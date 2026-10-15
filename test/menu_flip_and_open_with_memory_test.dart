import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rust_flutter_ui/services/platform_channel.dart';
import 'package:rust_flutter_ui/ui/menus.dart';
import 'package:rust_flutter_ui/ui/open_with_sheet.dart';

/// 本轮修复的回归护栏：
///  - 安卓文件 TAB 的菜单在底部（tab 栏附近）触发时，必须**向上弹出**，
///    底边不越过底部 tab 栏预留区（用户反馈：菜单要从 tab 栏上方弹出）。
///  - 「打开方式」的「始终」记忆：记住扩展名 → 应用，下次直接用它。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpHost(
    WidgetTester tester, {
    required Offset anchor,
    required Size size,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showIconMenu(
                context,
                anchor: anchor,
                header: 'a.txt',
                actions: <IconMenuAction>[
                  for (var i = 0; i < 6; i++)
                    IconMenuAction(
                      id: 'a$i',
                      label: '项目 $i',
                      icon: Icons.circle,
                      run: () async {},
                    ),
                ],
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('底部锚点：菜单向上弹出，不压进 tab 栏预留区', (tester) async {
    // 1400x900，锚点很靠下（模拟底部 tab 栏附近的文件卡片）
    const anchor = Offset(500, 860);
    await pumpHost(tester, anchor: anchor, size: const Size(1200, 900));

    final menu = find.text('项目 0');
    expect(menu, findsOneWidget, reason: '前置：菜单应弹出');

    // 菜单容器（自绘弹出菜单的那个 Material）的矩形
    final box = tester.getRect(
      find.ancestor(of: menu, matching: find.byType(Material)).first,
    );

    expect(box.bottom, lessThanOrEqualTo(900 - 72 + 1),
        reason: '菜单底边不能压进底部 72 的 tab 栏预留区；实测 bottom=${box.bottom}');
    // 关键：菜单必须整体待在锚点**上方**（向上翻转），而不是被压到屏幕底部
    expect(box.bottom, lessThanOrEqualTo(anchor.dy + 1),
        reason: '底部空间不够时菜单应向上翻转到锚点上方；'
            '实测 bottom=${box.bottom} anchor=${anchor.dy} '
            '（旧实现会把它压到屏幕底部 = 贴着 tab 栏）');
  });

  testWidgets('上方锚点：菜单仍从锚点向下弹出（不误翻转）', (tester) async {
    const anchor = Offset(300, 120);
    await pumpHost(tester, anchor: anchor, size: const Size(1200, 900));

    final menu = find.text('项目 0');
    final box = tester.getRect(
      find.ancestor(of: menu, matching: find.byType(Material)).first,
    );
    expect((box.top - anchor.dy).abs(), lessThan(2),
        reason: '空间足够时菜单应贴着锚点向下弹出；实测 top=${box.top}');
  });

  group('「打开方式」记住的「始终」选择', () {
    setUp(() => OpenWithMemory.clear());
    tearDown(() => OpenWithMemory.clear());

    test('按扩展名记忆，且不同扩展名互不干扰', () {
      const txt = OpenWithApp(package: 'com.a.reader', label: '阅读器');
      const img = OpenWithApp(package: 'com.b.gallery', label: '相册');
      OpenWithMemory.remember('/sdcard/a.txt', txt);
      OpenWithMemory.remember('/sdcard/b.png', img);

      expect(OpenWithMemory.remembered('/other/c.txt'), txt,
          reason: '同类文件（.txt）下次应直接命中记忆的应用');
      expect(OpenWithMemory.remembered('/other/d.png'), img);
      expect(OpenWithMemory.remembered('/other/e.pdf'), isNull,
          reason: '没记过的类型不应误命中');
    });

    test('扩展名大小写不敏感；无扩展名走 * 兜底', () {
      const app = OpenWithApp(package: 'com.a.x', label: 'X');
      OpenWithMemory.remember('/sdcard/A.TXT', app);
      expect(OpenWithMemory.remembered('/sdcard/2.txt'), app);
      OpenWithMemory.remember('/sdcard/README', app);
      expect(OpenWithMemory.remembered('/sdcard/OTHER'), app);
    });

    test('forget 清掉某扩展名的记忆（记忆失效后重新弹窗）', () {
      const app = OpenWithApp(package: 'com.a.x', label: 'X');
      OpenWithMemory.remember('/sdcard/a.txt', app);
      OpenWithMemory.forget('/sdcard/z.txt');
      expect(OpenWithMemory.remembered('/sdcard/q.txt'), isNull);
    });
  });

  test('openFileWithPackage 在非安卓上退化为系统默认打开', () async {
    YuChuanPlatform.isAndroidOverride = false;
    addTearDown(() => YuChuanPlatform.isAndroidOverride = null);
    // 桌面分支走 Process.start（cmd start）—— 只断言它**不抛异常**、
    // 语义退化为 [openFile]（没有「指定包名打开」这种桌面概念）。
    await expectLater(
      YuChuanPlatform.openFileWithPackage('/definitely/not/here.txt', 'com.x'),
      completes,
      reason: '桌面没有「指定包名打开」语义，应安全退化而不是抛异常',
    );
  });
}
