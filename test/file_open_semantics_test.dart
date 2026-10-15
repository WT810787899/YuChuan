import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rust_flutter_ui/services/platform_channel.dart';

/// 修 bug.md：
/// - 「PC端打开文件直接调用系统默认应用打开，不是打开所在目录——对于双击和菜单项的打开」
/// - 「菜单『打开方式』要有【始终/仅一次】的默认记忆」（交给系统对话框，见 openWithDialog）
///
/// 旧实现里 Windows 的 `openFile` 也跑 `explorer.exe /select,<path>` ——
/// 打开文件和定位目录成了同一个动作，用户看到的永远是「打开了所在目录」。
///
/// 非空洞性：`openFile` / `revealInFolder` / `openWithDialog` 三个方法都经
/// [YuChuanPlatform.openCommand] 拼命令，所以下面断言的就是生产代码真正跑的那条
/// 分支。谁把 `openFile` 改回 `/select`，第一条用例立刻红。
///
/// 平台不能靠真实 `Platform.isWindows` 断言（换台机器就白过）—— 用 `os:`
/// 参数显式钉住每条分支，再补一条当前宿主平台的端到端断言。
void main() {
  // 安卓分支要装 mock channel 处理器，必须先起测试 binding
  TestWidgetsFlutterBinding.ensureInitialized();

  const p = r'C:\tmp\a.txt';
  const launcherProbe = r'C:\tmp\一个 带空格的文件.txt';

  String win(String path) => YuChuanPlatform.describeOpenCommand(path,
      reveal: false, openWith: false, os: TargetPlatform.windows);
  String winReveal(String path) => YuChuanPlatform.describeOpenCommand(path,
      reveal: true, openWith: false, os: TargetPlatform.windows);
  String winOpenWith(String path) => YuChuanPlatform.describeOpenCommand(path,
      reveal: false, openWith: true, os: TargetPlatform.windows);

  group('Windows：三种语义互不相同', () {
    test('打开 = 系统默认应用（cmd start），绝不能是 explorer /select', () {
      final cmd = win(p);
      expect(cmd, contains('start'),
          reason: '打开文件必须交给 shell 按关联程序打开');
      expect(cmd, isNot(contains('/select')),
          reason: '旧 bug：打开被实现成了 explorer /select 定位目录');
      expect(cmd, isNot(contains('explorer')),
          reason: '打开文件不该出现资源管理器');
    });

    test('定位 = explorer /select（与打开不是同一条命令）', () {
      final cmd = winReveal(p);
      expect(cmd, contains('/select'));
      expect(cmd, isNot(contains('OpenAs_RunDLL')));
      expect(cmd, isNot(equals(win(p))),
          reason: '打开与定位必须是两个不同操作（旧实现两者同一条命令）');
    });

    test('打开方式 = rundll32 OpenAs_RunDLL（自带「始终使用此应用」勾选）', () {
      final cmd = winOpenWith(p);
      expect(cmd, contains('OpenAs_RunDLL'));
      expect(cmd, isNot(contains('/select')));
      expect(cmd, isNot(equals(win(p))));
      expect(cmd, isNot(equals(winReveal(p))));
    });

    test('带空格的路径整段作为一个参数传给 cmd start', () {
      final argv = YuChuanPlatform.openCommand(launcherProbe,
          os: TargetPlatform.windows);
      expect(argv.last, launcherProbe,
          reason: '空格路径必须整段成一个 argv，交给 Process.start 时才不会截断');
      expect(argv.contains('start'), isTrue);
    });
  });

  group('macOS / Linux：分支同样可断言', () {
    test('macOS 打开=open；定位=open -R；打开方式=open -a', () {
      expect(
          YuChuanPlatform.describeOpenCommand(p, os: TargetPlatform.macOS),
          'open $p');
      expect(
          YuChuanPlatform.describeOpenCommand(p,
              reveal: true, os: TargetPlatform.macOS),
          'open -R $p');
      expect(
          YuChuanPlatform.describeOpenCommand(p,
              openWith: true, os: TargetPlatform.macOS),
          'open -a $p');
    });

    test('Linux 三种语义都退化为 xdg-open 且不出现 Windows 命令', () {
      final open =
          YuChuanPlatform.describeOpenCommand(p, os: TargetPlatform.linux);
      final reveal = YuChuanPlatform.describeOpenCommand(p,
          reveal: true, os: TargetPlatform.linux);
      final openWith = YuChuanPlatform.describeOpenCommand(p,
          openWith: true, os: TargetPlatform.linux);
      for (final cmd in [open, reveal, openWith]) {
        expect(cmd, startsWith('xdg-open'));
        expect(cmd, isNot(contains('/select')));
        expect(cmd, isNot(contains('OpenAs_RunDLL')));
      }
    });
  });

  test('不传 os 时按真实宿主平台拼命令（本机 = Windows 时须与显式一致）', () {
    final host = YuChuanPlatform.describeOpenCommand(p);
    if (Platform.isWindows) {
      expect(host, contains('start'));
      expect(host, isNot(contains('/select')));
      expect(host, equals(win(p)));
      expect(YuChuanPlatform.describeOpenCommand(p, reveal: true),
          equals(winReveal(p)));
      expect(YuChuanPlatform.describeOpenCommand(p, openWith: true),
          equals(winOpenWith(p)));
    } else {
      // 非 Windows 宿主：至少必须真的落到某条已知启动器，而不是空串
      expect(host, isNotEmpty);
    }
  });

  group('安卓：三个方法各自打到不同的原生方法', () {
    const channel = MethodChannel('yuchuan/platform');
    final calls = <String>[];

    setUp(() {
      calls.clear();
      YuChuanPlatform.isAndroidOverride = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return null; // 全部按成功处理
      });
    });

    tearDown(() {
      YuChuanPlatform.isAndroidOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('openFile / revealInFolder 走两条不同通道', () async {
      expect(await YuChuanPlatform.openFile(p), isNull);
      expect(calls, contains('openFile'));

      calls.clear();
      expect(await YuChuanPlatform.revealInFolder(p), isNull);
      expect(calls, contains('revealFolder'));
    });

    test('openWithDialog 仍打到原生（旧接口保留，但 UI 已改走自建窗口）', () async {
      calls.clear();
      expect(await YuChuanPlatform.openWithDialog(p), isNull);
      expect(calls, contains('openFileWithChooser'));
    });

    test('listOpenWithApps / openFileWithPackage 支撑自建窗口与「始终」记忆', () async {
      calls.clear();
      await YuChuanPlatform.listOpenWithApps(p);
      expect(calls, contains('listOpenWithApps'));

      calls.clear();
      expect(await YuChuanPlatform.openFileWithPackage(p, 'com.x.y'), isNull);
      expect(calls, contains('openFileWithPackage'));
    });
  });

  group('PC「打开方式」必须真的弹出系统程序列表', () {
    // 实测对照（同一台机器、清场后各跑一次，看 rundll32 是否留在前台）：
    //   `shell32.dll,OpenAs_RunDLL`  → alive=false（**不弹**，瞬间退出）
    //   `shell32.dll,OpenAs_RunDLLW` → alive=true （对话框真的起来）
    // 含空格+中文路径与纯 ASCII 路径结论一致 ⇒ 是**入口点**的问题，
    // 不是路径编码问题。这就是用户反馈「PC 端【打开方式】没有调起系统选择」。
    test('Windows openWith 走 rundll32 + OpenAs_RunDLLW（Unicode 入口）', () {
      final argv = YuChuanPlatform.openCommand(p,
          openWith: true, os: TargetPlatform.windows);
      expect(argv.first, 'rundll32.exe',
          reason: '直接起 rundll32，不要再套 cmd/start（多一层 shell 会重解析命令行，'
              '带空格/中文的路径容易被切错）');
      expect(argv, contains('shell32.dll,OpenAs_RunDLLW'),
          reason: '必须用 W（Unicode）入口：ANSI 的 OpenAs_RunDLL 实测不弹');
      expect(argv, isNot(contains('shell32.dll,OpenAs_RunDLL')),
          reason: 'ANSI 入口不弹，不能再用');
      // 逗号形式必须是**一个**参数，不能被拆开
      expect(argv.last, p, reason: '文件路径必须是最后一个参数');
    });

    test('Windows 普通「打开」仍是 cmd /c start（不能被 OpenAs 污染）', () {
      final argv = YuChuanPlatform.openCommand(p, os: TargetPlatform.windows);
      expect(argv.first, 'cmd');
      expect(argv, isNot(contains('rundll32.exe')));
      expect(argv.last, p);
    });
  });
}
