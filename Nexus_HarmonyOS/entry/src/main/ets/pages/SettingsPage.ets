/**
 * 设置中心（第二阶段·第三轮 UI）
 *
 * 职责：把第二阶段新增的设置项以分组形式呈现，读写均走既有服务：
 *   - 读取：SettingsService.load() → AppSettings（页面首次进入取持久化真实值）
 *   - 写入：SettingsService.save()（内部 fromJson(toJson()) 归一化，与 UI 夹取形成双重夹取）
 * 每项改动即时落盘并 showToast 反馈；返回主页后再次进入仍读回真实值（不丢状态）。
 *
 * 约束：本文件只调用既有服务的公开接口，不修改 Orchestrator/AppSettings/SettingsService。
 * 退避上限（setReconnectBackoffMax）未纳入 AppSettings 持久化字段，故用进程内静态变量
 * 在页面实例之间保持（不写盘、不新增字段）。
 */
import { router, promptAction } from '@kit.ArkUI';
import { Ui } from '../theme/UiTokens';
import { SettingsService } from '../commons/services/SettingsService';
import { AppSettings, AutoSelectModes } from '../commons/models/AppSettings';
import { ConnectionOrchestrator } from '../commons/services/ConnectionOrchestrator';
import { SubscriptionService } from '../commons/services/SubscriptionService';
import { GeoAssetStatus } from '../commons/services/ConnectionOrchestrator';

/** 退避上限可选值（秒） */
const BACKOFF_OPTIONS: number[] = [8, 16, 32];
/** 退避上限进程内记忆（未持久化；默认 8s 与 Orchestrator 的 RECONNECT_MAX_MS 一致） */
class BackoffRuntime {
  static sec: number = 8;
}

/** geo 资产下载源偏好选项（与 AppSettings.assetSource 白名单一致） */
const ASSET_SOURCE_OPTIONS: string[] = ['auto', 'jsdelivr', 'ghproxy', 'github'];
const ASSET_SOURCE_LABELS: Record<string, string> = {
  'auto': '默认',
  'jsdelivr': 'CDN',
  'ghproxy': '加速',
  'github': '官方'
};

function formatGeoSize(bytes: number): string {
  if (bytes <= 0) {
    return '-';
  }
  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(0)} KB`;
  }
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

@Entry
@Component
struct SettingsPage {
  @State appRoutingSummary: string = '正在读取应用分流…';
  // ── 网络与重连 ──
  @State autoReconnect: boolean = true;
  @State backoffSec: number = 8;
  // ── 故障切换 ──
  @State failoverEnabled: boolean = true;
  @State failoverThreshold: number = 3;
  @State failoverCooldown: number = 60;
  // ── 选点 ──
  @State autoSelectMode: string = AutoSelectModes.MANUAL;
  @State currentNodeName: string = '';
  @State switchReason: string = '';
  @State switchFrom: string = '';
  @State switchTo: string = '';
  // ── 诊断 ──
  @State healthEnabled: boolean = true;
  @State repairMaxSteps: number = 2;
  // ── 数据与规则（geo 资产） ──
  @State geoAssets: GeoAssetStatus[] = [];
  @State assetSource: string = 'auto';
  @State geoUpdatingId: string = '';
  @State quotaNotifyEnabled: boolean = true;

  private settings: AppSettings = new AppSettings();
  private orchestrator: ConnectionOrchestrator = ConnectionOrchestrator.instance();
  private subs: SubscriptionService = SubscriptionService.instance();

  onPageShow(): void {
    this.bootstrap();
  }

  private async bootstrap(): Promise<void> {
    const ctx = getContext(this) as Context;
    this.orchestrator.init(ctx);
    await SettingsService.init(ctx);
    await this.subs.init(ctx);
    this.settings = await SettingsService.load();
    this.refreshAppRoutingSummary();
    // 每次进入：从持久化读取真实值回填（缺字段/脏值由 AppSettings.fromJson 兜底）
    this.autoReconnect = this.settings.autoReconnectOnNetworkChange;
    this.failoverEnabled = this.settings.failoverEnabled;
    this.failoverThreshold = this.settings.failoverFailureThreshold;
    this.failoverCooldown = this.settings.failoverCooldownSec;
    this.autoSelectMode = AutoSelectModes.normalize(this.settings.autoSelectMode);
    this.healthEnabled = this.settings.healthCheckEnabled;
    this.repairMaxSteps = this.settings.healthRepairMaxSteps;
    this.quotaNotifyEnabled = this.settings.quotaNotifyEnabled;
    this.assetSource = this.settings.assetSource;
    this.refreshGeoStatuses();
    // 退避上限：进程内记忆，进页面即应用到编排器
    this.backoffSec = BackoffRuntime.sec;
    this.orchestrator.setReconnectBackoffMax(this.backoffSec * 1000);
    this.refreshNodeAndSwitchInfo();
  }

  /** 只展示当前模式对应的数量，切回本页时与保存结果同步。 */
  private refreshAppRoutingSummary(): void {
    let summary = '全部应用 · 不限应用（0 个筛选项）';
    if (this.settings.appRoutingMode === 'exclude') {
      summary = `绕过所选应用 · 已选 ${this.settings.excludedApps.length} 个`;
    } else if (this.settings.appRoutingMode === 'include') {
      summary = `仅所选应用 · 已选 ${this.settings.includedApps.length} 个`;
    }
    this.appRoutingSummary = this.settings.appRoutingNeedsReview
      ? summary + ' · 待确认，请进入检查' : summary;
  }

  private refreshNodeAndSwitchInfo(): void {
    const node = this.subs.findNode(this.settings.preferredNodeId);
    if (node !== null) {
      this.currentNodeName = node.name;
    } else {
      this.currentNodeName = this.subs.nodes.length > 0 ? this.subs.nodes[0].name : '';
    }
    this.switchReason = this.orchestrator.autoSwitchReason();
    this.switchFrom = this.orchestrator.lastFailoverFromName();
    this.switchTo = this.orchestrator.lastFailoverToName();
  }

  /** UTF/模型双重夹取：本函数为 UI 侧夹取（保存时 SettingsService 再夹一次） */
  private clampInt(v: number, min: number, max: number, def: number): number {
    if (typeof v !== 'number' || !Number.isFinite(v)) {
      return def;
    }
    const i = Math.floor(v);
    if (i < min) {
      return min;
    }
    if (i > max) {
      return max;
    }
    return i;
  }

  /** 落盘 + 轻量反馈（每项改动即时保存） */
  private persist(): void {
    this.settings.autoReconnectOnNetworkChange = this.autoReconnect;
    this.settings.failoverEnabled = this.failoverEnabled;
    this.settings.failoverFailureThreshold = this.failoverThreshold;
    this.settings.failoverCooldownSec = this.failoverCooldown;
    this.settings.autoSelectMode = AutoSelectModes.normalize(this.autoSelectMode);
    this.settings.healthCheckEnabled = this.healthEnabled;
    this.settings.healthRepairMaxSteps = this.repairMaxSteps;
    SettingsService.save(this.settings).then((): void => {
      promptAction.showToast({ message: $r('app.string.settings_saved_toast') });
    }).catch((): void => {
      promptAction.showToast({ message: $r('app.string.settings_save_failed_toast') });
    });
  }

  // ── 各设置项交互 ──────────────────────────────────────────────────

  private onAutoReconnectChange(v: boolean): void {
    this.autoReconnect = v;
    this.persist();
  }

  private setBackoff(sec: number): void {
    const s = BACKOFF_OPTIONS.includes(sec) ? sec : 8;
    this.backoffSec = s;
    BackoffRuntime.sec = s;
    this.orchestrator.setReconnectBackoffMax(s * 1000);
    promptAction.showToast({ message: $r('app.string.settings_saved_toast') });
  }

  private onFailoverEnabledChange(v: boolean): void {
    this.failoverEnabled = v;
    this.persist();
  }

  private stepThreshold(delta: number): void {
    const before = this.failoverThreshold;
    this.failoverThreshold = this.clampInt(before + delta, 1, 10, 3);
    if (this.failoverThreshold === before) {
      promptAction.showToast({ message: $r('app.string.settings_clamp_toast') });
      return;
    }
    this.persist();
  }

  private stepCooldown(delta: number): void {
    const before = this.failoverCooldown;
    this.failoverCooldown = this.clampInt(before + delta, 0, 3600, 60);
    if (this.failoverCooldown === before) {
      promptAction.showToast({ message: $r('app.string.settings_clamp_toast') });
      return;
    }
    this.persist();
  }

  private setSelectMode(mode: string): void {
    const m = AutoSelectModes.normalize(mode);
    if (this.autoSelectMode === m) {
      return;
    }
    this.autoSelectMode = m;
    this.persist();
  }

  private onHealthEnabledChange(v: boolean): void {
    this.healthEnabled = v;
    this.persist();
  }

  private stepRepair(delta: number): void {
    const before = this.repairMaxSteps;
    this.repairMaxSteps = this.clampInt(before + delta, 0, 3, 2);
    if (this.repairMaxSteps === before) {
      promptAction.showToast({ message: $r('app.string.settings_clamp_toast') });
      return;
    }
    this.persist();
  }

  // ── 数据与规则（geo 资产管理） ────────────────────────────────────

  private refreshGeoStatuses(): void {
    this.geoAssets = this.orchestrator.geoAssetStatuses();
  }

  private geoStatusText(asset: GeoAssetStatus): string {
    if (!asset.ready) {
      return '未就绪（连接时会后台补齐）';
    }
    let age = '';
    if (asset.mtimeMs > 0) {
      const days = Math.floor((Date.now() - asset.mtimeMs) / 86400000);
      age = days <= 0 ? '今天更新' : `${days} 天前更新`;
    }
    return `就绪 · ${formatGeoSize(asset.sizeBytes)} · ${age}`;
  }

  private async updateAsset(id: string): Promise<void> {
    if (this.geoUpdatingId.length > 0) {
      return;
    }
    this.geoUpdatingId = id;
    try {
      const err = await this.orchestrator.refreshGeoAsset(id, this.assetSource);
      promptAction.showToast({ message: err.length > 0 ? err : '更新完成' });
    } catch (e) {
      promptAction.showToast({ message: '更新失败，请重试' });
    } finally {
      this.geoUpdatingId = '';
      this.refreshGeoStatuses();
    }
  }

  private setAssetSource(source: string): void {
    if (this.assetSource === source) {
      return;
    }
    this.assetSource = source;
    this.settings.assetSource = source;
    SettingsService.save(this.settings).then((): void => {
      promptAction.showToast({ message: $r('app.string.settings_saved_toast') });
    }).catch((): void => {
      promptAction.showToast({ message: $r('app.string.settings_save_failed_toast') });
    });
  }

  private setQuotaNotify(v: boolean): void {
    this.quotaNotifyEnabled = v;
    this.settings.quotaNotifyEnabled = v;
    SettingsService.save(this.settings).then((): void => {
      promptAction.showToast({ message: $r('app.string.settings_saved_toast') });
    }).catch((): void => {
      promptAction.showToast({ message: $r('app.string.settings_save_failed_toast') });
    });
  }

  // ── UI ────────────────────────────────────────────────────────────

  build() {
    Stack() {
      Column()
        .width('100%').height('100%')
        .linearGradient({ angle: 135, colors: Ui.backdropColors })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column() {
        // ── 顶栏 ──
        Row() {
          Text('←')
            .fontSize(22).fontColor(Ui.textPrimary)
            .padding({ left: 4, right: 8 })
            .onClick(() => router.back())
          Text($r('app.string.settings_title'))
            .fontSize(18).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
          Blank()
        }
        .width('100%')
        .height(48)

        Scroll() {
          Column({ space: 14 }) {
            // ── 应用分流：进入统一页面，不在设置页维护第二份编辑状态 ──
            Column({ space: 6 }) {
              Row({ space: 7 }) {
                Text('📱').fontSize(16).fontColor(Ui.textSecondary)
                Text('应用分流').fontSize(15).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
                Blank()
                Text('›').fontSize(20).fontColor(Ui.textSecondary)
              }.width('100%')
              Text(this.appRoutingSummary)
                .fontSize(12).fontColor(Ui.textSecondary).width('100%')
            }
            .width('100%').padding(16).borderRadius(20)
            .backgroundColor(Ui.surfaceMuted).borderWidth(1).borderColor(Ui.border)
            .onClick(() => router.pushUrl({ url: 'pages/AppRoutingPage' }))

            // ── 网络与重连 ──
            Column({ space: 12 }) {
              this.SectionHeader('🌐', $r('app.string.settings_network_reconnect_title'))
              this.ToggleRow($r('app.string.settings_auto_reconnect_label'),
                $r('app.string.settings_auto_reconnect_desc'),
                this.autoReconnect, (v: boolean): void => this.onAutoReconnectChange(v))
              Column({ space: 8 }) {
                Row() {
                  Text($r('app.string.settings_backoff_max_label'))
                    .fontSize(14).fontColor(Ui.textPrimary).layoutWeight(1)
                }.width('100%')
                Row({ space: 8 }) {
                  ForEach(BACKOFF_OPTIONS, (sec: number) => {
                    Text($r('app.string.settings_seconds_value', sec))
                      .fontSize(13)
                      .fontWeight(this.backoffSec === sec ? FontWeight.Bold : FontWeight.Normal)
                      .fontColor(this.backoffSec === sec ? Ui.textViolet : Ui.textSecondary)
                      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                      .borderRadius(12)
                      .backgroundColor(this.backoffSec === sec ? Ui.selectedBackground : Ui.inputBackground)
                      .borderWidth(1)
                      .borderColor(this.backoffSec === sec ? Ui.primary : Ui.border)
                      .onClick(() => this.setBackoff(sec))
                  }, (sec: number) => `${sec}`)
                }.width('100%')
                Text($r('app.string.settings_backoff_max_desc'))
                  .fontSize(11).fontColor(Ui.textTertiary).width('100%')
              }.width('100%')
            }
            .width('100%').padding(16).borderRadius(20)
            .backgroundColor(Ui.surfaceMuted).borderWidth(1).borderColor(Ui.border)

            // ── 故障切换 ──
            Column({ space: 12 }) {
              this.SectionHeader('⇄', $r('app.string.settings_failover_title'))
              this.ToggleRow($r('app.string.settings_failover_enable_label'),
                $r('app.string.settings_failover_enable_desc'),
                this.failoverEnabled, (v: boolean): void => this.onFailoverEnabledChange(v))
              this.StepperRow($r('app.string.settings_failover_threshold_label'),
                $r('app.string.settings_failover_threshold_desc'),
                this.failoverThreshold, false,
                (delta: number): void => this.stepThreshold(delta))
              this.StepperRow($r('app.string.settings_failover_cooldown_label'),
                $r('app.string.settings_failover_cooldown_desc'),
                this.failoverCooldown, true,
                (delta: number): void => this.stepCooldown(delta))
            }
            .width('100%').padding(16).borderRadius(20)
            .backgroundColor(Ui.surfaceMuted).borderWidth(1).borderColor(Ui.border)

            // ── 选点 ──
            Column({ space: 12 }) {
              this.SectionHeader('✦', $r('app.string.settings_select_title'))
              Text($r('app.string.settings_select_mode_label'))
                .fontSize(14).fontColor(Ui.textPrimary).width('100%')
              Row() {
                this.SelectChip(AutoSelectModes.MANUAL, $r('app.string.settings_select_mode_manual'))
                this.SelectChip(AutoSelectModes.AUTO, $r('app.string.settings_select_mode_auto'))
              }
              .width('100%').padding(4).borderRadius(14).backgroundColor(Ui.inputBackground)
              Text(this.autoSelectMode === AutoSelectModes.AUTO
                ? $r('app.string.settings_select_mode_auto_desc')
                : $r('app.string.settings_select_mode_manual_desc'))
                .fontSize(11).fontColor(Ui.textTertiary).width('100%')

              Divider().color(Ui.border)

              Row() {
                Text($r('app.string.settings_current_node_label'))
                  .fontSize(13).fontColor(Ui.textSecondary).layoutWeight(1)
                Text(this.currentNodeName.length > 0
                  ? this.currentNodeName : $r('app.string.settings_no_node'))
                  .fontSize(13).fontColor(Ui.textPrimary)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .constraintSize({ maxWidth: 180 })
              }.width('100%')

              Row() {
                Text($r('app.string.settings_last_switch_label'))
                  .fontSize(13).fontColor(Ui.textSecondary).layoutWeight(1)
                Text(this.switchFrom.length > 0 && this.switchTo.length > 0
                  ? $r('app.string.settings_last_switch_pair', this.switchFrom, this.switchTo)
                  : $r('app.string.settings_last_switch_none'))
                  .fontSize(13).fontColor(Ui.textPrimary)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .constraintSize({ maxWidth: 180 })
              }.width('100%')

              if (this.switchReason.length > 0) {
                Text(this.switchReason)
                  .fontSize(11).fontColor(Ui.textTertiary).width('100%')
              }
            }
            .width('100%').padding(16).borderRadius(20)
            .backgroundColor(Ui.surfaceMuted).borderWidth(1).borderColor(Ui.border)

            // ── 诊断 ──
            Column({ space: 12 }) {
              this.SectionHeader('🩺', $r('app.string.settings_diagnostics_title'))
              this.ToggleRow($r('app.string.settings_health_enable_label'),
                $r('app.string.settings_health_enable_desc'),
                this.healthEnabled, (v: boolean): void => this.onHealthEnabledChange(v))
              this.StepperRow($r('app.string.settings_health_repair_steps_label'),
                $r('app.string.settings_health_repair_steps_desc'),
                this.repairMaxSteps, false,
                (delta: number): void => this.stepRepair(delta))
              Divider().color(Ui.border)
              Column({ space: 4 }) {
                Row() {
                  Text('订阅配额提醒')
                    .fontSize(14).fontColor(Ui.textPrimary).layoutWeight(1)
                  Toggle({ type: ToggleType.Switch, isOn: this.quotaNotifyEnabled })
                    .selectedColor(Ui.primaryBlueFill)
                    .onChange((v: boolean): void => this.setQuotaNotify(v))
                }.width('100%').alignItems(VerticalAlign.Center)
                Text('订阅流量剩余不足 10% 或 3 天内到期时发送系统通知（每次刷新订阅后检查，每天最多提醒一次）')
                  .fontSize(11).fontColor(Ui.textTertiary).width('100%')
              }.width('100%')
            }
            .width('100%').padding(16).borderRadius(20)
            .backgroundColor(Ui.surfaceMuted).borderWidth(1).borderColor(Ui.border)

            // ── 数据与规则 ──
            Column({ space: 12 }) {
              this.SectionHeader('🗃', $r('app.string.settings_geo_title'))
              ForEach(this.geoAssets, (asset: GeoAssetStatus) => {
                Row({ space: 10 }) {
                  Column({ space: 3 }) {
                    Row({ space: 6 }) {
                      Text(asset.label).fontSize(14).fontWeight(FontWeight.Bold)
                        .fontColor(Ui.textPrimary)
                      Text(asset.ready ? '●' : '○')
                        .fontSize(12)
                        .fontColor(asset.ready ? Ui.success : Ui.textTertiary)
                    }.width('100%')
                    Text(`${asset.detail} · ${this.geoStatusText(asset)}`)
                      .fontSize(11).fontColor(Ui.textTertiary).width('100%')
                      .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  Text(this.geoUpdatingId === asset.id ? '更新中…' : '更新')
                    .fontSize(13)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.geoUpdatingId === asset.id ? Ui.textTertiary : Ui.primary)
                    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                    .borderRadius(12)
                    .backgroundColor(Ui.inputBackground)
                    .borderWidth(1)
                    .borderColor(Ui.border)
                    .onClick(() => {
                      if (this.geoUpdatingId.length === 0) {
                        this.updateAsset(asset.id);
                      }
                    })
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)
                .padding(10)
                .borderRadius(14)
                .backgroundColor(Ui.inputBackground)
              }, (asset: GeoAssetStatus) => `${asset.id}-${asset.ready}-${asset.sizeBytes}`)

              Column({ space: 8 }) {
                Text('下载源偏好')
                  .fontSize(14).fontColor(Ui.textPrimary).width('100%')
                Row({ space: 8 }) {
                  ForEach(ASSET_SOURCE_OPTIONS, (src: string) => {
                    Text(ASSET_SOURCE_LABELS[src] ?? src)
                      .fontSize(13)
                      .fontWeight(this.assetSource === src ? FontWeight.Bold : FontWeight.Normal)
                      .fontColor(this.assetSource === src ? Ui.textViolet : Ui.textSecondary)
                      .layoutWeight(1)
                      .textAlign(TextAlign.Center)
                      .padding({ top: 7, bottom: 7 })
                      .borderRadius(12)
                      .backgroundColor(this.assetSource === src ? Ui.selectedBackground : Ui.inputBackground)
                      .borderWidth(1)
                      .borderColor(this.assetSource === src ? Ui.primary : Ui.border)
                      .onClick(() => this.setAssetSource(src))
                  }, (src: string) => src)
                }.width('100%')
                Text('默认按实测可达性排序；CDN=jsdelivr 优先，加速=gh-proxy 前缀优先，官方=GitHub 直链优先。偏好源失败仍自动回退其余源。')
                  .fontSize(11).fontColor(Ui.textTertiary).width('100%')
              }.width('100%')
            }
            .width('100%').padding(16).borderRadius(20)
            .backgroundColor(Ui.surfaceMuted).borderWidth(1).borderColor(Ui.border)

            Blank().height(24)
          }
          .width('100%')
          .constraintSize({ maxWidth: Ui.pageMaxWidth })
          .padding({ left: 18, right: 18, top: 6, bottom: 24 })
        }
        .width('100%').layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      .width('100%').height('100%')
    }
    .width('100%').height('100%')
  }

  @Builder
  SectionHeader(icon: string, title: Resource) {
    Row({ space: 7 }) {
      Text(icon).fontSize(16).fontColor(Ui.textSecondary)
      Text(title).fontSize(15).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
      Blank()
    }
    .width('100%')
  }

  @Builder
  ToggleRow(label: Resource, desc: Resource, isOn: boolean, onChange: (v: boolean) => void) {
    Column({ space: 4 }) {
      Row() {
        Text(label).fontSize(14).fontColor(Ui.textPrimary).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: isOn })
          .selectedColor(Ui.primaryBlueFill)
          .onChange(onChange)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      Text(desc).fontSize(11).fontColor(Ui.textTertiary).width('100%')
    }
    .width('100%')
  }

  @Builder
  StepperRow(label: Resource, desc: Resource, value: number, useSeconds: boolean,
    onStep: (delta: number) => void) {
    Column({ space: 4 }) {
      Row() {
        Text(label).fontSize(14).fontColor(Ui.textPrimary).layoutWeight(1)
        Row({ space: 0 }) {
          Text('−')
            .fontSize(18).fontColor(Ui.textPrimary)
            .width(34).height(30).textAlign(TextAlign.Center)
            .borderRadius(8).backgroundColor(Ui.inputBackground)
            .onClick(() => onStep(-1))
          Text(useSeconds ? $r('app.string.settings_seconds_value', value) : `${value}`)
            .fontSize(14).fontColor(Ui.textPrimary)
            .constraintSize({ minWidth: 62 })
            .textAlign(TextAlign.Center)
            .padding({ left: 6, right: 6 })
          Text('+')
            .fontSize(18).fontColor(Ui.textPrimary)
            .width(34).height(30).textAlign(TextAlign.Center)
            .borderRadius(8).backgroundColor(Ui.inputBackground)
            .onClick(() => onStep(1))
        }
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      Text(desc).fontSize(11).fontColor(Ui.textTertiary).width('100%')
    }
    .width('100%')
  }

  @Builder
  SelectChip(mode: string, label: Resource) {
    Text(label)
      .fontSize(14)
      .fontWeight(FontWeight.Bold)
      .fontColor(this.autoSelectMode === mode ? Ui.textViolet : Ui.textSecondary)
      .layoutWeight(1)
      .textAlign(TextAlign.Center)
      .padding({ top: 9, bottom: 9 })
      .borderRadius(11)
      .backgroundColor(this.autoSelectMode === mode ? Ui.selectedBackground : Color.Transparent)
      .borderWidth(this.autoSelectMode === mode ? 1 : 0)
      .borderColor(this.autoSelectMode === mode ? Ui.primary : Color.Transparent)
      .onClick(() => this.setSelectMode(mode))
  }
}
