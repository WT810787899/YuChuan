import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models.dart';
import '../services/discovery_service.dart';
import 'chat_list.dart';
import 'menus.dart';
import 'osd_toast.dart';

// ============================================================
// Left panel: discovery
// ============================================================

class DiscoveryPanel extends StatefulWidget {
  const DiscoveryPanel({super.key});

  @override
  State<DiscoveryPanel> createState() => _DiscoveryPanelState();
}

class _DiscoveryPanelState extends State<DiscoveryPanel> {
  final _state = AppState.instance;
  final _manualCtrl = TextEditingController();

  @override
  void dispose() {
    _manualCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '设备发现',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _state.toggleDiscovering,
                    icon: Icon(
                      _state.discovering ? Icons.stop : Icons.radar,
                      size: 16,
                    ),
                    label: Text(_state.discovering ? '停止发现' : '开始发现'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // 发现雷达：真实 discovering 状态驱动（停止后转静态，PLAN §3.2）
              _DiscoveryRadarCard(state: _state),
              const SizedBox(height: 10),
              // 本机卡片：显示真实的设备名 / 设备 id / 本机地址（不再是硬编码占位）
              _LocalDeviceCard(state: _state),
            ],
          ),
        ),
        if (_state.discovering)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LinearProgressIndicator(minHeight: 3),
                const SizedBox(height: 6),
                Text(
                  _state.discoveryScanningText,
                  style: TextStyle(fontSize: 11, color: scheme.outline),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        // Android 权限引导卡（PLAN §3.2：先解释用途，再决定是否弹系统框）
        if (_state.localPlatform == 'android' &&
            !_state.notificationsGranted &&
            !_state.permissionCardDismissed)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: _PermissionGuideCard(state: _state),
          ),
        // manual connect
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _manualCtrl,
                  decoration: const InputDecoration(
                    hintText: '手动连接  IP:端口（AP 隔离时用）',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () {
                  _state.connectManual(_manualCtrl.text);
                  _manualCtrl.clear();
                },
                child: const Text('直连'),
              ),
            ],
          ),
        ),
        Expanded(
          child: _state.devices.isEmpty
              ? _DiscoveryEmptyState(state: _state)
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 8),
                  itemCount: _state.devices.length,
                  itemBuilder: (context, i) => _DeviceRow(deviceIndex: i),
                ),
        ),
      ],
    );
  }
}

/// 本机身份卡片：真实设备名 + 短 id + 本机地址（之前这里是硬编码的
/// 「本机 · DESKTOP-ORION / 192.168.1.23:9527」，双端都显示同一份假身份）。
class _LocalDeviceCard extends StatelessWidget {
  const _LocalDeviceCard({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final android = state.localPlatform == 'android';
    final addresses = state.localAddresses;
    final addrText = addresses.isEmpty
        ? (state.liveDiscovery ? '未解析到本机地址' : '演示模式（未连接 Rust）')
        : addresses
            .map((a) => '$a:${DiscoveryService.defaultChatPort}')
            .join('  ');

    String copyText() => addresses.isEmpty
        ? state.localDeviceName
        : addresses
            .map((a) => '$a:${DiscoveryService.defaultChatPort}')
            .join(' ');

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)],
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(android ? Icons.smartphone : Icons.computer,
                size: 18, color: Colors.white),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '本机 · ${state.localDeviceName}',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  addrText,
                  style: TextStyle(fontSize: 11.5, color: scheme.outline),
                ),
                if (state.liveDiscovery) ...[
                  const SizedBox(height: 2),
                  Text(
                    'ID ${state.localDeviceIdShort}'
                    '${state.multicastLockHeld ? ' · 组播锁已持有' : ''}',
                    style: TextStyle(fontSize: 10.5, color: scheme.outline),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: '复制本机地址',
            icon: Icon(Icons.copy, size: 16, color: scheme.outline),
            onPressed: () {
              // 横幅已删除：通知统一走 OSD
              OsdToast.info(context, '已复制 ${copyText()}');
            },
          ),
        ],
      ),
    );
  }
}

/// 空状态：说清「为什么没发现」，而不是只留一句「未发现设备」。
class _DiscoveryEmptyState extends StatelessWidget {
  const _DiscoveryEmptyState({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hint = state.discoveryHint;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_find, size: 34, color: scheme.outline),
            const SizedBox(height: 10),
            Text(
              state.liveDiscovery ? '还没有发现设备' : '未发现设备',
              style:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              hint.isEmpty
                  ? (state.liveDiscovery
                      ? '发现服务运行中：同一 Wi-Fi 下另一台设备打开本应用即可互见。'
                      : '点「开始发现」，或用上面的 IP:端口 手动直连。')
                  : hint,
              textAlign: TextAlign.center,
              style:
                  TextStyle(fontSize: 12, height: 1.5, color: scheme.outline),
            ),
            if (state.liveDiscovery) ...[
              const SizedBox(height: 14),
              Text(
                '发出 HELLO ${state.hellosSent} 次 · 收到 ${state.hellosReceived} 次'
                '${state.hellosIgnored > 0 ? ' · 忽略 ${state.hellosIgnored} 次' : ''}',
                style: TextStyle(fontSize: 11, color: scheme.outline),
              ),
              const SizedBox(height: 4),
              Text(
                state.localInterfaces.isEmpty
                    ? '网卡：未识别到可用网卡'
                    : '网卡：${state.localInterfaces.join('，')}',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 10.5, color: scheme.outline),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: state.announceNow,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重新发现'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 发现雷达卡片：状态行 + 动画雷达。真实模式显示真实端口 / 网卡 / 组播状态。
class _DiscoveryRadarCard extends StatelessWidget {
  const _DiscoveryRadarCard({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scanning = state.discovering;
    final live = state.liveDiscovery;

    return Row(
      children: [
        _DiscoveryRadar(active: scanning, blips: state.devices.length, size: 92),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: scanning
                          ? const Color(0xFF10B981)
                          : scheme.outline,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    scanning ? '发现中' : '已停止发现',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                scanning
                    ? '已发现 ${state.devices.length} 台设备'
                        '${live ? ' · 3s 心跳' : ' · 演示模式'}'
                    : '点右上角「开始发现」重新扫描',
                style: TextStyle(fontSize: 11.5, color: scheme.outline),
              ),
              const SizedBox(height: 2),
              Text(
                scanning && live
                    ? 'UDP :${state.discoveryListenPort} · 网卡 '
                        '${state.localInterfaces.length} 块 · '
                        '${state.discoveryMulticast ? '组播已加入' : '广播兜底'}'
                    : '组播 239.255.42.99 · UDP 45999',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10.5, color: scheme.outline),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 雷达/脉冲动画：只在 discovering 时转动，停止后转静态（PLAN §3.2），
/// 并尊重系统「减少动态效果」。设备光点按黄金角稳定分布。
class _DiscoveryRadar extends StatefulWidget {
  const _DiscoveryRadar({
    required this.active,
    required this.blips,
    this.size = 92,
  });

  final bool active;
  final int blips;
  final double size;

  @override
  State<_DiscoveryRadar> createState() => _DiscoveryRadarState();
}

class _DiscoveryRadarState extends State<_DiscoveryRadar>
    with SingleTickerProviderStateMixin {
  // 必须在 initState 里创建：字段懒初始化 + active=false 时 build 不引用它，
  // 会在 dispose 时才首次创建 → 对象已卸载后访问祖先 → 断言崩溃（widget_test 抓到）
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );
    if (widget.active) _ctrl.repeat();
  }

  @override
  void didUpdateWidget(covariant _DiscoveryRadar old) {
    super.didUpdateWidget(old);
    if (widget.active && !_ctrl.isAnimating) {
      _ctrl.repeat();
    } else if (!widget.active && _ctrl.isAnimating) {
      _ctrl.stop();
      _ctrl.value = 0;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final animate = widget.active && !reduceMotion;

    return RepaintBoundary(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: animate
            ? AnimatedBuilder(
                animation: _ctrl,
                builder: (context, _) => CustomPaint(
                  painter: _RadarPainter(
                    color: scheme.primary,
                    t: _ctrl.value,
                    blips: widget.blips,
                  ),
                ),
              )
            : CustomPaint(
                painter: _RadarPainter(
                  color: scheme.outline,
                  t: 0,
                  blips: widget.blips,
                  idle: true,
                ),
              ),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({
    required this.color,
    required this.t,
    required this.blips,
    this.idle = false,
  });

  final Color color;
  final double t;
  final int blips;
  final bool idle;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxR = size.width / 2;

    canvas.drawCircle(
      center,
      maxR,
      Paint()
        ..style = PaintingStyle.fill
        ..color = color.withValues(alpha: idle ? 0.05 : 0.07),
    );
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color.withValues(alpha: 0.18);
    for (final f in const [0.35, 0.65, 1.0]) {
      canvas.drawCircle(center, maxR * f, ring);
    }
    canvas.drawLine(
        Offset(center.dx, center.dy - maxR), Offset(center.dx, center.dy + maxR), ring);
    canvas.drawLine(
        Offset(center.dx - maxR, center.dy), Offset(center.dx + maxR, center.dy), ring);

    if (!idle) {
      final sweep = t * 2 * pi;
      final sweepPaint = Paint()
        ..shader = SweepGradient(
          colors: [
            color.withValues(alpha: 0.0),
            color.withValues(alpha: 0.32),
          ],
          transform: GradientRotation(sweep),
        ).createShader(Rect.fromCircle(center: center, radius: maxR));
      canvas.drawCircle(center, maxR, sweepPaint);
      canvas.drawLine(
        center,
        center + Offset(cos(sweep), sin(sweep)) * maxR,
        Paint()
          ..color = color.withValues(alpha: 0.75)
          ..strokeWidth = 1.6,
      );
    }

    final blipCount = blips > 8 ? 8 : blips;
    for (var i = 0; i < blipCount; i++) {
      final angle = (i * 2.399963) % (2 * pi);
      final radius = maxR * (0.30 + 0.12 * ((i * 37) % 5));
      final point = center + Offset(cos(angle), sin(angle)) * radius;
      final pulse =
          idle ? 0.55 : 0.45 + 0.55 * (0.5 + 0.5 * sin(t * 2 * pi * 2 + i));
      canvas.drawCircle(
        point,
        3.2,
        Paint()..color = const Color(0xFF10B981).withValues(alpha: pulse),
      );
      canvas.drawCircle(
        point,
        5.8,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = const Color(0xFF10B981).withValues(alpha: pulse * 0.45),
      );
    }

    canvas.drawCircle(center, 4, Paint()..color = color.withValues(alpha: 0.9));
  }

  @override
  bool shouldRepaint(covariant _RadarPainter old) =>
      old.t != t ||
      old.color != color ||
      old.blips != blips ||
      old.idle != idle;
}

/// Android 权限引导卡（PLAN §3.2）：先解释用途，用户同意后才弹系统权限框；
/// 「暂不」也不是死路 —— 收发消息照常，只是收不到系统通知。
class _PermissionGuideCard extends StatelessWidget {
  const _PermissionGuideCard({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const amber = Color(0xFFF59E0B);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 10, 6),
      decoration: BoxDecoration(
        color: amber.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: amber.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.notifications_active_outlined,
                  size: 16, color: amber),
              const SizedBox(width: 6),
              const Text(
                '开启通知权限',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '暂不',
                icon: Icon(Icons.close, size: 15, color: scheme.outline),
                onPressed: state.dismissPermissionCard,
              ),
            ],
          ),
          Text(
            '用于接收对方发来的消息与文件提醒。不授权也能正常收发，只是切到后台时收不到系统通知。',
            style: TextStyle(fontSize: 11, height: 1.4, color: scheme.outline),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              FilledButton.tonal(
                onPressed: state.requestNotifications,
                child: const Text('允许通知'),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: state.dismissPermissionCard,
                child: const Text('暂不'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DeviceRow extends StatefulWidget {
  const _DeviceRow({required this.deviceIndex});

  final int deviceIndex;

  @override
  State<_DeviceRow> createState() => _DeviceRowState();
}

class _DeviceRowState extends State<_DeviceRow> {
  bool hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = AppState.instance;
    final dev = state.devices[widget.deviceIndex];
    final selected = state.navIndex == 1 &&
        state.selectedDevice == widget.deviceIndex;

    return MouseRegion(
      onEnter: (_) => setState(() => hovered = true),
      onExit: (_) => setState(() => hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          state.setNavIndex(1);
          state.selectDevice(widget.deviceIndex);
        },
        // 移动端长按 / 桌面右键：设备专属操作菜单（带图标）
        onLongPress: () => _showDeviceMenu(dev),
        onSecondaryTap: () => _showDeviceMenu(dev),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primary.withValues(alpha: 0.10)
                : hovered
                    ? scheme.surfaceContainerHighest.withValues(alpha: 0.6)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: selected
                ? Border.all(color: scheme.primary.withValues(alpha: 0.35))
                : null,
          ),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  DeviceAvatar(device: dev, radius: 21),
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color:
                            dev.online ? const Color(0xFF10B981) : Colors.grey,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: scheme.surface,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            dev.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: 5),
                        Icon(dev.platformIcon, size: 13, color: scheme.outline),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      dev.ip,
                      style: TextStyle(fontSize: 12, color: scheme.outline),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (dev.paired)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Text(
                        '已配对',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF10B981),
                        ),
                      ),
                    )
                  else
                    Text(
                      dev.online ? '未配对' : '离线',
                      style: TextStyle(fontSize: 11, color: scheme.outline),
                    ),
                  const SizedBox(height: 3),
                  if (dev.online && dev.rttMs > 0)
                    Text(
                      '${dev.rttMs} ms',
                      style: TextStyle(fontSize: 10.5, color: scheme.outline),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
  /// 设备行菜单：移动端长按 / 桌面右键。按配对状态给出不同操作。
  Future<void> _showDeviceMenu(LanDevice dev) async {
    final state = AppState.instance;
    final actions = <IconMenuAction>[
      IconMenuAction(
        id: 'detail',
        label: '查看设备详情',
        icon: Icons.info_outline,
        run: () async {
          state.setNavIndex(1);
          state.selectDevice(widget.deviceIndex);
        },
      ),
      if (dev.paired && dev.online)
        IconMenuAction(
          id: 'chat',
          label: '发消息',
          icon: Icons.chat_bubble_outline,
          run: () async => state.openConversationWith(dev.id),
        ),
      if (!dev.paired && dev.online)
        IconMenuAction(
          id: 'pair',
          label: '发起配对',
          icon: Icons.link,
          run: () async => state.beginPairing(dev),
        ),
      IconMenuAction(
        id: 'copy',
        label: '复制 IP:端口',
        icon: Icons.copy_outlined,
        run: () async {
          final port = dev.chatPort == 0
              ? DiscoveryService.defaultChatPort
              : dev.chatPort;
          await Clipboard.setData(
              ClipboardData(text: '${dev.ip}:$port'));
        },
      ),
      IconMenuAction(
        id: 'redial',
        label: '重新连接',
        icon: Icons.refresh,
        run: () async => state.ensureDial(dev.id),
      ),
    ];
    if (!mounted) return;
    final picked =
        await showIconMenu(context, actions: actions, header: dev.name);
    await runIconMenuAction(picked, actions);
  }
}

// ============================================================
// Right area: device detail / pairing
// ============================================================

class DeviceDetailView extends StatefulWidget {
  const DeviceDetailView({super.key});

  @override
  State<DeviceDetailView> createState() => _DeviceDetailViewState();
}

class _DeviceDetailViewState extends State<DeviceDetailView> {
  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final idx = state.selectedDevice;
    if (idx == null || idx >= state.devices.length) {
      return const SizedBox.shrink();
    }
    final dev = state.devices[idx];
    final narrow = MediaQuery.sizeOf(context).width < 900;

    return Column(
      children: [
        Container(
          constraints: const BoxConstraints(minHeight: 60),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).cardTheme.color,
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context)
                    .colorScheme
                    .outlineVariant
                    .withValues(alpha: 0.4),
              ),
            ),
          ),
          child: Row(
            children: [
              if (narrow)
                IconButton(
                  icon: const Icon(Icons.arrow_back, size: 20),
                  onPressed: state.backToListPanel,
                ),
              const Text('设备详情', style: TextStyle(fontWeight: FontWeight.w700)),
            ],
          ),
        ),
        // 配对统一由全局 PairingDialog 负责；这里不再渲染内嵌 PIN 卡 ——
        // 两套 UI 叠在一起会互相打架、界面卡死（用户截图反馈的那层背景按钮）
        Expanded(child: _buildDetail(context, state, dev)),
      ],
    );
  }


  Widget _buildDetail(
      BuildContext context, AppState state, LanDevice dev) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        child: Container(
          width: 420,
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: Theme.of(context).cardTheme.color,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DeviceAvatar(device: dev, radius: 40),
              const SizedBox(height: 14),
              Text(
                dev.name,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  _chip(
                    dev.platform == DevicePlatform.windows
                        ? 'Windows'
                        : 'Android',
                    Icons.devices,
                  ),
                  _chip(dev.ip, Icons.lan_outlined),
                  _chip(dev.online ? '在线 · ${dev.rttMs} ms' : '离线',
                      dev.online ? Icons.signal_wifi_4_bar : Icons.wifi_off,
                      color: dev.online
                          ? const Color(0xFF10B981)
                          : scheme.outline),
                  if (dev.paired)
                    _chip('已配对', Icons.verified, color: const Color(0xFF10B981)),
                ],
              ),
              const SizedBox(height: 22),
              if (dev.paired)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: dev.online
                        ? () => _openChat(state, dev)
                        : null,
                    icon: const Icon(Icons.chat, size: 18),
                    label: const Text('发消息'),
                  ),
                )
              else ...[
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: dev.online
                        ? () {
                            // 真发起：Rust 生成 6 位 PIN 并建会话（T2.1）
                            state.beginPairing(dev);
                          }
                        : null,
                    icon: const Icon(Icons.link, size: 18),
                    label: const Text('开始配对'),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  dev.online ? '配对需要双方确认 6 位 PIN' : '设备离线，无法配对',
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(String text, IconData icon, {Color? color}) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: c),
          const SizedBox(width: 5),
          Text(
            text,
            style: TextStyle(
                fontSize: 12, color: c, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  void _openChat(AppState state, LanDevice dev) {
    // 统一走 peer_id 取/建会话，消息列表才是共享的那一份（新消息才会实时上屏）
    state.openConversationWith(dev.id);
  }

}

