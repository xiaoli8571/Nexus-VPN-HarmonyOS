<h1 align="center">
  <img src="Meta.png" alt="Meta Kennel" width="200">
  <br>Meta Kernel<br>
</h1>

<h3 align="center">Another Mihomo Kernel.</h3>

> **SSRVPN HarmonyOS 内核分支**
>
> 本目录是 SSRVPN HarmonyOS 的内核源码树，来源
> [lux5am/mihomo-smart](https://github.com/lux5am/mihomo-smart)（分支 `Alpha`，
> commit `8d4c8c70faedc27fda176ee18742ab86b5835a83`）。它在 mihomo-smart 之上叠加了
> SSRVPN 平台集成层，编译入口见 `../../SSRVPN_HarmonyOS/scripts/build-ohos-core.ps1`。
>
> 相对上游 mihomo-smart 的全部差异（新增 7 个文件 + 改动 5 个文件，本 README 除外）：
>
> | 路径 | 说明 |
> | --- | --- |
> | `cshared_main.go` | 新增。C ABI 包装层，导出 `SsrvpnInit/Start/InitProtect/SetProtectResult/SetProtectResultForFd/Stop/IsRunning/Version/LastError`，并把内核 stdout/stderr 重定向到 `<homeDir>/core.log` |
> | `bridge/bridge.go`, `bridge/bridge_test.go` | 新增。内核生命周期 + 出站 socket 逐 fd `protect` 通道（ArkTS 侧 `connection.protect` 回执按 seq 精确配对，超时 fail-open） |
> | `component/tls/reality.go`, `reality_legacy{,_erase_linux,_erase_other,_test}.go` | 改动/新增。REALITY 版本协商：先按新版 session ID 布局握手，失败后回退 legacy 布局并 memoise 结果（修旧面板节点握手失败） |
> | `component/sniffer/base_sniffer.go` | 改动。`SniffData` 返回 `ErrorUnsupportedSniffer` 而不是 `errors.New("TODO")`，让调用方能识别"该 sniffer 不支持"而非当成协议错误 |
> | `transport/tuic/v4/packet.go`, `transport/tuic/v5/packet.go` | 改动。`quicStreamPacketConn.SetDeadline` 前推到 `SetReadDeadline`（原先 no-op，导致 UDP 读永不超时） |
> | `go.mod`, `go.sum` | 改动。追加 `replace github.com/metacubex/gvisor => ../gvisor-patched`，并同步该 replace 引起的模块图校验和 |
>
> 这样 `go build` 直接编译本目录即可得到与 HAP 内 `libgojni.so` 对应的内核源码，
> 无需在构建期注入任何文件（GPL-3.0 对应源码要求）。
> 换核的完整审计与验证记录见仓库根目录 `MIHOMO_SMART_KERNEL_SWAP.md`。

<p align="center">
  <a href="https://goreportcard.com/report/github.com/MetaCubeX/mihomo">
    <img src="https://goreportcard.com/badge/github.com/MetaCubeX/mihomo?style=flat-square">
  </a>
  <img src="https://img.shields.io/github/go-mod/go-version/MetaCubeX/mihomo/Alpha?style=flat-square">
  <a href="https://github.com/MetaCubeX/mihomo/releases">
    <img src="https://img.shields.io/github/release/MetaCubeX/mihomo/all.svg?style=flat-square">
  </a>
  <a href="https://github.com/MetaCubeX/mihomo">
    <img src="https://img.shields.io/badge/release-Meta-00b4f0?style=flat-square">
  </a>
</p>

## Features

- Local HTTP/HTTPS/SOCKS server with authentication support
- VMess, VLESS, Shadowsocks, Trojan, Snell, TUIC, Hysteria protocol support
- Built-in DNS server that aims to minimize DNS pollution attack impact, supports DoH/DoT upstream and fake IP.
- Rules based off domains, GEOIP, IPCIDR or Process to forward packets to different nodes
- Remote groups allow users to implement powerful rules. Supports automatic fallback, load balancing or auto select node
  based off latency
- Remote providers, allowing users to get node lists remotely instead of hard-coding in config
- Netfilter TCP redirecting. Deploy Mihomo on your Internet gateway with `iptables`.
- Comprehensive HTTP RESTful API controller

## Dashboard

A web dashboard with first-class support for this project has been created; it can be checked out at [metacubexd](https://github.com/MetaCubeX/metacubexd).

## Configration example

Configuration example is located at [/docs/config.yaml](https://github.com/MetaCubeX/mihomo/blob/Alpha/docs/config.yaml).

## Docs

Documentation can be found in [mihomo Docs](https://wiki.metacubex.one/).

## For development

Requirements:
[Go 1.20 or newer](https://go.dev/dl/)

Build mihomo:

```shell
git clone https://github.com/MetaCubeX/mihomo.git
cd mihomo && go mod download
go build
```

Set go proxy if a connection to GitHub is not possible:

```shell
go env -w GOPROXY=https://goproxy.io,direct
```

Build with gvisor tun stack:

```shell
go build -tags with_gvisor
```

### IPTABLES configuration

Work on Linux OS which supported `iptables`

```yaml
# Enable the TPROXY listener
tproxy-port: 9898

iptables:
  enable: true # default is false
  inbound-interface: eth0 # detect the inbound interface, default is 'lo'
```

## Debugging

Check [wiki](https://wiki.metacubex.one/api/#debug) to get an instruction on using debug
API.

## Credits

- [Dreamacro/clash](https://github.com/Dreamacro/clash)
- [SagerNet/sing-box](https://github.com/SagerNet/sing-box)
- [riobard/go-shadowsocks2](https://github.com/riobard/go-shadowsocks2)
- [v2ray/v2ray-core](https://github.com/v2ray/v2ray-core)
- [WireGuard/wireguard-go](https://github.com/WireGuard/wireguard-go)
- [yaling888/clash-plus-pro](https://github.com/yaling888/clash)

## License

This software is released under the GPL-3.0 license.

**In addition, any downstream projects not affiliated with `MetaCubeX` shall not contain the word `mihomo` in their names.**