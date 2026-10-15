import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rust_flutter_ui/main.dart';
import 'package:rust_flutter_ui/ui/files_page.dart';

/// 文件 TAB 过滤按钮字体粗细统一（修 bug.md 第 4 行）。
///
/// 用户明确纠正过一次：**不是**「选中 vs 未选中」的差异，未选中的各个按钮
/// 之间也必须一致。所以断言打在「每个按钮实际解析出的最终样式」上 ——
/// 渲染管线算出来什么，就是用户眼里看到什么。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 与 `effectiveStyles` 同序的选中标记（下标 i 的按钮是否选中）。
  late List<bool> selectedFlags;

  /// 改动前实测的未选中标签颜色（= M3 的 onSurfaceVariant，深浅主题各一）。
  ///
  /// 数值来历（勿再凭推理填写）：浅色 `0xff46464f`、深色 `0xffc8c5d0`，
  /// 由探针对**改动前**的真实 `FilesPage` 渲染结果实测得到。
  /// 注意：**测试失败输出里的 `Expected:` 是回显本常量，不是真值** ——
  /// 想拿真值必须看 `Actual:`，那里才是渲染结果。
  const lightUnselectedColor = 0xff46464f;
  const darkUnselectedColor = 0xffc8c5d0;

  /// 把当前渲染出的每个过滤按钮的**最终生效样式**抓出来。
  ///
  /// 必须连**颜色、字体族、字距、行高**一起抓：`chipTheme.labelStyle` 是用
  /// `??` 取值的（Flutter `chip.dart`：`chipTheme.labelStyle ?? chipDefaults.labelStyle!`），
  /// 一旦它非空就会**整体取代** M3 的按状态默认样式 —— 只钉字重字号而不管
  /// 其余属性，会把默认的 onSurfaceVariant 颜色一起丢掉，未选中按钮变成
  /// 白字白底（实测 color 从 0xff46464f 变 null）。所以整套属性都纳入快照。
  Future<List<String>> effectiveStyles(WidgetTester tester) async {
    final chips = find.byType(ChoiceChip);
    final out = <String>[];
    final flags = <bool>[];
    for (var i = 0; i < chips.evaluate().length; i++) {
      final chipFinder = chips.at(i);
      final chip = tester.widget<ChoiceChip>(chipFinder);
      final rich = find.descendant(
        of: chipFinder,
        matching: find.byType(RichText),
      );
      final rp = tester.renderObject<RenderParagraph>(rich.first);
      final s = rp.text.style;
      flags.add(chip.selected);
      out.add('${(chip.label as Text).data}'
          '|${s?.fontWeight}|${s?.fontSize}'
          '|${s?.color?.toARGB32()}|${s?.fontFamily}'
          '|${s?.letterSpacing}|${s?.height}');
    }
    selectedFlags = flags;
    return out;
  }

  Future<void> pump(WidgetTester tester, Brightness b) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(b),
      home: const Scaffold(body: FilesPage()),
    ));
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// RED 测试：主题必须**显式钉死**两个字重。
  ///
  /// 现状（探针实测）：chipTheme.labelStyle 与 secondaryLabelStyle 都是 null，
  /// 一切依赖 Material 3 的 labelLarge 默认值。默认值是「别人的实现细节」，
  /// 一升级 Flutter 就可能变；而且 ChoiceChip 选中走 secondaryLabelStyle、
  /// 未选中走 labelStyle，两条来源各自被覆盖就会粗细不一致。
  /// 显式钉死两条来源，是保证「各个都统一」最直接的写法。
  test('chipTheme 显式钉死标签字重（不再依赖 M3 默认）', () {
    for (final b in [Brightness.light, Brightness.dark]) {
      final t = buildAppTheme(b);
      final unsel = t.chipTheme.labelStyle;
      final sel = t.chipTheme.secondaryLabelStyle;
      expect(unsel?.fontWeight, isNotNull,
          reason: '$b：未选中标签字重不能留给 M3 默认');
      expect(sel?.fontWeight, isNotNull,
          reason: '$b：选中标签字重不能留给 M3 默认');
      expect(sel!.fontWeight, unsel!.fontWeight,
          reason: '$b：选中与未选中必须同字重');
      expect(sel.fontSize, unsel.fontSize, reason: '$b：字号也必须同档');
    }
  });

  /// 用户复测裁定：「是字体，字体！！！」——问题不在字重而在**字体族**。
  ///
  /// Windows 上 M3 文本主题给的字体是 `Segoe UI`，它**没有任何中文字形**。
  /// 中文只能由系统逐字回退挑字体，不同汉字可能落到不同字体 → 字面参差，
  /// 就是用户看到的「几个按钮基本都不同」。
  ///
  /// 而 `chipTheme.labelStyle` 是**非空整体取代**（`chip.dart` 里用 `??` 取值），
  /// 所以 `ThemeData.fontFamilyFallback` **管不到 chip** —— 回退栈必须写进
  /// chip 样式本身。这条断言就是锁住这一点：删掉任一处回退栈即变红。
  test('chip 标签样式自带中文字体回退栈（否则中文逐字回退、字面参差）', () {
    for (final b in [Brightness.light, Brightness.dark]) {
      final t = buildAppTheme(b);
      for (final (name, s) in [
        ('labelStyle', t.chipTheme.labelStyle),
        ('secondaryLabelStyle', t.chipTheme.secondaryLabelStyle),
      ]) {
        expect(s?.fontFamilyFallback, isNotNull,
            reason: '$b/$name：必须显式给中文字体回退栈 —— '
                'Segoe UI 无中文字形，不给栈就只能逐字回退，字面参差');
        expect(s!.fontFamilyFallback, contains('Microsoft YaHei UI'),
            reason: '$b/$name：Windows 上应优先用微软雅黑 UI');
      }
    }
  });

  /// 回归护栏：把界面实际渲染出的样式抓出来。
  ///
  /// 用户的原意是「**未选中的各个**按钮之间也要一致」（他明确否掉了
  /// 「选中 vs 未选中」这个理解）。所以只对未选中的那批做一致性断言；
  /// 选中项按 M3 语义本就该和未选中不同色。
  testWidgets('未选中的过滤按钮彼此完全一致（浅色）', (tester) async {
    await pump(tester, Brightness.light);
    final all = await effectiveStyles(tester);
    expect(all.length, 7, reason: '过滤按钮应有 7 个，实际 ${all.length}');

    final unselected =
        all.where((s) => !selectedFlags[all.indexOf(s)]).toList();
    expect(unselected.length, 6, reason: '应有 6 个未选中按钮');

    final rest = unselected.map((s) => s.split('|').sublist(1).join('|')).toSet();
    expect(rest.length, 1,
        reason: '未选中的过滤按钮必须全部一致（字重/字号/颜色/字体族/字距/行高），'
            '实际各为：$unselected');

    // 关键：主题层写了字体栈 ≠ 渲染树真的用上。chip 内部是
    // `labelStyle.merge(widget.labelStyle)`（chip.dart:1365），而 merge 在
    // `other.inherit == false` 时会整体返回 other。必须直接查渲染出的段落样式。
    for (final f in find.byType(ChoiceChip).evaluate()) {
      final chip = f.widget as ChoiceChip;
      final rich = find.descendant(
          of: find.byWidget(chip), matching: find.byType(RichText));
      final s = tester.renderObject<RenderParagraph>(rich.first).text.style;
      expect(s?.fontFamilyFallback, contains('Microsoft YaHei UI'),
          reason: '渲染出的 chip「${(chip.label as Text).data}」'
              '必须带中文字体栈，否则中文仍逐字回退、字面参差');
    }

    // 绝对值钉死：本任务只允许「统一」，不允许改变外观。
    // 只钉字重字号会漏掉「颜色/几何被钉死样式吃掉」这个坑
    // （`chipTheme.labelStyle` 用 ?? 取值，非空即整体取代 M3 默认）。
    expect(rest.single,
        'FontWeight.w500|14.0|$lightUnselectedColor|Roboto|0.1|1.43',
        reason: '未选中按钮必须保持改动前的解析样式（w500 / 14.0 / '
            'onSurfaceVariant / Roboto / 0.1 / 1.43）；把颜色或几何丢掉就会红');
  });

  testWidgets('未选中的过滤按钮彼此完全一致（深色）', (tester) async {
    await pump(tester, Brightness.dark);
    final all = await effectiveStyles(tester);
    expect(all.length, 7, reason: '过滤按钮应有 7 个，实际 ${all.length}');
    final unselected =
        all.where((s) => !selectedFlags[all.indexOf(s)]).toList();
    expect(unselected.length, 6, reason: '应有 6 个未选中按钮');
    final rest = unselected.map((s) => s.split('|').sublist(1).join('|')).toSet();
    expect(rest.length, 1,
        reason: '深色下未选中按钮同样必须一致，实际各为：$unselected');
    expect(rest.single,
        'FontWeight.w500|14.0|$darkUnselectedColor|Roboto|0.1|1.43',
        reason: '深色下也要保住颜色与几何，不能是 null');
  });

  /// 应用级文本也必须带中文字体栈。
  ///
  /// 不只是过滤按钮：Windows 上整个 M3 文本主题的字体族都是 `Segoe UI`，
  /// 而它没有中文字形。`ThemeData(fontFamilyFallback:)` 会把它 apply 到
  /// defaultTextTheme（`theme_data.dart:502-505`），从而覆盖全应用的中文。
  test('应用级文本主题带中文字体回退栈', () {
    for (final b in [Brightness.light, Brightness.dark]) {
      final t = buildAppTheme(b);
      expect(t.textTheme.bodyMedium?.fontFamilyFallback,
          contains('Microsoft YaHei UI'),
          reason: '$b：bodyMedium 应带中文字体栈，否则中文逐字回退、字面参差');
      expect(t.textTheme.titleLarge?.fontFamilyFallback,
          contains('Microsoft YaHei UI'),
          reason: '$b：titleLarge 同样应带中文字体栈');
    }
  });
}
