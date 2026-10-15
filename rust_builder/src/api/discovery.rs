//! T1.3 frb 桥接：发现服务启停、邻居事件流、手动 IP 直连。
//!
//! Dart 侧使用顺序（重要）：先 discoverySubscribe() 拿到 Stream，再 discoveryStart()。
//! 事件是推送而非轮询（PLAN §3.6-5），UI 不设定时器拉取。

use std::net::{SocketAddr, ToSocketAddrs};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::Mutex;

use anyhow::{anyhow, bail};
use flutter_rust_bridge::frb;

use crate::backend::discovery::{
    self, DiscoveryConfig, DiscoveryEvent, DiscoveryHandle, DiscoveryStats, Neighbor,
};
use crate::frb_generated::StreamSink;

// ------------------------------------------------------------
// 跨调用状态
// ------------------------------------------------------------

/// 事件总线：服务线程发的邻居事件在这里汇聚，再由订阅线程推给 Dart Stream。
struct EventBus {
    tx: Sender<DiscoveryEvent>,
    /// 尚未被订阅线程取走的接收端（take 后为 None）。
    rx: Option<Receiver<DiscoveryEvent>>,
}

static DISCOVERY: Mutex<Option<DiscoveryHandle>> = Mutex::new(None);
static EVENT_BUS: Mutex<Option<EventBus>> = Mutex::new(None);
/// 最近一次启动参数：重复订阅时用它把服务重启到新的事件总线上。
static LAST_SETTINGS: Mutex<Option<DiscoverySettings>> = Mutex::new(None);

// ------------------------------------------------------------
// 桥接数据类型
// ------------------------------------------------------------

/// 启动参数（Dart → Rust）。
#[derive(Debug, Clone)]
pub struct DiscoverySettings {
    /// 设备唯一 id（首次启动由 Dart 侧持久化；可用 newDeviceId() 生成）。
    pub device_id: String,
    pub name: String,
    /// "windows" | "android"（空串则由 Rust 按运行平台填）
    pub platform: String,
    /// 本机 TCP 聊天端口（随 HELLO 广播出去）
    pub chat_port: u16,
    /// UDP 发现监听端口；0 = 系统分配（同机双实例联调用）
    pub listen_port: u16,
    /// 手动直连兜底目标，形如 "192.168.1.20:45999"（省略端口则用默认端口）
    pub manual_peers: Vec<String>,
    /// 是否过滤虚拟网卡（VMware/WSL 等），只用真实局域网网卡发现
    pub filter_virtual: bool,
}

/// 邻居设备快照（Rust → Dart）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceInfo {
    pub device_id: String,
    pub name: String,
    pub ip: String,
    /// 对端聊天端口
    pub port: u16,
    pub platform: String,
    pub paired: bool,
    pub last_seen_ms: u64,
}

/// 邻居变化类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiscoveryChange {
    Added,
    Updated,
    Removed,
}

/// 推给 Dart 的事件：Removed 时 device 为 None，仅带 device_id。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiscoveryEventDto {
    pub change: DiscoveryChange,
    pub device_id: String,
    pub device: Option<DeviceInfo>,
}

/// 发现服务运行计数（UI 自检：空列表时能说明「发了多少 / 收到多少 / 在哪几块网卡」）。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DiscoveryStatsDto {
    pub hellos_sent: u32,
    pub hellos_received: u32,
    pub datagrams_ignored: u32,
    /// 距服务启动收到最后一次对端 HELLO 的毫秒数（None = 一次都没收到）。
    pub last_hello_rx_ms: Option<u32>,
    /// 成功加入组播组的网卡数。
    pub multicast_interfaces: u32,
    /// 参与发现的本机网卡，形如 "以太网 7=192.168.1.191/24"。
    pub interfaces: Vec<String>,
}

/// 服务状态（UI 显示「组播是否可用 / 发现端口」）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiscoveryStatus {
    pub running: bool,
    pub local_port: u16,
    pub multicast_joined: bool,
    pub peers: Vec<String>,
    pub device_count: i32,
}

// ------------------------------------------------------------
// 内部工具
// ------------------------------------------------------------

fn bus_tx() -> anyhow::Result<Sender<DiscoveryEvent>> {
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

/// 取接收端；若已被取走（重复订阅）则换一条新总线并返回新接收端。
fn take_bus_rx() -> anyhow::Result<Receiver<DiscoveryEvent>> {
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

fn parse_peer(text: &str) -> anyhow::Result<SocketAddr> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        bail!("地址不能为空");
    }
    let with_port = if trimmed.contains(':') {
        trimmed.to_string()
    } else {
        format!("{trimmed}:{}", discovery::DEFAULT_DISCOVERY_PORT)
    };
    with_port
        .to_socket_addrs()?
        .next()
        .ok_or_else(|| anyhow!("无法解析地址: {with_port}"))
}

fn parse_peers(list: &[String]) -> anyhow::Result<Vec<SocketAddr>> {
    let mut out = Vec::with_capacity(list.len());
    for item in list {
        let addr = parse_peer(item)?;
        if !out.contains(&addr) {
            out.push(addr);
        }
    }
    Ok(out)
}

fn neighbor_to_dto(n: &Neighbor) -> DeviceInfo {
    DeviceInfo {
        device_id: n.device_id.clone(),
        name: n.name.clone(),
        ip: n.ip.clone(),
        port: n.port,
        platform: n.platform.clone(),
        paired: n.paired,
        last_seen_ms: n.last_seen_ms,
    }
}

fn event_to_dto(event: DiscoveryEvent) -> DiscoveryEventDto {
    match event {
        DiscoveryEvent::Added(n) => DiscoveryEventDto {
            change: DiscoveryChange::Added,
            device_id: n.device_id.clone(),
            device: Some(neighbor_to_dto(&n)),
        },
        DiscoveryEvent::Updated(n) => DiscoveryEventDto {
            change: DiscoveryChange::Updated,
            device_id: n.device_id.clone(),
            device: Some(neighbor_to_dto(&n)),
        },
        DiscoveryEvent::Removed { device_id } => DiscoveryEventDto {
            change: DiscoveryChange::Removed,
            device_id,
            device: None,
        },
    }
}

// ------------------------------------------------------------
// 桥接 API
// ------------------------------------------------------------

/// 本机平台名（"windows" / "android"）。
#[frb(sync)]
pub fn discovery_platform() -> String {
    DiscoveryConfig::current_platform()
}

/// 设备名建议值（Windows 取 COMPUTERNAME，其它平台取 hostname 或 "雨传"）。
#[frb(sync)]
pub fn device_name_hint() -> String {
    std::env::var("COMPUTERNAME")
        .or_else(|_| std::env::var("HOSTNAME"))
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| "雨传设备".to_string())
}

/// 当前发现服务的本机 device_id（传输/消息落库打发送方用；发现未启动时返回空串）。
#[frb(sync)]
pub fn local_device_id() -> String {
    LAST_SETTINGS
        .lock()
        .ok()
        .and_then(|g| g.as_ref().map(|s| s.device_id.clone()))
        .unwrap_or_default()
}

/// 生成设备唯一 id（uuid v4）。
#[frb(sync)]
pub fn new_device_id() -> String {
    uuid::Uuid::new_v4().to_string()
}

/// 订阅邻居事件流（Dart 侧是 Stream&lt;DiscoveryEventDto&gt;）。**须在 discoveryStart 之前调用。**
pub fn discovery_subscribe(sink: StreamSink<DiscoveryEventDto>) -> anyhow::Result<()> {
    let was_running = discovery_is_running();
    let rx = take_bus_rx()?;

    std::thread::Builder::new()
        .name("lanchat-discovery-bridge".into())
        .spawn(move || {
            while let Ok(event) = rx.recv() {
                // Dart 侧取消监听后 add 会失败，此时退出线程即可
                if sink.add(event_to_dto(event)).is_err() {
                    break;
                }
            }
        })?;

    // 重复订阅时，运行中的服务还在往旧总线上发，重启一次换到新总线
    if was_running {
        let settings = LAST_SETTINGS
            .lock()
            .map_err(|_| anyhow!("settings poisoned"))?
            .clone();
        if let Some(settings) = settings {
            discovery_start(settings)?;
        }
    }
    Ok(())
}

/// 启动发现服务（幂等：重复调用会停掉旧实例再去启动）。
pub fn discovery_start(settings: DiscoverySettings) -> anyhow::Result<DiscoveryStatus> {
    let platform = if settings.platform.trim().is_empty() {
        DiscoveryConfig::current_platform()
    } else {
        settings.platform.clone()
    };
    if settings.device_id.trim().is_empty() {
        bail!("device_id 不能为空");
    }

    let cfg = DiscoveryConfig::new(
        settings.device_id.clone(),
        settings.name.clone(),
        platform,
        settings.chat_port,
    )
    .with_listen_port(settings.listen_port)
    .with_filter_virtual(settings.filter_virtual)
    .with_peers(parse_peers(&settings.manual_peers)?);

    let handle = discovery::spawn(cfg, Some(bus_tx()?))?;
    let status = status_from(&handle, true);

    let mut slot = DISCOVERY.lock().map_err(|_| anyhow!("discovery poisoned"))?;
    if let Some(mut old) = slot.take() {
        old.stop();
    }
    *slot = Some(handle);
    drop(slot);

    *LAST_SETTINGS.lock().map_err(|_| anyhow!("settings poisoned"))? = Some(settings);
    Ok(status)
}

/// 停止发现服务，返回此前是否在运行。
pub fn discovery_stop() -> bool {
    let mut slot = match DISCOVERY.lock() {
        Ok(slot) => slot,
        Err(_) => return false,
    };
    match slot.take() {
        Some(mut handle) => {
            handle.stop();
            true
        }
        None => false,
    }
}

/// 当前在线邻居快照。
#[frb(sync)]
pub fn discovery_devices() -> Vec<DeviceInfo> {
    DISCOVERY
        .lock()
        .ok()
        .and_then(|slot| slot.as_ref().map(|h| h.devices()))
        .unwrap_or_default()
        .iter()
        .map(neighbor_to_dto)
        .collect()
}

#[frb(sync)]
pub fn discovery_is_running() -> bool {
    DISCOVERY
        .lock()
        .ok()
        .and_then(|slot| slot.as_ref().map(|h| h.is_running()))
        .unwrap_or(false)
}

/// 服务状态（含组播是否加入成功、实际监听端口）。
#[frb(sync)]
pub fn discovery_status() -> DiscoveryStatus {
    match DISCOVERY.lock() {
        Ok(slot) => match slot.as_ref() {
            Some(handle) => status_from(handle, handle.is_running()),
            None => DiscoveryStatus {
                running: false,
                local_port: 0,
                multicast_joined: false,
                peers: Vec::new(),
                device_count: 0,
            },
        },
        Err(_) => DiscoveryStatus {
            running: false,
            local_port: 0,
            multicast_joined: false,
            peers: Vec::new(),
            device_count: 0,
        },
    }
}

/// 运行计数 + 参与发现的网卡（设备页自检文案用）。
#[frb(sync)]
pub fn discovery_stats() -> DiscoveryStatsDto {
    with_handle(DiscoveryStatsDto::default(), |handle| {
        let stats: DiscoveryStats = handle.stats();
        DiscoveryStatsDto {
            hellos_sent: stats.hellos_sent.min(u32::MAX as u64) as u32,
            hellos_received: stats.hellos_received.min(u32::MAX as u64) as u32,
            datagrams_ignored: stats.datagrams_ignored.min(u32::MAX as u64) as u32,
            last_hello_rx_ms: stats.last_hello_rx_ms.map(|v| v.min(u32::MAX as u64) as u32),
            multicast_interfaces: stats.multicast_interfaces,
            interfaces: handle.interfaces().iter().map(|i| i.label()).collect(),
        }
    })
}

/// 参与发现的本机网卡（形如 "以太网 7=192.168.1.191/24"）。
#[frb(sync)]
pub fn discovery_interfaces() -> Vec<String> {
    with_handle(Vec::new(), |handle| {
        handle.interfaces().iter().map(|i| i.label()).collect()
    })
}

/// 手动直连兜底（T1.2）：加入一个 IP:端口 目标并立刻发一份 HELLO。
pub fn discovery_add_peer(host_port: String) -> anyhow::Result<String> {
    let addr = parse_peer(&host_port)?;
    let slot = DISCOVERY.lock().map_err(|_| anyhow!("discovery poisoned"))?;
    let handle = slot
        .as_ref()
        .ok_or_else(|| anyhow!("发现服务未启动，请先 discoveryStart()"))?;
    handle.add_peer(addr)?;
    Ok(addr.to_string())
}

/// 立刻重发一轮 HELLO（UI「重新发现」）。
pub fn discovery_announce() -> anyhow::Result<()> {
    let slot = DISCOVERY.lock().map_err(|_| anyhow!("discovery poisoned"))?;
    let handle = slot
        .as_ref()
        .ok_or_else(|| anyhow!("发现服务未启动，请先 discoveryStart()"))?;
    handle.announce_now()?;
    Ok(())
}

/// 在持有服务句柄时取值；服务未启动/锁中毒时返回默认值。
fn with_handle<T>(default: T, f: impl FnOnce(&DiscoveryHandle) -> T) -> T {
    match DISCOVERY.lock() {
        Ok(slot) => slot.as_ref().map(f).unwrap_or(default),
        Err(_) => default,
    }
}

fn status_from(handle: &DiscoveryHandle, running: bool) -> DiscoveryStatus {
    DiscoveryStatus {
        running,
        local_port: handle.local_port(),
        multicast_joined: handle.multicast_joined(),
        peers: handle.peers().iter().map(|p| p.to_string()).collect(),
        device_count: handle.len() as i32,
    }
}

// ------------------------------------------------------------
// Tests（桥接层的纯逻辑；真实 socket 行为由 backend::discovery 的测试覆盖）
// ------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::discovery::Neighbor;

    fn neighbor(id: &str, name: &str, ip: &str) -> Neighbor {
        Neighbor {
            device_id: id.into(),
            name: name.into(),
            ip: ip.into(),
            port: 9527,
            platform: "android".into(),
            paired: false,
            last_seen_ms: 1234,
            addr_history: vec!["192.168.1.7".into()],
        }
    }

    #[test]
    fn parse_peer_defaults_to_discovery_port() {
        let addr = parse_peer("192.168.1.20").unwrap();
        assert_eq!(addr.port(), discovery::DEFAULT_DISCOVERY_PORT);
        assert_eq!(addr.ip().to_string(), "192.168.1.20");

        let explicit = parse_peer(" 10.0.0.7:5000 ").unwrap();
        assert_eq!(explicit.port(), 5000);

        let local = parse_peer("127.0.0.1:45999").unwrap();
        assert!(local.ip().is_loopback());

        assert!(parse_peer("   ").is_err());
        assert!(parse_peer("no-such-host.invalid:1234").is_err());
    }

    #[test]
    fn parse_peers_dedupes_and_keeps_order() {
        let peers = parse_peers(&[
            "192.168.1.20:1000".into(),
            "192.168.1.20:1000".into(),
            "192.168.1.21".into(),
        ])
        .unwrap();
        assert_eq!(peers.len(), 2);
        assert_eq!(peers[0].port(), 1000);
        assert_eq!(peers[1].port(), discovery::DEFAULT_DISCOVERY_PORT);
    }

    #[test]
    fn dto_mapping_covers_all_three_changes() {
        let added = event_to_dto(DiscoveryEvent::Added(neighbor("dev-b", "手机", "192.168.1.7")));
        assert_eq!(added.change, DiscoveryChange::Added);
        assert_eq!(added.device_id, "dev-b");
        let device = added.device.expect("Added 必须带设备详情");
        assert_eq!(device.name, "手机");
        assert_eq!(device.ip, "192.168.1.7");
        assert_eq!(device.port, 9527);
        assert_eq!(device.platform, "android");
        assert!(!device.paired);
        assert_eq!(device.last_seen_ms, 1234);

        let updated = event_to_dto(DiscoveryEvent::Updated(neighbor("dev-b", "手机", "10.0.0.8")));
        assert_eq!(updated.change, DiscoveryChange::Updated);
        assert_eq!(updated.device.unwrap().ip, "10.0.0.8");

        let removed = event_to_dto(DiscoveryEvent::Removed {
            device_id: "dev-b".into(),
        });
        assert_eq!(removed.change, DiscoveryChange::Removed);
        assert_eq!(removed.device_id, "dev-b");
        assert!(removed.device.is_none(), "Removed 不带设备详情");
    }

    #[test]
    fn device_name_hint_and_new_id_are_non_empty() {
        assert!(!device_name_hint().trim().is_empty());
        let a = new_device_id();
        let b = new_device_id();
        assert_eq!(a.len(), 36);
        assert_ne!(a, b);
        assert!(a.contains('-'));
    }

    #[test]
    fn status_is_stopped_before_start() {
        // 不启动服务时，状态查询必须是安全的空状态
        let status = discovery_status();
        if !discovery_is_running() {
            assert!(!status.running);
            assert_eq!(status.local_port, 0);
            assert_eq!(status.device_count, 0);
        }
    }
}
