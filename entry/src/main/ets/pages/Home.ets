import { VpnAuthorization } from '../data/VpnAuthorization';
import { common, Want } from '@kit.AbilityKit';
import { vpnExtension } from '@kit.NetworkKit';
import { FlClashStore, Profile, ProxyNode, ConnectionItem, RuleItem } from '../data/FlClashStore';

@Entry
@Component
struct Home {
  private store: FlClashStore = FlClashStore.get();
  @State tab: number = 0;
  @State page: string = '';
  @State busy: boolean = false;
  @State connected: boolean = false;
  @State version: string = '';
  @State error: string = '';
  @State mode: string = 'rule';
  @State profiles: Profile[] = [];
  @State proxies: ProxyNode[] = [];
  @State connections: ConnectionItem[] = [];
  @State rules: RuleItem[] = [];
  @State controller: string = 'http://127.0.0.1:9090';
  @State secret: string = '';
  @State profileName: string = '';
  @State profileUrl: string = '';
  @State profileContent: string = '';
  @State editingId: number = 0;
  @State selectedProfile: number = 0;
  @State nativeStatus: string = 'stopped';

  aboutToAppear(): void { this.initialize(); }

  private async initialize(): Promise<void> {
    try {
      await this.store.init(this.getUIContext().getHostContext() as common.UIAbilityContext);
      this.controller = this.store.controller;
      this.secret = this.store.secret;
      this.profiles = [...this.store.profiles];
      this.selectedProfile = this.store.selectedProfile;
      this.nativeStatus = await this.store.getNativeStatus();
      await this.refresh();
    } catch (e) { this.showError(e); }
  }

  private showError(error: Object): void {
    this.error = String(error);
    this.getUIContext().getPromptAction().showToast({ message: this.error });
  }

  private async refresh(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    try {
      this.nativeStatus = await this.store.getNativeStatus();
      if (this.nativeStatus === 'error') {
        this.error = await this.store.getNativeError();
      }
      this.version = await this.store.checkController();
      this.connected = true;
      this.error = '';
      try {
        this.mode = await this.store.getMode();
        if (this.tab === 2) { this.proxies = await this.store.getProxies(); }
        if (this.tab === 3) { this.connections = await this.store.getConnections(); }
        if (this.tab === 4) { this.rules = await this.store.getRules(); }
      } catch (e) { this.error = String(e); }
    } catch (e) {
      this.connected = false;
      this.error = this.nativeStatus === 'error' ? await this.store.getNativeError() : String(e);
    } finally { this.busy = false; }
  }

  private vpnWant(): Want {
    return {
      deviceId: '',
      bundleName: 'com.flclash.harmony',
      abilityName: 'FlClashVpnExtension'
    };
  }

  private async startVpn(): Promise<void> {
    if (this.busy) { return; }
    try {
      this.busy = true;
      await this.store.prepareNativeProfile();
      this.controller = this.store.controller;
      this.secret = this.store.secret;
      this.nativeStatus = 'starting';
      VpnAuthorization.subscribe((authorized: boolean) => {
        if (!authorized) {
          this.nativeStatus = 'error';
          this.store.setNativeStatus('error', '用户未授权 VPN 连接')
            .catch((error: Error) => { this.showError(error); });
          this.showError(new Error('用户未授权 VPN 连接'));
        }
        VpnAuthorization.unsubscribe();
      });
      await vpnExtension.startVpnExtensionAbility(this.vpnWant());
      setTimeout(() => { this.waitForNativeStartup(0); }, 1000);
    } catch (error) {
      VpnAuthorization.unsubscribe();
      this.nativeStatus = 'error';
      await this.store.setNativeStatus('error', String(error));
      this.showError(error);
    } finally { this.busy = false; }
  }

  private async waitForNativeStartup(attempt: number): Promise<void> {
    await this.refresh();
    if (this.nativeStatus === 'starting' && attempt < 19) {
      setTimeout(() => { this.waitForNativeStartup(attempt + 1); }, 1000);
    }
  }

  private async stopVpn(): Promise<void> {
    try {
      await vpnExtension.stopVpnExtensionAbility(this.vpnWant());
      this.nativeStatus = 'stopped';
      await this.store.setNativeStatus('stopped');
      await this.refresh();
    } catch (error) { this.showError(error); }
  }

  private async switchMode(value: string): Promise<void> {
    try {
      await this.store.setMode(value);
      this.mode = value;
    } catch (e) { this.showError(e); }
  }

  private async chooseProxy(group: string, name: string): Promise<void> {
    try {
      await this.store.selectProxy(group, name);
      this.proxies = await this.store.getProxies();
    } catch (e) { this.showError(e); }
  }

  private async testProxy(group: ProxyNode): Promise<void> {
    try {
      const delay = await this.store.testDelay(group.name);
      this.proxies = this.proxies.map((item: ProxyNode): ProxyNode => {
        if (item.name !== group.name) { return item; }
        const updated: ProxyNode = { name: item.name, type: item.type, now: item.now, all: item.all, delay };
        return updated;
      });
    } catch (e) { this.showError(e); }
  }

  private async saveController(): Promise<void> {
    this.store.controller = this.controller.trim();
    this.store.secret = this.secret.trim();
    await this.store.save();
    await this.refresh();
    if (!this.connected) { this.showError(this.error); }
  }

  private async importUrl(): Promise<void> {
    try {
      this.busy = true;
      await this.store.addFromUrl(this.profileUrl, this.profileName);
      this.profiles = [...this.store.profiles];
      this.selectedProfile = this.store.selectedProfile;
      this.profileName = '';
      this.profileUrl = '';
      this.page = '';
    } catch (e) { this.showError(e); }
    finally { this.busy = false; }
  }

  private async importFile(): Promise<void> {
    try {
      await this.store.addFromFile(this.getUIContext().getHostContext() as common.UIAbilityContext);
      this.profiles = [...this.store.profiles];
      this.selectedProfile = this.store.selectedProfile;
    } catch (e) { this.showError(e); }
  }

  private async saveProfile(): Promise<void> {
    try {
      const index = this.store.profiles.findIndex((item: Profile) => item.id === this.editingId);
      if (index >= 0) {
        if (this.profileContent.trim().length === 0) { throw new Error('配置内容为空'); }
        this.store.profiles[index].content = this.profileContent;
        this.store.profiles[index].name = this.profileName.trim() || '未命名配置';
        this.store.profiles[index].updatedAt = Date.now();
      }
      await this.store.save();
      this.profiles = [...this.store.profiles];
      this.page = '';
    } catch (e) { this.showError(e); }
  }

  private async updateProfile(id: number): Promise<void> {
    try {
      this.busy = true;
      await this.store.updateProfile(id);
      this.profiles = [...this.store.profiles];
    } catch (e) { this.showError(e); }
    finally { this.busy = false; }
  }

  private async deleteProfile(id: number): Promise<void> {
    await this.store.removeProfile(id);
    this.profiles = [...this.store.profiles];
    this.selectedProfile = this.store.selectedProfile;
    this.page = '';
  }

  private async selectProfile(id: number): Promise<void> {
    this.store.selectedProfile = id;
    await this.store.save();
    this.selectedProfile = id;
  }

  private openEditor(profile: Profile): void {
    this.editingId = profile.id;
    this.profileName = profile.name;
    this.profileContent = profile.content;
    this.page = 'edit';
  }

  private currentProfileName(): string {
    const selected = this.profiles.find((item: Profile) => item.id === this.selectedProfile);
    return selected ? selected.name : '尚未选择配置';
  }

  private formatBytes(value: number): string {
    if (value >= 1048576) { return `${(value / 1048576).toFixed(1)} MB`; }
    if (value >= 1024) { return `${(value / 1024).toFixed(1)} KB`; }
    return `${value} B`;
  }

  @Builder
  private heading(title: string, subtitle: string) {
    Row() {
      Column({ space: 4 }) {
        Text(title).fontSize(26).fontWeight(FontWeight.Bold).fontColor('#192438');
        Text(subtitle).fontSize(13).fontColor('#6D7789');
      }.alignItems(HorizontalAlign.Start).layoutWeight(1);
      Button('刷新').fontSize(13).backgroundColor('#E8EEFB').fontColor('#34548B')
        .onClick(() => { this.refresh(); });
    }.width('100%').padding({ left: 20, right: 20, top: 20, bottom: 18 });
  }

  @Builder
  private emptyState(title: string, detail: string) {
    Column({ space: 8 }) {
      Text(title).fontSize(17).fontWeight(FontWeight.Medium).fontColor('#536074');
      Text(detail).fontSize(13).fontColor('#8791A0').textAlign(TextAlign.Center);
    }.width('100%').padding({ top: 80, left: 24, right: 24 });
  }

  @Builder
  private modeButton(value: string, label: string) {
    Button(label).layoutWeight(1).fontSize(14)
      .backgroundColor(this.mode === value ? '#3467D5' : '#E8EEFB')
      .fontColor(this.mode === value ? Color.White : '#34548B')
      .enabled(this.connected).onClick(() => { this.switchMode(value); });
  }

  @Builder
  private dashboard() {
    Column({ space: 16 }) {
      this.heading('仪表盘', 'OHClash · 鸿蒙版');
      Column({ space: 16 }) {
        Column({ space: 12 }) {
          Row({ space: 10 }) {
            Text('●').fontColor(this.connected ? '#16A36C' : '#D76A63').fontSize(16);
            Text(this.connected ? '控制器已连接' : '控制器未连接').fontSize(18).fontWeight(FontWeight.Bold);
          }.width('100%');
          Text(this.connected ? `mihomo ${this.version}` : '启动本机 VPN，或在设置中连接外部控制器。')
            .fontSize(14).fontColor('#6D7789').width('100%');
          if (!this.connected && this.error.length > 0) {
            Text(this.error).fontSize(12).fontColor('#B45650').maxLines(3).width('100%');
          }
          Text(`本机 VPN：${this.nativeStatus === 'running' ? '运行中' : this.nativeStatus === 'starting' ? '启动中' : this.nativeStatus === 'error' ? '启动失败' : '未运行'}`)
            .fontSize(13).fontColor('#536074').width('100%');
          Row({ space: 10 }) {
            Button('启动 VPN').backgroundColor('#3467D5').fontColor(Color.White)
              .enabled(this.nativeStatus !== 'running' && this.nativeStatus !== 'starting' && !this.busy)
              .onClick(() => { this.startVpn(); });
            Button('停止 VPN').backgroundColor('#E8EEFB').fontColor('#34548B')
              .enabled(this.nativeStatus === 'running' || this.nativeStatus === 'starting')
              .onClick(() => { this.stopVpn(); });
          }.width('100%');
        }.padding(18).borderRadius(18).backgroundColor(Color.White).width('100%');
        Column({ space: 12 }) {
          Text('出站模式').fontSize(18).fontWeight(FontWeight.Bold).width('100%');
          Row({ space: 8 }) {
            this.modeButton('rule', '规则');
            this.modeButton('global', '全局');
            this.modeButton('direct', '直连');
          }.width('100%');
        }.padding(18).borderRadius(18).backgroundColor(Color.White).width('100%');
        Column({ space: 8 }) {
          Text('当前配置').fontSize(18).fontWeight(FontWeight.Bold).width('100%');
          Text(this.currentProfileName()).fontSize(15).fontColor('#536074').width('100%');
          Text('点击“启动 VPN”后，将使用当前选择的配置。切换配置后需重新启动 VPN。')
            .fontSize(12).fontColor('#8791A0').width('100%');
        }.padding(18).borderRadius(18).backgroundColor(Color.White).width('100%');
      }.padding({ left: 16, right: 16 });
    }.width('100%');
  }

  @Builder
  private profilesPage() {
    Column() {
      this.heading('配置', `${this.profiles.length} 个本地配置`);
      Row({ space: 10 }) {
        Button('添加订阅').backgroundColor('#3467D5').onClick(() => { this.page = 'add'; });
        Button('导入文件').backgroundColor('#E8EEFB').fontColor('#34548B')
          .onClick(() => { this.importFile(); });
      }.width('100%').padding({ left: 16, right: 16, bottom: 12 });
      if (this.profiles.length === 0) {
        this.emptyState('还没有配置', '通过订阅链接或本地 YAML 文件添加。');
      } else {
        List({ space: 10 }) {
          ForEach(this.profiles, (profile: Profile) => {
            ListItem() {
              Column({ space: 10 }) {
                Row({ space: 8 }) {
                  Text(profile.id === this.selectedProfile ? '●' : '○').fontColor('#3467D5').fontSize(18);
                  Text(profile.name).fontSize(17).fontWeight(FontWeight.Medium).layoutWeight(1);
                }.width('100%');
                Text(profile.source || '本地文件').fontSize(12).fontColor('#8791A0')
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%');
                Row({ space: 8 }) {
                  Button('选择').fontSize(12).backgroundColor('#E8EEFB').fontColor('#34548B')
                    .onClick(() => { this.selectProfile(profile.id); });
                  Button('编辑').fontSize(12).backgroundColor('#E8EEFB').fontColor('#34548B')
                    .onClick(() => { this.openEditor(profile); });
                  if (profile.source.length > 0) {
                    Button('更新').fontSize(12).backgroundColor('#E8EEFB').fontColor('#34548B')
                      .onClick(() => { this.updateProfile(profile.id); });
                  }
                }.width('100%');
              }.padding(16).borderRadius(16).backgroundColor(Color.White).width('100%');
            }
          }, (profile: Profile) => profile.id.toString());
        }.width('100%').layoutWeight(1).padding({ left: 16, right: 16, bottom: 16 });
      }
    }.width('100%').layoutWeight(1);
  }

  @Builder
  private proxiesPage() {
    Column() {
      this.heading('代理', this.connected ? `${this.proxies.length} 个代理组` : '连接控制器后可查看');
      if (this.proxies.length === 0) {
        this.emptyState('没有代理组', '连接 mihomo 控制器并刷新。');
      } else {
        List({ space: 10 }) {
          ForEach(this.proxies, (group: ProxyNode) => {
            ListItem() {
              Column({ space: 10 }) {
                Row() {
                  Text(group.name).fontSize(17).fontWeight(FontWeight.Bold).layoutWeight(1);
                  Text(group.delay > 0 ? `${group.delay} ms` : group.type).fontSize(12).fontColor('#8791A0');
                }.width('100%');
                Text(`当前：${group.now}`).fontSize(13).fontColor('#3467D5').width('100%');
                Button('测速').fontSize(12).height(32).backgroundColor('#E8EEFB').fontColor('#34548B')
                  .onClick(() => { this.testProxy(group); });
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(group.all, (name: string) => {
                    Button(name).fontSize(12).height(34).margin({ right: 8, bottom: 8 })
                      .backgroundColor(group.now === name ? '#3467D5' : '#E8EEFB')
                      .fontColor(group.now === name ? Color.White : '#34548B')
                      .onClick(() => { this.chooseProxy(group.name, name); });
                  }, (name: string) => name);
                }.width('100%');
              }.padding(16).borderRadius(16).backgroundColor(Color.White).width('100%');
            }
          }, (group: ProxyNode) => group.name);
        }.width('100%').layoutWeight(1).padding({ left: 16, right: 16, bottom: 16 });
      }
    }.width('100%').layoutWeight(1);
  }

  @Builder
  private connectionsPage() {
    Column() {
      this.heading('连接', this.connected ? `${this.connections.length} 个活动连接` : '连接控制器后可查看');
      if (this.connections.length === 0) {
        this.emptyState('暂无活动连接', '点击右上角刷新。');
      } else {
        List({ space: 10 }) {
          ForEach(this.connections, (item: ConnectionItem) => {
            ListItem() {
              Column({ space: 8 }) {
                Row() {
                  Text(item.host || '未知目标').fontSize(16).fontWeight(FontWeight.Medium).layoutWeight(1);
                  Text(item.network.toUpperCase()).fontSize(12).fontColor('#8791A0');
                }.width('100%');
                Text(item.chains).fontSize(12).fontColor('#6D7789').width('100%');
                Row() {
                  Text(`↑ ${this.formatBytes(item.upload)}   ↓ ${this.formatBytes(item.download)}`)
                    .fontSize(12).fontColor('#8791A0').layoutWeight(1);
                  Button('关闭').fontSize(12).backgroundColor('#FBEAEA').fontColor('#B45650')
                    .onClick(async () => {
                      try {
                        await this.store.closeConnection(item.id);
                        this.connections = await this.store.getConnections();
                      } catch (e) { this.showError(e); }
                    });
                }.width('100%');
              }.padding(16).borderRadius(16).backgroundColor(Color.White).width('100%');
            }
          }, (item: ConnectionItem) => item.id);
        }.width('100%').layoutWeight(1).padding({ left: 16, right: 16, bottom: 16 });
      }
    }.width('100%').layoutWeight(1);
  }

  @Builder
  private settingsPage() {
    Column({ space: 14 }) {
      this.heading('设置', '本机或外部 mihomo 控制器');
      Column({ space: 14 }) {
        Text('控制器地址').fontSize(14).fontWeight(FontWeight.Medium).width('100%');
        TextInput({ text: this.controller, placeholder: 'http://127.0.0.1:9090' })
          .onChange((value: string) => { this.controller = value; });
        Text('Secret（可选）').fontSize(14).fontWeight(FontWeight.Medium).width('100%');
        TextInput({ text: this.secret, placeholder: 'Bearer token' }).type(InputType.Password)
          .onChange((value: string) => { this.secret = value; });
        Button('保存并连接').width('100%').backgroundColor('#3467D5')
          .onClick(() => { this.saveController(); });
      }.padding(18).borderRadius(18).backgroundColor(Color.White).width('100%');
      Text('启动本机 VPN 时将自动使用 127.0.0.1:9090 和随机 Secret；也可以在这里连接外部控制器。')
        .fontSize(13).fontColor('#6D7789').width('100%');
    }.padding({ left: 16, right: 16 }).width('100%');
  }

  @Builder
  private rulesPage() {
    Column() {
      this.heading('规则', this.connected ? `${this.rules.length} 条规则` : '连接控制器后可查看');
      if (this.rules.length === 0) {
        this.emptyState('暂无规则', '连接 mihomo 控制器并刷新。');
      } else {
        List({ space: 8 }) {
          ForEach(this.rules, (rule: RuleItem, index: number) => {
            ListItem() {
              Column({ space: 5 }) {
                Row() {
                  Text(rule.type).fontSize(13).fontColor('#3467D5').layoutWeight(1);
                  Text(rule.proxy).fontSize(12).fontColor('#6D7789');
                }.width('100%');
                Text(rule.payload || '全部').fontSize(14).fontColor('#192438').width('100%');
              }.padding(14).borderRadius(14).backgroundColor(Color.White).width('100%');
            }
          }, (rule: RuleItem, index: number) => index.toString());
        }.width('100%').layoutWeight(1).padding({ left: 16, right: 16, bottom: 16 });
      }
    }.width('100%').layoutWeight(1);
  }

  @Builder
  private subHeader(title: string) {
    Row({ space: 12 }) {
      Button('‹').fontSize(22).backgroundColor('#E8EEFB').fontColor('#34548B')
        .onClick(() => { this.page = ''; });
      Text(title).fontSize(23).fontWeight(FontWeight.Bold);
    }.width('100%');
  }

  @Builder
  private addPage() {
    Column({ space: 14 }) {
      this.subHeader('添加订阅');
      TextInput({ text: this.profileName, placeholder: '配置名称' })
        .onChange((value: string) => { this.profileName = value; });
      TextInput({ text: this.profileUrl, placeholder: 'https://example.com/profile.yaml' })
        .onChange((value: string) => { this.profileUrl = value; });
      Button(this.busy ? '导入中…' : '下载并保存').width('100%').backgroundColor('#3467D5')
        .enabled(!this.busy).onClick(() => { this.importUrl(); });
    }.padding(20).width('100%');
  }

  @Builder
  private editPage() {
    Column({ space: 14 }) {
      this.subHeader('编辑配置');
      TextInput({ text: this.profileName, placeholder: '配置名称' })
        .onChange((value: string) => { this.profileName = value; });
      TextArea({ text: this.profileContent, placeholder: 'YAML 配置' })
        .fontSize(13).layoutWeight(1).width('100%')
        .onChange((value: string) => { this.profileContent = value; });
      Row({ space: 10 }) {
        Button('保存').layoutWeight(1).backgroundColor('#3467D5')
          .onClick(() => { this.saveProfile(); });
        Button('删除').backgroundColor('#FBEAEA').fontColor('#B45650')
          .onClick(() => { this.deleteProfile(this.editingId); });
      }.width('100%');
    }.padding(20).width('100%').height('100%');
  }

  @Builder
  private tabButton(index: number, label: string) {
    Column({ space: 4 }) {
      Text(label).fontSize(13).fontWeight(this.tab === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.tab === index ? '#3467D5' : '#8791A0');
      Text(this.tab === index ? '●' : ' ').fontSize(9).fontColor('#3467D5');
    }.layoutWeight(1).height(48).justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.tab = index;
        this.page = '';
        if (index === 2 || index === 3 || index === 4) { this.refresh(); }
      });
  }

  build() {
    Column() {
      if (this.page === 'add') {
        this.addPage();
      } else if (this.page === 'edit') {
        this.editPage();
      } else {
        Column() {
          if (this.tab === 0) {
            Scroll() { this.dashboard(); }.layoutWeight(1).width('100%');
          } else if (this.tab === 1) {
            this.profilesPage();
          } else if (this.tab === 2) {
            this.proxiesPage();
          } else if (this.tab === 3) {
            this.connectionsPage();
          } else if (this.tab === 4) {
            this.rulesPage();
          } else {
            Scroll() { this.settingsPage(); }.layoutWeight(1).width('100%');
          }
          Row() {
            this.tabButton(0, '概览');
            this.tabButton(1, '配置');
            this.tabButton(2, '代理');
            this.tabButton(3, '连接');
            this.tabButton(4, '规则');
            this.tabButton(5, '设置');
          }.width('100%').padding({ top: 8, bottom: 4 }).backgroundColor(Color.White);
        }.height('100%').width('100%');
      }
    }.height('100%').width('100%').backgroundColor('#F5F7FB');
  }
}
