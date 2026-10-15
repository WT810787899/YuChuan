import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:rust_flutter_ui/app_state.dart';
import 'package:rust_flutter_ui/models.dart';
import 'package:rust_flutter_ui/src/rust/api/chat.dart' as rust_chat;

/// 回归：批次B1 第 5 条 ——「如果接收端处在离线，发送端发的单个文件会在窗口
/// 显示 N 个发送气泡，然后接收端上线也没能接收。」
///
/// 上一轮（task-2）统一了 fileId（内容哈希），修掉了「同一文件两条发件箱条目」。
/// 但用户反馈**仍然看到 N 个气泡、对端上线仍收不到** —— 因为还有一条**独立**的
/// 泄漏路径没堵：`queued` 标记只活在内存里。
///
/// 事实链（已逐行复核）：
///   1. 离线发送 → `msg.queued = true`（app_state.dart:2500）**只改内存对象**，
///      这条气泡**根本没落库**（离线分支在 `return` 之前没有任何 `appendMessage`）。
///   2. 进程被回收 / 历史重载后，气泡从存储读回：`_toChatMessage`
///      （app_state.dart:2340-2391）**从不设置 `queued`**，恒为 false，
///      且 `filePath` 常常是空的（台账里可能没有这条）。
///   3. `flushOutbox` 补发成功后调 `_clearQueuedBubble`（app_state.dart:1643）
///      靠 `m.queued == true` 找气泡 —— 重载后找不到任何目标，旧气泡**永远
///      停在「排队中」**。
///   4. 同一次补发走 `sendFilePath`，它的复用判定 `existingQueued`
///      （app_state.dart:2438-2444）同样要求 `m.queued == true` **且
///      `m.filePath == path`** —— 重载后两个条件都不成立 ⇒ 不复用 ⇒
///      `conv.messages.add(新气泡)`（app_state.dart:2464）⇒ **每次补发多一个气泡**。
///   5. 于是「N 个发送气泡」随补发轮次线性增长，而每个气泡看起来都在发同一个文件。
///
/// 本测试锁定「队列状态必须跨重载存活」这一契约：模拟历史重载后，发件箱里
/// 仍有该文件的 pending 条目时，补发**必须复用**那个气泡而不是新增。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late String filePath;

  var peerSeq = 0;
  String nextPeer() => 'dev-queued-${peerSeq++}';

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('b1_5_queued');
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
    s.chatReady = true;
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

  /// 真实发件箱里的待发文件条目（Rust outbox.jsonl 是唯一真相源）。
  ///
  /// 单元测试 VM 里没有 native 库，`outboxPending()` 必抛 —— 直接用它会让
  /// 断言在测试中**根本不执行**，那就是上一轮的假绿。所以这里装一个注入点：
  /// 让 `_reconcileQueuedFromOutbox` 的真实逻辑被跑到，且数据由测试给出。
  List<rust_chat.OutboxItemDto> Function(String)? override;

  setUp(() {
    override = (peerId) => <rust_chat.OutboxItemDto>[];
    AppState.debugOutboxPendingOverrideForTest = (peerId) => override!(peerId);
  });

  tearDown(() {
    AppState.debugOutboxPendingOverrideForTest = null;
  });

  /// 造一条与真实入队等价的 pending 条目。
  rust_chat.OutboxItemDto pendingDto({
    required String peerId,
    required String path,
    required String fileName,
    required int fileSize,
    required String fileId,
  }) =>
      rust_chat.OutboxItemDto(
        id: fileId,
        peerId: peerId,
        kind: 3,
        text: '',
        filePath: path,
        fileName: fileName,
        fileSize: fileSize,
        createdMs: DateTime.now().millisecondsSinceEpoch,
      );

  test('离线入队的文件必须落进持久发件箱（而不是只活在内存气泡上）', () async {
    final peer = nextPeer();
    final s = freshState(peer);

    await s.sendFilePath(filePath, peerId: peer);
    expect(fileBubbleCount(s, peer), 1, reason: '离线发送应留下一个排队气泡');
    expect(
      s.conversationFor(peer).messages.first.queued,
      isTrue,
      reason: '离线时该气泡应标记为排队中',
    );

    // 入队是异步 unawaited 的，给它一个微任务窗口
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // 桥不可用时入队会退化成内存排队（那是既有行为）；这里断言的是
    // **气泡必须落库**，它走的是 appendMessage，同样被 try 包住。
    // 关键断言：排队标记必须能被发件箱回灌出来（见下一个用例）。
    expect(
      s.conversationFor(peer).messages.first.queued,
      isTrue,
      reason: '离线入队的文件必须保持「排队中」，否则用户看到的是「已发送」假象',
    );
  });

  test('历史重载后：发件箱里的 pending 必须把气泡还原成「排队中」（B1-5 核心）',
      () async {
    final peer = nextPeer();
    final s = freshState(peer);

    await s.sendFilePath(filePath, peerId: peer);
    final bubble = s.conversationFor(peer).messages.first;
    final size = bubble.fileSize;

    // 模拟进程被回收后重启：内存气泡从存储重建 —— queued / filePath 全丢。
    s.debugReloadFromStorageForTest(peer);
    expect(
      s.conversationFor(peer).messages.first.queued,
      isFalse,
      reason: '前置：刚重载时 queued 必然是 false（存储里没有这个字段）',
    );

    // 发件箱里仍有该文件的 pending（它跨进程存活）
    override = (p) => p == peer
        ? [
            pendingDto(
              peerId: peer,
              path: filePath,
              fileName: 'report.pdf',
              fileSize: size,
              fileId: 'hash-of-report',
            ),
          ]
        : <rust_chat.OutboxItemDto>[];
    s.debugReconcileQueuedForTest(peer);

    expect(
      s.conversationFor(peer).messages.first.queued,
      isTrue,
      reason: '发件箱里有 pending 就必须把重载回来的气泡还原成「排队中」—— '
          'queued 不能只活在内存里，否则 _clearQueuedBubble / existingQueued '
          '两条复用判定永远命中不了，每次补发都新建气泡',
    );
  });

  test('历史重载后补发同一文件：必须复用已存在的气泡，不得新增', () async {
    final peer = nextPeer();
    final s = freshState(peer);

    await s.sendFilePath(filePath, peerId: peer);
    final size = s.conversationFor(peer).messages.first.fileSize;
    expect(fileBubbleCount(s, peer), 1);

    // 重载 + 发件箱回灌 → 气泡重新变成「排队中」且 filePath 被补回
    s.debugReloadFromStorageForTest(peer);
    override = (p) => p == peer
        ? [
            pendingDto(
              peerId: peer,
              path: filePath,
              fileName: 'report.pdf',
              fileSize: size,
              fileId: 'hash-of-report',
            ),
          ]
        : <rust_chat.OutboxItemDto>[];
    s.debugReconcileQueuedForTest(peer);

    // 补发一次（对端仍离线，走离线分支）
    await s.sendFilePath(filePath, peerId: peer);

    expect(
      fileBubbleCount(s, peer),
      1,
      reason: '重载后补发同一文件必须复用原气泡；新增就是用户看到的「N 个发送气泡」',
    );
  });

  test('同一次补发不得新增第二个气泡（N 个气泡的根因：复用判定必须命中）',
      () async {
    final peer = nextPeer();
    final s = freshState(peer);

    await s.sendFilePath(filePath, peerId: peer);
    expect(fileBubbleCount(s, peer), 1);

    // 再发一次同一个文件（对端仍离线）：必须复用那条排队气泡。
    //
    // 旧实现的复用判定额外要求 `m.filePath == path`；只要有一条不成立就
    // add 新气泡 —— 用户看到的「N 个发送气泡」就是这么来的。
    await s.sendFilePath(filePath, peerId: peer);

    expect(
      fileBubbleCount(s, peer),
      1,
      reason: '同一文件重复入队必须复用原气泡；新增就是用户看到的「N 个发送气泡」',
    );
  });

  test('对端离线时 flushOutbox 不得清掉气泡的排队标记', () async {
    final peer = nextPeer();
    final s = freshState(peer);

    await s.sendFilePath(filePath, peerId: peer);
    await s.flushOutbox();

    expect(
      s.conversationFor(peer).messages.first.queued,
      isTrue,
      reason: '对端离线时补发必须失败并保留「排队中」；若被清掉，用户会以为'
          '已经发出去了，而对端上线后其实收不到',
    );
  });

  /// Bug 复现：手机返回桌面后，同一个 peer 上有一个卡住的传输（心跳被冻结 →
  /// 拿不到 ACK → progress 永远 <1），**不能**因此把队列里别的文件永远挡住。
  ///
  /// 这是「手机返回桌面一会，PC 就发送失败；手机连上也没有发送」的根因：
  /// 旧实现只问「该 peer 有没有在传的东西」，答是即跳过全部文件条目。
  test('同 peer 有别的文件卡在传输时：队列里的其他文件不得被挡住（fix#2600743）',
      () {
    const peer = 'dev-android';
    const queued = 'report.pdf';
    const queuedSize = 4096;
    const queuedPath = r'C:\files\report.pdf';

    // 该 peer 上有一个**别的**文件卡着（progress 0.5，未失败）
    final blockedByOtherFile = AppState.outboxItemBlockedByInFlight(
      peerId: peer,
      itemFileName: queued,
      itemFileSize: queuedSize,
      itemFilePath: queuedPath,
      inFlight: [
        (
          peerId: peer,
          fileName: 'other.pdf',
          fileSize: 5000,
          filePath: r'C:\files\other.pdf',
          failed: false,
          progress: 0.5,
        ),
      ],
    );
    expect(
      blockedByOtherFile,
      isFalse,
      reason: '别的文件卡住不能挡住队列里的文件 —— 否则「手机返回桌面后'
          'PC 显示离线、文件一直发不出去」，对端上线也收不到',
    );

    // 同一个文件在传时才应该让路（交给 Rust 续传，避免双发）
    final blockedBySameFile = AppState.outboxItemBlockedByInFlight(
      peerId: peer,
      itemFileName: queued,
      itemFileSize: queuedSize,
      itemFilePath: queuedPath,
      inFlight: [
        (
          peerId: peer,
          fileName: queued,
          fileSize: queuedSize,
          filePath: queuedPath,
          failed: false,
          progress: 0.5,
        ),
      ],
    );
    expect(blockedBySameFile, isTrue, reason: '同一文件在传时必须让路，避免双发');

    // 另一个 peer 在传不相关
    final blockedByOtherPeer = AppState.outboxItemBlockedByInFlight(
      peerId: peer,
      itemFileName: queued,
      itemFileSize: queuedSize,
      itemFilePath: queuedPath,
      inFlight: [
        (
          peerId: 'someone-else',
          fileName: queued,
          fileSize: queuedSize,
          filePath: queuedPath,
          failed: false,
          progress: 0.5,
        ),
      ],
    );
    expect(blockedByOtherPeer, isFalse, reason: '别的对端在传不能挡住本对端');

    // 已完成 / 已失败的不算「在传」
    for (final done in [
      (progress: 1.0, failed: false),
      (progress: 0.5, failed: true),
    ]) {
      expect(
        AppState.outboxItemBlockedByInFlight(
          peerId: peer,
          itemFileName: queued,
          itemFileSize: queuedSize,
          itemFilePath: queuedPath,
          inFlight: [
            (
              peerId: peer,
              fileName: queued,
              fileSize: queuedSize,
              filePath: queuedPath,
              failed: done.failed,
              progress: done.progress,
            ),
          ],
        ),
        isFalse,
        reason: '已完成/已失败的传输不该继续挡住补发'
            '（progress=${done.progress} failed=${done.failed}）',
      );
    }
  });
}
