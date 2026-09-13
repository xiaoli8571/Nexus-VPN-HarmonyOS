/**
 * 设置持久化服务
 * 移植自 upstream: SSRVPN_Android/lib/services/settings_service.dart
 * - apiSecret：@ohos.security.asset（系统级加密存储，对应 Keystore AES-GCM / NativeApiSecretResolver）
 * - 连接快照：重启后恢复上次连接意图（对应 NativeConnectionSnapshotStore）
 */
import { preferences } from '@kit.ArkData';
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { AppSettings, AppSettingsJson } from '../models/AppSettings';
import { AppLogger } from '../utils/AppLogger';
import { RawSubscriptionStore } from './RawSubscriptionStore';

const TAG = 'SettingsService';
const PREF_NAME = 'ssrvpn_settings';
const KEY_SETTINGS = 'app_settings_json';
const ASSET_SERVICE = 'ssrvpn_service';
const ASSET_SECRET_KEY = 'api_secret';
const KEY_SNAPSHOT = 'connection_snapshot_json';
const KEY_SUBSCRIPTION_FAB_X = 'subscription_fab_x';
const KEY_SUBSCRIPTION_FAB_Y = 'subscription_fab_y';

/** 连接快照（对应 NativeConnectionSnapshot：重启恢复连接意图） */
export class ConnectionSnapshot {
  desiredConnected: boolean = false;
  nodeName: string = '';
  savedAt: number = 0;
  /** 本次真实 VPN 会话开始时刻；旧快照缺少此字段时按 0 兼容。 */
  startedAt: number = 0;
}

export class SettingsService {
  private static store: preferences.Preferences | null = null;
  /** 本进程内「双轨 provider」开关的上一次生效值：用于识别 true → false 的关闭动作 */
  private static lastRawProviderFlag: boolean = false;
  /** 关闭状态下是否已清理过落盘原文（避免每次加载/保存都扫描目录） */
  private static rawProviderPurgedWhileDisabled: boolean = false;

  static async init(context: Context): Promise<void> {
    SettingsService.store = await preferences.getPreferences(context, PREF_NAME);
  }

  static async load(): Promise<AppSettings> {
    if (SettingsService.store === null) {
      return new AppSettings();
    }
    const raw = await SettingsService.store.get(KEY_SETTINGS, '') as string;
    if (raw.length === 0) {
      return new AppSettings();
    }
    try {
      const j = JSON.parse(raw) as AppSettingsJson;
      const settings = AppSettings.fromJson(j);
      // 双轨开关是全局闸门：任何一次加载都把持久化值同步给落盘仓，
      // 持久化为关闭 → 顺带清掉历史落盘原文（含进程被杀后残留）。
      SettingsService.syncRawProviderGate(settings.useRawProviderConfig);
      return settings;
    } catch (e) {
      return new AppSettings();
    }
  }

  static async save(settings: AppSettings): Promise<void> {
    if (SettingsService.store === null) {
      return;
    }
    // 保存前经 fromJson(toJson()) 归一化：非法值夹取、缺字段补默认，
    // 保证「保存两次 = 同一 JSON」（幂等），且不回写脏值。
    const normalized = AppSettings.fromJson(settings.toJson());
    await SettingsService.store.put(KEY_SETTINGS, JSON.stringify(normalized.toJson()));
    await SettingsService.store.flush();
    SettingsService.syncRawProviderGate(normalized.useRawProviderConfig);
  }

  /**
   * 双轨开关的一键切换（设置页/诊断面板调用）：写盘 + 同步落盘仓闸门。
   * 关闭时落盘原文会被删除（凭据不再需要即删干净），返回删除的文件数。
   */
  static async setUseRawProviderConfig(value: boolean): Promise<number> {
    const settings = await SettingsService.load();
    settings.useRawProviderConfig = value;
    await SettingsService.save(settings);
    const removed = RawSubscriptionStore.setEnabled(value);
    AppLogger.info(TAG, `useRawProviderConfig=${value} (raw files removed=${removed})`);
    return removed;
  }

  /**
   * 闸门同步：开启时只设置标记（保留文件）；关闭时清理落盘原文（凭据不再需要即删干净），
   * 且每个进程只在首次观察到「关闭」时清理一次，避免反复扫描目录。
   */
  private static syncRawProviderGate(enabled: boolean): void {
    if (enabled) {
      RawSubscriptionStore.setEnabled(true, false);
      SettingsService.lastRawProviderFlag = true;
      SettingsService.rawProviderPurgedWhileDisabled = false;
      return;
    }
    RawSubscriptionStore.setEnabled(false, false);
    SettingsService.lastRawProviderFlag = false;
    if (SettingsService.rawProviderPurgedWhileDisabled || !RawSubscriptionStore.isReady()) {
      return;
    }
    SettingsService.rawProviderPurgedWhileDisabled = true;
    const removed = RawSubscriptionStore.removeAll();
    if (removed > 0) {
      AppLogger.info(TAG, `purged ${removed} raw subscription file(s): raw provider disabled`);
    }
  }

  /** apiSecret 只允许存入系统加密 AssetStore，禁止降级到明文 Preferences。 */
  static async setApiSecret(secret: string): Promise<void> {
    const attr: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    attr.set(asset.Tag.SECRET, stringToUint8(secret));
    attr.set(asset.Tag.ALIAS, stringToUint8(ASSET_SECRET_KEY));
    attr.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    try {
      await asset.remove(attr);
    } catch (e) {
      // 首次写入前不存在属正常
    }
    await asset.add(attr);

    // 清除旧版本可能遗留的明文回退值。
    if (SettingsService.store !== null) {
      try {
        await SettingsService.store.delete('api_secret_fallback');
        await SettingsService.store.flush();
      } catch (cleanupError) {
        AppLogger.warn(TAG, `failed to remove legacy api secret fallback: ${cleanupError instanceof Error ? cleanupError.message : String(cleanupError)}`);
      }
    }
    AppLogger.info(TAG, 'apiSecret stored in asset store');
  }

  static async getApiSecret(): Promise<string> {
    try {
      const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
      query.set(asset.Tag.ALIAS, stringToUint8(ASSET_SECRET_KEY));
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const results: asset.AssetMap[] = await asset.query(query);
      if (results.length === 0) {
        return '';
      }
      const secretVal = results[0].get(asset.Tag.SECRET);
      if (secretVal !== undefined && secretVal instanceof Uint8Array) {
        return uint8ToString(secretVal as Uint8Array);
      }
      return '';
    } catch (e) {
      AppLogger.warn(TAG, `asset store query failed: ${e instanceof Error ? e.message : String(e)}`);
      return '';
    }
  }

  /** 连接快照读写（重启恢复） */
  static async saveSnapshot(snap: ConnectionSnapshot): Promise<void> {
    if (SettingsService.store === null) {
      return;
    }
    await SettingsService.store.put(KEY_SNAPSHOT, JSON.stringify(snap));
    await SettingsService.store.flush();
  }

  static async loadSnapshot(): Promise<ConnectionSnapshot> {
    const snap = new ConnectionSnapshot();
    if (SettingsService.store === null) {
      return snap;
    }
    const raw = await SettingsService.store.get(KEY_SNAPSHOT, '') as string;
    if (raw.length === 0) {
      return snap;
    }
    try {
      const j = JSON.parse(raw) as ConnectionSnapshot;
      snap.desiredConnected = j.desiredConnected;
      snap.nodeName = j.nodeName;
      snap.savedAt = j.savedAt;
      snap.startedAt = typeof j.startedAt === 'number' && j.startedAt > 0 ? j.startedAt : 0;
    } catch (e) {
      // 快照损坏则视为空
    }
    return snap;
  }

  static async loadSubscriptionFabPosition(): Promise<number[]> {
    if (SettingsService.store === null) {
      return [-1, -1];
    }
    const x = await SettingsService.store.get(KEY_SUBSCRIPTION_FAB_X, -1) as number;
    const y = await SettingsService.store.get(KEY_SUBSCRIPTION_FAB_Y, -1) as number;
    return [x, y];
  }

  static async saveSubscriptionFabPosition(x: number, y: number): Promise<void> {
    if (SettingsService.store === null) {
      return;
    }
    await SettingsService.store.put(KEY_SUBSCRIPTION_FAB_X, x);
    await SettingsService.store.put(KEY_SUBSCRIPTION_FAB_Y, y);
    await SettingsService.store.flush();
  }
}

function stringToUint8(s: string): Uint8Array {
  return util.TextEncoder.create('utf-8').encodeInto(s);
}

function uint8ToString(bytes: Uint8Array): string {
  return util.TextDecoder.create('utf-8').decodeToString(bytes);
}
