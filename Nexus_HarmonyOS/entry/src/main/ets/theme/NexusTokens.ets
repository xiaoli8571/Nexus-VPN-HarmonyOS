/**
 * Nexus VPN 设计 Tokens —— 对齐《Nexus_VPN_超详尽开发规范文档_Ultimate.md》§2
 * 浅色 phone 底 #f8fafc / 卡片纯白 / 品牌蓝 #2563eb / 成功绿 #10b981 等。
 * 深色：画布 #0f172a / 卡片 #1e293b / 品牌亮蓝 #60a5fa。
 *
 * 深浅感知入口 Nx：读 ThemeService.isDark() 即时判断。
 * 调用方页面持有 @StorageLink('theme_revision')，切换主题即重渲染，子组件随父重建。
 */
import { ThemeService } from './ThemeService';

export class NexusColors {
  static readonly phoneBg: ResourceColor = '#f8fafc';
  static readonly surface: ResourceColor = '#ffffff';
  static readonly fg: ResourceColor = '#0f172a';
  static readonly fgSoft: ResourceColor = '#f1f5f9';
  static readonly muted: ResourceColor = '#64748b';
  static readonly faint: ResourceColor = '#94a3b8';
  static readonly border: ResourceColor = '#e2e8f0';
  static readonly accent: ResourceColor = '#2563eb';
  static readonly accentSoft: ResourceColor = 'rgba(37, 99, 235, 0.12)';
  static readonly accentBg: ResourceColor = '#eff6ff';
  static readonly success: ResourceColor = '#10b981';
  static readonly successSoft: ResourceColor = 'rgba(16, 185, 129, 0.12)';
  static readonly warning: ResourceColor = '#f59e0b';
  static readonly danger: ResourceColor = '#ef4444';
  static readonly darkText: ResourceColor = '#334155';
}

/** 深浅感知色板（方法调用形式：Nx.bg()） */
export class Nx {
  static bg(): ResourceColor {
    return ThemeService.isDark() ? '#0f172a' : '#f8fafc';
  }

  static surface(): ResourceColor {
    return ThemeService.isDark() ? '#1e293b' : '#ffffff';
  }

  static fg(): ResourceColor {
    return ThemeService.isDark() ? '#f8fafc' : '#0f172a';
  }

  static fgSoft(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(148, 163, 184, 0.16)' : '#f1f5f9';
  }

  static muted(): ResourceColor {
    return ThemeService.isDark() ? '#94a3b8' : '#64748b';
  }

  static faint(): ResourceColor {
    return ThemeService.isDark() ? '#64748b' : '#94a3b8';
  }

  static border(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(148, 163, 184, 0.25)' : '#e2e8f0';
  }

  static accent(): ResourceColor {
    return ThemeService.isDark() ? '#60a5fa' : '#2563eb';
  }

  static accentSoft(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(96, 165, 250, 0.16)' : 'rgba(37, 99, 235, 0.12)';
  }

  static accentBg(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(96, 165, 250, 0.16)' : '#eff6ff';
  }

  static accentEdge(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(96, 165, 250, 0.30)' : 'rgba(37, 99, 235, 0.20)';
  }

  static success(): ResourceColor {
    return '#10b981';
  }

  static successSoft(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(16, 185, 129, 0.18)' : 'rgba(16, 185, 129, 0.12)';
  }

  static warning(): ResourceColor {
    return '#f59e0b';
  }

  static danger(): ResourceColor {
    return '#ef4444';
  }

  static darkText(): ResourceColor {
    return ThemeService.isDark() ? '#e2e8f0' : '#334155';
  }

  /** 状态环中层圆盘 */
  static disc(): ResourceColor {
    return ThemeService.isDark() ? '#1e293b' : '#ffffff';
  }

  static discBorder(connected: boolean): ResourceColor {
    if (connected) {
      return 'rgba(16, 185, 129, 0.45)';
    }
    return ThemeService.isDark() ? 'rgba(148, 163, 184, 0.35)' : 'rgba(226, 232, 240, 0.90)';
  }

  /** 图标底圈 */
  static iconBg(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(148, 163, 184, 0.18)' : '#f1f5f9';
  }

  /** 输入框底 */
  static inputBg(): ResourceColor {
    return ThemeService.isDark() ? '#0f172a' : '#ffffff';
  }

  /** Dock 基底/渐变罩/高光边/非激活文案 */
  static dockBase(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(15, 23, 42, 0.55)' : 'rgba(255, 255, 255, 0.45)';
  }

  static dockGradA(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(30, 41, 59, 0.55)' : 'rgba(255, 255, 255, 0.55)';
  }

  static dockGradB(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(30, 41, 59, 0.30)' : 'rgba(255, 255, 255, 0.28)';
  }

  static dockEdgeTop(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(255, 255, 255, 0.25)' : '#ffffff';
  }

  static dockHi(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(255, 255, 255, 0.18)' : 'rgba(255, 255, 255, 0.50)';
  }

  static tabActive(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(30, 41, 59, 0.92)' : 'rgba(255, 255, 255, 0.92)';
  }

  static tabInactive(): ResourceColor {
    return ThemeService.isDark() ? '#94a3b8' : '#475569';
  }

  /** 速率面积（未连接）：浅蓝罩 / 深亮蓝罩 */
  static areaBlue(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(96, 165, 250, 0.12)' : 'rgba(37, 99, 235, 0.08)';
  }

  /** 单选框未选中描边 */
  static radioEdge(): ResourceColor {
    return ThemeService.isDark() ? '#475569' : '#cbd5e1';
  }
}

export class NexusSizes {
  static readonly ringDiameter: number = 172;
  static readonly ringInnerInset: number = 12;
  static readonly ringIconBox: number = 36;
  static readonly cardRadius: number = 14;
  static readonly rateChartW: number = 340;
  static readonly rateChartH: number = 52;
  static readonly rateBaseY: number = 46;
  static readonly rateAmpY: number = 36;
  static readonly ratePoints: number = 26;
}

/** 延迟配色（对标主流客户端：<300ms 绿 / 300~800ms 橙 / ≥800ms 红，超时红） */
export class NexusPing {
  static color(pingMs: number | null): ResourceColor {
    if (pingMs === null || pingMs === undefined) {
      return Nx.muted();
    }
    if (pingMs <= 0 || pingMs >= 65535) {
      return Nx.danger();
    }
    if (pingMs < 300) {
      return Nx.success();
    }
    if (pingMs < 800) {
      return Nx.warning();
    }
    return Nx.danger();
  }

  static text(pingMs: number | null): string {
    if (pingMs === null || pingMs === undefined) {
      return '--';
    }
    if (pingMs <= 0 || pingMs >= 65535) {
      return '超时';
    }
    return `${pingMs} ms`;
  }
}
