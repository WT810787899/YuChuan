import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_flutter_ui/src/rust/api/pairing.dart' as rust;
import 'package:rust_flutter_ui/src/rust/frb_generated.dart';

/// T2.2 验收：配对表持久化（走真实 Dart ↔ Rust 桥接）。
///
/// 「重启 App 后联系人仍在」在这里等价于：关掉配对表后重新 open 同一个数据目录。
/// 运行前需要先构建过一次原生库（scripts/build_windows.ps1）。
void main() {
  setUpAll(() async {
    await RustLib.init(externalLibrary: _nativeLibrary());
  });

  test('联系人跨重启保留、地址历史并入、删除落盘', () async {
    final dir = Directory.systemTemp.createTempSync('lanchat_pairing_store').path;

    final first = await rust.pairingOpen(dataDir: dir);
    expect(first.contactCount, 0);
    expect(first.recoveredFromCorruption, isFalse);
    expect(first.storePath.endsWith('contacts.json'), isTrue);

    final saved = await rust.pairingConfirmLocal(
      deviceId: 'dev-it',
      name: '测试手机',
      platform: 'android',
      addr: '192.168.1.88',
    );
    expect(saved.name, '测试手机');
    expect(saved.addrHistory, ['192.168.1.88']);
    expect(rust.pairingIsPaired(deviceId: 'dev-it'), isTrue);

    // 模拟重启：重新打开同一目录
    final reopened = await rust.pairingOpen(dataDir: dir);
    expect(reopened.contactCount, 1, reason: '重启后联系人必须还在');
    final contacts = rust.pairingContacts();
    expect(contacts.single.deviceId, 'dev-it');
    expect(contacts.single.platform, 'android');

    // 发现到新地址 → 并入地址历史（M3 建连按序尝试）
    expect(
      await rust.pairingTouchAddr(deviceId: 'dev-it', addr: '10.0.0.9'),
      isTrue,
    );
    expect(rust.pairingContacts().single.addrHistory.first, '10.0.0.9');

    // 删除要落盘
    expect(await rust.pairingRemove(deviceId: 'dev-it'), isTrue);
    expect((await rust.pairingOpen(dataDir: dir)).contactCount, 0);

    // 磁盘上确实有这个文件（人可读 JSON）
    final file = File('$dir${Platform.pathSeparator}contacts.json');
    expect(file.existsSync(), isTrue);
    expect(file.readAsStringSync(), contains('"version"'));
  });

  test('PIN 配对会话：发起 → 对端接受 → 写入联系人', () async {
    final dir = Directory.systemTemp.createTempSync('lanchat_pairing_flow').path;
    await rust.pairingOpen(dataDir: dir);
    await rust.pairingReset();

    final started = await rust.pairingStart(
      peerId: 'dev-flow',
      peerName: '笔记本',
      peerPlatform: 'windows',
      peerAddr: '192.168.1.66',
    );
    expect(started.session.state, rust.PairStateDto.waitingResponse);
    expect(started.session.role, rust.PairRoleDto.initiator);
    final pin = started.session.pin;
    expect(pin, isNotNull);
    expect(rust.pairingIsValidPin(pin: pin!), isTrue);
    expect(started.session.remainingMs, rust.pairingTimeoutMs());
    expect(started.sendRequest, isNotNull, reason: '应产出要发的 PAIR_REQ');
    expect(started.sendRequest!.deviceId, 'dev-flow');
    expect(started.sendRequest!.pin, pin);

    // 对端接受（M3 收到 PAIR_RESP 时走同一个入口）
    final done = await rust.pairingResponseReceived(accepted: true);
    expect(done.session.state, rust.PairStateDto.paired);
    expect(done.contact, isNotNull, reason: '配对成功应写入联系人');
    expect(done.contact!.addrHistory, ['192.168.1.66']);
    expect(rust.pairingIsPaired(deviceId: 'dev-flow'), isTrue);

    // 已配对设备再次发起 → 幂等，不再产生 PAIR_REQ
    final again = await rust.pairingStart(
      peerId: 'dev-flow',
      peerName: '笔记本',
      peerPlatform: 'windows',
      peerAddr: '192.168.1.66',
    );
    expect(again.session.state, rust.PairStateDto.paired);
    expect(again.sendRequest, isNull);

    await rust.pairingRemove(deviceId: 'dev-flow');
    await rust.pairingReset();
  });

  test('非法 PIN 被拒绝且不建会话', () async {
    await rust.pairingReset();
    final outcome = await rust.pairingReceiveRequest(
      peerId: 'dev-bad',
      peerName: '冒名设备',
      peerPlatform: 'android',
      pin: '12ab',
      peerAddr: null,
    );
    expect(outcome.session.state, rust.PairStateDto.failed);
    expect(outcome.session.failure, rust.PairFailureDto.invalidPin);
    expect(outcome.sendResponse, isNotNull);
    expect(outcome.sendResponse!.accepted, isFalse);
    expect(rust.pairingSession()?.state, rust.PairStateDto.failed);
    await rust.pairingReset();
  });
}

ExternalLibrary _nativeLibrary() {
  if (Platform.isWindows) {
    // 必须优先用 rust_builder 刚编出来的那份：build/ 下的是上一次 Windows
    // 构建留下的陈旧副本，加载它会导致 frb 内容哈希不一致（Dart/Rust 侧对不上）。
    final candidates = [
      'rust_builder/target/release/rust_flutter_ui_native.dll',
      'build/windows/x64/runner/Release/rust_flutter_ui_native.dll',
    ];
    for (final candidate in candidates) {
      final file = File(candidate);
      if (file.existsSync()) return ExternalLibrary.open(file.absolute.path);
    }
    fail('找不到 rust_flutter_ui_native.dll，请先运行 scripts/build_windows.ps1');
  }
  return ExternalLibrary.open('librust_flutter_ui_native.so');
}
