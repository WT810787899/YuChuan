import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rust_flutter_ui/appearance.dart';
import 'package:rust_flutter_ui/services/platform_channel.dart';
import 'package:rust_flutter_ui/services/transfer_service.dart';
import 'package:rust_flutter_ui/ui/settings_page.dart';

/// 设置页「接收目录」必须显示**真实落点**。
///
/// 安卓没设自定义目录时落点是公共 `Download/雨传`（MediaStore），不是应用
/// 私有收件目录。显示私有目录会误导用户按界面上的路径去文件管理器里找
/// （永远找不到），「打开」按钮也会指到另一处。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('yuchuan/platform');
  const publicPath = '/storage/emulated/0/Download/雨传';

  setUp(() {
    YuChuanPlatform.isAndroidOverride = true;
    TransferService.downloadDirOverride =
        () => '/data/user/0/com.yuchuan.app/files/chat/downloads';
    AppearanceState.instance.setReceiveDir(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'publicDownloadPath') return publicPath;
      return null;
    });
  });

  tearDown(() {
    YuChuanPlatform.isAndroidOverride = null;
    TransferService.downloadDirOverride = null;
    AppearanceState.instance.setReceiveDir(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('安卓未设自定义目录时显示公共 Download/雨传，不显示私有目录',
      (tester) async {
    // 用宽屏分栏布局：传输分区默认可见，不必点导航
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: SettingsPage())));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('传输').last);
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Download'), findsWidgets,
        reason: '接收目录必须显示公共落点，实际界面里找不到 Download');
    expect(find.textContaining('/data/user/0/'), findsNothing,
        reason: '用户看不到的私有目录不应作为默认接收目录展示');
  });
}