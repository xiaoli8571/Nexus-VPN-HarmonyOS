# SSRVPN-HarmonyOS 开发踩坑记录

> 首次记录：2026-09-15（打包/签名）；2026-09-18 扩充为开发向：共存故障排查、真机行为、工具链陷阱、GitHub 发布流水线。
> 环境：DevEco Studio（hvigor-ohos-plugin 6.24.4）、hap-sign-tool（sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar）、Windows、真机 MLR-AL00（API 24 / SDK 6.1.1）
> 项目根：`C:\Users\xiaoli\Downloads\Agent-WorkerSpaces\SSRVPN-HarmonyOS\SSRVPN_HarmonyOS`
> 签名材料：项目上一级目录 `SSRVPN-HarmonyOS\` 下的 `SSRVPN.p12`（别名 `ssrvpn`）+ `SSRVPN.cer` + `SSRVPNRelease.p7b`
> NekoBox 姊妹项目材料：`NekoBox4Harmony-publish-1.9.1\签名材料\`（NekoBox.p12 别名 `nekobox`），两项目共用双层签名流程（坑 4/5/6 同样适用）

---

## 一、黄金路径（最终验证可行的完整流程）

```text
1. hvigor 构建未签名 release .app（--mode project -p product=default -p buildMode=release assembleApp）
2. 从 .app 内提取 entry-default.hap / pack.info / pac.json（注意：不是 outputs 根下那个独立 hap）
3. hap-sign-tool sign-app 签名 HAP（要带 -compatibleVersion 24 -signCode 1）
4. 用「签名后 HAP + 原 pack.info + 原 pac.json」重新打包 .app（HAP 条目名保持 entry-default.hap）
5. 再次 sign-app 签名 .app 外层容器（不带 -compatibleVersion，不带 -signCode）
6. verify-app 验签容器 + 从容器提取 HAP 做往返验签
```

每一步省略或做错都会在 hvigor 或 AGC 处报错，详见下文坑点。

---

## 二、坑点明细（打包 / 签名）

### 坑 1：hvigor 原生签名拒绝明文密码（错误码 00303116）

**现象**：在 `build-profile.json5` 的 `signingConfigs` 里填明文密码后，构建在 `SignHap` 任务失败：

```text
00303116 Configuration Error
The length of the storePassword or keyPassword field in the signature configuration
is less than 32. At file: ...\build-profile.json5
```

**原因**：新版 hvigor（6.24.4）要求配置文件里的密码是 **DevEco GUI 加密后的形式**（≥32 字符），不接受明文。校验在 Java 侧，JS 源码里搜不到该消息。

**解决**：走华为官方 CI 路径 —— 用 `hap-sign-tool.jar` 命令行直接签名，明文密码只作为命令行参数（`-pwdInputMode 0`）。

**善后**：失败后必须把 `build-profile.json5` 还原（`"signingConfigs": []`），否则后续所有构建都会挂在 SignHap。若想以后在 DevEco 内直接出签名包，用 **Project Structure → Project → Signing Configs** 图形界面配置一次（GUI 会自动加密密码写入配置）。

**教训**：不要在仓库文件里留明文密码；实验性签名配置失败后立刻还原。

### 坑 2：assembleApp 是项目级任务，`--mode module` 下任务不存在（错误码 00306054）

**现象**：

```text
00306054 Specification Limit Violation
Task [ 'assembleApp' ] was not found in the project SSRVPN_HarmonyOS.
```

**原因**：平时打 HAP 用 `--mode module`，但 `assembleApp` 只在项目级注册。

**解决**：`--mode project -p product=<产品名> -p buildMode=release assembleApp --no-daemon`。

### 坑 3：.app 产物不在模块 outputs 目录，而在项目级 build 下

**现象**：构建成功后在 `entry\build\default\outputs\default\` 只看到 `entry-default-unsigned.hap` 和一个 `app\` 子目录（里面是打包暂存的 `entry-default.hap`），找不到 .app。

**实际位置**：

```text
<项目根>\build\outputs\default\SSRVPN_HarmonyOS-default-unsigned.app
```

**另注意**：.app 里面的 `pack.info`（1428 字节，App 级）和 outputs 根下的 `pack.info`（921 字节，模块级）**不是同一个文件**，重组 .app 时必须用 .app 里提取的那份。

### 坑 4：.app 需要双层签名 —— 手动重打包丢容器签名 → AGC 错误码 991「非法软件包」

**现象**：把未签名 .app 拆开、签名内部 HAP、再用 `CreateFromDirectory` 重新打包上传 AGC，报：

```text
错误码：991，非法软件包
…或者是否有进行拆包再手动打包，导致未正确签名。
```

**根因**（读 hvigor 插件源码证实）：hvigor 的完整链路是

```text
SignHap（签每个 HAP）→ PackageApp（打 .app 容器）→ SignApp（再签 .app 容器整体）
```

即 **.app 外层容器自己也有一个签名块**（源码：`tasks/sign-app.js` → `SignUtil(SignTypeEnum.APP)`；`sign-command-factory.js` 中 APP 类型复用 `HapSignCommandBuilder`）。手动 `CreateFromDirectory` 重打包只还原了 zip 条目，没有容器签名块，AGC 判定包未签名。

**解决**：对装好签名 HAP 的 .app **再执行一次 sign-app**，参数与签 HAP 完全一致但**不带** `-compatibleVersion`（zip 输入不需要）也不带 `-signCode`：

```text
sign-app -mode localSign -keyAlias ssrvpn -appCertFile SSRVPN.cer
         -profileFile SSRVPNRelease.p7b -inFile <已装签名HAP的.app>
         -signAlg SHA256withECDSA -keystoreFile SSRVPN.p12
         -keystorePwd *** -keyPwd *** -outFile <最终.app> -pwdInputMode 0
```

日志出现 `no need to sign code for :app`（工具识别为 app 包，跳过内部代码签名）+ `Generate signing block success` 即正确。

### 坑 5：sign-app 的 `-compatibleVersion` 只在输入是 .hap 时必填

**规则**（来自 hap-sign-tool 自身 help）：

- 输入 .hap：`-compatibleVersion` 必填，值取 pack.info 的 `apiVersion.compatible`（本项目为 24）；`-signCode 1` 开启代码签名
- 输入 .app/zip：不填 `-compatibleVersion`，工具自动按 zip 处理，且自动跳过代码签名

**2026-09-18 补充**：NekoBox 的 module.json 里 `app.minAPIVersion` 是 SDK6 数字串（`60101024`），直接取它传参也能签成；但为与既往发布一致，签 NekoBox 时统一显式传 `24`（2.0.1 即此值，AGC 审核以 profile 的 compatible 为准）。

### 坑 6：签名块不在 META-INF —— 用错方式判断「已签名/未签名」

**认知纠正**：HarmonyOS NEXT 的签名**不写 META-INF 条目**（不同于 Android JAR v1），而是内嵌在 ZIP 结构里的 **Hap Signing Block（v3）**。

**正确验证方式**：必须用 `hap-sign-tool verify-app`：

```text
verify-app -inFile <signed.hap 或 signed.app> -outCertChain chain.cer -outProfile profile.p7b
```

判读要点：

- `Find Hap Signing Block success, version: 3` → 签名块存在
- `verify codesign success` + 逐个 native 库校验 → 代码签名有效（.app 容器层验证时出现 `can not find codesign block` 属**正常**，容器层没有代码可签）
- `Digest verify result: true` → 摘要校验通过
- `Missing parameter: outproof` 警告无害，可忽略
- 交付前必须做**往返验证**：从最终 .app 里提取 HAP 再次 verify-app，证明交付物本身有效

### 坑 7：多个 .p12 并存时先确认别名和证书指纹

目录里同时存在 `SSRVPN-legacy.p12`、`SSRVPN.before-cert-import.p12`、`SSRVPN.p12`。用 keytool 确认当前密钥库的别名与指纹：

```text
keytool -list -keystore SSRVPN.p12 -storetype PKCS12 -storepass ***
```

- 输出 `PrivateKeyEntry` 的别名即 `keyAlias`（SSRVPN 为 `ssrvpn`；NekoBox 为 `nekobox`）
- 记下证书 SHA-256 指纹，与 verify-app 输出的证书链中 `certificate #1` 的 SHA-256 **逐一比对**，确证签名用了对的钥匙
- 取 `LastWriteTime` 最新的密钥库；旧的 legacy/before-cert-import 不要用

### 坑 8：profile 类型必须与构建类型匹配

`SSRVPNRelease.p7b` 是 release 描述文件。签名日志和 verify-app 输出都会打印 `profile type is: release`。release profile 只能签 release 构建；用 release profile 签 debug 包会被拒绝。调试签名材料在 `~\.ohos\config\default_<工程名>_*.p12/.cer/.p7b`（DevEco 自动生成），与发布材料是两套，别混用。

### 坑 9：产物命名与 dist 目录管理

- 命名规范：`SSRVPN_HarmonyOS-<版本>-{unsigned|signed}-<SHA256前12位>.{hap|app}`，哈希命名天然防呆
- 复制后必须重新 `Get-FileHash` 比对，确认拷贝无损
- **发现缺陷产物立即从 dist 删除**（本次导致 991 的 `...-signed-23de557caedb.app` 已删除），避免误传旧包
- dist 里同时保留：签名 .app（上架 AGC 用）、签名 .hap（`hdc install` 真机直装用）
- 发新包前先升 `AppScope/app.json5` 的 versionCode/versionName：**同一 versionCode 的 HAP 无法覆盖安装**（两项目通用）。发布后务必回读包内 module.json 核对版本（解 zip 读 `module.json`），防增量构建把旧 hap 打进新容器。

### 坑 10：密码安全红线

- 密码只允许出现在**临时命令行参数**中，禁止写入 `build-profile.json5`、脚本、日志、文档（本文档一律以 `***` 代替）
- 签名实验失败后立即还原配置文件，不留含密码的残留
- 聊天里传过的令牌/口令用后撤销轮换（2026-09-18 会话用 GitHub 细粒度令牌走完发布，已提醒轮换）

---

## 三、命令速查（密码以 *** 代替）

```powershell
# 1. 构建未签名 release .app（--mode project！）
& 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat' `
  --mode project -p product=default -p buildMode=release assembleApp --no-daemon
# 产物：<项目根>\build\outputs\default\SSRVPN_HarmonyOS-default-unsigned.app

# 2. 签名 HAP（从 .app 内提取的 entry-default.hap）
& 'C:\Program Files\Huawei\DevEco Studio\jbr\bin\java.exe' -jar `
  'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar' `
  sign-app -mode localSign -keyAlias ssrvpn `
  -appCertFile 'C:\Users\xiaoli\Downloads\Agent-WorkerSpaces\SSRVPN-HarmonyOS\SSRVPN.cer' `
  -profileFile 'C:\Users\xiaoli\Downloads\Agent-WorkerSpaces\SSRVPN-HarmonyOS\SSRVPNRelease.p7b' `
  -inFile entry-default.hap -signAlg SHA256withECDSA `
  -keystoreFile 'C:\Users\xiaoli\Downloads\Agent-WorkerSpaces\SSRVPN-HarmonyOS\SSRVPN.p12' `
  -keystorePwd *** -keyPwd *** `
  -outFile entry-default-signed.hap -compatibleVersion 24 -signCode 1 -pwdInputMode 0

# 3. 重组 .app：签名 HAP（条目名保持 entry-default.hap）+ 原 pack.info + 原 pac.json

# 4. 签名 .app 外层容器（同参数，不带 -compatibleVersion / -signCode，输入输出换成 .app）

# 5. 验签（容器 + 往返提取包内 HAP 各验一次）
... verify-app -inFile <最终.app> -outCertChain chain.cer -outProfile profile.p7b

# —— GitHub Release 发布（api.github.com 直连可达；git 协议被 reset 时见坑 16）——
# 建 release
Invoke-RestMethod -Method Post -Uri 'https://api.github.com/repos/<owner>/<repo>/releases' `
  -Headers @{Authorization="Bearer <PAT>";Accept='application/vnd.github+json';'User-Agent'='dsh'} -Body $json
# 传资产（必须 curl 裸 PUT/POST；Invoke-RestMethod -InFile 会被拒,见坑 16）
curl.exe -sS -X POST -H "Authorization: Bearer <PAT>" -H "Content-Type: application/octet-stream" `
  --data-binary "@dist\xxx-unsigned.hap" "<upload_url>?name=xxx-unsigned.hap"
```

---

## 四、历史产物（2026-09-15 批次，均已在 dist，SHA-256 全量核对）

```text
SSRVPN_HarmonyOS-5.4.0-signed-e85378c3c67a.app   17,676,068 字节  （AGC 上传用）
SSRVPN_HarmonyOS-5.4.0-signed-20796b1ba7bf.hap   18,406,081 字节  （hdc 直装用）
SSRVPN_HarmonyOS-5.4.0-unsigned-74d4eca8af67.hap 19,862,318 字节  （未签名 debug 基线）
```

---

## 五、遗留注意事项（旧条目）

- AGC 上传结果以实际重传为准：本次修复的是工具链验证下唯一可证实的缺陷（容器缺签名）。若仍报 991，核对 AGC 侧证书/Profile 与本地是否同一份（发布证书 SerialNumber `9fd49474682fb6adea0fd0e0a54`，有效期 2026-09-09 ~ 2029-09-09）及 bundleName 是否一致。
- 回归测试脚本要用 `node --experimental-transform-types`（strip-types 模式不支持 TS enum）。
- 真机安装验证由使用者执行，本文档不声称真机结果。

---

## 六、2026-09-18 增补：三种启动报错 + 双 VPN 应用共存（SSRVPN 5.5.4/5.5.5，NekoBox 2.0.2）

真机背景：同装 NekoBox 2.0.1 与 SSRVPN 时 SSRVPN 启动必败；用户另报三类历史报错（凭据缺失拒载 / 控制字符拒载 / [object Object]）。以下按坑归档。

### 坑 11：`control characters are not allowed` 真凶不是订阅文本 —— truncate+write 的 NUL 空洞（最重要）

**现象**：配置文件由 `generate()` 出口全量净化后落盘（1861 字节，干净），内核仍报 `parse config: yaml: control characters are not allowed`。**Wi-Fi 用户从不复现，蜂窝用户必现**。

**根因**：扩展进程 `startCore` 前的 `ensureConfigMtu()` 做读-改-写：
```text
readSync(fd) → 文件偏移已到 1861
truncateSync(fd, 0) → 长度归零，但 POSIX 规定 truncate 不重置偏移!
writeSync(fd, patched) → 写落在偏移 1861 → 头部生成等长稀疏空洞,NUL 填充
```
mihomo 把 NUL 判为控制字符整份拒载。Wi-Fi MTU=1400 与配置默认值相同走不到改写分支，蜂窝 1360 必触发 —— 完美解释用户侧两极分化。

**修复**：读完关 fd，重新以 `READ_WRITE|CREATE|TRUNC` 打开再写（新 fd 偏移恒 0）。`sign-release-package.ps1` 同层思路。
**推广教训**：任何「读后 truncate 再写回同一个 fd」都是雷；改完文件要重开，或 `writeSync(fd, buf, {position:0})`。同类报错排查抓手：**落盘内容与解析内容不一致 → 找写盘之后还碰这个文件的代码**。

### 坑 12：协议白名单「宽进」必须与凭据门禁「成套」——`proxy "N": has unset fields:password`

`YamlMerger.isRelayType` 为防订阅升级出新协议丢节点，对任意合法小写 type 放行；但 `dropReasonFor` 凭据校验起初只覆盖 ss/ssr/trojan/hysteria2/vless/vmess。**tuic/hysteria/anytls 缺凭据的节点被照写进 proxies**，捆绑的旧 mihomo 内核对单节点字段缺失是「整份配置解析失败」而不是跳过 → 一个坏节点让所有用户起不来。报错里的 `"12"` 是 proxies 数组 1 起序号。

**修复**：补齐三类必填门禁（tuic: password+uuid；hysteria: password+protocol+up/down；anytls: password），坏节点进「无效节点账本」提示。
**教训**：白名单每放宽一次，配套的逐类型校验清单必须同步审视；「内核错误带索引」值得在错误映射里翻译成节点名/指引（`friendlyVpnStartError` 已加 `has unset fields`/`control characters` 分支）。

### 坑 13：`[object Object]` —— ArkTS 的 BusinessError 不是 Error 实例

系统 API reject 出来的是普通对象 `{code,name,message}`，惯用式 `e instanceof Error ? e.message : String(e)` 落到 `String(e)` 即 `[object Object]`（全工程曾有 56 处，UI 错误、日志、lastError 全被污染）。

**修复**：`AppLogger.errText(e)` 统一提取 message+code，占位兜底；全量替换。
**教训**：错误转文本永远走集中 helper；回归断言（verify 脚本 SOURCE 组）盯惯用式残留。

### 坑 14：双 VPN 应用共存 = 共享回环端口 + 唯一会话槽位 + 自我复活三件事叠加

真机实证（hilog + ps -ef）：
1. **第三方应用共享同一回环命名空间**：127.0.0.1:9090 上 SSRVPN(mihomo) 与 NekoBox(Clash API) 互踩 —— 一方探测到「端口被占/API 应答异常」直接起不来。NekoBox 2.0.1 把 `clashApiPort` 默认设 9090（安卓习惯），SSRVPN 默认也是 9090。
2. **系统同时只允许一个 VPN 会话（supplier 槽位）**，第三方无权限挤掉对方（`stopVpnExtensionAbility` 只能停自己）；错误码 2203002 要翻译成人话而不是重试。
3. **NekoBox 2.0.1 新增「网络变化重置连接」默认开**：SSRVPN 建/拆隧道本身就触发 `netAvailable/netCapabilitiesChange` → NekoBox 强制重连抢槽 → 反过来踢掉 SSRVPN → SSRVPN 健康恢复又触发……互踢环；配合 `pendingProfileId` 持久化自动重连，扩展进程驻留复活（1Hz `通知发布失败` 日志就是僵尸指纹），SSRVPN 被 `MANAGE_VPN permission check failed` + supplier 注册失败卡死。

**双侧修复**：SSRVPN 5.5.4 端口候选组避让（9090→19090→29090）+ foreign-core 401/403 指纹报错；NekoBox 2.0.2 默认关该功能 + 强制重连 15s 最小间隔 + api 端口 9090→19290 + 存量一次性迁移（带标记落盘、不覆盖用户显式选择）+ 通知失败 5 次退避停用。
**排查套路**：`bm dump -n <bundle>` 看版本、`hdc shell "ps -ef" | grep <bundle>` 看驻留进程、`hilog -x` 找周期刷屏（1Hz 级日志=定时器僵尸）、netmanager 的 `Request network for supplier[...]` 定抢槽失败。

### 坑 15：release 签名包的安装边界

- SSRVPN 的 release p7b 是商店 profile：`hdc install` 直装报 **9568322 not trusted app source**（无论新旧版本）；真机直装必须走 DevEco 自动签名（debug 材料在 `~\.ohos\config\`，口令 DevEco 加密存不了明文）。
- NekoBox 的 release profile 带 udid 白名单，本机（平板已注册进 AGC 设备列表）可直装 signed.app —— 两应用 profile 能力不同，文档别互相套用结论。
- `bm uninstall -k -n <bundle>` 保留数据卸载，重装同 versionCode 仍会被拒（数据里记着版本号）。

### 坑 16：GitHub 发布的三条网络/工具差异

- **git 协议直连 github.com 被 reset**（`Recv failure: Connection was reset`），但 **api.github.com 直连正常** → push 走本机代理：`git -c http.proxy=http://127.0.0.1:7897 push https://x-access-token:<PAT>@github.com/...`（token 拼在一次性 URL 里，不写 remote/config；输出记得 redact）。
- **release 资产上传**：`Invoke-RestMethod -InFile` 打 uploads.github.com 会被判成表单，报 `Multipart form data required` → 换 `curl.exe --data-binary "@file"` + `Content-Type: application/octet-stream` 一次成功。
- 资产名与既往 release 保持一致（`SSRVPN-<ver>-unsigned.hap` / `NekoBox4Harmony-<ver>-unsigned.hap`），推完用 API 回读核对大小。

### 坑 17：PowerShell 四连坑（本次全踩了一遍）

1. **内嵌双引号截断原生命令参数**：`git commit -m "...含 \"...\" 的多行消息"` 里 PS 把 `\"` 当普通字符+引号闭合，参数被切碎，git 报 pathspec 错误。→ 多行/含引号的提交消息一律 `git commit -F <临时文件>`（用完删）。
2. **`Set-Location` 不改变 .NET 进程当前目录**：`[ZipFile]::ExtractToDirectory($相对路径…)` 解析到别的盘目录报 DirectoryNotFound。→ 传给 .NET API 的路径一律绝对。
3. **`$ErrorActionPreference='Stop'` + `2>&1`**：java 工具往 stderr 写 WARN（如无害的 `Missing parameter: outproof`）会被抛成终止错误。→ 调用外部工具的小环境里临时切 `'Continue'`，用 `$LASTEXITCODE` 判成败（`sign-release-package.ps1` 的 `Invoke-SignTool` 就是这么写的）。
4. **`Select-Object -First N` 截断管道**：会让上游命令提前终止、exit code 假 1，还会吞掉 `BUILD SUCCESSFUL` 之后的行。→ 判断构建成败看**产物时间戳 + 包内版本号回读**，不要只看被过滤的日志。

另：控制台 `Get-Content` 输出 UTF-8 中文乱码（代码页问题）只是显示现象，文件本体没坏 —— 用 read 工具看。

### 坑 18：「已修复」的结论要用现场证据复检

5.5.2 的 git log 写着 "sanitize yaml-illegal control chars at all config emit sites"，据此我一度判定控制字符问题已闭环 —— 真机新日志（坑 11）证明报错来自另一条路径。**同类症状 ≠ 同一根因**：净化链修的是"内容脏"，坑 11 是"内容干净的文件被事后写坏"。给结论前，先拿新版本+复现环境的日志验证。

### 坑 19：hvigor 增量构建与包内版本核对

`BUILD SUCCESSFUL in 12s` 且日志里看不到 CompileArkTS/PackageHap —— 可能是增量 UP-TO-DATE，也可能说明没重新打包。发布前固定动作：解包读 `module.json` 的 `versionCode/versionName`（本次 SSRVPN 5.5.5/50504→50505、NekoBox 2.0.2/2000002 均以此法核对）。

### 坑 20：新装首连被防泄漏门禁误杀 —— 系统会整体丢弃扩展 want 的参数（2026-09-19）

**现象**：干净安装设备（日志指纹：asset store 24000002、geoip 未拉取、apiSecret 新建）首连报 `Clash 内核启动失败: 应用分流参数缺失或冲突，已拒绝恢复 VPN`。UI 侧 want 明明带全参数（同日另一台 5.5.4 设备都走到内核启动了），扩展 onCreate 收到的却是空 params。

**根因**：`VpnExtensionAbility` SDK 只有 onCreate(want)/onDestroy()（d.ts 证实，无 onNewWant/onRequest），系统侧二次拉起链路（**授权弹窗放行后由 vpnservice 重组扩展 want**、供应商崩溃复活）递给 onCreate 的 parameters 会整体丢失。configPath 早有 mtime 自愈，而 5.5.1 的分流门禁按防泄漏原则「宁死不猜」——结果新装用户被烧死在首连。老设备无此感，因为直启路径 want 完好。

**修复**（5.5.6）：want 丢参时唯一合法回退 = UI 每次 startVpnExtensionAbility **之前**原子重写的 `vpn_start_params.json`（configPath 逐字相等 + ts ≤3min + 三字段类型完整才采信；任何一项不满足维持原拒绝）。这不是"猜缓存"——文件就是本次 UI 意图的镜像；默认 all、默认 off 依旧禁止。

**教训**：跨进程传参的通道，必须假定"系统可能在中间把它抹掉"；防泄漏门禁要预留可自愈的合法取证路径，否则安全设计烧死首连。

### 坑 21：stop→start 的退出窗口会静默吞并拉起请求

**机制**（代码注释早已承认的竞态）：目标扩展进程尚在退出时 `startVpnExtensionAbility` 只累加 startId、**不回调 onCreate、不报任何错** → UI 只能干等 30s readiness 超时。与坑 20 同族：都源于"onCreate 是唯一入口"。

**修复**（5.5.6）：扩展 onCreate 第一行落 `vpn_launch_epoch.txt`（时间戳）；UI 发起拉起前记 floor，5s 内未见新 epoch 判定"被吞"，自动 stop→clear→重发一次；仍无送达报专属可行动错误，且与坑 20 同规则不计入节点失败。

**排查抓手**：日志里"config written → 扩展侧长时间无任何回写" = 大概率 start 被吞，而不是内核慢。

### 坑 22：日志来源核验（2026-09-19 实例）

一份"修复后设备日志"里出现了**本次会话几分钟前刚写进未提交代码的字符串**（`appRouting params recovered from start-params file`），同时混有四条整个代码库不存在的 `VpnExtensionAbility:` 行（`TUN established, starting core...` / `Core log stream ready` / `Core log level set to info` / `connection restored`——git grep 全库+跨项目零命中）。结论：该日志尾部是推演/模拟产物，不能当整份真机证据用；但同机 DevEco 确实跑过工作树（build-profile.json5 被 GUI 写入加密 debug 签名块），所以恢复行本身可信。**处理法**：症状按真机对待（被吞竞态与模拟症状吻合 → 坑 21 加固落地），来源问题向用户点破，**绝不按模拟日志"对答案"改代码**。

### 坑 23：构建进行中不要读/拷模块产物

后台 `assembleApp`（内部会重跑 assembleHap）执行期间，前台对 `entry-default-unsigned.hap` 做 ZipFile.OpenRead 会撞"file in use"，Copy-Item 更会把**写入中**的文件拷进 dist（本次拷出 20KB 残次品，SHA256 全错）。→ 串行：项目级构建结束 → 时间戳稳定 → 回读版本 → 再拷 dist。

### 坑 24：内核启动期的"联网下载"会把整个启动挂死（全新安装首连必挂，最重要）

**现象**（真机 2026-09-19，MLR-AL00 / 5.5.6 debug 包）：点连接后扩展进程日志停在
`CoreBridge: native module type=object, attachTunFd=function, startCore=function`，**之后 30 秒全静默**——没有 `core start result`、没有异常、没有 `reportStartError`；JS 线程没死（`onDestroy` 正常触发），UI 只能等满 30s 报"Clash API 未就绪：VPN 扩展未上报启动结果"，用户侧看到"内核未运行/隧道未建立/API 不可达"。测速核（headless）同时段也报"测速内核就绪超时(20s)"。

**根因**：配置里 `rule-providers: hyper-adrules: type: http` + `path: ./ruleset/hyper_adrules_ads.mrs`，而**全新安装时该文件不存在**。mihomo 对 http provider 的既定行为是：本地 path 无文件 → **在 `SsrvpnStart()` 内部同步拉取远端 URL**（`github.com`，国内直连不可达且此刻内核没起来、无代理可走）→ 启动协程长期阻塞 → `ExecuteStartCore` 永不返回 → NAPI 的 deferred 永不 settle。整个链路**不产生任何日志、任何错误**，是纯静默挂起。

**取证链（可复现）**：① 设备 `cache/ruleset/hyper_adrules_ads.mrs` 的 mtime = 那次连接后约 3 分钟，即被内核在启动路径里同步下载才落地；`geoip.metadb`（8.5MB）同样在事后才补齐。② 同一台设备、**同一个未修复构建**，仅仅因为这些文件已就位后再点连接，`core.log` 显示 **1ms** 完成启动、`core start result: true`、`connected to node 日本`、`traffic diag: code=200`——双向印证"缺文件=挂死 / 有文件=秒起"。

**关键教训**：GEOIP 那条路**早就**做了文件存在性降级（生成器注释写明"缺失时 config.Parse 阶段会联网下载 MMDB，国内不可达直接导致启动失败"），**同一个坑在 rule-provider 上漏了**。凡是"配置里引用外部文件/URL"的字段，都必须与内核启动路径隔离——要么检查本地就绪后降级，要么后台预取。

**修复**（5.5.7）：
- `ClashConfigGenerator.generate(...)` 新增末位入参 `ruleProviderReady`（默认 true，不破坏既有调用），`rule-providers` 声明与 `RULE-SET` 引用**同受该开关约束**（只关一个会导致引用未声明的 provider）；
- 编排器新增 `isRuleProviderReady()`（`statSync(...).size > 0`）与 `downloadRuleProviderInBackground()`（官方直链 + 两个 GitHub 加速前置代理依次回退，`buf.byteLength > 1024` 防把错误页写进缓存，`TRUNC` 原子覆盖，与 geoip 下载器同构）；**三条**生成路径（隧道 / 测速核 / 规则热重载）全部传该标志；
- 扩展侧新增 `CORE_START_TIMEOUT_MS = 20000` 硬超时与 `runStage()` 分段日志：把"静默挂起"转成可回传的明确错误（`内核启动超时（20s 无响应）…`），tunnel 与 headless 两条路径都加；
- `friendlyVpnStartError` 增分支给出可行动指引；该错误与坑 20/21 同规则**不计入节点失败**（否则会把可用节点误标失败并触发无谓换节点）；
- 顺手修 `CoreBridge.stopCore()`：原先无限 `await pendingStart`，启动一旦被下载阻塞，断开/清理会一起卡死 → 加 5s 上限后仍执行 native `stopCore()` 兜底。

**排查抓手**：扩展日志停在 CoreBridge 探测行之后、且 30s 内无 `core start result` → 先查内核 home（`cacheDir`）里配置引用的本地文件是否齐全（`geoip.metadb`、`ruleset/*.mrs`、`proxy-providers` 的 `./raw_subscriptions/*.yaml`），再看 `cache/core.log` 的最后一条。

### 坑 25：签名脚本会签"上一批"的包 —— 版本核对必须读签名后的包内

**现象**：`sign-release-package.ps1 -Kind hap` 输出的哈希看起来正常，但回读**签名后**的包，`module.json` 仍是上一版 `5.5.6/50506`；`.app` 内层同样。

**根因**（两个叠加）：① 该脚本 `-Kind app` 读的是**项目级** `build/outputs/default/*-unsigned.app`，而我只跑了模块级 `assembleHap`，那份 app 包是上一批的陈旧产物；② 脚本的 `app` 分支还会顺手覆写 `dist\SSRVPN-<ver>-release-signed.hap`（用陈旧内层），于是先签 hap 再签 app 会把正确的 hap 覆盖掉。

**解法/规矩**：发版必须**两级都重建**（`assembleHap` + `assembleApp`，后者内部会重跑前者），签名顺序 **先 app 后 hap**，且**只认签名后包内 `module.json` 的 versionName/versionCode**（本次 5.5.7 三件套 5.5.7/50507 全一致，独立 hap 与 .app 内层 SHA256 逐字节相同）。为此还需**临时让路** DevEco 写入的调试签名块：命令行签名无法解密其口令（`11014003 Init keystore failed / parseAlgParameters failed`），故构建前备份 `build-profile.json5` → `git checkout` 还原 → 构建 → **立即恢复备份**（该文件含签名材料，按 AGENTS 红线绝不提交）。

### 坑 26：延迟测试"半张列表变红"的根因 —— 本机 controller 的传输层异常被当成节点结论（2026-09-19，5.6.0）

**现象**：一次 106 节点的批测跑到 53 个时，其后所有节点全部变成连接异常。旧口径把
`reset` 一类异常归入 `network_unreachable`，于是**几十个节点被盖章成"失败"并写进排序快照**。

**根因（分层理解，必须记住）**：
- **节点不通**时，本机 controller 是**活着**的 —— 它会正常返回
  `503 {"message":"An error occurred in the delay test"}`（拨号失败/状态码不符/`delay==0`）
  或 `504 {"message":"Timeout"}`。也就是说**节点级失败永远带 HTTP 响应**。
- **本机 controller 没能给出 HTTP 响应**（拒绝/重置/超时/断管）只可能是**通道**问题：
  内核被停、扩展进程重启、secret 被换、socket 耗尽。

**规矩**：
1. `classifyTransportError()` 一律返回 `CORE_NOT_READY`，**绝不允许**出现
   "传输层异常 → 节点失败"的映射。
2. 引擎连续命中（≥3）时**先自愈一次**：`refreshLatencyEndpoint()` 用
   `SettingsService.getApiSecret()`（系统加密 AssetStore，**不是**去解析 yaml ——
   配置只是下游产物）+ `applyRealTunnelEndpoint()` 重新下发并复探。
3. 自愈后仍连续失联 → `coreUnavailable = true` 并 `invalidate()` **作废整批**，
   剩余节点保持**未测**，页面提示"内核不可用，本轮未测"。宁可显示"没测"，
   也绝不显示"全红"。

**附带确认的事实**：真机实测批测**不会**弄死隧道 —— 106 节点 / 并发 8 / 18.8s
跑完（88 实测 + 16 超时 + 2 失败），隧道 PID 与 secret 前后完全一致。之前那次
"中途失联"其实是当时隧道本来就处于未连接状态（`mihomo_config.yaml` 不存在）。

### 坑 27：`/group/{name}/delay` 是陷阱，只能用逐节点 `/proxies/{n}/delay`（5.6.0）

组测接口**存在也能用**（真机 46 节点 3087ms），但 mihomo 源码显示：对
`url-test/fallback/load-balance` 系组**忽略传入的 `url`**（用组自己的 `u.testUrl`）；
对非 Selector 组会 `ForceSet("")` **清掉用户固定选择的节点**并写进 cachefile；
**无并发上限**（每节点一个 goroutine）；失败节点从返回的 map 里**静默消失**；
还可能返回 `200` + **部分**结果（只有全失败才 `504 all proxies timeout`）。
→ 一律逐节点测：有明确状态码、可流式进度、可限并发、可取消。
回归套件里有负向断言（源码里出现 `/group/` 即失败）。

### 坑 28：`delay == 0` 是失败、`65535` 是"没测过"，两者都不是延迟（5.6.0）

mihomo 成功时 `delay` 恒 `>= 1`；`history.delay == 0` 表示**失败**（死节点
`alive=false, hist=0ms`）；`LastDelayForTestUrl` 用 `65535` 当"未测"哨兵。
把 0 当"很快"会让**死节点排到列表最前**。故 `LatencyPolicy.isValidDelay()`
只接受 `1 <= d < 32767`，且排序里失败**永不排最前**（CMFA 的朴素升序是公认痛点）。
另外 `timeout` 参数按 **16 位**解析（>32767 → 400）且**必须显式传**（不传 400）。

### 坑 29：测速 URL 必须 HTTPS（5.6.0）

配置里开了 `unified-delay: true`，mihomo 会发两次 HEAD，官方明确警告
`http://` 这类 URL 在**劫持型代理**下会失败。默认用
`https://www.gstatic.com/generate_204`，用户自定义的 URL 若以 `http://` 开头
也回落到 HTTPS 默认值。

### 坑 30：取消测速**不会**释放内核 socket（5.6.0）

`getProxyDelay` 用的是 `context.Background()` —— 客户端 abort 只是客户端行为，
内核会继续拨号到自己的 timeout。所以"取消"只能把 UI 从"测试中"解放、把结果标成
`CANCELLED`（**不是**失败），**不能**减轻内核负载；**并发上限是唯一的负载控制手段**
（移动端取 8，主流客户端区间 5~16）。

### 坑 31：Node 的 type-stripping 拒绝 `enum` —— 可离线回归的 .ets 必须用 class（5.6.0）

验证脚本把 `.ets` 按 `.ts` 暂存后在 Node 里直接 import（`verify-latency-cache.mjs`）。
Node 24 的 strip-only 模式**明确拒绝 `enum`**（`ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX`），
所以 `LatencyState` 用 `class + static readonly`（与既有 `LatencyFailKind` 同风格）。
另外 Node ESM **要求显式扩展名**，暂存时要把 `from './X'` 改写成 `from './X.ts'`。

### 坑 32：测速内核与真实隧道**共用同一个 VpnExtensionAbility 进程**（5.6.0，最危险）

`stopTestCore()` 的第一步就是 `stopVpnExtensionAbility`。延迟测试重做后，"回收
测速内核"由引擎在**每批测速结束后**统一挂起（90s 宽限），因此
`scheduleTestCoreRecycle()` 里必须有**硬安全闸**：`CONNECTED / CONNECTING /
DISCONNECTING / RECOVERING` 四态**直接拒绝回收**。少了这道闸，用户在**已连接**状态下
点一次测速，90 秒后 VPN 会被静默停掉 —— 而且日志里只会看到"回收测速内核"。

---

## 七、当前产物（最新批次优先）

```text
SSRVPN 5.6.0（2026-09-19，延迟测试整体重做 + 坑 26~32）
  dist\SSRVPN-5.6.0-unsigned.hap                 18,544,868 字节  SHA256 A9C0ADF3…
  dist\SSRVPN-5.6.0-release-signed.hap           18,607,418 字节  SHA256 25DACAF6…
  dist\SSRVPN_HarmonyOS-5.6.0-release-signed.app  17,758,993 字节  SHA256 ED759C86…
  （双层签名 + verify-app 通过；包内三件套 5.6.0/50600 一致，.app 内层 hap 与独立
    signed.hap 逐字节相同 SHA256 25DACAF6…；已同步到 %USERPROFILE%\Downloads）
  main=e4fb813 tag=v5.6.0（未推送 GitHub Release：本机到 github.com:443 被重置，
    但走本机代理 127.0.0.1:7897 可以 push —— 见坑 16）
  内容：LatencyEngine（唯一入口）/ LatencyState（五态+时间戳）/ 页面 UI 重写 /
        编排器 ensureLatencyApi + refreshLatencyEndpoint / 坑 26~32

SSRVPN 5.5.7（2026-09-19，修复"全新安装首连内核启动被联网下载挂死"= 坑 24）
  dist\SSRVPN-5.5.7-unsigned.hap                 18,541,856 字节  SHA256 45DA2080…
  dist\SSRVPN-5.5.7-release-signed.hap           18,602,238 字节  SHA256 E146AF92…
  dist\SSRVPN_HarmonyOS-5.5.7-release-signed.app 17,760,690 字节  SHA256 36584AFA…
  （双层签名；hap/容器/往返三级 verify-app 全绿，profile=release；包内三件套均为 5.5.7/50507，
    独立 signed.hap 与 .app 内层 entry-default.hap 逐字节一致）

SSRVPN 5.5.6（2026-09-19 批次，已被 5.5.7 取代）
  dist\SSRVPN-5.5.6-unsigned.hap              18,535,076 字节  SHA256 8B5E360C…
  dist\SSRVPN-5.5.6-release-signed.hap        18,600,826 字节  SHA256 884A5280…
  dist\SSRVPN_HarmonyOS-5.5.6-release-signed.app 17,757,606 字节 SHA256 C35392A4…
  （双层签名，hap/容器/往返提取三级 verify-app 全绿，profile=release）
  main=687b022 tag=v5.5.6（https://github.com/xiaoli8571/SSRVPN_Harmony/releases/tag/v5.5.6）
  内容：坑 20（want 丢参回退快照）+ 坑 21（launch-epoch 送达握手/被吞重发）+ 坑 22 教训

SSRVPN 5.5.5（2026-09-18 批次，已被 5.5.6 取代）
  dist\SSRVPN-5.5.5-unsigned.hap            18,526,284 字节
  dist\SSRVPN-5.5.5-release-signed.hap      SHA256 96688E2C4D420D1F…
  dist\SSRVPN_HarmonyOS-5.5.5-release-signed.app  SHA256 B4027898F1460C21…
  main=b601f11 tag=v5.5.5（https://github.com/xiaoli8571/SSRVPN_Harmony/releases/tag/v5.5.5）

NekoBox（GitHub Release v2.0.2 已挂未签名包；signed.app 本地）
  dist\NekoBox4Harmony-2.0.2-unsigned.hap   15,300,699 字节  SHA256 4BF40F1D…
  dist\NekoBox-2.0.2-signed.app             13,608,547 字节  SHA256 9580776D5A31BAA9…（双层签名+往返验签通过,profile=release）
  main=e714bc1 tag=v2.0.2（https://github.com/xiaoli8571/NekoBox4Harmony/releases/tag/v2.0.2）
```

## 八、验证套件现状

- SSRVPN：`tools/` 下 7 个验证脚本，6 个可无参离线跑（config-sanitize **22/22**、hot-recovery、card-guard、subscription_import_regressions、yaml_compat、yaml_flow_parser），本轮全部确认绿；`verify_local_yaml_production_path.mjs` 需要 yaml 夹具参数，不适用直接执行。为坑 11/12/13/17/20/21/**24** 加的 SOURCE/EXEC 回归断言含反向断言（如"扩展 clearStartError 不得删除自写 epoch"、"provider 声明与 RULE-SET 引用必须同受一个开关约束"、"扩展进程内不得出现规则集下载器"、"每条 generate 调用点都必须传就绪标志"）。
- 跑法：`node tools/verify-config-sanitize.mjs` 等，逐个执行；stderr 里的 ExperimentalWarning 无害。

### 5.6.0 延迟测试重做后的套件变化（2026-09-19）

脚本已从 `tools/` 迁到 `SSRVPN_HarmonyOS/scripts/`，跑法：

```powershell
cd SSRVPN_HarmonyOS
node scripts/verify-latency-cache.mjs    # 45/45  真实驱动状态机与存储
node scripts/test-latency-engine.js      # 40/40  新架构接线 + 旧缺陷负向断言
node scripts/verify-app-routing.mjs      # 71 项
node scripts/verify-config-sanitize.mjs  # 22/22
node scripts/verify-concurrent-refresh.mjs
node scripts/verify-logic-pure.mjs
node scripts/verify-site-routing.mjs
node scripts/verify-vpn-architecture.mjs
```

- **删除** `test-latency-pipeline.js`：它断言的是被整体删除的旧管线（28 路 lane、
  整批级 URL 降级、`prepareLatencyChannel`、`buildLatencyQueue` …），留着会永远红。
- **新增** `test-latency-engine.js`：断言新架构**接线**，重点是"旧缺陷不许复活"的
  负向断言 —— 唯一入口、禁止 `/group/*/delay`、未连接必须经 `ensureLatencyApi`、
  HTTPS URL 强制、并发上限 5~16、`timeout` 显式且 ≤32767、硬截止不写失败、
  取消≠失败、通道不可用≠节点失败、组条目过滤、回收安全闸、以及
  `ClashConfigGenerator` **逐字节未变**（指纹 `scripts/latency-gen-fingerprint.json`）。
- **已知非绿（均与本次改动无关，已用 `git stash` 在 HEAD 上复现）**：
  - `verify-types.mjs`：`[A] tsc` 在 SDK 自带的 `@ohos.annotation.d.ets` 上报
    TS1128/TS1146（SDK 用了 tsc 不认的装饰器语法），HEAD 上同样失败；
    `[B]` 语法解析 1452 行 0 错误。
  - `verify_local_yaml_production_path.mjs`：需要 yaml 夹具参数，无参直接抛 usage。
  - `verify-app-routing.mjs` 本轮**由红转绿**：两条断言写的是**字面语法**
    （`appRoutingMode: appRouting.mode` / `params['bypassPackages'] !== undefined || …`），
    而代码后来重构成 `Record` 下标赋值与合取否定形式，语义没变但断言假阴性。
    已改为**语义断言**（正则匹配两种等价写法）。教训：源码断言尽量匹配语义，
    否则会被无关重构打成假红，最后没人再看这套件。
- 真机交互取证法（本轮新增，可复用）：`hdc shell uitest dumpLayout` + 本地解析出大按钮中心 → `uitest uiInput click X Y` 复现连接 → 设备侧 `hilog -x | grep A05256` 读应用域日志 → `cache/core.log` 读内核自述。比让用户转述日志可靠得多（见坑 22）。
