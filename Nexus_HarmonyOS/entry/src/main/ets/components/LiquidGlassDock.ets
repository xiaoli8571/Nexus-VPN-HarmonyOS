/**
 * Nexus 纯净液态玻璃底部 Dock —— 对齐开发文档 §8
 * 官方做法（SDK common.d.ts）：backgroundBlurStyle(COMPONENT_* 材料)
 * + backgroundEffect({radius, saturation, brightness}) 实时高斯模糊与饱和度增益。
 * 材料跟随系统深浅（SYSTEM），叠加半透明白渐变 + 顶部受光高光边 + 表面漫反射高光层。
 */
import { router } from '@kit.ArkUI';
import { Nx } from '../theme/NexusTokens';

@Component
export struct LiquidGlassDock {
  @Prop currentTab: string = 'home';

  private goHome(): void {
    if (this.currentTab !== 'home') {
      router.replaceUrl({ url: 'pages/HomePage' });
    }
  }

  private goSub(): void {
    if (this.currentTab !== 'subscription') {
      router.replaceUrl({ url: 'pages/SubscriptionPage' });
    }
  }

  @Builder
  private TabItem(active: boolean, icon: string, label: string, onTap: () => void) {
    Row({ space: 8 }) {
      Text(icon).fontSize(18).fontColor(active ? Nx.accent() : Nx.tabInactive())
      Text(label)
        .fontSize(14)
        .fontWeight(active ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(active ? Nx.accent() : Nx.tabInactive())
    }
    .justifyContent(FlexAlign.Center)
    .layoutWeight(1)
    .constraintSize({ minHeight: 42 })
    .backgroundColor(Color.Transparent)
    .onClick(() => onTap())
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      // 玻璃表面漫反射高光（顶部渐隐，不拦截点击）
      Column()
        .width('100%')
        .height(30)
        .borderRadius(9999)
        .linearGradient({ angle: 180, colors: [[Nx.dockHi(), 0.0], ['rgba(255, 255, 255, 0.0)', 1.0]] })
        .hitTestBehavior(HitTestMode.None)
      // 双 Tab
      Row({ space: 6 }) {
        this.TabItem(this.currentTab === 'home', '⌂', '主页', () => this.goHome())
        this.TabItem(this.currentTab === 'subscription', '▤', '订阅', () => this.goSub())
      }
      .width('100%')
      .padding(5)
    }
    .width('100%')
    .borderRadius(9999)
    // 1. 系统材质底色（半透明，跟随深浅）
    .backgroundColor(Nx.dockBase())
    // 2. 官方材质模糊（组件级厚材质）
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
      colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
    })
    // 3. 实时高斯模糊 + 饱和度增益（文档 §8：blur 24 / saturate 180%）
    .backgroundEffect({ radius: 24, saturation: 1.8, brightness: 1.0 })
    // 4. 通透水感渐变罩（降低不透明度，透出后方模糊）
    .linearGradient({
      angle: 135,
      colors: [[Nx.dockGradA(), 0.0], [Nx.dockGradB(), 1.0]]
    })
    // 5. 晶体受光锐边（顶边高光锐利，底边柔折射）
    .borderWidth({ top: 1.5, left: 1.0, right: 1.0, bottom: 1.0 })
    .borderColor({
      top: Nx.dockEdgeTop(),
      left: 'rgba(255, 255, 255, 0.90)',
      right: 'rgba(255, 255, 255, 0.90)',
      bottom: 'rgba(255, 255, 255, 0.50)'
    })
    .shadow({ radius: 20, color: 'rgba(15, 23, 42, 0.08)', offsetY: 8 })
    .clip(true)
  }
}
