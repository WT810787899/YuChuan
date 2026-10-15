//! Rust 侧核心业务层（不依赖 flutter_rust_bridge，可独立单测）。
//!
//! 分层约定（见 docs/PLAN.md §4）：
//! - [`protocol`]  帧编解码 + 消息载荷（TASKS T0.3 / T3.2 风险9、10、11）
//! - [`discovery`] UDP 发现与邻居表（TASKS T1.1 / T1.2 风险2、3）
//! - [`pairing`]   握手配对状态机（TASKS T2.1 / T2.2）
//! - [`session`]   TCP 会话与重连（TASKS T3.1 / 风险17）
//! - [`transfer`]  分块传输与断点续传（TASKS T4.1 / T4.2 风险8）
//! - [`storage`]   SQLite 历史与配对表（TASKS T3.3 / T2.2）
//!
//! 注意：模块名刻意避开 `core`（与 crate `core` 歧义），统一用 `backend`。

pub mod discovery;
pub mod pairing;
pub mod protocol;
pub mod session;
pub mod storage;
pub mod transfer;
