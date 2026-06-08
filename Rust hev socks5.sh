#!/bin/bash
set -e
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[ "$(id -u)" = "0" ] || die "Ejecutar como root"

if command -v wget >/dev/null 2>&1; then
    FETCH="wget -q --timeout=30 -O"
elif command -v curl >/dev/null 2>&1; then
    FETCH="curl -fsSL --connect-timeout 30 -o"
else
    apt-get update -qq --fix-missing 2>/dev/null || true
    apt-get install -y -qq wget 2>/dev/null || die "No hay wget ni curl"
    FETCH="wget -q --timeout=30 -O"
fi

mkdir -p /opt/btserver
cd /opt/btserver

if [ -f /opt/btserver/token.txt ] && [ -s /opt/btserver/token.txt ]; then
    PANEL_TOKEN=$(cat /opt/btserver/token.txt)
    info "Token existente conservado."
else
    PANEL_TOKEN=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 64 || true)
    echo "${PANEL_TOKEN}" > /opt/btserver/token.txt
    chmod 600 /opt/btserver/token.txt
    info "Nuevo token generado."
fi

PANEL_PORT=8090
SERVER_IP=$(ip -4 addr show scope global | awk '/inet /{print $2}' | cut -d/ -f1 | head -1 || echo "0.0.0.0")

info "Deteniendo servicios..."
systemctl stop hev-socks5 btserver btpanel 2>/dev/null || true
sleep 1

info "Descargando hev-socks5-server..."
$FETCH /tmp/hev-socks5-server.tmp \
    https://github.com/heiher/hev-socks5-server/releases/latest/download/hev-socks5-server-linux-x86_64 \
    || die "No se pudo descargar hev-socks5-server"
mv -f /tmp/hev-socks5-server.tmp /opt/btserver/hev-socks5-server
chmod +x /opt/btserver/hev-socks5-server
info "hev-socks5-server OK"

NWORKERS=$(nproc 2>/dev/null || echo 1)

cat > /opt/btserver/hev-socks5-server.yml << YMLEOF
main:
  workers: ${NWORKERS}
  port: 1080
  listen-address: '127.0.0.1'
  listen-ipv6-only: false
  domain-address-type: unspec
misc:
  connect-timeout: 5000
  tcp-read-write-timeout: 300000
  udp-read-write-timeout: 60000
  max-session-count: 0
  log-file: stderr
  log-level: warn
  limit-nofile: 1000000
YMLEOF

info "Verificando Rust..."
if ! command -v cargo >/dev/null 2>&1; then
    info "Instalando Rust (rustup)..."
    export RUSTUP_HOME=/usr/local/rustup
    export CARGO_HOME=/usr/local/cargo
    $FETCH /tmp/rustup-init.sh https://sh.rustup.rs || die "No se pudo descargar rustup"
    chmod +x /tmp/rustup-init.sh
    /tmp/rustup-init.sh -y --no-modify-path --profile minimal --default-toolchain stable \
        || die "Error instalando Rust"
    rm -f /tmp/rustup-init.sh
    ln -sf /usr/local/cargo/bin/cargo  /usr/local/bin/cargo
    ln -sf /usr/local/cargo/bin/rustc  /usr/local/bin/rustc
    ln -sf /usr/local/cargo/bin/rustup /usr/local/bin/rustup
fi
export CARGO_HOME=/usr/local/cargo
export RUSTUP_HOME=/usr/local/rustup
export PATH=/usr/local/cargo/bin:$PATH
info "Rust: $(rustc --version)"

PROJ=/opt/btserver/btsrc
rm -rf "$PROJ"
mkdir -p "$PROJ/src/bin"

cat > "$PROJ/Cargo.toml" << 'TOMLEOF'
[package]
name    = "btserver"
version = "4.0.0"
edition = "2021"

[[bin]]
name = "btserver"
path = "src/bin/btserver.rs"

[[bin]]
name = "panel"
path = "src/bin/panel.rs"

[dependencies]
tokio              = { version = "1",    features = ["full"] }
axum               = { version = "0.8"  }
bytes              = "1"
crossbeam-queue    = "0.3"
socket2            = { version = "0.5", features = ["all"] }
libc               = "0.2"
serde              = { version = "1",   features = ["derive"] }
serde_json         = "1"
anyhow             = "1"
reqwest            = { version = "0.12", default-features = false, features = ["json", "rustls-tls"] }
tracing            = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }

[profile.release]
opt-level     = 3
lto           = true
codegen-units = 1
strip         = true
panic         = "abort"
TOMLEOF


cat > "$PROJ/src/bin/btserver.rs" << 'RSEOF'
use std::{
    collections::HashMap,
    io::IoSlice,
    net::SocketAddr,
    os::unix::io::AsRawFd,
    sync::{
        atomic::{AtomicBool, AtomicI32, AtomicI64, AtomicU32, Ordering},
        Arc, LazyLock,
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use anyhow::Result;
use bytes::{BufMut, Bytes, BytesMut};
use crossbeam_queue::SegQueue;
use socket2::{Domain, Protocol, Socket, TcpKeepalive, Type};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{
        tcp::{OwnedReadHalf, OwnedWriteHalf},
        TcpListener, TcpStream,
    },
    sync::{mpsc, RwLock},
    time,
};
use tracing::{info, warn};

const HEV_ADDR:             &str  = "127.0.0.1:1080";
const LISTEN_ADDR:          &str  = "0.0.0.0:80";
const KICK_ADDR:            &str  = "127.0.0.1:8091";
const USERS_FILE:           &str  = "/opt/btserver/users.txt";
const MAX_STREAMS:          usize = 7000;
const QUEUE_SIZE:           usize = 256;
const MAX_PAYLOAD:          usize = 16384;
const DIAL_TIMEOUT:         Duration = Duration::from_millis(200);
const HEV_CONN_TIMEOUT:     Duration = Duration::from_secs(1);
const HEV_WRITE_TIMEOUT:    Duration = Duration::from_secs(2);
const CLIENT_WRITE_TIMEOUT: Duration = Duration::from_secs(30);
const STREAM_IDLE_TIMEOUT:  i64  = 600;
const MUX_WRITE_QUEUE:      usize = 2048;
const CTRL_QUEUE:           usize = 128;
const MAX_BATCH:            usize = 64;
const READ_DEADLINE:        Duration = Duration::from_secs(120);
const PAYLOAD_DEADLINE:     Duration = Duration::from_secs(30);
const HEV_RCVBUF:           i32  = 524288;
const HEV_SNDBUF:           i32  = 524288;
const CLI_RCVBUF:           i32  = 524288;
const CLI_SNDBUF:           i32  = 524288;
const POOL_PREALLOC:        usize = 2048;

const T_OPEN:    u8 = 0x01;
const T_DATA:    u8 = 0x02;
const T_CLOSE:   u8 = 0x03;
const T_PING:    u8 = 0x04;
const T_PONG:    u8 = 0x05;
const T_KICK:    u8 = 0x06;
const T_EXPIRED: u8 = 0x07;

static UTC_OFFSET: LazyLock<i64> = LazyLock::new(|| {
    let stdout = std::process::Command::new("date")
        .arg("+%z")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .unwrap_or_default();
    let s = stdout.trim();
    if s.len() < 5 { return 0; }
    let sign: i64 = if s.starts_with('-') { -1 } else { 1 };
    let h: i64 = s[1..3].parse().unwrap_or(0);
    let m: i64 = s[3..5].parse().unwrap_or(0);
    sign * (h * 3600 + m * 60)
});

#[derive(Debug)]
enum AuthResult {
    Ok { name: String, days: i64 },
    NotFound,
    Expired,
}

#[inline]
fn now_secs() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() as i64
}

fn civil_to_epoch_days(y: i64, m: i64, d: i64) -> i64 {
    let m2 = if m <= 2 { m + 12 } else { m };
    let y2 = if m <= 2 { y - 1 } else { y };
    let a = y2 / 100;
    let b = 2 - a + a / 4;
    (365.25 * (y2 + 4716) as f64) as i64
        + (30.6001 * (m2 + 1) as f64) as i64
        + d + b - 1524 - 2440588
}

fn epoch_days_to_civil(days: i64) -> (i64, i64, i64) {
    let j = days + 2440588;
    let f = j + 1401 + (((4 * j + 274277) / 146097) * 3) / 4 - 38;
    let e = 4 * f + 3;
    let g = (e % 1461) / 4;
    let h = 5 * g + 2;
    let d = (h % 153) / 5 + 1;
    let m = (h / 153 + 2) % 12 + 1;
    let y = e / 1461 - 4716 + (14 - m) / 12;
    (y, m, d)
}

fn parse_date_end(s: &str) -> Option<i64> {
    let s = s.trim();
    let mut it = s.splitn(3, '-');
    let y: i64 = it.next()?.parse().ok()?;
    let m: i64 = it.next()?.parse().ok()?;
    let d: i64 = it.next()?.parse().ok()?;
    Some(civil_to_epoch_days(y, m, d) * 86400 + 86399 - *UTC_OFFSET)
}

fn ts_to_date(ts: i64) -> String {
    let (y, m, d) = epoch_days_to_civil(ts / 86400);
    format!("{y:04}-{m:02}-{d:02}")
}

fn days_from_now(n: i64) -> String {
    ts_to_date(now_secs() + n * 86400)
}

fn check_auth(id: &str) -> AuthResult {
    let Ok(content) = std::fs::read_to_string(USERS_FILE) else {
        return AuthResult::NotFound;
    };
    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') { continue; }
        let mut parts = line.splitn(3, ':');
        let Some(uid)  = parts.next() else { continue };
        let Some(name) = parts.next() else { continue };
        let Some(exp)  = parts.next() else { continue };
        if uid != id { continue; }
        let Some(exp_ts) = parse_date_end(exp) else { continue };
        let now = now_secs();
        if now > exp_ts { return AuthResult::Expired; }
        return AuthResult::Ok { name: name.to_string(), days: (exp_ts - now) / 86400 + 1 };
    }
    AuthResult::NotFound
}

#[derive(Clone)]
struct BufPool(Arc<SegQueue<BytesMut>>);

impl BufPool {
    fn new(prealloc: usize, cap: usize) -> Self {
        let q = SegQueue::new();
        for _ in 0..prealloc { q.push(BytesMut::with_capacity(cap)); }
        Self(Arc::new(q))
    }

    #[inline]
    fn get(&self, needed: usize) -> BytesMut {
        if let Some(mut b) = self.0.pop() {
            b.clear();
            if b.capacity() >= needed { return b; }
        }
        BytesMut::with_capacity(needed)
    }

    #[inline]
    fn put(&self, mut b: BytesMut) {
        if b.capacity() <= (MAX_PAYLOAD + 7) * 2 {
            b.clear();
            self.0.push(b);
        }
    }

    fn ctrl(&self, t: u8, sid: u32) -> Bytes {
        let mut b = self.get(7);
        b.put_u8(t);
        b.put_u32(sid);
        b.put_u16(0);
        b.freeze()
    }

    fn data(&self, sid: u32, payload: &[u8]) -> Bytes {
        let mut b = self.get(7 + payload.len());
        b.put_u8(T_DATA);
        b.put_u32(sid);
        b.put_u16(payload.len() as u16);
        b.put_slice(payload);
        b.freeze()
    }
}

unsafe fn setsockopt_i32(fd: i32, level: i32, opt: i32, val: i32) {
    libc::setsockopt(
        fd, level, opt,
        &val as *const i32 as *const libc::c_void,
        std::mem::size_of::<i32>() as libc::socklen_t,
    );
}

fn tune_client_fd(fd: i32) {
    unsafe {
        setsockopt_i32(fd, libc::IPPROTO_TCP, libc::TCP_NODELAY,   1);
        setsockopt_i32(fd, libc::SOL_SOCKET,  libc::SO_RCVBUF,     CLI_RCVBUF);
        setsockopt_i32(fd, libc::SOL_SOCKET,  libc::SO_SNDBUF,     CLI_SNDBUF);
    }
}

fn tune_hev_fd(fd: i32) {
    unsafe {
        setsockopt_i32(fd, libc::IPPROTO_TCP, libc::TCP_NODELAY,   1);
        setsockopt_i32(fd, libc::IPPROTO_TCP, libc::TCP_QUICKACK,  1);
        setsockopt_i32(fd, libc::SOL_SOCKET,  libc::SO_RCVBUF,     HEV_RCVBUF);
        setsockopt_i32(fd, libc::SOL_SOCKET,  libc::SO_SNDBUF,     HEV_SNDBUF);
        setsockopt_i32(fd, libc::SOL_SOCKET,  libc::SO_KEEPALIVE,  1);
        setsockopt_i32(fd, libc::IPPROTO_TCP, libc::TCP_KEEPIDLE,  30);
        setsockopt_i32(fd, libc::IPPROTO_TCP, libc::TCP_KEEPINTVL, 10);
        setsockopt_i32(fd, libc::IPPROTO_TCP, libc::TCP_KEEPCNT,   3);
    }
}

struct Stream {
    tx:           mpsc::Sender<Bytes>,
    closed:       AtomicBool,
    last_act:     AtomicI64,
    worker_count: AtomicI32,
}

impl Stream {
    fn new(tx: mpsc::Sender<Bytes>) -> Arc<Self> {
        Arc::new(Self {
            tx,
            closed:       AtomicBool::new(false),
            last_act:     AtomicI64::new(now_secs()),
            worker_count: AtomicI32::new(0),
        })
    }
    #[inline] fn touch(&self) { self.last_act.store(now_secs(), Ordering::Relaxed); }
    #[inline] fn idle_secs(&self) -> i64 { now_secs() - self.last_act.load(Ordering::Relaxed) }
    #[inline] fn try_close(&self) -> bool {
        self.closed.compare_exchange(false, true, Ordering::AcqRel, Ordering::Relaxed).is_ok()
    }
    #[inline] fn is_closed(&self) -> bool { self.closed.load(Ordering::Acquire) }
}

struct Mux {
    write_tx: mpsc::Sender<Bytes>,
    ctrl_tx:  mpsc::Sender<Bytes>,
    streams:  RwLock<HashMap<u32, Arc<Stream>>>,
    count:    AtomicU32,
    dead:     AtomicBool,
    pool:     BufPool,
}

impl Mux {
    fn new(write_tx: mpsc::Sender<Bytes>, ctrl_tx: mpsc::Sender<Bytes>, pool: BufPool) -> Arc<Self> {
        Arc::new(Self {
            write_tx, ctrl_tx,
            streams: RwLock::new(HashMap::with_capacity(128)),
            count:   AtomicU32::new(0),
            dead:    AtomicBool::new(false),
            pool,
        })
    }

    #[inline] fn is_dead(&self) -> bool { self.dead.load(Ordering::Acquire) }

    async fn send_data(&self, sid: u32, data: &[u8]) {
        if self.is_dead() { return; }
        let frame = self.pool.data(sid, data);
        if self.write_tx.try_send(frame).is_err() {
            self.close_stream(sid).await;
            let _ = self.ctrl_tx.try_send(self.pool.ctrl(T_CLOSE, sid));
        }
    }

    async fn send_ctrl(&self, t: u8, sid: u32) {
        if self.is_dead() { return; }
        let _ = self.ctrl_tx.try_send(self.pool.ctrl(t, sid));
    }

    async fn add_stream(&self, sid: u32, s: Arc<Stream>) -> bool {
        let mut map = self.streams.write().await;
        if map.len() >= MAX_STREAMS { return false; }
        map.insert(sid, s);
        self.count.fetch_add(1, Ordering::Relaxed);
        true
    }

    async fn get_stream(&self, sid: u32) -> Option<Arc<Stream>> {
        self.streams.read().await.get(&sid).cloned()
    }

    async fn del_stream(&self, sid: u32) {
        let mut map = self.streams.write().await;
        if map.remove(&sid).is_some() {
            self.count.fetch_sub(1, Ordering::Relaxed);
        }
    }

    async fn close_stream(&self, sid: u32) {
        if let Some(s) = self.get_stream(sid).await {
            if s.try_close() { self.del_stream(sid).await; }
        }
    }
}

type SessionMap = Arc<RwLock<HashMap<String, Arc<Mux>>>>;

async fn kick_session(sessions: &SessionMap, id: &str, reason: u8) -> bool {
    let entry = sessions.write().await.remove(id);
    if let Some(mux) = entry {
        let _ = mux.ctrl_tx.try_send(mux.pool.ctrl(reason, 0));
        mux.dead.store(true, Ordering::Release);
        info!(id, reason, "session kicked");
        true
    } else {
        false
    }
}

async fn write_loop(
    mut writer:   OwnedWriteHalf,
    mut write_rx: mpsc::Receiver<Bytes>,
    mut ctrl_rx:  mpsc::Receiver<Bytes>,
    mux:          Arc<Mux>,
) {
    let mut batch: Vec<Bytes>      = Vec::with_capacity(MAX_BATCH);
    let mut slices: Vec<IoSlice>   = Vec::with_capacity(MAX_BATCH);
    let mut leftover: Option<Bytes> = None;

    'outer: loop {
        batch.clear();

        if let Some(b) = leftover.take() { batch.push(b); }

        if batch.is_empty() {
            tokio::select! {
                biased;
                frame = ctrl_rx.recv() => {
                    let Some(f) = frame else { break; };
                    batch.push(f);
                    while let Ok(f) = ctrl_rx.try_recv() { batch.push(f); }
                }
                frame = write_rx.recv() => {
                    let Some(f) = frame else { break; };
                    batch.push(f);
                    let mut n = 1;
                    while n < MAX_BATCH {
                        match write_rx.try_recv() {
                            Ok(f) => { batch.push(f); n += 1; }
                            Err(_) => break,
                        }
                    }
                }
            }
        }

        let mut written = 0usize;
        let total: usize = batch.iter().map(|b| b.len()).sum();

        loop {
            slices.clear();
            let mut off = 0usize;
            for b in &batch {
                if off + b.len() <= written { off += b.len(); continue; }
                let skip = written.saturating_sub(off);
                slices.push(IoSlice::new(&b[skip..]));
                off += b.len();
            }
            if slices.is_empty() { break; }

            match tokio::time::timeout(CLIENT_WRITE_TIMEOUT, writer.write_vectored(&slices)).await {
                Ok(Ok(0)) => { mux.dead.store(true, Ordering::Release); break 'outer; }
                Ok(Ok(n)) => {
                    written += n;
                    if written >= total { break; }
                }
                _ => { mux.dead.store(true, Ordering::Release); break 'outer; }
            }
        }
    }

    mux.dead.store(true, Ordering::Release);
}

async fn handle_stream(
    mux:    Arc<Mux>,
    sid:    u32,
    stream: Arc<Stream>,
    mut rx: mpsc::Receiver<Bytes>,
    first:  Bytes,
) {
    let cleanup = || async {
        if stream.try_close() {
            mux.del_stream(sid).await;
            mux.send_ctrl(T_CLOSE, sid).await;
        }
    };

    let hev = match tokio::time::timeout(DIAL_TIMEOUT, TcpStream::connect(HEV_ADDR)).await {
        Ok(Ok(c)) => c,
        _ => { cleanup().await; return; }
    };
    tune_hev_fd(hev.as_raw_fd());

    let (mut hev_r, mut hev_w) = hev.into_split();

    if !first.is_empty() {
        if tokio::time::timeout(HEV_CONN_TIMEOUT, hev_w.write_all(&first)).await.is_err() {
            cleanup().await;
            return;
        }
    }

    let mux2    = mux.clone();
    let stream2 = stream.clone();

    let t_c2h = tokio::spawn(async move {
        stream2.worker_count.fetch_add(1, Ordering::Relaxed);
        while let Some(data) = rx.recv().await {
            stream2.touch();
            if tokio::time::timeout(HEV_WRITE_TIMEOUT, hev_w.write_all(&data)).await.is_err() {
                break;
            }
        }
        stream2.worker_count.fetch_sub(1, Ordering::Relaxed);
    });

    let t_h2c = tokio::spawn(async move {
        stream.worker_count.fetch_add(1, Ordering::Relaxed);
        let mut buf = vec![0u8; MAX_PAYLOAD];
        loop {
            match hev_r.read(&mut buf).await {
                Ok(0) | Err(_) => break,
                Ok(n) => { stream.touch(); mux2.send_data(sid, &buf[..n]).await; }
            }
        }
        stream.worker_count.fetch_sub(1, Ordering::Relaxed);
    });

    let _ = tokio::join!(t_c2h, t_h2c);
    cleanup().await;
}

async fn idle_reaper(mux: Arc<Mux>) {
    let mut tick = time::interval(Duration::from_secs(60));
    loop {
        tick.tick().await;
        if mux.is_dead() { return; }
        let stale: Vec<u32> = mux.streams.read().await
            .iter()
            .filter(|(_, s)| {
                s.worker_count.load(Ordering::Relaxed) == 0
                    && !s.is_closed()
                    && s.idle_secs() > STREAM_IDLE_TIMEOUT
            })
            .map(|(sid, _)| *sid)
            .collect();
        for sid in stale {
            mux.close_stream(sid).await;
            mux.send_ctrl(T_CLOSE, sid).await;
        }
    }
}

async fn mux_run(mux: Arc<Mux>, mut reader: OwnedReadHalf) {
    let mut hdr  = [0u8; 7];
    let mut rbuf = vec![0u8; MAX_PAYLOAD];

    loop {
        match tokio::time::timeout(READ_DEADLINE, reader.read_exact(&mut hdr)).await {
            Ok(Ok(_)) => {}
            _ => break,
        }

        let ft  = hdr[0];
        let sid = u32::from_be_bytes(hdr[1..5].try_into().unwrap());
        let ln  = u16::from_be_bytes(hdr[5..7].try_into().unwrap()) as usize;
        if ln > MAX_PAYLOAD { break; }

        if ln > 0 {
            match tokio::time::timeout(PAYLOAD_DEADLINE, reader.read_exact(&mut rbuf[..ln])).await {
                Ok(Ok(_)) => {}
                _ => break,
            }
        }

        match ft {
            T_PING => { mux.send_ctrl(T_PONG, sid).await; }
            T_PONG => {}

            T_OPEN => {
                let payload = if ln > 0 {
                    Bytes::copy_from_slice(&rbuf[..ln])
                } else {
                    Bytes::new()
                };
                let (tx, rx) = mpsc::channel(QUEUE_SIZE);
                let s = Stream::new(tx);
                if !mux.add_stream(sid, s.clone()).await {
                    mux.send_ctrl(T_CLOSE, sid).await;
                    continue;
                }
                tokio::spawn(handle_stream(mux.clone(), sid, s, rx, payload));
            }

            T_DATA => {
                if let Some(s) = mux.get_stream(sid).await {
                    if !s.is_closed() {
                        s.touch();
                        let payload = Bytes::copy_from_slice(&rbuf[..ln]);
                        if s.tx.try_send(payload).is_err() {
                            mux.close_stream(sid).await;
                            mux.send_ctrl(T_CLOSE, sid).await;
                        }
                    }
                }
            }

            T_CLOSE => { mux.close_stream(sid).await; }
            _ => {}
        }
    }

    let sids: Vec<u32> = mux.streams.read().await.keys().cloned().collect();
    for sid in sids { mux.close_stream(sid).await; }
}

fn extract_header<'a>(raw: &'a [u8], needle: &[u8]) -> Option<&'a str> {
    for line in raw.split(|&b| b == b'\n') {
        let line = line.strip_suffix(b"\r").unwrap_or(line);
        if line.len() <= needle.len() { continue; }
        if !line[..needle.len()].eq_ignore_ascii_case(needle) { continue; }
        return std::str::from_utf8(line[needle.len()..].trim_ascii()).ok();
    }
    None
}

async fn send_403(writer: &mut OwnedWriteHalf, reason: &str) {
    let body = format!(
        "HTTP/1.1 403 Forbidden\r\nX-Disconnect-Reason: {reason}\r\nContent-Length: {}\r\n\r\n{reason}",
        reason.len()
    );
    let _ = writer.write_all(body.as_bytes()).await;
}

async fn handle_conn(tcp: TcpStream, sessions: SessionMap, pool: BufPool) {
    tune_client_fd(tcp.as_raw_fd());

    let mut buf = vec![0u8; 8192];
    let mut n   = 0usize;
    let deadline = time::Instant::now() + Duration::from_secs(10);

    let (mut reader, mut writer) = tcp.into_split();

    loop {
        if time::Instant::now() > deadline || n >= buf.len() { return; }
        match reader.read(&mut buf[n..]).await {
            Ok(0) | Err(_) => return,
            Ok(nr) => {
                n += nr;
                let has_action = buf[..n].windows(7).any(|w| w.eq_ignore_ascii_case(b"action:"));
                let has_end    = buf[..n].windows(4).any(|w| w == b"\r\n\r\n");
                if has_action && has_end { break; }
            }
        }
    }

    let raw    = &buf[..n];
    let action = extract_header(raw, b"action:");
    if action != Some("tunnel") && action != Some("tunnel-tcp") { return; }

    let user_id = match extract_header(raw, b"x-internal-id:").filter(|s| !s.is_empty()) {
        Some(id) => id.to_string(),
        None => { send_403(&mut writer, "not_registered").await; return; }
    };

    let (name, days) = match check_auth(&user_id) {
        AuthResult::Ok { name, days } => (name, days),
        AuthResult::NotFound => { send_403(&mut writer, "not_registered").await; return; }
        AuthResult::Expired  => { send_403(&mut writer, "expired").await; return; }
    };

    let resp = format!(
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nX-User-Name: {name}\r\nX-User-Days: {days}\r\n\r\n"
    );
    if writer.write_all(resp.as_bytes()).await.is_err() { return; }

    let (write_tx, write_rx) = mpsc::channel::<Bytes>(MUX_WRITE_QUEUE);
    let (ctrl_tx,  ctrl_rx)  = mpsc::channel::<Bytes>(CTRL_QUEUE);
    let mux  = Mux::new(write_tx, ctrl_tx, pool);


    let prev = sessions.write().await.insert(user_id.clone(), mux.clone());
    if let Some(prev_mux) = prev {
        let _ = prev_mux.ctrl_tx.try_send(prev_mux.pool.ctrl(T_KICK, 0));
        prev_mux.dead.store(true, Ordering::Release);
    }

    tokio::spawn(idle_reaper(mux.clone()));
    tokio::spawn(write_loop(writer, write_rx, ctrl_rx, mux.clone()));

    mux_run(mux.clone(), reader).await;

    let mut map = sessions.write().await;
    if map.get(&user_id).map(|m| Arc::ptr_eq(m, &mux)).unwrap_or(false) {
        map.remove(&user_id);
    }
}

fn build_listener() -> std::io::Result<std::net::TcpListener> {
    let addr: SocketAddr = LISTEN_ADDR.parse().unwrap();
    let sock = Socket::new(Domain::IPV4, Type::STREAM, Some(Protocol::TCP))?;
    sock.set_reuse_address(true)?;
    sock.set_reuse_port(true)?;
    sock.set_nodelay(true)?;
    let ka = TcpKeepalive::new()
        .with_time(Duration::from_secs(60))
        .with_interval(Duration::from_secs(10));
    sock.set_tcp_keepalive(&ka)?;
    unsafe {
        let fd = sock.as_raw_fd();
        libc::setsockopt(fd, libc::IPPROTO_TCP, libc::TCP_FASTOPEN,
            &1i32 as *const _ as _, 4);
    }
    sock.set_nonblocking(true)?;
    sock.bind(&addr.into())?;
    sock.listen(65535)?;
    Ok(sock.into())
}

async fn kick_api(sessions: SessionMap) {
    use axum::{extract::{Query, State}, routing::get, Router};

    async fn kick_handler(
        State(s): State<SessionMap>,
        Query(p): Query<HashMap<String, String>>,
    ) -> String {
        let Some(id) = p.get("id").filter(|id| !id.is_empty()) else {
            return "missing_id".into();
        };
        let reason = if p.get("reason").map(|s| s.as_str()) == Some("expired") {
            T_EXPIRED
        } else {
            T_KICK
        };
        if kick_session(&s, id, reason).await { "kicked".into() } else { "not_connected".into() }
    }

    let app = Router::new().route("/kick", get(kick_handler)).with_state(sessions);
    let ln  = TcpListener::bind(KICK_ADDR).await.expect("kick bind");
    info!("kick api on {KICK_ADDR}");
    axum::serve(ln, app).await.expect("kick serve");
}

async fn midnight_sweep(sessions: SessionMap) {
    loop {
        let secs = 86400 - (now_secs() % 86400);
        tokio::time::sleep(Duration::from_secs(secs as u64)).await;
        let ids: Vec<String> = sessions.read().await.keys().cloned().collect();
        let mut kicked = 0usize;
        for id in ids {
            let reason = match check_auth(&id) {
                AuthResult::Ok { .. } => continue,
                AuthResult::Expired   => T_EXPIRED,
                AuthResult::NotFound  => T_KICK,
            };
            kick_session(&sessions, &id, reason).await;
            kicked += 1;
        }
        if kicked > 0 { info!("midnight sweep: kicked {kicked}"); }
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::from_default_env()
                .add_directive("btserver=info".parse()?),
        )
        .init();

    let _ = *UTC_OFFSET;

    let sessions: SessionMap = Arc::new(RwLock::new(HashMap::new()));
    let pool = BufPool::new(POOL_PREALLOC, MAX_PAYLOAD + 7);

    tokio::spawn(kick_api(sessions.clone()));
    tokio::spawn(midnight_sweep(sessions.clone()));

    let std_ln = build_listener().expect("listener");
    let listener = TcpListener::from_std(std_ln).expect("tokio listener");
    info!("btserver on {LISTEN_ADDR} -> hev {HEV_ADDR}");

    loop {
        match listener.accept().await {
            Ok((conn, _)) => {
                let s = sessions.clone();
                let p = pool.clone();
                tokio::spawn(handle_conn(conn, s, p));
            }
            Err(e) => warn!("accept: {e}"),
        }
    }
}
RSEOF

cat > "$PROJ/src/bin/panel.rs" << 'RSEOF'
use std::{
    collections::HashMap,
    net::SocketAddr,
    sync::{Arc, LazyLock, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use anyhow::Result;
use axum::{
    extract::{ConnectInfo, Query, State},
    http::{HeaderMap, StatusCode},
    routing::{delete, get, post, put},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use tokio::net::TcpListener;
use tracing::info;

const PANEL_ADDR: &str = "0.0.0.0:8090";
const USERS_PATH: &str = "/opt/btserver/users.txt";
const TOKEN_PATH: &str = "/opt/btserver/token.txt";
const KICK_BASE:  &str = "http://127.0.0.1:8091/kick?id=";

static UTC_OFFSET: LazyLock<i64> = LazyLock::new(|| {
    let stdout = std::process::Command::new("date")
        .arg("+%z")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .unwrap_or_default();
    let s = stdout.trim();
    if s.len() < 5 { return 0; }
    let sign: i64 = if s.starts_with('-') { -1 } else { 1 };
    let h: i64 = s[1..3].parse().unwrap_or(0);
    let m: i64 = s[3..5].parse().unwrap_or(0);
    sign * (h * 3600 + m * 60)
});

#[inline]
fn now_secs() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() as i64
}

fn civil_to_epoch_days(y: i64, m: i64, d: i64) -> i64 {
    let m2 = if m <= 2 { m + 12 } else { m };
    let y2 = if m <= 2 { y - 1 } else { y };
    let a = y2 / 100;
    let b = 2 - a + a / 4;
    (365.25 * (y2 + 4716) as f64) as i64
        + (30.6001 * (m2 + 1) as f64) as i64
        + d + b - 1524 - 2440588
}

fn epoch_days_to_civil(days: i64) -> (i64, i64, i64) {
    let j = days + 2440588;
    let f = j + 1401 + (((4 * j + 274277) / 146097) * 3) / 4 - 38;
    let e = 4 * f + 3;
    let g = (e % 1461) / 4;
    let h = 5 * g + 2;
    let d = (h % 153) / 5 + 1;
    let m = (h / 153 + 2) % 12 + 1;
    let y = e / 1461 - 4716 + (14 - m) / 12;
    (y, m, d)
}

fn parse_date_end(s: &str) -> Option<i64> {
    let s = s.trim();
    let mut it = s.splitn(3, '-');
    let y: i64 = it.next()?.parse().ok()?;
    let m: i64 = it.next()?.parse().ok()?;
    let d: i64 = it.next()?.parse().ok()?;
    Some(civil_to_epoch_days(y, m, d) * 86400 + 86399 - *UTC_OFFSET)
}

fn ts_to_date(ts: i64) -> String {
    let (y, m, d) = epoch_days_to_civil(ts / 86400);
    format!("{y:04}-{m:02}-{d:02}")
}

fn days_from_now(n: i64) -> String { ts_to_date(now_secs() + n * 86400) }

fn add_days_to(base: &str, days: i64) -> String {
    match parse_date_end(base) {
        Some(ts) => ts_to_date(ts + days * 86400),
        None     => base.to_string(),
    }
}

fn days_left(expires: &str) -> i64 {
    let Some(ts) = parse_date_end(expires) else { return 0; };
    let left = ts - now_secs();
    if left <= 0 { 0 } else { left / 86400 + 1 }
}

#[derive(Clone)]
struct AppState {
    token:    Arc<String>,
    users_mu: Arc<Mutex<()>>,
    rate:     Arc<Mutex<HashMap<String, Vec<i64>>>>,
}

impl AppState {
    fn new() -> Self {
        let token = std::fs::read_to_string(TOKEN_PATH)
            .map(|s| s.trim().to_string())
            .unwrap_or_default();
        Self {
            token:    Arc::new(token),
            users_mu: Arc::new(Mutex::new(())),
            rate:     Arc::new(Mutex::new(HashMap::new())),
        }
    }

    fn rate_ok(&self, ip: &str) -> bool {
        let now = now_secs();
        let mut map = self.rate.lock().unwrap();
        let hits = map.entry(ip.to_string()).or_default();
        hits.retain(|&t| now - t < 60);
        if hits.len() >= 30 { return false; }
        hits.push(now);
        if map.len() > 1000 { map.clear(); }
        true
    }

    fn check_token(&self, headers: &HeaderMap) -> bool {
        headers.get("x-token")
            .and_then(|v| v.to_str().ok())
            .map(|t| t.trim() == self.token.as_str())
            .unwrap_or(false)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct User { name: String, expires: String }

fn load_users() -> HashMap<String, User> {
    let Ok(c) = std::fs::read_to_string(USERS_PATH) else { return HashMap::new(); };
    let mut map = HashMap::new();
    for line in c.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') { continue; }
        let mut parts = line.splitn(3, ':');
        let Some(id)  = parts.next().map(str::trim).filter(|s| !s.is_empty()) else { continue };
        let Some(name) = parts.next().map(str::trim) else { continue };
        let Some(exp)  = parts.next().map(str::trim) else { continue };
        map.insert(id.to_string(), User { name: name.to_string(), expires: exp.to_string() });
    }
    map
}

fn save_users(users: &HashMap<String, User>) {
    let tmp = format!("{USERS_PATH}.tmp");
    let mut out = String::from("# formato: id:nombre:YYYY-MM-DD\n");
    for (id, u) in users {
        out.push_str(&format!("{id}:{}:{}\n", u.name, u.expires));
    }
    if std::fs::write(&tmp, &out).is_ok() {
        let _ = std::fs::rename(&tmp, USERS_PATH);
    }
}

fn user_row(id: &str, u: &User) -> serde_json::Value {
    let dl = days_left(&u.expires);
    serde_json::json!({"id":id,"name":u.name,"expires":u.expires,"days_left":dl,"active":dl>0})
}

async fn kick_user(id: String, reason: &'static str) {
    let url = format!("{KICK_BASE}{id}&reason={reason}");
    let Ok(c) = reqwest::Client::builder().timeout(Duration::from_secs(2)).build() else { return; };
    let _ = c.get(&url).send().await;
}

type ApiResult = (StatusCode, Json<serde_json::Value>);

fn err_resp(code: StatusCode, msg: &str) -> ApiResult {
    (code, Json(serde_json::json!({"error": msg})))
}

fn auth_check(state: &AppState, headers: &HeaderMap, addr: &SocketAddr) -> Option<ApiResult> {
    let ip = addr.ip().to_string();
    if !state.rate_ok(&ip) {
        return Some(err_resp(StatusCode::TOO_MANY_REQUESTS, "too many requests"));
    }
    if !state.check_token(headers) {
        return Some(err_resp(StatusCode::UNAUTHORIZED, "unauthorized"));
    }
    None
}

async fn handle_clients(
    State(st): State<AppState>,
    headers: HeaderMap,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
) -> ApiResult {
    if let Some(e) = auth_check(&st, &headers, &addr) { return e; }
    let _l = st.users_mu.lock().unwrap();
    let users = load_users();
    let rows: Vec<_> = users.iter().map(|(id, u)| user_row(id, u)).collect();
    (StatusCode::OK, Json(serde_json::json!({"clients":rows,"total":rows.len()})))
}

async fn handle_client(
    State(st): State<AppState>,
    headers: HeaderMap,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Query(p): Query<HashMap<String, String>>,
) -> ApiResult {
    if let Some(e) = auth_check(&st, &headers, &addr) { return e; }
    let id = match p.get("id").map(|s| s.trim().to_string()).filter(|s| !s.is_empty()) {
        Some(id) => id,
        None => return err_resp(StatusCode::BAD_REQUEST, "falta id"),
    };
    let _l = st.users_mu.lock().unwrap();
    match load_users().get(&id).cloned() {
        Some(u) => (StatusCode::OK, Json(user_row(&id, &u))),
        None    => err_resp(StatusCode::NOT_FOUND, "no encontrado"),
    }
}

#[derive(Deserialize)]
struct CreateBody { id: String, name: Option<String>, days: Option<i64> }

async fn handle_create(
    State(st): State<AppState>,
    headers: HeaderMap,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Json(body): Json<CreateBody>,
) -> ApiResult {
    if let Some(e) = auth_check(&st, &headers, &addr) { return e; }
    let id = body.id.trim().to_string();
    if id.is_empty() { return err_resp(StatusCode::BAD_REQUEST, "falta id"); }
    let name = body.name.as_deref().unwrap_or("").trim().to_string();
    let name = if name.is_empty() { "sin-nombre".to_string() } else { name };
    let days = body.days.unwrap_or(30);
    let expires = days_from_now(days);
    let _l = st.users_mu.lock().unwrap();
    let mut users = load_users();
    users.insert(id.clone(), User { name: name.clone(), expires: expires.clone() });
    save_users(&users);
    (StatusCode::OK, Json(serde_json::json!({"ok":true,"id":id,"name":name,"expires":expires,"days":days})))
}

#[derive(Deserialize)]
struct IdBody { id: String }

async fn handle_delete(
    State(st): State<AppState>,
    headers: HeaderMap,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Json(body): Json<IdBody>,
) -> ApiResult {
    if let Some(e) = auth_check(&st, &headers, &addr) { return e; }
    let id = body.id.trim().to_string();
    if id.is_empty() { return err_resp(StatusCode::BAD_REQUEST, "falta id"); }
    {
        let _l = st.users_mu.lock().unwrap();
        let mut users = load_users();
        if !users.contains_key(&id) { return err_resp(StatusCode::NOT_FOUND, "no encontrado"); }
        users.remove(&id);
        save_users(&users);
    }
    tokio::spawn(kick_user(id, "kicked"));
    (StatusCode::OK, Json(serde_json::json!({"ok":true})))
}

#[derive(Deserialize)]
struct UpdateBody {
    id: String, name: Option<String>, new_id: Option<String>,
    add_days: Option<i64>, sub_days: Option<i64>, set_days: Option<i64>, set_date: Option<String>,
}

async fn handle_update(
    State(st): State<AppState>,
    headers: HeaderMap,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Json(body): Json<UpdateBody>,
) -> ApiResult {
    if let Some(e) = auth_check(&st, &headers, &addr) { return e; }
    let id = body.id.trim().to_string();
    if id.is_empty() { return err_resp(StatusCode::BAD_REQUEST, "falta id"); }

    let (final_id, u, old_kicked) = {
        let _l = st.users_mu.lock().unwrap();
        let mut users = load_users();
        let Some(mut u) = users.get(&id).cloned() else {
            return err_resp(StatusCode::NOT_FOUND, "no encontrado");
        };

        if let Some(n) = body.name.as_deref() {
            if !n.trim().is_empty() { u.name = n.trim().to_string(); }
        }

        let base = if parse_date_end(&u.expires).map(|t| t > now_secs()).unwrap_or(false) {
            u.expires.clone()
        } else {
            days_from_now(0)
        };

        if let Some(d)  = body.add_days { u.expires = add_days_to(&base, d); }
        else if let Some(d) = body.sub_days { u.expires = add_days_to(&u.expires, -d); }
        else if let Some(d) = body.set_days { u.expires = days_from_now(d); }
        else if let Some(dt) = body.set_date { u.expires = dt.trim().to_string(); }

        let (final_id, old_kicked) = if let Some(nid) = body.new_id.as_deref() {
            let nid = nid.trim().to_string();
            if !nid.is_empty() && nid != id {
                users.remove(&id);
                (nid, true)
            } else {
                (id.clone(), false)
            }
        } else {
            (id.clone(), false)
        };

        users.insert(final_id.clone(), u.clone());
        save_users(&users);
        (final_id, u, old_kicked)
    };

    if old_kicked { tokio::spawn(kick_user(id, "kicked")); }
    if days_left(&u.expires) <= 0 { tokio::spawn(kick_user(final_id.clone(), "expired")); }

    (StatusCode::OK, Json(user_row(&final_id, &u)))
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::from_default_env()
                .add_directive("panel=info".parse()?),
        )
        .init();

    let _ = *UTC_OFFSET;

    let state = AppState::new();
    let app = Router::new()
        .route("/clients",       get(handle_clients))
        .route("/client",        get(handle_client))
        .route("/client/create", post(handle_create))
        .route("/client/delete", delete(handle_delete))
        .route("/client/update", put(handle_update))
        .with_state(state)
        .into_make_service_with_connect_info::<SocketAddr>();

    let ln = TcpListener::bind(PANEL_ADDR).await?;
    info!("panel api on {PANEL_ADDR}");
    axum::serve(ln, app).await?;
    Ok(())
}
RSEOF

info "Tuning TCP/kernel..."
cat > /etc/sysctl.d/99-btserver.conf << 'SYSCTL'
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.rmem_default=524288
net.core.wmem_default=524288
net.ipv4.tcp_rmem=4096 524288 67108864
net.ipv4.tcp_wmem=4096 524288 67108864
net.ipv4.tcp_notsent_lowat=4096
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=10
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=3
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=65535
net.core.netdev_max_backlog=65535
fs.file-max=1000000
net.ipv4.tcp_mem=786432 1048576 67108864
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.tcp_max_tw_buckets=2000000
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_ecn=1
SYSCTL
modprobe tcp_bbr 2>/dev/null || true
sysctl -p /etc/sysctl.d/99-btserver.conf -q 2>/dev/null || true

cat > /etc/security/limits.d/btserver.conf << 'LIMITS'
*    soft nofile 1000000
*    hard nofile 1000000
root soft nofile 1000000
root hard nofile 1000000
LIMITS

info "Compilando (primera vez: 3-5 min)..."
cd "$PROJ"
cargo build --release 2>&1 | grep -E "^error|Compiling|Finished" || true

[ -f "$PROJ/target/release/btserver" ] || die "Error compilando btserver"
[ -f "$PROJ/target/release/panel"    ] || die "Error compilando panel"

cp "$PROJ/target/release/btserver" /opt/btserver/btserver
cp "$PROJ/target/release/panel"    /opt/btserver/panel
chmod +x /opt/btserver/btserver /opt/btserver/panel
info "Compilacion OK"

[ -f /opt/btserver/users.txt ] || printf '# formato: id:nombre:YYYY-MM-DD\n' > /opt/btserver/users.txt

cat > /etc/systemd/system/hev-socks5.service << 'SVC'
[Unit]
Description=HEV Socks5
After=network.target

[Service]
ExecStart=/opt/btserver/hev-socks5-server /opt/btserver/hev-socks5-server.yml
Restart=always
RestartSec=2
LimitNOFILE=1000000
LimitNPROC=infinity
TasksMax=infinity
Nice=-10
IOSchedulingClass=realtime
IOSchedulingPriority=0

[Install]
WantedBy=multi-user.target
SVC

cat > /etc/systemd/system/btserver.service << 'SVC'
[Unit]
Description=BlackTunnel Server (Rust v4)
After=network.target hev-socks5.service
Requires=hev-socks5.service

[Service]
ExecStart=/opt/btserver/btserver
Restart=always
RestartSec=2
LimitNOFILE=1000000
LimitNPROC=infinity
TasksMax=infinity
Nice=-10
IOSchedulingClass=realtime
IOSchedulingPriority=0

[Install]
WantedBy=multi-user.target
SVC

cat > /etc/systemd/system/btpanel.service << 'SVC'
[Unit]
Description=BlackTunnel Panel (Rust v4)
After=network.target

[Service]
ExecStart=/opt/btserver/panel
Restart=always
RestartSec=2
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable hev-socks5 btserver btpanel

info "Iniciando servicios..."
systemctl restart hev-socks5; sleep 1
systemctl restart btserver;   sleep 1
systemctl restart btpanel;    sleep 1

info "Configurando QoS..."
IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1)
if [ -n "$IFACE" ]; then
    tc qdisc del dev "$IFACE" root 2>/dev/null || true
    tc qdisc add dev "$IFACE" root handle 1: prio bands 3 priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    tc qdisc add dev "$IFACE" parent 1:1 handle 10: fq_codel limit 256  target 2ms  interval 50ms
    tc qdisc add dev "$IFACE" parent 1:2 handle 20: fq_codel limit 512  target 5ms  interval 100ms
    tc qdisc add dev "$IFACE" parent 1:3 handle 30: fq_codel limit 1024 target 5ms  interval 100ms
    tc filter add dev "$IFACE" parent 1: protocol ip prio 1 u32 match u16 0x0000 0xfe00 at 2 flowid 1:1
    tc filter add dev "$IFACE" parent 1: protocol ip prio 2 u32 match u16 0x0000 0xfc00 at 2 flowid 1:2
    tc filter add dev "$IFACE" parent 1: protocol ip prio 3 u32 match u32 0x00000000 0x00000000 at 0 flowid 1:3
    info "QoS aplicado en $IFACE"
fi

echo ""
echo "================================================"
echo "  INSTALACION COMPLETA (Rust v4)"
echo "================================================"
echo "  PANEL URL:  http://${SERVER_IP}:${PANEL_PORT}"
echo "  TOKEN:      ${PANEL_TOKEN}"
echo "================================================"
systemctl is-active hev-socks5 btserver btpanel 2>/dev/null || true
ss -s | grep -E "TCP|estab"
