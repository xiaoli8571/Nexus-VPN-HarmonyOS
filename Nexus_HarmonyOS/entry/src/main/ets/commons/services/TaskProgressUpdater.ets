/**
 * dataTransfer 长时任务的进度心跳（官方要求，见 startBackgroundRunning 官方示例）。
 *
 * 官方原文：「当长时任务类型包含数据传输(dataTransfer)时，应用需要更新进度，其他
 * 类型不需要」；「如果进度长时间（首次更新超过10分钟）未更新，数据传输的长时任务
 * 会被取消」。更新方式 = 用申请时返回的 notificationId 发一帧 downloadTemplate
 * 系统实况通知（typeCode 固定 8 = dataTransfer，slotType 必须为 LIVE_VIEW），
 * 该通道不需要另行申请实况窗场景权益。
 *
 * 本实现的取舍：
 *  - 进度值对 VPN 没有真实百分比语义 → 以「已连接分钟数 % 100」推进进度条，
 *    fileName 展示已连接时长；title/text 展示运行状态。更新内容仅限进度展示，
 *    与接入规范对 dataTransfer 的豁免条款（可更新进度信息）保持一致。
 *  - 发布失败（通知被禁用 1600004 / 任务已不存在等）只做节流日志，不重试风暴；
 *    任务被外部取消时由 BackgroundTaskWatch → detach() 止损。
 */
import { notificationManager } from '@kit.NotificationKit';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'TaskProgressUpdater';
/** 更新周期：官方窗口为 10 分钟，这里 5 分钟留一倍冗余 */
const UPDATE_INTERVAL_MS: number = 5 * 60 * 1000;
/** dataTransfer 类型实况通知固定 typeCode（官方示例：当前仅支持 8） */
const TYPE_CODE_DATA_TRANSFER: number = 8;
/** 仅支持的模板名（官方：downloadTemplate） */
const TEMPLATE_NAME: string = 'downloadTemplate';
/** 失败日志节流窗口：避免周期性刷屏 */
const FAIL_LOG_THROTTLE_MS: number = 10 * 60 * 1000;

export class TaskProgressUpdater {
  private static taskNotificationId: number = -1;
  private static timer: number = -1;
  private static startedAt: number = 0;
  private static lastFailLogAt: number = 0;

  /** 长时任务申请成功后调用：接管返回的 notificationId，立即推一帧并起周期心跳。 */
  static attach(notificationId: number): void {
    TaskProgressUpdater.detach();
    if (typeof notificationId !== 'number' || notificationId < 0) {
      AppLogger.warn(TAG, `attach skipped: invalid notificationId (${notificationId})`);
      return;
    }
    TaskProgressUpdater.taskNotificationId = notificationId;
    TaskProgressUpdater.startedAt = Date.now();
    TaskProgressUpdater.push();
    TaskProgressUpdater.timer = setInterval((): void => {
      TaskProgressUpdater.push();
    }, UPDATE_INTERVAL_MS);
    AppLogger.info(TAG, `progress heartbeat attached (taskNotificationId=${notificationId})`);
  }

  /** 释放 / 断开 / 任务取消时调用（幂等）。 */
  static detach(): void {
    if (TaskProgressUpdater.timer >= 0) {
      clearInterval(TaskProgressUpdater.timer);
      TaskProgressUpdater.timer = -1;
    }
    TaskProgressUpdater.taskNotificationId = -1;
    TaskProgressUpdater.startedAt = 0;
  }

  static isActive(): boolean {
    return TaskProgressUpdater.taskNotificationId >= 0;
  }

  /** 单帧进度更新（失败绝不抛出，只做节流日志）。 */
  private static push(): void {
    const id = TaskProgressUpdater.taskNotificationId;
    if (id < 0) {
      return;
    }
    const minutes: number = TaskProgressUpdater.startedAt > 0
      ? Math.max(0, Math.floor((Date.now() - TaskProgressUpdater.startedAt) / 60000)) : 0;
    const data: Record<string, Object> = {};
    data['title'] = 'Nexus VPN 运行中';
    data['fileName'] = `已连接 ${minutes} 分钟`;
    data['progressValue'] = minutes % 100;
    const request: notificationManager.NotificationRequest = {
      id: id,
      notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
        systemLiveView: {
          typeCode: TYPE_CODE_DATA_TRANSFER,
          title: 'Nexus VPN',
          text: '隧道已连接 · 持续保护中'
        }
      },
      template: {
        name: TEMPLATE_NAME,
        data: data
      }
    };
    notificationManager.publish(request).then((): void => {
      TaskProgressUpdater.lastFailLogAt = 0;
    }).catch((e: Error): void => {
      const now = Date.now();
      if (now - TaskProgressUpdater.lastFailLogAt > FAIL_LOG_THROTTLE_MS) {
        TaskProgressUpdater.lastFailLogAt = now;
        AppLogger.warn(TAG, `progress update failed: ${AppLogger.errText(e)}`);
      }
    });
  }
}
