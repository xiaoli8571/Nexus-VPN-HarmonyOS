import { router, promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { Ui } from '../theme/UiTokens';
import { SettingsService } from '../commons/services/SettingsService';
import { ConnectionOrchestrator } from '../commons/services/ConnectionOrchestrator';
import { SiteRoutingPolicy } from '../commons/services/SiteRoutingPolicy';

class SitePageParams { kind: string = 'proxy'; }

@CustomDialog
struct SiteInputDialog {
  controller?: CustomDialogController;
  @State text: string = '';
  onAdd: (text: string) => boolean = () => false;
  build() {
    Column({ space: 14 }) {
      Text('添加 / 批量导入网站').fontSize(19).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
      Text('每行一个纯域名，例如 example.com。无需 https://，不要填写路径、端口或通配符；规则包含其子域名。')
        .fontSize(12).fontColor(Ui.textSecondary)
      TextArea({ text: this.text, placeholder: 'example.com\nexample.org' }).height(180).maxLength(131072)
        .backgroundColor(Ui.inputBackground).fontColor(Ui.textPrimary).onChange((value: string) => { this.text = value; })
      Row({ space: 12 }) {
        Button('取消').layoutWeight(1).onClick(() => this.controller?.close())
        Button('添加到当前名单').layoutWeight(2).onClick(() => { if (this.onAdd(this.text)) { this.controller?.close(); } })
      }
    }.padding(22).borderRadius(24).backgroundColor(Ui.surfaceMuted)
  }
}

@Entry
@Component
struct SiteRoutingPage {
  @State kind: string = 'proxy';
  @State proxy: string[] = [];
  @State direct: string[] = [];
  @State query: string = '';
  @State selected: string[] = [];
  @State selectedOnly: boolean = false;
  @State alphabetical: boolean = false;
  @State visible: string[] = [];
  @State ready: boolean = false;
  @State busy: boolean = true;
  @State dirty: boolean = false;
  @State notice: string = '';
  private originalProxy: string[] = [];
  private originalDirect: string[] = [];
  private initial: string = '';
  private orchestrator: ConnectionOrchestrator = ConnectionOrchestrator.instance();
  private dialog: CustomDialogController = new CustomDialogController({
    builder: SiteInputDialog({ onAdd: (text: string): boolean => this.add(text) }), autoCancel: false
  });

  aboutToAppear(): void { this.load(); }
  private async load(): Promise<void> {
    try {
      const params = router.getParams() as SitePageParams;
      this.kind = params !== undefined && params !== null && params.kind === 'direct' ? 'direct' : 'proxy';
      const context = getContext(this) as Context;
      this.orchestrator.init(context);
      await SettingsService.init(context);
      const settings = await SettingsService.load();
      this.originalProxy = settings.forceProxySites.slice();
      this.originalDirect = settings.forceDirectSites.slice();
      this.proxy = SiteRoutingPolicy.normalizeList(settings.forceProxySites);
      this.direct = SiteRoutingPolicy.normalizeList(settings.forceDirectSites);
      this.initial = this.fingerprint();
      this.ready = true;
      this.notice = settings.proxyMode === 'global' ? '当前是全局模式，切回智能规则模式后网站规则才参与分流。' : '';
      this.rebuild();
    } catch (e) { this.notice = '读取配置失败，请返回后重试；没有修改任何设置。'; }
    finally { this.busy = false; }
  }

  private current(): string[] { return this.kind === 'direct' ? this.direct : this.proxy; }
  private other(): string[] { return this.kind === 'direct' ? this.proxy : this.direct; }
  private fingerprint(): string { return JSON.stringify([this.proxy, this.direct]); }
  private rebuild(): void {
    const keyword = this.query.trim().toLowerCase();
    this.visible = this.current().filter((domain: string) => domain.includes(keyword) && (!this.selectedOnly || this.selected.includes(domain)));
    if (this.alphabetical) { this.visible.sort((a: string, b: string) => a.localeCompare(b)); }
    else { this.visible.sort((a: string, b: string) => Number(this.selected.includes(b)) - Number(this.selected.includes(a))); }
    this.dirty = this.fingerprint() !== this.initial;
  }
  private setCurrent(domains: string[]): void {
    if (this.kind === 'direct') { this.direct = domains; } else { this.proxy = domains; }
    this.selected = this.selected.filter((domain: string) => domains.includes(domain));
    this.rebuild();
  }
  private switchKind(kind: string): void {
    this.kind = kind;
    this.selected = [];
    this.selectedOnly = false;
    this.rebuild();
  }
  private toggle(domain: string): void {
    this.selected = this.selected.includes(domain) ? this.selected.filter((item: string) => item !== domain) : this.selected.concat([domain]);
    this.rebuild();
  }
  private add(text: string): boolean {
    const added = SiteRoutingPolicy.parseInput(text);
    if (added.length === 0) { this.toast('请至少输入一个域名'); return false; }
    for (const domain of added) {
      const error = SiteRoutingPolicy.domainError(domain);
      if (error.length > 0) { this.toast(`${domain}：${error}`); return false; }
      if (this.other().includes(domain)) { this.toast(`${domain} 已在另一份名单，请先从另一侧移除`); return false; }
    }
    const next = SiteRoutingPolicy.normalizeList(this.current().concat(added));
    if (next.length > SiteRoutingPolicy.MAX_SITES) { this.toast('每份名单最多 500 个域名'); return false; }
    this.setCurrent(next);
    this.toast(`已添加 ${added.length} 项到草稿，保存后生效`);
    return true;
  }
  private async remove(domains: string[]): Promise<void> {
    if (domains.length === 0 || this.busy) { return; }
    try {
      const result = await promptAction.showDialog({ title: '移除网站', message: `从当前名单移除 ${domains.length} 项？保存前不影响已生效规则。`,
        buttons: [{ text: '取消', color: $r('app.color.ui_text_secondary') }, { text: '移除', color: $r('app.color.ui_text_blue') }] });
      if (result.index === 1) { this.setCurrent(this.current().filter((domain: string) => !domains.includes(domain))); }
    } catch (e) { /* 取消保持草稿。 */ }
  }
  private async exportList(): Promise<void> {
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.current().join('\n')));
      this.toast('当前网站名单已复制，每行一个域名');
    } catch (e) { this.toast('复制失败，请重试'); }
  }
  private async save(): Promise<void> {
    if (!this.ready || this.busy || !this.dirty) { return; }
    const error = SiteRoutingPolicy.validationError(this.proxy, this.direct);
    if (error.length > 0) { this.toast(error); return; }
    this.busy = true;
    try {
      const result = await promptAction.showDialog({ title: '保存网站规则',
        message: '两份名单同时保存。立即应用优先热更新规则；热更新失败时可能回退重连。仅保存则下次连接或规则重新加载时生效。',
        buttons: [{ text: '取消', color: $r('app.color.ui_text_secondary') }, { text: '仅保存', color: $r('app.color.ui_text_blue') }, { text: '保存并应用', color: $r('app.color.ui_text_blue') }] });
      if (result.index === 0) { return; }
      const settings = await SettingsService.load();
      if (JSON.stringify(settings.forceProxySites) !== JSON.stringify(this.originalProxy)
        || JSON.stringify(settings.forceDirectSites) !== JSON.stringify(this.originalDirect)) {
        this.toast('网站规则已被其他页面修改，请返回重新打开后编辑'); return;
      }
      settings.forceProxySites = this.proxy.slice();
      settings.forceDirectSites = this.direct.slice();
      await SettingsService.save(settings);
      this.originalProxy = this.proxy.slice();
      this.originalDirect = this.direct.slice();
      this.initial = this.fingerprint();
      this.rebuild();
      this.notice = '已保存，下次连接或规则重新加载时生效。';
      if (result.index === 2) {
        try {
          const outcome = await this.orchestrator.applyRulesChanged('forceSitesChanged');
          this.notice = outcome === 'hot' ? '已保存并热更新规则，未重建 VPN。'
            : outcome === 'reconnect' ? '已保存并请求重连，请在主页确认连接状态。' : '已保存，下次连接生效。';
        } catch (e) { this.notice = '配置已保存，但立即应用失败，请到主页重新连接。'; }
      }
      if (settings.proxyMode === 'global') { this.notice += ' 当前全局模式，请切回智能规则模式使用网站规则。'; }
      this.toast(this.notice);
    } catch (e) { this.toast('保存未完成，请重试'); }
    finally { this.busy = false; }
  }
  private toast(message: string): void { promptAction.showToast({ message: message }); }
  private async back(): Promise<void> {
    if (this.busy) { return; }
    if (!this.dirty) { router.back(); return; }
    try {
      const result = await promptAction.showDialog({ title: '尚未保存', message: '离开会丢弃两份网站名单的草稿。',
        buttons: [{ text: '继续编辑', color: $r('app.color.ui_text_blue') }, { text: '放弃并离开', color: $r('app.color.ui_text_secondary') }] });
      if (result.index === 1) { router.back(); }
    } catch (e) { /* 保持页面。 */ }
  }
  onBackPress(): boolean { this.back(); return true; }

  @Builder
  KindChip(kind: string, label: string, count: number) {
    Text(`${label} ${count}`).fontSize(13).fontWeight(FontWeight.Medium).layoutWeight(1)
      .textAlign(TextAlign.Center).padding({ top: 12, bottom: 12 }).borderRadius(14)
      .fontColor(this.kind === kind ? Ui.textBlue : Ui.textSecondary)
      .backgroundColor(this.kind === kind ? Ui.selectedBackground : Color.Transparent).onClick(() => this.switchKind(kind))
  }
  build() {
    Stack() {
      Column().width('100%').height('100%').linearGradient({ angle: 135, colors: Ui.backdropColors })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      Column({ space: 12 }) {
        Row() {
          Text('‹').fontSize(30).fontColor(Ui.textPrimary).padding({ left: 8, right: 18 }).onClick(() => this.back())
          Text('网站分流').fontSize(20).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
          Blank()
          Button(this.busy ? '请稍候' : '保存').fontSize(14).enabled(this.ready && !this.busy && this.dirty).onClick(() => this.save())
        }.height(50).width('100%')
        Row({ space: 4 }) {
          this.KindChip('proxy', '强制代理', this.proxy.length)
          this.KindChip('direct', '强制直连', this.direct.length)
        }.padding(4).width('100%').borderRadius(17).backgroundColor(Ui.inputBackground).enabled(this.ready && !this.busy)
        Column({ space: 6 }) {
          Text(this.kind === 'direct' ? '以下网站使用直连策略' : '以下网站使用代理策略').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
          Text('两份名单同时生效，切换标签不会关闭另一份。规则匹配域名及子域名；同名冲突需移除一侧。绕过 VPN 的应用不受此设置影响。')
            .fontSize(12).fontColor(Ui.textSecondary)
          Text('勾选仅用于批量操作，不是启用开关。网站规则位于广告 / 自定义规则之后；网站名单之间重叠时直连优先。')
            .fontSize(11).fontColor(Ui.textTertiary)
        }.width('100%').padding(16).alignItems(HorizontalAlign.Start).borderRadius(20).backgroundColor(Ui.surfaceTranslucent)
        TextInput({ text: this.query, placeholder: '搜索域名' }).height(42).fontColor(Ui.textPrimary).backgroundColor(Ui.inputBackground)
          .onChange((value: string) => { this.query = value; this.rebuild(); })
        Row() {
          Text(this.selectedOnly ? `已勾选 ${this.selected.length} ▾` : `当前名单 ${this.current().length} ▾`).fontSize(13).fontColor(Ui.textBlue)
            .onClick(() => { this.selectedOnly = !this.selectedOnly; this.rebuild(); })
          Blank()
          Text(this.alphabetical ? '域名排序' : '已选置顶').fontSize(12).fontColor(Ui.textSecondary)
            .onClick(() => { this.alphabetical = !this.alphabetical; this.rebuild(); })
        }.width('100%')
        List({ space: 8 }) {
          ForEach(this.visible, (domain: string) => {
            ListItem() {
              Row({ space: 10 }) {
                Text(this.kind === 'direct' ? '↘' : '↗').fontSize(20).fontColor(Ui.textBlue)
                Column({ space: 4 }) {
                  Text(domain || '（空域名）').fontSize(15).fontColor(Ui.textPrimary).wordBreak(WordBreak.BREAK_ALL)
                  if (this.other().includes(domain) || SiteRoutingPolicy.domainError(domain).length > 0) {
                    Text(this.other().includes(domain) ? '两份名单重复，请移除一侧' : '格式无效，请移除后重新添加').fontSize(11).fontColor(Ui.textError)
                  }
                  Text('移除').fontSize(11).fontColor(Ui.textBlue).padding({ top: 5, bottom: 5 }).onClick(() => this.remove([domain]))
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                Checkbox({ name: domain }).select(this.selected.includes(domain)).selectedColor(Ui.primaryBlueFill)
                  .onChange((value: boolean) => { if (value !== this.selected.includes(domain)) { this.toggle(domain); } })
              }.padding(14).width('100%').borderRadius(18).backgroundColor(Ui.surfaceTranslucent)
            }
          }, (domain: string) => `${domain}:${this.selected.includes(domain)}`)
          if (this.visible.length === 0) {
            ListItem() { Text('没有匹配的网站，可点击下方添加 / 导入。').fontSize(13).fontColor(Ui.textSecondary).padding(22) }
          }
        }.layoutWeight(1).width('100%').enabled(this.ready && !this.busy)
        if (this.notice.length > 0) { Text(this.notice).fontSize(11).fontColor(Ui.textBlue).width('100%') }
        Row({ space: 8 }) {
          Button('＋ 添加 / 导入').fontSize(12).layoutWeight(2).onClick(() => this.dialog.open())
          Button('导出名单').fontSize(12).layoutWeight(1).onClick(() => this.exportList())
        }.width('100%').enabled(this.ready && !this.busy)
        Row({ space: 10 }) {
          Text('全选结果').fontSize(12).fontColor(Ui.textBlue).onClick(() => {
            this.selected = SiteRoutingPolicy.normalizeList(this.selected.concat(this.visible)); this.rebuild();
          })
          Text('取消勾选').fontSize(12).fontColor(Ui.textSecondary).onClick(() => { this.selected = []; this.rebuild(); })
          Text(`移除 ${this.selected.length} 项`).fontSize(12).fontColor(Ui.textBlue).onClick(() => this.remove(this.selected.slice()))
        }.width('100%').enabled(this.ready && !this.busy)
        Text(this.dirty ? '草稿未保存' : '无未保存更改').fontSize(10).fontColor(Ui.textTertiary)
      }.width('100%').height('100%').padding({ left: 18, right: 18, top: 8, bottom: 16 }).constraintSize({ maxWidth: Ui.pageMaxWidth })
    }.width('100%').height('100%')
  }
}
