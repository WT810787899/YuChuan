import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rust_flutter_ui/app_state.dart';
import 'package:rust_flutter_ui/models.dart';
import 'package:rust_flutter_ui/services/platform_channel.dart';
import 'package:rust_flutter_ui/ui/chat_page.dart';

/// Task 9：所有类型的气泡都能多选；勾选框重复点可取消；去掉选中背景叠加
/// （修 bug.md：「所有类型的气泡都要有多选菜单。多选：不要有选中背景叠加，
///  只要现在的勾选框，重复点要能取消勾选」）。
///
/// 每条断言都标注了「打什么会把它打红」。
///
/// ## 探针实测的既有事实（决定了哪些断言是护栏、哪些是新增行为）
///
/// 1. **图片气泡长按本来就能弹出含「多选」的菜单** —— 外层 `_MessageRow` 的
///    `GestureDetector` 是图片内层手势的祖先，长按由它处理。所以
///    「图片菜单里有 多选」是**回归护栏**，不是本次从红转绿的行为。
/// 2. 真正由红转绿的图片相关断言是：**多选态下重复点图片能取消勾选**
///    （因为 android 分支原先只增不减）。
/// 3. 图片气泡自己新增的手势接线是**可观测**的：`Hero` 的最近
///    `GestureDetector` 祖先，改前是 `onLongPress=null / onSecondaryTap=null`，
///    改后非空。这条断言是真的会红/会绿的（见 imageBubbleGesture()）。
///
/// ## 为什么用 Hero 而不是 Image 定位图片气泡
///
/// `find.byType(Image)` 实测**不可命中**：真实 PNG 未解码时 rect 退化成 2×2、
/// `hitTestable()==0`，对它 `longPress()` 只是「打偏了但恰好落到外层行上」，
/// 菜单照样弹出 —— 这正是本批次反复踩到的「空洞绿」。
/// `Hero` 实测可命中（占位图 202×134），所以一律以 Hero 为锚点。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bubble_multi');
  });

  tearDown(() {
    YuChuanPlatform.isAndroidOverride = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 渲染聊天页，含两条同类型消息。
  ///
  /// 两条是为了在「至少还选中一条」的前提下测取消 —— 只选一条时取消会直接
  /// 退出多选，看不到切换。图片默认用**占位图**（无本地文件），因为占位态
  /// 的 Hero 才是真正可命中的大目标。
  Future<void> pumpWith(WidgetTester tester, MessageKind kind,
      {bool android = false}) async {
    YuChuanPlatform.isAndroidOverride = android ? true : null;
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final isImage = kind == MessageKind.image;
    final isText = kind == MessageKind.text;

    ChatMessage make(String id, String text, String fileName) => ChatMessage(
          id: id,
          fromMe: false,
          kind: kind,
          time: DateTime.now(),
          text: text,
          fileName: fileName,
          progress: 1,
        );

    AppState.instance.conversations
      ..clear()
      ..add(Conversation(
        device: LanDevice(
          id: 'dev-m',
          name: '多选设备',
          ip: '192.168.1.8',
          platform: DevicePlatform.windows,
          online: true,
          paired: true,
        ),
        messages: [
          make('m1', isText ? '你好' : '', isImage ? 'photo.png' : 'a.txt'),
          make('m2', isText ? '世界' : '', isImage ? 'photo.png' : 'b.txt'),
        ],
      ));
    AppState.instance.selectedConversation = 0;

    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: const Scaffold(body: ChatPage(peerId: 'dev-m'))));
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// 第 [i] 张图片气泡的锚点（可命中）。
  Finder imageBubble(int i) => find.byType(Hero).at(i);

  /// 图片气泡**自己**的 GestureDetector（Hero 的最近手势祖先）。
  ///
  /// 用于断言新增的 onMenu 接线真的存在 —— 这是本次改动在图片上
  /// 唯一可结构观测、且改前会红的点。
  ///
  /// **为什么调用方还要断 `child is Hero`**：外层 `_MessageRow` 的手势
  /// 也是 Hero 的祖先，只断 onLongPress/onSecondaryTap 非空的话，删掉
  /// 气泡内层手势后外层照样满足 —— 那是空洞绿（审查结论 A2）。所以
  /// 调用方必须再钉住「这一层就是气泡自己那一层」。
  GestureDetector? imageBubbleGesture(WidgetTester tester) {
    final gds = find
        .ancestor(
            of: find.byType(Hero).first,
            matching: find.byType(GestureDetector))
        .evaluate();
    if (gds.isEmpty) return null;
    return gds.first.widget as GestureDetector;
  }

  /// 自绘弹出菜单本体（`menus.dart` 里唯一 `elevation: 12` 的 Material）。
  ///
  /// 用它测量菜单的实际落点：`showIconMenu` 的非底部弹层分支把菜单
  /// `Positioned(left: anchor.dx, top: anchor.dy)` 放在全屏 Overlay 里，
  /// 所以这个 Material 的 global 左上角就是 anchor。
  Finder menuBox() =>
      find.byWidgetPredicate((w) => w is Material && w.elevation == 12);

  /// 当前选中条数（未进入多选 = 0）。
  int selectedCount(WidgetTester tester) {
    final f = find.textContaining('条已选');
    if (f.evaluate().isEmpty) return 0;
    final txt = (f.evaluate().first.widget as Text).data ?? '';
    return int.tryParse(RegExp(r'^(\d+)').firstMatch(txt)?.group(1) ?? '') ?? -1;
  }

  /// 点一下，并**显式推进过双击判定窗口**。
  ///
  /// 文字气泡外层注册了 `onDoubleTap`（双击复制），单击要等约 300ms 的
  /// 双击窗口超时才会派发 `onTap`；`pumpAndSettle` 只重复 pump 直到没有新帧，
  /// **不推进这个定时器**。探针实测：不 pump 这段时长时「点了但什么也没发生」，
  /// 断言会假绿/假红 —— 本批次踩过的坑。
  Future<void> tapSettled(WidgetTester tester, Finder target) async {
    await tester.tap(target);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  /// 进入多选：长按 [target] → 菜单点「多选」。
  Future<void> enterMultiSelect(WidgetTester tester, Finder target) async {
    await tester.longPress(target);
    await tester.pumpAndSettle();
    expect(find.text('多选'), findsOneWidget,
        reason: '前置条件：长按应弹出带「多选」的菜单，否则后续断言没有意义');
    await tester.tap(find.text('多选'));
    await tester.pumpAndSettle();
  }

  /// 多选态每个气泡旁的圆形勾选框。
  final ringFinder = find.byWidgetPredicate((w) =>
      w is AnimatedContainer &&
      w.decoration is BoxDecoration &&
      (w.decoration as BoxDecoration).shape == BoxShape.circle);

  // ==================================================================
  // (a) 文件气泡菜单含「多选」
  // ==================================================================
  testWidgets('文件气泡菜单含「多选」', (tester) async {
    await pumpWith(tester, MessageKind.file);

    // 前置：锚点真的可命中（否则下面全是空洞断言）。
    expect(find.text('a.txt').hitTestable(), findsOneWidget,
        reason: '前置条件：文件卡片标题必须真的可点中');

    await tester.longPress(find.text('a.txt'));
    await tester.pumpAndSettle();

    expect(find.text('转发'), findsOneWidget,
        reason: '前置条件：文件气泡菜单本来就能弹出来'
            '（否则「多选」断言会因菜单没开而假绿）');

    // 打红条件：删掉 _FileBubble._showFileMenu 里新增的 multi 条目。
    // 改动前实测 多选=0。
    expect(find.text('多选'), findsOneWidget,
        reason: '文件气泡菜单必须有多选（用户要求：所有类型气泡都要有多选菜单）');

    await tester.tap(find.text('多选'));
    await tester.pumpAndSettle();
    expect(selectedCount(tester), 1,
        reason: '文件气泡的「多选」应以「这条已选中」的状态进入多选');
  });

  // ==================================================================
  // (b) 图片气泡自己有菜单接线（可结构观测，改前会红）
  // ==================================================================
  testWidgets('图片气泡自身注册了长按/右键出菜单的手势', (tester) async {
    await pumpWith(tester, MessageKind.image);

    // 前置：Hero 真的可命中（Image 不可命中，见文件头说明）。
    expect(find.byType(Hero).hitTestable(), findsWidgets,
        reason: '前置条件：图片气泡的锚点必须可命中');

    final gd = imageBubbleGesture(tester);
    expect(gd, isNotNull, reason: '前置条件：Hero 之上应有气泡自己的 GestureDetector');

    // ---- A2：钉住「这一层就是气泡自己那一层」---------------------------
    //
    // 只断 onLongPress / onSecondaryTap 非空是不够的：外层 `_MessageRow`
    // 的 GestureDetector 同样是 Hero 的祖先，且它的这两个回调**也**非空，
    // 所以把气泡内层删掉，上面的断言照样通过（空洞绿）。
    // 气泡内层的手势**直接**包着 Hero；外层包的是 MouseRegion。
    // 这条断言只能由「图片气泡自己拥有手势层」满足。
    expect(gd!.child, isA<Hero>(),
        reason: 'A2：最近的手势祖先必须是气泡自己那层（直接包 Hero），'
            '而不是外层 _MessageRow 的行级手势（它包 MouseRegion）。'
            '打红条件：删掉 _ImageBubble 里的 GestureDetector');

    // 打红条件：删掉 _ImageBubble 里新增的 onLongPress / onSecondaryTap。
    // 探针实测改动前这里是 long=false sec=false（RED）。
    expect(gd.onLongPress, isNotNull,
        reason: '图片气泡要自己接长按出菜单（用户要求：所有类型气泡都要有多选菜单）');
    expect(gd.onSecondaryTap, isNotNull,
        reason: '桌面端右键同样要出菜单');
    // A1：右键落点必须由气泡自己记（否则菜单会弹到整行中心）。
    expect(gd.onSecondaryTapDown, isNotNull,
        reason: 'A1：右键落点要在气泡自己的手势里记录，'
            '不能依赖外层行 —— 快速右键由最深识别器胜出，外层永远收不到');
    // 单击语义必须保留（不能为了加菜单把预览弄丢）。
    expect(gd.onTap, isNotNull,
        reason: '未多选时单击图片仍是全屏预览，不能被菜单接线挤掉');
  });

  // ==================================================================
  // (b3) A1：右键菜单贴着鼠标落点，而不是整行中心
  // ==================================================================
  testWidgets('图片气泡右键菜单锚定在鼠标落点（不是整行中心）', (tester) async {
    await pumpWith(tester, MessageKind.image);

    // 故意点气泡的**左边缘内侧**：它离整行水平中心很远（整行宽 1400，
    // 气泡约在 x≈60..260），这样「锚在落点」与「回落到整行中心」两种
    // 结果相差数百像素，断言不可能同时成立。
    final rect = tester.getRect(imageBubble(0));
    final click = Offset(rect.left + 30, rect.center.dy);

    final g = await tester.startGesture(click, buttons: kSecondaryButton);
    await g.up();
    await tester.pumpAndSettle();

    // 前置：菜单真的弹出来了，否则下面的测量毫无意义。
    expect(find.text('多选'), findsOneWidget,
        reason: '前置条件：右键应弹出菜单');
    expect(menuBox(), findsOneWidget,
        reason: '前置条件：应恰有一个自绘弹出菜单（elevation 12）');

    // menus.dart 的弹出菜单把本体 Positioned(left: anchor.dx, top: anchor.dy)。
    // 下方空间不够时会**向上翻转**（用户要求：安卓菜单要从底部 tab 栏上方弹出），
    // 所以垂直方向只断言「不会回落到整行中心」，水平方向仍严格贴着落点。
    final menuTopLeft = tester.getTopLeft(menuBox());

    // 打红条件：删掉 _ImageBubble 的 onSecondaryTapDown（菜单会落到整行中心）。
    expect((menuTopLeft.dx - click.dx).abs(), lessThan(2),
        reason: 'A1：菜单左边缘应贴着右键落点 x=${click.dx}，'
            '实测 ${menuTopLeft.dx}（等于回落逻辑的整行中心）');
    // 垂直：要么贴着锚点，要么向上翻转（菜单底边落在锚点上方，留一点偏移）。
    final menuHeight = tester.getSize(menuBox()).height;
    final anchoredAtClick = (menuTopLeft.dy - click.dy).abs() < 2;
    final flippedAbove =
        (menuTopLeft.dy + menuHeight - click.dy).abs() < 24;
    expect(anchoredAtClick || flippedAbove, isTrue,
        reason: 'A1：菜单要么贴着右键落点 y=${click.dy}，要么向上翻转使底边贴住它；'
            '实测 top=${menuTopLeft.dy} height=$menuHeight');

    // 反向确认：落点必须远离「锚点丢失时的回落点」，否则上面的
    // 「贴着落点」断言无法区分两种情况。
    //
    // 回落点是**整行中心**（`showIconMenu` 的 `box.size.center`，box 即
    // `_MessageRow` 那一层，横向铺满列表内容宽度 → 约等于屏幕水平中心）。
    // 实测对比：打了修复时菜单 x=94（=落点）；去掉 onSecondaryTapDown
    // 后菜单 x=700（=整行中心）。
    final rowCentreX = tester.view.physicalSize.width /
        tester.view.devicePixelRatio /
        2;
    expect((click.dx - rowCentreX).abs(), greaterThan(200),
        reason: '前置条件：本用例的右键落点 x=${click.dx} 必须离整行中心 '
            'x=$rowCentreX 足够远，「贴着落点」与「回落到整行中心」'
            '才不可能同时成立');
  });

  // ==================================================================
  // (b2) 图片气泡长按/右键能弹出一个菜单（回归护栏）
  // ==================================================================
  testWidgets('图片气泡长按弹出菜单（含「多选」），且不会叠出两份', (tester) async {
    await pumpWith(tester, MessageKind.image);

    await tester.longPress(imageBubble(0));
    await tester.pumpAndSettle();

    // 打红条件：图片气泡内层也接 onLongPress 后，若内外层各弹一次菜单，
    // 这里会变成 2 —— 这是本次改动最真实的回归风险。
    expect(find.text('多选'), findsOneWidget,
        reason: '图片气泡长按应弹出**一个**含「多选」的菜单，不能内外层各弹一次');

    await tester.tap(find.text('多选'));
    await tester.pumpAndSettle();
    expect(selectedCount(tester), 1,
        reason: '图片气泡的「多选」应以「这条已选中」的状态进入多选');
  });

  testWidgets('图片气泡右键也能弹出菜单', (tester) async {
    await pumpWith(tester, MessageKind.image);

    final g = await tester.startGesture(
      tester.getCenter(imageBubble(0)),
      buttons: kSecondaryButton,
    );
    await g.up();
    await tester.pumpAndSettle();

    expect(find.text('多选'), findsOneWidget,
        reason: '桌面端右键应弹出菜单'
            '（打红条件：图片只接长按、不接 onSecondaryTap）');
  });

  // ==================================================================
  // (c) 非多选态单击图片仍是全屏预览
  // ==================================================================
  testWidgets('多选未激活时，单击图片仍打开全屏预览', (tester) async {
    await pumpWith(tester, MessageKind.image);

    await tester.tap(imageBubble(0));
    await tester.pumpAndSettle();

    // 打红条件：把图片的 onTap 改成弹菜单、或让选中逻辑吃掉单击。
    expect(find.byType(InteractiveViewer), findsOneWidget,
        reason: '非多选态单击图片 = 全屏预览（这条行为必须原样保留）');

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing,
        reason: '预览应能正常关闭');
  });

  // ==================================================================
  // (d) 多选态下反复切换（用户要求：重复点要能取消勾选）
  // ==================================================================
  for (final android in [false, true]) {
    final plat = android ? '安卓' : 'PC';
    testWidgets('多选态重复点气泡可取消勾选（$plat）', (tester) async {
      await pumpWith(tester, MessageKind.text, android: android);

      await enterMultiSelect(tester, find.text('你好'));
      expect(selectedCount(tester), 1, reason: '前置条件：已进入多选并选中第 1 条');

      await tapSettled(tester, find.text('世界'));
      expect(selectedCount(tester), 2, reason: '点未选中的气泡应追加选中');

      // 打红条件：toggle 写成只 add 不 remove。
      // 改动前安卓分支正是如此：实测这里仍是 2（RED）。
      await tapSettled(tester, find.text('世界'));
      expect(selectedCount(tester), 1,
          reason: '重复点必须能取消勾选，而不是只增不减（用户要求）');

      // 打红条件：把 toggle 写成「取消后不能再选」（单向）。
      await tapSettled(tester, find.text('世界'));
      expect(selectedCount(tester), 2,
          reason: '取消之后再点应能重新选中（切换语义双向都要成立）');
    });
  }

  testWidgets('取消最后一条选中会退出多选（多选条消失）', (tester) async {
    await pumpWith(tester, MessageKind.text, android: true);

    await enterMultiSelect(tester, find.text('你好'));
    expect(selectedCount(tester), 1, reason: '前置条件：已选中 1 条');

    await tapSettled(tester, find.text('你好'));

    // 打红条件：安卓分支只 add。改动前实测仍是 1 条已选（RED）。
    expect(selectedCount(tester), 0,
        reason: '取消勾选后不剩选中项，多选条应消失（用户要看到「取消了」）');
    expect(find.text('取消'), findsNothing, reason: '退出多选后操作条应整体消失');
  });

  testWidgets('重复点图片气泡也能取消勾选（安卓）', (tester) async {
    await pumpWith(tester, MessageKind.image, android: true);

    await enterMultiSelect(tester, imageBubble(0));
    expect(selectedCount(tester), 1, reason: '前置条件：图片已选中');

    await tapSettled(tester, imageBubble(1));
    expect(selectedCount(tester), 2, reason: '点未选中图片应追加');

    // 打红条件：安卓只 add；或图片在多选态把点击吃掉去开预览。
    await tapSettled(tester, imageBubble(1));
    expect(find.byType(InteractiveViewer), findsNothing,
        reason: '多选态点图片不得打开预览，点按语义是勾选');
    expect(selectedCount(tester), 1,
        reason: '重复点图片气泡必须能取消勾选');
  });

  // ==================================================================
  // (e) 勾选框本身也能切换
  // ==================================================================
  testWidgets('点勾选框本身也能取消勾选（安卓）', (tester) async {
    await pumpWith(tester, MessageKind.text, android: true);
    await enterMultiSelect(tester, find.text('你好'));

    expect(ringFinder, findsWidgets, reason: '前置条件：多选态每个气泡旁要有勾选圈');
    expect(find.byIcon(Icons.check), findsWidgets,
        reason: '前置条件：选中后勾选圈应显示对勾');

    await tapSettled(tester, find.text('世界'));
    expect(selectedCount(tester), 2, reason: '前置条件：两条都选中');

    final worldRow =
        find.ancestor(of: find.text('世界'), matching: find.byType(Row)).first;
    await tapSettled(
        tester, find.descendant(of: worldRow, matching: ringFinder).first);

    // 打红条件：勾选框的 onTap 不走 toggle（安卓只 add）。
    expect(selectedCount(tester), 1,
        reason: '勾选框是可点的切换控件，重复点它同样要取消勾选');
  });

  // ==================================================================
  // (f) 不要选中背景叠加：勾选框是唯一标识
  // ==================================================================
  testWidgets('选中态不再叠加背景色（勾选框才是唯一标识）', (tester) async {
    await pumpWith(tester, MessageKind.text);

    /// 气泡内容的所有祖先 DecoratedBox 的 decoration 快照。
    /// 选中背景是包在气泡外面的一个 DecoratedBox，所以它必然出现在这里。
    List<String> decorations() => tester
        .widgetList<DecoratedBox>(find.ancestor(
            of: find.text('你好'), matching: find.byType(DecoratedBox)))
        .map((d) => d.decoration.toString())
        .toList();

    final before = decorations();
    expect(before, isNotEmpty,
        reason: '前置条件：气泡自身就是 DecoratedBox，快照不能为空'
            '（否则本条断言是空洞的）');

    await enterMultiSelect(tester, find.text('你好'));
    final after = decorations();

    // 打红条件：把 wrapInner 里 scheme.primary alpha 0.30 的 DecoratedBox
    // 加回去。探针实测改动前 after 比 before 恰好多一项：
    //   BoxDecoration(color: Color(alpha: 0.3000, ...),
    //                 borderRadius: BorderRadius.circular(12.0))
    expect(after, before,
        reason: '用户要求：不要选中背景叠加，只要勾选框。'
            '选中态气泡的装饰必须与非选中态完全一致');

    // 反向确认「勾选框还在」——别把唯一标识也一起删了。
    expect(ringFinder, findsWidgets, reason: '去掉背景后，勾选框必须仍然在');
  });
}
