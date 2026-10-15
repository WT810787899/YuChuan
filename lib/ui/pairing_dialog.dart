import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../services/pairing_service.dart';
import '../src/rust/api/pairing.dart' as rust_pairing;

/// 全局导航键：弹窗需要一个稳定的 navigator 上下文。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// 配对操作窗口的**宿主**：监听 AppState.pairingActive，保证
/// ① 全程只有一个窗口（不会叠层卡住界面）
/// ② 状态机还没产出 PIN 时窗口先出现、PIN 回来自动填充（首次请求也能弹出）
/// ③ 成功/取消/关闭后窗口自动收起
class PairingDialogHost extends StatefulWidget {
  const PairingDialogHost({super.key, required this.child});

  final Widget child;

  @override
  State<PairingDialogHost> createState() => _PairingDialogHostState();
}

class _PairingDialogHostState extends State<PairingDialogHost> {
  bool _open = false;
  Timer? _watchdog;

  @override
  void initState() {
    super.initState();
    AppState.instance.addListener(_sync);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void dispose() {
    AppState.instance.removeListener(_sync);
    _watchdog?.cancel();
    super.dispose();
  }

  bool _opening = false;

  void _sync() {
    if (!mounted || _opening) return;
    final wanted = AppState.instance.pairingActive;
    // 兜底看门狗：状态机卡住时，配对窗口最多停留 pairingMaxSeconds 秒
    if (wanted && _watchdog == null) {
      _watchdog = Timer(const Duration(seconds: AppState.pairingMaxSeconds), () {
        _watchdog = null;
        if (mounted && AppState.instance.pairingActive) {
          AppState.instance.cancelPairing();
        }
      });
    } else if (!wanted) {
      _watchdog?.cancel();
      _watchdog = null;
    }
    if (!wanted || _open) return;

    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) {
      // 导航器还没就绪（首帧之前收到配对请求）：下一帧重试，不要放弃
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _sync();
      });
      return;
    }

    _opening = true;
    // 只有真的弹出来才算 open —— 之前先置位再弹，一旦 showDialog 抛错
    // （例如正处于路由切换中），_open 会永远卡在 true，之后再也弹不出来，
    // 表现就是「首次配对请求没有弹窗 / 配对各种卡」。
    _open = true;
    try {
      showDialog<void>(
        context: ctx,
        barrierDismissible: false,
        builder: (_) => const PairingDialog(),
      ).whenComplete(() {
        _open = false;
        _opening = false;
        // 窗口被返回键关掉时也要收尾状态机，避免「窗口没了配对还挂着」
        if (mounted && AppState.instance.pairingActive) {
          AppState.instance.cancelPairing();
        }
      });
    } catch (_) {
      _open = false;
      _opening = false;
      // 弹窗失败不能把状态机卡死：直接收尾，下次请求再试
      AppState.instance.cancelPairing();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class PairingDialog extends StatefulWidget {
  const PairingDialog({super.key});

  @override
  State<PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<PairingDialog> {
  late int _remaining;
  Timer? _timer;
  bool _expired = false;
  bool _celebrating = false;

  @override
  void initState() {
    super.initState();
    final state = AppState.instance;
    _remaining = state.pairingRemainingMs > 0
        ? (state.pairingRemainingMs / 1000).ceil()
        : state.pairingTimeoutSeconds;
    AppState.instance.addListener(_onState);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        _remaining--;
        if (_remaining <= 0) {
          _expired = true;
          t.cancel();
          AppState.instance.pairingCountdownFinished();
        }
      });
    });
  }

  @override
  void dispose() {
    AppState.instance.removeListener(_onState);
    _timer?.cancel();
    super.dispose();
  }

  void _onState() {
    if (!mounted) return;
    final state = AppState.instance;

    // ③ 配对结束（成功动画播完 / 取消 / 被拒）→ 关窗；
    //    之前只播动画不关窗，界面就一直卡在配对弹窗上。
    //
    //    关键：不能在 notifyListeners() 的同步链里直接 pop —— 那条链经常
    //    正处在 build/layout 阶段，同步 Navigator 操作会抛「setState during
    //    build」，整个界面就卡死了（用户反馈的「成功后弹窗不失焦、界面卡死」）。
    //    延后到当前帧结束后再关，绝对安全。
    if (!state.pairingActive) {
      _dismissSafely();
      return;
    }

    // ① 成功：播完 ✓ 动画收尾（宿主会随之关窗）。
    //    额外兜底：成功态停留超过 4s 也强制收尾，绝不允许卡在成功界面。
    if (state.pairingSucceeded) {
      if (!_celebrating) {
        _celebrating = true;
        _timer?.cancel();
        Timer(const Duration(milliseconds: 900), () {
          if (!mounted) return;
          AppState.instance.finishPairingAnimation();
        });
        Timer(const Duration(seconds: 4), () {
          if (!mounted) return;
          if (AppState.instance.pairingActive) {
            AppState.instance.finishPairingAnimation();
          }
        });
      }
      setState(() {});
      return;
    }
    // ② 配对结束且没成功：交给按钮处理错误文案（不要在这里自己 pop，
    //    否则错误一闪而过没人看见）
    setState(() {});
  }

  bool _dismissed = false;

  /// 安全关窗：延后到当前帧结束/微任务，避开 build 期的 Navigator 操作。
  void _dismissSafely() {
    if (_dismissed) return;
    _dismissed = true;
    _timer?.cancel();
    void close() {
      if (!mounted) return;
      Navigator.of(context).maybePop();
    }

    // 优先等下一帧；没帧可等（后台/无调度）时退化到微任务
    try {
      WidgetsBinding.instance.addPostFrameCallback((_) => close());
    } catch (_) {
      Future.microtask(close);
    }
  }
  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final scheme = Theme.of(context).colorScheme;

    if (state.pairingSucceeded) return _success(scheme, _peerName(state));

    // 角色判定：只有**明确是发起方**才显示"等待对方确认"；
    // 角色未知或应答方一律给「确认 / 拒绝」—— 之前角色没回填时
    // 应答方会错弹成"发起配对"，卡在等待态上
    final initiator = state.pairingRole == rust_pairing.PairRoleDto.initiator;
    final pin = (state.pairingPin ?? '').padRight(6, '·');
    final total = state.pairingTimeoutSeconds;
    final error = state.pairingError;

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(26),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  initiator ? Icons.link : Icons.person_add_alt_1_outlined,
                  size: 34,
                  color: scheme.primary,
                ),
                const SizedBox(height: 12),
                Text(
                  initiator
                      ? '与 ${_peerName(state)} 配对'
                      : '${_peerName(state)} 请求配对',
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w700),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                Text(
                  initiator ? '已生成 PIN，请在对方设备上核对' : '请核对双方屏幕上的 6 位 PIN',
                  style: TextStyle(fontSize: 12.5, color: scheme.outline),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < 6; i++) ...[
                      if (i == 3) const SizedBox(width: 10),
                      Container(
                        width: 40,
                        height: 52,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest
                              .withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(
                              color: scheme.primary.withValues(alpha: 0.35)),
                        ),
                        child: Text(
                          pin[i],
                          style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w700,
                              color: scheme.onSurface),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(99),
                        child: LinearProgressIndicator(
                          value: total == 0
                              ? 0
                              : (_remaining / total).clamp(0.0, 1.0),
                          minHeight: 6,
                          backgroundColor:
                              scheme.primary.withValues(alpha: 0.12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _expired ? '已过期' : '${_remaining}s',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color:
                            _expired ? const Color(0xFFEF4444) : scheme.outline,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                // 出错 / 超时：明确给一个出口，避免窗口卡死
                if (error != null && state.pairingPin == null) ...[
                  Text(error,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 12.5, color: Color(0xFFEF4444))),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => AppState.instance.cancelPairing(),
                      child: const Text('知道了'),
                    ),
                  ),
                ] else if (initiator) ...[
                  Row(
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text('已核对 PIN，等待对方确认…',
                            style: TextStyle(
                                fontSize: 12.5, color: scheme.outline)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: _cancel,
                      child: const Text('取消配对'),
                    ),
                  ),
                ] else
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _reject,
                          child: const Text('拒绝'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: FilledButton.icon(
                          onPressed: _expired || state.pairBusy
                              ? null
                              : () =>
                                  state.confirmPairing(state.pairingPin ?? ''),
                          icon:
                              const Icon(Icons.check_circle_outline, size: 18),
                          label: Text(state.pairBusy ? '配对中…' : '确认配对'),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _peerName(AppState state) {
    for (final d in state.devices) {
      if (d.id == state.pairingPeerId) return d.name;
    }
    for (final c in state.pairedContacts) {
      if (c.deviceId == state.pairingPeerId) return c.name;
    }
    return '对方设备';
  }

  Widget _success(ColorScheme scheme, String peerName) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 520),
                curve: Curves.easeOutBack,
                builder: (context, t, _) => Transform.scale(
                  scale: 0.4 + 0.6 * t,
                  child: Opacity(
                    opacity: t.clamp(0.0, 1.0),
                    child: const Icon(Icons.check_circle,
                        size: 66, color: Color(0xFF10B981)),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text('配对成功',
                  style:
                      TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text('已与 $peerName 成为联系人，正在进入会话…',
                  style: TextStyle(fontSize: 12.5, color: scheme.outline)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _cancel() async {
    await AppState.instance.cancelPairing();
  }

  Future<void> _reject() async {
    try {
      await PairingService.instance.reject();
    } catch (_) {}
    await AppState.instance.cancelPairing();
  }
}
