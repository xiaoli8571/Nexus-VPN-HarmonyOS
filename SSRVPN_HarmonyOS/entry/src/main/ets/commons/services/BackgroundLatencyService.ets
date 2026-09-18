/**
 * 静默后台节点测速服务。
 *
 * 设计目标：
 * - 应用冷启动后测速全部节点；
 * - 新订阅导入成功后只测速该订阅的节点；
 * - 不产生 Toast、弹窗或进度提示，只渐进更新 LatencyController；
 * - 复用真实 Clash/Mihomo 协议栈测速，不把裸 TCP 可达性冒充代理延迟；
 * - 单航班串行批次 + 有界并发，避免重复触发和过高并发造成假超时。
 */
import { AppSettings } from '../models/AppSettings';
import { ProxyNode } from '../models/ProxyNode';
import { AppLogger } from '../utils/AppLogger';
import { ConnectionOrchestrator } from './ConnectionOrchestrator';
import { LatencyFailKind } from './ClashApiService';
import { LatencyController } from './LatencyController';
import { NodeLatencyRecord, NodeSortModes, NodeSortSnapshot } from './NodeSortPersistence';
import { SettingsService } from './SettingsService';
import { SubscriptionService } from './SubscriptionService';

const TAG = 'BackgroundLatency';
// 后台测速采用更高的有界并发，尽快完成大订阅测速；失败复测仍限制并发，
// 避免瞬时网络拥塞把可用节点误判为超时。
const LANES = 16;
const NODE_TIMEOUT_MS = 3000;
const RECOVERY_TIMEOUT_MS = 4000;
const RECOVERY_LANES = 6;
const BATCH_DEADLINE_MS = 60000;
const TEST_CORE_KEEP_ALIVE_MS = 90000;
const FALLBACK_URLS: string[] = [
  'https://cp.cloudflare.com/generate_204',
  'https://www.gstatic.com/generate_204'
];

class ProbeResult {
  delay: number = -2;
  failKind: string = LatencyFailKind.UNTESTED;
}

export class BackgroundLatencyService {
  private static running: boolean = false;
  private static pendingAll: boolean = false;
  private static pendingSubscriptions: Set<string> = new Set<string>();
  private static startupScheduled: boolean = false;
  /** 手动测速拥有最高优先级。大于 0 时后台任务不启动，正在运行的后台 worker 尽快退出。 */
  private static manualPriorityCount: number = 0;
  /** 后台批次代次。手动测速开始时递增，使旧 worker 和旧结果持久化立即失效。 */
  private static backgroundGeneration: number = 0;

  /** 用户开始单测或批量手动测速：立即抢占后台自动测速。 */
  static beginManualPriority(): void {
    BackgroundLatencyService.manualPriorityCount = BackgroundLatencyService.manualPriorityCount + 1;
    BackgroundLatencyService.backgroundGeneration = BackgroundLatencyService.backgroundGeneration + 1;
    // 仅使后台 worker 逻辑退出还不够：已经发往 Mihomo 的 /delay 请求仍会占用通道直到超时。
    // 手动测速开始时直接销毁所有在途延迟请求，立即释放测速通道；后续后台旧结果也会因
    // generation 不匹配被丢弃，确保手动单测和手动批量测速真正抢占后台自动测速。
    const cancelled = ConnectionOrchestrator.instance().api.cancelInflight();
    AppLogger.info(TAG, `manual latency took priority count=${BackgroundLatencyService.manualPriorityCount} `
      + `cancelledBackgroundRequests=${cancelled}`);
  }

  /** 手动测速结束：释放优先级，并继续此前排队但尚未执行的后台请求。 */
  static endManualPriority(context: Context): void {
    BackgroundLatencyService.manualPriorityCount = Math.max(0,
      BackgroundLatencyService.manualPriorityCount - 1);
    if (BackgroundLatencyService.manualPriorityCount === 0
      && (BackgroundLatencyService.pendingAll || BackgroundLatencyService.pendingSubscriptions.size > 0)) {
      BackgroundLatencyService.drain(context).catch((e: Object): void => {
        AppLogger.warn(TAG, `resume queued background latency failed: ${e instanceof Error ? e.message : String(e)}`);
      });
    }
  }

  static isManualPriorityActive(): boolean {
    return BackgroundLatencyService.manualPriorityCount > 0;
  }

  /** 每个 UI 进程仅安排一次冷启动全量测速。 */
  static scheduleStartup(context: Context, delayMs: number = 800): void {
    if (BackgroundLatencyService.startupScheduled) {
      return;
    }
    BackgroundLatencyService.startupScheduled = true;
    setTimeout((): void => {
      BackgroundLatencyService.testAll(context).catch((e: Object): void => {
        AppLogger.warn(TAG, `startup latency failed: ${e instanceof Error ? e.message : String(e)}`);
      });
    }, Math.max(0, delayMs));
  }

  static async testAll(context: Context): Promise<void> {
    BackgroundLatencyService.pendingAll = true;
    BackgroundLatencyService.pendingSubscriptions.clear();
    await BackgroundLatencyService.drain(context);
  }

  static async testSubscription(context: Context, subscriptionId: string): Promise<void> {
    if (subscriptionId.length === 0) {
      return;
    }
    if (!BackgroundLatencyService.pendingAll) {
      BackgroundLatencyService.pendingSubscriptions.add(subscriptionId);
    }
    await BackgroundLatencyService.drain(context);
  }

  private static async drain(context: Context): Promise<void> {
    // 手动测速期间保留后台请求但绝不启动，让用户操作立即获得测速通道与网络资源。
    if (BackgroundLatencyService.running || BackgroundLatencyService.isManualPriorityActive()) {
      return;
    }
    BackgroundLatencyService.running = true;
    try {
      for (;;) {
        // 手动测速可以在后台批次之间随时抢占，未开始的请求继续留在队列。
        if (BackgroundLatencyService.isManualPriorityActive()) {
          return;
        }
        const all = BackgroundLatencyService.pendingAll;
        const ids: string[] = [];
        if (!all) {
          for (const id of BackgroundLatencyService.pendingSubscriptions) {
            ids.push(id);
          }
        }
        if (!all && ids.length === 0) {
          return;
        }
        BackgroundLatencyService.pendingAll = false;
        BackgroundLatencyService.pendingSubscriptions.clear();
        await BackgroundLatencyService.run(context, all ? null : ids);
      }
    } finally {
      BackgroundLatencyService.running = false;
      // 手动测速未结束时不自旋；endManualPriority 会在优先级释放后恢复队列。
      if (!BackgroundLatencyService.isManualPriorityActive()
        && (BackgroundLatencyService.pendingAll || BackgroundLatencyService.pendingSubscriptions.size > 0)) {
        BackgroundLatencyService.drain(context).catch((e: Object): void => {
          AppLogger.warn(TAG, `queued latency failed: ${e instanceof Error ? e.message : String(e)}`);
        });
      }
    }
  }

  private static urls(settings: AppSettings): string[] {
    const out: string[] = [];
    const primary = settings.testLatencyUrl.trim();
    if (primary.length > 0) {
      out.push(primary);
    }
    for (const fallback of FALLBACK_URLS) {
      if (out.indexOf(fallback) < 0) {
        out.push(fallback);
      }
    }
    return out;
  }

  private static async run(context: Context, subscriptionIds: string[] | null): Promise<void> {
    const generation = BackgroundLatencyService.backgroundGeneration;
    // 手动测速拥有绝对优先级：后台批次开始前再次检查，避免排队切换时发生竞态。
    if (BackgroundLatencyService.isManualPriorityActive()) {
      return;
    }
    const subs = SubscriptionService.instance();
    const orchestrator = ConnectionOrchestrator.instance();
    orchestrator.init(context);
    await SettingsService.init(context);
    await subs.init(context);
    const settings = await SettingsService.load();
    const nodes: ProxyNode[] = [];
    for (const node of subs.nodes) {
      if (subscriptionIds === null || subscriptionIds.indexOf(node.subscriptionId) >= 0) {
        nodes.push(node);
      }
    }
    if (nodes.length === 0) {
      return;
    }

    const connected = await orchestrator.isAuthoritativelyConnected();
    let channelReady = connected;
    if (!connected) {
      channelReady = await orchestrator.ensureTestCore(subs, settings);
    }
    if (!channelReady) {
      AppLogger.info(TAG, `silent batch skipped: latency core unavailable nodes=${nodes.length}`);
      return;
    }

    const urls = BackgroundLatencyService.urls(settings);
    if (urls.length === 0) {
      return;
    }
    const deadline = Date.now() + BATCH_DEADLINE_MS;
    const results: NodeLatencyRecord[] = [];
    for (const node of nodes) {
      const rec = new NodeLatencyRecord();
      rec.name = node.name;
      rec.latency = -2;
      rec.failKind = LatencyFailKind.UNTESTED;
      results.push(rec);
    }

    let cursor = 0;
    let urlIndex = 0;
    let urlFailureStreak = 0;
    const workerCount = Math.min(LANES, nodes.length);
    const workers: Promise<void>[] = [];
    for (let lane = 0; lane < workerCount; lane++) {
      workers.push((async (): Promise<void> => {
        for (;;) {
          const index = cursor;
          cursor = cursor + 1;
          if (index >= nodes.length || Date.now() >= deadline
            || BackgroundLatencyService.isManualPriorityActive()
            || generation !== BackgroundLatencyService.backgroundGeneration) {
            return;
          }
          const probe = await BackgroundLatencyService.probe(
            orchestrator, nodes[index], urls[urlIndex], NODE_TIMEOUT_MS);
          // 手动测速已抢占时，丢弃这个刚完成的后台结果，避免覆盖用户手测结果。
          if (BackgroundLatencyService.isManualPriorityActive()
            || generation !== BackgroundLatencyService.backgroundGeneration) {
            return;
          }
          if (probe.delay >= 0) {
            urlFailureStreak = 0;
          } else if (probe.failKind === LatencyFailKind.TIMEOUT
            || probe.failKind === LatencyFailKind.NETWORK_UNREACHABLE) {
            urlFailureStreak = urlFailureStreak + 1;
            if (urlFailureStreak >= 4 && urlIndex + 1 < urls.length) {
              urlIndex = urlIndex + 1;
              urlFailureStreak = 0;
            }
          }
          BackgroundLatencyService.apply(nodes[index], probe, results[index]);
        }
      })());
    }
    await Promise.all(workers);

    // 仅对首轮失败者低并发复测。成功结果不重复采样，兼顾速度；失败结果用更宽预算
    // 和备用 URL 去除瞬时拥塞、单测试站不可达导致的假超时。
    const failedIndexes: number[] = [];
    for (let i = 0; i < results.length; i++) {
      if (results[i].failKind === LatencyFailKind.TIMEOUT
        || results[i].failKind === LatencyFailKind.NETWORK_UNREACHABLE) {
        failedIndexes.push(i);
      }
    }
    let retryCursor = 0;
    const retryWorkers: Promise<void>[] = [];
    const retryLanes = Math.min(RECOVERY_LANES, failedIndexes.length);
    for (let lane = 0; lane < retryLanes; lane++) {
      retryWorkers.push((async (): Promise<void> => {
        for (;;) {
          const position = retryCursor;
          retryCursor = retryCursor + 1;
          if (position >= failedIndexes.length || Date.now() >= deadline
            || BackgroundLatencyService.isManualPriorityActive()
            || generation !== BackgroundLatencyService.backgroundGeneration) {
            return;
          }
          const index = failedIndexes[position];
          const retryUrl = urls.length > 1 ? urls[(urlIndex + 1) % urls.length] : urls[urlIndex];
          const probe = await BackgroundLatencyService.probe(
            orchestrator, nodes[index], retryUrl, RECOVERY_TIMEOUT_MS);
          // 用户手动测速已开始时，后台错误复测立即让路且不写回旧结果。
          if (BackgroundLatencyService.isManualPriorityActive()
            || generation !== BackgroundLatencyService.backgroundGeneration) {
            return;
          }
          if (probe.delay >= 0) {
            BackgroundLatencyService.apply(nodes[index], probe, results[index]);
          }
        }
      })());
    }
    await Promise.all(retryWorkers);
    LatencyController.flushNow();

    let verdicts = 0;
    for (const rec of results) {
      if (rec.latency !== -2) {
        verdicts = verdicts + 1;
      }
    }
    if (verdicts > 0) {
      const previous = NodeSortSnapshot.fromJsonText(settings.nodeSortSnapshot);
      const allNames: string[] = [];
      for (const node of subs.nodes) {
        allNames.push(node.name);
      }
      const snapshot = NodeSortSnapshot.buildAuto(Date.now(), results, previous, allNames);
      settings.nodeSortSnapshot = snapshot.toJsonText();
      // 静默测速更新数据，但尊重用户当前选择的默认/手动排序模式。
      if (settings.nodeSortMode === NodeSortModes.AUTO) {
        settings.nodeSortMode = NodeSortModes.AUTO;
      }
      await SettingsService.save(settings);
    }
    AppLogger.info(TAG, `silent batch done nodes=${nodes.length} verdicts=${verdicts} connected=${connected}`);
    if (!connected) {
      orchestrator.scheduleTestCoreRecycle(TEST_CORE_KEEP_ALIVE_MS);
    }
  }

  private static async probe(orchestrator: ConnectionOrchestrator, node: ProxyNode,
    url: string, timeoutMs: number): Promise<ProbeResult> {
    const out = new ProbeResult();
    try {
      const probe = await orchestrator.api.testLatencyDetailed(node.name, url, timeoutMs);
      out.delay = probe.delayMs;
      out.failKind = probe.delayMs >= 0 ? LatencyFailKind.NONE
        : (probe.failKind.length > 0 ? probe.failKind : LatencyFailKind.NETWORK_UNREACHABLE);
    } catch (e) {
      out.delay = -1;
      out.failKind = LatencyFailKind.NETWORK_UNREACHABLE;
    }
    return out;
  }

  private static apply(node: ProxyNode, probe: ProbeResult, rec: NodeLatencyRecord): void {
    rec.name = node.name;
    rec.failKind = probe.failKind;
    if (probe.failKind === LatencyFailKind.CORE_NOT_READY
      || probe.failKind === LatencyFailKind.PORT_ONLY
      || probe.failKind === LatencyFailKind.UNSUPPORTED
      || probe.failKind === LatencyFailKind.UNTESTED) {
      rec.latency = -2;
      return;
    }
    rec.latency = probe.delay;
    LatencyController.set(node.name, probe.delay);
  }
}
