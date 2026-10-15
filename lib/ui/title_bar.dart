import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// 自定义标题栏（Windows 无边框窗口）：左侧标题 + 设置按钮，右侧窗口控制。
///
/// Android 用原生状态栏/导航，不显示此栏。
class AppTitleBar extends StatefulWidget {
  const AppTitleBar({super.key, required this.title});

  final String title;

  @override
  State<AppTitleBar> createState() => _AppTitleBarState();
}

class _AppTitleBarState extends State<AppTitleBar> {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    _syncMaximized();
  }

  Future<void> _syncMaximized() async {
    try {
      final v = await windowManager.isMaximized();
      if (mounted) setState(() => _maximized = v);
    } catch (_) {
      // 窗口管理不可用（非桌面）
    }
  }

  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).platform == TargetPlatform.android) {
      return const SizedBox.shrink(); // 移动端用原生状态栏
    }
    final scheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onDoubleTap: _toggleMaximize,
      child: MouseRegion(
        cursor: SystemMouseCursors.move,
        child: DragToMoveArea(
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            color: Colors.transparent,
            child: Row(
              children: [
                const SizedBox(width: 10),
                Icon(Icons.chat_bubble_outline,
                    size: 15, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.title,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface.withValues(alpha: 0.85),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                _WindowButton(
                  icon: Icons.remove,
                  tooltip: '最小化',
                  hoverColor: Colors.amber,
                  onPressed: () => windowManager.minimize(),
                ),
                _WindowButton(
                  icon: _maximized ? Icons.filter_none : Icons.crop_square,
                  tooltip: _maximized ? '还原' : '最大化',
                  hoverColor: const Color(0xFF10B981),
                  onPressed: _toggleMaximize,
                ),
                _WindowButton(
                  icon: Icons.close,
                  tooltip: '关闭',
                  hoverColor: const Color(0xFFEF4444),
                  onPressed: () => windowManager.close(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _toggleMaximize() async {
    try {
      if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      } else {
        await windowManager.maximize();
      }
      _syncMaximized();
    } catch (_) {}
  }
}

class _WindowButton extends StatelessWidget {
  const _WindowButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.hoverColor,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color hoverColor;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onPressed,
        hoverColor: hoverColor.withValues(alpha: 0.22),
        child: SizedBox(
          width: 38,
          height: 30,
          child: Icon(icon, size: 15, color: Theme.of(context).colorScheme.outline),
        ),
      ),
    );
  }
}
