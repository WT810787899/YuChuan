import 'package:flutter_test/flutter_test.dart';
import 'package:rust_flutter_ui/app_state.dart';

/// 拨号闸门的契约测试（Task 11 / 根因1）。
///
/// 背景：`_dialed` 曾是**永久**去重集合 —— 首次拨号失败（或当时还没拿到
/// 对端 IP）之后 peerId 就留在集合里，此后 `ensureDial` 永远早退，
/// 对端永远等不到 Connected 事件，`_syncAfterConnect` 的离线补发也就
/// 永远不会触发。这正是用户报的「离线发送对端收不到」。
/// 改成带冷却的 `_dialedAt` 后，冷却期一过就会重拨。
void main() {
  test('冷却期内不重拨（避免每 400ms 轮询把对端打爆）', () {
    final t0 = DateTime(2026, 1, 1, 12, 0, 0);
    expect(
      AppState.isDialCoolingDown(t0, t0.add(const Duration(seconds: 1))),
      isTrue,
    );
    expect(
      AppState.isDialCoolingDown(t0, t0.add(const Duration(milliseconds: 4999))),
      isTrue,
    );
  });

  test('冷却期过后允许重拨（这是「永久闸门」被修掉的证据）', () {
    final t0 = DateTime(2026, 1, 1, 12, 0, 0);
    expect(
      AppState.isDialCoolingDown(t0, t0.add(const Duration(seconds: 5))),
      isFalse,
    );
    expect(
      AppState.isDialCoolingDown(t0, t0.add(const Duration(minutes: 30))),
      isFalse,
    );
  });
}
