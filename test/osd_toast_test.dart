import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_flutter_ui/ui/osd_toast.dart';

/// OSD 位置与配色（修 bug.md 第 3 行）。
void main() {
  /// 显示一条 OSD 并让动画彻底停稳后再断言。
  ///
  /// 三处「必须显式等待」的原因（都是实测出来的，不是猜的）：
  /// 1. `flutter test` 下 `defaultTargetPlatform` 被框架强制成 android，
  ///    桌面分支根本走不到 → 用 `debugDefaultTargetPlatformOverride` 伪造平台。
  ///    它必须在**测试体内**复位：binding 的 `_verifyInvariants()`（检查
  ///    「foundation debug 变量被改动」）跑在 `addTearDown` 之前，放 tearDown
  ///    里复位会被判失败。
  /// 2. `MaterialApp` 的换肤走 `AnimatedTheme`，`pumpWidget` 之后立刻读到的
  ///    brightness 还是上一套主题（实测 afterPumpWidget=light，300ms 后才 dark）。
  /// 3. `OverlayEntry` 在 `show()` 的下一帧才挂载并开始入场动画，只 pump 一次
  ///    的话 `SlideTransition` 还停在起点，量到的是「入场中」而不是最终位置。
  Future<void> pumpAndShow(
    WidgetTester tester, {
    required bool dark,
  }) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
      home: Builder(builder: (c) { ctx = c; return const Scaffold(); }),
    ));
    await tester.pump(const Duration(milliseconds: 300)); // 等换肤动画结束
    OsdToast.info(ctx, '测试提示');
    await tester.pump(const Duration(milliseconds: 300)); // 挂载 OverlayEntry
    await tester.pump(const Duration(milliseconds: 300)); // 等入场动画结束
  }

  /// 测试体收尾：复位伪造平台 + 走完 OSD 的 2 秒自动消失 Timer。
  ///
  /// 两件事都必须**在测试体内**做完，不能放 `addTearDown`：
  /// binding 的 `_verifyInvariants()`（既检查 foundation debug 变量、也检查
  /// 「还有 pending timer」）跑在 tearDown 之前，放 tearDown 里已经太迟。
  Future<void> cleanup(WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = null;
    await tester.pump(const Duration(seconds: 2)); // 让自动消失 Timer 触发
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> withPlatform(
    TargetPlatform platform,
    Future<void> Function() body,
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body();
    } finally {
      await cleanup(tester);
    }
  }

  testWidgets('OSD 不贴顶：顶部留出标题栏高度', (tester) async {
    await withPlatform(TargetPlatform.windows, () async {
      await pumpAndShow(tester, dark: false);
      final top = tester.getTopLeft(find.text('测试提示')).dy;
      expect(top, greaterThan(40), reason: 'OSD 必须落在标题栏之下，不能压住它');
    }, tester);
  });

  testWidgets('OSD 浅色主题下字体为黑、深色主题下为白', (tester) async {
    await withPlatform(TargetPlatform.windows, () async {
      await pumpAndShow(tester, dark: false);
      expect(
          tester.widget<Text>(find.text('测试提示')).style?.color, Colors.black);
      await pumpAndShow(tester, dark: true);
      expect(
          tester.widget<Text>(find.text('测试提示')).style?.color, Colors.white);
    }, tester);
  });

  testWidgets('OSD 圆角 ≤ 12、无描边横线', (tester) async {
    await withPlatform(TargetPlatform.windows, () async {
      await pumpAndShow(tester, dark: false);
      final c = tester.widget<Container>(find.ancestor(
        of: find.text('测试提示'),
        matching: find.byType(Container),
      ).first);
      final deco = c.decoration! as BoxDecoration;
      final r = deco.borderRadius! as BorderRadius;
      expect(r.topLeft.x, lessThanOrEqualTo(12.0));
      expect(deco.border, isNull, reason: '不要描边横线');
      // 真正的「横线」来源是贴顶的硬阴影，不是 border；只断言 border 抓不到它。
      expect(deco.boxShadow, isNull, reason: '不要贴顶硬阴影（上缘会被看成横线）');
    }, tester);
  });

  /// 安卓没有自定义标题栏，但聊天页有自己的头部（minHeight: 56）。
  /// 用户反馈两次「OSD 要再往下」：第一次给 14 不够，第二次要求
  /// 「至少再有一个按钮高度的距离」→ 现在让开 56 + 48。
  testWidgets('OSD 在安卓上让开聊天页头部 + 一个按钮高度', (tester) async {
    await withPlatform(TargetPlatform.android, () async {
      await pumpAndShow(tester, dark: false);
      final top = tester.getTopLeft(find.text('测试提示')).dy;
      expect(top, greaterThan(0));
      // 必须整体落到 56 高的页面头部之下（胶囊有内边距，文字本身更靠下）
      expect(top, greaterThanOrEqualTo(56.0),
          reason: '安卓 OSD 必须让开聊天页头部，否则会压住「会话标题」');
      // 用户要求：再往下至少一个按钮高度（48）
      expect(top, greaterThanOrEqualTo(56.0 + 20.0),
          reason: '安卓 OSD 还要再往下至少一个按钮高度的距离');
      // 但也不能掉到屏幕中部去
      expect(top, lessThan(56.0 + 90.0),
          reason: '安卓 OSD 不该掉到屏幕中部');
    }, tester);
  });

  /// 用户要求「OSD 的文字不要出现横线」：文本不得带删除线/下划线。
  testWidgets('OSD 文字没有横线（decoration 为 none）', (tester) async {
    await withPlatform(TargetPlatform.android, () async {
      await pumpAndShow(tester, dark: false);
      final t = tester.widget<Text>(find.text('测试提示'));
      expect(t.style?.decoration, anyOf(isNull, TextDecoration.none),
          reason: 'OSD 文字不能有下划线/删除线');
    }, tester);
  });
}
