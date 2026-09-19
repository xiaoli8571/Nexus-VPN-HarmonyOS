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
  /**
   * 服务端返回的 ETag（`ETag` / `Last-Modified`），供下次带 `If-None-Match` 条件请求。
   * 空串 = 服务端未给，下次仍做完整拉取。
   */
  etag: string = '';
  /**
   * 是否 304 Not Modified —— 服务端确认内容未变（本次没有响应体）。
   * 调用方据此走「未变更」路径（沿用已落盘节点），而不是把空响应当成失败。
   */
  notModified: boolean = false;
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
  /**
   * 面向用户的可操作建议（如「请先连接 VPN 再重试」）。空串表示无需额外提示。
   * 与 message 分开是因为 message 里含 URL 与原始错误码，适合日志，
   * 而卡片/弹窗要展示的是人话 + 下一步该干什么。
   */
  advice: string = '';
  /** 传输层失败（无 HTTP 响应）：换 UA 不可能修好，用于终止 UA 链。 */
  transportFailure: boolean = false;

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
  /**
   * 依次尝试 UA 链，返回第一个非空响应体。HTTP 仅在调用方显式接受风险时启用。
   *
   * @param etag 上次成功拉取拿到的 ETag（可空）。非空时带 `If-None-Match`：
   *   面板内容未变会回 304，省掉整份订阅的下载与解析（对齐 FlClash/Clash Verge
   *   的增量刷新语义）。
   */
  static async fetch(urlStr: string, headerName: string, headerValue: string,
    allowInsecureHttp: boolean = false, etag: string = ''): Promise<SubscriptionFetchResult> {
    if (!SubscriptionFetchPolicy.isValidSubscriptionUrl(urlStr, allowInsecureHttp)) {
      throw new SubscriptionFetchError(SubscriptionFetchErrorKind.HTTP,
        '订阅地址无效：仅允许公开 HTTPS 地址');
    }
    const customHeader = headerName.length > 0 && headerValue.length > 0;
    const attempts: string[] = [];
    // 整条 UA 链里出现过的 HTTP 状态码（用于区分限流与其它错误；优先保留 429/403）
    let rateLimitStatus = 0;
    let lastHttpStatus = 0;
    // 首个传输层失败（无 HTTP 状态）的原始消息，用于生成可读原因
    let transportMessage = '';
    let transportAttempts = 0;
    for (let i = 0; i < UA_CHAIN.length; i++) {
      const ua = customHeader ? headerValue : UA_CHAIN[i];
      try {
        const headers: Record<string, string> = {};
        if (customHeader && SubscriptionFetchPolicy.maySendCustomHeader(urlStr, headerName)) {
          headers[headerName] = ua;
        } else {
          headers['User-Agent'] = ua;
        }
        if (etag.length > 0) {
          headers['If-None-Match'] = etag;
        }
        const result = await SubscriptionFetchPolicy.requestWithRedirectValidation(
          urlStr, headers, allowInsecureHttp, 0);
        if (result.notModified) {
          // 304：内容未变。与「响应为空」是完全不同的语义，必须原样返回给调用方，
          // 绝不能落到下面的 EMPTY_RESPONSE 分支（那会把「没变化」报成「拉取失败」）。
          AppLogger.info(TAG, 'subscription not modified (304), reusing cached nodes');
          return result;
        }
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
        } else {
          // 传输层失败（DNS/连接/TLS/超时，拿不到任何 HTTP 状态）。
          //
          // UA 链的用途是**内容协商**（同一个 200 因 UA 不同而返回 YAML 或链接列表），
          // 它修不好「这个域名根本连不上」。此前这里继续把剩下 4 个 UA 跑完，
          // 每个都要吃满 connectTimeout，实测一次被阻断的域名要用户干等
          // 5 × 15s = 75s 才拿到结论。主流客户端（Clash Verge Rev / CMFA）本来
          // 就只发一个 UA、失败即止，没有这种重试。所以这里立即收束。
          transportAttempts = transportAttempts + 1;
          if (transportMessage.length === 0) {
            transportMessage = msg;
          }
          break;
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
    // 网络失败：message 保留原始错误码（日志用），advice 给出人话 + 下一步（UI 用）
    const err = new SubscriptionFetchError(SubscriptionFetchErrorKind.NETWORK,
      `订阅拉取失败（${SubscriptionFetchPolicy.redactUrl(urlStr)}）：${summary}`);
    err.transportFailure = transportAttempts > 0;
    err.advice = SubscriptionFetchPolicy.transportAdvice(transportMessage, urlStr);
    throw err;
  }

  /**
   * 把传输层原始错误翻译成用户能看懂的原因 + 该怎么做。
   * 只做关键词归类（各平台错误码不统一），拿不准就退回通用文案，
   * 绝不臆断具体原因。
   */
  static transportAdvice(rawMessage: string, urlStr: string): string {
    const msg = rawMessage.toLowerCase();
    let cause = '';
    if (msg.includes('未解析到地址') || msg.includes('enotfound')
      || msg.includes('nodename') || msg.includes('name not resolved')
      || msg.includes('getaddressesbyname')) {
      cause = '域名无法解析';
    } else if (msg.includes('timeout') || msg.includes('超时') || msg.includes('2300028')
      || msg.includes('2300034') || msg.includes('timed out')) {
      cause = '连接超时';
    } else if (msg.includes('reset') || msg.includes('errno=104') || msg.includes('econnreset')
      || msg.includes('broken pipe') || msg.includes('aborted')) {
      cause = '连接被重置';
    } else if (msg.includes('ssl') || msg.includes('tls') || msg.includes('certificate')
      || msg.includes('handshake')) {
      cause = 'TLS 握手失败';
    } else if (msg.includes('私网') || msg.includes('保留地址')) {
      cause = '地址被判定为内网或保留地址';
    } else if (msg.includes('超过') && msg.includes('限制')) {
      cause = '响应体超过大小限制';
    } else {
      cause = '无法连接到该地址';
    }
    let advice = `该订阅地址${cause}。`;
    if (cause === '连接超时' || cause === '连接被重置' || cause === 'TLS 握手失败'
      || cause === '无法连接到该地址') {
      // 这是最常见的一类：域名在本地网络被阻断，而 App 的订阅拉取不走代理。
      advice += '若该地址在浏览器/电脑客户端也要挂代理才能打开，请先连接 VPN 后重试；'
        + '或改用可直连的订阅地址。';
    } else if (cause === '域名无法解析') {
      advice += '请检查地址是否写错，或更换 DNS/网络后重试。';
    }
    return advice;
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
      if (resp.responseCode === 304) {
        // 条件请求命中：内容未变，无响应体。etag 原样回传（服务端可能刷新了 ETag）。
        const notModified = new SubscriptionFetchResult();
        notModified.notModified = true;
        notModified.etag = SubscriptionFetchPolicy.responseEtag(resp.header);
        notModified.userInfo = SubscriptionFetchPolicy.parseUserInfo(
          SubscriptionFetchPolicy.headerValue(resp.header, 'subscription-userinfo'));
        return notModified;
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
      out.etag = SubscriptionFetchPolicy.responseEtag(resp.header);
      return out;
    } finally {
      req.destroy();
    }
  }

  /**
   * 取响应的 ETag 作为条件请求凭据；服务端只给 Last-Modified 时退而用后者
   * （两者都是合法的 If-None-Match 值来源）。
   */
  private static responseEtag(header: Object): string {
    const etag = SubscriptionFetchPolicy.headerValue(header, 'etag');
    if (etag.length > 0) {
      return etag;
    }
    return SubscriptionFetchPolicy.headerValue(header, 'last-modified');
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
