/**
 * 数据模型：订阅
 * 移植自 upstream: packages/ssrvpn_shared/lib/models/subscription.dart
 */
import { SubscriptionJson } from '../services/SubscriptionService';

export class Subscription {
  id: string = '';
  name: string = '';
  url: string = '';
  /** 自定义请求头名（UA 协商时用户可覆盖默认 UA），对应 upstream subscription_header_name_parser */
  headerName: string = '';
  /**
   * 自定义请求头值（等价于订阅鉴权 token）：敏感凭据，只允许写入 AssetStore。
   * 该字段从不参与 preferences JSON 序列化（Subscription.toJson 恒写空串），
   * 仅在内存中持有；进程重启后由 CredentialStore 从加密层回填。
   */
  headerValue: string = '';
  /** 上次成功拉取的原始内容缓存 key（源缓存） */
  lastFetchedAt: number = 0;
  lastRefreshResult: string = '';
  nodeCount: number = 0;
  uploadBytes: number = -1;
  downloadBytes: number = -1;
  totalBytes: number = -1;
  expireAt: number = -1;
  enabled: boolean = true;
  sortOrder: number = 0;

  static newSubscription(id: string, name: string, url: string): Subscription {
    const s = new Subscription();
    s.id = id;
    s.name = name;
    s.url = url;
    return s;
  }

  static toJson(s: Subscription): SubscriptionJson {
    const j = new SubscriptionJson();
    j.id = s.id;
    j.name = s.name;
    j.url = s.url;
    j.headerName = s.headerName;
    // headerValue 属敏感凭据：永不写 preferences（加密层由 SubscriptionService.persist 负责）
    j.headerValue = '';
    j.lastFetchedAt = s.lastFetchedAt;
    j.lastRefreshResult = s.lastRefreshResult;
    j.nodeCount = s.nodeCount;
    j.uploadBytes = s.uploadBytes;
    j.downloadBytes = s.downloadBytes;
    j.totalBytes = s.totalBytes;
    j.expireAt = s.expireAt;
    j.enabled = s.enabled;
    j.sortOrder = s.sortOrder;
    return j;
  }

  static fromPersistJson(j: SubscriptionJson): Subscription {
    const s = new Subscription();
    s.id = j.id;
    s.name = j.name;
    s.url = j.url;
    s.headerName = j.headerName;
    s.headerValue = j.headerValue;
    s.lastFetchedAt = j.lastFetchedAt;
    s.lastRefreshResult = j.lastRefreshResult;
    s.nodeCount = j.nodeCount;
    s.uploadBytes = j.uploadBytes ?? -1;
    s.downloadBytes = j.downloadBytes ?? -1;
    s.totalBytes = j.totalBytes ?? -1;
    s.expireAt = j.expireAt ?? -1;
    s.enabled = j.enabled;
    s.sortOrder = j.sortOrder;
    return s;
  }
}

export enum SubscriptionRefreshStatus {
  OK = 'ok',
  NOT_MODIFIED = 'notModified',
  NETWORK_ERROR = 'networkError',
  HTTP_ERROR = 'httpError',
  EMPTY_RESPONSE = 'emptyResponse',
  DECODE_ERROR = 'decodeError',
  PARSE_ERROR = 'parseError',
  LIMIT_EXCEEDED = 'limitExceeded',
  PERSIST_ERROR = 'persistError',
  /**
   * 面板限流/拒绝（HTTP 429/403）。与 httpError 分开：摘要里必须能看出
   * 「是被限流」而不是「地址写错」。新增枚举值向后兼容（旧的 httpError 分支保留）。
   */
  RATE_LIMITED = 'rateLimited',
  /**
   * 拉取成功（HTTP 200、响应非空）但解析出 0 个条目。与 emptyResponse（响应体为空）
   * 和 parseError（内容无法识别）区分开，提示可能是面板按 UA 返回空列表。
   */
  EMPTY_ENTRIES = 'emptyEntries'
}

/** 三种导入入口共用的诊断统计，所有跳过原因均显式可见。 */
export class SubscriptionImportDiagnostics {
  inputCount: number = 0;
  addedCount: number = 0;
  duplicateCount: number = 0;
  invalidCount: number = 0;
  unsupportedCount: number = 0;
  hiddenCount: number = 0;
  limitCount: number = 0;
  unsupportedTypes: string = '';
  /** 无效/缺字段条目的原因摘要（最多 3 条，供界面直接展示，脱敏：只有原因文本） */
  invalidReasons: string = '';
  /** 敏感凭据写入加密层失败（回读校验不一致）的字段数：>0 表示重启后可能凭据缺失 */
  persistFailedCount: number = 0;
  /** 已导入但生成内核配置时被丢弃的节点数（列表有、内核无的显式计数） */
  configDroppedCount: number = 0;
  /** 上述丢弃中因 password/uuid/protocolParam/obfsParam 为空（凭据未回填）造成的数量 */
  configMissingCredentialCount: number = 0;
  /** 生成配置阶段丢弃原因明细（中文，供界面直接展示） */
  configDropReasons: string = '';
  /** 从 proxy-providers 成功导入的节点数（来源标注为 provider） */
  providerCount: number = 0;
  /** proxy-providers 中类型不支持而未能导入的 provider 数 */
  providerSkippedCount: number = 0;
  /** 不支持的 provider 类型清单（去重） */
  providerTypes: string = '';
  /** provider 拉取/解析失败的条数与明细（中文） */
  providerFailedCount: number = 0;
  providerFailureReasons: string = '';

  skippedCount(): number {
    return this.duplicateCount + this.invalidCount + this.unsupportedCount
      + this.hiddenCount + this.limitCount + this.providerSkippedCount;
  }

  /** 生成配置阶段丢弃总数（列表显示 N 个，内核实际只有 N-configDroppedCount 个） */
  kernelDroppedCount(): number {
    return this.configDroppedCount + this.providerFailedCount;
  }

  unsupportedDetail(): string {
    return this.unsupportedTypes.length > 0 ? `（${this.unsupportedTypes}）` : '';
  }

  providerDetail(): string {
    const bits: string[] = [];
    if (this.providerCount > 0) {
      bits.push(`导入 ${this.providerCount}`);
    }
    if (this.providerSkippedCount > 0) {
      bits.push(`不支持 ${this.providerSkippedCount}`
        + (this.providerTypes.length > 0 ? `（类型 ${this.providerTypes} 暂不支持）` : ''));
    }
    if (this.providerFailedCount > 0) {
      bits.push(`失败 ${this.providerFailedCount}`);
    }
    return bits.length > 0 ? `；proxy-providers ${bits.join('，')}` : '';
  }

  /**
   * 统一摘要：三种导入入口（URL 订阅 / 本地 YAML / 链接文本）都展示同一组指标，
   * 不再只报「获取到 N 个节点」。缺失项以 0 显式出现，便于用户/客服对账。
   */
  summary(): string {
    let text = `输入 ${this.inputCount}，成功 ${this.addedCount}，重复 ${this.duplicateCount}`
      + `，无效 ${this.invalidCount}，不支持 ${this.unsupportedCount}${this.unsupportedDetail()}`
      + `，超限 ${this.limitCount}，持久化失败 ${this.persistFailedCount}`
      + `，配置丢弃 ${this.configDroppedCount}`;
    if (this.hiddenCount > 0) {
      text += `，已隐藏 ${this.hiddenCount}`;
    }
    if (this.configMissingCredentialCount > 0) {
      text += `（其中凭据缺失 ${this.configMissingCredentialCount}）`;
    }
    if (this.configDropReasons.length > 0) {
      text += `〔${this.configDropReasons}〕`;
    }
    text += this.providerDetail();
    if (this.providerFailureReasons.length > 0) {
      text += `〔${this.providerFailureReasons}〕`;
    }
    return text;
  }
}

/** 刷新结果分类，移植自 subscription_refresh_result.dart */
export class SubscriptionRefreshResult {
  status: SubscriptionRefreshStatus = SubscriptionRefreshStatus.OK;
  message: string = '';
  nodeCount: number = 0;
  diagnostics: SubscriptionImportDiagnostics = new SubscriptionImportDiagnostics();

  static ok(nodeCount: number, diagnostics?: SubscriptionImportDiagnostics): SubscriptionRefreshResult {
    const r = new SubscriptionRefreshResult();
    r.status = SubscriptionRefreshStatus.OK;
    r.nodeCount = nodeCount;
    if (diagnostics !== undefined) {
      r.diagnostics = diagnostics;
    } else {
      r.diagnostics.addedCount = nodeCount;
    }
    return r;
  }

  static fail(status: SubscriptionRefreshStatus, message: string,
    diagnostics?: SubscriptionImportDiagnostics): SubscriptionRefreshResult {
    const r = new SubscriptionRefreshResult();
    r.status = status;
    r.message = message;
    if (diagnostics !== undefined) {
      r.diagnostics = diagnostics;
    }
    return r;
  }
}
