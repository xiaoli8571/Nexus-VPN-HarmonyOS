/**
 * HomePage —— Nexus VPN 主页（对齐 Nexus_VPN_完整UI设计_index.html + Ultimate 开发文档 §3/§4/§5/§8/§9）
 * 布局：顶部备份入口+Nexus品牌 → 状态环(172) → 速率卡(含折线+微字号流量/时长) → 双卡片(分流/规则) → 液态玻璃Dock
 * 后端：复用 ConnectionOrchestrator / SubscriptionService / SettingsService / LatencyController 全量逻辑。
 */
import { router, promptAction } from '@kit.ArkUI';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { window } from '@kit.ArkUI';
import { Nx, NexusSizes } from '../theme/NexusTokens';
import { StatusRing } from '../components/StatusRing';
import { RateChart } from '../components/RateChart';
import { LiquidGlassDock } from '../components/LiquidGlassDock';
import { ConnectionOrchestrator, ConnState } from '../commons/services/ConnectionOrchestrator';
import { SubscriptionService } from '../commons/services/SubscriptionService';
import { SettingsService } from '../commons/services/SettingsService';
import { PublicIpService } from '../commons/services/PublicIpService';
import { PublicIpInfo, AppDiagnostics } from '../commons/models/PublicIpInfo';
import { AppSettings, AutoSelectModes } from '../commons/models/AppSettings';
import { ClashConfigGenerator } from '../commons/services/ClashConfigGenerator';
import { LatencyController } from '../commons/services/LatencyController';
import { FormStateSync } from '../commons/services/FormStateSync';
import { UiGuardian } from '../commons/services/UiGuardian';
import { DiagnosticsSheet } from '../widgets/DiagnosticsSheet';
import { AppLogger } from '../commons/utils/AppLogger';
import { ThemeService } from '../theme/ThemeService';
import { ProxyNode } from '../commons/models/ProxyNode';
import { NodeSortSnapshot } from '../commons/services/NodeSortPersistence';
import { BackupRestoreService } from '../commons/services/BackupRestoreService';

const TAG = 'HomePage';

/** 网络规则 4 选项弹窗：规则 / 强制代理 / 强制直连 / 应用分流 */
@CustomDialog
struct NetworkRulesDialog {
  controller?: CustomDialogController;
  getProxyCount: () => number = (): number => 0;
  getDirectCount: () => number = (): number => 0;
  getAppSummary: () => string = (): string => '';
  getRulesSummary: () => string = (): string => '';
  onPick: (kind: string) => void = () => {};
  @State proxyCount: number = 0;
  @State directCount: number = 0;
  @State appSummary: string = '';
  @State rulesSummary: string = '';

  aboutToAppear(): void {
    this.proxyCount = this.getProxyCount();
    this.directCount = this.getDirectCount();
    this.appSummary = this.getAppSummary();
    this.rulesSummary = this.getRulesSummary();
  }

  @Builder
  OptionRow(icon: string, title: string, detail: string, kind: string) {
    Row({ space: 12 }) {
      Text(icon).fontSize(20).fontColor(Nx.accent())
        .width(40).height(40).textAlign(TextAlign.Center)
        .borderRadius(12).backgroundColor(Nx.accentSoft())
      Column({ space: 3 }) {
        Text(title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(Nx.fg())
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(detail).fontSize(11).fontColor(Nx.muted())
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Text('›').fontSize(20).fontColor(Nx.faint())
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .borderRadius(15)
    .backgroundColor(Nx.surface())
    .borderWidth(1)
    .borderColor(Nx.border())
    .onClick(() => this.onPick(kind))
  }

  build() {
    Column({ space: 10 }) {
      Text('规则模式设置').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Nx.fg())
      this.OptionRow('☷', '广告与隐私拦截规则', this.rulesSummary, 'rules')
      this.OptionRow('↗', '强制代理网站名单', `代理 ${this.proxyCount} 个域名`, 'proxy')
      this.OptionRow('↘', '强制直连网站名单', `直连 ${this.directCount} 个域名`, 'direct')
      this.OptionRow('▦', '应用分流策略设置', this.appSummary, 'app')
      Button('关闭')
        .width('100%')
        .backgroundColor(Nx.fgSoft())
        .fontColor(Nx.fg())
        .borderRadius(8)
        .onClick(() => {
          if (this.controller !== undefined) {
            this.controller.close();
          }
        })
    }
    .padding(20)
    .borderRadius(20)
    .backgroundColor(Nx.surface())
    .borderWidth(1)
    .borderColor(Nx.border())
    .shadow({ radius: 28, color: 'rgba(15, 23, 42, 0.25)', offsetY: 12 })
  }
}

/** 配置备份与恢复弹窗（Nexus §9）：导出/导入订阅+自定义规则 JSON */
@CustomDialog
struct BackupDialog {
  controller?: CustomDialogController;
  @State toastMsg: string = '';
  onExport: () => void = () => {};
  onImport: () => void = () => {};
  getToast: () => string = (): string => '';

  aboutToAppear(): void {
    this.toastMsg = '';
  }

  build() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text('▣').fontSize(20).fontColor(Nx.accent())
        Text('配置备份与恢复').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Nx.fg()).layoutWeight(1)
        Text('✕').fontSize(16).fontColor(Nx.muted()).padding(6)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
      }.width('100%')
      Text('备份范围包括当前全部已导入的订阅、节点以及自定义规则配置。')
        .fontSize(12).fontColor(Nx.muted()).width('100%')
      Column({ space: 4 }) {
        Text('📤 导出当前配置备份').fontSize(13).fontWeight(FontWeight.Bold).fontColor(Nx.fg()).width('100%')
        Text('生成包含所有订阅和规则的 .json 备份文件，便于多设备同步或留存。')
          .fontSize(11).fontColor(Nx.muted()).width('100%')
        Button('导出备份文件 (.json)')
          .width('100%').borderRadius(8)
          .backgroundColor(Nx.accent()).fontColor(Color.White).fontSize(12.5)
          .onClick(() => this.onExport())
      }
      .width('100%').padding(12).borderRadius(12)
      .backgroundColor(Nx.bg())
      .borderWidth(1).borderColor(Nx.border())
      Column({ space: 4 }) {
        Text('📥 导入恢复配置').fontSize(13).fontWeight(FontWeight.Bold).fontColor(Nx.fg()).width('100%')
        Text('上传备份的 .json 配置文件，一键恢复所有订阅及自定义规则。')
          .fontSize(11).fontColor(Nx.muted()).width('100%')
        Button('选择备份文件并恢复')
          .width('100%').borderRadius(8)
          .backgroundColor(Nx.surface()).fontColor(Nx.fg()).fontSize(12.5)
          .borderWidth(1.5).borderColor(Nx.border())
          .onClick(() => this.onImport())
      }
      .width('100%').padding(12).borderRadius(12)
      .backgroundColor(Nx.bg())
      .borderWidth(1).borderColor(Nx.border())
      if (this.getToast().length > 0) {
        Text(this.getToast())
          .fontSize(11.5).fontWeight(FontWeight.Bold).fontColor(Color.White)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(9999).backgroundColor(Nx.success())
      }
    }
    .padding(20)
    .borderRadius(20)
    .backgroundColor(Nx.surface())
    .borderWidth(1)
    .borderColor(Nx.border())
    .shadow({ radius: 28, color: 'rgba(15, 23, 42, 0.25)', offsetY: 12 })
  }
}

@Entry
@Component
struct HomePage {
  @State isConnected: boolean = false;
  @State isConnecting: boolean = false;
  @State errorMessage: string = '';
  @State publicIp: string = '';
  @State publicIpRefreshing: boolean = false;
  @State publicIpError: string = '';
  @State currentNodeName: string = '';
  @State currentLatencyTick: number = 0;
  @State showDiagnostics: boolean = false;
  @State diagData: AppDiagnostics | null = null;
  @State upSpeed: number = 0;
  @State downSpeed: number = 0;
  @State upTotal: number = 0;
  @State downTotal: number = 0;
  @State connectionDuration: number = 0;
  @State proxyMode: string = 'rule';
  @State rulesSummary: string = '加载中…';
  @State networkRulesSummary: string = '加载中…';
  @State ratePoints: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
  @State backupToast: string = '';
  @StorageLink('theme_revision') themeRevision: number = 0;
  @StorageLink('public_ip_revision') @Watch('onPublicIpRevision') publicIpRevision: number = 0;
  @StorageLink('vpn_request_seq') @Watch('onVpnRequest') vpnRequestSeq: number = 0;
  private pageReady: boolean = false;
  private orchestrator: ConnectionOrchestrator = ConnectionOrchestrator.instance();
  private subs: SubscriptionService = SubscriptionService.instance();
  private settings: AppSettings = new AppSettings();
  private readonly connectionListener: () => void = (): void => {
    this.applyOrchestratorState();
  };
  private readonly latencyListener: () => void = (): void => {
    this.currentLatencyTick = this.currentLatencyTick + 1;
  };
  private listenerBound: boolean = false;
  private latencyListenerBound: boolean = false;
  private connectionTimer: number = -1;
  private networkRulesDialog: CustomDialogController = new CustomDialogController({
    builder: NetworkRulesDialog({
      getProxyCount: (): number => this.settings.forceProxySites.length,
      getDirectCount: (): number => this.settings.forceDirectSites.length,
      getAppSummary: (): string => this.networkRulesSummary.split('\n')[1] ?? '',
      getRulesSummary: (): string => this.rulesSummary,
      onPick: (kind: string): void => {
        this.networkRulesDialog.close();
        if (kind === 'rules') {
          setTimeout((): void => {
            router.pushUrl({ url: 'pages/RulesPage' });
          }, 120);
        } else if (kind === 'app') {
          setTimeout((): void => {
            router.pushUrl({ url: 'pages/AppRoutingPage' });
          }, 120);
        } else {
          setTimeout((): void => {
            router.pushUrl({ url: 'pages/SiteRoutingPage', params: { kind: kind === 'direct' ? 'direct' : 'proxy' } });
          }, 120);
        }
      }
    }),
    autoCancel: true
  });
  private backupDialog: CustomDialogController = new CustomDialogController({
    builder: BackupDialog({
      getToast: (): string => this.backupToast,
      onExport: (): void => {
        this.exportBackup();
      },
      onImport: (): void => {
        this.importBackup();
      }
    }),
    autoCancel: true
  });

  onPageShow(): void {
    this.bootstrap();
  }

  aboutToDisappear(): void {
    this.pageReady = false;
    this.stopConnectionTimer();
    if (this.listenerBound) {
      this.orchestrator.removeListener(this.connectionListener);
      this.listenerBound = false;
    }
    if (this.latencyListenerBound) {
      LatencyController.removeListener(this.latencyListener);
      this.latencyListenerBound = false;
    }
  }

  private applyOrchestratorState(): void {
    this.isConnected = this.orchestrator.state === ConnState.CONNECTED;
    // App 内手动连接路径的会话守护：连接成功注册 dataTransfer 连续任务（防杀），
    // 断开/失败释放。幂等，状态重复同步不会重复注册/释放。
    if (this.isConnected && !UiGuardian.isRegistered()) {
      UiGuardian.engage(getContext(this) as Context).catch((): void => {});
    } else if (!this.isConnected && UiGuardian.isRegistered()
      && this.orchestrator.state !== ConnState.CONNECTING
      && this.orchestrator.state !== ConnState.DISCONNECTING
      && this.orchestrator.state !== ConnState.RECOVERING) {
      UiGuardian.release(getContext(this) as Context).catch((): void => {});
    }
    this.isConnecting = this.orchestrator.state === ConnState.CONNECTING
      || this.orchestrator.state === ConnState.DISCONNECTING
      || this.orchestrator.state === ConnState.RECOVERING;
    this.errorMessage = this.orchestrator.lastError;
    this.upSpeed = this.orchestrator.traffic.uploadSpeed;
    this.downSpeed = this.orchestrator.traffic.downloadSpeed;
    this.upTotal = this.orchestrator.traffic.uploadBytes;
    this.downTotal = this.orchestrator.traffic.downloadBytes;
    if (!this.isConnected) {
      this.ratePoints = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    }
    if (this.pageReady) {
      this.syncConnectionTimer();
    }
    this.refreshDisplayNode();
  }

  private syncConnectionTimer(): void {
    if (this.orchestrator.state !== ConnState.CONNECTED || this.orchestrator.startedAt <= 0) {
      this.connectionDuration = 0;
      this.stopConnectionTimer();
      return;
    }
    this.connectionDuration = Math.max(0,
      Math.floor((Date.now() - this.orchestrator.startedAt) / 1000));
    if (this.connectionTimer >= 0) {
      return;
    }
    this.connectionTimer = setInterval(() => {
      if (this.orchestrator.state !== ConnState.CONNECTED || this.orchestrator.startedAt <= 0) {
        this.connectionDuration = 0;
        this.stopConnectionTimer();
        return;
      }
      this.connectionDuration = Math.max(0,
        Math.floor((Date.now() - this.orchestrator.startedAt) / 1000));
      // Nexus 速率采样：滑动窗口 26 点，量程 1500KB/s
      const speed = this.orchestrator.traffic.uploadSpeed + this.orchestrator.traffic.downloadSpeed;
      const ratio = Math.min(1, Math.max(0, speed / (1500 * 1024)));
      const next = this.ratePoints.slice();
      next.push(ratio);
      if (next.length > NexusSizes.ratePoints) {
        next.splice(0, next.length - NexusSizes.ratePoints);
      }
      this.ratePoints = next;
      this.upSpeed = this.orchestrator.traffic.uploadSpeed;
      this.downSpeed = this.orchestrator.traffic.downloadSpeed;
      this.upTotal = this.orchestrator.traffic.uploadBytes;
      this.downTotal = this.orchestrator.traffic.downloadBytes;
    }, 1000);
  }

  private stopConnectionTimer(): void {
    if (this.connectionTimer >= 0) {
      clearInterval(this.connectionTimer);
      this.connectionTimer = -1;
    }
  }

  private async toggleTheme(): Promise<void> {
    await ThemeService.toggle();
    const mainWindow = AppStorage.get<window.Window>('main_window');
    if (mainWindow !== undefined) {
      await ThemeService.syncSystemBars(mainWindow);
    }
  }

  private async bootstrap(): Promise<void> {
    const ctx = getContext(this) as Context;
    this.orchestrator.init(ctx);
    await SettingsService.init(ctx);
    await this.subs.init(ctx);
    this.settings = await SettingsService.load();
    this.rulesSummary = this.settings.rulesEnabled
      ? `${this.settings.hyperAdRulesEnabled ? '去广告已开' : '去广告已关'} · 自定义 ${this.settings.customRules.length} 条`
      : '规则已关闭';
    const appSummary = this.settings.appRoutingMode === 'exclude'
      ? `绕过 ${this.settings.excludedApps.length} 个应用`
      : (this.settings.appRoutingMode === 'include'
        ? `仅 ${this.settings.includedApps.length} 个应用` : '全部应用');
    this.networkRulesSummary = `代理 ${this.settings.forceProxySites.length} · 直连 ${this.settings.forceDirectSites.length}`
      + `\n${appSummary}${this.settings.appRoutingNeedsReview ? ' · 待确认' : ''}`;
    const latencySnapshot = NodeSortSnapshot.fromJsonText(this.settings.nodeSortSnapshot);
    if (latencySnapshot !== null) {
      for (const rec of latencySnapshot.records) {
        if (rec.latency !== -2) {
          LatencyController.set(rec.name, rec.latency);
        }
      }
      LatencyController.flushNow();
    }
    this.proxyMode = this.settings.proxyMode === 'global' ? 'global' : 'rule';
    const authority = await this.orchestrator.authorityState();
    const snapshot = await SettingsService.loadSnapshot();
    if (authority.connected) {
      this.orchestrator.state = ConnState.CONNECTED;
      if (this.orchestrator.startedAt <= 0 && snapshot.startedAt > 0) {
        this.orchestrator.startedAt = snapshot.startedAt;
      }
    }
    if (!this.listenerBound) {
      this.listenerBound = true;
      this.orchestrator.addListener(this.connectionListener);
    }
    if (!this.latencyListenerBound) {
      this.latencyListenerBound = true;
      LatencyController.addListener(this.latencyListener);
    }
    if (this.publicIp.length === 0) {
      setTimeout((): void => {
        this.refreshPublicIp().catch((): void => {});
      }, 0);
    }
    this.applyOrchestratorState();
    this.pageReady = true;
    this.syncConnectionTimer();
    this.consumeVpnRequest();
  }

  onPublicIpRevision(): void {
    if (!this.pageReady || this.publicIpRefreshing) {
      return;
    }
    this.publicIp = '';
    this.refreshPublicIp().catch((): void => {});
  }

  onVpnRequest(): void {
    this.consumeVpnRequest();
  }

  private consumeVpnRequest(): void {
    if (!this.pageReady) {
      return;
    }
    const mode = AppStorage.get<string>('vpn_request_mode') ?? '';
    if (mode.length === 0) {
      return;
    }
    AppStorage.setOrCreate('vpn_request_mode', '');
    if (mode === 'start') {
      this.startConnectionIfNeeded();
    } else if (mode === 'toggle') {
      this.toggleConnection();
    }
  }

  private async startConnectionIfNeeded(): Promise<void> {
    if (this.isConnecting || this.isConnected) {
      return;
    }
    const node = this.selectedNode();
    if (node === null) {
      promptAction.showToast({ message: '暂无可用节点，请先在「订阅」页添加并刷新' });
      return;
    }
    const ok = await this.orchestrator.connect(node, this.subs);
    if (ok) {
      this.refreshPublicIp();
    }
  }

  private selectedNode(): ProxyNode | null {
    const preferred: ProxyNode | null = this.subs.findNode(this.settings.preferredNodeId);
    if (preferred !== null) {
      return preferred;
    }
    if (this.subs.nodes.length > 0) {
      return this.subs.nodes[0];
    }
    return null;
  }

  private refreshDisplayNode(): void {
    if (this.settings.autoSelectMode === AutoSelectModes.AUTO
      && this.orchestrator.ensureSmartModelReady()) {
      this.currentNodeName = ClashConfigGenerator.SMART_GROUP_NAME;
      return;
    }
    const preferred = this.subs.findNode(this.settings.preferredNodeId);
    if (preferred !== null) {
      this.currentNodeName = preferred.name;
      return;
    }
    if (this.subs.nodes.length > 0) {
      this.currentNodeName = this.subs.nodes[0].name;
      return;
    }
    this.currentNodeName = '';
  }

  private statusText(): string {
    if (this.isConnecting) {
      return this.isConnected ? '正在断开' : '正在连接';
    }
    if (this.errorMessage.length > 0) {
      return '连接异常';
    }
    if (this.isConnected) {
      return '已连接';
    }
    return '未连接';
  }

  private refreshDiagnostics(): void {
    this.orchestrator.diagnostics().then((d: AppDiagnostics) => {
      this.diagData = d;
    }).catch(() => {
      this.diagData = null;
    });
  }

  private async refreshPublicIp(): Promise<void> {
    this.publicIpRefreshing = true;
    this.publicIpError = '';
    const info: PublicIpInfo = await PublicIpService.query();
    if (info.ip.length > 0) {
      this.publicIp = info.ip;
    } else {
      this.publicIp = '';
      this.publicIpError = '获取公网 IPv4 失败，点击重试';
    }
    this.publicIpRefreshing = false;
  }

  private async toggleConnection(): Promise<void> {
    const context = getContext(this) as Context;
    const node = this.selectedNode();
    const nodeName = node === null ? '' : node.name;
    if (this.isConnecting) {
      return;
    }
    if (this.isConnected) {
      await FormStateSync.publish(context, FormStateSync.disconnecting(nodeName));
      await this.orchestrator.disconnect();
      await FormStateSync.publish(context,
        node === null ? FormStateSync.noNode() : FormStateSync.disconnected(nodeName));
      this.refreshPublicIp();
      return;
    }
    if (node === null) {
      await FormStateSync.publish(context, FormStateSync.noNode());
      promptAction.showToast({ message: '暂无可用节点，请先在「订阅」页添加并刷新' });
      return;
    }
    await FormStateSync.publish(context, FormStateSync.connecting(node.name));
    const ok = await this.orchestrator.connect(node, this.subs);
    await FormStateSync.publish(context,
      ok ? FormStateSync.connected(node.name) : FormStateSync.failed(node.name));
    if (ok) {
      this.refreshPublicIp();
    }
  }

  private async applyProxyMode(mode: string): Promise<void> {
    if (mode === this.proxyMode) {
      return;
    }
    this.proxyMode = mode;
    this.settings.proxyMode = mode;
    await SettingsService.save(this.settings);
    const label = mode === 'global' ? '全局模式' : '智能模式';
    await this.orchestrator.applyProxyMode(mode);
    promptAction.showToast({
      message: this.orchestrator.state === ConnState.CONNECTED
        ? `已切换${label}` : `已切换${label}，下次连接生效`
    });
  }

  /** Nexus §9 导出：快照 → filesDir JSON → Toast (+复制到剪贴板兜底) */
  private async exportBackup(): Promise<void> {
    try {
      const ctx = getContext(this) as Context;
      const json = BackupRestoreService.exportJsonWithSettings(this.settings);
      const fileName = BackupRestoreService.defaultFileName();
      const path = `${ctx.filesDir}/${fileName}`;
      const f = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, json);
      } finally {
        fs.closeSync(f);
      }
      try {
        const data = pasteboard.getSystemPasteboard();
        data.setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, json));
      } catch (e) {
        AppLogger.warn(TAG, `backup clipboard fallback failed: ${AppLogger.errText(e)}`);
      }
      this.backupToast = '✓ 备份文件已成功导出！';
      promptAction.showToast({ message: `备份已保存：${fileName}（JSON 已复制，可粘贴保存）` });
      AppLogger.info(TAG, `backup exported: ${path}`);
    } catch (e) {
      this.backupToast = '';
      promptAction.showToast({ message: '导出备份失败，请重试' });
      AppLogger.error(TAG, `backup export failed: ${AppLogger.errText(e)}`);
    }
  }

  /** Nexus §9 导入：系统文件选择器挑 .json → 校验恢复 */
  private async importBackup(): Promise<void> {
    try {
      const docPicker = new picker.DocumentViewPicker(getContext(this) as Context);
      const opts = new picker.DocumentSelectOptions();
      opts.maxSelectNumber = 1;
      opts.fileSuffixFilters = ['.json'];
      const uris = await docPicker.select(opts);
      if (uris.length === 0) {
        return;
      }
      const uri = uris[0];
      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      let text = '';
      try {
        const stat = fs.statSync(file.fd);
        if (stat.size <= 0 || stat.size > 4 * 1024 * 1024) {
          promptAction.showToast({ message: '文件大小需在 4MB 以内' });
          return;
        }
        const buf = new ArrayBuffer(Number(stat.size));
        let readLen = 0;
        while (readLen < Number(stat.size)) {
          const chunk = fs.readSync(file.fd, buf, { offset: readLen, length: Number(stat.size) - readLen });
          if (chunk <= 0) {
            break;
          }
          readLen += chunk;
        }
        text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf, 0, readLen));
      } finally {
        fs.closeSync(file);
      }
      const outcome = await BackupRestoreService.importJsonText(text);
      if (outcome.ok) {
        this.settings = await SettingsService.load();
        this.proxyMode = this.settings.proxyMode === 'global' ? 'global' : 'rule';
        this.refreshDisplayNode();
        this.backupToast = `✓ 恢复成功！已导入 ${outcome.subCount} 个订阅及自定义规则`;
        promptAction.showToast({ message: this.backupToast });
      } else {
        promptAction.showToast({ message: outcome.message });
      }
    } catch (e) {
      AppLogger.warn(TAG, `backup import failed: ${AppLogger.errText(e)}`);
      promptAction.showToast({ message: '导入失败，请重试' });
    }
  }

  private formatSpeedValue(bytesPerSecond: number): string {
    if (bytesPerSecond < 1024) {
      return `${Math.round(bytesPerSecond)} B/s`;
    }
    const kb = bytesPerSecond / 1024;
    if (kb < 1024) {
      return `${kb.toFixed(1)} KB/s`;
    }
    return `${(kb / 1024).toFixed(1)} MB/s`;
  }

  private formatRealtimeRate(): string {
    return this.formatSpeedValue(this.upSpeed + this.downSpeed);
  }

  private formatTotalMB(): string {
    const total = this.upTotal + this.downTotal;
    if (total < 1024) {
      return `${Math.round(total)} B`;
    }
    const kb = total / 1024;
    if (kb < 1024) {
      return `${kb.toFixed(1)} KB`;
    }
    const mb = kb / 1024;
    if (mb < 1024) {
      return `${mb.toFixed(1)} MB`;
    }
    return `${(mb / 1024).toFixed(2)} GB`;
  }

  private formatDuration(): string {
    const s = Math.max(0, Math.floor(this.connectionDuration));
    const hh = `0${Math.floor(s / 3600)}`.slice(-2);
    const mm = `0${Math.floor((s % 3600) / 60)}`.slice(-2);
    const ss = `0${s % 60}`.slice(-2);
    return this.connectionDuration > 0 ? `${hh}:${mm}:${ss}` : '--:--:--';
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // Nexus phone 底 #f8fafc（浅色规范；深色跟随系统由 ThemeService 接管，此处保持浅底以 1:1 还原设计稿）
      Column().width('100%').height('100%')
        .backgroundColor(Nx.bg())
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column() {
        Scroll() {
          Column({ space: 0 }) {
            // ── 顶部操作行：左备份 / 右深浅主题切换 ──
            Row() {
              Row() {
                Text('备份').fontSize(12).fontWeight(FontWeight.Bold).fontColor(Nx.fg())
              }
              .padding({ left: 11, right: 11, top: 5, bottom: 5 })
              .borderRadius(9999)
              .backgroundColor(Nx.surface())
              .borderWidth(1).borderColor(Nx.border())
              .shadow({ radius: 3, color: 'rgba(15, 23, 42, 0.05)', offsetY: 1 })
              .onClick(() => {
                this.backupToast = '';
                this.backupDialog.open();
              })
              Blank()
              Button() {
                SymbolGlyph($r('sys.symbol.sun_max'))
                  .fontSize(20)
                  .fontColor([Nx.muted()])
              }
              .width(40)
              .height(40)
              .borderRadius(20)
              .backgroundColor(Color.Transparent)
              .accessibilityText('切换浅色或深色主题')
              .onClick(() => this.toggleTheme())
            }.width('100%').margin({ bottom: 4 })

            // ── 品牌（启动按钮正上方，间隔 16） ──
            Row({ space: 8 }) {
              Text('Nexus')
                .fontSize(13).fontWeight(FontWeight.Bold)
                .fontColor(Nx.accent())
                .padding({ left: 12, right: 12, top: 4, bottom: 4 })
                .borderRadius(9999)
                .backgroundColor(Nx.accentSoft())
                .borderWidth(1).borderColor(Nx.accentEdge())
            }.width('100%').justifyContent(FlexAlign.Center).margin({ top: 8, bottom: 16 })

            // ── 状态环 ──
            Row() {
              Blank()
              StatusRing({
                isConnected: this.isConnected,
                isConnecting: this.isConnecting,
                statusText: this.statusText(),
                nodeName: this.currentNodeName,
                onToggle: () => {
                  this.toggleConnection();
                }
              })
              Blank()
            }.width('100%').padding({ top: 8, bottom: 12 })

            // ── 公网 IP 胶囊：状态环（电源按钮）正下方，水平居中（对齐 SSRVPN 上游最终布局）──
            // 仅连接后显示：此时查询到的是所选节点的出口公网 IP；未连接时隐藏，避免误导为本机宽带 IP。
            // 数据链路复用既有 PublicIpService（连接成功/断开/节点页重连 revision 均已触发刷新），此处只补展示。
            if (this.isConnected) {
              Row() {
                Row({ space: 6 }) {
                  if (this.publicIpRefreshing) {
                    LoadingProgress().width(15).height(15).color(Nx.accent())
                  } else {
                    Text('🌐').fontSize(14)
                  }
                  Text(this.publicIpRefreshing ? '正在获取公网 IP…'
                    : (this.publicIp.length > 0 ? this.publicIp : this.publicIpError))
                    .fontSize(12.5).fontWeight(FontWeight.Medium)
                    .fontColor(this.publicIpRefreshing ? Nx.muted()
                      : (this.publicIp.length > 0 ? Nx.darkText() : Nx.danger()))
                    .fontFamily('monospace')
                    .wordBreak(WordBreak.BREAK_ALL)
                    .textAlign(TextAlign.Center)
                    .constraintSize({ maxWidth: 300 })
                }
                .alignItems(VerticalAlign.Center)
                .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                .borderRadius(9999)
                .backgroundColor(Nx.surface())
                .borderWidth(1).borderColor(Nx.border())
                .shadow({ radius: 6, color: 'rgba(15, 23, 42, 0.04)', offsetY: 2 })
                .onClick(() => {
                  if (!this.publicIpRefreshing) {
                    this.refreshPublicIp();
                  }
                })
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .alignItems(VerticalAlign.Center)
              .margin({ bottom: 12 })
            }

            // ── 实时速率卡 ──
            Column({ space: 6 }) {
              Row() {
                Column({ space: 2 }) {
                  Text('实时速率')
                    .fontSize(11).fontWeight(FontWeight.Bold).fontColor(Nx.accent())
                    .width('100%')
                  Text(this.isConnected ? this.formatRealtimeRate() : '0.0 KB/s')
                    .fontSize(16).fontWeight(FontWeight.Bold).fontColor(Nx.fg())
                    .fontFamily('monospace')
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                Row({ space: 10 }) {
                  Row({ space: 3 }) {
                    Text('流量').fontSize(10).fontColor(Nx.faint())
                    Text(this.formatTotalMB()).fontSize(10.5).fontWeight(FontWeight.Medium)
                      .fontColor(Nx.darkText()).fontFamily('monospace')
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  }.alignItems(VerticalAlign.Center)
                  Row({ space: 3 }) {
                    Text('时长').fontSize(10).fontColor(Nx.faint())
                    Text(this.formatDuration()).fontSize(10.5).fontWeight(FontWeight.Medium)
                      .fontColor(Nx.darkText()).fontFamily('monospace')
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  }.alignItems(VerticalAlign.Center)
                  // 活跃连接入口：对齐主流客户端的连接查看器（Clash Verge / NekoBox）
                  Text('连接 ›')
                    .fontSize(10.5).fontWeight(FontWeight.Bold).fontColor(Nx.accent())
                    .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                    .borderRadius(9999)
                    .backgroundColor(Nx.accentSoft())
                    .borderWidth(1).borderColor(Nx.accentEdge())
                    .onClick(() => router.pushUrl({ url: 'pages/ConnectionsPage' }))
                }.alignItems(VerticalAlign.Center).flexShrink(0)
              }.width('100%')
              RateChart({ points: this.ratePoints, isConnected: this.isConnected })
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 12, bottom: 12 })
            .borderRadius(NexusSizes.cardRadius)
            .backgroundColor(Nx.surface())
            .borderWidth(1).borderColor(Nx.border())
            .shadow({ radius: 6, color: 'rgba(15, 23, 42, 0.04)', offsetY: 2 })
            .margin({ bottom: 12 })

            // ── 错误条 ──
            if (this.errorMessage.length > 0) {
              Row({ space: 6 }) {
                Text('⚠').fontSize(14).fontColor(Nx.danger())
                Text(this.errorMessage).fontSize(12).fontColor(Nx.danger())
                  .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
              }
              .width('100%').padding(12).borderRadius(NexusSizes.cardRadius)
              .backgroundColor(Nx.surface())
              .borderWidth(1).borderColor(Nx.border())
              .margin({ bottom: 12 })
              .onClick(() => {
                this.showDiagnostics = true;
                this.refreshDiagnostics();
              })
            }

            // ── 严格双卡片：分流模式 + 规则管理 ──
            Row({ space: 12 }) {
              // 卡片1：代理模式
              Column({ space: 5 }) {
                Row() {
                  Text('分流模式').fontSize(11).fontWeight(FontWeight.Bold).fontColor(Nx.accent())
                }.width('100%')
                Text('代理模式').fontSize(13.5).fontWeight(FontWeight.Bold).fontColor(Nx.fg()).width('100%')
                Text('智能分流大陆与境外').fontSize(11).fontColor(Nx.muted()).width('100%')
                Row({ space: 2 }) {
                  Text('智能')
                    .fontSize(11.5)
                    .fontWeight(this.proxyMode !== 'global' ? FontWeight.Bold : FontWeight.Medium)
                    .fontColor(this.proxyMode !== 'global' ? Nx.fg() : Nx.muted())
                    .layoutWeight(1).textAlign(TextAlign.Center)
                    .padding(4).borderRadius(9999)
                    .backgroundColor(this.proxyMode !== 'global' ? Nx.surface() : Color.Transparent)
                    .shadow(this.proxyMode !== 'global' ?
                      { radius: 4, color: 'rgba(15, 23, 42, 0.08)', offsetY: 1 } :
                      { radius: 0, color: Color.Transparent, offsetY: 0 })
                    .onClick(() => this.applyProxyMode('rule'))
                  Text('全局')
                    .fontSize(11.5)
                    .fontWeight(this.proxyMode === 'global' ? FontWeight.Bold : FontWeight.Medium)
                    .fontColor(this.proxyMode === 'global' ? Nx.fg() : Nx.muted())
                    .layoutWeight(1).textAlign(TextAlign.Center)
                    .padding(4).borderRadius(9999)
                    .backgroundColor(this.proxyMode === 'global' ? Nx.surface() : Color.Transparent)
                    .shadow(this.proxyMode === 'global' ?
                      { radius: 4, color: 'rgba(15, 23, 42, 0.08)', offsetY: 1 } :
                      { radius: 0, color: Color.Transparent, offsetY: 0 })
                    .onClick(() => this.applyProxyMode('global'))
                }
                .width('100%')
                .padding(2.5).borderRadius(9999)
                .backgroundColor(Nx.fgSoft())
              }
              .layoutWeight(1)
              .constraintSize({ minHeight: 100 })
              .alignItems(HorizontalAlign.Start)
              .padding(13).borderRadius(NexusSizes.cardRadius)
              .backgroundColor(Nx.surface())
              .borderWidth(1).borderColor(Nx.border())
              .shadow({ radius: 6, color: 'rgba(15, 23, 42, 0.04)', offsetY: 2 })

              // 卡片2：规则管理
              Column({ space: 5 }) {
                Row() {
                  Text('规则管理').fontSize(11).fontWeight(FontWeight.Bold).fontColor(Nx.accent())
                }.width('100%')
                Text('规则模式').fontSize(13.5).fontWeight(FontWeight.Bold).fontColor(Nx.fg()).width('100%')
                Text('广告拦截与直连规则').fontSize(11).fontColor(Nx.muted()).width('100%')
                Blank()
                Row() {
                  Text('点击配置').fontSize(11).fontWeight(FontWeight.Bold).fontColor(Nx.accent())
                  Blank()
                  Text('→').fontSize(11).fontWeight(FontWeight.Bold).fontColor(Nx.accent())
                }.width('100%')
              }
              .layoutWeight(1)
              .constraintSize({ minHeight: 100 })
              .alignItems(HorizontalAlign.Start)
              .justifyContent(FlexAlign.Start)
              .padding(13).borderRadius(NexusSizes.cardRadius)
              .backgroundColor(Nx.surface())
              .borderWidth(1).borderColor(Nx.border())
              .shadow({ radius: 6, color: 'rgba(15, 23, 42, 0.04)', offsetY: 2 })
              .onClick(() => this.networkRulesDialog.open())
            }.width('100%')
          }
          .width('100%')
          .padding({ left: 18, right: 18, top: 10, bottom: 110 })
        }
        .width('100%').height('100%')
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      .width('100%').height('100%')

      // ── 底部液态玻璃 Dock ──
      Column() {
        LiquidGlassDock({ currentTab: 'home' })
      }
      .width('100%')
      .padding({ left: 18, right: 18, bottom: 18 })

      if (this.showDiagnostics) {
        Column() {
          Blank()
          DiagnosticsSheet({
            diag: this.diagData,
            onRefresh: () => {
              this.refreshDiagnostics();
            },
            onClose: () => { this.showDiagnostics = false; }
          })
            .height('78%')
        }
        .width('100%').height('100%')
        .backgroundColor('rgba(15, 23, 42, 0.55)')
        .onClick(() => { this.showDiagnostics = false; })
      }
    }
    .width('100%').height('100%')
  }
}
