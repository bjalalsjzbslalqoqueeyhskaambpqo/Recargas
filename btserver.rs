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
use dashmap::DashMap;
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

const HEV_ADDR:             &str     = "127.0.0.1:1080";
const LISTEN_ADDR:          &str     = "0.0.0.0:80";
const KICK_ADDR:            &str     = "127.0.0.1:8091";
const USERS_FILE:           &str     = "/opt/btserver/users.txt";
const MAX_STREAMS:          usize    = 7000;
const QUEUE_SIZE:           usize    = 256;
const MAX_PAYLOAD:          usize    = 16384;
const DIAL_TIMEOUT:         Duration = Duration::from_millis(200);
const HEV_CONN_TIMEOUT:     Duration = Duration::from_secs(1);
const HEV_WRITE_TIMEOUT:    Duration = Duration::from_secs(2);
const CLIENT_WRITE_TIMEOUT: Duration = Duration::from_secs(30);
const BACKPRESSURE_TIMEOUT: Duration = Duration::from_secs(10);
const STREAM_IDLE_TIMEOUT:  i64      = 600;
const MUX_WRITE_QUEUE:      usize    = 2048;
const CTRL_QUEUE:           usize    = 128;
const MAX_BATCH:            usize    = 64;
const READ_DEADLINE:        Duration = Duration::from_secs(120);
const PAYLOAD_DEADLINE:     Duration = Duration::from_secs(30);
const HEV_RCVBUF:           i32      = 524288;
const HEV_SNDBUF:           i32      = 524288;
const CLI_RCVBUF:           i32      = 524288;
const CLI_SNDBUF:           i32      = 524288;
const POOL_PREALLOC:        usize    = 2048;

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
    let a  = y2 / 100;
    let b  = 2 - a + a / 4;
    (365.25 * (y2 + 4716) as f64) as i64
        + (30.6001 * (m2 + 1) as f64) as i64
        + d + b - 1524 - 2440588
}

fn parse_date_end(s: &str) -> Option<i64> {
    let s = s.trim();
    let mut it = s.splitn(3, '-');
    let y: i64 = it.next()?.parse().ok()?;
    let m: i64 = it.next()?.parse().ok()?;
    let d: i64 = it.next()?.parse().ok()?;
    Some(civil_to_epoch_days(y, m, d) * 86400 + 86399 - *UTC_OFFSET)
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

// ── Buffer pool (lock-free) ───────────────────────────────────────────────────

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

// ── Socket tuning ─────────────────────────────────────────────────────────────

unsafe fn setsockopt_i32(fd: i32, level: i32, opt: i32, val: i32) {
    libc::setsockopt(
        fd, level, opt,
        &val as *const i32 as *const libc::c_void,
        std::mem::size_of::<i32>() as libc::socklen_t,
    );
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
        setsockopt_i32(fd, libc::IPPROTO_TCP, libc::TCP_QUICKACK,  1);
        setsockopt_i32(fd, libc::SOL_SOCKET,  libc::SO_RCVBUF,     HEV_RCVBUF);
        setsockopt_i32(fd, libc::SOL_SOCKET,  libc::SO_SNDBUF,     HEV_SNDBUF);
        setsockopt_i32(fd, libc::SOL_SOCKET,  libc::SO_KEEPALIVE,  1);
        setsockopt_i32(fd, libc::IPPROTO_TCP, libc::TCP_KEEPIDLE,  30);
        setsockopt_i32(fd, libc::IPPROTO_TCP, libc::TCP_KEEPINTVL, 10);
        setsockopt_i32(fd, libc::IPPROTO_TCP, libc::TCP_KEEPCNT,   3);
    }
}

// ── Stream ────────────────────────────────────────────────────────────────────

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

// ── Mux ───────────────────────────────────────────────────────────────────────
// DashMap replaces tokio::RwLock<HashMap>:
//   - get_stream / add_stream / del_stream / close_stream are now synchronous
//   - No yield points in the hot T_DATA path
//   - Sharded internally — concurrent reads/writes don't block each other

struct Mux {
    write_tx: mpsc::Sender<Bytes>,
    ctrl_tx:  mpsc::Sender<Bytes>,
    streams:  DashMap<u32, Arc<Stream>>,
    count:    AtomicU32,
    dead:     AtomicBool,
    pool:     BufPool,
}

impl Mux {
    fn new(write_tx: mpsc::Sender<Bytes>, ctrl_tx: mpsc::Sender<Bytes>, pool: BufPool) -> Arc<Self> {
        Arc::new(Self {
            write_tx, ctrl_tx,
            streams: DashMap::with_capacity(128),
            count:   AtomicU32::new(0),
            dead:    AtomicBool::new(false),
            pool,
        })
    }

    #[inline] fn is_dead(&self) -> bool { self.dead.load(Ordering::Acquire) }

    // Backpressure: instead of dropping the frame when the write channel is full,
    // wait up to BACKPRESSURE_TIMEOUT for the write_loop to drain.
    // This propagates TCP slow-consumer pressure back to hev naturally.
    async fn send_data(&self, sid: u32, data: &[u8]) {
        if self.is_dead() { return; }
        let frame = self.pool.data(sid, data);
        match tokio::time::timeout(BACKPRESSURE_TIMEOUT, self.write_tx.send(frame)).await {
            Ok(Ok(())) => {}
            _ => { self.close_stream(sid); }
        }
    }

    async fn send_ctrl(&self, t: u8, sid: u32) {
        if self.is_dead() { return; }
        let _ = self.ctrl_tx.try_send(self.pool.ctrl(t, sid));
    }

    // All stream map operations are now synchronous — no await, no lock contention stall
    #[inline]
    fn add_stream(&self, sid: u32, s: Arc<Stream>) -> bool {
        if self.streams.len() >= MAX_STREAMS { return false; }
        self.streams.insert(sid, s);
        self.count.fetch_add(1, Ordering::Relaxed);
        true
    }

    #[inline]
    fn get_stream(&self, sid: u32) -> Option<Arc<Stream>> {
        self.streams.get(&sid).map(|e| e.value().clone())
    }

    #[inline]
    fn del_stream(&self, sid: u32) {
        if self.streams.remove(&sid).is_some() {
            self.count.fetch_sub(1, Ordering::Relaxed);
        }
    }

    // Atomic close: try_close + del in one logical step
    #[inline]
    fn close_stream(&self, sid: u32) {
        if let Some(entry) = self.streams.get(&sid) {
            if entry.value().try_close() {
                drop(entry); // release shard lock before remove
                self.del_stream(sid);
            }
        }
    }
}

// ── Session map (connect/disconnect only — not in data path) ──────────────────
type SessionMap = Arc<RwLock<HashMap<String, Arc<Mux>>>>;

async fn kick_session(sessions: &SessionMap, id: &str, reason: u8) -> bool {
    let entry = sessions.write().await.remove(id);
    if let Some(mux) = entry {
        mux.dead.store(true, Ordering::Release);
        let _ = mux.ctrl_tx.try_send(mux.pool.ctrl(reason, 0));
        info!(id, reason, "session kicked");
        true
    } else {
        false
    }
}

// ── Write loop ────────────────────────────────────────────────────────────────
// Batches up to MAX_BATCH frames and flushes with write_vectored (one syscall).
// ctrl_tx is biased-first so PING/KICK/CLOSE are never stuck behind data.

async fn write_loop(
    mut writer:   OwnedWriteHalf,
    mut write_rx: mpsc::Receiver<Bytes>,
    mut ctrl_rx:  mpsc::Receiver<Bytes>,
    mux:          Arc<Mux>,
) {
    let mut batch: Vec<Bytes>       = Vec::with_capacity(MAX_BATCH);
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
            // slices declared inside inner loop — no borrow conflict with batch
            let slices: Vec<IoSlice> = {
                let mut off = 0usize;
                batch.iter().filter_map(|b| {
                    let start = off;
                    off += b.len();
                    if start + b.len() <= written { return None; }
                    let skip = written.saturating_sub(start);
                    Some(IoSlice::new(&b[skip..]))
                }).collect()
            };
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

// ── Stream handler ────────────────────────────────────────────────────────────
// t_c2h: client → hev (reads from mux channel, writes to hev socket)
// t_h2c: hev → client (reads from hev socket, pushes through mux with backpressure)

async fn handle_stream(
    mux:    Arc<Mux>,
    sid:    u32,
    stream: Arc<Stream>,
    mut rx: mpsc::Receiver<Bytes>,
    first:  Bytes,
) {
    let hev = match tokio::time::timeout(DIAL_TIMEOUT, TcpStream::connect(HEV_ADDR)).await {
        Ok(Ok(c)) => c,
        _ => {
            if stream.try_close() {
                mux.del_stream(sid);
                mux.send_ctrl(T_CLOSE, sid).await;
            }
            return;
        }
    };
    tune_hev_fd(hev.as_raw_fd());

    let (mut hev_r, mut hev_w) = hev.into_split();

    if !first.is_empty() {
        if tokio::time::timeout(HEV_CONN_TIMEOUT, hev_w.write_all(&first)).await.is_err() {
            if stream.try_close() {
                mux.del_stream(sid);
                mux.send_ctrl(T_CLOSE, sid).await;
            }
            return;
        }
    }

    let mux2    = mux.clone();
    let stream2 = stream.clone();

    // client → hev
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

    // hev → client (with backpressure via send_data)
    let t_h2c = tokio::spawn(async move {
        stream.worker_count.fetch_add(1, Ordering::Relaxed);
        let mut buf = vec![0u8; MAX_PAYLOAD];
        loop {
            match hev_r.read(&mut buf).await {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    stream.touch();
                    mux2.send_data(sid, &buf[..n]).await;
                    // if mux died during backpressure wait, stop reading
                    if mux2.is_dead() { break; }
                }
            }
        }
        stream.worker_count.fetch_sub(1, Ordering::Relaxed);
    });

    let _ = tokio::join!(t_c2h, t_h2c);

    if stream.try_close() {
        mux.del_stream(sid);
        mux.send_ctrl(T_CLOSE, sid).await;
    }
}

// ── Idle reaper ───────────────────────────────────────────────────────────────

async fn idle_reaper(mux: Arc<Mux>) {
    let mut tick = time::interval(Duration::from_secs(60));
    loop {
        tick.tick().await;
        if mux.is_dead() { return; }
        // DashMap iteration holds no lock across the await below
        let stale: Vec<u32> = mux.streams.iter()
            .filter(|e| {
                let s = e.value();
                s.worker_count.load(Ordering::Relaxed) == 0
                    && !s.is_closed()
                    && s.idle_secs() > STREAM_IDLE_TIMEOUT
            })
            .map(|e| *e.key())
            .collect();
        for sid in stale {
            mux.close_stream(sid);
            mux.send_ctrl(T_CLOSE, sid).await;
        }
    }
}

// ── Mux read loop ─────────────────────────────────────────────────────────────
// Reads framed messages from the client TCP connection.
// T_DATA hot path: get_stream() is now sync (DashMap) — no yield, no lock stall.

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
                // sync — no await, no yield
                if !mux.add_stream(sid, s.clone()) {
                    mux.send_ctrl(T_CLOSE, sid).await;
                    continue;
                }
                tokio::spawn(handle_stream(mux.clone(), sid, s, rx, payload));
            }

            T_DATA => {
                // sync — no await, no lock stall in hot path
                if let Some(s) = mux.get_stream(sid) {
                    if !s.is_closed() {
                        s.touch();
                        let payload = Bytes::copy_from_slice(&rbuf[..ln]);
                        if s.tx.try_send(payload).is_err() {
                            mux.close_stream(sid);
                            mux.send_ctrl(T_CLOSE, sid).await;
                        }
                    }
                }
            }

            T_CLOSE => { mux.close_stream(sid); }
            _ => {}
        }
    }

    // drain all streams on disconnect
    let sids: Vec<u32> = mux.streams.iter().map(|e| *e.key()).collect();
    for sid in sids { mux.close_stream(sid); }
}

// ── HTTP header parser ────────────────────────────────────────────────────────

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

// ── Connection handler ────────────────────────────────────────────────────────

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
    let mux = Mux::new(write_tx, ctrl_tx, pool);

    let prev = sessions.write().await.insert(user_id.clone(), mux.clone());
    if let Some(prev_mux) = prev {
        prev_mux.dead.store(true, Ordering::Release);
        let _ = prev_mux.ctrl_tx.try_send(prev_mux.pool.ctrl(T_KICK, 0));
    }

    tokio::spawn(idle_reaper(mux.clone()));
    tokio::spawn(write_loop(writer, write_rx, ctrl_rx, mux.clone()));

    mux_run(mux.clone(), reader).await;

    let mut map = sessions.write().await;
    if map.get(&user_id).map(|m| Arc::ptr_eq(m, &mux)).unwrap_or(false) {
        map.remove(&user_id);
    }
}

// ── TCP listener ──────────────────────────────────────────────────────────────

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

// ── Kick API ──────────────────────────────────────────────────────────────────

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

// ── Midnight sweep ────────────────────────────────────────────────────────────

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

// ── Main ──────────────────────────────────────────────────────────────────────

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

    let std_ln   = build_listener().expect("listener");
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
