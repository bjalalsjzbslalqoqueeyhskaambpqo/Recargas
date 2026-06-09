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

info "Instalando dependencias del sistema..."
apt-get update -qq --fix-missing 2>/dev/null || true
apt-get install -y -qq build-essential pkg-config libssl-dev 2>/dev/null \
    || die "No se pudo instalar build-essential"
info "build-essential OK"

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
version = "5.0.0"
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
dashmap            = "6"
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
use bytes::Bytes;
use crossbeam_queue::SegQueue;
use dashmap::DashMap;
use socket2::{Domain, Protocol, Socket, TcpKeepalive, Type};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{
        tcp::{OwnedReadHalf, OwnedWriteHalf},
        TcpListener, TcpStream,
    },
    sync::mpsc,
    time,
};
use tracing::{info, warn};

const HEV_ADDR:&str         = "127.0.0.1:1080";
const LISTEN_ADDR:&str     = "0.0.0.0:80";
const KICK_ADDR:&str       = "127.0.0.1:8091";
const USERS_FILE:&str      = "/opt/btserver/users.txt";
const MAX_STREAMS:usize    = 7000;
const QUEUE_SIZE:usize     = 64;
const MAX_PAYLOAD:usize    = 16384;
const DIAL_TIMEOUT:Duration        = Duration::from_millis(200);
const HEV_WRITE_TIMEOUT:Duration   = Duration::from_secs(2);
const CLIENT_WRITE_TIMEOUT:Duration= Duration::from_secs(30);
const STREAM_IDLE_TIMEOUT:i64     = 600;
const MUX_WRITE_QUEUE:usize       = 4096;
const CTRL_QUEUE:usize            = 256;
const MAX_BATCH:usize             = 128;
const READ_DEADLINE:Duration       = Duration::from_secs(120);
const PAYLOAD_DEADLINE:Duration    = Duration::from_secs(30);
const HEV_RCVBUF:i32      = 524288;
const HEV_SNDBUF:i32      = 524288;
const CLI_RCVBUF:i32      = 524288;
const CLI_SNDBUF:i32      = 524288;
const POOL_PREALLOC:usize = 8192;

const T_OPEN:u8    = 0x01;
const T_DATA:u8    = 0x02;
const T_CLOSE:u8   = 0x03;
const T_PING:u8     = 0x04;
const T_PONG:u8     = 0x05;
const T_KICK:u8     = 0x06;
const T_EXPIRED:u8  = 0x07;

static UTC_OFFSET: LazyLock<i64> = LazyLock::new(|| {
    let out = std::process::Command::new("date").arg("+%z").output()
        .ok().and_then(|o| String::from_utf8(o.stdout).ok()).unwrap_or_default();
    let s = out.trim();
    if s.len() < 5 { return 0; }
    let sign:i64 = if s.starts_with('-') { -1 } else { 1 };
    let h:i64 = s[1..3].parse().unwrap_or(0);
    let m:i64 = s[3..5].parse().unwrap_or(0);
    sign * (h * 3600 + m * 60)
});

#[inline(always)]
fn now_secs() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() as i64
}

enum AuthResult { Ok { name: String, days: i64 }, NotFound, Expired }

fn parse_old_date(s: &str) -> Option<i64> {
    let s = s.trim();
    let mut it = s.split('-');
    let y:i64 = it.next()?.parse().ok()?;
    let m:i64 = it.next()?.parse().ok()?;
    let d:i64 = it.next()?.parse().ok()?;
    let j = (1461 * (y + 4800 + (m - 14) / 12)) / 4 + (367 * (m - 2 - 12 * ((m - 14) / 12))) / 12 - (3 * ((y + 4900 + (m - 14) / 12) / 100)) / 4 + d - 32075;
    Some((j - 2440588) * 86400 + 86399)
}

fn check_auth(id: &str) -> AuthResult {
    let Ok(content) = std::fs::read_to_string(USERS_FILE) else {
        return AuthResult::NotFound;
    };
    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') { continue; }
        let mut parts = line.splitn(3, ':');
        let Some(uid) = parts.next() else { continue };
        let Some(name) = parts.next() else { continue };
        let Some(exp_str) = parts.next() else { continue };
        if uid != id { continue; }
        let exp_ts = match exp_str.parse::<i64>() {
            Ok(ts) => ts,
            Err(_) => match parse_old_date(exp_str) {
                Some(ts) => {
                    let new_line = format!("{}:{}:{}\n", uid, name, ts);
                    let _ = std::fs::write(USERS_FILE, &content.replace(line, &new_line.trim()));
                    ts
                }
                None => continue,
            }
        };
        let now = now_secs();
        if now > exp_ts { return AuthResult::Expired; }
        return AuthResult::Ok { name: name.to_string(), days: (exp_ts - now) / 86400 };
    }
    AuthResult::NotFound
}

#[derive(Clone)]
struct BufPool(Arc<SegQueue<Vec<u8>>>);

impl BufPool {
    fn new(prealloc: usize, cap: usize) -> Self {
        let q = SegQueue::new();
        for _ in 0..prealloc { q.push(Vec::with_capacity(cap)); }
        Self(Arc::new(q))
    }

    #[inline(always)]
    fn get(&self, needed: usize) -> Vec<u8> {
        if let Some(mut v) = self.0.pop() {
            v.clear();
            if v.capacity() >= needed { return v; }
        }
        Vec::with_capacity(needed.max(MAX_PAYLOAD + 7))
    }

    #[inline(always)]
    fn put(&self, mut v: Vec<u8>) {
        if v.capacity() <= (MAX_PAYLOAD + 7) * 2 {
            v.clear();
            self.0.push(v);
        }
    }

    #[inline(always)]
    fn write_hdr(v: &mut Vec<u8>, t: u8, sid: u32, len: u16) {
        let sid_b = sid.to_be_bytes();
        let len_b = len.to_be_bytes();
        unsafe {
            let p = v.as_mut_ptr().add(v.len());
            p.write(t);
            p.add(1).copy_from(sid_b.as_ptr(), 4);
            p.add(5).copy_from(len_b.as_ptr(), 2);
            let new_len = v.len() + 7;
            v.set_len(new_len);
        }
    }

    #[inline(always)]
    fn ctrl(&self, t: u8, sid: u32) -> Bytes {
        let mut v = self.get(7);
        Self::write_hdr(&mut v, t, sid, 0);
        Bytes::from(v)
    }

    #[inline(always)]
    fn data_frame(&self, sid: u32, payload: &[u8]) -> Bytes {
        let mut v = self.get(7 + payload.len());
        Self::write_hdr(&mut v, T_DATA, sid, payload.len() as u16);
        v.extend_from_slice(payload);
        Bytes::from(v)
    }
}

#[inline(always)]
unsafe fn setsockopt_i32(fd: i32, level: i32, opt: i32, val: i32) {
    libc::setsockopt(fd, level, opt,
      &val as *const i32 as *const libc::c_void,
        std::mem::size_of::<i32>() as libc::socklen_t);
}

fn tune_client_fd(fd: i32) {
    unsafe {
        setsockopt_i32(fd, libc::IPPROTO_TCP, libc::TCP_NODELAY, 1);
        setsockopt_i32(fd, libc::SOL_SOCKET,  libc::SO_RCVBUF,   CLI_RCVBUF);
        setsockopt_i32(fd, libc::SOL_SOCKET,  libc::SO_SNDBUF,   CLI_SNDBUF);
    }
}

fn tune_hev_fd(fd: i32) {
    unsafe {
        setsockopt_i32(fd, libc::IPPROTO_TCP, libc::TCP_NODELAY,   1);
        setsockopt_i32(fd, libc::SOL_SOCKET,  libc::SO_RCVBUF,     HEV_RCVBUF);
        setsockopt_i32(fd, libc::SOL_SOCKET,  libc::SO_SNDBUF,     HEV_SNDBUF);
        setsockopt_i32(fd, libc::SOL_SOCKET,  libc::SO_KEEPALIVE,  1);
        setsockopt_i32(fd, libc::IPPROTO_TCP, libc::TCP_KEEPIDLE,  30);
        setsockopt_i32(fd, libc::IPPROTO_TCP, libc::TCP_KEEPINTVL, 10);
        setsockopt_i32(fd, libc::IPPROTO_TCP, libc::TCP_KEEPCNT,   3);
    }
}

struct Stream {
    tx:       mpsc::Sender<Bytes>,
    closed:   AtomicBool,
    last_act: AtomicI64,
    workers:  AtomicI32,
}

impl Stream {
    fn new(tx: mpsc::Sender<Bytes>) -> Arc<Self> {
        Arc::new(Self {
            tx,
            closed:   AtomicBool::new(false),
            last_act: AtomicI64::new(now_secs()),
            workers:  AtomicI32::new(0),
        })
    }
    #[inline(always)] fn touch(&self) { self.last_act.store(now_secs(), Ordering::Relaxed); }
    #[inline(always)] fn idle_secs(&self) -> i64 { now_secs() - self.last_act.load(Ordering::Relaxed) }
    #[inline(always)] fn try_close(&self) -> bool {
        self.closed.compare_exchange(false, true, Ordering::AcqRel, Ordering::Relaxed).is_ok()
    }
    #[inline(always)] fn is_closed(&self) -> bool { self.closed.load(Ordering::Acquire) }
}

struct Mux {
    write_tx: mpsc::Sender<Bytes>,
    ctrl_tx:  mpsc::Sender<Bytes>,
    streams:  Arc<DashMap<u32, Arc<Stream>>>,
    count:    AtomicU32,
    dead:     AtomicBool,
    pool:     BufPool,
}

impl Mux {
    fn new(write_tx: mpsc::Sender<Bytes>, ctrl_tx: mpsc::Sender<Bytes>, pool: BufPool) -> Arc<Self> {
        Arc::new(Self {
            write_tx, ctrl_tx,
            streams: Arc::new(DashMap::with_capacity(128)),
            count:   AtomicU32::new(0),
            dead:    AtomicBool::new(false),
            pool,
        })
    }

    #[inline(always)] fn is_dead(&self) -> bool { self.dead.load(Ordering::Acquire) }

    #[inline(always)]
    fn get_stream(&self, sid: u32) -> Option<Arc<Stream>> {
        self.streams.get(&sid).map(|r| r.clone())
    }

    #[inline(always)]
    fn send_data(&self, sid: u32, data: &[u8]) {
        if self.is_dead() { return; }
        let frame = self.pool.data_frame(sid, data);
        if self.write_tx.try_send(frame).is_err() {
            self.close_stream(sid);
            let _ = self.ctrl_tx.try_send(self.pool.ctrl(T_CLOSE, sid));
        }
    }

    #[inline(always)]
    fn send_ctrl(&self, t: u8, sid: u32) {
        if self.is_dead() { return; }
        let _ = self.ctrl_tx.try_send(self.pool.ctrl(t, sid));
    }

    fn close_stream(&self, sid: u32) {
        if let Some(s) = self.get_stream(sid) {
            if s.try_close() {
                let _ = s.tx.try_send(Bytes::new());
            }
        }
    }

    fn close_all(&self) {
        for r in self.streams.iter() {
            let s = r.value();
            if s.try_close() {
                let _ = s.tx.try_send(Bytes::new());
            }
        }
    }
}

type SessionMap = Arc<DashMap<String, Arc<Mux>>>;

fn kick_session(sessions: &SessionMap, id: &str, reason: u8) -> bool {
    if let Some((_, mux)) = sessions.remove(id) {
        mux.close_all();
        let _ = mux.ctrl_tx.try_send(mux.pool.ctrl(reason, 0));
        mux.dead.store(true, Ordering::Release);
        info!(id, reason, "session kicked");
        true
    } else {
        false
    }
}

async fn idle_reaper(mux: Arc<Mux>) {
    let mut tick = time::interval(Duration::from_secs(60));
    loop {
        tick.tick().await;
        if mux.is_dead() { return; }

        let stale: Vec<u32> = mux.streams.iter()
            .filter(|r| {
                let s = r.value();
                s.workers.load(Ordering::Relaxed) == 0
                    && !s.is_closed()
                    && s.idle_secs() > STREAM_IDLE_TIMEOUT
            })
            .map(|r| *r.key())
            .collect();

        for sid in stale {
            mux.close_stream(sid);
            mux.send_ctrl(T_CLOSE, sid);
        }
    }
}

async fn mux_run(mux: Arc<Mux>, mut reader: OwnedReadHalf) {
    let mut hdr  = [0u8; 7];
    let mut rbuf = vec![0u8; MAX_PAYLOAD];

    loop {
        if mux.is_dead() { break; }

        match time::timeout(READ_DEADLINE, reader.read_exact(&mut hdr)).await {
            Ok(Ok(_)) => {}
            _ => break,
        }

        if mux.is_dead() { break; }

        let ft  = hdr[0];
        let sid = u32::from_be_bytes(hdr[1..5].try_into().unwrap());
        let ln  = u16::from_be_bytes(hdr[5..7].try_into().unwrap()) as usize;
        if ln > MAX_PAYLOAD { break; }

        if ln > 0 {
            match time::timeout(PAYLOAD_DEADLINE, reader.read_exact(&mut rbuf[..ln])).await {
                Ok(Ok(_)) => {}
                _ => break,
            }
        }

        if mux.is_dead() { break; }

        match ft {
            T_PING => { mux.send_ctrl(T_PONG, sid); }
            T_PONG => {}

            T_OPEN => {
                let (tx, rx) = mpsc::channel(QUEUE_SIZE);
                let stream = Stream::new(tx);

                {
                    mux.streams.insert(sid, stream.clone());
                }

                mux.send_ctrl(T_OPEN, sid);
                stream.workers.fetch_add(1, Ordering::Relaxed);
                stream.touch();
                if let Some(s) = mux.get_stream(sid) {
                    s.workers.fetch_sub(1, Ordering::Relaxed);
                }
            }

            T_DATA => {
                if let Some(s) = mux.get_stream(sid) {
                    if !s.is_closed() {
                        s.touch();
                        let _ = s.tx.try_send(Bytes::copy_from_slice(&rbuf[..ln]));
                    }
                }
            }

            T_CLOSE => { mux.close_stream(sid); }

            T_KICK | T_EXPIRED => {
                mux.dead.store(true, Ordering::Release);
                break;
            }

            _ => {}
        }
    }
}

async fn write_loop(
    mut writer:   OwnedWriteHalf,
    mut write_rx: mpsc::Receiver<Bytes>,
    mut ctrl_rx:  mpsc::Receiver<Bytes>,
    mux:          Arc<Mux>,
) {
    let mut buf = Vec::with_capacity(65536);

    loop {
        if mux.is_dead() { return; }

        tokio::select! {
            biased;

            Some(data) = ctrl_rx.recv() => {
                if data.is_empty() { return; }
                if writer.write_all(&data).await.is_err() { return; }
            }
            Some(data) = write_rx.recv() => {
                if data.is_empty() { return; }
                buf.extend_from_slice(&data);

                while buf.len() >= 7 {
                    let len = u16::from_be_bytes([buf[5], buf[6]]) as usize;
                    if buf.len() < 7 + len { break; }

                    let frame = buf.drain(..7 + len).collect::<Vec<_>>();
                    if writer.write_all(&frame).await.is_err() { return; }
                }
            }
            else => return,
        }
    }
}

async fn handle_conn(conn: TcpStream, sessions: SessionMap, pool: BufPool) {
    let (mut reader, mut writer) = conn.into_split();
    tune_client_fd(reader.as_ref().as_raw_fd());

    let mut buf = [0u8; 4096];
    match time::timeout(Duration::from_secs(10), reader.read(&mut buf)).await {
        Ok(Ok(n)) if n > 0 => {}
        _ => return,
    }

    let header = std::str::from_utf8(&buf).unwrap_or("");
    let mut path = "";
    let mut is_websocket = false;

    for line in header.lines() {
        if line.starts_with("GET ") {
            path = line.trim_start_matches("GET ").split_whitespace().next().unwrap_or("");
        }
        if line.to_lowercase().contains("upgrade: websocket") {
            is_websocket = true;
        }
    }

    if !is_websocket {
        let resp = "HTTP/1.1 400 Bad Request\r\n\r\n";
        let _ = writer.write_all(resp.as_bytes()).await;
        return;
    }

    let query = if let Some(q) = path.strip_prefix("/?auth=") {
        q.split('&').fold(HashMap::new(), |mut acc, pair| {
            if let Some((k, v)) = pair.split_once('=') {
                acc.insert(k.to_string(), v.to_string());
            }
            acc
        })
    } else {
        HashMap::new()
    };

    let Some(user_id) = query.get("auth").filter(|s| !s.is_empty()) else {
        let resp = "HTTP/1.1 401 Unauthorized\r\n\r\n";
        let _ = writer.write_all(resp.as_bytes()).await;
        return;
    };

    let (name, days) = match check_auth(user_id) {
        AuthResult::Ok { name, days } => (name, days),
        AuthResult::Expired => {
            let resp = "HTTP/1.1 403 Expired\r\nX-Reason: expired\r\n\r\n";
            let _ = writer.write_all(resp.as_bytes()).await;
            return;
        }
        AuthResult::NotFound => {
            let resp = "HTTP/1.1 404 Not Found\r\nX-Reason: not_found\r\n\r\n";
            let _ = writer.write_all(resp.as_bytes()).await;
            return;
        }
    };

    let resp = format!(
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nX-User-Name: {name}\r\nX-User-Days: {days}\r\n\r\n"
    );
    if writer.write_all(resp.as_bytes()).await.is_err() { return; }

    let (write_tx, write_rx) = mpsc::channel::<Bytes>(MUX_WRITE_QUEUE);
    let (ctrl_tx,  ctrl_rx)  = mpsc::channel::<Bytes>(CTRL_QUEUE);
    let mux = Mux::new(write_tx, ctrl_tx, pool);

    if let Some(prev_mux) = sessions.insert(user_id.clone(), mux.clone()) {
        let _ = prev_mux.ctrl_tx.try_send(prev_mux.pool.ctrl(T_KICK, 0));
        prev_mux.dead.store(true, Ordering::Release);
    }

    tokio::spawn(idle_reaper(mux.clone()));
    tokio::spawn(write_loop(writer, write_rx, ctrl_rx, mux.clone()));
    mux_run(mux.clone(), reader).await;

    sessions.remove_if(user_id.as_str(), |_, m| Arc::ptr_eq(m, &mux));
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
        if kick_session(&s, id, reason) { "kicked".into() } else { "not_connected".into() }
    }

    let app = Router::new()
        .route("/kick", get(kick_handler))
        .route("/active", get(|State(s): State<SessionMap>| async move {
            let ids: Vec<_> = s.iter().map(|r| r.key().clone()).collect();
            serde_json::to_string(&ids).unwrap_or_default()
        }))
        .with_state(sessions);
    let ln  = TcpListener::bind(KICK_ADDR).await.expect("kick bind");
    info!("kick api on {KICK_ADDR}");
    axum::serve(ln, app).await.expect("kick serve");
}

async fn midnight_sweep(sessions: SessionMap) {
    loop {
        let secs = 86400 - (now_secs() % 86400);
        time::sleep(Duration::from_secs(secs as u64)).await;
        let ids: Vec<String> = sessions.iter().map(|r| r.key().clone()).collect();
        let mut kicked = 0usize;
        for id in ids {
            let reason = match check_auth(&id) {
                AuthResult::Ok { .. } => continue,
                AuthResult::Expired   => T_EXPIRED,
                AuthResult::NotFound  => T_KICK,
            };
            kick_session(&sessions, &id, reason);
            kicked += 1;
        }
        if kicked > 0 { info!("midnight sweep: kicked {kicked}"); }
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

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::from_default_env()
                .add_directive("btserver=info".parse()?),
        )
        .init();

    let _ = *UTC_OFFSET;

    let sessions: SessionMap = Arc::new(DashMap::new());
    let pool = BufPool::new(POOL_PREALLOC, MAX_PAYLOAD + 7);

    tokio::spawn(kick_api(sessions.clone()));
    tokio::spawn(midnight_sweep(sessions.clone()));

    let std_ln   = build_listener().expect("listener");
    let listener = TcpListener::from_std(std_ln).expect("tokio listener");
    info!("btserver v5 on {LISTEN_ADDR} â†’ hev {HEV_ADDR}");

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
    response::IntoResponse,
    routing::{delete, get, post, put},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use tokio::net::TcpListener;
use tracing::info;

const PANEL_ADDR: &str  = "0.0.0.0:8090";
const USERS_PATH:&str   = "/opt/btserver/users.txt";
const TOKEN_PATH:&str    = "/opt/btserver/token.txt";
const KICK_BASE:&str    = "http://127.0.0.1:8091/kick?id=";
const ACTIVE_BASE:&str  = "http://127.0.0.1:8091/active";

static UTC_OFFSET: LazyLock<i64> = LazyLock::new(|| {
    let out = std::process::Command::new("date").arg("+%z").output()
        .ok().and_then(|o| String::from_utf8(o.stdout).ok()).unwrap_or_default();
    let s = out.trim();
    if s.len() < 5 { return 0; }
    let sign:i64 = if s.starts_with('-') { -1 } else { 1 };
    let h:i64 = s[1..3].parse().unwrap_or(0);
    let m:i64 = s[3..5].parse().unwrap_or(0);
    sign * (h * 3600 + m * 60)
});

#[inline(always)]
fn now_secs() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() as i64
}

fn days_from_now(d: i64) -> i64 { now_secs() + d * 86400 }

fn days_left(exp: &str) -> i64 {
    match exp.parse::<i64>() {
        Ok(ts) => ((ts - now_secs()) / 86400).max(0),
        _ => 0,
    }
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
struct User { name: String, expires: i64 }

fn parse_old_date(s: &str) -> Option<i64> {
    let s = s.trim();
    let mut it = s.split('-');
    let y:i64 = it.next()?.parse().ok()?;
    let m:i64 = it.next()?.parse().ok()?;
    let d:i64 = it.next()?.parse().ok()?;
    let j = (1461 * (y + 4800 + (m - 14) / 12)) / 4 + (367 * (m - 2 - 12 * ((m - 14) / 12))) / 12 - (3 * ((y + 4900 + (m - 14) / 12) / 100)) / 4 + d - 32075;
    Some((j - 2440588) * 86400 + 86399)
}

fn load_users() -> HashMap<String, User> {
    let Ok(c) = std::fs::read_to_string(USERS_PATH) else { return HashMap::new(); };
    let mut map = HashMap::new();
    for line in c.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') { continue; }
        let mut parts = line.splitn(3, ':');
        let Some(id) = parts.next().map(str::trim).filter(|s| !s.is_empty()) else { continue };
        let Some(name) = parts.next().map(str::trim) else { continue };
        let Some(exp) = parts.next().map(str::trim) else { continue };
        let exp_ts = match exp.parse::<i64>() {
            Ok(ts) => ts,
            Err(_) => {
                if let Some(ts) = parse_old_date(exp) {
                    let new_line = format!("{}:{}:{}", id, name, ts);
                    let _ = std::fs::write(USERS_PATH, &c.replace(line, &new_line));
                    ts
                } else {
                    continue;
                }
            }
        };
        map.insert(id.to_string(), User { name: name.to_string(), expires: exp_ts });
    }
    map
}

fn save_users(users: &HashMap<String, User>) {
    let tmp = format!("{USERS_PATH}.tmp");
    let mut out = String::from("# formato: id:nombre:expires_ts\n");
    for (id, u) in users {
        out.push_str(&format!("{id}:{}:{}\n", u.name, u.expires));
    }
    if std::fs::write(&tmp, &out).is_ok() {
        let _ = std::fs::rename(&tmp, USERS_PATH);
    }
}

fn user_row(id: &str, u: &User, active: bool) -> serde_json::Value {
    let dl = days_left(&u.expires.to_string());
    serde_json::json!({"id":id,"name":u.name,"expires":u.expires,"days_left":dl,"active":active})
}

async fn kick_user(id: String, reason: &'static str) {
    let url = format!("{KICK_BASE}{id}&reason={reason}");
    let Ok(c) = reqwest::Client::builder().timeout(Duration::from_secs(2)).build() else { return; };
    let _ = c.get(&url).send().await;
}

async fn get_active_ids() -> Vec<String> {
    let Ok(c) = reqwest::Client::builder().timeout(Duration::from_secs(2)).build() else {
        return vec![];
    };
    match c.get(ACTIVE_BASE).send().await {
        Ok(r) => r.json::<Vec<String>>().await.unwrap_or_default(),
        _ => vec![],
    }
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
) -> Result<(StatusCode, Json<serde_json::Value>), StatusCode> {
    if let Some(e) = auth_check(&st, &headers, &addr) { return Err(e.0); }
    let _l = st.users_mu.lock().unwrap();
    let users = load_users();
    let active_ids = get_active_ids().await;
    let active_set: std::collections::HashSet<_> = active_ids.iter().collect();
    let rows: Vec<_> = users.iter()
        .map(|(id, u)| user_row(id, u, active_set.contains(id)))
        .collect();
    Ok((StatusCode::OK, Json(serde_json::json!({"clients":rows,"total":rows.len(),"active_count":active_ids.len()}))))
}

async fn handle_client(
    State(st): State<AppState>,
    headers: HeaderMap,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Query(p): Query<HashMap<String, String>>,
) -> Result<(StatusCode, Json<serde_json::Value>), StatusCode> {
    if let Some(e) = auth_check(&st, &headers, &addr) { return Err(e.0); }
    let id = match p.get("id").map(|s| s.trim().to_string()).filter(|s| !s.is_empty()) {
        Some(id) => id,
        None => return Err(StatusCode::BAD_REQUEST),
    };
    let active_ids = get_active_ids().await;
    let _l = st.users_mu.lock().unwrap();
    match load_users().get(&id).cloned() {
        Some(u) => Ok((StatusCode::OK, Json(user_row(&id, &u, active_ids.iter().any(|x| x == &id))))),
        None    => Err(StatusCode::NOT_FOUND),
    }
}

#[derive(Deserialize)]
struct CreateBody { id: String, name: Option<String>, days: Option<i64> }

async fn handle_create(
    State(st): State<AppState>,
    headers: HeaderMap,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Json(body): Json<CreateBody>,
) -> Result<(StatusCode, Json<serde_json::Value>), StatusCode> {
    if let Some(e) = auth_check(&st, &headers, &addr) { return Err(e.0); }
    let id = body.id.trim().to_string();
    if id.is_empty() { return Err(StatusCode::BAD_REQUEST); }
    let name = body.name.as_deref().unwrap_or("").trim().to_string();
    let name = if name.is_empty() { "sin-nombre".to_string() } else { name };
    let days = body.days.unwrap_or(30);
    let expires = days_from_now(days);
    let _l = st.users_mu.lock().unwrap();
    let mut users = load_users();
    let was_active = users.contains_key(&id);
    users.insert(id.clone(), User { name: name.clone(), expires });
    save_users(&users);
    if was_active { tokio::spawn(kick_user(id.clone(), "replaced")); }
    Ok((StatusCode::OK, Json(serde_json::json!({"ok":true,"id":id,"name":name,"expires":expires,"days":days,"was_active":was_active})))
}

#[derive(Deserialize)]
struct IdBody { id: String }

async fn handle_delete(
    State(st): State<AppState>,
    headers: HeaderMap,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Json(body): Json<IdBody>,
) -> Result<(StatusCode, Json<serde_json::Value>), StatusCode> {
    if let Some(e) = auth_check(&st, &headers, &addr) { return Err(e.0); }
    let id = body.id.trim().to_string();
    if id.is_empty() { return Err(StatusCode::BAD_REQUEST); }
    {
        let _l = st.users_mu.lock().unwrap();
        let mut users = load_users();
        if !users.contains_key(&id) { return Err(StatusCode::NOT_FOUND); }
        users.remove(&id);
        save_users(&users);
    }
    tokio::spawn(kick_user(id, "kicked"));
    Ok((StatusCode::OK, Json(serde_json::json!({"ok":true})))
}

#[derive(Deserialize)]
struct UpdateBody {
    id: String,
    name: Option<String>,
    new_id: Option<String>,
    days: Option<i64>,
}

async fn handle_update(
    State(st): State<AppState>,
    headers: HeaderMap,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Json(body): Json<UpdateBody>,
) -> Result<(StatusCode, Json<serde_json::Value>), StatusCode> {
    if let Some(e) = auth_check(&st, &headers, &addr) { return Err(e.0); }
    let id = body.id.trim().to_string();
    if id.is_empty() { return Err(StatusCode::BAD_REQUEST); }

    let (final_id, u, kick_old) = {
        let _l = st.users_mu.lock().unwrap();
        let mut users = load_users();
        let Some(mut u) = users.get(&id).cloned() else {
            return Err(StatusCode::NOT_FOUND);
        };
        if let Some(n) = body.name.as_deref() {
            if !n.trim().is_empty() { u.name = n.trim().to_string(); }
        }
        if let Some(d) = body.days {
            u.expires = days_from_now(d);
        }

        let (final_id, kick_old) = if let Some(nid) = body.new_id.as_deref() {
            let nid = nid.trim().to_string();
            if !nid.is_empty() && nid != id {
                if users.contains_key(&nid) {
                    return Err(StatusCode::CONFLICT);
                }
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
        (final_id, u, kick_old)
    };

    if kick_old { tokio::spawn(kick_user(id, "replaced")); }
    if days_left(&u.expires.to_string()) <= 0 { tokio::spawn(kick_user(final_id.clone(), "expired")); }
    let active_ids = get_active_ids().await;
    let is_active = active_ids.iter().any(|x| x == &final_id);
    Ok((StatusCode::OK, Json(user_row(&final_id, &u, is_active))))
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

[ -f /opt/btserver/users.txt ] || printf '# formato: id:nombre:expires_ts\n' > /opt/btserver/users.txt

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
Description=BlackTunnel Server (Rust v5)
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
Description=BlackTunnel Panel (Rust v5)
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
echo "  INSTALACION COMPLETA (Rust v5)"
echo "================================================"
echo "  PANEL URL:  http://${SERVER_IP}:${PANEL_PORT}"
echo "  TOKEN:      ${PANEL_TOKEN}"
echo "================================================"
systemctl is-active hev-socks5 btserver btpanel 2>/dev/null || true
ss -s | grep -E "TCP|estab"
