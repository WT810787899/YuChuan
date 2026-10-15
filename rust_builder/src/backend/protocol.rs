//! 二进制帧协议（PLAN §4 协议草案）。
//!
//! 帧头: `magic "LCHT"(4B) | version(1B) | type(1B) | length(4B, LE) | payload`
//!
//! payload 为 JSON（serde 结构见下方 `*Payload`），v2 若上加密则整帧替换。

use serde::{Deserialize, Serialize};

/// 协议魔数。
pub const MAGIC: [u8; 4] = *b"LCHT";
/// 当前协议版本（HELLO 能力协商用，风险10）。
pub const VERSION: u8 = 1;
/// 帧头长度。
pub const HEADER_LEN: usize = 10;
/// 单帧 payload 上限（防内存滥用；分块传输按 chunk 切分）。
pub const MAX_PAYLOAD: usize = 8 * 1024 * 1024;

/// 帧类型（PLAN §4 type 表）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum FrameType {
    Hello = 0x01,
    HelloAck = 0x02,
    PairReq = 0x10,
    PairResp = 0x11,
    Text = 0x20,
    FileMeta = 0x30,
    FileChunk = 0x31,
    FileAck = 0x32,
    FileDone = 0x33,
    /// 发起方取消传输：接收方据此丢弃 .part 并停止。
    ///
    /// 取消是**双端语义** —— 光删本地 job 不够，对端会一直等 chunk 直到
    /// 超时，进度条也停在半路（用户反馈「取消时双方没同步」）。
    FileAbort = 0x34,
    Ping = 0x40,
    Pong = 0x41,
    Bye = 0x7F,
}

impl FrameType {
    pub fn from_u8(v: u8) -> Option<Self> {
        Some(match v {
            0x01 => Self::Hello,
            0x02 => Self::HelloAck,
            0x10 => Self::PairReq,
            0x11 => Self::PairResp,
            0x20 => Self::Text,
            0x30 => Self::FileMeta,
            0x31 => Self::FileChunk,
            0x32 => Self::FileAck,
            0x33 => Self::FileDone,
            0x34 => Self::FileAbort,
            0x40 => Self::Ping,
            0x41 => Self::Pong,
            0x7F => Self::Bye,
            _ => return None,
        })
    }
}

/// 解码错误（回环/集成测试覆盖，对应风险9）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DecodeError {
    BadMagic,
    BadVersion(u8),
    UnknownType(u8),
    LengthTooLarge(usize),
}

impl std::fmt::Display for DecodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::BadMagic => write!(f, "bad magic"),
            Self::BadVersion(v) => write!(f, "unsupported protocol version {v}"),
            Self::UnknownType(t) => write!(f, "unknown frame type 0x{t:02X}"),
            Self::LengthTooLarge(n) => write!(f, "payload length {n} exceeds limit"),
        }
    }
}

impl std::error::Error for DecodeError {}

/// 一个已解析的帧。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub kind: FrameType,
    pub payload: Vec<u8>,
}

/// 编码一帧。
pub fn encode(kind: FrameType, payload: &[u8]) -> Vec<u8> {
    debug_assert!(payload.len() <= MAX_PAYLOAD, "payload exceeds MAX_PAYLOAD");
    let mut out = Vec::with_capacity(HEADER_LEN + payload.len());
    out.extend_from_slice(&MAGIC);
    out.push(VERSION);
    out.push(kind as u8);
    out.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    out.extend_from_slice(payload);
    out
}

/// 从字节流解码一帧。
///
/// 返回 `Ok(None)` 表示缓冲区数据尚不完整（半包），调用方继续读取；
/// `Ok(Some((frame, consumed)))` 表示成功解析并消费 `consumed` 字节（粘包时
/// 剩余字节属于下一帧）。
pub fn decode(buf: &[u8]) -> Result<Option<(Frame, usize)>, DecodeError> {
    if buf.len() < HEADER_LEN {
        return Ok(None);
    }
    if buf[0..4] != MAGIC {
        return Err(DecodeError::BadMagic);
    }
    let version = buf[4];
    if version != VERSION {
        return Err(DecodeError::BadVersion(version));
    }
    let kind = FrameType::from_u8(buf[5]).ok_or(DecodeError::UnknownType(buf[5]))?;
    let len = u32::from_le_bytes([buf[6], buf[7], buf[8], buf[9]]) as usize;
    if len > MAX_PAYLOAD {
        return Err(DecodeError::LengthTooLarge(len));
    }
    let total = HEADER_LEN + len;
    if buf.len() < total {
        return Ok(None);
    }
    Ok(Some((
        Frame {
            kind,
            payload: buf[HEADER_LEN..total].to_vec(),
        },
        total,
    )))
}

// ------------------------------------------------------------
// JSON payload 结构
// ------------------------------------------------------------

/// HELLO / HELLO_ACK：发现与能力协商。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct HelloPayload {
    pub device_id: String,
    pub name: String,
    /// "windows" | "android"
    pub platform: String,
    pub chat_port: u16,
    pub proto_version: u8,
}

/// PAIR_REQ：PIN 配对（风险14：v1 明文，v2 上加密）。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PairReqPayload {
    pub device_id: String,
    pub pin: String,
    /// 发起方本地时间，仅用于日志/展示；超时判定一律用接收方本地单调时钟。
    pub ts_ms: u64,
}

/// PAIR_RESP。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PairRespPayload {
    pub accepted: bool,
    pub reason: Option<String>,
}

/// TEXT：会话内消息，排序依赖 (sender_id, seq) 而非墙钟（风险11）。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TextPayload {
    pub sender_id: String,
    pub seq: u64,
    pub text: String,
    /// 发送方本地时间，仅用于展示；不参与排序。
    pub ts_ms: i64,
}

/// FILE_META：文件指纹 + 续传协商（风险8）。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct FileMetaPayload {
    pub file_id: String,
    pub sender_id: String,
    pub name: String,
    pub size: u64,
    pub chunk_size: u32,
    /// blake3 整文件哈希；续传时用于校验指纹一致性。
    pub hash_hex: String,
    /// 断点续传起点（FILE_ACK 回传的已确认 offset）。
    pub resume_offset: u64,
}

/// FILE_ACK：接收方确认的连续 offset。
///
/// `reason` 非空表示拒绝（磁盘不足 / 指纹非法等），此时 offset 为 0，
/// 发送方直接失败而不是傻等（T4.3 错误处理）。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct FileAckPayload {
    pub file_id: String,
    pub offset: u64,
    #[serde(default)]
    pub reason: Option<String>,
}

/// FILE_DONE：发送方在全部 chunk 被 ACK 后发哈希；接收方校验后回同一结构
/// （双向复用：接收方回 ok=false + error 即传输失败，T4.3）。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct FileDonePayload {
    pub file_id: String,
    /// blake3 整文件哈希（hex）。
    pub hash_hex: String,
    #[serde(default)]
    pub ok: bool,
    #[serde(default)]
    pub error: Option<String>,
}

/// FILE_ABORT：发起方取消传输。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct FileAbortPayload {
    pub file_id: String,
    #[serde(default)]
    pub reason: Option<String>,
}

/// FILE_CHUNK 的 JSON 头（实际分块为: 头帧 + 二进制追加段，v1 简化为
/// payload = 8B offset + raw bytes，非 JSON）。
pub const CHUNK_HEADER_LEN: usize = 8;

/// 构造 FILE_CHUNK payload：`offset(8B, LE) || data`。
pub fn encode_chunk(offset: u64, data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(CHUNK_HEADER_LEN + data.len());
    out.extend_from_slice(&offset.to_le_bytes());
    out.extend_from_slice(data);
    out
}

/// 解析 FILE_CHUNK payload，返回 (offset, data)。
pub fn decode_chunk(payload: &[u8]) -> Option<(u64, &[u8])> {
    if payload.len() < CHUNK_HEADER_LEN {
        return None;
    }
    let mut off = [0u8; 8];
    off.copy_from_slice(&payload[..CHUNK_HEADER_LEN]);
    Some((u64::from_le_bytes(off), &payload[CHUNK_HEADER_LEN..]))
}

// ------------------------------------------------------------
// Tests（T0.3 验收：帧编解码回环 + 粘包/半包覆盖，风险9）
// ------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn text_frame() -> Frame {
        let payload = TextPayload {
            sender_id: "dev-a".into(),
            seq: 42,
            text: "hello 局域网".into(),
            ts_ms: 1_760_000_000_000,
        };
        let bytes = serde_json::to_vec(&payload).unwrap();
        let buf = encode(FrameType::Text, &bytes);
        let (frame, consumed) = decode(&buf).unwrap().unwrap();
        assert_eq!(consumed, buf.len());
        frame
    }

    #[test]
    fn roundtrip_text_json() {
        let frame = text_frame();
        assert_eq!(frame.kind, FrameType::Text);
        let parsed: TextPayload = serde_json::from_slice(&frame.payload).unwrap();
        assert_eq!(parsed.seq, 42);
        assert_eq!(parsed.text, "hello 局域网");
    }

    #[test]
    fn roundtrip_all_frame_types() {
        for v in [
            0x01, 0x02, 0x10, 0x11, 0x20, 0x30, 0x31, 0x32, 0x33, 0x40, 0x41,
            0x7F,
        ] {
            let kind = FrameType::from_u8(v).expect("known type");
            let buf = encode(kind, b"payload");
            let (frame, consumed) = decode(&buf).unwrap().unwrap();
            assert_eq!(frame.kind, kind);
            assert_eq!(frame.payload, b"payload");
            assert_eq!(consumed, buf.len());
        }
    }

    #[test]
    fn partial_header_returns_none() {
        let buf = encode(FrameType::Ping, b"");
        assert_eq!(decode(&buf[..3]).unwrap(), None);
        assert_eq!(decode(&buf[..HEADER_LEN - 1]).unwrap(), None);
    }

    #[test]
    fn partial_payload_returns_none() {
        let buf = encode(FrameType::Text, &[1u8; 64]);
        // header 完整但 payload 只有一半
        assert_eq!(decode(&buf[..HEADER_LEN + 32]).unwrap(), None);
        assert!(decode(&buf).unwrap().is_some());
    }

    #[test]
    fn concatenated_frames_decode_sequentially() {
        let a = encode(FrameType::Ping, b"one");
        let b = encode(FrameType::Pong, b"two-two");
        let mut stream = a.clone();
        stream.extend_from_slice(&b);

        let (f1, n1) = decode(&stream).unwrap().unwrap();
        assert_eq!(f1.payload, b"one");
        assert_eq!(n1, a.len());

        let (f2, n2) = decode(&stream[n1..]).unwrap().unwrap();
        assert_eq!(f2.kind, FrameType::Pong);
        assert_eq!(f2.payload, b"two-two");
        assert_eq!(n1 + n2, stream.len());
    }

    #[test]
    fn bad_magic_rejected() {
        let mut buf = encode(FrameType::Ping, b"");
        buf[0] = b'X';
        assert_eq!(decode(&buf), Err(DecodeError::BadMagic));
    }

    #[test]
    fn bad_version_rejected() {
        let mut buf = encode(FrameType::Ping, b"");
        buf[4] = 99;
        assert_eq!(decode(&buf), Err(DecodeError::BadVersion(99)));
    }

    #[test]
    fn unknown_type_rejected() {
        let mut buf = encode(FrameType::Ping, b"");
        buf[5] = 0xEE;
        assert_eq!(decode(&buf), Err(DecodeError::UnknownType(0xEE)));
    }

    #[test]
    fn oversized_length_rejected() {
        let mut buf = encode(FrameType::FileChunk, &[0u8; 16]);
        // 篡改长度字段为超限值
        let huge = (MAX_PAYLOAD as u32 + 1).to_le_bytes();
        buf[6..10].copy_from_slice(&huge);
        assert_eq!(
            decode(&buf),
            Err(DecodeError::LengthTooLarge(MAX_PAYLOAD + 1))
        );
    }

    #[test]
    fn chunk_payload_roundtrip() {
        let data = vec![7u8; 1024];
        let payload = encode_chunk(65_536, &data);
        let (offset, got) = decode_chunk(&payload).unwrap();
        assert_eq!(offset, 65_536);
        assert_eq!(got, &data[..]);
        assert!(decode_chunk(&[0u8; 4]).is_none());
    }

    #[test]
    fn hello_payload_roundtrip() {
        let hello = HelloPayload {
            device_id: "dev-a".into(),
            name: "DESKTOP-ORION".into(),
            platform: "windows".into(),
            chat_port: 9527,
            proto_version: VERSION,
        };
        let bytes = serde_json::to_vec(&hello).unwrap();
        let buf = encode(FrameType::Hello, &bytes);
        let (frame, _) = decode(&buf).unwrap().unwrap();
        let back: HelloPayload = serde_json::from_slice(&frame.payload).unwrap();
        assert_eq!(back, hello);
    }
}
