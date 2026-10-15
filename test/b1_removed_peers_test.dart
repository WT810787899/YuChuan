import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rust_flutter_ui/app_state.dart';

/// 回归：批次B1 第 2 条 —— 「删除不干净，删联系人后有概率下次打开还残留在消息 tab，
/// 显示：未知设备」。
///
/// 根因（修复前）：`AppState._removedPeers` 这个删除墓碑**只存在内存**里，
/// `rebuildConversations` 里 `peers.removeWhere(_removedPeers.contains)` 是唯一闸门。
/// 删完联系人（`removeContact`）后，本地历史 key / 存储摘要仍可能因为删除当时
/// 失败或延迟写回而留着该 peer；一旦**重启进程**，墓碑集合清空，重建会话列表时
/// 该 peer 又被拉回来 —— 此时配对表里已经没有它，`_deviceFor` 只能兜底造名字，
/// 消息 tab 上就显示成「未知设备·xxxx」。
///
/// 修法：墓碑落盘到数据目录下的 `removed_peers.json`，`attachPrefsDir` 时读回，
/// `removeContact` 写盘，`_upsertContact`（重新配对）撤墓碑并写盘。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yc_b1_removed_');
  });

  tearDown(() {
    AppState.instance.attachPrefsDir(''); // 摘掉目录，别影响别的用例
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  File tombstoneFile() =>
      File('${tmp.path}${Platform.pathSeparator}removed_peers.json');

  test('删除后墓碑必须落盘，并且重新 attach 同一目录后仍然屏蔽该 peer', () async {
    final s = AppState.instance;
    s.attachPrefsDir(tmp.path);

    // 模拟「删除当时没删干净」：本地历史里仍然留着这个 peer 的记录。
    // 重启后 rebuildConversations 会把它当作会话来源之一。
    await s.debugSeedHistoryForTest('dev-b1-tomb', '残留消息');

    // 删除联系人（桥接不可用，走内存兜底分支，正是线上「删不干净」的那条路）
    await s.removeContact('dev-b1-tomb', notify: false);

    // 1) 立刻落盘：墓碑文件必须存在且含该 id
    expect(
      tombstoneFile().existsSync(),
      isTrue,
      reason: '删除墓碑必须落盘，否则重启后 _removedPeers 为空，残留 peer 会复活',
    );
    expect(
      jsonDecode(tombstoneFile().readAsStringSync()),
      contains('dev-b1-tomb'),
    );

    // 2) 模拟重启：内存历史仍在（对应「没删干净」），但重建后的会话列表
    //    绝不能再出现这个 peer —— 否则就是「未知设备·xxxx」残留。
    final before = await s.debugConversationIdsForTest();
    expect(
      before,
      isNot(contains('dev-b1-tomb')),
      reason: '删除后本进程内也不允许残留（原有行为，不能被这次修法弄坏）',
    );
  });

  test('重启（冷启动读回墓碑）后：删不干净残留的 peer 不得复活成「未知设备」', () async {
    final s = AppState.instance;

    // 第一次运行：先配对过/有历史 → 删除联系人（落盘墓碑）
    s.attachPrefsDir(tmp.path);
    await s.debugSeedHistoryForTest('dev-b1-restart', '残留消息');
    await s.removeContact('dev-b1-restart', notify: false);
    expect(
      tombstoneFile().existsSync(),
      isTrue,
      reason: '删除时必须落盘墓碑，否则重启后无从读回',
    );

    // 复现用户报的「删不干净」：删除动作没有把该 peer 的历史真正清掉
    //（删除当时写存储失败 / 延迟写回 / 对端重传历史），历史里又出现了它。
    await s.debugSeedHistoryForTest('dev-b1-restart', '删不干净残留');

    // 模拟**冷启动**：内存墓碑清空，只剩盘上那份；历史残留仍在。
    s.debugSimulateRestartKeepHistoryForTest();
    expect(s.debugRemovedPeersForTest(), isEmpty);

    // —— 红点：此时还没走启动路径（墓碑没读回），残留 peer 复活 ——
    // 这正是修复前的行为，也是用户看到的「未知设备·xxxx」。
    expect(
      await s.debugConversationIdsForTest(),
      contains('dev-b1-restart'),
      reason: '前置确认：冷启动后若墓碑没读回，该 peer 确实会复活（这就是 bug 本身）',
    );

    // —— 绿点：启动路径（loadPairingStore 会调 attachPrefsDir）把墓碑读回来 ——
    s.attachPrefsDir(tmp.path);
    expect(
      s.debugRemovedPeersForTest(),
      contains('dev-b1-restart'),
      reason: 'attachPrefsDir（loadPairingStore 会调）必须读回 removed_peers.json',
    );
    expect(
      await s.debugConversationIdsForTest(),
      isNot(contains('dev-b1-restart')),
      reason: '墓碑读回后残留 peer 不得复活成「未知设备·xxxx」（B1 第 2 条）',
    );
  });

  test('回归锚点：光把墓碑写进内存、不落盘时，冷启动一定会残留（证明这条修法是必要的）', () async {
    final s = AppState.instance;
    s.attachPrefsDir(tmp.path);
    await s.debugSeedHistoryForTest('dev-b1-nofile', '残留消息');

    // 只有内存墓碑、盘上没有文件 —— 这就是修复前的状态
    s.debugClearRemovedPeersForTest();
    expect(tombstoneFile().existsSync(), isFalse);
    expect(
      await s.debugConversationIdsForTest(),
      contains('dev-b1-nofile'),
      reason: '没有落盘墓碑时残留 peer 一定复活（= 用户看到的「未知设备」残留）',
    );
  });

  test('重新配对（_upsertContact）后：墓碑从盘上撤掉，该 peer 恢复可见', () async {
    final s = AppState.instance;
    s.attachPrefsDir(tmp.path);
    await s.removeContact('dev-b1-repair', notify: false);
    expect(jsonDecode(tombstoneFile().readAsStringSync()),
        contains('dev-b1-repair'));

    s.debugUpsertContactForTest('dev-b1-repair');

    expect(
      jsonDecode(tombstoneFile().readAsStringSync()),
      isNot(contains('dev-b1-repair')),
      reason: '重新配对过就不该再被墓碑屏蔽，盘上也要撤掉，否则永远看不到它',
    );
  });
}
