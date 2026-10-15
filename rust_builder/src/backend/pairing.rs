//! 握手与 PIN 配对状态机（T2.1；PLAN §3.3、风险14 v1 明文，v2 加密入队 T6.5）。
//!
//! 设计：**纯状态机**，不碰 socket 也不碰文件 —— 输入 [`PairInput`]（网络事件 / 用户
//! 操作 / 超时 tick），输出 [`PairAction`]（要发的帧、要显示的 PIN、要写入配对表的
//! 联系人）。这样 M3 的 TCP 会话层只要把收到的帧转成输入、把动作转成发送即可，
//! 而状态机本身可以在没有任何网络的情况下把超时 / 拒绝 / 重复配对全部测掉。
//!
//! 规则（PLAN §3.3 + TASKS T2.1）
//! - 发起方：生成 6 位 PIN → 显示 + 发 PAIR_REQ → 等 PAIR_RESP，60s 超时
//! - 应答方：收到 PAIR_REQ → 显示同一个 PIN → 用户对照后确认/拒绝 → 回 PAIR_RESP
//! - 失败（超时 / 拒绝 / PIN 非法）后可重试；已配对设备重复配对直接成功（幂等）
//! - 一方已在配对会话中又收到对方的 PAIR_REQ → 回 Busy，不打乱当前会话

use super::protocol::{PairReqPayload, PairRespPayload};

/// 配对会话超时（PLAN §3.3：60s 倒计时）。
pub const PAIR_TIMEOUT_MS: u64 = 60_000;

/// 配对表里名字的兜底长度（防止对端塞超长名字）。
pub const MAX_NAME_LEN: usize = 64;

/// 本机在配对里的角色。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PairRole {
    Initiator,
    Responder,
}

/// 状态机的状态。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PairState {
    Idle,
    /// 已发起，等待 PAIR_RESP（PIN 已显示）。
    WaitingResponse { pin: String, started_ms: u64 },
    /// 收到对端请求，等待本机用户对照 PIN 后确认。
    AwaitingConfirm { pin: String, started_ms: u64 },
    /// 配对完成（联系人已写入配对表）。
    Paired { device_id: String },
    /// 失败，可重试。
    Failed { reason: PairFailure },
}

impl PairState {
    pub fn is_terminal(&self) -> bool {
        matches!(self, Self::Paired { .. } | Self::Failed { .. })
    }

    pub fn pin(&self) -> Option<&str> {
        match self {
            Self::WaitingResponse { pin, .. } | Self::AwaitingConfirm { pin, .. } => Some(pin),
            _ => None,
        }
    }
}

/// 失败原因（UI 据此给不同文案）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PairFailure {
    /// 60s 内没有完成。
    Timeout,
    /// 对端拒绝或用户拒绝。
    Rejected,
    /// PIN 不是 6 位数字。
    InvalidPin,
    /// 对方/我方已有一个进行中的配对会话。
    Busy,
    /// 发起方或用户主动取消。
    Cancelled,
}

impl PairFailure {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Timeout => "timeout",
            Self::Rejected => "rejected",
            Self::InvalidPin => "invalid pin",
            Self::Busy => "busy",
            Self::Cancelled => "cancelled",
        }
    }
}

/// 状态机输入：网络事件、用户操作、超时推进。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PairInput {
    /// 发起配对；already_paired=true 表示这台设备已在配对表里（幂等直接成功）。
    Start { already_paired: bool, ts_ms: u64 },
    /// 收到对端 PAIR_REQ（name 来自发现阶段的邻居表）。
    RequestReceived {
        device_id: String,
        name: String,
        pin: String,
        ts_ms: u64,
    },
    /// 本机用户对照 PIN 一致，点「确认配对」（应答方）。
    UserConfirmed { ts_ms: u64 },
    /// 本机用户点「取消」或 PIN 不一致。
    UserRejected { ts_ms: u64 },
    /// 收到对端 PAIR_RESP（发起方）。
    ResponseReceived { accepted: bool, ts_ms: u64 },
    /// 主动取消。
    Cancel { ts_ms: u64 },
    /// 时间推进（用于超时检测，不依赖线程/定时器）。
    Tick { now_ms: u64 },
}

/// 状态机输出：交给传输层 / UI / 存储层执行。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PairAction {
    /// 发送 PAIR_REQ（M3 起由 TCP 会话层真正发送）。
    SendRequest { payload: PairReqPayload },
    /// 发送 PAIR_RESP。
    SendResponse { payload: PairRespPayload },
    /// UI：大字显示 PIN + 倒计时（deadline_ms 为绝对单调毫秒）。
    ShowPin { pin: String, deadline_ms: u64 },
    /// 写入配对表（T2.2）。
    PersistContact {
        device_id: String,
        name: String,
        at_ms: u64,
    },
    /// UI：配对成功（可动画 + 跳转联系人）。
    Paired { device_id: String },
    /// UI：失败文案。
    Failed { reason: PairFailure },
    /// UI：已取消。
    Cancelled,
}

/// 6 位数字 PIN 是否合法。
pub fn is_valid_pin(pin: &str) -> bool {
    pin.len() == 6 && pin.chars().all(|c| c.is_ascii_digit())
}

/// 生成 6 位数字 PIN（随机源：uuid v4 的 4 字节，v1 明文仅用于人工对照）。
pub fn generate_pin() -> String {
    let bytes = uuid::Uuid::new_v4();
    let raw = u32::from_le_bytes([bytes.as_bytes()[0], bytes.as_bytes()[1], bytes.as_bytes()[2], bytes.as_bytes()[3]]);
    format!("{:06}", raw % 1_000_000)
}

fn clamp_name(name: &str, fallback: &str) -> String {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return fallback.to_string();
    }
    trimmed.chars().take(MAX_NAME_LEN).collect()
}

/// 配对状态机。
#[derive(Debug, Clone)]
pub struct PairingMachine {
    role: PairRole,
    state: PairState,
    /// 对端设备 id（发起时来自发现阶段，应答时来自 PAIR_REQ）。
    peer_id: Option<String>,
    peer_name: String,
    deadline_ms: u64,
    /// 已经发起过几次（UI 可用于展示「重试」）。
    attempts: u32,
    /// 测试注入的 PIN 生成器（生产用 [`generate_pin`]）。
    pin_override: Option<String>,
}

impl Default for PairingMachine {
    fn default() -> Self {
        Self::new()
    }
}

impl PairingMachine {
    pub fn new() -> Self {
        Self {
            role: PairRole::Initiator,
            state: PairState::Idle,
            peer_id: None,
            peer_name: String::new(),
            deadline_ms: 0,
            attempts: 0,
            pin_override: None,
        }
    }

    /// 发起方：绑定对端设备（发现阶段已知 name 时一并记住）。
    pub fn with_peer(peer_id: impl Into<String>, peer_name: impl Into<String>) -> Self {
        let mut m = Self::new();
        m.peer_id = Some(peer_id.into());
        m.peer_name = peer_name.into();
        m
    }

    /// 单测用：固定 PIN。
    pub fn with_pin(mut self, pin: impl Into<String>) -> Self {
        self.pin_override = Some(pin.into());
        self
    }

    pub fn state(&self) -> &PairState {
        &self.state
    }

    pub fn role(&self) -> PairRole {
        self.role
    }

    pub fn peer_id(&self) -> Option<&str> {
        self.peer_id.as_deref()
    }

    pub fn attempts(&self) -> u32 {
        self.attempts
    }

    /// 当前会话还剩多少毫秒（无会话时返回 0）。
    pub fn remaining_ms(&self, now_ms: u64) -> u64 {
        match self.state {
            PairState::WaitingResponse { .. } | PairState::AwaitingConfirm { .. } => {
                self.deadline_ms.saturating_sub(now_ms)
            }
            _ => 0,
        }
    }

    /// 驱动状态机，返回需要执行的动作序列。
    pub fn handle(&mut self, input: PairInput) -> Vec<PairAction> {
        match input {
            PairInput::Start {
                already_paired,
                ts_ms,
            } => self.on_start(already_paired, ts_ms),
            PairInput::RequestReceived {
                device_id,
                name,
                pin,
                ts_ms,
            } => self.on_request(device_id, name, pin, ts_ms),
            PairInput::UserConfirmed { ts_ms } => self.on_user_confirmed(ts_ms),
            PairInput::UserRejected { ts_ms } => self.on_user_rejected(ts_ms),
            PairInput::ResponseReceived { accepted, ts_ms } => {
                self.on_response(accepted, ts_ms)
            }
            PairInput::Cancel { ts_ms: _ } => {
                if self.state.is_terminal() {
                    return Vec::new();
                }
                self.state = PairState::Failed {
                    reason: PairFailure::Cancelled,
                };
                vec![PairAction::Cancelled]
            }
            PairInput::Tick { now_ms } => self.on_tick(now_ms),
        }
    }

    fn on_start(&mut self, already_paired: bool, ts_ms: u64) -> Vec<PairAction> {
        let Some(peer_id) = self.peer_id.clone() else {
            return Vec::new(); // 没有对端设备，忽略（调用方应先 with_peer）
        };
        self.role = PairRole::Initiator;

        // 已经在配对表里：幂等成功，不再打扰对端
        if already_paired {
            self.state = PairState::Paired {
                device_id: peer_id.clone(),
            };
            return vec![PairAction::Paired { device_id: peer_id }];
        }

        let pin = self
            .pin_override
            .clone()
            .unwrap_or_else(generate_pin);
        if !is_valid_pin(&pin) {
            self.state = PairState::Failed {
                reason: PairFailure::InvalidPin,
            };
            return vec![PairAction::Failed {
                reason: PairFailure::InvalidPin,
            }];
        }

        self.attempts += 1;
        self.deadline_ms = ts_ms + PAIR_TIMEOUT_MS;
        self.state = PairState::WaitingResponse {
            pin: pin.clone(),
            started_ms: ts_ms,
        };
        vec![
            PairAction::ShowPin {
                pin: pin.clone(),
                deadline_ms: self.deadline_ms,
            },
            PairAction::SendRequest {
                payload: PairReqPayload {
                    device_id: peer_id,
                    pin,
                    ts_ms,
                },
            },
        ]
    }

    fn on_request(
        &mut self,
        device_id: String,
        name: String,
        pin: String,
        ts_ms: u64,
    ) -> Vec<PairAction> {
        let peer_name = clamp_name(&name, &device_id);

        // 已经配对成功过：直接回 accept（幂等，不再走一遍 PIN）
        if let PairState::Paired { device_id: paired } = &self.state {
            if paired == &device_id {
                self.peer_name = peer_name;
                return vec![PairAction::SendResponse {
                    payload: PairRespPayload {
                        accepted: true,
                        reason: None,
                    },
                }];
            }
        }

        // 已经在忙（我方发起中，或对端换了一台设备）→ 回 Busy，不打断当前会话
        let busy = match (&self.state, self.peer_id.as_deref()) {
            (PairState::Idle, _) | (PairState::Failed { .. }, _) => false,
            (_, Some(existing)) => existing != device_id,
            (_, None) => false,
        } || matches!(self.state, PairState::WaitingResponse { .. });
        if busy {
            return vec![PairAction::SendResponse {
                payload: PairRespPayload {
                    accepted: false,
                    reason: Some(PairFailure::Busy.as_str().to_string()),
                },
            }];
        }

        // 同一个对端重发同一会话：幂等重显 PIN
        if let PairState::AwaitingConfirm { pin: current, .. } = &self.state {
            if self.peer_id.as_deref() == Some(device_id.as_str()) && current == &pin {
                return vec![PairAction::ShowPin {
                    pin,
                    deadline_ms: self.deadline_ms,
                }];
            }
        }

        if !is_valid_pin(&pin) {
            self.state = PairState::Failed {
                reason: PairFailure::InvalidPin,
            };
            return vec![
                PairAction::SendResponse {
                    payload: PairRespPayload {
                        accepted: false,
                        reason: Some(PairFailure::InvalidPin.as_str().to_string()),
                    },
                },
                PairAction::Failed {
                    reason: PairFailure::InvalidPin,
                },
            ];
        }

        self.role = PairRole::Responder;
        self.peer_id = Some(device_id);
        self.peer_name = peer_name;
        self.deadline_ms = ts_ms + PAIR_TIMEOUT_MS;
        self.state = PairState::AwaitingConfirm {
            pin: pin.clone(),
            started_ms: ts_ms,
        };
        vec![PairAction::ShowPin {
            pin,
            deadline_ms: self.deadline_ms,
        }]
    }

    fn on_user_confirmed(&mut self, ts_ms: u64) -> Vec<PairAction> {
        if self.expire_if_needed(ts_ms).is_some() {
            return self.fail(PairFailure::Timeout);
        }
        let (PairState::AwaitingConfirm { .. }, Some(peer_id)) =
            (&self.state, self.peer_id.clone())
        else {
            return Vec::new();
        };
        let name = self.peer_name.clone();
        self.state = PairState::Paired {
            device_id: peer_id.clone(),
        };
        vec![
            PairAction::SendResponse {
                payload: PairRespPayload {
                    accepted: true,
                    reason: None,
                },
            },
            PairAction::PersistContact {
                device_id: peer_id.clone(),
                name,
                at_ms: ts_ms,
            },
            PairAction::Paired { device_id: peer_id },
        ]
    }

    fn on_user_rejected(&mut self, ts_ms: u64) -> Vec<PairAction> {
        if self.state.is_terminal() {
            return Vec::new();
        }
        let _ = ts_ms;
        let mut actions = Vec::new();
        if matches!(self.state, PairState::AwaitingConfirm { .. }) {
            actions.push(PairAction::SendResponse {
                payload: PairRespPayload {
                    accepted: false,
                    reason: Some(PairFailure::Rejected.as_str().to_string()),
                },
            });
        }
        self.state = PairState::Failed {
            reason: PairFailure::Rejected,
        };
        actions.push(PairAction::Failed {
            reason: PairFailure::Rejected,
        });
        actions
    }

    fn on_response(&mut self, accepted: bool, ts_ms: u64) -> Vec<PairAction> {
        if !matches!(self.state, PairState::WaitingResponse { .. }) {
            return Vec::new();
        }
        if self.expire_if_needed(ts_ms).is_some() {
            return self.fail(PairFailure::Timeout);
        }
        if !accepted {
            return self.fail(PairFailure::Rejected);
        }
        let Some(peer_id) = self.peer_id.clone() else {
            return self.fail(PairFailure::Rejected);
        };
        let name = self.peer_name.clone();
        self.state = PairState::Paired {
            device_id: peer_id.clone(),
        };
        vec![
            PairAction::PersistContact {
                device_id: peer_id.clone(),
                name,
                at_ms: ts_ms,
            },
            PairAction::Paired { device_id: peer_id },
        ]
    }

    fn on_tick(&mut self, now_ms: u64) -> Vec<PairAction> {
        if self.expire_if_needed(now_ms).is_some() {
            return self.fail(PairFailure::Timeout);
        }
        Vec::new()
    }

    /// 若已过超时阈值则置为 Failed 并返回原因（严格大于阈值才算超时）。
    fn expire_if_needed(&mut self, now_ms: u64) -> Option<PairFailure> {
        let active = matches!(
            self.state,
            PairState::WaitingResponse { .. } | PairState::AwaitingConfirm { .. }
        );
        if active && now_ms > self.deadline_ms {
            self.state = PairState::Failed {
                reason: PairFailure::Timeout,
            };
            return Some(PairFailure::Timeout);
        }
        None
    }

    /// 统一的失败出口：**先改状态再给动作**。
    ///
    /// （曾漏掉改状态：拒绝后状态还停在等待中，UI 会一直转圈、也无法重试）
    fn fail(&mut self, reason: PairFailure) -> Vec<PairAction> {
        self.state = PairState::Failed { reason };
        vec![PairAction::Failed { reason }]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const T0: u64 = 1_760_000_000_000;

    fn initiator() -> PairingMachine {
        PairingMachine::with_peer("dev-b", "Pixel 7").with_pin("123456")
    }

    fn responder() -> PairingMachine {
        PairingMachine::new()
    }

    fn request(m: &mut PairingMachine, pin: &str, ts: u64) -> Vec<PairAction> {
        m.handle(PairInput::RequestReceived {
            device_id: "dev-a".into(),
            name: "DESKTOP-ORION".into(),
            pin: pin.into(),
            ts_ms: ts,
        })
    }

    #[test]
    fn pin_is_six_digits_and_valid() {
        for _ in 0..64 {
            let pin = generate_pin();
            assert!(is_valid_pin(&pin), "生成的 PIN 不合法: {pin}");
        }
        assert!(!is_valid_pin("12345"));
        assert!(!is_valid_pin("1234567"));
        assert!(!is_valid_pin("12345a"));
        assert!(!is_valid_pin(""));
    }

    #[test]
    fn initiator_start_shows_pin_and_sends_request() {
        let mut m = initiator();
        let actions = m.handle(PairInput::Start {
            already_paired: false,
            ts_ms: T0,
        });
        assert_eq!(actions.len(), 2);
        match &actions[0] {
            PairAction::ShowPin { pin, deadline_ms } => {
                assert_eq!(pin, "123456");
                assert_eq!(*deadline_ms, T0 + PAIR_TIMEOUT_MS);
            }
            other => panic!("期望 ShowPin，实际 {other:?}"),
        }
        match &actions[1] {
            PairAction::SendRequest { payload } => {
                assert_eq!(payload.device_id, "dev-b");
                assert_eq!(payload.pin, "123456");
                assert_eq!(payload.ts_ms, T0);
            }
            other => panic!("期望 SendRequest，实际 {other:?}"),
        }
        assert_eq!(m.attempts(), 1);
        assert_eq!(m.remaining_ms(T0), PAIR_TIMEOUT_MS);
        assert!(!m.state().is_terminal());
    }

    #[test]
    fn initiator_happy_path_persists_contact() {
        let mut m = initiator();
        m.handle(PairInput::Start {
            already_paired: false,
            ts_ms: T0,
        });
        let actions = m.handle(PairInput::ResponseReceived {
            accepted: true,
            ts_ms: T0 + 3_000,
        });
        assert!(matches!(actions[0], PairAction::PersistContact { ref device_id, .. } if device_id == "dev-b"));
        match &actions[1] {
            PairAction::Paired { device_id } => assert_eq!(device_id, "dev-b"),
            other => panic!("期望 Paired，实际 {other:?}"),
        }
        assert_eq!(
            m.state(),
            &PairState::Paired {
                device_id: "dev-b".into()
            }
        );
    }

    #[test]
    fn initiator_timeout_is_strictly_after_deadline() {
        let mut m = initiator();
        m.handle(PairInput::Start {
            already_paired: false,
            ts_ms: T0,
        });
        // 恰好到点：还不算超时
        assert!(m.handle(PairInput::Tick {
            now_ms: T0 + PAIR_TIMEOUT_MS
        })
        .is_empty());
        assert!(!m.state().is_terminal());
        // 过 1ms：超时
        let actions = m.handle(PairInput::Tick {
            now_ms: T0 + PAIR_TIMEOUT_MS + 1,
        });
        assert_eq!(
            actions,
            vec![PairAction::Failed {
                reason: PairFailure::Timeout
            }]
        );
        assert_eq!(m.remaining_ms(T0 + PAIR_TIMEOUT_MS + 1), 0);
    }

    #[test]
    fn late_response_after_timeout_is_ignored() {
        let mut m = initiator();
        m.handle(PairInput::Start {
            already_paired: false,
            ts_ms: T0,
        });
        m.handle(PairInput::Tick {
            now_ms: T0 + PAIR_TIMEOUT_MS + 1,
        });
        assert!(m
            .handle(PairInput::ResponseReceived {
                accepted: true,
                ts_ms: T0 + PAIR_TIMEOUT_MS + 2
            })
            .is_empty());
        assert!(matches!(m.state(), PairState::Failed { .. }));
    }

    #[test]
    fn initiator_can_retry_after_failure() {
        let mut m = initiator();
        m.handle(PairInput::Start {
            already_paired: false,
            ts_ms: T0,
        });
        m.handle(PairInput::ResponseReceived {
            accepted: false,
            ts_ms: T0 + 1_000,
        });
        assert_eq!(
            m.state(),
            &PairState::Failed {
                reason: PairFailure::Rejected
            }
        );
        // 重试：重新计时并重新显示 PIN
        let actions = m.handle(PairInput::Start {
            already_paired: false,
            ts_ms: T0 + 2_000,
        });
        assert_eq!(actions.len(), 2);
        assert_eq!(m.attempts(), 2);
        assert_eq!(m.remaining_ms(T0 + 2_000), PAIR_TIMEOUT_MS);
    }

    #[test]
    fn already_paired_start_is_idempotent() {
        let mut m = initiator();
        let actions = m.handle(PairInput::Start {
            already_paired: true,
            ts_ms: T0,
        });
        assert_eq!(
            actions,
            vec![PairAction::Paired {
                device_id: "dev-b".into()
            }]
        );
        assert_eq!(m.attempts(), 0, "已配对不应重新发请求");
    }

    #[test]
    fn responder_shows_pin_then_confirms() {
        let mut m = responder();
        let actions = request(&mut m, "654321", T0);
        assert_eq!(actions.len(), 1, "应答方只显示 PIN，不发帧");
        match &actions[0] {
            PairAction::ShowPin { pin, deadline_ms } => {
                assert_eq!(pin, "654321");
                assert_eq!(*deadline_ms, T0 + PAIR_TIMEOUT_MS);
            }
            other => panic!("期望 ShowPin，实际 {other:?}"),
        }
        assert_eq!(m.role(), PairRole::Responder);
        assert_eq!(m.peer_id(), Some("dev-a"));
        assert!(matches!(m.state(), PairState::AwaitingConfirm { .. }));

        let actions = m.handle(PairInput::UserConfirmed { ts_ms: T0 + 5_000 });
        assert!(matches!(actions[0], PairAction::SendResponse { ref payload } if payload.accepted));
        assert!(matches!(actions[1], PairAction::PersistContact { ref device_id, ref name, .. }
            if device_id == "dev-a" && name == "DESKTOP-ORION"));
        assert!(matches!(actions[2], PairAction::Paired { .. }));
    }

    #[test]
    fn responder_rejects_and_can_retry() {
        let mut m = responder();
        request(&mut m, "111111", T0);
        let actions = m.handle(PairInput::UserRejected { ts_ms: T0 + 100 });
        assert!(matches!(
            &actions[0],
            PairAction::SendResponse { payload } if !payload.accepted
                && payload.reason.as_deref() == Some("rejected")
        ));
        assert_eq!(
            m.state(),
            &PairState::Failed {
                reason: PairFailure::Rejected
            }
        );
        // 重试新会话
        let actions = request(&mut m, "222222", T0 + 200);
        assert!(matches!(actions[0], PairAction::ShowPin { ref pin, .. } if pin == "222222"));
    }

    #[test]
    fn responder_rejects_invalid_pin_without_entering_session() {
        let mut m = responder();
        let actions = request(&mut m, "12ab", T0);
        assert!(matches!(
            &actions[0],
            PairAction::SendResponse { payload } if !payload.accepted
                && payload.reason.as_deref() == Some("invalid pin")
        ));
        assert_eq!(
            m.state(),
            &PairState::Failed {
                reason: PairFailure::InvalidPin
            }
        );
        assert!(m.peer_id().is_none(), "非法 PIN 不应记住对端");
    }

    #[test]
    fn responder_duplicate_request_is_idempotent() {
        let mut m = responder();
        request(&mut m, "654321", T0);
        let again = request(&mut m, "654321", T0 + 500);
        assert_eq!(again.len(), 1);
        assert!(matches!(&again[0], PairAction::ShowPin { pin, .. } if pin == "654321"));
        // 时间没有重置（仍按第一次的 deadline）
        assert_eq!(m.remaining_ms(T0 + 500), PAIR_TIMEOUT_MS - 500);
    }

    #[test]
    fn responder_answers_busy_when_another_session_active() {
        let mut m = responder();
        request(&mut m, "654321", T0);
        // 另一台设备插进来
        let actions = m.handle(PairInput::RequestReceived {
            device_id: "dev-c".into(),
            name: "Galaxy Tab".into(),
            pin: "999999".into(),
            ts_ms: T0 + 100,
        });
        assert!(matches!(
            &actions[0],
            PairAction::SendResponse { payload } if !payload.accepted
                && payload.reason.as_deref() == Some("busy")
        ));
        assert_eq!(m.peer_id(), Some("dev-a"), "忙碌时不应切换对端");
    }

    #[test]
    fn initiator_rejects_incoming_request_while_waiting() {
        let mut m = initiator();
        m.handle(PairInput::Start {
            already_paired: false,
            ts_ms: T0,
        });
        // 双方同时发起：我们是发起方，回 Busy 但保持自己的会话
        let actions = request(&mut m, "000000", T0 + 50);
        assert!(matches!(
            &actions[0],
            PairAction::SendResponse { payload } if payload.reason.as_deref() == Some("busy")
        ));
        assert!(matches!(m.state(), PairState::WaitingResponse { .. }));
    }

    #[test]
    fn paired_peer_re_request_is_auto_accepted() {
        let mut m = responder();
        request(&mut m, "654321", T0);
        m.handle(PairInput::UserConfirmed { ts_ms: T0 + 10 });
        // 已配对设备再来一次（例如对端重装后重发）→ 直接 accept，不再打扰用户
        let actions = request(&mut m, "111111", T0 + 20);
        assert_eq!(actions.len(), 1);
        assert!(matches!(
            &actions[0],
            PairAction::SendResponse { payload } if payload.accepted
        ));
    }

    #[test]
    fn responder_timeout_before_user_confirms() {
        let mut m = responder();
        request(&mut m, "654321", T0);
        m.handle(PairInput::Tick {
            now_ms: T0 + PAIR_TIMEOUT_MS + 1,
        });
        assert_eq!(
            m.state(),
            &PairState::Failed {
                reason: PairFailure::Timeout
            }
        );
        // 超时后再点确认：什么都不做（不会写出联系人）
        assert!(m
            .handle(PairInput::UserConfirmed {
                ts_ms: T0 + PAIR_TIMEOUT_MS + 2
            })
            .is_empty());
    }

    #[test]
    fn cancel_is_terminal_and_ignored_after_terminal() {
        let mut m = initiator();
        m.handle(PairInput::Start {
            already_paired: false,
            ts_ms: T0,
        });
        assert_eq!(
            m.handle(PairInput::Cancel { ts_ms: T0 + 1 }),
            vec![PairAction::Cancelled]
        );
        assert_eq!(
            m.state(),
            &PairState::Failed {
                reason: PairFailure::Cancelled
            }
        );
        assert!(m.handle(PairInput::Cancel { ts_ms: T0 + 2 }).is_empty());
    }

    #[test]
    fn long_peer_name_is_clamped() {
        // 对端可能塞超长名字，写进配对表前截断
        let mut m2 = responder();
        let actions = m2.handle(PairInput::RequestReceived {
            device_id: "dev-e".into(),
            name: "B".repeat(500),
            pin: "654321".into(),
            ts_ms: T0,
        });
        assert!(matches!(actions[0], PairAction::ShowPin { .. }));
        let actions = m2.handle(PairInput::UserConfirmed { ts_ms: T0 + 1 });
        match &actions[1] {
            PairAction::PersistContact { name, .. } => assert_eq!(name.chars().count(), MAX_NAME_LEN),
            other => panic!("期望 PersistContact，实际 {other:?}"),
        }
    }
}
