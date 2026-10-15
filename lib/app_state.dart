import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:rust_flutter_ui/src/rust/api/chat.dart' as rust_chat;
import 'package:rust_flutter_ui/src/rust/api/discovery.dart' as rust_discovery;
import 'package:rust_flutter_ui/src/rust/api/pairing.dart' as rust_pairing;

import 'appearance.dart';
import 'models.dart';
import 'services/chat_service.dart';
import 'services/transfer_service.dart';
import 'src/rust/api/transfer.dart' as rust_transfer;
import 'services/discovery_service.dart';
import 'services/pairing_service.dart';
import 'services/platform_channel.dart';

/// Which surface the right-hand content area is showing.
enum ContentTarget { none, conversation, discover, settings }

/// App-wide state (mock implementation — Rust-backed in M1+).
class AppState extends ChangeNotifier {
  AppState._() {
    _seed();
    // Restore last active session on launch (wide-screen default view).
    // 只对演示数据有意义；真实后端 rebuildConversations() 重建列表时会把
    // 越界的索引清掉，避免窄屏把它误判成「深层详情」。
    selectedConversation = 1;
  }

  static final AppState instance = AppState._();

  int navIndex = 0;
  int? selectedConversation;
  int? selectedDevice;
  ContentTarget contentTarget = ContentTarget.none;
  String searchQuery = '';
  bool discovering = false;
  final List<LanDevice> devices = [];
  final List<Conversation> conversations = [];

  int get totalUnread =>
      conversations.fold(0, (sum, c) => sum + c.unread);

  // ------------------------------------------------------------
  // Navigation
  // ------------------------------------------------------------

  void setNavIndex(int i) {
    navIndex = i;
    if (i == 1) {
      contentTarget = ContentTarget.discover;
      selectedConversation = null;
    } else if (i == 4) {
      // 4 = 设置
      contentTarget = ContentTarget.settings;
      selectedConversation = null;
    } else {
      // 0 = chats, 2 = contacts, 3 = files: 都清右侧
      contentTarget = ContentTarget.none;
      if (i == 2) selectedConversation = null;
    }
    notifyListeners();
  }

  void openConversation(int index) {
    if (index < 0 || index >= conversations.length) return;
    final conv = conversations[index];
    selectedConversation = index;
    activePeerId = conv.device.id;
    navIndex = 0;
    conv.unread = 0;
    contentTarget = ContentTarget.none;
    notifyListeners();
    // 真实链路：连对端 + 拉历史 + 标已读（都不阻塞界面）
    unawaited(ensureDial(conv.device.id));
    unawaited(loadHistory(conv.device.id));
    _markReadQuietly(conv.device.id);
  }

  /// 按 peer_id 打开会话（找不到就先建一个——对方可能先发消息过来）。
  void openConversationWith(String peerId) {
    var idx = conversations.indexWhere((c) => c.device.id == peerId);
    if (idx < 0) {
      conversations.insert(
        0,
        Conversation(device: _deviceFor(peerId), messages: _historyFor(peerId)),
      );
      idx = 0;
    }
    openConversation(idx);
  }

  void openSettings() {
    navIndex = 4; // 4 = 设置（3 是文件 TAB）
    contentTarget = ContentTarget.settings;
    notifyListeners();
  }

  /// Narrow-layout back: return to the list panel.
  void backToListPanel() {
    selectedConversation = null;
    selectedDevice = null;
    contentTarget = navIndex == 1
        ? ContentTarget.discover
        : ContentTarget.none;
    notifyListeners();
  }

  void setSearch(String q) {
    searchQuery = q;
    notifyListeners();
  }

  // ------------------------------------------------------------
  // Discovery / pairing
  // ------------------------------------------------------------

  Timer? _discoverTimer;

  // ------------------------------------------------------------
  // 真实发现（T1.3）：桥接可用时由 Rust UDP 服务驱动设备列表
  // ------------------------------------------------------------

  /// Rust 桥接是否可用；不可用时全部退化为本地 Mock，UI 不崩。
  bool backendAvailable = false;

  /// Rust 发现服务是否已运行。
  bool liveDiscovery = false;
  bool discoveryStarting = false;

  /// 设置项：自动过滤虚拟网卡（VMware/WSL 等），只用真实局域网网卡发现。
  /// 默认开启 —— 多网卡主机把 HELLO 发到虚拟网卡时真实对端收不到（T1.6）。
  /// 落盘在 <数据目录>/prefs.json：重启后要保持用户的选择。
  bool filterVirtualNic = true;

  /// 设置项：自动接收可信联系人的文件。
  ///
  /// ponytail: 本次只做「记住」（修 bug.md：核查设置项有没有持久化）。
  /// Rust 传输层没有对应入口，所以它暂时**不影响实际收发**；接线留待后续决定。
  bool autoAcceptFiles = true;

  /// 设置项：传输限速 MB/s，0 = 不限速。
  /// ponytail: 同上 —— 只落盘，暂未接入 Rust 传输层。
  double speedLimitMb = 0;

  /// 设置项目录（数据目录解析后由 [loadPairingStore] 注入；
  /// null = 还没解析到，不落盘 —— 与 `AppearanceState._dataDir` 同一套语义）。
  String? _prefsDir;

  File? get _prefsFile {
    final dir = _prefsDir;
    if (dir == null || dir.isEmpty) return null;
    return File('$dir${Platform.pathSeparator}prefs.json');
  }

  /// 注入设置项目录并载入（与 `AppearanceState.attachDataDir` 对称）。
  /// 空串 = 摘掉目录（不落盘），测试复位用。
  void attachPrefsDir(String dir) {
    _prefsDir = dir;
    _loadPrefs();
    _loadRemovedPeers();
  }

  /// 删除墓碑文件（B1 第 2 条）：`removed_peers.json`。
  File? get _removedPeersFile {
    final dir = _prefsDir;
    if (dir == null || dir.isEmpty) return null;
    return File('$dir${Platform.pathSeparator}removed_peers.json');
  }

  /// 把删除墓碑读回内存。
  ///
  /// 为什么必须落盘：[_removedPeers] 是 [rebuildConversations] 里唯一阻止已删
  /// 联系人复活的闸门（`peers.removeWhere(_removedPeers.contains)`）。它以前
  /// **只存在内存**，删完联系人（[removeContact] → `clearHistory` 走 Rust 存储，
  /// 可能失败/延迟）后本地历史 key 或存储摘要仍留着该 peer；一旦**重启进程**，
  /// 墓碑集合清空，重建会话列表时该 peer 又被拉回来 —— 此时配对表里已经没有它，
  /// [_deviceFor] 只能兜底造名字，消息 tab 上就显示成「未知设备·xxxx」。
  /// 这正是用户说的「删联系人后有概率下次打开还残留（未知设备）」。
  void _loadRemovedPeers() {
    try {
      final f = _removedPeersFile;
      if (f == null || !f.existsSync()) return;
      final raw = jsonDecode(f.readAsStringSync());
      if (raw is! List) return;
      for (final e in raw) {
        if (e is String && e.isNotEmpty) _removedPeers.add(e);
      }
    } catch (_) {
      // 墓碑损坏不影响启动：当作没有墓碑（宁可多显示一条，也不要启动失败）
    }
  }

  /// 把删除墓碑写盘（删除联系人 / 重新配对撤墓碑时都要调）。
  void _saveRemovedPeers() {
    try {
      final f = _removedPeersFile;
      if (f == null) return;
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode(_removedPeers.toList()));
    } catch (_) {
      // 落盘失败不能影响删除动作本身
    }
  }

  /// 载入非外观设置项；缺失/损坏一律保留默认值（配置损坏不影响启动）。
  void _loadPrefs() {
    try {
      final f = _prefsFile;
      if (f == null || !f.existsSync()) return;
      final m = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      autoAcceptFiles = m['autoAccept'] as bool? ?? true;
      speedLimitMb = (m['speedLimitMb'] as num? ?? 0).toDouble().clamp(0, 50);
      filterVirtualNic = m['filterVirtualNic'] as bool? ?? true;
    } catch (_) {
      // 配置损坏不影响启动
    }
  }

  void _savePrefs() {
    try {
      final f = _prefsFile;
      if (f == null) return;
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode({
        'autoAccept': autoAcceptFiles,
        'speedLimitMb': speedLimitMb,
        'filterVirtualNic': filterVirtualNic,
      }));
    } catch (_) {
      // 保存失败静默（只影响下次启动记忆）
    }
  }

  void setAutoAcceptFiles(bool v) {
    autoAcceptFiles = v;
    notifyListeners();
    _savePrefs();
  }

  void setSpeedLimitMb(double v) {
    speedLimitMb = v.clamp(0, 50);
    notifyListeners();
    _savePrefs();
  }

  /// 切换虚拟网卡过滤并重启发现（需发现已启动才生效）。
  Future<void> setFilterVirtualNic(bool value) async {
    filterVirtualNic = value;
    notifyListeners();
    _savePrefs();
    if (liveDiscovery) {
      // 重启发现 = stop → start，必须先放掉旧订阅（B1 第 1 条）：
      // Rust 侧接收端已被旧 bridge 取走，不复位就永远收不到邻居事件。
      _releaseDiscoverySub();
      try {
        await DiscoveryService.instance.stop();
      } catch (_) {}
      liveDiscovery = false;
      await enableLiveDiscovery();
    }
  }

  /// 设置页展示的一行发现状态（端口 / 组播 / 错误）。
  String discoveryStatusText = '未启动';
  bool discoveryMulticast = false;
  StreamSubscription<rust_discovery.DiscoveryEventDto>? _discoverySub;

  /// 本机身份（真实值，供设备页「本机」卡片展示；不再是硬编码占位）。
  String localDeviceName = '解析中…';
  String localDeviceId = '';
  String localPlatform = '';
  String identityPath = '';
  bool multicastLockHeld = false;

  /// 本机可用于发现/连接的地址（去掉掩码，形如 192.168.1.191）。
  List<String> get localAddresses => localInterfaces
      .map((label) => label.split('=').last.split('/').first)
      .where((a) => a.isNotEmpty)
      .toList();

  /// 本机 id 的短形式（UI 展示 / 同名设备区分）。
  String get localDeviceIdShort =>
      localDeviceId.length >= 4 ? localDeviceId.substring(0, 4) : localDeviceId;

  /// 扫描中状态行（真实模式显示真实端口 / 组播锁，演示模式才有「演示」字样）。
  String get discoveryScanningText {
    if (!liveDiscovery) return '演示模式（Rust 桥接未接通，数据为本地 Mock）…';
    final lock = multicastLockHeld ? ' · 组播锁已持有' : '';
    return '正在扫描局域网（UDP :$discoveryListenPort · 组播 239.255.42.99$lock）…';
  }

  /// 实际监听的 UDP 端口（0 = 未启动）。
  int discoveryListenPort = 0;

  /// 发现自检：参与发现的本机网卡 + 收发计数（空列表时能说清原因）。
  List<String> localInterfaces = [];
  int hellosSent = 0;
  int hellosReceived = 0;
  int hellosIgnored = 0;
  int? lastHelloMs;
  String discoveryHint = '';
  Timer? _statsTimer;

  /// 控制消息前缀：删除联系人的跨端通知。
  ///
  /// 走现有聊天通道（协议里没有专门的帧），两端都识别它：收到即解除本机配对，
  /// 且**不入库、不显示**，避免用户看到乱码消息。
  static const String kRemoveNotice = '\u0001YC_RM\u0001';

  /// 是否是控制消息（删除通知）。
  static bool isControlText(String text) => text.startsWith(kRemoveNotice);

  /// 演示数据里的假设备 id（真实后端上线后整体清掉，真机上不该出现测试列表）。
  static const Set<String> _demoDeviceIds = {
    'dev-pc',
    'dev-phone',
    'dev-tablet',
    'dev-laptop',
  };

  /// 由 main() 在 Rust 桥接初始化成功后调用。
  void enableBackend() {
    backendAvailable = true;
    _clearDemoData();
  }

  /// 清掉演示用的假设备/假会话；真实数据随后由配对表 + 消息仓库重建。
  void _clearDemoData() {
    final hadDemo =
        devices.any((d) => _demoDeviceIds.contains(d.id)) ||
            conversations.any((c) => _demoDeviceIds.contains(c.device.id));
    if (!hadDemo) return;
    devices.removeWhere((d) => _demoDeviceIds.contains(d.id));
    conversations.removeWhere((c) => _demoDeviceIds.contains(c.device.id));
    _history.clear();
    _historyDone.clear();
    _historyLoaded.clear();
    selectedConversation = null;
    selectedDevice = null;
    activePeerId = null;
    notifyListeners();
  }

  /// 只解析本机身份（device_id / 设备名 / 组播锁），**不启动发现**。
  ///
  /// 默认不开启发现（任务8）：启动时不扫描，需要找设备时在设备页手动开始。
  Future<void> prepareIdentity() async {
    try {
      await DiscoveryService.instance.prepare();
      localDeviceName = DiscoveryService.instance.deviceName;
      localDeviceId = DiscoveryService.instance.deviceId;
      localPlatform = rust_discovery.discoveryPlatform();
      identityPath = DiscoveryService.instance.identityPath ?? '';
      multicastLockHeld = DiscoveryService.instance.multicastLockHeld;
      unawaited(refreshNotificationState());
      _syncDevicesFromContacts();
      discoveryStatusText = '未启动（需要时在设备页开启）';
    } catch (e) {
      discoveryStatusText = '身份解析失败：$e';
    }
    notifyListeners();
  }

  /// 配对表里的联系人同步成设备行：发现关闭时也能看到联系人并直接聊天。
  void _syncDevicesFromContacts() {
    for (final c in pairedContacts) {
      final idx = devices.indexWhere((d) => d.id == c.deviceId);
      if (idx >= 0) {
        devices[idx] = _copyDevice(devices[idx], paired: true);
        continue;
      }
      final addr = c.addrHistory.isNotEmpty ? c.addrHistory.first : '';
      final parts = addr.split(':');
      devices.add(LanDevice(
        id: c.deviceId,
        name: c.name,
        ip: parts.isNotEmpty ? parts.first : '',
        platform: c.platform == 'android'
            ? DevicePlatform.android
            : DevicePlatform.windows,
        online: chatOnline[c.deviceId] ?? false,
        paired: true,
        chatPort: parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0,
      ));
    }
  }

  /// 释放发现事件订阅（B1 第 1 条的核心）。
  ///
  /// 为什么必须显式释放：Rust 侧 `discovery_subscribe` 把事件总线的**接收端**
  /// `take_bus_rx()` 取走（`rust_builder/src/api/discovery.rs`），接收端只能被取
  /// 一次，取走后内部 `rx` 置 None。`discovery_stop()` 之后旧的 bridge 线程
  /// 随接收端一起结束 —— 事件总线上再没有接收端。
  ///
  /// 而 [_discoverySub] 以前是 `??=` 建一次就永不重建：停一次发现后，即使重新
  /// `start()` 让服务跑起来，邻居事件也**没有任何线程在接**，UI 收不到任何
  /// added/updated → 用户看到的「发现设备点了没反应、扫不出设备，要重启才出现」。
  ///
  /// 不变量：**任何让发现停下来的路径都必须让 `_discoverySub` 归零**；只要它
  /// 归零，`enableLiveDiscovery()` 里的 `??=` 就会自动重新订阅。
  ///
  /// 必须写在 `DiscoveryService.stop()` **之前**：stop() 在桥未初始化时会抛
  /// （`Bad state: flutter_rust_bridge has not been initialized`），写在后面
  /// 会被异常整个跳过，订阅从此永久泄漏。
  void _releaseDiscoverySub() {
    final sub = _discoverySub;
    _discoverySub = null;
    if (sub != null) unawaited(sub.cancel());
  }

  /// 配对成功后自动关闭发现（任务8）：联系人已经拿到，不必一直扫描耗电。
  Future<void> _autoStopDiscovery() async {
    if (!liveDiscovery) return;
    if (pairedContacts.isEmpty) return;
    // 先放订阅再停服务：stop() 抛异常也不能漏掉订阅（见 _releaseDiscoverySub）
    _releaseDiscoverySub();
    try {
      await DiscoveryService.instance.stop();
    } catch (_) {}
    liveDiscovery = false;
    discovering = false;
    _statsTimer?.cancel();
    _statsTimer = null;
    localInterfaces = [];
    discoveryHint = '';
    hellosSent = 0;
    hellosReceived = 0;
    discoveryStatusText = '已配对，发现已自动关闭（可在「设备」页重新开启）';
    notifyListeners();
  }

  /// 订阅事件流并启动 Rust 发现服务（幂等）。失败只影响设备页，不影响启动。
  Future<void> enableLiveDiscovery() async {
    if (liveDiscovery || discoveryStarting) return;
    discoveryStarting = true;
    discoveryStatusText = '正在启动…';
    // **先清邻居再订阅/启动**：反过来的话，启动期间到达的邻居事件
    // 会被随后的 clear 抹掉（上一版就是先启动后 clear，首屏经常是空的）。
    // 已配对联系人的行要留着 —— 否则一点「开始发现」联系人就从列表里消失。
    devices.removeWhere((d) => !d.paired);
    _syncDevicesFromContacts();
    selectedDevice = null;
    notifyListeners();
    try {
      // 1) 本机身份：持久化 device_id（重启不变）+ 真实设备名 + Android 组播锁
      await DiscoveryService.instance.prepare();
      localDeviceName = DiscoveryService.instance.deviceName;
      localDeviceId = DiscoveryService.instance.deviceId;
      localPlatform = rust_discovery.discoveryPlatform();
      identityPath = DiscoveryService.instance.identityPath ?? '';
      multicastLockHeld = DiscoveryService.instance.multicastLockHeld;
      unawaited(refreshNotificationState());
      // 2) 先订阅再启动：服务线程启动时就要拿到事件总线
      _discoverySub ??=
          DiscoveryService.instance.events().listen(_onDiscoveryEvent);
      final status = await DiscoveryService.instance.start(
        filterVirtual: filterVirtualNic,
      );
      liveDiscovery = status.running;
      discovering = status.running;
      discoveryMulticast = status.multicastJoined;
      discoveryListenPort = status.localPort;
      discoveryStatusText = status.multicastJoined
          ? 'UDP :${status.localPort} · 组播已加入'
          : 'UDP :${status.localPort} · 组播不可用（广播兜底）';
      refreshDiscoveryStats();
      _startStatsTimer();
    } catch (e) {
      liveDiscovery = false;
      discovering = false;
      discoveryStatusText = '启动失败：$e';
    } finally {
      discoveryStarting = false;
      notifyListeners();
    }
  }

  /// 刷新发现自检（同步 FFI，1Hz 节流调用）。
  void refreshDiscoveryStats() {
    if (!liveDiscovery) {
      localInterfaces = [];
      discoveryHint = '';
      return;
    }
    final stats = DiscoveryService.instance.stats();
    localInterfaces = stats.interfaces;
    hellosSent = stats.hellosSent;
    hellosReceived = stats.hellosReceived;
    hellosIgnored = stats.datagramsIgnored;
    lastHelloMs = stats.lastHelloRxMs;
    discoveryHint = _buildHint(stats.hellosSent, stats.hellosReceived);
  }

  /// 空列表时给出可执行的原因排查（而不是只说「未发现设备」）。
  String _buildHint(int sent, int received) {
    if (localInterfaces.isEmpty) {
      return '没有找到可用的局域网网卡，请先连接网络。';
    }
    if (received == 0) {
      return '已发出 $sent 次 HELLO，但一个回应都没收到。\n'
          '· 确认两台设备在同一个 Wi-Fi / 网段，且路由器没开「AP 隔离」\n'
          '· Windows 首次运行需在防火墙弹窗里允许（专用网络）\n'
          '· 仍不行就用上面的手动 IP:端口 直连兜底';
    }
    return '';
  }

  void _startStatsTimer() {
    _statsTimer ??= Timer.periodic(const Duration(seconds: 1), (t) {
      if (!liveDiscovery) {
        t.cancel();
        _statsTimer = null;
        return;
      }
      final before =
          '$hellosSent|$hellosReceived|${localInterfaces.length}|$discoveryHint';
      refreshDiscoveryStats();
      final after =
          '$hellosSent|$hellosReceived|${localInterfaces.length}|$discoveryHint';
      if (before != after) notifyListeners();
    });
  }

  /// 收到 Rust 推送的邻居变化（增 / 改 / 删）。
  void _onDiscoveryEvent(rust_discovery.DiscoveryEventDto event) {
    switch (event.change) {
      case rust_discovery.DiscoveryChange.added:
      case rust_discovery.DiscoveryChange.updated:
        final info = event.device;
        if (info == null) return;
        final device = _fromDeviceInfo(info);
        final index = devices.indexWhere((d) => d.id == device.id);
        if (index >= 0) {
          devices[index] = device;
        } else {
          devices.add(device);
        }
      case rust_discovery.DiscoveryChange.removed:
        devices.removeWhere((d) => d.id == event.deviceId);
        if (selectedDevice != null && selectedDevice! >= devices.length) {
          selectedDevice = null;
        }
    }
    notifyListeners();
  }

  LanDevice _fromDeviceInfo(rust_discovery.DeviceInfo info) {
    var name = info.name;
    // 同机双实例 / 两台同名机器：附 4 位设备 id，避免看起来像「本机」
    if (localDeviceName.isNotEmpty && name == localDeviceName) {
      final shortId = info.deviceId.length >= 4
          ? info.deviceId.substring(0, 4)
          : info.deviceId;
      name = '$name · $shortId';
    }
    return LanDevice(
      id: info.deviceId,
      name: name,
      ip: info.ip,
      platform: info.platform == 'android'
          ? DevicePlatform.android
          : DevicePlatform.windows,
      online: true,
      // 配对状态以配对表为准（重启后仍是「已配对」）
      paired: info.paired || isPaired(info.deviceId),
      // 对端聊天端口来自 HELLO（M3 拨号用）
      chatPort: info.port,
    );
  }

  Future<void> toggleDiscovering() async {
    // 真实模式：启停 Rust 发现服务
    if (liveDiscovery) {
      discovering = false;
      discoveryStatusText = '已停止';
      notifyListeners();
      // 先放订阅再停服务（B1 第 1 条）：stop() 在桥未初始化时会抛异常，
      // 释放写在它后面就会被整个跳过，订阅从此永久泄漏 ——
      // 下次「开始发现」被 `??=` 挡住复用已死的订阅 = 扫不出设备。
      _releaseDiscoverySub();
      try {
        await DiscoveryService.instance.stop();
      } catch (_) {
        // 桥不可用：UI 状态仍须复位（下面照常执行）
      }
      liveDiscovery = false;
      _statsTimer?.cancel();
      _statsTimer = null;
      // 停止发现只清掉邻居，已配对联系人要保留（仍可直接聊天）
      devices.removeWhere((d) => !d.paired);
      _syncDevicesFromContacts();
      selectedDevice = null;
      localInterfaces = [];
      discoveryHint = '';
      notifyListeners();
      return;
    }
    if (backendAvailable) {
      discovering = true;
      notifyListeners();
      await enableLiveDiscovery();
      return;
    }
    // 演示模式：3 秒后自动结束「发现中」
    discovering = !discovering;
    if (discovering) {
      _discoverTimer = Timer(const Duration(seconds: 3), () {
        discovering = false;
        notifyListeners();
      });
    } else {
      _discoverTimer?.cancel();
    }
    notifyListeners();
  }

  void selectDevice(int index) {
    selectedDevice = index;
    notifyListeners();
  }

  /// Android 通知权限状态（PLAN §3.2：先解释用途再请求；非 Android 恒为已授权）。
  bool notificationsGranted = true;
  bool permissionCardDismissed = false;

  /// 查询通知权限（Android 13+；其它平台直接视为已授权）。
  Future<void> refreshNotificationState() async {
    final granted = await YuChuanPlatform.notificationsGranted();
    if (granted == notificationsGranted) return;
    notificationsGranted = granted;
    notifyListeners();
  }

  /// 用户点了引导卡的「允许通知」：此时才弹系统权限框。
  Future<void> requestNotifications() async {
    await YuChuanPlatform.requestNotifications();
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await refreshNotificationState();
  }

  /// 「暂不」：本次运行不再提示（下次启动仍会出现，被拒也有引导而非死路）。
  void dismissPermissionCard() {
    permissionCardDismissed = true;
    notifyListeners();
  }

  /// 立刻重发一轮 HELLO（「重新发现」按钮），并刷新自检。
  Future<void> announceNow() async {
    if (!liveDiscovery) return;
    try {
      await DiscoveryService.instance.announce();
    } catch (_) {
      // 服务已停 / 端口异常：忽略，下面的自检会显示真实计数
    }
    refreshDiscoveryStats();
    notifyListeners();
  }

  /// 手动 IP:端口 直连（T1.2 AP 隔离兜底）。真实模式下交给 Rust 发 HELLO。
  Future<void> connectManual(String hostPort) async {
    if (liveDiscovery) {
      try {
        final addr = await DiscoveryService.instance.addPeer(hostPort);
        discoveryStatusText = '已直连 $addr（等待对端 HELLO）';
      } catch (e) {
        discoveryStatusText = '直连失败：$e';
      }
      notifyListeners();
      return;
    }
    final host = hostPort.trim().split(':').first;
    if (host.isEmpty) return;
    devices.add(LanDevice(
      id: 'manual-$host',
      name: '手动连接设备',
      ip: host,
      platform: DevicePlatform.android,
      online: true,
    ));
    selectedDevice = devices.length - 1;
    notifyListeners();
  }

  void startPairing() {
    notifyListeners();
  }

  // ------------------------------------------------------------
  // 配对与联系人（T2.1 状态机 / T2.2 配对表）
  // ------------------------------------------------------------

  /// 本次运行中删除过的联系人 id：重建会话列表时一律跳过，
  /// 防止残留的历史 key / 存储摘要把刚删掉的会话又拉回来。
  final Set<String> _removedPeers = {};

  /// 待补发的删除通知：对方当时离线没收到，等他上线后重发。
  ///
  /// 只有**确认发送成功**才从这里移除 —— 之前是发完就忘，对方离线时通知
  /// 直接丢，导致「一方删除后对方还留着配对」。
  final Set<String> _pendingRemoveNotices = {};

  /// 已配对联系人（配对表内存镜像，重启时从 contacts.json 载入）。
  List<rust_pairing.PairedContactDto> pairedContacts = [];
  String pairingStorePath = '';
  bool pairingStoreOpened = false;
  bool pairingStoreRecovered = false;

  /// 配对操作窗口是否应该显示（由 UI 宿主监听它来开/关唯一的弹窗）。
  ///
  /// 之前靠事件回调触发 showDialog：首次请求时状态机还没产出 PIN 会直接早退
  /// （弹不出来），成功后第二次触发又会叠一个窗口卡住界面。改成状态驱动。
  bool pairingActive = false;

  /// 当前会话要显示的 6 位 PIN（null = 还没生成）。
  String? pairingPin;
  String? pairingError;
  int pairingRemainingMs = 0;

  /// T5.2 配对成功动画：成功先置位（PIN 卡播 ✓ 动画），
  /// 动画结束调 [finishPairingAnimation] 才真正进会话。
  bool pairingSucceeded = false;
  String? pairingCompletePeer;

  /// 本机在本轮配对里的角色：发起方只能等对端 PAIR_RESP（M3 送到），
  /// 应答方才是「对照 PIN 后点确认」（PLAN §3.3）。
  rust_pairing.PairRoleDto? pairingRole;
  String? pairingPeerId;

  bool get pairingIsInitiator =>
      pairingRole == rust_pairing.PairRoleDto.initiator;
  bool get pairingIsResponder =>
      pairingRole == rust_pairing.PairRoleDto.responder;

  bool _pairBusy = false;

  bool get pairBusy => _pairBusy;

  /// 配对超时秒数（UI 倒计时初值，来自 Rust 常量，避免两边各写一个 60）。
  /// 桥接未就绪时兜底 60s（与 Rust 侧 DEFAULT 一致），不要把异常抛到 UI。
  int get pairingTimeoutSeconds {
    try {
      return PairingService.instance.timeoutMs ~/ 1000;
    } catch (_) {
      return 60;
    }
  }

  /// 该设备是否已在配对表里。
  bool isPaired(String deviceId) =>
      pairedContacts.any((c) => c.deviceId == deviceId);

  /// 打开配对表并载入联系人（main 里桥接就绪后调用一次）。
  Future<void> loadPairingStore() async {
    try {
      await DiscoveryService.instance.prepare();
      // 外观设置（主题色/壁纸/滤镜）落盘在数据目录，先注入再载入
      final dir = DiscoveryService.instance.dataDir;
      if (dir != null && dir.isNotEmpty) {
        AppearanceState.instance.attachDataDir(dir);
        // 非外观设置项（自动接收 / 限速 / 虚拟网卡过滤）另存 prefs.json
        attachPrefsDir(dir);
      }
      final status = await PairingService.instance.open(
        DiscoveryService.instance.dataDir,
      );
      pairingStorePath = status.storePath;
      pairingStoreOpened = PairingService.instance.opened;
      pairingStoreRecovered = status.recoveredFromCorruption;
      pairedContacts = PairingService.instance.contacts();
      _syncDevicesFromContacts();
    } catch (e) {
      pairingStorePath = '打开失败：$e';
      pairingStoreOpened = false;
    }
    notifyListeners();
  }

  /// 发起配对（生成 PIN 并显示；已配对设备直接幂等成功）。
  Future<void> beginPairing(LanDevice dev) async {
    pairingPin = null;
    pairingError = null;
    pairingRole = rust_pairing.PairRoleDto.initiator;
    pairingPeerId = dev.id;
    pairingActive = true; // 窗口立刻出现（PIN 回来后填充）
    pairingRemainingMs = PairingService.instance.timeoutMs;
    notifyListeners();
    try {
      // 配对表必须先打开：否则**第一次**配对会因为 store 未就绪直接失败，
      // 重试才成功（用户反馈「第一配对请求对方不弹，返回重试才行」）
      await PairingService.instance.open(DiscoveryService.instance.dataDir);
      final outcome = await PairingService.instance.start(
        peerId: dev.id,
        peerName: dev.name,
        peerPlatform: dev.platform == DevicePlatform.android
            ? 'android'
            : 'windows',
        peerAddr: dev.ip,
      );
      pairingPin = outcome.session.pin;
      pairingRole = outcome.session.role;
      pairingPeerId = outcome.session.peerId;
      pairingRemainingMs = outcome.session.remainingMs;
      // 把 PAIR_REQ 发到对端。
      // 关键：必须**先等连接建立**再发。之前是 unawaited(ensureDial) 后
      // 立刻发，拨号还没完成帧就丢了 —— 表现为「第一次对方不弹，返回再点
      // 一次才行」（第二次时 Rust 侧重试已经把连接建好了）。
      if (outcome.sendRequest != null && pairingPin != null) {
        final sent = await _sendPairRequestWithRetry(dev.id, pairingPin!);
        if (!sent && pairingError == null) {
          pairingError = '配对请求发送失败，请确认对方在线后重试';
        }
      }
      final contact = outcome.contact;
      if (contact != null) _upsertContact(contact);
      if (outcome.session.state == rust_pairing.PairStateDto.paired) {
        // 已在配对表里：不再走 PIN，直接完成
        _completePairingUi(dev);
      }
    } catch (e) {
      pairingError = '发起配对失败：$e';
    }
    notifyListeners();
  }

  /// 确保与对端的 TCP 连接真的建立好了（不只是登记了重试器）。
  ///
  /// [ensureDial] 只是让 Rust 侧开始退避重试就返回，连接此时**还没通**；
  /// 紧接着发的帧会直接丢失。这里等到 chatOnline 变 true 或超时。
  Future<bool> _awaitConnected(String peerId, {Duration timeout = const Duration(seconds: 8)}) async {
    await ensureDial(peerId);
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (chatOnline[peerId] ?? false) return true;
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    return chatOnline[peerId] ?? false;
  }

  /// 发 PAIR_REQ，带连接等待与发送重试。
  ///
  /// 返回是否真的送出去了。第一次配对失败的根因就是这里没等连接就发。
  Future<bool> _sendPairRequestWithRetry(String peerId, String pin) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final connected = await _awaitConnected(
        peerId,
        timeout: Duration(seconds: attempt == 0 ? 8 : 4),
      );
      if (!connected) continue;
      try {
        await ChatService.instance.sendPairRequest(
          peerId: peerId,
          senderId: DiscoveryService.instance.deviceId,
          pin: pin,
        );
        return true;
      } catch (_) {
        // 连接可能刚断开：退一步重来（清冷却，让下一轮 ensureDial 真去重拨）
        _dialedAt.remove(peerId);
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    return false;
  }
  /// 「应答方入口该采纳哪个角色」—— 抽成纯函数以便直接钉住（B1 第 3 条）。
  ///
  /// 根因：应答方入口先把角色占位成 responder（这样弹窗按应答方渲染），
  /// 随后**无条件**用 `outcome.session.role` 覆盖。若本机此刻正卡在这个对端的
  /// `WaitingResponse`（本机先前发起过、对端还没回），这条 PAIR_REQ 在 Rust 状态机
  /// 里只会被回一个 Busy —— **角色/状态一个都不改**（见 `rust_builder/src/backend/
  /// pairing.rs` 的 `on_request`），于是 `session.role` 仍是 initiator，
  /// 弹窗就渲染成「与 X 配对 / 已生成 PIN / 等待对方确认」这套**发起方** UI。
  /// 用户看到的正是「手机端发起的配对申请，对端显示的也是反过来的配对申请，
  /// 而不是同意窗」。
  ///
  /// 判定语义：**只有状态机确实进入了应答态（awaitingConfirm）才采纳会话角色**；
  /// failed / busy / 状态未变一律保持入口设定的 responder。
  @visibleForTesting
  static rust_pairing.PairRoleDto responderRoleAfter({
    required bool wasResponder,
    required rust_pairing.PairStateDto state,
    required rust_pairing.PairRoleDto sessionRole,
  }) {
    if (!wasResponder) return sessionRole;
    // 真正进入应答态：可以采纳状态机的角色
    if (state == rust_pairing.PairStateDto.awaitingConfirm) return sessionRole;
    // 其余（failed / waitingResponse / idle / …）都说明这次请求没被受理，
    // 必须保持入口设定的 responder，否则对端看到反向的配对申请。
    return rust_pairing.PairRoleDto.responder;
  }

  /// 应答方入口：收到对端 PAIR_REQ（M3 由 TCP 会话层调用；UI 会直接显示 PIN 卡片）。
  Future<void> beginResponderPairing({
    required String peerId,
    required String peerName,
    required String platform,
    required String pin,
    String? addr,
  }) async {
    // 同一台设备重复发来的 PAIR_REQ（重试/重传）不要把正在进行的会话打断重来
    if (pairingActive && pairingPeerId == peerId && pairingPin != null) {
      return;
    }
    pairingError = null;
    // 应答方：先占位为 responder —— 窗口标题/按钮按角色走，
    // 即使状态机稍后才回填也不会错弹成「发起配对」
    pairingRole = rust_pairing.PairRoleDto.responder;
    pairingPeerId = peerId;
    pairingActive = true;
    notifyListeners();
    try {
      // 配对表必须先打开（与发起方同理，否则第一次请求会失败）
      await PairingService.instance.open(DiscoveryService.instance.dataDir);
      final outcome = await PairingService.instance.receiveRequest(
        peerId: peerId,
        peerName: peerName,
        peerPlatform: platform,
        pin: pin,
        peerAddr: addr,
      );
      pairingPin = outcome.session.pin;
      // B1 第 3 条：**不能**无条件采纳会话角色 —— 状态机回 Busy（本机正卡在
      // 该对端的 WaitingResponse）时 role 仍是 initiator，无条件覆盖会把
      // 应答窗渲染成发起窗（用户报的「反过来的配对申请」）。
      pairingRole = responderRoleAfter(
        wasResponder: true,
        state: outcome.session.state,
        sessionRole: outcome.session.role,
      );
      pairingPeerId = outcome.session.peerId;
      pairingRemainingMs = outcome.session.remainingMs;
      if (outcome.session.state == rust_pairing.PairStateDto.failed) {
        pairingError = _pairFailureText(outcome.session.failure);
      }
    } catch (e) {
      pairingError = '接收配对请求失败：$e';
    }
    notifyListeners();
  }

  /// 用户确认配对（**应答方**）：回 PAIR_RESP + 写配对表 + 建立会话。
  ///
  /// 发起方不能在这里直接完成配对 —— 协议要求等对端 PAIR_RESP（M3 传输层），
  /// 这里只提示「等待对方确认」。
  Future<void> confirmPairing(String pin) async {
    if (_pairBusy) return;
    if (pairingIsInitiator) {
      pairingError = '已核对 PIN，正在等待对方确认…';
      notifyListeners();
      return;
    }
    _pairBusy = true;
    pairingError = null;
    notifyListeners();
    try {
      if (pairingPin != null && pin.trim() != pairingPin) {
        pairingError = 'PIN 与本机显示不一致，请重新发起配对';
        pairingPin = null; // 让弹窗显示错误 + 出口，而不是继续停在 PIN 上
        return;
      }
      final outcome = await PairingService.instance.confirm();
      final failure = outcome.session.failure;
      if (outcome.session.state == rust_pairing.PairStateDto.failed) {
        pairingError = _pairFailureText(failure);
        pairingPin = null;
        return;
      }
      final contact = outcome.contact;
      if (contact != null) _upsertContact(contact);
      // 回 PAIR_RESP（应答方）
      final peerId = pairingPeerId;
      if (peerId != null) {
        final resp = outcome.sendResponse;
        try {
          await ChatService.instance.sendPairResponse(
            peerId: peerId,
            accepted: resp?.accepted ?? true,
            reason: resp?.reason,
          );
        } catch (e) {
          pairingError = '配对响应发送失败：$e';
        }
      }
      // 成功：先播 ✓ 动画，动画结束才进会话（T5.2）
      final idx = selectedDevice;
      pairingCompletePeer = pairingPeerId ??
          (idx != null && idx < devices.length ? devices[idx].id : null);
      pairingSucceeded = true;
      pairingPin = null;
      pairingRole = null;
      pairingPeerId = null;
    } catch (e) {
      pairingError = '配对失败：$e';
    } finally {
      _pairBusy = false;
      notifyListeners();
    }
  }

  /// 配对状态全量复位（成功 / 取消 / 超时 / 失败都走这里）。
  ///
  /// 只要有一个字段残留，弹窗就会停在错误的界面上 —— 之前反复出现的
  /// 「卡在配对成功界面」「窗口不消失」大多源于此。
  void pairingReset() {
    pairingPin = null;
    pairingRole = null;
    pairingPeerId = null;
    pairingError = null;
    pairingSucceeded = false;
    pairingCompletePeer = null;
    pairingActive = false;
    pairingRemainingMs = 0;
  }

  /// 配对成功动画播完（UI 的 Timer 调用）→ 真正建会话并打开。
  void finishPairingAnimation() {
    final peer = pairingCompletePeer;
    pairingReset();
    if (peer != null) {
      _completePairingUi(_deviceFor(peer));
    } else {
      notifyListeners();
    }
  }

  /// 取消配对（返回发现页）。
  Future<void> cancelPairing() async {
    try {
      await PairingService.instance.cancel();
    } catch (_) {
      // 没有会话时忽略
    }
    pairingReset(); // 关掉操作窗口
    notifyListeners();
  }

  /// 配对窗口最长停留时间（秒）：超过就强制收尾，绝不允许卡死界面。
  static const int pairingMaxSeconds = 75;

  /// 60s 倒计时到点：让状态机超时并给文案。
  Future<void> pairingCountdownFinished() async {
    // 会话已经结束了就别再动状态（成功动画期间倒计时到点会把它打回错误态）
    if (!pairingActive || pairingSucceeded) return;
    try {
      await PairingService.instance.tick();
    } catch (_) {
      // 忽略：状态机可能已经终态
    }
    // 保留窗口显示超时原因（并给出口），但清掉 PIN/角色，避免状态错乱
    pairingReset();
    pairingError = '配对超时（60s），请重新发起';
    pairingActive = true;
    notifyListeners();
  }

  /// 删除联系人：配对表 + 会话列表 + 本地历史 + 在线状态 + 连接，一并清掉（任务12）。
  Future<bool> removeContact(String deviceId, {bool notify = true}) async {
    var ok = false;
    _removedPeers.add(deviceId);
    // 墓碑必须立刻落盘（B1 第 2 条）：只放内存的话，重启后集合清空，
    // 删不干净的残留历史会把该 peer 拉回成「未知设备·xxxx」。
    _saveRemovedPeers();
    // 通知对端也解除配对（走聊天通道的控制消息；对方收到后不会回发，避免乒乓）
    if (notify && chatReady) {
      unawaited(_sendRemoveNotice(deviceId));
    }
    try {
      ok = await PairingService.instance.remove(deviceId);
    } catch (e) {
      pairingError = '删除联系人失败：$e';
    }
    try {
      pairedContacts = PairingService.instance.contacts();
    } catch (_) {
      // 桥接未就绪：至少把内存里的这条摘掉，界面不残留
      pairedContacts = [
        for (final c in pairedContacts)
          if (c.deviceId != deviceId) c,
      ];
    }
    // 1) 断开与该设备的会话（连着也没意义了）
    _dialedAt.remove(deviceId);
    chatOnline.remove(deviceId);
    _historyLoaded.remove(deviceId);
    _historyDone.remove(deviceId);
    _resyncedFiles.removeWhere((k) => k.startsWith('$deviceId|'));
    if (noticePeerId == deviceId) dismissNotice();
    if (chatReady) {
      try {
        await ChatService.instance.hangup(deviceId);
      } catch (_) {
        // 可能未连接：忽略
      }
    }
    // 2) 本地聊天历史（存储文件 + 内存）
    await clearHistory(deviceId);
    // 3) 设备行与会话行
    devices.removeWhere((d) => d.id == deviceId);
    conversations.removeWhere((c) => c.device.id == deviceId);
    if (activePeerId == deviceId) {
      activePeerId = null;
      selectedConversation = null;
    }
    if (selectedDevice != null && selectedDevice! >= devices.length) {
      selectedDevice = null;
    }
    await rebuildConversations();
    notifyListeners();
    return ok;
  }

  /// 给对端发一条「我删除了你」的控制消息（尽力而为，失败不影响本机删除）。
  Future<void> _sendRemoveNotice(String peerId) async {
    // 先入队：发送失败时保留在队列里，等对方上线由 connected 事件补发
    _pendingRemoveNotices.add(peerId);
    var ok = false;
    try {
      await ensureDial(peerId);
      await ChatService.instance.sendText(
        peerId: peerId,
        senderId: DiscoveryService.instance.deviceId,
        text: '$kRemoveNotice${DiscoveryService.instance.deviceId}',
      );
      ok = true;
    } catch (_) {
      // 对端不在线：留待补发，不影响本机删除
    }
    if (ok) _pendingRemoveNotices.remove(peerId);
  }

  /// 对端上线后补发积压的删除通知，确保他也解除配对。
  void _flushRemoveNotices(String peerId) {
    if (!_pendingRemoveNotices.contains(peerId)) return;
    unawaited(_sendRemoveNotice(peerId));
  }

  void _upsertContact(rust_pairing.PairedContactDto contact) {
    _removedPeers.remove(contact.deviceId); // 重新配对过就不再屏蔽
    // 盘上也要撤掉（B1 第 2 条）：否则下次冷启动读回旧墓碑，重新配好的
    // 设备永远看不到。
    _saveRemovedPeers();
    pairedContacts = [
      for (final existing in pairedContacts)
        if (existing.deviceId != contact.deviceId) existing,
      contact,
    ];
    _syncDevicesFromContacts();
    for (var i = 0; i < devices.length; i++) {
      if (devices[i].id == contact.deviceId && !devices[i].paired) {
        devices[i] = _copyDevice(devices[i], paired: true);
      }
    }
  }

  LanDevice _copyDevice(LanDevice dev, {required bool paired, bool? online}) =>
      LanDevice(
        id: dev.id,
        name: dev.name,
        ip: dev.ip,
        platform: dev.platform,
        online: online ?? dev.online,
        paired: paired,
        rttMs: dev.rttMs,
        chatPort: dev.chatPort,
      );

  /// 配对成功后的 UI 收尾：标记已配对 + 建会话并打开，然后接上真实会话。
  ///
  /// 不再往界面塞「配对成功」这类假消息 —— 消息列表只反映真实存储内容。
  void _completePairingUi(LanDevice dev) {
    var idx = conversations.indexWhere((c) => c.device.id == dev.id);
    if (idx < 0) {
      conversations.insert(
        0,
        Conversation(device: dev, messages: _historyFor(dev.id)),
      );
      idx = 0;
    }
    for (var i = 0; i < devices.length; i++) {
      if (devices[i].id == dev.id) {
        devices[i] = _copyDevice(devices[i], paired: true);
      }
    }
    openConversation(idx);
    unawaited(ensureDial(dev.id));
    unawaited(loadHistory(dev.id));
    unawaited(rebuildConversations());
    // 任务8：配对成功后自动关闭发现（已经拿到联系人，不必一直扫描耗电）
    unawaited(_autoStopDiscovery());
  }

  String _pairFailureText(rust_pairing.PairFailureDto? failure) {
    switch (failure) {
      case rust_pairing.PairFailureDto.timeout:
        return '配对超时（60s），请重新发起';
      case rust_pairing.PairFailureDto.rejected:
        return '对方拒绝了配对';
      case rust_pairing.PairFailureDto.invalidPin:
        return 'PIN 不合法，请重新发起';
      case rust_pairing.PairFailureDto.busy:
        return '对方正在与另一台设备配对，请稍后再试';
      case rust_pairing.PairFailureDto.cancelled:
        return '已取消配对';
      case null:
        return '配对失败，请重试';
    }
  }

  // ------------------------------------------------------------
  // 真实聊天（T3.4~T3.8）：会话、历史分页、未读、在线状态
  // ------------------------------------------------------------

  /// 页面级返回处理：注册后，安卓返回/手势优先交给当前页面
  /// （文件页有选中先取消、设置页先回总览、聊天页先退出多选…）。
  /// 返回 true = 已消费，Shell 不再继续返回。
  bool Function()? backHandler;

  /// 新消息提醒（顶部横幅）：非当前会话来消息时置位，UI 据此弹横幅。
  String? noticePeerId;
  String? noticeName;
  String? noticeText;

  /// 单调递增：同一会话连来多条也当作新事件，横幅会刷新而不是被忽略。
  int noticeSeq = 0;

  /// 关掉横幅（点了、或用户切走了）。
  void dismissNotice() {
    noticePeerId = null;
    noticeName = null;
    noticeText = null;
    notifyListeners();
  }

  /// 聊天就绪（消息仓库已打开 + 已监听端口 + 已订阅事件）。
  bool chatReady = false;
  String chatError = '';

  /// 从外部（如 Shell 的分享流程）设置错误文案：notifyListeners 是
  /// @protected，外部只能经由这类公开方法触发重建。
  void setChatError(String message) {
    chatError = message;
    notifyListeners();
  }

  /// 错误优先，其次当前会话断连重连中。供 OSD 提示条读取（顶部横幅已删除）。
  String? get connectionBanner {
    if (chatError.isNotEmpty) return chatError;
    final peer = activePeerId;
    if (peer != null &&
        _dialedAt.containsKey(peer) &&
        !(chatOnline[peer] ?? true)) {
      return '与 ${_deviceFor(peer).name} 的连接已断开，正在自动重连…';
    }
    return null;
  }

  /// 关闭状态条的错误文案（重连文案会自行消失）。
  void dismissConnectionBanner() {
    if (chatError.isEmpty) return;
    chatError = '';
    notifyListeners();
  }

  // ------------------------------------------------------------
  // T5.5 首次使用引导
  // ------------------------------------------------------------

  /// 是否需要展示首次使用引导（无标记文件 = 首次）。
  bool onboardingNeeded = false;

  /// 全屏引导是否在显示中（Shell 据此渲染 OnboardingPage）。
  bool onboardingActive = false;

  /// 启动全屏引导。
  void startOnboarding() {
    onboardingActive = true;
    notifyListeners();
  }

  /// 检查标记（启动时调用一次；标记文件在数据目录 .onboarded）。
  Future<void> checkOnboarding() async {
    try {
      final dir = DiscoveryService.instance.dataDir;
      if (dir == null || dir.isEmpty) return;
      final marker = File('$dir${Platform.pathSeparator}.onboarded');
      onboardingNeeded = !marker.existsSync();
    } catch (_) {
      onboardingNeeded = false;
    }
    if (onboardingNeeded) {
      onboardingActive = true;
      notifyListeners();
    }
  }

  /// 用户关闭引导 → 写标记文件，下次不再显示。
  void dismissOnboarding() {
    onboardingNeeded = false;
    onboardingActive = false;
    notifyListeners();
    try {
      final dir = DiscoveryService.instance.dataDir;
      if (dir == null || dir.isEmpty) return;
      File('$dir${Platform.pathSeparator}.onboarded').writeAsStringSync(
        DateTime.now().toIso8601String(),
      );
    } catch (_) {
      // 标记失败不影响主流程
    }
  }

  /// 本机聊天端口（随 HELLO 广播出去；实际监听端口回填到这里）。
  int chatPort = 45998;

  /// 当前会话的 peer_id（会话列表会重排，选中的会话靠它跟随）。
  String? activePeerId;

  StreamSubscription<rust_chat.ChatEventDto>? _chatSub;

  /// peer_id → 消息（升序）；与 Conversation.messages 是**同一个 List 实例**。
  final Map<String, List<ChatMessage>> _history = {};

  /// peer_id → 是否已连上（握手成功 / 断开）。
  final Map<String, bool> chatOnline = {};

  /// peer → 最近一次发起拨号的时间。引擎自带退避重连，冷却期内不需要重复拨；
  /// 冷却过后允许再拨（旧实现是永久 Set，首次拨号失败就再也不会重试）。
  final Map<String, DateTime> _dialedAt = {};

  /// 历史已全部加载完（不再上翻请求）。
  final Set<String> _historyDone = {};

  /// 该 peer 的首屏历史已从存储合并过（避免「非空就早退」丢消息）。
  final Set<String> _historyLoaded = {};

  /// 每页消息条数（PLAN：首屏 50 条）。
  static const int chatPageSize = 50;

  Conversation? get activeConversation {
    final ci = selectedConversation;
    if (ci == null || ci >= conversations.length) return null;
    return conversations[ci];
  }

  List<ChatMessage> _historyFor(String peerId) =>
      _history.putIfAbsent(peerId, () => []);

  /// 按 peer_id 取会话（不存在就建一个空会话，不改选中项）——聊天页用，
  /// 这样会话列表重排/重建后页面也不会拿到过期对象。
  Conversation conversationFor(String peerId) {
    for (final c in conversations) {
      if (c.device.id == peerId) return c;
    }
    final created = Conversation(
      device: _deviceFor(peerId),
      messages: _historyFor(peerId),
    );
    conversations.insert(0, created);
    return created;
  }

  /// 启动聊天链路：打开消息仓库 → 订阅事件流 → 监听端口 → 组装会话列表。
  /// 由 main 在桥接就绪后调用；失败只影响聊天，不影响发现/配对。
  Future<void> enableChat() async {
    if (chatReady) return;
    try {
      await DiscoveryService.instance.prepare();
      await ChatService.instance.openStore(DiscoveryService.instance.dataDir);
      _chatSub ??= ChatService.instance.events().listen(_onChatEvent);
      // 端口可由 LANCHAT_CHAT_PORT 覆盖（同机双实例联调必需）
      chatPort = DiscoveryService.chatPort;
      int port;
      try {
        port = await ChatService.instance.listen(
          deviceId: DiscoveryService.instance.deviceId,
          name: DiscoveryService.instance.deviceName,
          platform: rust_discovery.discoveryPlatform(),
          chatPort: chatPort,
        );
      } catch (listenErr) {
        // 固定端口（默认 45998）被占：右键「通过雨传发送」会拉起第二实例，
        // 撞上已运行实例的端口。退回系统随机端口 —— 本实例仍可主动拨号发送
        //（入站由第一实例承接），否则第二实例聊天永远未就绪、分享也弹不出选择器。
        port = await ChatService.instance.listen(
          deviceId: DiscoveryService.instance.deviceId,
          name: DiscoveryService.instance.deviceName,
          platform: rust_discovery.discoveryPlatform(),
          chatPort: 0,
        );
      }
      chatPort = port;
      chatReady = true;
      chatError = '';
      // 载入传输结果台账：历史里的文件消息据此还原真实进度/路径
      _loadTransferOutcomes();
      _loadAliases();
      _loadAvatars();
      // 接收端也要轮询传输状态：之前只有 sendFilePath 里启动，
      // 收件方永远不建气泡、进度也永远是 0%（文件却仍在落地）
      _startTransferPoll();
      await rebuildConversations();
    } catch (e) {
      chatReady = false;
      chatError = '聊天启动失败：$e';
    }
    notifyListeners();
  }

  /// 由配对表 + 本地历史摘要组装会话列表（选中的会话跟着 activePeerId 走）。
  Future<void> rebuildConversations() async {
    // 桥接未就绪/仓库读失败时不要抛：否则删除联系人等流程会被打断，
    // 界面上就出现「删了还在」的残留
    Map<String, rust_chat.ConversationDto> summaries = {};
    try {
      summaries = {
        for (final s in ChatService.instance.conversations()) s.peerId: s,
      };
    } catch (_) {
      summaries = {};
    }
    final peers = <String>{...pairedContacts.map((c) => c.deviceId)};
    peers.addAll(_history.keys);
    peers.addAll(summaries.keys);
    // 本次会话里删掉的联系人：一律不再重建
    peers.removeWhere(_removedPeers.contains);

    final rebuilt = <Conversation>[];
    for (final peerId in peers) {
      final summary = summaries[peerId];
      rebuilt.add(Conversation(
        device: _deviceFor(peerId),
        messages: _historyFor(peerId),
        unread: summary?.unread ?? 0,
        lastTsMs: summary?.lastTsMs ?? 0,
      ));
    }
    rebuilt.sort((a, b) => b.lastTsMs.compareTo(a.lastTsMs));
    conversations
      ..clear()
      ..addAll(rebuilt);
    final active = activePeerId;
    if (active != null) {
      final idx = conversations.indexWhere((c) => c.device.id == active);
      selectedConversation = idx >= 0 ? idx : null;
    } else if (selectedConversation != null &&
        selectedConversation! >= conversations.length) {
      // 没有 activePeerId 时旧索引无法重映射。若重建后它已越界（首次启动：
      // 构造时「恢复上次会话」留下的种子索引被真实空列表替换），必须清掉 ——
      // 窄屏布局靠 selectedConversation 判断是否处于「深层详情」，留着越界
      // 索引会让应用隐藏底部导航、渲染空内容（安卓端点完引导的空白页）。
      selectedConversation = null;
    }
  }

  /// 取某 peer 的设备信息：优先用发现结果（有实时在线状态），
  /// 其次用配对表（重启后还没发现到也能聊）。
  LanDevice _deviceFor(String peerId) {
    for (final d in devices) {
      if (d.id == peerId) return d;
    }
    for (final c in pairedContacts) {
      if (c.deviceId == peerId) {
        final addr = c.addrHistory.isNotEmpty ? c.addrHistory.first : '';
        final parts = addr.split(':');
        return LanDevice(
          id: c.deviceId,
          name: c.name,
          ip: parts.isNotEmpty ? parts.first : '',
          platform: c.platform == 'android'
              ? DevicePlatform.android
              : DevicePlatform.windows,
          online: chatOnline[c.deviceId] ?? false,
          paired: true,
          chatPort: parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0,
        );
      }
    }
    return LanDevice(
      id: peerId,
      // 名字别直接用原始 id（长串字符在界面上像乱码）
      name: peerId.length > 8
          ? '未知设备·${peerId.substring(0, 4)}'
          : '未知设备·$peerId',
      ip: '',
      platform: DevicePlatform.windows,
      online: chatOnline[peerId] ?? false,
      paired: true,
    );
  }

  /// 拨号冷却：`_dialed` 曾经是「拨过就永不再拨」的永久闸门，导致首次拨号失败
  /// （或当时没有 IP）之后**再也不会重拨**，对端永远等不到 Connected 事件，
  /// 离线补发也就永远不会触发（根因1）。改成带冷却的集合：冷却期内不重复拨，
  /// 冷却过后允许再试。`_dialed.contains` 的调用点语义保持「正在拨/刚拨过」。
  static const Duration _dialCooldown = Duration(seconds: 5);

  /// 纯函数，便于直接对冷却逻辑写单测。
  static bool isDialCoolingDown(DateTime lastAt, DateTime now) =>
      now.difference(lastAt) < _dialCooldown;

  bool _dialCoolingDown(String peerId) {
    final lastAt = _dialedAt[peerId];
    if (lastAt == null) return false;
    return isDialCoolingDown(lastAt, DateTime.now());
  }

  /// 确保与该对端有一条会话（引擎内部做指数退避重连）。
  Future<void> ensureDial(String peerId) async {
    if (!chatReady || _dialCoolingDown(peerId)) return;
    // **已经连着就绝不重拨** —— 这是「一发消息就 OSD 提示对方断开」的根因。
    //
    // Rust 侧的 `chat_dial`（api/chat.rs）会**无条件**拆掉该 peer 的现有连接
    // 再换成新的：
    //     if let Some(mut old) = map.remove(&peer_id) { old.stop(); }
    //     map.insert(peer_id, dialer);
    // 而 sendMessage / sendFilePath 在**已经在线时也会先 `await ensureDial`**
    // （本意是「没连上就先拨号」）。于是每发一条消息（过了 5s 冷却就）重拨一次：
    // 真断开事件 → chatOnline=false → connectionBanner 返回
    // 「与 X 的连接已断开，正在自动重连…」→ main.dart 推成 OSD。
    // 用户看到的就是「聊天窗内双方对着发消息，一发就提示对方断开」。
    //
    // 这里按契约收口：本函数只负责「**没有**连接时把它建起来」。已经在线说明
    // Rust 那边有活连接，重拨只会亲手把它拆掉。
    // 对端换 IP / 连接真断时 chatOnline 会被真事件清成 false，
    // 下一次调用自然又会走到下面的拨号逻辑，不会因此失去重连能力。
    // 只有 Rust 明确说「有活连接」时才不拨。
    //
    // 这里必须用 _effectivelyOnline 而不是 _isOnline：内存里的在线标记会过期
    // （安卓被冻结时漏掉 disconnected 事件），若只按它判断就会**死锁** ——
    // 标记是过期的 true ⇒ 不拨号；而 _effectivelyOnline 说没连接 ⇒ 进发件箱
    // 排队。两端互相否决，文件永远发不出去（用户反馈「根本就没发送过来」）。
    if (_effectivelyOnline(peerId)) return;
    final device = _deviceFor(peerId);
    // 没有地址：等发现结果或手动直连。这里必须清掉冷却记录，
    // 否则冷却窗口内拿到地址也不会重拨。
    if (device.ip.isEmpty) {
      _dialedAt.remove(peerId);
      return;
    }
    final port = device.chatPort == 0 ? chatPort : device.chatPort;
    _dialedAt[peerId] = DateTime.now();
    try {
      await ChatService.instance.dial(
        deviceId: DiscoveryService.instance.deviceId,
        name: DiscoveryService.instance.deviceName,
        platform: rust_discovery.discoveryPlatform(),
        peerId: peerId,
        target: '${device.ip}:$port',
      );
    } catch (e) {
      _dialedAt.remove(peerId);
      chatError = '连接失败：$e';
    }
  }

  /// 连上对端后的自动同步（任务19）：
  /// 1) 重新拉一次本地历史（离线期间本机存的消息补齐显示）
  /// 2) 出站中断/失败且原文件还在 → 重发；Rust 侧按 .part 指纹自动续传，
  ///    无法续传（指纹对不上）就从头重发
  /// 已经自动补发过的文件（peer|文件名|大小）：每个只补一次，
  /// 否则 connected 事件反复触发会把同一个文件重复发给对端（用户反馈的
  /// 「一端发送文件，另一端自动重复收到」就是这么来的）。
  final Set<String> _resyncedFiles = {};

  Future<void> _syncAfterConnect(String peerId) async {
    // ① 重启该 peer 所有未完成的发送。
    //
    // 断线时 Rust 侧的 Sender 任务还留在 hub 里，但没有 ACK 就永远停住 ——
    // 之前没有任何东西会在重连后重新驱动它（用户反馈的「安卓后台中断后
    // 无法继续」）。重启会重发 FILE_META 并从已确认点续传，对端的首个
    // ACK 会带回它自己的续传点。
    try {
      await TransferService.instance.reconnect(peerId);
    } catch (_) {
      // 该 peer 没有未完成的发送时是空操作
    }

    try {
      // 强制刷新：对端离线期间双方各自产生的消息都要补齐
      await loadHistory(peerId, force: true);
    } catch (_) {
      // 历史失败不影响补发
    }
    final conv = conversations.where((c) => c.device.id == peerId).firstOrNull;
    if (conv == null) return;

    // ① 离线排队的文本：**不再在这里发**。
    //
    // 发件箱（Rust outbox.jsonl）现在是唯一真相来源，由 flushOutbox() 独占
    // 消费并 ack。以前这条路径自己发一遍、但从不 ack 发件箱，于是同一句话
    // 会被 flushOutbox 再发一次（对端收到两条）——「一端发送另一端自动重复
    // 收到」正是这么来的。这里只把内存里的排队气泡转交给 flushOutbox 处理。
    unawaited(flushOutbox());

    // ② 只补「显式发送失败」且原文件还在的：进行中的不要碰（可能正在传），
    // 用户取消的不要复活，历史里 progress=0 的已发文件也不算中断
    final interrupted = conv.messages
        .where((m) =>
            m.fromMe &&
            m.kind != MessageKind.text &&
            (m.failed || m.queued) &&
            !m.cancelled &&
            m.filePath.isNotEmpty &&
            File(m.filePath).existsSync() &&
            !_transferMsgs.containsKey(m.fileId))
        .toList();
    for (final m in interrupted) {
      final key = '$peerId|${m.fileName}|${m.fileSize}';
      if (!_resyncedFiles.add(key)) continue;
      // 已经在持久发件箱里的，交给 flushOutbox（它持有 ack 权限），
      // 否则同一文件会被两条路径各发一次。
      if (_outboxHasFileFor(peerId, m.fileName, m.fileSize)) continue;
      final path = m.filePath;
      final kind = m.kind;
      m.queued = false;
      conv.messages.remove(m);
      notifyListeners();
      try {
        await sendFilePath(path, kind: kind, peerId: peerId);
      } catch (_) {
        _resyncedFiles.remove(key); // 失败允许下次再试
      }
    }
  }

  /// 发件箱里是否已有这个文件的待发条目（按 peer + 文件名 + 大小判定）。
  bool _outboxHasFileFor(String peerId, String fileName, int fileSize) {
    try {
      return ChatService.instance.outboxPending(peerId).any((it) =>
          it.kind != 1 && it.fileName == fileName && it.fileSize == fileSize);
    } catch (_) {
      // 桥接不可用时无法确认发件箱是否已有该文件：按「有」处理（审查 M2），
      // 宁可少补发一轮也别双发 —— flushOutbox 周期扫描很快会再补。
      return true;
    }
  }

  /// 清掉本机气泡上的「排队中」标记（发件箱补发成功接管后调用，审查 I4）。
  void _clearQueuedBubble(String peerId, String fileName, int fileSize) {
    for (final conv in conversations) {
      if (conv.device.id != peerId) continue;
      var changed = false;
      for (final m in conv.messages) {
        if (m.fromMe &&
            m.kind != MessageKind.text &&
            m.queued &&
            m.fileName == fileName &&
            m.fileSize == fileSize) {
          m.queued = false;
          changed = true;
        }
      }
      if (changed) notifyListeners();
      return;
    }
  }

  /// 标已读（演示模式/测试下桥接不可用，绝不能把异常抛到全局）。
  void _markReadQuietly(String peerId) {
    try {
      unawaited(ChatService.instance
          .markRead(peerId, DateTime.now().millisecondsSinceEpoch)
          .catchError((_) => 0));
    } catch (_) {
      // 同步抛出（RustLib 未初始化）也要吞掉
    }
  }

  /// 发件箱条目是否被「**同一文件**正在传输」挡住（B1-5 补发阻塞）。
  ///
  /// 为什么必须是「同一文件」：原实现只问「该 peer 有没有在传的东西」，
  /// 于是该 peer 有**别的**文件卡在传输中（典型成因：手机切后台 → 心跳冻结
  /// → 这个 sender 拿不到 ACK 永远停在 progress<1）时，队列里其他文件
  /// 会被无限期跳过 —— 用户看到的就是「手机返回桌面一会，PC 就发送失败；
  /// 手机连上也没有发送」。
  ///
  /// 抽成纯函数便于直接钉住（同 `responderRoleAfter` 的做法）。
  @visibleForTesting
  static bool outboxItemBlockedByInFlight({
    required String peerId,
    required String itemFileName,
    required int itemFileSize,
    required String itemFilePath,
    required Iterable<
            ({
              String peerId,
              String fileName,
              int fileSize,
              String filePath,
              bool failed,
              double progress,
            })>
        inFlight,
  }) {
    for (final t in inFlight) {
      if (t.peerId != peerId) continue;
      if (t.failed || t.progress >= 1) continue; // 只认「未完成」的
      // 路径优先：同一文件最可靠的判据。两边都有路径时按路径比，
      // 不再退化成名字+大小（同名同大小的不同文件会被误认为同一个）。
      if (itemFilePath.isNotEmpty && t.filePath.isNotEmpty) {
        if (t.filePath == itemFilePath) return true;
        continue;
      }
      if (t.fileName == itemFileName && t.fileSize == itemFileSize) return true;
    }
    return false;
  }

  /// 补发持久发件箱里排队的消息（任务20 的核心修复）。
  ///
  /// 为什么要有它：离线时 Dart 侧只在内存气泡上打了 `queued` 标记，进程一被
  /// 系统回收（安卓后台必发生）就全丢了；而补发的唯一触发点是 Rust 的
  /// Connected 事件，首次拨号失败后 `_dialed` 又会永久挡住重拨，于是
  /// 「对端上线自动接收」永远不会发生。
  ///
  /// 现在发件箱存在 Rust 侧（outbox.jsonl），这里做两件事：
  /// - 由 [flushOutbox] 周期性扫描（不依赖 Connected 事件）触发补发；
  /// - 每条补发成功后 ack 掉，做到「至少一次投递 + 对端按内容哈希去重」。
  ///
  /// 正在传输中的 peer 跳过，交给 transfer 自己的续传逻辑，避免同一文件
  /// 两条路径同时发造成重复。
  Future<void> flushOutbox() async {
    if (!chatReady) return;
    final List<rust_chat.OutboxItemDto> items;
    try {
      items = ChatService.instance.outboxPending();
    } catch (_) {
      return; // 桥接不可用：静默跳过
    }
    if (items.isEmpty) {
      _outboxPending = 0;
      unawaited(_updateKeepAlive());
      return;
    }
    _outboxPending = items.length;

    for (final item in items) {
      final peerId = item.peerId;
      if (peerId.isEmpty) continue;
      // 该 peer 的**同一文件**正在传：交给 Rust 的续传逻辑，别抢。
      //
      // 判定必须是「同一文件」而不是「同 peer 有东西在传」：原实现只要该 peer
      // 有任何未完成的传输就跳过**所有**文件条目，于是那个卡住的 sender
      // （拿到 ACK 之前永远 progress<1）会把队列里其他文件无限期挡住 ——
      // 用户看到的就是「手机返回桌面一会，PC 就发送失败；手机连上也没有发送」。
      // 决定逻辑抽成纯函数 [outboxItemBlockedByInFlight]，便于直接钉住。
      final blocked = outboxItemBlockedByInFlight(
        peerId: peerId,
        itemFileName: item.fileName,
        itemFileSize: item.fileSize.toInt(),
        itemFilePath: item.filePath,
        inFlight: [
          for (final m in _transferMsgs.values)
            if (m.fromMe && m.fileId.isNotEmpty)
              (
                peerId: msgPeerId(m),
                fileName: m.fileName,
                fileSize: m.fileSize,
                filePath: m.filePath,
                failed: m.failed,
                progress: m.progress,
              ),
        ],
      );
      if (blocked && item.kind != 1) continue;
      try {
        if (item.kind == 1) {
          // C1：sendTextTo 自己吞异常返回 null，只有真的拿到落库消息才算送达；
          // 无条件 ack 会把没发出去的条目删掉（对端上线后永不补发）。
          final saved = await sendTextTo(peerId, item.text, addBubble: false);
          if (saved != null) ChatService.instance.outboxAck(item.id);
        } else {
          final path = item.filePath;
          // 源文件被删/移走：明确告知用户，不能静默卡在「排队中」（审查点4）
          if (path.isEmpty || !File(path).existsSync()) {
            chatError = '离线文件已找不到，无法补发：${item.fileName}';
            ChatService.instance.outboxCancel(item.id);
            notifyListeners();
            continue;
          }
          final started = await sendFilePath(
            path,
            kind: item.kind == 2 ? MessageKind.image : MessageKind.file,
            peerId: peerId,
            fileNameOverride: item.fileName,
          );
          // **只有真的交给 Rust 传输引擎了才 ack。**
          //
          // 旧实现无条件 ack，注释里还写着「该路径只有在线时才会走到这里」——
          // 那是错的：本函数不检查在线，`sendFilePath` 离线时会走「重新排队」
          // 分支后正常返回，条目却被 ack 删掉了；而离线分支的重新入队是
          // `unawaited` 的，与 ack 竞态 —— ack 后落地就把文件从发件箱**彻底
          // 抹掉**，之后永远不会再补发（用户反馈「根本就没发送过来」）。
          //
          // 没真的发出去就**保持 pending**，下一轮（400ms 后）继续试；
          // 气泡也保持「离线待发」，不调 _clearQueuedBubble。
          if (started) {
            ChatService.instance.outboxAck(item.id);
            // 补发已成功接管：清掉本机气泡的「排队中」，不然永远停在排队态
            // （审查 I4）。找不到对应气泡就算了（历史消息可能还没加载）。
            _clearQueuedBubble(peerId, item.fileName, item.fileSize);
          }
        }
      } catch (_) {
        // 失败保持 pending，下一轮再试（至少一次投递）
      }
    }
    unawaited(_updateKeepAlive());
  }

  /// 拉历史：首屏 50 条 / 上翻更早（keyset 分页）。
  Future<void> loadHistory(String peerId, {bool older = false, bool force = false}) async {
    if (!chatReady) return;
    final list = _historyFor(peerId);
    // 「非空就早退」会让先到的在线消息挡住存储里的历史 —— 用户看到的
    // 就是「很多消息没显示」。改成按 peer 记「首屏拉过没有」，拉到后与
    // 内存里的乐观消息按 id 合并去重。
    // force：连上对方/进入会话时强制再拉一次最新页，保证「收到的一切都显示」
    if (!older && _historyLoaded.contains(peerId) && !force) return;
    if (older && _historyDone.contains(peerId)) return;
    final before = older && list.isNotEmpty
        ? list.first.time.millisecondsSinceEpoch
        : ChatService.pageStart;
    try {
      final page = ChatService.instance
          .page(peerId, limit: chatPageSize, beforeTsMs: before);
      if (older && page.isEmpty) {
        _historyDone.add(peerId);
      } else if (page.isNotEmpty) {
        // 控制消息（删除通知等）与本机已删/已取消的消息不参与显示
        final loaded = page
            .where((m) =>
                !isControlText(m.text) && !_removedMsgIds.contains(m.id))
            .map(_toChatMessage)
            .toList();
        final existing = {for (final m in list) m.id};
        if (older) {
          list.insertAll(0, loaded.where((m) => !existing.contains(m.id)));
        } else {
          // 首屏：存储里的历史 + 内存里已有的（乐观上屏/先到的事件）合并
          for (final m in loaded) {
            if (existing.contains(m.id)) {
              final idx = list.indexWhere((x) => x.id == m.id);
              if (idx < 0) continue;
              final old = list[idx];
              // 正在传输中的气泡**绝不能**被存储副本替换：
              // _toChatMessage 不还原 fileId，一替换就断开与 _transferMsgs
              // 的绑定，进度从此更新到脱离列表的旧对象上 → UI 永远 0%
              // （而 Rust 侧文件早已传完，就是用户反馈的那个现象）。
              if (old.fileId.isNotEmpty &&
                  old.progress < 1 &&
                  _transferMsgs.containsKey(old.fileId)) {
                continue;
              }
              // 其余情况存储是权威的：替换以带上真实 seq/state
              list[idx] = m;
            } else {
              list.add(m);
            }
          }
          list.sort((a, b) => a.time.compareTo(b.time));
          _historyLoaded.add(peerId);
          // B1-5：从存储重建的气泡 `queued` 恒为 false（存储里没这个字段），
          // 而发件箱才是「还有没有待发」的唯一真相源 —— 不在这里对账，
          // 补发时就认不出旧气泡，每轮新建一个 → 用户看到的「N 个发送气泡」。
          _reconcileQueuedFromOutbox(peerId);
        }
        if (loaded.length < chatPageSize) _historyDone.add(peerId);
      } else {
        _historyLoaded.add(peerId);
      }
    } catch (e) {
      chatError = '历史加载失败：$e';
    }
    notifyListeners();
  }

  /// 清空与某对端的本地聊天记录（存储 + 内存）。
  Future<void> clearHistory(String peerId) async {
    try {
      await ChatService.instance.clear(peerId);
    } catch (e) {
      chatError = '清空记录失败：$e';
    }
    // 必须删 key 而不是清空列表：rebuildConversations 按 _history.keys 组装，
    // 留着空 key 会把刚删掉的会话又建回来（用户反馈的「删除后残留」）
    _history.remove(peerId);
    _historyDone.remove(peerId);
    _historyLoaded.remove(peerId);
    _resyncedFiles.removeWhere((k) => k.startsWith('$peerId|'));
    await rebuildConversations();
    notifyListeners();
  }

  /// 收到对端**真实数据**（聊天消息）时的处理。
  ///
  /// 在线判定已不再依赖「最近收到数据的时间」（那条路已删除，见 [_isOnline]），
  /// 所以这里只做一件有价值的事：如果该 peer 因为漏掉事件等原因被标成离线，
  /// 就用这条真实数据把它纠正回在线，并驱动一次恢复同步。
  ///
  /// 为什么恢复同步不能只等 `connected` 事件：Rust 侧静默只发 `Stalled`、
  /// **不断开 socket**，所以连接可能从未关闭 —— Dart 就永远等不到新的 `connected`，
  /// 卡住的 sender 不会被 resume、发件箱也不会补发。用真实数据当"对端回来了"
  /// 的信号是最可靠的（它确实来自对端）。
  void _touchPeerRx(String peerId) {
    if (chatOnline[peerId] ?? false) return;
    _setOnline(peerId, true);
    unawaited(_syncAfterConnect(peerId));
  }

  void _onChatEvent(rust_chat.ChatEventDto event) {
    switch (event.kind) {
      case rust_chat.ChatEventKindDto.connected:
        final peer = event.peerId;
        if (peer != null) {
          _setOnline(peer, true);
          // 任务19：连上后自动同步本地历史 + 续传中断的出站文件
          unawaited(_syncAfterConnect(peer));
          // 对方上线：补发之前没送到的删除通知（对方据此解除他的配对）
          _flushRemoveNotices(peer);
        }
      case rust_chat.ChatEventKindDto.disconnected:
        final peer = event.peerId;
        // B1-4：按 reason 区分「真事件断开」与「纯静默」。
        // 真事件（eof/io/protocol/bye）才判离线；纯静默（timeout）只是递减，
        // 由 _onPeerDisconnected 内部处理（用户口径：静默不是关键事件）。
        if (peer != null) _onPeerDisconnected(peer, event.reason);
      case rust_chat.ChatEventKindDto.message:
        final dto = event.message;
        final peer = dto?.peerId ?? event.peerId;
        if (dto == null || peer == null) return;
        _touchPeerRx(peer);
        _onIncoming(peer, dto);
      case rust_chat.ChatEventKindDto.sent:
        break; // 本地发送路径已处理
      case rust_chat.ChatEventKindDto.pairRequest:
        final peer = event.peerId;
        final pin = event.pin;
        if (peer == null || pin == null) return;
        // 我方**正在向该设备发起**配对时，回流的 PAIR_REQ 直接忽略 ——
        // 否则申请端会弹出「对方请求配对」的审核窗（用户反馈的反向申请）
        if (pairingActive && pairingIsInitiator && pairingPeerId == peer) {
          return;
        }
        // 有人请求配对：弹出操作窗口（双端都要有，任务13）
        _focusDeviceForPairing(peer);
        final dev = _deviceFor(peer);
        unawaited(beginResponderPairing(
          peerId: peer,
          peerName: dev.name,
          platform: dev.platform == DevicePlatform.android
              ? 'android'
              : 'windows',
          pin: pin,
          addr: dev.ip,
        ));
      case rust_chat.ChatEventKindDto.pairResponse:
        unawaited(_onPairResponse(event.accepted ?? false));
    }
    notifyListeners();
  }

  /// 把设备补进列表（配对弹窗靠 pairingPeerId 取名字，不再强制跳转）。
  ///
  /// 之前这里会强行 `navIndex = 1`：弹窗刚出来就整页切换，
  /// 安卓上和路由动画撞在一起，表现为配对后界面卡死。
  void _focusDeviceForPairing(String peerId) {
    if (devices.any((d) => d.id == peerId)) return;
    devices.add(_deviceFor(peerId));
  }

  /// 发起方收到 PAIR_RESP：成功则写联系人并进入会话。
  Future<void> _onPairResponse(bool accepted) async {
    try {
      final outcome = await PairingService.instance.responseReceived(accepted);
      if (outcome.session.state == rust_pairing.PairStateDto.failed) {
        pairingError = _pairFailureText(outcome.session.failure);
      }
      final contact = outcome.contact;
      if (contact != null) _upsertContact(contact);
      if (outcome.session.state == rust_pairing.PairStateDto.paired) {
        // 发起方也走 ✓ 动画 → 进会话（T5.2）。
        // 对端 id 一定要兜住（session.peerId / contact / 本轮发起对象），
        // 否则 pairingSucceeded 永远为 false，而 pairingActive 还是 true ——
        // 弹窗就一直停在「等待对方确认」上（用户反馈的卡在配对界面）。
        pairingCompletePeer =
            outcome.session.peerId ?? contact?.deviceId ?? pairingPeerId;
        pairingPin = null;
        pairingRole = null;
        pairingPeerId = null;
        if (pairingCompletePeer != null) {
          pairingSucceeded = true;
        } else {
          pairingError = '配对完成，但未能识别对端设备，请重新发起';
        }
      }
    } catch (e) {
      pairingError = '配对失败：$e';
    }
    notifyListeners();
  }

  void _onIncoming(String peerId, rust_chat.MessageDto dto) {
    // 对方删除了本机：同步解除配对并清掉相关数据（不入库、不显示）
    if (isControlText(dto.text)) {
      if (dto.text.startsWith(kRemoveNotice)) {
        unawaited(removeContact(peerId, notify: false));
      }
      return;
    }
    // 只接受**已配对**联系人的消息：否则任何陌生设备都能往你这儿塞内容，
    // 而未知设备在界面上的名字就是原始 id（看起来像乱码）
    if (!isPaired(peerId)) return;
    // 本机已删/已取消的消息不再回流
    if (_removedMsgIds.contains(dto.id)) return;

    final list = _historyFor(peerId);
    if (list.any((m) => m.id == dto.id)) return; // 幂等（重连重放）
    list.add(_toChatMessage(dto));
    list.sort((a, b) => a.time.compareTo(b.time));

    var matches = conversations.where((c) => c.device.id == peerId).toList();
    if (matches.isEmpty) {
      // 对方先发消息：补一个会话放到最前
      final created = Conversation(
        device: _deviceFor(peerId),
        messages: list,
        lastTsMs: dto.tsMs,
      );
      conversations.insert(0, created);
      if (selectedConversation != null) {
        selectedConversation = selectedConversation! + 1;
      }
      matches = [created];
    }
    final target = matches.first;
    target.lastTsMs = dto.tsMs;
    final active = navIndex == 0 && activePeerId == peerId;
    if (active) {
      try {
        unawaited(ChatService.instance.markRead(peerId, dto.tsMs));
      } catch (_) {
        // 桥接未就绪（演示模式/测试）：忽略
      }
      target.unread = 0;
    } else {
      target.unread += 1;
      // 不在会话里 → 顶部横幅提醒（任务：做好消息提醒的 UI 响应）
      _pushNotice(peerId, _noticePreview(dto));
    }
  }

  /// 横幅里显示的一句话摘要。
  String _noticePreview(rust_chat.MessageDto dto) {
    switch (dto.kind) {
      case 2:
        return '[图片] ${dto.fileName}';
      case 3:
        return '[文件] ${dto.fileName}';
      default:
        return dto.text;
    }
  }

  void _pushNotice(String peerId, String text) {
    noticePeerId = peerId;
    noticeName = _deviceFor(peerId).name;
    noticeText = text;
    noticeSeq++;
  }

  void _setOnline(String peerId, bool online) {
    final before = chatOnline[peerId];
    chatOnline[peerId] = online;
    for (var i = 0; i < devices.length; i++) {
      if (devices[i].id == peerId && devices[i].online != online) {
        devices[i] =
            _copyDevice(devices[i], paired: devices[i].paired, online: online);
      }
    }
    for (var i = 0; i < conversations.length; i++) {
      final c = conversations[i];
      if (c.device.id == peerId && c.device.online != online) {
        conversations[i] = Conversation(
          device: _copyDevice(c.device, paired: c.device.paired, online: online),
          messages: c.messages,
          unread: c.unread,
          draft: c.draft,
          lastTsMs: c.lastTsMs,
        );
      }
    }
    // 在线集合变了 = 保活判定的第三条变了（B1-4）：有一条会话在线就必须挂
    // 前台服务，否则切后台会被系统冻结、心跳停发、对端判离线。
    if (before != online) unawaited(_updateKeepAlive());
  }

  // ───────────────── B1-4 在线判定（只跟随 Rust 的连接事实） ─────────────────

  /// 供测试复位在线表（单例跨用例会互相污染）。
  @visibleForTesting
  void debugClearPresenceForTest() {
    chatOnline.clear();
  }

  /// 静默断开（非关键事件）的 reason 白名单。
  ///
  /// 与 Rust 侧 `SessionEvent::Disconnected { reason }` 一一对应；Rust 侧已改为
  /// **不再**因静默产出 disconnected（见 `session.rs` 超时分支的说明），这里
  /// 是第二道防线，防止老版本 dll / 未来的静默来源把对端误判死。
  static bool _isSilentDisconnect(String? reason) {
    if (reason == null || reason.isEmpty) return false;
    return reason == 'timeout';
  }

  void _onPeerDisconnected(String peerId, String? reason) {
    // 纯静默**不是**关键事件：不动在线标记（用户口径「不需要判得那么死，
    // 间隔问候就行」）。真正的断开只由 eof/io/protocol/bye 这类真事件判定。
    if (_isSilentDisconnect(reason)) return;
    _setOnline(peerId, false);
  }

  /// 传输结果台账：fileId → {failed, path, ts}（持久化到数据目录）。
  ///
  /// 存储层只记「发起过这条文件消息」，不记它最终成没成；而 Rust 的
  /// transfer_status() 只保留最近 32 条。两者都拿不到结果时，历史里的
  /// 文件消息读回来 progress 就是 0 —— 界面退回 0%（用户反馈的
  /// 「刷新后又回到 0%」）。这里在 Dart 侧把结果落盘，读历史时据此还原。
  final Map<String, Map<String, dynamic>> _transferOutcomes = {};

  /// 台账上限：只保留最近若干条，避免无限增长。
  static const int _maxTransferOutcomes = 400;

  void _recordTransferOutcome(String fileId,
      {required bool failed, String path = ''}) {
    if (fileId.isEmpty) return;
    _transferOutcomes[fileId] = {
      'failed': failed,
      'path': path,
      'ts': DateTime.now().millisecondsSinceEpoch,
    };
    if (_transferOutcomes.length > _maxTransferOutcomes) {
      final keys = _transferOutcomes.keys.toList()
        ..sort((a, b) {
          final ta = (_transferOutcomes[a]?['ts'] ?? 0) as int;
          final tb = (_transferOutcomes[b]?['ts'] ?? 0) as int;
          return ta.compareTo(tb);
        });
      final drop = keys.take(_transferOutcomes.length - _maxTransferOutcomes);
      for (final k in drop) {
        _transferOutcomes.remove(k);
      }
    }
    _saveTransferOutcomes();
  }

  File? get _transferOutcomesFile {
    final dir = DiscoveryService.instance.dataDir;
    if (dir == null || dir.isEmpty) return null;
    return File('$dir${Platform.pathSeparator}transfer_outcomes.json');
  }

  void _saveTransferOutcomes() {
    try {
      final f = _transferOutcomesFile;
      if (f == null) return;
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode(_transferOutcomes));
    } catch (_) {
      // 台账只用于还原显示，写失败不影响收发
    }
  }

  void _loadTransferOutcomes() {
    try {
      final f = _transferOutcomesFile;
      if (f == null || !f.existsSync()) return;
      final map = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      _transferOutcomes
        ..clear()
        ..addAll(map.map(
            (k, v) => MapEntry(k, Map<String, dynamic>.from(v as Map))));
    } catch (_) {
      // 台账损坏：清空重来，不影响收发
      _transferOutcomes.clear();
    }
  }

  /// 联系人备注名：peerId → alias（空串表示清掉备注、回到设备原名）。
  final Map<String, String> _aliases = {};

  File? get _aliasesFile {
    final dir = DiscoveryService.instance.dataDir;
    if (dir == null || dir.isEmpty) return null;
    return File('$dir${Platform.pathSeparator}contact_aliases.json');
  }

  void _loadAliases() {
    try {
      final f = _aliasesFile;
      if (f == null || !f.existsSync()) return;
      final map = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      _aliases
        ..clear()
        ..addAll(map.map((k, v) => MapEntry(k, v?.toString() ?? '')));
    } catch (_) {
      _aliases.clear();
    }
    _applyAliases();
  }

  void _saveAliases() {
    try {
      final f = _aliasesFile;
      if (f == null) return;
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode(_aliases));
    } catch (_) {
      // 备注只影响显示，写失败不影响功能
    }
  }

  /// 把备注刷进当前已知的设备对象（设备对象每次发现都会重建）。
  void _applyAliases() {
    for (final c in conversations) {
      final a = _aliases[c.device.id];
      if (a != null) c.device.alias = a;
    }
  }

  /// 给联系人改备注名；传空串 = 清掉备注、回到设备原名。
  void renameContact(String peerId, String alias) {
    final trimmed = alias.trim();
    if (trimmed.isEmpty) {
      _aliases.remove(peerId);
    } else {
      _aliases[peerId] = trimmed;
    }
    for (final c in conversations) {
      if (c.device.id == peerId) c.device.alias = trimmed;
    }
    _saveAliases();
    notifyListeners();
  }

  /// 当前联系人的备注名（未设置返回空串）。
  String contactAlias(String peerId) => _aliases[peerId] ?? '';
  /// 联系人自定义头像：peerId → 本地图片路径。
  final Map<String, String> _avatars = {};

  File? get _avatarsFile {
    final dir = DiscoveryService.instance.dataDir;
    if (dir == null || dir.isEmpty) return null;
    return File('$dir${Platform.pathSeparator}contact_avatars.json');
  }

  void _loadAvatars() {
    try {
      final f = _avatarsFile;
      if (f == null || !f.existsSync()) return;
      final map = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      _avatars
        ..clear()
        ..addAll(map.map((k, v) => MapEntry(k, v?.toString() ?? '')));
    } catch (_) {
      _avatars.clear();
    }
  }

  void _saveAvatars() {
    try {
      final f = _avatarsFile;
      if (f == null) return;
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode(_avatars));
    } catch (_) {
      // 头像只影响显示，写失败不影响功能
    }
  }

  /// 设置/清除联系人头像；传空串 = 恢复默认（按平台的设备图标）。
  void setContactAvatar(String peerId, String path) {
    if (path.isEmpty) {
      _avatars.remove(peerId);
    } else {
      _avatars[peerId] = path;
    }
    _saveAvatars();
    notifyListeners();
  }

  /// 联系人头像路径；空串 = 用默认设备图标。
  String contactAvatar(String peerId) => _avatars[peerId] ?? '';

  // ------------------------------------------------------------
  // 其他应用「分享」进来的内容（安卓）
  // ------------------------------------------------------------

  /// 待处理的分享：非空即触发「选联系人发送」流程。
  String pendingShareText = '';
  final List<String> pendingShareFiles = [];
  int _shareSeq = 0;

  /// 取走系统分享进来的文字/文件，登记为待发送。
  ///
  /// 返回 true 表示确实收到了内容（UI 据此弹联系人选择）。
  Future<bool> consumeShared() async {
    final shared = await YuChuanPlatform.takeShared();
    if (shared.text.isEmpty && shared.files.isEmpty) return false;
    pendingShareText = shared.text;
    pendingShareFiles
      ..clear()
      ..addAll(shared.files);
    _shareSeq++;
    notifyListeners();
    return true;
  }

  /// 把待处理的分享发给指定联系人，并清空待处理状态。
  Future<void> sendPendingShare(String peerId) async {
    final text = pendingShareText;
    final files = List<String>.from(pendingShareFiles);
    pendingShareText = '';
    pendingShareFiles.clear();
    if (text.isNotEmpty) {
      await sendTextTo(peerId, text);
    }
    for (final f in files) {
      final lower = f.toLowerCase();
      final kind = const ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp']
              .any(lower.endsWith)
          ? MessageKind.image
          : MessageKind.file;
      await sendFilePath(f, kind: kind, peerId: peerId);
    }
    notifyListeners();
  }

  /// 丢弃待处理的分享。
  void dismissPendingShare() {
    pendingShareText = '';
    pendingShareFiles.clear();
    notifyListeners();
  }

  /// 单实例交接：另一进程（右键菜单拉起）把文件清单递进来，登记为
  /// 待发送；UI 侧（main.dart 的 _onState 监听 shareSeq）会走与系统
  /// 分享完全相同的「选联系人」流程。
  void injectShared(List<String> files) {
    if (files.isEmpty) return;
    pendingShareText = '';
    pendingShareFiles
      ..clear()
      ..addAll(files);
    _shareSeq++;
    notifyListeners();
  }

  /// 从启动参数里取「通过雨传发送」的文件（Windows 资源管理器右键）。
  ///
  /// 右键菜单会用 `雨传.exe <文件路径...>` 启动；runner 把用户参数经
  /// set_dart_entrypoint_arguments 投递到 main(args)，main 存进
  /// [launchArgs]。注意：Platform.executableArguments 只有 VM 标志位、
  /// 永远读不到文件参数（本项目右键功能曾因此整体失效，勿回退）。
  /// 复用待处理分享的状态，UI 侧逻辑与安卓分享完全一致。
  static List<String> launchArgs = const [];

  bool _launchArgsConsumed = false;

  bool consumeLaunchArgs() {
    // 每进程只消费一次：桌面端窗口重新聚焦也会派发 resumed，
    // 不加闸会反复把同一批启动参数当成新分享（重复弹窗/重复发送）
    if (_launchArgsConsumed) return false;
    List<String> args;
    try {
      args = List<String>.from(launchArgs);
    } catch (_) {
      return false;
    }
    final files = args
        .where((a) => !a.startsWith('-') && File(a).existsSync())
        .toList();
    if (files.isEmpty) return false;
    _launchArgsConsumed = true;
    pendingShareText = '';
    pendingShareFiles
      ..clear()
      ..addAll(files);
    _shareSeq++;
    notifyListeners();
    return true;
  }
  /// 分享序号：UI 用它判断「有一份新分享要处理」（避免重复弹）。
  int get shareSeq => _shareSeq;
  ChatMessage _toChatMessage(rust_chat.MessageDto dto) {
    final kind = switch (dto.kind) {
      2 => MessageKind.image,
      3 => MessageKind.file,
      _ => MessageKind.text,
    };
    final isFile = kind != MessageKind.text;

    // 文件/图片消息：还原 fileId、进度、本地路径。
    //
    // 落库时用的 msgId 就是 'file-<fileId>'，所以能直接反解；再用台账/
    // 收件目录补齐真实结果。不这么做的话，从历史读回来的文件消息
    // progress 恒为 0，界面永远显示 0%（而文件其实早就传完了）。
    String fileId = '';
    var progress = 0.0;
    var failed = false;
    String filePath = '';
    var state = dto.fromMe ? SendState.sent : SendState.delivered;

    if (isFile && dto.id.startsWith('file-')) {
      fileId = dto.id.substring(5);
      final rec = _transferOutcomes[fileId];
      if (rec != null) {
        failed = rec['failed'] == true;
        progress = failed ? 0 : 1;
        state = failed ? SendState.failed : SendState.delivered;
        filePath = (rec['path'] as String?) ?? '';
      } else {
        // 台账里没有（旧版本留下的历史 / 台账被淘汰）：能落库说明这条
        // 消息当时已发起，绝大多数已传完 —— 按完成态还原，别退回 0%
        progress = 1;
      }
      if (filePath.isEmpty) {
        filePath = _findDownloaded(dto.fileName) ?? '';
      }
    }

    return ChatMessage(
      id: dto.id,
      fromMe: dto.fromMe,
      kind: kind,
      time: DateTime.fromMillisecondsSinceEpoch(dto.tsMs),
      text: dto.text,
      fileName: dto.fileName,
      fileSize: dto.fileSize,
      state: state,
      fileId: fileId,
      progress: progress,
      failed: failed,
      filePath: filePath,
    );
  }

  // ------------------------------------------------------------
  // 文件传输（T4.4/T4.5）：发起发送 + 进度轮询 + 收件落消息
  // ------------------------------------------------------------

  /// fileId → 进行中/最近的文件消息（进度只更新这个对象，不整页 rebuild）。
  final Map<String, ChatMessage> _transferMsgs = {};
  /// 已落库的入站传输（防重复写）。
  final Set<String> _transferPersisted = {};
  Timer? _transferTimer;

  /// 发起真实文件传输：选中的文件 → 计算哈希 → 分块发出 → 消息上屏（T4.5）。
  ///
  /// [kind]：MessageKind.file / image。失败时消息直接标红可重试入口在 UI。
  /// 返回**是否真的把文件交给了 Rust 传输引擎**（发起了一次传输）。
  ///
  /// 这个返回值是必需的，不是装饰：`flushOutbox` 必须靠它决定能不能 ack 发件箱
  /// 条目。以前它返回 void，于是补发路径**无条件** ack —— 而离线时会走"重新排队"
  /// 分支后正常返回，条目就被删了；离线分支的重新入队又是 `unawaited`，与 ack
  /// 竞态，一旦 ack 后落地，**文件就从发件箱彻底消失、永远不会再补发**
  /// （用户反馈「根本就没发送过来」）。
  ///
  /// false = 只进了发件箱（排队/失败），调用方必须**保留** pending 条目。
  Future<bool> sendFilePath(
    String path, {
    MessageKind kind = MessageKind.file,
    String? peerId,

    /// 发送文件夹时用来保留目录结构：'文件夹»子目录»文件名'
    String? fileNameOverride,
  }) async {
    // peerId 用于「重连后补发中断文件」：那时用户不一定停在这个会话里
    final conv =
        peerId != null ? conversationFor(peerId) : activeConversation;
    if (conv == null) return false;
    if (!chatReady) {
      chatError = '聊天未就绪，无法发送文件';
      notifyListeners();
      return false;
    }
    final file = File(path);
    if (!file.existsSync()) {
      chatError = '文件不存在：$path';
      notifyListeners();
      return false;
    }
    final name = fileNameOverride ?? path.split(Platform.pathSeparator).last;
    final size = file.lengthSync();

    // 复用已存在的「未完成」文件气泡（B1-5：「N 个发送气泡」的直接原因），
    // 但**只复用气泡对象，绝不改变后面「真的去发」的流程**。
    //
    // 踩过的坑（务必保留这段说明）：第一版在复用命中时直接 `return`，于是
    // 「补发」变成「把气泡标成排队中然后返回」—— `flushOutbox` 紧接着
    // `outboxAck()` 就把发件箱条目删了，文件**从头到尾没被发出去过**，
    // 用户看到的就是「手机连上也没有发送」。复用必须 fall through。
    //
    // 判定按**文件名 + 大小 + 未完成**，不要求 `m.filePath == path`：
    // 重载回来的气泡 filePath 是空的（存储里没有这个字段），要求它就永远
    // 命中不了 —— 那正是「每轮补发多一个气泡」的来源。
    ChatMessage? reuse;
    for (var i = conv.messages.length - 1; i >= 0; i--) {
      final existing = conv.messages[i];
      if (!existing.fromMe || existing.kind == MessageKind.text) continue;
      if (existing.fileName != name || existing.fileSize != size) continue;
      if (existing.progress >= 1 || existing.failed || existing.cancelled) {
        continue; // 已完成/已失败的不能复用，那是重新发一次
      }
      reuse = existing;
      break;
    }

    final ChatMessage msg;
    if (reuse != null) {
      // 复用：把这个气泡拨回「发送中」，不新增第二个气泡
      reuse.queued = false;
      reuse.state = SendState.sending;
      reuse.failed = false;
      if (reuse.filePath.isEmpty) reuse.filePath = path;
      msg = reuse;
    } else {
      // 先上屏（sending，0%），Rust 侧算哈希可能要一两秒
      msg = ChatMessage(
        id: 'pending-file-${DateTime.now().microsecondsSinceEpoch}',
        fromMe: true,
        kind: kind,
        time: DateTime.now(),
        fileName: name,
        fileSize: size,
        state: SendState.sending,
        progress: 0,
        filePath: path,
      );
      conv.messages.add(msg);
    }
    conv.lastTsMs = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();

    // 对方不在线：标记「离线待发」并**立刻主动拨号**。
    //
    // 用 _effectivelyOnline 而不是 _isOnline：安卓进程被冻结时会漏掉
    // disconnected 事件、chatOnline 停在过期的 true 上，那种情况下把文件交给
    // Rust 只会得到「失败 0%」（用户反馈「PC 发送离线正常，手机离线发送失败 0%」）。
    // 这里先向 Rust 核一次：它说没有活连接就走排队，绝不硬发。
    //
    // 右键菜单拉起的第二实例/冷启动时 chatOnline 还是空的，之前这里只
    // 排队不拨号（拨号要等用户手动进会话才由 openConversationWith 触发），
    // 一旦拨号没成功，看起来就是「选了联系人却没发送」。这里补上
    // ensureDial（内部有 _dialed 闸、异常自吞），连上后 _syncAfterConnect
    // 会自动补发这条排队消息。
    if (!chatReady || !_effectivelyOnline(conv.device.id)) {
      unawaited(ensureDial(conv.device.id));
      msg.queued = true;
      msg.state = SendState.sending;
      chatError = '对方当前离线：文件已排队，上线后自动发送';
      notifyListeners();
      // 落进持久发件箱：进程被回收也能在重启后继续补发（根因3）。
      //
      // fileId 必须是**内容哈希**：Rust 侧 outbox 按 id 去重、入站也按内容哈希
      // 去重（chat.rs 明确要求两者共用同一个键）。以前这里用
      // `'${path.hashCode}-$size'` —— 路径 hash 不是内容，另一处（catch 分支）
      // 又用 `'file-${msg.id}'`，同一个物理文件会写出两个不同的 id，于是
      // 发件箱里同时留两条待发条目，上线后补发两次 → 用户看到的「N 个发送气泡」。
      unawaited(() async {
        try {
          final contentId = await ChatService.instance.fileContentId(path);
          await ChatService.instance.outboxEnqueueFile(
            peerId: conv.device.id,
            fileId: contentId,
            path: path,
            fileName: name,
            fileSize: size,
            kind: kind == MessageKind.image ? 2 : 3,
          );
        } catch (_) {
          // 桥接不可用：退化成旧的内存排队行为
        }
      }());
      return false;
    }

    try {
      final status = await TransferService.instance
          .send(peerId: conv.device.id, path: path);
      // 发出去就说明连接是活的（B1-4）：刷新活跃时间，别让递减窗口
      // 在对端明明有应答时照样过期。
      _touchPeerRx(conv.device.id);
      // 用户在算哈希期间点了「取消」：这里拿到 fileId 后立刻撤掉，不再上屏
      if (_cancelledPending.remove(msg.id)) {
        await TransferService.instance.cancel(status.fileId);
        return false; // 用户主动取消：没发出去，但条目由取消路径处理
      }
      final real = ChatMessage(
        id: 'file-${status.fileId}',
        fromMe: true,
        kind: kind,
        time: msg.time,
        fileName: name,
        fileSize: size,
        state: SendState.sending,
        progress: 0,
        fileId: status.fileId,
        filePath: path,
      );
      final idx = conv.messages.indexOf(msg);
      if (idx >= 0) {
        conv.messages[idx] = real;
      } else {
        conv.messages.add(real);
      }
      _transferMsgs[status.fileId] = real;
      // 落库（文件卡片重启后仍是卡片而不是纯文本）
      await ChatService.instance.appendMessage(
        peerId: conv.device.id,
        fromMe: true,
        text: '[文件] $name',
        tsMs: msg.time.millisecondsSinceEpoch,
        kind: kind == MessageKind.image ? 2 : 3,
        fileName: name,
        fileSize: size,
        msgId: 'file-${status.fileId}',
      );
      _startTransferPoll();
      notifyListeners();
      return true; // 真的交给 Rust 传输引擎了
    } catch (e) {
      // 发送失败（无论对端离线还是中途断开）一律落发件箱：outbox 是唯一
      // 真相源，重启后也能继续补发（审查 I2）。气泡标「排队中」并触发保活。
      msg.queued = true;
      msg.state = SendState.sending;
      msg.failed = false;
      chatError = '';
      unawaited(() async {
        try {
          // 与离线分支共用同一个**内容哈希**作为 fileId（B1-5）。
          // 以前这里是 `'file-${msg.id}'`：Rust 侧入队还会再加一层 `file-` 前缀，
          // 于是同一个物理文件在发件箱里存成两条 → 对端上线后补发两次 →
          // 用户看到的「N 个发送气泡」；而且它不是内容哈希，入站查重也对不上。
          final contentId = await ChatService.instance.fileContentId(path);
          await ChatService.instance.outboxEnqueueFile(
            peerId: conv.device.id,
            fileId: contentId,
            path: path,
            fileName: name,
            fileSize: size,
            kind: kind == MessageKind.image ? 2 : 3,
          );
        } catch (_) {}
      }());
      notifyListeners();
      return false; // 只进了发件箱，**没有**真的发出去
    }
  }

  void _startTransferPoll() {
    if (_transferTimer != null) return;
    // Rust 侧已 ≥100ms 节流，这里 400ms 拉一次（≤2Hz，风险5）
    _transferTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      // 轮询失败不能让未捕获异常冒泡（会打断整个 isolate 的事件循环）
      _pollTransfers().catchError((_) {});
    });
  }

  Future<void> _pollTransfers() async {
    // 这里**不能**拿 `chat_sessions()` 的 connected 去把对端标成在线。
    //
    // 试过并回退了：`is_connected()` 只表示「连接对象还活着」，对端进程被冻结、
    // socket 已经写不通时它**依然是 true**。用它当在线依据 ⇒ 明明发不出去的文件
    // 被交给 Rust 去发，收到 IO 错误后回一个 failed，界面就是
    // 「发送文件，直接失败 0%」；文字那条会走「非离线」分支被标成
    // 「发送失败」（用户反馈的正是这两条）。
    //
    // 会话状态只在**回前台兜底核对**时用一次，而且是单向的：只允许把
    // 「Rust 说没连上」的清成离线，绝不反向标成在线（见 [_verifyPresenceWithRust]）。

    // 周期补发：上线事件（_syncAfterConnect）只在对端连上那一刻触发一次，
    // 若那一刻拨号还没成功、或对端地址还没发现，补发就永远错过。
    // 这里每 400ms 补一次，配合 Rust 发件箱（pending 条目跨进程存活）。
    unawaited(flushOutbox());
    final statuses = await TransferService.instance.status();
    // 空列表**不要**停表：接收端要靠它发现新入的传输，
    // 停了就再也起不来（Rust 侧已 ≥100ms 节流，这里 400ms 拉一次很便宜）
    if (statuses.isEmpty) return;
    // 只有真的有变化才 notifyListeners：无条件通知会让整个 Shell 每 400ms
    // 全量重建一次（用户反馈「PC 端全程几乎都在卡」）。
    var changed = false;
    for (final s in statuses) {
      final size = s.size.toInt();
      final done = s.transferred.toInt();
      if (s.dir == rust_transfer.TransferDir.receive &&
          !_transferMsgs.containsKey(s.fileId) &&
          !_transferPersisted.contains(s.fileId) &&
          !_transferCancelled.contains(s.fileId)) {
        // 新的入站传输：给对应会话插一条文件消息。
        // 注意：**已完成的也要建** —— 小文件常常在两次轮询之间就传完了，
        // 之前被 !s.finished 挡掉，对端就完全看不到这条消息（用户反馈的
        // 「发文件对方还是不显示」）。去重靠 fileId + 落库集合，不靠 finished。
        _beginIncomingTransfer(s, size);
        changed = true;
      }
      final msg = _transferMsgs[s.fileId];
      if (msg == null) continue;
      if (s.finished) {
        changed = true;
        // 无论成败都记进台账：历史里读回来时才知道真实结果，
        // 而不是一律退回 0%（用户反馈的「刷新后又回到 0%」）
        if (s.cancelled) {
          // 取消是用户主动意图，**不是失败**：对端应显示「已取消」，
          // 而不是「传输失败」（用户反馈「一方取消，对方直接显示失败」）
          msg.cancelled = true;
          msg.failed = false;
          _transferCancelled.add(s.fileId);
          _recordTransferOutcome(s.fileId, failed: true);
          _removeMessageEverywhere(msg);
        } else if (s.failed) {
          msg.state = SendState.failed;
          msg.failed = true;
          _recordTransferOutcome(s.fileId, failed: true);
          if (s.error != null) chatError = '传输失败：${s.error}';
        } else {
          msg.state = SendState.delivered;
          msg.progress = 1;
          if (!msg.fromMe) {
            // 入站完成：按用户设置的接收目录归档（没设就留在默认收件目录），
            // 并记下真实路径，图片气泡/打开文件都靠它
            msg.filePath = _moveToReceiveDir(msg.fileName) ?? msg.filePath;
          } else if (msg.kind == MessageKind.image && msg.filePath.isEmpty) {
            msg.filePath = _findDownloaded(msg.fileName) ?? '';
          }
          _recordTransferOutcome(s.fileId,
              failed: false, path: msg.filePath);
          if (!msg.fromMe && !_transferPersisted.contains(s.fileId)) {
            // 入站完成：落库（重启后文件卡片仍在历史里）
            _transferPersisted.add(s.fileId);
            unawaited(ChatService.instance.appendMessage(
              peerId: msg.fileId.isEmpty ? s.peerId : s.peerId,
              fromMe: false,
              text: '[文件] ${s.name}',
              tsMs: msg.time.millisecondsSinceEpoch,
              kind: msg.kind == MessageKind.image ? 2 : 3,
              fileName: s.name,
              fileSize: size,
              msgId: 'file-${s.fileId}',
            ).catchError((_) => rust_chat.MessageDto(
                  id: '',
                  peerId: s.peerId,
                  seq: 0,
                  fromMe: false,
                  kind: 3,
                  text: '',
                  fileName: '',
                  fileSize: 0,
                  tsMs: 0,
                  delivered: true,
                )));
          }
        }
        _transferMsgs.remove(s.fileId);
      } else {
        final next = size == 0 ? 0.0 : (done / size).clamp(0.0, 1.0).toDouble();
        // 进度推进够明显才标记变化：否则 400ms 一次的微小抖动也会触发
        // 整页重建，大消息列表上就是肉眼可见的卡顿
        if ((next - msg.progress).abs() >= 0.005 || msg.paused != s.paused) {
          msg.progress = next;
          changed = true;
        }
        // 以 Rust 侧为准同步暂停态，避免两端状态漂移
        msg.paused = s.paused;
        if (msg.state == SendState.delivered) {
          msg.state = SendState.sending;
        }
      }
    }
    if (changed) notifyListeners();
    unawaited(_updateKeepAlive());
  }

  /// 前台服务是否已开（Task 10：仅在真有活干时才开，避免白挂常驻通知）。
  bool _keepAliveOn = false;

  bool get keepAliveOn => _keepAliveOn;

  /// 现在是否「有活干」：有在传的文件、发件箱里有排队条目，**或有会话在线**。
  ///
  /// B1-4：以前只看前两条，纯聊天（没有传输、没有待发）时切后台不开前台服务
  /// → Android 冻结进程 → 心跳（3s 一次）停发 → PC 侧 PEER_TIMEOUT_MS=10000
  /// 一到就判安卓离线。用户看到的就是「一切到桌面后台，PC 上就显示安卓离线，
  /// 明明安卓进程都还在」。安卓**确实**停止发送了，所以不是 PC 误判 ——
  /// 要修的是「只要有活着的会话就必须保活」。
  ///
  /// 但仍要避免白挂常驻通知：所有会话都离线且无传输无待发时才关。
  bool get _keepAliveWanted =>
      _transferMsgs.isNotEmpty || _outboxPending > 0 || _hasOnlinePeer();

  /// 是否有任何会话处于在线（保活判定的第三条）。
  bool _hasOnlinePeer() {
    for (final id in chatOnline.keys) {
      if (_isOnline(id)) return true;
    }
    return false;
  }

  /// 最近一次 flushOutbox 看到的待发条数（UI 无事可做时就不开前台服务）。
  int _outboxPending = 0;

  /// 按需开关前台服务。幂等：状态没变就一次原生调用都不发。
  ///
  /// 与真实服务状态对账（审查 I5/M4）：若原生 startKeepAlive 被系统拒绝
  /// （Android 12+ 后台启动限制）而 Dart 侧已把 _keepAliveOn 写成 true，
  /// 早退会让保活**永久失效**。所以 wanted==on 时仍向原生查一次
  /// isKeepAliveRunning，不一致就重发 start/stop 拉平。
  Future<void> _updateKeepAlive() async {
    if (!YuChuanPlatform.isAndroid) return;
    final wanted = _keepAliveWanted;
    if (wanted == _keepAliveOn) {
      bool running;
      try {
        running = await YuChuanPlatform.isKeepAliveRunning();
      } catch (_) {
        return; // 原生未实现：无法对账，保持现状
      }
      if (running == wanted) return;
    }
    _keepAliveOn = wanted;
    try {
      if (_keepAliveOn) {
        await YuChuanPlatform.startKeepAlive();
      } else {
        await YuChuanPlatform.stopKeepAlive();
      }
    } catch (_) {
      // 原生未实现/被系统拒绝：不影响收发，只是后台可能被系统回收。
      // 不把 _keepAliveOn 置 false 之外的东西——下一轮对账还会重试 start。
      _keepAliveOn = false;
    }
  }

  /// 切后台/状态变化时重新算一次要不要开前台服务（供 main.dart 调用）。
  Future<void> refreshKeepAlive() => _updateKeepAlive();

  /// 回前台自愈。
  ///
  /// **不再清在线标记**（这是「双方都显示一直离线」的根因）：
  ///
  /// 旧实现在离开前台 ≥10s 时对每个会话 `_setOnline(id, false)`。但 Rust 侧静默
  /// 早就改成**不断开**（只发一次 `Stalled`），那次断开**根本没发生** ——
  /// 清掉之后没有任何东西会把它设回 true：`connected` 事件早在最初连上时就发过
  /// 了不会重发，在线判定也不再靠递减窗口。结果就是**永久离线**，
  /// 而且双方互相都是这个状态。
  ///
  /// 现在只做两件事：
  ///   1. 用 Rust 的真实连接状态兜底核对（只清「Rust 说没连上」的，
  ///      安全方向 —— 永远不会凭空造出离线），见 [_verifyPresenceWithRust]；
  ///   2. 重算前台服务（有会话在线就要保活）。
  ///
  /// [backgroundFor] 保留仅为兼容调用方；判定不再依赖它 —— 把「离开多久」当阈值
  /// 是个手工耦合点，而且是错的方向（静默本就不该判死）。
  Future<void> onAppResumed({Duration? backgroundFor}) async {
    _verifyPresenceWithRust();
    await _updateKeepAlive();
  }

  /// 供测试驱动一次「用 Rust 的真实连接状态兜底核对」。
  @visibleForTesting
  void debugVerifyPresenceWithRustForTest() => _verifyPresenceWithRust();

  /// 供测试注入「Rust 认为哪些 peer 还连着」（`chat_sessions()` 的替身）。
  ///
  /// 单元测试 VM 里没有 native 库，`ChatService.instance.sessions()` 必抛；
  /// 注入后真实逻辑照跑，只是数据由测试给出。
  @visibleForTesting
  static Set<String>? debugConnectedPeersForTest;

  /// 用 Rust 的真实连接状态兜底核对在线表。
  ///
  /// **单向：只把「Rust 说没连上」的清成离线。** 绝不反向把没连上的写成在线 ——
  /// 这条不变量保证它不会造假：最坏情况只是更保守地显示离线，而不会凭一个
  /// 「连接对象还活着」就宣称对端可达（那正是「发送文件直接失败」的来源）。
  ///
  /// 存在的价值：兜住漏掉的 `disconnected` 事件（进程被冻结期间事件可能丢），
  /// 让真断开的会话最终会显示离线，而不是永久停在一个过期的 true 上。
  void _verifyPresenceWithRust() {
    final override = debugConnectedPeersForTest;
    final Set<String> connected;
    if (override != null) {
      connected = override;
    } else {
      try {
        connected = {
          for (final s in ChatService.instance.sessions())
            if (s.connected) s.peerId,
        };
      } catch (_) {
        return; // 桥未就绪（演示模式/测试）：不动现有判断
      }
    }
    var changed = false;
    for (final id in chatOnline.keys.toList()) {
      if (!(chatOnline[id] ?? false)) continue;
      if (connected.contains(id)) continue;
      chatOnline[id] = false;
      changed = true;
      unawaited(ensureDial(id));
    }
    if (changed) notifyListeners();
  }

  /// 供测试驱动「忙不忙」判定，不碰真实通道。
  @visibleForTesting
  Future<void> debugApplyKeepAlive({
    required int busyTransfers,
    required int pendingOutbox,
    List<String> onlinePeers = const [],
  }) async {
    _transferMsgs.clear();
    for (var i = 0; i < busyTransfers; i++) {
      _transferMsgs['debug-$i'] = ChatMessage(
        id: 'debug-$i',
        fromMe: true,
        kind: MessageKind.file,
        time: DateTime.now(),
      );
    }
    _outboxPending = pendingOutbox;
    // 在线会话是保活的第三条依据（B1-4）：清干净再摆，避免上一条用例残留。
    chatOnline.clear();
    for (final id in onlinePeers) {
      _dialedAt[id] = DateTime.now();
      chatOnline[id] = true;
    }
    await _updateKeepAlive();
  }

  // ─────────────────── B1-4 测试钩子（命名一律带 ForTest） ───────────────────

  /// 供测试直接摆好「该 peer 在线/离线」，绕过真实会话事件。
  @visibleForTesting
  void debugSetOnlineForTest(String peerId, bool online) => _setOnline(peerId, online);

  /// 供测试查询 [_isOnline] 的现值（内部判定，不等于展示字段）。
  @visibleForTesting
  bool debugIsOnlineForTest(String peerId) => _isOnline(peerId);

  /// 供测试模拟一条来自 Rust 的 disconnected 事件（含 reason 区分）。
  @visibleForTesting
  void debugPeerDisconnectedForTest(String peerId, String? reason) =>
      _onPeerDisconnected(peerId, reason);

  /// 供测试记录「该 peer 已被拨号过」（锁住重连不重复拨）。
  @visibleForTesting
  void debugMarkDialedForTest(String peerId) {
    _dialedAt[peerId] = DateTime.now();
  }

  /// 供测试查询拨号记录是否存在。
  @visibleForTesting
  bool debugHasDialRecordForTest(String peerId) => _dialedAt.containsKey(peerId);

  /// 供测试**走真实事件分发路径**投递一条 Rust 聊天事件。
  ///
  /// 直接调 `_onPeerDisconnected` 会绕过 [_onChatEvent] 里按 kind 的分发，
  /// 测不到「timeout 静默 vs eof/io/protocol/bye 真断开」这条判定 ——
  /// 而那正是 B1-4「一直显示断开断开」的所在地，必须走同一入口。
  @visibleForTesting
  void debugDeliverChatEventForTest(rust_chat.ChatEventDto event) =>
      _onChatEvent(event);

  // ────────────────────── B1-1 测试钩子：发现订阅生命周期 ──────────────────────

  /// 当前是否挂着发现事件订阅（[enableLiveDiscovery] 的 `??=` 是否会被跳过）。
  @visibleForTesting
  bool get debugDiscoverySubscribedForTest => _discoverySub != null;

  /// 供测试把「发现正在跑」的 UI 状态摆好（`toggleDiscovering` 的停止分支看它）。
  @visibleForTesting
  void debugMarkLiveDiscoveryForTest(bool live) {
    liveDiscovery = live;
    discovering = live;
  }

  /// 挂一个**不会被真实事件驱动**的空订阅，模拟「订阅已建立」。
  ///
  /// 不接真实 DiscoveryService（测试环境没有 Rust 桥），只占用 `_discoverySub`
  /// 这个槽位，好让「停止路径有没有释放它」被真正测到。
  @visibleForTesting
  void debugAttachIdleDiscoverySubForTest() {
    _discoverySub?.cancel();
    _discoverySub = const Stream<rust_discovery.DiscoveryEventDto>.empty().listen((_) {});
  }

  /// 供测试直接触发自动停发现（配对成功后的那条路径）。
  @visibleForTesting
  Future<void> debugAutoStopDiscoveryForTest() => _autoStopDiscovery();

  // ────────────────────── B1-2 测试钩子：删除墓碑持久化 ──────────────────────

  /// 当前内存里的删除墓碑（断言「落盘后能否读回」）。
  @visibleForTesting
  Set<String> debugRemovedPeersForTest() => {..._removedPeers};

  /// 清掉内存墓碑（模拟「只写了内存、没落盘」的修复前状态）。
  @visibleForTesting
  void debugClearRemovedPeersForTest() => _removedPeers.clear();

  /// 模拟冷启动：内存墓碑清空，但**保留历史**（复现「删不干净」的残留）。
  @visibleForTesting
  void debugSimulateRestartKeepHistoryForTest() => _removedPeers.clear();

  /// 当前会话列表里的 device id（用于断言残留 peer 有没有复活）。
  @visibleForTesting
  Future<List<String>> debugConversationIdsForTest() async {
    rebuildConversations();
    return [for (final c in conversations) c.device.id];
  }

  /// 往某个 peer 的历史里塞一条消息（模拟「删除时没删干净」的残留）。
  @visibleForTesting
  Future<void> debugSeedHistoryForTest(String peerId, String text) async {
    _history.putIfAbsent(peerId, () => <ChatMessage>[]).add(ChatMessage(
          id: 'residue-$peerId-${DateTime.now().microsecondsSinceEpoch}',
          fromMe: false,
          kind: MessageKind.text,
          time: DateTime.now(),
          text: text,
        ));
    _historyLoaded.add(peerId);
  }

  /// 走生产路径写入一条联系人（验证「重新配对撤墓碑」）。
  @visibleForTesting
  void debugUpsertContactForTest(String peerId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _upsertContact(rust_pairing.PairedContactDto(
      deviceId: peerId,
      name: '测试设备',
      platform: 'android',
      addrHistory: const [],
      pairedAtMs: now,
      lastSeenMs: now,
    ));
  }

  // ────────────────────── B1-5 测试钩子：排队状态跨重载存活 ──────────────────────

  /// 发件箱 pending 的注入点。
  ///
  /// 单元测试 VM 里没有 native 库，`ChatService.outboxPending()` 必抛 ——
  /// 直接用它会让 [_reconcileQueuedFromOutbox] 的断言**根本不执行**（假绿）。
  /// 注入后真实逻辑照跑，只是数据由测试给出。
  @visibleForTesting
  static List<rust_chat.OutboxItemDto> Function(String peerId)?
      debugOutboxPendingOverrideForTest;

  /// 模拟「进程被回收后重启」：内存气泡从存储重建 —— `queued`/`filePath` 全丢。
  @visibleForTesting
  void debugReloadFromStorageForTest(String peerId) {
    final list = _history[peerId];
    if (list == null) return;
    for (var i = 0; i < list.length; i++) {
      final m = list[i];
      list[i] = ChatMessage(
        id: m.id,
        fromMe: m.fromMe,
        kind: m.kind,
        time: m.time,
        text: m.text,
        fileName: m.fileName,
        fileSize: m.fileSize,
        fileId: m.fileId,
        state: m.state,
        progress: m.progress,
        failed: m.failed,
        cancelled: m.cancelled,
        paused: m.paused,
        // 存储里没有 queued 字段 → 重载后恒为 false（这正是泄漏点）
        queued: false,
        filePath: '',
      );
    }
  }

  /// 走生产路径把发件箱里的 pending 回灌到气泡上。
  @visibleForTesting
  void debugReconcileQueuedForTest(String peerId) =>
      _reconcileQueuedFromOutbox(peerId);

  /// 把发件箱里仍待发的文件对回内存气泡（B1-5 核心）。
  ///
  /// 为什么必须做：`queued` 只活在内存里，而气泡重载后它恒为 false，于是
  /// [_clearQueuedBubble]（补发成功后清「排队中」）和 `sendFilePath` 里的
  /// `existingQueued` 复用判定**两个都命中不了** —— 每次补发都新建一个气泡，
  /// 这就是用户看到的「N 个发送气泡」；旧气泡则永远停在「排队中」。
  ///
  /// 发件箱是唯一真相源：只要里面还有该文件的 pending，气泡就该是「排队中」，
  /// 并把 `filePath` 补回去（重载后它是空的，复用判定也要用它）。
  void _reconcileQueuedFromOutbox(String peerId) {
    final list = _history[peerId];
    if (list == null || list.isEmpty) return;
    final List<rust_chat.OutboxItemDto> pending;
    final override = debugOutboxPendingOverrideForTest;
    if (override != null) {
      pending = override(peerId);
    } else {
      try {
        pending = ChatService.instance.outboxPending(peerId);
      } catch (_) {
        return; // 桥不可用：保持现状
      }
    }
    if (pending.isEmpty) return;
    // 文件类 pending 按「文件名 + 大小」对回气泡：重载后 fileName/fileSize
    // 是存储里有的字段，而 filePath/fileId 都可能已丢。
    for (final item in pending) {
      if (item.kind == 1) continue; // 文本走 sendTextTo，不参与气泡复用
      for (var i = list.length - 1; i >= 0; i--) {
        final m = list[i];
        if (!m.fromMe || m.kind == MessageKind.text) continue;
        if (m.fileName != item.fileName || m.fileSize != item.fileSize) continue;
        if (m.progress >= 1 || m.failed || m.cancelled) continue;
        m.queued = true;
        if (m.filePath.isEmpty && item.filePath.isNotEmpty) {
          m.filePath = item.filePath;
        }
        // fileId 在 ChatMessage 里是 final，不能回填；复用判定按
        // 「文件名 + 大小」而不是 fileId，正好不依赖它。
        break; // 一个 pending 只认领一个气泡
      }
    }
  }

  /// 把一条消息从所有会话/历史里摘掉（取消收尾用）。
  void _removeMessageEverywhere(ChatMessage msg) {
    _removedMsgIds.add(msg.id);
    String? peerId;
    for (final c in conversations) {
      if (c.messages.remove(msg)) peerId ??= c.device.id;
    }
    for (final e in _history.entries) {
      if (e.value.remove(msg)) peerId ??= e.key;
    }
    // 磁盘也要删：否则重启后那条取消的记录又从存储里读回来
    if (peerId != null) _removeFromStore(peerId, msg.id);
    notifyListeners();
  }

  /// 图片消息的本地路径（T5.1）：发送方=源文件路径；接收方=收件目录里查找
  /// （含重名自动编号 (1)…）；都找不到返回 null（用占位渐变）。
  String? localImagePath(ChatMessage msg) {
    if (msg.filePath.isNotEmpty && File(msg.filePath).existsSync()) {
      return msg.filePath;
    }
    return _findDownloaded(msg.fileName);
  }
  /// 在收件目录里找实际落盘路径（接收端重名时会自动编号 (1)…）。
  /// 优先找用户自定义的接收目录，再回落到默认收件目录。
  String? _findDownloaded(String fileName) {
    if (fileName.isEmpty) return null;
    final custom = AppearanceState.instance.receiveDir;
    String? found;
    try {
      found = _findIn(custom, fileName) ??
          _findIn(TransferService.instance.downloadDir(), fileName);
    } catch (_) {
      // 桥接未就绪：只按自定义目录找
      found = _findIn(custom, fileName);
    }
    return found;
  }

  /// 在某个目录里按文件名找（含重名自动编号 (1)…）。
  String? _findIn(String? dir, String fileName) {
    if (dir == null || dir.isEmpty) return null;
    final direct = File('$dir${Platform.pathSeparator}$fileName');
    if (direct.existsSync()) return direct.path;
    for (var i = 1; i <= 50; i++) {
      final dot = fileName.lastIndexOf('.');
      final candidate = dot > 0
          ? '${fileName.substring(0, dot)} ($i)${fileName.substring(dot)}'
          : '$fileName ($i)';
      final f = File('$dir${Platform.pathSeparator}$candidate');
      if (f.existsSync()) return f.path;
    }
    return null;
  }

  /// 收到文件后：若用户设置了自定义接收目录，把文件从默认收件目录挪过去。
  /// 返回最终落盘路径（失败则留在默认目录，不影响收消息）。
  /// 文件夹传输的分隔符：发送端把目录结构编进文件名（协议只传一个 name），
  /// 接收端按它还原成真实的子目录。
  static const String kFolderSep = '»';

  String? _moveToReceiveDir(String fileName) {
    final src = _findDownloaded(fileName);
    if (src == null) return null;
    final custom = AppearanceState.instance.receiveDir;
    String defaultDir = '';
    try {
      defaultDir = TransferService.instance.downloadDir();
    } catch (_) {
      defaultDir = '';
    }
    var root = (custom != null && custom.isNotEmpty) ? custom : defaultDir;
    // 安卓零存储权限：共享可见的 Download/雨传 只能走 MediaStore，
    // 真实路径既拿不到也不可写 —— 所以没设自定义目录时优先用它。
    // 私有副本**保留**（不删）：打开文件 / 图片预览 / 重发都依赖它。
    if (YuChuanPlatform.isAndroid && (custom == null || custom.isEmpty)) {
      final parts = fileName.split(kFolderSep);
      unawaited(_archiveViaMediaStore(
        src,
        parts.sublist(0, parts.length - 1).join('/'),
        parts.last,
      ));
      return src;
    }
    if (root.isEmpty) return src;
    // 安卓：自定义接收目录 dart:io 都写不进去 ——
    // ① `content://` SAF 树 → 交给原生 DocumentsContract 复制；
    // ② 真实路径（**file_picker 选目录返回的就是解析后的真实路径**，
    //    没有任何写权限）→ 先试 dart:io 直拷（应用专用目录可行；
    //    不能用 rename —— 私有目录和外部存储是不同挂载点，EXDEV 必败），
    //    共享存储被拒时同样落回原生 SAF：原生用真实路径重建树 URI，
    //    借用选择器留下的瞬时授权转持久授权。
    // 两条路都保留默认收件目录的副本 —— 「打开文件 / 图片预览 / 文件 TAB」
    // 都依赖真实路径（SAF 的 content URI 不能可靠跨应用打开）。
    if (YuChuanPlatform.isAndroid) {
      if (root.startsWith('content://')) {
        unawaited(_archiveViaSaf(src, root, fileName));
        return src;
      }
      try {
        File(src).copySync(_prepareDstSync(root, fileName));
        return src;
      } catch (_) {
        // 共享存储被 scoped storage 拒绝 → 原生 SAF 归档兜底
        unawaited(_archiveViaSaf(src, root, fileName));
        return src;
      }
    }
    try {
      final dst = _prepareDstSync(root, fileName);
      File(src).renameSync(dst);
      return dst;
    } catch (_) {
      return src;
    }
  }

  /// 计算落盘目标路径并确保存在：文件夹传输的 `»` 子目录链 + 重名自动编号
  /// （`report.pdf` → `report (1).pdf`，与原生侧规则一致）。
  String _prepareDstSync(String root, String fileName) {
    final sep = Platform.pathSeparator;
    final parts = fileName.split(kFolderSep);
    var baseName = fileName;
    if (parts.length > 1) {
      root = [root, ...parts.sublist(0, parts.length - 1)].join(sep);
      baseName = parts.last;
    }
    final dir = Directory(root);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    var dst = root + sep + baseName;
    var i = 1;
    while (File(dst).existsSync()) {
      final dot = baseName.lastIndexOf('.');
      dst = dot > 0
          ? '$root$sep${baseName.substring(0, dot)} ($i)${baseName.substring(dot)}'
          : '$root$sep$baseName ($i)';
      i++;
    }
    return dst;
  }

  /// 安卓：把收到的文件归档进公共 `Download/雨传`（MediaStore）。
  ///
  /// 零存储权限下这是唯一能被系统文件管理器直接看到的落点。失败只出横幅，
  /// 不影响收消息 —— 应用私有副本始终还在，文件 TAB / 打开 / 预览都可回落。
  Future<void> _archiveViaMediaStore(
      String src, String relPath, String fileName) async {
    final r = await YuChuanPlatform.archiveToMediaStore(
      srcPath: src,
      relPath: relPath,
      fileName: fileName,
    );
    final err = r.error;
    if (err == null) return;
    chatError = '已收到文件，但写入 Download/${YuChuanPlatform.publicDownloadDirName} 失败：$err';
    notifyListeners();
  }

  /// 安卓归档到用户选的接收目录：`target` 可以是 `content://` 树或真实路径
  /// （原生内部统一转成树 URI）。失败出全局横幅，不影响收消息。
  Future<void> _archiveViaSaf(String src, String target, String fileName) async {
    final parts = fileName.split(kFolderSep);
    final err = await YuChuanPlatform.archiveToTree(
      srcPath: src,
      treeUri: target,
      relPath: parts.sublist(0, parts.length - 1).join('/'),
      fileName: parts.last,
    );
    if (err == null) return;
    chatError = '已收到文件，但写入接收目录失败：$err（请在设置里重新选择接收目录）';
    notifyListeners();
  }

  void _beginIncomingTransfer(rust_transfer.TransferStatusDto s, int size) {
    final peerId = s.peerId;
    if (peerId.isEmpty) return;
    final conv = conversationFor(peerId);
    final lower = s.name.toLowerCase();
    final isImage = lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp');
    final msg = ChatMessage(
      id: 'file-${s.fileId}',
      fromMe: false,
      kind: isImage ? MessageKind.image : MessageKind.file,
      time: DateTime.now(),
      fileName: s.name,
      fileSize: size,
      // 小文件可能在两次轮询之间就传完了：直接按完成态建气泡
      state: s.finished && !s.failed ? SendState.delivered : SendState.sending,
      progress: s.finished && !s.failed ? 1 : 0,
      fileId: s.fileId,
    );
    // 同一个 file_id 只允许一条气泡（重复的 FILE_META/状态刷新都会走到这里）
    final dup = conv.messages.where((m) => m.id == msg.id).firstOrNull;
    if (dup != null) {
      _transferMsgs[s.fileId] = dup;
      return;
    }
    if (s.finished && !s.failed) {
      // 已完成：归档到接收目录、记路径、直接落库（poll 里不会再碰到它）
      msg.filePath = _moveToReceiveDir(msg.fileName) ?? '';
      _transferPersisted.add(s.fileId);
      unawaited(ChatService.instance.appendMessage(
        peerId: peerId,
        fromMe: false,
        text: '[文件] ${s.name}',
        tsMs: msg.time.millisecondsSinceEpoch,
        kind: msg.kind == MessageKind.image ? 2 : 3,
        fileName: s.name,
        fileSize: size,
        msgId: msg.id,
      ).catchError((_) => rust_chat.MessageDto(
            id: '',
            peerId: peerId,
            seq: 0,
            fromMe: false,
            kind: 3,
            text: '',
            fileName: '',
            fileSize: 0,
            tsMs: 0,
            delivered: true,
          )));
    } else {
      _transferMsgs[s.fileId] = msg;
    }
    conv.messages.add(msg);
    conv.lastTsMs = msg.time.millisecondsSinceEpoch;
    conv.messages.sort((a, b) => a.time.compareTo(b.time));
  }

  /// 已被用户取消、但还没拿到 fileId 的发送（Rust 侧算哈希期间）。
  final Set<String> _cancelledPending = {};

  /// 已取消的传输 id：既不重建入站气泡，也不参与自动补发。
  final Set<String> _transferCancelled = {};

  /// 已删除/已取消的消息 id：从存储重载历史时也要滤掉，
  /// 否则连上对端触发强制刷新时，删掉的气泡会被又拉回来。
  final Set<String> _removedMsgIds = {};

  /// 取消一个传输（UI 从文件卡片/长按菜单调用）。
  ///
  /// 之前只处理「已有 fileId」的情况 —— 算哈希那一两秒里取消按钮点了没反应
  /// （用户反馈「发送的取消按钮无效」）。现在 pending 消息也能取消：先标记，
  /// 等 Rust 返回 fileId 后立刻撤掉这个传输。
  /// 暂停一个进行中的发送（纯发送侧；心跳独立，连接不会被判离线）。
  Future<void> pauseTransfer(ChatMessage msg) async {
    if (msg.fileId.isEmpty) return;
    try {
      await TransferService.instance.pause(msg.fileId);
    } catch (_) {
      return;
    }
    msg.paused = true;
    notifyListeners();
  }

  /// 继续一个已暂停的发送。
  Future<void> resumeTransfer(ChatMessage msg) async {
    if (msg.fileId.isEmpty) return;
    try {
      await TransferService.instance.resume(msg.fileId);
    } catch (_) {
      return;
    }
    msg.paused = false;
    notifyListeners();
  }
  Future<void> cancelTransfer(ChatMessage msg) async {
    if (msg.fileId.isEmpty) {
      _cancelledPending.add(msg.id);
    } else {
      _transferCancelled.add(msg.fileId);
      try {
        await TransferService.instance.cancel(msg.fileId);
      } catch (_) {
        // 传输可能刚好结束：忽略，下面照样把消息收掉
      }
      _transferMsgs.remove(msg.fileId);
    }
    msg.cancelled = true;
    msg.failed = false;
    _removedMsgIds.add(msg.id); // 取消的也不要在重载后复活
    // 取消 = 这条消息不该再留在聊天里（用户反馈：取消后气泡还挂着
    // 「发送失败」样式）。历史里同 id 的副本也一并摘掉。
    var removed = false;
    String? peerId;
    for (final c in conversations) {
      if (c.messages.remove(msg)) {
        removed = true;
        peerId ??= c.device.id;
      }
    }
    for (final e in _history.entries) {
      if (e.value.remove(msg)) {
        removed = true;
        peerId ??= e.key;
      }
    }
    if (removed) _historyLoaded.add(peerId ?? msgPeerId(msg));
    // 磁盘也要删：出站文件在 sendFilePath 里已落库，不删重启就复活
    if (peerId != null) _removeFromStore(peerId, msg.id);
    notifyListeners();
  }

  /// 该消息属于哪个 peer（按消息反查会话）。
  String msgPeerId(ChatMessage msg) {
    for (final c in conversations) {
      if (c.messages.contains(msg)) return c.device.id;
    }
    for (final e in _history.entries) {
      if (e.value.contains(msg)) return e.key;
    }
    return '';
  }

  /// 文件消息的本地路径：发送方=源文件；接收方=收件目录按文件名找（含重名编号）。
  String localFilePath(ChatMessage msg) {
    if (msg.filePath.isNotEmpty && File(msg.filePath).existsSync()) {
      return msg.filePath;
    }
    return _findDownloaded(msg.fileName) ?? '';
  }

  /// 「打开所在文件夹」的统一入口（桌面 + 手机）。
  ///
  /// 桌面：资源管理器定位到该文件。安卓：交给原生打开**目录**，且必须打开
  /// 用户真能在文件管理器里看到的落点 —— 传进来的 path 往往是应用私有副本
  /// （`/data/…`），外部进不去，原生只会回 `APP_INTERNAL`；而安卓上文件早已
  /// 归档到公共 `Download/雨传`（或用户自选的接收目录），那才是该打开的地方。
  /// path 本身在公共存储时（如自己发出的文件），定位文件**自己**所在处。
  ///
  /// 返回可直接 toast 的提示语（永远非空）。
  Future<String> revealFolder(String path) async {
    String? err;
    if (YuChuanPlatform.isAndroid) {
      final custom = AppearanceState.instance.receiveDir;
      if (custom != null && custom.isNotEmpty && _insideAppPrivate(path)) {
        // ① 用户设了自定义接收目录，且传入的是外部进不去的私有副本：
        //    打开那棵树（收到的文件在那边有副本）。
        //    注意门控不能省：path 在公共存储时（如自己发出的文件），
        //    用户要的是文件**自己**所在处，不是接收目录。
        err = await YuChuanPlatform.revealInFolder(custom);
      } else if (_insideAppPrivate(path)) {
        // ② 未设自定义目录：文件的对外落点就是公共 Download/雨传，
        //    由原生构造 document URI 交给系统文件管理器
        err = await YuChuanPlatform.revealPublicDownloadDir();
      } else {
        // ③ 路径本身就在公共存储：常规定位到该文件
        err = await YuChuanPlatform.revealInFolder(path);
      }
    } else {
      err = await YuChuanPlatform.revealInFolder(path);
    }
    // 旧实现把 APP_INTERNAL 当成「切到应用内『文件』TAB」的信号，用户看到的
    // 就是「在应用内部不能打开」（修 bug.md 第 7、12 行）。现在它只会在连
    // 公共目录都定位不到时出现（如存储未挂载），转成中文，
    // 别把内部哨兵值漏给用户。
    if (err == YuChuanPlatform.revealAppInternal) {
      return '打开失败：系统里找不到可浏览的目录';
    }
    return err == null ? '已打开所在文件夹' : '打开失败：$err';
  }

  /// 安卓：路径是否在外部文件管理器进不去的应用私有区。
  static bool _insideAppPrivate(String path) {
    final shared = path.startsWith('/storage/') ||
        path.startsWith('/sdcard/') ||
        path.startsWith('/mnt/media_rw/');
    if (!shared) return true;
    // 应用的外部私有目录（getExternalFilesDir）也在 /storage 下
    return path.contains('/Android/data/') || path.contains('/Android/obb/');
  }

  // ------------------------------------------------------------
  // Messaging
  // ------------------------------------------------------------

  void updateDraft(String text) {
    if (selectedConversation == null) return;
    conversations[selectedConversation!].draft = text;
    // No notifyListeners: typing must not rebuild the whole shell.
  }

  /// 发文本：乐观上屏（sending）→ Rust 落库并发出 → 用落库后的消息替换
  /// （id 与存储一致，重载历史不会重复）；失败标红，可长按重发（T3.6）。
  Future<void> sendMessage(String text) async {
    final conv = activeConversation;
    final trimmed = text.trim();
    if (conv == null || trimmed.isEmpty) return;
    final peerId = conv.device.id;
    if (!chatReady) {
      chatError = '聊天未就绪（消息存储/监听未启动）';
      notifyListeners();
      return;
    }
    conv.draft = '';
    final now = DateTime.now();
    final optimistic = ChatMessage(
      id: 'pending-${now.microsecondsSinceEpoch}',
      fromMe: true,
      kind: MessageKind.text,
      time: now,
      text: trimmed,
      state: SendState.sending,
    );
    conv.messages.add(optimistic);
    conv.lastTsMs = now.millisecondsSinceEpoch;
    notifyListeners();

    // 对方不在线：排进**持久**发件箱（Rust outbox.jsonl），并主动拨一次号。
    // 关键点（根因1）：这里以前只给气泡打了个内存标记，既不拨号也不落盘，
    // 于是「对端上线自动接收」永远不会发生 —— 进程一旦被回收连标记都没了。
    // 同 sendFilePath：用 _effectivelyOnline 先向 Rust 核一次，避免安卓漏掉
    // 断开事件后把消息硬发给死连接（「手机离线发送失败 0%」的那条链路）。
    if (!chatReady || !_effectivelyOnline(peerId)) {
      optimistic.queued = true;
      optimistic.state = SendState.sending;
      notifyListeners();
      unawaited(ensureDial(peerId)); // 主动拨号，不再干等对端连入
      try {
        await ChatService.instance.outboxEnqueueText(peerId, trimmed);
      } catch (_) {
        // 桥接不可用：退化成旧的内存排队行为，至少本次运行内还能补发
      }
      return;
    }

    try {
      await ensureDial(peerId);
      final saved = await ChatService.instance.sendText(
        peerId: peerId,
        senderId: DiscoveryService.instance.deviceId,
        text: trimmed,
      );
      final idx = conv.messages.indexOf(optimistic);
      final real = _toChatMessage(saved)..state = SendState.sent;
      if (idx >= 0) {
        conv.messages[idx] = real;
      } else {
        conv.messages.add(real);
      }
      chatError = '';
    } catch (e) {
      // 对方不在线 → 标成「离线排队」，连上后自动补发（只补一次）；
      // 其它错误才显示失败可重试
      // Rust 侧「拨号与入站连接均不可用」也按离线处理：出站拨号常卡在重连
      // 而对端反向连入是活的（UI 显示在线），恢复后由 _syncAfterConnect 补发
      final offline = !_dialedAt.containsKey(peerId) ||
          !_isOnline(peerId) ||
          e.toString().contains('未连接到对端');
      optimistic.state = offline ? SendState.sending : SendState.failed;
      optimistic.failed = !offline;
      optimistic.queued = offline;
      chatError = offline ? '' : '发送失败：$e';
    }
    notifyListeners();
  }

  /// 该对端当前是否在线。
  ///
  /// **唯一权威来源是 Rust 侧的连接事实**（`connected` / `disconnected` 事件，
  /// 以及 [_verifyPresenceWithRust] 的兜底核对）。
  ///
  /// 为什么**不再**用「最近一次收到数据的时间」递减判断（试过，回退了）：
  /// 心跳（PING/PONG）完全由 Rust 内部处理，**不会**变成 Dart 事件
  /// （`session.rs` 的 `FrameType::Ping =>` 只回 pong）。所以「Dart 侧多久没收到
  /// 数据」根本反映不了连接死活 —— 一条健康但空闲的连接 30 秒后必然被判成离线，
  /// 而且**再也不会变回在线**（没有任何 Dart 事件会来刷新它）。
  /// 这就是用户反馈的「双方在聊天窗都能显示一直离线」。
  ///
  /// 这条是**廉价的展示口径**（UI 每帧都在读，不能每次都问 FFI）。
  /// 真正要「交给 Rust 去发」之前，必须再用 [_rustConnected] 核一次 —— 见
  /// [_effectivelyOnline]。
  bool _isOnline(String peerId) => chatOnline[peerId] ?? false;

  /// Rust 侧现在有没有该 peer 的活连接？`null` = 问不到（桥不可用/测试无注入）。
  ///
  /// 与 [_verifyPresenceWithRust] 同一份数据源，但按 peer 精确问。
  bool? _rustConnected(String peerId) {
    final override = debugConnectedPeersForTest;
    if (override != null) return override.contains(peerId);
    try {
      return ChatService.instance
          .sessions()
          .any((s) => s.peerId == peerId && s.connected);
    } catch (_) {
      return null; // 桥未就绪：当作「不知道」，保持从宽
    }
  }

  /// 「现在可以把东西交给 Rust 去发了吗」——发送路径专用。
  ///
  /// 在展示口径 [_isOnline] 之上补一次**单向**核对：Rust 明确说没有活连接时
  /// 一律按离线处理（走发件箱排队），并把过期的在线标记纠正掉。
  ///
  /// 为什么必须加这一道（用户反馈「PC 发送离线正常，手机离线发送失败 0%」）：
  /// 安卓进程被冻结时会**错过** `disconnected` 事件，`chatOnline` 就停在过期的
  /// true 上。这时发文件会走「在线」分支 → 交给 Rust → 往死 socket 发 → Rust 报
  /// IO 错误 → 界面「失败 0%」。PC 端在前台能及时收到断开事件，所以同样的操作
  /// 走的是排队分支、表现正常 —— 这正是「PC 正常、手机失败」的差别。
  ///
  /// 只查一次（每次发送一次 FFI），不进 [_isOnline] —— 那个每帧都在读。
  bool _effectivelyOnline(String peerId) {
    if (!_isOnline(peerId)) return false;
    if (_rustConnected(peerId) == false) {
      // Rust 说没连上：把过期标记纠正掉（顺便让重连提示能正常出现）
      _setOnline(peerId, false);
      return false;
    }
    return true;
  }

  /// 按指定会话发一条文本（离线补发/转发用）。
  ///
  /// [addBubble] = true 时会把气泡加进该会话（转发后双方都要看得到）；
  /// 离线补发时传 false —— 那条消息本来就在列表里，**要就地替换成落库那条**。
  Future<rust_chat.MessageDto?> sendTextTo(
    String peerId,
    String text, {
    bool addBubble = true,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    // addBubble=false 时也要拿到会话：离线补发必须把列表里那条「排队中」的
    // 乐观气泡换成落库后的真实消息（见下面 replace 分支）。
    // 但**不要**用 conversationFor —— 它不存在时会新建一个空会话，
    // 给一个没有会话的对端补发会凭空多出一行。只找已存在的。
    Conversation? conv;
    if (addBubble) {
      conv = conversationFor(peerId);
    } else {
      for (final c in conversations) {
        if (c.device.id == peerId) {
          conv = c;
          break;
        }
      }
    }
    ChatMessage? optimistic;
    if (conv != null && addBubble) {
      final now = DateTime.now();
      optimistic = ChatMessage(
        id: 'pending-fwd-${now.microsecondsSinceEpoch}',
        fromMe: true,
        kind: MessageKind.text,
        time: now,
        text: trimmed,
        state: SendState.sending,
      );
      conv.messages.add(optimistic);
      conv.lastTsMs = now.millisecondsSinceEpoch;
      notifyListeners();
    }
    try {
      await ensureDial(peerId);
      final saved = await ChatService.instance.sendText(
        peerId: peerId,
        senderId: DiscoveryService.instance.deviceId,
        text: trimmed,
      );
      if (conv != null) {
        final real = _toChatMessage(saved)..state = SendState.sent;
        if (optimistic != null) {
          final idx = conv.messages.indexOf(optimistic);
          if (idx >= 0) {
            conv.messages[idx] = real;
          } else {
            conv.messages.add(real);
          }
        } else {
          // 离线补发（addBubble=false）：把那条排队中的乐观气泡**就地换成**
          // 落库消息。
          //
          // 不换的话它一直带着 `pending-<微秒>` 这个 id 留在列表里，而存储里
          // 已经有真实 id 的副本了；下一次 loadHistory（_syncAfterConnect 会强制
          // 拉一次）发现存储那条 id 不在列表里 → `list.add(m)` → **出现两个气泡**
          // （用户反馈「离线发送文字两个气泡」）。
          final idx = conv.messages.lastIndexWhere((m) =>
              m.fromMe &&
              m.kind == MessageKind.text &&
              m.id.startsWith('pending-') &&
              m.text == trimmed);
          if (idx >= 0) {
            conv.messages[idx] = real;
          } else {
            conv.messages.add(real);
          }
        }
        conv.lastTsMs = real.time.millisecondsSinceEpoch;
        notifyListeners();
      }
      return saved;
    } catch (_) {
      if (optimistic != null) {
        optimistic.state = SendState.failed;
        optimistic.failed = true;
        notifyListeners();
      }
      return null;
    }
  }

  /// 长按「重发」：先移除失败的那条，再按同一文本重发。
  Future<void> retryMessage(ChatMessage msg) async {
    final conv = activeConversation;
    if (conv == null) return;
    final text = msg.text;
    conv.messages.remove(msg);
    notifyListeners();
    await sendMessage(text);
  }

  /// 删除一条消息：内存 + **磁盘存储**都清掉。
  ///
  /// 之前只改内存（`_removedMsgIds` 是进程内 Set，重启即空），而 Rust 的
  /// JSONL 里那条还在 —— 重启一读文件就又回来了（用户反馈的「取消/删除
  /// 的气泡重启后又出现」）。现在直接从存储里删。
  void deleteMessage(ChatMessage msg) {
    final conv = activeConversation;
    if (conv == null) return;
    final peerId = conv.device.id;
    _removedMsgIds.add(msg.id); // 重载历史时不要再拉回来
    conv.messages.remove(msg);
    for (final list in _history.values) {
      list.remove(msg);
    }
    _removeFromStore(peerId, msg.id);
    notifyListeners();
  }

  /// 从磁盘存储里删掉一条消息（尽力而为：失败时内存已删，界面不受影响）。
  void _removeFromStore(String peerId, String msgId) {
    if (peerId.isEmpty || msgId.isEmpty) return;
    if (msgId.startsWith('pending')) return; // 乐观消息从未落库，无需删
    try {
      unawaited(ChatService.instance.remove(peerId, msgId).catchError((_) => false));
    } catch (_) {
      // 桥接未就绪：忽略（内存里已经摘掉了）
    }
  }

  /// 重发失败的文件消息（依赖 filePath；换过文件就取不回了，只能重新选）。
  Future<void> retryTransfer(ChatMessage msg) async {
    if (msg.filePath.isEmpty) {
      chatError = '文件原位置不可用，请重新选择发送';
      notifyListeners();
      return;
    }
    final conv = activeConversation;
    conv?.messages.remove(msg);
    notifyListeners();
    await sendFilePath(msg.filePath, kind: msg.kind);
  }

  // ------------------------------------------------------------
  // Seed data
  // ------------------------------------------------------------

  void _seed() {
    final now = DateTime.now();
    devices.addAll([
      LanDevice(
        id: 'dev-pc',
        name: 'DESKTOP-ORION',
        ip: '192.168.1.23',
        platform: DevicePlatform.windows,
        online: true,
        paired: true,
        rttMs: 3,
      ),
      LanDevice(
        id: 'dev-phone',
        name: 'Pixel 7',
        ip: '192.168.1.41',
        platform: DevicePlatform.android,
        online: true,
        paired: true,
        rttMs: 11,
      ),
      LanDevice(
        id: 'dev-tablet',
        name: 'Galaxy Tab S8',
        ip: '192.168.1.57',
        platform: DevicePlatform.android,
        online: true,
        paired: false,
        rttMs: 18,
      ),
      LanDevice(
        id: 'dev-laptop',
        name: 'LAPTOP-AIR',
        ip: '192.168.1.66',
        platform: DevicePlatform.windows,
        online: false,
        paired: false,
      ),
    ]);

    final c0 = Conversation(
      device: devices[1],
      unread: 2,
      messages: [
        ChatMessage(
          id: 's1',
          fromMe: false,
          kind: MessageKind.text,
          time: now.subtract(const Duration(hours: 3)),
          text: '安装包我下好了，你那边能装吗？',
        ),
        ChatMessage(
          id: 's2',
          fromMe: true,
          kind: MessageKind.text,
          time: now.subtract(const Duration(hours: 3, minutes: 2)),
          text: '可以，等我这边跑完测试就装',
          state: SendState.delivered,
        ),
        ChatMessage(
          id: 's3',
          fromMe: false,
          kind: MessageKind.text,
          time: now.subtract(const Duration(hours: 2, minutes: 58)),
          text: '好的，发你了',
        ),
        ChatMessage(
          id: 's4',
          fromMe: false,
          kind: MessageKind.file,
          time: now.subtract(const Duration(hours: 2, minutes: 57)),
          fileName: 'client_setup_v1.2.0.apk',
          fileSize: 48 * 1024 * 1024,
          progress: 1,
        ),
        ChatMessage(
          id: 's5',
          fromMe: false,
          kind: MessageKind.text,
          time: now.subtract(const Duration(minutes: 42)),
          text: '对了，记得开热点的话要关掉 AP 隔离，不然互相发现不了',
        ),
        ChatMessage(
          id: 's6',
          fromMe: false,
          kind: MessageKind.text,
          time: now.subtract(const Duration(minutes: 41)),
          text: '测试截图.png',
        ),
      ],
    );
    // Replace the placeholder text with an image message.
    c0.messages.removeLast();
    c0.messages.add(ChatMessage(
      id: 's6',
      fromMe: false,
      kind: MessageKind.image,
      time: now.subtract(const Duration(minutes: 41)),
      fileName: '测试截图.png',
    ));
    c0.messages.add(ChatMessage(
      id: 's7',
      fromMe: true,
      kind: MessageKind.text,
      time: now.subtract(const Duration(minutes: 40)),
      text: '收到，我先看下发现逻辑',
      state: SendState.delivered,
    ));

    final c1 = Conversation(
      device: devices[0],
      messages: [
        ChatMessage(
          id: 't1',
          fromMe: false,
          kind: MessageKind.text,
          time: now.subtract(const Duration(days: 1, hours: 2)),
          text: '这次的会议纪要',
        ),
        ChatMessage(
          id: 't2',
          fromMe: false,
          kind: MessageKind.file,
          time: now.subtract(const Duration(days: 1, hours: 2, minutes: 1)),
          fileName: '局域网传输方案_讨论.docx',
          fileSize: 236 * 1024,
          progress: 1,
        ),
        ChatMessage(
          id: 't3',
          fromMe: true,
          kind: MessageKind.text,
          time: now.subtract(const Duration(days: 1, hours: 1)),
          text: '嗯，断点续传那块我补充了状态机图',
          state: SendState.delivered,
        ),
      ],
    );

    conversations.addAll([c0, c1]);
  }
}
