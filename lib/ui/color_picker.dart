import 'package:flutter/material.dart';

/// 自定义取色器：色相条 + 饱和度/明度方块 + 十六进制输入。
///
/// 不引入第三方取色库（零依赖），UI 与系统深浅主题一致。
Future<Color?> showYuChuanColorPicker(
  BuildContext context, {
  required Color initial,
  String title = '自定义颜色',
}) {
  return showDialog<Color>(
    context: context,
    builder: (_) => _ColorPickerDialog(initial: initial, title: title),
  );
}

class _ColorPickerDialog extends StatefulWidget {
  const _ColorPickerDialog({required this.initial, required this.title});

  final Color initial;
  final String title;

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  late HSVColor _hsv;
  late final TextEditingController _hex;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initial);
    _hex = TextEditingController(text: _toHex(_hsv.toColor()));
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  String _toHex(Color c) =>
      '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

  void _apply(HSVColor hsv, {bool updateHex = true}) {
    setState(() {
      _hsv = hsv;
      if (updateHex) _hex.text = _toHex(hsv.toColor());
    });
  }

  void _applyHex(String text) {
    var s = text.trim().replaceFirst('#', '');
    if (s.length == 6) s = 'FF$s';
    final v = int.tryParse(s, radix: 16);
    if (v == null || s.length != 8) return;
    _apply(HSVColor.fromColor(Color(v)), updateHex: false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = _hsv.toColor();

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 16),
              // 饱和度(横) × 明度(纵)
              SizedBox(
                width: double.infinity,
                height: 160,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return GestureDetector(
                        onPanUpdate: (d) => _onSvDrag(
                            constraints, d.localPosition.dx, d.localPosition.dy),
                        onTapDown: (d) => _onSvDrag(
                            constraints, d.localPosition.dx, d.localPosition.dy),
                        child: CustomPaint(
                          painter: _SvPainter(_hsv.hue),
                          child: Stack(
                            children: [
                              Positioned(
                                left: (_hsv.saturation * constraints.maxWidth - 9)
                                    .clamp(0, double.infinity),
                                top: ((1 - _hsv.value) * constraints.maxHeight - 9)
                                    .clamp(0, double.infinity),
                                child: Container(
                                  width: 18,
                                  height: 18,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: color,
                                    border:
                                        Border.all(color: Colors.white, width: 2),
                                    boxShadow: const [
                                      BoxShadow(
                                          color: Colors.black45, blurRadius: 4),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 14),
              // 色相条
              SizedBox(
                height: 22,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(11),
                  child: LayoutBuilder(
                    builder: (context, constraints) => GestureDetector(
                      onPanUpdate: (d) =>
                          _onHueDrag(constraints.maxWidth, d.localPosition.dx),
                      onTapDown: (d) =>
                          _onHueDrag(constraints.maxWidth, d.localPosition.dx),
                      child: CustomPaint(
                        painter: _HuePainter(),
                        child: Stack(
                          children: [
                            Positioned(
                              left: (_hsv.hue / 360 * constraints.maxWidth - 9)
                                  .clamp(0, double.infinity),
                              top: 2,
                              child: Container(
                                width: 18,
                                height: 18,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color:
                                      HSVColor.fromAHSV(1, _hsv.hue, 1, 1).toColor(),
                                  border:
                                      Border.all(color: Colors.white, width: 2),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: scheme.outlineVariant.withValues(alpha: 0.6)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _hex,
                      onChanged: _applyHex,
                      decoration: const InputDecoration(
                        hintText: '#6366F1',
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, color),
                    child: const Text('确定'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _onSvDrag(BoxConstraints c, double dx, double dy) {
    final s = (dx / c.maxWidth).clamp(0.0, 1.0);
    final v = 1 - (dy / c.maxHeight).clamp(0.0, 1.0);
    _apply(_hsv.withSaturation(s).withValue(v));
  }

  void _onHueDrag(double width, double dx) {
    final h = (dx / width).clamp(0.0, 1.0) * 360;
    _apply(_hsv.withHue(h));
  }
}

/// 饱和度(横) × 明度(纵) 渐变方块。
class _SvPainter extends CustomPainter {
  _SvPainter(this.hue);

  final double hue;

  @override
  void paint(Canvas canvas, Size size) {
    final hueColor = HSVColor.fromAHSV(1, hue, 1, 1).toColor();
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [Colors.white, hueColor],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(covariant _SvPainter old) => old.hue != hue;
}

/// 色相条。
class _HuePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          colors: [
            Color.fromRGBO(255, 0, 0, 1),
            Color.fromRGBO(255, 255, 0, 1),
            Color.fromRGBO(0, 255, 0, 1),
            Color.fromRGBO(0, 255, 255, 1),
            Color.fromRGBO(0, 0, 255, 1),
            Color.fromRGBO(255, 0, 255, 1),
            Color.fromRGBO(255, 0, 0, 1),
          ],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
