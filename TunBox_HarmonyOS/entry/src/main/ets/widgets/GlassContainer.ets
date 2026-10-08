/**
 * 毛玻璃容器
 * 移植自 upstream: SSRVPN_Android/lib/widgets/glass_container.dart
 *                packages/ssrvpn_shared/lib/widgets/glass_container_part.dart
 * Flutter 的 BackdropFilter + liquid_lens.frag 着色器用 ArkUI backgroundEffect 等价实现。
 */
import { Ui } from '../theme/UiTokens';

@Component
export struct GlassContainer {
  @Prop darkMode: boolean = true;
  @Prop radius: number = Ui.cardRadius;
  @Prop paddingV: number = 16;
  @Prop paddingH: number = 16;
  @Prop interactive: boolean = false;
  @State private pressed: boolean = false;
  @Builder
  emptyContent() {
  }
  @BuilderParam content: () => void = this.emptyContent;

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.content()
      }
      .width('100%')

      // 顶部折射高光，模拟液态玻璃边缘聚光；不拦截内容交互。
      Column()
        .width('100%')
        .height('46%')
        .borderRadius({ topLeft: this.radius, topRight: this.radius })
        .linearGradient({
          angle: 160,
          colors: [[Ui.glassHighlight, 0.0], [Ui.glassHighlightSoft, 0.32], [Color.Transparent, 1.0]]
        })
        .hitTestBehavior(HitTestMode.None)
    }
    .padding({ top: this.paddingV, bottom: this.paddingV, left: this.paddingH, right: this.paddingH })
    .borderRadius(this.radius)
    .backgroundColor(Ui.surfaceTranslucent)
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
    .scale(this.interactive && this.pressed
      ? { x: Ui.glassPressScale, y: Ui.glassPressScale }
      : { x: 1, y: 1 })
    .animation({ duration: 180, curve: Curve.EaseOut })
    .onTouch((event: TouchEvent) => {
      if (!this.interactive) {
        return;
      }
      if (event.type === TouchType.Down) {
        this.pressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressed = false;
      }
    })
  }
}

/** 液态透镜高光层：liquid_lens.frag 的近似视觉（顶部高光渐变） */
@Component
export struct LiquidLensOverlay {
  @Prop darkMode: boolean = true;

  build() {
    Column()
      .width('100%')
      .height('100%')
      .linearGradient({
        angle: 160,
        colors: [[Ui.glassHighlight, 0.0], [Ui.glassHighlightSoft, 0.28], [Color.Transparent, 0.72]]
      })
      .hitTestBehavior(HitTestMode.None)
  }
}
