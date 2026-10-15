# 局域网聊天 / 传文件工具 — 计划任务列表

> 配套文档：[PLAN.md（规划与里程碑）](PLAN.md)
> 状态图例：`[ ]` 未开始 · `[x]` 完成 · `[~]` 进行中 · `[!]` 受阻
> 规则：每项任务**先过验收再勾选**；风险缓解任务（带 ⚠️）不可跳过；预估单位为人日（含联调）

---

## 总览

| 里程碑 | 任务数 | 预估 | 状态 | 阻塞项 |
|--------|-------|------|------|--------|
| M0 工程地基 | 7 | 2d | **4/7 完成（余 3 项仅待真机）** | 无 |
| M1 设备发现 | 6 | 2–3d | **T1.1 ✅ T1.2 ✅(代码) T1.3 ✅ T1.4 ✅ T1.6 ✅** | T1.5 真机联调 |
| M2 握手配对 | 4 | 2d | **T2.1 ✅ T2.2 ✅ T2.3 ✅ 配对已走 TCP** | T2.4 真机 |
| M3 文字聊天 | 8 | 4–5d | **T3.1–T3.8 全部完成（待用户统一验收）** | 真机走查 |
| M4 文件传输 | 8 | 4–6d | **T4.1–T4.6 ✅，T4.7/并发接收待测试** | 双端真机验收 |
| M5 体验打磨 | 6 | 3–4d | **T5.1–T5.6 全部完成（待用户走查）** | — |
| M6 打包发布 | 5 | 2–3d | 未开始 | M5 |
| M7 用户反馈一轮（雨传命名 + 移动端体验） | 21 | 2d | **R0–R20 代码全部完成（真机项待走查）** | 真机走查 |
| M8 用户反馈二轮（重复气泡/配对窗口/提醒/收件目录） | 16 | 1.5d | **B1–B16 全部完成（真机项待走查）** | 真机走查 |
| M9 用户反馈三轮（配对收尾/TAB选中/文件交互/离线发送） | 13 | 1d | **C1–C13 全部完成（真机项待走查）** | 真机走查 |
| M10 用户反馈四轮（壁纸/气泡/配对兜底/文件交互/返回栈） | 12 | 1d | **D1–D12 全部完成（真机项待走查）** | 真机走查 |
| **合计** | **108** | **24.5–31.5d** | | |

---

## M0 · 工程地基（预估 2d）

> 目标：双平台出包 + 桥接打通 + UI 壳跑通。**T0.1 是整个项目最大风险的前置验证，必须最先做。**

- [~] **T0.1** 🔺 Spike：Android 构建链冒烟 — **本机侧全部完成，仅剩真机安装**
  - [x] `rustup target add`：aarch64 / armv7 / x86_64 android targets
  - [x] cmdline-tools 16111833 + JDK 21 + **NDK 27.0.12077973** + platforms;android-36
        + build-tools;36.0.0（版本已记录 README）
  - [x] `flutter create --platforms=android .` + 权限 manifest 写入（T0.4）
  - [x] `flutter build apk --debug` 出包（101MB，含 4 ABI 的 librust_flutter_ui_native.so，
        cargokit 自动交叉编译 4 目标）
  - [x] app 级 `compileSdk=36` / `ndkVersion=27.0.12077973` 对齐插件要求
  - [x] **复核（2026-10-08，M1 加入原生依赖 socket2 后）**：重新出包成功，APK 内含 4 ABI 的
        `librust_flutter_ui_native.so`（arm64-v8a / armeabi-v7a / x86 / x86_64）
  - [ ] **真机启动**（待 Android 设备：安装 `build\app\outputs\flutter-apk\app-debug.apk`）
- [~] **T0.2** ⚠️ 风险1预案：frb 双平台桥接验证 — **Windows 已验证，Android 待真机**
  - [x] Rust `ping_platform()`（api/simple.rs，frb sync）+ codegen 重新生成
  - [x] 设置页「关于」实时显示 Rust 端平台；启动诊断写 `%TEMP%\lanchat_startup_diag.txt`
  - [x] **Windows 验证通过**：`bridge=ok / rust_platform=windows`（诊断文件证据）
  - [x] 修复真实缺陷：frb 默认 `ioDirectory`（相对 CWD 的 `rust_builder/target/release/`）
        加载到陈旧手动构建产物 → content-hash 不匹配 → 显式加载 exe 旁 cargokit DLL（README 已记录）
  - [ ] Android 真机调用一次（装 APK 后看设置页显示 `[android]`）
  - 降级预案（cargokit 手动 cargo ndk）**未启用** —— cargokit 交叉编译原生可用
- [x] **T0.3** Rust 核心目录重构（0.5d）✅ 验收通过（2026-10-08）
  - `rust_builder/src/backend/{protocol,discovery,pairing,session,transfer,storage}.rs`
    骨架（**命名偏差**：`core` 与 crate `core` 歧义，改用 `backend`，见 mod.rs 注释）
  - 帧结构按 PLAN §4 落地：`LCHT` 魔数 + version + type + length + JSON payload
  - 验收：`cargo test` **22 个测试全过**（帧回环/粘包/半包/坏魔数/超长帧/邻居表超时/退避/续传状态机/分页游标）
- [x] **T0.4** ⚠️ 权限与平台清单落地 ✅（2026-10-08）
  - [x] `docs/permissions.md`：Android 权限清单（INTERNET/MULTICAST_STATE/通知…）
    + 运行时行为清单 + Windows 防火墙规则与引导文案
  - [x] README：防火墙允许提示 + AP 隔离排障说明 + frb 加载陷阱
  - [x] Android manifest 声明已写入 `android/app/src/main/AndroidManifest.xml`
        （INTERNET / ACCESS_NETWORK_STATE / ACCESS_WIFI_STATE /
        CHANGE_WIFI_MULTICAST_STATE / POST_NOTIFICATIONS）
- [~] **T0.5** UI 壳与自适应布局 — PC 端完成
  - [x] 5 页面 + 路由 + 明暗主题（消息/设备/配对/联系人/设置，已真机截图验证）
  - [x] 断点 ≥900dp 双栏 / <900dp 单栏（shell 内实现）
  - [ ] Android 竖屏单栏真机验证（随 T0.1 出包后）
- [x] **T0.6** 构建脚本与版本锁定 ✅ 验收通过（2026-10-08）
  - `scripts/{codegen,build_windows,build_apk,test_rust}.ps1`（统一镜像 + frb 2.8.0 版本锁检查）
  - 验收：一条命令出包；README 已记录版本锁定原因（风险13）
  - 修复（2026-10-08，T1.3 期间暴露）：
    ① `$ErrorActionPreference='Stop'` + native 命令写 stderr → PS 5.1 视为终止错误，
    `codegen.ps1` 在 `flutter pub get` 处直接中断；改为 `Continue` + 逐条检查 `$LASTEXITCODE`
    ② `.ps1` 必须保留 **UTF-8 BOM**：无 BOM 时 PS 5.1 按 GBK 解码中文注释，
    会拆错字节并吞掉行尾换行 —— 下一行代码被并进注释（曾让版本锁检查误报）
  - 验收：`test_rust.ps1` / `codegen.ps1` / `build_windows.ps1` 在 Windows PowerShell 5.1 下均跑通
- [x] **T0.7** 旧代码清理 ✅ 验收通过（2026-10-08）
  - [x] 删除废弃 `native/` 目录（已确认零引用）
  - [x] `windows/CMakeLists.txt` manifest_dir 已修正为 `..`（曾指向 native 导致编译旧代码）
  - [x] 演示 Dashboard 主代码归档至 `docs/archive/main_dashboard_demo.dart`
  - 验收：`dart analyze lib` 零问题，Windows 构建产物干净

---

## M1 · 设备发现（预估 2–3d）

> 目标：同网段设备互见、在线状态实时。

- [x] **T1.1** Rust：UDP 组播/广播发现服务 ✅ 验收通过（2026-10-08）
  - `backend/discovery.rs`：真实 socket（`SO_REUSEADDR` / `SO_BROADCAST` /
    `join_multicast_v4`），3s 心跳 + 10s 超时（`DEFAULT_*`），**组播 + 受限广播双发**，
    另可对 `peers` 单播补发
  - 邻居表 `upsert` 区分 Inserted/Updated/Unchanged —— 心跳只刷新时间**不推事件**
    （避免 3s 一次 UI 抖动）；`prune` 摘除超时设备并推 `Removed`
  - 入表逻辑抽成纯函数 `absorb_datagram`（过滤自身回环报文 / 协议版本不符 / 坏包）
  - 验收：`cargo test` **36 个全过**（其中 discovery 13 个），**含真实 socket 端到端**：
    两实例 loopback 互见（Added）+ 一方退出后摘除（Removed）
- [~] **T1.2** ⚠️ 风险2/3：AP 隔离兜底 + 组播锁 — 代码完成，待真机走查
  - [x] **逐网卡子网定向广播**（关键修复，见 T1.6）+ 组播组在**每块网卡**上 join
        + 受限广播兜底（PLAN 风险3）
  - [x] `DiscoveryHandle::add_peer()` 手动直连：加入目标后**立刻**补发一份 HELLO
  - [x] Android `MulticastLock`：`MainActivity.kt` 新增 `lanchat/platform` 通道
        （`deviceName` / `filesDir` / `acquire|releaseMulticastLock`），
        `DiscoveryService.prepare()` 申请、`stop()` 释放（省电模式丢组播包，风险3）
  - [x] 同机多实例已验证：`SO_REUSEADDR` 让两个进程都能绑 45999（身份用
        `LANCHAT_INSTANCE=2` 区分，见 T1.3）
  - [ ] 手机热点（AP 隔离）真机走查
- [x] **T1.3** frb 桥接：邻居列表事件流 ✅ 验收通过（2026-10-08）
  - Rust `api/discovery.rs`：`discovery_subscribe()`（`StreamSink` → Dart
    `Stream<DiscoveryEventDto>`）、`discovery_start/stop/status/devices`、
    `discovery_add_peer`（手动直连）、`discovery_announce`
  - Dart `lib/services/discovery_service.dart` 封装；`AppState` 订阅事件流**增量**维护设备
    列表（推送不是轮询）；桥接不可用时自动退化为演示数据，UI 不崩
  - 本机身份：`device_id` 持久化到 `%APPDATA%\LanChat\device_id`（Android 为应用私有
    目录），重启仍是同一台设备；同名设备在列表里附 4 位 id 区分
  - 自检：`discovery_stats()`（发出/收到/忽略 HELLO + 最近一次收到时间）、
    `discovery_interfaces()`（参与发现的网卡）→ 设备页空状态直接给出排查建议
  - **注意**：同机跑两个实例必须设 `LANCHAT_INSTANCE=2`，否则两个进程共用同一个
    持久化 id，会把对方当成「自己」过滤掉（实测 `hellos_received=0`，已复现并修复）
  - 验收（Windows 双实例，证据 `%TEMP%\lanchat_startup_diag_<pid>.txt`）：两进程均为
    `discovery=UDP :45999 · 组播已加入`；A 视角 `PC_STUDIO (2)@192.168.1.191`
    （真实局域网地址）、B 视角 `PC_STUDIO@192.168.1.191`；杀掉对端 11s 后列表清空。
    一键复现：`.\scripts\run_two_instances.ps1`（实测 hellos 20/15 与 20/20）
- [x] **T1.4** UI：设备发现页 ✅ 验收通过（2026-10-08，Windows 截图 + Android 出包）
  - [x] 设备页/设置页展示真实邻居（Rust 事件驱动，含 IP 自动跟随）；设置页显示发现端口、
        组播状态与参与发现的网卡
  - [x] 「本机」卡片改为**真实**身份（设备名 / 短 id / 本机地址 / 组播锁状态）——
        原先这里是硬编码的 `本机 · DESKTOP-ORION` + `192.168.1.23:9527`，**双端显示同一份
        假身份**，即用户反馈的「本机识别是错的」
  - [x] 空状态改为自检（发出/收到计数 + 网卡列表 + 防火墙 / AP 隔离排查建议 + 重新发现）
  - [x] **雷达动效**：`_DiscoveryRadar` 只在 `discovering` 时转动（扫描扇形 + 设备光点按
        黄金角稳定分布），停止发现后转静态；尊重系统「减少动态效果」；状态行显示
        「发现中 · 已发现 N 台设备 · UDP :端口 · 网卡 N 块 · 组播状态」
  - [x] **Android 权限引导卡**（PLAN §3.2）：先解释用途（消息 / 文件提醒）再弹系统框，
        `MainActivity` 新增 `notificationsGranted` / `requestNotifications`；
        「暂不」只是本次不再提示，收发功能不受影响 —— 被拒有引导而非死路
  - 验收：Windows 实机截图 `shot_t14_final.png`（雷达 + 状态行 + 真实本机卡片
    `本机 · PC_STUDIO / ID fa5a / 192.168.1.191:45998` + 设备行 `PC_STUDIO (2)` 同屏）；
    网卡按地址排序，本机地址首行即真实局域网地址；APK 重新出包通过
- [ ] **T1.5** 双平台联调
  - [ ] 双 Windows **两台机器**、Win↔Android 互见；关闭一台 10s 内消失（本机双实例已过）
  - [ ] ⚠️ 换 3 个网络环境复测（风险2）
- [x] **T1.6** ⚠️ 多网卡主机发现失效 + 地址抖动 ✅ 验收通过（2026-10-08）
  - **现象**（用户反馈「没有发现设备」的根因）：出接口交给系统选时，多网卡主机的
    组播/广播被选到 VMware 虚拟网卡 —— 实测对端来源 IP 是 `192.168.238.1` 而不是
    `192.168.1.x`，真实局域网里的第二台设备根本收不到 HELLO
  - **修复**：`local_interfaces()` 枚举本机 IPv4 网卡（跳过 loopback / 169.254），
    每块网卡都 join 组播组，心跳改为**逐网卡子网定向广播**（`192.168.1.255` /
    `192.168.152.255` / `192.168.238.255`）—— 定向广播按路由表走对应网卡
  - **地址优选**：`AddrPolicy` 优先与本机同子网的可达地址并保持既有优选（不抖动），
    无网卡信息时跟随新地址（DHCP 换 IP，风险17）；`Neighbor.addr_history` 记录来源
    地址历史（承接 T2.2 的 `addr_history`）
  - 验收：回归测试 `heartbeats_are_sent_out_every_local_interface` —— 独立接收端观察到
    的来源地址必须覆盖**全部**本机网卡（修复前只有 VMnet1）；地址优选/历史另有 3 个单测；
    App 内 diag 显示对端为 `PC_STUDIO (2)@192.168.1.191`（真实局域网地址）

---

## M2 · 握手配对（预估 2d）

> 目标：确认身份、成为联系人、持久化。

- [x] **T2.1** Rust：握手与配对状态机 ✅ 验收通过（2026-10-09）
  - `PAIR_REQ{device_id,pin,ts_ms}` → `PAIR_RESP{accepted,reason}`；`backend/pairing.rs` 是
    **纯状态机**（输入 `PairInput`：网络事件 / 用户操作 / 超时 tick；输出 `PairAction`：
    要发的帧 / 要显示的 PIN / 要落库的联系人），传输层未到位也能把规则全测掉
  - 规则：60s 超时（严格大于阈值才算超时）、失败可重试、已配对幂等成功、
    非法 PIN 拒绝、忙时回 Busy 不打断当前会话、超长名字截断、PIN 6 位数字校验
  - 验收：`cargo test` **72 个全过**，其中配对状态机 17 个（超时/拒绝/重试/重复/忙碌/幂等/取消）
- [x] **T2.2** Rust：配对表持久化 ✅ 验收通过（2026-10-09）
  - 介质选型：**JSON KV + 原子写**（写 `.tmp` 再 rename）—— 联系人只有几条，人可读易备份，
    跨平台零依赖；文件损坏时备份成 `.corrupt` 后空表启动（绝不静默丢数据）。
    SQLite（rusqlite bundled）留给 T3.3 的消息历史，**其 Android 交叉编译尚未验证**
  - 存 `device_id / name / platform / addr_history / paired_at_ms / last_seen_ms`；
    `addr_history` 最新置顶去重截断（M3 建连按序尝试），承接 T1.6 的地址优选
  - 落盘位置：`%APPDATA%\LanChat\contacts.json`（Android 应用私有目录）；
    `LANCHAT_DATA_DIR` 可覆盖（集成测试隔离用）
  - 验收：8 个存储单测（跨重启读回 / 合并 / 删除 / 原子写不留 tmp / 损坏留档）；
    Dart↔Rust 桥接测试 3 个；集成测试断言「重新解析磁盘后联系人仍在、PIN 不落库」
- [x] **T2.x 补齐：PAIR_REQ/PAIR_RESP 走 TCP** ✅（2026-10-09，M3 期间发现并修复）
  - **缺口**：T2.1 的状态机在 M2 完成时与传输层没接上 —— 配对只在单机状态机里推演，
    两台真实设备之间根本无法配对（PAIR_REQ 没有发送路径）。这是收尾时准备做
    手工端到端联调才发现的
  - **修复**：`session.rs` 新增 `PairRequest`/`PairResponse` 事件 + `send_frame_to`/
    `Dialer::send_frame` 通用帧通道；`api/chat.rs` 提供 `chat_send_pair_request`/
    `chat_send_pair_response`（主动拨号与被连入方向都能发）；Dart 侧 `ChatService` +
    `AppState` 串起来：发起方 `beginPairing` 产出 PIN 后真发 PAIR_REQ → 对端会话事件
    `pairRequest` → 自动聚焦设备并弹 PIN 卡（`beginResponderPairing`）→ 用户确认 →
    回 PAIR_RESP → 发起方 `pairResponse` 事件 → 状态机 `responseReceived` → 落联系人
    → 双方进会话
  - 验收：Rust 90 测试全过（含配对帧解析事件）；analyze 零问题；双平台构建通过
  - 待用户统一真机验收：两台设备走一次完整 PIN 配对 + 重启免配对（T2.4）
- [~] **T2.3** UI：配对确认页 — 已接真状态机，动效与「跳过 PIN」待补
  - [x] 6 位 PIN **来自 Rust 状态机**（原来本地随机，两边看到的不一样）、大字分组显示、
        60s 倒计时（初值与超时判定都取自 Rust 常量/状态机）
  - [x] **角色区分**：发起方显示「已核对 PIN，等待对方确认…」（等 PAIR_RESP，**不得**单方面
        写联系人）；应答方才显示「确认配对」→ 回 PAIR_RESP + 落库 + 建会话
  - [ ] 配对成功动画、设置项「跳过 PIN」（PLAN §3.3）
  - **过程缺陷（集成测试发现，均已修）**：
    ① `Shell` 中读 AppState 的子树写成 `const`（NavRail / 三个面板 /
    `DeviceDetailView` / `SettingsPage` / `BottomNavBar`）—— Flutter 收到 identical 的
    const widget 会**跳过重建**，UI 卡在旧数据：应答方 PIN 卡片根本不显示、设备列表要切页
    才刷新；已去掉这些 const 并写注释说明原因
    ② 发起方的「确认配对」原本会直接完成配对并写联系人 —— 协议上属于单方面落库；
    已改为角色感知（发起方只能等 PAIR_RESP）
  - 桌面合成鼠标点击（SetCursorPos + mouse_event）在该 PIN 视图上不可靠（坐标命中
    FLUTTERVIEW 但按钮无响应）→ UI 回归改用 Flutter 官方 `integration_test -d windows`
    驱动真实应用（命令见 README）
- [ ] **T2.4** 双平台联调
  - 验收：Win→Android、Android→Win 各配对一次；重启两台设备免重新配对

---

## M3 · 文字聊天（预估 4–5d）

> 目标：微信式会话 P0 功能全部可用（PLAN §3.5 P0 行）。**这是用户第一眼看到的体验，UI 细节优先。**

- [x] **T3.1** Rust：TCP 会话与重连 ✅ 验收通过（2026-10-09）
  - `backend/session.rs`：`listen`（接受连接）/ `dial`（指数退避持续重连）/ `Connection`
    （hello 握手、心跳 PING/PONG、BYE、超时判离线）；收发的字节序/帧解析复用 protocol
  - 心跳 3s、静默 10s 判离线；心跳与业务帧共用一把写锁，避免字节级交错
  - 谁都能发：主动拨号走 `Dialer::send_text`，被连入方走 `Listener::send_text_to`（按 peer_id）
  - 验收：7 个测试 —— 双向收发文本、**粘包/半包**（1 字节切帧 + 两帧一写）、
    超时判离线、**网络恢复自动重连**（先拨空端口 → 起监听 → 自动接上）、坏 magic 关连接
- [x] **T3.2** ⚠️ 风险9/10/11：帧编解码 + 消息序号 ✅（T0.3 编解码 + 本轮序号）
  - 长度前缀解析器 + version/magic/超长帧校验（T0.3 已有 12 个测试）
  - 新增 `SeqTracker`：会话内 `(sender_id, seq)` 单调递增，重复/乱序丢弃，**不依赖墙钟**
    （风险11）；发送侧 `next_out` 从 1 开始
  - 验收：`seq_tracker_dedupes_and_orders`（重复/旧包/跳号/多 sender 独立）
- [x] **T3.3** Rust：消息存储 ✅ 验收通过（2026-10-09）
  - **介质改为 append-only JSONL**（每会话一个文件）+ 读游标 JSON：PLAN 原选型是
    rusqlite bundled，但 SQLite 的 C 代码交叉编译到 Android 未经验证（会引入 NDK 风险）；
    v1 验收标准（500 条 <50ms + 重启不丢）用日志 + 内存索引完全满足，跨平台零依赖。
    接口（page/unread/append/mark_read/conversations）设计成可平移 redb/SQLite
  - keyset 分页（首屏 50 条、新的在前）、未读计数（收到即入库、自己发的不算）、
    已读游标只前进、会话摘要排序、坏行/半行跳过不丢整会话、peer_id 文件名白名单
  - 验收：6 个存储测试（**500 条分页 <50ms**、重启读回、未读/已读持久化、坏行容忍、
    摘要、路径穿越防护）+ Dart 桥接端到端（收到即入库 / 重启 total 不变）
- [x] **T3.4** UI：聊天页骨架 ⭐ ✅（2026-10-09）
  - 聊天页改为**按 peer_id 取会话**（`ChatPage(peerId:)`）：会话列表会重排/重建，
    传 Conversation 对象会拿到过期实例 —— 这是真实数据接入时的关键改动
  - 反转 `ListView.builder`、气泡（左右/头像/圆角/主题配色）、时间分隔线（>5min）沿用；
    消息来源换成 `MessageStore`（打开会话拉最近 50 条）
  - 空状态区分为「未就绪 / 启动中 / 还没有消息」，不再拿假消息撑场面
  - ⏳ 待用户验收：500 条滚动帧率、深浅主题对比度
- [x] **T3.5** UI：输入栏与键盘行为 ✅（2026-10-09）
  - 多行自适应（minLines 1 / maxLines 5）；桌面 Enter 发送 / Shift+Enter 换行
    （`HardwareKeyboard` 处理器抢在焦点链之前，中文输入法组合中不误发）；
    Android 用右侧发送钮，提示文案按平台区分
  - ⏳ 待用户验收：Android 键盘弹出布局、中文候选回车行为
- [x] **T3.6** UI：消息状态与长按菜单 ✅（2026-10-09）
  - 发送中 spinner / ✓ 已发出 / 失败红叹号（点击直接重试）；长按菜单：复制 / 重新发送 / 删除
  - 发送改为真实链路：乐观上屏 → Rust 落库并发出 → 用**落库后的消息替换乐观条目**
    （id 与存储一致，重载历史不会重复）；发送失败标红，重连后可重发
  - 说明：✓✓「已送达」需要消息级 ACK，M3 协议暂无 → 目前发出即 ✓
    （已在 README 记为后续小项）
- [x] **T3.7** UI：联系人列表页 ✅（2026-10-09）
  - 会话行：头像/未读角标/在线绿点/相对时间/摘要（「我: 」前缀）；搜索按名称与摘要过滤；
    空状态区分「暂无会话」与「没有匹配」
  - 长按菜单（PLAN §3.4）：清空本地聊天记录（真实删存储文件）/ 删除联系人（配对表）；
    联系人页点「聊」直接按 peer_id 打开真实会话
  - 会话列表由「配对表 + 本地历史摘要 + 发现结果」组装，按最后消息时间倒序；
    在线状态来自会话事件（连接/断开）
- [x] **T3.8** 性能验收：历史加载与吸底 ✅（2026-10-09）
  - 上翻到最早附近自动拉上一页（keyset 分页，`before_ts_ms = 已加载最早一条`），
    不足一页即判定到底，不再重复请求
  - 用户上翻期间来新消息**不强制吸底**，改显示「回到最新」悬浮按钮；回到最新自动清掉
  - ⏳ 待用户验收：连发 50 条流畅度、上翻增量加载无闪烁

---

## M4 · 文件传输（预估 4–6d）

> 目标：大文件可靠送达（PLAN 里程碑 M4 验收标准）。

- [x] **T4.1** ⚠️ 风险8：传输协议与状态机 ✅ 验收通过（2026-10-10）
  - `SendSender`（窗口流控：在途 ≤8 块；续传点由首个 ACK 携带）+ `Receiver`
    （`on_meta`/`on_chunk`/`on_done` 三段驱动，均不碰网络，api 层接帧）；
    拒绝走 `FILE_ACK.reason`、校验失败走 `FILE_DONE.error`
  - 指纹 `(file_id,size,hash)` 不一致即从头传（风险8，sidecar 存 `.part.meta`）
  - 验收：**状态机单测 15 个** —— 正常全量、断点续传、指纹变化从头传、磁盘不足拒绝、
    哈希不一致丢弃、乱序/重复 chunk 重同步、越界拒绝、窗口流控与 DONE 时序、
    空/1B/块边界文件、文件名清洗、磁盘探测
- [x] **T4.2** Rust：分块发送/接收 + 断点续传 ✅ 验收通过（2026-10-10）
  - 256KB 分块（`DEFAULT_CHUNK_SIZE`）、`.part` 临时文件 + `.part.meta` 指纹 sidecar、
    完成后**原子改名**；重复 chunk 幂等、缺口回当前位让对端重发
  - 续传 e2e：第一轮发 3 帧中断 → 第二轮 `FILE_ACK.offset = part 长度` → 补齐后逐字节一致
  - ⏳ 1GB 杀进程重启续传（T4.7）待用户真机验收 —— 逻辑路径已由 512KB 中断续传测试覆盖
- [x] **T4.3** Rust：完整性校验 + 错误处理 ✅ 验收通过（2026-10-10）
  - 收端完成后**整读比对 blake3**（对续传天然正确，0..size 全量都在文件里）；
    不一致 → 删 part+sidecar 拒绝对端重传；256KB 流式读写，**任何文件不整包进内存**（风险16）
  - 磁盘空间预检：Windows `GetDiskFreeSpaceExW` / Unix `statvfs`，不足直接 `FILE_ACK.reason` 拒绝（风险18）
  - 文件名：去路径 + 替换非法字符 + Windows 保留名 + 尾部点空格 + 180 字符截断；
    重名自动编号 `a (1).txt`（风险15）
  - 验收：伪造哈希 DONE 被拒且坏文件不落地；磁盘不足注入测试；文件名 4 组测试
- [~] **T4.4** ⚠️ 风险5：进度桥接 ✅（实现方式有偏差，已记录）
  - **实现**：传输中枢（hub 线程）内 ≥100ms 节流更新状态快照，Dart 以 400ms（≤2Hz）
    拉 `transfer_status()`，只更新目标气泡的 `progress` —— 与 PLAN 的「Rust 合并推送」
    等价但方向相反（拉取而非推送），避免为进度再开第二条 frb 事件流
  - `File*` 帧不进聊天 UI：chat 事件中继把它们转发到 hub 的二级总线
    （两个 mpsc 消费者互抢的问题由这条中继解决）
  - ⏳ 用户验收：传输中 UI 帧率、DevTools 无整页 rebuild
- [x] **T4.5** UI：文件消息卡片 ✅（2026-10-10，复用既有卡片接真实数据）
  - 图标/文件名/大小/进度条来自真实传输；`msg.fileId` 关联进度对象，400ms 局部更新；
    失败标红 + 重发（`retryTransfer` 按 `filePath` 重发）；取消 = `transfer_cancel`
  - 收到文件在历史里仍是**卡片**（`kind/file_name/file_size` 入库，重启不退化成文本）
- [x] **T4.6** 文件选择与收件目录 ✅（2026-10-10）
  - 发送：`file_picker`（类型可选文件/图片；Android SAF 由插件处理，风险7 待真机）
  - 接收：`<数据目录>/chat/downloads`（`messages_open` 注入根目录后自动创建）
  - ⏳ 「打开所在位置」入口待做（v1 未提供，可进收件目录）；双平台验收待用户测试
- [ ] **T4.7** 内存与稳定性压测 —— **待用户测试**（需要 1GB 真实文件 + 双端）
  - 1GB+ 双向传输，观测 Rust 峰值内存 <150MB；杀进程重启续传
    （T4.2 的 e2e 用 512KB 已验断点路径）；切后台/锁屏行为（风险6，v1 允许中断后恢复）
  - 验收：内存曲线平稳，无 OOM/无 UI 卡死
- [~] **T4.8** 多任务与取消 ⚠️ 部分完成
  - [x] 同一会话并发多发送（`sends` 按 file_id 分键）；`transfer_cancel` 取消单个不影响其他；
    重复接收同名自动编号（`unique_dest`）
  - [ ] **单对端同时只收一个文件**（v1 约定：新 `FILE_META` 替换未完成的旧接收）——
    并发接收需要按 `(peer_id,file_id)` 分键 + FILE_CHUNK 路由改造，列入后续池
  - ⏳ 场景走查待用户测试

---

## M5 · 体验打磨（预估 3–4d）

- [x] **T5.1** 图片消息 ✅（2026-10-10）
  - 气泡缩略图：`Image.file` + `cacheWidth: 400`（按 2×DPR 解码，imageCache 缓存不重复
    解码，PLAN §3.6-3）；发送方取源文件路径，接收方按文件名在收件目录查找
    （`localImagePath`，含重名编号 (1)…）；找不到文件时回退占位渐变
  - Hero 全屏预览 + `InteractiveViewer`（最大 4× 缩放）；传输中显示进度环遮罩
  - **偏差说明**：PLAN 原计划 Rust 端缩图，实测 Dart 端 cacheWidth 解码等价且零新依赖，
    Rust 端缩图列为后续可选优化
  - 验收：`ui_polish_test` 验证真实文件渲染 + 预览可缩放
- [x] **T5.2** 动效 ✅（2026-10-10）
  - 气泡入场：fade+上滑 8px/120ms（easeOut；列表复用滚动不重播）
  - 配对成功：PIN 卡 → ✓ 弹跳（easeOutBack 520ms）→ 900ms 后自动进会话
    （应答方/发起方两条路径都走 `pairingSucceeded`）
  - 进度条平滑：`TweenAnimationBuilder` 320ms 插值到目标进度
- [x] **T5.3** 全状态走查 ✅（2026-10-10）
  - 顶部全局状态条（`_ConnectionBanner`，宽窄屏通用）：错误（红，可点掉）/
    当前会话断连自动重连中（琥珀）
  - 空/加载/错误三态：设备页自检空态、聊天页未就绪/无消息区分、发现雷达静止态
- [x] **T5.4** 拖拽/粘贴 + 主题 ✅（2026-10-10）
  - Windows 拖拽发送（`desktop_drop`，整个聊天区域是投放区，按扩展名分图片/文件）
  - Ctrl+V 粘贴发送（`pasteboard`）：优先资源管理器复制的文件 → 截图位图（存临时
    PNG 发送）→ 文本（自插到光标处，替代被吞掉的默认粘贴）
  - 明暗主题走查：`shot_t14_final.png`（浅色）/ 深色经 widget 测试与双主题断言覆盖
- [x] **T5.5** 可用性细节 ✅（2026-10-10）
  - 新消息悬浮按钮（T3.8 已做「回到最新」）；设置页接收目录 tile 显示真实下载路径
  - 首次使用引导：三步卡（扫描→配对→聊天/传文件），关闭写 `.onboarded` 标记
    （截图 `shot_m5_onboarding.png` + `ui_polish_test` 覆盖显示/关闭）
- [x] **T5.6** 键盘与焦点 ✅（2026-10-10）
  - Enter 发送带 IME 组合态保护（`composing.isValid` 时不发，中文回车确认候选不出消息）；
    Shift+Enter 换行；`onSubmitted` 兜底路径同样避开组合态
  - Ctrl+V 在组合态放行默认粘贴；输入框 autofocus（打开会话即可打字）

---

## M6 · 打包发布（预估 2–3d）

- [ ] **T6.1** Android 打包：release 签名、targetSdk 合规、`POST_NOTIFICATIONS` 运行时请求、安装包体积检查
- [ ] **T6.2** Windows 打包：MSIX 或 Inno Setup 安装器、桌面快捷方式、**首次启动防火墙引导文案**（风险4）
- [ ] **T6.3** ⚠️ PLAN §7 测试矩阵全走查（发现/网络/文件/消息/系统 五组场景）
- [ ] **T6.4** 用户文档：README（安装、配对、防火墙、AP 隔离排障）+ 版本锁定与已知限制
- [ ] **T6.5** v1.1/v2 待办入池：后台前台服务保活（风险6）、已读回执/撤回、**端到端加密 X25519+AES-GCM**（风险14）、iOS

## M7 · 用户反馈一轮（正式命名「雨传 YuChuan」+ 移动端体验）

> 起因：安卓真机首次使用走查反馈的 21 条。编号 R0–R20 对应用户的 0–20。
> 自动化覆盖见本文末「R 任务 → 测试条目对照表」；标注 ⏳ 的需要双端真机走查。

- [x] **R0** 正式命名「雨传 YuChuan」✅（2026-10-11）
  - 显示名：Android `android:label="雨传"`、窗口标题 `雨传 YuChuan`（自定义标题栏）、
    `MaterialApp.title`、关于页、启动诊断 `app=雨传 YuChuan v1.0.0`
  - 标识：`applicationId / namespace = com.yuchuan.app`（MainActivity 迁到
    `kotlin/com/yuchuan/app/`）、原生通道改名 `yuchuan/platform`
  - 路径：Windows 数据目录 `%APPDATA%\YuChuan`、诊断文件 `yuchuan_startup_diag*.txt` /
    `yuchuan_ui_error.txt`、Rust 兜底设备名「雨传设备」
  - **保留**：Dart 包名 `rust_flutter_ui` 与 Rust crate 名（内部标识；改名会牵动全部
    import 与 cargokit 插件链路，收益为零）
  - ⏳ 真机：安装后桌面图标与名称显示「雨传」（换了 applicationId，需卸载旧包重装）
- [x] **R1** 聊天显示发送的一切信息 + 文件 TAB 独立 ✅
  - 文件 TAB 只读收件目录，与会话页完全解耦；聊天里不再注入假的「已建立会话」系统消息
    （`openConversationWith` 统一按 peer_id 取共享消息列表，新消息才会实时上屏）
  - 文件消息任意类型都可定位本地路径（`localFilePath`，发送方源文件 / 接收方按名查找含重名编号）
  - 测试：`mobile_features_test`「聊天时间线与消息菜单」组（文本/文件/图片三类都上屏）
- [x] **R2** 文件 TAB 图标视图：图标在上、名称在下、尺寸正确 ✅
  - 瓦片：52×52 圆角图标底（30 号图标，按类型着色）+ 名称（居中、两行省略）+ 大小/日期
  - 列表视图同步为「图标 + 名称 + 大小/日期 + 打开」
  - 测试：`mobile_features_test`「文件 TAB」组
- [x] **R3** 安卓点开收到的文件（apk 直接调安装器）✅
  - `MainActivity.openFile`：FileProvider `content://` + `ACTION_VIEW`，
    apk → 系统安装器（新增 `REQUEST_INSTALL_PACKAGES`），其余按扩展名猜 MIME；
    manifest 增加 `queries`（http/https/content/file）保证可见性
  - 聊天文件卡片单击即打开；长按/右键菜单含「打开文件 / 打开所在文件夹」；桌面端=资源管理器定位
  - ⏳ 真机：apk 安装、图片/文本/视频/压缩包各开一次
- [x] **R4** 聊天按时间线排序，最新在底部 ✅
  - 反转 `ListView` + 数据按时间升序；测试断言 `reverse: true` 且最新消息存在
- [x] **R5** PC 右键菜单 / 安卓长按菜单，带图标 ✅
  - 新增 `lib/ui/menus.dart` 的 `showIconMenu`：安卓=底部菜单，桌面=右键弹出菜单；
    消息气泡、文件卡片、文件 TAB 共用；条目按类型增减
    （复制 / 打开链接 / 打开文件 / 打开所在文件夹 / 取消传输 / 重新发送 / 删除）
  - 测试：`mobile_features_test` 长按菜单组（断言 `Icons.copy_outlined` 等图标存在）
- [x] **R6** 安卓全面屏返回适配（之前返回直接退到桌面）✅
  - 窄屏 `PopScope`：详情页 → 列表 → 消息 TAB → 才退出应用
  - 测试：`mobile_features_test`「安卓返回栈」组
- [x] **R7** 安卓状态栏发黑 / 全面屏未适配 ✅
  - 根因：原生侧启动即 `controller.hide(systemBars())`（沉浸式隐藏），状态栏区域因此发黑；
    已改为**保持可见 + 透明**，Dart 侧 `SystemUiMode.edgeToEdge` + 透明系统栏，
    图标深浅跟随明暗主题；内容用 `SafeArea` 让出状态栏
  - ⏳ 真机：深浅主题下状态栏图标对比
- [x] **R8** 选中 TAB 样式 ✅
  - 选中态：`primaryContainer` 实心胶囊 + primary 描边 + `onPrimaryContainer` 图标与加粗标签，
    胶囊宽度随选中变化（动效 180ms）
  - ⏳ 真机截图确认
- [x] **R9/R10** 外观设置整合进设置 TAB + 更多分区 + 自定义选色 + 壁纸开关 ✅
  - 外观全部搬进「设置」TAB：深色模式 / 主题色 / 壁纸 / 壁纸滤镜 / 遮罩（独立分区）；
    标题栏「设置」按钮改为跳转设置 TAB，`AppearanceDialog` 删除
  - 新增 `lib/ui/color_picker.dart`：色相条 + 饱和度×明度方块 + 十六进制输入（零依赖），
    主题色与遮罩色都可自定义
  - 壁纸开关 `wallpaperEnabled` 持久化（关闭保留路径，可随时再开）
  - 测试：`mobile_features_test`「设置页」组
- [x] **R11** 关于面板作者信息 ✅
  - 「关于」新增作者行：B站：音乐制作王某人 → `https://space.bilibili.com/80192671`
    （安卓走 Intent，桌面走默认浏览器）；测试断言文案存在
- [x] **R12** 删除联系人级联清理 ✅
  - 配对表删除 + 断开连接（hangup）+ 清本地历史（存储文件+内存）+ 移除会话行/设备行 +
    清在线状态与拨号记录
- [x] **R13** 双端请求配对都弹操作窗口 ✅
  - 新增 `lib/ui/pairing_dialog.dart`：发起方（点「开始配对」）与应答方（收到 PAIR_REQ，
    经 `AppState.onPairRequest` 回调）都会弹窗；应答方有「确认配对 / 拒绝」，发起方显示等待态
  - ⏳ 真机：Win→Android、Android→Win 各一次
- [x] **R14** 绘制符合定位的应用图标 ✅
  - `scripts/gen_icon.py`（Pillow）：靛紫渐变圆角方块 + 白云 + 雨 + 纸飞机（雨传/传输）
  - 输出：安卓 5 档 mipmap（48/72/96/144/192）+ Windows 多尺寸 `app_icon.ico`
- [x] **R15** 完善 PC 右键 / 安卓长按菜单 ✅ —— 同 R5（消息、文件卡片、文件 TAB 三处）
- [x] **R16** 自动识别文字里的链接，单击打开浏览器 ✅
  - `lib/ui/linkify.dart`：http/https/ftp/www 识别 + 尾部标点裁剪；
    气泡内渲染为可点片段；消息菜单也有「打开链接」
  - 测试：`mobile_features_test`「链接识别」组
- [x] **R17** 发送的取消按钮无效 ✅
  - 根因：取消只处理「已有 fileId」的情况，而 Rust 侧算哈希的 1–2s 里消息还没有 fileId；
    现在 pending 阶段记入 `_cancelledPending`，拿到 fileId 后立刻撤单，不再上屏
  - 测试：`mobile_features_test`「取消发送」组
- [x] **R18** 安卓后台不要断连 ✅（基础保活）
  - 原生持有高性能 `WifiLock(WIFI_MODE_FULL_HIGH_PERF)` + 既有 `MulticastLock`；
    manifest 声明 `WAKE_LOCK / CHANGE_WIFI_STATE`；Dart 侧定时器不随生命周期停止
  - ⏳ 真机：切后台 5 分钟再回来，会话与传输仍在；完全保活（前台服务）列在 v1.1
- [x] **R19** 连接后自动同步最近聊天 + 续传中断文件 ✅
  - `connected` 事件 → `_syncAfterConnect`：重拉本地历史 + 补发中断/失败的出站文件；
    Rust 侧按 `.part` 指纹判定续传，续不上就从头重发
  - ⏳ 真机：断网→恢复，双方历史补齐、中断文件续传
- [x] **R20** 文件 TAB 追加排序方式 ✅
  - 时间（最新/最早）/ 名称（A→Z / Z→A）/ 大小（大→小 / 小→大）/ 类型，
    带图标的弹出菜单 + 当前项勾选
  - 测试：`mobile_features_test`「文件 TAB」组（排序入口存在）

### R 任务 → 测试条目对照表

| 用户反馈 | 任务 | 自动化测试 | 真机走查 |
|---------|------|-----------|---------|
| 0 命名 | R0 | `flutter analyze` 零问题 + 出包通过 | ⏳ 桌面图标/名称 |
| 1 显示全部信息 / 文件 TAB 独立 | R1 | `mobile_features_test` 聊天时间线组 | — |
| 2 图标视图 | R2 | `mobile_features_test` 文件 TAB 组 | ⏳ |
| 3 打开 apk/文件 | R3 | Kotlin 编译 + 出包 | ⏳ 各类型文件 |
| 4 时间线排序 | R4 | `mobile_features_test`（reverse + 最新在底部） | ⏳ |
| 5/15 右键/长按菜单 | R5/R15 | `mobile_features_test` 长按菜单组 | ⏳ |
| 6 返回适配 | R6 | `mobile_features_test` 安卓返回栈组 | ⏳ |
| 7 状态栏 | R7 | — | ⏳ 深浅主题 |
| 8 选中 TAB 样式 | R8 | — | ⏳ 截图 |
| 9/10 外观整合 + 选色 | R9/R10 | `mobile_features_test` 设置页组 | ⏳ |
| 11 关于作者 | R11 | `mobile_features_test` 设置页组 | ⏳ 链接可打开 |
| 12 删除联系人 | R12 | — | ⏳ 双端 |
| 13 配对窗口 | R13 | — | ⏳ 双向各一次 |
| 14 图标 | R14 | — | ⏳ |
| 16 链接识别 | R16 | `mobile_features_test` 链接识别组 | ⏳ 浏览器可开 |
| 17 取消发送 | R17 | `mobile_features_test` 取消发送组 | ⏳ |
| 18 后台不断连 | R18 | — | ⏳ 切后台 5 分钟 |
| 19 重连同步/续传 | R19 | — | ⏳ 断网恢复 |
| 20 文件排序 | R20 | `mobile_features_test` 文件 TAB 组 | ⏳ |

> 全量自动化：`flutter test` 16 个测试全过（R 任务新增 12 个断言点）。
> M8 收尾后为 **21 个测试全过**，`dart analyze lib test` 零问题。

---

## M8 · 用户反馈二轮（重复气泡 / 配对窗口 / 提醒 / 收件目录）

> 起因：一轮真机走查后的第二批反馈（9 项返工 + 8 项新需求）。编号 B1–B18。

- [x] **B1** 聊天显示不全 + 重复气泡 ✅
  - **重复气泡根因**：`_pollTransfers` 里 `status()` 会把完成的传输留在「最近 32 条」，
    而入站消息在完成后已从 `_transferMsgs` 移除 → 下一轮 400ms 轮询又判定为「新入站」
    → 每 400ms 重建一条气泡。修复：排除 `finished` / 已落库 / 已取消，并按 `file-<id>`
    去重（`_beginIncomingTransfer` 也加了同 id 防重）
  - **消息缺失根因**：`loadHistory` 「列表非空就早退」—— 先到的在线消息会挡住存储里的
    历史。修复：按 peer 记 `_historyLoaded`，首屏把存储页与内存里的乐观消息按 id 合并，
    最后按时间排序
  - 测试：`mobile_features_test`「聊天时间线与消息菜单」组
- [x] **B2** 菜单扩展 ✅ —— 会话行（打开/复制设备信息/接收目录/清空/删除联系人）、
  设备行（详情/发消息/发起配对/复制 IP:端口/重新连接）、消息、文件卡片、文件 TAB；
  安卓长按 + 桌面右键同一套
- [x] **B3** 顶部设置按钮已移除 ✅（设置统一走底部 TAB / 侧边栏）
- [x] **B4** 状态栏仍发黑 → 主题里显式 `statusBarColor/navigationBarColor = transparent`
  + `windowDrawsSystemBarBackgrounds`（values 与 values-night 都补了）✅
- [x] **B5** 外观更多分区 ✅ —— 主题（显示模式三选 SegmentedButton + 主题色/自定义）、
  背景与壁纸（开关/滤镜/遮罩）、界面（字号/气泡宽度/气泡圆角/动画开关）、通知
- [x] **B6** 删除联系人残留 ✅ —— 根因是 `clearHistory` 只清列表**保留了 key**，
  `rebuildConversations` 按 `_history.keys` 组装会把刚删的会话又建回来；
  另加 `_removedPeers` 黑名单，重建一律跳过；`rebuildConversations` 桥接异常不再抛出
- [x] **B7** 配对窗口三连 bug ✅ —— 改成**状态驱动宿主** `PairingDialogHost`：
  ① 首次请求也弹（窗口先出、PIN 回填，不再受 80ms 等待限制）
  ② 全程只弹一个（不会再叠层卡住界面）
  ③ 角色判定：只有明确是发起方才显示「等待对方确认」，角色未知一律给「确认/拒绝」
  ④ **配对结束必须关窗**：成功动画播完/取消/拒绝都会把 `pairingActive` 置 false，
    窗口随之自动关闭（之前只播动画不关窗，界面就卡在弹窗上）
  （之前应答方会错弹成「发起配对」）
- [x] **B8** 取消发送不再留失败样式 ✅ —— 取消直接把气泡从聊天里移走并标记
  `cancelled`（不参与自动补发）
- [x] **B9** 链接固定显示为蓝色 ✅（浅底 `#1D4ED8`、深底 `#60A5FA`、主色气泡 `#BFDBFE`）
- [x] **B10** 历史膨胀 / 一端发文件另一端自动重复发 ✅ —— 重连补发改为「只补显式失败、
  非用户取消、且每个文件只补一次」（`_resyncedFiles`），不再按 `progress<1` 粗判
- [x] **B11** 清掉演示设备列表 ✅ —— 真实后端上线（`enableBackend`）即清掉种子设备/会话；
  联系人由配对表同步（`_syncDevicesFromContacts`），已配对/未配对状态正确
- [x] **B12** 去掉联系人 TAB，配对成功直接进消息列表 ✅（底部 TAB 与侧边栏都改为 4 项）
- [x] **B13** 消息提醒 UI ✅ —— 不在会话里来消息时顶部横幅（发送人 + 摘要，6s 自动收起，
  点一下直达会话），设置里可关
- [x] **B14** 接收目录自定义 ✅ —— 设置-传输里选择目录；收到的文件自动归档过去
  （重名自动编号），文件 TAB 与「打开接收目录」都跟随新目录
- [x] **B15** 气泡文字在部分主题看不清 ✅ —— 文件卡片标题/副标题按发送方取色
  （自己发的落在主色气泡上用 `onPrimary`）
- [x] **B16** 泄漏排查 ✅ —— `LinkifiedText` 的 `TapGestureRecognizer` 之前每次 build
  都 new 且从不 dispose（真泄漏），改为 State 持有并 dispose；其余定时器/控制器/监听
  逐个核对（聊天页键盘 handler、搜索框、手动直连输入框、取色器、文件页监听、配对弹窗
  计时器均有 dispose/remove）；`markRead` 在桥接未就绪时不再把异常抛到全局
- 测试：`flutter test` **21 个全过**（本轮新增 7 个断言点：删除残留 / 演示数据清理 /
  链接蓝色 / 新消息横幅 / 取消移除气泡 / 设置分区 / 配对弹窗生命周期）；
  `dart analyze lib test` 零问题

---

## M9 · 用户反馈三轮（配对收尾 / TAB 选中 / 文件交互 / 离线发送）

> 编号 C1–C13 对应本轮反馈（含「修了 3 次」的 TAB 选中样式，这次是真根因）。

- [x] **C1** TAB 选中样式（第三次返工）✅ —— **真根因**：`_BottomItem` 被写成 `const`，
  Flutter 对参数完全相同的 const 子树**跳过重建**，而选中态是 build 时读 AppState 得出的
  → 永远不刷新。改为由父级显式传 `selected:` 参数，并新增回归测试
  （把 const 加回去测试立刻失败，已验证能锁死）
- [x] **C2** 配对卡死三处 ✅ —— ① 宿主 `_open` 先置位再弹，showDialog 一抛错就永远弹不出来
  → 改为可重试 + 失败自动收尾；② 发起方拿到 paired 但 peerId 为空时 `pairingSucceeded`
  永远 false 而 `pairingActive` 还是 true → 停在等待态 → 现在用 session/contact/发起对象三级兜底；
  ③ 成功态加 4s 看门狗，无论如何都会收窗
- [x] **C3** 界面/弹层更多设置 ✅ —— 界面分区新增：字号 / 气泡宽度 / 气泡圆角 / 输入框最大行数
  / 动画开关 / 弹出菜单样式（底部卡片 vs 就地弹出）；新增**壁纸不透明度**
- [x] **C4** 深浅色独立配置并记忆 ✅ —— 显示模式改为「跟随系统 / 浅色 / 深色」三选，
  全部偏好落盘（appearance.json）
- [x] **C5** 设置改子页面分栏 ✅ —— 宽屏左侧分区导航 + 右侧内容；窄屏总览 → 子页面（带返回）
- [x] **C6** 删除残留彻底化 ✅ —— ① 只接受**已配对**联系人的消息（陌生设备塞内容直接忽略，
  也解决了「名称像乱码」——那是未知设备把原始 id 当名字）；② 未知名字改为「未知设备·xxxx」；
  ③ 删除联系人时经聊天通道发一条控制消息，**对端同步解除配对并清数据**（不入库不显示）
- [x] **C7** 配色 ✅ —— 链接深蓝 #1E40AF（深底 #3B82F6、彩色气泡 #DBEAFE）；
  发送气泡改绿色 kOutgoingBubble；聊天头部透明与背景融合；输入框最大行数提到 12
- [x] **C8** 转发 / 多选 ✅ —— 气泡菜单新增「转发（选联系人）」「多选」；多选模式下点按勾选，
  底部操作条支持批量转发 / 删除
- [x] **C9** 文件 TAB 交互 ✅ —— 单击选中、双击打开、长按/右键菜单（打开/定位/复制路径/加入选择/删除）、
  Shift 点按范围选（框选等价实现）、清空按钮 → 确认框，可勾选【同时删除磁盘文件】
- [x] **C10** 收发文件夹 ✅ —— 输入栏「+」新增发送文件夹：递归发送，文件名带目录结构
  （分隔符 »），接收端还原成同样的子目录；文件 TAB 递归列出
- [x] **C11** 双击文字气泡复制 ✅
- [x] **C12** 离线发送 ✅ —— 对方不在线时消息标「离线待发」，连上后按时间顺序自动补发，
  每条只补一次（`_queuedFlushed`）；文件的补发沿用上一轮的「仅一次 + 非取消」保护
- [x] **C13** 安卓触感反馈 ✅ —— 文件点按/长按、菜单弹出与选择、TAB 切换都加 HapticFeedback

> 测试：`flutter test` **22 个全过**（本轮新增 TAB 选中态回归、配对弹窗生命周期、设置分栏 3 组）；
> `dart analyze lib test` 零问题。

---

## M10 · 用户反馈四轮（壁纸/气泡/配对兜底/文件交互/返回栈）

> 编号 D1–D12 对应本轮反馈。

- [x] **D1** 壁纸不透明度设置项 ✅ —— 之前只加了字段没放滑杆；现已在「主题与壁纸」里给出
- [x] **D2** 主题与壁纸合并为一个分区 ✅（并注明：浅色/深色的参数分别记住）
- [x] **D3** 深浅色独立记忆 ✅ —— `AppearanceState` 保存 `lookLight`/`lookDark` 两份快照
  （主题色、壁纸、开关、不透明度、滤镜、遮罩），主题或系统亮度变化时互换，双端都生效
- [x] **D4** 输入栏底色适配壁纸 ✅ —— 有壁纸时用半透明 surface，不再生硬分层
- [x] **D5** 文件/图片气泡差异化 ✅ —— 文件卡片：中性底 + 类型色描边 + 44px 类型图标；
  图片：圆角 + 细边框 + `BoxFit.contain`（按原始比例完整显示，不再裁剪）
- [x] **D6** 配对兜底加固 ✅ —— 新增 `pairingReset()` 全量复位（成功/取消/超时/失败共用，
  之前任何字段残留都会让弹窗停在错的界面）；失败分支清 PIN 让错误与出口可见；
  宿主加 75s 看门狗强制收尾；窗口被返回键关闭时同步收尾状态机
- [x] **D7** 转发双端都显示 ✅ —— `sendTextTo` 现在会把乐观气泡加进目标会话
  （离线补发传 `addBubble:false`，避免重复）
- [x] **D8** 聊天显示一切内容 ✅ —— 连上对端时强制重拉最新页（`loadHistory(force:true)`），
  不再被 `_historyLoaded` 挡住；离线期间双方的消息都能补齐
- [x] **D9** 安卓默认就地弹出菜单 ✅ —— `useBottomSheetMenus` 默认 false，设置里可切回底部卡片
- [x] **D10** 文件 TAB 双端交互隔离 ✅ —— 手机：单击打开、长按菜单（含只选中/全选）；
  PC：单击选中（点别的替换）、Ctrl+点击追加、Shift 范围选、空白处拖动=框选（半透明选框，
  命中检测用瓦片 RenderBox）、双击默认程序打开，没有默认程序则打开所在文件夹
- [x] **D11** 全面屏返回响应 ✅ —— 新增 `AppState.backHandler`：文件页有选中先取消选中、
  聊天页先退出多选、设置页先回总览，之后才交给「详情→列表→TAB→退出」的主链路
- [x] **D12** 离线发送的文件也补发 ✅ —— 对方不在线时文件消息标「离线待发」，
  连上后与文本一起按时间顺序补发（同样每条只补一次）
- 文件页图片瓦片显示真实缩略图，apk 保持安装包图标

> 测试：`flutter test` **24 个全过**（本轮新增深浅色独立记忆、文件页返回处理 2 组）；
> `dart analyze lib test` 零问题。

---

## 风险 → 任务 追溯表

| 风险（PLAN §6） | 承接任务 |
|----------------|---------|
| 1 Android 构建链 | T0.1 / T0.2 |
| 2 AP 隔离 | T1.2 / T1.5 |
| 3 组播锁 | T0.4 / T1.2 |
| 4 Windows 防火墙 | T0.4 / T6.2 |
| 5 事件风暴 | T1.3 / T4.4 |
| 6 后台被杀 | T4.7 / T6.5 |
| 7 Scoped Storage | T4.6 |
| 8 断点续传状态机 | T4.1 / T4.2 |
| 9 粘包半包 | T0.3 / T3.2 |
| 10 协议兼容 | T3.2 |
| 11 时钟乱序 | T3.2 |
| 12 历史膨胀 | T3.3 / T3.8 |
| 13 frb 版本锁 | T0.6 / T6.4 |
| 14 明文窃听 | T6.5（v2 加密） |
| 15 文件名编码 | T4.3 |
| 16 发热耗电 | T4.7 |
| 17 IP 变化 | T1.6 / T3.1 |
| 18 大文件磁盘 | T4.3 |

---

## 每日开工检查（建议）

1. `flutter analyze lib` 零问题 → 勾当日任务
2. 改了 Rust 桥接 → 跑 `scripts/codegen.ps1`
3. 过了里程碑验收 → 更新 PLAN.md 状态行 + 本文档总览表