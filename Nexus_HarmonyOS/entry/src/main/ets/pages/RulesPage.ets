import { router, promptAction } from '@kit.ArkUI';
import { Ui } from '../theme/UiTokens';
import { AppSettings } from '../commons/models/AppSettings';
import { SettingsService } from '../commons/services/SettingsService';
import { ClashConfigGenerator } from '../commons/services/ClashConfigGenerator';
import { ConnectionOrchestrator } from '../commons/services/ConnectionOrchestrator';

@Entry
@Component
struct RulesPage {
  @State rulesEnabled: boolean = true;
  @State hyperAdRulesEnabled: boolean = true;
  @State customRulesText: string = '';
  /** 逐行校验错误（"第 N 行：原因"），输入即刷新（M8：所见校验 = 实际落盘） */
  @State ruleErrors: string[] = [];
  private settings: AppSettings = new AppSettings();
  private orchestrator: ConnectionOrchestrator = ConnectionOrchestrator.instance();

  onPageShow(): void {
    this.bootstrap();
  }

  /** 输入变化时逐行校验；规则为空的行跳过（不报错） */
  private refreshRuleErrors(): void {
    const errors: string[] = [];
    const lines = this.customRulesText.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (line.length === 0) {
        continue;
      }
      const error = ClashConfigGenerator.validateCustomRuleDetailed(line);
      if (error.length > 0) {
        errors.push(`第 ${i + 1} 行：${error}`);
      }
    }
    this.ruleErrors = errors;
  }

  private async bootstrap(): Promise<void> {
    await SettingsService.init(getContext(this) as Context);
    this.settings = await SettingsService.load();
    this.rulesEnabled = this.settings.rulesEnabled;
    this.hyperAdRulesEnabled = this.settings.hyperAdRulesEnabled;
    this.customRulesText = this.settings.customRules.join('\n');
    this.refreshRuleErrors();
  }

  private async save(): Promise<void> {
    const supplied = this.customRulesText.split('\n')
      .map((v: string) => v.trim()).filter((v: string) => v.length > 0);
    const normalized = ClashConfigGenerator.normalizeCustomRules(supplied);
    const invalidCount = Math.max(0, supplied.length - normalized.length);
    this.settings.rulesEnabled = this.rulesEnabled;
    this.settings.hyperAdRulesEnabled = this.hyperAdRulesEnabled;
    this.settings.customRules = normalized;
    this.customRulesText = normalized.join('\n');
    this.refreshRuleErrors();
    await SettingsService.save(this.settings);
    const outcome = await this.orchestrator.applyRulesChanged('rulesChanged');
    const suffix = invalidCount > 0 ? `，已忽略 ${invalidCount} 条无效规则` : '';
    const effect = outcome === 'hot' ? '已即时生效（未重建隧道）'
      : (outcome === 'reconnect' ? '正在自动重连' : '下次连接生效');
    promptAction.showToast({
      message: `规则已保存，${effect}${suffix}`
    });
  }

  build() {
    Stack() {
      Column().width('100%').height('100%')
        .linearGradient({ angle: 135, colors: Ui.backdropColors })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      Column() {
        Row() {
          Text('←').fontSize(22).fontColor(Ui.textPrimary).padding({ left: 4, right: 10 })
            .onClick(() => router.back())
          Text('规则').fontSize(18).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
          Blank()
          Text('保存').fontSize(14).fontWeight(FontWeight.Bold).fontColor(Ui.textBlue)
            .padding({ left: 10, right: 4, top: 8, bottom: 8 }).onClick(() => this.save())
        }.width('100%').height(48).padding({ left: 14, right: 14 })
        Scroll() {
          Column({ space: 14 }) {
            Row() {
              Column({ space: 4 }) {
                Text('启用规则功能').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
                Text(this.rulesEnabled ? '规则将在连接时生效' : '已关闭，将使用基础代理配置')
                  .fontSize(12).fontColor(Ui.textTertiary)
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.rulesEnabled })
                .selectedColor(Ui.primaryBlueFill)
                .onChange((value: boolean) => { this.rulesEnabled = value; })
            }.width('100%').alignItems(VerticalAlign.Center).padding(18).borderRadius(22)
              .backgroundColor(Ui.surfaceTranslucent)
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
                colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
              })
              .backgroundEffect({
                radius: Ui.glassBlurRadius, saturation: Ui.glassSaturationSoft, brightness: Ui.glassBrightnessSoft
              })
              .borderWidth(1).borderColor(Ui.glassEdge).shadow({ radius: 24, color: Ui.shadow, offsetY: 10 })
            Column({ space: 10 }) {
              Row() {
                Column({ space: 4 }) {
                  Text('HyperADRules 去广告').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
                  Text('默认启用，每日自动更新官方 MRS 规则集').fontSize(12).fontColor(Ui.textTertiary)
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.hyperAdRulesEnabled })
                  .selectedColor(Ui.primaryBlueFill)
                  .enabled(this.rulesEnabled)
                  .onChange((value: boolean) => { this.hyperAdRulesEnabled = value; })
              }.width('100%').alignItems(VerticalAlign.Center)
              Text('来源：Lynricsy/HyperADRules · 广告域名命中后直接 REJECT')
                .fontSize(11).fontColor(Ui.textTertiary).width('100%')
            }.width('100%').padding(18).borderRadius(22)
              .backgroundColor(Ui.surfaceTranslucent)
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
                colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
              })
              .backgroundEffect({
                radius: Ui.glassBlurRadius, saturation: Ui.glassSaturationSoft, brightness: Ui.glassBrightnessSoft
              })
              .borderWidth(1).borderColor(Ui.glassEdge).shadow({ radius: 24, color: Ui.shadow, offsetY: 10 })
            Column({ space: 10 }) {
              Text('自定义规则').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary).width('100%')
              Text('每行一条，例如 DOMAIN-SUFFIX,example.com,REJECT').fontSize(12).fontColor(Ui.textTertiary).width('100%')
              TextArea({
                placeholder: 'DOMAIN-SUFFIX,example.com,REJECT\nDOMAIN,example.org,DIRECT',
                text: this.customRulesText
              })
                .enabled(this.rulesEnabled)
                .onChange((value: string) => {
                  this.customRulesText = value;
                  this.refreshRuleErrors();
                })
                .height(260).fontSize(13).fontColor(Ui.textPrimary).placeholderColor(Ui.textTertiary)
                .backgroundColor(Ui.inputBackground).borderRadius(14).padding(12)
                .borderWidth(1)
                .borderColor(this.ruleErrors.length > 0 ? Ui.error : Ui.glassEdge)
              if (this.ruleErrors.length > 0) {
                Column({ space: 3 }) {
                  ForEach(this.ruleErrors, (err: string) => {
                    Text(`⚠ ${err}`)
                      .fontSize(11).fontColor(Ui.error).width('100%')
                  }, (err: string, idx: number) => `${idx}-${err}`)
                }
                .width('100%')
                .padding(10)
                .borderRadius(12)
                .backgroundColor(Ui.inputBackground)
                .borderWidth(1)
                .borderColor(Ui.error)
                .alignItems(HorizontalAlign.Start)
              }
              Text('支持 DOMAIN、DOMAIN-SUFFIX、DOMAIN-KEYWORD、IP-CIDR、IP-CIDR6、GEOIP；策略支持 DIRECT、PROXY、REJECT、PASS、REJECT-DROP；IP 类规则可追加 no-resolve。')
                .fontSize(11).fontColor(Ui.textTertiary).width('100%')
            }.width('100%').padding(18).borderRadius(22)
              .backgroundColor(Ui.surfaceTranslucent)
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
                colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
              })
              .backgroundEffect({
                radius: Ui.glassBlurRadius, saturation: Ui.glassSaturationSoft, brightness: Ui.glassBrightnessSoft
              })
              .borderWidth(1).borderColor(Ui.glassEdge).shadow({ radius: 24, color: Ui.shadow, offsetY: 10 })
          }.width('100%').constraintSize({ maxWidth: Ui.pageMaxWidth })
            .padding({ left: 18, right: 18, top: 8, bottom: 30 })
        }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
      }.width('100%').height('100%')
    }.width('100%').height('100%')
  }

  pageTransition() {
    PageTransitionEnter({ duration: 360, curve: Curve.EaseInOut })
      .translate({ x: '4%', y: 0 }).opacity(0.68)
    PageTransitionExit({ duration: 300, curve: Curve.EaseInOut })
      .translate({ x: '2%', y: 0 }).opacity(0.72)
  }
}
