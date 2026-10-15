import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

/// Windows 单实例「尽力交接」：应用已在运行时，右键「通过雨传发送」
/// 拉起的第二个进程把文件清单递给运行中的实例后自己退出；连不上
/// （没在运行/握手失败）就照常启动 —— **不做强制单实例**，多开仍允许。
///
/// 机制（纯 Dart，不动 C++ runner）：
/// - 首个/任一实例启动时在 127.0.0.1 随机端口起 TCP 控制服务，
///   把 {pid, port} 写到 %LOCALAPPDATA%\\yuchuan\\instance.json；
/// - 带文件参数的新进程先读该文件并尝试连接：连上 → 发一行 JSON 清单
///   → 等回 `OK` → AppActivate 唤起目标窗口 → exit(0)；
/// - 任何一步失败 → 返回 false，新进程继续正常启动（自己成为发送方）。
///
/// 过期文件（实例崩溃没清理）会因连接失败被自然忽略；新实例启动后会
/// 覆盖写入自己的 {pid, port}。
class SingleInstance {
  SingleInstance._();

  static File defaultInfoFile() {
    final base = Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['TEMP'] ??
        '.';
    return File('$base\\yuchuan\\instance.json');
  }

  /// 排查用落地日志：追加到 %TEMP%\\yuchuan_handoff_diag.txt。
  /// 交接失败目前全靠静默兜底，线上无从判断卡在哪一步——出问题时看这里。
  static void log(String msg) {
    try {
      final dir = Platform.environment['TEMP'] ?? '.';
      File('$dir\\yuchuan_handoff_diag.txt').writeAsStringSync(
          '${DateTime.now().toIso8601String()} pid=${_currentPid()} $msg\n',
          mode: FileMode.append);
    } catch (_) {}
  }

  /// 当前进程 pid（Dart 没有 Process.pid，Windows 下走 kernel32；
  /// 拿不到返回 0，客户端会跳过唤起窗口这一步）。
  static int _currentPid() {
    try {
      final k32 = DynamicLibrary.open('kernel32.dll');
      final fn = k32
          .lookupFunction<Uint32 Function(), int Function()>(
              'GetCurrentProcessId');
      return fn();
    } catch (_) {
      return 0;
    }
  }

  /// 起控制服务（任一实例启动时调用）。[onShare] 收到交接来的文件清单。
  /// [infoFile] 默认写 %LOCALAPPDATA%\\yuchuan\\instance.json（测试可注入）。
  /// 返回监听中的 ServerSocket（失败返回 null，不影响主流程）。
  static Future<ServerSocket?> startControlServer({
    required void Function(List<String> files) onShare,
    bool writeInfoFile = true,
    File? infoFile,
  }) async {
    try {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      if (writeInfoFile) {
        final f = infoFile ?? defaultInfoFile();
        await f.parent.create(recursive: true);
        await f.writeAsString(
            jsonEncode({'pid': _currentPid(), 'port': server.port}));
      }
      server.listen((socket) {
        socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
          try {
            final msg = jsonDecode(line) as Map<String, dynamic>;
            if (msg['type'] == 'share') {
              final files = (msg['files'] as List<dynamic>? ?? [])
                  .whereType<String>()
                  .toList();
              if (files.isNotEmpty) {
                log('server received share files=$files');
                onShare(files);
              }
            }
            socket.add(utf8.encode('OK\n'));
            socket.flush().whenComplete(() => socket.destroy());
          } catch (e) {
            log('server onMessage error: $e');
            try {
              socket.add(utf8.encode('ERR\n'));
              socket.flush().whenComplete(() => socket.destroy());
            } catch (_) {}
          }
        }, onError: (e) => log('server stream error: $e'),
            onDone: () => socket.destroy());
      });
      log('server listening port=${server.port}');
      return server;
    } catch (e) {
      log('server start FAILED: $e'); // 控制服务起不来不影响主流程
      return null;
    }
  }

  /// 带文件参数的新进程调用：尝试交给运行中的实例。
  /// 返回 true = 交接成功（调用方应 exit(0)）。
  static Future<bool> handoffToRunningInstance(
    List<String> files, {
    File? infoFile,
  }) async {
    if (files.isEmpty) {
      log('handoff: no files');
      return false;
    }
    final f = infoFile ?? defaultInfoFile();
    Map<String, dynamic> info;
    try {
      info = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (e) {
      log('handoff: info read fail path=${f.path} ($e)');
      return false; // 没有实例在跑（或文件已损坏）
    }
    final port = info['port'];
    if (port is! int || port <= 0) {
      log('handoff: bad port info=$info');
      return false;
    }
    Socket? sock;
    try {
      log('handoff: connecting port=$port files=${files.length}');
      sock = await Socket.connect(InternetAddress.loopbackIPv4, port,
          timeout: const Duration(milliseconds: 500));
      sock.add(utf8.encode(
          '${jsonEncode({'type': 'share', 'files': files})}\n'));
      await sock.flush();
      // 等首实例回 OK；拿不到/不是 OK 都当成交接失败，走正常启动
      final ack = await sock
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 2));
      log('handoff: ack=$ack');
      if (ack != 'OK') return false;
      await _activateProcess(info['pid']);
      log('handoff: OK -> exit');
      return true;
    } on TimeoutException catch (e) {
      log('handoff: ack timeout ($e)');
      return false;
    } catch (e) {
      log('handoff: error ($e)');
      return false;
    } finally {
      sock?.destroy();
    }
  }

  /// 唤起目标进程的窗口到前台（本进程刚被用户拉起，有抢焦点的资格）。
  /// 用 WScript.Shell.AppActivate(pid)，零依赖；失败不影响交接。
  static Future<void> _activateProcess(Object? pid) async {
    if (pid is! int || pid <= 0) return;
    final pidStr = pid.toString();
    try {
      await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '(New-Object -ComObject WScript.Shell).AppActivate($pidStr)',
      ]);
    } catch (_) {}
  }
}
