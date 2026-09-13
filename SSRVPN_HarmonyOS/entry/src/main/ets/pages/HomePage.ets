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
import { AppSettings } from '../commons/models/AppSettings';
import { LatencyController } from '../commons/services/LatencyController';
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
import { ClashConfigGenerator } from '../commons/services/ClashConfigGenerator';
import { ProxyNode } from '../commons/models/ProxyNode';

const TAG = 'HomePage';

@CustomDialog
struct AboutDialog {
  controller?: CustomDialogController;
  onClose: () => void = () => {};

  build() {
    Column({ space: 14 }) {
      Text('SSRVPN').fontSize(30).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
      Text(`for HarmonyOS v${AppInfo.version()}`).fontSize(13).fontColor(Ui.textTertiary)
      Text('Mihomo (Clash Meta) 客户端 · MIT License')
        .fontSize(12).fontColor(Ui.textSecondary)
      // 检查更新暂不启用（后续需要时再接入自有更新源）
      Button('关闭')
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

@CustomDialog
struct TutorialDialog {
  controller?: CustomDialogController;
  onClose: () => void = () => {};

  private steps: string[] = [
    '点击底部「订阅」，再点击右下角「+」；可通过 URL、二维码或本地文件添加订阅',
    '添加后点击订阅卡片上的刷新按钮，等待节点加载完成',
    '返回主页，点击「当前节点」卡片进入节点列表并选择节点',
    '回到主页点击连接按钮；首次连接时按系统提示允许 VPN 权限',
    '需要分流时，在节点页右上角打开「网络规则」；不走代理和走代理的应用只能配置一种'
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

@CustomDialog
struct RulesDialog {
  controller?: CustomDialogController;
  @State rulesEnabled: boolean = true;
  @State hyperAdRulesEnabled: boolean = true;
  @State customRulesText: string = '';
  private settings: AppSettings = new AppSettings();
  private orchestrator: ConnectionOrchestrator = ConnectionOrchestrator.instance();

  aboutToAppear(): void {
    this.loadSettings();
  }

  private async loadSettings(): Promise<void> {
    await SettingsService.init(getContext(this) as Context);
    this.settings = await SettingsService.load();
    this.rulesEnabled = this.settings.rulesEnabled;
    this.hyperAdRulesEnabled = this.settings.hyperAdRulesEnabled;
    this.customRulesText = this.settings.customRules.join('\n');
  }

  private async save(): Promise<void> {
    const supplied = this.customRulesText.split('\n')
      .map((value: string) => value.trim()).filter((value: string) => value.length > 0);
    const normalized = ClashConfigGenerator.normalizeCustomRules(supplied);
    const invalidCount = Math.max(0, supplied.length - normalized.length);
    this.settings.rulesEnabled = this.rulesEnabled;
    this.settings.hyperAdRulesEnabled = this.hyperAdRulesEnabled;
    this.settings.customRules = normalized;
    await SettingsService.save(this.settings);
    const restarted = await this.orchestrator.restartIfConnected('rulesChanged');
    if (this.controller !== undefined) {
      this.controller.close();
    }
    const suffix = invalidCount > 0 ? `，已忽略 ${invalidCount} 条无效规则` : '';
    promptAction.showToast({
      message: restarted ? `规则已保存，正在自动重连${suffix}` : `规则已保存，下次连接生效${suffix}`
    });
  }

  build() {
    Column({ space: 14 }) {
      Row() {
        Text('规则').fontSize(20).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
        Blank()
        Text(this.rulesEnabled ? '已启用' : '已关闭')
          .fontSize(12).fontColor(this.rulesEnabled ? Ui.success : Ui.textTertiary)
      }.width('100%')
      Row() {
        Column({ space: 4 }) {
          Text('启用规则功能').fontSize(15).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
          Text('不需要规则时可直接关闭').fontSize(12).fontColor(Ui.textTertiary)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.rulesEnabled })
          .selectedColor(Ui.primaryBlueFill)
          .onChange((value: boolean) => { this.rulesEnabled = value; })
      }.width('100%').alignItems(VerticalAlign.Center)
      Row() {
        Text('HyperADRules 去广告').fontSize(14).fontColor(Ui.textPrimary).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.hyperAdRulesEnabled })
          .selectedColor(Ui.primaryBlueFill).enabled(this.rulesEnabled)
          .onChange((value: boolean) => { this.hyperAdRulesEnabled = value; })
      }.width('100%').alignItems(VerticalAlign.Center)
      TextArea({ placeholder: '每行一条规则，例如 DOMAIN-SUFFIX,example.com,REJECT', text: this.customRulesText })
        .enabled(this.rulesEnabled)
        .onChange((value: string) => { this.customRulesText = value; })
        .height(180).fontSize(13).fontColor(Ui.textPrimary).placeholderColor(Ui.textTertiary)
        .backgroundColor(Ui.surfaceTranslucent).borderRadius(14).padding(12)
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
          colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
        })
        .backgroundEffect({ radius: Ui.glassControlBlurRadius, saturation: Ui.glassControlSaturation, brightness: Ui.glassControlBrightness })
        .borderWidth(1).borderColor(Ui.glassEdge)
      Row({ space: 12 }) {
        Button('取消').layoutWeight(1).fontColor(Ui.textSecondary)
          .backgroundColor(Ui.surfaceTranslucent)
          .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
            colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
          })
          .backgroundEffect({ radius: Ui.glassControlBlurRadius, saturation: Ui.glassControlSaturation, brightness: Ui.glassControlBrightness })
          .borderWidth(1).borderColor(Ui.glassEdge)
          .onClick(() => { if (this.controller !== undefined) this.controller.close(); })
        Button('保存').layoutWeight(1).fontColor(Color.White).backgroundColor(Ui.primaryBlueFill)
          .onClick(() => this.save())
      }.width('100%')
    }
    .padding(24).borderRadius(Ui.dialogRadius)
    .backgroundColor(Ui.surfaceTranslucent)
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
      colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
    })
    .backgroundEffect({ radius: Ui.glassBlurRadius, saturation: Ui.glassSaturation, brightness: Ui.glassBrightness })
    .borderWidth(1).borderColor(Ui.glassEdge)
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
  /** 电源按钮直径: 按屏宽自适应(手机≈40% 宽, 平板封顶 210), 修复手机上比例失衡 */
  @State powerSize: number = 210;
  @StorageLink('theme_revision') themeRevision: number = 0;
  /** 桌面长按快捷方式/服务卡片启动请求: EntryAbility 递增 seq + 写 mode, 这里消费 */
  @StorageLink('vpn_request_seq') @Watch('onVpnRequest') vpnRequestSeq: number = 0;
  private pageReady: boolean = false;
  private orchestrator: ConnectionOrchestrator = ConnectionOrchestrator.instance();
  private subs: SubscriptionService = new SubscriptionService();
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
  private aboutDialog: CustomDialogController = new CustomDialogController({
    builder: AboutDialog({})
  });
  private tutorialDialog: CustomDialogController = new CustomDialogController({
    builder: TutorialDialog({})
  });
  private rulesDialog: CustomDialogController = new CustomDialogController({
    builder: RulesDialog({}),
    autoCancel: true,
    alignment: DialogAlignment.Center
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
    const authority = await this.orchestrator.authorityState();
    const snapshot = await SettingsService.loadSnapshot();
    if (authority.connected) {
      this.orchestrator.state = ConnState.CONNECTED;
      if (this.orchestrator.startedAt <= 0 && snapshot.startedAt > 0) {
        this.orchestrator.startedAt = snapshot.startedAt;
      }
    }
    // 电源按钮随屏宽自适应: 手机(≈433vp)取 40% 宽 ≈ 173, 平板封顶 210
    try {
      const disp = display.getDefaultDisplaySync();
      const widthVp = disp.width / disp.densityPixels;
      this.powerSize = Math.round(Math.min(210, Math.max(150, widthVp * 0.40)));
    } catch (e) {
      this.powerSize = 180;
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
      await this.refreshPublicIp();
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
            // ── 头部：关于 + 规则 | SSRVPN(绝对居中) | 使用教程 + 主题切换 ──
            // 标题放在 Stack 里由系统居中，两侧操作项作为同一行的叠加层，
            // 不再参与标题的水平定位（此前右侧按钮会把标题挤偏）。
            Stack() {
              Text('SSRVPN')
                .fontSize(26)
                .fontWeight(FontWeight.Normal)
                .fontColor(Ui.textPrimary)
                .letterSpacing(0.4)
              Row() {
                Text('关于')
                  .fontSize(14).fontColor(Ui.textSecondary)
                  .padding({ left: 4, right: 4 })
                  .onClick(() => this.aboutDialog.open())
                Text('规则')
                  .fontSize(14).fontColor(Ui.textSecondary)
                  .padding({ left: 8, right: 4 })
                  .onClick(() => this.rulesDialog.open())
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

            // ── 当前节点卡 ──
            this.CurrentNodeCard()

            // ── 数据面板: 四格横排(上传速率/下载速率/本次累计/连接时间), 常驻显示。
            // 直接内联在 build() 内: @Builder 值传参没有状态观察,
            // 真机实测 @State 变化不刷新独立 builder, 面板会永远停在 0。 ──
            Blank().height(14)
            Row({ space: 6 }) {
              Column({ space: 4 }) {
                Row({ space: 3 }) {
                  Text('↑').fontSize(12).fontColor(Ui.textBlue)
                  Text(this.formatSpeedValue(this.upSpeed))
                    .fontSize(12).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
                    .maxLines(1)
                }
                .alignItems(VerticalAlign.Center)
                Text('上传速率').fontSize(11).fontColor(Ui.textSecondary)
              }
              .alignItems(HorizontalAlign.Center)
              .justifyContent(FlexAlign.Center)
              .layoutWeight(1)
              .padding({ top: 12, bottom: 12 })
              .borderRadius(14)
              .backgroundColor(Ui.surfaceTranslucent)
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT })
              .backgroundEffect({ radius: Ui.glassControlBlurRadius, saturation: Ui.glassControlSaturation, brightness: Ui.glassControlBrightness })
              .borderWidth(1)
              .borderColor(Ui.glassEdge)

              Column({ space: 4 }) {
                Row({ space: 3 }) {
                  Text('↓').fontSize(12).fontColor(Ui.success)
                  Text(this.formatSpeedValue(this.downSpeed))
                    .fontSize(12).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
                    .maxLines(1)
                }
                .alignItems(VerticalAlign.Center)
                Text('下载速率').fontSize(11).fontColor(Ui.textSecondary)
              }
              .alignItems(HorizontalAlign.Center)
              .justifyContent(FlexAlign.Center)
              .layoutWeight(1)
              .padding({ top: 12, bottom: 12 })
              .borderRadius(14)
              .backgroundColor(Ui.surfaceTranslucent)
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT })
              .backgroundEffect({ radius: Ui.glassControlBlurRadius, saturation: Ui.glassControlSaturation, brightness: Ui.glassControlBrightness })
              .borderWidth(1)
              .borderColor(Ui.glassEdge)

              Column({ space: 4 }) {
                Row({ space: 3 }) {
                  Text('Σ').fontSize(12).fontColor(Ui.accent)
                  Text(this.formatBytesValue(this.upTotal + this.downTotal))
                    .fontSize(12).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
                    .maxLines(1)
                }
                .alignItems(VerticalAlign.Center)
                Text('本次累计').fontSize(11).fontColor(Ui.textSecondary)
              }
              .alignItems(HorizontalAlign.Center)
              .justifyContent(FlexAlign.Center)
              .layoutWeight(1)
              .padding({ top: 12, bottom: 12 })
              .borderRadius(14)
              .backgroundColor(Ui.surfaceTranslucent)
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT })
              .backgroundEffect({ radius: Ui.glassControlBlurRadius, saturation: Ui.glassControlSaturation, brightness: Ui.glassControlBrightness })
              .borderWidth(1)
              .borderColor(Ui.glassEdge)

              Column({ space: 4 }) {
                Text(this.formatConnectionDuration(this.connectionDuration))
                  .fontSize(11).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
                  .maxLines(1)
                Text('连接时间').fontSize(11).fontColor(Ui.textSecondary)
              }
              .alignItems(HorizontalAlign.Center)
              .justifyContent(FlexAlign.Center)
              .layoutWeight(1)
              .padding({ top: 12, bottom: 12 })
              .borderRadius(14)
              .backgroundColor(Ui.surfaceTranslucent)
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT })
              .backgroundEffect({ radius: Ui.glassControlBlurRadius, saturation: Ui.glassControlSaturation, brightness: Ui.glassControlBrightness })
              .borderWidth(1)
              .borderColor(Ui.glassEdge)
            }
            .width('100%')
            .constraintSize({ maxWidth: 408 })

            // ── 连接详情 / 公网 IP ──
            if (this.isConnected || this.errorMessage.length > 0) {
              Blank().height(14)
              if (this.errorMessage.length > 0) {
                Row({ space: 6 }) {
                  Text('⚠').fontSize(16).fontColor(Ui.textError)
                  Text(this.errorMessage).fontSize(13).fontColor(Ui.textError).layoutWeight(1)
                }
                .width('100%')
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
                  Text(this.publicIpRefreshing ? '正在获取公网 IPv4…'
                    : (this.publicIp.length > 0 ? `公网 IPv4  ${this.publicIp}` : this.publicIpError))
                    .fontSize(13).fontColor(Ui.textSecondary)
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)
                .onClick(() => {
                  if (!this.publicIpRefreshing) {
                    this.refreshPublicIp();
                  }
                })
              }
            }
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

  /** 当前节点卡（对齐 SsrvpnCurrentNodeCard） */
  @Builder
  CurrentNodeCard() {
    Column() {
      // 内联卡片样式（自定义组件 builder 跨组件传 UI 在部分设备上布局异常，改用内联）
      Row() {
        Column() {
          Text('✦').fontSize(24).fontColor(Color.White)
        }
        .width(48).height(48)
        .borderRadius(15)
        .backgroundColor(Ui.primary)
        .justifyContent(FlexAlign.Center)
        .shadow({ radius: 18, color: Ui.shadow, offsetY: 8 })

        Column({ space: 4 }) {
          Text('当前节点').fontSize(12).fontColor(Ui.textSecondary)
          Row({ space: 7 }) {
            CountryFlagIcon({
              nodeName: this.currentNodeName.length > 0 ? this.currentNodeName : 'UN',
              iconSize: 22
            })
            Text(this.currentNodeName.length > 0
              ? NodeDisplay.compact(NodeDisplay.withoutLeadingFlag(this.currentNodeName))
              : '暂无可用节点')
              .fontSize(16).fontWeight(FontWeight.Bold)
              .fontColor(Ui.textPrimary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')
          Text(LatencyStyle.text(LatencyController.latencyFor(this.currentNodeName)))
            .fontSize(12)
            .fontColor(LatencyStyle.color(LatencyController.latencyFor(this.currentNodeName)))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 12 })

        Text('›').fontSize(24).fontColor(Ui.textSecondary).margin({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .borderRadius(22)
      .backgroundColor(Ui.surfaceTranslucent)
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
        colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
      })
      .backgroundEffect({ radius: Ui.glassBlurRadius, saturation: Ui.glassSaturationSoft, brightness: Ui.glassBrightnessSoft })
      .borderWidth(1)
      .borderColor(Ui.glassEdge)
      .shadow({ radius: 32, color: Ui.shadow, offsetY: 16 })
    }
    .width('100%')
    .constraintSize({ maxWidth: 408 })
    .onClick(() => {
      router.pushUrl({ url: 'pages/NodeSelectionPage' });
    })
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

  pageTransition() {
    PageTransitionEnter({ duration: 360, curve: Curve.EaseInOut }).opacity(0.68).scale({ x: 0.992, y: 0.992 })
    PageTransitionExit({ duration: 300, curve: Curve.EaseInOut }).opacity(0.72).scale({ x: 1.008, y: 1.008 })
  }
}
