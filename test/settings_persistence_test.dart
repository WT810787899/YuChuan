import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_flutter_ui/app_state.dart';
import 'package:rust_flutter_ui/appearance.dart';
import 'package:rust_flutter_ui/main.dart';
import 'package:rust_flutter_ui/ui/settings_page.dart';

/// 修 bug.md：「双端都没有记住主题深浅的设置，核查设置项都有没有持久化，并修复」。
///
/// 覆盖三类回归：
///   1) 显示模式（跟随系统/浅色/深色）必须写进 appearance.json，重启能读回；
///   2) 自动接收 / 限速 / 虚拟网卡过滤必须写进 prefs.json，重启能读回；
///   3) 设置页那条 UI 路径（SegmentedButton「深色」）必须真的走持久化接口，
///      而不是只改内存里的 notifier。
///
/// AppearanceState / AppState 都是进程内单例，没有「新建实例」这条路：
/// 每个用例注入自己的临时目录，tearDown 里把目录摘掉并复位改过的值。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('settings_persist_');
    AppearanceState.instance.attachDataDir(dir.path);
    AppState.instance.attachPrefsDir(dir.path);
  });

  tearDown(() {
    // 空串 = 不落盘（_file/_prefsFile 都返回 null），摘掉临时目录，
    // 免得同文件后续用例把文件写进已经删掉的目录。
    AppearanceState.instance.attachDataDir('');
    AppearanceState.instance.setThemeMode(ThemeMode.system);
    AppState.instance.attachPrefsDir('');
    AppState.instance.autoAcceptFiles = true;
    AppState.instance.speedLimitMb = 0;
    AppState.instance.filterVirtualNic = true;
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  File appearanceFile(Directory d) =>
      File('${d.path}${Platform.pathSeparator}appearance.json');

  File prefsFile(Directory d) =>
      File('${d.path}${Platform.pathSeparator}prefs.json');

  /// 读落盘 JSON。文件不存在直接判失败 —— 本任务的核心就是「必须写盘」。
  Map<String, dynamic> readJson(File f) {
    expect(f.existsSync(), isTrue,
        reason: '设置项没有落盘：${f.path} 不存在');
    return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  }

  test('显示模式：选深色写入 appearance.json，模拟重启后读回仍是深色', () {
    AppearanceState.instance.setThemeMode(ThemeMode.dark);

    final raw = readJson(appearanceFile(dir));
    expect(raw['themeMode'], 'dark',
        reason: 'appearance.json 必须记录显示模式，否则重启就丢');

    // 模拟重启 = 换一个数据目录，把刚才那份 JSON 原样放进去再注入。
    final dir2 = Directory.systemTemp.createTempSync('settings_persist2_');
    addTearDown(() => dir2.deleteSync(recursive: true));
    appearanceFile(dir2).writeAsStringSync(jsonEncode(raw));
    // 先把内存值摆回默认：单例若还留着 dark，下面那条断言会自己骗自己。
    AppearanceState.instance.setThemeMode(ThemeMode.system);
    AppearanceState.instance.attachDataDir(dir2.path);

    expect(AppearanceState.instance.themeMode, ThemeMode.dark);
  });

  test('显示模式：缺失或损坏的 themeMode 回落「跟随系统」', () {
    AppearanceState.instance.setThemeMode(ThemeMode.dark);
    // 覆盖成损坏值（setThemeMode 会写盘，所以必须放在它之后）
    appearanceFile(dir).writeAsStringSync(jsonEncode({'themeMode': '???'}));
    AppearanceState.instance.attachDataDir(dir.path);

    expect(AppearanceState.instance.themeMode, ThemeMode.system);
  });

  test('载入深色显示模式后生效的是深色那套外观快照', () {
    final a = AppearanceState.instance;
    a.setDarkLook(false);
    a.setSeedColor(const Color(0xFF112233)); // 浅色那套
    a.setDarkLook(true);
    a.setSeedColor(const Color(0xFF445566)); // 深色那套
    a.setThemeMode(ThemeMode.dark);
    expect(a.seedColor.toARGB32(), 0xFF445566);

    // 模拟重启：内存摆回浅色一套，再重新注入同一目录。
    a.setDarkLook(false);
    a.attachDataDir(dir.path);

    expect(a.themeMode, ThemeMode.dark);
    expect(a.seedColor.toARGB32(), 0xFF445566,
        reason: '载入深色模式后必须用 _darkLook 那套，而不是浅色那套');
  });

  test('启动顺序：先按系统亮度同步再载入落盘值，载入后不再多余落盘', () {
    final a = AppearanceState.instance;
    // 落盘：浅色那套外观 + 显示模式 light
    a.setDarkLook(false);
    a.setSeedColor(const Color(0xFF112233));
    a.setDarkLook(true);
    a.setSeedColor(const Color(0xFF445566));
    a.setThemeMode(ThemeMode.light);

    // ---- 模拟 main() 的真实启动顺序 ----
    // ① 进程刚起来：notifier 还是初值 system（系统亮度是深色，与存下的 light 不同）
    themeModeNotifier.value = ThemeMode.system;
    var calls = 0;
    void syncLikeMain() {
      calls++;
      a.setDarkLook(themeModeNotifier.value == ThemeMode.dark);
    }

    themeModeNotifier.addListener(syncLikeMain);
    addTearDown(() => themeModeNotifier.removeListener(syncLikeMain));

    // ② runApp 之后 main 先做的那次同步（system + 系统深色 → 深色外观）
    a.setDarkLook(true);

    // ③ 数据目录就绪前的窗口期：塞一个本实现不认识的键。任何一次 _save() 都会
    //    把整份文件重写，所以它能不能活下来 = 载入之后有没有发生多余落盘。
    final file = appearanceFile(dir);
    final map = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    map['unknownFutureKey'] = 'keep-me';
    file.writeAsStringSync(jsonEncode(map));

    // ④ loadPairingStore() 里注入数据目录 → _load() 读到 light
    a.attachDataDir(dir.path);
    // ⑤ 载入完成后再灌 notifier（main 里 .then 的那一步）
    applyLoadedThemeMode();

    expect(calls, 1,
        reason: '载入把 notifier 从 system 推到 light，监听者应恰好被叫一次');
    expect(themeModeNotifier.value, ThemeMode.light);
    expect(a.seedColor.toARGB32(), 0xFF112233,
        reason: '存的是浅色、系统是深色：最终必须套浅色那套外观，'
            '不能被启动时那次「按系统亮度」的同步覆盖掉');
    final after = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    expect(after['unknownFutureKey'], 'keep-me',
        reason: '载入完成后不该再落盘：多余的一次 _save() 会把文件整份重写；'
            '真有这次写入，就说明顺序把刚载入的外观快照又冲了一遍');
  });

  test('自动接收：单独调用也必须立刻落盘', () {
    // 只调这一个 setter：prefs.json 里就该只剩它改过。
    // （若和另外两个 setter 混在一个用例里，后两次的 _savePrefs 会把整份文件
    //   重写，把「本 setter 压根没落盘」这个 bug 掩盖掉 —— 实测踩过。）
    AppState.instance.setAutoAcceptFiles(false);
    expect(readJson(prefsFile(dir))['autoAccept'], isFalse);
  });

  test('限速：单独调用也必须立刻落盘', () {
    AppState.instance.setSpeedLimitMb(12);
    expect(readJson(prefsFile(dir))['speedLimitMb'], 12);
  });

  test('自动接收 / 限速 / 虚拟网卡过滤：三个字段都能读回', () async {
    AppState.instance.setAutoAcceptFiles(false);
    AppState.instance.setSpeedLimitMb(12);
    await AppState.instance.setFilterVirtualNic(false);

    final raw = readJson(prefsFile(dir));
    expect(raw['autoAccept'], isFalse);
    expect(raw['speedLimitMb'], 12);
    expect(raw['filterVirtualNic'], isFalse);

    // 模拟重启：先把内存值摆回默认（否则「读回」断言是废话），再重新注入目录。
    AppState.instance.autoAcceptFiles = true;
    AppState.instance.speedLimitMb = 0;
    AppState.instance.filterVirtualNic = true;
    AppState.instance.attachPrefsDir(dir.path);

    expect(AppState.instance.autoAcceptFiles, isFalse);
    expect(AppState.instance.speedLimitMb, 12);
    expect(AppState.instance.filterVirtualNic, isFalse);
  });

  testWidgets('设置页「深色」按钮：走持久化接口，落盘且同步全局 notifier',
      (tester) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SettingsPage())));
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.text('深色'));
    await tester.pump(const Duration(milliseconds: 200));

    // 两条都断言：只改 notifier 不落盘 = 重启丢；只落盘不改 notifier = 界面不跟手。
    expect(themeModeNotifier.value, ThemeMode.dark);
    expect(readJson(appearanceFile(dir))['themeMode'], 'dark',
        reason: '设置页点「深色」必须写进 appearance.json');
  });
}
