/**
 * 订阅解析器（统一入口）
 * 移植自 upstream: packages/ssrvpn_shared/lib/services/subscription_parser.dart
 *                subscription_parser_base64_part.dart
 *                subscription_parser_naming_part.dart
 *                subscription_parser_yaml_part.dart
 *
 * 支持：ssr:// / ss:// / vless:// / vmess:// / trojan:// / hysteria2://(hy2://) 单链接、
 *       Base64 批量列表、Clash YAML proxies。
 */
import { ProxyNode, ProxyNodeType, SsrCodec } from '../models/ProxyNode';
import { MergedProxy, YamlMergeError, YamlMerger, YamlNodeError } from './YamlMerger';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'SubscriptionParser';

/** 解析层诊断，不依赖服务层状态，避免三种入口各自猜测跳过数量。 */
export class SubscriptionParseDiagnostics {
  inputCount: number = 0;
  duplicateCount: number = 0;
  invalidCount: number = 0;
  unsupportedCount: number = 0;
  unsupportedTypes: string = '';
}

export class SubscriptionParseResult {
  nodes: ProxyNode[] = [];
  diagnostics: SubscriptionParseDiagnostics = new SubscriptionParseDiagnostics();
}

export class SubscriptionParser {
  private static isProxyUri(trimmed: string): boolean {
    return trimmed.startsWith('ssr://') || trimmed.startsWith('ss://')
      || trimmed.startsWith('vless://') || trimmed.startsWith('vmess://')
      || trimmed.startsWith('trojan://') || trimmed.startsWith('hysteria2://')
      || trimmed.startsWith('hy2://');
  }
  /**
   * 解析订阅文本，返回节点列表。
   * 顺序与 upstream 一致：先按行找 ssr:///ss:// 链接 → 整体 base64 解码后再找 → Clash YAML。
   */
  static parse(text: string, subscriptionId: string): ProxyNode[] {
    return SubscriptionParser.parseDetailed(text, subscriptionId).nodes;
  }

  /**
   * 统一的可诊断解析入口。明文、整体 Base64 与 YAML 均逐条隔离失败，
   * 重复、无效和未知协议不会静默消失。
   */
  static parseDetailed(text: string, subscriptionId: string): SubscriptionParseResult {
    const result = new SubscriptionParseResult();
    const diagnostics = result.diagnostics;
    const nodes: ProxyNode[] = [];
    const seen = new Set<string>();
    let counter = 0;

    const add = (node: ProxyNode | null): void => {
      if (node === null) {
        diagnostics.invalidCount = diagnostics.invalidCount + 1;
        return;
      }
      // 去重键须能区分"同地址不同凭据"的节点: YAML 条目无 rawUri, 只用 server:port 会
      // 误伤共用落地服务器的多账号/多协议节点; 通知型重复后端(全字段一致)仍正常去重。
      // name 必须参与去重键: 面板推广/公告条目常与真实节点共用 server:port:凭据, 仅
      // 名字不同; 不含 name 会把它们当重复删掉(与 YamlMerger.identityFingerprint 同理)。
      const key = `${node.name}:${node.server}:${node.port}:${node.proxyType.length > 0 ? node.proxyType : node.type}`
        + `:${node.password}:${node.uuid}:${node.rawUri}`;
      if (seen.has(key)) {
        diagnostics.duplicateCount = diagnostics.duplicateCount + 1;
        return;
      }
      seen.add(key);
      node.name = SubscriptionParser.dedupName(nodes, node.name);
      nodes.push(node);
    };

    const normalized = text.replace(/^\uFEFF/, '');
    // 1) 明文链接逐行解析
    for (const line of normalized.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (trimmed.length === 0) {
        continue;
      }
      if (SubscriptionParser.isProxyUri(trimmed)) {
        diagnostics.inputCount = diagnostics.inputCount + 1;
        try {
          add(ProxyNode.fromUri(trimmed, subscriptionId, `${subscriptionId}-${counter++}`));
        } catch (e) {
          diagnostics.invalidCount = diagnostics.invalidCount + 1;
        }
      } else if (/^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed)) {
        diagnostics.inputCount = diagnostics.inputCount + 1;
        diagnostics.unsupportedCount = diagnostics.unsupportedCount + 1;
        SubscriptionParser.noteUnsupported(diagnostics, trimmed);
      }
    }

    // 2) 整体 Base64 解码后再解析（对应 subscription_parser_base64_part）
    if (nodes.length === 0) {
      const decoded = SsrCodec.decodeBase64Url(normalized.replace(/\s+/g, ''));
      if (decoded.length > 0 && decoded.includes('://')) {
        for (const line of decoded.split(/\r?\n/)) {
          const trimmed = line.trim();
          if (trimmed.length === 0) {
            continue;
          }
          if (SubscriptionParser.isProxyUri(trimmed)) {
            diagnostics.inputCount = diagnostics.inputCount + 1;
            try {
              add(ProxyNode.fromUri(trimmed, subscriptionId, `${subscriptionId}-${counter++}`));
            } catch (e) {
              diagnostics.invalidCount = diagnostics.invalidCount + 1;
            }
          } else if (/^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed)) {
            diagnostics.inputCount = diagnostics.inputCount + 1;
            diagnostics.unsupportedCount = diagnostics.unsupportedCount + 1;
            SubscriptionParser.noteUnsupported(diagnostics, trimmed);
          } else {
            diagnostics.inputCount = diagnostics.inputCount + 1;
            diagnostics.invalidCount = diagnostics.invalidCount + 1;
          }
        }
      }
    }

    // 3) Clash YAML proxies 提取（对应 subscription_parser_yaml_part；完整 YAML 语义由 ClashConfigGenerator 的解析支持）
    if (nodes.length === 0) {
      const groups = YamlMerger.proxyItemGroups(normalized);
      diagnostics.inputCount = groups.length;
      YamlMerger.resetSkipStats();
      const yamlNodes = SubscriptionParser.parseClashYaml(normalized, subscriptionId, counter);
      for (const n of yamlNodes) {
        add(n);
      }
      diagnostics.unsupportedCount = YamlMerger.lastSkippedCount;
      diagnostics.unsupportedTypes = YamlMerger.lastSkippedTypes;
      const accounted = nodes.length + diagnostics.duplicateCount + diagnostics.unsupportedCount;
      diagnostics.invalidCount = Math.max(0, diagnostics.inputCount - accounted);
    }

    AppLogger.info(TAG, `parsed ${nodes.length} nodes for subscription ${subscriptionId}`);
    result.nodes = nodes;
    return result;
  }

  private static noteUnsupported(diagnostics: SubscriptionParseDiagnostics, uri: string): void {
    const sep = uri.indexOf('://');
    const type = sep > 0 ? uri.substring(0, sep).toLowerCase() : 'unknown';
    const types = new Set<string>();
    for (const item of diagnostics.unsupportedTypes.split(',')) {
      if (item.length > 0) {
        types.add(item);
      }
    }
    if (types.size < 12) {
      types.add(type);
    }
    diagnostics.unsupportedTypes = Array.from(types).join(',');
  }

  /** 节点重名规整（对应 subscription_parser_naming_part）：重名追加序号 */
  static dedupName(existing: ProxyNode[], name: string): string {
    const base = name.length > 0 ? name : 'node';
    let finalName = base;
    let i = 2;
    const names = new Set<string>(existing.map((n) => n.name));
    while (names.has(finalName)) {
      finalName = `${base} ${i++}`;
    }
    return finalName;
  }

  /** Clash YAML 统一复用 YamlMerger 的受限结构化解析，坏节点按条目隔离。 */
  static parseClashYaml(text: string, subscriptionId: string, startCounter: number): ProxyNode[] {
    const out: ProxyNode[] = [];
    let counter = startCounter;
    for (const itemLines of YamlMerger.proxyItemGroups(text)) {
      let merged: MergedProxy | null = null;
      try {
        merged = YamlMerger.parseProxyItem(itemLines);
      } catch (e) {
        if (e instanceof YamlNodeError) {
          continue;
        }
        if (e instanceof YamlMergeError) {
          throw e;
        }
        continue;
      }
      if (merged === null) {
        continue;
      }
      const node = new ProxyNode();
      node.id = `${subscriptionId}-y${counter++}`;
      node.subscriptionId = subscriptionId;
      node.name = merged.name;
      node.server = merged.server;
      node.port = merged.port;
      node.password = merged.password;
      node.method = merged.cipher;
      node.protocol = merged.protocol;
      node.protocolParam = merged.protocolParam;
      node.obfs = merged.obfs;
      node.obfsParam = merged.obfsParam;
      node.proxyType = merged.type;
      node.type = merged.type === 'ssr' ? ProxyNodeType.SSR
        : (merged.type === 'ss' ? ProxyNodeType.SS : ProxyNodeType.UNKNOWN);
      node.uuid = merged.uuid;
      node.alterId = merged.alterId;
      node.udp = merged.udp;
      node.network = merged.network;
      node.tls = merged.tls;
      node.servername = merged.servername;
      node.skipCertVerify = merged.skipCertVerify;
      node.flow = merged.flow;
      node.clientFingerprint = merged.clientFingerprint;
      node.realityPublicKey = merged.realityPublicKey;
      node.realityShortId = merged.realityShortId;
      node.wsPath = merged.wsPath;
      node.wsHost = merged.wsHost;
      node.grpcServiceName = merged.grpcServiceName;
      node.hyUp = merged.hyUp;
      node.hyDown = merged.hyDown;
      node.alpnList = merged.alpnList;
      node.extraOpts = merged.extraOpts;
      node.rawYaml = '';
      out.push(node);
    }
    return out;
  }
}
