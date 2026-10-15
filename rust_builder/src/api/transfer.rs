//! T4.1/T4.2/T4.4 桥接：文件传输中枢。
//!
//! 结构：
//! - **hub 线程**：`chat_subscribe` 启动时一并拉起（见 [start_hub]），是文件事件的
//!   唯一消费者 —— chat 事件中继把 `File*` 帧转给它，它把驱动器产出的帧经
//!   `send_any_frame` 发回 TCP。
//! - **发送方向**：`transfer_send(path, peer_id)` → Sender（64KB 分块 + 窗口流控）；
//! - **接收方向**：收到 FILE_META 自动建 Receiver（.part + sidecar 指纹 + 完成校验 + 原子改名）；
//! - **进度（T4.4 风险5）**：hub 每 200ms 节流后更新状态，UI 以 2 Hz 拉取
//!   `transfer_status()` —— 只重建对应传输的状态行，不做整页推送；
//! - **锁序**：HUB_STATE →（chat 的 DIALERS/LISTENER），反向路径不存在。
//!
//! v1 约定：单对端同时只接收一个文件（新 FILE_META 替换未完成的旧接收）。
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Receiver as MpscReceiver;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail};

use crate::api::chat::{send_any_frame, take_file_event_rx};
use crate::backend::protocol::{FileAbortPayload, FileAckPayload, FileDonePayload, FrameType};
use crate::backend::session::SessionEvent;
use crate::backend::transfer::{Receiver, SendAction, Sender};

static HUB_STATE: Mutex<Option<HubState>> = Mutex::new(None);
static HUB_ALIVE: AtomicBool = AtomicBool::new(false);

/// 传输方向。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransferDir {
    Send,
    Receive,
}

/// 传输进度快照（UI 查询；hub 200ms 节流更新）。
#[derive(Debug, Clone)]
pub struct TransferStatusDto {
    pub file_id: String,
    pub peer_id: String,
    pub name: String,
    pub dir: TransferDir,
    pub size: u64,
    /// 已确认（发送）/ 已写入（接收）字节数。
    pub transferred: u64,
    pub finished: bool,
    pub failed: bool,
    /// 是否是「取消」收尾（本机取消或对端发来 FILE_ABORT）。
    ///
    /// 与 failed 分开：取消是用户的主动意图，对端应当显示「已取消」，
    /// 而不是「传输失败」（用户反馈「一方取消，对方直接显示失败」）。
    pub cancelled: bool,
    pub error: Option<String>,
    /// 是否处于暂停中（仅发送方向有意义）。
    pub paused: bool,
}

struct SendJob {
    sender: Sender,
    peer_id: String,
}

struct RecvJob {
    receiver: Receiver,
    name: String,
}

/// 待发帧：(peer_id, 帧类型, payload)。
type PendingFrame = (String, FrameType, Vec<u8>);

/// 传输中枢内部状态。不进桥接（frb 会把 api 目录里的标准 trait impl 当成导出函数）。
/// 若不加 `pub(crate)`，frb codegen 会把它当成 opaque type 导出并生成 wire 函数，
/// 导致编译失败（private struct 被 frb_generated.rs 引用）。
pub(crate) struct HubState {
    sends: HashMap<String, SendJob>,
    /// key = peer_id（v1 单对端单接收；FILE_CHUNK 帧不带 file_id，只能按 peer 路由）。
    recvs: HashMap<String, RecvJob>,
    recent: Vec<TransferStatusDto>,
    last_progress_flush: Instant,
    /// 待发帧队列。
    ///
    /// **关键**：socket 写会被 TCP 背压阻塞，而 transfer_status()（UI 线程）
    /// 要拿同一把 HUB_STATE —— 之前在持锁期间直接写 socket，写一阻塞
    /// UI 就整个冻住（用户反馈「PC 端整个软件不响应」）。改成先入队、
    /// 放锁之后再统一发出去，临界区内不再做任何 IO。
    pending_sends: Vec<PendingFrame>,
    /// peer → 当前正在流式发送的 file_id。
    ///
    /// **同 peer 必须串行**：接收端 v1 每个 peer 只有一个 recv job，且
    /// FILE_CHUNK 帧不带 file_id（只有 8B offset + 原始字节），接收端无法把
    /// 交错的块分派到多个文件 —— 同 peer 的第二个 FILE_META 会直接替换掉
    /// 第一个未完成的接收。所以同 peer 的多个文件排队串行；不同 peer 天然并行。
    active_send: HashMap<String, String>,
}

/// 不进桥接（frb 会把 api 目录里的标准 trait impl 当成导出函数）。
impl Default for HubState {
    fn default() -> Self {
        Self {
            sends: HashMap::new(),
            recvs: HashMap::new(),
            recent: Vec::new(),
            last_progress_flush: Instant::now(),
            pending_sends: Vec::new(),
            active_send: HashMap::new(),
        }
    }
}

impl HubState {
    fn push_finished(&mut self, status: TransferStatusDto) {
        self.recent.retain(|s| s.file_id != status.file_id);
        self.recent.push(status);
        if self.recent.len() > 32 {
            self.recent.remove(0);
        }
    }
}

/// 启动 hub（幂等；chat_subscribe 与 transfer_send 都会调用）。
fn start_hub() -> anyhow::Result<()> {
    if HUB_ALIVE.load(Ordering::SeqCst) {
        return Ok(());
    }
    let rx = take_file_event_rx().ok_or_else(|| anyhow!("文件事件接收端已被占用"))?;
    // 先占位再起线程：并发调用者看到 Some 会直接返回。
    *HUB_STATE
        .lock()
        .map_err(|_| anyhow!("hub poisoned"))? = Some(HubState::default());
    HUB_ALIVE.store(true, Ordering::SeqCst);
    if let Err(e) = std::thread::Builder::new()
        .name("lanchat-transfer-hub".into())
        .spawn(move || hub_loop(rx))
    {
        HUB_ALIVE.store(false, Ordering::SeqCst);
        *HUB_STATE.lock().map_err(|_| anyhow!("hub poisoned"))? = None;
        return Err(anyhow!("启动传输线程失败：{e}"));
    }
    Ok(())
}

/// chat_subscribe 启动时调用（保证文件事件一上来就有消费者）。
pub fn ensure_hub() -> anyhow::Result<()> {
    start_hub()
}

fn hub_loop(rx: MpscReceiver<SessionEvent>) {
    while let Ok(event) = rx.recv() {
        let pending = {
            let mut guard = match HUB_STATE.lock() {
                Ok(g) => g,
                Err(_) => break,
            };
            // 锁保证独占：同一时刻只有一个路径能拿到 &mut HubState
            let Some(hub) = guard.as_mut() else { break };
            handle_event(hub, event);
            // 处理完把待发帧取走——真正的 socket 写放到锁外。
            std::mem::take(&mut hub.pending_sends)
        };
        flush_pending(pending);
    }
    HUB_ALIVE.store(false, Ordering::SeqCst);
}

fn handle_event(hub: &mut HubState, event: SessionEvent) {
    match event {
        SessionEvent::FileMeta { peer_id, meta } => {
            let file_id = meta.file_id.clone();
            // 内容级查重：发送方的 file_id 是每次发送新生成的 UUID
            //（api/transfer.rs 的 transfer_send 用 Uuid::new_v4()），所以同一个
            // 文件补发两次会带两个不同的 file_id。真正的身份是整文件哈希
            // hash_hex（blake3，发送侧 Sender::open 算出并放进 meta）。
            // 已经完整收过同内容的文件就直接回 FileDone 跳过，避免：
            //   ① 对端看不到「已收到」而反复补发；
            //   ② 磁盘上多出一份 report(1).pdf 的冗余副本。
            // 半截接收（只有 .part）不算「已收」，照常走续传。
            if crate::api::chat::lookup_received_hash(&meta.hash_hex).is_some() {
                let reply = FileDonePayload {
                    file_id: file_id.clone(),
                    hash_hex: meta.hash_hex.clone(),
                    ok: true,
                    error: None,
                };
                let bytes = serde_json::to_vec(&reply).unwrap_or_default();
                queue_frame(hub, &peer_id, FrameType::FileDone, bytes);
                // 让 Dart 侧也能看到这条已完成记录（否则聊天窗里不显示）。
                hub.push_finished(TransferStatusDto {
                    file_id,
                    peer_id,
                    name: meta.name.clone(),
                    dir: TransferDir::Receive,
                    size: meta.size,
                    transferred: meta.size,
                    finished: true,
                    failed: false,
                    cancelled: false,
                    error: None,
                    paused: false,
                });
                return;
            }
            // v1：单对端单接收，替换未完成的旧接收。
            hub.recvs.remove(&peer_id);
            let mut recv = Receiver::new(receive_dir());
            match recv.on_meta(meta) {
                Ok(ack) => {
                    hub.recvs.insert(
                        peer_id.clone(),
                        RecvJob {
                            receiver: recv,
                            name: hub
                                .recent
                                .iter()
                                .find(|s| s.file_id == file_id)
                                .map(|s| s.name.clone())
                                .unwrap_or_default(),
                        },
                    );
                    // 名称：meta 里已做 sanitize 保留。Receiver meta
                    if let Some(job) = hub.recvs.get_mut(&peer_id) {
                        job.name = job
                            .receiver
                            .meta()
                            .map(|m| m.name.clone())
                            .unwrap_or_default();
                    }
                    queue_ack(hub, &peer_id, &ack);
                }
                Err(e) => {
                    let ack = FileAckPayload {
                        file_id,
                        offset: 0,
                        reason: Some(format!("接收准备失败：{e}")),
                    };
                    queue_ack(hub, &peer_id, &ack);
                }
            }
        }
        SessionEvent::FileAbort { peer_id, file_id } => {
            // 对端取消：双向都要收尾。
            // ① 我正在给它发 → 停止发送（否则会继续把剩余块灌过去）。
            if let Some(job) = hub.sends.remove(&file_id) {
                hub.push_finished(cancelled_send_status(&job, "对方已取消"));
                complete_send(hub, &peer_id, &file_id);
            }
            // ② 我正在收它的 → 丢掉半截 .part 与 sidecar，别一直挂着
            let mine = hub
                .recvs
                .get(&peer_id)
                .and_then(|j| j.receiver.meta())
                .map(|m| m.file_id == file_id)
                .unwrap_or(false);
            if mine {
                if let Some(job) = hub.recvs.remove(&peer_id) {
                    let size = job.receiver.meta().map(|m| m.size).unwrap_or(0);
                    let written = job.receiver.written();
                    let mut job = job;
                    job.receiver.abort();
                    hub.push_finished(TransferStatusDto {
                        file_id,
                        peer_id,
                        name: job.name.clone(),
                        dir: TransferDir::Receive,
                        size,
                        transferred: written,
                        finished: true,
                        failed: false,
                        cancelled: true,
                        error: Some("对方已取消".to_string()),
                        paused: false,
                    });
                }
            } else {
                // 对端在校验阶段取消：FILE_DONE 之后 recv job 已移除，
                // 但气泡刚被标成「已完成」。必须覆盖成取消，否则对端
                // 停留在完成态（用户反馈过 bug）。push_finished 按 file_id
                // 覆盖 recent，正好把那条完成记录改写掉。
                let old = hub.recent.iter().find(|s| s.file_id == file_id);
                if let Some(prev) = old {
                    hub.push_finished(TransferStatusDto {
                        file_id,
                        peer_id,
                        name: prev.name.clone(),
                        dir: TransferDir::Receive,
                        size: prev.size,
                        transferred: prev.transferred,
                        finished: true,
                        failed: false,
                        cancelled: true,
                        error: Some("对方已取消".to_string()),
                        paused: false,
                    });
                }
            }
        }
        SessionEvent::FileChunk {
            peer_id,
            offset,
            data,
        } => {
            if let Some(job) = hub.recvs.get_mut(&peer_id) {
                match job.receiver.on_chunk(offset, &data) {
                    Ok(ack) => queue_ack(hub, &peer_id, &ack),
                    Err(e) => {
                        if let Some(meta) = job.receiver.meta() {
                            let ack = FileAckPayload {
                                file_id: meta.file_id.clone(),
                                offset: 0,
                                reason: Some(format!("写入盘失败: {e}")),
                            };
                            queue_ack(hub, &peer_id, &ack);
                        }
                    }
                }
            }
        }
        SessionEvent::FileAck { peer_id, ack } => {
            let file_id = ack.file_id.clone();
            let Some(mut job) = hub.sends.remove(&file_id) else {
                return;
            };
            let mut done = false;
            let outcome = match job.sender.on_ack(&ack) {
                Some(SendAction::Failed { reason }) => {
                    done = true;
                    Some(send_status(&job, Some(reason)))
                }
                Some(SendAction::Complete) => {
                    done = true;
                    Some(send_status(&job, None))
                }
                _ => match drain_sender(hub, &mut job) {
                    Some(status) => {
                        done = true;
                        Some(status)
                    }
                    None => {
                        hub.sends.insert(file_id.clone(), job);
                        None
                    }
                },
            };
            if let Some(status) = outcome {
                hub.push_finished(status);
            }
            // 该文件结束了 → 释放该 peer 的流式槽位，启动排队中的下一个。
            if done {
                complete_send(hub, &peer_id, &file_id);
            }
        }
        SessionEvent::FileDone { peer_id, done } => {
            let file_id = done.file_id.clone();
            // 先看我是不是该文件的接收方（对端发完请求校验）。
            let recv_meta_matches = hub.recvs.get(&peer_id).and_then(|job| {
                job.receiver.meta().map(|m| m.file_id.clone())
            }) == Some(file_id.clone());

            if recv_meta_matches {
                let Some(mut job) = hub.recvs.remove(&peer_id) else {
                    return;
                };
                match job.receiver.on_done(&done) {
                    Ok(reply) => {
                        let bytes = serde_json::to_vec(&reply).unwrap_or_default();
                        queue_frame(hub, &peer_id, FrameType::FileDone, bytes);
                        // B2：收全后由 Rust 直接落一条 kind=3 记录（带内容哈希）。
                        // 之前只靠 Dart appendMessage 写 UI 通知、不进 Rust 存储，
                        // 重启后查重闸查不到 → 离线补发同文件会落成 report(1).pdf。
                        if reply.ok {
                            if let Some(m) = job.receiver.meta() {
                                crate::api::chat::record_received_file(
                                    &peer_id,
                                    &m.file_id,
                                    &done.hash_hex,
                                    &m.name,
                                    m.size,
                                );
                            }
                        }
                        hub.push_finished(TransferStatusDto {
                            file_id,
                            peer_id,
                            name: job.name.clone(),
                            dir: TransferDir::Receive,
                            size: job.receiver.meta().map(|m| m.size).unwrap_or(0),
                            transferred: job.receiver.written(),
                            finished: true,
                            failed: !reply.ok,
                            cancelled: false,
                            error: reply.error,
                            paused: false,
                        });
                    }
                    Err(e) => {
                        let reply = FileDonePayload {
                            file_id: file_id.clone(),
                            hash_hex: done.hash_hex,
                            ok: false,
                            error: Some(format!("写入盘失败: {e}")),
                        };
                        queue_frame(
                            hub,
                            &peer_id,
                            FrameType::FileDone,
                            serde_json::to_vec(&reply).unwrap_or_default(),
                        );
                        hub.push_finished(TransferStatusDto {
                            file_id,
                            peer_id,
                            name: job.name.clone(),
                            dir: TransferDir::Receive,
                            size: job.receiver.meta().map(|m| m.size).unwrap_or(0),
                            transferred: job.receiver.written(),
                            finished: true,
                            failed: true,
                            cancelled: false,
                            error: Some(format!("写入盘失败: {e}")),
                            paused: false,
                        });
                    }
                }
                return;
            }
            // 我是发送方：这是完成回执。
            let Some(mut job) = hub.sends.remove(&file_id) else {
                return;
            };
            let mut finished = false;
            match job.sender.on_done(&done) {
                Some(SendAction::Complete) => {
                    hub.push_finished(send_status(&job, None));
                    finished = true;
                }
                Some(SendAction::Failed { reason }) => {
                    hub.push_finished(send_status(&job, Some(reason)));
                    finished = true;
                }
                _ => {
                    hub.sends.insert(file_id.clone(), job);
                }
            }
            if finished {
                complete_send(hub, &peer_id, &file_id);
            }
        }
        _ => {}
    }
    // 进度节流：≥100ms 才允许下一次快照刷新（查询路径无状态，这里只打点）
    if hub.last_progress_flush.elapsed() >= Duration::from_millis(100) {
        hub.last_progress_flush = Instant::now();
    }
}

/// 取消态的发送快照：**不是失败**（failed=false, cancelled=true）。
///
/// 对端收到它应当显示「已取消」，而不是「传输失败」——取消是用户主动
/// 意图，报错会让人误以为出了故障。
fn cancelled_send_status(job: &SendJob, reason: &str) -> TransferStatusDto {
    let (transferred, size) = job.sender.progress();
    TransferStatusDto {
        file_id: job.sender.file_id().to_string(),
        peer_id: job.peer_id.clone(),
        name: job.sender.meta().name.clone(),
        dir: TransferDir::Send,
        size,
        transferred,
        finished: true,
        failed: false,
        cancelled: true,
        error: Some(reason.to_string()),
        paused: false,
    }
}
fn send_status(job: &SendJob, error: Option<String>) -> TransferStatusDto {
    let (transferred, size) = job.sender.progress();
    TransferStatusDto {
        file_id: job.sender.file_id().to_string(),
        peer_id: job.peer_id.clone(),
        name: job.sender.meta().name.clone(),
        dir: TransferDir::Send,
        size,
        transferred,
        finished: true,
        failed: error.is_some(),
        cancelled: false,
        error,
        paused: job.sender.is_paused(),
    }
}

/// 发送方向的"可发就发"泵（meta → chunks → done）；IO 错误返回失败状态。
///
/// 关键：泵是在**持有 HUB_STATE 锁**下跑的，但 socket 写可能因 TCP 背压阻塞。
/// 之前不限量，一次把窗口（n = 2MB）全写出去，写阻塞期间
/// `transfer_status()` 拿不到锁 → 进度条整个冻住（用户反馈过
/// 「发送端进度条停滞」「发大文件卡卡的」）。限额后每轮很快放锁，
/// 后续块由 ACK 到达继续驱动（接收端每块都回 ACK，不会饿死）。
fn drain_sender(hub: &mut HubState, job: &mut SendJob) -> Option<TransferStatusDto> {
    // 单轮最多发几帧（局部常量，避免被 codegen 当成导出项）
    const MAX_FRAMES: usize = 2;
    let mut budget = MAX_FRAMES;
    loop {
        match job.sender.next_action() {
            Ok(SendAction::Frame { kind, payload }) => {
                // 只入队不写网：真正的 socket 写由锁外的 flush_pending 做。
                queue_frame(hub, &job.peer_id, kind, payload);
                budget = budget.saturating_sub(1);
                if budget == 0 {
                    return None; // 收工，等下一轮 ACK 继续驱动
                }
            }
            Ok(SendAction::Wait) => return None,
            // next_action 不返回 Complete/Failed（由 on_* 触发）；防御性退出。
            Ok(SendAction::Complete | SendAction::Failed { .. }) => return None,
            Err(e) => {
                return Some(send_status(job, Some(format!("IO 错误: {e}"))));
            }
        }
    }
}

/// 一个发送结束（完成/失败/取消）后的收尾：释放该 peer 的流式槽位，
/// 并启动同 peer 排队中的下一个文件。
/// 不这么做的话，第一个文件结束后后面的会永远停着 — 用户反馈过
/// 「新任务会导致旧传输停滞」双向都成立：新文件插队打断旧接收，
/// 旧文件结束后新文件又没人启动。
fn complete_send(hub: &mut HubState, peer_id: &str, file_id: &str) {
    if hub.active_send.get(peer_id).map(|s| s.as_str()) == Some(file_id) {
        hub.active_send.remove(peer_id);
    } else if !hub.sends.contains_key(file_id) {
        // 已经不在 sends 里且槽位不是它：说明已收到过清理。
    }

    // 找同 peer 下一个还没开流的任务（保持提交顺序）
    let mut candidates: Vec<(String, u64)> = hub
        .sends
        .iter()
        .filter(|(_, j)| j.peer_id == peer_id && !j.sender.has_started())
        .map(|(id, j)| (id.clone(), j.sender.progress().1))
        .collect();
    candidates.sort_by(|a, b| a.1.cmp(&b.1));
    let Some(next_id) = candidates.into_iter().next().map(|(id, _)| id) else {
        return;
    };

    hub.active_send.insert(peer_id.to_string(), next_id.clone());
    let Some(mut job) = hub.sends.remove(&next_id) else {
        return;
    };
    match drain_sender(hub, &mut job) {
        Some(status) => hub.push_finished(status),
        None => {
            hub.sends.insert(next_id, job);
        }
    }
}
/// 收件目录（数据目录/chat/downloads）。
fn receive_dir() -> PathBuf {
    crate::backend::storage::MessageStore::default_download_dir()
}

/// 把一帧排进待发队列（**绝不在锁内做 IO**，理由见 HubState.pending_sends）。
fn queue_ack(hub: &mut HubState, peer_id: &str, ack: &FileAckPayload) {
    if let Ok(bytes) = serde_json::to_vec(ack) {
        hub.pending_sends.push((peer_id.to_string(), FrameType::FileAck, bytes));
    }
}

fn queue_frame(hub: &mut HubState, peer_id: &str, kind: FrameType, payload: Vec<u8>) {
    hub.pending_sends.push((peer_id.to_string(), kind, payload));
}

/// 锁外统一发送：把队列里的帧真正写上网。
/// 必须在**释放 HUB_STATE 之后**调用 — socket 写可能阻塞，
/// 阻塞期间不能让 UI 线程拿不到锁。
fn flush_pending(frames: Vec<PendingFrame>) {
    for (peer_id, kind, payload) in frames {
        let _ = send_any_frame(&peer_id, kind, &payload);
    }
}

// ------------------------------------------------------------
// 桥接 API
// ------------------------------------------------------------

/// 发起发送：读文件、算哈希、注册进 hub、立刻开泵（分块 + 流控）。
///
/// peer 会话必须已建立（chatDial 或等对方连入）。
pub fn transfer_send(peer_id: String, path: String) -> anyhow::Result<TransferStatusDto> {
    start_hub()?;
    let file_path = PathBuf::from(&path);
    if !file_path.is_file() {
        bail!("文件不存在：{path}");
    }
    let file_id = uuid::Uuid::new_v4().to_string();
    let sender_id = crate::api::discovery::local_device_id();
    let sender_id = if sender_id.is_empty() {
        "unknown".to_string()
    } else {
        sender_id
    };
    let (sender, meta) = Sender::open(&file_path, file_id.clone(), sender_id)?;
    let name = meta.name.clone();
    let size = meta.size;

    let (result, pending) = {
        let mut guard = HUB_STATE
            .lock()
            .map_err(|_| anyhow!("传输服务未就绪"))?;
        let hub = guard
            .as_mut()
            .ok_or_else(|| anyhow!("传输服务未就绪"))?;

        hub.sends.insert(
            file_id.clone(),
            SendJob {
                sender,
                peer_id: peer_id.clone(),
            },
        );
        let mut job = hub.sends.remove(&file_id).expect("刚插入");
        let status = TransferStatusDto {
            file_id: file_id.clone(),
            peer_id: peer_id.clone(),
            name,
            dir: TransferDir::Send,
            size,
            transferred: job.sender.progress().0,
            finished: false,
            failed: false,
            cancelled: false,
            error: None,
            paused: job.sender.is_paused(),
        };
        // 同 peer 已有在途发送 → busy（排队等待）。
        let busy = hub.active_send.contains_key(&peer_id);
        // 同一 peer 已有文件在流式发送 → 排队等待，而不是立即开流。
        // 否则第二个 FILE_META 会把对端未完成的接收直接顶掉。
        let res = if busy {
            hub.sends.insert(file_id, job);
            Ok(status)
        } else if let Some(failed) = drain_sender(hub, &mut job) {
            hub.push_finished(failed.clone());
            Ok(failed)
        } else {
            hub.active_send.insert(peer_id.clone(), file_id.clone());
            hub.sends.insert(file_id, job);
            Ok(status)
        };
        // 锁内只入队；真正对 socket 的写放到锁外（经 HubState.pending_sends）。
        (res, std::mem::take(&mut hub.pending_sends))
    };
    flush_pending(pending);
    result
}

/// 传输进度列表（进行中 + 最近 32 条完成/失败）。UI 建议 2 Hz 拉取。
///
/// **不能用 #[frb(sync)]**：sync 会在 UI isolate 上同步执行，而本函数要拿
/// HUB_STATE；一旦 hub 线程持锁做 IO，UI 就整个冻住（用户反馈：
/// 「PC 端整个软件不响应」）。async 让它跑在 frb 工作线程上。
pub fn transfer_status() -> Vec<TransferStatusDto> {
    let Ok(mut guard) = HUB_STATE.lock() else {
        return Vec::new();
    };
    let Some(hub) = guard.as_mut() else {
        return Vec::new();
    };
    let mut out: Vec<TransferStatusDto> = hub
        .sends
        .iter()
        .map(|(file_id, job)| {
            let (transferred, size) = job.sender.progress();
            TransferStatusDto {
                file_id: file_id.clone(),
                peer_id: job.peer_id.clone(),
                name: job.sender.meta().name.clone(),
                dir: TransferDir::Send,
                size,
                transferred,
                finished: false,
                failed: job.sender.failed_reason().is_some(),
                cancelled: false,
                error: job.sender.failed_reason().map(|s| s.to_string()),
                paused: job.sender.is_paused(),
            }
        })
        .collect();
    out.extend(hub.recvs.iter().map(|(peer_id, job)| TransferStatusDto {
        file_id: job
            .receiver
            .meta()
            .map(|m| m.file_id.clone())
            .unwrap_or_default(),
        peer_id: peer_id.clone(),
        name: job.name.clone(),
        dir: TransferDir::Receive,
        size: job.receiver.meta().map(|m| m.size).unwrap_or(0),
        transferred: job.receiver.written(),
        finished: false,
        failed: false,
        cancelled: false,
        error: None,
        paused: false,
    }));
    out.extend(hub.recent.iter().cloned());
    out
}

/// 取消一个进行中的发送。
/// 取消是**双端语义**：除了删本地 job，还要给对端发 FILE_ABORT，
/// 否则对端一直等 chunk 到超时，.part 也一直挂着（用户反馈过
///「取消时双方没同步」）。锁：HUB_STATE（与 chat 状态是既有约定）。
pub fn transfer_cancel(file_id: String) -> bool {
    let work = |hub: &mut HubState| -> (bool, Vec<PendingFrame>) {
        if let Some(job) = hub.sends.remove(&file_id) {
            let peer_id = job.peer_id.clone();
            hub.push_finished(cancelled_send_status(&job, "已取消"));
            queue_abort(hub, &peer_id, &file_id, "已取消");
            // 取消也要释放槽位，否则同 peer 后续文件永远排队
            complete_send(hub, &peer_id, &file_id);
            (true, std::mem::take(&mut hub.pending_sends))
        } else {
            // 接收方向：双向取消——接收方也能主动放弃一个入站文件，
            // 并告知发送方停止继续传（否则它会一直把剩余块灌过来）。
            let recv_peer = hub
                .recvs
                .iter()
                .find(|(_, j)| {
                    j.receiver
                        .meta()
                        .map(|m| m.file_id == file_id)
                        .unwrap_or(false)
                })
                .map(|(p, _)| p.clone());
            match recv_peer {
                Some(peer_id) => {
                    if let Some(job) = hub.recvs.remove(&peer_id) {
                        let size = job.receiver.meta().map(|m| m.size).unwrap_or(0);
                        let written = job.receiver.written();
                        let mut job = job;
                        job.receiver.abort(); // 删掉半截 .part 与 sidecar
                        hub.push_finished(TransferStatusDto {
                            file_id: file_id.clone(),
                            peer_id: peer_id.clone(),
                            name: job.name.clone(),
                            dir: TransferDir::Receive,
                            size,
                            transferred: written,
                            finished: true,
                            failed: false,
                            cancelled: true,
                            error: Some("已取消".to_string()),
                            paused: false,
                        });
                        queue_abort(hub, &peer_id, &file_id, "已取消");
                    }
                    (true, std::mem::take(&mut hub.pending_sends))
                }
                None => (false, std::mem::take(&mut hub.pending_sends)),
            }
        }
    };
    let (ok, pending) = {
        let Ok(mut guard) = HUB_STATE.lock() else {
            return false;
        };
        match guard.as_mut() {
            Some(hub) => work(hub),
            None => (false, Vec::new()),
        }
    };
    flush_pending(pending);
    ok
}

/// 把一个 FILE_ABORT 排进待发队列（对端不在线也不影响本机操作）。
fn queue_abort(hub: &mut HubState, peer_id: &str, file_id: &str, reason: &str) {
    let payload = FileAbortPayload {
        file_id: file_id.to_string(),
        reason: Some(reason.to_string()),
    };
    if let Ok(bytes) = serde_json::to_vec(&payload) {
        queue_frame(hub, peer_id, FrameType::FileAbort, bytes);
    }
}

/// 暂停一个进行中的发送（纯发送侧：停产出 chunk，连接与在途块照常）。
pub fn transfer_pause(file_id: String) -> bool {
    let Ok(mut guard) = HUB_STATE.lock() else {
        return false;
    };
    let Some(hub) = guard.as_mut() else {
        return false;
    };
    match hub.sends.get_mut(&file_id) {
        Some(job) => {
            job.sender.set_paused(true);
            true
        }
        None => false,
    }
}

/// 继续一个已暂停的发送。
pub fn transfer_resume(file_id: String) -> bool {
    let work = |hub: &mut HubState| -> (bool, Vec<PendingFrame>) {
        // 先取出 job 再操作：drain_sender 也要 &mut hub，
        // 直接 get_mut 会撞双重可变借用
        let Some(mut job) = hub.sends.remove(&file_id) else {
            return (false, Vec::new());
        };
        job.sender.set_paused(false);
        // 立刻把暂停期间积压的窗口排出去，避免等下一轮事件
        let res = drain_sender(hub, &mut job);
        if let Some(status) = res {
            hub.push_finished(status);
        } else {
            hub.sends.insert(file_id.clone(), job);
        }
        (true, std::mem::take(&mut hub.pending_sends))
    };
    let (ok, pending) = {
        let Ok(mut guard) = HUB_STATE.lock() else {
            return false;
        };
        match guard.as_mut() {
            Some(hub) => work(hub),
            None => (false, Vec::new()),
        }
    };
    flush_pending(pending);
    ok
}

/// 对端重连后调用：把该 peer 所有未完成的发送重启（重发 FILE_META +
/// 已确认点续传），并重新驱动一轮。
///
/// 断线后 Sender 任务还留在 sends 里，但没有 ACK 进来就永远停着 ——
/// 之前没有任何东西会在重连后重新驱动它（用户反馈的「安卓后台中断后
/// 无法继续」）。返回被重启的任务数。
pub fn transfer_reconnect(peer_id: String) -> u32 {
    let (count, pending) = {
        let Ok(mut guard) = HUB_STATE.lock() else {
            return 0;
        };
        let Some(hub) = guard.as_mut() else {
            return 0;
        };

        // 同 peer 所有未完成的发送：重置到已确认点，重发 FILE_META
        let ids: Vec<String> = hub
            .sends
            .iter()
            .filter(|(_, j)| j.peer_id == peer_id && !j.sender.is_complete())
            .map(|(id, _)| id.clone())
            .collect();
        let mut restarted = 0u32;
        for id in &ids {
            if let Some(job) = hub.sends.get_mut(id) {
                job.sender.restart();
                restarted += 1;
            }
        }

        // 只启动其中一个（同 peer 串行），其余保持排队
        if let Some(first) = ids.first() {
            if let Some(mut job) = hub.sends.remove(first) {
                hub.active_send.insert(peer_id.clone(), first.clone());
                if let Some(status) = drain_sender(hub, &mut job) {
                    hub.push_finished(status);
                } else {
                    hub.sends.insert(first.clone(), job);
                }
            }
        }
        (restarted, std::mem::take(&mut hub.pending_sends))
    };
    flush_pending(pending);
    count
}
/// 接收目录（收件箱）。#[frb(sync)]
pub fn transfer_download_dir() -> String {
    receive_dir().to_string_lossy().to_string()
}

/// hub 是否存活（自检）。
/// 注意：frb 2.8.0 在本模块会忽略 #[frb(sync)]，因此保持 async。
pub fn transfer_hub_running() -> bool {
    HUB_ALIVE.load(Ordering::SeqCst)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::chat::lookup_received_hash;
    use crate::backend::protocol::FileMetaPayload;
    use crate::backend::transfer::Receiver;
    use std::time::Instant;

    /// 与 backend::transfer 测试同款的确定性样本：不用 rand，避免新依赖。
    fn sample(size: usize) -> Vec<u8> {
        (0..size).map(|i| (i % 251) as u8).collect()
    }

    /// 把样本写进测试目录，返回路径（算真实哈希用）。
    fn write_sample(dir: &std::path::Path, name: &str, bytes: &[u8]) -> std::path::PathBuf {
        let path = dir.join(name);
        std::fs::write(&path, bytes).expect("写样本文件应成功");
        path
    }

    #[test]
    fn download_dir_is_under_chat_or_temp() {
        let dir = receive_dir();
        let text = dir.to_string_lossy();
        assert!(!text.is_empty());
        assert!(text.contains("downloads") || text.contains("Temp"), "{text}");
    }

    #[test]
    fn status_empty_before_hub() {
        // 未 start_hub 时安全返回空（HUB_STATE 为 None）。
        if !HUB_ALIVE.load(Ordering::SeqCst) {
            assert!(transfer_status().is_empty());
        }
    }

    #[test]
    fn received_file_can_be_found_by_hash() {
        // 离线补发场景：同一个文件可能被发两次（第一次发到一半断了，第二次
        // 从发件箱补发）。若接收端不记得自己已经收全过，就会再落一份
        // 「xxx (1).pdf」——用户反馈的「文件冗余错乱」。
        // 判据是内容哈希 hash_hex，不是 file_id（file_id 每次发送都是新的 UUID）。
        let dir = std::env::temp_dir().join(format!(
            "lanchat_recv_hash_{}_{}",
            std::process::id(),
            Instant::now().elapsed().as_nanos()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let payload = sample(4096);
        let _ = crate::backend::storage::MessageStore::set_download_root(&dir);

        // 收完一个文件（走完整路径：meta → chunk → done），会落一条文件消息。
        // on_done 会整读重算哈希并与 meta.hash_hex 比对，所以这里必须用真哈希，
        // 不能用占位串（否则接收被判「哈希校验不一致」而不落盘）。
        let real_hash = crate::backend::transfer::hash_file(&write_sample(&dir, "src.bin", &payload))
            .expect("算哈希应成功");
        let meta = FileMetaPayload {
            file_id: "uuid-first-send".into(),
            sender_id: "peer-a".into(),
            name: "report.pdf".into(),
            size: payload.len() as u64,
            chunk_size: 1024,
            hash_hex: real_hash.clone(),
            resume_offset: 0,
        };
        let mut recv = Receiver::new(dir.clone());
        recv.on_meta(meta.clone()).expect("on_meta 应成功");
        for (i, chunk) in payload.chunks(1024).enumerate() {
            recv.on_chunk((i * 1024) as u64, chunk).expect("写块应成功");
        }
        let done = recv
            .on_done(&FileDonePayload {
                file_id: meta.file_id.clone(),
                hash_hex: meta.hash_hex.clone(),
                ok: true,
                error: None,
            })
            .expect("on_done 应成功");
        assert!(done.ok, "接收应成功：{:?}", done.error);
        let dest = dir.join("report.pdf");
        assert!(dest.exists(), "落盘文件应存在");

        // 把这条已收记录写进消息库（真实路径由 Dart 的 appendMessage 完成，
        // 不进 Rust 存储）。必须写进 messages_open 打开的那份 store，
        // 另开实例只写内存/自己的文件，lookup_received_hash 看不到。
        let msg = crate::backend::storage::StoredMessage {
            id: format!("file-{}", meta.file_id),
            peer_id: "peer-a".into(),
            seq: 0,
            from_me: false,
            kind: 3,
            text: String::new(),
            file_name: "report.pdf".into(),
            file_size: payload.len() as u64,
            ts_ms: 1_760_000_000_000,
            delivered: true,
            hash_hex: meta.hash_hex.clone(),
        };
        let dedup_dir = dir.join("chat");
        // 必须与发件箱测试互斥：`MESSAGES`/`OUTBOX` 都是进程级 static，
        // `messages_open` 会把两个 store 一起换掉。本测试在并行跑时，
        // 会让正在断言的发件箱测试读到别人的空箱（表现为「单跑通过、
        // 全量失败」）。产品代码不受影响（真机只 open 一次）。
        let _gate = crate::api::chat::messages_test_lock();
        let mut store = crate::backend::storage::MessageStore::open(&dedup_dir);
        store.append(msg).unwrap();
        // 真实顺序是「Dart 先 messagesOpen（打开消息根目录），之后 append 追加到
        // 已打开的实例里」。messages_open 会在根目录下再拼一层 chat，所以这里
        // 也是往 dir/chat 写，并在写完后重开一次模拟「重启后仍能查到」。
        let _ = crate::api::chat::messages_open(dir.to_string_lossy().to_string());

        // 对端补发：新 file_id（真实场景是新的 UUID），同一份 hash。
        assert_eq!(
            lookup_received_hash(&meta.hash_hex),
            Some("report.pdf".to_string()),
            "同一内容哈希必须能查到已收记录"
        );
        assert_eq!(
            lookup_received_hash("hash-never-received"),
            None,
            "没收到过的哈希不应误报"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 内容查重闸：已完整收过同 hash 的文件时，再来一份 FileMeta
    /// 必须直接回 FileDone(ok=true) 并不建 RecvJob（否则磁盘上会多一份
    /// report(1).pdf，且对端会一直以为没送到而反复补发）。
    #[test]
    fn duplicate_file_meta_is_acked_and_not_received() {
        let dir = temp_dir_for("dedup_gate");
        let _gate = crate::api::chat::messages_test_lock();
        let _ = crate::api::chat::messages_open(dir.to_string_lossy().to_string());

        // 造一条「已收过 report.pdf」的记录。必须写进 messages_open 打开的那份
        // store（全局 MESSAGES）—— 另开一个 MessageStore 实例只写内存/自己的文件，
        // lookup_received_hash 看不到。
        let payload = sample(2048);
        let src = write_sample(&dir, "src.bin", &payload);
        let real_hash = crate::backend::transfer::hash_file(&src).expect("算哈希应成功");
        let stored = crate::backend::storage::StoredMessage {
            id: "file-uuid-original".into(),
            peer_id: "peer-a".into(),
            seq: 0,
            from_me: false,
            kind: 3,
            text: String::new(),
            file_name: "report.pdf".into(),
            file_size: payload.len() as u64,
            ts_ms: 1_760_000_000_000,
            delivered: true,
            hash_hex: real_hash.clone(),
        };
        crate::backend::storage::MessageStore::open(dir.join("chat"))
            .append(stored)
            .unwrap();
        // 重新打开，让全局 store 从磁盘载入刚写的记录
        let _ = crate::api::chat::messages_open(dir.to_string_lossy().to_string());
        assert_eq!(
            crate::api::chat::lookup_received_hash(&real_hash),
            Some("report.pdf".to_string()),
            "测试前置：消息库必须能查到这条记录（否则本测试测的是空气）"
        );

        // 对端补发：同内容、新 file_id（真实场景是新的 UUID）。
        let mut hub = HubState::default();
        handle_event(
            &mut hub,
            SessionEvent::FileMeta {
                peer_id: "peer-a".into(),
                meta: FileMetaPayload {
                    file_id: "uuid-resend".into(),
                    sender_id: "peer-a".into(),
                    name: "report.pdf".into(),
                    size: payload.len() as u64,
                    chunk_size: 1024,
                    hash_hex: real_hash.clone(),
                    resume_offset: 0,
                },
            },
        );

        assert!(
            hub.recvs.is_empty(),
            "已收过的文件不应再建接收任务（否则会有残留 .part 或冗余副本）"
        );
        assert_eq!(hub.pending_sends.len(), 1, "应回一帧 FileDone");
        let (peer, kind, bytes) = &hub.pending_sends[0];
        assert_eq!(peer, "peer-a");
        assert_eq!(*kind, FrameType::FileDone);
        let reply: FileDonePayload = serde_json::from_slice(bytes).expect("回执应能解析");
        assert!(reply.ok, "去重回执必须 ok=true，否则对端会一直重发");
        assert_eq!(reply.file_id, "uuid-resend", "回执要带对端这次的 file_id");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 半截接收不能算「已收」：只有 .part 残留时必须照常走续传，
    /// 否则用户会拿到一个永远补不上的文件。
    #[test]
    fn half_received_file_is_not_treated_as_duplicate() {
        let dir = temp_dir_for("dedup_half");
        let _gate = crate::api::chat::messages_test_lock();
        let _ = crate::api::chat::messages_open(dir.to_string_lossy().to_string());

        let payload = sample(4096);
        let src = write_sample(&dir, "src.bin", &payload);
        let real_hash = crate::backend::transfer::hash_file(&src).expect("算哈希应成功");

        // 收件目录：<目录>/downloads（见 MessageStore::default_download_dir），
        // 不是根目录本身 —— handle_event 走的 receive_dir() 也从这里取。
        // 只用 1024 字节落盘就断（有 .part + sidecar，但没有消息库记录）。
        let recv_dir = crate::backend::storage::MessageStore::default_download_dir();
        std::fs::create_dir_all(&recv_dir).unwrap();
        let mut recv = Receiver::new(recv_dir.clone());
        recv.on_meta(FileMetaPayload {
            file_id: "uuid-half".into(),
            sender_id: "peer-a".into(),
            name: "half.bin".into(),
            size: payload.len() as u64,
            chunk_size: 1024,
            hash_hex: real_hash.clone(),
            resume_offset: 0,
        })
        .expect("on_meta 应成功");
        recv.on_chunk(0, &payload[..1024]).expect("写块应成功");
        drop(recv);

        let mut hub = HubState::default();
        handle_event(
            &mut hub,
            SessionEvent::FileMeta {
                peer_id: "peer-a".into(),
                meta: FileMetaPayload {
                    file_id: "uuid-half-resend".into(),
                    sender_id: "peer-a".into(),
                    name: "half.bin".into(),
                    size: payload.len() as u64,
                    chunk_size: 1024,
                    hash_hex: real_hash.clone(),
                    resume_offset: 0,
                },
            },
        );

        assert_eq!(hub.recvs.len(), 1, "半截文件必须正常建立接收任务");
        let (_, kind, bytes) = &hub.pending_sends[0];
        assert_eq!(*kind, FrameType::FileAck);
        let ack: FileAckPayload = serde_json::from_slice(bytes).expect("ACK 应能解析");
        assert_eq!(ack.offset, 1024, "应从断点续传而不是从头来");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// B2（审查 C2）：收全文件后 Rust 必须自己落一条带 hash_hex 的记录。
    /// 之前只靠 Dart appendMessage（不进 Rust 存储），重启后查重闸查不到：
    /// 离线补发同内容文件会落成 report(1).pdf。走真实 handle_event 路径：
    /// FileMeta → FileChunk → FileDone，随后重开 messages_open 模拟新进程，
    /// 断言 lookup_received_hash 能查到。
    #[test]
    fn received_file_is_recorded_with_hash_by_rust() {
        let dir = temp_dir_for("dedup_record");
        let _gate = crate::api::chat::messages_test_lock();
        let _ = crate::api::chat::messages_open(dir.to_string_lossy().to_string());

        let payload = sample(4096);
        let src = write_sample(&dir, "src.bin", &payload);
        let real_hash = crate::backend::transfer::hash_file(&src).expect("算哈希应成功");

        let mut hub = HubState::default();
        handle_event(
            &mut hub,
            SessionEvent::FileMeta {
                peer_id: "peer-a".into(),
                meta: FileMetaPayload {
                    file_id: "uuid-record".into(),
                    sender_id: "peer-a".into(),
                    name: "record.pdf".into(),
                    size: payload.len() as u64,
                    chunk_size: 1024,
                    hash_hex: real_hash.clone(),
                    resume_offset: 0,
                },
            },
        );
        for (i, chunk) in payload.chunks(1024).enumerate() {
            handle_event(
                &mut hub,
                SessionEvent::FileChunk {
                    peer_id: "peer-a".into(),
                    offset: (i * 1024) as u64,
                    data: chunk.to_vec(),
                },
            );
        }
        handle_event(
            &mut hub,
            SessionEvent::FileDone {
                peer_id: "peer-a".into(),
                done: FileDonePayload {
                    file_id: "uuid-record".into(),
                    hash_hex: real_hash.clone(),
                    ok: true,
                    error: None,
                },
            },
        );

        // 模拟进程重启：从磁盘重开消息库，记录必须还在
        let _ = crate::api::chat::messages_open(dir.to_string_lossy().to_string());
        assert_eq!(
            crate::api::chat::lookup_received_hash(&real_hash),
            Some("record.pdf".to_string()),
            "收全文件后 Rust 必须落库 hash_hex（重启后查重闸才放不了重复文件）"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 独立 temp 目录（带 pid，避免并行测试互踩）。
    fn temp_dir_for(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "lanchat_xfer_api_{}_{}",
            tag,
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::create_dir_all(&dir);
        dir
    }
}
