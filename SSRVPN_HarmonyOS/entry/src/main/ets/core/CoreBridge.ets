/**
 * 内核桥（NAPI 封装的 ArkTS 侧接口）
 * 移植自 upstream: SSRVPN_Android/lib/services/clash_service_native_bridge.dart
 *                android/.../kotlin/bridge/Bridge.kt
 *
 * 底层由 entry/src/main/cpp (NAPI) 加载 libgojni.so（Mihomo c-shared 内核）实现。
 * ABI（cshared_main.go 导出）：
 *   SsrvpnInit(homeDir, configFile) / SsrvpnStart(configPath, tunFd) /
 *   SsrvpnStop() / SsrvpnIsRunning() / SsrvpnVersion() / SsrvpnLastError()
 */
import native from 'libssrvpn_core_napi.so';
import { AppLogger } from '../commons/utils/AppLogger';

const TAG = 'CoreBridge';
const CORE_LIB = 'libgojni.so';

export class CoreBridgeImpl {
  private loaded: boolean = false;
  private tunFd: number = -1;
  private pendingStart: Promise<boolean> | null = null;

  private ensureLoaded(): boolean {
    if (this.loaded) {
      return true;
    }
    this.loaded = true;
    AppLogger.info(TAG, `${CORE_LIB} bridge module registered`);
    AppLogger.info(TAG, `native module type=${typeof native}, attachTunFd=${typeof native.attachTunFd}, startCore=${typeof native.startCore}`);
    return true;
  }

  /** VpnExtensionAbility 在 TUN 建立后调用：注入 fd */
  async attachTun(fd: number, mtu: number): Promise<boolean> {
    if (!this.ensureLoaded()) {
      return false;
    }
    this.tunFd = -1;
    const attached = native.attachTunFd(fd, mtu);
    if (attached) {
      this.tunFd = fd;
    }
    return attached;
  }

  /** 初始化 Go socket-protect 请求通道。 */
  async initProtect(): Promise<boolean> {
    if (!this.ensureLoaded()) {
      return false;
    }
    return native.initProtect() >= 0;
  }

  /** 非阻塞读取一条 protect 请求 [socketFd, seq]；无请求时 socketFd 为 -1。 */
  readProtectSocketFd(): number[] {
    return native.readProtectSocketFd();
  }

  /** 将 VpnConnection.protect() 的结果回传给 Go bridge。 */
  setProtectResult(ok: boolean): void {
    native.setProtectResult(ok);
  }

  /** 按 seq 精确回传 protect 结果, 唤醒对应拨号协程(旧符号保留兼容)。 */
  setProtectResultForFd(fd: number, seq: number, ok: boolean): void {
    native.setProtectResultForFd(fd, seq, ok);
  }

  /** 启动内核（configPath 为已写入的 Mihomo YAML 文件路径） */
  async startCore(configPath: string): Promise<boolean> {
    if (!this.ensureLoaded()) {
      return false;
    }
    const pending = native.startCore(configPath, this.tunFd);
    this.pendingStart = pending;
    try {
      return await pending;
    } finally {
      if (this.pendingStart === pending) {
        this.pendingStart = null;
      }
    }
  }

  async stopCore(): Promise<void> {
    // Native start runs in a worker: stop only after it settles, otherwise that
    // worker could start a new core after disconnect has already stopped it.
    const pending = this.pendingStart;
    this.tunFd = -1;
    if (pending !== null) {
      try {
        await pending;
      } catch (e) {
        // Even a rejected start needs native rollback.
      }
    }
    native.stopCore();
  }

  async isCoreAlive(): Promise<boolean> {
    return native.isCoreAlive();
  }

  async coreVersion(): Promise<string> {
    return native.coreVersion();
  }

  async lastError(): Promise<string> {
    return native.lastError();
  }
}

export const coreBridge: CoreBridgeImpl = new CoreBridgeImpl();
