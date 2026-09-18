/**
 * VPN 扩展能力：TUN 建立、fd 注入内核、长时任务
 * 移植自 upstream: android/.../SsrvpnVpnService.kt
 *                VpnRouteInstaller.kt / VpnIpv6Config.kt / CoreLivenessMonitor.kt
 *
 * 真实 API（SDK @ohos.net.vpnExtension，API 11+ / 本机 SDK 26）：
 *   vpnExtension.createVpnConnection(context) → VpnConnection
 *   VpnConnection.create(VpnConfig) → Promise<number>（TUN fd）
 * 链路：UI 侧 ConnectionOrchestrator 写好配置文件并通过
 *   startVpnExtensionAbility(want.parameters.configPath) 拉起本能力 →
 *   本能力 onCreate 里 create() 拿到 fd → coreBridge.attachTun(fd) + startCore(configPath)。
 *
 * ⚠️ 生命周期回调名：VpnExtensionAbility 只有 onCreate(want) / onDestroy()，
 *    不存在 onStart/onStop（见 SDK @ohos.app.ability.VpnExtensionAbility.d.ts）。
 *    之前误用 onStart/onStop，系统回调命中基类空实现，TUN/内核从未启动，
 *    表现为 UI 侧 30s 超时报「9090 端口跨进程不可达」。
 *
 * 统一 IPv4-only（项目规格，不提供双栈入口）：isIPv6Accepted=false，TUN 仅安装
 * IPv4 地址与默认路由；内核侧 dns.ipv6=false + disable-ipv6=true 同步关闭，
 * 杜绝 IPv6 绕行使流量泄漏出代理隧道。
 *
 * 隧道存续期间本进程是**网络与恢复的权威**：订阅网络切换、按承载动态调 MTU、
 * 内核崩溃后就地热恢复（必要时升级一次 TUN 重建）、以事件驱动写入 vpn_status.json
 * 供 UI 只读还原真实状态 —— UI 进程被系统回收也不影响 VPN 数据面。
 *
 * 长时任务：本 SDK 无 VPN 模式，使用 TASK_KEEPING（对应 Android 前台服务语义）。
 */
import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import type Want from '@ohos.app.ability.Want';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { coreBridge } from '../core/CoreBridge';
import { AppLogger } from '../commons/utils/AppLogger';
import { NetworkStateListener, NetworkStateWatcher, NetTypes } from '../commons/services/NetworkStateWatcher';
import {
  mtuForNetType, coreRecoveryDelayMs, tunnelRebuildDelayMs,
  MAX_CORE_RECOVERY_ATTEMPTS, MAX_TUNNEL_REBUILDS
} from '../commons/services/VpnRecoveryPolicy';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = 'VpnExtensionAbility';
const VPN_MTU = 1400;
/** TUN 地址/前缀与 bridge/bridge.go 的 Inet4Address 严格一致（对齐 NekoBox 实测格式） */
const TUN_ADDRESS = '172.19.0.1';
const TUN_PREFIX = 30;
const TUN_IFNAME = 'vpn-tun';
const DNS_SERVERS = ['223.5.5.5', '119.29.29.29'];
/** 启动错误回传文件名（写入 configPath 同目录，UI 侧读取真实失败原因） */
const START_ERROR_FILE = 'vpn_start_error.txt';
/** 启动成功标记文件名（内核 API 就绪后写入，UI 侧轮询） */
const START_OK_FILE = 'vpn_start_ok.txt';
/** 兼容旧 UI 的事件状态快照文件，不再周期性写入。 */
const HEARTBEAT_FILE = 'vpn_heartbeat.txt';
/** Extension 主导的权威运行态文件（事件驱动写入，UI 打开时直接读取真实状态）。 */
const STATUS_FILE = 'vpn_status.json';

/** Extension 写入的权威运行态结构。 */
export class VpnRuntimeStatus {
  /** running | recovering | leak-blocked | stopped | failed */
  public phase: string = 'running';
  /** 当前 TUN 使用的 MTU（按物理承载动态）。 */
  public mtu: number = VPN_MTU;
  /** 归一化物理网络类型。 */
  public netType: string = NetTypes.UNKNOWN;
  /** 内核是否存活。 */
  public coreAlive: boolean = true;
  /** 本世代已尝试的 Core 恢复次数。 */
  public recoveryAttempts: number = 0;
  /** 本会话已执行的 TUN 重建次数。 */
  public rebuilds: number = 0;
  /** 递增序列号，供 UI 判定新旧与去重。 */
  public seq: number = 0;
  /** 写入时间戳。 */
  public ts: number = Date.now();
  /** 脱敏说明（绝不含 secret/订阅地址/节点口令）。 */
  public detail: string = '';

  public toJson(): string {
    return `{"phase":"${this.phase}","mtu":${this.mtu},"netType":"${this.netType}","` +
      `"coreAlive":${this.coreAlive ? 'true' : 'false'},"recoveryAttempts":${this.recoveryAttempts},` +
      `"rebuilds":${this.rebuilds},"seq":${this.seq},"ts":${this.ts},"detail":"${this.detail}"}`;
  }
}

export default class SsrvpnVpnExtension extends VpnExtensionAbility implements NetworkStateListener {
  /** 当前 VpnConnection（重入时先 destroy 旧的，避免 2200002 VPN already exist） */
  private connection: vpnExtension.VpnConnection | null = null;
  /** Extension 进程内的权威网络监听器，不依赖 UI 进程存活。 */
  private networkWatcher: NetworkStateWatcher | null = null;
  /** 最近一次物理网络类型与事件代数，用于去重和恢复编排。 */
  private lastNetworkType: string = NetTypes.UNKNOWN;
  private lastNetworkGeneration: number = 0;
  /** Core 存活监控与有界恢复状态。 */
  private coreMonitorTimer: number = -1;
  private recoveryTimer: number = -1;
  /** TUN 重建专用定时器与门控（与内核热恢复互不干扰）。 */
  private rebuildTimer: number = -1;
  private rebuilding: boolean = false;
  private recoveryAttempts: number = 0;
  private recoveryRunning: boolean = false;
  private networkAvailable: boolean = true;
  /** 当前实际 MTU，由网络类型决定并同时传给 TUN 与 native bridge。 */
  private activeMtu: number = VPN_MTU;
  /** 当前会话的 VpnConfig，MTU 变化触发隧道重建时复用其余字段。 */
  private tunConfig: vpnExtension.VpnConfig | null = null;
  /** 本会话已执行的 TUN 重建次数（MTU 变化 / Kill Switch 升级）。 */
  private tunnelRebuilds: number = 0;
  /** Extension 权威运行态序列号，事件每次递增。 */
  private statusSeq: number = 0;
  /** 上次落盘的状态 JSON，用于事件驱动去重（无变化不写盘）。 */
  private lastStatusJson: string = '';
  /** 事件状态快照所在目录（cleanup 时删除兼容快照文件）。 */
  private heartbeatDir: string = '';
  /** Protect socket 请求轮询器，由 Go 核心请求逐 socket 绕过 VPN。 */
  private protectTimer: number = -1;
  /** 后台长时任务是否已启动。 */
  private backgroundRunning: boolean = false;
  /** 统一清理的幂等门控。 */
  private cleanupPromise: Promise<void> | null = null;
  /** 本次会话的配置路径（onDestroy 时删除含 API secret 的 YAML） */
  private configPathForCleanup: string = '';
  /** 该配置是否为临时测速配置（由 UI 侧生成为 mihomo_test_config.yaml） */
  private configIsTransient: boolean = false;

  /**
   * 删除含凭据的运行时配置。每个文件独立容错，缺失即跳过。
   * @param force 内核启动失败/无头测速失败时即使不是临时配置也删除
   */
  private removePrivateConfig(force: boolean): void {
    if (this.configPathForCleanup.length === 0) {
      return;
    }
    if (!force && !this.configIsTransient) {
      return;
    }
    try {
      fs.unlinkSync(this.configPathForCleanup);
    } catch (e) {
      // 已被 UI 侧删除属正常
    }
  }

  /** 判断配置是否为测速用临时文件（UI 侧命名约定） */
  private static isTransientConfig(path: string): boolean {
    return path.endsWith('mihomo_test_config.yaml');
  }

  /** 把扩展进程内的启动失败原因写回 UI 可读的目录（跨进程无法直接共享内存） */
  private reportStartError(configPath: string, message: string): void {
    try {
      const dir = configPath.substring(0, configPath.lastIndexOf('/'));
      const file = fs.openSync(`${dir}/${START_ERROR_FILE}`,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, message);
      } finally {
        // 写入失败也必须释放 fd（此前 writeSync 抛错会泄漏句柄）
        fs.closeSync(file);
      }
    } catch (e) {
      AppLogger.warn(TAG, `write start error file failed: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  /** 写入启动成功标记（内容为时间戳，便于排查） */
  private reportStartOk(configPath: string): void {
    try {
      const dir = configPath.substring(0, configPath.lastIndexOf('/'));
      const file = fs.openSync(`${dir}/${START_OK_FILE}`,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, `${Date.now()}`);
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      AppLogger.warn(TAG, `write start ok file failed: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  private clearStartError(configPath: string): void {
    const dir = configPath.substring(0, configPath.lastIndexOf('/'));
    const targets: string[] = [START_ERROR_FILE, START_OK_FILE, HEARTBEAT_FILE, STATUS_FILE];
    // 逐文件独立容错：一个文件不存在不得阻止其余文件删除
    for (const name of targets) {
      try {
        fs.unlinkSync(`${dir}/${name}`);
      } catch (e) {
        // 文件不存在属正常
      }
    }
  }

  /**
   * 事件驱动写入 Extension 权威运行态。仅在状态真正变化时落盘，避免固定周期写盘；
   * core 监控作为兜底对账（每 10s 最多一次），把恢复进度/MTU/网络类型变化推到 UI。
   */
  private writeStatus(phase: string, coreAlive: boolean, detail: string): void {
    if (this.heartbeatDir.length === 0) {
      return;
    }
    const st = new VpnRuntimeStatus();
    st.phase = phase;
    st.mtu = this.activeMtu;
    st.netType = this.lastNetworkType;
    st.coreAlive = coreAlive;
    st.recoveryAttempts = this.recoveryAttempts;
    st.rebuilds = this.tunnelRebuilds;
    st.seq = ++this.statusSeq;
    st.ts = Date.now();
    st.detail = detail;
    // 存活租约：每次调用都刷新心跳时间戳（低频，仅随 10s 内核监控与状态事件触发），
    // 让 UI 的 15s 陈旧窗口判定继续成立；替代旧版 3s 定周期写盘。
    this.touchLivenessLease(st.ts);
    const text = st.toJson();
    if (text === this.lastStatusJson) {
      return; // 权威态无变化不重复写 STATUS_FILE（事件驱动）
    }
    this.lastStatusJson = text;
    try {
      const file = fs.openSync(`${this.heartbeatDir}/${STATUS_FILE}`,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, text);
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      AppLogger.warn(TAG, `status write failed: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  /** 低频存活租约：仅写一个时间戳到心跳文件，供 UI 判断内核/隧道存活。 */
  private touchLivenessLease(ts: number): void {
    try {
      const hb = fs.openSync(`${this.heartbeatDir}/${HEARTBEAT_FILE}`,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(hb.fd, `${ts}`);
      } finally {
        fs.closeSync(hb);
      }
    } catch (e) {
      AppLogger.warn(TAG, `liveness lease write failed: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  /**
   * 把 mihomo 配置里的 `  mtu: NNNN`（tun 段，恰好 2 空格缩进）改写为当前 activeMtu，
   * 使内核 gvisor 与 VpnConfig.mtu 一致。仅匹配 tun 段的两空格 mtu 行，避免误改
   * 节点级（更深缩进）的 wireguard mtu。改写失败静默忽略（回落配置自带值）。
   */
  private ensureConfigMtu(): void {
    const path = this.configPathForCleanup;
    if (path.length === 0) {
      return;
    }
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE);
      try {
        const buf = new ArrayBuffer(262144);
        const len = fs.readSync(file.fd, buf);
        const text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf, 0, len));
        const patched = text.replace(/^ {2}mtu: \d+$/m, `  mtu: ${this.activeMtu}`);
        if (patched !== text) {
          fs.truncateSync(file.fd, 0);
          fs.writeSync(file.fd, patched);
        }
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      AppLogger.warn(TAG, `config mtu sync skipped: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  /**
   * 隧道建立成功后的事件驱动快照（替代旧版每 3s 心跳写盘）。
   * Core 存活由 Extension 进程直接探测，文件仅供旧 UI 跨进程读取。
   */
  private publishStateSnapshot(configPath: string): void {
    const dir = configPath.substring(0, configPath.lastIndexOf('/'));
    this.heartbeatDir = dir;
    this.writeStatus('running', true, 'tunnel-up');
  }

  /**
   * 排空 Go 内核的逐 fd protect 请求队列, 并发 protect 并按 fd 回执。
   *
   * 语义(v3, 真机双实证): protectProcessNet 在本机对 Go socket 不生效, "先
   * protect 后 connect" 的顺序保证全靠这条通道 —— 必须回执(Go 等自己的 fd 回执
   * 才放行 connect, 上限 800ms, 超时 fail-open)。同时按批排空 + 并发 promise,
   * 杜绝旧版"5s 串行等待→排队超时→会话退役→全线 unavailable"的死亡螺旋。
   */
  private startProtectMonitor(): void {
    this.stopProtectMonitor();
    this.protectTimer = setInterval(() => {
      const connection = this.connection;
      if (connection === null) {
        return;
      }
      for (let i = 0; i < 16; i++) {
        const request: number[] = coreBridge.readProtectSocketFd();
        const fd: number = request[0];
        if (fd < 0) {
          break;
        }
        const seq: number = request[1];
        // protect 失败(fd 已关闭/复用等)也要回执: Go 侧收到回执(含 false)立即放行拨号。
        connection.protect(fd).then(() => {
          coreBridge.setProtectResultForFd(fd, seq, true);
        }).catch(() => {
          coreBridge.setProtectResultForFd(fd, seq, false);
        });
      }
    }, 10);
  }

  private stopProtectMonitor(): void {
    if (this.protectTimer >= 0) {
      clearInterval(this.protectTimer);
      this.protectTimer = -1;
    }
  }

  /** 根据物理承载选择保守 MTU：委托给可离线验证的纯策略函数（单一真值源）。 */
  private mtuForNetwork(netType: string): number {
    return mtuForNetType(netType);
  }

  /** Extension 进程内处理网络变化，不依赖 UI 进程。 */
  onNetworkTypeChanged(netType: string, generation: number): void {
    if (generation <= this.lastNetworkGeneration) {
      return;
    }
    const previous = this.lastNetworkType;
    this.lastNetworkGeneration = generation;
    this.lastNetworkType = netType;
    this.networkAvailable = netType !== NetTypes.NONE;
    const nextMtu = this.mtuForNetwork(netType);
    AppLogger.info(TAG, `extension network changed: ${previous} -> ${netType}, mtu=${nextMtu}`);
    if (!this.networkAvailable) {
      // 断网：保持 TUN 与默认路由（Kill Switch），内核无法拨出即天然阻断泄漏；
      // 取消恢复编排，等待网络恢复事件。
      this.cancelRecovery();
      this.writeStatus('leak-blocked', this.coreAliveGuess(), 'network-lost');
      return;
    }
    if (this.connection === null) {
      return;
    }
    if (nextMtu !== this.activeMtu && this.tunnelRebuilds < MAX_TUNNEL_REBUILDS) {
      // MTU 变化必须重建 TUN 才能生效：这是唯一必要的重建，其余情况只做内核热恢复。
      this.activeMtu = nextMtu;
      this.scheduleTunnelRebuild('mtu-change');
    } else if (previous === NetTypes.NONE || previous !== netType) {
      this.activeMtu = nextMtu;
      this.scheduleCoreRecovery('network-changed');
    }
  }

  /** 无法直接问 native 时，用 running 相位近似内核存活（仅供状态文件呈现）。 */
  private coreAliveGuess(): boolean {
    return this.connection !== null;
  }

  /** 合并短时间内的多次隧道重建请求，指数退避，封顶 MAX_TUNNEL_REBUILDS 次。 */
  private scheduleTunnelRebuild(reason: string): void {
    if (this.rebuilding || this.rebuildTimer >= 0 || this.tunnelRebuilds >= MAX_TUNNEL_REBUILDS) {
      return;
    }
    const delay = tunnelRebuildDelayMs(this.tunnelRebuilds);
    this.tunnelRebuilds = this.tunnelRebuilds + 1;
    this.rebuilding = true;
    AppLogger.warn(TAG, `schedule extension TUN rebuild #${this.tunnelRebuilds} in ${delay}ms (${reason})`);
    this.writeStatus('recovering', false, 'tun-rebuild-scheduled');
    this.rebuildTimer = setTimeout((): void => {
      this.rebuildTimer = -1;
      this.rebuildTunnel(reason).finally((): void => {
        this.rebuilding = false;
      });
    }, delay);
  }

  /** 仅重建 TUN 与内核，保留 Kill Switch 语义；不触碰 UI 进程。 */
  private async rebuildTunnel(reason: string): Promise<void> {
    const config = this.tunConfig;
    if (config === null || this.configPathForCleanup.length === 0) {
      return;
    }
    config.mtu = this.activeMtu;
    let candidate: vpnExtension.VpnConnection | null = null;
    try {
      const old = this.connection;
      this.connection = null;
      // Core 必须先停止并释放其私有 TUN 副本，平台连接随后才能安全销毁。
      try {
        await coreBridge.stopCore();
      } catch (e) {
        AppLogger.warn(TAG, 'core stop before rebuild failed');
      }
      if (old !== null) {
        try {
          await old.destroy();
        } catch (e) {
          AppLogger.warn(TAG, 'old connection destroy failed');
        }
      }

      candidate = vpnExtension.createVpnConnection(this.context);
      const tunFd = await candidate.create(config);
      await candidate.protectProcessNet();
      const attached = await coreBridge.attachTun(tunFd, this.activeMtu);
      if (!attached) {
        throw new Error('内核桥重挂载失败（attachTun）');
      }
      this.ensureConfigMtu();
      const ok = await coreBridge.startCore(this.configPathForCleanup);
      if (!ok) {
        throw new Error(await coreBridge.lastError());
      }

      // 只有 Core 已成功接管后才提交新连接，避免 create/protect/attach/start
      // 任一步失败时局部 VpnConnection 脱离统一清理路径。
      this.connection = candidate;
      candidate = null;
      this.recoveryAttempts = 0;
      // START_OK_FILE 只属于首次启动握手。TUN 重建后的稳态由状态租约证明，
      // 禁止重新生成永久成功标记，避免 UI 把陈旧文件误判为长期存活证据。
      this.writeStatus('running', true, `tun-rebuilt:${reason}`);
      AppLogger.info(TAG, `TUN rebuilt with mtu=${this.activeMtu} (${reason})`);
    } catch (e) {
      // 若 Core 在失败前已部分启动，先停 Core，再销毁尚未提交的平台连接。
      try {
        await coreBridge.stopCore();
      } catch (stopError) {
        AppLogger.warn(TAG, 'core rollback after TUN rebuild failure failed');
      }
      if (candidate !== null) {
        try {
          await candidate.destroy();
        } catch (destroyError) {
          AppLogger.warn(TAG, 'candidate connection rollback failed');
        }
        candidate = null;
      }
      const msg = e instanceof Error ? e.message : String(e);
      AppLogger.warn(TAG, `TUN rebuild failed: ${msg}`);
      this.writeStatus('leak-blocked', false, 'tun-rebuild-failed');
      // 当前 rebuild Promise 的 finally 会先释放 rebuilding 门控。下一事件循环再排重试，
      // 避免 scheduleTunnelRebuild 因 rebuilding=true 直接拒绝本次重试。
      setTimeout((): void => {
        this.scheduleTunnelRebuild('retry');
      }, 0);
    }
  }

  private startNetworkAuthority(): void {
    if (this.networkWatcher === null) {
      this.networkWatcher = new NetworkStateWatcher();
    }
    this.networkWatcher.addListener(this);
    this.networkWatcher.start(this.context);
    this.lastNetworkType = this.networkWatcher.networkType();
    this.lastNetworkGeneration = this.networkWatcher.generation();
    this.networkAvailable = this.lastNetworkType !== NetTypes.NONE;
    this.activeMtu = this.mtuForNetwork(this.lastNetworkType);
  }

  private stopNetworkAuthority(): void {
    this.cancelRecovery();
    if (this.networkWatcher !== null) {
      this.networkWatcher.stop();
      this.networkWatcher = null;
    }
  }

  /** 在 Extension 内直接探测 Core，替代高频文件心跳（10s 低频租约 + 事件驱动状态）。 */
  private startCoreMonitor(): void {
    this.stopCoreMonitor();
    this.coreMonitorTimer = setInterval((): void => {
      if (this.connection === null || this.rebuilding || !this.networkAvailable) {
        return;
      }
      coreBridge.isCoreAlive().then((alive: boolean): void => {
        if (this.connection === null) {
          return;
        }
        if (!alive) {
          // 内核已死：保持 TUN（Kill Switch），进入恢复编排；刷新租约反映当前相位。
          this.writeStatus('recovering', false, 'core-not-alive');
          this.scheduleCoreRecovery('core-not-alive');
          return;
        }
        // 健康：低频刷新存活租约（每 10s 一次，远低于旧版 3s），维持 UI 陈旧窗口判定。
        this.touchLivenessLease(Date.now());
      }).catch((e: Object): void => {
        AppLogger.warn(TAG, `core liveness probe failed: ${e instanceof Error ? e.message : String(e)}`);
      });
    }, 10000);
  }

  private stopCoreMonitor(): void {
    if (this.coreMonitorTimer >= 0) {
      clearInterval(this.coreMonitorTimer);
      this.coreMonitorTimer = -1;
    }
  }

  private cancelRecovery(): void {
    if (this.recoveryTimer >= 0) {
      clearTimeout(this.recoveryTimer);
      this.recoveryTimer = -1;
    }
    if (this.rebuildTimer >= 0) {
      clearTimeout(this.rebuildTimer);
      this.rebuildTimer = -1;
    }
    this.rebuilding = false;
  }

  /** 有界指数退避恢复，只重启 Core，保持 VPN/TUN 与 Kill Switch 路由不被拆除。 */
  private scheduleCoreRecovery(reason: string): void {
    if (this.recoveryRunning || this.recoveryTimer >= 0 || this.rebuilding || this.recoveryAttempts >= MAX_CORE_RECOVERY_ATTEMPTS
      || this.connection === null || !this.networkAvailable) {
      return;
    }
    const delay = coreRecoveryDelayMs(this.recoveryAttempts);
    this.recoveryAttempts = this.recoveryAttempts + 1;
    AppLogger.warn(TAG, `schedule extension core recovery ${this.recoveryAttempts}/${MAX_CORE_RECOVERY_ATTEMPTS} in ${delay}ms (${reason})`);
    this.recoveryTimer = setTimeout((): void => {
      this.recoveryTimer = -1;
      this.recoverCore(reason);
    }, delay);
  }

  private async recoverCore(reason: string): Promise<void> {
    if (this.recoveryRunning || this.connection === null || !this.networkAvailable
      || this.configPathForCleanup.length === 0) {
      return;
    }
    this.recoveryRunning = true;
    try {
      await coreBridge.stopCore();
      this.ensureConfigMtu();
      const ok = await coreBridge.startCore(this.configPathForCleanup);
      if (!ok) {
        throw new Error(await coreBridge.lastError());
      }
      this.recoveryAttempts = 0;
      this.reportStartOk(this.configPathForCleanup);
      this.writeStatus('running', true, `core-recovered:${reason}`);
      AppLogger.info(TAG, `extension core recovered without rebuilding TUN (${reason})`);
    } catch (e) {
      AppLogger.warn(TAG, `extension core recovery failed: ${e instanceof Error ? e.message : String(e)}`);
      // 内核热恢复耗尽 → 升级为一次必要的 TUN 重建（仍是 Kill Switch 内的自愈）。
      if (this.recoveryAttempts >= MAX_CORE_RECOVERY_ATTEMPTS && this.tunnelRebuilds < MAX_TUNNEL_REBUILDS) {
        this.recoveryAttempts = 0;
        this.scheduleTunnelRebuild('core-recovery-exhausted');
      } else {
        this.scheduleCoreRecovery(reason + '-retry');
      }
    } finally {
      this.recoveryRunning = false;
    }
  }

  private cleanupResources(): Promise<void> {
    if (this.cleanupPromise !== null) {
      return this.cleanupPromise;
    }
    this.cleanupPromise = this.cleanupResourcesInternal().finally(() => {
      this.cleanupPromise = null;
    });
    return this.cleanupPromise;
  }

  private async cleanupResourcesInternal(): Promise<void> {
    this.stopCoreMonitor();
    this.stopNetworkAuthority();
    this.stopProtectMonitor();
    // 状态文件清理：删除权威态与兼容心跳文件，防止其他进程在陈旧窗口内把
    // "已断开"误判为"内核还活着"（与 orchestrator.clearTunnelMarkers 双保险）。
    if (this.heartbeatDir.length > 0) {
      const stale: string[] = [HEARTBEAT_FILE, STATUS_FILE];
      for (const name of stale) {
        try {
          fs.unlinkSync(`${this.heartbeatDir}/${name}`);
        } catch (e) {
          // 已被 UI 侧删除属正常
        }
      }
    }
    // 临时测速配置随扩展退出删除（无头测速无 TUN，配置不会被内核长期需要）
    this.removePrivateConfig(false);
    try {
      await coreBridge.stopCore();
    } catch (e) {
      AppLogger.warn(TAG, 'core cleanup failed');
    }
    const connection = this.connection;
    this.connection = null;
    if (connection !== null) {
      try {
        await connection.destroy();
      } catch (e) {
        AppLogger.warn(TAG, 'VPN connection cleanup failed');
      }
    }
    if (this.backgroundRunning) {
      this.backgroundRunning = false;
      try {
        await backgroundTaskManager.stopBackgroundRunning(this.context);
      } catch (e) {
        AppLogger.warn(TAG, 'background task cleanup failed');
      }
    }
  }

  async onCreate(want: Want): Promise<void> {
    AppLogger.info(TAG, 'vpn onCreate');
    // 长时任务（对应 Android 前台服务），失败不阻塞连接流程
    try {
      const entryWant: Want = {
        bundleName: 'com.ssrvpn.client',
        // moduleName 缺失会让 wantAgent 校验失败（16000151 invalid wantAgent），
        // 导致 TASK_KEEPING 永远起不来、扩展进程可被系统回收。
        moduleName: 'entry',
        abilityName: 'EntryAbility'
      };
      const agentRequest: wantAgent.WantAgentInfo = {
        wants: [entryWant],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent = await wantAgent.getWantAgent(agentRequest);
      await backgroundTaskManager.startBackgroundRunning(this.context,
        backgroundTaskManager.BackgroundMode.TASK_KEEPING, agent);
      this.backgroundRunning = true;
      AppLogger.info(TAG, 'background task started (TASK_KEEPING)');
    } catch (e) {
      const err = e as BusinessError;
      // 记录真实错误码：16000151=invalid wantAgent、201=权限被拒、
      // 9800005/其它=系统策略拒绝（例如通知被禁用时长时任务可能被拒）。
      AppLogger.warn(TAG,
        `background task start failed: code=${err.code} msg=${err.message}`);
    }

    const params = want.parameters;
    let headless = (params !== undefined && params !== null)
      && ((params['headless'] as number) === 1);
    let configPath = (params !== undefined && params !== null) ? (params['configPath'] as string) : '';
    if (configPath === undefined || configPath.length === 0) {
      // 自愈：系统冷启动扩展时 want.parameters 可能整体丢失（实测偶发，
      // 表现为 configPath/headless 全空 → 走隧道分支建 TUN → 因找不到配置失败）。
      // 按 mtime 消歧恢复意图：测速配置较新 → headless；隧道配置存在 → 隧道。
      const cacheDir = this.context.cacheDir;
      const testCfg = `${cacheDir}/mihomo_test_config.yaml`;
      const tunCfg = `${cacheDir}/mihomo_config.yaml`;
      let testMtime = -1;
      let tunMtime = -1;
      try {
        testMtime = fs.statSync(testCfg).mtime;
      } catch (e) {
        testMtime = -1;
      }
      try {
        tunMtime = fs.statSync(tunCfg).mtime;
      } catch (e) {
        tunMtime = -1;
      }
      if (testMtime >= tunMtime && testMtime > 0) {
        configPath = testCfg;
        headless = true;
        AppLogger.warn(TAG, 'config params lost; recovered headless test config by mtime');
      } else if (tunMtime > 0) {
        configPath = tunCfg;
        AppLogger.warn(TAG, 'config params lost; recovered tunnel config by mtime');
      } else {
        configPath = tunCfg;
        AppLogger.warn(TAG, 'config path missing; using cache configuration');
      }
    }
    this.configPathForCleanup = configPath;
    this.configIsTransient = SsrvpnVpnExtension.isTransientConfig(configPath);
    this.clearStartError(configPath);

    // 重入防护：Core 仍可能使用旧 TUN fd，必须先同步停止 Core，再销毁平台连接。
    // 反向顺序会让 fd 号在 Core 清理前被系统复用，形成误关新 fd 的竞态。
    try {
      await coreBridge.stopCore();
    } catch (e) {
      // 未启动过时停止属正常
    }
    const previousConnection = this.connection;
    this.connection = null;
    if (previousConnection !== null) {
      try {
        await previousConnection.destroy();
      } catch (e) {
        // 旧连接可能已失效，忽略
      }
    }

    // headless 测速模式(UI 预启动内核做真实协议测速): 不建 TUN、不请求 VPN
    // 授权、不启 protect/心跳 —— 只拉起内核开 127.0.0.1 的 mixed+API 端口。
    // (headless 已在 onCreate 顶部随 configPath 一并解析, 含参数丢失时的 mtime 自愈)
    if (headless) {
      this.runHeadless(configPath);
      return;
    }

    // 建立 Extension 进程内的网络权威：在任何 TUN 参数计算之前读取当前物理承载，
    // 使 MTU、Kill Switch 与恢复编排完全由本进程掌控，UI 进程被回收也不受影响。
    this.startNetworkAuthority();

    // 项目规格要求 IPv4-only：TUN 仅安装 IPv4 地址和默认路由，明确拒绝 IPv6。
    // 这样可以避免 IPv6 流量绕过代理或在无完整 IPv6 代理链路时形成泄漏通道。
    // MTU 按当前物理承载动态取值（蜂窝链路降低分片风险，Wi-Fi/以太网 1400）。
    this.activeMtu = this.mtuForNetwork(this.lastNetworkType);
    const config: vpnExtension.VpnConfig = {
      addresses: [{
        address: { address: TUN_ADDRESS, family: 1 },
        prefixLength: TUN_PREFIX
      }],
      routes: [{
        interface: TUN_IFNAME,
        destination: { address: { address: '0.0.0.0', family: 1 }, prefixLength: 0 },
        gateway: { address: '0.0.0.0', family: 1 },
        hasGateway: false,
        isDefaultRoute: true
      }],
      dnsAddresses: DNS_SERVERS,
      mtu: this.activeMtu,
      isIPv4Accepted: true,
      isIPv6Accepted: false
    };
    this.tunConfig = config;
    AppLogger.info(TAG, `vpn config: IPv4-only, mtu=${this.activeMtu}, net=${this.lastNetworkType}`);

    // ── 应用级分流（两类包名均由 UI 侧逗号拼接传入） ──────────────────────────
    // (a) 强制不走代理的应用: VpnConfig.blockedApplications —— 框架层让这些包名的 App
    //     流量直接走物理网络、不进隧道（刷抖音/微信等不需要代理的 App 不受加速影响）。
    //     包名由 UI 侧 excludedApps 填充。
    // (b) 走代理的应用白名单: VpnConfig.trustedApplications —— 平台字段名就是
    //     trustedApplications（官方文档：配置该列表后**仅**列表内的应用数据才按 routes
    //     被 VPN 代理；SDK API 24 的 VpnConfig 里**没有** allowedApplications 字段）。
    //     包名由 UI 侧 includedApps 填充；空 = 不下发 = 黑名单模式（行为与旧版本一致）。
    // 平台约束：trustedApplications 与 blockedApplications **不能同时配置**，因此白名单
    // 生效时不下发 blockedApplications，改用「差集」表达 blocked 优先：两个列表都填了的
    // 包会被从白名单里剔除（= 白名单内仍然直连）。
    // 解析容错：params 为 undefined/null、字段缺失、空串、多余逗号、重复项。
    const bypassRaw = (params !== undefined && params !== null) ? (params['bypassPackages'] as string) : '';
    const blockedPkgs: string[] = [];
    if (bypassRaw !== undefined && bypassRaw !== null && bypassRaw.length > 0) {
      for (const p of bypassRaw.split(',')) {
        const t = p.trim();
        if (t.length > 0 && blockedPkgs.indexOf(t) < 0) {
          blockedPkgs.push(t);
        }
      }
    }
    const proxyRaw = (params !== undefined && params !== null) ? (params['proxyPackages'] as string) : '';
    const allowPkgs: string[] = [];
    if (proxyRaw !== undefined && proxyRaw !== null && proxyRaw.length > 0) {
      for (const p of proxyRaw.split(',')) {
        const t = p.trim();
        if (t.length > 0 && allowPkgs.indexOf(t) < 0) {
          allowPkgs.push(t);
        }
      }
    }
    // blocked 优先：从白名单里剔除同时出现在 blocked 列表里的包
    const effectiveAllow: string[] = [];
    for (const p of allowPkgs) {
      if (blockedPkgs.indexOf(p) < 0) {
        effectiveAllow.push(p);
      }
    }
    if (effectiveAllow.length > 0) {
      // 平台上限（API 23 起 256 个；更低版本 64），超限直接下发可能导致 create 失败
      const capped = effectiveAllow.length > 256 ? effectiveAllow.slice(0, 256) : effectiveAllow;
      config.trustedApplications = capped;
      AppLogger.info(TAG, `trustedApplications configured(whitelist): count=${capped.length}` +
        ` (input=${allowPkgs.length}, blocked-overlap=${allowPkgs.length - effectiveAllow.length}` +
        `${capped.length !== effectiveAllow.length ? ', truncated' : ''})`);
      if (blockedPkgs.length > 0) {
        AppLogger.info(TAG, `blockedApplications skipped in whitelist mode: count=${blockedPkgs.length}` +
          ' (VpnConfig: trusted/blocked 互斥, 已用白名单差集表达 blocked 优先)');
      }
    } else if (blockedPkgs.length > 0) {
      // 黑名单模式（无白名单 / 白名单被 blocked 完全抵消 → 回落旧行为）
      if (allowPkgs.length > 0) {
        AppLogger.info(TAG, `proxyPackages fully cancelled by blockedApplications: count=${allowPkgs.length}, fallback to blocklist mode`);
      }
      config.blockedApplications = blockedPkgs;
      AppLogger.info(TAG, `blockedApplications configured: count=${blockedPkgs.length}`);
    }

    try {
      this.connection = vpnExtension.createVpnConnection(this.context);
      const tunFd = await this.connection.create(config);
      AppLogger.info(TAG, 'TUN created');

      // 同时启用进程级保护与逐 socket Protect 通道，避免出站流量回灌 TUN。
      await this.connection.protectProcessNet();
      AppLogger.info(TAG, 'protectProcessNet enabled');

      const attached = await coreBridge.attachTun(tunFd, this.activeMtu);
      if (!attached) {
        throw new Error('内核桥加载失败（attachTun）');
      }
      const protectReady = await coreBridge.initProtect();
      if (!protectReady) {
        throw new Error('内核 Protect 通道初始化失败');
      }
      this.startProtectMonitor();

      // 内核 gvisor 的 MTU 必须与 VpnConfig.mtu 一致：启动前把配置里的 tun.mtu 对齐。
      this.ensureConfigMtu();
      // startCore 在线程池执行，ArkTS 事件循环持续处理 Protect 请求。
      const ok = await coreBridge.startCore(configPath);
      AppLogger.info(TAG, `core start result: ${ok}`);
      if (!ok) {
        const coreErr = await coreBridge.lastError();
        throw new Error(coreErr.length > 0 ? coreErr : '内核启动失败（未知原因）');
      }
      this.reportStartOk(configPath);
      this.publishStateSnapshot(configPath);
      this.startCoreMonitor();
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      this.reportStartError(configPath, `VPN 扩展启动异常: ${msg}`);
      AppLogger.error(TAG, `vpn onCreate failed: ${msg}`);
      // 启动失败即为本次会话终结：删掉含 API secret 的配置，避免凭据滞留磁盘
      this.removePrivateConfig(true);
      await this.cleanupResources();
    }
  }

  /** headless 测速内核: 仅 startCore + 回写启动结果标记, 失败走同一错误通道 */
  private async runHeadless(configPath: string): Promise<void> {
    try {
      AppLogger.info(TAG, 'headless test-core starting (no TUN / no VPN permission)');
      const ok = await coreBridge.startCore(configPath);
      if (!ok) {
        const coreErr = await coreBridge.lastError();
        throw new Error(coreErr.length > 0 ? coreErr : 'headless 内核启动失败');
      }
      this.reportStartOk(configPath);
      AppLogger.info(TAG, 'headless test-core started');
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      this.reportStartError(configPath, `测速内核启动失败: ${msg}`);
      AppLogger.error(TAG, `headless start failed: ${msg}`);
      // 失败路径不留残余：删除测速配置与启动标记文件
      this.clearStartError(configPath);
      this.removePrivateConfig(true);
      await this.cleanupResources();
    }
  }

  onDestroy(): void {
    AppLogger.info(TAG, 'vpn onDestroy');
    this.cleanupResources().catch((e: Error) => {
      AppLogger.warn(TAG, `vpn onDestroy cleanup failed: ${e instanceof Error ? e.message : String(e)}`);
    });
  }
}
