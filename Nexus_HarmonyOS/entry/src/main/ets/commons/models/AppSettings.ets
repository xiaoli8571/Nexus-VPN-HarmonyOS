/**
 * 数据模型：应用设置
 * 移植自 upstream: packages/ssrvpn_shared/lib/models/app_settings.dart
 * 字段与 upstream 保持一致；鸿蒙端持久化由 SettingsService（@ohos.data.preferences）承担。
 */
import { NodeSortModes } from '../services/NodeSortPersistence';
import { AppRoutingCustomApp, AppRoutingPolicy } from '../services/AppRoutingPolicy';

/** 自动选点模式（第二阶段新增，语义同 NodeSortModes 风格） */
export class AutoSelectModes {
  /** 手动：使用用户在上一次连接/偏好中固定的节点（默认） */
  static readonly MANUAL: string = 'manual';
  /** 自动：按 SmartSelector 评分自动选点，失败达阈值时自动切换 */
  static readonly AUTO: string = 'auto';

  /** 归一化任意输入为合法模式，未知/缺省值一律回退 MANUAL */
  static normalize(mode: string | undefined): string {
    if (mode === AutoSelectModes.AUTO) {
      return AutoSelectModes.AUTO;
    }
    return AutoSelectModes.MANUAL;
  }
}

/** 整数夹取：缺失/非法（非有限数）取默认值，越界夹到 [min,max] */
function clampInt(v: number, def: number, min: number, max: number): number {
  if (typeof v !== 'number' || !Number.isFinite(v)) {
    return def;
  }
  const i = Math.floor(v);
  if (i < min) {
    return min;
  }
  if (i > max) {
    return max;
  }
  return i;
}

/** 持久化 JSON 形状（显式类，满足 arkts-no-untyped-obj-literals） */
export class AppSettingsJson {
  themeMode: number = 0;
  autoConnectOnBoot: boolean = true;
  bypassDomesticApps: boolean = true;
  excludedApps: string[] = [];
  includedApps: string[] = [];
  /** 缺失值必须保持 undefined，不能让默认 all 遮蔽旧数据迁移。 */
  appRoutingMode: string | undefined = undefined;
  appRoutingNeedsReview: boolean = false;
  appRoutingCustomApps: AppRoutingCustomApp[] = [];
  forceProxySites: string[] = [];
  forceDirectSites: string[] = [];
  preferredNodeId: string = '';
  preferredNodeSubscriptionId: string = '';
  autoUpdateSubscription: boolean = true;
  selectedSubscriptionId: string = '';
  testLatencyUrl: string = 'https://www.gstatic.com/generate_204';
  proxyMode: string = 'rule';
  /** 节点列表排序模式: 'default' 订阅默认顺序 / 'auto' 按最近测速结果 / 'manual' 用户手动固定顺序 */
  nodeSortMode: string = 'default';
  /** 最近一次测速快照（JSON: NodeSortSnapshot），无测速数据为空串 */
  nodeSortSnapshot: string = '';
  /** 各订阅代理组当前策略选择（JSON 对象：稳定组键 -> 成员名）；旧配置缺失时为空串。 */
  proxyGroupSelections: string = '';
  // ── 第二阶段新增（旧版本配置缺这些字段时由 fromJson 取默认值） ──
  /** 网络类型变化时是否自动重连 */
  autoReconnectOnNetworkChange: boolean = true;
  /** 是否启用连续失败自动切换节点 */
  failoverEnabled: boolean = true;
  /** 触发切换的连续失败阈值（1..10） */
  failoverFailureThreshold: number = 3;
  /** 故障切换冷却秒数（0..3600） */
  failoverCooldownSec: number = 60;
  /** 自动选点模式：'manual'（默认，用户固定） / 'auto'（按评分自动选点） */
  autoSelectMode: string = 'manual';
  /** 是否启用链路自检与有限自动修复 */
  healthCheckEnabled: boolean = true;
  /** 自检后最多执行的修复步数（0..3） */
  healthRepairMaxSteps: number = 2;
  rulesEnabled: boolean = true;
  hyperAdRulesEnabled: boolean = true;
  customRules: string[] = [];
  /**
   * 「双轨」原始订阅 provider（实验开关，默认关闭）：
   * true = 除解析链外，另把每个订阅的**原文**落盘并在生成的 Mihomo 配置里以
   * `proxy-providers: {type: file}` 交给内核自己解析；false = 行为与现状完全一致。
   * 旧版本配置缺此字段时取默认 false。
   */
  useRawProviderConfig: boolean = false;
  /** 内核 smart 组 policy-priority（见 AppSettings.smartPolicyPriority）；旧配置缺失时为空串。 */
  smartPolicyPriority: string = '';
}

export class AppSettings {
  /** 跟随系统 / 暗色 / 亮色 */
  themeMode: number = 0; // 0=system, 1=dark, 2=light
  autoConnectOnBoot: boolean = true;
  bypassDomesticApps: boolean = true;
  excludedApps: string[] = [];
  /** 两份名单独立保留，只有 appRoutingMode 选中的一份参与运行。 */
  includedApps: string[] = [];
  appRoutingMode: string = 'all';
  /** 旧版双名单冲突/非法数据必须由 UI 保存确认，普通设置保存不得清除。 */
  appRoutingNeedsReview: boolean = false;
  appRoutingCustomApps: AppRoutingCustomApp[] = [];
  forceProxySites: string[] = [];
  /** 强制直连网站（始终 DIRECT, 不走代理） */
  forceDirectSites: string[] = [];
  preferredNodeId: string = '';
  preferredNodeSubscriptionId: string = '';
  autoUpdateSubscription: boolean = true;
  selectedSubscriptionId: string = '';
  testLatencyUrl: string = 'https://www.gstatic.com/generate_204';
  /** 代理模式：rule = 规则 / global = 全局（对应 upstream settings.proxyMode） */
  proxyMode: string = 'rule';
  /** 节点列表排序模式: 'default'=订阅默认顺序, 'auto'=按最近测速结果, 'manual'=手动固定顺序 */
  nodeSortMode: string = 'default';
  /** 最近一次测速快照序列化（NodeSortSnapshot JSON），无则空串。随设置一起落盘，
   *  使测速排序结果在退出页面/重启应用后仍然保持，直到用户重新测速才覆盖。 */
  nodeSortSnapshot: string = '';

  // ── 第二阶段新增设置 ────────────────────────────────────────────────
  /** 网络类型变化（含 none→有网恢复）时，若用户意图为已连接则自动退避重连。默认 true */
  autoReconnectOnNetworkChange: boolean = true;
  /** 是否启用「连续失败→自动切换节点」。默认 true */
  failoverEnabled: boolean = true;
  /** 触发自动切换的连续失败阈值，范围 1..10，默认 3 */
  failoverFailureThreshold: number = 3;
  /** 故障切换冷却秒数，范围 0..3600，默认 60（冷却期内禁止再次切换，防切换风暴） */
  failoverCooldownSec: number = 60;
  /** 自动选点模式：'manual'（默认，维持用户固定节点）/ 'auto'（按 SmartSelector 评分自动选点并允许切换） */
  autoSelectMode: string = 'manual';
  /** 是否启用链路自检与有限自动修复。默认 true */
  healthCheckEnabled: boolean = true;
  /** 自检后最多执行的修复步数，范围 0..3，默认 2 */
  healthRepairMaxSteps: number = 2;
  /** 是否启用规则功能；关闭后不生成广告规则和自定义规则。 */
  rulesEnabled: boolean = true;
  hyperAdRulesEnabled: boolean = true;
  customRules: string[] = [];
  /** 双轨原始订阅 provider 开关（默认关闭；见 AppSettings.useRawProviderConfig） */
  useRawProviderConfig: boolean = false;
  /** 各订阅代理组当前策略选择（JSON 对象：稳定组键 -> 成员名）。 */
  proxyGroupSelections: string = '';
  /**
   * 内核 smart 组的 `policy-priority`：按**节点名**给权重因子，格式 `模式:因子;模式:因子`。
   *
   * 这是 lux5am/mihomo-smart 独有的 fork 能力（mainline mihomo 没有 smart 组，更没有这个键）。
   * 语义见 `adapter/outboundgroup/smart.go`：因子**大于** LightGBM 评分的排序优先级 ——
   * 只要两个节点的因子不同，就按因子降序排，分数再高也翻不过来（`smart.go:580`）。
   * 模式支持子串匹配（默认）或正则；**首个命中的规则生效**；因子必须为正数，非法规则内核
   * 只告警并跳过，不会导致启动失败，所以坏配置是安全的。
   *
   * 默认空串 = 不生成该键，排序完全交给 LightGBM（与之前行为一致）。
   */
  smartPolicyPriority: string = '';

  toJson(): AppSettingsJson {
    const j = new AppSettingsJson();
    j.themeMode = this.themeMode;
    j.autoConnectOnBoot = this.autoConnectOnBoot;
    j.bypassDomesticApps = this.bypassDomesticApps;
    j.excludedApps = this.excludedApps;
    j.includedApps = this.includedApps;
    j.appRoutingMode = this.appRoutingMode;
    j.appRoutingNeedsReview = this.appRoutingNeedsReview;
    j.appRoutingCustomApps = this.appRoutingCustomApps;
    j.forceProxySites = this.forceProxySites;
    j.forceDirectSites = this.forceDirectSites;
    j.preferredNodeId = this.preferredNodeId;
    j.preferredNodeSubscriptionId = this.preferredNodeSubscriptionId;
    j.autoUpdateSubscription = this.autoUpdateSubscription;
    j.selectedSubscriptionId = this.selectedSubscriptionId;
    j.testLatencyUrl = this.testLatencyUrl;
    j.proxyMode = this.proxyMode;
    j.nodeSortMode = this.nodeSortMode;
    j.nodeSortSnapshot = this.nodeSortSnapshot;
    j.proxyGroupSelections = this.proxyGroupSelections;
    j.autoReconnectOnNetworkChange = this.autoReconnectOnNetworkChange;
    j.failoverEnabled = this.failoverEnabled;
    j.failoverFailureThreshold = this.failoverFailureThreshold;
    j.failoverCooldownSec = this.failoverCooldownSec;
    j.autoSelectMode = this.autoSelectMode;
    j.healthCheckEnabled = this.healthCheckEnabled;
    j.healthRepairMaxSteps = this.healthRepairMaxSteps;
    j.rulesEnabled = this.rulesEnabled;
    j.hyperAdRulesEnabled = this.hyperAdRulesEnabled;
    j.customRules = this.customRules;
    j.useRawProviderConfig = this.useRawProviderConfig;
    j.smartPolicyPriority = this.smartPolicyPriority;
    return j;
  }

  static fromJson(j: AppSettingsJson): AppSettings {
    const s = new AppSettings();
    s.themeMode = j.themeMode === 1 || j.themeMode === 2 ? j.themeMode : 0;
    s.autoConnectOnBoot = typeof j.autoConnectOnBoot === 'boolean' ? j.autoConnectOnBoot : true;
    s.bypassDomesticApps = typeof j.bypassDomesticApps === 'boolean' ? j.bypassDomesticApps : true;
    // 不能 filter 无效项：丢掉仅代理名单会扩大接管，丢掉绕过名单会改变用户边界。
    s.excludedApps = Array.isArray(j.excludedApps) ? AppRoutingPolicy.normalizePackages(j.excludedApps)
      : (j.excludedApps === undefined ? [] : ['[无效名单] ' + String(j.excludedApps)]);
    s.includedApps = Array.isArray(j.includedApps) ? AppRoutingPolicy.normalizePackages(j.includedApps)
      : (j.includedApps === undefined ? [] : ['[无效名单] ' + String(j.includedApps)]);
    const legacyRouting = j.appRoutingMode === undefined;
    s.appRoutingMode = legacyRouting ? AppRoutingPolicy.legacyMode(s.includedApps, s.excludedApps)
      : (typeof j.appRoutingMode === 'string' ? j.appRoutingMode : 'invalid');
    s.appRoutingNeedsReview = j.appRoutingNeedsReview === true ||
      (j.appRoutingNeedsReview !== undefined && typeof j.appRoutingNeedsReview !== 'boolean') ||
      (legacyRouting && s.includedApps.length > 0 && s.excludedApps.length > 0);
    if (AppRoutingPolicy.validationError(s.appRoutingMode, s.includedApps, s.excludedApps, false).length > 0) {
      s.appRoutingNeedsReview = true;
    }
    if (Array.isArray(j.appRoutingCustomApps)) {
      for (const item of j.appRoutingCustomApps) {
        if (item === null || typeof item !== 'object') {
          s.appRoutingNeedsReview = true;
          continue;
        }
        const custom = new AppRoutingCustomApp();
        custom.bundleName = typeof item.bundleName === 'string' ? item.bundleName.trim() : '[无效包名]';
        custom.label = typeof item.label === 'string' ? item.label.trim() : '';
        s.appRoutingCustomApps.push(custom);
      }
    }
    s.forceProxySites = Array.isArray(j.forceProxySites)
      ? j.forceProxySites.filter((v: string) => typeof v === 'string') : [];
    s.forceDirectSites = Array.isArray(j.forceDirectSites)
      ? j.forceDirectSites.filter((v: string) => typeof v === 'string') : [];
    s.preferredNodeId = typeof j.preferredNodeId === 'string' ? j.preferredNodeId : '';
    s.preferredNodeSubscriptionId = typeof j.preferredNodeSubscriptionId === 'string'
      ? j.preferredNodeSubscriptionId : '';
    s.autoUpdateSubscription = typeof j.autoUpdateSubscription === 'boolean' ? j.autoUpdateSubscription : true;
    s.selectedSubscriptionId = typeof j.selectedSubscriptionId === 'string' ? j.selectedSubscriptionId : '';
    s.testLatencyUrl = typeof j.testLatencyUrl === 'string' && j.testLatencyUrl.length > 0
      ? j.testLatencyUrl : 'https://www.gstatic.com/generate_204';
    s.proxyMode = j.proxyMode === 'global' ? 'global' : 'rule';
    s.nodeSortMode = NodeSortModes.normalize(j.nodeSortMode);
    s.nodeSortSnapshot = typeof j.nodeSortSnapshot === 'string' ? j.nodeSortSnapshot : '';
    s.proxyGroupSelections = typeof j.proxyGroupSelections === 'string' ? j.proxyGroupSelections : '';
    // 旧版本配置缺字段 → 取默认值；非法值 → 回落/夹取（加载不炸、保存幂等）
    s.autoReconnectOnNetworkChange = typeof j.autoReconnectOnNetworkChange === 'boolean'
      ? j.autoReconnectOnNetworkChange : true;
    s.failoverEnabled = typeof j.failoverEnabled === 'boolean' ? j.failoverEnabled : true;
    s.failoverFailureThreshold = clampInt(j.failoverFailureThreshold, 3, 1, 10);
    s.failoverCooldownSec = clampInt(j.failoverCooldownSec, 60, 0, 3600);
    s.autoSelectMode = AutoSelectModes.normalize(j.autoSelectMode);
    s.healthCheckEnabled = typeof j.healthCheckEnabled === 'boolean' ? j.healthCheckEnabled : true;
    s.healthRepairMaxSteps = clampInt(j.healthRepairMaxSteps, 2, 0, 3);
    s.rulesEnabled = typeof j.rulesEnabled === 'boolean' ? j.rulesEnabled : true;
    s.hyperAdRulesEnabled = typeof j.hyperAdRulesEnabled === 'boolean' ? j.hyperAdRulesEnabled : true;
    s.customRules = Array.isArray(j.customRules)
      ? j.customRules.filter((v: string) => typeof v === 'string').slice(0, 500) : [];
    // 双轨 provider 开关：缺字段/脏值一律回落 false（默认关闭 = 可一键回退的安全默认）
    s.useRawProviderConfig = typeof j.useRawProviderConfig === 'boolean' ? j.useRawProviderConfig : false;
    // policy-priority：缺字段/非字符串回落空串（=不生成该键，行为与旧版一致）。
    // 长度上限防止脏配置把生成的 YAML 撑爆；合法性（pattern:factor）交给内核判定，
    // 内核遇到非法规则只告警跳过，不会启动失败。
    s.smartPolicyPriority = typeof j.smartPolicyPriority === 'string'
      ? j.smartPolicyPriority.slice(0, 2000) : '';
    return s;
  }
}
