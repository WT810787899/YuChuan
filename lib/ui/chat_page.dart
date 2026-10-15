import 'dart:async';
import 'dart:io' show Directory, File, Platform;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';

import '../app_state.dart';
import '../appearance.dart';
import '../models.dart';
import '../services/platform_channel.dart';
import 'chat_list.dart';
import 'device_icons.dart';
import 'linkify.dart';
import 'menus.dart';
import 'osd_toast.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.peerId});

  /// 会话以 peer_id 标识（会话列表会重排，传对象会拿到过期实例）。
  final String peerId;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  late final TextEditingController _ctrl;
  final _focusNode = FocusNode();
  final _scroll = ScrollController();
  final _state = AppState.instance;

  /// reverse 列表：pixels==0 就是最新一条。
  bool _atBottom = true;
  /// 用户上翻期间来了新消息 → 显示「新消息」按钮（T3.8）。
  bool _hasNewBelow = false;
  int _lastCount = 0;
  bool _loadingOlder = false;

  Conversation get _conv => _state.conversationFor(widget.peerId);

  /// 多选模式下已选中的消息 id（空 = 非多选模式）。
  final Set<String> _selected = {};

  bool get _selecting => _selected.isNotEmpty;

  /// 聊天窗口内容过滤器：'all' | 'text' | 'image' | 'file'。
  /// 在头部「筛选」按钮里切换，只影响本会话显示，不删数据。
  String _contentFilter = 'all';

  /// 筛选项文案（菜单与 tooltip 共用，避免两处写死的字串漂移）。
  static String _filterLabel(String value) => switch (value) {
        'text' => '仅文本',
        'image' => '仅图片',
        'file' => '仅文件',
        _ => '全部消息',
      };

  /// 筛选态 → (图标, 文案)。
  ///
  /// 用户要求「筛选按钮换样式使其更直观」，同时**必须保持纯图标**：
  /// 所以每个筛选态给一个专属图标，形状本身就能说明「现在在筛什么」。
  (IconData, String) get _filterIcon => switch (_contentFilter) {
        'text' => (Icons.text_fields_outlined, _filterLabel('text')),
        'image' => (Icons.image_outlined, _filterLabel('image')),
        'file' => (Icons.insert_drive_file_outlined, _filterLabel('file')),
        _ => (Icons.filter_alt_outlined, _filterLabel('all')),
      };

  /// 安卓返回：多选模式下先退出多选（再由 Shell 决定回列表/切 TAB）。
  bool _onBack() {
    if (_selected.isEmpty) return false;
    setState(() => _selected.clear());
    return true;
  }

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: _conv.draft);
    _ctrl.addListener(_syncDraft);
    _scroll.addListener(_onScroll);
    _lastCount = _conv.messages.length;
    // Enter-send via HardwareKeyboard: runs BEFORE the focus chain, so the
    // multi-line EditableText cannot swallow Enter first.
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    AppState.instance.backHandler = _onBack;
    // 首次进入：拉最近 50 条历史（存储层 keyset 分页）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _state.loadHistory(widget.peerId);
    });
  }

  @override
  void didUpdateWidget(covariant ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.peerId != widget.peerId) {
      _ctrl.text = _conv.draft;
      _lastCount = _conv.messages.length;
      _atBottom = true;
      _hasNewBelow = false;
      _state.loadHistory(widget.peerId);
    }
  }

  /// 上翻到最早附近就再拉一页（keyset 分页，T3.8）。
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final atBottom = pos.pixels <= 60;
    if (atBottom != _atBottom || (atBottom && _hasNewBelow)) {
      setState(() {
        _atBottom = atBottom;
        if (atBottom) _hasNewBelow = false;
      });
    }
    if (pos.pixels >= pos.maxScrollExtent - 200) {
      _maybeLoadOlder();
    }
  }

  Future<void> _maybeLoadOlder() async {
    if (_loadingOlder) return;
    if (_conv.messages.length < AppState.chatPageSize) return; // 不足一页 = 已到底
    _loadingOlder = true;
    await _state.loadHistory(widget.peerId, older: true);
    _loadingOlder = false;
  }

  void _scrollToBottom() {
    _scroll.animateTo(
      0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  bool _onHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    // T5.4：Ctrl+V 粘贴发送（图片/文件/文本三类；文本自己插入以替代默认粘贴）
    if (event.logicalKey == LogicalKeyboardKey.keyV &&
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed)) {
      if (!_focusNode.hasFocus) return false;
      // 中文输入法组合中放行，避免干扰候选
      if (_ctrl.value.composing.isValid) return false;
      unawaited(_pasteFromClipboard());
      return true;
    }
    if (event.logicalKey != LogicalKeyboardKey.enter) return false;
    if (!_focusNode.hasFocus || HardwareKeyboard.instance.isShiftPressed) {
      return false;
    }
    // Let the IME commit an in-progress composition (e.g. Chinese pinyin).
    if (_ctrl.value.composing.isValid) return false;
    _send();
    return true;
  }

  /// Ctrl+V：优先文件（资源管理器复制）→ 图片位图（截图）→ 文本（自行插入）。
  Future<void> _pasteFromClipboard() async {
    try {
      // 1) 文件路径（Explorer 里复制的文件）
      final files = await Pasteboard.files();
      if (files.isNotEmpty) {
        for (final path in files) {
          if (path.isEmpty || !File(path).existsSync()) continue;
          final lower = path.toLowerCase();
          final isImage = ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp']
              .any(lower.endsWith);
          await _state.sendFilePath(
            path,
            kind: isImage ? MessageKind.image : MessageKind.file,
          );
        }
        return;
      }
      // 2) 位图数据（截图复制）
      final image = await Pasteboard.image;
      if (image != null && image.isNotEmpty) {
        final dir = Directory.systemTemp.createTempSync('yuchuan_paste');
        final path =
            '${dir.path}${Platform.pathSeparator}粘贴图片_${DateTime.now().millisecondsSinceEpoch}.png';
        File(path).writeAsBytesSync(image);
        await _state.sendFilePath(path, kind: MessageKind.image);
        return;
      }
      // 3) 文本：默认粘贴已被本 handler 吞掉，这里自己插到光标处
      final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
      final text = clipboard?.text ?? '';
      if (text.isEmpty) return;
      final value = _ctrl.value;
      final selection = value.selection;
      if (selection.isValid && selection.isCollapsed) {
        final start = selection.start;
        final newText = value.text.replaceRange(start, start, text);
        _ctrl.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: start + text.length),
        );
      } else if (selection.isValid) {
        final newText =
            value.text.replaceRange(selection.start, selection.end, text);
        _ctrl.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(
              offset: selection.start + text.length),
        );
      } else {
        _ctrl.text = value.text + text;
      }
      _syncDraft();
    } catch (e) {
      _showSnack('粘贴失败：$e');
    }
  }

  @override
  void dispose() {
    if (AppState.instance.backHandler == _onBack) {
      AppState.instance.backHandler = null;
    }
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _ctrl.removeListener(_syncDraft);
    _scroll.removeListener(_onScroll);
    _ctrl.dispose();
    _scroll.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _syncDraft() {
    _conv.draft = _ctrl.text;
  }

  void _send() {
    if (_ctrl.value.composing.isValid) return;
    final text = _ctrl.text;
    if (text.trim().isEmpty) return;
    setState(() => _ctrl.clear());
    _state.sendMessage(text);
  }


  /// 发送整个文件夹：递归发送里面的所有文件，文件名带上目录结构
  /// （'文件夹»子目录»文件名'），对端收到后会还原成同样的目录。
  Future<void> _pickAndSendFolder() async {
    try {
      final dir = await FilePicker.platform
          .getDirectoryPath(dialogTitle: '选择要发送的文件夹');
      if (dir == null || dir.isEmpty) return;
      final root = Directory(dir);
      final rootName = root.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final files = <File>[];
      if (root.existsSync()) {
        for (final f in root.listSync(recursive: true)) {
          if (f is File) files.add(f);
        }
      }
      if (files.isEmpty) {
        _showSnack('这个文件夹里没有文件');
        return;
      }
      _showSnack('正在发送 $rootName（${files.length} 个文件）');
      for (final f in files) {
        final rel = f.path
            .substring(root.path.length)
            .replaceAll('\\', '/')
            .replaceFirst(RegExp(r'^[/]+'), '');
        final encoded =
            [rootName, ...rel.split('/')].join(AppState.kFolderSep);
        await AppState.instance
            .sendFilePath(f.path, fileNameOverride: encoded);
      }
    } catch (e) {
      _showSnack('选择文件夹失败：$e');
    }
  }

  /// 真实选文件发送（T4.6）；取消选择不产生消息。
  Future<void> _pickAndSend({required bool image}) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: image ? FileType.image : FileType.any,
        allowMultiple: false,
      );
      final path = result?.files.single.path;
      if (path == null || path.isEmpty) return;
      await _state.sendFilePath(
        path,
        kind: image ? MessageKind.image : MessageKind.file,
      );
    } catch (e) {
      _showSnack('选择文件失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final conv = _conv;
    final scheme = Theme.of(context).colorScheme;
    final narrow = MediaQuery.sizeOf(context).width < 900;
    final items = _buildItems(conv.messages);

    // 用户上翻期间来了新消息 → 提示「新消息」而不是强行吸底（T3.8）
    if (conv.messages.length > _lastCount && !_atBottom) {
      _hasNewBelow = true;
    }
    _lastCount = conv.messages.length;

    // T5.4 拖拽发送：整个聊天区域都是投放区（Windows 拖文件进窗口）
    return DropTarget(
      onDragDone: (detail) => _onDragDone(detail),
      child: Column(
      children: [
        // ---- header ----
        // 透明背景：标题栏与页面/壁纸融为一体，不凸出来（用户反馈）。
        // 用 minHeight 而不是固定高度：窄屏两行文字不会溢出。
        Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: const BoxDecoration(color: Colors.transparent),
          child: Row(
            children: [
             if (narrow)
               // 窄屏返回箭头：纯文本‹（左双引号开），不显示成 Icon 组件。
               IconButton(
                 icon: Container(
                   width: 18, height: 36,
                   alignment: Alignment.centerLeft,
                   child: Text('‹', style: const TextStyle(fontSize: 18)),
                 ),
                 padding: EdgeInsets.zero,
                 constraints: const BoxConstraints.tightFor(width: 18, height: 36),
                 onPressed: _state.backToListPanel,
               ),
             DeviceAvatar(device: conv.device, radius: 18),
             const SizedBox(width: 10),
             Expanded(
               child: Column(
                 mainAxisAlignment: MainAxisAlignment.center,
                 crossAxisAlignment: CrossAxisAlignment.start,
                 children: [
                   Text(
                     conv.device.displayName,
                     style: const TextStyle(
                         fontSize: 15, fontWeight: FontWeight.w700),
                   ),
                   Text(
                     '${conv.device.online ? '在线' : '离线'} · ${conv.device.platform == DevicePlatform.windows ? 'Windows' : 'Android'}',
                     style: TextStyle(
                       fontSize: 11.5,
                       color: conv.device.online
                           ? const Color(0xFF10B981)
                           : scheme.outline,
                     ),
                   ),
                 ],
               ),
             ),
              IconButton(
                tooltip: '筛选消息内容：${_filterIcon.$2}',
                // 用户裁决：**只有图标，只换图标样式**，不加文字标签/胶囊/新控件，
                // 也不动尺寸与位置。所以「当前在筛什么」全靠图标形状本身表达，
                // 再用一个主色小圆点表示「筛选生效中」。
                icon: _contentFilter == 'all'
                    ? Icon(_filterIcon.$1, size: 20)
                    : Badge(
                        backgroundColor: scheme.primary,
                        smallSize: 7,
                        child: Icon(_filterIcon.$1,
                            size: 20, color: scheme.primary),
                      ),
                onPressed: _showFilterMenu,
              ),
              PopupMenuButton<String>(
                tooltip: '更多',
                icon: const Icon(Icons.more_horiz, size: 20),
                onSelected: (v) {
                  if (v == 'clear') {
                    _state.clearHistory(widget.peerId);
                    _showSnack('已清空本地聊天记录');
                  } else if (v == 'info') {
                    _showSnack(
                        '与 ${conv.device.displayName} 的会话 · 历史 ${conv.messages.length} 条（本地存储）');
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'info', child: Text('会话信息')),
                  PopupMenuItem(value: 'clear', child: Text('清空本地记录')),
                  PopupMenuItem(value: 'export', child: Text('导出记录（敬请期待）')),
                ],
              ),
            ],
          ),
        ),

        // ---- messages ----
        Expanded(
          child: Stack(
            children: [
              if (items.isEmpty)
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.forum_outlined, size: 34, color: scheme.outline),
                      const SizedBox(height: 10),
                      Text(
                        _state.chatReady
                            ? '还没有消息，发第一条吧'
                            : (_state.chatError.isNotEmpty
                                ? _state.chatError
                                : '聊天链路启动中…'),
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13, color: scheme.outline),
                      ),
                    ],
                  ),
                )
              else
                GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () => _focusNode.unfocus(),
                  child: ListView.builder(
                    controller: _scroll,
                    reverse: true,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    itemCount: items.length,
                    itemBuilder: (context, i) {
                      final item = items[items.length - 1 - i];
                      if (item.sep != null) return _TimeSep(item.sep!);
                      final msg = item.msg!;
                      return _MessageRow(
                        msg: msg,
                        device: conv.device,
                        selected: _selected.contains(msg.id),
                        onStartSelect: () {
                          tapFeedback();
                          setState(() => _selected.add(msg.id));
                        },
                        // 多选中：气泡菜单的「转发」作用于选中的全部（用户要求）
                        onForward: () {
                          if (_selecting && _selected.length > 1) {
                            _forwardSelected();
                          } else {
                            _forwardMessage(msg);
                          }
                        },
                        // 双端统一切换语义：重复点即取消勾选（用户要求）。
                        // 之前安卓端刻意「只追加不取消」，与用户诉求相反，已废弃。
                        onToggleSelect: _selecting
                            ? () {
                                tapFeedback();
                                setState(() {
                                  if (!_selected.remove(msg.id)) {
                                    _selected.add(msg.id);
                                  }
                                });
                              }
                            : null,
                      );
                    },
                  ),
                ),
              // 上翻看历史时来了新消息：悬浮按钮回到最新（PLAN §3.5 P1）
              if (_hasNewBelow)
                Positioned(
                  right: 16,
                  bottom: 12,
                  child: FloatingActionButton.small(
                    tooltip: '回到最新',
                    onPressed: () {
                      setState(() => _hasNewBelow = false);
                      _scrollToBottom();
                    },
                    child: const Icon(Icons.arrow_downward, size: 18),
                  ),
                ),
            ],
          ),
        ),

        // ---- input bar / 多选操作条 ----
        if (_selecting)
          _buildSelectionBar(conv)
        else
          _InputBar(
            controller: _ctrl,
            focusNode: _focusNode,
            onSend: _send,
            onFile: () => _pickAndSend(image: false),
            onImage: () => _pickAndSend(image: true),
            onFolder: _pickAndSendFolder,
          ),
      ],
      ),
    );
  }

  /// T5.4 拖拽投放：把拖进来的文件逐个真实发送。
  Future<void> _onDragDone(DropDoneDetails details) async {
    final files = details.files;
    if (files.isEmpty) return;
    for (final file in files) {
      final path = file.path;
      if (path.isEmpty) continue;
      final lower = path.toLowerCase();
      final isImage = ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp']
          .any(lower.endsWith);
      await _state.sendFilePath(
        path,
        kind: isImage ? MessageKind.image : MessageKind.file,
      );
    }
    _showSnack('已发送 ${files.length} 个文件');
  }

  List<_Item> _buildItems(List<ChatMessage> msgs) {
    final out = <_Item>[];
    var prevKept = false; // 过滤后相邻保留项的时间间距判断
    ChatMessage? lastKept;
    for (var j = 0; j < msgs.length; j++) {
      final m = msgs[j];
      // 内容过滤：按类型隐藏消息（只改显示，不删数据）
      if (_contentFilter != 'all') {
        final keep = switch (_contentFilter) {
          'text' => m.kind == MessageKind.text,
          'image' => m.kind == MessageKind.image,
          'file' => m.kind == MessageKind.file,
          _ => true,
        };
        if (!keep) continue;
      }
      if (!prevKept ||
          lastKept == null ||
          m.time.difference(lastKept.time).inMinutes >= 5) {
        out.add(_Item.sep(m.time));
      }
      out.add(_Item.msg(m));
      lastKept = m;
      prevKept = true;
    }
    return out;
  }

  /// 多选操作条：转发 / 删除 / 取消。
  Widget _buildSelectionBar(Conversation conv) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 10),
      color: scheme.primaryContainer.withValues(alpha: 0.55),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Text(
              '${_selected.length} 条已选',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            TextButton.icon(
              icon: const Icon(Icons.forward, size: 18),
              label: const Text('转发'),
              onPressed: _forwardSelected,
            ),
            TextButton.icon(
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('删除'),
              onPressed: _deleteSelected,
            ),
            TextButton(
              onPressed: () => setState(() => _selected.clear()),
              child: const Text('取消'),
            ),
          ],
        ),
      ),
    );
  }

  /// 单条转发：选一个联系人发过去。
  Future<void> _forwardMessage(ChatMessage m) async {
    final target = await _pickContact();
    if (target == null) return;
    await _forwardOne(target, m);
    _snack('已转发到 ${target.name}');
  }

  Future<void> _forwardSelected() async {
    final target = await _pickContact();
    if (target == null) return;
    final picked =
        _conv.messages.where((m) => _selected.contains(m.id)).toList();
    for (final m in picked) {
      await _forwardOne(target, m);
    }
    setState(() => _selected.clear());
    _snack('已转发 ${picked.length} 条到 ${target.name}');
  }

  Future<void> _forwardOne(LanDevice target, ChatMessage m) async {
    final state = AppState.instance;
    if (m.kind == MessageKind.text) {
      await state.sendTextTo(target.id, m.text);
      return;
    }
    final path = state.localFilePath(m);
    if (path.isEmpty) {
      _snack('原文件已不在，无法转发');
      return;
    }
    await state.sendFilePath(path, kind: m.kind, peerId: target.id);
  }

  /// 选一个联系人（会话列表 = 已配对的人）。
  Future<LanDevice?> _pickContact() async {
    final state = AppState.instance;
    final contacts = state.conversations.map((c) => c.device).toList();
    if (contacts.isEmpty) {
      _snack('还没有可转发的联系人');
      return null;
    }
    final id = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('转发到',
                    style: TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w700)),
              ),
            ),
            for (final d in contacts)
              ListTile(
                leading: DeviceAvatar(device: d, radius: 16),
                title: Text(d.name),
                subtitle: Text(d.online ? '在线' : '离线'),
                onTap: () {
                  tapFeedback();
                  Navigator.pop(sheetContext, d.id);
                },
              ),
          ],
        ),
      ),
    );
    if (id == null) return null;
    return contacts.where((d) => d.id == id).firstOrNull;
  }

  Future<void> _deleteSelected() async {
    final conv = _conv;
    final picked =
        conv.messages.where((m) => _selected.contains(m.id)).toList();
    for (final m in picked) {
      AppState.instance.deleteMessage(m);
    }
    setState(() => _selected.clear());
    _snack('已删除 ${picked.length} 条');
  }

  void _snack(String text) => _showSnack(text);

  /// 头部内容筛选菜单。
  void _showFilterMenu() {
    showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('筛选消息内容',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              ),
            ),
            for (final (value, icon) in const [
              ('all', Icons.all_inclusive),
              ('text', Icons.text_fields_outlined),
              ('image', Icons.image_outlined),
              ('file', Icons.insert_drive_file_outlined),
            ])
              ListTile(
                leading: Icon(icon, size: 20),
                title: Text(_filterLabel(value)),
                trailing: _contentFilter == value
                    ? Icon(Icons.check, size: 20,
                        color: Theme.of(sheetContext).colorScheme.primary)
                    : null,
                onTap: () => Navigator.pop(sheetContext, value),
              ),
          ],
        ),
      ),
    ).then((value) {
      if (value != null && mounted) {
        setState(() => _contentFilter = value);
      }
    });
  }

  /// 所有通知统一走 OSD（横幅已按用户要求删除：「已发送」等通知也走 OSD）。
  void _showSnack(String text) {
    if (!mounted) return;
    OsdToast.info(context, text);
  }
}



class _Item {
  const _Item.sep(this.sep)
      : msg = null;
  const _Item.msg(this.msg)
      : sep = null;

  final ChatMessage? msg;
  final DateTime? sep;
}

class _TimeSep extends StatelessWidget {
  const _TimeSep(this.time);

  final DateTime time;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 10),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          '${time.month}-${time.day.toString().padLeft(2, '0')} ${clockTime(time)}',
          style: TextStyle(fontSize: 11, color: scheme.outline),
        ),
      ),
    );
  }
}

// ============================================================
// Message row / bubble
// ============================================================

class _MessageRow extends StatefulWidget {
  const _MessageRow({
    required this.msg,
    required this.device,
    this.selected = false,
    this.onToggleSelect,
    this.onStartSelect,
    this.onForward,
  });

  final ChatMessage msg;
  final LanDevice device;

  /// 多选模式：是否已选中，以及点按切换选中（null = 非多选模式）。
  final bool selected;
  final VoidCallback? onToggleSelect;

  /// 菜单里的「多选 / 转发」由父级（聊天页）实现。
  final VoidCallback? onStartSelect;
  final VoidCallback? onForward;

  @override
  State<_MessageRow> createState() => _MessageRowState();
}

/// 出站气泡底色：按消息类型区分，且**全部基于主色生成**并压半透明。
///
/// 之前直接取 scheme.secondary / tertiary，但这两个色阶在很多主题下
/// 都跟主色同色系（比如主题是蓝，secondary 也是蓝紫），三种类型
/// 区分不开（用户反馈「主题是蓝色，对应不上」）。
/// 现在：从主色出发，按类型做色相偏移 —— 三种类型都能分得开，
/// 且都属于主色附近的一族，不会脱离主题。
/// 出站气泡底色：按消息类型区分，且**全部基于主色生成**并压半透明。
///
/// 之前直接取 scheme.secondary / tertiary，但这两个色阶在很多主题下
class _MessageRowState extends State<_MessageRow> {
  /// 右键点击位置（菜单贴着它弹出，不偏移到气泡中心）。
  Offset? _menuPos;

  bool _hovered = false;

  ChatMessage get m => widget.msg;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 设置里可调：气泡最大宽度 / 圆角 / 是否播入场动画
    final ap = AppearanceState.instance;
    final radius = ap.bubbleRadius;
    // 选择态：onToggleSelect 非空即处于多选模式。选择态下关闭入场/悬浮动画、
    // 隔离重绘，保证「点一下加一个」不卡。
    final selecting = widget.onToggleSelect != null;

    // 气泡底色计算（按类型、深浅、收发分支）
    Color bubbleColor;
    Color bubbleTextColor;
    if (m.kind == MessageKind.image) {
      // 图片：外层透明，内容自带边界
      bubbleColor = Colors.transparent;
      bubbleTextColor = m.fromMe ? Colors.white : scheme.onSurface;
    } else if (m.fromMe) {
      // 本端：按类型固定/适配
      final opacity = AppearanceState.instance.bubbleOpacity;
      final keyColor = scheme.primary;
      final keyColorDark = HSLColor.fromColor(keyColor).withLightness(0.35).toColor();
      switch (m.kind) {
        case MessageKind.text:
          bubbleColor = const Color(0xFF5AB66F);
          bubbleTextColor = Colors.white;
          break;
        case MessageKind.image:
          bubbleColor = keyColor.withValues(alpha: opacity);
          bubbleTextColor = Colors.white;
          break;
        case MessageKind.file:
          bubbleColor = isDark
              ? keyColorDark.withValues(alpha: opacity)
              : keyColor.withValues(alpha: opacity);
          bubbleTextColor = Colors.white;
          break;
      }
    } else {
      // 对端
      switch (m.kind) {
        case MessageKind.text:
          bubbleColor = isDark ? const Color(0xFF31333D) : Colors.white;
          bubbleTextColor = scheme.onSurface;
          break;
        case MessageKind.image:
          bubbleColor = Colors.transparent;
          bubbleTextColor = scheme.onSurface;
          break;
        case MessageKind.file:
          bubbleColor = isDark ? const Color(0xFF4F7795) : scheme.surfaceContainerHighest;
          bubbleTextColor = isDark ? Colors.white : scheme.onSurface;
          break;
      }
    }
    
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: ap.bubbleMaxWidth),
      padding: m.kind == MessageKind.text
          ? const EdgeInsets.symmetric(horizontal: 13, vertical: 10)
          : const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: bubbleColor,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(radius),
          topRight: Radius.circular(radius),
          bottomLeft: Radius.circular(m.fromMe ? radius : 4),
          bottomRight: Radius.circular(m.fromMe ? 4 : radius),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: _buildBubbleContent(scheme, isDark, bubbleTextColor),
    );

    // 自己发的：用手绘的 PC/手机头像（不是 ME 文字）
    final avatar = m.fromMe
        ? const MyDeviceAvatar(size: 36)
        : DeviceAvatar(device: widget.device, radius: 18);

    final content = Column(
      crossAxisAlignment:
          m.fromMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // 多选模式下，点按=勾选/取消
            onTap: widget.onToggleSelect,
            // 移动端长按 / 桌面端右键：操作菜单；双击：直接复制文字
            onLongPress: () {
              HapticFeedback.lightImpact();
              _showMessageMenu(context);
            },
            // 记住右键点，菜单贴着鼠标弹出（不偏移到气泡中心）
            onSecondaryTapDown: (d) => _menuPos = d.globalPosition,
            onSecondaryTap: () => _showMessageMenu(context),
            // 双击复制文字。**多选态下不注册**：Flutter 的 TapGestureRecognizer
            // 只要同节点上有 onDoubleTap，就会把单击压后到双击窗口（约 300ms）
            // 才判定 —— 用户反馈的「多选勾选不跟手、卡」就是这个延迟。
            // 多选态下双击没有意义，去掉它，单击即刻生效。
            onDoubleTap: selecting
                ? null
                : (m.kind == MessageKind.text && m.text.isNotEmpty
                    ? () async {
                        HapticFeedback.selectionClick();
                        await Clipboard.setData(ClipboardData(text: m.text));
                        _snack('已复制');
                      }
                    : null),
            child: AnimatedOpacity(
              duration: selecting
                  ? Duration.zero
                  : const Duration(milliseconds: 120),
              opacity: _hovered && !selecting ? 0.92 : 1,
              child: bubble,
            ),
          ),
        ),
        const SizedBox(height: 3),
        _buildStatusRow(scheme),
      ],
    );

    // T5.2 气泡入场：fade + 轻微上滑 120ms（设置里可整体关掉）。
    //
    // key 用消息 id：没有 key 时 ListView 重建会让 TweenAnimationBuilder
    // 重新创建、动画从 0 重放 —— 多选每点一下整屏气泡闪一次，就是
    // 用户反馈的「多选卡卡的」。稳定 key 让它只在真正新增气泡时跑一次。
    // 选择态下直接跳过入场动画（没必要，且避免点选时重放）。
    final entrance = (!selecting && ap.animationsEnabled)
        ? TweenAnimationBuilder<double>(
            key: ValueKey(widget.msg.id),
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            builder: (context, t, child) => Opacity(
              opacity: t,
              child:
                  Transform.translate(offset: Offset(0, 8 * (1 - t)), child: child),
            ),
            child: content,
          )
        : content;

    // 用户要求：**不要选中背景叠加**，只保留勾选圈 —— 勾选圈就是唯一的选中标识。
    // 选择态下仍整行隔离重绘，点一下只重画这一条，不波及整屏。
    final wrapped = selecting ? RepaintBoundary(child: entrance) : entrance;

    // 勾选圈：未选中=空心环；已选中=实心主色圆 + 白色对勾。
    // 圈本身也能点选（追加/取消，与点气泡同一动作）。
    final check = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onToggleSelect,
      child: AnimatedContainer(
        duration: Duration.zero,
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.selected ? scheme.primary : Colors.transparent,
          border: Border.all(
            color: widget.selected ? scheme.primary : scheme.outline,
            width: 2,
          ),
        ),
        child: widget.selected
            ? const Icon(Icons.check, size: 16, color: Colors.white)
            : null,
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisAlignment:
            m.fromMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!m.fromMe) ...[
            avatar,
            const SizedBox(width: 6),
            Flexible(child: wrapped),
            // 内侧（远离头像的一侧）：对端圈在气泡右边
            if (selecting) ...[const SizedBox(width: 4), check],
          ] else ...[
            // 内侧：本端圈在气泡左边
            if (selecting) ...[check, const SizedBox(width: 4)],
            Flexible(child: wrapped),
            const SizedBox(width: 6),
            avatar,
          ],
        ],
      ),
    );
  }

  Widget _buildBubbleContent(ColorScheme scheme, bool isDark, Color bubbleTextColor) {
    switch (m.kind) {
      case MessageKind.text:
        // 自动识别链接：固定显示为蓝色，单击用系统浏览器打开
        return LinkifiedText(
          text: m.text,
          color: bubbleTextColor,
          linkColor: m.fromMe
              ? const Color(0xFFDBEAFE) // 绿色气泡上：浅蓝才看得清
              : (isDark ? const Color(0xFF3B82F6) : const Color(0xFF1E40AF)),
        );
      case MessageKind.image:
        // 多选模式：卡片内层手势会抢点击，选择态下让位给外层的「点选」手势。
        // onMenu：长按（安卓）/ 右键（桌面）由气泡自己出菜单，
        // 菜单内容复用本行的 `_showMessageMenu`（非文本分支已含多选入口）。
        // A1：右键落点也由气泡自己这一层记录后回填给本行（见 _ImageBubble
        // 的 onSecondaryTapDown 说明），否则菜单只能回落到整行中心。
        return _ImageBubble(
          msg: m,
          selecting: widget.onToggleSelect != null,
          onMenu: () => _showMessageMenu(context),
          onSecondaryTapDown: (d) => _menuPos = d.globalPosition,
        );
      case MessageKind.file:
        return _FileBubble(
            msg: m,
            onForward: widget.onForward,
            onStartSelect: widget.onStartSelect,
            selecting: widget.onToggleSelect != null);
    }
  }

  Widget _buildStatusRow(ColorScheme scheme) {
    if (!m.fromMe) return const SizedBox.shrink();
    final textColor = scheme.outline;

    Widget status;
    if (m.queued && !m.failed) {
      // 离线排队：对方上线后自动补发（不是失败，别吓用户）
      status = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.schedule, size: 13, color: Color(0xFFF59E0B)),
          const SizedBox(width: 3),
          Text('离线待发',
              style: TextStyle(
                  fontSize: 11,
                  color: const Color(0xFFF59E0B),
                  fontWeight: FontWeight.w600)),
        ],
      );
    } else if (m.failed) {
      // OSD 风格胶囊：半透明 errorContainer 底 + onErrorContainer 文字
      status = InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => AppState.instance.retryMessage(m),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: scheme.errorContainer.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline,
                  size: 13, color: scheme.onErrorContainer),
              const SizedBox(width: 4),
              Text(
                '发送失败 · 点击重试',
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onErrorContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );
    } else if (m.state == SendState.sending) {
      status = const SizedBox(
        width: 11,
        height: 11,
        child: CircularProgressIndicator(strokeWidth: 1.6),
      );
    } else if (m.state == SendState.sent) {
      status = const Icon(Icons.check, size: 14, color: Color(0xFF10B981));
    } else {
      status = const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check, size: 14, color: Color(0xFF10B981)),
          Icon(Icons.check, size: 14, color: Color(0xFF10B981)),
        ],
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(clockTime(m.time), style: TextStyle(fontSize: 10.5, color: textColor)),
        const SizedBox(width: 5),
        status,
      ],
    );
  }

  /// 消息操作：桌面右键 / 移动端长按。菜单带图标，条目按消息类型动态增减。
  Future<void> _showMessageMenu(BuildContext context) async {
    final state = AppState.instance;
    final actions = <IconMenuAction>[];


    if (m.kind == MessageKind.text && m.text.isNotEmpty) {
      actions.add(IconMenuAction(
        id: 'copy',
        label: '复制',
        icon: Icons.copy_outlined,
        run: () async {
          await Clipboard.setData(ClipboardData(text: m.text));
          _snack('已复制到剪贴板');
        },
      ));
      final links = findLinks(m.text);
      if (links.isNotEmpty) {
        final url = links.first.url;
        actions.add(IconMenuAction(
          id: 'link',
          label: '打开链接',
          icon: Icons.link,
          run: () => _openOrSnack(
              YuChuanPlatform.openUrl(url), '已在浏览器打开'),
        ));
      }
      // 重新发送：自己发的、以及发送失败的都能重发（用户要求）
      if (m.fromMe || m.failed) {
        actions.add(IconMenuAction(
          id: 'resend',
          label: '重新发送',
          icon: Icons.refresh,
          run: () => state.retryMessage(m),
        ));
      }
    } else {
      final path =
          m.filePath.isNotEmpty ? m.filePath : state.localImagePath(m) ?? '';
      if (path.isNotEmpty && File(path).existsSync()) {
        actions.add(IconMenuAction(
          id: 'open',
          label: '打开文件',
          icon: Icons.open_in_new,
          run: () => _openOrSnack(YuChuanPlatform.openFile(path), '已调起系统打开方式'),
        ));
        actions.add(IconMenuAction(
          id: 'folder',
          label: '打开所在文件夹',
          icon: Icons.folder_open_outlined,
          run: () async => _snack(await state.revealFolder(path)),
        ));
      }
      final transferring = m.progress < 1 && !m.failed;
      if (transferring) {
        actions.add(IconMenuAction(
          id: 'cancel',
          label: '取消传输',
          icon: Icons.cancel_outlined,
          run: () async {
            await state.cancelTransfer(m);
            _snack('已取消传输 ${m.fileName}');
          },
        ));
      } else if (m.fromMe && m.filePath.isNotEmpty) {
        actions.add(IconMenuAction(
          id: 'resend',
          label: '重新发送',
          icon: Icons.refresh,
          run: () => state.retryTransfer(m),
        ));
      }
    }
    if (widget.onForward != null) {
      actions.add(IconMenuAction(
        id: 'forward',
        label: '转发',
        icon: Icons.forward,
        run: () async => widget.onForward!(),
      ));
    }
    if (widget.onStartSelect != null) {
      actions.add(IconMenuAction(
        id: 'multi',
        label: '多选',
        icon: Icons.checklist,
        run: () async => widget.onStartSelect!(),
      ));
    }
    actions.add(IconMenuAction(
      id: 'delete',
      label: '删除',
      icon: Icons.delete_outline,
      run: () async {
        state.deleteMessage(m);
        _snack('已删除该消息');
      },
    ));

    final picked = await showIconMenu(context, actions: actions, anchor: _menuPos);
    if (picked == null) return;
    for (final a in actions) {
      if (a.id == picked) {
        await a.run();
        return;
      }
    }
  }

  Future<void> _openOrSnack(Future<String?> op, String okText) async {
    final err = await op;
    _snack(err == null ? okText : '打开失败：$err');
  }



  void _snack(String text) {
    if (!mounted) return;
    OsdToast.info(context, text);
  }
}

// ============================================================
// File message card
// ============================================================

class _FileBubble extends StatefulWidget {
  const _FileBubble({
    required this.msg,
    this.onForward,
    this.onStartSelect,
    this.selecting = false,
  });

  final ChatMessage msg;

  /// 转发这条消息（由页面层注入；多选时页面层会转发全部）。
  final VoidCallback? onForward;

  /// 菜单里的「多选」：由外层行注入，与文字气泡共用同一入口
  /// （用户要求：所有类型的气泡菜单都要有多选）。
  final VoidCallback? onStartSelect;

  /// 多选模式：卡片自身不再响应「单击打开」，交给外层行负责选中（用户要求：
  /// 进入多选后，文件卡片和勾选框都能点选）。
  final bool selecting;

  @override
  State<_FileBubble> createState() => _FileBubbleState();
}

class _FileBubbleState extends State<_FileBubble> {
  /// 右键点击位置（菜单贴着它弹出）。
  Offset? _menuPos;

  ChatMessage get m => widget.msg;
  bool get _active => m.progress < 1 && !m.failed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ext = fileExt(m.fileName);
    // 文件卡片宽度：手机端必须明显收短 —— 左右各让出一个「头像列」
    // （头像 36 + 间距 6 = 42），保证气泡不会横穿到对方头像的位置；
    // PC/平板维持原值不动（bubbleMaxWidth clamp 240..320）。
    final ap = AppearanceState.instance;
    final screenW = MediaQuery.of(context).size.width;
    final narrow = screenW < 900;
    final maxW = narrow
        ? (screenW - 16 * 2 - 42 * 2).clamp(200.0, 280.0).toDouble()
        : ap.bubbleMaxWidth.clamp(240.0, 320.0).toDouble();
    // 文字颜色跟随气泡底色：本端白字，对端自适应
    final titleColor = m.fromMe ? Colors.white : (isDark ? Colors.white : scheme.onSurface);
    final subColor = m.fromMe
        ? Colors.white.withValues(alpha: 0.85)
        : (isDark ? Colors.white.withValues(alpha: 0.7) : scheme.outline);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        // 多选模式：不注册单击手势（否则会把外层行的「点选」手势吃掉），
        // 点击落到外层 = 勾选/追加（用户要求）。
        onTap: widget.selecting ? null : () {
          tapFeedback();
          _onTap();
        },
        onLongPress: () {
          if (Theme.of(context).platform == TargetPlatform.android) {
            HapticFeedback.mediumImpact();
          }
          _showFileMenu();
        },
        onSecondaryTapDown: (d) => _menuPos = d.globalPosition,
        onSecondaryTap: _showFileMenu,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: maxW,
          padding: const EdgeInsets.all(11),
          // 文件卡片：与文字气泡明显区分 —— 中性底 + 类型色描边 + 类型图标
          decoration: BoxDecoration(
            // 出站/入站深色：半透明白，让气泡底色透出；
            // 入站浅色：surfaceContainerHighest 微透。
            color: m.fromMe
                ? Colors.white.withValues(alpha: 0.14)
                : isDark
                    ? Colors.white.withValues(alpha: 0.12)
                    : scheme.surfaceContainerHighest.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              // 出站/入站深色都用半透明黑边框，保持一致；
              // 入站浅色用类型色半透明边框（保留类型识别）。
              color: m.fromMe
                  ? const Color(0x26000000)
                  : isDark
                      ? const Color(0x26000000)
                      : extColor(ext).withValues(alpha: 0.4),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // 图标保持**类型色**（用户要求：保留类型识别）。
                  // 对比度靠底片拉开：底片用半透明白，在出站的彩色气泡上
                  // 会明显比气泡亮一档，类型色图标落在上面就看得清；
                  // 入站是中性卡底，底片用类型色浅底同样成立。
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: m.fromMe
                          ? Colors.white.withValues(alpha: 0.5)
                          : extColor(ext).withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: m.fromMe
                            ? Colors.white.withValues(alpha: 0.6)
                            : extColor(ext).withValues(alpha: 0.35),
                      ),
                    ),
                    // 图标一律用类型色，不再随出站变白
                    child: Icon(extIcon(ext), color: extColor(ext), size: 24),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          m.fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: titleColor,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          formatBytes(m.fileSize),
                          style: TextStyle(fontSize: 11.5, color: subColor),
                        ),
                      ],
                    ),
                  ),
                  if (!_active && !m.failed)
                    Icon(
                        m.fromMe ? Icons.check_circle_outline : Icons.open_in_new,
                        size: 20,
                        color: m.fromMe ? scheme.onPrimary : scheme.primary),
                ],
              ),
              if (_active || m.failed) ...[
                const SizedBox(height: 10),
                // T5.2：400ms 拉取的离散进度 → 平滑插值到目标值
                ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: m.failed ? 0 : m.progress),
                    duration: AppearanceState.instance.animationsEnabled
                        ? const Duration(milliseconds: 320)
                        : Duration.zero,
                    curve: Curves.easeOut,
                    builder: (context, v, _) => LinearProgressIndicator(
                      value: m.failed ? null : v,
                      minHeight: 6,
                      backgroundColor: (m.fromMe
                              ? Colors.white
                              : scheme.primary)
                          .withValues(alpha: 0.18),
                      valueColor: AlwaysStoppedAnimation(
                        m.failed
                            ? const Color(0xFFEF4444)
                            : m.fromMe
                                ? Colors.white
                                : scheme.primary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 7),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        m.failed
                            ? '传输失败'
                            // 离线排队：**不是**在算哈希，也永远不会有进度。
                            // 必须先判它，否则排队中的文件会一直显示「计算校验值…」
                            // —— 用户看到的就是「一直在计算校验值」（以为卡死/失败）。
                            // 文字消息有「离线待发」胶囊，文件气泡以前漏了这一支。
                            : (m.queued
                                ? '离线待发 · 等对方上线自动发送'
                                : (m.progress == 0 &&
                                        m.state == SendState.sending
                                    // 还没有任何字节被确认，但传输已注册 →
                                    // 大概率在算 blake3 哈希（大文件会卡几秒）。
                                    ? '计算校验值… ${formatBytes(m.fileSize)}'
                                    : '${(m.progress * 100).toStringAsFixed(0)}% · ${formatBytes((m.fileSize * m.progress).toInt())} / ${formatBytes(m.fileSize)}')),
                        style: TextStyle(
                          fontSize: 11,
                          color: m.failed
                              ? const Color(0xFFEF4444)
                              : m.queued
                                  ? const Color(0xFFF59E0B)
                                  : m.fromMe
                                      ? Colors.white
                                      : scheme.outline,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    // 暂停/继续：纯发送侧状态机，连接与在途块照常
                    if (!m.failed && m.fromMe && m.fileId.isNotEmpty)
                      TextButton(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: const Size(0, 26),
                        ),
                        onPressed: () {
                          if (m.paused) {
                            AppState.instance.resumeTransfer(m);
                          } else {
                            AppState.instance.pauseTransfer(m);
                          }
                        },
                        child: Text(
                          m.paused ? '继续' : '暂停',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: m.fromMe ? Colors.white : scheme.primary,
                          ),
                        ),
                      ),                    TextButton(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 26),
                      ),
                      onPressed: () {
                        if (m.failed) {
                          AppState.instance.retryTransfer(m);
                        } else {
                          AppState.instance.cancelTransfer(m);
                        }
                      },
                      child: Text(
                        m.failed ? '重试' : '取消',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: m.fromMe ? Colors.white : scheme.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 单击：完成的文件直接用系统方式打开（安卓 apk → 安装器）；
  /// 传输中给提示；失败=重试。
  void _onTap() {
    if (_active) {
      _snack('正在传输 ${m.fileName}…');
      return;
    }
    if (m.failed) {
      AppState.instance.retryTransfer(m);
      return;
    }
    final path = AppState.instance.localFilePath(m);
    if (path.isEmpty) {
      _snack(m.fromMe ? '原文件已不在原位置，无法打开' : '文件还没接收完成');
      return;
    }
    YuChuanPlatform.openFile(path).then((err) {
      if (!mounted) return;
      _snack(err == null ? '已调起系统打开方式' : '打开失败：$err');
    });
  }

  /// 长按（安卓）/ 右键（桌面）：文件专属操作，全部带图标。
  Future<void> _showFileMenu() async {
    final state = AppState.instance;
    final path = state.localFilePath(m);
    final actions = <IconMenuAction>[
      // 转发：与文字气泡菜单一致（用户反馈文件气泡缺这项）
      if (!_active)
        IconMenuAction(
          id: 'forward',
          label: '转发',
          icon: Icons.forward,
          run: () async {
            final cb = widget.onForward;
            if (cb != null) cb();
          },
        ),
      // 多选：与前面几项一致（用户要求：所有类型气泡都要有多选菜单）。
      // 传输中不提供 —— 与「转发」同样只在完成态可用。
      if (!_active && widget.onStartSelect != null)
        IconMenuAction(
          id: 'multi',
          label: '多选',
          icon: Icons.checklist,
          run: () async => widget.onStartSelect!(),
        ),
      // 完成态也可重新发送（用户要求与文字气泡对齐）
      if (!_active && !m.failed && m.fromMe && m.filePath.isNotEmpty)
        IconMenuAction(
          id: 'resend',
          label: '重新发送',
          icon: Icons.refresh,
          run: () async => state.retryTransfer(m),
        ),
      if (path.isNotEmpty && !_active) ...[
        IconMenuAction(
          id: 'open',
          label: '打开文件',
          icon: Icons.open_in_new,
          run: () async {
            final err = await YuChuanPlatform.openFile(path);
            if (mounted) _snack(err == null ? '已调起系统打开方式' : '打开失败：$err');
          },
        ),
        IconMenuAction(
          id: 'folder',
          label: '打开所在文件夹',
          icon: Icons.folder_open_outlined,
          run: () async {
            final msg = await AppState.instance.revealFolder(path);
            if (mounted) _snack(msg);
          },
        ),
      ],
      if (_active)
        IconMenuAction(
          id: 'cancel',
          label: '取消传输',
          icon: Icons.cancel_outlined,
          run: () async {
            await state.cancelTransfer(m);
            if (mounted) _snack('已取消传输 ${m.fileName}');
          },
        )
      else if (m.failed)
        IconMenuAction(
          id: 'retry',
          label: '重新发送',
          icon: Icons.refresh,
          run: () => state.retryTransfer(m),
        ),
      IconMenuAction(
        id: 'delete',
        label: '删除这条消息',
        icon: Icons.delete_outline,
        run: () async {
          state.deleteMessage(m);
          if (mounted) _snack('已删除该消息');
        },
      ),
    ];

    final picked =
        await showIconMenu(context, actions: actions, header: m.fileName, anchor: _menuPos);
    if (picked == null) return;
    for (final a in actions) {
      if (a.id == picked) {
        await a.run();
        return;
      }
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    OsdToast.info(context, text);
  }
}

// ============================================================
// Image message
// ============================================================

/// 图片气泡（T5.1）：有本地文件 → `Image.file` 解码 400px 缩略图
/// （cacheWidth 控制解码尺寸，imageCache 缓存不重复解码，PLAN §3.6-3）；
/// 传输中/文件缺失 → 占位渐变 + 进度环。
class _ImageBubble extends StatelessWidget {
  const _ImageBubble({
    required this.msg,
    this.selecting = false,
    this.onMenu,
    this.onSecondaryTapDown,
  });

  final ChatMessage msg;

  /// 多选模式：气泡自己把手势整个让出去（单击 / 长按 / 右键全不注册），
  /// 点按语义落到外层行的「勾选/取消」。
  final bool selecting;

  /// 长按（安卓）/ 右键（桌面）出菜单：由外层行注入，让图片气泡与
  /// 文字/文件气泡一样有「多选 / 转发 / 删除」入口（用户要求）。
  final VoidCallback? onMenu;

  /// 右键落点回调：由**气泡自己这一层的手势**记录落点，再回填给外层
  /// 行当菜单锚点（`_FileBubble` 是自持 `_menuPos`，图片气泡复用外层
  /// 行的 `_showMessageMenu`，所以这里只回填位置）。
  ///
  /// 根因：手势竞技场把一次快速右键判给最深的识别器，外层 `_MessageRow`
  /// 的 `onSecondaryTapDown` 因而收不到，`_menuPos` 保持 null，
  /// `showIconMenu` 只能回落到整行中心 —— 菜单不贴鼠标。
  final GestureTapDownCallback? onSecondaryTapDown;

  /// 本地路径：发送方=源文件；接收方=收件目录里按文件名找（含重名编号）。
  String? get _localPath => AppState.instance.localImagePath(msg);

  bool get _hasImage => _localPath != null;

  @override
  Widget build(BuildContext context) {
    final transferring = msg.progress < 1 && !msg.failed;
    return GestureDetector(
      // 多选态：图片气泡**自己**把单击 / 长按 / 右键三路全部注销
      // （onTap / onLongPress / onSecondaryTapDown / onSecondaryTap 全为
      // null），点按语义整个让给外层行的「勾选/取消」。
      //
      // 注意：这与文件卡片**不同**——`_FileBubble` 只把 `onTap` 挂在
      // `selecting` 上，它的 `onLongPress` 在多选态**照样**弹菜单
      // （见 _FileBubbleState.build）。所以这里不能写「与文件卡片同一套
      // 约定」，那是与原码不符的描述（原注释的毛病，已改正）。
      onTap: selecting
          ? null
          : () {
              if (transferring) return;
              _openPreview(context);
            },
      onLongPress: selecting ? null : onMenu,
      // A1：右键落点必须由本层记录。快速右键在手势竞技场里判给最深的
      // 识别器，外层 `_MessageRow.onSecondaryTapDown` 收不到，`_menuPos`
      // 会保持 null，菜单只能回落到整行中心（不贴鼠标）。
      // 做法与 `_FileBubble:1309` 同一套：本层记落点 → 交给菜单当锚点。
      onSecondaryTapDown: selecting ? null : onSecondaryTapDown,
      onSecondaryTap: selecting ? null : onMenu,
      child: Hero(
        tag: 'img-${msg.id}',
        // 图片：圆角 + 细边框，按原始比例完整显示（不裁剪）。
        // 固定半透明黑描边：outlineVariant 会被主题染色，看着像绿边。
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: const Color(0x26000000),
              width: 1,
            ),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 210, maxHeight: 260),
            child: Stack(
              children: [
                if (_hasImage)
                  Image.file(
                    File(_localPath!),
                    fit: BoxFit.contain, // 完整显示，不裁剪
                    cacheWidth: 520,
                    errorBuilder: (_, __, ___) =>
                        SizedBox(width: 200, height: 132, child: _placeholder(msg.fileName)),
                  )
                else
                  SizedBox(width: 200, height: 132, child: _placeholder(msg.fileName)),
                if (transferring)
                  Positioned.fill(
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.45),
                      alignment: Alignment.center,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 30,
                            height: 30,
                            child: CircularProgressIndicator(
                              value: msg.progress,
                              strokeWidth: 2.4,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${(msg.progress * 100).toStringAsFixed(0)}%',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static Widget _placeholder(String fileName) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: thumbnailGradient(fileName),
        ),
        child: const Center(
          child: Icon(Icons.image_outlined, size: 34, color: Colors.white70),
        ),
      );

  Widget _placeholderPreview() => Container(
        width: 720,
        height: 460,
        decoration: BoxDecoration(
          gradient: thumbnailGradient(msg.fileName),
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.image_outlined,
                size: 64, color: Colors.white70),
            const SizedBox(height: 12),
            Text(
              msg.fileName,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              msg.filePath.isEmpty ? '图片尚未落盘' : '原图不可用',
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
          ],
        ),
      );

  void _openPreview(BuildContext context) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InteractiveViewer(
              maxScale: 4,
              child: Hero(
                tag: 'img-${msg.id}',
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                        maxWidth: 720, maxHeight: 460),
                    child: _hasImage
                        ? Image.file(
                            File(_localPath!),
                            fit: BoxFit.contain,
                            gaplessPlayback: true,
                            errorBuilder: (_, __, ___) =>
                                _placeholderPreview(),
                          )
                        : _placeholderPreview(),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close),
              label: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// Input bar
// ============================================================

class _InputBar extends StatefulWidget {
  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.onSend,
    required this.onFile,
    required this.onImage,
    required this.onFolder,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSend;
  final VoidCallback onFile;
  final VoidCallback onImage;
  final VoidCallback onFolder;

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  /// 右键点击位置（菜单贴着它弹出）。
  Offset? _menuPos;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final canSend = widget.controller.text.trim().isNotEmpty;

    // 底色跟着壁纸走：有壁纸时半透明，不再和背景生硬分层；
    // 透明度由设置项「输入区域不透明度」统一控制（0 = 全透明，1 = 不透明）。
    final opacity = AppearanceState.instance.inputOpacity;
    final bg = AppearanceState.instance.hasWallpaper
        ? scheme.surface.withValues(alpha: 0.45 * opacity)
        : (Theme.of(context).cardTheme.color ?? scheme.surface)
            .withValues(alpha: opacity);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        color: bg,
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4)),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              PopupMenuButton<String>(
                tooltip: '发送文件 / 图片',
                icon: Icon(Icons.add_circle_outline,
                    size: 26, color: scheme.outline),
                onSelected: (v) {
                  if (v == 'file') widget.onFile();
                  if (v == 'image') widget.onImage();
                  if (v == 'folder') widget.onFolder();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'file', child: Text('发送文件')),
                  PopupMenuItem(value: 'image', child: Text('发送图片')),
                  PopupMenuItem(value: 'folder', child: Text('发送文件夹')),
                ],
              ),
              const SizedBox(width: 6),
              Expanded(
                // 右键菜单：复制 / 全选 / 清空 / 粘贴 / 粘贴并发送（桌面）
                child: Listener(
                  // 用**裸指针事件**而不是 GestureDetector：TextField 内部自带
                  // 手势识别器，右键会被它赢下（它要弹系统的选择工具栏），
                  // 外层 GestureDetector 的 onSecondaryTap 永远收不到 ——
                  // 这正是「输入栏的右键菜单一直没装上」的原因。
                  // Listener 走指针路由、不参与手势竞技场，必定先收到。
                  onPointerDown: YuChuanPlatform.isAndroid
                      ? null
                      : (e) {
                          if ((e.buttons & kSecondaryButton) == 0) return;
                          // 记住右键点，菜单贴着鼠标弹出（不偏移到元素中心）
                          _menuPos = e.position;
                          _showInputMenu(context);
                        },
                  child: TextField(
                    controller: widget.controller,
                    focusNode: widget.focusNode,
                    // 桌面：打开会话即可直接打字；手机不自动聚焦（进聊天窗不自动
                    // 弹软键盘，点输入区再弹）。用 Theme 平台判断，测试可 fake。
                    autofocus:
                        Theme.of(context).platform != TargetPlatform.android,
                    // 桌面：关掉 TextField 自带的系统右键工具栏，
                    // 否则会和我们的菜单同时弹出（两层菜单）。
                    contextMenuBuilder: YuChuanPlatform.isAndroid
                        ? null
                        : (ctx, editableState) => const SizedBox.shrink(),
                    // PC 默认两行高，手机保持一行（软键盘空间宝贵）
                    minLines: YuChuanPlatform.isAndroid ? 1 : 2,
                    // 最大行数可在「设置-界面-输入栏」里调（最多 12 行）
                    maxLines: AppearanceState.instance.inputMaxLines,
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      // 桌面：Enter 发送 / Shift+Enter 换行；Android 用右侧发送钮
                      hintText: Platform.isAndroid
                          ? '输入消息…'
                          : '输入消息，Enter 发送，Shift+Enter 换行',
                    ),
                    // T5.6：多行框 Enter 由 _onHardwareKey 处理（带 IME 保护），
                    // 这里的 onSubmitted 只作兜底（无障碍/IME 路径），同样避开组合态
                    onSubmitted: (_) {
                      if (!widget.controller.value.composing.isValid) {
                        widget.onSend();
                      }
                    },
                  ),
                ),
              ),
              const SizedBox(width: 10),
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                child: IconButton.filled(
                  tooltip: '发送 (Enter)',
                  icon: const Icon(Icons.send, size: 19),
                  onPressed: canSend ? widget.onSend : null,
                  style: IconButton.styleFrom(
                    backgroundColor:
                        canSend ? scheme.primary : scheme.surfaceContainerHighest,
                    foregroundColor:
                        canSend ? scheme.onPrimary : scheme.outline,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 输入框右键菜单：复制 / 全选 / 清空 / 粘贴 / 粘贴并发送（桌面）。
  Future<void> _showInputMenu(BuildContext context) async {
    final c = widget.controller;
    final hasText = c.text.isNotEmpty;
    final hasSelection = c.selection.start != c.selection.end;
    final actions = <IconMenuAction>[
      if (hasSelection)
        IconMenuAction(
          id: 'copy',
          label: '复制',
          icon: Icons.copy,
          run: () async {
            tapFeedback();
            await Clipboard.setData(ClipboardData(text: c.selection.textInside(c.text)));
          },
        ),
      if (hasText)
        IconMenuAction(
          id: 'selectAll',
          label: '全选',
          icon: Icons.select_all,
          run: () async {
            tapFeedback();
            c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length);
          },
        ),
      IconMenuAction(
        id: 'clear',
        label: '清空',
        icon: Icons.clear_all,
        run: () async {
          tapFeedback();
          c.clear();
          widget.focusNode.requestFocus();
        },
      ),
      IconMenuAction(
        id: 'paste',
        label: '粘贴',
        icon: Icons.content_paste,
        run: () async {
          final data = await Clipboard.getData('text/plain');
          final t = data?.text;
          if (t == null || t.isEmpty) return;
          tapFeedback();
          c.text += t;
          widget.focusNode.requestFocus();
        },
      ),
      IconMenuAction(
        id: 'pasteSend',
        label: '粘贴并发送',
        icon: Icons.playlist_add_check,
        run: () async {
          final data = await Clipboard.getData('text/plain');
          final t = data?.text;
          if (t == null || t.isEmpty) return;
          tapFeedback();
          c.text = t;
          widget.onSend();
        },
      ),
    ];
    if (!mounted) return;
    await runIconMenuAction(
      await showIconMenu(context, actions: actions, anchor: _menuPos),
      actions,
    );
  }
}
