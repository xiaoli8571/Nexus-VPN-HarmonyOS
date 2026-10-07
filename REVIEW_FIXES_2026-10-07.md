# 评审修复记录（2026-10-07）· 对照官方开发手册

> 来源：对 Nexus 的「对照官方开发手册」代码评审（P1 后台任务合规 / P2 安全与正确性 / P3 功耗 / P4 核对项）。
> 本次落地 P1–P3 的全部可代码化项；P4 中需真机验证的项按纪律留档、不盲改（见文末）。
> 分支：`fix/review-2026-10-07`，逐项独立提交，任意单点可 revert。

## 回退指引（先看这里）

| 目标 | 命令 |
|---|---|
| 看本次改了哪些提交 | `git log --oneline review-baseline-2026-10-07..fix/review-2026-10-07` |
| 回到开工前的完整工作树（含当时所有未提交改动） | `git switch fix/review-2026-10-07` 然后 `git reset --hard review-baseline-2026-10-07` |
| 回到 main，并把开工前的未提交改动恢复成"未提交"状态 | `git switch main` 然后 `git stash apply review-baseline-2026-10-07` |
| 只回退某一项 | `git revert <sha>`（P2 拆两个提交：d8ff4d0 与 65370a1） |
| 只回退某文件、保留历史 | `git checkout review-baseline-2026-10-07 -- <文件>` |

- `review-baseline-2026-10-07` 是 `git stash create` 生成的快照（包含 5.8.x 全部未提交改动），tag 指向它、不会被 GC。
- 基线提交 `075cdf9`：把上述快照落成普通提交，便于 diff / cherry-pick。
- 本次提交清单（老→新）：
  - `6a19e45` fix(P1)：长时任务合规 —— 取消监听 / 进度心跳 / 通知点击动作
  - `d8ff4d0` fix(P2)：凭据缓存去明文 + 错误文本残留清零 + 错误码补全 + 权限最小化
  - `8999602` perf(P3)：protect 轮询自适应退避
  - `a9ee87e` test：新增评审修复自检脚本
  - `65370a1` fix(P2)：CredentialStore.ets 入库（此前被 `*credential*` 通配忽略、从未被 git 跟踪）
  - `a4c1f06` test：verify-logic-pure 沙箱补 AppLogger.errText 桩

---

## 一、P1 后台任务合规

### 1.1 长时任务取消监听（用户删除任务通知 = 用户主动停止）

官方依据：《Background Tasks Kit 接入规范》——不得在"用户主动停止（删除长时任务通知等方式）"或"系统取消/暂停"后**立即再次申请**；违规有处罚条款。
官方 API：`backgroundTaskManager.on('continuousTaskCancel')`（API 15+，回调 `ContinuousTaskCancelInfo{id, reason}`）。

改动：
- 新增 `commons/services/BackgroundTaskWatch.ets`：进程级幂等注册；事件到达时 ① 进度心跳止损 ② `UiGuardian.noteExternalCancel()` 清账并进入抑制态 ③ 广播监听者（QuickToggleAbility 清 `bgTaskRegistered`）。**所有路径都不自动重新申请。**
- `EntryAbility.onCreate`、`QuickToggleAbility.onCreate` 各调一次 `ensure()`（同进程幂等）。
- 抑制态 `UiGuardian.autoEngageSuppressed`（进程级）：抑制期内 `engage()` 直接跳过；仅**显式用户操作**可清除——`HomePage.toggleConnection()` / `startConnectionIfNeeded()` / 外部请求消费点、`QuickToggleAbility.onCreate/onNewWant`。

### 1.2 dataTransfer 进度心跳（官方 10 分钟窗口）

官方依据：`startBackgroundRunning` 官方示例——"当长时任务类型包含数据传输(dataTransfer)时，应用需要更新进度"；"进度长时间（首次更新超过 10 分钟）未更新，任务会被取消"；更新方式 = 用申请返回的 `notificationId` 发 `downloadTemplate` **系统实况通知**（`typeCode: 8`、`SlotType.LIVE_VIEW`、`NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW`）。
（评审已核实：LiveViewKit 的 13 个场景不含 VPN，单独走"实况窗场景权益"路线不可行；而 downloadTemplate 通道不需要额外权益。）

改动：新增 `commons/services/TaskProgressUpdater.ets`——
- `attach(notificationId)`：立即推一帧 + 每 5 分钟一帧（10 分钟窗口留一倍冗余）；进度值 = 已连接分钟数 % 100，fileName = `已连接 N 分钟`；
- 失败节流记录、不重试风暴；任务取消 / 断开 / 释放时 `detach()`。
- `UiGuardian.engage()` 与 `QuickToggleAbility.enterGuardian()` 在 `startBackgroundRunning` 成功后接管返回 id。

**编译期踩坑（已修，2026-10-07）**：`startBackgroundRunning` 有四个重载，单值枚举重载 `(context, bgMode: BackgroundMode, wantAgent): Promise<void>` **返回 void**——要拿到任务通知 id 必须用字符串数组重载 `(context, bgModes: string[], wantAgent): Promise<ContinuousTaskNotification>`（官方示例形态）；且 `BackgroundMode.DATA_TRANSFER` 是**数值枚举**（=1），不能用 `as string`，需字面量 `['dataTransfer']`。`verify-card-guard.mjs` 的对应断言已同步为 `['dataTransfer']` 形态。另：`WantAgent` 类型需从 `@kit.AbilityKit` 导入（`wantAgent` 命名空间本身不导出该类型）。

### 1.3 通知点击回前台（官方《连接VPN》指南硬要求）

官方依据："当VPN启动连接时……点击该通知能够将您的 VPN 应用调入前台"；`NotificationRequest.wantAgent` 默认为空 = 点击无动作。

改动：`SsrvpnNotifier` 懒构建并复用 wantAgent（START_ABILITY → EntryAbility）；构建失败只记录、不影响通知发布。

### 1.4 用途口径注释（代码内）

`UiGuardian` 头注释写明：dataTransfer 的规定场景口径、"原定用途需在 AGC 应用介绍中提前声明"、用户可感知/可主动停止边界。

**遗留动作（非代码）**：请在 AGC 应用介绍里补充该后台用途说明（见文末第 1 条）。

---

## 二、P2 安全与正确性

### 2.1 凭据别名缓存去明文

问题：`sealed_alias_cache_json`（preferences `ssrvpn_credentials`）此前持久化 alias→凭据值 的**明文 JSON**，与"凭据只进 AssetStore"的设计红线冲突。

改动（`CredentialStore.ets` + `SubscriptionService.ets`）：
- 持久化只存**别名标记数组**；值一律从 AssetStore 回读（`hydrateKnownAliases`：仅批量查询不可用的固件、每进程一次、分片并发 8）。
- 兼容旧格式：导入时只取 alias、丢弃值；`SubscriptionService.init` 读入后**立即以新格式重写该键**——升级即净化历史明文。
- `rawuri|` 一次性绑定保持原机制（它是 asset 写入失败时的回退源，转存 asset 会自断退路）；修正"绝不落盘"的注释与实际不符的问题（其短暂驻留窗口见 `markNodeSealed` 删除时机）。

### 2.2 Error 实例判断残留清零 + 闸门加严

- 8 处残留（NetworkStateWatcher / ClashApiService / ConcurrentRefresh / LinkHealthChecker / ProxyProviderParser / YamlMerger ×2 / CredentialStore）改为 `AppLogger.errText` 或 BusinessError 感知的本地实现（保持 ConcurrentRefresh / LinkHealthChecker / YamlMerger 的"零 SDK 依赖"自包含性）。
- `verify-config-sanitize.mjs` 的 SOURCE 闸门从"3 个文件 + 精确字符串"升级为**全 app 源码扫描**（`instanceof Error` 零容忍）——等价写法不再漏网。

### 2.3 官方 VPN 错误码补全

`friendlyVpnStartError` 新增 `2200003 / 2203004 / 19900001 / 19900002`（官方错误码表 8 项全覆盖）；`verify-config-sanitize.mjs` 增加对应 EXEC 断言。

### 2.4 权限最小化

`module.json5` 移除 `GET_BUNDLE_INFO`（唯一消费方 `AppInfo` 用 `getBundleInfoForSelfSync`，官方未标注需要权限）。回退：把该行加回即可。

---

## 三、P3 功耗：protect 轮询自适应退避

原实现固定 10ms（100Hz）空转 → 改为 `setTimeout` 自适应链：命中请求立即回 10ms 底线；空闲 10→20→…→100ms 封顶。新请求最大多等一个退避窗口（≤100ms）≪ Go 侧 800ms 回执预算；回执/fail-open/批量排空（16）语义不变。官方口径：后台进程 CPU 配额 / 长时任务"典型负载"管控。

---

## 四、验证与基线对照

新增 `tools/verify-review-fixes-2026-10-07.mjs`（9 项不变量）→ **9/9 通过**。

全量自检对照（修改后 → 与基线快照逐一比对）：

| 脚本 | 结果 | 与基线 |
|---|---|---|
| verify-vpn-architecture | 236/236 | 一致（全过） |
| verify-hot-recovery | 8/8 | 一致（全过） |
| verify-card-guard | 8/8 | 一致（全过） |
| verify-logic-pure | 228/228 | 修复了桩缺失后与基线一致 |
| verify-latency-cache / latency-engine-runtime / smart-e2e / proxy-name-uniqueness / node-sort-persistence / mihomo-alignment / yaml_compat / yaml_flow_parser / sub-node-two-row / sub-brace-balance / smart-active-chains | 全过 | 一致 |
| verify-config-sanitize | 21 通过 / 4 失败 | **4 项失败基线同样存在**（WIP 漂移；本次+1 通过） |
| verify-app-routing | 7 fail | 基线同 7（CRLF 字面量） |
| verify-concurrent-refresh / verify-types | 失败 | 基线同样失败 |
| verify-site-routing | 1 fail | 基线同 |
| verify_subscription_import_regressions | 1 fail | 基线同（SubscriptionPage 漂移） |
| verify-shipped-dns-fix / verify_local_yaml_production_path / verify-subscription-fidelity | 需参数/fixture，未跑 | — |

Debug 构建（hvigor `assembleHap`，buildMode=debug）：**结果见下方「构建结论」小节。**

> 基线对照方法：`git worktree add <tmp> 075cdf9` 后在同一批脚本上运行原始树并逐项比对（对照完成后已移除工作树，快照仍在 tag 里）。

---

## 五、需要你后续处理的（代码之外 / 需真机验证）

1. **AGC 应用介绍**：补充 dataTransfer 后台用途声明（口径："用户主动开启的持续数据传输（VPN 隧道），用户可随时停止"）。
2. **>10 分钟后台驻留实验**：连接后退后台 ≥15 分钟，确认任务通知仍在（进度心跳生效）、隧道未死；失败则查 `TaskProgressUpdater progress update failed` 日志与任务是否被系统取消。
3. **"用户删除任务通知"体验实验**：删除长时任务通知 → 日志应出现 `continuousTaskCancel`、不再自动重挂；再点连接按钮 → 恢复正常挂载。
4. **gateway `'0.0.0.0'` 对齐**（VpnExtensionAbility 默认路由，官方示例用空串）：当前线上可用，属低风险核对项，建议真机 A/B 后再动。
5. **`isBlocking`（平台阻塞模式）**：官方字段语义未展开；可实验验证是否能作 Kill Switch 的补充。
6. **CredentialStore.ets 入库**：此前被 `.gitignore` 的 `*credential*` 通配吞掉（Windows `core.ignorecase`），从未进过任何提交——fresh clone 缺该文件无法构建。本次已入库并加例外注释；如确有意不追踪，用 `git rm --cached <path>` 撤销。
7. **既有断言漂移**（verify-config-sanitize 4 项、app-routing 7 项、site-routing 1 项、subscription_import_regressions 1 项、types/concurrent-refresh）：建议另开一次"断言卫生"会话统一修，本次未动以免与功能修复混淆。
8. **rawuri 一次性绑定的明文窗口**：如要彻底消除需重构"asset 写失败回退链"，超出本次范围。

---

## 构建结论

**构建通过**：`hvigor --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap` → `BUILD SUCCESSFUL`（55 s）。
产物：`Nexus_HarmonyOS/entry/build/default/outputs/default/entry-default-unsigned.hap`（≈29.9 MB，2026-10-07 11:13）。

首轮构建曾暴露 5 个 ArkTS 严格模式错误（全部属于新代码的类型问题：`startBackgroundRunning` 重载返回类型 / `WantAgent` 类型导入 / 枚举-字符串），修复方式见 §1.2「编译期踩坑」。修复后复建通过；未新增任何编译错误（既有 WARN 与本次无关）。
