/**
 * proxy-providers 提取器（漏洞 C）
 *
 * Clash / Mihomo 配置允许把节点放在   proxy-providers   段（远程 http(s) provider 或
 * 本地 file 文件），而   proxies   段只留少量甚至为空。此前 SSRVPN 只读 proxies，
 * 于是「订阅少节点」且界面没有任何提示（用户看到 0 节点或只剩几个节点）。
 *
 * 本文件只做一件事：从 YAML 文本中提取 provider 条目（name / type / url / interval /
 * path 等）。真正的拉取与合并由 SubscriptionService 完成 —— provider 内容必须走与
 * 主订阅完全相同的 UA 降级链与解析链，并计入同一次导入的诊断。
 *
 * 支持的写法（均为常见面板输出形态）：
 *   proxy-providers:
 *     provider1:
 *       type: http
 *       url: "https://example.com/sub"
 *       interval: 3600
 *       path: ./providers/provider1.yaml
 *     provider2: {type: http, url: "https://example.com/sub2", interval: 7200}
 *   proxy-providers:
 *     - name: provider3
 *       type: file
 *       path: ./providers/p3.yaml
 */
import { AppLogger } from '../utils/AppLogger';

const TAG = 'ProxyProviderParser';
/** 单次导入允许拉取的 provider 上限（防恶意配置把刷新变成 N 次网络请求） */
export const MAX_PROVIDERS = 64;
/** url/path 最大长度（超过视为脏数据直接忽略该字段） */
const MAX_VALUE_LENGTH = 8192;

export class ProxyProviderEntry {
  name: string = '';
  type: string = '';
  url: string = '';
  path: string = '';
  interval: number = 0;

  /** 类型是否支持（http/https 指向远程订阅内容，本客户端可拉取） */
  isSupportedType(): boolean {
    return this.type === 'http' || this.type === 'https';
  }

  /** 是否具备拉取条件（类型支持且 url 非空） */
  isFetchable(): boolean {
    return this.isSupportedType() && this.url.length > 0;
  }
}

export class ProxyProviderParser {
  /** 去掉成对的引号（'...' / "..."），并裁剪空白 */
  private static unquote(raw: string): string {
    let value = raw.trim();
    if (value.length >= 2) {
      const first = value.charAt(0);
      const last = value.charAt(value.length - 1);
      if ((first === '"' && last === '"') || (first === '\'' && last === '\'')) {
        value = value.substring(1, value.length - 1).trim();
      }
    }
    return value;
  }

  /** 写入一个 key: value（仅识别 name/type/url/path/interval） */
  private static applyPair(entry: ProxyProviderEntry, rawKey: string, rawValue: string): void {
    const key = ProxyProviderParser.unquote(rawKey).toLowerCase();
    const value = ProxyProviderParser.unquote(rawValue);
    if (key === 'name') {
      if (value.length > 0 && value.length <= 4096) {
        entry.name = value;
      }
    } else if (key === 'type') {
      entry.type = value.toLowerCase();
    } else if (key === 'url') {
      if (value.length <= MAX_VALUE_LENGTH) {
        entry.url = value;
      }
    } else if (key === 'path') {
      if (value.length <= MAX_VALUE_LENGTH) {
        entry.path = value;
      }
    } else if (key === 'interval') {
      const seconds = Number(value);
      if (Number.isInteger(seconds) && seconds >= 0) {
        entry.interval = seconds;
      }
    }
  }

  /** 解析 "key: value" 行；无冒号或键为空时返回 false */
  private static applyLine(entry: ProxyProviderEntry, text: string): boolean {
    const idx = text.indexOf(':');
    if (idx <= 0) {
      return false;
    }
    ProxyProviderParser.applyPair(entry, text.substring(0, idx), text.substring(idx + 1));
    return true;
  }

  /** 解析 flow-map 值 {k: v, k2: v2}（引号内的逗号不参与切分） */
  private static applyFlowMap(entry: ProxyProviderEntry, flow: string): void {
    const text = flow.trim();
    if (!text.startsWith('{') || !text.endsWith('}')) {
      return;
    }
    const inner = text.substring(1, text.length - 1);
    const parts: string[] = [];
    let current = '';
    let quote = '';
    for (let i = 0; i < inner.length; i++) {
      const ch = inner.charAt(i);
      if (quote.length > 0) {
        current += ch;
        if (ch === quote) {
          quote = '';
        }
      } else if (ch === '"' || ch === '\'') {
        quote = ch;
        current += ch;
      } else if (ch === ',') {
        parts.push(current);
        current = '';
      } else {
        current += ch;
      }
    }
    parts.push(current);
    for (const part of parts) {
      if (part.trim().length > 0) {
        ProxyProviderParser.applyLine(entry, part.trim());
      }
    }
  }

  /**
   * 提取 proxy-providers 条目。解析失败/脏条目直接忽略（不影响其它条目），
   * 超过 MAX_PROVIDERS 的部分截断（调用方通过返回值长度与日志可见）。
   */
  static parse(yaml: string): ProxyProviderEntry[] {
    const out: ProxyProviderEntry[] = [];
    if (yaml.indexOf('proxy-providers:') < 0) {
      return out;
    }
    const section = ProxyProviderParser.sectionLines(yaml);
    let current: ProxyProviderEntry | null = null;
    const flush = (): void => {
      if (current === null) {
        return;
      }
      const entry = current;
      current = null;
      if (entry.name.length === 0 && entry.url.length === 0) {
        return;
      }
      if (entry.name.length === 0) {
        entry.name = entry.url;
      }
      out.push(entry);
    };
    for (const rawLine of section) {
      const trimmed = rawLine.trim();
      if (trimmed.length === 0 || trimmed.startsWith('#')) {
        continue;
      }
      const indent = rawLine.length - rawLine.trimStart().length;
      if (indent <= 2) {
        // 顶层条目：映射形式 "name:" 或序列形式 "- name: x" / "- {..}"
        flush();
        current = new ProxyProviderEntry();
        let body = trimmed;
        if (body.startsWith('- ')) {
          body = body.substring(2).trim();
        } else if (body.startsWith('-')) {
          continue;
        }
        if (body.endsWith(':') && body.indexOf('{') < 0) {
          current.name = ProxyProviderParser.unquote(body.substring(0, body.length - 1));
        } else if (body.indexOf('{') > 0) {
          const brace = body.indexOf('{');
          const head = body.substring(0, brace);
          if (head.trim().endsWith(':')) {
            current.name = ProxyProviderParser.unquote(head.trim().substring(0, head.trim().length - 1));
          }
          ProxyProviderParser.applyFlowMap(current, body.substring(brace));
        } else {
          ProxyProviderParser.applyLine(current, body);
        }
        continue;
      }
      if (current === null) {
        continue;
      }
      if (trimmed.startsWith('{')) {
        ProxyProviderParser.applyFlowMap(current, trimmed);
      } else {
        ProxyProviderParser.applyLine(current, trimmed);
      }
    }
    flush();
    if (out.length > MAX_PROVIDERS) {
      AppLogger.warn(TAG, `proxy-providers truncated: ${out.length} -> ${MAX_PROVIDERS}`);
      return out.slice(0, MAX_PROVIDERS);
    }
    if (out.length > 0) {
      AppLogger.info(TAG, `parsed ${out.length} proxy-provider entr(ies)`);
    }
    return out;
  }

  /** 提取 proxy-providers 段的原始行（保留缩进，便于判定层级） */
  private static sectionLines(yaml: string): string[] {
    const out: string[] = [];
    let inSection = false;
    for (let line of yaml.split('\n')) {
      if (line.endsWith('\r')) {
        line = line.substring(0, line.length - 1);
      }
      if (line.startsWith('\uFEFF')) {
        line = line.substring(1);
      }
      if (!line.startsWith(' ') && !line.startsWith('\t')) {
        const trimmed = line.trim();
        if (trimmed.startsWith('proxy-providers:')) {
          inSection = true;
          continue;
        }
        if (inSection && trimmed.length > 0 && !trimmed.startsWith('#')) {
          break;
        }
      }
      if (inSection) {
        out.push(line);
      }
    }
    return out;
  }

  /** 不支持（本客户端无法拉取）的 provider 类型清单，去重后按 name(type) 形式给出 */
  static unsupportedTypes(entries: ProxyProviderEntry[]): string {
    const seen = new Set<string>();
    for (const e of entries) {
      if (e.isSupportedType()) {
        continue;
      }
      const type = e.type.length > 0 ? e.type : 'unknown';
      seen.add(type);
    }
    return Array.from(seen).join(',');
  }

  /** 支持的 http/https provider（需要拉取并合并） */
  static fetchable(entries: ProxyProviderEntry[]): ProxyProviderEntry[] {
    const out: ProxyProviderEntry[] = [];
    for (const e of entries) {
      if (e.isFetchable()) {
        out.push(e);
      }
    }
    return out;
  }

  /** 类型受支持但缺少 url 的 provider（提示用，不算失败） */
  static missingUrl(entries: ProxyProviderEntry[]): number {
    let count = 0;
    for (const e of entries) {
      if (e.isSupportedType() && e.url.length === 0) {
        count = count + 1;
      }
    }
    return count;
  }
}
