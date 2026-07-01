use bytes::{Buf, Bytes, BytesMut};
use h2::client::SendRequest;
use smoltcp::socket::tcp::{Socket as TcpSocket, State};
use smoltcp::socket::udp::{Socket as UdpSocket, PacketBuffer as UdpPacketBuffer, PacketMetadata};
use smoltcp::wire::{IpAddress, IpEndpoint, Ipv4Address};
use std::collections::HashMap;
use std::sync::atomic::Ordering;
use tokio::sync::mpsc;
use tokio::time::{sleep, Duration};
use log::{info, error};

use crate::nat;
use crate::stack::Stack;
use crate::state;
use crate::tun::TunDevice;
use crate::tunnel::Tunnel;
use crate::dns;

pub async fn run_bridge(
    mut stack: Stack<'_>,
    mut device: TunDevice,
    client: SendRequest<Bytes>,
) {
    let mut tcp_listen_handle = stack.create_tcp_socket();
    let tcp_endpoint = IpEndpoint::new(IpAddress::Ipv4(Ipv4Address::new(198, 18, 0, 1)), 1234);

    {
        let socket = stack.sockets.get_mut::<TcpSocket>(tcp_listen_handle);
        let _ = socket.listen(tcp_endpoint);
    }

    let udp_rx_buf = UdpPacketBuffer::new(vec![PacketMetadata::EMPTY; 256], vec![0; 65535]);
    let udp_tx_buf = UdpPacketBuffer::new(vec![PacketMetadata::EMPTY; 256], vec![0; 65535]);
    let mut udp_socket = UdpSocket::new(udp_rx_buf, udp_tx_buf);
    let udp_endpoint = IpEndpoint::new(IpAddress::Ipv4(Ipv4Address::new(198, 18, 0, 1)), 12345);
    
    let _ = udp_socket.bind(udp_endpoint);
    let udp_handle = stack.sockets.add(udp_socket);

    let mut active_tcp_streams = HashMap::new();
    let mut active_udp_streams = HashMap::new();

    loop {
        if !state::get_state().run.load(Ordering::SeqCst) { break; }

        stack.poll(&mut device);

        let mut tcp_established = false;
        {
            let socket = stack.sockets.get_mut::<TcpSocket>(tcp_listen_handle);
            if socket.state() == State::Established {
                tcp_established = true;
            }
        }

        if tcp_established {
            let src_port = {
                let socket = stack.sockets.get_mut::<TcpSocket>(tcp_listen_handle);
                socket.remote_endpoint().map(|e| e.port).unwrap_or(0)
            };

            let (target_host, dst_port) = {
                if let Ok(nat_map) = nat::get_nat().lock() {
                    if let Some(entry) = nat_map.tcp.get(&src_port) {
                        let d_ip = entry.dst_ip;
                        let d_port = entry.dst_port;
                        let (domain, ip_str) = {
                            if let Ok(cache) = dns::get_cache().lock() {
                                if let Some(d) = cache.get_domain(d_ip) {
                                    (d, "".to_string())
                                } else {
                                    ("".to_string(), format!("{}.{}.{}.{}", (d_ip >> 24) & 0xFF, (d_ip >> 16) & 0xFF, (d_ip >> 8) & 0xFF, d_ip & 0xFF))
                                }
                            } else {
                                ("".to_string(), format!("{}.{}.{}.{}", (d_ip >> 24) & 0xFF, (d_ip >> 16) & 0xFF, (d_ip >> 8) & 0xFF, d_ip & 0xFF))
                            }
                        };
                        let host = if !domain.is_empty() { domain } else { ip_str };
                        (host, d_port)
                    } else { ("".to_string(), 0) }
                } else { ("".to_string(), 0) }
            };

            if !target_host.is_empty() && dst_port > 0 {
                info!("TCP -> {}:{}", target_host, dst_port);
                let (tx_to_h2, mut rx_from_smoltcp) = mpsc::channel::<Bytes>(32);
                let (tx_to_smoltcp, rx_from_h2) = mpsc::channel::<Bytes>(32);

                active_tcp_streams.insert(tcp_listen_handle, (tx_to_h2, rx_from_h2, BytesMut::new()));

                let mut client_clone = client.clone();
                tokio::spawn(async move {
                    match Tunnel::open_stream(&mut client_clone, &target_host, dst_port, false).await {
                        Ok((mut h2_send, mut h2_recv)) => {
                            let send_task = async move {
                                while let Some(mut data) = rx_from_smoltcp.recv().await {
                                    while !data.is_empty() {
                                        h2_send.reserve_capacity(data.len());
                                        if let Some(Ok(cap)) = std::future::poll_fn(|cx| h2_send.poll_capacity(cx)).await {
                                            if cap == 0 { tokio::time::sleep(Duration::from_millis(1)).await; continue; }
                                            let chunk = data.split_to(std::cmp::min(cap, data.len()));
                                            if h2_send.send_data(chunk, false).is_err() { return; }
                                        } else { return; }
                                    }
                                }
                                let _ = h2_send.send_data(Bytes::new(), true);
                            };

                            let recv_task = async move {
                                while let Some(Ok(data)) = h2_recv.data().await {
                                    let _ = h2_recv.flow_control().release_capacity(data.len());
                                    if tx_to_smoltcp.send(data).await.is_err() { break; }
                                }
                            };
                            tokio::select! { _ = send_task => {}, _ = recv_task => {} }
                        }
                        Err(e) => {
                            error!("Error TCP {}:{}: {}", target_host, dst_port, e);
                        }
                    }
                });
            }

            tcp_listen_handle = stack.create_tcp_socket();
            let new_socket = stack.sockets.get_mut::<TcpSocket>(tcp_listen_handle);
            let _ = new_socket.listen(tcp_endpoint);
        }

        let mut to_remove_tcp = Vec::new();
        for (handle, (tx, rx, h2_buf)) in active_tcp_streams.iter_mut() {
            let socket = stack.sockets.get_mut::<TcpSocket>(*handle);
            if socket.state() == State::Closed || socket.state() == State::TimeWait {
                to_remove_tcp.push(*handle); continue;
            }
            if socket.can_recv() {
                let mut buf = BytesMut::with_capacity(65535); buf.resize(65535, 0);
                if let Ok(size) = socket.recv_slice(&mut buf) {
                    if size > 0 { buf.truncate(size); let _ = tx.try_send(buf.freeze()); }
                }
            }
            if socket.can_send() {
                if h2_buf.is_empty() {
                    if let Ok(data) = rx.try_recv() { h2_buf.extend_from_slice(&data); }
                }
                if !h2_buf.is_empty() {
                    if let Ok(sent) = socket.send_slice(h2_buf) {
                        if sent > 0 { let _ = h2_buf.split_to(sent); }
                    }
                }
            }
        }
        for handle in to_remove_tcp {
            active_tcp_streams.remove(&handle); stack.sockets.remove(handle);
        }

        let mut udp_responses = Vec::new();
        {
            let mut udp_socket = stack.sockets.get_mut::<UdpSocket>(udp_handle);
            while let Ok((data, meta)) = udp_socket.recv() {
                let src_port = meta.endpoint.port;
                if let Ok(nat_map) = nat::get_nat().lock() {
                    if let Some(entry) = nat_map.udp.get(&src_port) {
                        let d_port = entry.dst_port;
                        let d_ip = entry.dst_ip;

                        if d_port == 53 && data.len() >= 12 {
                            let mut domain = String::new();
                            let mut offset = 12;
                            let mut valid = true;
                            while offset < data.len() {
                                let len = data[offset] as usize;
                                if len == 0 { offset += 1; break; }
                                if (len & 0xC0) == 0xC0 { valid = false; break; }
                                if offset + 1 + len > data.len() { valid = false; break; }
                                if !domain.is_empty() { domain.push('.'); }
                                if let Ok(s) = std::str::from_utf8(&data[offset + 1 .. offset + 1 + len]) { domain.push_str(s); }
                                offset += 1 + len;
                            }
                            
                            if valid && offset + 4 <= data.len() {
                                let qtype = ((data[offset] as u16) << 8) | (data[offset + 1] as u16);
                                if qtype == 1 { 
                                    let fake_ip = dns::get_cache().lock().unwrap().get_or_create(&domain);
                                    let mut resp = data.to_vec();
                                    resp[2] |= 0x80; resp[3] |= 0x80;
                                    resp[6] = 0; resp[7] = 1; 
                                    resp.extend_from_slice(&[0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x04]);
                                    resp.extend_from_slice(&fake_ip.to_be_bytes());
                                    udp_responses.push((resp, meta.endpoint));
                                } else if qtype == 28 || qtype == 65 { 
                                    let mut resp = data.to_vec();
                                    resp[2] |= 0x80; resp[3] |= 0x80;
                                    resp[6] = 0; resp[7] = 0; resp[8] = 0; resp[9] = 0; resp[10] = 0; resp[11] = 0;
                                    udp_responses.push((resp, meta.endpoint));
                                }
                            }
                            continue;
                        }

                        if !active_udp_streams.contains_key(&src_port) {
                            let target_host = format!("{}.{}.{}.{}", (d_ip >> 24) & 0xFF, (d_ip >> 16) & 0xFF, (d_ip >> 8) & 0xFF, d_ip & 0xFF);
                            info!("UDP -> {}:{}", target_host, d_port);
                            let (tx_h2, mut rx_smoltcp) = mpsc::channel::<Bytes>(32);
                            let (tx_smoltcp, rx_h2) = mpsc::channel::<Bytes>(32);
                            active_udp_streams.insert(src_port, (tx_h2, rx_h2, meta.endpoint));
                            
                            let mut client_clone = client.clone();
                            tokio::spawn(async move {
                                match Tunnel::open_stream(&mut client_clone, &target_host, d_port, true).await {
                                    Ok((mut h2_send, mut h2_recv)) => {
                                        let send_task = async move {
                                            while let Some(chunk) = rx_smoltcp.recv().await {
                                                let mut prefixed = BytesMut::with_capacity(2 + chunk.len());
                                                prefixed.extend_from_slice(&(chunk.len() as u16).to_be_bytes());
                                                prefixed.extend_from_slice(&chunk);
                                                let mut dt = prefixed.freeze();
                                                while !dt.is_empty() {
                                                    h2_send.reserve_capacity(dt.len());
                                                    if let Some(Ok(cap)) = std::future::poll_fn(|cx| h2_send.poll_capacity(cx)).await {
                                                        if cap == 0 { tokio::time::sleep(Duration::from_millis(1)).await; continue; }
                                                        let c = dt.split_to(std::cmp::min(cap, dt.len()));
                                                        if h2_send.send_data(c, false).is_err() { return; }
                                                    } else { return; }
                                                }
                                            }
                                            let _ = h2_send.send_data(Bytes::new(), true);
                                        };
                                        let recv_task = async move {
                                            let mut buf = BytesMut::new();
                                            while let Some(Ok(dt)) = h2_recv.data().await {
                                                let _ = h2_recv.flow_control().release_capacity(dt.len());
                                                buf.extend_from_slice(&dt);
                                                while buf.len() >= 2 {
                                                    let length = u16::from_be_bytes([buf[0], buf[1]]) as usize;
                                                    if buf.len() < 2 + length { break; }
                                                    buf.advance(2);
                                                    let payload = buf.split_to(length).freeze();
                                                    if tx_smoltcp.send(payload).await.is_err() { return; }
                                                }
                                            }
                                        };
                                        tokio::select! { _ = send_task => {}, _ = recv_task => {} }
                                    }
                                    Err(e) => {
                                        error!("Error UDP {}:{}: {}", target_host, d_port, e);
                                    }
                                }
                            });
                        }
                        
                        if let Some((tx, _, _)) = active_udp_streams.get_mut(&src_port) {
                            let _ = tx.try_send(Bytes::copy_from_slice(data));
                        }
                    }
                }
            }
        }

        if !udp_responses.is_empty() {
            let mut udp_socket = stack.sockets.get_mut::<UdpSocket>(udp_handle);
            for (resp, ep) in udp_responses {
                let _ = udp_socket.send_slice(&resp, ep);
            }
        }

        let mut closed_udp = Vec::new();
        for (port, (_, rx, endpoint)) in active_udp_streams.iter_mut() {
            loop {
                match rx.try_recv() {
                    Ok(payload) => {
                        let mut udp_socket = stack.sockets.get_mut::<UdpSocket>(udp_handle);
                        if udp_socket.can_send() {
                            let _ = udp_socket.send_slice(&payload, *endpoint);
                        }
                    }
                    Err(tokio::sync::mpsc::error::TryRecvError::Empty) => break,
                    Err(tokio::sync::mpsc::error::TryRecvError::Disconnected) => {
                        closed_udp.push(*port);
                        break;
                    }
                }
            }
        }
        for port in closed_udp { active_udp_streams.remove(&port); }

        sleep(Duration::from_millis(2)).await;
    }
}
