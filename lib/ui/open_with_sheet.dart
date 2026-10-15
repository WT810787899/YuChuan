import 'package:flutter/material.dart';

import '../services/platform_channel.dart';
import 'osd_toast.dart';

/// 「始终」记忆：文件扩展名 → 包名。
///
/// 用户要求：安卓自建「打开方式」窗口，选「始终」后**记住**，下次触发打开
/// 文件直接使用记忆的应用，不再弹窗。记忆粒度按扩展名（同一类文件走同一应用），
/// 无扩展名则按 `*` 兜底。
///
/// 存内存即可 —— 它只是「本次会话的快捷方式」，不写入配置，避免污染设置。
class OpenWithMemory {
  OpenWithMemory._();

  static final Map<String, OpenWithApp> _byExt = <String, OpenWithApp>{};

  /// 规范化扩展名（小写、带点；无扩展名用 `*`）。
  static String keyOf(String path) {
    final name = path.split(RegExp(r'[/\\]')).last;
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '*';
    return name.substring(dot).toLowerCase();
  }

  static OpenWithApp? remembered(String path) => _byExt[keyOf(path)];

  static void remember(String path, OpenWithApp app) {
    _byExt[keyOf(path)] = app;
  }

  static void forget(String path) => _byExt.remove(keyOf(path));

  @visibleForTesting
  static void clear() => _byExt.clear();
}

/// 自建「打开方式」窗口：列出候选应用 + 「仅一次 / 始终」二选一。
///
/// 用户要求（安卓）：自建选择窗口 --「仅一次/始终」，「始终」有记忆功能，
/// 下次触发打开文件直接使用记忆的应用。
///
/// 返回 true 表示已经把文件交给某个应用打开了。
Future<bool> showOpenWithChooser(BuildContext context, String path) async {
  final apps = await YuChuanPlatform.listOpenWithApps(path);
  if (!context.mounted) return false;
  if (apps.isEmpty) {
    OsdToast.error(context, '没有可以打开该文件的应用');
    return false;
  }

  final chosen = await showDialog<({OpenWithApp app, bool always})>(
    context: context,
    builder: (dialogContext) => _OpenWithSheet(
      path: path,
      apps: apps,
    ),
  );
  if (chosen == null || !context.mounted) return false;

  if (chosen.always) {
    OpenWithMemory.remember(path, chosen.app);
  }

  final err = await YuChuanPlatform.openFileWithPackage(path, chosen.app.package);
  if (!context.mounted) return false;
  if (err == null) {
    OsdToast.success(
      context,
      chosen.always ? '已用「${chosen.app.label}」打开并记住' : '已用「${chosen.app.label}」打开',
    );
    return true;
  }
  if (err == YuChuanPlatform.stalePackage) {
    // 记忆失效（应用被卸载/不再支持）→ 清掉记忆，提示重选
    OpenWithMemory.forget(path);
    OsdToast.error(context, '记住的应用已不可用，请重新选择');
    return false;
  }
  OsdToast.error(context, '打开失败：$err');
  return false;
}

/// 打开文件时统一入口：命中「始终」记忆就直接用它，否则弹自建窗口。
Future<bool> openFileRespectingMemory(BuildContext context, String path) async {
  final remembered = OpenWithMemory.remembered(path);
  if (remembered != null) {
    final err =
        await YuChuanPlatform.openFileWithPackage(path, remembered.package);
    if (!context.mounted) return false;
    if (err == null) return true;
    // 记忆失效则清理并回退到弹窗
    OpenWithMemory.forget(path);
    if (err != YuChuanPlatform.stalePackage) {
      OsdToast.error(context, '打开失败：$err');
      return false;
    }
  }
  return showOpenWithChooser(context, path);
}

class _OpenWithSheet extends StatefulWidget {
  const _OpenWithSheet({required this.path, required this.apps});

  final String path;
  final List<OpenWithApp> apps;

  @override
  State<_OpenWithSheet> createState() => _OpenWithSheetState();
}

class _OpenWithSheetState extends State<_OpenWithSheet> {
  int _index = 0;
  bool _always = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fileName = widget.path.split(RegExp(r'[/\\]')).last;
    // 屏幕高度的 60% 封顶：应用多的时候**内部滚动**翻页，而不是撑出屏幕
    // （用户要求：窗体不够展示要能滑动往下翻）。
    final maxListHeight =
        (MediaQuery.sizeOf(context).height * 0.6 - 210).clamp(120.0, 420.0);
    return AlertDialog(
      title: const Text('打开方式', style: TextStyle(fontSize: 16)),
      contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
      content: SizedBox(
        width: 330,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: scheme.outline),
              ),
            ),
            const SizedBox(height: 8),
            // 应用列表（图标 + 名称），高度受限时可滚动
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxListHeight),
              child: Scrollbar(
                child: ListView.builder(
                  shrinkWrap: true,
                  primary: false,
                  // 应用多时能一路滑到底
                  physics: const ClampingScrollPhysics(),
                  itemCount: widget.apps.length,
                  itemBuilder: (context, i) {
                    final app = widget.apps[i];
                    return RadioListTile<int>(
                      value: i,
                      groupValue: _index,
                      onChanged: (v) => setState(() => _index = v ?? 0),
                      dense: true,
                      // 应用图标（用户要求：选择应用要有图标）
                      secondary: _AppIcon(app: app, scheme: scheme),
                      title: Text(
                        app.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14),
                      ),
                      subtitle: app.isDefault
                          ? Text('当前默认',
                              style:
                                  TextStyle(fontSize: 11.5, color: scheme.outline))
                          : null,
                    );
                  },
                ),
              ),
            ),
            const Divider(height: 1),
            // 「仅一次 / 始终」两个动作（用户明确要求这两个选项）
            RadioListTile<bool>(
              value: false,
              groupValue: _always,
              onChanged: (v) => setState(() => _always = false),
              dense: true,
              title: const Text('仅一次', style: TextStyle(fontSize: 14)),
              subtitle: Text('每次打开都询问',
                  style: TextStyle(fontSize: 11.5, color: scheme.outline)),
            ),
            RadioListTile<bool>(
              value: true,
              groupValue: _always,
              onChanged: (v) => setState(() => _always = true),
              dense: true,
              title: const Text('始终', style: TextStyle(fontSize: 14)),
              subtitle: Text('记住该应用，下次直接打开',
                  style: TextStyle(fontSize: 11.5, color: scheme.outline)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            (app: widget.apps[_index], always: _always),
          ),
          child: const Text('打开'),
        ),
      ],
    );
  }
}

/// 候选应用图标：原生给的是 PNG 字节就显示真图标，取不到退回通用类型图标。
class _AppIcon extends StatelessWidget {
  const _AppIcon({required this.app, required this.scheme});

  final OpenWithApp app;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final bytes = app.iconPng;
    return SizedBox(
      width: 32,
      height: 32,
      child: bytes != null && bytes.isNotEmpty
          ? ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(
                bytes,
                width: 32,
                height: 32,
                fit: BoxFit.contain,
                // 图标解码失败也不能让整行崩掉
                errorBuilder: (_, __, ___) =>
                    Icon(Icons.android, size: 26, color: scheme.primary),
              ),
            )
          : Icon(Icons.android, size: 26, color: scheme.primary),
    );
  }
}
