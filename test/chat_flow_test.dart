import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_flutter_ui/services/chat_service.dart';
import 'package:rust_flutter_ui/src/rust/api/chat.dart' as rust;
import 'package:rust_flutter_ui/src/rust/frb_generated.dart';

/// T3.1 / T3.3 端到端（真实 Rust TCP 会话 + 真实 socket + 真实消息落盘）：
/// 本进程跑「被连入方」（chatListen），测试自己扮演对端（原始 TCP + 手写 LCHT 帧），
/// 验证：hello 双向握手 → 收到文本即入库 → 本机回消息对端能收到 → 未读/已读 →
/// 会话摘要 → 重启（重新打开目录）历史与已读都在 → 断开有事件。
void main() {
  setUpAll(() async {
    await RustLib.init(externalLibrary: _nativeLibrary());
  });

  test('会话收发 + 收到即入库 + 未读/已读 + 重启读回', () async {
    final dataDir = Directory.systemTemp.createTempSync('lanchat_chat_e2e').path;
    final store = await ChatService.instance.openStore(dataDir);
    expect(store.total, 0);

    final events = <rust.ChatEventDto>[];
    final sub = ChatService.instance.events().listen(events.add);

    // 本机监听（端口交给系统分配，避免和真实实例抢 45998）
    final port = await ChatService.instance.listen(
      deviceId: 'dev-app',
      name: '本机测试',
      platform: 'windows',
      chatPort: 0,
    );
    expect(port, greaterThan(0));
    expect(ChatService.instance.listening, isTrue);

    // 扮演对端：原始 TCP + 手写 LCHT 帧（hello + 一条文本，粘在一个 flush 里）
    final peer = await Socket.connect('127.0.0.1', port);
    final reader = _FrameReader();
    peer.listen(reader.add);
    peer.add(_frame(0x01, {
      'device_id': 'dev-peer',
      'name': '对端手机',
      'platform': 'android',
      'chat_port': 45998,
      'proto_version': 1,
    }));
    peer.add(_frame(0x20, {
      'sender_id': 'dev-peer',
      'seq': 1,
      'text': '来自对端的第一条',
      'ts_ms': 1760000000000,
    }));
    await peer.flush();

    // 本机收到 hello（握手）→ Connected
    await _waitUntil(
      () => events.any((e) => e.kind == rust.ChatEventKindDto.connected),
      reason: '未收到 Connected 事件',
    );
    // 本机也回了 hello（证明双向握手）
    await _waitUntil(() => reader.frames.any((f) => f.$1 == 0x01));
    final peerHello = jsonDecode(
      utf8.decode(reader.frames.firstWhere((f) => f.$1 == 0x01).$2),
    ) as Map<String, dynamic>;
    expect(peerHello['device_id'], 'dev-app');

    // 收到文本：事件 + 立刻落库（收到即入库）
    await _waitUntil(
      () => events.any((e) => e.kind == rust.ChatEventKindDto.message),
      reason: '未收到 Message 事件',
    );
    final incoming =
        events.firstWhere((e) => e.kind == rust.ChatEventKindDto.message);
    expect(incoming.message!.text, '来自对端的第一条');
    expect(incoming.message!.fromMe, isFalse);
    await _waitUntil(
      () => ChatService.instance.page('dev-peer').length == 1,
      reason: '收到即入库',
    );
    expect(ChatService.instance.unread('dev-peer'), 1);

    // 本机回消息：对端应收到 TEXT 帧，本机也落库（from_me）
    final sent = await ChatService.instance.sendText(
      peerId: 'dev-peer',
      senderId: 'dev-app',
      text: '本机回复',
    );
    expect(sent.seq, 1, reason: '本机发出的首个 seq');
    expect(sent.id, 'dev-app-1', reason: 'id 规则 = 发送方 + 序号（与存储一致）');
    expect(sent.fromMe, isTrue);
    await _waitUntil(() => reader.frames.any((f) => f.$1 == 0x20));
    final outText = jsonDecode(
      utf8.decode(reader.frames.firstWhere((f) => f.$1 == 0x20).$2),
    ) as Map<String, dynamic>;
    expect(outText['text'], '本机回复');
    expect(outText['sender_id'], 'dev-app');
    expect(outText['seq'], 1);

    final page = ChatService.instance.page('dev-peer');
    expect(page.length, 2, reason: '收 + 发都要入库');
    expect(page.first.text, '本机回复', reason: '新的在前');
    expect(page.first.fromMe, isTrue);
    expect(page.last.text, '来自对端的第一条');

    // 已读游标（只前进）
    expect(await ChatService.instance.markRead('dev-peer', 1760000000000), 0);
    expect(ChatService.instance.unread('dev-peer'), 0);

    // 会话摘要（聊天列表页）
    final convs = ChatService.instance.conversations();
    expect(convs.single.peerId, 'dev-peer');
    expect(convs.single.count, 2);
    expect(convs.single.unread, 0);
    expect(convs.single.lastText, '本机回复');

    // 「重启」：重新打开消息目录
    final reopened = await ChatService.instance.openStore(dataDir);
    expect(reopened.total, 2, reason: '重启后历史必须还在');
    expect(reopened.totalUnread, 0, reason: '已读状态也要持久化');
    expect(ChatService.instance.page('dev-peer').length, 2);

    // 断开对端 → 本机应收到 Disconnected（拔网线场景）
    await peer.close();
    await _waitUntil(
      () => events.any((e) => e.kind == rust.ChatEventKindDto.disconnected),
      reason: '断开未产生事件',
    );

    await ChatService.instance.stopListening();
    // 不 await：frb 的流取消不会等 Rust 转发线程退出（转发线程靠 add 失败自行收尾）
    unawaited(sub.cancel());
  });
}

/// 一帧：magic(4) + version(1) + type(1) + length(4, LE) + JSON payload
List<int> _frame(int type, Map<String, dynamic> payload) {
  final body = utf8.encode(jsonEncode(payload));
  return [
    0x4C, 0x43, 0x48, 0x54, // LCHT
    1,
    type,
    body.length & 0xFF,
    (body.length >> 8) & 0xFF,
    (body.length >> 16) & 0xFF,
    (body.length >> 24) & 0xFF,
    ...body,
  ];
}

/// 把字节流切成完整帧（半包/粘包都按协议处理）。
class _FrameReader {
  final List<int> _buf = [];
  final List<(int, List<int>)> frames = [];

  void add(List<int> data) {
    _buf.addAll(data);
    while (_buf.length >= 10) {
      if (_buf[0] != 0x4C ||
          _buf[1] != 0x43 ||
          _buf[2] != 0x48 ||
          _buf[3] != 0x54) {
        _buf.removeAt(0); // 坏帧：丢一个字节重新同步（测试里不会发生）
        continue;
      }
      final len = _buf[6] | (_buf[7] << 8) | (_buf[8] << 16) | (_buf[9] << 24);
      if (_buf.length < 10 + len) break;
      frames.add((_buf[5], _buf.sublist(10, 10 + len)));
      _buf.removeRange(0, 10 + len);
    }
  }
}

Future<void> _waitUntil(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 5),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
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
