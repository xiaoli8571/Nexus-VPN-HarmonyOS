/**
 * 节点选择卡片
 * 移植自 upstream: packages/ssrvpn_shared/lib/widgets/ssrvpn_node_selection_node_card.dart
 * 延迟着色规则：<200 绿 / <500 警告黄 / 失败 红，与 upstream 一致。
 */
import { Ui, LatencyStyle } from '../theme/UiTokens';
import { ProxyNode } from '../commons/models/ProxyNode';
import { NodeCountryPolicy } from '../commons/services/PublicIpService';
import { CountryFlagIcon } from './CountryFlagIcon';

@Component
export struct NodeCard {
  @Prop node: ProxyNode | null = null;
  @Prop darkMode: boolean = true;
  @Prop selected: boolean = false;
  @Prop latencyMs: number = -2; // -2 未测试, -1 失败
  onSelect: (node: ProxyNode) => void = () => {};

  private latencyText(): string {
    if (this.latencyMs === -2) {
      return '—';
    }
    if (this.latencyMs === -1) {
      return '超时';
    }
    return `${this.latencyMs}ms`;
  }

  private latencyColor(): ResourceColor {
    if (this.latencyMs === -2) return Ui.textTertiary;
    if (this.latencyMs === -1) return Ui.error;
    return LatencyStyle.color(this.latencyMs);
  }

  build() {
    if (this.node !== null) {
      Row({ space: 12 }) {
        CountryFlagIcon({ nodeName: this.node.name, iconSize: 20 })
        Column({ space: 2 }) {
          Text(NodeCountryPolicy.displayName(this.node.name))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.selected ? Ui.primary : Ui.textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`${this.node.server}:${this.node.port}`)
            .fontSize(12)
            .fontColor(Ui.textTertiary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text(this.latencyText())
          .fontSize(13)
          .fontColor(this.latencyColor())

        if (this.selected) {
          Text('✓')
            .fontSize(16)
            .fontColor(Ui.primary)
        }
      }
      .width('100%')
      .padding(14)
      .borderRadius(Ui.cardRadius)
      .backgroundColor(this.selected ? Ui.surfaceStrong : Ui.surfaceTranslucent)
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT })
      .backgroundEffect({
        radius: Ui.glassBlurRadius,
        saturation: Ui.glassSaturationSoft,
        brightness: Ui.glassBrightnessSoft
      })
      .borderWidth(this.selected ? 1.5 : 1)
      .borderColor(this.selected ? Ui.primary : Ui.glassEdge)
      .shadow({
        radius: this.selected ? 30 : 24,
        color: this.selected ? Ui.glassGlow : Ui.shadow,
        offsetX: 0,
        offsetY: this.selected ? 10 : 12
      })
      .onClick(() => {
        if (this.node !== null) {
          this.onSelect(this.node);
        }
      })
    }
  }
}
