import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:rust_flutter_ui/src/rust/api/simple.dart' as rust_simple;

import '../app_state.dart';
import '../appearance.dart';
import '../main.dart';
import '../services/platform_channel.dart';
import '../services/transfer_service.dart';
import 'color_picker.dart';
import 'menus.dart';
import 'osd_toast.dart';

/// 作者主页（B站：音乐制作王某人）。
const String kAuthorBilibili = 'https://space.bilibili.com/80192671';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// 资源管理器右键菜单「通过雨传发送」是否已注册（仅 Windows）。
  bool _ctxMenu = false;
  bool _ctxBusy = false;
  String? _platform;
  /// 通知权限状态（Android 13+ 需要运行时申请）。
  bool _notifyGranted = true;

  /// 安卓实际收件落点：公共 `Download/雨传` 的真实路径（原生取回）。
  /// null = 还没取到/旧版原生 → 显示回落默认收件目录。
  String? _publicDir;

  /// 取公共收件目录路径（安卓；目录还不存在时原生照样返回路径字符串）。
  Future<void> _refreshPublicDir() async {
    if (!YuChuanPlatform.isAndroid) return;
    final p = await YuChuanPlatform.publicDownloadPath();
    if (!mounted || p == null || p.isEmpty) return;
    setState(() => _publicDir = p);
  }

  /// 安卓返回：子页面先回总览（分栏模式下交回 Shell）。
  bool _onBack() {
    if (_section == null) return false;
    setState(() => _section = null);
    return true;
  }

  @override
  void initState() {
    super.initState();
    if (rustBridgeOk) {
      try {
        _platform = rust_simple.pingPlatform();
      } catch (e) {
        _platform = 'error: $e';
      }
    }
    AppState.instance.backHandler = _onBack;
    unawaited(_refreshPublicDir());
    _refreshNotifyState();
    _refreshCtxMenuState();
  }

  /// 右键菜单注册表键（HKCU，免管理员；卸载即删，可回滚）。
  static const _ctxKey =
      r'HKCU\Software\Classes\*\shell\YuChuan.Send';

  /// 读当前是否已注册。
  Future<void> _refreshCtxMenuState() async {
    if (!Platform.isWindows) return;
    // 测试环境不查注册表：Process.run 会留下 pending 状态，
    // flutter test 收尾断言 !timersPending 会失败。
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    try {
      final r = await Process.run('reg', ['query', _ctxKey]);
      if (!mounted) return;
      setState(() => _ctxMenu = r.exitCode == 0);
    } catch (_) {
      // reg 不存在（极少数环境）：当成未注册，开关不可用
    }
  }

  /// 开/关右键菜单：直接写注册表，不依赖外部脚本。
  ///
  /// 路径里的 * 会被 PowerShell 提供程序当通配符（脚本踩过），
  /// 所以这里直接调 reg.exe，按字面量处理。
  Future<void> _setCtxMenu(bool on) async {
    if (_ctxBusy) return;
    setState(() => _ctxBusy = true);
    try {
      final exe = Platform.resolvedExecutable;
      if (on) {
        for (final key in [_ctxKey, r'HKCU\Software\Classes\Directory\shell\YuChuan.Send']) {
          await Process.run('reg', ['add', key, '/ve', '/t', 'REG_SZ', '/d', '通过雨传发送', '/f']);
          await Process.run('reg', ['add', key, '/v', 'MUIVerb', '/t', 'REG_SZ', '/d', '通过雨传发送', '/f']);
          await Process.run('reg', ['add', key, '/v', 'Icon', '/t', 'REG_SZ', '/d', exe, '/f']);
          await Process.run('reg', ['add', key, '/v', 'MultiSelectModel', '/t', 'REG_SZ', '/d', 'Player', '/f']);
          // 必须写字面普通引号（标准格式 "exe" "%1"）：Dart Process.run 自带
          // Windows 参数转义，reg.exe 收到什么就存什么。写成 \" 会被原样存进
          // 注册表，Explorer 的 CreateProcess 按空白断词 → 解析出带引号的非法
          // 路径 → 右键直接弹「Windows 无法访问指定设备、路径或文件」（实测踩过，
          // PowerShell 下的转义经验不能照搬到 Dart——两边参数传递机制不同）。
          await Process.run('reg', [
            'add', '$key\\command', '/ve', '/t', 'REG_SZ', '/f',
            '/d', '"$exe" "%1"',
          ]);
        }
      } else {
        for (final key in [_ctxKey, r'HKCU\Software\Classes\Directory\shell\YuChuan.Send']) {
          await Process.run('reg', ['delete', key, '/f']);
        }
      }
    } catch (_) {
      // 写失败不影响应用，下面会重读真实状态回填开关
    }
    await _refreshCtxMenuState();
    if (mounted) setState(() => _ctxBusy = false);
  }

  @override
  void dispose() {
    if (AppState.instance.backHandler == _onBack) {
      AppState.instance.backHandler = null;
    }
    super.dispose();
  }
  Future<void> _refreshNotifyState() async {
    final granted = await YuChuanPlatform.notificationsGranted();
    if (!mounted) return;
    setState(() => _notifyGranted = granted);
  }

  /// 设置分区（宽屏分栏导航 / 窄屏子页面）。
  static const _sections = <(String, IconData)>[
    ('主题与壁纸', Icons.palette_outlined),
    ('界面', Icons.devices_other_outlined),
    ('通知', Icons.notifications_active_outlined),
    ('发现与连接', Icons.radar_outlined),
    ('传输', Icons.folder_outlined),
    ('关于', Icons.info_outline),
  ];

  /// 当前打开的子页面（null = 总览，只在窄屏用）。
  String? _section;

  Widget _sectionBody(String name, ColorScheme scheme) => switch (name) {
        '主题与壁纸' => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _themeCard(scheme),
              const SizedBox(height: 16),
              _backgroundCard(scheme),
              const SizedBox(height: 12),
              Text(
                '浅色与深色下的主题色、壁纸、滤镜、遮罩会分别记住',
                style: TextStyle(fontSize: 11.5, color: scheme.outline),
              ),
            ],
          ),
        '界面' => _interfaceCard(),
        '通知' => _notifyCard(scheme),
        '发现与连接' => _discoveryCard(scheme),
        '传输' => _transferCard(scheme),
        _ => _aboutCard(scheme),
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final wide = MediaQuery.sizeOf(context).width >= 820;

    // 宽屏：左侧分区导航 + 右侧内容（分栏，不再一屏塞满）
    if (wide) {
      final current = _section ?? _sections.first.$1;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 220, child: _sectionNav(current, scheme)),
          const VerticalDivider(width: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionTitle(current),
                    _sectionBody(current, scheme),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    }

    // 窄屏：总览 → 子页面（带返回）
    final current = _section;
    if (current != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 8, 16, 2),
            child: Row(
              children: [
                IconButton(
                  tooltip: '返回',
                  icon: const Icon(Icons.arrow_back, size: 20),
                  onPressed: () => setState(() => _section = null),
                ),
                Text(current,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 32),
              child: _sectionBody(current, scheme),
            ),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 4, bottom: 8),
          child: Text('设置',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        ),
        for (final (name, icon) in _sections)
          Card(
            child: ListTile(
              leading: Icon(icon, size: 20),
              title: Text(name),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: () {
                tapFeedback();
                setState(() => _section = name);
              },
            ),
          ),
      ],
    );
  }

  /// 宽屏左侧分区导航。
  Widget _sectionNav(String current, ColorScheme scheme) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 12, bottom: 10),
          child: Text('设置',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        ),
        for (final (name, icon) in _sections)
          ListTile(
            leading: Icon(icon, size: 19),
            title: Text(name, style: const TextStyle(fontSize: 13.5)),
            selected: name == current,
            selectedColor: scheme.primary,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
            onTap: () {
              tapFeedback();
              setState(() => _section = name);
            },
          ),
      ],
    );
  }

  // ------------------------------------------------------------
  // 主题：深色模式三选 + 主题色（预设 / 自定义）
  // ------------------------------------------------------------

  Widget _themeCard(ColorScheme scheme) {
    final a = AppearanceState.instance;
    return Card(
      child: ListenableBuilder(
        listenable: a,
        builder: (context, _) {
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.dark_mode_outlined, size: 19),
                        const SizedBox(width: 10),
                        const Text('显示模式',
                            style: TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w700)),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ValueListenableBuilder<ThemeMode>(
                      valueListenable: themeModeNotifier,
                      builder: (context, mode, _) {
                        return SegmentedButton<ThemeMode>(
                          segments: const [
                            ButtonSegment(
                              value: ThemeMode.system,
                              label: Text('跟随系统'),
                              icon: Icon(Icons.brightness_auto, size: 17),
                            ),
                            ButtonSegment(
                              value: ThemeMode.light,
                              label: Text('浅色'),
                              icon: Icon(Icons.light_mode, size: 17),
                            ),
                            ButtonSegment(
                              value: ThemeMode.dark,
                              label: Text('深色'),
                              icon: Icon(Icons.dark_mode, size: 17),
                            ),
                          ],
                          selected: {mode},
                          // 走持久化 setter：直接改 notifier 不落盘，重启就丢
                          onSelectionChanged: (s) =>
                              AppearanceState.instance.setThemeMode(s.first),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.palette_outlined, size: 19),
                        const SizedBox(width: 10),
                        const Text('主题色',
                            style: TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w700)),
                        const Spacer(),
                        TextButton.icon(
                          icon: const Icon(Icons.colorize, size: 17),
                          label: const Text('自定义'),
                          onPressed: () async {
                            final c = await showYuChuanColorPicker(context,
                                initial: a.seedColor, title: '自定义主题色');
                            if (c != null) a.setSeedColor(c);
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        for (final c in AppearanceState.presetColors)
                          _ColorDot(
                            color: c,
                            selected: a.seedColor.toARGB32() == c.toARGB32(),
                            onTap: () => a.setSeedColor(c),
                          ),
                        _ColorDot(
                          color: a.seedColor,
                          selected: !AppearanceState.presetColors
                              .any((c) => c.toARGB32() == a.seedColor.toARGB32()),
                          custom: true,
                          onTap: () async {
                            final c = await showYuChuanColorPicker(context,
                                initial: a.seedColor, title: '自定义主题色');
                            if (c != null) a.setSeedColor(c);
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ------------------------------------------------------------
  // 背景与壁纸：开关 + 选择 + 滤镜 + 遮罩
  // ------------------------------------------------------------

  Widget _backgroundCard(ColorScheme scheme) {
    final a = AppearanceState.instance;
    return Card(
      child: ListenableBuilder(
        listenable: a,
        builder: (context, _) {
          return Column(
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.wallpaper_outlined),
                title: const Text('启用壁纸'),
                subtitle: Text(
                  a.wallpaperPath == null
                      ? '还没有选择壁纸（关闭时用纯色背景）'
                      : a.wallpaperPath!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                value: a.wallpaperEnabled && a.wallpaperPath != null,
                onChanged: (v) {
                  if (v && a.wallpaperPath == null) {
                    _pickWallpaper();
                  } else {
                    a.setWallpaperEnabled(v);
                  }
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Row(
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(Icons.image_outlined, size: 16),
                      label: Text(a.wallpaperPath == null ? '选择壁纸' : '更换壁纸'),
                      onPressed: _pickWallpaper,
                    ),
                    if (a.wallpaperPath != null) ...[
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () => a.setWallpaper(null),
                        child: const Text('移除'),
                      ),
                    ],
                  ],
                ),
              ),
              // 不透明度紧跟在更换按钮下方、模糊上方（用户要求的顺序）
              if (a.wallpaperPath != null)
                _slider('壁纸不透明度', a.wallpaperOpacity, 0.2, 1,
                    a.setWallpaperOpacity, (v) => '${(v * 100).round()}%'),
              if (a.hasWallpaper) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _slider('模糊', a.blur, 0, 30, a.setBlur,
                          (v) => v.round().toString()),
                      _slider('饱和度', a.saturation, 0, 2.5, a.setSaturation,
                          (v) => '${v.toStringAsFixed(1)}×'),
                      _slider('亮度', a.brightness, 0.2, 2, a.setBrightness,
                          (v) => '${v.toStringAsFixed(1)}×'),
                      const Divider(height: 18),
                      const Text('遮罩',
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      _slider('遮罩不透明度', a.maskOpacity, 0, 1,
                          a.setMaskOpacity, (v) => '${(v * 100).round()}%'),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Text('遮罩颜色',
                              style: TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600)),
                          const SizedBox(width: 12),
                          for (final c in const [
                            Color(0xFF000000),
                            Color(0xFFFFFFFF),
                            Color(0xFF1E293B),
                            Color(0xFF312E81),
                            Color(0xFF0F172A),
                          ])
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: _ColorDot(
                                color: c,
                                size: 24,
                                selected:
                                    a.maskColor.toARGB32() == c.toARGB32(),
                                onTap: () => a.setMaskColor(c),
                              ),
                            ),
                          TextButton.icon(
                            icon: const Icon(Icons.colorize, size: 16),
                            label: const Text('自定义'),
                            onPressed: () async {
                              final c = await showYuChuanColorPicker(context,
                                  initial: a.maskColor, title: '遮罩颜色');
                              if (c != null) a.setMaskColor(c);
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Future<void> _pickWallpaper() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    final path = result?.files.single.path;
    if (path != null && path.isNotEmpty) {
      AppearanceState.instance
        ..setWallpaper(path)
        ..setWallpaperEnabled(true);
    }
  }

  // ------------------------------------------------------------
  // 界面：字号 / 气泡宽度 / 气泡圆角 / 动画
  // ------------------------------------------------------------

  Widget _interfaceCard() {
    final a = AppearanceState.instance;
    return Card(
      child: ListenableBuilder(
        listenable: a,
        builder: (context, _) {
          return Column(
            children: [
              _slider('字号', a.textScale, 0.85, 1.3, a.setTextScale,
                  (v) => '${(v * 100).round()}%'),
               // 聊天气泡不透明度（浅色/深色分别记忆）
              _slider('气泡不透明度', a.bubbleOpacity, 0.1, 0.7,
                  a.setBubbleOpacity, (v) => '${(v * 100).round()}%'),
              _slider('气泡宽度', a.bubbleMaxWidth, 300, 560,
                  a.setBubbleMaxWidth, (v) => '${v.round()}px'),
              _slider('气泡圆角', a.bubbleRadius, 4, 24, a.setBubbleRadius,
                  (v) => '${v.round()}px'),
              _slider('输入框最大行数', a.inputMaxLines.toDouble(), 3, 12,
                  (v) => a.setInputMaxLines(v.round()),
                  (v) => '${v.round()} 行'),
              // 框外输入区背景透明度：调低即可透出壁纸/背景
              _slider('输入区域不透明度', a.inputOpacity, 0, 1,
                  a.setInputOpacity, (v) => '${(v * 100).round()}%'),

              const Divider(height: 1, indent: 16, endIndent: 16),
              SwitchListTile(
                secondary: const Icon(Icons.open_in_full),
                title: const Text('弹出菜单用底部卡片'),
                subtitle: const Text('关掉则用就地弹出菜单（桌面习惯）'),
                value: a.useBottomSheetMenus,
                onChanged: a.setUseBottomSheetMenus,
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              SwitchListTile(
                secondary: const Icon(Icons.animation),
                title: const Text('入场与进度动画'),
                subtitle: const Text('关闭后消息立即到位，低端机更跟手'),
                value: a.animationsEnabled,
                onChanged: a.setAnimationsEnabled,
              ),
            ],
          );
        },
      ),
    );
  }

  // ------------------------------------------------------------
  // 通知
  // ------------------------------------------------------------

  Widget _notifyCard(ColorScheme scheme) {
    final a = AppearanceState.instance;
    return Card(
      child: ListenableBuilder(
        listenable: a,
        builder: (context, _) {
          return Column(
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.notifications_active_outlined),
                title: const Text('新消息提醒（OSD 提示条）'),
                subtitle: const Text('不在会话里时，顶部弹出发送人与内容摘要'),
                value: a.noticeBannerEnabled,
                onChanged: a.setNoticeBannerEnabled,
              ),
              if (YuChuanPlatform.isAndroid) ...[
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  leading: Icon(
                    _notifyGranted
                        ? Icons.check_circle
                        : Icons.notifications_off_outlined,
                    color: _notifyGranted
                        ? const Color(0xFF10B981)
                        : scheme.outline,
                  ),
                  title: const Text('系统通知权限'),
                  subtitle: Text(_notifyGranted ? '已授予' : '未授予（不影响收发）'),
                  trailing: _notifyGranted
                      ? null
                      : TextButton(
                          onPressed: () async {
                            await YuChuanPlatform.requestNotifications();
                            await Future<void>.delayed(
                                const Duration(milliseconds: 700));
                            await _refreshNotifyState();
                          },
                          child: const Text('去开启'),
                        ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  // ------------------------------------------------------------
  // 发现与连接
  // ------------------------------------------------------------

  Widget _discoveryCard(ColorScheme scheme) {
    return Card(
      child: Column(
        children: [
          const ListTile(
            leading: Icon(Icons.radar_outlined),
            title: Text('启动时不自动发现'),
            subtitle: Text('默认保持安静；需要找设备时在「设备」页手动开始，配对成功后会自动关闭'),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListenableBuilder(
            listenable: AppState.instance,
            builder: (context, _) {
              final state = AppState.instance;
              return SwitchListTile(
                secondary: const Icon(Icons.filter_alt_outlined),
                title: const Text('自动过滤虚拟网卡'),
                subtitle:
                    const Text('跳过 VMware / WSL / 虚拟机等适配器，只用真实局域网网卡发现'),
                value: state.filterVirtualNic,
                onChanged: state.setFilterVirtualNic,
              );
            },
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListenableBuilder(
            listenable: AppState.instance,
            builder: (context, _) {
              final state = AppState.instance;
              return ListTile(
                leading: const Icon(Icons.contacts_outlined),
                title: const Text('联系人与配对表'),
                subtitle: Text(
                  '${state.pairedContacts.isEmpty
                      ? '暂无已配对设备'
                      : state.pairedContacts.map((c) => c.name).join('、')}\n${state.pairingStoreOpened
                          ? state.pairingStorePath
                          : '配对表未打开（重启会丢）'}',
                ),
                isThreeLine: true,
                trailing: Text(
                  '${state.pairedContacts.length} 位',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: scheme.primary,
                  ),
                ),
              );
            },
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListenableBuilder(
            listenable: AppState.instance,
            builder: (context, _) {
              final state = AppState.instance;
              return ListTile(
                leading: Icon(
                  state.liveDiscovery ? Icons.lan : Icons.lan_outlined,
                  color: state.liveDiscovery
                      ? const Color(0xFF10B981)
                      : scheme.outline,
                ),
                title: const Text('发现服务'),
                subtitle: Text(
                  '${state.discoveryStatusText}（组播 239.255.42.99）\n本机 ${state.localDeviceName} · ID ${state.localDeviceIdShort}${state.multicastLockHeld ? ' · 组播锁已持有' : ''}',
                ),
                isThreeLine: true,
                trailing: Icon(
                  state.liveDiscovery
                      ? Icons.check_circle
                      : Icons.info_outline,
                  size: 18,
                  color: state.liveDiscovery
                      ? const Color(0xFF10B981)
                      : scheme.outline,
                ),
              );
            },
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListenableBuilder(
            listenable: AppState.instance,
            builder: (context, _) {
              final state = AppState.instance;
              return ListTile(
                leading: const Icon(Icons.settings_ethernet),
                title: const Text('参与发现的网卡'),
                subtitle: Text(
                  state.localInterfaces.isEmpty
                      ? '未识别到可用 IPv4 网卡'
                      : state.localInterfaces.join('\n'),
                ),
                isThreeLine: state.localInterfaces.length > 1,
                trailing: Text(
                  state.liveDiscovery ? '运行中' : '未启动',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: state.liveDiscovery
                        ? const Color(0xFF10B981)
                        : scheme.outline,
                  ),
                ),
              );
            },
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListenableBuilder(
            listenable: AppState.instance,
            builder: (context, _) {
              final state = AppState.instance;
              return ListTile(
                leading: Icon(
                  state.chatReady ? Icons.forum : Icons.forum_outlined,
                  color: state.chatReady
                      ? const Color(0xFF10B981)
                      : scheme.outline,
                ),
                title: const Text('聊天会话与消息存储'),
                subtitle: Text(
                  state.chatReady
                      ? '已监听 TCP :${state.chatPort} · 会话 ${state.conversations.length} · 在线 ${state.chatOnline.values.where((v) => v).length}'
                      : (state.chatError.isEmpty
                          ? '聊天链路启动中…'
                          : state.chatError),
                ),
                trailing: Text(
                  '${state.totalUnread} 未读',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: scheme.primary,
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------
  // 传输：接收目录（可自定义）+ 自动接收 + 限速
  // ------------------------------------------------------------

  Widget _transferCard(ColorScheme scheme) {
    final a = AppearanceState.instance;
    // 安卓没设自定义目录时，实际落点是公共 Download/雨传（MediaStore），
    // 不是应用私有收件目录 —— 这里必须显示**真实落点**，否则用户按界面上的
    // 路径去文件管理器里找永远找不到（设置项与「打开」按钮也会各指一处）。
    String androidPublicDir = '';
    if (YuChuanPlatform.isAndroid) androidPublicDir = _publicDir ?? '';
    String defaultDir = '';
    try {
      if (rustBridgeOk) defaultDir = TransferService.instance.downloadDir();
    } catch (_) {
      defaultDir = '';
    }
    final custom = a.receiveDir;
    final effective = (custom != null && custom.isNotEmpty)
        ? custom
        : (androidPublicDir.isNotEmpty ? androidPublicDir : defaultDir);

    return Card(
      // 自动接收 / 限速现在归 AppState（prefs.json），接收目录归 AppearanceState；
      // 两个都要听，否则改完开关界面不刷新。
      child: ListenableBuilder(
        listenable: Listenable.merge([a, AppState.instance]),
        builder: (context, _) {
          final state = AppState.instance;
          return Column(
            children: [
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: const Text('接收目录'),
                subtitle: Text(
                  effective.isEmpty
                      ? '（聊天链路就绪后显示真实路径）'
                      // 安卓 SAF 存的是 content:// URI：显示成可读路径
                      : YuChuanPlatform.describeTreeUri(effective),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                isThreeLine: true,
                trailing: Wrap(
                  spacing: 2,
                  children: [
                    TextButton(
                      onPressed: _pickReceiveDir,
                      child: const Text('更改'),
                    ),
                    if (effective.isNotEmpty)
                      TextButton(
                        onPressed: () async {
                          // 安卓且没设自定义目录：落点是公共 Download/雨传，
                          // 应用对它没有 dart:io 权限，只能由原生构造 document
                          // URI 交给系统文件管理器（目录不存在时退到 Download）。
                          if (YuChuanPlatform.isAndroid &&
                              (custom == null || custom.isEmpty)) {
                            final err = await YuChuanPlatform
                                .revealPublicDownloadDir();
                            _snack(err == null
                                ? '已打开 ${YuChuanPlatform.publicDownloadDirName} 目录'
                                : '打开失败：$err');
                            return;
                          }
                          final msg =
                              await AppState.instance.revealFolder(effective);
                          _snack(msg);
                        },
                        child: const Text('打开'),
                      ),
                  ],
                ),
              ),
              if (custom != null && custom.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '已自定义 · 默认目录：'
                      '${androidPublicDir.isNotEmpty ? androidPublicDir : defaultDir}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: scheme.outline),
                    ),
                  ),
                ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              SwitchListTile(
                secondary: const Icon(Icons.download_done),
                title: const Text('自动接收可信联系人的文件'),
                // 诚实措辞：该开关当前只记忆选择，尚未接入传输层（本轮按默认处理）
                subtitle: const Text('记住此选择（自动接收逻辑待接入）'),
                value: state.autoAcceptFiles,
                onChanged: state.setAutoAcceptFiles,
              ),
              // 仅 Windows：注册资源管理器右键「通过雨传发送」
              if (Platform.isWindows)
                SwitchListTile(
                  secondary: const Icon(Icons.mouse_outlined),
                  title: const Text('资源管理器右键菜单「通过雨传发送」'),
                  subtitle: const Text(
                      '写入当前用户的注册表，无需管理员；关掉即删除'),
                  value: _ctxMenu,
                  onChanged: _ctxBusy ? null : _setCtxMenu,
                ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: const Icon(Icons.speed_outlined),
                title: const Text('限速'),
                subtitle: Slider(
                  value: state.speedLimitMb,
                  min: 0,
                  max: 50,
                  divisions: 10,
                  label: state.speedLimitMb == 0
                      ? '不限速'
                      : '${state.speedLimitMb.round()} MB/s',
                  onChanged: state.setSpeedLimitMb,
                ),
                trailing: Text(
                  state.speedLimitMb == 0
                      ? '不限速'
                      : '${state.speedLimitMb.round()} MB/s',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: scheme.primary,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _pickReceiveDir() async {
    var dir = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择接收目录');
    if (dir != null && dir.isNotEmpty) {
      // 安卓：file_picker 把树 URI 解析成**真实路径**返回（没有写权限）。
      // 趁选择器给的瞬时授权还在，重建树 URI 并转成持久授权，
      // 之后写入/打开都走这个 content:// 树。
      if (YuChuanPlatform.isAndroid && !dir.startsWith('content://')) {
        final tree = await YuChuanPlatform.persistTreeForPath(dir);
        if (tree != null) dir = tree;
      }
      AppearanceState.instance.setReceiveDir(dir);
      // 安卓 SAF：授权必须持久化，否则进程结束/重启后收到的文件
      // 就再也写不进用户选的这个目录（file_picker 不帮你做这步）
      if (dir.startsWith('content://')) {
        final err = await YuChuanPlatform.takeTreePermission(dir);
        if (err != null) _snack('接收目录授权失败：$err');
      }
    }
  }

  // ------------------------------------------------------------
  // 关于（含作者信息）
  // ------------------------------------------------------------

  Widget _aboutCard(ColorScheme scheme) {
    return Card(
      child: Column(
        children: [
          const ListTile(
            leading: Icon(Icons.apps_outlined),
            title: Text('雨传 YuChuan v1.0.0'),
            subtitle: Text(
                '局域网聊天 / 传文件工具 · Flutter + Rust · Android + Windows'),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListTile(
            leading: Icon(
              rustBridgeOk ? Icons.bolt : Icons.bolt_outlined,
              color: rustBridgeOk ? const Color(0xFF10B981) : scheme.outline,
            ),
            title: const Text('Rust 桥接'),
            subtitle: Text(
              rustBridgeOk
                  ? 'flutter_rust_bridge 2.8.0 已连接 · Rust 端 [${_platform ?? '…'}]'
                  : '演示模式（桥接未接通，UI 数据为本地 Mock）',
            ),
            trailing: Icon(
              rustBridgeOk ? Icons.check_circle : Icons.info_outline,
              size: 18,
              color: rustBridgeOk ? const Color(0xFF10B981) : scheme.outline,
            ),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('作者'),
            subtitle: const Text('B站：音乐制作王某人'),
            trailing: const Icon(Icons.open_in_new, size: 17),
            onTap: () async {
              final err = await YuChuanPlatform.openUrl(kAuthorBilibili);
              if (err != null) _snack('打开失败：$err');
            },
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListTile(
            leading: const Icon(Icons.security_outlined),
            title: const Text('安全说明'),
            subtitle:
                const Text('仅限可信局域网使用；端到端加密计划于 v2 提供'),
            onTap: () => _snack('仅在可信局域网内使用，不要连接陌生公共 Wi-Fi'),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      );

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    void Function(double) onChanged,
    String Function(double) fmt,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(label, style: const TextStyle(fontSize: 12.5)),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              fmt(value),
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  /// 所有通知统一走 OSD（横幅已按用户要求删除）。
  void _snack(String text) {
    if (!mounted) return;
    OsdToast.info(context, text);
  }
}

/// 颜色圆点（主题色 / 遮罩色共用）。
class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.color,
    required this.selected,
    required this.onTap,
    this.size = 30,
    this.custom = false,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;
  final double size;
  final bool custom;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: custom
              ? const LinearGradient(
                  colors: [
                    Color(0xFFEF4444),
                    Color(0xFFF59E0B),
                    Color(0xFF10B981),
                    Color(0xFF6366F1),
                  ],
                )
              : null,
          color: custom ? null : color,
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.onSurface
                : Colors.black.withValues(alpha: 0.12),
            width: selected ? 2.4 : 1,
          ),
        ),
        child: Icon(
          custom ? Icons.colorize : (selected ? Icons.check : null),
          size: size * 0.5,
          color: custom ? Colors.white : (selected ? Colors.white : null),
        ),
      ),
    );
  }
}