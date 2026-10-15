import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:rust_flutter_ui/src/rust/api/simple.dart' as rust_simple;
import 'package:rust_flutter_ui/src/rust/frb_generated.dart';
import 'package:window_manager/window_manager.dart';

import 'appearance.dart';
import 'app_state.dart';
import 'services/platform_channel.dart';
import 'services/single_instance.dart';
import 'ui/chat_list.dart';
import 'ui/device_icons.dart';
import 'ui/chat_page.dart';
import 'ui/discovery.dart';
import 'ui/files_page.dart';
import 'ui/onboarding_page.dart';
import 'ui/osd_toast.dart';
import 'ui/pairing_dialog.dart';
import 'ui/settings_page.dart';
import 'ui/title_bar.dart';
import 'services/transfer_service.dart';

/// Set in main() after probing the Rust bridge.
bool rustBridgeOk = false;
/// Init failure detail (diagnostics).
String rustBridgeError = '';

Future<void> main([List<String> args = const []]) async {
  WidgetsFlutterBinding.ensureInitialized();
  // 启动参数（资源管理器右键传入的文件等）由 runner 的
  // set_dart_entrypoint_arguments 投递到 main 入口。
  // Platform.executableArguments 只有 VM 标志位，读不到文件 —— 踩过坑。
  AppState.launchArgs = args;
  // Windows 尽力交接：右键菜单拉起的进程先问运行中的实例要不要接手
  // 文件清单，接手成功就退出 —— 不做强制单实例，连不上就照常启动。
  // 放在最前面：成功时跳过窗口/桥初始化，退出得干净利落。
  if (Platform.isWindows) {
    final files =
        args.where((a) => !a.startsWith('-') && File(a).existsSync()).toList();
    SingleInstance.log('boot entrypoint=$args files=$files');
    if (files.isNotEmpty &&
        await SingleInstance.handoffToRunningInstance(files)) {
      exit(0);
    }
  }
  // Windows/Linux 无边框窗口：先配好样式，但**不要在首帧前 show()**
  // —— 过早 show 会让窗口停在白色首帧不更新（本机踩过）。
  final isDesktop = Platform.isWindows || Platform.isLinux;
  if (isDesktop) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow();
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden,
        windowButtonVisibility: false);
    await windowManager.setMinimumSize(const Size(960, 640));
  }
  // 任何 UI 构建异常写文件，避免 release 白屏无从排查
  FlutterError.onError = (details) {
    final buf = StringBuffer()
      ..writeln('=== FlutterError ===')
      ..writeln(details.exception)
      ..writeln(details.stack);
    try {
      final dir = Platform.environment['TEMP'] ?? '.';
      File('$dir\\yuchuan_ui_error.txt')
          .writeAsStringSync(buf.toString(), mode: FileMode.append);
    } catch (_) {}
    FlutterError.presentError(details);
  };
  try {
    await RustLib.init(externalLibrary: _externalLibrary());
    rustBridgeOk = true;
  } catch (e, st) {
    // Demo UI keeps working without the bridge (M1 wires the real backend).
    rustBridgeOk = false;
    rustBridgeError = '$e\n$st';
  }
  _writeStartupDiag();
  if (rustBridgeOk) {
    // T1.3 真实发现：先订阅事件流再启动 Rust UDP 服务；失败只影响设备页
    final state = AppState.instance;
    state.enableBackend();
    // T2.2 配对表：先载入联系人，重启后「已配对」与联系人列表立刻正确。
    // 载入同时会注入数据目录（外观 + prefs.json）——「记住主题深浅」靠这一步，
    // 所以必须**等它载完**再把落盘值灌进 themeModeNotifier：先灌 notifier 会触发
    // _syncSystemBarStyle → setDarkLook → _save，把刚载入的模式又按 system 写回去。
    unawaited(state.loadPairingStore().then((_) => applyLoadedThemeMode()));
    // T3.1/T3.3 聊天链路：开消息仓库 + 监听端口 + 订阅事件（失败不影响发现/配对）
    //
    // 收件目录必须等 messages_open 注册完 DOWNLOAD_ROOT 之后再预热：
    // 在它之前调 transfer_download_dir() 拿到的是 Rust 侧的系统临时目录兜底值，
    // 一旦被缓存，收件目录查找 / 文件 TAB / 「打开文件」全都指向错地方。
    unawaited(state.enableChat().then((_) {
      return TransferService.instance.warmDownloadDir();
    }));
    // 任务8：默认**不**开启发现 —— 只解析本机身份，需要找设备时在设备页手动开始
    unawaited(state.prepareIdentity().then((_) {
      _appendDiscoveryDiag();
      // T5.5：数据目录就绪后检查首次引导标记
      unawaited(state.checkOnboarding());
    }));
    // 任务13：配对操作窗口由 PairingDialogHost 状态驱动（双端各一个）
    // 三次采样（6s/12s/25s），便于自动化验证「双实例互见 + 对端下线 10s 内摘除」；
    // 只写 %TEMP% 诊断文件，不影响主流程。
    for (final seconds in const [6, 12, 25]) {
      Timer(Duration(seconds: seconds), _appendDiscoveryDiag);
    }
  }
  // Windows：起单实例控制服务，接收其他进程右键分享交接来的文件
  if (Platform.isWindows) {
    SingleInstance.log('startControlServer requested');
    unawaited(SingleInstance.startControlServer(
        onShare: AppState.instance.injectShared));
  }
  runApp(const YuChuanApp());
  // 主题/系统亮度变化 → 同步深浅色各自的外观参数（双端都要）
  themeModeNotifier.addListener(_syncSystemBarStyle);
  _syncSystemBarStyle();
  // Android：全面屏（内容铺到系统栏后面 + 系统栏透明）+ 图标深浅跟随主题
  if (Platform.isAndroid) {
    // 任务18：切后台不断连 —— 高性能 Wi-Fi 锁交给原生层持有
    unawaited(YuChuanPlatform.acquireWifiLock());
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.dark,
    ));
    WidgetsBinding.instance.platformDispatcher.onPlatformBrightnessChanged =
        _syncSystemBarStyle;
  }
  // 首帧渲染后再设置尺寸/居中/显示，避免白屏
  if (isDesktop) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await windowManager.setSize(const Size(1180, 780));
      await windowManager.center();
      await windowManager.show();
      await windowManager.focus();
    });
  }
}

/// T1.3 诊断：把发现服务真实端口 / 组播状态 / 邻居数追加到启动诊断文件，
/// 供自动化验证读取（GUI 截图在多会话下不可靠）。
void _appendDiscoveryDiag() {
  final state = AppState.instance;
  _writeDiag(
    'discovery=${state.discoveryStatusText}\n'
    'discovery_live=${state.liveDiscovery}\n'
    'discovery_multicast=${state.discoveryMulticast}\n'
    'discovery_self=${state.localDeviceName}#${state.localDeviceIdShort}\n'
    'discovery_addrs=${state.localAddresses.join(',')}\n'
    'discovery_ifaces=${state.localInterfaces.join('|')}\n'
    'discovery_hellos=${state.hellosSent}/${state.hellosReceived}\n'
    'discovery_devices=${state.devices.map((d) => '${d.name}@${d.ip}').join(',')}\n'
    'pairing_contacts=${state.pairedContacts.length}\n'
    'pairing_names=${state.pairedContacts.map((c) => c.name).join(',')}\n'
    'pairing_store=${state.pairingStorePath}\n'
    'chat_ready=${state.chatReady}\n'
    'chat_port=${state.chatPort}\n'
    'chat_conversations=${state.conversations.length}\n'
    'chat_messages=${state.conversations.map((c) => '${c.device.name}:${c.messages.length}').join(',')}\n'
    'chat_error=${state.chatError}\n',
    FileMode.append,
  );
}

/// Windows: frb 默认 ioDirectory 相对 CWD（`rust_builder/target/release/`），
/// 会命中陈旧的手动构建产物导致 content-hash 不匹配 —— 显式加载 exe 旁边的
/// cargokit 打包 DLL，任意工作目录下行为一致。Android 走系统加载
/// `librust_flutter_ui_native.so`，用默认逻辑即可。
ExternalLibrary? _externalLibrary() {
  if (!Platform.isWindows) return null;
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  return ExternalLibrary.open('$exeDir\\rust_flutter_ui_native.dll');
}

/// T0.2 启动诊断：把桥接探测结果写到 %TEMP%，供自动化/真机验证读取。
/// （Windows 上其他会话可能抢占前台，截图不可靠，文件证据不受影响）
void _writeStartupDiag() {
  final ping = rustBridgeOk ? rust_simple.pingPlatform() : 'bridge-not-ready';
  _writeDiag(
    'app=雨传 YuChuan v1.0.0\n'
    'time=${DateTime.now().toIso8601String()}\n'
    'bridge=${rustBridgeOk ? 'ok' : 'failed'}\n'
    'rust_platform=$ping\n'
    'frb=2.8.0\n'
    'pid=$pid\n'
    'error=${rustBridgeError.replaceAll('\n', ' | ')}\n',
    FileMode.write,
  );
}

/// 写诊断文件：固定名（最后一次写入者胜出）+ 按 pid 区分（同机多实例联调）。
void _writeDiag(String text, FileMode mode) {
  try {
    final dir =
        Platform.environment['TEMP'] ?? Platform.environment['TMP'] ?? '.';
    for (final path in [
      '$dir\\yuchuan_startup_diag.txt',
      '$dir\\yuchuan_startup_diag_$pid.txt',
    ]) {
      File(path).writeAsStringSync(text, mode: mode);
    }
  } catch (_) {
    // Diagnostics must never crash the app.
  }
}

/// 由 AppearanceState 载入落盘值后调用一次，把显示模式灌进 UI。
///
/// 幂等：`_load()` 里已经同步过 notifier，这里值相同时 ValueNotifier 不重复通知。
void applyLoadedThemeMode() {
  themeModeNotifier.value = AppearanceState.instance.themeMode;
}

/// Android：让系统栏（状态栏/导航栏）图标深浅跟随明暗主题。
void _syncSystemBarStyle() {
  final mode = themeModeNotifier.value;
  final brightness = mode == ThemeMode.system
      ? PlatformDispatcher.instance.platformBrightness
      : (mode == ThemeMode.dark ? Brightness.dark : Brightness.light);
  // 深浅色各自的壁纸/主题色参数独立记忆（双端都要，不只安卓）
  AppearanceState.instance.setDarkLook(brightness == Brightness.dark);
  if (Platform.isAndroid) {
    // 深色主题（亮背景）→ 系统栏图标用深色（isLight=true）；浅色主题反之
    YuChuanPlatform.setSystemBarsLight(brightness == Brightness.light);
  }
}

class YuChuanApp extends StatelessWidget {
  const YuChuanApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 配对操作窗口宿主（状态驱动，双端全程只弹一个）
    return PairingDialogHost(
      child: ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) {
        // 注意：这里在 MaterialApp 上方，没有 MediaQuery 祖先，
        // 用 platformDispatcher 判断系统亮度（用 MediaQuery 会抛异常 → 整屏白）。
        final isLight = mode == ThemeMode.light ||
            (mode == ThemeMode.system &&
                View.of(context).platformDispatcher.platformBrightness ==
                    Brightness.light);
        return ListenableBuilder(
          listenable: AppearanceState.instance,
          builder: (context, _) {
            return MaterialApp(
              title: '雨传 YuChuan',
              navigatorKey: appNavigatorKey,
              debugShowCheckedModeBanner: false,
              theme: buildAppTheme(Brightness.light),
              darkTheme: buildAppTheme(Brightness.dark),
              themeMode: mode,
              // 壁纸背景铺满整个窗口（含标题栏区域）
              builder: (context, child) => Stack(
                children: [
                  Positioned.fill(
                    child: WallpaperBackground(isLight: isLight),
                  ),
                  if (child != null)
                    // 设置里可调的全局字号（不影响系统字体大小）
                    MediaQuery(
                      data: MediaQuery.of(context).copyWith(
                        textScaler:
                            TextScaler.linear(AppearanceState.instance.textScale),
                      ),
                      child: child,
                    ),
                ],
              ),
              home: const Shell(),
            );
          },
        );
      },
      ),
    );
  }
}

/// 中文字体回退栈。
///
/// Windows 上 M3 文本主题把字体族定为 `Segoe UI`，而它**没有任何中文字形**
/// （纯拉丁字体）。中文只能由系统**逐字回退**去挑字体：不同汉字可能落到不同
/// 字体，字面（笔画粗细/字形）参差不齐 —— 用户反馈的「过滤按钮几个基本都不同、
/// 是字体」就是这个。
///
/// 显式给出中文字体栈后，所有中文一律走同一字体，字形与字重才可能真正统一。
/// 拉丁字母/数字仍走 `fontFamily`（Segoe UI），不受影响。
///
/// 顺序按平台可用性排列，取第一个装了的：
/// Windows(微软雅黑 UI → 微软雅黑) / macOS(苹方) / Linux(Noto、思源)。
const List<String> _cjkFontFallback = <String>[
  'Microsoft YaHei UI',
  'Microsoft YaHei',
  'PingFang SC',
  'Noto Sans CJK SC',
  'Source Han Sans SC',
  'SimHei',
];

ThemeData buildAppTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppearanceState.instance.seedColor,
    brightness: brightness,
  );
  final isLight = brightness == Brightness.light;
  // 过滤按钮标签样式的「基线」：字体族/颜色来自平台明暗文本主题，几何（字号、
  // 字重、字距、行高）来自 M3 文种文本主题 —— 两者合并后即框架本地化后真正
  // 生效的 labelLarge，也就是 M3 chip 默认样式（`labelLarge` + 按状态换色）的底。
  final typography = Typography.material2021(
    platform: defaultTargetPlatform,
    colorScheme: scheme,
  );
  // ponytail: 几何固定取 englishLike；M3 2021 的 englishLike/dense/tall 三档
  // labelLarge 数值实测完全相同，故不按 locale 区分文种。若将来三者分化，
  // 这里需要改为按当前 locale 的 ScriptCategory 取值。
  final chipLabelBase = typography.englishLike.labelLarge!
      .merge((isLight ? typography.black : typography.white).labelLarge!);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    // 中文统一走 _cjkFontFallback：Windows 默认的 Segoe UI 无中文字形，
    // 不显式给栈就只能逐字回退，字面参差（见 _cjkFontFallback 注释）。
    fontFamilyFallback: _cjkFontFallback,
    // 壁纸模式下让背景透明，透出底下铺的壁纸
    scaffoldBackgroundColor: AppearanceState.instance.hasWallpaper
        ? Colors.transparent
        : (isLight ? const Color(0xFFF3F4F8) : const Color(0xFF101116)),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      // 壁纸模式下卡片半透明，透出背景
      color: AppearanceState.instance.hasWallpaper
          ? (isLight
              ? Colors.white.withValues(alpha: 0.72)
              : Colors.black.withValues(alpha: 0.42))
          : (isLight ? Colors.white : const Color(0xFF1A1B22)),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: isLight
              ? Colors.black.withValues(alpha: 0.06)
              : Colors.white.withValues(alpha: 0.06),
        ),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: scheme.onSurface,
      titleTextStyle: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: scheme.onSurface,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      isDense: true,
      hintStyle: TextStyle(color: scheme.outline, fontSize: 13.5),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: scheme.primary, width: 1.3),
      ),
    ),
    chipTheme: ChipThemeData(
      // 文件 TAB 的过滤按钮字重必须「各个都一样」。
      //
      // 这里的样式是「整体取代」而不是「叠加」：Flutter 按
      // `chipTheme.labelStyle ?? chipDefaults.labelStyle!`（chip.dart）取值，
      // 只要它非空，Material 3 的按状态默认样式就再也不会被查询 ——
      // 而那份默认样式一并携带了颜色、字体族、letterSpacing 与行高。
      // 所以钉字重字号时必须把颜色与几何一起写回来：只钉字重会让未选中按钮
      // 丢掉 onSurfaceVariant（实测 color 变 null），浅色下即白字白底、看不见；
      // 几何也从 labelLarge 取，避免字体族/字距/行高退化成 null。
      //
      // ChoiceChip 的标签样式有两条独立来源：未选中读 labelStyle，选中读
      // secondaryLabelStyle（choice_chip.dart）。任一条被单独覆盖，两者就会分叉。
      // 两条都显式钉成同值，才能保证这 7 个按钮彼此统一且不依赖 M3 实现细节。
      //
      // **中文必须显式给回退栈**：`chipTheme.labelStyle` 非空时会**整体取代**
      // M3 默认样式（含 ThemeData 层的 fontFamilyFallback），而基线样式来自
      // `typography.black/white`（Windows = Segoe UI），其 fontFamilyFallback 为
      // null。不给栈，中文就只能由系统逐字回退挑字体，字面参差 —— 用户裁定
      // 「是字体，字体！！！」正指此处。拉丁字母仍走 Segoe UI。
      labelStyle: chipLabelBase.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: scheme.onSurfaceVariant,
        fontFamilyFallback: _cjkFontFallback,
      ),
      secondaryLabelStyle: chipLabelBase.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: scheme.onSecondaryContainer,
        fontFamilyFallback: _cjkFontFallback,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      side: BorderSide.none,
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: 0.4),
      thickness: 1,
    ),
  );
}

// ============================================================
// Shell: nav rail + list panel + content area
// ============================================================

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with WidgetsBindingObserver {
  Timer? _shareBootTimer;
  bool _shareFlowBusy = false;
  int _seenShareSeq = 0;

  /// 进入后台的时刻。回前台时用它算「离开了多久」，决定要不要做掉线自愈：
  /// 只有离开时间 ≥ 对端判超时的阈值，对端才可能已经把我断开（B1-4）。
  DateTime? _backgroundedAt;

  final state = AppState.instance;

  /// OSD 去重游标：上一次已转成 OSD 的横幅文案、已提示过的消息序号。
  String _lastOsdChatError = '';
  int _lastOsdNoticeSeq = 0;

  @override
  void initState() {
    super.initState();
    state.addListener(_onState);
    // 其他应用分享进来：启动时取一次（安卓）。
    // 记住 timer 并在 dispose 里取消 —— 不然测试结束时还挂着 pending timer。
    WidgetsBinding.instance.addObserver(this);
    _shareBootTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) _consumeShare();
    });
  }

  @override
  void dispose() {
    _shareBootTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    state.removeListener(_onState);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    // 从后台回前台也可能带新的分享（singleTop 走 onNewIntent）
    if (s == AppLifecycleState.resumed) {
      _consumeShare();
      // 回前台状态自愈：只有**确实离开了足够久**（对端可能已判我超时断开）
      // 才清在线标记重拨。以前无条件清 —— PC 只是从最小化恢复、连接根本没断
      // 也会清，于是冒出「与 X 的连接已断开，正在自动重连…」的假提示（B1-4）。
      final backgroundFor = _backgroundedAt == null
          ? null
          : DateTime.now().difference(_backgroundedAt!);
      _backgroundedAt = null;
      unawaited(state.onAppResumed(backgroundFor: backgroundFor));
    } else if (s == AppLifecycleState.paused) {
      _backgroundedAt = DateTime.now();
      // 切后台：若还有活干，拉起前台服务保住 Wi-Fi/组播/CPU 锁（Task 7/10）
      unawaited(state.refreshKeepAlive());
    }
  }

  /// 取走待处理的分享并弹联系人选择；没有内容时静默返回。
  Future<void> _consumeShare() async {
    // 重入闸：800ms timer / resumed / 单实例交接注入可能并发触发，
    // 选人面板只能弹一个
    if (_shareFlowBusy) return;
    _shareFlowBusy = true;
    try {
      await _consumeShareInner();
    } finally {
      _shareFlowBusy = false;
    }
  }

  Future<void> _consumeShareInner() async {
    // Windows 资源管理器右键传来的文件（启动参数）优先
    var got = state.consumeLaunchArgs();
    if (!got) got = await state.consumeShared();
    // 单实例交接注入的分享：pending 已被填好，没有可「消费」的动作
    if (!got) {
      got = state.pendingShareFiles.isNotEmpty ||
          state.pendingShareText.isNotEmpty;
    }
    if (!got || !mounted) return;
    // 冷启动时 resumed 常早于 enableChat 完成（会话列表还没组装、chatReady
    // 还是 false）：轮询等就绪再弹选择器，别把分享静默丢掉 —— 之前 contacts
    // 为空直接 dismiss，表现为「分享只把应用拉起来，不弹选人」。
    var attempts = 0;
    while (mounted &&
        attempts < 10 &&
        (!state.chatReady || state.conversations.isEmpty)) {
      attempts++;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    if (!mounted) return;
    final contacts = state.conversations.map((c) => c.device).toList();
    if (!state.chatReady || contacts.isEmpty) {
      state.dismissPendingShare();
      state.setChatError('分享未发送：聊天未就绪或还没有可发送的联系人（先配对一台设备）');
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
                child: Text('分享到',
                    style: TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w700)),
              ),
            ),
            for (final d in contacts)
              ListTile(
                title: Text(d.displayName),
                subtitle: Text(d.online ? '在线' : '离线'),
                onTap: () => Navigator.pop(sheetContext, d.id),
              ),
          ],
        ),
      ),
    );
    if (id == null) {
      state.dismissPendingShare();
      return;
    }
    await state.sendPendingShare(id);
    state.openConversationWith(id);
  }

  void _onState() {
    if (mounted) setState(() {});
    // 单实例交接：别的进程把分享递进来了 → 走与系统分享相同的选人流程
    if (state.shareSeq != _seenShareSeq) {
      _seenShareSeq = state.shareSeq;
      _consumeShare();
    }
    // 通知桥接放最后：setState 之后再读 state，context 也已可用
    _bridgeNotificationsToOsd();
  }

  /// 把原先走顶部横幅的两类事件转成 OSD 胶囊（用户要求：所有通知走 OSD）。
  ///
  /// 这里**只发通知，不动状态**：
  ///   - `chatError` 是常驻的**诊断状态**（`chat_page` / `settings_page` 的内联
  ///     诊断、`main.dart` diag 采样的 `chat_error=` 都在读它），OSD 只是瞬时
  ///     **通知**。从桥里清掉它会让那两处永远回落成「聊天链路启动中…」、diag
  ///     永远空串 —— 错误只剩 2 秒可见。
  ///   - 去重游标靠「条件恢复」（app 在聊天成功启动 / 发送成功时自行把
  ///     `chatError` 置空）复位，所以同一条错误在条件未恢复前连发不会刷屏，
  ///     恢复后再出现仍能弹。
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
    // ② 新消息：只有不在该会话里才提示（沿用设置里的同一个开关）。
    // 开关关闭也算「消费」：游标照样前进，否则用户事后打开开关时，
    // 这条早已过期的提醒会被当成新鲜消息补弹出来。
    if (s.noticeSeq != _lastOsdNoticeSeq) {
      _lastOsdNoticeSeq = s.noticeSeq;
      if (AppearanceState.instance.noticeBannerEnabled &&
          s.noticePeerId != null) {
        OsdToast.info(context, '${s.noticeName ?? ''}：${s.noticeText ?? ''}');
      }
    }
  }

  /// 安卓返回手势/键的栈：详情页 → 列表 → 消息 TAB → 最后才退出应用。
  ///（之前没有这层，返回直接把整个应用退到桌面。）
  void _handleBack({required bool isDeepDetail}) {
    final state = AppState.instance;
    // ① 当前页面自己的返回逻辑（文件页取消选中 / 设置页回总览 / 聊天页退出多选）
    if (state.backHandler?.call() ?? false) return;
    // ② 深层详情 → 列表
    if (isDeepDetail) {
      state.backToListPanel();
      return;
    }
    if (state.navIndex != 0) {
      state.setNavIndex(0);
      return;
    }
    SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 900;

    // 注意：这些子树都读 AppState，**不要**写成 const —— Shell 重建时若传入
    // identical 的 const widget，Flutter 会跳过该子树的重建，UI 就会「卡在旧数据」
    // （曾导致应答方的 PIN 卡片不显示、设备列表要切页面才刷新）。

    // 全屏首次使用引导（覆盖整个窗口，不叠在内容上）。
    if (state.onboardingActive) {
      return Scaffold(
        body: OnboardingPage(
          onDone: state.dismissOnboarding,
        ),
      );
    }

    Widget panel;
    if (state.navIndex == 0) {
      panel = ChatListPanel();
    } else if (state.navIndex == 1) {
      panel = DiscoveryPanel();
    } else if (state.navIndex == 2) {
      // 联系人 TAB 已并入「消息」：配对成功的联系人直接出现在会话列表里
      panel = ChatListPanel();
    } else {
      panel = const SizedBox.shrink();
    }

    // 深层详情：进入某个会话或设备详情。移动端在此隐藏底部 TAB、全屏展示
    // （详情页自带返回按钮）。
    // 注意：选中项必须**真的解析到一个存在的会话/设备**才算深层详情。首次
    // 启动时后端会用真实会话列表重建（真机上为空），而构造函数里「恢复上次
    // 会话」留下的索引可能已经越界 —— 若仍按「已进入详情」处理，窄屏会隐藏
    // 底部 TAB 并渲染空内容：安卓端点完引导就停在一张哪儿都去不了的空白页。
    final convIndex = state.selectedConversation;
    final deviceIndex = state.selectedDevice;
    final isDeepDetail =
        (convIndex != null && convIndex < state.conversations.length) ||
            (state.contentTarget == ContentTarget.discover &&
                deviceIndex != null &&
                deviceIndex < state.devices.length);

    // -------- 移动端 / 窄屏：底部 TAB 导航 --------
    if (!wide) {
      // 顶层（列表）保留底部 TAB；文件(3)/设置(4)/深层详情全屏。
      final showFullContent = isDeepDetail ||
          state.navIndex == 3 ||
          state.navIndex == 4 ||
          state.contentTarget == ContentTarget.settings;
      // 全面屏：内容不要被状态栏压住（安卓内容延伸到系统栏后面）。
      return PopScope(
        // 返回手势/键先走应用内栈：详情 → 列表 → 消息 TAB → 才退出应用
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          _handleBack(isDeepDetail: isDeepDetail);
        },
        child: Scaffold(
          bottomNavigationBar: isDeepDetail ? null : BottomNavBar(),
          body: SafeArea(
            top: Platform.isAndroid,
            bottom: false,
            child: Column(
              children: [
                const AppTitleBar(title: '雨传 YuChuan'),
                Expanded(
                    child: _withBanner(
                        showFullContent ? _buildContent() : panel)),
              ],
            ),
          ),
        ),
      );
    }

    // -------- 桌面 / 宽屏：侧边 NavigationRail --------
    return Scaffold(
      body: Column(
        children: [
          const AppTitleBar(title: '雨传 YuChuan'),
          Expanded(
            child: _withBanner(
              Row(
                children: [
                  NavRail(),
                  const VerticalDivider(width: 1, thickness: 1),
                  if (state.navIndex != 3 && state.navIndex != 4) ...[
                    SizedBox(width: 320, child: panel),
                    const VerticalDivider(width: 1, thickness: 1),
                  ],
                  Expanded(child: _buildContent()),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 顶部横幅已按用户要求删除：所有通知统一走 OSD（Overlay 胶囊）。
  Widget _withBanner(Widget body) => body;

  Widget _buildContent() {
    if (state.navIndex == 4 ||
        state.contentTarget == ContentTarget.settings) {
      return SettingsPage();
    }
    if (state.navIndex == 3) {
      return FilesPage();
    }
    if (state.contentTarget == ContentTarget.discover) {
      if (state.selectedDevice == null) {
        return const EmptyHint(
          icon: Icons.devices_other,
          title: '选择一台设备',
          subtitle: '在左侧列表中点击设备查看详情或发起配对',
        );
      }
      return DeviceDetailView();
    }
    final ci = state.selectedConversation;
    if (ci != null && ci < state.conversations.length) {
      // 传 peerId 而不是 Conversation 对象：会话列表会重排/重建，
      // 按 id 取实例可以避免页面拿到过期对象
      return ChatPage(peerId: state.conversations[ci].device.id);
    }
    if (state.navIndex == 2) {
      return const EmptyHint(
        icon: Icons.contact_mail_outlined,
        title: '还没有会话',
        subtitle: '选择左侧联系人开始聊天，或到「设备」页配对新设备',
      );
    }
    return const EmptyHint(
      icon: Icons.chat_bubble_outline,
      title: '选择一个会话',
      subtitle: '左侧点击任意聊天开始，或到「设备」页发现新设备',
    );
  }
}

class EmptyHint extends StatelessWidget {
  const EmptyHint({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 40, color: scheme.primary),
          ),
          const SizedBox(height: 18),
          Text(title,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: scheme.outline),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// Navigation rail
// ============================================================

class NavRail extends StatelessWidget {
  const NavRail({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final scheme = Theme.of(context).colorScheme;
    final unread = state.totalUnread;

    Widget item(int index, IconData icon, String label, {bool dot = false}) {
      final selected = state.navIndex == index;
      return _NavItem(
        selected: selected,
        icon: icon,
        label: label,
        showDot: dot,
        onTap: () => state.setNavIndex(index),
      );
    }

    return SizedBox(
      width: 76,
      child: Column(
        children: [
          const SizedBox(height: 14),
          // 本机头像：手绘的 PC/手机图标（不要再用 ME 文字）
          const MyDeviceAvatar(size: 44),
          const SizedBox(height: 18),
          item(0, Icons.chat_bubble_outline, '消息', dot: unread > 0),
          item(1, Icons.devices, '设备'),
          item(3, Icons.folder_outlined, '文件'),
          item(4, Icons.settings_outlined, '设置'),
          const Spacer(),
          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeModeNotifier,
            builder: (context, mode, _) {
              final dark = mode == ThemeMode.dark ||
                  (mode == ThemeMode.system &&
                      Theme.of(context).brightness == Brightness.dark);
              return IconButton(
                tooltip: dark ? '切换浅色' : '切换深色',
                icon: Icon(
                  dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
                  size: 21,
                ),
                color: scheme.outline,
                onPressed: () {
                  // 走持久化 setter：直接改 notifier 不会落盘，重启就丢
                  AppearanceState.instance.setThemeMode(
                      dark ? ThemeMode.light : ThemeMode.dark);
                },
              );
            },
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.selected,
    required this.icon,
    required this.label,
    required this.onTap,
    required this.showDot,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool showDot;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 未选中用 onSurfaceVariant：scheme.outline 在深色主题下太淡看不清
    final fg = widget.selected
        ? scheme.primary
        : hovered
            ? scheme.onSurface
            : scheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: MouseRegion(
        onEnter: (_) => setState(() => hovered = true),
        onExit: (_) => setState(() => hovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 64,
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: widget.selected
                  ? scheme.primary.withValues(alpha: 0.10)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Badge(
                  backgroundColor: const Color(0xFFEF4444),
                  label: const SizedBox.shrink(),
                  isLabelVisible: widget.showDot,
                  smallSize: 8,
                  child: Icon(widget.icon, size: 23, color: fg),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight:
                        widget.selected ? FontWeight.w700 : FontWeight.w500,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// Bottom navigation bar (Android / narrow screens)
// ============================================================

/// 底部 TAB 导航（移动端）。选中态三重区分：胶囊底 + 主题色实心图标 + 加粗标签，
/// 外加未读数角标 —— 保证「选中的 TAB 要有区分」在任何主题下都清晰可见。
class BottomNavBar extends StatelessWidget {
  const BottomNavBar({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final scheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              // 注意：**绝不能写成 const** —— const 子树在父级重建时若参数
              // 完全相同会被 Flutter 跳过，而选中态是靠 build 时读 AppState
              // 得出的 → 选中样式永远不刷新（这就是「安卓选中 TAB 没样式」
              // 反复出现的根因）。选中态一律由父级显式传参。
              _BottomItem(
                index: 0,
                icon: Icons.chat_bubble_outline,
                selectedIcon: Icons.chat_bubble,
                label: '消息',
                count: state.totalUnread,
                selected: state.navIndex == 0,
              ),
              _BottomItem(
                index: 1,
                icon: Icons.devices_other,
                selectedIcon: Icons.devices,
                label: '设备',
                selected: state.navIndex == 1,
              ),
              _BottomItem(
                index: 3,
                icon: Icons.folder_outlined,
                selectedIcon: Icons.folder,
                label: '文件',
                selected: state.navIndex == 3,
              ),
              _BottomItem(
                index: 4,
                icon: Icons.settings_outlined,
                selectedIcon: Icons.settings,
                label: '设置',
                selected: state.navIndex == 4,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomItem extends StatelessWidget {
  const _BottomItem({
    required this.index,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    this.count = 0,
  });

  final int index;
  final IconData icon;
  final IconData selectedIcon;
  final String label;

  /// 选中态由父级显式传入（不要在这里读全局状态：const 子树会被跳过重建）。
  final bool selected;

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 未选中也要够清楚：用 onSurfaceVariant（深浅主题都比 outline 显眼）
    final fg = selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;

    return Expanded(
      child: InkWell(
        onTap: () => AppState.instance.setNavIndex(index),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 选中态：主题色实心胶囊 + 主色图标/加粗标签，任何主题下都一眼可辨
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              width: selected ? 58 : 46,
              height: 30,
              decoration: BoxDecoration(
                color: selected
                    ? scheme.primaryContainer
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: selected
                      ? scheme.primary.withValues(alpha: 0.35)
                      : Colors.transparent,
                  width: 1,
                ),
              ),
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  Icon(
                    selected ? selectedIcon : icon,
                    size: 23,
                    color: fg,
                  ),
                  if (count > 0)
                    Positioned(
                      right: 8,
                      top: -1,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        constraints: const BoxConstraints(minWidth: 15),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEF4444),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          count > 99 ? '99+' : '$count',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9.5,
                            height: 1.2,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: fg,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
