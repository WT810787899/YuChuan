import 'package:rust_flutter_ui/src/rust/api/chat.dart' as rust;

export 'package:rust_flutter_ui/src/rust/api/chat.dart'
    show ChatEventDto, ChatEventKindDto, ChatStateDto, ChatSessionDto, MessageDto;

/// 聊天会话与消息存储的 Dart 封装（T3.1 / T3.3）。
///
/// - 回调式状态：Rust 推事件（Connected / Disconnected / Message / Sent），UI 不轮询；
/// - 收到即入库、发出也入库，UI 只需要「读历史 + 听事件」；
/// - 消息按 (sender_id, seq) 去重（Rust 侧 SeqTracker），乱序/重复不会重复上屏。
class ChatService {
  ChatService._();

  static final ChatService instance = ChatService._();

  /// i64 最大值：第一页分页游标。
  static const int pageStart = 9223372036854775807;

  bool _storeOpened = false;
  String? _storeDir;

  bool get storeOpened => _storeOpened;
  String? get storeDir => _storeDir;

  /// 订阅会话事件流。**必须在 [listen] / [dial] 之前调用**。
  Stream<rust.ChatEventDto> events() => rust.chatSubscribe();

  /// 打开消息仓库（%APPDATA%/YuChuan 或 Android 私有目录）。幂等。
  Future<rust.MessageStoreStatusDto> openStore(String? dataDir) async {
    if (dataDir == null || dataDir.isEmpty) {
      return const rust.MessageStoreStatusDto(
        dir: '',
        total: 0,
        totalUnread: 0,
        skippedLines: 0,
      );
    }
    final status = await rust.messagesOpen(dataDir: dataDir);
    _storeOpened = true;
    _storeDir = status.dir;
    return status;
  }

  /// 开始监听本机聊天端口，返回实际端口（chatPort=0 时由系统分配）。
  Future<int> listen({
    required String deviceId,
    required String name,
    required String platform,
    int chatPort = 45998,
  }) =>
      rust.chatListen(
        info: rust.SelfInfo(
          deviceId: deviceId,
          name: name,
          platform: platform,
        ),
        chatPort: chatPort,
      );

  /// 主动连接对端（带指数退避自动重连）。target 形如 "192.168.1.23:45998"。
  Future<void> dial({
    required String deviceId,
    required String name,
    required String platform,
    required String peerId,
    required String target,
  }) =>
      rust.chatDial(
        info: rust.SelfInfo(
          deviceId: deviceId,
          name: name,
          platform: platform,
        ),
        peerId: peerId,
        target: target,
      );

  /// 发文本（自动判断走主动连接还是监听端连接），返回**落库后的消息**
  /// （UI 用它替换乐观条目，id 与存储一致，重载历史不会重复）。
  Future<rust.MessageDto> sendText({
    required String peerId,
    required String senderId,
    required String text,
  }) =>
      rust.chatSendText(peerId: peerId, senderId: senderId, text: text);

  /// 清空某会话的本地记录（删文件 + 内存 + 读游标）。
  Future<bool> clear(String peerId) => rust.messagesClear(peerId: peerId);

  /// 删掉单条消息（内存 + 磁盘 JSONL 重写）。
  ///
  /// 只从 Dart 内存摘掉不够 —— 重启一读文件就又回来了。
  Future<bool> remove(String peerId, String msgId) =>
      rust.messagesRemove(peerId: peerId, msgId: msgId);

  /// 追加一条消息（文件消息 kind=3、图片 kind=2；msgId 用传输 id 派生保证唯一）。
  Future<rust.MessageDto> appendMessage({
    required String peerId,
    required bool fromMe,
    required String text,
    required int tsMs,
    int seq = 0,
    int kind = 1,
    String fileName = '',
    int fileSize = 0,
    String? msgId,
  }) =>
      rust.messagesAppend(
        peerId: peerId,
        fromMe: fromMe,
        text: text,
        tsMs: tsMs,
        seq: seq,
        kind: kind,
        fileName: fileName,
        fileSize: fileSize,
        msgId: msgId,
      );

  /// 离线发件箱：排队待发的条目（Rust 侧 outbox.jsonl，进程被杀也不丢）。
  List<rust.OutboxItemDto> outboxPending([String? peerId]) =>
      rust.chatOutboxPending(peerId: peerId);

  /// 把文本排进离线发件箱，返回条目 id。
  Future<String> outboxEnqueueText(String peerId, String text) =>
      rust.chatOutboxEnqueueText(peerId: peerId, text: text);

  /// 把文件排进离线发件箱（id 由 file_id 派生，保证同一文件不重复入队）。
  Future<String> outboxEnqueueFile({
    required String peerId,
    required String fileId,
    required String path,
    required String fileName,
    required int fileSize,
    required int kind,
  }) =>
      rust.chatOutboxEnqueueFile(
        peerId: peerId,
        fileId: fileId,
        path: path,
        fileName: fileName,
        fileSize: fileSize,
        kind: kind,
      );

  /// 文件内容 id（blake3 hex）。**发件箱去重的稳定键**，必须在入队前算好，
  /// 且同一个文件的所有入队路径都用它（B1-5：以前两条路径各用一套 id，
  /// 同一文件在发件箱里存两条 → 补发两次 → N 个气泡 + 对端收不到）。
  Future<String> fileContentId(String path) =>
      rust.chatFileContentId(path: path);

  /// 标记发件箱条目已投递（成功后调用）。
  Future<void> outboxAck(String id) => rust.chatOutboxAck(id: id);

  /// 撤销发件箱条目（用户取消，或源文件已不存在时）。
  Future<bool> outboxCancel(String id) => rust.chatOutboxCancel(id: id);

  /// 发 PAIR_REQ（T2.1 发起方：状态机产出 PIN 后调用）。
  Future<void> sendPairRequest({
    required String peerId,
    required String senderId,
    required String pin,
  }) =>
      rust.chatSendPairRequest(peerId: peerId, senderId: senderId, pin: pin);

  /// 回 PAIR_RESP（T2.1 应答方：用户确认/拒绝后调用）。
  Future<void> sendPairResponse({
    required String peerId,
    required bool accepted,
    String? reason,
  }) =>
      rust.chatSendPairResponse(
        peerId: peerId,
        accepted: accepted,
        reason: reason,
      );

  List<rust.ChatSessionDto> sessions() => rust.chatSessions();

  bool get listening => rust.chatIsListening();

  Future<bool> hangup(String peerId) => rust.chatHangup(peerId: peerId);

  Future<void> stopListening() => rust.chatStopListening();

  /// 历史一页（新的在前）。beforeTsMs 传 [pageStart] 表示第一页。
  List<rust.MessageDto> page(
    String peerId, {
    int limit = 50,
    int beforeTsMs = pageStart,
  }) =>
      rust.messagesPage(peerId: peerId, limit: limit, beforeTsMs: beforeTsMs);

  int unread(String peerId) => rust.messagesUnread(peerId: peerId);

  Future<int> markRead(String peerId, int uptoMs) =>
      rust.messagesMarkRead(peerId: peerId, uptoTsMs: uptoMs);

  List<rust.ConversationDto> conversations() => rust.messagesConversations();

  rust.MessageStoreStatusDto status() => rust.messagesStatus();
}
