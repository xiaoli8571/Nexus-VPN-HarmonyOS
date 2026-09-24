/**
 * 诊断面板（底部弹出）
 * 移植自 upstream: SSRVPN_Android/lib/widgets/android_diagnostics_sheet.dart
 *                packages/ssrvpn_shared/lib/widgets/app_diagnostics_view.dart
 *
 * 第二阶段·第三轮增强：新增「链路健康自检」区域
 *   - 展示 lastHealthReport() 的分项（label/status/detail/耗时）
 *   - 最近修复步数 healthRepairStepsLast()、是否正在自检 isHealthCheckRunning()
 *   - 当前网络类型与 generation、重连状态 reconnectState()
 *   - 「立即自检」按钮：复用既有纯逻辑服务 runLinkHealthCheck + OrchestratorHealthProbes
 *     （均为既有的公开入口，未新增任何后端逻辑，也未修改服务模块）
 *   - 「复制脱敏报告」：复用既有 LogRedactor 脱敏能力 + AppLogger 已脱敏日志
 */
import { Ui } from '../theme/UiTokens';
import { AppDiagnostics } from '../commons/models/PublicIpInfo';
import { AppLogger, LogRedactor } from '../commons/utils/AppLogger';
import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { ConnectionOrchestrator, ReconnectRuntimeState } from '../commons/services/ConnectionOrchestrator';
import { SettingsService } from '../commons/services/SettingsService';
import {
  LinkHealthItem, LinkHealthReport, summarize, runLinkHealthCheck,
  repairSteps, HealthStatus, HealthOverall
} from '../commons/services/LinkHealthChecker';
import { OrchestratorHealthProbes } from '../commons/services/OrchestratorHealthProbes';

@Component
export struct DiagnosticsSheet {
  @Prop diag: AppDiagnostics | null = null;
  onRefresh: () => void = () => {};
  onClose: () => void = () => {};

  // ── 链路健康自检状态 ──
  @State healthItems: LinkHealthItem[] = [];
  @State hasReport: boolean = false;
  @State overall: string = '';
  @State passCount: number = 0;
  @State failCount: number = 0;
  @State skipCount: number = 0;
  @State repairCount: number = 0;
  @State running: boolean = false;
  // ── 运行态 ──
  @State netType: string = 'unknown';
  @State generation: number = 0;
  @State reconnectActive: boolean = false;
  @State reconnectConnecting: boolean = false;
  @State reconnectPendingMs: number = 0;

  private orchestrator: ConnectionOrchestrator = ConnectionOrchestrator.instance();
  private boundCb: (() => void) | null = null;

  aboutToAppear(): void {
    this.orchestrator.init(getContext(this) as Context);
    this.syncFromOrchestratorReport();
    this.syncRuntimeView();
    if (this.boundCb === null) {
      // 订阅既有 orchestrator 通知：网络类型/代际、重连退避、自检运行态变化即时刷新
      const cb: () => void = (): void => {
        this.syncRuntimeView();
      };
      this.boundCb = cb;
      this.orchestrator.listeners.push(cb);
    }
  }

  aboutToDisappear(): void {
    const cb = this.boundCb;
    if (cb !== null) {
      const idx = this.orchestrator.listeners.indexOf(cb);
      if (idx >= 0) {
        this.orchestrator.listeners.splice(idx, 1);
      }
      this.boundCb = null;
    }
  }

  /** 读取编排器缓存的自检报告/汇总/修复步数（不触发任何检查） */
  private syncFromOrchestratorReport(): void {
    const report = this.orchestrator.lastHealthReport();
    if (report !== null) {
      this.applyReport(report);
    }
    this.repairCount = this.orchestrator.healthRepairStepsLast().length;
  }

  /** 读取运行态：网络类型/代际/重连快照/自检运行中 */
  private syncRuntimeView(): void {
    this.running = this.orchestrator.isHealthCheckRunning();
    this.netType = this.orchestrator.currentNetworkType();
    this.generation = this.orchestrator.networkGeneration();
    const r: ReconnectRuntimeState = this.orchestrator.reconnectState();
    this.reconnectActive = r.active;
    this.reconnectConnecting = r.connecting;
    this.reconnectPendingMs = r.pendingDelayMs;
  }

  private applyReport(report: LinkHealthReport): void {
    const summary = summarize(report);
    this.overall = summary.overall;
    this.passCount = summary.passCount;
    this.failCount = summary.failCount;
    this.skipCount = summary.skipCount;
    this.healthItems = report.items.slice();
    this.hasReport = report.items.length > 0;
  }

  /**
   * 「立即自检」：复用既有纯逻辑自检服务与既有探针实现。
   * 不新增后端逻辑，不写编排器缓存（只影响本弹窗展示）。
   */
  private async runNow(): Promise<void> {
    if (this.running) {
      return;
    }
    this.running = true;
    try {
      const report = await runLinkHealthCheck(new OrchestratorHealthProbes(this.orchestrator));
      this.applyReport(report);
      let maxSteps = 2;
      try {
        const s = await SettingsService.load();
        maxSteps = s.healthRepairMaxSteps;
      } catch (e) {
        maxSteps = 2;
      }
      this.repairCount = repairSteps(report, maxSteps).length;
    } catch (e) {
      // runLinkHealthCheck 内部已把异常收敛为 fail 项，这里仅兜底
    }
    this.running = false;
  }

  /** 复制/导出脱敏报告：复用既有 LogRedactor；AppLogger.dump() 本身已脱敏 */
  private copyReport(): void {
    try {
      const parts: string[] = [];
      parts.push(`Nexus diagnostics @ ${new Date().toISOString()}`);
      const d = this.diag;
      const coreUp = d !== null && d.coreRunning;
      const vpnOn = d !== null && d.vpnActive;
      const apiUp = d !== null && d.clashApiReachable;
      const uptime = d !== null ? d.uptimeSeconds : 0;
      parts.push(`core=${coreUp ? 'up' : 'down'} vpn=${vpnOn ? 'on' : 'off'} `
        + `api=${apiUp ? 'reachable' : 'unreachable'} uptime=${uptime}s`);
      parts.push(`health overall=${this.overall.length > 0 ? this.overall : 'n/a'} `
        + `pass=${this.passCount} fail=${this.failCount} skip=${this.skipCount} `
        + `repairSteps=${this.repairCount} running=${this.running}`);
      for (const it of this.healthItems) {
        const val = it.value.length > 0 ? ` => ${it.value}` : '';
        const dur = it.durationMs > 0 ? ` [${it.durationMs}ms]` : '';
        parts.push(`[${it.status}] ${it.id} (${it.label}): ${it.detail}${val}${dur}`);
      }
      const rc = this.reconnectConnecting ? 'connecting'
        : (this.reconnectActive ? `backoff:${this.reconnectPendingMs}ms` : 'idle');
      parts.push(`net=${this.netType} gen=${this.generation} reconnect=${rc}`);
      parts.push('');
      parts.push(AppLogger.dump().join('\n'));
      const safe = LogRedactor.redact(parts.join('\n'));
      const data = pasteboard.getSystemPasteboard();
      data.setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, safe));
      promptAction.showToast({ message: $r('app.string.diagnostics_health_report_copied') });
    } catch (e) {
      promptAction.showToast({ message: $r('app.string.diagnostics_health_copy_failed') });
    }
  }

  // ── 展示辅助 ──

  private statusLabel(status: string): Resource {
    if (status === HealthStatus.PASS) {
      return $r('app.string.diagnostics_status_pass');
    }
    if (status === HealthStatus.FAIL) {
      return $r('app.string.diagnostics_status_fail');
    }
    return $r('app.string.diagnostics_status_skip');
  }

  private statusColor(status: string): ResourceColor {
    if (status === HealthStatus.PASS) {
      return Ui.success;
    }
    if (status === HealthStatus.FAIL) {
      return Ui.error;
    }
    return Ui.textTertiary;
  }

  private overallLabel(): Resource {
    if (this.overall === HealthOverall.OK) {
      return $r('app.string.diagnostics_health_overall_ok');
    }
    if (this.overall === HealthOverall.BROKEN) {
      return $r('app.string.diagnostics_health_overall_broken');
    }
    return $r('app.string.diagnostics_health_overall_degraded');
  }

  private overallColor(): ResourceColor {
    if (this.overall === HealthOverall.OK) {
      return Ui.success;
    }
    if (this.overall === HealthOverall.BROKEN) {
      return Ui.error;
    }
    return Ui.warning;
  }

  private reconnectLabel(): Resource {
    if (this.reconnectConnecting) {
      return $r('app.string.diagnostics_health_reconnect_connecting');
    }
    if (this.reconnectActive) {
      return $r('app.string.diagnostics_health_reconnect_active', this.reconnectPendingMs);
    }
    return $r('app.string.diagnostics_health_reconnect_idle');
  }

  build() {
    Column({ space: 10 }) {
      Row() {
        Text($r('app.string.diagnostics_title'))
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(Ui.textPrimary)
        Blank()
        Text($r('app.string.diagnostics_refresh'))
          .fontSize(14)
          .fontColor(Ui.primary)
          .onClick(() => this.onRefresh())
        Text($r('app.string.diagnostics_close'))
          .fontSize(14)
          .fontColor(Ui.textSecondary)
          .onClick(() => this.onClose())
          .padding({ left: 16 })
      }
      .width('100%')

      Row() {
        Text($r('app.string.diagnostics_core_running')).fontSize(14).fontColor(Ui.textSecondary).layoutWeight(1)
        Text(this.diag !== null && this.diag.coreRunning
          ? $r('app.string.diagnostics_core_ok') : $r('app.string.diagnostics_core_stopped'))
          .fontSize(14)
          .fontColor(this.diag !== null && this.diag.coreRunning ? Ui.success : Ui.error)
      }.width('100%')

      Row() {
        Text($r('app.string.diagnostics_vpn_active')).fontSize(14).fontColor(Ui.textSecondary).layoutWeight(1)
        Text(this.diag !== null && this.diag.vpnActive
          ? $r('app.string.diagnostics_vpn_on') : $r('app.string.diagnostics_vpn_off'))
          .fontSize(14)
          .fontColor(this.diag !== null && this.diag.vpnActive ? Ui.success : Ui.warning)
      }.width('100%')

      Row() {
        Text($r('app.string.diagnostics_clash_api')).fontSize(14).fontColor(Ui.textSecondary).layoutWeight(1)
        Text(this.diag !== null && this.diag.clashApiReachable
          ? $r('app.string.diagnostics_api_reachable', this.diag.clashApiPort)
          : $r('app.string.diagnostics_api_unreachable'))
          .fontSize(14)
          .fontColor(this.diag !== null && this.diag.clashApiReachable ? Ui.success : Ui.error)
      }.width('100%')

      Row() {
        Text($r('app.string.diagnostics_uptime')).fontSize(14).fontColor(Ui.textSecondary).layoutWeight(1)
        Text(`${this.diag !== null ? this.diag.uptimeSeconds : 0}s`)
          .fontSize(14).fontColor(Ui.textPrimary)
      }.width('100%')

      if (this.diag !== null && this.diag.lastError.length > 0) {
        Text($r('app.string.diagnostics_last_error', this.diag.lastError))
          .fontSize(13)
          .fontColor(Ui.error)
          .width('100%')
      }

      Divider().color(Ui.border)

      // ── 链路健康自检 ──
      Row() {
        Text($r('app.string.diagnostics_health_title'))
          .fontSize(14).fontWeight(FontWeight.Medium).fontColor(Ui.textPrimary)
        if (this.hasReport) {
          Text(this.overallLabel())
            .fontSize(12)
            .fontColor(this.overallColor())
            .padding({ left: 8 })
        }
        Blank()
        Text(this.running
          ? $r('app.string.diagnostics_health_running')
          : $r('app.string.diagnostics_health_run_now'))
          .fontSize(13)
          .fontColor(this.running ? Ui.textTertiary : Ui.primary)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .borderRadius(10)
          .backgroundColor(Ui.surfaceTranslucent)
          .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
            colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
          })
          .backgroundEffect({ radius: Ui.glassControlBlurRadius, saturation: Ui.glassControlSaturation, brightness: Ui.glassControlBrightness })
          .borderWidth(1)
          .borderColor(Ui.glassEdge)
          .onClick(() => {
            if (!this.running) {
              this.runNow();
            }
          })
        Text($r('app.string.diagnostics_health_copy_report'))
          .fontSize(13)
          .fontColor(Ui.textBlue)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .onClick(() => this.copyReport())
      }
      .width('100%')

      if (this.hasReport) {
        Row() {
          Text($r('app.string.diagnostics_health_counts', this.passCount, this.failCount, this.skipCount))
            .fontSize(12).fontColor(Ui.textSecondary).layoutWeight(1)
          Text($r('app.string.diagnostics_health_repair_steps'))
            .fontSize(12).fontColor(Ui.textSecondary)
          Text(this.repairCount > 0 ? `${this.repairCount}` : $r('app.string.diagnostics_health_repair_none'))
            .fontSize(12).fontColor(Ui.textPrimary).padding({ left: 6 })
        }.width('100%')
      } else {
        Text($r('app.string.diagnostics_health_not_run'))
          .fontSize(12).fontColor(Ui.textTertiary).width('100%')
      }

      Row({ space: 12 }) {
        Row({ space: 4 }) {
          Text($r('app.string.diagnostics_health_network')).fontSize(11).fontColor(Ui.textTertiary)
          Text(this.netType.length > 0 ? this.netType : '-').fontSize(11).fontColor(Ui.textSecondary)
        }
        Row({ space: 4 }) {
          Text($r('app.string.diagnostics_health_generation')).fontSize(11).fontColor(Ui.textTertiary)
          Text(`${this.generation}`).fontSize(11).fontColor(Ui.textSecondary)
        }
        Row({ space: 4 }) {
          Text($r('app.string.diagnostics_health_reconnect')).fontSize(11).fontColor(Ui.textTertiary)
          Text(this.reconnectLabel())
            .fontSize(11)
            .fontColor(this.reconnectActive || this.reconnectConnecting ? Ui.warning : Ui.textSecondary)
        }
      }
      .width('100%')

      if (this.hasReport) {
        List({ space: 4 }) {
          ForEach(this.healthItems, (item: LinkHealthItem) => {
            ListItem() {
              Column({ space: 2 }) {
                Row({ space: 6 }) {
                  Text(this.statusLabel(item.status))
                    .fontSize(11)
                    .fontColor(this.statusColor(item.status))
                    .constraintSize({ minWidth: 30 })
                  Text(item.label)
                    .fontSize(12).fontColor(Ui.textPrimary).layoutWeight(1).maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`${item.durationMs}ms`)
                    .fontSize(10).fontColor(Ui.textTertiary)
                }.width('100%')
                Text(item.detail.length > 0 ? item.detail : item.advice)
                  .fontSize(10).fontColor(Ui.textSecondary).width('100%').maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
            }
          }, (item: LinkHealthItem) => item.id + '#' + item.status + '#' + item.durationMs.toString())
        }
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
      } else {
        Blank().layoutWeight(1)
      }

      Divider().color(Ui.border)

      Text($r('app.string.diagnostics_log_title'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(Ui.textPrimary)

      List() {
        ForEach(AppLogger.dump(), (line: string) => {
          ListItem() {
            Text(line)
              .fontSize(11)
              .fontFamily('monospace')
              .fontColor(Ui.textSecondary)
              .width('100%')
              .padding({ top: 1, bottom: 1 })
          }
        }, (line: string, idx: number) => `${idx}-${line.length}`)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
    }
    .padding(20)
    .backgroundColor(Ui.surfaceTranslucent)
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
      colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
    })
    .backgroundEffect({
      radius: Ui.glassBlurRadius,
      saturation: Ui.glassSaturationSoft,
      brightness: Ui.glassBrightnessSoft
    })
    .borderWidth({ top: 1 })
    .borderColor(Ui.glassEdge)
    .shadow({ radius: 32, color: Ui.shadow, offsetY: -10 })
    .borderRadius({ topLeft: 20, topRight: 20 })
  }
}
