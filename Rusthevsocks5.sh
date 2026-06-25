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
    collections::{HashMap, HashSet},
    net::SocketAddr,
    os::unix::io::AsRawFd,
    sync::{
        atomic::{AtomicBool, AtomicU32, Ordering},
        Arc,
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use anyhow::Result;
use bytes::Bytes;
use dashmap::DashMap;
use socket2::{Domain, Protocol, Socket, TcpKeepalive, Type};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{
        tcp::{OwnedReadHalf, OwnedWriteHalf},
        TcpListener, TcpStream,
    },
    sync::{mpsc, watch},
    time,
};
use tracing::subscriber;

const HEV_ADDR:      &str = "127.0.0.1:1080";
const LISTEN_ADDR:   &str = "0.0.0.0:80";
const KICK_ADDR:     &str = "127.0.0.1:8091";
const USERS_FILE:    &str = "/opt/btserver/users.txt";

const MAX_STREAMS:     usize = 10000;
const MAX_PAYLOAD:     usize = 32768;
const WAIT_TIMEOUT:    Duration = Duration::from_secs(300);
const WAIT_MAX_PER_IP: usize = 3;

const OP_PING:       u8 = 0x10;
const OP_PONG:       u8 = 0x11;
const OP_STRM_OPEN:  u8 = 0x12;
const OP_STRM_DATA:  u8 = 0x13;
const OP_STRM_CLOSE: u8 = 0x14;
const OP_SYNC_STATE: u8 = 0x15;
const OP_SYNC_RST:   u8 = 0x16;
const OP_KICK:       u8 = 0x18;
const OP_EXPIRED:    u8 = 0x19;

const TCP_QUICKACK: i32 = 12;

#[derive(Clone, Copy, PartialEq)]
enum TunnelMode {
    Normal,
    Gaming,
}

fn maximize_fd_limit() {
    unsafe {
        let mut rl = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
        if libc::getrlimit(libc::RLIMIT_NOFILE, &mut rl) == 0 {
            rl.rlim_cur = rl.rlim_max;
            libc::setrlimit(libc::RLIMIT_NOFILE, &rl);
        }
    }
}

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

fn check_auth_blocking(id: &str) -> AuthResult {
    let Ok(content) = std::fs::read_to_string(USERS_FILE) else { return AuthResult::NotFound; };
    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') { continue; }
        let mut parts = line.splitn(3, ':');
        let Some(uid)  = parts.next() else { continue };
        let Some(name) = parts.next() else { continue };
        let Some(exp)  = parts.next() else { continue };
        if uid != id { continue; }
        let Some(exp_ts) = parse_expires(exp) else { continue };
        let now = now_secs();
        if now > exp_ts { return AuthResult::Expired; }
        return AuthResult::Ok { name: name.to_string(), secs_left: exp_ts - now };
    }
    AuthResult::NotFound
}

async fn check_auth(id: String) -> AuthResult {
    tokio::task::spawn_blocking(move || check_auth_blocking(&id))
        .await
        .unwrap_or(AuthResult::NotFound)
}

#[inline(always)]
fn build_frame(op: u8, flags: u8, sid: u32, payload: &[u8]) -> Bytes {
    let mut v = Vec::with_capacity(8 + payload.len());
    v.push(op);
    v.push(flags);
    v.extend_from_slice(&sid.to_be_bytes());
    v.extend_from_slice(&(payload.len() as u16).to_be_bytes());
    if !payload.is_empty() {
        v.extend_from_slice(payload);
    }
    Bytes::from(v)
}

#[inline(always)]
unsafe fn setsockopt_i32(fd: i32, level: i32, opt: i32, val: i32) {
    libc::setsockopt(fd, level, opt, &val as *const i32 as *const libc::c_void, 4);
}

fn tune_client_fd(fd: i32, mode: TunnelMode) {
    unsafe {
        if mode == TunnelMode::Gaming {
            setsockopt_i32(fd, libc::IPPROTO_TCP, libc::TCP_NODELAY, 1);
            setsockopt_i32(fd, libc::IPPROTO_TCP, TCP_QUICKACK, 1);
        } else {
            setsockopt_i32(fd, libc::IPPROTO_TCP, libc::TCP_NODELAY, 0);
        }
        
        let timeout: i32 = 15000;
        libc::setsockopt(fd, libc::IPPROTO_TCP, 18, &timeout as *const _ as _, 4);

        setsockopt_i32(fd, libc::SOL_SOCKET,  libc::SO_KEEPALIVE, 1);
        setsockopt_i32(fd, libc::IPPROTO_TCP, libc::TCP_KEEPIDLE, 15);
        setsockopt_i32(fd, libc::IPPROTO_TCP, libc::TCP_KEEPINTVL, 5);
        setsockopt_i32(fd, libc::IPPROTO_TCP, libc::TCP_KEEPCNT,   3);
    }
}

fn tune_hev_fd(fd: i32, mode: TunnelMode) {
    unsafe {
        if mode == TunnelMode::Gaming {
            setsockopt_i32(fd, libc::IPPROTO_TCP, libc::TCP_NODELAY, 1);
            setsockopt_i32(fd, libc::IPPROTO_TCP, TCP_QUICKACK, 1);
        } else {
            setsockopt_i32(fd, libc::IPPROTO_TCP, libc::TCP_NODELAY, 0);
        }
        
        let linger = libc::linger { l_onoff: 1, l_linger: 0 };
        libc::setsockopt(fd, libc::SOL_SOCKET, libc::SO_LINGER, &linger as *const _ as _, std::mem::size_of::<libc::linger>() as libc::socklen_t);
    }
}

fn get_rtt_us(fd: i32) -> u32 {
    unsafe {
        let mut info: libc::tcp_info = std::mem::zeroed();
        let mut len = std::mem::size_of::<libc::tcp_info>() as libc::socklen_t;
        if libc::getsockopt(fd, libc::IPPROTO_TCP, libc::TCP_INFO, &mut info as *mut _ as *mut libc::c_void, &mut len) == 0 {
            info.tcpi_rtt
        } else { 0 }
    }
}

struct Stream {
    tx:     mpsc::Sender<Bytes>,
    closed: AtomicBool,
}

impl Stream {
    fn new(tx: mpsc::Sender<Bytes>) -> Arc<Self> {
        Arc::new(Self { tx, closed: AtomicBool::new(false) })
    }
    #[inline(always)] fn try_close(&self) -> bool {
        self.closed.compare_exchange(false, true, Ordering::AcqRel, Ordering::Relaxed).is_ok()
    }
    #[inline(always)] fn is_closed(&self) -> bool { self.closed.load(Ordering::Acquire) }
}

struct LinkMux {
    write_tx: mpsc::Sender<Bytes>,
    ctrl_tx:  mpsc::Sender<Bytes>,
    kill_tx:  watch::Sender<bool>,
    streams:  Arc<DashMap<u32, Arc<Stream>>>,
    count:    AtomicU32,
    dead:     AtomicBool,
    rtt_us:   AtomicU32,
}

impl LinkMux {
    fn new(write_tx: mpsc::Sender<Bytes>, ctrl_tx: mpsc::Sender<Bytes>) -> Arc<Self> {
        let (kill_tx, _) = watch::channel(false);
        Arc::new(Self {
            write_tx, ctrl_tx, kill_tx,
            streams: Arc::new(DashMap::with_capacity(32)),
            count:   AtomicU32::new(0),
            dead:    AtomicBool::new(false),
            rtt_us:  AtomicU32::new(0),
        })
    }

    #[inline(always)] fn kill(&self) {
        if self.dead.compare_exchange(false, true, Ordering::AcqRel, Ordering::Relaxed).is_ok() {
            let _ = self.kill_tx.send(true);
            self.streams.clear();
        }
    }

    #[inline(always)] fn is_dead(&self) -> bool { self.dead.load(Ordering::Acquire) }

    #[inline(always)] fn has_stream_sync(&self, sid: u32) -> bool {
        self.streams.contains_key(&sid)
    }

    #[inline(always)] fn get_stream_sync(&self, sid: u32) -> Option<Arc<Stream>> {
        self.streams.get(&sid).map(|r| r.clone())
    }

    #[inline(always)] async fn send_data_async(&self, sid: u32, data: &[u8]) -> bool {
        if self.is_dead() { return false; }
        if self.write_tx.send(build_frame(OP_STRM_DATA, 0, sid, data)).await.is_err() {
            self.close_stream_sync(sid);
            self.send_ctrl_async(OP_STRM_CLOSE, sid).await;
            return false;
        }
        true
    }

    #[inline(always)] async fn send_ctrl_async(&self, op: u8, sid: u32) {
        if self.is_dead() { return; }
        let _ = self.ctrl_tx.send(build_frame(op, 0, sid, &[])).await;
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

type SessionMap = Arc<DashMap<String, Arc<LinkMux>>>;

fn kick_session_sync(sessions: &SessionMap, id: &str, reason: u8) -> bool {
    if let Some((_, mux)) = sessions.remove(id) {
        let _ = mux.ctrl_tx.try_send(build_frame(reason, 0, 0, &[]));
        mux.kill();
        true
    } else {
        false
    }
}

async fn write_loop(
    mut writer:   OwnedWriteHalf,
    mut write_rx: mpsc::Receiver<Bytes>,
    mut ctrl_rx:  mpsc::Receiver<Bytes>,
    mut kill_rx:  watch::Receiver<bool>,
    mux:          Arc<LinkMux>,
) {
    let mut buf = bytes::BytesMut::with_capacity(32768);

    loop {
        buf.clear();
        if buf.capacity() > 131072 {
            buf = bytes::BytesMut::with_capacity(32768);
        }

        tokio::select! {
            biased;
            _ = kill_rx.changed() => break,
            frame = ctrl_rx.recv() => {
                let Some(f) = frame else { break; };
                buf.extend_from_slice(&f);
                while let Ok(f) = ctrl_rx.try_recv() { buf.extend_from_slice(&f); }
            }
            frame = write_rx.recv() => {
                let Some(f) = frame else { break; };
                buf.extend_from_slice(&f);
                while let Ok(f) = write_rx.try_recv() { buf.extend_from_slice(&f); }
            }
        }

        if buf.is_empty() { continue; }
        if writer.write_all(&buf).await.is_err() { break; }
    }
    mux.kill();
}

async fn handle_stream(
    mux:    Arc<LinkMux>,
    sid:    u32,
    _stream: Arc<Stream>,
    mut rx: mpsc::Receiver<Bytes>,
    first:  Bytes,
    mode:   TunnelMode,
) {
    let mut kill_rx1 = mux.kill_tx.subscribe();
    let mut kill_rx2 = mux.kill_tx.subscribe();

    let Ok(Ok(hev)) = time::timeout(Duration::from_millis(10000), TcpStream::connect(HEV_ADDR)).await else {
        mux.close_stream_sync(sid);
        mux.send_ctrl_async(OP_STRM_CLOSE, sid).await;
        return;
    };
    
    tune_hev_fd(hev.as_raw_fd(), mode);
    let (mut hev_r, mut hev_w) = hev.into_split();

    if !first.is_empty() {
        if hev_w.write_all(&first).await.is_err() {
            mux.close_stream_sync(sid);
            mux.send_ctrl_async(OP_STRM_CLOSE, sid).await;
            return;
        }
    }

    let (close_tx, _) = watch::channel(false);
    let mut close_rx_c2h = close_tx.subscribe();
    let close_tx_h2c = close_tx.clone();

    let mux2 = mux.clone();

    let t_c2h = tokio::spawn(async move {
        loop {
            tokio::select! {
                biased;
                _ = kill_rx1.changed() => break,
                _ = close_rx_c2h.changed() => break,
                data = rx.recv() => {
                    match data {
                        Some(data) => { 
                            if hev_w.write_all(&data).await.is_err() { 
                                break; 
                            }
                        }
                        None => break,
                    }
                }
            }
        }
        let _ = hev_w.shutdown().await;
    });

    let t_h2c = tokio::spawn(async move {
        let mut buf = vec![0u8; 32768];
        loop {
            let rtt = mux2.rtt_us.load(Ordering::Relaxed);
            let mut limit = if mode == TunnelMode::Gaming { 4096 } else { 32768 };
            
            if rtt > 200_000 { limit = std::cmp::min(limit, 16384); }
            if rtt > 400_000 { limit = std::cmp::min(limit, 8192);  }
            if rtt > 800_000 { limit = std::cmp::min(limit, 4096);  }

            tokio::select! {
                biased;
                _ = kill_rx2.changed() => break,
                res = hev_r.read(&mut buf[..limit]) => {
                    match res {
                        Ok(0) | Err(_) => break,
                        Ok(n) => { 
                            if !mux2.send_data_async(sid, &buf[..n]).await { break; } 
                        }
                    }
                }
            }
        }
        let _ = close_tx_h2c.send(true);
    });

    let _ = tokio::join!(t_c2h, t_h2c);
    mux.close_stream_sync(sid);
    mux.send_ctrl_async(OP_STRM_CLOSE, sid).await;
}

async fn mux_run(mux: Arc<LinkMux>, mut reader: OwnedReadHalf, mode: TunnelMode) {
    let mut hdr  = [0u8; 8];
    let mut rbuf = vec![0u8; MAX_PAYLOAD];
    let mut kill_rx = mux.kill_tx.subscribe();

    loop {
        tokio::select! {
            biased;
            _ = kill_rx.changed() => break,
            res = reader.read_exact(&mut hdr) => { if res.is_err() { break; } }
        }

        let op    = hdr[0];
        let _flag = hdr[1];
        let sid   = u32::from_be_bytes(hdr[2..6].try_into().unwrap());
        let ln    = u16::from_be_bytes(hdr[6..8].try_into().unwrap()) as usize;
        
        if ln > MAX_PAYLOAD { break; }

        if ln > 0 {
            tokio::select! {
                biased;
                _ = kill_rx.changed() => break,
                res = reader.read_exact(&mut rbuf[..ln]) => { if res.is_err() { break; } }
            }
        }

        match op {
            OP_PING => { mux.send_ctrl_async(OP_PONG, 0).await; }
            OP_PONG => {}
            OP_SYNC_STATE => {
                let client_sids: HashSet<u32> = rbuf[..ln]
                    .chunks_exact(4)
                    .map(|c| u32::from_be_bytes(c.try_into().unwrap()))
                    .collect();
                
                let local_sids: Vec<u32> = mux.streams.iter().map(|r| *r.key()).collect();
                
                for local_sid in local_sids {
                    if !client_sids.contains(&local_sid) {
                        mux.close_stream_sync(local_sid);
                    }
                }
                for client_sid in client_sids {
                    if !mux.has_stream_sync(client_sid) {
                        mux.send_ctrl_async(OP_SYNC_RST, client_sid).await;
                    }
                }
            }
            OP_STRM_OPEN => {
                if mux.has_stream_sync(sid) {
                    continue;
                }
                let payload = if ln > 0 { Bytes::copy_from_slice(&rbuf[..ln]) } else { Bytes::new() };
                let queue_size = if mode == TunnelMode::Gaming { 64 } else { 512 };
                let (tx, rx) = mpsc::channel(queue_size);
                let s = Stream::new(tx);
                if !mux.add_stream_sync(sid, s.clone()) {
                    mux.send_ctrl_async(OP_STRM_CLOSE, sid).await;
                    continue;
                }
                tokio::spawn(handle_stream(mux.clone(), sid, s, rx, payload, mode));
            }
            OP_STRM_DATA => {
                if let Some(s) = mux.get_stream_sync(sid) {
                    if !s.is_closed() {
                        let payload = Bytes::copy_from_slice(&rbuf[..ln]);
                        if s.tx.try_send(payload).is_err() {
                            mux.close_stream_sync(sid);
                            mux.send_ctrl_async(OP_STRM_CLOSE, sid).await;
                        }
                    }
                } else {
                    mux.send_ctrl_async(OP_SYNC_RST, sid).await;
                }
            }
            OP_STRM_CLOSE | OP_SYNC_RST => { mux.close_stream_sync(sid); }
            _ => { break; }
        }
    }
    mux.kill();
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
    let peer_ip = tcp.peer_addr().map(|a| a.ip().to_string()).unwrap_or_default();
    let mut buf = vec![0u8; 8192];
    let mut n   = 0usize;
    let deadline = time::Instant::now() + Duration::from_secs(10);
    
    let fd = tcp.as_raw_fd();
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
    let action_str = extract_header(raw, b"action:");
    
    let mode = match action_str {
        Some("tunnel-gaming") => TunnelMode::Gaming,
        Some("tunnel") | Some("tunnel-tcp") => TunnelMode::Normal,
        _ => return,
    };

    tune_client_fd(fd, mode);

    let user_id = match extract_header(raw, b"x-internal-id:").filter(|s| !s.is_empty()) {
        Some(id) => id.to_string(),
        None => return,
    };

    if !valid_id(&user_id) { return; }

    let resp_101 = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n";

    match check_auth(user_id.clone()).await {
        AuthResult::Ok { name, secs_left } => {
            let resp = format!("{resp_101}X-User-Name: {name}\r\nX-User-Secs: {secs_left}\r\n\r\n");
            if writer.write_all(resp.as_bytes()).await.is_err() { return; }

            let mux_write_queue = if mode == TunnelMode::Gaming { 64 } else { 512 };
            let (write_tx, write_rx) = mpsc::channel::<Bytes>(mux_write_queue);
            let ctrl_queue = if mode == TunnelMode::Gaming { 32 } else { 128 };
            let (ctrl_tx,  ctrl_rx)  = mpsc::channel::<Bytes>(ctrl_queue);
            
            let mux = LinkMux::new(write_tx, ctrl_tx);
            let kill_rx = mux.kill_tx.subscribe();

            if let Some((_, prev_mux)) = sessions.remove(&user_id) {
                let _ = prev_mux.ctrl_tx.try_send(build_frame(OP_KICK, 0, 0, &[]));
                prev_mux.kill();
            }

            sessions.insert(user_id.clone(), mux.clone());

            let mut kill_rx3 = mux.kill_tx.subscribe();
            let mux_clone_metrics = mux.clone();
            tokio::spawn(async move {
                let mut ticker = time::interval(Duration::from_secs(2));
                loop {
                    tokio::select! {
                        biased;
                        _ = kill_rx3.changed() => break,
                        _ = ticker.tick() => {
                            let rtt = get_rtt_us(fd);
                            mux_clone_metrics.rtt_us.store(rtt, Ordering::Relaxed);
                        }
                    }
                }
            });

            tokio::spawn(write_loop(writer, write_rx, ctrl_rx, kill_rx, mux.clone()));
            mux_run(mux.clone(), reader, mode).await;
            sessions.remove_if(&user_id, |_, m| Arc::ptr_eq(m, &mux));
            mux.kill();
        }
        AuthResult::NotFound | AuthResult::Expired => {
            let ip_conns = ip_count.get(&peer_ip).map(|v| *v).unwrap_or(0);
            if ip_conns >= WAIT_MAX_PER_IP { return; }
            let status = match check_auth(user_id.clone()).await { AuthResult::Expired => "expired", _ => "waiting" };
            let resp = format!("{resp_101}X-Wait-Status: {status}\r\n\r\n");
            if writer.write_all(resp.as_bytes()).await.is_err() { return; }
            wait_room(writer, reader, user_id, peer_ip, waitroom, ip_count).await;
        }
    }
}

async fn wait_room(mut writer: OwnedWriteHalf, mut reader: OwnedReadHalf, user_id: String, ip: String, waitroom: WaitRoom, ip_count: IpCount) {
    let activated_msg = b"{\"status\":\"activated\"}\n";
    let (promote_tx, promote_rx) = tokio::sync::oneshot::channel::<()>();
    if let Some(prev_tx) = waitroom.insert(user_id.clone(), promote_tx) { let _ = prev_tx.send(()); }
    *ip_count.entry(ip.clone()).or_insert(0) += 1;

    let result = tokio::select! {
        _ = promote_rx => "promoted",
        _ = time::sleep(WAIT_TIMEOUT) => "timeout",
        _ = async {
            let mut drain = [0u8; 256];
            loop { if reader.read(&mut drain).await.unwrap_or(0) == 0 { break; } }
        } => "disconnected",
    };

    if result == "promoted" { let _ = writer.write_all(activated_msg).await; }
    waitroom.remove(&user_id);
    ip_count.entry(ip).and_modify(|c| { if *c > 0 { *c -= 1; } });
}

#[derive(Clone)] struct InternalState { sessions: SessionMap, waitroom: WaitRoom }

async fn kick_api(sessions: SessionMap, waitroom: WaitRoom) {
    use axum::{extract::{Query, State}, routing::get, Router};
    async fn kick_handler(State(s): State<InternalState>, Query(p): Query<HashMap<String, String>>) -> String {
        let Some(id) = p.get("id").filter(|id| !id.is_empty()) else { return "missing_id".into(); };
        let reason = if p.get("reason").map(|s| s.as_str()) == Some("expired") { OP_EXPIRED } else { OP_KICK };
        if kick_session_sync(&s.sessions, id, reason) { "kicked".into() } else { "not_connected".into() }
    }
    async fn active_handler(State(s): State<InternalState>) -> String {
        let ids: Vec<String> = s.sessions.iter().filter(|r| !r.value().is_dead()).map(|r| r.key().clone()).collect();
        serde_json::json!({ "active": ids, "count": ids.len() }).to_string()
    }
    async fn promote_handler(State(s): State<InternalState>, Query(p): Query<HashMap<String, String>>) -> String {
        let Some(id) = p.get("id").filter(|id| !id.is_empty()) else { return "missing_id".into(); };
        if let Some((_, tx)) = s.waitroom.remove(id.as_str()) { let _ = tx.send(()); "promoted".into() } else { "not_waiting".into() }
    }
    let state = InternalState { sessions, waitroom };
    let app = Router::new().route("/kick", get(kick_handler)).route("/active", get(active_handler)).route("/promote", get(promote_handler)).with_state(state);
    let ln = TcpListener::bind(KICK_ADDR).await.expect("kick bind");
    axum::serve(ln, app).await.expect("kick serve");
}

async fn session_monitor(sessions: SessionMap) {
    loop {
        time::sleep(Duration::from_secs(60)).await;
        let ids: Vec<String> = sessions.iter().map(|r| r.key().clone()).collect();
        for id in ids {
            match check_auth(id.clone()).await {
                AuthResult::Ok { .. } => continue,
                AuthResult::Expired => { kick_session_sync(&sessions, &id, OP_EXPIRED); }
                AuthResult::NotFound => { kick_session_sync(&sessions, &id, OP_KICK); }
            }
        }
    }
}

fn build_listener() -> std::io::Result<std::net::TcpListener> {
    let addr: SocketAddr = LISTEN_ADDR.parse().unwrap();
    let sock = Socket::new(Domain::IPV4, Type::STREAM, Some(Protocol::TCP))?;
    sock.set_reuse_address(true)?; sock.set_reuse_port(true)?; sock.set_nodelay(true)?;
    
    let ka = TcpKeepalive::new().with_time(Duration::from_secs(15)).with_interval(Duration::from_secs(5));
    sock.set_tcp_keepalive(&ka)?;
    
    unsafe { libc::setsockopt(sock.as_raw_fd(), libc::IPPROTO_TCP, libc::TCP_FASTOPEN, &1i32 as *const _ as _, 4); }
    sock.set_nonblocking(true)?; sock.bind(&addr.into())?; sock.listen(65535)?;
    Ok(sock.into())
}

#[tokio::main]
async fn main() -> Result<()> {
    maximize_fd_limit();
    tracing_subscriber::fmt().with_env_filter(tracing_subscriber::EnvFilter::from_default_env().add_directive("btserver=info".parse()?)).init();
    let sessions: SessionMap = Arc::new(DashMap::new());
    let waitroom: WaitRoom   = Arc::new(DashMap::new());
    let ip_count: IpCount    = Arc::new(DashMap::new());
    tokio::spawn(kick_api(sessions.clone(), waitroom.clone()));
    tokio::spawn(session_monitor(sessions.clone()));
    let std_ln = build_listener().expect("listener");
    let listener = TcpListener::from_std(std_ln).expect("tokio listener");
    loop {
        match listener.accept().await {
            Ok((conn, _)) => { tokio::spawn(handle_conn(conn, sessions.clone(), waitroom.clone(), ip_count.clone())); }
            Err(_) => {}
        }
    }
}
RSEOF

cat > "$PROJ/src/bin/panel.rs" << 'RSEOF'
use std::{collections::HashMap, net::SocketAddr, sync::Arc, time::{Duration, SystemTime, UNIX_EPOCH}};
use anyhow::Result;
use axum::{extract::{ConnectInfo, Query, State}, http::{HeaderMap, StatusCode}, routing::{delete, get, post, put}, Json, Router};
use serde::{Deserialize, Serialize};
use tokio::{net::TcpListener, sync::Mutex};

const PANEL_ADDR: &str = "0.0.0.0:8090";
const USERS_PATH: &str = "/opt/btserver/users.txt";
const TOKEN_PATH: &str = "/opt/btserver/token.txt";
const KICK_BASE:  &str = "http://127.0.0.1:8091/kick?id=";
const PROMOTE_BASE: &str = "http://127.0.0.1:8091/promote?id=";

#[inline(always)] fn now_secs() -> i64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() as i64 }
fn expires_from_days(days: i64) -> i64 { now_secs() + days * 86400 }

fn migrate_date_to_ts(s: &str) -> Option<i64> {
    let s = s.trim(); let mut it = s.splitn(3, '-');
    let y: i64 = it.next()?.parse().ok()?; let m: i64 = it.next()?.parse().ok()?; let d: i64 = it.next()?.parse().ok()?;
    if y < 2000 || y > 2100 { return None; }
    let m2 = if m <= 2 { m + 12 } else { m }; let y2 = if m <= 2 { y - 1 } else { y };
    let a  = y2 / 100; let b  = 2 - a + a / 4;
    let days = (365.25 * (y2 + 4716) as f64) as i64 + (30.6001 * (m2 + 1) as f64) as i64 + d + b - 1524 - 2440588;
    Some(days * 86400 + 86399)
}

fn parse_expires(s: &str) -> i64 { let s = s.trim(); if let Ok(ts) = s.parse::<i64>() { return ts; } migrate_date_to_ts(s).unwrap_or(0) }

#[derive(Clone)] struct AppState { token: Arc<String>, users_mu: Arc<Mutex<()>>, rate: Arc<std::sync::Mutex<HashMap<String, Vec<i64>>>> }
impl AppState {
    fn new() -> Self {
        let token = std::fs::read_to_string(TOKEN_PATH).map(|s| s.trim().to_string()).unwrap_or_default();
        Self { token: Arc::new(token), users_mu: Arc::new(Mutex::new(())), rate: Arc::new(std::sync::Mutex::new(HashMap::new())) }
    }
    fn rate_ok(&self, ip: &str) -> bool {
        let now = now_secs(); let mut map = self.rate.lock().unwrap();
        let hits = map.entry(ip.to_string()).or_default();
        hits.retain(|&t| now - t < 60);
        if hits.len() >= 30 { return false; }
        hits.push(now); if map.len() > 1000 { map.clear(); }
        true
    }
    fn check_token(&self, headers: &HeaderMap) -> bool {
        headers.get("x-token").and_then(|v| v.to_str().ok()).map(|t| t.trim() == self.token.as_str()).unwrap_or(false)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)] struct User { name: String, expires_ts: i64 }

fn load_users_blocking() -> HashMap<String, User> {
    let Ok(c) = std::fs::read_to_string(USERS_PATH) else { return HashMap::new(); };
    let mut map = HashMap::new();
    for line in c.lines() {
        let line = line.trim(); if line.is_empty() || line.starts_with('#') { continue; }
        let mut parts = line.splitn(3, ':');
        let Some(id)   = parts.next().map(str::trim).filter(|s| !s.is_empty()) else { continue };
        let Some(name) = parts.next().map(str::trim) else { continue };
        let Some(exp)  = parts.next().map(str::trim) else { continue };
        let expires_ts = parse_expires(exp);
        map.insert(id.to_string(), User { name: name.to_string(), expires_ts });
    }
    map
}

fn save_users_blocking(users: &HashMap<String, User>) {
    let tmp = format!("{USERS_PATH}.tmp"); let mut out = String::new();
    for (id, u) in users { out.push_str(&format!("{id}:{}:{}\n", u.name, u.expires_ts)); }
    if std::fs::write(&tmp, &out).is_ok() { let _ = std::fs::rename(&tmp, USERS_PATH); }
}

async fn load_users() -> HashMap<String, User> {
    tokio::task::spawn_blocking(load_users_blocking).await.unwrap_or_default()
}

async fn save_users(users: HashMap<String, User>) {
    let _ = tokio::task::spawn_blocking(move || save_users_blocking(&users)).await;
}

fn user_row(id: &str, u: &User) -> serde_json::Value {
    let secs_left = (u.expires_ts - now_secs()).max(0);
    serde_json::json!({ "id": id, "name": u.name, "expires_ts": u.expires_ts, "secs_left": secs_left, "active": secs_left > 0 })
}

async fn kick_user(id: String, reason: &'static str) {
    let url = format!("{KICK_BASE}{id}&reason={reason}");
    if let Ok(c) = reqwest::Client::builder().timeout(Duration::from_secs(2)).build() { let _ = c.get(&url).send().await; }
}
async fn promote_user(id: String) {
    let url = format!("{PROMOTE_BASE}{id}");
    if let Ok(c) = reqwest::Client::builder().timeout(Duration::from_secs(2)).build() { let _ = c.get(&url).send().await; }
}

type ApiResult = (StatusCode, Json<serde_json::Value>);
fn err_resp(code: StatusCode, msg: &str) -> ApiResult { (code, Json(serde_json::json!({"error": msg}))) }

fn auth_check(state: &AppState, headers: &HeaderMap, addr: &SocketAddr) -> Option<ApiResult> {
    let ip = addr.ip().to_string();
    if !state.rate_ok(&ip) { return Some(err_resp(StatusCode::TOO_MANY_REQUESTS, "too many requests")); }
    if !state.check_token(headers) { return Some(err_resp(StatusCode::UNAUTHORIZED, "unauthorized")); }
    None
}

async fn fetch_active_ids() -> std::collections::HashSet<String> {
    if let Ok(c) = reqwest::Client::builder().timeout(Duration::from_secs(2)).build() {
        if let Ok(resp) = c.get("http://127.0.0.1:8091/active").send().await {
            if let Ok(text) = resp.text().await {
                if let Ok(val) = serde_json::from_str::<serde_json::Value>(&text) {
                    return val["active"].as_array().map(|arr| arr.iter().filter_map(|v| v.as_str().map(|s| s.to_string())).collect()).unwrap_or_default();
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
    let users = load_users().await;
    let rows: Vec<_> = users.iter().map(|(id, u)| {
        let mut row = user_row(id, u); row["connected"] = serde_json::json!(active.contains(id.as_str())); row
    }).collect();
    (StatusCode::OK, Json(serde_json::json!({"clients":rows,"total":rows.len()})))
}

async fn handle_client(State(st): State<AppState>, headers: HeaderMap, ConnectInfo(addr): ConnectInfo<SocketAddr>, Query(p): Query<HashMap<String, String>>) -> ApiResult {
    if let Some(e) = auth_check(&st, &headers, &addr) { return e; }
    let id = match p.get("id").map(|s| s.trim().to_string()).filter(|s| !s.is_empty()) { Some(id) => id, None => return err_resp(StatusCode::BAD_REQUEST, "falta id") };
    let _l = st.users_mu.lock().await;
    match load_users().await.get(&id).cloned() { Some(u) => (StatusCode::OK, Json(user_row(&id, &u))), None => err_resp(StatusCode::NOT_FOUND, "no encontrado") }
}

#[derive(Deserialize)] struct CreateBody { id: String, name: Option<String>, days: Option<i64> }
async fn handle_create(State(st): State<AppState>, headers: HeaderMap, ConnectInfo(addr): ConnectInfo<SocketAddr>, Json(body): Json<CreateBody>) -> ApiResult {
    if let Some(e) = auth_check(&st, &headers, &addr) { return e; }
    let id = body.id.trim().to_string(); if id.is_empty() { return err_resp(StatusCode::BAD_REQUEST, "falta id"); }
    let name = body.name.as_deref().unwrap_or("").trim().to_string(); let name = if name.is_empty() { "sin-nombre".to_string() } else { name };
    let days = body.days.unwrap_or(30).max(0);
    let _l = st.users_mu.lock().await;
    let mut users = load_users().await;
    if users.contains_key(&id) { return err_resp(StatusCode::CONFLICT, "ya existe"); }
    let expires_ts = expires_from_days(days);
    users.insert(id.clone(), User { name: name.clone(), expires_ts });
    save_users(users).await;
    drop(_l);
    tokio::spawn(promote_user(id.clone()));
    (StatusCode::CREATED, Json(user_row(&id, &User { name, expires_ts })))
}

#[derive(Deserialize)] struct IdBody { id: String }
async fn handle_delete(State(st): State<AppState>, headers: HeaderMap, ConnectInfo(addr): ConnectInfo<SocketAddr>, Json(body): Json<IdBody>) -> ApiResult {
    if let Some(e) = auth_check(&st, &headers, &addr) { return e; }
    let id = body.id.trim().to_string(); if id.is_empty() { return err_resp(StatusCode::BAD_REQUEST, "falta id"); }
    {
        let _l = st.users_mu.lock().await;
        let mut users = load_users().await;
        if !users.contains_key(&id) { return err_resp(StatusCode::NOT_FOUND, "no encontrado"); }
        users.remove(&id);
        save_users(users).await;
    }
    tokio::spawn(kick_user(id, "kicked"));
    (StatusCode::OK, Json(serde_json::json!({"ok":true})))
}

#[derive(Deserialize)] struct UpdateBody { id: String, name: Option<String>, new_id: Option<String>, days: Option<i64> }
async fn handle_update(State(st): State<AppState>, headers: HeaderMap, ConnectInfo(addr): ConnectInfo<SocketAddr>, Json(body): Json<UpdateBody>) -> ApiResult {
    if let Some(e) = auth_check(&st, &headers, &addr) { return e; }
    let id = body.id.trim().to_string(); if id.is_empty() { return err_resp(StatusCode::BAD_REQUEST, "falta id"); }
    let (final_id, u, kick_old) = {
        let _l = st.users_mu.lock().await;
        let mut users = load_users().await;
        let Some(mut u) = users.get(&id).cloned() else { return err_resp(StatusCode::NOT_FOUND, "no encontrado"); };
        if let Some(n) = body.name.as_deref() { let n = n.trim(); if !n.is_empty() { u.name = n.to_string(); } }
        if let Some(d) = body.days { u.expires_ts = expires_from_days(d.max(0)); }
        let (final_id, kick_old) = match body.new_id.as_deref().map(str::trim) {
            Some(nid) if !nid.is_empty() && nid != id => { users.remove(&id); (nid.to_string(), true) }
            _ => (id.clone(), false),
        };
        users.insert(final_id.clone(), u.clone());
        save_users(users).await;
        (final_id, u, kick_old)
    };
    if kick_old { tokio::spawn(kick_user(id, "kicked")); }
    if u.expires_ts <= now_secs() { tokio::spawn(kick_user(final_id.clone(), "expired")); } else { tokio::spawn(promote_user(final_id.clone())); }
    (StatusCode::OK, Json(user_row(&final_id, &u)))
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt().with_env_filter(tracing_subscriber::EnvFilter::from_default_env().add_directive("panel=info".parse()?)).init();
    let state = AppState::new();
    let app = Router::new().route("/clients", get(handle_clients)).route("/client", get(handle_client)).route("/client/create", post(handle_create)).route("/client/delete", delete(handle_delete)).route("/client/update", put(handle_update)).with_state(state).into_make_service_with_connect_info::<SocketAddr>();
    let ln = TcpListener::bind(PANEL_ADDR).await?;
    axum::serve(ln, app).await?;
    Ok(())
}
RSEOF

cd "$PROJ"
cargo build --release
