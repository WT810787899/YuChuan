import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rust_flutter_ui/main.dart';
import 'package:rust_flutter_ui/app_state.dart';

/// 应用壳冒烟：YuChuanApp 能渲染出导航壳与会话列表面板
/// （原文件是 flutter create 的计数器模板，引用不存在的 MyApp，从未通过过）。
void main() {
  testWidgets('应用壳渲染：导航 + 会话列表面板', (WidgetTester tester) async {
    // 宽屏（≥900dp 双栏）：默认测试视口 800px 是窄屏布局，会直接进会话页
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const YuChuanApp());
    // 启动过渡 + 首帧
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(Shell), findsOneWidget);
    expect(find.text('搜索联系人或消息'), findsOneWidget,
        reason: '会话列表面板应渲染出搜索框');

    // 演示数据里至少有一个会话可点（种子数据）
    expect(AppState.instance.conversations, isNotEmpty);

    // 切到设备页：发现面板（含本机卡片占位）
    AppState.instance.setNavIndex(1);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('设备发现'), findsOneWidget);
    expect(find.textContaining('本机'), findsWidgets,
        reason: '本机卡片应显示');
  });
}
