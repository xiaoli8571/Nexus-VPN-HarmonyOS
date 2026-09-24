# SSRVPN for HarmonyOS（鸿蒙 NEXT）

将 [SSRVPN](https://github.com/Elegying/SSRVPN)（Android 上的 Clash/Mihomo 客户端）完整移植到
**HarmonyOS NEXT（纯鸿蒙 ArkTS）**。
**Mihomo（Clash Meta）**以 `c-shared` 库形式进程内嵌入，通过 `VpnExtensionAbility` + TUN
（gVisor 用户态协议栈）实现全局代理。

> ⚠️ 本项目仅供学习与技术研究。使用者需自行遵守所在地法律法规及所用网络服务条款。
> 仓库内 HAP 为**未签名**产物，不能直接安装，需自行签名（见下文）。
> 欢迎加入交流群：https://t.me/+x9D290Stp9NhYWU9  华为商店邀测会在群里发布链接

## 主要能力

- 订阅管理：订阅/节点链接导入、base64/明文 YAML 解析、更新与去重、二维码导入
- 节点选择：分组筛选、按国家/地区图标、批量测速（`/proxies` API）、延迟配色
- 连接编排：`VpnExtensionAbility` 创建 TUN，进程内加载 `libgojni.so`（Mihomo）并启动内核
- 防回环：`connection.protectProcessNet()`（API 22+）保护内核自身 socket，避免自连死循环
- DNS 覆写：fake-ip 模式 + TUN `dns-hijack any:53`（常开），裸 IP UDP 上游防解析死锁
- **代理域名防投毒**：连接前在 UI 进程用 DoH（doh.pub/alidns）预解析所有节点入口域名，
  写入 YAML `hosts:`，内核直接命中真实 IP —— 规避国内 UDP DNS 把代理域名污染成假 IP
  （否则表现为"连上了但所有网站打不开"）
- **IPv6 入站（按环境自动启用）**：连接前探测物理网络 IPv6 连通性，有则开双栈
  （`::/0` 路由 + `fake-ip-range6`），无则自动绕过为纯 IPv4 —— 避免把 IPv6-preferred
  应用（YouTube 等）引上无出口的死路
- **全局/智能模式修复**：节点选择同时下发到 `PROXY` 与 `GLOBAL` 组 —— mihomo 全局模式
  走隐式 `GLOBAL` 组，若不设置会默认 `DIRECT` 导致全局模式全走直连
- **分应用不走代理**：填包名（如抖音 `com.ss.hm.ugc.aweme`）→ `VpnConfig.blockedApplications`，
  框架层让这些 App 流量完全绕过隧道直连（gvisor TUN 无法按进程名分流，故用框架层）
- 首页：电源按钮（对齐原项目 `SsrvpnPowerButton`）、实时上传/下载速率与本次累计（轮询
  `/connections` 差值算速率）、公网 IPv4 查询
- 诊断与运行日志：订阅页顶栏「日志」→ 居中弹窗（对齐原项目 `AppDiagnosticsView`），
  含诊断项检查、分级可读运行记录、技术明细（已脱敏）
- GeoIP 分流：`geoip.metadb` 后台下载，缺失时自动降级跳过 `GEOIP` 规则避免启动失败
- 规则：强制代理 / 强制直连站点、`DOMAIN-SUFFIX,cn`、GEOIP 兜底 `MATCH,PROXY`

## 仓库结构

```
SSRVPN_Harmony/
├── SSRVPN_HarmonyOS/            # HarmonyOS 工程（ArkTS + 原生 NAPI + 内核库）
│   ├── entry/
│   │   ├── libs/arm64-v8a/libgojni.so   # 交叉编译好的 Mihomo 内核（c-shared）
│   │   ├── src/main/ets/                # ArkTS：UI / 服务 / VpnExtensionAbility
│   │   ├── src/main/cpp/                # NAPI 桥（dlopen libgojni.so）
│   │   └── src/main/module.json5        # 声明 VpnExtensionAbility
│   ├── scripts/build-ohos-core.{ps1,sh} # 重编内核的交叉编译脚本
│   └── build-profile.json5 / AppScope/
├── mihomo-build/                # Mihomo Go 源码（含 bridge/cshared_main 改动 + gvisor-patched）
└── BUILD_README.md              # 详细打包 / 内核重编说明
```

## 构建 HAP

前置：安装 DevEco Studio（含 OpenHarmony SDK 与自带 JDK）。

```powershell
cd SSRVPN_HarmonyOS
$env:DEVECO_SDK_HOME = 'C:\Program Files\Huawei\DevEco Studio\sdk'   # 必须是 sdk 目录本身
$env:JAVA_HOME       = 'C:\Program Files\Huawei\DevEco Studio\jbr'
$env:Path            = "$env:JAVA_HOME\bin;$env:Path"
node "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js" `
  --mode module -p product=default -p module=entry@default -p buildMode=debug `
  assembleHap --no-daemon
```

产物：`entry\build\default\outputs\default\entry-default-unsigned.hap`（未签名）。

## 签名与安装（未签名 HAP → 可安装）

未签名 HAP **无法直接安装**，需用自己的调试证书签名。任选其一：

1. **DevEco Studio**：File → Project Structure → Signing Configs → 勾选 Automatically
   generate signature（登录华为账号），然后 Build → Build Hap(s)，得到已签名 HAP。
2. **命令行**：用 `hap-sign-tool.jar`（`bin` 目录下）配 `localSign` 模式签名，示例见
   `BUILD_README.md`。

安装（开启 USB 调试 / 无线调试后）：

```powershell
hdc install -r entry-default-signed.hap
```

## 重新编译内核（可选）

`entry/libs/arm64-v8a/libgojni.so` 已随仓库提供，正常打包无需重编。若要改 Go 层内核：

```powershell
# 需要 OpenHarmony 版 Go 工具链(GOOS=openharmony) + DevEco native SDK
powershell -ExecutionPolicy Bypass -File SSRVPN_HarmonyOS\scripts\build-ohos-core.ps1
```

关键环境变量（脚本会读取，缺省用相对仓库根的路径）：`MIHOMO_SRC`、`DEVECO_NATIVE_SDK`、
`OHOS_GO_ROOT`、`PROJ_ROOT`。链接阶段约占 4GB 提交内存。详见 `BUILD_README.md`。

## 内核与平台关键实现点

- **c-shared ABI**：`cshared_main.go` 导出 `SsrvpnInit/Start/Stop/IsRunning/Version/LastError`，
  由 `ssrvpn_core_napi.cpp` 以 `dlsym` 加载。
- **TLS 模型**：OHOS 下 CGO 需 `-ftls-model=global-dynamic`，否则运行期 TLS 重定位失败。
- **gvisor fd 注入**：`tun` 用 `stack: gvisor` + 文件描述符注入（`FileDescriptor`），配合
  对 `gvisor` 的 `fdbased.isSocketFD`（`Fstat` 失败回退）补丁，规避沙箱无 `iptables` 的限制。
- **日志重定向**：内核 stdout/stderr 经 `dup3` 重定向到 `core.log`，供诊断弹窗「技术明细」读取。
- **代理服务器解析**：`pinProxyServerHosts` 预解析代理域名写入 hosts，避免 fake-ip 把代理
  服务器域名解析成假地址导致拨号超时；`interface-name` 绑定物理网卡防回环。

完整进度/规格见 `SSRVPN_HarmonyOS/PORTING_STATUS.md`、`SPEC.md`。

## 致谢 / 许可

- 上游设计参考：[Elegying/SSRVPN](https://github.com/Elegying/SSRVPN)（Android）
- 内核：[MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo)（GPL-3.0）
- 参考实现：NekoBox4Harmony、Hey 等同平台移植项目
- 本仓库移植代码遵循与上游一致的开源许可；集成 Mihomo 时须遵守 GPL-3.0（提供内核源码构建方式，见 `mihomo-build/`）。
