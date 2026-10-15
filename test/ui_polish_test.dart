import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rust_flutter_ui/app_state.dart';
import 'package:rust_flutter_ui/models.dart';
import 'package:rust_flutter_ui/ui/chat_page.dart';
import 'package:rust_flutter_ui/ui/onboarding_page.dart';

/// M5 体验打磨的自动化覆盖：
/// 1) T5.1 图片气泡——有本地文件时用 Image.file 渲染（不是占位渐变），Hero 全屏可缩放；
/// 2) T5.5 首次使用引导——onboardingNeeded 时出现、点「开始体验」后消失。
void main() {
  testWidgets('图片气泡用真实文件渲染', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 造一张真实 PNG（1x1 红点）
    final tmp = Directory.systemTemp.createTempSync('img_bubble');
    final imgPath = '${tmp.path}${Platform.pathSeparator}photo.png';
    File(imgPath).writeAsBytesSync(_tinyPng());

    final device = LanDevice(
      id: 'dev-x',
      name: '图片设备',
      ip: '192.168.1.50',
      platform: DevicePlatform.windows,
      online: true,
      paired: true,
      chatPort: 45998,
    );
    final conv = Conversation(device: device, messages: []);
    conv.messages.add(ChatMessage(
      id: 'img-1',
      fromMe: false,
      kind: MessageKind.image,
      time: DateTime.now(),
      fileName: 'photo.png',
      filePath: imgPath,
      progress: 1, // 已完成 → 不显示进度遮罩
    ));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ChatPage(peerId: 'dev-x')),
    ));
    // conversationFor 找不到会建空会话；手动塞进 conversations 再渲染
    AppState.instance.conversations
      ..clear()
      ..add(conv);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ChatPage(peerId: 'dev-x')),
    ));
    await tester.pump(const Duration(milliseconds: 400));

    // 应有 Image.file（真实渲染），而不是只有渐变占位
    expect(find.byType(Image), findsWidgets);

    // 点开全屏预览（Hero + InteractiveViewer）
    await tester.tap(find.byType(Image).first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(InteractiveViewer), findsOneWidget,
        reason: '预览应支持缩放');
    await tester.pumpAndSettle();
    tmp.deleteSync(recursive: true);
  });

  testWidgets('全屏首次引导：多页切换 + 开始使用关闭', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var done = false;
    await tester.pumpWidget(MaterialApp(
      home: OnboardingPage(onDone: () => done = true),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    // 首页标题
    expect(find.text('自动发现附近设备'), findsOneWidget);
    expect(find.text('继续'), findsOneWidget);
    expect(find.text('跳过引导'), findsNothing); // 跳过是 tooltip，非文本

    // 点「继续」翻到下一页
    await tester.tap(find.text('继续'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('核对 PIN，安全配对'), findsOneWidget);

    // 最后一页应为「开始使用」，点击触发 onDone
    await tester.tap(find.text('继续'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('拖进去就传文件'), findsOneWidget);
    expect(find.text('开始使用'), findsOneWidget);

    await tester.tap(find.text('开始使用'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(done, isTrue, reason: '最后一屏「开始使用」应触发 onDone');
  });
}

/// 极小合法 PNG（1×1 红色像素）。
Uint8List _tinyPng() => Uint8List.fromList(<int>[
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG 签名
      0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR
      0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
      0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, // IDAT
      0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
      0x00, 0x00, 0x03, 0x00, 0x01, 0x6A, 0x82, 0x65,
      0x5D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, // IEND
      0x44, 0xAE, 0x42, 0x60, 0x82,
    ]);
