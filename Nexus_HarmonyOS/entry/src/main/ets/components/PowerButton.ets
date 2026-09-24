/**
 * Power start button (1:1 aligned with upstream SsrvpnPowerButton)
 *
 * Upstream: outer 2px theme border + glow; inner solid circle;
 * Material power icon (circle with top gap + vertical bar) at 36% size.
 *
 * Implementation note: NO Path / NO mask overlay (both broken on real device).
 * The icon ring is drawn with Circle.strokeDashArray (mature attribute), the
 * top gap is rotated to 12 o'clock, and the vertical bar is a Column centered
 * with offset. All layers are plain Circle/Column primitives.
 */
import { Ui } from '../theme/UiTokens';

@Component
export struct PowerButton {
  @Prop isConnected: boolean = false;
  @Prop isConnecting: boolean = false;
  @Prop hasError: boolean = false;
  @Prop buttonSize: number = 210;
  onToggle: () => void = () => {};
  @State private pressed: boolean = false;

  private activeColor(): ResourceColor {
    if (this.hasError) {
      return Ui.error;
    }
    return this.isConnected ? Ui.success : Ui.primary;
  }

  private iconColor(): ResourceColor {
    return this.isConnected ? this.activeColor() : Ui.textSecondary;
  }

  build() {
    Stack() {
      // 外层边框圆环 + 外发光（原版 Border.all 2px + BoxShadow blur38）
      // 柔和圆形光晕（替代 shadow: ArkUI 形状 shadow 按矩形边界渲染会产生方框）
      Circle({ width: this.buttonSize + 56, height: this.buttonSize + 56 })
        .fill(Color.Transparent)
        .radialGradient({
          center: [(this.buttonSize + 56) / 2, (this.buttonSize + 56) / 2],
          radius: (this.buttonSize + 56) / 2,
          colors: [
            [Color.Transparent, 0.0],
            [this.isConnected ? Ui.powerGlowActive : Ui.powerGlowIdle, 0.76],
            [Color.Transparent, 1.0]
          ]
        })
      // 外层边框圆环（原版 Border.all 2px 主题色）
      Circle({ width: this.buttonSize, height: this.buttonSize })
        .fill(Color.Transparent)
        .stroke(this.isConnected ? Ui.powerRingActive : Ui.powerRingIdle)
        .strokeWidth(2)
      // 内层实心圆（连接 20% 主题色 / 未连接 #202B4B）
      Circle({ width: this.buttonSize * 0.85, height: this.buttonSize * 0.85 })
        .fill(this.isConnected ? Ui.powerInnerActive : Ui.powerInnerIdle)
      // Power 图标
      if (this.isConnecting) {
        LoadingProgress()
          .width(this.buttonSize * 0.3)
          .height(this.buttonSize * 0.3)
          .color(this.activeColor())
      } else {
        Stack() {
          // 图标圆环: 顶部 60° 缺口由 strokeDashArray 生成, rotate 转缺口到 12 点
          // 直径 64, 周长≈201, 缺口弧长≈34
          Circle({ width: 64, height: 64 })
            .fill(Color.Transparent)
            .stroke(this.iconColor())
            .strokeWidth(5)
            .strokeDashArray([167, 34])
            .rotate({ angle: -60 })
          // 竖线: 穿过顶部缺口中央
          Column()
            .width(5)
            .height(28)
            .borderRadius(2.5)
            .backgroundColor(this.iconColor())
            .offset({ x: 0, y: -17 })
        }
        .width(72)
        .height(72)
      }
    }
    .width(this.buttonSize)
    .height(this.buttonSize)
    .scale(this.pressed ? { x: 0.95, y: 0.95 } : { x: 1, y: 1 })
    .onClick(() => {
      animateTo({ duration: 120 }, () => { this.pressed = true; });
      setTimeout(() => {
        animateTo({ duration: 200 }, () => { this.pressed = false; });
      }, 140);
      this.onToggle();
    })
  }
}
