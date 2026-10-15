import 'package:flutter/material.dart';

import '../models.dart';

/// 本机/设备头像：**App 图标风**（参考用户给的三张图）。
///
/// 配色（用户指定）：手机 = 橙系，PC = 蓝系；两端色相拉开，一眼可分。
/// 风格基准是第三张图的「插画感 App 图标」：
///  · 圆角方块（squircle 愔觉，22%）
///  · 渐变底 + 左上高光 + 右下压暗（有体积，不是纯色）
///  · 主体白色实心图标（白字/白图形，对比强）
///  · 角落点缀 2 颗四角星芒，做出那张图的「闪光」氛围
class MyDeviceAvatar extends StatelessWidget {
  const MyDeviceAvatar({
    super.key,
    required this.size,
    this.platform,
  });

  /// 边长（正方形）。
  final double size;

  /// 显式平台；null = 跟随当前运行平台（本机头像用）。
  final DevicePlatform? platform;

  // 手机：橙系（参考图一）
  static const phoneA = Color(0xFFFF8A2B);
  static const phoneB = Color(0xFFF04E0A);

  // PC：蓝系（参考图二）
  static const pcA = Color(0xFF3FA3FF);
  static const pcB = Color(0xFF1168E8);

  @override
  Widget build(BuildContext context) {
    final p = platform ??
        (Theme.of(context).platform == TargetPlatform.android
            ? DevicePlatform.android
            : DevicePlatform.windows);
    final isPhone = p == DevicePlatform.android;
    final a = isPhone ? phoneA : pcA;
    final b = isPhone ? phoneB : pcB;
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.22),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // ① 斜向渐变底
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [a, b],
              ),
            ),
          ),
          // ② 左上柔光高光
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.55, -0.62),
                radius: 1.0,
                colors: [
                  Colors.white.withValues(alpha: 0.38),
                  Colors.white.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
          // ③ 右下压暗
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0.7, 0.78),
                radius: 0.9,
                colors: [
                  Colors.black.withValues(alpha: 0.18),
                  Colors.black.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
          // ④ 角落星芒：只有手机端画（用户要求 PC 不要星光）
          if (isPhone)
            Positioned.fill(
              child: CustomPaint(
                painter: _SparklePainter(
                  color: Colors.white.withValues(alpha: 0.75),
                ),
              ),
            ),
          // ⑤ 主体图标
          Center(
            child: CustomPaint(
              size: Size.square(size * 0.72),
              painter: isPhone
                  ? const _PhoneIconPainter(color: Colors.white, bg: phoneA)
                  : const _LaptopIconPainter(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

Paint _stroke(Color color, double s) => Paint()
  ..color = color
  ..style = PaintingStyle.stroke
  ..strokeWidth = s * 0.09
  ..strokeCap = StrokeCap.round;

/// 四角星芒（ sparkle ）：凹边四角星，比正方形更有「闪光」感。
class _SparklePainter extends CustomPainter {
  const _SparklePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final paint = Paint()..color = color;
    // (相对位置, 半径)：右上一颗小、左下一颗更小
    const sparks = [
      (0.80, 0.20, 0.075),
      (0.20, 0.83, 0.050),
    ];
    for (final (fx, fy, fr) in sparks) {
      _drawSpark(canvas, Offset(w * fx, h * fy), w * fr, paint);
    }
  }

  void _drawSpark(Canvas canvas, Offset c, double r, Paint paint) {
    final k = r * 0.22; // 凹边控制点
    final path = Path()
      ..moveTo(c.dx, c.dy - r)
      ..quadraticBezierTo(c.dx + k, c.dy - k, c.dx + r, c.dy)
      ..quadraticBezierTo(c.dx + k, c.dy + k, c.dx, c.dy + r)
      ..quadraticBezierTo(c.dx - k, c.dy + k, c.dx - r, c.dy)
      ..quadraticBezierTo(c.dx - k, c.dy - k, c.dx, c.dy - r)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_SparklePainter old) => old.color != color;
}

/// 笔记本（白色）：屏幕描边 + 屏内 'PC' + 更宽的键盘座。
class _LaptopIconPainter extends CustomPainter {
  const _LaptopIconPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final stroke = _stroke(color, w);

    // 居中构图：上下留白各 0.10（原来上 0.05 下 0.14，整体偏上）
    // 屏幕加大到 0.62h、底座压到 0.10h（原来屏幕 0.59h、底座 0.14h）
    final scrTop = h * 0.10;
    final scrBot = h * 0.72;
    final scrL = w * 0.13;
    final scrR = w * 0.87;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(scrL, scrTop, scrR, scrBot),
        Radius.circular(w * 0.06),
      ),
      stroke,
    );

    final tp = TextPainter(
      text: TextSpan(
        text: 'PC',
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: (scrBot - scrTop) * 0.52,
          letterSpacing: -0.5,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset((w - tp.width) / 2, (scrTop + scrBot - tp.height) / 2));

    final baseTop = scrBot + h * 0.08;
    final baseH = h * 0.10;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, baseTop, w, baseH),
        Radius.circular(baseH * 0.42),
      ),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_LaptopIconPainter old) => old.color != color;
}

/// 手机（白色实心 + 挖空屏）：实心机身 + 屏幕镂空 + 刘海 + Home 条。
class _PhoneIconPainter extends CustomPainter {
  const _PhoneIconPainter({required this.color, required this.bg});

  final Color color;
  final Color bg;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final bodyW = w * 0.60;
    final left = (w - bodyW) / 2;
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(left, 0, bodyW, h),
      Radius.circular(bodyW * 0.18),
    );
    canvas.drawRRect(body, Paint()..color = color);

    // 屏幕：用底色挖空（真·镂空）
    final pad = bodyW * 0.10;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          left + pad,
          pad * 2.6,
          bodyW - pad * 2,
          h - pad * 4.2,
        ),
        Radius.circular(bodyW * 0.10),
      ),
      Paint()..color = bg,
    );

    // 顶部刘海
    final notchW = bodyW * 0.30;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH((w - notchW) / 2, pad * 1.4, notchW, h * 0.026),
        Radius.circular(h * 0.013),
      ),
      Paint()..color = color,
    );

    // 底部 Home 条
    final homeW = bodyW * 0.40;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH((w - homeW) / 2, h - pad * 2.4, homeW, h * 0.022),
        Radius.circular(h * 0.011),
      ),
      Paint()..color = bg,
    );
  }

  @override
  bool shouldRepaint(_PhoneIconPainter old) => old.color != color || old.bg != bg;
}
