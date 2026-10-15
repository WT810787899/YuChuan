import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rust_flutter_ui/app_state.dart';
import 'package:rust_flutter_ui/models.dart';
import 'package:rust_flutter_ui/ui/chat_page.dart';

/// 回归：手机端进入聊天窗**不要**自动聚焦输入框（否则一进会话就弹软键盘，
/// 挡住聊天内容）。桌面端保持「打开会话即可直接打字」。
///
/// 用 `ThemeData(platform:)` fake 平台 —— autofocus 判断走
/// `Theme.of(context).platform`（见 chat_page.dart _InputBar）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void seedConversation() {
    final state = AppState.instance;
    state.conversations
      ..clear()
      ..add(Conversation(
        device: LanDevice(
          id: 'dev-focus',
          name: '焦点机',
          ip: '192.168.1.50',
          platform: DevicePlatform.android,
        ),
        messages: [],
      ));
    state.selectedConversation = 0;
    state.onboardingActive = false;
  }

  Future<TextField> pumpChat(
      WidgetTester tester, TargetPlatform platform) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    seedConversation();
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(platform: platform),
      home: Scaffold(body: ChatPage(peerId: 'dev-focus')),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    return tester.widgetList<TextField>(find.byType(TextField)).first;
  }

  testWidgets('安卓：进入聊天窗输入框不自动聚焦（不自动弹键盘）', (tester) async {
    final field = await pumpChat(tester, TargetPlatform.android);
    expect(field.autofocus, isFalse,
        reason: '手机进会话就弹键盘会挡住聊天内容');
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面：打开会话仍自动聚焦，可直接打字', (tester) async {
    final field = await pumpChat(tester, TargetPlatform.windows);
    expect(field.autofocus, isTrue);
  });
}
