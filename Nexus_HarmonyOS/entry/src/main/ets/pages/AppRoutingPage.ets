import { router, promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { Ui } from '../theme/UiTokens';
import { AppSettings } from '../commons/models/AppSettings';
import { AppRoutingCustomApp, AppRoutingPolicy } from '../commons/services/AppRoutingPolicy';
import { SettingsService } from '../commons/services/SettingsService';
import { ConnectionOrchestrator } from '../commons/services/ConnectionOrchestrator';

class RoutingRow {
  bundleName: string = '';
  label: string = '';
  source: string = '';
  selected: boolean = false;
}

@CustomDialog
struct RoutingInputDialog {
  controller?: CustomDialogController;
  @State label: string = '';
  @State packages: string = '';
  onAdd: (packages: string, label: string) => boolean = () => false;
  build() {
    Column({ space: 14 }) {
      Text('添加 / 批量导入').fontSize(19).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
      Text('每行一个鸿蒙应用包名；名称备注只用于单个应用。请勿使用 Android 包名代替鸿蒙包名。')
        .fontSize(12).fontColor(Ui.textSecondary)
      TextInput({ text: this.label, placeholder: '名称备注（可选）' }).maxLength(40)
        .onChange((v: string) => { this.label = v; }).backgroundColor(Ui.inputBackground).fontColor(Ui.textPrimary)
      TextArea({ text: this.packages, placeholder: 'com.tencent.wechat\ncom.ss.hm.ugc.aweme' })
        .height(180).maxLength(65536).fontColor(Ui.textPrimary).backgroundColor(Ui.inputBackground)
        .onChange((v: string) => { this.packages = v; })
      Row({ space: 12 }) {
        Button('取消').layoutWeight(1).onClick(() => this.controller?.close())
        Button('添加到当前名单').layoutWeight(2).onClick(() => {
          if (this.onAdd(this.packages, this.label)) { this.controller?.close(); }
        })
      }
    }.padding(22).borderRadius(24).backgroundColor(Ui.surfaceMuted)
  }
}

/** 应用接管范围：先编辑草稿，统一保存；不将目录伪装为已安装列表。 */
@Entry
@Component
struct AppRoutingPage {
  @State mode: string = 'all';
  @State included: string[] = [];
  @State excluded: string[] = [];
  @State customApps: AppRoutingCustomApp[] = [];
  @State needsReview: boolean = false;
  @State query: string = '';
  @State selectedOnly: boolean = false;
  @State nameSort: boolean = false;
  @State rows: RoutingRow[] = [];
  @State busy: boolean = true;
  @State ready: boolean = false;
  @State dirty: boolean = false;
  @State resultText: string = '';
  private original: string = '';
  private orchestrator: ConnectionOrchestrator = ConnectionOrchestrator.instance();
  private inputDialog: CustomDialogController = new CustomDialogController({
    builder: RoutingInputDialog({ onAdd: (text: string, label: string): boolean => this.addPackages(text, label) }),
    autoCancel: false
  });

  aboutToAppear(): void { this.load(); }

  private async load(): Promise<void> {
    try {
      const context = getContext(this) as Context;
      this.orchestrator.init(context);
      await SettingsService.init(context);
      const settings = await SettingsService.load();
      this.mode = settings.appRoutingMode;
      this.included = settings.includedApps.slice();
      this.excluded = settings.excludedApps.slice();
      this.customApps = settings.appRoutingCustomApps.slice();
      this.needsReview = settings.appRoutingNeedsReview;
      this.original = this.fingerprint();
      this.ready = true;
      this.rebuild();
    } catch (e) {
      this.resultText = '读取配置失败，请返回后重试；未更改任何设置。';
    } finally { this.busy = false; }
  }

  private fingerprint(): string {
    return JSON.stringify([this.mode, this.included, this.excluded, this.customApps, this.needsReview]);
  }

  private current(): string[] { return this.mode === 'include' ? this.included : this.excluded; }

  private setCurrent(packages: string[]): void {
    if (this.mode === 'include') { this.included = packages; } else { this.excluded = packages; }
    this.rebuild();
  }

  private addRow(rows: RoutingRow[], name: string, label: string, source: string): void {
    if (rows.some((r: RoutingRow) => r.bundleName === name)) { return; }
    const row = new RoutingRow();
    row.bundleName = name;
    row.label = label.length > 0 ? label : name;
    row.source = source;
    row.selected = this.mode !== 'all' && this.current().includes(name);
    rows.push(row);
  }

  private rebuild(): void {
    const rows: RoutingRow[] = [];
    // 仅保留原项目已有的两项鸿蒙包名，不猜测更多应用包名。
    this.addRow(rows, 'com.tencent.wechat', '微信', '常用目录 · 安装状态未确认');
    this.addRow(rows, 'com.ss.hm.ugc.aweme', '抖音', '常用目录 · 安装状态未确认');
    for (const app of this.customApps) { this.addRow(rows, app.bundleName, app.label, '手动添加 · 安装状态未确认'); }
    for (const name of this.included.concat(this.excluded)) { this.addRow(rows, name, '', '已有名单 · 安装状态未确认'); }
    const keyword = this.query.trim().toLowerCase();
    this.rows = rows.filter((r: RoutingRow) => (!this.selectedOnly || r.selected)
      && (r.label.toLowerCase().includes(keyword) || r.bundleName.toLowerCase().includes(keyword)))
      .sort((a: RoutingRow, b: RoutingRow) => {
        if (!this.nameSort && a.selected !== b.selected) { return a.selected ? -1 : 1; }
        return a.label.localeCompare(b.label);
      });
    this.dirty = this.fingerprint() !== this.original;
  }

  private selectMode(mode: string): void {
    this.mode = mode;
    this.needsReview = false;
    this.selectedOnly = false;
    this.resultText = '';
    this.rebuild();
  }

  private toggle(name: string): void {
    if (this.mode === 'all' || this.busy) { return; }
    const current = this.current();
    const next = current.includes(name) ? current.filter((p: string) => p !== name) : current.concat([name]);
    if (next.length > 256 && next.length > current.length) { this.toast('每份名单最多 256 个应用'); return; }
    this.setCurrent(next);
  }

  private selectVisible(select: boolean): void {
    const names = this.rows.map((r: RoutingRow) => r.bundleName);
    const next = select ? AppRoutingPolicy.normalizePackages(this.current().concat(names))
      : this.current().filter((name: string) => !names.includes(name));
    if (next.length > 256 && next.length > this.current().length) { this.toast('当前结果超出 256 个上限，请缩小搜索范围'); return; }
    this.setCurrent(next);
  }

  private addPackages(text: string, label: string): boolean {
    const packages = AppRoutingPolicy.normalizePackages(text.split(new RegExp('\\r?\\n')).filter((line: string) => line.trim().length > 0));
    if (packages.length === 0) { this.toast('请至少输入一个包名'); return false; }
    const next = AppRoutingPolicy.normalizePackages(this.current().concat(packages));
    const error = AppRoutingPolicy.validationError(this.mode,
      this.mode === 'include' ? next : this.included,
      this.mode === 'exclude' ? next : this.excluded, this.needsReview);
    if (error.length > 0) { this.toast(error); return false; }
    const apps = this.customApps.slice();
    for (const name of packages) {
      if (!apps.some((app: AppRoutingCustomApp) => app.bundleName === name)) {
        const app = new AppRoutingCustomApp();
        app.bundleName = name;
        app.label = packages.length === 1 ? label.trim() : '';
        apps.push(app);
      }
    }
    if (apps.length > 512) { this.toast('手动目录最多 512 项，请先整理已有条目'); return false; }
    this.customApps = apps;
    this.setCurrent(next);
    this.toast(`已添加到草稿：${packages.length} 项，保存后生效`);
    return true;
  }

  private async removeEntry(name: string): Promise<void> {
    if (this.busy || !this.ready) { return; }
    try {
      const response = await promptAction.showDialog({ title: '移除应用条目',
        message: `${name}\n从两份名单及手动目录移除（常用目录仍会保留）。保存前不会改变当前 VPN。`,
        buttons: [{ text: '取消', color: $r('app.color.ui_text_secondary') }, { text: '移除', color: $r('app.color.ui_text_blue') }] });
      if (response.index !== 1) { return; }
      this.included = this.included.filter((p: string) => p !== name);
      this.excluded = this.excluded.filter((p: string) => p !== name);
      this.customApps = this.customApps.filter((app: AppRoutingCustomApp) => app.bundleName !== name);
      this.rebuild();
    } catch (e) { /* 取消不改变草稿。 */ }
  }

  private async exportList(): Promise<void> {
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.current().join('\n')));
      this.toast('当前名单已复制，每行一个包名');
    } catch (e) { this.toast('复制失败，请重试'); }
  }

  private async save(): Promise<void> {
    if (this.busy || !this.ready || !this.dirty) { return; }
    const error = AppRoutingPolicy.validationError(this.mode, this.included, this.excluded, this.needsReview);
    if (error.length > 0) { this.toast(error); return; }
    this.busy = true;
    try {
      const response = await promptAction.showDialog({
        title: '应用分流变更',
        message: '保存不会改变网站规则。立即应用会在 VPN 已连接时重建隧道，网络可能短暂中断；也可以仅保存供下次连接使用。',
        buttons: [{ text: '取消', color: $r('app.color.ui_text_secondary') }, { text: '仅保存', color: $r('app.color.ui_text_blue') }, { text: '保存并应用', color: $r('app.color.ui_text_blue') }]
      });
      if (response.index === 0) { return; }
      // 加载最新设置，只覆盖本页字段，避免旧页面快照覆盖节点等其他设置。
      const settings = await SettingsService.load();
      settings.appRoutingMode = this.mode;
      settings.appRoutingNeedsReview = false;
      settings.includedApps = this.included.slice();
      settings.excludedApps = this.excluded.slice();
      settings.appRoutingCustomApps = this.customApps.slice();
      await SettingsService.save(settings);
      this.original = this.fingerprint();
      this.rebuild();
      this.resultText = '已保存，下次连接生效；当前隧道接管范围尚未改变。';
      if (response.index === 2) {
        try {
          const restarted = await this.orchestrator.restartIfConnected('appRoutingChanged');
          this.resultText = restarted ? '已保存并请求重连，请在主页确认连接结果。' : '已保存，下次连接生效。';
        } catch (e) { this.resultText = '配置已保存，但重连未成功，请回主页手动连接。'; }
      }
      this.toast(this.resultText);
    } catch (e) { this.toast('保存未完成，请重试'); }
    finally { this.busy = false; }
  }

  private toast(message: string): void { promptAction.showToast({ message: message }); }

  private async back(): Promise<void> {
    if (this.busy) { return; }
    if (!this.dirty) { router.back(); return; }
    try {
      const response = await promptAction.showDialog({ title: '尚未保存', message: '离开会丢弃本页草稿，不会改变已保存的应用分流。',
        buttons: [{ text: '继续编辑', color: $r('app.color.ui_text_blue') }, { text: '放弃并离开', color: $r('app.color.ui_text_secondary') }] });
      if (response.index === 1) { router.back(); }
    } catch (e) { /* 系统取消对话框时留在编辑页。 */ }
  }

  onBackPress(): boolean { this.back(); return true; }

  @Builder
  ModeChip(mode: string, label: string) {
    Text(label).fontSize(13).fontWeight(this.mode === mode ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(this.mode === mode ? Ui.textBlue : Ui.textSecondary)
      .padding({ top: 12, bottom: 12 }).layoutWeight(1).textAlign(TextAlign.Center).borderRadius(13)
      .backgroundColor(this.mode === mode ? Ui.selectedBackground : Color.Transparent)
      .onClick(() => this.selectMode(mode))
  }

  build() {
    Stack() {
      Column().width('100%').height('100%').linearGradient({ angle: 135, colors: Ui.backdropColors })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      Column({ space: 12 }) {
        Row() {
          Text('‹').fontSize(30).fontColor(Ui.textPrimary).padding({ left: 8, right: 18 }).onClick(() => this.back())
          Text('应用分流').fontSize(20).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
          Blank()
          Button(this.busy ? '请稍候' : '保存').fontSize(14).enabled(this.ready && !this.busy && this.dirty)
            .backgroundColor(Ui.primaryBlueFill).onClick(() => this.save())
        }.width('100%').height(50)
        Row({ space: 4 }) {
          this.ModeChip('all', '所有应用')
          this.ModeChip('exclude', '排除所选')
          this.ModeChip('include', '仅限所选')
        }.width('100%').padding(4).borderRadius(17).backgroundColor(Ui.inputBackground).enabled(this.ready && !this.busy)
        Column({ space: 7 }) {
          Text(this.needsReview ? '旧名单存在冲突，请先明确选择一种模式'
            : this.mode === 'all' ? '所有应用进入 VPN'
            : `${this.mode === 'include' ? '仅接管' : '已排除'} ${this.current().length} 个应用`)
            .fontSize(16).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary).width('100%')
          Text(this.mode === 'all' ? '两份名单仍保留，但当前均不启用。'
            : this.mode === 'include' ? '仅所选应用进入 VPN，其余应用直接联网。' : '所选应用直接联网，其余应用进入 VPN。')
            .fontSize(12).fontColor(Ui.textSecondary).width('100%')
          Text('进入 VPN 后仍按规则 / 全局模式处理，不代表强制走代理节点。')
            .fontSize(11).fontColor(Ui.textTertiary).width('100%')
        }.width('100%').padding(16).borderRadius(20).backgroundColor(Ui.surfaceTranslucent)
          .borderWidth(1).borderColor(Ui.glassEdge)
        Text('当前 SDK 不支持读取完整安装列表。以下是常用目录与手动名单，不代表本机已安装；字形为名称标识，并非应用图标。')
          .fontSize(11).fontColor(Ui.textTertiary).width('100%')
        TextInput({ text: this.query, placeholder: '搜索名称或鸿蒙包名' })
          .fontColor(Ui.textPrimary).backgroundColor(Ui.inputBackground).height(42)
          .onChange((v: string) => { this.query = v; this.rebuild(); })
        Row({ space: 12 }) {
          Text(this.selectedOnly ? `已选择 (${this.current().length}) ▾` : `可用目录 (${this.rows.length}) ▾`)
            .fontColor(Ui.textBlue).fontSize(13).onClick(() => { this.selectedOnly = !this.selectedOnly; this.rebuild(); })
          Blank()
          Text(this.nameSort ? '名称排序' : '已选置顶').fontSize(12).fontColor(Ui.textSecondary)
            .onClick(() => { this.nameSort = !this.nameSort; this.rebuild(); })
        }.width('100%')
        List({ space: 8 }) {
          ForEach(this.rows, (row: RoutingRow) => {
            ListItem() {
              Row({ space: 12 }) {
                Text(row.label.substring(0, 1)).fontSize(20).fontColor(Ui.textBlue)
                  .width(42).height(42).textAlign(TextAlign.Center).borderRadius(13).backgroundColor(Ui.selectedBackground)
                Column({ space: 4 }) {
                  Text(row.label).fontSize(15).fontWeight(FontWeight.Medium).fontColor(Ui.textPrimary).maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(row.bundleName).fontSize(11).fontColor(Ui.textSecondary).maxLines(2).wordBreak(WordBreak.BREAK_ALL)
                  Text(row.source).fontSize(10).fontColor(Ui.textTertiary)
                  Text('移除条目').fontSize(11).fontColor(Ui.textBlue)
                    .padding({ top: 5, bottom: 5 }).onClick(() => this.removeEntry(row.bundleName))
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                Checkbox({ name: row.bundleName }).select(row.selected).selectedColor(Ui.primaryBlueFill)
                  .enabled(this.mode !== 'all' && !this.busy).onChange((checked: boolean) => {
                    if (checked !== row.selected) { this.toggle(row.bundleName); }
                  })
              }.width('100%').padding(12).borderRadius(18).backgroundColor(Ui.surfaceTranslucent)
            }
          }, (row: RoutingRow) => `${row.bundleName}:${row.selected}`)
          if (this.rows.length === 0) {
            ListItem() { Text('没有匹配项，可手动添加鸿蒙包名。').fontColor(Ui.textSecondary).padding(22) }
          }
        }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
        if (this.resultText.length > 0) { Text(this.resultText).fontSize(12).fontColor(Ui.textBlue).width('100%') }
        Row({ space: 8 }) {
          Button('＋ 添加 / 导入').fontSize(12).layoutWeight(2).onClick(() => this.inputDialog.open())
          Button('导出').fontSize(12).layoutWeight(1).onClick(() => this.exportList())
        }.width('100%').enabled(this.ready && !this.busy && this.mode !== 'all')
        Row({ space: 16 }) {
          Text('全选当前结果').fontSize(12).fontColor(Ui.textBlue).onClick(() => this.selectVisible(true))
          Text('取消当前结果').fontSize(12).fontColor(Ui.textSecondary).onClick(() => this.selectVisible(false))
          Blank()
          Text(this.dirty ? '草稿未保存' : '无未保存更改').fontSize(10).fontColor(Ui.textTertiary)
        }.width('100%').enabled(this.ready && !this.busy && this.mode !== 'all')
      }.width('100%').height('100%').padding({ left: 18, right: 18, top: 8, bottom: 16 })
        .constraintSize({ maxWidth: Ui.pageMaxWidth })
    }.width('100%').height('100%')
  }
}
