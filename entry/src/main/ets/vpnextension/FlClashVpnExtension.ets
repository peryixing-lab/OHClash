import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import * as core from 'libflclash_napi.so';
import { RuntimeDiagnostics } from '../data/RuntimeDiagnostics';

const DOMAIN = 0xF1C1;

interface VpnCommand {
  sessionId: string;
  action: string;
  requestedAt: number;
  secret: string;
}

interface VpnRuntimeStatus {
  sessionId: string;
  status: string;
  error: string;
  updatedAt: number;
  cleanupComplete: boolean;
}

interface VpnSession {
  sessionId: string;
  startedAt: number;
}

export default class FlClashVpnExtension extends VpnExtensionAbility {
  private connection?: vpnExtension.VpnConnection;
  private connectionCreated: boolean = false;
  private coreAttempted: boolean = false;
  private pendingFd: number = -1;
  private cancelled: boolean = false;
  private sessionId: string = '';
  private status: string = 'starting';
  private statusError: string = '';
  private cleaned: boolean = false;
  private startup?: Promise<void>;
  private stopping?: Promise<void>;
  private coreStopping?: Promise<void>;
  private cleanup?: Promise<void>;
  private commandTimer: number = -1;
  private lastHeartbeat: number = 0;

  onCreate(): void {
    RuntimeDiagnostics.watch();
    RuntimeDiagnostics.record('VPN extension created');
    hilog.info(DOMAIN, 'FlClashVPN', 'VPN extension created');
    const command = this.readCommand();
    if (!command || !command.sessionId) {
      hilog.error(DOMAIN, 'FlClashVPN', 'Missing VPN session command; refusing unowned startup');
      return;
    }
    this.sessionId = command.sessionId;
    if (command.action !== 'start') {
      this.cleaned = true;
      this.publishStatus('stopped');
      return;
    }
    this.publishStatus('starting');
    this.commandTimer = setInterval(() => { this.pollCommand(); }, 250);
    this.startup = this.start(command.secret);
  }

  private readCommand(): VpnCommand | undefined {
    try {
      return JSON.parse(fs.readTextSync(`${this.context.filesDir}/vpn-command.json`)) as VpnCommand;
    } catch (_) { return undefined; }
  }

  private ownsSession(): boolean {
    return this.sessionId.length > 0 && this.readCommand()?.sessionId === this.sessionId;
  }

  private writeJson(name: string, content: string): void {
    const path = `${this.context.filesDir}/${name}`;
    const temporary = `${path}.extension.tmp`;
    const file = fs.openSync(temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try { fs.writeSync(file.fd, content); } finally { fs.closeSync(file); }
    fs.renameSync(temporary, path);
  }

  private publishStatus(status: string, error: string = ''): void {
    this.status = status;
    this.statusError = error;
    if (!this.ownsSession()) { return; }
    const data: VpnRuntimeStatus = {
      sessionId: this.sessionId, status, error,
      updatedAt: Date.now(), cleanupComplete: this.cleaned
    };
    try {
      this.writeJson('vpn-status.json', JSON.stringify(data));
      this.lastHeartbeat = data.updatedAt;
    } catch (failure) {
      hilog.error(DOMAIN, 'FlClashVPN', 'Cannot publish VPN state: %{public}s', String(failure));
    }
  }

  private pollCommand(): void {
    const command = this.readCommand();
    if (!command || command.sessionId !== this.sessionId || command.action !== 'start') {
      this.requestStop();
      return;
    }
    if (Date.now() - this.lastHeartbeat >= 2000) {
      this.publishStatus(this.status, this.statusError);
    }
  }

  private checkStartAllowed(): void {
    const command = this.readCommand();
    if (this.cancelled || !command || command.sessionId !== this.sessionId || command.action !== 'start') {
      this.cancelled = true;
      throw new Error('VPN 启动已取消');
    }
  }

  private async start(secret: string): Promise<void> {
    let failure: string = '';
    try {
      this.checkStartAllowed();
      if (!secret) { throw new Error('VPN 会话凭据缺失，请重新连接'); }
      // Configure the core before changing the system route. Profile/provider
      // loading must not route into a TUN that has no reader yet.
      this.coreAttempted = true;
      const launchError = await core.launchAsync(this.context.filesDir, secret);
      this.checkStartAllowed();
      if (launchError.length > 0) { throw new Error(launchError); }
      hilog.info(DOMAIN, 'FlClashVPN', 'Native core launch completed');
      this.connection = vpnExtension.createVpnConnection(this.context);
      const address: vpnExtension.LinkAddress = {
        address: { address: '172.19.0.1', family: 1 }, prefixLength: 30
      };
      const route: vpnExtension.RouteInfo = {
        interface: 'vpn-tun',
        destination: { address: { address: '0.0.0.0', family: 1 }, prefixLength: 0 },
        gateway: { address: '172.19.0.1', family: 1 },
        hasGateway: false,
        isDefaultRoute: true
      };
      const config: vpnExtension.VpnConfig = {
        addresses: [address], routes: [route], dnsAddresses: ['172.19.0.2'],
        mtu: 1400, isIPv4Accepted: true, isIPv6Accepted: false
      };
      this.pendingFd = await this.connection.create(config);
      // Never destroy a connection whose create() failed: it may belong to a
      // different VPN application (2203002).
      this.connectionCreated = true;
      hilog.info(DOMAIN, 'FlClashVPN', 'VPN TUN created');
      this.checkStartAllowed();
      const fd = this.pendingFd;
      this.pendingFd = -1;
      // startTunAsync takes ownership of fd, including cancellation/failure.
      const started = await core.startTunAsync(fd);
      this.checkStartAllowed();
      if (!started) { throw new Error(`mihomo 无法读取系统 TUN 接口: ${core.getTunError()}`); }
      const session: VpnSession = { sessionId: this.sessionId, startedAt: Date.now() };
      this.writeJson('vpn-session.json', JSON.stringify(session));
      this.publishStatus('running');
      hilog.info(DOMAIN, 'FlClashVPN', 'Native TUN started');
      return;
    } catch (error) {
      if (!this.cancelled) {
        const vpnError = error as BusinessError;
        failure = vpnError.code === 2203002
          ? '系统已有 VPN 连接，请先断开其他 VPN 后重试（2203002）'
          : (vpnError.message || String(error));
        hilog.error(DOMAIN, 'FlClashVPN', 'VPN start failed: %{public}s', failure);
      }
    }
    try { await this.releaseResources(); }
    catch (error) { failure = `${failure ? `${failure}；` : ''}VPN 清理失败：${String(error)}`; }
    this.clearCommandTimer();
    this.publishStatus(failure ? 'error' : 'stopped', failure);
  }

  private stopCore(): Promise<void> {
    if (!this.coreStopping) {
      this.coreStopping = this.coreAttempted ? core.stopAsync() : Promise.resolve();
      // A stop requested during launch is awaited by releaseResources after
      // startup settles. Attach a rejection handler immediately in that gap.
      this.coreStopping.catch(() => {});
    }
    return this.coreStopping;
  }

  private releaseResources(): Promise<void> {
    if (!this.cleanup) { this.cleanup = this.releaseOwnedResources(); }
    return this.cleanup;
  }

  private async releaseOwnedResources(): Promise<void> {
    let failure: string = '';
    try { await this.stopCore(); }
    catch (error) { failure = String(error); }
    if (this.pendingFd >= 0) {
      try { fs.closeSync(this.pendingFd); }
      catch (error) { hilog.warn(DOMAIN, 'FlClashVPN', 'Unused TUN fd cleanup: %{public}s', String(error)); }
      this.pendingFd = -1;
    }
    if (this.connectionCreated && this.connection) {
      try {
        await this.connection.destroy();
        this.connectionCreated = false;
      } catch (error) { failure = `${failure ? `${failure}；` : ''}${String(error)}`; }
    }
    if (failure) { throw new Error(failure); }
    this.cleaned = true;
    this.connection = undefined;
    try {
      const path = `${this.context.filesDir}/vpn-session.json`;
      const session = JSON.parse(fs.readTextSync(path)) as VpnSession;
      if (session.sessionId === this.sessionId) { fs.unlinkSync(path); }
    } catch (_) {}
  }

  private requestStop(): void {
    if (this.stopping) { return; }
    this.cancelled = true;
    this.publishStatus('stopping');
    // Invalidate native queued startup work immediately. Completion remains
    // asynchronous, and stopped is only acknowledged once all cleanup finishes.
    this.stopCore();
    this.stopping = this.finishStop();
  }

  private async finishStop(): Promise<void> {
    try {
      await this.startup;
      await this.releaseResources();
      this.publishStatus('stopped');
    } catch (error) {
      const detail = `VPN 清理失败：${String(error)}`;
      hilog.error(DOMAIN, 'FlClashVPN', '%{public}s', detail);
      this.publishStatus('error', detail);
    } finally { this.clearCommandTimer(); }
  }

  private clearCommandTimer(): void {
    if (this.commandTimer >= 0) {
      clearInterval(this.commandTimer);
      this.commandTimer = -1;
    }
  }

  onDestroy(): void {
    RuntimeDiagnostics.record(`VPN extension destroyed: status=${this.status} cancelled=${this.cancelled}`);
    this.requestStop();
  }
}
