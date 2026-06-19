#!/bin/bash
set -e

PROJ=/opt/btserver/btsrc
mkdir -p "$PROJ/src/bin"

cat > "$PROJ/Cargo.toml" << 'TOMLEOF'
[package]
name    = "btserver"
version = "9.0.0"
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
    net::SocketAddr,
    os::unix::io::AsRawFd,
    sync::{
        atomic::{AtomicBool, AtomicI64, AtomicU32, Ordering},
        Arc,
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use anyhow::Result;
use bytes::{BufMut, Bytes, BytesMut};
use dashmap::DashMap;
use socket2::{Domain, Protocol, Socket, TcpKeepalive, Type};
use tokio::{
    fs,
    io::{AsyncReadExt, AsyncWriteExt},
    net::{
        tcp::{OwnedReadHalf, OwnedWriteHalf},
        TcpListener, TcpStream,
    },
    sync::mpsc,
    time,
};
use tracing::{info, warn};

const HEV_ADDR:             &str     = "127.0.0.1:1080";
const LISTEN_ADDR:          &str     = "0.0.0.0:80";
const KICK_ADDR:            &str     = "127.0.0.1:8091";
const USERS_FILE:           &str     = "/opt/btserver/users.txt";
const MAX_STREAMS:          usize    = 7000;
const MAX_PAYLOAD:          usize    = 16384;
const DIAL_TIMEOUT:         Duration = Duration::from_millis(800);
const HEV_CONN_TIMEOUT:     Duration = Duration::from_secs(5);
const HEV_WRITE_TIMEOUT:    Duration = Duration::from_secs(10);
const CLIENT_WRITE_TIMEOUT: Duration = Duration::from_secs(60);
const READ_DEADLINE:        Duration = Duration::from_secs(300);
const PAYLOAD_DEADLINE:     Duration = Duration::from_secs(60);

const T_OPEN:    u8 = 0x01;
const T_DATA:    u8 = 0x02;
const T_CLOSE:   u8 = 0x03;
const T_PING:    u8 = 0x04;
const T_PONG:    u8 = 0x05;
const T_KICK:    u8 = 0x06;
const T_EXPIRED: u8 = 0x07;

const WAIT_TIMEOUT:    Duration = Duration::from_secs(300);
const WAIT_MAX_PER_IP: usize    = 3;

fn valid_id(id: &str) -> bool {
    if let Some(rest) = id.strip_prefix("S-") {
        return rest.len() == 8 && rest.bytes().all(|b| b.is_ascii_alphanumeric());
    }
    if let Some(rest) = id.strip_prefix("STRK-") {
        return rest.len() == 48 && rest.bytes().all(|b| b.is_ascii_hexdigit());
    }
    false
}

type WaitRoom = Arc<DashMap<String, tokio::sync::oneshot::Sender<()>>>;
type IpCount  = Arc<DashMap<String, usize>>;

#[inline(always)]
fn now_secs() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() as i64
}

fn parse_expires(s: &str) -> Option<i64> {
    let s = s.trim();
    if let Ok(ts) = s.parse::<i64>() { return Some(ts); }
    let mut it = s.splitn(3, '-');
    let y: i64 = it.next()?.parse().ok()?;
    let m: i64 = it.next()?.parse().ok()?;
    let d: i64 = it.next()?.parse().ok()?;
    if y < 2000 || y > 2100 { return None; }
    let m2 = if m <= 2 { m + 12 } else { m };
    let y2 = if m <= 2 { y - 1 } else { y };
    let a  = y2 / 100;
    let b  = 2 - a + a / 4;
    let days = (365.25 * (y2 + 4716) as f64) as i64
        + (30.6001 * (m2 + 1) as f64) as i64
        + d + b - 1524 - 2440588;
    Some(days * 86400 + 86399)
}

enum AuthResult { Ok { name: String, secs_left: i64 }, NotFound, Expired }

async fn check_auth(id: &str) -> AuthResult {
    let Ok(content) = fs::read_to_string(USERS_FILE).await else {
        return AuthResult::NotFound;
    };
    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') { continue; }
        let mut parts = line.splitn(3, ':');
        let Some(uid)  = parts.next() else { continue };
        if uid != id { continue; }
        let Some(name) = parts.next() else { continue };
        let Some(exp)  = parts.next() else { continue };
        let Some(exp_ts) = parse_expires(exp) else { continue };
        let now = now_secs();
        if now > exp_ts { return AuthResult::Expired; }
        return AuthResult::Ok { name: name.to_string(), secs_left: exp_ts - now };
    }
    AuthResult::NotFound
}

#[inline(always)]
fn make_frame(typ: u8, sid: u32, payload: &[u8]) -> Bytes {
    let mut buf = BytesMut::with_capacity(7 + payload.len());
    buf.put_u8(typ);
    buf.put_u32(sid);
    buf.put_u16(payload.len() as u16);
    buf.put_slice(payload);
    buf.freeze()
}

fn tune_client_fd(fd: i32) {
    unsafe {
        let one: i32 = 1;
        libc::setsockopt(fd, libc::IPPROTO_TCP, libc::TCP_NODELAY, &one as *const _ as _, 4);
        libc::setsockopt(fd, libc::IPPROTO_TCP, libc::TCP_QUICKACK, &one as *const _ as _, 4);
        libc::setsockopt(fd, libc::SOL_SOCKET, libc::SO_KEEPALIVE, &one as *const _ as _, 4);
        
        let idle: i32 = 120;
        let intvl: i32 = 30;
        let cnt: i32 = 3;
        libc::setsockopt(fd, libc::IPPROTO_TCP, libc::TCP_KEEPIDLE, &idle as *const _ as _, 4);
        libc::setsockopt(fd, libc::IPPROTO_TCP, libc::TCP_KEEPINTVL, &intvl as *const _ as _, 4);
        libc::setsockopt(fd, libc::IPPROTO_TCP, libc::TCP_KEEPCNT, &cnt as *const _ as _, 4);
    }
}

fn tune_hev_fd(fd: i32) {
    unsafe {
        let one: i32 = 1;
        libc::setsockopt(fd, libc::IPPROTO_TCP, libc::TCP_NODELAY, &one as *const _ as _, 4);
        libc::setsockopt(fd, libc::IPPROTO_TCP, libc::TCP_QUICKACK, &one as *const _ as _, 4);
        libc::setsockopt(fd, libc::SOL_SOCKET, libc::SO_KEEPALIVE, &one as *const _ as _, 4);
        
        let idle: i32 = 300;
        let intvl: i32 = 60;
        let cnt: i32 = 5;
        libc::setsockopt(fd, libc::IPPROTO_TCP, libc::TCP_KEEPIDLE, &idle as *const _ as _, 4);
        libc::setsockopt(fd, libc::IPPROTO_TCP, libc::TCP_KEEPINTVL, &intvl as *const _ as _, 4);
        libc::setsockopt(fd, libc::IPPROTO_TCP, libc::TCP_KEEPCNT, &cnt as *const _ as _, 4);
    }
}

struct Stream {
    tx:       mpsc::Sender<Bytes>,
    closed:   AtomicBool,
    last_act: AtomicI64,
}

impl Stream {
    fn new(tx: mpsc::Sender<Bytes>) -> Arc<Self> {
        Arc::new(Self { tx, closed: AtomicBool::new(false), last_act: AtomicI64::new(now_secs()) })
    }
    #[inline(always)] fn touch(&self) { self.last_act.store(now_secs(), Ordering::Relaxed); }
    #[inline(always)] fn try_close(&self) -> bool { self.closed.compare_exchange(false, true, Ordering::AcqRel, Ordering::Relaxed).is_ok() }
    #[inline(always)] fn is_closed(&self) -> bool { self.closed.load(Ordering::Acquire) }
}

struct Mux {
    write_tx: mpsc::Sender<Bytes>,
    ctrl_tx:  mpsc::Sender<Bytes>,
    streams:  Arc<DashMap<u32, Arc<Stream>>>,
    count:    AtomicU32,
    dead:     AtomicBool,
}

impl Mux {
    fn new(write_tx: mpsc::Sender<Bytes>, ctrl_tx: mpsc::Sender<Bytes>) -> Arc<Self> {
        Arc::new(Self {
            write_tx, ctrl_tx,
            streams: Arc::new(DashMap::with_capacity(64)),
            count: AtomicU32::new(0),
            dead: AtomicBool::new(false),
        })
    }

    #[inline(always)] fn is_dead(&self) -> bool { self.dead.load(Ordering::Acquire) }

    #[inline(always)] fn get_stream_sync(&self, sid: u32) -> Option<Arc<Stream>> {
        self.streams.get(&sid).map(|r| r.clone())
    }

    #[inline(always)] fn send_data_sync(&self, sid: u32, data: &[u8]) {
        if self.is_dead() { return; }
        if self.write_tx.try_send(make_frame(T_DATA, sid, data)).is_err() {
            self.close_stream_sync(sid);
            let _ = self.ctrl_tx.try_send(make_frame(T_CLOSE, sid, &[]));
        }
    }

    #[inline(always)] fn send_ctrl_sync(&self, t: u8, sid: u32) {
        if !self.is_dead() { let _ = self.ctrl_tx.try_send(make_frame(t, sid, &[])); }
    }

    fn add_stream_sync(&self, sid: u32, s: Arc<Stream>) -> bool {
        if self.count.load(Ordering::Relaxed) as usize >= MAX_STREAMS { return false; }
        self.streams.insert(sid, s);
        self.count.fetch_add(1, Ordering::Relaxed);
        true
    }

    fn close_stream_sync(&self, sid: u32) {
        if let Some((_, s)) = self.streams.remove(&sid) {
            s.try_close();
            self.count.fetch_sub(1, Ordering::Relaxed);
        }
    }
}

type SessionMap = Arc<DashMap<String, Arc<Mux>>>;

fn kick_session_sync(sessions: &SessionMap, id: &str, reason: u8) -> bool {
    if let Some((_, mux)) = sessions.remove(id) {
        let _ = mux.ctrl_tx.try_send(make_frame(reason, 0, &[]));
        mux.dead.store(true, Ordering::Release);
        info!(id, reason, "session kicked");
        true
    } else { false }
}

async fn write_loop(
    mut writer:   OwnedWriteHalf,
    mut write_rx: mpsc::Receiver<Bytes>,
    mut ctrl_rx:  mpsc::Receiver<Bytes>,
    mux:          Arc<Mux>,
) {
    let mut buf = BytesMut::with_capacity(65536);
    loop {
        buf.clear();
        tokio::select! {
            biased;
            Some(f) = ctrl_rx.recv() => buf.extend_from_slice(&f),
            Some(f) = write_rx.recv() => buf.extend_from_slice(&f),
            else => break,
        }
        
        while let Ok(f) = ctrl_rx.try_recv() { buf.extend_from_slice(&f); }
        
        while buf.len() < 65536 {
            if let Ok(f) = write_rx.try_recv() { buf.extend_from_slice(&f); } else { break; }
        }

        if !matches!(time::timeout(CLIENT_WRITE_TIMEOUT, writer.write_all(&buf)).await, Ok(Ok(_))) { break; }
    }
    mux.dead.store(true, Ordering::Release);
}

async fn handle_stream(mux: Arc<Mux>, sid: u32, stream: Arc<Stream>, mut rx: mpsc::Receiver<Bytes>, first: Bytes) {
    let hev = match time::timeout(DIAL_TIMEOUT, TcpStream::connect(HEV_ADDR)).await {
        Ok(Ok(c)) => c,
        _ => { mux.close_stream_sync(sid); mux.send_ctrl_sync(T_CLOSE, sid); return; }
    };
    tune_hev_fd(hev.as_raw_fd());
    let (mut hev_r, mut hev_w) = hev.into_split();

    if !first.is_empty() {
        if time::timeout(HEV_CONN_TIMEOUT, hev_w.write_all(&first)).await.is_err() {
            mux.close_stream_sync(sid); mux.send_ctrl_sync(T_CLOSE, sid); return;
        }
    }

    let mux2 = mux.clone();
    let stream2 = stream.clone();

    let t_c2h = tokio::spawn(async move {
        while let Some(data) = rx.recv().await {
            stream2.touch();
            if !matches!(time::timeout(HEV_WRITE_TIMEOUT, hev_w.write_all(&data)).await, Ok(Ok(_))) { break; }
        }
        let _ = hev_w.shutdown().await;
    });

    let t_h2c = tokio::spawn(async move {
        let mut buf = vec![0u8; MAX_PAYLOAD];
        loop {
            match hev_r.read(&mut buf).await {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    stream.touch();
                    mux2.send_data_sync(sid, &buf[..n]);
                }
            }
        }
    });

    let _ = tokio::join!(t_c2h, t_h2c);
    mux.close_stream_sync(sid);
    mux.send_ctrl_sync(T_CLOSE, sid);
}

async fn mux_run(mux: Arc<Mux>, mut reader: OwnedReadHalf) {
    let mut hdr = [0u8; 7];
    let mut rbuf = vec![0u8; MAX_PAYLOAD];

    loop {
        if !matches!(time::timeout(READ_DEADLINE, reader.read_exact(&mut hdr)).await, Ok(Ok(_))) { break; }
        let ft  = hdr[0];
        let sid = u32::from_be_bytes(hdr[1..5].try_into().unwrap());
        let ln  = u16::from_be_bytes(hdr[5..7].try_into().unwrap()) as usize;
        
        if ln > MAX_PAYLOAD { break; }
        if ln > 0 {
            if !matches!(time::timeout(PAYLOAD_DEADLINE, reader.read_exact(&mut rbuf[..ln])).await, Ok(Ok(_))) { break; }
        }

        match ft {
            T_PING => mux.send_ctrl_sync(T_PONG, sid),
            T_OPEN => {
                let payload = if ln > 0 { Bytes::copy_from_slice(&rbuf[..ln]) } else { Bytes::new() };
                let (tx, rx) = mpsc::channel(1024);
                let s = Stream::new(tx);
                if !mux.add_stream_sync(sid, s.clone()) { mux.send_ctrl_sync(T_CLOSE, sid); continue; }
                tokio::spawn(handle_stream(mux.clone(), sid, s, rx, payload));
            }
            T_DATA => {
                if let Some(s) = mux.get_stream_sync(sid) {
                    if !s.is_closed() {
                        s.touch();
                        if s.tx.try_send(Bytes::copy_from_slice(&rbuf[..ln])).is_err() {
                            mux.close_stream_sync(sid); mux.send_ctrl_sync(T_CLOSE, sid);
                        }
                    }
                }
            }
            T_CLOSE => mux.close_stream_sync(sid),
            _ => {}
        }
    }

    let sids: Vec<u32> = mux.streams.iter().map(|r| *r.key()).collect();
    for sid in sids { mux.close_stream_sync(sid); }
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

async fn handle_conn(tcp: TcpStream, sessions: SessionMap, waitroom: WaitRoom, ip_count: IpCount) {
    tune_client_fd(tcp.as_raw_fd());
    let peer_ip = tcp.peer_addr().map(|a| a.ip().to_string()).unwrap_or_default();
    let mut buf = vec![0u8; 8192];
    let mut n = 0usize;
    let deadline = time::Instant::now() + Duration::from_secs(10);
    let (mut reader, mut writer) = tcp.into_split();

    loop {
        if time::Instant::now() > deadline || n >= buf.len() { return; }
        match reader.read(&mut buf[n..]).await {
            Ok(0) | Err(_) => return,
            Ok(nr) => {
                n += nr;
                let raw = &buf[..n];
                if raw.windows(7).any(|w| w.eq_ignore_ascii_case(b"action:")) && raw.windows(4).any(|w| w == b"\r\n\r\n") { break; }
            }
        }
    }

    let raw = &buf[..n];
    let action = extract_header(raw, b"action:");
    if action != Some("tunnel") && action != Some("tunnel-tcp") { return; }

    let user_id = match extract_header(raw, b"x-internal-id:").filter(|s| !s.is_empty()) {
        Some(id) => id.to_string(),
        None => return,
    };

    if !valid_id(&user_id) { return; }

    let resp_101 = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n";

    match check_auth(&user_id).await {
        AuthResult::Ok { name, secs_left } => {
            let resp = format!("{resp_101}X-User-Name: {name}\r\nX-User-Secs: {secs_left}\r\n\r\n");
            if writer.write_all(resp.as_bytes()).await.is_err() { return; }

            let (write_tx, write_rx) = mpsc::channel(1024);
            let (ctrl_tx,  ctrl_rx)  = mpsc::channel(256);
            let mux = Mux::new(write_tx, ctrl_tx);

            if let Some(prev_mux) = sessions.insert(user_id.clone(), mux.clone()) {
                let _ = prev_mux.ctrl_tx.try_send(make_frame(T_KICK, 0, &[]));
                prev_mux.dead.store(true, Ordering::Release);
                prev_mux.streams.clear();
            }

            tokio::spawn(write_loop(writer, write_rx, ctrl_rx, mux.clone()));
            mux_run(mux.clone(), reader).await;
            sessions.remove_if(&user_id, |_, m| Arc::ptr_eq(m, &mux));
            mux.streams.clear();
        }
        AuthResult::NotFound | AuthResult::Expired => {
            let ip_conns = ip_count.get(&peer_ip).map(|v| *v).unwrap_or(0);
            if ip_conns >= WAIT_MAX_PER_IP { return; }

            let status = match check_auth(&user_id).await { AuthResult::Expired => "expired", _ => "waiting" };
            let resp = format!("{resp_101}X-Wait-Status: {status}\r\n\r\n");
            if writer.write_all(resp.as_bytes()).await.is_err() { return; }

            wait_room(writer, reader, user_id, peer_ip, waitroom, ip_count).await;
        }
    }
}

async fn wait_room(mut writer: OwnedWriteHalf, mut reader: OwnedReadHalf, user_id: String, ip: String, waitroom: WaitRoom, ip_count: IpCount) {
    let (promote_tx, promote_rx) = tokio::sync::oneshot::channel::<()>();
    if let Some(prev_tx) = waitroom.insert(user_id.clone(), promote_tx) { let _ = prev_tx.send(()); }
    *ip_count.entry(ip.clone()).or_insert(0) += 1;

    let result = tokio::select! {
        _ = promote_rx => "promoted",
        _ = time::sleep(WAIT_TIMEOUT) => "timeout",
        _ = async {
            let mut drain = [0u8; 256];
            loop { if reader.read(&mut drain).await.is_err() || reader.read(&mut drain).await.unwrap_or(0) == 0 { break; } }
        } => "disconnected",
    };

    if result == "promoted" { let _ = writer.write_all(b"{\"status\":\"activated\"}\n").await; }
    waitroom.remove(&user_id);
    ip_count.entry(ip).and_modify(|c| { if *c > 0 { *c -= 1; } });
}

async fn memory_sweep(sessions: SessionMap) {
    loop {
        time::sleep(Duration::from_secs(300)).await;
        sessions.retain(|_, mux| {
            if mux.dead.load(Ordering::Acquire) { mux.streams.clear(); false } else { mux.streams.retain(|_, s| !s.is_closed()); true }
        });
    }
}

#[derive(Clone)] struct InternalState { sessions: SessionMap, waitroom: WaitRoom }

async fn kick_api(sessions: SessionMap, waitroom: WaitRoom) {
    use axum::{extract::{Query, State}, routing::get, Router};

    async fn kick_handler(State(s): State<InternalState>, Query(p): Query<HashMap<String, String>>) -> String {
        let Some(id) = p.get("id").filter(|id| !id.is_empty()) else { return "missing_id".into(); };
        let reason = if p.get("reason").map(|s| s.as_str()) == Some("expired") { T_EXPIRED } else { T_KICK };
        if kick_session_sync(&s.sessions, id, reason) { "kicked".into() } else { "not_connected".into() }
    }

    async fn active_handler(State(s): State<InternalState>) -> String {
        let ids: Vec<String> = s.sessions.iter().filter(|r| !r.value().dead.load(Ordering::Relaxed)).map(|r| r.key().clone()).collect();
        serde_json::json!({ "active": ids, "count": ids.len() }).to_string()
    }

    async fn promote_handler(State(s): State<InternalState>, Query(p): Query<HashMap<String, String>>) -> String {
        let Some(id) = p.get("id").filter(|id| !id.is_empty()) else { return "missing_id".into(); };
        if let Some((_, tx)) = s.waitroom.remove(id.as_str()) { let _ = tx.send(()); "promoted".into() } else { "not_waiting".into() }
    }

    let app = Router::new().route("/kick", get(kick_handler)).route("/active", get(active_handler)).route("/promote", get(promote_handler)).with_state(InternalState { sessions, waitroom });
    let ln = TcpListener::bind(KICK_ADDR).await.expect("kick bind");
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
            let reason = match check_auth(&id).await {
                AuthResult::Ok { .. } => continue,
                AuthResult::Expired   => T_EXPIRED,
                AuthResult::NotFound  => T_KICK,
            };
            kick_session_sync(&sessions, &id, reason);
            kicked += 1;
        }
        if kicked > 0 { info!("midnight sweep: kicked {kicked}"); }
    }
}

fn build_listener() -> std::io::Result<std::net::TcpListener> {
    let addr: SocketAddr = LISTEN_ADDR.parse().unwrap();
    let sock = Socket::new(Domain::IPV4, Type::STREAM, Some(Protocol::TCP))?;
    sock.set_reuse_address(true)?; sock.set_reuse_port(true)?; sock.set_nodelay(true)?;
    let ka = TcpKeepalive::new().with_time(Duration::from_secs(60)).with_interval(Duration::from_secs(10));
    sock.set_tcp_keepalive(&ka)?;
    unsafe { libc::setsockopt(sock.as_raw_fd(), libc::IPPROTO_TCP, libc::TCP_FASTOPEN, &1i32 as *const _ as _, 4); }
    sock.set_nonblocking(true)?; sock.bind(&addr.into())?; sock.listen(65535)?;
    Ok(sock.into())
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt().with_env_filter(tracing_subscriber::EnvFilter::from_default_env().add_directive("btserver=info".parse()?)).init();
    let sessions: SessionMap = Arc::new(DashMap::new());
    let waitroom: WaitRoom   = Arc::new(DashMap::new());
    let ip_count: IpCount    = Arc::new(DashMap::new());

    tokio::spawn(kick_api(sessions.clone(), waitroom.clone()));
    tokio::spawn(midnight_sweep(sessions.clone()));
    tokio::spawn(memory_sweep(sessions.clone()));

    let listener = TcpListener::from_std(build_listener()?).expect("tokio listener");
    info!("btserver v9 on {LISTEN_ADDR} → hev {HEV_ADDR}");

    loop {
        match listener.accept().await {
            Ok((conn, _)) => {
                tokio::spawn(handle_conn(conn, sessions.clone(), waitroom.clone(), ip_count.clone()));
            }
            Err(_) => {
                time::sleep(Duration::from_millis(50)).await;
            }
        }
    }
}
RSEOF

cat > "$PROJ/src/bin/panel.rs" << 'RSEOF'
use std::{collections::HashMap, net::SocketAddr, sync::Arc, time::{Duration, SystemTime, UNIX_EPOCH}};
use anyhow::Result;
use axum::{extract::{ConnectInfo, Query, State}, http::{HeaderMap, StatusCode}, routing::{delete, get, post, put}, Json, Router};
use serde::{Deserialize, Serialize};
use tokio::{fs, net::TcpListener, sync::Mutex};
use tracing::info;

const PANEL_ADDR: &str = "0.0.0.0:8090";
const USERS_PATH: &str = "/opt/btserver/users.txt";
const TOKEN_PATH: &str = "/opt/btserver/token.txt";
const KICK_BASE:  &str = "http://127.0.0.1:8091/kick?id=";
const PROMOTE_BASE: &str = "http://127.0.0.1:8091/promote?id=";

#[inline(always)] fn now_secs() -> i64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() as i64 }
fn expires_from_days(days: i64) -> i64 { now_secs() + days * 86400 }

fn migrate_date_to_ts(s: &str) -> Option<i64> {
    let mut it = s.trim().splitn(3, '-');
    let y: i64 = it.next()?.parse().ok()?; let m: i64 = it.next()?.parse().ok()?; let d: i64 = it.next()?.parse().ok()?;
    if y < 2000 || y > 2100 { return None; }
    let m2 = if m <= 2 { m + 12 } else { m }; let y2 = if m <= 2 { y - 1 } else { y };
    let a = y2 / 100; let b = 2 - a + a / 4;
    let days = (365.25 * (y2 + 4716) as f64) as i64 + (30.6001 * (m2 + 1) as f64) as i64 + d + b - 1524 - 2440588;
    Some(days * 86400 + 86399)
}

fn parse_expires(s: &str) -> i64 { if let Ok(ts) = s.trim().parse::<i64>() { ts } else { migrate_date_to_ts(s).unwrap_or(0) } }

#[derive(Clone)]
struct AppState {
    token:    Arc<String>,
    users_mu: Arc<Mutex<()>>,
    rate:     Arc<std::sync::Mutex<HashMap<String, Vec<i64>>>>,
}

impl AppState {
    async fn new() -> Self {
        let token = fs::read_to_string(TOKEN_PATH).await.unwrap_or_default().trim().to_string();
        Self { token: Arc::new(token), users_mu: Arc::new(Mutex::new(())), rate: Arc::new(std::sync::Mutex::new(HashMap::new())) }
    }

    fn rate_ok(&self, ip: &str) -> bool {
        let now = now_secs(); let mut map = self.rate.lock().unwrap();
        let hits = map.entry(ip.to_string()).or_default(); hits.retain(|&t| now - t < 60);
        if hits.len() >= 30 { return false; }
        hits.push(now); if map.len() > 1000 { map.clear(); }
        true
    }

    fn check_token(&self, headers: &HeaderMap) -> bool {
        headers.get("x-token").and_then(|v| v.to_str().ok()).map(|t| t.trim() == self.token.as_str()).unwrap_or(false)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)] struct User { name: String, expires_ts: i64 }

async fn load_users() -> HashMap<String, User> {
    let mut map = HashMap::new();
    if let Ok(c) = fs::read_to_string(USERS_PATH).await {
        for line in c.lines() {
            let line = line.trim(); if line.is_empty() || line.starts_with('#') { continue; }
            let mut p = line.splitn(3, ':');
            if let (Some(id), Some(name), Some(exp)) = (p.next().map(str::trim), p.next().map(str::trim), p.next().map(str::trim)) {
                if !id.is_empty() { map.insert(id.to_string(), User { name: name.to_string(), expires_ts: parse_expires(exp) }); }
            }
        }
    }
    map
}

async fn save_users(users: &HashMap<String, User>) {
    let tmp = format!("{USERS_PATH}.tmp"); let mut out = String::new();
    for (id, u) in users { out.push_str(&format!("{id}:{}:{}\n", u.name, u.expires_ts)); }
    if fs::write(&tmp, &out).await.is_ok() { let _ = fs::rename(&tmp, USERS_PATH).await; }
}

fn user_row(id: &str, u: &User) -> serde_json::Value {
    let secs_left = (u.expires_ts - now_secs()).max(0);
    serde_json::json!({ "id": id, "name": u.name, "expires_ts": u.expires_ts, "secs_left": secs_left, "active": secs_left > 0 })
}

async fn kick_user(id: String, reason: &'static str) {
    if let Ok(c) = reqwest::Client::builder().timeout(Duration::from_secs(2)).build() { let _ = c.get(format!("{KICK_BASE}{id}&reason={reason}")).send().await; }
}

async fn promote_user(id: String) {
    if let Ok(c) = reqwest::Client::builder().timeout(Duration::from_secs(2)).build() { let _ = c.get(format!("{PROMOTE_BASE}{id}")).send().await; }
}

type ApiResult = (StatusCode, Json<serde_json::Value>);
fn err_resp(code: StatusCode, msg: &str) -> ApiResult { (code, Json(serde_json::json!({"error": msg}))) }

fn auth_check(st: &AppState, headers: &HeaderMap, addr: &SocketAddr) -> Option<ApiResult> {
    if !st.rate_ok(&addr.ip().to_string()) { return Some(err_resp(StatusCode::TOO_MANY_REQUESTS, "too many requests")); }
    if !st.check_token(headers) { return Some(err_resp(StatusCode::UNAUTHORIZED, "unauthorized")); }
    None
}

async fn fetch_active_ids() -> std::collections::HashSet<String> {
    if let Ok(c) = reqwest::Client::builder().timeout(Duration::from_secs(2)).build() {
        if let Ok(resp) = c.get("http://127.0.0.1:8091/active").send().await {
            if let Ok(text) = resp.text().await {
                if let Ok(val) = serde_json::from_str::<serde_json::Value>(&text) {
                    return val["active"].as_array().map(|arr| arr.iter().filter_map(|v| v.as_str().map(String::from)).collect()).unwrap_or_default();
                }
            }
        }
    }
    Default::default()
}

async fn handle_clients(State(st): State<AppState>, headers: HeaderMap, ConnectInfo(addr): ConnectInfo<SocketAddr>) -> ApiResult {
    if let Some(e) = auth_check(&st, &headers, &addr) { return e; }
    let active = fetch_active_ids().await;
    let _l = st.users_mu.lock().await;
    let rows: Vec<_> = load_users().await.iter().map(|(id, u)| { let mut r = user_row(id, u); r["connected"] = serde_json::json!(active.contains(id.as_str())); r }).collect();
    (StatusCode::OK, Json(serde_json::json!({"clients":rows,"total":rows.len()})))
}

async fn handle_client(State(st): State<AppState>, headers: HeaderMap, ConnectInfo(addr): ConnectInfo<SocketAddr>, Query(p): Query<HashMap<String, String>>) -> ApiResult {
    if let Some(e) = auth_check(&st, &headers, &addr) { return e; }
    let id = p.get("id").map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).unwrap_or_default();
    if id.is_empty() { return err_resp(StatusCode::BAD_REQUEST, "falta id"); }
    let _l = st.users_mu.lock().await;
    if let Some(u) = load_users().await.get(&id) { (StatusCode::OK, Json(user_row(&id, u))) } else { err_resp(StatusCode::NOT_FOUND, "no encontrado") }
}

#[derive(Deserialize)] struct CreateBody { id: String, name: Option<String>, days: Option<i64> }

async fn handle_create(State(st): State<AppState>, headers: HeaderMap, ConnectInfo(addr): ConnectInfo<SocketAddr>, Json(body): Json<CreateBody>) -> ApiResult {
    if let Some(e) = auth_check(&st, &headers, &addr) { return e; }
    let id = body.id.trim().to_string(); if id.is_empty() { return err_resp(StatusCode::BAD_REQUEST, "falta id"); }
    let name = body.name.unwrap_or_default().trim().to_string(); let name = if name.is_empty() { "sin-nombre".to_string() } else { name };
    let days = body.days.unwrap_or(30).max(0); let _l = st.users_mu.lock().await;
    let mut users = load_users().await;
    if users.contains_key(&id) { return err_resp(StatusCode::CONFLICT, "ya existe"); }
    let expires_ts = expires_from_days(days);
    users.insert(id.clone(), User { name: name.clone(), expires_ts });
    save_users(&users).await; info!(id, name, days, "usuario creado"); tokio::spawn(promote_user(id.clone()));
    (StatusCode::CREATED, Json(user_row(&id, &User { name, expires_ts })))
}

#[derive(Deserialize)] struct IdBody { id: String }

async fn handle_delete(State(st): State<AppState>, headers: HeaderMap, ConnectInfo(addr): ConnectInfo<SocketAddr>, Json(body): Json<IdBody>) -> ApiResult {
    if let Some(e) = auth_check(&st, &headers, &addr) { return e; }
    let id = body.id.trim().to_string(); if id.is_empty() { return err_resp(StatusCode::BAD_REQUEST, "falta id"); }
    {
        let _l = st.users_mu.lock().await; let mut users = load_users().await;
        if !users.contains_key(&id) { return err_resp(StatusCode::NOT_FOUND, "no encontrado"); }
        users.remove(&id); save_users(&users).await;
    }
    info!(id, "usuario eliminado"); tokio::spawn(kick_user(id, "kicked"));
    (StatusCode::OK, Json(serde_json::json!({"ok":true})))
}

#[derive(Deserialize)] struct UpdateBody { id: String, name: Option<String>, new_id: Option<String>, days: Option<i64> }

async fn handle_update(State(st): State<AppState>, headers: HeaderMap, ConnectInfo(addr): ConnectInfo<SocketAddr>, Json(body): Json<UpdateBody>) -> ApiResult {
    if let Some(e) = auth_check(&st, &headers, &addr) { return e; }
    let id = body.id.trim().to_string(); if id.is_empty() { return err_resp(StatusCode::BAD_REQUEST, "falta id"); }
    let (final_id, u, kick_old) = {
        let _l = st.users_mu.lock().await; let mut users = load_users().await;
        let Some(mut u) = users.get(&id).cloned() else { return err_resp(StatusCode::NOT_FOUND, "no encontrado"); };
        if let Some(n) = body.name.as_deref().map(str::trim).filter(|s| !s.is_empty()) { u.name = n.to_string(); }
        if let Some(d) = body.days { u.expires_ts = expires_from_days(d.max(0)); }
        let (fid, ko) = match body.new_id.as_deref().map(str::trim) { Some(nid) if !nid.is_empty() && nid != id => { users.remove(&id); (nid.to_string(), true) } _ => (id.clone(), false) };
        users.insert(fid.clone(), u.clone()); save_users(&users).await; (fid, u, ko)
    };
    if kick_old { tokio::spawn(kick_user(id, "kicked")); }
    if u.expires_ts <= now_secs() { tokio::spawn(kick_user(final_id.clone(), "expired")); } else { tokio::spawn(promote_user(final_id.clone())); }
    info!(id = final_id, "usuario actualizado");
    (StatusCode::OK, Json(user_row(&final_id, &u)))
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt().with_env_filter(tracing_subscriber::EnvFilter::from_default_env().add_directive("panel=info".parse()?)).init();
    let app = Router::new().route("/clients", get(handle_clients)).route("/client", get(handle_client)).route("/client/create", post(handle_create)).route("/client/delete", delete(handle_delete)).route("/client/update", put(handle_update)).with_state(AppState::new().await).into_make_service_with_connect_info::<SocketAddr>();
    info!("panel api on {PANEL_ADDR}"); axum::serve(TcpListener::bind(PANEL_ADDR).await?, app).await?; Ok(())
}
RSEOF

cd "$PROJ"
cargo build --release
