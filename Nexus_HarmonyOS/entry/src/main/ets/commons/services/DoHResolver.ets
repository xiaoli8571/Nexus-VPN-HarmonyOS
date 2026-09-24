/**
 * DoH 解析器（UI 进程）—— 代理服务器域名的防投毒解析。
 *
 * 背景: 明文 UDP DNS 会被 GFW 按域名投毒(真机实测: 代理服务器域名被追加注入
 * Cloudflare/NS 段假记录, 与权威应答混在一起, 内核拨到假地址全线 i/o timeout,
 * 表现为"连上了但 YouTube 等全部打不开")。DoH 是 HTTPS 加密查询, 注入无法篡改;
 * 权威直查 + doh.pub + 阿里 DoH + 腾讯 UDP 四方比对验证过: DoH 应答与权威一致,
 * pin 的就是唯一真实记录。
 *
 * 必须在 UI 进程、VPN 隧道建立之前调用(此时网络干净)。解析结果写进 YAML 的
 * hosts: 段, 内核直接用真实 IP 拨号代理服务器, 彻底绕开运行期被污染的 DNS。
 * 未解析出的域名不 pin(内核回退 proxy-server-nameserver), 但连接时会有日志点名。
 */
import { http } from '@kit.NetworkKit';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'DoHResolver';
// 阿里 DoH 的 GET-JSON 入口是 /resolve(/dns-query 只收 wire-format, GET JSON 会 400,
// 真机旧版就是因此少了一个可用端点, doh.pub 瞬时超时时域名直接漏 pin)。
const ENDPOINTS: string[] = ['https://doh.pub/dns-query', 'https://dns.alidns.com/resolve'];

/** DoH JSON 应答结构(只取需要的字段) */
interface DoHAnswer {
  name: string;
  type: number;
  data: string;
}

interface DoHResponse {
  Status: number;
  Answer?: DoHAnswer[];
}

export class DoHResolver {
  /** 跨连接缓存: domain -> ip, 避免每次连接重复解析。限制容量，防止订阅频繁变化后常驻增长。 */
  private static cache: Map<string, string> = new Map<string, string>();
  private static readonly CACHE_MAX_ENTRIES: number = 512;
  /** 并发度: 一次 TLS 握手 + 查询约 200-400ms, 16 路足够 3s 内清几十上百个域名 */
  private static readonly WORKERS: number = 16;

  /**
   * 批量解析多个域名(去重后), 带全局时间预算。跑两轮: 第一轮失败的域名
   * (端点瞬时超时/限流)在预算内重试一轮 —— 真机实测单个端点偶发失败会直接
   * 漏 pin(如 chuixuevl1), 两轮 + 双端点把漏 pin 概率压到接近零。
   * 预算耗尽未解析的域名跳过(内核回退 proxy-server-nameserver)。
   */
  static async resolveMany(domains: string[], budgetMs: number = 6000): Promise<Record<string, string>> {
    const result: Record<string, string> = {};
    const seen = new Set<string>();
    let pending: string[] = [];
    for (const raw of domains) {
      const d = raw.toLowerCase();
      if (seen.has(d)) {
        continue;
      }
      seen.add(d);
      const cached = DoHResolver.cache.get(d);
      if (cached !== undefined && cached.length > 0) {
        result[d] = cached;
      } else {
        pending.push(d);
      }
    }
    if (pending.length === 0) {
      return result;
    }
    const deadline = Date.now() + budgetMs;
    for (let pass = 0; pass < 2 && pending.length > 0; pass++) {
      const current: string[] = pending;
      const remaining: string[] = [];
      const workers: Promise<void>[] = [];
      let idx = 0;
      for (let w = 0; w < DoHResolver.WORKERS; w++) {
        workers.push((async (): Promise<void> => {
          for (;;) {
            if (Date.now() > deadline) {
              return;
            }
            const i = idx;
            idx = idx + 1;
            if (i >= current.length) {
              return;
            }
            const d = current[i];
            const ip = await DoHResolver.resolveA(d);
            if (ip.length > 0) {
              DoHResolver.cachePut(d, ip);
              result[d] = ip;
            } else if (pass === 0) {
              remaining.push(d);
            }
          }
        })());
      }
      await Promise.all(workers);
      if (Date.now() > deadline) {
        // 预算已尽: 剩余(含本轮未处理到的)域名放弃 pin, 记日志便于排查
        const unpinned: string[] = remaining.slice();
        for (const d of current) {
          if (result[d] === undefined && !unpinned.includes(d)) {
            unpinned.push(d);
          }
        }
        if (unpinned.length > 0) {
          AppLogger.warn(TAG, `budget exhausted, unpinned: ${unpinned.slice(0, 12).join(', ')}`);
        }
        break;
      }
      pending = remaining;
      if (pass === 0 && remaining.length > 0) {
        AppLogger.info(TAG, `retry ${remaining.length} domains: ${remaining.slice(0, 8).join(', ')}`);
      }
    }
    return result;
  }

  /** 解析单个域名的 A 记录; 失败返回空串(调用方回退到 proxy-server-nameserver) */
  static async resolveA(domain: string): Promise<string> {
    const cached = DoHResolver.cache.get(domain);
    if (cached !== undefined && cached.length > 0) {
      return cached;
    }
    for (const ep of ENDPOINTS) {
      const req = http.createHttp();
      try {
        const queryUrl = ep + '?name=' + encodeURIComponent(domain) + '&type=A';
        const resp = await req.request(queryUrl, {
          method: http.RequestMethod.GET,
          header: {
            'Accept': 'application/dns-json',
            'User-Agent': 'Mozilla/5.0'
          } as Record<string, string>,
          connectTimeout: 2500,
          readTimeout: 2500,
          expectDataType: http.HttpDataType.STRING,
          usingCache: false
        } as http.HttpRequestOptions);
        const code = resp.responseCode;
        let body = '';
        if (typeof resp.result === 'string') {
          body = resp.result as string;
        }
        if (code !== 200 || body.length === 0) {
          continue;
        }
        const parsed = JSON.parse(body) as DoHResponse;
        if (parsed.Status !== 0 || parsed.Answer === undefined) {
          continue;
        }
        for (const a of parsed.Answer) {
          // type 1 = A; data 是 IPv4 点分十进制
          if (a.type === 1 && DoHResolver.looksLikeIPv4(a.data)) {
            DoHResolver.cachePut(domain, a.data);
            return a.data;
          }
        }
      } catch (e) {
        AppLogger.info(TAG, `DoH ${ep} for ${domain} failed: ${AppLogger.errText(e)}`);
      } finally {
        req.destroy();
      }
    }
    return '';
  }

  private static looksLikeIPv4(s: string): boolean {
    const parts = s.split('.');
    if (parts.length !== 4) {
      return false;
    }
    for (const p of parts) {
      const n = Number(p);
      if (Number.isNaN(n) || n < 0 || n > 255 || `${n}` !== p) {
        return false;
      }
    }
    return true;
  }

  /** Map 保持插入顺序；命中时移到末尾，并淘汰最久未使用的条目。 */
  private static cachePut(domain: string, ip: string): void {
    if (DoHResolver.cache.has(domain)) {
      DoHResolver.cache.delete(domain);
    }
    DoHResolver.cache.set(domain, ip);
    while (DoHResolver.cache.size > DoHResolver.CACHE_MAX_ENTRIES) {
      const oldest = DoHResolver.cache.keys().next();
      if (oldest.done) {
        break;
      }
      DoHResolver.cache.delete(oldest.value);
    }
  }
}
