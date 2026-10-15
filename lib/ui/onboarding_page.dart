import 'package:flutter/material.dart';

/// 全屏首次使用引导（T5.5 重做）：多页 PageView + 进度点 + 「开始使用」。
///
/// 原来是设备页顶部的小卡片，用户反馈「没做好」—— 改为启动即弹的全屏引导，
/// 逐页讲清「发现 → 配对 → 聊天 → 传文件」，最后一页一键进入。
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  late final PageController _ctrl;
  int _page = 0;

  static const _pages = <(IconData, Color, String, String, List<String>)>[
    (
      Icons.radar_outlined,
      Color(0xFF6366F1),
      '自动发现附近设备',
      '手机与电脑连同一个 Wi-Fi，打开应用就能互相看到。',
      ['无需注册、无需联网', '同一局域网自动互见', '找不到时可手动输入 IP 直连'],
    ),
    (
      Icons.link,
      Color(0xFF8B5CF6),
      '核对 PIN，安全配对',
      '点击「配对」，双方屏幕显示相同的 6 位 PIN，确认一致即成为联系人。',
      ['6 位 PIN 防误配', '60 秒超时保护', '重启后免重新配对'],
    ),
    (
      Icons.forum_outlined,
      Color(0xFF06B6D4),
      '像微信一样聊天',
      '文字实时送达，历史本地保存，重启不丢。Enter 发送、Shift+Enter 换行。',
      ['实时消息 + 已发出状态', '断线自动重连', '500 条历史流畅滚动'],
    ),
    (
      Icons.folder_zip_outlined,
      Color(0xFF10B981),
      '拖进去就传文件',
      '把文件拖进聊天窗口，或点「+」发送。支持断点续传，大文件也稳。',
      ['任意文件 / 图片', '断点续传 + 完整校验', '收件在「文件」页统一查看'],
    ),
  ];

  @override
  void initState() {
    super.initState();
    _ctrl = PageController();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  bool get _isLast => _page == _pages.length - 1;

  void _next() {
    if (_isLast) {
      widget.onDone();
      return;
    }
    _ctrl.nextPage(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: Column(
          children: [
            // 顶部：跳过 + 进度点
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '跳过引导',
                    icon: Icon(Icons.close, size: 20, color: scheme.outline),
                    onPressed: widget.onDone,
                  ),
                  const Spacer(),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < _pages.length; i++)
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: i == _page ? 20 : 7,
                          height: 7,
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          decoration: BoxDecoration(
                            color: i == _page
                                ? _pages[_page].$2
                                : scheme.outlineVariant,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                    ],
                  ),
                  const Spacer(),
                  const SizedBox(width: 48),
                ],
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _ctrl,
                itemCount: _pages.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (context, i) {
                  final (icon, color, title, subtitle, bullets) = _pages[i];
                  return _OnboardingSlide(
                    icon: icon,
                    color: color,
                    title: title,
                    subtitle: subtitle,
                    bullets: bullets,
                  );
                },
              ),
            ),
            // 底部：上一页 / 开始使用
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: Row(
                children: [
                  if (_page > 0)
                    TextButton.icon(
                      onPressed: () => _ctrl.previousPage(
                        duration: const Duration(milliseconds: 280),
                        curve: Curves.easeOutCubic,
                      ),
                      icon: const Icon(Icons.arrow_back, size: 18),
                      label: const Text('上一页'),
                    )
                  else
                    const SizedBox.shrink(),
                  const Spacer(),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: _pages[_page].$2,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 26, vertical: 14),
                    ),
                    onPressed: _next,
                    icon: Icon(_isLast ? Icons.check : Icons.arrow_forward,
                        size: 18),
                    label: Text(_isLast ? '开始使用' : '继续'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OnboardingSlide extends StatelessWidget {
  const _OnboardingSlide({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.bullets,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final List<String> bullets;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 92,
            height: 92,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(28),
            ),
            child: Icon(icon, size: 46, color: color),
          ),
          const SizedBox(height: 32),
          Text(
            title,
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          Text(
            subtitle,
            style: TextStyle(
                fontSize: 15, height: 1.5, color: scheme.outline),
          ),
          const SizedBox(height: 26),
          for (final b in bullets)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Icon(Icons.check_circle, size: 20, color: color),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(b,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w500)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
