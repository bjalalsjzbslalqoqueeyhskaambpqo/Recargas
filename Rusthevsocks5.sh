#!/bin/bash
set -e

PROJ=/opt/btserver/btsrc
mkdir -p "$PROJ/src/bin"

cat > "$PROJ/Cargo.toml" << 'TOMLEOF'
[package]
name    = "btserver"
version = "9.5.0"
edition = "2021"

[[bin]]
name = "btserver"
path = "src/bin/btserver.rs"

[dependencies]
tokio              = { version = "1",    features = ["full"] }
bytes              = "1"
h2                 = "0.3"
http               = "0.2"

[profile.release]
opt-level     = 3
lto           = true
codegen-units = 1
strip         = true
panic         = "abort"
TOMLEOF

cat > "$PROJ/src/bin/btserver.rs" << 'RSEOF'
use bytes::{Bytes, BytesMut};
use h2::server;
use std::sync::Arc;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream, UdpSocket},
    time::{self, Duration},
};

async fn proxy_tcp(mut req: h2::RecvStream, mut resp_tx: h2::SendStream<Bytes>, authority: String) {
    let connect_addr = if authority.contains(':') { authority.clone() } else { format!("{}:80", authority) };
    let Ok(Ok(mut tcp)) = time::timeout(Duration::from_secs(5), TcpStream::connect(&connect_addr)).await else {
        println!("[-] Fallo al conectar TCP a {}", connect_addr);
        let _ = resp_tx.send_reset(h2::Reason::CONNECT_ERROR);
        return;
    };
    let _ = tcp.set_nodelay(true);
    let (mut tcp_r, mut tcp_w) = tcp.into_split();
    
    let t_up = tokio::spawn(async move {
        while let Some(Ok(chunk)) = req.data().await {
            let _ = req.flow_control().release_capacity(chunk.len());
            if tcp_w.write_all(&chunk).await.is_err() { break; }
        }
        let _ = tcp_w.shutdown().await;
    });
    
    let t_dn = tokio::spawn(async move {
        let mut buf = [0u8; 65536];
        while let Ok(n) = tcp_r.read(&mut buf).await {
            if n == 0 { break; }
            let mut chunk = Bytes::copy_from_slice(&buf[..n]);
            while !chunk.is_empty() {
                resp_tx.reserve_capacity(chunk.len());
                if let Some(Ok(cap)) = std::future::poll_fn(|cx| resp_tx.poll_capacity(cx)).await {
                    let data = chunk.split_to(std::cmp::min(cap, chunk.len()));
                    if resp_tx.send_data(data, false).is_err() { return; }
                } else { return; }
            }
        }
        let _ = resp_tx.send_data(Bytes::new(), true);
    });
    let _ = tokio::join!(t_up, t_dn);
    println!("[*] Stream TCP cerrado: {}", authority);
}

async fn proxy_udp(mut req: h2::RecvStream, mut resp_tx: h2::SendStream<Bytes>, authority: String) {
    let Ok(udp) = UdpSocket::bind("0.0.0.0:0").await else {
        let _ = resp_tx.send_reset(h2::Reason::CONNECT_ERROR); return;
    };
    if time::timeout(Duration::from_secs(3), udp.connect(&authority)).await.is_err() {
        let _ = resp_tx.send_reset(h2::Reason::CONNECT_ERROR); return;
    }
    let udp = Arc::new(udp);
    let u_rx = udp.clone(); let u_tx = udp.clone();
    
    let t_up = tokio::spawn(async move {
        let mut buf = BytesMut::new();
        while let Some(Ok(chunk)) = req.data().await {
            let _ = req.flow_control().release_capacity(chunk.len());
            buf.extend_from_slice(&chunk);
            while buf.len() >= 2 {
                let len = u16::from_be_bytes([buf[0], buf[1]]) as usize;
                if buf.len() < 2 + len { break; }
                let payload = buf[2..2+len].to_vec();
                buf.split_to(2 + len);
                if u_tx.send(&payload).await.is_err() { return; }
            }
        }
    });
    
    let t_dn = tokio::spawn(async move {
        let mut b = [0u8; 65536];
        while let Ok(Ok(n)) = time::timeout(Duration::from_secs(60), u_rx.recv(&mut b)).await {
            let mut p = BytesMut::with_capacity(2 + n);
            p.extend_from_slice(&(n as u16).to_be_bytes());
            p.extend_from_slice(&b[..n]);
            let mut chunk = p.freeze();
            while !chunk.is_empty() {
                resp_tx.reserve_capacity(chunk.len());
                if let Some(Ok(cap)) = std::future::poll_fn(|cx| resp_tx.poll_capacity(cx)).await {
                    let data = chunk.split_to(std::cmp::min(cap, chunk.len()));
                    if resp_tx.send_data(data, false).is_err() { return; }
                } else { return; }
            }
        }
        let _ = resp_tx.send_data(Bytes::new(), true);
    });
    let _ = tokio::join!(t_up, t_dn);
    println!("[*] Stream UDP cerrado: {}", authority);
}

async fn handle_conn(mut tcp: TcpStream) {
    let _ = tcp.set_nodelay(true);
    let mut buf = Vec::new();
    let mut b = [0u8; 1];
    
    println!("[+] Nueva conexión entrante...");
    
    let read_req = time::timeout(Duration::from_secs(10), async {
        loop {
            if tcp.read_exact(&mut b).await.is_err() { return Err(()); }
            buf.push(b[0]);
            if buf.ends_with(b"\r\n\r\n") {
                let text = String::from_utf8_lossy(&buf).to_lowercase();
                if text.contains("upgrade: websocket") { break; }
            }
            if buf.len() > 8192 { return Err(()); }
        }
        Ok(())
    }).await;
    
    if read_req.is_err() || read_req.unwrap().is_err() { 
        println!("[-] Handshake HTTP fallido o timeout.");
        return; 
    }
    
    println!("[+] Handshake HTTP recibido. Enviando 101...");
    let resp = "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nX-User-Name: debug\r\nX-User-Secs: 9999\r\n\r\n";
    if tcp.write_all(resp.as_bytes()).await.is_err() { return; }
    
    println!("[+] Iniciando H2...");
    let mut h2 = match server::Builder::new()
        .initial_connection_window_size(10485760)
        .initial_window_size(5242880)
        .max_concurrent_streams(4096)
        .handshake(tcp).await 
    {
        Ok(h) => h, 
        Err(e) => { println!("[-] Error H2 Handshake: {}", e); return; }
    };
    
    println!("[+] H2 inicializado correctamente. Esperando streams...");
    
    while let Some(res) = h2.accept().await {
        let (req, mut respond) = match res { 
            Ok(r) => r, 
            Err(e) => { println!("[-] Error aceptando stream: {}", e); continue; }
        };
        
        let authority = req.uri().authority().map(|a| a.to_string()).unwrap_or_default();
        if authority.is_empty() { continue; }
        
        let is_udp = req.headers().contains_key("x-udp-cmd");
        println!("[>] Nuevo stream H2 -> {} (UDP: {})", authority, is_udp);
        
        let resp_tx = match respond.send_response(http::Response::builder().status(200).body(()).unwrap(), false) { 
            Ok(tx) => tx, 
            Err(_) => continue 
        };
        
        if is_udp { tokio::spawn(proxy_udp(req.into_body(), resp_tx, authority)); }
        else { tokio::spawn(proxy_tcp(req.into_body(), resp_tx, authority)); }
    }
    println!("[-] Conexión H2 finalizada.");
}

#[tokio::main]
async fn main() -> Result<()> {
    println!("[*] Servidor Simple H2 iniciado en {}", LISTEN_ADDR);
    let listener = TcpListener::bind(LISTEN_ADDR).await?;
    loop { 
        if let Ok((c, _)) = listener.accept().await { 
            tokio::spawn(handle_conn(c)); 
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
const RELOAD_URL: &str = "http://127.0.0.1:8091/reload";

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

async fn load_users() -> HashMap<String, User> { tokio::task::spawn_blocking(load_users_blocking).await.unwrap_or_default() }
async fn save_users(users: HashMap<String, User>) { let _ = tokio::task::spawn_blocking(move || save_users_blocking(&users)).await; }

fn user_row(id: &str, u: &User) -> serde_json::Value {
    let secs_left = (u.expires_ts - now_secs()).max(0);
    serde_json::json!({ "id": id, "name": u.name, "expires_ts": u.expires_ts, "secs_left": secs_left, "active": secs_left > 0 })
}

async fn reload_proxy() {
    if let Ok(c) = reqwest::Client::builder().timeout(Duration::from_secs(2)).build() { let _ = c.get(RELOAD_URL).send().await; }
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
    reload_proxy().await;
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
    reload_proxy().await;
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
