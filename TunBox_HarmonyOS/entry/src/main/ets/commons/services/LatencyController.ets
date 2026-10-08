/**
 * 延迟结果存储（重做版）
 *
 * 旧版是 `Map<string, number>`：只能放一个数字，于是超时写成 -1、未测写成 -2，
 * 既丢失了「失败 vs 超时 vs 未测」的区别，也没有时间戳。UI 只能把 -1/-2 一律
 * 渲染成「超时」，用户看到的就是"明明没测过却显示超时""数字永远不变旧"。
 *
 * 现在存 `LatencyRecord`（状态 + 延迟 + 时间戳 + 通道）。为兼容既有调用点
 * （HomePage / NodeCard / LogicTest），保留数字入口 `set()` 与 `latencyFor()`：
 *  - `set(name, -1)` → TIMEOUT（旧语义）
 *  - `set(name, -2)` → UNTESTED（旧语义）
 *  - `set(name, >=1)` → MEASURED
 * 新代码一律用 `setRecord()` / `recordFor()`。
 *
 * 性能约束不变：批量测速每个节点都会写一次，若每次都同步通知监听者，节点页会随
 * 每条结果重建整张列表（106 个节点即 106 次重排）。这里把通知合并到最多每 200ms
 * 一次，仅压缩刷新频率，数值本身不丢。
 */
import { LatencyChannel, LatencyRecord, LatencyState } from './LatencyState';

const NOTIFY_COALESCE_MS = 200;

export class LatencyController {
  private static map: Map<string, LatencyRecord> = new Map<string, LatencyRecord>();
  private static listeners: (() => void)[] = [];
  /** 待触发的合并通知定时器；-1 表示当前没有挂起的通知 */
  private static notifyTimer: number = -1;

  /** 完整记录（新代码入口） */
  static recordFor(nodeName: string): LatencyRecord | null {
    const v = LatencyController.map.get(nodeName);
    return v === undefined ? null : v;
  }

  /** 状态（缺省 = UNTESTED，绝不缺省成"超时"） */
  static stateFor(nodeName: string): number {
    const v = LatencyController.map.get(nodeName);
    return v === undefined ? LatencyState.UNTESTED : v.state;
  }

  /**
   * 兼容视图：数值延迟。
   * MEASURED/OFFLINE → 延迟；TIMEOUT/FAILED → -1；其余（未测/测试中/取消）→ null。
   */
  static latencyFor(nodeName: string): number | null {
    const v = LatencyController.map.get(nodeName);
    if (v === undefined) {
      return null;
    }
    if (v.state === LatencyState.MEASURED || v.state === LatencyState.OFFLINE) {
      return v.delayMs;
    }
    if (v.state === LatencyState.TIMEOUT || v.state === LatencyState.FAILED) {
      return -1;
    }
    return null;
  }

  /** 写入完整记录 */
  static setRecord(rec: LatencyRecord): void {
    LatencyController.map.set(rec.name, rec);
    LatencyController.scheduleNotify();
  }

  /** 标记为「测试中」（UI 显示 spinner；不覆盖已有数值，直到新结果落地） */
  static markTesting(nodeName: string): void {
    const existing = LatencyController.map.get(nodeName);
    const rec = new LatencyRecord();
    rec.name = nodeName;
    rec.state = LatencyState.TESTING;
    rec.delayMs = -1;
    rec.atMs = 0;
    rec.channel = existing === undefined ? LatencyChannel.CORE : existing.channel;
    LatencyController.map.set(nodeName, rec);
    LatencyController.scheduleNotify();
  }

  /** 兼容入口：数字 → 记录 */
  static set(nodeName: string, latency: number): void {
    if (latency >= 1) {
      LatencyController.setRecord(
        LatencyRecord.measured(nodeName, latency, LatencyChannel.CORE, Date.now()));
      return;
    }
    if (latency === 0 || latency === -1) {
      LatencyController.setRecord(
        LatencyRecord.failed(nodeName, LatencyState.TIMEOUT, Date.now()));
      return;
    }
    // -2（旧"未测"）及其它：回到未测，不盖章成失败
    LatencyController.setRecord(LatencyRecord.untested(nodeName));
  }

  static clearAll(): void {
    LatencyController.map.clear();
    LatencyController.scheduleNotify();
  }

  /** 全部记录快照（排序/持久化用） */
  static snapshot(): LatencyRecord[] {
    const out: LatencyRecord[] = [];
    for (const rec of LatencyController.map.values()) {
      out.push(rec);
    }
    return out;
  }

  /**
   * 丢弃当前订阅已不存在节点的延迟，避免订阅反复刷新或换源后 Map 常驻增长。
   * 只有确实删除条目时才通知，因而可安全地在列表重建路径调用。
   */
  static retainOnly(nodeNames: string[]): void {
    const active = new Set<string>(nodeNames);
    let changed = false;
    for (const name of LatencyController.map.keys()) {
      if (!active.has(name)) {
        LatencyController.map.delete(name);
        changed = true;
      }
    }
    if (changed) {
      LatencyController.scheduleNotify();
    }
  }

  static addListener(listener: () => void): void {
    if (LatencyController.listeners.indexOf(listener) < 0) {
      LatencyController.listeners.push(listener);
    }
  }

  static removeListener(listener: () => void): void {
    const index = LatencyController.listeners.indexOf(listener);
    if (index >= 0) {
      LatencyController.listeners.splice(index, 1);
    }
  }

  /** 合并窗口内的通知调度：已有挂起定时器则不再排新的（O(1) 合并） */
  private static scheduleNotify(): void {
    if (LatencyController.notifyTimer >= 0) {
      return;
    }
    LatencyController.notifyTimer = setTimeout((): void => {
      LatencyController.notifyTimer = -1;
      LatencyController.notify();
    }, NOTIFY_COALESCE_MS);
  }

  /** 立即刷新（批次结束/进入页面恢复快照后调用，避免最后一批结果延迟 200ms 才显示） */
  static flushNow(): void {
    if (LatencyController.notifyTimer >= 0) {
      clearTimeout(LatencyController.notifyTimer);
      LatencyController.notifyTimer = -1;
    }
    LatencyController.notify();
  }

  /** 是否有挂起的合并通知（专项验证用） */
  static hasPendingNotify(): boolean {
    return LatencyController.notifyTimer >= 0;
  }

  static notify(): void {
    for (const l of LatencyController.listeners) {
      l();
    }
  }
}
