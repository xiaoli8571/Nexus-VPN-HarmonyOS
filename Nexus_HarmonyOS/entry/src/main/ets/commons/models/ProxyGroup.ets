/**
 * Clash / Mihomo 代理分组领域模型。
 *
 * 仅保存订阅原始语义：所属订阅、组名、组类型及成员声明顺序。
 * 展开状态属于页面临时状态，不在此模型中持久化。
 *
 * 动态分组（include-all / filter / exclude-filter / include-all-proxies）
 * 在解析链拿到同订阅节点池后被「物化」进 members（见 SubscriptionParser
 * .materializeDynamicGroups）；dynamic 字段仅保留原始声明语义，供诊断与
 * 后续重算使用，物化结果不覆盖原始静态声明之外的顺序。
 */
export interface ProxyGroupJson {
  subscriptionId: string;
  name: string;
  groupType: string;
  members: string[];
  /** 可选：动态分组声明。旧持久化数据没有这些键，缺失即视为纯静态组。 */
  includeAll?: boolean;
  includeAllProxies?: boolean;
  filterPattern?: string;
  excludeFilterPattern?: string;
}

export class ProxyGroup {
  subscriptionId: string = '';
  name: string = '';
  groupType: string = '';
  members: string[] = [];
  /** include-all: true —— 成员为（过滤后的）全部节点 */
  includeAll: boolean = false;
  /** include-all-proxies: true —— 成员为全部静态 proxies（mihomo 扩展） */
  includeAllProxies: boolean = false;
  /** filter: "<regex>" —— 按节点名正则筛选 */
  filterPattern: string = '';
  /** exclude-filter: "<regex>" —— 按节点名正则剔除 */
  excludeFilterPattern: string = '';

  /** 是否声明了任何动态分组语法 */
  isDynamic(): boolean {
    return this.includeAll || this.includeAllProxies
      || this.filterPattern.length > 0 || this.excludeFilterPattern.length > 0;
  }

  static fromJson(value: ProxyGroupJson): ProxyGroup {
    const group = new ProxyGroup();
    group.subscriptionId = value.subscriptionId;
    group.name = value.name;
    group.groupType = value.groupType;
    group.members = value.members.slice();
    group.includeAll = value.includeAll === true;
    group.includeAllProxies = value.includeAllProxies === true;
    group.filterPattern = value.filterPattern !== undefined ? value.filterPattern : '';
    group.excludeFilterPattern = value.excludeFilterPattern !== undefined
      ? value.excludeFilterPattern : '';
    return group;
  }

  static toJson(group: ProxyGroup): ProxyGroupJson {
    const json: ProxyGroupJson = {
      subscriptionId: group.subscriptionId,
      name: group.name,
      groupType: group.groupType,
      members: group.members.slice()
    };
    // 纯静态组保持与旧版本完全相同的 JSON 形态（不新增键），减少持久化差异。
    if (group.includeAll) {
      json.includeAll = true;
    }
    if (group.includeAllProxies) {
      json.includeAllProxies = true;
    }
    if (group.filterPattern.length > 0) {
      json.filterPattern = group.filterPattern;
    }
    if (group.excludeFilterPattern.length > 0) {
      json.excludeFilterPattern = group.excludeFilterPattern;
    }
    return json;
  }
}
