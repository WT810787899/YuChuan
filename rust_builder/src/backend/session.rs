//! TCP 会话管理与断线重连（T3.1；风险9 粘包/半包、风险17 指数退避重连）。
//!
//! 结构：
//! - [`listen`]：服务端，接受连接并为每条连接起读线程；
//! - [`dial`]：客户端，带指数退避的持续重连，网络恢复后自动接回来；
//! - [`Connection`]：一条双向连接（hello 握手 / 心跳 / 文本帧 / BYE）；
//! - [`SeqTracker`]：会话内 (sender_id, seq) 单调序号，用于去重与排序（风险11 不依赖墙钟）。
//!
//! 事件通过 mpsc 推给上层（frb 层再转 Stream），不对 socket 做轮询。

use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::net::{Shutdown, SocketAddr, TcpListener, TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use super::protocol::{self, FrameType, HelloPayload, TextPayload};
use serde::{Deserialize, Serialize};

/// 默认聊天端口（随 HELLO 广播出去，M1 起邻居表里的 port 就是它）。
pub const DEFAULT_CHAT_PORT: u16 = 45_998;
/// 心跳间隔。
pub const HEARTBEAT_INTERVAL_MS: u64 = 3_000;
/// 对端静默超过该时长判定离线（PLAN：10s）。
pub const PEER_TIMEOUT_MS: u64 = 10_000;
/// TCP 连接超时。
pub const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
/// 读循环的检查节拍（决定 stop / 超时的响应粒度）。
const READ_TICK: Duration = Duration::from_millis(200);
/// 半包缓冲上限：超过即认为对端异常（防内存滥用）。
const MAX_PENDING: usize = 8 * 1024 * 1024;
/// 拨号循环里等待连接结束的节拍。
const DIAL_WATCH_TICK: Duration = Duration::from_millis(150);

/// 连接生命周期。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionState {
    Disconnected,
    Connecting,
    Connected,
    /// 指数退避中的重连等待，attempt 从 1 开始。
    Reconnecting { attempt: u32, backoff_ms: u64 },
}

/// 退避参数：min(base * 2^(attempt-1), max)。
pub fn backoff_ms(attempt: u32, base_ms: u64, max_ms: u64) -> u64 {
    let shift = attempt.saturating_sub(1).min(20);
    (base_ms.saturating_mul(1u64 << shift)).min(max_ms)
}

/// 推给上层（frb Stream / UI）的会话事件。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionEvent {
    /// 收到对端 hello，会话可用。
    Connected {
        peer_id: String,
        name: String,
        addr: String,
    },
    /// 会话断开。peer_id 在还没握手成功时可能为 None。
    Disconnected {
        peer_id: Option<String>,
        reason: String,
    },
    /// 对端**静默**（一段时间没读到任何字节）—— B1-4。
    ///
    /// 注意这**不是**断开：连接与 socket 都还活着，只是暂时没听到对端。
    /// 上层据此收缩「在线」的展示（间隔问候口径），但不得据此判死 / 重拨。
    Stalled {
        peer_id: Option<String>,
        silent_ms: u64,
    },
    /// 收到文本消息（已通过 SeqTracker 去重）。
    Message {
        peer_id: String,
        message: TextPayload,
    },
    /// 本地一帧已写出（UI 的「已发出」用）。
    Sent { peer_id: Option<String>, seq: u64 },
    /// 收到 PAIR_REQ（T2.1 配对状态机的应答方入口）。
    PairRequest {
        peer_id: String,
        pin: String,
        ts_ms: u64,
    },
    /// 收到 PAIR_RESP（发起方据此结束等待）。
    PairResponse {
        peer_id: String,
        accepted: bool,
        reason: Option<String>,
    },
    /// 收到 FILE_META（接收方 driver 调 Receiver::on_meta 回 ack）。
    FileMeta {
        peer_id: String,
        meta: super::protocol::FileMetaPayload,
    },
    /// 收到 FILE_CHUNK。
    FileChunk {
        peer_id: String,
        offset: u64,
        data: Vec<u8>,
    },
    /// 收到 FILE_ACK（发送方推进确认位）。
    FileAck {
        peer_id: String,
        ack: super::protocol::FileAckPayload,
    },
    /// 收到 FILE_DONE（双向：发送方回执 / 接收方请求校验）。
    FileDone {
        peer_id: String,
        done: super::protocol::FileDonePayload,
    },
    /// 收到 FILE_ABORT（对端取消了传输，接收方丢弃 .part）。
    FileAbort {
        peer_id: String,
        file_id: String,
    },
}

/// 会话参数。
#[derive(Debug, Clone)]
pub struct SessionConfig {
    /// 本机 hello（复用发现用的 HelloPayload）。
    pub self_hello: HelloPayload,
    pub heartbeat: Duration,
    pub peer_timeout: Duration,
    pub base_backoff_ms: u64,
    pub max_backoff_ms: u64,
}

impl SessionConfig {
    pub fn new(self_hello: HelloPayload) -> Self {
        Self {
            self_hello,
            heartbeat: Duration::from_millis(HEARTBEAT_INTERVAL_MS),
            peer_timeout: Duration::from_millis(PEER_TIMEOUT_MS),
            base_backoff_ms: 500,
            max_backoff_ms: 30_000,
        }
    }

    pub fn with_timing(mut self, heartbeat: Duration, peer_timeout: Duration) -> Self {
        self.heartbeat = heartbeat;
        self.peer_timeout = peer_timeout;
        self
    }
}

/// 连接共享状态。
#[derive(Debug)]
struct Shared {
    alive: AtomicBool,
    last_rx: Mutex<Instant>,
    addr: SocketAddr,
    peer_id: Mutex<Option<String>>,
    peer_name: Mutex<Option<String>>,
    /// 已见的最大 (sender_id, seq)，用于去重/排序。
    seqs: Mutex<SeqTracker>,
}

impl Shared {
    /// 导出当前去重/发送序号状态（Task 5 落盘用）。
    pub fn seq_snapshot(&self) -> SeqState {
        self.seqs
            .lock()
            .map(|t| t.snapshot())
            .unwrap_or_default()
    }
}

/// 一条已建立的 TCP 连接。
pub struct Connection {
    addr: SocketAddr,
    shared: Arc<Shared>,
    /// 所有写出都过这把锁：心跳与业务帧不会在字节层面交错。
    out: Arc<Mutex<TcpStream>>,
}

impl Connection {
    /// 用一条已连接的 socket 起会话（双方都会立刻互发 hello）。
    pub fn start(
        stream: TcpStream,
        cfg: SessionConfig,
        events: Sender<SessionEvent>,
    ) -> io::Result<Self> {
        Self::start_with_seqs(stream, cfg, events, SeqState::default())
    }

    /// 带既有序号状态起会话：重连时必须走这个入口，
    /// 否则 `out_seq` 归零会让新消息被对端当作旧的丢弃（见 SeqTracker 文档）。
    pub fn start_with_seqs(
        stream: TcpStream,
        cfg: SessionConfig,
        events: Sender<SessionEvent>,
        seq_state: SeqState,
    ) -> io::Result<Self> {
        let addr = stream.peer_addr()?;
        stream.set_read_timeout(Some(READ_TICK))?;
        // 局域网小消息：关掉 Nagle，避免 40ms 级延迟
        let _ = stream.set_nodelay(true);

        let read_half = stream.try_clone()?;
        let out = Arc::new(Mutex::new(stream));
        let shared = Arc::new(Shared {
            alive: AtomicBool::new(true),
            last_rx: Mutex::new(Instant::now()),
            addr,
            peer_id: Mutex::new(None),
            peer_name: Mutex::new(None),
            seqs: Mutex::new(SeqTracker::from_state(seq_state)),
        });

        // 读线程
        {
            let shared = Arc::clone(&shared);
            let out = Arc::clone(&out);
            let events = events.clone();
            let timeout = cfg.peer_timeout;
            thread::Builder::new()
                .name("lanchat-session-rx".into())
                .spawn(move || reader_loop(read_half, out, shared, events, timeout))?;
        }
        // 心跳线程
        {
            let shared = Arc::clone(&shared);
            let out = Arc::clone(&out);
            let interval = cfg.heartbeat;
            thread::Builder::new()
                .name("lanchat-session-hb".into())
                .spawn(move || heartbeat_loop(out, shared, interval))?;
        }

        let conn = Self { addr, shared, out };
        conn.send_hello(&cfg.self_hello)?;
        Ok(conn)
    }

    pub fn addr(&self) -> SocketAddr {
        self.addr
    }

    pub fn peer_id(&self) -> Option<String> {
        self.shared.peer_id.lock().map(|g| g.clone()).unwrap_or(None)
    }

    pub fn peer_name(&self) -> Option<String> {
        self.shared
            .peer_name
            .lock()
            .map(|g| g.clone())
            .unwrap_or(None)
    }

    pub fn is_alive(&self) -> bool {
        self.shared.alive.load(Ordering::SeqCst)
    }

    /// 发任意帧（配对帧等由上层构造 payload）。
    pub fn send_frame(&self, kind: FrameType, payload: &[u8]) -> io::Result<()> {
        let frame = protocol::encode(kind, payload);
        let mut out = self.out.lock().map_err(|_| {
            io::Error::new(io::ErrorKind::Other, "session write lock poisoned")
        })?;
        out.write_all(&frame)?;
        out.flush()
    }

    /// 发本机 hello（连接建立后双方都发，对端据此知道我们是谁）。
    pub fn send_hello(&self, hello: &HelloPayload) -> io::Result<()> {
        let json = serde_json::to_vec(hello)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        self.send_frame(FrameType::Hello, &json)
    }

    /// 发一条文本消息，返回使用的 seq。
    pub fn send_text(&self, sender_id: &str, seq: u64, text: &str, ts_ms: i64) -> io::Result<()> {
        let payload = TextPayload {
            sender_id: sender_id.to_string(),
            seq,
            text: text.to_string(),
            ts_ms,
        };
        let json = serde_json::to_vec(&payload)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        self.send_frame(FrameType::Text, &json)?;
        Ok(())
    }

    /// 优雅关闭：发 BYE 再关 socket。
    pub fn close(&self, reason: &str) {
        if !self.shared.alive.swap(false, Ordering::SeqCst) {
            return;
        }
        let payload = serde_json::json!({ "reason": reason });
        let _ = self.send_frame(FrameType::Bye, payload.to_string().as_bytes());
        if let Ok(out) = self.out.lock() {
            let _ = out.shutdown(Shutdown::Both);
        }
    }
}

impl Drop for Connection {
    fn drop(&mut self) {
        // 连接对象被丢弃 = 上层不再需要这条会话
        self.shared.alive.store(false, Ordering::SeqCst);
        if let Ok(out) = self.out.lock() {
            let _ = out.shutdown(Shutdown::Both);
        }
    }
}

fn emit(events: &Sender<SessionEvent>, event: SessionEvent) {
    let _ = events.send(event);
}

fn peer_id_of(shared: &Shared) -> Option<String> {
    shared.peer_id.lock().map(|g| g.clone()).unwrap_or(None)
}

/// 读循环：粘包/半包由 protocol::decode 处理，这里只管缓冲与事件。
fn reader_loop(
    mut stream: TcpStream,
    out: Arc<Mutex<TcpStream>>,
    shared: Arc<Shared>,
    events: Sender<SessionEvent>,
    timeout: Duration,
) {
    let mut pending: Vec<u8> = Vec::with_capacity(8 * 1024);
    let mut chunk = [0u8; 4096];
    let reason: &str; // 所有 break 路径都会先赋值，延迟初始化避免死存储警告
    // 「已经就静默上报过一次」的节流标志（B1-4）：静默不再判死，只上报一次
    // Stalled，避免每 200ms 的 READ_TICK 都推一条。
    let stalled_reported = AtomicBool::new(false);

    'outer: loop {
        if !shared.alive.load(Ordering::SeqCst) {
            reason = "closed";
            break;
        }
        match stream.read(&mut chunk) {
            Ok(0) => {
                reason = "eof";
                break;
            }
            Ok(n) => {
                if let Ok(mut last) = shared.last_rx.lock() {
                    *last = Instant::now();
                }
                pending.extend_from_slice(&chunk[..n]);
                loop {
                    match protocol::decode(&pending) {
                        Ok(Some((frame, used))) => {
                            pending.drain(..used);
                            match handle_frame(&frame, &shared, &out, &events) {
                                FrameOutcome::Continue => {}
                                FrameOutcome::Close(r) => {
                                    reason = r;
                                    break 'outer;
                                }
                            }
                        }
                        Ok(None) => break, // 半包：等更多字节
                        Err(_) => {
                            reason = "protocol";
                            break 'outer;
                        }
                    }
                }
                if pending.len() > MAX_PENDING {
                    reason = "oversize";
                    break;
                }
            }
            Err(ref e)
                if e.kind() == io::ErrorKind::WouldBlock
                    || e.kind() == io::ErrorKind::TimedOut =>
            {
                let idle = shared
                    .last_rx
                    .lock()
                    .map(|t| t.elapsed())
                    .unwrap_or_default();
                if idle > timeout {
                    // 用户口径（B1-4）：「不需要判得那么死，没有关键事件触发，
                    // 不用太严，间隔问候就行」。
                    //
                    // 纯静默**不是关键事件**：安卓后台被 Doze / 国产 ROM 冻结时，
                    // 进程和通知栏都还在跑，只是心跳线程暂时没被调度；PC 侧却在这里
                    // 10s 一到就判死并断开 socket，反向同理 —— 这正是用户看到的
                    // 「软件明明都开着，一直显示断开断开」。
                    //
                    // 所以这里**不断开**：只把「很久没听到对端」的事实用
                    // SessionEvent::Stalled 通知上层（上层据此收缩在线展示），
                    // 连接本身继续保留，socket 继续等 —— 对端一旦恢复调度，
                    // 下一帧/下一个心跳立刻让会话回到活跃。
                    //
                    // 真正该断的仍然是真事件（Eof/Io/Protocol/Bye/Oversize），
                    // 见下面各分支。这**不是**「把超时调大」：超时值不再有任何
                    // 判死语义，只是上报一次告警的节流阈值。
                    if !stalled_reported.swap(true, Ordering::SeqCst) {
                        emit(
                            &events,
                            SessionEvent::Stalled {
                                peer_id: peer_id_of(&shared),
                                silent_ms: idle.as_millis().min(u64::MAX as u128) as u64,
                            },
                        );
                    }
                }
            }
            Err(_) => {
                reason = "io";
                break;
            }
        }
    }

    shared.alive.store(false, Ordering::SeqCst);
    emit(
        &events,
        SessionEvent::Disconnected {
            peer_id: peer_id_of(&shared),
            reason: reason.to_string(),
        },
    );
    let _ = stream.shutdown(Shutdown::Both);
}

enum FrameOutcome {
    Continue,
    Close(&'static str),
}

fn handle_frame(
    frame: &protocol::Frame,
    shared: &Arc<Shared>,
    out: &Arc<Mutex<TcpStream>>,
    events: &Sender<SessionEvent>,
) -> FrameOutcome {
    match frame.kind {
        FrameType::Hello | FrameType::HelloAck => {
            let Ok(hello) = serde_json::from_slice::<HelloPayload>(&frame.payload) else {
                return FrameOutcome::Close("protocol");
            };
            if hello.device_id.is_empty() {
                return FrameOutcome::Close("protocol");
            }
            if let Ok(mut id) = shared.peer_id.lock() {
                *id = Some(hello.device_id.clone());
            }
            if let Ok(mut name) = shared.peer_name.lock() {
                *name = Some(hello.name.clone());
            }
            emit(
                events,
                SessionEvent::Connected {
                    peer_id: hello.device_id,
                    name: hello.name,
                    addr: shared.addr.to_string(),
                },
            );
            FrameOutcome::Continue
        }
        FrameType::Ping => {
            // 回 pong（保持对端 last_rx 新鲜，对端超时判定才准）
            if let Ok(mut o) = out.lock() {
                let pong = protocol::encode(FrameType::Pong, b"");
                if o.write_all(&pong).is_err() || o.flush().is_err() {
                    return FrameOutcome::Close("io");
                }
            }
            FrameOutcome::Continue
        }
        FrameType::Pong => FrameOutcome::Continue,
        FrameType::Text => {
            let Ok(msg) = serde_json::from_slice::<TextPayload>(&frame.payload) else {
                return FrameOutcome::Close("protocol");
            };
            let peer_id = peer_id_of(shared).unwrap_or_else(|| msg.sender_id.clone());
            let fresh = shared
                .seqs
                .lock()
                .map(|mut t| t.accept(&msg.sender_id, msg.seq))
                .unwrap_or(false);
            if fresh {
                emit(
                    events,
                    SessionEvent::Message {
                        peer_id,
                        message: msg,
                    },
                );
            }
            FrameOutcome::Continue
        }
        FrameType::PairReq => {
            let Ok(payload) =
                serde_json::from_slice::<super::protocol::PairReqPayload>(&frame.payload)
            else {
                return FrameOutcome::Close("protocol");
            };
            let peer_id = peer_id_of(shared).unwrap_or_else(|| payload.device_id.clone());
            emit(
                events,
                SessionEvent::PairRequest {
                    peer_id,
                    pin: payload.pin,
                    ts_ms: payload.ts_ms,
                },
            );
            FrameOutcome::Continue
        }
        FrameType::PairResp => {
            let Ok(payload) =
                serde_json::from_slice::<super::protocol::PairRespPayload>(&frame.payload)
            else {
                return FrameOutcome::Close("protocol");
            };
            let peer_id = peer_id_of(shared).unwrap_or_default();
            emit(
                events,
                SessionEvent::PairResponse {
                    peer_id,
                    accepted: payload.accepted,
                    reason: payload.reason,
                },
            );
            FrameOutcome::Continue
        }
        FrameType::FileMeta => {
            let Ok(meta) = serde_json::from_slice::<super::protocol::FileMetaPayload>(
                &frame.payload,
            ) else {
                return FrameOutcome::Close("protocol");
            };
            let peer_id = peer_id_of(shared).unwrap_or_else(|| meta.sender_id.clone());
            emit(events, SessionEvent::FileMeta { peer_id, meta });
            FrameOutcome::Continue
        }
        FrameType::FileChunk => {
            let Some((offset, data)) = super::protocol::decode_chunk(&frame.payload) else {
                return FrameOutcome::Close("protocol");
            };
            let peer_id = peer_id_of(shared).unwrap_or_default();
            emit(
                events,
                SessionEvent::FileChunk {
                    peer_id,
                    offset,
                    data: data.to_vec(),
                },
            );
            FrameOutcome::Continue
        }
        FrameType::FileAck => {
            let Ok(ack) =
                serde_json::from_slice::<super::protocol::FileAckPayload>(&frame.payload)
            else {
                return FrameOutcome::Close("protocol");
            };
            let peer_id = peer_id_of(shared).unwrap_or_default();
            emit(events, SessionEvent::FileAck { peer_id, ack });
            FrameOutcome::Continue
        }
        FrameType::FileDone => {
            let Ok(done) =
                serde_json::from_slice::<super::protocol::FileDonePayload>(&frame.payload)
            else {
                return FrameOutcome::Close("protocol");
            };
            let peer_id = peer_id_of(shared).unwrap_or_default();
            emit(events, SessionEvent::FileDone { peer_id, done });
            FrameOutcome::Continue
        }
        FrameType::FileAbort => {
            let Ok(abort) =
                serde_json::from_slice::<super::protocol::FileAbortPayload>(&frame.payload)
            else {
                return FrameOutcome::Close("protocol");
            };
            let peer_id = peer_id_of(shared).unwrap_or_default();
            emit(
                events,
                SessionEvent::FileAbort {
                    peer_id,
                    file_id: abort.file_id,
                },
            );
            FrameOutcome::Continue
        }
        FrameType::Bye => FrameOutcome::Close("bye"),
    }
}

fn heartbeat_loop(out: Arc<Mutex<TcpStream>>, shared: Arc<Shared>, interval: Duration) {
    let ping = protocol::encode(FrameType::Ping, b"");
    loop {
        thread::sleep(interval);
        if !shared.alive.load(Ordering::SeqCst) {
            break;
        }
        let Ok(mut o) = out.lock() else { break };
        if o.write_all(&ping).is_err() || o.flush().is_err() {
            break;
        }
    }
}

/// 服务端：监听端口，为每条进来的连接起会话。
pub struct Listener {
    local_addr: SocketAddr,
    stop: Arc<AtomicBool>,
    thread: Option<thread::JoinHandle<()>>,
    connections: Arc<Mutex<Vec<Connection>>>,
}

impl Listener {
    pub fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }

    /// 当前活着的连接数。
    pub fn connection_count(&self) -> usize {
        self.connections
            .lock()
            .map(|g| g.iter().filter(|c| c.is_alive()).count())
            .unwrap_or(0)
    }

    /// 已握手完成的对端 device_id 列表。
    pub fn peers(&self) -> Vec<String> {
        self.connections
            .lock()
            .map(|guard| {
                guard
                    .iter()
                    .filter(|c| c.is_alive())
                    .filter_map(|c| c.peer_id())
                    .collect()
            })
            .unwrap_or_default()
    }

    /// 向指定对端发文本（监听端回消息用；主动拨号方向用 Dialer::send_text）。
    ///
    /// `next_seq` 由调用方提供：同一个 sender 在拨号连接与监听连接上是两条
    /// 不同的 `Connection`，若各自计数就会拿到相同 seq，对端 `accept()` 只按
    /// sender_id 去重、`seq <= last_seen` 即静默丢弃（用户报的「收不到」）。
    /// 序号所有权归调用方（见 `crate::api::chat` 的 `OUT_SEQ`）。
    pub fn send_text_to(
        &self,
        peer_id: &str,
        sender_id: &str,
        text: &str,
        ts_ms: i64,
        next_seq: impl FnOnce() -> u64,
    ) -> io::Result<u64> {
        let mut guard = self
            .connections
            .lock()
            .map_err(|_| io::Error::new(io::ErrorKind::Other, "listener poisoned"))?;
        let conn = guard
            .iter_mut()
            .find(|c| c.is_alive() && c.peer_id().as_deref() == Some(peer_id))
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::NotConnected,
                    format!("没有对端 {peer_id} 的活连接"),
                )
            })?;
        let seq = next_seq();
        conn.send_text(sender_id, seq, text, ts_ms)?;
        Ok(seq)
    }

    /// 向指定对端发任意帧（配对握手等）。
    pub fn send_frame_to(
        &self,
        peer_id: &str,
        kind: FrameType,
        payload: &[u8],
    ) -> io::Result<()> {
        let guard = self
            .connections
            .lock()
            .map_err(|_| io::Error::new(io::ErrorKind::Other, "listener poisoned"))?;
        let conn = guard
            .iter()
            .find(|c| c.is_alive() && c.peer_id().as_deref() == Some(peer_id))
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::NotConnected,
                    format!("没有对端 {peer_id} 的活连接"),
                )
            })?;
        conn.send_frame(kind, payload)
    }

    /// 主动断开所有连接并停止接受新连接。
    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Ok(mut conns) = self.connections.lock() {
            for conn in conns.iter() {
                conn.close("local stop");
            }
            conns.clear();
        }
        if let Some(handle) = self.thread.take() {
            let _ = handle.join();
        }
    }
}

impl Drop for Listener {
    fn drop(&mut self) {
        self.stop();
    }
}

/// 启动服务端。port = 0 时由系统分配（测试用），实际端口见 local_addr。
pub fn listen(
    cfg: SessionConfig,
    port: u16,
    events: Sender<SessionEvent>,
) -> io::Result<Listener> {
    let listener = TcpListener::bind(("0.0.0.0", port))?;
    listener.set_nonblocking(true)?;
    let local_addr = listener.local_addr()?;
    let stop = Arc::new(AtomicBool::new(false));
    let connections: Arc<Mutex<Vec<Connection>>> = Arc::new(Mutex::new(Vec::new()));

    let thread = {
        let stop = Arc::clone(&stop);
        let connections = Arc::clone(&connections);
        let cfg = cfg.clone();
        let events = events.clone();
        thread::Builder::new()
            .name("lanchat-session-accept".into())
            .spawn(move || {
                while !stop.load(Ordering::SeqCst) {
                    match listener.accept() {
                        Ok((stream, _)) => {
                            match Connection::start_with_seqs(
                                stream,
                                cfg.clone(),
                                events.clone(),
                                SeqState::default(),
                            ) {
                                Ok(conn) => {
                                    if let Ok(mut guard) = connections.lock() {
                                        guard.retain(|c| c.is_alive());
                                        guard.push(conn);
                                    }
                                }
                                Err(_) => {
                                    // 连接建立失败：丢弃这条，继续接受
                                }
                            }
                        }
                        Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => {
                            thread::sleep(Duration::from_millis(50));
                        }
                        Err(_) => thread::sleep(Duration::from_millis(100)),
                    }
                }
            })?
    };

    Ok(Listener {
        local_addr,
        stop,
        thread: Some(thread),
        connections,
    })
}

/// 客户端：持续重连（指数退避），网络恢复后自动接回。
pub struct Dialer {
    stop: Arc<AtomicBool>,
    thread: Option<thread::JoinHandle<()>>,
    conn: Arc<Mutex<Option<Connection>>>,
    state: Arc<Mutex<SessionState>>,
    /// 该对端的序号状态：每次重连建连时注入新连接，连接结束后写回。
    /// 没有它，重连后 `SeqTracker` 归零 → 新消息被对端静默丢弃。
    seq_state: Arc<SeqStateStore>,
}

impl Dialer {
    pub fn state(&self) -> SessionState {
        self.state
            .lock()
            .map(|g| g.clone())
            .unwrap_or(SessionState::Disconnected)
    }

    pub fn peer_id(&self) -> Option<String> {
        self.conn
            .lock()
            .ok()
            .and_then(|g| g.as_ref().and_then(|c| c.peer_id()))
    }

    pub fn is_connected(&self) -> bool {
        self.conn
            .lock()
            .map(|g| g.as_ref().map(|c| c.is_alive()).unwrap_or(false))
            .unwrap_or(false)
    }

    /// 通过当前连接发一条文本（未连接返回错误）。
    ///
    /// `next_seq` 由调用方提供，而不是在这里数：同一个 sender 可能有两条出站
    /// 路径（拨号连接 / 监听连接），各持一份 `SeqTracker` 的话必然撞号，对端
    /// 只按 sender_id 去重、`seq <= last_seen` 即静默丢弃。序号的所有权归
    /// 调用方（见 `crate::api::chat` 的 `OUT_SEQ`），本层只负责发。
    /// 只在确认能发（连接活着）之后才调用 `next_seq`，避免失败的空拨号吃掉号段。
    pub fn send_text(
        &self,
        sender_id: &str,
        text: &str,
        ts_ms: i64,
        next_seq: impl FnOnce() -> u64,
    ) -> io::Result<u64> {
        let mut guard = self
            .conn
            .lock()
            .map_err(|_| io::Error::new(io::ErrorKind::Other, "dialer lock poisoned"))?;
        let conn = guard
            .as_mut()
            .filter(|c| c.is_alive())
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotConnected, "未连接到对端"))?;
        let seq = next_seq();
        conn.send_text(sender_id, seq, text, ts_ms)?;
        Ok(seq)
    }

    /// 通过当前连接发任意帧（配对握手等）。
    pub fn send_frame(&self, kind: FrameType, payload: &[u8]) -> io::Result<()> {
        let guard = self
            .conn
            .lock()
            .map_err(|_| io::Error::new(io::ErrorKind::Other, "dialer lock poisoned"))?;
        let conn = guard
            .as_ref()
            .filter(|c| c.is_alive())
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotConnected, "未连接到对端"))?;
        conn.send_frame(kind, payload)
    }

    /// 导出当前序号状态（落盘/写回时调用）。
    pub fn seq_state(&self) -> SeqState {
        self.seq_state.snapshot()
    }

    /// 注入序号状态（重连建连前调用）。
    pub fn set_seq_state(&self, state: SeqState) {
        self.seq_state.restore(state);
    }

    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Ok(mut guard) = self.conn.lock() {
            if let Some(conn) = guard.take() {
                conn.close("local stop");
            }
        }
        if let Some(handle) = self.thread.take() {
            let _ = handle.join();
        }
    }
}

impl Drop for Dialer {
    fn drop(&mut self) {
        self.stop();
    }
}

/// 启动客户端：目标形如 "192.168.1.23:45998"。
pub fn dial(
    cfg: SessionConfig,
    target: impl Into<String>,
    events: Sender<SessionEvent>,
) -> io::Result<Dialer> {
    let target = target.into();
    let stop = Arc::new(AtomicBool::new(false));
    let conn: Arc<Mutex<Option<Connection>>> = Arc::new(Mutex::new(None));
    let state = Arc::new(Mutex::new(SessionState::Disconnected));
    let seq_state = Arc::new(SeqStateStore::default());

    let thread = {
        let stop = Arc::clone(&stop);
        let conn = Arc::clone(&conn);
        let state = Arc::clone(&state);
        let seq_state = Arc::clone(&seq_state);
        thread::Builder::new()
            .name("lanchat-session-dial".into())
            .spawn(move || {
                let mut attempt: u32 = 0;
                while !stop.load(Ordering::SeqCst) {
                    if let Ok(mut s) = state.lock() {
                        *s = SessionState::Connecting;
                    }
                    match connect_to(&target) {
                        Ok(stream) => {
                            attempt = 0;
                            // 注入该对端已积累的序号状态：没有它，重连后 out_seq 归零
                            // 会让新消息被对端当作旧的丢弃（见 SeqTracker 文档）。
                            match Connection::start_with_seqs(
                                stream,
                                cfg.clone(),
                                events.clone(),
                                seq_state.snapshot(),
                            ) {
                                Ok(new_conn) => {
                                    if let Ok(mut guard) = conn.lock() {
                                        *guard = Some(new_conn);
                                    }
                                    // 立刻写回一次，让 Dialer::seq_state() 能反映当前连接。
                                    if let Ok(guard) = conn.lock() {
                                        if let Some(c) = guard.as_ref() {
                                            seq_state.restore(c.shared.seq_snapshot());
                                        }
                                    }
                                    if let Ok(mut s) = state.lock() {
                                        *s = SessionState::Connected;
                                    }
                                    // 等这条连接结束（断开后回到重连）
                                    while !stop.load(Ordering::SeqCst) {
                                        thread::sleep(DIAL_WATCH_TICK);
                                        let alive = conn
                                            .lock()
                                            .map(|g| {
                                                g.as_ref()
                                                    .map(|c| c.is_alive())
                                                    .unwrap_or(false)
                                            })
                                            .unwrap_or(false);
                                        if !alive {
                                            break;
                                        }
                                    }
                                    // 断开前把最新序号写回，供下次重连注入。
                                    if let Ok(guard) = conn.lock() {
                                        if let Some(c) = guard.as_ref() {
                                            seq_state.restore(c.shared.seq_snapshot());
                                        }
                                    }
                                    if let Ok(mut guard) = conn.lock() {
                                        guard.take();
                                    }
                                    if let Ok(mut s) = state.lock() {
                                        *s = SessionState::Disconnected;
                                    }
                                }
                                Err(_) => {
                                    attempt = attempt.saturating_add(1);
                                }
                            }
                        }
                        Err(_) => {
                            attempt = attempt.saturating_add(1);
                        }
                    }
                    if stop.load(Ordering::SeqCst) {
                        break;
                    }
                    let wait = backoff_ms(attempt.max(1), cfg.base_backoff_ms, cfg.max_backoff_ms);
                    if let Ok(mut s) = state.lock() {
                        *s = SessionState::Reconnecting {
                            attempt: attempt.max(1),
                            backoff_ms: wait,
                        };
                    }
                    // 分段睡眠，stop 后能很快退出
                    let deadline = Instant::now() + Duration::from_millis(wait);
                    while Instant::now() < deadline && !stop.load(Ordering::SeqCst) {
                        thread::sleep(Duration::from_millis(50));
                    }
                }
                if let Ok(mut s) = state.lock() {
                    *s = SessionState::Disconnected;
                }
            })?
    };

    Ok(Dialer {
        stop,
        thread: Some(thread),
        conn,
        state,
        seq_state,
    })
}

fn connect_to(target: &str) -> io::Result<TcpStream> {
    let addr = target
        .to_socket_addrs()?
        .next()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "无法解析目标地址"))?;
    TcpStream::connect_timeout(&addr, CONNECT_TIMEOUT)
}

/// 会话内 (sender_id, seq) 单调序号：去重 + 排序不依赖墙钟（风险11）。
///
/// **状态必须跨连接、跨进程重启存活**：此前的实现每次 `Connection::start` 都
/// `SeqTracker::default()`，重连后 `out_seq` 归零会让新消息被对端当成旧的丢弃，
/// `last_seen` 清空又会让重发的旧消息变成重复。快照由 Task 5 负责落盘与注入。
#[derive(Debug, Default)]
pub struct SeqTracker {
    last_seen: HashMap<String, u64>,
    out_seq: u64,
    /// 每个 sender_id 的出站序号。对端 `accept()` 只按 sender_id 去重，
    /// 因此**同一 sender 的所有出站路径必须共用同一条序列**：拨号连接与
    /// 监听连接是两个不同的 `Connection`（各自一份 `SeqTracker`），若各自
    /// 从 1 起算，第 2 条无论走哪条路都会 <= 对端 last_seen 而被静默丢弃
    /// —— 这正是「对端收不到」的隐蔽成因。
    out_by_sender: HashMap<String, u64>,
}

/// `SeqTracker` 的可持久化快照（JSON 落盘用）。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SeqState {
    #[serde(default)]
    pub last_seen: HashMap<String, u64>,
    #[serde(default)]
    pub out_seq: u64,
    /// 跨重连保留的 per-sender 出站序号（`out_seq` 是历史遗留的全局计数，
    /// 保留只为兼容旧快照）。
    #[serde(default)]
    pub out_by_sender: HashMap<String, u64>,
}

/// 进程内共享的序号状态：连接重建（自动重连）时用它恢复 `SeqTracker`，
/// 避免 `out_seq` 归零导致新消息被对端当旧的丢弃、`last_seen` 清空导致重复入站。
#[derive(Debug, Default)]
pub struct SeqStateStore {
    state: Mutex<SeqState>,
}

/// 进程内出站计数器，按 **(本端 sender_id, 对端 peer_id)** 分桶。
///
/// **为什么共享**：同一个 sender_id 有两条出站路径 —— 主动拨号的 `Dialer`
/// 连接与 accept 出来的 `Listener` 连接，是两个不同的 `Connection`（各持一份
/// `SeqTracker`）。若各自从 1 起算，两条路径交替发包时必然撞号；对端 `accept()`
/// 只按 sender_id 去重，`seq <= last_seen` 即静默丢弃 —— 用户报的
/// 「对端收不到」正是这个。
///
impl SeqStateStore {
    pub fn snapshot(&self) -> SeqState {
        self.state.lock().map(|s| s.clone()).unwrap_or_default()
    }

    pub fn restore(&self, state: SeqState) {
        if let Ok(mut guard) = self.state.lock() {
            *guard = state;
        }
    }
}

impl SeqTracker {
    /// 从已保存的状态恢复（重连/重启后调用）。
    pub fn from_state(state: SeqState) -> Self {
        Self {
            last_seen: state.last_seen,
            out_seq: state.out_seq,
            out_by_sender: state.out_by_sender,
        }
    }

    /// 导出当前状态供落盘。
    pub fn snapshot(&self) -> SeqState {
        SeqState {
            last_seen: self.last_seen.clone(),
            out_seq: self.out_seq,
            out_by_sender: self.out_by_sender.clone(),
        }
    }

    /// 收到一条消息：仅当 seq 比该 sender 已见的更大才算新消息。
    pub fn accept(&mut self, sender_id: &str, seq: u64) -> bool {
        let entry = self.last_seen.entry(sender_id.to_string()).or_insert(0);
        if seq > *entry {
            *entry = seq;
            true
        } else {
            false
        }
    }

    /// 下一条本地发送序号（从 1 开始）。
    pub fn next_out(&mut self) -> u64 {
        self.out_seq += 1;
        self.out_seq
    }

    /// 指定 sender 的下一条出站序号。**同一 sender 的所有出站路径共用**，
    /// 且进度会被 `snapshot()` 带走，因此拨号/监听两条连接、以及重连之后的
    /// 新连接都接着同一条序列往下发。
    pub fn next_out_for(&mut self, sender_id: &str) -> u64 {
        let next = {
            let entry = self
                .out_by_sender
                .entry(sender_id.to_string())
                .or_insert(0);
            *entry += 1;
            *entry
        };
        // 兼容旧快照：老实现只维护全局 out_seq，迁移时不能低于它，
        // 否则升级后第一次发送会用到对端已经见过的序号。
        if next <= self.out_seq {
            self.out_seq += 1;
            self.out_by_sender
                .insert(sender_id.to_string(), self.out_seq);
            self.out_seq
        } else {
            self.out_seq = next;
            next
        }
    }

    pub fn last_seen(&self, sender_id: &str) -> Option<u64> {
        self.last_seen.get(sender_id).copied()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc::{channel, Receiver};

    fn hello(id: &str) -> HelloPayload {
        HelloPayload {
            device_id: id.into(),
            name: format!("host-{id}"),
            platform: "windows".into(),
            chat_port: DEFAULT_CHAT_PORT,
            proto_version: protocol::VERSION,
        }
    }

    fn wait_until(deadline: Duration, mut cond: impl FnMut() -> bool) -> bool {
        let start = Instant::now();
        while start.elapsed() < deadline {
            if cond() {
                return true;
            }
            thread::sleep(Duration::from_millis(20));
        }
        cond()
    }

    /// 从事件流里等一条满足条件的事件。
    fn wait_event(
        rx: &Receiver<SessionEvent>,
        deadline: Duration,
        mut pred: impl FnMut(&SessionEvent) -> bool,
    ) -> Option<SessionEvent> {
        let start = Instant::now();
        while start.elapsed() < deadline {
            match rx.recv_timeout(Duration::from_millis(100)) {
                Ok(ev) => {
                    if pred(&ev) {
                        return Some(ev);
                    }
                }
                Err(_) => continue,
            }
        }
        None
    }

    fn fast_cfg(id: &str) -> SessionConfig {
        SessionConfig::new(hello(id)).with_timing(
            Duration::from_millis(150),
            Duration::from_millis(600),
        )
    }

    #[test]
    fn backoff_grows_exponentially_and_caps() {
        assert_eq!(backoff_ms(1, 500, 30_000), 500);
        assert_eq!(backoff_ms(2, 500, 30_000), 1_000);
        assert_eq!(backoff_ms(3, 500, 30_000), 2_000);
        assert_eq!(backoff_ms(10, 500, 30_000), 30_000);
        // attempt=0 视作第 1 次
        assert_eq!(backoff_ms(0, 500, 30_000), 500);
    }

    #[test]
    fn seq_tracker_dedupes_and_orders() {
        let mut t = SeqTracker::default();
        assert!(t.accept("dev-a", 1), "首条接受");
        assert!(!t.accept("dev-a", 1), "重复丢弃");
        assert!(!t.accept("dev-a", 0), "更旧的丢弃");
        assert!(t.accept("dev-a", 5), "跳号可以（丢包/离线期间）");
        assert!(!t.accept("dev-a", 4), "乱序旧包丢弃");
        assert!(t.accept("dev-b", 1), "不同 sender 独立计数");
        assert_eq!(t.last_seen("dev-a"), Some(5));
        assert_eq!(t.next_out(), 1);
        assert_eq!(t.next_out(), 2);
    }

    #[test]
    fn seq_tracker_round_trips_through_snapshot() {
        let mut t = SeqTracker::default();
        assert!(t.accept("peer-a", 5));
        assert!(!t.accept("peer-a", 5)); // 同 seq 不新鲜
        let s1 = t.next_out();
        let s2 = t.next_out();
        assert_eq!(s1, 1);
        assert_eq!(s2, 2);

        // 快照 → 新 tracker：去重与发送序号都要延续
        let snap = t.snapshot();
        let mut restored = SeqTracker::from_state(snap);
        assert_eq!(restored.last_seen("peer-a"), Some(5));
        // 已见 seq=5，所以 5 及以下都不新鲜
        assert!(!restored.accept("peer-a", 5));
        assert!(!restored.accept("peer-a", 3));
        assert!(restored.accept("peer-a", 6));
        // 发送序号必须接着走，不能回退到 1（回退会让对端把新消息当成旧的丢弃）
        assert_eq!(restored.next_out(), 3);
        assert_eq!(restored.next_out(), 4);
    }

    #[test]
    fn out_seq_does_not_rewind_after_restore() {
        // 模拟「重连」：保存状态后用同一份状态重建 tracker，
        // 新消息的 seq 必须仍大于此前已发出去的序号。
        let mut first = SeqTracker::default();
        let a = first.next_out();
        let b = first.next_out();
        assert_eq!((a, b), (1, 2));

        let mut second = SeqTracker::from_state(first.snapshot());
        let c = second.next_out();
        assert_eq!(c, 3);
        assert!(c > b);
    }

    #[test]
    fn restore_seqs_keeps_last_seen_across_reconnect() {
        // 真实缺口回归：重连后若 tracker 归零，
        // 对端发来的新消息会因 seq 比历史小而被静默丢弃（比重复更隐蔽）。
        let mut t = SeqTracker::default();
        assert!(t.accept("peer-a", 9));
        let _ = t.next_out();
        let mut state = t.snapshot();
        state.out_seq = 5;

        let mut after = SeqTracker::from_state(state);
        // 同一 sender 的新消息仍被接受，不因状态丢失而误判
        assert!(after.accept("peer-a", 10));
        // 对端重启后 seq 从 1 重新计数，也必须被接受（不同 sender 独立）
        assert!(after.accept("peer-b", 1));
        // 发送序号必须延续已发的 5 条，不回退
        assert_eq!(after.next_out(), 6);
    }

    #[test]
    fn seq_state_store_roundtrip() {
        let store = SeqStateStore::default();
        assert_eq!(store.snapshot().out_seq, 0);

        let mut t = SeqTracker::default();
        assert!(t.accept("peer-z", 9));
        let _ = t.next_out();
        let _ = t.next_out();
        store.restore(t.snapshot());

        let got = store.snapshot();
        assert_eq!(got.out_seq, 2);
        assert_eq!(got.last_seen.get("peer-z"), Some(&9));
    }

    #[test]
    fn listener_out_seq_survives_peer_reconnect() {
        // 真实缺口：监听端每条进来的连接都是新的 Connection，
        // 其 tracker 的 out_seq 从 0 起算。对端（已持久化 last_seen）
        // 会把我重连后发的第 1、2 条当成旧消息静默丢弃。
        let (tx_a, _rx_a) = channel();
        let listener = listen(fast_cfg("dev-a"), 0, tx_a).expect("listen 失败");
        let port = listener.local_addr().port();

        for round in 0..2 {
            let (tx_b, _rx_b) = channel();
            let mut dialer = dial(fast_cfg("dev-b"), format!("127.0.0.1:{port}"), tx_b)
                .expect("dial 失败");
            assert!(
                wait_until(Duration::from_secs(5), || dialer.is_connected()),
                "第 {round} 轮客户端未连上"
            );
            assert!(
                wait_until(Duration::from_secs(5), || !listener.peers().is_empty()),
                "第 {round} 轮监听端未完成握手"
            );

            let seq = listener
                .send_text_to("dev-b", "dev-a", "hi", 1_760_000_000_000, || {
                    round + 1
                })
                .expect("监听端发送失败");
            assert_eq!(seq, round + 1, "监听端 out_seq 必须跨重连单调递增");

            dialer.stop();
            assert!(
                wait_until(Duration::from_secs(5), || listener.connection_count() == 0),
                "第 {round} 轮连接未清理"
            );
        }
    }

    #[test]
    fn dialer_and_listener_share_one_out_seq_per_sender() {
        // 真实缺口：同一个 sender_id 有**两套**出站计数器 ——
        // Dialer 用连接里的 SeqTracker（持久化、跨重连延续），
        // Listener 用自己那张 out_seqs 表（另一条独立序列）。
        // chat_send_text 先试 dialer、失败才回落 listener，于是两条路径
        // 交替发包时 seq 会重复，对端 accept() 只按 sender_id 去重，
        // 第二条同号消息被当成重发**静默丢弃**（用户报的「对端收不到」）。
        let (tx_a, _rx_a) = channel();
        let listener = listen(fast_cfg("dev-a"), 0, tx_a).expect("listen 失败");
        let port = listener.local_addr().port();
        let (tx_b, _rx_b) = channel();
        let mut dialer =
            dial(fast_cfg("dev-b"), format!("127.0.0.1:{port}"), tx_b).expect("dial 失败");
        assert!(
            wait_until(Duration::from_secs(5), || dialer.is_connected()),
            "客户端未连上"
        );
        assert!(
            wait_until(Duration::from_secs(5), || !listener.peers().is_empty()),
            "监听端未完成握手"
        );

        // 模拟 chat.rs 的 OUT_SEQ 表：两条路径共用一个计数器。
        // 若各发自带计数（旧行为）会拿到相同 seq，对端把后一条当重发丢弃。
        let shared = std::cell::Cell::new(0u64);
        let next = move || {
            shared.set(shared.get() + 1);
            shared.get()
        };

        // 同一台设备的两条发送路径各发一条，sender_id 相同
        let from_dialer = dialer
            .send_text("dev-a", "甲", 1_760_000_000_000, &next)
            .expect("dialer 发送失败");
        let from_listener = listener
            .send_text_to("dev-b", "dev-a", "乙", 1_760_000_000_001, next)
            .expect("listener 发送失败");
        assert_ne!(
            from_dialer, from_listener,
            "同一 sender 的两条路径必须共用一条序列，否则对端会把后一条当重发丢弃"
        );
        // 共用一条序列意味着连续取号
        assert_eq!(
            (from_dialer, from_listener),
            (1, 2),
            "两条路径取的号必须来自同一条连续序列"
        );
        dialer.stop();
    }

    #[test]
    fn two_sessions_exchange_text_both_ways() {
        let (tx_a, rx_a) = channel();
        let mut listener = listen(fast_cfg("dev-a"), 0, tx_a).expect("listen 失败");
        let port = listener.local_addr().port();

        let (tx_b, rx_b) = channel();
        let mut dialer = dial(
            fast_cfg("dev-b"),
            format!("127.0.0.1:{port}"),
            tx_b,
        )
        .expect("dial 失败");

        assert!(
            wait_until(Duration::from_secs(5), || dialer.is_connected()),
            "客户端未连上"
        );
        // 双方都应收到对端 hello
        let connected_a = wait_event(&rx_a, Duration::from_secs(5), |e| {
            matches!(e, SessionEvent::Connected { .. })
        });
        let connected_b = wait_event(&rx_b, Duration::from_secs(5), |e| {
            matches!(e, SessionEvent::Connected { .. })
        });
        match connected_a {
            Some(SessionEvent::Connected { peer_id, name, .. }) => {
                assert_eq!(peer_id, "dev-b");
                assert_eq!(name, "host-dev-b");
            }
            other => panic!("A 未收到 Connected: {other:?}"),
        }
        match connected_b {
            Some(SessionEvent::Connected { peer_id, .. }) => assert_eq!(peer_id, "dev-a"),
            other => panic!("B 未收到 Connected: {other:?}"),
        }

        // B → A
        let seq = dialer
            .send_text("dev-b", "你好，A", 1_760_000_000_000, || 1)
            .expect("发送失败");
        assert_eq!(seq, 1);
        let got = wait_event(&rx_a, Duration::from_secs(5), |e| {
            matches!(e, SessionEvent::Message { .. })
        });
        match got {
            Some(SessionEvent::Message { peer_id, message }) => {
                assert_eq!(peer_id, "dev-b");
                assert_eq!(message.text, "你好，A");
                assert_eq!(message.seq, 1);
            }
            other => panic!("A 未收到消息: {other:?}"),
        }

        // A → B：直接从 listener 的连接发
        {
            let guard = listener.connections.lock().unwrap();
            let conn = guard.iter().find(|c| c.is_alive()).expect("没有活连接");
            conn.send_text("dev-a", 1, "收到，B", 1_760_000_000_001)
                .expect("发送失败");
        }
        let got = wait_event(&rx_b, Duration::from_secs(5), |e| {
            matches!(e, SessionEvent::Message { .. })
        });
        match got {
            Some(SessionEvent::Message { message, .. }) => {
                assert_eq!(message.text, "收到，B");
                assert_eq!(message.sender_id, "dev-a");
            }
            other => panic!("B 未收到消息: {other:?}"),
        }

        assert_eq!(listener.connection_count(), 1);
        dialer.stop();
        listener.stop();
    }

    #[test]
    fn fragmented_and_coalesced_frames_are_handled() {
        // 手工写原始字节：一帧拆成 1 字节发送（半包），两帧合并成一次写（粘包）
        let (tx, rx) = channel();
        let mut listener = listen(fast_cfg("dev-a"), 0, tx).expect("listen 失败");
        let port = listener.local_addr().port();

        let mut raw = TcpStream::connect(("127.0.0.1", port)).expect("connect 失败");
        raw.set_nodelay(true).ok();
        // 先发本端 hello，让服务端把 peer_id 认下来
        let mut hello_frame = protocol::encode(
            FrameType::Hello,
            &serde_json::to_vec(&hello("dev-raw")).unwrap(),
        );
        for byte in hello_frame.drain(..) {
            raw.write_all(&[byte]).unwrap();
            raw.flush().unwrap();
        }

        let mk_text = |seq: u64, text: &str| {
            protocol::encode(
                FrameType::Text,
                &serde_json::to_vec(&TextPayload {
                    sender_id: "dev-raw".into(),
                    seq,
                    text: text.into(),
                    ts_ms: 0,
                })
                .unwrap(),
            )
        };
        // 粘包：两帧一次写
        let mut both = mk_text(1, "第一帧");
        both.extend_from_slice(&mk_text(2, "第二帧"));
        raw.write_all(&both).unwrap();
        raw.flush().unwrap();

        let mut texts = Vec::new();
        while texts.len() < 2 {
            match wait_event(&rx, Duration::from_secs(5), |e| {
                matches!(e, SessionEvent::Message { .. })
            }) {
                Some(SessionEvent::Message { peer_id, message }) => {
                    assert_eq!(peer_id, "dev-raw");
                    texts.push(message.text);
                }
                other => panic!("未收到消息: {other:?}"),
            }
        }
        assert_eq!(texts, vec!["第一帧", "第二帧"]);

        drop(raw);
        listener.stop();
    }

    #[test]
    fn timeout_marks_peer_offline() {
        let (tx, rx) = channel();
        let mut listener = listen(fast_cfg("dev-a"), 0, tx).expect("listen 失败");
        let port = listener.local_addr().port();

        let (tx_b, _rx_b) = channel(); // 接收端保持存活（_ 前缀绑定仍活到测试结束）
        let mut dialer = dial(fast_cfg("dev-b"), format!("127.0.0.1:{port}"), tx_b).unwrap();
        assert!(wait_until(Duration::from_secs(5), || dialer.is_connected()));

        // 模拟「拔网线」：直接掐掉客户端 socket（不发 BYE）
        let stream = {
            let guard = dialer.conn.lock().unwrap();
            let conn = guard.as_ref().expect("应有连接");
            let out = conn.out.lock().unwrap();
            out.try_clone().unwrap()
        };
        stream.shutdown(Shutdown::Both).unwrap();

        let disc = wait_event(&rx, Duration::from_secs(5), |e| {
            matches!(e, SessionEvent::Disconnected { .. })
        });
        match disc {
            Some(SessionEvent::Disconnected { peer_id, reason }) => {
                assert_eq!(peer_id.as_deref(), Some("dev-b"));
                assert!(
                    reason == "eof" || reason == "io",
                    "断开原因意外: {reason}"
                );
            }
            other => panic!("未收到 Disconnected: {other:?}"),
        }

        dialer.stop();
        listener.stop();
    }

    /// 回归（B1-4）：**纯静默不得判死**。
    ///
    /// 用户口径：「软件明明都开着，一直显示断开断开……不需要判得那么死，没有关键
    /// 事件触发，不用太严，间隔问候就行」。
    ///
    /// 旧实现在 WouldBlock/TimedOut 分支里 `idle > timeout` 就 `reason = "timeout";
    /// break;`，随后发 `SessionEvent::Disconnected` —— 对端（安卓被 Doze/国产 ROM
    /// 冻结了心跳线程，进程与通知栏都还在）只是暂时没说话，却被判死断开 socket。
    ///
    /// 现在：静默既不 break 也不发 Disconnected，只发一次 `Stalled`（非断开告警），
    /// 连接保留。
    ///
    /// 本测试用**裸 TCP 客户端**制造真静默：握手成功后彻底闭嘴（不发心跳）。
    /// 不能用 dialer 对打 —— 它自带心跳，socket 上一直有数据，last_rx 永不过期，
    /// 那样测不出静默路径（会变成假绿）。
    ///
    /// 断言：
    ///   ① 收到过 Stalled（证明静默路径真的走到了 —— 防止本用例假绿）；
    ///   ② 再等远超阈值，仍然**没有** Disconnected；
    ///   ③ 连接仍在 accept 列表里（没被 shutdown）；
    ///   ④ 对端「恢复调度」后再发一帧，消息照样收得到（连接真的还活着）。
    #[test]
    fn silent_peer_is_not_declared_dead() {
        let cfg = SessionConfig::new(hello("dev-a")).with_timing(
            Duration::from_millis(80),
            Duration::from_millis(80), // 静默阈值极短：旧实现必判死
        );
        let (tx, rx) = channel();
        let mut listener = listen(cfg, 0, tx).expect("listen 失败");
        let port = listener.local_addr().port();

        // 裸客户端：只发一帧 HELLO，然后**永久闭嘴**（模拟被 Doze 冻结的对端）
        let mut raw = TcpStream::connect(("127.0.0.1", port)).expect("connect 失败");
        let hello_json = serde_json::to_vec(&hello("dev-b")).unwrap();
        raw.write_all(&protocol::encode(FrameType::Hello, &hello_json))
            .unwrap();
        raw.flush().unwrap();

        let conn_ev = wait_event(&rx, Duration::from_secs(5), |e| {
            matches!(e, SessionEvent::Connected { .. })
        });
        assert!(conn_ev.is_some(), "裸客户端 HELLO 后应收到 Connected");

        // ① 静默超阈值 → 应上报 Stalled（是告警，不是断开）
        let stalled = wait_event(&rx, Duration::from_secs(5), |e| {
            matches!(e, SessionEvent::Stalled { .. })
        });
        assert!(
            stalled.is_some(),
            "静默超过阈值后应上报 Stalled（静默事实不能丢），实际没收到"
        );

        // ② + ③ 远超阈值之后仍然不许判死
        let disc = wait_event(&rx, Duration::from_millis(900), |e| {
            matches!(e, SessionEvent::Disconnected { .. })
        });
        assert!(
            disc.is_none(),
            "纯静默不是关键事件，不得判死；却收到了 Disconnected: {disc:?}"
        );
        assert!(
            listener.peers().iter().any(|p| p == "dev-b"),
            "静默期间服务端连接应保留（不该被 shutdown）"
        );

        // ④ 对端恢复：再发一帧文本，应能收到（证明连接真的还活着）
        let text = serde_json::to_vec(&TextPayload {
            sender_id: "dev-b".into(),
            seq: 1,
            text: "我回来了".into(),
            ts_ms: 1,
        })
        .unwrap();
        raw.write_all(&protocol::encode(FrameType::Text, &text))
            .unwrap();
        raw.flush().unwrap();
        let msg = wait_event(&rx, Duration::from_secs(5), |e| {
            matches!(e, SessionEvent::Message { .. })
        });
        assert!(
            msg.is_some(),
            "对端恢复说话后应能收到消息（连接不该被判死）"
        );
        let _ = raw.shutdown(Shutdown::Both);

        listener.stop();
    }

    #[test]
    fn dialer_reconnects_after_listener_appears() {
        // 先起 dialer（目标端口还没有监听）→ 应进入 Reconnecting；
        // 再把 listener 起起来 → 应自动连上（风险17：网络恢复自动重连）
        let bogus_port = {
            let probe = TcpListener::bind(("127.0.0.1", 0)).unwrap();
            probe.local_addr().unwrap().port()
        };

        let (tx_b, _rx_b) = channel();
        let cfg = SessionConfig::new(hello("dev-b")).with_timing(
            Duration::from_millis(200),
            Duration::from_millis(800),
        );
        let mut dialer = dial(cfg.clone(), format!("127.0.0.1:{bogus_port}"), tx_b).unwrap();

        assert!(
            wait_until(Duration::from_secs(3), || matches!(
                dialer.state(),
                SessionState::Reconnecting { .. }
            )),
            "未进入重连状态: {:?}",
            dialer.state()
        );
        assert!(!dialer.is_connected());

        // 目标端口现在可用
        let (tx_a, _rx_a) = channel();
        let mut listener = listen(cfg, bogus_port, tx_a).expect("listen 失败");
        assert!(
            wait_until(Duration::from_secs(6), || dialer.is_connected()),
            "网络恢复后未自动重连"
        );
        assert_eq!(dialer.state(), SessionState::Connected);

        dialer.stop();
        listener.stop();
    }

    #[test]
    fn protocol_error_closes_connection() {
        let (tx, rx) = channel();
        let mut listener = listen(fast_cfg("dev-a"), 0, tx).expect("listen 失败");
        let port = listener.local_addr().port();

        let mut raw = TcpStream::connect(("127.0.0.1", port)).unwrap();
        // 坏 magic：服务端应判协议错误并关连接
        raw.write_all(b"XXXXXXXXXX").unwrap();
        raw.flush().unwrap();

        let disc = wait_event(&rx, Duration::from_secs(5), |e| {
            matches!(e, SessionEvent::Disconnected { .. })
        });
        match disc {
            Some(SessionEvent::Disconnected { reason, .. }) => {
                assert!(
                    reason == "protocol" || reason == "io" || reason == "eof",
                    "断开原因意外: {reason}"
                );
            }
            other => panic!("未收到 Disconnected: {other:?}"),
        }
        listener.stop();
    }
}
