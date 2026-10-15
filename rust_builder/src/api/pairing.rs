//! T2.1 / T2.2 桥接：PIN 配对状态机 + 配对表（联系人）持久化。
//!
//! 状态机是纯逻辑（backend::pairing），这里只做三件事：
//! 1) 把 Dart 的事件（收到请求 / 用户确认 / 超时 tick）转成状态机输入；
//! 2) 把状态机输出的动作翻译成 DTO（要发的帧、要落的联系人）；
//! 3) 维护全局会话与配对表句柄。
//!
//! 传输层（M3 TCP 会话）到位后，只需把 send_request / send_response 真正发出去，
//! 并且在收到帧时调用 pairing_receive_request / pairing_response_received。

use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, bail};
use flutter_rust_bridge::frb;

use crate::backend::pairing::{
    self, PairAction, PairFailure, PairInput, PairRole, PairState, PairingMachine, PAIR_TIMEOUT_MS,
};
use crate::backend::storage::{PairedDevice, PairingStore};

// ------------------------------------------------------------
// 全局句柄
// ------------------------------------------------------------

static STORE: Mutex<Option<PairingStore>> = Mutex::new(None);
static MACHINE: Mutex<Option<PairingMachine>> = Mutex::new(None);
/// 对端平台（PAIR_REQ 里不带，M3 从邻居表拿；本机联调时由 Dart 传入）。
static PEER_PLATFORM: Mutex<Option<String>> = Mutex::new(None);
/// 对端当前地址，配对成功后写进联系人地址历史（M3 建连直接用）。
static PEER_ADDR: Mutex<Option<String>> = Mutex::new(None);

/// 当前墙钟毫秒（配对倒计时/落库时间戳都用它，跨进程可读）。
fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

// ------------------------------------------------------------
// DTO
// ------------------------------------------------------------

/// 一条已配对联系人。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairedContactDto {
    pub device_id: String,
    pub name: String,
    pub platform: String,
    /// 地址候选（最新在前），M3 建连按序尝试。
    pub addr_history: Vec<String>,
    pub paired_at_ms: i64,
    pub last_seen_ms: i64,
}

impl From<&PairedDevice> for PairedContactDto {
    fn from(c: &PairedDevice) -> Self {
        Self {
            device_id: c.device_id.clone(),
            name: c.name.clone(),
            platform: c.platform.clone(),
            addr_history: c.addr_history.clone(),
            paired_at_ms: c.paired_at_ms,
            last_seen_ms: c.last_seen_ms,
        }
    }
}

/// 配对表状态（设置页 / 自检展示）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairingStatusDto {
    pub store_path: String,
    pub contact_count: i32,
    /// 上次打开时发现文件损坏并已留档（数据不会静默丢）。
    pub recovered_from_corruption: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PairRoleDto {
    Initiator,
    Responder,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PairStateDto {
    Idle,
    /// 我方发起，等对端 PAIR_RESP（PIN 已显示）
    WaitingResponse,
    /// 收到请求，等用户对照 PIN 后确认
    AwaitingConfirm,
    Paired,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PairFailureDto {
    Timeout,
    Rejected,
    InvalidPin,
    Busy,
    Cancelled,
}

/// 会话快照（UI 用）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairSessionDto {
    pub role: PairRoleDto,
    pub state: PairStateDto,
    pub failure: Option<PairFailureDto>,
    /// 需要大字显示的 6 位 PIN。
    pub pin: Option<String>,
    pub peer_id: Option<String>,
    /// 剩余毫秒（无会话 = 0）。
    pub remaining_ms: u32,
    pub attempts: u32,
}

/// 要发给对端的 PAIR_REQ（M3 传输层负责真正发送）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairRequestDto {
    pub device_id: String,
    pub pin: String,
    pub ts_ms: i64,
}

/// 要回给对端的 PAIR_RESP。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairResponseDto {
    pub accepted: bool,
    pub reason: Option<String>,
}

/// 一次状态机推进的结果：会话快照 + 需要执行的动作。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairOutcomeDto {
    pub session: PairSessionDto,
    pub send_request: Option<PairRequestDto>,
    pub send_response: Option<PairResponseDto>,
    /// 本次推进写入/更新的联系人（配对成功时非空）。
    pub contact: Option<PairedContactDto>,
}

// ------------------------------------------------------------
// 转换
// ------------------------------------------------------------

fn role_dto(role: PairRole) -> PairRoleDto {
    match role {
        PairRole::Initiator => PairRoleDto::Initiator,
        PairRole::Responder => PairRoleDto::Responder,
    }
}

fn failure_dto(reason: PairFailure) -> PairFailureDto {
    match reason {
        PairFailure::Timeout => PairFailureDto::Timeout,
        PairFailure::Rejected => PairFailureDto::Rejected,
        PairFailure::InvalidPin => PairFailureDto::InvalidPin,
        PairFailure::Busy => PairFailureDto::Busy,
        PairFailure::Cancelled => PairFailureDto::Cancelled,
    }
}

fn state_dto(state: &PairState) -> (PairStateDto, Option<PairFailureDto>, Option<String>) {
    match state {
        PairState::Idle => (PairStateDto::Idle, None, None),
        PairState::WaitingResponse { pin, .. } => {
            (PairStateDto::WaitingResponse, None, Some(pin.clone()))
        }
        PairState::AwaitingConfirm { pin, .. } => {
            (PairStateDto::AwaitingConfirm, None, Some(pin.clone()))
        }
        PairState::Paired { .. } => (PairStateDto::Paired, None, None),
        PairState::Failed { reason } => (PairStateDto::Failed, Some(failure_dto(*reason)), None),
    }
}

fn session_dto(machine: &PairingMachine, now: u64) -> PairSessionDto {
    let (state, failure, pin) = state_dto(machine.state());
    PairSessionDto {
        role: role_dto(machine.role()),
        state,
        failure,
        pin,
        peer_id: machine.peer_id().map(|s| s.to_string()),
        remaining_ms: machine.remaining_ms(now).min(u32::MAX as u64) as u32,
        attempts: machine.attempts(),
    }
}

// ------------------------------------------------------------
// 配对表（T2.2）
// ------------------------------------------------------------

/// 打开配对表（Dart 传入应用数据目录，例如 %APPDATA%/LanChat 或 Android filesDir）。
pub fn pairing_open(data_dir: String) -> anyhow::Result<PairingStatusDto> {
    if data_dir.trim().is_empty() {
        bail!("data_dir 不能为空");
    }
    let path = PathBuf::from(data_dir).join("contacts.json");
    let store = PairingStore::open(path);
    let status = PairingStatusDto {
        store_path: store.path().to_string_lossy().to_string(),
        contact_count: store.len() as i32,
        recovered_from_corruption: store.recovered_from_corruption(),
    };
    *STORE.lock().map_err(|_| anyhow!("store poisoned"))? = Some(store);
    Ok(status)
}

fn with_store<T>(f: impl FnOnce(&mut PairingStore) -> anyhow::Result<T>) -> anyhow::Result<T> {
    let mut guard = STORE.lock().map_err(|_| anyhow!("store poisoned"))?;
    let store = guard
        .as_mut()
        .ok_or_else(|| anyhow!("配对表未打开，请先 pairingOpen()"))?;
    f(store)
}

/// 配对表状态。
#[frb(sync)]
pub fn pairing_status() -> PairingStatusDto {
    match STORE.lock() {
        Ok(guard) => match guard.as_ref() {
            Some(store) => PairingStatusDto {
                store_path: store.path().to_string_lossy().to_string(),
                contact_count: store.len() as i32,
                recovered_from_corruption: store.recovered_from_corruption(),
            },
            None => PairingStatusDto {
                store_path: String::new(),
                contact_count: 0,
                recovered_from_corruption: false,
            },
        },
        Err(_) => PairingStatusDto {
            store_path: String::new(),
            contact_count: 0,
            recovered_from_corruption: false,
        },
    }
}

/// 全部联系人（按配对时间倒序，最近配对的在前）。
#[frb(sync)]
pub fn pairing_contacts() -> Vec<PairedContactDto> {
    let mut list: Vec<PairedContactDto> = STORE
        .lock()
        .ok()
        .and_then(|guard| {
            guard
                .as_ref()
                .map(|s| s.list().iter().map(PairedContactDto::from).collect())
        })
        .unwrap_or_default();
    list.sort_by(|a, b| b.paired_at_ms.cmp(&a.paired_at_ms));
    list
}

#[frb(sync)]
pub fn pairing_is_paired(device_id: String) -> bool {
    STORE
        .lock()
        .ok()
        .and_then(|guard| guard.as_ref().map(|s| s.is_paired(&device_id)))
        .unwrap_or(false)
}

/// 写入/更新一个联系人（配对成功时调用；M3 也会由状态机的 PersistContact 动作触发）。
pub fn pairing_confirm_local(
    device_id: String,
    name: String,
    platform: String,
    addr: Option<String>,
) -> anyhow::Result<PairedContactDto> {
    if device_id.trim().is_empty() {
        bail!("device_id 不能为空");
    }
    let ts = now_ms() as i64;
    let entry = PairedDevice::new(device_id, name, platform, addr, ts);
    with_store(|store| {
        store.upsert(entry.clone())?;
        Ok(store
            .get(&entry.device_id)
            .map(PairedContactDto::from)
            .unwrap_or_else(|| PairedContactDto::from(&entry)))
    })
}

/// 删除联系人。
pub fn pairing_remove(device_id: String) -> anyhow::Result<bool> {
    with_store(|store| Ok(store.remove(&device_id)?))
}

/// 发现到已配对设备时刷新地址历史。
pub fn pairing_touch_addr(device_id: String, addr: String) -> anyhow::Result<bool> {
    let ts = now_ms() as i64;
    with_store(|store| Ok(store.touch_addr(&device_id, &addr, ts)?))
}

// ------------------------------------------------------------
// 配对会话（T2.1）
// ------------------------------------------------------------

/// 发起配对：生成 6 位 PIN 并给出要发的 PAIR_REQ。已在配对表里则幂等成功。
pub fn pairing_start(
    peer_id: String,
    peer_name: String,
    peer_platform: String,
    peer_addr: Option<String>,
) -> PairOutcomeDto {
    *PEER_PLATFORM.lock().unwrap_or_else(|e| e.into_inner()) = Some(peer_platform);
    *PEER_ADDR.lock().unwrap_or_else(|e| e.into_inner()) = peer_addr;
    let already_paired = pairing_is_paired(peer_id.clone());
    let mut machine = PairingMachine::with_peer(peer_id, peer_name);
    let now = now_ms();
    let actions = machine.handle(PairInput::Start {
        already_paired,
        ts_ms: now,
    });
    let outcome = finish(machine, actions, now);
    *MACHINE.lock().unwrap_or_else(|e| e.into_inner()) = Some(outcome.0);
    outcome.1
}

/// 收到对端 PAIR_REQ：显示 PIN，等用户确认。
pub fn pairing_receive_request(
    peer_id: String,
    peer_name: String,
    peer_platform: String,
    pin: String,
    peer_addr: Option<String>,
) -> PairOutcomeDto {
    *PEER_PLATFORM.lock().unwrap_or_else(|e| e.into_inner()) = Some(peer_platform);
    *PEER_ADDR.lock().unwrap_or_else(|e| e.into_inner()) = peer_addr;
    let mut guard = MACHINE.lock().unwrap_or_else(|e| e.into_inner());
    let mut machine = guard.take().unwrap_or_default();
    let now = now_ms();
    let actions = machine.handle(PairInput::RequestReceived {
        device_id: peer_id,
        name: peer_name,
        pin,
        ts_ms: now,
    });
    drop(guard);
    let outcome = finish(machine, actions, now);
    *MACHINE.lock().unwrap_or_else(|e| e.into_inner()) = Some(outcome.0);
    outcome.1
}

/// 用户对照 PIN 一致后点「确认配对」。
pub fn pairing_confirm() -> anyhow::Result<PairOutcomeDto> {
    advance(|m| m.handle(PairInput::UserConfirmed { ts_ms: now_ms() }))
}

/// 用户点「取消」/ PIN 不一致。
pub fn pairing_reject() -> anyhow::Result<PairOutcomeDto> {
    advance(|m| m.handle(PairInput::UserRejected { ts_ms: now_ms() }))
}

/// 收到 PAIR_RESP（M3 传输层调用）。
pub fn pairing_response_received(accepted: bool) -> anyhow::Result<PairOutcomeDto> {
    advance(|m| {
        m.handle(PairInput::ResponseReceived {
            accepted,
            ts_ms: now_ms(),
        })
    })
}

/// 主动取消。
pub fn pairing_cancel() -> anyhow::Result<PairOutcomeDto> {
    advance(|m| m.handle(PairInput::Cancel { ts_ms: now_ms() }))
}

/// 时间推进：UI 的 60s 倒计时到点后调用，触发超时失败。
pub fn pairing_tick() -> anyhow::Result<PairOutcomeDto> {
    advance(|m| m.handle(PairInput::Tick { now_ms: now_ms() }))
}

/// 当前会话快照（没有会话返回 None）。
#[frb(sync)]
pub fn pairing_session() -> Option<PairSessionDto> {
    let now = now_ms();
    MACHINE
        .lock()
        .ok()
        .and_then(|guard| guard.as_ref().map(|m| session_dto(m, now)))
}

/// 清掉会话（保留联系人）。
pub fn pairing_reset() {
    *MACHINE.lock().unwrap_or_else(|e| e.into_inner()) = None;
}

fn advance(f: impl FnOnce(&mut PairingMachine) -> Vec<PairAction>) -> anyhow::Result<PairOutcomeDto> {
    let mut guard = MACHINE.lock().map_err(|_| anyhow!("machine poisoned"))?;
    let machine = guard
        .as_mut()
        .ok_or_else(|| anyhow!("没有进行中的配对会话"))?;
    let now = now_ms();
    let actions = f(machine);
    drop(guard);
    let (machine, outcome) = finish_take(actions, now);
    *MACHINE.lock().map_err(|_| anyhow!("machine poisoned"))? = Some(machine);
    Ok(outcome)
}

/// 执行动作 → 返回 (会话快照, 待发送 DTO, 落库后的联系人)。
/// 用「同一时刻」计算整份结果：否则 remaining_ms 会因为几毫秒流逝而不等于超时常量。
fn finish(
    machine: PairingMachine,
    actions: Vec<PairAction>,
    now: u64,
) -> (PairingMachine, PairOutcomeDto) {
    let outcome = apply_actions(&machine, actions, now);
    (machine, outcome)
}

fn finish_take(actions: Vec<PairAction>, now: u64) -> (PairingMachine, PairOutcomeDto) {
    let mut guard = MACHINE.lock().unwrap_or_else(|e| e.into_inner());
    let machine = guard.take().unwrap_or_default();
    drop(guard);
    let outcome = apply_actions(&machine, actions, now);
    (machine, outcome)
}

fn apply_actions(
    machine: &PairingMachine,
    actions: Vec<PairAction>,
    now: u64,
) -> PairOutcomeDto {
    let mut send_request = None;
    let mut send_response = None;
    let mut contact = None;

    for action in actions {
        match action {
            PairAction::SendRequest { payload } => {
                send_request = Some(PairRequestDto {
                    device_id: payload.device_id,
                    pin: payload.pin,
                    ts_ms: payload.ts_ms.min(i64::MAX as u64) as i64,
                });
            }
            PairAction::SendResponse { payload } => {
                send_response = Some(PairResponseDto {
                    accepted: payload.accepted,
                    reason: payload.reason,
                });
            }
            PairAction::PersistContact {
                device_id,
                name,
                at_ms,
            } => {
                let platform = PEER_PLATFORM
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .clone()
                    .unwrap_or_default();
                let addr = PEER_ADDR
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .clone();
                let entry = PairedDevice::new(device_id, name, platform, addr, at_ms as i64);
                if let Ok(mut guard) = STORE.lock() {
                    if let Some(store) = guard.as_mut() {
                        // 落盘失败只影响持久化，配对结果仍返回给 UI（由 UI 提示）
                        let _ = store.upsert(entry.clone());
                        contact = store.get(&entry.device_id).map(PairedContactDto::from);
                    }
                }
                if contact.is_none() {
                    contact = Some(PairedContactDto::from(&entry));
                }
            }
            PairAction::ShowPin { .. }
            | PairAction::Paired { .. }
            | PairAction::Failed { .. }
            | PairAction::Cancelled => {}
        }
    }

    PairOutcomeDto {
        session: session_dto(machine, now),
        send_request,
        send_response,
        contact,
    }
}

/// 配对超时常量（UI 倒计时初值；Dart 侧不用自己写 60s）。
#[frb(sync)]
pub fn pairing_timeout_ms() -> u32 {
    PAIR_TIMEOUT_MS as u32
}

/// 校验一个字符串是否可作为 PIN（UI 输入校验）。
#[frb(sync)]
pub fn pairing_is_valid_pin(pin: String) -> bool {
    pairing::is_valid_pin(&pin)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 这些测试都在操作全局 STORE / MACHINE，必须串行执行 ——
    /// 并行跑时它们会互相把对方的配对表换掉（曾导致「配对成功却没落库」的假失败）。
    static GLOBAL_STATE_TEST_LOCK: Mutex<()> = Mutex::new(());

    fn temp_dir(tag: &str) -> String {
        let dir = std::env::temp_dir().join(format!(
            "lanchat_api_pairing_{}_{}",
            tag,
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        dir.to_string_lossy().to_string()
    }

    #[test]
    fn state_dto_maps_every_state() {
        let (s, f, pin) = state_dto(&PairState::Idle);
        assert_eq!((s, f, pin), (PairStateDto::Idle, None, None));

        let (s, _, pin) = state_dto(&PairState::WaitingResponse {
            pin: "123456".into(),
            started_ms: 0,
        });
        assert_eq!(s, PairStateDto::WaitingResponse);
        assert_eq!(pin.as_deref(), Some("123456"));

        let (s, _, pin) = state_dto(&PairState::AwaitingConfirm {
            pin: "654321".into(),
            started_ms: 0,
        });
        assert_eq!(s, PairStateDto::AwaitingConfirm);
        assert_eq!(pin.as_deref(), Some("654321"));

        let (s, _, _) = state_dto(&PairState::Paired {
            device_id: "dev-a".into(),
        });
        assert_eq!(s, PairStateDto::Paired);

        let (s, f, _) = state_dto(&PairState::Failed {
            reason: PairFailure::Timeout,
        });
        assert_eq!(s, PairStateDto::Failed);
        assert_eq!(f, Some(PairFailureDto::Timeout));
        assert_eq!(failure_dto(PairFailure::Busy), PairFailureDto::Busy);
        assert_eq!(role_dto(PairRole::Responder), PairRoleDto::Responder);
        assert_eq!(role_dto(PairRole::Initiator), PairRoleDto::Initiator);
    }

    #[test]
    fn contact_dto_roundtrips() {
        let entry = PairedDevice::new(
            "dev-a",
            "Pixel 7",
            "android",
            Some("192.168.1.41".into()),
            1_760_000_000_000,
        );
        let dto = PairedContactDto::from(&entry);
        assert_eq!(dto.device_id, "dev-a");
        assert_eq!(dto.addr_history, ["192.168.1.41"]);
        assert_eq!(dto.paired_at_ms, 1_760_000_000_000);
    }

    #[test]
    fn pin_validation_helper() {
        assert!(pairing_is_valid_pin("123456".into()));
        assert!(!pairing_is_valid_pin("12345".into()));
        assert_eq!(pairing_timeout_ms(), 60_000);
    }

    /// 走一遍真实存储（全局句柄，单个测试内串行完成，避免测试间互相踩）。
    #[test]
    fn store_api_persists_contacts_across_reopen() {
        let _guard = GLOBAL_STATE_TEST_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let dir = temp_dir("store");
        let status = pairing_open(dir.clone()).unwrap();
        assert_eq!(status.contact_count, 0);
        assert!(!status.recovered_from_corruption);

        let saved = pairing_confirm_local(
            "dev-b".into(),
            "Pixel 7".into(),
            "android".into(),
            Some("192.168.1.41".into()),
        )
        .unwrap();
        assert_eq!(saved.name, "Pixel 7");
        assert!(pairing_is_paired("dev-b".into()));
        assert_eq!(pairing_contacts().len(), 1);

        // 模拟重启：重新打开同一个目录
        let reopened = pairing_open(dir.clone()).unwrap();
        assert_eq!(reopened.contact_count, 1, "重启后联系人必须还在");
        assert!(reopened.store_path.ends_with("contacts.json"));

        assert!(pairing_touch_addr("dev-b".into(), "192.168.1.99".into()).unwrap());
        let contacts = pairing_contacts();
        assert_eq!(contacts[0].addr_history[0], "192.168.1.99");

        assert!(pairing_remove("dev-b".into()).unwrap());
        assert!(!pairing_is_paired("dev-b".into()));
        assert_eq!(pairing_open(dir).unwrap().contact_count, 0);
    }

    #[test]
    fn pairing_open_rejects_empty_dir() {
        assert!(pairing_open("   ".into()).is_err());
    }

    /// 状态机推进：发起方本地走一遍（无传输层），确认会落库联系人。
    #[test]
    fn local_initiator_flow_persists_on_response() {
        let _guard = GLOBAL_STATE_TEST_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let dir = temp_dir("machine");
        pairing_open(dir).unwrap();
        pairing_reset();

        let outcome = pairing_start(
            "dev-z".into(),
            "Laptop".into(),
            "windows".into(),
            Some("192.168.1.66".into()),
        );
        assert_eq!(outcome.session.state, PairStateDto::WaitingResponse);
        let pin = outcome.session.pin.clone().expect("应显示 PIN");
        assert!(pairing::is_valid_pin(&pin));
        let req = outcome.send_request.expect("应产出 PAIR_REQ");
        assert_eq!(req.device_id, "dev-z");
        assert_eq!(req.pin, pin);
        assert_eq!(outcome.session.remaining_ms, pairing_timeout_ms());

        // 模拟收到 accept
        let done = pairing_response_received(true).unwrap();
        assert_eq!(done.session.state, PairStateDto::Paired);
        let contact = done.contact.expect("配对成功应写入联系人");
        assert_eq!(contact.device_id, "dev-z");
        assert_eq!(contact.platform, "windows");
        assert_eq!(contact.addr_history, ["192.168.1.66"], "配对成功后应记下对端地址");
        assert!(pairing_is_paired("dev-z".into()));
        pairing_remove("dev-z".into()).unwrap();
    }
}
