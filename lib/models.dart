import 'package:flutter/material.dart';

// ============================================================
// Domain models (mock data layer — M1+ swaps in Rust-backed data)
// ============================================================

/// 发送方气泡底色（绿色）。链接/状态色都以它为对比基准。
const Color kOutgoingBubble = Color(0xFF10B981);

enum DevicePlatform { windows, android }

enum MessageKind { text, image, file }

enum SendState { sending, sent, delivered, failed }

class LanDevice {
  LanDevice({
    required this.id,
    required this.name,
    required this.ip,
    required this.platform,
    this.online = true,
    this.paired = false,
    this.rttMs = 0,
    this.chatPort = 0,
    this.alias = '',
  });

  /// 用户给该联系人起的备注名；空 = 用设备原名。
  ///
  /// 可变：备注随时可改，不需要重建整个设备对象。
  String alias;

  final String id;
  final String name;
  final String ip;
  final DevicePlatform platform;
  final bool online;
  final bool paired;
  final int rttMs;

  /// 对端 TCP 聊天端口（来自发现阶段的 HELLO；0 = 未知，用默认端口）。
  final int chatPort;

  /// 显示名：备注优先，其次设备原名。
  String get displayName => alias.isNotEmpty ? alias : name;

  Color get avatarColor {
    var h = 0;
    for (final c in id.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return HSLColor.fromAHSL(1, (h % 360).toDouble(), 0.55, 0.48).toColor();
  }

  String get initials {
    final parts = displayName.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return (parts[0][0] + parts[1][0]).toUpperCase();
    }
    return name.characters.take(2).toString().toUpperCase();
  }

  IconData get platformIcon =>
      platform == DevicePlatform.windows ? Icons.computer : Icons.phone_android;
}

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.fromMe,
    required this.kind,
    required this.time,
    this.text = '',
    this.fileName = '',
    this.fileSize = 0,
    this.state = SendState.delivered,
    this.progress = 0,
    this.failed = false,
    this.fileId = '',
    this.filePath = '',
    this.cancelled = false,
    this.queued = false,
    this.paused = false,
  });

  final String id;
  final bool fromMe;
  final MessageKind kind;
  final DateTime time;
  final String text;
  final String fileName;
  final int fileSize;

  /// 关联的传输 id（文件消息用于更新进度；文本消息为空）。
  final String fileId;

  /// 本地文件路径：出站=源文件（重发用），入站=收件目录落盘路径（图片显示用）。
  String filePath;
  SendState state;
  double progress;
  bool failed;

  /// 用户主动取消过（取消的文件不参与自动补发，也不会显示失败样式）。
  bool cancelled;

  /// 离线排队：对方不在线时先存着，等连上后自动补发（只补一次）。
  bool queued;

  /// 发送中被暂停（纯发送侧：停产出 chunk，连接不断）。
  bool paused;
}

class Conversation {
  Conversation({
    required this.device,
    required this.messages,
    this.unread = 0,
    this.draft = '',
    this.lastTsMs = 0,
  });

  final LanDevice device;
  final List<ChatMessage> messages;
  int unread;
  String draft;

  /// 最后一条消息时间（毫秒；来自消息存储摘要，列表排序用）。
  int lastTsMs;

  ChatMessage? get last => messages.isEmpty ? null : messages.last;
}

/// Deterministic gradient used to fake image thumbnails in the demo build.
Gradient thumbnailGradient(String seed) {
  var h = 0;
  for (final c in seed.codeUnits) {
    h = (h * 33 + c) & 0x7fffffff;
  }
  final a = HSLColor.fromAHSL(1, (h % 360).toDouble(), 0.6, 0.55).toColor();
  final b =
      HSLColor.fromAHSL(1, ((h ~/ 7) % 360).toDouble(), 0.65, 0.42).toColor();
  return LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [a, b],
  );
}

String formatBytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  if (n < 1024 * 1024 * 1024) {
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(n / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

String relativeTime(DateTime t) {
  final now = DateTime.now();
  final d = now.difference(t);
  if (d.inMinutes < 1) return '刚刚';
  if (d.inMinutes < 60) return '${d.inMinutes}分钟前';
  final today = DateTime(now.year, now.month, now.day);
  if (t.isAfter(today)) return '${d.inHours}小时前';
  if (t.isAfter(today.subtract(const Duration(days: 1)))) return '昨天';
  return '${t.month}-${t.day.toString().padLeft(2, '0')}';
}

String clockTime(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String fileExt(String name) {
  final i = name.lastIndexOf('.');
  return i < 0 ? '' : name.substring(i + 1).toLowerCase();
}

Color extColor(String ext) {
  switch (ext) {
    case 'pdf':
      return const Color(0xFFEF4444);
    case 'doc':
    case 'docx':
      return const Color(0xFF3B82F6);
    case 'zip':
    case 'rar':
    case '7z':
      return const Color(0xFFF59E0B);
    case 'mp4':
    case 'mkv':
    case 'mov':
      return const Color(0xFF8B5CF6);
    case 'png':
    case 'jpg':
    case 'jpeg':
    case 'gif':
      return const Color(0xFF10B981);
    case 'apk':
      return const Color(0xFF14B8A6);
    default:
      return const Color(0xFF64748B);
  }
}

IconData extIcon(String ext) {
  switch (ext) {
    case 'pdf':
      return Icons.picture_as_pdf;
    case 'doc':
    case 'docx':
      return Icons.article;
    case 'zip':
    case 'rar':
    case '7z':
      return Icons.folder_zip;
    case 'mp4':
    case 'mkv':
    case 'mov':
      return Icons.movie;
    case 'png':
    case 'jpg':
    case 'jpeg':
    case 'gif':
      return Icons.image;
    default:
      return Icons.insert_drive_file;
  }
}
