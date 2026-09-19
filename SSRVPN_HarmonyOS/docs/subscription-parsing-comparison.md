# 订阅解析：本 App vs 主流 mihomo 客户端（对比与改造判断）

> 结论先行：**解析层不需要推倒重来。** 用真实订阅实测，本 App 的解析结果是
> **43/43 节点、0 丢失、0 虚构、type 全对、凭据全在**，且已有一套 40 用例 / 96 标签的
> 「跑真源码」语料测试全绿。用户体感到的"解析问题特别多"，主因**不在解析**，而在
> **拉取失败后静默变成 0 节点、且界面不告诉用户为什么**（实测复现，见 §1）。
> 真正值得改的是**失败可见性**和**评测基线**，而不是重写解析器。

---

## 1. 先复现用户报的那个错（这是"问题特别多"的真实来源）

订阅 `https://dorocloud.xyz/s/716f…（订阅链接已脱敏）` 导入失败，真机实测：

```
17:48:04 SubscriptionService: subscription added: 订阅 4
17:48:19 SubscriptionFetchPolicy: subscription fetch attempt failed: code=2300028 Operation timeout
17:48:34 … (第二条 UA)  17:48:49 …  17:49:04 …  17:49:19 …
订阅 4 卡片：0 节点 / 未更新 / 流量 未知   ← 界面上没有任何错误提示
落库：lastRefreshResult = "networkError", nodeCount = 0, lastFetchedAt = 0
```

**根因不是解析，是网络：该域名直连的 TLS 握手被重置。** 三处独立证据：

| 位置 | 命令 | 结果 |
|---|---|---|
| 本机直连 | `curl -v` | `Trying [2606:4700:3032::ac43:bc50]:443` → `Recv failure: Connection was reset`（ClientHello 被 RST） |
| 本机走代理 | `curl -x 127.0.0.1:7897` | **200**，24392 B，`text/yaml` |
| 真机直连 | `openssl s_client -connect dorocloud.xyz:443 -servername …` | `CONNECTED` → `write:errno=104` → `SSL handshake has read 0 bytes and written 325 bytes` |

即 **TCP 连得上、ClientHello 发得出去、然后被重置** = 典型的 SNI 阻断。
用户在电脑上"Clash Verge 拉取正常"，是因为当时的流量走了代理。**用户自己也确认了"被墙了，开代理就可以了"。**

所以这一条：**拉取层问题，不是解析层问题。** 但它暴露了一个真问题 ——

### 1.1 真问题：失败被静默吞掉

`SubscriptionFetchErrorKind` 里有 `NETWORK` / `EMPTY_RESPONSE` / `HTTP` / `DECODE`
等分类，`lastRefreshResult` 也如实写了 `networkError`，**但卡片上不显示**：
用户看到的是 `0 节点 / 未更新 / 流量 未知` —— 和"这个订阅本来就是空的"完全无法区分。
5 个 UA × 15 s 超时 = 用户干等 75 秒，最后什么都没得到、也没有任何解释。

对照主流客户端（研究结论 §失败策略）：它们确实是"逐节点静默丢弃 + 整体为空才大声报错"，
**但整体为空时它们会明确报错**（mihomo：`convert v2ray subscribe error: format invalid`）。
本 App 连这个都没有。

---

## 2. 解析层对比（用户真正问的）

### 2.1 各家"谁来解析"

| | mihomo 核心 | Clash Verge Rev | FlClash | ClashMetaForAndroid | NekoBox / sing-box | **本 App** |
|---|---|---|---|---|---|---|
| App 语言里有解析器？ | —（核心自己就是） | **有，Rust** | 无（vendored mihomo） | **完全没有** | **有，Kotlin** | **有，ArkTS ~250 KB** |
| 顶层接受什么格式 | Clash YAML / 链接列表 / base64 | **只有 Clash YAML** | **只有 Clash YAML** | **只有 Clash YAML** | Clash YAML / sing-box JSON / WG conf / 链接列表 | **Clash YAML / 链接列表 / base64 / ssr / 单链接** |
| 下载由谁做 | provider 的 http type | reqwest（20s） | Dart dio（**走代理**） | **核心自己做**（60s） | 自己 | 自己（http，15s×5） |
| sing-box JSON | ✗ | ✗ | ✗ | ✗ | **✓** | ✗ |
| Quantumult X | ✗ | ✗ | ✗ | ✗ | 仅 Userinfo 头 | ✗ |
| Surge / LOON | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| 逐节点诊断 | **无** | 无 | 无 | 无 | 无 | **有**（`SubscriptionParseDiagnostics`） |
| 未知/新协议 | 映射透传 | YAML 原样 | 映射透传 | YAML 原样 | JSON 原样 | **extraOpts 透传** |

**关键事实：主流客户端里只有 2/5 自己做解析（Verge Rev 用 Rust、NekoBox 用 Kotlin），
其余 3 家直接把活交给核心。** 本 App 属于"自己做解析"的那一类 —— 这是**架构选择差异，
不是缺陷**：HarmonyOS 上要挂 mihomo 做 proxy-provider 远程拉取，还要处理"订阅内容要
在 UI 里展示/编辑/排序"，自己做解析是合理的。

### 2.2 支持格式：本 App 覆盖面**不低于**主流

- mihomo 核心**不认** sing-box JSON / Quantumult X / Surge / LOON ——
  本 App 不认这些**完全对齐核心行为**（不是短板）。
- 链接 scheme：mihomo 支持 `hysteria / hysteria2 / hy2 / tuic / trojan / vless / vmess /
  ss / ssr / socks* / http(s) / anytls / mieru`；本 App 的 `ProxyNode` 里同样覆盖
  `hysteria2:// / tuic:// / anytls:// / mieru / wireguard`（源码可查）。
- UA 链 `clash-verge/v1.7.7 → clash.meta/v1.18.8 → SSRVPN/x → v2rayN/6.23 →
  Shadowrocket/2077` 与主流一致，**优先 Clash UA** 让面板直接返回 YAML —— 这正是
  Verge Rev（`clash-verge/v{version}`）和 CMFA（`ClashMetaForAndroid/<version>`）的做法。

### 2.3 实测：真订阅零丢失

我用真订阅跑了**真解析器**（新套件 `scripts/verify-subscription-fidelity.mjs`，
与 mihomo 口径逐节点对账）：

```
fixture: dorocloud YAML (22648 bytes)
mihomo baseline: 43 nodes, 3 groups    type mix: {anytls:21, ss:8, hysteria2:5, trojan:9}
app parsed:      43 nodes, 3 groups
diagnostics: {inputCount:43, duplicateCount:0, invalidCount:0, unsupportedCount:0}
16 passed, 0 failed
```

覆盖：节点数不丢不多、**逐节点 type 与 mihomo 一致**、server/port 齐全、凭据可达、
`skip-cert-verify` 保真、非节点条目（select/url/fallback）不被当节点、名称不串位、
无重复计数、proxy-groups 不丢、诊断字段自洽。

### 2.4 本 App 已有的评测基线（比多数客户端都厚）

- `tools/true-parser-harness/corpus_runner.mjs` —— **40 用例 / 96 标签，全绿**，
  且是**跑真实 `YamlMerger.ets` 源码**（不是重新实现一遍解析逻辑）：
  锚点/别名链/递归锚点限深、`<<` 嵌套深链、`dialer-proxy` 缺失与成环、字段 64KB /
  节点 128KB / 全局限额、flow-map、跨文档、BOM/CRLF、emoji、裸 IPv6、promo-node、
  `same-hostport-diff-path`、`name-in-fingerprint` 去重……
- `tools/verify_yaml_flow_parser.mjs`（flow 语法 7 例）、`tools/verify_yaml_compat.mjs`
  （13 协议）、`tools/verify_subscription_import_regressions.mjs`（URL/local-YAML/
  link-text/base64/base64url/BOM/CRLF/emoji/percent/IPv6/混合/重复/同名/未知/空/限额/
  批量/错误边界）—— 全绿。

对比：研究里明确写着 **"No per-node diagnostics exist anywhere"**（主流客户端都没有逐节点
诊断），而本 App 有。**这一层本 App 是领先的，不该动。**

### 2.5 一个**真实**的设计差异（要理解，不是要改）

本 App 的节点有**两个**类型字段，实测确认是刻意的：

```
anytls 节点实测： proxyType = "anytls"   （原文协议，永远保真）
                  type      = "unknown"  （ProxyNodeType 枚举，只有结构化协议才填）
                  password  = ""         （结构化槽位空）
                  servername= ""
                  extraOpts = [["password","f56a…"],["udp","true"],
                               ["sni","buylite.music.apple.com"],["skip-cert-verify","true"]]
```

中继协议（tuic / hysteria / anytls / naive / shadowtls / wireguard…）**没有结构化槽位**，
除 name/type/server/port 外**全部原样进 `extraOpts`**，生成配置时由
`ClashConfigGenerator` 回写（L873-900 "extraOpts 中继"）。消费层一律**优先 `proxyType`**
（`LatencyPolicy.isTestableType`、`NodeProtocolPolicy.resolve` 都做了兜底）。

**效果**：未知/未来协议天然透传、不丢字段 —— 这与 mihomo 的 `override`
"emit mappings not typed structs"、Verge Rev 的 YAML 原样保留是**同一个思路**。
代价是结构化槽位为空，**任何只看 `node.password`/`node.type` 的新代码都会踩坑**
（我的第一版断言就误报了 21 个"丢凭据"，查证后确认数据其实都在 `extraOpts` 里）。

### 2.6 值得补的对齐点（研究给的、我们缺的）

1. **hysteria2 端口跳跃**（`host:1000-2000`）：`url.Parse` 会把非数字端口当非法。
2. **`fp` vs `pcs` 是两个不同字段**（`fp`→`client-fingerprint` 默认 `"chrome"`；
   `pcs`→`fingerprint`，hysteria2 的证书指纹）—— 本 App 把两者都塞进
   `clientFingerprint`（`YamlMerger` L1986-1989），**有串味风险**。
3. **ws `ed` → `max-early-data` + 同时删掉 path 里的 `ed`**；`httpupgrade` 语义不同。
4. **重复节点名在 Clash 里是致命的**（核心会自己改成 `name-01`）—— 本 App 有
   `dedupName`，但要确认生成配置时不会给核心送去重名。
5. **ETag / If-None-Match 增量拉取**：本 App 每次都整包拉，主流会带 ETag 省流量。
6. **拉取走代理**：FlClash 明确用 `findProxy` 让订阅下载**穿过代理**。本 App 目前
   只在隧道已连接时才能经 TUN 回源（`validateResolvedTarget` 的注释里有说明），
   **未连接 + 被墙 = 必然失败**，这正是用户这次的遭遇。

---

## 3. 改造判断（回答"有没有必要重新改造"）

**解析层：不需要重做。** 理由是实测数据，不是感觉：

| 维度 | 现状 | 结论 |
|---|---|---|
| 真订阅零丢失 | 43/43，type 全对 | 解析正确性**已达标** |
| 边界覆盖 | 40 用例/96 标签全绿（跑真源码） | 健壮性**已达标** |
| 协议保真 | 结构化槽位 + extraOpts 透传 | **优于**逐节点丢弃的主流做法 |
| 逐节点诊断 | 有（主流都没有） | **领先** |
| 支持格式 | 对齐 mihomo 核心 | **无短板** |

**该改的是这三件（都不动解析内核）：**

1. **拉取失败必须可见**（最高优先，这就是用户这次报的错）
   现在 `0 节点 / 未更新 / 流量 未知` 与"订阅本就为空"无法区分。
   要按 `lastRefreshResult` / `SubscriptionFetchErrorKind` 在卡片上显示具体原因，
   并给出可操作建议（"直连被阻断，请先连接 VPN 或换用可直连的订阅地址"）。
   顺带修 75 秒静默等待：UA 链全部超时后应尽早给结论。
2. **补真实订阅回归基线**（已做，本次新增）
   `scripts/verify-subscription-fidelity.mjs` 把真订阅喂真解析器、与 mihomo 口径对账，
   并支持 `SKIP`（无 fixture 不算失败）。这是从"合成 fixture"到"真订阅对账"的补齐。
3. **补 §2.6 的对齐点**，优先 `fp`/`pcs` 串味（会影响 hysteria2 能否连上）与
   hysteria2 端口跳跃；再评估 ETag 与"未连接时如何拉被墙订阅"。

---

## 4. 复现方式

```powershell
# 解析保真度（需要真 YAML；不带参数则 SKIP）
node scripts/verify-subscription-fidelity.mjs <real-subscription.yaml>

# 既有解析基线
node tools/true-parser-harness/corpus_runner.mjs     # 40 用例 / 96 标签
node tools/verify_yaml_flow_parser.mjs
node tools/verify_yaml_compat.mjs
node tools/verify_subscription_import_regressions.mjs
```

研究全文（含每个结论的一手 URL）：`subscription-parsing-research.md` /
`subscription-parsing-research-full.md`（工作区根目录）。
