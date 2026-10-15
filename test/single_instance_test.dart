import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rust_flutter_ui/services/single_instance.dart';

void main() {
  test('单实例交接：清单送达运行中的实例并拿到 OK', () async {
    final received = <String>[];
    final infoFile =
        File('${Directory.systemTemp.path}\\yuchuan_test_instance.json');
    final server = await SingleInstance.startControlServer(
      onShare: received.addAll,
      writeInfoFile: true,
      infoFile: infoFile,
    );
    expect(server, isNotNull);

    final ok = await SingleInstance.handoffToRunningInstance(
      ['D:\\a.mp4', 'D:\\b.txt'],
      infoFile: infoFile,
    );
    expect(ok, isTrue);
    expect(received, ['D:\\a.mp4', 'D:\\b.txt']);

    await server!.close();
    try {
      infoFile.deleteSync();
    } catch (_) {}
  });

  test('单实例交接：没有运行中实例时按失败返回（照常启动）', () async {
    final infoFile =
        File('${Directory.systemTemp.path}\\yuchuan_test_instance_missing.json');
    final ok = await SingleInstance.handoffToRunningInstance(
      ['D:\\a.mp4'],
      infoFile: infoFile,
    );
    expect(ok, isFalse);
  });
}
