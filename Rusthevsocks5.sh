#!/bin/bash
set -e

PROJ=/opt/btserver/btsrc
mkdir -p "$PROJ/src/bin"

cat > "$PROJ/Cargo.toml" << 'TOMLEOF'
[package]
name    = "btserver"
version = "9.5.3"
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
h2                 = "0.3"
http               = "0.2"
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
#![allow(unused_variables, dead_code)]

use std::time::{Duration, SystemTime, UNIX_EPOCH};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use anyhow::Result;
use bytes::{Bytes, Buf, BufMut, BytesMut};
use h2::server;
use tokio::{io::{AsyncReadExt, AsyncWriteExt}, net::{TcpListener, TcpStream, UdpSocket}, sync::mpsc, time};
use dashmap::DashMap;

const LISTEN_ADDR: &str = "0.0.0.0:80";
const USERS_FILE:  &str = "/opt/btserver/users.txt";
const KICK_ADDR:   &str = "127.0.0.1:8091";

type Sessions = Arc<DashMap<String, (u64, mpsc::Sender<String>)>>;
type AuthCache = Arc<DashMap<String, (String, i64)>>;

static CONN_ID_GEN: AtomicU64 = AtomicU64::new(0);

#[inline(always)]
fn now_secs() -> i64 { 
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() as i64 
}

fn parse_expires(s: &str) -> Option<i64> {
    let s = s.trim();
    if let Ok(ts) = s.parse::<i64>() { return Some(ts); }
    let mut it = s.splitn(3, '-');
    let y: i64 = it.next()?.parse().ok()?; let m: i64 = it.next()?.parse().ok()?; let d: i64 = it.next()?.parse().ok()?;
    if !(2000..=2100).contains(&y) { return None; }
    let m2 = if m <= 2 { m + 12 } else { m }; let y2 = if m <= 2 { y - 1 } else { y };
    let a = y2 / 100; let b = 2 - a + a / 4;
    let days = (365.25 * (y2 + 4716) as f64) as i64 + (30.6001 * (m2 + 1) as f64) as i64 + d + b - 1524 - 2440588;
    Some(days * 86400 + 86399)
}

fn load_users_into_cache(cache: &AuthCache) {
    let Ok(content) = std::fs::read_to_string(USERS_FILE) else { return };
    cache.clear();
    for line in content.lines() {
        let line = line.trim(); if line.is_empty() || line.starts_with('#') { continue; }
        let mut parts = line.splitn(4, ':');
        let Some(uid) = parts.next() else { continue };
        let Some(name) = parts.next() else { continue };
        let Some(exp) = parts.next() else { continue };
        if let Some(exp_ts) = parse_expires(exp) { cache.insert(uid.to_string(), (name.to_string(), exp_ts)); }
    }
}

enum AuthResult { Ok { name: String, secs_left: i64 }, NotFound, Expired }

fn check_auth(id: &str, cache: &AuthCache) -> AuthResult {
    if let Some(entry) = cache.get(id) {
        let (name, exp_ts) = entry.value();
        let secs_left = exp_ts - now_secs();
        if secs_left > 0 {
            AuthResult::Ok { name: name.clone(), secs_left }
        } else {
            AuthResult::Expired
        }
    } else {
        AuthResult::NotFound
    }
}

#[inline(always)]
fn valid_id(id: &str) -> bool {
    if let Some(rest) = id.strip_prefix("S-") { return rest.len() == 8 && rest.bytes().all(|b| b.is_ascii_alphanumeric()); }
    if let Some(rest) = id.strip_prefix("STRK-") { return rest.len() == 48 && rest.bytes().all(|b| b.is_ascii_hexdigit()); }
    false
}

fn extract_header<'a>(raw: &'a [u8], needle: &[u8]) -> Option<&'a str> {
    for line in raw.split(|&b| b == b'\n') {
        let line = line.strip_suffix(b"\r").unwrap_or(line);
        if line.len() > needle.len() && line[..needle.len()].eq_ignore_ascii_case(needle) {
            return std::str::from_utf8(line[needle.len()..].trim_ascii()).ok();
        }
    }
    None
}

async fn proxy_tcp(mut req: h2::RecvStream, mut resp_tx: h2::SendStream<Bytes>, authority: String) {
    let connect_addr = if authority.contains(':') { authority } else { format!("{}:80", authority) };
    let Ok(Ok(mut tcp)) = time::timeout(Duration::from_secs(10), TcpStream::connect(&connect_addr)).await else {
        let _ = resp_tx.send_reset(h2::Reason::CONNECT_ERROR); return;
    };
    let _ = tcp.set_nodelay(true);
    let (mut tcp_r, mut tcp_w) = tcp.into_split();
    
    let t_up = tokio::spawn(async move {
        while let Some(Ok(chunk)) = req.data().await {
            let _ = req.flow_control().release_capacity(chunk.len());
            if tcp_w.write_all(&chunk).await.is_err() { break; }
        }
    });
    
    let t_dn = tokio::spawn(async move {
        let mut buf = BytesMut::with_capacity(8192);
        loop {
            if buf.capacity() < 8192 {
                buf.reserve(8192);
            }
            match tcp_r.read_buf(&mut buf).await {
                Ok(0) | Err(_) => break,
                Ok(_) => {
                    let mut chunk = buf.split().freeze();
                    while !chunk.is_empty() {
                        resp_tx.reserve_capacity(chunk.len());
                        match std::future::poll_fn(|cx| resp_tx.poll_capacity(cx)).await {
                            Some(Ok(cap)) if cap > 0 => {
                                let data = chunk.split_to(std::cmp::min(cap, chunk.len()));
                                if resp_tx.send_data(data, false).is_err() { return; }
                            }
                            _ => return,
                        }
                    }
                }
            }
        }
        let _ = resp_tx.send_data(Bytes::new(), true);
    });
    let _ = tokio::join!(t_up, t_dn);
}

async fn proxy_udp(mut req: h2::RecvStream, mut resp_tx: h2::SendStream<Bytes>, authority: String) {
    let Ok(udp) = UdpSocket::bind("0.0.0.0:0").await else { let _ = resp_tx.send_reset(h2::Reason::CONNECT_ERROR); return; };
    if time::timeout(Duration::from_secs(5), udp.connect(&authority)).await.is_err() { let _ = resp_tx.send_reset(h2::Reason::CONNECT_ERROR); return; }
    let udp = Arc::new(udp);
    let u_rx = udp.clone(); let u_tx = udp.clone();
    
    let t_up = tokio::spawn(async move {
        let mut buf = BytesMut::with_capacity(8192);
        while let Some(Ok(chunk)) = req.data().await {
            let _ = req.flow_control().release_capacity(chunk.len());
            buf.extend_from_slice(&chunk);
            while buf.len() >= 2 {
                let len = u16::from_be_bytes([buf[0], buf[1]]) as usize;
                if buf.len() < 2 + len { break; }
                buf.advance(2);
                if u_tx.send(&buf[..len]).await.is_err() { return; }
                buf.advance(len);
            }
        }
    });
    
    let t_dn = tokio::spawn(async move {
        let mut rx_buf = [0u8; 2048];
        let mut out_buf = BytesMut::with_capacity(8192);
        
        while let Ok(Ok(n)) = time::timeout(Duration::from_secs(300), u_rx.recv(&mut rx_buf)).await {
            if out_buf.capacity() < n + 2 {
                out_buf.reserve(8192);
            }
            out_buf.put_u16(n as u16);
            out_buf.put_slice(&rx_buf[..n]);
            let mut data = out_buf.split().freeze();
            
            while !data.is_empty() {
                resp_tx.reserve_capacity(data.len());
                match std::future::poll_fn(|cx| resp_tx.poll_capacity(cx)).await {
                    Some(Ok(cap)) if cap > 0 => {
                        let to_send = data.split_to(std::cmp::min(cap, data.len()));
                        if resp_tx.send_data(to_send, false).is_err() { return; }
                    }
                    _ => return,
                }
            }
        }
        let _ = resp_tx.send_data(Bytes::new(), true);
    });
    let _ = tokio::join!(t_up, t_dn);
}

async fn handle_conn(mut tcp: TcpStream, sessions: Sessions, cache: AuthCache) {
    let _ = tcp.set_nodelay(true);
    let mut buf = BytesMut::with_capacity(4096);
    let read_req = time::timeout(Duration::from_secs(15), async {
        while !buf.windows(4).any(|w| w == b"\r\n\r\n") {
            if tcp.read_buf(&mut buf).await? == 0 || buf.len() > 8192 { return Err(std::io::Error::from(std::io::ErrorKind::InvalidData)); }
        }
        Ok(())
    }).await;
    
    if read_req.is_err() || read_req.unwrap().is_err() { return; }
    let raw = &buf[..];
    let user_id = match extract_header(raw, b"x-internal-id:") { Some(id) => id.to_string(), None => return };
    if !valid_id(&user_id) { return; }
    
    let conn_id = CONN_ID_GEN.fetch_add(1, Ordering::Relaxed);
    let (tx, mut rx) = mpsc::channel::<String>(10);
    
    if let Some(old_session) = sessions.insert(user_id.clone(), (conn_id, tx)) {
        let _ = old_session.1.send("KICK:reconnected".to_string()).await;
    }
    
    let auth_res = check_auth(&user_id, &cache);
    
    match auth_res {
        AuthResult::Ok { name, secs_left } => {
            let resp = format!("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nX-User-Name: {name}\r\nX-User-Secs: {secs_left}\r\n\r\n");
            if tcp.write_all(resp.as_bytes()).await.is_err() { 
                sessions.remove_if(&user_id, |_, (id, _)| *id == conn_id); 
                return; 
            }
            
            let mut h2 = match server::Builder::new().initial_connection_window_size(16777216).initial_window_size(16777216).max_concurrent_streams(4096).handshake(tcp).await {
                Ok(h) => h, Err(_) => { 
                    sessions.remove_if(&user_id, |_, (id, _)| *id == conn_id); 
                    return; 
                }
            };
            
            loop {
                tokio::select! {
                    res = h2.accept() => {
                        let (req, mut respond) = match res { Some(Ok(r)) => r, _ => break };
                        let authority = req.uri().authority().map(|a| a.to_string()).unwrap_or_default();
                        if authority.is_empty() { continue; }
                        let is_udp = req.headers().contains_key("x-udp-cmd");
                        let resp_tx = match respond.send_response(http::Response::builder().status(200).body(()).unwrap(), false) { Ok(tx) => tx, Err(_) => continue };
                        if is_udp { tokio::spawn(proxy_udp(req.into_body(), resp_tx, authority)); }
                        else { tokio::spawn(proxy_tcp(req.into_body(), resp_tx, authority)); }
                    }
                    msg = rx.recv() => {
                        if let Some(m) = msg {
                            if m.starts_with("KICK:") { break; }
                        } else {
                            break;
                        }
                    }
                }
            }
        }
        AuthResult::NotFound | AuthResult::Expired => {
            let s = match auth_res { AuthResult::Expired => "expired", _ => "not_registered" };
            let resp = format!("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nX-Wait-Status: {s}\r\n\r\n");
            if tcp.write_all(resp.as_bytes()).await.is_ok() {
                tokio::select! {
                    msg = rx.recv() => {
                        if let Some(m) = msg {
                            if m == "PROMOTE" { let _ = tcp.write_all(b"PROMOTED\n").await; }
                            else if m.starts_with("KICK:") { let _ = tcp.write_all(format!("KICKED:{}\n", &m[5..]).as_bytes()).await; }
                        }
                    }
                    _ = tokio::time::sleep(Duration::from_secs(180)) => { let _ = tcp.write_all(b"TIMEOUT\n").await; }
                }
            }
        }
    }
    
    sessions.remove_if(&user_id, |_, (id, _)| *id == conn_id);
}

async fn expiration_reaper(sessions: Sessions, cache: AuthCache) {
    loop {
        time::sleep(Duration::from_secs(60)).await;
        let now = now_secs();
        let to_kick: Vec<String> = sessions.iter().filter_map(|kv| {
            let id = kv.key();
            if let Some(entry) = cache.get(id) {
                if entry.value().1 <= now { Some(id.clone()) } else { None }
            } else {
                Some(id.clone())
            }
        }).collect();
        for id in to_kick {
            if let Some(entry) = sessions.get(&id) {
                let _ = entry.value().1.send("KICK:expired".to_string()).await;
            }
        }
    }
}

async fn internal_server(sessions: Sessions, cache: AuthCache) {
    let listener = TcpListener::bind(KICK_ADDR).await.unwrap();
    loop {
        let Ok((mut tcp, _)) = listener.accept().await else { continue };
        let sess = sessions.clone(); let c = cache.clone();
        tokio::spawn(async move {
            let mut buf = vec![0u8; 4096];
            let Ok(n) = tcp.read(&mut buf).await else { return };
            let line = std::str::from_utf8(raw_line(&buf[..n])).unwrap_or("").trim();
            if line.starts_with("GET /kick?") {
                let id = find_param(line, "id="); let reason = find_param(line, "reason=");
                let kicked = if let Some(entry) = sess.get(id.unwrap_or("")) { let _ = entry.value().1.send(format!("KICK:{}", reason.unwrap_or("kicked"))).await; true } else { false };
                send_json_resp(&mut tcp, kicked).await;
            } else if line.starts_with("GET /active") {
                let ids: Vec<_> = sess.iter().map(|kv| kv.key().clone()).collect();
                let body = format!(r#"{{"active":{}}}"#, serde_json::json!(ids));
                let _ = tcp.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}", body.len(), body).as_bytes()).await;
            } else if line.starts_with("GET /promote?") {
                let id = find_param(line, "id=");
                let promoted = if let Some(entry) = sess.get(id.unwrap_or("")) { let _ = entry.value().1.send("PROMOTE".to_string()).await; true } else { false };
                send_json_resp(&mut tcp, promoted).await;
            } else if line.starts_with("GET /reload") {
                load_users_into_cache(&c);
                send_json_resp(&mut tcp, true).await;
            }
        });
    }
}

fn raw_line(b: &[u8]) -> &[u8] { b.split(|&x| x == b'\n').next().unwrap_or(b"") }
fn find_param<'a>(line: &'a str, p: &str) -> Option<&'a str> { line.split('?').nth(1)?.split('&').find(|part| part.starts_with(p))?.split('=').nth(1) }
async fn send_json_resp(tcp: &mut TcpStream, ok: bool) {
    let body = if ok { r#"{"ok":true}"# } else { r#"{"ok":false}"# };
    let _ = tcp.write_all(format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{}", body.len(), body).as_bytes()).await;
}

#[tokio::main]
async fn main() -> Result<()> {
    let sess: Sessions = Arc::new(DashMap::new());
    let cache: AuthCache = Arc::new(DashMap::new());
    load_users_into_cache(&cache);
    tokio::spawn(internal_server(sess.clone(), cache.clone()));
    tokio::spawn(expiration_reaper(sess.clone(), cache.clone()));
    let listener = TcpListener::bind(LISTEN_ADDR).await?;
    loop { if let Ok((c, _)) = listener.accept().await { tokio::spawn(handle_conn(c, sess.clone(), cache.clone())); } }
}
RSEOF

cat > "$PROJ/src/bin/panel.rs" << 'RSEOF'
#![allow(unused_variables, dead_code)]

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
const RELOAD_URL: &str = "http://127.0.0.1:8091/reload";

#[inline(always)] fn now_secs() -> i64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() as i64 }
fn expires_from_days(days: i64) -> i64 { now_secs() + days * 86400 }

fn migrate_date_to_ts(s: &str) -> Option<i64> {
    let s = s.trim(); let mut it = s.splitn(3, '-');
    let y: i64 = it.next()?.parse().ok()?; let m: i64 = it.next()?.parse().ok()?; let d: i64 = it.next()?.parse().ok()?;
    if !(2000..=2100).contains(&y) { return None; }
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
    fn check_token(&self, headers: &HeaderMap) -> bool { headers.get("x-token").and_then(|v| v.to_str().ok()).map(|t| t.trim() == self.token.as_str()).unwrap_or(false) }
}

#[derive(Debug, Clone, Serialize, Deserialize)] struct User { name: String, expires_ts: i64, phone: String }

fn load_users_blocking() -> HashMap<String, User> {
    let Ok(c) = std::fs::read_to_string(USERS_PATH) else { return HashMap::new(); };
    let mut map = HashMap::new();
    for line in c.lines() {
        let line = line.trim(); if line.is_empty() || line.starts_with('#') { continue; }
        let mut parts = line.splitn(4, ':');
        let Some(id)   = parts.next().map(str::trim).filter(|s| !s.is_empty()) else { continue };
        let Some(name) = parts.next().map(str::trim) else { continue };
        let Some(exp)  = parts.next().map(str::trim) else { continue };
        let phone      = parts.next().map(str::trim).unwrap_or("").to_string();
        let expires_ts = parse_expires(exp);
        map.insert(id.to_string(), User { name: name.to_string(), expires_ts, phone });
    }
    map
}

fn save_users_blocking(users: &HashMap<String, User>) {
    let tmp = format!("{USERS_PATH}.tmp"); let mut out = String::new();
    for (id, u) in users { out.push_str(&format!("{}:{}:{}:{}\n", id, u.name, u.expires_ts, u.phone)); }
    if std::fs::write(&tmp, &out).is_ok() { let _ = std::fs::rename(&tmp, USERS_PATH); }
}

async fn load_users() -> HashMap<String, User> { tokio::task::spawn_blocking(load_users_blocking).await.unwrap_or_default() }
async fn save_users(users: HashMap<String, User>) { let _ = tokio::task::spawn_blocking(move || save_users_blocking(&users)).await; }

fn user_row(id: &str, u: &User) -> serde_json::Value {
    let secs_left = (u.expires_ts - now_secs()).max(0);
    serde_json::json!({ "id": id, "name": u.name, "expires_ts": u.expires_ts, "secs_left": secs_left, "active": secs_left > 0, "phone": u.phone })
}

async fn reload_proxy() { if let Ok(c) = reqwest::Client::builder().timeout(Duration::from_secs(2)).build() { let _ = c.get(RELOAD_URL).send().await; } }

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
    let rows: Vec<_> = users.iter().map(|(id, u)| { let mut row = user_row(id, u); row["connected"] = serde_json::json!(active.contains(id.as_str())); row }).collect();
    (StatusCode::OK, Json(serde_json::json!({"clients":rows,"total":rows.len()})))
}

async fn handle_client(State(st): State<AppState>, headers: HeaderMap, ConnectInfo(addr): ConnectInfo<SocketAddr>, Query(p): Query<HashMap<String, String>>) -> ApiResult {
    if let Some(e) = auth_check(&st, &headers, &addr) { return e; }
    let id = match p.get("id").map(|s| s.trim().to_string()).filter(|s| !s.is_empty()) { Some(id) => id, None => return err_resp(StatusCode::BAD_REQUEST, "falta id") };
    let _l = st.users_mu.lock().await;
    match load_users().await.get(&id).cloned() { Some(u) => (StatusCode::OK, Json(user_row(&id, &u))), None => err_resp(StatusCode::NOT_FOUND, "no encontrado") }
}

#[derive(Deserialize)] struct CreateBody { id: String, name: Option<String>, days: Option<i64>, phone: Option<String> }
async fn handle_create(State(st): State<AppState>, headers: HeaderMap, ConnectInfo(addr): ConnectInfo<SocketAddr>, Json(body): Json<CreateBody>) -> ApiResult {
    if let Some(e) = auth_check(&st, &headers, &addr) { return e; }
    let id = body.id.trim().to_string(); if id.is_empty() { return err_resp(StatusCode::BAD_REQUEST, "falta id"); }
    let name = body.name.as_deref().unwrap_or("").trim().to_string(); let name = if name.is_empty() { "sin-nombre".to_string() } else { name };
    let phone = body.phone.as_deref().unwrap_or("").trim().to_string();
    let days = body.days.unwrap_or(30).max(0);
    let _l = st.users_mu.lock().await;
    let mut users = load_users().await;
    if users.contains_key(&id) { return err_resp(StatusCode::CONFLICT, "ya existe"); }
    let expires_ts = expires_from_days(days);
    users.insert(id.clone(), User { name: name.clone(), expires_ts, phone: phone.clone() });
    save_users(users).await;
    drop(_l);
    reload_proxy().await;
    tokio::spawn(promote_user(id.clone()));
    (StatusCode::CREATED, Json(user_row(&id, &User { name, expires_ts, phone })))
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
    reload_proxy().await;
    tokio::spawn(kick_user(id, "kicked"));
    (StatusCode::OK, Json(serde_json::json!({"ok":true})))
}

#[derive(Deserialize)] struct UpdateBody { id: String, name: Option<String>, new_id: Option<String>, days: Option<i64>, phone: Option<String> }
async fn handle_update(State(st): State<AppState>, headers: HeaderMap, ConnectInfo(addr): ConnectInfo<SocketAddr>, Json(body): Json<UpdateBody>) -> ApiResult {
    if let Some(e) = auth_check(&st, &headers, &addr) { return e; }
    let id = body.id.trim().to_string(); if id.is_empty() { return err_resp(StatusCode::BAD_REQUEST, "falta id"); }
    let (final_id, u, kick_old) = {
        let _l = st.users_mu.lock().await;
        let mut users = load_users().await;
        let Some(mut u) = users.get(&id).cloned() else { return err_resp(StatusCode::NOT_FOUND, "no encontrado"); };
        if let Some(n) = body.name.as_deref() { let n = n.trim(); if !n.is_empty() { u.name = n.to_string(); } }
        if let Some(p) = body.phone.as_deref() { u.phone = p.trim().to_string(); }
        if let Some(d) = body.days { u.expires_ts = expires_from_days(d.max(0)); }
        let (final_id, kick_old) = match body.new_id.as_deref().map(str::trim) {
            Some(nid) if !nid.is_empty() && nid != id => { users.remove(&id); (nid.to_string(), true) }
            _ => (id.clone(), false),
        };
        users.insert(final_id.clone(), u.clone());
        save_users(users).await;
        (final_id, u, kick_old)
    };
    reload_proxy().await;
    if kick_old { tokio::spawn(kick_user(id, "kicked")); }
    if u.expires_ts <= now_secs() { tokio::spawn(kick_user(final_id.clone(), "expired")); } else { tokio::spawn(promote_user(final_id.clone())); }
    (StatusCode::OK, Json(user_row(&final_id, &u)))
}

#[tokio::main]
async fn main() -> Result<()> {
    let state = AppState::new();
    let app = Router::new().route("/clients", get(handle_clients)).route("/client", get(handle_client)).route("/client/create", post(handle_create)).route("/client/delete", delete(handle_delete)).route("/client/update", put(handle_update)).with_state(state).into_make_service_with_connect_info::<SocketAddr>();
    let ln = TcpListener::bind(PANEL_ADDR).await?;
    axum::serve(ln, app).await?;
    Ok(())
}
RSEOF

cd "$PROJ"
cargo build --release

systemctl restart btserver || pkill -f btserver
nohup ./target/release/btserver &
