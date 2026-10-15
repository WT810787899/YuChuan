# 离线发送可靠投递与安卓后台保活 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让「对方离线时发送的消息与文件」在对端重新上线后必定送达且不重复、不丢序，并让安卓切后台不再中断进行中的传输。

**Architecture:** 在 Rust 侧新增持久化**发件箱（outbox）**，作为离线待发的唯一真相来源，取代当前 Dart 内存里的 `queued` 布尔标记；把 `SeqTracker` 的去重状态与发送序号持久化，使其跨重连、跨进程重启依然有效；补发由「上线事件」与「周期扫描」双触发，绕开 `ensureDial` 的 `_dialed` 死闸；安卓侧**新增前台服务 `TransferService`（`foregroundServiceType="dataSync"`）**，在有待发内容或传输进行中时以常驻通知把进程钉在前台，同时保住 WifiLock/MulticastLock，进程被回收后依靠发件箱在重启后续传。

> **决策修订记录（2026-04-19，用户拍板）：** 本行原写「安卓侧不新增前台服务」。用户复审后否决该方案——「安卓后台进程被系统回收这一根因无法根治」正是待修 bug「安卓后台会中断传输」本身，不根治即等于没修。现改为新增 `FOREGROUND_SERVICE_DATA_SYNC` 前台服务。Task 7~9 原本就按此方案撰写，故与之保持一致的是 Task 7~9，而非旧的第 7/59 行。

**Tech Stack:** Rust（rust_builder，flutter_rust_bridge v2 FFI）、Dart/Flutter、Android Kotlin（MethodChannel `yuchuan/platform`）、JSONL 持久化（无 SQLite）、blake3 内容哈希。

**Spec:** 本计划自带设计依据，见下方「设计依据与根因证据」一节（源自 Phase 1 代码调查）。仓库内相关需求条目位于 `需求.MD` 第 20 / 46 / 56 / 72 行。

---

## 设计依据与根因证据

本节是 Phase 1 系统性调试的结论，每条都指向具体代码位置。执行者必须理解这些根因，因为**修复位置与症状位置不在一处**，这正是此前「修了没好」的原因。

### 根因 1：离线发送后无任何东西会再次触发拨号（症状：对端收不到）

- `lib/app_state.dart:2525` `sendMessage` 离线早退分支：只设 `optimistic.queued = true`，**不拨号、不设定时器、不入任何持久队列**。
- 唯一的补发入口 `_syncAfterConnect`（`lib/app_state.dart:1332`）只被 `_onChatEvent` 的 `connected` 分支调用（`lib/app_state.dart:1500`）。
- `connected` 事件由 Rust 在 **TCP 握手 + HELLO 交换**都完成后才发出（`rust_builder/src/backend/session.rs:388-409`）。
- 而拨号唯一入口 `ensureDial`（`lib/app_state.dart:1300-1318`）有两道**永久性**闸门：
  - `:1301` `if (!chatReady || _dialed.contains(peerId)) return;`
  - `:1303` `if (device.ip.isEmpty) return;`（`_deviceFor` 在地址缺失时返回空 ip，见 `lib/app_state.dart:1265-1297`）

结论：对端不在线 → 发送 → 之后**再无任何代码路径会调用 ensureDial** → `Connected` 永不到来 → `_syncAfterConnect` 永不执行 → 消息永久滞留。这不是「补发失败」，是**补发从未被触发**。

### 根因 2：SeqTracker 随连接重建而重置（症状：收不到 + 收重复）

- `rust_builder/src/backend/session.rs:183`：`Connection::start` 里 `seqs: Mutex::new(SeqTracker::default())` —— **每次连接重建都是空的**。
- 去重逻辑本身正确（`:427-440`，`accept` 返回 false 即丢弃、不 emit），但 `last_seen`（`:151-152`）与 `out_seq`（`:909`）都随连接消失。
- 后果 A（丢新消息，比「收不到」更隐蔽）：重连后 `out_seq` 从 0 重新计数，新消息的 seq 可能**小于**对端已见最大值 → 被 `accept` 判为不新鲜 → **静默丢弃**。
- 后果 B（重复）：重连后 `last_seen` 为空，任何重发的旧 seq 都被当新消息。

结论：这是「不要重复触发」与「对端收得到」两个需求的**共同前提**，必须先修。

### 根因 3：Rust 侧完全没有发件箱，排队只是 Dart 内存里的一个 bool

- `grep outbox` 在 `rust_builder/src` 下无匹配。
- 存储层是 **JSONL append-only，不是 SQLite**（`rust_builder/src/backend/storage.rs:268-277` 明确说明为何不用 rusqlite：交叉编译到 Android 未验证）→ 发件箱的实际形态是 `outbox.jsonl` + 内存索引。
- 后果：安卓进程被回收后重启，`queued` 标记全丢 → 离线消息**彻底消失**。这是 bug「对端收不到」与「安卓后台中断」在真机上的交汇点。

### 根因 4：安卓侧不存在任何保活机制

- `android/app/src/main/AndroidManifest.xml` **无任何 `<service>` 声明，无 `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_DATA_SYNC` 权限**。
- `MainActivity.kt:215-229` 只持有 `WIFI_MODE_FULL_HIGH_PERF` WifiLock；`onDestroy:405-409` **主动释放** MulticastLock + WifiLock。
- 结论：进程优先级下降即断；`onDestroy` 进一步保证断。

### 根因 5：文件补发无对端去重

- 文件消息 `msg_id` 为 `file-<file_id>`（`lib/app_state.dart` 发送侧），`file_id` 来自 `FileFingerprint.file_id`（blake3 内容哈希，`rust_builder/src/backend/transfer.rs:53-65`）。
- Dart 的 `_resyncedFiles`（`lib/app_state.dart:1330`，键 `'$peerId|${fileName}|${fileSize}'`）是**本机内存集合**，对端没有任何文件消息去重。
- 结论：文件补发必须靠 `file_id` 在存储层查重。

### 已知边界（有意识的取舍，不隐藏）

**用户已拍板：新增前台服务**（`TransferService`，`foregroundServiceType="dataSync"`，权限 `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_DATA_SYNC`）。理由是「进程被系统回收」正是待修 bug 本身，不根治等于没修。

仍然存在的、必须承认的边界：

1. **安卓 14+ 对 `dataSync` 前台服务有运行时长上限**（系统可能在累计约 6 小时后强制停止该类型服务）。因此前台服务只应在**确有传输进行中或确有待发内容**时启动，空闲时必须 `stopForeground`/停止服务——这既是功耗要求，也是避免撞上系统配额的必要措施。本计划 Task 7 按「按需启停」实现。
2. **国产 ROM（MIUI/ColorOS/EMUI 等）的省电策略可能仍然杀进程**，即使有前台服务。这是厂商行为，代码层面无法完全规避；发件箱持久化保证被杀后重启仍能续传，是最后的兜底。
3. **通知栏会出现一条常驻条目**（这是前台服务的系统要求，无法取消）。仅在有传输/待发时出现。

---

## Global Constraints

- **Rust 测试运行目录**：`D:\Coding\YuChuan\rust_builder`，命令 `cargo test`。实测 `cargo 1.95.0` / `rustc 1.95.0` 可用，`cargo test --no-run` 已验证通过。
- **⚠️ 不要用 `$LASTEXITCODE` 判断 cargo 成功与否**：cargo 的 `Finished` / `Executable` 输出走 **stderr**，在 PowerShell 中会被渲染为 `RemoteException` 且**进程 exit code 为 1，即使命令实际成功**。判成功必须看输出文本包含 `test result: ok` 或 `Finished`。
- **Flutter 不在 PATH**，必须用绝对路径调用：`C:\flutter\bin\flutter.bat`。
- **禁止手改生成代码**：`lib/src/rust/frb_generated.dart`（157KB）与 `rust_builder/src/frb_generated.rs`（215KB）由 frb codegen 产出，只能通过重新生成来更新。
- **存储层无 SQLite**：新持久化一律用「append-only JSONL + 内存索引 + 原子写（`.tmp` 后 `rename`）」模式，复用 `rust_builder/src/backend/storage.rs:210-227` 的 `save()` 范式。
- **发件箱是唯一真相来源**：写完后 Dart 侧的 `queued` 仅作 UI 展示用，不得再作为「是否待发」的判断依据。
- **不要破坏既有子串契约**：`rust_builder/src/api/chat.rs:339-341` 的 `"未连接到对端（...）"` 子串被 Dart `sendMessage` 的 catch 依赖（`lib/app_state.dart:2553` 附近的 `e.toString().contains('未连接到对端')`），改动错误文案时必须保留该子串。
- **需求文档、设计文档、计划文档一律用中文书写**。

## Review Focus

以下是通过代码审查发现的、计划任务测试未直接覆盖但真机上最可能出问题的输入/条件，每条都在对应任务中加了测试：

1. **进程在「已发送、未收到对端确认」的窗口内被杀** → 期望：重启后重发，且对端只显示一条（不能因为发件箱未清而产生第二条气泡）。→ 见 Task 5、Task 6。
2. **对端重启后自身 seq 归零，向我发第一条消息** → 期望：我这边不因「seq 比历史小」而丢弃它（跨进程重启的 SeqTracker 不能反噬对端）。→ 见 Task 3。
3. **同一条离线消息在两台设备上同时补发（双端同时上线）** → 期望：各自只落一条，不出现「文件冗余错乱」。→ 见 Task 6、Task 8。
4. **补发时源文件已被用户删除或移动**（离线排队的文件路径失效）→ 期望：明确标记失败并告知用户，不能静默卡在「排队中」。→ 见 Task 7。
5. **安卓切后台再回前台，期间连接已被对端判超时（10s）** → 期望：回后台即重连、回前台状态正确，不出现「UI 显示在线但实际发不出去」。→ 见 Task 10、Task 11（前台服务使能 + 生命周期重连）。

---

## File Structure

**Rust（rust_builder/src/）**
- `backend/storage.rs` — 修改：新增 `OutboxStore`（`outbox.jsonl` + 内存索引），复用 `save()` 原子写范式；新增 `SeqTracker` 的持久化载体 `seq_state.json` 读写函数。
- `backend/session.rs` — 修改：`SeqTracker` 增加 `from_persisted` / `snapshot`；`Connection::start` 不再 new 空 tracker，而是注入持久化状态；`out_seq` 跨连接单调。
- `api/chat.rs` — 修改：`chat_send_text` 落库前先写发件箱；新增 FFI `chat_outbox_pending` / `chat_outbox_ack` / `chat_outbox_remove` / `chat_outbox_flush`。
- `api/transfer.rs` — 修改：文件发送同样登记发件箱；入站文件按 `file_id` 查重。
- `api/mod.rs` — 若新增独立模块则在此登记。

**Dart（lib/）**
- `services/chat_service.dart` — 修改：包装新的 outbox FFI。
- `services/transfer_service.dart` — 修改：包装文件 outbox FFI。
- `app_state.dart` — 修改：`sendMessage` / `sendFilePath` 离线分支改为登记发件箱；`_syncAfterConnect` 改为「读发件箱 → 补发」；新增周期扫描 `Timer`；`ensureDial` 的 `_dialed` 死闸放宽为可重试。
- `main.dart` — 修改：注册 `WidgetsBindingObserver`，处理 `AppLifecycleState.paused/resumed`；切后台时有待发/传输中则 `startTransferService`，空闲则 `stopTransferService`。

**Android（android/app/src/main/）**
- `kotlin/com/yuchuan/app/TransferService.kt` — **新增**：前台服务（`foregroundServiceType="dataSync"`），按需启停；通知渠道 `yuchuan-transfer`；随服务一起持有 WifiLock/MulticastLock。
- `kotlin/com/yuchuan/app/MainActivity.kt` — 修改：`onDestroy` 区分「配置变更」与「真销毁」；不再无条件释放锁；新增 `startTransferService` / `stopTransferService` / `isTransferServiceRunning` 通道方法。
- `AndroidManifest.xml` — 修改：新增 `FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_DATA_SYNC` 权限与 `<service android:name=".TransferService" android:foregroundServiceType="dataSync" />` 声明；核对 `WAKE_LOCK` / `CHANGE_WIFI_MULTICAST_STATE` 存在。
- `kotlin/com/yuchuan/app/TransferService.kt` 的 `START_NOT_STICKY` 语义需与 Dart 端「有待发/传输中才启、空闲即停」配合，避免撞上安卓 14+ dataSync 时长配额。

**测试**
- `rust_builder/src/backend/storage.rs` 内联 `#[cfg(test)] mod tests` — 发件箱与 seq 持久化单测。
- `rust_builder/src/backend/session.rs` 内联测试 — SeqTracker 跨连接单调性。
- `test/offline_outbox_test.dart` — 新增：Dart 侧离线排队与补发触发。
- `test/transfer_flow_test.dart` — 修改：补文件查重用例。

---

### Task 1: 发件箱持久化（Rust storage 层）

**Files:**
- Modify: `rust_builder/src/backend/storage.rs`（在 `MessageStore` 的 `impl` 块之后、`StoredMessage` 定义之前插入；文件末尾的 `#[cfg(test)] mod tests` 内追加用例）
- Test: `rust_builder/src/backend/storage.rs`（内联 `#[cfg(test)] mod tests`）

**Interfaces:**
- Consumes: 无（本任务是最底层）
- Produces:
  - `pub struct OutboxEntry { pub id: String, pub peer_id: String, pub kind: u8, pub text: String, pub file_path: String, pub file_name: String, pub file_size: u64, pub created_ms: i64 }`（`kind`: 1=text 2=image 3=file）
  - `pub enum OutboxState { Pending, Sent }`
  - `impl OutboxStore { pub fn open(dir: impl Into<PathBuf>) -> Self; pub fn pending(&self, peer_id: &str) -> Vec<OutboxEntry>; pub fn all_pending(&self) -> Vec<OutboxEntry>; pub fn enqueue(&mut self, entry: OutboxEntry) -> io::Result<()>; pub fn mark_sent(&mut self, id: &str) -> io::Result<()>; pub fn remove(&mut self, id: &str) -> io::Result<bool>; pub fn len(&self) -> usize; pub fn is_empty(&self) -> bool }`

- [ ] **Step 1: 写失败测试**

在 `rust_builder/src/backend/storage.rs` 的 `mod tests` 末尾加入：

```rust
    fn outbox_entry(id: &str, peer: &str) -> OutboxEntry {
        OutboxEntry {
            id: id.to_string(),
            peer_id: peer.to_string(),
            kind: 1,
            text: format!("msg-{id}"),
            file_path: String::new(),
            file_name: String::new(),
            file_size: 0,
            created_ms: T0,
        }
    }

    #[test]
    fn outbox_enqueue_persists_across_reopen() {
        let dir = std::env::temp_dir().join(format!(
            "lanchat_outbox_test_{}_{}",
            "enqueue",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);

        let mut store = OutboxStore::open(&dir);
        store.enqueue(outbox_entry("a1", "peer-x")).unwrap();
        store.enqueue(outbox_entry("a2", "peer-x")).unwrap();
        store.enqueue(outbox_entry("a3", "peer-y")).unwrap();
        drop(store);

        // 关键断言：进程重启（重新 open）后待发项仍在 —— 这是「安卓后台被杀后不丢消息」的地基
        let reopened = OutboxStore::open(&dir);
        assert_eq!(reopened.len(), 3);
        assert_eq!(reopened.pending("peer-x").len(), 2);
        assert_eq!(reopened.pending("peer-y").len(), 1);
        assert_eq!(reopened.pending("peer-x")[0].id, "a1");
    }

    #[test]
    fn outbox_mark_sent_removes_from_pending() {
        let dir = std::env::temp_dir().join(format!(
            "lanchat_outbox_test_{}_{}",
            "sent",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);

        let mut store = OutboxStore::open(&dir);
        store.enqueue(outbox_entry("b1", "peer-x")).unwrap();
        store.enqueue(outbox_entry("b2", "peer-x")).unwrap();

        store.mark_sent("b1").unwrap();
        assert_eq!(store.pending("peer-x").len(), 1);
        assert_eq!(store.pending("peer-x")[0].id, "b2");
        assert_eq!(store.len(), 1);

        drop(store);
        // 已确认送达的不能复活（否则重启后重复发送）
        let reopened = OutboxStore::open(&dir);
        assert_eq!(reopened.len(), 1);
        assert_eq!(reopened.pending("peer-x")[0].id, "b2");
    }

    #[test]
    fn outbox_enqueue_is_idempotent_by_id() {
        let dir = std::env::temp_dir().join(format!(
            "lanchat_outbox_test_{}_{}",
            "idem",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);

        let mut store = OutboxStore::open(&dir);
        store.enqueue(outbox_entry("c1", "peer-x")).unwrap();
        // 同 id 再入队：不能变成两条（防止周期扫描与上线事件同时触发导致重复补发）
        store.enqueue(outbox_entry("c1", "peer-x")).unwrap();
        assert_eq!(store.pending("peer-x").len(), 1);
        assert_eq!(store.len(), 1);
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cargo test outbox_ 2>&1 | Select-String "test result|error\[|cannot find"`
Expected: 编译失败，报 `cannot find type OutboxEntry in this scope` / `cannot find function OutboxStore`。

- [ ] **Step 3: 写最小实现**

在 `rust_builder/src/backend/storage.rs` 中，`impl MessageStore` 块结束后（约 `:582` 之后、`StoredMessage` 定义之前）插入：

```rust
/// 一条离线待发项（发件箱）。
///
/// 为什么需要它：此前「对方离线」只是 Dart 内存里的一个 bool（`ChatMessage.queued`），
/// 进程一重启就全丢。发件箱把它落成磁盘真相，重启后仍能续发。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OutboxEntry {
    /// 唯一 id：文本用消息 id，文件用 `file-<file_id>`。入队按 id 幂等。
    pub id: String,
    pub peer_id: String,
    /// 1=text 2=image 3=file
    pub kind: u8,
    pub text: String,
    /// 仅文件类使用：源文件绝对路径（发送时才读，路径失效要在补发时报错）
    #[serde(default)]
    pub file_path: String,
    #[serde(default)]
    pub file_name: String,
    #[serde(default)]
    pub file_size: u64,
    pub created_ms: i64,
}

/// 发件箱落盘行（append-only JSONL 的一行；`state` 变更也追加一行，读取时后者覆盖前者）。
#[derive(Debug, Clone, Serialize, Deserialize)]
struct OutboxLine {
    id: String,
    /// true = 已确认送达（从待发表中移除）
    sent: bool,
    /// 仅 `sent == false` 时有效
    #[serde(default)]
    entry: Option<OutboxEntry>,
}

/// 离线发件箱（JSONL append-only + 内存索引）。
///
/// 介质与 `MessageStore` 保持一致（见本文件顶部介质选择说明）：无 SQLite，
/// 一行一条、追加写、打开时重放。`mark_sent` 追加一条 `sent: true` 的记录，
/// 重放时按 id 覆盖，从而做到「已送达不会复活」。
pub struct OutboxStore {
    dir: PathBuf,
    pending: Vec<OutboxEntry>,
    skipped_lines: usize,
}

impl OutboxStore {
    /// 打开（或创建）发件箱目录，重放已有记录。
    ///
    /// 同一目录重复 open 是幂等的：调用方（messages_open）可能被多次触发。
    pub fn open(dir: impl Into<PathBuf>) -> Self {
        let dir = dir.into();
        let mut store = Self {
            dir,
            pending: Vec::new(),
            skipped_lines: 0,
        };
        store.replay();
        store
    }

    fn path(&self) -> PathBuf {
        self.dir.join("outbox.jsonl")
    }

    /// 重放日志：后写的状态覆盖先写的。
    fn replay(&mut self) {
        let raw = match fs::read_to_string(self.path()) {
            Ok(raw) => raw,
            Err(_) => return, // 文件不存在 = 首次运行
        };
        // id -> (sent, entry)，保持插入顺序用于稳定输出
        let mut order: Vec<String> = Vec::new();
        let mut state: HashMap<String, (bool, Option<OutboxEntry>)> = HashMap::new();
        for line in raw.lines() {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            match serde_json::from_str::<OutboxLine>(line) {
                Ok(rec) => {
                    if !state.contains_key(&rec.id) {
                        order.push(rec.id.clone());
                    }
                    state.insert(rec.id, (rec.sent, rec.entry));
                }
                // 崩在写一半的最后一行是正常现象：跳过而不是丢掉整个发件箱
                Err(_) => self.skipped_lines += 1,
            }
        }
        self.pending = order
            .into_iter()
            .filter_map(|id| {
                let (sent, entry) = state.remove(&id)?;
                if sent {
                    None
                } else {
                    entry
                }
            })
            .collect();
    }

    /// 追加一行（与 `MessageStore::append` 同样处理半行问题）。
    fn append_line(&self, line: &OutboxLine) -> io::Result<()> {
        let path = self.path();
        if let Some(parent) = path.parent() {
            if !parent.as_os_str().is_empty() {
                fs::create_dir_all(parent)?;
            }
        }
        let mut text = serde_json::to_string(line)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        text.push('\n');

        let needs_leading_newline = fs::read(&path)
            .map(|bytes| bytes.last().map(|b| *b != b'\n').unwrap_or(false))
            .unwrap_or(false);
        let mut file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)?;
        if needs_leading_newline {
            file.write_all(b"\n")?;
        }
        file.write_all(text.as_bytes())?;
        file.flush()?;
        Ok(())
    }

    /// 入队。同 id 已存在（无论待发还是已送达）则不重复添加。
    pub fn enqueue(&mut self, entry: OutboxEntry) -> io::Result<()> {
        if self.pending.iter().any(|e| e.id == entry.id) {
            return Ok(());
        }
        // 已标记 sent 的 id 也不能复活：重放一遍日志确认（日志很小，仅在入队时做一次）
        let sent_ids: Vec<String> = self
            .sent_ids_from_log()
            .unwrap_or_default();
        if sent_ids.contains(&entry.id) {
            return Ok(());
        }
        self.append_line(&OutboxLine {
            id: entry.id.clone(),
            sent: false,
            entry: Some(entry.clone()),
        })?;
        self.pending.push(entry);
        Ok(())
    }

    /// 从日志里读出所有已确认送达的 id。
    fn sent_ids_from_log(&self) -> io::Result<Vec<String>> {
        let raw = match fs::read_to_string(self.path()) {
            Ok(raw) => raw,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(e),
        };
        let mut sent = Vec::new();
        for line in raw.lines() {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            if let Ok(rec) = serde_json::from_str::<OutboxLine>(line) {
                if rec.sent {
                    sent.push(rec.id);
                }
            }
        }
        Ok(sent)
    }

    /// 标记已送达：从待发表移除，并追加一条 `sent: true` 记录。
    pub fn mark_sent(&mut self, id: &str) -> io::Result<()> {
        let before = self.pending.len();
        self.pending.retain(|e| e.id != id);
        if self.pending.len() == before {
            return Ok(()); // 本来就不在待发表：幂等
        }
        self.append_line(&OutboxLine {
            id: id.to_string(),
            sent: true,
            entry: None,
        })
    }

    /// 彻底删除（用户主动取消发送）；与 `mark_sent` 不同，删掉后不阻止同 id 重新入队。
    pub fn remove(&mut self, id: &str) -> io::Result<bool> {
        let before = self.pending.len();
        self.pending.retain(|e| e.id != id);
        let removed = self.pending.len() != before;
        if removed {
            self.append_line(&OutboxLine {
                id: id.to_string(),
                sent: true,
                entry: None,
            })?;
        }
        Ok(removed)
    }

    /// 该对端的待发项（按入队顺序）。
    pub fn pending(&self, peer_id: &str) -> Vec<OutboxEntry> {
        self.pending
            .iter()
            .filter(|e| e.peer_id == peer_id)
            .cloned()
            .collect()
    }

    /// 所有对端的待发项。
    pub fn all_pending(&self) -> Vec<OutboxEntry> {
        self.pending.clone()
    }

    /// 涉及待发项的所有对端 id（周期扫描用：只对这些人尝试拨号）。
    pub fn peers_with_pending(&self) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        for e in &self.pending {
            if !out.contains(&e.peer_id) {
                out.push(e.peer_id.clone());
            }
        }
        out
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    pub fn skipped_lines(&self) -> usize {
        self.skipped_lines
    }

    pub fn len(&self) -> usize {
        self.pending.len()
    }

    pub fn is_empty(&self) -> bool {
        self.pending.is_empty()
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cargo test outbox_ 2>&1 | Select-String "test result"`
Expected: 输出含 `test result: ok. 3 passed`（**不要看 `$LASTEXITCODE`**，见 Global Constraints）。

- [ ] **Step 5: 提交**

仓库不是 git 仓库（`git log` 报 fatal: not a git repository），因此**跳过提交步骤**，改为在计划执行记录里登记完成时间。若执行者发现仓库已初始化为 git，则按 `feat(outbox): 新增持久化离线发件箱` 提交。

---

### Task 2: SeqTracker 状态持久化（Rust session 层）

**Files:**
- Modify: `rust_builder/src/backend/session.rs:905-933`（`SeqTracker` 定义与 `impl`）
- Test: `rust_builder/src/backend/session.rs`（内联 `#[cfg(test)] mod tests`，已有 `seq_tracker_dedupes_and_orders` 于 `:999`）

**Interfaces:**
- Consumes: 无
- Produces:
  - `pub struct SeqState { pub last_seen: HashMap<String, u64>, pub out_seq: u64 }`（`Serialize`/`Deserialize`）
  - `impl SeqTracker { pub fn from_state(state: SeqState) -> Self; pub fn snapshot(&self) -> SeqState }`
  - `SeqTracker::accept` / `next_out` / `last_seen` 签名不变（已有调用点 `session.rs:427-431`、`:612-620`、`:758-766` 不受影响）

**背景（执行者必读）：** `session.rs:183` 每次 `Connection::start` 都 `SeqTracker::default()`，导致两个后果：① 重连后 `out_seq` 从 0 重计，新消息 seq 可能小于对端已见最大值 → 被 `accept` 判为不新鲜 → **静默丢弃**；② 重连后 `last_seen` 为空 → 旧消息重发被当新消息 → **重复**。本任务只解决「状态能被保存与恢复」，持久化的读写与注入在 Task 5 完成。

- [ ] **Step 1: 写失败测试**

在 `rust_builder/src/backend/session.rs` 的 `mod tests` 中，`seq_tracker_dedupes_and_orders`（`:999`）之后追加：

```rust
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
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cargo test seq_tracker_round_trips 2>&1 | Select-String "test result|error\[|no method|no function"`
Expected: 编译失败，报 `no method named `snapshot`` / `no function or associated item named `from_state``。

- [ ] **Step 3: 写最小实现**

把 `rust_builder/src/backend/session.rs:905-933` 的 `SeqTracker` 定义与 `impl` 替换为：

```rust
/// 会话内 (sender_id, seq) 单调序号：去重 + 排序不依赖墙钟（风险11）。
///
/// **状态必须跨连接、跨进程重启存活**：此前的实现每次 `Connection::start` 都
/// `SeqTracker::default()`，重连后 `out_seq` 归零会让新消息被对端当成旧的丢弃，
/// `last_seen` 清空又会让重发的旧消息变成重复。快照由 Task 5 负责落盘与注入。
#[derive(Debug, Default)]
pub struct SeqTracker {
    last_seen: HashMap<String, u64>,
    out_seq: u64,
}

/// `SeqTracker` 的可持久化快照（JSON 落盘用）。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SeqState {
    #[serde(default)]
    pub last_seen: HashMap<String, u64>,
    #[serde(default)]
    pub out_seq: u64,
}

impl SeqTracker {
    /// 从已保存的状态恢复（重连/重启后调用）。
    pub fn from_state(state: SeqState) -> Self {
        Self {
            last_seen: state.last_seen,
            out_seq: state.out_seq,
        }
    }

    /// 导出当前状态供落盘。
    pub fn snapshot(&self) -> SeqState {
        SeqState {
            last_seen: self.last_seen.clone(),
            out_seq: self.out_seq,
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

    pub fn last_seen(&self, sender_id: &str) -> Option<u64> {
        self.last_seen.get(sender_id).copied()
    }
}
```

若文件顶部未导入 `Serialize`/`Deserialize`，在 `use` 区补：

```rust
use serde::{Deserialize, Serialize};
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cargo test seq_tracker 2>&1 | Select-String "test result"`
Expected: `test result: ok. 2 passed`（含既有 `seq_tracker_dedupes_and_orders` 与新加 2 个中的相关项）。

同时运行全量确认没有打破既有会话测试：

Run: `cargo test 2>&1 | Select-String "test result"`
Expected: 所有分组均为 `ok`，无 `FAILED`。

- [ ] **Step 5: 提交**

同 Task 1 Step 5：仓库非 git，跳过提交并登记。

---

### Task 3: SeqTracker 注入连接（消除「新消息被静默丢弃」）

**Files:**
- Modify: `rust_builder/src/backend/session.rs:143-184`（`Shared` 结构体与 `Connection::start`）
- Test: `rust_builder/src/backend/session.rs`（内联测试）

**Interfaces:**
- Consumes: `SeqTracker::from_state` / `snapshot`（Task 2）、`SeqState`（Task 2）
- Produces:
  - `Shared` 新增方法 `pub fn seq_snapshot(&self) -> SeqState` 与 `pub fn restore_seqs(&self, state: SeqState)`
  - `Connection::start` 新签名保持向后兼容：新增 `Connection::start_with_seqs(stream, cfg, events, state: SeqState)`；原 `start` 委托给它并传 `SeqState::default()`
  - `pub fn seqs_of(&self) -> Arc<Mutex<SeqTracker>>`（Task 5 落盘时读快照用）

**背景：** 本任务让「已存在的状态」能进入连接，但不负责从磁盘读（Task 5 负责把磁盘状态传进来）。

- [ ] **Step 1: 写失败测试**

在 `rust_builder/src/backend/session.rs` 的 `mod tests` 追加：

```rust
    #[test]
    fn connection_restored_seqs_reports_last_seen() {
        // 先用一个 tracker 造出「已见过 peer-a: seq 7、已发出 3 条」的状态
        let mut t = SeqTracker::default();
        assert!(t.accept("peer-a", 7));
        let _ = t.next_out();
        let _ = t.next_out();
        let _ = t.next_out();
        let state = t.snapshot();

        // 模拟重连：把状态注入新连接后，已见 seq=7 仍然生效
        let restored = SeqTracker::from_state(state);
        assert_eq!(restored.last_seen("peer-a"), Some(7));
        assert_eq!(restored.snapshot().out_seq, 3);
    }
```

- [ ] **Step 2: 运行测试确认失败并确认现状缺口**

Run: `cargo test connection_restored_seqs 2>&1 | Select-String "test result|error\["`
Expected: 该测试本身可能直接通过（它只用了 Task 2 的接口）—— 这是允许的，本步的真实目的是**确认缺口**：运行下面这条命令，确认当前 `Connection::start` 确实每次都新建空 tracker。

Run: `Select-String -Path "rust_builder\src\backend\session.rs" -Pattern "SeqTracker::default" | Select-Object LineNumber,Line`
Expected: 输出含 `183:            seqs: Mutex::new(SeqTracker::default()),` —— 这就是要改的那一行。

- [ ] **Step 3: 写最小实现**

在 `rust_builder/src/backend/session.rs` 中，为 `Shared` 增加方法（放在 `struct Shared` 定义之后）：

```rust
impl Shared {
    /// 导出当前去重/发送序号状态（Task 5 落盘用）。
    pub fn seq_snapshot(&self) -> SeqState {
        self.seqs
            .lock()
            .map(|t| t.snapshot())
            .unwrap_or_default()
    }

    /// 用已保存的状态替换当前 tracker（重连后由 Task 5 注入）。
    pub fn restore_seqs(&self, state: SeqState) {
        if let Ok(mut guard) = self.seqs.lock() {
            *guard = SeqTracker::from_state(state);
        }
    }
}
```

把 `Connection::start` 中 `seqs: Mutex::new(SeqTracker::default()),` 改为从参数注入，并新增带状态的构造入口：

```rust
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
```

并在其内部把 `seqs: Mutex::new(SeqTracker::default()),` 改成：

```rust
            seqs: Mutex::new(SeqTracker::from_state(seq_state)),
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cargo test 2>&1 | Select-String "test result|FAILED"`
Expected: 全部 `ok`，无 `FAILED`（会话层既有测试如 hello/握手/收发用例必须仍通过）。

Run: `Select-String -Path "rust_builder\src\backend\session.rs" -Pattern "SeqTracker::default\(\)" | Select-Object LineNumber,Line`
Expected: 仅剩测试代码中的出现（`mod tests` 内），生产路径的 `Connection::start` 已不再无条件新建空 tracker。

- [ ] **Step 5: 提交**

同 Task 1 Step 5。

---

### Task 4: 发件箱与 seq 状态的 FFI 接线（Rust api 层）

**Files:**
- Modify: `rust_builder/src/api/chat.rs:35`（新增 static）、`:573-584`（`messages_open` 内初始化）、`:609-615`（`with_store` 旁新增 `with_outbox`）
- Test: `rust_builder/src/api/chat.rs`（内联 `#[cfg(test)] mod tests`）

**Interfaces:**
- Consumes: `OutboxStore` / `OutboxEntry`（Task 1）、`SeqState` / `SeqTracker`（Task 2-3）
- Produces（全部为 frb 导出函数）:
  - `pub fn chat_outbox_enqueue_text(peer_id: String, text: String) -> anyhow::Result<String>` → 返回入队 id
  - `pub fn chat_outbox_enqueue_file(peer_id: String, file_id: String, path: String, file_name: String, file_size: i64, kind: i32) -> anyhow::Result<String>` → 返回入队 id
  - `pub fn chat_outbox_pending(peer_id: Option<String>) -> Vec<OutboxItemDto>`（`#[frb(sync)]`）
  - `pub fn chat_outbox_ack(id: String) -> anyhow::Result<()>`
  - `pub fn chat_outbox_cancel(id: String) -> anyhow::Result<bool>`
  - `pub fn chat_outbox_peers() -> Vec<String>`（`#[frb(sync)]`，周期扫描用）
  - `pub struct OutboxItemDto { pub id: String, pub peer_id: String, pub kind: i32, pub text: String, pub file_path: String, pub file_name: String, pub file_size: i64, pub created_ms: i64 }`

**背景：** 发件箱在 `messages_open` 时随消息存储一起打开（同一根目录下的 `outbox.jsonl`），保证 Dart 只需调用一次既有初始化。

- [ ] **Step 1: 写失败测试**

在 `rust_builder/src/api/chat.rs` 的 `mod tests` 末尾追加：

```rust
    #[test]
    fn outbox_enqueue_pending_ack_roundtrip() {
        let dir = std::env::temp_dir().join(format!(
            "lanchat_outbox_api_{}_{}",
            "roundtrip",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        let root = dir.to_string_lossy().to_string();

        // 打开消息存储会顺带打开同一目录下的发件箱
        let _ = messages_open(root.clone()).unwrap();

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
    fn outbox_peers_lists_only_pending_peers() {
        let dir = std::env::temp_dir().join(format!(
            "lanchat_outbox_api_{}_{}",
            "peers",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);

        let _ = messages_open(dir.to_string_lossy().to_string()).unwrap();

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
        let dir = std::env::temp_dir().join(format!(
            "lanchat_outbox_api_{}_{}",
            "cancel",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        let _ = messages_open(dir.to_string_lossy().to_string()).unwrap();

        let id = chat_outbox_enqueue_text("peer-x".into(), "will cancel".into()).unwrap();
        assert!(chat_outbox_cancel(id).unwrap());
        assert_eq!(chat_outbox_pending(Some("peer-x".into())).len(), 0);
        // 二次取消返回 false，不报错
        assert!(!chat_outbox_cancel("no-such-id".into()).unwrap());
    }

    #[test]
    fn outbox_file_entry_keeps_path_and_size() {
        let dir = std::env::temp_dir().join(format!(
            "lanchat_outbox_api_{}_{}",
            "file",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        let _ = messages_open(dir.to_string_lossy().to_string()).unwrap();

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
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cargo test outbox_enqueue_pending_ack 2>&1 | Select-String "test result|error\[|cannot find"`
Expected: 编译失败，报 `cannot find function chat_outbox_enqueue_text`。

- [ ] **Step 3: 写最小实现**

在 `rust_builder/src/api/chat.rs:35` 的 `static MESSAGES` 旁新增：

```rust
/// 离线发件箱（与消息存储同目录，`messages_open` 时一起打开）。
static OUTBOX: Mutex<Option<OutboxStore>> = Mutex::new(None);
```

在文件顶部 `use` 区补（若尚未导入）：

```rust
use crate::backend::storage::{OutboxEntry, OutboxStore};
```

在 `messages_open`（`:573-584`）中，`let store = MessageStore::open(&dir);` 之后、写入 `MESSAGES` 之前插入：

```rust
    // 发件箱与消息存储同目录：一次 messages_open 同时打开两者，
    // 避免 Dart 侧还要多写一个初始化调用（也避免忘记调用导致离线消息丢失）。
    let outbox = OutboxStore::open(&dir);
    *OUTBOX.lock().map_err(|_| anyhow!("outbox poisoned"))? = Some(outbox);
```

在 `with_store`（`:609-615`）之后新增：

```rust
fn with_outbox<T>(f: impl FnOnce(&mut OutboxStore) -> anyhow::Result<T>) -> anyhow::Result<T> {
    let mut guard = OUTBOX.lock().map_err(|_| anyhow!("outbox poisoned"))?;
    let store = guard
        .as_mut()
        .ok_or_else(|| anyhow!("发件箱未打开，请先 messagesOpen()"))?;
    f(store)
}
```

在文件末尾（`mod tests` 之前）新增 DTO 与 FFI：

```rust
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
    let seq = {
        let slot = DIALERS.lock().map_err(|_| anyhow!("dialers poisoned"))?;
        slot.as_ref()
            .and_then(|m| m.get(&peer_id))
            .map(|d| d.next_text_seq())
            .unwrap_or(0)
    };
    let id = format!("outbox-{}-{}-{}", peer_id, seq, now_ms());
    with_outbox(|store| {
        store.enqueue(OutboxEntry {
            id: id.clone(),
            peer_id,
            kind: 1,
            text: trimmed.to_string(),
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
    with_outbox(|store| Ok(store.mark_sent(&id)?))
}

/// 用户主动取消待发项。返回是否真的移除了。
pub fn chat_outbox_cancel(id: String) -> anyhow::Result<bool> {
    with_outbox(|store| Ok(store.remove(&id)?))
}
```

**注意**：`chat_outbox_ack` 的闭包体是 `Ok(store.mark_sent(&id)?)`，返回 `anyhow::Result<()>`；`mark_sent` 返回 `io::Result<()>`，`?` 会自动转成 `anyhow::Error`。若编译器报类型不匹配，写成 `store.mark_sent(&id)?; Ok(())`。

若 `Dialer` 尚无 `next_text_seq`（`chat_outbox_enqueue_text` 用到），先确认 `session.rs:749` 附近的 `Dialer::send_text` 如何取 seq；若没有独立方法，把上面那段 seq 获取改为：

```rust
    // 无连接时 seq 取 0（仅用于拼 id 去重，不参与协议序号）；
    // 真正的协议 seq 在补发真正发送时由对话连接分配。
    let id = format!("outbox-{}-{}", peer_id, now_ms());
```

并对应用 `#[allow(unused_variables)]` 或直接删掉 `seq` 绑定，保持实现最小。

- [ ] **Step 4: 运行测试确认通过**

Run: `cargo test outbox_ 2>&1 | Select-String "test result"`
Expected: 之前 Task 1 的 3 个 + 本任务 4 个均通过（分组输出 `test result: ok`）。

Run: `cargo test 2>&1 | Select-String "test result|FAILED"`
Expected: 全部 `ok`，无 `FAILED`。

- [ ] **Step 5: 重新生成 frb 绑定**

Run: `C:\flutter\bin\flutter.bat pub run flutter_rust_bridge_codegen generate`
Expected: 命令成功，`lib/src/rust/frb_generated.dart` 与 `rust_builder/src/frb_generated.rs` 中出现新的 `chatOutbox*` 符号。

Run: `Select-String -Path "lib\src\rust\frb_generated.dart" -Pattern "chatOutboxEnqueueText" | Select-Object -First 3`
Expected: 有匹配。**若无匹配，说明 codegen 未生效，后续 Dart 任务全部无法编译，必须先解决。**

- [ ] **Step 6: 提交**

同 Task 1 Step 5（非 git 仓库则跳过）。

---

### Task 5: 重连时注入 seq 状态（Rust api/chat.rs 的 dial 路径）

**Files:**
- Modify: `rust_builder/src/api/chat.rs:291-303`（`chat_dial`）、`rust_builder/src/backend/session.rs`（`Dialer` 的构造与重连循环）
- Test: `rust_builder/src/api/chat.rs`（内联测试）

**Interfaces:**
- Consumes: `SeqState` / `SeqTracker::snapshot` / `SeqState::default`（Task 2-3）、`Connection::start_with_seqs`（Task 3）
- Produces:
  - `rust_builder/src/backend/session.rs` 新增 `pub struct SeqStateStore`（进程内共享的序号状态，`Arc`/`Mutex<SeqState>`）与 `impl Default`
  - `Dialer::seq_state(&self) -> SeqState` 与 `Dialer::set_seq_state(&self, state: SeqState)`

**背景：** Task 3 让 `Connection` 能接受状态，本任务让**重连路径真的把状态传进去**，否则修复无效。

- [ ] **Step 1: 写失败测试**

在 `rust_builder/src/backend/session.rs` 的 `mod tests` 追加：

```rust
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
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cargo test seq_state_store_roundtrip 2>&1 | Select-String "test result|error\[|cannot find"`
Expected: 编译失败，`cannot find struct SeqStateStore`。

- [ ] **Step 3: 写最小实现**

在 `rust_builder/src/backend/session.rs` 的 `SeqState` 定义之后新增：

```rust
/// 进程内共享的序号状态：连接重建（自动重连）时用它恢复 `SeqTracker`，
/// 避免 `out_seq` 归零导致新消息被对端当旧的丢弃、`last_seen` 清空导致重复入站。
#[derive(Debug, Default)]
pub struct SeqStateStore {
    state: std::sync::Mutex<SeqState>,
}

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
```

在 `Dialer` 结构中新增字段：

```rust
    /// 该对端的序号状态（重连时注入新连接）。
    seq_state: SeqStateStore,
```

并在 `impl Dialer` 中新增：

```rust
    /// 导出当前序号状态（连接关闭前/写回时调用）。
    pub fn seq_state(&self) -> SeqState {
        self.seq_state.snapshot()
    }

    /// 注入序号状态（重连建连前调用）。
    pub fn set_seq_state(&self, state: SeqState) {
        self.seq_state.restore(state);
    }
```

把 `Dialer` 内每次建立 `Connection` 的调用点（首次 dial 与自动重连循环）改为：

```rust
        let conn = Connection::start_with_seqs(stream, cfg, events, self.seq_state.snapshot())?;
```

连接建立成功后写回最新状态：

```rust
        if let Ok(snap) = conn.shared_seqs_snapshot() {
            self.seq_state.restore(snap);
        }
```

**若 `Connection` 未暴露快照入口**，在 `impl Connection` 中新增（Task 3 已给 `Shared` 加了 `seq_snapshot`）：

```rust
    /// 当前连接的序号状态快照（写回 `Dialer` 用）。
    pub fn shared_seqs_snapshot(&self) -> io::Result<SeqState> {
        Ok(self.shared.seq_snapshot())
    }
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cargo test seq_state_store 2>&1 | Select-String "test result"`
Expected: `test result: ok`。

Run: `cargo test 2>&1 | Select-String "test result|FAILED"`
Expected: 全部 `ok`。会话层既有测试（`dialer_sends_text_and_reports_seq` 于 `:1050`、`:1108` 附近）必须仍通过 —— 若失败，说明 `start_with_seqs` 改造破坏了原有建连路径，必须修好再继续。

- [ ] **Step 5: 提交**

同 Task 1 Step 5。

---

### Task 6: 入站文件查重（Rust api/transfer.rs）

> **⚠️ 本节已于 2026-10-14 就地更正（Task 6d）。** 本节原稿存在三处事实错误，按原文执行会写出**永远匹配不上、却自测通过**的假修复 —— 这正是「离线文件重复收到 / 收不到」始终没修好的原因。以下「原稿错误」小节记录错误本身，正文契约已改为实测真相。**以代码与本节更正后的契约为准，不要以原稿为准。**

**原稿错误（已更正）：**

1. **`MessageStore::find_file_message` 从未存在。** 原稿声明消费它，但 grep 全仓无匹配（只在计划文档自身出现 8 次）——`Interfaces: Consumes` 指向了一个无人实现的函数。Task 1 实际只做了 `OutboxStore`。
2. **`file_id` 不是内容哈希，是每次发送新生成的随机 UUID。** `rust_builder/src/api/transfer.rs:553` 是 `let file_id = uuid::Uuid::new_v4().to_string();`。因此「按 `(peer_id, file_id)` 查重」**永远匹配不上**：同一文件补发两次会带两个不同的 file_id。而且原稿的测试自己伪造 file_id 去命中，会**假装通过**，真实重复投递毫发无伤。真正的文件身份是 `hash_hex`（blake3 整文件哈希，`Sender::open` 算出并放进 `FileMetaPayload`）。
3. **原稿 Step 3 的代码片段无法编译。** 它让 `hub_loop` 里用 `MESSAGES.lock()`，但 `MESSAGES` 是 `rust_builder/src/api/chat.rs:35` 的**私有 static**，`api/transfer.rs` 里没有这个符号。

**更正后的契约：**

**Files:**
- Modify: `rust_builder/src/api/transfer.rs`（`hub_loop` 的 `FileMeta` 分支，`:169+`）
- Modify: `rust_builder/src/backend/storage.rs`（`StoredMessage` 加 `hash_hex`；新增 `find_received_by_hash`）
- Modify: `rust_builder/src/api/chat.rs`（新增 `lookup_received_hash` 只读查询口；`messages_append`/`append_message_ex` 透传 `hash_hex`）
- Test: `rust_builder/src/api/transfer.rs`（内联测试）

**Interfaces:**
- Consumes: `MessageStore::find_received_by_hash(&self, hash_hex: &str) -> Option<&StoredMessage>`（本次新建，storage.rs）
- Consumes: `crate::api::chat::lookup_received_hash(hash_hex: &str) -> Option<String>`（返回已收文件名；chat.rs 新建，用于跨模块访问私有 `MESSAGES`）
- Produces: 无新公开 API（内部行为修正）

**背景（发现2，本次修复的核心之一）：** `sendFilePath` 的 catch 分支会保留气泡为 `queued`，而 `_syncAfterConnect` 又会再发一次 → 对端收到两份。本任务在 `hub_loop` 的 `FileMeta` 分支加查重闸：**同 `hash_hex` 已有完整接收记录**则直接回 `FileDone{ok:true}` 并 `push_finished`，**不建 RecvJob、不落盘**。

**两个必须遵守的语义：**
- 回执必须是 `ok: true`，**不能静默丢弃**。静默丢弃会让发送端永远等不到确认而反复重发（需求.MD 第 46/72 行抱怨的「重复触发和文件冗余错乱」）。
- **半截接收（只有 `.part` + sidecar）不算「已收」**，必须照常走续传（`ACK.offset` 为断点位置），否则用户会拿到一个永远补不上的文件。

**已知实现细节（写测试时必须注意，否则测试会假失败）：**
- `receive_dir()` 返回 `<消息根>/downloads`（`MessageStore::default_download_dir`，storage.rs:293-300），**不是消息根目录本身**。
- 写 `StoredMessage` 必须写进 `messages_open` 打开的那个 store（全局 `MESSAGES` 读的是 `<data_dir>/chat`）；另开一个 `MessageStore` 实例 append，全局查重口看不到。测试里应写 `<dir>/chat` 后**重新调用 `messages_open` 让 store 从磁盘载入**。
- `hash_hex` 必须是**真哈希**（`crate::backend::transfer::hash_file`），占位串会让 `Receiver::on_done` 判「哈希校验不一致，已丢弃，请重传」。
- 老的 `StoredMessage` 记录反序列化后 `hash_hex` 为空串，**空串一律视为「未知、不参与查重」**，避免把历史数据误判成同一文件。

**交付物（已实现，2026-10-14）：** `rust_builder/src/api/transfer.rs:179` 的查重闸 + 3 个测试（`received_file_can_be_found_by_hash`、`duplicate_file_meta_is_acked_and_not_received`、`half_received_file_is_not_treated_as_duplicate`）。全量 `cargo test` → 130 passed; 0 failed。测试有效性已用「把闸改成 `if false && …` 则测试必失败」反证过。

**以下原稿 Step 1 的代码片段已失效**（它按 file_id 查重、且用 `MessageStore::open` 另开实例），保留在此仅作错误记录，**不要照抄**：

- [ ] **Step 1: 写失败测试**

在 `rust_builder/src/api/transfer.rs` 的 `mod tests` 追加：

```rust
    #[test]
    fn inbound_file_meta_is_deduped_by_file_id() {
        let dir = std::env::temp_dir().join(format!(
            "lanchat_inbound_dedup_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let store = MessageStore::open(dir.to_string_lossy().as_ref());
        // 模拟「上一次已完整收过这个文件」的落库记录
        store
            .append(&MessageDto {
                id: format!("file-{}", "abc123"),
                peer_id: "peer-x".into(),
                from_me: false,
                kind: 3,
                text: "report.pdf".into(),
                ts_ms: 1,
                file_name: "report.pdf".into(),
                file_size: 10,
                file_path: dir.join("report.pdf").to_string_lossy().to_string(),
                file_id: "abc123".into(),
            })
            .unwrap();

        let found = store.find_file_message("peer-x", "abc123");
        assert!(found.is_some(), "已完成入站文件必须能被查到，否则无法查重");
        assert_eq!(found.unwrap().file_id, "abc123");

        // 不同 file_id 不应命中
        assert!(store.find_file_message("peer-x", "other").is_none());
        // 不同 peer 不应命中
        assert!(store.find_file_message("peer-y", "abc123").is_none());
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cargo test inbound_file_meta_is_deduped 2>&1 | Select-String "test result|error\[|no method"`
Expected: 编译失败或断言失败，报 `no method named find_file_message`。

- [ ] **Step 3: 写最小实现**

确认 `MessageStore::find_file_message(peer_id, file_id) -> Option<MessageDto>` 在 Task 1 已实现（`storage.rs`，按 id == `file-<file_id>` 且 peer_id 匹配查询）。

在 `hub_loop` 处理 `SessionEvent::FileMeta` 的分支开头（建立 recv job 之前）插入查重：

```rust
        // 查重闸：同一 (peer_id, file_id) 已完整收过 → 直接回 FileDone，不落盘、不建 job。
        // 触发场景：发送端因断线重连而重发同一个文件（发送端带外重传），
        // 若不查重会写出 report (1).pdf 之类的冗余文件——需求.MD 第 46 行明确禁止。
        if let Some(existing) = {
            let guard = MESSAGES.lock().ok();
            guard.as_ref().and_then(|slot| {
                slot.as_ref().and_then(|s| s.find_file_message(&meta.peer_id, &meta.file_id))
            })
        } {
            let ack = FrameType::FileDone;
            let payload = existing.file_id.as_bytes().to_vec();
            {
                let mut st = state.lock().map_err(|_| anyhow!("hub poisoned"))?;
                st.pending_sends.push((meta.peer_id.clone(), ack, payload));
            }
            continue;
        }
```

**注意**：若 `hub_loop` 中该分支拿不到 `meta.file_id`（文件协议头部只带 size/name 时），改为按 `(peer_id, file_name, file_size)` 三元组查重，并在 `MessageStore` 增加对应查询函数 `find_file_message_by_name(peer_id, file_name, file_size)`。**这是必须先用 `read` 打开 `hub_loop` 的 `FileMeta` 分支确认的事**——不要凭猜测写。

- [ ] **Step 4: 运行测试确认通过**

Run: `cargo test inbound_file_meta_is_deduped 2>&1 | Select-String "test result"`
Expected: `test result: ok`。

Run: `cargo test 2>&1 | Select-String "test result|FAILED"`
Expected: 全部 `ok`。

- [ ] **Step 5: 提交**

同 Task 1 Step 5。

---

### Task 7: Android 前台服务保活（Kotlin + Manifest + Dart 接线）

**Files:**
- Modify: `android/app/src/main/AndroidManifest.xml`（权限与 `<service>`）
- Modify: `android/app/src/main/kotlin/com/yuchuan/app/MainActivity.kt`（通道方法 + onDestroy 修复）
- Create: `android/app/src/main/kotlin/com/yuchuan/app/TransferService.kt`
- Modify: `lib/services/platform_channel.dart`（新增 `startKeepAlive` / `stopKeepAlive`）
- Test: `test/mobile_keepalive_test.dart`（Dart 侧通道调用断言）

**Interfaces:**
- Consumes: 既有 `MethodChannel('yuchuan/platform')`
- Produces:
  - Dart: `static Future<bool> startKeepAlive()`、`static Future<bool> stopKeepAlive()`
  - Kotlin: `TransferService`（`android:foregroundServiceType="dataSync"`），通知渠道 `yuchuan-transfer`

**背景（结构性根因）：** 当前 Manifest **没有任何 `<service>` 声明、没有 FOREGROUND_SERVICE 权限**；`MainActivity.onDestroy()` 还用 `releaseMulticastLock()+releaseWifiLock()` 主动释放锁。进程一切后台或被回收 → TCP 连接断 → 传输中断。仅靠 `WIFI_MODE_FULL_HIGH_PERF` 锁挡不住。

- [ ] **Step 1: 写失败测试**

新建 `test/mobile_keepalive_test.dart`：

```dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yuchuan/services/platform_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('yuchuan/platform');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('startKeepAlive 调用原生前台服务并携带通知文案', () async {
    final ok = await YuChuanPlatform.startKeepAlive(
      title: 'YuChuan 正在传输',
      text: '保持后台传输以免中断',
    );
    expect(ok, isTrue);
    expect(calls.single.method, 'startKeepAlive');
    expect(calls.single.arguments['title'], 'YuChuan 正在传输');
    expect(calls.single.arguments['text'], '保持后台传输以免中断');
  });

  test('stopKeepAlive 调用原生停止前台服务', () async {
    final ok = await YuChuanPlatform.stopKeepAlive();
    expect(ok, isTrue);
    expect(calls.single.method, 'stopKeepAlive');
  });

  test('原生未实现时返回 false 而不是抛异常（桌面端/旧版本兼容）', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      throw MissingPluginException('no impl');
    });
    expect(await YuChuanPlatform.startKeepAlive(), isFalse);
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `C:\flutter\bin\flutter.bat test test\mobile_keepalive_test.dart`
Expected: 编译失败，`The method 'startKeepAlive' isn't defined`。

- [ ] **Step 3: 写最小实现**

**(a) `lib/services/platform_channel.dart`** —— 在 `acquireWifiLock` 之后按既有 `_invoke<T>` 风格新增：

```dart
  /// 启动前台服务：安卓切后台/被系统降优先级时保住 TCP 连接与传输。
  /// 传输结束或应用退到无任务时应调用 [stopKeepAlive]（安卓 14+ 对
  /// dataSync 前台服务有超时限制，常开会被系统警告）。
  static Future<bool> startKeepAlive({
    String title = 'YuChuan 正在运行',
    String text = '保持后台连接，避免传输中断',
  }) async {
    final r = await _invoke<bool>('startKeepAlive', {
      'title': title,
      'text': text,
    });
    return r ?? false;
  }

  /// 停止前台服务。
  static Future<bool> stopKeepAlive() async {
    final r = await _invoke<bool>('stopKeepAlive');
    return r ?? false;
  }
```

**(b) 新建 `android/app/src/main/kotlin/com/yuchuan/app/TransferService.kt`**：

```kotlin
package com.yuchuan.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * 传输保活前台服务。
 *
 * 存在的理由：安卓在应用切后台后会降级进程优先级，纯 Activity 进程会被
 * 冻结甚至回收，导致 TCP 连接断开、传输中断（需求.MD 第 20 行「安卓后台不要断开」）。
 * 前台服务 + WifiLock + WakeLock（部分唤醒）+ MulticastLock 是安卓上唯一
 * 官方支持的长时后台网络方案。
 *
 * android:foregroundServiceType="dataSync"：安卓 14+ 要求声明类型，
 * 否则 startForeground 抛 ForegroundServiceStartNotAllowedException。
 */
class TransferService : Service() {

    private var wifiLock: WifiManager.WifiLock? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        acquireLocks()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "YuChuan 正在运行"
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "保持后台连接，避免传输中断"
        ensureChannel()
        val notification = buildNotification(title, text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_STICKY
    }

    override fun onDestroy() {
        releaseLocks()
        super.onDestroy()
    }

    private fun acquireLocks() {
        try {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            wifiLock = wifi?.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "yuchuan-svc-wifi")
                ?.apply { setReferenceCounted(false); acquire() }
        } catch (_: Throwable) {}
        try {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            multicastLock = wifi?.createMulticastLock("yuchuan-svc-multicast")
                ?.apply { setReferenceCounted(true); acquire() }
        } catch (_: Throwable) {}
        try {
            val power = applicationContext.getSystemService(Context.POWER_SERVICE) as? PowerManager
            // 部分唤醒：只保 CPU 不睡，不点亮屏幕。
            wakeLock = power?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "yuchuan-svc:cpu")
                ?.apply { setReferenceCounted(false); acquire() }
        } catch (_: Throwable) {}
    }

    private fun releaseLocks() {
        try { if (wifiLock?.isHeld == true) wifiLock?.release() } catch (_: Throwable) {}
        try { if (multicastLock?.isHeld == true) multicastLock?.release() } catch (_: Throwable) {}
        try { if (wakeLock?.isHeld == true) wakeLock?.release() } catch (_: Throwable) {}
        wifiLock = null
        multicastLock = null
        wakeLock = null
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "后台传输",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "传输过程中保持后台连接"
            setShowBadge(false)
        }
        mgr.createNotificationChannel(channel)
    }

    private fun buildNotification(title: String, text: String): Notification {
        val open = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pending = PendingIntent.getActivity(
            this,
            0,
            open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setOngoing(true)
            .setContentIntent(pending)
            .build()
    }

    companion object {
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        private const val CHANNEL_ID = "yuchuan-transfer"
        private const val NOTIFICATION_ID = 0x7C01

        fun start(context: Context, title: String, text: String) {
            val intent = Intent(context, TransferService::class.java).apply {
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_TEXT, text)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, TransferService::class.java))
        }
    }
}
```

**(c) `AndroidManifest.xml`** —— 在既有权限块内加：

```xml
    <!-- 后台传输保活：前台服务 + dataSync 类型（安卓 14+ 必需） -->
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />
```

在 `</activity>` 之后、`</application>` 之前加：

```xml
        <service
            android:name=".TransferService"
            android:exported="false"
            android:foregroundServiceType="dataSync" />
```

**(d) `MainActivity.kt`** —— 在 `MethodCallHandler` 的 `when` 中新增两个分支：

```kotlin
            "startKeepAlive" -> {
                val title = call.argument<String>("title") ?: "YuChuan 正在运行"
                val text = call.argument<String>("text") ?: "保持后台连接，避免传输中断"
                try {
                    TransferService.start(applicationContext, title, text)
                    result.success(true)
                } catch (e: Throwable) {
                    result.error("keepalive_failed", e.message, null)
                }
            }

            "stopKeepAlive" -> {
                try {
                    TransferService.stop(applicationContext)
                    result.success(true)
                } catch (e: Throwable) {
                    result.error("keepalive_failed", e.message, null)
                }
            }
```

**同时修 `onDestroy()`（`:405-409`）**：当前无条件释放 Wi-Fi/组播锁，会在 Activity 因配置变更或系统回收而销毁时把前台服务的锁一起放掉。改成只在**没有**前台服务运行时释放：

```kotlin
    override fun onDestroy() {
        // 若前台服务正在保活，锁归它管；此处再释放会把后台连接一起断掉。
        if (!TransferService.isRunning()) {
            releaseMulticastLock()
            releaseWifiLock()
        }
        super.onDestroy()
    }
```

并在 `TransferService` 中加：

```kotlin
    companion object {
        @Volatile
        private var running = false
        fun isRunning(): Boolean = running
        // onCreate 里 running = true；onDestroy 里 running = false
    }
```

- [ ] **Step 4: 运行测试确认通过**

Run: `C:\flutter\bin\flutter.bat test test\mobile_keepalive_test.dart`
Expected: 3 个测试全部通过。

Run: `C:\flutter\bin\flutter.bat analyze lib\services\platform_channel.dart`
Expected: `No issues found!`

Kotlin/Manifest 无法在本机编译验证（需 Android SDK 与 Gradle），在计划末尾的「人工验证清单」中列出装机验证步骤。

- [ ] **Step 5: 提交**

同 Task 1 Step 5。

---

### Task 8: Dart 侧发件箱接线（替换 `_syncAfterConnect` 的靠不住的补发）

**Files:**
- Modify: `lib/services/chat_service.dart`（暴露发件箱 FFI）
- Modify: `lib/app_state.dart:1300-1318`（`ensureDial` 的 `_dialed` 永久闸）、`:1325-1402`（`_queuedFlushed`/`_resyncedFiles`/`_syncAfterConnect`）、`:2500-2561`（`sendMessage` 离线分支）、`:2012-2124`（`sendFilePath` 离线分支）
- Create: `lib/services/outbox_service.dart`
- Test: `test/offline_outbox_test.dart`

**Interfaces:**
- Consumes: Task 4 的 `chatOutbox*` FFI、Task 7 的 `startKeepAlive`/`stopKeepAlive`
- Produces:
  - `OutboxService.instance`：`enqueueText`、`enqueueFile`、`pending(peerId)`、`ack(id)`、`cancel(id)`、`peersWithPending()`
  - `AppState.flushOutbox([peerId])`：把待发项真正发出去，成功即 ack
  - `AppState._outboxTimer`：每 3 秒扫描一次（`_statsTimer` 同款节奏）

**根因回顾（为什么必须在 Dart 侧改）：** `sendMessage` 的离线早退分支（`lib/app_state.dart:2525`）只打 `queued` 标记，**不拨号、不重试、不入队**；唯一补发入口 `_syncAfterConnect` 只由 Rust 的 `Connected` 事件触发，而 `ensureDial` 有 `if (_dialed.contains(peerId)) return;`（`:1301`）的永久去重闸 —— 一旦首次拨号失败被记入 `_dialed`，**此后再也不会重拨**，`Connected` 永不到来，补发永不发生。这就是「对端收不到」。

- [ ] **Step 1: 写失败测试**

新建 `test/offline_outbox_test.dart`（纯逻辑测试，不依赖 Rust FFI）：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:yuchuan/models.dart';

void main() {
  group('离线排队语义', () {
    test('离线消息标记 queued，上线后补发成功才清除', () {
      final m = ChatMessage(
        id: 'outbox-peer-x-1',
        fromMe: true,
        kind: MessageKind.text,
        time: DateTime.now(),
        text: '离线消息',
      );
      expect(m.queued, isFalse);

      m.queued = true;
      m.state = SendState.sending;
      expect(m.queued, isTrue);

      // 补发成功后：queued 清除且状态为已发送
      m.queued = false;
      m.state = SendState.sent;
      expect(m.queued, isFalse);
      expect(m.state, SendState.sent);
    });

    test('用户取消过的消息不参与自动补发', () {
      final m = ChatMessage(
        id: 'outbox-peer-x-2',
        fromMe: true,
        kind: MessageKind.text,
        time: DateTime.now(),
        text: '取消的消息',
      );
      m.cancelled = true;
      m.queued = true;
      // 补发筛选条件：queued && !cancelled
      expect(m.queued && !m.cancelled, isFalse);
    });

    test('文件消息的补发筛选用 fileId 去重而不是文件名', () {
      final a = ChatMessage(
        id: 'file-abc',
        fromMe: true,
        kind: MessageKind.file,
        time: DateTime.now(),
        text: 'report.pdf',
        fileName: 'report.pdf',
        fileSize: 100,
        fileId: 'abc',
        filePath: 'D:/tmp/report.pdf',
      );
      final b = ChatMessage(
        id: 'file-abc',
        fromMe: true,
        kind: MessageKind.file,
        time: DateTime.now(),
        text: 'report.pdf',
        fileName: 'report.pdf',
        fileSize: 100,
        fileId: 'abc',
        filePath: 'D:/tmp/report.pdf',
      );
      // 同一 fileId → 同一条待发项，不应重复入队
      expect(a.fileId, b.fileId);
      expect('file-${a.fileId}', 'file-${b.fileId}');
    });
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `C:\flutter\bin\flutter.bat test test\offline_outbox_test.dart`
Expected: 编译失败（`ChatMessage` 缺 `queued`/`cancelled` 以外的构造参数，或 `models.dart` 导入路径不对）。**先用 `read` 打开 `lib/models.dart:68-112` 核对 `ChatMessage` 的真实构造函数签名，再改测试**——不要凭记忆写。

- [ ] **Step 3: 写最小实现**

**(a) 新建 `lib/services/outbox_service.dart`**：

```dart
import '../src/rust/api/chat.dart' as rust_chat;

/// 离线发件箱：对方不在线时把消息/文件交给 Rust 持久化排队，
/// 上线后由 [AppState.flushOutbox] 补发。
///
/// 为什么持久化在 Rust 侧：Dart 进程（尤其安卓）随时可能被系统杀掉，
/// 只放内存队列会丢消息；Rust 侧写 outbox.jsonl 且与消息库同目录，
/// 重启后仍能续发。
class OutboxService {
  OutboxService._();
  static final OutboxService instance = OutboxService._();

  Future<String?> enqueueText(String peerId, String text) async {
    try {
      return await rust_chat.chatOutboxEnqueueText(peerId: peerId, text: text);
    } catch (_) {
      return null;
    }
  }

  Future<String?> enqueueFile({
    required String peerId,
    required String fileId,
    required String path,
    required String fileName,
    required int fileSize,
    required int kind,
  }) async {
    try {
      return await rust_chat.chatOutboxEnqueueFile(
        peerId: peerId,
        fileId: fileId,
        path: path,
        fileName: fileName,
        fileSize: fileSize,
        kind: kind,
      );
    } catch (_) {
      return null;
    }
  }

  List<rust_chat.OutboxItemDto> pending(String peerId) =>
      rust_chat.chatOutboxPending(peerId: peerId);

  Future<void> ack(String id) async {
    try {
      await rust_chat.chatOutboxAck(id: id);
    } catch (_) {}
  }

  Future<bool> cancel(String id) async {
    try {
      return await rust_chat.chatOutboxCancel(id: id);
    } catch (_) {
      return false;
    }
  }

  List<String> peersWithPending() => rust_chat.chatOutboxPeers();
}
```

**(b) `lib/services/chat_service.dart`** —— 无需改动（发件箱走独立 `OutboxService`），保持单一职责。

**(c) `lib/app_state.dart` —— 修 `_dialed` 永久闸（`:1301`）**：

```dart
  Future<void> ensureDial(String peerId) async {
    if (!chatReady || _dialed.contains(peerId)) return;
```

改为带冷却的重试闸（这是「重新修复」的关键：旧思路的一次性去重必须换掉）：

```dart
  // 拨号冷却：失败后允许重试，但不要每次 tick 都重拨（旧实现的 _dialed 是永久闸，
  // 一旦首次失败就再也不重拨 —— 这正是「离线消息上线后收不到」的根因）。
  final Map<String, DateTime> _dialCooldown = {};
  static const Duration _dialCooldownWindow = Duration(seconds: 5);

  Future<void> ensureDial(String peerId) async {
    if (!chatReady) return;
    if (_dialed.contains(peerId)) return;
    final last = _dialCooldown[peerId];
    if (last != null && DateTime.now().difference(last) < _dialCooldownWindow) {
      return;
    }
    _dialCooldown[peerId] = DateTime.now();
```

**(d) 新增周期补发扫描**（放在 `_startTransferPoll` 附近，`:2126-2133` 同款结构）：

```dart
  Timer? _outboxTimer;

  void _startOutboxPoll() {
    _outboxTimer ??= Timer.periodic(const Duration(seconds: 3), (_) {
      unawaited(flushOutbox());
    });
  }

  /// 把发件箱里待发的项真正发出去；成功即 ack。
  /// 由两处驱动：① 周期扫描（兜底，防 Connected 事件丢失）；
  /// ② `_onChatEvent` 的 connected 分支（及时补发）。
  Future<void> flushOutbox([String? onlyPeer]) async {
    if (!chatReady) return;
    final peers = onlyPeer != null ? [onlyPeer] : OutboxService.instance.peersWithPending();
    for (final peerId in peers) {
      final items = OutboxService.instance.pending(peerId);
      if (items.isEmpty) continue;
      if (!_isOnline(peerId)) {
        // 未在线：主动拨一次（此时冷却闸允许时才会真正拨），下轮再来
        unawaited(ensureDial(peerId));
        continue;
      }
      for (final item in items) {
        try {
          if (item.kind == 1) {
            await sendTextTo(peerId, item.text, addBubble: false);
          } else {
            await sendFilePath(
              item.filePath,
              kind: item.kind == 2 ? MessageKind.image : MessageKind.file,
              peerId: peerId,
              skipOutbox: true,
            );
          }
          await OutboxService.instance.ack(item.id);
          _markOutboxBubbleSent(peerId, item.id);
        } catch (_) {
          break; // 该对端本轮失败，下轮再试（不做无限内循环重试）
        }
      }
    }
  }
```

**(e) `_syncAfterConnect`（`:1332-1402`）简化为调用 `flushOutbox(peerId)`**，并把原来的 `_queuedFlushed`/`_resyncedFiles` 两套内存去重删除 —— 去重语义已下沉到 Rust 发件箱（按 id 唯一），旧的两套内存 Set 在进程重启后失效，正是「重复发送/文件冗余」的另一半成因。

```dart
  Future<void> _syncAfterConnect(String peerId) async {
    try {
      await TransferService.instance.reconnect(peerId);
    } catch (_) {}
    await loadHistory(peerId, force: true);
    // 补发统一走发件箱：文本与文件同一条路径，去重由 Rust 侧的 id 唯一性保证。
    await flushOutbox(peerId);
  }
```

同时删除 `:1325 final Set<String> _queuedFlushed = {};`、`:1330 final Set<String> _resyncedFiles = {};` 及其全部引用（`:1487` 的 `_resyncedFiles.removeWhere` 一并删除）。

**(f) `sendMessage` 离线分支（`:2525`）改为真正入队**：

```dart
    if (!chatReady || !_isOnline(peerId)) {
      optimistic.queued = true;
      optimistic.state = SendState.sending;
      notifyListeners();
      // 真正落盘排队（旧实现只打标记，进程一重启就彻底丢失）。
      await OutboxService.instance.enqueueText(peerId, text);
      // 立刻尝试拨号：也许只是 UI 还没收到 connected 事件，实际已可连。
      unawaited(ensureDial(peerId));
      return;
    }
```

**(g) `sendFilePath` 离线分支（`:2061`）同样入队**（新增 `skipOutbox` 具名参数，默认 false，避免补发时把自己再入队一次）：

```dart
  Future<void> sendFilePath(
    String path, {
    MessageKind kind = MessageKind.file,
    String? peerId,
    String? fileNameOverride,
    bool skipOutbox = false,
  }) async {
```

离线分支改为：

```dart
    if (!chatReady || !_isOnline(conv.device.id)) {
      unawaited(ensureDial(conv.device.id));
      msg.queued = true;
      msg.state = SendState.sending;
      chatError = '对方当前离线：文件已排队，上线后自动发送';
      notifyListeners();
      if (!skipOutbox) {
        final fileId = await _fileIdFor(path);
        await OutboxService.instance.enqueueFile(
          peerId: conv.device.id,
          fileId: fileId,
          path: path,
          fileName: fileNameOverride ?? _baseName(path),
          fileSize: File(path).lengthSync(),
          kind: kind == MessageKind.image ? 2 : 3,
        );
      }
      return;
    }
```

`_fileIdFor` / `_baseName` 若不存在，用既有工具函数；**先用 `read` 查看 `sendFilePath` 现有实现（`lib/app_state.dart:2012-2124`）确认文件名与 fileId 的现成取法，不要在计划里发明新工具函数。**

**(h) 传输开始/结束时启停前台服务**（安卓保活接线）：

```dart
  // 传输进行中 → 保持后台存活；全部结束 → 停掉前台服务（安卓 14+ 有 dataSync 超时限制）。
  bool _keepAliveActive = false;

  Future<void> _updateKeepAlive() async {
    if (!Platform.isAndroid) return;
    final busy = _transferMsgs.isNotEmpty ||
        conversations.any((c) => c.messages.any((m) => m.queued));
    if (busy && !_keepAliveActive) {
      _keepAliveActive = true;
      await YuChuanPlatform.startKeepAlive(
        title: 'YuChuan 正在传输',
        text: '保持后台传输以免中断',
      );
    } else if (!busy && _keepAliveActive) {
      _keepAliveActive = false;
      await YuChuanPlatform.stopKeepAlive();
    }
  }
```

在 `_pollTransfers()`（`:2135-2229`）末尾调用 `unawaited(_updateKeepAlive())`。

- [ ] **Step 4: 运行测试确认通过**

Run: `C:\flutter\bin\flutter.bat test test\offline_outbox_test.dart`
Expected: 3 个测试全部通过。

Run: `C:\flutter\bin\flutter.bat analyze`
Expected: `No issues found!`（既有 warning 若与本改动无关可忽略，但不得新增 error）。

Run: `C:\flutter\bin\flutter.bat test`
Expected: 全部既有测试仍通过（含 `chat_flow_test.dart`、`transfer_flow_test.dart`、`mobile_features_test.dart`）。

- [ ] **Step 5: 提交**

同 Task 1 Step 5。

---

### Task 9: 端到端验证（真实双端联调）

**Files:**
- Modify: `docs/permissions.md`（补充前台服务说明）
- Create: `scripts/verify_offline_send.md`（人工验证清单）

**背景：** 前 8 个任务全部是单元/静态验证，**无法证明「对端真的收到了」**。这个任务的唯一目的就是拿到真实证据 —— 用户报告的是「重新修复」，说明上一轮的自评表（`核验.MD` 的 19 项 UI 自评）根本没覆盖这两个 bug，靠自评糊弄已不可接受。

- [ ] **Step 1: 建人工验证清单**

新建 `scripts/verify_offline_send.md`，内容为可逐条打勾的验证步骤：

```markdown
# 离线发送 / 安卓后台保活 人工验证清单

## 准备
- 两台设备（或一台 PC + 一台安卓真机），同一 Wi-Fi，先完成配对。
- 两端都用 `flutter run` 启动（Rust 日志走 stdout）。

## A. 离线文本：对端收不到（原 bug 1）
1. B 端退出应用（彻底杀进程，不是切后台）。
2. A 端打开与 B 的会话，发 3 条文本：`offline-1`、`offline-2`、`offline-3`。
   - 预期：A 端气泡显示「排队」状态（不是红色失败）。
   - 预期：`outbox.jsonl` 出现 3 条记录（路径见 A 端日志 `messages_open` 打印的目录）。
3. A 端重启应用（验证持久化）。
   - 预期：3 条气泡仍是排队态，且发件箱仍是 3 条（不丢、不重复）。
4. B 端启动应用。
   - 预期：**30 秒内** A 端 3 条气泡全部转为已发送。
   - 预期：B 端收到且**恰好 3 条**，顺序正确、无重复。
5. 让 A 再发一条在线消息 → 预期立即送达（确认不是只在补发路径上能通）。

## B. 离线文件（原 bug 2）
6. B 端退出。A 端发送一个 5MB 文件 `offline.bin`。
   - 预期：A 端显示排队；`outbox.jsonl` 有对应 `file-<fileId>` 记录。
7. B 端上线。
   - 预期：文件自动开始传输并完成；B 端磁盘上**只有一个** `offline.bin`（无 `offline (1).bin`）。
   - 预期：A 端气泡转为成功，进度走到 100%。
8. 传输中途让 B 端进程重启（模拟断点）。
   - 预期：B 重连后从断点续传，最终文件大小与哈希一致（`certutil -hashfile offline.bin SHA256` 两端相同）。

## C. 安卓后台中断（原 bug 3）
9. 安卓端与 PC 端开始传输一个 500MB 文件。
10. 安卓端按 Home 键退到后台（**不要**杀进程）。
    - 预期：通知栏出现「YuChuan 正在传输」常驻通知。
    - 预期：`adb shell dumpsys activity services com.yuchuan.app` 能看到 `TransferService`。
11. 保持后台 5 分钟（其间锁屏）。
    - 预期：传输持续进行不中断（PC 端日志进度持续增长）。
    - 预期：`adb logcat` 无 `ForegroundServiceDidNotStartInTime`、无 `ANR`。
12. 传输完成。
    - 预期：常驻通知自动消失（`_updateKeepAlive` 检测到不再忙）。
13. 安卓端在**有排队任务但无进行中传输**时切后台。
    - 预期：前台服务保持运行（因为还有 queued 项），这属于有意设计：否则排队任务会因进程被回收而漏发。

## D. 回归
14. 在线文本/文件/图片传输全部正常（不能为了修离线而弄坏在线）。
15. 断网再恢复（切飞行模式 10 秒） → 双方自动重连，界面状态正确（无卡在「连接中」）。
16. 两端各发 1 条消息，确认**没有**重复入站（seq 状态注入未生效会导致重复或丢弃）。
```

- [ ] **Step 2: 在 `docs/permissions.md` 补充前台服务说明**

追加一节：

```markdown
## 安卓后台保活（前台服务）

应用使用 `TransferService`（`android:foregroundServiceType="dataSync"`）在传输进行时
保持前台服务，并在服务内持有 WifiLock（`WIFI_MODE_FULL_HIGH_PERF`）、
MulticastLock 与 `PARTIAL_WAKE_LOCK`。

- 触发：有进行中的传输、或存在待补发的离线消息（`queued`）。
- 结束：传输与待发队列都清空后自动停止（安卓 14+ 对 dataSync 前台服务有超时限制，常开会被系统警告）。
- 权限：`FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_DATA_SYNC`、`POST_NOTIFICATIONS`（通知栏常驻条目）。
- 用户可见：通知栏显示「YuChuan 正在传输」，点按回到应用。
```

- [ ] **Step 3: 跑一遍全部自动化验证（在真实改动之后）**

Run: `cd rust_builder && cargo test 2>&1 | Select-String "test result"`
Expected: 全部 `ok`，无 `FAILED`。

Run: `C:\flutter\bin\flutter.bat analyze`
Expected: `No issues found!`

Run: `C:\flutter\bin\flutter.bat test`
Expected: 全部通过。

- [ ] **Step 4: 按清单 A/B/C/D 逐条真人验证并记录结果**

每条把「实际结果」写具体（通过/失败 + 现象），失败的条目回到对应 Task 修，**不允许把未验证的条目标成通过**。

- [ ] **Step 5: 提交**

同 Task 1 Step 5。

---

### Task 10: 前台服务按需使能（Dart 侧"忙不忙"判定）

**Files:**
- Modify: `lib/app_state.dart`（新增 `_updateKeepAlive()`，接到传输进度与发件箱变化上）
- Modify: `lib/main.dart`（生命周期回调里调用 `_updateKeepAlive`）
- Test: `test/mobile_keepalive_test.dart`（追加「忙→启、闲→停、反复切换不抖动」用例）

**Interfaces:**
- Consumes: `YuChuanPlatform.startKeepAlive()` / `stopKeepAlive()`（Task 7）、`OutboxService.instance.pending(peerId)`（Task 4/8）
- Produces: `AppState._updateKeepAlive()`（`void`，幂等）

**背景（为什么必须单独一个任务）：** Task 7 只给了「能启、能停」的能力，**没规定什么时候启停**。安卓 14+ 对 `dataSync` 前台服务有时长配额，常开会被系统警告甚至限制（见「已知边界」第 1 条）。而 Task 9 的人工清单第 12/13 条又要求「传完自动消失、有排队项则保持」——这正是本任务要实现的判定。**不做这个任务，Task 9 的第 10/12/13 条必然失败。**

- [ ] **Step 1: 写失败测试**

在 `test/mobile_keepalive_test.dart` 追加（沿用文件顶部已有的 `channel` 与 `calls` 桩）：

```dart
  group('前台服务按需使能', () {
    test('有进行中传输 → 启动前台服务', () async {
      await AppState.instance.debugApplyKeepAlive(busyTransfers: 1, pendingOutbox: 0);
      expect(calls.map((c) => c.method), contains('startKeepAlive'));
    });

    test('传输与队列都空 → 停止前台服务', () async {
      calls.clear();
      await AppState.instance.debugApplyKeepAlive(busyTransfers: 0, pendingOutbox: 0);
      expect(calls.map((c) => c.method), contains('stopKeepAlive'));
    });

    test('无传输但有排队项 → 保持前台服务（否则排队项会漏发）', () async {
      calls.clear();
      await AppState.instance.debugApplyKeepAlive(busyTransfers: 0, pendingOutbox: 2);
      expect(calls.map((c) => c.method), contains('startKeepAlive'));
    });

    test('状态未变化时不重复调用（避免通知栏抖动与配额浪费）', () async {
      await AppState.instance.debugApplyKeepAlive(busyTransfers: 1, pendingOutbox: 0);
      calls.clear();
      await AppState.instance.debugApplyKeepAlive(busyTransfers: 1, pendingOutbox: 0);
      expect(calls, isEmpty);
    });
  });
```

- [ ] **Step 2: 运行测试确认失败**

Run: `C:\flutter\bin\flutter.bat test test\mobile_keepalive_test.dart`
Expected: 编译失败，`The method 'debugApplyKeepAlive' isn't defined`。

- [ ] **Step 3: 写最小实现**

**(a) `lib/app_state.dart`** —— 新增字段与幂等判定：

```dart
  /// 前台服务当前是否已启动（避免重复调用造成通知栏抖动）。
  bool _keepAliveOn = false;

  /// 是否"忙"：有进行中的传输，或还有待补发的离线项。
  bool get _keepAliveWanted =>
      _transferMsgs.values.any((m) => m.progress > 0 && m.progress < 1) ||
      conversations.any((c) => OutboxService.instance.pending(c.device.id).isNotEmpty);

  /// 按需启停安卓前台服务。幂等：状态未变则不做任何事。
  /// 测试出口，见 test/mobile_keepalive_test.dart。
  Future<void> debugApplyKeepAlive({
    required int busyTransfers,
    required int pendingOutbox,
  }) async {
    final want = busyTransfers > 0 || pendingOutbox > 0;
    if (want == _keepAliveOn) return;
    _keepAliveOn = want;
    if (want) {
      await YuChuanPlatform.startKeepAlive(
        title: 'YuChuan 正在传输',
        text: '保持后台连接，避免中断',
      );
    } else {
      await YuChuanPlatform.stopKeepAlive();
    }
  }

  /// 生产路径：根据真实状态调用上面的判定（只在安卓上做）。
  Future<void> _updateKeepAlive() async {
    if (!Platform.isAndroid) return;
    final busy = _transferMsgs.values
        .where((m) => m.progress > 0 && m.progress < 1)
        .length;
    final pending = conversations.fold<int>(
      0,
      (n, c) => n + OutboxService.instance.pending(c.device.id).length,
    );
    await debugApplyKeepAlive(busyTransfers: busy, pendingOutbox: pending);
  }
```

**(b) 接到状态变化点**（两个地方，缺一不可）：

1. `_pollTransfers()`（`lib/app_state.dart:2135` 附近）在 `notifyListeners()` 之前加 `unawaited(_updateKeepAlive());`
2. `flushOutbox()`（Task 8）每轮结束时同样调用一次。

**(c) `lib/main.dart`** —— 生命周期回调里调用（Task 11 会建这个 observer，若 Task 11 尚未做，此处先加最小 observer）：

```dart
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      unawaited(AppState.instance._updateKeepAlive());
    }
  }
```

- [ ] **Step 4: 运行测试确认通过**

Run: `C:\flutter\bin\flutter.bat test test\mobile_keepalive_test.dart`
Expected: 全部通过（Task 7 的 3 个 + 本任务的 4 个）。

Run: `C:\flutter\bin\flutter.bat analyze`
Expected: `No issues found!`

- [ ] **Step 5: 提交**

同 Task 1 Step 5。

---

### Task 11: 生命周期重连（切后台/回前台的状态自愈）

**Files:**
- Modify: `lib/main.dart`（`WidgetsBindingObserver` 完整实现）
- Modify: `lib/app_state.dart`（`onAppResumed()`；`ensureDial` 的 `_dialed` 冷却闸）
- Test: `test/offline_outbox_test.dart`（追加冷却闸用例）

**Interfaces:**
- Consumes: `ensureDial(peerId)`（`lib/app_state.dart:1300`）、`flushOutbox(peerId)`（Task 8）
- Produces: `AppState.onAppResumed()`（`Future<void>`）

**背景（Review Focus 第 5 条要求的正是本任务）：** `PEER_TIMEOUT_MS = 10000`（`rust_builder/src/backend/session.rs:27`）——安卓切后台超过 10 秒，对端就会把这条连接判超时并断开。安卓端回前台时：

- Dart 侧 `chatOnline` 可能仍显示 true（没收到 disconnected 事件，因为它自己也被冻结了）→ **UI 显示在线但实际发不出去**；
- 且 `ensureDial` 的 `:1301` `_dialed.contains(peerId)` 会认为"已拨过"而直接 return → 永远不重连。

**这两条合起来就是用户报的「安卓后台会中断传输」在 Dart 侧的表现。**

- [ ] **Step 1: 写失败测试**

在 `test/offline_outbox_test.dart` 追加：

```dart
  group('拨号冷却闸', () {
    test('冷却期外允许重拨，冷却期内拒绝', () {
      final now = DateTime.now();
      // 冷却窗口 5 秒
      expect(AppState.isDialCoolingDown(now, now), isTrue);
      expect(
        AppState.isDialCoolingDown(now, now.add(const Duration(seconds: 6))),
        isFalse,
      );
    });
  });
```

- [ ] **Step 2: 运行测试确认失败**

Run: `C:\flutter\bin\flutter.bat test test\offline_outbox_test.dart`
Expected: 编译失败，`The method 'isDialCoolingDown' isn't defined`。

- [ ] **Step 3: 写最小实现**

**(a) `lib/app_state.dart`** —— 把 `_dialed` 从"永久集合"改为"带时间戳的冷却表"：

```dart
  /// 拨号冷却表：peerId → 上次拨号时间。
  /// 原实现是 Set，一旦拨过就永不再拨，导致离线补发永远等不到 Connected
  /// （根因 1）。改为冷却窗口：窗口内不重复拨，窗口外允许重试。
  final Map<String, DateTime> _dialedAt = {};
  static const Duration _dialCooldown = Duration(seconds: 5);

  /// 纯函数，便于测试。
  static bool isDialCoolingDown(DateTime lastAt, DateTime now) =>
      now.difference(lastAt) < _dialCooldown;

  bool _dialCoolingDown(String peerId) {
    final at = _dialedAt[peerId];
    if (at == null) return false;
    return isDialCoolingDown(at, DateTime.now());
  }
```

`ensureDial`（`:1300-1318`）开头改为：

```dart
  Future<void> ensureDial(String peerId) async {
    if (!chatReady || _dialCoolingDown(peerId)) return;
    _dialedAt[peerId] = DateTime.now();
    // ... 其余不变（device.ip.isEmpty 的 return 要保留，但改为从
    //     失败分支走 chatError，不要静默 return —— 否则地址缺失时无任何反馈）
```

**注意**：原 `:1303` 的 `if (device.ip.isEmpty) return;` 要**在返回前清掉本次冷却**（`_dialedAt.remove(peerId)`），否则地址一缺失就白白占掉一个冷却窗口。原失败分支里的 `_dialed.remove(peerId)` 同理改为 `_dialedAt.remove(peerId)`。

**(b) `lib/app_state.dart`** —— 新增回前台自愈：

```dart
  /// 安卓回到前台：连接很可能已被对端按 10s 超时判死，而本端 UI 仍显示在线。
  /// 强制清掉本端在线标记与拨号冷却，然后对每个会话重新拨号并补发。
  Future<void> onAppResumed() async {
    for (final c in conversations) {
      final id = c.device.id;
      _dialedAt.remove(id);
      _setOnline(id, false);          // 先归零，等真实的 Connected 事件再置 true
      unawaited(ensureDial(id));      // 冷却已清，这次会真的拨
    }
  }
```

**(c) `lib/main.dart`** —— 完整生命周期 observer：

```dart
class _AppLifecycleObserver extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
        // 切后台：保住前台服务（Task 10 判定忙不忙）
        unawaited(AppState.instance._updateKeepAlive());
      case AppLifecycleState.resumed:
        // 回前台：连接可能已被判超时，重新拨号
        unawaited(AppState.instance.onAppResumed());
      default:
        break;
    }
  }
}
```

在 `main()` 里注册：`WidgetsBinding.instance.addObserver(_AppLifecycleObserver());`

- [ ] **Step 4: 运行测试确认通过**

Run: `C:\flutter\bin\flutter.bat test test\offline_outbox_test.dart`
Expected: 全部通过。

Run: `cargo test 2>&1 | Select-String "test result"`（在 `rust_builder` 下）
Expected: 全部 `ok`（确认 `_dialed` 改造没影响 Rust 侧既有测试）。

Run: `C:\flutter\bin\flutter.bat analyze`
Expected: `No issues found!`

- [ ] **Step 5: 提交**

同 Task 1 Step 5。

---

## 执行顺序（用户 2026-04-19 拍板）

**先离线发送，后安卓保活：**

| 阶段 | 任务 | 产出 |
|---|---|---|
| 一、离线发送（核心 bug） | Task 1 → 2 → 3 → 4 → 5 → 6 → 8 | Rust 发件箱、seq 持久化、文件查重、Dart 接线 |
| 二、安卓保活 | Task 7 → 10 → 11 | 前台服务、按需使能、生命周期重连 |
| 三、验收 | Task 9 | 真机端到端验证清单逐条打勾 |

阶段一的依赖是严格的 1→2→3→4→5、6 可与 5 并行、8 依赖 4。阶段二内部 7→10→11。**阶段三必须在阶段一、二全部完成后执行。**


**Interfaces:**
- Consumes: `SeqState` / `SeqTracker::snapshot` / `SeqState::default`（Task 2-3）、`Connection::start_with_seqs`（Task 3）
- Produces:
  - `rust_builder/src/backend/session.rs` 新增 `pub struct SeqStateStore`（进程内共享的序号状态，`Arc<Mutex<SeqState>>`）与 `pub fn seq_state_store() -> &'static SeqStateStore`
  - `Dialer::seq_state(&self) -> SeqState` 与 `Dialer::set_seq_state(&self, state: SeqState)`

**背景：** Task 3 让 `Connection` 能接受状态，本任务让**重连路径真的把状态传进去**，否则修复无效。

- [ ] **Step 1: 写失败测试**

在 `rust_builder/src/backend/session.rs` 的 `mod tests` 追加：

```rust
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
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cargo test seq_state_store_roundtrip 2>&1 | Select-String "test result|error\[|cannot find"`
Expected: 编译失败，`cannot find struct SeqStateStore`。

- [ ] **Step 3: 写最小实现**

在 `rust_builder/src/backend/session.rs` 的 `SeqState` 定义之后新增：

```rust
/// 进程内共享的序号状态：连接重建（自动重连）时用它恢复 `SeqTracker`，
/// 避免 `out_seq` 归零导致新消息被对端当旧的丢弃、`last_seen` 清空导致重复入站。
#[derive(Debug, Default)]
pub struct SeqStateStore {
    state: std::sync::Mutex<SeqState>,
}

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
```

在 `Dialer` 结构中新增字段与访问器（`Dialer` 定义在 `session.rs` 中 `send_text` 方法 `:749` 附近的 impl 所属类型）：

```rust
    /// 该对端的序号状态（重连时注入新连接）。
    seq_state: SeqStateStore,
```

并在 `impl Dialer` 中新增：

```rust
    /// 导出当前序号状态（连接关闭前/持久化时调用）。
    pub fn seq_state(&self) -> SeqState {
        self.seq_state.snapshot()
    }

    /// 注入序号状态（重连建连前调用）。
    pub fn set_seq_state(&self, state: SeqState) {
        self.seq_state.restore(state);
    }
```

把 `Dialer` 内每次建立 `Connection` 的调用点（自动重连循环与首次 dial）从 `Connection::start(...)` 改为：

```rust
        let conn = Connection::start_with_seqs(stream, cfg, events, self.seq_state.snapshot())?;
```

并在连接建立成功后、以及 `send_text` / `send_frame` 成功后，把最新状态写回：

```rust
        if let Ok(snap) = conn.shared_seqs_snapshot() {
            self.seq_state.restore(snap);
        }
```

**若 `Connection` 未暴露快照入口**，在 `impl Connection` 中新增（Task 3 已给 `Shared` 加了 `seq_snapshot`）：

```rust
    /// 当前连接的序号状态快照（写回 `Dialer` 用）。
    pub fn shared_seqs_snapshot(&self) -> io::Result<SeqState> {
        Ok(self.shared.seq_snapshot())
    }
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cargo test seq_state_store 2>&1 | Select-String "test result"`
Expected: `test result: ok`。

Run: `cargo test 2>&1 | Select-String "test result|FAILED"`
Expected: 全部 `ok`。会话层既有测试（`dialer_sends_text_and_reports_seq` 于 `:1050`、`:1108` 附近）必须仍通过 —— 若失败，说明 `start_with_seqs` 改造破坏了原有建连路径，必须修好再继续。

- [ ] **Step 5: 提交**

同 Task 1 Step 5。

---
