import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rust_flutter_ui/app_state.dart';
import 'package:rust_flutter_ui/models.dart';
import 'package:rust_flutter_ui/ui/chat_page.dart';

/// Task 8：聊天标题的筛选按钮「更直观」。
///
/// 用户的硬性裁决（必须原样遵守）：**只有图标，只换图标样式**。
///   「只有图标，我都说了图标换样式，那就不要拓展想法。」
/// 因此本测试同时守两条线：
///   1) 图标随当前筛选态变化（一眼看出「在筛什么」）；
///   2) 不得引入文字标签 / 尺寸变化 —— 按钮里只能有 Icon。
///
/// 每个断言「改什么会把它打红」都写在对应 reason 里，避免空洞断言。
void main() {
  /// 只按 tooltip 定位头部筛选按钮 —— 因为图标本身就在变，
  /// 用 byIcon 定位会自我指涉（改了图标名测试就崩，而不是变红）。
  Finder filterButton() => find.byWidgetPredicate(
      (w) => w is IconButton && (w.tooltip ?? '').startsWith('筛选'));

  Future<void> pumpChat(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    AppState.instance.conversations
      ..clear()
      ..add(Conversation(
        device: LanDevice(
          id: 'dev-f',
          name: '筛选设备',
          ip: '192.168.1.9',
          platform: DevicePlatform.windows,
          online: true,
          paired: true,
        ),
        messages: [
          ChatMessage(
            id: 'f1',
            fromMe: false,
            kind: MessageKind.text,
            text: '筛选用例',
            time: DateTime.now(),
            progress: 1,
          ),
        ],
      ));
    AppState.instance.selectedConversation = 0;

    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: ChatPage(peerId: 'dev-f'))));
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// 打开筛选菜单并选定一项（菜单里的文字标签是弹层里的，不是按钮上的）。
  Future<void> pickFilter(WidgetTester tester, String label) async {
    await tester.tap(filterButton());
    await tester.pumpAndSettle();
    expect(find.text(label), findsOneWidget,
        reason: '筛选弹层里应当有「$label」这一项，否则下面的选择没有意义');
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets('初始（全部）：图标为 filter_alt_outlined，且按钮内没有任何文字',
      (tester) async {
    await pumpChat(tester);

    expect(filterButton(), findsOneWidget, reason: '头部必须仍有筛选按钮（原地不改位置）');

    // 打红条件：把初始图标改回 filter_list_off_outlined / filter_list。
    expect(
      find.descendant(
          of: filterButton(), matching: find.byIcon(Icons.filter_alt_outlined)),
      findsOneWidget,
      reason: '「全部」态应使用 filter_alt_outlined，以与「筛选中」的专属图标区分开',
    );
    expect(
      find.descendant(
          of: filterButton(),
          matching: find.byIcon(Icons.filter_list_off_outlined)),
      findsNothing,
      reason: '旧的 filter_list_off_outlined 必须不再作为「全部」态图标',
    );

    // 打红条件：给按钮加回文字标签（胶囊/文字/任何 Text）。
    expect(
      find.descendant(of: filterButton(), matching: find.byType(Text)),
      findsNothing,
      reason: '用户裁决：只有图标，不得出现文字标签',
    );

    // 打红条件：改掉图标尺寸（用户要求不改变尺寸/位置）。
    final icon = tester.widget<Icon>(
        find.descendant(of: filterButton(), matching: find.byType(Icon)));
    expect(icon.size, 20, reason: '图标尺寸保持 20，不得顺带改大小');

    // 打红条件：无筛选时也叠角标 → 「正在筛选」就失去指示意义。
    expect(
      find.descendant(of: filterButton(), matching: find.byType(Badge)),
      findsNothing,
      reason: '「全部」态没有在筛选，不应显示角标',
    );
  });

  testWidgets('四种筛选态各有专属图标 + 生效角标，且 tooltip 说明当前筛选',
      (tester) async {
    await pumpChat(tester);

    // (状态, 图标, 菜单项文字, tooltip 里应出现的当前筛选名)
    const cases = <(String, IconData, String, String)>[
      ('all', Icons.filter_alt_outlined, '全部消息', '全部消息'),
      ('text', Icons.text_fields_outlined, '仅文本', '仅文本'),
      ('image', Icons.image_outlined, '仅图片', '仅图片'),
      ('file', Icons.insert_drive_file_outlined, '仅文件', '仅文件'),
    ];

    for (final (state, icon, menuLabel, tooltipName) in cases) {
      await pickFilter(tester, menuLabel);

      final btn = tester.widget<IconButton>(filterButton());
      final iconSizes = tester
          .widgetList<Icon>(find.descendant(
              of: filterButton(), matching: find.byType(Icon)))
          .map((i) => i.icon)
          .toList();

      expect(iconSizes, contains(icon),
          reason: '$state 态：图标必须是 $icon，'
              '否则用户无法从图标看出当前在筛什么（打红条件：删掉按状态取图标的 switch）');

      expect((btn.tooltip ?? ''), contains(tooltipName),
          reason: '$state 态：tooltip 要说明当前筛选（打红条件：tooltip 写死成「筛选消息内容」）');

      // 角标：只有非 all 才表示「正在筛选」。
      final badgeCount = find
          .descendant(of: filterButton(), matching: find.byType(Badge))
          .evaluate()
          .length;
      expect(badgeCount, state == 'all' ? 0 : 1,
          reason: '$state 态：角标应为 ${state == 'all' ? '无' : '有'}（打红条件：'
              'Badge 恒有或恒无）');

      // 任何状态下都不得出现文字标签。
      expect(
        find.descendant(of: filterButton(), matching: find.byType(Text)),
        findsNothing,
        reason: '$state 态：按钮必须仍是纯图标',
      );

      // 回到全部，便于下一轮从干净状态开始。
      if (state != 'file') await pickFilter(tester, '全部消息');
    }
  });
}
