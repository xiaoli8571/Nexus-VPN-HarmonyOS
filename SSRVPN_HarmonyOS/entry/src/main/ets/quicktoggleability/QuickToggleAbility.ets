/**
 * 无界面快捷宿主：桌面图标长按「启动代理」与服务卡片点击的共同落点。
 *
 * 与 EntryAbility 的区别：不 loadContent 任何页面，onCreate 里直接跑
 * VpnQuickStart（后台连接/断开）。
 *
 * ── 会话守护者（2026-09-18 真机取证后的设计变更）──
 * 真机日志证实：`:vpn` 扩展进程内申请长时任务必然 401（连续任务只支持 UIAbility
 * 上下文），卡片宿主进程被回收后应用组失去一切驻留凭证，`:vpn` 在 0.3 秒内被系统
 * 连带回收（exit 0），表现为「卡片启动代理几秒即断且不自愈、卡片仍显示已连接」。
 * 因此连接成功（'on'/'already'）后本能力不再立即自毁，而是：
 *   1) 用自身 UIAbility 上下文注册 dataTransfer 连续任务（需通知权限，用户侧开启）；
 *   2) 保持存活并低频轮询跨进程权威状态（vpn_status 租约），会话终结即释放；
 *   3) 断开/失败/守护被拒 → 释放任务并自毁（removeMissionAfterTerminate 保证不留痕）。
 * 卡片端由此从「message 到 Form 进程内跑连接」改为「router 到本能力」，
 * Form 回调即刻返回，不再长时间占用宿主。
 *
 * 历史取证（2026-09-10）：本能力「闪一下」是系统为无页面 UIAbility 建启动窗的
 * 必然副产物而非崩溃；窗口隐形化与自毁时序修正保留（见 blindWindow/scheduleSelfDestroy）。
 * 重复点击/在途请求：单航班 + 末次意图合并，绝不吞点击，也不重复拉起。
 */
import { UIAbility, AbilityConstant, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import { BusinessError } from '@kit.BasicServicesKit';
import { VpnQuickStart } from '../commons/services/VpnQuickStart';
import { VpnGuardianPolicy } from '../commons/services/VpnGuardianPolicy';
import { ConnectionOrchestrator } from '../commons/services/ConnectionOrchestrator';
import { FormStateSync } from '../commons/services/FormStateSync';
import { ShortcutOutcomeLog, ShortcutOutcomeRecord } from '../commons/services/ShortcutOutcomeLog';
import { AppLogger } from '../commons/utils/AppLogger';

const TAG = 'QuickToggleAbility';
/** 明确「只连接」的快捷方式参数值（与 shortcuts_config.json 保持一致） */
const MODE_START = 'start';
/** 无参数/其它值一律按切换处理（服务卡片等入口共用） */
const MODE_TOGGLE = 'toggle';
/** 完全透明色：用于抹掉无界面能力的启动窗与主窗口底色 */
const COLOR_TRANSPARENT = '#00000000';
/**
 * 兜底寿命守护：无页面能力一旦悬留就是一块黑屏，任何异常路径都不允许它常驻。
 * 覆盖最慢建连路径（扩展拉起 + 就绪 + DNS 可达上限），守护模式接管后撤销。
 */
const MAX_LIFETIME_MS = 60000;
/** 自毁前等待 windowStage 就绪的上限（极快的「已连接」短路会早于窗口创建） */
const WINDOW_STAGE_GRACE_MS = 1500;
/** 轮询 windowStage 就绪的步长 */
const WINDOW_STAGE_POLL_MS = 100;
/** 守护期权威态轮询周期：低频，避免电量与调度噪音 */
const GUARDIAN_POLL_MS = 15000;
/** 连续缺失多少次才判定会话终结（≈30s，容忍扩展重启窗口与文件读写抖动） */
const GUARDIAN_MISS_THRESHOLD = 2;

export default class QuickToggleAbility extends UIAbility {
  private running: boolean = false;
  private pendingMode: string = '';
  private windowStageReady: boolean = false;
  private destroyScheduled: boolean = false;
  private destroyed: boolean = false;
  private lifetimeTimer: number = -1;
  /** 守护态：已持有连续任务并轮询会话租约 */
  private guardianActive: boolean = false;
  private bgTaskRegistered: boolean = false;
  private guardianTimer: number = -1;
  private guardianMisses: number = 0;
  private guardianChecking: boolean = false;
  /** 主窗口句柄：守护接管后用于最小化回桌面（设备不支持时降级为透明悬窗）。 */
  private mainWindow: window.Window | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.armLifetimeGuard();
    AppLogger.info(TAG, 'headless host created (no page loaded by design)');
    this.enqueue(this.resolveMode(want));
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 复用任务栈时的第二次点击（守护期间卡片再次点击 = 断开/重连意图）：必须生效。
    if (this.destroyed) {
      return;
    }
    AppLogger.info(TAG, 'headless host re-used (onNewWant)');
    this.enqueue(this.resolveMode(want));
  }

  onForeground(): void {
    this.drain();
  }

  onBackground(): void {
    // 前台的窗口生命周期可能被系统提前收起；在途任务照常继续，这里只做推进。
    this.drain();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.windowStageReady = true;
    this.blindWindow(windowStage);
    this.drain();
  }

  onWindowStageDestroy(): void {
    this.windowStageReady = false;
    this.mainWindow = null;
  }

  onDestroy(): void {
    this.destroyed = true;
    this.running = false;
    this.pendingMode = '';
    this.windowStageReady = false;
    this.clearLifetimeGuard();
    this.clearGuardianTimer();
    if (this.bgTaskRegistered) {
      // 兜底：进程被系统直接回收时尽力注销连续任务，避免残留登记。
      this.bgTaskRegistered = false;
      backgroundTaskManager.stopBackgroundRunning(this.context).catch((): void => {
        AppLogger.warn(TAG, 'continuous task cleanup failed at destroy');
      });
    }
    AppLogger.info(TAG, 'headless host destroyed');
  }

  /**
   * 把无内容窗口彻底变透明。
   * 这里全部是 UI-only 调用：headless 路径下必须独立 try/catch，
   * 任何失败只降级为「可能可见一闪」，绝不能把整个快捷动作带崩。
   */
  private blindWindow(windowStage: window.WindowStage): void {
    try {
      const mainWindow = windowStage.getMainWindowSync();
      mainWindow.setWindowBackgroundColor(COLOR_TRANSPARENT);
      this.mainWindow = mainWindow;
    } catch (error) {
      AppLogger.warn(TAG,
        `blind window failed (UI-only API): ${AppLogger.errText(error)}`);
    }
  }

  /** 守护接管后自动退回桌面（用户要求 2026-09-18）。minimize 在部分机型返回 801，
   *  失败仅降级为「透明窗口留在桌面」，不影响守护职责。 */
  private retreatToDesktop(): void {
    const target = this.mainWindow;
    if (target === null) {
      AppLogger.warn(TAG, 'guardian retreat skipped: no main window handle');
      return;
    }
    target.minimize().then((): void => {
      AppLogger.info(TAG, 'guardian minimized to desktop');
    }).catch((error: Error): void => {
      const err = error as BusinessError;
      AppLogger.warn(TAG, `guardian minimize unsupported code=${err.code} msg=${err.message}`);
    });
  }

  private resolveMode(want: Want): string {
    const params = want.parameters;
    if (params !== undefined && params['vpn_shortcut'] === MODE_START) {
      return MODE_START;
    }
    return MODE_TOGGLE;
  }

  /** 合并为最后一次有效意图，但绝不因能力已启动或前一次尚未完成而静默丢弃。 */
  private enqueue(mode: string): void {
    if (this.destroyed) {
      return;
    }
    this.pendingMode = mode;
    this.drain();
  }

  private drain(): void {
    if (this.destroyed || this.running || this.pendingMode.length === 0) {
      return;
    }
    const mode = this.pendingMode;
    this.pendingMode = '';
    this.running = true;
    const startedAt = Date.now();
    let outcome = 'failed';
    AppLogger.info(TAG, `quick action started: mode=${mode}`);
    VpnQuickStart.run(mode, this.context).then((result: string): void => {
      outcome = result;
      AppLogger.info(TAG, `quick action done: ${result}`);
      this.recordOutcome(mode, result, '', startedAt);
    }).catch((error: Error): void => {
      AppLogger.error(TAG, `quick action failed: ${error.message}`);
      this.recordOutcome(mode, 'failed', error.message, startedAt);
    }).finally((): void => {
      this.running = false;
      if (this.destroyed) {
        return;
      }
      if (this.pendingMode.length > 0) {
        this.drain();
        return;
      }
      if (VpnGuardianPolicy.shouldGuard(outcome)) {
        this.enterGuardian(outcome);
        return;
      }
      if (this.guardianActive) {
        // 守护期间动作以非守护结果收尾（断开/失败/no_node）：释放后自毁。
        this.releaseGuardian('action-' + outcome);
        return;
      }
      this.scheduleSelfDestroy();
    });
  }

  /**
   * 进入守护：用本 UIAbility 的上下文注册 dataTransfer 连续任务。
   * 成功 → 常驻并低频轮询权威租约；失败（如通知被禁用）→ 如实记录并恢复自毁路径，
   * 让系统按既有语义处理会话，绝不静默伪装成功。
   */
  private async enterGuardian(outcome: string): Promise<void> {
    this.clearLifetimeGuard();
    try {
      const entryWant: Want = {
        bundleName: 'com.ssrvpn.client',
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
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
      this.bgTaskRegistered = true;
      this.guardianActive = true;
      this.guardianMisses = 0;
      this.armGuardianPoll();
      this.retreatToDesktop();
      AppLogger.info(TAG, `guardian engaged after ${outcome} (dataTransfer continuous task registered)`);
    } catch (e) {
      const err = e as BusinessError;
      const detail = `guard-denied(code=${err.code} ${err.message})`;
      AppLogger.warn(TAG, `continuous task registration failed: ${detail}`);
      const record = new ShortcutOutcomeRecord();
      record.at = Date.now();
      record.mode = 'guard';
      record.result = 'failed';
      record.detail = detail;
      record.elapsedMs = 0;
      ShortcutOutcomeLog.record(this.context, record);
      this.scheduleSelfDestroy();
    }
  }

  private armGuardianPoll(): void {
    this.clearGuardianTimer();
    this.guardianTimer = setInterval((): void => {
      this.checkSessionAlive();
    }, GUARDIAN_POLL_MS);
  }

  private clearGuardianTimer(): void {
    if (this.guardianTimer >= 0) {
      clearInterval(this.guardianTimer);
      this.guardianTimer = -1;
    }
  }

  /** 跨进程权威判据（与 UI/Form 侧同源）：租约缺失连续达阈值 → 会话终结 → 释放守护。 */
  private checkSessionAlive(): void {
    if (this.destroyed || !this.guardianActive || this.running || this.guardianChecking) {
      return;
    }
    this.guardianChecking = true;
    const orchestrator = ConnectionOrchestrator.instance();
    orchestrator.init(this.context);
    orchestrator.authorityState().then((state): void => {
      this.guardianChecking = false;
      if (this.destroyed || !this.guardianActive) {
        return;
      }
      if (state.connected) {
        this.guardianMisses = 0;
        return;
      }
      this.guardianMisses = VpnGuardianPolicy.normalizeMisses(this.guardianMisses + 1);
      if (VpnGuardianPolicy.shouldReleaseOnLeaseLoss(this.guardianMisses, GUARDIAN_MISS_THRESHOLD)) {
        AppLogger.warn(TAG, `guardian releasing: session authority lost x${this.guardianMisses}`);
        this.releaseGuardian('session-lost');
      }
    }).catch((error: Error): void => {
      this.guardianChecking = false;
      // 读失败同样计入缺失：守护不能因权威通道损坏而无限驻留。
      if (this.destroyed || !this.guardianActive) {
        return;
      }
      AppLogger.warn(TAG, `guardian authority read failed: ${error.message}`);
      this.guardianMisses = VpnGuardianPolicy.normalizeMisses(this.guardianMisses + 1);
      if (VpnGuardianPolicy.shouldReleaseOnLeaseLoss(this.guardianMisses, GUARDIAN_MISS_THRESHOLD)) {
        this.releaseGuardian('authority-unreadable');
      }
    });
  }

  /** 释放守护：注销连续任务 → 尽力把真实状态刷到卡片 → 自毁。 */
  private releaseGuardian(reason: string): void {
    if (!this.guardianActive) {
      this.scheduleSelfDestroy();
      return;
    }
    this.guardianActive = false;
    this.clearGuardianTimer();
    const stop = this.bgTaskRegistered
      ? backgroundTaskManager.stopBackgroundRunning(this.context).catch((): void => {
        AppLogger.warn(TAG, `stopBackgroundRunning failed (${reason})`);
      })
      : Promise.resolve();
    this.bgTaskRegistered = false;
    AppLogger.info(TAG, `guardian released (${reason})`);
    stop.then((): Promise<void> => {
      return FormStateSync.calibrate(this.context).then((snapshot): Promise<void> => {
        return FormStateSync.publish(this.context, snapshot);
      }).catch((): void => {
        AppLogger.warn(TAG, 'guardian release card refresh failed');
      });
    }).finally((): void => {
      this.scheduleSelfDestroy();
    });
  }

  private recordOutcome(mode: string, result: string, detail: string, startedAt: number): void {
    const record = new ShortcutOutcomeRecord();
    record.at = Date.now();
    record.mode = mode;
    record.result = result;
    record.detail = detail.length > 0 ? detail : VpnQuickStart.lastDetail();
    record.elapsedMs = Date.now() - startedAt;
    ShortcutOutcomeLog.record(this.context, record);
  }

  /**
   * 自毁时序修正：terminateSelf 必须发生在 windowStage 创建之后。
   * 若在 onCreate 里同步短路完（如「已连接」直接返回 already）就立刻 terminateSelf，
   * 框架会以 null windowStage 走窗口销毁路径（真机 hilog 里的 [JUA2516]null windowStage），
   * 窗口状态错位且有把启动窗留在屏幕上的风险。这里最多等 WINDOW_STAGE_GRACE_MS。
   */
  private scheduleSelfDestroy(): void {
    if (this.destroyScheduled || this.destroyed || this.guardianActive) {
      return;
    }
    this.destroyScheduled = true;
    if (this.windowStageReady) {
      this.terminate('window-stage-ready');
      return;
    }
    let waited = 0;
    const step = (): void => {
      if (this.destroyed) {
        return;
      }
      if (this.windowStageReady) {
        this.terminate('window-stage-late');
        return;
      }
      waited = waited + WINDOW_STAGE_POLL_MS;
      if (waited >= WINDOW_STAGE_GRACE_MS) {
        this.terminate('window-stage-timeout');
        return;
      }
      setTimeout(step, WINDOW_STAGE_POLL_MS);
    };
    setTimeout(step, WINDOW_STAGE_POLL_MS);
  }

  private terminate(reason: string): void {
    if (this.destroyed) {
      return;
    }
    this.destroyed = true;
    this.clearLifetimeGuard();
    this.clearGuardianTimer();
    AppLogger.info(TAG, `terminateSelf (${reason})`);
    this.context.terminateSelf().catch((error: Error): void => {
      // 自毁失败不重试（重试可能循环）：只记录，交给兜底寿命守护与系统回收。
      AppLogger.warn(TAG, `terminateSelf failed: ${error.message}`);
    });
  }

  private armLifetimeGuard(): void {
    this.clearLifetimeGuard();
    this.lifetimeTimer = setTimeout((): void => {
      this.lifetimeTimer = -1;
      if (this.guardianActive) {
        return;
      }
      AppLogger.warn(TAG, 'lifetime guard fired: forcing terminate to avoid a stuck blank window');
      this.terminate('lifetime-guard');
    }, MAX_LIFETIME_MS);
  }

  private clearLifetimeGuard(): void {
    if (this.lifetimeTimer >= 0) {
      clearTimeout(this.lifetimeTimer);
      this.lifetimeTimer = -1;
    }
  }
}
