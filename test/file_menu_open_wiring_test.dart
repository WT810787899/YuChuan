import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rust_flutter_ui/appearance.dart';
import 'package:rust_flutter_ui/services/platform_channel.dart';
import 'package:rust_flutter_ui/services/transfer_service.dart';
import 'package:rust_flutter_ui/ui/files_page.dart';

/// 文件菜单「打开」与「打开方式…」必须走**不同的**平台调用。
///
/// 这是 Task 5 修复轮的回归护栏：上一轮改成「一律弹系统选择器」后，
/// 菜单「打开」不再用系统默认应用打开 —— 纯函数测试（`openCommand`）
/// 抓不到它，因为那测的是命令拼装、不是菜单接线。这里测接线本身。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('yuchuan/platform');
  late List<String> calls;
  late Directory dir;

  setUp(() {
    calls = <String>[];
    dir = Directory.systemTemp.createTempSync('open_semantics_');
    File('${dir.path}${Platform.pathSeparator}a.txt').writeAsStringSync('x');

    // 伪造成安卓：让 openFile / openWithDialog 都走 MethodChannel，
    // 从而既能断言接线，又**不会真的拉起进程**（桌面分支会 Process.start）。
    YuChuanPlatform.isAndroidOverride = true;
    TransferService.downloadDirOverride = () => dir.path;
    AppearanceState.instance.setReceiveDir(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      // listOpenWithApps 的返回类型是 List<Map>：返回 null 会被当成「没有
      // 可打开的应用」，从而弹出一条 OSD 错误（它的 2s 计时器会在测试结束时
      // 仍挂着 → "Timer is still pending"）。
      if (call.method == 'listOpenWithApps') {
        return <Map<String, Object?>>[
          {'package': 'com.example.viewer', 'label': '示例查看器', 'isDefault': true},
        ];
      }
      // openFile / openFileWithChooser / openFileWithPackage 的返回类型是
      // String?（null = 成功）；返回非字符串会触发 _invoke 的类型转换异常，
      // 从而掩盖接线断言。
      return null;
    });
  });

  tearDown(() {
    YuChuanPlatform.isAndroidOverride = null;
    TransferService.downloadDirOverride = null;
    AppearanceState.instance.setReceiveDir(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 长按文件卡片打开菜单，点指定菜单项。
  Future<void> openMenuAndTap(WidgetTester tester, String label) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: FilesPage()),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.longPress(find.text('a.txt'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text(label), findsOneWidget,
        reason: '菜单里应当有「$label」这一项');
    await tester.tap(find.text(label));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('菜单「打开」用系统默认应用，不弹选择器', (tester) async {
    await openMenuAndTap(tester, '打开');
    // 安卓「打开」走自建入口：没有「始终」记忆时列候选，有记忆时直接用记住的应用。
    expect(
      calls.any((m) =>
          m == 'openFile' ||
          m == 'listOpenWithApps' ||
          m == 'openFileWithPackage'),
      isTrue,
      reason: '「打开」必须真的去打开文件',
    );
    expect(calls, isNot(contains('openFileWithChooser')),
        reason: '「打开」不能走系统选择器那条老路径'
            '（Android 11+ 已不提供「仅一次 / 始终」）');
  });

  testWidgets('菜单「打开方式…」弹自建选择窗口（列候选应用）', (tester) async {
    await openMenuAndTap(tester, '打开方式…');
    expect(calls, contains('listOpenWithApps'),
        reason: '安卓「打开方式…」必须列出候选应用，由我们自建窗口问「仅一次 / 始终」'
            '（系统 ResolverActivity 在 Android 11+ 已不再提供那组按钮）');
    expect(calls, isNot(contains('openFile')),
        reason: '「打开方式…」不应退化成默认应用直开');
  });

  /// PC 端「打开方式…」：用户反馈了两轮「毫无响应」。
  ///
  /// 之前的测试全部把 `isAndroidOverride = true`，**PC 分支从来没被跑过**，
  /// 所以它坏了两轮都没人发现。这里不 mock 平台、不 mock 进程，
  /// 直接断言真实行为：菜单点下去必须真的拉起一个进程（系统「打开方式」列表）。
  testWidgets('PC 端「打开方式…」必须真的拉起系统程序列表', (tester) async {
    // 本文件的 setUp 会把平台伪造成安卓（其它用例需要），这里必须显式
    // 置回真实平台，否则 PC 分支根本走不到。
    YuChuanPlatform.isAndroidOverride = null;
    addTearDown(() => YuChuanPlatform.isAndroidOverride = null);

    final spawned = <String>[];
    // 观察 Process.start：只记录，不真正弹窗（避免测试机弹出真实对话框）。
    final prevHook = YuChuanPlatform.processStartHook;
    YuChuanPlatform.processStartHook = (exe, args) async {
      spawned.add([exe, ...args].join(' '));
      return null;
    };
    addTearDown(() => YuChuanPlatform.processStartHook = prevHook);

    await openMenuAndTap(tester, '打开方式…');

    expect(spawned, isNotEmpty,
        reason: 'PC 端「打开方式…」点了必须真的拉起系统「打开方式」程序列表；'
            '本轮用户第二次反馈「毫无响应」');
    final cmd = spawned.first;
    expect(cmd, contains('OpenAs_RunDLLW'),
        reason: 'Windows 的「打开方式」列表来自 shell32 的 **W（Unicode）入口**；'
            'ANSI 的 OpenAs_RunDLL 实测不弹对话框。实际拉起：$cmd');
    expect(cmd, isNot(contains('OpenAs_RunDLL ')),
        reason: '不能再用 ANSI 入口。实际拉起：$cmd');
    expect(cmd, startsWith('rundll32.exe'),
        reason: '直接起 rundll32，不再套 cmd/start（多一层 shell 会重解析命令行，'
            '带空格/中文路径容易被切错）。实际拉起：$cmd');
  });

  /// 用户反馈两次「安卓文件 TAB 的菜单要从 tab 栏上方弹出」。
  ///
  /// 第一轮只改了「下方空间不够时向上翻转」，但真正的原因是**锚点丢了**：
  /// 触屏没有右键，`onSecondaryTapDown` 永不触发 → `_menuPos` 恒为 null →
  /// `showIconMenu` 退回用**触发 widget 的中心**当锚点。文件 TAB 用网格，
  /// 卡片中心在屏幕上半部时，菜单就从上面冒出来 —— 看起来跟 tab 栏无关。
  /// 这个测试断言的是菜单实际落点，纯接线测试抓不到。
  testWidgets('长按文件卡片：菜单落在卡片处（不是从别处冒出来）', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: FilesPage()),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.longPress(find.text('a.txt'));
    await tester.pump(const Duration(milliseconds: 300));

    final menu = find.text('打开');
    expect(menu, findsOneWidget, reason: '前置：长按应弹出菜单');

    // 被长按的那个卡片（"a.txt" 文本所在瓦片）的矩形
    final card = tester.getRect(
      find.ancestor(of: find.text('a.txt'), matching: find.byType(GestureDetector)).first,
    );
    final menuRect = tester.getRect(
      find.ancestor(of: menu, matching: find.byType(Material)).first,
    );
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;

    // 菜单必须离卡片很近：横向重叠，且垂直方向贴着卡片（上或下）
    expect(menuRect.left, lessThan(card.right),
        reason: '菜单不该跑到卡片左边的屏幕外/别处；'
            'card=$card menu=$menuRect');
    expect(menuRect.right, greaterThan(card.left),
        reason: '菜单应与卡片横向重叠；card=$card menu=$menuRect');
    // 菜单必须贴着长按的那张卡片弹出：锚点是卡片中心，菜单从中心向下
    // （或空间不够时向上）展开，因此菜单的 top/bottom 必落在卡片矩形附近。
    // 丢了锚点时 `showIconMenu` 会退回「触发 widget 的中心」，而文件 TAB
    // 网格里那张卡片的中心偏上 → 菜单被挤到屏幕顶部 y=8，离卡片 140+ 像素
    // （用户看到的就是「从顶部弹出」，跟 tab 栏无关）。
    final cardCenterY = card.center.dy;
    final vGap = menuRect.top >= cardCenterY
        ? menuRect.top - cardCenterY
        : cardCenterY - menuRect.bottom;
    expect(vGap, lessThan(60),
        reason: '菜单必须贴着长按的那张卡片弹出（长按丢了锚点时会退到屏幕顶部，'
            '就是用户看到的「从顶部弹出」）；'
            'card=$card menu=$menuRect vGap=$vGap');

    // 底部 tab 栏预留区：菜单绝不能压进去
    final reserve = screen.height - 72;
    expect(menuRect.bottom, lessThanOrEqualTo(reserve + 1),
        reason: '菜单不能压进底部 tab 栏（用户要求：从 tab 栏上方弹出）；'
            'menu=$menuRect reserve=$reserve');
  });

  /// 用户要求：「优化弹出的文件菜单的菜单项排列，关键项用颜色区分」。
  ///
  /// 8 项平铺一列很难扫读。按语义分组后：
  ///   打开类（主题强调色）→ 定位/复制 → 选择类（次级灰）→ 删除（错误色）。
  /// 这个测试锁死分组顺序与色调，避免以后加条目时又退化成一锅粥。
  testWidgets('文件菜单：打开类在最前、删除在最后且用错误色', (tester) async {
    YuChuanPlatform.isAndroidOverride = null;
    addTearDown(() => YuChuanPlatform.isAndroidOverride = null);
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: FilesPage()),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.longPress(find.text('a.txt'));
    await tester.pump(const Duration(milliseconds: 300));

    final scheme = Theme.of(tester.element(find.text('打开'))).colorScheme;
    Color colorOf(String label) =>
        tester.widget<Text>(find.text(label)).style!.color!;

    // 顺序：打开 / 打开方式… / 发送 必须排在 复制路径、全选 之前
    final openY = tester.getCenter(find.text('打开')).dy;
    final openWithY = tester.getCenter(find.text('打开方式…')).dy;
    final sendY = tester.getCenter(find.text('发送')).dy;
    final copyY = tester.getCenter(find.text('复制文件路径')).dy;
    final selectAllY = tester.getCenter(find.text('全选')).dy;
    final deleteY = tester.getCenter(find.text('删除…')).dy;

    expect(openY, lessThan(copyY),
        reason: '「打开」属主操作，必须排在「复制文件路径」这类小工具前面');
    expect(openWithY, lessThan(copyY),
        reason: '「打开方式…」也要在打开类那一组里');
    expect(sendY, lessThan(copyY),
        reason: '「发送」是主操作，不能沉到工具项下面');
    expect(copyY, lessThan(deleteY),
        reason: '删除是危险操作，必须排最后，避免误触');
    expect(selectAllY, lessThan(deleteY),
        reason: '「全选」应在删除之前');
    expect(deleteY, greaterThan(copyY),
        reason: '删除固定收尾');

    // 颜色：主操作用主题强调色，删除用错误色，二者必须区分得开
    expect(colorOf('打开'), scheme.primary,
        reason: '主操作「打开」用主题强调色');
    expect(colorOf('打开方式…'), scheme.primary,
        reason: '「打开方式…」同属主操作');
    expect(colorOf('删除…'), scheme.error,
        reason: '危险操作「删除…」必须用错误色，跟其它项一眼分得开');
    expect(colorOf('删除…'), isNot(colorOf('打开')),
        reason: '删除与打开不能同色');
    expect(colorOf('全选'), scheme.onSurfaceVariant,
        reason: '次要工具退到次级色，视觉上给主操作让位');

    // 分组之间必须有分隔线（4 组 → 3 条）
    expect(find.byType(Divider), findsNWidgets(3),
        reason: '打开类 / 定位复制 / 选择 / 删除 共 4 组，组间应有 3 条分隔线');
  });
}
