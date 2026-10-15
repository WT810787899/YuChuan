import 'dart:async';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

/// 桌面自定义标题栏高度（与 `AppTitleBar` 的 38px 对齐）。
const double _kTitleBarHeight = 38.0;

/// 页面自身的标题栏高度（如聊天页头部 `minHeight: 56`）。
/// OSD 必须同时避开它，否则会压在「会话标题」那一行上（用户反馈）。
const double _kPageHeaderHeight = 56.0;

/// 安卓顶部额外让出的距离（用户要求：OSD 再往下，至少再让出一个按钮的高度）。
/// 用户反馈过两次，第一次给的 14 不够 —— 直接按「一个按钮高度」给 48。
const double _kAndroidTopGap = 48.0;

/// OSD 圆角（用户要求：比原来的 28 明显减小）。
const double _kRadius = 12.0;

/// 是否为桌面。用 `defaultTargetPlatform` 而非 `Platform.isWindows`，
/// 这样 widget 测试可以用 `debugDefaultTargetPlatformOverride` 伪造平台。
bool get _isDesktop =>
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux ||
    defaultTargetPlatform == TargetPlatform.macOS;

/// OSD 提示气泡：关键色（主色）+ 半透明 + 圆角 + 轻微入场动画。
///
/// 用于替代 ScaffoldMessenger 的 Snack：用户要求「类似 已辅助 等的弹出横条
/// UI 样式要关键色 半透明 圆角的」。全局共用一个 OverlayEntry，不会
/// 与 ScaffoldMessenger 的 snack 冲突。
class OsdToast {
  OsdToast._();

  static OverlayEntry? _current;
  static Timer? _timer;

  /// 显示一条 OSD 气泡。同一时刻只显示一条（新调用会顶掉旧的）。
  static void show(
    BuildContext context, {
    required String text,
    required Duration duration,
    required Icon icon,
    Color? color,
  }) {
    _timer?.cancel();
    _current?.remove();
    _current = null;

    final scheme = Theme.of(context).colorScheme;
    final t = color ?? scheme.primary;
    // 用户要求：只切字体颜色（浅色→黑、深色→白），底色与图标保留语义色。
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final entry = OverlayEntry(
      builder: (ctx) => _OsdToastWidget(
        text: text,
        icon: icon,
        color: t,
        textColor: isDark ? Colors.white : Colors.black,
        scheme: scheme,
        onDismiss: () {
          _current = null;
          _timer?.cancel();
          _timer = null;
        },
      ),
    );
    _current = entry;
    Overlay.of(context).insert(entry);

    _timer = Timer(duration, () {
      _current?.remove();
      _current = null;
      _timer = null;
    });
  }

  /// 便利：错误红 / 成功绿 / 信息主色。
  static void error(BuildContext context, String text) => show(
        context,
        text: text,
        duration: const Duration(seconds: 2),
        icon: const Icon(Icons.error_outline, size: 18),
        color: Theme.of(context).colorScheme.error,
      );

  static void success(BuildContext context, String text) => show(
        context,
        text: text,
        duration: const Duration(seconds: 2),
        icon: const Icon(Icons.check_circle_outline, size: 18),
        color: const Color(0xFF10B981),
      );

  static void info(BuildContext context, String text) => show(
        context,
        text: text,
        duration: const Duration(seconds: 2),
        icon: const Icon(Icons.info_outline, size: 18),
      );
}

class _OsdToastWidget extends StatefulWidget {
  const _OsdToastWidget({
    required this.text,
    required this.icon,
    required this.color,
    required this.textColor,
    required this.scheme,
    required this.onDismiss,
  });

  final String text;
  final Icon icon;
  final Color color;
  final Color textColor;
  final ColorScheme scheme;
  final VoidCallback onDismiss;

  @override
  State<_OsdToastWidget> createState() => _OsdToastWidgetState();
}

class _OsdToastWidgetState extends State<_OsdToastWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      duration: const Duration(milliseconds: 220),
      vsync: this,
    );
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, -0.6),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 顶部居中；SafeArea 让 OSD 落在自定义标题栏之下（用户反馈：原先贴顶压住标题栏）
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: Align(
        alignment: Alignment.topCenter,
        child: SafeArea(
          top: true,
          minimum: EdgeInsets.only(
            // 安卓没有自定义标题栏，但聊天页有自己的头部（minHeight: 56），
            // 再往下一个按钮高度（约 48），否则仍然「贴着会话标题」
            // （用户反馈：还要再往下，至少再有一个按钮高度的距离）。
            top: _isDesktop
                ? _kTitleBarHeight + _kPageHeaderHeight + 8
                : _kPageHeaderHeight + _kAndroidTopGap,
            left: 16,
            right: 16,
            bottom: 8,
          ),
          child: FadeTransition(
            opacity: _fade,
            child: SlideTransition(
              position: _slide,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(
                    color: widget.color.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(_kRadius),
                    // 阴影已删除：贴顶的硬阴影上缘会被看成一条横线（用户反馈「去掉横线」）。
                    // 边框也一律不画，避免任何"横向线条"观感。
                    border: null,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(widget.icon.icon, size: 18, color: widget.color),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          widget.text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: widget.textColor,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            // 用户要求「OSD 的文字不要出现横线」：
                            // 显式清掉下划线/删除线，杜绝任何来自主题或字体的横线。
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}