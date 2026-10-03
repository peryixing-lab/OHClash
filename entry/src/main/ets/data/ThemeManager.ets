import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { resourceManager } from '@kit.LocalizationKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

export type ThemeMode = 'dark' | 'light' | 'system';

export class ThemeManager {
  private static context?: common.UIAbilityContext;
  private static pref?: preferences.Preferences;
  private static mainWindow?: window.Window;
  private static mode: ThemeMode = 'dark';

  static initialize(context: common.UIAbilityContext): void {
    ThemeManager.context = context;
    try {
      ThemeManager.pref = preferences.getPreferencesSync(context, { name: 'ohclash_theme' });
      const saved = ThemeManager.pref.getSync('mode', 'dark');
      ThemeManager.mode = saved === 'light' || saved === 'system' ? saved : 'dark';
    } catch (error) { hilog.warn(0xF1C1, 'OHClashTheme', 'Cannot load theme: %{public}s', String(error)); }
    AppStorage.setOrCreate('themeMode', ThemeManager.mode);
    ThemeManager.updateAppearance(context.config.colorMode);
  }

  static attachWindow(mainWindow: window.Window): void {
    ThemeManager.mainWindow = mainWindow;
    ThemeManager.apply();
  }

  static detachWindow(): void { ThemeManager.mainWindow = undefined; }

  static select(mode: ThemeMode): void {
    // Persist before updating the UI, so a failed save never looks successful.
    if (!ThemeManager.pref) { throw new Error('主题设置尚未准备好，请重新打开应用'); }
    ThemeManager.pref.putSync('mode', mode);
    ThemeManager.pref.flushSync();
    ThemeManager.mode = mode;
    AppStorage.setOrCreate('themeMode', mode);
    ThemeManager.apply();
  }

  private static apply(): void {
    const colorMode = ThemeManager.mode === 'dark' ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK :
      ThemeManager.mode === 'light' ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT :
        ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    ThemeManager.context?.getApplicationContext().setColorMode(colorMode);
    // System resources remain independent of a previously forced app theme.
    ThemeManager.updateAppearance(resourceManager.getSystemResourceManager().getConfigurationSync().colorMode);
  }

  static updateAppearance(systemMode?: number): void {
    const dark = ThemeManager.mode === 'dark' ||
      (ThemeManager.mode === 'system' && systemMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    AppStorage.setOrCreate('themeDark', dark);
    ThemeManager.mainWindow?.setWindowBackgroundColor(dark ? '#191617' : '#FFFFFF');
    ThemeManager.mainWindow?.setWindowSystemBarProperties({
      statusBarColor: dark ? '#191617' : '#FFFFFF',
      navigationBarColor: dark ? '#191617' : '#FFFFFF',
      statusBarContentColor: dark ? '#EBDDE0' : '#252124',
      navigationBarContentColor: dark ? '#EBDDE0' : '#252124'
    }).catch((error: Error) => {
      hilog.warn(0xF1C1, 'OHClashTheme', 'Cannot update system bars: %{public}s', error.message);
    });
  }
}
