import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../appearance.dart';
import '../models.dart';
import '../services/transfer_service.dart';
import 'device_icons.dart';
import 'menus.dart';
import 'osd_toast.dart';

/// 消息 TAB 的会话列表（联系人已并入这里：配对成功的联系人即使还没聊过，
/// 也会以「已配对 · 点击开始聊天」出现在列表里）。
class ChatListPanel extends StatefulWidget {
  const ChatListPanel({super.key});

  @override
  State<ChatListPanel> createState() => _ChatListPanelState();
}

class _ChatListPanelState extends State<ChatListPanel> {
  final _searchCtrl = TextEditingController();
  final _state = AppState.instance;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final query = _state.searchQuery.trim().toLowerCase();
    final items = <int>[];
    for (var i = 0; i < _state.conversations.length; i++) {
      final c = _state.conversations[i];
      if (query.isEmpty ||
          c.device.name.toLowerCase().contains(query) ||
          c.device.alias.toLowerCase().contains(query) ||
          (c.last?.text.toLowerCase().contains(query) ?? false)) {
        items.add(i);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '消息 · ${_state.conversations.length}',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _searchCtrl,
                onChanged: _state.setSearch,
                decoration: InputDecoration(
                  hintText: '搜索联系人或消息',
                  prefixIcon: const Icon(Icons.search, size: 19),
                  suffixIcon: _searchCtrl.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear, size: 17),
                          onPressed: () {
                            _searchCtrl.clear();
                            _state.setSearch('');
                          },
                        ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Text(
                    query.isEmpty ? '暂无会话' : '没有匹配「$_state.searchQuery」的会话',
                    style: TextStyle(fontSize: 13, color: scheme.outline),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 2),
                  itemBuilder: (context, i) =>
                      _ConversationRow(convIndex: items[i]),
                ),
        ),
      ],
    );
  }
}

class _ConversationRow extends StatefulWidget {
  const _ConversationRow({required this.convIndex});

  final int convIndex;

  @override
  State<_ConversationRow> createState() => _ConversationRowState();
}

class _ConversationRowState extends State<_ConversationRow> {
  bool hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = AppState.instance;
    // 会话列表会随消息/配对变化重排，防止索引越界
    if (widget.convIndex >= state.conversations.length) {
      return const SizedBox.shrink();
    }
    final conv = state.conversations[widget.convIndex];
    final selected = state.navIndex == 0 &&
        state.selectedConversation == widget.convIndex;

    final last = conv.last;
    var preview = '';
    if (last != null) {
      switch (last.kind) {
        case MessageKind.text:
          preview = last.text;
        case MessageKind.image:
          preview = '[图片] ${last.fileName}';
        case MessageKind.file:
          preview = '[文件] ${last.fileName}';
      }
      if (last.fromMe) preview = '我: $preview';
    } else {
      // 联系人 TAB 已并入消息：刚配对、还没聊过的联系人也要有可读的摘要
      preview = conv.device.paired ? '已配对 · 点击开始聊天' : '还没有消息';
    }

    return MouseRegion(
      onEnter: (_) => setState(() => hovered = true),
      onExit: (_) => setState(() => hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => state.openConversation(widget.convIndex),
        // 移动端长按 / 桌面右键：同一套带图标的操作菜单
        onLongPress: () => _showRowMenu(state, conv.device),
        onSecondaryTap: () => _showRowMenu(state, conv.device),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          margin: const EdgeInsets.symmetric(horizontal: 8),
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primary.withValues(alpha: 0.10)
                : hovered
                    ? scheme.surfaceContainerHighest.withValues(alpha: 0.6)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  DeviceAvatar(device: conv.device, radius: 22),
                  if (conv.device.online)
                    Positioned(
                      right: -1,
                      bottom: -1,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: const Color(0xFF10B981),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: selected
                                ? scheme.primaryContainer
                                : scheme.surface,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      conv.device.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: scheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    last == null ? '' : relativeTime(last.time),
                    style: TextStyle(fontSize: 11, color: scheme.outline),
                  ),
                  const SizedBox(height: 6),
                  if (conv.unread > 0)
                    Container(
                      constraints: const BoxConstraints(minWidth: 18),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEF4444),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '${conv.unread}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    )
                  else
                    const SizedBox(height: 20),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 换头像：选一张图，落盘后显示在所有用到该联系人头像的地方。
  Future<void> _changeAvatar(LanDevice dev) async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    final path = result?.files.single.path;
    if (path == null || path.isEmpty) return;
    tapFeedback();
    AppState.instance.setContactAvatar(dev.id, path);
  }
  /// 改备注名：弹输入框，空提交 = 清掉备注、回到设备原名。
  Future<void> _renameContact(LanDevice dev) async {
    final ctrl = TextEditingController(text: dev.alias);
    final next = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('修改备注名称'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            hintText: dev.name,
            helperText: '留空则使用设备原名',
          ),
          onSubmitted: (v) => Navigator.pop(d, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, ctrl.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (next == null) return;
    tapFeedback();
    AppState.instance.renameContact(dev.id, next);
  }
  /// 会话行操作：移动端长按 / 桌面右键 —— 同一套带图标的菜单，
  /// 覆盖常用操作（打开、复制信息、接收目录、清空、删除联系人）。
  Future<void> _showRowMenu(AppState state, LanDevice dev) async {
    final actions = <IconMenuAction>[
      IconMenuAction(
        id: 'open',
        label: '打开会话',
        icon: Icons.chat_bubble_outline,
        run: () async => state.openConversationWith(dev.id),
      ),
      IconMenuAction(
        id: 'rename',
        label: '修改备注名称…',
        icon: Icons.edit_outlined,
        run: () async => _renameContact(dev),
      ),
      IconMenuAction(
        id: 'avatar',
        label: AppState.instance.contactAvatar(dev.id).isEmpty
            ? '设置头像…'
            : '更换头像…',
        icon: Icons.image_outlined,
        run: () async => _changeAvatar(dev),
      ),
      if (AppState.instance.contactAvatar(dev.id).isNotEmpty)
        IconMenuAction(
          id: 'avatarReset',
          label: '恢复默认头像',
          icon: Icons.restart_alt,
          run: () async => AppState.instance.setContactAvatar(dev.id, ''),
        ),
      IconMenuAction(
        id: 'copy',
        label: '复制设备信息',
        icon: Icons.copy_outlined,
        run: () async {
          await Clipboard.setData(
              ClipboardData(text: '${dev.name} ${dev.ip}'.trim()));
        },
      ),
      IconMenuAction(
        id: 'folder',
        label: '打开接收目录',
        icon: Icons.folder_open_outlined,
        run: () async {
          // 优先打开用户自定义的接收目录，没设就用默认收件目录
          var dir = AppearanceState.instance.receiveDir ?? '';
          if (dir.isEmpty) {
            try {
              dir = TransferService.instance.downloadDir();
            } catch (_) {
              // 桥接未就绪
            }
          }
          if (dir.isEmpty) return;
          final msg = await state.revealFolder(dir);
          if (mounted) OsdToast.info(context, msg);
        },
      ),
      IconMenuAction(
        id: 'clear',
        label: '清空本地聊天记录',
        icon: Icons.cleaning_services_outlined,
        run: () async => state.clearHistory(dev.id),
      ),
      IconMenuAction(
        id: 'remove',
        label: '删除联系人及其数据',
        icon: Icons.person_remove_outlined,
        run: () async => state.removeContact(dev.id),
      ),
    ];
    if (!mounted) return;
    final picked =
        await showIconMenu(context, actions: actions, header: dev.displayName);
    await runIconMenuAction(picked, actions);
  }
}

/// 共用头像：按设备平台给手绘的 PC/手机图标（不再是首字母渐变块）。
class DeviceAvatar extends StatelessWidget {
  const DeviceAvatar({super.key, required this.device, this.radius = 22});

  final LanDevice device;
  final double radius;

  @override
  Widget build(BuildContext context) {
    // 用户给该联系人设过头像就用图片，否则按平台给默认设备图标
    final custom = AppState.instance.contactAvatar(device.id);
    if (custom.isNotEmpty) {
      final f = File(custom);
      if (f.existsSync()) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(radius * 0.45),
          child: Image.file(
            f,
            width: radius * 2,
            height: radius * 2,
            fit: BoxFit.cover,
            cacheWidth: (radius * 4).round(),
            // 图片读不出来时退回默认图标，不要留空块
            errorBuilder: (_, __, ___) => MyDeviceAvatar(
              size: radius * 2,
              platform: device.platform,
            ),
          ),
        );
      }
    }
    return MyDeviceAvatar(
      size: radius * 2,
      platform: device.platform,
    );
  }
}


