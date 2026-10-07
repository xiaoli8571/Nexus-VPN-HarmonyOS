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
import { SettingsService } from './SettingsService';

const TAG = 'DoHResolver';
// 阿里 DoH 的 GET-JSON 入口是 /resolve(/dns-query 只收 wire-format, GET JSON 会 400,
// 真机旧版就是因此少了一个可用端点, doh.pub 瞬时超时时域名直接漏 pin)。
const ENDPOINTS: string[] = ['https://doh.pub/dns-query', 'https://dns.alidns.com/resolve'];

/**
 * 新鲜期：缓存年龄在此之内视为可信，直接 pin 不重解析（连接路径零延迟）。
 * 取 12h 是权衡：机场节点域名多为泛解析/多 IP，24h 以上才可能明显漂移；
 * 12h 既覆盖绝大多数同日重连，又保证跨天使用前一定会刷新一次。
 */
const FRESH_TTL_MS = 12 * 60 * 60 * 1000;
/**
 * 可用上限：超过新鲜期但在此之内仍可 pin（宁可 pin 旧 IP 也不让它回落明文 DNS），
 * 同时立刻标记为需要后台刷新。超过此上限才彻底丢弃。
 */
const USABLE_TTL_MS = 7 * 24 * 60 * 60 * 1000;
/** 后台刷新的落盘节流（ms）：批量解析后合并成一次写盘。 */
const PERSIST_DEBOUNCE_MS = 2000;

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
  /** 跨连接缓存: domain -> ip。限制容量，防止订阅频繁变化后常驻增长。 */
  private static cache: Map<string, string> = new Map<string, string>();
  private static readonly CACHE_MAX_ENTRIES: number = 512;
  /** 并发度: 一次 TLS 握手 + 查询约 200-400ms, 16 路足够 3s 内清几十上百个域名 */
  private static readonly WORKERS: number = 16;
  /** 持久化缓存是否已从 SettingsService 载入（每进程一次） */
  private static loaded: boolean = false;
  /** 落盘节流定时器（-1 = 无挂起） */
  private static persistTimer: number = -1;
  /** 已过期但仍可用的 pin 域名，等后台刷新 */
  private static staleQueue: Set<string> = new Set<string>();

  /**
   * 载入跨进程持久化缓存（每进程一次）。
   *
   * 效果：应用被回收/冷启动后，第一次连接**零网络**即可拿到上次的 pin 结果 ——
   * 这段 DoH 预解析原本是连接路径上最贵的一步（并发 16、预算 6s，且发生在隧道建立
   * 之前，用户全程没网）。超出新鲜期的条目仍会被采用，但登记进 staleQueue 由后台刷新。
   */
  static async ensureLoaded(): Promise<void> {
    if (DoHResolver.loaded) {
      return;
    }
    DoHResolver.loaded = true;
    try {
      const persisted = await SettingsService.loadDohPins();
      const now = Date.now();
      let revived = 0;
      let stale = 0;
      for (const domain of Object.keys(persisted)) {
        const packed = persisted[domain];
        if (typeof packed !== 'string' || packed.length === 0) {
          continue;
        }
        const bar = packed.indexOf('|');
        const ip = bar > 0 ? packed.substring(0, bar) : packed;
        const ts = bar > 0 ? Number(packed.substring(bar + 1)) : 0;
        if (!DoHResolver.looksLikeIPv4(ip) || !Number.isFinite(ts) || ts <= 0) {
          continue;
        }
        if (now - ts > USABLE_TTL_MS) {
          continue;
        }
        if (now - ts > FRESH_TTL_MS) {
          stale++;
          DoHResolver.staleQueue.add(domain);
        }
        DoHResolver.cachePut(domain, ip, false);
        revived++;
      }
      if (revived > 0) {
        AppLogger.info(TAG, `doh pins restored from disk: ${revived} (stale=${stale})`);
      }
    } catch (e) {
      AppLogger.warn(TAG, `doh pin cache load failed: ${AppLogger.errText(e)}`);
    }
  }

  /**
   * 批量解析多个域名(去重后), 带全局时间预算。跑两轮: 第一轮失败的域名
   * (端点瞬时超时/限流)在预算内重试一轮 —— 真机实测单个端点偶发失败会直接
   * 漏 pin(如 chuixuevl1), 两轮 + 双端点把漏 pin 概率压到接近零。
   * 预算耗尽未解析的域名跳过(内核回退 proxy-server-nameserver)。
   *
   * @param priorityDomains 需要**先**解析的域名（本次实际要连的节点）。预算吃紧时
   *        优先保证它们被 pin —— 连不上当前节点的代价比漏 pin 备用节点高得多。
   */
  static async resolveMany(domains: string[], budgetMs: number = 6000,
    priorityDomains: string[] = []): Promise<Record<string, string>> {
    await DoHResolver.ensureLoaded();
    const result: Record<string, string> = {};
    const seen = new Set<string>();
    let pending: string[] = [];
    const priority = new Set<string>();
    for (const raw of priorityDomains) {
      priority.add(raw.toLowerCase());
    }
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
    // 优先级重排：优先域名在前，其余维持订阅顺序（Map 记录首次出现顺序）
    pending = DoHResolver.sortByPriority(pending, priority);
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
              DoHResolver.cachePut(d, ip, true);
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

  /**
   * 后台刷新过期 pin（连接成功后调用，绝不阻塞连接路径）。
   *
   * 用过期值先顶上保证本次连接可用，这里再把真实 IP 更新回来，下一次连接命中新鲜值。
   * 返回的 Promise 只用于日志/测试，调用方不应 await。
   */
  static async refreshStale(budgetMs: number = 20000): Promise<number> {
    await DoHResolver.ensureLoaded();
    if (DoHResolver.staleQueue.size === 0) {
      return 0;
    }
    const todo: string[] = [];
    for (const d of DoHResolver.staleQueue) {
      todo.push(d);
    }
    DoHResolver.staleQueue.clear();
    let updated = 0;
    const deadline = Date.now() + budgetMs;
    const workers: Promise<void>[] = [];
    let idx = 0;
    // 后台刷新降并发：4 路足够，且避免与用户正在发起的业务抢带宽
    for (let w = 0; w < 4; w++) {
      workers.push((async (): Promise<void> => {
        for (;;) {
          if (Date.now() > deadline || idx >= todo.length) {
            return;
          }
          const d = todo[idx];
          idx = idx + 1;
          const ip = await DoHResolver.resolveANoCache(d);
          if (ip.length > 0) {
            DoHResolver.cachePut(d, ip, true);
            updated++;
          }
        }
      })());
    }
    await Promise.all(workers);
    if (updated > 0) {
      AppLogger.info(TAG, `background doh refresh updated ${updated} pin(s)`);
    }
    return updated;
  }

  /** 稳定分区：优先域名在前（保持相对顺序），其余在后。 */
  private static sortByPriority(list: string[], priority: Set<string>): string[] {
    if (priority.size === 0) {
      return list;
    }
    const head: string[] = [];
    const tail: string[] = [];
    for (const d of list) {
      if (priority.has(d)) {
        head.push(d);
      } else {
        tail.push(d);
      }
    }
    return head.concat(tail);
  }

  /** 解析单个域名的 A 记录; 失败返回空串(调用方回退到 proxy-server-nameserver) */
  static async resolveA(domain: string): Promise<string> {
    const cached = DoHResolver.cache.get(domain);
    if (cached !== undefined && cached.length > 0) {
      return cached;
    }
    return DoHResolver.resolveANoCache(domain);
  }

  /** 绕过缓存的真实 DoH 查询（缓存未命中 / 需要刷新时使用）。 */
  private static async resolveANoCache(domain: string): Promise<string> {
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
            DoHResolver.cachePut(domain, a.data, true);
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

  /**
   * Map 保持插入顺序；命中时移到末尾，并淘汰最久未使用的条目。
   *
   * @param schedule 是否排一次落盘。从磁盘载入时传 false，避免"读即写"。
   */
  private static cachePut(domain: string, ip: string, schedule: boolean): void {
    DoHResolver.cache.delete(domain);
    DoHResolver.cache.set(domain, ip);
    DoHResolver.staleQueue.delete(domain);
    while (DoHResolver.cache.size > DoHResolver.CACHE_MAX_ENTRIES) {
      const oldest = DoHResolver.cache.keys().next();
      if (oldest.done) {
        break;
      }
      DoHResolver.cache.delete(oldest.value);
    }
    if (schedule) {
      DoHResolver.schedulePersist();
    }
  }

  /** 节流落盘：批量解析后合并成一次 Preferences 写入，避免每条都 flush。 */
  private static schedulePersist(): void {
    if (DoHResolver.persistTimer >= 0) {
      return;
    }
    DoHResolver.persistTimer = setTimeout(() => {
      DoHResolver.persistTimer = -1;
      const out: Record<string, string> = {};
      const stamp = Date.now();
      for (const domain of DoHResolver.cache.keys()) {
        const ip = DoHResolver.cache.get(domain);
        if (ip !== undefined && ip.length > 0) {
          out[domain] = `${ip}|${stamp}`;
        }
      }
      SettingsService.saveDohPins(out).catch((e: Error): void => {
        AppLogger.warn(TAG, `doh pin persist failed: ${AppLogger.errText(e)}`);
      });
    }, PERSIST_DEBOUNCE_MS);
  }
}
