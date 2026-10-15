import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../appearance.dart';
import '../models.dart';
import '../services/platform_channel.dart';
import '../services/transfer_service.dart';
import 'menus.dart';
import 'open_with_sheet.dart';
import 'osd_toast.dart';

/// 文件 TAB：收发文件的另一个视图（消息里该有的气泡一条不少，这里是集中入口）。
///
/// - 单击 = 选中，双击 = 打开（文件管理器习惯）
/// - 长按（安卓）/ 右键（桌面）= 带图标的操作菜单
/// - 支持多选、框选（Shift 范围选）、清空（可同时删除磁盘文件）
class FilesPage extends StatefulWidget {
  const FilesPage({super.key});

  /// 测试探针：统计扫盘期间的元数据读取（默认走真实 statSync）。
  /// 仅供测试验证「选中触发的重建不再读盘」，生产代码永不设置它。
  @visibleForTesting
  static FileStat Function(File)? statProbe;

  @override
  State<FilesPage> createState() => _FilesPageState();
}

/// 扫盘一次得到的文件条目：磁盘元数据缓存在这里，
/// 排序 / 过滤 / 渲染都不再碰磁盘。
class FileEntry {
  FileEntry(this.file, this.size, this.mtime, this.name, this.ext);
  final File file;
  final int size;
  final DateTime mtime;
  final String name;
  final String ext;

  /// apk 安装图标的缓存文件；null = 非 apk / 还没解析出 / 解析出的路径不存在。
  /// 扫盘后异步解析一次写在这里，build 只读它 —— 不再逐帧 `existsSync`。
  File? apkIcon;

  /// 这个 apk 的图标是否已经解析过（每轮扫盘每个 apk 只发起一次）。
  bool apkIconResolved = false;
}

/// 排序方式。
enum FileSort { timeDesc, timeAsc, nameAsc, nameDesc, sizeDesc, sizeAsc, typeAsc }

class _FilesPageState extends State<FilesPage> {
  bool _gridView = true;
  String _filter = 'all';
  FileSort _sort = FileSort.timeDesc;
  List<FileEntry> _files = [];
  bool _loaded = false;

  /// 选中的文件（按路径）；非空即进入多选操作条。
  final Set<String> _selected = {};
  int _lastTapIndex = -1;

  /// 瓦片的 GlobalKey（框选时用来命中检测）。
  final Map<String, GlobalKey> _tileKeys = {};

  /// 本帧内是否已经排过重扫。
  ///
  /// AppState 的通知非常密（传输进度、设备上下线、通知横幅…），每次都
  /// `listSync` 全量扫盘 + 重建整页瓦片，点选就会被拖到下一帧才跟上。
  /// 这里把同一次事件循环里的多次通知合并成一次扫盘。
  bool _reloadScheduled = false;

  /// 当前选框（**网格区局部坐标**，与 `_BandPainter` 的绘制坐标系一致）。
  ///
  /// 必须是局部坐标：选框是画在 Stack 里的（`Positioned.fill`），若存全局坐标，
  /// 一旦这个 Stack 不在屏幕原点（文件 TAB 上面还有标题栏/页头/过滤 chips），
  /// 画出来的框就会整体偏移 —— 这正是用户反馈的
  /// 「框选的起始位置要和鼠标对齐」。见 [_toBandLocal]。
  Rect? _bandRect;

  /// 框选起点（**网格区局部坐标**）。
  ///
  /// 必须单独存：用 _bandRect.topLeft 当起点会漂移 —— 那是矩形归一化后的
  /// 左上角，拖过起点之后就不是按下时的位置了（用户反馈「框选起始位置不对」）。
  Offset? _bandStart;

  /// 框选区域的参照物（用来把全局指针坐标转成局部坐标）。
  final GlobalKey _bandAreaKey = GlobalKey();

  /// 全局坐标 → 网格区局部坐标。
  ///
  /// 拿不到 RenderBox（未挂载）时原样返回：宁可偏移也不要崩。
  Offset _toBandLocal(Offset global) {
    final box = _bandAreaKey.currentContext?.findRenderObject();
    if (box is RenderBox && box.attached) return box.globalToLocal(global);
    return global;
  }

  /// 右键点击位置（菜单贴着它弹出）。
  Offset? _menuPos;

  static const _filters = <(String, String, List<String>)>[
    ('all', '全部', []),
    ('image', '图片', ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg']),
    ('video', '视频', ['mp4', 'mkv', 'mov', 'avi', 'webm']),
    ('audio', '音频', ['mp3', 'wav', 'flac', 'aac', 'm4a']),
    ('doc', '文档', [
      'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'md', 'csv',
    ]),
    ('archive', '压缩包', ['zip', 'rar', '7z', 'tar', 'gz']),
    ('apk', '安装包', ['apk']),
  ];

  static const _sortLabels = <FileSort, (String, IconData)>{
    FileSort.timeDesc: ('最新在前', Icons.schedule),
    FileSort.timeAsc: ('最早在前', Icons.history),
    FileSort.nameAsc: ('名称 A→Z', Icons.sort_by_alpha),
    FileSort.nameDesc: ('名称 Z→A', Icons.sort_by_alpha_outlined),
    FileSort.sizeDesc: ('从大到小', Icons.arrow_downward),
    FileSort.sizeAsc: ('从小到大', Icons.arrow_upward),
    FileSort.typeAsc: ('按类型分组', Icons.category_outlined),
  };

  /// 安卓返回：先取消选中，再交回 Shell（切回消息 TAB）。
  bool _onBack() {
    if (_selected.isEmpty) return false;
    tapFeedback();
    setState(() => _selected.clear());
    return true;
  }

  @override
  void initState() {
    super.initState();
    // 记住上次的视图与排序（跨重启保持）
    final ap = AppearanceState.instance;
    _gridView = ap.fileGridView;
    _sort = FileSort.values.firstWhere(
      (e) => e.name == ap.fileSort,
      orElse: () => FileSort.timeDesc,
    );
    _reload();
    AppState.instance.addListener(_scheduleReload);
    AppState.instance.backHandler = _onBack;
  }

  /// 落盘当前视图与排序。
  void _persistView() {
    AppearanceState.instance.setFileView(
      gridView: _gridView,
      sort: _sort.name,
    );
  }

  @override
  void dispose() {
    if (AppState.instance.backHandler == _onBack) {
      AppState.instance.backHandler = null;
    }
    AppState.instance.removeListener(_scheduleReload);
    _reloadScheduled = false;
    super.dispose();
  }

  /// AppState 通知入口：把同一次事件循环里的多次通知合并成一次真正的扫盘。
  void _scheduleReload() {
    if (!mounted || _reloadScheduled) return;
    _reloadScheduled = true;
    // 用 microtask 合并：一次事件循环里（甚至一帧里）连发的多条通知，
    // 只会在下一个 microtask  checkpoint 触发一次 `listSync` + 重建，
    // 而不是每条通知都全量扫盘，点选也就不会被高频通知拖慢。
    Future.microtask(() {
      _reloadScheduled = false;
      if (mounted) _reload();
    });
  }

  void _reload() {
    if (!mounted) return;
    var dir = AppearanceState.instance.receiveDir ?? '';
    // 自定义目录不可读时回落到默认收件目录：安卓的自定义接收目录是 SAF 的
    // `content://` URI（Dart 的 Directory 打不开），或目录已被删除 ——
    // 不回落的话整个「文件」TAB 一片空白，收到的文件也看不到。
    if (dir.isNotEmpty && !_dirExists(dir)) {
      dir = '';
    }
    if (dir.isEmpty) {
      try {
        dir = TransferService.instance.downloadDir();
      } catch (_) {
        // 桥接未就绪（演示模式/测试）：按空目录渲染
      }
    }
    final list = <FileEntry>[];
    if (dir.isNotEmpty) {
      try {
        for (final f in Directory(dir).listSync(recursive: true)) {
          if (f is! File) continue;
          // 磁盘元数据只在这里读一次，之后排序/过滤/渲染都用缓存值 ——
          // 否则 AppState 的高频通知会让每次点选都重读一遍全目录。
          var size = 0;
          var mtime = DateTime.fromMillisecondsSinceEpoch(0);
          try {
            final st = FilesPage.statProbe?.call(f) ?? f.statSync();
            size = st.size;
            mtime = st.modified;
          } catch (_) {
            // 不可读：按 0 大小 / 纪元时间参与排序，不中断扫盘
          }
          list.add(FileEntry(
            f,
            size,
            mtime,
            f.uri.pathSegments.last,
            fileExt(f.path),
          ));
        }
      } catch (_) {
        // 不可列出（安卓共享存储可能“存在但不可读”）→ 按空目录渲染，
        // 不让整个「文件」TAB 崩掉
      }
    }
    setState(() {
      _files = list;
      _loaded = true;
      _selected.removeWhere((p) => !list.any((e) => e.file.path == p));
    });
    _resolveApkIcons(list);
  }

  /// apk 图标解析结果缓存（路径 → 图标文件；value 为 null = 解析过但没有图标）。
  ///
  /// 每次重扫都会重建 [FileEntry]，缓存能避免对同一个 apk 反复发原生调用
  /// （AppState 的高频通知会不断触发重扫）。
  ///
  /// ponytail: null 也缓存 → 某个 apk 若在本次运行中后续才解析出图标，
  /// 要重启应用才会显示。代价可忽略（原生图标按包名落盘后是稳定的），
  /// 换来的是「每个 apk 最多一次原生调用」。真需要热更新时改成只缓存命中项。
  final Map<String, File?> _apkIcons = {};

  /// 只在扫盘后解析一次 apk 图标（原生缓存路径 + 存在性），结果写回 [FileEntry]。
  ///
  /// 旧实现把 `File(p).existsSync()` 放在瓦片 build 里 —— 每次选中/悬浮重建
  /// 都摸一次磁盘。现在 build 只读缓存字段。
  void _resolveApkIcons(List<FileEntry> list) {
    for (final e in list) {
      if (e.ext != 'apk' || e.apkIconResolved) continue;
      e.apkIconResolved = true;
      final path = e.file.path;
      if (_apkIcons.containsKey(path)) {
        e.apkIcon = _apkIcons[path]; // 已解析过：直接复用，不再发原生调用
        continue;
      }
      YuChuanPlatform.apkIconPath(path).then((p) {
        if (!mounted) return;
        // 路径为空或文件不存在 → 存 null，界面退回类型图标
        final f = (p.isEmpty || !File(p).existsSync()) ? null : File(p);
        _apkIcons[path] = f;
        if (f == null) return;
        setState(() => e.apkIcon = f);
      }).catchError((_) {});
    }
  }

  /// 目录是否**可读可列出**：`content://` 这类 URI 返回 false；
  /// 安卓共享存储里“存在但不可读”的真实路径也返回 false
  /// （只 existsSync 会误判 → 文件 TAB 列不到刚收到的文件）。
  bool _dirExists(String dir) {
    try {
      final d = Directory(dir);
      if (!d.existsSync()) return false;
      d.listSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  List<FileEntry> get _visible {
    final base = _filter == 'all'
        ? _files
        : _files.where((e) {
            final exts = _filters.firstWhere((f2) => f2.$1 == _filter).$3;
            return exts.contains(e.ext);
          }).toList();
    return _sortFiles(base);
  }

  /// 排序：纯内存比较，完全不碰磁盘（元数据已在 `_reload` 扫盘时缓存）。
  List<FileEntry> _sortFiles(List<FileEntry> input) {
    final list = [...input];
    switch (_sort) {
      case FileSort.timeDesc:
        list.sort((a, b) => b.mtime.compareTo(a.mtime));
      case FileSort.timeAsc:
        list.sort((a, b) => a.mtime.compareTo(b.mtime));
      case FileSort.nameAsc:
        list.sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      case FileSort.nameDesc:
        list.sort(
            (a, b) => b.name.toLowerCase().compareTo(a.name.toLowerCase()));
      case FileSort.sizeDesc:
        list.sort((a, b) => b.size.compareTo(a.size));
      case FileSort.sizeAsc:
        list.sort((a, b) => a.size.compareTo(b.size));
      case FileSort.typeAsc:
        list.sort((a, b) {
          final c = a.ext.compareTo(b.ext);
          return c != 0 ? c : b.mtime.compareTo(a.mtime);
        });
    }
    return list;
  }

  // ------------------------------------------------------------
  // 选择 / 批量操作
  // ------------------------------------------------------------

  /// 单击行为按平台区分（用户要求）：
  /// 手机 = 已在多选模式则追加点选（不再直接打开文件）；PC = 选中。
  /// 抖动处理：点按/切换都给一次触感反馈，避免误触。
  void _select(File file, int index, {bool shift = false, bool ctrl = false}) {
    tapFeedback();
    if (YuChuanPlatform.isAndroid) {
      // 已在多选模式：追加点选（用户要求：点一下就追加，不切换取消）
      if (_selected.isNotEmpty) {
        setState(() {
          if (!_selected.remove(file.path)) _selected.add(file.path);
        });
        return;
      }
      // 未多选：保持「单击直接打开」的原有习惯
      _openFile(file, context);
      return;
    }
    setState(() {
      if (ctrl) {
        if (!_selected.remove(file.path)) _selected.add(file.path);
        _lastTapIndex = index;
        return;
      }
      if (shift && _lastTapIndex >= 0) {
        // Shift 范围选（框选的等价实现）：从上次点击到这次之间全选
        final lo = _lastTapIndex < index ? _lastTapIndex : index;
        final hi = _lastTapIndex < index ? index : _lastTapIndex;
        final files = _visible;
        for (var i = lo; i <= hi && i < files.length; i++) {
          _selected.add(files[i].file.path);
        }
      } else {
        // PC 单击 = 只选中它（点别的会取消上一次的选中）
        _selected
          ..clear()
          ..add(file.path);
        _lastTapIndex = index;
      }
    });
  }

  List<File> get _selectedFiles => _visible
      .where((e) => _selected.contains(e.file.path))
      .map((e) => e.file)
      .toList();

  void _openSelected() {
    for (final f in _selectedFiles) {
      _openFile(f, context);
    }
  }

  Future<void> _deleteSelected() async {
    final files = _selectedFiles;
    if (files.isEmpty) return;
    // 确认框：默认只从列表移除；勾选「删除文件」才真的删磁盘文件
    var deleteFromDisk = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text('清空选中的 ${files.length} 个文件'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('默认只从收件列表里移除，磁盘上的文件保留。'),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('同时删除磁盘文件'),
                value: deleteFromDisk,
                onChanged: (v) {
                  setDialogState(() => deleteFromDisk = v ?? false);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    var removed = 0;
    for (final f in files) {
      if (deleteFromDisk) {
        try {
          f.deleteSync();
          removed++;
        } catch (_) {
          // 占用中/无权限：跳过
        }
      }
      _selected.remove(f.path);
    }
    if (deleteFromDisk) {
      _snack('已删除 $removed 个文件');
      _reload();
    } else {
      setState(() {});
      _snack('已从列表移除 ${files.length} 项（磁盘文件保留）');
    }
  }

  /// 所有通知统一走 OSD（横幅已按用户要求删除：「已发送」等通知也走 OSD）。
  void _snack(String text) {
    if (!mounted) return;
    OsdToast.info(context, text);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final files = _visible;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _selected.isEmpty
                          ? '文件 · ${files.length}'
                          : '已选 ${_selected.length}',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  PopupMenuButton<FileSort>(
                    tooltip: '排序方式',
                    icon: const Icon(Icons.sort, size: 20),
                    onSelected: (v) => setState(() {
                      _sort = v;
                      _persistView();
                    }),
                    itemBuilder: (_) => [
                      for (final e in _sortLabels.entries)
                        PopupMenuItem<FileSort>(
                          value: e.key,
                          height: 42,
                          child: Row(
                            children: [
                              Icon(e.value.$2, size: 18),
                              const SizedBox(width: 10),
                              Text(e.value.$1),
                              if (e.key == _sort) ...[
                                const SizedBox(width: 8),
                                Icon(Icons.check, size: 16, color: scheme.primary),
                              ],
                            ],
                          ),
                        ),
                    ],
                  ),
                  IconButton(
                    tooltip: _gridView ? '切换列表视图' : '切换网格视图',
                    icon: Icon(
                      _gridView ? Icons.view_list : Icons.grid_view,
                      size: 20,
                    ),
                    onPressed: () => setState(() {
                      _gridView = !_gridView;
                      _persistView();
                    }),
                  ),
                  IconButton(
                    tooltip: '刷新',
                    icon: const Icon(Icons.refresh, size: 20),
                    onPressed: _reload,
                  ),
                  IconButton(
                    tooltip: '清空',
                    icon: const Icon(Icons.delete_sweep_outlined, size: 20),
                    onPressed: files.isEmpty
                        ? null
                        : () {
                            setState(() => _selected
                                .addAll(files.map((e) => e.file.path)));
                            _deleteSelected();
                          },
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '单击选中 · 双击打开 · 长按（右键）更多操作 · Shift 点按可范围选',
                style: TextStyle(fontSize: 11, color: scheme.outline),
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final (id, label, _) in _filters)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(label),
                          selected: _filter == id,
                          onSelected: (_) => setState(() => _filter = id),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: !_loaded
              ? const Center(child: CircularProgressIndicator())
              : files.isEmpty
                  ? _empty(scheme)
                  : _gridView
                      ? _buildGrid(files, scheme)
                      : _buildList(files, scheme),
        ),
        // 手机端才需要底部选中操作栏；PC 用右键/工具栏，不占一屏
        if (_selected.isNotEmpty && YuChuanPlatform.isAndroid)
          _buildSelectionBar(scheme),
      ],
    );
  }

  /// 底部批量操作条。
  Widget _buildSelectionBar(ColorScheme scheme) {
    return Material(
      color: scheme.primaryContainer.withValues(alpha: 0.6),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
          child: Row(
            children: [
              Text(
                '已选 ${_selected.length} 项',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.open_in_new, size: 17),
                label: const Text('打开'),
                onPressed: _openSelected,
              ),
              TextButton.icon(
                icon: const Icon(Icons.folder_open_outlined, size: 17),
                label: const Text('定位'),
                onPressed: () async {
                  // 「定位」= 在文件管理器中找到它，与「打开」是两回事
                  // （旧实现两者都走 openFile —— 那时 openFile 本身就是定位）
                  final f = _selectedFiles.firstOrNull;
                  if (f == null) return;
                  _snack(await AppState.instance.revealFolder(f.path));
                },
              ),
              TextButton.icon(
                icon: const Icon(Icons.delete_outline, size: 17),
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
      ),
    );
  }

  Widget _empty(ColorScheme scheme) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open_outlined, size: 40, color: scheme.outline),
            const SizedBox(height: 10),
            Text(
              _filter == 'all' ? '还没有接收过文件' : '没有此类型的文件',
              style: TextStyle(fontSize: 13, color: scheme.outline),
            ),
            const SizedBox(height: 6),
            Text(
              '接收的文件会出现在这里',
              style: TextStyle(
                  fontSize: 11.5, color: scheme.outline.withValues(alpha: 0.7)),
            ),
          ],
        ),
      );

  Widget _buildGrid(List<FileEntry> files, ColorScheme scheme) {
    // 桌面：在空白处按住拖动 = 框选（被框到的进入选中状态）
    final rub = !YuChuanPlatform.isAndroid;
    return Stack(
      key: _bandAreaKey,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onPanStart: rub
              ? (d) => setState(() {
                  // 统一转成**网格区局部坐标**：选框就画在这个 Stack 里，
                  // 用全局坐标会随页面偏移（用户反馈「起始位置要和鼠标对齐」）。
                  final at = _toBandLocal(d.globalPosition);
                  _bandStart = at;
                  _bandRect = Rect.fromPoints(at, at);
                })
              : null,
          onPanUpdate: rub
              ? (d) {
                  final start = _bandStart ?? _toBandLocal(d.globalPosition);
                  setState(() => _bandRect =
                      Rect.fromPoints(start, _toBandLocal(d.globalPosition)));
                }
              : null,
          onPanEnd: rub ? (_) => _commitBand() : null,
          // 手机端：长按空白处出框，在触控位置起框（用户要求）
          onLongPressStart: YuChuanPlatform.isAndroid
              ? (d) => setState(() {
                  tapFeedback();
                  final at = _toBandLocal(d.globalPosition);
                  _bandStart = at;
                  _bandRect = Rect.fromPoints(at, at);
                })
              : null,
          onLongPressMoveUpdate: YuChuanPlatform.isAndroid
              ? (d) {
                  final start = _bandStart ?? _toBandLocal(d.globalPosition);
                  setState(() => _bandRect =
                      Rect.fromPoints(start, _toBandLocal(d.globalPosition)));
                }
              : null,
          onLongPressEnd: YuChuanPlatform.isAndroid
              ? (_) => _commitBand()
              : null,
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 132,
              mainAxisExtent: 136,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: files.length,
            itemBuilder: (context, i) {
              final e = files[i];
              return _FileTile(
                key: _tileKeys.putIfAbsent(e.file.path, () => GlobalKey()),
                entry: e,
                scheme: scheme,
                selected: _selected.contains(e.file.path),
                onSelect: (shift, ctrl) =>
                    _select(e.file, i, shift: shift, ctrl: ctrl),
                onMenu: () => _showFileMenu(context, e.file, _menuPos),
                onMenuPos: (p) => _menuPos = p,
              );
            },
          ),
        ),
        if (_bandRect != null)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _BandPainter(_bandRect!)),
            ),
          ),
      ],
    );
  }

  /// 框选结束：把与选框相交的瓦片都选上。
  void _commitBand() {
    final band = _bandRect;
    setState(() {
      _bandRect = null;
      _bandStart = null;
    });
    if (band == null) return;
    if (band.width < 6 && band.height < 6) return; // 只是点了一下空白
    tapFeedback();
    setState(() {
      for (final e in _tileKeys.entries) {
        final box = e.value.currentContext?.findRenderObject();
        if (box is! RenderBox || !box.attached) continue;
        // 瓦片矩形也要换算到同一个局部坐标系，否则「画出来的框」和
        // 「判定用的框」不在一个空间里，选中范围会随页面偏移而错位。
        final rect = box.localToGlobal(Offset.zero) & box.size;
        final localRect = Rect.fromPoints(
          _toBandLocal(rect.topLeft),
          _toBandLocal(rect.bottomRight),
        );
        if (band.overlaps(localRect)) _selected.add(e.key);
      }
    });
  }

  Widget _buildList(List<FileEntry> files, ColorScheme scheme) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: files.length,
      separatorBuilder: (_, __) => const SizedBox(height: 2),
      itemBuilder: (context, i) {
        final e = files[i];
        return _FileRow(
          entry: e,
          scheme: scheme,
          selected: _selected.contains(e.file.path),
          onSelect: (shift, ctrl) =>
              _select(e.file, i, shift: shift, ctrl: ctrl),
          onMenu: () => _showFileMenu(context, e.file, _menuPos),
          onMenuPos: (p) => _menuPos = p,
        );
      },
    );
  }

  /// 文件操作菜单：打开 / 定位 / 复制路径 / 加入选择 / 删除。
  Future<void> _showFileMenu(BuildContext context, File file,
      [Offset? anchor]) async {
    final actions = <IconMenuAction>[
      // ── 第 1 组：打开类（主操作，主题强调色）──────────────────────
      // 打开：直接用**系统默认应用**（用户要求：双击与菜单项都如此）
      IconMenuAction(
        id: 'open',
        label: '打开',
        icon: Icons.open_in_new,
        tone: MenuTone.primary,
        run: () => _openFile(file, context),
      ),
      // 打开方式：安卓弹**自建**窗口（仅一次/始终，始终有记忆）；PC 弹系统程序列表
      IconMenuAction(
        id: 'openWithChooser',
        label: '打开方式…',
        icon: Icons.apps_outlined,
        tone: MenuTone.primary,
        run: () => _openWithChooser(file),
      ),
      // 发送：作用于**所有选中**的文件（多选时发一批，不是只发这一个）
      IconMenuAction(
        id: 'send',
        label: _selected.length > 1
            ? '发送选中的 ${_selected.length} 个文件'
            : '发送',
        icon: Icons.send,
        tone: MenuTone.primary,
        run: () => _sendToContact(_sendTargets(file)),
      ),

      // ── 第 2 组：定位/复制（普通项）──────────────────────────────
      IconMenuAction(
        id: 'folder',
        label: '打开所在文件夹',
        icon: Icons.folder_open_outlined,
        run: () async {
          final msg = await AppState.instance.revealFolder(file.path);
          _snack(msg);
        },
      ),
      IconMenuAction(
        id: 'copy',
        label: '复制文件路径',
        icon: Icons.copy_outlined,
        tone: MenuTone.muted,
        run: () async {
          await Clipboard.setData(ClipboardData(text: file.path));
          _snack('已复制文件路径');
        },
      ),

      // ── 第 3 组：选择（次要工具，退到次级色）──────────────────────
      // 选中：进/出多选（用户要求加回来）
      IconMenuAction(
        id: 'select',
        label: _selected.contains(file.path) ? '取消选中' : '选择',
        icon: Icons.checklist,
        tone: MenuTone.muted,
        run: () async {
          tapFeedback();
          setState(() {
            if (!_selected.remove(file.path)) _selected.add(file.path);
          });
        },
      ),
      IconMenuAction(
        id: 'selectAll',
        label: '全选',
        icon: Icons.select_all,
        tone: MenuTone.muted,
        run: () async {
          tapFeedback();
          setState(() =>
              _selected.addAll(_visible.map((e) => e.file.path)));
        },
      ),

      // ── 第 4 组：危险操作（错误色）──────────────────────────────
      IconMenuAction(
        id: 'delete',
        label: '删除…',
        icon: Icons.delete_outline,
        tone: MenuTone.danger,
        run: () async {
          setState(() => _selected.add(file.path));
          await _deleteSelected();
        },
      ),
    ];
    if (!mounted) return;
    final picked = await showIconMenu(context,
        actions: actions, header: file.uri.pathSegments.last, anchor: anchor);
    await runIconMenuAction(picked, actions);
  }

  /// 本次「发送」的目标：多选时发全部选中，否则只发右键的那个。
  List<File> _sendTargets(File file) {
    if (_selected.length > 1 && _selected.contains(file.path)) {
      return _selectedFiles;
    }
    return [file];
  }

  /// 发送给某个联系人（文件 TAB 的「发送」；支持一次发多个）。
  Future<void> _sendToContact(List<File> files) async {
    if (files.isEmpty) return;
    final state = AppState.instance;
    final contacts = state.conversations.map((c) => c.device).toList();
    if (contacts.isEmpty) {
      _snack('还没有可发送的联系人，先去配对');
      return;
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
                child: Text('发送到',
                    style: TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w700)),
              ),
            ),
            for (final d in contacts)
              ListTile(
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
    if (id == null) return;
    // 逐个发：每个文件单独走一次传输（同 peer 由 Rust 侧排队串行）
    for (final f in files) {
      final lower = f.path.toLowerCase();
      final kind = const ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp']
              .any(lower.endsWith)
          ? MessageKind.image
          : MessageKind.file;
      await AppState.instance.sendFilePath(f.path, kind: kind, peerId: id);
    }
    final who = contacts.firstWhere((d) => d.id == id).displayName;
    _snack(files.length > 1
        ? '已发送 ${files.length} 个文件给 $who'
        : '已发送给 $who');
  }

  /// 「打开方式…」：安卓走**自建**选择窗口（列应用 + 仅一次/始终 + 记忆），
  /// PC 走系统「打开方式」程序列表（rundll32 OpenAs_RunDLL）。
  ///
  /// 不再依赖安卓系统 ResolverActivity 的「仅一次 / 始终」——Android 11+
  /// 对隐式 ACTION_VIEW 不再提供那组按钮（用户反馈「一直不对」）。
  Future<void> _openWithChooser(File file) async {
    if (YuChuanPlatform.isAndroid) {
      await showOpenWithChooser(context, file.path);
      return;
    }
    final err = await YuChuanPlatform.openWithDialog(file.path);
    if (!mounted) return;
    if (err != null) _snack('打开失败：$err');
  }

  /// 「打开」：直接用系统默认应用；但若用户对这类文件选过「始终」，
  /// 就用记住的那个应用（用户要求：下次触发打开文件直接使用记忆的应用）。
  Future<void> _openFile(File file, BuildContext context) async {
    if (YuChuanPlatform.isAndroid) {
      await openFileRespectingMemory(context, file.path);
      return;
    }
    final err = await YuChuanPlatform.openFile(file.path);
    if (!context.mounted) return;
    if (err != null) {
      OsdToast.error(context, '打开失败：$err');
    }
  }
}

/// apk 用 PackageManager 解析出的真实图标；非 apk 或解析失败退回类型图标。
///
/// 图标路径与存在性已在扫盘后解析并缓存在 [FileEntry.apkIcon] ——
/// 这里只读缓存，build 不碰磁盘（旧实现在 build 里 `existsSync`）。
/// 图标按路径缓存在原生侧（cacheDir/apkicons/包名.png），Dart 这层用
/// [FileImage] 的内存缓存避免重复解码。
Widget _apkIconOrBox(File? cachedIcon, Color color, IconData icon) {
  if (cachedIcon == null) return _tileIconBox(color, icon);
  return Image.file(
    cachedIcon,
    width: 52,
    height: 52,
    fit: BoxFit.cover,
    cacheWidth: 104,
    errorBuilder: (_, __, ___) => _tileIconBox(color, icon),
  );
}
/// 文件类型图标 + 颜色。
(IconData, Color) _fileMeta(String path) {
  switch (fileExt(path)) {
    case 'png':
    case 'jpg':
    case 'jpeg':
    case 'gif':
    case 'webp':
    case 'bmp':
      return (Icons.image_outlined, const Color(0xFF8B5CF6));
    case 'mp4':
    case 'mkv':
    case 'mov':
    case 'avi':
    case 'webm':
      return (Icons.video_file_outlined, const Color(0xFFEF4444));
    case 'mp3':
    case 'wav':
    case 'flac':
    case 'aac':
    case 'm4a':
      return (Icons.audio_file_outlined, const Color(0xFFF59E0B));
    case 'pdf':
      return (Icons.picture_as_pdf_outlined, const Color(0xFFDC2626));
    case 'doc':
    case 'docx':
      return (Icons.description_outlined, const Color(0xFF2563EB));
    case 'xls':
    case 'xlsx':
    case 'csv':
      return (Icons.table_chart_outlined, const Color(0xFF16A34A));
    case 'zip':
    case 'rar':
    case '7z':
    case 'tar':
    case 'gz':
      return (Icons.folder_zip_outlined, const Color(0xFF64748B));
    case 'apk':
      return (Icons.android, const Color(0xFF14B8A6));
    default:
      return (Icons.insert_drive_file_outlined, const Color(0xFF94A3B8));
  }
}


String _fmtSize(int bytes) => formatBytes(bytes);

/// 扫盘时读不到元数据的文件按「纪元时间 + 0 字节」参与排序（不中断扫盘），
/// 但界面上不该显示 1970 年的日期 —— 这类文件只显示大小。
bool _hasMtime(DateTime t) => t.millisecondsSinceEpoch != 0;

/// 图标底：类型色方块（apk 用安卓绿 + 安装包图标）。
Widget _tileIconBox(Color color, IconData icon) => Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(14),
      ),
      alignment: Alignment.center,
      child: Icon(icon, color: color, size: 30),
    );

/// 网格瓦片：图标在上、名称在下（居中，尺寸统一）。
class _FileTile extends StatelessWidget {
  const _FileTile({
    super.key,
    required this.entry,
    required this.scheme,
    required this.selected,
    required this.onSelect,
    required this.onMenu,
    this.onMenuPos,
  });

  final FileEntry entry;
  final ColorScheme scheme;
  final bool selected;
  final void Function(bool shift, bool ctrl) onSelect;
  final VoidCallback onMenu;
  final ValueChanged<Offset>? onMenuPos;

  /// 本瓦片的屏幕中心，用作菜单锚点（安卓长按没有右键坐标可用）。
  Offset _selfCenter(BuildContext tileContext) {
    final box = tileContext.findRenderObject();
    if (box is RenderBox && box.attached) {
      return box.localToGlobal(box.size.center(Offset.zero));
    }
    return Offset.zero;
  }

  @override
  Widget build(BuildContext context) {
    // 元数据全部来自扫盘缓存，这里绝不碰磁盘（选中要跟手）
    final name = entry.name;
    final (icon, color) = _fileMeta(entry.file.path);
    bool hovered = false; // 仅 PC 悬浮用（StatefulBuilder 局部状态）
    // 图片直接给缩略图；apk 用安装包图标；其余用类型图标
    final ext = entry.ext;
    final isImage = const [
      'png',
      'jpg',
      'jpeg',
      'gif',
      'webp',
      'bmp',
    ].contains(ext);
    final size = entry.size;
    final mtime = entry.mtime;

    // PC 悬浮反馈：只在桌面端启用（移动端没有 hover，套上去反而多一层状态）
    final hoverable = !YuChuanPlatform.isAndroid;
    // 「选中要跟手」的根因：同节点上注册了 onDoubleTap 时，Flutter 的 tap
    // 识别器必须等双击窗口（约 300ms）才能判定单击 —— 实测「50ms 未选中、
    // 450ms 才选中」。两端各自绕开：
    //  - 桌面：选中走裸指针 onPointerDown（不参与手势竞技场，按下即选中）。
    //    注意**不能**顺带在安卓也这么做：安卓单击语义是「打开文件」，
    //    长按也会先触发 pointerDown → 会误开文件（实测踩过）。
    //  - 安卓：触屏没有双击概念，直接不注册 onDoubleTap，单击即生效。
    final usePointerSelect = !YuChuanPlatform.isAndroid;
    final tile = StatefulBuilder(
      builder: (context, setTileState) => MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: hoverable
            ? (_) => setTileState(() => hovered = true)
            : null,
        onExit: hoverable
            ? (_) => setTileState(() => hovered = false)
            : null,
        child: GestureDetector(
          // 桌面：选中由外层 Listener.onPointerDown 处理（按下即选中），
          //       这里只留双击打开与长按/右键菜单。
          // 安卓：单击语义是「选中/打开文件」，触屏没有双击概念 → 不注册
          //       onDoubleTap，单击即时生效（注册了就要等约 300ms 双击窗口）。
          onTap: usePointerSelect
              ? null
              : () => onSelect(
                  HardwareKeyboard.instance.isShiftPressed,
                  HardwareKeyboard.instance.isControlPressed ||
                      HardwareKeyboard.instance.isMetaPressed),
          onDoubleTap: usePointerSelect
              ? () {
                  tapFeedback();
                  _openStandalone(entry.file, context);
                }
              : null,
          // 长按（安卓触摸）也要给出锚点：触屏没有右键，onSecondaryTapDown
          // 永远不触发 → _menuPos 恒为 null → 菜单退回到「卡片中心」弹出，
          // 看起来就是从顶部冒出来（用户反馈两次的根因）。
          onLongPress: () {
            onMenuPos?.call(_selfCenter(context));
            onMenu();
          },
          onSecondaryTapDown:
              onMenuPos == null ? null : (d) => onMenuPos!(d.globalPosition),
          onSecondaryTap: onMenu,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 10),
        decoration: BoxDecoration(
          // 选中态加深（用户要求「全端选中颜色再深点」）；PC 悬浮给一层轻抬升
          color: selected
              ? scheme.primary.withValues(alpha: 0.28)
              : hovered
                  ? scheme.surfaceContainerHighest.withValues(alpha: 0.75)
                  : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? scheme.primary.withValues(alpha: 0.5)
                : Colors.transparent,
            width: 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: isImage
                      ? Image.file(
                          entry.file,
                          width: 52,
                          height: 52,
                          fit: BoxFit.cover,
                          cacheWidth: 104,
                          errorBuilder: (_, __, ___) =>
                              _tileIconBox(color, icon),
                        )
                      : _apkIconOrBox(entry.apkIcon, color, icon),
                ),

              ],
            ),
            const SizedBox(height: 10),
            Text(
              name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, height: 1.25),
            ),
            const Spacer(),
            Text(
              _hasMtime(mtime)
                  ? '${_fmtSize(size)} · ${mtime.month}/${mtime.day}'
                  : _fmtSize(size),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, color: scheme.outline),
            ),
          ],
        ), // Column
      ), // Container
    ), // GestureDetector
      ), // MouseRegion
    ); // StatefulBuilder
    // 桌面：裸指针按下即选中（不参与手势竞技场，故不受双击窗口影响）。
    // 安卓不套这层 —— 那边单击就是「打开文件」，pointerDown 会在长按前
    // 先触发，导致长按误开文件（实测被测试抓到过）。
    return usePointerSelect
        ? Listener(
            onPointerDown: (e) {
              // 右键(2)/中键(4) 留给菜单
              if (e.buttons == 2 || e.buttons == 4) return;
              onSelect(
                  HardwareKeyboard.instance.isShiftPressed,
                  HardwareKeyboard.instance.isControlPressed ||
                      HardwareKeyboard.instance.isMetaPressed);
            },
            child: tile,
          )
        : tile;
  }
}

/// 列表行：图标 + 名称 + 大小/时间。
class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.entry,
    required this.scheme,
    required this.selected,
    required this.onSelect,
    required this.onMenu,
    this.onMenuPos,
  });

  final FileEntry entry;
  final ColorScheme scheme;
  final bool selected;
  final void Function(bool shift, bool ctrl) onSelect;
  final VoidCallback onMenu;
  final ValueChanged<Offset>? onMenuPos;

  /// 本行的屏幕中心，用作菜单锚点（安卓长按没有右键坐标可用）。
  Offset _selfCenter(BuildContext rowContext) {
    final box = rowContext.findRenderObject();
    if (box is RenderBox && box.attached) {
      return box.localToGlobal(box.size.center(Offset.zero));
    }
    return Offset.zero;
  }

  @override
  Widget build(BuildContext context) {
    // 同 _FileTile：全部用扫盘缓存，build 不碰磁盘
    final name = entry.name;
    final (icon, color) = _fileMeta(entry.file.path);
    final size = entry.size;
    final mtime = entry.mtime;

    final usePointerSelect = !YuChuanPlatform.isAndroid;
    final row = InkWell(
      borderRadius: BorderRadius.circular(10),
      // 同 _FileTile：桌面选中由外层 Listener 处理，只留双击打开；
      // 安卓不注册 onDoubleTap，单击即时生效（见 _FileTile 注释）。
      onTap: usePointerSelect
          ? null
          : () => onSelect(
              HardwareKeyboard.instance.isShiftPressed,
              HardwareKeyboard.instance.isControlPressed ||
                  HardwareKeyboard.instance.isMetaPressed),
      onDoubleTap: usePointerSelect
          ? () {
              tapFeedback();
              _openStandalone(entry.file, context);
            }
          : null,
      // 见 _FileTile.onLongPress：安卓长按必须自己给锚点，否则菜单从卡片中心冒出来
      onLongPress: () {
        onMenuPos?.call(_selfCenter(context));
        onMenu();
      },
      onSecondaryTapDown: onMenuPos == null ? null : (d) => onMenuPos!(d.globalPosition),
      onSecondaryTap: onMenu,
      child: Container(
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.24)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13.5)),
                  Text(
                    _hasMtime(mtime)
                        ? '${_fmtSize(size)} · ${mtime.year}-${mtime.month.toString().padLeft(2, '0')}-${mtime.day.toString().padLeft(2, '0')}'
                        : _fmtSize(size),
                    style: TextStyle(fontSize: 11.5, color: scheme.outline),
                  ),
                ],
              ),
            ),

          ],
        ),
      ),
    ); // InkWell
    // 桌面：裸指针按下即选中（与 _FileTile 同理，绕开双击窗口延迟）
    return usePointerSelect
        ? Listener(
            onPointerDown: (e) {
              if (e.buttons == 2 || e.buttons == 4) return;
              onSelect(
                  HardwareKeyboard.instance.isShiftPressed,
                  HardwareKeyboard.instance.isControlPressed ||
                      HardwareKeyboard.instance.isMetaPressed);
            },
            child: row,
          )
        : row;
  }
}


/// 框选选框（半透明填充 + 描边）。
class _BandPainter extends CustomPainter {
  _BandPainter(this.rect);

  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()
      ..color = const Color(0xFF6366F1).withValues(alpha: 0.12)
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = const Color(0xFF6366F1).withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(6));
    canvas.drawRRect(rrect, fill);
    canvas.drawRRect(rrect, stroke);
  }

  @override
  bool shouldRepaint(covariant _BandPainter old) => old.rect != rect;
}

/// 打开文件：安卓调系统默认应用（apk 直接进安装器），桌面交给文件关联
/// 用系统默认应用打开（不再是打开所在目录）。
/// 没有默认程序时回落到「打开所在文件夹」并提示，不静默。
Future<void> _openStandalone(File file, BuildContext context) async {
  final err = await YuChuanPlatform.openFile(file.path);
  if (err == null) return;
  // 没有默认程序时回落到「打开所在文件夹」（提示语由 revealFolder 给）
  final msg = await AppState.instance.revealFolder(file.path);
  if (!context.mounted) return;
  // 横幅已删除：通知统一走 OSD
  OsdToast.info(context, msg);
}


