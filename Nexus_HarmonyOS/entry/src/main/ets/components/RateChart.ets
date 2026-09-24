/**
 * Nexus 速率折线 —— 对齐开发文档 §4.2
 * 归一化坐标系（基线 46/52，振幅 36/52，26 点滑动窗口），按组件实测宽高缩放，
 * 平板等宽屏下折线铺满全宽，不再只占左半边。
 */
import { Nx, NexusSizes } from '../theme/NexusTokens';

@Component
export struct RateChart {
  @Prop points: number[] = [];
  @Prop isConnected: boolean = false;
  @State private chartW: number = NexusSizes.rateChartW;
  @State private chartH: number = NexusSizes.rateChartH;

  private lineColor(): ResourceColor {
    return this.isConnected ? Nx.success() : Nx.accent();
  }

  private areaColor(): ResourceColor {
    return this.isConnected ? 'rgba(16, 185, 129, 0.10)' : Nx.areaBlue();
  }

  private baseRatio(): number {
    return NexusSizes.rateBaseY / NexusSizes.rateChartH;
  }

  private ampRatio(): number {
    return NexusSizes.rateAmpY / NexusSizes.rateChartH;
  }

  private linePoints(): number[][] {
    const n = Math.max(2, this.points.length);
    const pts: number[][] = [];
    for (let i = 0; i < this.points.length; i++) {
      const r = Math.min(1, Math.max(0, this.points[i]));
      const x = i * (this.chartW / (n - 1));
      const y = this.chartH * this.baseRatio() - r * this.chartH * this.ampRatio();
      pts.push([x, y]);
    }
    return pts;
  }

  private areaPoints(): number[][] {
    const line = this.linePoints();
    const closed: number[][] = line.slice();
    closed.push([this.chartW, this.chartH]);
    closed.push([0, this.chartH]);
    return closed;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 面积
      Polygon({ width: this.chartW, height: this.chartH })
        .points(this.areaPoints())
        .fill(this.areaColor())
        .stroke(Color.Transparent)
        .strokeWidth(0)
      // 折线
      Polyline({ width: this.chartW, height: this.chartH })
        .points(this.linePoints())
        .stroke(this.lineColor())
        .strokeWidth(2.2)
        .strokeLineCap(LineCapStyle.Round)
        .strokeLineJoin(LineJoinStyle.Round)
        .fill(Color.Transparent)
    }
    .width('100%')
    .height(52)
    .onAreaChange((_old: Area, cur: Area) => {
      const w = Number(cur.width);
      const h = Number(cur.height);
      if (!Number.isNaN(w) && w > 0) {
        this.chartW = w;
      }
      if (!Number.isNaN(h) && h > 0) {
        this.chartH = h;
      }
    })
  }
}
