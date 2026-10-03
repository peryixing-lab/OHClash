import { AbilityConstant, Configuration, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { RuntimeDiagnostics } from '../data/RuntimeDiagnostics';
import { ThemeManager } from '../data/ThemeManager';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    ThemeManager.initialize(this.context);
    RuntimeDiagnostics.watch();
    RuntimeDiagnostics.record(`UI created: lastExitReason=${launchParam.lastExitReason} message=${launchParam.lastExitMessage}`);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    RuntimeDiagnostics.record('UI destroyed');
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/ReferenceHome', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      ThemeManager.attachWindow(windowStage.getMainWindowSync());
    });
  }

  onConfigurationUpdate(configuration: Configuration): void {
    ThemeManager.updateAppearance(configuration.colorMode);
  }

  onWindowStageDestroy(): void {
    ThemeManager.detachWindow();
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    RuntimeDiagnostics.record('UI foreground');
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    RuntimeDiagnostics.record('UI background');
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
