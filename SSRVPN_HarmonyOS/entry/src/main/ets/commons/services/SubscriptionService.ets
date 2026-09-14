/**
 * 订阅服务：增删改查 + 刷新 + 撤销；手工节点独立存储（ManualNodeStore）
 * 移植自 upstream: SSRVPN_Android/lib/services/subscription_service.dart
 *                packages/ssrvpn_shared/lib/services/subscription_service_*.dart
 *                subscription_processing.dart / subscription_undo_record.dart
 *
 * 敏感凭据存储策略（对齐 SettingsService.apiSecret 的 AssetStore 先例）：
 * - 节点 password/uuid/protocolParam/obfsParam、订阅 headerValue 只允许写入系统加密
 *   AssetStore（@ohos.security.asset / @kit.AssetStoreKit），禁止降级为明文 preferences。
 * - 其余节点元数据（server/port/method/network/TLS 参数等）仍存 preferences，
 *   alias 采用稳定键 "ssrvpn_node|<nodeId>|<field>" / "ssrvpn_sub|<subId>|headerValue"。
 * - Asset 缺失（首次升级、清除数据、写入失败回滚）时回退读取一次性绑定字段：
 *   节点用 node.rawUri（上游同样只写 Asset，绝不写 preferences），订阅用内存态，
 *   两者都不落盘明文。
 * - 一次性迁移：把历史明文 preferences 中的凭据写入 Asset 并回读校验，成功后才删除明文；
 *   任一步失败保留明文并记录，绝不丢数据。迁移幂等（重跑只重写加密层，不清明文）。
 */
import { preferences } from '@kit.ArkData';
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import {
  Subscription, SubscriptionImportDiagnostics, SubscriptionRefreshResult, SubscriptionRefreshStatus
} from '../models/Subscription';
import { ProxyNode, ProxyNodeType, SsrCodec } from '../models/ProxyNode';
import { ProxyGroup, ProxyGroupJson } from '../models/ProxyGroup';
import { AppSettings } from '../models/AppSettings';
import { SubscriptionParseResult, SubscriptionParser } from './SubscriptionParser';
import {
  SubscriptionFetchPolicy, SubscriptionFetchError, SubscriptionFetchErrorKind, SubscriptionFetchResult
} from './SubscriptionFetchPolicy';
import { YamlMerger, MergedProxy, YamlMergeError, YamlNodeError } from './YamlMerger';
import { ClashConfigGenerator, ProxyDropStats } from './ClashConfigGenerator';
import { ProxyProviderEntry, ProxyProviderParser } from './ProxyProviderParser';
import {
  RawProviderEntry, RawProviderStates, RawProviderStatus, RawSubscriptionStore, RawWriteResult
} from './RawSubscriptionStore';
import {
  CredentialStore, CredentialMigrationReport, NodeCredentialValues, SubscriptionCredentialSource,
  CRED_PREF_NAME, MIGRATION_FLAG_KEY, NODE_CRED_FIELDS, baseNodeName, nodeCredentialId, setCredentialLogger
} from './CredentialStore';
import { AppLogger } from '../utils/AppLogger';
import {
  ConcurrentRefresh, RefreshBatchProgress, RefreshBatchSummary, RefreshItemOutcome, RefreshPrepOutcome
} from './ConcurrentRefresh';

const TAG = 'SubscriptionService';

const PREF_NAME = 'ssrvpn_subscriptions';
const KEY_SUBS = 'subscriptions_json';
const KEY_NODES = 'nodes_json';
const KEY_HIDDEN = 'hidden_nodes_json';
const KEY_GROUPS = 'proxy_groups_json';
export const DIRECT_GROUP_ID = 'direct';
const DIRECT_GROUP_NAME = '单节点';
const DIRECT_GROUP_URL = 'local://direct';

/**
 * 并发预取结果的存活上限。批次被中断（页面销毁 / 用户连点被拦）后残留的 body
 * 绝不允许被后续刷新误当成最新内容写进节点表：宁可多打一次请求，也不能写错数据。
 */
const PREFETCH_TTL_MS = 60 * 1000;

/**
 * 并发批次「网络阶段」的唯一产物：拉取结果或拉取错误（二选一，无 null 字段以便严格模式收窄）。
 * 只放内存、只由 prefetchSubscription 写入、只由 takePrefetch 取走（取走即删）。
 */
class PrefetchedSubscription {
  url: string = '';
  headerName: string = '';
  headerValue: string = '';
  at: number = 0;
  /** 是否命中预取（false = 未预取，由串行阶段自行拉取） */
  hit: boolean = false;
  /** 命中时携带的是错误还是结果 */
  hasError: boolean = false;
  fetched: SubscriptionFetchResult = new SubscriptionFetchResult();
  error: SubscriptionFetchError = new SubscriptionFetchError(SubscriptionFetchErrorKind.NETWORK, '');

  static body(url: string, headerName: string, headerValue: string,
    fetched: SubscriptionFetchResult): PrefetchedSubscription {
    const p = new PrefetchedSubscription();
    p.url = url;
    p.headerName = headerName;
    p.headerValue = headerValue;
    p.at = Date.now();
    p.hit = true;
    p.hasError = false;
    p.fetched = fetched;
    return p;
  }

  static failure(url: string, headerName: string, headerValue: string,
    error: SubscriptionFetchError): PrefetchedSubscription {
    const p = new PrefetchedSubscription();
    p.url = url;
    p.headerName = headerName;
    p.headerValue = headerValue;
    p.at = Date.now();
    p.hit = true;
    p.hasError = true;
    p.error = error;
    return p;
  }
}

/** 一次性回退源（rawUri）在偏好中的键；节点凭据加密写入成功后即删除 */
function nodeUriKey(nodeId: string): string {
  return `rawuri|${nodeId}`;
}

export class SubscriptionService {
  private store: preferences.Preferences | null = null;
  /** 敏感凭据专用偏好（只放一次性绑定，不放凭据本体） */
  private credStore: preferences.Preferences | null = null;
  /** 明文清扫是否已结束（结束后节点凭据完全由 AssetStore 承担） */
  private sealedPlaintextKeys: boolean = false;
  subscriptions: Subscription[] = [];
  nodes: ProxyNode[] = [];
  /** 订阅内代理组（静态成员 + 已物化的动态分组成员），随订阅增删/刷新同步 */
  proxyGroups: ProxyGroup[] = [];
  /** 用户手动删除的节点指纹清单: 订阅刷新时过滤, 防止已删节点"复活" */
  private hiddenNodes: string[] = [];
  /** 撤销记录（对应 subscription_undo_record.dart）：最近一次删除的订阅与节点 */
  private undoSnapshot: SubscriptionUndoSnapshot | null = null;
  /** 敏感凭据已由本实例加载/写入加密层（幂等闸门） */
  private credentialsReady: boolean = false;
  /**
   * 最近一次凭据回填后仍缺凭据（password/uuid 为空但协议需要）的节点数。
   * >0 表示加密层不可用或凭据已丢失 —— UI 必须明确提示, 而不是让节点在
   * 生成配置阶段被静默丢成空行（「列表有、内核无」）。
   */
  credentialMissingCount: number = 0;
  /** 最近一次导入（刷新/本地 YAML/直链）的诊断, 供页面直接展示 */
  lastImportDiagnostics: SubscriptionImportDiagnostics = new SubscriptionImportDiagnostics();
  /** 最近一次节点恢复（nodes_json → 内存）被丢弃的记录数与原因 */
  lastRestoreInvalidCount: number = 0;
  lastRestoreInvalidReasons: string = '';
  /**
   * 双轨（原始订阅 → file provider）最近一次的诊断口径字符串：
   * 「解析到 N / provider 读到 M」，诊断面板直接展示（任何差额可见）。
   */
  lastRawProviderSummary: string = '';
  /** 最近一次开关切换/清理的结果文案（诊断面板提示用） */
  lastRawProviderMessage: string = '';
  /**
   * 并发批次的预取缓存（key = 订阅 id）。这是并发阶段**唯一**被写入的状态：
   * 并发阶段只做网络拉取并暂存结果，绝不碰 this.nodes / 订阅统计 / preferences，
   * 因此不会出现「两个刷新同时落盘互相覆盖」。串行阶段 takePrefetch 取走即删。
   */
  private prefetchCache: Map<string, PrefetchedSubscription> = new Map<string, PrefetchedSubscription>();

  async init(context: Context): Promise<void> {
    // 双轨落盘仓先就位（cacheDir 与内核 HomeDir 一致，见 RawSubscriptionStore 顶部注释）
    RawSubscriptionStore.init(context.cacheDir);
    this.store = await preferences.getPreferences(context, PREF_NAME);
    this.subscriptions = [];
    this.nodes = [];
    this.proxyGroups = [];
    this.hiddenNodes = [];

    // 敏感凭据专用 preferences（仅存放一次性绑定字段，凭据本体在 AssetStore）
    if (this.credStore === null) {
      this.credStore = await preferences.getPreferences(context, CRED_PREF_NAME);
    }
    setCredentialLogger((msg: string) => AppLogger.info(TAG, msg));

    try {
      const subsRaw = await this.store.get(KEY_SUBS, '[]') as string;
      this.subscriptions = SubscriptionService.mapSubs(JSON.parse(subsRaw) as Object);
    } catch (e) {
      AppLogger.warn(TAG, 'invalid subscriptions preferences ignored');
    }

    try {
      const nodesRaw = await this.store.get(KEY_NODES, '[]') as string;
      const restoreDiagnostics = new SubscriptionImportDiagnostics();
      this.nodes = SubscriptionService.mapNodes(JSON.parse(nodesRaw) as Object, restoreDiagnostics);
      this.lastRestoreInvalidCount = restoreDiagnostics.invalidCount;
      this.lastRestoreInvalidReasons = restoreDiagnostics.invalidReasons;
      if (restoreDiagnostics.invalidCount > 0) {
        AppLogger.warn(TAG, `restore dropped ${restoreDiagnostics.invalidCount} node record(s): `
          + `${restoreDiagnostics.invalidReasons}`);
      }
    } catch (e) {
      AppLogger.warn(TAG, 'invalid nodes preferences ignored');
    }

    try {
      const hiddenRaw = await this.store.get(KEY_HIDDEN, '[]') as string;
      const arr = JSON.parse(hiddenRaw) as string[];
      if (Array.isArray(arr)) {
        this.hiddenNodes = arr.filter((x): boolean => typeof x === 'string');
      }
    } catch (e) {
      AppLogger.warn(TAG, 'invalid hidden nodes preferences ignored');
    }

    try {
      const groupsRaw = await this.store.get(KEY_GROUPS, '[]') as string;
      this.proxyGroups = SubscriptionService.mapGroups(JSON.parse(groupsRaw) as Object);
    } catch (e) {
      AppLogger.warn(TAG, 'invalid proxy groups preferences ignored');
    }

    // 1) 一次性凭据迁移（必须在任何 persist 之前，避免明文被再次写回）
    await this.runCredentialMigrationOnce();
    // 2) 从加密层回填订阅凭据（headerValue 从不落 preferences）
    await this.hydrateSubscriptionCredentials();
    // 3) 节点凭据回填（Asset 缺失时用一次性 rawUri 解析兜底）
    await this.initNodes(this.nodes);

    // 4) 明文清扫：加密层验证通过的记录删除 preferences 明文字段
    // 历史数据可能存在重名节点(内核会拒绝启动), 加载时即去重并落库
    const renamed = this.ensureUniqueNames();

    // 4.5) 分组恢复兜底：旧存储没有 proxy_groups_json 但存在 yaml_cache_ 的订阅，
    //      从结构化缓存重解析分组并按当前节点池物化（升级后首次启动即可用）。
    const groupsRebuilt = await this.rebuildGroupsFromCacheIfMissing();

    let directGroup = this.subscriptions.find((s) => s.id === DIRECT_GROUP_ID);
    let createdDirectGroup = false;
    if (directGroup === undefined) {
      directGroup = Subscription.newSubscription(DIRECT_GROUP_ID, DIRECT_GROUP_NAME, DIRECT_GROUP_URL);
      directGroup.sortOrder = 0;
      this.subscriptions.unshift(directGroup);
      createdDirectGroup = true;
    }
    directGroup.nodeCount = this.nodes.filter((n) => n.subscriptionId === DIRECT_GROUP_ID).length;

    // 5) 双轨 provider 对账：清理孤儿落盘文件 + 回填每订阅 provider 状态
    //    （开关关闭时只清孤儿文件，绝不读订阅原文）
    const rawReconciled = this.reconcileRawProviders();

    AppLogger.info(TAG, `loaded ${this.subscriptions.length} subscriptions, `
      + `${this.nodes.length} nodes, ${this.proxyGroups.length} proxy groups`);
    if (renamed || createdDirectGroup || rawReconciled || groupsRebuilt) {
      await this.persist();
    }
  }

  /**
   * 升级恢复路径：proxy_groups_json 缺失（旧版本存储）但有 yaml_cache_ 结构化缓存的
   * 订阅，从缓存重解析分组并物化动态成员。结果随后随 init 末尾的 persist 落盘，
   * 幂等（有持久化分组的订阅不重建）。
   */
  private async rebuildGroupsFromCacheIfMissing(): Promise<boolean> {
    if (this.store === null) {
      return false;
    }
    const hasGroupsFor = new Set<string>();
    for (const g of this.proxyGroups) {
      hasGroupsFor.add(g.subscriptionId);
    }
    let rebuilt = false;
    for (const s of this.subscriptions) {
      if (s.id === DIRECT_GROUP_ID || hasGroupsFor.has(s.id)) {
        continue;
      }
      let cached = '';
      try {
        cached = await this.store.get(`yaml_cache_${s.id}`, '') as string;
      } catch (e) {
        continue;
      }
      if (cached.length === 0) {
        continue;
      }
      const groups = SubscriptionParser.parseProxyGroups(cached, s.id);
      if (groups.length === 0) {
        continue;
      }
      SubscriptionParser.materializeDynamicGroups(groups, this.nodesOf(s.id));
      this.proxyGroups = this.proxyGroups.concat(groups);
      rebuilt = true;
      AppLogger.info(TAG, `rebuilt ${groups.length} proxy group(s) from cached yaml `
        + `for subscription ${s.id}`);
    }
    return rebuilt;
  }

  /**
   * 双轨 provider 对账（启动时调用一次）：
   * 1) 删除不属于任何现存订阅的孤儿文件（订阅在应用被杀时被删的场景）；
   * 2) 开关开启时：文件存在 → 状态 ready 并登记 provider（条目数从落盘原文读回估算）；
   *    文件缺失 → 状态 missing（节点仍保留在列表里，UI 明确提示，绝不因此删节点）。
   * 返回是否需要重新持久化（订阅元数据发生变化）。
   */
  private reconcileRawProviders(): boolean {
    if (!RawSubscriptionStore.isReady()) {
      return false;
    }
    const ids: string[] = [];
    for (const s of this.subscriptions) {
      ids.push(s.id);
    }
    RawSubscriptionStore.removeOrphans(ids);
    if (!RawSubscriptionStore.enabled) {
      // 开关关闭：落盘仓已被 SettingsService 闸门清空，订阅状态无需改写
      return false;
    }
    let changed = false;
    for (const s of this.subscriptions) {
      if (s.id === DIRECT_GROUP_ID) {
        continue;
      }
      if (RawSubscriptionStore.has(s.id)) {
        const estimate = SubscriptionService.countRawEntries(s.id);
        if (s.rawProviderState !== RawProviderStates.READY
          || s.rawProviderNodeEstimate !== estimate) {
          changed = true;
        }
        s.rawProviderState = RawProviderStates.READY;
        s.rawProviderNodeEstimate = estimate;
        this.registerRawProvider(s.id, estimate);
        continue;
      }
      if (s.rawProviderState !== RawProviderStates.INELIGIBLE
        && s.rawProviderState !== RawProviderStates.FAILED) {
        // 开关开着但文件没了（被清理 / 上次写入未完成）：显式标 missing，节点不删
        if (s.rawProviderState !== RawProviderStates.MISSING) {
          changed = true;
        }
        s.rawProviderState = RawProviderStates.MISSING;
        s.rawProviderNodeEstimate = 0;
      }
      RawSubscriptionStore.drop(s.id);
    }
    return changed;
  }

  /** 落盘原文的条目数估算（与生成配置时的条目口径一致；失败返回 0） */
  private static countRawEntries(subscriptionId: string): number {
    const body = RawSubscriptionStore.readRaw(subscriptionId);
    if (body.length === 0) {
      return 0;
    }
    try {
      return YamlMerger.proxyItemGroups(body).length;
    } catch (e) {
      return 0;
    }
  }

  /** 登记 provider（生成器 planRawProviders 只认登记表 + 文件存在性） */
  private registerRawProvider(subscriptionId: string, nodeEstimate: number): void {
    const entry = new RawProviderEntry();
    entry.subscriptionId = subscriptionId;
    entry.providerName = RawSubscriptionStore.providerNameFor(subscriptionId);
    entry.providerPath = RawSubscriptionStore.providerPathFor(subscriptionId);
    entry.filePath = RawSubscriptionStore.filePathFor(subscriptionId);
    entry.bytes = RawSubscriptionStore.sizeOf(subscriptionId);
    entry.nodeEstimate = nodeEstimate;
    RawSubscriptionStore.upsert(entry);
  }

  /**
   * 一次性迁移：把历史 preferences 明文凭据写入 AssetStore（写后回读校验），
   * 全部成功后才清除明文键。任一失败保留明文并记录，绝不丢数据。
   * 幂等：非首启时不再改写凭据本体（只补建缺失项），也不重复清明文。
   */
  private async runCredentialMigrationOnce(): Promise<void> {
    await CredentialStore.loadMigrationFlag();
    const firstRun = CredentialStore.isFirstRun();
    let plainKeys: string[] = [];
    if (this.credStore !== null) {
      const raw = await this.credStore.get('sealed_node_keys_json', '[]') as string;
      plainKeys = SubscriptionService.readJsonStringArray(raw);
    }

    const sources: SubscriptionCredentialSource[] = [];
    for (const s of this.subscriptions) {
      const src = new SubscriptionCredentialSource();
      src.id = s.id;
      src.headerValue = s.headerValue;
      if (s.headerValue.length > 0) {
        sources.push(src);
      }
    }

    let report: CredentialMigrationReport;
    try {
      report = await CredentialStore.canonicalize(this.nodes, sources, !firstRun);
    } catch (e) {
      AppLogger.warn(TAG, `credential canonicalize aborted: ${e instanceof Error ? e.message : String(e)}`);
      return;
    }

    // 节点若仍受明文约束（Asset 写入/校验失败），其 rawUri 必须继续保留作回退源
    const keepIds = new Set<string>();
    for (const n of this.nodes) {
      let bound = false;
      let boundField = '';
      for (const f of NODE_CRED_FIELDS) {
        if (f === 'password' && n.password.length > 0) {
          bound = true;
          boundField = f;
        } else if (f === 'uuid' && n.uuid.length > 0) {
          bound = true;
          boundField = f;
        } else if (f === 'protocolParam' && n.protocolParam.length > 0) {
          bound = true;
          boundField = f;
        } else if (f === 'obfsParam' && n.obfsParam.length > 0) {
          bound = true;
          boundField = f;
        }
      }
      if (bound && !report.fieldFailed(nodeCredentialId(n), boundField)) {
        keepIds.add(nodeCredentialId(n));
      }
    }

    this.credentialsReady = true;

    if (report.failed > 0) {
      // Asset 不可用或个别凭据校验失败：绝不清明文，也不做任何持久化（保留现状）
      CredentialStore.logAssetUnavailable('migration');
      AppLogger.warn(TAG,
        `credential migration incomplete: ${report.failed} field(s) failed; plaintext preserved`);
      return;
    }
    if (!firstRun) {
      // 幂等：非首启不重复清除
      AppLogger.info(TAG, `credential migration idempotent: ${report.alreadyStored} verified, ${report.addedNew} added`);
      return;
    }

    // 首启且全部校验通过 → 清 preferences 明文凭据（节点 JSON 字段 + 订阅 headerValue 已由 toJson 恒空）
    await this.sealPlaintext(plainKeys, keepIds);
    await this.markMigrationDone();
    AppLogger.info(TAG,
      `credential migration done: ${report.migratedNodes} node(s) / ${report.migratedSubscriptions} sub credential(s) moved to asset store`);
  }

  /** 残留一键扫描（专项验证用）：返回 preferences 中仍可枚举到的明文凭据键 */
  async scanPlaintextResidue(): Promise<string[]> {
    const out: string[] = [];
    if (this.store === null) {
      return out;
    }
    const nodesRaw = await this.store.get(KEY_NODES, '[]') as string;
    const subsRaw = await this.store.get(KEY_SUBS, '[]') as string;
    for (const field of CredentialStore.plaintextFieldKeys()) {
      const needle = `"${field}":"`;
      if (nodesRaw.includes(needle)) {
        const probe = `"${field}":""`;
        // 空串是规范化目标，只有非空值才算残留
        const hit = nodesRaw.indexOf(needle);
        if (hit >= 0 && !nodesRaw.startsWith(probe, hit)) {
          out.push(`nodes_json.${field}`);
        }
      }
      if (subsRaw.includes(needle)) {
        out.push(`subscriptions_json.${field}`);
      }
    }
    return out;
  }

  /**
   * 清除已迁移成功的明文凭据。
   * 节点：清 preferences JSON 字段并 flush；确认写入成功后才释放 rawUri 回退源。
   * 订阅：headerValue 已不参与序列化（Subscription.toJson 恒空），无需额外处理。
   */
  private async sealPlaintext(plainKeys: string[], keepIds: Set<string>): Promise<void> {
    let sealedNodes = 0;
    let unverifiedNodes = 0;
    if (this.store !== null) {
      try {
        for (const n of this.nodes) {
          if (keepIds.has(nodeCredentialId(n))) {
            continue;
          }
          // 只有能从加密层「原值回读」的节点才允许清明文。否则一旦 Asset 缺失
          // （清理数据/升级/写入失败），重启后 password/uuid 为空 → 生成配置时整条被丢。
          const verifiable = await SubscriptionService.hasVerifiableStoredCredentials(n);
          if (!verifiable) {
            if (n.password.length > 0 || n.uuid.length > 0
              || n.protocolParam.length > 0 || n.obfsParam.length > 0) {
              unverifiedNodes = unverifiedNodes + 1;
            }
            continue;
          }
          n.password = '';
          n.uuid = '';
          n.protocolParam = '';
          n.obfsParam = '';
          n.rawYaml = '';
          n.rawUri = '';
          sealedNodes = sealedNodes + 1;
        }
        await this.store.put(KEY_NODES, JSON.stringify(SubscriptionService.nodesToJson(this.nodes)));
        await this.store.flush();
      } catch (e) {
        AppLogger.warn(TAG,
          `plaintext seal failed (plaintext kept in memory only, no credential loss): ${e instanceof Error ? e.message : String(e)}`);
      }
    }
    if (unverifiedNodes > 0) {
      AppLogger.warn(TAG,
        `plaintext seal skipped for ${unverifiedNodes} node(s): credentials are not readable from asset store `
        + '— plaintext kept so that connection keeps working');
    }
    if (sealedNodes > 0) {
      AppLogger.info(TAG, `plaintext seal done for ${sealedNodes} node(s) (credentials verified in asset store)`);
    }
    if (this.nodes.length > 0 || plainKeys.length > 0) {
      this.sealedPlaintextKeys = true;
    }
  }

  /**
   * 加密层回读校验（漏洞 A 第二半：凭据封存后未回填）。
   * 只有节点内存中每个非空凭据字段都能从 AssetStore 原值读回时才返回 true;
   * Asset 缺失/写入失败/回读不一致一律返回 false → 明文保留, 保证连接时凭据可用。
   * 无需凭据的节点（如 anytls/tuic 中继型）直接视为可封存。
   */
  private static async hasVerifiableStoredCredentials(n: ProxyNode): Promise<boolean> {
    const needed = n.password.length > 0 || n.uuid.length > 0
      || n.protocolParam.length > 0 || n.obfsParam.length > 0;
    if (!needed) {
      return true;
    }
    const empty = new NodeCredentialValues();
    let stored: NodeCredentialValues;
    try {
      stored = await CredentialStore.nodeCredentials(nodeCredentialId(n), empty);
    } catch (e) {
      return false;
    }
    if (n.password.length > 0 && stored.password !== n.password) {
      return false;
    }
    if (n.uuid.length > 0 && stored.uuid !== n.uuid) {
      return false;
    }
    if (n.protocolParam.length > 0 && stored.protocolParam !== n.protocolParam) {
      return false;
    }
    if (n.obfsParam.length > 0 && stored.obfsParam !== n.obfsParam) {
      return false;
    }
    return true;
  }

  private async markMigrationDone(): Promise<void> {
    if (this.credStore === null) {
      return;
    }
    try {
      await this.credStore.put(MIGRATION_FLAG_KEY, '1');
      await this.credStore.flush();
    } catch (e) {
      AppLogger.warn(TAG, `migration flag write failed: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  private static readJsonStringArray(raw: string): string[] {
    try {
      const arr = JSON.parse(raw) as string[];
      return Array.isArray(arr) ? arr : [];
    } catch (e) {
      return [];
    }
  }

  /**
   * 回填订阅凭据：Asset 缺失时保持内存态原值（本进程内新输入），
   * 不回退任何持久化明文来源。
   */
  private async hydrateSubscriptionCredentials(): Promise<void> {
    for (const s of this.subscriptions) {
      const value = await CredentialStore.subscriptionCredential(s.id, s.headerValue);
      s.headerValue = value;
    }
  }

  /**
   * 节点凭据回填：Asset 优先。
   * 缺失时回退一次性绑定的 rawUri（内存解析，绝不落盘），在加密层写入成功后即解除绑定。
   */
  async initNodes(nodes: ProxyNode[]): Promise<void> {
    if (this.credStore === null) {
      return;
    }
    const raw = await this.credStore.get('sealed_node_keys_json', '[]') as string;
    const sealed = new Set<string>();
    for (const k of SubscriptionService.readJsonStringArray(raw)) {
      sealed.add(k);
    }
    for (const n of nodes) {
      let uri = '';
      if (!sealed.has(nodeCredentialId(n))) {
        uri = await this.credStore.get(nodeUriKey(nodeCredentialId(n)), '') as string;
      }
      const fallback = SubscriptionService.parseFallbackCredentials(n, uri);
      const values = await CredentialStore.nodeCredentials(nodeCredentialId(n), fallback);
      n.password = values.password;
      n.uuid = values.uuid;
      n.protocolParam = values.protocolParam;
      n.obfsParam = values.obfsParam;
      if (uri.length > 0) {
        await this.markNodeSealed(nodeCredentialId(n), n, sealed);
      }
    }
    // 回填后审计：仍缺凭据的节点必须在 UI 可见（否则连接时生成配置会整批丢成空行）
    const dropStats = ClashConfigGenerator.countDroppedNodes(nodes);
    this.credentialMissingCount = dropStats.missingCredential;
    if (dropStats.missingCredential > 0) {
      AppLogger.warn(TAG,
        `${dropStats.missingCredential} node(s) still missing credentials after hydrate `
        + '(asset store unavailable or credential lost) — 连接时这些节点无法写入内核配置');
    }
  }

  /** 一次性回退源用完后移除 preferences 中的副本（Asset 已持有加密凭据） */
  private async markNodeSealed(nodeId: string, node: ProxyNode, sealed: Set<string>): Promise<void> {
    if (this.credStore === null) {
      return;
    }
    try {
      await this.credStore.delete(nodeUriKey(nodeId));
      sealed.add(nodeId);
      await this.credStore.put('sealed_node_keys_json', JSON.stringify(Array.from(sealed)));
      await this.credStore.flush();
    } catch (e) {
      AppLogger.warn(TAG, `sealed node record update failed: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  /**
   * 一次性回退源解析：优先 rawUri（历史版本持久化的原始节点链接），
   * 其次从节点自身字段（老版本明文，尚未被清扫时）还原。结果只驻留内存。
   */
  private static parseFallbackCredentials(n: ProxyNode, uri: string): NodeCredentialValues {
    const out = new NodeCredentialValues();
    out.password = n.password;
    out.uuid = n.uuid;
    out.protocolParam = n.protocolParam;
    out.obfsParam = n.obfsParam;
    if (uri.length === 0) {
      return out;
    }
    let parsed: ProxyNode | null = null;
    try {
      parsed = ProxyNode.fromUri(uri, n.subscriptionId, n.id);
    } catch (e) {
      AppLogger.warn(TAG, 'rawUri fallback parse failed');
      return out;
    }
    if (parsed === null) {
      return out;
    }
    if (parsed.password.length > 0) {
      out.password = parsed.password;
    }
    if (parsed.uuid.length > 0) {
      out.uuid = parsed.uuid;
    }
    if (parsed.protocolParam.length > 0) {
      out.protocolParam = parsed.protocolParam;
    }
    if (parsed.obfsParam.length > 0) {
      out.obfsParam = parsed.obfsParam;
    }
    return out;
  }

  /** 节点稳定指纹（跨刷新不变, 用于删除记忆）。name 用去重前的原始名, 与刷新解析结果一致 */
  static nodeKey(n: ProxyNode): string {
    return `${n.subscriptionId}|${n.server}|${n.port}|${SubscriptionService.baseName(n.name)}`;
  }

  /**
   * 去掉去重后缀, 还原节点原始名。
   * 两种历史形态都要剥: " #2"（ensureUniqueNames 旧形态）与 " (2)"（YamlMerger.uniqueProxyName
   * 形态, 现已统一为该形态）。只剥其中一种会让「改名后的节点」与加密层 alias / 隐藏清单失配 ——
   * 表现为凭据回填失败（生成配置时整条丢成空行）或已删节点刷新后复活。
   */
  private static baseName(name: string): string {
    return baseNodeName(name);
  }

  /**
   * 全局节点名去重: mihomo 对 proxies 段重名直接拒绝启动
   * ("parse config: proxy X is the duplicate name") —— 一个重名会让
   * 整个内核起不来, 所有节点都连不上。按列表顺序给重名节点追加
   * " #2/#3..." 后缀; UI/PROXY 组/内核配置/API 选节点共用此名, 天然一致。
   * 返回是否发生了改名。
   */
  ensureUniqueNames(): boolean {
    const used = new Set<string>();
    let changed = false;
    for (const n of this.nodes) {
      if (used.has(n.name)) {
        // 统一后缀形态为 "name (n)"（与 YamlMerger.uniqueProxyName 一致）,
        // 这样 nodeKey/baseName 只需要剥一种形态, 隐藏清单与加密层 alias 才稳定。
        const rawBase = SubscriptionService.baseName(n.name);
        const base = rawBase.length > 0 ? rawBase : (n.name.length > 0 ? n.name : 'node');
        let k = 2;
        while (used.has(`${base} (${k})`)) {
          k = k + 1;
        }
        n.name = `${base} (${k})`;
        changed = true;
      }
      used.add(n.name);
    }
    return changed;
  }

  /**
   * 删除单个节点（订阅页长按）: 从列表移除并记入隐藏清单,
   * 后续订阅刷新自动过滤; 手动直连节点同样支持（重新导入链接可再次添加）。
   */
  async removeNode(nodeId: string): Promise<boolean> {
    const n = this.findNode(nodeId);
    if (n === null) {
      return false;
    }
    const key = SubscriptionService.nodeKey(n);
    if (!this.hiddenNodes.includes(key)) {
      this.hiddenNodes.push(key);
    }
    this.nodes = this.nodes.filter((x) => x.id !== nodeId);
    const sub = this.subscriptions.find((s) => s.id === n.subscriptionId);
    if (sub !== undefined) {
      sub.nodeCount = this.nodesOf(sub.id).length;
    }
    await this.persist();
    AppLogger.info(TAG, `node removed: ${n.name} (hidden total ${this.hiddenNodes.length})`);
    return true;
  }

  private static validString(value: Object, maxLength: number, allowEmpty: boolean = true): boolean {
    return typeof value === 'string' && value.length <= maxLength && (allowEmpty || value.length > 0);
  }

  private static validInteger(value: Object, min: number, max: number): boolean {
    return typeof value === 'number' && Number.isInteger(value) && value >= min && value <= max;
  }

  private static validRefreshStatus(value: string): boolean {
    return value === '' || value === SubscriptionRefreshStatus.OK
      || value === SubscriptionRefreshStatus.NOT_MODIFIED
      || value === SubscriptionRefreshStatus.NETWORK_ERROR
      || value === SubscriptionRefreshStatus.HTTP_ERROR
      || value === SubscriptionRefreshStatus.EMPTY_RESPONSE
      || value === SubscriptionRefreshStatus.DECODE_ERROR
      || value === SubscriptionRefreshStatus.PARSE_ERROR
      || value === SubscriptionRefreshStatus.LIMIT_EXCEEDED
      || value === SubscriptionRefreshStatus.PERSIST_ERROR;
  }

  private static mapSubs(json: Object): Subscription[] {
    const out: Subscription[] = [];
    if (!Array.isArray(json)) {
      AppLogger.warn(TAG, 'subscriptions preferences root is not an array');
      return out;
    }
    let skipped = 0;
    for (const item of json as Object[]) {
      if (item === null || typeof item !== 'object') {
        skipped++;
        continue;
      }
      const j = item as SubscriptionJson;
      if (!SubscriptionService.validString(j.id, 256, false)
        || !SubscriptionService.validString(j.name, 4096)
        || !SubscriptionService.validString(j.url, 8192, false)
        || !SubscriptionService.validString(j.headerName, 256)
        || !SubscriptionService.validString(j.headerValue, 16 * 1024)
        || !SubscriptionService.validString(j.lastRefreshResult, 64)
        || !SubscriptionService.validRefreshStatus(j.lastRefreshResult)
        || !SubscriptionService.validInteger(j.lastFetchedAt, 0, Number.MAX_SAFE_INTEGER)
        || !SubscriptionService.validInteger(j.nodeCount, 0, 100000)
        || typeof j.enabled !== 'boolean'
        || !SubscriptionService.validInteger(j.sortOrder, 0, 100000)) {
        skipped++;
        continue;
      }
      // 双轨附加字段：非法值就地归一（旧存储无这些键），绝不因附加字段丢弃整条订阅
      if (typeof j.rawProviderState !== 'string' || !RawProviderStates.isValid(j.rawProviderState)) {
        j.rawProviderState = '';
      }
      if (typeof j.rawProviderNodeEstimate !== 'number'
        || !Number.isInteger(j.rawProviderNodeEstimate)
        || j.rawProviderNodeEstimate < 0 || j.rawProviderNodeEstimate > 100000) {
        j.rawProviderNodeEstimate = 0;
      }
      out.push(Subscription.fromPersistJson(j));
    }
    if (skipped > 0) {
      AppLogger.warn(TAG, `ignored ${skipped} invalid subscription records`);
    }
    return out;
  }

  /** 追加一条无效原因明细（去重、最多 3 条、';' 分隔）；只做明细，不做计数 */
  private static appendInvalidReason(d: SubscriptionImportDiagnostics, reason: string): void {
    const text = reason.trim();
    if (text.length === 0) {
      return;
    }
    if (d.invalidReasons.length === 0) {
      d.invalidReasons = text;
      return;
    }
    const parts = d.invalidReasons.split(';');
    if (parts.length >= 3) {
      return;
    }
    for (const it of parts) {
      if (it === text) {
        return;
      }
    }
    d.invalidReasons = `${d.invalidReasons};${text}`;
  }

  /**
   * 把「无效 / 缺字段条目」的原因计入诊断：invalidCount 自增，并把原因追加进
   * invalidReasons（最多 3 条、去重、';' 分隔）。d 为 undefined（调用方没有诊断
   * 对象）时只返回，不抛错 —— 三入口统一走这里，避免任何静默丢弃。
   *
   * 注：参数写成 `d: SubscriptionImportDiagnostics | undefined` 而不是 `d?:`，
   * 因为 TS/ArkTS 不允许「必选参数跟在可选参数之后」（TS1016）。
   */
  private static noteInvalid(d: SubscriptionImportDiagnostics | undefined, reason: string): void {
    if (d === undefined) {
      return;
    }
    d.invalidCount = d.invalidCount + 1;
    SubscriptionService.appendInvalidReason(d, reason);
  }

  /**
   * 批量登记无效条目：invalidCount 一次加 count，只追加一条汇总原因。
   * 用于 YamlMerger 这类上游（它只给「失败条数 + 明细」）。
   */
  private static noteInvalidBulk(d: SubscriptionImportDiagnostics | undefined,
    count: number, reason: string): void {
    if (d === undefined || count <= 0) {
      return;
    }
    d.invalidCount = d.invalidCount + count;
    SubscriptionService.appendInvalidReason(d, reason);
  }

  /** 把 YamlMerger 的跳过/无效统计并入统一诊断（不再只写日志） */
  private static absorbYamlMergeStats(d: SubscriptionImportDiagnostics): void {
    if (YamlMerger.lastSkippedCount > 0) {
      d.unsupportedCount = d.unsupportedCount + YamlMerger.lastSkippedCount;
      d.unsupportedTypes = SubscriptionService.mergeTypes(d.unsupportedTypes, YamlMerger.lastSkippedTypes);
    }
    if (YamlMerger.lastInvalidCount > 0) {
      const detail = YamlMerger.lastInvalidReasons.join('；');
      SubscriptionService.noteInvalidBulk(d, YamlMerger.lastInvalidCount,
        `YAML 节点无效 ${YamlMerger.lastInvalidCount} 条：`
        + `${detail.length > 0 ? detail : '字段缺失或格式错误'}`);
    }
  }

  /** 逗号分隔的类型清单合并（去重，保持原有顺序） */
  private static mergeTypes(current: string, extra: string): string {
    if (extra.length === 0) {
      return current;
    }
    if (current.length === 0) {
      return extra;
    }
    const seen = new Set<string>();
    const out: string[] = [];
    for (const raw of `${current},${extra}`.split(',')) {
      const t = raw.trim();
      if (t.length === 0 || seen.has(t)) {
        continue;
      }
      seen.add(t);
      out.push(t);
    }
    return out.join(',');
  }

  /** provider 拉取/解析失败明细（去重、最多 3 条、';' 分隔） */
  private static appendProviderFailure(d: SubscriptionImportDiagnostics, reason: string): void {
    const text = reason.trim();
    if (text.length === 0) {
      return;
    }
    if (d.providerFailureReasons.length === 0) {
      d.providerFailureReasons = text;
      return;
    }
    const parts = d.providerFailureReasons.split(';');
    if (parts.length >= 3) {
      return;
    }
    for (const it of parts) {
      if (it === text) {
        return;
      }
    }
    d.providerFailureReasons = `${d.providerFailureReasons};${text}`;
  }

  /** 统一异常文案（不输出 URL / 凭据，只输出错误消息） */
  private static describeError(e: Object): string {
    return e instanceof Error ? e.message : String(e);
  }

  /**
   * 生成配置阶段丢弃账本并入诊断：列表显示 N 个节点，内核实际可写入 N-configDroppedCount 个。
   * 导入后立即算一次，用户就能在导入提示里看到「列表有、内核无」的风险（而不是等到连接）。
   */
  private noteConfigDrops(d: SubscriptionImportDiagnostics): void {
    const dropStats = ClashConfigGenerator.countDroppedNodes(this.nodes);
    d.configDroppedCount = dropStats.dropped();
    d.configMissingCredentialCount = dropStats.missingCredential;
    if (dropStats.hasDrop()) {
      d.configDropReasons = dropStats.reasons();
    }
  }

  // ── 双轨（原始订阅 → 内核 file provider；开关默认关闭）──────────────────

  /** 追加一条双轨原因明细（去重、最多 3 条、'；' 分隔） */
  private static appendRawReason(d: SubscriptionImportDiagnostics, reason: string): void {
    const text = reason.trim();
    if (text.length === 0) {
      return;
    }
    if (d.rawProviderReasons.length === 0) {
      d.rawProviderReasons = text;
      return;
    }
    const parts = d.rawProviderReasons.split('；');
    if (parts.length >= 3) {
      return;
    }
    for (const it of parts) {
      if (it === text) {
        return;
      }
    }
    d.rawProviderReasons = `${d.rawProviderReasons}；${text}`;
  }

  /**
   * 双轨：把订阅原文落盘为内核 `type: file` provider。
   *
   * 铁律（与任务约束一致）：
   * - 开关关闭 → 什么都不做（且诊断文案为空，与现状完全一致）；
   * - 落盘失败 → 绝不抛出、绝不影响导入结果，只记诊断并降级为「仅解析链」；
   * - 原文不是 Clash YAML（内核 file provider 只认带 proxies 的 YAML / 代理列表）→
   *   标「不适用」并显式写进诊断，避免被误认为 provider 丢了节点。
   * 返回是否落盘成功。
   */
  private writeRawProvider(sub: Subscription, body: string, eligible: boolean,
    diagnostics: SubscriptionImportDiagnostics): boolean {
    diagnostics.rawProviderEnabled = RawSubscriptionStore.enabled;
    if (!RawSubscriptionStore.enabled) {
      return false;
    }
    if (!eligible) {
      diagnostics.rawProviderIneligible = diagnostics.rawProviderIneligible + 1;
      sub.rawProviderState = RawProviderStates.INELIGIBLE;
      sub.rawProviderNodeEstimate = 0;
      RawSubscriptionStore.drop(sub.id);
      SubscriptionService.appendRawReason(diagnostics,
        `${sub.name}：原文不是 Clash YAML（如 base64 链接列表），不能作为 file provider`);
      return false;
    }
    const result: RawWriteResult = RawSubscriptionStore.writeRaw(sub.id, body);
    if (!result.ok) {
      diagnostics.rawProviderFailed = diagnostics.rawProviderFailed + 1;
      sub.rawProviderState = RawProviderStates.FAILED;
      sub.rawProviderNodeEstimate = 0;
      RawSubscriptionStore.drop(sub.id);
      SubscriptionService.appendRawReason(diagnostics,
        `${sub.name}：原文落盘失败（${result.reason}），已降级为仅解析链`);
      AppLogger.warn(TAG, `raw provider write failed for ${sub.name}: ${result.reason}`);
      return false;
    }
    let estimate = 0;
    try {
      estimate = YamlMerger.proxyItemGroups(body).length;
    } catch (e) {
      estimate = 0;
    }
    diagnostics.rawProviderWritten = diagnostics.rawProviderWritten + 1;
    diagnostics.rawProviderNodeEstimate = diagnostics.rawProviderNodeEstimate + estimate;
    sub.rawProviderState = RawProviderStates.READY;
    sub.rawProviderNodeEstimate = estimate;
    this.registerRawProvider(sub.id, estimate);
    AppLogger.info(TAG, `raw provider written: ${sub.name} -> ${RawSubscriptionStore.fileNameFor(sub.id)}`
      + ` (${result.bytes} bytes, ${estimate} entries)`);
    return true;
  }

  /**
   * 双轨诊断汇总（「解析到 N / provider 读到 M」+ 生成配置时实际发出的 provider 条数）。
   * 「配置内 provider 条数」直接复用 ClashConfigGenerator.planRawProviders，与真正写进配置
   * 的逻辑同源，避免诊断与实际不一致。
   */
  private updateRawProviderSummary(diagnostics: SubscriptionImportDiagnostics): void {
    diagnostics.rawProviderEnabled = RawSubscriptionStore.enabled;
    const probe = new AppSettings();
    probe.useRawProviderConfig = RawSubscriptionStore.enabled;
    const plan = ClashConfigGenerator.planRawProviders(probe, this.nodes);
    diagnostics.rawProviderEmitted = plan.stats.emitted;
    if (!diagnostics.rawProviderEnabled) {
      this.lastRawProviderSummary = '双轨 provider 关闭（原文未落盘，配置与旧版一致）';
      RawSubscriptionStore.lastDiagnosticLine = this.lastRawProviderSummary;
      return;
    }
    let text = `${diagnostics.parsedVsProviderText()}；配置内 provider ${plan.stats.emitted} 条`
      + `（候选 ${plan.stats.candidates}，缺失文件 ${plan.stats.missingFiles}，无对应节点 ${plan.stats.orphaned}）`;
    if (diagnostics.rawProviderFailed > 0 || diagnostics.rawProviderIneligible > 0) {
      text += '；注意：部分订阅未落盘，见明细';
    }
    this.lastRawProviderSummary = text;
    RawSubscriptionStore.lastDiagnosticLine = text;
  }

  /**
   * 双轨开关切换（设置/诊断面板调用）：写盘由调用方（SettingsService）负责，
   * 这里负责落盘仓闸门 + 每订阅状态 + 文案。关闭时清理全部落盘原文并返回删除数。
   */
  async setRawProviderEnabled(enabled: boolean): Promise<number> {
    const removed = RawSubscriptionStore.setEnabled(enabled);
    let changed = false;
    for (const s of this.subscriptions) {
      if (s.id === DIRECT_GROUP_ID) {
        continue;
      }
      const exists = enabled ? RawSubscriptionStore.has(s.id) : false;
      const next = enabled
        ? (exists ? RawProviderStates.READY : RawProviderStates.MISSING)
        : RawProviderStates.OFF;
      const estimate = exists ? SubscriptionService.countRawEntries(s.id) : 0;
      if (s.rawProviderState !== next || s.rawProviderNodeEstimate !== estimate) {
        changed = true;
      }
      s.rawProviderState = next;
      s.rawProviderNodeEstimate = estimate;
      if (exists) {
        this.registerRawProvider(s.id, estimate);
      } else {
        RawSubscriptionStore.drop(s.id);
      }
    }
    if (changed) {
      try {
        await this.persist();
      } catch (e) {
        AppLogger.warn(TAG, `raw provider state persist failed: ${SubscriptionService.describeError(e)}`);
      }
    }
    this.lastRawProviderSummary = enabled
      ? '双轨 provider 已开启：下次刷新/连接起生效（原文按订阅 id 落盘，由内核自行解析）'
      : `双轨 provider 已关闭，已清理 ${removed} 个落盘文件（回到解析链单轨）`;
    this.lastRawProviderMessage = this.lastRawProviderSummary;
    AppLogger.info(TAG, this.lastRawProviderSummary);
    return removed;
  }

  /** 手动清理落盘原文（诊断面板入口）；节点列表不受影响 */
  async purgeRawProviders(): Promise<number> {
    const removed = RawSubscriptionStore.removeAll();
    let changed = false;
    for (const s of this.subscriptions) {
      if (s.id === DIRECT_GROUP_ID) {
        continue;
      }
      if (s.rawProviderState === RawProviderStates.READY) {
        s.rawProviderState = RawProviderStates.MISSING;
        s.rawProviderNodeEstimate = 0;
        changed = true;
      }
    }
    if (changed) {
      try {
        await this.persist();
      } catch (e) {
        AppLogger.warn(TAG, `raw provider purge persist failed: ${SubscriptionService.describeError(e)}`);
      }
    }
    this.lastRawProviderMessage = `已清理 ${removed} 个 provider 落盘文件（节点列表不受影响；刷新订阅可重新落盘）`;
    AppLogger.info(TAG, this.lastRawProviderMessage);
    return removed;
  }

  /** 订阅卡/诊断：单个订阅的双轨 provider 状态（节点永远不因 provider 缺失被删除） */
  rawProviderStatusFor(subscriptionId: string): RawProviderStatus {
    const sub = this.subscriptions.find((s) => s.id === subscriptionId);
    const state = sub === undefined ? '' : sub.rawProviderState;
    const status = RawSubscriptionStore.statusFor(subscriptionId, state);
    if (sub !== undefined && status.fileExists && sub.rawProviderNodeEstimate > 0) {
      // 以落库的估算值为准（registerRawProvider 与之一致）
      status.nodeEstimate = sub.rawProviderNodeEstimate;
    }
    return status;
  }

  /**
   * provider 内容按「普通订阅内容」解析：Clash YAML 走合并引擎，链接 / 整体 Base64
   * 走统一解析器，统计并入同一次导入的 diagnostics（来源标注为 provider）。
   */
  private static parseProviderBody(body: string, subscriptionId: string,
    providerLabel: string, diagnostics: SubscriptionImportDiagnostics): ProxyNode[] {
    YamlMerger.resetSkipStats();
    if (YamlMerger.proxyItemGroups(body).length > 0) {
      const merged: MergedProxy[] = YamlMerger.merge([body],
        providerLabel.length > 0 ? providerLabel : 'provider', '');
      SubscriptionService.absorbYamlMergeStats(diagnostics);
      const nodes = SubscriptionService.mergedToNodes(merged, subscriptionId, diagnostics);
      diagnostics.inputCount = diagnostics.inputCount + nodes.length + diagnostics.invalidCount
        + diagnostics.unsupportedCount;
      return nodes;
    }
    const parseResult = SubscriptionParser.parseDetailed(body, subscriptionId);
    diagnostics.inputCount = diagnostics.inputCount + parseResult.diagnostics.inputCount;
    diagnostics.duplicateCount = diagnostics.duplicateCount + parseResult.diagnostics.duplicateCount;
    if (parseResult.diagnostics.invalidCount > 0) {
      SubscriptionService.noteInvalidBulk(diagnostics, parseResult.diagnostics.invalidCount,
        `provider 无效链接 ${parseResult.diagnostics.invalidCount} 条`);
    }
    diagnostics.unsupportedCount = diagnostics.unsupportedCount + parseResult.diagnostics.unsupportedCount;
    diagnostics.unsupportedTypes = SubscriptionService.mergeTypes(diagnostics.unsupportedTypes,
      parseResult.diagnostics.unsupportedTypes);
    return parseResult.nodes;
  }

  /**
   * 合并结果 → 节点模型（仅映射白名单结构化字段，proxyType 保留真实类型）。
   * server/port 缺失的条目必须计数并回报（漏洞 E：此前是静默丢弃）。
   */
  private static mergedToNodes(merged: MergedProxy[], subscriptionId: string,
    diagnostics?: SubscriptionImportDiagnostics): ProxyNode[] {
    const out: ProxyNode[] = [];
    let counter = 0;
    let dropped = 0;
    for (const m of merged) {
      const n = new ProxyNode();
      n.id = `${subscriptionId}-m${counter++}`;
      n.subscriptionId = subscriptionId;
      n.name = m.name;
      // 合并引擎输出的即订阅原始名（yaml_cache 跨刷新保名），冻结给分组匹配用
      n.originalName = m.name;
      n.server = m.server;
      n.port = m.port;
      n.password = m.password;
      n.method = m.cipher;
      n.protocol = m.protocol;
      n.protocolParam = m.protocolParam;
      n.obfs = m.obfs;
      n.obfsParam = m.obfsParam;
      n.proxyType = m.type;
      n.uuid = m.uuid;
      n.alterId = m.alterId;
      n.udp = m.udp;
      n.network = m.network;
      n.tls = m.tls;
      n.servername = m.servername;
      n.skipCertVerify = m.skipCertVerify;
      n.flow = m.flow;
      n.clientFingerprint = m.clientFingerprint;
      n.realityPublicKey = m.realityPublicKey;
      n.realityShortId = m.realityShortId;
      n.wsPath = m.wsPath;
      n.wsHost = m.wsHost;
      n.grpcServiceName = m.grpcServiceName;
      n.hyUp = m.hyUp;
      n.hyDown = m.hyDown;
      n.alpnList = m.alpnList;
      n.extraOpts = m.extraOpts;
      n.rawYaml = '';
      if (m.type === 'ssr') {
        n.type = ProxyNodeType.SSR;
      } else if (m.type === 'ss') {
        n.type = ProxyNodeType.SS;
      } else {
        n.type = ProxyNodeType.UNKNOWN;
      }
      // direct 出站没有 server/port（mihomo 合法节点），不能按缺字段丢弃
      if ((n.server.length > 0 && n.port > 0) || n.proxyType === 'direct') {
        out.push(n);
      } else {
        dropped = dropped + 1;
      }
    }
    if (dropped > 0) {
      SubscriptionService.noteInvalid(diagnostics, `合并映射丢弃 ${dropped} 条（缺 server 或 port）`);
      AppLogger.warn(TAG, `mergedToNodes dropped ${dropped} node(s) without server/port`);
    }
    return out;
  }

  public static mapNodes(json: Object, diagnostics?: SubscriptionImportDiagnostics): ProxyNode[] {
    const out: ProxyNode[] = [];
    if (!Array.isArray(json)) {
      AppLogger.warn(TAG, 'nodes preferences root is not an array');
      SubscriptionService.noteInvalid(diagnostics, '节点存储根节点不是数组');
      return out;
    }
    let skipped = 0;
    for (const item of json as Object[]) {
      if (item === null || typeof item !== 'object') {
        skipped++;
        continue;
      }
      const j = item as ProxyNodeJson;
      // direct 出站允许 server 为空、port 为 0（mihomo 合法节点）
      const isDirect = j.proxyType === 'direct';
      const validType = j.type === 'ss' || j.type === 'ssr' || j.type === 'other';
      if (!SubscriptionService.validString(j.id, 256, false)
        || !SubscriptionService.validString(j.subscriptionId, 256, false)
        || !SubscriptionService.validString(j.name, 4096)
        || (!isDirect && (!SubscriptionService.validString(j.server, 4096, false)
          || !SubscriptionService.validInteger(j.port, 1, 65535)))
        || !SubscriptionService.validString(j.password, 64 * 1024)
        || !SubscriptionService.validString(j.method, 256)
        || !SubscriptionService.validString(j.protocol, 256)
        || !SubscriptionService.validString(j.protocolParam, 64 * 1024)
        || !SubscriptionService.validString(j.obfs, 256)
        || !SubscriptionService.validString(j.obfsParam, 64 * 1024)
        || !SubscriptionService.validString(j.type, 32, false)
        || !validType
        || !SubscriptionService.validString(j.proxyType, 64)
        || !SubscriptionService.validString(j.uuid, 4096)
        || !SubscriptionService.validInteger(j.alterId, 0, 2147483647)
        || typeof j.udp !== 'boolean'
        || !SubscriptionService.validString(j.network, 256)
        || typeof j.tls !== 'boolean'
        || !SubscriptionService.validString(j.servername, 4096)
        || typeof j.skipCertVerify !== 'boolean'
        || !SubscriptionService.validString(j.flow, 4096)
        || !SubscriptionService.validString(j.clientFingerprint, 256)
        || !SubscriptionService.validString(j.realityPublicKey, 4096)
        || !SubscriptionService.validString(j.realityShortId, 4096)
        || !SubscriptionService.validString(j.wsPath, 64 * 1024)
        || !SubscriptionService.validString(j.wsHost, 4096)
        || !SubscriptionService.validString(j.grpcServiceName, 64 * 1024)
        || (j.hyUp !== undefined && !SubscriptionService.validString(j.hyUp, 256))
        || (j.hyDown !== undefined && !SubscriptionService.validString(j.hyDown, 256))
        || (j.alpnList !== undefined && !SubscriptionService.validString(j.alpnList, 256))
        || (j.extraOpts !== undefined && !SubscriptionService.validString(j.extraOpts, 64 * 1024))
        || !SubscriptionService.validString(j.rawYaml, 128 * 1024)
        || !SubscriptionService.validString(j.rawUri, 128 * 1024)
        || (j.originalName !== undefined && !SubscriptionService.validString(j.originalName, 4096))) {
        skipped++;
        continue;
      }
      const n = new ProxyNode();
      n.id = j.id;
      n.subscriptionId = j.subscriptionId;
      n.name = j.name;
      // 旧存储没有 originalName 键：用剥掉历史唯一名后缀的显示名回填，
      // 保证升级后代理组成员（引用订阅原始名）仍能匹配到节点。
      n.originalName = j.originalName !== undefined
        ? j.originalName : SubscriptionService.baseName(j.name);
      n.server = j.server;
      n.port = j.port;
      n.password = j.password;
      n.method = j.method;
      n.protocol = j.protocol;
      n.protocolParam = j.protocolParam;
      n.obfs = j.obfs;
      n.obfsParam = j.obfsParam;
      n.type = j.type === 'ss' ? ProxyNodeType.SS : (j.type === 'ssr' ? ProxyNodeType.SSR : ProxyNodeType.UNKNOWN);
      n.proxyType = j.proxyType.length > 0 ? j.proxyType : j.type;
      n.uuid = j.uuid;
      n.alterId = j.alterId;
      n.udp = j.udp;
      n.network = j.network;
      n.tls = j.tls;
      n.servername = j.servername;
      n.skipCertVerify = j.skipCertVerify;
      n.flow = j.flow;
      n.clientFingerprint = j.clientFingerprint;
      n.realityPublicKey = j.realityPublicKey;
      n.realityShortId = j.realityShortId;
      n.wsPath = j.wsPath;
      n.wsHost = j.wsHost;
      n.grpcServiceName = j.grpcServiceName;
      n.hyUp = j.hyUp ?? '';
      n.hyDown = j.hyDown ?? '';
      n.alpnList = j.alpnList ?? '';
      n.extraOpts = j.extraOpts ?? '';
      n.rawYaml = '';
      n.rawUri = j.rawUri;
      out.push(n);
    }
    if (skipped > 0) {
      // 恢复阶段的丢弃必须计数并回报（此前只写日志，界面与诊断都无从得知）
      AppLogger.warn(TAG, `ignored ${skipped} invalid node records (restore stage)`);
      SubscriptionService.noteInvalidBulk(diagnostics, skipped,
        `恢复阶段丢弃 ${skipped} 条无效节点记录`);
    }
    return out;
  }

  /**
   * 持久化元数据 + 凭据。返回「写加密层失败的凭据字段数」（0=全部成功, -1=写入过程异常）,
   * 供导入诊断的 persistFailedCount 使用 —— 凭据没写进去必须让用户看到, 不能静默。
   */
  /** 恢复阶段的代理组校验：坏记录跳过（与 mapNodes 同口径），成员列表逐项过滤 */
  private static mapGroups(json: Object): ProxyGroup[] {
    const out: ProxyGroup[] = [];
    if (!Array.isArray(json)) {
      AppLogger.warn(TAG, 'proxy groups preferences root is not an array');
      return out;
    }
    for (const item of json as Object[]) {
      if (item === null || typeof item !== 'object') {
        continue;
      }
      const j = item as ProxyGroupJson;
      if (!SubscriptionService.validString(j.subscriptionId, 256, false)
        || !SubscriptionService.validString(j.name, 4096, false)
        || !SubscriptionService.validString(j.groupType, 64)
        || !Array.isArray(j.members)) {
        continue;
      }
      const members: string[] = [];
      for (const m of j.members as Object[]) {
        if (typeof m === 'string' && m.length > 0 && m.length <= 4096) {
          members.push(m);
        }
      }
      const g = ProxyGroup.fromJson(j as ProxyGroupJson);
      g.members = members;
      out.push(g);
    }
    return out;
  }

  private async persist(): Promise<number> {
    if (this.store === null) {
      return 0;
    }
    // 凭据先写加密层（订阅 headerValue / 节点 rawUri 一次性绑定），再落元数据
    const credentialFailed = await this.storeCredentials();
    const subsJson: SubscriptionJson[] = [];
    for (const s of this.subscriptions) {
      subsJson.push(Subscription.toJson(s));
    }
    await this.store.put(KEY_SUBS, JSON.stringify(subsJson));
    await this.store.put(KEY_NODES, JSON.stringify(SubscriptionService.nodesToJson(this.nodes)));
    await this.store.put(KEY_HIDDEN, JSON.stringify(this.hiddenNodes));
    const groupsJson: ProxyGroupJson[] = [];
    for (const g of this.proxyGroups) {
      groupsJson.push(ProxyGroup.toJson(g));
    }
    await this.store.put(KEY_GROUPS, JSON.stringify(groupsJson));
    await this.store.flush();
    return credentialFailed;
  }

  /**
   * 敏感凭据落盘（透明写入路径）：节点凭据写 AssetStore；
   * 订阅 headerValue 同样入加密层，另存一次性绑定 rawUri 以便 Asset 缺失时回退。
   * Asset 不可用时绝不写明文，仅记录告警（元数据仍可正常持久化）。
   * 返回失败字段数（Asset 整体不可用时按节点数计, 确保上层诊断为非零）。
   */
  private async storeCredentials(): Promise<number> {
    if (this.credStore === null) {
      return 0;
    }
    let failed = 0;
    try {
      const report = await CredentialStore.canonicalize(this.nodes, this.subscriptionCredentialSources(), false);
      failed = report.failed;
      if (report.storeUnavailable) {
        // 加密层整体不可用：绝不写明文, 但凭据确实没有落盘, 必须计入诊断提示用户
        failed = failed + this.nodes.length;
        AppLogger.warn(TAG,
          'credential store unavailable: node credentials were not persisted (plaintext metadata kept, no plaintext credential file written)');
      }
    } catch (e) {
      AppLogger.warn(TAG, `credential store write aborted: ${e instanceof Error ? e.message : String(e)}`);
      return -1;
    }
    const sealed = new Set<string>();
    const rawSealed = await this.credStore.get('sealed_node_keys_json', '[]') as string;
    for (const k of SubscriptionService.readJsonStringArray(rawSealed)) {
      sealed.add(k);
    }
    for (const n of this.nodes) {
      const id = nodeCredentialId(n);
      if (sealed.has(id) || n.rawUri.length === 0) {
        continue;
      }
      n.rawYaml = '';
      await this.credStore.put(nodeUriKey(id), n.rawUri);
    }
    await this.credStore.flush();
    return failed;
  }

  private subscriptionCredentialSources(): SubscriptionCredentialSource[] {
    const out: SubscriptionCredentialSource[] = [];
    for (const s of this.subscriptions) {
      if (s.headerValue.length === 0) {
        continue;
      }
      const src = new SubscriptionCredentialSource();
      src.id = s.id;
      src.headerValue = s.headerValue;
      out.push(src);
    }
    return out;
  }

  private static nodesToJson(nodes: ProxyNode[]): ProxyNodeJson[] {
    const out: ProxyNodeJson[] = [];
    for (const n of nodes) {
      out.push(ProxyNodeJson.fromNode(n));
    }
    return out;
  }

  async addSubscription(name: string, url: string, headerName: string, headerValue: string): Promise<Subscription> {
    const s = Subscription.newSubscription(util.generateRandomUUID(), name, url);
    s.headerName = headerName;
    s.headerValue = headerValue;
    s.sortOrder = this.subscriptions.length;
    this.subscriptions.push(s);
    await this.persist();
    AppLogger.info(TAG, `subscription added: ${s.name}`);
    return s;
  }

  async removeSubscription(id: string): Promise<void> {
    if (id === DIRECT_GROUP_ID) {
      return;
    }
    // 双轨：删除订阅前先取出落盘原文（撤销窗口内可回写），随后立即删文件
    const rawBody = RawSubscriptionStore.readRaw(id);
    // 事务化快照以支持撤销
    this.undoSnapshot = new SubscriptionUndoSnapshot(this.subscriptions.slice(), this.nodes.slice(),
      id, rawBody, this.proxyGroups.filter((g) => g.subscriptionId === id));
    this.subscriptions = this.subscriptions.filter((s) => s.id !== id);
    this.nodes = this.nodes.filter((n) => n.subscriptionId !== id);
    this.proxyGroups = this.proxyGroups.filter((g) => g.subscriptionId !== id);
    // 「不再需要即删干净」：删订阅即删其 provider 落盘原文与登记项
    RawSubscriptionStore.remove(id);
    await this.persist();
  }

  async undoRemove(): Promise<boolean> {
    if (this.undoSnapshot === null) {
      return false;
    }
    const snapshot = this.undoSnapshot;
    this.subscriptions = this.undoSnapshot.subs;
    this.nodes = this.undoSnapshot.nodes;
    this.proxyGroups = this.proxyGroups.filter((g) => g.subscriptionId !== snapshot.rawSubscriptionId)
      .concat(snapshot.proxyGroups);
    this.undoSnapshot = null;
    if (snapshot.rawSubscriptionId.length > 0 && snapshot.rawBody.length > 0
      && RawSubscriptionStore.enabled) {
      const restored = RawSubscriptionStore.writeRaw(snapshot.rawSubscriptionId, snapshot.rawBody);
      const sub = this.subscriptions.find((s) => s.id === snapshot.rawSubscriptionId);
      if (sub !== undefined) {
        if (restored.ok) {
          const estimate = SubscriptionService.countRawEntries(sub.id);
          sub.rawProviderState = RawProviderStates.READY;
          sub.rawProviderNodeEstimate = estimate;
          this.registerRawProvider(sub.id, estimate);
        } else {
          sub.rawProviderState = RawProviderStates.FAILED;
          sub.rawProviderNodeEstimate = 0;
          AppLogger.warn(TAG, `raw provider restore failed after undo: ${restored.reason}`);
        }
      }
    }
    await this.persist();
    return true;
  }

  /**
   * 并发阶段（纯网络 I/O）：只做单条订阅的拉取，结果暂存到 prefetchCache。
   * **不改任何共享状态**（不碰 this.nodes / 订阅统计 / preferences / YamlMerger 静态状态），
   * 所以多条订阅同时预取不会互相覆盖。失败（含 429/403）也存进缓存，交给串行阶段复用
   * **同一条**错误 —— 不重试、不对同一面板再打一次请求（限流风暴的主要来源）。
   */
  async prefetchSubscription(id: string): Promise<RefreshPrepOutcome> {
    const sub = this.subscriptions.find((s) => s.id === id);
    if (sub === undefined) {
      return RefreshPrepOutcome.skipped(id);
    }
    if (sub.url.startsWith('local://')) {
      // 本地 YAML 伪订阅没有网络源：串行阶段按既有语义以现有节点数报成功，这里不预取
      return RefreshPrepOutcome.skipped(id);
    }
    if (!SubscriptionFetchPolicy.isValidSubscriptionUrl(sub.url, false)) {
      // 地址非法交给串行阶段按原样报错（提示文案与单条刷新逐字一致），这里不预取
      return RefreshPrepOutcome.skipped(id);
    }
    try {
      const fetched = await SubscriptionFetchPolicy.fetch(sub.url, sub.headerName, sub.headerValue);
      this.prefetchCache.set(id,
        PrefetchedSubscription.body(sub.url, sub.headerName, sub.headerValue, fetched));
      return RefreshPrepOutcome.prefetched(id);
    } catch (e) {
      if (e instanceof SubscriptionFetchError) {
        this.prefetchCache.set(id,
          PrefetchedSubscription.failure(sub.url, sub.headerName, sub.headerValue, e));
        AppLogger.warn(TAG, `prefetch ${id} failed: ${e.message}`);
        return RefreshPrepOutcome.failed(id, e.message, e.isRateLimited());
      }
      const message = SubscriptionService.describeError(e);
      AppLogger.warn(TAG, `prefetch ${id} failed: ${message}`);
      return RefreshPrepOutcome.unexpected(id, message);
    }
  }

  /**
   * 取走某条订阅的预取结果（取走即删）。
   * 只有 url / 自定义 UA 与当前订阅完全一致、且未过期才复用：
   * 批次中断后残留的旧内容宁可丢掉重拉，也绝不能写错数据。
   */
  private takePrefetch(sub: Subscription): PrefetchedSubscription {
    const miss = new PrefetchedSubscription();
    if (!this.prefetchCache.has(sub.id)) {
      return miss;
    }
    const cached = this.prefetchCache.get(sub.id) as PrefetchedSubscription;
    this.prefetchCache.delete(sub.id);
    if (cached.url !== sub.url || cached.headerName !== sub.headerName) {
      return miss;
    }
    if (cached.headerValue !== sub.headerValue) {
      return miss;
    }
    if (Date.now() - cached.at > PREFETCH_TTL_MS) {
      return miss;
    }
    return cached;
  }

  /**
   * 「全部刷新」（订阅页 refreshAll / 节点页 refreshNodes 共用）：有上限的并发批次。
   * 网络拉取并发（<= lanes 路，默认 ConcurrentRefresh.DEFAULT_LANES=4），
   * 解析 → 改内存 → 落盘 由 ConcurrentRefresh 串行保证：不丢节点、不丢订阅统计、
   * 不互相覆盖、单条失败不影响其它条。onProgress 每条完成后回调一次（串行、顺序确定），
   * 页面据此边到边刷 UI；shouldStop 返回 true 时不再启动新条目（在途条目仍会走完并落盘）。
   */
  async refreshSubscriptionsConcurrently(ids: string[], lanes: number,
    onProgress: (progress: RefreshBatchProgress, item: RefreshItemOutcome) => void,
    shouldStop: () => boolean): Promise<RefreshBatchSummary> {
    // 批次开始先清空可能残留的预取：上一次中断的批次不得影响这一次
    this.prefetchCache.clear();
    try {
      return await ConcurrentRefresh.run(ids, lanes,
        (id: string): Promise<RefreshPrepOutcome> => this.prefetchSubscription(id),
        (id: string): Promise<RefreshItemOutcome> => this.applyRefreshedSubscription(id),
        onProgress, shouldStop);
    } finally {
      // 批次结束不留任何 body / 错误残片（并发期的额外内存峰值 = lanes 份响应体）
      this.prefetchCache.clear();
    }
  }

  /** 串行阶段：走既有的 refreshSubscription（解析/合并/限流/诊断/落盘语义零改动） */
  private async applyRefreshedSubscription(id: string): Promise<RefreshItemOutcome> {
    const result = await this.refreshSubscription(id);
    const ok = result.status === SubscriptionRefreshStatus.OK
      || result.status === SubscriptionRefreshStatus.NOT_MODIFIED;
    if (ok) {
      return RefreshItemOutcome.success(id, result.nodeCount);
    }
    return RefreshItemOutcome.failure(id, result.message.length > 0 ? result.message : `${result.status}`,
      result.status === SubscriptionRefreshStatus.RATE_LIMITED);
  }

  async refreshSubscription(id: string): Promise<SubscriptionRefreshResult> {
    const sub = this.subscriptions.find((s) => s.id === id);
    if (sub === undefined) {
      return SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.HTTP_ERROR, 'subscription not found');
    }
    // 三入口统一诊断：本次刷新的所有计数（输入/成功/重复/无效/不支持/超限/持久化失败/配置丢弃）
    const diagnostics = new SubscriptionImportDiagnostics();
    this.lastImportDiagnostics = diagnostics;
    // 本地 YAML 导入的伪订阅: 刷新 = 从落盘原文重解析 + 重拉 providers（provider
    // 内容可能已更新，或上次导入时拉取失败——刷新就是重试入口），不是空转报成功。
    if (sub.url.startsWith('local://')) {
      return await this.refreshLocalSubscription(sub, diagnostics);
    }
    try {
      // 并发批次（refreshSubscriptionsConcurrently）已在网络阶段拉过这条订阅时直接复用：
      // 不重复打同一面板（429 风险），失败也复用**同一条**错误 → 状态分类 / 订阅状态落盘 /
      // 诊断与串行路径完全一致（下面统一 catch 里走 RATE_LIMITED 等既有分支）。
      const prefetched = this.takePrefetch(sub);
      if (prefetched.hit && prefetched.hasError) {
        throw prefetched.error;
      }
      const fetched: SubscriptionFetchResult = prefetched.hit
        ? prefetched.fetched
        : await SubscriptionFetchPolicy.fetch(sub.url, sub.headerName, sub.headerValue);
      const body = fetched.body;
      sub.uploadBytes = fetched.userInfo.uploadBytes;
      sub.downloadBytes = fetched.userInfo.downloadBytes;
      sub.totalBytes = fetched.userInfo.totalBytes;
      sub.expireAt = fetched.userInfo.expireAt;

      // 自动命名：订阅仍是默认名（"订阅 N"）时，从内容中提取机场名
      if (SubscriptionService.isDefaultName(sub.name)) {
        const detected = SubscriptionService.detectProviderName(body);
        if (detected.length > 0) {
          sub.name = detected;
          AppLogger.info(TAG, `auto-named subscription to "${detected}"`);
        }
      }

      let parsed: ProxyNode[];
      let parsedGroups: ProxyGroup[] = [];
      YamlMerger.resetSkipStats();
      const structuredYaml = YamlMerger.proxyItemGroups(body).length > 0;
      if (structuredYaml) {
        // Clash YAML 订阅：走合并引擎（跨刷新保留节点名称，限额与去重对齐 upstream）
        const prev = this.store !== null ? await this.store.get(`yaml_cache_${id}`, '') as string : '';
        let merged: MergedProxy[] = [];
        try {
          merged = YamlMerger.merge([body], sub.name, prev);
        } catch (mergeError) {
          if (mergeError instanceof YamlMergeError) {
            // 合并引擎限额（10k 节点 / 1000 来源 / 字段长度 / 单条大小）属「超限」，
            // 不能笼统报成解析失败：用户看到的应是「超限」而不是「内容坏了」。
            diagnostics.limitCount = diagnostics.limitCount + 1;
            SubscriptionService.appendInvalidReason(diagnostics, `合并超限：${mergeError.message}`);
            sub.lastRefreshResult = SubscriptionRefreshStatus.LIMIT_EXCEEDED;
            try {
              await this.persist();
            } catch (persistError) {
              return SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.PERSIST_ERROR,
                `节点超限状态保存失败：${SubscriptionService.describeError(persistError)}`, diagnostics);
            }
            return SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.LIMIT_EXCEEDED,
              `订阅内容超出合并限额：${mergeError.message}`, diagnostics);
          }
          throw mergeError as Error;
        }
        // 合并阶段被跳过的节点（不支持的协议类型）与逐条失败的原因并入同一次诊断
        SubscriptionService.absorbYamlMergeStats(diagnostics);
        parsed = SubscriptionService.mergedToNodes(merged, sub.id, diagnostics);
        parsedGroups = SubscriptionParser.parseProxyGroups(body, sub.id);
        diagnostics.inputCount = diagnostics.inputCount + parsed.length + diagnostics.invalidCount
          + diagnostics.unsupportedCount;
        if (this.store !== null) {
          // 缓存只保存白名单结构化节点的安全 YAML，禁止缓存或回放订阅原文。
          await this.store.put(`yaml_cache_${id}`, YamlMerger.toYaml(merged));
        }
      } else {
        const parseResult = SubscriptionParser.parseDetailed(body, sub.id);
        parsed = parseResult.nodes;
        parsedGroups = parseResult.groups;
        diagnostics.inputCount = diagnostics.inputCount + parseResult.diagnostics.inputCount;
        diagnostics.duplicateCount = diagnostics.duplicateCount + parseResult.diagnostics.duplicateCount;
        if (parseResult.diagnostics.invalidCount > 0) {
          SubscriptionService.noteInvalidBulk(diagnostics, parseResult.diagnostics.invalidCount,
            `无效链接 ${parseResult.diagnostics.invalidCount} 条`);
        }
        diagnostics.unsupportedCount = diagnostics.unsupportedCount + parseResult.diagnostics.unsupportedCount;
        diagnostics.unsupportedTypes = SubscriptionService.mergeTypes(diagnostics.unsupportedTypes,
          parseResult.diagnostics.unsupportedTypes);
      }
      if (YamlMerger.lastSkippedCount > 0) {
        // 不再静默丢弃: 记录被跳过的节点数与协议类型, 供诊断与界面提示
        AppLogger.warn(TAG, `subscription ${id} skipped ${YamlMerger.lastSkippedCount} node(s) `
          + `of unsupported type(s): ${YamlMerger.lastSkippedTypes}`);
      }

      // ---- proxy-providers：节点放在 provider 段而 proxies 为空的配置也必须导入 ----
      const providerEntries = ProxyProviderParser.parse(body);
      let providerImported = 0;
      if (providerEntries.length > 0) {
        const fetchable = ProxyProviderParser.fetchable(providerEntries);
        diagnostics.providerSkippedCount = providerEntries.length - fetchable.length;
        diagnostics.providerTypes = ProxyProviderParser.unsupportedTypes(providerEntries);
        if (diagnostics.providerSkippedCount > 0) {
          AppLogger.warn(TAG, `subscription ${id} has ${diagnostics.providerSkippedCount} proxy-provider(s) `
            + `of unsupported type(s): ${diagnostics.providerTypes}`);
        }
        const missingUrl = ProxyProviderParser.missingUrl(providerEntries);
        if (missingUrl > 0) {
          diagnostics.providerFailedCount = diagnostics.providerFailedCount + missingUrl;
          SubscriptionService.appendProviderFailure(diagnostics, `provider 缺少 url ${missingUrl} 个`);
        }
        for (let pi = 0; pi < fetchable.length; pi++) {
          const entry = fetchable[pi];
          try {
            // 与主订阅完全相同的 UA 降级链 / 重定向校验 / 大小上限
            const providerFetched = await SubscriptionFetchPolicy.fetch(
              entry.url, sub.headerName, sub.headerValue);
            const providerNodes = SubscriptionService.parseProviderBody(providerFetched.body, sub.id,
              entry.name, diagnostics);
            // 节点来源标注为 provider（id 前缀 -p 与主订阅条目区分，避免 id 冲突）
            for (let ni = 0; ni < providerNodes.length; ni++) {
              providerNodes[ni].id = `${sub.id}-p${pi}-${ni}`;
            }
            if (providerNodes.length > 0) {
              parsed = parsed.concat(providerNodes);
              providerImported = providerImported + providerNodes.length;
            }
          } catch (providerError) {
            diagnostics.providerFailedCount = diagnostics.providerFailedCount + 1;
            SubscriptionService.appendProviderFailure(diagnostics,
              `${entry.name.length > 0 ? entry.name : 'provider'}: `
              + `${SubscriptionService.describeError(providerError)}`);
            AppLogger.warn(TAG, `proxy-provider fetch/parse failed: `
              + `${SubscriptionService.describeError(providerError)}`);
          }
        }
        diagnostics.providerCount = providerImported;
        diagnostics.inputCount = diagnostics.inputCount + providerImported;
      }

      if (parsed.length === 0) {
        // HTTP 200 但 0 条目：与「响应为空」「内容无法识别」区分，且给出 provider 专用提示
        sub.lastRefreshResult = SubscriptionRefreshStatus.EMPTY_ENTRIES;
        let message = '内容未解析出节点（支持 ss/ssr/vless/vmess/trojan/hysteria2/tuic/hysteria '
          + '与 Clash YAML）';
        if (providerEntries.length > 0 && !structuredYaml) {
          message = providerImported > 0
            ? '配置未包含 proxies 节点，节点来自 proxy-providers'
            : '配置只有 proxy-providers 段且未导入任何节点（请检查 provider 类型 http/https 与链接可用性）';
        }
        try {
          await this.persist();
        } catch (persistError) {
          return SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.PERSIST_ERROR,
            `解析失败状态保存失败：${SubscriptionService.describeError(persistError)}`, diagnostics);
        }
        return SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.EMPTY_ENTRIES, message, diagnostics);
      }
      if (!SubscriptionFetchPolicy.isNodeCountAllowed(parsed.length)) {
        sub.lastRefreshResult = SubscriptionRefreshStatus.LIMIT_EXCEEDED;
        diagnostics.limitCount = diagnostics.limitCount + 1;
        SubscriptionService.appendInvalidReason(diagnostics, `节点数量 ${parsed.length} 超过 2000 上限`);
        try {
          await this.persist();
        } catch (persistError) {
          return SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.PERSIST_ERROR,
            `节点超限状态保存失败：${SubscriptionService.describeError(persistError)}`, diagnostics);
        }
        return SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.LIMIT_EXCEEDED,
          `节点数量 ${parsed.length} 超过 2000 个上限，未写入任何节点`, diagnostics);
      }
      // 用户手动删除过的节点: 刷新后不再复活
      if (this.hiddenNodes.length > 0) {
        const visible = parsed.filter((n) => !this.hiddenNodes.includes(SubscriptionService.nodeKey(n)));
        diagnostics.hiddenCount = parsed.length - visible.length;
        parsed = visible;
      }
      // 动态分组物化（include-all/filter/exclude-filter → members），再整体替换该订阅的组
      SubscriptionParser.materializeDynamicGroups(parsedGroups, parsed);
      this.proxyGroups = this.proxyGroups.filter((g) => g.subscriptionId !== id).concat(parsedGroups);
      this.nodes = this.nodes.filter((n) => n.subscriptionId !== id).concat(parsed);
      this.ensureUniqueNames();
      sub.nodeCount = parsed.length;
      sub.lastFetchedAt = Date.now();
      sub.lastRefreshResult = SubscriptionRefreshStatus.OK;
      diagnostics.addedCount = parsed.length;
      diagnostics.configMissingCredentialCount = this.credentialMissingCount;
      // ── 双轨：原始原文同步落盘（开关开启时才发生；失败自动降级为仅解析链）──
      this.writeRawProvider(sub, body, structuredYaml, diagnostics);
      this.updateRawProviderSummary(diagnostics);
      let credentialFailed = 0;
      try {
        credentialFailed = await this.persist();
      } catch (persistError) {
        sub.lastRefreshResult = SubscriptionRefreshStatus.PERSIST_ERROR;
        return SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.PERSIST_ERROR,
          `节点持久化失败：${SubscriptionService.describeError(persistError)}`, diagnostics);
      }
      if (credentialFailed > 0) {
        // 凭据写入加密层失败（异常或回读校验不一致）: 重启后这些节点可能缺凭据
        diagnostics.persistFailedCount = credentialFailed;
        AppLogger.warn(TAG, `subscription ${id} refreshed with ${credentialFailed} `
          + 'credential field(s) not persisted');
      }
      this.noteConfigDrops(diagnostics);
      return SubscriptionRefreshResult.ok(parsed.length, diagnostics);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      let status = SubscriptionRefreshStatus.PARSE_ERROR;
      if (e instanceof SubscriptionFetchError) {
        if (e.isRateLimited()) {
          // HTTP 429/403：面板限流/拒绝访问，与「地址写错」的用户提示完全不同
          status = SubscriptionRefreshStatus.RATE_LIMITED;
        } else if (e.kind === SubscriptionFetchErrorKind.HTTP) {
          status = SubscriptionRefreshStatus.HTTP_ERROR;
        } else if (e.kind === SubscriptionFetchErrorKind.EMPTY_RESPONSE) {
          status = SubscriptionRefreshStatus.EMPTY_RESPONSE;
        } else if (e.kind === SubscriptionFetchErrorKind.DECODE) {
          status = SubscriptionRefreshStatus.DECODE_ERROR;
        } else {
          status = SubscriptionRefreshStatus.NETWORK_ERROR;
        }
      }
      sub.lastRefreshResult = status;
      try {
        await this.persist();
      } catch (persistError) {
        return SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.PERSIST_ERROR,
          `刷新失败且状态持久化失败：${SubscriptionService.describeError(persistError)}`, diagnostics);
      }
      return SubscriptionRefreshResult.fail(status, msg, diagnostics);
    }
  }

  /**
   * 导入本地 YAML 文件（订阅页"导入文件"入口）: 建 local:// 伪订阅,
   * 复用与网络订阅完全相同的解析链（Clash YAML proxies / base64 链接列表 /
   * 明文链接行, 含 hysteria2 全协议）。返回导入节点数, 0=解析失败。
   */
  /**
   * 拉取并解析 provider 列表，把节点追加进 parsed（id 前缀 -p 与主条目区分）。
   * 单个 provider 失败只降级计数（静态节点仍在），绝不影响整份导入/刷新。
   * 导入与本地刷新共用；URL 订阅刷新路径保留原内联实现（带订阅级 header）。
   */
  private async appendProviderNodes(providerEntries: ProxyProviderEntry[], subscriptionId: string,
    headerName: string, headerValue: string, parsed: ProxyNode[],
    diagnostics: SubscriptionImportDiagnostics): Promise<number> {
    let providerImported = 0;
    const fetchable = ProxyProviderParser.fetchable(providerEntries);
    diagnostics.providerSkippedCount = diagnostics.providerSkippedCount
      + providerEntries.length - fetchable.length;
    diagnostics.providerTypes = SubscriptionService.mergeTypes(diagnostics.providerTypes,
      ProxyProviderParser.unsupportedTypes(providerEntries));
    const missingUrl = ProxyProviderParser.missingUrl(providerEntries);
    if (missingUrl > 0) {
      diagnostics.providerFailedCount = diagnostics.providerFailedCount + missingUrl;
      SubscriptionService.appendProviderFailure(diagnostics, `provider 缺少 url ${missingUrl} 个`);
    }
    for (let pi = 0; pi < fetchable.length; pi++) {
      const entry = fetchable[pi];
      try {
        const providerFetched = await SubscriptionFetchPolicy.fetch(entry.url, headerName, headerValue);
        const providerNodes = SubscriptionService.parseProviderBody(providerFetched.body, subscriptionId,
          entry.name, diagnostics);
        for (let ni = 0; ni < providerNodes.length; ni++) {
          providerNodes[ni].id = `${subscriptionId}-p${pi}-${ni}`;
        }
        for (const pn of providerNodes) {
          parsed.push(pn);
        }
        providerImported = providerImported + providerNodes.length;
      } catch (providerError) {
        diagnostics.providerFailedCount = diagnostics.providerFailedCount + 1;
        SubscriptionService.appendProviderFailure(diagnostics,
          `${entry.name.length > 0 ? entry.name : 'provider'}: `
          + `${SubscriptionService.describeError(providerError)}`);
        AppLogger.warn(TAG, `proxy-provider fetch/parse failed: `
          + `${SubscriptionService.describeError(providerError)}`);
      }
    }
    diagnostics.providerCount = diagnostics.providerCount + providerImported;
    diagnostics.inputCount = diagnostics.inputCount + providerImported;
    return providerImported;
  }

  /**
   * 本地 YAML 伪订阅的刷新：从落盘原文（双轨 raw，缺失时退 yaml_cache）重解析
   * 静态节点与分组，并**重拉 providers** —— 这是 provider 拉取失败后的重试入口，
   * 也让 provider 内容能随刷新更新（对齐 mihomo 的 interval 行为的用户侧等价物）。
   * 原文与缓存都缺失时保持旧行为（按现有节点数报成功，不动任何数据）。
   */
  private async refreshLocalSubscription(sub: Subscription,
    diagnostics: SubscriptionImportDiagnostics): Promise<SubscriptionRefreshResult> {
    const id = sub.id;
    const localCount = this.nodesOf(id).length;
    let body = RawSubscriptionStore.isReady() ? RawSubscriptionStore.readRaw(id) : '';
    if (body.length === 0 && this.store !== null) {
      try {
        body = await this.store.get(`yaml_cache_${id}`, '') as string;
      } catch (e) {
        body = '';
      }
    }
    if (body.trim().length === 0) {
      diagnostics.inputCount = localCount;
      diagnostics.addedCount = localCount;
      diagnostics.configMissingCredentialCount = this.credentialMissingCount;
      return SubscriptionRefreshResult.ok(localCount, diagnostics);
    }
    try {
      YamlMerger.resetSkipStats();
      let parsed: ProxyNode[];
      let parsedGroups: ProxyGroup[] = [];
      const structuredYaml = YamlMerger.proxyItemGroups(body).length > 0;
      if (structuredYaml) {
        const merged: MergedProxy[] = YamlMerger.merge([body], sub.name, '');
        SubscriptionService.absorbYamlMergeStats(diagnostics);
        parsed = SubscriptionService.mergedToNodes(merged, id, diagnostics);
        parsedGroups = SubscriptionParser.parseProxyGroups(body, id);
        diagnostics.inputCount = diagnostics.inputCount + parsed.length
          + diagnostics.invalidCount + diagnostics.unsupportedCount;
      } else {
        const parseResult = SubscriptionParser.parseDetailed(body, id);
        parsed = parseResult.nodes;
        parsedGroups = parseResult.groups;
        diagnostics.inputCount = diagnostics.inputCount + parseResult.diagnostics.inputCount;
        diagnostics.duplicateCount = diagnostics.duplicateCount + parseResult.diagnostics.duplicateCount;
        if (parseResult.diagnostics.invalidCount > 0) {
          SubscriptionService.noteInvalidBulk(diagnostics, parseResult.diagnostics.invalidCount,
            `无效链接 ${parseResult.diagnostics.invalidCount} 条`);
        }
        diagnostics.unsupportedCount = diagnostics.unsupportedCount + parseResult.diagnostics.unsupportedCount;
        diagnostics.unsupportedTypes = SubscriptionService.mergeTypes(diagnostics.unsupportedTypes,
          parseResult.diagnostics.unsupportedTypes);
      }
      const providerEntries = ProxyProviderParser.parse(body);
      if (providerEntries.length > 0) {
        const providerImported = await this.appendProviderNodes(providerEntries, id,
          '', '', parsed, diagnostics);
        AppLogger.info(TAG, `local refresh imported ${providerImported} provider node(s) `
          + `for subscription ${id}`);
      }
      if (parsed.length === 0) {
        sub.lastRefreshResult = SubscriptionRefreshStatus.EMPTY_ENTRIES;
        return SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.EMPTY_ENTRIES,
          '重解析未得到节点（原文件内容可能已变化）', diagnostics);
      }
      if (!SubscriptionFetchPolicy.isNodeCountAllowed(parsed.length)) {
        sub.lastRefreshResult = SubscriptionRefreshStatus.LIMIT_EXCEEDED;
        diagnostics.limitCount = diagnostics.limitCount + 1;
        SubscriptionService.appendInvalidReason(diagnostics, `节点数量 ${parsed.length} 超过 2000 上限`);
        return SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.LIMIT_EXCEEDED,
          `节点数量 ${parsed.length} 超过 2000 个上限，未写入任何节点`, diagnostics);
      }
      if (this.hiddenNodes.length > 0) {
        parsed = parsed.filter((n) => !this.hiddenNodes.includes(SubscriptionService.nodeKey(n)));
      }
      SubscriptionParser.materializeDynamicGroups(parsedGroups, parsed);
      // 分组仅在有新解析结果时替换（yaml_cache 退路无组信息，不能因此清空既有组）
      if (parsedGroups.length > 0) {
        this.proxyGroups = this.proxyGroups.filter((g) => g.subscriptionId !== id).concat(parsedGroups);
      }
      this.nodes = this.nodes.filter((n) => n.subscriptionId !== id).concat(parsed);
      this.ensureUniqueNames();
      sub.nodeCount = parsed.length;
      sub.lastFetchedAt = Date.now();
      sub.lastRefreshResult = SubscriptionRefreshStatus.OK;
      diagnostics.addedCount = parsed.length;
      diagnostics.configMissingCredentialCount = this.credentialMissingCount;
      try {
        await this.persist();
      } catch (persistError) {
        sub.lastRefreshResult = SubscriptionRefreshStatus.PERSIST_ERROR;
        return SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.PERSIST_ERROR,
          `刷新结果持久化失败：${SubscriptionService.describeError(persistError)}`, diagnostics);
      }
      this.noteConfigDrops(diagnostics);
      AppLogger.info(TAG, `local subscription refreshed: ${sub.name} (${parsed.length} nodes, `
        + `${this.groupsOf(id).length} groups)`);
      return SubscriptionRefreshResult.ok(parsed.length, diagnostics);
    } catch (e) {
      sub.lastRefreshResult = SubscriptionRefreshStatus.PARSE_ERROR;
      return SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.PARSE_ERROR,
        SubscriptionService.describeError(e), diagnostics);
    }
  }

  async addLocalYaml(fileName: string, content: string): Promise<number> {
    // 三入口统一诊断：本地 YAML 与 URL 订阅 / 链接文本展示同一组指标
    const diagnostics = new SubscriptionImportDiagnostics();
    this.lastImportDiagnostics = diagnostics;
    const base = fileName.replace(/\.(ya?ml|txt)$/i, '');
    const trimmed = content.trim();
    if (trimmed.length === 0) {
      SubscriptionService.noteInvalid(diagnostics, '文件内容为空');
      return 0;
    }
    const sub = Subscription.newSubscription(util.generateRandomUUID(),
      `本地:${base.length > 0 ? base : '订阅'}`, `local://${base}`);
    sub.sortOrder = this.subscriptions.length;
    let parsed: ProxyNode[];
    let parsedGroups: ProxyGroup[] = [];
    /** 双轨：原文是否为 Clash YAML（决定能否作为内核 file provider 落盘） */
    let localEligible = false;
    try {
      YamlMerger.resetSkipStats();
      localEligible = YamlMerger.proxyItemGroups(trimmed).length > 0;
      if (localEligible) {
        const merged: MergedProxy[] = YamlMerger.merge([trimmed], sub.name, '');
        SubscriptionService.absorbYamlMergeStats(diagnostics);
        parsed = SubscriptionService.mergedToNodes(merged, sub.id, diagnostics);
        parsedGroups = SubscriptionParser.parseProxyGroups(trimmed, sub.id);
        diagnostics.inputCount = diagnostics.inputCount + parsed.length + diagnostics.invalidCount
          + diagnostics.unsupportedCount;
        if (this.store !== null) {
          await this.store.put(`yaml_cache_${sub.id}`, YamlMerger.toYaml(merged));
        }
      } else {
        const parseResult = SubscriptionParser.parseDetailed(trimmed, sub.id);
        parsed = parseResult.nodes;
        parsedGroups = parseResult.groups;
        diagnostics.inputCount = diagnostics.inputCount + parseResult.diagnostics.inputCount;
        diagnostics.duplicateCount = diagnostics.duplicateCount + parseResult.diagnostics.duplicateCount;
        if (parseResult.diagnostics.invalidCount > 0) {
          SubscriptionService.noteInvalidBulk(diagnostics, parseResult.diagnostics.invalidCount,
            `无效链接 ${parseResult.diagnostics.invalidCount} 条`);
        }
        diagnostics.unsupportedCount = diagnostics.unsupportedCount + parseResult.diagnostics.unsupportedCount;
        diagnostics.unsupportedTypes = SubscriptionService.mergeTypes(diagnostics.unsupportedTypes,
          parseResult.diagnostics.unsupportedTypes);
      }
      if (YamlMerger.lastSkippedCount > 0) {
        AppLogger.warn(TAG, `local yaml skipped ${YamlMerger.lastSkippedCount} node(s) `
          + `of unsupported type(s): ${YamlMerger.lastSkippedTypes}`);
      }

      // ---- proxy-providers：本地 YAML 的 provider 段同样拉取（对齐 mihomo 语义）----
      // mihomo 的 include-all/use 组包含 provider 节点；本地导入不拉取的话，
      // 「全部节点/国家组」与内核客户端（BettBox 等）的分组内容差距巨大。
      const providerEntries = ProxyProviderParser.parse(trimmed);
      if (providerEntries.length > 0) {
        const providerImported = await this.appendProviderNodes(providerEntries, sub.id,
          '', '', parsed, diagnostics);
        AppLogger.info(TAG, `local yaml imported ${providerImported} provider node(s) `
          + `from ${providerEntries.length} provider declaration(s)`);
      }
    } catch (e) {
      if (e instanceof YamlMergeError) {
        // 合并限额与解析失败分开：超限必须能被用户看见，而不是笼统「解析失败」
        diagnostics.limitCount = diagnostics.limitCount + 1;
        SubscriptionService.appendInvalidReason(diagnostics, `合并超限：${e.message}`);
      } else {
        SubscriptionService.noteInvalid(diagnostics, `解析异常：${SubscriptionService.describeError(e)}`);
      }
      AppLogger.warn(TAG, `local yaml parse failed: ${SubscriptionService.describeError(e)}`);
      return 0;
    }
    if (parsed.length === 0) {
      SubscriptionService.noteInvalid(diagnostics, '内容未解析出节点');
      return 0;
    }
    if (!SubscriptionFetchPolicy.isNodeCountAllowed(parsed.length)) {
      AppLogger.warn(TAG, `local import rejected: ${parsed.length} nodes exceed 2000 limit`);
      diagnostics.limitCount = diagnostics.limitCount + 1;
      SubscriptionService.appendInvalidReason(diagnostics, `节点数量 ${parsed.length} 超过 2000 上限`);
      return 0;
    }
    if (this.hiddenNodes.length > 0) {
      const visible = parsed.filter((n) => !this.hiddenNodes.includes(SubscriptionService.nodeKey(n)));
      diagnostics.hiddenCount = parsed.length - visible.length;
      parsed = visible;
    }
    // 动态分组物化后随本地导入一并入库
    SubscriptionParser.materializeDynamicGroups(parsedGroups, parsed);
    this.proxyGroups = this.proxyGroups.filter((g) => g.subscriptionId !== sub.id).concat(parsedGroups);
    this.subscriptions.push(sub);
    this.nodes = this.nodes.concat(parsed);
    this.ensureUniqueNames();
    sub.nodeCount = parsed.length;
    sub.lastFetchedAt = Date.now();
    sub.lastRefreshResult = SubscriptionRefreshStatus.OK;
    diagnostics.addedCount = parsed.length;
    diagnostics.configMissingCredentialCount = this.credentialMissingCount;
    // ── 双轨：本地导入的原文同样落盘作为 provider（开关开启时；失败自动降级）──
    this.writeRawProvider(sub, trimmed, localEligible, diagnostics);
    this.updateRawProviderSummary(diagnostics);
    let credentialFailed = 0;
    try {
      credentialFailed = await this.persist();
    } catch (e) {
      // 落盘异常不再只抛给页面（页面只会说「导入失败」），而是计入诊断的持久化失败
      diagnostics.persistFailedCount = this.nodes.length;
      AppLogger.warn(TAG, `local yaml persist failed: ${SubscriptionService.describeError(e)}`);
    }
    if (credentialFailed > 0 && diagnostics.persistFailedCount === 0) {
      diagnostics.persistFailedCount = credentialFailed;
    }
    this.noteConfigDrops(diagnostics);
    AppLogger.info(TAG, `local yaml imported: ${sub.name} (${parsed.length} nodes)`);
    return parsed.length;
  }

  nodesOf(subscriptionId: string): ProxyNode[] {
    return this.nodes.filter((n) => n.subscriptionId === subscriptionId);
  }

  /** 某订阅的全部代理组（保持声明顺序） */
  groupsOf(subscriptionId: string): ProxyGroup[] {
    return this.proxyGroups.filter((g) => g.subscriptionId === subscriptionId);
  }

  /**
   * 展开代理组成员为具体节点（Clash Meta 语义）：
   * - 成员先按「NFKC + 去 U+FE0F」归一再匹配（emoji 变体选择符/全半角兼容）；
   * - 命中节点（originalName 优先，其次显示名）→ 收入结果，按节点 id 去重；
   * - 命中同订阅嵌套组 → 递归展开（含环保护）；DIRECT/REJECT/GLOBAL、
   *   GEO/规则型成员无法映射为节点，直接跳过，绝不误配。
   */
  expandProxyGroup(group: ProxyGroup): ProxyNode[] {
    const out: ProxyNode[] = [];
    const seenNodeIds = new Set<string>();
    const visitedGroups = new Set<string>();
    SubscriptionService.expandGroupInto(group, this.proxyGroups, this.nodes, out, seenNodeIds, visitedGroups);
    return out;
  }

  private static expandGroupInto(group: ProxyGroup, allGroups: ProxyGroup[], nodes: ProxyNode[],
    out: ProxyNode[], seenNodeIds: Set<string>, visitedGroups: Set<string>): void {
    const groupKey = `${group.subscriptionId}\u0000${SubscriptionParser.normalizeGroupName(group.name)}`;
    if (visitedGroups.has(groupKey)) {
      return;
    }
    visitedGroups.add(groupKey);
    // originalName → 节点列表（一对多）：订阅里两个节点原名相同时，组成员引用该原名
    // 必须同时展开出两个节点（显示名已被去重改名，但原始声明只有一个名字）。
    const nodesByOriginal = new Map<string, ProxyNode[]>();
    const nodesByName = new Map<string, ProxyNode>();
    for (const n of nodes) {
      if (n.subscriptionId !== group.subscriptionId) {
        continue;
      }
      const original = n.originalName.length > 0 ? n.originalName : n.name;
      const oKey = SubscriptionParser.normalizeGroupName(original);
      const bucket = nodesByOriginal.get(oKey);
      if (bucket === undefined) {
        nodesByOriginal.set(oKey, [n]);
      } else {
        bucket.push(n);
      }
      const nKey = SubscriptionParser.normalizeGroupName(n.name);
      if (!nodesByName.has(nKey)) {
        nodesByName.set(nKey, n);
      }
    }
    const groupsByName = new Map<string, ProxyGroup>();
    for (const g of allGroups) {
      if (g.subscriptionId !== group.subscriptionId) {
        continue;
      }
      const key = SubscriptionParser.normalizeGroupName(g.name);
      if (!groupsByName.has(key)) {
        groupsByName.set(key, g);
      }
    }
    for (const member of group.members) {
      const key = SubscriptionParser.normalizeGroupName(member);
      if (SubscriptionService.isBuiltinGroupMember(key)) {
        continue;
      }
      const originals = nodesByOriginal.get(key);
      if (originals !== undefined) {
        for (const node of originals) {
          if (!seenNodeIds.has(node.id)) {
            seenNodeIds.add(node.id);
            out.push(node);
          }
        }
        continue;
      }
      const named = nodesByName.get(key);
      if (named !== undefined) {
        if (!seenNodeIds.has(named.id)) {
          seenNodeIds.add(named.id);
          out.push(named);
        }
        continue;
      }
      const nested = groupsByName.get(key);
      if (nested !== undefined) {
        SubscriptionService.expandGroupInto(nested, allGroups, nodes, out, seenNodeIds, visitedGroups);
      }
    }
  }

  /** DIRECT/REJECT/GLOBAL 等内置成员与通配规则成员不可展开为节点 */
  private static isBuiltinGroupMember(normalized: string): boolean {
    const v = normalized.toUpperCase();
    return v === 'DIRECT' || v === 'REJECT' || v === 'REJECT-DROP' || v === 'PASS'
      || v === 'GLOBAL' || v === 'COMPATIBLE';
  }

  /**
   * 组的**直接成员**视图（不递归，mihomo 客户端同款展示语义）：
   * 成员解析为节点（originalName 一对多）或嵌套组；DIRECT/REJECT 与
   * GEO/规则型成员忽略。嵌套组由调用方决定是否继续展开。
   */
  groupMembersOf(group: ProxyGroup): GroupMembers {
    const out = new GroupMembers();
    const seenNodeIds = new Set<string>();
    const seenGroupKeys = new Set<string>();
    const nodesByOriginal = new Map<string, ProxyNode[]>();
    const nodesByName = new Map<string, ProxyNode>();
    for (const n of this.nodes) {
      if (n.subscriptionId !== group.subscriptionId) {
        continue;
      }
      const original = n.originalName.length > 0 ? n.originalName : n.name;
      const oKey = SubscriptionParser.normalizeGroupName(original);
      const bucket = nodesByOriginal.get(oKey);
      if (bucket === undefined) {
        nodesByOriginal.set(oKey, [n]);
      } else {
        bucket.push(n);
      }
      const nKey = SubscriptionParser.normalizeGroupName(n.name);
      if (!nodesByName.has(nKey)) {
        nodesByName.set(nKey, n);
      }
    }
    const groupsByName = new Map<string, ProxyGroup>();
    for (const g of this.proxyGroups) {
      if (g.subscriptionId !== group.subscriptionId) {
        continue;
      }
      const key = SubscriptionParser.normalizeGroupName(g.name);
      if (!groupsByName.has(key)) {
        groupsByName.set(key, g);
      }
    }
    for (const member of group.members) {
      const key = SubscriptionParser.normalizeGroupName(member);
      if (SubscriptionService.isBuiltinGroupMember(key)) {
        continue;
      }
      const originals = nodesByOriginal.get(key);
      if (originals !== undefined) {
        for (const node of originals) {
          if (!seenNodeIds.has(node.id)) {
            seenNodeIds.add(node.id);
            out.nodes.push(node);
          }
        }
        continue;
      }
      const named = nodesByName.get(key);
      if (named !== undefined) {
        if (!seenNodeIds.has(named.id)) {
          seenNodeIds.add(named.id);
          out.nodes.push(named);
        }
        continue;
      }
      const nested = groupsByName.get(key);
      if (nested !== undefined) {
        const gKey = SubscriptionParser.normalizeGroupName(nested.name);
        if (!seenGroupKeys.has(gKey)) {
          seenGroupKeys.add(gKey);
          out.groups.push(nested);
        }
      }
    }
    return out;
  }

  findNode(id: string): ProxyNode | null {
    const n = this.nodes.find((x) => x.id === id);
    return n === undefined ? null : n;
  }

  /** 节点直链导入（对应 upstream SubscriptionAddStatus.singleNodeImported） */
  async addDirectNode(uri: string): Promise<number> {
    const diagnostics = new SubscriptionImportDiagnostics();
    this.lastImportDiagnostics = diagnostics;
    diagnostics.inputCount = 1;
    let node: ProxyNode | null = null;
    try {
      node = ProxyNode.fromUri(uri, DIRECT_GROUP_ID, util.generateRandomUUID());
    } catch (e) {
      SubscriptionService.noteInvalid(diagnostics, `链接解析异常：${SubscriptionService.describeError(e)}`);
      AppLogger.warn(TAG, `direct node parse failed: ${SubscriptionService.describeError(e)}`);
      return 0;
    }
    if (node === null) {
      SubscriptionService.noteInvalid(diagnostics, '链接无法解析为节点（协议不支持或字段缺失）');
      return 0;
    }
    const key = `${node.server}:${node.port}:${node.proxyType.length > 0 ? node.proxyType : node.type}`
      + `:${node.password}:${node.uuid}:${node.rawUri}`;
    const exists = this.nodes.some((n) => {
      const existingKey = `${n.server}:${n.port}:${n.proxyType.length > 0 ? n.proxyType : n.type}`
        + `:${n.password}:${n.uuid}:${n.rawUri}`;
      return existingKey === key;
    });
    if (exists) {
      diagnostics.duplicateCount = diagnostics.duplicateCount + 1;
      return -1;
    }
    this.nodes.push(node);
    this.ensureUniqueNames();
    const directGroup = this.subscriptions.find((s) => s.id === DIRECT_GROUP_ID);
    if (directGroup !== undefined) {
      directGroup.nodeCount = this.nodes.filter((n) => n.subscriptionId === DIRECT_GROUP_ID).length;
    }
    diagnostics.addedCount = 1;
    diagnostics.configMissingCredentialCount = this.credentialMissingCount;
    let credentialFailed = 0;
    try {
      credentialFailed = await this.persist();
    } catch (e) {
      diagnostics.persistFailedCount = this.nodes.length;
      AppLogger.warn(TAG, `direct node persist failed: ${SubscriptionService.describeError(e)}`);
    }
    if (credentialFailed > 0 && diagnostics.persistFailedCount === 0) {
      diagnostics.persistFailedCount = credentialFailed;
    }
    this.noteConfigDrops(diagnostics);
    return 1;
  }

  /** 更新订阅名称/URL（对应 upstream SubscriptionEditStatus.saved 持久化路径） */
  async updateSubscription(target: Subscription): Promise<void> {
    const index = this.subscriptions.findIndex((s) => s.id === target.id);
    if (index < 0) {
      return;
    }
    if (target.id === DIRECT_GROUP_ID) {
      target.url = DIRECT_GROUP_URL;
    }
    this.subscriptions[index] = target;
    await this.persist();
  }

  /** 判断是否为默认占位名（"订阅 N"） */
  static isDefaultName(name: string): boolean {
    return /^订阅\s*\d+$/.test(name.trim());
  }

  /**
   * 从订阅内容提取机场名（对齐常见订阅面板的 userinfo / 标题行约定）：
   * 1) Base64 整体解码后首行 `name=xxx` 或 `title=xxx`（V2Board 惯例）
   * 2) 解码后首行纯文本（非节点链接）视为品牌名，如 "吹雪云"
   * 3) Clash YAML 无用户信息头时返回 ''
   */
  static detectProviderName(body: string): string {
    let text = body;
    // 尝试整体 Base64 解码
    try {
      const cleaned = body.replace(/\s+/g, '');
      if (!/[:{]/.test(cleaned.substring(0, 200)) && /^[A-Za-z0-9+/=_-]+$/.test(cleaned)) {
        const decoded = SsrCodec.decodeBase64Url(cleaned);
        if (decoded.length > 0) {
          text = decoded;
        }
      }
    } catch (e) {
      // 保持原文
    }

    const lines = text.split(/\r?\n/).map((l) => l.trim()).filter((l) => l.length > 0);
    if (lines.length === 0) {
      return '';
    }
    // 跳过 YAML/节点链接内容找头部信息行
    for (const line of lines.slice(0, 5)) {
      if (line.startsWith('ssr://') || line.startsWith('ss://') || line.startsWith('vless://')
        || line.startsWith('vmess://') || line.startsWith('trojan://')) {
        break; // 直接是节点列表，无头部
      }
      // name=xxx / title=xxx（URL 编码的中文需解码）
      const kv = line.match(/^(?:name|title)=(.+)$/i);
      if (kv !== null) {
        let val = kv[1].trim();
        try {
          val = decodeURIComponent(val);
        } catch (e) {
          // 已是明文
        }
        if (val.length > 0 && val.length <= 60) {
          return val;
        }
      }
      // 纯文本首行（含中文/字母，不含 yaml 冒号结构）视为品牌名
      if (!line.includes('://') && !line.startsWith('{') && !line.startsWith('-')
        && !/^[\w-]+\s*:/.test(line) && /[A-Za-z\u4e00-\u9fa5]/.test(line) && line.length <= 60) {
        return line;
      }
      break; // 首行不匹配即停止（YAML 等格式）
    }
    return '';
  }

  /** 判断是否为节点直链（与 ProxyNode.fromUri 支持的 scheme 一致） */
  static isNodeUri(input: string): boolean {
    const t = input.trim();
    const m = t.match(/^([a-zA-Z][a-zA-Z0-9+.-]*):\/\//);
    return m !== null && ProxyNode.hasUriCodec(m[1]);
  }
}

/** 手工节点的独立持久化桶（对应 node_edit_screen 手工添加） */
export class ManualNodeStore {
  private static store: preferences.Preferences | null = null;
  private static credStore: preferences.Preferences | null = null;
  private static nodes: ProxyNode[] = [];
  private static listeners: (() => void)[] = [];

  static async init(context: Context): Promise<void> {
    ManualNodeStore.store = await preferences.getPreferences(context, PREF_NAME);
    if (ManualNodeStore.credStore === null) {
      ManualNodeStore.credStore = await preferences.getPreferences(context, CRED_PREF_NAME);
    }
    ManualNodeStore.nodes = [];
    try {
      const raw = await ManualNodeStore.store.get('manual_nodes_json', '[]') as string;
      ManualNodeStore.nodes = SubscriptionService.mapNodes(JSON.parse(raw) as Object);
    } catch (e) {
      AppLogger.warn(TAG, 'invalid manual nodes preferences ignored');
    }
    // 手工节点同样走凭据分离：迁移 → 加密回填 → 清扫明文 → 落库
    await ManualNodeStore.migrateCredentials();
    CredentialStore.canonicalizeNodes(ManualNodeStore.nodes, false)
      .catch((e: Object) => AppLogger.warn(TAG, `manual node credential sync failed: ${e instanceof Error ? e.message : String(e)}`));
  }

  /** 手工节点一次性迁移（与订阅节点同一套 Asset 键空间，幂等） */
  private static async migrateCredentials(): Promise<void> {
    if (ManualNodeStore.nodes.length === 0) {
      return;
    }
    const report = await CredentialStore.canonicalizeNodes(ManualNodeStore.nodes, !CredentialStore.isFirstRun());
    if (report.failed > 0) {
      AppLogger.warn(TAG, `manual node credential migration incomplete: ${report.failed} field(s) failed; plaintext preserved`);
      return;
    }
    // 全部回读校验通过 → 清明文并落库（凭据已只存在于 AssetStore）
    for (const n of ManualNodeStore.nodes) {
      n.password = '';
      n.uuid = '';
      n.protocolParam = '';
      n.obfsParam = '';
      n.rawYaml = '';
      n.rawUri = '';
    }
    await ManualNodeStore.persist();
  }

  static all(): ProxyNode[] {
    return ManualNodeStore.nodes;
  }

  static async addNode(node: ProxyNode): Promise<void> {
    ManualNodeStore.nodes.push(node);
    await ManualNodeStore.persist();
    for (const l of ManualNodeStore.listeners) {
      l();
    }
  }

  static addListener(listener: () => void): void {
    ManualNodeStore.listeners.push(listener);
  }

  private static async persist(): Promise<void> {
    if (ManualNodeStore.store === null) {
      return;
    }
    // 凭据先入加密层，元数据 JSON 里的敏感字段已在 fromNode 中恒为空
    const report = await CredentialStore.canonicalizeNodes(ManualNodeStore.nodes, false);
    const out: ProxyNodeJson[] = [];
    for (const n of ManualNodeStore.nodes) {
      out.push(ProxyNodeJson.fromNode(n));
    }
    await ManualNodeStore.store.put('manual_nodes_json', JSON.stringify(out));
    await ManualNodeStore.store.flush();
    if (report.failed > 0) {
      AppLogger.warn(TAG, `manual node credential store incomplete: ${report.failed} field(s)`);
    }
  }
}

/** 撤销快照（对应 subscription_undo_record.dart） */
/** 代理组的直接成员视图（groupMembersOf 返回值；不递归） */
export class GroupMembers {
  /** 可直接挂在本组下的节点（originalName 一对多，去重） */
  nodes: ProxyNode[] = [];
  /** 成员里引用的同订阅嵌套组（声明顺序） */
  groups: ProxyGroup[] = [];
}

export class SubscriptionUndoSnapshot {
  subs: Subscription[];
  nodes: ProxyNode[];
  /** 双轨：被删订阅 id 与其落盘原文（撤销时回写 provider 文件；空串 = 无） */
  rawSubscriptionId: string = '';
  rawBody: string = '';
  /** 被删订阅的代理组（撤销时一并恢复） */
  proxyGroups: ProxyGroup[];

  constructor(subs: Subscription[], nodes: ProxyNode[],
    rawSubscriptionId: string = '', rawBody: string = '', proxyGroups: ProxyGroup[] = []) {
    this.subs = subs;
    this.nodes = nodes;
    this.rawSubscriptionId = rawSubscriptionId;
    this.rawBody = rawBody;
    this.proxyGroups = proxyGroups;
  }
}

/** 持久化 JSON 形状（显式类，满足 arkts-no-untyped-obj-literals） */
export class ProxyNodeJson {
  id: string = '';
  subscriptionId: string = '';
  name: string = '';
  server: string = '';
  port: number = 0;
  password: string = '';
  method: string = '';
  protocol: string = '';
  protocolParam: string = '';
  obfs: string = '';
  obfsParam: string = '';
  type: string = 'ssr';
  proxyType: string = '';
  uuid: string = '';
  alterId: number = 0;
  udp: boolean = false;
  network: string = '';
  tls: boolean = false;
  servername: string = '';
  skipCertVerify: boolean = false;
  flow: string = '';
  clientFingerprint: string = '';
  realityPublicKey: string = '';
  realityShortId: string = '';
  wsPath: string = '';
  wsHost: string = '';
  grpcServiceName: string = '';
  /** hysteria2 扩展字段（可选: 旧存储无这些键, 读取端 ?? '' 兜底） */
  hyUp?: string;
  hyDown?: string;
  alpnList?: string;
  /** 结构化槽位之外的额外键值(JSON 数组)，旧存储无此键，读取端 ?? '' 兜底 */
  extraOpts?: string;
  /** 订阅原始节点名（旧存储无此键，读取端 ?? '' 兜底），代理组成员匹配依赖它 */
  originalName?: string;
  rawYaml: string = '';
  rawUri: string = '';

  static fromNode(n: ProxyNode): ProxyNodeJson {
    const j = new ProxyNodeJson();
    j.id = n.id;
    j.subscriptionId = n.subscriptionId;
    j.name = n.name;
    j.originalName = n.originalName;
    j.server = n.server;
    j.port = n.port;
    j.password = n.password;
    j.method = n.method;
    j.protocol = n.protocol;
    j.protocolParam = n.protocolParam;
    j.obfs = n.obfs;
    j.obfsParam = n.obfsParam;
    j.type = n.type === ProxyNodeType.SS ? 'ss' : (n.type === ProxyNodeType.SSR ? 'ssr' : 'other');
    j.proxyType = n.proxyType;
    j.uuid = n.uuid;
    j.alterId = n.alterId;
    j.udp = n.udp;
    j.network = n.network;
    j.tls = n.tls;
    j.servername = n.servername;
    j.skipCertVerify = n.skipCertVerify;
    j.flow = n.flow;
    j.clientFingerprint = n.clientFingerprint;
    j.realityPublicKey = n.realityPublicKey;
    j.realityShortId = n.realityShortId;
    j.wsPath = n.wsPath;
    j.wsHost = n.wsHost;
    j.grpcServiceName = n.grpcServiceName;
    j.hyUp = n.hyUp;
    j.hyDown = n.hyDown;
    j.alpnList = n.alpnList;
    j.extraOpts = n.extraOpts;
    j.rawYaml = '';
    j.rawUri = n.rawUri;
    return j;
  }
}

/** 持久化 JSON 形状 */
export class SubscriptionJson {
  id: string = '';
  name: string = '';
  url: string = '';
  headerName: string = '';
  headerValue: string = '';
  lastFetchedAt: number = 0;
  lastRefreshResult: string = '';
  nodeCount: number = 0;
  uploadBytes?: number;
  downloadBytes?: number;
  totalBytes?: number;
  expireAt?: number;
  enabled: boolean = true;
  sortOrder: number = 0;
  /** 双轨 provider 状态（见 Subscription.rawProviderState；旧存储无此键，读取端 ?? '' 兜底） */
  rawProviderState?: string;
  /** 双轨 provider 落盘原文条目估算（旧存储无此键，读取端 ?? 0 兜底） */
  rawProviderNodeEstimate?: number;
}
