/**
 * 延迟测试引擎（重做，5.6.0）—— 唯一入口
 *
 * ## 为什么废弃旧方案
 *
 * 旧实现（NodeSelectionPage.runBatch + ConnectionOrchestrator.ensureTestCore）在
 * 未连接时会**专门拉起第二个无头 mihomo 内核**（第二个 VpnExtensionAbility 进程，
 * 写 mihomo_test_config.yaml，无 TUN），再自己开 10 路 lane 逐节点打
 * /proxies/{name}/delay。代价与缺陷（真机取证 2026-09-19）：
 *
 *  1. 点测速要先等第二内核起来（DoH 预解析 → 停旧扩展 → 600ms 等待 → 启新扩展 →
 *     健康轮询，20s 超时），第一个数字迟迟不出现；
 *  2. 两个内核共用 controller 端口与 secret（且共享 cache 目录）：secret 被覆盖后
 *     全部 401 → 全显超时；cache.db 的 bbolt 文件锁与 core.log 争用；
 *  3. 第二份完整 mihomo（provider + geo 数据 + 缓存）在移动端的内存/耗电开销；
 *  4. 队列等待与探测共用一份超时预算，排在饱和 lane 后面的好节点被写成超时
 *     （FlClash 专门为这个缺陷把两者拆开）；
 *  5. 命中"10s 内测速缓存"时直接返回"无需重新测速"，用户点了像没反应。
 *
 * ## 新方案的事实依据（真机实测 + mihomo 源码）
 *
 *  - `(*Proxy).URLTest` 直接 `p.DialContext` 到出站适配器，**绕过 TUN 与规则引擎**
 *    → 只要内核已加载，测速与 VPN 是否连接无关；
 *  - 已连接时隧道的 controller 就在 127.0.0.1:9090 且**带着全部真实节点**
 *    （实测 106 节点 / 16 组，全部在 PROXY 组内）→ 直接复用，零额外启动；
 *  - `/group/{name}/delay` **不采用**：对 url-test 系组忽略传入 url、对非 Selector
 *    组会 ForceSet("") 清掉固定选择、无并发上限（每节点一 goroutine）、失败节点
 *    从 map 静默消失且可能返回 200 + 部分结果。逐节点才有状态码与可流式进度。
 *  - **取消不释放内核 socket**：getProxyDelay 用 context.Background()，abort 只是
 *    客户端行为，内核会继续拨号到自己的 timeout。故并发上限是控制负载的唯一手段。
 *  - `timeout` 用 16 位解析 → 上限 32767，且必须显式传（不传 400）。
 *  - `history.delay == 0` 表示失败；`LastDelayForTestUrl` 用 65535 表示没测过。
 *    **0 绝不能当延迟显示**，否则死节点会以"0ms"排到最前。
 *
 * ## 通道分层
 *
 *  1. `core`：**权威通道**。已连接 → 隧道 controller；未连接 → UI 进程内无头内核
 *     （无 TUN，独立端口与 secret，实测解析 1ms 级）。真实代理延迟。
 *  2. `offline`：**粗略通道**。两条内核路径都不可用时，用 TCP/TLS/QUIC 探活给
 *     服务器可达性，状态为 OFFLINE、UI 显示 `≈123ms`，**绝不冒充代理延迟**。
 */
import { AppLogger } from '../utils/AppLogger';
import { ClashApiService, LatencyFailKind, LatencyProbeResult } from './ClashApiService';
import { ConnectionOrchestrator } from './ConnectionOrchestrator';
import { LatencyChannel, LatencyPolicy, LatencyRecord, LatencyState } from './LatencyState';
import { LatencyController } from './LatencyController';
import { ProxyNode } from '../models/ProxyNode';
import { DirectLatencyTester } from './DirectLatencyTester';

const TAG = 'LatencyEngine';

/** 并发探测数。内核侧并发无上限保护，客户端必须自律（主流取值 5~16）。 */
export const LATENCY_CONCURRENCY = 16;
/** 单节点探测超时（mihomo 内部默认 5000ms）。 */
export const LATENCY_TIMEOUT_MS = LatencyPolicy.DEFAULT_TIMEOUT_MS;
/** 首批请求错峰抖动上限，避免整批同时撞内核（Clash Verge Rev 同款做法）。 */
const STAGGER_MAX_MS = 200;
/**
 * 单批硬上限：超过即把剩余节点保持「未测」，绝不盖章为失败。
 * 导出是为了让回归套件能**真跑**出 deadline 场景（而不是只读源码断言），
 * 见 scripts/verify-latency-engine-runtime.mjs。
 */
export const BATCH_DEADLINE_MS = 90000;
/** 连续「通道不可用」达到该次数即中止本批（内核不在/凭证错配，整批结论无效）。 */
const CORE_NOT_READY_ABORT_STREAK = 3;
/** `force=false` 时，多久以内的实测结果视为新鲜、可跳过重测。 */
export const FRESH_RESULT_MS = 5 * 60 * 1000;
/**
 * 批次结束后测速内核的空闲宽限（毫秒）。90s 内来回切页面/连点测速复用同一内核，
 * 超过则回收，避免临时进程在后台长期常驻。仅对未连接时的 headless 内核生效。
 */
export const LATENCY_CORE_IDLE_MS = 90000;

/**
 * 默认测速 URL：**http** 的 generate_204 —— 对齐主流 Clash 客户端（CFW/CMFA/v2rayN）
 * 的出厂默认；过节点对 gstatic 的 TLS 握手在受限出口会挂起，导致「正常节点测出超时」。
 * 捆绑内核对 unified-delay 的第二次 HEAD 失败是非致命回退（adapter.go），测试不会失败。
 */
export const LATENCY_TEST_URL = 'http://www.gstatic.com/generate_204';
export const LATENCY_TEST_URL_ALT = 'http://cp.cloudflare.com/generate_204';

/** 进度快照（UI 直接绑定） */
export class LatencyProgress {
  total: number = 0;
  finished: number = 0;
  measured: number = 0;
  timeout: number = 0;
  failed: number = 0;
  cancelled: number = 0;
  /** 因结果仍新鲜而跳过的节点数（force=false 时） */
  skipped: number = 0;
  /** 通道不可用（内核/凭证层面）的连续命中总数 */
  coreNotReady: number = 0;
  /** 整批因通道不可用而中止：此时**不能**把结果当节点结论 */
  coreUnavailable: boolean = false;
  /** 本批实际使用的通道：LatencyChannel.CORE / OFFLINE */
  channel: string = LatencyChannel.CORE;
  running: boolean = false;

  done(): boolean {
    return !this.running;
  }
}

export type LatencyResultSink = (rec: LatencyRecord) => void;
export type LatencyProgressSink = (p: LatencyProgress) => void;

/** 批次参数 */
export class LatencyRunOptions {
  timeoutMs: number = LATENCY_TIMEOUT_MS;
  /** true=全部重测；false=跳过仍新鲜的实测结果（进页面自动测速用） */
  force: boolean = true;
  onResult: LatencyResultSink | null = null;
  onProgress: LatencyProgressSink | null = null;
}

/**
 * 单批测速会话。同一个引擎上同时只允许一个会话；新会话使旧会话立即作废。
 */
export class LatencyRun {
  private readonly api: ClashApiService | null;
  private readonly nodes: ProxyNode[];
  private readonly url: string;
  private readonly timeoutMs: number;
  private readonly force: boolean;
  private readonly onResult: LatencyResultSink | null;
  private readonly onProgress: LatencyProgressSink | null;
  private readonly progress: LatencyProgress = new LatencyProgress();
  /** 代次：被 cancel / 新批次抢占时递增，旧回调据此丢弃结果 */
  private generation: number = 0;
  private cancelled: boolean = false;
  private finished: boolean = false;
  private coreNotReadyStreak: number = 0;
  /** 本批是否已尝试过"重新解析通道凭证"（每批最多一次） */
  private channelRecoveryTried: boolean = false;
  private cursor: number = 0;

  constructor(api: ClashApiService | null, nodes: ProxyNode[], url: string, timeoutMs: number,
    force: boolean, onResult: LatencyResultSink | null, onProgress: LatencyProgressSink | null) {
    this.api = api;
    this.nodes = nodes;
    this.url = url;
    this.timeoutMs = timeoutMs;
    this.force = force;
    this.onResult = onResult;
    this.onProgress = onProgress;
    this.progress.total = nodes.length;
    this.progress.channel = api === null ? LatencyChannel.OFFLINE : LatencyChannel.CORE;
  }

  isRunning(): boolean {
    return !this.finished && !this.cancelled;
  }

  currentProgress(): LatencyProgress {
    return this.progress;
  }

  /**
   * 取消本批。
   *
   * 注意：mihomo 的 /proxies/{n}/delay 用 context.Background()，**abort HTTP 请求
   * 不会让内核停止拨号**（仍跑到自己的 timeout）。cancel 的作用是把结果标记为
   * 「已取消」并把 UI 从"测试中"解放，而非真正减负 —— 负载由 LATENCY_CONCURRENCY
   * 控制。这里仍调用 cancelInflight()，因为它能立刻释放客户端侧 http 句柄，避免
   * 页面退出后旧回调继续写 UI。
   */
  cancel(): void {
    if (this.cancelled || this.finished) {
      return;
    }
    this.cancelled = true;
    this.generation = this.generation + 1;
    if (this.api !== null) {
      this.api.cancelInflight();
    }
    AppLogger.info(TAG, `latency run cancelled finished=${this.progress.finished}/${this.progress.total} `
      + `channel=${this.progress.channel}`);
  }

  /** 内部：新批次抢占/通道不可用时作废本批剩余工作（不再发布结果） */
  private invalidate(): void {
    this.cancelled = true;
    this.generation = this.generation + 1;
  }

  /**
   * 收尾：把本批遗留的 TESTING 标记收回 `--`。
   *
   * 为什么必须在引擎内部做：被取消、被抢占、被通道故障作废（invalidate）的节点，
   * probeThroughCore/probeOffline 都不会为它发布任何记录，那条记录会**永远停在
   * TESTING** —— UI 行上就是一个永不停止的转圈。这不是节点结论，必须收回。
   *
   * 旧实现依赖每个调用方自己记得清理（浏览器里就是 NodeSelectionPage 的
   * clearTestingMarks），漏一个入口就漏一个永久转圈。收尾归引擎 = 引擎自己在
   * 所有退出路径（正常结束 / 取消 / 作废 / 异常）上都保证不再留下 TESTING。
   */
  private clearOwnTestingMarks(): void {
    let cleared = 0;
    for (const node of this.nodes) {
      if (LatencyController.stateFor(node.name) === LatencyState.TESTING) {
        LatencyController.setRecord(LatencyRecord.untested(node.name));
        cleared = cleared + 1;
      }
    }
    if (cleared > 0) {
      AppLogger.info(TAG, `latency cleanup: ${cleared} node(s) left TESTING -> untested `
        + `(cancelled=${this.cancelled} unavailable=${this.progress.coreUnavailable})`);
      LatencyController.notify();
    }
  }

  /** 执行整批，返回最终进度 */
  async run(): Promise<LatencyProgress> {
    const generation = this.generation;
    const startedAt = Date.now();
    const deadlineAt = startedAt + BATCH_DEADLINE_MS;
    AppLogger.info(TAG, `latency batch start nodes=${this.nodes.length} `
      + `concurrency=${LATENCY_CONCURRENCY} timeout=${this.timeoutMs}ms force=${this.force} `
      + `channel=${this.progress.channel} url=${this.url}`);

    const lanes = Math.min(LATENCY_CONCURRENCY, Math.max(1, this.nodes.length));
    const workers: Promise<void>[] = [];
    for (let w = 0; w < lanes; w++) {
      workers.push(this.worker(w, generation, deadlineAt));
    }
    // worker 抛异常也必须收尾：否则 TESTING 标记会漏在控制器里（行上永久转圈）。
    // 引擎对所有退出路径负责，调用方不需要知道这个内部约定。
    try {
      await Promise.all(workers);
    } catch (e) {
      AppLogger.warn(TAG, `latency batch worker error: ${AppLogger.errText(e)}`);
    } finally {
      this.clearOwnTestingMarks();
    }

    this.finished = true;
    this.progress.running = false;
    this.emitProgress();
    AppLogger.info(TAG, `latency batch done nodes=${this.nodes.length} channel=${this.progress.channel} `
      + `measured=${this.progress.measured} timeout=${this.progress.timeout} failed=${this.progress.failed} `
      + `cancelled=${this.progress.cancelled} skipped=${this.progress.skipped} `
      + `notReady=${this.progress.coreNotReady} unavailable=${this.progress.coreUnavailable} `
      + `elapsed=${Date.now() - startedAt}ms`);
    // 内核回收归引擎管：批次结束后挂一个**宽限**回收（而不是立刻停）。测速内核重建
    // 要经历 DoH + 停旧扩展 + 600ms 等待 + 启新扩展 + 健康轮询（秒级），用户来回切
    // 页面/连点测速时应复用同一内核；宽限期内再次测速会 cancel 掉这个定时器。
    // 仅内核通道才需要回收：离线通道没有内核可回收；已连接时该方法内部会因
    // orchestrator busy 直接返回，绝不动用户正在用的 VPN（见 scheduleTestCoreRecycle）。
    if (this.api !== null) {
      ConnectionOrchestrator.instance().scheduleTestCoreRecycle(LATENCY_CORE_IDLE_MS);
    }
    return this.progress;
  }

  /** 领取下一个待测节点下标（单线程事件循环，无需锁） */
  private nextIndex(): number {
    const i = this.cursor;
    this.cursor = this.cursor + 1;
    return i;
  }

  private isAborted(generation: number): boolean {
    return this.cancelled || this.generation !== generation;
  }

  /**
   * 单个 worker：循环领取节点并探测。
   *
   * 队列等待与探测计时**分离**：testLatencyDetailed 的超时只覆盖这一次 HTTP，
   * worker 在两次探测之间不累积 deadline 压力，故排在后面的节点不会被前面的
   * 节点耗尽预算（旧实现共用一份 deadline，队尾节点大面积假超时）。
   */
  private async worker(lane: number, generation: number, deadlineAt: number): Promise<void> {
    // 首批错峰：0~200ms，避免整批同时打内核
    if (lane > 0) {
      const jitter = Math.floor(Math.random() * STAGGER_MAX_MS);
      await new Promise<void>((resolve) => setTimeout(() => resolve(), jitter));
    }
    for (;;) {
      if (this.isAborted(generation)) {
        return;
      }
      const index = this.nextIndex();
      if (index >= this.nodes.length) {
        return;
      }
      if (Date.now() >= deadlineAt) {
        AppLogger.warn(TAG, `latency batch deadline hit; nodes from index ${index} left untested`);
        return;
      }
      const node = this.nodes[index];

      // force=false：仍新鲜的实测结果直接跳过，不浪费一次拨号
      if (!this.force) {
        const existing = LatencyController.recordFor(node.name);
        if (existing !== null && existing.channel === LatencyChannel.CORE && existing.hasValue()
          && Date.now() - existing.atMs < FRESH_RESULT_MS) {
          this.progress.skipped = this.progress.skipped + 1;
          this.progress.finished = this.progress.finished + 1;
          this.emitProgress();
          continue;
        }
      }

      LatencyController.markTesting(node.name);
      if (this.isAborted(generation)) {
        return;
      }
      // 单节点异常必须就地收敛。若让异常冒泡出 worker，Promise.all 会立刻拒绝，
      // 其余 lane 变成孤儿：批次已经宣布结束（finished=true）、调用方也已 release，
      // 它们的结果却还在后面陆续落库 —— 用户看到的是"进度条跑完了，列表还在变"。
      // 真实 ClashApiService 自己吞异常返回 failKind，所以这条路径平时不触发；
      // 但引擎不能依赖调用方永不抛错。
      let outcome: ProbeOutcome;
      try {
        outcome = this.api === null
          ? await this.probeOffline(node, generation)
          : await this.probeThroughCore(node, generation);
      } catch (e) {
        AppLogger.warn(TAG, `latency probe threw for one node; keeping it untested: `
          + `${AppLogger.errText(e)}`);
        // 不落任何结论（保持未测），但必须计入进度，否则进度条永远到不了 total
        this.progress.finished = this.progress.finished + 1;
        this.emitProgress();
        continue;
      }
      if (this.isAborted(generation)) {
        return;
      }
      if (!outcome.publishable) {
        // 通道不可用：不是节点结论 → 保持「未测」，并在连续命中后中止整批
        this.progress.finished = this.progress.finished + 1;
        this.emitProgress();
        continue;
      }
      this.publish(node.name, outcome.record);
      this.progress.finished = this.progress.finished + 1;
      this.emitProgress();
    }
  }

  /**
   * 通道失联时的自愈：内核**中途重启会换掉 external-controller 的 secret**
   * （真机实测：批测进行到 53/106 时隧道重启，secret 变更，随后所有 /delay 全部
   * 连接异常）。此时无需中止整批 —— 重新解析一次隧道凭证就能接着测。
   *
   * 由编排器实现（只有它知道 secret 从哪读、内核是不是刚重启过）；这里只负责
   * 在**连续失联并且本批已经有实测结果**时触发一次，且同批最多救一次，避免
   * 内核真死时把时间浪费在反复读盘上。
   */
  private async tryRecoverChannel(): Promise<void> {
    if (this.channelRecoveryTried) {
      return;
    }
    if (this.coreNotReadyStreak < CORE_NOT_READY_ABORT_STREAK) {
      return;
    }
    this.channelRecoveryTried = true;
    const api = this.api;
    if (api === null) {
      return;
    }
    try {
      const recovered = await ConnectionOrchestrator.instance().refreshLatencyEndpoint(api);
      if (recovered) {
        AppLogger.info(TAG, 'latency channel recovered: endpoint secret re-resolved');
        this.coreNotReadyStreak = 0;
      } else {
        AppLogger.warn(TAG, 'latency channel recovery failed: core still unusable');
      }
    } catch (e) {
      AppLogger.warn(TAG, `latency channel recovery error: ${AppLogger.errText(e)}`);
    }
  }

  /** 通道可用性判定的探测结果包装 */
  private async probeThroughCore(node: ProxyNode, generation: number): Promise<ProbeOutcome> {
    const api = this.api;
    if (api === null) {
      return ProbeOutcome.notPublishable();
    }
    const probe = await api.testLatencyDetailed(node.name, this.url, this.timeoutMs, 16);
    if (this.isAborted(generation)) {
      // 用户取消 / 新批次抢占 / 通道作废：本批剩余工作全部作废。
      //
      // 这里**故意不发布任何记录**（包括"已取消"），原因是一个真实竞态：
      // `start()` 抢占旧批次走的是同一个 `cancel()`，旧批次的 worker 会在
      // cancel 之后才异步拿到探测结果。如果此时写一条记录，就会盖掉**新批次**
      // 刚刚打上的 TESTING 标记 —— UI 上表现为"正在测速的节点突然变成已取消"。
      // 因此 abort 之后只计数、不落库；遗留的 TESTING 由收尾的
      // clearOwnTestingMarks() 统一收回 `--`（"我们不知道"，这是诚实的）。
      //
      // 注意：只有拿到结果后才计数（failKind !== NONE 说明这次探测确实被打断），
      // 取消瞬间刚好成功返回的探测不计入 cancelled。
      if (probe.failKind !== LatencyFailKind.NONE) {
        this.progress.cancelled = this.progress.cancelled + 1;
      }
      return ProbeOutcome.notPublishable();
    }
    if (probe.failKind === LatencyFailKind.CORE_NOT_READY) {
      // 通道问题，不是节点问题。两种成因必须分开处理：
      //  - 内核中途重启 / secret 被换掉（真机实测：106 节点批测进行中隧道重启，
      //    此后 49 个节点全部连接异常）→ 重新解析隧道 secret 还能救回来；
      //  - 内核真的不在了 → 连续命中后作废整批。
      this.coreNotReadyStreak = this.coreNotReadyStreak + 1;
      this.progress.coreNotReady = this.progress.coreNotReady + 1;
      await this.tryRecoverChannel();
      if (this.isAborted(generation)) {
        return ProbeOutcome.notPublishable();
      }
      // 自愈已尝试过（或本轮不满足自愈条件）仍然连续失联 → 通道确实不可用。
      // 此时**作废整批**：剩余节点保持「未测」，页面提示"内核不可用，本轮未测"。
      // 绝不把通道故障写进任何节点的结论里 —— 这是旧实现"内核一抖半张列表变红"的根因。
      if (this.coreNotReadyStreak >= CORE_NOT_READY_ABORT_STREAK) {
        this.progress.coreUnavailable = true;
        AppLogger.warn(TAG, `latency batch aborted: core/channel unavailable `
          + `streak=${this.coreNotReadyStreak} measured=${this.progress.measured} `
          + `recoveryTried=${this.channelRecoveryTried}`);
        this.invalidate();
      }
      return ProbeOutcome.notPublishable();
    }
    this.coreNotReadyStreak = 0;
    if (probe.failKind === LatencyFailKind.NONE && LatencyPolicy.isValidDelay(probe.delayMs)) {
      this.progress.measured = this.progress.measured + 1;
      return ProbeOutcome.publishable(
        LatencyRecord.measured(node.name, probe.delayMs, LatencyChannel.CORE, Date.now()));
    }
    const state = LatencyEngine.mapFailure(probe.failKind, probe.httpCode);
    if (state === LatencyState.TIMEOUT) {
      this.progress.timeout = this.progress.timeout + 1;
    } else {
      this.progress.failed = this.progress.failed + 1;
    }
    return ProbeOutcome.publishable(LatencyRecord.failed(node.name, state, Date.now()));
  }

  /**
   * 离线粗略探测（无内核可用时的兜底通道）。
   * 结果状态是 OFFLINE（UI 显示 `≈ms`），语义是"服务器可达"，不是代理延迟。
   * `-2`（协议不支持离线探测）保持「未测」，绝不写成失败。
   */
  private async probeOffline(node: ProxyNode, generation: number): Promise<ProbeOutcome> {
    // 本地/环回地址的"可达性"不是代理延迟，而是本机自己的握手开销。实测里这类节点
    // 会以个位数毫秒的 `≈2ms` 排到列表最前，看起来"最快"其实毫无意义。保持未测。
    if (LatencyPolicy.isLoopbackOrLocal(node.server)) {
      this.progress.skipped = this.progress.skipped + 1;
      return ProbeOutcome.notPublishable();
    }
    let delay = -1;
    try {
      delay = await DirectLatencyTester.testNode(node, this.timeoutMs);
    } catch (e) {
      delay = -1;
    }
    if (this.isAborted(generation)) {
      return ProbeOutcome.notPublishable();
    }
    if (delay === -2) {
      // 无法离线探测：保持未测（不污染排序快照）
      this.progress.skipped = this.progress.skipped + 1;
      return ProbeOutcome.notPublishable();
    }
    if (delay >= 0) {
      this.progress.measured = this.progress.measured + 1;
      return ProbeOutcome.publishable(
        LatencyRecord.measured(node.name, delay, LatencyChannel.OFFLINE, Date.now()));
    }
    this.progress.failed = this.progress.failed + 1;
    return ProbeOutcome.publishable(
      LatencyRecord.failed(node.name, LatencyState.FAILED, Date.now(), LatencyChannel.OFFLINE));
  }

  private publish(nodeName: string, rec: LatencyRecord): void {
    LatencyController.setRecord(rec);
    if (this.onResult !== null) {
      this.onResult(rec);
    }
  }

  private emitProgress(): void {
    this.progress.running = !this.finished && !this.cancelled;
    if (this.onProgress !== null) {
      this.onProgress(this.progress);
    }
  }
}

/** 单次探测的结果包装：区分「节点结论」与「通道不可用（无结论）」 */
class ProbeOutcome {
  publishable: boolean = false;
  record: LatencyRecord = new LatencyRecord();

  static publishable(rec: LatencyRecord): ProbeOutcome {
    const o = new ProbeOutcome();
    o.publishable = true;
    o.record = rec;
    return o;
  }

  static notPublishable(): ProbeOutcome {
    const o = new ProbeOutcome();
    o.publishable = false;
    return o;
  }
}

/**
 * 引擎：持有当前会话，保证同一时刻只有一批在跑。
 */
export class LatencyEngine {
  private static current: LatencyRun | null = null;

  /**
   * 把 ClashApiService 的失败分类映射到状态。
   *
   * 严格区分三件事：
   *  - TIMEOUT：内核按预算判定超时（504）
   *  - FAILED：拨号失败 / 状态码不符 / delay==0（503）、节点已不存在（404）
   *  - CANCELLED：客户端主动中止
   */
  static mapFailure(failKind: string, httpCode: number): number {
    if (failKind === LatencyFailKind.TIMEOUT) {
      return LatencyState.TIMEOUT;
    }
    if (failKind === LatencyFailKind.CANCELLED) {
      return LatencyState.CANCELLED;
    }
    if (httpCode === 504) {
      return LatencyState.TIMEOUT;
    }
    return LatencyState.FAILED;
  }

  /**
   * 启动一批测速。已有批次会被作废（其结果全部丢弃）。
   * @param api 内核通道；null 表示走离线粗略通道
   */
  static start(api: ClashApiService | null, nodes: ProxyNode[], url: string,
    opts: LatencyRunOptions): LatencyRun {
    if (LatencyEngine.current !== null) {
      LatencyEngine.current.cancel();
    }
    const run = new LatencyRun(api, nodes, url, opts.timeoutMs, opts.force,
      opts.onResult, opts.onProgress);
    LatencyEngine.current = run;
    return run;
  }

  /** 取消当前批次（页面退出 / 用户点取消 / 网络切换） */
  static cancelCurrent(): void {
    if (LatencyEngine.current !== null) {
      LatencyEngine.current.cancel();
    }
  }

  static isRunning(): boolean {
    return LatencyEngine.current !== null && LatencyEngine.current.isRunning();
  }

  static currentProgress(): LatencyProgress | null {
    return LatencyEngine.current === null ? null : LatencyEngine.current.currentProgress();
  }

  /** 批次结算后清理引用 */
  static release(run: LatencyRun): void {
    if (LatencyEngine.current === run) {
      LatencyEngine.current = null;
    }
  }
}
