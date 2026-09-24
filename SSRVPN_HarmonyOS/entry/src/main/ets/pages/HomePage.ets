/**
 * HomePage - 1:1 aligned with upstream SsrvpnHomeOverview
 */
import { router, promptAction } from '@kit.ArkUI';
import { Ui, LatencyStyle, NodeDisplay } from '../theme/UiTokens';
import { ConnectionOrchestrator, ConnState } from '../commons/services/ConnectionOrchestrator';
import { SubscriptionService } from '../commons/services/SubscriptionService';
import { SettingsService } from '../commons/services/SettingsService';
import { PublicIpService } from '../commons/services/PublicIpService';
import { PublicIpInfo, AppDiagnostics } from '../commons/models/PublicIpInfo';
import { AppSettings, AutoSelectModes } from '../commons/models/AppSettings';
import { ClashConfigGenerator } from '../commons/services/ClashConfigGenerator';
import { LatencyController } from '../commons/services/LatencyController';
import { BackgroundLatencyService } from '../commons/services/BackgroundLatencyService';
import { FormStateSync } from '../commons/services/FormStateSync';
import { ConnectionSnapshot } from '../commons/services/SettingsService';
import { NodeCountryPolicy } from '../commons/services/PublicIpService';
import { CountryFlagIcon } from '../widgets/CountryFlagIcon';
import { DiagnosticsSheet } from '../widgets/DiagnosticsSheet';
import { PowerButton } from '../components/PowerButton';
import { AppLogger } from '../commons/utils/AppLogger';
import { AppInfo } from '../commons/utils/AppInfo';
import { display } from '@kit.ArkUI';
import { window } from '@kit.ArkUI';
import { ThemeService } from '../theme/ThemeService';
import { ProxyNode } from '../commons/models/ProxyNode';
import { NodeSortSnapshot } from '../commons/services/NodeSortPersistence';

const TAG = 'HomePage';

@CustomDialog
struct TutorialDialog {
  controller?: CustomDialogController;
  onClose: () => void = () => {};

  private steps: string[] = [
    '点击底部「订阅」，再点击右下角「+」；可通过 URL、二维码或本地文件添加订阅',
    '添加后点击订阅卡片上的刷新按钮，等待节点加载完成',
    '返回主页，点击「当前节点」卡片进入节点列表并选择节点',
    '回到主页点击连接按钮；首次连接时按系统提示允许 VPN 权限',
    '主页「网络规则」可配置规则/去广告、强制代理/直连网站或应用分流，修改后保存并按提示应用'
  ];

  build() {
    Column({ space: 12 }) {
      Text('教程').fontSize(20).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
      ForEach(this.steps, (step: string, idx: number) => {
        Row({ space: 10 }) {
          Text(`${idx + 1}`)
            .fontSize(13).fontWeight(FontWeight.Bold)
            .fontColor(Ui.textBlue)
            .width(22).height(22)
            .borderRadius(11)
            .backgroundColor(Ui.statusTint)
            .textAlign(TextAlign.Center)
          Text(step).fontSize(14).fontColor(Ui.textSecondary).layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }, (step: string) => step)
      Button('知道了')
        .width('100%')
        .backgroundColor(Ui.primaryBlueFill)
        .fontColor(Color.White)
        .onClick(() => {
          if (this.controller !== undefined) {
            this.controller.close();
          }
        })
    }
    .padding(26)
    .borderRadius(Ui.dialogRadius)
    .backgroundColor(Ui.surfaceTranslucent)
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
      colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
    })
    .backgroundEffect({ radius: Ui.glassBlurRadius, saturation: Ui.glassSaturation, brightness: Ui.glassBrightness })
    .borderWidth(1)
    .borderColor(Ui.glassEdge)
    .shadow({ radius: 32, color: Ui.shadow, offsetY: 16 })
  }
}

/** 网络规则 4 选项弹窗：主页「网络规则」卡片直接弹出；选中某项再进入对应配置页面。 */
@CustomDialog
struct NetworkRulesDialog {
  controller?: CustomDialogController;
  /** 打开时刻从父页面读取最新摘要，避免构造期快照导致计数过期。 */
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
      Text(icon).fontSize(20).fontColor(Ui.textBlue)
        .width(40).height(40).textAlign(TextAlign.Center)
        .borderRadius(12).backgroundColor(Ui.selectedBackground)
      Column({ space: 3 }) {
        Text(title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(Ui.textPrimary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(detail).fontSize(11).fontColor(Ui.textSecondary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Text('›').fontSize(20).fontColor(Ui.textTertiary)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .borderRadius(15)
    .backgroundColor(Ui.surfaceTranslucent)
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
      colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
    })
    .backgroundEffect({ radius: Ui.glassControlBlurRadius, saturation: Ui.glassControlSaturation, brightness: Ui.glassControlBrightness })
    .borderWidth(1)
    .borderColor(Ui.glassEdge)
    .onClick(() => this.onPick(kind))
  }

  build() {
    Column({ space: 10 }) {
      Text('网络规则').fontSize(18).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
      Text('选择一项进入配置页面')
        .fontSize(12).fontColor(Ui.textTertiary).width('100%').textAlign(TextAlign.Center)
      this.OptionRow('☷', '规则', this.rulesSummary, 'rules')
      this.OptionRow('↗', '强制代理网站', `代理 ${this.proxyCount} 个域名`, 'proxy')
      this.OptionRow('↘', '强制直连网站', `直连 ${this.directCount} 个域名`, 'direct')
      this.OptionRow('▦', '应用分流', this.appSummary, 'app')
      Text('绕过 VPN 的应用不受网站规则影响。')
        .fontSize(10).fontColor(Ui.textTertiary).width('100%').textAlign(TextAlign.Center)
      Button('关闭')
        .width('100%')
        .backgroundColor(Ui.surfaceTranslucent)
        .fontColor(Ui.textSecondary)
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
          colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
        })
        .backgroundEffect({ radius: Ui.glassControlBlurRadius, saturation: Ui.glassControlSaturation, brightness: Ui.glassControlBrightness })
        .borderWidth(1)
        .borderColor(Ui.glassEdge)
        .margin({ top: 2 })
        .onClick(() => {
          if (this.controller !== undefined) {
            this.controller.close();
          }
        })
    }
    .padding(22)
    .borderRadius(20)
    .backgroundColor(Ui.surfaceTranslucent)
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
      colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
    })
    .backgroundEffect({ radius: Ui.glassBlurRadius, saturation: Ui.glassSaturationSoft, brightness: Ui.glassBrightnessSoft })
    .borderWidth(1)
    .borderColor(Ui.glassEdge)
    .shadow({ radius: 28, color: Ui.shadow, offsetY: 12 })
  }
}

/** 代理模式选择弹窗：与教程弹窗同一套主题化毛玻璃底，深色模式不再是系统默认黑底。 */
@CustomDialog
struct ProxyModeDialog {
  controller?: CustomDialogController;
  currentMode: string = 'rule';
  onPick: (mode: string) => void = () => {};

  @Builder
  ModeRow(label: string, detail: string, mode: string) {
    Row({ space: 12 }) {
      Text(this.currentMode === mode ? '●' : '○').fontSize(16).fontColor(Ui.textBlue)
      Column({ space: 2 }) {
        Text(label).fontSize(15).fontWeight(FontWeight.Medium).fontColor(Ui.textPrimary)
        Text(detail).fontSize(11).fontColor(Ui.textSecondary)
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .borderRadius(15)
    .backgroundColor(Ui.surfaceTranslucent)
    .borderWidth(1)
    .borderColor(this.currentMode === mode ? Ui.primary : Ui.glassEdge)
    .onClick(() => this.onPick(mode))
  }

  build() {
    Column({ space: 12 }) {
      Text('选择代理模式').fontSize(18).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
      this.ModeRow('智能', '按规则分流：国内直连，其余按规则', 'rule')
      this.ModeRow('全局', '所有流量走代理', 'global')
      Text('已连接时优先热更新，失败才回退重连。')
        .fontSize(11).fontColor(Ui.textTertiary).width('100%').textAlign(TextAlign.Center)
      Button('取消')
        .width('100%')
        .backgroundColor(Ui.surfaceTranslucent)
        .fontColor(Ui.textSecondary)
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
          colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
        })
        .borderWidth(1)
        .borderColor(Ui.glassEdge)
        .onClick(() => {
          if (this.controller !== undefined) {
            this.controller.close();
          }
        })
    }
    .padding(24)
    .borderRadius(Ui.dialogRadius)
    .backgroundColor(Ui.surfaceTranslucent)
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
      colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
    })
    .backgroundEffect({ radius: Ui.glassBlurRadius, saturation: Ui.glassSaturation, brightness: Ui.glassBrightness })
    .borderWidth(1)
    .borderColor(Ui.glassEdge)
    .shadow({ radius: 32, color: Ui.shadow, offsetY: 16 })
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
  @State currentLatencyTick: number = 0; // 延迟缓存变化时触发重渲染
  @State showDiagnostics: boolean = false;
  @State diagTick: number = 0;
  @State diagData: AppDiagnostics | null = null;
  @State upSpeed: number = 0;
  @State downSpeed: number = 0;
  @State upTotal: number = 0;
  @State downTotal: number = 0;
  @State connectionDuration: number = 0;
  @State buttonPressed: boolean = false;
  /** 当前代理模式（'rule' 智能(规则) / 'global' 全局），随设置落盘并驱动隧道重建 */
  @State proxyMode: string = 'rule';
  /** 卡片只展示已保存设置；每次 onPageShow 的 bootstrap 重新加载。 */
  @State rulesSummary: string = '加载中…';
  @State networkRulesSummary: string = '加载中…';
  /** 电源按钮直径: 按屏宽自适应(手机≈40% 宽, 平板封顶 210), 修复手机上比例失衡 */
  @State powerSize: number = 240;
  @StorageLink('theme_revision') themeRevision: number = 0;
  /** 节点页完成隧道重连后递增，通知仍驻留在导航栈中的主页刷新出口公网 IP。 */
  @StorageLink('public_ip_revision') @Watch('onPublicIpRevision') publicIpRevision: number = 0;
  /** 桌面长按快捷方式/服务卡片启动请求: EntryAbility 递增 seq + 写 mode, 这里消费 */
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
  private tutorialDialog: CustomDialogController = new CustomDialogController({
    builder: TutorialDialog({})
  });
  /** 代理模式选择弹窗（主题化 CustomDialog，替代系统 showActionMenu 黑底问题） */
  private proxyModeDialog: CustomDialogController = new CustomDialogController({
    builder: ProxyModeDialog({
      currentMode: this.proxyMode,
      onPick: (mode: string): void => {
        this.proxyModeDialog.close();
        this.applyProxyMode(mode);
      }
    }),
    autoCancel: true
  });
  /** 网络规则 4 选项弹窗：规则 / 强制代理网站 / 强制直连网站 / 应用分流 */
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

  private async toggleTheme(): Promise<void> {
    await ThemeService.toggle();
    const mainWindow = AppStorage.get<window.Window>('main_window');
    if (mainWindow !== undefined) {
      await ThemeService.syncSystemBars(mainWindow);
    }
  }

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
    this.isConnecting = this.orchestrator.state === ConnState.CONNECTING
      || this.orchestrator.state === ConnState.DISCONNECTING
      || this.orchestrator.state === ConnState.RECOVERING;
    this.errorMessage = this.orchestrator.lastError;
    this.upSpeed = this.orchestrator.traffic.uploadSpeed;
    this.downSpeed = this.orchestrator.traffic.downloadSpeed;
    this.upTotal = this.orchestrator.traffic.uploadBytes;
    this.downTotal = this.orchestrator.traffic.downloadBytes;
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
    }, 1000);
  }

  private stopConnectionTimer(): void {
    if (this.connectionTimer >= 0) {
      clearInterval(this.connectionTimer);
      this.connectionTimer = -1;
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
    // 主页也必须从持久化测速快照恢复 LatencyController。此前只有节点页执行回填，
    // 所以后台测速完成后节点页能显示延迟，而主页当前节点卡片仍显示“未测试”，
    // 直到用户在节点页手动批量测速。现在主页初始化时直接恢复全部有效结果。
    const latencySnapshot = NodeSortSnapshot.fromJsonText(this.settings.nodeSortSnapshot);
    if (latencySnapshot !== null) {
      for (const rec of latencySnapshot.records) {
        if (rec.latency !== -2) {
          LatencyController.set(rec.name, rec.latency);
        }
      }
      LatencyController.flushNow();
    }
    // 冷启动后台静默测速已取消（用户要求）：只保留用户手动测试。
    // BackgroundLatencyService.scheduleStartup(ctx);
    this.proxyMode = this.settings.proxyMode === 'global' ? 'global' : 'rule';
    const authority = await this.orchestrator.authorityState();
    const snapshot = await SettingsService.loadSnapshot();
    if (authority.connected) {
      this.orchestrator.state = ConnState.CONNECTED;
      if (this.orchestrator.startedAt <= 0 && snapshot.startedAt > 0) {
        this.orchestrator.startedAt = snapshot.startedAt;
      }
    }
    // 电源按钮随屏宽自适应: 手机(≈433vp)取 44% 宽 ≈ 190, 平板封顶 260
    try {
      const disp = display.getDefaultDisplaySync();
      const widthVp = disp.width / disp.densityPixels;
      this.powerSize = Math.round(Math.min(260, Math.max(170, widthVp * 0.44)));
    } catch (e) {
      this.powerSize = 200;
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
    // 单例 orchestrator: 回到主页时立即同步真实状态(不依赖下一次 notify),
    // 已连接则 UI 直接显示"已连接", 也不会触发误重连。
    this.applyOrchestratorState();
    this.pageReady = true;
    this.syncConnectionTimer();
    // 不再自动恢复连接: 打开应用保持断开状态, 由用户手动点击启动。
    // 冷启动时快捷方式/卡片请求可能先于页面就绪写入, 这里兜底消费一次。
    this.consumeVpnRequest();
  }

  /** 节点页完成自动重连后，立即丢弃主页旧值并重新查询实际出口公网 IP。 */
  onPublicIpRevision(): void {
    if (!this.pageReady || this.publicIpRefreshing) {
      return;
    }
    this.publicIp = '';
    this.refreshPublicIp().catch((): void => {});
  }

  /** @Watch: 页面存活期间(前台/后台)收到新请求即时响应 */
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

  /** 快捷方式「启动代理」: 未连接才发起, 已连接/连接中保持现状 */
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

  /** 对齐 HomeNodeController.resolveDefaultNode / resolveRuntimeSelectedNode 的简化实现 */
  private selectedNode(): ProxyNode | null {
    // 注意：这里**必须**返回真实节点，不能因为自动模式就返回 null。
    // connect() 开头就无条件读 node.name 并把它当兜底 target（无效时才回退到
    // 首个有效节点），传 null 会直接抛。自动模式下「PROXY 指向 smart 组」是由
    // orchestrator 内部 pinSmartGroup 完成的，不靠这里传空。
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
    // 自动模式下 PROXY 指向的是内核 smart 组，「当前节点」应显示自动选择，
    // 否则会把 preferredNodeId 指的那个**备选**节点当成实际出口（用户看到的
    // "选完自动选择回主页还是别的节点"就是这个）。
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

  private statusColor(): ResourceColor {
    if (this.isConnecting) {
      return Ui.warning;
    }
    if (this.errorMessage.length > 0) {
      return Ui.error;
    }
    if (this.isConnected) {
      return Ui.success;
    }
    return Ui.textSecondary;
  }

  private powerColor(): ResourceColor {
    if (this.errorMessage.length > 0) {
      return Ui.error;
    }
    return this.isConnected ? Ui.success : Ui.primary;
  }

  /** 打开/刷新诊断面板: 拉一次内核诊断并回填 @State (异步, 完成即重渲染) */
  private refreshDiagnostics(): void {
    this.diagTick = this.diagTick + 1;
    this.orchestrator.diagnostics().then((d: AppDiagnostics) => {
      this.diagData = d;
      this.diagTick = this.diagTick + 1;
    }).catch(() => {
      this.diagData = null;
    });
  }

  private async refreshPublicIp(): Promise<void> {    this.publicIpRefreshing = true;
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

  /**
   * 切换代理模式（原节点页 ModeChip 逻辑上移主页）。
   * 已连接时优先通过 Mihomo controller 热更新，保持 TUN、VPN 与 Core；失败才回退重连。
   */
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

  /** 主页与订阅/节点页之间的切换动画（与 SubscriptionPage 同款） */
  pageTransition() {
    PageTransitionEnter({ duration: 360, curve: Curve.EaseInOut }).opacity(0.68).scale({ x: 0.992, y: 0.992 })
    PageTransitionExit({ duration: 300, curve: Curve.EaseInOut }).opacity(0.72).scale({ x: 1.008, y: 1.008 })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // ── 背景（SsrvpnAppBackdrop：三段对角渐变） ──
      Column()
        .width('100%').height('100%')
        .linearGradient({
          angle: 135,
          colors: Ui.backdropColors
        })
        // 背景延伸到状态栏/底部导航条之下, 配合透明系统栏呈现主题色
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column() {
        Scroll() {
          Column({ space: 0 }) {
            // ── 头部：SSRVPN(绝对居中) | 使用教程 + 主题切换 ──
            // 标题放在 Stack 里由系统居中，两侧操作项作为同一行的叠加层，
            // 不再参与标题的水平定位（此前右侧按钮会把标题挤偏）。
            Stack() {
              Text('SSRVPN')
                .fontSize(26)
                .fontWeight(FontWeight.Normal)
                .fontColor(Ui.textPrimary)
                .letterSpacing(0.4)
              Row() {
                Blank()
                Row({ space: 4 }) {
                  Text('教程')
                    .fontSize(14).fontColor(Ui.textSecondary)
                    .padding({ left: 4, right: 4 })
                    .onClick(() => this.tutorialDialog.open())
                  Button() {
                    SymbolGlyph($r('sys.symbol.sun_max'))
                      .fontSize(20)
                      .fontColor([Ui.textSecondary])
                  }
                  .width(40)
                  .height(40)
                  .borderRadius(20)
                  .backgroundColor(Color.Transparent)
                  .accessibilityText('切换浅色或深色主题')
                  .onClick(() => this.toggleTheme())
                }
              }
              .width('100%')
            }
            .width('100%')
            .height(48)

            Blank().height(10)

            // ── 状态胶囊 ──
            Row({ space: 8 }) {
              Circle({ width: 8, height: 8 }).fill(this.statusColor())
              Text(this.statusText())
                .fontSize(13).fontWeight(FontWeight.Bold)
                .fontColor(this.statusColor())
            }
            .padding({ left: 14, right: 14, top: 7, bottom: 7 })
            .borderRadius(18)
            .backgroundColor(Ui.surfaceTranslucent)
            .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
              colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
            })
            .backgroundEffect({ radius: Ui.glassBlurRadius, saturation: Ui.glassSaturationSoft, brightness: Ui.glassBrightnessSoft })
            .borderWidth(1)
            .borderColor(Ui.glassEdge)

            Blank().height(28)

            // ── 电源按钮（PowerButton 组件: 外环描边+内圆+SVG 电源图标） ──
            PowerButton({
              isConnected: this.isConnected,
              isConnecting: this.isConnecting,
              hasError: this.errorMessage.length > 0,
              buttonSize: this.powerSize,
              onToggle: () => {
                this.toggleConnection();
              }
            })

            Blank().height(34)

            // ── 公网 IP 胶囊：电源按钮正下方，内容自适应宽度（IPv6 也能完整展示），水平居中 ──
            if (this.isConnected || this.errorMessage.length > 0) {
              if (this.errorMessage.length > 0) {
                Row({ space: 6 }) {
                  Text('⚠').fontSize(16).fontColor(Ui.textError)
                  Text(this.errorMessage).fontSize(13).fontColor(Ui.textError).maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                .borderRadius(18)
                .backgroundColor(Ui.surfaceTranslucent)
                .borderWidth(1)
                .borderColor(Ui.glassEdge)
                .constraintSize({ maxWidth: Ui.pageMaxWidth })
                .onClick(() => {
                  this.showDiagnostics = true;
                  this.refreshDiagnostics();
                })
              } else {
                Row({ space: 6 }) {
                  if (this.publicIpRefreshing) {
                    LoadingProgress().width(15).height(15).color(Ui.textSecondary)
                  } else {
                    Text('🌐').fontSize(15)
                  }
                  Text(this.publicIpRefreshing ? '正在获取公网 IP…'
                    : (this.publicIp.length > 0 ? this.publicIp : this.publicIpError))
                    .fontSize(13).fontColor(Ui.textSecondary)
                    .wordBreak(WordBreak.BREAK_ALL)
                    .constraintSize({ maxWidth: Ui.pageMaxWidth - 60 })
                }
                .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                .borderRadius(18)
                .backgroundColor(Ui.surfaceTranslucent)
                .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
                  colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
                })
                .borderWidth(1)
                .borderColor(Ui.glassEdge)
                .constraintSize({ maxWidth: Ui.pageMaxWidth })
                .onClick(() => {
                  if (!this.publicIpRefreshing) {
                    this.refreshPublicIp();
                  }
                })
              }
            }

            Blank().height(16)

            // ── 2×2 功能卡片：节点 / 数据 / 代理模式 / 网络规则，尺寸一致 ──
            Row({ space: 10 }) {
              this.CurrentNodeCard()
              this.StatsTile()
            }
            .width('100%')
            .constraintSize({ maxWidth: 408 })
            .alignItems(VerticalAlign.Top)

            Row({ space: 10 }) {
              this.ProxyModeCard()
              this.NetworkRulesCard()
            }
            .width('100%')
            .constraintSize({ maxWidth: 408 })
            .margin({ top: 10, bottom: 8 })
          }
          .constraintSize({ maxWidth: Ui.pageMaxWidth })
          .padding({ left: 18, right: 18, top: 14, bottom: 104 })
        }
        .width('100%').height('100%')
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      .width('100%').height('100%')

      // ── 浮动底部导航（对齐 SsrvpnBottomNavigation） ──
      this.BottomNav()

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
        .backgroundColor(Ui.overlay)
        .onClick(() => { this.showDiagnostics = false; })
      }
    }
    .width('100%').height('100%')
  }

  /** 2×2 功能卡片（左上）：选择节点卡，尺寸与数据/代理/网络规则卡一致 */
  @Builder
  CurrentNodeCard() {
    Column() {
      Row() {
        Column() {
          Text('🌐').fontSize(14)
        }
        .width(28).height(28)
        .borderRadius(10)
        .linearGradient({ angle: 135, colors: [[Ui.statusTint, 0.0], [Ui.surfaceMuted, 1.0]] })
        .justifyContent(FlexAlign.Center)

        Blank()

        Text('›').fontSize(16).fontColor(Ui.textSecondary)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text('选择节点').fontSize(10).fontColor(Ui.textSecondary).width('100%').margin({ top: 8 })

      Row({ space: 4 }) {
        CountryFlagIcon({
          nodeName: this.currentNodeName.length > 0 ? this.currentNodeName : 'UN',
          iconSize: 14
        })
        Text(this.currentNodeName.length > 0
          ? NodeDisplay.compact(NodeDisplay.withoutLeadingFlag(this.currentNodeName))
          : '暂无可用节点')
          .fontSize(12).fontWeight(FontWeight.Bold)
          .fontColor(Ui.textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 3 })

      Text(LatencyStyle.text(LatencyController.latencyFor(this.currentNodeName)))
        .fontSize(10)
        .fontColor(LatencyStyle.color(LatencyController.latencyFor(this.currentNodeName)))
        .width('100%')
        .margin({ top: 2 })
    }
    .layoutWeight(1)
    .constraintSize({ minHeight: 100 })
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Start)
    .padding(12)
    .borderRadius(22)
    .backgroundColor(Ui.tileFill)
    .linearGradient({ angle: 160, colors: [[Ui.tileGloss, 0.0], [Ui.tileDeep, 1.0]] })
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
      colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
    })
    .backgroundEffect({ radius: Ui.glassBlurRadius, saturation: Ui.glassSaturationSoft, brightness: Ui.glassBrightnessSoft })
    .borderWidth(1)
    .borderColor(Ui.glassEdge)
    .shadow({ radius: 32, color: Ui.shadow, offsetY: 16 })
    .onClick(() => {
      router.pushUrl({ url: 'pages/NodeSelectionPage' });
    })
  }

  @Builder
  NetworkRulesCard() {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Text('⇄').fontSize(17).fontColor(Ui.textBlue)
        Text('网络规则').fontSize(14).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
        Blank()
        Text('›').fontSize(18).fontColor(Ui.textSecondary)
      }.width('100%')
      Text(this.networkRulesSummary)
        .fontSize(11).fontColor(Ui.textSecondary)
        .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1)
    .constraintSize({ minHeight: 100 })
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .borderRadius(22)
    .backgroundColor(Ui.tileFill)
    .linearGradient({ angle: 160, colors: [[Ui.tileGloss, 0.0], [Ui.tileDeep, 1.0]] })
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
      colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
    })
    .backgroundEffect({ radius: Ui.glassBlurRadius, saturation: Ui.glassSaturationSoft, brightness: Ui.glassBrightnessSoft })
    .borderWidth(1).borderColor(Ui.glassEdge)
    .shadow({ radius: 20, color: Ui.shadow, offsetY: 8 })
    .accessibilityText('网络规则，规则、网站规则与应用分流')
    .onClick(() => this.networkRulesDialog.open())
  }

  /** 2×2 功能卡片（下半区）：代理模式卡；点击弹主题化菜单切换 智能/全局 */
  @Builder
  ProxyModeCard() {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Text('🔀').fontSize(17).fontColor(Ui.textBlue)
        Text('代理模式').fontSize(14).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
        Blank()
        Text('›').fontSize(18).fontColor(Ui.textSecondary)
      }.width('100%')
      Text(this.proxyMode === 'global' ? '当前全局：所有流量走代理' : '当前智能：按规则分流')
        .fontSize(11).fontColor(Ui.textSecondary)
        .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1)
    .constraintSize({ minHeight: 100 })
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Start)
    .padding(14)
    .borderRadius(22)
    .backgroundColor(Ui.tileFill)
    .linearGradient({ angle: 160, colors: [[Ui.tileGloss, 0.0], [Ui.tileDeep, 1.0]] })
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
      colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
    })
    .backgroundEffect({
      radius: Ui.glassBlurRadius, saturation: Ui.glassSaturationSoft, brightness: Ui.glassBrightnessSoft
    })
    .borderWidth(1)
    .borderColor(Ui.glassEdge)
    .shadow({ radius: 20, color: Ui.shadow, offsetY: 8 })
    .onClick(() => {
      this.proxyModeDialog.open();
    })
  }

  /**
   * 数据总览卡（2×2 布局右上）：上传/下载/累计/时长四项，尺寸与其余三卡一致。
   * 注意：必须直接引用 this.xxx（不能值传参），否则 @State 变化不会刷新 builder 内的文本。
   */
  @Builder
  StatsTile() {
    Column({ space: 6 }) {
      Text('数据总览').fontSize(14).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary).width('100%')
      Row({ space: 6 }) {
        Row({ space: 3 }) {
          Text('↑').fontSize(10).fontColor(Ui.textBlue)
          Text(this.formatSpeedValue(this.upSpeed))
            .fontSize(10).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(VerticalAlign.Center)

        Row({ space: 3 }) {
          Text('↓').fontSize(10).fontColor(Ui.success)
          Text(this.formatSpeedValue(this.downSpeed))
            .fontSize(10).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')

      Row({ space: 6 }) {
        Row({ space: 3 }) {
          Text('Σ').fontSize(10).fontColor(Ui.accent)
          Text(this.formatBytesValue(this.upTotal + this.downTotal))
            .fontSize(10).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(VerticalAlign.Center)

        Row({ space: 3 }) {
          Text('🕒').fontSize(9).fontColor(Ui.textSecondary)
          Text(this.formatConnectionDuration(this.connectionDuration))
            .fontSize(10).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
    }
    .layoutWeight(1)
    .constraintSize({ minHeight: 100 })
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Center)
    .padding(14)
    .borderRadius(22)
    .backgroundColor(Ui.tileFill)
    .linearGradient({ angle: 160, colors: [[Ui.tileGloss, 0.0], [Ui.tileDeep, 1.0]] })
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
      colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
    })
    .backgroundEffect({ radius: Ui.glassBlurRadius, saturation: Ui.glassSaturationSoft, brightness: Ui.glassBrightnessSoft })
    .borderWidth(1)
    .borderColor(Ui.glassEdge)
    .shadow({ radius: 20, color: Ui.shadow, offsetY: 8 })
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

  private formatConnectionDuration(totalSeconds: number): string {
    const safeSeconds = Math.max(0, Math.floor(totalSeconds));
    const days = Math.floor(safeSeconds / 86400);
    const hours = Math.floor((safeSeconds % 86400) / 3600);
    const minutes = Math.floor((safeSeconds % 3600) / 60);
    const seconds = safeSeconds % 60;
    const time = `${hours.toString().padStart(2, '0')}:${minutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}`;
    return days > 0 ? `${days}d ${time}` : time;
  }

  private formatBytesValue(bytes: number): string {
    if (bytes < 1024) {
      return `${Math.round(bytes)} B`;
    }
    const kb = bytes / 1024;
    if (kb < 1024) {
      return `${kb.toFixed(1)} KB`;
    }
    const mb = kb / 1024;
    if (mb < 1024) {
      return `${mb.toFixed(1)} MB`;
    }
    return `${(mb / 1024).toFixed(2)} GB`;
  }

  /** 浮动底部导航（对齐 SsrvpnBottomNavigation） */
  @Builder
  BottomNav() {
    Column({ space: 6 }) {
      Row() {
        this.NavItem(true, '⌂', '主页', () => {})
        this.NavItem(false, '☰', '订阅', () => {
          // 底部导航栏在主页/订阅页都有, 用 replaceUrl 切换避免路由栈无限堆叠
          router.replaceUrl({ url: 'pages/SubscriptionPage' });
        })
      }
      .width('100%')
      .padding(5)
      .constraintSize({ minHeight: 56 })
      .borderRadius(24)
      .backgroundColor(Ui.navBackground)
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
        colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
      })
      .backgroundEffect({ radius: Ui.glassBlurRadius, saturation: Ui.glassSaturation, brightness: Ui.glassBrightness })
      .borderWidth(1)
      .borderColor(Ui.glassEdge)
      .shadow({ radius: 30, color: Ui.shadow, offsetY: 16 })

      Text(`SSRVPN for HarmonyOS v${AppInfo.version()}`)
        .fontSize(10).fontColor(Ui.textTertiary)
    }
    .width('92%')
    .constraintSize({ maxWidth: Ui.bottomNavMaxWidth })
    .margin({ bottom: 6 })
  }

  @Builder
  NavItem(selected: boolean, icon: string, label: string, onTap: () => void) {
    Column({ space: 2 }) {
      Text(icon).fontSize(17).fontColor(selected ? Ui.textPrimary : Ui.textSecondary)
      Text(label)
        .fontSize(11)
        .fontWeight(selected ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(selected ? Ui.textPrimary : Ui.textSecondary)
    }
    .layoutWeight(1)
    .constraintSize({ minWidth: 0 })
    .padding({ top: 6, bottom: 6 })
    .borderRadius(18)
    .backgroundColor(selected ? Ui.selectedBackground : Color.Transparent)
    .onClick(() => onTap())
  }

}
