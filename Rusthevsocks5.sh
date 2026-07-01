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

cd "$PROJ"
cargo build --release
