import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../services/platform_channel.dart';

/// 链接识别：把文本里的 URL 抽成可点击片段（http/https/ftp/www）。
final RegExp kUrlPattern = RegExp(
  r'(?:https?|ftp)://[^\s<>"（）()【】「」、，。；：！？]+'
  r'|www\.[^\s<>"（）()【】「」、，。；：！？]+',
  caseSensitive: false,
);

/// 尾部常见中英文标点（链接后面紧跟的句号/括号不应算进 URL）。
const String _trailingPunct = ',.;:!?)]}，。；：！？）】、';

/// 去掉尾巴上误吞的中英文标点（「见 https://a.com。」这种）。
String normalizeUrl(String raw) {
  var s = raw.trim();
  while (s.isNotEmpty && _trailingPunct.contains(s[s.length - 1])) {
    s = s.substring(0, s.length - 1);
  }
  if (s.toLowerCase().startsWith('www.')) return 'https://$s';
  return s;
}

/// 从一段文本里找出所有链接（含起止下标），供气泡/预览复用。
List<({int start, int end, String url})> findLinks(String text) {
  final out = <({int start, int end, String url})>[];
  for (final m in kUrlPattern.allMatches(text)) {
    out.add((start: m.start, end: m.end, url: normalizeUrl(m.group(0)!)));
  }
  return out;
}

/// 链接默认色：浅底用深蓝、深底用亮蓝（链接必须一眼看出是蓝色）。
Color defaultLinkColor(Color textColor) =>
    textColor.computeLuminance() > 0.5
        ? const Color(0xFFDBEAFE)
        : const Color(0xFF1E40AF); // 深蓝

/// 可点击链接的富文本：普通文字用 [color]，链接固定用蓝色并加下划线，
/// 点击调起系统浏览器（Android 走 Intent，桌面走默认浏览器）。
///
/// 手势识别器由 State 持有并在 dispose 时释放 —— 直接在 build 里 new
/// TapGestureRecognizer 会随每次重建泄漏（检查泄漏时发现的问题）。
class LinkifiedText extends StatefulWidget {
  const LinkifiedText({
    super.key,
    required this.text,
    required this.color,
    this.linkColor,
    this.fontSize = 14.2,
    this.height = 1.4,
    this.fontWeight,
  });

  final String text;
  final Color color;
  final Color? linkColor;
  final double fontSize;
  final double height;
  final FontWeight? fontWeight;

  @override
  State<LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends State<LinkifiedText> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final linkColor =
        widget.linkColor ?? defaultLinkColor(widget.color);
    final links = findLinks(widget.text);

    if (links.isEmpty) {
      return Text(
        widget.text,
        style: TextStyle(
          fontSize: widget.fontSize,
          height: widget.height,
          color: widget.color,
          fontWeight: widget.fontWeight,
        ),
      );
    }

    // 文本没变就不重建识别器（避免滚动时反复 new/dispose）
    if (_recognizers.length != links.length) {
      for (final r in _recognizers) {
        r.dispose();
      }
      _recognizers
        ..clear()
        ..addAll([for (var i = 0; i < links.length; i++) TapGestureRecognizer()]);
    }

    final spans = <InlineSpan>[];
    var cursor = 0;
    for (var i = 0; i < links.length; i++) {
      final l = links[i];
      if (l.start > cursor) {
        spans.add(TextSpan(
          text: widget.text.substring(cursor, l.start),
          style: TextStyle(
            color: widget.color,
            fontSize: widget.fontSize,
            height: widget.height,
          ),
        ));
      }
      spans.add(TextSpan(
        text: widget.text.substring(l.start, l.end),
        style: TextStyle(
          color: linkColor,
          fontSize: widget.fontSize,
          height: widget.height,
          fontWeight: widget.fontWeight ?? FontWeight.w600,
          decoration: TextDecoration.underline,
          decorationColor: linkColor.withValues(alpha: 0.55),
        ),
        recognizer: _recognizers[i]..onTap = () => YuChuanPlatform.openUrl(l.url),
      ));
      cursor = l.end;
    }
    if (cursor < widget.text.length) {
      spans.add(TextSpan(
        text: widget.text.substring(cursor),
        style: TextStyle(
          color: widget.color,
          fontSize: widget.fontSize,
          height: widget.height,
        ),
      ));
    }
    return RichText(
      text: TextSpan(children: spans),
      textWidthBasis: TextWidthBasis.longestLine,
    );
  }
}
