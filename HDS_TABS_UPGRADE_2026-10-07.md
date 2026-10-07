# HdsTabs 悬浮底部页签升级记录（2026-10-07）

> 需求：用 `@kit.UIDesignKit`（UI Design Kit）的 **HdsTabs** 把底部菜单栏升级为官方悬浮页签效果；
> 并普查其他可套用该组件效果的位置（结论见文末 §7）。

## 1. 官方依据与版本门槛

- 组件：`HdsTabs`（HDS 页签容器）——**起始 6.0.0(20)**；`barFloatingStyle` 悬浮页签栏——**起始 6.1.0(23)**；
  syscap `SystemCapability.UIDesign.HDSComponent.Core`。
- 本工程基线 `compatibleSdkVersion 6.1.1(24)` ≥ 门槛 ✓；本机 SDK 同时提供 `hds_tabs` 组件声明与 `@hms.hds.*` 类型。
- 官方形态（《设置页签栏的悬浮样式》指南 + 《HdsTabs》API 参考）：
  `barPosition(BarPosition.End)` + `vertical(false)` + `barOverlap(true)` + `barFloatingStyle({...})`；
  悬浮样式下页签栏仅支持 `BottomTabBarStyle` 或 CustomBuilder 两种样式。

## 2. 架构变更（改造说明）

| 维度 | 原实现 | 新实现 |
|---|---|---|
| 主导航 | HomePage / SubscriptionPage 两个 `@Entry` 路由页 | `pages/MainPage.ets`（@Entry）承载 HdsTabs，两个页面转为 **TabContent 内容组件** |
| 切换方式 | 自制 Dock `router.replaceUrl`（整页重建） | HdsTabs 页签切换（**状态保留**，重新展示时刷新） |
| 页签栏外观 | 自制液态玻璃 Dock（backgroundBlurStyle + backgroundEffect） | `barFloatingStyle`：`systemMaterialEffect(IMMERSIVE/ADAPTIVE)` 系统材质 + `gradientMask` 底部渐隐 + 官方分档宽度/边距 |
| 页签图标 | 文本符号（⌂ / ▤） | 系统 Symbol 两态：`sys.symbol.house(_fill)` / `sys.symbol.list_bullet_square(_fill)`（已对照本机 SDK `sysResource.js` 确认资源存在） |
| onPageShow 语义 | 页面级生命周期（从子页返回刷新） | `TabLifecycleBridge`（宿主 onPageShow / 页签切换 → 通知当前页签刷新；含"迟注册补发"兜底） |

## 3. 文件清单

- 新增：`pages/MainPage.ets`、`commons/utils/TabLifecycleBridge.ets`
- 修改：`pages/HomePage.ets`、`pages/SubscriptionPage.ets`（去 @Entry / 去 pageTransition / 去 Dock / 接入桥）、
  `entryability/EntryAbility.ets`（`loadContent` → `pages/MainPage`，2 处）、
  `resources/base/profile/main_pages.json`（+MainPage，−HomePage/−SubscriptionPage）
- 停用：`components/LiquidGlassDock.ets`（**保留文件** + 顶部弃用注释，不再被引用）

## 4. 行为差异（需真机确认）

1. **页签切换不再重建页面**：两侧状态与滚动位置保留（原 replaceUrl 每次重建、滚动归零）。属预期改善；
   请确认订阅页手风琴/节点列表等对"页面常驻"假设无副作用（本次已核对：两侧监听器生命周期方法保持不变，
   LatencyController 支持多监听者，`vpn_request_seq` 消费方仅 HomePage）。
2. **外部请求更可靠**：快捷方式/卡片写入的 `vpn_request_seq` 由常驻的 HomePage 消费——
   原实现里用户在订阅页时 HomePage 已被销毁，请求要等回主页才被消费；现在即时消费。
3. 内容区底部留白仍为 110vp（原为 Dock 预留），与悬浮页签栏（`barBottomMargin: 18` + 栏高）的配合需真机看效果；
   `gradientMask.maskHeight: 92` 也是同一处可调参数。
4. 页签栏选中色为 HDS 规范色（系统蓝 `#ff007dff`），与品牌蓝 `#2563eb` 略有差异；
   如需品牌化，可评估 `SymbolGlyphModifier.fontColor` 链式调用的类型兼容性后再改（本次未动，避免引入类型风险）。

## 5. 验证

- 构建：`hvigor --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap`
  → **BUILD SUCCESSFUL**（28.7 s；产物 `entry-default-unsigned.hap` ≈ 29.87 MB，2026-10-07 11:49）。
  编译期修复 1 处：`SymbolGlyphModifier` 需显式 `import { SymbolGlyphModifier } from '@kit.ArkUI'`
  （命名空间中仅有类型声明，作为值 `new` 时必须导入）。
- 自检脚本（共 22 个，全量与升级前逐项对照）：**无新增失败**。
  - 通过：`verify-vpn-architecture` 236/236、`logic-pure` 228/228、`hot-recovery` 全过、`card-guard` 8/8、
    `verify-review-fixes` 9/9、`latency-cache` 61/61、`latency-engine-runtime` 17/17、`smart-e2e` 21/21、
    `proxy-name-uniqueness` 15/15、`node-sort-persistence` 16/16、`mihomo-alignment` 102/102、
    `yaml_compat`、`yaml_flow_parser`、`sub-node-two-row`、`sub-brace-balance`、`smart-active-chains`。
  - 既有失败（与升级前完全一致，属仓库存量断言漂移，非本次引入）：`app-routing` 7 项、`concurrent-refresh`、
    `types`、`site-routing` 1 项、`subscription_import_regressions`、`config-sanitize` 4 项。
- 残留检查：`pages/HomePage` / `pages/SubscriptionPage` 路由引用已全部清除（`loadContent` 指向 MainPage）；
  `LiquidGlassDock` 仅剩自身文件（含弃用注释）。

## 6. 回退指引

| 目标 | 命令 |
|---|---|
| 回到升级前（含全部历史） | `git switch feat/hds-tabs-2026-10-07` 然后 `git reset --hard hds-tabs-baseline-2026-10-07` |
| 只回退本次升级 | `git revert <本次提交 sha>`（一条提交覆盖全部文件，回退后即恢复两个 @Entry 页 + Dock 引用） |
| 只恢复旧 Dock 用法 | 从基线恢复两个页面文件：`git checkout hds-tabs-baseline-2026-10-07 -- Nexus_HarmonyOS/entry/src/main/ets/pages/HomePage.ets Nexus_HarmonyOS/entry/src/main/ets/pages/SubscriptionPage.ets`（并同步回 EntryAbility / main_pages.json） |

- 基线 tag：`hds-tabs-baseline-2026-10-07`（= `be905bb`，即本次升级前的完整状态）。
- `LiquidGlassDock.ets` **未删除**，回退后可直接恢复引用。

## 7. 「其他地方也能适用」普查结论

全仓扫描 Tabs/TabContent/Segment 使用面：**除主底部导航外没有其他页签语义的 UI**——
设置/规则/节点/连接等页均为推入式子页；订阅页是手风琴分组；规则页的"智能/全局"是二选开关（非页签）。
故本次仅落地主底部导航一处。后续可选的 HdsTabs 进阶能力（未启用，供后续决策）：

- **miniBar（迷你栏）**：与页签栏等高、可折叠/展开，可承载"连接状态 / 一键启停"迷你卡片（官方支持，6.1.0(23)+）；
- **侧边页签**（`vertical(true)`）：平板宽屏差异化布局；
- **HdsNavigation / HdsListItem**（同套件其他组件）：推入式子页的标题栏与列表卡片升级候选（另一个话题）。

## 8. 其他说明

- 卡片 `targetPage` 深链（widget → 订阅页）：该参数在**原实现中也从未被消费**（仅写在卡片参数里），
  未构成回归；如需"点卡片直达订阅页签"，可用 `HdsTabsController.changeIndex(1)` 做后续增强。
- 本次升级**未 push**；默认停留在 `feat/hds-tabs-2026-10-07` 分支。
