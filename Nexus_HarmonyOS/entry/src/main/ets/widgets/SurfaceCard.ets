/**
 * SsrvpnSurfaceCard 等价物 — 对齐 upstream ssrvpn_app_surface.dart
 * surface 88% alpha + 白 20% 描边 + 黑 22% 投影 (blur28, offsetY14)。
 */
import { Ui } from '../theme/UiTokens';

@Component
export struct SurfaceCard {
  @Prop radius: number = Ui.cardRadius;
  @Prop paddingV: number = 20;
  @Prop paddingH: number = 20;
  @Prop bgColor: ResourceColor = Ui.surfaceMuted;
  @Prop edgeColor: ResourceColor = Ui.border;
  @BuilderParam content: () => void = this.empty;

  @Builder
  empty() {
  }

  build() {
    Column() {
      Column() {
        this.content()
      }
      .width('100%')
    }
    .padding({ top: this.paddingV, bottom: this.paddingV, left: this.paddingH, right: this.paddingH })
    .borderRadius(this.radius)
    .backgroundColor(this.bgColor)
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
      colorMode: ThemeColorMode.SYSTEM,
      adaptiveColor: AdaptiveColor.DEFAULT
    })
    .backgroundEffect({
      radius: Ui.glassBlurRadius,
      saturation: Ui.glassSaturation,
      brightness: Ui.glassBrightness
    })
    .borderWidth(1)
    .borderColor(Ui.glassEdge)
    .shadow({
      radius: Ui.glassShadowRadius,
      color: Ui.shadow,
      offsetX: 0,
      offsetY: Ui.glassShadowOffsetY
    })
  }
}
