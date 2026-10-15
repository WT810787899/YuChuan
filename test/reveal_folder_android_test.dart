import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rust_flutter_ui/app_state.dart';
import 'package:rust_flutter_ui/appearance.dart';
import 'package:rust_flutter_ui/services/platform_channel.dart';

/// 安卓「打开所在文件夹」必须进系统文件管理器的**真实目录**，
/// 不能回一句「该文件在应用内部目录」（修 bug.md 第 7、12 行：
/// 文件 TAB 与聊天窗文件气泡菜单两处反馈的都是同一个 bug）。
///
/// 根因：`AppState.revealFolder` 把应用私有副本的路径交给原生，原生判定
/// 私有区后回 `APP_INTERNAL`，Dart 只能切到应用内「文件」TAB 或报内部目录。
/// 但安卓上文件早已归档到公共落点（`Download/雨传` / 用户选的接收目录），
/// 那才是用户在文件管理器里真正能看到的位置。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('yuchuan/platform');
  final calls = <String>[];
  final args = <Object?>[];

  setUp(() {
    calls.clear();
    args.clear();
    YuChuanPlatform.isAndroidOverride = true;
    AppearanceState.instance.setReceiveDir(null); // 未设自定义目录
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      args.add(call.arguments);
      // revealFolder / revealPublicDownloadDir 的返回类型是 String?
      // （null = 原生已打开）；返回非字符串会触发类型转换异常，
      // 把「接线错了」这件事掩盖成一个 cast 报错。
      return null;
    });
  });

  tearDown(() {
    YuChuanPlatform.isAndroidOverride = null;
    AppearanceState.instance.setReceiveDir(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// 应用私有收件目录里的文件：外部文件管理器进不去。
  const privatePath =
      '/data/user/0/com.yuchuan.app/files/chat/downloads/a.txt';

  test('安卓未设自定义目录 + 私有路径：走公共 Download/雨传，不把私有路径交给原生',
      () async {
    final msg = await AppState.instance.revealFolder(privatePath);

    expect(calls, contains('revealPublicDownloadDir'),
        reason: '文件的对外落点是公共 Download/雨传，必须让原生打开它');
    expect(calls, isNot(contains('revealFolder')),
        reason: '私有副本路径不能直接交给原生 —— 那样只会回 APP_INTERNAL，'
            '用户看到的就是「在应用内部不能打开」');
    expect(msg, contains('已打开'));
    expect(msg, isNot(contains('内部')),
        reason: '这条提示正是用户投诉的那句，不能再出现');
  });

  test('安卓设了自定义接收目录 + 私有路径：打开那棵树，不问公共目录', () async {
    const tree =
        'content://com.android.externalstorage.documents/tree/primary%3AYuChuan';
    AppearanceState.instance.setReceiveDir(tree);

    final msg = await AppState.instance.revealFolder(privatePath);

    expect(calls, contains('revealFolder'),
        reason: '用户自选的接收目录里有一份副本，打开它才符合用户预期');
    expect(args, contains(tree),
        reason: '交给原生的必须是自定义接收目录本身，不是私有路径');
    expect(calls, isNot(contains('revealPublicDownloadDir')),
        reason: '设了自定义目录就不该再打开公共 Download/雨传（用户已经改过落点）');
    expect(msg, contains('已打开'));
  });

  test('安卓路径本身在公共存储：常规定位到该文件，不改道公共目录', () async {
    const publicFile = '/storage/emulated/0/Download/x/a.txt';

    final msg = await AppState.instance.revealFolder(publicFile);

    expect(calls, contains('revealFolder'));
    expect(args, contains(publicFile),
        reason: '公共路径要原样交给原生定位，不能被替换成别的目录');
    expect(calls, isNot(contains('revealPublicDownloadDir')),
        reason: '路径本身外部可进时不需要绕道公共收件目录');
    expect(msg, contains('已打开'));
  });

  test('安卓设了自定义接收目录 + 公共路径：仍定位文件本身，不改道接收目录', () async {
    // 这是 review 抓到的回归组合：自定义目录分支若不门控 `_insideAppPrivate`，
    // 「自己发出的文件」（filePath = 公共源路径）会被送到接收目录树，
    // 而用户要的是文件**自己**所在处。
    const tree =
        'content://com.android.externalstorage.documents/tree/primary%3AYuChuan';
    AppearanceState.instance.setReceiveDir(tree);
    const publicFile = '/storage/emulated/0/Download/x/a.txt';

    final msg = await AppState.instance.revealFolder(publicFile);

    expect(calls, contains('revealFolder'),
        reason: '公共路径外部进得去，必须交给原生定位它自己');
    expect(args, contains(publicFile),
        reason: '自定义接收目录不能劫持公共路径 —— 该文件不在接收目录里');
    expect(args, isNot(contains(tree)),
        reason: '接收目录树不能顶替文件自己的路径');
    expect(calls, isNot(contains('revealPublicDownloadDir')),
        reason: '也不是打开公共收件目录');
    expect(msg, contains('已打开'));
  });

  test('原生报错时回「打开失败：…」，不吞成成功文案', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      throw PlatformException(
          code: 'NO_HANDLER', message: '没有可以浏览该目录的应用');
    });

    final msg = await AppState.instance.revealFolder(privatePath);

    expect(calls, contains('revealPublicDownloadDir'));
    expect(msg, contains('打开失败'),
        reason: '原生明确失败时必须如实告知，不能报成功让用户去空等');
    expect(msg, contains('没有可以浏览该目录的应用'));
  });

  test('原生仍回 APP_INTERNAL（存储没挂载等）：转成中文失败，不漏内部哨兵值', () async {
    // 公共目录定位不到时原生还会回 APP_INTERNAL。旧代码拿它当「切到应用内
    // 文件 TAB」的信号（用户投诉的那句）；现在只该是一条中文失败提示，
    // 绝不能把 APP_INTERNAL 这个内部常量原样塞进给用户看的提示语。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return 'APP_INTERNAL';
    });

    final msg = await AppState.instance.revealFolder(privatePath);

    expect(msg, contains('打开失败'));
    expect(msg, isNot(contains('APP_INTERNAL')),
        reason: '内部哨兵值不该出现在面向用户的提示语里');
    expect(AppState.instance.navIndex, isNot(3),
        reason: '不能再偷偷把用户切到应用内「文件」TAB');
  });
}
