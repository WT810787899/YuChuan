import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rust_flutter_ui/app_state.dart';
import 'package:rust_flutter_ui/main.dart';
import 'package:rust_flutter_ui/ui/onboarding_page.dart';

/// 安卓端回归：点完首次使用引导后，必须回到带底部导航的主界面。
///
/// 真实链路里 enableChat() → rebuildConversations() 会用「真实但为空」的会话
/// 列表替换掉种子数据，而构造函数里「恢复上次会话」留下的
/// selectedConversation=1 变成越界索引 —— 窄屏 Shell 把它当成
/// 「深层详情」，于是隐藏底部 TAB、渲染空内容 → 引导结束后一片空白且无处可去。
void main() {
  testWidgets('引导结束后回到带底部导航的会话列表（不是死路空屏）', (tester) async {
    tester.view.physicalSize = const Size(412, 915); // Pixel 类手机逻辑分辨率
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = AppState.instance;
    // 模拟真机首次启动：后端重建后会话为空，但选中索引仍是种子期的 1。
    state.conversations.clear();
    state.selectedConversation = 1;
    state.onboardingActive = true;

    await tester.pumpWidget(const YuChuanApp());
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(OnboardingPage), findsOneWidget);

    // 走完 4 页引导
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.text(i == 3 ? '开始使用' : '继续'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
    }

    expect(find.byType(OnboardingPage), findsNothing,
        reason: '引导应已关闭');
    expect(find.byType(BottomNavBar), findsOneWidget,
        reason: '引导结束后必须回到带底部导航的主界面，不能卡在无导航的空屏');
    expect(find.text('搜索联系人或消息'), findsOneWidget,
        reason: '应显示会话列表（含搜索框）');
  });
}
