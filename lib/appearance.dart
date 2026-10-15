import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageFilter, PlatformDispatcher, TileMode;

import 'package:flutter/material.dart';

/// 显示模式全局通知器（跟随系统 / 浅色 / 深色）。
///
/// 归属放在这里而不是 main.dart：它是**需要持久化**的状态，唯一写入口是
/// [AppearanceState.setThemeMode]；main.dart 只是消费方（MaterialApp.themeMode、
/// 系统栏图标深浅、NavRail 的明暗按钮都读它）。声明在 main.dart 会逼
/// appearance.dart 反向 import 入口文件，形成 import 环。
final ValueNotifier<ThemeMode> themeModeNotifier =
    ValueNotifier<ThemeMode>(ThemeMode.system);

/// 外观设置（主题色 + 壁纸 + 壁纸滤镜）。
///
/// 持久化到 `<数据目录>/appearance.json`；壁纸存绝对路径。
/// 滤镜语义：
/// - [blur] 壁纸高斯模糊半径（0 = 不模糊）
/// - [saturation] 壁纸饱和度倍率（0 = 灰度，1 = 原图，>1 = 更艳）
/// - [brightness] 壁纸亮度倍率（0 = 全黑，1 = 原图）
/// - [maskColor] / [maskOpacity] 壁纸上的遮罩（不透明度 0~1）
class AppearanceState extends ChangeNotifier {
  AppearanceState._();

  static final AppearanceState instance = AppearanceState._();

  /// 主题色（Material 3 seed）。
  Color seedColor = const Color(0xFF6366F1);

  /// 显示模式（跟随系统 / 浅色 / 深色）。用户要求：双端都要记住。
  ThemeMode themeMode = ThemeMode.system;

  /// 壁纸绝对路径；null = 纯色背景。
  String? wallpaperPath;

  /// 壁纸总开关：关闭即回到纯色背景（路径保留，可随时再打开）。
  bool wallpaperEnabled = true;

  // ----------------------------------------------------------
  // 界面（气泡/字号/动效）—— 设置 TAB「界面」分区
  // ----------------------------------------------------------

  /// 全局字号倍率（0.85 ~ 1.3）。
  double textScale = 1;

  /// 聊天气泡最大宽度（300 ~ 560）。
  double bubbleMaxWidth = 460;

  /// 聊天气泡圆角（4 ~ 24）。
  double bubbleRadius = 13;

  /// 入场/进度动画开关（关闭后立即到位，省电也更「跟手」）。
  bool animationsEnabled = true;

  /// 输入框最大行数（3 ~ 12，默认 8）。
  int inputMaxLines = 8;

  /// 壁纸不透明度（0.2 ~ 1，默认 1）。
  double wallpaperOpacity = 1;

  /// 弹出式菜单/卡片样式：true = 底部弹层，false = 就地弹出菜单。
  /// 默认就地弹出（用户指定）；设置里可切回底部卡片。
  bool useBottomSheetMenus = false;

  // ----------------------------------------------------------
  // 通知
  // ----------------------------------------------------------

  /// 新消息顶部横幅提醒（关掉后仍有未读角标）。
  bool noticeBannerEnabled = true;

  // ----------------------------------------------------------
  // 传输
  // ----------------------------------------------------------

  /// 自定义接收目录：null = 用默认（<数据目录>/chat/downloads）。
  String? receiveDir;

  /// 文件 TAB 视图：true = 网格，false = 列表（跨重启记住）。
  bool fileGridView = true;

  /// 输入区背景不透明度：1 = 完全不透明，越小越透（框外看到壁纸/背景）。
  double inputOpacity = 1;

  /// 聊天气泡不透明度（0.1 ~ 0.7，默认 0.35）。浅色/深色分别记忆。
  double bubbleOpacity = 0.35;

  /// 文件 TAB 排序键：name / size / time。
  String fileSort = 'time';

  /// 壁纸模糊半径。
  double blur = 0;

  /// 壁纸饱和度倍率。
  double saturation = 1;

  /// 壁纸亮度倍率。
  double brightness = 1;

  /// 遮罩颜色。
  Color maskColor = const Color(0xFF000000);

  /// 遮罩不透明度。
  double maskOpacity = 0;

  /// 数据目录（由 AppState 在解析后注入；注入即尝试载入）。
  String? _dataDir;

  /// 可选预设主题色（UI 里一排圆点）。
  static const presetColors = <Color>[
    Color(0xFF6366F1), // Indigo
    Color(0xFF8B5CF6), // Violet
    Color(0xFFEC4899), // Pink
    Color(0xFFF59E0B), // Amber
    Color(0xFF10B981), // Emerald
    Color(0xFF06B6D4), // Cyan
    Color(0xFF3B82F6), // Blue
    Color(0xFFEF4444), // Red
    Color(0xFF64748B), // Slate
  ];

  File? get _file {
    final dir = _dataDir;
    if (dir == null || dir.isEmpty) return null;
    return File('$dir${Platform.pathSeparator}appearance.json');
  }

  /// 注入数据目录并载入设置。
  void attachDataDir(String dir) {
    _dataDir = dir;
    _load();
  }

  void _load() {
    try {
      final f = _file;
      if (f == null || !f.existsSync()) return;
      final map = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      seedColor = Color(map['seed'] as int? ?? seedColor.toARGB32());
      wallpaperPath = map['wallpaper'] as String?;
      wallpaperEnabled = map['wallpaperOn'] as bool? ?? true;
      blur = (map['blur'] as num? ?? 0).toDouble().clamp(0, 60);
      saturation =
          (map['saturation'] as num? ?? 1).toDouble().clamp(0, 3);
      brightness = (map['brightness'] as num? ?? 1).toDouble().clamp(0, 3);
      maskColor = Color(map['mask'] as int? ?? maskColor.toARGB32());
      maskOpacity = (map['maskOpacity'] as num? ?? 0).toDouble().clamp(0, 1);
      textScale = (map['textScale'] as num? ?? 1).toDouble().clamp(0.85, 1.3);
      bubbleMaxWidth =
          (map['bubbleMaxWidth'] as num? ?? 460).toDouble().clamp(300, 560);
      bubbleRadius =
          (map['bubbleRadius'] as num? ?? 13).toDouble().clamp(4, 24);
      animationsEnabled = map['animations'] as bool? ?? true;
      inputMaxLines = (map['inputMaxLines'] as num? ?? 8).round().clamp(3, 12);
      wallpaperOpacity =
          (map['wallpaperOpacity'] as num? ?? 1).toDouble().clamp(0.2, 1);
      useBottomSheetMenus = map['bottomSheetMenus'] as bool? ?? false;
      noticeBannerEnabled = map['noticeBanner'] as bool? ?? true;
      receiveDir = map['receiveDir'] as String?;
      fileGridView = map['fileGridView'] as bool? ?? true;
      fileSort = map['fileSort'] as String? ?? 'time';
      inputOpacity = (map['inputOpacity'] as num? ?? 1).toDouble().clamp(0, 1);
      bubbleOpacity = (map['bubbleOpacity'] as num? ?? 0.35).toDouble().clamp(0.1, 0.7);
      // 显示模式：缺失/损坏一律回落「跟随系统」
      themeMode = switch (map['themeMode'] as String?) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
      // 深浅色各自的外观快照（旧配置没有时保持上面的平铺值）
      _lightLook = (map['lookLight'] as Map?)?.cast<String, dynamic>() ?? {};
      _darkLook = (map['lookDark'] as Map?)?.cast<String, dynamic>() ?? {};
      // 快照按**落盘的显示模式**选：跟随系统时按当前系统亮度选，跟 main 里的
      // _syncSystemBarStyle 保持一致（否则首帧会套错一套颜色）
      _isDarkLook = switch (themeMode) {
        ThemeMode.dark => true,
        ThemeMode.light => false,
        ThemeMode.system =>
          PlatformDispatcher.instance.platformBrightness == Brightness.dark,
      };
      // 先摆好快照再发布 notifier：main 的监听者会在 notifier 变化时同步调用
      // setDarkLook，此时 _isDarkLook 已与落盘模式一致 → 直接命中 early-return，
      // **不会**顺手 _save() 把刚载入的模式冲掉。
      _applyLook(_isDarkLook ? _darkLook : _lightLook);
      themeModeNotifier.value = themeMode;
    } catch (_) {
      // 配置损坏不影响启动
    }
  }


  // ------------------------------------------------------------
  // 深浅色独立记忆：主题与壁纸分区里的参数（主题色/壁纸/滤镜/遮罩）
  // 在浅色与深色下各自保存一份，切换模式时互换。
  // ------------------------------------------------------------

  bool _isDarkLook = false;
  Map<String, dynamic> _lightLook = {};
  Map<String, dynamic> _darkLook = {};

  Map<String, dynamic> _snapshot() => {
        'seed': seedColor.toARGB32(),
        'wallpaper': wallpaperPath,
        'wallpaperOn': wallpaperEnabled,
        'wallpaperOpacity': wallpaperOpacity,
        'blur': blur,
        'saturation': saturation,
        'brightness': brightness,
        'mask': maskColor.toARGB32(),
        'maskOpacity': maskOpacity,
      };

  void _applyLook(Map<String, dynamic> look) {
    if (look.isEmpty) return;
    seedColor = Color(look['seed'] as int? ?? seedColor.toARGB32());
    wallpaperPath = look['wallpaper'] as String?;
    wallpaperEnabled = look['wallpaperOn'] as bool? ?? true;
    wallpaperOpacity =
        (look['wallpaperOpacity'] as num? ?? 1).toDouble().clamp(0.2, 1);
    blur = (look['blur'] as num? ?? 0).toDouble().clamp(0, 60);
    saturation = (look['saturation'] as num? ?? 1).toDouble().clamp(0, 3);
    brightness = (look['brightness'] as num? ?? 1).toDouble().clamp(0, 3);
    maskColor = Color(look['mask'] as int? ?? maskColor.toARGB32());
    maskOpacity = (look['maskOpacity'] as num? ?? 0).toDouble().clamp(0, 1);
  }

  /// 当前生效的是深色外观吗（由 main 在主题/系统亮度变化时同步）。
  void setDarkLook(bool dark) {
    if (_isDarkLook == dark) return;
    if (_isDarkLook) {
      _darkLook = _snapshot();
    } else {
      _lightLook = _snapshot();
    }
    _isDarkLook = dark;
    // 切到另一套参数（没有就用当前值，避免闪一下默认值）
    _applyLook(dark ? _darkLook : _lightLook);
    notifyListeners();
    _save();
  }

  /// 切换显示模式（设置页与 NavRail 的明暗按钮都走这里）。
  ///
  /// 语义：用户显式选过 light/dark 后，系统亮度变化不再改外观（跟着模式走）。
  /// 这是**唯一**允许改 [themeModeNotifier] 的入口 —— 反面例子是让
  /// [setDarkLook] 反推模式，那会把用户选的「跟随系统」压成 light/dark。
  void setThemeMode(ThemeMode mode) {
    themeMode = mode;
    // 先把模式落到 notifier：监听者（main 的 _syncSystemBarStyle）会据此算亮度，
    // 同步进 setDarkLook；此处若先 setDarkLook，算出的模式会丢掉「跟随系统」。
    themeModeNotifier.value = mode;
    setDarkLook(_isDarkMode(mode));
    notifyListeners();
    _save();
  }

  /// 显示模式在当前系统亮度下是否算深色（system 才需要问系统）。
  bool _isDarkMode(ThemeMode mode) => switch (mode) {
        ThemeMode.dark => true,
        ThemeMode.light => false,
        ThemeMode.system =>
          PlatformDispatcher.instance.platformBrightness == Brightness.dark,
      };

  /// 当前壁纸是否真的生效：开关打开 + 文件存在。
  bool get hasWallpaper {
    if (!wallpaperEnabled) return false;
    final p = wallpaperPath;
    if (p == null || p.isEmpty) return false;
    return File(p).existsSync();
  }

  /// 输入区背景不透明度（用户要求：框外输入区背景透明，透明度可调）。
  void setInputOpacity(double v) {
    inputOpacity = v.clamp(0, 1);
    notifyListeners();
    _save();
  }

  void setBubbleOpacity(double v) {
    bubbleOpacity = v.clamp(0.1, 0.7);
    notifyListeners();
    _save();
  }

  /// 记住文件区视图 / 排序（用户要求：重启后保持）。
  void setFileView({required bool gridView, required String sort}) {
    fileGridView = gridView;
    fileSort = sort;
    notifyListeners();
    _save();
  }

  void setWallpaperEnabled(bool value) {
    wallpaperEnabled = value;
    notifyListeners();
    _save();
  }

  void setSeedColor(Color c) {
    seedColor = c;
    notifyListeners();
    _save();
  }

  void setWallpaper(String? path) {
    wallpaperPath = path;
    notifyListeners();
    _save();
  }

  void setBlur(double v) {
    blur = v.clamp(0, 60);
    notifyListeners();
    _save();
  }

  void setSaturation(double v) {
    saturation = v.clamp(0, 3);
    notifyListeners();
    _save();
  }

  void setBrightness(double v) {
    brightness = v.clamp(0, 3);
    notifyListeners();
    _save();
  }

  void setMaskColor(Color c) {
    maskColor = c;
    notifyListeners();
    _save();
  }

  void setMaskOpacity(double v) {
    maskOpacity = v.clamp(0, 1);
    notifyListeners();
    _save();
  }

  void setTextScale(double v) {
    textScale = v.clamp(0.85, 1.3);
    notifyListeners();
    _save();
  }

  void setBubbleMaxWidth(double v) {
    bubbleMaxWidth = v.clamp(300, 560);
    notifyListeners();
    _save();
  }

  void setBubbleRadius(double v) {
    bubbleRadius = v.clamp(4, 24);
    notifyListeners();
    _save();
  }

  void setInputMaxLines(int v) {
    inputMaxLines = v.round().clamp(3, 12);
    notifyListeners();
    _save();
  }

  void setUseBottomSheetMenus(bool v) {
    useBottomSheetMenus = v;
    notifyListeners();
    _save();
  }

  void setWallpaperOpacity(double v) {
    wallpaperOpacity = v.clamp(0.2, 1);
    notifyListeners();
    _save();
  }

  void setAnimationsEnabled(bool v) {
    animationsEnabled = v;
    notifyListeners();
    _save();
  }

  void setNoticeBannerEnabled(bool v) {
    noticeBannerEnabled = v;
    notifyListeners();
    _save();
  }

  void setReceiveDir(String? dir) {
    receiveDir = (dir == null || dir.isEmpty) ? null : dir;
    notifyListeners();
    _save();
  }

  void _save() {
    try {
      final f = _file;
      if (f == null) return;
      // 先把当前值存进当前模式的快照，再一起落盘
      if (_isDarkLook) {
        _darkLook = _snapshot();
      } else {
        _lightLook = _snapshot();
      }
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode({
        'themeMode': themeMode.name,
        'lookLight': _lightLook,
        'lookDark': _darkLook,
        'seed': seedColor.toARGB32(),
        'wallpaper': wallpaperPath,
        'wallpaperOn': wallpaperEnabled,
        'blur': blur,
        'saturation': saturation,
        'brightness': brightness,
        'mask': maskColor.toARGB32(),
        'maskOpacity': maskOpacity,
        'textScale': textScale,
        'bubbleMaxWidth': bubbleMaxWidth,
        'bubbleRadius': bubbleRadius,
        'animations': animationsEnabled,
        'inputMaxLines': inputMaxLines,
        'bottomSheetMenus': useBottomSheetMenus,
        'wallpaperOpacity': wallpaperOpacity,
        'bubbleOpacity': bubbleOpacity,
        'noticeBanner': noticeBannerEnabled,
        'receiveDir': receiveDir,
        'fileGridView': fileGridView,
        'fileSort': fileSort,
        'inputOpacity': inputOpacity,
      }));
    } catch (_) {
      // 保存失败静默（只影响下次启动记忆）
    }
  }
}

/// 壁纸背景层：把当前壁纸按滤镜渲染，并叠遮罩。无壁纸时为纯色。
class WallpaperBackground extends StatelessWidget {
  const WallpaperBackground({super.key, required this.isLight});

  final bool isLight;

  @override
  Widget build(BuildContext context) {
    final a = AppearanceState.instance;
    if (!a.hasWallpaper) {
      return ColoredBox(
        color: isLight ? const Color(0xFFF3F4F8) : const Color(0xFF101116),
      );
    }
    final image = Image.file(
      File(a.wallpaperPath!),
      fit: BoxFit.cover,
      // 壁纸按屏幕尺寸解码，避免大图 OOM
      cacheWidth: 1920,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => ColoredBox(
        color: isLight ? const Color(0xFFF3F4F8) : const Color(0xFF101116),
      ),
    );
    final opacity = a.wallpaperOpacity;
    final filtered = a.blur > 0
        ? ImageFiltered(
            imageFilter: ImageFilter.blur(
              sigmaX: a.blur,
              sigmaY: a.blur,
              tileMode: TileMode.mirror,
            ),
            child: image,
          )
        : image;
    final tuned = ColorFiltered(
      colorFilter: ColorFilter.matrix(_satBrightnessMatrix(
        a.saturation,
        a.brightness,
      )),
      child: opacity >= 1
          ? filtered
          : Opacity(opacity: opacity, child: filtered),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        // 底色：壁纸调低不透明度时透出的是它，而不是黑底
        ColoredBox(
          color: isLight ? const Color(0xFFF3F4F8) : const Color(0xFF101116),
        ),
        tuned,
        if (a.maskOpacity > 0)
          ColoredBox(
            color: a.maskColor.withValues(alpha: a.maskOpacity),
          ),
      ],
    );
  }

  /// 饱和度 + 亮度矩阵（行主序 5x4，末列是偏移，本实现不加偏移）。
  static List<double> _satBrightnessMatrix(double sat, double bright) {
    // 先做亮度缩放，再做饱和度（相对灰度）。
    return <double>[
      bright * (0.213 + 0.787 * sat), bright * (0.715 - 0.715 * sat),
      bright * (0.072 - 0.072 * sat), 0, 0,
      bright * (0.213 - 0.213 * sat), bright * (0.715 + 0.285 * sat),
      bright * (0.072 - 0.072 * sat), 0, 0,
      bright * (0.213 - 0.213 * sat), bright * (0.715 - 0.715 * sat),
      bright * (0.072 + 0.928 * sat), 0, 0,
      0, 0, 0, 1, 0,
    ];
  }
}
