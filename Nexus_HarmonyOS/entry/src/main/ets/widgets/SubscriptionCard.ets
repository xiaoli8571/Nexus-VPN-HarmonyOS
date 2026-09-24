/**
 * 订阅卡片
 * 移植自 upstream: packages/ssrvpn_shared/lib/widgets/ssrvpn_subscription_view.dart
 *                ssrvpn_subscription_connection_card.dart / ssrvpn_subscription_header.dart
 */
import { Ui } from '../theme/UiTokens';
import { Subscription } from '../commons/models/Subscription';

@Component
export struct SubscriptionCard {
  @Prop sub: Subscription | null = null;
  @Prop darkMode: boolean = true;
  @Prop active: boolean = false;
  onRefresh: (id: string) => void = () => {};
  onEdit: (id: string) => void = () => {};
  onDelete: (id: string) => void = () => {};

  private subId(): string {
    return this.sub !== null ? this.sub.id : '';
  }

  build() {
    if (this.sub !== null) {
      Column({ space: 10 }) {
        Row({ space: 10 }) {
          Text(this.sub.name)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.textPrimary)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.active) {
            Text('当前')
              .fontSize(11)
              .fontColor(Color.White)
              .backgroundColor(Ui.primaryBlueFill)
              .borderRadius(8)
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          }
        }
        .width('100%')

        Text(this.sub.url)
          .fontSize(12)
          .fontColor(Ui.textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Row() {
          Text(`节点 ${this.sub.nodeCount}`)
            .fontSize(13)
            .fontColor(Ui.textSecondary)
          Blank()
          Text('刷新')
            .fontSize(13)
            .fontColor(Ui.primary)
            .onClick(() => this.onRefresh(this.subId()))
            .padding({ left: 12, right: 6 })
          Text('编辑')
            .fontSize(13)
            .fontColor(Ui.primary)
            .onClick(() => this.onEdit(this.subId()))
            .padding({ left: 6, right: 6 })
          Text('删除')
            .fontSize(13)
            .fontColor(Ui.error)
            .onClick(() => this.onDelete(this.subId()))
            .padding({ left: 6, right: 12 })
        }
        .width('100%')
      }
      .width('100%')
      .padding(16)
      .borderRadius(Ui.cardRadius)
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
        radius: this.active ? 30 : 24,
        color: this.active ? Ui.glassGlow : Ui.shadow,
        offsetX: 0,
        offsetY: this.active ? 10 : 12
      })
    }
  }
}
