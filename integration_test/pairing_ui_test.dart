import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rust_flutter_ui/app_state.dart';
import 'package:rust_flutter_ui/main.dart' as app;
import 'package:rust_flutter_ui/models.dart';
import 'package:rust_flutter_ui/src/rust/api/pairing.dart' as rust_pairing;

/// M2 端到端 UI 回归（真实应用 + 真实 Rust 后端）：
/// 1) 发起方：PIN 来自 Rust 状态机，只能等对端 PAIR_RESP，不得单方面写入联系人；
/// 2) 应答方：收到 PAIR_REQ → 显示 PIN → 用户确认 → 回 PAIR_RESP + 联系人落盘；
/// 3) 「重启」= 重新解析磁盘上的 contacts.json，联系人必须还在。
///
/// 运行（Windows）：
///   $env:LANCHAT_DATA_DIR = "$env:TEMP\lanchat_it"
///   flutter test integration_test/pairing_ui_test.dart -d windows
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('配对端到端：发起方等待 / 应答方确认落库 / 重启读回', (tester) async {
    final dataDir = Platform.environment['LANCHAT_DATA_DIR'];
    expect(dataDir, isNotNull, reason: '需要设置 LANCHAT_DATA_DIR（测试用临时目录）');
    final dir = dataDir!;
    final store = File('$dir${Platform.pathSeparator}contacts.json');
    if (store.existsSync()) store.deleteSync();

    // 真实启动路径（RustLib.init / 发现服务 / 配对表载入）
    await app.main();
    // 注意：发现中雷达动画常驻，不能用 pumpAndSettle
    await tester.pump(const Duration(milliseconds: 600));

    final state = AppState.instance;
    await state.loadPairingStore();
    expect(state.pairingStoreOpened, isTrue, reason: '配对表应已打开');
    expect(state.pairingStorePath.endsWith('contacts.json'), isTrue);

    // 一台待配对设备（发现链路已由 discovery 的测试覆盖）
    state.devices.clear();
    state.devices.add(LanDevice(
      id: 'dev-ui',
      name: 'UI 测试机',
      ip: '192.168.1.123',
      platform: DevicePlatform.windows,
      online: true,
    ));
    state.setNavIndex(1);
    await tester.pump(const Duration(milliseconds: 400));

    // 进入设备详情
    await tester.tap(find.text('UI 测试机').first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('开始配对'), findsOneWidget);

    // ---------- 发起方 ----------
    await tester.tap(find.text('开始配对'));
    await tester.pump(const Duration(milliseconds: 600));
    final initiatorPin = state.pairingPin;
    expect(initiatorPin, isNotNull, reason: 'PIN 应由 Rust 状态机生成');
    expect(initiatorPin!.length, 6);
    expect(rust_pairing.pairingIsValidPin(pin: initiatorPin), isTrue);
    expect(state.pairingIsInitiator, isTrue);
    expect(find.text('已核对 PIN，等待对方确认…'), findsOneWidget);
    expect(find.text('确认配对'), findsNothing,
        reason: '发起方不得单方面把配对点完成（要等 PAIR_RESP）');
    expect(store.existsSync(), isFalse,
        reason: '没收到 PAIR_RESP 之前不该写入联系人');

    await tester.tap(find.text('取消'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('开始配对'), findsOneWidget);
    await state.cancelPairing();

    // ---------- 应答方（M3 由 TCP 收到 PAIR_REQ 后走同一入口）----------
    await state.beginResponderPairing(
      peerId: 'dev-ui',
      peerName: 'UI 测试机',
      platform: 'windows',
      pin: '246810',
      addr: '192.168.1.123',
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.pairingIsResponder, isTrue);
    expect(state.pairingPin, '246810');
    expect(find.text('确认配对'), findsOneWidget);

    await tester.tap(find.text('确认配对'));
    await tester.pump(const Duration(milliseconds: 800));

    expect(state.isPaired('dev-ui'), isTrue, reason: '配对成功后内存里应有该联系人');
    expect(store.existsSync(), isTrue, reason: '配对表必须落盘到数据目录');
    final raw = store.readAsStringSync();
    expect(raw, contains('dev-ui'));
    expect(raw, contains('192.168.1.123'), reason: '地址历史应写入（M3 建连用）');
    expect(raw, isNot(contains('246810')), reason: 'PIN 绝不能落库');

    // ---------- 「重启」：重新解析磁盘 ----------
    final reopened = await rust_pairing.pairingOpen(dataDir: dir);
    expect(reopened.contactCount, 1, reason: '重启读回后联系人必须还在');
    final contacts = rust_pairing.pairingContacts();
    expect(contacts.single.deviceId, 'dev-ui');
    expect(contacts.single.platform, 'windows');
    expect(contacts.single.addrHistory, ['192.168.1.123']);
    expect(rust_pairing.pairingIsPaired(deviceId: 'dev-ui'), isTrue);
  });
}
