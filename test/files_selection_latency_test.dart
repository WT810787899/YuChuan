import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rust_flutter_ui/appearance.dart';
import 'package:rust_flutter_ui/services/transfer_service.dart';
import 'package:rust_flutter_ui/ui/files_page.dart';

/// 文件卡片选中要跟手（修 bug.md #5：选中反应不跟手，慢）：
/// 每帧 build 不再做 statSync/lengthSync —— 磁盘元数据在扫盘时缓存一次。
///
/// flutter test 里 Rust 桥没起，downloadDir() 会抛 —— 用
/// [TransferService.downloadDirOverride] 注入收件目录（同
/// `mobile_receive_reveal_test.dart` 的写法）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('yuchuan_files_cache_');
    TransferService.downloadDirOverride = () => dir.path;
  });

  tearDown(() {
    TransferService.downloadDirOverride = null;
    AppearanceState.instance.setReceiveDir(null);
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('选中触发的重建不再读磁盘元数据', (tester) async {
    // 放大测试窗口：30 个瓦片必须全部可见，否则 tap 落空会让用例白过
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    for (var i = 0; i < 30; i++) {
      File('${dir.path}${Platform.pathSeparator}f$i.txt')
          .writeAsStringSync('x' * (i + 1));
    }

    // 探针：只数扫盘期间的元数据读取（唯一为测试加的口子）
    var reads = 0;
    FilesPage.statProbe = (f) {
      reads++;
      return f.statSync();
    };
    addTearDown(() => FilesPage.statProbe = null);

    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: FilesPage())));
    await tester.pump(const Duration(milliseconds: 300));

    expect(reads, greaterThan(0), reason: '扫盘时应当读过元数据');
    expect(find.text('f29.txt'), findsOneWidget);

    // 选中最新那个（timeDesc 下必然可见）：本次 setState 后 build 不应再读盘。
    // 注意：瓦片同时挂了 onTap 与 onDoubleTap，单击要等双击判定超时（~300ms）
    // 才会真正回调，这里必须 pump 足够久，否则点击落空会让用例白过。
    final before = reads;
    await tester.tap(find.text('f29.txt'));
    await tester.pump(const Duration(milliseconds: 400));

    // 先确认选中真的生效了，否则下面那条断言会「因为没点中」而白过
    expect(find.text('已选 1'), findsOneWidget, reason: '点击必须真的选中了文件');

    expect(reads, before, reason: '选中触发的重建不能再读磁盘元数据');
  });
}
