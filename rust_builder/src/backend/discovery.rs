//! UDP 发现与邻居表（TASKS T1.1；风险2 AP 隔离由手动直连兜底、风险3 组播锁在
//! Android 侧持有，见 T1.2）。
//!
//! 设计要点
//! - 双发兜底：每 hello_interval 向组播组与受限广播各发一份 HELLO（PLAN 风险3），
//!   并按需对 peers 单播补发（手动直连 / 本机多实例联调，T1.2）。
//! - 纯逻辑可测：absorb_datagram 不碰 socket，只做「解析 → 过滤 → 更新邻居表」
//!   并返回 Absorbed；线程循环只负责 IO 与事件推送。
//! - 推送而非轮询：邻居增/改/删通过 mpsc::Sender<DiscoveryEvent> 交给上层
//!   （T1.3 桥接成 frb Stream），UI 不需要定时拉取。
//! - 在线判定：3s 心跳 / 10s 超时（DEFAULT_*）；对端 DHCP 换 IP 时 ip 自动更新（风险17）。

use std::collections::HashMap;
use std::io;
use std::net::{Ipv4Addr, SocketAddr, UdpSocket};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use if_addrs::get_if_addrs;
use socket2::{Domain, Protocol, Socket, Type};

use super::protocol::{self, FrameType, HelloPayload, VERSION};

/// 默认 UDP 发现端口（HELLO 的收发端口）。
pub const DEFAULT_DISCOVERY_PORT: u16 = 45_999;
/// 默认组播组地址（本地管理范围 239.255.x.x）。
pub const DEFAULT_MULTICAST_ADDR: Ipv4Addr = Ipv4Addr::new(239, 255, 42, 99);
/// 心跳间隔默认值（PLAN：3s 一次 HELLO）。
pub const DEFAULT_HELLO_INTERVAL_MS: u64 = 3_000;
/// 邻居在线超时默认值（PLAN：3s 心跳，10s 离线）。
pub const DEFAULT_TIMEOUT_MS: u64 = 10_000;
/// 单次 recv_from 阻塞上限，决定 stop 的响应粒度。
const RECV_TIMEOUT: Duration = Duration::from_millis(200);
/// 超时摘除扫描间隔。
const PRUNE_INTERVAL: Duration = Duration::from_millis(500);
/// HELLO 报文大小上限：远小于 1500B，避免 IP 分片丢包。
pub const MAX_HELLO_SIZE: usize = 1200;

// ------------------------------------------------------------
// 邻居表
// ------------------------------------------------------------

/// 一台被发现的局域网设备。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Neighbor {
    pub device_id: String,
    pub name: String,
    /// 由数据报来源地址得到（不信任 payload 里的自述，防伪造）。
    pub ip: String,
    /// 对端 TCP 聊天端口（来自 HELLO 的 chat_port）。
    pub port: u16,
    /// "windows" | "android"
    pub platform: String,
    pub paired: bool,
    /// 最近一次收到心跳的单调时钟毫秒值。
    pub last_seen_ms: u64,
    /// 近期收到过 HELLO 的来源地址（最新在前，最多 [`MAX_ADDR_HISTORY`] 个）。
    /// 多网卡主机上同一设备会从不同网段发来报文（T1.6），这里留历史做优选。
    pub addr_history: Vec<String>,
}

/// upsert 的结果，用于决定要推送哪种事件。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Touch {
    /// 新设备入表 → Added。
    Inserted,
    /// 设备名/地址/平台等发生变化 → Updated。
    Updated,
    /// 只有心跳时间前进 → 不推送事件（避免 3s 一次的 UI 抖动）。
    Unchanged,
}

/// 邻居表：touch 记录心跳，prune 摘除超时设备（返回被摘除的 id）。
#[derive(Debug, Default)]
pub struct NeighborTable {
    map: HashMap<String, Neighbor>,
    timeout_ms: u64,
}

impl NeighborTable {
    pub fn new(timeout_ms: u64) -> Self {
        Self {
            map: HashMap::new(),
            timeout_ms,
        }
    }

    /// 记录/更新一次心跳（等价于忽略返回值的 upsert）。
    pub fn touch(&mut self, neighbor: Neighbor) {
        let _ = self.upsert(neighbor);
    }

    /// 插入或更新邻居，并报告本次变化类型。
    ///
    /// 已有设备的地址字段被覆盖（DHCP/漫游换 IP 自动跟随，风险17），
    /// last_seen_ms 每次都会刷新。
    pub fn upsert(&mut self, neighbor: Neighbor) -> Touch {
        match self.map.get(&neighbor.device_id) {
            None => {
                self.map.insert(neighbor.device_id.clone(), neighbor);
                Touch::Inserted
            }
            Some(old) => {
                let changed = old.ip != neighbor.ip
                    || old.port != neighbor.port
                    || old.name != neighbor.name
                    || old.platform != neighbor.platform
                    || old.paired != neighbor.paired;
                self.map.insert(neighbor.device_id.clone(), neighbor);
                if changed {
                    Touch::Updated
                } else {
                    Touch::Unchanged
                }
            }
        }
    }

    /// 摘除超过 timeout_ms 未见心跳的设备，返回其 id 列表（UI 据此移除行）。
    pub fn prune(&mut self, now_ms: u64) -> Vec<String> {
        let timeout = self.timeout_ms;
        let removed: Vec<String> = self
            .map
            .iter()
            .filter(|(_, n)| now_ms.saturating_sub(n.last_seen_ms) > timeout)
            .map(|(id, _)| id.clone())
            .collect();
        for id in &removed {
            self.map.remove(id);
        }
        removed
    }

    pub fn get(&self, device_id: &str) -> Option<&Neighbor> {
        self.map.get(device_id)
    }

    pub fn list(&self) -> Vec<&Neighbor> {
        let mut v: Vec<&Neighbor> = self.map.values().collect();
        v.sort_by(|a, b| a.device_id.cmp(&b.device_id));
        v
    }

    pub fn len(&self) -> usize {
        self.map.len()
    }

    pub fn is_empty(&self) -> bool {
        self.map.is_empty()
    }
}

// ------------------------------------------------------------
// 本机网卡与地址优选（T1.6：出接口不能交给系统选）
// ------------------------------------------------------------

/// 邻居地址历史保留条数。
pub const MAX_ADDR_HISTORY: usize = 4;

/// 本机一个可用于局域网发现的 IPv4 接口。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalInterface {
    pub name: String,
    pub addr: Ipv4Addr,
    pub netmask: Ipv4Addr,
}

impl LocalInterface {
    /// 该接口的子网定向广播地址（192.168.1.191/24 → 192.168.1.255）。
    pub fn broadcast(&self) -> Ipv4Addr {
        subnet_broadcast(self.addr, self.netmask)
    }

    /// 目标地址是否与本接口同子网（同子网 = 不经路由即可直达）。
    pub fn contains(&self, ip: Ipv4Addr) -> bool {
        same_subnet(self.addr, ip, self.netmask)
    }

    pub fn label(&self) -> String {
        format!("{}={}/{}", self.name, self.addr, prefix_len(self.netmask))
    }
}

/// 子网广播地址：网络号 | ~掩码。
pub fn subnet_broadcast(addr: Ipv4Addr, netmask: Ipv4Addr) -> Ipv4Addr {
    Ipv4Addr::from(u32::from(addr) | !u32::from(netmask))
}

/// 两个地址是否在同一子网。
pub fn same_subnet(a: Ipv4Addr, b: Ipv4Addr, netmask: Ipv4Addr) -> bool {
    (u32::from(a) & u32::from(netmask)) == (u32::from(b) & u32::from(netmask))
}

/// 掩码前缀长度（255.255.255.0 → 24）。
pub fn prefix_len(netmask: Ipv4Addr) -> u32 {
    u32::from(netmask).count_ones()
}

/// 枚举本机可用于发现的 IPv4 接口（跳过 loopback / 未分配 / 链路本地）。
///
/// **为什么必须枚举**：只 bind 0.0.0.0 让系统选出口时，多网卡主机（物理网卡 +
/// VMware / WSL 虚拟网卡）上组播会被选到虚拟网卡，真实局域网里的对端永远收不到
/// HELLO —— 本机实测对端来源 IP 是 192.168.238.1（VMnet1）而不是 192.168.1.x。
pub fn local_interfaces() -> Vec<LocalInterface> {
    local_interfaces_impl(false)
}

/// 枚举本机 IPv4 接口，可选过滤虚拟网卡（设置项「自动过滤虚拟网卡」）。
#[allow(dead_code)]
pub fn local_interfaces_filtered(filter_virtual: bool) -> Vec<LocalInterface> {
    local_interfaces_impl(filter_virtual)
}

fn local_interfaces_impl(filter_virtual: bool) -> Vec<LocalInterface> {
    let mut out: Vec<LocalInterface> = Vec::new();
    for iface in get_if_addrs().unwrap_or_default() {
        // 只看 IPv4；IPv6 / loopback / 链路本地（169.254.x）不参与发现
        let if_addrs::IfAddr::V4(v4) = &iface.addr else {
            continue;
        };
        let (ip, netmask) = (v4.ip, v4.netmask);
        if ip.is_unspecified() || ip.is_loopback() || ip.is_link_local() {
            continue;
        }
        // 设置项：过滤虚拟网卡（VMware/WSL/VirtualBox 等），只留真实局域网
        if filter_virtual && is_virtual_adapter_name(&iface.name) {
            continue;
        }
        let entry = LocalInterface {
            name: iface.name.clone(),
            addr: ip,
            netmask,
        };
        if !out.contains(&entry) {
            out.push(entry);
        }
    }
    // 按地址排序：低地址（真实局域网 192.168.1.x）排在虚拟网卡前面 —— UI 里本机
    // 地址第一行就是可达的那个，手动直连抄地址不容易抄错
    out.sort_by(|a, b| a.addr.cmp(&b.addr).then(a.name.cmp(&b.name)));
    out
}

/// 按网卡名判断是否虚拟适配器（Windows/Linux 常见命名）。
///
/// 命中即视为虚拟网卡，设置项开启后不参与发现，避免多网卡主机把 HELLO
/// 发到虚拟网卡而真实局域网对端收不到（T1.6 的根因之一）。
pub fn is_virtual_adapter_name(name: &str) -> bool {
    let n = name.to_ascii_lowercase();
    const PATTERNS: &[&str] = &[
        "vmware",
        "vmnet",
        "vbox",
        "virtualbox",
        "wsl",
        "vethernet",
        "hyper-v",
        "hyperv",
        "virtual",
        "qemu",
        "xen",
        "docker",
        "bridge",
        "loopback",
        "vpn",
        "tap",
        "tun",
        "wintun",
        "wireguard",
        "tailscale",
        "zerotier",
        "bluetooth",
        "isatap",
        "teredo",
    ];
    PATTERNS.iter().any(|p| n.contains(p))
}

/// 地址优选策略：多网卡主机会从多个来源地址收到同一设备的 HELLO，
/// 这里选出与本机同子网的「可达」地址，并保持既有优选不变以避免 UI 抖动（T1.6）。
#[derive(Debug, Clone, Default)]
pub struct AddrPolicy {
    pub interfaces: Vec<LocalInterface>,
}

impl AddrPolicy {
    pub fn new(interfaces: Vec<LocalInterface>) -> Self {
        Self { interfaces }
    }

    /// 空策略（单测里不关心可达性时使用）。
    pub fn any() -> Self {
        Self::default()
    }

    /// 该地址是否与本机某个网卡同子网（= 可直接投递）。
    pub fn reachable(&self, ip: &str) -> bool {
        match ip.parse::<Ipv4Addr>() {
            Ok(v) => self.interfaces.iter().any(|i| i.contains(v)),
            Err(_) => false,
        }
    }

    /// 在「当前地址 / 历史地址 / 新到地址」中挑一个优选地址。
    ///
    /// 规则（由强到弱）：当前地址仍可达 → 保持；新地址可达 → 换新；
    /// 有当前地址 → 保持；历史里第一个可达 → 用它；都不行 → 用新地址。
    pub fn prefer(&self, current: Option<&str>, history: &[String], incoming: &str) -> String {
        // 拿不到本机网卡信息时无从判断可达性 → 直接跟随新地址（DHCP 换 IP 场景，风险17）
        if self.interfaces.is_empty() {
            return incoming.to_string();
        }
        if let Some(cur) = current {
            if self.reachable(cur) {
                return cur.to_string();
            }
        }
        if self.reachable(incoming) {
            return incoming.to_string();
        }
        if let Some(cur) = current {
            return cur.to_string();
        }
        history
            .iter()
            .find(|ip| self.reachable(ip))
            .cloned()
            .unwrap_or_else(|| incoming.to_string())
    }
}

/// 地址历史：新地址置顶、去重、截断。
fn push_addr_history(history: &mut Vec<String>, ip: &str) {
    history.retain(|h| h != ip);
    history.insert(0, ip.to_string());
    history.truncate(MAX_ADDR_HISTORY);
}

/// 发现服务运行计数：收不到 HELLO 时 UI 能自己说明原因（发送次数 / 收到次数 / 网卡）。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DiscoveryStats {
    pub hellos_sent: u64,
    pub hellos_received: u64,
    pub datagrams_ignored: u64,
    pub last_hello_rx_ms: Option<u64>,
    /// 成功加入组播组的网卡数。
    pub multicast_interfaces: u32,
}

// ------------------------------------------------------------
// 事件
// ------------------------------------------------------------

/// 推送给上层（T1.3 → frb Stream）的邻居变化。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DiscoveryEvent {
    Added(Neighbor),
    Updated(Neighbor),
    Removed { device_id: String },
}

/// 忽略一条数据报的原因（用于日志/测试断言）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IgnoreReason {
    /// 不是合法 HELLO 帧（坏 magic / JSON 非法 / 非 HELLO 类型 / 缺字段）。
    Malformed,
    /// 自己发出的 HELLO 从组播/广播回环收到。
    SelfHello,
    /// 协议版本不一致（风险10：不兼容时不入表，后续可提示升级）。
    VersionMismatch,
}

/// absorb_datagram 的结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Absorbed {
    Added(Neighbor),
    Updated(Neighbor),
    /// 心跳只刷新了时间（无需推事件）。
    Unchanged(Neighbor),
    Ignored(IgnoreReason),
}

impl Absorbed {
    /// 需要推送给上层的事件（心跳刷新/被忽略时为 None）。
    pub fn event(&self) -> Option<DiscoveryEvent> {
        match self {
            Self::Added(n) => Some(DiscoveryEvent::Added(n.clone())),
            Self::Updated(n) => Some(DiscoveryEvent::Updated(n.clone())),
            Self::Unchanged(_) | Self::Ignored(_) => None,
        }
    }
}

// ------------------------------------------------------------
// 纯逻辑：HELLO 编解码 + 入表
// ------------------------------------------------------------

/// 把本机信息编成 HELLO 帧（LCHT 帧头 + JSON payload）。
pub fn encode_hello(payload: &HelloPayload) -> Vec<u8> {
    let json = serde_json::to_vec(payload).expect("HelloPayload 序列化不会失败");
    protocol::encode(FrameType::Hello, &json)
}

/// 解析 HELLO / HELLO_ACK 数据报；非 HELLO 或数据损坏返回 None。
pub fn parse_hello(buf: &[u8]) -> Option<HelloPayload> {
    match protocol::decode(buf) {
        Ok(Some((frame, _))) if matches!(frame.kind, FrameType::Hello | FrameType::HelloAck) => {
            let hello: HelloPayload = serde_json::from_slice(&frame.payload).ok()?;
            (!hello.device_id.is_empty()).then_some(hello)
        }
        _ => None,
    }
}

/// 由 HELLO payload + 数据报来源地址构造邻居条目。
///
/// ip 取来源地址而非 payload 自述（防伪造）；port 取 payload 的 chat_port。
pub fn neighbor_from_hello(hello: &HelloPayload, from: SocketAddr, now_ms: u64) -> Neighbor {
    Neighbor {
        device_id: hello.device_id.clone(),
        name: hello.name.clone(),
        ip: from.ip().to_string(),
        port: hello.chat_port,
        platform: hello.platform.clone(),
        paired: false,
        last_seen_ms: now_ms,
        addr_history: vec![from.ip().to_string()],
    }
}

/// 处理一个收到的数据报：解析 HELLO → 过滤自身/版本不符 → 更新邻居表。
///
/// now_ms 由调用方提供单调时钟毫秒值，便于单测注入固定时间。
pub fn absorb_datagram(
    table: &mut NeighborTable,
    self_id: &str,
    now_ms: u64,
    from: SocketAddr,
    buf: &[u8],
    policy: &AddrPolicy,
) -> Absorbed {
    let Some(hello) = parse_hello(buf) else {
        return Absorbed::Ignored(IgnoreReason::Malformed);
    };
    if hello.device_id == self_id {
        return Absorbed::Ignored(IgnoreReason::SelfHello);
    }
    if hello.proto_version != VERSION {
        return Absorbed::Ignored(IgnoreReason::VersionMismatch);
    }
    let mut neighbor = neighbor_from_hello(&hello, from, now_ms);
    if let Some(existing) = table.get(&hello.device_id) {
        // 多网卡主机：同一设备可能从多个网段发来 HELLO，选可达地址并保持稳定（T1.6）
        let preferred = policy.prefer(Some(&existing.ip), &existing.addr_history, &neighbor.ip);
        let mut history = existing.addr_history.clone();
        push_addr_history(&mut history, &neighbor.ip);
        history.retain(|h| h != &preferred);
        history.insert(0, preferred.clone());
        history.truncate(MAX_ADDR_HISTORY);
        neighbor.ip = preferred;
        neighbor.addr_history = history;
    }
    match table.upsert(neighbor.clone()) {
        Touch::Inserted => Absorbed::Added(neighbor),
        Touch::Updated => Absorbed::Updated(neighbor),
        Touch::Unchanged => Absorbed::Unchanged(neighbor),
    }
}

// ------------------------------------------------------------
// 配置
// ------------------------------------------------------------

/// 发现服务配置。
#[derive(Debug, Clone)]
pub struct DiscoveryConfig {
    pub device_id: String,
    pub name: String,
    /// "windows" | "android"
    pub platform: String,
    /// 本机 TCP 聊天端口（随 HELLO 广播出去，供对端连接）。
    pub chat_port: u16,
    /// UDP 发现监听端口；0 = 由系统分配（本机多实例联调/测试用）。
    pub listen_port: u16,
    pub multicast_addr: Ipv4Addr,
    /// 组播加入所使用的网卡地址，0.0.0.0 = 由系统选择。
    pub multicast_interface: Ipv4Addr,
    /// HELLO 发送间隔。
    pub hello_interval: Duration,
    /// 邻居离线判定超时。
    pub timeout: Duration,
    /// 额外的单播目标（手动直连兜底 / 本机多实例联调）。
    pub peers: Vec<SocketAddr>,
    /// 是否过滤虚拟网卡（VMware/WSL/虚拟机等），只用真实局域网网卡发现。
    pub filter_virtual: bool,
}

impl DiscoveryConfig {
    pub fn new(
        device_id: impl Into<String>,
        name: impl Into<String>,
        platform: impl Into<String>,
        chat_port: u16,
    ) -> Self {
        Self {
            device_id: device_id.into(),
            name: name.into(),
            platform: platform.into(),
            chat_port,
            listen_port: DEFAULT_DISCOVERY_PORT,
            multicast_addr: DEFAULT_MULTICAST_ADDR,
            multicast_interface: Ipv4Addr::UNSPECIFIED,
            hello_interval: Duration::from_millis(DEFAULT_HELLO_INTERVAL_MS),
            timeout: Duration::from_millis(DEFAULT_TIMEOUT_MS),
            peers: Vec::new(),
            filter_virtual: false,
        }
    }

    pub fn with_listen_port(mut self, port: u16) -> Self {
        self.listen_port = port;
        self
    }

    pub fn with_filter_virtual(mut self, filter: bool) -> Self {
        self.filter_virtual = filter;
        self
    }

    pub fn with_peers(mut self, peers: Vec<SocketAddr>) -> Self {
        self.peers = peers;
        self
    }

    pub fn with_timing(mut self, hello_interval: Duration, timeout: Duration) -> Self {
        self.hello_interval = hello_interval;
        self.timeout = timeout;
        self
    }

    /// 本机当前平台名（windows / android / 其它系统名）。
    pub fn current_platform() -> String {
        if cfg!(target_os = "android") {
            "android"
        } else if cfg!(target_os = "windows") {
            "windows"
        } else {
            std::env::consts::OS
        }
        .to_string()
    }

    /// 本机 HELLO payload。
    pub fn hello_payload(&self) -> HelloPayload {
        HelloPayload {
            device_id: self.device_id.clone(),
            name: self.name.clone(),
            platform: self.platform.clone(),
            chat_port: self.chat_port,
            proto_version: VERSION,
        }
    }
}

// ------------------------------------------------------------
// 服务（真实 socket + 后台线程）
// ------------------------------------------------------------

/// 运行中的发现服务句柄。drop 即停止。
pub struct DiscoveryHandle {
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
    table: Arc<Mutex<NeighborTable>>,
    socket: Arc<UdpSocket>,
    peers: Arc<Mutex<Vec<SocketAddr>>>,
    hello: Vec<u8>,
    local_port: u16,
    multicast_joined: bool,
    interfaces: Vec<LocalInterface>,
    stats: Arc<Mutex<DiscoveryStats>>,
}

impl DiscoveryHandle {
    /// 当前在线邻居快照（按 device_id 排序）。
    pub fn devices(&self) -> Vec<Neighbor> {
        self.table
            .lock()
            .expect("neighbor table poisoned")
            .list()
            .into_iter()
            .cloned()
            .collect()
    }

    pub fn device(&self, device_id: &str) -> Option<Neighbor> {
        self.table
            .lock()
            .expect("neighbor table poisoned")
            .get(device_id)
            .cloned()
    }

    pub fn len(&self) -> usize {
        self.table.lock().expect("neighbor table poisoned").len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// 实际监听的 UDP 端口（listen_port = 0 时由系统分配）。
    pub fn local_port(&self) -> u16 {
        self.local_port
    }

    /// 组播组是否加入成功（失败时仍有广播 + 单播兜底）。
    pub fn multicast_joined(&self) -> bool {
        self.multicast_joined
    }

    /// 本机参与发现的网卡（UI 自检展示：到底在哪几块网卡上收发）。
    pub fn interfaces(&self) -> Vec<LocalInterface> {
        self.interfaces.clone()
    }

    /// 运行计数快照（发送 / 收到 / 忽略 / 最近一次收到 HELLO）。
    pub fn stats(&self) -> DiscoveryStats {
        self.stats
            .lock()
            .map(|s| s.clone())
            .unwrap_or_default()
    }

    pub fn peers(&self) -> Vec<SocketAddr> {
        self.peers.lock().expect("peers poisoned").clone()
    }

    /// 立刻发一轮 HELLO（UI「重新发现」按钮 / 手动直连立即生效）。
    pub fn announce_now(&self) -> io::Result<()> {
        send_hello(&self.socket, &self.hello, self.local_port, &self.peers)
    }

    /// 添加单播目标并立刻对其发一份 HELLO（T1.2 手动 IP 直连兜底）。
    pub fn add_peer(&self, target: SocketAddr) -> io::Result<()> {
        {
            let mut peers = self.peers.lock().expect("peers poisoned");
            if !peers.contains(&target) {
                peers.push(target);
            }
        }
        self.socket.send_to(&self.hello, target).map(|_| ())
    }

    pub fn is_running(&self) -> bool {
        self.thread.as_ref().is_some_and(|t| !t.is_finished())
    }

    /// 停止后台线程（幂等）。
    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(handle) = self.thread.take() {
            let _ = handle.join();
        }
    }
}

impl Drop for DiscoveryHandle {
    fn drop(&mut self) {
        self.stop();
    }
}

/// 启动发现服务；events 为 None 时只维护邻居表，不推事件。
pub fn spawn(
    cfg: DiscoveryConfig,
    events: Option<Sender<DiscoveryEvent>>,
) -> io::Result<DiscoveryHandle> {
    if cfg.device_id.trim().is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "device_id 不能为空",
        ));
    }

    let socket = bind_discovery_socket(cfg.listen_port)?;
    let local_port = socket.local_addr()?.port();

    // 每块网卡都加入组播组：只在 0.0.0.0 上 join 时，多网卡主机的组播可能只落在
    // 虚拟网卡上（本机实测落在 VMware VMnet1），真实局域网里的对端收不到。
    // 设置项「自动过滤虚拟网卡」开启后只用真实局域网网卡。
    let interfaces = if cfg.filter_virtual {
        local_interfaces_filtered(true)
    } else {
        local_interfaces()
    };
    let mut multicast_interfaces = 0u32;
    for iface in &interfaces {
        if socket
            .join_multicast_v4(&cfg.multicast_addr, &iface.addr)
            .is_ok()
        {
            multicast_interfaces += 1;
        }
    }
    let multicast_joined = if multicast_interfaces > 0 {
        true
    } else if socket
        .join_multicast_v4(&cfg.multicast_addr, &cfg.multicast_interface)
        .is_ok()
    {
        // 兜底：拿不到网卡列表时交给系统默认接口
        multicast_interfaces = 1;
        true
    } else {
        false
    };

    let policy = AddrPolicy::new(interfaces.clone());
    let stats = Arc::new(Mutex::new(DiscoveryStats {
        multicast_interfaces,
        ..Default::default()
    }));

    let hello = encode_hello(&cfg.hello_payload());
    debug_assert!(
        hello.len() <= MAX_HELLO_SIZE,
        "HELLO 报文过大，可能被 IP 分片: {}",
        hello.len()
    );

    let table = Arc::new(Mutex::new(NeighborTable::new(
        cfg.timeout.as_millis() as u64,
    )));
    let peers = Arc::new(Mutex::new(cfg.peers.clone()));
    let stop = Arc::new(AtomicBool::new(false));
    let socket = Arc::new(socket);

    let thread = {
        let table = Arc::clone(&table);
        let peers = Arc::clone(&peers);
        let stop = Arc::clone(&stop);
        let socket = Arc::clone(&socket);
        let self_id = cfg.device_id.clone();
        let multicast = cfg.multicast_addr;
        let interval = cfg.hello_interval;
        let hello = hello.clone();
        let interfaces = interfaces.clone();
        let policy = policy.clone();
        let stats = Arc::clone(&stats);
        thread::Builder::new()
            .name("lanchat-discovery".into())
            .spawn(move || {
                run_loop(
                    socket,
                    table,
                    peers,
                    stop,
                    events,
                    self_id,
                    multicast,
                    interval,
                    hello,
                    local_port,
                    interfaces,
                    policy,
                    stats,
                )
            })?
    };

    Ok(DiscoveryHandle {
        stop,
        thread: Some(thread),
        table,
        socket,
        peers,
        hello,
        local_port,
        multicast_joined,
        interfaces,
        stats,
    })
}

/// 绑定发现 socket：允许地址复用（本机多实例联调）、开广播、设读超时。
fn bind_discovery_socket(port: u16) -> io::Result<UdpSocket> {
    let socket = Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP))?;
    socket.set_reuse_address(true)?;
    // Windows 无 SO_REUSEPORT；Unix 上再开一次，方便本机双实例组播互见。
    #[cfg(unix)]
    {
        let _ = socket.set_reuse_port(true);
    }
    socket.set_broadcast(true)?;
    let _ = socket.set_multicast_loop_v4(true);
    let _ = socket.set_multicast_ttl_v4(1);
    let addr = SocketAddr::from((Ipv4Addr::UNSPECIFIED, port));
    socket.bind(&addr.into())?;
    let socket: UdpSocket = socket.into();
    socket.set_read_timeout(Some(RECV_TIMEOUT))?;
    Ok(socket)
}

/// 向组播组、受限广播、以及所有 peers 各发一份 HELLO。
fn send_hello(
    socket: &UdpSocket,
    hello: &[u8],
    port: u16,
    peers: &Arc<Mutex<Vec<SocketAddr>>>,
) -> io::Result<()> {
    // 组播与广播都失败（例如网卡全断）时不算致命：继续跑，等网络恢复。
    let _ = socket.send_to(hello, SocketAddr::from((DEFAULT_MULTICAST_ADDR, port)));
    let _ = socket.send_to(hello, SocketAddr::from((Ipv4Addr::BROADCAST, port)));
    let targets = peers.lock().expect("peers poisoned").clone();
    for target in targets {
        let _ = socket.send_to(hello, target);
    }
    Ok(())
}

/// 发一份并计数（发送失败只记录，不打断心跳循环）。
fn send_counted(socket: &UdpSocket, hello: &[u8], target: SocketAddr, sent: &mut u64) {
    if socket.send_to(hello, target).is_ok() {
        *sent += 1;
    }
}

#[allow(clippy::too_many_arguments)]
fn run_loop(
    socket: Arc<UdpSocket>,
    table: Arc<Mutex<NeighborTable>>,
    peers: Arc<Mutex<Vec<SocketAddr>>>,
    stop: Arc<AtomicBool>,
    events: Option<Sender<DiscoveryEvent>>,
    self_id: String,
    multicast: Ipv4Addr,
    interval: Duration,
    hello: Vec<u8>,
    local_port: u16,
    interfaces: Vec<LocalInterface>,
    policy: AddrPolicy,
    stats: Arc<Mutex<DiscoveryStats>>,
) {
    let start = Instant::now();
    let mut last_hello: Option<Instant> = None;
    let mut next_prune = Instant::now();
    let mut buf = [0u8; 2048];

    while !stop.load(Ordering::SeqCst) {
        // 1) 收：一次读超时（RECV_TIMEOUT）内的数据报
        match socket.recv_from(&mut buf) {
            Ok((n, from)) => {
                let now_ms = start.elapsed().as_millis() as u64;
                let absorbed = {
                    let mut table = table.lock().expect("neighbor table poisoned");
                    absorb_datagram(&mut table, &self_id, now_ms, from, &buf[..n], &policy)
                };
                if let Ok(mut s) = stats.lock() {
                    match &absorbed {
                        // 自身回环 / 版本不符 / 坏包都不算「收到对端心跳」
                        Absorbed::Ignored(_) => s.datagrams_ignored += 1,
                        _ => {
                            s.hellos_received += 1;
                            s.last_hello_rx_ms = Some(now_ms);
                        }
                    }
                }
                if let (Some(tx), Some(event)) = (events.as_ref(), absorbed.event()) {
                    let _ = tx.send(event);
                }
            }
            Err(e)
                if matches!(
                    e.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) => {}
            // Windows：对端端口关闭时 UDP 会回 ICMP，表现为 ConnectionReset，忽略即可
            Err(e) if e.kind() == io::ErrorKind::ConnectionReset => {}
            Err(_) => {}
        }

        // 2) 发：组播 + 受限广播 + 每块网卡的子网定向广播 + 单播 peers
        //    定向广播按路由表走对应网卡，多网卡主机上不会被虚拟网卡吞掉（关键修复）
        if last_hello.is_none_or(|t| t.elapsed() >= interval) {
            let mut sent = 0u64;
            // 组播：系统选接口
            send_counted(&socket, &hello, SocketAddr::from((multicast, local_port)), &mut sent);
            // 受限广播
            send_counted(
                &socket,
                &hello,
                SocketAddr::from((Ipv4Addr::BROADCAST, local_port)),
                &mut sent,
            );
            // 每个网卡的子网定向广播（192.168.1.255 等）
            for iface in &interfaces {
                send_counted(
                    &socket,
                    &hello,
                    SocketAddr::from((iface.broadcast(), local_port)),
                    &mut sent,
                );
            }
            // 手动直连 / 同机多实例
            for target in peers.lock().expect("peers poisoned").iter() {
                send_counted(&socket, &hello, *target, &mut sent);
            }
            last_hello = Some(Instant::now());
            if let Ok(mut s) = stats.lock() {
                s.hellos_sent += sent;
            }
        }

        // 3) 摘：超时邻居 → Removed 事件
        if Instant::now() >= next_prune {
            let now_ms = start.elapsed().as_millis() as u64;
            let removed = table.lock().expect("neighbor table poisoned").prune(now_ms);
            if let Some(tx) = events.as_ref() {
                for device_id in removed {
                    let _ = tx.send(DiscoveryEvent::Removed { device_id });
                }
            }
            next_prune = Instant::now() + PRUNE_INTERVAL;
        }
    }
}

// ------------------------------------------------------------
// Tests
// ------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    fn neighbor(id: &str, seen: u64) -> Neighbor {
        Neighbor {
            device_id: id.into(),
            name: format!("dev-{id}"),
            ip: "192.168.1.50".into(),
            port: 9527,
            platform: "android".into(),
            paired: false,
            last_seen_ms: seen,
            addr_history: vec![],
        }
    }

    fn hello_payload(id: &str) -> HelloPayload {
        HelloPayload {
            device_id: id.into(),
            name: format!("host-{id}"),
            platform: "windows".into(),
            chat_port: 9527,
            proto_version: VERSION,
        }
    }

    fn from() -> SocketAddr {
        SocketAddr::from((Ipv4Addr::new(192, 168, 1, 77), 45_999))
    }

    /// 轮询等待条件成立，最长 deadline（避免测试 sleep 固定时长导致偶发失败）。
    fn wait_until(deadline: Duration, mut cond: impl FnMut() -> bool) -> bool {
        let start = Instant::now();
        while start.elapsed() < deadline {
            if cond() {
                return true;
            }
            thread::sleep(Duration::from_millis(20));
        }
        cond()
    }

    // ---------- 邻居表 ----------

    #[test]
    fn touch_inserts_and_updates_address() {
        let mut t = NeighborTable::new(DEFAULT_TIMEOUT_MS);
        t.touch(neighbor("a", 1000));
        let mut changed = neighbor("a", 2000);
        changed.ip = "192.168.1.77".into();
        t.touch(changed);
        assert_eq!(t.len(), 1);
        assert_eq!(t.get("a").unwrap().ip, "192.168.1.77");
        assert_eq!(t.get("a").unwrap().last_seen_ms, 2000);
    }

    #[test]
    fn upsert_reports_insert_update_and_unchanged() {
        let mut t = NeighborTable::new(DEFAULT_TIMEOUT_MS);
        assert_eq!(t.upsert(neighbor("a", 1_000)), Touch::Inserted);
        // 只刷新心跳时间 → Unchanged（不推事件，避免 3s 一次的 UI 抖动）
        assert_eq!(t.upsert(neighbor("a", 2_000)), Touch::Unchanged);
        // 地址变化 → Updated
        let mut moved = neighbor("a", 3_000);
        moved.ip = "10.0.0.9".into();
        assert_eq!(t.upsert(moved), Touch::Updated);
        assert_eq!(t.get("a").unwrap().ip, "10.0.0.9");
    }

    #[test]
    fn prune_removes_only_stale_neighbors() {
        let mut t = NeighborTable::new(DEFAULT_TIMEOUT_MS);
        t.touch(neighbor("fresh", 9_500));
        t.touch(neighbor("stale", 0));
        // now=10_001: stale 龄 10_001 > 10_000 被摘除；fresh 龄 501 保留
        let removed = t.prune(10_001);
        assert_eq!(removed, vec!["stale".to_string()]);
        assert_eq!(t.len(), 1);
        assert!(t.get("fresh").is_some());
    }

    #[test]
    fn prune_keeps_neighbor_exactly_at_timeout_boundary() {
        let mut t = NeighborTable::new(DEFAULT_TIMEOUT_MS);
        t.touch(neighbor("edge", 0));
        // 恰好等于超时阈值：不算过期（严格大于才摘除）
        assert!(t.prune(DEFAULT_TIMEOUT_MS).is_empty());
        assert_eq!(t.len(), 1);
        assert_eq!(t.prune(DEFAULT_TIMEOUT_MS + 1).len(), 1);
        assert!(t.is_empty());
    }

    #[test]
    fn list_is_sorted_by_id() {
        let mut t = NeighborTable::new(DEFAULT_TIMEOUT_MS);
        t.touch(neighbor("c", 1));
        t.touch(neighbor("a", 1));
        t.touch(neighbor("b", 1));
        let ids: Vec<String> = t.list().iter().map(|n| n.device_id.clone()).collect();
        assert_eq!(ids, vec!["a", "b", "c"]);
    }

    // ---------- HELLO 编解码 ----------

    #[test]
    fn hello_datagram_roundtrip_and_size() {
        let payload = hello_payload("dev-a");
        let bytes = encode_hello(&payload);
        assert!(
            bytes.len() <= MAX_HELLO_SIZE,
            "HELLO 报文体 {}B 过大",
            bytes.len()
        );
        assert_eq!(parse_hello(&bytes).unwrap(), payload);
        // 单帧完整（无粘包残留）
        let (frame, consumed) = protocol::decode(&bytes).unwrap().unwrap();
        assert_eq!(consumed, bytes.len());
        assert_eq!(frame.kind, FrameType::Hello);
    }

    #[test]
    fn parse_hello_rejects_non_hello_and_garbage() {
        assert!(parse_hello(b"").is_none());
        assert!(parse_hello(b"not a frame at all").is_none());
        // 合法帧但不是 HELLO
        let ping = protocol::encode(FrameType::Ping, b"{}");
        assert!(parse_hello(&ping).is_none());
        // 坏 magic
        let mut broken = encode_hello(&hello_payload("dev-a"));
        broken[0] = b'X';
        assert!(parse_hello(&broken).is_none());
        // HELLO 帧但 JSON 非法
        let bad_json = protocol::encode(FrameType::Hello, b"{oops");
        assert!(parse_hello(&bad_json).is_none());
        // device_id 为空视作畸形
        let empty_id = protocol::encode(
            FrameType::Hello,
            &serde_json::to_vec(&HelloPayload {
                device_id: String::new(),
                ..hello_payload("x")
            })
            .unwrap(),
        );
        assert!(parse_hello(&empty_id).is_none());
    }

    // ---------- 入表逻辑 ----------

    #[test]
    fn absorb_adds_then_dedupes_then_updates() {
        let mut t = NeighborTable::new(DEFAULT_TIMEOUT_MS);
        let bytes = encode_hello(&hello_payload("dev-b"));

        // 首次 → Added，ip 取源地址而非 payload
        match absorb_datagram(&mut t, "dev-a", 1_000, from(), &bytes, &AddrPolicy::any()) {
            Absorbed::Added(n) => {
                assert_eq!(n.device_id, "dev-b");
                assert_eq!(n.name, "host-dev-b");
                assert_eq!(n.ip, "192.168.1.77");
                assert_eq!(n.port, 9527);
                assert_eq!(n.platform, "windows");
                assert!(!n.paired);
                assert_eq!(n.last_seen_ms, 1_000);
            }
            other => panic!("期望 Added，实际 {other:?}"),
        }

        // 同一台设备再来一份心跳 → Unchanged，不推事件
        match absorb_datagram(&mut t, "dev-a", 4_000, from(), &bytes, &AddrPolicy::any()) {
            Absorbed::Unchanged(n) => assert_eq!(n.last_seen_ms, 4_000),
            other => panic!("期望 Unchanged，实际 {other:?}"),
        }
        assert!(Absorbed::Unchanged(neighbor("x", 1)).event().is_none());
        assert_eq!(t.get("dev-b").unwrap().last_seen_ms, 4_000);

        // 换 IP（DHCP / 漫游，风险17）→ Updated 且地址跟随
        let new_addr = SocketAddr::from((Ipv4Addr::new(10, 0, 0, 12), 45_999));
        match absorb_datagram(&mut t, "dev-a", 5_000, new_addr, &bytes, &AddrPolicy::any()) {
            Absorbed::Updated(n) => assert_eq!(n.ip, "10.0.0.12"),
            other => panic!("期望 Updated，实际 {other:?}"),
        }
        // 事件映射
        assert!(Absorbed::Ignored(IgnoreReason::SelfHello).event().is_none());
        assert!(matches!(
            Absorbed::Added(neighbor("x", 1)).event(),
            Some(DiscoveryEvent::Added(_))
        ));
        assert!(matches!(
            Absorbed::Updated(neighbor("x", 1)).event(),
            Some(DiscoveryEvent::Updated(_))
        ));
    }

    #[test]
    fn absorb_filters_self_hello_and_bad_packets() {
        let mut t = NeighborTable::new(DEFAULT_TIMEOUT_MS);
        // 自己的 HELLO 从组播回环收到 → 不入表
        let mine = encode_hello(&hello_payload("dev-a"));
        assert_eq!(
            absorb_datagram(&mut t, "dev-a", 1_000, from(), &mine, &AddrPolicy::any()),
            Absorbed::Ignored(IgnoreReason::SelfHello)
        );
        // 乱码
        assert_eq!(
            absorb_datagram(&mut t, "dev-a", 1_000, from(), &[0u8, 1, 2], &AddrPolicy::any()),
            Absorbed::Ignored(IgnoreReason::Malformed)
        );
        // 版本不符（风险10）
        let future = encode_hello(&HelloPayload {
            proto_version: VERSION + 1,
            ..hello_payload("dev-future")
        });
        assert_eq!(
            absorb_datagram(&mut t, "dev-a", 1_000, from(), &future, &AddrPolicy::any()),
            Absorbed::Ignored(IgnoreReason::VersionMismatch)
        );
        assert!(t.is_empty(), "被忽略的数据报不应入表");
    }

    // ---------- 多网卡：子网广播与地址优选（T1.6） ----------

    #[test]
    fn subnet_broadcast_and_same_subnet_math() {
        let iface = LocalInterface {
            name: "以太网".into(),
            addr: Ipv4Addr::new(192, 168, 1, 191),
            netmask: Ipv4Addr::new(255, 255, 255, 0),
        };
        assert_eq!(iface.broadcast(), Ipv4Addr::new(192, 168, 1, 255));
        assert_eq!(iface.label(), "以太网=192.168.1.191/24");
        assert_eq!(prefix_len(iface.netmask), 24);
        assert!(iface.contains(Ipv4Addr::new(192, 168, 1, 20)));
        assert!(!iface.contains(Ipv4Addr::new(192, 168, 238, 1)));
        // /16 与 /24 的差别
        assert_eq!(
            subnet_broadcast(Ipv4Addr::new(10, 1, 2, 3), Ipv4Addr::new(255, 255, 0, 0)),
            Ipv4Addr::new(10, 1, 255, 255)
        );
        assert!(same_subnet(
            Ipv4Addr::new(10, 1, 2, 3),
            Ipv4Addr::new(10, 1, 9, 9),
            Ipv4Addr::new(255, 255, 0, 0)
        ));
    }

    #[test]
    fn is_virtual_adapter_detects_common_names() {
        // 虚拟网卡（应被过滤）
        for name in [
            "VMware Network Adapter VMnet1",
            "VMnet8",
            "vEthernet (WSL)",
            "VirtualBox Host-Only",
            "Hyper-V Virtual Ethernet",
            "Loopback Pseudo-Interface 1",
            "Tailscale",
            "WireGuard Tunnel",
        ] {
            assert!(
                is_virtual_adapter_name(name),
                "{name} 应识别为虚拟网卡"
            );
        }
        // 真实网卡（不应被过滤）
        for name in ["以太网 7", "Ethernet", "Wi-Fi", "WLAN"] {
            assert!(
                !is_virtual_adapter_name(name),
                "{name} 不应识别为虚拟网卡"
            );
        }
    }

    #[test]
    fn filtered_interfaces_exclude_virtual() {
        let all = local_interfaces();
        let filtered = local_interfaces_filtered(true);
        // 过滤后不应含虚拟网卡
        for iface in &filtered {
            assert!(
                !is_virtual_adapter_name(&iface.name),
                "过滤后仍含虚拟网卡: {:?}",
                iface.name
            );
        }
        // 过滤是「只减不增」
        assert!(filtered.len() <= all.len());
        // 本机有 VMware 网卡时，过滤后应确实变少
        if all.iter().any(|i| is_virtual_adapter_name(&i.name)) {
            assert!(filtered.len() < all.len(), "有虚拟网卡时过滤应变少");
        }
    }

    #[test]
    fn local_interfaces_exclude_loopback_and_have_broadcast() {
        let ifaces = local_interfaces();
        // 本机可能确实没有可用局域网卡（CI 容器），有则必须满足基本不变量
        for iface in &ifaces {
            assert!(!iface.addr.is_loopback(), "loopback 不应出现: {iface:?}");
            assert!(!iface.addr.is_link_local(), "链路本地不应出现: {iface:?}");
            assert_eq!(
                iface.broadcast(),
                subnet_broadcast(iface.addr, iface.netmask)
            );
            assert!(!iface.label().is_empty());
        }
        // 本机（开发机）确实只有一块真实网卡 + 两块 VMware 虚拟网卡
        if !ifaces.is_empty() {
            println!("本机发现网卡: {:?}", ifaces.iter().map(|i| i.label()).collect::<Vec<_>>());
        }
    }

    #[test]
    fn addr_policy_prefers_reachable_and_stays_stable() {
        // 只有一个真实网卡 192.168.1.x/24，另有一块虚拟网卡 192.168.238.x/24
        let policy = AddrPolicy::new(vec![LocalInterface {
            name: "以太网 7".into(),
            addr: Ipv4Addr::new(192, 168, 1, 191),
            netmask: Ipv4Addr::new(255, 255, 255, 0),
        }]);
        assert!(policy.reachable("192.168.1.20"));
        assert!(!policy.reachable("192.168.238.1"));
        assert!(!policy.reachable("not-an-ip"));

        // 当前地址可达 → 即使来了新地址也不跳（防 UI 抖动）
        assert_eq!(
            policy.prefer(Some("192.168.1.20"), &[], "192.168.1.77"),
            "192.168.1.20"
        );
        // 当前地址不可达（虚拟网卡）→ 换成可达的新地址
        assert_eq!(
            policy.prefer(Some("192.168.238.1"), &[], "192.168.1.77"),
            "192.168.1.77"
        );
        // 都不可达 → 保持当前（不要在两个都不可达的地址之间来回跳）
        assert_eq!(
            policy.prefer(Some("10.9.9.9"), &[], "10.8.8.8"),
            "10.9.9.9"
        );
        // 没有任何网卡信息（例如枚举失败）→ 跟随新地址，别把 DHCP 换 IP 卡死
        assert_eq!(
            AddrPolicy::any().prefer(Some("10.9.9.9"), &[], "10.8.8.8"),
            "10.8.8.8"
        );
        // 无当前 → 从历史里挑可达的，实在没有才用新地址
        assert_eq!(
            policy.prefer(None, &["10.0.0.1".into(), "192.168.1.5".into()], "10.7.7.7"),
            "192.168.1.5"
        );
        assert_eq!(policy.prefer(None, &[], "10.7.7.7"), "10.7.7.7");
    }

    #[test]
    fn absorb_prefers_reachable_address_and_keeps_history() {
        let mut t = NeighborTable::new(DEFAULT_TIMEOUT_MS);
        let bytes = encode_hello(&hello_payload("dev-b"));
        let policy = AddrPolicy::new(vec![LocalInterface {
            name: "以太网 7".into(),
            addr: Ipv4Addr::new(192, 168, 1, 191),
            netmask: Ipv4Addr::new(255, 255, 255, 0),
        }]);
        let virtual_addr = SocketAddr::from((Ipv4Addr::new(192, 168, 238, 1), 45_999));
        let lan_addr = SocketAddr::from((Ipv4Addr::new(192, 168, 1, 20), 45_999));

        // 第一条来自虚拟网卡 → 只有它可选
        assert!(matches!(
            absorb_datagram(&mut t, "dev-a", 1_000, virtual_addr, &bytes, &policy),
            Absorbed::Added(_)
        ));
        assert_eq!(t.get("dev-b").unwrap().ip, "192.168.238.1");

        // 之后从真实局域网卡收到同一设备 → 优选切到可达地址，并记录历史
        match absorb_datagram(&mut t, "dev-a", 2_000, lan_addr, &bytes, &policy) {
            Absorbed::Updated(n) => assert_eq!(n.ip, "192.168.1.20"),
            other => panic!("期望 Updated，实际 {other:?}"),
        }
        let n = t.get("dev-b").unwrap();
        assert_eq!(n.ip, "192.168.1.20", "优选地址应为可达地址");
        assert_eq!(n.addr_history[0], "192.168.1.20", "优选地址置顶");
        assert!(n.addr_history.contains(&"192.168.238.1".to_string()), "历史保留旧地址");

        // 再来一次虚拟网卡报文 → 优选不变（不抖动）
        assert!(matches!(
            absorb_datagram(&mut t, "dev-a", 3_000, virtual_addr, &bytes, &policy),
            Absorbed::Unchanged(_)
        ));
        assert_eq!(t.get("dev-b").unwrap().ip, "192.168.1.20");
    }

    #[test]
    fn heartbeats_are_sent_out_every_local_interface() {
        // 回归测试（本轮真实缺陷）：出接口交给系统时，多网卡主机上 HELLO 只从
        // VMware 虚拟网卡发出（实测来源 192.168.238.1），真实局域网对端收不到。
        // 修好后每块网卡都会收到一次子网定向广播，来源地址应覆盖全部网卡。
        let ifaces = local_interfaces();
        if ifaces.is_empty() {
            return; // 没有任何可用 IPv4 网卡（CI 容器）时跳过
        }

        // 独立接收端：与服务同绑发现端口（SO_REUSEADDR），只听广播/单播
        let receiver = bind_discovery_socket(DEFAULT_DISCOVERY_PORT).expect("接收端绑定失败");
        receiver
            .set_read_timeout(Some(Duration::from_millis(200)))
            .unwrap();

        let cfg = DiscoveryConfig::new("dev-tx", "tx-host", "windows", 45_998)
            .with_listen_port(DEFAULT_DISCOVERY_PORT)
            .with_timing(Duration::from_millis(100), Duration::from_millis(500));
        let mut service = spawn(cfg, None).expect("发现服务启动失败");

        let mut sources: Vec<Ipv4Addr> = Vec::new();
        let mut buf = [0u8; 2048];
        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline {
            if let Ok((n, from)) = receiver.recv_from(&mut buf) {
                if parse_hello(&buf[..n]).is_some() {
                    if let std::net::IpAddr::V4(v4) = from.ip() {
                        if !sources.contains(&v4) {
                            sources.push(v4);
                        }
                    }
                }
            }
        }
        let stats = service.stats();
        service.stop();

        // 每轮至少：组播 + 受限广播 + 每块网卡一次定向广播
        assert!(
            stats.hellos_sent >= 2 + ifaces.len() as u64,
            "发送计数偏少：{} < 2 + {}",
            stats.hellos_sent,
            ifaces.len()
        );

        let missing: Vec<String> = ifaces
            .iter()
            .filter(|iface| !sources.iter().any(|src| iface.contains(*src)))
            .map(|iface| iface.label())
            .collect();
        assert!(
            missing.is_empty(),
            "以下网卡没有发出可被本机收到的 HELLO：{missing:?}（实际来源 {sources:?}）"
        );
    }

    // ---------- 真实 socket 端到端 ----------

    #[test]
    fn config_defaults_match_plan() {
        let cfg = DiscoveryConfig::new("dev-a", "DESKTOP-ORION", "windows", 9527);
        assert_eq!(cfg.listen_port, DEFAULT_DISCOVERY_PORT);
        assert_eq!(cfg.multicast_addr, DEFAULT_MULTICAST_ADDR);
        assert_eq!(
            cfg.hello_interval.as_millis() as u64,
            DEFAULT_HELLO_INTERVAL_MS
        );
        assert_eq!(cfg.timeout.as_millis() as u64, DEFAULT_TIMEOUT_MS);
        assert_eq!(cfg.hello_payload().proto_version, VERSION);
        // 端口 0 交给系统分配（本机多实例）
        assert_eq!(cfg.clone().with_listen_port(0).listen_port, 0);
    }

    #[test]
    fn spawn_rejects_empty_device_id() {
        let cfg = DiscoveryConfig::new("  ", "x", "windows", 1).with_listen_port(0);
        assert!(spawn(cfg, None).is_err());
    }

    #[test]
    fn two_instances_discover_each_other_then_timeout() {
        let timing = |id: &str, peers: Vec<SocketAddr>| {
            DiscoveryConfig::new(id, format!("host-{id}"), "windows", 9527)
                .with_listen_port(0)
                .with_peers(peers)
                .with_timing(Duration::from_millis(120), Duration::from_millis(700))
        };

        let (tx_a, rx_a) = mpsc::channel();
        let mut a = spawn(timing("dev-a", vec![]), Some(tx_a)).expect("A 绑定失败");
        let addr_a = SocketAddr::from((Ipv4Addr::LOCALHOST, a.local_port()));

        let (tx_b, rx_b) = mpsc::channel();
        let b = spawn(timing("dev-b", vec![addr_a]), Some(tx_b)).expect("B 绑定失败");
        let addr_b = SocketAddr::from((Ipv4Addr::LOCALHOST, b.local_port()));
        assert_ne!(a.local_port(), b.local_port());

        // A 手动直连 B（T1.2 兜底路径）：立即补发 HELLO，无需等心跳周期
        a.add_peer(addr_b).expect("A → B 单播 HELLO 失败");

        assert!(
            wait_until(Duration::from_secs(5), || !a.is_empty()),
            "A 未发现 B（邻居表为空）"
        );
        assert!(
            wait_until(Duration::from_secs(5), || !b.is_empty()),
            "B 未发现 A（邻居表为空）"
        );
        let seen_by_a = a.devices();
        assert_eq!(seen_by_a.len(), 1);
        assert_eq!(seen_by_a[0].device_id, "dev-b");
        assert_eq!(seen_by_a[0].name, "host-dev-b");
        assert_eq!(seen_by_a[0].port, 9527, "端口应为对方 chat_port");
        assert_eq!(seen_by_a[0].ip, "127.0.0.1");
        assert_eq!(b.devices()[0].device_id, "dev-a");
        assert!(a.peers().contains(&addr_b));

        // 事件推送：Added（而不是轮询）
        let mut saw_added = false;
        while let Ok(ev) = rx_a.recv_timeout(Duration::from_millis(300)) {
            if matches!(ev, DiscoveryEvent::Added(_)) {
                saw_added = true;
                break;
            }
        }
        assert!(saw_added, "A 未收到 Added 事件");
        assert!(matches!(
            rx_b.recv_timeout(Duration::from_secs(1)),
            Ok(DiscoveryEvent::Added(_))
        ));

        // B 下线 → A 在超时（700ms）+ 摘除扫描（500ms）内收到 Removed
        drop(b);
        assert!(
            wait_until(Duration::from_secs(5), || a.is_empty()),
            "B 下线后未被摘除"
        );
        let mut saw_removed = false;
        while let Ok(ev) = rx_a.recv_timeout(Duration::from_millis(400)) {
            if matches!(ev, DiscoveryEvent::Removed { .. }) {
                saw_removed = true;
                break;
            }
        }
        assert!(saw_removed, "A 未收到 Removed 事件");

        // 服务仍在跑：announce_now 不报错，stop 可干净收尾
        assert!(a.is_running());
        a.announce_now().expect("announce_now 失败");

        // 网卡枚举与运行计数（UI 自检依赖这两个接口）
        let stats = a.stats();
        assert!(stats.hellos_sent > 0, "应至少发出过一轮 HELLO");
        assert!(stats.hellos_received > 0, "应至少收到过一次对端 HELLO");
        assert!(stats.last_hello_rx_ms.is_some());
        let ifaces = a.interfaces();
        if !ifaces.is_empty() {
            assert!(
                ifaces.iter().all(|i| !i.addr.is_loopback()),
                "loopback 不应参与发现: {ifaces:?}"
            );
        }

        a.stop();
        assert!(!a.is_running());
    }

    #[test]
    fn dropped_handle_stops_thread() {
        let cfg = DiscoveryConfig::new("dev-z", "host-z", "windows", 9527)
            .with_listen_port(0)
            .with_timing(Duration::from_millis(100), Duration::from_millis(500));
        let handle = spawn(cfg, None).expect("绑定失败");
        assert!(handle.is_running());
        assert!(handle.local_port() > 0);
        drop(handle); // Drop → stop → join
    }
}
