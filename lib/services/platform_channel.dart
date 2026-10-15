import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 一个能打开某文件的候选应用（自建「打开方式」窗口的一行）。
class OpenWithApp {
  const OpenWithApp({
    required this.package,
    required this.label,
    this.isDefault = false,
    this.iconPng,
  });

  /// 安卓包名（「始终」记忆存的就是它）。
  final String package;

  /// 展示名（如「WPS Office」）。
  final String label;

  /// 是否是当前系统默认应用（排最前 + 标注「默认」）。
  final bool isDefault;

  /// 应用图标的 PNG 字节（原生 PackageManager 导出，Uint8List）。
  /// 为空 = 取不到，调用方退回通用类型图标。
  final Uint8List? iconPng;

  @override
  bool operator ==(Object other) =>
      other is OpenWithApp &&
      other.package == package &&
      other.label == label &&
      other.isDefault == isDefault;

  @override
  int get hashCode => Object.hash(package, label, isDefault);

  @override
  String toString() => 'OpenWithApp($package, $label, default=$isDefault)';
}

/// 平台能力桥（Android 原生 / 桌面兜底）。
///
/// Android 走 MethodChannel（MainActivity 实现）；其它平台或原生侧未实现时
/// 全部安全降级（返回 null / false），绝不影响主流程。
class YuChuanPlatform {  YuChuanPlatform._();

  static const MethodChannel _channel = MethodChannel('yuchuan/platform');

  static bool get isAndroid => _isAndroidOverride ?? Platform.isAndroid;

  /// 测试用平台开关。`Platform.isAndroid` 来自 dart:io，读的是真实操作系统，
  /// 测试里无法伪造（`debugDefaultTargetPlatformOverride` 只影响
  /// `defaultTargetPlatform`，不影响它）。安卓专有分支因此只能靠这个口子才测得到。
  /// 生产代码永不设置它；置回 null 即恢复真实平台判断。
  static bool? _isAndroidOverride;

  /// 仅供测试：伪造/恢复安卓平台判断。详见 [isAndroid]。
  @visibleForTesting
  static set isAndroidOverride(bool? value) => _isAndroidOverride = value;

  /// 测试用 `Process.start` 拦截口（exe, args）→ 错误文案（null = 成功）。
  ///
  /// 桌面分支会真的拉进程（弹真实对话框），测试里不能让它落地；同时 PC 分支
  /// 曾因「所有测试都伪造安卓」而两轮没被跑到。留这个口子才能在测试里
  /// 断言「PC 端到底拉了什么命令」。生产代码永不设置它。
  @visibleForTesting
  static Future<String?> Function(String exe, List<String> args)?
      processStartHook;

  /// 设备型号（Android 上替代不可用的 hostname）。
  static Future<String?> deviceName() async {
    if (!isAndroid) return null;
    return _invoke<String>('deviceName');
  }

  /// 应用私有目录（用于持久化 device_id，零权限）。
  static Future<String?> filesDir() async {
    if (!isAndroid) return null;
    return _invoke<String>('filesDir');
  }

  /// 申请组播锁；Android 省电模式会丢组播包，不持锁发现不稳定（风险3）。
  static Future<bool> acquireMulticastLock() async {
    if (!isAndroid) return false;
    return await _invoke<bool>('acquireMulticastLock') ?? false;
  }

  static Future<bool> releaseMulticastLock() async {
    if (!isAndroid) return false;
    return await _invoke<bool>('releaseMulticastLock') ?? false;
  }

  /// 高性能 Wi-Fi 锁：切后台时不让系统降级 Wi-Fi，聊天/传输不断连。
  static Future<bool> acquireWifiLock() async {
    if (!isAndroid) return false;
    return await _invoke<bool>('acquireWifiLock') ?? false;
  }

  static Future<bool> releaseWifiLock() async {
    if (!isAndroid) return false;
    return await _invoke<bool>('releaseWifiLock') ?? false;
  }

  /// 启动前台服务：安卓切后台后进程会被降优先级/冻结，纯 Activity 进程的
  /// TCP 连接会断、传输中断（需求.MD 第 20 行「安卓后台不要断开」）。
  ///
  /// 传输结束或没有待发任务时应调用 [stopKeepAlive]：安卓 14+ 对 dataSync
  /// 类型的前台服务有累计时长限制，常开会被系统告警甚至停止。
  static Future<bool> startKeepAlive({
    String title = '雨传正在后台传输',
    String text = '保持连接，避免传输中断',
  }) async {
    if (!isAndroid) return false;
    return await _invoke<bool>('startKeepAlive', {
          'title': title,
          'text': text,
        }) ??
        false;
  }

  /// 停止前台服务。
  static Future<bool> stopKeepAlive() async {
    if (!isAndroid) return false;
    return await _invoke<bool>('stopKeepAlive') ?? false;
  }

  /// 前台服务当前是否在跑（用于状态自愈：进程被回收后服务可能已不在）。
  static Future<bool> isKeepAliveRunning() async {
    if (!isAndroid) return false;
    return await _invoke<bool>('isKeepAliveRunning') ?? false;
  }

  /// 通知权限是否已授予（Android 13 以下视为已授权）。
  static Future<bool> notificationsGranted() async {
    if (!isAndroid) return true;
    return await _invoke<bool>('notificationsGranted') ?? true;
  }

  /// 请求通知权限：只在用户点了引导卡上的「允许通知」后调用。
  static Future<void> requestNotifications() async {
    if (!isAndroid) return;
    await _invoke<bool>('requestNotifications');
  }

  /// 切换系统栏（状态栏/导航栏）图标深浅，跟随明暗主题。
  static Future<void> setSystemBarsLight(bool light) async {
    if (!isAndroid) return;
    await _invoke<bool>('setSystemBarsLight', light);
  }

  /// 显示/隐藏系统栏（true = 沉浸式隐藏）。
  static Future<void> setSystemBarsHidden(bool hidden) async {
    if (!isAndroid) return;
    await _invoke<bool>('setSystemBarsHidden', hidden);
  }

  /// 真实操作系统（与 [isAndroid] 一样走 dart:io）。
  ///
  /// 不用 `defaultTargetPlatform`：flutter_test 会把它默认为 android，
  /// 本轮测试要按宿主真实平台断言，用它会把断言变成空过。
  static TargetPlatform get _hostPlatform {
    if (Platform.isWindows) return TargetPlatform.windows;
    if (Platform.isMacOS) return TargetPlatform.macOS;
    return TargetPlatform.linux;
  }

  /// 桌面命令拼装（纯函数，便于测试）：三种语义互不相同。
  ///
  /// - 默认：用系统默认应用打开文件
  /// - `reveal`：在文件管理器中定位该文件
  /// - `openWith`：弹系统「打开方式」，由系统负责记「始终 / 仅一次」
  ///
  /// [os] 只为测试显式钉住分支（真机上不传，按 [_hostPlatform] 走）。
  @visibleForTesting
  static List<String> openCommand(String path,
      {bool reveal = false, bool openWith = false, TargetPlatform? os}) {
    switch (os ?? _hostPlatform) {
      case TargetPlatform.windows:
        if (reveal) return ['explorer.exe', '/select,', path];
        // 「打开方式」必须用 **W（Unicode）入口** `OpenAs_RunDLLW`。
        //
        // 实测对照（同一台机器、清场后各跑一次，看 rundll32 是否留在前台）：
        //   `shell32.dll,OpenAs_RunDLL`  → alive=false（**不弹**，瞬间退出）
        //   `shell32.dll,OpenAs_RunDLLW` → alive=true （对话框真的起来）
        // 含空格+中文的路径与纯 ASCII 路径结论一致 —— 所以这不是路径编码问题，
        // 是**入口点本身**的问题。这就是用户反馈「PC 端【打开方式】没有调起
        // 系统选择」的根因；ANSI 入口在 rundll32 下解析不到可用实现。
        //
        // 同时不再套 `cmd /c start`：多一层 shell 会重新解析命令行，
        // 带空格/中文的路径容易被切错，直接起进程最稳。
        if (openWith) {
          return ['rundll32.exe', 'shell32.dll,OpenAs_RunDLLW', path];
        }
        // 不能 Process.start(path)（那要求 path 本身可执行）；
        // cmd start 才会交给 shell 按文件关联打开，且能处理带空格的路径
        return ['cmd', '/c', 'start', '', path];
      case TargetPlatform.macOS:
        if (reveal) return ['open', '-R', path];
        if (openWith) return ['open', '-a', path];
        return ['open', path];
      default:
        return ['xdg-open', path];
    }
  }

  /// 把命令拼回一行，测试断言用的是哪条分支。
  @visibleForTesting
  static String describeOpenCommand(String path,
          {bool reveal = false, bool openWith = false, TargetPlatform? os}) =>
      openCommand(path, reveal: reveal, openWith: openWith, os: os).join(' ');

  /// 启动一条桌面命令。返回 null=成功，否则是错误文案。
  static Future<String?> _startCommand(List<String> argv) async {
    final hook = processStartHook;
    if (hook != null) return hook(argv.first, argv.sublist(1));
    try {
      await Process.start(argv.first, argv.sublist(1));
      return null;
    } catch (e) {
      return '$e';
    }
  }
  /// 用**系统默认应用**打开文件。
  /// Android：apk → 安装器，其余按扩展名找可打开的应用（FileProvider）。
  /// 桌面：交给文件关联（Windows `cmd start`）。返回 null 表示成功。
  ///
  /// 桌面旧实现在这里跑 `explorer /select` —— 「打开」被做成了「打开所在目录」
  /// （修 bug.md 第 8 行）；定位请用 [revealInFolder]。
  static Future<String?> openFile(String path) async {
    if (isAndroid) {
      return _invoke<String>('openFile', path);
    }
    return _startCommand(openCommand(path));
  }

  /// 弹系统「打开方式」选择器，由**系统 UI** 让用户选「仅一次 / 始终」。
  ///
  /// Windows：`rundll32 shell32.dll,OpenAs_RunDLL`（对话框自带
  /// 「始终使用此应用」勾选）；安卓：自建的候选应用窗口（见
  /// lib/ui/open_with_sheet.dart），因为 Android 11+ 的系统 ResolverActivity
  /// 对隐式 ACTION_VIEW 已不再提供「仅一次 / 始终」那组按钮。
  /// 返回 null=成功，否则是错误文案。
  static Future<String?> openWithDialog(String path) async {
    if (isAndroid) {
      return openFileWithChooser(path);
    }
    return _startCommand(openCommand(path, openWith: true));
  }

  /// 取 APK 的安装图标（写到缓存后的图片路径）；非 apk 或失败返回空串。
  ///
  /// 仅安卓有真实图标；桌面端返回空串，调用方退回类型图标。
  static Future<String> apkIconPath(String path) async {
    if (!isAndroid) return '';
    try {
      return await _invoke<String>('apkIcon', path) ?? '';
    } catch (_) {
      return '';
    }
  }
  /// 取走其他应用「分享」进来的内容（文字 + 文件路径），只取一次。
  ///
  /// 桌面端返回空值（没有分享通路）。
  static Future<({String text, List<String> files})> takeShared() async {
    if (!isAndroid) return (text: '', files: const <String>[]);
    try {
      final raw = await _invoke<Object?>('takeShared');
      final map = (raw as Map?)?.cast<String, dynamic>();
      return (
        text: map?['text']?.toString() ?? '',
        files: (map?['files'] as List?)?.map((e) => e.toString()).toList() ??
            const <String>[],
      );
    } catch (_) {
      return (text: '', files: const <String>[]);
    }
  }
  /// 安卓「打开方式」：弹出系统选择器，用户可选「仅一次 / 始终」。
  ///
  /// 桌面没有等价语义，直接退化为 [openFile]。
  static Future<String?> openFileWithChooser(String path) async {
    if (isAndroid) {
      return _invoke<String>('openFileWithChooser', path);
    }
    return openFile(path);
  }

  /// 能打开该文件的应用候选（自建「打开方式」窗口用）。
  ///
  /// 只安卓有；返回 package / label / isDefault / iconPng。桌面返回空列表
  /// （走系统「打开方式」程序列表，见 [openWithDialog]）。
  static Future<List<OpenWithApp>> listOpenWithApps(String path) async {
    if (!isAndroid) return const <OpenWithApp>[];
    try {
      final raw = await _invoke<List<Object?>>('listOpenWithApps', path);
      if (raw == null) return const <OpenWithApp>[];
      return raw
          .whereType<Map>()
          .map((e) => e.cast<Object?, Object?>())
          .map((m) => OpenWithApp(
                package: m['package']?.toString() ?? '',
                label: m['label']?.toString() ?? '',
                isDefault: m['isDefault'] == true,
                // 原生侧直接回 Uint8List；万一被序列化成 List<int> 也兼容
                iconPng: switch (m['icon']) {
                  final Uint8List b => b,
                  final List<Object?> l => Uint8List.fromList(
                      l.whereType<int>().toList(growable: false)),
                  _ => null,
                },
              ))
          .where((a) => a.package.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const <OpenWithApp>[];
    }
  }

  /// [openFileWithPackage] 返回这个常量表示：记忆的包名已不可用
  /// （应用被卸载 / 不再支持该类型），调用方应清除记忆并重新弹窗。
  static const String stalePackage = 'STALE_PACKAGE';

  /// 用**指定包名**的应用打开文件（配合自建窗口的「始终」记忆）。
  /// [package] 为空 = 系统默认应用。返回 null=成功，否则错误文案。
  static Future<String?> openFileWithPackage(String path, String package) async {
    if (!isAndroid) return openFile(path);
    try {
      await _invoke<bool>('openFileWithPackage', {
        'path': path,
        'package': package,
      });
      return null;
    } on PlatformException catch (e) {
      // 记忆的应用已不可用：调用方据此清除记忆并重新弹窗
      if (e.code == stalePackage) return stalePackage;
      return e.message ?? e.code;
    } catch (e) {
      return '$e';
    }
  }

  /// [revealInFolder] 在安卓上可能返回这个常量：目录落在应用私有区
  /// （`/data/...`、`Android/data`），外部文件管理器进不去。
  ///
  /// 现在它只表示「找不到可浏览的目录」；调用方（`AppState.revealFolder`）
  /// 把它转成一句中文失败提示，不再切到应用内「文件」TAB。
  static const String revealAppInternal = 'APP_INTERNAL';

  /// 打开所在文件夹：桌面 = 资源管理器定位到该文件；
  /// 安卓 = 交给原生打开**目录**（系统文件管理器浏览到它）。
  ///
  /// 安卓返回值：null=成功；[revealAppInternal]=目录在应用私有区；
  /// 其它 = 错误文案。
  static Future<String?> revealInFolder(String path) async {
    // 桌面：与「打开」不同的操作 —— 资源管理器 / Finder 定位到该文件
    if (!isAndroid) return _startCommand(openCommand(path, reveal: true));
    // 不用 _invoke：它会吞掉 PlatformException，把「没有可以浏览该目录的应用」
    // 这类失败误报成成功。
    try {
      return await _channel.invokeMethod<String>('revealFolder', path);
    } on MissingPluginException {
      return null; // 旧版原生没有该方法 → 按成功降级
    } on PlatformException catch (e) {
      return e.message ?? '打开所在文件夹失败';
    }
  }

  /// 把安卓 SAF 的 `content://…/tree/primary%3AYuChuan` 显示成可读路径
  /// `/storage/emulated/0/YuChuan`；非 SAF URI 或非安卓原样返回。
  static String describeTreeUri(String uri) {
    if (!isAndroid || !uri.startsWith('content://')) return uri;
    const marker = '/tree/';
    final i = uri.indexOf(marker);
    if (i < 0) return uri;
    final id = Uri.decodeComponent(uri.substring(i + marker.length));
    final sep = id.indexOf(':');
    if (sep < 0) return uri;
    final vol = id.substring(0, sep);
    final rest = id.substring(sep + 1);
    final base = vol == 'primary' ? '/storage/emulated/0' : '/storage/$vol';
    return rest.isEmpty ? base : '$base/$rest';
  }

  /// 安卓：把 SAF 目录树的读写授权持久化（选择目录后**立即**调用）。
  ///
  /// file_picker 不做这一步，临时授权会在进程结束/重启后失效，
  /// 届时收到的文件就再也写不进用户选的目录。
  /// 返回 null=成功，否则是错误文案。
  static Future<String?> takeTreePermission(String treeUri) async {
    if (!isAndroid) return null;
    try {
      await _channel.invokeMethod<bool>('takeTreePermission', treeUri);
      return null;
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      return e.message ?? '授权失败';
    }
  }

  /// 安卓：把 file_picker 返回的**真实路径**换成已持久化授权的
  /// SAF 树 URI（`content://…/tree/…`）。
  ///
  /// file_picker 在安卓选目录时会把树 URI 解析成真实路径返回，
  /// 授权信息丢了；它选完的瞬间选择器给的瞬时授权还在我们手里，
  /// 这里重建树 URI 并转成持久授权。返回 null=转换失败（保持原路径用，
  /// 由写入端兜底），否则是 `content://` 树 URI。
  static Future<String?> persistTreeForPath(String path) async {
    if (!isAndroid) return null;
    try {
      final uri = await _channel.invokeMethod<String>('persistTreeForPath', path);
      return (uri != null && uri.startsWith('content://')) ? uri : null;
    } on MissingPluginException {
      return null; // 旧版原生没有该方法 → 保持真实路径
    } on PlatformException {
      return null; // 瞬时授权已过期等 → 保持真实路径，写入失败时有横幅提示
    }
  }

  /// 安卓：把文件复制进用户选择的接收目录 —— `treeUri` 可以是 `content://`
  /// 树，也可以是**真实路径**（file_picker 选目录返回的就是真实路径，
  /// 原生会用它重建树 URI 并借用瞬时授权），`»` 分隔符还原成子目录，重名自动编号。
  ///
  /// Dart 的 `dart:io` 写不了 `content://`，必须走 DocumentsContract。
  /// 返回 null=成功，否则是错误文案。
  static Future<String?> archiveToTree({
    required String srcPath,
    required String treeUri,
    required String relPath,
    required String fileName,
  }) async {
    if (!isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('archiveToTree', {
        'src': srcPath,
        'tree': treeUri,
        'rel': relPath,
        'name': fileName,
      });
    } on MissingPluginException {
      return '原生未实现 archiveToTree';
    } on PlatformException catch (e) {
      return e.message ?? '归档失败';
    }
  }

  /// 公共「下载」目录里的应用子目录名（Android 上接收文件的默认落点）。
  ///
  /// 与用户可见路径 `Download/雨传` 对应；桌面端没有这个概念。
  static const String publicDownloadDirName = '雨传';

  /// 安卓：把文件写进公共 `Download/雨传`（Android 10+ 走 MediaStore）。
  ///
  /// 零存储权限（targetSdk 36）下这是唯一能被文件管理器直接看到的落点。
  /// 返回 null=成功；成功时若原生回传 `content://` URI（旧版原生或
  /// MediaStore 分配），也按成功处理 —— 判定只看有没有错误文案。
  /// 返回值语义：`(error, uri)`，两个字段只会有一个非空。
  static Future<({String? error, String? uri})> archiveToMediaStore({
    required String srcPath,
    required String relPath,
    required String fileName,
  }) async {
    if (!isAndroid) return (error: null, uri: null);
    try {
      final uri = await _channel.invokeMethod<String>('archiveToMediaStore', {
        'src': srcPath,
        'rel': relPath,
        'name': fileName,
      });
      return (error: null, uri: uri);
    } on MissingPluginException {
      return (error: '原生未实现 archiveToMediaStore', uri: null);
    } on PlatformException catch (e) {
      return (error: e.message ?? '写入公共下载目录失败', uri: null);
    }
  }

  /// 安卓：列出公共 `Download/雨传` 下的条目（含子目录 `rel`）。
  ///
  /// 返回字段：name / size / modified / mime / rel / path。
  /// 非安卓、旧版原生或 Android 9 及以下返回空列表（调用方回落真实路径扫盘）。
  static Future<List<Map<String, dynamic>>> listMediaStoreDir({
    String relPath = '',
  }) async {
    if (!isAndroid) return const <Map<String, dynamic>>[];
    try {
      final raw = await _channel.invokeMethod<Object?>('listMediaStoreDir', relPath);
      final list = (raw as List?) ?? const [];
      return list
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList(growable: false);
    } on MissingPluginException {
      return const <Map<String, dynamic>>[];
    } on PlatformException {
      return const <Map<String, dynamic>>[];
    }
  }

  /// 安卓：打开公共下载目录里的条目（真实路径或 `content://` 都接受）。
  /// 桌面端退化为 [openFile]。返回 null=成功，否则是错误文案。
  static Future<String?> openMediaDocument(String path) async {
    if (!isAndroid) return openFile(path);
    try {
      await _channel.invokeMethod<bool>('openMediaDocument', path);
      return null;
    } on MissingPluginException {
      return openFile(path);
    } on PlatformException catch (e) {
      return e.message ?? '打开失败';
    }
  }

  /// 安卓：公共收件目录 `Download/雨传` 的真实路径（设置页展示用）。
  ///
  /// 应用对公共下载目录没有 dart:io 权限，只能把「路径字符串」从原生取回来 ——
  /// 展示成用户实际能在文件管理器里看到的位置，而不是应用私有目录。
  /// 非安卓、旧版原生或取名失败返回 null（调用方回落到默认收件目录）。
  static Future<String?> publicDownloadPath() async {
    if (!isAndroid) return null;
    try {
      final path = await _channel.invokeMethod<String>('publicDownloadPath');
      return (path != null && path.isNotEmpty) ? path : null;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// 安卓：打开公共 `Download/雨传`（目录不存在时退到 Download）。
  /// 返回 null=成功；[revealAppInternal] 或错误文案由调用方转成提示。
  static Future<String?> revealPublicDownloadDir() async {
    if (!isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('revealPublicDownloadDir');
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      return e.message ?? '打开失败';
    }
  }

  /// 用系统浏览器打开链接（聊天里识别出的 URL / 关于页的主页链接）。
  static Future<String?> openUrl(String url) async {
    if (isAndroid) {
      return _invoke<String>('openUrl', url);
    }
    try {
      if (Platform.isWindows) {
        await Process.start(
            'cmd', ['/c', 'start', '', url.replaceAll('&', '^&')]);
      } else if (Platform.isMacOS) {
        await Process.start('open', [url]);
      } else {
        await Process.start('xdg-open', [url]);
      }
      return null;
    } catch (e) {
      return '$e';
    }
  }

  static Future<T?> _invoke<T>(String method, [dynamic args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
