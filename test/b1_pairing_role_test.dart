import 'package:flutter_test/flutter_test.dart';
import 'package:rust_flutter_ui/app_state.dart';
import 'package:rust_flutter_ui/src/rust/api/pairing.dart' as rust;

/// 回归：批次B1 第 3 条 —— 「手机端发起的配对申请，对端显示的也是反过来的
/// 配对申请，而不是同意窗」。
///
/// 弹窗按 `pairingRole` 决定方向（lib/ui/pairing_dialog.dart:215）：
/// initiator → 「与 X 配对 / 等待对方确认」；responder → 「X 请求配对 / 确认配对」。
///
/// 根因（修复前）：`beginResponderPairing` 把角色占位设成 responder 之后，又
/// **无条件**用 `outcome.session.role` 覆盖它。若本机此刻正卡在这个对端的
/// `WaitingResponse`（本机先前发起过、对端还没回），这条 PAIR_REQ 在 Rust 状态机
/// 里只会被回一个 Busy —— **角色/状态一个都不改**（`rust_builder/src/backend/
/// pairing.rs` 的 `on_request`），于是 `session.role` 仍是 initiator，弹窗就渲染成
/// 「与 X 配对 / 等待对方确认」这套发起方 UI，即用户看到的「反过来」。
///
/// 判定语义：**只有状态机确实进入了应答态（awaitingConfirm）才采纳会话角色**；
/// failed / busy / 状态未变一律保持入口设定的 responder。这条规则被抽成纯函数
/// `AppState.responderRoleAfter`，所以这里能钉住它 —— 桥接在测试环境不可用时，
/// 走 `beginResponderPairing` 真链路会在 try 里异常早退，测不到那一行。
void main() {
  const responder = rust.PairRoleDto.responder;
  const initiator = rust.PairRoleDto.initiator;

  test('Busy/失败：不得采纳 initiator（否则对端看到的是反过来的配对申请）', () {
    expect(
      AppState.responderRoleAfter(
        wasResponder: true,
        state: rust.PairStateDto.failed,
        sessionRole: initiator,
      ),
      responder,
      reason: '状态机没进入 awaitingConfirm（Busy 失败）时角色必须保持应答方，'
          '否则弹窗标题/按钮走发起方那套 = 用户报的「反过来的配对申请」',
    );
  });

  test('Busy 且状态仍是 WaitingResponse（本机先前发起）：同样不得被翻成发起方', () {
    expect(
      AppState.responderRoleAfter(
        wasResponder: true,
        state: rust.PairStateDto.waitingResponse,
        sessionRole: initiator,
      ),
      responder,
      reason: '这正是 on_request 回 Busy 后 session.role 仍是 initiator 的真实形态',
    );
  });

  test('真的进了应答态（awaitingConfirm）：采纳会话角色', () {
    expect(
      AppState.responderRoleAfter(
        wasResponder: true,
        state: rust.PairStateDto.awaitingConfirm,
        sessionRole: responder,
      ),
      responder,
    );
  });

  test('非应答方入口不受影响：保持会话角色', () {
    // wasResponder: false 时保持会话角色（发起方入口等），
    // 避免这次修复把发起方那条路也一起改了。
    expect(
      AppState.responderRoleAfter(
        wasResponder: false,
        state: rust.PairStateDto.failed,
        sessionRole: initiator,
      ),
      initiator,
    );
  });
}
