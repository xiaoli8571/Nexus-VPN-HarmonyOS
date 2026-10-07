/**
 * 应用入口 Ability
 * 移植自 upstream: SSRVPN_Android/lib/main.dart + app.dart + startup/*（启动编排的 ArkTS 等价）
 */
import { UIAbility, AbilityConstant, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SettingsService } from '../commons/services/SettingsService';
import { ConnectionOrchestrator } from '../commons/services/ConnectionOrchestrator';
import { UiGuardian } from '../commons/services/UiGuardian';
import { AppLogger } from '../commons/utils/AppLogger';
import { ThemeService } from '../theme/ThemeService';


const TAG = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  private pendingMode: string = '';
  private windowReady: boolean = false;
  /** 自愈编排单航班：冷启动与回前台都走它，避免重复拉起隧道 */
  private healTask: Promise<string> | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppLogger.info(TAG, 'onCreate');
    ThemeService.init(this.context).catch((e: BusinessError) => {
      AppLogger.error(TAG, `theme init failed: ${e.message}`);
    });
    SettingsService.init(this.context).catch((e: BusinessError) => {
      AppLogger.error(TAG, `settings init failed: ${e.message}`);
    });
    this.captureWant(want);
    // 后台被杀后被重新拉起（含桌面图标/卡片/快捷方式等任何入口）：只要磁盘上的
    // 用户意图仍是"想连着"而隧道已经没了，就自动重建 —— 原来这里什么都不做，
    // 用户只能看到"已断开"，得手动再点一次连接。
    this.scheduleSelfHeal('cold-start');
  }

  /** 应用已在前台/后台存活时, 快捷方式与卡片点击走这里 */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.captureWant(want);
  }

  /**
   * 任务栈复用或后台恢复时再次投递尚未消费的快捷意图，并补做一次自愈。
   *
   * 为什么每次回前台都要查：`dataTransfer` 长时任务只是"尽量别被杀"，被杀是常态。
   * 进程重启后进程内一切归零（state / 心跳 / UiGuardian.registered 都不可信），
   * 只有磁盘上的用户意图 + 跨进程心跳租约还在 —— 自愈判定正是基于这两者。
   */
  onForeground(): void {
    this.publishPendingWant();
    this.scheduleSelfHeal('foreground');
  }

  onBackground(): void {
    // 进后台时若隧道确实活着，补一次驻留凭证：UiGuardian.registered 是进程级静态
    // 布尔，进程重启后必然为 false，只有 HomePage 存在时才会被重新 engage ——
    // 卡片/快捷方式路径拉起的会话没有页面，这里兜住最后一环。
    this.reengageGuardian().catch((e: Error): void => {
      AppLogger.warn(TAG, `background guardian re-engage failed: ${e.message}`);
    });
  }

  private scheduleSelfHeal(trigger: string): void {
    if (this.healTask !== null) {
      return;
    }
    // 有明确的用户请求（桌面快捷方式 / 服务卡片）时不介入：
    // 那条路径自己会走 VpnQuickStart，语义是"切换"，自愈再并行拉一次连接
    // 只会和它抢 connectSeq，把一次点击变成两次互相打断的建连。
    if (this.pendingMode.length > 0) {
      AppLogger.info(TAG, `self-heal(${trigger}) skipped: explicit request "${this.pendingMode}" in flight`);
      return;
    }
    const task = ConnectionOrchestrator.instance()
      .restoreKilledSession(this.context)
      .then((reason: string): string => {
        AppLogger.info(TAG, `self-heal(${trigger}): ${reason}`);
        return reason;
      })
      .catch((e: Error): string => {
        AppLogger.warn(TAG, `self-heal(${trigger}) failed: ${e.message}`);
        return 'error';
      })
      .finally((): void => {
        if (this.healTask === task) {
          this.healTask = null;
        }
      });
    this.healTask = task;
  }

  /** 仅在"权威状态确实已连接"时补驻留凭证，避免断开后残留空耗电。 */
  private async reengageGuardian(): Promise<void> {
    if (UiGuardian.isRegistered()) {
      return;
    }
    const authority = await ConnectionOrchestrator.instance().authorityState();
    if (authority.connected) {
      await UiGuardian.engage(this.context);
    }
  }

  /**
   * 外部启动请求统一入口（对应 AutoConnectRequestRegistry）：
   * - vpn_shortcut=start      桌面图标长按「启动代理」快捷方式 → 未连接则连接
   * - auto_connect=1          服务卡片"连接/断开" → 切换语义
   * 通过 AppStorage 递增 seq + mode 交给 HomePage 消费（前台 @Watch 即时响应,
   * 冷启动由 onPageShow 兜底消费）。
   */
  private captureWant(want: Want): void {
    let mode = '';
    if (want.parameters && want.parameters['vpn_shortcut'] === 'start') {
      mode = 'start';
    } else if (want.parameters && want.parameters['auto_connect'] === '1') {
      mode = 'toggle';
    }
    if (mode.length === 0) {
      return;
    }
    // 单槽保留最后一次有效请求。页面未挂载或 Ability 正在恢复时不丢失意图。
    this.pendingMode = mode;
    this.publishPendingWant();
  }

  private publishPendingWant(): void {
    if (!this.windowReady || this.pendingMode.length === 0) {
      return;
    }
    const mode = this.pendingMode;
    this.pendingMode = '';
    AppStorage.setOrCreate('vpn_request_mode', mode);
    const seq = (AppStorage.get<number>('vpn_request_seq') ?? 0) + 1;
    AppStorage.setOrCreate('vpn_request_seq', seq);
    AppLogger.info(TAG, `vpn request queued: mode=${mode} seq=${seq}`);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    ThemeService.init(this.context).then(() => {
      windowStage.loadContent('pages/HomePage', (err) => {
        if (err.code) {
          hilog.error(0x0, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
          return;
        }
        this.windowReady = true;
        this.publishPendingWant();
        windowStage.getMainWindow((err2, win) => {
          if (!err2.code) {
            ThemeService.syncSystemBars(win).catch(() => {});
            AppStorage.setOrCreate('main_window', win);
          }
        });
      });
    }).catch((e: BusinessError) => {
      AppLogger.error(TAG, `theme restore failed: ${e.message}`);
      windowStage.loadContent('pages/HomePage', (err) => {
        if (!err.code) {
          this.windowReady = true;
          this.publishPendingWant();
        }
      });
    });
  }

  onDestroy(): void {
    AppLogger.info(TAG, 'onDestroy: UI ability released; preserve active VPN runtime artifacts');
    // UI Ability 被系统回收不代表用户主动停止 VPN。运行配置、Extension 状态和恢复工件
    // 由 VpnExtensionAbility 在确认会话终止后统一清理，避免破坏仍在后台运行的隧道及其恢复链。
  }
}
