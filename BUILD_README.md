# Nexus HarmonyOS 完整构建包

本包内含可在 DevEco Studio 环境一次性完成 HAP 打包的全部内容：

```
Nexus-HarmonyOS-full/
├── Nexus_HarmonyOS/          # HarmonyOS 工程完整源码
│   ├── entry/                 #   主模块（源码 + libs/arm64-v8a/libgojni.so 内核库）
│   ├── AppScope/
│   ├── build-profile.json5    #   构建/产品配置
│   ├── hvigor/                #   hvigor 配置
│   ├── oh-package.json5 / oh-package-lock.json5
│   ├── oh_modules/            #   依赖（已就位，无需 ohpm install）
│   └── scripts/               #   build-ohos-core.ps1 / .sh（内核交叉编译脚本）
├── mihomo-build/              # Mihomo 内核 Go 源码（含已修改的 bridge/cshared_main 与
│                              #   gvisor-patched，供重新编译 libgojni.so；当前包内已含编译好的 .so）
└── BUILD_README.md            # 本文件
```

## 一次性 HAP 打包步骤（PowerShell）

前置条件：已安装 DevEco Studio（本机路径示例）。

```powershell
cd Nexus_HarmonyOS

$env:DEVECO_SDK_HOME = 'C:\Program Files\Huawei\DevEco Studio\sdk'   # 必须是 sdk 目录本身
$env:JAVA_HOME       = 'C:\Program Files\Huawei\DevEco Studio\jbr'   # 打包工具需要 java
$env:Path            = "$env:JAVA_HOME\bin;$env:Path"

node "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js" `
  --mode module -p product=default -p module=entry@default -p buildMode=debug `
  assembleHap --no-daemon
```

- 成功标志：`BUILD SUCCESSFUL`
- 产物：`entry\build\default\outputs\default\entry-default-unsigned.hap`
- 注意：`DEVECO_SDK_HOME` 必须指向 `...\DevEco Studio\sdk`；指向 `sdk\default` 会报
  `00303312 Cannot find the corresponding SDK version`。
- 未配置签名（构建日志会有 `No signingConfig found` 警告），产物为未签名调试 HAP，
  真机安装需自行在 DevEco Studio 配置签名。

## 重新编译内核（可选）

`Nexus_HarmonyOS/entry/libs/arm64-v8a/libgojni.so` 已随包提供，正常打包无需重编。
如需修改内核（Go 层 bridge）：

```powershell
powershell -ExecutionPolicy Bypass -File Nexus_HarmonyOS\scripts\build-ohos-core.ps1
```

脚本内路径为固定写死的构建机路径（mihomo-build 源目录 / OHOS NDK clang），
换机器时请先按本包内 mihomo-build 的实际路径与 NDK 路径修改脚本顶部变量。
注意：链接阶段内存占用大（约 4GB+ 提交内存），低内存机器需调大页面文件。

## 关键源码位置

- UI/服务层：`Nexus_HarmonyOS/entry/src/main/ets/`
- VPN 扩展：`Nexus_HarmonyOS/entry/src/main/ets/vpnability/VpnExtensionAbility.ets`
- 连接编排：`Nexus_HarmonyOS/entry/src/main/ets/commons/services/ConnectionOrchestrator.ets`
- 订阅解析：`Nexus_HarmonyOS/entry/src/main/ets/commons/services/SubscriptionParser.ets`
- 配置生成：`Nexus_HarmonyOS/entry/src/main/ets/commons/services/ClashConfigGenerator.ets`
- NAPI 桥：`Nexus_HarmonyOS/entry/src/main/cpp/ssrvpn_core_napi.cpp`
- 内核桥（Go）：`mihomo-build/mihomo-*/bridge/bridge.go` 与 `mihomo-build/mihomo-*/cshared_main.go`
