/**
 * Clash / Mihomo 配置生成器
 * 移植自 upstream: packages/ssrvpn_shared/lib/services/clash_config_generator.dart
 *
 * 关键约束（与 upstream 行为一致）：
 * - IPv4-only：DNS 不解析 AAAA，ipv6: false
 * - external-controller 仅绑定 127.0.0.1，secret 由调用方注入
 * - TUN 通过 VpnExtensionAbility 的 fd 注入，配置仅声明 tun.enable
 * - 国内直连规则 + 强制代理站点规则
 */
import { ProxyNode, ProxyNodeType } from '../models/ProxyNode';
import { ProxyGroup } from '../models/ProxyGroup';
import { AppSettings } from '../models/AppSettings';
import { YamlMerger } from './YamlMerger';
import { AppLogger } from '../utils/AppLogger';
import {
  RawProviderEntry, RawProviderPlan, RawProviderStats, RawSubscriptionStore,
  RAW_PROVIDER_HEALTH_CHECK_ENABLED, RAW_PROVIDER_HEALTH_CHECK_INTERVAL,
  RAW_PROVIDER_HEALTH_CHECK_URL, RAW_PROVIDER_PATH_MODE
} from './RawSubscriptionStore';

const TAG = 'ClashConfigGenerator';

/** 节点无法写入内核配置的原因（判定顺序与 proxyYamlLine 完全一致） */
export enum ProxyDropReason {
  NONE = 'none',
  /** 协议不在白名单（ss/ssr/vless/vmess/trojan/hysteria2/中继协议之外） */
  UNSUPPORTED_PROTOCOL = 'unsupportedProtocol',
  /** 字段含换行/NUL/超长：写进 YAML 会破坏配置结构 */
  UNSAFE_TEXT = 'unsafeText',
  /** 缺 name/server 或协议级必需字段（如 vless 的 uuid、ss 的 cipher） */
  MISSING_FIELD = 'missingField',
  /** 缺的正是凭据字段（password/uuid）—— 典型为加密层未回填 */
  MISSING_CREDENTIAL = 'missingCredential',
  /** 端口 <=0 或 >65535 */
  INVALID_PORT = 'invalidPort'
}

/**
 * 「列表有、内核无」的显式账本：生成配置时被 proxyYamlLine 判定为不可写入的
 * 节点数与原因分类。调用方（服务层/UI）据此提示用户，禁止静默丢成空行。
 */
export class ProxyDropStats {
  total: number = 0;
  kept: number = 0;
  unsupportedProtocol: number = 0;
  unsafeText: number = 0;
  /** 缺必需字段（含缺凭据） */
  missingFields: number = 0;
  invalidPort: number = 0;
  /** missingFields 中因 password/uuid 为空导致的数量（凭据未回填信号） */
  missingCredential: number = 0;
  /** 被丢弃节点名示例（最多 3 个，便于定位） */
  samples: string = '';

  dropped(): number {
    return this.unsupportedProtocol + this.unsafeText + this.missingFields + this.invalidPort;
  }

  hasDrop(): boolean {
    return this.dropped() > 0;
  }

  /** 原因分类明细（始终列出四项，0 也显示，避免「看起来没丢」的误判） */
  reasons(): string {
    let text = `协议不支持 ${this.unsupportedProtocol}，文本不安全 ${this.unsafeText}`
      + `，缺必需字段 ${this.missingFields}`;
    if (this.missingCredential > 0) {
      text += `（其中凭据缺失 ${this.missingCredential}）`;
    }
    text += `，端口非法 ${this.invalidPort}`;
    if (this.samples.length > 0) {
      text += `；示例：${this.samples}`;
    }
    return text;
  }

  summary(): string {
    return `列表 ${this.total} 个节点，可写入内核 ${this.kept} 个，丢弃 ${this.dropped()} 个（${this.reasons()}）`;
  }
}

export class ClashConfigGenerator {
  /** 最近一次生成的丢弃账本（UI/诊断可读取，即使调用方忽略返回值也不丢信息） */
  static lastDropStats: ProxyDropStats = new ProxyDropStats();
  /** 最近一次生成的「双轨 provider」账本（开关关闭时 enabled=false 且 emitted=0） */
  static lastProviderStats: RawProviderStats = new RawProviderStats();
  /** 丢弃告警回调：UI 侧注册后，连接/测速生成配置时的丢弃会以提示形式触达用户 */
  private static dropReporter: ((text: string) => void) | null = null;

  static setDropReporter(reporter: ((text: string) => void) | null): void {
    ClashConfigGenerator.dropReporter = reporter;
  }

  /** 记录并上报丢弃：日志必定写，UI 回调存在时同步提示 */
  static notifyDroppedNodes(stats: ProxyDropStats, stage: string): void {
    const text = `${stage}丢弃 ${stats.dropped()} / ${stats.total} 个节点：${stats.reasons()}`;
    AppLogger.warn(TAG, text);
    if (ClashConfigGenerator.dropReporter !== null) {
      ClashConfigGenerator.dropReporter(text);
    }
  }

  static generate(selectedNode: ProxyNode, allNodes: ProxyNode[], settings: AppSettings,
    mixedPort: number, apiPort: number, dnsPort: number, apiSecret: string, useGeoip: boolean = true,
    ipv6Enabled: boolean = false, proxyHosts: Record<string, string> = {},
    tunEnabled: boolean = true, proxyGroups: ProxyGroup[] = []): string {
    const lines: string[] = [];

    lines.push('mixed-port: ' + mixedPort);
    lines.push('external-controller: 127.0.0.1:' + apiPort);
    lines.push('secret: "' + apiSecret + '"');
    // 代理模式（upstream settings.proxyMode）：rule=规则 / global=全局
    lines.push('mode: ' + (settings.proxyMode === 'global' ? 'global' : 'rule'));
    // Warning retains operational failures while reducing steady-state formatting and I/O.
    lines.push('log-level: warning');
    // 项目规格统一为 IPv4-only：同时关闭 mihomo 全局 IPv6 与 DNS AAAA，
    // 配合 VpnExtensionAbility 的 IPv4-only TUN，消除 IPv6 绕过及泄漏通道。
    lines.push('ipv6: false');
    lines.push('disable-ipv6: true');
    lines.push('unified-delay: true');
    lines.push('tcp-concurrent: true');
    // 长连接与会话复用参数：降低频繁握手、弱网切换后的僵尸连接和后台功耗。
    lines.push('keep-alive-idle: 30');
    lines.push('keep-alive-interval: 15');
    lines.push('udp-timeout: 300');
    lines.push('find-process-mode: off');
    lines.push('');
    lines.push('dns:');
    lines.push('  enable: true');
    lines.push(`  listen: 127.0.0.1:${dnsPort}`);
    lines.push('  ipv6: false');
    lines.push('  enhanced-mode: fake-ip');
    lines.push('  cache-algorithm: arc');
    lines.push('  fake-ip-range: 198.18.0.1/16');
    // DNS 上游必须用裸 IP UDP 直连(不走代理不劫持): DoH(域名)会引发解析死锁——
    // 解析 DoH 域名 → DoH 请求 → 又需要域名 → 回环超时(真机 core.log 实证)。
    lines.push('  default-nameserver:');
    lines.push('    - 223.5.5.5');
    lines.push('    - 119.29.29.29');
    // 分流 DNS：国内域名用国内公共 DNS 直解（快、准、不被污染）；
    // 海外域名走加密 fallback（DoH/DoQ 裸 IP，避免解析死锁）经代理链解析。
    lines.push('  nameserver:');
    lines.push('    - 223.5.5.5');
    lines.push('    - 119.29.29.29');
    lines.push('  fallback:');
    lines.push('    - tls://1.1.1.1:853#DIRECT');
    lines.push('    - tls://8.8.8.8:853#DIRECT');
    // fallback 与 nameserver 竞速（命中国内即返回，避免 fallback 拖慢国内解析）。
    lines.push('  strategy: prefer_ipv4');
    lines.push('  disable-cache: false');
    // 代理服务器域名的专用解析: 不走 fake-ip(否则内核拿 198.18.x.x 假地址拨号
    // 代理服务器, 全部 i/o timeout —— 真机 core.log 实证), 用真实 DNS 直出。
    lines.push('  proxy-server-nameserver:');
    lines.push('    - 223.5.5.5');
    lines.push('    - 119.29.29.29');
    // fake-ip 过滤：局域网/系统/直连目标不返回假 IP，避免误伤本地发现与测速。
    lines.push('  fake-ip-filter:');
    lines.push('    - "*.lan"');
    lines.push('    - "*.local"');
    lines.push('    - "*.msftconnecttest.com"');
    lines.push('    - "*.msftncsi.com"');
    lines.push('    - "localhost.ptlogin2.qq.com"');
    lines.push('    - "+.srv.nintendo.net"');
    lines.push('    - "+.stun.playstation.net"');
    lines.push('');
    lines.push('profile:');
    // 连接复用：存储已选策略，减少重连后的重复握手与选点抖动。
    lines.push('  store-selections: true');
    lines.push('  store-fake-ip: true');
    lines.push('');
    lines.push('tun:');
    // headless 测速模式: tun.enable=false, 内核只开 mixed/API 端口, 不建隧道不碰 VPN 权限
    lines.push('  enable: ' + (tunEnabled ? 'true' : 'false'));
    lines.push('  stack: gvisor');  // fd 注入 + 沙箱无 iptables, 只有 gvisor 可用
    // DNS 覆写(TUN 层): 所有目标端口 53 的 DNS 请求一律劫持进内核解析。
    lines.push('  dns-hijack:');
    lines.push('    - any:53');
    lines.push('  auto-route: false');   // 路由由 VpnExtensionAbility 安装（默认路由 = 系统级 Kill Switch）
    lines.push('  auto-detect-interface: false');
    // 说明：strict-route 依赖 nftables/iptables，OHOS gvisor+fd 注入沙箱不可用，
    // 故不启用；Kill Switch 由 Extension 的 IPv4-only 默认路由 + 内核存活监控保证。
    lines.push('  mtu: 1400');          // 缺省值；Extension 按物理承载改写并下发 VpnConfig.mtu
    lines.push('');
    // ── hosts: 代理服务器域名的防投毒固定解析(UI 进程 DoH 预解析结果) ──
    // 内核拨号代理服务器时直接命中这些真实 IP, 不再走运行期(可能被污染的)DNS。
    const normalizedHosts = new Map<string, string>();
    for (const rawHost of Object.keys(proxyHosts)) {
      const host = ClashConfigGenerator.normalizeDomain(rawHost);
      const address = proxyHosts[rawHost].trim();
      if (host.length === 0 || !ClashConfigGenerator.isValidIpAddress(address)) {
        continue;
      }
      normalizedHosts.set(host, address.toLowerCase());
    }
    if (normalizedHosts.size > 0) {
      lines.push('hosts:');
      for (const h of Array.from(normalizedHosts.keys()).sort()) {
        lines.push(`  "${ClashConfigGenerator.escapeYaml(h)}": "${ClashConfigGenerator.escapeYaml(normalizedHosts.get(h) ?? '')}"`);
      }
      lines.push('');
    }
    lines.push('proxies:');
    // 只从白名单结构化字段生成合法配置，任何协议均不透传 rawYaml。
    // 同时把不可写入的节点按原因计数（漏洞 A：此前 validNodes 过滤是静默的，
    // 列表显示 N 个而内核只有 0 个，界面无任何提示）。
    const dropStats = ClashConfigGenerator.countDroppedNodes(allNodes);
    ClashConfigGenerator.lastDropStats = dropStats;
    const validNodes: ProxyNode[] = [];
    for (const n of allNodes) {
      if (ClashConfigGenerator.proxyYamlLine(n).length > 0) {
        validNodes.push(n);
      }
    }
    if (dropStats.hasDrop()) {
      // 存活数少于列表节点数：日志 + UI 回调（不阻止连接，但绝不静默）
      ClashConfigGenerator.notifyDroppedNodes(dropStats, '生成配置');
    }
    if (validNodes.length === 0) {
      // 零有效节点时生成空 proxies + 空组会让内核解析失败，直接抛出可读错误。
      // 错误文案必须带丢弃数量与原因，否则用户只看到「没有可用的节点配置」而无从下手。
      throw new Error(`没有可用的节点配置：${dropStats.summary()}。`
        + (dropStats.missingCredential > 0
          ? '其中多个节点缺少 password/uuid：本机加密存储未能回填凭据，请到「订阅」页刷新订阅后重连。'
          : '请到「订阅」页刷新订阅后重连。'));
    }
    for (const n of validNodes) {
      lines.push(ClashConfigGenerator.proxyYamlLine(n));
    }
    // ── 双轨（settings.useRawProviderConfig，默认关闭）────────────────────
    // 开关关闭：计划为空、不追加任何一行 → 输出与现状（HEAD）完全一致。
    // 开关开启：每个已落盘的订阅原文作为 `type: file` provider 交给内核自行解析，
    // 与 Mihomo/Clash Verge 对齐；文件缺失的 provider 绝不写入（避免 use: 悬空引用）。
    const providerPlan: RawProviderPlan = ClashConfigGenerator.planRawProviders(settings, allNodes);
    ClashConfigGenerator.lastProviderStats = providerPlan.stats;
    if (providerPlan.entries.length > 0) {
      lines.push('');
      lines.push('proxy-providers:');
      for (const entry of providerPlan.entries) {
        lines.push(`  "${ClashConfigGenerator.escapeYaml(entry.providerName)}":`);
        lines.push('    type: file');
        // path 语义见 RawSubscriptionStore 顶部注释：默认相对内核 HomeDir(=cacheDir)
        lines.push(`    path: "${ClashConfigGenerator.escapeYaml(entry.providerPath)}"`);
        if (RAW_PROVIDER_HEALTH_CHECK_ENABLED) {
          lines.push('    health-check:');
          lines.push('      enable: true');
          lines.push(`      url: "${RAW_PROVIDER_HEALTH_CHECK_URL}"`);
          lines.push(`      interval: ${RAW_PROVIDER_HEALTH_CHECK_INTERVAL}`);
        }
      }
    }
    const groupSelected: ProxyNode = validNodes.includes(selectedNode) ? selectedNode : validNodes[0];
    const emittedGroups = ClashConfigGenerator.planProxyGroups(proxyGroups, validNodes);
    const selections = ClashConfigGenerator.parseProxyGroupSelections(settings.proxyGroupSelections);
    lines.push('');
    lines.push('proxy-groups:');
    lines.push('  - name: "PROXY"');
    lines.push('    type: select');
    lines.push('    proxies:');
    lines.push(`      - "${ClashConfigGenerator.escapeYaml(groupSelected.name)}"`);
    for (const group of emittedGroups) {
      lines.push(`      - "${ClashConfigGenerator.escapeYaml(group.name)}"`);
    }
    for (const n of validNodes) {
      if (n.id !== groupSelected.id) {
        lines.push(`      - "${ClashConfigGenerator.escapeYaml(n.name)}"`);
      }
    }
    // 代理组通过 use: 引用原始订阅 provider：解析链节点 + provider 节点同时可用，
    // 任一路径失效都不会让「组内为空」导致内核启动失败（双轨过渡的核心保障）。
    if (providerPlan.entries.length > 0) {
      lines.push('    use:');
      for (const entry of providerPlan.entries) {
        lines.push(`      - "${ClashConfigGenerator.escapeYaml(entry.providerName)}"`);
      }
    }
    for (const group of emittedGroups) {
      const members = group.members.slice();
      const selected = selections.get(ClashConfigGenerator.proxyGroupKey(group));
      if (selected !== undefined && members.includes(selected)) {
        members.splice(members.indexOf(selected), 1);
        members.unshift(selected);
      }
      lines.push(`  - name: "${ClashConfigGenerator.escapeYaml(group.name)}"`);
      lines.push(`    type: ${group.groupType}`);
      if (group.groupType === 'url-test' || group.groupType === 'fallback') {
        lines.push('    url: "https://www.gstatic.com/generate_204"');
        lines.push('    interval: 300');
      } else if (group.groupType === 'load-balance') {
        lines.push('    url: "https://www.gstatic.com/generate_204"');
        lines.push('    interval: 300');
        lines.push('    strategy: consistent-hashing');
      }
      lines.push('    proxies:');
      for (const member of members) {
        lines.push(`      - "${ClashConfigGenerator.escapeYaml(member)}"`);
      }
    }
    if (settings.rulesEnabled && settings.hyperAdRulesEnabled) {
      lines.push('');
      lines.push('rule-providers:');
      lines.push('  hyper-adrules:');
      lines.push('    type: http');
      lines.push('    behavior: domain');
      lines.push('    format: mrs');
      lines.push('    interval: 86400');
      lines.push('    path: ./ruleset/hyper_adrules_ads.mrs');
      lines.push('    url: "https://github.com/Lynricsy/HyperADRules/releases/latest/download/hyper_adrules_ads.mrs"');
    }
    lines.push('');
    lines.push('rules:');
    if (settings.rulesEnabled && settings.hyperAdRulesEnabled) {
      lines.push('  - RULE-SET,hyper-adrules,REJECT');
    }
    if (settings.rulesEnabled) {
      for (const customRule of ClashConfigGenerator.normalizeCustomRules(settings.customRules)) {
        lines.push(`  - ${customRule}`);
      }
    }
    // 强制站点规则统一做域名规范化、格式验证和去重，避免规则/YAML 注入。
    const directSites = ClashConfigGenerator.normalizeDomains(settings.forceDirectSites);
    const proxySites = ClashConfigGenerator.normalizeDomains(settings.forceProxySites);
    for (const site of directSites) {
      lines.push(`  - DOMAIN-SUFFIX,${site},DIRECT`);
    }
    for (const site of proxySites) {
      // DIRECT 优先，避免同一域名生成互相冲突的规则。
      if (!directSites.includes(site)) {
        lines.push(`  - DOMAIN-SUFFIX,${site},PROXY`);
      }
    }
    // 国内直连：GEOIP 需要 geoip.metadb（内核 home 目录）; 缺失时降级跳过,
    // 否则 config.Parse 阶段就会联网下载 MMDB, 国内网络不可达直接导致启动失败。
    // DOMAIN-SUFFIX,cn 直连不受影响, MMDB 由编排器后台补齐后下次连接生效。
    if (useGeoip) {
      lines.push('  - GEOIP,CN,DIRECT');
    }
    lines.push('  - DOMAIN-SUFFIX,cn,DIRECT');
    // 兜底规则: 上面的国内规则已放行国内流量, 剩余(YouTube/Google 等国外站点)
    // 必须走代理。此前 bypassDomesticApps=true 会生成 MATCH,DIRECT, 导致
    // 国外流量也直连、无法访问被墙站点(真机 core.log: youtube:443 using DIRECT)。
    // bypassDomesticApps 的语义收敛为"国内直连分流是否启用"(见上方 GEOIP/cn 规则),
    // 不再影响兜底 —— 兜底永远是 PROXY, 否则 VPN 没有意义。
    lines.push('  - MATCH,PROXY');
    // 最终出口净化：无论上游哪条路径漏进控制字符（rawTemplate/逐字 ws 值/持久化脏数据），
    // 落盘配置必然 YAML-printable，内核不会因 "control characters are not allowed" 拒载。
    return ClashConfigGenerator.sanitizeControlChars(lines.join('\n') + '\n');
  }

  /** 与节点页持久化键保持一致：订阅 ID + NUL + 原始组名。 */
  static proxyGroupKey(group: ProxyGroup): string {
    return group.subscriptionId + '\u0000' + group.name;
  }

  /** 容错读取代理组选择；旧版本、损坏 JSON 或非字符串值均按空选择处理。 */
  static parseProxyGroupSelections(raw: string): Map<string, string> {
    const out = new Map<string, string>();
    if (raw.length === 0) {
      return out;
    }
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      for (const key of Object.keys(parsed)) {
        const value = parsed[key];
        // 键是节点页稳定键（subscriptionId + '\u0000' + 组名），含 NUL 属预期格式，
        // 仅用于内存查找、从不写入 YAML，故不套用 isSafeText；值会进入配置，必须安全。
        if (typeof value === 'string' && key.length > 0 && key.length <= 64 * 1024
          && ClashConfigGenerator.isSafeText(value)) {
          out.set(key, value);
        }
      }
    } catch (_) {
      // 设置损坏不能阻止连接，回退到订阅声明顺序。
    }
    return out;
  }

  /**
   * 生成可安全写入 Mihomo 的代理组计划。
   * 仅保留支持类型、名称唯一且成员最终可解析的组，并通过迭代消除悬空引用与纯循环组。
   */
  static planProxyGroups(groups: ProxyGroup[], validNodes: ProxyNode[]): ProxyGroup[] {
    const supported = new Set<string>(['select', 'url-test', 'fallback', 'load-balance']);
    const nodeNames = new Set<string>();
    const originalToDisplay = new Map<string, string[]>();
    for (const node of validNodes) {
      nodeNames.add(node.name);
      const original = node.originalName.length > 0 ? node.originalName : node.name;
      const displays = originalToDisplay.get(original);
      if (displays === undefined) {
        originalToDisplay.set(original, [node.name]);
      } else if (!displays.includes(node.name)) {
        displays.push(node.name);
      }
    }
    // 组名保留字：任何节点显示名/原始名（含 NUL 分隔的订阅键无关）都不能被组占用，
    // 否则成员引用存在「解析为节点还是组」的二义性。
    const reservedNames = new Set<string>();
    for (const node of validNodes) {
      reservedNames.add(node.name);
      reservedNames.add(node.originalName.length > 0 ? node.originalName : node.name);
    }

    const candidates: ProxyGroup[] = [];
    const acceptedNames = new Set<string>();
    for (const source of groups) {
      const type = source.groupType.trim().toLowerCase();
      const name = source.name.trim();
      if (!supported.has(type) || name.length === 0 || name === 'PROXY'
        || !ClashConfigGenerator.isSafeText(name) || reservedNames.has(name)
        || acceptedNames.has(name)) {
        continue;
      }
      const item = new ProxyGroup();
      item.subscriptionId = source.subscriptionId;
      item.name = name;
      item.groupType = type;
      item.members = source.members.slice();
      candidates.push(item);
      acceptedNames.add(name);
    }

    // 落地性迭代：组必须能经成员引用最终到达真实节点才可写入配置。
    // 纯循环组（互相引用但无节点出口）永远不会落地 → 整组丢弃；
    // 带真实出口的循环由直接引用节点的组先落地，再逐轮向外传播保留。
    const groundedNames = new Set<string>();
    const groundedOrder = new Map<string, number>();
    let changed = true;
    while (changed) {
      changed = false;
      for (const group of candidates) {
        if (groundedNames.has(group.name)) {
          continue;
        }
        for (const rawMember of group.members) {
          const displays = originalToDisplay.get(rawMember);
          const reachesNode = nodeNames.has(rawMember)
            || (displays !== undefined && displays.length > 0);
          const reachesGroundedGroup = groundedNames.has(rawMember) && rawMember !== group.name;
          if (reachesNode || reachesGroundedGroup) {
            groundedOrder.set(group.name, groundedOrder.size);
            groundedNames.add(group.name);
            changed = true;
            break;
          }
        }
      }
    }

    const out: ProxyGroup[] = [];
    for (const group of candidates) {
      if (!groundedNames.has(group.name)) {
        continue;
      }
      const members: string[] = [];
      for (const rawMember of group.members) {
        const displays = originalToDisplay.get(rawMember);
        if (displays !== undefined) {
          for (const display of displays) {
            if (!members.includes(display)) {
              members.push(display);
            }
          }
        } else if (nodeNames.has(rawMember) && !members.includes(rawMember)) {
          members.push(rawMember);
        } else if (groundedNames.has(rawMember) && rawMember !== group.name
          && (groundedOrder.get(rawMember) ?? 0) < (groundedOrder.get(group.name) ?? 0)
          && !members.includes(rawMember)) {
          // 组引用只指向更早落地的组：严格偏序天然消除配置内循环引用，
          // 也绝不引用被丢弃的组（无悬空引用），内核可安全加载。
          members.push(rawMember);
        }
      }
      if (members.length === 0) {
        continue;
      }
      group.members = members;
      out.push(group);
    }
    return out;
  }

  static normalizeCustomRules(values: string[]): string[] {
    const out: string[] = [];
    const allowed: string[] = ['DOMAIN', 'DOMAIN-SUFFIX', 'DOMAIN-KEYWORD', 'IP-CIDR', 'IP-CIDR6', 'GEOIP'];
    for (const raw of values) {
      const rule = raw.trim();
      if (rule.length === 0 || rule.length > 512 || rule.includes('\n') || rule.includes('\r')) {
        continue;
      }
      const parts = rule.split(',').map((v: string) => v.trim());
      if ((parts.length !== 3 && parts.length !== 4) || !allowed.includes(parts[0])) {
        continue;
      }
      if (parts[1].length === 0 || (parts[2] !== 'DIRECT' && parts[2] !== 'PROXY' && parts[2] !== 'REJECT')) {
        continue;
      }
      if (parts.length === 4 && parts[3] !== 'no-resolve') {
        continue;
      }
      const normalized = parts.join(',');
      if (!out.includes(normalized)) {
        out.push(normalized);
      }
    }
    return out.slice(0, 500);
  }

  /** 节点 → 内核类型（ss/ssr 用模型枚举，其余用 proxyType 小写） */
  private static proxyTypeOf(n: ProxyNode): string {
    return n.type === ProxyNodeType.SSR ? 'ssr'
      : (n.type === ProxyNodeType.SS ? 'ss' : n.proxyType.toLowerCase());
  }

  /**
   * 「能否写入内核配置」的唯一判定（顺序与旧 proxyYamlLine 的 return '' 分支严格一致）：
   * 协议不支持 → 文本不安全 → 缺 name/server 或协议必需字段 → 端口非法。
   * 生成配置与诊断计数共用此函数，保证「丢弃计数」与「实际写入行」永不漂移。
   */
  static dropReasonFor(n: ProxyNode): ProxyDropReason {
    const proxyType = ClashConfigGenerator.proxyTypeOf(n);
    // direct 出站只有 name/type（mihomo 合法节点），没有 server/port/凭据可校验
    if (proxyType === 'direct') {
      return n.name.length === 0 ? ProxyDropReason.MISSING_FIELD : ProxyDropReason.NONE;
    }
    if (proxyType !== 'ss' && proxyType !== 'ssr' && proxyType !== 'vless'
      && proxyType !== 'vmess' && proxyType !== 'trojan' && proxyType !== 'hysteria2'
      && !YamlMerger.isRelayType(proxyType)) {
      return ProxyDropReason.UNSUPPORTED_PROTOCOL;
    }
    const textValues: string[] = [n.name, n.server, n.password, n.method, n.protocol, n.protocolParam,
      n.obfs, n.obfsParam, n.uuid, n.network, n.servername, n.flow, n.clientFingerprint,
      n.realityPublicKey, n.realityShortId, n.wsPath, n.wsHost, n.grpcServiceName,
      n.hyUp, n.hyDown, n.alpnList];
    for (const value of textValues) {
      if (!ClashConfigGenerator.isSafeText(value)) {
        return ProxyDropReason.UNSAFE_TEXT;
      }
    }
    if (n.name.length === 0 || n.server.length === 0) {
      return ProxyDropReason.MISSING_FIELD;
    }
    if (n.port <= 0 || n.port > 65535) {
      return ProxyDropReason.INVALID_PORT;
    }
    if (proxyType === 'ss' || proxyType === 'ssr') {
      // method 缺失属结构缺字段; password 缺失属凭据缺失(加密层未回填的典型信号)
      if (n.method.length === 0) {
        return ProxyDropReason.MISSING_FIELD;
      }
      if (n.password.length === 0) {
        return ProxyDropReason.MISSING_CREDENTIAL;
      }
    }
    if (proxyType === 'ssr' && (n.protocol.length === 0 || n.obfs.length === 0)) {
      return ProxyDropReason.MISSING_FIELD;
    }
    if ((proxyType === 'vless' || proxyType === 'vmess') && n.uuid.length === 0) {
      return ProxyDropReason.MISSING_CREDENTIAL;
    }
    if (n.realityPublicKey.length > 0 || n.realityShortId.length > 0) {
      // REALITY 字段合法性对齐内核解析规则(mihomo reality.go):
      // public-key = base64url(RawURLEncoding) 解码后必须 32 字节(43 字符);
      // short-id 必须偶数长度 hex 且解码后 ≤8 字节(≤16 字符)。
      // 新版官方内核对解析失败的代理是「跳过该节点」; 捆绑的旧内核是
      // 「整份配置解析失败」→ 一个坏节点曾让内核完全起不来(全部超时)。
      // 这里在生成前拦截: 非法 REALITY 字段的节点按无效丢弃并计数。
      if (n.realityPublicKey.length > 0
        && !/^[A-Za-z0-9_-]{43}$/.test(n.realityPublicKey)) {
        return ProxyDropReason.MISSING_FIELD;
      }
      if (n.realityShortId.length > 0
        && !/^[0-9a-fA-F]{2}([0-9a-fA-F]{2}){0,7}$/.test(n.realityShortId)) {
        return ProxyDropReason.MISSING_FIELD;
      }
    }
    if (proxyType === 'trojan' && n.password.length === 0) {
      return ProxyDropReason.MISSING_CREDENTIAL;
    }
    if (proxyType === 'hysteria2' && n.password.length === 0) {
      return ProxyDropReason.MISSING_CREDENTIAL;
    }
    if (n.alterId < 0 || !Number.isInteger(n.alterId)) {
      return ProxyDropReason.MISSING_FIELD;
    }
    return ProxyDropReason.NONE;
  }

  /**
   * 统计 nodes 中「列表有、内核无」的节点数与原因分类（漏洞 A 的核心修复）。
   * 复用 dropReasonFor，因此与实际写入内核配置的判定完全同源。
   */
  static countDroppedNodes(nodes: ProxyNode[]): ProxyDropStats {
    const stats = new ProxyDropStats();
    stats.total = nodes.length;
    const samples: string[] = [];
    for (const n of nodes) {
      const reason = ClashConfigGenerator.dropReasonFor(n);
      if (reason === ProxyDropReason.NONE) {
        stats.kept = stats.kept + 1;
        continue;
      }
      if (reason === ProxyDropReason.UNSUPPORTED_PROTOCOL) {
        stats.unsupportedProtocol = stats.unsupportedProtocol + 1;
      } else if (reason === ProxyDropReason.UNSAFE_TEXT) {
        stats.unsafeText = stats.unsafeText + 1;
      } else if (reason === ProxyDropReason.INVALID_PORT) {
        stats.invalidPort = stats.invalidPort + 1;
      } else {
        stats.missingFields = stats.missingFields + 1;
        if (reason === ProxyDropReason.MISSING_CREDENTIAL) {
          stats.missingCredential = stats.missingCredential + 1;
        }
      }
      if (samples.length < 3) {
        samples.push(n.name.length > 0 ? n.name : '(未命名)');
      }
    }
    stats.samples = samples.join('、');
    return stats;
  }

  /**
   * 「双轨」provider 计划：决定本次配置要不要输出 proxy-providers / use:。
   *
   * 硬约束（缺一不可，任何一条不满足都只是「少一条 provider」，绝不产生悬空引用）：
   * 1) settings.useRawProviderConfig 为 true（开关关闭 → 直接返回空计划，输出与现状一致）；
   * 2) 该订阅的原文已成功落盘且文件此刻仍存在（RawSubscriptionStore.active 已校验）；
   * 3) 该订阅此刻仍有节点在列表里（订阅被删/被隐藏后不再引用其 provider）。
   * 差额（缺失文件 / 无对应节点）全部计入 lastProviderStats，由诊断面板展示。
   */
  static planRawProviders(settings: AppSettings, allNodes: ProxyNode[]): RawProviderPlan {
    const plan = new RawProviderPlan();
    plan.stats.pathMode = RAW_PROVIDER_PATH_MODE;
    if (!settings.useRawProviderConfig) {
      // 默认路径：开关关闭时行为与现状完全一致（不产生任何额外行 / 额外 IO）
      plan.stats.enabled = false;
      return plan;
    }
    plan.stats.enabled = true;
    const liveSubscriptions = new Set<string>();
    for (const n of allNodes) {
      if (n.subscriptionId.length > 0) {
        liveSubscriptions.add(n.subscriptionId);
      }
    }
    const names: string[] = [];
    for (const entry of RawSubscriptionStore.active()) {
      plan.stats.candidates = plan.stats.candidates + 1;
      if (!liveSubscriptions.has(entry.subscriptionId)) {
        plan.stats.orphaned = plan.stats.orphaned + 1;
        continue;
      }
      if (!RawSubscriptionStore.has(entry.subscriptionId)) {
        plan.stats.missingFiles = plan.stats.missingFiles + 1;
        continue;
      }
      plan.entries.push(entry);
      names.push(entry.providerName);
    }
    plan.stats.emitted = plan.entries.length;
    plan.stats.providerNames = names.join(',');
    if (plan.stats.candidates > plan.stats.emitted) {
      AppLogger.warn(TAG, `raw provider plan: ${plan.stats.detail()}`);
    }
    return plan;
  }

  /**
   * 提取 extras 里以 `ws-opts.<sub>` 前缀保全的 WS 高级子键（max-early-data 等），
   * 返回 [subKey, 发射值]：布尔/数字原样、其余引号，供并入 ws-opts 结构。
   */
  private static wsExtraPairs(extraOpts: string): string[][] {
    const out: string[][] = [];
    for (const pair of YamlMerger.parseExtraOpts(extraOpts)) {
      const key = pair[0];
      if (!key.startsWith('ws-opts.')) {
        continue;
      }
      const sub = key.substring('ws-opts.'.length);
      if (!YamlMerger.isSafeExtraKey(sub) || !ClashConfigGenerator.isSafeText(pair[1])) {
        continue;
      }
      const value = pair[1];
      if (value === 'true' || value === 'false' || /^-?[0-9]+(\.[0-9]+)?$/.test(value)
        || value.startsWith('{') || value.startsWith('[')) {
        out.push([sub, ClashConfigGenerator.sanitizeControlChars(value)]);
      } else {
        out.push([sub, `"${ClashConfigGenerator.escapeYaml(value)}"`]);
      }
    }
    return out;
  }

  static proxyYamlLine(n: ProxyNode): string {
    // 判定统一走 dropReasonFor：能写出合法行的节点必定判定为 NONE，
    // 判定非 NONE 的节点返回空行（调用方用 countDroppedNodes 记账并提示）。
    if (ClashConfigGenerator.dropReasonFor(n) !== ProxyDropReason.NONE) {
      return '';
    }
    const proxyType = ClashConfigGenerator.proxyTypeOf(n);
    const q = (value: string): string => `"${ClashConfigGenerator.escapeYaml(value)}"`;
    // ── 逐字模板优先（根治「解析→重生成丢字段」）──
    // 订阅原始 flow-map 已去 name/凭据，原样回写，再注入去重后的 name 与
    // 加密层回填的凭据。传输/选项字段(xhttp-opts、reality-opts、headers、
    // dialer-proxy、null 值…)全部逐字保留，与桌面 Clash 用原始 YAML 等价。
    if (n.rawTemplate.length > 0 && ClashConfigGenerator.isSafeText(n.rawTemplate)) {
      const rawParts: string[] = [`name: ${q(n.name)}`, ClashConfigGenerator.sanitizeControlChars(n.rawTemplate)];
      if (n.uuid.length > 0) {
        rawParts.push(`uuid: ${q(n.uuid)}`);
      }
      if (n.password.length > 0) {
        rawParts.push(`password: ${q(n.password)}`);
      }
      if (n.protocolParam.length > 0) {
        rawParts.push(`protocol-param: ${q(n.protocolParam)}`);
      }
      if (n.obfsParam.length > 0) {
        rawParts.push(`${proxyType === 'hysteria2' ? 'obfs-password' : 'obfs-param'}: ${q(n.obfsParam)}`);
      }
      // 保留结构化路径的 WS 兜底: 面板把 ws 节点写成 network: ws 却省略 ws-opts 时,
      // mihomo 会发无路径/无 Host 的 Upgrade 被 Cloudflare 拒绝, 这里补默认值。
      if ((proxyType === 'vless' || proxyType === 'vmess' || proxyType === 'trojan')
        && n.network === 'ws' && !n.rawTemplate.includes('ws-opts')) {
        const ws: string[] = ['path: "/"'];
        if (n.servername.length > 0) {
          ws.push(`headers: {Host: ${q(n.servername)}}`);
        }
        rawParts.push(`ws-opts: {${ws.join(', ')}}`);
      }
      return `  - {${rawParts.join(', ')}}`;
    }
    // ── 无模板(URI 导入/块式写法)：回退结构化生成 ──
    const fields: string[] = [];
    fields.push(`name: ${q(n.name)}`);
    fields.push(`type: ${proxyType}`);
    if (proxyType !== 'direct') {
      // direct 出站没有 server/port（mihomo 的 DirectOption 不含这两个键）
      fields.push(`server: ${q(n.server)}`);
      fields.push(`port: ${n.port}`);
    }
    if (proxyType === 'ss' || proxyType === 'ssr' || proxyType === 'vmess') {
      fields.push(`cipher: ${q(n.method.length > 0 ? n.method : 'auto')}`);
    }
    if (proxyType === 'ss' || proxyType === 'ssr' || proxyType === 'trojan'
      || proxyType === 'hysteria2' || (proxyType !== 'vless' && proxyType !== 'vmess'
        && n.password.length > 0)) {
      // 口令类协议: vless/vmess 用 uuid, 其余(含 tuic/hysteria/socks5/http)用 password
      fields.push(`password: ${q(n.password)}`);
    }
    if (proxyType === 'ssr') {
      fields.push(`protocol: ${q(n.protocol)}`);
      fields.push(`protocol-param: ${q(n.protocolParam)}`);
      fields.push(`obfs: ${q(n.obfs)}`);
      fields.push(`obfs-param: ${q(n.obfsParam)}`);
    }
    if ((proxyType === 'vless' || proxyType === 'vmess' || proxyType === 'tuic')
      && n.uuid.length > 0) {
      fields.push(`uuid: ${q(n.uuid)}`);
    }
    if (proxyType === 'vmess') {
      fields.push(`alterId: ${n.alterId}`);
    }
    if (n.udp) {
      fields.push('udp: true');
    }
    if (n.network.length > 0) {
      fields.push(`network: ${q(n.network)}`);
    }
    if (n.tls) {
      fields.push('tls: true');
    }
    if (n.servername.length > 0) {
      // hysteria2/hysteria/tuic 的 SNI 键名是 sni（不接受 servername 键）
      fields.push(`${YamlMerger.usesSniKey(proxyType) ? 'sni' : 'servername'}: ${q(n.servername)}`);
    }
    if (n.skipCertVerify) {
      fields.push('skip-cert-verify: true');
    }
    if (n.flow.length > 0) {
      fields.push(`flow: ${q(n.flow)}`);
    }
    if (n.clientFingerprint.length > 0) {
      // hysteria2 的证书指纹(pinSHA256)键名是 fingerprint
      fields.push(`${proxyType === 'hysteria2' ? 'fingerprint' : 'client-fingerprint'}: ${q(n.clientFingerprint)}`);
    }
    if (proxyType === 'hysteria2') {
      if (n.obfs.length > 0) {
        fields.push(`obfs: ${q(n.obfs)}`);
      }
      if (n.obfsParam.length > 0) {
        fields.push(`obfs-password: ${q(n.obfsParam)}`);
      }
      if (n.hyUp.length > 0) {
        fields.push(`up: ${q(n.hyUp)}`);
      }
      if (n.hyDown.length > 0) {
        fields.push(`down: ${q(n.hyDown)}`);
      }
    }
    if (n.alpnList.length > 0 && YamlMerger.supportsAlpn(proxyType)) {
      // alpn 不再只输出给 hysteria2: vless/vmess/trojan/tuic 同样需要 ALPN 协商
      const items: string[] = [];
      for (const it of n.alpnList.split(',')) {
        if (it.length > 0) {
          items.push(q(it));
        }
      }
      if (items.length > 0) {
        fields.push(`alpn: [${items.join(', ')}]`);
      }
    }
    if (n.realityPublicKey.length > 0 || n.realityShortId.length > 0) {
      const reality: string[] = [];
      if (n.realityPublicKey.length > 0) {
        reality.push(`public-key: ${q(n.realityPublicKey)}`);
      }
      if (n.realityShortId.length > 0) {
        reality.push(`short-id: ${q(n.realityShortId)}`);
      }
      fields.push(`reality-opts: {${reality.join(', ')}}`);
    }
    if (n.wsPath.length > 0 || n.wsHost.length > 0) {
      const ws: string[] = [];
      if (n.wsPath.length > 0) {
        ws.push(`path: ${q(n.wsPath)}`);
      }
      if (n.wsHost.length > 0) {
        ws.push(`headers: {Host: ${q(n.wsHost)}}`);
      }
      // ws-opts 高级子键（max-early-data 等）从 extras 并回 ws-opts 结构
      for (const pair of ClashConfigGenerator.wsExtraPairs(n.extraOpts)) {
        ws.push(`${pair[0]}: ${pair[1]}`);
      }
      fields.push(`ws-opts: {${ws.join(', ')}}`);
    } else if (n.network === 'ws') {
      // 订阅未提供 ws-opts 的 WS 节点（典型：Cloudflare 隧道，servername 是
      // xxx.trycloudflare.com 而 path/Host 留空）。mihomo 缺 ws-opts 时不会发
      // 正确的 WebSocket Upgrade（无路径/无 Host），CF 直接拒绝 → 测速 503/
      // 连上也不通。主流客户端（Clash Verge/v2rayN）对这类节点默认 path="/"、
      // Host 取 SNI，这里对齐同样语义。仅对 network=ws 生效，不影响
      // grpc/hysteria2/plain tcp 节点；订阅已给出 path/host 时走上面的分支原样保留。
      const ws: string[] = [`path: ${q('/')}`];
      if (n.servername.length > 0) {
        ws.push(`headers: {Host: ${q(n.servername)}}`);
      }
      fields.push(`ws-opts: {${ws.join(', ')}}`);
    }
    if (n.grpcServiceName.length > 0) {
      fields.push(`grpc-opts: {grpc-service-name: ${q(n.grpcServiceName)}}`);
    }
    // extraOpts 中继: 结构化槽位未覆盖的键(plugin/plugin-opts、h2-opts、ports、tfo、
    // mptcp、ip-version、smux、packet-encoding 等, 以及 tuic/hysteria/http/socks5 等
    // 中继协议的专用键)原样回写; 与已输出键重名时以结构化字段为准。
    const emitted = new Set<string>();
    for (const f of fields) {
      const ci = f.indexOf(':');
      if (ci > 0) {
        emitted.add(f.substring(0, ci).trim());
      }
    }
    for (const pair of YamlMerger.parseExtraOpts(n.extraOpts)) {
      const key = pair[0];
      const value = pair[1];
      if (emitted.has(key) || key === 'name' || key === 'type' || key === 'server'
        || key === 'port' || !YamlMerger.isSafeExtraKey(key)) {
        continue;
      }
      if (!ClashConfigGenerator.isSafeText(value)) {
        continue;
      }
      if (value.startsWith('{') || value.startsWith('[')
        || value === 'true' || value === 'false' || /^-?[0-9]+(\.[0-9]+)?$/.test(value)) {
        fields.push(`${key}: ${value}`);
      } else {
        fields.push(`${key}: ${q(value)}`);
      }
      emitted.add(key);
    }
    return `  - {${fields.join(', ')}}`;
  }

  /** 规范化域名列表并去重，忽略无法安全表达的条目。 */
  private static normalizeDomains(values: string[]): string[] {
    const seen = new Set<string>();
    const out: string[] = [];
    for (const value of values) {
      const domain = ClashConfigGenerator.normalizeDomain(value);
      if (domain.length > 0 && !seen.has(domain)) {
        seen.add(domain);
        out.push(domain);
      }
    }
    return out;
  }

  /** 规范化并验证 hosts/规则使用的域名，拒绝通配符、换行和 YAML/规则元字符。 */
  private static normalizeDomain(value: string): string {
    let domain = value.trim().toLowerCase();
    while (domain.endsWith('.')) {
      domain = domain.substring(0, domain.length - 1);
    }
    if (domain.length === 0 || domain.length > 253 || domain.includes('\n') || domain.includes('\r')
      || domain.includes(',') || domain.includes(':') || domain.includes('#') || domain.includes('[')
      || domain.includes(']') || domain.includes('{') || domain.includes('}') || domain.includes('*')
      || domain.startsWith('.') || domain.endsWith('.') || domain.includes('..')) {
      return '';
    }
    const labels = domain.split('.');
    for (const label of labels) {
      if (label.length === 0 || label.length > 63 || label.startsWith('-') || label.endsWith('-')
        || !/^[a-z0-9-]+$/.test(label)) {
        return '';
      }
    }
    return domain;
  }

  /** hosts 值仅接受规范 IPv4 或无区域标识的 IPv6 字面量。 */
  private static isValidIpAddress(value: string): boolean {
    if (value.length === 0 || value.includes('\n') || value.includes('\r') || value.includes('%')
      || value.includes('#') || value.includes(',') || value.includes(' ') || value.includes('\t')) {
      return false;
    }
    const ipv4 = value.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
    if (ipv4 !== null) {
      for (let i = 1; i <= 4; i++) {
        const part = parseInt(ipv4[i]);
        if (part < 0 || part > 255) {
          return false;
        }
      }
      return true;
    }
    if (!/^[0-9a-fA-F:]+$/.test(value) || !value.includes(':')) {
      return false;
    }
    const pieces = value.split(':');
    if (pieces.length < 3 || pieces.length > 8) {
      return false;
    }
    let emptyRuns = 0;
    for (let i = 0; i < pieces.length; i++) {
      const piece = pieces[i];
      if (piece.length === 0) {
        if (i > 0 && pieces[i - 1].length === 0) {
          emptyRuns++;
        }
      } else if (piece.length > 4 || !/^[0-9a-fA-F]+$/.test(piece)) {
        return false;
      }
    }
    return emptyRuns <= 1;
  }

  private static isSafeText(value: string): boolean {
    return value.length <= 64 * 1024 && !value.includes('\n') && !value.includes('\r')
      && !value.includes('\u0000');
  }

  static escapeYaml(value: string): string {
    let out = '';
    for (let i = 0; i < value.length; i++) {
      const ch = value.charAt(i);
      const code = value.charCodeAt(i);
      if (ch === '\\') {
        out += '\\\\';
      } else if (ch === '"') {
        out += '\\"';
      } else if (ch === '\t') {
        out += '\\t';
      } else if (code < 0x20 || code === 0x7f) {
        out += '?';
      } else {
        out += ch;
      }
    }
    return out;
  }

  /**
   * YAML 可打印白名单净化（用户真机修复 2026-09-18）：
   * mihomo 的 yaml.v3 对 C0 控制符（除 \t\n\r）、0x7F-0x84、0x86-0x9F 一律报
   * "control characters are not allowed"，整份配置拒绝启动。订阅节点里
   * （rawTemplate / ws-opts 原样值 / 历史持久化数据）任何路径漏进来的非法字符
   * 在此统一清洗：制表/游离回车→空格，其余不可打印→'?'。
   * generate() 出口与逐字模板出口双重调用，杜绝"单点遗漏→整机无法连接"。
   */
  static sanitizeControlChars(value: string): string {
    let out = '';
    for (let i = 0; i < value.length; i++) {
      const code = value.charCodeAt(i);
      if (code === 0x09 || code === 0x0d) {
        out += ' ';
      } else if (code === 0x0a || (code >= 0x20 && code <= 0x7e) || code >= 0xa0) {
        out += value.charAt(i);
      } else {
        out += '?';
      }
    }
    return out;
  }

  /** 为端口冲突策略提供本实现使用的端口清单（对应 runtime_port_conflict_policy.dart） */
  static requiredPorts(): number[] {
    return [1053, 7890];
  }
}
