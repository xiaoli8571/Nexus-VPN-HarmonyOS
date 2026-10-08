/**
 * Nexus 状态环 —— 对齐开发文档 §3 / HTML .status-ring
 * 三层：外层光晕(呼吸) / 中层圆盘 / 核心内容(图标+状态+节点名)
 * 铁律：所有圆形一律纯色 .fill，禁用 .shadow / .linearGradient / .radialGradient。
 * ArkUI 里 .shadow 按矩形渲染，渐变类通用属性画在矩形盒子上——两者都会透出方形底。
 */
import { Nx } from '../theme/NexusTokens';

@Component
export struct StatusRing {
  @Prop isConnected: boolean = false;
  @Prop isConnecting: boolean = false;
  @Prop statusText: string = '未连接';
  @Prop nodeName: string = '';
  /** 外圈直径（默认 196；文档基准 172，用户要求放大一圈） */
  @Prop diameter: number = 196;
  onToggle: () => void = () => {};
  @State private pressed: boolean = false;

  private glowColor(): ResourceColor {
    return this.isConnected ? 'rgba(16, 185, 129, 0.22)' : 'rgba(37, 99, 235, 0.12)';
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 唯一外圈：呼吸光晕环
      Circle({ width: this.diameter, height: this.diameter })
        .fill(this.glowColor())
        .opacity(this.isConnected ? 0.9 : 1.0)
        .scale(this.isConnected ? { x: 1.04, y: 1.04 } : { x: 1.0, y: 1.0 })
        .animation({
          duration: 1200, iterations: this.isConnected ? -1 : 1,
          playMode: PlayMode.Alternate, curve: Curve.EaseInOut
        })
      // Layer 1: 中层圆盘（纯白扁平。描边必须用形状 .stroke，通用 .borderWidth 画在矩形盒子上会出方形边框）
      Circle({ width: this.diameter - 24, height: this.diameter - 24 })
        .fill(Nx.disc())
        .stroke(Nx.discBorder(this.isConnected))
        .strokeWidth(1.5)
      // Layer 2: 核心内容
      Column({ space: 3 }) {
        Stack({ alignContent: Alignment.Center }) {
          Circle({ width: 40, height: 40 })
            .fill(this.isConnected ? Nx.successSoft() : Nx.iconBg())
          if (this.isConnecting) {
            LoadingProgress()
              .width(22).height(22)
              .color(this.isConnected ? Nx.success() : Nx.muted())
          } else {
            Text('⏻')
              .fontSize(20)
              .fontColor(this.isConnected ? Nx.success() : Nx.muted())
          }
        }
        Text(this.statusText)
          .fontSize(19).fontWeight(FontWeight.Bold).fontColor(Nx.fg())
        Text(this.nodeName.length > 0 ? this.nodeName : '暂无可用节点')
          .fontSize(11).fontColor(Nx.muted())
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: this.diameter - 46 })
      }
    }
    .width(this.diameter)
    .height(this.diameter)
    .scale(this.pressed ? { x: 0.97, y: 0.97 } : { x: 1.0, y: 1.0 })
    .gesture(TapGesture()
      .onAction(() => {
        animateTo({ duration: 120, curve: Curve.FastOutSlowIn }, () => {
          this.pressed = true;
        });
        setTimeout(() => {
          animateTo({ duration: 250, curve: Curve.EaseOut }, () => {
            this.pressed = false;
          });
        }, 140);
        this.onToggle();
      }))
  }
}
