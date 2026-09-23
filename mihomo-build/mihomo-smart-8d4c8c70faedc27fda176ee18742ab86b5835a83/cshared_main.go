// Package main — SSRVPN HarmonyOS c-shared 包装层
// 对应 upstream Android 构建中 gomobile bind 的角色：把 bridge 包暴露为 C ABI。
// upstream: SSRVPN_Android/native/bridge/bridge.go (package bridge)
// 构建目标: GOOS=linux GOARCH=arm64 -buildmode=c-shared, CC = OHOS NDK musl clang
//
// 导出 ABI（与 entry/src/main/cpp/ssrvpn_core_napi.cpp 的 dlsym 对齐）:
//
//	SsrvpnInit(homeDir, configFile)             初始化内核目录
//	SsrvpnStart(configPath, tunFd) -> int       0=成功，1=失败（错误串经 SsrvpnLastError 取）
//	SsrvpnInitProtect() -> longlong             建立逐 fd protect 通道，返回读端 dup fd
//	SsrvpnSetProtectResult(ok)                        兼容保留(无 seq 回执不唤醒)
//	SsrvpnSetProtectResultForFd(fd, seq, ok)          按 seq 精确唤醒对应拨号等待者
//	SsrvpnStop()
//	SsrvpnIsRunning() -> int
//	SsrvpnVersion() -> const char*
//	SsrvpnLastError() -> const char*
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"

	"golang.org/x/sys/unix"

	"github.com/metacubex/mihomo/bridge"
	"github.com/metacubex/mihomo/constant"
)

var (
	lastErrMu  sync.Mutex
	lastErrStr string
)

func setLastErr(s string) {
	lastErrMu.Lock()
	lastErrStr = s
	lastErrMu.Unlock()
}

// redirectCoreLogs 把 Go 进程的 stdout/stderr 重定向到 homeDir/core.log。
// OHOS 应用进程的 stdout 不落任何可见位置, mihomo 全部运行日志(拨号失败原因/
// DNS/TUN)只有落盘才能被 hdc 拉取排查(对齐 Hey/NekoBox 的内核日志文件方案)。
func redirectCoreLogs(homeDir string) {
	if len(homeDir) == 0 {
		return
	}
	path := filepath.Join(homeDir, "core.log")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return
	}
	fd := int(f.Fd())
	// 故意不关闭 f: fd 1/2 现在别名到同一文件描述符
	_ = unix.Dup3(fd, 1, 0)
	_ = unix.Dup3(fd, 2, 0)
}

//export SsrvpnInit
func SsrvpnInit(homeDir *C.char, configFile *C.char) {
	redirectCoreLogs(C.GoString(homeDir))
	bridge.Init(C.GoString(homeDir), C.GoString(configFile))
}

//export SsrvpnStart
func SsrvpnStart(configPath *C.char, tunFd C.longlong) C.int {
	path := C.GoString(configPath)
	if _, err := os.Stat(path); err != nil {
		setLastErr(fmt.Sprintf("config file missing: %v", err))
		return 1
	}
	fd := int64(tunFd)
	result := bridge.Start(path, fd)
	if result != "" {
		setLastErr(result)
		return 1
	}
	setLastErr("")
	return 0
}

//export SsrvpnInitProtect
func SsrvpnInitProtect() C.longlong {
	return C.longlong(bridge.InitProtect())
}

//export SsrvpnSetProtectResult
func SsrvpnSetProtectResult(ok C.int) {
	bridge.SetProtectResult(ok != 0)
}

//export SsrvpnSetProtectResultForFd
func SsrvpnSetProtectResultForFd(fd C.longlong, seq C.longlong, ok C.int) {
	bridge.SetProtectResultForFd(uint32(fd), uint32(seq), ok != 0)
}

//export SsrvpnStop
func SsrvpnStop() {
	bridge.Stop()
}

//export SsrvpnIsRunning
func SsrvpnIsRunning() C.int {
	if bridge.IsRunning() {
		return 1
	}
	return 0
}

//export SsrvpnVersion
func SsrvpnVersion() *C.char {
	// 报告内嵌 mihomo 内核的真实版本，而不是一个静态产品串：诊断弹窗靠它区分
	// 用户实际跑的是哪一版内核。constant.Version 由 mihomo 自己维护。
	return C.CString("ssrvpn-ohos-mihomo-" + constant.Version)
}

//export SsrvpnLastError
func SsrvpnLastError() *C.char {
	lastErrMu.Lock()
	defer lastErrMu.Unlock()
	return C.CString(lastErrStr)
}

// main() is provided by mihomo's main.go in the same package; with
// -buildmode=c-shared it is never executed, but must exist exactly once.
