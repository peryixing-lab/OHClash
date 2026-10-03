import { curves } from '@kit.ArkUI';
import { accessibility } from '@kit.AccessibilityKit';
import { VpnAuthorization } from '../data/VpnAuthorization';
import { ThemeManager, ThemeMode } from '../data/ThemeManager';
import { common, Want } from '@kit.AbilityKit';
import { vpnExtension } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TrafficChart, TrafficRing } from '../components/TrafficChart';
import { exportProfileBackup, importProfileBackup } from '../data/ProfileBackup';
import { HdsTabs, hdsMaterial } from '@kit.UIDesignKit';
import { FlClashStore, Profile, ProxyNode, ProxyEntry, ConnectionItem, RuleItem, TrafficSummary, ProxySnapshot, DelayJobResult } from '../data/FlClashStore';

@Entry
@Component
struct ReferenceHome {
  @StorageProp('themeMode') themeMode: string = 'dark';
  private store: FlClashStore = FlClashStore.get();
  private active: boolean = false;
  private lastTrafficAt: number = 0;
  private lastUpload: number = 0;
  private lastDownload: number = 0;
  private locationGeneration: number = 0;
  private previewGeneration: number = 0;
  private pollTimer: number = 0;
  private pageVisible: boolean = true;
  private sessionStartedAt: number = 0;
  private refreshing: boolean = false;
  @State lifecycleBusy: boolean = false;
  private startupSession: string = "";
  private controllerFailures: number = 0;
  private testGeneration: number = 0;
  private offlineJob: string = '';
  @State testing: boolean = false;
  @State testDone: number = 0;
  @State testTotal: number = 0;
  @State selecting: boolean = false;

  @State reduceMotion: boolean = false;
  @State tab: number = 0;
  @State page: string = '';
  @State busy: boolean = false;
  @State connected: boolean = false;
  @State nativeStatus: string = 'stopped';
  @State version: string = '';
  @State error: string = '';
  @State speedSamples: number[] = [];
  @State elapsed: string = '00:00:00';
  @State modeBusy: boolean = false;
  @State mode: string = 'rule';
  @State uploadSpeed: number = 0;
  @State downloadSpeed: number = 0;
  @State totalUpload: number = 0;
  @State totalDownload: number = 0;
  @State localIp: string = '—';
  @State exitIp: string = '—';
  @State exitLocation: string = '点击检测出口位置';
  @State exitFlag: string = '◎';
  @State locationBusy: boolean = false;
  @State proxyHint: string = '';

  @State profiles: Profile[] = [];
  @State proxies: ProxyNode[] = [];
  @State proxyEntries: ProxyEntry[] = [];
  @State selectedGroup: string = '';
  @State searchOpen: boolean = false;
  @State searchText: string = '';
  @State profileDescending: boolean = true;
  @State selectedProfile: number = 0;
  @State connections: ConnectionItem[] = [];
  @State rules: RuleItem[] = [];
  @State controller: string = 'http://127.0.0.1:9090';
  @State secret: string = '';
  @State profileName: string = '';
  @State profileUrl: string = '';
  @State profileContent: string = '';
  @State editingId: number = 0;

  aboutToAppear(): void {
    this.updateMotionPreference();
    this.active = true;
    this.initialize();
  }

  aboutToDisappear(): void {
    this.active = false;
    this.cancelTests();
    clearTimeout(this.pollTimer);
    this.locationGeneration++;
    this.previewGeneration++;
    VpnAuthorization.unsubscribe();
  }

  onPageShow(): void {
    this.updateMotionPreference();
    this.pageVisible = true;
    if (this.active) { this.refresh(); }
  }

  onPageHide(): void { this.pageVisible = false; }

  onBackPress(): boolean {
    if (this.page.length > 0) { this.navigatePage(''); return true; }
    if (this.searchOpen) { this.searchOpen = false; this.searchText = ''; return true; }
    return false;
  }

  private async initialize(): Promise<void> {
    try {
      const host = this.getUIContext().getHostContext();
      if (!host) { return; }
      await this.store.init(host as common.UIAbilityContext);
      this.controller = this.store.controller;
      this.secret = this.store.secret;
      this.profiles = [...this.store.profiles];
      this.selectedProfile = this.store.selectedProfile;
      this.nativeStatus = await this.store.getNativeStatus();
      this.mode = await this.store.getPreferredMode();
      try { this.localIp = await this.store.getLocalIp(); } catch (_) {}
      await this.loadOfflineProxies();
      this.detectLocation();
      await this.refresh();

      this.pollTraffic();
    } catch (error) { this.showError(error); }
  }

  private showError(error: Object): void {
    this.error = String(error);
    hilog.error(0xF1C1, 'FlClashUI', 'Operation failed: %{public}s', this.error);
    this.getUIContext().getPromptAction().showToast({ message: this.error });
  }

  private async refresh(): Promise<void> {
    if (this.refreshing || this.lifecycleBusy) { return; }
    this.refreshing = true;
    const wasConnected = this.connected;
    try {
      this.nativeStatus = await this.store.getNativeStatus();
      const local = this.store.controller === 'http://127.0.0.1:9090';
      if (local && (['stopped', 'error', 'stale', 'stopping', 'starting'].includes(this.nativeStatus))) {
        this.connected = false;
        if (this.nativeStatus === 'error') { this.error = await this.store.getNativeError(); }
        if (this.nativeStatus === 'stale') { this.error = '上次连接已中断，点击连接重新恢复'; }
        return;
      }
      try {
        this.version = await this.store.checkController();
        this.controllerFailures = 0;
      } catch (error) {
        this.controllerFailures++;
        if (!wasConnected || this.controllerFailures >= 3) { this.connected = false; }
        this.error = '控制器暂时无响应，正在重试';
        return;
      }
      // Controller readiness precedes TUN readiness. Trust the extension's
      // atomic status file instead of a cross-process Preferences cache.
      if (local && this.nativeStatus !== 'running') { return; }
      this.connected = true;
      this.error = '';
      try {
        if (!wasConnected) {
          await this.store.setMode(await this.store.getPreferredMode());
          this.sessionStartedAt = this.store.getSessionStartedAt();
          this.lastTrafficAt = 0;
          this.speedSamples = [];
        }
        this.mode = await this.store.getMode();
        if (this.tab === 1 && !this.selecting && !this.testing) { await this.refreshProxies(); }
        if (this.page === 'requests' || this.page === 'connections') { this.connections = await this.store.getConnections(); }
        if (this.page === 'rules') { this.rules = await this.store.getRules(); }
        if (this.tab === 0) { await this.sampleTraffic(); }
      } catch (_) {
        this.error = '部分数据刷新失败，可稍后重试';
      }
    } finally {
      this.refreshing = false;
      if (!this.connected && !this.testing && !this.selecting) { await this.loadOfflineProxies(); }
      if (wasConnected !== this.connected) { this.detectLocation(); }
    }
  }

  private async detectLocation(): Promise<void> {
    const generation = ++this.locationGeneration;
    this.locationBusy = true;
    this.exitIp = '—';
    this.exitFlag = '◎';
    this.exitLocation = '正在检测…';
    try {
      try { this.localIp = await this.store.getLocalIp(); } catch (_) { this.localIp = '—'; }
      const location = await this.store.detectNetworkLocation();
      if (!this.active || generation !== this.locationGeneration) { return; }
      this.exitIp = location.ip;
      this.exitLocation = location.country + (location.city && location.city !== location.country ? ` · ${location.city}` : '');
      const code = location.countryCode.toUpperCase();
      this.exitFlag = /^[A-Z]{2}$/.test(code) ? String.fromCodePoint(127397 + code.charCodeAt(0), 127397 + code.charCodeAt(1)) : '◎';
    } catch (_) {
      if (generation === this.locationGeneration) { this.exitLocation = '检测失败，点击重试'; }
    } finally {
      if (generation === this.locationGeneration) { this.locationBusy = false; }
    }
  }

  private applyProxySnapshot(snapshot: ProxySnapshot): void {
    this.proxies = snapshot.groups;
    this.proxyEntries = snapshot.entries;
    if (!this.proxies.some((group: ProxyNode) => group.name === this.selectedGroup)) {
      this.selectedGroup = this.proxies.length > 0 ? this.proxies[0].name : '';
    }
  }

  private async loadOfflineProxies(): Promise<void> {
    const generation = ++this.previewGeneration;
    try {
      const snapshot = await this.store.getOfflineProxies();
      if (generation !== this.previewGeneration || !this.active) { return; }
      this.applyProxySnapshot(snapshot);
      this.proxyHint = snapshot.providers ? '提供商节点将在首次连接下载后缓存' : '未连接 · 可预选节点，长按测速';
    } catch (_) {
      if (generation !== this.previewGeneration) { return; }
      this.proxies = [];
      this.proxyEntries = [];
      this.proxyHint = '配置无法解析，请检查订阅内容';
    }
  }

  private async refreshProxies(): Promise<void> {
    const generation = ++this.previewGeneration;
    const snapshot = await this.store.getLiveProxies();
    if (generation !== this.previewGeneration) { return; }
    this.applyProxySnapshot(snapshot);
    this.proxyHint = '';
  }

  private async sampleTraffic(): Promise<void> {
    const summary: TrafficSummary = await this.store.getTrafficSummary();
    const now = Date.now();
    const fresh = this.lastTrafficAt > 0 && now > this.lastTrafficAt && now - this.lastTrafficAt < 10000 &&
      summary.upload >= this.lastUpload && summary.download >= this.lastDownload;
    const seconds = Math.max(0.001, (now - this.lastTrafficAt) / 1000);
    this.uploadSpeed = fresh ? (summary.upload - this.lastUpload) / seconds : 0;
    this.downloadSpeed = fresh ? (summary.download - this.lastDownload) / seconds : 0;
    this.totalUpload = summary.upload;
    this.totalDownload = summary.download;
    this.lastUpload = summary.upload;
    this.lastDownload = summary.download;
    this.lastTrafficAt = now;
    this.speedSamples = [...this.speedSamples.slice(-59), this.uploadSpeed + this.downloadSpeed];
  }

  private updateElapsed(): void {
    const seconds = this.connected && this.sessionStartedAt > 0 ? Math.max(0, Math.floor((Date.now() - this.sessionStartedAt) / 1000)) : 0;
    this.elapsed = [Math.floor(seconds / 3600), Math.floor(seconds / 60) % 60, seconds % 60]
      .map((value: number): string => value.toString().padStart(2, '0')).join(':');
  }

  private pollTraffic(): void {
    if (!this.active) { return; }
    clearTimeout(this.pollTimer);
    this.pollTimer = setTimeout(async () => {
      if (!this.active) { return; }
      this.updateElapsed();
      if (this.pageVisible && !this.lifecycleBusy) {
        const status = await this.store.getNativeStatus();
        if (status !== this.nativeStatus) { await this.refresh(); }
      }
      if (this.pageVisible && this.connected && !this.lifecycleBusy) {
        try {
          await this.sampleTraffic();
          if (this.page === 'connections' || this.page === 'requests') { this.connections = await this.store.getConnections(); }
        }
        catch (_) {
          this.uploadSpeed = 0;
          this.downloadSpeed = 0;
          this.lastTrafficAt = 0;
          await this.refresh();
        }
      }
      if (this.pageVisible && !this.connected && this.nativeStatus === 'running') { await this.refresh(); }
      this.pollTraffic();
    }, 1000);
  }

  private vpnWant(): Want {
    return { deviceId: '', bundleName: 'com.flclash.harmony', abilityName: 'FlClashVpnExtension' };
  }

  private async pauseFor(ms: number): Promise<void> {
    await new Promise<void>((resolve: () => void) => { setTimeout(resolve, ms); });
  }

  private async releaseVpn(): Promise<void> {
    const initial = this.store.getRuntimeStatus();
    const sessionId = this.store.requestVpnStop();
    this.nativeStatus = 'stopping';
    let abilityStopped = false;
    // Legacy / crashed extensions do not consume the command file.
    if (!this.store.runtimeIsFresh(initial) || initial.cleanupComplete) {
      try { await vpnExtension.stopVpnExtensionAbility(this.vpnWant()); } catch (_) {}
      abilityStopped = true;
    }
    const deadline = Date.now() + 18000;
    while (Date.now() < deadline) {
      const state = this.store.getRuntimeStatus();
      if (state.sessionId === sessionId && state.cleanupComplete &&
        (state.status === 'stopped' || state.status === 'error')) {
        if (!abilityStopped) { await vpnExtension.stopVpnExtensionAbility(this.vpnWant()); }
        return;
      }
      if (abilityStopped && !this.store.runtimeIsFresh(state)) {
        // After process death the old heartbeat stays on disk; require that the
        // local controller has also disappeared before reusing its configuration.
        try { await this.store.request('/version', undefined, '', 1000); }
        catch (_) { return; }
      }
      if (!abilityStopped && Date.now() > deadline - 7000) {
        await vpnExtension.stopVpnExtensionAbility(this.vpnWant());
        abilityStopped = true;
      }
      await this.pauseFor(200);
    }
    throw new Error('上次 VPN 尚未释放，请稍后重试；未创建重复连接');
  }

  private async startVpn(): Promise<void> {
    if (this.lifecycleBusy || this.busy) { return; }
    this.lifecycleBusy = true;
    this.error = '';
    this.cancelTests();
    try {
      await this.releaseVpn();
      this.connected = false;
      this.startupSession = await this.store.prepareNativeProfile();
      this.controller = this.store.controller;
      this.secret = this.store.secret;
      this.nativeStatus = 'starting';
      let denied = false;
      let rejectAuthorization: ((reason: Error) => void) | undefined;
      const authorizationDenied = new Promise<void>((_, reject: (reason: Error) => void) => { rejectAuthorization = reject; });
      VpnAuthorization.subscribe((authorized: boolean) => {
        denied = !authorized;
        if (denied && rejectAuthorization) { rejectAuthorization(new Error('未授权 VPN，请重新连接并允许系统授权')); }
      });
      let startTimeout = 0;
      try {
        await Promise.race<void>([
          vpnExtension.startVpnExtensionAbility(this.vpnWant()),
          authorizationDenied,
          new Promise<void>((_, reject: (reason: Error) => void) => {
            startTimeout = setTimeout(() => { reject(new Error('等待系统 VPN 授权超时，请重新连接')); }, 120000);
          })
        ]);
      } finally { clearTimeout(startTimeout); }
      const deadline = Date.now() + 45000;
      let ready = false;
      while (Date.now() < deadline) {
        if (denied) { throw new Error('未授权 VPN，请重新连接并允许系统授权'); }
        const state = this.store.getRuntimeStatus();
        if (state.sessionId === this.startupSession) {
          if (state.status === 'error') { throw new Error(state.error || 'VPN 启动失败'); }
          if (state.status === 'running') { ready = true; break; }
          if (state.status === 'stopped') { throw new Error('VPN 启动已取消'); }
        }
        await this.pauseFor(250);
      }
      if (!ready) { throw new Error('VPN 启动超时，已取消本次连接，可重新尝试'); }
      this.nativeStatus = 'running';
    } catch (error) {
      try { await this.releaseVpn(); } catch (_) {}
      this.nativeStatus = 'error';
      this.connected = false;
      this.showError(error);
    } finally {
      VpnAuthorization.unsubscribe();
      this.lifecycleBusy = false;
    }
    if (this.nativeStatus === 'running') { await this.refresh(); }
  }

  private async stopVpn(): Promise<boolean> {
    if (this.lifecycleBusy) { return false; }
    this.lifecycleBusy = true;
    this.cancelTests();
    try {
      await this.releaseVpn();
      this.nativeStatus = 'stopped';
      this.connected = false;
      this.error = '';
      this.sessionStartedAt = 0;
      this.updateElapsed();
      this.uploadSpeed = 0;
      this.downloadSpeed = 0;
      this.totalUpload = 0;
      this.totalDownload = 0;
      this.speedSamples = [];
      this.lastTrafficAt = 0;
      await this.loadOfflineProxies();
      this.detectLocation();
      return true;
    } catch (error) { this.showError(error); return false; }
    finally { this.lifecycleBusy = false; }
  }

  private async switchMode(value: string): Promise<void> {
    if (this.modeBusy || this.lifecycleBusy) { return; }
    this.modeBusy = true;
    try {
      if (this.connected) {
        await this.store.setMode(value);
        this.mode = await this.store.getMode();
        this.detectLocation();
        if (value === 'global') { this.selectedGroup = 'GLOBAL'; }
      } else {
        await this.store.savePreferredMode(value);
        this.mode = value;
      }
    } catch (error) { this.showError(error); }
    finally { this.modeBusy = false; }
  }

  private async chooseProxy(group: string, name: string): Promise<void> {
    if (this.selecting || this.lifecycleBusy) { return; }
    const target = this.proxies.find((item: ProxyNode) => item.name === group);
    if (!target || !target.all.includes(name)) { return; }
    if (!['selector', 'select', 'urltest', 'url-test', 'fallback'].includes(target.type.toLowerCase())) {
      this.getUIContext().getPromptAction().showToast({ message: '此组由策略自动分配，请在选择组中切换节点' });
      return;
    }
    this.selecting = true;
    ++this.previewGeneration;
    try {
      if (this.connected) { await this.store.selectProxy(group, name); }
      else { await this.store.rememberProxy(group, name); }
      this.proxies = this.proxies.map((item: ProxyNode): ProxyNode => item.name === group ?
        { name: item.name, type: item.type, all: item.all, now: name, delay: item.delay } : item);
      if (this.connected) { this.detectLocation(); }
      else { this.getUIContext().getPromptAction().showToast({ message: '已保存，连接时使用此节点' }); }
    } catch (error) { this.showError(error); }
    finally { this.selecting = false; }
  }

  private offlineLeafNames(names: string[], visited: string[] = []): string[] {
    const result: string[] = [];
    names.forEach((name: string) => {
      if (visited.includes(name)) { return; }
      const group = this.proxies.find((item: ProxyNode) => item.name === name);
      const leaves = group ? this.offlineLeafNames(group.all, [...visited, name]) : [name];
      leaves.forEach((leaf: string) => { if (!result.includes(leaf) && leaf !== 'REJECT') { result.push(leaf); } });
    });
    return result;
  }

  private cancelTests(): void {
    this.testGeneration++;
    this.store.cancelDelayRequests();
    this.store.cancelOfflineTests(this.offlineJob);
    this.offlineJob = '';
    this.testing = false;
    this.proxyEntries = this.proxyEntries.map((item: ProxyEntry): ProxyEntry => item.delay === -2 ?
      { name: item.name, type: item.type, delay: 0 } : item);
  }

  private applyDelayResult(name: string, delay: number): void {
    this.proxyEntries = this.proxyEntries.map((item: ProxyEntry): ProxyEntry =>
      item.name === name ? { name: item.name, type: item.type, delay } : item);
    this.testDone++;
  }

  private async runDelayTests(names: string[]): Promise<void> {
    if (names.length === 0 || this.testing || this.lifecycleBusy) { return; }
    const online = this.connected;
    // Test each concrete node once; testing parent groups simultaneously would
    // duplicate traffic and skew the measured delay of their selected children.
    const targets = this.offlineLeafNames(names);
    const generation = ++this.testGeneration;
    this.testing = true;
    this.testDone = 0;
    this.testTotal = targets.length;
    let succeeded = 0;
    this.proxyEntries = this.proxyEntries.map((item: ProxyEntry): ProxyEntry => targets.includes(item.name) ?
      { name: item.name, type: item.type, delay: -2 } : item);
    try {
      if (online) {
        let next = 0;
        const workers: Promise<void>[] = [];
        for (let worker = 0; worker < Math.min(8, targets.length); worker++) {
          workers.push((async (): Promise<void> => {
            while (next < targets.length && generation === this.testGeneration && this.active) {
              const name = targets[next++];
              let delay = -1;
              try { delay = await this.store.testDelay(name); } catch (_) {}
              if (generation !== this.testGeneration) { return; }
              if (delay > 0) { succeeded++; }
              this.applyDelayResult(name, delay);
            }
          })());
        }
        await Promise.all(workers);
      } else {
        this.offlineJob = this.store.beginOfflineTests(targets);
        if (!this.offlineJob) { throw new Error('无法创建测速任务'); }
        while (generation === this.testGeneration && this.active) {
          const snapshot = this.store.pollOfflineTests(this.offlineJob);
          snapshot.results.forEach((result: DelayJobResult) => {
            const delay = result.error ? -1 : result.delay;
            if (delay > 0) { succeeded++; }
            this.applyDelayResult(result.name, delay);
          });
          if (snapshot.done) { this.offlineJob = ''; break; }
          await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 200); });
        }
      }
      if (generation === this.testGeneration) {
        hilog.info(0xF1C1, 'FlClashUI', 'Delay queue completed: online=%{public}s success=%{public}d total=%{public}d concurrency=8', String(online), succeeded, targets.length);
        this.getUIContext().getPromptAction().showToast({ message: `测速完成：${succeeded}/${targets.length} 成功` });
      }
    } catch (error) { this.showError(error); }
    finally { if (generation === this.testGeneration) { this.cancelTests(); } }
  }

  private async testSelectedGroup(): Promise<void> {
    const names = this.groupEntries().filter((entry: ProxyEntry): boolean =>
      entry.type.toLowerCase() !== 'direct' && entry.type.toLowerCase() !== 'reject').map((entry: ProxyEntry): string => entry.name);
    await this.runDelayTests(names);
  }

  private async testOneProxy(name: string): Promise<void> { await this.runDelayTests([name]); }

  private groupEntries(): ProxyEntry[] {
    const group = this.proxies.find((item: ProxyNode) => item.name === this.selectedGroup);
    if (!group) { return []; }
    const query = this.searchText.trim().toLowerCase();
    return group.all.map((name: string): ProxyEntry => {
      const entry = this.proxyEntries.find((item: ProxyEntry) => item.name === name);
      return entry ?? { name, type: '', delay: 0 };
    }).filter((entry: ProxyEntry) => query.length === 0 || entry.name.toLowerCase().includes(query));
  }

  private currentGroup(): ProxyNode | undefined {
    return this.proxies.find((item: ProxyNode) => item.name === this.selectedGroup);
  }

  private async importUrl(): Promise<void> {
    if (this.busy || this.lifecycleBusy) { return; }
    try {
      this.busy = true;
      await this.store.addFromUrl(this.profileUrl, this.profileName);
      this.profiles = [...this.store.profiles];
      this.selectedProfile = this.store.selectedProfile;
      this.profileName = '';
      this.profileUrl = '';
      this.navigatePage('');
    } catch (error) { this.showError(error); }
    finally { this.busy = false; }
  }

  private async importFile(): Promise<void> {
    if (this.busy || this.lifecycleBusy) { return; }
    this.busy = true;
    try {
      await this.store.addFromFile(this.getUIContext().getHostContext() as common.UIAbilityContext);
      this.profiles = [...this.store.profiles];
      this.selectedProfile = this.store.selectedProfile;
      this.navigatePage('');
    } catch (error) { this.showError(error); }
    finally { this.busy = false; }
  }

  private async saveProfile(): Promise<void> {
    if (this.busy || this.lifecycleBusy) { return; }
    this.busy = true;
    let restart = false;
    try {
      const index = this.store.profiles.findIndex((item: Profile) => item.id === this.editingId);
      if (index < 0) { throw new Error('配置不存在'); }
      await this.store.validateProfile(this.profileContent);
      restart = this.connected && this.editingId === this.selectedProfile;
      if (restart && !await this.stopVpn()) { return; }
      this.cancelTests();
      this.store.profiles[index].content = this.profileContent;
      this.store.profiles[index].name = this.profileName.trim() || '未命名配置';
      this.store.profiles[index].updatedAt = Date.now();
      await this.store.save();
      this.profiles = [...this.store.profiles];
      await this.loadOfflineProxies();
      this.navigatePage('');
    } catch (error) { this.showError(error); }
    finally { this.busy = false; }
    if (restart) { await this.startVpn(); }
  }

  private async deleteProfile(id: number): Promise<void> {
    if (this.busy || this.lifecycleBusy) { return; }
    this.busy = true;
    let restart = false;
    try {
      restart = this.connected && id === this.selectedProfile;
      if (restart && !await this.stopVpn()) { return; }
      this.cancelTests();
      await this.store.removeProfile(id);
      this.profiles = [...this.store.profiles];
      this.selectedProfile = this.store.selectedProfile;
      await this.loadOfflineProxies();
      this.navigatePage('');
    } catch (error) { this.showError(error); }
    finally { this.busy = false; }
    if (restart && this.selectedProfile !== 0) { await this.startVpn(); }
  }

  private async selectProfile(id: number): Promise<void> {
    if (id === this.selectedProfile || this.busy || this.lifecycleBusy) { return; }
    this.busy = true;
    let restart = false;
    try {
      this.cancelTests();
      restart = this.connected;
      if (restart && !await this.stopVpn()) { return; }
      this.store.selectedProfile = id;
      await this.store.save();
      this.selectedProfile = id;
      await this.loadOfflineProxies();
    } catch (error) { this.showError(error); }
    finally { this.busy = false; }
    if (restart) { await this.startVpn(); }
  }

  private openEditor(profile: Profile): void {
    this.editingId = profile.id;
    this.profileName = profile.name;
    this.profileContent = profile.content;
    this.navigatePage('edit');
  }

  private async updateSelectedProfile(): Promise<void> {
    if (this.selectedProfile === 0 || this.busy || this.lifecycleBusy) { return; }
    this.busy = true;
    let restart = false;
    try {
      this.cancelTests();
      await this.store.updateProfile(this.selectedProfile);
      this.profiles = [...this.store.profiles];
      restart = this.connected;
      if (restart && !await this.stopVpn()) { return; }
      await this.loadOfflineProxies();
    } catch (error) { this.showError(error); }
    finally { this.busy = false; }
    if (restart) { await this.startVpn(); }
  }

  private async saveController(): Promise<void> {
    if (this.busy || this.lifecycleBusy) { return; }
    this.busy = true;
    try {
      if (!/^https?:\/\/[^/\s]+/.test(this.controller.trim())) { throw new Error('控制器地址必须是有效 HTTP(S) 地址'); }
      if (['running', 'starting', 'stopping'].includes(await this.store.getNativeStatus())) {
        if (!await this.stopVpn()) { return; }
      }
      this.store.controller = this.controller.trim();
      this.store.secret = this.secret.trim();
      await this.store.save();
      this.connected = false;
      this.navigatePage('');
      await this.refresh();
    } catch (error) { this.showError(error); }
    finally { this.busy = false; }
  }

  private async exportBackup(): Promise<void> {
    if (this.busy || this.lifecycleBusy) { return; }
    this.busy = true;
    try {
      const saved = await exportProfileBackup(this.getUIContext().getHostContext() as common.UIAbilityContext,
        await this.store.getBackupData());
      if (saved) { this.getUIContext().getPromptAction().showToast({ message: '备份已导出' }); }
    } catch (error) { this.showError(error); }
    finally { this.busy = false; }
  }

  private async restoreBackup(): Promise<void> {
    if (this.busy || this.lifecycleBusy) { return; }
    this.busy = true;
    try {
      const data = await importProfileBackup(this.getUIContext().getHostContext() as common.UIAbilityContext);
      if (!data) { return; }
      for (const profile of data.profiles) { await this.store.validateProfile(profile.content); }
      if (!await this.stopVpn()) { return; }
      this.cancelTests();
      await this.store.restoreBackupData(data);
      this.profiles = [...this.store.profiles];
      this.selectedProfile = this.store.selectedProfile;
      this.mode = await this.store.getPreferredMode();
      await this.loadOfflineProxies();
      this.getUIContext().getPromptAction().showToast({ message: '已恢复配置，点击连接即可使用' });
    } catch (error) { this.showError(error); }
    finally { this.busy = false; }
  }

  private updateMotionPreference(): void {
    try { this.reduceMotion = accessibility.isAnimationReduceEnabledSync(); } catch (_) {}
  }

  private navigatePage(page: string): void {
    if (page === this.page) { return; }
    this.updateMotionPreference();
    this.getUIContext().animateTo({ duration: this.reduceMotion ? 0 : 220,
      curve: curves.cubicBezierCurve(0.22, 1, 0.36, 1) }, () => { this.page = page; });
  }

  private async openToolPage(page: string): Promise<void> {
    this.navigatePage(page);
    this.error = '';
    this.connections = [];
    this.rules = [];
    try {
      if (page === 'connections' || page === 'requests') {
        this.connections = await this.store.getConnections();
      } else if (page === 'rules') {
        this.rules = await this.store.getRules();
      }
    } catch (error) { this.error = String(error); }
  }

  private formatBytes(value: number): string {
    if (value >= 1099511627776) { return `${(value / 1099511627776).toFixed(1)} TB`; }
    if (value >= 1073741824) { return `${(value / 1073741824).toFixed(1)} GB`; }
    if (value >= 1048576) { return `${(value / 1048576).toFixed(1)} MB`; }
    if (value >= 1024) { return `${(value / 1024).toFixed(1)} KB`; }
    return `${Math.round(value)} B`;
  }

  private formatTime(value: number): string {
    return new Date(value).toLocaleDateString('zh-CN');
  }

  private relativeTime(value: number): string {
    const hours = Math.max(0, Math.floor((Date.now() - value) / 3600000));
    if (hours < 1) { return '刚刚'; }
    if (hours < 24) { return `${hours} 小时前`; }
    return `${Math.floor(hours / 24)} 天前`;
  }

  private sortedProfiles(): Profile[] {
    return [...this.profiles].sort((a: Profile, b: Profile) =>
      this.profileDescending ? b.updatedAt - a.updatedAt : a.updatedAt - b.updatedAt);
  }

  @Builder
  private pageTitle(title: string) {
    Row() {
      Text(title).fontSize(25).fontWeight(FontWeight.Normal)
        .fontColor($r('app.color.text_primary')).layoutWeight(1);
      if (title === '仪表盘') {
        Image($r('app.media.action_edit')).width(23).height(23)
          .onClick(() => { this.openToolPage('controller'); });
      } else if (title === '代理') {
        Image($r('app.media.action_search')).width(22).height(22)
          .margin({ right: 25 }).onClick(() => { this.searchOpen = !this.searchOpen; });
        Text('◎').fontSize(29).fontColor($r('app.color.text_primary'))
          .margin({ right: 22 }).onClick(() => { this.testSelectedGroup(); });
        Text('⋮').fontSize(25).fontColor($r('app.color.text_primary'))
          .onClick(() => { this.refresh(); });
      } else if (title === '配置') {
        Image($r('app.media.action_refresh')).width(23).height(23)
          .margin({ right: 25 }).onClick(() => { this.updateSelectedProfile(); });
        Image($r('app.media.action_sort')).width(23).height(23)
          .onClick(() => { this.profileDescending = !this.profileDescending; });
      }
    }.width('100%').height(50).flexShrink(0).padding({ left: 16, right: 20 });
  }

  @Builder
  private modeLine(value: string, label: string) {
    Row({ space: 13 }) {
      Text(this.mode === value ? '◉' : '◯').fontSize(22)
        .fontColor(this.mode === value ? $r('app.color.accent') : $r('app.color.text_secondary'));
      Text(label).fontSize(16).fontColor($r('app.color.text_primary'));
    }.height(34).width('100%').enabled(!this.modeBusy).onClick(() => { this.switchMode(value); });
  }

  @Builder
  private dashboardTab() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        this.pageTitle('仪表盘');
        Scroll() {
        Column({ space: 14 }) {
          Column() {
            Row() {
              Image($r('app.media.card_speed')).width(19).height(19).margin({ right: 9 });
              Text('网络速度').fontSize(16).fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary')).layoutWeight(1);
              Text(`↑ ${this.formatBytes(this.uploadSpeed)}/s   ↓ ${this.formatBytes(this.downloadSpeed)}/s`)
                .fontSize(12).fontColor($r('app.color.text_secondary'));
            }.width('100%').padding({ left: 16, right: 16, top: 16 });
            TrafficChart({ samples: this.speedSamples }).width('100%').layoutWeight(1);
          }.height(174).width('100%').backgroundColor($r('app.color.card_bg'))
            .border({ width: 1, color: $r('app.color.card_border') }).borderRadius(17).clip(true);
          Row({ space: 14 }) {
            Column({ space: 12 }) {
              Column({ space: 8 }) {
                Row({ space: 8 }) {
                  Image($r('app.media.card_mode')).width(19).height(19);
                  Text('出站模式').fontSize(16).fontColor($r('app.color.text_primary'));
                };
                this.modeLine('rule', '规则');
                this.modeLine('global', '全局');
                this.modeLine('direct', '直连');
              }.alignItems(HorizontalAlign.Start).width('100%').height(174).padding(15)
                .backgroundColor($r('app.color.card_bg'))
                .border({ width: 1, color: $r('app.color.card_border') }).borderRadius(17);
              Column({ space: 11 }) {
                Row({ space: 8 }) {
                  Image($r('app.media.card_lan')).width(19).height(19);
                  Text('内网 IP').fontSize(15).fontColor($r('app.color.text_primary'));
                };
                Text(this.localIp).fontSize(16).fontColor($r('app.color.text_secondary'));
              }.alignItems(HorizontalAlign.Start).width('100%').height(80).padding(15)
                .backgroundColor($r('app.color.card_bg'))
                .border({ width: 1, color: $r('app.color.card_border') }).borderRadius(17);
            }.layoutWeight(1);
            Column({ space: 12 }) {
              Column({ space: 5 }) {
                Text(`${this.exitFlag}  网络检测`).fontSize(15).fontColor($r('app.color.text_primary'));
                Text(this.exitIp).fontSize(14)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .fontColor($r('app.color.text_secondary'));
                Text(this.exitLocation).fontSize(10).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_secondary'));
              }.alignItems(HorizontalAlign.Start).width('100%').height(80).padding(13)
                .backgroundColor($r('app.color.card_bg'))
                .border({ width: 1, color: $r('app.color.card_border') }).borderRadius(17)
                .onClick(() => { if (!this.locationBusy) { this.detectLocation(); } });
              Column({ space: 8 }) {
                Row({ space: 8 }) {
                  Image($r('app.media.card_traffic')).width(19).height(19);
                  Text('流量统计').fontSize(15).fontColor($r('app.color.text_primary'));
                };
                Row({ space: 8 }) {
                  TrafficRing({ upload: this.totalUpload, download: this.totalDownload });
                  Blank().layoutWeight(1);
                  Column({ space: 10 }) {
                    Row({ space: 5 }) {
                      Row().width(19).height(8).borderRadius(5).backgroundColor($r('app.color.accent'));
                      Text('上传').fontSize(12).fontColor($r('app.color.text_primary'));
                    };
                    Row({ space: 5 }) {
                      Row().width(19).height(8).borderRadius(5).backgroundColor($r('app.color.text_secondary'));
                      Text('下载').fontSize(12).fontColor($r('app.color.text_primary'));
                    };
                  }.alignItems(HorizontalAlign.Start);
                }.width('100%');
                Row({ space: 8 }) {
                  Text('↑').fontSize(15).fontColor($r('app.color.text_secondary'));
                  Text(this.formatBytes(this.totalUpload).split(' ')[0]).fontSize(13)
                    .fontColor($r('app.color.text_primary')).layoutWeight(1);
                  Text(this.formatBytes(this.totalUpload).split(' ')[1] || 'B').fontSize(12)
                    .fontColor($r('app.color.text_secondary'));
                }.width('100%');
                Row({ space: 8 }) {
                  Text('↓').fontSize(15).fontColor($r('app.color.text_secondary'));
                  Text(this.formatBytes(this.totalDownload).split(' ')[0]).fontSize(13)
                    .fontColor($r('app.color.text_primary')).layoutWeight(1);
                  Text(this.formatBytes(this.totalDownload).split(' ')[1] || 'B').fontSize(12)
                    .fontColor($r('app.color.text_secondary'));
                }.width('100%');
              }.alignItems(HorizontalAlign.Start).width('100%').height(174).padding(15)
                .backgroundColor($r('app.color.card_bg'))
                .border({ width: 1, color: $r('app.color.card_border') }).borderRadius(17);
            }.layoutWeight(1);
          }.width('100%');
          if (this.error.length > 0) {
            Text(this.error.includes('yaml: unmarshal') ? '配置无法解析，请检查订阅内容。点击查看详情' : this.error)
              .fontSize(12).fontColor($r('app.color.error')).maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
              .onClick(() => { this.getUIContext().getPromptAction().showToast({ message: this.error }); });
          }
        }.width('100%').padding({ left: 16, right: 16, top: 17, bottom: 132 });
        }.width('100%').layoutWeight(1).align(Alignment.TopStart).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true });
      }.width('100%').height('100%');
      Button(this.lifecycleBusy ? (this.nativeStatus === 'stopping' ? '正在断开…' : '正在连接…') : (this.nativeStatus === 'running' && this.connected ? `Ⅱ  ${this.elapsed}` : '▷'))
        .width(this.connected ? 130 : 55).height(55).fontSize(this.connected ? 18 : 24).fontWeight(FontWeight.Normal).fontColor($r('app.color.connect_button_text'))
        .backgroundColor($r('app.color.button_bg')).borderRadius(18)
        .margin({ right: 17, bottom: 112 })
        .enabled(!this.busy && !this.lifecycleBusy)
        .onClick(() => {
          if (this.nativeStatus === 'running' && !this.connected) {
            this.stopVpn().then((stopped: boolean) => { if (stopped) { this.startVpn(); } });
          }
          else if (this.nativeStatus === 'running') { this.stopVpn(); }
          else { this.startVpn(); }
        });
    }.height('100%').width('100%').background($r('app.color.page_bg'));
  }

  @Builder
  private proxyCard(entry: ProxyEntry) {
    Column({ space: 4 }) {
      Text(entry.name).fontSize(15).fontColor($r('app.color.text_primary'))
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%');
      Blank().layoutWeight(1);
      Text(entry.type || '代理').fontSize(12).fontColor($r('app.color.text_secondary')).width('100%');
      Text(entry.delay > 0 ? `${entry.delay} ms` : entry.delay === -2 ? '测试中…' : entry.delay === -1 ? '超时 / 失败' : 'ϟ').fontSize(12)
        .fontColor(entry.delay > 0 ? $r('app.color.good') : entry.delay === -1 ? $r('app.color.error') : $r('app.color.accent')).width('100%');
    }.alignItems(HorizontalAlign.Start).width('48.7%').height(120).padding(12).margin({ bottom: 10 })
      .backgroundColor(this.currentGroup()?.now === entry.name ? $r('app.color.selected_bg') : $r('app.color.card_bg'))
      .border({ width: 1, color: this.currentGroup()?.now === entry.name ? $r('app.color.accent') : $r('app.color.card_border') })
      .borderRadius(15)
      .onClick(() => { this.chooseProxy(this.selectedGroup, entry.name); })
      .gesture(LongPressGesture().onAction(() => { this.testOneProxy(entry.name); }));
  }

  @Builder
  private proxyTab() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        this.pageTitle('代理');
        if (this.searchOpen) {
          TextInput({ text: this.searchText, placeholder: '搜索节点' })
            .fontColor($r('app.color.text_primary'))
            .backgroundColor($r('app.color.card_bg')).borderRadius(12)
            .margin({ left: 16, right: 16, bottom: 8 })
            .onChange((value: string) => { this.searchText = value; });
        }
        Scroll() {
          Row({ space: 28 }) {
            ForEach(this.proxies, (group: ProxyNode) => {
              Column({ space: 11 }) {
                Text(group.name).fontSize(15).fontWeight(group.name === this.selectedGroup ? FontWeight.Medium : FontWeight.Normal)
                  .fontColor(group.name === this.selectedGroup ? $r('app.color.text_primary') : $r('app.color.text_secondary'));
                Row().width('100%').height(3).borderRadius(2)
                  .backgroundColor(group.name === this.selectedGroup ? $r('app.color.accent') : Color.Transparent);
              }.width(Math.min(180, Math.max(76, group.name.length * 15))).flexShrink(0)
                .onClick(() => { this.selectedGroup = group.name; });
            }, (group: ProxyNode) => group.name);
          }.padding({ left: 27, right: 18 });
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).height(43).width('100%').flexShrink(0);
        if (!this.connected && this.proxyHint) {
          Text(this.proxyHint).fontSize(11).fontColor($r('app.color.text_secondary'))
            .width('100%').padding({ left: 16, right: 16, top: 6 }).flexShrink(0);
        }
        Scroll() {
          if (this.groupEntries().length === 0) {
            this.emptyState('暂无代理节点', this.connected ? '请切换代理组或检查配置。' : (this.proxyHint || '请先添加并选择一个配置。'));
          } else {
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
              ForEach(this.groupEntries(), (entry: ProxyEntry) => {
                this.proxyCard(entry);
              }, (entry: ProxyEntry) => `${entry.name}:${entry.delay}:${this.currentGroup()?.now === entry.name}`);
            }.width('100%').padding({ left: 16, right: 16, top: 14, bottom: 140 });
          }
        }.width('100%').layoutWeight(1).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true });
      }.width('100%').height('100%');
      Button(this.testing ? `停止 ${this.testDone}/${this.testTotal}` : '⌁  延迟测试')
        .height(54).fontSize(15).fontColor($r('app.color.button_text'))
        .backgroundColor($r('app.color.button_bg')).borderRadius(17)
        .margin({ right: 16, bottom: 112 }).enabled(!this.lifecycleBusy && this.proxyEntries.length > 0)
        .onClick(() => { if (this.testing) { this.cancelTests(); } else { this.testSelectedGroup(); } });
    }.height('100%').width('100%').background($r('app.color.page_bg'));
  }

  @Builder
  private profileCard(profile: Profile) {
    Column({ space: 12 }) {
      Row() {
        Text(profile.name).fontSize(18).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary')).layoutWeight(1)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
        Text('⋮').fontSize(23).fontColor($r('app.color.text_primary'))
          .onClick(() => { this.openEditor(profile); });
      }.width('100%');
      if (profile.subscription && profile.subscription.total > 0) {
        Progress({ value: profile.subscription.upload + profile.subscription.download,
          total: profile.subscription.total, type: ProgressType.Linear })
          .width('92%').height(4).color($r('app.color.accent'))
          .backgroundColor($r('app.color.progress_track'));
        Text(`${this.formatBytes(profile.subscription.upload + profile.subscription.download)} / ${this.formatBytes(profile.subscription.total)}` +
          (profile.subscription.expire > 0 ? ` · ${this.formatTime(profile.subscription.expire * 1000)}` : ''))
          .fontSize(13).fontColor($r('app.color.text_secondary')).width('100%');
      } else {
        Row().width('92%').height(4).backgroundColor($r('app.color.progress_track')).borderRadius(2);
        Text(profile.source.length > 0 ? '订阅未提供用量信息' : '本地配置').fontSize(13)
          .fontColor($r('app.color.text_secondary')).width('100%');
      }
      Text(this.relativeTime(profile.updatedAt)).fontSize(12)
        .fontColor($r('app.color.text_secondary')).width('100%');
    }.alignItems(HorizontalAlign.Start).padding(16).width('100%')
      .backgroundColor(profile.id === this.selectedProfile ? $r('app.color.selected_bg') : $r('app.color.card_bg'))
      .border({ width: 1, color: profile.id === this.selectedProfile ? $r('app.color.accent') : $r('app.color.card_border') })
      .borderRadius(17).onClick(() => { this.selectProfile(profile.id); });
  }

  @Builder
  private configTab() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        this.pageTitle('配置');
        Scroll() {
          Column({ space: 13 }) {
            if (this.profiles.length === 0) {
              this.emptyState('暂无配置', '点击右下角添加订阅或导入 YAML 文件。');
            } else {
              ForEach(this.sortedProfiles(), (profile: Profile) => {
                this.profileCard(profile);
              }, (profile: Profile) => `${profile.id}:${profile.updatedAt}:${this.selectedProfile === profile.id}`);
            }
          }.width('100%').padding({ left: 16, right: 16, top: 17, bottom: 145 });
        }.width('100%').layoutWeight(1).align(Alignment.TopStart).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true });
      }.width('100%').height('100%');
      Button('＋  添加配置').height(54).fontSize(15).fontColor($r('app.color.button_text'))
        .backgroundColor($r('app.color.button_bg')).borderRadius(17)
        .margin({ right: 16, bottom: 112 })
        .onClick(() => { this.navigatePage('add'); });
    }.height('100%').width('100%').background($r('app.color.page_bg'));
  }

  @Builder
  private toolRow(icon: string, title: string, subtitle: string, target: string) {
    Column() {
      Row({ space: 17 }) {
        Text(icon).fontSize(23).fontColor($r('app.color.text_primary')).width(27);
        Column({ space: 4 }) {
          Text(title).fontSize(17).fontColor($r('app.color.text_primary'));
          Text(title === '主题' ? (this.themeMode === 'system' ? '跟随系统' : this.themeMode === 'light' ? '浅色' : '深色') : subtitle)
            .fontSize(13).fontColor($r('app.color.text_secondary'));
        }.alignItems(HorizontalAlign.Start);
      }.width('100%').height(56).padding({ left: 18, right: 15 });
      Divider().strokeWidth(1).color($r('app.color.card_border'));
    }.width('100%').onClick(() => { this.openToolPage(target); });
  }

  @Builder
  private toolsTab() {
    Column() {
      this.pageTitle('工具');
      Scroll() {
      Column() {
        Text('更多').fontSize(15).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_secondary'))
          .width('100%').padding({ left: 16, top: 32, bottom: 11 });
        this.toolRow('▣', '请求', '查看当前请求记录', 'requests');
        this.toolRow('▤', '连接', '查看当前连接数据', 'connections');
        this.toolRow('☷', '资源', '规则与外部资源', 'rules');
        Text('设置').fontSize(15).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_secondary'))
          .width('100%').padding({ left: 16, top: 30, bottom: 10 });
        this.toolRow('◎', '语言', '当前支持简体中文', 'language');
        this.toolRow('◈', '主题', this.themeMode === 'system' ? '跟随系统' : this.themeMode === 'light' ? '浅色' : '深色', 'theme');
        this.toolRow('♧', '备份与恢复', '导出或导入配置', 'backup');
        this.toolRow('▦', '代理范围', '当前为系统全局 VPN', 'access');
        this.toolRow('✎', '基本配置', '控制器地址与密钥', 'controller');
        this.toolRow('ⓘ', '免责声明', '使用范围与责任说明', 'disclaimer');
      }.width('100%').padding({ bottom: 125 });
      }.layoutWeight(1).width('100%').align(Alignment.TopStart).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true });
    }.height('100%').width('100%').background($r('app.color.page_bg'));
  }

  @Builder
  private emptyState(title: string, detail: string) {
    Column({ space: 10 }) {
      Text(title).fontSize(17).fontColor($r('app.color.text_primary'));
      Text(detail).fontSize(13).fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center);
    }.width('100%').padding({ top: 65, left: 24, right: 24 });
  }

  @Builder
  private detailHeader(title: string) {
    Row({ space: 16 }) {
      Text('‹').fontSize(29).fontColor($r('app.color.text_primary')).width(36).height(44).textAlign(TextAlign.Center)
        .onClick(() => { this.navigatePage(''); });
      Text(title).fontSize(25).fontColor($r('app.color.text_primary'));
    }.width('100%').height(70).padding({ left: 18 });
  }

  @Builder
  private addPage() {
    Column({ space: 15 }) {
      this.detailHeader('添加配置');
      TextInput({ text: this.profileName, placeholder: '配置名称' })
        .backgroundColor($r('app.color.card_bg')).fontColor($r('app.color.text_primary'))
        .onChange((value: string) => { this.profileName = value; });
      TextInput({ text: this.profileUrl, placeholder: 'https://example.com/profile.yaml' })
        .backgroundColor($r('app.color.card_bg')).fontColor($r('app.color.text_primary'))
        .onChange((value: string) => { this.profileUrl = value; });
      Button(this.busy ? '导入中…' : '下载并保存').width('100%').height(48)
        .backgroundColor($r('app.color.button_bg')).fontColor($r('app.color.button_text'))
        .enabled(!this.busy && !this.lifecycleBusy).onClick(() => { this.importUrl(); });
      Button('从文件导入 YAML').width('100%').height(48)
        .backgroundColor($r('app.color.selected_bg')).fontColor($r('app.color.text_primary'))
        .onClick(() => { this.importFile(); });
    }.padding({ left: 18, right: 18 }).width('100%').height('100%')
      .background($r('app.color.page_bg'));
  }

  @Builder
  private editPage() {
    Column({ space: 15 }) {
      this.detailHeader('编辑配置');
      TextInput({ text: this.profileName, placeholder: '配置名称' })
        .backgroundColor($r('app.color.card_bg')).fontColor($r('app.color.text_primary'))
        .onChange((value: string) => { this.profileName = value; });
      TextArea({ text: this.profileContent, placeholder: 'YAML 配置' })
        .backgroundColor($r('app.color.card_bg')).fontColor($r('app.color.text_primary'))
        .fontSize(13).layoutWeight(1).width('100%')
        .onChange((value: string) => { this.profileContent = value; });
      Row({ space: 10 }) {
        Button('保存').layoutWeight(1).height(48)
          .backgroundColor($r('app.color.button_bg')).fontColor($r('app.color.button_text'))
          .onClick(() => { this.saveProfile(); });
        Button('删除').height(48).backgroundColor($r('app.color.selected_bg'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => { this.deleteProfile(this.editingId); });
      }.width('100%');
    }.padding({ left: 18, right: 18, bottom: 16 }).width('100%').height('100%')
      .background($r('app.color.page_bg'));
  }

  @Builder
  private controllerPage() {
    Column({ space: 15 }) {
      this.detailHeader('基本配置');
      Text('控制器地址').fontSize(14).fontColor($r('app.color.text_primary')).width('100%');
      TextInput({ text: this.controller, placeholder: 'http://127.0.0.1:9090' })
        .backgroundColor($r('app.color.card_bg')).fontColor($r('app.color.text_primary'))
        .onChange((value: string) => { this.controller = value; });
      Text('Secret').fontSize(14).fontColor($r('app.color.text_primary')).width('100%');
      TextInput({ text: this.secret, placeholder: 'Bearer token' }).type(InputType.Password)
        .backgroundColor($r('app.color.card_bg')).fontColor($r('app.color.text_primary'))
        .onChange((value: string) => { this.secret = value; });
      Button('保存并连接').width('100%').height(48)
        .backgroundColor($r('app.color.button_bg')).fontColor($r('app.color.button_text'))
        .onClick(() => { this.saveController(); });
      Text('启动本机 VPN 时会自动使用本机控制器地址。').fontSize(12)
        .fontColor($r('app.color.text_secondary')).width('100%');
    }.padding({ left: 18, right: 18 }).width('100%').height('100%')
      .background($r('app.color.page_bg'));
  }

  @Builder
  private connectionsPage() {
    Column() {
      this.detailHeader(this.page === 'requests' ? '请求' : '连接');
      if (this.connections.length === 0) {
        this.emptyState('暂无活动连接', this.error.length > 0 ? this.error : '连接代理后可在这里查看。');
      } else {
        List({ space: 10 }) {
          ForEach(this.connections, (item: ConnectionItem) => {
            ListItem() {
              Column({ space: 9 }) {
                Text(item.host || '未知目标').fontSize(16)
                  .fontColor($r('app.color.text_primary')).width('100%');
                Text(`${item.network.toUpperCase()}  ${item.chains}`)
                  .fontSize(12).fontColor($r('app.color.text_secondary')).width('100%');
                Row() {
                  Text(`↑ ${this.formatBytes(item.upload)}   ↓ ${this.formatBytes(item.download)}`)
                    .fontSize(12).fontColor($r('app.color.text_secondary')).layoutWeight(1);
                  Button('关闭').fontSize(12).height(30).backgroundColor($r('app.color.selected_bg'))
                    .fontColor($r('app.color.text_primary')).onClick(async () => {
                      try {
                        await this.store.closeConnection(item.id);
                        this.connections = await this.store.getConnections();
                      } catch (error) { this.showError(error); }
                    });
                }.width('100%');
              }.padding(15).backgroundColor($r('app.color.card_bg'))
                .border({ width: 1, color: $r('app.color.card_border') }).borderRadius(16);
            }
          }, (item: ConnectionItem) => item.id);
        }.width('100%').layoutWeight(1).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).padding({ left: 16, right: 16 });
      }
    }.height('100%').background($r('app.color.page_bg'));
  }

  @Builder
  private rulesPage() {
    Column() {
      this.detailHeader('资源');
      if (this.rules.length === 0) {
        this.emptyState('暂无规则资源', this.error.length > 0 ? this.error : '连接控制器后可查看。');
      } else {
        List({ space: 8 }) {
          ForEach(this.rules, (rule: RuleItem, index: number) => {
            ListItem() {
              Column({ space: 6 }) {
                Text(`${rule.type}  →  ${rule.proxy}`).fontSize(14)
                  .fontColor($r('app.color.text_primary')).width('100%');
                Text(rule.payload || '全部').fontSize(12)
                  .fontColor($r('app.color.text_secondary')).width('100%');
              }.padding(14).backgroundColor($r('app.color.card_bg'))
                .border({ width: 1, color: $r('app.color.card_border') }).borderRadius(14);
            }
          }, (rule: RuleItem, index: number) => index.toString());
        }.width('100%').layoutWeight(1).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).padding({ left: 16, right: 16 });
      }
    }.height('100%').background($r('app.color.page_bg'));
  }

  @Builder
  private themeOption(mode: ThemeMode, title: string, subtitle: string) {
    Row({ space: 14 }) {
      Column({ space: 6 }) {
        Text(title).fontSize(17).fontColor($r('app.color.text_primary'));
        Text(subtitle).fontSize(13).fontColor($r('app.color.text_secondary'));
      }.alignItems(HorizontalAlign.Start).layoutWeight(1);
      Radio({ value: mode, group: 'appearance' }).checked(this.themeMode === mode)
        .radioStyle({ checkedBackgroundColor: $r('app.color.accent'),
          uncheckedBorderColor: $r('app.color.text_secondary'), indicatorColor: $r('app.color.page_bg') })
        .hitTestBehavior(HitTestMode.None);
    }.width('100%').padding(18).borderRadius(16)
      .backgroundColor(this.themeMode === mode ? $r('app.color.selected_bg') : $r('app.color.card_bg'))
      .border({ width: 1, color: this.themeMode === mode ? $r('app.color.accent') : $r('app.color.card_border') })
      .accessibilityGroup(true).accessibilityText(`${title}${this.themeMode === mode ? '，已选择' : ''}`)
      .onClick(() => { try { ThemeManager.select(mode); } catch (error) { this.showError(error); } });
  }

  @Builder
  private themePage() {
    Column({ space: 12 }) {
      this.detailHeader('主题');
      this.themeOption('dark', '深色', '柔和深色背景');
      this.themeOption('light', '浅色', '清爽白色背景');
      this.themeOption('system', '跟随系统', '随系统自动切换浅色与深色');
    }.padding({ left: 18, right: 18 }).height('100%').width('100%')
      .background($r('app.color.page_bg'));
  }

  @Builder
  private disclaimerPage() {
    Column() {
      this.detailHeader('免责声明');
      Scroll() {
        Column({ space: 20 }) {
          Text('仅供学习与技术研究').fontSize(20).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'));
          Text('OHClash 仅供学习、技术研究与交流使用。使用本软件时，请遵守所在地的法律法规。')
            .fontSize(15).fontColor($r('app.color.text_secondary')).lineHeight(25);
          Text('禁止违法犯罪用途').fontSize(17).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'));
          Text('不得利用本软件从事任何违法犯罪行为，不得侵犯他人的合法权益。')
            .fontSize(15).fontColor($r('app.color.text_secondary')).lineHeight(25);
          Text('使用责任').fontSize(17).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'));
          Text('使用者应对自己的使用行为负责。因使用者违法使用本软件而产生的责任，由使用者自行承担，软件作者不承担相关责任。')
            .fontSize(15).fontColor($r('app.color.text_secondary')).lineHeight(25);
          Text('本软件不提供代理节点、订阅或网络服务，请自行确认所使用服务的合法性与安全性。')
            .fontSize(15).fontColor($r('app.color.text_secondary')).lineHeight(25);
        }.alignItems(HorizontalAlign.Start).width('100%').padding(22);
      }.width('100%').layoutWeight(1).align(Alignment.TopStart).scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true });
    }.width('100%').height('100%').background($r('app.color.page_bg'));
  }

  @Builder
  private infoPage() {
    Column({ space: 18 }) {
      this.detailHeader(this.page === 'language' ? '语言' :
        this.page === 'backup' ? '备份与恢复' : '代理范围');
      Text(this.page === 'language' ? '当前使用简体中文。' :
        this.page === 'backup' ? '备份包含订阅链接和节点凭据，请妥善保管。恢复将替换当前配置；卸载前请将备份保存到应用外的文件目录。' :
        '当前 VPN 覆盖系统 IPv4 流量；暂不支持按应用分流。')
        .fontSize(15).fontColor($r('app.color.text_secondary')).width('100%');
      if (this.page === 'backup') {
        Button('导出备份').width('100%').height(48).enabled(!this.busy && !this.lifecycleBusy)
          .backgroundColor($r('app.color.button_bg')).fontColor($r('app.color.button_text')).onClick(() => { this.exportBackup(); });
        Button('从文件恢复').width('100%').height(48).enabled(!this.busy && !this.lifecycleBusy)
          .backgroundColor($r('app.color.selected_bg')).fontColor($r('app.color.text_primary'))
          .onClick(() => { this.restoreBackup(); });
      }
    }.padding({ left: 18, right: 18 }).height('100%').width('100%')
      .background($r('app.color.page_bg'));
  }

  @Builder
  private dockItem(index: number, label: string, icon: Resource) {
    Column({ space: 3 }) {
      Row() {
        Image(icon).width(24).height(24)
          .opacity(this.tab === index ? 1 : 0.72);
      }.width(50).height(32).justifyContent(FlexAlign.Center)
        .backgroundColor(this.tab === index ? $r('app.color.dock_selection') : Color.Transparent)
        .border({ width: 0.5, color: this.tab === index ? $r('app.color.dock_selection_border') : Color.Transparent })
        .borderRadius(16);
      Text(label).fontSize(11)
        .fontWeight(this.tab === index ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.tab === index ? $r('app.color.accent') : $r('app.color.text_secondary'));
    }.width('100%').height(56).justifyContent(FlexAlign.Center)
      .accessibilityGroup(true).accessibilityText(label);
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
        HdsTabs({ barPosition: BarPosition.End, index: this.tab }) {
          TabContent() { this.dashboardTab(); }
            .tabBar(this.dockItem(0, '仪表盘', $r('app.media.tab_dashboard')));
          TabContent() { this.proxyTab(); }
            .tabBar(this.dockItem(1, '代理', $r('app.media.tab_proxy')));
          TabContent() { this.configTab(); }
            .tabBar(this.dockItem(2, '配置', $r('app.media.tab_config')));
          TabContent() { this.toolsTab(); }
            .tabBar(this.dockItem(3, '工具', $r('app.media.tab_tools')));
        }
        .animationDuration(this.reduceMotion ? 0 : 240)
        .barHeight(68)
        .barOverlap(true)
        .barFloatingStyle({
          barSideMargin: 48,
          barBottomMargin: 6,
          gradientMask: { maskColor: Color.Transparent, maskHeight: 0 },
          lightColor: $r('app.color.accent'),
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.ADAPTIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
          }
        })
        .barBackgroundColor($r('app.color.dock_bg'))
        .onChange((index: number) => {
          this.tab = index;
          if (index === 1) {
            if (!this.connected) { this.loadOfflineProxies(); }
            this.refresh();
          } else if (index === 0) { this.refresh(); }
        })
        .width('100%').height(LayoutPolicy.matchParent)
        .enabled(this.page.length === 0)
        .accessibilityLevel(this.page.length === 0 ? 'auto' : 'no-hide-descendants');
      if (this.page.length > 0) {
        Column() {
          if (this.page === 'add') {
            this.addPage();
          } else if (this.page === 'edit') {
            this.editPage();
          } else if (this.page === 'controller') {
            this.controllerPage();
          } else if (this.page === 'connections' || this.page === 'requests') {
            this.connectionsPage();
          } else if (this.page === 'rules') {
            this.rulesPage();
          } else if (this.page === 'theme') {
            this.themePage();
          } else if (this.page === 'disclaimer') {
            this.disclaimerPage();
          } else {
            this.infoPage();
          }
        }.width('100%').height(LayoutPolicy.matchParent).background($r('app.color.page_bg'))
          .transition(TransitionEffect.OPACITY.combine(
            TransitionEffect.translate({ x: this.reduceMotion ? 0 : 24 })));
      }
    }.width('100%').height(LayoutPolicy.matchParent).background($r('app.color.page_bg')).clip(true);
  }
}
