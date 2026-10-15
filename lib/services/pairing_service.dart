import 'package:rust_flutter_ui/src/rust/api/pairing.dart' as rust;

/// 配对与联系人（T2.1 / T2.2）的 Dart 封装。
///
/// 状态机与配对表都在 Rust（可单测），这里只做三件事：打开配对表、驱动会话、
/// 把联系人读写转成 Dart 调用。传输层是 M3 的事，本机联调时状态机可以单向走完。
class PairingService {
  PairingService._();

  static final PairingService instance = PairingService._();

  String? _storePath;
  bool _opened = false;

  /// 配对表文件路径（UI 自检展示）。
  String? get storePath => _storePath;

  /// 是否真的打开了磁盘上的配对表（false = 只能内存态，重启会丢）。
  bool get opened => _opened;

  /// 打开配对表；重启后联系人还在的关键。幂等。
  Future<rust.PairingStatusDto> open(String? dataDir) async {
    if (_opened) return rust.pairingStatus();
    if (dataDir == null || dataDir.isEmpty) {
      return const rust.PairingStatusDto(
        storePath: '',
        contactCount: 0,
        recoveredFromCorruption: false,
      );
    }
    final status = await rust.pairingOpen(dataDir: dataDir);
    _storePath = status.storePath;
    _opened = true;
    return status;
  }

  List<rust.PairedContactDto> contacts() => rust.pairingContacts();

  bool isPaired(String deviceId) => rust.pairingIsPaired(deviceId: deviceId);

  Future<rust.PairedContactDto> confirmLocal({
    required String deviceId,
    required String name,
    required String platform,
    String? addr,
  }) =>
      rust.pairingConfirmLocal(
        deviceId: deviceId,
        name: name,
        platform: platform,
        addr: addr,
      );

  Future<bool> remove(String deviceId) =>
      rust.pairingRemove(deviceId: deviceId);

  /// 发现到已配对设备时刷新地址历史（M3 建连按序尝试）。
  Future<bool> touchAddr({required String deviceId, required String addr}) =>
      rust.pairingTouchAddr(deviceId: deviceId, addr: addr);

  /// 发起配对（生成 6 位 PIN）。
  Future<rust.PairOutcomeDto> start({
    required String peerId,
    required String peerName,
    required String peerPlatform,
    String? peerAddr,
  }) =>
      rust.pairingStart(
        peerId: peerId,
        peerName: peerName,
        peerPlatform: peerPlatform,
        peerAddr: peerAddr,
      );

  /// 应答方：收到对端 PAIR_REQ（M3 由 TCP 会话层调用）。
  Future<rust.PairOutcomeDto> receiveRequest({
    required String peerId,
    required String peerName,
    required String peerPlatform,
    required String pin,
    String? peerAddr,
  }) =>
      rust.pairingReceiveRequest(
        peerId: peerId,
        peerName: peerName,
        peerPlatform: peerPlatform,
        pin: pin,
        peerAddr: peerAddr,
      );

  /// 发起方：收到对端 PAIR_RESP（M3 由会话事件送达）。
  Future<rust.PairOutcomeDto> responseReceived(bool accepted) =>
      rust.pairingResponseReceived(accepted: accepted);

  Future<rust.PairOutcomeDto> confirm() => rust.pairingConfirm();

  Future<rust.PairOutcomeDto> reject() => rust.pairingReject();

  Future<rust.PairOutcomeDto> cancel() => rust.pairingCancel();

  /// 倒计时到点（触发状态机的 60s 超时）。
  Future<rust.PairOutcomeDto> tick() => rust.pairingTick();

  int get timeoutMs => rust.pairingTimeoutMs();

  bool isValidPin(String pin) => rust.pairingIsValidPin(pin: pin);
}
