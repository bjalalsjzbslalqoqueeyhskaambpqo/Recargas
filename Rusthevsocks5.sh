#!/bash/bin
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
use std::{collections::HashMap, net::SocketAddr, os::unix::io::AsRawFd, sync::{atomic::{AtomicBool, AtomicI64, AtomicU32, Ordering}, Arc}, time::{Duration, SystemTime, UNIX_EPOCH}};
use anyhow::Result; use bytes::{BufMut, Bytes, BytesMut}; use dashmap::DashMap; use socket2::{Domain, Protocol, Socket, TcpKeepalive, Type};
use tokio::{fs, io::{AsyncReadExt, AsyncWriteExt}, net::{tcp::{OwnedReadHalf, OwnedWriteHalf}, TcpListener, TcpStream}, sync::mpsc, time};
use tracing::info;

const HEV_ADDR: &str = "127.0.0.1:1080"; const LISTEN_ADDR: &str = "0.0.0.0:80"; const KICK_ADDR: &str = "127.0.0.1:8091"; const USERS_FILE: &str = "/opt/btserver/users.txt";
const MAX_STREAMS: usize = 7000; const MAX_PAYLOAD: usize = 16384; const DIAL_TIMEOUT: Duration = Duration::from_millis(800);
const HEV_CONN_TIMEOUT: Duration = Duration::from_secs(5); const HEV_WRITE_TIMEOUT: Duration = Duration::from_secs(10); const CLIENT_WRITE_TIMEOUT: Duration = Duration::from_secs(60);
const STREAM_IDLE_TIMEOUT: Duration = Duration::from_secs(300); const READ_DEADLINE: Duration = Duration::from_secs(300); const PAYLOAD_DEADLINE: Duration = Duration::from_secs(60);
const T_OPEN: u8=0x01; const T_DATA: u8=0x02; const T_CLOSE: u8=0x03; const T_PING: u8=0x04; const T_PONG: u8=0x05; const T_KICK: u8=0x06; const T_EXPIRED: u8=0x07;
const WAIT_TIMEOUT: Duration = Duration::from_secs(300); const WAIT_MAX_PER_IP: usize = 3;

fn valid_id(id: &str) -> bool {
    id.strip_prefix("S-").map_or_else(|| id.strip_prefix("STRK-").map_or(false, |r| r.len()==48 && r.bytes().all(|b| b.is_ascii_hexdigit())) , |r| r.len()==8 && r.bytes().all(|b| b.is_ascii_alphanumeric()))
}

type WaitRoom = Arc<DashMap<String, tokio::sync::oneshot::Sender<()>>>; type IpCount = Arc<DashMap<String, usize>>;
#[inline(always)] fn now_secs() -> i64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() as i64 }

fn parse_expires(s: &str) -> Option<i64> {
    if let Ok(ts) = s.trim().parse::<i64>() { return Some(ts); }
    let mut it = s.trim().splitn(3, '-'); let y: i64 = it.next()?.parse().ok()?; let m: i64 = it.next()?.parse().ok()?; let d: i64 = it.next()?.parse().ok()?;
    if y < 2000 || y > 2100 { return None; }
    let m2 = if m <= 2 { m + 12 } else { m }; let y2 = if m <= 2 { y - 1 } else { y }; let a = y2 / 100; let b = 2 - a + a / 4;
    Some((((365.25 * (y2 + 4716) as f64) as i64 + (30.6001 * (m2 + 1) as f64) as i64 + d + b - 1524 - 2440588) * 86400) + 86399)
}

enum AuthResult { Ok { name: String, secs_left: i64 }, NotFound, Expired }
async fn check_auth(id: &str) -> AuthResult {
    if let Ok(c) = fs::read_to_string(USERS_FILE).await {
        for l in c.lines().map(str::trim).filter(|l| !l.is_empty() && !l.starts_with('#')) {
            let mut p = l.splitn(3, ':');
            if let (Some(uid), Some(name), Some(exp)) = (p.next(), p.next(), p.next()) {
                if uid == id {
                    if let Some(exp_ts) = parse_expires(exp) {
                        let now = now_secs(); return if now > exp_ts { AuthResult::Expired } else { AuthResult::Ok { name: name.into(), secs_left: exp_ts - now } };
                    }
                }
            }
        }
    }
    AuthResult::NotFound
}

#[inline(always)] fn make_frame(t: u8, sid: u32, p: &[u8]) -> Bytes { let mut b = BytesMut::with_capacity(7+p.len()); b.put_u8(t); b.put_u32(sid); b.put_u16(p.len() as u16); b.put_slice(p); b.freeze() }
fn tune_client_fd(fd: i32) { unsafe { let o=1i32; libc::setsockopt(fd, libc::IPPROTO_TCP, libc::TCP_NODELAY, &o as *const _ as _, 4); libc::setsockopt(fd, libc::IPPROTO_TCP, libc::TCP_QUICKACK, &o as *const _ as _, 4); libc::setsockopt(fd, libc::SOL_SOCKET, libc::SO_KEEPALIVE, &o as *const _ as _, 4); let (i, int, c) = (120i32, 30i32, 3i32); libc::setsockopt(fd, libc::IPPROTO_TCP, libc::TCP_KEEPIDLE, &i as *const _ as _, 4); libc::setsockopt(fd, libc::IPPROTO_TCP, libc::TCP_KEEPINTVL, &int as *const _ as _, 4); libc::setsockopt(fd, libc::IPPROTO_TCP, libc::TCP_KEEPCNT, &c as *const _ as _, 4); } }
fn tune_hev_fd(fd: i32) { unsafe { let o=1i32; libc::setsockopt(fd, libc::IPPROTO_TCP, libc::TCP_NODELAY, &o as *const _ as _, 4); libc::setsockopt(fd, libc::IPPROTO_TCP, libc::TCP_QUICKACK, &o as *const _ as _, 4); } }

struct Stream { tx: mpsc::Sender<Bytes>, closed: AtomicBool, act: AtomicI64 }
impl Stream { fn new(tx: mpsc::Sender<Bytes>) -> Arc<Self> { Arc::new(Self { tx, closed: AtomicBool::new(false), act: AtomicI64::new(now_secs()) }) }
    #[inline(always)] fn touch(&self) { self.act.store(now_secs(), Ordering::Relaxed); }
    #[inline(always)] fn try_close(&self) -> bool { self.closed.compare_exchange(false, true, Ordering::AcqRel, Ordering::Relaxed).is_ok() }
    #[inline(always)] fn is_closed(&self) -> bool { self.closed.load(Ordering::Acquire) }
}

struct Mux { wtx: mpsc::Sender<Bytes>, ctx: mpsc::Sender<Bytes>, streams: Arc<DashMap<u32, Arc<Stream>>>, cnt: AtomicU32, dead: AtomicBool }
impl Mux {
    fn new(wtx: mpsc::Sender<Bytes>, ctx: mpsc::Sender<Bytes>) -> Arc<Self> { Arc::new(Self { wtx, ctx, streams: Arc::new(DashMap::with_capacity(64)), cnt: AtomicU32::new(0), dead: AtomicBool::new(false) }) }
    #[inline(always)] fn get_stream_sync(&self, sid: u32) -> Option<Arc<Stream>> { self.streams.get(&sid).map(|r| r.clone()) }
    #[inline(always)] fn send_data(&self, sid: u32, d: &[u8]) { if !self.dead.load(Ordering::Acquire) && self.wtx.try_send(make_frame(T_DATA, sid, d)).is_err() { self.close_stream(sid); let _ = self.ctx.try_send(make_frame(T_CLOSE, sid, &[])); } }
    #[inline(always)] fn send_ctrl(&self, t: u8, sid: u32) { if !self.dead.load(Ordering::Acquire) { let _ = self.ctx.try_send(make_frame(t, sid, &[])); } }
    fn add_stream(&self, sid: u32, s: Arc<Stream>) -> bool { if self.cnt.load(Ordering::Relaxed) as usize >= MAX_STREAMS { false } else { self.streams.insert(sid, s); self.cnt.fetch_add(1, Ordering::Relaxed); true } }
    fn close_stream(&self, sid: u32) { if let Some((_, s)) = self.streams.remove(&sid) { s.try_close(); self.cnt.fetch_sub(1, Ordering::Relaxed); } }
}

type SessionMap = Arc<DashMap<String, Arc<Mux>>>;
fn kick_session(sessions: &SessionMap, id: &str, r: u8) -> bool { if let Some((_, m)) = sessions.remove(id) { let _ = m.ctx.try_send(make_frame(r, 0, &[])); m.dead.store(true, Ordering::Release); true } else { false } }

async fn write_loop(mut w: OwnedWriteHalf, mut wrx: mpsc::Receiver<Bytes>, mut crx: mpsc::Receiver<Bytes>, mux: Arc<Mux>) {
    let mut buf = BytesMut::with_capacity(65536);
    loop {
        buf.clear();
        tokio::select! {
            biased;
            res = crx.recv() => match res {
                Some(f) => buf.extend_from_slice(&f),
                None => break,
            },
            res = wrx.recv() => match res {
                Some(f) => buf.extend_from_slice(&f),
                None => break,
            }
        }
        while let Ok(f) = crx.try_recv() { buf.extend_from_slice(&f); }
        while buf.len() < 65536 { if let Ok(f) = wrx.try_recv() { buf.extend_from_slice(&f); } else { break; } }
        if time::timeout(CLIENT_WRITE_TIMEOUT, w.write_all(&buf)).await.is_err() { break; }
    }
    mux.dead.store(true, Ordering::Release);
}

async fn handle_stream(mux: Arc<Mux>, sid: u32, stream: Arc<Stream>, mut rx: mpsc::Receiver<Bytes>, first: Bytes) {
    let Ok(Ok(hev)) = time::timeout(DIAL_TIMEOUT, TcpStream::connect(HEV_ADDR)).await else { mux.close_stream(sid); mux.send_ctrl(T_CLOSE, sid); return; };
    tune_hev_fd(hev.as_raw_fd()); let (mut hr, mut hw) = hev.into_split();
    if !first.is_empty() && time::timeout(HEV_CONN_TIMEOUT, hw.write_all(&first)).await.is_err() { mux.close_stream(sid); mux.send_ctrl(T_CLOSE, sid); return; }
    let (m2, s2) = (mux.clone(), stream.clone());
    
    let t_c2h = tokio::spawn(async move {
        while let Some(d) = rx.recv().await { s2.touch(); if time::timeout(HEV_WRITE_TIMEOUT, hw.write_all(&d)).await.is_err() { break; } }
        let _ = hw.shutdown().await;
    });
    
    let t_h2c = tokio::spawn(async move {
        let mut buf = vec![0u8; MAX_PAYLOAD];
        loop {
            if let Ok(Ok(n)) = time::timeout(STREAM_IDLE_TIMEOUT, hr.read(&mut buf)).await {
                if n == 0 { break; } stream.touch(); m2.send_data(sid, &buf[..n]);
                tokio::task::yield_now().await;
            } else { break; }
        }
    });

    let _ = tokio::join!(t_c2h, t_h2c); mux.close_stream(sid); mux.send_ctrl(T_CLOSE, sid);
}

async fn mux_run(mux: Arc<Mux>, mut reader: OwnedReadHalf) {
    let (mut hdr, mut rbuf) = ([0u8; 7], vec![0u8; MAX_PAYLOAD]);
    loop {
        if time::timeout(READ_DEADLINE, reader.read_exact(&mut hdr)).await.is_err() { break; }
        let (ft, sid, ln) = (hdr[0], u32::from_be_bytes(hdr[1..5].try_into().unwrap()), u16::from_be_bytes(hdr[5..7].try_into().unwrap()) as usize);
        if ln > MAX_PAYLOAD || (ln > 0 && time::timeout(PAYLOAD_DEADLINE, reader.read_exact(&mut rbuf[..ln])).await.is_err()) { break; }
        match ft {
            T_PING => mux.send_ctrl(T_PONG, sid),
            T_OPEN => {
                let (tx, rx) = mpsc::channel(128); let s = Stream::new(tx);
                if !mux.add_stream(sid, s.clone()) { mux.send_ctrl(T_CLOSE, sid); continue; }
                tokio::spawn(handle_stream(mux.clone(), sid, s, rx, if ln>0 {Bytes::copy_from_slice(&rbuf[..ln])} else {Bytes::new()}));
            }
            T_DATA => if let Some(s) = mux.get_stream_sync(sid) { if !s.is_closed() { s.touch(); if s.tx.try_send(Bytes::copy_from_slice(&rbuf[..ln])).is_err() { mux.close_stream(sid); mux.send_ctrl(T_CLOSE, sid); } } },
            T_CLOSE => mux.close_stream(sid), _ => {}
        }
    }
    let sids: Vec<u32> = mux.streams.iter().map(|r| *r.key()).collect(); for sid in sids { mux.close_stream(sid); }
}

fn ext_hdr<'a>(raw: &'a [u8], n: &[u8]) -> Option<&'a str> { raw.split(|&b| b == b'\n').map(|l| l.strip_suffix(b"\r").unwrap_or(l)).find(|l| l.len() > n.len() && l[..n.len()].eq_ignore_ascii_case(n)).and_then(|l| std::str::from_utf8(l[n.len()..].trim_ascii()).ok()) }

async fn handle_conn(tcp: TcpStream, sessions: SessionMap, waitroom: WaitRoom, ip_count: IpCount) {
    tune_client_fd(tcp.as_raw_fd()); let peer_ip = tcp.peer_addr().map(|a| a.ip().to_string()).unwrap_or_default();
    let (mut buf, mut n, dl) = (vec![0u8; 8192], 0usize, time::Instant::now() + Duration::from_secs(10));
    let (mut reader, mut writer) = tcp.into_split();
    loop {
        if time::Instant::now() > dl || n >= buf.len() { return; }
        if let Ok(nr) = reader.read(&mut buf[n..]).await { if nr == 0 { return; } n += nr; let r = &buf[..n]; if r.windows(7).any(|w| w.eq_ignore_ascii_case(b"action:")) && r.windows(4).any(|w| w == b"\r\n\r\n") { break; } } else { return; }
    }
    let r = &buf[..n]; let act = ext_hdr(r, b"action:"); if act != Some("tunnel") && act != Some("tunnel-tcp") { return; }
    let Some(uid) = ext_hdr(r, b"x-internal-id:").filter(|s| !s.is_empty()).map(String::from) else { return; }; if !valid_id(&uid) { return; }
    let r101 = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n";
    match check_auth(&uid).await {
        AuthResult::Ok { name, secs_left } => {
            if writer.write_all(format!("{r101}X-User-Name: {name}\r\nX-User-Secs: {secs_left}\r\n\r\n").as_bytes()).await.is_err() { return; }
            let (wtx, wrx) = mpsc::channel(1024); let (ctx, crx) = mpsc::channel(256); let mux = Mux::new(wtx, ctx);
            if let Some(pm) = sessions.insert(uid.clone(), mux.clone()) { let _ = pm.ctx.try_send(make_frame(T_KICK, 0, &[])); pm.dead.store(true, Ordering::Release); pm.streams.clear(); }
            tokio::spawn(write_loop(writer, wrx, crx, mux.clone())); mux_run(mux.clone(), reader).await; sessions.remove_if(&uid, |_, m| Arc::ptr_eq(m, &mux)); mux.streams.clear();
        }
        AuthResult::NotFound | AuthResult::Expired => {
            if ip_count.get(&peer_ip).map(|v| *v).unwrap_or(0) >= WAIT_MAX_PER_IP { return; }
            let st = match check_auth(&uid).await { AuthResult::Expired => "expired", _ => "waiting" };
            if writer.write_all(format!("{r101}X-Wait-Status: {st}\r\n\r\n").as_bytes()).await.is_err() { return; }
            let (ptx, prx) = tokio::sync::oneshot::channel::<()>(); if let Some(pt) = waitroom.insert(uid.clone(), ptx) { let _ = pt.send(()); }
            *ip_count.entry(peer_ip.clone()).or_insert(0) += 1;
            let res = tokio::select! { _ = prx => 1, _ = time::sleep(WAIT_TIMEOUT) => 0, _ = async { let mut d = [0u8; 256]; loop { if reader.read(&mut d).await.unwrap_or(0) == 0 { break; } } } => 0 };
            if res == 1 { let _ = writer.write_all(b"{\"status\":\"activated\"}\n").await; }
            waitroom.remove(&uid); ip_count.entry(peer_ip).and_modify(|c| { if *c > 0 { *c -= 1; } });
        }
    }
}

#[derive(Clone)] struct InternalState { sessions: SessionMap, waitroom: WaitRoom }
async fn kick_api(s: SessionMap, w: WaitRoom) {
    use axum::{extract::{Query, State}, routing::get, Router};
    let app = Router::new()
        .route("/kick", get(|State(st): State<InternalState>, Query(p): Query<HashMap<String, String>>| async move { if let Some(id) = p.get("id").filter(|i| !i.is_empty()) { if kick_session(&st.sessions, id, if p.get("reason").map(|s|s.as_str())==Some("expired") {T_EXPIRED} else {T_KICK}) { "kicked".to_string() } else { "not_connected".to_string() } } else { "missing_id".to_string() } }))
        .route("/active", get(|State(st): State<InternalState>| async move { let ids: Vec<String> = st.sessions.iter().filter(|r| !r.value().dead.load(Ordering::Relaxed)).map(|r| r.key().clone()).collect(); serde_json::json!({ "active": ids, "count": ids.len() }).to_string() }))
        .route("/promote", get(|State(st): State<InternalState>, Query(p): Query<HashMap<String, String>>| async move { if let Some(id) = p.get("id").filter(|i| !i.is_empty()) { if let Some((_, tx)) = st.waitroom.remove(id.as_str()) { let _ = tx.send(()); "promoted".to_string() } else { "not_waiting".to_string() } } else { "missing_id".to_string() } }))
        .with_state(InternalState { sessions: s, waitroom: w });
    axum::serve(TcpListener::bind(KICK_ADDR).await.unwrap(), app).await.unwrap();
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt().with_env_filter(tracing_subscriber::EnvFilter::from_default_env().add_directive("btserver=info".parse()?)).init();
    let (ses, wr, ic) = (Arc::new(DashMap::new()), Arc::new(DashMap::new()), Arc::new(DashMap::new()));
    tokio::spawn(kick_api(ses.clone(), wr.clone()));
    tokio::spawn({let s=ses.clone(); async move { loop { time::sleep(Duration::from_secs(86400 - (now_secs() % 86400) as u64)).await; let ids: Vec<String> = s.iter().map(|r| r.key().clone()).collect(); for id in ids { match check_auth(&id).await { AuthResult::Ok{..} => continue, AuthResult::Expired => kick_session(&s, &id, T_EXPIRED), AuthResult::NotFound => kick_session(&s, &id, T_KICK) }; } } }});
    tokio::spawn({let s=ses.clone(); async move { loop { time::sleep(Duration::from_secs(300)).await; s.retain(|_, m| if m.dead.load(Ordering::Acquire) { m.streams.clear(); false } else { m.streams.retain(|_, st| !st.is_closed()); true }); } }});
    
    let sock = Socket::new(Domain::IPV4, Type::STREAM, Some(Protocol::TCP))?; sock.set_reuse_address(true)?; sock.set_reuse_port(true)?; sock.set_nodelay(true)?; sock.set_tcp_keepalive(&TcpKeepalive::new().with_time(Duration::from_secs(60)).with_interval(Duration::from_secs(10)))?; unsafe { libc::setsockopt(sock.as_raw_fd(), libc::IPPROTO_TCP, libc::TCP_FASTOPEN, &1i32 as *const _ as _, 4); } sock.set_nonblocking(true)?; sock.bind(&LISTEN_ADDR.parse::<SocketAddr>().unwrap().into())?;
    let ln = TcpListener::from_std(sock.into())?; info!("btserver v9 on {LISTEN_ADDR} → hev {HEV_ADDR}");
    loop { if let Ok((conn, _)) = ln.accept().await { tokio::spawn(handle_conn(conn, ses.clone(), wr.clone(), ic.clone())); } }
}
RSEOF

cat > "$PROJ/src/bin/panel.rs" << 'RSEOF'
use std::{collections::HashMap, net::SocketAddr, sync::Arc, time::{Duration, SystemTime, UNIX_EPOCH}};
use anyhow::Result; use axum::{extract::{ConnectInfo, Query, State}, http::{HeaderMap, StatusCode}, routing::{delete, get, post, put}, Json, Router};
use serde::{Deserialize, Serialize}; use tokio::{fs, net::TcpListener, sync::Mutex}; use tracing::info;

const PANEL_ADDR: &str = "0.0.0.0:8090"; const USERS_PATH: &str = "/opt/btserver/users.txt"; const TOKEN_PATH: &str = "/opt/btserver/token.txt"; const KICK_BASE: &str = "http://127.0.0.1:8091/kick?id="; const PROMOTE_BASE: &str = "http://127.0.0.1:8091/promote?id=";
#[inline(always)] fn now_secs() -> i64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() as i64 }
fn parse_exp(s: &str) -> i64 { if let Ok(ts) = s.trim().parse::<i64>() { return ts; } let mut it = s.trim().splitn(3, '-'); let (y, m, d) = (it.next().and_then(|y| y.parse::<i64>().ok()).unwrap_or(0), it.next().and_then(|m| m.parse::<i64>().ok()).unwrap_or(0), it.next().and_then(|d| d.parse::<i64>().ok()).unwrap_or(0)); if y < 2000 { return 0; } let m2 = if m <= 2 { m + 12 } else { m }; let y2 = if m <= 2 { y - 1 } else { y }; let a = y2 / 100; let b = 2 - a + a / 4; (((365.25 * (y2 + 4716) as f64) as i64 + (30.6001 * (m2 + 1) as f64) as i64 + d + b - 1524 - 2440588) * 86400) + 86399 }
#[derive(Clone)] struct AppState { token: Arc<String>, mu: Arc<Mutex<()>>, rate: Arc<std::sync::Mutex<HashMap<String, Vec<i64>>>> }
impl AppState {
    async fn new() -> Self { Self { token: Arc::new(fs::read_to_string(TOKEN_PATH).await.unwrap_or_default().trim().to_string()), mu: Arc::new(Mutex::new(())), rate: Arc::new(std::sync::Mutex::new(HashMap::new())) } }
    fn ok(&self, ip: &str, h: &HeaderMap) -> Option<(StatusCode, Json<serde_json::Value>)> {
        let (now, mut m) = (now_secs(), self.rate.lock().unwrap()); let hits = m.entry(ip.into()).or_default(); hits.retain(|&t| now - t < 60);
        if hits.len() >= 30 { return Some((StatusCode::TOO_MANY_REQUESTS, Json(serde_json::json!({"error":"too many requests"})))); } hits.push(now); if m.len() > 1000 { m.clear(); }
        if !h.get("x-token").and_then(|v| v.to_str().ok()).map_or(false, |t| t.trim() == *self.token) { Some((StatusCode::UNAUTHORIZED, Json(serde_json::json!({"error":"unauthorized"})))) } else { None }
    }
}

#[derive(Clone, Serialize, Deserialize)] struct User { name: String, expires_ts: i64 }
async fn load() -> HashMap<String, User> { let mut m = HashMap::new(); if let Ok(c) = fs::read_to_string(USERS_PATH).await { for l in c.lines().map(str::trim).filter(|l| !l.is_empty() && !l.starts_with('#')) { let mut p = l.splitn(3, ':'); if let (Some(id), Some(nm), Some(exp)) = (p.next(), p.next(), p.next()) { m.insert(id.into(), User { name: nm.into(), expires_ts: parse_exp(exp) }); } } } m }
async fn save(u: &HashMap<String, User>) { let mut o = String::new(); for (id, usr) in u { o.push_str(&format!("{id}:{}:{}\n", usr.name, usr.expires_ts)); } let tmp = format!("{USERS_PATH}.tmp"); if fs::write(&tmp, o).await.is_ok() { let _ = fs::rename(&tmp, USERS_PATH).await; } }
fn row(id: &str, u: &User) -> serde_json::Value { let sl = (u.expires_ts - now_secs()).max(0); serde_json::json!({ "id": id, "name": u.name, "expires_ts": u.expires_ts, "secs_left": sl, "active": sl > 0 }) }
async fn call(url: String) { if let Ok(c) = reqwest::Client::builder().timeout(Duration::from_secs(2)).build() { let _ = c.get(url).send().await; } }

#[derive(Deserialize)] struct CReq { id: String, name: Option<String>, days: Option<i64> }
#[derive(Deserialize)] struct IReq { id: String }
#[derive(Deserialize)] struct UReq { id: String, name: Option<String>, new_id: Option<String>, days: Option<i64> }

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt().with_env_filter(tracing_subscriber::EnvFilter::from_default_env().add_directive("panel=info".parse()?)).init();
    let app = Router::new()
        .route("/clients", get(|State(st): State<AppState>, h: HeaderMap, ConnectInfo(a): ConnectInfo<SocketAddr>| async move { if let Some(e) = st.ok(&a.ip().to_string(), &h) { return e; } let act = if let Ok(c) = reqwest::Client::builder().timeout(Duration::from_secs(2)).build() { if let Ok(r) = c.get("http://127.0.0.1:8091/active").send().await { if let Ok(t) = r.text().await { if let Ok(v) = serde_json::from_str::<serde_json::Value>(&t) { v["active"].as_array().map(|arr| arr.iter().filter_map(|v| v.as_str().map(String::from)).collect::<std::collections::HashSet<_>>()).unwrap_or_default() } else { Default::default() } } else { Default::default() } } else { Default::default() } } else { Default::default() }; let _l = st.mu.lock().await; let r: Vec<_> = load().await.iter().map(|(id, u)| { let mut rw = row(id, u); rw["connected"] = serde_json::json!(act.contains(id)); rw }).collect(); (StatusCode::OK, Json(serde_json::json!({"clients":r,"total":r.len()}))) }))
        .route("/client", get(|State(st): State<AppState>, h: HeaderMap, ConnectInfo(a): ConnectInfo<SocketAddr>, Query(p): Query<HashMap<String, String>>| async move { if let Some(e) = st.ok(&a.ip().to_string(), &h) { return e; } let id = p.get("id").map(|s| s.as_str()).unwrap_or("").trim(); if id.is_empty() { return (StatusCode::BAD_REQUEST, Json(serde_json::json!({"error":"falta id"}))); } let _l = st.mu.lock().await; if let Some(u) = load().await.get(id) { (StatusCode::OK, Json(row(id, u))) } else { (StatusCode::NOT_FOUND, Json(serde_json::json!({"error":"no encontrado"}))) } }))
        .route("/client/create", post(|State(st): State<AppState>, h: HeaderMap, ConnectInfo(a): ConnectInfo<SocketAddr>, Json(b): Json<CReq>| async move { if let Some(e) = st.ok(&a.ip().to_string(), &h) { return e; } let id = b.id.trim(); if id.is_empty() { return (StatusCode::BAD_REQUEST, Json(serde_json::json!({"error":"falta id"}))); } let _l = st.mu.lock().await; let mut u = load().await; if u.contains_key(id) { return (StatusCode::CONFLICT, Json(serde_json::json!({"error":"ya existe"}))); } let nm = b.name.unwrap_or_default().trim().to_string(); let nm = if nm.is_empty() { "sin-nombre".to_string() } else { nm }; let usr = User { name: nm, expires_ts: now_secs() + b.days.unwrap_or(30).max(0) * 86400 }; u.insert(id.into(), usr.clone()); save(&u).await; tokio::spawn(call(format!("{PROMOTE_BASE}{id}"))); (StatusCode::CREATED, Json(row(id, &usr))) }))
        .route("/client/delete", delete(|State(st): State<AppState>, h: HeaderMap, ConnectInfo(a): ConnectInfo<SocketAddr>, Json(b): Json<IReq>| async move { if let Some(e) = st.ok(&a.ip().to_string(), &h) { return e; } let id = b.id.trim(); if id.is_empty() { return (StatusCode::BAD_REQUEST, Json(serde_json::json!({"error":"falta id"}))); } let _l = st.mu.lock().await; let mut u = load().await; if u.remove(id).is_none() { return (StatusCode::NOT_FOUND, Json(serde_json::json!({"error":"no encontrado"}))); } save(&u).await; tokio::spawn(call(format!("{KICK_BASE}{id}&reason=kicked"))); (StatusCode::OK, Json(serde_json::json!({"ok":true}))) }))
        .route("/client/update", put(|State(st): State<AppState>, h: HeaderMap, ConnectInfo(a): ConnectInfo<SocketAddr>, Json(b): Json<UReq>| async move { if let Some(e) = st.ok(&a.ip().to_string(), &h) { return e; } let id = b.id.trim(); if id.is_empty() { return (StatusCode::BAD_REQUEST, Json(serde_json::json!({"error":"falta id"}))); } let (fid, usr, ko) = { let _l = st.mu.lock().await; let mut u = load().await; let Some(mut usr) = u.get(id).cloned() else { return (StatusCode::NOT_FOUND, Json(serde_json::json!({"error":"no encontrado"}))); }; if let Some(n) = b.name.as_deref().map(str::trim).filter(|s| !s.is_empty()) { usr.name = n.to_string(); } if let Some(d) = b.days { usr.expires_ts = now_secs() + d.max(0) * 86400; } let (fid, ko) = match b.new_id.as_deref().map(str::trim).filter(|s| !s.is_empty() && *s != id) { Some(nid) => { u.remove(id); (nid.to_string(), true) }, None => (id.to_string(), false) }; u.insert(fid.clone(), usr.clone()); save(&u).await; (fid, usr, ko) }; if ko { tokio::spawn(call(format!("{KICK_BASE}{id}&reason=kicked"))); } if usr.expires_ts <= now_secs() { tokio::spawn(call(format!("{KICK_BASE}{fid}&reason=expired"))); } else { tokio::spawn(call(format!("{PROMOTE_BASE}{fid}"))); } (StatusCode::OK, Json(row(&fid, &usr))) }))
        .with_state(AppState::new().await).into_make_service_with_connect_info::<SocketAddr>();
    info!("panel api on {PANEL_ADDR}"); axum::serve(TcpListener::bind(PANEL_ADDR).await?, app).await?; Ok(())
}
RSEOF

cd "$PROJ"
cargo build --release
