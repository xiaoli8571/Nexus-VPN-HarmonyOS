/**
 * 常驻通知（对应 upstream VpnNotificationSupport / NotificationUpdatePolicy）
 * 连接期间显示节点名与实时速率；每秒由编排器刷新。
 *
 * 通知被系统禁用时（错误码 1600004 / "disabled"）不再每秒重试造成日志与
 * 调度风暴：进入退避窗口（默认 60s）内直接跳过，窗口结束后再探测一次；
 * 通知重新可用（或主动 cancel/重连）即恢复。可观察状态经 isSuppressed() 暴露。
 */
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'SsrvpnNotifier';
const NOTIFICATION_ID = 1001;
/** 通知被禁用后的退避时长：避免每秒 publish 失败风暴 */
const DISABLED_BACKOFF_MS = 60000;

export class SsrvpnNotifier {
  private static lastText: string = '';
  private static lastUpdateAt: number = 0;
  /** 退避截止时间戳（>now 表示通知当前不可用，跳过 publish） */
  private static disabledUntil: number = 0;
  /** 最近一次失败错误码（0 表示无失败），供 UI/诊断读取 */
  private static lastErrorCode: number = 0;

  /** 通知当前是否因被禁用而处于退避抑制状态 */
  static isSuppressed(): boolean {
    return Date.now() < SsrvpnNotifier.disabledUntil;
  }

  /** 最近一次通知失败错误码（0=无失败）；1600004 表示通知被用户/系统禁用 */
  static lastCode(): number {
    return SsrvpnNotifier.lastErrorCode;
  }

  static async update(title: string, nodeLine: string, speedLine: string): Promise<void> {
    const now = Date.now();
    // 退避窗口内直接返回：通知禁用属于用户设置，重试没有意义
    if (now < SsrvpnNotifier.disabledUntil) {
      return;
    }
    // 节流：内容未变化或距上次刷新不足 900ms 则跳过
    const text = `${nodeLine}\n${speedLine}`;
    if (text === SsrvpnNotifier.lastText && now - SsrvpnNotifier.lastUpdateAt < 900) {
      return;
    }
    SsrvpnNotifier.lastText = text;
    SsrvpnNotifier.lastUpdateAt = now;
    try {
      const contentBody: notificationManager.NotificationBasicContent = {
        title: title,
        text: speedLine,
        additionalText: nodeLine
      };
      const request: notificationManager.NotificationRequest = {
        id: NOTIFICATION_ID,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: contentBody
        },
        isOngoing: true,
        isUnremovable: true
      };
      await notificationManager.publish(request);
      SsrvpnNotifier.lastErrorCode = 0;
      SsrvpnNotifier.disabledUntil = 0;
    } catch (e) {
      const err = e as BusinessError;
      const code = (err !== undefined && err !== null) ? err.code : 0;
      const message = (err !== undefined && err !== null) ? err.message : String(e);
      SsrvpnNotifier.lastErrorCode = code;
      // 1600004 = 通知已被禁用；同类文案也一并识别，进入退避窗口
      const disabled = code === 1600004 || message.indexOf('disabled') >= 0
        || message.indexOf('not enabled') >= 0;
      if (disabled) {
        SsrvpnNotifier.disabledUntil = now + DISABLED_BACKOFF_MS;
        AppLogger.warn(TAG, `notify disabled (code=${code}); backing off ${DISABLED_BACKOFF_MS}ms`);
      } else {
        AppLogger.warn(TAG, `notify failed: code=${code} ${message}`);
      }
    }
  }

  static async cancel(): Promise<void> {
    try {
      await notificationManager.cancel(NOTIFICATION_ID);
    } catch (e) {
      // 忽略：通知可能本就不存在
    }
    SsrvpnNotifier.lastText = '';
    SsrvpnNotifier.lastUpdateAt = 0;
    SsrvpnNotifier.disabledUntil = 0;
  }
}
