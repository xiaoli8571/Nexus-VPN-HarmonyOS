/**
 * 连接编排器：管理连接状态机、VPN 能力拉起、Clash API 就绪等待
 * 移植自 upstream: SSRVPN_Android/lib/services/connection_orchestrator.dart
 *                packages/ssrvpn_shared/lib/utils/connection_intent_tracker.dart
 *                connection_transition_queue.dart / core_recovery_policy.dart
 *
 * 链路（API 26 实测形态）：
 *   connect() → 写 Mihomo YAML 到 cacheDir → startVpnExtensionAbility(want.parameters.configPath)
 *   → VpnExtensionAbility：create() 得到 TUN fd → coreBridge.attachTun + startCore
 *   → 本编排器轮询 Clash API 就绪 → selectNode → CONNECTED
 */
import { vpnExtension, http } from '@kit.NetworkKit';
import type Want from '@ohos.app.ability.Want';
import { fileIo as fs } from '@kit.CoreFileKit';
import { notificationManager } from '@kit.NotificationKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { coreBridge } from '../../core/CoreBridge';
import { ClashApiService, TrafficSnapshot } from './ClashApiService';
import { ClashConfigGenerator } from './ClashConfigGenerator';
import { Ipv6Detector } from './Ipv6Detector';
import { DoHResolver } from './DoHResolver';
import { SubscriptionService } from './SubscriptionService';
import { SubscriptionRefreshStatus } from '../models/Subscription';
import { SettingsService, ConnectionSnapshot } from './SettingsService';
import { SsrvpnNotifier } from './SsrvpnNotifier';
import { TunnelAuthorityState, resolveAuthority } from './TunnelAuthority';
import {
  MAX_STATE_FILE_BYTES, PRIVATE_TEST_CONFIG_FILE,
  SyncReadResult, clearPrivateArtifacts, heartbeatAgeFromText
} from './RuntimeFilePolicy';
import { ensurePrivateDir, privateFs } from './PrivateFileStore';
import { SingleFlightTestCore, TestCoreStatus } from './TestCoreFlight';
import { NetworkStateWatcher, NetworkStateListener, NetTypes } from './NetworkStateWatcher';
import {
  LinkHealthReport, LinkHealthSummary, runLinkHealthCheck, summarize, repairSteps, RepairActions
} from './LinkHealthChecker';
import { OrchestratorHealthProbes, OrchestratorHealthView } from './OrchestratorHealthProbes';
import { NodeSortSnapshot, NodeLatencyRecord } from './NodeSortPersistence';
import {
  NodeCandidate, SelectorOptions, nextBestNode, failoverAllowed, LATENCY_UNTESTED, LATENCY_FAILED
} from './SmartSelector';
import { AppSettings, AutoSelectModes } from '../models/AppSettings';
import { ProxyNode } from '../models/ProxyNode';
import { AppDiagnostics } from '../models/PublicIpInfo';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'ConnectionOrchestrator';
const MIXED_PORT = 7890;
const API_PORT = 9090;
const CONFIG_FILE = 'mihomo_config.yaml';
const START_ERROR_FILE = 'vpn_start_error.txt';
const START_OK_FILE = 'vpn_start_ok.txt';
/** 扩展进程心跳文件（内核运行期间每 3s 覆写时间戳） */
const HEARTBEAT_FILE = 'vpn_heartbeat.txt';
/** 心跳超过该时长视为内核死亡（ms） */
const HEARTBEAT_STALE_MS = 15000;
/** 同一状态同步周期内复用文件探针，避免 heartbeat/start-ok 被重复同步读取。 */
const STATE_PROBE_CACHE_MS = 120;
/** API readiness 快速起步并有上限退避，总超时仍由调用方 deadline 决定。 */
const READINESS_INITIAL_DELAY_MS = 40;
const READINESS_MAX_DELAY_MS = 300;
/** Two-second traffic sampling reduces /connections allocations and UI redraws. */
const TRAFFIC_POLL_INTERVAL_MS = 2000;
/** 测速内核停扩展的重试次数与间隔：停失败必须重试，或至少让下次启动能正确重建 */
const TEST_CORE_STOP_ATTEMPTS = 2;
const TEST_CORE_STOP_RETRY_DELAY_MS = 300;
/** 测速内核启动失败后的负缓存冷却：避免每次测速都白等一次 15~20s 启动超时 */
const TEST_CORE_NEGATIVE_COOLDOWN_MS = 45000;

export function nextReadinessDelayMs(currentMs: number): number {
  if (currentMs <= 0) {
    return READINESS_INITIAL_DELAY_MS;
  }
  return Math.min(currentMs * 2, READINESS_MAX_DELAY_MS);
}

export enum ConnState {
  DISCONNECTED = 0,
  CONNECTING = 1,
  CONNECTED = 2,
  DISCONNECTING = 3,
  RECOVERING = 4
}

/** 重连运行态（只读快照，供第三轮 UI 展示） */
export class ReconnectRuntimeState {
  /** 是否有挂起的重连定时器 */
  active: boolean = false;
  /** 是否正在执行重连（单航班） */
  connecting: boolean = false;
  /** 已发起的重连尝试次数 */
  attempts: number = 0;
  /** 最大尝试次数 */
  maxAttempts: number = 3;
  /** 下一次重连的退避延迟（ms） */
  pendingDelayMs: number = 0;
  /** 触发原因（network-changed / network-restored / ...） */
  reason: string = '';
  /** 当前网络类型 */
  networkType: string = 'unknown';
  /** 网络事件代数 */
  networkGeneration: number = 0;
  /** 网络监听是否已订阅 */
  watcherSubscribed: boolean = false;
}

/** 单个修复动作的执行结果（内部结构） */
class RepairOutcome {
  text: string = '';
  /** 是否执行了重建/重连 */
  usedReconnect: boolean = false;
  /** 是否应终止后续修复（需要用户介入） */
  stop: boolean = false;
}

/** 网络类型变化重建连的退避基准（ms）：1s/2s/4s/8s */
const RECONNECT_BASE_MS: number = 1000;
/** 退避上限（ms），可经 setReconnectBackoffMax 覆盖 */
const RECONNECT_MAX_MS: number = 8000;
/** 网络切换触发的最大重连尝试次数 */
const RECONNECT_MAX_ATTEMPTS: number = 3;

export class ConnectionOrchestrator implements NetworkStateListener, OrchestratorHealthView {
  /**
   * 进程级单例: 每个页面必须共享同一个 orchestrator 实例。
   * 此前各页面各 new 一个, 新实例 state 永远是 DISCONNECTED —— 切换页面时
   * 主页 onPageShow 误判"未连接"触发重连, 且 connect() 每次生成新 API secret,
   * 其他页面持有的旧 secret 全部 401(延迟测试"超时"的根因)。
   */
  private static shared: ConnectionOrchestrator | null = null;

  static instance(): ConnectionOrchestrator {
    if (ConnectionOrchestrator.shared === null) {
      ConnectionOrchestrator.shared = new ConnectionOrchestrator();
    }
    return ConnectionOrchestrator.shared;
  }

  state: ConnState = ConnState.DISCONNECTED;
  traffic: TrafficSnapshot = { uploadBytes: 0, downloadBytes: 0, uploadSpeed: 0, downloadSpeed: 0 };
  publicIp: string = '';
  startedAt: number = 0;
  lastError: string = '';
  api: ClashApiService = new ClashApiService();
  /** 本次连接是否启用 IPv6 入站（连接时探测, 无 IPv6 环境自动绕过） */
  ipv6Active: boolean = false;
  private monitorTimer: number = -1;
  private trafficTimer: number = -1;
  /** Prevent overlapping requests when a traffic poll is slow. */
  private trafficPollRunning: boolean = false;
  private connectSeq: number = 0; // 启动代际门控（对应 StartGenerationGate）
  /** 连接期间收到的断开意图。requestDisconnect 会立即使旧连接代际失效。 */
  private disconnectRequested: boolean = false;
  /** 重复 Form 事件复用同一停止 Promise，避免重复停止扩展和 native core。 */
  private disconnectTask: Promise<void> | null = null;
  private context: Context | null = null;
  private apiSecret: string = '';
  private stateProbeCachedAt: number = 0;
  private stateProbeStartOk: boolean = false;
  private stateProbeHeartbeatAge: number = -1;
  private lastSubs: SubscriptionService | null = null;
  private lastNode: ProxyNode | null = null;
  private recoveryAttempts: number = 0; // 内核恢复退避计数（对应 core_recovery_policy）
  private lastNodeName: string = '';

  // ── 第二阶段：网络切换感知 → 退避智能重连 ──────────────────────────
  private netWatcher: NetworkStateWatcher | null = null;
  /** 上一次已上报的网络类型（'' = 尚未建立基线） */
  private lastNetType: string = '';
  /** 上一次处理过的网络事件代数（防重复处理） */
  private lastNetGeneration: number = -1;
  private reconnectTimer: number = -1;
  private reconnectAttempts: number = 0;
  private reconnectReasonText: string = '';
  private reconnectPendingDelayMs: number = 0;
  private reconnectMaxMs: number = RECONNECT_MAX_MS;
  private readonly reconnectMaxAttempts: number = RECONNECT_MAX_ATTEMPTS;

  // ── 第二阶段：链路自检 → 有限自动修复 ──────────────────────────────
  private healthReport: LinkHealthReport | null = null;
  private healthSummaryCache: LinkHealthSummary | null = null;
  private healthRepairCache: string[] = [];
  private healthRunning: boolean = false;
  private coreLossHandling: boolean = false;
  private inRepairConnect: boolean = false;

  // ── 第二阶段：连续失败 → 自动切换节点 ──────────────────────────────
  private failoverRunning: boolean = false;
  private lastFailoverAt: number = 0;
  private lastFailoverFrom: string = '';
  private lastFailoverTo: string = '';
  private autoSwitchReasonText: string = '';

  listeners: (() => void)[] = [];
  addListener(listener: () => void): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  removeListener(listener: () => void): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  notify(): void {
    for (const l of this.listeners) {
      l();
    }
  }

  init(context: Context): void {
    this.context = context;
    this.invalidateStateProbeCache();
    // 第二阶段集成点①：进程级启动网络状态监听（幂等，失败静默降级）
    this.startNetworkWatch();
  }

  requestDisconnect(): void {
    this.invalidateStateProbeCache();
    this.disconnectRequested = true;
    this.connectSeq = this.connectSeq + 1;
    // 用户主动断开 → 取消一切挂起的退避重连（禁止重连风暴）
    this.reconnectAttempts = 0;
    this.cancelReconnect('user-disconnect');
  }

  isDisconnectRequested(): boolean {
    return this.disconnectRequested;
  }

  /**
   * 隧道是否存活。优先看进程内状态; 进程新起(单例状态丢失)时以扩展进程
   * 心跳文件为准 —— 供桌面快捷方式/服务卡片等无页面入口判断"已连接"。
   */
  isTunnelAlive(): boolean {
    if (this.state === ConnState.CONNECTED || this.state === ConnState.CONNECTING) {
      return true;
    }
    return this.context !== null && this.isCoreAliveByHeartbeat();
  }

  /** 心跳文件年龄；-1 = 无心跳/读取失败（对外暴露供权威状态与专项验证使用） */
  heartbeatAgeMs(): number {
    return this.readHeartbeatAge();
  }

  /** 隧道存活标记：内核成功启动后由扩展进程写入（当前复用 START_OK_FILE 语义） */
  tunnelMarkerExists(): boolean {
    return this.readStartOk();
  }

  /**
   * 权威状态：唯一真值 = 持久化用户意图(desiredConnected) ∧ 内核存活证据。
   * 卡片/通知/页面一律以此为"已连接"判据，绝不再各自依赖易漂移的进程内 state。
   * 需要 await 读取 preferences；调用方在异步上下文使用。
   */
  async authorityState(): Promise<TunnelAuthorityState> {
    let desired = false;
    try {
      const snap = await SettingsService.loadSnapshot();
      desired = snap.desiredConnected;
    } catch (e) {
      desired = false;
    }
    const state = resolveAuthority(desired, this.readHeartbeatAge(), this.readStartOk());
    // 进程内已确认为连接中/恢复中时，仍以内存态优先（避免广播空窗期闪烁）
    if (this.state === ConnState.CONNECTED && state.coreAlive) {
      state.connected = true;
      state.reason = 'core-alive';
    }
    return state;
  }

  /**
   * 权威判定"是否已连接"。内核退出/心跳超时后立即返回 false —— 卡片随即
   * 更新为已断开（修复卡片长期停留在「已连接」的核心）。
   */
  async isAuthoritativelyConnected(): Promise<boolean> {
    const state = await this.authorityState();
    return state.connected;
  }

  /** 配置变更后自动重启隧道：仅当前处于已连接/连接中时才断开并用同一节点重连
   *  （重连会重新生成含新 mode/规则/hosts 的 YAML 并重建带新 blockedApplications 的 TUN）。
   *  未连接时不动 —— 下次手动连接自然带上最新配置。 */
  private restarting: boolean = false;
  async restartIfConnected(reason: string): Promise<boolean> {
    if (this.state !== ConnState.CONNECTED && this.state !== ConnState.CONNECTING) {
      return false;
    }
    if (this.restarting) {
      return false; // 已有重启在途, 忽略重复触发(防抖)
    }
    const subs = this.lastSubs;
    const node = this.lastNode;
    if (subs === null || node === null) {
      return false;
    }
    this.restarting = true;
    AppLogger.info(TAG, `auto-restart (${reason}): 断开并重连以应用新配置`);
    try {
      await this.disconnect();
      await new Promise<void>((resolve) => setTimeout(() => resolve(), 600));
      const ok = await this.connect(node, subs);
      AppLogger.info(TAG, `auto-restart (${reason}) 完成, 结果=${ok}`);
      return ok;
    } finally {
      this.restarting = false;
    }
  }

  /** 运行时切换代理模式：模式写在 YAML 里, 需重建隧道生效(自动断开重连)。 */
  async applyProxyMode(mode: string): Promise<void> {
    await this.restartIfConnected('proxyMode=' + mode);
  }

  // ══════════════════════════════════════════════════════════════════
  // 第二阶段集成点①：网络切换感知 → 指数退避 + 单航班 + 最大次数重连
  // ══════════════════════════════════════════════════════════════════

  /** 启动网络状态监听（幂等）。register 失败只降级，不影响主流程。 */
  startNetworkWatch(): void {
    if (this.context === null) {
      return;
    }
    if (this.netWatcher === null) {
      this.netWatcher = new NetworkStateWatcher();
    }
    // addListener 幂等（watcher 内部按引用去重），确保 stop 后再 start 仍能收到回调
    this.netWatcher.addListener(this);
    if (!this.netWatcher.isSubscribed()) {
      const ok = this.netWatcher.start(this.context);
      // 建立基线：首个事件（prev=''）只记录不触发重连
      this.lastNetType = this.netWatcher.networkType();
      this.lastNetGeneration = this.netWatcher.generation();
      AppLogger.info(TAG, `[reconnect] network watcher start=${ok} subscribed=${this.netWatcher.isSubscribed()} type=${this.lastNetType}`);
    }
  }

  /** 停止网络状态监听并彻底解绑 */
  stopNetworkWatch(): void {
    if (this.netWatcher !== null) {
      this.netWatcher.stop();
    }
    this.cancelReconnect('watch-stopped');
  }

  /** 退避上限可配（ms） */
  setReconnectBackoffMax(ms: number): void {
    this.reconnectMaxMs = ms > 0 ? ms : RECONNECT_MAX_MS;
  }

  /**
   * NetworkStateListener 回调。
   * 只对「物理网络类型」之间的真实切换做响应；UNKNOWN（多为本应用自身 TUN 承载）
   * 一律忽略，避免 VPN 起来后自触发重连风暴。
   */
  onNetworkTypeChanged(netType: string, generation: number): void {
    try {
      if (generation <= this.lastNetGeneration) {
        return; // 同一代际重复回调，忽略
      }
      this.lastNetGeneration = generation;
      const prev = this.lastNetType;
      this.lastNetType = netType;
      AppLogger.info(TAG, `[reconnect] net change gen=${generation} ${prev.length === 0 ? '(init)' : prev} -> ${netType}`);
      if (netType === NetTypes.NONE) {
        AppLogger.info(TAG, '[reconnect] network lost; wait for recovery (no reconnect)');
        return;
      }
      if (!this.isPhysicalNetType(netType) || !this.isPhysicalNetType(prev)) {
        AppLogger.info(TAG, `[reconnect] ignore non-physical transition ${prev} -> ${netType}`);
        return;
      }
      if (prev.length === 0) {
        AppLogger.info(TAG, '[reconnect] baseline recorded, no action');
        return;
      }
      if (prev === netType) {
        return;
      }
      const restored = prev === NetTypes.NONE;
      this.requestReconnect(restored ? 'network-restored' : 'network-changed');
    } catch (e) {
      AppLogger.warn(TAG, `[reconnect] listener error: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  private isPhysicalNetType(t: string): boolean {
    return t === NetTypes.NONE || t === NetTypes.WIFI
      || t === NetTypes.CELLULAR || t === NetTypes.ETHERNET;
  }

  /** 请求一次（可能退避延后的）重连；单航班：已有挂起定时器则合并 */
  private requestReconnect(reason: string): void {
    this.evaluateIntentThenSchedule(reason);
  }

  private async evaluateIntentThenSchedule(reason: string): Promise<void> {
    if (this.disconnectRequested) {
      AppLogger.info(TAG, `[reconnect] user-disconnected; skip (${reason})`);
      return;
    }
    const intent = await this.isUserIntentConnected();
    if (!intent) {
      AppLogger.info(TAG, `[reconnect] intent=disconnected; skip (${reason})`);
      return;
    }
    if (this.reconnectTimer >= 0) {
      AppLogger.info(TAG, `[reconnect] already scheduled; coalesce (${reason})`);
      return;
    }
    if (this.state === ConnState.CONNECTING) {
      AppLogger.info(TAG, `[reconnect] connect in flight; skip (${reason})`);
      return;
    }
    if (this.reconnectAttempts >= this.reconnectMaxAttempts) {
      AppLogger.warn(TAG, `[reconnect] max attempts(${this.reconnectMaxAttempts}) reached; give up (${reason})`);
      this.lastError = '网络切换后自动重连多次失败，已停止自动重试';
      this.notify();
      return;
    }
    const attempt = this.reconnectAttempts;
    let delay = this.reconnectMaxMs;
    const scaled = RECONNECT_BASE_MS * Math.pow(2, attempt);
    if (scaled < delay) {
      delay = scaled;
    }
    this.reconnectAttempts = this.reconnectAttempts + 1;
    this.reconnectReasonText = reason;
    this.reconnectPendingDelayMs = delay;
    AppLogger.info(TAG, `[reconnect] schedule attempt ${this.reconnectAttempts}/${this.reconnectMaxAttempts} in ${delay}ms (${reason})`);
    this.notify();
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1;
      this.reconnectPendingDelayMs = 0;
      this.runScheduledReconnect(reason);
    }, delay);
  }

  private async runScheduledReconnect(reason: string): Promise<void> {
    if (this.disconnectRequested) {
      AppLogger.info(TAG, '[reconnect] cancelled by user disconnect before attempt');
      this.reconnectAttempts = 0;
      this.notify();
      return;
    }
    const subs = this.lastSubs;
    if (subs === null || this.lastNodeName.length === 0) {
      AppLogger.warn(TAG, '[reconnect] no previous endpoint; abort');
      return;
    }
    const intent = await this.isUserIntentConnected();
    if (!intent) {
      AppLogger.info(TAG, '[reconnect] intent disconnected; abort');
      this.reconnectAttempts = 0;
      return;
    }
    if (this.state === ConnState.CONNECTING) {
      AppLogger.info(TAG, '[reconnect] connect in flight; abort'); // 单航班
      return;
    }
    const node = this.findNodeByName(subs, this.lastNodeName);
    if (node === null) {
      AppLogger.warn(TAG, '[reconnect] node not found; abort');
      return;
    }
    AppLogger.info(TAG, `[reconnect] attempt ${this.reconnectAttempts}/${this.reconnectMaxAttempts} (${reason})`);
    const ok = await this.connect(node, subs);
    if (ok) {
      AppLogger.info(TAG, `[reconnect] success (${reason})`);
      this.reconnectAttempts = 0;
      this.cancelReconnect('reconnected');
      return;
    }
    AppLogger.warn(TAG, `[reconnect] attempt failed (${reason})`);
    if (this.disconnectRequested) {
      this.reconnectAttempts = 0;
      return;
    }
    if (this.reconnectAttempts < this.reconnectMaxAttempts) {
      this.requestReconnect(reason + '-retry');
    } else {
      this.lastError = '网络切换后自动重连失败（已达最大尝试次数）';
      this.notify();
    }
  }

  private cancelReconnect(reason: string): void {
    if (this.reconnectTimer >= 0) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
      this.reconnectPendingDelayMs = 0;
      AppLogger.info(TAG, `[reconnect] timer cancelled (${reason})`);
    }
  }

  /** 用户连接意图（进程内状态优先，否则读持久化快照） */
  private async isUserIntentConnected(): Promise<boolean> {
    if (this.disconnectRequested) {
      return false;
    }
    if (this.state === ConnState.CONNECTED || this.state === ConnState.CONNECTING
      || this.state === ConnState.RECOVERING) {
      return true;
    }
    try {
      const snap = await SettingsService.loadSnapshot();
      return snap.desiredConnected;
    } catch (e) {
      return false;
    }
  }

  // ── 只读访问器（供第三轮 UI 读取，无副作用） ──────────────────────

  /** 当前网络类型（watcher 视图） */
  currentNetworkType(): string {
    return this.netWatcher === null ? NetTypes.UNKNOWN : this.netWatcher.networkType();
  }

  /** 网络事件代数 */
  networkGeneration(): number {
    return this.netWatcher === null ? 0 : this.netWatcher.generation();
  }

  /** 网络监听是否已订阅 */
  isNetworkWatcherSubscribed(): boolean {
    return this.netWatcher !== null && this.netWatcher.isSubscribed();
  }

  /** 重连运行态快照 */
  reconnectState(): ReconnectRuntimeState {
    const r = new ReconnectRuntimeState();
    r.active = this.reconnectTimer >= 0;
    r.connecting = this.state === ConnState.CONNECTING;
    r.attempts = this.reconnectAttempts;
    r.maxAttempts = this.reconnectMaxAttempts;
    r.pendingDelayMs = this.reconnectPendingDelayMs;
    r.reason = this.reconnectReasonText;
    r.networkType = this.currentNetworkType();
    r.networkGeneration = this.networkGeneration();
    r.watcherSubscribed = this.isNetworkWatcherSubscribed();
    return r;
  }

  // ══════════════════════════════════════════════════════════════════
  // 第二阶段集成点②：链路自检 → 有限自动修复（自检报告缓存供 UI）
  // ══════════════════════════════════════════════════════════════════

  /** 最近一次自检报告（可读，供 UI）；从未自检为 null */
  lastHealthReport(): LinkHealthReport | null {
    return this.healthReport;
  }

  /** 最近一次自检汇总 */
  lastHealthSummary(): LinkHealthSummary | null {
    return this.healthSummaryCache;
  }

  /** 最近一次自检推导出的修复动作序列 */
  healthRepairStepsLast(): string[] {
    return this.healthRepairCache.slice();
  }

  /** 是否正在执行自检/修复 */
  isHealthCheckRunning(): boolean {
    return this.healthRunning;
  }

  /**
   * 自检 + 有限修复一条龙。
   * 顺序：先跑一次自检 → 缓存报告 → 按 repairSteps(受 healthRepairMaxSteps 限制)
   * 顺序执行修复 → 重新自检一次；仍失败则以明确原因结束，不再盲目重试。
   * @returns 最终是否恢复为已连接
   */
  private async runHealthSelfCheckAndRepair(reason: string): Promise<boolean> {
    if (this.healthRunning) {
      AppLogger.info(TAG, `[health] already running; skip (${reason})`);
      return this.state === ConnState.CONNECTED;
    }
    let settings: AppSettings;
    try {
      settings = await SettingsService.load();
    } catch (e) {
      settings = new AppSettings();
    }
    if (!settings.healthCheckEnabled) {
      AppLogger.info(TAG, `[health] disabled by settings; skip (${reason})`);
      return false;
    }
    this.healthRunning = true;
    try {
      AppLogger.info(TAG, `[health] self-check start (reason=${reason})`);
      const report = await runLinkHealthCheck(new OrchestratorHealthProbes(this));
      this.healthReport = report;
      const summary = summarize(report);
      this.healthSummaryCache = summary;
      AppLogger.info(TAG, `[health] report overall=${summary.overall} pass=${summary.passCount} fail=${summary.failCount} skip=${summary.skipCount} firstFail=${summary.firstFailId}`);
      this.notify();

      const steps = repairSteps(report, settings.healthRepairMaxSteps);
      this.healthRepairCache = steps;
      AppLogger.info(TAG, `[health] repair steps(max=${settings.healthRepairMaxSteps})=${steps.length === 0 ? '(none)' : steps.join(' > ')}`);
      let reconnectUsed = false;
      for (const step of steps) {
        if (this.disconnectRequested) {
          AppLogger.info(TAG, '[health] user disconnected; abort repair chain');
          break;
        }
        const r = await this.executeRepair(step, reconnectUsed);
        if (r.usedReconnect) {
          reconnectUsed = true;
        }
        AppLogger.info(TAG, `[health] repair ${step}: ${r.text}`);
        if (r.stop) {
          AppLogger.warn(TAG, `[health] repair halted: ${r.text}`);
          break;
        }
      }

      // 修复后重新自检一次
      const report2 = await runLinkHealthCheck(new OrchestratorHealthProbes(this));
      this.healthReport = report2;
      const summary2 = summarize(report2);
      this.healthSummaryCache = summary2;
      AppLogger.info(TAG, `[health] recheck overall=${summary2.overall} pass=${summary2.passCount} fail=${summary2.failCount} skip=${summary2.skipCount}`);
      this.notify();
      if (summary2.isOk()) {
        return true;
      }
      if (this.state === ConnState.CONNECTED) {
        AppLogger.info(TAG, '[health] degraded but connected; treat as recovered');
        return true;
      }
      this.lastError = summary2.failCount > 0
        ? `链路自检未通过（${summary2.firstFailLabel}：${summary2.firstFailDetail}）`
        : '链路自检未通过（存在无法判定项），已停止自动重试';
      AppLogger.warn(TAG, `[health] still broken after repair: ${this.lastError}`);
      return false;
    } catch (e) {
      AppLogger.warn(TAG, `[health] self-check failed: ${e instanceof Error ? e.message : String(e)}`);
      return false;
    } finally {
      this.healthRunning = false;
    }
  }

  /** 执行单个修复动作（有限、有序；重建类动作全链路最多一次） */
  private async executeRepair(action: string, reconnectUsed: boolean): Promise<RepairOutcome> {
    const r = new RepairOutcome();
    switch (action) {
      case RepairActions.REFRESH_SUBSCRIPTION: {
        const subs = this.lastSubs;
        if (subs === null) {
          r.text = '无订阅可刷新';
          r.stop = true;
          return r;
        }
        let okCount = 0;
        let failedCount = 0;
        const failedStatuses: string[] = [];
        for (const s of subs.subscriptions) {
          try {
            const result = await subs.refreshSubscription(s.id);
            if (result.status === SubscriptionRefreshStatus.OK
              || result.status === SubscriptionRefreshStatus.NOT_MODIFIED) {
              okCount = okCount + 1;
            } else {
              failedCount = failedCount + 1;
              failedStatuses.push(result.status);
              AppLogger.warn(TAG, `[health] refresh ${s.name} failed: ${result.status} ${result.message}`);
            }
          } catch (e) {
            failedCount = failedCount + 1;
            failedStatuses.push('exception');
            AppLogger.warn(TAG, `[health] refresh ${s.name} failed: ${e instanceof Error ? e.message : String(e)}`);
          }
        }
        const details = failedStatuses.length > 0 ? `，失败 ${failedCount}（${failedStatuses.join('/')}）` : '';
        r.text = `已刷新 ${okCount}/${subs.subscriptions.length} 个订阅${details}`;
        return r;
      }
      case RepairActions.RESELECT_NODE: {
        const switched = await this.tryFailover('health-reselect');
        r.text = switched ? '已切换到备用节点' : '未找到更优节点，保持当前节点';
        r.usedReconnect = switched;
        return r;
      }
      case RepairActions.REBUILD_TUN:
      case RepairActions.RESTART_CORE:
      case RepairActions.RESTART_CLASH_API: {
        if (reconnectUsed) {
          r.text = '本次已执行过重建，跳过多余重启（避免重连风暴）';
          return r;
        }
        const done = await this.repairReconnect();
        r.text = done ? '已重建隧道并重连' : '重建隧道失败';
        r.usedReconnect = true;
        if (!done) {
          r.stop = true;
        }
        return r;
      }
      case RepairActions.RECONCILE_INTENT: {
        const alive = this.isCoreAliveByHeartbeat() || this.readStartOk();
        const snap = new ConnectionSnapshot();
        snap.desiredConnected = alive;
        snap.nodeName = this.lastNodeName;
        snap.savedAt = Date.now();
        await SettingsService.saveSnapshot(snap);
        r.text = `已将连接意图对齐真实状态(desired=${alive})`;
        return r;
      }
      case RepairActions.FIX_DNS:
        r.text = 'DNS 由内核内置处理，已随隧道重建生效';
        return r;
      case RepairActions.CHECK_UPLINK:
        r.text = '上层物理网络受限，本地修复无法解决，请检查运营商/路由';
        return r;
      case RepairActions.GRANT_VPN_PERMISSION:
        r.text = '需要用户在系统弹窗中授予 VPN 权限，停止自动修复';
        r.stop = true;
        return r;
      case RepairActions.ENABLE_NOTIFICATIONS:
        r.text = '需要用户开启通知权限，停止自动修复';
        r.stop = true;
        return r;
      default:
        r.text = `未知修复动作(${action})，忽略`;
        return r;
    }
  }

  /** 重建隧道（有限一次）：断开 → 等待 → 用上次节点重连 */
  private async repairReconnect(): Promise<boolean> {
    const subs = this.lastSubs;
    if (subs === null || this.lastNodeName.length === 0) {
      return false;
    }
    if (this.state === ConnState.CONNECTING) {
      return false; // 单航班
    }
    const node = this.findNodeByName(subs, this.lastNodeName);
    if (node === null) {
      return false;
    }
    this.inRepairConnect = true;
    try {
      await this.disconnect();
      await new Promise<void>((resolve) => setTimeout(() => resolve(), 600));
      return await this.connect(node, subs);
    } catch (e) {
      AppLogger.warn(TAG, `[health] repairReconnect failed: ${e instanceof Error ? e.message : String(e)}`);
      return false;
    } finally {
      this.inRepairConnect = false;
    }
  }

  /** 内核死亡入口（监控循环调用）：有界，单航班 */
  private handleCoreLoss(): void {
    this.handleCoreLossAsync();
  }

  private async handleCoreLossAsync(): Promise<void> {
    if (this.coreLossHandling) {
      return;
    }
    this.coreLossHandling = true;
    try {
      let healthEnabled = true;
      try {
        const s = await SettingsService.load();
        healthEnabled = s.healthCheckEnabled;
      } catch (e) {
        healthEnabled = true;
      }
      if (healthEnabled) {
        // 集成点②：内核已死 → 先自检 → 有限修复 → 复核
        const recovered = await this.runHealthSelfCheckAndRepair('core-death');
        if (recovered) {
          AppLogger.info(TAG, '[health] core restored');
          return;
        }
        this.state = ConnState.DISCONNECTED;
        if (this.lastError.length === 0) {
          this.lastError = '内核已死，链路自检与有限修复未能恢复，已停止自动重试';
        }
        this.notify();
        return;
      }
      // 自检被关闭：退回既有有界恢复策略（最多 2 次）
      AppLogger.info(TAG, '[health] disabled; fallback to legacy bounded recovery');
      if (this.recoveryAttempts < 2 && this.lastSubs !== null) {
        this.recoveryAttempts = this.recoveryAttempts + 1;
        const node = this.findNodeByName(this.lastSubs, this.lastNodeName);
        if (node !== null) {
          await this.connect(node, this.lastSubs);
          return;
        }
      }
      this.state = ConnState.DISCONNECTED;
      this.lastError = '内核异常退出，自动恢复失败，请手动重连';
      this.notify();
    } finally {
      this.coreLossHandling = false;
    }
  }

  // ══════════════════════════════════════════════════════════════════
  // 第二阶段集成点③：节点统计 + 连续失败 → 自动切换节点
  // ══════════════════════════════════════════════════════════════════

  /** 自动切换原因（最近一次，供 UI/通知展示）；空 = 从未切换 */
  autoSwitchReason(): string {
    return this.autoSwitchReasonText;
  }

  lastFailoverFromName(): string {
    return this.lastFailoverFrom;
  }

  lastFailoverToName(): string {
    return this.lastFailoverTo;
  }

  private findNodeByName(subs: SubscriptionService, name: string): ProxyNode | null {
    for (const n of subs.nodes) {
      if (n.name === name) {
        return n;
      }
    }
    return subs.nodes.length > 0 ? subs.nodes[0] : null;
  }

  /** 连接成功：复位该节点连续失败计数（复用 NodeSortPersistence 快照记录） */
  private async recordNodeSuccess(name: string): Promise<void> {
    await this.updateNodeStats(name, true);
  }

  /** 连接失败：累加该节点连续失败计数 */
  private async recordNodeFailure(name: string): Promise<void> {
    await this.updateNodeStats(name, false);
  }

  /**
   * 更新节点统计并落盘（复用 AppSettings.nodeSortSnapshot = NodeSortSnapshot JSON）。
   * @returns 该节点更新后的连续失败次数
   */
  private async updateNodeStats(name: string, ok: boolean): Promise<number> {
    if (name.length === 0) {
      return 0;
    }
    try {
      const settings = await SettingsService.load();
      let snap = NodeSortSnapshot.fromJsonText(settings.nodeSortSnapshot);
      if (snap === null) {
        snap = new NodeSortSnapshot();
      }
      let rec = snap.recordFor(name);
      if (rec === null) {
        rec = new NodeLatencyRecord();
        rec.name = name;
        rec.latency = LATENCY_UNTESTED;
        snap.records.push(rec);
      }
      if (ok) {
        rec.failCount = 0;
        rec.lastOk = true;
        if (rec.latency < 0) {
          rec.latency = LATENCY_UNTESTED; // 由后续测速填充
        }
      } else {
        rec.failCount = rec.failCount + 1;
        rec.lastOk = false;
        rec.latency = LATENCY_FAILED;
      }
      settings.nodeSortSnapshot = snap.toJsonText();
      await SettingsService.save(settings);
      AppLogger.info(TAG, `[failover] node stat ${name}: ok=${ok} consecutiveFailures=${rec.failCount}`);
      return rec.failCount;
    } catch (e) {
      AppLogger.warn(TAG, `[failover] update node stats failed: ${e instanceof Error ? e.message : String(e)}`);
      return 0;
    }
  }

  private candidateFromRecord(name: string, snap: NodeSortSnapshot | null): NodeCandidate {
    const rec = snap === null ? null : snap.recordFor(name);
    if (rec === null) {
      return NodeCandidate.make(name, LATENCY_UNTESTED);
    }
    return NodeCandidate.fromStats(name, rec.latency, rec.failCount, rec.lastOk, 0, 0);
  }

  private buildCandidates(subs: SubscriptionService, snap: NodeSortSnapshot | null): NodeCandidate[] {
    const list: NodeCandidate[] = [];
    for (const n of subs.nodes) {
      if (ClashConfigGenerator.proxyYamlLine(n).length === 0) {
        continue; // 仅有效节点参与评分
      }
      list.push(this.candidateFromRecord(n.name, snap));
    }
    return list;
  }

  /**
   * 连续失败达阈值 → 按 SmartSelector 选点并切换（受 failoverEnabled /
   * autoSelectMode=auto / 冷却 / 单航班约束）。切换后通知卡片与通知。
   * @returns 是否成功切换到并连上新的节点
   */
  private async tryFailover(trigger: string): Promise<boolean> {
    if (this.failoverRunning) {
      AppLogger.info(TAG, `[failover] already running; skip (${trigger})`);
      return false;
    }
    if (this.disconnectRequested) {
      AppLogger.info(TAG, `[failover] user-disconnected; skip (${trigger})`);
      return false;
    }
    const subs = this.lastSubs;
    if (subs === null || subs.nodes.length === 0) {
      return false;
    }
    let settings: AppSettings;
    try {
      settings = await SettingsService.load();
    } catch (e) {
      return false;
    }
    if (!settings.failoverEnabled) {
      AppLogger.info(TAG, `[failover] disabled by settings; skip (${trigger})`);
      return false;
    }
    if (settings.autoSelectMode !== AutoSelectModes.AUTO) {
      AppLogger.info(TAG, `[failover] autoSelectMode=manual (用户固定节点); skip (${trigger})`);
      return false;
    }
    if (this.state === ConnState.CONNECTING) {
      AppLogger.info(TAG, `[failover] connect in flight; skip (${trigger})`); // 单航班
      return false;
    }
    const now = Date.now();
    const cooldownMs = settings.failoverCooldownSec * 1000;
    if (this.lastFailoverAt > 0 && now - this.lastFailoverAt < cooldownMs) {
      AppLogger.info(TAG, `[failover] cooldown active ${now - this.lastFailoverAt}ms < ${cooldownMs}ms; skip (${trigger})`);
      return false;
    }
    const snap = NodeSortSnapshot.fromJsonText(settings.nodeSortSnapshot);
    const opts = new SelectorOptions();
    opts.failThreshold = settings.failoverFailureThreshold;
    opts.cooldownMs = cooldownMs;
    opts.autoSwitch = true;
    const cur = this.lastNodeName.length > 0 ? this.candidateFromRecord(this.lastNodeName, snap) : null;
    const fails = cur === null ? settings.failoverFailureThreshold : cur.consecutiveFailures;
    if (cur !== null && !failoverAllowed(cur, fails, now, opts)) {
      AppLogger.info(TAG, `[failover] not allowed (fails=${fails}, threshold=${opts.failThreshold}); skip (${trigger})`);
      return false;
    }
    const list = this.buildCandidates(subs, snap);
    const next = nextBestNode(cur, list, now, opts);
    if (next === null) {
      AppLogger.info(TAG, `[failover] no better eligible node; keep current (${trigger})`);
      return false;
    }
    this.lastFailoverFrom = this.lastNodeName;
    this.lastFailoverTo = next.name;
    this.lastFailoverAt = now;
    this.autoSwitchReasonText = `节点「${this.lastNodeName}」连续失败 ${fails} 次，自动切换至「${next.name}」`;
    AppLogger.info(TAG, `[failover] ${this.autoSwitchReasonText} (trigger=${trigger})`);
    // 通知卡片/通知状态
    this.notify();
    try {
      await SsrvpnNotifier.update('SSRVPN 已切换节点', next.name,
        `连续失败 ${fails} 次，已自动切换`);
    } catch (e) {
      AppLogger.warn(TAG, `[failover] notify update failed: ${e instanceof Error ? e.message : String(e)}`);
    }
    const node = this.findNodeByName(subs, next.name);
    if (node === null) {
      return false;
    }
    this.failoverRunning = true;
    try {
      this.reconnectAttempts = 0;
      this.cancelReconnect('failover-switch');
      const ok = await this.connect(node, subs);
      AppLogger.info(TAG, `[failover] switch to ${next.name} result=${ok}`);
      return ok;
    } finally {
      this.failoverRunning = false;
    }
  }

  // ══════════════════════════════════════════════════════════════════
  // OrchestratorHealthView：向链路自检探针暴露只读运行态
  // ══════════════════════════════════════════════════════════════════

  hasSubscriptions(): boolean {
    return this.lastSubs !== null && this.lastSubs.subscriptions.length > 0;
  }

  subsNodeCount(): number {
    return this.lastSubs === null ? 0 : this.lastSubs.nodes.length;
  }

  currentNodeName(): string {
    return this.lastNodeName;
  }

  isCurrentNodeValid(): boolean {
    return this.lastNode !== null && ClashConfigGenerator.proxyYamlLine(this.lastNode).length > 0;
  }

  isHeartbeatAlive(): boolean {
    return this.isCoreAliveByHeartbeat();
  }

  isTunnelMarkerPresent(): boolean {
    return this.readStartOk();
  }

  async isDesiredConnected(): Promise<boolean> {
    try {
      const snap = await SettingsService.loadSnapshot();
      return snap.desiredConnected === true;
    } catch (e) {
      return false;
    }
  }

  async isIntentConsistent(): Promise<boolean> {
    const desired = await this.isDesiredConnected();
    const alive = this.isCoreAliveByHeartbeat() || this.readStartOk();
    return desired === alive;
  }

  startErrorText(): string {
    return this.readStartError();
  }

  isIpv6Enabled(): boolean {
    return this.ipv6Active;
  }

  async checkClashApiReachable(): Promise<boolean> {
    try {
      return await this.api.healthProbe();
    } catch (e) {
      return false;
    }
  }

  async checkDnsResolvable(): Promise<boolean> {
    try {
      const hosts: Record<string, string> = await DoHResolver.resolveMany(['www.gstatic.com'], 1200);
      return Object.keys(hosts).length > 0;
    } catch (e) {
      return false;
    }
  }

  async checkEgressReachable(): Promise<boolean> {
    const client = http.createHttp();
    try {
      const resp = await client.request('https://www.gstatic.com/generate_204', {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 1500,
        readTimeout: 1500
      });
      return resp.responseCode === 204 || resp.responseCode === 200;
    } catch (e) {
      return false;
    } finally {
      client.destroy();
    }
  }

  /** 读取 VPN Extension 进程回写的启动错误（跨进程文件通道） */
  private readStartError(): string {
    if (this.context === null) {
      return '';
    }
    // fd 释放与长度上限统一由 privateFs.readCapped 保证（finally closeSync）
    const res: SyncReadResult = privateFs.readCapped(
      `${this.context.cacheDir}/${START_ERROR_FILE}`, MAX_STATE_FILE_BYTES);
    return res.ok ? res.text.trim() : '';
  }

  private clearStartError(): void {
    if (this.context === null) {
      return;
    }
    try {
      fs.unlinkSync(`${this.context.cacheDir}/${START_ERROR_FILE}`);
    } catch (e) {
      // 文件不存在属正常
    }
    try {
      fs.unlinkSync(`${this.context.cacheDir}/${START_OK_FILE}`);
    } catch (e) {
      // 文件不存在属正常
    }
  }

  private invalidateStateProbeCache(): void {
    this.stateProbeCachedAt = 0;
    this.stateProbeStartOk = false;
    this.stateProbeHeartbeatAge = -1;
  }

  private refreshStateProbeCache(nowMs: number): void {
    if (this.context === null) {
      this.invalidateStateProbeCache();
      return;
    }
    if (this.stateProbeCachedAt > 0 && nowMs - this.stateProbeCachedAt < STATE_PROBE_CACHE_MS) {
      return;
    }
    try {
      fs.statSync(`${this.context.cacheDir}/${START_OK_FILE}`);
      this.stateProbeStartOk = true;
    } catch (e) {
      this.stateProbeStartOk = false;
    }
    const res: SyncReadResult = privateFs.readCapped(
      `${this.context.cacheDir}/${HEARTBEAT_FILE}`, MAX_STATE_FILE_BYTES);
    this.stateProbeHeartbeatAge = res.ok ? heartbeatAgeFromText(res.text, nowMs) : -1;
    this.stateProbeCachedAt = nowMs;
  }

  /** 扩展进程是否已回写启动成功标记；同一同步周期复用短时探针缓存。 */
  private readStartOk(): boolean {
    this.refreshStateProbeCache(Date.now());
    return this.stateProbeStartOk;
  }

  /** 读取扩展进程心跳距今毫秒数；-1 = 无心跳/读取失败 */
  private readHeartbeatAge(): number {
    const nowMs = Date.now();
    this.refreshStateProbeCache(nowMs);
    if (this.stateProbeHeartbeatAge < 0) {
      return -1;
    }
    return this.stateProbeHeartbeatAge + Math.max(0, nowMs - this.stateProbeCachedAt);
  }

  /** 内核存活判定：扩展进程心跳新鲜即存活（UI 进程的 coreBridge 实例与扩展进程无关，不可用） */
  private isCoreAliveByHeartbeat(): boolean {
    const age = this.readHeartbeatAge();
    return age >= 0 && age < HEARTBEAT_STALE_MS;
  }

  /** headless 测速内核: 未连接时预启动真实协议栈做端到端测速 */
  /** @deprecated 仅作兼容读出口，真实状态看 testCoreFlight.getStatus() */
  testCoreActive: boolean = false;
  private testCoreSecret: string = '';
  /** 单航班状态机：并发启动只生效一次，超时可取消，启停不互损 */
  private testCoreFlight: SingleFlightTestCore | null = null;
  /**
   * 启动失败后的负缓存截止时间戳（ms）。0 = 无冷却。
   * 内核确实拉不起来时不能每次测速都白等 15~20s 的启动超时；冷却期内直接返回
   * false，页面按既有约定降级成「端口可达」，绝不冒充代理延迟。
   */
  private testCoreNegativeUntil: number = 0;

  /** 懒建状态机（依赖 this.context，调用前须已 init） */
  private getTestCoreFlight(): SingleFlightTestCore {
    if (this.testCoreFlight === null) {
      this.testCoreFlight = new SingleFlightTestCore({
        startFn: (): Promise<boolean> => this.launchTestCore(),
        cancelFn: (): Promise<void> => this.teardownTestCore(),
        timeoutMs: 15000,
        onStatusChange: (status: TestCoreStatus): void => {
          this.testCoreActive = status === TestCoreStatus.ACTIVE;
        }
      });
    }
    return this.testCoreFlight;
  }

  /**
   * 单飞状态机是否自认 ACTIVE（**仅进程内状态**，不代表 controller 可用）。
   * 生产判定必须用 verifyTestCoreChannel() / isTestCoreServing()：ACTIVE 只说明
   * 「本进程里曾经启动成功过」，与扩展进程是否还在、跑的是哪份配置/secret 无关。
   * 二次进入节点页全部 /delay 非 200 的根因就是只信了这个布尔量。
   */
  isTestCoreActive(): boolean {
    return this.testCoreFlight !== null && this.testCoreFlight.isActive();
  }

  /**
   * 测速内核通道真实可用判据（四者一致才算就绪）：
   *   1) 本进程持有本班次的测速 secret；
   *   2) endpoint 端口 = API_PORT；
   *   3) endpoint secret = 本班次 secret；
   *   4) 真实探测 GET /version 返回 200（进程存活 + secret 被内核接受）。
   */
  async verifyTestCoreChannel(): Promise<boolean> {
    if (this.testCoreSecret.length === 0) {
      return false;
    }
    if (this.api.currentPort() !== API_PORT || !this.api.hasSecret(this.testCoreSecret)) {
      AppLogger.warn(TAG, 'test core channel verify failed: endpoint port/secret mismatch');
      return false;
    }
    const probe = await this.api.probeController(1500);
    if (!probe.secretAccepted) {
      AppLogger.warn(TAG, `test core channel verify failed: reachable=${probe.reachable} `
        + `code=${probe.httpCode} detail=${probe.detail}`);
      return false;
    }
    return true;
  }

  /** 测速内核是否正在服务（状态机 ACTIVE + 通道真实可用） */
  async isTestCoreServing(): Promise<boolean> {
    if (this.testCoreFlight === null || !this.testCoreFlight.isActive()) {
      return false;
    }
    return this.verifyTestCoreChannel();
  }

  /** 启动失败负缓存是否生效（页面据此直接走「端口可达」降级，不白等启动超时） */
  isTestCoreNegativeCached(): boolean {
    return Date.now() < this.testCoreNegativeUntil;
  }

  /**
   * 确保 headless 测速内核在跑。并发调用共享同一航班：
   * 只有第一次真正走 stop→start，其余复用同一 Promise，
   * 避免「后到的启动把先到的扩展停掉」的互相 stop。
   */
  async ensureTestCore(subs: SubscriptionService, settings: AppSettings): Promise<boolean> {
    if (this.context === null || subs.nodes.length === 0) {
      return false;
    }
    const flight = this.getTestCoreFlight();
    if (flight.isActive()) {
      // 就绪判据 = controller 实际可用（端口 + secret + 真实 /version 探测），
      // 不能只看进程内状态机 ACTIVE：内核已死或 secret 被别的路径覆盖时，
      // 旧实现直接 return true，导致整批 /delay 非 200（真机 143 节点全超时）。
      if (await this.verifyTestCoreChannel()) {
        this.testCoreNegativeUntil = 0;
        return true;
      }
      // 通道可能只是被覆盖了 secret：先用本班次 secret 重新下发并复探一次
      if (this.testCoreSecret.length > 0) {
        this.api.setEndpoint(API_PORT, this.testCoreSecret);
        if (await this.verifyTestCoreChannel()) {
          AppLogger.info(TAG, 'test core channel recovered by re-issuing endpoint secret');
          this.testCoreNegativeUntil = 0;
          return true;
        }
      }
      AppLogger.warn(TAG,
        'test core marked ACTIVE but controller unusable; tearing down and relaunching');
      await this.stopTestCore();
    }
    // 安全门禁（防「互相 stop」）：headless 测速内核的启动流程第一步就是
    // stopVpnExtensionAbility —— 若此刻真实隧道正在建立/已连接/恢复中，那一步
    // 会把用户正在用的 VPN 直接停掉。不能只信任调用方传入的进程内 state
    // （新进程 state 恒为 DISCONNECTED），必须用权威判据再复判一次。
    if (this.state === ConnState.CONNECTING || this.state === ConnState.CONNECTED
      || this.state === ConnState.DISCONNECTING || this.state === ConnState.RECOVERING) {
      AppLogger.info(TAG, `ensureTestCore skipped: orchestrator busy (state=${this.state})`);
      return false;
    }
    try {
      const authority = await this.authorityState();
      if (authority.connected) {
        AppLogger.info(TAG, `ensureTestCore skipped: real tunnel is authoritative (${authority.reason})`);
        return false;
      }
    } catch (error) {
      // 读不到持久化意图时按「未连接」继续：不能因一次读盘失败就永久禁用测速内核。
      AppLogger.warn(TAG,
        `ensureTestCore authority probe failed: ${error instanceof Error ? error.message : String(error)}`);
    }
    if (this.isTestCoreNegativeCached()) {
      AppLogger.info(TAG, 'ensureTestCore skipped: negative cache cooling down');
      return false;
    }
    this.testCoreSubs = subs;
    this.testCoreSettings = settings;
    const started = await flight.ensure();
    if (started) {
      this.testCoreNegativeUntil = 0;
    } else {
      this.testCoreNegativeUntil = Date.now() + TEST_CORE_NEGATIVE_COOLDOWN_MS;
      AppLogger.warn(TAG,
        `ensureTestCore failed; negative cache ${TEST_CORE_NEGATIVE_COOLDOWN_MS}ms`);
    }
    return started;
  }

  /** 本次航班的输入（启动时才读取，避免并发覆盖） */
  private testCoreSubs: SubscriptionService | null = null;
  private testCoreSettings: AppSettings | null = null;

  /** 真正的启动动作（由状态机单次调用） */
  private async launchTestCore(): Promise<boolean> {
    const subs = this.testCoreSubs;
    const settings = this.testCoreSettings;
    if (this.context === null || subs === null || settings === null) {
      return false;
    }
    try {
      const domains: string[] = [];
      for (const n of subs.nodes) {
        const s = n.server;
        if (s.length === 0 || s.includes(':') || /^\d+\.\d+\.\d+\.\d+$/.test(s)) {
          continue;
        }
        domains.push(s);
      }
      let hosts: Record<string, string> = {};
      try {
        hosts = await DoHResolver.resolveMany(domains, 4000);
      } catch (e) {
        AppLogger.warn(TAG, `test-core DoH pre-resolve failed: ${e instanceof Error ? e.message : String(e)}`);
      }
      this.testCoreSecret = `ssr-test-${Date.now().toString(36)}-${Math.floor(Math.random() * 0x7FFFFFFF).toString(36)}`;
      // geoip 缺失时不生成 GEOIP 规则(同 connect), 否则内核启动会联网下载 MMDB 卡死
      let testGeoip = false;
      try {
        testGeoip = fs.statSync(`${this.context.cacheDir}/geoip.metadb`).size > 0;
      } catch (e) {
        testGeoip = false;
      }
      const yaml = ClashConfigGenerator.generate(subs.nodes[0], subs.nodes, settings,
        MIXED_PORT, API_PORT, this.testCoreSecret, testGeoip, false, hosts, false, subs.proxyGroups);
      const configPath = `${this.context.cacheDir}/${PRIVATE_TEST_CONFIG_FILE}`;
      // 最小权限私有目录 + 0600 文件（含 api secret 与节点口令）
      ensurePrivateDir(this.context.cacheDir);
      privateFs.writePrivate(configPath, yaml);
      this.clearStartError();
      const stopWant: Want = {
        bundleName: 'com.ssrvpn.client',
        abilityName: 'VpnExtensionAbility'
      };
      try {
        await vpnExtension.stopVpnExtensionAbility(stopWant);
      } catch (e) {
        // 未运行属正常
      }
      await new Promise<void>((resolve) => setTimeout(() => resolve(), 600));
      const want: Want = {
        bundleName: 'com.ssrvpn.client',
        abilityName: 'VpnExtensionAbility',
        parameters: {
          configPath: configPath,
          headless: 1
        }
      };
      await vpnExtension.startVpnExtensionAbility(want);
      this.invalidateStateProbeCache();
      this.api.setEndpoint(API_PORT, this.testCoreSecret);
      const deadline = Date.now() + 20000;
      let readinessDelayMs = 0;
      while (Date.now() < deadline) {
        const extErr = this.readStartError();
        if (extErr.length > 0) {
          throw new Error(`测速内核启动失败: ${extErr}`);
        }
        if (this.readStartOk() && await this.api.healthProbe()) {
          AppLogger.info(TAG, 'headless test core ready');
          return true;
        }
        readinessDelayMs = nextReadinessDelayMs(readinessDelayMs);
        const remainingMs = deadline - Date.now();
        if (remainingMs > 0) {
          await new Promise<void>((resolve) =>
            setTimeout(() => resolve(), Math.min(readinessDelayMs, remainingMs)));
        }
      }
      const finalError = this.readStartError();
      if (finalError.length > 0) {
        throw new Error(`测速内核启动失败: ${finalError}`);
      }
      throw new Error('测速内核就绪超时(20s)');
    } catch (e) {
      AppLogger.warn(TAG, `ensureTestCore failed: ${e instanceof Error ? e.message : String(e)}`);
      return false;
    }
  }

  /**
   * 释放测速内核：停扩展 + 删除测速配置（含 secret）+ 抹掉内存 secret。
   * 扩展未运行时 stopVpnExtensionAbility 抛错属正常，配置删除逐文件独立容错。
   */
  private async teardownTestCore(): Promise<void> {
    const stopWant: Want = {
      bundleName: 'com.ssrvpn.client',
      abilityName: 'VpnExtensionAbility'
    };
    let stopped = false;
    for (let attempt = 1; attempt <= TEST_CORE_STOP_ATTEMPTS && !stopped; attempt++) {
      try {
        await vpnExtension.stopVpnExtensionAbility(stopWant);
        stopped = true;
      } catch (e) {
        AppLogger.warn(TAG, `stopTestCore attempt ${attempt}/${TEST_CORE_STOP_ATTEMPTS} failed: `
          + (e instanceof Error ? e.message : String(e)));
        if (attempt < TEST_CORE_STOP_ATTEMPTS) {
          await new Promise<void>((resolve) =>
            setTimeout(() => resolve(), TEST_CORE_STOP_RETRY_DELAY_MS));
        }
      }
    }
    if (!stopped) {
      // 停失败不能只吞日志：下次启动的第一步就是 stop + 覆盖测速配置（含新
      // secret），因此扩展会被正确重建而不是复用旧配置，这里如实记录即可。
      AppLogger.warn(TAG,
        'stopTestCore: extension stop failed after retries; next launch rebuilds it');
    }
    this.resetTestCoreChannelState();
  }

  /**
   * 显式复位测速通道的全部本地状态：清 secret、清 endpoint、清单飞状态、清启动
   * 失败负缓存、删残余测速配置与隧道状态文件。
   * stopTestCore / teardownTestCore 之后必须走这里，否则页面级 testCoreOk 与真实
   * 通道脱钩，二次进入页面会继续按「内核就绪」走 CHANNEL_KERNEL 而全部失败。
   */
  resetTestCoreChannelState(): void {
    this.testCoreSecret = '';
    this.api.setEndpoint(API_PORT, '');
    this.testCoreActive = false;
    this.testCoreNegativeUntil = 0;
    this.invalidateStateProbeCache();
    this.clearTestCoreArtifacts();
    if (this.testCoreFlight !== null) {
      this.testCoreFlight.resetIdle();
    }
  }

  /**
   * 页面进入时同步「真实隧道」controller 凭证。
   *
   * 必须拒绝在 headless 测速内核仍在服务时覆盖：两者共用 9090 端口，但 secret
   * 完全不同（测速内核每次随机生成）。旧实现无条件 setEndpoint(9090, 真实secret)
   * 会让内核侧所有 /delay 返回 401 → UI 全显超时，且不重启应用就一直错。
   * @returns 是否真的写入了真实隧道凭证
   */
  async applyRealTunnelEndpoint(realSecret: string): Promise<boolean> {
    if (this.state === ConnState.CONNECTED || this.state === ConnState.CONNECTING) {
      this.api.setEndpoint(API_PORT, realSecret);
      return true;
    }
    if (await this.isTestCoreServing()) {
      AppLogger.info(TAG, 'skip real-tunnel endpoint override: headless test core is serving');
      return false;
    }
    this.api.setEndpoint(API_PORT, realSecret);
    return true;
  }

  /**
   * 真实隧道接管扩展进程后，测速内核的进程内状态全部失效（同一扩展、不同配置与
   * secret）。必须显式复位，否则下次测速会因状态机仍 ACTIVE 而跳过重建。
   */
  invalidateTestCoreAfterRealTunnel(): void {
    this.testCoreNegativeUntil = 0;
    this.testCoreSecret = '';
    this.testCoreActive = false;
    if (this.testCoreFlight !== null) {
      this.testCoreFlight.resetIdle();
    }
  }

  /** 单独抽出便于验证：删除测速配置 + 隧道状态文件，逐文件独立容错 */
  clearTestCoreArtifacts(): string[] {
    if (this.context === null) {
      return [];
    }
    return clearPrivateArtifacts(this.context.cacheDir, privateFs);
  }

  async stopTestCore(): Promise<void> {
    if (this.testCoreFlight === null) {
      // 状态机未建但可能有残留配置（进程重启后），仍然完整复位一次
      this.resetTestCoreChannelState();
      return;
    }
    await this.testCoreFlight.stop();
    // 状态机只负责状态位；secret / endpoint / 负缓存 / 单飞复位统一在这里显式清零
    this.testCoreActive = false;
    this.testCoreNegativeUntil = 0;
    if (this.testCoreFlight.isActive()) {
      AppLogger.warn(TAG, 'stopTestCore: flight still ACTIVE after stop(); forcing idle');
      this.testCoreFlight.resetIdle();
    }
  }

  /**
   * 待回收定时器句柄（-1 = 无挂起回收）。
   * 测速内核在「连续多次测速 / 节点页来回切换」之间必须复用：重建一次要
   * DoH 预解析 + 停旧扩展 + 600ms 等待 + 启新扩展 + 健康轮询（秒级），
   * 用户感受就是「每点一次测速先卡一两秒」。所以离开测速场景时不立即回收，
   * 而是挂一个宽限回收；期间再次进入测速会 cancel 掉它（继续用同一内核）。
   */
  private testCoreIdleTimer: number = -1;

  /** 挂起「延迟回收测速内核」；重复调用只保留最后一次。 */
  scheduleTestCoreRecycle(delayMs: number): void {
    this.cancelTestCoreRecycle();
    this.testCoreIdleTimer = setTimeout((): void => {
      this.testCoreIdleTimer = -1;
      this.stopTestCore();
    }, delayMs);
  }

  /** 取消挂起的回收（真实连接 / 重新进入测速场景时调用）。 */
  cancelTestCoreRecycle(): void {
    if (this.testCoreIdleTimer >= 0) {
      clearTimeout(this.testCoreIdleTimer);
      this.testCoreIdleTimer = -1;
    }
  }

  async connect(node: ProxyNode, subs: SubscriptionService): Promise<boolean> {
    this.disconnectRequested = false;
    const seq = ++this.connectSeq;
    // 真实连接会重启扩展进程, headless 测速内核随之失效；同时必须取消
    // 挂起的「回收测速内核」定时器 —— 否则它会在真实隧道起来之后再执行
    // stopVpnExtensionAbility，把用户正在用的 VPN 停掉。
    this.cancelTestCoreRecycle();
    // 真实连接会重建扩展进程（同一 9090 端口换成隧道配置 + 真实 secret）：
    // 测速内核的进程内状态与本班次 secret 在此刻全部作废。
    this.invalidateTestCoreAfterRealTunnel();
    this.state = ConnState.CONNECTING;
    this.lastError = '';
    this.lastSubs = subs;
    this.lastNodeName = node.name;
    this.notify();

    try {
      if (this.context === null) {
        throw new Error('orchestrator 未初始化（init(context) 缺失）');
      }
      const settings: AppSettings = await SettingsService.load();

      // 节点有效性检查：旧版本持久化的节点缺 rawYaml 且非 ss/ssr 字段不完整时无法生成配置。
      // 自动降级到第一个可用节点；全部无效时自动刷新一次订阅（修复升级后旧数据不可用）。
      const isValidNode = (n: ProxyNode): boolean => ClashConfigGenerator.proxyYamlLine(n).length > 0;
      let target: ProxyNode = node;
      if (!isValidNode(target)) {
        const firstValid = subs.nodes.find((n) => isValidNode(n)) ?? null;
        if (firstValid !== null) {
          target = firstValid;
          AppLogger.warn(TAG, `preferred node invalid; fall back to ${target.name}`);
        } else {
          AppLogger.warn(TAG, 'no valid node config; auto-refreshing subscriptions');
          for (const s of subs.subscriptions) {
            try {
              const refreshResult = await subs.refreshSubscription(s.id);
              if (refreshResult.status !== SubscriptionRefreshStatus.OK
                && refreshResult.status !== SubscriptionRefreshStatus.NOT_MODIFIED) {
                AppLogger.warn(TAG,
                  `auto refresh ${s.name} failed: ${refreshResult.status} ${refreshResult.message}`);
              }
            } catch (e) {
              AppLogger.warn(TAG, `auto refresh ${s.name} failed: ${e instanceof Error ? e.message : String(e)}`);
            }
          }
          const retry = subs.nodes.find((n) => isValidNode(n)) ?? null;
          if (retry === null) {
            throw new Error('订阅节点配置无效：请到「订阅」页点击「全部刷新」，确认节点已成功导入后再连接');
          }
          target = retry;
        }
      }
      this.lastNodeName = target.name;
      this.lastNode = target;

      // API secret 保持稳定(首次生成后复用): 每次重连都换 secret 会让其他页面
      // 持有的旧 secret 全部 401, 延迟测试/节点切换集体失败(表现全是"超时")。
      const savedSecret = await SettingsService.getApiSecret();
      if (savedSecret.length > 0) {
        this.apiSecret = savedSecret;
      } else {
        const random = cryptoFramework.createRandom();
        const randomBlob = await random.generateRandom(24);
        let randomHex = '';
        for (const value of randomBlob.data) {
          randomHex += value.toString(16).padStart(2, '0');
        }
        this.apiSecret = `ssr-${randomHex}`;
        await SettingsService.setApiSecret(this.apiSecret);
      }

      // 关键：扩展进程存活时再次 startVpnExtensionAbility 只会累加 startId，
      // 系统不会重新回调 onCreate（TUN/内核启动逻辑不会重放）。
      // 因此每次连接前先停掉既有 VPN 扩展（触发 onDestroy → 内核停止），
      // 等待进程退出后重新拉起，保证新配置/新节点真正生效。
      // 注意: 停旧隧道也必须在 IPv6 探测之前 —— 隧道存活时 ::/0 路由指向
      // 隧道自身, 探测会误报"有 IPv6"。
      try {
        const stopWant: Want = {
          bundleName: 'com.ssrvpn.client',
          abilityName: 'VpnExtensionAbility'
        };
        await vpnExtension.stopVpnExtensionAbility(stopWant);
      } catch (e) {
        // 未运行时停止会报错，属正常
      }
      await new Promise<void>((resolve) => setTimeout(() => resolve(), 400));

      // geoip.metadb 缺失时降级生成（不含 GEOIP 规则）, 避免内核在 config.Parse
      // 阶段联网下载 MMDB 失败导致启动卡死; 连接成功后后台补齐, 下次连接生效。
      const geoipPath = `${this.context.cacheDir}/geoip.metadb`;
      let useGeoip = false;
      try {
        useGeoip = fs.statSync(geoipPath).size > 0;
      } catch (e) {
        useGeoip = false;
      }
      if (!useGeoip) {
        AppLogger.info(TAG, 'geoip.metadb missing; generate config without GEOIP rule');
      }

      // ── 代理服务器域名防投毒解析(UI 进程, 此刻 VPN 未起、网络干净) ──
      // 明文 UDP DNS 会往代理域名的应答里追加假记录, 内核拨假地址全线超时。
      // 用 DoH 预解析所有节点入口域名(与权威应答验证一致), 结果写进 YAML hosts:,
      // 内核直接命中真实 IP。带缓存 + 6s 全局预算 + 失败二轮重试。
      const serverDomains: string[] = [];
      for (const n of subs.nodes) {
        const s = n.server;
        if (s.length === 0 || s.includes(':') || /^\d+\.\d+\.\d+\.\d+$/.test(s)) {
          continue; // 跳过空/IPv6/裸 IPv4
        }
        serverDomains.push(s);
      }
      // IPv6 detection and DoH pre-resolution are independent. Running them in parallel
      // removes the IPv6 probe from the cold-start critical path while preserving semantics.
      const ipv6Task = Ipv6Detector.hasIPv6();
      const hostsTask = DoHResolver.resolveMany(serverDomains, 6000);
      let proxyHosts: Record<string, string> = {};
      try {
        const startupResults = await Promise.all([ipv6Task, hostsTask]);
        this.ipv6Active = startupResults[0];
        proxyHosts = startupResults[1];
      } catch (e) {
        this.ipv6Active = false;
        AppLogger.warn(TAG, `startup network probes failed: ${e instanceof Error ? e.message : String(e)}`);
        try {
          proxyHosts = await hostsTask;
        } catch (ignored) {
          proxyHosts = {};
        }
      }
      AppLogger.info(TAG, `DoH pinned ${Object.keys(proxyHosts).length}/${serverDomains.length} proxy servers`);
      const unpinnedDomains: string[] = [];
      for (const d of serverDomains) {
        if (proxyHosts[d.toLowerCase()] === undefined) {
          unpinnedDomains.push(d);
        }
      }
      if (unpinnedDomains.length > 0) {
        // 未 pin 的域名运行期回退 proxy-server-nameserver(明文 UDP, 有被投毒风险),
        // 点名记录便于排查"个别节点不通"类问题。
        AppLogger.warn(TAG, `unpinned servers: ${unpinnedDomains.slice(0, 12).join(', ')}`);
      }

      const yaml = ClashConfigGenerator.generate(target, subs.nodes, settings, MIXED_PORT, API_PORT,
        this.apiSecret, useGeoip, this.ipv6Active, proxyHosts, true, subs.proxyGroups);
      const configPath = `${this.context.cacheDir}/${CONFIG_FILE}`;
      // 含 API secret 与节点口令：最小权限目录(0700) + 文件(0600)，fd 由 writePrivate 兜底关闭
      ensurePrivateDir(this.context.cacheDir);
      privateFs.writePrivate(configPath, yaml);
      AppLogger.info(TAG, `config written: ${configPath} (${yaml.length} bytes)`);
      this.clearStartError();

      // 拉起 VPN 能力（首次会弹系统 VPN 授权框）；TUN 建立 + 内核启动都在扩展进程完成。
      // 扩展进程把启动结果写入 vpn_start_error.txt（空文件/不存在 = 成功，非空 = 失败原因），
      // 并写入 vpn_start_ok.txt 成功标记 —— UI 进程通过文件轮询确认，绕开跨进程 loopback 探测的不确定性。
      // ipv6Inbound 标志同步 VpnConfig 的双栈开关, 与 YAML 保持一致。
      // bypassPackages: 强制不走代理的应用包名(VpnConfig.blockedApplications,
      //   框架层直接让这些 App 的流量绕过隧道走物理网络)。
      // proxyPackages: 「走代理的应用」白名单包名(includedApps → 扩展侧
      //   VpnConfig.trustedApplications, 仅这些 App 接入 VPN)。
      //   与 bypassPackages 一致: 空列表时传空串 —— 扩展侧按 length>0 判定,
      //   不下发对应字段、不产生任何副作用(空串 ≠ 白名单为空 = 全直连)。
      const want: Want = {
        bundleName: 'com.ssrvpn.client',
        abilityName: 'VpnExtensionAbility',
        parameters: {
          configPath: configPath,
          ipv6Inbound: this.ipv6Active ? 1 : 0,
          bypassPackages: settings.excludedApps.join(','),
          proxyPackages: settings.includedApps.join(',')
        }
      };
      // 关键防护: startVpnExtensionAbility 的 Promise 在系统授权链路异常时
      // (真机实证: checkVpnPermission datashare Query error → vpndialog 后无响应)
      // 可能永不 resolve —— 加 15s 竞速超时, 保证 UI 不会无限转圈。
      await Promise.race([
        vpnExtension.startVpnExtensionAbility(want),
        new Promise<void>((resolve, reject) => {
          setTimeout(() => {
            reject(new Error('VPN 扩展拉起超时（15s）：系统授权弹窗未完成或扩展无法启动，请重试'));
          }, 15000);
        })
      ]);

      this.api.resetTrafficBaseline();
      this.api.setEndpoint(API_PORT, this.apiSecret);
      const deadline = Date.now() + 30000;
      let apiReady = false;
      let readinessDelayMs = 0;
      while (Date.now() < deadline) {
        if (seq !== this.connectSeq) {
          await this.disconnectInternal();
          return false;
        }
        // 1) 失败信号优先：扩展进程回写的错误
        const extErr = this.readStartError();
        if (extErr.length > 0) {
          throw new Error(`Clash 内核启动失败: ${extErr}`);
        }
        // 2) 成功信号：扩展回写 OK 标记，且 loopback 探测通过（此时接口必然已绑定）
        if (this.readStartOk() && await this.api.healthProbe()) {
          apiReady = true;
          break;
        }
        readinessDelayMs = nextReadinessDelayMs(readinessDelayMs);
        const remainingMs = deadline - Date.now();
        if (remainingMs > 0) {
          await new Promise<void>((resolve) =>
            setTimeout(() => resolve(), Math.min(readinessDelayMs, remainingMs)));
        }
      }
      if (!apiReady) {
        const extErr = this.readStartError();
        if (extErr.length > 0) {
          throw new Error(`Clash 内核启动失败: ${extErr}`);
        }
        if (this.readStartOk()) {
          throw new Error('内核已启动但 API 探测失败：9090 端口跨进程不可达，请反馈日志');
        }
        throw new Error('Clash API 未就绪（30s 超时）：VPN 扩展未上报启动结果，请重试或反馈日志');
      }

      // 选中节点
      const selected = await this.api.selectNode(target.name);
      if (!selected) {
        AppLogger.warn(TAG, `selectNode(${target.name}) failed; keep default PROXY first node`);
      }

      if (seq !== this.connectSeq) {
        await this.disconnectInternal();
        return false; // 已被更新的连接请求取代
      }

      this.state = ConnState.CONNECTED;
      this.startedAt = Date.now();
      this.recoveryAttempts = 0;
      this.startMonitors();
      this.clearStartError(); // 连接成功，清掉启动标记文件
      // 重连成功 → 取消挂起的退避定时器并复位尝试计数（禁止重连风暴）
      this.reconnectAttempts = 0;
      this.cancelReconnect('connected');
      // 连接快照：重启/崩溃后恢复连接意图（对应 NativeConnectionSnapshotStore）
      const snap = new ConnectionSnapshot();
      snap.desiredConnected = true;
      snap.nodeName = target.name;
      snap.savedAt = Date.now();
      snap.startedAt = this.startedAt;
      await SettingsService.saveSnapshot(snap);
      // 集成点③：连接成功 → 复位该节点连续失败统计（复用 NodeSortPersistence 记录结构）
      await this.recordNodeSuccess(target.name);
      await SsrvpnNotifier.update('SSRVPN 已连接', target.name, '↓ 0 B/s  ↑ 0 B/s');
      this.notify();
      AppLogger.info(TAG, `connected to node ${target.name}`);
      if (!useGeoip) {
        // 后台补齐 geoip.metadb（jsdelivr 镜像）, 下次连接即可启用 GEOIP 直连规则
        this.downloadGeoipInBackground();
      }
      return true;
    } catch (e) {
      const errorMessage = e instanceof Error ? e.message : String(e);
      try {
        await this.disconnectInternal();
      } catch (cleanupError) {
        AppLogger.warn(TAG, `connect rollback failed: ${cleanupError instanceof Error ? cleanupError.message : String(cleanupError)}`);
      }
      this.state = ConnState.DISCONNECTED;
      this.startedAt = 0;
      this.ipv6Active = false;
      this.traffic = { uploadBytes: 0, downloadBytes: 0, uploadSpeed: 0, downloadSpeed: 0 };
      this.api.resetTrafficBaseline();
      this.api.setEndpoint(API_PORT, '');
      this.lastError = errorMessage;
      this.notify();
      AppLogger.error(TAG, `connect failed: ${errorMessage}`);
      // 集成点③：连接失败 → 累加节点连续失败统计（复用 NodeSortPersistence 记录结构）
      await this.recordNodeFailure(this.lastNodeName);
      // 若本次失败是由修复/切换内部发起的连接，则不再向外级联，避免重连风暴
      const nested = this.inRepairConnect || this.failoverRunning;
      if (!nested && !this.healthRunning) {
        // 集成点②：连接失败 → 一次链路自检 + 有限修复（受 healthCheckEnabled 门控）
        const recovered = await this.runHealthSelfCheckAndRepair('connect-failed');
        if (recovered) {
          return true;
        }
        // 集成点③：仍失败且连续失败达阈值 → 自动切换节点（受配置/冷却约束）
        const switched = await this.tryFailover('connect-failed');
        if (switched) {
          return true;
        }
      }
      return false;
    }
  }

  disconnect(): Promise<void> {
    this.requestDisconnect();
    if (this.disconnectTask !== null) {
      return this.disconnectTask;
    }
    const task = this.disconnectExclusive();
    this.disconnectTask = task;
    task.finally((): void => {
      if (this.disconnectTask === task) {
        this.disconnectTask = null;
      }
    });
    return task;
  }

  private async disconnectExclusive(): Promise<void> {
    const seq = this.connectSeq;
    this.state = ConnState.DISCONNECTING;
    this.notify();
    await this.disconnectInternal();
    if (seq !== this.connectSeq) {
      return;
    }
    this.state = ConnState.DISCONNECTED;
    this.startedAt = 0;
    this.traffic = { uploadBytes: 0, downloadBytes: 0, uploadSpeed: 0, downloadSpeed: 0 };
    this.api.resetTrafficBaseline();
    this.disconnectRequested = false;
    this.notify();
    AppLogger.info(TAG, 'disconnected');
  }

  /** 后台下载 geoip.metadb 到内核 home 目录（cacheDir），成功后下次连接启用 GEOIP 直连规则 */
  private geoipDownloading: boolean = false;

  private downloadGeoipInBackground(): void {
    if (this.geoipDownloading || this.context === null) {
      return;
    }
    this.geoipDownloading = true;
    const ctx = this.context;
    // jsdelivr CDN 镜像（GitHub release 直连国内不可达），多镜像依次回退
    const mirrors: string[] = [
      'https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb',
      'https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb',
      'https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb'
    ];
    const tryMirror = (idx: number): void => {
      if (idx >= mirrors.length) {
        this.geoipDownloading = false;
        AppLogger.warn(TAG, 'geoip.metadb download failed from all mirrors; will retry on next connect');
        return;
      }
      const client = http.createHttp();
      client.request(mirrors[idx], {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 15000,
        readTimeout: 90000
      }).then((resp: http.HttpResponse) => {
        const buf = resp.result as ArrayBuffer;
        if (resp.responseCode === 200 && buf.byteLength > 1024 * 100) {
          const file = fs.openSync(`${ctx.cacheDir}/geoip.metadb`,
            fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
          try {
            fs.writeSync(file.fd, buf);
          } finally {
            fs.closeSync(file);
          }
          this.geoipDownloading = false;
          client.destroy();
          AppLogger.info(TAG, `geoip.metadb downloaded (${buf.byteLength} bytes); GEOIP rule enabled next connect`);
        } else {
          client.destroy();
          AppLogger.warn(TAG, `geoip mirror ${idx} returned ${resp.responseCode}, size ${buf.byteLength}`);
          tryMirror(idx + 1);
        }
      }).catch((e: Object) => {
        client.destroy();
        AppLogger.warn(TAG, `geoip mirror ${idx} failed: ${e}`);
        tryMirror(idx + 1);
      });
    };
    tryMirror(0);
  }

  private async disconnectInternal(): Promise<void> {
    this.invalidateStateProbeCache();
    this.stopMonitors();
    // 测速内核与真实隧道互斥：断开/回滚路径一并回收单航班状态机（含配置清理）
    if (this.testCoreFlight !== null) {
      try {
        await this.testCoreFlight.stop();
      } catch (e) {
        AppLogger.warn(TAG, `test core stop during disconnect failed: ${e instanceof Error ? e.message : String(e)}`);
      }
    }
    const snap = new ConnectionSnapshot();
    snap.desiredConnected = false;
    snap.savedAt = Date.now();
    snap.startedAt = 0;
    await SettingsService.saveSnapshot(snap);
    try {
      await coreBridge.stopCore();
    } catch (e) {
      AppLogger.warn(TAG, `stopCore error: ${e}`);
    }
    if (this.context === null) {
      return;
    }
    try {
      const want: Want = {
        bundleName: 'com.ssrvpn.client',
        abilityName: 'VpnExtensionAbility'
      };
      await vpnExtension.stopVpnExtensionAbility(want);
    } catch (e) {
      AppLogger.warn(TAG, `stopVpnExtensionAbility error: ${e}`);
    }
    // 立即清理心跳/启动标记文件: 否则断开后 15s 内心跳文件仍是"新鲜"的,
    // isTunnelAlive() 会把"已断开"误判为"还活着" —— 真机实证: 卡片连续
    // 开关两次后就再也启动不了(每次都被误判 alive 而走 disconnect 分支)。
    this.clearTunnelMarkers();
    // 凭据清理：主配置 + 测速配置（内含 API secret / 节点口令）随隧道一并删除。
    // 逐文件独立容错: 任一文件不存在或删除失败都不阻断其余文件。
    const removed = clearPrivateArtifacts(this.context.cacheDir, privateFs);
    this.apiSecret = '';
    AppLogger.info(TAG, `runtime artifacts cleared: ${removed.join(',')}`);
  }

  private clearTunnelMarkers(): void {
    this.invalidateStateProbeCache();
    if (this.context === null) {
      return;
    }
    const dir = this.context.cacheDir;
    for (const f of [HEARTBEAT_FILE, START_OK_FILE, START_ERROR_FILE]) {
      try {
        fs.unlinkSync(`${dir}/${f}`);
      } catch (e) {
        // 文件不存在属正常
      }
    }
  }

  /** 存活监控 + 流量轮询 + 常驻通知（对应 CoreLivenessMonitor / VpnTrafficTracker / NotificationUpdatePolicy） */
  private startMonitors(): void {
    this.stopMonitors();
    this.monitorTimer = setInterval(() => {
      // 内核跑在 VPN 扩展进程里，UI 进程的 coreBridge.isCoreAlive() 永远为 false，
      // 只能依据扩展进程心跳文件判断存活（心跳新鲜 = 内核活着）。
      const alive = this.isCoreAliveByHeartbeat();
      if (!alive && this.state === ConnState.CONNECTED) {
          // 内核死亡：权威判据为「心跳过期/无心跳」→ 升级到链路自检 + 有限修复
          // （对应 core_recovery_policy；healthCheckEnabled=false 时退回既有有界恢复）
          this.state = ConnState.RECOVERING;
          this.notify();
          AppLogger.warn(TAG, `core died (authority: heartbeat stale/absent); escalating to health self-check`);
          this.handleCoreLoss();
          return;
        }
    }, 3000);
    this.trafficPollRunning = false;
    this.trafficTimer = setInterval(() => {
      if (this.trafficPollRunning || this.state !== ConnState.CONNECTED) {
        return;
      }
      this.trafficPollRunning = true;
      this.api.traffic().then((t: TrafficSnapshot) => {
        this.traffic = t;
        if (this.state === ConnState.CONNECTED) {
          SsrvpnNotifier.update('SSRVPN 已连接',
            this.lastNodeName.length > 0 ? this.lastNodeName : '已连接',
            `↓ ${this.formatSpeed(t.downloadSpeed)}  ↑ ${this.formatSpeed(t.uploadSpeed)}`);
        }
        this.notify();
      }).finally(() => {
        this.trafficPollRunning = false;
      });
    }, TRAFFIC_POLL_INTERVAL_MS);
  }

  private stopMonitors(): void {
    if (this.monitorTimer >= 0) {
      clearInterval(this.monitorTimer);
      this.monitorTimer = -1;
    }
    if (this.trafficTimer >= 0) {
      clearInterval(this.trafficTimer);
      this.trafficTimer = -1;
    }
    this.trafficPollRunning = false;
  }

  async diagnostics(): Promise<AppDiagnostics> {
    const d = new AppDiagnostics();
    d.coreRunning = this.state === ConnState.CONNECTED;
    d.vpnActive = this.state === ConnState.CONNECTED;
    d.clashApiReachable = await this.api.healthProbe();
    d.clashApiPort = API_PORT;
    d.startedAt = this.startedAt;
    d.uptimeSeconds = this.startedAt > 0 ? Math.floor((Date.now() - this.startedAt) / 1000) : 0;
    d.lastError = this.lastError;
    d.connectionState = String(this.state);
    d.currentNode = this.lastNodeName;
    d.uploadSpeed = this.traffic.uploadSpeed;
    d.downloadSpeed = this.traffic.downloadSpeed;
    d.uploadBytes = this.traffic.uploadBytes;
    d.downloadBytes = this.traffic.downloadBytes;
    return d;
  }

  formatSpeed(bytesPerSecond: number): string {
    if (bytesPerSecond < 1024) {
      return `${bytesPerSecond.toFixed(0)} B/s`;
    }
    if (bytesPerSecond < 1024 * 1024) {
      return `${(bytesPerSecond / 1024).toFixed(1)} KB/s`;
    }
    return `${(bytesPerSecond / 1024 / 1024).toFixed(2)} MB/s`;
  }

  formatBytes(total: number): string {
    if (total < 1024) {
      return `${total} B`;
    }
    if (total < 1024 * 1024) {
      return `${(total / 1024).toFixed(1)} KB`;
    }
    if (total < 1024 * 1024 * 1024) {
      return `${(total / 1024 / 1024).toFixed(1)} MB`;
    }
    return `${(total / 1024 / 1024 / 1024).toFixed(2)} GB`;
  }
}
