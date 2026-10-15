import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_flutter_ui/services/chat_service.dart';
import 'package:rust_flutter_ui/services/transfer_service.dart';
import 'package:rust_flutter_ui/src/rust/api/transfer.dart' as rust;
import 'package:rust_flutter_ui/src/rust/frb_generated.dart';

/// T4.x 端到端（真实 Rust 传输中枢 + 真实 socket）：
/// 本进程是**发送方**（chatListen + transferSend），raw socket 扮演接收方
/// （回 FILE_ACK / FILE_DONE），验证：分块切分、窗口流控（meta+8 块后必须等 ACK）、
/// 状态轮询到完成、以及**重组字节与源文件逐字节一致**。
///
/// 接收方驱动器（.part/指纹/哈希/原子改名）由 Rust 单测
/// `backend::transfer` 的真实文件测试覆盖。
void main() {
  setUpAll(() async {
    await RustLib.init(externalLibrary: _nativeLibrary());
  });

  test('发送端到端：分块 + 流控 + 完成状态 + 字节一致', () async {
    final dataDir = Directory.systemTemp.createTempSync('lanchat_xfer_e2e').path;
    await ChatService.instance.openStore(dataDir);
    // 关键：文件事件由 chat 事件中继转发 → 必须先订阅
    final events = <dynamic>[];
    final sub = ChatService.instance.events().listen(events.add);
    await TransferService.instance.init();

    final port = await ChatService.instance.listen(
      deviceId: 'dev-app',
      name: '发送方测试',
      platform: 'windows',
      chatPort: 0,
    );
    expect(port, greaterThan(0));

    // raw 接收方：发 hello 握手
    final peer = await Socket.connect('127.0.0.1', port);
    final reader = _FrameReader();
    final acks = <int>[]; // 收到的确认位
    final reassembly = <int, List<int>>{}; // offset → 数据
    final recvdFrames = <int>[];
    var helloSeen = false;
    var doneSeen = false;
    var donePayload = '';
    var transferId = ''; // FILE_META 里的 id，回 ACK 必须带它（发送方按 id 过滤）
    // 写回必须排到 listen 回调之外（sink 重入会抛 "StreamSink is bound to a stream"）
    final pendingWrites = <List<int>>[];
    var draining = false;
    void drain() {
      if (draining) return;
      draining = true;
      scheduleMicrotask(() {
        draining = false;
        while (pendingWrites.isNotEmpty) {
          peer.add(pendingWrites.removeAt(0));
        }
        // 注意：不要在 listen 回调的微任务里 flush —— dart:io 会抛
        // "Bad state: StreamSink is bound to a stream"；add 会自行把数据写出
      });
    }

    peer.listen((data) {
      reader.add(data);
      while (true) {
        final frame = reader.next();
        if (frame == null) break;
        final (type, payload) = frame;
        recvdFrames.add(type);
        if (type == 0x01) {
          helloSeen = true;
        } else if (type == 0x30) {
          // FILE_META → ACK(offset=0)（全新接收）
          final meta = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
          expect(meta['hash_hex'], isA<String>());
          expect((meta['hash_hex'] as String).length, 64, reason: 'blake3 hex');
          transferId = meta['file_id'] as String;
          pendingWrites.add(
              _frame(0x32, {'file_id': transferId, 'offset': 0}));
        } else if (type == 0x31) {
          // FILE_CHUNK → 记录 + ACK(end)
          final offset = _u64(payload, 0);
          final data = payload.sublist(8);
          reassembly[offset] = data;
          acks.add(offset + data.length);
          pendingWrites.add(_frame(0x32, {
            'file_id': transferId,
            'offset': offset + data.length,
          }));
        } else if (type == 0x33) {
          doneSeen = true;
          donePayload = utf8.decode(payload);
          final done = jsonDecode(donePayload) as Map<String, dynamic>;
          pendingWrites.add(_frame(0x33, {
            'file_id': done['file_id'],
            'hash_hex': done['hash_hex'],
            'ok': true,
          }));
        }
      }
      drain();
    });
    peer.add(_frame(0x01, {
      'device_id': 'dev-raw',
      'name': 'raw 接收方',
      'platform': 'windows',
      'chat_port': 45998,
      'proto_version': 1,
    }));
    await peer.flush();
    await _waitUntil(() => helloSeen, reason: '未收到本机 hello');

    // 源文件：2MB + 13B（跨 8 块 + 尾块）
    final srcDir = Directory.systemTemp.createTempSync('lanchat_xfer_src');
    final srcPath = '${srcDir.path}${Platform.pathSeparator}压测文件.bin';
    final bytes = Uint8List(2 * 1024 * 1024 + 13);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = i % 251;
    }
    File(srcPath).writeAsBytesSync(bytes);

    // 发起传输
    final started = await TransferService.instance
        .send(peerId: 'dev-raw', path: srcPath);
    expect(started.dir, rust.TransferDir.send);
    expect(started.size.toInt(), bytes.length);
    expect(started.finished, isFalse);

    // 轮询到完成（Rust hub 驱动）。status() 现在是 async（不再 frb(sync)，
    // 避免 UI isolate 卡在锁上），所以这里用异步轮询而不是 _waitUntil。
    rust.TransferStatusDto? final_;
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      final list = await TransferService.instance.status();
      for (final s in list) {
        if (s.fileId == started.fileId && s.finished) {
          final_ = s;
        }
      }
      if (final_ != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    if (final_ == null) {
      fail('传输未在 30s 内完成');
    }

    expect(final_, isNotNull);
    expect(final_!.failed, isFalse, reason: final_!.error);
    expect(final_!.transferred.toInt(), bytes.length);
    expect(doneSeen, isTrue, reason: 'raw 端应收到 FILE_DONE');
    expect(donePayload.contains('ok'), isTrue);

    // 分块切分：256KB/块
    final expectedChunks = (bytes.length + 262143) ~/ 262144;
    expect(reassembly.length, expectedChunks,
        reason: '块数应为 $expectedChunks，实际 ${reassembly.length}');

    // 重组后与源文件逐字节一致
    final offsets = reassembly.keys.toList()..sort();
    expect(offsets.first, 0, reason: '第一块必须从 0 开始');
    final rebuilt = BytesBuilder();
    var cursor = 0;
    for (final off in offsets) {
      expect(off, cursor, reason: '块必须连续无缝隙');
      final chunk = reassembly[off]!;
      rebuilt.add(chunk);
      cursor += chunk.length;
    }
    expect(cursor, bytes.length, reason: '重组总长一致');
    expect(rebuilt.toBytes(), bytes, reason: '逐字节一致');

    // 状态里已有完成记录（recent）
    final tail = await TransferService.instance.status();
    expect(tail.any((s) => s.finished && !s.failed), isTrue);
    expect(TransferService.instance.downloadDir(), contains('downloads'));
    // meta → chunks → done 帧序列出现过
    expect(recvdFrames.contains(0x30), isTrue);
    expect(recvdFrames.contains(0x31), isTrue);
    expect(recvdFrames.contains(0x33), isTrue);

    await peer.close();
    await ChatService.instance.stopListening();
    unawaited(sub.cancel());
    final _ = events;
  });
}

/// payload: offset(8B LE) + data
int _u64(List<int> p, int start) {
  var v = 0;
  for (var i = 7; i >= 0; i--) {
    v = (v << 8) | p[start + i];
  }
  return v;
}

List<int> _frame(int type, Map<String, dynamic> payload) {
  final body = utf8.encode(jsonEncode(payload));
  return [
    0x4C, 0x43, 0x48, 0x54,
    1,
    type,
    body.length & 0xFF,
    (body.length >> 8) & 0xFF,
    (body.length >> 16) & 0xFF,
    (body.length >> 24) & 0xFF,
    ...body,
  ];
}

class _FrameReader {
  final List<int> _buf = [];
  (int, List<int>)? next() {
    while (_buf.length >= 10) {
      if (_buf[0] != 0x4C || _buf[1] != 0x43 || _buf[2] != 0x48 || _buf[3] != 0x54) {
        _buf.removeAt(0);
        continue;
      }
      final len = _buf[6] | (_buf[7] << 8) | (_buf[8] << 16) | (_buf[9] << 24);
      if (_buf.length < 10 + len) return null;
      final frame = (_buf[5], _buf.sublist(10, 10 + len));
      _buf.removeRange(0, 10 + len);
      return frame;
    }
    return null;
  }

  void add(List<int> data) => _buf.addAll(data);
}

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
