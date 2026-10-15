//! 本地持久化：配对表（T2.2）与消息历史契约（T3.3；风险12 分页查询）。
//!
//! 介质选择
//! - 配对表（T2.2）：JSON KV 文件 + 原子写（写 tmp 再 rename）。联系人只有几条，
//!   人可读、易备份、跨平台零依赖；损坏时备份成 .corrupt 后重新开始，不会卡死启动。
//! - 消息历史（T3.3）：数据量级不同（数百上千条 + keyset 分页），届时应换 SQLite
//!   （rusqlite bundled）。注意 Android NDK 交叉编译尚未验证，T3.3 开工第一件事是
//!   先跑通一次 APK 出包再写业务。

use std::collections::HashMap;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use super::discovery::MAX_ADDR_HISTORY;

/// 配对表文件格式版本（将来迁移用）。
pub const STORE_VERSION: u32 = 1;

/// 消息根目录（messages_open 注入；收件目录由它推导）。
static DOWNLOAD_ROOT: std::sync::Mutex<Option<PathBuf>> = std::sync::Mutex::new(None);

/// 一条已配对设备（联系人）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PairedDevice {
    pub device_id: String,
    pub name: String,
    /// "windows" | "android"
    #[serde(default)]
    pub platform: String,
    /// 该设备用过的地址（最新在前，最多 MAX_ADDR_HISTORY 条）——
    /// M3 建连时按序尝试，正好接上 T1.6 的地址优选（风险17）。
    #[serde(default)]
    pub addr_history: Vec<String>,
    /// 最近一次配对成功时间（本地墙钟，仅用于展示）。
    pub paired_at_ms: i64,
    /// 最近一次见到该设备的时间（发现/连接时刷新）。
    #[serde(default)]
    pub last_seen_ms: i64,
}

impl PairedDevice {
    pub fn new(
        device_id: impl Into<String>,
        name: impl Into<String>,
        platform: impl Into<String>,
        addr: Option<String>,
        paired_at_ms: i64,
    ) -> Self {
        let addr_history = addr.into_iter().collect();
        Self {
            device_id: device_id.into(),
            name: name.into(),
            platform: platform.into(),
            addr_history,
            paired_at_ms,
            last_seen_ms: paired_at_ms,
        }
    }

    /// 追加地址历史：最新置顶、去重、截断（与邻居表同一套规则）。
    pub fn push_addr(&mut self, addr: &str) {
        if addr.is_empty() {
            return;
        }
        self.addr_history.retain(|a| a != addr);
        self.addr_history.insert(0, addr.to_string());
        self.addr_history.truncate(MAX_ADDR_HISTORY);
    }

    /// 连接时的地址候选顺序（M3 用）。
    pub fn addrs(&self) -> &[String] {
        &self.addr_history
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct StoreFile {
    version: u32,
    contacts: Vec<PairedDevice>,
}

impl Default for StoreFile {
    fn default() -> Self {
        Self {
            version: STORE_VERSION,
            contacts: Vec::new(),
        }
    }
}

/// 配对表（内存镜像 + JSON 文件）。
///
/// 所有修改方法都会立刻落盘，避免「配对成功但没保存」这种难查的问题；
/// 落盘失败会把 io 错误交回调用方（UI 可提示），内存状态仍然更新。
#[derive(Debug)]
pub struct PairingStore {
    path: PathBuf,
    contacts: Vec<PairedDevice>,
    recovered_from_corruption: bool,
}

impl PairingStore {
    /// 打开（或创建）配对表。文件不存在 → 空表；内容损坏 → 备份后空表。
    pub fn open(path: impl Into<PathBuf>) -> Self {
        let mut store = Self {
            path: path.into(),
            contacts: Vec::new(),
            recovered_from_corruption: false,
        };
        store.load();
        store
    }

    fn load(&mut self) {
        let raw = match fs::read_to_string(&self.path) {
            Ok(raw) => raw,
            Err(_) => return, // 不存在 / 读不了：当成空表，不要炸启动
        };
        match serde_json::from_str::<StoreFile>(&raw) {
            Ok(file) => self.contacts = file.contacts,
            Err(_) => {
                // 保留现场再重来：绝不静默丢数据
                self.recovered_from_corruption = true;
                let backup = self.path.with_extension("corrupt");
                let _ = fs::rename(&self.path, &backup);
                self.contacts.clear();
            }
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// 是否发生过「损坏文件已备份」。
    pub fn recovered_from_corruption(&self) -> bool {
        self.recovered_from_corruption
    }

    pub fn list(&self) -> &[PairedDevice] {
        &self.contacts
    }

    pub fn len(&self) -> usize {
        self.contacts.len()
    }

    pub fn is_empty(&self) -> bool {
        self.contacts.is_empty()
    }

    pub fn get(&self, device_id: &str) -> Option<&PairedDevice> {
        self.contacts.iter().find(|c| c.device_id == device_id)
    }

    pub fn is_paired(&self, device_id: &str) -> bool {
        self.get(device_id).is_some()
    }

    /// 插入或更新（名字/平台覆盖，地址并入历史），并落盘。
    pub fn upsert(&mut self, entry: PairedDevice) -> io::Result<()> {
        match self
            .contacts
            .iter_mut()
            .find(|c| c.device_id == entry.device_id)
        {
            Some(existing) => {
                if !entry.name.trim().is_empty() {
                    existing.name = entry.name;
                }
                if !entry.platform.trim().is_empty() {
                    existing.platform = entry.platform;
                }
                existing.paired_at_ms = entry.paired_at_ms;
                existing.last_seen_ms = existing.last_seen_ms.max(entry.last_seen_ms);
                for addr in entry.addr_history.iter().rev() {
                    existing.push_addr(addr);
                }
            }
            None => self.contacts.push(entry),
        }
        self.save()
    }

    /// 删除联系人；返回是否真的删掉了。
    pub fn remove(&mut self, device_id: &str) -> io::Result<bool> {
        let before = self.contacts.len();
        self.contacts.retain(|c| c.device_id != device_id);
        let removed = self.contacts.len() != before;
        if removed {
            self.save()?;
        }
        Ok(removed)
    }

    /// 发现到该设备时刷新地址历史 / 最近可见时间（未配对设备不动）。
    pub fn touch_addr(&mut self, device_id: &str, addr: &str, seen_ms: i64) -> io::Result<bool> {
        let Some(contact) = self.contacts.iter_mut().find(|c| c.device_id == device_id) else {
            return Ok(false);
        };
        contact.push_addr(addr);
        contact.last_seen_ms = seen_ms;
        self.save()?;
        Ok(true)
    }

    /// 原子落盘：先写 .tmp 再 rename，避免半截文件。
    pub fn save(&self) -> io::Result<()> {
        if let Some(parent) = self.path.parent() {
            if !parent.as_os_str().is_empty() {
                fs::create_dir_all(parent)?;
            }
        }
        let file = StoreFile {
            version: STORE_VERSION,
            contacts: self.contacts.clone(),
        };
        let json = serde_json::to_string_pretty(&file)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        let tmp = self.path.with_extension("tmp");
        fs::write(&tmp, json)?;
        fs::rename(&tmp, &self.path)?;
        Ok(())
    }
}

/// 消息历史查询游标（keyset 分页：只取 ts_ms 小于 before 的最近 limit 条，
/// 避免 OFFSET 深翻页，风险12）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PageQuery {
    pub limit: u32,
    pub before_ts_ms: i64,
}

impl PageQuery {
    pub const DEFAULT_LIMIT: u32 = 50;

    pub fn first_page() -> Self {
        Self {
            limit: Self::DEFAULT_LIMIT,
            before_ts_ms: i64::MAX,
        }
    }

    /// 由本页最早一条消息构造上一页查询。
    pub fn prev_page(&self, earliest_ts_ms: i64) -> Self {
        Self {
            limit: self.limit,
            before_ts_ms: earliest_ts_ms,
        }
    }
}


/// 会话摘要（聊天列表页用，T3.7）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConversationSummary {
    pub peer_id: String,
    pub count: usize,
    pub last_ts_ms: i64,
    pub last_text: String,
    pub unread: u32,
}

/// 消息存储（T3.3）。
///
/// 介质：每个会话一个 **append-only JSONL** 文件
/// （`<dir>/messages/<peer_id>.jsonl`，一行一条消息）+ 一个读游标文件
/// （`<dir>/unread.json`，原子写）。
///
/// 为什么不是 SQLite：PLAN 的原始选型是 rusqlite bundled，但它的 C 代码交叉编译到
/// Android 未经验证（会引入 NDK 工具链风险）。v1 的验收标准是「500 条查询 <50ms +
/// 重启不丢」，append-only 日志 + 内存索引完全满足，且跨平台零依赖。
/// 历史量级上万条后可以平移到 redb/SQLite —— 接口（page/unread/append）不用改。
pub struct MessageStore {
    dir: PathBuf,
    /// peer_id → 按 ts_ms 升序的消息。
    conversations: HashMap<String, Vec<StoredMessage>>,
    /// peer_id → 已读游标（ts_ms 小于等于它的都算已读）。
    read_upto: HashMap<String, i64>,
    /// 打开时跳过的损坏行数（自检/日志用）。
    skipped_lines: usize,
}

impl MessageStore {
    /// 收件目录（T4.6）：`<消息根目录>/downloads`。不存在时创建。
    ///
    /// Windows 建议放 `文档/LanChat`，但消息根目录由 Dart 侧注入
    /// （%APPDATA%/LanChat 或 Android 私有目录），这里统一在其下建 downloads。
    pub fn default_download_dir() -> PathBuf {
        // 由 messages_open 注入的根目录推导；未打开时退回系统 temp
        DOWNLOAD_ROOT
            .lock()
            .ok()
            .and_then(|g| g.as_ref().map(|root| root.join("downloads")))
            .unwrap_or_else(std::env::temp_dir)
    }

    /// 注册消息根目录（messages_open 时调用），下载目录跟着它走。
    pub fn set_download_root(root: &Path) -> io::Result<()> {
        let dir = root.join("downloads");
        fs::create_dir_all(&dir)?;
        let mut guard = DOWNLOAD_ROOT
            .lock()
            .map_err(|_| io::Error::new(io::ErrorKind::Other, "download root poisoned"))?;
        *guard = Some(root.to_path_buf());
        Ok(())
    }

    /// 打开（或创建）消息目录，扫描已有会话。
    pub fn open(dir: impl Into<PathBuf>) -> Self {
        let dir = dir.into();
        let mut store = Self {
            dir,
            conversations: HashMap::new(),
            read_upto: HashMap::new(),
            skipped_lines: 0,
        };
        store.load_read_cursor();
        store.load_conversations();
        store
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    pub fn skipped_lines(&self) -> usize {
        self.skipped_lines
    }

    fn messages_dir(&self) -> PathBuf {
        self.dir.join("messages")
    }

    fn cursor_path(&self) -> PathBuf {
        self.dir.join("unread.json")
    }

    /// 会话文件路径：device_id 通常是 uuid，这里再做一次字符白名单防目录穿越。
    fn conversation_path(&self, peer_id: &str) -> PathBuf {
        let safe: String = peer_id
            .chars()
            .map(|c| {
                if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                    c
                } else {
                    '_'
                }
            })
            .collect();
        self.messages_dir().join(format!("{safe}.jsonl"))
    }

    fn load_read_cursor(&mut self) {
        let raw = match fs::read_to_string(self.cursor_path()) {
            Ok(raw) => raw,
            Err(_) => return,
        };
        if let Ok(map) = serde_json::from_str::<HashMap<String, i64>>(&raw) {
            self.read_upto = map;
        }
    }

    fn load_conversations(&mut self) {
        let entries = match fs::read_dir(self.messages_dir()) {
            Ok(entries) => entries,
            Err(_) => return, // 目录不存在 = 还没有历史
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
                continue;
            }
            let Ok(raw) = fs::read_to_string(&path) else {
                continue;
            };
            let mut messages: Vec<StoredMessage> = Vec::new();
            for line in raw.lines() {
                let line = line.trim();
                if line.is_empty() {
                    continue;
                }
                match serde_json::from_str::<StoredMessage>(line) {
                    Ok(msg) => messages.push(msg),
                    // 崩在写一半的最后一行是正常现象：跳过而不是丢掉整个会话
                    Err(_) => self.skipped_lines += 1,
                }
            }
            messages.sort_by_key(|m| (m.ts_ms, m.id.clone()));
            if let Some(first) = messages.first() {
                self.conversations
                    .entry(first.peer_id.clone())
                    .or_default()
                    .extend(messages);
            }
        }
    }

    /// 按内容哈希找一条已收到的文件消息，返回其文件名。
    ///
    /// 为什么需要：离线补发会把同一个文件发两次（第一次发到一半断线，
    /// 第二次从发件箱补发），而 `file_id` 每次发送都是新的 UUID，接收端
    /// 靠它认不出来，于是再落一份「xxx (1).pdf」—— 用户反馈的
    /// 「文件冗余错乱」。内容哈希是唯一稳定的身份。
    ///
    /// 只扫内存索引（`open` 时已全量加载），不碰磁盘。空哈希一律返回 None：
    /// 老记录没有这个字段，不能让它和「哈希为空的新文件」互相误判。
    pub fn find_received_by_hash(&self, hash_hex: &str) -> Option<&StoredMessage> {
        if hash_hex.is_empty() {
            return None;
        }
        self.conversations
            .values()
            .flatten()
            .find(|m| !m.from_me && m.kind == 3 && m.hash_hex == hash_hex)
    }

    /// 追加一条消息：更新索引 + 落地（一行一条）。
    pub fn append(&mut self, message: StoredMessage) -> io::Result<()> {
        let peer_id = message.peer_id.clone();
        let path = self.conversation_path(&peer_id);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let mut line = serde_json::to_string(&message)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        line.push('\n');

        // 若上一次写崩在半行，先补一个换行避免把两行粘在一起
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
        file.write_all(line.as_bytes())?;
        file.flush()?;

        let list = self.conversations.entry(peer_id).or_default();
        list.push(message);
        list.sort_by_key(|m| (m.ts_ms, m.id.clone()));
        Ok(())
    }

    /// keyset 分页：取 ts_ms 严格小于 before_ts_ms 的最近 limit 条（新的在前）。
    pub fn page(&self, peer_id: &str, query: PageQuery) -> Vec<StoredMessage> {
        let Some(list) = self.conversations.get(peer_id) else {
            return Vec::new();
        };
        let mut out: Vec<StoredMessage> = list
            .iter()
            .filter(|m| m.ts_ms < query.before_ts_ms)
            .rev()
            .take(query.limit as usize)
            .cloned()
            .collect();
        out.sort_by_key(|m| std::cmp::Reverse((m.ts_ms, m.id.clone())));
        out
    }

    pub fn len(&self, peer_id: &str) -> usize {
        self.conversations.get(peer_id).map(|v| v.len()).unwrap_or(0)
    }

    pub fn is_empty(&self) -> bool {
        self.conversations.values().all(|v| v.is_empty())
    }

    pub fn total(&self) -> usize {
        self.conversations.values().map(|v| v.len()).sum()
    }

    /// 未读数：对方发来且 ts 大于读游标的条数。
    pub fn unread(&self, peer_id: &str) -> u32 {
        let cursor = self.read_upto.get(peer_id).copied().unwrap_or(i64::MIN);
        self.conversations
            .get(peer_id)
            .map(|list| {
                list.iter()
                    .filter(|m| !m.from_me && m.ts_ms > cursor)
                    .count() as u32
            })
            .unwrap_or(0)
    }

    pub fn total_unread(&self) -> u32 {
        self.conversations.keys().map(|k| self.unread(k)).sum()
    }

    /// 标记已读到 upto_ts_ms（只前进不后退），返回更新后的未读数。
    pub fn mark_read(&mut self, peer_id: &str, upto_ts_ms: i64) -> io::Result<u32> {
        let entry = self
            .read_upto
            .entry(peer_id.to_string())
            .or_insert(i64::MIN);
        if upto_ts_ms > *entry {
            *entry = upto_ts_ms;
            self.save_read_cursor()?;
        }
        Ok(self.unread(peer_id))
    }

    fn save_read_cursor(&self) -> io::Result<()> {
        if let Some(parent) = self.cursor_path().parent() {
            if !parent.as_os_str().is_empty() {
                fs::create_dir_all(parent)?;
            }
        }
        let json = serde_json::to_string_pretty(&self.read_upto)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        let tmp = self.cursor_path().with_extension("tmp");
        fs::write(&tmp, json)?;
        fs::rename(&tmp, &self.cursor_path())?;
        Ok(())
    }

    /// 清空某会话的本地记录（删文件 + 内存 + 读游标）；返回是否有东西被清掉。
    pub fn clear(&mut self, peer_id: &str) -> io::Result<bool> {
        let path = self.conversation_path(peer_id);
        let had_index = self.conversations.remove(peer_id).is_some();
        let had_file = path.exists();
        if had_file {
            fs::remove_file(&path)?;
        }
        self.read_upto.remove(peer_id);
        self.save_read_cursor()?;
        Ok(had_index || had_file)
    }

    /// 删掉单条消息：内存 + JSONL 重写（原子：先写 tmp 再 rename）。
    ///
    /// append-only 存储没有「删除」概念，只能整文件重写过滤掉目标行。
    /// 只从内存摘掉是不够的 —— 重启一读文件就又回来了（用户反馈的
    ///「取消/删除的气泡重启后又出现」）。返回是否真的删掉了一条。
    pub fn remove_message(&mut self, peer_id: &str, msg_id: &str) -> io::Result<bool> {
        let Some(list) = self.conversations.get_mut(peer_id) else {
            return Ok(false);
        };
        let before = list.len();
        list.retain(|m| m.id != msg_id);
        let removed = list.len() != before;

        // 磁盘：重写整文件，只留未删除的行
        let path = self.conversation_path(peer_id);
        let mut lines: Vec<String> = Vec::new();
        if path.exists() {
            let content = fs::read_to_string(&path)?;
            for line in content.lines() {
                let t = line.trim();
                if t.is_empty() {
                    continue;
                }
                let keep = serde_json::from_str::<StoredMessage>(t)
                    .map(|m| m.id != msg_id)
                    .unwrap_or(true); // 解析不了的坏行顺手丢掉
                if keep {
                    lines.push(t.to_string());
                }
            }
        }
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let mut body = lines.join("\n");
        if !body.is_empty() {
            body.push('\n');
        }
        let tmp = path.with_extension("tmp");
        fs::write(&tmp, body)?;
        fs::rename(&tmp, &path)?;
        Ok(removed)
    }
    /// 会话摘要列表（按最后一条消息时间倒序）——聊天列表页用。
    pub fn conversations(&self) -> Vec<ConversationSummary> {
        let mut out: Vec<ConversationSummary> = self
            .conversations
            .iter()
            .filter(|(_, list)| !list.is_empty())
            .map(|(peer_id, list)| {
                let last = list.last().expect("非空");
                ConversationSummary {
                    peer_id: peer_id.clone(),
                    count: list.len(),
                    last_ts_ms: last.ts_ms,
                    last_text: last.text.clone(),
                    unread: self.unread(peer_id),
                }
            })
            .collect();
        out.sort_by_key(|s| std::cmp::Reverse(s.last_ts_ms));
        out
    }
}

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
        let sent_ids: Vec<String> = self.sent_ids_from_log().unwrap_or_default();
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
            // 记 sent:false 而非 sent:true：取消不等于送达，
            // 重放时 sent:true 会把同 id 永久钉死（enqueue 的 sent_ids 检查），
            // 用户想重发同一个文件就会被静默吞掉。
            // sent:false + entry:None 在重放时被 filter_map 丢弃，不复活。
            self.append_line(&OutboxLine {
                id: id.to_string(),
                sent: false,
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

/// 一条持久化消息的行契约（T3.3；JSONL 每行一条）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StoredMessage {
    pub id: String,
    pub peer_id: String,
    /// 会话内序号（发送方单调递增；用于去重与状态标记）。
    #[serde(default)]
    pub seq: i64,
    pub from_me: bool,
    /// 1=text 2=image 3=file
    pub kind: u8,
    pub text: String,
    pub file_name: String,
    pub file_size: u64,
    pub ts_ms: i64,
    pub delivered: bool,
    /// 文件内容哈希（blake3，仅文件消息非空）。
    ///
    /// 存在的唯一理由：离线补发时同一个文件会被发两次，接收端必须能认出
    /// 「这个内容我已经收过」——而 `file_id` 是每次发送新生成的 UUID，
    /// 认不出来（用户反馈的「文件冗余错乱」）。
    /// 老记录没有这个字段 → 反序列化为空串，空串一律视为「未知，不参与查重」。
    #[serde(default)]
    pub hash_hex: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    const T0: i64 = 1_760_000_000_000;

    /// 每个测试用独立临时目录（避免并行互踩）。
    fn temp_path(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "lanchat_store_test_{}_{}",
            tag,
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        dir.join("contacts.json")
    }

    fn contact(id: &str, name: &str, addr: &str) -> PairedDevice {
        PairedDevice::new(id, name, "android", Some(addr.to_string()), T0)
    }

    #[test]
    fn first_page_is_wide_open() {
        let q = PageQuery::first_page();
        assert_eq!(q.limit, 50);
        assert_eq!(q.before_ts_ms, i64::MAX);
    }

    #[test]
    fn prev_page_uses_earliest_ts_as_cursor() {
        let q1 = PageQuery::first_page();
        let q2 = q1.prev_page(1_760_000_000_000);
        assert_eq!(q2.before_ts_ms, 1_760_000_000_000);
        assert_eq!(q2.limit, q1.limit);
    }

    #[test]
    fn missing_file_is_an_empty_store() {
        let path = temp_path("missing");
        let store = PairingStore::open(&path);
        assert!(store.is_empty());
        assert!(!store.is_paired("dev-a"));
        assert!(!store.recovered_from_corruption());
    }

    #[test]
    fn contacts_survive_reopen() {
        let path = temp_path("roundtrip");
        {
            let mut store = PairingStore::open(&path);
            store.upsert(contact("dev-a", "Pixel 7", "192.168.1.41")).unwrap();
            store
                .upsert(PairedDevice::new(
                    "dev-b",
                    "DESKTOP-ORION",
                    "windows",
                    Some("192.168.1.23".to_string()),
                    T0 + 10,
                ))
                .unwrap();
            assert_eq!(store.len(), 2);
        }
        // 模拟重启 App
        let reopened = PairingStore::open(&path);
        assert_eq!(reopened.len(), 2);
        assert!(reopened.is_paired("dev-a"));
        let a = reopened.get("dev-a").unwrap();
        assert_eq!(a.name, "Pixel 7");
        assert_eq!(a.platform, "android");
        assert_eq!(a.addrs(), ["192.168.1.41"]);
        assert_eq!(a.paired_at_ms, T0);
        assert_eq!(reopened.get("dev-b").unwrap().name, "DESKTOP-ORION");
    }

    #[test]
    fn upsert_merges_name_and_address_history() {
        let path = temp_path("merge");
        let mut store = PairingStore::open(&path);
        store.upsert(contact("dev-a", "Pixel", "192.168.1.41")).unwrap();
        store
            .upsert(PairedDevice::new(
                "dev-a",
                "Pixel 7 Pro",
                "android",
                Some("192.168.1.77".to_string()),
                T0 + 500,
            ))
            .unwrap();

        let a = store.get("dev-a").unwrap();
        assert_eq!(store.len(), 1, "同一设备不应出现两行");
        assert_eq!(a.name, "Pixel 7 Pro", "名字应更新");
        assert_eq!(a.addrs(), ["192.168.1.77", "192.168.1.41"], "新地址在前且不重复");
        assert_eq!(a.paired_at_ms, T0 + 500);
        assert_eq!(a.last_seen_ms, T0 + 500);
    }

    #[test]
    fn address_history_is_deduped_and_capped() {
        let path = temp_path("cap");
        let mut store = PairingStore::open(&path);
        store.upsert(contact("dev-a", "Pixel", "10.0.0.1")).unwrap();
        for i in 2..=8 {
            store
                .touch_addr("dev-a", &format!("10.0.0.{i}"), T0 + i as i64)
                .unwrap();
        }
        let a = store.get("dev-a").unwrap();
        assert_eq!(a.addrs().len(), MAX_ADDR_HISTORY);
        assert_eq!(a.addrs()[0], "10.0.0.8", "最新地址置顶");
    }

    #[test]
    fn touch_addr_ignores_unknown_devices() {
        let path = temp_path("touch-unknown");
        let mut store = PairingStore::open(&path);
        assert!(!store.touch_addr("dev-x", "10.0.0.9", T0).unwrap());
        assert!(store.is_empty());
    }

    #[test]
    fn remove_deletes_and_persists() {
        let path = temp_path("remove");
        let mut store = PairingStore::open(&path);
        store.upsert(contact("dev-a", "Pixel", "10.0.0.1")).unwrap();
        assert!(store.remove("dev-a").unwrap());
        assert!(!store.remove("dev-a").unwrap(), "重复删除返回 false");
        assert!(PairingStore::open(&path).is_empty(), "删除要落盘");
    }

    #[test]
    fn save_leaves_no_tmp_file() {
        let path = temp_path("atomic");
        let mut store = PairingStore::open(&path);
        store.upsert(contact("dev-a", "Pixel", "10.0.0.1")).unwrap();
        assert!(path.exists());
        assert!(!path.with_extension("tmp").exists(), "原子写不应留下 .tmp");
        let raw = fs::read_to_string(&path).unwrap();
        let parsed: StoreFile = serde_json::from_str(&raw).unwrap();
        assert_eq!(parsed.version, STORE_VERSION);
        assert_eq!(parsed.contacts.len(), 1);
    }

    #[test]
    fn corrupt_file_is_backed_up_and_store_starts_empty() {
        let path = temp_path("corrupt");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, "{ this is not json").unwrap();

        let store = PairingStore::open(&path);
        assert!(store.is_empty());
        assert!(store.recovered_from_corruption(), "应标记为已从损坏恢复");
        let backup = path.with_extension("corrupt");
        assert!(backup.exists(), "损坏文件必须留档，不能静默丢");
        assert_eq!(fs::read_to_string(&backup).unwrap(), "{ this is not json");
        // 恢复后还能正常写入
        let mut store = store;
        store.upsert(contact("dev-a", "Pixel", "10.0.0.1")).unwrap();
        assert_eq!(PairingStore::open(&path).len(), 1);
    }

    #[test]
    fn empty_address_is_not_stored() {
        let mut c = PairedDevice::new("dev-a", "Pixel", "android", None, T0);
        assert!(c.addrs().is_empty());
        c.push_addr("");
        assert!(c.addrs().is_empty(), "空地址不入历史");
    }

    // ---------- 消息存储（T3.3） ----------

    fn msg(peer: &str, id: &str, ts: i64, from_me: bool, text: &str) -> StoredMessage {
        StoredMessage {
            id: id.into(),
            peer_id: peer.into(),
            seq: 1,
            from_me,
            kind: 1,
            text: text.into(),
            file_name: String::new(),
            file_size: 0,
            ts_ms: ts,
            delivered: true,
            hash_hex: String::new(),
        }
    }

    fn temp_msg_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "lanchat_msg_test_{}_{}",
            tag,
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn messages_survive_reopen() {
        let dir = temp_msg_dir("msg-roundtrip");
        {
            let mut store = MessageStore::open(&dir);
            store.append(msg("dev-a", "m1", T0, false, "你好")).unwrap();
            store.append(msg("dev-a", "m2", T0 + 1, true, "收到")).unwrap();
            store
                .append(msg("dev-b", "m3", T0 + 2, false, "另一会话"))
                .unwrap();
            assert_eq!(store.total(), 3);
            assert_eq!(store.len("dev-a"), 2);
        }
        // 模拟杀进程重启
        let reopened = MessageStore::open(&dir);
        assert_eq!(reopened.total(), 3);
        assert_eq!(reopened.len("dev-a"), 2);
        let page = reopened.page("dev-a", PageQuery::first_page());
        assert_eq!(page.len(), 2);
        assert_eq!(page[0].id, "m2", "新的在前");
        assert_eq!(page[1].text, "你好");
        assert_eq!(reopened.skipped_lines(), 0);
    }

    #[test]
    fn page_is_keyset_newest_first() {
        let dir = temp_msg_dir("msg-page");
        let mut store = MessageStore::open(&dir);
        for i in 1..=10 {
            store
                .append(msg("dev-a", &format!("m{i:02}"), T0 + i, i % 2 == 0, "t"))
                .unwrap();
        }
        let first = store.page("dev-a", PageQuery::first_page());
        // 默认 limit 50 > 10 条，全量返回且新的在前
        assert_eq!(first.len(), 10);
        assert_eq!(first.first().unwrap().id, "m10");
        assert_eq!(first.last().unwrap().id, "m01");

        let first3 = store.page("dev-a", PageQuery { limit: 3, before_ts_ms: i64::MAX });
        assert_eq!(
            first3.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(),
            vec!["m10", "m09", "m08"]
        );
        // 用本页最早一条做游标翻上一页（带上同样的 limit，和 UI 用法一致）
        let earliest = first3.last().unwrap().ts_ms;
        let page_query = PageQuery {
            limit: 3,
            before_ts_ms: i64::MAX,
        };
        let prev = store.page("dev-a", page_query.prev_page(earliest));
        assert_eq!(
            prev.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(),
            vec!["m07", "m06", "m05"]
        );
    }

    #[test]
    fn five_hundred_messages_page_under_50ms() {
        let dir = temp_msg_dir("msg-500");
        let mut store = MessageStore::open(&dir);
        for i in 0..500 {
            store
                .append(msg(
                    "dev-a",
                    &format!("m{i:04}"),
                    T0 + i,
                    i % 3 == 0,
                    "历史消息",
                ))
                .unwrap();
        }
        assert_eq!(store.len("dev-a"), 500);

        let started = std::time::Instant::now();
        let page = store.page("dev-a", PageQuery::first_page());
        let elapsed = started.elapsed();
        assert_eq!(page.len(), 50, "首屏 50 条");
        assert!(
            elapsed.as_millis() < 50,
            "500 条历史查询应 <50ms，实际 {}ms",
            elapsed.as_millis()
        );

        // 上翻一页也要快
        let started = std::time::Instant::now();
        let prev = store.page(
            "dev-a",
            PageQuery::first_page().prev_page(page.last().unwrap().ts_ms),
        );
        let elapsed = started.elapsed();
        assert_eq!(prev.len(), 50);
        assert!(elapsed.as_millis() < 50, "翻页 {}ms", elapsed.as_millis());
    }

    #[test]
    fn unread_counts_and_mark_read_persists() {
        let dir = temp_msg_dir("msg-unread");
        {
            let mut store = MessageStore::open(&dir);
            store.append(msg("dev-a", "m1", T0, false, "在吗")).unwrap();
            store.append(msg("dev-a", "m2", T0 + 1, true, "在")).unwrap();
            store.append(msg("dev-a", "m3", T0 + 2, false, "帮我看下")).unwrap();
            assert_eq!(store.unread("dev-a"), 2, "自己发的不算未读");
            assert_eq!(store.total_unread(), 2);
            let left = store.mark_read("dev-a", T0 + 2).unwrap();
            assert_eq!(left, 0);
            // 游标只前进不后退
            assert_eq!(store.mark_read("dev-a", T0).unwrap(), 0);
        }
        let reopened = MessageStore::open(&dir);
        assert_eq!(reopened.unread("dev-a"), 0, "已读状态要持久化");
        // 新消息重新计未读
        let mut reopened = reopened;
        reopened
            .append(msg("dev-a", "m4", T0 + 10, false, "再看下"))
            .unwrap();
        assert_eq!(reopened.unread("dev-a"), 1);
    }

    #[test]
    fn corrupt_line_is_skipped_not_fatal() {
        let dir = temp_msg_dir("msg-corrupt");
        let messages = dir.join("messages");
        fs::create_dir_all(&messages).unwrap();
        let good = serde_json::to_string(&msg("dev-a", "m1", T0, false, "还行")).unwrap();
        let content = format!("{good}\n{{ 半行写崩\n{good}\n");
        fs::write(messages.join("dev-a.jsonl"), content).unwrap();

        let mut store = MessageStore::open(&dir);
        assert_eq!(store.len("dev-a"), 2, "好的行要保留");
        assert_eq!(store.skipped_lines(), 1, "坏行计数");

        // 追加后仍然可解析（不要在坏行后面直接粘）
        store.append(msg("dev-a", "m2", T0 + 1, true, "新消息")).unwrap();
        let reopened = MessageStore::open(&dir);
        assert_eq!(reopened.len("dev-a"), 3);
        assert_eq!(reopened.skipped_lines(), 1, "新写入的行不该再坏");
    }

    #[test]
    fn conversation_summary_is_sorted_and_carries_unread() {
        let dir = temp_msg_dir("msg-summary");
        let mut store = MessageStore::open(&dir);
        store.append(msg("dev-a", "a1", T0, false, "早")).unwrap();
        store
            .append(msg("dev-b", "b1", T0 + 100, false, "晚一点"))
            .unwrap();
        store.append(msg("dev-b", "b2", T0 + 101, true, "我发的")).unwrap();

        let list = store.conversations();
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].peer_id, "dev-b", "最近有消息的排前面");
        assert_eq!(list[0].last_text, "我发的");
        assert_eq!(list[0].count, 2);
        assert_eq!(list[0].unread, 1, "对方那条还没读");
        assert_eq!(list[1].peer_id, "dev-a");
        assert_eq!(list[1].unread, 1);
    }

    #[test]
    fn peer_id_is_sanitized_for_filename() {
        let dir = temp_msg_dir("msg-sanitize");
        let mut store = MessageStore::open(&dir);
        store
            .append(msg("../../etc/passwd", "m1", T0, false, "坏 id"))
            .unwrap();
        let files: Vec<String> = fs::read_dir(dir.join("messages"))
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().to_string())
            .collect();
        assert_eq!(files.len(), 1);
        assert!(
            !files[0].contains('/') && !files[0].contains('\\'),
            "文件名不应包含路径分隔符: {files:?}"
        );
        // 重新打开仍能读回
        let reopened = MessageStore::open(&dir);
        assert_eq!(reopened.total(), 1);
    }

    /// 删单条消息：内存与磁盘都要生效。
    ///
    /// 只从内存摘掉是不够的 —— 重启一读文件就又回来了（用户反馈的
    ///「取消/删除的气泡重启后又出现」）。
    #[test]
    fn remove_message_drops_from_memory_and_disk() {
        let dir = temp_msg_dir("remove-one");
        {
            let mut store = MessageStore::open(&dir);
            store.append(msg("dev-a", "m1", T0, false, "第一条")).unwrap();
            store.append(msg("dev-a", "m2", T0 + 1, true, "第二条")).unwrap();
            store.append(msg("dev-a", "m3", T0 + 2, false, "第三条")).unwrap();
            assert_eq!(store.len("dev-a"), 3);

            assert!(store.remove_message("dev-a", "m2").unwrap(), "应删掉一条");
            assert_eq!(store.len("dev-a"), 2, "内存里应剩 2 条");
            let ids: Vec<String> =
                store.page("dev-a", PageQuery::first_page()).into_iter().map(|m| m.id).collect();
            assert!(!ids.contains(&"m2".to_string()), "内存页里不该再有 m2");
            assert!(ids.contains(&"m1".to_string()));
            assert!(ids.contains(&"m3".to_string()));

            // 删不存在的 id：不应报错，返回 false
            assert!(!store.remove_message("dev-a", "nope").unwrap());
        }

        // **关键**：重新打开（模拟重启）后也不能复活
        let reopened = MessageStore::open(&dir);
        assert_eq!(reopened.len("dev-a"), 2, "重启后仍是 2 条");
        let ids: Vec<String> = reopened
            .page("dev-a", PageQuery::first_page())
            .into_iter()
            .map(|m| m.id)
            .collect();
        assert!(
            !ids.contains(&"m2".to_string()),
            "重启后被删的消息绝不能从磁盘复活"
        );
    }

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
}
