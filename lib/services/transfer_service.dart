import 'dart:async';

import 'package:rust_flutter_ui/services/chat_service.dart';
import 'package:rust_flutter_ui/src/rust/api/transfer.dart' as rust;

export 'package:rust_flutter_ui/src/rust/api/transfer.dart'
    show TransferDir, TransferStatusDto;

/// 文件传输（T4.x）的 Dart 封装。
///
/// 传输是**后台驱动**（Rust hub 自动收发），Dart 只做发起 + 轮询进度；
/// 进度快照在 Rust 侧已按 ≥100ms 节流（风险5），UI 侧 ≤2Hz 拉取即可。
class TransferService {
  TransferService._();

  static final TransferService instance = TransferService._();

  /// 拉起传输中枢（chat_subscribe 内部也会调，幂等）。
  Future<void> init() async {
    await rust.ensureHub();
    // 预热收件目录缓存：transfer_download_dir 在 frb 2.8.0 下已是 async，
    // 不能在 UI 同步路径里 await，故桥就绪后缓存一次（进程内目录稳定）。
    await warmDownloadDir();
  }

  /// 发起发送（会先算哈希，大文件可能耗时，故为 async）。
  Future<rust.TransferStatusDto> send({
    required String peerId,
    required String path,
  }) =>
      rust.transferSend(peerId: peerId, path: path);

  /// 全量进度快照：进行中 + 最近 32 条完成/失败。
  ///
  /// **async**：Rust 侧不再标 frb(sync)，避免 UI isolate 卡在锁上
  ///（用户反馈「PC 端整个软件不响应」的根因）。
  Future<List<rust.TransferStatusDto>> status() => rust.transferStatus();

  /// 取消发送；返回是否真的取消了。
  ///
  /// 取消是双端语义：Rust 侧会同时给对端发 FILE_ABORT，让对方丢弃 .part。
  Future<bool> cancel(String fileId) => rust.transferCancel(fileId: fileId);

  /// 暂停发送（纯发送侧：停产出 chunk；心跳独立，连接不断）。
  Future<bool> pause(String fileId) => rust.transferPause(fileId: fileId);

  /// 继续发送。
  Future<bool> resume(String fileId) => rust.transferResume(fileId: fileId);

  /// 对端重连后：重启该 peer 所有未完成的发送（重发 FILE_META + 从已确认点续传）。
  ///
  /// 断线时任务还在 hub 里，但没有 ACK 就永远停住；必须显式重启。
  Future<int> reconnect(String peerId) => rust.transferReconnect(peerId: peerId);

  /// 收件目录（同步读缓存）。
  ///
  /// Rust 侧 `transfer_download_dir` 在 frb 2.8.0 下已被忽略 #[frb(sync)]，
  /// 变成 async，不能在 build()/microtask 这类同步路径里 await。改为：桥就绪后
  /// 调一次 [warmDownloadDir] 把结果缓存，本方法同步返回。
  /// 测试钩子 [downloadDirOverride]：flutter test 环境没起 Rust 桥时注入，
  /// 用于验证「文件」TAB 的回落逻辑（见 test/mobile_receive_reveal_test.dart）。
  static String Function()? downloadDirOverride;
  String? _downloadDirCache;

  /// 缓存里的值是否**可信**。
  ///
  /// 判据是「这次探测发生时消息仓库已经打开」：messages_open 才会在 Rust 侧
  /// 注册 DOWNLOAD_ROOT，在那之前 transfer_download_dir() 返回的是系统临时
  /// 目录兜底值。这个错值一旦被当成最终结果缓存，收件目录查找 / 文件 TAB /
  /// 「打开文件」全都指向错地方，现场表现就是「收到的文件找不到」
  /// 和「文件还没能接收完成」。
  bool _downloadDirResolved = false;
  int _lastDownloadDirProbeMs = 0;

  /// 不可信缓存的补探间隔（同步 getter 里 fire-and-forget，不阻塞 UI）。
  static const int _downloadDirRetryGapMs = 1000;

  /// 收件目录（同步读缓存）。
  ///
  /// Rust 侧 transfer_download_dir 在 frb 2.8.0 下已是 async，不能在
  /// build()/microtask 这类同步路径里 await，所以返回缓存值；缓存还没落到
  /// 可信值时按 [_downloadDirRetryGapMs] 节流补探（探测在后台跑）。
  String downloadDir() {
    final override = downloadDirOverride;
    if (override != null) return override();
    final cached = _downloadDirCache ?? '';
    // 消息仓库打开后 Rust 侧才有真正的收件目录；之前的空/临时目录一律重探。
    if (!_downloadDirResolved && ChatService.instance.storeOpened) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastDownloadDirProbeMs >= _downloadDirRetryGapMs) {
        _lastDownloadDirProbeMs = now;
        unawaited(warmDownloadDir());
      }
    }
    return cached;
  }

  /// 预热收件目录缓存。
  ///
  /// 幂等且可重复调用：只有「消息仓库已打开」时探到的值才置为可信；
  /// 仓库打开前探到的空/temp 兜底值不置锁存，等仓库打开后再探一次就会落到
  /// 真正的 `<数据目录>/chat/downloads`。
  Future<void> warmDownloadDir() async {
    final storeReady = ChatService.instance.storeOpened;
    try {
      final dir = await rust.transferDownloadDir();
      _downloadDirCache = dir;
      _downloadDirResolved = storeReady && dir.isNotEmpty;
    } catch (_) {
      _downloadDirCache = null;
      _downloadDirResolved = false;
    }
  }

  Future<bool> hubRunning() => rust.transferHubRunning();
}
