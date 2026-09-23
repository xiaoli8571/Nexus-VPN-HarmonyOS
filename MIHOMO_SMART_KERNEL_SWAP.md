# 内核替换记录：zeyugao/mihomo@7031b75 → lux5am/mihomo-smart

**日期**：2026-09-19
**范围**：仅 `SSRVPN-HarmonyOS-mihomo-smart` 工作副本；`SSRVPN-HarmonyOS` 未改动。
**目标**：把 SSRVPN HarmonyOS 捆绑的 mihomo 内核换成
[lux5am/mihomo-smart](https://github.com/lux5am/mihomo-smart)。

---

## 1. 目标内核的确定

| 项 | 值 |
| --- | --- |
| 仓库 | `https://github.com/lux5am/mihomo-smart` |
| 分支 | `Alpha`（该仓库唯一分支，也是 HEAD） |
| commit | `8d4c8c70faedc27fda176ee18742ab86b5835a83` |
| commit 时间 | 2026-07-12 |
| Go 模块 | `github.com/metacubex/mihomo`（与旧内核同模块路径，`go 1.20`） |
| 内核版本常量 | `constant.Version = "1.10.0"` |

替换前先用 `git ls-remote` 列过全部分支与 tag，确认 `Alpha` 是唯一开发分支
（另有 `core`/`mini`/`plus`/`plus_pro`/`premium`/`LightGBM-Model` 等 tag，
是不同功能裁剪档位，不是另一条内核线）。

## 2. 旧内核的 SSRVPN 改动清单（迁移基准）

旧内核目录名就是上游 commit：`mihomo-build/mihomo-7031b7569831677a8d89ad8a8a3347db116ba1a8`。
把它与 `MetaCubeX/mihomo@7031b75`（`git clone --filter=blob:none` + `fetch --depth 1 <sha>`）
逐文件比对（按行尾归一化后比对内容），得到 SSRVPN 的全部改动 ——
**改动 6 个文件 + 新增 7 个文件**：

| 文件 | 类型 | 内容 |
| --- | --- | --- |
| `cshared_main.go` | 新增 | C ABI 包装层（9 个 `Ssrvpn*` 导出符号）+ stdout/stderr 重定向到 `core.log` |
| `bridge/bridge.go` | 新增 | 内核生命周期；出站 socket 逐 fd `protect` 通道（8 字节 fd+seq 协议、按 seq 精确回执、800ms fail-open、并发等待） |
| `bridge/bridge_test.go` | 新增 | bridge 行为套件 |
| `component/tls/reality.go` | 改动 | REALITY 两段式版本协商（新版 session ID 布局失败 → legacy 布局重试 → 结果 memoise） |
| `component/tls/reality_legacy.go` | 新增 | `realityVersion`/`buildRealitySessionID`/`verifyRealityProof` + 有界并发版本缓存 |
| `component/tls/reality_legacy_erase_linux.go` | 新增 | 用 `MSG_PEEK\|MSG_TRUNC` + `SIOCINQ` 丢弃失败尝试已写入的 ClientHello，使同一条 TCP 连接可重试 |
| `component/tls/reality_legacy_erase_other.go` | 新增 | 非 Linux 平台该能力的空实现 |
| `component/tls/reality_legacy_test.go` | 新增 | 纯函数套件 |
| `component/sniffer/base_sniffer.go` | 改动 | `SniffData` 返回 `ErrorUnsupportedSniffer` 而非 `errors.New("TODO")` |
| `transport/tuic/v4/packet.go` | 改动 | `SetDeadline` 前推到 `SetReadDeadline` |
| `transport/tuic/v5/packet.go` | 改动 | 同上 |
| `go.mod` | 改动 | 追加 `replace github.com/metacubex/gvisor => ../gvisor-patched` |
| `go.sum` | 改动 | 随上面那条 replace 调整的模块图校验和（gvisor 走本地目录后其依赖的哈希条目变化） |

（`f.out` 是误入仓库的一次性 grep 产物，未迁移。）

## 3. 迁移动作

1. **落地新源码树**：把 `lux5am/mihomo-smart@8d4c8c7` 的完整工作树复制为
   `mihomo-build/mihomo-smart-8d4c8c70faedc27fda176ee18742ab86b5835a83/`，
   去掉 `.git`（源码由 SSRVPN 主仓库跟踪），并把全部文本文件行尾统一为 LF
   （与仓库内既有内核文件一致，Windows 上 `core.autocrlf=true` 会引入 CRLF）。
2. **逐文件搬运补丁**，先判断新内核里对应文件的基线是否变过：
   - `component/tls/reality.go`：新内核与旧基线**逐字节相同** → 直接放入旧补丁版本。
   - `component/sniffer/base_sniffer.go`：同上 → 直接放入。
   - `transport/tuic/v4/packet.go`：同上 → 直接放入。
   - `transport/tuic/v5/packet.go`：**新内核改过**（上游修了
     `ReadFrom` 里 `packet.DATA` → `packetPtr.DATA` 的分片读 bug）→ 只在新的
     文件上重打 `SetDeadline` 两处改动，不整文件覆盖。
   - `bridge/`、`cshared_main.go`、`reality_legacy*.go`：纯新增 → 直接放入。
   - `go.mod`：追加同一行 `replace .../gvisor => ../gvisor-patched`。
3. **gvisor 补丁无需重做**：新旧内核对 `github.com/metacubex/gvisor` 的版本要求
   **完全相同**（`v0.0.0-20251227095601-261ec1326fe8`，`go.mod` 与 `go.sum` 双证）。
   把 `gvisor-patched/` 与该版本原始模块 zip 逐文件比对，确认相对原始模块**只改了 1 个文件**
   （`pkg/tcpip/link/fdbased/endpoint.go` 的 `isSocketFD`：`Fstat` 失败时回退为
   「非 socket」而不是报错，因为 HarmonyOS 的 VPN fd 拒绝 `Fstat` 但 `readv/writev` 正常）。
4. **删除旧内核目录** `mihomo-build/mihomo-7031b75…/`（替换语义；历史可从 git 取回）。
5. **构建脚本改为确定性选源**：`scripts/build-ohos-core.ps1` / `.sh` 原先用
   `Get-ChildItem mihomo-* | Select -First 1`（目录序不保证），现在优先选
   `mihomo-smart-*`，多于一个或一个都没有就报错退出，不再可能静默编到别的树。

## 4. 验证

### 4.1 编译与测试

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 补丁包类型检查 | `GOOS=linux GOARCH=arm64 go build ./component/tls ./component/sniffer ./transport/tuic/...` | 通过 |
| 全模块编译（含 bridge） | `GOOS=linux GOARCH=arm64 go build -tags with_gvisor,cmfa ./...` | 通过 |
| 补丁包单测 | `go test ./component/tls ./component/sniffer` | 通过 |
| bridge 测试可编译到目标平台 | `GOOS=linux GOARCH=arm64 go test -c ./bridge/` | 通过（43.5MB 测试二进制） |
| 内核交叉编译 | `scripts/build-ohos-core.ps1` | 通过 |

### 4.2 产物

| 项 | 旧内核 | 新内核 |
| --- | --- | --- |
| 大小 | 50,285,248 B（47.95MB） | 49,297,792 B（47.01MB） |
| SHA-256 | `8F50BAAC…D30B95` | `2058307C216F938C6608BBA9E0BB6FE5DAEFC96D4AA1C94C8B2FA6B7159A62D1` |
| ELF | ELF64 / LE / AArch64 | ELF64 / LE / AArch64 |
| `Ssrvpn*` 导出符号 | 9 个 | **同一组 9 个，名称与数量逐一相同** |
| 生成的 `libgojni.h` | — | 与旧版**字节级完全一致** → `ssrvpn_core_napi.cpp` 无需改动 |
| 可复现性 | — | 连续三次构建 SHA 完全一致 |

新二进制内的特征串自检（`SsrvpnVersion` 现在返回内核真实版本）：

- `ssrvpn-ohos-mihomo-` 存在，且 `1.10.0` 存在 → 版本上报随内核走
- `REALITY negotiation` 存在 → REALITY 版本协商补丁确实进了产物
- `smart_weight_data.csv`（LightGBM 采集器）存在 → mihomo-smart 的 smart 组件确实编进去了

### 4.3 配置兼容性（关键回归面）

把新旧内核所有配置解析包（`config`、`listener/config`、`adapter/provider`、
`rules/provider`、`adapter/outboundgroup`、`component/sniffer`、`component/resolver`、
`component/fakeip`）的结构体 tag 全量提取为键集合后比对：

- 旧内核 269 个键 → 新内核 318 个键
- **被删除的键：0 个**（新增 49 个，全是新特性开关）

即 SSRVPN 生成的 YAML 在新内核上是旧键面的**严格超集**，不存在被移除而静默失效的配置项。

### 4.4 mihomo-smart 新增的 smart 组不会影响 SSRVPN

mihomo-smart 相对 MetaCubeX 的主要增量是 `adapter/outboundgroup/smart.go` +
`component/smart/lightgbm/`（LightGBM 模型驱动的智能选路，模型默认从
`github.com/vernesong/mihomo/releases/.../Model.bin` 下载）。

- 该路径只在 `proxy-groups` 出现 `type: smart` 时进入（`outboundgroup/parser.go` 的 `case "smart"`），
  且只有 `useLightGBM` 为真时才会 `lightgbm.GetModel()`（唯一调用点 `smart.go:754`）。
- SSRVPN 的 `ClashConfigGenerator` 只产出 `select` / `url-test` / `fallback` / `load-balance`
  四种组（`planProxyGroups` 里有 `supported` 白名单），**永远不会产出 `smart` 组**。
- `lgbm-auto-update` 默认 `false`（`config.go` 的 `RawConfig` 默认值），且 SSRVPN 不写这个键。

**结论：SSRVPN 的运行路径不会触发模型下载**，不会重现「全新安装首连被联网下载挂死」那一类问题
（踩坑记录 坑 24）。

> **后续更新（2026-09-19，见 §7）**：该结论描述的是**换核当时**的状态。之后按需求把
> smart 组接进了自动选择，因此不再成立 —— 改为「由应用侧 `isSmartModelReady()` 闸门
> 保证只在模型就绪时才声明 smart 组」。详见 §7。

### 4.5 应用侧回归套件

`SSRVPN_HarmonyOS/scripts/` 下的校验脚本在本工作副本上重跑：

| 脚本 | 结果 |
| --- | --- |
| `verify-logic-pure.mjs` | 228/228 通过 |
| `verify-vpn-architecture.mjs` | 127/127 通过 |
| `verify-mihomo-alignment.mjs` | 102/102 通过 |
| `verify-site-routing.mjs` | 56 通过 / 0 失败（6 条非门禁审计项） |
| `verify-app-routing.mjs` | 71 通过 |
| `verify-node-sort-persistence.mjs` | 16/16 通过 |
| `verify-proxy-name-uniqueness.mjs` | 15/15 通过 |
| `verify-latency-engine-runtime.mjs` | 17/17 通过 |
| `verify-latency-cache.mjs` | 61/61 通过 |
| `verify-types.mjs` | **失败，但与本次改动无关**：失败点是 DevEco SDK 自带的 `@ohos.annotation.d.ets` 无法被本地 tsc 解析；在未改动的 `SSRVPN-HarmonyOS` 副本上重跑结果完全相同 |

### 4.6 HAP 打包验证（端到端）

用 DevEco 自带 hvigor 真实打包：

```
node "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js" `
  --mode module -p product=default -p module=entry@default -p buildMode=debug `
  assembleHap --no-daemon
```

结果 `BUILD SUCCESSFUL`，产物
`entry/build/default/outputs/default/entry-default-unsigned.hap`（19.98MB，未签名）。

解包 HAP 后核对 `libs/arm64-v8a/`：

| 文件 | 大小 | 检查 |
| --- | --- | --- |
| `libgojni.so` | 49,297,600 B（hvigor 已 strip） | ELF64/AArch64；`Ssrvpn*` 9 个；含 `1.10.0` 与 `REALITY negotiation` 标记 |
| `libssrvpn_core_napi.so` | 72,752 B | 未变 |
| `libc++_shared.so` | 1,262,504 B | 未变 |

### 4.7 打包过程中发现并修掉的两个坑

这两个都不是内核本身的问题，但都会让「换了内核」这件事在真机上表现为失败或退步：

1. **`entry/oh_modules/libssrvpn_core_napi.so` 是 ohpm 建的 Junction（目录联接），复制项目时会被拍平成空目录。**
   症状：`CoreBridge.ets` 报 `arkts-no-any-unknown`（`native.attachTunFd(...)` 退化成 `any`），
   日志里真正的线索是 `Currently module for 'libssrvpn_core_napi.so' is not verified`。
   修法：删掉空目录后重建联接
   （`New-Item -ItemType Junction -Path entry\oh_modules\libssrvpn_core_napi.so -Target entry\src\main\cpp\types\libssrvpn_core_napi`）。
   注意这**不是**清构建缓存能解决的，清缓存后依旧复现。

2. **`entry/libs/<abi>/` 下任何 `.so` 都会被 hvigor 打进 HAP，不只是 `libgojni.so`。**
   我一开始把旧内核备份成 `libgojni.so.bak-7031b75` 放在同目录，结果 HAP 里同时出现新旧两个内核
   （HAP 从 20MB 涨到 36.9MB，且分发出去就带着旧内核）。
   已删除备份，并在两个构建脚本里加了守卫：`entry/libs/<abi>/` 出现除 `libgojni.so` 以外的 `.so`
   直接报错退出，不再可能静默打包旧内核。

## 5. 附带改动

- `cshared_main.go` 的 `SsrvpnVersion()` 由静态串 `ssrvpn-ohos-mihomo-1.0.0` 改为
  返回 `"ssrvpn-ohos-mihomo-" + constant.Version`，这样诊断弹窗显示的版本随内核走，
  能直接在真机上确认跑的是哪一版内核。（该串在工程内无任何断言依赖。）
- `SSRVPN_HarmonyOS/THIRD_PARTY_NOTICES.md` 按 GPL-3.0 要求重写内核来源登记：
  新内核 repo/branch/commit、源码树路径、构建 recipe、产物 SHA-256，并把 gvisor 补丁
  单独登记为 Apache-2.0 的第二个第三方来源。
- `SSRVPN_HarmonyOS/SPEC.md`、`PORTING_STATUS.md`、`START_HERE_FOR_AGENT.md`
  中指向旧内核的表述已更新（upstream Android 版仍用旧内核这一点保留说明）。
- `mihomo-build/mihomo-smart-8d4c8c7…/README.md` 顶部加了差异表，
  让这个源码树本身就能说明「相对上游 mihomo-smart 改了哪 5 个文件、新增哪 7 个文件」
  （第 6 个改动文件就是这个 README 自己）。

## 6. 尚未验证 / 下一步

- **真机验证**：内核是 OHOS/arm64 二进制，本机（Windows）无法执行，因此
  「连接可用、节点测速、TUN 流量、REALITY 节点握手」这些只能在真机上确认。
  特别值得回归的是 REALITY legacy 协商补丁在新内核上的实际表现（新内核的
  `component/tls/reality.go` 与旧基线相同，补丁语义未变，但 utls 版本从 1.8.4
  升到 1.8.7，握手细节值得实测）。
- **HAP 未签名**：本次跑通了打包（`BUILD SUCCESSFUL`），但没有配置签名，
  产物仍是 `entry-default-unsigned.hap`，真机安装前需按
  `README.md`「签名与安装」自行签名。
- **`bridge/bridge_test.go` 未在真机/目标平台执行**：只验证了它能编译到 linux/arm64
  （Windows 上跑不了 linux 二进制）。bridge 的 protect 协议属于真机行为，
  回归仍需真机。
- **只换了鸿蒙端**：`SSRVPN-HarmonyOS`（原始副本）未做任何改动，仍捆绑旧内核
  `zeyugao/mihomo@7031b75`；如果也要换，把本工作副本的
  `mihomo-build/mihomo-smart-8d4c8c7…/`、`entry/libs/arm64-v8a/libgojni.{so,h,sha256}`
  与两个构建脚本一起搬过去即可（`gvisor-patched` 两份相同，可不搬）。

## 7. 启用内核 smart 组（自动选择 / LightGBM）

换核之后新增的工作：把一个真正的 LightGBM 智能选点接进 SSRVPN。

### 7.1 为什么需要（换核前 vs 换核后）

SSRVPN 原本的"自动选择"是**应用侧手写线性权重**（`SmartSelector.ets`：延迟 + EWMA 成功率
+ 连续失败 + 冷却 + 陈旧度），而且选出来的是**整条隧道钉死一个节点**。
内核 smart 组是**按每条连接的目标特征**（ASN / GeoIP / 端口 / 域名类型）分别选点，
并且用 LightGBM 模型做综合评分。两者不是同一个东西。

### 7.2 上游没有官方文档

找不到任何官方说明，只能从代码推导（详见踩坑记录 坑 41）：

- MetaCubeX wiki **没有 `smart` 组页面**；fork 的 `README.md` 是主线 README 逐字拷贝；
  `docs/` 里没有任何 smart/lightgbm 字样。
- `config/config.go` **没有默认 `SmartOption` 块** → 不写就是零值全关。

采用的配置：`uselightgbm: true` + `collectdata: false` + `prefer-asn: false`。

### 7.3 启动期阻塞（本改动最大的风险）

`GetModel()` / `InitASN()` 都会在 `config.Parse` 阶段**同步联网下载**（github.com，国内不可达）。
本机用真内核 `-t` 实测：

| 配置 | 耗时 | 结果 |
| --- | --- | --- |
| `smart` + `uselightgbm: true`，无 `Model.bin` | **90.1s** | 软失败降级（配置仍 successful，但用户已等 90s） |
| 同上，有真 `Model.bin`（9,345,218 B） | **0.1s** | `Model file loaded successfully` |
| `smart` + `prefer-asn: true`，无 `ASN.mmdb` | **90s** | `Failed to load ASN database` |
| `smart` + `prefer-asn: false` | 7ms | 正常 |

这是坑 24/40 的第三个入口。**软失败比 hard fail 更阴**：配置能起来，
但内核悄悄退化成无模型，看起来能用其实没生效。

### 7.4 实现

| 位置 | 改动 |
| --- | --- |
| `ClashConfigGenerator.generate(…, useSmart = false)` | 新增 `♻️ 自动选择`（`type: smart`）组；仅当 `useSmart && validNodes.length >= 2` 且组名不与任何节点/组冲突时声明 |
| `ClashConfigGenerator.SMART_GROUP_NAME` | 固定组名常量，集成层用它选中该组 |
| PROXY 成员顺序 | auto 模式下 smart 组占首位；manual 模式下仍在列表里但不占首位 |
| `ConnectionOrchestrator.isSmartModelReady()` | 存在 + ≥1MB + 魔数 `tree` 才算就绪 |
| `ConnectionOrchestrator.seedSmartModelFromRawfile()` | **首选**：从 HAP 内置 `rawfile/Model.bin` 铺到 cacheDir（无网络依赖） |
| `ConnectionOrchestrator.downloadSmartModelInBackground()` | 兜底：多镜像 + 落盘前魔数校验 |
| `connect()` 的 `pinSmartGroup` | **auto + 就绪时把 PROXY 指向 smart 组本身**，而不是 `selectNode(target.name)` |
| `this.lastUseSmart` | 热重载复用同一决策，避免两次生成不一致 |

**`pinSmartGroup` 是关键且不显然的一点**：`connect()` 末尾本来会
`api.selectNode(target.name)` → `PUT /proxies/PROXY {name}`。
如果 auto 模式下仍把 PROXY 钉到具体节点，内核的按连接选点就被彻底架空了。

### 7.4.1 模型必须内置，不能只靠下载（2026-09-19 真机反馈后修正）

**第一版把 smart 组和模型准备都锁在 `autoSelectMode === AUTO` 上，结果真机上"自动选择一直不出现"。**
两个原因叠加：

1. `autoSelectMode` 默认就是 **`manual`**（`AppSettings` 默认值），用户开箱即是，
   所以整条路径根本没进 —— 连下载都没触发。
   **修正**：模型准备与模式解耦，任一模式下只要没就绪就先补齐；
   `autoSelectMode` 只决定 PROXY 是否默认指向 smart 组。
2. 就算进了路径，**纯联网下载在国内基本不可用**（2026-09-19 直连实测）：

   | 镜像 | 结果 |
   | --- | --- |
   | `testingcf.jsdelivr.net/gh/vernesong/mihomo@LightGBM-Model/Model.bin` | **404** —— `LightGBM-Model` 是 release tag 不是仓库 ref，jsdelivr 取不到 release 附件 |
   | `ghfast.top/...` | 连不通 |
   | `gh.llkk.cc/...` | 连不通 |
   | `github.moeyy.xyz/...` | 连不通 |
   | `gh-proxy.com/...` | 200，但**限速**：120s 只下到 5.9MB / 9.3MB |
   | `ghproxy.net/...` | 200，但更慢：120s 只下到 2.9MB |

   **修正**：把 `Model.bin`（9,345,218 B）**内置进 HAP 的 `resources/rawfile/`**，
   首选本地铺盘；下载降级为兜底（镜像表按实测可达性重排，`readTimeout` 放宽到 300s）。
   副作用：HAP 从 20,000,041 → **29,349,873 B**（rawfile 不压缩）。

   这也顺带满足了「离线可用」：模型不再依赖任何网络。

### 7.4.3 节点列表里的「♻️ 自动选择」入口（第二次真机反馈后补）

**第二次真机反馈：模型已铺盘，但「全部节点」里依然看不到自动选择。**

根因是架构性的，与模式无关：

> `NodeSelectionPage.rebuildRows()` 的列表数据源是 **`this.subs.nodes`（解析后的订阅）**，
> 而 smart 组只存在于**内核配置**里。两者是不同来源，所以内核组**在任何模式下都不可能**
> 出现在该列表中 —— 光加 `type: smart` 是看不见的。

补法：在 `rebuildRows()` 里合成一行 `♻️ 自动选择` 并置顶（仅当模型就绪且未按订阅过滤）。
合成行不是真实节点（`server=''`/`port=0`），因此必须逐处显式区分，否则会污染既有逻辑：

| 风险点 | 处理 |
| --- | --- |
| 批量测速（`targetNodes()` 遍历 `this.nodes`） | `isSmart === true` 跳过 —— 否则永远显示「超时」 |
| 排序（快照 / 实时延迟重排） | 排序前先摘出，排完再置顶；实时重排 key 返回 `-1` |
| 长按删除 | 直接 `return` —— 它不在订阅里，DELETE 会拿不存在的 id |
| 选中它 | **语义 = 切到自动模式**，重连仍用当前偏好真实节点；绝不能把假节点传给 `reconnectWithNode`（会生成非法配置） |
| 配置生成 | 天然安全：它不在 `subs.nodes` 里，生成器遍历不到 |
| 按订阅过滤（`filterSubId`） | 合成行无法反查 `subscriptionId`，该分支下不展示 |

选中流程：`selectNode()` 命中 `SMART_ROW_ID` → 存 `autoSelectMode=auto` → `reconnectWithNode(真实节点)`
→ `connect()` 内 `SettingsService.load()` 读到 auto（line 480，非缓存）→ `pinSmartGroup` 把 PROXY 指向 smart 组。

卡片也刻意做了区分：不显示协议徽标与延迟徽标/↻，改成「内核智能选点 · 按每条连接的目标自动择优」，
避免用户点测速拿到永远失败的结果而误以为功能坏了。

`ensureSmartModelReady()`（public）供页面判断是否展示该入口，并顺带触发一次内置模型铺盘 ——
否则用户**首次打开节点列表（还没连过）时看不到入口**。



### 7.4.4 第三轮真机反馈：主页显示、测速频率、自动选择分组

三个独立问题，一起改：

**(1) 选完「自动选择」回主页仍显示别的节点**

`HomePage.refreshDisplayNode()` 读的是 `settings.preferredNodeId`。选自动选择时我
**故意没改 preferredNodeId**（保留手动偏好，退出自动模式能回到原节点），但主页
只用它渲染 → 显示的是那个"备选"节点，看起来像没生效。

修法：自动模式 + 模型就绪时，主页显示 `♻️ 自动选择`。

> **注意一个反直觉点**：`HomePage.selectedNode()` **不能**因为自动模式就返回 `null`。
> `ConnectionOrchestrator.connect()` 开头（line 2204）无条件读 `node.name`，并把它当
> 兜底 `target`（只在 `isValidNode` 失败时才回退到首个有效节点），传 `null` 会直接抛。
> 「PROXY 指向 smart 组」是 orchestrator 内部 `pinSmartGroup` 做的，不靠调用方传空。
> 这一点差点改错，已验证。

**(2) 每次进节点页都重新测速**

旧行为：`onPageShow → bootstrap → autoTestMissing()`，每次进页面都补测。
用户要求：**只在 app 启动时测一次，或导入订阅时测一次**。

修法：加频率闸门。`AppStorage` 只在进程内存里，冷启动即清空 —— 正好表达"本次启动
还没测过"；订阅变更用 `subscription_revision` 表达（唯一持久化收口点
`SubscriptionService.persist()` 里 +1，导入/刷新/增删都会经过它）。
两者拼成 stamp，相同就跳过。**先写 stamp 再测**，避免快速切页并发触发两轮。

**(3) 节点页加「自动选择」分组，映射内核实际选点**

加在「全部」旁边的 chip（互斥）。

> **关键限制**：内核 `Smart.Now()` 返回的是 `s.selected`，**只在用户手动固定时非空**；
> LightGBM 的按连接选择**不会**写回 `now`（见 fork `smart.go` 的 `Now()`/`MarshalJSON`，
> 字段还有 `fixed`）。所以组详情接口**根本反映不出自动选点结果**。

唯一的事实来源是 `GET /connections` 里每条连接的 `chains`。
于是新增 `ClashApiService.smartActiveNodes(groupName, knownNames)`：
遍历活动连接，筛出 `chains` 含该组的，再**与已知真实节点名求交、取最后一个命中**。
不假设 chains 顺序 —— 内核里 `AppendToChains` 由各组自己调用
（`smart.go:404` 只 append 自己，内层节点由适配器 append），顺序随实现变化，
求交与顺序无关。

视图每 3s 轮询一次，**只在进入该视图期间存在，`onPageHide` 必须停**
（否则退到后台还在打内核 API）。区分三种状态，避免把通道故障显示成"没有节点"：

| 状态 | 显示 |
| --- | --- |
| `null`（内核不可达） | 「内核未连接 · 读不到内核的连接列表，先连接 VPN 再看」 |
| `[]`（连上了但无活动连接） | 「当前没有活动连接 · 产生流量后会显示在这里」 |
| 有节点 | 按内核实际选中的顺序列出该节点卡片 |

这也顺带满足了「过一会检测到更优节点能增加/替换」：轮询会自动反映内核的实时选择。

### 7.4.5 第四轮真机反馈：分组空白 + 手动选不了节点

**(1) 自动选择分组一直没有节点**

真机抓包拿到了**权威响应**（`hdc fport tcp:19090 tcp:9090` + `curl` 打内核 API）：

```
GET /proxies/PROXY   -> now = "♻️ 自动选择"     内核确实在自动选点
GET /connections     -> chains:
    ["套餐到期：长期有效", "♻️ 自动选择", "PROXY"]
    ["🇭🇰 香港Z09 | IEPL",  "♻️ 自动选择", "PROXY"]
    ["🇦🇺 澳大利亚Z01",    "♻️ 自动选择", "PROXY"]
```

**内核侧全对**：组存在、PROXY 指向它、chains 里出口节点名就是真实节点名，
且 `chains[0]` 正是出口（不是我原先担心的顺序问题）。

bug 在应用侧，是一行遗漏：

```ts
private async refreshSmartActive(): Promise<void> {
  ...
  this.smartActiveNodes = used;   // 只改了 @State
  // ❌ 少了 this.rebuildRows();
}
```

**UI 渲染的是 `this.nodes`，不是 `smartActiveNodes`。** 而 `enterSmartView()` 里那次
`rebuildRows()` 发生在**异步拉取之前**，拿到的还是空数组 → 分组永远空白。

修法：`refreshSmartActive()` 的三条路径（未启用 / 通道故障 / 成功）都要 `rebuildRows()`，
且必须在 `await` **之后**。

> 新增 `scripts/verify-smart-active-chains.mjs`：用真机抓包的 `/connections` + `/proxies`
> 真实响应验证解析逻辑（含「组名/PROXY 不得被当成出口节点」）。无抓包参数时 **SKIP 而非失败**。
> 它的价值在于：证明解析逻辑与顺序假设都对，从而把嫌疑**唯一锁定**到 UI 重建那一步。

**(2) 手动选不了其他节点（本轮改动引入的回归）**

`selectNode()` 对真实节点设了 `preferredNodeId`，但**没有退出自动模式**。
而 auto 模式下 `connect()` 里 `pinSmartGroup` 会把 PROXY 指向 smart 组
（`orchestrator:2504`），于是 `preferredNodeId` 被静默架空 —— 用户点任何节点都没用。

修法：手动点真实节点 = 明确的"我要固定走这个"意图，**必须退出自动模式**。
同时同步页面 `@State autoSelectMode`（横幅读它，不同步会继续显示"自动选点"，
与刚落库的值自相矛盾）。

**(3) 顺带修掉的两个相邻缺陷**

- `exitSmartView()` 漏了 `rebuildRows()`：自动选择视图把 `this.nodes` 换成了
  内核在用节点的**子集**，退出时不重建就会卡在那个被过滤的列表上 ——
  这正是"选不了其他节点"的**第二个成因**。
- 空状态文案没有区分「手动模式所以没在自动选点」与「自动模式但暂无流量」。
  两者都是空列表但原因完全不同，混为一谈会让用户以为功能坏了：
  现在手动模式下显示「尚未启用自动选择 · 点了实际节点就会退回手动模式…」。

### 7.4.6 订阅自带同名组，别混淆

用户的订阅里**本身就有一个叫 `自动选择` 的组**（provider 提供的 `url-test`）。
本改动新增的叫 **`♻️ 自动选择`**（带 emoji 前缀），两者共存不冲突。
在节点列表里找的是**带 emoji 的那个**。

### 7.5 端到端验证（新增 `scripts/verify-smart-e2e.mjs`）

之前的 9 个 `verify-*.mjs` **全部是源码字符串断言**，没有一个真正执行过生成器 ——
而坑 24/40/41 都是"生成的配置让内核启动卡死"，字符串断言对这类问题完全无感。
新套件补上这个空白：真正执行 `ClashConfigGenerator.generate()`，
把产物交给**真实内核** `mihomo -t` 解析。

结果：**21/21 PASSED**

- 结构断言 12 项（smart 组声明/开关约束/组名冲突/单节点不声明/PROXY 成员顺序…）
- 真实内核 9 项：smart 配置 **0.1s** 被接受 + `Model file loaded successfully`
  + 未触发 `Model.bin` 下载 + 未触发 MMDB 下载 + 未长时间阻塞

跑法：`node scripts/verify-smart-e2e.mjs`
（内核自动从 `mihomo-build/*/mihomo.exe` 找；模型放 `mihomo-build/Model.bin`
或用 `SSRVPN_MODEL_BIN` 指定；缺任一则跳过内核段并报告 SKIPPED，绝不静默通过）。

### 7.6 全量回归

| 套件 | 结果 |
| --- | --- |
| `verify-vpn-architecture.mjs` | **190/190**（本轮新增 7 项：rebuildRows-after-await / manual-exits-auto / smart-priority / exclude-filter / url-from-settings） |
| `verify-smart-e2e.mjs` | **21/21**（新增） |
| `verify-smart-active-chains.mjs` | **SKIP（无真机抓包时）** / **5/5（有抓包时）** |
| `verify-logic-pure.mjs` | ALL PASSED |
| `verify-mihomo-alignment.mjs` | 102/102 |
| `verify-app-routing.mjs` | 71 |
| `verify-site-routing.mjs` | 56/0（+6 非门禁审计） |
| `verify-latency-cache.mjs` | 61/61 |
| `verify-latency-engine-runtime.mjs` | 17/17 |
| `verify-node-sort-persistence.mjs` | 16/16 |
| `verify-proxy-name-uniqueness.mjs` | 15/15 |

`mihomo-build/Model.bin`（9.3MB）已加进 `.gitignore`，不入库。

### 7.7 现有应用侧选点逻辑的去留

`SmartSelector.ets` / `NodeSortPersistence.ets` / `DirectLatencyTester.ets` **全部保留**：
模型未就绪时（首次连接后、以及后台下载完成前）走它们，与换核前行为一致。
即"smart 组就绪则内核选点，否则应用侧选点"，不存在功能回退窗口。

### 7.7 新内核能力：已落地与未落地清单

`SmartOption`（`adapter/outboundgroup/smart.go:63`）暴露 5 个键；`GroupCommonOption`
还继承 `url` / `expected-status` / `disable-udp` / `filter` / `exclude-filter` /
`exclude-type` / `test-timeout` / `max-failed-times` / `hidden` / `icon`。

| 键 | 状态 | 说明 |
|---|---|---|
| `uselightgbm` | ✅ 已用 | 生成器固定 `true` |
| `collectdata` | ✅ 已用 | 固定 `false`（本地隐私） |
| `prefer-asn` | ✅ 已用 | 固定 `false`（否则 90s 拉 ASN.mmdb） |
| `sample-rate` | ⚠️ 默认 1 即可 | 只在 `collectdata=true` 时生效；当前 collectdata=false 不影响 |
| `policy-priority` | ✅ **本轮新增** | 高于 LightGBM 评分的硬排序键；新增设置项 `smartPolicyPriority`，格式 `pattern:factor;pattern2:factor2`；子串或正则，首命中生效，因子必须 >0 |
| `url` | ✅ **本轮新增** | 以前硬编码 gstatic，现在用用户「测速设置」里的 `testLatencyUrl`，口径统一 |
| `exclude-filter` | ✅ **本轮新增** | 内核 `GroupBase` 对**显式 proxies 同样生效**（`groupbase.go:196`）；用于排除机场塞进 proxies 的信息条伪节点（真机实证：`套餐到期：长期有效` 曾入选出口） |
| `expected-status` | ⏸ 未用 | 默认空 = 204；若用户测速地址返回非 204 可考虑启用 |
| `disable-udp` | ⏸ 未用 | 当前无此需求 |
| `filter` / `exclude-type` | ⏸ 未用 | `exclude-filter` 已覆盖信息条场景；按类型排除暂不需要 |

**为什么 policy-priority 重要**：它是 fork 里唯一**高于 LightGBM 评分**的排序键
（`smart.go:580`：只要因子不同，就按因子降序，LightGBM 分数再高也翻不过来）。
适合的场景：用户知道某些节点更稳定/更便宜，想给它们硬加权；或者给 `下载专用`
这类廉价节点降权。

**为什么 info-node 过滤重要**：真机抓包证实某些机场把 `剩余流量：965.88 GB`、
`套餐到期：长期有效` 当成节点写进 proxies，它们与真实节点共用完全相同的
server/port/uuid/servername/reality-opts，是纯重复噪音。不过滤的话：
1. 污染 LightGBM 训练/评分样本；
2. 可能被选成出口（真机 chains 已出现）；
3. 测速浪费。

本轮用真机抓包 + 真实内核（`mihomo.exe`）做了两项端到端验证：
- `exclude-filter` 把 3 条信息条从 6 条候选里**干净地移除**，3 条真实节点保留；
- 非法 `policy-priority`（缺因子、零/负因子）内核只告警跳过，**不导致启动失败**。

### 7.8 仍需真机确认

- `exclude-filter` 在真实 OHOS 内核（非 Windows 测试内核）上的行为与测试一致；
  理论上 `GroupBase` 实现跨平台相同，但应确认。
- `policy-priority` 在真实设备上的排序效果（需在设置里填写，观察 `/connections` chains）。
- 用户手动选择节点后，主页显示从 `♻️ 自动选择` 切回真实节点名（逻辑已修，待真机确认）。
- `testLatencyUrl` 设置改变后，smart 组是否随之改变（需重连才能生效，这是正常的）。

