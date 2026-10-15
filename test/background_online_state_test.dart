import 'package:flutter_test/flutter_test.dart';

import 'package:rust_flutter_ui/app_state.dart';

/// 回归：批次B1 第 4 条 —— 「PC 端从最小化【非托盘】回到界面，手机端会提示
/// OSD:与PC断开连接,自动重试。这不应该，PC 从未掉过线。」
///
/// 根因（修复前）：`AppState.onAppResumed()` 会**无条件**把所有会话的
/// `chatOnline[id]` 清成 false、并移除拨号冷却。而 `main.dart:471-484` 的
/// `didChangeAppLifecycleState` 在**任何** `AppLifecycleState.resumed` 时都会
/// 调用它 —— 包括「我刚从后台回来但对端一直没断」这种最常见的情况。
/// 于是 `connectionBanner`（lib/app_state.dart:1127-1136）立刻返回
/// 「与 X 的连接已断开，正在自动重连…」，main.dart 的 `_bridgeNotificationsToOsd`
/// 把它推成 OSD 胶囊，用户就看到了那条不该出现的提示。
///
/// 判定语义应当是：**只有在后台被冻结到超过对端超时、确实已经掉线时才清**。
/// 这里用 `AppState.debugMarkPeerStaleForTest` 这个测试口子来分别模拟
/// 「回到前台时连接其实是好的」与「确实冻结超时了」两种情形。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AppState freshState() {
    final s = AppState.instance;
    s.conversations.clear();
    s.chatOnline.clear();
    s.chatError = '';
    s.activePeerId = null;
    s.selectedConversation = null;
    return s;
  }

  /// 造一个「已配对 + 已连上 + 当前正在会话里」的状态，
  /// 与用户真实场景一致（PC 恢复时正停留在与该安卓设备的会话页）。
  AppState connectedConversation(String peerId) {
    final s = freshState();
    final conv = s.conversationFor(peerId);
    s.conversations
      ..clear()
      ..add(conv);
    s.activePeerId = peerId;
    s.selectedConversation = 0;
    // 走到过拨号路径（_dialedAt 有记录）→ connectionBanner 才会考虑这条会话
    s.debugMarkDialedForTest(peerId);
    s.debugSetOnlineForTest(peerId, true);
    return s;
  }

  test('回前台时连接是好的：不得把在线状态清成离线，也不得弹出「已断开」提示',
      () async {
    const peer = 'dev-android';
    final s = connectedConversation(peer);
    expect(s.connectionBanner, isNull, reason: '前置：刚连上时不该有横幅');

    await s.onAppResumed();

    expect(
      s.chatOnline[peer],
      isTrue,
      reason: '对端从未掉线，回前台不该把自己判成离线',
    );
    expect(
      s.connectionBanner,
      isNull,
      reason: '不该出现「与 X 的连接已断开，正在自动重连…」——用户抱怨的那条 OSD',
    );
  });

  test('短暂最小化（离开前台远短于对端超时）回前台：连接状态必须原样保留', () async {
    // 这才是用户描述的真实场景：PC「从最小化状态【非托盘】回到界面」，
    // 通常只离开几秒 —— 远不到对端 PEER_TIMEOUT_MS=10000 的判超时阈值。
    // 修复前 onAppResumed 无条件清在线 + 清 _dialedAt，于是这里会假断线。
    const peer = 'dev-android';
    final s = connectedConversation(peer);

    await s.onAppResumed(backgroundFor: const Duration(seconds: 2));

    expect(
      s.chatOnline[peer],
      isTrue,
      reason: '离开前台 2s 远不到对端 10s 超时阈值，连接不可能已断，不得清在线',
    );
    expect(
      s.connectionBanner,
      isNull,
      reason: '不得弹出假断线 OSD —— 这正是 B1-4 用户抱怨的现象',
    );
    // 也不应触发重拨：对端会看到重复 hello / 新连接。
    // 重拨前会先 `_dialedAt.remove(id)`，所以「拨号记录还在」= 没有重拨。
    expect(
      s.debugHasDialRecordForTest(peer),
      isTrue,
      reason: '连接还活着就不该清拨号记录/重拨，否则对端会看到重复连接',
    );
  });

  test('离开很久后回前台：也不得清在线（Rust 没断开就不算掉线）', () async {
    const peer = 'dev-android';
    final s = connectedConversation(peer);

    // 即使离开 30 分钟：Rust 侧静默只是发 Stalled、**不断开 socket**，
    // 所以那次断开根本没发生。清掉之后没有任何东西会把它设回 true
    // （connected 事件不会重发，在线判定也不再靠递减窗口）→ 永久离线。
    // 这正是用户反馈的「双方在聊天窗都能显示一直离线」。
    await s.onAppResumed(backgroundFor: const Duration(minutes: 30));

    expect(
      s.chatOnline[peer],
      isTrue,
      reason: 'Rust 没断开就不许清 —— 一旦清了就再也不会变回在线',
    );
    expect(s.connectionBanner, isNull, reason: '不该凭空出现假断线提示');
  });

  test('回前台时 Rust 说它没连上：才允许转成离线', () async {
    const peer = 'dev-android';
    final s = connectedConversation(peer);

    AppState.debugConnectedPeersForTest = const <String>{};
    addTearDown(() => AppState.debugConnectedPeersForTest = null);

    await s.onAppResumed();

    expect(
      s.chatOnline[peer],
      isFalse,
      reason: '兜底核对是单向的：只有 Rust 说没连上才清，避免永久停在过期的在线',
    );
  });

  test('没有任何会话时回前台不应抛异常', () async {
    final s = freshState();
    await s.onAppResumed();
    expect(s.conversations, isEmpty);
  });
}
