/**
 * 后台静默测速 —— 现已改为 `LatencyEngine` 的**薄适配层**（5.6.0 延迟测试重做）。
 *
 * ## 为什么砍掉旧实现
 *
 * 旧版本自带一整套并行管线：10 路 lane、整批级 URL 降级、通道熔断、整批零成功
 * 判定、负缓存冷却、`manualPriorityCount` 手动抢占、`backgroundGeneration` 代次、
 * 45s 自动重排定时器。它与页面里的手动批测是**两套彼此竞争的实现**，且各自维护
 * 超时/取消/落盘语义 —— 真机上表现为：
 *   · 用户点「测速」却看到后台批次的结果（抢占竞态）；
 *   · 一次通道故障把 143 个节点盖章成「全部超时」并写进排序快照；
 *   · 冷启动静默全量测速与页面打开时的测速互相打断。
 *
 * 现在**只有一个引擎**（`LatencyEngine`，单航班、五态语义、有界并发、进度/取消），
 * 后台路径与页面前台路径走完全相同的代码，只是参数不同（`force=false` 跳过新鲜结果）。
 * 于是本文件不再需要维护任何并发状态。
 *
 * ## 保留的语义
 *
 *  - 冷启动后静默补齐缺失的延迟（`scheduleStartup`）；
 *  - 新订阅导入后只测该订阅的节点（`testSubscription`）；
 *  - 不产生 Toast / 弹窗 / 进度提示，只渐进更新 `LatencyController`；
 *  - 走真实内核协议栈（`ensureLatencyApi`），不把 TCP 可达性冒充代理延迟。
 *    内核确实不可用时，引擎会退化为**明确标注**的离线粗略通道（状态 OFFLINE），
 *    且**绝不**把通道故障写成节点超时。
 */
import { AppLogger } from '../utils/AppLogger';
import { ConnectionOrchestrator } from './ConnectionOrchestrator';
import { LatencyController } from './LatencyController';
import { LatencyEngine, LatencyRunOptions, LATENCY_TIMEOUT_MS, LATENCY_TEST_URL } from './LatencyEngine';
import { ProxyNode } from '../models/ProxyNode';
import { SettingsService } from './SettingsService';
import { SubscriptionService } from './SubscriptionService';

const TAG = 'BackgroundLatency';
/** 冷启动静默测速的延迟：让首屏渲染与订阅加载先完成，别和 UI 抢资源。 */
const STARTUP_DELAY_MS = 1200;

export class BackgroundLatencyService {
  private static startupScheduled: boolean = false;
  /** 静默批次是否在跑（仅用于日志与去重；真正的单航班由 LatencyEngine 保证） */
  private static running: boolean = false;

  /**
   * 每个 UI 进程仅安排一次冷启动全量测速。
   * 静默批次不强制重测（`force=false`）：只补缺失/过期结果，不重新拨号。
   */
  static scheduleStartup(context: Context, delayMs: number = STARTUP_DELAY_MS): void {
    if (BackgroundLatencyService.startupScheduled) {
      return;
    }
    BackgroundLatencyService.startupScheduled = true;
    setTimeout((): void => {
      BackgroundLatencyService.testAll(context).catch((e: Object): void => {
        AppLogger.warn(TAG, `startup latency failed: ${AppLogger.errText(e)}`);
      });
    }, Math.max(0, delayMs));
  }

  /** 静默测试全部节点（跳过仍新鲜的结果） */
  static async testAll(context: Context): Promise<void> {
    await BackgroundLatencyService.execute(context, null);
  }

  /** 订阅导入/刷新成功后只测该订阅的节点 */
  static async testSubscription(context: Context, subscriptionId: string): Promise<void> {
    if (subscriptionId.length === 0) {
      return;
    }
    await BackgroundLatencyService.execute(context, subscriptionId);
  }

  /**
   * 手动测速已不再需要与后台互相抢占：两者共用同一个单航班引擎，
   * 新批次会自动作废旧批次。保留这两个方法只为兼容既有调用点。
   */
  static beginManualPriority(): void {
    // 用户手测优先：直接取消在途的静默批次（引擎里是单航班，新批次自会抢占）
    LatencyEngine.cancelCurrent();
  }

  static endManualPriority(context: Context): void {
    // 无需续跑积压队列：页面自己的批次结束后，下次进页面/刷新会自然补齐。
  }

  static isManualPriorityActive(): boolean {
    return false;
  }

  /**
   * 执行一次静默批次。
   * @param subscriptionId null = 全部节点
   */
  private static async execute(context: Context, subscriptionId: string | null): Promise<void> {
    if (BackgroundLatencyService.running || LatencyEngine.isRunning()) {
      // 单航班：已有批次（不论来自页面还是后台）在跑就不叠加
      AppLogger.info(TAG, 'silent batch skipped: a latency run is already in flight');
      return;
    }
    BackgroundLatencyService.running = true;
    try {
      const orchestrator = ConnectionOrchestrator.instance();
      orchestrator.init(context);
      await SettingsService.init(context);
      const subs = SubscriptionService.instance();
      await subs.init(context);

      const nodes: ProxyNode[] = [];
      for (const node of subs.nodes) {
        if (subscriptionId === null || node.subscriptionId === subscriptionId) {
          nodes.push(node);
        }
      }
      if (nodes.length === 0) {
        return;
      }

      // 通道：已连接复用隧道 controller；未连接尝试无头内核；都不可用则 null
      // → 引擎走离线粗略通道（状态 OFFLINE，绝不冒充代理延迟）
      const api = await orchestrator.ensureLatencyApi();
      const settings = await SettingsService.load();
      const url = settings.testLatencyUrl.trim().length > 0
        ? settings.testLatencyUrl.trim() : LATENCY_TEST_URL;

      const opts = new LatencyRunOptions();
      opts.force = false;              // 静默批次只补缺失/过期结果
      opts.timeoutMs = LATENCY_TIMEOUT_MS;
      opts.onProgress = null;          // 静默：不驱动任何 UI
      opts.onResult = null;            // LatencyController 自己会通知监听者
      const run = LatencyEngine.start(api, nodes, url, opts);
      const progress = await run.run();
      LatencyEngine.release(run);
      LatencyController.flushNow();

      AppLogger.info(TAG, `silent batch done nodes=${nodes.length} `
        + `channel=${progress.channel} measured=${progress.measured} timeout=${progress.timeout} `
        + `failed=${progress.failed} skipped=${progress.skipped} `
        + `coreUnavailable=${progress.coreUnavailable}`);
    } catch (e) {
      AppLogger.warn(TAG, `silent batch failed: ${AppLogger.errText(e)}`);
    } finally {
      BackgroundLatencyService.running = false;
    }
  }
}
