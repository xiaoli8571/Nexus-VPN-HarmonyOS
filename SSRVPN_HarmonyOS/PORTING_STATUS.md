# SSRVPN HarmonyOS — 移植进度与剩余工作清单

> 本文件是移植工作的进度账本（2026-09-17 更新，见文末「架构与性能改造」一节）。
> **当前状态：HAP 已可完整编译（BUILD SUCCESSFUL，含原生 NAPI）；网络监听、恢复编排与
> 权威状态已下沉到 VpnExtensionAbility，规则/节点/模式支持不重建隧道的热更新，
> 全链路统一 IPv4-only，3s 定周期心跳已改为事件驱动 + 低频存活租约。**
> 继续开发前必须通读本文件和 `SPEC.md`（规格书 §1.4 功能 / §1.5 UI / §4 验收）。

## 构建方法（本机已验证）

```powershell
cd C:\Users\Administrator\Downloads\zcode-worker\SSRVPN-HM\SSRVPN_HarmonyOS
$env:DEVECO_SDK_HOME = 'C:\Program Files\Huawei\DevEco Studio\sdk'
$env:Path = 'C:\Program Files\Huawei\DevEco Studio\jbr\bin;' + $env:Path
& 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat' --mode module -p module=entry@default -p product=default assembleHap --no-daemon
# 产物: entry\build\default\outputs\default\entry-default-unsigned.hap
# 已复制: C:\Users\Administrator\Downloads\zcode-worker\SSRVPN_HarmonyOS.hap (未签名, ~1.6MB)
```

- SDK：本机 DevEco Studio SDK **API 26**（`compatibleSdkVersion: "26.0.0"`，注意新版本号格式不带 `(N)` 括号后缀）
- 签名：HAP 当前未签名，装真机需 AGC 证书 + Profile（手动步骤，见 README_HarmonyOS.md）
- 打包依赖 java：必须把 `DevEco Studio\jbr\bin` 加入 PATH，否则 PackageHap 报 `spawn java ENOENT`

## Mihomo 内核编译（ohos/arm64）

- 方案：**不用 gomobile**（upstream 用 gomobile bind 产出 bionic libc 的 android .so，无法在 OHOS musl 上加载）。
  自写 c-shared 包装层 `mihomo-build/mihomo-<commit>/cshared_main.go`（package main，导出
  SsrvpnInit/SsrvpnStart/SsrvpnStop/SsrvpnIsRunning/SsrvpnVersion/SsrvpnLastError），
  复制 upstream `SSRVPN_Android/native/bridge/bridge.go`（package bridge）到 mihomo 源码 `bridge/` 子目录，
  `GOOS=linux GOARCH=arm64 CGO_ENABLED=1 CC=<OHOS NDK clang --target=aarch64-linux-ohos --sysroot=...>` 编译。
- 本机构建脚本：`C:\Users\Administrator\Downloads\zcode-worker\build_core.ps1`（产物应放 `entry\libs\arm64-v8a\libgojni.so`）
- protect 机制：cshared_main.go 内置 auto-approve 守护（读 pipe fd → 自动 SetProtectResult(true)）。
  **API21/26 核对点**：真机上若出现流量回环，需把该 fd 真正绑定到底层物理网络。
- 注意：本机 8GB 内存，编译 mihomo 峰值内存大，需关闭 DevEco/浏览器等大户，`-p 1` 降低并行度。
- ABI 对齐：`ssrvpn_core_napi.cpp` 的 dlsym 符号已与 cshared_main.go 一致（含 SsrvpnLastError）。
  NAPI startCore 直接收 configPath + tunFd，由 Go 侧读文件。

## 已完成（P0/P1 + UI 1:1 + P2/P3 全部收官，2026-09-06 最终版）

> **2026-09-06 P3 收官**：
> - **YAML 合并引擎** `commons/services/YamlMerger.ets`：移植 subscription_yaml_merger.dart 核心语义
>   （proxies 分节提取与缩进规整、条目切分、内容指纹跨订阅去重、previousYaml 同内容节点保留名称、
>   uniqueProxyName "(n)" 后缀、节点数/单条/字段/输出全部限额）。已接入订阅刷新：Clash YAML 订阅
>   走合并链路（上一轮 YAML 按 subId 缓存于 preferences，512KB 封顶）。已声明简化：dialer-proxy
>   依赖解析未实现（ss/ssr 订阅不含该依赖）；解析面向 flow-map 与块列表两种主流写法。
> - **强制代理站点对话框**：节点选择页顶栏「站点」入口，逐行域名输入 → settings.forceProxySites →
>   下次连接的配置生成生效（DOMAIN-SUFFIX,site,PROXY）。
> - **hypium 单测** `entry/src/ohosTest/ets/test/LogicTest.ets`（12 个用例）：SSR/SS/SIP002/Base64 订阅
>   解析、Clash YAML 提取、配置生成器（IPv4-only/mode/external-controller/GEOIP/MATCH/强制站点）、
>   国家识别、日志脱敏、节点名规整、延迟配色阈值、YAML 合并（去重+名称保留）、URL 校验与脱敏。
>   DevEco 中右键 ohosTest → Run 'LogicTest' 即可执行（本地单测引擎）。
> - **THIRD_PARTY_NOTICES**：补齐 libgojni.so OHOS 构建来源（方式/产物/SHA-256/包装层 ABI/与
>   upstream gomobile 方案差异/对应源码获取方式），GPL-3.0 合规闭环。

> **2026-09-06 P2 收官**：
> - **apiSecret 加密存储**：AssetStoreKit（`asset.add/query`，ALIAS 检索，失败降级偏好并记日志）
> - **连接快照 + 启动自动恢复**：连接成功写入 `{desiredConnected, nodeName}`，断开清除；
>   HomePage 启动时若快照为已连接意图 → 自动重连上次节点（对应 NativeConnectionSnapshot 恢复语义）
> - **内核自动恢复**：存活监控检测内核死亡 → 自动重连（最多 2 次退避），失败则转手动并提示
> - **代理模式**：规则/全局（AppSettings.proxyMode → 配置生成 mode 字段 + 节点选择页 chips 运行时 PATCH /configs）
> - **常驻通知速率**：SsrvpnNotifier（isOngoing，每秒随流量轮询刷新，节流 900ms，授权未开静默降级）
> - **订阅删除撤销条**：删除后 5 秒内可撤销（undoRemove 已有事务快照）
> - **更新检查**：UpdateChecker 查 GitHub latest release，关于对话框"检查更新"按钮接线
> - 注：errorManager 崩溃钩子在本 SDK（API26）的 ErrorObserver 类型不可公开导入，已移除（诊断面板日志仍可用）

> **2026-09-06 UI 大版本更新**：读 upstream 共享 widgets 源码后发现安卓版真实 UI 使用 `SsrvpnUiTokens`
> （深海军蓝渐变背景 + 紫色主色 #8A84FF，`app_theme.dart` 是旧版兼容色已被弃用）。已按 upstream 源码
> **逐组件 1:1 重写**全部页面：
> - `theme/UiTokens.ets`：SsrvpnUiTokens 全量色值/尺寸 + 延迟配色阈值（<180 绿/<350 黄/≥350 或超时红）+ 节点名规整
> - `widgets/SurfaceCard.ets`：SsrvpnSurfaceCard 等价（surface 88% + 白20%描边 + 黑22%投影 blur28/offsetY14）
> - `pages/HomePage.ets`：渐变背景+双辉光、头部（关于/SSRVPN/使用教程）、状态胶囊、166 圆形电源按钮
>   （连接色逻辑+光晕+连接中 LoadingProgress）、当前节点卡（图标盒/旗帜/名称/延迟/chevron）、
>   公网 IPv4 行、浮动底部导航（主页/订阅+版本页脚）、关于/教程自定义对话框
> - `pages/NodeSelectionPage.ets`（新增）：订阅筛选 chips + 节点卡（旗帜/名称/延迟按钮/选中勾）+ 测全部/单测
> - `pages/SubscriptionPage.ets`：添加卡（➕标题+输入框+primaryBlue按钮）、我的订阅+计数徽标+全部刷新、
>   刷新结果条、订阅卡（渐变图标盒/脱敏URL/✎编辑/🗑删除/启用点/相对时间）、空态、删除确认与编辑对话框
> - `pages/NodeEditPage.ets`：新令牌风格表单
> - 批量/单节点延迟测试（LatencyController + ClashApiService.testLatency）
> - 订阅直链节点导入（singleNodeImported 分支）与 updateSubscription 编辑持久化

| 鸿蒙文件 | 对应 upstream 源 | 状态 |
|---|---|---|
| 工程配置全套（app/build-profile/oh-package/hvigor-config/module.json5，权限含 MANAGE_VPN） | — | ✅ 已按 SDK 26 校正，hvigor 校验通过 |
| `ets/theme/AppTheme.ets` | `lib/theme/app_theme.dart` | ✅ 色值逐项照抄 |
| `ets/commons/models/ProxyNode.ets`（SSR/SS 编解码，util.Base64Helper） | proxy_node.dart + ssr/uri parser | ✅ ArkTS 严格模式合规 |
| `ets/commons/models/Subscription.ets` / `AppSettings.ets` / `PublicIpInfo.ets` | 对应 models | ✅ |
| `ets/commons/services/SubscriptionParser.ets` | subscription_parser*.dart | ✅ |
| `ets/commons/services/SubscriptionFetchPolicy.ets`（UA 链，url.URL 校验） | subscription_fetch_policy.dart | ✅ |
| `ets/commons/services/ClashConfigGenerator.ets`（IPv4-only/规则） | clash_config_generator.dart | ✅ |
| `ets/commons/services/ClashApiService.ets`（waitReady/selectNode/testLatency/traffic） | clash_service_* | ✅ |
| `ets/commons/services/SettingsService.ets` / `SubscriptionService.ets`（含撤销 + ManualNodeStore） | 对应 services | ✅ |
| `ets/commons/services/PublicIpService.ets`（含国家策略/旗帜） | public_ip_info_service + node_country_policy | ✅ |
| `ets/commons/services/ConnectionOrchestrator.ets`（写配置→startVpnExtensionAbility→等 API→选节点→监控） | connection_orchestrator 等 | ✅ 真实 API 链路 |
| `ets/core/CoreBridge.ets` + `cpp/ssrvpn_core_napi.cpp` + `cpp/types/` d.ts | native_bridge + Bridge.kt | ✅ 编译通过，import native from 'libssrvpn_core_napi.so' |
| `ets/vpnability/VpnExtensionAbility.ets`（createVpnConnection→create→fd→内核；TASK_KEEPING 长时任务） | SsrvpnVpnService.kt | ✅ 真实 vpnExtension API |
| `ets/pages/HomePage.ets` / `SubscriptionPage.ets` / `NodeEditPage.ets` | 三个页面 | ✅ 编译通过 |
| `ets/widgets/`（GlassContainer@BuilderParam/NodeCard/SubscriptionCard/CountryFlagIcon/DiagnosticsSheet） | widgets | ✅ |
| `ets/widget/ToggleCard.ets` 服务卡片 + form_config.json | VpnTileService | ✅ |
| `resources/`（base/zh_CN/en_US 字符串、图标、main_pages、form_config） | res | ✅ |

## 剩余工作（按此顺序继续，一次性完成）

### P1.5 — 内核链路收尾（最高优先）

1. ~~确认/完成 libgojni.so 编译~~ **✅ 已完成（2026-09-06）**：`entry\libs\arm64-v8a\libgojni.so`（46.5MB，ELF64 AArch64，
   SHA256=9BFF5455…4C0FF，见 libgojni.sha256）。最终 HAP（含内核）48.2MB 已产出：
   `C:\Users\Administrator\Downloads\zcode-worker\SSRVPN_HarmonyOS.hap`。后续改 Go 代码后用
   `scripts\build-ohos-core.ps1` 重编（mihomo 源码在 `..\..\..\mihomo-build\mihomo-7031b75…\`，GOPROXY 必须走 goproxy.cn）。
2. **真机冒烟**：**不要在 module.json5 声明 ohos.permission.MANAGE_VPN**（受限 ACL 权限，声明后安装报
   "权限申请失败，请按ACL签名指导申请受限权限"；已于 2026-09-06 移除，参照 NekoBox4Harmony 已验证做法：
   HarmonyOS 6.x 上 type:"vpn" 的 VpnExtensionAbility 无需该权限，DevEco 自动签名即可安装，
   运行时由系统 VPN 授权弹框管控）。流程：签名 → 安装 → 订阅导入 → 连接 → 验证 Clash API 9090 可达、TUN 流量、断开恢复。
3. **签名交付**：调试用 DevEco 自动签名即可（工程已无受限权限）；对外发布需 AGC 证书/Profile。

### P2 — 功能补全（对照 SPEC §1.4）

4. 完整 YAML 解析/合并（subscription_yaml_merger.dart、bounded_yaml.dart）
5. 批量测延迟 + 结果缓存（home_latency_controller.dart、private_node_latency_policy.dart）
6. apiSecret 加密存储（@ohos.security.asset 或 cryptoFramework AES-GCM，当前明文）
7. 连接快照持久化与重启恢复（NativeConnectionSnapshot/Store/Committer）
8. 开机自启（CommonEventSubscriber 监听开机事件 → 触发连接）
9. 应用分流：按 UID 分流在 OHOS VpnConfig 的能力以真机为准；不支持则转内核规则层方案
10. 设置页 SettingsPage.ets（主题/自启/排除应用/强制代理站点/测延迟 URL）+ main_pages.json 登记
11. 常驻通知速率更新（NotificationUpdatePolicy）
12. 订阅删除 5s 撤销 UI（undoRemove 已实现）
13. 更新检查（update_checker/update_service）
14. 崩溃报告（errorManager.on('error') → 本地日志 + 提示）
15. 启动编排（startup/* 任务图）
16. 内核恢复策略完整移植（core_recovery_policy.dart：重启内核→重建 TUN→重选节点→退避）

### P3 — 质量与合规

17. hypium 单测：SubscriptionParser / ClashConfigGenerator / SubscriptionFetchPolicy / NodeCountryPolicy / LogRedactor
18. THIRD_PARTY_NOTICES.md 补 ohos 构建来源（含 libgojni.sha256）
19. 对照 SPEC §1.5 色值逐项复核 UI；§4 验收清单逐项打勾

## 已知骨架简化（必须移除/替换）

- `VpnExtensionAbility` 的 protect 由 Go 侧 auto-approve（见上），真机需验证回环
- `SettingsService.apiSecret` 明文存储
- HomePage 节点抽屉未按订阅分组（对应 ssrvpn_node_selection_subscription_filter）
- HomePage 诊断抽屉传入 diag: null（固定显示未运行），需接入 orchestrator.diagnostics()
- 服务卡片状态文本未联动 formProvider.updateForm

## 架构与性能改造（2026-09-17，对齐《mihomo VPN 架构与性能优化建议》）

按优化建议完成的一轮结构性改造，八项全部落地并已通过编译与离线自动验证。

### 1. 网络监听与恢复编排下沉 Extension（控制面/数据面解耦）

`VpnExtensionAbility` 在隧道存续期间成为**唯一权威**，UI 进程被系统回收不影响 VPN 数据面：

- `onCreate` 建隧道前先 `startNetworkAuthority()` 订阅网络事件（`NetworkStateWatcher`）。
- `startCoreMonitor()` 每 10s 在 Extension 进程内直接 `coreBridge.isCoreAlive()` 探测内核。
- `scheduleCoreRecovery()` / `recoverCore()`：内核死亡后**就地热重启内核**（保持 TUN 不拆），
  指数退避、单航班门控、上限 `MAX_CORE_RECOVERY_ATTEMPTS`。
- `scheduleTunnelRebuild()` / `rebuildTunnel()`：热恢复耗尽才升级为 TUN 重建，上限
  `MAX_TUNNEL_REBUILDS`，再耗尽转 `leak-blocked`（保持阻断不放行，绝不泄漏）。
- 决策逻辑抽到零依赖纯模块 `commons/services/VpnRecoveryPolicy.ets`，Extension 运行时与
  离线用例共用同一真值源。

### 2. 扩大安全热更新，最小化 VPN/TUN/Core 重建

`ClashApiService` 新增 `putConfigs()` / `reloadFromPath()`（`PUT /configs?force=true`），
`ConnectionOrchestrator` 新增三条不重建隧道的生效路径，失败才回退完整重连：

| 变更类型 | 路径 | 是否重建 TUN |
| --- | --- | --- |
| 代理模式（规则/全局） | `applyProxyMode()` → `PUT /configs {mode}` | 否 |
| 规则 / 强制站点 | `applyRulesChanged()` → 重写 YAML + `reloadFromPath` | 否 |
| 切换节点 | `switchNodeHot()` → `PUT /proxies` | 否 |
| 免代理 / 走代理应用（包名级） | `restartIfConnected()`（VpnConfig 只能在建隧道时下发） | 是 |

页面接线：HomePage / RulesPage / NodeSelectionPage 已改走上述入口，并按
`hot` / `reconnect` / `none` 三态给出准确提示。

### 3. Extension 主导的可靠状态同步

- Extension 写 `vpn_status.json`（`VpnRuntimeStatus`：phase/mtu/netType/coreAlive/
  recoveryAttempts/rebuilds/seq/ts/detail），**事件驱动**、内容去重。
- UI 侧 `TunnelAuthority.parseExtensionStatus()` + `deriveUiPhase()` 纯函数解析并归一
  （`running→connected`、`recovering`/`leak-blocked` 原样、租约过期→`stale`），
  `ConnectionOrchestrator.extensionStatus()` 供冷启动/回收后还原真实状态。
- 断开时 `clearStartError()` 一并清除状态文件，防止读到上一会话的陈旧 `running`。

### 4. IPv4-only 统一

删除 `Ipv6Detector.ets`；Extension 侧 `isIPv6Accepted: false` + 仅 IPv4 地址与默认路由；
YAML 侧 `ipv6: false` / `disable-ipv6: true` / `dns.ipv6: false`，移除 `fake-ip-range6`、
`inet6-address`；want 不再下发 `ipv6Inbound`；诊断面板改为如实显示「统一 IPv4-only」。

### 5. DNS 分流 / fallback / 缓存 与 链路参数

`dns.nameserver-policy` 分流 + `fallback` DoT（`1.1.1.1:853` / `8.8.8.8:853#DIRECT`）+
`cache-algorithm: arc` / `disable-cache: false` / `strategy: prefer_ipv4` + `fake-ip-filter`；
`tcp-concurrent` / `unified-delay` / `keep-alive-idle` / `keep-alive-interval` / `udp-timeout` /
`find-process-mode: off` / `log-level: warning` / `profile.store-*`。
`strict-route` 明确不启用（gvisor 栈无 iptables，OHOS 上不可用）。

### 6. 按承载动态 MTU

`mtuForNetType()`：蜂窝 1360、其余 1400；网络切换导致 MTU 变化时在重建预算内重建 TUN，
并由 `ensureConfigMtu()` 把新 MTU 同步回内核 YAML，避免两侧不一致。

### 7. 移除 3s 定周期心跳 I/O

删除 `startHeartbeat()` / `HEARTBEAT_INTERVAL_MS`；改为「事件驱动写状态文件」+
「10s 内核监控顺带刷新一次存活租约时间戳」（`touchLivenessLease()`）。
UI 的 15s 陈旧窗口判定仍然成立，I/O 从每 3s 降至每 10s 且相位变化即时可见。

### 8. 验证

- `node scripts/verify-vpn-architecture.mjs`：**125 条断言全绿**。可执行部分直接加载
  `VpnRecoveryPolicy.ets` / `TunnelAuthority.ets` 真源码（Node 24 type-stripping），仿真
  后台/锁屏/UI 进程回收、网络切换、内核崩溃、弱网退避、长时间运行、不可恢复收敛；
  另有对配置生成器/Extension/编排器的源码级不变量断言（已明确标注为 SOURCE 断言）。
- `node scripts/verify-logic-pure.mjs` 228 全绿；`verify-latency-cache.mjs` 全绿。
- `entry/src/ohosTest/ets/test/VpnArchTest.ets`：11 个 hypium 用例覆盖同一批纯逻辑，
  已注册进 `List.test.ets`。
- 顺带修复了 ohosTest 模块**从未编译成功**的历史问题（该模块在引入前即已损坏）：
  `OpenHarmonyTestRunner` 按 API 26 契约重写（`TestRunner` 是 interface、无 `run()`），
  `TestAbility` 补上真正的 `Hypium.hypiumTest()` 启动链路（旧代码调用了不存在的
  `delegator.sendState()` 且从未执行用例），`LogicTest.ets` 的 17 处相对路径深度写错
  （多两层 `../`）、`rankNodes` 漏 import、3 处接口用对象字面量实现、
  `assertSmallerOrEqual` 拼错，均已修正。现在 `entry@ohosTest` 也 BUILD SUCCESSFUL。
- 需真机 + 签名包复核的项：真实锁屏/后台保留、Wi-Fi↔蜂窝切换、Core 崩溃自愈、
  弱网吞吐与断流、长时间运行内存与 fd 稳定性。

### 构建（含 ohosTest）

```powershell
# 项目路径含中文会让 hvigor 报 Invalid project path，需镜像到纯 ASCII 目录再构建
robocopy '<本目录>' 'C:\Users\xiaoli\Downloads\Agent-WorkerSpaces\SSRVPN-HarmonyOS-build' `
  /MIR /XD .git entry\build entry\.cxx .hvigor node_modules oh_modules
# ohosTest 需要 hypium：首次在该目录执行 ohpm install --all
& 'C:\Program Files\Huawei\DevEco Studio\tools\ohpm\bin\ohpm.bat' install --all
$env:DEVECO_SDK_HOME = 'C:\Program Files\Huawei\DevEco Studio\sdk'
$env:Path = 'C:\Program Files\Huawei\DevEco Studio\jbr\bin;' + $env:Path
& 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat' --mode module -p module=entry@default  -p product=default assembleHap --no-daemon
& 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat' --mode module -p module=entry@ohosTest -p product=default assembleHap --no-daemon
# 产物: entry\build\default\outputs\default\entry-default-unsigned.hap
```

> 注意：`robocopy /MIR` 会删掉目标目录里源目录没有的东西，务必把 `oh_modules` 加入
> `/XD`，否则每次同步都要重装 hypium 依赖。
