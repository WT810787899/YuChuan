import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rust_flutter_ui/app_state.dart';
import 'package:rust_flutter_ui/appearance.dart';
import 'package:rust_flutter_ui/main.dart';

/// 顶部横幅已删除，通知统一走 OSD 胶囊（修 bug.md：去掉顶部提示横幅，所用通知走 OSD）。
///
/// 两个私有横幅类（`_ConnectionBanner` / `_NewMessageBanner`）无法 `find.byType`，
/// 所以这里断言的是**行为**：
///   - 旧横幅渲染在 `Shell` 子树内，新通知必须由 Overlay 里的 OSD 承载；
///   - `chatError` 是**常驻状态**（`chat_page` / `settings_page` 的内联诊断和
///     `main.dart` 的 diag 采样都在读它），OSD 只是**瞬时通知** → 胶囊 2 秒后必须
///     消失，但 `AppState.chatError` 必须**留着**（诊断通道不能被通知层掐断）；
///   - 去重游标只在「条件恢复」（`chatError` 被清空）后复位 → 连发同一条错误不刷屏，
///     恢复后同一条错误还能再弹。
/// 只断言「错误文案还在」抓不到 bug（旧横幅里也有同样文案），必须靠
/// 「在 Shell 子树内消失 + 2 秒后消失 + 状态仍可读 + 游标可复位」这四条区分。
void main() {
  /// 起壳：宽屏（≥900dp）双栏布局，与 widget_test 的冒烟口径一致。
  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const YuChuanApp());
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// 走完 OSD 的 2 秒自动消失 Timer。
  ///
  /// 必须在测试体内 pump 掉：binding 的 `_verifyInvariants()` 检查「还有 pending
  /// timer」，且它跑在 `addTearDown` **之前**，放 tearDown 里已经太迟。
  Future<void> drainOsd(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// 模拟「不在会话里时收到一条新消息」：置位 notice 状态并推进 seq。
  void incoming(AppState state, String text) {
    state.conversationFor('dev-notice');
    state.noticePeerId = 'dev-notice';
    state.noticeName = '通知测试机';
    state.noticeText = text;
    state.noticeSeq++;
    state.notifyListeners();
  }

  /// 把新消息提醒的前置状态摆成「不在会话里」。
  Future<void> pumpShellAwayFromChat(
      WidgetTester tester, AppState state) async {
    state.conversations.clear();
    state.selectedConversation = null;
    state.navIndex = 0;
    state.onboardingActive = false;
    state.dismissNotice();
    await tester.pump(const Duration(milliseconds: 300));
  }

  setUp(() {
    // AppState / AppearanceState 是进程内单例，逐条用例复位，避免互相污染
    final s = AppState.instance;
    s.chatError = '';
    s.dismissNotice();
  });

  testWidgets('错误文案改走 OSD：离开 Shell 子树、2 秒即散，但 chatError 诊断状态仍在',
      (tester) async {
    await pumpShell(tester);
    final state = AppState.instance;

    state.setChatError('模拟错误');
    await tester.pump(const Duration(milliseconds: 300));

    // ① 框架的 MaterialBanner 从未用过，这里钉死「不许用它替代横幅」
    expect(find.byType(MaterialBanner), findsNothing);
    // ② 旧横幅是 Shell 子树里的一行；通知改走 OSD 后（OSD 挂在 Navigator 的
    //    Overlay 上，是 Shell 的祖先层），Shell 子树内不该再有这条错误文案
    expect(
      find.descendant(of: find.byType(Shell), matching: find.text('模拟错误')),
      findsNothing,
      reason: '顶部横幅必须整体删除，通知只能由 Overlay 里的 OSD 承载',
    );
    // ③ 但错误文案本身仍然可见 —— 只是容器换成了 OSD 胶囊
    expect(find.text('模拟错误'), findsOneWidget,
        reason: '错误必须仍然可见，只是改走 OSD');
    // ④ Finding 1 回归护栏：OSD 只是**瞬时通知**，`chatError` 是**常驻状态**
    //    （内联诊断 + diag 文件的 chat_error= 都读它）。通知层绝不能替它清场，
    //    否则 settings/chat 的占位永远回落成「聊天链路启动中…」、diag 永远空串。
    expect(state.chatError, '模拟错误',
        reason: '弹出 OSD 之后 chatError 必须仍然可读：诊断通道不能被通知层掐断');

    // ⑤ 关键语义差异：旧 chatError 常驻到用户手动关闭，OSD 是 2 秒瞬时提示
    await drainOsd(tester);
    expect(find.text('模拟错误'), findsNothing,
        reason: 'OSD 是瞬时提示，不能像旧横幅那样一直挂在顶部');
    // ⑥ 胶囊消失后诊断状态依然在 —— 这正是「不再从桥里清空」要保住的行为
    expect(state.chatError, '模拟错误',
        reason: 'OSD 散场不等于错误消失，chatError 必须继续可读');
  });

  testWidgets('同一错误连发不重复弹 OSD（防刷屏），恢复后同一文案会重新弹',
      (tester) async {
    await pumpShell(tester);
    final state = AppState.instance;

    // (a) 首次置位：必须弹一次
    state.setChatError('模拟错误');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('模拟错误'), findsOneWidget,
        reason: '错误出现必须弹 OSD');

    await drainOsd(tester);
    expect(find.text('模拟错误'), findsNothing, reason: '第一条 OSD 应已自动消失');

    // (b) 条件没变、文案没变：故意**不**再弹（防刷屏）。
    //     若有人把去重游标在弹出后复位（例如又去清空 chatError），这里会多弹一条。
    state.setChatError('模拟错误');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('模拟错误'), findsNothing,
        reason: '同一条错误在条件未恢复前连发，不允许刷屏式重弹');

    // (c) 条件恢复：app 在聊天成功启动/发送成功时会清空 chatError（dismissConnectionBanner
    //     是同一路径的公开入口）。清空会复位游标 —— 证明游标不会永久卡死。
    state.dismissConnectionBanner();
    await tester.pump(const Duration(milliseconds: 300));
    expect(state.chatError, isEmpty, reason: '恢复后 chatError 应为空');

    state.setChatError('模拟错误');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('模拟错误'), findsOneWidget,
        reason: '恢复后同一条错误再次出现必须重新弹 OSD（游标已复位，没被卡死）');

    await drainOsd(tester);
  });

  testWidgets('新消息提醒走 OSD，且设置里的开关仍然能关掉它', (tester) async {
    await pumpShell(tester);
    final state = AppState.instance;
    final appearance = AppearanceState.instance;
    addTearDown(() => appearance.setNoticeBannerEnabled(true));

    await pumpShellAwayFromChat(tester, state);

    // 开关打开：弹 OSD（发送人 + 内容摘要）
    appearance.setNoticeBannerEnabled(true);
    incoming(state, '你好呀');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('通知测试机'), findsOneWidget,
        reason: '新消息提醒要显示发送人');
    expect(find.textContaining('你好呀'), findsOneWidget,
        reason: '新消息提醒要显示内容摘要');
    await drainOsd(tester);

    // 开关关闭：同样的新消息不再提示（设置开关必须保持原语义）
    appearance.setNoticeBannerEnabled(false);
    incoming(state, '第二条');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('第二条'), findsNothing,
        reason: '设置里的「新消息提醒」开关必须仍然生效');
    expect(find.textContaining('通知测试机'), findsNothing);

    await drainOsd(tester);
  });

  testWidgets('开关关闭期间到达的消息被静默消费：打开开关后不会补弹陈旧提醒',
      (tester) async {
    await pumpShell(tester);
    final state = AppState.instance;
    final appearance = AppearanceState.instance;
    addTearDown(() => appearance.setNoticeBannerEnabled(true));

    await pumpShellAwayFromChat(tester, state);

    // 开关关着时来了一条消息：不提示（开关语义），但这条消息必须被「消费」掉
    appearance.setNoticeBannerEnabled(false);
    incoming(state, '旧消息');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('旧消息'), findsNothing,
        reason: '开关关闭时不提示');

    // 用户随后打开开关：这条已经过期的消息不能再补弹成新鲜提醒
    appearance.setNoticeBannerEnabled(true);
    state.notifyListeners();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('旧消息'), findsNothing,
        reason: '开关关闭期间到达的旧消息已被消费，打开开关不得补弹');

    // 非空洞性护栏：开关打开后**真正的新消息**必须照常弹 ——
    // 证明上面的 findsNothing 不是因为桥接整体失效 / 开关永远为假
    incoming(state, '新消息');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('新消息'), findsOneWidget,
        reason: '开关打开后真正的新消息必须照常提示');

    await drainOsd(tester);
  });
}
