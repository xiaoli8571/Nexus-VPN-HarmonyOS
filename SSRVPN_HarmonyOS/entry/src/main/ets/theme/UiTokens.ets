/**
 * SSRVPN UI Tokens — 1:1 对齐 upstream packages/ssrvpn_shared/lib/widgets/ssrvpn_app_surface.dart
 * 这是真实安卓版使用的现代色板（app_theme.dart 为旧版兼容色，勿再使用）。
 */

/** 随系统深浅模式自动解析的语义设计令牌。 */
export class Ui {
  static readonly background: ResourceColor = $r('app.color.ui_background');
  static readonly backgroundRaised: ResourceColor = $r('app.color.ui_background_raised');
  static readonly surface: ResourceColor = $r('app.color.ui_surface');
  static readonly surfaceStrong: ResourceColor = $r('app.color.ui_surface_strong');
  static readonly surfaceTranslucent: ResourceColor = $r('app.color.ui_surface_translucent');
  /** 主页三张信息磁贴专用底色/渐变：深色主题下更实、去白纱，避免「透白」不协调 */
  static readonly tileFill: ResourceColor = $r('app.color.ui_tile_fill');
  static readonly tileGloss: ResourceColor = $r('app.color.ui_tile_gloss');
  static readonly tileDeep: ResourceColor = $r('app.color.ui_tile_deep');
  static readonly surfaceMuted: ResourceColor = $r('app.color.ui_surface_muted');
  static readonly glassHighlight: ResourceColor = $r('app.color.ui_glass_highlight');
  static readonly glassHighlightSoft: ResourceColor = $r('app.color.ui_glass_highlight_soft');
  static readonly glassEdge: ResourceColor = $r('app.color.ui_glass_edge');
  static readonly glassGlow: ResourceColor = $r('app.color.ui_glass_glow');
  static readonly inputBackground: ResourceColor = $r('app.color.ui_input_background');
  static readonly primary: ResourceColor = $r('app.color.ui_primary');
  static readonly primaryBlue: ResourceColor = $r('app.color.ui_primary_blue');
  static readonly primaryBlueFill: ResourceColor = $r('app.color.ui_primary_blue_fill');
  static readonly accent: ResourceColor = $r('app.color.ui_accent');
  static readonly success: ResourceColor = $r('app.color.ui_success');
  static readonly warning: ResourceColor = $r('app.color.ui_warning');
  static readonly error: ResourceColor = $r('app.color.ui_error');
  static readonly textPrimary: ResourceColor = $r('app.color.ui_text_primary');
  static readonly textSecondary: ResourceColor = $r('app.color.ui_text_secondary');
  static readonly textTertiary: ResourceColor = $r('app.color.ui_text_tertiary');
  static readonly textOnBrand: ResourceColor = $r('app.color.ui_text_on_brand');
  static readonly textBlue: ResourceColor = $r('app.color.ui_text_blue');
  static readonly textError: ResourceColor = $r('app.color.ui_text_error');
  static readonly textViolet: ResourceColor = $r('app.color.ui_text_violet');
  static readonly border: ResourceColor = $r('app.color.ui_border');
  static readonly borderStrong: ResourceColor = $r('app.color.ui_border_strong');
  static readonly buttonDisabled: ResourceColor = $r('app.color.ui_button_disabled');
  static readonly overlay: ResourceColor = $r('app.color.ui_overlay');
  static readonly shadow: ResourceColor = $r('app.color.ui_shadow');
  static readonly navBackground: ResourceColor = $r('app.color.ui_nav_background');
  static readonly selectedBackground: ResourceColor = $r('app.color.ui_selected_background');
  static readonly statusTint: ResourceColor = $r('app.color.ui_status_tint');
  static readonly powerGlowActive: ResourceColor = $r('app.color.ui_power_glow_active');
  static readonly powerGlowIdle: ResourceColor = $r('app.color.ui_power_glow_idle');
  static readonly powerRingActive: ResourceColor = $r('app.color.ui_power_ring_active');
  static readonly powerRingIdle: ResourceColor = $r('app.color.ui_power_ring_idle');
  static readonly powerInnerActive: ResourceColor = $r('app.color.ui_power_inner_active');
  static readonly powerInnerIdle: ResourceColor = $r('app.color.ui_power_inner_idle');

  static readonly pagePadding: number = 20;
  static readonly cardRadius: number = 24;
  static readonly dialogRadius: number = 28;
  static readonly controlRadius: number = 14;
  static readonly glassBlurRadius: number = 28;
  /** 全局液态玻璃光学参数，避免各页面出现不同的雾化、亮度和景深。 */
  static readonly glassSaturation: number = 1.26;
  static readonly glassBrightness: number = 1.06;
  /** 次级卡片与浮层使用的轻量液态玻璃参数。 */
  static readonly glassSaturationSoft: number = 1.20;
  static readonly glassBrightnessSoft: number = 1.04;
  static readonly glassControlBlurRadius: number = 18;
  static readonly glassControlSaturation: number = 1.12;
  static readonly glassControlBrightness: number = 1.03;
  static readonly glassShadowRadius: number = 30;
  static readonly glassShadowOffsetY: number = 14;
  static readonly glassPressScale: number = 0.985;
  static readonly compactBreakpoint: number = 460;
  static readonly pageMaxWidth: number = 440;
  static readonly bottomNavMaxWidth: number = 380;
  static readonly currentNodeMaxWidth: number = 320;

  /** 背景渐变由 base/dark 同名资源自动切换。 */
  static readonly backdropColors: Array<[ResourceColor, number]> = [
    [$r('app.color.ui_backdrop_start'), 0.0],
    [$r('app.color.ui_backdrop_middle'), 0.48],
    [$r('app.color.ui_backdrop_end'), 1.0]
  ];
}

/** 延迟配色与文案（对齐 ssrvpn_node_selection_node_card / current_node_card 阈值） */
export class LatencyStyle {
  static readonly TIMEOUT_MS: number = 65535;

  static isTimeout(latency: number | null): boolean {
    return latency !== null && (latency <= 0 || latency >= LatencyStyle.TIMEOUT_MS);
  }

  static color(latency: number | null): ResourceColor {
    if (latency === null) {
      return Ui.textSecondary;
    }
    if (LatencyStyle.isTimeout(latency)) {
      return Ui.error;
    }
    if (latency < 180) {
      return Ui.success;
    }
    if (latency < 350) {
      return Ui.warning;
    }
    return Ui.error;
  }

  static text(latency: number | null): string {
    if (latency === null) {
      return '--';
    }
    if (LatencyStyle.isTimeout(latency)) {
      return '超时';
    }
    return `${latency}ms`;
  }
}

/** 节点显示规整（对齐 node_display_policy.dart） */
export class NodeDisplay {
  /** 去掉开头的国旗 emoji（upstream nodeDisplayNameWithoutLeadingFlag） */
  static withoutLeadingFlag(name: string): string {
    let out = name;
    // 移除开头的 regional-indicator emoji 对与其余前导旗帜符号
    while (out.length > 0) {
      const cp = out.codePointAt(0);
      if (cp === undefined) {
        break;
      }
      const isFlag = (cp >= 0x1F1E6 && cp <= 0x1F1FF) || cp === 0x1F3F3 || cp === 0xFE0F || cp === 0x200D;
      if (!isFlag) {
        break;
      }
      out = out.substring(String.fromCodePoint(cp).length);
    }
    return out.trimStart();
  }

  /** 截断过长的节点名（upstream compactNodeDisplayName：约 24 字符 + …） */
  static compact(name: string): string {
    if (name.length <= 24) {
      return name;
    }
    return `${name.substring(0, 23)}…`;
  }
}
