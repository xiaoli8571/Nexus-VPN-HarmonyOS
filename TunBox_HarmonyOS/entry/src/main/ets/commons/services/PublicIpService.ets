/**
 * 节点国家识别策略 + 公网 IP 服务
 * 移植自 upstream: packages/ssrvpn_shared/lib/utils/node_country_policy.dart
 *                packages/ssrvpn_shared/lib/services/public_ip_info_service.dart
 */
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { PublicIpInfo } from '../models/PublicIpInfo';

export interface CountryDef {
  code: string;
  nameZh: string;
  flagEmoji: string;
  keywords: string[];
}

/** 国家关键词表（与 upstream node_country_policy 的识别词一致的核心子集） */
export const COUNTRY_TABLE: CountryDef[] = [
  { code: 'HK', nameZh: '香港', flagEmoji: '🇭🇰', keywords: ['香港', 'hong kong', 'hongkong', 'hk'] },
  { code: 'TW', nameZh: '台湾', flagEmoji: '🇹🇼', keywords: ['台湾', '台灣', 'taiwan', 'tw'] },
  { code: 'JP', nameZh: '日本', flagEmoji: '🇯🇵', keywords: ['日本', 'japan', 'jp'] },
  { code: 'SG', nameZh: '新加坡', flagEmoji: '🇸🇬', keywords: ['新加坡', '狮城', 'singapore', 'sg'] },
  { code: 'US', nameZh: '美国', flagEmoji: '🇺🇸', keywords: ['美国', '美國', 'united states', 'usa', 'us'] },
  { code: 'KR', nameZh: '韩国', flagEmoji: '🇰🇷', keywords: ['韩国', '韓國', 'korea', 'kr'] },
  { code: 'DE', nameZh: '德国', flagEmoji: '🇩🇪', keywords: ['德国', '德國', 'germany', 'de'] },
  { code: 'GB', nameZh: '英国', flagEmoji: '🇬🇧', keywords: ['英国', '英國', 'united kingdom', 'uk', 'gb'] },
  { code: 'MY', nameZh: '马来西亚', flagEmoji: '🇲🇾', keywords: ['马来西亚', 'malaysia', 'my'] },
  { code: 'TH', nameZh: '泰国', flagEmoji: '🇹🇭', keywords: ['泰国', 'thailand', 'th'] },
  { code: 'VN', nameZh: '越南', flagEmoji: '🇻🇳', keywords: ['越南', 'vietnam', 'vn'] },
  { code: 'PH', nameZh: '菲律宾', flagEmoji: '🇵🇭', keywords: ['菲律宾', 'philippines', 'ph'] }
];

export class NodeCountryPolicy {
  /** 从节点名识别国家（小写包含匹配，与 upstream 顺序一致：先匹配中文关键词再英文） */
  static detect(nodeName: string): CountryDef {
    const lower = nodeName.toLowerCase();
    for (const c of COUNTRY_TABLE) {
      for (const k of c.keywords) {
        if (lower.includes(k)) {
          return c;
        }
      }
    }
    return { code: 'XX', nameZh: '其他', flagEmoji: '🌐', keywords: [] };
  }

  /** 展示名规整（对应 node_display_policy.dart）：去协议前缀/线路数字之外的冗余 */
  static displayName(nodeName: string): string {
    return nodeName.replace(/^(ssr?|ss|vmess|trojan)\s*[:|]\s*/i, '').trim();
  }

  /** 排序：按国家表顺序，再按名称（对应 upstream 节点排序） */
  static compare(a: string, b: string): number {
    const ca = COUNTRY_TABLE.findIndex((c) => c.code === NodeCountryPolicy.detect(a).code);
    const cb = COUNTRY_TABLE.findIndex((c) => c.code === NodeCountryPolicy.detect(b).code);
    if (ca !== cb) {
      return ca - cb;
    }
    return a.localeCompare(b);
  }
}

export class PublicIpService {
  /** 查询当前出口公网 IP（ip-api 免费版仅支持 HTTP，HTTPS 是付费 pro 端点，用 https 会 TLS 失败） */
  static async query(): Promise<PublicIpInfo> {
    const info = PublicIpInfo.empty();
    const req = http.createHttp();
    try {
      const resp = await req.request('http://ip-api.com/json/?fields=query,country,countryCode,city,isp', {
        method: http.RequestMethod.GET,
        connectTimeout: 5000,
        readTimeout: 8000,
        usingCache: false
      });
      const maxResponseBytes = 64 * 1024;
      let body = '';
      if (typeof resp.result === 'string') {
        const encoded = util.TextEncoder.create('utf-8').encodeInto(resp.result);
        if (encoded.length > maxResponseBytes) {
          return info;
        }
        body = resp.result;
      } else if (resp.result instanceof ArrayBuffer) {
        if (resp.result.byteLength > maxResponseBytes) {
          return info;
        }
        body = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(resp.result));
      }
      if (resp.responseCode === 200 && body.length > 0) {
        const json = JSON.parse(body) as Record<string, Object>;
        info.ip = typeof json['query'] === 'string' ? json['query'] as string : '';
        info.country = typeof json['country'] === 'string' ? json['country'] as string : '';
        info.countryCode = typeof json['countryCode'] === 'string' ? json['countryCode'] as string : '';
        info.city = typeof json['city'] === 'string' ? json['city'] as string : '';
        info.isp = typeof json['isp'] === 'string' ? json['isp'] as string : '';
        info.queryTime = Date.now();
      }
    } catch (e) {
      // 失败返回空对象，由 UI 呈现"获取失败"
    } finally {
      req.destroy();
    }
    return info;
  }
}
