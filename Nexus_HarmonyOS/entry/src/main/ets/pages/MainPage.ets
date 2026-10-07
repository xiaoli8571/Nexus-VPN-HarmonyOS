/**
 * MainPage —— 应用主容器页（HdsTabs 主导航，UI Design Kit / @kit.UIDesignKit）
 *
 * 形态（官方《设置页签栏的悬浮样式》+《HdsTabs》API，本机 SDK 6.1.1(24) 全量支持）：
 *  - 手机 / 平板竖屏（< 840vp）：底部悬浮页签栏 ——
 *    barPosition(End) + vertical(false) + barOverlap(true) +
 *    barFloatingStyle（系统沉浸材质 IMMERSIVE/ADAPTIVE + 底部渐变蒙层 + 官方分档宽度）。
 *    内容自然延伸到页签栏之下，栏体悬浮、圆角胶囊、透光材质由系统渲染。
 *  - 平板 / 横屏宽屏（≥ 840vp，HarmonyOS lg 断点）：纵向侧边页签 ——
 *    vertical(true) + barPosition(Start) + barBackgroundBlurStyle(COMPONENT_ULTRA_THICK)
 *    提供系统组件级材质（非悬浮形态下 systemMaterialEffect 不可用，材质走官方 blur style 通道）。
 *  - 材质统一交给系统：blurStrategy(ADAPTIVE) 由系统按设备能力决定模糊策略；
 *    不实现任何自绘模糊、不叠加多层模糊、不引入定时器/后台任务。
 *
 * 尺寸与动效（2026-10-07 真机反馈调整）：
 *  - barWidth 分档加大（原默认贴内容宽 → 320/420/460），两个页签间距显著拉开；
 *  - barHeight(64) 加高；labelStyle 字号 12fp → 14fp；
 *  - animationDuration(240)：BottomTabBarStyle 默认切换时长为 0，显式给自然时长。
 *
 * 语义保持不变：页签数量 / 顺序、页面状态保留、展示刷新桥（TabLifecycleBridge）、
 * 外部请求消费（HomePage @Watch）与上一版一致。
 */
import { HdsTabs, HdsTabsController, hdsMaterial, BlurStrategy } from '@kit.UIDesignKit';
import { SymbolGlyphModifier, window } from '@kit.ArkUI';
import { ThemeService } from '../theme/ThemeService';
import { TabLifecycleBridge } from '../commons/utils/TabLifecycleBridge';
import { AppLogger } from '../commons/utils/AppLogger';
import { HomePage } from './HomePage';
import { SubscriptionPage } from './SubscriptionPage';

const TAG = 'MainPage';
/** 宽屏（平板/横屏）切换为侧边页签的断点（HarmonyOS lg 断点，不写死具体设备尺寸） */
const WIDE_BREAKPOINT_VP = 840;

@Entry
@Component
struct MainPage {
  /** 页签控制器（预留程序化切换：外部深链 / 自愈回跳等场景） */
  private controller: HdsTabsController = new HdsTabsController();
  /** 页签内容与宿主之间的「重新展示」桥（替代原各页 @Entry 的 onPageShow 语义） */
  private homeBridge: TabLifecycleBridge = new TabLifecycleBridge();
  private subBridge: TabLifecycleBridge = new TabLifecycleBridge();
  /** 当前页签：0=主页 1=订阅 */
  @State activeIndex: number = 0;
  /** 宽屏布局：纵向侧边页签（跟随窗口尺寸事件动态切换，旋转/分屏即时生效） */
  @State isWide: boolean = false;
  /** 跟随主题切换重渲染（与子页共用同一份主题信号） */
  @StorageLink('theme_revision') themeRevision: number = 0;
  /** 窗口尺寸监听（事件驱动，无定时器） */
  private win: window.Window | null = null;
  private sizeListener: ((size: window.Size) => void) | null = null;

  aboutToAppear(): void {
    this.initResponsive();
  }

  aboutToDisappear(): void {
    this.teardownResponsive();
  }

  onPageShow(): void {
    // 从推入式子页（节点 / 规则 / 设置 / 连接 / 应用分流等）返回时，
    // 让当前页签执行一次刷新（等价于原各页 onPageShow 的 bootstrap 语义）。
    this.notifyActiveTab();
  }

  /** 监听窗口尺寸 → 决定底部 / 侧边页签形态（事件驱动；失败静默降级为底部形态） */
  private async initResponsive(): Promise<void> {
    try {
      const win = await window.getLastWindow(getContext(this));
      this.win = win;
      this.applyWindowWidth(win.getWindowProperties().windowRect.width);
      const listener = (size: window.Size): void => {
        this.applyWindowWidth(size.width);
      };
      this.sizeListener = listener;
      win.on('windowSizeChange', listener);
    } catch (e) {
      AppLogger.warn(TAG, `responsive init failed, keep bottom tabs: ${AppLogger.errText(e)}`);
    }
  }

  private teardownResponsive(): void {
    const win = this.win;
    const listener = this.sizeListener;
    this.win = null;
    this.sizeListener = null;
    if (win !== null && listener !== null) {
      try {
        win.off('windowSizeChange', listener);
      } catch (e) {
        AppLogger.warn(TAG, `responsive teardown failed: ${AppLogger.errText(e)}`);
      }
    }
  }

  private applyWindowWidth(widthPx: number): void {
    const widthVp = px2vp(widthPx);
    const wide = widthVp >= WIDE_BREAKPOINT_VP;
    if (wide !== this.isWide) {
      this.isWide = wide;
      AppLogger.info(TAG,
        `layout mode -> ${wide ? 'side-tabs' : 'bottom-tabs'} (width=${Math.round(widthVp)}vp)`);
    }
  }

  private notifyActiveTab(): void {
    if (this.activeIndex === 0) {
      this.homeBridge.notifyShown();
    } else {
      this.subBridge.notifyShown();
    }
  }

  /**
   * 底部页签样式：系统 Symbol 常态/选中两态，标签字号放大到 14fp。
   * 注意：TabBarSymbol 仅有类型声明、运行时不存在 —— 必须以内联对象字面量传入
   * （真机实证 2026-10-07：new TabBarSymbol() 能过编译，首帧抛 ReferenceError 闪退）。
   */
  private tabStyle(normal: Resource, selected: Resource, label: string): BottomTabBarStyle {
    return new BottomTabBarStyle({
      normal: new SymbolGlyphModifier(normal),
      selected: new SymbolGlyphModifier(selected)
    }, label)
      .labelStyle({ font: { size: 14 } });
  }

  /** 页签栏底部的内容渐隐蒙层（跟随深浅主题，宽度与页面底色一致） */
  private maskColor(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(15, 23, 42, 0.40)' : 'rgba(248, 250, 252, 0.40)';
  }

  /**
   * 页签栏光效颜色（HdsTabsFloatingStyle.lightColor，6.1.0(23)+）。
   *
   * 官方默认：深色 #33E5E5E5、浅色 #33FFFFFF —— 浅色那档是 20% 纯白，
   * 落在浅色悬浮材质上几乎不可见（真机实证 2026-10-07：深色有明显光感、浅色没有）。
   * 因此浅色改用 Nexus 品牌蓝 #2563EB 同透明档位（0x40 = 25%）；
   * 深色沿用官方默认 #33E5E5E5，保持已确认可见的深色观感不变。
   */
  private lightEffectColor(): ResourceColor {
    return ThemeService.isDark() ? '#33E5E5E5' : '#402563EB';
  }

  build() {
    HdsTabs({ controller: this.controller }) {
      TabContent() {
        HomePage({ shownBridge: this.homeBridge })
      }
      .tabBar(this.tabStyle($r('sys.symbol.house'), $r('sys.symbol.house_fill'), '主页'))

      TabContent() {
        SubscriptionPage({ shownBridge: this.subBridge })
      }
      .tabBar(this.tabStyle($r('sys.symbol.list_bullet_square'),
        $r('sys.symbol.list_bullet_square_fill'), '订阅'))
    }
    .width('100%')
    .height('100%')
    // ── 形态：竖屏底部悬浮 / 宽屏纵向侧边（跟随窗口尺寸）──
    .vertical(this.isWide)
    .barPosition(this.isWide ? BarPosition.Start : BarPosition.End)
    .barOverlap(!this.isWide)
    // ── 栏体尺寸（放大：更高的栏 + 更宽的分档宽度；分档值见 barFloatingStyle.barWidth）──
    .barHeight(64)
    // ── 切换动画：BottomTabBarStyle 默认时长为 0，显式给自然、不过度的时长 ──
    .animationDuration(240)
    // ── 模糊策略交给系统（ADAPTIVE：按设备能力取舍，避免固定高成本实时模糊）──
    .blurStrategy(BlurStrategy.ADAPTIVE)
    // ── 系统组件级材质：宽屏侧边形态启用（悬浮形态走 systemMaterialEffect，避免叠层模糊）──
    .barBackgroundBlurStyle(this.isWide ? BlurStyle.COMPONENT_ULTRA_THICK : BlurStyle.NONE, {
      colorMode: ThemeColorMode.SYSTEM,
      adaptiveColor: AdaptiveColor.DEFAULT
    })
    // ── 底部悬浮页签栏（官方指南形态）：系统沉浸材质 + 底部渐变蒙层 + 加大的分档宽度 ──
    .barFloatingStyle(this.isWide ? undefined : {
      barWidth: { smallWidth: 320, mediumWidth: 420, largeWidth: 460 },
      barBottomMargin: 18,
      gradientMask: { maskColor: this.maskColor(), maskHeight: 92 },
      // 页签栏光效颜色：浅色主题默认的 #33FFFFFF 在浅色材质上看不见，改用品牌蓝
      lightColor: this.lightEffectColor(),
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      }
    })
    .onChange((index: number): void => {
      this.activeIndex = index;
      // 首次切入某页签（内容懒创建）或再次切回：等价于原路由切换后的「重新展示」刷新
      this.notifyActiveTab();
    })
  }
}
