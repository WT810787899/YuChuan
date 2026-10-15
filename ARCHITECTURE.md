# 雨传 YuChuan · 项目架构说明

本文说明代码怎么组织、各部分负责什么、关键流程怎么走。**面向要改代码的人**；只想用的话看 [README](README.md)。

---

## 1. 总体形态

一句话：**Flutter 画界面，Rust 干所有网络与存储的活**，两边通过 `flutter_rust_bridge`（frb）v2 双向调用。

```
┌──────────────────────────── Flutter（Dart）────────────────────────────┐
│  lib/ui/**                     纯展示 + 交互（页面、气泡、菜单、OSD）      │
│  lib/app_state.dart            单一状态源：会话/消息/在线/传输/设置        │
│  lib/appearance.dart           外观（主题、壁纸、透明度）                 │
│  lib/services/**               对 Rust 的薄封装 + 平台差异隔离            │
└───────────────────────────────┬────────────────────────────────────────┘
                                │  frb（生成代码，勿手改）
┌───────────────────────────────▼────────────────────────────────────────┐
│  Rust                                                                    │
│  src/api/**        导出给 Dart 的接口（薄封装，参数校验 + DTO 转换）        │
│  src/backend/**    真正的实现：发现 / 会话 / 协议 / 配对 / 存储 / 传输      │
└─────────────────────────────────────────────────────────────────────────┘
```

**为什么这么分**：网络收发、断点续传、消息落盘这些必须跨平台一致且能扛住 Dart 侧的重启/冻结，放在 Rust 里只写一遍；Dart 只关心"现在要显示什么"。

---

## 2. 目录结构

```
YuChuan/
├─ icon.png                     应用图标源图（1024×1024），换图标只改这里
├─ scripts/gen_platform_icons.py 由 icon.png 派生各平台图标
│
├─ lib/                         ── Flutter 侧 ──
│  ├─ main.dart                 入口：初始化、生命周期、OSD 桥接、单实例
│  ├─ app_state.dart            核心状态机（最大的文件，见 §4）
│  ├─ models.dart               纯数据模型（LanDevice / Conversation / ChatMessage）
│  ├─ appearance.dart           外观状态（主题色、壁纸、不透明度、行数）
│  ├─ ui/                       界面层
│  │  ├─ chat_list.dart         消息列表页
│  │  ├─ chat_page.dart         会话页（气泡、输入栏、传输卡片、右键菜单）
│  │  ├─ files_page.dart        文件 TAB（网格/列表、框选、排序、筛选）
│  │  ├─ discovery.dart         设备发现与配对页
│  │  ├─ settings_page.dart     设置（主题与壁纸/界面/通知/发现与连接/传输/关于）
│  │  ├─ menus.dart             统一菜单组件（桌面弹出菜单 / 安卓底部弹层）
│  │  ├─ osd_toast.dart         OSD 提示胶囊
│  │  ├─ pairing_dialog.dart    配对确认窗
│  │  ├─ open_with_sheet.dart   「打开方式」选择（始终 / 仅一次）
│  │  ├─ title_bar.dart         桌面端自绘标题栏
│  │  ├─ linkify.dart           文本里的链接识别
│  │  ├─ color_picker.dart      主题色选色
│  │  ├─ device_icons.dart      设备类型图标（PC / 手机等）
│  │  └─ onboarding_page.dart   首次使用引导
│  ├─ services/                 对 Rust 的封装，隔离平台差异
│  │  ├─ chat_service.dart      聊天会话与消息
│  │  ├─ discovery_service.dart 设备发现
│  │  ├─ pairing_service.dart   配对
│  │  ├─ transfer_service.dart  文件传输
│  │  ├─ platform_channel.dart  平台能力（打开文件/打开方式/安装包/保活/资源管理器）
│  │  └─ single_instance.dart   PC 单实例（右键发送拉起第二个进程时移交）
│  └─ src/rust/                 ── frb 生成的桥接代码，**不要手改** ──
│
├─ rust_builder/                ── Rust 侧 ──
│  └─ src/
│     ├─ api/                   导出给 Dart 的接口
│     │  ├─ chat.rs             会话/消息/发件箱/会话快照
│     │  ├─ discovery.rs        发现与设备列表
│     │  ├─ pairing.rs          配对
│     │  ├─ transfer.rs         传输控制与进度
│     │  └─ dashboard.rs        早期 demo（历史遗留）
│     ├─ backend/               真正的实现
│     │  ├─ discovery.rs        组播发现（UDP 广播 / 单播应答）
│     │  ├─ session.rs          TCP 会话：握手、心跳、退避重连、收帧循环
│     │  ├─ protocol.rs         帧格式（长度前缀 + 类型 + 负载）
│     │  ├─ pairing.rs         配对状态机
│     │  ├─ storage.rs          聊天仓库 / 发件箱 / 联系人落盘
│     │  └─ transfer.rs         分块传输、流控、断点续传
│     └─ frb_generated.rs       ── frb 生成，**不要手改** ──
│
├─ android/                     安卓壳
│  └─ app/src/main/kotlin/com/yuchuan/app/
│     ├─ MainActivity.kt        平台通道实现 + 分享入口（其他应用 → 雨传）
│     └─ TransferService.kt     前台服务（后台保活）
│
├─ windows/                     Windows 壳
│  ├─ runner/                   标准 Flutter Windows runner
│  └─ flutter/generated_plugin_registrant.cc   插件注册（自动生成）
│
├─ test/                        Dart 单元/组件测试
├─ integration_test/            集成测试
├─ scripts/                     构建与辅助脚本
├─ Screenshots/                 README 用截图
└─ flutter_rust_bridge.yaml     frb 代码生成配置
```

**生成代码的边界**（改代码时最容易踩）：

| 路径 | 来源 | 能不能手改 |
|---|---|---|
| `lib/src/rust/**` | `scripts/codegen.ps1` | ❌ 会被覆盖 |
| `rust_builder/src/frb_generated.rs` | 同上 | ❌ |
| `windows/flutter/generated_plugin_registrant.*` | 构建时生成 | ❌ |
| `lib/ui/**`、`lib/app_state.dart` | 手写 | ✅ |
| `rust_builder/src/api/**`、`src/backend/**` | 手写 | ✅ |

改了 `rust_builder/src/api/**` 里**导出的签名**，必须重跑 `scripts/codegen.ps1`；
只改实现（函数体）不需要。

---

## 3. 分层职责

| 层 | 负责 | 不负责 |
|---|---|---|
| `lib/ui/**` | 画界面、收集输入、调 `AppState` | 不直接调 Rust |
| `lib/app_state.dart` | 会话与消息的**单一真相**、在线判定、传输进度、设置读写 | 不做 socket / 不解析协议 |
| `lib/services/**` | 把 Rust 接口包成好用的 Future/Stream；隔离「桌面 vs 安卓」 | 不持有 UI 状态 |
| `rust_builder/src/api/**` | 参数校验、DTO 转换、锁的获取与释放 | 不放业务规则 |
| `rust_builder/src/backend/**` | 网络、协议、存储、传输算法 | 不知道 UI 存在 |

---

## 4. `app_state.dart` 里值得先看懂的几个点

这个文件很大，但只有几条主线：

- **`_onChatEvent`**：Rust 推来的事件总入口（connected / disconnected / message / sent / pairRequest / pairResponse）。
- **在线判定 `_isOnline`**：**唯一权威来源是 Rust 的连接事实**（`connected`/`disconnected` 事件）。
  特意**不**按「多久没收到数据」递减 —— 心跳由 Rust 内部处理、不会变成 Dart 事件，
  按时间判会把健康但空闲的连接误判成离线，且再也回不来。
  发送前另有一次单向核对 `_effectivelyOnline`（Rust 说没连上才降级为排队）。
- **发件箱 `flushOutbox`**：周期性（400ms）扫描 `outbox.jsonl` 补发离线消息。
  **只有 `sendFilePath` 返回 `true`（真的交给了传输引擎）才 ack**，否则保持 pending。
- **气泡复用**：同一「文件名+大小」的未完成气泡会被复用而不是新建，避免"发一次冒一个气泡"。
- **保活 `_updateKeepAlive`**：有传输 / 有待发 / 有在线会话时开安卓前台服务。

---

## 5. 关键流程

### 发现与配对

```
两端启动 → Rust 组播广播 HELLO ─→ 对端收单播应答 → Dart 设备列表
配对：Dart 调 chat 的 PAIR_REQ（带 PIN）→ Rust 状态机 → 对端弹窗确认
    → 写 contacts.json → 自动关闭发现
```

### 聊天消息（在线）

```
Dart sendMessage → 上屏乐观气泡 → Rust chat_send_text
  ├─ 优先走主动拨号的会话；不可用则回落到监听端的入站连接
  └─ 落库（messages/<peerId>.jsonl）→ 返回真实 id → Dart 用真实消息替换乐观气泡
```

### 聊天消息（对方离线）

```
Dart：气泡标「离线待发」+ 写入 Rust outbox.jsonl + 主动拨号
对端上线 → Dart flushOutbox 扫到 pending
  → 真的发出去才 outboxAck，并清掉气泡的排队标记
```

### 文件传输

```
Dart sendFilePath → Rust transfer_send 注册任务（算 blake3 内容哈希）
  → 分块发送（窗口流控）+ 接收端逐块 ACK → 接收端落盘到 downloads/
  → 两侧按 file_id 记录结果到 transfer_outcomes.json
断线重连 → 重发 META，双方交换续传点，从断点继续（指纹对不上则重传）
```

### 「打开方式」（安卓 vs 桌面）

```
安卓：列出能打开该类型的所有应用 → 自建选择窗（始终 / 仅一次）→ 记忆选择
桌面：rundll32 shell32.dll,OpenAs_RunDLLW <path>（必须是 Unicode 入口，
       ANSI 的 OpenAs_RunDLL 实测不弹窗）
```

---

## 6. 本地数据文件

都在平台的应用数据目录下：

| 文件 | 写入方 | 内容 |
|---|---|---|
| `messages/<peerId>.jsonl` | Rust | 每个会话的消息日志（按行追加） |
| `outbox.jsonl` | Rust | 待发消息/文件（离线发送的真相源，跨重启存活） |
| `contacts.json` | Rust | 已配对联系人 |
| `unread.json` | Rust | 未读计数 |
| `downloads/` | Rust | 接收到的文件（可在设置里改接收目录） |
| `prefs.json` | Dart | 非外观类设置（自动接收、限速、虚拟网卡过滤等） |
| `transfer_outcomes.json` | Dart | 传输结果台账（重启后还原真实进度/路径） |
| `contact_aliases.json` | Dart | 联系人备注名 |
| `removed_peers.json` | Dart | 已删除联系人的「墓碑」，防止删完又冒出来 |

---

## 7. 构建与测试

```powershell
.\scripts\build_windows.ps1    # 出 Windows 版
.\scripts\build_apk.ps1        # 出 Android APK
.\scripts\test_rust.ps1        # Rust 单元测试
.\scripts\codegen.ps1          # 改了 api/ 导出签名后重新生成桥接
.\scripts\explorer_context_menu.ps1   # 安装「通过雨传发送」资源管理器右键菜单
```

> 改了 Rust 之后，**先 `cargo build --release` 再跑 Dart 测试**：否则加载的是旧
> `rust_flutter_ui_native.dll`，会报 `Content hash on Dart side ... out-of-sync code`。
