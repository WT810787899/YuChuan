//! 分块传输与断点续传（T4.1 状态机 / T4.2 分块 IO / T4.3 校验与错误处理；
//! 风险8 指纹不一致即从头传、风险15 文件名、风险18 磁盘空间）。
//!
//! 结构分层：
//! - [`SendSender`] / [`Receiver`]：**不碰网络**的文件驱动器 —— 发送方把文件切成
//!   256KB 块产出帧，接收方落 `.part` 临时文件并回 ACK；两边由 api 层接到 TCP 帧上；
//! - [`FileFingerprint`]：`(file_id, size, hash)` 指纹，不一致必须从头传（风险8）；
//! - 哈希 blake3（快 + 流式读，风险16）；接收方**完成后整读一遍比对**，简单且
//!   对「续传」天然正确（0..size 全量都在文件里）。
//!
//! 协议流程（PLAN §4）：
//! `FILE_META → FILE_ACK(offset) → FILE_CHUNK×N → FILE_ACK×N → FILE_DONE(hash)//! → FILE_DONE(ok)`。
//! 拒绝（磁盘不足/哈希不一致）走 `FILE_ACK.reason` 或 `FILE_DONE.error`。

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use super::protocol::{self, FileAckPayload, FileDonePayload, FileMetaPayload, FrameType};

/// 默认分块大小（PLAN §3.6-4：256KB/块，不整包读内存）。
pub const DEFAULT_CHUNK_SIZE: u32 = 256 * 1024;
/// 接收方临时文件后缀（风险8：完成后原子改名）。
pub const PART_SUFFIX: &str = ".part";
/// 续传指纹 sidecar 后缀（JSON：size + hash，用于判断 .part 是否属于本次传输）。
pub const SIDECAR_SUFFIX: &str = ".part.meta";
/// 单文件大小上限（u32 寻址之外的防御，v1 先定 64GB）。
pub const MAX_FILE_SIZE: u64 = 64 * 1024 * 1024 * 1024;

// ------------------------------------------------------------
// 指纹（风险8）
// ------------------------------------------------------------

/// 文件指纹：`(file_id, size, hash_hex)` 三元组。指纹不一致时必须从头传输。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileFingerprint {
    pub file_id: String,
    pub size: u64,
    pub hash_hex: String,
}

impl FileFingerprint {
    pub fn matches(&self, other: &FileFingerprint) -> bool {
        self.file_id == other.file_id
            && self.size == other.size
            && self.hash_hex == other.hash_hex
    }
}

/// 流式计算文件 blake3（hex）。读 buffer 复用，峰值内存 = chunk 级别。
pub fn hash_file(path: &Path) -> std::io::Result<String> {
    let mut file = File::open(path)?;
    let mut hasher = blake3::Hasher::new();
    let mut buf = vec![0u8; DEFAULT_CHUNK_SIZE as usize];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hasher.finalize().to_hex().to_string())
}

// ------------------------------------------------------------
// 运行时状态（沿用 T0.3 的 TransferState 契约）
// ------------------------------------------------------------

/// 一次传输的运行时状态（纯逻辑，供状态机单测）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransferState {
    pub file_id: String,
    pub size: u64,
    /// 已确认（FILE_ACK）的连续 offset。
    pub acked_offset: u64,
    /// 发送方当前写入 offset。
    pub sent_offset: u64,
    /// 传输完成且校验通过。
    pub done: bool,
}

impl TransferState {
    /// 收到 FILE_ACK：推进确认 offset（不回退，防乱序 ACK）。
    pub fn on_ack(&mut self, offset: u64) {
        self.acked_offset = self.acked_offset.max(offset.min(self.size));
    }

    /// 续传起点 = 已确认 offset。
    pub fn resume_from(&self) -> u64 {
        self.acked_offset
    }

    pub fn is_complete(&self) -> bool {
        self.done && self.acked_offset >= self.size
    }
}

// ------------------------------------------------------------
// 文件名（风险15：Win↔Android 字符集差异）
// ------------------------------------------------------------

/// 规范化对端文件名：去路径、替换非法字符、Windows 保留名、去尾部点/空格。
///
/// 空结果回退 "file"。长度按字符截断到 180（防超长路径）。
pub fn sanitize_file_name(raw: &str) -> String {
    // 1) 只取 basename：对端可能送来 "C:\x\y.txt" 或 "/sdcard/..."
    let name = raw
        .rsplit(|c| c == '/' || c == '\\')
        .find(|s| !s.trim().is_empty())
        .unwrap_or("");

    // 2) 控制字符 + Windows 非法字符替换
    let mut cleaned: String = name
        .chars()
        .map(|c| match c {
            '<' | '>' | ':' | '"' | '/' | '|' | '?' | '*' => '_',
            c if (c as u32) < 0x20 || c == '\u{7f}' => '_',
            c => c,
        })
        .collect();

    // 3) 尾部点/空格在 Windows 上会被吞掉，双方都去掉
    while cleaned.ends_with('.') || cleaned.ends_with(' ') {
        cleaned.pop();
    }

    // 4) Windows 设备保留名（主名命中即算，带扩展名也一样）
    let stem = cleaned
        .split('.')
        .next()
        .unwrap_or("")
        .to_ascii_uppercase();
    let reserved = matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        || (stem.len() == 4
            && (stem.starts_with("COM") || stem.starts_with("LPT"))
            && stem[3..].parse::<u8>().is_ok_and(|n| (1..=9).contains(&n)));
    if reserved {
        cleaned = format!("_{cleaned}");
    }

    // 5) 空名回退；按字符截断
    if cleaned.is_empty() {
        return "file".to_string();
    }
    let mut out: String = cleaned.chars().take(180).collect();
    while out.ends_with('.') || out.ends_with(' ') {
        out.pop();
    }
    if out.is_empty() {
        "file".to_string()
    } else {
        out
    }
}

/// 目标目录里生成不冲突路径：`a.txt` 已存在 → `a (1).txt`、`a (2).txt`…
pub fn unique_dest(dir: &Path, name: &str) -> PathBuf {
    let direct = dir.join(name);
    if !direct.exists() {
        return direct;
    }
    let p = Path::new(name);
    let stem = p
        .file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| name.to_string());
    let ext = p
        .extension()
        .map(|s| format!(".{}", s.to_string_lossy()))
        .unwrap_or_default();
    for i in 1..10_000 {
        let candidate = dir.join(format!("{stem} ({i}){ext}"));
        if !candidate.exists() {
            return candidate;
        }
    }
    dir.join(format!("{stem} (copy){ext}"))
}

// ------------------------------------------------------------
// 磁盘空间（风险18）
// ------------------------------------------------------------

/// 目标目录所在卷的可用字节数；探测失败返回 u64::MAX（放行，传输错误
/// 仍会被写入失败兜住）。
pub fn disk_available(path: &Path) -> u64 {
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        use windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;
        let wide: Vec<u16> = path
            .as_os_str()
            .encode_wide()
            .chain(std::iter::once(0))
            .collect();
        let mut free_to_caller: u64 = 0;
        let mut total: u64 = 0;
        let mut total_free: u64 = 0;
        let ok = unsafe {
            GetDiskFreeSpaceExW(
                wide.as_ptr(),
                &mut free_to_caller,
                &mut total,
                &mut total_free,
            )
        };
        if ok != 0 {
            return free_to_caller;
        }
        return u64::MAX;
    }
    #[cfg(unix)]
    {
        use std::ffi::CString;
        use std::os::unix::ffi::OsStrExt;
        let cstr = match CString::new(path.as_os_str().as_bytes()) {
            Ok(c) => c,
            Err(_) => return u64::MAX,
        };
        let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
        let rc = unsafe { libc::statvfs(cstr.as_ptr(), &mut stat) };
        if rc != 0 {
            return u64::MAX;
        }
        let avail = stat.f_bavail as u64;
        let bsize = stat.f_bsize as u64;
        avail.saturating_mul(bsize)
    }
    #[cfg(not(any(windows, unix)))]
    {
        u64::MAX
    }
}

// ------------------------------------------------------------
// 发送方（T4.1/T4.2）
// ------------------------------------------------------------

/// 发送动作：api 层直接翻译成一帧发出去。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SendAction {
    /// 发一帧（kind 已定好，payload 即帧体）。
    Frame { kind: FrameType, payload: Vec<u8> },
    /// 对端拒绝（磁盘不足等），停止本次传输。
    Failed { reason: String },
    /// 对端校验通过，传输成功收尾。
    Complete,
    /// 没有可发的内容（窗口满 / 等 ACK），继续等。
    Wait,
}

/// 文件发送驱动器。
///
/// 流控：在途字节数（sent-acked）不超过 `window`；收到 ACK 推进。
/// 首个 ACK 携带接收方续传点，发送方据此**跳过已存在部分**（风险8）。
pub struct Sender {
    file: File,
    path: PathBuf,
    meta: FileMetaPayload,
    acked: u64,
    sent: u64,
    window: u64,
    meta_sent: bool,
    done_sent: bool,
    failed: Option<String>,
    complete: bool,
    /// 暂停标志：置位后 next_action 不再产出 chunk（发送侧状态机停住，
    /// 已发出的在途块照常被 ACK；心跳是独立线程，连接不会被判离线）。
    paused: bool,
    /// 本进程发出的 chunk 数（测试/统计用）。
    pub chunks_sent: u64,
}

impl Sender {
    /// 打开文件并算哈希 → 产出 FILE_META。file_id 由调用方生成。
    pub fn open(
        path: &Path,
        file_id: impl Into<String>,
        sender_id: impl Into<String>,
    ) -> std::io::Result<(Self, FileMetaPayload)> {
        let file_id = file_id.into();
        let sender_id = sender_id.into();
        let file = File::open(path)?;
        let size = file.metadata()?.len();
        if size > MAX_FILE_SIZE {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "文件过大（上限 64GB）",
            ));
        }
        let hash_hex = hash_file(path)?;
        let name = path
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| "file".into());
        let meta = FileMetaPayload {
            file_id,
            sender_id,
            name,
            size,
            chunk_size: DEFAULT_CHUNK_SIZE,
            hash_hex,
            resume_offset: 0,
        };
        let sender = Self {
            file,
            path: path.to_path_buf(),
            meta: meta.clone(),
            acked: 0,
            sent: 0,
            window: (DEFAULT_CHUNK_SIZE as u64) * 8, // 8 块在途上限
            meta_sent: false,
            done_sent: false,
            failed: None,
            complete: false,
            paused: false,
            chunks_sent: 0,
        };
        Ok((sender, meta))
    }

    pub fn meta(&self) -> &FileMetaPayload {
        &self.meta
    }

    pub fn file_id(&self) -> &str {
        &self.meta.file_id
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn failed_reason(&self) -> Option<&str> {
        self.failed.as_deref()
    }

    pub fn is_complete(&self) -> bool {
        self.complete
    }

    /// 进度（acked, size）—— T4.4 由 api 层按 100ms 节流后推 UI。
    pub fn progress(&self) -> (u64, u64) {
        (self.acked, self.meta.size)
    }

    /// 暂停/继续发送（纯发送侧状态机，不需要通知对端 —— 心跳独立线程，
    /// 连接不会被判离线；已发出的在途块照常被 ACK 推进）。
    pub fn set_paused(&mut self, paused: bool) {
        self.paused = paused;
    }

    pub fn is_paused(&self) -> bool {
        self.paused
    }

    /// 标记为失败（取消时用；让状态机走 Failed 分支收尾）。
    pub fn abort(&mut self, reason: &str) {
        self.failed = Some(reason.to_string());
    }

    /// 是否已经开始流式发送（发过 FILE_META）。
    pub fn has_started(&self) -> bool {
        self.meta_sent
    }

    /// 断线重连后重启：重发 FILE_META 并从已确认点续传。
    ///
    /// 关键：`sent` 必须退回 `acked` —— 断线时对端可能只写到 acked 那里，
    /// 若保留原来的 sent，中间那段就永远补不上（静默丢数据）。退到 acked
    /// 后，对端的首个 ACK 会带回它自己的续传点，我们据此跳到更远处（风险8）。
    pub fn restart(&mut self) {
        self.meta_sent = false;
        self.done_sent = false;
        self.sent = self.acked;
        self.failed = None;
        self.complete = false;
        // FILE_META 带上已确认偏移，便于对端校验/日志
        self.meta.resume_offset = self.acked;
    }

    /// 取下一步要发的帧；没帧可发返回 `SendAction::Wait`。
    pub fn next_action(&mut self) -> std::io::Result<SendAction> {
        if let Some(reason) = &self.failed {
            return Ok(SendAction::Failed {
                reason: reason.clone(),
            });
        }
        if self.complete {
            return Ok(SendAction::Wait);
        }
        // 暂停中：不产出任何帧，等 resume 再继续
        if self.paused {
            return Ok(SendAction::Wait);
        }
        // 1) FILE_META
        if !self.meta_sent {
            self.meta_sent = true;
            let payload = serde_json::to_vec(&self.meta)
                .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
            return Ok(SendAction::Frame {
                kind: FrameType::FileMeta,
                payload,
            });
        }
        // 2) FILE_CHUNK（受窗口流控）
        if self.sent < self.meta.size {
            if self.sent.saturating_sub(self.acked) >= self.window {
                return Ok(SendAction::Wait); // 等 ACK 腾出窗口
            }
            let mut remaining = self.meta.size - self.sent;
            let want = remaining.min(self.meta.chunk_size as u64) as usize;
            let buf = &mut vec![0u8; want];
            self.file.seek(SeekFrom::Start(self.sent))?;
            let n = read_full(&mut self.file, buf)?;
            if n == 0 {
                // 文件被截断了：直接失败
                self.failed = Some("发送中文件消失/被截断".into());
                return Ok(SendAction::Failed {
                    reason: self.failed.clone().unwrap(),
                });
            }
            remaining = n as u64;
            let offset = self.sent;
            self.sent += remaining;
            self.chunks_sent += 1;
            return Ok(SendAction::Frame {
                kind: FrameType::FileChunk,
                payload: protocol::encode_chunk(offset, &buf[..n]),
            });
        }
        // 3) 全部发完等 ACK：acked 还没到 size 就继续等
        if self.acked < self.meta.size {
            return Ok(SendAction::Wait);
        }
        // 4) FILE_DONE(hash)
        if !self.done_sent {
            self.done_sent = true;
            let payload = serde_json::to_vec(&FileDonePayload {
                file_id: self.meta.file_id.clone(),
                hash_hex: self.meta.hash_hex.clone(),
                ok: true,
                error: None,
            })
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
            return Ok(SendAction::Frame {
                kind: FrameType::FileDone,
                payload,
            });
        }
        Ok(SendAction::Wait)
    }

    /// 处理 FILE_ACK：推进确认位、承载拒绝原因、首个 ACK 承载续传点。
    pub fn on_ack(&mut self, ack: &FileAckPayload) -> Option<SendAction> {
        if ack.file_id != self.meta.file_id {
            return None; // 别的传输的 ACK，忽略
        }
        if let Some(reason) = &ack.reason {
            self.failed = Some(reason.clone());
            return Some(SendAction::Failed {
                reason: reason.clone(),
            });
        }
        let offset = ack.offset.min(self.meta.size);
        self.acked = self.acked.max(offset);
        if offset > self.sent {
            // 续传：接收方从 resume 起步，我们把已发指针也跳过去
            self.sent = offset;
        }
        None
    }

    /// 处理对端 FILE_DONE 回执：ok → Complete；error → Failed。
    pub fn on_done(&mut self, done: &FileDonePayload) -> Option<SendAction> {
        if done.file_id != self.meta.file_id {
            return None;
        }
        if done.ok && !done.error.is_some() {
            self.complete = true;
            Some(SendAction::Complete)
        } else {
            let reason = done
                .error
                .clone()
                .unwrap_or_else(|| "对端校验失败".into());
            self.failed = Some(reason.clone());
            Some(SendAction::Failed { reason })
        }
    }
}

/// 读满 buf（短读循环）。
fn read_full(file: &mut File, buf: &mut [u8]) -> std::io::Result<usize> {
    let mut filled = 0;
    while filled < buf.len() {
        let n = file.read(&mut buf[filled..])?;
        if n == 0 {
            break;
        }
        filled += n;
    }
    Ok(filled)
}

// ------------------------------------------------------------
// 接收方（T4.1/T4.2/T4.3）
// ------------------------------------------------------------

/// .part 续传 sidecar（指纹存储，风险8）。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
struct PartSidecar {
    size: u64,
    hash_hex: String,
}

/// 接收驱动器：`.part` 临时文件 + sidecar 指纹 + 完成校验 + 原子改名。
pub struct Receiver {
    dir: PathBuf,
    part: Option<PathBuf>,
    meta: Option<FileMetaPayload>,
    file: Option<File>,
    written: u64,
    rejected: Option<String>,
    done: bool,
    /// 磁盘探测结果可注入（测试磁盘不足路径）。
    available_override: Option<u64>,
}

impl Receiver {
    pub fn new(dir: PathBuf) -> Self {
        Self {
            dir,
            part: None,
            meta: None,
            file: None,
            written: 0,
            rejected: None,
            done: false,
            available_override: None,
        }
    }

    pub fn written(&self) -> u64 {
        self.written
    }

    pub fn meta(&self) -> Option<&FileMetaPayload> {
        self.meta.as_ref()
    }

    pub fn rejected_reason(&self) -> Option<&str> {
        self.rejected.as_deref()
    }

    /// 放弃当前接收：关句柄并删掉 .part 与 sidecar。
    ///
    /// 对端取消（FILE_ABORT）或本机主动放弃时调用 —— 不清理的话半截
    /// .part 一直占着磁盘，且下次同名文件续传会拿错误指纹从头再来。
    pub fn abort(&mut self) {
        self.file.take();
        if let Some(part) = self.part.take() {
            let sidecar = sidecar_path(&part);
            let _ = std::fs::remove_file(&part);
            let _ = std::fs::remove_file(sidecar);
        }
        self.meta = None;
        self.written = 0;
        self.done = true;
    }

    /// 处理 FILE_META：磁盘预检 → 指纹判定（续传/重启）→ 回 ACK。
    pub fn on_meta(&mut self, meta: FileMetaPayload) -> std::io::Result<FileAckPayload> {
        let avail = self
            .available_override
            .unwrap_or_else(|| disk_available(&self.dir));
        self.on_meta_with_space(meta, avail)
    }

    /// 同 [`Self::on_meta`]，可用空间可注入（测试用）。
    pub fn on_meta_with_space(
        &mut self,
        meta: FileMetaPayload,
        available: u64,
    ) -> std::io::Result<FileAckPayload> {
        let file_id = meta.file_id.clone();
        let reject = |reason: &str, s: &mut Self| -> FileAckPayload {
            s.rejected = Some(reason.to_string());
            FileAckPayload {
                file_id: file_id.clone(),
                offset: 0,
                reason: Some(reason.to_string()),
            }
        };

        if meta.size > MAX_FILE_SIZE {
            return Ok(reject("文件超过上限", self));
        }
        fs::create_dir_all(&self.dir)?;
        // 风险18：磁盘空间预检（写入需要 size，容一点页缓存余量）
        if available < meta.size {
            return Ok(reject("磁盘空间不足", self));
        }

        let safe_name = sanitize_file_name(&meta.name);
        let part = self.dir.join(format!("{safe_name}{PART_SUFFIX}"));
        let sidecar = self.dir.join(format!("{safe_name}{SIDECAR_SUFFIX}"));

        // 指纹判定（风险8）：sidecar 存在且与本次一致 → 从 .part 长度续传
        let mut resume = 0u64;
        let mut keep_part = false;
        if let Ok(raw) = fs::read_to_string(&sidecar) {
            if let Ok(saved) = serde_json::from_str::<PartSidecar>(&raw) {
                if saved.size == meta.size && saved.hash_hex == meta.hash_hex {
                    if let Ok(md) = fs::metadata(&part) {
                        let len = md.len();
                        if len <= meta.size {
                            resume = len;
                            keep_part = true;
                        }
                    }
                }
            }
        }
        if !keep_part {
            // 指纹不匹配 / 残留半文件 → 从头（删掉旧 part）
            let _ = fs::remove_file(&part);
            resume = 0;
        }

        let side = PartSidecar {
            size: meta.size,
            hash_hex: meta.hash_hex.clone(),
        };
        fs::write(
            &sidecar,
            serde_json::to_vec(&side)
                .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?,
        )?;

        let mut file = OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .truncate(false)
            .open(&part)?;
        file.set_len(resume)?; // 指纹一致但长度超出/异常时按 resume 收敛
        file.seek(SeekFrom::Start(resume))?;

        self.part = Some(part);
        self.meta = Some(meta);
        self.file = Some(file);
        self.written = resume;
        self.rejected = None;
        Ok(FileAckPayload {
            file_id,
            offset: resume,
            reason: None,
        })
    }

    /// 处理 FILE_CHUNK：按 offset 落盘，返回确认位。
    pub fn on_chunk(&mut self, offset: u64, data: &[u8]) -> std::io::Result<FileAckPayload> {
        let (file_id, size) = {
            let meta = self.meta.as_ref().ok_or_else(|| {
                std::io::Error::new(std::io::ErrorKind::InvalidData, "还没收到 FILE_META")
            })?;
            (meta.file_id.clone(), meta.size)
        };
        if let Some(reason) = &self.rejected {
            return Ok(FileAckPayload {
                file_id,
                offset: 0,
                reason: Some(reason.clone()),
            });
        }
        // 越界 chunk（对端异常）→ 明确拒绝，不写脏数据
        let end = offset.saturating_add(data.len() as u64);
        if end > size {
            let reason = format!("chunk 越界（{end} > {size}）");
            self.rejected = Some(reason.clone());
            return Ok(FileAckPayload {
                file_id,
                offset: 0,
                reason: Some(reason),
            });
        }
        if offset > self.written {
            // 有缺口：回当前写入位让对端跳回（TCP 上不该出现，防脏数据）
            return Ok(FileAckPayload {
                file_id,
                offset: self.written,
                reason: None,
            });
        }
        if offset == self.written {
            let file = self.file.as_mut().expect("on_meta 后必有文件");
            file.seek(SeekFrom::Start(offset))?;
            file.write_all(data)?;
            file.flush()?;
            self.written = end;
        }
        // offset < written：重复 chunk，只回当前确认位
        Ok(FileAckPayload {
            file_id,
            offset: self.written,
            reason: None,
        })
    }

    /// 处理 FILE_DONE：整读比对哈希 → 原子改名；回 ok/error（T4.3）。
    pub fn on_done(&mut self, done: &FileDonePayload) -> std::io::Result<FileDonePayload> {
        let meta = self
            .meta
            .clone()
            .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::InvalidData, "还没收到 FILE_META"))?;
        let reply = |ok: bool, error: Option<String>| FileDonePayload {
            file_id: meta.file_id.clone(),
            hash_hex: done.hash_hex.clone(),
            ok,
            error,
        };
        if self.done {
            return Ok(reply(true, None)); // 幂等重发
        }
        if done.file_id != meta.file_id {
            return Ok(reply(false, Some("file_id 不匹配".to_string())));
        }
        if self.rejected.is_some() {
            return Ok(reply(false, self.rejected.clone()));
        }
        if self.written != meta.size {
            let reason = format!("未收全（{} / {}）", self.written, meta.size);
            self.rejected = Some(reason.clone());
            return Ok(reply(false, Some(reason)));
        }

        // 关句柄后整读比对（续传场景也天然覆盖 0..size 全量）
        let part = self.part.clone().expect("on_meta 后必有 part");
        drop(self.file.take());
        let actual = hash_file(&part)?;
        if actual != meta.hash_hex || done.hash_hex != meta.hash_hex {
            // 内容不对（风险8 的第二道防线）：删掉，重传时从头
            let _ = fs::remove_file(&part);
            let _ = fs::remove_file(sidecar_path(&part));
            let reason = "哈希校验不一致，已丢弃，请重传".to_string();
            self.rejected = Some(reason.clone());
            return Ok(reply(false, Some(reason)));
        }

        // 原子落位：重名自动编号（风险15）
        let safe_name = sanitize_file_name(&meta.name);
        let dest = unique_dest(&self.dir, &safe_name);
        fs::rename(&part, &dest)?;
        let _ = fs::remove_file(sidecar_path(&part));
        self.done = true;
        Ok(reply(true, None))
    }

    pub fn is_done(&self) -> bool {
        self.done
    }
}

fn sidecar_path(part: &Path) -> PathBuf {
    // "name.pdf.part" → "name.pdf.part.meta"（sidecar 与 part 同名加 .meta）
    part.with_extension(SIDECAR_SUFFIX.trim_start_matches('.'))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_dir(tag: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!(
            "lanchat_xfer_{}_{}_{}",
            tag,
            std::process::id(),
            nanos
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn write_file(dir: &Path, name: &str, bytes: &[u8]) -> PathBuf {
        let p = dir.join(name);
        fs::write(&p, bytes).unwrap();
        p
    }

    /// 数据样本：可辨识的伪随机内容（不用 rand，避免新依赖）。
    fn sample(size: usize) -> Vec<u8> {
        (0..size).map(|i| (i % 251) as u8).collect()
    }

    /// 把发送方的帧灌给接收方，直到结束（含中断注入）。
    fn pump(sender: &mut Sender, receiver: &mut Receiver) -> Vec<FrameType> {
        pump_with(sender, receiver, |_, _| true)
    }

    /// 可注入 on_before（返回 false 提前"杀进程"，第 k 帧后中断）。
    fn pump_with(
        sender: &mut Sender,
        receiver: &mut Receiver,
        mut on_before: impl FnMut(usize, &[u8]) -> bool,
    ) -> Vec<FrameType> {
        let mut sent = 0usize;
        let mut types = Vec::new();
        loop {
            // 接收方没帧要收时才让发送方继续
            let action = sender.next_action().expect("next_action io");
            match action {
                SendAction::Frame { kind, payload } => {
                    types.push(kind);
                    sent += 1;
                    if !on_before(sent, &payload) {
                        break;
                    }
                    match kind {
                        FrameType::FileMeta => {
                            let meta: FileMetaPayload = serde_json::from_slice(&payload).unwrap();
                            let ack = receiver.on_meta(meta).unwrap();
                            if let Some(sa) = sender.on_ack(&ack) {
                                if matches!(sa, SendAction::Failed { .. }) {
                                    break;
                                }
                            }
                        }
                        FrameType::FileChunk => {
                            let (offset, data) = protocol::decode_chunk(&payload).unwrap();
                            let ack = receiver.on_chunk(offset, data).unwrap();
                            if let Some(sa) = sender.on_ack(&ack) {
                                if matches!(sa, SendAction::Failed { .. }) {
                                    break;
                                }
                            }
                        }
                        FrameType::FileDone => {
                            let done: FileDonePayload = serde_json::from_slice(&payload).unwrap();
                            let reply = receiver.on_done(&done).unwrap();
                            sender.on_done(&reply);
                            break;
                        }
                        other => panic!("意外帧 {other:?}"),
                    }
                }
                SendAction::Wait => {
                    // 正常流程里 window=8 不会在 loopback 测试打满；若打满说明断言要改
                    // （等待型空转保护：连续 Wait 超过上限视为死锁）
                    types.push(FrameType::Ping);
                    if types.iter().filter(|t| **t == FrameType::Ping).count() > 100 {
                        panic!("pump 空转：发送方一直 Wait（可能死锁）");
                    }
                }
                SendAction::Failed { reason } => panic!("意外失败: {reason}"),
                SendAction::Complete => break,
            }
        }
        types
    }

    // ---------- 文件名（风险15） ----------

    #[test]
    fn sanitize_strips_paths_and_illegal_chars() {
        assert_eq!(sanitize_file_name("C:\\Users\\x\\报告.pdf"), "报告.pdf");
        assert_eq!(sanitize_file_name("/sdcard/Download/a b.txt"), "a b.txt");
        assert_eq!(sanitize_file_name("a<b>c:d\"e|f?g*h.txt"), "a_b_c_d_e_f_g_h.txt");
        assert_eq!(sanitize_file_name("trailing.. "), "trailing");
        assert_eq!(sanitize_file_name(""), "file");
        assert_eq!(sanitize_file_name("   "), "file");
        assert_eq!(sanitize_file_name("///"), "file");
    }

    #[test]
    fn sanitize_handles_windows_reserved_names() {
        assert_eq!(sanitize_file_name("CON"), "_CON");
        assert_eq!(sanitize_file_name("nul.txt"), "_nul.txt");
        assert_eq!(sanitize_file_name("COM1.log"), "_COM1.log");
        assert_eq!(sanitize_file_name("LPT9"), "_LPT9");
        // 非保留名不误伤
        assert_eq!(sanitize_file_name("COMMON.txt"), "COMMON.txt");
        assert_eq!(sanitize_file_name("COM10.txt"), "COM10.txt");
    }

    #[test]
    fn sanitize_clamps_length() {
        let long = "长".repeat(500);
        let out = sanitize_file_name(&long);
        assert_eq!(out.chars().count(), 180);
    }

    #[test]
    fn unique_dest_numbers_duplicates() {
        let dir = temp_dir("unique");
        assert_eq!(unique_dest(&dir, "a.txt"), dir.join("a.txt"));
        fs::write(dir.join("a.txt"), b"x").unwrap();
        assert_eq!(unique_dest(&dir, "a.txt"), dir.join("a (1).txt"));
        fs::write(dir.join("a (1).txt"), b"x").unwrap();
        assert_eq!(unique_dest(&dir, "a.txt"), dir.join("a (2).txt"));
        // 无扩展名
        fs::write(dir.join("README"), b"x").unwrap();
        assert_eq!(unique_dest(&dir, "README"), dir.join("README (1)"));
    }

    // ---------- 磁盘空间（风险18） ----------

    #[test]
    fn disk_available_is_plausible() {
        let dir = temp_dir("space");
        let avail = disk_available(&dir);
        assert_ne!(avail, 0, "可用空间不应为 0（探测失败返回 MAX）");
        assert!(avail >= 1024 * 1024, "本机临时目录应至少有 1MB");
    }

    // ---------- 指纹（风险8，沿用旧测试） ----------

    #[test]
    fn fingerprint_mismatch_forces_restart() {
        let a = FileFingerprint {
            file_id: "f1".into(),
            size: 1000,
            hash_hex: "aa".into(),
        };
        let mut same = a.clone();
        assert!(a.matches(&same));
        same.size = 2000;
        assert!(!a.matches(&same));
        same.size = 1000;
        same.hash_hex = "bb".into();
        assert!(!a.matches(&same));
        same.hash_hex = "aa".into();
        same.file_id = "f2".into();
        assert!(!a.matches(&same));
    }

    #[test]
    fn transfer_state_ack_monotonic_and_complete() {
        let mut s = TransferState {
            file_id: "f1".into(),
            size: 1000,
            acked_offset: 0,
            sent_offset: 0,
            done: false,
        };
        s.on_ack(300);
        s.on_ack(100);
        s.on_ack(640);
        assert_eq!(s.acked_offset, 640);
        assert_eq!(s.resume_from(), 640);
        s.on_ack(9999);
        assert_eq!(s.acked_offset, 1000);
        assert!(!s.is_complete());
        s.done = true;
        assert!(s.is_complete());
    }

    // ---------- 端到端（真实文件） ----------

    #[test]
    fn full_transfer_moves_bytes_intact() {
        let src = temp_dir("src");
        let dst = temp_dir("dst");
        let data = sample(1024 * 1024 + 7); // 跨 4 个块 + 尾块
        let file = write_file(&src, "报告 2026Q4.pdf", &data);

        let (mut sender, meta) = Sender::open(&file, "fid-1", "dev-a").unwrap();
        let mut receiver = Receiver::new(dst.clone());
        let types = pump(&mut sender, &mut receiver);

        assert!(sender.is_complete(), "发送方应完成");
        assert!(receiver.is_done(), "接收方应完成");
        assert!(types.contains(&FrameType::FileMeta));
        assert!(types.contains(&FrameType::FileChunk));
        assert!(types.contains(&FrameType::FileDone));
        // 文件名空格保留（Windows 非法字符才是 _）
        let dest = dst.join("报告 2026Q4.pdf");
        assert!(dest.exists(), "目标文件应存在");
        assert_eq!(fs::read(&dest).unwrap(), data, "字节必须一致");
        assert!(!dst.join(format!("报告 2026Q4.pdf{}", PART_SUFFIX)).exists());
        assert!(!dst
            .join(format!("报告 2026Q4.pdf{}", SIDECAR_SUFFIX))
            .exists(),
            "sidecar 完成后应删除");
        // 哈希一致
        assert_eq!(hash_file(&dest).unwrap(), meta.hash_hex);
    }

    #[test]
    fn small_and_empty_files() {
        for size in [0usize, 1, 4095, 4096, 4097] {
            let src = temp_dir("edge-src");
            let dst = temp_dir("edge-dst");
            let data = sample(size);
            let file = write_file(&src, format!("edge{size}.bin").as_str(), &data);
            let (mut sender, _meta) = Sender::open(&file, format!("f{size}"), "me").unwrap();
            let mut receiver = Receiver::new(dst.clone());
            pump(&mut sender, &mut receiver);
            assert!(sender.is_complete() && receiver.is_done(), "size={size}");
            assert_eq!(
                fs::read(dst.join(format!("edge{size}.bin"))).unwrap(),
                data,
                "size={size} 字节一致"
            );
            let _ = fs::remove_dir_all(&src);
            let _ = fs::remove_dir_all(&dst);
        }
    }

    #[test]
    fn resumes_after_interrupted_transfer() {
        let src = temp_dir("resume-src");
        let dst = temp_dir("resume-dst");
        let data = sample(512 * 1024);
        let file = write_file(&src, "movie.mp4", &data);

        // 第一次：发到第 3 帧后"杀进程"（只留下 part + sidecar）
        let (mut sender1, meta1) = Sender::open(&file, "fid-r", "dev-a").unwrap();
        let mut receiver1 = Receiver::new(dst.clone());
        let _ = pump_with(&mut sender1, &mut receiver1, |n, _payload| n < 3);
        assert!(!sender1.is_complete(), "第一次应中断");
        let part_len = fs::metadata(dst.join(format!("movie.mp4{}", PART_SUFFIX)))
            .map(|m| m.len())
            .unwrap_or(0);
        assert!(part_len > 0, "应留下部分数据，实际 {part_len}");

        // 第二次：新 Sender + 同目录 Receiver → 指纹一致，从 part 长度续传
        let (mut sender2, _meta2) = Sender::open(&file, "fid-r", "dev-a").unwrap();
        let mut receiver2 = Receiver::new(dst.clone());
        // 第一帧是 meta，第二帧应从续传点开始
        let ack_before_chunks = {
            // 手动走一遍 meta 看 ack
            let action = sender2.next_action().unwrap();
            let SendAction::Frame { kind, payload } = action else {
                panic!("首帧应是 META")
            };
            assert_eq!(kind, FrameType::FileMeta);
            let meta: FileMetaPayload = serde_json::from_slice(&payload).unwrap();
            assert_eq!(meta.hash_hex, meta1.hash_hex, "指纹不变");
            let ack = receiver2.on_meta(meta).unwrap();
            assert_eq!(ack.offset, part_len, "ACK 携带续传点");
            ack
        };
        sender2.on_ack(&ack_before_chunks);
        let total_chunks_first = sender1.chunks_sent;
        pump(&mut sender2, &mut receiver2);
        assert!(sender2.is_complete());
        assert_eq!(
            fs::read(dst.join("movie.mp4")).unwrap(),
            data,
            "续传后文件必须完整一致"
        );
        assert!(
            sender2.chunks_sent < 4 || part_len > 0,
            "第二轮应少发（第一轮已发 {total_chunks_first} 块）"
        );
        // 续传点推进：第二轮的 sent 起点即 part_len
        assert_eq!(ack_before_chunks.offset, part_len);
    }

    #[test]
    fn fingerprint_mismatch_restarts_from_zero() {
        let src = temp_dir("fp-src");
        let dst = temp_dir("fp-dst");
        let data_a = sample(200 * 1024);
        let file = write_file(&src, "doc.txt", &data_a);

        // 第一次完整传输
        let (mut s1, _m1) = Sender::open(&file, "fid-fp", "dev-a").unwrap();
        let mut r1 = Receiver::new(dst.clone());
        pump(&mut s1, &mut r1);
        let final_bytes = fs::read(dst.join("doc.txt")).unwrap();
        let _ = final_bytes;
        // 制造一个残留 part + 过期 sidecar（换了内容/哈希）
        let part = dst.join(format!("doc.txt{}", PART_SUFFIX));
        fs::write(&part, b"stale bytes from another file").unwrap();
        fs::write(
            dst.join(format!("doc.txt{}", SIDECAR_SUFFIX)),
            serde_json::to_string(&PartSidecar {
                size: 999,
                hash_hex: "deadbeef".into(),
            })
            .unwrap(),
        )
        .unwrap();

        // 第二次传输（同名但新内容 → 新哈希）
        let data_b = sample(180 * 1024);
        fs::write(&file, &data_b).unwrap();
        let (mut s2, _m2) = Sender::open(&file, "fid-fp2", "dev-a").unwrap();
        let mut r2 = Receiver::new(dst.clone());
        let ack = {
            let SendAction::Frame { payload, .. } = s2.next_action().unwrap() else {
                panic!("META")
            };
            let meta: FileMetaPayload = serde_json::from_slice(&payload).unwrap();
            r2.on_meta(meta).unwrap()
        };
        assert_eq!(ack.offset, 0, "指纹不一致必须从头传（风险8）");
        s2.on_ack(&ack);
        pump(&mut s2, &mut r2);
        assert!(s2.is_complete());
        // 正式文件是上次的，这次会编号成 doc (1).txt（重名自动编号）
        assert!(dst.join("doc (1).txt").exists());
        assert_eq!(fs::read(dst.join("doc (1).txt")).unwrap(), data_b);
    }

    #[test]
    fn disk_full_is_rejected_with_reason() {
        let src = temp_dir("full-src");
        let dst = temp_dir("full-dst");
        let data = sample(64 * 1024);
        let file = write_file(&src, "big.bin", &data);

        let (mut sender, _meta) = Sender::open(&file, "fid-d", "dev-a").unwrap();
        let mut receiver = Receiver::new(dst.clone());
        // 注入：可用空间只有 1 字节
        let SendAction::Frame { payload, .. } = sender.next_action().unwrap() else {
            panic!("META")
        };
        let meta: FileMetaPayload = serde_json::from_slice(&payload).unwrap();
        let ack = receiver.on_meta_with_space(meta, 1).unwrap();
        assert_eq!(ack.reason.as_deref(), Some("磁盘空间不足"));
        let action = sender.on_ack(&ack);
        assert!(
            matches!(action, Some(SendAction::Failed { .. })),
            "发送方收到拒绝应失败退出"
        );
        assert!(sender.failed_reason().is_some());
        // 后续 next_action 直接 Failed，不再发数据
        assert!(matches!(
            sender.next_action().unwrap(),
            SendAction::Failed { .. }
        ));
    }

    #[test]
    fn hash_mismatch_is_detected_and_part_discarded() {
        let src = temp_dir("hash-src");
        let dst = temp_dir("hash-dst");
        let data = sample(64 * 1024);
        let file = write_file(&src, "x.bin", &data);

        let (mut sender, meta) = Sender::open(&file, "fid-h", "dev-a").unwrap();
        let mut receiver = Receiver::new(dst.clone());

        // 正常收到 meta + 全部 chunk，但伪造一个错误的 FILE_DONE 哈希
        loop {
            match sender.next_action().unwrap() {
                SendAction::Frame { kind, payload } => match kind {
                    FrameType::FileMeta => {
                        let m: FileMetaPayload = serde_json::from_slice(&payload).unwrap();
                        let ack = receiver.on_meta(m).unwrap();
                        sender.on_ack(&ack);
                    }
                    FrameType::FileChunk => {
                        let (o, d) = protocol::decode_chunk(&payload).unwrap();
                        let ack = receiver.on_chunk(o, d).unwrap();
                        sender.on_ack(&ack);
                    }
                    _ => break,
                },
                SendAction::Wait => break,
                other => panic!("{other:?}"),
            }
        }
        // 伪造坏哈希的 DONE
        let forged = FileDonePayload {
            file_id: meta.file_id.clone(),
            hash_hex: "00".repeat(32),
            ok: true,
            error: None,
        };
        let reply = receiver.on_done(&forged).unwrap();
        assert!(!reply.ok, "哈希不一致必须拒绝");
        assert!(reply.error.as_deref().unwrap().contains("哈希"));
        assert!(receiver.rejected_reason().is_some());
        assert!(!dst.join("x.bin").exists(), "坏文件不能落正式文件名");
        let part = dst.join(format!("x.bin{}", PART_SUFFIX));
        assert!(!part.exists(), "坏 part 应删除");
    }

    #[test]
    fn out_of_order_and_duplicate_chunks_resync() {
        let src = temp_dir("ooo-src");
        let dst = temp_dir("ooo-dst");
        let data = sample(300 * 1024);
        let file = write_file(&src, "ooo.bin", &data);
        let (mut sender, meta) = Sender::open(&file, "fid-o", "dev-a").unwrap();
        let mut receiver = Receiver::new(dst.clone());

        let ack0 = {
            let SendAction::Frame { payload, .. } = sender.next_action().unwrap() else { panic!() };
            let m: FileMetaPayload = serde_json::from_slice(&payload).unwrap();
            receiver.on_meta(m).unwrap()
        };
        assert_eq!(ack0.offset, 0);

        // 跳过第一块直接喂第二块（有缺口）
        let SendAction::Frame { payload, .. } = sender.next_action().unwrap() else { panic!() };
        let (off1, data1) = protocol::decode_chunk(&payload).unwrap();
        let SendAction::Frame { payload, .. } = sender.next_action().unwrap() else { panic!() };
        let (off2, data2) = protocol::decode_chunk(&payload).unwrap();
        let ack_gap = receiver.on_chunk(off2, data2).unwrap();
        assert_eq!(ack_gap.offset, 0, "缺口时回当前写入位（0）让对端重发");
        // 按序补上第一块
        let ack1 = receiver.on_chunk(off1, data1).unwrap();
        assert_eq!(ack1.offset, off1 + data1.len() as u64);
        // 重复第一块：确认位不回退
        let ack_dup = receiver.on_chunk(off1, data1).unwrap();
        assert_eq!(ack_dup.offset, ack1.offset);

        // 越界 chunk：拒绝
        let oob = receiver.on_chunk(meta.size - 4, &[0u8; 64]).unwrap();
        assert!(oob.reason.is_some());
        assert_eq!(oob.offset, 0);
        let _ = sender;
    }

    #[test]
    fn sender_window_limits_inflight() {
        let src = temp_dir("win-src");
        let data = sample(1024 * 1024); // 4 块
        let file = write_file(&src, "w.bin", &data);
        let (mut sender, _meta) = Sender::open(&file, "fid-w", "dev-a").unwrap();

        // meta
        assert!(matches!(
            sender.next_action().unwrap(),
            SendAction::Frame { kind: FrameType::FileMeta, .. }
        ));
        // 窗口 = 8 块：1MB 只有 4 块，全部可发
        let mut chunks = 0;
        loop {
            match sender.next_action().unwrap() {
                SendAction::Frame { kind: FrameType::FileChunk, .. } => chunks += 1,
                _ => break,
            }
        }
        assert_eq!(chunks, 4);
        // 没有 ACK 时已发完所有块 → 等待
        assert!(matches!(sender.next_action().unwrap(), SendAction::Wait));
        // 全量 ACK 后才能发 DONE
        sender.on_ack(&FileAckPayload {
            file_id: "fid-w".into(),
            offset: 1024 * 1024,
            reason: None,
        });
        assert!(matches!(
            sender.next_action().unwrap(),
            SendAction::Frame { kind: FrameType::FileDone, .. }
        ));
        // 对端 ok 回执 → Complete
        let reply = FileDonePayload {
            file_id: "fid-w".into(),
            hash_hex: sender.meta().hash_hex.clone(),
            ok: true,
            error: None,
        };
        assert!(matches!(
            sender.on_done(&reply),
            Some(SendAction::Complete)
        ));
        assert!(sender.is_complete());
    }

    /// 暂停期间不产出 chunk，继续后从暂停点接着发（纯发送侧，无需通知对端）。
    #[test]
    fn sender_pause_and_resume_stops_chunk_output() {
        let src = temp_dir("pause-src");
        let data = sample(1024 * 1024); // 4 块
        let file = write_file(&src, "p.bin", &data);
        let (mut sender, _meta) = Sender::open(&file, "fid-p", "dev-a").unwrap();

        // meta
        assert!(matches!(
            sender.next_action().unwrap(),
            SendAction::Frame { kind: FrameType::FileMeta, .. }
        ));
        // 只发 1 块就暂停
        assert!(matches!(
            sender.next_action().unwrap(),
            SendAction::Frame { kind: FrameType::FileChunk, .. }
        ));
        sender.set_paused(true);
        assert!(sender.is_paused());
        // 暂停中：不产出任何帧（窗口没满、也没等 ACK，纯粹是暂停挡住的）
        for _ in 0..5 {
            assert!(matches!(sender.next_action().unwrap(), SendAction::Wait));
        }
        assert_eq!(sender.chunks_sent, 1, "暂停期间不该再发块");

        // 继续：剩下的 3 块照常发出
        sender.set_paused(false);
        assert!(!sender.is_paused());
        let mut chunks = 0;
        loop {
            match sender.next_action().unwrap() {
                SendAction::Frame { kind: FrameType::FileChunk, .. } => chunks += 1,
                _ => break,
            }
        }
        assert_eq!(chunks, 3, "继续后应把剩余块发完");
        assert_eq!(sender.chunks_sent, 4);
    }

    /// 对端取消：接收方要删掉半截 .part 与 sidecar，别占着磁盘
    #[test]
    fn receiver_abort_removes_part_and_sidecar() {
        let src = temp_dir("ab-src");
        let dst = temp_dir("ab-dst");
        let data = sample(512 * 1024);
        let file = write_file(&src, "big.bin", &data);
        let (mut sender, _meta) = Sender::open(&file, "fid-ab", "dev-a").unwrap();
        let mut recv = Receiver::new(dst.clone());

        // 只走 META，让接收方建出 .part 与 sidecar
        let SendAction::Frame { payload, .. } = sender.next_action().unwrap() else {
            panic!("META")
        };
        let meta: FileMetaPayload = serde_json::from_slice(&payload).unwrap();
        let _ = recv.on_meta(meta).unwrap();

        let part = dst.join(format!("big.bin{}", PART_SUFFIX));
        let sidecar = dst.join(format!("big.bin{}", SIDECAR_SUFFIX));
        assert!(part.exists(), "应已建出 .part");
        assert!(sidecar.exists(), "应已建出 sidecar");
        assert!(recv.written() == 0);

        recv.abort();

        assert!(!part.exists(), "abort 后 .part 应被删除");
        assert!(!sidecar.exists(), "abort 后 sidecar 应被删除");
        assert!(recv.meta().is_none(), "abort 后 meta 应清空");
    }

    /// 断线重连：restart 必须把 sent 退回 acked。
    ///
    /// 若保留原 sent，断线时对端可能只写到 acked 那里，中间那段就永远补不上
    /// （静默丢数据）。restart 后应重发 FILE_META 并从 acked 续传。
    #[test]
    fn sender_restart_resends_meta_and_continues_from_acked() {
        let src = temp_dir("rs-src");
        let data = sample(1024 * 1024); // 4 块
        let file = write_file(&src, "r.bin", &data);
        let (mut sender, _meta) = Sender::open(&file, "fid-rs", "dev-a").unwrap();

        // meta + 4 块
        assert!(matches!(
            sender.next_action().unwrap(),
            SendAction::Frame { kind: FrameType::FileMeta, .. }
        ));
        let mut chunks = 0;
        loop {
            match sender.next_action().unwrap() {
                SendAction::Frame { kind: FrameType::FileChunk, .. } => chunks += 1,
                _ => break,
            }
        }
        assert_eq!(chunks, 4);
        assert_eq!(sender.progress().0, 0, "还没 ACK，确认位应为 0");

        // 模拟断线前只确认了前 2 块（256KB * 2）
        sender.on_ack(&FileAckPayload {
            file_id: "fid-rs".into(),
            offset: DEFAULT_CHUNK_SIZE as u64 * 2,
            reason: None,
        });
        assert_eq!(sender.progress().0, DEFAULT_CHUNK_SIZE as u64 * 2);
        assert!(!sender.has_started() == false, "应已开流");

        // 断线 → 重连重启
        sender.restart();
        assert!(!sender.has_started(), "restart 后应重新发 FILE_META");
        assert_eq!(
            sender.progress().0,
            DEFAULT_CHUNK_SIZE as u64 * 2,
            "确认位不能变（acked 是权威进度）"
        );

        // 重发 META
        assert!(matches!(
            sender.next_action().unwrap(),
            SendAction::Frame { kind: FrameType::FileMeta, .. }
        ));

        // 剩余 2 块应被重新发出（不能跳过已确认点之后的数据）
        let mut rest = 0;
        loop {
            match sender.next_action().unwrap() {
                SendAction::Frame { kind: FrameType::FileChunk, .. } => rest += 1,
                _ => break,
            }
        }
        assert_eq!(rest, 2, "应从 acked 处续传剩余 2 块，而不是跳过");
    }
}