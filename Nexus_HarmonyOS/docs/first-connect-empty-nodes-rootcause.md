# 首连失败根因分析：`loaded 1 subscriptions, 0 nodes, 0 proxy groups`

> 用户报告（5.5.7，2026-09-19T08:06Z）：「应用启动后点连接报错，提示内核启动卡在联网下载」。
> 本文是对该报告的根因定论，供 5.6.x 修复使用。

## 一、现象与时间线（用户日志，UTC）

```text
08:06:35.517  credential migration done: 0 node(s) / 0 sub credential(s) moved to asset store
08:06:35.521  loaded 1 subscriptions, 0 nodes, 0 proxy groups      ← 关键：节点数为 0
08:06:46.092  config written: .../mihomo_config.yaml (1861 bytes)   ← 1861 字节 = 空壳配置
08:07:06.273  connect failed: 内核启动超时（20s 无响应）             ← 差值 20.18s
08:07:06.289  [health] report overall=broken pass=3 fail=2 skip=5 firstFail=core
08:07:06.289  [health] repair steps(max=2)=restart-core > restart-clash-api
08:07:06.299  disconnected
```

`20.18s` 与 `CORE_START_TIMEOUT_MS = 20000`（`VpnExtensionAbility.ets:73`）**逐毫秒吻合**，
即报错来自 `startCoreWithTimeout()` 的硬超时，不是内核自己吐的错误。

## 二、根因

**不是**「规则集/数据库缺失导致内核联网下载」——那句文案是**猜测**，5.5.7 已经做过降级
（`isRuleProviderReady()` + geoip statSync），设备上 `geoip.metadb`(8.5MB) 与
`ruleset/hyper_adrules_ads.mrs`(1.25MB) 都在。

真正的原因是一条**三段的因果链**：

### 1. 用户是全新安装，节点为空
`loaded 1 subscriptions, 0 nodes, 0 proxy groups` —— 只有 1 条订阅且节点为 0
（该用户的订阅在 16:39/16:40 才拉取成功，晚于这次连接）。1861 字节的配置就是
「无节点」的空壳。

### 2. 空节点配置让内核卡在启动路径
mihomo 的 `Start initial configuration` 在**完全没有可用 outbound**时会长时间无响应。
设备后来的正常启动日志显示同一颗内核对 41KB / 128 代理的正常配置只需
**58ms**（`Initial configuration complete, total time: 58ms`）——所以 20s 不是性能问题，
是空配置下的阻塞。

### 3. 应用把「内核 20s 无响应」直接翻译成「请去补齐规则集」
`startCoreWithTimeout()` 在任何超时情况下都抛出同一句带因果断言的文案
（"配置引用的远程规则集或数据库缺失时，内核会在启动阶段联网下载而长期阻塞"），
`VpnRecoveryPolicy.friendlyVpnStartError()` 再把它润色成「请等 10 秒后再点一次连接」。
**用户被指向了完全不相关的方向**，而且"再点一次"在订阅未拉取前必然同样失败。

### 为什么"全新安装"这个组合能踩中
```text
全新安装 → 无订阅/订阅未拉取 → nodes = 0
        → ClashConfigGenerator.generate() 生成 1861B 空壳配置
        → connect() 里只有「单个节点无效」的降级（找第一个有效节点 / 自动刷新订阅），
          没有「一个节点都没有」的前置拦截 → 照样拉起 VPN 扩展
        → 内核 20s 不响应 → 报"规则集缺失，请重试"
```
`connect()` 的自动刷新补偿（`ConnectionOrchestrator.ets:2152-2175`）只在
**"有节点但都无效"**时触发；**"压根没有节点"**时 `subs.nodes.find()` 返回 null 走
`retry === null` 分支抛错——但这条分支的触发前提是 `!isValidNode(node)`，而首连时
调用方传入的 `node` 本身也可能为空/无效，实际未拦住拉起扩展。

## 三、修复方向（建议，未实施）

1. **前置拦截**：`connect()` 开头加硬门禁 —— `subs.nodes.length === 0` 时
   **立即**返回并提示「没有可用节点，请先到「订阅」页添加/刷新订阅」，
   绝不拉起 VPN 扩展、绝不进入 20s 等待。
2. **区分超时原因**：`startCoreWithTimeout()` 超时时不要断言原因。改为把
   「配置里的 proxies 数量」一并写入 start-error，让 UI 能报
   「内核启动无响应（配置含 N 个节点）」；N=0 时直接指向订阅问题。
3. **首连自动拉取**：若 `nodes.length === 0` 但存在启用中的订阅，先
   `refreshSubscription()` 再判断，把"首连必须先手动刷新"变成自动。
4. **文案去猜测化**：`VpnRecoveryPolicy` 里那句"卡在联网下载"应改成中性表述 +
   实际的节点数/规则集状态，避免把用户引向错误方向。

## 四、附带发现（与本报告无关但值得记）

- 设备上同时装着 `com.shadohos.proxy` 与 `com.nexlink.proxy` 两个代理应用，
  且都在运行。HarmonyOS 同一时刻只允许一个 VPN 生效 —— 排查"连不上"时必须先排除
  第三方 VPN 抢占；`detectForeignControllerBusy()`(2412) 已能识别端口被占的情形。
- 设备的 `vpn_heartbeat.txt` 在 16:37:37 后停止刷新且 `:vpn` 进程消失，说明
  那次隧道确实掉线了；不能把用户报告与"内核一跑就崩"混为一谈，两者需要分别取证。
