/**
 * MainPage —— 应用主容器页（HdsTabs 悬浮底部页签，UI Design Kit / @kit.UIDesignKit）
 *
 * 背景：原「主页 / 订阅」是两个 @Entry 路由页 + 自制液态玻璃 Dock（router.replaceUrl 切换）。
 * 现升级为官方 HdsTabs 根容器（《设置页签栏的悬浮样式》指南形态，起始版本 6.1.0(23)）：
 *   barPosition(End) + vertical(false) + barOverlap(true)
 *   + barFloatingStyle（系统沉浸材质 + 底部渐变蒙层 + 官方页签栏间距）。
 *
 * 与原实现的语义映射：
 *  - 原「从子页返回触发 onPageShow 刷新」→ MainPage.onPageShow 仅通知“当前页签”（经 TabLifecycleBridge）；
 *  - 原 router.replaceUrl 切页（重建页面、状态清零）→ 页签切换保留两侧状态 + 重新展示刷新；
 *  - 原自制 Dock 的玻璃材质 → HdsTabs barFloatingStyle.systemMaterialEffect(IMMERSIVE)；
 *  - 原 Dock 的圆角悬浮位置 → 官方悬浮页签栏（barBottomMargin 与原 Dock 底距对齐）。
 *
 * 图标：系统 Symbol 常态/选中两态（sys.symbol.house / list_bullet_square 及 _fill 变体，
 * 已按本机 SDK sysResource.js 实际资源名核对；颜色用 HDS 页签栏规范色，深浅自适应）。
 */
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { ThemeService } from '../theme/ThemeService';
import { TabLifecycleBridge } from '../commons/utils/TabLifecycleBridge';
import { HomePage } from './HomePage';
import { SubscriptionPage } from './SubscriptionPage';

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
  /** 跟随主题切换重渲染（与子页共用同一份主题信号） */
  @StorageLink('theme_revision') themeRevision: number = 0;

  onPageShow(): void {
    // 从推入式子页（节点 / 规则 / 设置 / 连接 / 应用分流等）返回时，
    // 让当前页签执行一次刷新（等价于原各页 onPageShow 的 bootstrap 语义）。
    this.notifyActiveTab();
  }

  private notifyActiveTab(): void {
    if (this.activeIndex === 0) {
      this.homeBridge.notifyShown();
    } else {
      this.subBridge.notifyShown();
    }
  }

  /**
   * 底部页签样式：系统 Symbol 常态/选中两态。
   * 说明：TabBarSymbol 是类（非接口），需 new 后赋值 normal/selected；
   * 字体色沿用 HDS 页签栏规范色（#66182431 / #ff007dff，深浅自适应）。
   */
  private tabStyle(normal: Resource, selected: Resource, label: string): BottomTabBarStyle {
    const symbol = new TabBarSymbol();
    symbol.normal = new SymbolGlyphModifier(normal);
    symbol.selected = new SymbolGlyphModifier(selected);
    return new BottomTabBarStyle(symbol, label);
  }

  /** 页签栏底部的内容渐隐蒙层（跟随深浅主题，宽度与页面底色一致） */
  private maskColor(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(15, 23, 42, 0.40)' : 'rgba(248, 250, 252, 0.40)';
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
    // ── 悬浮底部页签栏（官方指南形态）──
    .barPosition(BarPosition.End)
    .vertical(false)
    .barOverlap(true)
    .barFloatingStyle({
      // 与原自制 Dock 的底距（18vp）对齐；左右与宽度用官方默认分档
      barBottomMargin: 18,
      gradientMask: { maskColor: this.maskColor(), maskHeight: 92 },
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
