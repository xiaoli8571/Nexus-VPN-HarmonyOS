/**
 * 节点/订阅敏感凭据安全存储（HarmonyOS AssetStore 封装）
 * 先例：SettingsService.setApiSecret/getApiSecret（@kit.AssetStoreKit）
 *
 * 设计要点
 * 1) 元数据留在 preferences，凭据单独进 AssetStore，键空间与明文完全分离。
 * 2) alias 稳定：节点 "ssrvpn_node|<nodeId>|<field>"，订阅 "ssrvpn_sub|<subId>|headerValue"。
 *    nodeId = SubscriptionService.nodeKey（subscriptionId|server|port|原名），跨刷新稳定。
 * 3) 读取回退：Asset 中不存在时由调用方传入 fallback（历史明文 / 一次性 rawUri），
 *    且不因读取失败而抛错（返回 fallback）。
 * 4) 一次性迁移：canonicalize() 回读校验成功后才通知调用方清除明文；失败保留明文并记录。
 * 5) 幂等：迁移标记 "migration_v1_done" 只影响是否重复清除明文，
 *    而加密写入本身是 SET 语义（remove 成功/失败均 add），重复启动或重复迁移不产生脏数据。
 */
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { ProxyNode } from '../models/ProxyNode';

export const CRED_PREF_NAME = 'ssrvpn_credentials';

/** 节点凭据字段（全部只允许存 AssetStore） */
export const NODE_CRED_FIELDS: string[] = ['password', 'uuid', 'protocolParam', 'obfsParam'];
/** 订阅凭据字段（自定义请求头，等价于订阅鉴权 token） */
export const SUB_CRED_FIELD = 'headerValue';

export const MIGRATION_FLAG_KEY = 'migration_v1_done';

const ASSET_SERVICE = 'ssrvpn_service';
const NODE_ALIAS_PREFIX = 'ssrvpn_node';
const SUB_ALIAS_PREFIX = 'ssrvpn_sub';
/** 探测 alias 的一个不可能与真实凭据重名的哨兵键（用于判断 AssetStore 是否可用） */
const PROBE_ALIAS = 'ssrvpn_probe';

/** 迁移/落盘统计（不含任何凭据值，可安全记录日志） */
export class CredentialMigrationReport {
  migratedNodes: number = 0;
  migratedFields: number = 0;
  migratedSubscriptions: number = 0;
  /** 本次新增（Asset 中原本不存在）的项 */
  addedNew: number = 0;
  /** 回读校验失败项：其明文必须保留 */
  failed: number = 0;
  /** 已存在且回读一致，可安全清除明文 */
  alreadyStored: number = 0;
  /**
   * 加密层整体不可用（probe 失败）。此时 failed 仍为 0（没有任何一次写入被尝试），
   * 调用方绝不能把「0 失败」当成「凭据已安全入库」——否则首启会清掉全部明文凭据，
   * 导致重启后 password/uuid 永久缺失、节点在生成配置阶段被整批丢弃（漏洞 A）。
   */
  storeUnavailable: boolean = false;
  /** 失败明细（nodeId|field），用于决定哪些节点仍需保留明文回退源 */
  private failedKeys: Set<string> = new Set<string>();
  /** 已回读校验成功的明细（nodeId|field）：只有这些字段允许清除明文 */
  private storedKeys: Set<string> = new Set<string>();

  markFailed(ownerId: string, field: string): void {
    this.failedKeys.add(`${ownerId}|${field}`);
  }

  markStored(ownerId: string, field: string): void {
    this.storedKeys.add(`${ownerId}|${field}`);
  }

  /** 该字段是否已确认存在于加密层（写入 + 回读校验通过/原值一致） */
  fieldStored(ownerId: string, field: string): boolean {
    return this.storedKeys.has(`${ownerId}|${field}`);
  }

  /** 该节点的该字段是否迁移失败（失败 → 不得清除明文） */
  fieldFailed(nodeId: string, field: string): boolean {
    return this.failedKeys.has(`${nodeId}|${field}`);
  }

  /** 节点是否有任意字段失败 */
  nodeHasFailure(nodeId: string): boolean {
    for (const k of this.failedKeys) {
      if (k.startsWith(`${nodeId}|`)) {
        return true;
      }
    }
    return false;
  }
}

/** 节点凭据三态（Asset 优先，缺失回退一次性 rawUri） */
export class NodeCredentialValues {
  password: string = '';
  uuid: string = '';
  protocolParam: string = '';
  obfsParam: string = '';
}

/** 单条凭据读取结果：found=false 表示 Asset 中没有（调用方应回退） */
class CredentialRead {
  found: boolean = false;
  value: string = '';
}

export class CredentialStore {
  private static available: boolean = false;
  /** 用于幂等与"首次启动"判定：在写入任何 Asset 项之前读取 */
  private static flagPresentOnEntry: boolean = false;
  private static probed: boolean = false;

  /** AI-7：为指定的 alias 集合生成透明读回缓存，测试可在构造前替换（wiring point） */
  static makeCache(): Map<string, string> {
    return new Map<string, string>();
  }

  /** 构造仅含 ALIAS 的 remove 参数：remove 携带 SECRET 等多余 tag 在部分版本会参数校验失败且异常被吞，导致旧值残留 */
  private static removeAttrOf(alias: string): asset.AssetMap {
    const removeAttr: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    removeAttr.set(asset.Tag.ALIAS, stringToUint8(alias));
    return removeAttr;
  }

  /** 探测 AssetStore 可用性（只写一个哨兵 alias，不影响真实凭据） */
  static async probe(): Promise<boolean> {
    if (CredentialStore.probed) {
      return CredentialStore.available;
    }
    CredentialStore.probed = true;
    const attr: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    attr.set(asset.Tag.ALIAS, stringToUint8(PROBE_ALIAS));
    attr.set(asset.Tag.SECRET, stringToUint8('1'));
    attr.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    const removeAttr = CredentialStore.removeAttrOf(PROBE_ALIAS);
    try {
      // 哨兵自愈：上次运行中途被杀或清理失败会留下哨兵，本次 add 会抛 "The asset already exists."。
      // 该错误曾把「实际可用」的 AssetStore 误判为不可用 → 导入时全部节点凭据保存失败（保存失败 N）。
      const existing = await CredentialStore.readAsset(PROBE_ALIAS);
      if (existing.found && existing.value === '1') {
        // 残留哨兵能完整读回，本身即证明 AssetStore 可用
        CredentialStore.available = true;
        try {
          await asset.remove(removeAttr);
        } catch (e) {
          // 清理失败不影响可用性结论；下次 probe 会再次自愈
        }
      } else {
        try {
          await asset.remove(removeAttr);
        } catch (e) {
          // 哨兵不存在属正常
        }
        try {
          await asset.add(attr);
        } catch (addErr) {
          // already-exists 兜底：清掉残留后重试一次
          await asset.remove(removeAttr);
          await asset.add(attr);
        }
        const read = await CredentialStore.readAsset(PROBE_ALIAS);
        CredentialStore.available = read.found && read.value === '1';
        try {
          await asset.remove(removeAttr);
        } catch (e) {
          // 探测项清除失败无影响（值恒为 '1'，非凭据；下次 probe 先自愈）
        }
      }
    } catch (e) {
      CredentialStore.available = false;
      AppLoggerSafe(`credential store probe failed: ${errText(e)}`);
    }
    if (!CredentialStore.available) {
      AppLoggerSafe('asset store unavailable: credentials will NOT be persisted in plaintext');
    }
    return CredentialStore.available;
  }

  /**
   * 迁移标记读取。必须在任何 Asset 写入之前调用，用于判定"首次启动"，
   * 否则下一次运行时写入会与本次写入不可区分（幂等检测失效）。
   */
  static async loadMigrationFlag(): Promise<void> {
    const read = await CredentialStore.readAsset(MIGRATION_FLAG_KEY);
    CredentialStore.flagPresentOnEntry = read.found;
  }

  static isFirstRun(): boolean {
    return !CredentialStore.flagPresentOnEntry;
  }

  /**
   * 一次性迁移核心：把节点/订阅凭据（加密写入 + 回读校验）规范化到 AssetStore。
   * 返回报告；调用方仅在 failed === 0 时清除明文 preferences。
   * 参数 quickExit：当 Asset 中该 alias 已存在且值一致时跳过（幂等快速路径）。
   *
   * 性能关键：整个流程只做「1 次全量读 + 仅缺失项写入 + 1 次批量回读」，
   * 绝不逐字段读回（70 节点 × 4 字段的逐条 IPC 曾把每次 init 拖到数秒）。
   */
  static async canonicalize(nodes: ProxyNode[], subscriptions: SubscriptionCredentialSource[],
    quickExit: boolean): Promise<CredentialMigrationReport> {
    const report = new CredentialMigrationReport();
    if (!CredentialStore.probed) {
      await CredentialStore.probe();
    }
    if (!CredentialStore.available) {
      // Asset 完全不可用：绝不写明文，也不清明文，交由调用方记录。
      // 显式标记 storeUnavailable：调用方不得把 failed===0 当成「已安全入库」。
      report.storeUnavailable = true;
      AppLoggerSafe('asset store unavailable: credential migration skipped (plaintext preserved)');
      return report;
    }

    const pending: PendingCredentialWrite[] = [];
    const cache = await CredentialStore.loadAllCredentials();

    const planField = (ownerId: string, field: string, value: string, alias: string): boolean => {
      // 空值不入库也不计数（空凭据无意义，且部分固件对空 SECRET 拒绝）
      if (value.length === 0) {
        return true;
      }
      const existing = cache.get(alias);
      if (existing !== undefined && existing === value) {
        report.migratedFields += 1;
        report.alreadyStored += 1;
        report.markStored(ownerId, field);
        return true;
      }
      if (existing !== undefined && quickExit) {
        // 非首启且已有加密值：不改写（内存中的明文可能是待清除的历史副本）
        report.migratedFields += 1;
        report.alreadyStored += 1;
        report.markStored(ownerId, field);
        return true;
      }
      const item = new PendingCredentialWrite();
      item.ownerId = ownerId;
      item.field = field;
      item.alias = alias;
      item.value = value;
      pending.push(item);
      report.migratedFields += 1;
      return true;
    };

    for (const n of nodes) {
      const nodeId: string = nodeCredentialId(n);
      if (nodeId.length === 0) {
        continue;
      }
      // 模型字段理论恒为 string，此处防御性收敛，防止历史数据/解析异常引入非 string 值
      const values: string[] = [
        typeof n.password === 'string' ? n.password : '',
        typeof n.uuid === 'string' ? n.uuid : '',
        typeof n.protocolParam === 'string' ? n.protocolParam : '',
        typeof n.obfsParam === 'string' ? n.obfsParam : ''
      ];
      for (let i = 0; i < NODE_CRED_FIELDS.length; i++) {
        planField(nodeId, NODE_CRED_FIELDS[i], values[i], nodeAlias(nodeId, NODE_CRED_FIELDS[i]));
      }
    }

    for (const s of subscriptions) {
      if (s.id.length === 0 || s.headerValue.length === 0) {
        continue;
      }
      planField(s.id, SUB_CRED_FIELD, s.headerValue, subAlias(s.id));
    }

    // 仅写入缺失/不一致项（通常只在首次迁移或凭据变更时发生）
    for (const item of pending) {
      try {
        await CredentialStore.writeAsset(item.alias, item.value);
        // 写入成功即维护会话缓存：后续刷新在 planField 命中「已存储」，
        // 不再整批 remove+add 重写（数百次 IPC 曾把整个应用拖慢）。
        CredentialStore.cachePut(item.alias, item.value);
      } catch (e) {
        report.failed += 1;
        report.markFailed(item.ownerId, item.field);
        AppLoggerSafe(`credential write failed (field=${item.field}, `
          + `valLen=${item.value.length}): ${errText(e)}`);
      }
    }

    if (pending.length > 0) {
      // 批量回读校验：一次查询核对全部写入项，只有回读一致才算入库。
      // 部分固件不支持 ReturnType.ALL + SECRET 的批量查询（Batch secret query is
      // not supported）→ loadAllCredentials 恒为空表 → 之前把成功写入误判为失败
      // （「保存失败 N」）。批量结果为空时改走逐条 ALIAS 精确查询兜底。
      const verify = await CredentialStore.loadAllCredentials();
      const batchUsable = verify.size > 0;
      for (const item of pending) {
        let actual: string | undefined;
        if (batchUsable) {
          actual = verify.get(item.alias);
        } else {
          const single = await CredentialStore.readAsset(item.alias);
          if (single.found) {
            actual = single.value;
          }
        }
        if (actual !== item.value) {
          report.failed += 1;
          report.markFailed(item.ownerId, item.field);
          // 回读不一致 = 缓存不可信，清掉该条避免后续误命中
          CredentialStore.cacheDelete(item.alias);
          AppLoggerSafe(`credential verify readback mismatch (field=${item.field}); keeping plaintext`);
        } else {
          report.addedNew += 1;
          report.markStored(item.ownerId, item.field);
          CredentialStore.cachePut(item.alias, item.value);
        }
      }
    }
    // 汇总节点级成败：无任何字段失败的节点才算迁移完成
    const failedNodes = new Set<string>();
    for (const n of nodes) {
      for (const f of NODE_CRED_FIELDS) {
        if (report.fieldFailed(nodeCredentialId(n), f)) {
          failedNodes.add(nodeCredentialId(n));
          break;
        }
      }
    }
    for (const n of nodes) {
      const nodeId: string = nodeCredentialId(n);
      if (nodeId.length === 0) {
        continue;
      }
      if (!failedNodes.has(nodeId)) {
        report.migratedNodes += 1;
      }
    }

    for (const s of subscriptions) {
      if (s.id.length === 0 || s.headerValue.length === 0) {
        continue;
      }
      if (!report.fieldFailed(s.id, SUB_CRED_FIELD)) {
        report.migratedSubscriptions += 1;
      }
    }
    return report;
  }

  /**
   * 固件能力探测与会话级别名缓存。
   * 部分固件不支持 ReturnType.ALL + SECRET 批量查询（恒报 Batch secret query
   * is not supported）→ 重启后由 hydrateKnownAliases 逐条 ALIAS 回填。
   * 没有本缓存时，每次刷新都会把全部凭据判为「未存储」而整批 remove+add 重写
   * （数百次 IPC，整应用被拖慢）；有了它，未变化的凭据直接跳过读写。
   *
   * 安全约束（2026-10-07 评审修复）：持久化只允许落**别名标记**（哪些 alias
   * 已封存），绝不落凭据值 —— 历史版本把 alias→值 的明文 JSON 写进 preferences
   * （sealed_alias_cache_json），与「凭据只进 AssetStore」的设计红线冲突；
   * 新格式为纯字符串数组，旧格式读取时丢弃值并由调用方立即重写净化。
   */
  private static batchQueryUsable: boolean | null = null;
  private static aliasCache: Map<string, string> = new Map<string, string>();
  /** 已知已封存别名（跨重启的标记集；值一律从 AssetStore 回读，绝不持久化值） */
  private static knownAliases: Set<string> = new Set<string>();
  /** 本进程是否已完成逐条回填（仅批量查询不可用的固件需要） */
  private static aliasHydrated: boolean = false;

  /** 维护会话缓存与标记集（所有写路径统一走这里） */
  private static cachePut(alias: string, value: string): void {
    CredentialStore.aliasCache.set(alias, value);
    CredentialStore.knownAliases.add(alias);
  }

  private static cacheDelete(alias: string): void {
    CredentialStore.aliasCache.delete(alias);
    CredentialStore.knownAliases.delete(alias);
  }

  /**
   * 会话缓存持久化(导出)：只导出**别名标记**（JSON 字符串数组），绝不导出值。
   * 仅当本固件批量查询确认为不可用时才需要持久化（导入端据此推断固件能力）；
   * 批量查询可用的固件返回空表，值重启后由一次批量查询恢复。
   * 由 SubscriptionService 在凭据写盘后调用保存。
   */
  static exportAliasCache(): string {
    if (CredentialStore.batchQueryUsable !== false) {
      return '[]';
    }
    const aliases: string[] = [];
    for (const alias of CredentialStore.knownAliases) {
      aliases.push(alias);
    }
    return JSON.stringify(aliases);
  }

  /**
   * 会话缓存持久化(导入)：恢复已封存**别名标记**；兼容旧格式 [[alias, value], ...]
   * —— 旧的明文值一律丢弃（由调用方立即以新格式重写该键完成净化）。
   */
  static importAliasCache(json: string): void {
    if (json.length === 0) {
      return;
    }
    try {
      const parsed = JSON.parse(json) as Object[];
      if (!Array.isArray(parsed)) {
        return;
      }
      CredentialStore.aliasCache.clear();
      CredentialStore.knownAliases.clear();
      CredentialStore.aliasHydrated = false;
      let count = 0;
      for (const item of parsed) {
        if (typeof item === 'string') {
          CredentialStore.knownAliases.add(item as string);
          count += 1;
        } else if (Array.isArray(item) && (item as Object[]).length === 2
          && typeof (item as Object[])[0] === 'string') {
          // 旧格式（含明文值）：只保留别名，值丢弃
          CredentialStore.knownAliases.add((item as Object[])[0] as string);
          count += 1;
        }
      }
      if (count > 0 && CredentialStore.batchQueryUsable === null) {
        // 有持久化标记说明本固件批量查询此前已确认不可用（否则用不到该标记）
        CredentialStore.batchQueryUsable = false;
      }
    } catch (e) {
      // 缓存损坏按空处理，绝不让恢复故障打断启动
    }
  }

  /**
   * 逐条回填已知别名的值（仅批量查询不可用的固件；每进程一次；分片并发）。
   * 值只驻留内存与 AssetStore —— 回填过程本身不写任何持久化。
   */
  private static async hydrateKnownAliases(): Promise<void> {
    if (CredentialStore.aliasHydrated) {
      return;
    }
    CredentialStore.aliasHydrated = true;
    const missing: string[] = [];
    for (const alias of CredentialStore.knownAliases) {
      if (!CredentialStore.aliasCache.has(alias)) {
        missing.push(alias);
      }
    }
    const CHUNK = 8;
    for (let i = 0; i < missing.length; i += CHUNK) {
      const slice = missing.slice(i, i + CHUNK);
      let reads: CredentialRead[] = [];
      try {
        reads = await Promise.all(slice.map((alias: string): Promise<CredentialRead> =>
          CredentialStore.readAsset(alias)));
      } catch (e) {
        continue; // 本片失败按缺失处理，不打断启动
      }
      for (let j = 0; j < slice.length; j++) {
        if (j < reads.length && reads[j].found && reads[j].value.length > 0) {
          CredentialStore.aliasCache.set(slice[j], reads[j].value);
        }
      }
    }
    AppLoggerSafe(`alias cache hydrated from asset store (${missing.length} alias(es))`);
  }

  /** 仅节点凭据的规范化入口（ManualNodeStore 等只有节点的调用方使用） */
  static async canonicalizeNodes(nodes: ProxyNode[], quickExit: boolean): Promise<CredentialMigrationReport> {
    return CredentialStore.canonicalize(nodes, [], quickExit);
  }

  /** Asset 读写 */
  private static async writeAsset(alias: string, value: string): Promise<void> {
    const attr: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    attr.set(asset.Tag.SECRET, stringToUint8(value));
    attr.set(asset.Tag.ALIAS, stringToUint8(alias));
    attr.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    // SET 语义：先清旧值再写。remove 只带 ALIAS（带 SECRET 等多余 tag 的 remove 可能参数错误
    // 且异常被吞 → 旧值残留 → 下一次 add 抛 already exists → 凭据保存失败）。
    try {
      await asset.remove(CredentialStore.removeAttrOf(alias));
    } catch (e) {
      // 首次写入前不存在属正常（与 SettingsService.setApiSecret 行为一致）
    }
    await asset.add(attr);
  }

  /**
   * 单次 asset.query 取回本应用全部凭据（alias → 值）。
   * 批量回填/迁移的唯一读取入口：把 N×M 次逐条 IPC 压成 1 次。
   * 查询异常时返回已收集部分（可能为空 Map），调用方按缺失处理。
   */
  static async loadAllCredentials(): Promise<Map<string, string>> {
    // 已探测到批量查询不可用的固件：先用持久化标记逐条回填（每进程一次），
    // 再返回会话缓存；不再反复发起注定失败的批量查询。
    if (CredentialStore.batchQueryUsable === false) {
      await CredentialStore.hydrateKnownAliases();
      return CredentialStore.aliasCache;
    }
    const out = new Map<string, string>();
    try {
      const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const results: asset.AssetMap[] = await asset.query(query);
      for (const m of results) {
        const aliasVal = m.get(asset.Tag.ALIAS);
        const secretVal = m.get(asset.Tag.SECRET);
        if (aliasVal !== undefined && aliasVal instanceof Uint8Array
          && secretVal !== undefined && secretVal instanceof Uint8Array) {
          out.set(uint8ToString(aliasVal as Uint8Array), uint8ToString(secretVal as Uint8Array));
        }
      }
      if (out.size === 0 && results.length === 0) {
        // 空结果 + 空表：该固件批量查询不可用（已在日志确认），之后走逐条兜底
        if (CredentialStore.batchQueryUsable === null && CredentialStore.aliasCache.size > 0) {
          CredentialStore.batchQueryUsable = false;
          for (const pair of CredentialStore.aliasCache) {
            out.set(pair[0], pair[1]);
          }
          return out;
        }
        CredentialStore.batchQueryUsable = false;
      } else {
        CredentialStore.batchQueryUsable = true;
        for (const pair of out) {
          CredentialStore.cachePut(pair[0], pair[1]);
        }
      }
    } catch (e) {
      // 读不到就当全部缺失：调用方按回退路径处理，绝不让读取故障打断启动
      CredentialStore.batchQueryUsable = false;
      if (CredentialStore.aliasCache.size > 0) {
        for (const pair of CredentialStore.aliasCache) {
          out.set(pair[0], pair[1]);
        }
      }
    }
    return out;
  }

  /**
   * 从预加载的全量凭据表解析节点凭据（同步、零 IPC）。
   * 与 nodeCredentials 同语义，供 initNodes 等批量场景一次加载全部后逐节点取值。
   */
  static nodeCredentialsFromCache(cache: Map<string, string>, nodeId: string,
    fallback: NodeCredentialValues): NodeCredentialValues {
    const out = new NodeCredentialValues();
    out.password = fallback.password;
    out.uuid = fallback.uuid;
    out.protocolParam = fallback.protocolParam;
    out.obfsParam = fallback.obfsParam;
    if (nodeId.length === 0) {
      return out;
    }
    for (let i = 0; i < NODE_CRED_FIELDS.length; i++) {
      const field: string = NODE_CRED_FIELDS[i];
      const stored = cache.get(nodeAlias(nodeId, field));
      if (stored !== undefined && stored.length > 0) {
        if (field === 'password') {
          out.password = stored;
        } else if (field === 'uuid') {
          out.uuid = stored;
        } else if (field === 'protocolParam') {
          out.protocolParam = stored;
        } else if (field === 'obfsParam') {
          out.obfsParam = stored;
        }
      }
    }
    return out;
  }

  private static async readAsset(alias: string): Promise<CredentialRead> {
    const out = new CredentialRead();
    try {
      const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
      query.set(asset.Tag.ALIAS, stringToUint8(alias));
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const results: asset.AssetMap[] = await asset.query(query);
      if (results.length === 0) {
        return out;
      }
      const secretVal = results[0].get(asset.Tag.SECRET);
      if (secretVal !== undefined && secretVal instanceof Uint8Array) {
        out.found = true;
        out.value = uint8ToString(secretVal as Uint8Array);
      }
      return out;
    } catch (e) {
      // 读取失败按缺失处理（Asset 不可用时由调用方回退一次性来源）
      return out;
    }
  }

  /**
   * 批量透明读取某节点的凭据（连接配置生成/节点列表走这里）。
   * fallback 为一次性来源（rawUri，绝不落盘）。单次 asset.query 取回整个 alias 集合。
   */
  static async nodeCredentials(nodeId: string, fallback: NodeCredentialValues): Promise<NodeCredentialValues> {
    const out = new NodeCredentialValues();
    out.password = fallback.password;
    out.uuid = fallback.uuid;
    out.protocolParam = fallback.protocolParam;
    out.obfsParam = fallback.obfsParam;
    if (nodeId.length === 0) {
      return out;
    }
    if (!CredentialStore.probed) {
      await CredentialStore.probe();
    }
    if (!CredentialStore.available) {
      return out;
    }
    try {
      let cache: Map<string, string>;
      if (CredentialStore.batchQueryUsable === false) {
        // 该固件批量查询不可用：先用持久化标记逐条回填（每进程一次），再取会话缓存
        await CredentialStore.hydrateKnownAliases();
        cache = CredentialStore.aliasCache;
      } else {
        const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
        query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
        const results: asset.AssetMap[] = await asset.query(query);
        cache = CredentialStore.makeCache();
        for (const m of results) {
          const aliasVal = m.get(asset.Tag.ALIAS);
          const secretVal = m.get(asset.Tag.SECRET);
          if (aliasVal !== undefined && aliasVal instanceof Uint8Array
            && secretVal !== undefined && secretVal instanceof Uint8Array) {
            cache.set(uint8ToString(aliasVal as Uint8Array), uint8ToString(secretVal as Uint8Array));
          }
        }
      }
      out.password = CredentialStore.pick(cache, nodeAlias(nodeId, 'password'), out.password);
      out.uuid = CredentialStore.pick(cache, nodeAlias(nodeId, 'uuid'), out.uuid);
      out.protocolParam = CredentialStore.pick(cache, nodeAlias(nodeId, 'protocolParam'), out.protocolParam);
      out.obfsParam = CredentialStore.pick(cache, nodeAlias(nodeId, 'obfsParam'), out.obfsParam);
      return out;
    } catch (e) {
      // 读取异常：整体回退一次性来源，绝不让连接因加密层故障而失败
      return out;
    }
  }

  private static pick(cache: Map<string, string>, alias: string, fallback: string): string {
    const cached = cache.get(alias);
    return cached === undefined ? fallback : cached;
  }

  /** 订阅凭据透明读取：Asset 优先，缺失返回 fallback（一次性来源） */
  static async subscriptionCredential(subscriptionId: string, fallback: string): Promise<string> {
    if (subscriptionId.length === 0) {
      return fallback;
    }
    const read = await CredentialStore.readAsset(subAlias(subscriptionId));
    return read.found ? read.value : fallback;
  }

  /** preferences 中是否还残留明文凭据键（迁移后应为 0） */
  static plaintextFieldKeys(): string[] {
    const out: string[] = [];
    for (const f of NODE_CRED_FIELDS) {
      out.push(f);
    }
    out.push(SUB_CRED_FIELD);
    return out;
  }

  /** Asset 不可用时的显式记录（调用方在报错路径使用） */
  static logAssetUnavailable(path: string): void {
    AppLoggerSafe(`asset store unavailable at ${path}: plaintext kept, plaintext credentials not persisted`);
  }
}

/** 批量迁移中待写入的凭据项（只含定位信息，不含多余派生数据） */
class PendingCredentialWrite {
  ownerId: string = '';
  field: string = '';
  alias: string = '';
  value: string = '';
}

/** 订阅凭据来源（避免与偏好模型耦合） */
export class SubscriptionCredentialSource {
  id: string = '';
  headerValue: string = '';
}

/**
 * 节点凭据 alias 的稳定 ID。
 * 用 SubscriptionService.nodeKey 同源信息（订阅|服务器|端口|原名），
 * 跨订阅刷新/节点重排/去重改名保持不变；节点直链导入用 rawUri 兜底。
 */
export function nodeCredentialId(n: ProxyNode): string {
  const base: string = baseNodeName(n.name);
  if (n.subscriptionId.length > 0 && n.server.length > 0 && n.port > 0) {
    return `${n.subscriptionId}|${n.server}|${n.port}|${base}`;
  }
  return n.rawUri;
}

/**
 * 与 SubscriptionService.baseName 同源：去掉去重后缀，还原节点原始名。
 * 两种历史形态都要剥：" #2"（SubscriptionService.ensureUniqueNames 旧形态）
 * 与 " (2)"（YamlMerger.uniqueProxyName 形态，现已统一为该形态）。
 * 只剥其一会让「改名后的节点」与加密层 alias/隐藏清单失配 —— 表现为凭据回填失败
 * （生成配置时整条丢成空行）或已删节点刷新后复活。
 */
export function baseNodeName(name: string): string {
  let out = name;
  let changed = true;
  while (changed) {
    changed = false;
    const next = out.replace(/\s#\d+$/, '').replace(/\s\(\d+\)$/, '');
    if (next !== out) {
      out = next;
      changed = true;
    }
  }
  return out;
}

export function nodeAlias(nodeId: string, field: string): string {
  return `${NODE_ALIAS_PREFIX}|${nodeId}|${field}`;
}

export function subAlias(subscriptionId: string): string {
  return `${SUB_ALIAS_PREFIX}|${subscriptionId}|${SUB_CRED_FIELD}`;
}

/** 日志兜底：避免本模块反向依赖 AppLogger（防止循环引用） */
let logger: ((msg: string) => void) | null = null;

export function setCredentialLogger(fn: (msg: string) => void): void {
  logger = fn;
}

function AppLoggerSafe(msg: string): void {
  if (logger !== null) {
    logger(`[CredentialStore] ${msg}`);
  }
}

/**
 * 错误 → 文本：系统 API 抛出的多是 BusinessError 形态普通对象（{code, message}），
 * 沿用 Error 实例判断会退化成 [object Object]。本模块刻意不依赖 AppLogger（防循环
 * 引用），语义与 AppLogger.errText 保持对齐（消息 + 非零 code + 占位兜底）。
 */
function errText(e: Object): string {
  if (e === null || e === undefined) {
    return '未知错误（错误对象为空）';
  }
  const biz = e as Record<string, Object>;
  const msgVal = biz.message;
  const codeVal = biz.code;
  const msg: string = (typeof msgVal === 'string') ? msgVal as string : '';
  const code: number = (typeof codeVal === 'number') ? codeVal as number : 0;
  if (msg.length > 0) {
    return code !== 0 ? `code=${code} ${msg}` : msg;
  }
  if (code !== 0) {
    return `code=${code}`;
  }
  const text = String(e);
  return (text.length === 0 || text === '[object Object]') ? '未知错误（错误对象不含文本或代码）' : text;
}

function stringToUint8(s: string): Uint8Array {
  if (typeof s !== 'string') {
    // 防御：asset SECRET 要求 napi_object（Uint8Array），绝不能把 undefined 等原始值传进去
    s = s === null || s === undefined ? '' : String(s);
  }
  try {
    // 用最稳定的 encode()（API 8 起可用）而非较新的单参 encodeInto() 重载
    const out = util.TextEncoder.create('utf-8').encode(s);
    if (out instanceof Uint8Array) {
      return out;
    }
  } catch (e) {
    // 落入兜底
  }
  return new Uint8Array(0);
}

function uint8ToString(bytes: Uint8Array): string {
  return util.TextDecoder.create('utf-8').decodeToString(bytes);
}
