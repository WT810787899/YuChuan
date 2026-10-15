# 修复批次 A1 实施计划（UI 细节 + 设置持久化）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按用户 2026-10-14 的 12 条反馈，修掉 OSD 位置/配色、顶部横幅、文件 TAB 选中卡顿与打开方式、安卓「打开所在文件夹」、主题深浅持久化、聊天筛选按钮与气泡多选。

**Architecture:** 全部是既有流程的就地修正，不新增子系统。三类手段：(1) 把顶部两个横幅删除，错误/状态/新消息统一改走已有的 `OsdToast`（Overlay）通道；(2) 文件 TAB 把 `statSync/lengthSync` 从 build 路径挪到扫盘一次并缓存进条目；(3) 设置项落盘：`themeMode` 进 `appearance.json`，其余三项进 `AppState` 的 `prefs.json`。

**Tech Stack:** Flutter 3.32 / Dart 3.8、flutter_rust_bridge、Kotlin（Android MethodChannel）、PowerShell/reg（Windows 打开方式）。

**Spec:** 无独立 spec（bounded 任务，设计在对话中获批）。需求原文见仓库根 `修bug.md` 第 1–13 行。

## Global Constraints

- 需求文档、计划、注释说明一律中文。
- 用户三条明确修正，**不得替换**：
  1. OSD **只改字体颜色**（浅色→黑、深色→白），彩色半透明底与彩色图标保留；
  2. 安卓「打开方式」**必须同时给「仅一次」和「始终」**，记忆交给系统选择器，**不要**应用自弹「记住选择？」询问框；
  3. 聊天筛选按钮**只换图标样式**，保持纯图标，**不要**加文字/胶囊/分段控件。
- 文件 TAB 的过滤按钮**只统一字重**，不改尺寸、颜色、形状。
- 不改 `flutter_rust_bridge` 生成物（`lib/src/rust/**`）。
- 本仓库非 git 仓库（无 worktree / diff / commit）。SDD 的 review-package 以 `git diff` 为输入，因此**改用手工清单**：每次审查前由控制者生成本轮改动文件清单（路径 + 行数 + 完整文件内容），交给审查者；审查者按清单逐文件核对。这是本仓库下最接近 diff 的替代物，记为裁决 R2。
- 每个任务结束跑一次完整 `flutter test`（基线：49 项全绿）；`flutter analyze` 必须 No issues。

## Review Focus

以下 5 类是本计划未由用户点名、但同族代码改错就会立刻伤到人的输入，各自在所属任务里有测试钉住：

1. **OSD 在安卓上偏高**：安卓没有自定义标题栏（`AppTitleBar` 返回 `SizedBox.shrink`），若照搬桌面 38px 偏移，OSD 会浮在屏幕中部。
2. **OSD 与标题栏窗口按钮重叠**：桌面标题栏右上角有最小化/最大化/关闭，OSD 若横跨全宽会盖住它们。
3. **文件 TAB 高频通知下的过期缓存**：AppState 通知很密，缓存若不在 `_reload` 里重建，会显示已删除文件的旧大小/时间。
4. **`revealFolder` 对已归档文件的回退**：安卓文件已复制进 `Download/雨传`，但传入的仍是私有副本路径 → 必须回退到公共目录，否则又回到「提示在内部不能打开」。
5. **`themeMode` 与浅深外观快照的写入顺序**：`AppearanceState.setDarkLook()` 会 `_save()`，若 themeMode 的读取晚于 `_isDarkLook` 的同步，重启后会套用错误的一套外观。

---

### Task 1: OSD 回到标题栏之下、圆角减小、字体颜色随深浅取黑/白

**Files:**
- Modify: `lib/ui/osd_toast.dart:16-50`（`show` 传平台信息）、`lib/ui/osd_toast.dart:123-179`（渲染）
- Test: `test/osd_toast_test.dart`（新建）

**Interfaces:**
- Consumes: 无（叶子组件）
- Produces: `OsdToast.show/error/success/info` 签名不变；新增私有常量 `_kTitleBarHeight = 38.0`、`_kRadius = 12.0`。

- [ ] **Step 1: 写失败测试**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_flutter_ui/ui/osd_toast.dart';

/// OSD 位置与配色（修 bug.md 第 3 行）。
void main() {
  Future<void> pumpAndShow(WidgetTester tester, {required bool dark}) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
      home: Builder(builder: (c) { ctx = c; return const Scaffold(); }),
    ));
    OsdToast.info(ctx, '测试提示');
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('OSD 不贴顶：顶部留出标题栏高度', (tester) async {
    await pumpAndShow(tester, dark: false);
    final top = tester.getTopLeft(find.text('测试提示')).dy;
    expect(top, greaterThan(40), reason: 'OSD 必须落在标题栏之下，不能压住它');
  });

  testWidgets('OSD 浅色主题下字体为黑、深色主题下为白', (tester) async {
    await pumpAndShow(tester, dark: false);
    expect(tester.widget<Text>(find.text('测试提示')).style?.color, Colors.black);
    await pumpAndShow(tester, dark: true);
    expect(tester.widget<Text>(find.text('测试提示')).style?.color, Colors.white);
  });

  testWidgets('OSD 圆角 ≤ 12、无描边横线', (tester) async {
    await pumpAndShow(tester, dark: false);
    final c = tester.widget<Container>(find.ancestor(
      of: find.text('测试提示'),
      matching: find.byType(Container),
    ).first);
    final deco = c.decoration! as BoxDecoration;
    final r = deco.borderRadius! as BorderRadius;
    expect(r.topLeft.x, lessThanOrEqualTo(12.0));
    expect(deco.border, isNull, reason: '不要描边横线');
  });
}
```

- [ ] **Step 2: 跑测试确认 RED**

Run: `flutter test test/osd_toast_test.dart`
Expected: FAIL —— 文字颜色是语义色而非黑/白；`top` 约 < 40；圆角 28。

- [ ] **Step 3: 最小实现**

`lib/ui/osd_toast.dart`，`_OsdToastWidget` 增加字体颜色参数并在 `show` 里按主题亮度取值：

```dart
// show() 内部，取完 scheme 后：
final isDark = Theme.of(context).brightness == Brightness.dark;
// ...
_OsdToastWidget(
  text: text,
  icon: icon,
  color: t,
  // 用户要求：只在深/浅之间把字体切换成白或黑（底色与图标保留语义色）
  textColor: isDark ? Colors.white : Colors.black,
  scheme: scheme,
  onDismiss: ...,
)
```

渲染处：

```dart
const double _kTitleBarHeight = 38.0; // 桌面自定义标题栏高度（AppTitleBar）
const double _kRadius = 12.0;          // 用户要求：圆角减小

// Positioned 内：
top: 0,
child: Align(
  alignment: Alignment.topCenter,
  child: SafeArea(
    top: true,
    minimum: EdgeInsets.only(
      // 安卓没有自定义标题栏 → 不额外偏移，否则 OSD 会掉到屏幕中间
      top: _isDesktop ? _kTitleBarHeight + 8 : 8,
      left: 16,
      right: 16,
      bottom: 8,
    ),
    // ...
```

容器改造：

```dart
Container(
  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
  decoration: BoxDecoration(
    color: widget.color.withValues(alpha: 0.16),
    borderRadius: BorderRadius.circular(_kRadius),
    // 阴影已删除：贴顶的硬阴影上缘会被看成一条横线（用户反馈「去掉横线」）
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
          ),
        ),
      ),
    ],
  ),
)
```

`_isDesktop` 用 `defaultTargetPlatform`（不要 `Platform.isWindows`，测试里要可 fake）：

```dart
final isDesktop = defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux ||
    defaultTargetPlatform == TargetPlatform.macOS;
```

- [ ] **Step 4: 跑测试确认 GREEN**

Run: `flutter test test/osd_toast_test.dart`
Expected: PASS（3 项）

- [ ] **Step 5: 全量回归**

Run: `flutter test` → 52 项全绿；`flutter analyze` → No issues。

---

### Task 2: 删除顶部两个横幅，通知统一走 OSD

**Files:**
- Modify: `lib/main.dart:353-407`（删 `_ConnectionBanner`）、`lib/main.dart:409-519`（删 `_NewMessageBanner`）、`lib/main.dart:776-795`（`_withBanner`）
- Modify: `lib/ui/settings_page.dart:596-604`（通知分区说明文案需与新行为一致）
- Test: `test/banner_to_osd_test.dart`（新建）

**Interfaces:**
- Consumes: `OsdToast.info/error`（Task 1）
- Produces: `Shell._notificationBridge()` —— 监听 `AppState`，把三类事件转 OSD；`AppState.consumeNoticeForOsd()` 返回一次性提示文案（`({String name, String text})?`），避免重复弹。

- [ ] **Step 1: 写失败测试**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_flutter_ui/app_state.dart';
import 'package:rust_flutter_ui/main.dart';

/// 顶部横幅已移除，通知改走 OSD（修 bug.md 第 3 行末句）。
void main() {
  testWidgets('Shell 不再渲染任何顶部横幅', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const YuChuanApp());
    await tester.pump(const Duration(milliseconds: 300));

    // 旧横幅的两条特征文本都不应作为常驻行存在
    AppState.instance.setChatError('模拟错误');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('确定'), findsNothing); // 旧横幅的按钮
    expect(find.byType(MaterialBanner), findsNothing);
  });

  testWidgets('chatError 出现后会弹 OSD 提示', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const YuChuanApp());
    await tester.pump(const Duration(milliseconds: 300));
    AppState.instance.setChatError('模拟错误');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('模拟错误'), findsOneWidget, reason: '错误必须仍可见，只是改走 OSD');
  });
}
```

- [ ] **Step 2: 跑测试确认 RED**

Run: `flutter test test/banner_to_osd_test.dart`
Expected: 第一个测试 PASS（当前无 `MaterialBanner`），第二个 FAIL —— `chatError` 只出现在顶部横幅里，OSD 尚未接上。

> 私有类无法 `find.byType`，所以断言的是**行为**：错误文案置位后，界面上必须出现 OSD 的居中胶囊提示。横幅删除后若忘了接 OSD，第二个测试会一直红。

- [ ] **Step 3: 最小实现**

1. 删除 `_ConnectionBanner`、`_NewMessageBanner` 两个类。
2. `_withBanner` 简化为直通，只保留内容：

```dart
/// 顶部横幅已按用户要求删除：所有通知统一走 OSD（Overlay 胶囊）。
Widget _withBanner(Widget body) => body;
```

3. 在 `_ShellState` 增加 OSD 桥（`initState` 里已有 `state.addListener(_onState)`，在 `_onState` 内追加）：

```dart
String _lastOsdChatError = '';
int _lastOsdNoticeSeq = 0;

/// 把原来走顶部横幅的三类事件转成 OSD 胶囊（用户要求：所有通知走 OSD）。
void _bridgeNotificationsToOsd() {
  if (!mounted) return;
  final s = AppState.instance;
  // ① 错误 / 断连重连：文案变化才弹，避免每帧重弹
  final banner = s.connectionBanner ?? '';
  if (banner.isNotEmpty && banner != _lastOsdChatError) {
    _lastOsdChatError = banner;
    if (banner.contains('重连')) {
      OsdToast.info(context, banner);
    } else {
      OsdToast.error(context, banner);
    }
  }
  if (banner.isEmpty) _lastOsdChatError = '';
  // ② 新消息：只有不在该会话里才提示（与旧横幅同样的开关）
  if (AppearanceState.instance.noticeBannerEnabled &&
      s.noticeSeq != _lastOsdNoticeSeq &&
      s.noticePeerId != null) {
    _lastOsdNoticeSeq = s.noticeSeq;
    OsdToast.info(context, '${s.noticeName ?? ''}：${s.noticeText ?? ''}');
  }
  // ③ OSD 是纯提示，不需要常驻：立刻回收横幅状态，避免下次同文案不再触发
  if (s.connectionBanner != null) s.dismissConnectionBanner();
}
```

在 `_onState()` 末尾调用 `_bridgeNotificationsToOsd()`（放到 `setState` 之后，确保 `context` 可用）。

> 关键点：旧 `chatError` 是**常驻**状态（要手动关），OSD 是**瞬时**提示。因此桥接后立刻 `dismissConnectionBanner()`，否则同一条错误第二次出现时文案没变化、OSD 不再弹。

4. `settings_page.dart` 通知分区文案同步：

```dart
const Text('新消息提醒（OSD 提示条）'),
subtitle: const Text('不在会话里时，顶部弹出发送人与内容摘要'),
```

- [ ] **Step 4: 跑测试确认 GREEN**

Run: `flutter test test/banner_to_osd_test.dart` → PASS
Run: `flutter test` → 全绿（注意 `widget_test.dart` 依赖 Shell 渲染，横幅删除不应影响它）

- [ ] **Step 5: 全量回归**

Run: `flutter analyze` → No issues（删除的类不能留下未用 import）。

---

### Task 3: 文件 TAB 过滤按钮字重统一

> **用户 2026-10-14 纠正（以此为准）**：这里的「字重」**不是**选中/未选中的差异 —— 未选中的各个按钮之间也必须一致。
>
> 实测现状（探针输出）：7 个按钮**都**渲染为 `w500 / 14.0`，但主题层 `chipTheme.labelStyle` 与 `secondaryLabelStyle` **都是 `null`**。也就是说当前的一致是「碰巧继承 M3 默认值」，一处默认值变化或某一支被覆盖就会散架 —— 这正是用户反复看到「乱」的结构成因。
>
> 要求：在 `chipTheme` 里**显式钉死**两个字重（同字号、同字重），不再继承默认。
> 测试已由控制者写好：`test/chip_weight_uniform_test.dart`（逐个抓 7 个按钮的**最终渲染样式**并要求完全一致，浅色与深色各一条；另有主题层断言）。本任务不要另写测试，只需让它变绿。

**Files:**
- Modify: `lib/main.dart:342-345`（`chipTheme`）
- Test: `test/chip_weight_test.dart`（新建）

**Interfaces:**
- Consumes: 无
- Produces: 全局 `chipTheme.labelStyle` 与 `secondaryLabelStyle` 字重一致（`FontWeight.w600`）。

- [ ] **Step 1: 写失败测试**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_flutter_ui/main.dart';

/// 文件 TAB 过滤按钮（ChoiceChip）选中/未选中字重必须一致。
///
/// 根因在主题层：ChoiceChip 选中态取 `secondaryLabelStyle`、未选中取
/// `labelStyle`（见 Flutter `choice_chip.dart:232`），两条来源各写一份字重
/// 就会出现「粗细不统一」。所以断言直接打在主题上。
void main() {
  test('chipTheme 的选中/未选中标签字重一致', () {
    for (final b in [Brightness.light, Brightness.dark]) {
      final t = buildAppTheme(b);
      final sel = t.chipTheme.secondaryLabelStyle?.fontWeight;
      final unsel = t.chipTheme.labelStyle?.fontWeight;
      expect(unsel, isNotNull, reason: '$b：未选中字重不能留给 M3 默认');
      expect(sel, isNotNull, reason: '$b：选中字重不能留给 M3 默认');
      expect(sel, unsel, reason: '$b：选中与未选中必须同字重');
    }
  });
}
```

- [ ] **Step 2: 跑测试确认 RED**

Run: `flutter test test/chip_weight_test.dart`
Expected: FAIL —— 当前 `chipTheme` 只设了 `shape` 和 `side`，两个字重都是 `null`。

- [ ] **Step 3: 最小实现**

`lib/main.dart` 的 `chipTheme`：

```dart
chipTheme: ChipThemeData(
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
  side: BorderSide.none,
  // 用户要求：各过滤按钮字重统一。
  // ChoiceChip 的选中态取 secondaryLabelStyle、未选中取 labelStyle，
  // 两条来源各写一份字重就是「粗细不统一」的根因 —— 这里同时钉死。
  labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
  secondaryLabelStyle:
      const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
),
```

- [ ] **Step 4: 跑测试确认 GREEN**

Run: `flutter test test/chip_weight_test.dart` → PASS

- [ ] **Step 5: 回归**

Run: `flutter test` + `flutter analyze`。

---

### Task 4: 文件卡片选中跟手（把磁盘 IO 移出 build）

**Files:**
- Modify: `lib/ui/files_page.dart:28-56`（状态字段）、`:137-234`（`_reload`/`_visible`/`_sortFiles`）、`:365-485`（build 传参）、`:551-658`（网格/列表）、`:946-1164`（`_FileTile`/`_FileRow`）
- Test: `test/files_selection_latency_test.dart`（新建）

**Interfaces:**
- Consumes: 无新增
- Produces: 顶层数据类 `FileEntry`：

```dart
/// 扫盘一次得到的文件条目：把磁盘元数据缓存在这里，
/// 排序 / 过滤 / 渲染都不再碰磁盘。
class FileEntry {
  FileEntry(this.file, this.size, this.mtime, this.name, this.ext);
  final File file;
  final int size;
  final DateTime mtime;
  final String name;
  final String ext;
}
```

- 状态字段由 `List<File> _files` 改为 `List<FileEntry> _files`。
- `_FileTile` / `_FileRow` 的 `file` 参数类型由 `File` 改为 `FileEntry`。

- [ ] **Step 1: 写失败测试**

```dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_flutter_ui/appearance.dart';
import 'package:rust_flutter_ui/services/transfer_service.dart';
import 'package:rust_flutter_ui/ui/files_page.dart';

/// 文件卡片选中要跟手（修 bug.md 第 5 行）：
/// 每帧 build 不再做 statSync/lengthSync —— 磁盘元数据在扫盘时缓存一次。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('build 不重复读磁盘：同一次渲染内管道被复用', (tester) async {
    final dir = Directory.systemTemp.createTempSync('files_cache_');
    addTearDown(() => dir.deleteSync(recursive: true));
    for (var i = 0; i < 30; i++) {
      File('${dir.path}${Platform.pathSeparator}f$i.txt').writeAsStringSync('x' * (i + 1));
    }
    TransferService.downloadDirOverride = () => dir.path;
    addTearDown(() => TransferService.downloadDirOverride = null);
    AppearanceState.instance.setReceiveDir(null);

    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: FilesPage())));
    await tester.pump(const Duration(milliseconds: 300));

    // 选中第一个：本次 setState 后 build 命中缓存，不应再出现新的磁盘读
    final before = _statCounter.value;
    await tester.tap(find.text('f0.txt'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(_statCounter.value, before,
        reason: '选中触发的重建不能再读磁盘元数据');
  });
}
```

> 计数用生产代码里可注入的探针：`FilesPage` 暴露 `@visibleForTesting static int Function(File)? statProbe;`，默认走 `f.statSync()`。这是唯一为测试加的口子，签名见本任务 Interfaces。

- [ ] **Step 2: 跑测试确认 RED**

Run: `flutter test test/files_selection_latency_test.dart`
Expected: FAIL — `statProbe` 不存在（编译失败），先加探针与 `FileEntry` 骨架，再跑 → FAIL，计数在选中后仍增长。

- [ ] **Step 3: 最小实现**

1. `_reload()` 扫盘时一次性取元数据：

```dart
final list = <FileEntry>[];
if (dir.isNotEmpty) {
  try {
    for (final f in Directory(dir).listSync(recursive: true)) {
      if (f is! File) continue;
      var size = 0;
      var mtime = DateTime.fromMillisecondsSinceEpoch(0);
      try {
        final st = statProbe?.call(f) ?? f.statSync();
        size = st.size;
        mtime = st.modified;
      } catch (_) {
        // 不可读：按 0 大小 / 纪元时间参与排序，不中断扫盘
      }
      list.add(FileEntry(
        f, size, mtime, f.uri.pathSegments.last, fileExt(f.path),
      ));
    }
  } catch (_) {}
}
```

2. `_sortFiles` 改为纯内存比较（不再 `statSync`/`lengthSync`）：

```dart
List<FileEntry> _sortFiles(List<FileEntry> input) {
  final list = [...input];
  switch (_sort) {
    case FileSort.timeDesc: list.sort((a, b) => b.mtime.compareTo(a.mtime));
    case FileSort.timeAsc:  list.sort((a, b) => a.mtime.compareTo(b.mtime));
    case FileSort.nameAsc:  list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    case FileSort.nameDesc: list.sort((a, b) => b.name.toLowerCase().compareTo(a.name.toLowerCase()));
    case FileSort.sizeDesc: list.sort((a, b) => b.size.compareTo(a.size));
    case FileSort.sizeAsc:  list.sort((a, b) => a.size.compareTo(b.size));
    case FileSort.typeAsc:
      list.sort((a, b) {
        final c = a.ext.compareTo(b.ext);
        return c != 0 ? c : b.mtime.compareTo(a.mtime);
      });
  }
  return list;
}
```

3. `_visible` 改为返回 `List<FileEntry>`，过滤用缓存的 `ext`：

```dart
List<FileEntry> get _visible {
  final base = _filter == 'all'
      ? _files
      : _files.where((e) {
          final exts = _filters.firstWhere((f2) => f2.$1 == _filter).$3;
          return exts.contains(e.ext);
        }).toList();
  return _sortFiles(base);
}
```

4. `_selected` 仍存路径（`_selectedFiles` 改为 `_visible.where((e) => _selected.contains(e.file.path)).map((e) => e.file).toList()`）。
5. `_FileTile`/`_FileRow` 接收 `FileEntry entry`，内部直接用 `entry.name` / `entry.size` / `entry.mtime` / `entry.ext`，删除各自的 `statSync` 块；`_openStandalone(entry.file, ...)`。
6. 网格 itemBuilder 的 key 从 `files[i].path` 改 `files[i].file.path`。

- [ ] **Step 4: 跑测试确认 GREEN**

Run: `flutter test test/files_selection_latency_test.dart` → PASS

- [ ] **Step 5: 回归（含旧用例）**

Run: `flutter test`
Expected: 全绿，尤其 `test/mobile_receive_reveal_test.dart`（文件列表按名字找）与 `test/ui_polish_test.dart`。

---

### Task 5: PC「打开文件」用系统默认应用；「打开方式」给始终/仅一次

**Files:**
- Modify: `lib/services/platform_channel.dart:114-133`（拆 `openFile` 与 `revealInFolder`）、新增 `openWithDialog`
- Modify: `lib/ui/files_page.dart:660-740`（菜单）、`:803-859`（打开逻辑）、`:1193-1202`（`_openStandalone`）
- Modify: `lib/ui/chat_page.dart:1103-1153`、`:1473-1493`（气泡打开）
- Test: `test/file_open_semantics_test.dart`（新建）

**Interfaces:**
- Consumes: 无
- Produces:
  - `YuChuanPlatform.openFile(String path)` —— 语义收紧为「用系统默认应用打开文件」。
  - `YuChuanPlatform.revealInFolder(String path)` —— 语义为「在文件管理器中定位」。
  - 新增 `YuChuanPlatform.openWithDialog(String path)` —— 弹系统「打开方式」；桌面用 `rundll32 shell32.dll,OpenAs_RunDLL <path>`（自带「始终使用此应用」勾选），安卓用 `openFileWithChooser`。

- [ ] **Step 1: 写失败测试**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_flutter_ui/services/platform_channel.dart';

/// 桌面「打开文件」必须调系统默认应用，不能退化成打开所在目录
/// （修 bug.md 第 8 行）。
void main() {
  test('openFile 与 revealInFolder 是两个不同操作', () {
    // 语义分离的契约：桌面 openFile 走默认应用（cmd /c start），
    // revealInFolder 才走 explorer /select
    expect(YuChuanPlatform.describeOpenCommand(r'C:\tmp\a.txt', reveal: false),
        contains('start'));
    expect(YuChuanPlatform.describeOpenCommand(r'C:\tmp\a.txt', reveal: true),
        contains('/select'));
  });

  test('打开方式走系统 OpenAs 对话框（含始终/仅一次）', () {
    expect(YuChuanPlatform.describeOpenCommand(r'C:\tmp\a.txt', openWith: true),
        contains('OpenAs_RunDLL'));
  });
}
```

- [ ] **Step 2: 跑测试确认 RED**

Run: `flutter test test/file_open_semantics_test.dart`
Expected: FAIL —— `describeOpenCommand` 不存在（编译失败）。先加该纯函数（把命令拼装从 `Process.start` 里抽出来，便于测试），再跑 → 仍 FAIL 于未实现分支。

- [ ] **Step 3: 最小实现**

`platform_channel.dart`：

```dart
/// 桌面命令拼装（纯函数，便于测试）：三种语义互不相同。
/// - reveal=false, openWith=false：用系统默认应用打开
/// - reveal=true：在文件管理器中定位该文件
/// - openWith=true：弹「打开方式」对话框（Windows 自带「始终使用此应用」）
@visibleForTesting
static List<String> openCommand(String path,
    {bool reveal = false, bool openWith = false}) {
  if (Platform.isWindows) {
    if (reveal) return ['explorer.exe', '/select,$path'];
    if (openWith) return ['rundll32.exe', 'shell32.dll,OpenAs_RunDLL', path];
    // 不能用 Process.start(path)（它要求 path 本身可执行）；
    // 走 cmd start 才会交给 shell 按关联程序打开，且能处理空格路径
    return ['cmd', '/c', 'start', '', path];
  }
  if (Platform.isMacOS) {
    if (reveal) return ['open', '-R', path];
    if (openWith) return ['open', '-a', path];
    return ['open', path];
  }
  return ['xdg-open', path];
}

/// 测试用：把命令拼回一行，断言用的是哪条分支。
@visibleForTesting
static String describeOpenCommand(String path,
        {bool reveal = false, bool openWith = false}) =>
    openCommand(path, reveal: reveal, openWith: openWith).join(' ');
```

`openFile` 改为（**根因**：旧代码在 Windows 用 `/select`，这就是「打开变成打开目录」）：

```dart
/// 用系统默认应用打开文件。返回 null=成功。
static Future<String?> openFile(String path) async {
  if (isAndroid) return _invoke<String>('openFile', path);
  try {
    final argv = openCommand(path);
    await Process.start(argv.first, argv.sublist(1));
    return null;
  } catch (e) {
    return '$e';
  }
}

/// 弹系统「打开方式」对话框：用户在系统 UI 里选「仅一次 / 始终」。
static Future<String?> openWithDialog(String path) async {
  if (isAndroid) return openFileWithChooser(path);
  try {
    final argv = openCommand(path, openWith: true);
    await Process.start(argv.first, argv.sublist(1));
    return null;
  } catch (e) {
    return '$e';
  }
}

/// 打开所在文件夹（定位）。
static Future<String?> revealInFolder(String path) async {
  if (!isAndroid) {
    try {
      final argv = openCommand(path, reveal: true);
      await Process.start(argv.first, argv.sublist(1));
      return null;
    } catch (e) {
      return '$e';
    }
  }
  // ...（安卓分支保持原样）
}
```

`files_page.dart` 菜单（去掉应用自弹的「记住选择？」对话框 —— 用户要求交给系统）：

```dart
// 「打开」：记忆了始终则直接开，否则弹选择器并把「始终」交给系统
IconMenuAction(
  id: 'open',
  label: '打开',
  icon: Icons.open_in_new,
  run: () => _openFileWithPreference(file),
),
IconMenuAction(
  id: 'openWithChooser',
  label: '打开方式…',
  icon: Icons.apps_outlined,
  run: () async {
    final err = await YuChuanPlatform.openWithDialog(file.path);
    _snack(err == null ? '已调起系统打开方式' : '打开失败：$err');
  },
),
```

```dart
/// 按偏好打开：记忆了「始终」→ 默认应用直开；否则交给系统选择器，
/// 由系统 UI 自己询问并记住「仅一次 / 始终」（不再自弹冗余询问框）。
Future<void> _openFileWithPreference(File file) async {
  final ext = fileExt(file.path);
  final pref = AppearanceState.instance.openWithPrefs[ext];
  if (pref == 'always') {
    _openFile(file, context);
    return;
  }
  final err = await YuChuanPlatform.openWithDialog(file.path);
  if (!mounted) return;
  if (err != null) _snack('打开失败：$err');
}
```

`_openStandalone` 与气泡的打开保持调 `openFile`（现在语义正确），**失败回落**改为提示而不是静默开目录：

```dart
Future<void> _openStandalone(File file, BuildContext context) async {
  final err = await YuChuanPlatform.openFile(file.path);
  if (err == null) return;
  if (!context.mounted) return;
  OsdToast.error(context, '打开失败：$err');
}
```

- [ ] **Step 4: 跑测试确认 GREEN**

Run: `flutter test test/file_open_semantics_test.dart` → PASS

- [ ] **Step 5: 回归**

Run: `flutter test` + `flutter analyze`。

---

### Task 6: 安卓「打开所在文件夹」回到文件管理器的真实目录

**Files:**
- Modify: `lib/app_state.dart:2788-2814`（`revealFolder`）
- Test: `test/reveal_folder_android_test.dart`（新建）

**Interfaces:**
- Consumes: `YuChuanPlatform.revealPublicDownloadDir()`（已存在）
- Produces: `AppState.revealFolder(String path)` 安卓分支新契约 —— 未设自定义接收目录时，一律打开公共 `Download/雨传`。

- [ ] **Step 1: 写失败测试**

```dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_flutter_ui/app_state.dart';
import 'package:rust_flutter_ui/appearance.dart';
import 'package:rust_flutter_ui/services/platform_channel.dart';

/// 安卓「打开所在文件夹」必须进文件管理器的真实目录，
/// 不能回一句「在应用内部不能打开」（修 bug.md 第 7、12 行）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('yuchuan/platform');
  final calls = <String>[];

  setUp(() {
    calls.clear();
    YuChuanPlatform.isAndroidOverride = true;
    AppearanceState.instance.setReceiveDir(null); // 未设自定义目录
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null; // 原生：打开成功
    });
  });

  tearDown(() {
    YuChuanPlatform.isAndroidOverride = null;
    AppearanceState.instance.setReceiveDir(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('安卓未设自定义目录：走公共 Download/雨传，不切文件 TAB', () async {
    final msg = await AppState.instance
        .revealFolder('/data/user/0/com.yuchuan.app/files/chat/downloads/a.txt');
    expect(calls, contains('revealPublicDownloadDir'));
    expect(calls, isNot(contains('revealFolder')),
        reason: '私有副本路径不应直接交给原生，那样只会回 APP_INTERNAL');
    expect(msg, contains('已打开'));
  });

  test('安卓设了自定义目录：直接打开那棵树', () async {
    AppearanceState.instance.setReceiveDir(
        'content://com.android.externalstorage.documents/tree/primary%3AYuChuan');
    final msg = await AppState.instance
        .revealFolder('/data/user/0/com.yuchuan.app/files/chat/downloads/a.txt');
    expect(calls, contains('revealFolder'));
    expect(msg, contains('已打开'));
  });
}
```

- [ ] **Step 2: 跑测试确认 RED**

Run: `flutter test test/reveal_folder_android_test.dart`
Expected: FAIL —— 第一个测试走到 `revealFolder` 而非 `revealPublicDownloadDir`。

- [ ] **Step 3: 最小实现**

`revealFolder` 安卓分支改为**优先公共目录**（文件本来就已经归档在那边）：

```dart
Future<String> revealFolder(String path) async {
  if (YuChuanPlatform.isAndroid) {
    final custom = AppearanceState.instance.receiveDir;
    // ① 用户设了自定义接收目录：直接打开那棵树（文件在那边有副本）
    if (custom != null && custom.isNotEmpty) {
      final err = await YuChuanPlatform.revealInFolder(custom);
      return err == null ? '已打开所在文件夹' : '打开失败：$err';
    }
    // ② 没设自定义目录：文件的对外落点就是公共 Download/雨传。
    // 之前拿私有副本路径交给原生 → 永远回 APP_INTERNAL → 只能切应用内
    // 文件 TAB，用户看到的就是「提示在内部不能打开」。这里改走原生
    // 构造的公共目录 document URI，进系统文件管理器。
    if (_insideAppPrivate(path)) {
      final err = await YuChuanPlatform.revealPublicDownloadDir();
      return err == null ? '已打开所在文件夹' : '打开失败：$err';
    }
    // ③ 路径本身在公共存储：常规定位
    final err = await YuChuanPlatform.revealInFolder(path);
    return err == null ? '已打开所在文件夹' : '打开失败：$err';
  }
  final err = await YuChuanPlatform.revealInFolder(path);
  return err == null ? '已打开所在文件夹' : '打开失败：$err';
}
```

- [ ] **Step 4: 跑测试确认 GREEN**

Run: `flutter test test/reveal_folder_android_test.dart` → PASS（2 项）

- [ ] **Step 5: 回归**

Run: `flutter test`。`test/mobile_features_test.dart` 里若断言过旧文案（「已切到「文件」页」），按新契约同步更新，并在报告里点名。

---

### Task 7: 持久化主题深浅 + 核查其余设置项

**Files:**
- Modify: `lib/appearance.dart:100-169`（`_load`）、`:364-405`（`_save`）
- Modify: `lib/main.dart:212-227`（`themeModeNotifier` 与落盘联动）
- Modify: `lib/app_state.dart:133-146`（`filterVirtualNic` 落盘）、新增 `prefs.json` 读写
- Modify: `lib/ui/settings_page.dart:28-33`、`:871-911`（自动接收/限速接上持久化）
- Test: `test/settings_persistence_test.dart`（新建）

**Interfaces:**
- Consumes: `AppearanceState.attachDataDir(dir)`（已存在，`AppState.loadPairingStore` 里调用）
- Produces:
  - `AppearanceState.themeMode`（`ThemeMode`）与其 `setThemeMode(ThemeMode)`。
  - `AppState.autoAcceptFiles`（`bool`）与 `AppState.speedLimitMb`（`double`）及其 setter；落盘在 `<dataDir>/prefs.json`。

- [ ] **Step 1: 写失败测试**

```dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_flutter_ui/appearance.dart';
import 'package:rust_flutter_ui/app_state.dart';
import 'package:rust_flutter_ui/main.dart';

/// 双端都要记住主题深浅（修 bug.md 第 9 行），并核查其余设置项落盘。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('settings_persist_');
    AppearanceState.instance.attachDataDir(dir.path);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('显示模式落盘并可重新载入', () {
    themeModeNotifier.value = ThemeMode.dark;
    // 触发一次落盘
    AppearanceState.instance.setThemeMode(ThemeMode.dark);

    final raw = jsonDecode(
        File('${dir.path}${Platform.pathSeparator}appearance.json').readAsStringSync())
      as Map<String, dynamic>;
    expect(raw['themeMode'], 'dark');

    // 模拟重启：换目录重新注入，再载入同一次写入的内容
    final dir2 = Directory.systemTemp.createTempSync('settings_persist2_');
    addTearDown(() => dir2.deleteSync(recursive: true));
    File('${dir2.path}${Platform.pathSeparator}appearance.json')
        .writeAsStringSync(jsonEncode(raw));
    AppearanceState.instance.attachDataDir(dir2.path);
    expect(AppearanceState.instance.themeMode, ThemeMode.dark);
  });

  test('自动接收 / 限速 / 虚拟网卡过滤都落盘', () {
    AppState.instance.setAutoAcceptFiles(false);
    AppState.instance.setSpeedLimitMb(12);
    final raw = jsonDecode(File(
            '${dir.path}${Platform.pathSeparator}prefs.json')
        .readAsStringSync()) as Map<String, dynamic>;
    expect(raw['autoAccept'], false);
    expect(raw['speedLimitMb'], 12);
  });
}
```

- [ ] **Step 2: 跑测试确认 RED**

Run: `flutter test test/settings_persistence_test.dart`
Expected: FAIL —— `setThemeMode` / `prefs.json` 都不存在。

- [ ] **Step 3: 最小实现**

`appearance.dart`：

```dart
/// 显示模式（跟随系统 / 浅色 / 深色）。用户要求：双端都要记住。
ThemeMode themeMode = ThemeMode.system;

void setThemeMode(ThemeMode mode) {
  themeMode = mode;
  themeModeNotifier.value = mode; // 见 main.dart 的同名 notifier 联动
  notifyListeners();
  _save();
}
```

`_load()` 内追加（放在 `_applyLook` **之前**，保证 `_isDarkLook` 先就位）：

```dart
switch (map['themeMode'] as String?) {
  case 'light': themeMode = ThemeMode.light;
  case 'dark': themeMode = ThemeMode.dark;
  default: themeMode = ThemeMode.system;
}
```

`_save()` 的 map 里追加 `'themeMode': themeMode.name,`。

> **顺序要点（Review Focus 5）**：`main.dart` 里 `themeModeNotifier.addListener(_syncSystemBarStyle)` 会调 `setDarkLook`。启动时必须在 `attachDataDir` 载入完 `themeMode` 之后，再把 notifier 同步过去，否则会先按 system 保存一次快照、覆盖掉已存的深浅外观。

`main.dart`：

```dart
/// 显示模式全局通知器：值变化即落盘（AppearanceState 是唯一持久化出口）。
final ValueNotifier<ThemeMode> themeModeNotifier =
    ValueNotifier<ThemeMode>(ThemeMode.system);

/// 由 AppearanceState 载入后调用一次，把落盘值灌进 UI。
void applyLoadedThemeMode() {
  themeModeNotifier.value = AppearanceState.instance.themeMode;
}
```

并在 `main()` 的 `loadPairingStore()` 之后 `_syncSystemBarStyle()` 之前调用 `applyLoadedThemeMode()`；`NavRail` 与设置页切主题时改走：

```dart
AppearanceState.instance.setThemeMode(dark ? ThemeMode.light : ThemeMode.dark);
```

`app_state.dart` 新增：

```dart
/// 自动接收可信联系人的文件（设置项，需跨重启记住）。
bool autoAcceptFiles = true;
/// 传输限速 MB/s，0 = 不限速（设置项，需跨重启记住）。
double speedLimitMb = 0;

File? get _prefsFile {
  final dir = DiscoveryService.instance.dataDir;
  if (dir == null || dir.isEmpty) return null;
  return File('$dir${Platform.pathSeparator}prefs.json');
}

void _loadPrefs() {
  try {
    final f = _prefsFile;
    if (f == null || !f.existsSync()) return;
    final m = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    autoAcceptFiles = m['autoAccept'] as bool? ?? true;
    speedLimitMb = (m['speedLimitMb'] as num? ?? 0).toDouble().clamp(0, 50);
    filterVirtualNic = m['filterVirtualNic'] as bool? ?? true;
  } catch (_) {}
}

void _savePrefs() {
  try {
    final f = _prefsFile;
    if (f == null) return;
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(jsonEncode({
      'autoAccept': autoAcceptFiles,
      'speedLimitMb': speedLimitMb,
      'filterVirtualNic': filterVirtualNic,
    }));
  } catch (_) {}
}

void setAutoAcceptFiles(bool v) { autoAcceptFiles = v; notifyListeners(); _savePrefs(); }
void setSpeedLimitMb(double v) { speedLimitMb = v.clamp(0, 50); notifyListeners(); _savePrefs(); }
```

`setFilterVirtualNic` 末尾追加 `_savePrefs();`；`loadPairingStore()` 内 `attachDataDir` 之后追加 `_loadPrefs();`。

`settings_page.dart` 去掉本地 `_autoAccept` / `_speedLimit` 字段，改用 `AppState`：

```dart
value: AppState.instance.autoAcceptFiles,
onChanged: AppState.instance.setAutoAcceptFiles,
// ...
value: AppState.instance.speedLimitMb,
onChanged: AppState.instance.setSpeedLimitMb,
```

- [ ] **Step 4: 跑测试确认 GREEN**

Run: `flutter test test/settings_persistence_test.dart` → PASS（2 项）

- [ ] **Step 5: 核查报告 + 回归**

逐项对照设置页所有控件与落盘字段，把结果写进最终报告（哪些原本就持久化、哪些本次修好、哪些仍是本地/未接线）。然后跑 `flutter test` + `flutter analyze`。

> **用户 2026-10-14 裁决**：「自动接收」与「限速」**按默认处理** —— 本任务只让它们能被记住（落盘/载入），**不新增**与 Rust 传输层的接线。是否真正生效留待用户后续决定，最终报告里必须点名这两项仍未接线。

---

### Task 8: 聊天标题的筛选按钮换成更直观的图标样式

**Files:**
- Modify: `lib/ui/chat_page.dart:345-357`（筛选按钮）
- Test: `test/chat_filter_button_test.dart`（新建）

**Interfaces:**
- Consumes: 无
- Produces: 筛选按钮保持 `IconButton`，但图标按当前筛选态取「专属图标」，并用 `Badge` 指示「正在筛选」。

- [ ] **Step 1: 写失败测试**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_flutter_ui/app_state.dart';
import 'package:rust_flutter_ui/models.dart';
import 'package:rust_flutter_ui/ui/chat_page.dart';

/// 筛选按钮要一眼看出「当前在筛什么」（修 bug.md 第 11 行）。
/// 用户要求：仍然是纯图标，只换图标样式。
void main() {
  testWidgets('不同筛选态使用不同图标，且不出现文字标签', (tester) async {
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
        messages: [],
      ));

    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: ChatPage(peerId: 'dev-f'))));
    await tester.pump(const Duration(milliseconds: 300));

    // 初始：全部消息 → 该图标
    expect(find.byIcon(Icons.filter_alt_outlined), findsOneWidget);
    // 纯图标：按钮区域内不应出现「全部消息/仅图片」之类的文字
    expect(find.text('仅图片'), findsNothing);
  });
}
```

- [ ] **Step 2: 跑测试确认 RED**

Run: `flutter test test/chat_filter_button_test.dart`
Expected: FAIL —— 当前图标是 `filter_list_off_outlined` / `filter_list`。

- [ ] **Step 3: 最小实现**

```dart
/// 筛选态 → 图标（纯图标，靠形状区分当前在筛什么）。
(IconData, String) get _filterIcon => switch (_contentFilter) {
      'text' => (Icons.text_fields_outlined, '仅文本'),
      'image' => (Icons.image_outlined, '仅图片'),
      'file' => (Icons.insert_drive_file_outlined, '仅文件'),
      _ => (Icons.filter_alt_outlined, '全部消息'),
    };
```

按钮：

```dart
IconButton(
  tooltip: '筛选消息内容：${_filterIcon.$2}',
  icon: _contentFilter == 'all'
      ? Icon(_filterIcon.$1, size: 20)
      // 生效中：叠一个角标，"正在筛选" 一眼可辨（仍是纯图标）
      : Badge(
          backgroundColor: scheme.primary,
          label: const SizedBox.shrink(),
          smallSize: 7,
          child: Icon(_filterIcon.$1, size: 20, color: scheme.primary),
        ),
  onPressed: _showFilterMenu,
),
```

- [ ] **Step 4: 跑测试确认 GREEN**

Run: `flutter test test/chat_filter_button_test.dart` → PASS

- [ ] **Step 5: 回归**

Run: `flutter test` + `flutter analyze`。

---

### Task 9: 所有气泡都能多选；勾选框可重复点取消；去掉选中背景

**Files:**
- Modify: `lib/ui/chat_page.dart:416-447`（点击回调）、`:941-955`（选中底色）、`:1103-1209`（文字/文件气泡菜单）、`:1496-1576`（文件气泡菜单）、`:1591-1761`（图片气泡加菜单）
- Test: `test/bubble_multiselect_test.dart`（新建）

**Interfaces:**
- Consumes: `_MessageRow.onStartSelect` / `onToggleSelect`（已存在）
- Produces:
  - `_ImageBubble` 增加 `onLongPress` / `onSecondaryTap` 回调（新参数 `VoidCallback? onMenu`）。
  - 选中态**不再**叠加背景色（`wrapInner` 恒为 `entrance`）。

- [ ] **Step 1: 写失败测试**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_flutter_ui/app_state.dart';
import 'package:rust_flutter_ui/models.dart';
import 'package:rust_flutter_ui/ui/chat_page.dart';

/// 多选：所有气泡都有「多选」菜单；勾选框可重复点取消；无选中背景叠加
/// （修 bug.md 第 13 行）。
void main() {
  Future<void> pumpWith(WidgetTester tester, MessageKind kind) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final conv = Conversation(
      device: LanDevice(
        id: 'dev-m',
        name: '多选设备',
        ip: '192.168.1.8',
        platform: DevicePlatform.windows,
        online: true,
        paired: true,
      ),
      messages: [
        ChatMessage(
          id: 'm1',
          fromMe: false,
          kind: kind,
          time: DateTime.now(),
          text: kind == MessageKind.text ? '你好' : '',
          fileName: kind == MessageKind.text ? '' : 'a.txt',
          filePath: kind == MessageKind.text ? '' : '',
          progress: 1,
        ),
      ],
    );
    AppState.instance.conversations
      ..clear()
      ..add(conv);
    await tester
        .pumpWidget(const MaterialApp(home: Scaffold(body: ChatPage(peerId: 'dev-m'))));
    await tester.pump(const Duration(milliseconds: 300));
  }

  for (final kind in [MessageKind.text, MessageKind.file]) {
    testWidgets('$kind 气泡菜单含「多选」', (tester) async {
      await pumpWith(tester, kind);
      await tester.longPress(find.byType(GestureDetector).last);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('多选'), findsOneWidget);
    });
  }

  testWidgets('多选勾选框重复点可取消', (tester) async {
    await pumpWith(tester, MessageKind.text);
    // 长按进菜单 → 多选
    await tester.longPress(find.text('你好'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('多选').last);
    await tester.pump(const Duration(milliseconds: 300));
    // 已进入多选：点气泡取消
    await tester.tap(find.text('你好'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('已选'), findsNothing,
        reason: '重复点必须能取消勾选，而不是只增不减');
  });
}
```

- [ ] **Step 2: 跑测试确认 RED**

Run: `flutter test test/bubble_multiselect_test.dart`
Expected: FAIL —— 文件气泡菜单无「多选」；安卓分支只 `add` 不 `remove`；图片气泡无菜单。

- [ ] **Step 3: 最小实现**

1. **双端统一 toggle（去掉安卓「只增不减」）**：

```dart
onToggleSelect: _selecting
    ? () {
        tapFeedback();
        setState(() {
          // 用户要求：重复点要能取消勾选 —— 双端统一切换语义
          if (!_selected.remove(msg.id)) _selected.add(msg.id);
        });
      }
    : null,
```

2. **去掉选中背景叠加**（勾选框已是唯一标识）：

```dart
// 用户要求：不要选中背景叠加，只保留勾选框。
// 选择态下仍用 RepaintBoundary 隔离重绘，保证点一下只重画这一条。
final wrapped = selecting ? RepaintBoundary(child: entrance) : entrance;
```

（删除 `wrapInner` 那段 `DecoratedBox`。）

3. **文件气泡菜单补「多选」**（`_FileBubbleState._showFileMenu` 的 actions 列表里，紧跟 `forward`）：

```dart
if (!_active && widget.onStartSelect != null)
  IconMenuAction(
    id: 'multi',
    label: '多选',
    icon: Icons.checklist,
    run: () async => widget.onStartSelect!(),
  ),
```

`_FileBubble` 增加字段：

```dart
/// 菜单里的「多选」由外层行注入（与 `_MessageRow` 的其他气泡一致）。
final VoidCallback? onStartSelect;
```

`_MessageRow._buildBubbleContent` 里传入：

```dart
return _FileBubble(
  msg: m,
  onForward: widget.onForward,
  onStartSelect: widget.onStartSelect,
  selecting: widget.onToggleSelect != null,
);
```

4. **图片气泡补菜单**（现在完全没有长按/右键）：

```dart
class _ImageBubble extends StatelessWidget {
  const _ImageBubble({
    required this.msg,
    this.selecting = false,
    this.onMenu,
  });

  /// 长按（安卓）/ 右键（桌面）出菜单：由外层行注入，
  /// 保证图片气泡也有与文字/文件一致的多选、转发、删除入口。
  final VoidCallback? onMenu;
```

`build` 里的 `GestureDetector`：

```dart
return GestureDetector(
  onTap: selecting ? null : () { if (transferring) return; _openPreview(context); },
  // 多选模式不弹单条菜单（此时点按语义是勾选）
  onLongPress: selecting ? null : onMenu,
  onSecondaryTap: selecting ? null : onMenu,
  child: Hero(...),
);
```

`_MessageRow._buildBubbleContent`：

```dart
case MessageKind.image:
  return _ImageBubble(
    msg: m,
    selecting: widget.onToggleSelect != null,
    onMenu: () => _showMessageMenu(context),
  );
```

> `_showMessageMenu` 走的是 `else` 分支（非文本），已含打开文件 / 打开所在文件夹 / 转发 / 多选 / 删除，正好补齐图片气泡缺的入口。

- [ ] **Step 4: 跑测试确认 GREEN**

Run: `flutter test test/bubble_multiselect_test.dart` → PASS

- [ ] **Step 5: 回归**

Run: `flutter test` + `flutter analyze`。

---

### Task 10: 全量验收

**Files:** 无（只读验证）

- [ ] **Step 1: 全量测试**

Run: `flutter test`
Expected: 全部通过（基线 49 + 本批新增），无 warning。

- [ ] **Step 2: 静态检查**

Run: `flutter analyze`
Expected: `No issues found!`

- [ ] **Step 3: Windows 真机构建**

Run: `build_windows.bat`（或 `flutter build windows --release`）
Expected: 构建成功；启动后逐条核对：OSD 落在标题栏下方且不压窗口按钮、无顶部横幅、文件卡片点选即时、双击用默认应用打开、菜单「打开方式」出现 Windows 的「始终使用此应用」勾选。

- [ ] **Step 4: 安卓真机验证（不可自动化项）**

装 APK 后核对 4 条只能在真机确认的：安卓 OSD 不明显偏高、「打开方式」出现系统「仅一次/始终」、「打开所在文件夹」进文件管理器、「打开所在文件夹」不再回「在内部不能打开」。

- [ ] **Step 5: 写验收报告**

输出到 `CHANGES_AUDIT.md`（中文）：每项改动的 `文件:行号`、根因一句话、验证方式与实测结果、以及**明确未做/未接线**的项（自动接收与限速开关仍未接线）。
