import 'dart:async';

import 'package:flutter/foundation.dart';

import '../appearance.dart';
import '../services/platform_channel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 安卓上点按/长按/弹菜单都给一次触感反馈（用户要求：抖动处理）。
void tapFeedback() {
  if (defaultTargetPlatform == TargetPlatform.android) {
    HapticFeedback.lightImpact();
  }
}

/// 菜单统一文字样式（用户要求：字体和颜色不要参差不齐）。
const _menuTextStyle = TextStyle(fontSize: 14, height: 1.3);
const _headerTextStyle = TextStyle(fontSize: 13, fontWeight: FontWeight.w700);

/// 菜单底部预留：安卓底部 tab 栏（约 56）+ 系统导航条。
/// 菜单不得压进这块区域，否则看起来是「从 tab 栏下面/上面糊出来」（用户反馈）。
double get _kBottomBarReserve =>
    defaultTargetPlatform == TargetPlatform.android ? 72.0 : 8.0;

/// 把 [MenuTone] 映射成实际颜色（主题色，明暗自适应）。
Color _toneColor(ColorScheme scheme, MenuTone tone) {
  switch (tone) {
    case MenuTone.primary:
      return scheme.primary;
    case MenuTone.danger:
      return scheme.error;
    case MenuTone.muted:
      return scheme.onSurfaceVariant;
    case MenuTone.normal:
      return scheme.onSurface;
  }
}

/// 菜单行：图标 20 + 10 间距 + 统一 14 号文字，弹出菜单与底部菜单共用。
/// 颜色由 [MenuTone] 决定（关键项用颜色区分）。
class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.label,
    this.tone = MenuTone.normal,
  });

  final IconData icon;
  final String label;
  final MenuTone tone;

  @override
  Widget build(BuildContext context) {
    final color = _toneColor(Theme.of(context).colorScheme, tone);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: _menuTextStyle.copyWith(
              color: color,
              // 危险项与主操作加粗，进一步拉开层次
              fontWeight: tone == MenuTone.danger || tone == MenuTone.primary
                  ? FontWeight.w600
                  : null,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// 菜单条目的语义色调（用户要求：关键项用颜色区分）。
///
/// 不是装饰：用户在一列 8 项里要能一眼分出「打开/发送」这类主操作、
/// 「删除」这类危险操作、以及「复制路径/全选」这类无副作用的小工具。
/// 用主题色而非硬编码色值，明暗主题自动跟随。
enum MenuTone {
  /// 普通项，跟随正文颜色。
  normal,

  /// 主操作（打开、打开方式、发送）：主题强调色。
  primary,

  /// 危险操作（删除）：主题错误色。
  danger,

  /// 次要工具（复制路径、全选、选择）：退到次级文字色，视觉上让位。
  muted,
}

/// 带图标的操作菜单条目。
class IconMenuAction {
  const IconMenuAction({
    required this.id,
    required this.label,
    required this.icon,
    required this.run,
    this.tone = MenuTone.normal,
  });

  final String id;
  final String label;
  final IconData icon;
  final Future<void> Function() run;

  /// 颜色分类，见 [MenuTone]。
  final MenuTone tone;
}

/// 菜单分组：同组条目紧挨着，组与组之间插一条分隔线。
///
/// 用户要求「优化菜单项排列」：8 项平铺一列很难扫读，按语义断成
/// 打开类 / 选择类 / 管理类三组后，视线只需要在组内找。
List<List<IconMenuAction>> groupMenuActions(List<IconMenuAction> actions) {
  const order = <MenuTone>[MenuTone.primary, MenuTone.normal, MenuTone.muted, MenuTone.danger];
  final groups = <List<IconMenuAction>>[];
  for (final tone in order) {
    final g = actions.where((a) => a.tone == tone).toList();
    if (g.isNotEmpty) groups.add(g);
  }
  // 兜底：万一将来加了新 tone 忘了进 order，也不能把条目弄丢
  final listed = groups.expand((g) => g).toSet();
  final rest = actions.where((a) => !listed.contains(a)).toList();
  if (rest.isNotEmpty) groups.add(rest);
  return groups;
}

/// 自定义弹出菜单路由：支持短促动画（150ms fade+slide）+ 透明 barrier 防误触 + PC 悬浮高亮防抖动。
class _AnimatedPopupMenuRoute<T> extends PopupRoute<T> {
  _AnimatedPopupMenuRoute({
    required this.actions,
    required this.anchor,
    required this.header,
    required this.screenSize,
    this.transitionDuration = const Duration(milliseconds: 150),
    this.barrierDismissible = true,
    this.barrierColor = Colors.transparent,
    this.barrierLabel = 'Dismiss menu',
  });

  final List<IconMenuAction> actions;
  final Offset anchor;
  final String? header;
  final Size screenSize;
  // 字段本身即实现 PopupRoute 的抽象 getter（重复的 @override getter 是
  // duplicate_definition + 无限递归，已删除）
  @override
  final Duration transitionDuration;
  @override
  final bool barrierDismissible;
  @override
  final Color barrierColor;
  @override
  final String barrierLabel;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    // 计算菜单位置，确保不超出屏幕
    final itemHeight = 42.0;
    final headerHeight = header != null ? 56.0 : 0.0;
    // 分组会插入 Divider（height 9），高度算错会让菜单底部被裁掉/悬空。
    final groups = groupMenuActions(actions);
    final dividerCount = groups.length - 1;
    final menuHeight =
        headerHeight + actions.length * itemHeight + dividerCount * 9 + 16; // padding
    
    double left = anchor.dx;
    double top = anchor.dy;
    
    // 水平翻转：如果右侧空间不够，菜单向左展开
    const menuWidth = 280.0;
    if (left + menuWidth > screenSize.width) {
      left = screenSize.width - menuWidth - 8;
    }
    if (left < 8) left = 8;
    
    // 垂直翻转：下方空间不够就**向上展开**（菜单底边贴住锚点上方）。
    // 安卓文件 TAB 的卡片常在底部 tab 栏附近，向下弹会盖住/贴着 tab 栏，
    // 用户要求「菜单要从 tab 栏上方弹出」（反馈了两次，上一次没修对）。
    final double maxBottom = screenSize.height - _kBottomBarReserve;
    // 锚点本身就是「手指按住的那个卡片」的中心（安卓长按）或右键点（PC），
    // 向上翻转时从**卡片底边**起算，视觉上才是「贴着卡片往上弹」。
    final double anchorBottom = anchor.dy;
    if (top + menuHeight > maxBottom) {
      // 优先：整块菜单放到锚点上方
      final above = anchorBottom - menuHeight;
      if (above >= 8) {
        top = above;
      } else {
        // 空间确实不够（菜单比可用高度还高）：贴着底部预留区上沿，
        // 绝不能压进 tab 栏。
        top = maxBottom - menuHeight;
      }
    }
    if (top < 8) top = 8;
    // 兜底：任何情况下都不许压进底部 tab 栏预留区
    if (top + menuHeight > maxBottom) top = maxBottom - menuHeight;
    if (top < 8) top = 8;

    return Stack(
      children: [
        // 透明 barrier 覆盖全屏，点击空白处关闭菜单但不拦截底层事件传递
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => Navigator.pop(context),
            child: const SizedBox.expand(),
          ),
        ),
        // 菜单本体
        Positioned(
          left: left,
          top: top,
          width: menuWidth,
          child: FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, -0.1),
                end: Offset.zero,
              ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
              child: Material(
                elevation: 12,
                borderRadius: BorderRadius.circular(10),
                clipBehavior: Clip.antiAlias,
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (header != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Text(
                          header!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _headerTextStyle,
                        ),
                      ),
                    for (final group in groups) ...[
                      if (group != groups.first)
                        Divider(
                          height: 9,
                          thickness: 1,
                          indent: 12,
                          endIndent: 12,
                          color: Theme.of(context)
                              .colorScheme
                              .outlineVariant
                              .withValues(alpha: 0.5),
                        ),
                      for (final a in group)
                        _HoverMenuItem(
                          action: a,
                          itemHeight: itemHeight,
                          onSelected: () {
                            tapFeedback();
                            Navigator.pop(context, a.id);
                          },
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// PC 端菜单项：悬浮高亮。
///
/// **只保留一层 hover**（InkWell 自带的那层）。
///
/// 旧实现在 MouseRegion + AnimatedContainer 上自己维护了一套 `_hovering`，
/// 里面又套了一个 InkWell —— InkWell 自己也会响应 hover 画高亮，于是同一行
/// 有两套互相独立的悬浮判定，各自还有 100ms 防抖定时器，鼠标划过时两层
/// 不同步（一层已经亮、另一层还没亮/已经灭），看起来就是「闪烁、像两层
/// 悬浮判定」（用户反馈）。现在只留 InkWell 一层，天然同步、也没有定时器。
class _HoverMenuItem extends StatelessWidget {
  const _HoverMenuItem({
    required this.action,
    required this.itemHeight,
    required this.onSelected,
  });

  final IconMenuAction action;
  final double itemHeight;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDesktop = !YuChuanPlatform.isAndroid;

    return InkWell(
      onTap: onSelected,
      mouseCursor: isDesktop ? SystemMouseCursors.click : MouseCursor.defer,
      // 悬浮高亮交给 InkWell 自己：单层、无防抖、与点击反馈同源
      hoverColor: scheme.primaryContainer.withValues(alpha: 0.5),
      child: SizedBox(
        height: itemHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: _MenuRow(
            icon: action.icon,
            label: action.label,
            tone: action.tone,
          ),
        ),
      ),
    );
  }
}

/// 带图标的操作菜单：Android 用底部菜单，桌面用右键自定义弹出菜单（有动画+防误触）。
///
/// 消息气泡 / 文件卡片 / 文件 TAB 共用；[header] 是可选的标题行。
/// 菜单外点击拦截：barrierColor=transparent + barrierDismissible=true。
Future<String?> showIconMenu(
  BuildContext context, {
  required List<IconMenuAction> actions,
  String? header,
  Offset? anchor,
}) {
  // 设置里可切：底部弹层（安卓习惯）/ 就地弹出菜单（桌面习惯）
  final useSheet = AppearanceState.instance.useBottomSheetMenus &&
      Theme.of(context).platform == TargetPlatform.android;
  final groups = groupMenuActions(actions);
  tapFeedback();
  if (!useSheet) {
    // 菜单贴着触发点弹出（不偏移到元素中心），桌面右键尤其重要
    final box = context.findRenderObject();
    final local = box is RenderBox ? box.size.center(Offset.zero) : Offset.zero;
    final origin = box is RenderBox ? box.localToGlobal(local) : Offset.zero;
    final at = anchor ?? origin;
    final overlay = Overlay.of(context);
    final overlaySize = overlay.context.size ?? MediaQuery.sizeOf(context);
    
    final route = _AnimatedPopupMenuRoute<String>(
      actions: actions,
      anchor: at,
      header: header,
      screenSize: overlaySize,
    );
    return Navigator.push(context, route);
  }
  return showModalBottomSheet<String>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (header != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(header,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _headerTextStyle),
            ),
          for (final group in groups) ...[
            if (group != groups.first)
              Divider(
                height: 1,
                thickness: 1,
                indent: 16,
                endIndent: 16,
                color: Theme.of(context)
                    .colorScheme
                    .outlineVariant
                    .withValues(alpha: 0.5),
              ),
            for (final a in group)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                leading: Icon(a.icon,
                    size: 20,
                    color: _toneColor(Theme.of(context).colorScheme, a.tone)),
                title: Text(
                  a.label,
                  style: _menuTextStyle.copyWith(
                    color: _toneColor(Theme.of(context).colorScheme, a.tone),
                    fontWeight: a.tone == MenuTone.danger ||
                            a.tone == MenuTone.primary
                        ? FontWeight.w600
                        : null,
                  ),
                ),
                onTap: () {
                  tapFeedback();
                  Navigator.pop(sheetContext, a.id);
                },
              ),
          ],
        ],
      ),
    ),
  );
}

/// 执行用户选中的那一条。
Future<void> runIconMenuAction(
    String? picked, List<IconMenuAction> actions) async {
  if (picked == null) return;
  for (final a in actions) {
    if (a.id == picked) {
      await a.run();
      return;
    }
  }
}
