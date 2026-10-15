# 批次 A1 改动验收清单（CHANGES_AUDIT）

> 本文档覆盖**本批**改动，取代此前那份只记录「删重复菜单项 + OSD 挪顶」的旧清单
> （旧文件对应的是更早、更小的一次改动，已过时且有误导）。
>
> 需求原文：仓库根 `修bug.md` 第 1–13 行。实施计划：
> `docs/superpowers/plans/2026-10-14-batch-a1-ui-and-persistence-fixes.md`。
> 本仓库**非 git 仓库**，无法给 diff；因此逐条给「改动文件:行号 → 根因 → 验证方式与实测结果」，
> 所有行号以落盘后的当前文件为准。

---

## 一、批次 A1 总览（逐条对应 `修bug.md` 第 1–13 行的 12 条反馈）

### 1. OSD 过于置顶、有横线、深/浅配色、圆角偏大（`修bug.md:3` 前半）

- **改动文件:行号**：`lib/ui/osd_toast.dart:6`（`_kTitleBarHeight = 38.0`）、
  `:9`（`_kRadius = 12.0`）、`:148`（`top: 0`）、`:152`（`SafeArea(top: true)`）、
  `:155`（`top: _isDesktop ? _kTitleBarHeight + 8 : 8`）、`:169`（`BorderRadius.circular(_kRadius)`）。
- **根因**：OSD 原先贴在 `bottom: 0` / `Align.bottomCenter`，位置与「提示条」语境相反；
  容器带 `Border.all` 描边，贴顶后其上缘被看成一条横线；圆角 28 过大。
- **验证方式与实测结果**：`test/osd_toast_test.dart`（3 项）——
  ①「OSD 不贴顶：顶部留出标题栏高度」断言 `Text('测试提示')` 的 `toppLeft.dy > 40`；
  ②「浅色字黑、深色字白」断言 `Text.style.color == Colors.black / Colors.white`；
  ③「圆角 ≤ 12、无描边横线」断言 `BorderRadius.topLeft.x <= 12` 且 `deco.border == null`。
  当前全绿。另：安卓侧不额外偏移（`_isDesktop` 为假时只留 8），避免顶到屏幕中部。

### 2. 去掉顶部提示横幅，所有通知统一走 OSD（`修bug.md:3` 后半）

- **改动文件:行号**：`lib/main.dart:695`（`Widget _withBanner(Widget body) => body;`，
  横幅类已删除；调用点 `:660`、`:675` 原样保留但不再包壳）、
  `lib/main.dart:548-572`（`_bridgeNotificationsToOsd()`，在 `:535` 的 `_onState` 末尾调用）。
- **根因**：顶部常驻横幅与 OSD 两套通知并存；用户要求只留 OSD。
- **验证方式与实测结果**：`test/banner_to_osd_test.dart` ——
  ①「Shell 不再渲染任何顶部横幅」断言 `find.byType(MaterialBanner)` 为空；
  ②「chatError 出现后会弹 OSD」断言错误文案仍可见（只是改走 OSD）；全绿。
  桥接里对「新消息」用 `noticeSeq` 游标去重（`main.dart:565-571`），
  开关关闭也推进游标，避免事后打开开关补弹过期提醒。

### 3. 文件 TAB：PC 端过滤按钮字体粗细统一（`修bug.md:5` 前半）

- **改动文件:行号**：`lib/main.dart:307`（`chipLabelBase`）、
  `:363-386`（`chipTheme` 里 `labelStyle` 与 `secondaryLabelStyle` 同时钉死）。
- **根因**：`ChoiceChip` 选中态取 `secondaryLabelStyle`、未选中取 `labelStyle`，
  而主题层两者原先都是 `null` —— 一致只是「碰巧继承 M3 默认」，
  任一支被覆盖或默认值变化就散架。
- **验证方式与实测结果**：`test/chip_weight_uniform_test.dart` 逐个抓 7 个按钮的
  **最终渲染样式**并要求完全一致（浅色 + 深色各一条，含主题层断言）；全绿。

### 4. 文件 TAB：文件卡片选中不跟手、慢（`修bug.md:5` 后半）

- **改动文件:行号**：`lib/ui/files_page.dart:24`（`statProbe` 测试探针）、
  `:32-38`（新增 `FileEntry` 数据类）、`:184-196`（`_reload` 扫盘时一次性取
  `size`/`mtime` 并缓存）、`:272-295`（`_sortFiles` 改为纯内存比较）、
  `:1012`、`:1129`（`_FileTile`/`_FileRow` 直接用 `entry.mtime`/`entry.size`/`entry.ext`）。
- **根因**：`statSync`/`lengthSync` 落在 `build` 路径上，每次 setState 重建都重新读盘，
  选中反馈被磁盘 IO 拖住。
- **验证方式与实测结果**：`test/files_selection_latency_test.dart` ——
  选中触发的重建不得产生新的磁盘读（比较 `FilesPage.statProbe` 计数前后相等）；全绿。

### 5. 文件 TAB：菜单「打开方式」要有【始终 / 仅一次】的默认记忆（`修bug.md:6`）

- **改动文件:行号**：`lib/services/platform_channel.dart:132-153`（`openCommand` 纯函数，
  `openWith` 分支走 `rundll32.exe shell32.dll,OpenAs_RunDLL`）、
  `:155-157`（`describeOpenCommand` 测试用）、`:188-193`（`openWithDialog`）、
  `lib/ui/files_page.dart:784-789`（菜单项 `openWithChooser`）、`:880`（`_openWithChooser`）。
- **根因**：旧实现自弹「记住选择？」询问框，而非交给系统选择器；
  用户裁决**必须**由系统 UI 提供「仅一次 / 始终」。
- **验证方式与实测结果**：`test/file_open_semantics_test.dart` 断言
  `openCommand(path, openWith: true)` 拼出的命令含 `OpenAs_RunDLL`
  （Windows 该对话框自带「始终使用此应用」勾选）；全绿。
  ⚠️ 「勾选框真的出现」只能在真机确认，见第三节。

### 6. 文件 TAB：【打开所在文件夹】要进文件管理器真实目录（`修bug.md:7`）

- **改动文件:行号**：`lib/app_state.dart:2869-2898`（`revealFolder` 安卓三分支）、
  `:2900-2908`（`_insideAppPrivate`）。
- **根因**：旧代码把**应用私有副本**路径交给原生，原生判定私有区后回 `APP_INTERNAL`，
  Dart 只能回「在应用内部不能打开」（或偷偷切到应用内「文件」TAB）；
  但文件的对外落点其实是公共 `Download/雨传`。
- **验证方式与实测结果**：`test/reveal_folder_android_test.dart`（6 项）断言
  ①未设自定义目录 + 私有路径 → 调 `revealPublicDownloadDir`，不调 `revealFolder`，
  文案不含「内部」；②设了自定义目录 + 私有路径 → 调 `revealFolder` 且参数是那棵树；
  ③路径本身在公共存储 → 原样定位；④设了自定义目录 + 公共路径 → 仍定位文件本身
  （`_insideAppPrivate` 门控，避免接收目录树劫持自己发出的文件）；
  ⑤原生报错 → 回「打开失败：…」不吞成功；⑥原生仍回 `APP_INTERNAL` → 转中文失败，
  `APP_INTERNAL` 不漏给用户，且不再改 `navIndex`。全绿。

### 7. 文件 TAB：PC 端「打开」用系统默认应用（双击与菜单项都是）（`修bug.md:8`）

- **改动文件:行号**：`lib/services/platform_channel.dart:132-153`
  （`openCommand` 默认分支 `['cmd','/c','start','',path]`；`reveal: true` 才走
  `explorer.exe /select,`）、`:175-182`（`openFile` 语义收紧为「用默认应用打开」）、
  `:245`（`revealInFolder` 负责定位）、`lib/ui/files_page.dart:777-782`
  （菜单 `open` → `_openFile`）、`:781` 与双击共用同一条路径。
- **根因**：桌面旧实现在 `openFile` 里跑 `explorer /select` —— 于是「打开」被做成了
  「打开所在目录」，这正是用户第 8 行的投诉。
- **验证方式与实测结果**：`test/file_open_semantics_test.dart` 两条纯函数断言 ——
  `reveal: false` 的命令含 `start`（默认应用），`reveal: true` 的命令含 `/select`；
  两者互不相同。全绿。

### 8. 双端都没记住主题深浅（`修bug.md:9` 前半）

- **改动文件:行号**：`lib/appearance.dart:33`（`ThemeMode themeMode`）、
  `:167`（`_load` 读 `map['themeMode']`，在 `_applyLook` 之前，见 `:187` 附近）、
  `:249-254`（`setThemeMode`，唯一写入口）、`:410`（`_save` 写 `themeMode.name`）、
  `lib/main.dart:221`（载入后灌 `themeModeNotifier`）、`:831`、`:817`（NavRail 切换）、
  `lib/ui/settings_page.dart:337`。
- **根因**：`themeMode` 只存在内存里的 `ValueNotifier`，从未落盘。
- **验证方式与实测结果**：`test/settings_persistence_test.dart` 第 1 条 ——
  设置深色后 `appearance.json` 含 `"themeMode":"dark"`，换目录重新 `attachDataDir`
  后 `themeMode == ThemeMode.dark`（模拟重启）；全绿。
  顺序要点：必须先载完再灌 notifier，否则会按 `system` 抢先保存一份外观快照覆盖已存值。

### 9. 核查其余设置项有没有持久化并修复（`修bug.md:9` 后半）

- **改动文件:行号**：`lib/app_state.dart:142`、`:146`（`autoAcceptFiles` / `speedLimitMb`）、
  `:152-160`（`_prefsFile` → `<dataDir>/prefs.json`）、`:162`、`:166-177`（`_loadPrefs`）、
  `:179-192`（`_savePrefs`）、`:194-204`（两个 setter）、`:210`（`setFilterVirtualNic` 也落盘）、
  `lib/ui/settings_page.dart:876-877`、`:894-906`（开关改读 `AppState`，不再用页面本地字段）。
- **根因**：自动接收、限速、虚拟网卡过滤原先只存在页面/内存字段里，重启即丢。
- **验证方式与实测结果**：`test/settings_persistence_test.dart` 第 2 条 ——
  写 `prefs.json` 后 `autoAccept == false`、`speedLimitMb == 12`；全绿。
  ⚠️ **只记忆选择，未接入传输层**，见第四节。
  另外「接收目录」本来就是 `AppearanceState` 持久化项，本批未动（核查结论：原本就正确）。

### 10. 聊天窗口：标题的筛选按钮更换样式使其更直观（`修bug.md:11`）

- **改动文件:行号**：`lib/ui/chat_page.dart:66-71`（`_filterIcon`：每个筛选态一个专属图标）、
  `:364-378`（`IconButton`，非「全部」时叠一个主色 `Badge` 圆点表示筛选生效中）。
- **根因**：原按钮只有 `filter_list` / `filter_list_off` 两种形态，看不出「在筛什么」。
- **验证方式与实测结果**：`test/chat_filter_button_test.dart` 断言初始态为
  `Icons.filter_alt_outlined`，且按钮区域**不出现文字标签**（用户裁决：保持纯图标，
  不加文字/胶囊/分段控件；只换图标样式，不动尺寸与位置）；全绿。

### 11. 聊天窗口：手机端文件气泡菜单【打开所在文件夹】进文件管理器，不是文件 TAB（`修bug.md:12`）

- **改动文件:行号**：与第 6 条同一处 `lib/app_state.dart:2869-2898`；
  聊天侧调用点 `lib/ui/chat_page.dart:1565-1570`（文件气泡菜单 `folder` →
  `state.revealFolder(path)`，文案走 OSD `_snack`）。
- **根因**：与第 6 条同源 —— 两处入口共用一个 `revealFolder`，都会回「在内部不能打开」。
- **验证方式与实测结果**：`test/reveal_folder_android_test.dart` 6 项全绿；
  该用例头部注释已明确「文件 TAB 与聊天窗文件气泡菜单两处反馈的是同一个 bug」。

### 12. 聊天窗口：所有类型气泡都要有多选菜单；不要选中背景叠加；重复点要能取消勾选（`修bug.md:13`）

- **改动文件:行号**：`lib/ui/chat_page.dart:441-464`（`onStartSelect` + 双端统一切换语义，
  去掉安卓「只增不减」）、`:959-961`（`wrapped = selecting ? RepaintBoundary(child: entrance) : entrance`，
  删除选中背景 `DecoratedBox`）、`:1200-1207`（文字气泡菜单 `multi`）、
  `:1539-1545`（文件气泡菜单 `multi`）、`:1624-1651`、`:1661-1682`（图片气泡自己的手势层）。
- **根因**：① 文件/图片气泡菜单缺「多选」入口；② 安卓分支 `_selected.add` 只增不减，
  重复点无法取消；③ 选中态额外叠了一层主色半透明 `DecoratedBox`，与勾选框重复且闪。
- **验证方式与实测结果**：`test/bubble_multiselect_test.dart`（12 项）——
  文件气泡菜单含「多选」；图片气泡长按/右键弹出**一个**菜单（不内外各弹一次）；
  多选态重复点气泡/勾选框可取消且能再次选中；取消最后一条会退出多选；
  选中态气泡装饰与非选中态**完全一致**（勾选框是唯一标识）。全绿。

---

## 二、测试与静态检查（本批收尾实测）

| 项目 | 命令 | 结果 |
| --- | --- | --- |
| 全量测试 | `C:\flutter\bin\flutter.bat test` | **`00:18 +99: All tests passed!`** —— 99 项全绿（本批开始前基线 98 项；本轮 A1/A2 净增 1 项） |
| 静态检查 | `C:\flutter\bin\flutter.bat analyze` | **`3 issues found.`** —— 与仓库既有的 3 条完全一致，全部是 `test/transfer_flow_test.dart:151:18`、`:151:51`、`:152:18` 的 `unnecessary_non_null_assertion`。**无新增问题** |
| 聚焦回归 | `flutter test test/bubble_multiselect_test.dart` | `+12: All tests passed!` |
| Windows 构建 | `build_windows.bat`（见下节） | 成功 |

> `flutter analyze` 的退出码非 0 是这 3 条既有 warning 造成的，与本次改动无关；
> 本批**未**修改 `test/transfer_flow_test.dart`。

### 本轮（Task 10）在批次内额外清掉的 3 条 review 结论

- **A1｜桌面右键点图片气泡，菜单丢鼠标锚点。** 图片气泡原先只注册
  `onSecondaryTap` 不注册 `onSecondaryTapDown`，而 `_menuPos` 全仓库只有外层
  `_MessageRow` 的 `onSecondaryTapDown`（`lib/ui/chat_page.dart:915`）会写；
  快速右键在手势竞技场里判给最深的识别器 → 外层收不到 → `_menuPos` 保持 `null`
  → `showIconMenu` 回落到整行中心（`lib/ui/menus.dart:253-256`）。
  改法对齐 `_FileBubble:1309` 的既有做法：给 `_ImageBubble` 增加
  `onSecondaryTapDown` 参数（`chat_page.dart:1644-1651`），在气泡**自己**的手势里
  记录并回填给本行（`chat_page.dart:1681` 与调用点 `:1032`）；
  `selecting` 时该回调为 `null`，与 `onTap`/`onLongPress`/`onSecondaryTap` 一起整路注销
  （`chat_page.dart:1670-1682`）。
  **判别性证明（RED→GREEN）**：单独把内层 `onSecondaryTapDown` 改成 `null` 后，
  新增用例 `图片气泡右键菜单锚定在鼠标落点（不是整行中心）` 变红 ——
  `菜单左边缘应贴着右键落点 x=94.0，实测 700.0（等于回落逻辑的整行中心）`；
  恢复后该用例转绿（`+12: All tests passed!`）。
- **A2｜用例 `图片气泡自身注册了长按/右键出菜单的手势` 名不副实。** 它取的是 `Hero` 的
  **最近** `GestureDetector` 祖先，而外层行级手势同样是 `Hero` 的祖先、回调同样非空，
  所以删掉内层手势它照样能过（空洞绿）。已加固：断言该层 `child` **就是** `Hero`
  （`test/bubble_multiselect_test.dart:207-217`），并同时断言 `onSecondaryTapDown` 非空。
  **判别性证明（RED→GREEN）**：把内层 `GestureDetector` 整层删掉后，该用例变红 ——
  `Expected: <Instance of 'Hero'> / Actual: AnimatedOpacity:<AnimatedOpacity(duration: 120ms, opacity: 1.0)>`
  （即最近祖先变成了外层行级手势）；恢复后转绿。这次证明同时说明：
  **光靠 `onLongPress`/`onSecondaryTap` 非空是抓不住这个回归的**。
- **A3｜注释与代码不符。** 图片气泡原注释称多选态「与文件卡片同一套约定」，
  但 `_FileBubble` 只把 `onTap` 挂在 `selecting` 上，其 `onLongPress` 在多选态
  **照样**弹菜单。已把注释改成陈述实际行为，并明确点出两者不同
  （`lib/ui/chat_page.dart:1661-1669`），同时把 `selecting` 字段的文档同步为
  「单击/长按/右键全不注册」（`:1636-1638`）。**未改动任何行为** —— 见第五节。

---

## 三、只能真机确认的项（不可自动化，务必在真机逐条核对）

这四条 Dart 侧已经接线且单测覆盖到「调了哪个平台方法」，但**最终效果只有真机能判**：

1. **安卓 OSD 不再偏高**。代码保证 `_isDesktop` 为假时只留 `8` 而不是 `38+8`
   （`lib/ui/osd_toast.dart:155`），单测只能断言「桌面下 `top > 40`」；
   安卓真机上「落在状态栏之下、不浮到屏幕中部」需要肉眼确认。
2. **安卓「打开方式」出现系统「仅一次 / 始终」**。代码走
   `YuChuanPlatform.openWithDialog` → `openFileWithChooser`
   （`lib/services/platform_channel.dart:188-193`、`:226-231`），
   但系统选择器长什么样、是否带「始终」，只能在真机看。
3. **安卓「打开所在文件夹」进文件管理器，且不再提示「在内部不能打开」**。
   单测断言走 `revealPublicDownloadDir` 且文案不含「内部」
   （`test/reveal_folder_android_test.dart`），但（a）是否真的拉起文件管理器、
   （b）是否定位到 `Download/雨传`，需要真机确认。
4. **Windows 双击 / 菜单「打开」用默认应用打开；「打开方式」对话框确有「始终使用此应用」**。
   单测只能断言命令拼装含 `start` 与 `OpenAs_RunDLL`；
   对话框的实际外观与勾选框必须真机看。

---

## 四、未接线 / 未生效的项（明确声明）

- **「自动接收」开关**：`AppState.autoAcceptFiles`（`lib/app_state.dart:142`）现在能落盘/载入
  （`:171`、`:185`、`:194`），设置页也改成读它（`lib/ui/settings_page.dart:876-877`），
  但**没有任何生产代码读取它去决定是否自动接收**（全仓 `grep autoAcceptFiles` 只命中
  定义、载入、保存、setter、设置页）。**开关目前不生效**，只记忆选择。
- **「限速」开关**：`AppState.speedLimitMb`（`lib/app_state.dart:146`）同样只落盘/载入
  （`:172`、`:186`、`:200`），**未接入 Rust 传输层**，**不生效**，只记忆选择。
  （以上两项依用户 2026-10-14 裁决「按默认处理」——本批只做持久化，不新增传输层接线。）

---

## 五、已知遗留（本批**记录但未修**）

一行一条，附我的判断：

1. `AppState.dismissConnectionBanner()`（`lib/app_state.dart:1139-1143`）自横幅删除后
   **无生产调用方**（全仓仅 `test/banner_to_osd_test.dart:126` 调用）。影响低：
   属死代码，但删它会动测试，留给后续清理。
2. **错误态 `chatError` 没有任何用户可见的关闭入口**（旧横幅的「知道了」按钮随横幅一起没了），
   卡住的错误会一直留在设置页副标题（`lib/ui/settings_page.dart:759-765`）。
   影响中：文案本身仍可见+有 OSD，但用户无法主动清掉。**建议下一批补一个可关闭入口。**
3. 桌面现在对**每一条**新消息都弹 2 秒 OSD（`lib/main.dart:565-571`，OSD 时长
   `lib/ui/osd_toast.dart:73`/`:81`/`:89`）。批次指示「所用通知走 OSD」被理解为涵盖桌面，
   而此前用户另有「桌面不弹顶部条」的诉求 —— **这一条我按要求只记录、留给用户裁决**。
   影响中高：消息密集时会连续弹条，桌面端可能觉得吵。
4. `test/chat_filter_button_test.dart` / `test/bubble_multiselect_test.dart`：
   `useBottomSheetMenus == true`（底部弹层菜单）这条分支**没有测试**。
   影响中：设置里能切到该模式，切换后菜单路径完全无覆盖。
5. `test/files_selection_latency_test.dart` 只统计走 `FilesPage.statProbe` 的读盘；
   若有人在 build 路径重新引入裸 `statSync`，该用例**抓不住**。
   影响低：真正兜底的是 `FileEntry` 类型本身（build 拿不到 `File` 的元数据）。
6. `test/reveal_folder_android_test.dart` 的第 2、3 条不是 revert-to-red
   （删掉对应实现它们不会红）。影响低：第 1、4 条是真的判别性护栏，覆盖了主风险。
7. `lib/main.dart:377-386` 两处 chip 标签样式重复写了 `fontSize: 14, fontWeight: w500`
   —— `chipLabelBase`（`:307`）已经带同样的值。影响极低：冗余，可删。
8. `test/chip_weight_uniform_test.dart:114`、`:130` 把字体名 `Roboto` 写进了期望串
   （测试平台是 MountainView，Windows 上是 Redmond）。影响低：当前测试环境稳定通过，
   属跨平台脆弱点。
9. `lib/app_state.dart` 审计结论：Rust 桥初始化失败时**不注入数据目录**，
   该次会话不载入也不保存任何设置（demo 模式）。**属既有行为**，非本批引入。影响低。
10. `AppearanceState.setThemeMode`（`lib/appearance.dart:249-254`）一次改动会写
    `appearance.json` **两次**（`_save()` 自身 + notifier 联动路径）。影响极低：幂等，只是多一次 IO。
11. `lib/ui/settings_page.dart:786` 的 `_transferCard` 监听整个 `AppState`
    （`Listenable.merge([a, AppState.instance])`，`:807-808`）——`AppState` 是通知最频繁的
    notifier，会带来多余的卡片重建。影响低：卡片很轻，暂无卡顿报告。

---

## 六、Windows 构建（本批实测证据）

- 命令：`build_windows.bat`（脚本自带 flutter / cargo 发现、codegen、`taskkill` 抢占）。
- 结果：**成功**。关键输出：
  - `[1/3] flutter_rust_bridge codegen...` → `Done!`
  - `[2/3] Compile Rust static lib (x86_64-pc-windows-msvc)...` → `Finished dev profile ... in 3.47s`
  - `[3/3] Flutter build...` → `√ Built build\windows\x64\runner\Release\rust_flutter_ui.exe`
  - `Windows build done.`（进程退出码 0）
- 产物：`build\windows\x64\runner\Release\rust_flutter_ui.exe`
  —— 大小 `104448` 字节，修改时间 `2026/10/15 2:44:21`。
- 构建后复跑 `flutter analyze` 仍为 `3 issues found.`，即 codegen 未引入新问题。
- **未做**：构建产物只验证到「编译并链接成功」。第三节那 4 条真机项**未**在本环境运行核对。

---

## 七、第二轮修复（针对用户 2026-10-15 的 5 条复测反馈）

用户复测原文：`修bug.md:16-20`。编号对应本文档第一节的第 1/3/4/5/12 条。

> 先更正我上一轮的一个**方法错误**：我曾用 UTF-8 直接搜 `app.so` 里的中文字串，
> 得出「构建里没有新代码」——**这是错的**。Dart AOT 里中文以 UTF-16 存放。
> 改用 UTF-16 并先用旧字串（`文件`/`打开`）校准后，正确结论是
> **Release 构建一直包含本批改动**。构建不是原因，是我的修改没解决。

### 1｜OSD 要再往下，别在聊天标题（对应第一节第 1 条）

- **根因（实测）**：原偏移只让开了自定义标题栏 38px，而聊天页头部
  （`lib/ui/chat_page.dart:323`，`minHeight: 56`）占据 38–94 区间，OSD 正好压在其上。
- **改法**：`lib/ui/osd_toast.dart:10` 新增 `_kPageHeaderHeight = 56.0`；
  `:161` 桌面偏移改为 `38 + 56 + 8`。安卓仍只留 8（无自定义标题栏）。
- **实测**：OSD 容器 `top = 102.0`（> 94），不再压聊天标题。

### 3｜PC 端过滤按钮仍「粗浅不一」（对应第一节第 3 条）

> **⚠️ 本节前两次结论都是错的，第三次才是对的。**
>
> **第一次错**：我用 UTF-8 搜 `app.so` 中文串，得出「构建里没有新代码」。
> Dart AOT 中文是 UTF-16，方法本身无效。
>
> **第二次错（更严重）**：我说「我三次测量都一致」。但 `flutter_test` 会**替换掉
> 真实字体**（等宽假字体，任何字重量出来都同宽），所以它在结构上不可能复现
> Windows 真实字体回退的差异。**不能据此下「一致」的结论。**
> 我还曾据一张**并未真正看到**的截图（本模型图片返回被系统过滤，我却据此描述）
> 改了按钮文字颜色 —— 那是编造，已撤回。

- **真因（用户裁定 + 代码级确认）**：用户复测说「**不止背景不背景，是字体，
  字体！！！！**」。Windows 上 M3 文本主题（`typography.blackRedmond` /
  `whiteRedmond`）把字体族定为 **`Segoe UI`**，而它**没有任何中文字形**（纯拉丁字体）。
  7 个按钮标签全是中文，只能由系统**逐字回退**挑字体 → 不同汉字可能落到不同字体、
  不同字面，观感参差。再叠加请求的 `w500` 在 Segoe UI 与微软雅黑里都不存在
  （雅黑只有 300/400/700），只能由引擎就近吸附。
- **改法**（`lib/main.dart`）：
  - 新增 `_cjkFontFallback`：雅黑 UI → 雅黑 → 苹方 → Noto → 思源 → 黑体；
  - `ThemeData(fontFamilyFallback:)` 覆盖全应用中文本
    （`theme_data.dart:502-505` 会 apply 到 `defaultTextTheme`）；
  - **必须同时写进 `chipTheme.labelStyle` 与 `secondaryLabelStyle`**：
    chip 样式非空时按 `chip.dart:1357` 的 `??` **整体取代** M3 默认样式，
    主题层的回退栈管不到 chip。**漏这一处等于没修**。
- **护栏**（`test/chip_weight_uniform_test.dart` 新增 2 条 + 加固 2 条）：
  ① 主题层两条 chip 样式都带回退栈；② 应用级 `textTheme` 也带；
  ③ **渲染树**里每个 chip 的段落样式都带回退栈（主题层有值 ≠ 渲染用上，
  `chip.dart:1365` 的 `merge` 在 `other.inherit == false` 时整体返回 other）。
  **判别性验证（RED→GREEN）**：临时删掉 `labelStyle` 的回退栈后
  `Expected: not null / Actual: <null>` 变红，恢复后转绿 —— 不是空洞绿。
- **撤回**：选中项文字色已改回 `onSecondaryContainer`（原 M3 语义），
  未选中仍为 `onSurfaceVariant`。颜色不是用户指的问题。

### 4｜文件卡片选中不跟手（对应第一节第 4 条）

- **真因（实测）**：瓦片与列表行**同时注册 `onTap` 与 `onDoubleTap`**。Flutter 的 tap
  识别器只要同节点存在 `onDoubleTap`，就必须等双击窗口（约 300ms）才能判定单击 ——
  实测「按下后 50ms 未选中、450ms 才选中」。上一轮只搬走了 `statSync` 磁盘 IO，
  **没动这个手势冲突**，所以用户「没区别」。
- **改法**：`lib/ui/files_page.dart` 桌面端改用 `Listener.onPointerDown`
  （裸指针事件不参与手势竞技场，按下即选中），双击仍由 `GestureDetector` 负责打开。
  安卓端**不套这层**：安卓单击语义是「打开文件」，`pointerDown` 会在长按之前先触发
  而误开文件（该回归被 `test/file_menu_open_wiring_test.dart` 抓到过），改为直接
  **不注册 `onDoubleTap`**（触屏本无双击概念），单击即生效。
- **实测**：桌面 50ms 已选中。

### 5｜「打开方式」完全没有实现、毫无变化（对应第一节第 5 条）

- **真因（文档级确定）**：安卓侧原先用 `Intent.createChooser(...)` 包了一层。
  **`createChooser` 是一次性选择器，系统刻意不显示「仅一次 / 始终」**；那组按钮
  只属于**隐式 intent 的系统 Resolver**。所以安卓上永远看不到 → 正是「毫无变化」。
- **改法**：`android/app/src/main/kotlin/com/yuchuan/app/MainActivity.kt` 的
  `openFileWithChooser` 去掉 `createChooser`，直接 `startActivity(隐式 ACTION_VIEW)`，
  并在 `resolveActivity == null` 时回 `NO_HANDLER`。
- **Windows 侧实测无需改**：`rundll32 shell32.dll,OpenAs_RunDLL <path>` 对话框
  **能正常弹出**（进程存活、等待用户操作），含空格路径也正常。

### 12｜气泡勾选/取消不跟手（对应第一节第 12 条）

- **真因**：与第 4 条同源 —— 气泡同节点注册了 `onDoubleTap`（双击复制文字），
  把单击勾选压后到双击窗口。
- **改法**：`lib/ui/chat_page.dart` 的 `onDoubleTap` 在**多选态下整路注销**
  （`selecting == true` 时双击本无意义）。
- **实测**：50ms 即完成勾选/取消。

### 本轮验证（实测输出）

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | `3 issues found.`（与既有基线一致，无新增） |
| `flutter test` | `00:19 +99: All tests passed!` |
| Windows Release 重建 | 成功；`app.so` `10-15 04:45:27`、exe `10-15 04:45:31` |
| 产物自检 | 新字符串（UTF-16）均在重建后的 `app.so` 中命中 |
| 临时探针 | 全部已删除，`test/` 无 `zz_*` 残留 |
