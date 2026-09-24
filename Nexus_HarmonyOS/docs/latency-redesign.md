# 延迟测试重做 · 设计说明（5.6.0）

> 结论先行：延迟测试从「页面自己开 10 路 lane + 未连接时另起一个无头内核 + 整批级 URL
> 降级」重做为**单一引擎**（`LatencyEngine`）+ **显式五态以上状态机**
> （`LatencyState`）+ **可取消的确定性进度**。测速结果不再是 `Map<string, number>`
> 加哨兵值，而是带时间戳与通道来源的记录。

## 一、旧实现为什么"难用"

| # | 现象 | 根因 |
|---|---|---|
| 1 | 点「测全部」半天不出第一个数字 | 未连接时要先拉起**第二个** VpnExtensionAbility 内核：DoH 预解析 → 停旧扩展 → 600ms 等待 → 启新扩展 → 健康轮询（20s 超时） |
| 2 | 全列表"超时"（真机 143 节点） | 两个内核共用 9090 端口但 secret 不同，凭证被覆盖后全部 401；旧实现把 401 也归入"超时" |
| 3 | 点了像没反应 | 命中"10s 内测速缓存"直接返回"无需重新测速"，无任何提示 |
| 4 | 好节点被写成超时 | 队列等待与探测**共用一份超时预算**，排在饱和 lane 后面的节点被前面的耗时吃掉 |
| 5 | 死节点排最前 / 显示 `0ms` | `history.delay == 0` 是**失败**语义，被当数字参与升序排序 |
| 6 | 没测过却显示"超时" | 只有 `-1/-2` 两个哨兵，UI 无法区分未测/超时/失败/取消 |
| 7 | 结果永远是几分钟前的 | 没有时间戳，无法表达新鲜度 |
| 8 | 无法中止 | 没有取消入口；且旧实现自己也说不清"取消"算什么状态 |
| 9 | 后台静默测速与手动测速互相打断 | 两套独立管线（`BackgroundLatencyService` vs 页面 `runBatch`）+ 手动优先级抢占 + 代次校验 |

## 二、实测得到的关键事实

全部来自真机（MLR-AL00 / API 24，mihomo 1.10.0）与 mihomo 源码交叉验证，
详见 [`mihomo-delay-api-contract.md`](./mihomo-delay-api-contract.md)。

1. `GET /proxies/{name}/delay?url=&timeout=` → `200 {"delay":N}`（N≥1）；
   强制超时 `504 {"message":"Timeout"}`；未知节点 `404`；内建项 `503`；
   `timeout` 按 **16 位**解析（>32767 → 400），且**必须显式传**（不传 400）。
2. `GET /group/{name}/delay` **能用但是陷阱**：对 url-test 系组忽略传入 `url`、
   对非 Selector 组 `ForceSet("")` 清掉用户固定选择、无并发上限（每节点一 goroutine）、
   失败节点从结果 map 里**静默消失**，且可能返回 `200` + **部分**结果。
   → **本实现完全不用它**（套件里有负向断言）。
3. `(*Proxy).URLTest` 直接 `p.DialContext` 到出站适配器，**绕过 TUN 与规则引擎**
   → 只要内核已加载，测速与"VPN 是否连接"无关。
4. **已连接时隧道的 controller 就带着全部真实节点**（实测 128 条目 = 106 真实节点
   + 16 组 + 内建；全部在 `PROXY` 组内）→ 直接复用，零额外启动。
5. `history[last].delay == 0` 表示**失败**；`LastDelayForTestUrl` 用 `65535` 表示
   "没测过"。**两者都不是有效延迟**。
6. **取消不释放内核 socket**：`getProxyDelay` 用 `context.Background()`，abort 只是
   客户端行为，内核会继续拨号到自己的 timeout → 并发上限是控制负载的唯一手段。
7. `unified-delay` 下 `http://` 测速 URL 在劫持型代理里会失败（mihomo 官方警告）
   → 统一 HTTPS。

## 三、新架构

```
                      ┌─────────────────────────────────────────────┐
   已连接 ────────────► ① 复用隧道内核 controller（带全部真实节点）
                      │    零额外启动、零额外内存                    │
   未连接 ────────────► ② headless 测速内核（无 TUN，独立 secret）    │
                      │    mihomo 探测绕过 TUN，故能得到**真实**延迟  │
   内核不可用 ────────► ③ 离线直连探测（TCP/TLS/QUIC）                │
                      │    UI 显示 ≈123ms，只代表"服务器可达"         │
                      └─────────────────────────────────────────────┘
                                      │
                            LatencyEngine（唯一入口）
        · 有界并发 8（移动端，取主流客户端 5~16 的下沿；内核侧无上限，客户端必须自律）
        · 队列等待与探测计时**分离**（单节点预算 5000ms，不跨节点累计）
        · 首批请求错峰抖动 0~200ms，避免整批同时撞内核
        · 整批硬截止 90s：到点未完成的节点保持**未测**，绝不写失败
        · 单航班：新批次自动作废旧批次，旧回调丢弃结果
        · 进度：确定性 finished/total + 取消
```

**与初版设计的偏差（实现时修正，记录以免误导后来者）**：

- 初版想连"无头测速内核"一起删掉。**没有删**：mihomo 的探测需要**已加载的内核**
  才能拨出站适配器，未连接时若不启内核就只能给"离线粗略值"，而"未连接也要能测出
  真实延迟"是这次重做的核心诉求。因此保留内核，但把它收进 `ensureLatencyApi()`
  统一决策（已连接复用隧道 → 未连接起 headless → 都不行才降级），页面不再直接碰它。
- `TestCoreFlight` 单航班状态机与 90s 宽限回收**保留**（既有实现是可靠的、被
  LogicTest 覆盖的）。回收改为**由引擎在每批结束后挂起**，并在
  `scheduleTestCoreRecycle()` 里加了硬安全闸：`CONNECTED/CONNECTING/DISCONNECTING/
  RECOVERING` 四态直接拒绝回收 —— 因为测速内核与真实隧道**共用同一个
  VpnExtensionAbility 进程**，一次误回收就会把用户正在用的 VPN 停掉。
- 真正**删除**的是页面里那套 700 行并行管线（lane 池、整批级 URL 降级、通道熔断、
  整批零成功判定、负缓存、代次校验、directReachableNames）与
  `BackgroundLatencyService` 里第二套并行实现 + 手动/后台抢占机制。

## 四、状态语义（UI 必须可区分）

| 状态 | 含义 | 触发 |
|---|---|---|
| `MEASURED` | 实测代理延迟 N ms | `200 {"delay":N}`，N ≥ 1 |
| `TIMEOUT` | 内核侧超时 | `504 {"message":"Timeout"}` |
| `FAILED` | 探测失败（拨号失败/状态码不符/`delay==0`） | `503` |
| `CANCELLED` | 用户取消/网络切换中断，**不是节点结论** | 客户端 abort |
| `OFFLINE` | 离线粗略可达性（≈N ms），**不是代理延迟** | 兜底通道 |
| `TESTING` | 测试中（UI 显示 spinner） | 探测在途 |
| `UNTESTED` | 从未测过 | 初始态 |

外加 `atMs` 时间戳（>10 分钟灰显为"旧"）。状态必须**一路带到 UI / 日志 / 持久化**，
禁止把 `FAILED` 折叠成"超时"、禁止把通道不可用折叠成"超时"。

## 五、UI 规范（实现口径）

- **徽标**：`123ms` / `≈123ms`（离线）/ `超时` / `失败` / `--`（未测）/ spinner（测试中）。
- **配色**：沿用 `LatencyStyle` 既有阈值（`<180` 绿 / `<350` 琥珀 / 其余红）——
  这三个阈值被 `ohosTest/LogicTest.ets` 断言，本次**不动**；过期结果用次级文字色灰显。
- **排序**：实测升序 → 离线 → 未测/已取消 → 超时 → 失败。**失败永不排最前**
  （CMFA 的朴素升序把死节点顶到最上，是公认痛点）。
- **进度**：顶栏确定性 `finished/total` + **取消按钮**（旧实现没有取消）。
- **过滤**：只测真实出站节点，排除组类型（`Selector/URLTest/Fallback/LoadBalance/
  Relay`）与内建项（`DIRECT/REJECT/REJECT-DROP/COMPATIBLE/PASS/PASS-RULE/DNS`）。
  本项目 `PROXY.all` 里混着 14 个组条目，不过滤会把"组当前选择的那个节点"的延迟
  张冠李戴到组上。
- **测全部** = 当前筛选（订阅 chip）后的节点列表，且**总是强制重测**
  （修掉旧版"命中缓存所以什么都不做"）。
- **自动测速**：进页面时跑一次 `force=false` 的批次（跳过 5 分钟内的新鲜结果，
  计为 `skipped`），冷启动由 `BackgroundLatencyService.scheduleStartup` 静默补齐一次；
  两者都不弹提示、不阻塞渲染。
- **结果持久化**跨重启 + 显示新鲜度（主流客户端普遍不做，是我们的差异点）。

## 六、验证

- `scripts/test-latency-engine.js`（取代已删除的 `test-latency-pipeline.js`）：
  源码级接线与**旧缺陷不许复活**的负向断言 —— 唯一入口、禁止 `/group/*/delay`、
  未连接路径必须经 `ensureLatencyApi`、HTTPS URL、并发上限、`timeout` 显式且 ≤32767、
  硬截止不写失败、取消≠失败、通道不可用≠节点失败、组条目过滤、回收安全闸、
  生成器逐字节未变（指纹 `scripts/latency-gen-fingerprint.json`）。
- `scripts/verify-latency-cache.mjs`：把 `LatencyState.ets` / `LatencyController.ets`
  按 `.ts` 暂存后在 Node 里**真实驱动**（45 项）—— 五态迁移、`0ms` 不是延迟、
  `65535` 不是延迟、排序、组过滤、`retainOnly`。
  （Node 的 type-stripping 只接受可擦除语法，故 `LatencyState` 用 class +
  static readonly 而非 `enum`。）
- 真机实证：已连接（隧道 controller）与未连接（headless 内核）各测一轮，
  记录 106 节点的完成耗时与各状态分布。
