# 权限与平台清单（T0.4）

> 对应 [PLAN.md](PLAN.md) 风险 2/3/4/6/7 与 TASKS T0.4。Android manifest 在
> `flutter create --platforms=android` 之后落进 `android/app/src/main/AndroidManifest.xml`。

## 1. Android（targetSdk 36）

### 1.1 Manifest 声明（v1 必需）

| 权限 | 用途 | 任务/风险 |
|------|------|----------|
| `INTERNET` | TCP 收发 / UDP 发现（Flutter 模板默认已有） | 全部 |
| `ACCESS_NETWORK_STATE` | 判断 Wi-Fi 是否连接、切换网络时重扫 | T1.1 |
| `CHANGE_WIFI_MULTICAST_STATE` | 持有 `MulticastLock`，否则省电模式丢组播包 | T1.2 / 风险3 |
| `ACCESS_WIFI_STATE` | 读取本机 Wi-Fi 信息（组播锁获取前置） | T1.2 |
| `POST_NOTIFICATIONS`（Android 13+） | 传输进度通知（**v1.1 前台服务**阶段使用） | T6.1 / 风险6 |

**v1 明确不申请**（风险7 缓解）：
- ~~`READ_EXTERNAL_STORAGE` / `MANAGE_EXTERNAL_STORAGE`~~ —— 收件目录用应用私有
  `getExternalFilesDir(Files)`（零权限）；"发送文件"走 `file_picker`/SAF 授权读取。
- ~~后台保活类权限~~ —— v1 声明"亮屏传输"。

### 1.2 运行时行为清单
- [ ] 首次进入发现页：先展示应用内说明卡（为何需要本地网络），再触发系统权限弹窗
- [ ] 开始扫描前获取 `WifiManager.MulticastLock`（`setReferenceCounted(true)`），停止发现时释放
- [ ] Android 13+ 通知权限：在首次真正开始传输前请求，拒绝后不影响文本聊天
- [ ] 切后台 >30s 停止发现（省电），回前台自动恢复（`AppLifecycleListener`）

## 2. Windows 10/11

### 2.1 防火墙（风险4）
首次监听时 Windows 会弹出防火墙询问 —— 静默拒绝会导致"对方搜不到我"。

- 需要放行：**入站 TCP 9527**（会话）、**入站 UDP 9527 + 组播 239.255.42.99:9527**（发现）
- 安装器（Inno Setup，T6.2）中创建规则示例：
  ```powershell
  netsh advfirewall firewall add rule name="LanChat" dir=in action=allow protocol=TCP localport=9527
  netsh advfirewall firewall add rule name="LanChat-UDP" dir=in action=allow protocol=UDP localport=9527
  ```
- 应用内引导文案（连接失败时展示）：
  > 无法被对方发现？请检查：① Windows 防火墙是否允许 `rust_flutter_ui.exe` 通过专用网络；
  > ② 两台设备是否在同一普通 Wi-Fi（访客网络可能开启 AP 隔离）；
  > ③ 可尝试「手动输入 IP:端口」直连。

### 2.2 其他
- 收件目录默认 `文档\LanChat`（首次运行创建，无需管理员权限）
- 单实例运行：再次启动时激活已有窗口（避免双开监听冲突）

## 3. 明确排除（v1）
- iOS / macOS / Linux（见 PLAN §1.3）
- 端到端加密（v2，PLAN 风险14）
