# 浅色光感 + 底部毛玻璃 + 规则配置页主题（2026-10-07）

回退基线标签：`light-theme-baseline-2026-10-07`（指向 `fbe89a7`）

本轮以华为官方文档 + 本机 SDK 6.1.1(24) 真实签名为准，处理内容如下：

1. 浅色主题下切换底部 HdsTabs 页签看不到"光感动效" → 改用官方 `lightColor` 输出蓝色光效。✅ 已生效
2. 分流模式「智能 / 全局」没有同等级光感 → 曾换成官方 `SegmentButton` + 沉浸材质，**真机观感不佳已回退**。⚠️ 见第二节
3. 底部菜单栏毛玻璃透明效果（浅色 + 深色通用）→ 按官方反模式修正材质遮挡，让内容延伸进栏体下方。🔍 待真机确认
4. 规则模式配置页深浅主题颜色不统一 → 统一深色令牌色相 + 与规则页共用玻璃卡片配方。✅ 已生效

---

## 一、浅色主题页签光效（蓝色）

### 问题定位

官方参考《HdsTabs》`HdsTabsFloatingStyle.lightColor` 字段说明写明默认值：

> 页签栏光效颜色。默认值：深色模式 `#33E5E5E5`，浅色模式 `#33FFFFFF`。

`#33FFFFFF` = 20% 纯白。浅色悬浮栏本身也是浅色材质，纯白光感叠在上面几乎不可见——这正是"深色有明显光感、浅色看不见"的根因，与悬浮材质、模糊策略无关。

### 官方依据

- SDK：`@hms.hds.hdsBaseComponent.d.ets` → `HdsTabsFloatingStyle.lightColor?: ResourceColor`，`@since 6.1.0(23)`
- 文档：`document/cn/harmonyos-references/ui-design-hdstabs` → `HdsTabsFloatingStyle` 表

### 改动（`pages/MainPage.ets`）

```ts
private lightEffectColor(): ResourceColor {
  return ThemeService.isDark() ? '#33E5E5E5' : '#402563EB';
}
```

并在 `barFloatingStyle` 中新增 `lightColor: this.lightEffectColor()`。

- 浅色：`#402563EB` = Nexus 品牌蓝 `#2563EB` 同透明档位（0x40 = 25%），与浅色下不可见的 20% 纯白形成明确可见的蓝色光感。
- 深色：沿用官方默认 `#33E5E5E5`，**深色观感零变化**（真机已确认深色光感本就可见，不做无谓调整）。

### 明确没有做的事

- 没有自绘光效、没有加动画、没有加定时器。
- 没有改 `systemMaterialEffect` / `blurStrategy`：官方《设置页签栏的悬浮样式》已确认悬浮形态默认启用沉浸光感，材质与模糊策略继续交给系统按设备能力决定。
- 没有在宽屏侧边形态加 `lightColor`：`barFloatingStyle` 只在底部悬浮形态生效，侧边形态仍走 `barBackgroundBlurStyle`。

---

## 二、分流模式「智能 / 全局」接入同等级光感 —— ⚠️ 试后已回退

> **状态：已回退（提交 `63a15f1`，revert 自 `3e2e16c`）。**
> 真机观感不佳：胶囊分段按钮的材质样式在原卡片里显得突兀、与原双卡片设计语言不协调。
> 用户明确要求"很难看，回退之前的样式"，因此该项**没有保留**。
> 原始双 `Text` 胶囊 + 静态投影样式已完整恢复（HomePage.ets 与改动前逐字节一致）。

### 尝试过程（保留作技术记录）

原控件是两个 `Text` 胶囊 + `shadow` 静态投影，没有任何交互动效。

#### 为什么不自绘

官方《组件适配沉浸光感》把 `SegmentButton` / `SegmentButtonV2` 明确列为"内嵌于内容流的选择类组件"，支持交互形变（`interactive`）与点光源（`lightEffect`），且开启后**选中项背景跟随手指拖拽**。

需要注意官方《沉浸光感功耗优化》里的生效范围说明：普通容器走通用属性 `systemMaterial` 只在 Navigation 标题栏 / 横向 Tabs 底部栏生效，在主页内容区不生效——所以**不能**给现有 `Row`/`Text` 挂 `systemMaterial`，必须换成支持 `backgroundSystemMaterial` 的选择类组件。

#### 官方依据

- SDK：`@ohos.arkui.advanced.SegmentButton.d.ets`
  - `CapsuleSegmentButtonConstructionOptions.backgroundSystemMaterial?: uiMaterial.Material`，`@since 26.0.0`
  - `SegmentButton.selectedIndexes` 是 `@Link`（父子双向同步），必须绑 `@State`
  - `onItemClicked` 是 `@Event`，必须写在构造参数里，**不是**通用属性方法
  - `backgroundBorderRadius` / `itemBorderRadius` 类型是 `LengthMetrics`，不能直接写数字
- SDK：`@ohos.arkui.uiMaterial.d.ts` → `ImmersiveMaterial` / `ImmersiveStyle` / `LightEffectOptions`，均 `@since 26.0.0`
- 文档：`document/cn/harmonyos-guides/arkts-immersive-light-sense-component-adaptation`、`...-common-capability`、`...-faq`

#### 当时写法（现已删除）

```ts
SegmentButton({
  options: new SegmentButtonOptions({
    type: 'capsule',
    multiply: false,
    buttons: [{ text: '智能' }, { text: '全局' }],
    fontColor: Nx.muted(),
    selectedFontColor: Nx.fg(),
    fontSize: 11.5,
    selectedFontSize: 11.5,
    fontWeight: FontWeight.Medium,
    selectedFontWeight: FontWeight.Bold,
    backgroundBorderRadius: LengthMetrics.vp(9999),
    itemBorderRadius: LengthMetrics.vp(9999),
    backgroundSystemMaterial: new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
      interactive: true,
      lightEffect: { color: this.segLightColor() }
    })
  }),
  selectedIndexes: this.proxySegIndexes,
  onItemClicked: (index: number): void => {
    this.applyProxyMode(index === 1 ? 'global' : 'rule');
  }
}).width('100%')
```

曾配套的状态同步（已一并删除）：`@State proxySegIndexes` 与 `setProxyModeState()`，把**所有** `proxyMode` 写入口（首次加载 `bootstrap`、用户切换 `applyProxyMode`、备份恢复 `importJsonText`）收敛到一处。

#### 编译期被 ArkTS 纠正的 API 细节（仍有参考价值）

1. `onItemClicked` 是 `@Event`，写在构造参数里，不是通用属性方法（写成链式方法会报 `does not exist on type 'CommonAttribute'`）。
2. `backgroundBorderRadius` / `itemBorderRadius` 类型是 `LengthMetrics`，要用 `LengthMetrics.vp(9999)`，直接写数字报 `Type 'number' is not assignable to type 'LengthMetrics'`。
3. 材质层级位于 `backgroundColor` / `backgroundBlurStyle` 之下（官方 FAQ），开启材质处不能再叠加背景色或背景模糊，否则材质被盖住。

### 结论与后续

主页「分流模式」卡片里这套自定义双胶囊本身就是有意为之的极简设计，换成系统胶囊分段按钮后，材质光泽、边框、字重和卡片整体的轻量风格冲突，视觉上反而更重。

**若要再改善这一处**，方向应是：在不引入 SegmentButton 组件级材质的前提下，给现有 `Text` 胶囊补一层轻量的点击态过渡（如颜色/缩放微动效），并保持与规则管理卡片的同套视觉语言；具体做法需先征得认可再做。

---

## 三、底部页签栏毛玻璃透明效果（浅色 + 深色通用）

> 需求来源：用户反馈"底部菜单栏要实现毛玻璃透明效果，浅色深色都要"，参照华为音乐底部菜单栏。
> 状态：代码已改，**真机观感待确认**（需在 DevEco Run 安装后验证）。

### 真机定位到的两个根因（2026-10-07 截图实证）

1. **官方反模式被触发**。官方《组件适配沉浸光感》原文：
   > "设置悬浮材质后，不建议再通过 barBackgroundColor、barBackgroundBlurStyle
   > 为 TabBar 设置背景色或背景模糊，避免遮挡材质效果。"

   而 `MainPage.ets` 对底部悬浮形态仍然调了
   `.barBackgroundBlurStyle(BlurStyle.NONE, {...})`。即使传的是 `NONE`，
   这条通道的存在本身就在和 `systemMaterialEffect` 打架 —— 材质被自己的
   blur 通道压住，渲染出来就是一块实色圆角片。

2. **栏体下方没有内容可透**。`HomePage` / `SubscriptionPage` 滚动列底部
   `padding({ bottom: 110 })` 留出了大片空白。这意味着内容滚到底时，
   页签栏正下方是**纯色页面背景**（浅色 `#f8fafc` / 深色 `#0f172a`）。
   IMMERSIVE 材质要"透出底层内容"，而底层只有一片纯色，于是观感等同实色块。
   对照华为音乐：它的栏体下方是滚动中的专辑封面、彩色封面矩阵 —— 那才是毛玻璃能透的东西。

### 改动

**`pages/MainPage.ets`**

- 底部悬浮形态下不再调用 `barBackgroundBlurStyle`（仅宽屏侧边形态保留
  `COMPONENT_ULTRA_THICK`，因为侧边形态不存在悬浮样式，材质只能走 blur 通道）。
- `gradientMask.maskColor` 从近实底改为半透明中性色：

  ```ts
  private maskColor(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(10, 16, 32, 0.28)' : 'rgba(232, 238, 248, 0.34)';
  }
  ```

  原来浅色用 `rgba(248,250,252,0.40)` —— 这是近乎实底的白，等于在材质上
  再糊一层，把透光性彻底糊死。现在改为更低不透明度的中性色，把渐隐交给
  系统 IMMERSIVE 材质去做。

**`pages/HomePage.ets` / `pages/SubscriptionPage.ets`**

- 滚动列底部 padding `110 → 100`（= bar 64 + barBottomMargin 18 + 呼吸余量）。
  让内容真正延伸到页签栏之下，滚动时卡片进入栏体下方，材质才有可透内容。

### 维持不变的官方通道

`barFloatingStyle` 里这些是官方标准配置，**没有动**：

```ts
.barFloatingStyle({
  barWidth: { smallWidth: 320, mediumWidth: 420, largeWidth: 460 },
  barBottomMargin: 18,
  gradientMask: { maskColor: this.maskColor(), maskHeight: 92 },
  lightColor: this.lightEffectColor(),
  systemMaterialEffect: {
    materialType: hdsMaterial.MaterialType.IMMERSIVE,   // 官方 6.1.0 起
    materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE   // 官方推荐档
  }
})
```

依据：官方《UI Design Kit - 沉浸光感》指南《设置页签栏的悬浮样式》与
《HDS 组件材质效果》均以 `systemMaterialEffect(IMMERSIVE + ADAPTIVE)` +
`gradientMask` 作为悬浮页签栏的标准写法；`MaterialLevel.ADAPTIVE` 是官方
明确推荐值（"由系统根据设备性能自动选择合适的档位，推荐大多数场景使用"）。

### 待人工确认的视觉项（新增）

1. 浅色主题：底栏是否呈半透明磨砂，滚动主页时卡片能否透入栏体。
2. 深色主题：同上，且栏体不应呈灰白实色。
3. 华为音乐式观感：栏体圆角胶囊 + 透光，而非实色块。

---

## 四、规则模式配置页主题统一


### 实际入口核对

规则模式弹窗共 4 个入口（`HomePage.ets` 的 `NetworkRulesDialog`）：

| 入口 | 落地页 | 本轮处理 |
| --- | --- | --- |
| 广告与隐私拦截规则 | `RulesPage` | 用户确认已适配，保持不动 |
| 强制代理网站名单 | `SiteRoutingPage`(proxy) | 已统一 |
| 强制直连网站名单 | `SiteRoutingPage`(direct) | 已统一 |
| 应用分流策略设置 | `AppRoutingPage` | 已统一 |

即：4 个入口里 1 个已适配，另外 3 个入口对应的 **2 个页面 + 2 个「添加/导入」弹窗**全部统一。

### 根因：深色令牌色相漂移

主页用的是 `Nx`（Tailwind slate：深色画布 `#0f172a`、卡片 `#1e293b`、强调蓝 `#60a5fa`），
配置页用的是 `Ui`（`UiTokens.ets` + `color.json`）。两套体系在深色下已经漂移：

- `ui_surface_translucent` 深色 `#7A303653` 是**紫罗兰**，浅色 `#A8FFFFFF` 是中性白 → 同一张卡片在深浅主题完全是两种色相。
- `ui_surface` / `ui_surface_strong` / `ui_surface_muted` / `ui_tile_*` / `ui_nav_background` 深色同样是紫系（`#2B3150`、`#3A4164`、`#303853`、`#252B46`）。
- `ui_selected_background` 深色 `#298A84FF` 是紫色，浅色 `#1F2563EB` 是蓝色 → 选中态两套主题不同色相。
- `ui_backdrop_start` 深色 `#1E2254` 是靛紫，`ui_background` 深色 `#0A1020` 是蓝黑 → 画布与卡片不同色系。

### 改动 1：深色令牌统一到板岩蓝（`resources/dark/element/color.json`）

| 令牌 | 原值 | 新值 |
| --- | --- | --- |
| `start_window_background` | `#0A1020` | `#0F172A` |
| `ui_background` | `#0A1020` | `#0F172A` |
| `ui_background_raised` | `#14152F` | `#16213A` |
| `ui_surface` | `#8F2B3150` | `#8F1E293B` |
| `ui_surface_strong` | `#B83A4164` | `#BA1E293B` |
| `ui_surface_translucent` | `#7A303653` | `#7A1E293B` |
| `ui_surface_muted` | `#66303853` | `#661E293B` |
| `ui_tile_fill` / `ui_tile_gloss` / `ui_tile_deep` | `#8A252B46` | `#8A1E293B` |
| `ui_nav_background` | `#8A252B46` | `#8A1E293B` |
| `ui_input_background` | `#181B2A` | `#151D2B` |
| `ui_selected_background` | `#298A84FF` | `#336E9BFF` |
| `ui_backdrop_start` | `#1E2254` | `#1B2942` |
| `ui_backdrop_middle` | `#0A1020` | `#0F172A` |
| `ui_backdrop_end` | `#0A1B36` | `#0B1B2E` |

透明通道（alpha 前两位）全部保留，只改色相；`#1E293B` 与主页 `Nx.surface()` 深色值完全一致。
浅色 `color.json` 未改动——浅色配置页的问题不是色相，而是下面第 2 条（缺玻璃质感）。

### 改动 2：配置页与规则页共用同一套玻璃卡片配方

`RulesPage` 的卡片是"半透明底 + `COMPONENT_THICK` 模糊 + `backgroundEffect` + 1px `glassEdge` 描边 + 阴影"，
而两个配置页只有一层平铺的半透明底色，视觉上又扁又和规则页不是一套。

已在 `SiteRoutingPage` / `AppRoutingPage` 的说明卡、列表行、以及两个「添加/导入」弹窗容器上补齐与 `RulesPage` 完全一致的属性链（`Ui.glassBlurRadius` / `Ui.glassSaturationSoft` / `Ui.glassBrightnessSoft` / `Ui.glassEdge` / `Ui.shadow`）。

### 改动 3：操作按钮改用主题色

原先这些按钮用 ArkUI 默认系统蓝，与页面主题蓝（`Ui.primaryBlueFill`）不是同一个蓝，页面上出现两种蓝：

- `保存`（`SiteRoutingPage`）
- `＋ 添加 / 导入`、`导出名单` / `导出`
- 两个弹窗里的 `取消` / `添加到当前名单`

统一为 `.backgroundColor(Ui.primaryBlueFill).fontColor(Ui.textOnBrand)`，`取消` 用 `Ui.surfaceStrong` + `Ui.textPrimary` 做次级按钮。

### 没有动的部分

- `ui_primary`（紫）、`ui_text_violet`：节点选择、诊断、设置等页面大量使用，且深浅两档本来就同色相，本轮不动，避免牵连未反馈问题的页面。
- `ui_accent`（深色 `#20C8B4` 青）：全仓无业务引用，属于未使用令牌，不做无意义改动。
- 所有 VPN 连接逻辑、页面业务、页签数量与顺序均未改。

---

## 验证结果

### 编译

```
$env:DEVECO_SDK_HOME = 'C:\Program Files\Huawei\DevEco Studio\sdk'
$env:JAVA_HOME = 'C:\Program Files\Huawei\DevEco Studio\jbr'
node 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' `
  --mode module -p product=default -p module=entry@default `
  -p buildMode=debug assembleHap --no-daemon
```

- **BUILD SUCCESSFUL**（本轮共编译 3 次：SegmentButton 事件位置、`LengthMetrics` 类型两处均由此发现并修正）
- 产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`（29,891,756 bytes）

### 自检脚本（`Nexus_HarmonyOS/scripts`）

| 脚本 | 结果 |
| --- | --- |
| verify-vpn-architecture | PASSED |
| verify-logic-pure | ALL PURE-LOGIC CHECKS PASSED |
| verify-mihomo-alignment | 102 passed, 0 failed |
| verify-latency-cache | 61 passed, 0 failed |
| verify-latency-engine-runtime | 17 passed, 0 failed |
| verify-node-sort-persistence | 16 passed, 0 failed |
| verify-proxy-name-uniqueness | 15 passed, 0 failed |
| verify-smart-e2e | PASSED |
| verify-sub-brace-balance | PASSED |
| verify-sub-node-two-row | PASSED |
| verify-app-routing | 失败 7 项（**基线存量**） |
| verify-site-routing | 失败 1 项（**基线存量**） |
| verify-concurrent-refresh | 失败（**基线存量**） |
| verify-types | 失败（**基线存量**：tsc 直接解析 SDK 自带 `@ohos.annotation.d.ets` 报 TS1128/TS1146/TS1434，与本轮改动文件无关） |
| verify-subscription-fidelity | 0 run（**基线存量**，需外部数据） |
| verify-shipped-dns-fix | 失败（未入库的新脚本，本轮未触碰） |
| verify-smart-active-chains | SKIP（需真机抓包参数） |

**零新增失败。**

### 真机验证（MatePad mini `MLR-AL00`，HarmonyOS 7.0.0.109 / API 26）

- 设备已连接：`hdc list targets` → `192.168.10.7:39933`
- ⚠️ **本轮安装需人工完成**：命令行 hvigor 产出的 `entry-default-unsigned.hap` 未签名，`build-profile.json5` 的 `signingConfigs` 为空且注释明确「命令行 hvigor 无法使用 DevEco 加密密码串」。需在 DevEco Studio 里点 Run 走托管调试签名安装。

待人工确认的视觉项：

1. 浅色主题：底部 HdsTabs 切换主页/订阅时是否出现**蓝色**光感（此前完全不可见）。
2. 深色主题：页签光感是否与改动前一致（应无变化）。
3. 规则模式 → 强制代理 / 强制直连 / 应用分流：深色下卡片是否已从紫罗兰变为板岩蓝、与主页同色系；浅色下是否与「广告与隐私拦截规则」页观感一致。
4. 横屏（≥840vp）侧边页签形态是否正常。
5. 主页「分流模式 → 智能 / 全局」是否已恢复为原始样式（该项已 revert）。

---

## 回退方式

逐项提交（每项都能单独 revert，互不依赖）：

| # | 提交 | 内容 |
| --- | --- | --- |
| 1 | `8e79e72` | 浅色主题页签栏蓝色光感（`MainPage.ets`） |
| 2 | `3e2e16c` | ~~智能/全局原生光感（`HomePage.ets`）~~ |
| 2′ | `63a15f1` | ⚠️ **revert `3e2e16c`**：真机观感不佳，已恢复原双 `Text` 胶囊样式 |
| 3 | `cbcc2d7` | 深色令牌色相统一（`dark/element/color.json`） |
| 4 | `f27ee81` | 站点/应用分流配置页视觉统一（`SiteRoutingPage.ets`、`AppRoutingPage.ets`） |
| 5 | `2d37ae8` | 记录文档（智能/全局试后回退） |
| 6 | 本次 | 底部页签栏毛玻璃：去掉遮挡材质的 blur 通道 + 内容延伸进栏体下方（`MainPage.ets`、`HomePage.ets`、`SubscriptionPage.ets`） |

```powershell
cd C:\Users\xiaoli\Downloads\Agent-WorkerSpaces\Nexus

# 整轮回退（回到 fbe89a7）
git reset --hard light-theme-baseline-2026-10-07

# 按需逐项回退（保留其余改动与文档）
git revert f27ee81   # 只回退配置页视觉
git revert cbcc2d7   # 只回退深色令牌
git revert 8e79e72   # 只回退浅色页签光感
# 注意：3e2e16c 已被 63a15f1 反向撤销，无需（也不能）再 revert
# 毛玻璃改动同理，用其提交 hash revert 即可，不影响其他项
```
