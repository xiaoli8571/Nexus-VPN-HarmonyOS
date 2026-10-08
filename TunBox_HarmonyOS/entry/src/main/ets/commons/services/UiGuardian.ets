/**
 * UI 进程会话守护（App 内手动连接路径的防杀）：
 *
 * 真机取证（2026-09-24）：只有卡片/快捷方式路径（QuickToggleAbility）注册了
 * dataTransfer 连续任务；App 内手动点启动的路径没有任何驻留凭证 —— UI 进程退
 * 后台几分钟即被系统回收，VpnExtensionAbility 无独立驻留资格，跟着宿主进程组
 * 被连带杀掉（表现为"启动没几分钟就被杀"）。
 *
 * 本服务在连接成功后用当前 UIAbility 上下文注册同一款 dataTransfer 连续任务，
 * 断开/失败时释放。生命周期由页面驱动（不自带轮询）：
 * HomePage 的 connectionListener 在状态变化时 engage/release。
 *
 * 合规边界（2026-10-07 对照《Background Tasks Kit 接入规范》）：
 *  - dataTransfer 的规定场景是"非托管形式的上传、下载"；本用途（隧道保活）按
 *    "持续数据传输"口径使用，原定用途需在 AGC 应用介绍中提前声明；
 *  - 用户主动删除长时任务通知 = 用户主动停止：由 BackgroundTaskWatch 感知后
 *    本服务进入抑制态（autoEngageSuppressed），抑制期内的自动补挂一律跳过，
 *    只有显式用户操作（连接按钮 / 卡片 / 快捷方式）才会清除抑制并允许重挂；
 *  - dataTransfer 要求周期更新进度（首次不得超过 10 分钟），由
 *    TaskProgressUpdater 用申请返回的 notificationId 承担。
 */
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import type { BusinessError } from '@kit.BasicServicesKit';
import { AppLogger } from '../utils/AppLogger';
import { TaskProgressUpdater } from './TaskProgressUpdater';

const TAG = 'UiGuardian';

export class UiGuardian {
  private static registered: boolean = false;
  private static engaging: boolean = false;
  /**
   * 用户主动停止后台任务（删除长时任务通知）后的自动重挂抑制态。
   * 进程级布尔：仅由显式用户操作或进程重启清除（规范：不得立即再次申请）。
   */
  private static autoEngageSuppressed: boolean = false;

  /** 连接成功后调用：注册 dataTransfer 连续任务（失败如实记录，绝不伪装成功） */
  static async engage(context: Context): Promise<void> {
    if (UiGuardian.registered || UiGuardian.engaging) {
      return;
    }
    if (UiGuardian.autoEngageSuppressed) {
      AppLogger.info(TAG, 'guardian engage skipped: user canceled the continuous task earlier (explicit action required)');
      return;
    }
    UiGuardian.engaging = true;
    try {
      const agentRequest: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: 'com.tunbox.client',
          moduleName: 'entry',
          abilityName: 'EntryAbility'
        }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent = await wantAgent.getWantAgent(agentRequest);
      // 字符串数组重载（官方示例形态）是唯一返回任务通知 id 的重载；
      // 单值枚举重载（BackgroundMode.DATA_TRANSFER = 1）返回 void。
      const modes: string[] = ['dataTransfer'];
      const res = await backgroundTaskManager.startBackgroundRunning(context, modes, agent);
      UiGuardian.registered = true;
      // 接管任务通知 id：dataTransfer 官方要求周期更新进度（首次不得超过 10 分钟）
      TaskProgressUpdater.attach(res !== undefined && res !== null ? res.notificationId : -1);
      AppLogger.info(TAG, 'guardian engaged (dataTransfer continuous task registered)');
    } catch (e) {
      const err = e as BusinessError;
      AppLogger.warn(TAG, `guardian engage failed (code=${err.code} ${err.message})`);
    } finally {
      UiGuardian.engaging = false;
    }
  }

  /** 断开/失败后调用：释放连续任务（幂等）。stopBackgroundRunning 必须 UIAbility 上下文。 */
  static async release(context: Context): Promise<void> {
    if (!UiGuardian.registered) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      AppLogger.info(TAG, 'guardian released');
    } catch (e) {
      const err = e as BusinessError;
      AppLogger.warn(TAG, `guardian release failed (code=${err.code} ${err.message})`);
    } finally {
      UiGuardian.registered = false;
      TaskProgressUpdater.detach();
    }
  }

  static isRegistered(): boolean {
    return UiGuardian.registered;
  }

  /**
   * 外部取消（用户删除长时任务通知 / 系统取消）的记账入口，由 BackgroundTaskWatch 调用：
   * 刷新登记状态 + 进入抑制态 + 进度心跳止损。绝不在这里重新申请任务（规范红线）。
   */
  static noteExternalCancel(): void {
    if (UiGuardian.registered) {
      AppLogger.warn(TAG, 'guardian registration cleared by external cancel');
    }
    UiGuardian.registered = false;
    UiGuardian.autoEngageSuppressed = true;
    TaskProgressUpdater.detach();
  }

  /** 显式用户操作（连接按钮 / 卡片 / 快捷方式）入口调用：清除抑制，允许重新挂任务。 */
  static clearExternalCancelSuppression(): void {
    if (UiGuardian.autoEngageSuppressed) {
      AppLogger.info(TAG, 'auto-engage suppression cleared by explicit user action');
    }
    UiGuardian.autoEngageSuppressed = false;
  }

  static isAutoEngageSuppressed(): boolean {
    return UiGuardian.autoEngageSuppressed;
  }
}
