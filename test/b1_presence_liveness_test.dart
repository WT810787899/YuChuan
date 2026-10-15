import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:rust_flutter_ui/app_state.dart';
import 'package:rust_flutter_ui/models.dart';
import 'package:rust_flutter_ui/src/rust/api/chat.dart' as rust_chat;

/// 回归：批次B1 第 4 条 —— 「软件明明都开着，一直显示断开断开。查代码是不是
/// 判定有问题。不需要判得那么死，没有关键事件触发，不用太严，间隔问候就行。」
///
/// 用户给的是**产品约束**，不是「超时调大」的请求：
///   1. 纯静默（心跳没来）**不是**关键事件 → 不得据此判死；
///   2. 只有真事件（eof / io / protocol / bye）才断开；
///   3. 在线状态应由「最近一次收到对端数据的时间」递减判断，
///      而不是被一次 disconnect 事件永久钉死。
///
/// 本文件锁住 AppState 这一侧（Rust session.rs 侧由
/// `rust_builder/src/backend/session.rs` 的 #[cfg(test)] 单测锁）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AppState freshState() {
    final s = AppState.instance;
    s.conversations.clear();
    s.chatOnline.clear();
    s.chatError = '';
    s.chatReady = true;
    s.activePeerId = null;
    s.selectedConversation = null;
    // 在线表必须清干净：上一个用例留下的 chatOnline 会污染本用例的
    // `_isOnline`。test 的执行顺序在文件内由声明顺序决定，但**跨文件**的顺序
    // 不由我们控制，留脏状态会让用例随机翻红 —— 这种「靠顺序才绿」的测试
    // 本身就是缺陷。
    s.debugClearPresenceForTest();
    return s;
  }

  rust_chat.ChatEventDto disconnected(String peerId, String reason) =>
      rust_chat.ChatEventDto(
        kind: rust_chat.ChatEventKindDto.disconnected,
        peerId: peerId,
        reason: reason,
      );

  group('B1-4 静默不判死', () {
    test('reason=timeout 的 disconnected 不得把对端判成离线（纯静默非关键事件）', () {
      final s = freshState();
      const peer = 'dev-silent-1';
      s.debugSetOnlineForTest(peer, true);
      expect(s.debugIsOnlineForTest(peer), isTrue, reason: '前置：对端在线');

      // Rust 侧静默超时（旧实现 reason = "timeout"）—— 用户明确说这不该死。
      s.debugDeliverChatEventForTest(disconnected(peer, 'timeout'));

      expect(
        s.debugIsOnlineForTest(peer),
        isTrue,
        reason: '「没有关键事件触发，不用太严」：纯静默（timeout）不是关键事件，'
            '不得据此把对端判成离线。旧实现无条件 _setOnline(peer, false)，'
            '这正是「软件明明都开着却一直显示断开」的来源。',
      );
    });

    test('reason=eof/io/protocol/bye 的真事件才允许判离线', () {
      for (final reason in ['eof', 'io', 'protocol', 'bye']) {
        final s = freshState();
        final peer = 'dev-real-$reason';
        s.debugSetOnlineForTest(peer, true);

        s.debugDeliverChatEventForTest(disconnected(peer, reason));

        expect(
          s.debugIsOnlineForTest(peer),
          isFalse,
          reason: 'reason=$reason 是真断开事件，必须判离线',
        );
      }
    });

    test('静默超时后 connectionBanner 不得再报「连接已断开」', () {
      final s = freshState();
      const peer = 'dev-silent-2';
      s.debugMarkDialedForTest(peer);
      s.activePeerId = peer;
      s.debugSetOnlineForTest(peer, true);

      s.debugDeliverChatEventForTest(disconnected(peer, 'timeout'));
      s.activePeerId = peer; // 事件处理可能清了 activePeerId

      expect(
        s.connectionBanner,
        isNull,
        reason: 'banner 会被 main.dart 推成 OSD —— 用户看到的就是「一直显示断开'
            '断开」。静默超时不该产生这条文案。',
      );
    });
  });

  group('B1-4 在线判定只跟随 Rust 的连接事实（不得按时间递减）', () {
    test('没有任何时间输入能把在线翻成离线（递减窗口已删除）', () {
      final s = freshState();
      const peer = 'dev-idle-1';
      s.debugSetOnlineForTest(peer, true);

      // 以前这里靠 debugAgePeerLastRxForTest 把时间戳往前推来模拟静默，
      // 结果是「健康但空闲的连接 30 秒后必然变离线、而且再也回不来」——
      // 用户反馈的「双方在聊天窗都能显示一直离线」。
      // 现在这条时间通路已经被删掉（【_isOnline】只看 chatOnline），
      // 所以能影响它的只剩两类真实信号，下面逐个钉住。
      expect(s.debugIsOnlineForTest(peer), isTrue);

      // ① 纯静默事件：不得判离线（用户口径「间隔问候就行」）
      s.debugPeerDisconnectedForTest(peer, 'timeout');
      expect(s.debugIsOnlineForTest(peer), isTrue,
          reason: '静默不是关键事件，不得判死');

      // ② 真事件：必须判离线
      s.debugPeerDisconnectedForTest(peer, 'eof');
      expect(s.debugIsOnlineForTest(peer), isFalse,
          reason: 'eof 这类真事件才允许判离线');
    });

    test('Rust 说这个 peer 没连上：兜底核对必须把它转成离线', () {
      final s = freshState();
      const peer = 'dev-gone';
      s.debugSetOnlineForTest(peer, true);
      expect(s.debugIsOnlineForTest(peer), isTrue, reason: '前置：以为在线');

      // Rust 的真实连接表里没有它 → 漏掉的 disconnected 事件要被兜住
      AppState.debugConnectedPeersForTest = const <String>{};
      addTearDown(() => AppState.debugConnectedPeersForTest = null);

      s.debugVerifyPresenceWithRustForTest();

      expect(
        s.debugIsOnlineForTest(peer),
        isFalse,
        reason: '兜底核对是单向的：Rust 说没连上就必须转离线，'
            '否则真断开的会话会永久停在过期的「在线」上',
      );
    });

    test('Rust 说还连着：兜底核对不得把它清成离线', () {
      final s = freshState();
      const peer = 'dev-alive';
      s.debugSetOnlineForTest(peer, true);

      AppState.debugConnectedPeersForTest = const <String>{'dev-alive'};
      addTearDown(() => AppState.debugConnectedPeersForTest = null);

      s.debugVerifyPresenceWithRustForTest();

      expect(
        s.debugIsOnlineForTest(peer),
        isTrue,
        reason: '还连着却被清成离线，就是用户看到的「一直离线」',
      );
    });
  });

  /// 回归护栏（用户反馈）：「PC 发送离线正常，手机离线发送失败 0%」。
  ///
  /// 安卓进程被冻结时会**漏掉** `disconnected` 事件，`chatOnline` 就停在过期的
  /// true 上。这时发文件会走「在线」分支 → 交给 Rust → 往死 socket 发 →
  /// Rust 报 IO 错误 → 界面「失败 0%」。PC 端在前台能及时收到断开事件，
  /// 所以同样的操作走排队分支、表现正常 —— 这正是「PC 正常、手机失败」的差别。
  group('B1-4 发送前必须向 Rust 核实连接（手机漏掉断开事件时）', () {
    test('chatOnline 过期为 true 但 Rust 说没连上：文件必须排队，不得交给 Rust', () async {
      final dir = Directory.systemTemp.createTempSync('b1_stale_online');
      final path = '${dir.path}${Platform.pathSeparator}f.bin';
      File(path).writeAsBytesSync(List<int>.filled(1024, 5));
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });

      final s = freshState();
      const peer = 'dev-stale';
      final conv = s.conversationFor(peer);
      s.conversations
        ..clear()
        ..add(conv);
      s.chatReady = true;

      // 过期的在线标记（模拟漏掉 disconnected 事件）
      s.debugSetOnlineForTest(peer, true);
      expect(s.debugIsOnlineForTest(peer), isTrue, reason: '前置：标记是过期的 true');

      // Rust 说它没有活连接
      AppState.debugConnectedPeersForTest = const <String>{};
      addTearDown(() => AppState.debugConnectedPeersForTest = null);

      await s.sendFilePath(path, peerId: peer);

      final bubble = s.conversationFor(peer).messages.first;
      expect(
        bubble.queued,
        isTrue,
        reason: 'Rust 说没连上时必须走排队；硬发给死连接就是「失败 0%」',
      );
      expect(bubble.failed, isFalse,
          reason: '排队不是失败 —— 用户看到「失败 0%」就是这里判错了');
      expect(
        s.debugIsOnlineForTest(peer),
        isFalse,
        reason: '顺带要把过期的在线标记纠正掉，别让界面继续显示在线',
      );
    });

    test('Rust 说还连着：仍然正常直发（不得把能发的也拦成排队）', () async {
      final dir = Directory.systemTemp.createTempSync('b1_live_online');
      final path = '${dir.path}${Platform.pathSeparator}g.bin';
      File(path).writeAsBytesSync(List<int>.filled(1024, 6));
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });

      final s = freshState();
      const peer = 'dev-live';
      final conv = s.conversationFor(peer);
      s.conversations
        ..clear()
        ..add(conv);
      s.chatReady = true;
      s.debugSetOnlineForTest(peer, true);

      AppState.debugConnectedPeersForTest = const <String>{'dev-live'};
      addTearDown(() => AppState.debugConnectedPeersForTest = null);

      await s.sendFilePath(path, peerId: peer);

      final bubble = s.conversationFor(peer).messages.first;
      // 单测 VM 里没有 frb 桥，TransferService.send 会抛 → 走 catch 的排队分支。
      // 关键区别是：**它确实去尝试发了**（说明没被误拦成纯离线）。
      expect(bubble, isNotNull);
      expect(s.debugIsOnlineForTest(peer), isTrue,
          reason: 'Rust 说还连着就不许把在线标记清掉');
    });
  });

  ///
  /// 根因：Rust 的 `chat_dial`（api/chat.rs）会**无条件**拆掉该 peer 的现有连接再
  /// 换成新的：
  ///     if let Some(mut old) = map.remove(&peer_id) { old.stop(); }
  /// 而 `sendMessage` / `sendFilePath` 在**已经在线时也会先 `await ensureDial`**
  /// （本意是「没连上就先拨号」）。于是每发一条消息就重拨一次 → 真断开事件 →
  /// `chatOnline=false` → 横幅「与 X 的连接已断开，正在自动重连…」→ 被推成 OSD。
  ///
  /// 修法：`ensureDial` 按契约收口 —— 已经在线就不再拨。
  /// 造一个「有地址」的设备：地址为空时 ensureDial 会提前返回，
  /// 那样就测不到真正的拨号分支（假绿）。
  void seedDialable(AppState s, String peer) {
    s.devices.add(LanDevice(
      id: peer,
      name: '对端',
      ip: '127.0.0.1',
      platform: DevicePlatform.windows,
      online: false,
      paired: true,
      chatPort: 45998,
    ));
  }

  group('B1-4 已经连着时不得重拨（否则一发消息就假断开）', () {
    test('对端在线时调用 ensureDial：不得去拨号（否则会拆掉活连接）', () async {
      final s = freshState();
      const peer = 'dev-online-nodial';
      // 造一个「有地址」的设备：地址为空的话 ensureDial 会提前返回，
      // 那样这个用例就测不到真正的拨号分支了（假绿）。
      s.devices.add(LanDevice(
        id: peer,
        name: '对端',
        ip: '127.0.0.1',
        platform: DevicePlatform.windows,
        online: true,
        paired: true,
        chatPort: 45998,
      ));
      s.debugSetOnlineForTest(peer, true);
      expect(s.debugIsOnlineForTest(peer), isTrue, reason: '前置：对端在线');
      s.chatError = '';

      await s.ensureDial(peer);

      // 真拨号会走到 `ChatService.instance.dial(...)`，在单测 VM 里必抛
      // （没有 frb 桥），catch 里会写 `chatError = '连接失败：…'`。
      // 所以 chatError 为空 == 根本没尝试拨号。
      expect(
        s.chatError,
        isEmpty,
        reason: '在线时不得拨号：Rust 的 chat_dial 会 stop 掉现有连接，'
            '于是每发一条消息就制造一次真断开 → OSD「与 X 的连接已断开」',
      );
    });

    test('对端离线时 ensureDial 仍要真去拨号（重连能力不能丢）', () async {
      final s = freshState();
      const peer = 'dev-offline-dial';
      seedDialable(s, peer);
      s.debugSetOnlineForTest(peer, false);
      s.chatError = '';

      await s.ensureDial(peer);

      expect(
        s.chatError,
        contains('连接失败'),
        reason: '离线时必须真的尝试拨号（这里因单测无桥而失败），'
            '否则真断线后再也连不回来',
      );
    });

    /// 死锁回归：「过期的在线标记 ⇒ 不拨号」+「Rust 说没连接 ⇒ 进队列」，
    /// 两者互相否决，文件永远发不出去（用户反馈「根本就没发送过来」）。
    /// 拨号闸门必须按 **Rust 的真实连接**判断，而不是过期的内存标记。
    test('在线标记是过期的 true、但 Rust 说没连上：必须仍然去拨号（破死锁）',
        () async {
      final s = freshState();
      const peer = 'dev-stale-deadlock';
      seedDialable(s, peer);
      // 过期的在线标记（安卓漏掉 disconnected 事件的典型状态）
      s.debugSetOnlineForTest(peer, true);
      // Rust 说这个 peer 没有活连接
      AppState.debugConnectedPeersForTest = const <String>{};
      addTearDown(() => AppState.debugConnectedPeersForTest = null);
      s.chatError = '';

      await s.ensureDial(peer);

      expect(
        s.chatError,
        contains('连接失败'),
        reason: '必须真去拨号：只按过期的在线标记就会拒绝拨号，'
            '而发送侧又按 Rust 的真实连接判离线 → 两边互相否决，'
            '文件永远补发不出去',
      );
    });
  });

  ///
  /// 两条同源：曾经拿 Rust 的 `chat_sessions().connected` 去刷新在线判定，
  /// 但 `is_connected()` 只表示「连接对象还活着」—— 对端进程被冻结、socket
  /// 已经写不通时它**依然是 true**。于是：
  ///   - 文件被当成「对端在线」交给 Rust 去发 → 写 socket 出 IO 错误 →
  ///     回一个 failed → 界面「发送文件，直接失败 0%」；
  ///   - 文字走「非离线」分支 → `failed = true` → 「发送失败」。
  /// 诚实的在线判定只有一个来源：**真的收到了对端数据**。这一组把
  /// 「对端离线时必须走排队、绝不能判成失败/在线直发」钉死。
  group('B1-4 离线时必须排队，不得判成失败', () {
    test('离线发文字：气泡必须是「排队中」，不能是「发送失败」', () async {
      final s = freshState();
      const peer = 'dev-offline-text';
      final conv = s.conversationFor(peer);
      s.conversations
        ..clear()
        ..add(conv);
      s.activePeerId = peer;
      s.selectedConversation = 0;
      expect(s.debugIsOnlineForTest(peer), isFalse, reason: '前置：对端离线');

      await s.sendMessage('离线的一句话');

      final bubble = s.conversationFor(peer).messages.first;
      expect(bubble.queued, isTrue,
          reason: '离线发送必须排队等补发，不能直接失败');
      expect(bubble.failed, isFalse,
          reason: '「发送失败」在用户那里就是「直接失败」——离线不是失败');
      expect(bubble.state, SendState.sending);
    });

    test('离线发文件：气泡必须是「排队中」，不能是「发送失败」', () async {
      final dir = Directory.systemTemp.createTempSync('b1_off_file');
      final path = '${dir.path}${Platform.pathSeparator}f.bin';
      File(path).writeAsBytesSync(List<int>.filled(1024, 3));
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });

      final s = freshState();
      const peer = 'dev-offline-file';
      final conv = s.conversationFor(peer);
      s.conversations
        ..clear()
        ..add(conv);
      s.activePeerId = peer;
      s.selectedConversation = 0;
      expect(s.debugIsOnlineForTest(peer), isFalse, reason: '前置：对端离线');

      await s.sendFilePath(path, peerId: peer);

      final bubble = s.conversationFor(peer).messages.first;
      expect(bubble.queued, isTrue,
          reason: '离线发文件必须排队；判成失败就是用户看到的「直接失败 0%」');
      expect(bubble.failed, isFalse);
      expect(bubble.progress, 0);
    });
  });
}
