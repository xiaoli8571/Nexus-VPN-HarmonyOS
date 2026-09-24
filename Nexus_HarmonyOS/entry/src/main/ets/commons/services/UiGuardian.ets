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
 */
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import type { BusinessError } from '@kit.BasicServicesKit';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'UiGuardian';

export class UiGuardian {
  private static registered: boolean = false;
  private static engaging: boolean = false;

  /** 连接成功后调用：注册 dataTransfer 连续任务（失败如实记录，绝不伪装成功） */
  static async engage(context: Context): Promise<void> {
    if (UiGuardian.registered || UiGuardian.engaging) {
      return;
    }
    UiGuardian.engaging = true;
    try {
      const agentRequest: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: 'com.nexus.client',
          moduleName: 'entry',
          abilityName: 'EntryAbility'
        }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent = await wantAgent.getWantAgent(agentRequest);
      await backgroundTaskManager.startBackgroundRunning(context,
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
      UiGuardian.registered = true;
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
    }
  }

  static isRegistered(): boolean {
    return UiGuardian.registered;
  }
}
