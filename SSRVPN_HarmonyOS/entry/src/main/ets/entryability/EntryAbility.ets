/**
 * 应用入口 Ability
 * 移植自 upstream: SSRVPN_Android/lib/main.dart + app.dart + startup/*（启动编排的 ArkTS 等价）
 */
import { UIAbility, AbilityConstant, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SettingsService } from '../commons/services/SettingsService';
import { AppLogger } from '../commons/utils/AppLogger';
import { ThemeService } from '../theme/ThemeService';


const TAG = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  private pendingMode: string = '';
  private windowReady: boolean = false;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppLogger.info(TAG, 'onCreate');
    ThemeService.init(this.context).catch((e: BusinessError) => {
      AppLogger.error(TAG, `theme init failed: ${e.message}`);
    });
    SettingsService.init(this.context).catch((e: BusinessError) => {
      AppLogger.error(TAG, `settings init failed: ${e.message}`);
    });
    this.captureWant(want);
  }

  /** 应用已在前台/后台存活时, 快捷方式与卡片点击走这里 */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.captureWant(want);
  }

  /** 任务栈复用或后台恢复时再次投递尚未消费的快捷意图。 */
  onForeground(): void {
    this.publishPendingWant();
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
