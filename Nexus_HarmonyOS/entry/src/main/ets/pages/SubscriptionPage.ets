/**
 * SubscriptionPage —— Nexus 订阅页（对齐 HTML + Ultimate 文档 §6/§7/§8）
 * 布局：大标题+刷新全部+“+”导入 → 状态卡(当前订阅/节点/统计) → 手风琴订阅卡(展开节点单选) → 液态玻璃Dock
 * 后端：复用 SubscriptionService / SettingsService / LatencyController / BackgroundLatencyService 全量逻辑。
 */
import { router, promptAction } from '@kit.ArkUI';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import scanBarcode from '@hms.core.scan.scanBarcode';
import { BusinessError } from '@kit.BasicServicesKit';
import { Nx, NexusPing } from '../theme/NexusTokens';
import { LiquidGlassDock } from '../components/LiquidGlassDock';
import { SubscriptionService, DIRECT_GROUP_ID } from '../commons/services/SubscriptionService';
import { Subscription, SubscriptionRefreshStatus } from '../commons/models/Subscription';
import { ProxyNode } from '../commons/models/ProxyNode';
import { SubscriptionFetchPolicy } from '../commons/services/SubscriptionFetchPolicy';
import { SettingsService } from '../commons/services/SettingsService';
import { AppSettings, AutoSelectModes } from '../commons/models/AppSettings';
import { ClashConfigGenerator } from '../commons/services/ClashConfigGenerator';
import { ConnectionOrchestrator } from '../commons/services/ConnectionOrchestrator';
import { AppLogger } from '../commons/utils/AppLogger';
import { LatencyController } from '../commons/services/LatencyController';
import { BackgroundLatencyService } from '../commons/services/BackgroundLatencyService';
import {
  ConcurrentRefresh, RefreshBatchProgress, RefreshItemOutcome
} from '../commons/services/ConcurrentRefresh';

const TAG = 'SubscriptionPage';

/** “+”导入三选一弹窗（扫描 / URL / 文件），对齐 HTML import-overlay */
@CustomDialog
struct ImportDialog {
  controller?: CustomDialogController;
  @State mode: string = 'main';
  @State urlText: string = '';
  onScan: () => void = () => {};
  onUrl: (url: string) => void = () => {};
  onFile: () => void = () => {};

  aboutToAppear(): void {
    this.mode = 'main';
  }

  @Builder
  OptionBtn(icon: string, title: string, desc: string, bg: ResourceColor, fg: ResourceColor, target: string) {
    Row({ space: 14 }) {
      Text(icon).fontSize(20).fontColor(fg)
        .width(40).height(40).textAlign(TextAlign.Center)
        .borderRadius(10).backgroundColor(bg)
      Column({ space: 1 }) {
        Text(title).fontSize(14).fontWeight(FontWeight.Bold).fontColor(Nx.fg()).width('100%')
        Text(desc).fontSize(11).fontColor(Nx.muted()).width('100%')
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .borderRadius(12)
    .backgroundColor(Nx.surface())
    .borderWidth(1).borderColor(Nx.border())
    .onClick(() => {
      this.mode = target;
    })
  }

  build() {
    Column({ space: 10 }) {
      Row() {
        Text(this.mode === 'main' ? '导入订阅' : (this.mode === 'scan' ? '扫码导入' : (this.mode === 'url' ? '从 URL 链接导入' : '从本地文件导入')))
          .fontSize(16).fontWeight(FontWeight.Bold).fontColor(Nx.fg()).layoutWeight(1)
        Text('✕').fontSize(16).fontColor(Nx.muted()).padding(6)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
      }.width('100%')

      if (this.mode === 'main') {
        this.OptionBtn('☷', '扫描', '扫描屏幕或纸质二维码导入订阅',
          Nx.successSoft(), Nx.success(), 'scan')
        this.OptionBtn('🔗', 'URL', '输入或粘贴订阅链接一键解析',
          Nx.accentSoft(), Nx.accent(), 'url')
        this.OptionBtn('📄', '文件', '选择本地 .yaml / .json / .conf 配置文件',
          'rgba(245, 158, 11, 0.12)', Nx.warning(), 'file')
      } else if (this.mode === 'scan') {
        Column() {
          Text('[ 摄像头：请在系统扫码页对准二维码 ]')
            .fontSize(12).fontColor(Nx.success())
            .width('100%').textAlign(TextAlign.Center)
            .padding(30).borderRadius(10)
            .backgroundColor('#0f172a')
            .borderWidth(1).borderColor('rgba(16, 185, 129, 0.50)')
        }.width('100%')
        Row({ space: 8 }) {
          Button('返回').layoutWeight(1).borderRadius(8)
            .backgroundColor(Nx.fgSoft()).fontColor(Nx.fg()).fontSize(13)
            .onClick(() => { this.mode = 'main'; })
          Button('开始扫码').layoutWeight(1).borderRadius(8)
            .backgroundColor(Nx.accent()).fontColor(Color.White).fontSize(13)
            .onClick(() => {
              if (this.controller !== undefined) {
                this.controller.close();
              }
              this.onScan();
            })
        }.width('100%').margin({ top: 2 })
      } else if (this.mode === 'url') {
        Text('输入订阅 URL 链接：').fontSize(12).fontColor(Nx.muted()).width('100%')
        TextInput({ placeholder: 'https://...', text: this.urlText })
          .onChange((v: string) => { this.urlText = v; })
          .height(40).borderRadius(8).fontSize(13)
          .backgroundColor(Nx.inputBg())
          .borderWidth(1).borderColor(Nx.border())
          .fontColor(Nx.fg())
        Row({ space: 8 }) {
          Button('返回').layoutWeight(1).borderRadius(8)
            .backgroundColor(Nx.fgSoft()).fontColor(Nx.fg()).fontSize(13)
            .onClick(() => { this.mode = 'main'; })
          Button('确认导入').layoutWeight(1).borderRadius(8)
            .backgroundColor(Nx.accent()).fontColor(Color.White).fontSize(13)
            .onClick(() => {
              if (this.controller !== undefined) {
                this.controller.close();
              }
              this.onUrl(this.urlText);
            })
        }.width('100%').margin({ top: 2 })
      } else {
        Column({ space: 2 }) {
          Text('选择本地 Clash / V2Ray 配置文件').fontSize(13).fontWeight(FontWeight.Bold)
            .fontColor(Nx.fg()).width('100%').textAlign(TextAlign.Center)
          Text('支持 .yaml、.json、.conf 格式').fontSize(11).fontColor(Nx.muted())
            .width('100%').textAlign(TextAlign.Center)
        }.width('100%').padding(16).borderRadius(8)
        .borderWidth(1.5).borderColor(Nx.border())
        Row({ space: 8 }) {
          Button('返回').layoutWeight(1).borderRadius(8)
            .backgroundColor(Nx.fgSoft()).fontColor(Nx.fg()).fontSize(13)
            .onClick(() => { this.mode = 'main'; })
          Button('选择文件').layoutWeight(1).borderRadius(8)
            .backgroundColor(Nx.accent()).fontColor(Color.White).fontSize(13)
            .onClick(() => {
              if (this.controller !== undefined) {
                this.controller.close();
              }
              this.onFile();
            })
        }.width('100%').margin({ top: 2 })
      }
    }
    .padding(20)
    .borderRadius(20)
    .backgroundColor(Nx.surface())
    .borderWidth(1).borderColor(Nx.border())
    .shadow({ radius: 28, color: 'rgba(15, 23, 42, 0.25)', offsetY: 12 })
  }
}

@CustomDialog
struct DeleteConfirmDialog {
  controller?: CustomDialogController;
  onConfirm: () => void = () => {};

  build() {
    Column({ space: 14 }) {
      Text('确认删除').fontSize(18).fontWeight(FontWeight.Bold).fontColor(Nx.fg())
      Text('删除后将无法恢复，确定要删除吗？')
        .fontSize(13).fontColor(Nx.muted()).textAlign(TextAlign.Center)
      Row({ space: 12 }) {
        Button('取消').layoutWeight(1).borderRadius(10)
          .backgroundColor(Nx.fgSoft()).fontColor(Nx.fg())
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
        Button('删除').layoutWeight(1).borderRadius(10)
          .backgroundColor(Nx.danger()).fontColor(Color.White)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
            this.onConfirm();
          })
      }.width('100%')
    }
    .padding(24).borderRadius(20)
    .backgroundColor(Nx.surface())
    .borderWidth(1).borderColor(Nx.border())
  }
}

@CustomDialog
struct EditSubscriptionDialog {
  controller?: CustomDialogController;
  @State editName: string = '';
  @State editUrl: string = '';
  @State isLocal: boolean = false;
  getInitialName: () => string = () => '';
  getInitialUrl: () => string = () => '';
  getIsLocal: () => boolean = () => false;
  onConfirm: (name: string, url: string) => void = () => {};

  aboutToAppear(): void {
    this.editName = this.getInitialName();
    this.editUrl = this.getInitialUrl();
    this.isLocal = this.getIsLocal();
  }

  build() {
    Column({ space: 14 }) {
      Text('编辑订阅').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Nx.fg())
      TextInput({ placeholder: '订阅名称', text: this.editName })
        .onChange((v: string) => { this.editName = v; })
        .height(40).borderRadius(8).fontSize(13)
        .backgroundColor(Nx.inputBg())
        .borderWidth(1).borderColor(Nx.border())
        .fontColor(Nx.fg())
      if (!this.isLocal) {
        TextInput({ placeholder: '订阅链接', text: this.editUrl })
          .onChange((v: string) => { this.editUrl = v; })
          .height(40).borderRadius(8).fontSize(13)
          .backgroundColor(Nx.inputBg())
          .borderWidth(1).borderColor(Nx.border())
          .fontColor(Nx.fg())
      } else {
        Text('本地导入的订阅仅支持改名')
          .fontSize(11).fontColor(Nx.muted()).width('100%')
      }
      Row({ space: 12 }) {
        Button('取消').layoutWeight(1).borderRadius(8)
          .backgroundColor(Nx.fgSoft()).fontColor(Nx.fg()).fontSize(13)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
        Button('保存').layoutWeight(1).borderRadius(8)
          .backgroundColor(Nx.accent()).fontColor(Color.White).fontSize(13)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
            this.onConfirm(this.editName, this.editUrl);
          })
      }.width('100%')
    }
    .padding(20).borderRadius(20)
    .backgroundColor(Nx.surface())
    .borderWidth(1).borderColor(Nx.border())
  }
}

@Entry
@Component
struct SubscriptionPage {
  @StorageLink('theme_revision') themeRevision: number = 0;
  @State subs: Subscription[] = [];
  @State expandedIds: string[] = [];
  @State activeSubId: string = '';
  @State activeNodeId: string = '';
  /** 自动选点模式（manual 手动固定 / auto 内核 smart 优选），与设置页同一份持久化 */
  @State autoSelectMode: string = AutoSelectModes.MANUAL;
  @State latencyTick: number = 0;
  @State isAdding: boolean = false;
  @State isRefreshing: boolean = false;
  @State refreshingIds: string[] = [];
  @State isImporting: boolean = false;
  @State isScanning: boolean = false;
  @State toastMsg: string = '';
  @State toastVisible: boolean = false;
  @State deleteTargetId: string = '';
  @State spinTick: number = 0;
  private service: SubscriptionService = SubscriptionService.instance();
  private settings: AppSettings = new AppSettings();
  private readonly latencyListener: () => void = (): void => {
    this.latencyTick = this.latencyTick + 1;
  };
  private latencyBound: boolean = false;
  private deleteDialog: CustomDialogController = new CustomDialogController({
    builder: DeleteConfirmDialog({
      onConfirm: () => {
        this.doDelete(this.deleteTargetId);
      }
    })
  });
  private editTarget: Subscription | null = null;
  private editDialog: CustomDialogController = new CustomDialogController({
    builder: EditSubscriptionDialog({
      getInitialName: (): string => this.editTarget !== null ? this.editTarget.name : '',
      getInitialUrl: (): string => this.editTarget !== null ? this.editTarget.url : '',
      getIsLocal: (): boolean => this.editTarget !== null && this.editTarget.url.startsWith('local://'),
      onConfirm: (name: string, url: string) => {
        this.doEdit(name, url);
      }
    }),
    autoCancel: true
  });
  private importDialog: CustomDialogController = new CustomDialogController({    builder: ImportDialog({
      onScan: () => {
        this.importFromQr();
      },
      onUrl: (url: string) => {
        this.importFromUrl(url);
      },
      onFile: () => {
        this.importYamlFile();
      }
    }),
    autoCancel: true
  });

  onPageShow(): void {
    this.bootstrap();
  }

  aboutToDisappear(): void {
    if (this.latencyBound) {
      LatencyController.removeListener(this.latencyListener);
      this.latencyBound = false;
    }
  }

  private async bootstrap(): Promise<void> {
    const ctx = getContext(this) as Context;
    ConnectionOrchestrator.instance().init(ctx);
    await SettingsService.init(ctx);
    await this.service.init(ctx);
    this.settings = await SettingsService.load();
    this.activeSubId = this.settings.preferredNodeSubscriptionId;
    this.activeNodeId = this.settings.preferredNodeId;
    this.autoSelectMode = AutoSelectModes.normalize(this.settings.autoSelectMode);
    this.reload();
    if (!this.latencyBound) {
      this.latencyBound = true;
      LatencyController.addListener(this.latencyListener);
    }
  }

  private reload(): void {
    this.subs = this.service.subscriptions.filter((s: Subscription) =>
      s.id !== DIRECT_GROUP_ID || s.nodeCount > 0);
    // 默认展开活动订阅；首个订阅默认展开以展示手风琴
    if (this.expandedIds.length === 0 && this.subs.length > 0) {
      const first = this.subs.find((s) => s.id === this.activeSubId) ?? this.subs[0];
      this.expandedIds = [first.id];
    }
    // 同步活动节点展示
    const node = this.service.findNode(this.activeNodeId);
    if (node === null && this.service.nodes.length > 0) {
      this.activeNodeId = this.service.nodes[0].id;
      this.activeSubId = this.service.nodes[0].subscriptionId;
    }
  }

  private showToast(msg: string): void {
    this.toastMsg = msg;
    this.toastVisible = true;
    setTimeout(() => {
      this.toastVisible = false;
    }, 2400);
  }

  private isOpen(id: string): boolean {
    return this.expandedIds.includes(id);
  }

  private toggleOpen(id: string): void {
    if (this.isOpen(id)) {
      this.expandedIds = this.expandedIds.filter((x) => x !== id);
    } else {
      this.expandedIds = this.expandedIds.concat([id]);
    }
  }

  private activeSub(): Subscription | null {
    const s = this.subs.find((x) => x.id === this.activeSubId);
    if (s !== undefined) {
      return s;
    }
    return this.subs.length > 0 ? this.subs[0] : null;
  }

  private activeNode(): ProxyNode | null {
    return this.service.findNode(this.activeNodeId);
  }

  private totalNodes(): number {
    let n = 0;
    for (const s of this.subs) {
      n += this.service.nodesOf(s.id).length;
    }
    return n;
  }

  private protoOf(node: ProxyNode): string {
    if (node.proxyType.length > 0) {
      return node.proxyType.toUpperCase().slice(0, 8);
    }
    if (node.protocol.length > 0) {
      return node.protocol.toUpperCase().slice(0, 8);
    }
    return node.type === 'ss' ? 'SS' : 'SSR';
  }

  private pingOf(node: ProxyNode): number | null {
    return LatencyController.latencyFor(node.name);
  }

  private async selectNode(node: ProxyNode): Promise<void> {
    // 真实节点必须退出自动模式（同 NodeSelectionPage 语义）：否则 orchestrator 的
    // pinSmartGroup 会把 PROXY 指向 smart 组，preferredNodeId 被架空，主页环永远显示“自动选择”。
    if (this.settings.autoSelectMode === AutoSelectModes.AUTO) {
      this.settings.autoSelectMode = AutoSelectModes.MANUAL;
      this.autoSelectMode = AutoSelectModes.MANUAL;
      AppLogger.info(TAG, `manual node pick (${node.name}); auto mode disabled`);
    }
    this.activeNodeId = node.id;
    this.activeSubId = node.subscriptionId;
    this.settings.preferredNodeId = node.id;
    this.settings.preferredNodeSubscriptionId = node.subscriptionId;
    this.settings.selectedSubscriptionId = node.subscriptionId;
    await SettingsService.save(this.settings);
    // 已连接时完整重连让新节点即时生效；未连接时仅保存选择。
    const didRestart = await ConnectionOrchestrator.instance()
      .reconnectWithNode(node, this.service, 'preferredNode=' + node.id);
    if (didRestart) {
      this.showToast(`已选择 ${node.name}，正在自动重连…`);
      AppStorage.setOrCreate('public_ip_revision', (AppStorage.get<number>('public_ip_revision') ?? 0) + 1);
    } else {
      this.showToast(`已选择 ${node.name}`);
    }
  }

  /**
   * 启用内核智能选点（mihomo-smart LightGBM）：跨全部订阅自动优选出口，
   * 故障自动切换 + 网络变化自动重连由编排器既有策略承担（默认全开）。
   * 语义同节点页 smart 合成行：重连仍需一个真实节点做拨号目标。
   */
  private async enableAutoSelect(): Promise<void> {
    if (this.autoSelectMode === AutoSelectModes.AUTO) {
      this.showToast('已在使用内核智能选点');
      return;
    }
    const pool: ProxyNode[] = this.service.nodes;
    let target: ProxyNode | null = this.service.findNode(this.settings.preferredNodeId);
    if (target === null && pool.length > 0) {
      target = pool[0];
    }
    if (target === null) {
      this.showToast('没有可用节点');
      return;
    }
    this.settings.autoSelectMode = AutoSelectModes.AUTO;
    await SettingsService.save(this.settings);
    this.autoSelectMode = AutoSelectModes.AUTO;
    const didRestart = await ConnectionOrchestrator.instance()
      .reconnectWithNode(target, this.service, 'autoSelectMode=auto');
    if (didRestart) {
      AppStorage.setOrCreate('public_ip_revision', (AppStorage.get<number>('public_ip_revision') ?? 0) + 1);
    }
    this.showToast(didRestart ? '已启用内核智能选点，正在自动重连…' : '已启用内核智能选点，下次连接生效');
  }

  private async speedTestSub(subId: string): Promise<void> {
    try {
      this.showToast('正在测速…');
      await BackgroundLatencyService.testSubscription(getContext(this) as Context, subId);
      this.showToast('✓ 测速完成');
    } catch (e) {
      this.showToast('测速失败，请重试');
    }
  }

  private isRefreshingSub(id: string): boolean {
    return this.refreshingIds.includes(id);
  }

  private async refreshOne(sub: Subscription): Promise<void> {
    if (sub.id === DIRECT_GROUP_ID || this.isRefreshing || this.isRefreshingSub(sub.id)) {
      return;
    }
    this.spinTick += 1;
    this.refreshingIds = this.refreshingIds.concat([sub.id]);
    try {
      const result = await this.service.refreshSubscription(sub.id);
      this.reload();
      if (result.status === SubscriptionRefreshStatus.OK) {
        this.showToast(`✓ 已刷新「${sub.name}」及节点测速`);
      } else {
        this.showToast(`${sub.name}：${result.userText('刷新失败')}`);
      }
    } finally {
      this.refreshingIds = this.refreshingIds.filter((x) => x !== sub.id);
    }
  }

  private async refreshAll(): Promise<void> {
    if (this.isAdding || this.isRefreshing || this.refreshingIds.length > 0) {
      return;
    }
    const ids: string[] = [];
    for (const s of this.subs) {
      if (s.id !== DIRECT_GROUP_ID) {
        ids.push(s.id);
      }
    }
    if (ids.length === 0) {
      this.showToast('没有可刷新的订阅');
      return;
    }
    this.spinTick += 1;
    this.isRefreshing = true;
    this.refreshingIds = ids.slice();
    try {
      const summary = await this.service.refreshSubscriptionsConcurrently(ids,
        ConcurrentRefresh.DEFAULT_LANES,
        (progress: RefreshBatchProgress, item: RefreshItemOutcome) => {
          this.refreshingIds = this.refreshingIds.filter((x) => x !== item.id);
          this.reload();
        },
        (): boolean => !this.isRefreshing);
      if (summary.failCount === 0) {
        this.showToast(`✓ 已成功刷新全部 ${summary.total} 个订阅及节点！`);
      } else if (summary.okCount > 0) {
        this.showToast(`部分刷新成功（${summary.okCount} 成功 / ${summary.failCount} 失败）`);
      } else {
        this.showToast('刷新失败，请检查网络后重试');
      }
    } finally {
      this.refreshingIds = [];
      this.isRefreshing = false;
      this.reload();
    }
  }

  private subscriptionNameOf(id: string): string {
    const f = this.subs.find((s: Subscription) => s.id === id);
    return f === undefined ? id : f.name;
  }

  /** URL 导入（HTML importFromUrl 等价：按 host 自动命名） */
  private async importFromUrl(rawUrl: string): Promise<void> {
    const raw = rawUrl.trim();
    if (raw.length === 0 || this.isAdding || this.isRefreshing) {
      return;
    }
    if (SubscriptionService.isNodeUri(raw)) {
      await this.importNodeUri(raw);
      return;
    }
    if (!SubscriptionFetchPolicy.isValidSubscriptionUrl(raw)) {
      promptAction.showToast({ message: '请输入有效的URL地址' });
      return;
    }
    const dupe = this.subs.find((s) => s.url === raw);
    if (dupe !== undefined) {
      promptAction.showToast({ message: '该订阅已存在，无需重复添加' });
      return;
    }
    this.isAdding = true;
    try {
      let host = raw.replace(/^https?:\/\//, '').split('/')[0];
      if (host.length === 0) {
        host = '订阅';
      }
      const sub = await this.service.addSubscription(`🔗 ${host} 节点组`, raw, '', '');
      // 立刻上屏：订阅卡先出现（0 节点 · 刷新中），不等网络刷新完成。
      // 此前 reload 放在 refreshSubscription 之后，慢订阅要等十几秒才有可见反馈。
      this.expandedIds = [sub.id];
      this.activeSubId = sub.id;
      this.reload();
      this.showToast('已添加，正在获取节点…');
      const result = await this.service.refreshSubscription(sub.id);
      if (result.status === SubscriptionRefreshStatus.OK && result.nodeCount > 0) {
        const nodes = this.service.nodesOf(sub.id);
        if (nodes.length > 0) {
          await this.selectNode(nodes[0]);
        }
      }
      this.reload();
      this.showToast(result.status === SubscriptionRefreshStatus.OK
        ? `✓ 订阅成功，获取到 ${result.nodeCount} 个节点` : `已添加，但刷新失败：${result.userText('请稍后重试')}`);
    } catch (e) {
      promptAction.showToast({ message: '添加失败，请检查链接是否有效' });
    }
    this.isAdding = false;
  }

  private async importNodeUri(raw: string): Promise<void> {
    this.isAdding = true;
    try {
      const added = await this.service.addDirectNode(raw);
      this.reload();
      if (added === 1) {
        this.showToast(`节点链接已导入，当前共 ${this.service.nodes.length} 个节点`);
      } else if (added === -1) {
        this.showToast('该节点已存在，无需重复添加');
      } else {
        this.showToast('导入失败，请检查链接是否有效');
      }
    } catch (e) {
      this.showToast('导入失败，请检查链接是否有效');
    }
    this.isAdding = false;
  }

  private async importFromQr(): Promise<void> {
    if (this.isScanning || this.isAdding || this.isRefreshing || this.isImporting) {
      return;
    }
    this.isScanning = true;
    try {
      const result = await scanBarcode.startScanForResult(getContext(this) as Context, {
        enableMultiMode: false,
        enableAlbum: true
      });
      const raw = result.originalValue.trim();
      if (raw.length === 0) {
        this.showToast('二维码内容为空');
        return;
      }
      if (SubscriptionService.isNodeUri(raw)) {
        await this.importNodeUri(raw);
        return;
      }
      const lower = raw.toLowerCase();
      if (!(lower.startsWith('https://') || lower.startsWith('http://'))
        || !SubscriptionFetchPolicy.isValidSubscriptionUrl(raw, true)) {
        this.showToast('二维码不是有效的 HTTP 或 HTTPS 订阅链接');
        return;
      }
      await this.importFromUrl(raw);
    } catch (e) {
      const err = e as BusinessError;
      if (err.code === 1000500002) {
        this.showToast('已取消二维码扫描');
      } else if (err.code === 201) {
        this.showToast('相机权限被拒绝，无法扫描二维码');
      } else {
        this.showToast('二维码扫描失败，请重试');
      }
    } finally {
      this.isScanning = false;
    }
  }

  private async importYamlFile(): Promise<void> {
    if (this.isImporting) {
      return;
    }
    this.isImporting = true;
    try {
      const docPicker = new picker.DocumentViewPicker(getContext(this) as Context);
      const opts = new picker.DocumentSelectOptions();
      opts.maxSelectNumber = 1;
      opts.fileSuffixFilters = ['.yaml', '.yml', '.txt', '.json', '.conf'];
      const uris = await docPicker.select(opts);
      if (uris.length === 0) {
        return;
      }
      const uri = uris[0];
      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      try {
        const stat = fs.statSync(file.fd);
        if (stat.size <= 0 || stat.size > 4 * 1024 * 1024) {
          this.showToast('文件大小需在 4MB 以内');
          return;
        }
        const buf = new ArrayBuffer(Number(stat.size));
        let readLen = 0;
        while (readLen < Number(stat.size)) {
          const chunk = fs.readSync(file.fd, buf, { offset: readLen, length: Number(stat.size) - readLen });
          if (chunk <= 0) {
            break;
          }
          readLen += chunk;
        }
        const text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf, 0, readLen));
        const fileName = uri.substring(uri.lastIndexOf('/') + 1);
        const count = await this.service.addLocalYaml(fileName, text);
        if (count > 0) {
          this.showToast(`文件导入成功，解析出 ${count} 个节点`);
          this.reload();
        } else {
          this.showToast('文件未解析出节点（支持 Clash YAML 与 ss/vless/vmess/trojan 链接）');
        }
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      AppLogger.warn(TAG, `yaml file import failed: ${AppLogger.errText(e)}`);
      this.showToast('导入失败，请重试');
    } finally {
      this.isImporting = false;
    }
  }

  private async doDelete(id: string): Promise<void> {
    if (id === DIRECT_GROUP_ID) {
      this.showToast('单节点分组为常驻分组，不能删除');
      return;
    }
    await this.service.removeSubscription(id);
    this.expandedIds = this.expandedIds.filter((x) => x !== id);
    if (this.activeSubId === id) {
      this.activeSubId = '';
      this.activeNodeId = '';
    }
    this.reload();
    this.showToast('订阅已删除');
  }

  private openEdit(sub: Subscription): void {
    this.editTarget = sub;
    this.editDialog.open();
  }

  private async doEdit(name: string, url: string): Promise<void> {
    const target = this.editTarget;
    if (target === null) {
      return;
    }
    if (name.trim().length === 0) {
      this.showToast('订阅名称不能为空');
      return;
    }
    const isLocal = target.url.startsWith('local://');
    if (target.id !== DIRECT_GROUP_ID && !isLocal && url.trim().length === 0) {
      this.showToast('订阅链接不能为空');
      return;
    }
    // 本地导入允许改名；http/https 走完整 URL 校验
    if (target.id !== DIRECT_GROUP_ID && !isLocal && !url.trim().startsWith('local://')
      && !SubscriptionFetchPolicy.isValidSubscriptionUrl(url.trim())) {
      this.showToast('请输入有效的订阅链接');
      return;
    }
    const dupe = target.id === DIRECT_GROUP_ID ? undefined
      : this.subs.find((s) => s.url === url.trim() && s.id !== target.id);
    if (dupe !== undefined) {
      this.showToast('该订阅链接已存在');
      return;
    }
    target.name = name.trim();
    if (target.id !== DIRECT_GROUP_ID && !isLocal) {
      target.url = url.trim();
    }
    await this.service.updateSubscription(target);
    this.reload();
    this.editTarget = null;
    this.showToast('订阅已更新');
  }

  private formatUpdateTime(ts: number): string {
    if (ts <= 0) {
      return '未更新';
    }
    const diff = Date.now() - ts;
    const minutes = Math.floor(diff / 60000);
    if (minutes < 1) {
      return '刚刚';
    }
    if (minutes < 60) {
      return `${minutes}分钟前`;
    }
    const hours = Math.floor(minutes / 60);
    if (hours < 24) {
      return `${hours}小时前`;
    }
    const days = Math.floor(hours / 24);
    if (days < 7) {
      return `${days}天前`;
    }
    const d = new Date(ts);
    return `${d.getMonth() + 1}/${d.getDate()}`;
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column().width('100%').height('100%')
        .backgroundColor(Nx.bg())
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column() {
        Scroll() {
          Column({ space: 0 }) {
            // 顶部 Toast（刷新反馈，居中悬浮等价：顶部横条）
            if (this.toastVisible) {
              Text(this.toastMsg)
                .fontSize(11.5).fontWeight(FontWeight.Bold).fontColor(Color.White)
                .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                .borderRadius(9999)
                .backgroundColor('rgba(15, 23, 42, 0.88)')
                .margin({ bottom: 8 })
            }
            // ── 顶部大标题 + 刷新全部 + “+” ──
            Row() {
              Column({ space: 1 }) {
                Text('订阅与节点').fontSize(22).fontWeight(FontWeight.Bold)
                  .fontColor(Nx.fg()).width('100%')
                Text('展开查看节点，点击即可直接选用')
                  .fontSize(12).fontColor(Nx.muted()).width('100%')
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              Row({ space: 8 }) {
                // 刷新全部 38px
                Stack({ alignContent: Alignment.Center }) {
                  if (this.isRefreshing) {
                    LoadingProgress().width(18).height(18).color(Nx.accent())
                  } else {
                    Text('↻').fontSize(18).fontColor(Nx.muted())
                      .rotate({ angle: this.spinTick * 360 })
                      .animation({ duration: 650, curve: Curve.EaseInOut })
                  }
                }
                .width(38).height(38).borderRadius(9999)
                .backgroundColor(Nx.surface())
                .borderWidth(1.5).borderColor(Nx.border())
                .shadow({ radius: 6, color: 'rgba(15, 23, 42, 0.05)', offsetY: 2 })
                .onClick(() => this.refreshAll())
                // “+”导入 38px
                Text('+')
                  .fontSize(22).fontWeight(FontWeight.Bold).fontColor(Nx.accent())
                  .width(38).height(38).textAlign(TextAlign.Center)
                  .borderRadius(9999)
                  .backgroundColor(Nx.surface())
                  .borderWidth(1.5).borderColor(Nx.border())
                  .shadow({ radius: 8, color: 'rgba(15, 23, 42, 0.06)', offsetY: 2 })
                  .onClick(() => this.importDialog.open())
              }.alignItems(VerticalAlign.Center)
            }.width('100%').margin({ bottom: 12 })

            // ── 当前状态卡 ──
            Column({ space: 5 }) {
              Row() {
                Text('当前使用订阅').fontSize(12).fontColor(Nx.muted()).layoutWeight(1)
                Text(this.activeSub() !== null ? (this.activeSub() as Subscription).name : '暂无')
                  .fontSize(12).fontWeight(FontWeight.Bold).fontColor(Nx.fg())
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              }.width('100%')
              Row() {
                Text('当前连接节点').fontSize(12).fontColor(Nx.muted()).layoutWeight(1)
                Text(this.activeNode() !== null ? (this.activeNode() as ProxyNode).name : '未选择')
                  .fontSize(12).fontWeight(FontWeight.Bold).fontColor(Nx.accent())
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              }.width('100%')
              Row() {
                Text('统计总览').fontSize(12).fontColor(Nx.muted()).layoutWeight(1)
                Text(`${this.subs.length} 个订阅 · ${this.totalNodes()} 个节点`)
                  .fontSize(12).fontWeight(FontWeight.Bold).fontColor(Nx.fg())
                  .fontFamily('monospace')
              }.width('100%')
            }
            .width('100%')
            .padding({ left: 13, right: 13, top: 11, bottom: 11 })
            .borderRadius(14)
            .backgroundColor(Nx.surface())
            .borderWidth(1).borderColor(Nx.border())
            .shadow({ radius: 6, color: 'rgba(15, 23, 42, 0.04)', offsetY: 2 })
            .margin({ bottom: 12 })

            // ── 自动选择分组（mihomo-smart 内核智能选点，跨全部订阅优选） ──
            Column({ space: 0 }) {
              Row({ space: 10 }) {
                Text('♻️').fontSize(15).fontColor(Nx.success())
                  .width(32).height(32).textAlign(TextAlign.Center)
                  .borderRadius(8).backgroundColor(Nx.successSoft())
                Column({ space: 2 }) {
                  Row({ space: 6 }) {
                    Text('自动选择 · 内核智能选点')
                      .fontSize(14).fontWeight(FontWeight.Bold).fontColor(Nx.fg())
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    if (this.autoSelectMode === AutoSelectModes.AUTO) {
                      Text('使用中')
                        .fontSize(10).fontWeight(FontWeight.Bold).fontColor(Nx.success())
                        .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                        .borderRadius(9999)
                        .backgroundColor(Nx.successSoft())
                    }
                  }.width('100%')
                  Text(`跨订阅自动优选 · 故障自动切换 · ${this.totalNodes()} 个候选节点`)
                    .fontSize(11).fontColor(Nx.muted()).width('100%')
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                Text('›')
                  .fontSize(18).fontColor(Nx.muted())
                  .rotate({ angle: this.isOpen('__auto_select__') ? 90 : 0 })
                  .animation({ duration: 250, curve: Curve.EaseInOut })
              }
              .width('100%')
              .padding({ left: 15, right: 15, top: 13, bottom: 13 })
              .backgroundColor(Nx.surface())
              .onClick(() => this.toggleOpen('__auto_select__'))

              if (this.isOpen('__auto_select__')) {
                Column({ space: 5 }) {
                  Row() {
                    Text('由 smart 内核按连接目标自动选点，无需手动切换')
                      .fontSize(11).fontColor(Nx.muted()).layoutWeight(1)
                  }.width('100%').padding({ left: 6, right: 6, top: 4, bottom: 2 })
                  Row({ space: 9 }) {
                    Stack({ alignContent: Alignment.Center }) {
                      Circle({ width: 16, height: 16 })
                        .fill(this.autoSelectMode === AutoSelectModes.AUTO ? Nx.accent() : Color.Transparent)
                        .stroke(this.autoSelectMode === AutoSelectModes.AUTO ? Nx.accent() : Nx.radioEdge())
                        .strokeWidth(1.6)
                      if (this.autoSelectMode === AutoSelectModes.AUTO) {
                        Circle({ width: 5, height: 5 }).fill(Color.White)
                      }
                    }.width(16).height(16)
                    Text(ClashConfigGenerator.SMART_GROUP_NAME)
                      .fontSize(13).fontWeight(FontWeight.Medium).fontColor(Nx.fg())
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                    Text('SMART')
                      .fontSize(10).fontColor(Nx.muted()).fontFamily('monospace')
                      .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                      .borderRadius(4).backgroundColor(Nx.fgSoft())
                    Text('自动优选')
                      .fontSize(11).fontWeight(FontWeight.Bold)
                      .fontColor(Nx.success()).fontFamily('monospace')
                  }
                  .width('100%')
                  .padding({ left: 12, right: 12, top: 9, bottom: 9 })
                  .borderRadius(10)
                  .backgroundColor(this.autoSelectMode === AutoSelectModes.AUTO ? Nx.accentBg() : Nx.surface())
                  .borderWidth(1)
                  .borderColor(this.autoSelectMode === AutoSelectModes.AUTO ? Nx.accent() : Nx.border())
                  .shadow(this.autoSelectMode === AutoSelectModes.AUTO ?
                    { radius: 4, color: 'rgba(37, 99, 235, 0.15)', offsetY: 1 } :
                    { radius: 0, color: Color.Transparent, offsetY: 0 })
                  .onClick(() => this.enableAutoSelect())
                }
                .width('100%')
                .padding({ left: 10, right: 10, bottom: 12, top: 4 })
                .backgroundColor(Nx.bg())
                .borderWidth({ top: 1 })
                .borderColor(Nx.border())
              }
            }
            .width('100%')
            .borderRadius(14)
            .backgroundColor(Nx.surface())
            .borderWidth(1.5)
            .borderColor(this.autoSelectMode === AutoSelectModes.AUTO ? Nx.accent() : Nx.border())
            .shadow(this.autoSelectMode === AutoSelectModes.AUTO ?
              { radius: 12, color: 'rgba(37, 99, 235, 0.10)', offsetY: 3 } :
              { radius: 6, color: 'rgba(15, 23, 42, 0.04)', offsetY: 2 })
            .margin({ bottom: 12 })
            .clip(true)

            // ── 手风琴订阅列表 ──
            ForEach(this.subs, (sub: Subscription) => {
              Column({ space: 0 }) {
                // 头部
                Row({ space: 10 }) {
                  Text('📦').fontSize(15).fontColor(Nx.accent())
                    .width(32).height(32).textAlign(TextAlign.Center)
                    .borderRadius(8).backgroundColor(Nx.accentSoft())
                  Column({ space: 2 }) {
                    Row({ space: 6 }) {
                      Text(sub.name)
                        .fontSize(14).fontWeight(FontWeight.Bold).fontColor(Nx.fg())
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      if (sub.id === this.activeSubId) {
                        Text('使用中')
                          .fontSize(10).fontWeight(FontWeight.Bold).fontColor(Nx.success())
                          .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                          .borderRadius(9999)
                          .backgroundColor(Nx.successSoft())
                      }
                    }.width('100%')
                    Text(`${this.service.nodesOf(sub.id).length} 个节点 · 更新于 ${this.formatUpdateTime(sub.lastFetchedAt)}`)
                      .fontSize(11).fontColor(Nx.muted()).width('100%')
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                  // 单个刷新 28px
                  Stack({ alignContent: Alignment.Center }) {
                    if (this.isRefreshingSub(sub.id)) {
                      LoadingProgress().width(15).height(15).color(Nx.accent())
                    } else {
                      Text('↻').fontSize(15).fontColor(Nx.muted())
                    }
                  }
                  .width(28).height(28).borderRadius(9999)
                  .onClick(() => this.refreshOne(sub))
                  // 重命名（常驻分组头，不用展开）
                  Text('✎')
                    .fontSize(15).fontColor(Nx.muted())
                    .width(28).height(28).textAlign(TextAlign.Center)
                    .borderRadius(9999)
                    .onClick(() => this.openEdit(sub))
                  if (sub.id !== DIRECT_GROUP_ID) {
                    Text('🗑')
                      .fontSize(14).fontColor(Nx.muted())
                      .width(28).height(28).textAlign(TextAlign.Center)
                      .borderRadius(9999)
                      .onClick(() => {
                        this.deleteTargetId = sub.id;
                        this.deleteDialog.open();
                      })
                  }
                  Text('›')
                    .fontSize(18).fontColor(Nx.muted())
                    .rotate({ angle: this.isOpen(sub.id) ? 90 : 0 })
                    .animation({ duration: 250, curve: Curve.EaseInOut })
                }
                .width('100%')
                .padding({ left: 15, right: 15, top: 13, bottom: 13 })
                .backgroundColor(Nx.surface())
                .onClick(() => this.toggleOpen(sub.id))

                // 展开节点区
                if (this.isOpen(sub.id)) {
                  Column({ space: 5 }) {
                    Row() {
                      Text('点击任一节点即可直接选用')
                        .fontSize(11).fontColor(Nx.muted()).layoutWeight(1)
                      Text('⚡ 一键测速')
                        .fontSize(11).fontWeight(FontWeight.Bold).fontColor(Nx.accent())
                        .onClick(() => this.speedTestSub(sub.id))
                    }.width('100%').padding({ left: 6, right: 6, top: 4, bottom: 2 })
                    ForEach(this.service.nodesOf(sub.id), (node: ProxyNode) => {
                      Row({ space: 9 }) {
                        // 单选圆圈 16px
                        Stack({ alignContent: Alignment.Center }) {
                          Circle({ width: 16, height: 16 })
                            .fill(node.id === this.activeNodeId ? Nx.accent() : Color.Transparent)
                            .stroke(node.id === this.activeNodeId ? Nx.accent() : Nx.radioEdge())
                            .strokeWidth(1.6)
                          if (node.id === this.activeNodeId) {
                            Circle({ width: 5, height: 5 }).fill(Color.White)
                          }
                        }.width(16).height(16)
                        Text(node.name)
                          .fontSize(13).fontWeight(FontWeight.Medium).fontColor(Nx.fg())
                          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                          .layoutWeight(1)
                        Text(this.protoOf(node))
                          .fontSize(10).fontColor(Nx.muted()).fontFamily('monospace')
                          .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                          .borderRadius(4).backgroundColor(Nx.fgSoft())
                        Row({ space: 4 }) {
                          Circle({ width: 5, height: 5 }).fill(NexusPing.color(this.pingOf(node)))
                          Text(NexusPing.text(this.pingOf(node)))
                            .fontSize(11).fontWeight(FontWeight.Bold)
                            .fontColor(NexusPing.color(this.pingOf(node))).fontFamily('monospace')
                        }
                      }
                      .width('100%')
                      .padding({ left: 12, right: 12, top: 9, bottom: 9 })
                      .borderRadius(10)
                      .backgroundColor(node.id === this.activeNodeId ? Nx.accentBg() : Nx.surface())
                      .borderWidth(1)
                      .borderColor(node.id === this.activeNodeId ? Nx.accent() : Nx.border())
                      .shadow(node.id === this.activeNodeId ?
                        { radius: 4, color: 'rgba(37, 99, 235, 0.15)', offsetY: 1 } :
                        { radius: 0, color: Color.Transparent, offsetY: 0 })
                      .onClick(() => this.selectNode(node))
                    }, (node: ProxyNode) => node.id)
                    // 编辑/删除行
                    if (sub.id !== DIRECT_GROUP_ID) {
                      Row({ space: 12 }) {
                        Blank()
                        Text('✎ 编辑')
                          .fontSize(12).fontColor(Nx.muted())
                          .onClick(() => this.openEdit(sub))
                        Text('🗑 删除')
                          .fontSize(12).fontColor(Nx.danger())
                          .onClick(() => {
                            this.deleteTargetId = sub.id;
                            this.deleteDialog.open();
                          })
                      }.width('100%').padding({ top: 4, right: 4 })
                    }
                  }
                  .width('100%')
                  .padding({ left: 10, right: 10, bottom: 12, top: 4 })
                  .backgroundColor(Nx.bg())
                  .borderWidth({ top: 1 })
                  .borderColor(Nx.border())
                }
              }
              .width('100%')
              .borderRadius(14)
              .backgroundColor(Nx.surface())
              .borderWidth(1.5)
              .borderColor(sub.id === this.activeSubId ? Nx.accent() : Nx.border())
              .shadow(sub.id === this.activeSubId ?
                { radius: 12, color: 'rgba(37, 99, 235, 0.10)', offsetY: 3 } :
                { radius: 6, color: 'rgba(15, 23, 42, 0.04)', offsetY: 2 })
              .margin({ bottom: 12 })
              .clip(true)
            }, (sub: Subscription) => `${sub.id}|${sub.name}|${this.service.nodesOf(sub.id).length}|${sub.lastFetchedAt}|${this.isOpen(sub.id) ? 1 : 0}|${sub.id === this.activeSubId ? 1 : 0}|${this.activeNodeId}|${this.latencyTick}`)

            if (this.subs.length === 0) {
              Column({ space: 10 }) {
                Text('📡').fontSize(44)
                Text('暂无订阅').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Nx.muted())
                Text('点击右上角 + 添加订阅').fontSize(12).fontColor(Nx.faint())
              }.width('100%').padding({ top: 50, bottom: 50 })
            }
          }
          .width('100%')
          .padding({ left: 18, right: 18, top: 10, bottom: 110 })
        }
        .width('100%').height('100%')
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      .width('100%').height('100%')

      // ── 底部液态玻璃 Dock ──
      Column() {
        LiquidGlassDock({ currentTab: 'subscription' })
      }
      .width('100%')
      .padding({ left: 18, right: 18, bottom: 18 })
    }
    .width('100%').height('100%')
  }

  pageTransition() {
    PageTransitionEnter({ duration: 360, curve: Curve.EaseInOut }).opacity(0.68).scale({ x: 0.992, y: 0.992 })
    PageTransitionExit({ duration: 300, curve: Curve.EaseInOut }).opacity(0.72).scale({ x: 1.008, y: 1.008 })
  }
}
