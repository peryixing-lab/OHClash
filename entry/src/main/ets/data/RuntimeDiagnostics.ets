import { hiAppEvent, hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from '@kit.CoreFileKit';

interface FaultParams {
  time?: number;
  pid?: number;
  process_name?: string;
  foreground?: boolean;
  reason?: string;
  external_log?: string[];
}

// System-delivered reports cover both the UI and VPN processes. Keep the
// observer alive for the process lifetime, including while the UI is hidden.
export class RuntimeDiagnostics {
  private static watching: boolean = false;

  static record(message: string): void {
    const safe = message.replace(/https?:\/\/[^\s"']+/g, '[URL]')
      .replace(/(secret|password|token|uuid)\s*[:=]\s*[^\s,}]+/gi, '$1=[redacted]');
    hilog.info(0xF1C1, 'OHClashDiagnostics', '%{public}s', safe.substring(0, 3500));
  }

  static watch(): void {
    if (RuntimeDiagnostics.watching) { return; }
    try {
      hiAppEvent.addWatcher({
        name: 'OHClashFaults',
        appEventFilters: [{ domain: hiAppEvent.domain.OS,
          names: [hiAppEvent.event.APP_CRASH, hiAppEvent.event.APP_FREEZE, hiAppEvent.event.APP_KILLED] }],
        onReceive: (_domain: string, groups: hiAppEvent.AppEventGroup[]): void => {
          groups.forEach((group: hiAppEvent.AppEventGroup) => {
            group.appEventInfos.forEach((event: hiAppEvent.AppEventInfo) => {
              const params = event.params as FaultParams;
              RuntimeDiagnostics.record(`${event.name} time=${params.time} pid=${params.pid} process=${params.process_name} foreground=${params.foreground} reason=${params.reason}`);
              (params.external_log ?? []).slice(0, 2).forEach((path: string) => {
                // Only read files delivered by the OS inside this app's log sandbox.
                if (!path.startsWith('/data/storage/el2/log/hiappevent/')) { return; }
                fs.readText(path, { length: 24000 }).then((report: string) => {
                  const lines = report.split('\n');
                  let frames = 0;
                  lines.forEach((line: string) => {
                    if (/^(Reason:|Exception|Error name:|Error message:|Pid:|Uid:|Process name:|Timestamp:|Fault thread|Signal:|LastFatalMessage:|#\d{2}|\s+at )/.test(line) && frames++ < 70) {
                      RuntimeDiagnostics.record(line);
                    }
                  });
                }).catch(() => { RuntimeDiagnostics.record('Fault report unavailable'); });
              });
            });
          });
        }
      });
      RuntimeDiagnostics.watching = true;
    } catch (error) { RuntimeDiagnostics.record(`Cannot register fault observer: ${String(error)}`); }
  }
}
