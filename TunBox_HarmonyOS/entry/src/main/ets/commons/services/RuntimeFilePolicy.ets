/**
 * 运行时私有文件策略：证书/配置文件的最小权限落盘与可靠清理。
 *
 * 设计要点（对应审计项「运行时凭据清理」）：
 * 1) 最小权限：写入前确保目录存在且以 0700 创建；文件以 READ_WRITE|CREATE|TRUNC
 *    创建后用 chmod 收窄到 0600（仅属主可读写），避免同设备其他进程读取
 *    含 API secret / 节点口令的 YAML。
 * 2) 可靠清理：每个文件独立 try/catch，一个文件不存在或删除失败不得阻止
 *    其余文件删除（逐文件独立容错）。
 * 3) 集中管理文件名，避免散落的字符串常量导致漏删。
 *
 * 纯策略 + 注入文件系统，便于在 ohosTest 中做专项验证（不依赖真实沙箱）。
 */

/** 含凭据的运行时文件（相对 cacheDir） */
export const PRIVATE_CONFIG_FILE = 'mihomo_config.yaml';
export const PRIVATE_TEST_CONFIG_FILE = 'mihomo_test_config.yaml';
/** 扩展进程回写的跨进程状态文件 */
export const TUNNEL_STATE_FILES: string[] = [
  'vpn_heartbeat.txt',
  'vpn_start_ok.txt',
  'vpn_start_error.txt',
  // UI 每次拉起前重写、扩展仅在 want 丢参时读一次的路由参数快照；
  // 随隧道生命周期清理（名字须与 ConnectionOrchestrator/VpnExtensionAbility 两侧常量一致）
  'vpn_start_params.json',
  // 扩展 onCreate 送达标记（UI 判定 start 是否被系统吞并）；断开时复位
  'vpn_launch_epoch.txt'
];

/** 同步读取状态文件时的最大字节数（防止被写入超长内容后一次性分配巨额内存） */
export const MAX_STATE_FILE_BYTES = 64 * 1024;
/** 最小权限目录 / 文件权限位 */
export const PRIVATE_DIR_MODE = 0o700;
export const PRIVATE_FILE_MODE = 0o600;

/**
 * 同步文件读取结果：ok=false 表示读取失败（文件不存在/IO 错误），
 * text 为空串而非抛异常 —— 调用方按「无数据」处理。
 */
export interface SyncReadResult {
  ok: boolean;
  text: string;
  /** 原始内容是否因超过上限而被截断 */
  truncated: boolean;
}

/**
 * 最小权限文件系统接口。仅为可测试性抽象，生产实现直接包 fileIo。
 */
export interface PrivateFs {
  /** 写入（创建/覆盖）并收窄权限；实现必须保证 fd 在 finally 中关闭 */
  writePrivate(path: string, content: string): void;
  /** 读取上限内的文本；失败返回 { ok: false }，绝不抛异常 */
  readCapped(path: string, maxBytes: number): SyncReadResult;
  /** 删除单个文件；不存在/失败均返回 false，绝不抛异常 */
  remove(path: string): boolean;
  /** 仅探测存在性 */
  exists(path: string): boolean;
}

/**
 * 逐文件独立容错删除：返回成功删除的文件名列表。
 * 关键约束：任一文件不存在（抛错）不得中断循环，后续文件仍必须尝试删除。
 */
export function removeFilesIndependently(dir: string, fileNames: string[],
  fsImpl: PrivateFs): string[] {
  const removed: string[] = [];
  for (const name of fileNames) {
    if (fsImpl.remove(`${dir}/${name}`)) {
      removed.push(name);
    }
  }
  return removed;
}

/**
 * 凭据文件清理：主配置 + 测速配置 + 隧道状态文件。
 * 每个文件独立容错，缺失即跳过，绝不因单点失败影响其他文件。
 */
export function clearPrivateArtifacts(dir: string, fsImpl: PrivateFs): string[] {
  const targets: string[] = [PRIVATE_CONFIG_FILE, PRIVATE_TEST_CONFIG_FILE];
  for (const f of TUNNEL_STATE_FILES) {
    targets.push(f);
  }
  return removeFilesIndependently(dir, targets, fsImpl);
}

/** 状态文本解析为心跳时间戳；非法内容返回 -1 */
export function parseHeartbeatTimestamp(text: string): number {
  const ts = Number(text.trim());
  if (!Number.isFinite(ts) || ts <= 0) {
    return -1;
  }
  return ts;
}

/** 由心跳文本计算年龄（ms）；-1 = 无心跳/非法 */
export function heartbeatAgeFromText(text: string, now: number): number {
  const ts = parseHeartbeatTimestamp(text);
  if (ts < 0) {
    return -1;
  }
  return now - ts;
}
