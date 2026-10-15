import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:rust_flutter_ui/app_state.dart';
import 'package:rust_flutter_ui/models.dart';
import 'package:rust_flutter_ui/src/rust/api/chat.dart' as rust_chat;

/// 回归：批次B1 第 5 条 —— 「如果接收端处在离线，发送端发的单个文件会在窗口
/// 显示 N 个发送气泡，然后接收端上线也没能接收。」
///
/// 两个独立成因，这里分别锁住：
///
/// **(a) 同一个文件在发件箱里排成 N 条**（Lead 已核实）：
///   - 离线分支用 `fileId: '${path.hashCode}-$size'`（app_state.dart 旧 2268 行）
///   - catch 分支用 `fileId: 'file-${msg.id}'`，而 msg.id 是
///     `pending-file-<微秒>`，每次调用都不同（旧 2352 行）
///   Rust 的 `chat_outbox_enqueue_file` 只按 `file-<file_id>` 去重
///   （rust_builder/src/api/chat.rs），于是同一文件留下两条 → flushOutbox
///   对每条各补发一次 → 每发一次新上屏一个气泡。
///
/// **(b) 补发时**新建**气泡而不是复用已有的排队气泡**：
///   `flushOutbox` 调 `sendFilePath`，后者无条件 `conv.messages.add(...)`，
///   而 `_clearQueuedBubble` 只把旧气泡的 `queued` 置 false、并不删它 →
///   「1 个排队气泡 + 每次补发各 1 个新气泡」= N 个。
///
/// 本测试在**没有真实 Rust 桥**的环境下驱动 sendFilePath：桥接调用会抛异常，
/// 正好走「离线也要排队」的路径，且入队失败会退化成内存排队 —— 这正是修复
/// 之前最容易看出气泡增殖的路径。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late String filePath;

  /// 每条用例用**不同的 peer id**：`AppState._history` 是进程级的
  /// `peer_id → List<ChatMessage>`，且它正是 `Conversation.messages` 的
  /// 同一个 List 实例 —— 清 `conversations` 不会清 `_history`，复用同一个
  /// peer id 会让上一条用例的气泡漏进下一条（测试会假红）。
  var peerSeq = 0;
  String nextPeer() => 'dev-offline-${peerSeq++}';

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('b1_5_bubbles');
    filePath = '${tmp.path}${Platform.pathSeparator}report.pdf';
    File(filePath).writeAsBytesSync(List<int>.filled(4096, 7));
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  AppState freshState(String peerId) {
    final s = AppState.instance;
    s.conversations.clear();
    s.chatOnline.clear();
    s.chatError = '';
    s.chatReady = true; // 跳过「聊天未就绪」早退，直接测文件排队路径
    final conv = s.conversationFor(peerId);
    s.conversations
      ..clear()
      ..add(conv);
    s.activePeerId = peerId;
    s.selectedConversation = 0;
    return s;
  }

  int fileBubbleCount(AppState s, String peerId) => s
      .conversationFor(peerId)
      .messages
      .where((m) => m.fromMe && m.kind != MessageKind.text)
      .length;

  test('对端离线时重复发同一个文件：不得每发一次就多一个气泡', () async {
    final peer = nextPeer();
    final s = freshState(peer);
    // 对端离线（chatOnline 无记录 → _isOnline 返回 false）
    expect(s.chatOnline[peer], isNull);

    await s.sendFilePath(filePath, peerId: peer);
    expect(fileBubbleCount(s, peer), 1, reason: '第一次发送应只有一个气泡');

    // 用户/补发机制再发同一个文件（同一路径、同一内容）
    await s.sendFilePath(filePath, peerId: peer);
    await s.sendFilePath(filePath, peerId: peer);

    expect(
      fileBubbleCount(s, peer),
      1,
      reason: '同一文件的重复发送必须复用已有排队气泡，不能每次新增一个'
          '（用户看到的就是「N 个发送气泡」）',
    );
  });

  test('排队气泡在同文件补发后不应同时留下「旧的排队气泡 + 新的发送气泡」', () async {
    final peer = nextPeer();
    final s = freshState(peer);

    await s.sendFilePath(filePath, peerId: peer);
    final queued = s
        .conversationFor(peer)
        .messages
        .where((m) => m.fromMe && m.kind != MessageKind.text)
        .toList();
    expect(queued.length, 1);
    expect(queued.first.queued, isTrue, reason: '离线时该气泡应标记为排队中');

    // 补发（同文件）：必须**复用同一个气泡对象**（而不是删旧建新）。
    //
    // 注意：此用例里对端始终离线，所以离线分支会在 app_state.dart:2367
    // 重新把 queued 置回 true —— 这是正确行为（还没发出去就该显示排队中），
    // 因此这里断言的是「同一对象被复用」，而不是 queued 变 false。
    final before = s
        .conversationFor(peer)
        .messages
        .where((m) => m.fromMe && m.kind != MessageKind.text)
        .toList();
    await s.sendFilePath(filePath, peerId: peer);

    final after = s
        .conversationFor(peer)
        .messages
        .where((m) => m.fromMe && m.kind != MessageKind.text)
        .toList();
    expect(after.length, 1, reason: '补发不得新增气泡');
    expect(
      identical(after.first, before.first),
      isTrue,
      reason: '补发应复用已有排队气泡（同一 ChatMessage 实例），'
          '而不是再 add 一条、把旧气泡留在列表里',
    );
    expect(after.first.queued, isTrue, reason: '仍离线，应保持排队中');
  });

  test('不同文件仍然各占一个气泡（复用逻辑不能误合并）', () async {
    final peer = nextPeer();
    final s = freshState(peer);
    final other = '${tmp.path}${Platform.pathSeparator}other.pdf';
    File(other).writeAsBytesSync(List<int>.filled(4096, 9));

    await s.sendFilePath(filePath, peerId: peer);
    await s.sendFilePath(other, peerId: peer);

    expect(
      fileBubbleCount(s, peer),
      2,
      reason: '不同文件必须各自一个气泡，内容/路径不同不得被复用逻辑吞掉',
    );
  });

  /// 回归护栏：复用气泡时**必须继续往下走**（真的去发/真的去排队），
  /// 不能在复用命中时直接 return。
  ///
  /// 踩过的坑：第一版复用命中就 `return`，于是「补发」退化成「把气泡标成
  /// 排队中然后返回」，而 `flushOutbox` 紧接着 `outboxAck()` 把发件箱条目
  /// 删掉 —— 文件**从头到尾没被发出去**，用户看到的就是「对端上线也收不到」。
  /// 判定用「离线分支是否真的执行过」：离线发送会写
  /// `chatError = '对方当前离线…'`，而早退的复用路径不会写。
  test('复用命中后必须继续走发送流程（不得早退吞掉这次发送）', () async {
    final peer = nextPeer();
    final s = freshState(peer);

    // 第一次：创建排队气泡（此时会写离线提示）
    await s.sendFilePath(filePath, peerId: peer);
    expect(fileBubbleCount(s, peer), 1);
    expect(s.chatError, contains('对方当前离线'),
        reason: '前置：离线发送应当提示已排队');

    // 清掉提示，再发同一个文件 —— 这次必然走「复用已存在气泡」那条分支
    s.chatError = '';
    await s.sendFilePath(filePath, peerId: peer);

    expect(
      s.chatError,
      contains('对方当前离线'),
      reason: '复用命中后仍必须继续执行离线/在线分支（fall through）；'
          '若这里为空，说明复用时直接 return 了 —— 那次发送被静默吞掉，'
          'flushOutbox 还会把发件箱条目 ack 掉，文件永远发不出去',
    );
    expect(fileBubbleCount(s, peer), 1, reason: '复用不得新增气泡');
  });

  /// 用户口径里的「N 个气泡」在真机上最常见的形式是：先离线排队 → 进程被
  /// 系统回收 → 重启后从存储重建气泡（`queued`/`filePath` 全丢）→ 上线补发。
  /// 修复前 `queued` 恒为 false，`existingQueued` 判定永远命中不了，
  /// 于是每轮补发新增一个气泡。这里用 `debugReloadFromStorageForTest` 精确
  /// 复现「重载后字段丢失」，再用 `debugReconcileQueuedForTest` 走生产对账逻辑。
  test('进程重启后从存储重建的排队气泡：对账必须把它认回「排队中」并复用', () async {
    final peer = nextPeer();
    final s = freshState(peer);

    await s.sendFilePath(filePath, peerId: peer);
    expect(fileBubbleCount(s, peer), 1);

    // 模拟重启：queued / filePath 丢失（存储里没有这两个字段）
    s.debugReloadFromStorageForTest(peer);
    final reloaded = s
        .conversationFor(peer)
        .messages
        .where((m) => m.fromMe && m.kind != MessageKind.text)
        .toList();
    expect(reloaded.length, 1);
    expect(reloaded.first.queued, isFalse, reason: '前置：重载后 queued 确实丢了');
    expect(reloaded.first.filePath, isEmpty, reason: '前置：重载后 filePath 确实丢了');

    // 发件箱里该文件仍 pending → 对账后气泡必须重新认回「排队中」+ filePath
    AppState.debugOutboxPendingOverrideForTest = (_) => [
          rust_chat.OutboxItemDto(
            id: 'file-content-hash',
            peerId: peer,
            kind: 3,
            text: '',
            filePath: filePath,
            fileName: 'report.pdf',
            fileSize: 4096,
            createdMs: DateTime.now().millisecondsSinceEpoch,
          ),
        ];
    addTearDown(() => AppState.debugOutboxPendingOverrideForTest = null);

    s.debugReconcileQueuedForTest(peer);

    final after = s
        .conversationFor(peer)
        .messages
        .where((m) => m.fromMe && m.kind != MessageKind.text)
        .toList();
    expect(after.length, 1, reason: '对账不得新增气泡');
    expect(
      after.first.queued,
      isTrue,
      reason: '发件箱里还有该文件的 pending，气泡就必须显示「排队中」；'
          '否则补发时认不出它，会不停地新建气泡（N 个气泡的根因）',
    );
    expect(
      after.first.filePath,
      filePath,
      reason: 'filePath 必须从发件箱补齐：重载后它是空的，而复用判定要用它',
    );

    // 对账后再发同一文件：必须复用，不能新增
    final countBefore = fileBubbleCount(s, peer);
    await s.sendFilePath(filePath, peerId: peer);
    expect(
      fileBubbleCount(s, peer),
      countBefore,
      reason: '对账认回排队状态后，补发必须复用而不是再冒一个气泡',
    );
  });

  /// 回归护栏（用户反馈）：「不是UI的问题，根本就没发送过来」。
  ///
  /// 旧 `flushOutbox` 里：
  ///     await sendFilePath(...);   // 离线时走「重新排队」分支后**正常返回**
  ///     outboxAck(item.id);        // 无条件 ack：把没发出去的条目删了
  /// 而离线分支的重新入队是 `unawaited` 的，与 ack 竞态 —— ack 后落地就把文件
  /// 从发件箱**彻底抹掉**，之后永远不会再补发。
  ///
  /// 契约：`sendFilePath` 必须**如实报告**有没有真的交给 Rust 传输引擎。
  test('离线发文件：sendFilePath 必须返回 false（没交给 Rust，调用方不能 ack）',
      () async {
    final peer = nextPeer();
    final s = freshState(peer);
    expect(s.debugIsOnlineForTest(peer), isFalse, reason: '前置：对端离线');

    final started = await s.sendFilePath(filePath, peerId: peer);

    expect(
      started,
      isFalse,
      reason: '离线时只是进了发件箱、**没有**发出去；返回 true 会让 flushOutbox '
          '无条件 ack 把条目删掉 → 文件永远补发不出去（「根本就没发送过来」）',
    );
    expect(fileBubbleCount(s, peer), 1);
    expect(
      s.conversationFor(peer).messages.first.queued,
      isTrue,
      reason: '必须保持「离线待发」，等对端上线后继续补发',
    );
  });
}
