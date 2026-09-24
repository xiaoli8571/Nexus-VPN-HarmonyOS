/**
 * 节点编辑页（手工添加/编辑节点）— 视觉对齐 upstream 新令牌（UiTokens）
 * 移植自 upstream: SSRVPN_Android/lib/screens/node_edit_screen.dart
 */
import { router, promptAction } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { Ui } from '../theme/UiTokens';
import { ProxyNode, ProxyNodeType } from '../commons/models/ProxyNode';
import { ManualNodeStore } from '../commons/services/SubscriptionService';
import { SettingsService } from '../commons/services/SettingsService';

@Entry
@Component
struct NodeEditPage {
  @State name: string = '';
  @State server: string = '';
  @State port: string = '';
  @State password: string = '';
  @State method: string = 'aes-256-cfb';
  @State protocol: string = 'origin';
  @State obfs: string = 'plain';
  @State rawImport: string = '';
  onPageShow(): void {
    this.bootstrap();
  }

  private async bootstrap(): Promise<void> {
    const context = getContext(this) as Context;
    await SettingsService.init(context);
    await ManualNodeStore.init(context);
  }

  /** 从 ssr:// / ss:// 链接一键导入（对应 subscription_node_editor 的导入行为） */
  private importFromUri(): void {
    const node = ProxyNode.fromUri(this.rawImport.trim(), 'direct', util.generateRandomUUID());
    if (node === null) {
      promptAction.showToast({ message: '链接解析失败，请检查格式' });
      return;
    }
    this.name = node.name;
    this.server = node.server;
    this.port = `${node.port}`;
    this.password = node.password;
    this.method = node.method;
    this.protocol = node.protocol.length > 0 ? node.protocol : 'origin';
    this.obfs = node.obfs.length > 0 ? node.obfs : 'plain';
  }

  private async save(): Promise<void> {
    const portNum = parseInt(this.port);
    if (this.server.length === 0 || !(portNum > 0 && portNum < 65536)) {
      promptAction.showToast({ message: '服务器地址或端口无效' });
      return;
    }
    const node = new ProxyNode();
    node.id = util.generateRandomUUID();
    node.subscriptionId = 'direct';
    node.type = ProxyNodeType.SSR;
    node.name = this.name.length > 0 ? this.name : this.server;
    node.server = this.server.trim();
    node.port = portNum;
    node.password = this.password;
    node.method = this.method;
    node.protocol = this.protocol;
    node.protocolParam = '';
    node.obfs = this.obfs;
    node.obfsParam = '';
    const duplicate = ManualNodeStore.all().some((existing: ProxyNode) =>
      existing.server === node.server && existing.port === node.port && existing.type === node.type);
    if (duplicate) {
      promptAction.showToast({ message: '该节点已存在' });
      return;
    }
    await ManualNodeStore.addNode(node);
    promptAction.showToast({ message: '节点已保存' });
    router.back();
  }

  build() {
    Stack() {
      Column()
        .width('100%').height('100%')
        .linearGradient({ angle: 135, colors: Ui.backdropColors })
        // 背景延伸到状态栏/底部导航条之下, 消除底部白条
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column() {
        Row() {
          Text('←')
            .fontSize(22).fontColor(Ui.textPrimary)
            .onClick(() => router.back())
          Blank()
          Text('编辑节点')
            .fontSize(17).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
          Blank()
          Text('保存')
            .fontSize(15).fontColor(Ui.textBlue)
            .onClick(() => this.save())
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 10, bottom: 6 })

        Scroll() {
          Column({ space: 12 }) {
            Column({ space: 12 }) {
              Column({ space: 12 }) {
                Text('从链接导入').fontSize(13).fontColor(Ui.textTertiary)
                TextInput({ placeholder: '粘贴 ssr:// 或 ss:// 链接', text: this.rawImport })
                  .onChange((v: string) => { this.rawImport = v; })
                  .height(88)
                  .borderRadius(14)
                  .backgroundColor(Ui.surfaceTranslucent)
                  .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
                    colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
                  })
                  .backgroundEffect({
                    radius: Ui.glassControlBlurRadius,
                    saturation: Ui.glassControlSaturation,
                    brightness: Ui.glassControlBrightness
                  })
                  .borderWidth(1)
                  .borderColor(Ui.glassEdge)
                  .fontColor(Ui.textPrimary)
                  .placeholderColor(Ui.textTertiary)
                Button('解析并填充')
                  .width('100%')
                  .height(44)
                  .backgroundColor(Ui.surfaceTranslucent)
                  .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
                    colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
                  })
                  .backgroundEffect({
                    radius: Ui.glassControlBlurRadius,
                    saturation: Ui.glassControlSaturation,
                    brightness: Ui.glassControlBrightness
                  })
                  .borderWidth(1)
                  .borderColor(Ui.glassEdge)
                  .fontColor(Ui.textViolet)
                  .borderRadius(12)
                  .onClick(() => this.importFromUri())
              }
              .width('100%')
              .padding(18)
              .borderRadius(22)
              .backgroundColor(Ui.surfaceTranslucent)
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT })
              .backgroundEffect({
                radius: Ui.glassBlurRadius,
                saturation: Ui.glassSaturationSoft,
                brightness: Ui.glassBrightnessSoft
              })
              .borderWidth(1)
              .borderColor(Ui.glassEdge)
              .shadow({ radius: 32, color: Ui.shadow, offsetY: 16 })
            }

            Column({ space: 12 }) {
              Column({ space: 12 }) {
                Text('节点信息').fontSize(13).fontColor(Ui.textTertiary)
                TextInput({ placeholder: '节点名称', text: this.name })
                  .onChange((v: string) => { this.name = v; })
                  .height(46).borderRadius(12).backgroundColor(Ui.surfaceTranslucent)
                  .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT })
                  .backgroundEffect({ radius: Ui.glassControlBlurRadius, saturation: Ui.glassControlSaturation, brightness: Ui.glassControlBrightness })
                  .borderWidth(1).borderColor(Ui.glassEdge).fontColor(Ui.textPrimary).placeholderColor(Ui.textTertiary)
                TextInput({ placeholder: '服务器地址', text: this.server })
                  .onChange((v: string) => { this.server = v; })
                  .height(46).borderRadius(12).backgroundColor(Ui.surfaceTranslucent)
                  .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT })
                  .backgroundEffect({ radius: Ui.glassControlBlurRadius, saturation: Ui.glassControlSaturation, brightness: Ui.glassControlBrightness })
                  .borderWidth(1).borderColor(Ui.glassEdge).fontColor(Ui.textPrimary).placeholderColor(Ui.textTertiary)
                TextInput({ placeholder: '端口', text: this.port })
                  .onChange((v: string) => { this.port = v; })
                  .height(46).borderRadius(12).backgroundColor(Ui.surfaceTranslucent)
                  .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT })
                  .backgroundEffect({ radius: Ui.glassControlBlurRadius, saturation: Ui.glassControlSaturation, brightness: Ui.glassControlBrightness })
                  .borderWidth(1).borderColor(Ui.glassEdge).fontColor(Ui.textPrimary).placeholderColor(Ui.textTertiary)
                TextInput({ placeholder: '密码', text: this.password })
                  .onChange((v: string) => { this.password = v; })
                  .type(InputType.Password)
                  .height(46).borderRadius(12).backgroundColor(Ui.surfaceTranslucent)
                  .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT })
                  .backgroundEffect({ radius: Ui.glassControlBlurRadius, saturation: Ui.glassControlSaturation, brightness: Ui.glassControlBrightness })
                  .borderWidth(1).borderColor(Ui.glassEdge).fontColor(Ui.textPrimary).placeholderColor(Ui.textTertiary)
                Row({ space: 8 }) {
                  TextInput({ placeholder: '加密方法', text: this.method })
                    .onChange((v: string) => { this.method = v; })
                    .height(46).borderRadius(12).backgroundColor(Ui.surfaceTranslucent)
                    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT })
                    .backgroundEffect({ radius: Ui.glassControlBlurRadius, saturation: Ui.glassControlSaturation, brightness: Ui.glassControlBrightness })
                    .borderWidth(1).borderColor(Ui.glassEdge)
                    .fontColor(Ui.textPrimary).placeholderColor(Ui.textTertiary).layoutWeight(1)
                  TextInput({ placeholder: '协议', text: this.protocol })
                    .onChange((v: string) => { this.protocol = v; })
                    .height(46).borderRadius(12).backgroundColor(Ui.surfaceTranslucent)
                    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT })
                    .backgroundEffect({ radius: Ui.glassControlBlurRadius, saturation: Ui.glassControlSaturation, brightness: Ui.glassControlBrightness })
                    .borderWidth(1).borderColor(Ui.glassEdge)
                    .fontColor(Ui.textPrimary).placeholderColor(Ui.textTertiary).layoutWeight(1)
                  TextInput({ placeholder: '混淆', text: this.obfs })
                    .onChange((v: string) => { this.obfs = v; })
                    .height(46).borderRadius(12).backgroundColor(Ui.surfaceTranslucent)
                    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT })
                    .backgroundEffect({ radius: Ui.glassControlBlurRadius, saturation: Ui.glassControlSaturation, brightness: Ui.glassControlBrightness })
                    .borderWidth(1).borderColor(Ui.glassEdge)
                    .fontColor(Ui.textPrimary).placeholderColor(Ui.textTertiary).layoutWeight(1)
                }
                .width('100%')
              }
              .width('100%')
              .padding(18)
              .borderRadius(22)
              .backgroundColor(Ui.surfaceTranslucent)
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT })
              .backgroundEffect({
                radius: Ui.glassBlurRadius,
                saturation: Ui.glassSaturationSoft,
                brightness: Ui.glassBrightnessSoft
              })
              .borderWidth(1)
              .borderColor(Ui.glassEdge)
              .shadow({
                radius: Ui.glassShadowRadius,
                color: Ui.shadow,
                offsetY: Ui.glassShadowOffsetY
              })
            }
          }
          .padding({ left: 18, right: 18, bottom: 40 })
          .constraintSize({ maxWidth: Ui.pageMaxWidth })
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      .width('100%').height('100%')
    }
    .width('100%').height('100%')
  }

  pageTransition() {
    PageTransitionEnter({ duration: 360, curve: Curve.EaseInOut })
      .translate({ x: '4%', y: 0 }).opacity(0.68)
    PageTransitionExit({ duration: 300, curve: Curve.EaseInOut })
      .translate({ x: '2%', y: 0 }).opacity(0.72)
  }
}
