/**
 * 节点选择页 — 对齐 upstream SsrvpnNodeSelectionPage + _NodeSelectionCard
 * 顶栏(返回/标题/测全部) + 订阅筛选 chips + 节点卡列表（旗帜/名称/延迟按钮/选中勾）。
 *
 * 测速唯一入口是 `LatencyEngine`：已连接时复用隧道 controller，未连接时由编排器的
 * `ensureLatencyApi()` 提供进程内无头内核；两者都不可用时引擎自己退化为**明确标注**
 * 的离线粗略通道（状态 OFFLINE，显示 `≈123ms`），绝不把通道故障写成节点超时。
 * 页面不再自己拉起第二个内核、不再自己开并发 lane、不再维护 URL 降级与看门狗
 * （旧实现真机表现为慢、成批假超时，以及"点了测速像没反应"）。
 */
import { router, promptAction } from '@kit.ArkUI';
import { Ui, LatencyStyle, NodeDisplay } from '../theme/UiTokens';
import { SubscriptionService } from '../commons/services/SubscriptionService';
import { Subscription } from '../commons/models/Subscription';
import { SettingsService } from '../commons/services/SettingsService';
import { AppSettings, AutoSelectModes } from '../commons/models/AppSettings';
import { ProxyNode, ProxyNodeType } from '../commons/models/ProxyNode';
import { ClashConfigGenerator } from '../commons/services/ClashConfigGenerator';
import { ProxyGroup } from '../commons/models/ProxyGroup';
import { LatencyController } from '../commons/services/LatencyController';
import { ClashApiService, LatencyFailKind } from '../commons/services/ClashApiService';
import { ConnectionOrchestrator, ConnState } from '../commons/services/ConnectionOrchestrator';
import { LatencyChannel, LatencyRecord, LatencyState } from '../commons/services/LatencyState';
import {
  LATENCY_TEST_URL, LATENCY_TIMEOUT_MS, LatencyEngine, LatencyProgress, LatencyRun,
  LatencyRunOptions, GROUP_TEST_TIMEOUT_MS
} from '../commons/services/LatencyEngine';
import { NodeCountryPolicy } from '../commons/services/PublicIpService';
import { AppLogger } from '../commons/utils/AppLogger';
import {
  NodeSortSnapshot, NodeSortModes, NodeLatencyRecord, NodeProtocolPolicy
} from '../commons/services/NodeSortPersistence';
import { NodeCandidate, scoreOf } from '../commons/services/SmartSelector';
import { CountryFlagIcon } from '../widgets/CountryFlagIcon';
import {
  ConcurrentRefresh, RefreshBatchProgress, RefreshItemOutcome
} from '../commons/services/ConcurrentRefresh';

const TAG = 'NodeSelectionPage';

/** 合成行的稳定 id（不是真实节点，仅用于列表 key 与识别选中态） */
const SMART_ROW_ID = '__smart_group__';

interface NodeRow {
  node: ProxyNode;
  countryCode: string;
  /** 综合评分/状态（来自持久化测速快照；无数据时 hasData=false） */
  status: NodeStatusView;
  /**
   * 合成行标记：内核 smart 组入口（♻️ 自动选择）。
   * 不是真实节点 —— 禁止测速、禁止长按删除、禁止参与排序。
   */
  isSmart?: boolean;
}

/** 页面临时代理组视图。策略组与普通节点同级展示，不再维护二级展开层级。 */
interface ProxyGroupRow {
  group: ProxyGroup;
  /** 展平的全部有效节点（组卡计数与兜底展示用） */
  nodes: NodeRow[];
  /** 直接挂在本组下的普通节点成员（不递归） */
  memberNodes: NodeRow[];
  /** 直接引用的 url-test、fallback、load-balance 等可选策略组。 */
  strategyGroups: ProxyGroup[];
}

/**
 * 节点状态视图（第三轮 UI）：由持久化快照派生，纯展示用。
 *  - hasData: 快照中存在该节点且非「未测」
 *  - rateLabel: 近期成功率文本，如 "100%"
 *  - failCount: 连续失败次数
 *  - score: SmartSelector 综合评分（越小越好，ms 等价）
 */
class NodeStatusView {
  hasData: boolean = false;
  rateLabel: string = '';
  failCount: number = 0;
  score: number = 0;
}

/** 订阅筛选 chip 数据（按 id 过滤，避免同名订阅互相覆盖） */
interface SubChip {
  id: string;
  name: string;
}

/** 长按节点后的删除确认对话框；与网站规则编辑无关。 */
@CustomDialog
struct NodeDeleteDialog {
  controller?: CustomDialogController;
  getNodeName: () => string = (): string => '';
  onConfirm: () => void = () => {};

  build() {
    Column({ space: 14 }) {
      Text('删除节点').fontSize(17).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
      Text(`确定删除「${this.getNodeName()}」吗？该节点在订阅刷新后不会再出现。`)
        .fontSize(13).fontColor(Ui.textSecondary)
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1).backgroundColor(Ui.surfaceTranslucent).fontColor(Ui.textSecondary)
          .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
            colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
          })
          .backgroundEffect({ radius: Ui.glassControlBlurRadius, saturation: Ui.glassControlSaturation, brightness: Ui.glassControlBrightness })
          .borderWidth(1).borderColor(Ui.glassEdge)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
        Button('删除')
          .layoutWeight(1).backgroundColor(Ui.error).fontColor(Color.White)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
            this.onConfirm();
          })
      }
      .width('100%')
    }
    .padding(22)
    .borderRadius(20)
    .backgroundColor(Ui.surfaceTranslucent)
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
      colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
    })
    .backgroundEffect({ radius: Ui.glassBlurRadius, saturation: Ui.glassSaturationSoft, brightness: Ui.glassBrightnessSoft })
    .borderWidth(1)
    .borderColor(Ui.glassEdge)
    .shadow({ radius: 28, color: Ui.shadow, offsetY: 12 })
  }
}

@Entry
@Component
struct NodeSelectionPage {
  @State nodes: NodeRow[] = [];
  @State groupRows: ProxyGroupRow[] = [];
  @State expandedGroupKeys: string[] = [];
  @State filterSubId: string = ''; // '' = 全部
  /**
   * 「自动选择」视图开关。
   *
   * 刻意**不复用 filterSubId**：后者是订阅 id，语义是"筛出某个订阅的节点"；
   * 自动选择是跨订阅的内核选点视图，混进同一状态会让 rebuildRows 的过滤分支
   * 把合成行按 subscriptionId 误判。两者互斥，切换时互相清空。
   */
  @State smartView: boolean = false;
  /** 内核当前实际在用的出口节点（来自 /connections 的 chains） */
  @State smartActiveNodes: string[] = [];
  /** 上次拉取是否通道故障（区别于"确实没有活动连接"） */
  @State smartChannelDown: boolean = false;
  private listScroller: Scroller = new Scroller();
  @State subChips: SubChip[] = [];
  @State selectedName: string = '';
  @State testingName: string = '';
  @State batchTesting: boolean = false;
  /**
   * 本轮测速进度（顶栏进度条直接绑定）。
   * 进度只有引擎是唯一来源：页面自己不再统计成功/失败，避免"UI 数字与结论不一致"。
   */
  @State latencyTotal: number = 0;
  @State latencyDone: number = 0;
  /** 本轮实际使用的通道（core / offline）；用于在顶栏标注「离线粗略」 */
  @State latencyChannelLabel: string = '';
  /** 本轮因通道（内核/凭证）不可用而中止：结果不能当节点结论，也不能落盘 */
  @State latencyCoreUnavailable: boolean = false;
  /**
   * 本轮是否被取消（用户点取消 / 页面退出）。
   * 引擎的 LatencyProgress 只统计「取消时正好在探测的节点」，无法回答"这一批是否
   * 被取消"，所以取消动作在这里记账：被取消的批次不是完整结论 → 不落盘、不弹完成 toast。
   */
  private batchCancelled: boolean = false;
  /** 组测速的 api 引用（供「取消」abort 组测请求） */
  private groupTestApi: ClashApiService | null = null;
  /** 排序模式: default 订阅顺序 / auto 按持久化的最近测速结果 / manual 手动固定顺序。
   *  进页面时由 AppSettings.nodeSortMode + nodeSortSnapshot 恢复，测速完成后落盘。 */
  @State sortMode: string = NodeSortModes.DEFAULT;
  /** 最近一次测速快照（内存镜像，随设置持久化） */
  private sortSnapshot: NodeSortSnapshot | null = null;
  /** 长按删除节点目标 */
  @State deleteTargetName: string = '';
  private deleteTargetId: string = '';
  private deleteNodeDialog: CustomDialogController = new CustomDialogController({
    builder: NodeDeleteDialog({
      getNodeName: (): string => this.deleteTargetName,
      onConfirm: () => {
        this.doDeleteNode();
      }
    }),
    autoCancel: true
  });
  @State refreshing: boolean = false;
  /** 刷新批次进度：顶栏刷新图标上直接显示 done/total（边到边刷 UI） */
  @State refreshTotal: number = 0;
  @State refreshDone: number = 0;
  @State refreshOk: number = 0;
  @State refreshFail: number = 0;
  @State isConnected: boolean = false;

  @State latencyTick: number = 0;
  /** 固定监听器实例，避免每次返回节点页都追加匿名监听，造成重复刷新和页面卡顿。 */
  private readonly latencyListener: () => void = (): void => {
    this.latencyTick = this.latencyTick + 1;
    // 边测边排序：AUTO 排序下，每合并一批新延迟就把可见列表按当前延迟重排一次，
    // 用户实时看到节点「冒泡」到前面，而不是等整批测完才一次性排。
    // 通知已由 LatencyController 合并到 ≤200ms/次，重排成本 O(N log N) 可忽略。
    if (this.batchTesting && this.sortMode === NodeSortModes.AUTO) {
      this.resortLiveByLatency();
    }
  };
  private latencyListenerBound: boolean = false;
  /** 页面切入时先完成首帧绘制，再启动设置/订阅加载，避免初始化与转场争抢 UI 线程。 */
  private pageActive: boolean = false;
  /** 自动选点模式（'manual' 手动固定 / 'auto' 自动最优），进页面从持久化读取 */
  @State autoSelectMode: string = AutoSelectModes.MANUAL;
  private subs: SubscriptionService = SubscriptionService.instance();
  private settings: AppSettings = new AppSettings();
  private orchestrator: ConnectionOrchestrator = ConnectionOrchestrator.instance();

  onPageShow(): void {
    this.pageActive = true;
    setTimeout(() => {
      if (this.pageActive) {
        this.bootstrap();
      }
    }, 32);
  }

  /**
   * 离开节点页：取消在途测速并摘掉监听器。
   *
   * 取消只是把结果标成 CANCELLED 并 destroy 掉客户端在途 HTTP —— mihomo 的
   * /delay 用 context.Background()，abort **不会**让内核停止拨号，所以真正限制
   * 负载的是引擎的并发上限，不是这里。已经落地的结果保持可见（不回滚）。
   * 不再需要「宽限回收测速内核」：内核生命周期完全归编排器（隧道或进程内无头内核），
   * 页面不再自己持有第二个内核。
   */
  onPageHide(): void {
    this.pageActive = false;
    this.batchCancelled = true;
    LatencyEngine.cancelCurrent();
    this.batchTesting = false;
    this.testingName = '';
    // 轮询只在视图可见期间存在，离开必须停 —— 否则页面退到后台还在每 3s 打内核 API
    this.stopSmartPoll();
    if (this.latencyListenerBound) {
      LatencyController.removeListener(this.latencyListener);
      this.latencyListenerBound = false;
    }
  }

  /** 重建订阅筛选项，并在 direct 变空或订阅被删除时回退到“全部”。 */
  private refreshSubChips(): void {
    const chips: SubChip[] = [];
    for (const sub of this.subs.subscriptions) {
      if (sub.id === 'direct' && sub.nodeCount <= 0) {
        continue;
      }
      chips.push({ id: sub.id, name: sub.name });
    }
    this.subChips = chips;
    if (this.filterSubId.length > 0
      && !chips.some((chip: SubChip) => chip.id === this.filterSubId)) {
      this.filterSubId = '';
    }
  }

  private async bootstrap(): Promise<void> {
    const ctx = getContext(this) as Context;
    this.orchestrator.init(ctx);
    await SettingsService.init(ctx);
    const apiSecret = await SettingsService.getApiSecret();
    // 不能无条件覆盖 endpoint：无头测速内核与真实隧道共用 9090 端口但 secret 不同，
    // 覆盖会让内核侧所有请求返回 401 → 全显失败，且不重启应用就一直错。
    // 编排器只在「没有其它内核在服务」时才写入真实凭证。
    await this.orchestrator.applyRealTunnelEndpoint(apiSecret);
    await this.subs.init(ctx);
    this.settings = await SettingsService.load();
    this.autoSelectMode = AutoSelectModes.normalize(this.settings.autoSelectMode);
    this.restoreSortState();
    this.isConnected = this.orchestrator.state === ConnState.CONNECTED;
    this.selectedName = this.settings.preferredNodeId.length > 0 && this.subs.findNode(this.settings.preferredNodeId) !== null
      ? this.subs.findNode(this.settings.preferredNodeId)!.name
      : (this.subs.nodes.length > 0 ? this.subs.nodes[0].name : '');
    // 异步初始化完成后统一重建筛选项，隐藏空 direct 并清理失效筛选。
    this.refreshSubChips();
    // 进入页面自动定位到**当前出口节点**所属订阅并展开分组（用户要求）：
    //  - 手动模式：preferredNodeId 固定的节点；
    //  - 自动模式（内核 smart 组）：smartActiveNodes（/connections 里实际在用的
    //    出口节点，bootstrap 时 smartActiveNodes 还没拉取，先把分组定位好，
    //    refreshSmartActive 拉到出口节点后再补滚动）。
    // 定位到分组后**自动展开**该分组——用户不必再手动展开看具体节点。
    if (this.filterSubId.length === 0 && this.autoSelectMode !== AutoSelectModes.AUTO
      && this.settings.preferredNodeId.length > 0) {
      const cur = this.subs.findNode(this.settings.preferredNodeId);
      if (cur !== null && cur.subscriptionId.length > 0 && cur.subscriptionId !== 'direct'
        && this.subs.subscriptions.some((s: Subscription) => s.id === cur.subscriptionId)) {
        this.filterSubId = cur.subscriptionId;
        this.rebuildRows();
        this.expandAndScrollToNode(cur.name);
      }
    }
    this.rebuildRows();
    // 定位到当前选中节点行（等 nodes 状态驱动的 List 完成构建再滚动）
    const selectedIndex = this.nodes.findIndex((r) => r.node.name === this.selectedName);
    if (selectedIndex > 0) {
      setTimeout(() => {
        this.listScroller.scrollToIndex(selectedIndex, true);
      }, 350);
    }
    if (!this.latencyListenerBound) {
      LatencyController.addListener(this.latencyListener);
      this.latencyListenerBound = true;
    }
    // 进页面不再自动测速（用户要求）：只有用户主动点「测全部」或单节点测速才运行。
  }

  /**
   * 由持久化测速快照派生单个节点的综合评分与状态（纯展示，不改任何持久化）。
   * 成功率沿用 NodeLatencyRecord.recentSuccessRate() 语义；评分复用 SmartSelector.scoreOf。
   * 「冷却中」= 近期已失败且连续失败次数达到「故障切换阈值」（该节点会被自动选点视为失效）。
   */
  private statusFor(name: string): NodeStatusView {
    const st = new NodeStatusView();
    const snap = this.sortSnapshot;
    if (snap === null) {
      return st;
    }
    const rec = snap.recordFor(name);
    if (rec === null || rec.latency === -2) {
      return st;
    }
    st.hasData = true;
    st.failCount = rec.failCount;
    const rate = rec.recentSuccessRate();
    st.rateLabel = rate < 0 ? '--' : `${Math.round(rate * 100)}%`;
    const cand = NodeCandidate.fromStats(name, rec.latency, rec.failCount, rec.lastOk, 0, 0);
    st.score = Math.round(scoreOf(cand, Date.now()));
    return st;
  }

  private rebuildRows(): void {
    const rows: NodeRow[] = [];
    const activeNames: string[] = [];
    for (const n of this.subs.nodes) {
      activeNames.push(n.name);
      if (this.filterSubId.length > 0 && n.subscriptionId !== this.filterSubId) {
        continue;
      }
      const row: NodeRow = {
        node: n,
        countryCode: NodeCountryPolicy.detect(n.name).code,
        status: this.statusFor(n.name)
      };
      rows.push(row);
    }
    LatencyController.retainOnly(activeNames);

    // ── 自动选择视图 ────────────────────────────────────────────────
    // 显示内核**当前实际在用**的出口节点（来自 /connections 的 chains）。
    // 置顶排序：最近有流量的排前面 —— 用户要的是"现在走哪个"，不是全量列表。
    if (this.smartView) {
      const byName = new Map<string, NodeRow>();
      for (const r of rows) {
        byName.set(r.node.name, r);
      }
      const picked: NodeRow[] = [];
      for (const name of this.smartActiveNodes) {
        const r = byName.get(name);
        if (r !== undefined) {
          picked.push(r);
        }
      }
      this.groupRows = [];
      this.nodes = picked;
      return;
    }

    // ── 内核 smart 组入口（♻️ 自动选择）───────────────────────────────
    // 该组只存在于**内核配置**里，不在订阅里，所以默认「全部节点」列表看不到它。
    // 这里补一个合成行。所有过滤条件都必须显式处理「合成行」：
    // 走 filterSubId 分支时无法反查 subscriptionId，直接不展示，避免归属错误。
    if (this.smartSelectable() && this.filterSubId.length === 0) {
      rows.unshift(this.mkSmartRow());
    }
    const groupRows: ProxyGroupRow[] = [];
    if (this.filterSubId.length > 0) {
      for (const group of this.subs.groupsOf(this.filterSubId)) {
        const groupNodes: NodeRow[] = [];
        for (const node of this.subs.expandProxyGroup(group)) {
          groupNodes.push(this.mkNodeRow(node));
        }
        // Selector 的直接成员保持订阅声明顺序。策略组与普通节点作为同级选项展示。
        const members = this.subs.groupMembersOf(group);
        const memberNodes: NodeRow[] = [];
        for (const node of members.nodes) {
          memberNodes.push(this.mkNodeRow(node));
        }
        groupRows.push({ group: group, nodes: groupNodes,
          memberNodes: memberNodes, strategyGroups: members.groups.slice() });
      }
    }
    this.groupRows = groupRows;
    const validGroupKeys = new Set<string>();
    for (const row of groupRows) {
      validGroupKeys.add(row.group.subscriptionId + '\u0000' + row.group.name);
    }
    this.expandedGroupKeys = this.expandedGroupKeys.filter((key: string) => validGroupKeys.has(key));
    // 合成行不参与测速排序（它没有延迟），单独摘出来最后固定置顶。
    const smartRow: NodeRow | undefined =
      (rows.length > 0 && rows[0].isSmart === true) ? rows[0] : undefined;
    const sortable: NodeRow[] = smartRow !== undefined ? rows.slice(1) : rows;

    // 排序：按持久化的测速快照恢复顺序（auto/manual），无数据则保持订阅原始顺序
    let ordered: NodeRow[] = sortable;
    if (this.sortMode !== NodeSortModes.DEFAULT) {
      const snap = this.sortSnapshot;
      if (snap !== null) {
        const names: string[] = [];
        for (const r of sortable) {
          names.push(r.node.name);
        }
        const order = snap.orderedNames(names);
        if (order.length > 0) {
          const byName = new Map<string, NodeRow>();
          for (const r of sortable) {
            byName.set(r.node.name, r);
          }
          const reordered: NodeRow[] = [];
          for (const name of order) {
            const r = byName.get(name);
            if (r !== undefined) {
              reordered.push(r);
            }
          }
          ordered = reordered;
        }
      }
    }
    this.nodes = smartRow !== undefined ? [smartRow].concat(ordered) : ordered;
  }

  /** 内核 smart 组入口当前是否应展示（模型就绪即展示，与 autoSelectMode 无关） */
  private smartSelectable(): boolean {
    try {
      return this.orchestrator.ensureSmartModelReady();
    } catch (e) {
      return false;
    }
  }

  /** 当前是否正走内核自动选点（自动模式 + 模型就绪） */
  private smartEngaged(): boolean {
    return this.settings.autoSelectMode === AutoSelectModes.AUTO && this.smartSelectable();
  }

  /** 订阅里的真实节点名（用于从 chains 里认出出口节点） */
  private knownNodeNames(): string[] {
    const out: string[] = [];
    for (const n of this.subs.nodes) {
      out.push(n.name);
    }
    return out;
  }

  /**
   * 拉取内核当前实际在用的出口节点。
   *
   * 只做一次请求、不重试：这是「显示当前选中」的辅助信息，失败时保留上一次结果
   * 并标记通道异常，绝不能因为它失败就去清空列表或弹错误。
   */
  private async refreshSmartActive(): Promise<void> {
    if (!this.smartEngaged()) {
      this.smartActiveNodes = [];
      this.smartChannelDown = false;
      this.rebuildRows();
      return;
    }
    const used: string[] | null = await this.orchestrator.api.smartActiveNodes(
      ClashConfigGenerator.SMART_GROUP_NAME, this.knownNodeNames());
    if (used === null) {
      this.smartChannelDown = true;
      this.rebuildRows();
      return;
    }
    this.smartChannelDown = false;
    this.smartActiveNodes = used;
    // **必须重建行**：UI 渲染的是 this.nodes，不是 smartActiveNodes。
    // 漏掉这一步会让状态更新了但列表永远是空的（真机表现：自动选择分组一直没节点）。
    // enterSmartView() 里那次 rebuildRows 发生在异步拉取之前，拿到的还是空数组。
    this.rebuildRows();
    // 自动模式：定位到**实际出口节点**所属订阅并展开分组（用户要求）
    if (this.filterSubId.length === 0 && used.length > 0) {
      const display = used[0];
      const cur = this.subs.nodes.find((n: ProxyNode) => n.name === display) ?? null;
      if (cur !== null && cur.subscriptionId.length > 0 && cur.subscriptionId !== 'direct'
        && this.subs.subscriptions.some((s: Subscription) => s.id === cur.subscriptionId)) {
        this.filterSubId = cur.subscriptionId;
        this.rebuildRows();
      }
      this.expandAndScrollToNode(display);
    }
  }

  /**
   * 定位到 nodeName 所属的订阅分组（filterSubId），并把该分组**自动展开**，
   * 最后滚动到该节点行——用户不必再手动展开分组找节点。
   * 节点不在任何分组时只定位订阅、不展开。
   */
  private expandAndScrollToNode(nodeName: string): void {
    if (nodeName.length === 0) {
      return;
    }
    for (const group of this.subs.groupsOf(this.filterSubId)) {
      const members = this.subs.groupMembersOf(group);
      const inMembers = members.nodes.some((n: ProxyNode) => n.name === nodeName);
      const inExpanded = this.subs.expandProxyGroup(group).some((n: ProxyNode) => n.name === nodeName);
      if (inMembers || inExpanded) {
        const key = this.groupKey(group);
        if (!this.expandedGroupKeys.includes(key)) {
          this.expandedGroupKeys = this.expandedGroupKeys.concat([key]);
        }
        this.rebuildRows();
        break;
      }
    }
    const idx = this.nodes.findIndex((r: NodeRow) => r.node.name === nodeName);
    if (idx > 0) {
      setTimeout(() => {
        this.listScroller.scrollToIndex(idx, true);
      }, 350);
    }
  }

  /**
   * 自动选择视图的空状态文案。
   *
   * 必须区分「手动模式所以压根没在自动选点」与「自动模式但暂时没流量」——
   * 两者都表现为空列表，但原因和下一步动作完全不同。混为一谈会让用户
   * 以为是功能坏了（这正是本轮之前的实际体验）。
   */
  private smartEmptyTitle(): string {
    if (!this.smartView) {
      return '暂无可用节点';
    }
    if (!this.smartEngaged()) {
      return '尚未启用自动选择';
    }
    if (this.smartChannelDown) {
      return '内核未连接';
    }
    return '当前没有活动连接';
  }

  private smartEmptyHint(): string {
    if (!this.smartEngaged()) {
      return '点了实际节点就会退回手动模式；想用内核自动选点，请点上方「自动选择」';
    }
    if (this.smartChannelDown) {
      return '读不到内核的连接列表，先连接 VPN 再看';
    }
    return '产生流量后，内核实际选中的节点会显示在这里（每 3 秒刷新）';
  }

  /** 自动选择视图的轮询：进入视图才起，离开/页面隐藏必须停 */
  private smartPollTimer: number = -1;

  private startSmartPoll(): void {
    this.stopSmartPoll();
    this.refreshSmartActive();
    this.smartPollTimer = setInterval(() => {
      this.refreshSmartActive();
    }, 3000);
  }

  private stopSmartPoll(): void {
    if (this.smartPollTimer !== -1) {
      clearInterval(this.smartPollTimer);
      this.smartPollTimer = -1;
    }
  }

  private enterSmartView(): void {
    this.smartView = true;
    this.filterSubId = '';
    this.rebuildRows();
    this.startSmartPoll();
  }

  private exitSmartView(): void {
    if (!this.smartView) {
      return;
    }
    this.smartView = false;
    this.stopSmartPoll();
    // 必须重建：自动选择视图把 this.nodes 换成了内核在用节点的子集，
    // 不重建就会停留在那个被过滤的列表上（用户会以为"看不到/选不了其他节点"）。
    this.rebuildRows();
  }

  /**
   * 构造「♻️ 自动选择」合成行。
   *
   * 它**不是真实节点**（没有 server/port），只为在列表里提供一个可选入口：
   * 选中它 = 切到自动模式，由内核按连接目标用 LightGBM 选点。
   * 因此必须靠 `isSmart` 标记把它与真实节点区分开，否则会被送进测速引擎，
   * 或在下一次生成配置时被当成真实节点（它不在 `subs.nodes` 里，天然不会）。
   */
  private mkSmartRow(): NodeRow {
    const node = new ProxyNode();
    node.id = SMART_ROW_ID;
    node.name = ClashConfigGenerator.SMART_GROUP_NAME;
    node.originalName = node.name;
    node.type = ProxyNodeType.UNKNOWN;
    node.server = '';
    node.port = 0;
    const row: NodeRow = {
      node: node,
      countryCode: '',
      status: this.statusFor(node.name),
      isSmart: true
    };
    return row;
  }

  /**
   * 批量测速期间的实时重排：按当前延迟值升序，未测/失败(负值)沉底并保持原相对顺序。
   * 与批末 rebuildRows 的快照排序口径一致（buildAuto 也是有效延迟升序、失败沉底），
   * 所以中途的实时顺序与最终顺序平滑衔接，不会跳变。
   */
  private resortLiveByLatency(): void {
    const arr: NodeRow[] = this.nodes.slice();
    const key = (row: NodeRow): number => {
      // 合成行没有延迟，永远置顶（否则会被当成"未测"沉到最底）
      if (row.isSmart === true) {
        return -1;
      }
      const v = LatencyController.latencyFor(row.node.name);
      return (v === null || v < 0) ? Number.MAX_SAFE_INTEGER : v;
    };
    arr.sort((a: NodeRow, b: NodeRow): number => key(a) - key(b));
    this.nodes = arr;
  }

  private groupKey(group: ProxyGroup): string {
    return group.subscriptionId + '\u0000' + group.name;
  }

  /** 当前持久化的父组策略选择名（无选择或 JSON 损坏时返回空串）。 */
  private selectedStrategyName(parent: ProxyGroup): string {
    if (this.settings.proxyGroupSelections.length === 0) {
      return '';
    }
    try {
      const selections = JSON.parse(this.settings.proxyGroupSelections) as Record<string, string>;
      const value = selections[this.groupKey(parent)];
      return typeof value === 'string' ? value : '';
    } catch (_) {
      return '';
    }
  }

  /** 组头摘要：类型 + 有效节点数，已选策略时附加展示。 */
  private groupSubtitle(groupRow: ProxyGroupRow): string {
    let text = `${groupRow.group.groupType} · ${groupRow.nodes.length} 个有效节点`;
    const selected = this.selectedStrategyName(groupRow.group);
    if (selected.length > 0) {
      text += ` · 已选 ${selected}`;
    }
    return text;
  }

  private mkNodeRow(node: ProxyNode): NodeRow {
    return {
      node: node,
      countryCode: NodeCountryPolicy.detect(node.name).code,
      status: this.statusFor(node.name)
    };
  }

  private isGroupExpanded(group: ProxyGroup): boolean {
    return this.expandedGroupKeys.includes(this.groupKey(group));
  }

  private toggleGroup(group: ProxyGroup): void {
    const key = this.groupKey(group);
    if (this.expandedGroupKeys.includes(key)) {
      this.expandedGroupKeys = this.expandedGroupKeys.filter((value: string) => value !== key);
      return;
    }
    this.expandedGroupKeys = this.expandedGroupKeys.concat([key]);
  }

  /**
   * 页面初始化时恢复排序状态:
   * 从设置里反序列化最近一次测速快照 + 排序模式，并把快照中的延迟回填到
   * LatencyController（否则重启后列表顺序对了但延迟数字仍显示"未测试"）。
   * 快照损坏 / 无数据时回退 default（订阅原始顺序）。
   */
  private restoreSortState(): void {
    const snap = NodeSortSnapshot.fromJsonText(this.settings.nodeSortSnapshot);
    const mode = NodeSortModes.normalize(this.settings.nodeSortMode);
    if (snap === null || (mode === NodeSortModes.AUTO && !snap.hasLatencyData())
      || (mode === NodeSortModes.MANUAL && snap.order.length === 0)) {
      this.sortSnapshot = snap;
      this.sortMode = NodeSortModes.DEFAULT;
      return;
    }
    this.sortSnapshot = snap;
    this.sortMode = mode;
    for (const rec of snap.records) {
      if (rec.latency !== -2) {
        LatencyController.set(rec.name, rec.latency);
      }
    }
    this.pruneStaleLatencyDisplay();
  }

  /**
   * 清理「没有结论」的显示残留：控制器里的旧值（例如上一轮的 -1）会被
   * LatencyStyle 渲染成「超时」，而快照里该节点其实是「未测 / 核心不可用 /
   * 端口可达」。只保留快照中**有有效延迟结论**的节点，其余剔除（回到「未测」）。
   */
  private pruneStaleLatencyDisplay(): void {
    const snap = this.sortSnapshot;
    if (snap === null) {
      return;
    }
    const valid: string[] = [];
    for (const rec of snap.records) {
      if (rec.latency !== -2) {
        valid.push(rec.name);
      }
    }
    LatencyController.retainOnly(valid);
  }

  /** 落盘排序模式 + 测速快照（随 AppSettings 持久化，无需重连隧道） */
  private async persistSortState(): Promise<void> {
    this.settings.nodeSortMode = this.sortMode;
    this.settings.nodeSortSnapshot = this.sortSnapshot === null ? '' : this.sortSnapshot.toJsonText();
    await SettingsService.save(this.settings);
  }

  /** 排序模式中文说明（用于 toast） */
  private sortModeLabel(mode: string): string {
    if (mode === NodeSortModes.AUTO) {
      return '自动排序（按测速结果）';
    }
    if (mode === NodeSortModes.MANUAL) {
      return '手动固定顺序';
    }
    return '默认顺序';
  }

  /** 用户切换排序模式（点击排序按钮）: 循环 default → auto → manual → default 并持久化 */
  private cycleSortMode(): void {
    const next = this.sortMode === NodeSortModes.DEFAULT ? NodeSortModes.AUTO
      : (this.sortMode === NodeSortModes.AUTO ? NodeSortModes.MANUAL : NodeSortModes.DEFAULT);
    this.sortMode = next;
    // 切到 manual 时把当前可见顺序固化为固定顺序
    if (next === NodeSortModes.MANUAL) {
      const order: string[] = [];
      for (const r of this.nodes) {
        order.push(r.node.name);
      }
      const snap = this.sortSnapshot === null ? new NodeSortSnapshot() : this.sortSnapshot;
      snap.mode = NodeSortModes.MANUAL;
      snap.order = order;
      this.sortSnapshot = snap;
    } else if (this.sortSnapshot !== null) {
      this.sortSnapshot.mode = next;
    }
    this.rebuildRows();
    this.persistSortState();
    promptAction.showToast({ message: `排序方式：${this.sortModeLabel(next)}` });
  }

  /**
   * 刷新: 全部订阅重新拉取并重建节点列表(对齐原版顶栏刷新图标职责)。
   * 并发版：网络拉取并发（DEFAULT_LANES 路），解析/改内存/落盘逐条串行。
   * 进度边到边刷 UI：顶栏刷新图标显示 done/total，成功一条就把新节点立即上屏。
   * 防重入语义保留：refreshing 为真时直接返回，连点不会产生重叠批次。
   */
  private async refreshNodes(): Promise<void> {
    if (this.refreshing) {
      return;
    }
    const ids: string[] = [];
    for (const s of this.subs.subscriptions) {
      ids.push(s.id);
    }
    if (ids.length === 0) {
      promptAction.showToast({ message: '没有可刷新的订阅' });
      return;
    }
    this.refreshing = true;
    this.refreshTotal = ids.length;
    this.refreshDone = 0;
    this.refreshOk = 0;
    this.refreshFail = 0;
    try {
      const summary = await this.subs.refreshSubscriptionsConcurrently(ids,
        ConcurrentRefresh.DEFAULT_LANES,
        (progress: RefreshBatchProgress, item: RefreshItemOutcome) => {
          this.refreshDone = progress.done;
          this.refreshOk = progress.okCount;
          this.refreshFail = progress.failCount;
          if (item.ok) {
            this.rebuildRows();
          }
        },
        (): boolean => !this.refreshing);
      this.rebuildRows();
      const reasons: string[] = [];
      for (const item of summary.outcomes) {
        if (!item.ok) {
          const reason = item.message.length > 0 ? item.message : '刷新失败';
          reasons.push(`${this.subscriptionNameOf(item.id)}: ${reason}`);
        }
      }
      let message = '';
      if (summary.failCount === 0) {
        message = `刷新完成，共 ${summary.nodeCount} 个节点（并发 ${summary.lanes} 路）`;
      } else if (summary.okCount > 0) {
        message = `刷新完成，共 ${summary.nodeCount} 个节点（${summary.okCount} 成功 / `
          + `${summary.failCount} 失败）；${this.summarizeReasons(reasons)}`;
      } else {
        message = `刷新失败：${this.summarizeReasons(reasons)}`;
      }
      if (summary.rateLimitedCount > 0) {
        message = message + `；${summary.rateLimitedCount} 条被面板限流(429/403)，已降速未重试`;
      }
      AppLogger.info(TAG, `refreshNodes done: ${summary.done}/${summary.total} ok=${summary.okCount} `
        + `fail=${summary.failCount} nodes=${summary.nodeCount} lanes=${summary.lanes}`);
      promptAction.showToast({ message: message });
    } catch (e) {
      promptAction.showToast({ message: '刷新失败，请检查网络' });
      AppLogger.warn(TAG, `refreshNodes failed: ${AppLogger.errText(e)}`);
    } finally {
      this.refreshing = false;
      this.refreshTotal = 0;
      this.refreshDone = 0;
    }
  }

  /** 订阅 id → 显示名（失败原因要点名到具体订阅） */
  private subscriptionNameOf(id: string): string {
    const found = this.subs.subscriptions.find((s: Subscription) => s.id === id);
    return found === undefined ? id : found.name;
  }

  /** 失败原因摘要（toast 有长度上限：最多 2 条 + 总数） */
  private summarizeReasons(reasons: string[]): string {
    if (reasons.length === 0) {
      return '请检查网络';
    }
    const head = reasons.slice(0, 2).join('；');
    return reasons.length > 2 ? `${head} 等 ${reasons.length} 条` : head;
  }


  /** 本页要测的节点集合 = 当前列表里的真实节点行（不含组行、组成员行与 smart 合成行）。 */
  private targetNodes(): ProxyNode[] {
    const out: ProxyNode[] = [];
    for (const row of this.nodes) {
      if (row.isSmart === true) {
        continue;
      }
      out.push(row.node);
    }
    return out;
  }

  /** 把引擎进度映射到顶栏 UI（唯一数据来源；页面不自己再统计成功/失败） */
  private applyProgress(p: LatencyProgress, driveHeader: boolean): void {
    this.latencyTotal = p.total;
    this.latencyDone = p.finished;
    this.latencyChannelLabel = p.channel;
    this.latencyCoreUnavailable = p.coreUnavailable;
    if (driveHeader) {
      // 顶栏「进度 + 取消」只在批量（含进页面自动补测）时出现：单节点测速的反馈
      // 是那一行的转圈，不该把整条顶栏换成进度条。
      this.batchTesting = p.running;
    }
  }

  /**
   * 本批使用的测速 URL。
   *
   * 尊重用户在设置里的 `testLatencyUrl`（旧实现也是这么做的，只是同时挂着 3 个
   * fallback 和整批级降级机制 —— 那套机制已删除，因为主流客户端**没有一个**做 URL
   * 轮换，失败通常意味着节点本身不通，而不是 URL 被针对）。
   * 但**强制 HTTPS**：`unified-delay` 开启时 mihomo 会发两次 HEAD，官方明确警告
   * `http://` 这类 URL 在劫持型代理下会失败；用户若填了 http 就回落到默认 HTTPS。
   */
  private testUrlForLatency(): string {
    const configured: string = this.settings.testLatencyUrl.trim();
    if (configured.startsWith('https://')) {
      return configured;
    }
    if (configured.length > 0) {
      AppLogger.warn(TAG, `test url "${configured}" is not https; falling back to ${LATENCY_TEST_URL}`);
    }
    return LATENCY_TEST_URL;
  }

  /**
   * 跑一批测速。
   *
   * 与旧实现的根本差别：并发、超时、取消、失败分类、URL 选择全部归引擎，
   * 页面只负责「给一串节点 + 把进度画出来」。落盘由调用方决定（见
   * commitLatencySnapshot）：显式「测全部」才写排序快照，进页面的静默补测只填数字。
   *
   * @param list 目标节点
   * @param force true=全部重测（用户主动点），false=只补缺失/过期（进页面自动补）
   * @param driveHeader 是否用本批进度驱动顶栏（批量 true / 单节点 false）
   */
  private async runLatency(list: ProxyNode[], force: boolean,
    driveHeader: boolean): Promise<LatencyProgress | null> {
    if (list.length === 0) {
      return null;
    }
    this.batchCancelled = false;
    if (driveHeader) {
      // 立刻进入「进度 + 取消」态：取通道本身可能要等（未连接时要拉起进程内无头内核），
      // 这段等待必须有可见反馈，否则用户会以为点了没反应。
      this.batchTesting = true;
      this.latencyTotal = list.length;
      this.latencyDone = 0;
      this.latencyCoreUnavailable = false;
    }
    // 通道由编排器决定：已连接 → 隧道 controller；未连接 → 进程内无头内核；
    // 都没有 → null，引擎据此走**明确标注**的离线粗略通道（状态 OFFLINE，显示 ≈ms）。
    // 这里绝不因为 api === null 就放弃调用 —— 那会让"没连 VPN 时点测速毫无反应"。
    const api: ClashApiService | null = await this.orchestrator.ensureLatencyApi();
    if (this.batchCancelled) {
      // 用户在这段等待里已经点了取消/离开了页面：别再起批次
      if (driveHeader) {
        this.batchTesting = false;
      }
      return null;
    }
    const opts = new LatencyRunOptions();
    opts.force = force;
    opts.timeoutMs = LATENCY_TIMEOUT_MS;
    // 结果不需要在这里手动处理：LatencyEngine 自己写 LatencyController，页面的
    // latencyListener 已经在 200ms 合并窗口里 bump latencyTick 触发重排/重绘。
    opts.onResult = null;
    opts.onProgress = (p: LatencyProgress): void => {
      this.applyProgress(p, driveHeader);
    };
    const run: LatencyRun = LatencyEngine.start(api, list, this.testUrlForLatency(), opts);
    try {
      return await run.run();
    } catch (e) {
      AppLogger.warn(TAG, `latency run failed: ${AppLogger.errText(e)}`);
      return null;
    } finally {
      // 引擎是单航班：必须在收尾时释放，否则残留引用会让 isRunning() 永远为真，
      // 之后每次测速都走 cancelCurrent() 直接作废。
      LatencyEngine.release(run);
      // 被打断（取消/离页）或通道不可用的节点，引擎不会为它发布任何记录，那条记录
      // 会永远停在 TESTING —— 行上就是一个永不停止的转圈。这不是节点结论，收回 `--`。
      this.clearTestingMarks(list);
      LatencyController.flushNow();
      if (driveHeader) {
        this.batchTesting = false;
      }
    }
  }

  /** 单节点手动测速：与批量走同一引擎、同一套五态语义，只是列表里只有一个节点 */
  private async testOne(node: ProxyNode): Promise<void> {
    if (this.batchTesting || this.testingName.length > 0) {
      promptAction.showToast({ message: '测速进行中' });
      return;
    }
    this.testingName = node.name;
    try {
      // force=true：用户明确点了这一行就一定要重测，绝不拿缓存糊弄（旧实现用
      // 「5 分钟内的缓存」直接返回 toast，用户点了像没反应）。
      await this.runLatency([node], true, false);
    } finally {
      this.testingName = '';
    }
  }

  /**
   * 进页面自动补测：force=false，只补没有新鲜结果的节点。
   *
   * 不 await（不能阻塞首屏渲染）、不弹任何 toast：全部新鲜时引擎立刻以
   * skipped === total 结束，绝不能再出现「全部节点使用缓存，无需重新测速」这种
   * 让用户以为点坏了的提示。已有批次在跑就直接让位（引擎是单航班）。
   */
  private async autoTestMissing(): Promise<void> {
    if (LatencyEngine.isRunning()) {
      return;
    }
    // ── 频率闸门 ────────────────────────────────────────────────────
    // 旧行为：每次进页面都补测（onPageShow → bootstrap → 这里）。用户明确要求
    // 「只在软件重新启动时测一次，或导入订阅时自动测一次」。
    //
    // AppStorage 只在**进程内存**里，app 冷启动即清空 —— 正好表达"本次启动还没测过"。
    // 订阅变化用 subscriptionRevision 表达（导入/刷新会 +1），它变了就再测一次。
    const testedStamp = AppStorage.get<string>('latency_session_stamp') ?? '';
    const stamp = `${AppStorage.get<number>('subscription_revision') ?? 0}`;
    if (testedStamp === stamp) {
      return;
    }
    // 先占位再测：autoTestMissing 可能被并发触发（快速切页），
    // 不先写入会出现两轮同时启动。
    AppStorage.setOrCreate('latency_session_stamp', stamp);
    const list = this.targetNodes();
    if (list.length === 0) {
      return;
    }
    try {
      await this.runLatency(list, false, true);
    } catch (e) {
      AppLogger.warn(TAG, `auto latency failed: ${AppLogger.errText(e)}`);
    }
  }

  /**
   * 把本轮引擎结果落成持久化排序快照（只在用户主动「测全部」后调用）。
   *
   * 旧实现在 worker 里自己攒 NodeLatencyRecord；现在唯一的结果来源是控制器，
   * 于是这里做一次「状态 → 快照记录」的翻译。翻译必须保留五态语义：
   * 只有 MEASURED 是节点结论；TIMEOUT / FAILED 是结论性失败；OFFLINE（离线粗略，
   * 只证明端口可达）与 TESTING / CANCELLED / UNTESTED 都**不是**代理延迟结论，
   * 标成 PORT_ONLY / UNTESTED 交给 NodeSortSnapshot.buildAuto() 沿用上一次结论，
   * 绝不把通道故障写成"全超时"污染排序。
   *
   * @param tested 本轮参与测速的节点（快照只覆盖它们，其余节点沿用旧结论）
   */
  private commitLatencySnapshot(tested: ProxyNode[]): void {
    const collected: NodeLatencyRecord[] = [];
    for (const node of tested) {
      const rec = LatencyController.recordFor(node.name);
      collected.push(rec === null
        ? this.untestedPersistRecord(node.name) : this.toPersistRecord(rec));
    }
    const allNames: string[] = [];
    for (const n of this.subs.nodes) {
      allNames.push(n.name);
    }
    this.sortSnapshot = NodeSortSnapshot.buildAuto(Date.now(), collected, this.sortSnapshot, allNames);
    this.sortMode = NodeSortModes.AUTO;
    // 状态徽标来自快照，重建行才会刷新
    this.rebuildRows();
  }

  /** 无记录 = 本次没得出节点结论：保持「未测」，交给 buildAuto 沿用旧结论 */
  private untestedPersistRecord(name: string): NodeLatencyRecord {
    const out = new NodeLatencyRecord();
    out.name = name;
    out.latency = -2;
    out.failKind = LatencyFailKind.UNTESTED;
    return out;
  }

  /** LatencyRecord（五态）→ NodeLatencyRecord（持久化形状），见 commitLatencySnapshot 注释 */
  private toPersistRecord(rec: LatencyRecord): NodeLatencyRecord {
    const out = new NodeLatencyRecord();
    out.name = rec.name;
    if (rec.state === LatencyState.MEASURED) {
      out.latency = rec.delayMs;
      out.failKind = LatencyFailKind.NONE;
      return out;
    }
    if (rec.state === LatencyState.TIMEOUT) {
      out.latency = -1;
      out.failKind = LatencyFailKind.TIMEOUT;
      return out;
    }
    if (rec.state === LatencyState.FAILED) {
      out.latency = -1;
      out.failKind = LatencyFailKind.NETWORK_UNREACHABLE;
      return out;
    }
    // OFFLINE（仅端口可达）/ TESTING / CANCELLED / UNTESTED：不是节点结论
    out.latency = -2;
    out.failKind = rec.state === LatencyState.OFFLINE
      ? LatencyFailKind.PORT_ONLY : LatencyFailKind.UNTESTED;
    return out;
  }

  /**
   * 把仍停在「测试中」的记录收回「未测」。
   *
   * 第一责任人是引擎（LatencyEngine.clearOwnTestingMarks，覆盖正常结束/取消/
   * 作废/worker 异常全部退出路径）。这里保留一次是**纵深防御**：页面拿到的 list
   * 可能包含引擎没跑到的节点（比如批次开始前就被取消），多清一次是幂等的，
   * 而漏清的代价是行上永久转圈。
   */
  private clearTestingMarks(names: ProxyNode[]): void {
    for (const node of names) {
      if (LatencyController.stateFor(node.name) === LatencyState.TESTING) {
        LatencyController.set(node.name, -2);
      }
    }
  }

  /** 长按删除单个节点 */
  private async doDeleteNode(): Promise<void> {
    if (this.deleteTargetId.length === 0) {
      return;
    }
    const removed = this.subs.findNode(this.deleteTargetId);
    const wasSelected = this.settings.preferredNodeId === this.deleteTargetId;
    const ok = await this.subs.removeNode(this.deleteTargetId);
    this.deleteTargetId = '';
    if (!ok) {
      promptAction.showToast({ message: '删除失败，请重试' });
      return;
    }
    if (wasSelected) {
      this.settings.preferredNodeId = '';
      await SettingsService.save(this.settings);
      this.selectedName = this.subs.nodes.length > 0 ? this.subs.nodes[0].name : '';
    }
    this.rebuildRows();
    promptAction.showToast({ message: removed !== null ? `已删除「${removed.name}」` : '已删除' });
  }

  /**
   * 「测全部」—— **组测速（对齐主流客户端）**：一次 `GET /group/PROXY/delay`
   * 让内核对组内全部节点并发测试（Go goroutine，无客户端 http 栈的同 host
   * 并发连接限制——16/32 并发的连接池排队问题就此消失）。
   * 内核源码实证：url 参数被使用；PROXY 组（select 类型）的用户固定选择不被
   * ForceSet 清掉；返回 map 里只有成功的节点，失败的按「超时」落库。
   * 单节点测速仍走 `/proxies/{name}/delay`（逐个）。取消 = abort 组测请求。
   */
  private async testAll(): Promise<void> {
    if (this.batchTesting || LatencyEngine.isRunning()) {
      promptAction.showToast({ message: '测速进行中' });
      return;
    }
    const list = this.targetNodes();
    if (list.length === 0) {
      promptAction.showToast({ message: '暂无可测速的节点' });
      return;
    }
    const progress = await this.runGroupLatency(list, true);
    if (this.batchCancelled) {
      // 用户取消 / 离开页面：已落库的结果保持可见（不回滚）。
      return;
    }
    if (progress === null) {
      if (this.pageActive) {
        promptAction.showToast({ message: '内核不可用，已跳过（未写入超时）' });
      }
      return;
    }
    this.commitLatencySnapshot(list);
    await this.persistSortState();
    AppLogger.info(TAG, `group latency batch done: total=${progress.total} measured=${progress.measured} `
      + `timeout=${progress.timeout} channel=${progress.channel}`);
    if (this.pageActive) {
      promptAction.showToast({
        message: `测速完成：可用 ${progress.measured} / 超时 ${progress.timeout}`
      });
    }
  }

  /**
   * 组测速执行：markTesting 全部 → 一次组测请求 → 按 map 逐节点落库。
   * map 里有的节点 = 内核实测成功（MEASURED）；map 里没有的 = 内核侧超时/失败
   * （TIMEOUT，内核源码 URLTest：err != nil 的节点不进 map）——按用户要求
   * 「要么超时要么延迟」，不留未测。请求失败（连接失败/全超时）= 通道不可用，
   * 保持未测 + 由 testAll 提示。
   */
  private async runGroupLatency(list: ProxyNode[], driveHeader: boolean): Promise<LatencyProgress | null> {
    if (list.length === 0) {
      return null;
    }
    this.batchCancelled = false;
    if (driveHeader) {
      this.batchTesting = true;
      this.latencyTotal = list.length;
      this.latencyDone = 0;
      this.latencyCoreUnavailable = false;
    }
    const api: ClashApiService | null = await this.orchestrator.ensureLatencyApi();
    if (this.batchCancelled) {
      if (driveHeader) {
        this.batchTesting = false;
      }
      return null;
    }
    if (api === null) {
      if (driveHeader) {
        this.batchTesting = false;
      }
      return null;
    }
    const progress = new LatencyProgress();
    progress.total = list.length;
    progress.running = true;
    progress.channel = LatencyChannel.CORE;
    this.applyProgress(progress, driveHeader);
    // 先全部标记「测试中」（转圈），结果落地后逐个覆盖
    for (const n of list) {
      LatencyController.markTesting(n.name);
    }
    this.groupTestApi = api;
    const resultMap = await api.testGroupDetailed('PROXY', this.testUrlForLatency(),
      GROUP_TEST_TIMEOUT_MS);
    this.groupTestApi = null;
    if (this.batchCancelled) {
      // 用户取消：被中断的节点收回「未测」
      for (const n of list) {
        if (LatencyController.stateFor(n.name) === LatencyState.TESTING) {
          LatencyController.setRecord(LatencyRecord.untested(n.name));
        }
      }
      LatencyController.flushNow();
      if (driveHeader) {
        this.batchTesting = false;
      }
      return null;
    }
    if (resultMap === null) {
      // 组测请求失败 = 通道不可用：保持未测（TESTING 收回），不写成节点结论
      progress.coreUnavailable = true;
      for (const n of list) {
        if (LatencyController.stateFor(n.name) === LatencyState.TESTING) {
          LatencyController.setRecord(LatencyRecord.untested(n.name));
        }
      }
      LatencyController.flushNow();
      if (driveHeader) {
        this.batchTesting = false;
      }
      return progress;
    }
    // 逐节点落库：map 有 → 实测；map 无 → 内核侧超时（TIMEOUT）
    for (const n of list) {
      const delay = resultMap.get(n.name);
      if (delay !== undefined && delay > 0) {
        LatencyController.setRecord(
          LatencyRecord.measured(n.name, delay, LatencyChannel.CORE, Date.now()));
        progress.measured = progress.measured + 1;
      } else {
        LatencyController.setRecord(
          LatencyRecord.failed(n.name, LatencyState.TIMEOUT, Date.now(), LatencyChannel.CORE));
        progress.timeout = progress.timeout + 1;
      }
      progress.finished = progress.finished + 1;
      this.latencyDone = progress.finished;
      this.applyProgress(progress, driveHeader);
    }
    // 双保险：provider 节点等组内成员不在 App 表的，TESTING 残留统一收回
    let testing = 0;
    for (const n of list) {
      if (LatencyController.stateFor(n.name) === LatencyState.TESTING) {
        LatencyController.setRecord(
          LatencyRecord.failed(n.name, LatencyState.TIMEOUT, Date.now(), LatencyChannel.CORE));
        testing = testing + 1;
      }
    }
    if (testing > 0) {
      progress.timeout = progress.timeout + testing;
      progress.finished = progress.total;
    }
    progress.running = false;
    LatencyController.flushNow();
    // **重建行数据**：页面行渲染的是 rebuildRows() 预构建的 status 字段，
    // 只 bump 重绘信号（flushNow）不会更新行内容 —— 组测结束必须主动重建，
    // 否则用户要返回主页再进才能看到延迟（手动刷新的旧观感）。
    this.rebuildRows();
    if (driveHeader) {
      this.batchTesting = false;
    }
    return progress;
  }

  /**
   * 顶栏「取消」：只取消引擎当前批次。
   * 取消是幂等的（再点一次什么也不会发生），批次的进度回调/收尾会把 batchTesting 复位。
   */
  private cancelLatency(): void {
    this.batchCancelled = true;
    LatencyEngine.cancelCurrent();
    // 组测速（单请求）也要能取消：abort 组测的 http 请求
    if (this.groupTestApi !== null) {
      this.groupTestApi.cancelInflight();
    }
  }

  /** 选择 selector 直接引用的策略组，并持久化到稳定的父组键。 */
  private async selectStrategy(parent: ProxyGroup, strategy: ProxyGroup): Promise<void> {
    let selections: Record<string, string> = {};
    if (this.settings.proxyGroupSelections.length > 0) {
      try {
        selections = JSON.parse(this.settings.proxyGroupSelections) as Record<string, string>;
      } catch (_) {
        selections = {};
      }
    }
    selections[this.groupKey(parent)] = strategy.name;
    this.settings.proxyGroupSelections = JSON.stringify(selections);
    await SettingsService.save(this.settings);
    // bump @State 计数让 ForEach 键变化，立即刷新组头摘要与策略行选中标记。
    this.latencyTick = this.latencyTick + 1;
    const didRestart = await this.orchestrator.restartIfConnected('proxyGroup=' + strategy.name);
    promptAction.showToast({
      message: didRestart ? `已选择 ${strategy.name}，正在自动重连…` : `已选择 ${strategy.name}，下次连接生效`
    });
  }

  private async selectNode(node: ProxyNode): Promise<void> {
    // ── 合成行：内核 smart 组入口 ──────────────────────────────────
    // 它不是真实节点，不能进 reconnectWithNode（没有 server/port 会生成非法配置）。
    // 选中它的语义 = 「切到自动模式」，由内核按连接目标用 LightGBM 选点；
    // 重连仍用当前偏好的真实节点，orchestrator 在 auto 模式下会把 PROXY 指向 smart 组。
    if (node.id === SMART_ROW_ID) {
      this.settings.autoSelectMode = AutoSelectModes.AUTO;
      this.autoSelectMode = AutoSelectModes.AUTO;
      await SettingsService.save(this.settings);
      const pool: ProxyNode[] = this.subs.nodes;
      let target: ProxyNode | null = null;
      for (const n of pool) {
        if (n.id === this.settings.preferredNodeId) {
          target = n;
          break;
        }
      }
      if (target === null && pool.length > 0) {
        target = pool[0];
      }
      if (target === null) {
        promptAction.showToast({ message: '没有可用节点' });
        return;
      }
      const didRestart = await this.orchestrator.reconnectWithNode(
        target, this.subs, 'autoSelectMode=auto');
      if (didRestart) {
        const revision = AppStorage.get<number>('public_ip_revision') ?? 0;
        AppStorage.setOrCreate('public_ip_revision', revision + 1);
      }
      this.selectedName = ClashConfigGenerator.SMART_GROUP_NAME;
      promptAction.showToast({
        message: didRestart ? '已启用内核智能选点，正在自动重连…' : '已启用内核智能选点，下次连接生效'
      });
      return;
    }
    // ── 真实节点：必须**退出自动模式** ────────────────────────────────
    // 否则会出现「点了节点但没用」：auto 模式下 connect() 里的 pinSmartGroup 会把
    // PROXY 指向 smart 组，preferredNodeId 被悄悄架空 —— 用户看到的是手动选择失效。
    // 手动点节点是明确的"我要固定走这个"意图，必须以它为准。
    if (this.settings.autoSelectMode === AutoSelectModes.AUTO) {
      this.settings.autoSelectMode = AutoSelectModes.MANUAL;
      // 页面横幅读的是 @State autoSelectMode，不同步会继续显示"自动选点"，
      // 与刚刚落库的手动选择自相矛盾。
      this.autoSelectMode = AutoSelectModes.MANUAL;
      this.exitSmartView();
      AppLogger.info(TAG, `manual node pick (${node.name}); auto mode disabled`);
    }
    this.settings.preferredNodeId = node.id;
    this.selectedName = node.name;
    await SettingsService.save(this.settings);
    // 节点切换始终执行完整重连。Mihomo controller 返回 2xx 只能证明请求被接受，
    // 不能证明现有连接已迁移到新节点；此前因此错误提示“未重建隧道”，但流量仍走旧节点。
    const didRestart = await this.orchestrator.reconnectWithNode(node, this.subs, 'preferredNode=' + node.id);
    // 通知仍驻留在导航栈中的主页：重连完成后重新查询出口公网 IP，不能继续显示旧 @State 缓存。
    if (didRestart) {
      const revision = AppStorage.get<number>('public_ip_revision') ?? 0;
      AppStorage.setOrCreate('public_ip_revision', revision + 1);
    }
    promptAction.showToast({
      message: didRestart ? `已选择 ${node.name}，正在自动重连…` : `已选择 ${node.name}，下次连接生效`
    });
  }

  build() {
    Stack() {
      Column()
        .width('100%').height('100%')
        .linearGradient({ angle: 135, colors: Ui.backdropColors })
        // 背景延伸到状态栏/底部导航条之下, 消除底部白条
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column() {
        // ── 顶栏（对齐原版: 返回 + 当前节点 + 刷新/闪电图标组） ──
        Row() {
          Text('←')
            .fontSize(22).fontColor(Ui.textPrimary)
            .onClick(() => router.back())
          Row({ space: 7 }) {
            CountryFlagIcon({
              nodeName: this.selectedName.length > 0 ? this.selectedName : 'UN',
              iconSize: 22
            })
            Text(this.selectedName.length > 0 ? this.selectedName : '选择节点')
              .fontSize(16).fontWeight(FontWeight.Bold)
              .fontColor(Ui.textPrimary)
              // 直接使用完整原始节点名。禁止 compact/去旗标/截断/maxLines/Ellipsis，
              // 让 MARQUEE 对完整字符串循环滚动。
              .textOverflow({ overflow: TextOverflow.MARQUEE })
              .layoutWeight(1)
          }
          .layoutWeight(1)
          .constraintSize({ minWidth: 0 })
          .margin({ left: 12, right: 12 })
          // 刷新 + 排序方式 + 测速（测速中变成「进度 + 取消」）
          Row({ space: 10 }) {
            Text(this.refreshing ? `◌ ${this.refreshDone}/${this.refreshTotal}` : '⟳')
              .fontSize(this.refreshing ? 16 : 22)
              .fontColor(this.refreshing ? Ui.primary : Ui.textPrimary)
              .onClick(() => this.refreshNodes())
            Text(this.sortMode === NodeSortModes.AUTO ? '⇅'
              : (this.sortMode === NodeSortModes.MANUAL ? '🔒' : '↕'))
              .fontSize(20)
              .fontColor(this.sortMode === NodeSortModes.DEFAULT ? Ui.textPrimary : Ui.primary)
              .onClick(() => this.cycleSortMode())
            if (this.batchTesting) {
              // 测速中：进度（已结束节点数 / 总数）+ 通道 + 取消。
              // 进度直接来自引擎的 onProgress，页面不自己统计，避免数字与结论不一致。
              Row({ space: 6 }) {
                Progress({
                  value: this.latencyDone,
                  total: this.latencyTotal > 0 ? this.latencyTotal : 1,
                  type: ProgressType.Linear
                })
                  .width(46)
                  .height(6)
                  .color(Ui.primary)
                  .backgroundColor(Ui.surfaceTranslucent)
                Text(`${this.latencyDone}/${this.latencyTotal}`)
                  .fontSize(12)
                  .fontColor(Ui.textSecondary)
                // 离线粗略通道必须标出来：这些数字只代表服务器可达，不是代理延迟
                if (this.latencyChannelLabel === LatencyChannel.OFFLINE) {
                  Text('离线')
                    .fontSize(11)
                    .fontColor(Ui.textTertiary)
                }
                Text('取消')
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Ui.primary)
                  .padding({ left: 4, right: 2 })
                  .onClick(() => this.cancelLatency())
              }
            } else {
              Row({ space: 8 }) {
                // 通道（内核/凭证）不可用：本轮没有任何节点结论，明确告诉用户原因
                if (this.latencyCoreUnavailable) {
                  Text('内核不可用，本轮未测')
                    .fontSize(11)
                    .fontColor(Ui.warning)
                }
                Text('测全部')
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Ui.textPrimary)
                  .onClick(() => this.testAll())
              }
            }
          }
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 10, bottom: 6 })

        // ── 订阅筛选 chips ──
        if (this.subChips.length > 0) {
          Scroll() {
            Row({ space: 8 }) {
              Text('全部')
                .fontSize(13)
                .fontColor(!this.smartView && this.filterSubId.length === 0 ? Ui.textPrimary : Ui.textSecondary)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .borderRadius(16)
                .backgroundColor(!this.smartView && this.filterSubId.length === 0 ? Ui.selectedBackground : Ui.surfaceTranslucent)
                .borderWidth(1)
                .borderColor(!this.smartView && this.filterSubId.length === 0 ? Ui.primary : Ui.border)
                .onClick(() => {
                  this.exitSmartView();
                  this.filterSubId = '';
                  this.rebuildRows();
                })
              // 自动选择分组：把内核按连接选出的节点集中展示。
              // 只在模型就绪时出现 —— 没模型时内核压根没有这个组，展示会是空壳。
              if (this.smartSelectable()) {
                Text('自动选择')
                  .fontSize(13)
                  .fontColor(this.smartView ? Ui.textPrimary : Ui.textSecondary)
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .borderRadius(16)
                  .backgroundColor(this.smartView ? Ui.selectedBackground : Ui.surfaceTranslucent)
                  .borderWidth(1)
                  .borderColor(this.smartView ? Ui.primary : Ui.border)
                  .onClick(() => this.enterSmartView())
              }
              ForEach(this.subChips, (chip: SubChip) => {
                Text(chip.name)
                  .fontSize(13)
                  .fontColor(!this.smartView && this.filterSubId === chip.id ? Ui.textPrimary : Ui.textSecondary)
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .borderRadius(16)
                  .backgroundColor(!this.smartView && this.filterSubId === chip.id ? Ui.selectedBackground : Ui.surfaceTranslucent)
                  .borderWidth(1)
                  .borderColor(!this.smartView && this.filterSubId === chip.id ? Ui.primary : Ui.border)
                  .onClick(() => {
                    this.exitSmartView();
                    this.filterSubId = chip.id;
                    this.rebuildRows();
                  })
              }, (chip: SubChip) => chip.id + '#' + chip.name)
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
          // 与上方快捷按钮拉开间距
          .padding({ left: 18, right: 18, top: 18, bottom: 6 })
        }

        // ── 选点模式说明：明确区分「手动固定」与「自动排序」，澄清自动切换不会覆盖手动选择 ──
        Row({ space: 6 }) {
          Text(this.autoSelectMode === AutoSelectModes.AUTO ? '⚡' : '🔒')
            .fontSize(12)
            .fontColor(this.autoSelectMode === AutoSelectModes.AUTO ? Ui.warning : Ui.textSecondary)
          Text(this.autoSelectMode === AutoSelectModes.AUTO
            ? $r('app.string.node_mode_auto_banner')
            : $r('app.string.node_mode_manual_banner'))
            .fontSize(11)
            .fontColor(Ui.textSecondary)
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .borderRadius(12)
        .backgroundColor(Ui.surfaceTranslucent)
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
          colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
        })
        .backgroundEffect({ radius: Ui.glassControlBlurRadius, saturation: Ui.glassControlSaturation, brightness: Ui.glassControlBrightness })
        .borderWidth(1)
        .borderColor(Ui.glassEdge)
        .margin({ left: 18, right: 18, top: 10 })

        // ── 节点列表 ──
        // 说明文案只保留上方那条横幅（模式 + 长按删除提示），
        // 此前这里还有一行「排序：自动排序（按测速结果）」与横幅重复，已移除。
        if (this.nodes.length === 0) {
          Column({ space: 12 }) {
            Text(this.smartView ? '⚡' : '🖧').fontSize(46).fontColor(Ui.textTertiary)
            Text(this.smartEmptyTitle())
              .fontSize(15).fontColor(Ui.textSecondary)
            if (this.smartView) {
              Text(this.smartEmptyHint())
                .fontSize(12).fontColor(Ui.textTertiary)
                .textAlign(TextAlign.Center)
                .padding({ left: 30, right: 30 })
            }
          }
          .width('100%')
          .margin({ top: 120 })
        } else if (this.groupRows.length > 0) {
          List({ space: 9, scroller: this.listScroller }) {
            ForEach(this.groupRows, (groupRow: ProxyGroupRow) => {
              ListItem() {
                Column({ space: 7 }) {
                  Row({ space: 10 }) {
                    Text(this.isGroupExpanded(groupRow.group) ? '⌄' : '›')
                      .fontSize(22)
                      .fontColor(Ui.primary)
                      .width(24)
                      .textAlign(TextAlign.Center)
                    Column({ space: 2 }) {
                      Text(groupRow.group.name)
                        .fontSize(16)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(Ui.textPrimary)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(this.groupSubtitle(groupRow))
                        .fontSize(11)
                        .fontColor(Ui.textSecondary)
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                  }
                  .width('100%')
                  .padding({ left: 12, right: 12, top: 10, bottom: 10 })
                  .borderRadius(15)
                  .backgroundColor(Ui.surfaceStrong)
                  .borderWidth(1)
                  .borderColor(Ui.glassEdge)
                  .onClick(() => this.toggleGroup(groupRow.group))

                  if (this.isGroupExpanded(groupRow.group)) {
                    // 自动选择、故障转移、负载均衡等策略作为 selector 的同级可选项。
                    ForEach(groupRow.strategyGroups, (strategy: ProxyGroup) => {
                      Row({ space: 10 }) {
                        Text('⚙')
                          .fontSize(18)
                          .fontColor(Ui.primary)
                          .width(24)
                          .textAlign(TextAlign.Center)
                        Column({ space: 2 }) {
                          Text(strategy.name)
                            .fontSize(14)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(Ui.textPrimary)
                            .maxLines(1)
                            .textOverflow({ overflow: TextOverflow.Ellipsis })
                          Text(`${strategy.groupType} · ${this.subs.expandProxyGroup(strategy).length} 个节点`)
                            .fontSize(10)
                            .fontColor(Ui.textSecondary)
                        }
                        .layoutWeight(1)
                        .alignItems(HorizontalAlign.Start)
                        Text(this.selectedStrategyName(groupRow.group) === strategy.name ? '✓' : '›')
                          .fontSize(20)
                          .fontColor(this.selectedStrategyName(groupRow.group) === strategy.name
                            ? Ui.primary : Ui.textTertiary)
                      }
                      .width('100%')
                      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
                      .borderRadius(12)
                      .backgroundColor(Ui.surfaceTranslucent)
                      .borderWidth(1)
                      .borderColor(Ui.glassEdge)
                      .onClick(() => this.selectStrategy(groupRow.group, strategy))
                    }, (strategy: ProxyGroup) => this.groupKey(groupRow.group) + '#strategy#'
                      + this.groupKey(strategy))

                    // 直接挂在本组下的普通节点成员
                    ForEach(groupRow.memberNodes, (row: NodeRow) => {
                      Row() {
                        this.NodeCard(row)
                      }
                      .gesture(LongPressGesture().onAction(() => {
                        this.deleteTargetId = row.node.id;
                        this.deleteTargetName = row.node.name;
                        this.deleteNodeDialog.open();
                      }))
                    }, (row: NodeRow) => this.groupKey(groupRow.group) + '#m#' + row.node.id + '#'
                      + this.latencyTick.toString() + '#' + this.testingName)
                  }
                }
                .width('100%')
              }
            }, (groupRow: ProxyGroupRow) => this.groupKey(groupRow.group) + '#'
              + this.expandedGroupKeys.join('|') + '#' + this.latencyTick.toString() + '#' + this.testingName)
          }
          .layoutWeight(1)
          .padding({ left: 18, right: 18, top: 8, bottom: 20 })
          .scrollBar(BarState.Off)
        } else {
          List({ space: 7, scroller: this.listScroller }) {
            ForEach(this.nodes, (row: NodeRow) => {
              ListItem() {
                this.NodeCard(row)
              }
              // 合成行不可删除：它不在订阅里，DELETE 会拿一个不存在的 id 去删。
              .gesture(LongPressGesture().onAction(() => {
                if (row.isSmart === true) {
                  return;
                }
                this.deleteTargetId = row.node.id;
                this.deleteTargetName = row.node.name;
                this.deleteNodeDialog.open();
              }))
            }, (row: NodeRow) => row.node.id + '#' + this.latencyTick.toString() + '#' + this.testingName)
          }
          .layoutWeight(1)
          .padding({ left: 18, right: 18, top: 8, bottom: 20 })
          .scrollBar(BarState.Off)
        }
      }
      .width('100%').height('100%')
    }
    .width('100%').height('100%')
  }

  /** 协议类型徽标: vless/vmess/trojan/ss/ssr/hysteria2，REALITY 节点追加 ·REALITY */
  @Builder
  ProtocolBadge(node: ProxyNode) {
    Row({ space: 5 }) {
      Text(NodeProtocolPolicy.fromNode(node).display())
        .fontSize(10)
        .fontWeight(FontWeight.Medium)
        .fontColor(NodeProtocolPolicy.isRealityNode(node) ? Ui.textViolet : Ui.textSecondary)
        .padding({ left: 6, right: 6, top: 1, bottom: 1 })
        .borderRadius(6)
        .backgroundColor(Ui.surfaceTranslucent)
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
          colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
        })
        .borderWidth(1)
        .borderColor(NodeProtocolPolicy.isRealityNode(node) ? Ui.primary : Ui.glassEdge)
    }
  }

  /** 通用小徽标 */
  @Builder
  Badge(text: ResourceStr, color: ResourceColor) {
    Text(text)
      .fontSize(10)
      .fontWeight(FontWeight.Medium)
      .fontColor(color)
      .padding({ left: 6, right: 6, top: 1, bottom: 1 })
      .borderRadius(6)
      .backgroundColor(Ui.surfaceTranslucent)
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
        colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
      })
      .borderWidth(1)
      .borderColor(Ui.glassEdge)
  }

  /**
   * 节点状态徽标（来自持久化测速快照）。
   *
   * 只展示对用户可操作的状态：未测速 / 连续失败次数 / 成功率。数字「综合评分」
   * 不再展示 —— 它是 SmartSelector 内部用于自动选点与故障切换排序的代价
   * （ms 等价值，越小越好），对用户没有直接可操作性，显示反而造成困惑；
   * 评分计算保留，供将来开启自动选点时使用。
   *
   * 「冷却中」徽标已移除：冷却只影响 SmartSelector 内部选点权重（保留不动），
   * 对用户没有可操作动作，展示它只会造成「节点坏了」的误导。
   */
  @Builder
  NodeStatusBadge(st: NodeStatusView) {
    Row({ space: 5 }) {
      if (!st.hasData) {
        this.Badge($r('app.string.node_badge_untested'), Ui.textTertiary)
      } else {
        if (st.failCount > 0) {
          this.Badge($r('app.string.node_badge_failed_count', st.failCount), Ui.warning)
        } else {
          this.Badge($r('app.string.node_badge_success_rate', st.rateLabel), Ui.success)
        }
      }
    }
  }

  @Builder
  NodeCard(row: NodeRow) {
    if (row.isSmart === true) {
      this.SmartCard(row)
    } else {
      this.RealNodeCard(row)
    }
  }

  /**
   * 「♻️ 自动选择」合成行。
   *
   * 与真实节点卡片的差别是**刻意的**：它没有 server/port，测速与协议徽标都无意义。
   * 所以不显示延迟徽标与 ↻，改成说明文字 —— 否则用户会点测速然后拿到一个永远
   * 「超时」的结果，反而以为功能坏了。
   */
  @Builder
  SmartCard(row: NodeRow) {
    Row() {
      Row({ space: 12 }) {
        Text('♻️').fontSize(24).width(26).textAlign(TextAlign.Center)
        Column({ space: 3 }) {
          Text('自动选择')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(row.node.name === this.selectedName ? Ui.primary : Ui.textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text('内核智能选点 · 按每条连接的目标自动择优')
            .fontSize(11)
            .fontColor(Ui.textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .onClick(() => this.selectNode(row.node))

      Text('✓')
        .fontSize(20)
        .fontColor(Ui.primary)
        .width(24)
        .textAlign(TextAlign.Center)
        .opacity(row.node.name === this.selectedName ? 1 : 0)
    }
    .width('100%')
    .padding({ left: 14, right: 6, top: 7, bottom: 7 })
    .borderRadius(17)
    .backgroundColor(row.node.name === this.selectedName ? Ui.surfaceStrong : Ui.surfaceTranslucent)
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
      colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
    })
    .backgroundEffect({ radius: Ui.glassBlurRadius, saturation: Ui.glassSaturationSoft, brightness: Ui.glassBrightnessSoft })
    .borderWidth(1)
    .borderColor(row.node.name === this.selectedName ? Ui.primary : Ui.glassEdge)
  }

  @Builder
  RealNodeCard(row: NodeRow) {
    Row() {
      Row({ space: 12 }) {
        CountryFlagIcon({ nodeName: row.node.name, iconSize: 26 })
        Column({ space: 3 }) {
          Text(NodeDisplay.withoutLeadingFlag(row.node.name))
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(row.node.name === this.selectedName ? Ui.primary : Ui.textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Row({ space: 5 }) {
            this.ProtocolBadge(row.node)
            this.NodeStatusBadge(row.status)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .onClick(() => this.selectNode(row.node))

      // 延迟徽标：五态可区分（未测 `--` / 测试中转圈 / 实测 ms / 离线粗略 ≈ms / 超时·失败）。
      // 旧实现把「没测过」「失败」「超时」一律画成「超时」，这是本页最大的可信度问题。
      // 徽标本身与右侧 ↻ 都能触发单节点测速；两者都是标题行的兄弟节点，
      // 不会冒泡到上面那个「点行选中节点」的 onClick。
      Row({ space: 2 }) {
        if (LatencyController.stateFor(row.node.name) === LatencyState.TESTING) {
          LoadingProgress()
            .width(16)
            .height(16)
            .color(Ui.primary)
        } else {
          Text(LatencyStyle.recordText(LatencyController.recordFor(row.node.name), Date.now()))
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(LatencyStyle.recordColor(LatencyController.recordFor(row.node.name), Date.now()))
        }
        Text('↻')
          .fontSize(14)
          .fontColor(Ui.textSecondary)
          .padding({ left: 2, right: 6 })
          .onClick(() => this.testOne(row.node))
      }
      .padding({ left: 8 })
      .onClick(() => this.testOne(row.node))

      Text('✓')
        .fontSize(20)
        .fontColor(Ui.primary)
        .width(24)
        .textAlign(TextAlign.Center)
        .opacity(row.node.name === this.selectedName ? 1 : 0)
    }
    .width('100%')
    .padding({ left: 14, right: 6, top: 7, bottom: 7 })
    .borderRadius(17)
    .backgroundColor(row.node.name === this.selectedName ? Ui.surfaceStrong : Ui.surfaceTranslucent)
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
      colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
    })
    .backgroundEffect({ radius: Ui.glassBlurRadius, saturation: Ui.glassSaturationSoft, brightness: Ui.glassBrightnessSoft })
    .borderWidth(1)
    .borderColor(row.node.name === this.selectedName ? Ui.primary : Ui.glassEdge)
  }

}
