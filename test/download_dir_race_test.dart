import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_flutter_ui/services/chat_service.dart';
import 'package:rust_flutter_ui/services/transfer_service.dart';
import 'package:rust_flutter_ui/src/rust/frb_generated.dart';

/// 回归：收件目录缓存**不能**被启动竞态冻死。
///
/// 现场现象：`main.dart` 的预热跑在 `messages_open` 之前 → Rust 侧还没注册
/// DOWNLOAD_ROOT → `transfer_download_dir()` 回落到系统临时目录。旧实现把它
/// 当成最终值缓存，且没有任何地方再刷新（`TransferService.init()` 在生产代码
/// 里没有调用者）→ 收件目录查找 / 文件 TAB / 「打开文件」全部指向错目录，
/// 用户看到的就是「文件还没能接收完成」和空白的文件列表。
///
/// 修复后：仓库打开前探到的值不置锁存，`downloadDir()` 按节流重探，
/// 仓库打开后自然落到真正的 `<数据目录>/chat/downloads`。
void main() {
  setUpAll(() async {
    await RustLib.init(externalLibrary: _nativeLibrary());
  });

  test('messages_open 之前探测不锁存，打开后 downloadDir 必须自愈', () async {
    final dataDir =
        Directory.systemTemp.createTempSync('lanchat_dl_race').path;
    final sep = Platform.pathSeparator;
    final expected = _norm('$dataDir${sep}chat${sep}downloads');

    // 1) 模拟启动竞态：消息仓库还没打开就预热（旧实现会把 temp 值冻住）
    await TransferService.instance.warmDownloadDir();
    final before = TransferService.instance.downloadDir();
    expect(_norm(before), isNot(expected),
        reason: '仓库未打开时不可能拿到真实收件目录，实际：$before');

    // 2) 打开消息仓库（Rust 侧此刻才注册 DOWNLOAD_ROOT）
    await ChatService.instance.openStore(dataDir);
    expect(ChatService.instance.storeOpened, isTrue);

    // 3) downloadDir() 必须自愈到真实收件目录（节流补探在后台完成）
    await _waitUntil(
      () => _norm(TransferService.instance.downloadDir()) == expected,
      reason: 'downloadDir 必须自愈到 $expected，'
          '实际：${TransferService.instance.downloadDir()}',
    );

    expect(_norm(TransferService.instance.downloadDir()), isNot(_norm(before)),
        reason: '自愈后的目录必须与竞态期间的兜底值不同');
    // 收件目录必须真实存在（Dart 与 Rust 对同一条路径达成一致）
    expect(Directory(TransferService.instance.downloadDir()).existsSync(),
        isTrue,
        reason: '收件目录应真实存在');
  });
}

String _norm(String p) =>
    p.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '').toLowerCase();

Future<void> _waitUntil(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 10),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
  fail(reason ?? '等待条件超时');
}

ExternalLibrary _nativeLibrary() {
  if (Platform.isWindows) {
    // 必须优先用 rust_builder 刚编出来的那份：build/ 下的是上一次 Windows
    // 构建留下的陈旧副本，加载它会导致 frb 内容哈希不一致（Dart/Rust 侧对不上）。
    final candidates = [
      'rust_builder/target/release/rust_flutter_ui_native.dll',
      'build/windows/x64/runner/Release/rust_flutter_ui_native.dll',
    ];
    for (final candidate in candidates) {
      final file = File(candidate);
      if (file.existsSync()) return ExternalLibrary.open(file.absolute.path);
    }
    fail('找不到 rust_flutter_ui_native.dll，请先运行 scripts/build_windows.ps1');
  }
  return ExternalLibrary.open('librust_flutter_ui_native.so');
}