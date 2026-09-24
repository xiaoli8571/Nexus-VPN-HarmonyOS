/**
 * 网络状态监听器（自包含服务，第二阶段）
 *
 * 职责:
 *   封装 @ohos.net.connection 的可用/丢失/能力变化订阅，向上暴露一个「当前网络类型」+
 *   单调递增事件代数(generation) 的稳定视图，供智能选点 / 链路自检 / TunnelAuthority 复用。
 *
 * 设计约束（真机要点）:
 *   1) 不持有任何 UI 对象（ArkUI 组件 / Context 一律不保存），只保存纯数据与回调；
 *      监听者通过 NetworkStateListener 注册，stop() 时全部释放，避免页面销毁后泄漏。
 *   2) 回调内绝不外抛异常：系统回调里的任何异常都会被吞掉并降级为日志，
 *      绝不让 NetManager 的 IPC 回调把主流程带崩。
 *   3) start() 幂等：重复调用直接返回，不会产生第二份订阅（对应 2101008 回调已存在）。
 *   4) stop() 彻底解绑：unregister + 所有回调置空 + 监听者清空。
 *   5) 订阅失败降级：register 抛错/回调带错时只置 subscribed=false 并记日志，
 *      不抛异常、不影响调用方主流程（VPN 仍然可以连接，只是少了网络变化信号）。
 *   6) 事件去抖（默认 1500ms）：WiFi↔蜂窝切换瞬间会产生一串 netLost/netAvailable/
 *      netCapabilitiesChange，逐条上报会触发多次重排/重连，故做窗口合并。
 *
 * 纯函数（可离线单测，不触碰 SDK）:
 *   normalizeNetType(bearerTypes, hasDefaultNet)
 *   shouldEmit(prev, next, elapsedMs, debounceMs)
 */
import { connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'NetworkStateWatcher';

/** 默认事件去抖窗口（毫秒） */
export const NET_DEBOUNCE_MS: number = 1500;

/** bearer 类型数值常量（与 connection.NetBearType 数值一致；纯判定不依赖 SDK 枚举） */
export const BEARER_CELLULAR: number = 0;
export const BEARER_WIFI: number = 1;
export const BEARER_BLUETOOTH: number = 2;
export const BEARER_ETHERNET: number = 3;
export const BEARER_VPN: number = 4;

/** 对外网络类型（归一化结果） */
export class NetTypes {
  /** 无默认网络（完全离线） */
  static readonly NONE: string = 'none';
  static readonly WIFI: string = 'wifi';
  static readonly CELLULAR: string = 'cellular';
  static readonly ETHERNET: string = 'ethernet';
  /** 有默认网络但 bearer 不可识别（蓝牙 / 纯 VPN 等） */
  static readonly UNKNOWN: string = 'unknown';
}

/** 网络类型变化监听者（实现方自行保证不长时间阻塞回调） */
export interface NetworkStateListener {
  onNetworkTypeChanged(netType: string, generation: number): void;
}

/**
 * 纯函数：把 bearer 列表归一化为对外网络类型。
 * 优先级: wifi > ethernet > cellular > unknown（VPN/蓝牙承载不单独对外暴露，
 * 因为 VPN 承载正是本应用自己建立的 TUN，暴露会造成自指混淆）。
 *
 * @param bearerTypes 当前默认网络的 bearer 类型数值列表
 * @param hasDefaultNet 是否存在默认网络（getDefaultNetSync 的 netId != 0）
 */
export function normalizeNetType(bearerTypes: number[], hasDefaultNet: boolean): string {
  if (!hasDefaultNet) {
    return NetTypes.NONE;
  }
  if (bearerTypes.length === 0) {
    return NetTypes.UNKNOWN;
  }
  if (bearerTypes.includes(BEARER_WIFI)) {
    return NetTypes.WIFI;
  }
  if (bearerTypes.includes(BEARER_ETHERNET)) {
    return NetTypes.ETHERNET;
  }
  if (bearerTypes.includes(BEARER_CELLULAR)) {
    return NetTypes.CELLULAR;
  }
  return NetTypes.UNKNOWN;
}

/**
 * 纯函数：是否应把 (prev → next) 的变化上报给监听者。
 *
 * 规则（确定性，无副作用）:
 *   - next === prev            → false（无变化，绝不重复上报）
 *   - prev 为空串（无历史状态） → true （首个已知状态立即上报，不等去抖窗口）
 *   - debounceMs <= 0          → true （去抖关闭）
 *   - elapsedMs < 0            → true （时钟回拨 / 时间源异常时不阻塞上报）
 *   - 其余                      → elapsedMs >= debounceMs
 *
 * @param prev 上一次已上报的网络类型；'' 表示尚无历史状态
 * @param next 本次观测到的网络类型
 * @param elapsedMs 距上次上报的毫秒数（调用方提供，便于单测）
 * @param debounceMs 去抖窗口毫秒
 */
export function shouldEmit(prev: string, next: string, elapsedMs: number, debounceMs: number): boolean {
  if (next === prev) {
    return false;
  }
  if (prev.length === 0) {
    return true;
  }
  if (debounceMs <= 0) {
    return true;
  }
  if (elapsedMs < 0) {
    return true;
  }
  return elapsedMs >= debounceMs;
}

/** 异常对象 → 可读文本（绝不抛） */
function errText(e: Object): string {
  if (e instanceof Error) {
    return e.message;
  }
  return String(e);
}

/**
 * 网络状态监听器。
 * 典型用法：
 *   watcher.addListener(this);
 *   watcher.start(context);   // 失败只返回 false，主流程继续
 *   ... 页面销毁 ...
 *   watcher.stop();
 */
export class NetworkStateWatcher {
  private debounceMs: number;
  private nowFn: () => number;

  private netConn: connection.NetConnection | null = null;
  private subscribed: boolean = false;

  /** 已上报的网络类型；'' 表示尚无历史状态（networkType() 对外映射为 unknown） */
  private currentType: string = '';
  /** 单调递增的事件代数：每次真实上报 +1 */
  private gen: number = 0;
  /** 上次上报时刻（ms） */
  private lastEmitAt: number = 0;

  private listeners: NetworkStateListener[] = [];

  /** 系统回调引用（unregister/置空用） */
  private cbAvailable: ((handle: connection.NetHandle) => void) | null = null;
  private cbLost: ((handle: connection.NetHandle) => void) | null = null;
  private cbCaps: ((info: connection.NetCapabilityInfo) => void) | null = null;
  private cbProps: ((info: connection.NetConnectionPropertyInfo) => void) | null = null;
  private cbUnavailable: (() => void) | null = null;

  /**
   * @param debounceMs 事件去抖窗口，默认 1500ms；负数回退默认值
   * @param nowFn 时间源（便于单测注入）；默认 Date.now
   */
  constructor(debounceMs: number = NET_DEBOUNCE_MS, nowFn?: () => number) {
    this.debounceMs = debounceMs >= 0 ? debounceMs : NET_DEBOUNCE_MS;
    this.nowFn = nowFn === undefined ? (): number => Date.now() : nowFn;
  }

  /** 当前网络类型；从未观测到任何状态时为 'unknown' */
  networkType(): string {
    return this.currentType.length > 0 ? this.currentType : NetTypes.UNKNOWN;
  }

  /** 单调递增的事件代数（每次真实上报 +1，只增不减） */
  generation(): number {
    return this.gen;
  }

  /** 是否已成功订阅系统网络变化 */
  isSubscribed(): boolean {
    return this.subscribed;
  }

  /** 当前去抖窗口（ms） */
  debounceWindowMs(): number {
    return this.debounceMs;
  }

  addListener(listener: NetworkStateListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  removeListener(listener: NetworkStateListener): void {
    const idx = this.listeners.indexOf(listener);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  /**
   * 启动订阅（幂等）。
   * @param context 仅用于 API 兼容与日志；**不被保存**，因此不会持有 UI 对象。
   * @returns 是否订阅成功；失败时静默降级返回 false（调用方无需处理）
   */
  start(context: Object): boolean {
    if (this.subscribed) {
      return true;
    }
    // 1) 先用同步接口取一次初值；失败不影响后续订阅
    this.refreshSync();

    // 2) 建立订阅
    let conn: connection.NetConnection;
    try {
      conn = connection.createNetConnection();
    } catch (e) {
      AppLogger.warn(TAG, 'createNetConnection failed, watcher degraded: ' + errText(e));
      return false;
    }

    try {
      this.cbAvailable = (handle: connection.NetHandle): void => {
        this.onSystemSignal(null);
      };
      this.cbLost = (handle: connection.NetHandle): void => {
        this.onSystemSignal(null);
      };
      this.cbCaps = (info: connection.NetCapabilityInfo): void => {
        this.onSystemSignal(null);
      };
      this.cbProps = (info: connection.NetConnectionPropertyInfo): void => {
        this.onSystemSignal(null);
      };
      this.cbUnavailable = (): void => {
        this.onSystemSignal(NetTypes.NONE);
      };

      conn.on('netAvailable', this.cbAvailable);
      conn.on('netLost', this.cbLost);
      conn.on('netCapabilitiesChange', this.cbCaps);
      conn.on('netConnectionPropertiesChange', this.cbProps);
      conn.on('netUnavailable', this.cbUnavailable);

      conn.register((err: BusinessError): void => {
        // 回调内绝不外抛：订阅失败仅降级
        try {
          if (err !== null && err !== undefined && err.code !== 0) {
            this.subscribed = false;
            AppLogger.warn(TAG, 'network register failed code=' + err.code + ', watcher degraded');
          }
        } catch (e) {
          // 忽略：降级路径本身不得再抛
        }
      });

      this.netConn = conn;
      this.subscribed = true;
      AppLogger.info(TAG, 'network state subscription started (debounce=' + this.debounceMs + 'ms)');
      return true;
    } catch (e) {
      // register 可同步抛 201/2101008 等 → 彻底回滚，不残留半订阅
      AppLogger.warn(TAG, 'network subscription unavailable, watcher degraded: ' + errText(e));
      this.netConn = null;
      this.subscribed = false;
      this.clearCallbacks();
      return false;
    }
  }

  /**
   * 停止订阅并彻底解绑：unregister + 回调置空 + 监听者清空。
   * 幂等；任何异常都被吞掉。
   */
  stop(): void {
    const conn = this.netConn;
    this.netConn = null;
    this.subscribed = false;
    if (conn !== null) {
      try {
        conn.unregister((err: BusinessError): void => {
          try {
            if (err !== null && err !== undefined && err.code !== 0) {
              AppLogger.warn(TAG, 'network unregister failed code=' + err.code);
            }
          } catch (e) {
            // 忽略
          }
        });
      } catch (e) {
        AppLogger.warn(TAG, 'network unregister threw: ' + errText(e));
      }
    }
    this.clearCallbacks();
    // 清空监听者，避免 UI 对象被本服务长期持有
    this.listeners = [];
    AppLogger.info(TAG, 'network state subscription stopped');
  }

  /**
   * 同步刷新一次当前网络类型（幂等；异常降级为 unknown）。
   * 供 start() 首次取值与测试/调试手动触发使用。
   */
  refreshSync(): void {
    const next = this.readCurrentType();
    this.emitIfChanged(next);
  }

  /** 供单测直接注入一次观测（不触碰 SDK） */
  feedForTest(next: string): void {
    this.emitIfChanged(next);
  }

  // ── 内部 ────────────────────────────────────────────────────────────

  private clearCallbacks(): void {
    this.cbAvailable = null;
    this.cbLost = null;
    this.cbCaps = null;
    this.cbProps = null;
    this.cbUnavailable = null;
  }

  /** 系统事件入口：任何异常都在此终结，绝不外抛 */
  private onSystemSignal(hint: string | null): void {
    try {
      const next = hint === null ? this.readCurrentType() : hint;
      this.emitIfChanged(next);
    } catch (e) {
      AppLogger.warn(TAG, 'network signal handling failed (ignored): ' + errText(e));
    }
  }

  /** 同步读取默认网络类型；任何失败都返回 unknown（绝不抛） */
  private readCurrentType(): string {
    try {
      const handle = connection.getDefaultNetSync();
      if (handle === null || handle === undefined || handle.netId === 0) {
        return NetTypes.NONE;
      }
      const caps = connection.getNetCapabilitiesSync(handle);
      const bearers: number[] = [];
      if (caps !== null && caps !== undefined) {
        const raw: connection.NetBearType[] = caps.bearerTypes;
        if (Array.isArray(raw)) {
          for (let i = 0; i < raw.length; i++) {
            const v: number = raw[i] as number;
            bearers.push(v);
          }
        }
      }
      return normalizeNetType(bearers, true);
    } catch (e) {
      return NetTypes.UNKNOWN;
    }
  }

  /** 去抖 + 代际递增 + 安全广播 */
  private emitIfChanged(next: string): void {
    const now = this.nowFn();
    const prev = this.currentType;
    if (!shouldEmit(prev, next, now - this.lastEmitAt, this.debounceMs)) {
      return;
    }
    this.currentType = next;
    this.lastEmitAt = now;
    this.gen = this.gen + 1;
    const gen = this.gen;
    // 快照遍历：监听者在回调里增删自己不会影响本轮
    const snapshot = this.listeners.slice();
    for (const l of snapshot) {
      try {
        l.onNetworkTypeChanged(next, gen);
      } catch (e) {
        // 监听者异常必须被隔离，绝不影响其他监听者与主流程
        AppLogger.warn(TAG, 'listener threw, isolated: ' + errText(e));
      }
    }
  }
}
