import 'dart:async';
import 'dart:io';

import 'package:rust_flutter_ui/src/rust/api/discovery.dart' as rust;

import 'platform_channel.dart';

/// 发现服务的 Dart 侧封装（T1.3）。
///
/// - 邻居事件由 Rust 主动推送（不是 Dart 轮询），AppState 订阅后驱动设备页；
/// - 手动直连（T1.2 AP 隔离兜底）走 [addPeer]，对端会立刻收到一份 HELLO；
/// - 本机身份（device_id / 设备名）在 [prepare] 里解析并落盘：id 持久化后重启仍是
///   同一台设备，设备名在 Windows 取 COMPUTERNAME、Android 取 Build.MODEL。
class DiscoveryService {
  DiscoveryService._();

  static final DiscoveryService instance = DiscoveryService._();

  /// 本机 TCP 聊天端口（M3 起由 session 模块真正监听）。
  static const int defaultChatPort = 45998;

  /// UDP 发现端口：与 Rust 端 DEFAULT_DISCOVERY_PORT 一致（固定端口才能收到组播 /
  /// 广播 HELLO）。socket 已开 SO_REUSEADDR，同机双实例联调也能互见。
  static const int defaultListenPort = 45999;

  /// 本机 TCP 聊天端口：LANCHAT_CHAT_PORT 可覆盖 —— 同机跑第二个实例时 TCP 不能
  /// 复用同一端口（没有 SO_REUSEADDR），必须给它换一个（如 45997）。
  static int get chatPort =>
      int.tryParse(Platform.environment['LANCHAT_CHAT_PORT'] ?? '') ??
      defaultChatPort;

  String? _deviceId;
  String? _deviceName;
  String? _identityPath;
  String? _dataDir;
  bool _multicastLockHeld = false;

  /// 应用数据目录（Windows: %APPDATA%/YuChuan；Android: 应用私有目录）。
  /// 配对表 contacts.json 也放这里（T2.2）。null = 拿不到目录（退化为不持久）。
  String? get dataDir => _dataDir;

  /// 稳定的本机设备 id（未 prepare 时为占位值）。
  String get deviceId => _deviceId ?? 'unprepared';

  String get deviceName => _deviceName ?? '雨传设备';

  /// device_id 落盘位置（UI 自检展示：确认身份是否持久化）。
  String? get identityPath => _identityPath;

  /// Android 组播锁是否已持有（风险3）。
  bool get multicastLockHeld => _multicastLockHeld;

  bool get running => rust.discoveryIsRunning();

  /// 同机多实例联调标记：LANCHAT_INSTANCE=2 时用独立身份（id 文件与设备名都带后缀）。
  ///
  /// 设备 id 是「每台机器一份」并持久化的，所以同一台机器上跑两个进程会共用同一个
  /// id —— 双方都会把对方的 HELLO 当成自己发出的而过滤掉（实测 hellos_received=0）。
  /// 真实场景里两台设备各自持久化，id 天然不同；同机联调才需要这个开关。
  static String get instanceTag =>
      (Platform.environment['LANCHAT_INSTANCE'] ?? '').trim();

  /// 解析本机身份并落盘；Android 上同时申请组播锁。启动发现前调用（幂等）。
  Future<void> prepare() async {
    if (_deviceName != null) return;
    final base = await _resolveName();
    _deviceName = instanceTag.isEmpty ? base : '$base ($instanceTag)';
    _dataDir = await _resolveDataDir();
    _identityPath = _dataDir == null
        ? null
        : [
            _dataDir!,
            instanceTag.isEmpty ? 'device_id' : 'device_id_$instanceTag',
          ].join(Platform.pathSeparator);
    _deviceId = _readOrCreateDeviceId(_identityPath);
    if (Platform.isAndroid) {
      _multicastLockHeld = await YuChuanPlatform.acquireMulticastLock();
    }
  }

  Future<String> _resolveName() async {
    if (Platform.isAndroid) {
      final model = await YuChuanPlatform.deviceName();
      if (model != null && model.trim().isNotEmpty) return model.trim();
    }
    return rust.deviceNameHint();
  }

  /// 数据目录本身（身份 id 与配对表共用一个目录）。
  ///
  /// LANCHAT_DATA_DIR 可覆盖（集成测试用临时目录，避免污染真实联系人）。
  Future<String?> _resolveDataDir() async {
    final override = (Platform.environment['LANCHAT_DATA_DIR'] ?? '').trim();
    if (override.isNotEmpty) return override;
    if (Platform.isAndroid) {
      final base = await YuChuanPlatform.filesDir();
      if (base != null && base.isNotEmpty) return base;
    }
    final home = Platform.environment['APPDATA'] ?? Platform.environment['HOME'];
    if (home == null || home.isEmpty) return null;
    return [home, 'YuChuan'].join(Platform.pathSeparator);
  }

  /// 读回持久化的 device_id，没有就生成并写入（写失败则退化为进程内 id）。
  String _readOrCreateDeviceId(String? path) {
    try {
      if (path != null) {
        final file = File(path);
        if (file.existsSync()) {
          final existing = file.readAsStringSync().trim();
          if (existing.isNotEmpty) return existing;
        }
        final fresh = rust.newDeviceId();
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(fresh);
        return fresh;
      }
    } catch (_) {
      // 权限 / 磁盘异常：不阻塞发现，退化成进程内 id
    }
    return rust.newDeviceId();
  }

  /// 订阅邻居事件流。**必须在 [start] 之前调用**：服务线程启动时就要拿到事件总线。
  Stream<rust.DiscoveryEventDto> events() => rust.discoverySubscribe();

  Future<rust.DiscoveryStatus> start({
    List<String> manualPeers = const [],
    int? chatPort,
    int? listenPort,
    bool filterVirtual = false,
  }) async {
    await prepare();
    return rust.discoveryStart(
      settings: rust.DiscoverySettings(
        deviceId: deviceId,
        name: deviceName,
        platform: rust.discoveryPlatform(),
        chatPort: chatPort ?? DiscoveryService.chatPort,
        listenPort: listenPort ?? defaultListenPort,
        manualPeers: manualPeers,
        filterVirtual: filterVirtual,
      ),
    );
  }

  Future<bool> stop() async {
    final wasRunning = await rust.discoveryStop();
    if (Platform.isAndroid && _multicastLockHeld) {
      await YuChuanPlatform.releaseMulticastLock();
      _multicastLockHeld = false;
    }
    return wasRunning;
  }

  /// 当前在线邻居快照（UI 首帧可用，之后靠事件流增量更新）。
  List<rust.DeviceInfo> devices() => rust.discoveryDevices();

  rust.DiscoveryStatus status() => rust.discoveryStatus();

  /// 运行计数 + 参与发现的本机网卡（空列表自检文案用）。
  rust.DiscoveryStatsDto stats() => rust.discoveryStats();

  /// 参与发现的本机网卡，形如 "以太网 7=192.168.1.191/24"。
  List<String> interfaces() => rust.discoveryInterfaces();

  /// 手动直连兜底，返回规范化后的 ip:port。
  Future<String> addPeer(String hostPort) =>
      rust.discoveryAddPeer(hostPort: hostPort);

  /// 立刻重发一轮 HELLO（UI「重新发现」）。
  Future<void> announce() => rust.discoveryAnnounce();
}
