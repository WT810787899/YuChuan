import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rust_flutter_ui/app_state.dart';
import 'package:rust_flutter_ui/appearance.dart';
import 'package:rust_flutter_ui/main.dart';
import 'package:rust_flutter_ui/models.dart';
import 'package:rust_flutter_ui/ui/chat_page.dart';
import 'package:rust_flutter_ui/ui/files_page.dart';
import 'package:rust_flutter_ui/ui/linkify.dart';
import 'package:rust_flutter_ui/ui/pairing_dialog.dart';
import 'package:rust_flutter_ui/ui/settings_page.dart';

/// 「雨传」移动端体验任务的回归覆盖：
/// 文件 TAB（图标视图/排序）、链接识别、外观整合进设置、返回栈、取消发送。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // AppState 是进程内单例，逐条用例复位 chatError。
  //
  // 前面某条用例会留下非空 chatError（如「删除联系人」走到 clearHistory 时
  // ChatService 未初始化 → 记下「清空记录失败」）。chatError 现在是**常驻
  // 诊断状态**（通知层不再替它清场），所以下一条用例一起壳，OSD 桥就会把这份
  // 残留当成新错误弹一次，留下 2 秒 pending timer 被 binding 判死。
  // 这不是产品缺陷，是用例间共享单例的卫生问题 —— 在这里统一复位。
  setUp(() => AppState.instance.chatError = '');

  group('文件 TAB', () {
    testWidgets('渲染标题/排序入口/视图切换，且空目录不崩', (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: FilesPage())));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('文件'), findsWidgets);
      expect(find.byTooltip('排序方式'), findsOneWidget,
          reason: '文件页需要排序方式入口');
      expect(find.byTooltip('切换列表视图'), findsOneWidget,
          reason: '默认网格视图，可切列表');
      expect(tester.takeException(), isNull);
    });
  });

  group('链接识别', () {
    testWidgets('识别 http/www 链接并渲染成可点击片段', (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const text = '看这个 https://space.bilibili.com/80192671 和 www.example.com/a。';
      expect(findLinks(text).map((l) => l.url).toList(),
          ['https://space.bilibili.com/80192671', 'https://www.example.com/a']);

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: EdgeInsets.all(16),
            child: LinkifiedText(text: text, color: Colors.black),
          ),
        ),
      ));
      await tester.pump();
      expect(find.byType(RichText), findsOneWidget);
    });
  });

  group('设置页', () {
    testWidgets('子页面分栏：左侧分区导航，右侧内容；各分区可点开', (tester) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SettingsPage())));
      await tester.pump(const Duration(milliseconds: 300));

      // 宽屏：左侧分区导航
      expect(find.text('主题与壁纸'), findsWidgets);
      expect(find.text('界面'), findsOneWidget);
      expect(find.text('通知'), findsOneWidget);
      expect(find.text('传输'), findsOneWidget);
      expect(find.text('关于'), findsOneWidget);
      // 默认分区 = 主题与壁纸：主题色可自定义 + 壁纸开关
      expect(find.text('主题色'), findsOneWidget);
      expect(find.text('自定义'), findsWidgets);
      expect(find.text('启用壁纸'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 切到传输分区：接收目录
      await tester.tap(find.text('传输').last);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('接收目录'), findsOneWidget);

      // 切到关于分区：作者信息
      await tester.tap(find.text('关于').last);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('作者'), findsOneWidget);
      expect(find.text('B站：音乐制作王某人'), findsOneWidget);
    });
  });

  group('安卓返回栈', () {
    testWidgets('在设置 TAB 按返回应回到消息 TAB，而不是退出应用', (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState.instance;
      state.conversations.clear();
      state.selectedConversation = null;
      state.navIndex = 0;
      state.onboardingActive = false;

      await tester.pumpWidget(const YuChuanApp());
      await tester.pump(const Duration(milliseconds: 300));

      // 进入设置 TAB
      await tester.tap(find.text('设置'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.navIndex, 4);

      // 返回手势/键
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 300));

      expect(state.navIndex, 0,
          reason: '返回应该先回到消息 TAB，而不是直接退出应用');
    });
  });


  group('聊天时间线与消息菜单', () {
    testWidgets('反转列表 + 按时间升序：最新在底部，且所有类型消息都上屏', (tester) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final base = DateTime(2026, 10, 11, 10, 0);
      final conv = Conversation(
        device: LanDevice(
          id: 'dev-line',
          name: '时间线机',
          ip: '192.168.1.7',
          platform: DevicePlatform.windows,
        ),
        messages: [
          ChatMessage(
              id: 'm1',
              fromMe: false,
              kind: MessageKind.text,
              time: base,
              text: '最早的文本'),
          ChatMessage(
              id: 'm2',
              fromMe: true,
              kind: MessageKind.file,
              time: base.add(const Duration(minutes: 1)),
              fileName: '报告.pdf',
              fileSize: 2048,
              progress: 1),
          ChatMessage(
              id: 'm3',
              fromMe: false,
              kind: MessageKind.text,
              time: base.add(const Duration(minutes: 2)),
              text: '最新的文本'),
        ],
      );
      final state = AppState.instance;
      state.conversations
        ..clear()
        ..add(conv);
      state.selectedConversation = 0;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ChatPage(peerId: 'dev-line')),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      final list = tester.widget<ListView>(find.byType(ListView));
      expect(list.reverse, isTrue, reason: '反转列表：最新消息贴底');
      // 三种消息类型都要显示出来
      expect(find.text('最早的文本'), findsOneWidget);
      expect(find.text('最新的文本'), findsOneWidget);
      expect(find.text('报告.pdf'), findsOneWidget);
    });

    testWidgets('长按消息弹出带图标的操作菜单', (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final conv = Conversation(
        device: LanDevice(
          id: 'dev-menu',
          name: '菜单机',
          ip: '192.168.1.8',
          platform: DevicePlatform.android,
        ),
        messages: [
          ChatMessage(
            id: 'mm1',
            fromMe: false,
            kind: MessageKind.text,
            time: DateTime.now(),
            text: '记得看 https://space.bilibili.com/80192671',
          ),
        ],
      );
      final state = AppState.instance;
      state.conversations
        ..clear()
        ..add(conv);
      state.selectedConversation = 0;

      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Scaffold(body: ChatPage(peerId: 'dev-menu')),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      // 链接文本是 RichText（可点击片段），按内容定位后长按
      final bubble = find.byWidgetPredicate(
          (w) => w is RichText && w.text.toPlainText().contains('space.bilibili.com'));
      expect(bubble, findsOneWidget);
      await tester.longPress(bubble);
      await tester.pumpAndSettle();

      expect(find.text('复制'), findsOneWidget);
      expect(find.byIcon(Icons.copy_outlined), findsOneWidget,
          reason: '菜单条目要带图标');
      expect(find.text('打开链接'), findsOneWidget);
      expect(find.byIcon(Icons.link), findsOneWidget);
    });
  });

  group('取消发送', () {
    test('pending 阶段也能取消，且取消后气泡直接消失（不留失败样式）', () async {
      final state = AppState.instance;
      final conv = Conversation(
        device: LanDevice(
          id: 'dev-cancel',
          name: '取消测试机',
          ip: '192.168.1.99',
          platform: DevicePlatform.windows,
        ),
        messages: [],
      );
      state.conversations
        ..clear()
        ..add(conv);
      state.selectedConversation = 0;

      final msg = ChatMessage(
        id: 'pending-cancel-1',
        fromMe: true,
        kind: MessageKind.file,
        time: DateTime.now(),
        fileName: 'big.zip',
        fileSize: 1024,
        state: SendState.sending,
        progress: 0,
        filePath: '',
      );
      conv.messages.add(msg);

      await state.cancelTransfer(msg);

      expect(msg.cancelled, isTrue, reason: '要标记为用户取消');
      expect(msg.failed, isFalse, reason: '取消不该显示「发送失败」样式');
      expect(conv.messages.contains(msg), isFalse,
          reason: '取消的气泡要从聊天里移走');
    });
  });


  group('删除与演示数据', () {
    test('删除联系人后消息列表无残留', () async {
      final state = AppState.instance;
      // conversationFor 会同时把 peer 记进内存历史（残留最容易出现在这里）
      state.conversations.clear();
      state.conversationFor('dev-del');
      state.selectedConversation = null;
      expect(state.conversations.any((c) => c.device.id == 'dev-del'), isTrue);

      await state.removeContact('dev-del');

      expect(state.conversations.any((c) => c.device.id == 'dev-del'), isFalse,
          reason: '删除联系人后会话行必须消失');
      expect(state.pairedContacts.any((c) => c.deviceId == 'dev-del'), isFalse);
    });

    test('真实后端上线后不再显示演示设备', () {
      final state = AppState.instance;
      expect(state.devices.any((d) => d.id == 'dev-phone'), isTrue,
          reason: '演示模式下应有种子设备');
      state.enableBackend();
      expect(state.devices.any((d) => d.id == 'dev-phone'), isFalse,
          reason: '真实后端上线后必须清掉测试列表');
    });
  });

  group('链接颜色与新消息提醒', () {
    testWidgets('气泡里的链接是蓝色', (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: LinkifiedText(
            text: '看 https://space.bilibili.com/80192671',
            color: Colors.black,
          ),
        ),
      ));
      await tester.pump();

      final rich = tester.widget<RichText>(find.byType(RichText));
      final link = (rich.text as TextSpan)
          .children!
          .whereType<TextSpan>()
          .firstWhere((s) => s.text?.contains('https') ?? false);
      expect(link.style?.color, const Color(0xFF1E40AF),
          reason: '浅底链接必须是深蓝色');
    });

    testWidgets('不在会话里时来消息会弹 OSD 提示条', (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final state = AppState.instance;
      state.conversations.clear();
      state.selectedConversation = null;
      state.navIndex = 0;
      state.onboardingActive = false;
      state.dismissNotice();

      await tester.pumpWidget(const YuChuanApp());
      await tester.pump(const Duration(milliseconds: 300));

      // 模拟收到一条来自 dev-notice 的消息
      state.conversationFor('dev-notice');
      state.noticePeerId = 'dev-notice';
      state.noticeName = '通知测试机';
      state.noticeText = '你好呀';
      state.noticeSeq++;
      state.notifyListeners();
      await tester.pump(const Duration(milliseconds: 300));

      // 顶部横幅已删除（用户要求），提醒改走 OSD：发送人与摘要合成一条文案
      expect(find.byType(MaterialBanner), findsNothing);
      expect(find.text('通知测试机：你好呀'), findsOneWidget,
          reason: 'OSD 提示条要显示发送人 + 内容摘要');

      // OSD 是瞬时提示：2 秒后自行消失（旧横幅要手动关，语义已变）
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('通知测试机：你好呀'), findsNothing,
          reason: 'OSD 是瞬时提示，不应常驻');

      // 清掉待提示状态，避免污染后续用例（旧横幅靠点击消费，现在没有这个入口）
      state.dismissNotice();
      await tester.pump(const Duration(milliseconds: 300));
    });
  });


  group('配对操作窗口', () {
    testWidgets('应答方弹「确认/拒绝」，角色未知时也是应答方界面', (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final state = AppState.instance;
      state.conversations.clear();
      state.selectedConversation = null;
      state.onboardingActive = false;
      state.pairingSucceeded = false;
      state.pairingError = null;
      state.pairingPeerId = 'dev-pair';
      state.pairingPin = '123456';
      state.pairingRole = null; // 角色还没回填
      state.pairingActive = true;
      state.notifyListeners();
      await tester.pumpWidget(const YuChuanApp());
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(find.text('确认配对'), findsOneWidget,
          reason: '应答方（含角色未知）必须给确认入口，不能弹成发起配对');
      expect(find.text('拒绝'), findsOneWidget);
      expect(find.textContaining('等待对方确认'), findsNothing);

      // 成功 → 播动画 → 配对结束 → 窗口必须自己关掉
      state.pairingSucceeded = true;
      state.pairingPin = null;
      state.notifyListeners();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('配对成功'), findsOneWidget);

      state.finishPairingAnimation();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(find.byType(PairingDialog), findsNothing,
          reason: '配对结束后弹窗必须自动关闭，不能卡住界面');
      // 等成功动画(900ms)与「卡住兜底」(4s)的定时器都走完
      await tester.pump(const Duration(seconds: 5));
    });
  });


  group('底部 TAB 选中态', () {
    testWidgets('切 TAB 后选中态必须跟着变（回归：const 子树被跳过重建）', (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final state = AppState.instance;
      state.conversations.clear();
      state.selectedConversation = null;
      state.onboardingActive = false;
      state.navIndex = 0;

      await tester.pumpWidget(const YuChuanApp());
      await tester.pump(const Duration(milliseconds: 300));

      // 消息：选中 → 实心图标
      expect(find.byIcon(Icons.chat_bubble), findsOneWidget);
      expect(find.byIcon(Icons.chat_bubble_outline), findsNothing);

      // 切到设备
      await tester.tap(find.text('设备'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.navIndex, 1);
      expect(find.byIcon(Icons.devices), findsOneWidget,
          reason: '设备 TAB 必须显示选中态实心图标');
      expect(find.byIcon(Icons.devices_other), findsNothing);
      expect(find.byIcon(Icons.chat_bubble), findsNothing,
          reason: '上一个 TAB 的选中态要取消');

      // 切到文件
      await tester.tap(find.text('文件'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byIcon(Icons.folder), findsOneWidget);
      expect(find.byIcon(Icons.folder_outlined), findsNothing);

      // 切到设置
      await tester.tap(find.text('设置'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byIcon(Icons.settings), findsOneWidget);
      expect(find.byIcon(Icons.settings_outlined), findsNothing);
    });
  });


  group('深浅色独立记忆与返回栈', () {
    test('切换深浅色时，壁纸/主题色参数各自独立', () {
      final a = AppearanceState.instance;
      // 浅色：绿色主题 + 不透明度 1
      a.setDarkLook(false);
      a.setSeedColor(const Color(0xFF10B981));
      a.setWallpaperOpacity(1);

      // 深色：改成蓝色 + 半透明
      a.setDarkLook(true);
      a.setSeedColor(const Color(0xFF3B82F6));
      a.setWallpaperOpacity(0.5);
      expect(a.seedColor, const Color(0xFF3B82F6));
      expect(a.wallpaperOpacity, 0.5);

      // 切回浅色：参数应当恢复成浅色那套
      a.setDarkLook(false);
      expect(a.seedColor, const Color(0xFF10B981),
          reason: '浅色下的主题色要独立记住');
      expect(a.wallpaperOpacity, 1);
    });

    testWidgets('文件页返回：有选中时先取消选中，没有才交回上层', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final state = AppState.instance;
      state.onboardingActive = false;
      state.navIndex = 3;

      await tester.pumpWidget(const YuChuanApp());
      await tester.pump(const Duration(milliseconds: 400));

      final handler = state.backHandler;
      expect(handler, isNotNull, reason: '文件页应注册返回处理');
      expect(handler!(), isFalse,
          reason: '没有选中时应交回上层（切回消息 TAB）');
    });
  });

  group('聊天窗顶栏返回箭头', () {
    testWidgets('安卓窄屏：返回箭头紧贴左缘，不占 48 宽的点击盒', (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final state = AppState.instance;
      state.onboardingActive = false;
      final dev = LanDevice(
          id: 'dev-arrow',
          name: '箭头机',
          ip: '192.168.1.9',
          platform: DevicePlatform.android);
      state.conversations
        ..clear()
        ..add(Conversation(
          device: dev,
          messages: [
            ChatMessage(
              id: 'arrow-1',
              fromMe: false,
              kind: MessageKind.text,
              text: '嗨',
              time: DateTime(2026, 1, 1, 10, 0),
              progress: 1,
            ),
          ],
        ));
      state.selectedConversation = 0;

      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: ChatPage(peerId: 'dev-arrow'))));
      await tester.pump(const Duration(milliseconds: 300));

      // 不带横线的返回箭头：纯文本 ‹（U+2039）在 IconButton 里，不是图标组件。
      final arrowText = find.text('‹');
      expect(arrowText, findsOneWidget, reason: '窄屏聊天窗应有返回箭头（‹ 纯文本）');

      // 测位置：箭头容器紧贴 header 左 padding（14）。
      final arrowBtn = find.ancestor(of: arrowText, matching: find.byType(IconButton)).first;
      final box = tester.getRect(arrowBtn);
      expect(box.left, lessThanOrEqualTo(18),
          reason: '箭头应往左靠：图标左缘距屏幕左缘不超过 18 逻辑像素，实际 ${box.left}');
    });
  });

  group('文件 TAB 选中跟手', () {
    testWidgets('AppState 连发通知不会反复全量扫盘', (tester) async {
      final dir = Directory.systemTemp.createTempSync('yuchuan_files_');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
        AppearanceState.instance.setReceiveDir(null);
      });
      for (var i = 0; i < 3; i++) {
        File('${dir.path}${Platform.pathSeparator}报告$i.pdf')
            .writeAsStringSync('x' * (16 * (i + 1)));
      }

      final ap = AppearanceState.instance;
      ap.setReceiveDir(dir.path);
      final state = AppState.instance;
      state.onboardingActive = false;

      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: FilesPage())));
      await tester.pumpAndSettle();
      expect(find.text('报告0.pdf'), findsOneWidget);

      // 记住当前瓦片文本的 widget 身份：只有整页数据被重建才会换新实例。
      final before = tester.widget<Text>(find.text('报告1.pdf'));

      // 连发 5 次 AppState 通知（模拟传输进度/设备上下线等高频事件）。
      for (var i = 0; i < 5; i++) {
        state.notifyListeners();
      }
      await tester.pump();

      final after = tester.widget<Text>(find.text('报告1.pdf'));
      expect(identical(before, after), isTrue,
          reason: 'AppState 通知不应重建整页文件瓦片（否则点选必卡）');

      // 且合并/节流不能丢更新：新落盘的文件最终必须出现在列表里。
      File('${dir.path}${Platform.pathSeparator}新到的.pdf')
          .writeAsStringSync('new');
      state.notifyListeners();
      // 等 microtask 合并的那次扫盘跑完（Future.microtask 比下一帧更早）。
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('新到的.pdf'), findsOneWidget,
          reason: '节流后仍必须反映目录新增的文件');
    });
  });

  group('深色模式对端气泡', () {
    testWidgets('深色下对端文本气泡提亮一档，且文字仍清晰', (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final state = AppState.instance;
      state.onboardingActive = false;
      final dev = LanDevice(
        id: 'dev-dark',
        name: '深色机',
        ip: '192.168.1.11',
        platform: DevicePlatform.android,
      );
      state.conversations
        ..clear()
        ..add(Conversation(
          device: dev,
          messages: [
            ChatMessage(
              id: 'dark-1',
              fromMe: false,
              kind: MessageKind.text,
              text: '深色对端',
              time: DateTime(2026, 1, 1, 10, 0),
              progress: 1,
            ),
          ],
        ));
      state.selectedConversation = 0;

      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: const Scaffold(body: ChatPage(peerId: 'dev-dark')),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      // 气泡底：文字节点最近的、带非透明纯色装饰的祖先容器。
      final base = find
          .ancestor(
            of: find.text('深色对端'),
            matching: find.byWidgetPredicate((w) =>
                w is Container &&
                w.decoration is BoxDecoration &&
                (w.decoration as BoxDecoration).color != null &&
                (w.decoration as BoxDecoration).color!.a > 0.9),
          )
          .first;
      final bubbleColor =
          (tester.widget<Container>(base).decoration as BoxDecoration).color!;

      // 旧值 0xFF26272F：必须严格更亮。
      expect(bubbleColor, isNot(const Color(0xFF26272F)));
      expect(bubbleColor.computeLuminance(),
          greaterThan(const Color(0xFF26272F).computeLuminance()),
          reason: '深色对端气泡底色应比旧的 0xFF26272F 更亮，实际 $bubbleColor');

      // 文字仍是近白色 onSurface：与气泡底色的对比度不低于 7:1。
      final textColor = tester.widget<Text>(find.text('深色对端')).style!.color!;
      final lighter = textColor.computeLuminance() > bubbleColor.computeLuminance()
          ? textColor
          : bubbleColor;
      final darker = identical(lighter, textColor) ? bubbleColor : textColor;
      final ratio = (lighter.computeLuminance() + 0.05) /
          (darker.computeLuminance() + 0.05);
      expect(ratio, greaterThan(7.0),
          reason: '气泡提亮后文字对比度仍需 ≥7:1，实际 ${ratio.toStringAsFixed(2)}');
    });
  });

  group('聊天窗气泡多选', () {
    testWidgets('进入多选后每个气泡旁有勾选圈，点气泡可追加选中', (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final conv = Conversation(
        device: LanDevice(
          id: 'dev-select',
          name: '多选机',
          ip: '192.168.1.21',
          platform: DevicePlatform.android,
        ),
        messages: [
          ChatMessage(
            id: 's1',
            fromMe: false,
            kind: MessageKind.text,
            text: '对端一条',
            time: DateTime(2026, 1, 1, 10, 0),
            progress: 1,
          ),
          ChatMessage(
            id: 's2',
            fromMe: true,
            kind: MessageKind.text,
            text: '本端一条',
            time: DateTime(2026, 1, 1, 10, 1),
            progress: 1,
          ),
          ChatMessage(
            id: 's3',
            fromMe: false,
            kind: MessageKind.file,
            fileName: '多选文件.pdf',
            fileSize: 1024,
            time: DateTime(2026, 1, 1, 10, 2),
            progress: 1,
          ),
        ],
      );
      final state = AppState.instance;
      state.conversations
        ..clear()
        ..add(conv);
      state.selectedConversation = 0;

      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: const Scaffold(body: ChatPage(peerId: 'dev-select')),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      // 进入多选：长按调出菜单 → 点「多选」。
      await tester.longPress(find.text('对端一条'));
      await tester.pumpAndSettle();
      expect(find.text('多选'), findsOneWidget);
      await tester.tap(find.text('多选'));
      await tester.pumpAndSettle();

      final ringPredicate = find.byWidgetPredicate((w) =>
          w is AnimatedContainer &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).shape == BoxShape.circle);
      expect(ringPredicate, findsWidgets,
          reason: '多选模式下每个气泡旁都要有勾选圈');

      // 勾选圈必须在**内侧**（远离头像那一侧）：
      // 对端消息（头像在左）圈在气泡右边；本端消息（头像在右）圈在气泡左边。
      // 按行取圈（reverse 列表下 tree order 不可靠，逐行断言）。
      final peerRow = find
          .ancestor(of: find.text('对端一条'), matching: find.byType(Row))
          .first;
      final peerRingCenter = tester.getCenter(
          find.descendant(of: peerRow, matching: ringPredicate).first);
      final peerTextCenter = tester.getCenter(find.text('对端一条'));
      expect(peerRingCenter.dx, greaterThan(peerTextCenter.dx),
          reason: '对端气泡：勾选圈要在气泡右侧（内侧），不能在头像那边');
      final meRow = find
          .ancestor(of: find.text('本端一条'), matching: find.byType(Row))
          .first;
      final meRingCenter = tester.getCenter(
          find.descendant(of: meRow, matching: ringPredicate).first);
      final meTextCenter = tester.getCenter(find.text('本端一条'));
      expect(meRingCenter.dx, lessThan(meTextCenter.dx),
          reason: '本端气泡：勾选圈要在气泡左侧（内侧），不能在头像那边');

      // **勾选框本身也能点选**：此时只有「对端一条」被菜单选中，
      // 点「本端一条」行的勾选圈 → 应追加一条选中。
      final checksBefore = tester.widgetList(find.byIcon(Icons.check)).length;
      await tester.tap(
          find.descendant(of: meRow, matching: ringPredicate).first);
      await tester.pumpAndSettle();
      expect(tester.widgetList(find.byIcon(Icons.check)).length,
          greaterThan(checksBefore),
          reason: '点勾选框也要能追加选中');

      // 点一下「对端一条」气泡本体 → 已在选中态，数量不降（安卓只加不减）。
      await tester.tap(find.text('对端一条'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check), findsWidgets,
          reason: '点选后应有已选中的实心勾');

      var checked = tester.widgetList(find.byIcon(Icons.check)).length;
      expect(checked, greaterThanOrEqualTo(2),
          reason: '点选可追加：两条都应处于选中态');

      // 进入多选后，**文件卡片单击 = 选中**（不再是打开）。
      await tester.tap(find.text('多选文件.pdf'));
      await tester.pumpAndSettle();
      checked = tester.widgetList(find.byIcon(Icons.check)).length;
      expect(checked, greaterThanOrEqualTo(3),
          reason: '多选模式下单击文件卡片要追加选中，而不是打开文件');
    });
  });

  group('手机端文件气泡宽度', () {
    testWidgets('窄屏文件气泡不超过对方头像（不顶破右边界）', (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final conv = Conversation(
        device: LanDevice(
          id: 'dev-file',
          name: '文件气泡机',
          ip: '192.168.1.31',
          platform: DevicePlatform.android,
        ),
        messages: [
          ChatMessage(
            id: 'f1',
            fromMe: false,
            kind: MessageKind.file,
            fileName: '很长的文件名用来撑宽度测试.pdf',
            fileSize: 4096,
            time: DateTime(2026, 1, 1, 10, 0),
            progress: 1,
          ),
        ],
      );
      final state = AppState.instance;
      state.conversations
        ..clear()
        ..add(conv);
      state.selectedConversation = 0;

      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: const Scaffold(body: ChatPage(peerId: 'dev-file')),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      // 文件卡片：宽度由 _FileBubble 控制，应是带圆角的 AnimatedContainer。
      final cardFinder = find
          .byWidgetPredicate((w) =>
              w is AnimatedContainer &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).borderRadius != null)
          .first;
      final cardW =
          tester.renderObject<RenderBox>(cardFinder).size.width;
      // 手机端必须明显收短（用户反馈旧版「完全没做」= 仍 320 顶满屏）：
      // 公式 min(屏宽 - 两侧 padding 32 - 两个头像列 84, 280)；
      // 412 屏 → 280。断言上限 280，旧值 320 必须失败。
      expect(cardW, lessThanOrEqualTo(280),
          reason: '手机端文件气泡要收短、不超过对方头像列，实际宽 $cardW');
    });
  });
}

