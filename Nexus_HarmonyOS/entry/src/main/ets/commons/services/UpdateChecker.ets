/**
 * 更新检查（对应 upstream update_checker.dart）
 * 查询 GitHub 最新 release 的 tag_name 并与当前版本比较。
 */
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { AppInfo } from '../utils/AppInfo';

// 本 HarmonyOS 移植版的发布仓库（Android 上游 Elegying/SSRVPN 版本号体系不同，不可比对）
const RELEASES_API = 'https://api.github.com/repos/xiaoli8571/SSRVPN_Harmony/releases/latest';

export class UpdateChecker {
  /** 返回最新版本号；无更新或网络失败返回 '' */
  static async latestVersion(): Promise<string> {
    const req = http.createHttp();
    try {
      const headers: Record<string, string> = {};
      headers['User-Agent'] = 'Nexus-HarmonyOS';
      const resp = await req.request(RELEASES_API, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 8000,
        readTimeout: 10000,
        usingCache: false
      });
      let body: string = '';
      if (typeof resp.result === 'string') {
        body = resp.result as string;
      } else if (resp.result instanceof ArrayBuffer) {
        body = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(resp.result));
      }
      if (resp.responseCode !== 200 || body.length === 0) {
        return '';
      }
      const json = JSON.parse(body) as Record<string, Object>;
      const tag = json['tag_name'] as string;
      return tag !== undefined ? UpdateChecker.normalize(tag) : '';
    } catch (e) {
      return '';
    } finally {
      req.destroy();
    }
  }

  static hasUpdate(latest: string): boolean {
    if (latest.length === 0) {
      return false;
    }
    return UpdateChecker.compare(latest, UpdateChecker.currentVersion()) > 0;
  }

  /** 点分数字版本比较: a>b → 1, a<b → -1, 相等/不可解析 → 0 */
  static compare(a: string, b: string): number {
    const pa = a.split('.').map((x) => parseInt(x) || 0);
    const pb = b.split('.').map((x) => parseInt(x) || 0);
    const len = Math.max(pa.length, pb.length);
    for (let i = 0; i < len; i++) {
      const va = i < pa.length ? pa[i] : 0;
      const vb = i < pb.length ? pb[i] : 0;
      if (va > vb) {
        return 1;
      }
      if (va < vb) {
        return -1;
      }
    }
    return 0;
  }

  static normalize(tag: string): string {
    return tag.trim().replace(/^v/i, '');
  }

  static currentVersion(): string {
    return UpdateChecker.normalize(AppInfo.version());
  }
}
