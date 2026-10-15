import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rust_flutter_ui/app_state.dart';

/// 回归：批次B1 第 1 条 —— 「安卓删除联系人后 发现设备不起作用，没有扫出设备，
/// 要重启才出现」。
///
/// 根因：`AppState._discoverySub` 是**一次性**订阅，只在第一次
/// `enableLiveDiscovery()` 里 `??=` 建起来一次，之后**从不取消也从不重建**。
/// 而 Rust 侧 `discovery_subscribe` 把事件总线的接收端 `take_bus_rx()` 取走
/// （`rust_builder/src/api/discovery.rs:234-261`，接收端只能被取一次，取走后内部
/// `rx` 被置 None）。`discovery_stop()` 之后旧的 bridge 线程随接收端一起结束，
/// 事件总线上再没有接收端。此后即使重新 `start()` 让发现服务跑起来，邻居事件也
/// **没有任何线程在接** —— UI 再也收不到 added/updated 事件，表现就是
/// 「发现设备点了没反应、扫不出设备」，只有重启进程（重建订阅）才恢复。
///
/// 不变量：**任何让发现停下来的路径，都必须让 `_discoverySub` 归零**；
/// 只要这个不变量成立，`enableLiveDiscovery()` 里的 `??=` 就会自动重新订阅。
/// 三个停止路径：`toggleDiscovering` 的停止分支、
/// `setFilterVirtualNic` 的重启循环、`_autoStopDiscovery`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => AppState.instance.attachPrefsDir(''));

  test('停止发现（toggleDiscovering 的停止分支）必须释放订阅', () {
    final s = AppState.instance;

    expect(
      s.debugDiscoverySubscribedForTest,
      isFalse,
      reason: '初始状态不该有订阅',
    );

    // 先摆好「发现正在跑、订阅已建立」，再走**生产代码**的停止分支。
    // 释放订阅这件事不能靠测试帮忙做 —— helper 里做掉就等于没测生产代码。
    s.debugMarkLiveDiscoveryForTest(true);
    s.debugAttachIdleDiscoverySubForTest();
    expect(s.debugDiscoverySubscribedForTest, isTrue, reason: '前置：订阅已挂上');

    s.toggleDiscovering();

    expect(
      s.debugDiscoverySubscribedForTest,
      isFalse,
      reason: '停止发现后订阅必须释放，否则下次开始发现会复用已死的订阅（B1 第 1 条）',
    );
  });

  test('切换虚拟网卡过滤（stop→start 循环）必须释放订阅', () async {
    final s = AppState.instance;

    s.debugMarkLiveDiscoveryForTest(true);
    s.debugAttachIdleDiscoverySubForTest();

    // setFilterVirtualNic 是最容易被复现的 stop→start 循环：它必然走一遍
    // 「旧桥已死、`??=` 跳过重订阅」的路径。
    await s.setFilterVirtualNic(!s.filterVirtualNic);

    expect(
      s.debugDiscoverySubscribedForTest,
      isFalse,
      reason: '重启发现前必须先放掉旧订阅，否则重订阅会被 ??= 跳过（B1 第 1 条）',
    );
  });

  test('删除联系人后订阅不得残留（残留则再发现扫不出设备）', () async {
    final s = AppState.instance;
    final tmp = Directory.systemTemp.createTempSync('yc_b1_discovery_');
    addTearDown(() {
      s.attachPrefsDir('');
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
    s.attachPrefsDir(tmp.path);

    s.debugMarkLiveDiscoveryForTest(true);
    s.debugAttachIdleDiscoverySubForTest();

    // 删掉唯一联系人：pairedContacts 变空，随后走的都是停止发现的路径。
    await s.removeContact('dev-b1-only', notify: false);

    // 删除路径本身不一定要停发现；但**只要**发现被停下了，订阅就必须归零。
    // 这里断言的是不变量本身，而不是某一条具体路径的副作用：
    // liveDiscovery 为 false 时不允许还挂着订阅。
    if (!s.liveDiscovery) {
      expect(
        s.debugDiscoverySubscribedForTest,
        isFalse,
        reason: '发现已停却仍挂着旧订阅，下一次「开始发现」会扫不出设备（B1 第 1 条）',
      );
    }
  });

  test('自动停发现（配对成功后 _autoStopDiscovery）也必须释放订阅', () async {
    final s = AppState.instance;

    s.debugMarkLiveDiscoveryForTest(true);
    s.debugAttachIdleDiscoverySubForTest();
    // _autoStopDiscovery 的第二个守卫是 pairedContacts.isEmpty，
    // 所以必须有一个联系人才会真的走到停止逻辑。
    s.debugUpsertContactForTest('dev-b1-auto');
    expect(s.debugDiscoverySubscribedForTest, isTrue, reason: '前置：订阅已挂上');

    await s.debugAutoStopDiscoveryForTest();

    expect(
      s.debugDiscoverySubscribedForTest,
      isFalse,
      reason: '配对成功自动停发现也是「让发现停下来」的路径，订阅必须一并释放（B1 第 1 条）',
    );
  });

  test('释放订阅必须发生在 FFI stop() 之前：桥抛异常时也不能漏掉订阅', () async {
    final s = AppState.instance;

    // 不初始化桥接 —— DiscoveryService.instance.stop() 一定会抛
    // `Bad state: flutter_rust_bridge has not been initialized`。
    // 若实现把 _releaseDiscoverySub() 写在 stop() 之后，这条例用就会红：
    // 异常把后面的释放代码整个跳过，订阅永久漏掉（这正是「要重启才出现」的形态）。
    s.debugMarkLiveDiscoveryForTest(true);
    s.debugAttachIdleDiscoverySubForTest();

    // toggleDiscovering 是 async：必须 await 完，否则断言跑在 stop() 之前，
    // 测的只是「同步段」而不是整条路径。
    await s.toggleDiscovering();

    expect(
      s.debugDiscoverySubscribedForTest,
      isFalse,
      reason: 'stop() 抛异常时若订阅没被释放，说明释放写在 FFI 调用之后了 —— '
          '这条路径下订阅会永久泄漏，下次「开始发现」复用死订阅 = 扫不出设备',
    );
    expect(s.liveDiscovery, isFalse, reason: '抛异常后 UI 状态仍须复位');
  });
}
