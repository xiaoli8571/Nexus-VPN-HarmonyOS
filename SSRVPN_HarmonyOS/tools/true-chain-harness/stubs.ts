// tools/true-chain-harness/stubs.ts
// 仅替换 HarmonyOS 系统能力与「持久化/网络」边界（测试替身），不包含任何解析逻辑。
// 所有解析/合并/映射/字段生成逻辑都来自 generated/*.ts（真实 .ets 源码）。
type AnyObj = Record<string, unknown>;

/** 与 @ohos.util.Type 对齐（BASIC=0 / MIME=1）。 */
const UTIL_TYPE = { BASIC: 0, MIME: 1, BASIC_URL_SAFE: 2, MIME_URL_SAFE: 3 };

/**
 * @ohos.util.Base64Helper 替身。decodeSync 按 BASIC 的严格度校验（非法字符/长度抛错），
 * 以贴近真机行为（HarmonyOS 在非法输入时抛错，而 Buffer 会静默容忍）。
 */
class Base64HelperStub {
  decodeSync(input: string, _type?: number): Uint8Array {
    const s = input.replace(/[\r\n\s]/g, '');
    if (!/^[A-Za-z0-9+/]*={0,2}$/.test(s) || s.length % 4 !== 0) {
      throw new Error('base64 stub: invalid input');
    }
    return new Uint8Array(Buffer.from(s, 'base64'));
  }
  encodeToStringSync(input: Uint8Array, _type?: number): string {
    return Buffer.from(input).toString('base64');
  }
}

export const util = {
  Type: UTIL_TYPE,
  Base64Helper: Base64HelperStub,
  TextEncoder: {
    create(_enc: string): { encodeInto(s: string): Uint8Array } {
      return {
        encodeInto(s: string): Uint8Array {
          return new Uint8Array(Buffer.from(s, 'utf8'));
        },
      };
    },
  },
  TextDecoder: {
    create(_enc: string): { decodeToString(b: Uint8Array): string } {
      return {
        decodeToString(b: Uint8Array): string {
          return Buffer.from(b).toString('utf8');
        },
      };
    },
  },
  generateRandomUUID(): string {
    return globalThis.crypto.randomUUID();
  },
};

export class AppLogger {
  static lines: string[] = [];
  static info(tag: string, msg: string): void { AppLogger.lines.push(`INFO ${tag} ${msg}`); }
  static warn(tag: string, msg: string): void { AppLogger.lines.push(`WARN ${tag} ${msg}`); }
  static error(tag: string, msg: string): void { AppLogger.lines.push(`ERROR ${tag} ${msg}`); }
  static addListener(_l: (line: string) => void): void {}
  static removeListener(_l: (line: string) => void): void {}
}

/** preferences 替身：内存实现，用于模拟 devices 上的持久化（可选注入初始值）。 */
export const harnessPrefs = new Map<string, string>();
export const preferences = {
  async getPreferences(_ctx: unknown): Promise<AnyObj> {
    return {
      async get(key: string, def: string): Promise<string> {
        return harnessPrefs.has(key) ? (harnessPrefs.get(key) as string) : def;
      },
      async put(key: string, value: string): Promise<void> { harnessPrefs.set(key, value); },
      async delete(key: string): Promise<void> { harnessPrefs.delete(key); },
      async flush(): Promise<void> {},
    };
  },
};

export const asset = {};

/** SubscriptionJson 是纯数据类，这里按真实字段复刻（仅用于模型层往返，不含逻辑）。 */
export class SubscriptionJson {
  id: string = '';
  name: string = '';
  url: string = '';
  headerName: string = '';
  headerValue: string = '';
  lastFetchedAt: number = 0;
  lastRefreshResult: string = '';
  nodeCount: number = 0;
  uploadBytes?: number;
  downloadBytes?: number;
  totalBytes?: number;
  expireAt?: number;
  enabled: boolean = true;
  sortOrder: number = 0;
}

export class CredentialMigrationReport {
  migratedNodes: number = 0;
  migratedFields: number = 0;
  migratedSubscriptions: number = 0;
  alreadyStored: number = 0;
  addedNew: number = 0;
  failed: number = 0;
  fieldFailed(_id: string, _field: string): boolean { return false; }
}

export class NodeCredentialValues {
  password: string = '';
  uuid: string = '';
  protocolParam: string = '';
  obfsParam: string = '';
}

export class SubscriptionCredentialSource {
  id: string = '';
  headerValue: string = '';
}

export const CRED_PREF_NAME = 'ssrvpn_credentials';
export const MIGRATION_FLAG_KEY = 'migration_v1_done';
export const SUB_CRED_FIELD = 'headerValue';
export const NODE_CRED_FIELDS: string[] = ['password', 'uuid', 'protocolParam', 'obfsParam'];
export function nodeCredentialId(n: AnyObj): string {
  return `${n['subscriptionId']}|${n['server']}|${n['port']}|${n['name']}`;
}
export function setCredentialLogger(_f: (msg: string) => void): void {}

export class CredentialStore {
  static async loadMigrationFlag(): Promise<void> {}
  static isFirstRun(): boolean { return false; }
  static async canonicalize(_n: AnyObj[], _s: AnyObj[], _b: boolean): Promise<CredentialMigrationReport> {
    return new CredentialMigrationReport();
  }
  static async canonicalizeNodes(_n: AnyObj[], _b: boolean): Promise<CredentialMigrationReport> {
    return new CredentialMigrationReport();
  }
  static logAssetUnavailable(_where: string): void {}
  static async nodeCredentials(_id: string, fallback: NodeCredentialValues): Promise<NodeCredentialValues> {
    return fallback;
  }
  static async subscriptionCredential(_id: string, fallback: string): Promise<string> { return fallback; }
  static plaintextFieldKeys(): string[] { return []; }
}

export class AppInfo {
  static version(): string { return '0.0.0-harness'; }
}

export class SubscriptionUserInfo {
  uploadBytes: number = -1;
  downloadBytes: number = -1;
  totalBytes: number = -1;
  expireAt: number = -1;
}

/** 网络替身：body 由 chain.mjs 注入到 globalThis.__HARNESS_BODY__。 */
export class SubscriptionFetchPolicy {
  static async fetch(_url: string, _hn: string, _hv: string): Promise<AnyObj> {
    const g = globalThis as unknown as { __HARNESS_BODY__?: string; __HARNESS_FETCH_MODE__?: string };
    const body = g.__HARNESS_BODY__ ?? '';
    return { body, userInfo: new SubscriptionUserInfo() };
  }
  static isNodeCountAllowed(count: number): boolean { return count <= 2000; }
  static isValidSubscriptionUrl(_url: string, _qr?: boolean): boolean { return true; }
}

export const SubscriptionFetchErrorKind = {
  NETWORK: 'network', HTTP: 'http', EMPTY_RESPONSE: 'emptyResponse', DECODE: 'decode',
};

export class SubscriptionFetchError extends Error {
  kind: string = SubscriptionFetchErrorKind.NETWORK;
  constructor(kind: string, message: string) {
    super(message);
    this.kind = kind;
  }
}
