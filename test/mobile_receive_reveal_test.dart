import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rust_flutter_ui/appearance.dart';
import 'package:rust_flutter_ui/services/transfer_service.dart';
import 'package:rust_flutter_ui/ui/files_page.dart';

/// 安卓接收目录 bug 的回归（修 bug.md #2）：
/// 1. file_picker 在安卓上返回的是 SAF `content://` URI，Dart 的 Directory
///    打不开 —— 此时「文件」TAB 必须回落到默认收件目录，不能一片空白；
/// 2. 自定义接收目录可读时，必须按它列出，不能误回落。
///
/// flutter test 里 Rust 桥没起，downloadDir() 会抛 —— 用
/// [TransferService.downloadDirOverride] 注入默认收件目录。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory defaultDir;
  late Directory customDir;

  setUp(() {
    defaultDir = Directory.systemTemp.createTempSync('yuchuan_default_');
    customDir = Directory.systemTemp.createTempSync('yuchuan_custom_');
    TransferService.downloadDirOverride = () => defaultDir.path;
  });

  tearDown(() {
    TransferService.downloadDirOverride = null;
    AppearanceState.instance.setReceiveDir(null);
    for (final d in [defaultDir, customDir]) {
      try {
        d.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  Future<void> pumpFiles(WidgetTester tester) async {
    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: FilesPage())));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('content:// 接收目录打不开时，回落到默认收件目录列出文件', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    File('${defaultDir.path}${Platform.pathSeparator}probe_reveal_123.txt')
        .writeAsStringSync('x');
    // 安卓上 file_picker 选目录得到的就是这种 URI（Dart 打不开）
    AppearanceState.instance.setReceiveDir(
        'content://com.android.externalstorage.documents/tree/primary%3ADebug');

    await pumpFiles(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('probe_reveal_123.txt'), findsOneWidget,
        reason: 'content:// 目录不可读时必须回落默认收件目录，文件 TAB 不能空白');
  });

  testWidgets('自定义接收目录可读时按它列出，不误回落', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    File('${customDir.path}${Platform.pathSeparator}custom_only.txt')
        .writeAsStringSync('x');
    File('${defaultDir.path}${Platform.pathSeparator}default_only.txt')
        .writeAsStringSync('x');
    AppearanceState.instance.setReceiveDir(customDir.path);

    await pumpFiles(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('custom_only.txt'), findsOneWidget);
    expect(find.text('default_only.txt'), findsNothing,
        reason: '自定义目录可读时不能回落到默认收件目录');
  });

  testWidgets('接收目录被删除后回落，不崩', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final gone = '${customDir.path}${Platform.pathSeparator}not_here';
    File('${defaultDir.path}${Platform.pathSeparator}still_here.txt')
        .writeAsStringSync('x');
    AppearanceState.instance.setReceiveDir(gone); // 目录不存在

    await pumpFiles(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('still_here.txt'), findsOneWidget,
        reason: '自定义目录被删后应回落默认收件目录');
  });
}
