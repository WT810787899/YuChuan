//! T3.1 / T3.3 桥接：TCP 会话（收发文本）+ 消息存储（历史/未读/分页）。
//!
//! 约定：
//! - 收到消息由事件转发线程**先落库再推给 UI**（T3.3「收到即入库」）；
//! - 发送成功也立刻落库（from_me），UI 只需读历史 + 听事件流；
//! - 每个对端一个 Dialer，键为 device_id。

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, bail};
use flutter_rust_bridge::frb;

use crate::backend::protocol::HelloPayload;
use crate::backend::session::{
    self, Dialer, SessionConfig, SessionEvent, SessionState,
};
use crate::backend::storage::{MessageStore, OutboxEntry, OutboxStore, PageQuery, StoredMessage};
use crate::frb_generated::StreamSink;

// ------------------------------------------------------------
// 全局句柄
// ------------------------------------------------------------

struct EventBus {
    tx: Sender<SessionEvent>,
    rx: Option<Receiver<SessionEvent>>,
}

static EVENT_BUS: Mutex<Option<EventBus>> = Mutex::new(None);
static DIALERS: Mutex<Option<HashMap<String, Dialer>>> = Mutex::new(None);
static LISTENER: Mutex<Option<session::Listener>> = Mutex::new(None);
static MESSAGES: Mutex<Option<MessageStore>> = Mutex::new(None);
/// 离线发件箱（与消息存储同目录，`messages_open` 时一起打开）。
static OUTBOX: Mutex<Option<OutboxStore>> = Mutex::new(None);

/// 每个 (对端, 发送者) 已发出的最大序号。**必须放在这一层**：
/// `chat_send_text` 先试 `DIALERS` 里的拨号连接、失败才回落 `LISTENER` 的
/// 入站连接，而这是两个不同的 `Connection`（各持一份 `SeqTracker`）。对端
/// 只按 sender_id 去重、`seq <= last_seen` 即静默丢弃，所以只要两条路径各
/// 自计数，第二条必然撞号被丢掉 —— 这正是用户报的「离线发送对端收不到」。
/// 这个登记表同时持有 DIALERS 与 LISTENER，是两条路径唯一的交汇点。
static OUT_SEQ: Mutex<Option<HashMap<(String, String), u64>>> = Mutex::new(None);

/// 取 (对端, 发送者) 的下一条出站序号。键含对端：各对端各存各的 `last_seen`，
/// 一个对端的进度不该抬高发给另一个对端的序号。
fn next_out_seq(peer_id: &str, sender_id: &str) -> u64 {
    let mut guard = match OUT_SEQ.lock() {
        Ok(g) => g,
        Err(p) => p.into_inner(),
    };
    let map = guard.get_or_insert_with(HashMap::new);
    let entry = map
        .entry((peer_id.to_string(), sender_id.to_string()))
        .or_insert(0);
    *entry += 1;
    *entry
}

/// 测试串行闸：`MESSAGES`/`OUTBOX` 都是进程级 static，`messages_open` 会把两个
/// store 一起换掉。并行跑的多个测试各自调 `messages_open` 时，后来者会顶掉前者的
/// store，断言便读到别人的空箱（表现为「单跑通过、全量失败」）。凡是会调
/// `messages_open` 的测试都必须先拿这把锁；产品代码不受影响（真机只 open 一次）。
#[cfg(test)]
static MESSAGES_TEST_LOCK: Mutex<()> = Mutex::new(());

/// 取测试串行闸的守卫（必须在调用 `messages_open` 之前拿，且守卫要活到测试结束）。
#[cfg(test)]
pub(crate) fn messages_test_lock() -> std::sync::MutexGuard<'static, ()> {
    MESSAGES_TEST_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner())
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// 发件箱文本条目 id 的进程内递增值。
///
/// 文本没有内容哈希可用，而 `now_ms()` 在 Windows 上粒度约 15.6ms：同一毫秒内
/// 连发两条文本会算出同一个 id，`OutboxStore::enqueue` 按 id 幂等 → 第二条被
/// 静默丢弃，表现就是「离线消息对端收不到」。加上计数器后 id 单调唯一，
/// 不再依赖时钟粒度。
static OUTBOX_SEQ: AtomicU64 = AtomicU64::new(0);

fn next_outbox_seq() -> u64 {
    OUTBOX_SEQ.fetch_add(1, Ordering::Relaxed)
}

fn bus_tx() -> anyhow::Result<Sender<SessionEvent>> {
    let mut bus = EVENT_BUS.lock().map_err(|_| anyhow!("event bus poisoned"))?;
    if let Some(existing) = bus.as_ref() {
        return Ok(existing.tx.clone());
    }
    let (tx, rx) = channel();
    *bus = Some(EventBus {
        tx: tx.clone(),
        rx: Some(rx),
    });
    Ok(tx)
}

fn take_bus_rx() -> anyhow::Result<Receiver<SessionEvent>> {
    let mut bus = EVENT_BUS.lock().map_err(|_| anyhow!("event bus poisoned"))?;
    if let Some(existing) = bus.as_mut() {
        if let Some(rx) = existing.rx.take() {
            return Ok(rx);
        }
    }
    let (tx, rx) = channel();
    *bus = Some(EventBus { tx, rx: None });
    Ok(rx)
}

// ------------------------------------------------------------
// DTO
// ------------------------------------------------------------

/// 会话状态（UI 状态点/文案）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChatStateDto {
    Disconnected,
    Connecting,
    Connected,
    Reconnecting,
}

/// 一条消息（与存储行一一对应）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessageDto {
    pub id: String,
    pub peer_id: String,
    /// 会话内序号（发送方单调递增；重发/去重用）。
    pub seq: i64,
    pub from_me: bool,
    /// 1=text 2=image 3=file
    pub kind: i32,
    pub text: String,
    pub file_name: String,
    pub file_size: i64,
    pub ts_ms: i64,
    pub delivered: bool,
}

impl From<&StoredMessage> for MessageDto {
    fn from(m: &StoredMessage) -> Self {
        Self {
            id: m.id.clone(),
            peer_id: m.peer_id.clone(),
            seq: m.seq,
            from_me: m.from_me,
            kind: m.kind as i32,
            text: m.text.clone(),
            file_name: m.file_name.clone(),
            file_size: m.file_size.min(i64::MAX as u64) as i64,
            ts_ms: m.ts_ms,
            delivered: m.delivered,
        }
    }
}

/// 会话事件（frb Stream）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChatEventKindDto {
    Connected,
    Disconnected,
    Message,
    Sent,
    /// 收到对端 PAIR_REQ（应答方据此弹 PIN 卡片）。
    PairRequest,
    /// 收到对端 PAIR_RESP（发起方据此结束等待）。
    PairResponse,
}

#[derive(Debug, Clone)]
pub struct ChatEventDto {
    pub kind: ChatEventKindDto,
    pub peer_id: Option<String>,
    pub name: Option<String>,
    pub addr: Option<String>,
    pub reason: Option<String>,
    pub message: Option<MessageDto>,
    pub seq: Option<i64>,
    pub state: Option<ChatStateDto>,
    /// 配对请求里的 6 位 PIN / 响应是否被接受。
    pub pin: Option<String>,
    pub accepted: Option<bool>,
}

/// 发 PAIR_REQ（T2.1 发起方；配对状态机产出 PIN 后调用）。
pub fn chat_send_pair_request(
    peer_id: String,
    sender_id: String,
    pin: String,
) -> anyhow::Result<()> {
    let payload = crate::backend::protocol::PairReqPayload {
        device_id: sender_id,
        pin,
        ts_ms: now_ms().max(0) as u64,
    };
    let json = serde_json::to_vec(&payload)?;
    send_any_frame(&peer_id, crate::backend::protocol::FrameType::PairReq, &json)
}

/// 回 PAIR_RESP（T2.1 应答方用户确认/拒绝后调用）。
pub fn chat_send_pair_response(
    peer_id: String,
    accepted: bool,
    reason: Option<String>,
) -> anyhow::Result<()> {
    let payload = crate::backend::protocol::PairRespPayload { accepted, reason };
    let json = serde_json::to_vec(&payload)?;
    send_any_frame(
        &peer_id,
        crate::backend::protocol::FrameType::PairResp,
        &json,
    )
}

/// 文件事件的二级总线：chat 事件中继线程把 File* 事件转给 transfer hub
/// （聊天 UI 不消费文件帧，避免两边抢同一个 mpsc 接收端）。
static FILE_EVENT_TX: Mutex<Option<Sender<SessionEvent>>> = Mutex::new(None);

/// 注册文件事件接收端（transfer hub 启动时调用一次），返回接收端。
pub(crate) fn take_file_event_rx() -> Option<Receiver<SessionEvent>> {
    let mut slot = FILE_EVENT_TX.lock().ok()?;
    let (tx, rx) = channel();
    let replace = slot.replace(tx).is_none();
    // 若已有旧 tx（hub 重启场景）：保留新的即可
    let _ = replace;
    Some(rx)
}

/// 找该对端的连接发一帧（主动拨号优先，其次监听端连接）。
pub(crate) fn send_any_frame(
    peer_id: &str,
    kind: crate::backend::protocol::FrameType,
    payload: &[u8],
) -> anyhow::Result<()> {
    {
        let slot = DIALERS.lock().map_err(|_| anyhow!("dialers poisoned"))?;
        if let Some(map) = slot.as_ref() {
            if let Some(dialer) = map.get(peer_id) {
                if dialer.send_frame(kind, payload).is_ok() {
                    return Ok(());
                }
            }
        }
    }
    let slot = LISTENER.lock().map_err(|_| anyhow!("listener poisoned"))?;
    if let Some(listener) = slot.as_ref() {
        listener.send_frame_to(peer_id, kind, payload)?;
        return Ok(());
    }
    bail!("未与该设备建立会话（先 chatDial 或等对方连入）")
}

/// 会话快照（UI 的设备行在线状态）。
#[derive(Debug, Clone)]
pub struct ChatSessionDto {
    pub peer_id: String,
    pub state: ChatStateDto,
    pub connected: bool,
}

/// 消息存储状态。
#[derive(Debug, Clone)]
pub struct MessageStoreStatusDto {
    pub dir: String,
    pub total: i32,
    pub total_unread: i32,
    pub skipped_lines: i32,
}

/// 会话摘要（聊天列表页）。
#[derive(Debug, Clone)]
pub struct ConversationDto {
    pub peer_id: String,
    pub count: i32,
    pub unread: i32,
    pub last_ts_ms: i64,
    pub last_text: String,
}

fn state_dto(state: &SessionState) -> ChatStateDto {
    match state {
        SessionState::Disconnected => ChatStateDto::Disconnected,
        SessionState::Connecting => ChatStateDto::Connecting,
        SessionState::Connected => ChatStateDto::Connected,
        SessionState::Reconnecting { .. } => ChatStateDto::Reconnecting,
    }
}

// ------------------------------------------------------------
// 会话
// ------------------------------------------------------------

/// 会话/存储参数共用的本机身份。
#[derive(Debug, Clone)]
pub struct SelfInfo {
    pub device_id: String,
    pub name: String,
    pub platform: String,
}

fn self_hello(info: &SelfInfo, chat_port: u16) -> HelloPayload {
    HelloPayload {
        device_id: info.device_id.clone(),
        name: info.name.clone(),
        platform: info.platform.clone(),
        chat_port,
        proto_version: crate::backend::protocol::VERSION,
    }
}

fn session_cfg(info: &SelfInfo, chat_port: u16) -> SessionConfig {
    SessionConfig::new(self_hello(info, chat_port))
}

/// 开始监听本机聊天端口（接收对端连接）。幂等：重复调用先停旧的。
pub fn chat_listen(info: SelfInfo, chat_port: u16) -> anyhow::Result<i32> {
    if info.device_id.trim().is_empty() {
        bail!("device_id 不能为空");
    }
    let mut slot = LISTENER.lock().map_err(|_| anyhow!("listener poisoned"))?;
    if let Some(mut old) = slot.take() {
        old.stop();
    }
    // chat_port = 0 交给系统分配（测试/同机多实例联调都靠它）
    let listener = session::listen(session_cfg(&info, chat_port), chat_port, bus_tx()?)?;
    let actual = listener.local_addr().port() as i32;
    *slot = Some(listener);
    Ok(actual)
}

/// 主动连接一个已配对设备（带指数退避自动重连）。
pub fn chat_dial(info: SelfInfo, peer_id: String, target: String) -> anyhow::Result<()> {
    if peer_id.trim().is_empty() || target.trim().is_empty() {
        bail!("peer_id / target 不能为空");
    }
    let dialer = session::dial(session_cfg(&info, 0), target, bus_tx()?)?;
    let mut slot = DIALERS.lock().map_err(|_| anyhow!("dialers poisoned"))?;
    let map = slot.get_or_insert_with(HashMap::new);
    if let Some(mut old) = map.remove(&peer_id) {
        old.stop();
    }
    map.insert(peer_id, dialer);
    Ok(())
}

/// 发一条文本：发出 + 落库（from_me），返回落库后的消息（UI 直接用它的 id/seq）。
pub fn chat_send_text(
    peer_id: String,
    sender_id: String,
    text: String,
) -> anyhow::Result<MessageDto> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        bail!("消息不能为空");
    }
    let ts = now_ms();
    // 先找主动拨号的会话；失败（拨号中/重连中/目标 IP 过期）不能直接抛错，
    // 要落到监听端的入站连接 —— 与 send_any_frame 同一策略，否则
    // 「拨号未通但对端已反向连入（UI 显示在线）」时发文本必报「未连接到对端」。
    // 序号从两条路径共用的 OUT_SEQ 取，不各自计数：拨号连接与监听连接是
    // 两个不同的 Connection，各持一份 SeqTracker，各自从 1 起算必然撞号，
    // 对端会把后一条当重发静默丢弃（见 OUT_SEQ 的说明）。
    let mut seq: Option<u64> = None;
    {
        let slot = DIALERS.lock().map_err(|_| anyhow!("dialers poisoned"))?;
        if let Some(map) = slot.as_ref() {
            if let Some(dialer) = map.get(&peer_id) {
                if let Ok(s) = dialer.send_text(&sender_id, trimmed, ts, || {
                    next_out_seq(&peer_id, &sender_id)
                }) {
                    seq = Some(s);
                }
            }
        }
    }
    if seq.is_none() {
        let slot = LISTENER.lock().map_err(|_| anyhow!("listener poisoned"))?;
        if let Some(listener) = slot.as_ref() {
            if let Ok(s) = listener.send_text_to(&peer_id, &sender_id, trimmed, ts, || {
                next_out_seq(&peer_id, &sender_id)
            }) {
                seq = Some(s);
            }
        }
    }
    // 保留「未连接到对端」子串：Dart sendMessage 的 catch 据此判定离线排队，而非红条报错
    let seq = seq.ok_or_else(|| {
        anyhow!("未连接到对端（拨号与监听连接均不可用，先 chatDial 或等对方连入）")
    })?;
    append_message(&peer_id, true, trimmed, ts, seq, &sender_id)
}

/// 会话快照（UI 显示在线/重连状态）。
#[frb(sync)]
pub fn chat_sessions() -> Vec<ChatSessionDto> {
    let mut out = Vec::new();
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
    if let Ok(slot) = DIALERS.lock() {
        if let Some(map) = slot.as_ref() {
            for (peer_id, dialer) in map.iter() {
                seen.insert(peer_id.clone());
                out.push(ChatSessionDto {
                    peer_id: peer_id.clone(),
                    state: state_dto(&dialer.state()),
                    connected: dialer.is_connected(),
                });
            }
        }
    }
    // **入站连接也必须算进来**（对端主动连入那一半）。
    //
    // `send_any_frame` 在 dialer 不可用时会回落到 `listener.send_frame_to`，
    // 所以「没有 dialer」绝不等于「没连上」。以前这里只遍历 DIALERS，于是对端
    // 反向连入时 `chat_sessions()` 里看不到它 —— 上层「发送前核实连接」会把
    // 明明能发的对端误判成离线（用户反馈的「PC 端情况复杂时也会发送失败」，
    // 那个「复杂情况」正是对端反向连入）。
    //
    // 只加数据不改 DTO 形状，因此**不需要重新跑 codegen**。
    if let Ok(slot) = LISTENER.lock() {
        if let Some(listener) = slot.as_ref() {
            for peer_id in listener.peers() {
                if !seen.insert(peer_id.clone()) {
                    continue; // dialer 已经报过这条，别重复
                }
                out.push(ChatSessionDto {
                    peer_id,
                    state: ChatStateDto::Connected,
                    connected: true,
                });
            }
        }
    }
    out.sort_by(|a, b| a.peer_id.cmp(&b.peer_id));
    out
}

#[frb(sync)]
pub fn chat_is_listening() -> bool {
    LISTENER
        .lock()
        .map(|slot| slot.is_some())
        .unwrap_or(false)
}

/// 断开某个对端 / 全部对端（UI 关闭会话用）。
pub fn chat_hangup(peer_id: String) -> bool {
    let mut stopped = false;
    if let Ok(mut slot) = DIALERS.lock() {
        if let Some(map) = slot.as_mut() {
            if let Some(mut dialer) = map.remove(&peer_id) {
                dialer.stop();
                stopped = true;
            }
        }
    }
    stopped
}

/// 停止监听（退出前调用）。
pub fn chat_stop_listening() {
    if let Ok(mut slot) = LISTENER.lock() {
        if let Some(mut listener) = slot.take() {
            listener.stop();
        }
    }
}

/// 订阅会话事件流。**须在 chatListen / chatDial 之前调用**。
pub fn chat_subscribe(sink: StreamSink<ChatEventDto>) -> anyhow::Result<()> {
    // 文件事件先有消费者再接聊天流：避免启动瞬间的 FILE_META 被丢弃（T4.x）
    crate::api::transfer::ensure_hub()?;
    let rx = take_bus_rx()?;
    std::thread::Builder::new()
        .name("lanchat-chat-bridge".into())
        .spawn(move || {
            use std::sync::mpsc::RecvTimeoutError;
            // 用 recv_timeout 而不是裸 recv：Dart 侧取消订阅后 send 会失败，
            // 但裸 recv 会一直阻塞、线程永远不退出（取消时表现为卡住）。
            loop {
                let event = match rx.recv_timeout(std::time::Duration::from_millis(500)) {
                    Ok(event) => event,
                    // 空闲：继续等（真正的退出靠 add 失败）
                    Err(RecvTimeoutError::Timeout) => continue,
                    Err(RecvTimeoutError::Disconnected) => break,
                };
                // 文件帧不进聊天 UI：转给 transfer hub（如果已注册）
                let is_file = matches!(
                    event,
                    SessionEvent::FileMeta { .. }
                        | SessionEvent::FileChunk { .. }
                        | SessionEvent::FileAck { .. }
                        | SessionEvent::FileDone { .. }
                        // 取消也必须转发给中枢，否则接收方收不到、取消无法双端同步
                        | SessionEvent::FileAbort { .. }
                );
                if is_file {
                    if let Ok(slot) = FILE_EVENT_TX.lock() {
                        if let Some(tx) = slot.as_ref() {
                            if tx.send(event.clone()).is_err() {
                                // hub 已断开：丢弃文件事件
                            }
                            continue;
                        }
                    }
                    continue; // 没注册 hub：文件事件没有消费者
                }
                let dto = event_to_dto(&event);
                // 收到即入库（失败不阻塞 UI，但事件照推）
                if let SessionEvent::Message { peer_id, message } = &event {
                    let _ = append_message(
                        peer_id,
                        false,
                        &message.text,
                        message.ts_ms,
                        message.seq,
                        &message.sender_id,
                    );
                }
                if sink.add(dto).is_err() {
                    break;
                }
            }
        })?;
    Ok(())
}

fn event_to_dto(event: &SessionEvent) -> ChatEventDto {
    match event {
        SessionEvent::Connected { peer_id, name, addr } => ChatEventDto {
            kind: ChatEventKindDto::Connected,
            peer_id: Some(peer_id.clone()),
            name: Some(name.clone()),
            addr: Some(addr.clone()),
            reason: None,
            message: None,
            seq: None,
            state: Some(ChatStateDto::Connected),
            pin: None,
            accepted: None,
        },
        SessionEvent::Disconnected { peer_id, reason } => ChatEventDto {
            kind: ChatEventKindDto::Disconnected,
            peer_id: peer_id.clone(),
            name: None,
            addr: None,
            reason: Some(reason.clone()),
            message: None,
            seq: None,
            state: Some(ChatStateDto::Disconnected),
            pin: None,
            accepted: None,
        },
        SessionEvent::Message { peer_id, message } => ChatEventDto {
            kind: ChatEventKindDto::Message,
            peer_id: Some(peer_id.clone()),
            name: None,
            addr: None,
            reason: None,
            message: Some(MessageDto {
                // 与落库时的 id 规则保持一致（sender_id + seq），避免同一消息两条记录
                id: message_id(&message.sender_id, message.seq),
                peer_id: peer_id.clone(),
                seq: message.seq.min(i64::MAX as u64) as i64,
                from_me: false,
                kind: 1, // 会话层只有文本帧；文件消息走 transfer 落库
                text: message.text.clone(),
                file_name: String::new(),
                file_size: 0,
                ts_ms: message.ts_ms,
                delivered: true,
            }),
            seq: Some(message.seq.min(i64::MAX as u64) as i64),
            state: None,
            pin: None,
            accepted: None,
        },
        SessionEvent::Sent { peer_id, seq } => ChatEventDto {
            kind: ChatEventKindDto::Sent,
            peer_id: peer_id.clone(),
            name: None,
            addr: None,
            reason: None,
            message: None,
            seq: Some(*seq as i64),
            state: None,
            pin: None,
            accepted: None,
        },
        SessionEvent::PairRequest {
            peer_id,
            pin,
            ts_ms: _,
        } => ChatEventDto {
            kind: ChatEventKindDto::PairRequest,
            peer_id: Some(peer_id.clone()),
            name: None,
            addr: None,
            reason: None,
            message: None,
            seq: None,
            state: None,
            pin: Some(pin.clone()),
            accepted: None,
        },
        // B1-4：对端静默**不是**断开事件，也不该让 UI 见到任何东西。
        // 这里显式吞掉（而不是落进下面 FileFrame 那条 `kind: Sent` 的兜底臂），
        // 免得给 Dart 推一条语义不明的 Sent 事件。Dart 侧的在线展示由
        // 「最近一次收到对端数据的时间」自行递减（见 app_state./_isOnline）。
        SessionEvent::Stalled { .. } => ChatEventDto {
            kind: ChatEventKindDto::Sent,
            peer_id: None,
            name: None,
            addr: None,
            reason: None,
            message: None,
            seq: None,
            state: None,
            pin: None,
            accepted: None,
        },
        // 文件帧由 api::transfer 的事件流单独处理，聊天事件流忽略
        SessionEvent::FileMeta { .. }
        | SessionEvent::FileChunk { .. }
        | SessionEvent::FileAck { .. }
        | SessionEvent::FileDone { .. }
        | SessionEvent::FileAbort { .. } => ChatEventDto {
            kind: ChatEventKindDto::Sent,
            peer_id: None,
            name: None,
            addr: None,
            reason: None,
            message: None,
            seq: None,
            state: None,
            pin: None,
            accepted: None,
        },
        SessionEvent::PairResponse {
            peer_id,
            accepted,
            reason,
        } => ChatEventDto {
            kind: ChatEventKindDto::PairResponse,
            peer_id: Some(peer_id.clone()),
            name: None,
            addr: None,
            reason: reason.clone(),
            message: None,
            seq: None,
            state: None,
            pin: None,
            accepted: Some(*accepted),
        },
    }
}

// ------------------------------------------------------------
// 消息存储
// ------------------------------------------------------------

/// 打开消息目录（%APPDATA%/LanChat 或 Android 私有目录）。
pub fn messages_open(data_dir: String) -> anyhow::Result<MessageStoreStatusDto> {
    if data_dir.trim().is_empty() {
        bail!("data_dir 不能为空");
    }
    let dir = std::path::PathBuf::from(data_dir).join("chat");
    // 收件目录跟着消息根目录走（T4.6）
    let _ = MessageStore::set_download_root(&dir);
    let store = MessageStore::open(&dir);
    let status = status_of(&store);
    *MESSAGES.lock().map_err(|_| anyhow!("messages poisoned"))? = Some(store);
    // 发件箱与消息存储同目录：一次 messages_open 同时打开两者，
    // 避免 Dart 侧还要多写一个初始化调用（也避免忘记调用导致离线消息丢失）。
    let outbox = OutboxStore::open(&dir);
    *OUTBOX.lock().map_err(|_| anyhow!("outbox poisoned"))? = Some(outbox);
    Ok(status)
}

fn status_of(store: &MessageStore) -> MessageStoreStatusDto {
    MessageStoreStatusDto {
        dir: store.dir().to_string_lossy().to_string(),
        total: store.total() as i32,
        total_unread: store.total_unread() as i32,
        skipped_lines: store.skipped_lines() as i32,
    }
}

#[frb(sync)]
pub fn messages_status() -> MessageStoreStatusDto {
    MESSAGES
        .lock()
        .ok()
        .and_then(|slot| slot.as_ref().map(status_of))
        .unwrap_or(MessageStoreStatusDto {
            dir: String::new(),
            total: 0,
            total_unread: 0,
            skipped_lines: 0,
        })
}

fn with_store<T>(f: impl FnOnce(&mut MessageStore) -> anyhow::Result<T>) -> anyhow::Result<T> {
    let mut guard = MESSAGES.lock().map_err(|_| anyhow!("messages poisoned"))?;
    let store = guard
        .as_mut()
        .ok_or_else(|| anyhow!("消息存储未打开，请先 messagesOpen()"))?;
    f(store)
}

fn with_outbox<T>(f: impl FnOnce(&mut OutboxStore) -> anyhow::Result<T>) -> anyhow::Result<T> {
    let mut guard = OUTBOX.lock().map_err(|_| anyhow!("outbox poisoned"))?;
    let store = guard
        .as_mut()
        .ok_or_else(|| anyhow!("发件箱未打开，请先 messagesOpen()"))?;
    f(store)
}

/// 消息 id 规则：发送方 id + 会话内序号（收发两侧一致，天然去重）。
fn message_id(sender_id: &str, seq: u64) -> String {
    format!("{sender_id}-{seq}")
}

/// 追加一条消息（UI 极少直接调用；收发路径内部已落库）。
#[allow(clippy::too_many_arguments)]
pub fn messages_append(
    peer_id: String,
    from_me: bool,
    text: String,
    ts_ms: i64,
    seq: i64,
    // 1=text 2=image 3=file（None = 文本）；file_* 为文件消息字段；
    // msg_id 覆盖 id 规则（file_id 派生），None = 发送方 + 序号
    kind: Option<i64>,
    file_name: Option<String>,
    file_size: Option<i64>,
    msg_id: Option<String>,
    // 文件内容哈希（blake3）。入站查重键：补发时 file_id 会变，只有它不变。
    hash_hex: Option<String>,
) -> anyhow::Result<MessageDto> {
    let sender = if from_me {
        "me".to_string()
    } else {
        peer_id.clone()
    };
    append_message_ex(
        &peer_id,
        from_me,
        &text,
        if ts_ms == 0 { now_ms() } else { ts_ms },
        seq.max(0) as u64,
        &sender,
        kind.unwrap_or(1).clamp(1, 3) as u8,
        file_name.as_deref().unwrap_or(""),
        file_size.unwrap_or(0).max(0) as u64,
        msg_id,
        hash_hex.as_deref().unwrap_or(""),
    )
}

/// 落库并返回消息 DTO（收发路径共用；文本 id = 发送方 + 序号）。
fn append_message(
    peer_id: &str,
    from_me: bool,
    text: &str,
    ts_ms: i64,
    seq: u64,
    sender_id: &str,
) -> anyhow::Result<MessageDto> {
    append_message_ex(peer_id, from_me, text, ts_ms, seq, sender_id, 1, "", 0, None, "")
}

/// 全量参数版（文件消息 kind=3 + id 覆盖，T4.x）。
#[allow(clippy::too_many_arguments)]
fn append_message_ex(
    peer_id: &str,
    from_me: bool,
    text: &str,
    ts_ms: i64,
    seq: u64,
    sender_id: &str,
    kind: u8,
    file_name: &str,
    file_size: u64,
    msg_id: Option<String>,
    hash_hex: &str,
) -> anyhow::Result<MessageDto> {
    let message = StoredMessage {
        id: msg_id.unwrap_or_else(|| message_id(sender_id, seq)),
        peer_id: peer_id.to_string(),
        seq: seq.min(i64::MAX as u64) as i64,
        from_me,
        kind,
        text: text.to_string(),
        file_name: file_name.to_string(),
        file_size,
        ts_ms,
        delivered: true,
        hash_hex: hash_hex.to_string(),
    };
    let dto = MessageDto::from(&message);
    with_store(|store| {
        store.append(message)?;
        Ok(())
    })?;
    Ok(dto)
}

/// 接收端把「收全了一个文件」落库成 kind=3 / from_me=false 的消息记录。
///
/// 之前这条记录只由 Dart 的 appendMessage 写（纯 UI 通知，不进 Rust 存储），
/// 导致重启后 `lookup_received_hash` 查不到任何东西、查重闸永远放行 ——
/// 离线补发的文件会被反复落成 report(1).pdf。现在收端在 on_done 成功后
/// 直接在这里落库（哈希来自 FileDone 帧，无需 Dart 参与）。
pub(crate) fn record_received_file(
    peer_id: &str,
    file_id: &str,
    hash_hex: &str,
    file_name: &str,
    file_size: u64,
) {
    if hash_hex.is_empty() || file_name.is_empty() {
        return;
    }
    let _ = append_message_ex(
        peer_id,
        false,
        "",
        crate::api::chat::now_ms(),
        0,
        peer_id,
        3,
        file_name,
        file_size,
        Some(format!("file-{file_id}")),
        hash_hex,
    );
}

/// 按内容哈希查已收到的文件消息（文件名）。
/// 给 `api::transfer` 的入站查重使用：`MESSAGES` 是私有 static，
/// 从别的模块拿不到，必须在这里开一个只读查询口。
/// 存储未打开时返回 None（正常路径下 hub 启动前就已 `messagesOpen`）。
pub fn lookup_received_hash(hash_hex: &str) -> Option<String> {
    if hash_hex.is_empty() {
        return None;
    }
    MESSAGES
        .lock()
        .ok()
        .and_then(|slot| {
            slot.as_ref()
                .and_then(|store| store.find_received_by_hash(hash_hex))
                .map(|m| m.file_name.clone())
        })
        .filter(|name| !name.is_empty())
}

/// 删掉单条消息（内存 + 磁盘 JSONL 重写）。返回是否真的删掉了一条。
///
/// 只从 Dart 侧的内存列表摘掉是不够的 —— 重启一读文件就又回来了。
pub fn messages_remove(peer_id: String, msg_id: String) -> anyhow::Result<bool> {
    with_store(|store| Ok(store.remove_message(&peer_id, &msg_id)?))
}
/// 清空某个会话的本地记录（聊天列表的「清空本地记录」）。
pub fn messages_clear(peer_id: String) -> anyhow::Result<bool> {
    with_store(|store| Ok(store.clear(&peer_id)?))
}

/// keyset 分页：before_ts_ms 传 i64::MAX 表示第一页（新的在前）。
#[frb(sync)]
pub fn messages_page(peer_id: String, limit: u32, before_ts_ms: i64) -> Vec<MessageDto> {
    MESSAGES
        .lock()
        .ok()
        .and_then(|slot| {
            slot.as_ref().map(|store| {
                store
                    .page(
                        &peer_id,
                        PageQuery {
                            limit: if limit == 0 { 50 } else { limit },
                            before_ts_ms,
                        },
                    )
                    .iter()
                    .map(MessageDto::from)
                    .collect()
            })
        })
        .unwrap_or_default()
}

#[frb(sync)]
pub fn messages_unread(peer_id: String) -> i32 {
    MESSAGES
        .lock()
        .ok()
        .and_then(|slot| slot.as_ref().map(|store| store.unread(&peer_id) as i32))
        .unwrap_or(0)
}

/// 标记已读（只前进不后退），返回剩余未读。
pub fn messages_mark_read(peer_id: String, upto_ts_ms: i64) -> anyhow::Result<i32> {
    with_store(|store| Ok(store.mark_read(&peer_id, upto_ts_ms)? as i32))
}

/// 会话摘要（聊天列表页；按最后消息时间倒序）。
#[frb(sync)]
pub fn messages_conversations() -> Vec<ConversationDto> {
    MESSAGES
        .lock()
        .ok()
        .and_then(|slot| {
            slot.as_ref().map(|store| {
                store
                    .conversations()
                    .iter()
                    .map(|c| ConversationDto {
                        peer_id: c.peer_id.clone(),
                        count: c.count as i32,
                        unread: c.unread as i32,
                        last_ts_ms: c.last_ts_ms,
                        last_text: c.last_text.clone(),
                    })
                    .collect()
            })
        })
        .unwrap_or_default()
}

/// 发件箱条目（UI 展示「待发送」标记用）。
#[derive(Debug, Clone)]
pub struct OutboxItemDto {
    pub id: String,
    pub peer_id: String,
    pub kind: i32,
    pub text: String,
    pub file_path: String,
    pub file_name: String,
    pub file_size: i64,
    pub created_ms: i64,
}

impl From<&OutboxEntry> for OutboxItemDto {
    fn from(e: &OutboxEntry) -> Self {
        Self {
            id: e.id.clone(),
            peer_id: e.peer_id.clone(),
            kind: e.kind as i32,
            text: e.text.clone(),
            file_path: e.file_path.clone(),
            file_name: e.file_name.clone(),
            file_size: e.file_size.min(i64::MAX as u64) as i64,
            created_ms: e.created_ms,
        }
    }
}

/// 文本入发件箱（对方离线时调用）。返回入队 id。
pub fn chat_outbox_enqueue_text(peer_id: String, text: String) -> anyhow::Result<String> {
    let trimmed = text.trim();
    if peer_id.trim().is_empty() || trimmed.is_empty() {
        bail!("peer_id / text 不能为空");
    }
    // 无连接时 seq 取 0：这里的序号只用于拼 id 去重，
    // 真正的协议 seq 在补发时由对话连接分配，不参与协议。
    // 追加进程内计数器：now_ms() 在 Windows 上粒度约 15.6ms，只靠时间戳
    // 会让同一毫秒内的两条文本撞成同一个 id，第二条被 enqueue 静默吞掉。
    let id = format!("outbox-{}-{}-{}", peer_id, now_ms(), next_outbox_seq());
    let text = trimmed.to_string();
    with_outbox(|store| {
        store.enqueue(OutboxEntry {
            id: id.clone(),
            peer_id,
            kind: 1,
            text,
            file_path: String::new(),
            file_name: String::new(),
            file_size: 0,
            created_ms: now_ms(),
        })?;
        Ok(())
    })?;
    Ok(id)
}

/// 文件入发件箱。`file_id` 为内容哈希，id 规则与落库一致（`file-<file_id>`），
/// 从而保证「入站查重」与「发件箱去重」用的是同一个键。
pub fn chat_outbox_enqueue_file(
    peer_id: String,
    file_id: String,
    path: String,
    file_name: String,
    file_size: i64,
    kind: i32,
) -> anyhow::Result<String> {
    if peer_id.trim().is_empty() || file_id.trim().is_empty() || path.trim().is_empty() {
        bail!("peer_id / file_id / path 不能为空");
    }
    let id = format!("file-{file_id}");
    with_outbox(|store| {
        store.enqueue(OutboxEntry {
            id: id.clone(),
            peer_id,
            kind: kind.clamp(2, 3) as u8,
            text: String::new(),
            file_path: path,
            file_name,
            file_size: file_size.max(0) as u64,
            created_ms: now_ms(),
        })?;
        Ok(())
    })?;
    Ok(id)
}

/// 文件内容 id：`blake3` 十六进制（复用 `backend::transfer::hash_file`）。
///
/// 为什么需要它（用户反馈 B1-5「离线发一个文件，发送端出现 N 个发送气泡，
/// 接收端上线也收不到」）：发件箱的去重键是 `file-<file_id>`
/// （见 [`chat_outbox_enqueue_file`]），而 `transfer_send` 的 file_id 是
/// **每次新建的 UUID**（`api/transfer.rs` 里 `Uuid::new_v4()`），
/// 拿它当发件箱去重键等于每次都产生新条目 —— 同一文件反复入队就变成 N 条。
/// `OutboxStore::enqueue` 只按 id 去重（`backend/storage.rs`），所以
/// **入队方必须自己保证「同一文件 → 同一个 id」**，这里提供这个稳定 id。
///
/// 语义与「入站查重」（`lookup_received_hash`）一致：都按内容哈希，因此
/// 「同一文件重复发送」在两端都会收敛成一条。
///
/// 计算成本：整读一遍文件（流式，128KB buffer），大文件可能耗时数百毫秒，
/// 调用方应在异步上下文里调（不要 `#[frb(sync)]`）。
pub fn chat_file_content_id(path: String) -> anyhow::Result<String> {
    let p = std::path::PathBuf::from(&path);
    if !p.is_file() {
        bail!("文件不存在：{path}");
    }
    crate::backend::transfer::hash_file(&p)
        .map_err(|e| anyhow::anyhow!("计算文件内容哈希失败：{e}"))
}

/// 待发项。`peer_id` 为 None 时返回全部。
#[frb(sync)]
pub fn chat_outbox_pending(peer_id: Option<String>) -> Vec<OutboxItemDto> {
    OUTBOX
        .lock()
        .ok()
        .and_then(|slot| {
            slot.as_ref().map(|store| match &peer_id {
                Some(p) => store.pending(p),
                None => store.all_pending(),
            })
        })
        .unwrap_or_default()
        .iter()
        .map(OutboxItemDto::from)
        .collect()
}

/// 待发项涉及的对端（周期扫描据此决定给谁拨号）。
#[frb(sync)]
pub fn chat_outbox_peers() -> Vec<String> {
    OUTBOX
        .lock()
        .ok()
        .and_then(|slot| slot.as_ref().map(|s| s.peers_with_pending()))
        .unwrap_or_default()
}

/// 标记已送达：从待发箱移除。幂等。
pub fn chat_outbox_ack(id: String) -> anyhow::Result<()> {
    with_outbox(|store| store.mark_sent(&id).map_err(Into::into))
}

/// 用户主动取消待发项。返回是否真的移除了。
pub fn chat_outbox_cancel(id: String) -> anyhow::Result<bool> {
    with_outbox(|store| store.remove(&id).map_err(Into::into))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn self_hello_carries_chat_port() {
        let info = SelfInfo {
            device_id: "dev-a".into(),
            name: "PC".into(),
            platform: "windows".into(),
        };
        let hello = self_hello(&info, 45_998);
        assert_eq!(hello.device_id, "dev-a");
        assert_eq!(hello.chat_port, 45_998);
        assert_eq!(hello.proto_version, crate::backend::protocol::VERSION);
    }

    #[test]
    fn state_dto_maps_all_states() {
        assert_eq!(state_dto(&SessionState::Disconnected), ChatStateDto::Disconnected);
        assert_eq!(state_dto(&SessionState::Connecting), ChatStateDto::Connecting);
        assert_eq!(state_dto(&SessionState::Connected), ChatStateDto::Connected);
        assert_eq!(
            state_dto(&SessionState::Reconnecting {
                attempt: 2,
                backoff_ms: 1000
            }),
            ChatStateDto::Reconnecting
        );
    }

    #[test]
    fn message_dto_roundtrips() {
        let stored = StoredMessage {
            id: "m1".into(),
            peer_id: "dev-a".into(),
            seq: 3,
            from_me: false,
            kind: 1,
            text: "你好".into(),
            file_name: String::new(),
            file_size: 0,
            ts_ms: 123,
            delivered: true,
            hash_hex: String::new(),
        };
        let dto = MessageDto::from(&stored);
        assert_eq!(dto.text, "你好");
        assert!(!dto.from_me);
        assert_eq!(dto.ts_ms, 123);
    }

    #[test]
    fn event_dto_maps_message_and_sent() {
        let msg = crate::backend::protocol::TextPayload {
            sender_id: "dev-b".into(),
            seq: 7,
            text: "hi".into(),
            ts_ms: 999,
        };
        let dto = event_to_dto(&SessionEvent::Message {
            peer_id: "dev-b".into(),
            message: msg,
        });
        assert_eq!(dto.kind, ChatEventKindDto::Message);
        assert_eq!(dto.seq, Some(7));
        assert_eq!(dto.message.unwrap().text, "hi");

        let sent = event_to_dto(&SessionEvent::Sent {
            peer_id: Some("dev-b".into()),
            seq: 3,
        });
        assert_eq!(sent.kind, ChatEventKindDto::Sent);
        assert_eq!(sent.seq, Some(3));
    }

    #[test]
    fn messages_open_rejects_empty_dir() {
        assert!(messages_open("  ".into()).is_err());
    }

    /// 拨号连接不可用时，发文本应回退到监听端的入站连接（而不是直接抛
    /// 「未连接到对端」）。复现线上场景：出站 Dialer 还在拨号/重连（连不上），
    /// 但对端已反向连入、UI 显示在线。
    #[test]
    fn chat_send_text_falls_back_to_inbound_when_dialer_dead() {
        // 本机（被连入方）开监听
        let info_a = SelfInfo {
            device_id: "dev-a".into(),
            name: "A".into(),
            platform: "windows".into(),
        };
        let port = chat_listen(info_a.clone(), 0).expect("监听应成功");

        // 对端 dev-b 主动连进来，形成入站活连接
        let info_b = SelfInfo {
            device_id: "dev-b".into(),
            name: "B".into(),
            platform: "android".into(),
        };
        let (tx_b, rx_b) = channel();
        let mut dialer_b =
            session::dial(session_cfg(&info_b, 0), format!("127.0.0.1:{port}"), tx_b)
                .expect("对端应能拨入");
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            let ready = LISTENER
                .lock()
                .map(|slot| {
                    slot.as_ref()
                        .map(|l| l.peers().contains(&"dev-b".to_string()))
                        .unwrap_or(false)
                })
                .unwrap_or(false);
            if ready {
                break;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "入站握手超时：监听端未见到 dev-b"
            );
            std::thread::sleep(std::time::Duration::from_millis(50));
        }

        // 给 dev-b 注册一个永远拨不通的出站拨号（旧代码在这里把 NotConnected 直接抛出）
        chat_dial(info_a.clone(), "dev-b".into(), "127.0.0.1:1".into())
            .expect("死拨号注册应成功");

        // 发文本需要落库。
        // 必须与其他调 `messages_open` 的测试互斥：`MESSAGES`/`OUTBOX` 都是进程级
        // static，两边都调 `messages_open` 会把对方的 store 顶掉。
        let _gate = super::messages_test_lock();
        let dir = std::env::temp_dir().join(format!(
            "yuchuan_send_text_fallback_{}",
            std::process::id()
        ));
        messages_open(dir.to_string_lossy().into()).expect("消息存储应打开");

        let msg = chat_send_text("dev-b".into(), "dev-a".into(), "回退成功".into())
            .expect("拨号不可用时应通过监听端入站连接发出");
        assert_eq!(msg.text, "回退成功");
        assert!(msg.from_me);

        // 清理全局 static，避免影响同进程其他测试
        chat_hangup("dev-b".into());
        chat_stop_listening();
        dialer_b.stop();
        let _ = rx_b; // 事件接收端保持存活到测试结束
    }

    /// 打开一个独占的发件箱测试目录，返回串行闸的守卫（须活到测试结束）。
    fn outbox_test_open(tag: &str) -> std::sync::MutexGuard<'static, ()> {
        let guard = super::messages_test_lock();
        let dir = std::env::temp_dir().join(format!(
            "lanchat_outbox_api_{}_{}",
            tag,
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        let _ = messages_open(dir.to_string_lossy().to_string()).unwrap();
        guard
    }

    #[test]
    fn outbox_enqueue_pending_ack_roundtrip() {
        let _gate = outbox_test_open("roundtrip");

        let id = chat_outbox_enqueue_text("peer-x".into(), "hello offline".into()).unwrap();
        assert!(!id.is_empty());

        let pending = chat_outbox_pending(Some("peer-x".into()));
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].text, "hello offline");
        assert_eq!(pending[0].kind, 1);

        // 对端上线、补发成功 → ack 后不再待发
        chat_outbox_ack(id.clone()).unwrap();
        assert_eq!(chat_outbox_pending(Some("peer-x".into())).len(), 0);

        // ack 是幂等的（周期扫描与上线事件可能都调一次）
        chat_outbox_ack(id).unwrap();
        assert_eq!(chat_outbox_pending(Some("peer-x".into())).len(), 0);
    }

    #[test]
    fn outbox_id_uses_content_hash_for_files() {
        let _gate = outbox_test_open("dupid");

        let a = chat_outbox_enqueue_file(
            "peer-x".into(),
            "hash1".into(),
            "/tmp/a.bin".into(),
            "a.bin".into(),
            10,
            3,
        )
        .unwrap();
        let b = chat_outbox_enqueue_file(
            "peer-x".into(),
            "hash1".into(),
            "/tmp/a.bin".into(),
            "a.bin".into(),
            10,
            3,
        )
        .unwrap();

        assert_eq!(a, "file-hash1");
        // 同一个文件重复入队只留一条：对端不会收到两份
        assert_eq!(a, b);
        assert_eq!(chat_outbox_pending(Some("peer-x".into())).len(), 1);
    }

    #[test]
    fn outbox_cancel_allows_reenqueue_of_same_file() {
        let _gate = outbox_test_open("recancel");

        let id = chat_outbox_enqueue_file(
            "peer-x".into(),
            "hash2".into(),
            "/tmp/b.bin".into(),
            "b.bin".into(),
            10,
            3,
        )
        .unwrap();
        assert!(chat_outbox_cancel(id.clone()).unwrap());
        assert_eq!(chat_outbox_pending(Some("peer-x".into())).len(), 0);

        // 用户取消后想重发同一个文件：不能再被 sent_ids 钉死
        assert_eq!(
            chat_outbox_enqueue_file(
                "peer-x".into(),
                "hash2".into(),
                "/tmp/b.bin".into(),
                "b.bin".into(),
                10,
                3,
            )
            .unwrap(),
            id
        );
        assert_eq!(chat_outbox_pending(Some("peer-x".into())).len(), 1);
    }

    #[test]
    fn outbox_ack_blocks_same_file_reenqueue() {
        let _gate = outbox_test_open("reack");

        let id = chat_outbox_enqueue_file(
            "peer-x".into(),
            "hash3".into(),
            "/tmp/c.bin".into(),
            "c.bin".into(),
            10,
            3,
        )
        .unwrap();
        chat_outbox_ack(id.clone()).unwrap();
        assert_eq!(chat_outbox_pending(None).len(), 0);

        // 已确认送达的文件重新入队应被吞掉（回执与重发竞争时不重复传）
        let again = chat_outbox_enqueue_file(
            "peer-x".into(),
            "hash3".into(),
            "/tmp/c.bin".into(),
            "c.bin".into(),
            10,
            3,
        )
        .unwrap();
        assert_eq!(again, id);
        assert_eq!(chat_outbox_pending(None).len(), 0);
    }

    /// 回归（B1-5）：`chat_file_content_id` 必须**只由内容决定** —— 同一内容
    /// 无论路径/文件名怎么变都是同一个 id（这样发件箱去重键才稳定），
    /// 内容不同则 id 必须不同（否则去重会误吞另一个文件）。
    #[test]
    fn file_content_id_is_stable_by_content_not_path() {
        let dir = std::env::temp_dir().join(format!(
            "yuchuan_content_id_{}",
            std::process::id()
        ));
        let _ = std::fs::create_dir_all(&dir);

        let a = dir.join("a.bin");
        let b = dir.join("b.bin"); // 同内容、不同路径/文件名
        let c = dir.join("c.bin"); // 同大小、不同内容
        std::fs::write(&a, b"same-payload").unwrap();
        std::fs::write(&b, b"same-payload").unwrap();
        std::fs::write(&c, b"diff-payload").unwrap(); // 长度也是 12

        let ida = chat_file_content_id(a.to_string_lossy().into()).unwrap();
        let idb = chat_file_content_id(b.to_string_lossy().into()).unwrap();
        let idc = chat_file_content_id(c.to_string_lossy().into()).unwrap();

        assert_eq!(ida.len(), 64, "应是 blake3 hex，实际 {ida}");
        assert_eq!(ida, idb, "同一内容必须得到同一个 id（与路径无关）");
        assert_ne!(ida, idc, "同大小不同内容必须得到不同 id（否则去重会误吞）");

        // 不存在的文件必须报错，而不是返回空 id 让调用方拿空键去重
        assert!(chat_file_content_id(dir.join("nope.bin").to_string_lossy().into()).is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 回归（B1-5，端到端口径）：用同一份内容算出的 id 反复入队，
    /// 发件箱里只应有一条待发 —— 这正是用户看到的「N 个气泡」的源头。
    #[test]
    fn outbox_dedupes_repeated_enqueue_with_content_id() {
        let _gate = outbox_test_open("contentid");
        let dir = std::env::temp_dir().join(format!(
            "yuchuan_content_id_enqueue_{}",
            std::process::id()
        ));
        let _ = std::fs::create_dir_all(&dir);
        let f = dir.join("payload.bin");
        std::fs::write(&f, b"payload-for-enqueue").unwrap();
        let path = f.to_string_lossy().to_string();

        let cid = chat_file_content_id(path.clone()).unwrap();
        // 模拟「离线早期返回分支」与「发送失败 catch 分支」以及后续每一次补发
        for _ in 0..5 {
            chat_outbox_enqueue_file(
                "peer-x".into(),
                cid.clone(),
                path.clone(),
                "payload.bin".into(),
                19,
                3,
            )
            .unwrap();
        }
        let pending = chat_outbox_pending(Some("peer-x".into()));
        assert_eq!(
            pending.len(),
            1,
            "同一文件反复入队只应留一条，实际 {}: {:?}",
            pending.len(),
            pending.iter().map(|p| &p.id).collect::<Vec<_>>()
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 回归（用户反馈「离线发一个文件，发送端窗口出现 N 个发送气泡，
    /// 接收端上线也收不到」）：发件箱的去重键是 `file-<file_id>`，而
    /// **Rust 这层只能按 id 去重**（它看不到文件内容，`OutboxStore::enqueue`
    /// 只比 id）。所以「同一文件只留一条」的责任在**调用方**：
    /// 必须传同一个内容哈希。本测试锁死 Rust 侧的契约面 ——
    /// 不同 file_id ⇒ 不同条目（Rust 不会、也不应该按文件名/大小去猜），
    /// 这正是为什么 Dart 侧两套 id 会真的产生 N 条。
    #[test]
    fn outbox_file_entries_dedupe_key_is_the_caller_supplied_id() {
        let _gate = outbox_test_open("fileidkey");

        // Dart 旧「离线分支」的 id 方案：'${path.hashCode}-$size'
        chat_outbox_enqueue_file(
            "peer-x".into(),
            "1234567-4096".into(),
            "/tmp/report.pdf".into(),
            "report.pdf".into(),
            4096,
            3,
        )
        .unwrap();
        // Dart 旧「catch 分支」的 id 方案：'file-pending-file-<微秒>'
        chat_outbox_enqueue_file(
            "peer-x".into(),
            "file-pending-file-1700000000000001".into(),
            "/tmp/report.pdf".into(),
            "report.pdf".into(),
            4096,
            3,
        )
        .unwrap();

        // 同一物理文件（同 path/name/size）因 id 不同而排成两条 —— 说明
        // 「N 个气泡」的根在 Dart 侧 id 不一致，Rust 侧无法补救。
        let pending = chat_outbox_pending(Some("peer-x".into()));
        assert_eq!(
            pending.len(),
            2,
            "Rust 只按 id 去重：不同 id 必须各自成条（否则这条测试的前提就错了）"
        );

        // 同一个 id 再入队则必须被吞掉 —— 这才是 Rust 保证的那一半契约。
        chat_outbox_enqueue_file(
            "peer-x".into(),
            "1234567-4096".into(),
            "/tmp/report.pdf".into(),
            "report.pdf".into(),
            4096,
            3,
        )
        .unwrap();
        assert_eq!(
            chat_outbox_pending(Some("peer-x".into())).len(),
            2,
            "同 id 重复入队必须被吞掉"
        );
    }

    #[test]
    fn outbox_same_ms_texts_do_not_collide() {
        // 真实缺陷：id 原本是 `outbox-<peer>-<now_ms()>`，而 now_ms() 在 Windows
        // 上粒度约 15.6ms：同一毫秒内连发两条文本会算出同一个 id，而 enqueue
        // 按 id 幂等 → 第二条被静默丢弃，表现就是「离线消息对端收不到」。
        // 文本没有内容哈希可用，所以必须靠计数器保证唯一。
        let _gate = outbox_test_open("samems");

        // 紧凑循环：真实场景就是用户在离线状态下连着敲好几条。
        let mut ids = Vec::new();
        let mut texts = Vec::new();
        for i in 0..8 {
            let text = format!("离线第{i}条");
            ids.push(chat_outbox_enqueue_text("peer-a".into(), text.clone()).unwrap());
            texts.push(text);
        }

        // 1) id 两两不同
        let mut uniq = ids.clone();
        uniq.sort();
        uniq.dedup();
        assert_eq!(uniq.len(), ids.len(), "同一毫秒内的文本 id 不能重复：{ids:?}");

        // 2) 每条都留在发件箱，一条不丢
        let pending = chat_outbox_pending(Some("peer-a".into()));
        assert_eq!(pending.len(), 8, "8 条文本必须全部留在发件箱");
        let got: Vec<String> = pending.iter().map(|i| i.text.clone()).collect();
        for t in &texts {
            assert!(got.contains(t), "发件箱丢了 {t}：{got:?}");
        }

        // 3) 取消其中一条不能带走别的
        assert!(chat_outbox_cancel(ids[0].clone()).unwrap());
        let left = chat_outbox_pending(Some("peer-a".into()));
        assert_eq!(left.len(), 7);
        assert!(!left.iter().any(|i| i.text == texts[0]));
    }

    #[test]
    fn outbox_peers_lists_only_pending_peers() {
        let _gate = outbox_test_open("peers");

        let a = chat_outbox_enqueue_text("peer-a".into(), "m1".into()).unwrap();
        let _ = chat_outbox_enqueue_text("peer-a".into(), "m2".into()).unwrap();
        let _ = chat_outbox_enqueue_text("peer-b".into(), "m3".into()).unwrap();

        let peers = chat_outbox_peers();
        assert_eq!(peers.len(), 2);
        assert!(peers.contains(&"peer-a".to_string()));
        assert!(peers.contains(&"peer-b".to_string()));

        chat_outbox_ack(a).unwrap();
        // peer-a 还有 m2，仍然在列
        assert!(chat_outbox_peers().contains(&"peer-a".to_string()));
    }

    #[test]
    fn outbox_cancel_removes_item() {
        let _gate = outbox_test_open("cancel");

        let id = chat_outbox_enqueue_text("peer-x".into(), "will cancel".into()).unwrap();
        assert!(chat_outbox_cancel(id).unwrap());
        assert_eq!(chat_outbox_pending(Some("peer-x".into())).len(), 0);
        // 二次取消返回 false，不报错
        assert!(!chat_outbox_cancel("no-such-id".into()).unwrap());
    }

    #[test]
    fn outbox_file_entry_keeps_path_and_size() {
        let _gate = outbox_test_open("file");

        let id = chat_outbox_enqueue_file(
            "peer-x".into(),
            "deadbeef".into(),
            "D:/tmp/report.pdf".into(),
            "report.pdf".into(),
            12345,
            3,
        )
        .unwrap();
        assert_eq!(id, "file-deadbeef");

        let pending = chat_outbox_pending(Some("peer-x".into()));
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].file_path, "D:/tmp/report.pdf");
        assert_eq!(pending[0].file_size, 12345);
        assert_eq!(pending[0].kind, 3);
    }
}
