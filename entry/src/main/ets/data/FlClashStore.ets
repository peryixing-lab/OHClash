import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { connection, http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { ProfileBackupData, parseProfileBackup } from './ProfileBackup';
import core from 'libflclash_napi.so';

export interface Profile {
  id: number;
  name: string;
  source: string;
  content: string;
  updatedAt: number;
  subscription?: SubscriptionInfo;
}

export interface SubscriptionInfo {
  upload: number;
  download: number;
  total: number;
  expire: number;
}

interface DownloadedProfile {
  content: string;
  subscription?: SubscriptionInfo;
}

export interface ProxyNode {
  name: string;
  type: string;
  now: string;
  all: string[];
  delay: number;
}

export interface ProxyEntry {
  name: string;
  type: string;
  delay: number;
}

export interface ProxySnapshot {
  groups: ProxyNode[];
  entries: ProxyEntry[];
  providers: boolean;
  error?: string;
}

export interface NetworkLocation {
  ip: string;
  country: string;
  city: string;
  countryCode: string;
}

export interface DelayJobResult { name: string; delay: number; error?: string; }
export interface DelayJobSnapshot { results: DelayJobResult[]; done: boolean; total: number; }
export interface RuntimeStatus {
  sessionId: string;
  status: string;
  error: string;
  updatedAt: number;
  cleanupComplete: boolean;
}
interface VpnCommand { sessionId: string; action: string; requestedAt: number; secret: string; }

interface DelayResult {
  delay: number;
  error?: string;
}

export interface TrafficSummary {
  upload: number;
  download: number;
}

export interface ConnectionItem {
  id: string;
  host: string;
  network: string;
  chains: string;
  upload: number;
  download: number;
}

export interface RuleItem {
  type: string;
  payload: string;
  proxy: string;
}

export class FlClashStore {
  private static instance: FlClashStore = new FlClashStore();
  private pref?: preferences.Preferences;
  private filesDir: string = '';
  private delayRequests: Set<http.HttpRequest> = new Set<http.HttpRequest>();
  private delayEpoch: number = 0;
  private selections: Record<string, Record<string, string>> = {};
  private offlineDelays: Map<string, number> = new Map<string, number>();
  profiles: Profile[] = [];
  controller: string = 'http://127.0.0.1:9090';
  secret: string = '';
  selectedProfile: number = 0;

  static get(): FlClashStore {
    return FlClashStore.instance;
  }

  async init(context: common.UIAbilityContext): Promise<void> {
    this.pref = await preferences.getPreferences(context, 'flclash_arkts');
    this.filesDir = context.filesDir;
    this.controller = String(await this.pref.get('controller', this.controller));
    this.secret = String(await this.pref.get('secret', ''));
    this.selectedProfile = Number(await this.pref.get('selectedProfile', 0));
    try { this.selections = JSON.parse(String(await this.pref.get('proxySelections', '{}'))) as Record<string, Record<string, string>>; } catch (_) {}
    const saved = String(await this.pref.get('profiles', '[]'));
    try {
      this.profiles = JSON.parse(saved) as Profile[];
      this.profiles.forEach((profile: Profile) => {
        if (profile.content.length === 0) {
          try {
            profile.content = fs.readTextSync(this.profilePath(profile.id));
          } catch (_) { profile.content = ''; }
        }
      });
    } catch (_) {
      this.profiles = [];
    }
  }

  async save(): Promise<void> {
    if (!this.pref) {
      return;
    }
    await this.pref.put('controller', this.controller);
    await this.pref.put('secret', this.secret);
    await this.pref.put('selectedProfile', this.selectedProfile);
    const metadata: Profile[] = [];
    this.profiles.forEach((profile: Profile) => {
      this.writePrivateFile(`profile-${profile.id}.yaml`, profile.content);
      const item: Profile = { id: profile.id, name: profile.name, source: profile.source,
        content: '', updatedAt: profile.updatedAt, subscription: profile.subscription };
      metadata.push(item);
    });
    await this.pref.put('profiles', JSON.stringify(metadata));
    await this.pref.flush();
  }

  private profilePath(id: number): string {
    return `${this.filesDir}/profile-${id}.yaml`;
  }

  async prepareNativeProfile(): Promise<string> {
    const profile = this.profiles.find((item: Profile) => item.id === this.selectedProfile);
    if (!profile || profile.content.trim().length === 0) {
      throw new Error('请先选择一个有效配置或订阅');
    }
    await this.validateProfile(profile.content);
    this.writePrivateFile('proxy-selections.json', JSON.stringify(this.selections[String(this.selectedProfile)] ?? {}));
    this.writePrivateFile('config.yaml', profile.content);
    if (this.secret.length === 0) {
      this.secret = util.generateRandomUUID() + util.generateRandomUUID();
    }
    this.controller = 'http://127.0.0.1:9090';
    if (this.pref) {
      await this.pref.put('runningPreviewKey', `proxyPreview-${profile.id}-${profile.updatedAt}`);
      await this.pref.put('nativeStatus', 'starting');
      await this.pref.put('nativeError', '');
    }
    await this.save();
    const sessionId = util.generateRandomUUID();
    const command: VpnCommand = { sessionId, action: 'start', requestedAt: Date.now(), secret: this.secret };
    this.writePrivateFile('vpn-command.json', JSON.stringify(command));
    return sessionId;
  }

  private writePrivateFile(name: string, content: string): void {
    const path = `${this.filesDir}/${name}`;
    const file = fs.openSync(`${path}.tmp`, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try { fs.writeSync(file.fd, content); } finally { fs.closeSync(file); }
    fs.renameSync(`${path}.tmp`, path);
  }

  getRuntimeStatus(): RuntimeStatus {
    try {
      const state = JSON.parse(fs.readTextSync(`${this.filesDir}/vpn-status.json`)) as RuntimeStatus;
      return state;
    } catch (_) {
      return { sessionId: '', status: 'stopped', error: '', updatedAt: 0, cleanupComplete: true };
    }
  }

  runtimeIsFresh(state: RuntimeStatus): boolean {
    return typeof state.sessionId === 'string' && state.sessionId.length > 0 && Date.now() - state.updatedAt < 15000;
  }

  requestVpnStop(): string {
    let command: VpnCommand;
    try { command = JSON.parse(fs.readTextSync(`${this.filesDir}/vpn-command.json`)) as VpnCommand; }
    catch (_) {
      command = { sessionId: this.getRuntimeStatus().sessionId || '', action: 'stop', requestedAt: Date.now(), secret: this.secret };
    }
    command.action = 'stop';
    command.requestedAt = Date.now();
    this.writePrivateFile('vpn-command.json', JSON.stringify(command));
    return command.sessionId;
  }

  async getNativeStatus(): Promise<string> {
    const state = this.getRuntimeStatus();
    if (['running', 'starting', 'stopping'].includes(state.status) && !this.runtimeIsFresh(state)) { return 'stale'; }
    return state.status;
  }

  // Retained for the legacy page only; the active page never publishes extension state.
  async setNativeStatus(status: string, error: string = ''): Promise<void> {
    await this.pref?.put('nativeStatus', status);
    await this.pref?.put('nativeError', error);
    await this.pref?.flush();
  }

  async getNativeError(): Promise<string> { return this.getRuntimeStatus().error; }

  async validateProfile(content: string): Promise<void> {
    if (content.trim().length === 0) { throw new Error('配置内容为空'); }
    const preview = JSON.parse(await core.inspectProfile(content)) as ProxySnapshot;
    if (preview.error) { throw new Error('配置无法解析，请检查 YAML 或订阅格式'); }
  }

  async getBackupData(): Promise<ProfileBackupData> {
    const selections: Record<string, Record<string, string>> = {};
    this.profiles.forEach((profile: Profile) => {
      const saved = this.selections[String(profile.id)];
      if (saved) { selections[String(profile.id)] = saved; }
    });
    return parseProfileBackup(JSON.stringify({ version: 1, profiles: this.profiles,
      selectedProfile: this.selectedProfile, preferredMode: await this.getPreferredMode(), selections }));
  }

  async restoreBackupData(input: ProfileBackupData): Promise<void> {
    const data = parseProfileBackup(JSON.stringify(input));
    for (const profile of data.profiles) { await this.validateProfile(profile.content); }
    this.profiles = data.profiles;
    this.selectedProfile = data.selectedProfile;
    this.selections = data.selections;
    this.offlineDelays.clear();
    this.controller = 'http://127.0.0.1:9090';
    await this.pref?.put('proxySelections', JSON.stringify(this.selections));
    await this.savePreferredMode(data.preferredMode);
    await this.save();
  }

  async rememberProxy(group: string, name: string): Promise<void> {
    const key = String(this.selectedProfile);
    const choices: Record<string, string> = this.selections[key] ?? {};
    choices[group] = name;
    this.selections[key] = choices;
    await this.pref?.put('proxySelections', JSON.stringify(this.selections));
    await this.pref?.flush();
  }

  beginOfflineTests(names: string[]): string {
    const profile = this.profiles.find((item: Profile) => item.id === this.selectedProfile);
    if (!profile) { throw new Error('请先选择配置'); }
    return core.beginDelayJob(profile.content, JSON.stringify(names));
  }

  pollOfflineTests(id: string): DelayJobSnapshot {
    const snapshot = JSON.parse(core.pollDelayJob(id)) as DelayJobSnapshot;
    const profile = this.profiles.find((item: Profile) => item.id === this.selectedProfile);
    if (profile) {
      snapshot.results.forEach((result: DelayJobResult) => {
        this.offlineDelays.set(`${profile.id}:${profile.updatedAt}:${result.name}`, result.error ? -1 : result.delay);
      });
    }
    return snapshot;
  }

  cancelOfflineTests(id: string): void { if (id) { core.cancelDelayJob(id); } }

  async addFromUrl(url: string, name: string): Promise<void> {
    const downloaded = await this.download(url);
    await this.validateProfile(downloaded.content);
    this.addProfile(name, url.trim(), downloaded.content, downloaded.subscription);
    await this.save();
  }

  async updateProfile(id: number): Promise<void> {
    const index = this.profiles.findIndex((item: Profile) => item.id === id);
    if (index < 0 || !this.profiles[index].source.startsWith('http')) {
      throw new Error('此配置没有可更新的订阅链接');
    }
    const downloaded = await this.download(this.profiles[index].source);
    await this.validateProfile(downloaded.content);
    this.profiles[index].content = downloaded.content;
    if (downloaded.subscription) { this.profiles[index].subscription = downloaded.subscription; }
    this.profiles[index].updatedAt = Date.now();
    await this.save();
  }

  async addFromFile(context: common.UIAbilityContext): Promise<void> {
    const selector = new picker.DocumentViewPicker(context);
    const uris = await selector.select({ maxSelectNumber: 1, fileSuffixFilters: ['配置文件|.yaml,.yml,.txt'] });
    if (uris.length === 0) {
      return;
    }
    const uri = uris[0];
    const source = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    const localPath = `${context.cacheDir}/import-${Date.now()}.yaml`;
    let body: string = '';
    try {
      fs.copyFileSync(source.fd, localPath);
      body = fs.readTextSync(localPath);
    } finally {
      fs.closeSync(source);
      try { fs.unlinkSync(localPath); } catch (_) {}
    }
    const name = decodeURIComponent(uri.substring(uri.lastIndexOf('/') + 1));
    await this.validateProfile(body);
    this.addProfile(name, '', body);
    await this.save();
  }

  addProfile(name: string, source: string, content: string, subscription?: SubscriptionInfo): void {
    if (content.trim().length === 0) {
      throw new Error('配置内容为空');
    }
    let id = Date.now();
    while (this.profiles.some((item: Profile) => item.id === id)) { id++; }
    this.profiles = [...this.profiles, { id, name: name.trim() || '未命名配置', source,
      content, updatedAt: id, subscription }];
    if (this.selectedProfile === 0) {
      this.selectedProfile = id;
    }
  }

  async removeProfile(id: number): Promise<void> {
    this.profiles = this.profiles.filter((item: Profile) => item.id !== id);
    const remaining: Record<string, Record<string, string>> = {};
    Object.keys(this.selections).forEach((key: string) => {
      if (key !== String(id)) { remaining[key] = this.selections[key]; }
    });
    this.selections = remaining;
    await this.pref?.put('proxySelections', JSON.stringify(this.selections));
    if (this.selectedProfile === id) {
      this.selectedProfile = this.profiles.length > 0 ? this.profiles[0].id : 0;
    }
    await this.save();
    try { fs.unlinkSync(this.profilePath(id)); } catch (_) {}
  }

  async request(path: string, method: http.RequestMethod = http.RequestMethod.GET, body: string = '', readTimeout: number = 8000): Promise<string> {
    const endpoint = this.controller.trim().replace(/\/+$/, '');
    if (!/^https?:\/\//.test(endpoint)) {
      throw new Error('控制器地址必须以 http:// 或 https:// 开头');
    }
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    if (this.secret.length > 0) {
      headers['Authorization'] = `Bearer ${this.secret}`;
    }
    const client = http.createHttp();
    if (path.includes('/delay?')) { this.delayRequests.add(client); }
    try {
      const result = await client.request(endpoint + path, {
        method,
        header: headers,
        extraData: body,
        connectTimeout: 2500,
        readTimeout,
        usingCache: false,
        expectDataType: http.HttpDataType.STRING
      });
      if (result.responseCode < 200 || result.responseCode >= 300) {
        throw new Error(`控制器返回 HTTP ${result.responseCode}`);
      }
      return String(result.result);
    } finally {
      this.delayRequests.delete(client);
      client.destroy();
    }
  }

  cancelDelayRequests(): void {
    this.delayEpoch++;
    this.delayRequests.forEach((client: http.HttpRequest) => { client.destroy(); });
    this.delayRequests.clear();
  }

  async checkController(): Promise<string> {
    const data = JSON.parse(await this.request('/version')) as Record<string, Object>;
    return String(data['version'] ?? '已连接');
  }

  async getMode(): Promise<string> {
    const data = JSON.parse(await this.request('/configs')) as Record<string, Object>;
    return String(data['mode'] ?? 'rule');
  }

  async setMode(mode: string): Promise<void> {
    await this.request('/configs', http.RequestMethod.PATCH, JSON.stringify({ mode }));
    if (await this.getMode() !== mode) { throw new Error('内核未确认出站模式，请重试'); }
    await this.savePreferredMode(mode);
  }

  async getProxies(): Promise<ProxyNode[]> {
    const data = JSON.parse(await this.request('/proxies')) as Record<string, Object>;
    const proxies = (data['proxies'] as Record<string, Record<string, Object>>) ?? {};
    const nodes: ProxyNode[] = [];
    Object.keys(proxies).forEach((name: string) => {
      const proxy = proxies[name];
      const all = proxy['all'] as string[] | undefined;
      if (!all || all.length === 0) {
        return;
      }
      const history = proxy['history'] as Array<Record<string, number>> | undefined;
      const last = history && history.length > 0 ? history[history.length - 1]['delay'] : 0;
      nodes.push({ name, type: String(proxy['type'] ?? ''), now: String(proxy['now'] ?? ''), all, delay: last ?? 0 });
    });
    return nodes;
  }

  async getProxyEntries(): Promise<ProxyEntry[]> {
    const data = JSON.parse(await this.request('/proxies')) as Record<string, Object>;
    const proxies = (data['proxies'] as Record<string, Record<string, Object>>) ?? {};
    return Object.keys(proxies).map((name: string): ProxyEntry => {
      const item = proxies[name];
      const history = item['history'] as Array<Record<string, number>> | undefined;
      const delay = history && history.length > 0 ? Number(history[history.length - 1]['delay'] ?? 0) : 0;
      return { name, type: String(item['type'] ?? ''), delay };
    });
  }

  async getOfflineProxies(): Promise<ProxySnapshot> {
    const profile = this.profiles.find((item: Profile) => item.id === this.selectedProfile);
    if (!profile) { return { groups: [], entries: [], providers: false }; }
    let preview = JSON.parse(await core.inspectProfile(profile.content)) as ProxySnapshot;
    if (preview.error) { throw new Error(preview.error); }
    if (preview.providers && this.pref) {
      const cached = String(await this.pref.get(`proxyPreview-${profile.id}-${profile.updatedAt}`, ''));
      if (cached) { preview = JSON.parse(cached) as ProxySnapshot; }
    }
    const choices: Record<string, string> = this.selections[String(this.selectedProfile)] ?? {};
    preview.groups = preview.groups.map((group: ProxyNode): ProxyNode => {
      const saved = choices[group.name];
      const now = saved && group.all.includes(saved) ? saved : (group.now || group.all[0] || '');
      return { name: group.name, type: group.type, now, all: group.all, delay: group.delay };
    });
    preview.entries = preview.entries.map((entry: ProxyEntry): ProxyEntry => {
      const delay = this.offlineDelays.get(`${profile.id}:${profile.updatedAt}:${entry.name}`) ?? entry.delay;
      return { name: entry.name, type: entry.type, delay };
    });
    return preview;
  }

  async getLiveProxies(): Promise<ProxySnapshot> {
    const data = JSON.parse(await this.request('/proxies')) as Record<string, Object>;
    const proxies = (data['proxies'] as Record<string, Record<string, Object>>) ?? {};
    const snapshot: ProxySnapshot = { groups: [], entries: [], providers: false };
    Object.keys(proxies).forEach((name: string) => {
      const item = proxies[name];
      const history = item['history'] as Array<Record<string, number>> | undefined;
      const delay = history && history.length > 0 ? Number(history[history.length - 1]['delay'] ?? 0) : 0;
      const type = String(item['type'] ?? '');
      snapshot.entries.push({ name, type, delay });
      const all = item['all'] as string[] | undefined;
      if (all) { snapshot.groups.push({ name, type, all, now: String(item['now'] ?? ''), delay }); }
    });
    const key = String(await this.pref?.get('runningPreviewKey', '') ?? '');
    if (key && this.pref) {
      await this.pref.put(key, JSON.stringify(snapshot));
      await this.pref.flush();
    }
    return snapshot;
  }

  async detectNetworkLocation(): Promise<NetworkLocation> {
    // Requests use the app's current route, including the active VPN. Never bind
    // them to the physical network: that would report the ISP instead of exit IP.
    for (const endpoint of ['https://ipwho.is/?lang=zh-CN', 'https://api.ip.sb/geoip']) {
      const client = http.createHttp();
      try {
        const response = await client.request(endpoint, {
          method: http.RequestMethod.GET, expectDataType: http.HttpDataType.STRING,
          usingCache: false, reuseConnections: false, addressFamily: http.AddressFamily.ONLY_V4,
          header: { 'User-Agent': 'FlClash-Harmony/1.0' },
          connectTimeout: 5000, readTimeout: 7000
        });
        if (response.responseCode !== 200) { continue; }
        const data = JSON.parse(String(response.result)) as Record<string, Object>;
        if (data['success'] === false || !data['ip'] || !data['country']) { continue; }
        return { ip: String(data['ip']), country: String(data['country']),
          city: String(data['city'] ?? ''), countryCode: String(data['country_code'] ?? '') };
      } catch (_) {
        // A blocked or unavailable lookup service may be retried via the fallback.
      } finally { client.destroy(); }
    }
    throw new Error('网络检测失败，点击重试');
  }

  async getTrafficSummary(): Promise<TrafficSummary> {
    const data = JSON.parse(await this.request('/connections')) as Record<string, Object>;
    return {
      upload: Number(data['uploadTotal'] ?? 0),
      download: Number(data['downloadTotal'] ?? 0)
    };
  }

  async getLocalIp(): Promise<string> {
    const networks = await connection.getAllNets();
    for (const network of networks) {
      const caps = await connection.getNetCapabilities(network);
      if (!caps.networkCap?.includes(connection.NetCap.NET_CAPABILITY_NOT_VPN)) { continue; }
      const properties = await connection.getConnectionProperties(network);
      if (properties.interfaceName.startsWith('tun') || properties.interfaceName.startsWith('lo')) { continue; }
      for (const link of properties.linkAddresses) {
        const address = link.address.address;
        if (link.address.family === 1 && !address.startsWith('127.') && !address.startsWith('169.254.')) {
          return address;
        }
      }
    }
    return '—';
  }

  async selectProxy(group: string, proxy: string): Promise<void> {
    await this.request(`/proxies/${encodeURIComponent(group)}`, http.RequestMethod.PUT, JSON.stringify({ name: proxy }));
    const result = JSON.parse(await this.request(`/proxies/${encodeURIComponent(group)}`)) as Record<string, Object>;
    if (String(result['now'] ?? '') !== proxy) { throw new Error('内核未确认节点选择，请重试'); }
    await this.rememberProxy(group, proxy);
  }

  async testOfflineDelay(name: string): Promise<number> {
    const profile = this.profiles.find((item: Profile) => item.id === this.selectedProfile);
    if (!profile) { throw new Error('请先选择配置'); }
    const result = JSON.parse(await core.testProfileDelay(profile.content, name)) as DelayResult;
    this.offlineDelays.set(`${profile.id}:${profile.updatedAt}:${name}`, result.error ? -1 : result.delay);
    if (result.error || result.delay <= 0) { throw new Error(result.error || '测速失败'); }
    return result.delay;
  }

  getSessionStartedAt(): number {
    try {
      const data = JSON.parse(fs.readTextSync(`${this.filesDir}/vpn-session.json`)) as Record<string, number>;
      return Number(data['startedAt'] ?? 0);
    } catch (_) { return 0; }
  }

  async getPreferredMode(): Promise<string> {
    return String(await this.pref?.get('preferredMode', 'rule') ?? 'rule');
  }

  async savePreferredMode(mode: string): Promise<void> {
    await this.pref?.put('preferredMode', mode);
    await this.pref?.flush();
  }

  async testDelay(name: string): Promise<number> {
    const url = encodeURIComponent('https://www.gstatic.com/generate_204');
    const epoch = this.delayEpoch;
    let failure: string = '节点测速失败';
    for (let attempt = 0; attempt < 2; attempt++) {
      if (epoch !== this.delayEpoch) { throw new Error('测速已取消'); }
      try {
        const data = JSON.parse(await this.request(`/proxies/${encodeURIComponent(name)}/delay?url=${url}&timeout=10000`,
          http.RequestMethod.GET, '', 13000)) as Record<string, Object>;
        const delay = Number(data['delay'] ?? 0);
        if (delay > 0) { return delay; }
      } catch (error) { failure = String(error); }
    }
    throw new Error(failure);
  }

  async getConnections(): Promise<ConnectionItem[]> {
    const data = JSON.parse(await this.request('/connections')) as Record<string, Object>;
    const entries = (data['connections'] as Array<Record<string, Object>>) ?? [];
    return entries.map((item: Record<string, Object>): ConnectionItem => {
      const metadata = (item['metadata'] as Record<string, Object>) ?? {};
      const chain = (item['chains'] as string[]) ?? [];
      const connection: ConnectionItem = {
        id: String(item['id'] ?? ''),
        host: String(metadata['host'] || metadata['destinationIP'] || ''),
        network: String(metadata['network'] ?? ''),
        chains: chain.join(' → '),
        upload: Number(item['upload'] ?? 0),
        download: Number(item['download'] ?? 0)
      };
      return connection;
    });
  }

  async closeConnection(id: string): Promise<void> {
    await this.request(`/connections/${encodeURIComponent(id)}`, http.RequestMethod.DELETE);
  }

  async getRules(): Promise<RuleItem[]> {
    const data = JSON.parse(await this.request('/rules')) as Record<string, Object>;
    const entries = (data['rules'] as Array<Record<string, Object>>) ?? [];
    return entries.map((item: Record<string, Object>): RuleItem => {
      const rule: RuleItem = {
        type: String(item['type'] ?? ''),
        payload: String(item['payload'] ?? ''),
        proxy: String(item['proxy'] ?? '')
      };
      return rule;
    });
  }

  private async download(url: string): Promise<DownloadedProfile> {
    if (!/^https?:\/\//.test(url.trim())) {
      throw new Error('订阅链接必须以 http:// 或 https:// 开头');
    }
    const client = http.createHttp();
    try {
      const result = await client.request(url.trim(), {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 10000,
        readTimeout: 20000,
        usingCache: false,
        header: { 'User-Agent': 'Clash.Meta OHClash/1.0', 'Accept': 'text/plain, application/yaml, */*' }
      });
      if (result.responseCode < 200 || result.responseCode >= 300) {
        throw new Error(`订阅下载失败：HTTP ${result.responseCode}`);
      }
      const rawHeaders: Object = result.header;
      let headers: Record<string, Object> = {};
      try {
        headers = (typeof rawHeaders === 'string' ? JSON.parse(rawHeaders) : rawHeaders) as Record<string, Object>;
      } catch (_) {}
      const rawInfo = Object.keys(headers).find((key: string) => key.toLowerCase() === 'subscription-userinfo');
      let subscription: SubscriptionInfo | undefined = undefined;
      if (rawInfo) {
        const parts: Record<string, number> = {};
        String(headers[rawInfo]).split(';').forEach((part: string) => {
          const pair = part.trim().split('=');
          if (pair.length === 2) { parts[pair[0].trim()] = Number(pair[1].trim()) || 0; }
        });
        subscription = { upload: parts['upload'] ?? 0, download: parts['download'] ?? 0,
          total: parts['total'] ?? 0, expire: parts['expire'] ?? 0 };
      }
      return { content: String(result.result), subscription };
    } finally {
      client.destroy();
    }
  }
}
