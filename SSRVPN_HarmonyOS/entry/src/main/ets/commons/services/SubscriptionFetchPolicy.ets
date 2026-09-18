/**
 * 订阅拉取策略：UA 协商
 * 移植自 upstream: packages/ssrvpn_shared/lib/services/subscription_fetch_policy.dart
 *
 * UA 顺序（必须一致）：SSRVPN → Clash Verge → v2rayN → Shadowrocket。
 * 每次降级重试都在 HTTP 403/406 或空结果时触发。
 */
import { http, connection } from '@kit.NetworkKit';
import { url, util } from '@kit.ArkTS';
import { AppLogger } from '../utils/AppLogger';
import { AppInfo } from '../utils/AppInfo';

const TAG = 'SubscriptionFetchPolicy';
const MAX_RESPONSE_BYTES = 8 * 1024 * 1024;
const MAX_FIELD_LENGTH = 4096;
const MAX_NODE_COUNT = 2000;
const MAX_REDIRECTS = 5;

/**
 * UA 顺序：优先 Clash 系 UA 让面板直接返回 Clash YAML（vmess/vless/trojan 字段最完整），
 * 其余 UA 依次兜底；解析层同时支持 vless/vmess/trojan 链接格式。
 * SSRVPN 自家 UA 携带实时版本（AppInfo 单一来源, 不再硬编码）。
 */
export const UA_CHAIN: string[] = [
  'clash-verge/v1.7.7',
  'clash.meta/v1.18.8',
  'SSRVPN/' + AppInfo.version(),
  'v2rayN/6.23',
  'Shadowrocket/2077'
];

export class SubscriptionUserInfo {
  uploadBytes: number = -1;
  downloadBytes: number = -1;
  totalBytes: number = -1;
  expireAt: number = -1;
}

export class SubscriptionFetchResult {
  body: string = '';
  userInfo: SubscriptionUserInfo = new SubscriptionUserInfo();
}

export enum SubscriptionFetchErrorKind {
  NETWORK = 'network',
  HTTP = 'http',
  EMPTY_RESPONSE = 'emptyResponse',
  DECODE = 'decode'
}

/** 保留拉取失败边界，供 SubscriptionService 映射为准确的刷新状态。 */
export class SubscriptionFetchError extends Error {
  kind: SubscriptionFetchErrorKind;
  /**
   * 失败时的 HTTP 状态码（0 = 不适用/未知）。429/403 需要与普通 http 错误区分：
   * 面板限流与「地址写错」的用户提示完全不同（漏洞 6：429/403 vs 200 但 0 条目）。
   */
  httpStatus: number = 0;

  constructor(kind: SubscriptionFetchErrorKind, message: string, httpStatus: number = 0) {
    super(message);
    this.kind = kind;
    this.httpStatus = httpStatus;
  }

  /** 面板限流/拒绝访问 */
  isRateLimited(): boolean {
    return this.kind === SubscriptionFetchErrorKind.HTTP
      && (this.httpStatus === 429 || this.httpStatus === 403);
  }
}

export class SubscriptionFetchPolicy {
  /** 依次尝试 UA 链，返回第一个非空响应体。HTTP 仅在调用方显式接受风险时启用。 */
  static async fetch(urlStr: string, headerName: string, headerValue: string,
    allowInsecureHttp: boolean = false): Promise<SubscriptionFetchResult> {
    if (!SubscriptionFetchPolicy.isValidSubscriptionUrl(urlStr, allowInsecureHttp)) {
      throw new SubscriptionFetchError(SubscriptionFetchErrorKind.HTTP,
        '订阅地址无效：仅允许公开 HTTPS 地址');
    }
    const customHeader = headerName.length > 0 && headerValue.length > 0;
    const attempts: string[] = [];
    // 整条 UA 链里出现过的 HTTP 状态码（用于区分限流与其它错误；优先保留 429/403）
    let rateLimitStatus = 0;
    let lastHttpStatus = 0;
    for (let i = 0; i < UA_CHAIN.length; i++) {
      const ua = customHeader ? headerValue : UA_CHAIN[i];
      try {
        const headers: Record<string, string> = {};
        if (customHeader && SubscriptionFetchPolicy.maySendCustomHeader(urlStr, headerName)) {
          headers[headerName] = ua;
        } else {
          headers['User-Agent'] = ua;
        }
        const result = await SubscriptionFetchPolicy.requestWithRedirectValidation(
          urlStr, headers, allowInsecureHttp, 0);
        if (result.body.length > 0) {
          AppLogger.info(TAG, `subscription fetched (${result.body.length} bytes)`);
          return result;
        }
        attempts.push('响应为空');
      } catch (e) {
        const msg = AppLogger.errText(e);
        AppLogger.warn(TAG, `subscription fetch attempt failed: ${msg}`);
        attempts.push(msg);
        const status = SubscriptionFetchPolicy.extractHttpStatus(e, msg);
        if (status === 429 || status === 403) {
          if (rateLimitStatus !== 429) {
            rateLimitStatus = status;
          }
        } else if (status > 0) {
          lastHttpStatus = status;
        }
      }
    }
    const summary = attempts.slice(0, 2).join(' / ');
    if (attempts.length > 0 && attempts.every((item: string) => item === '响应为空')) {
      throw new SubscriptionFetchError(SubscriptionFetchErrorKind.EMPTY_RESPONSE,
        `订阅响应为空（${SubscriptionFetchPolicy.redactUrl(urlStr)}）`);
    }
    if (rateLimitStatus > 0) {
      // 全 UA 链都拿到 429/403：面板限流/拒绝，而不是地址或网络问题
      throw new SubscriptionFetchError(SubscriptionFetchErrorKind.HTTP,
        `面板限流或拒绝访问（HTTP ${rateLimitStatus}，${UA_CHAIN.length} 个 UA 全部失败，`
        + `请稍后重试或更换订阅链接）：${summary}`, rateLimitStatus);
    }
    if (attempts.some((item: string) => item.startsWith('HTTP '))) {
      throw new SubscriptionFetchError(SubscriptionFetchErrorKind.HTTP,
        `订阅 HTTP 请求失败（${SubscriptionFetchPolicy.redactUrl(urlStr)}）：${summary}`,
        lastHttpStatus);
    }
    if (attempts.some((item: string) => item.includes('解码失败'))) {
      throw new SubscriptionFetchError(SubscriptionFetchErrorKind.DECODE,
        `订阅响应解码失败（${SubscriptionFetchPolicy.redactUrl(urlStr)}）：${summary}`);
    }
    throw new SubscriptionFetchError(SubscriptionFetchErrorKind.NETWORK,
      `订阅拉取失败（${SubscriptionFetchPolicy.redactUrl(urlStr)}）：${summary}`);
  }

  /** 从错误对象或消息文本中提取 HTTP 状态码（0 = 无） */
  private static extractHttpStatus(e: Object, msg: string): number {
    if (e instanceof SubscriptionFetchError && e.httpStatus > 0) {
      return e.httpStatus;
    }
    const m = msg.match(/HTTP\s+(\d{3})/);
    if (m === null) {
      return 0;
    }
    const code = Number(m[1]);
    return Number.isInteger(code) ? code : 0;
  }

  private static async requestWithRedirectValidation(urlStr: string, headers: Record<string, string>,
    allowInsecureHttp: boolean, redirectCount: number): Promise<SubscriptionFetchResult> {
    if (redirectCount > MAX_REDIRECTS) {
      throw new Error('订阅重定向次数超限');
    }
    await SubscriptionFetchPolicy.validateResolvedTarget(urlStr, allowInsecureHttp);
    const req = http.createHttp();
    try {
      const resp = await req.request(urlStr, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 15000,
        readTimeout: 20000,
        usingCache: false,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        maxRedirects: 0
      });
      if (resp.responseCode >= 300 && resp.responseCode < 400) {
        const location = SubscriptionFetchPolicy.headerValue(resp.header, 'location');
        if (location.length === 0) {
          throw new Error(`HTTP ${resp.responseCode} 重定向缺少 Location`);
        }
        const nextUrl = SubscriptionFetchPolicy.resolveRedirectUrl(urlStr, location);
        return SubscriptionFetchPolicy.requestWithRedirectValidation(
          nextUrl, SubscriptionFetchPolicy.redirectHeaders(headers, nextUrl), allowInsecureHttp, redirectCount + 1);
      }
      if (resp.responseCode !== 200) {
        throw new SubscriptionFetchError(SubscriptionFetchErrorKind.HTTP, `HTTP ${resp.responseCode}`);
      }
      let bytes = 0;
      let body = '';
      if (resp.result instanceof ArrayBuffer) {
        bytes = resp.result.byteLength;
        if (!SubscriptionFetchPolicy.isResponseSizeAllowed(bytes)) {
          throw new Error('订阅响应体超过 8 MiB 限制');
        }
        try {
          body = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(resp.result));
        } catch (e) {
          throw new SubscriptionFetchError(SubscriptionFetchErrorKind.DECODE,
            `响应 UTF-8 解码失败：${AppLogger.errText(e)}`);
        }
      } else if (typeof resp.result === 'string') {
        body = resp.result as string;
        bytes = body.length;
        if (!SubscriptionFetchPolicy.isResponseSizeAllowed(bytes)) {
          throw new Error('订阅响应体超过 8 MiB 限制');
        }
      }
      const out = new SubscriptionFetchResult();
      out.body = body.trim();
      out.userInfo = SubscriptionFetchPolicy.parseUserInfo(
        SubscriptionFetchPolicy.headerValue(resp.header, 'subscription-userinfo'));
      return out;
    } finally {
      req.destroy();
    }
  }

  private static async validateResolvedTarget(urlStr: string, allowInsecureHttp: boolean): Promise<void> {
    if (!SubscriptionFetchPolicy.isValidSubscriptionUrl(urlStr, allowInsecureHttp)) {
      throw new Error('订阅目标不是允许的公开地址');
    }
    const parsed = url.URL.parseURL(urlStr);
    const host = SubscriptionFetchPolicy.extractHost(parsed.host);
    if (host.includes(':') || /^\d{1,3}(\.\d{1,3}){3}$/.test(host)) {
      if (!SubscriptionFetchPolicy.isPublicIpAddress(host)) {
        throw new Error('订阅目标命中私网或保留地址');
      }
      return;
    }
    const addresses = await connection.getAddressesByName(host);
    if (addresses.length === 0) {
      throw new Error('订阅域名未解析到地址');
    }
    for (const address of addresses) {
      if (SubscriptionFetchPolicy.isPublicIpAddress(address.address)) {
        continue;
      }
      // Mihomo fake-ip DNS（本应用隧道开启时接管系统解析）会把所有域名解析到
      // 198.18.0.0/15（IPv6 fc00::/18）。该网段不可能承载真实服务：
      // 无隧道时连它必然失败（无 SSRF 风险），有隧道时连接会被本应用 TUN 截获
      // 并按域名回源 —— 属预期路径。此前该场景被误判为「私网/保留地址」拦截，
      // 导致「VPN 开启后刷新订阅」必然失败，这里无条件放行 fake-ip 网段。
      if (SubscriptionFetchPolicy.isFakeIp(address.address)) {
        continue;
      }
      throw new Error('订阅域名解析到私网或保留地址');
    }
  }

  private static headerValue(header: Object, name: string): string {
    const values = JSON.parse(JSON.stringify(header)) as Record<string, Object>;
    for (const key of Object.keys(values)) {
      if (key.toLowerCase() === name.toLowerCase()) {
        const value = values[key];
        if (typeof value === 'string') {
          return value as string;
        }
        if (Array.isArray(value) && value.length > 0) {
          return String(value[0]);
        }
      }
    }
    return '';
  }

  static parseUserInfo(value: string): SubscriptionUserInfo {
    const out = new SubscriptionUserInfo();
    for (const item of value.split(';')) {
      const pair = item.trim().split('=');
      if (pair.length !== 2 || !/^\d+$/.test(pair[1].trim())) {
        continue;
      }
      const numberValue = Number(pair[1].trim());
      if (!Number.isSafeInteger(numberValue) || numberValue < 0) {
        continue;
      }
      const key = pair[0].trim().toLowerCase();
      if (key === 'upload') out.uploadBytes = numberValue;
      else if (key === 'download') out.downloadBytes = numberValue;
      else if (key === 'total') out.totalBytes = numberValue;
      else if (key === 'expire') out.expireAt = numberValue * 1000;
    }
    return out;
  }

  private static resolveRedirectUrl(currentUrl: string, location: string): string {
    if (location.startsWith('https://') || location.startsWith('http://')) {
      return location;
    }
    const parsed = url.URL.parseURL(currentUrl);
    const origin = `${parsed.protocol}//${parsed.host}`;
    if (location.startsWith('/')) {
      return origin + location;
    }
    const slash = parsed.pathname.lastIndexOf('/');
    const base = slash >= 0 ? parsed.pathname.substring(0, slash + 1) : '/';
    return origin + base + location;
  }

  private static redirectHeaders(headers: Record<string, string>, nextUrl: string): Record<string, string> {
    const out: Record<string, string> = {};
    for (const key of Object.keys(headers)) {
      if (SubscriptionFetchPolicy.maySendCustomHeader(nextUrl, key)) {
        out[key] = headers[key];
      }
    }
    return out;
  }

  private static extractHost(authority: string): string {
    const lower = authority.toLowerCase();
    if (lower.startsWith('[')) {
      const close = lower.indexOf(']');
      return close > 0 ? lower.substring(1, close) : '';
    }
    const colon = lower.lastIndexOf(':');
    return colon >= 0 && lower.indexOf(':') === colon ? lower.substring(0, colon) : lower;
  }

  private static parseIpv4(value: string): number[] | null {
    const match = value.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
    if (match === null) {
      return null;
    }
    const parts: number[] = [Number(match[1]), Number(match[2]), Number(match[3]), Number(match[4])];
    for (const part of parts) {
      if (part < 0 || part > 255) {
        return null;
      }
    }
    return parts;
  }

  private static expandIpv6(value: string): number[] | null {
    let normalized = value.toLowerCase();
    if (!/^[0-9a-f:.]+$/.test(normalized) || normalized.includes('%')) {
      return null;
    }
    const lastColon = normalized.lastIndexOf(':');
    const ipv4Tail = normalized.substring(lastColon + 1);
    if (ipv4Tail.includes('.')) {
      const ipv4 = SubscriptionFetchPolicy.parseIpv4(ipv4Tail);
      if (ipv4 === null) {
        return null;
      }
      normalized = normalized.substring(0, lastColon + 1)
        + ((ipv4[0] << 8) | ipv4[1]).toString(16) + ':'
        + ((ipv4[2] << 8) | ipv4[3]).toString(16);
    }
    const halves = normalized.split('::');
    if (halves.length > 2) {
      return null;
    }
    const left: string[] = halves[0].length === 0 ? [] : halves[0].split(':');
    const right: string[] = halves.length === 1 || halves[1].length === 0 ? [] : halves[1].split(':');
    if ((halves.length === 1 && left.length !== 8)
      || (halves.length === 2 && left.length + right.length >= 8)) {
      return null;
    }
    const groups: number[] = [];
    for (const item of left) {
      if (!/^[0-9a-f]{1,4}$/.test(item)) {
        return null;
      }
      groups.push(parseInt(item, 16));
    }
    if (halves.length === 2) {
      while (groups.length + right.length < 8) {
        groups.push(0);
      }
    }
    for (const item of right) {
      if (!/^[0-9a-f]{1,4}$/.test(item)) {
        return null;
      }
      groups.push(parseInt(item, 16));
    }
    return groups.length === 8 ? groups : null;
  }

  static isPublicIpAddress(address: string): boolean {
    const value = address.trim().toLowerCase();
    const ipv4 = SubscriptionFetchPolicy.parseIpv4(value);
    if (ipv4 !== null) {
      const a = ipv4[0];
      const b = ipv4[1];
      const c = ipv4[2];
      const d = ipv4[3];
      return !(a === 0 || a === 10 || a === 127 || a >= 224
        || (a === 100 && b >= 64 && b <= 127)
        || (a === 169 && b === 254)
        || (a === 172 && b >= 16 && b <= 31)
        || (a === 192 && b === 0)
        || (a === 192 && b === 168)
        || (a === 198 && (b === 18 || b === 19))
        || (a === 198 && b === 51 && c === 100)
        || (a === 203 && b === 0 && c === 113)
        || (a === 255 && b === 255 && c === 255 && d === 255));
    }
    const groups = SubscriptionFetchPolicy.expandIpv6(value);
    if (groups === null) {
      return false;
    }
    const allZero = groups.every((part) => part === 0);
    const loopback = groups.slice(0, 7).every((part) => part === 0) && groups[7] === 1;
    const mappedIpv4 = groups.slice(0, 5).every((part) => part === 0) && groups[5] === 0xffff;
    if (mappedIpv4) {
      return SubscriptionFetchPolicy.isPublicIpAddress(
        `${groups[6] >> 8}.${groups[6] & 255}.${groups[7] >> 8}.${groups[7] & 255}`);
    }
    return !(allZero || loopback
      || (groups[0] & 0xfe00) === 0xfc00
      || (groups[0] & 0xffc0) === 0xfe80
      || (groups[0] & 0xff00) === 0xff00
      || (groups[0] === 0x2001 && groups[1] === 0x0db8));
  }

  /**
   * Mihomo fake-ip 默认网段：IPv4 198.18.0.0/15（198.18/198.19，RFC 2544 基准测试保留段），
   * IPv6 为 fc00::/18。仅当本应用隧道开启时这些地址才是「预期路径」。
   */
  static isFakeIp(address: string): boolean {
    const value = address.trim().toLowerCase();
    const ipv4 = SubscriptionFetchPolicy.parseIpv4(value);
    if (ipv4 !== null) {
      return ipv4[0] === 198 && (ipv4[1] === 18 || ipv4[1] === 19);
    }
    const groups = SubscriptionFetchPolicy.expandIpv6(value);
    if (groups === null) {
      return false;
    }
    return (groups[0] & 0xffc0) === 0xfc00;
  }

  static maySendCustomHeader(urlStr: string, headerName: string): boolean {
    const lowerName = headerName.toLowerCase();
    if (lowerName === 'user-agent') {
      return true;
    }
    return urlStr.toLowerCase().startsWith('https://');
  }

  static isResponseSizeAllowed(size: number): boolean {
    return size >= 0 && size <= MAX_RESPONSE_BYTES;
  }

  static isFieldLengthAllowed(value: string): boolean {
    return value.length <= MAX_FIELD_LENGTH;
  }

  static isNodeCountAllowed(count: number): boolean {
    return count >= 0 && count <= MAX_NODE_COUNT;
  }

  /** URL 脱敏（只保留 host），配合 log_redactor */
  static redactUrl(urlStr: string): string {
    try {
      return url.URL.parseURL(urlStr).host;
    } catch (e) {
      return '<invalid-url>';
    }
  }

  /** 订阅 URL 合法性：默认仅允许 HTTPS；HTTP 必须由调用方显式开启。 */
  static isValidSubscriptionUrl(urlStr: string, allowInsecureHttp: boolean = false): boolean {
    const lower = urlStr.toLowerCase();
    if (urlStr.length === 0 || urlStr.length > 8192
      || (!lower.startsWith('https://') && !(allowInsecureHttp && lower.startsWith('http://')))
      || urlStr.includes('\n') || urlStr.includes('\r') || urlStr.includes('\t')) {
      return false;
    }
    try {
      const parsed = url.URL.parseURL(urlStr);
      const proto = parsed.protocol.replace(/:/g, '').toLowerCase();
      let authority = parsed.host.toLowerCase();
      if ((proto !== 'https' && !(allowInsecureHttp && proto === 'http'))
        || authority.length === 0 || authority.includes('@')) {
        return false;
      }

      let host = authority;
      let port = '';
      if (authority.startsWith('[')) {
        const close = authority.indexOf(']');
        if (close <= 1) {
          return false;
        }
        host = authority.substring(1, close);
        const suffix = authority.substring(close + 1);
        if (suffix.length > 0) {
          if (!suffix.startsWith(':')) {
            return false;
          }
          port = suffix.substring(1);
        }
      } else {
        const colon = authority.lastIndexOf(':');
        if (colon >= 0) {
          if (authority.indexOf(':') !== colon) {
            return false;
          }
          host = authority.substring(0, colon);
          port = authority.substring(colon + 1);
        }
      }
      if (host.length === 0 || (port.length > 0 && (!/^\d{1,5}$/.test(port)
        || parseInt(port) <= 0 || parseInt(port) > 65535))) {
        return false;
      }

      if (host === 'localhost' || host.endsWith('.localhost') || host.endsWith('.local')
        || host === 'localhost.localdomain' || host === 'ip6-localhost' || host === 'ip6-loopback'
        || host.endsWith('.internal') || host.endsWith('.home') || host.endsWith('.lan')) {
        return false;
      }

      if (SubscriptionFetchPolicy.parseIpv4(host) !== null || host.includes(':')) {
        return SubscriptionFetchPolicy.isPublicIpAddress(host);
      }

      if (host.length > 253 || host.startsWith('.') || host.endsWith('.') || host.includes('..')) {
        return false;
      }
      const labels = host.split('.');
      if (labels.length < 2) {
        return false;
      }
      for (const label of labels) {
        if (label.length === 0 || label.length > 63 || label.startsWith('-') || label.endsWith('-')
          || !/^[a-z0-9-]+$/.test(label)) {
          return false;
        }
      }
      return true;
    } catch (e) {
      return false;
    }
  }
}
