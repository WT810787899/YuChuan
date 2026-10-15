import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_flutter_ui/app_state.dart';
import 'package:rust_flutter_ui/services/platform_channel.dart';

/// 安卓后台保活通道的契约测试。
///
/// 背景（需求.MD 第 20 行「安卓后台不要断开」）：应用切后台后进程被降优先级/
/// 冻结，纯 Activity 进程的 TCP 连接会断，传输中断。修法是前台服务
/// （见 android/app/src/main/kotlin/com/yuchuan/app/TransferService.kt）。
/// 本文件只测 Dart 侧通道契约，不涉及原生实现。
///
/// 注意：这些方法在非安卓平台会直接早退（不碰通道），而 `Platform.isAndroid`
/// 读的是真实操作系统、测试里伪造不了（`debugDefaultTargetPlatformOverride`
/// 只影响 `defaultTargetPlatform`，不影响它），所以这里用
/// `YuChuanPlatform.isAndroidOverride` 这个测试专用口子。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('yuchuan/platform');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    YuChuanPlatform.isAndroidOverride = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
  });

  tearDown(() {
    YuChuanPlatform.isAndroidOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('startKeepAlive 调用原生前台服务并携带通知文案', () async {
    final ok = await YuChuanPlatform.startKeepAlive(
      title: 'YuChuan 正在传输',
      text: '保持后台传输以免中断',
    );
    expect(ok, isTrue);
    expect(calls.single.method, 'startKeepAlive');
    expect(calls.single.arguments['title'], 'YuChuan 正在传输');
    expect(calls.single.arguments['text'], '保持后台传输以免中断');
  });

  test('startKeepAlive 有兜底文案（调用方不传时不能是空通知）', () async {
    final ok = await YuChuanPlatform.startKeepAlive();
    expect(ok, isTrue);
    expect(calls.single.method, 'startKeepAlive');
    final args = calls.single.arguments as Map;
    expect((args['title'] as String?)?.isNotEmpty, isTrue);
    expect((args['text'] as String?)?.isNotEmpty, isTrue);
  });

  test('stopKeepAlive 调用原生停止前台服务', () async {
    final ok = await YuChuanPlatform.stopKeepAlive();
    expect(ok, isTrue);
    expect(calls.single.method, 'stopKeepAlive');
  });

  test('isKeepAliveRunning 反映原生服务真实状态（状态自愈用）', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'isKeepAliveRunning' ? false : true;
    });
    expect(await YuChuanPlatform.isKeepAliveRunning(), isFalse);
    expect(calls.single.method, 'isKeepAliveRunning');
  });

  test('原生未实现时返回 false 而不是抛异常（桌面端/旧版本兼容）', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      throw MissingPluginException('no impl');
    });
    expect(await YuChuanPlatform.startKeepAlive(), isFalse);
    expect(await YuChuanPlatform.stopKeepAlive(), isFalse);
  });

  // ---- Task 10：前台服务按需使能（忙才开，闲就关，避免白挂常驻通知）----
  //
  // 判定依据是「有没有活干」：有在传的文件，或发件箱里还有排队条目。
  // 这里只驱动 AppState 的判定逻辑，不碰真实传输/发件箱。

  test('有传输时开前台服务', () async {
    final state = AppState.instance;
    await state.debugApplyKeepAlive(busyTransfers: 1, pendingOutbox: 0);
    expect(state.keepAliveOn, isTrue);
    expect(calls.map((c) => c.method), contains('startKeepAlive'));
    expect(calls.map((c) => c.method), isNot(contains('stopKeepAlive')));
  });

  test('传输与发件箱都空时关前台服务', () async {
    final state = AppState.instance;
    await state.debugApplyKeepAlive(busyTransfers: 1, pendingOutbox: 0);
    calls.clear();
    await state.debugApplyKeepAlive(busyTransfers: 0, pendingOutbox: 0);
    expect(state.keepAliveOn, isFalse);
    expect(calls.single.method, 'stopKeepAlive');
  });

  test('没有在传文件但有排队消息时保持开启', () async {
    final state = AppState.instance;
    await state.debugApplyKeepAlive(busyTransfers: 0, pendingOutbox: 3);
    expect(state.keepAliveOn, isTrue);
    expect(calls.map((c) => c.method), contains('startKeepAlive'));
  });

  test('状态没变时不发原生调用（幂等，避免每 400ms 刷一次服务）', () async {
    final state = AppState.instance;
    await state.debugApplyKeepAlive(busyTransfers: 1, pendingOutbox: 0);
    calls.clear();
    await state.debugApplyKeepAlive(busyTransfers: 1, pendingOutbox: 0);
    // 幂等语义（I5 对账后更新）：wanted==on 时允许一次 isKeepAliveRunning
    // 对账查询，但绝不允许再次 start/stop。
    expect(calls.map((c) => c.method), everyElement('isKeepAliveRunning'));
    expect(calls.length, lessThanOrEqualTo(1));
  });

  // ---- B1-4：**纯聊天**（没有传输、没有待发）时切后台也必须保活 ----
  //
  // 用户反馈：「一切到桌面后台，PC 上就显示安卓离线（明明安卓进程还在）」。
  // 根因：以前 `_keepAliveWanted` 只看「传输中 / 发件箱有待发」，纯聊天时切
  // 后台没有任何保活 → Android 冻结进程 → 心跳（3s 一次）停发 → PC 侧
  // PEER_TIMEOUT_MS=10000 一到就判离线。安卓**确实**停止发送了，所以不是
  // PC 误判，要修的是「有活着的会话就要保活」。

  test('纯聊天（有会话在线）且无传输无待发时：仍要开前台服务', () async {
    final state = AppState.instance;
    // AppState 是进程级单例，_keepAliveOn 会被前面的用例带到 true。先显式
    // 归零（无在线会话/无传输/无待发），确保下面测的是**真的从关到开**。
    await state.debugApplyKeepAlive(
      busyTransfers: 0,
      pendingOutbox: 0,
      onlinePeers: const [],
    );
    calls.clear();

    await state.debugApplyKeepAlive(
      busyTransfers: 0,
      pendingOutbox: 0,
      onlinePeers: const ['dev-android'],
    );
    expect(
      state.keepAliveOn,
      isTrue,
      reason: '有会话在线就必须保活，否则切后台被冻结 → PC 显示安卓离线（B1-4）',
    );
    expect(
      calls.map((c) => c.method),
      contains('startKeepAlive'),
      reason: '从空闲转为「有会话在线」应当真的发出 startKeepAlive',
    );
  });

  test('所有会话都离线且无传输无待发时：关掉前台服务（不白挂常驻通知）', () async {
    final state = AppState.instance;
    await state.debugApplyKeepAlive(
      busyTransfers: 0,
      pendingOutbox: 0,
      onlinePeers: const ['dev-android'],
    );
    calls.clear();
    await state.debugApplyKeepAlive(
      busyTransfers: 0,
      pendingOutbox: 0,
      onlinePeers: const [],
    );
    expect(state.keepAliveOn, isFalse, reason: '真正空闲时才该停，避免通知常驻');
    expect(calls.single.method, 'stopKeepAlive');
  });

  test('会话转为离线但仍有传输：不得误停前台服务', () async {
    final state = AppState.instance;
    await state.debugApplyKeepAlive(
      busyTransfers: 0,
      pendingOutbox: 0,
      onlinePeers: const ['dev-android'],
    );
    calls.clear();
    await state.debugApplyKeepAlive(busyTransfers: 1, pendingOutbox: 0);
    expect(state.keepAliveOn, isTrue, reason: '还有文件在传，不能停保活');
    expect(calls.map((c) => c.method), isNot(contains('stopKeepAlive')));
  });

  test('保活判定必须真的由「在线会话」驱动（关掉后重新在线会再次开）', () async {
    final state = AppState.instance;
    await state.debugApplyKeepAlive(
      busyTransfers: 0,
      pendingOutbox: 0,
      onlinePeers: const ['dev-android'],
    );
    expect(state.keepAliveOn, isTrue);

    // 掉线 → 空闲 → 必须关
    await state.debugApplyKeepAlive(
      busyTransfers: 0,
      pendingOutbox: 0,
      onlinePeers: const [],
    );
    expect(state.keepAliveOn, isFalse,
        reason: '没有在线会话也没有活干时不该白挂通知');

    // 再次在线 → 必须重新开（证明「在线会话」这一条真的参与判定，
    // 而不是靠前面用例遗留的 true 蒙混过关）
    calls.clear();
    await state.debugApplyKeepAlive(
      busyTransfers: 0,
      pendingOutbox: 0,
      onlinePeers: const ['dev-android'],
    );
    expect(state.keepAliveOn, isTrue);
    expect(calls.map((c) => c.method), contains('startKeepAlive'));
  });
}
