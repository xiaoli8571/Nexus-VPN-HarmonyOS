/**
 * VPN 恢复策略（纯函数，无 SDK 依赖，可离线自动验证）。
 *
 * 把 VpnExtensionAbility 的 MTU 选择、内核恢复退避、TUN 重建升级、Kill Switch
 * 泄漏阻断判定从进程里抽出来，供 Extension 运行时调用，也供
 * scripts/verify-vpn-architecture.mjs 做后台/锁屏/进程回收/网络切换/内核崩溃/
 * 弱网/长稳等场景的确定性仿真验证。语义必须与 Extension 内联实现保持一致。
 */

/** 网络类型常量（与 NetworkStateWatcher.NetTypes 数值语义一致，纯字符串）。 */
export class NetTypes {
  static readonly NONE: string = 'none';
  static readonly WIFI: string = 'wifi';
  static readonly CELLULAR: string = 'cellular';
  static readonly ETHERNET: string = 'ethernet';
  static readonly UNKNOWN: string = 'unknown';
}

/** Wi-Fi/以太网基线 MTU；蜂窝链路降 MTU 降低分片/PMTUD 黑洞风险。 */
export const BASE_MTU: number = 1400;
export const CELLULAR_MTU: number = 1360;
/** 内核热恢复最大次数，超过升级为一次 TUN 重建。 */
export const MAX_CORE_RECOVERY_ATTEMPTS: number = 3;
/** 单会话 TUN 重建上限（防重建风暴）。 */
export const MAX_TUNNEL_REBUILDS: number = 2;
/** 恢复退避基准与上限（ms）。 */
export const RECOVERY_BASE_DELAY_MS: number = 1000;
export const RECOVERY_MAX_DELAY_MS: number = 8000;
export const REBUILD_BASE_DELAY_MS: number = 1500;
export const REBUILD_MAX_DELAY_MS: number = 8000;

/** 按物理承载选择 MTU。蜂窝 → 1360，其余（含未知/以太网/无网）→ 1400 基线。 */
export function mtuForNetType(netType: string): number {
  return netType === NetTypes.CELLULAR ? CELLULAR_MTU : BASE_MTU;
}

/** 纯函数：第 attempt 次（从 0 起）内核恢复的退避延迟，指数增长并封顶。 */
export function coreRecoveryDelayMs(attempt: number): number {
  const a = attempt < 0 ? 0 : attempt;
  const raw = RECOVERY_BASE_DELAY_MS * Math.pow(2, a);
  return raw > RECOVERY_MAX_DELAY_MS ? RECOVERY_MAX_DELAY_MS : raw;
}

/** 纯函数：第 rebuild 次（从 0 起）TUN 重建的退避延迟，指数增长并封顶。 */
export function tunnelRebuildDelayMs(rebuild: number): number {
  const r = rebuild < 0 ? 0 : rebuild;
  const raw = REBUILD_BASE_DELAY_MS * Math.pow(2, r);
  return raw > REBUILD_MAX_DELAY_MS ? REBUILD_MAX_DELAY_MS : raw;
}

/** 网络类型是否为可承载恢复尝试的物理网络。 */
export function isRecoverableNetwork(netType: string): boolean {
  return netType === NetTypes.WIFI || netType === NetTypes.CELLULAR
    || netType === NetTypes.ETHERNET;
}

/**
 * Kill Switch / 断线防泄漏核心判定：返回本世代是否应「保持 TUN + 阻断泄漏」。
 *
 * 语义：只要不是用户主动断开（stopped），隧道默认路由与 IPv4-only 就必须保留 ——
 * 内核不可用时流量落入 TUN 而无出口 = 天然阻断，绝不回退物理网络造成泄漏。
 * 断网（NONE）时不进入恢复（无法拨出），但保持阻断。返回 'leak-blocked' 表示
 * 阻断中且不再消耗恢复预算；'recover' 表示应尝试恢复；'down' 表示可拆除。
 */
export function leakSwitchDecision(userStopped: boolean, netType: string, coreAlive: boolean): string {
  if (userStopped) {
    return 'down';
  }
  if (!coreAlive && netType === NetTypes.NONE) {
    return 'leak-blocked';
  }
  if (!coreAlive && isRecoverableNetwork(netType)) {
    return 'recover';
  }
  return 'keep';
}

/** 恢复调度决策输入/输出（显式类型，满足 ArkTS 严格模式）。 */
export class RecoveryInput {
  userStopped: boolean = false;
  netType: string = NetTypes.UNKNOWN;
  coreAlive: boolean = true;
  connectionUp: boolean = true;
  rebuilding: boolean = false;
  recoveryAttempts: number = 0;
  tunnelRebuilds: number = 0;
}

/** 恢复动作取值集合（用常量而非字面量联合类型，规避 ArkTS 严格模式限制）。 */
export class RecoveryAction {
  static readonly NONE: string = 'none';
  static readonly CORE_RECOVERY: string = 'core-recovery';
  static readonly TUN_REBUILD: string = 'tun-rebuild';
  static readonly LEAK_BLOCKED: string = 'leak-blocked';
}

/**
 * 纯函数：给定恢复上下文，决定本 tick 应执行的动作。把 Extension 的
 * scheduleCoreRecovery / scheduleTunnelRebuild / leak-block 门控收敛成一处，
 * 便于自动化覆盖「内核崩溃→有限热恢复→升级一次 TUN 重建→再耗尽→泄漏阻断」。
 * 返回值为 RecoveryAction.* 之一。
 */
export function decideRecoveryAction(inp: RecoveryInput): string {
  if (inp.userStopped || inp.rebuilding) {
    return RecoveryAction.NONE;
  }
  const switchDecision = leakSwitchDecision(inp.userStopped, inp.netType, inp.coreAlive);
  if (!inp.connectionUp) {
    return RecoveryAction.NONE;
  }
  if (inp.netType === NetTypes.NONE) {
    return switchDecision === 'leak-blocked' ? RecoveryAction.LEAK_BLOCKED : RecoveryAction.NONE;
  }
  if (inp.coreAlive) {
    return RecoveryAction.NONE;
  }
  // 内核已死且网络可用：先做有限次内核热恢复（不重建 TUN），耗尽后升级一次 TUN 重建。
  if (inp.recoveryAttempts < MAX_CORE_RECOVERY_ATTEMPTS) {
    return RecoveryAction.CORE_RECOVERY;
  }
  if (inp.tunnelRebuilds < MAX_TUNNEL_REBUILDS) {
    return RecoveryAction.TUN_REBUILD;
  }
  return RecoveryAction.LEAK_BLOCKED;
}

/**
 * 纯函数：长时间运行/弱网下是否应重置恢复计数。
 * 当内核重新存活（恢复成功）且网络可用时归零，避免跨事件累计导致过早放弃。
 */
export function shouldResetRecovery(coreAlive: boolean, netType: string): boolean {
  return coreAlive && isRecoverableNetwork(netType);
}
