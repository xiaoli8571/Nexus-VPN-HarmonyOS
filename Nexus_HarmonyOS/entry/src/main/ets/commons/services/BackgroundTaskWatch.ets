/**
 * 长时任务取消监听（官方 backgroundTaskManager.on('continuousTaskCancel')，API 15+）。
 *
 * 为什么需要：官方《Background Tasks Kit 接入规范》明确禁止「用户主动停止
 * （删除长时任务通知等方式）或系统取消/暂停长时任务后，立即再次申请」；
 * 用户删除任务通知 = 用户主动停止后台任务，应用必须能感知并刷新进程内的
 * 驻留登记（否则 UiGuardian/QuickToggleAbility 的记账与真实状态脱钩：
 * registered 恒 true → 后续路径不再补挂，用户以为还受保护）。
 *
 * 本模块只做「感知 + 清账 + 广播」，绝不自动重申请 —— 重新申请只允许由
 * 显式用户操作（连接按钮 / 卡片 / 快捷方式）触发（见 UiGuardian 抑制态）。
 *
 * 注册点：EntryAbility.onCreate / QuickToggleAbility.onCreate（同进程，幂等）。
 */
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import { AppLogger } from '../utils/AppLogger';
import { UiGuardian } from './UiGuardian';
import { TaskProgressUpdater } from './TaskProgressUpdater';

const TAG = 'BackgroundTaskWatch';

/** 取消事件监听者（同步回调；实现方自行容错，绝不抛出） */
export interface ContinuousTaskCancelListener {
  onContinuousTaskCancel(id: number, reason: string): void;
}

export class BackgroundTaskWatch {
  private static watching: boolean = false;
  private static listeners: ContinuousTaskCancelListener[] = [];
  private static lastCancelId: number = -1;
  private static lastCancelReason: string = '';
  private static lastCancelAt: number = 0;

  /** 幂等注册（进程级一次）。失败只记录，不影响主流程（旧固件可能不支持该事件）。 */
  static ensure(): void {
    if (BackgroundTaskWatch.watching) {
      return;
    }
    BackgroundTaskWatch.watching = true;
    try {
      backgroundTaskManager.on('continuousTaskCancel',
        (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
          BackgroundTaskWatch.dispatch(info);
        });
      AppLogger.info(TAG, 'continuousTaskCancel listener registered');
    } catch (e) {
      AppLogger.warn(TAG,
        `continuousTaskCancel listener registration failed: ${AppLogger.errText(e)}`);
    }
  }

  /** 事件分发：先做核心清账（进度心跳止损 + 守护抑制态），再广播给监听者。 */
  private static dispatch(info: backgroundTaskManager.ContinuousTaskCancelInfo): void {
    const id: number = (info !== undefined && info !== null) ? info.id : -1;
    const reason: string = (info !== undefined && info !== null && typeof info.reason === 'string')
      ? info.reason : '';
    BackgroundTaskWatch.lastCancelId = id;
    BackgroundTaskWatch.lastCancelReason = reason;
    BackgroundTaskWatch.lastCancelAt = Date.now();
    AppLogger.warn(TAG, `continuous task canceled externally: id=${id} reason=${reason}`);
    // 任务已不存在：进度心跳立刻止损（继续 publish 会持续报错）
    TaskProgressUpdater.detach();
    // 刷新守护记账并进入抑制态（窗口内自动补挂一律跳过；仅显式用户操作可清除）
    UiGuardian.noteExternalCancel();
    for (const l of BackgroundTaskWatch.listeners.slice()) {
      try {
        l.onContinuousTaskCancel(id, reason);
      } catch (e) {
        AppLogger.warn(TAG, `cancel listener threw: ${AppLogger.errText(e)}`);
      }
    }
  }

  static addListener(listener: ContinuousTaskCancelListener): void {
    if (!BackgroundTaskWatch.listeners.includes(listener)) {
      BackgroundTaskWatch.listeners.push(listener);
    }
  }

  static removeListener(listener: ContinuousTaskCancelListener): void {
    const idx = BackgroundTaskWatch.listeners.indexOf(listener);
    if (idx >= 0) {
      BackgroundTaskWatch.listeners.splice(idx, 1);
    }
  }

  /** 最近一次取消的时间戳（0 = 从未），供诊断展示。 */
  static lastCancelAtMs(): number {
    return BackgroundTaskWatch.lastCancelAt;
  }

  /** 最近一次取消原因文本（诊断用，可能为空）。 */
  static lastReason(): string {
    return BackgroundTaskWatch.lastCancelReason;
  }
}
