import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { window } from '@kit.ArkUI';

const PREF_NAME = 'ssrvpn_theme';
const KEY_THEME_MODE = 'theme_mode';

export enum AppThemeMode {
  SYSTEM = 'system',
  LIGHT = 'light',
  DARK = 'dark'
}

/**
 * 应用级主题服务。
 * 未手动选择时使用 COLOR_MODE_NOT_SET 跟随系统；手动选择后持久化 LIGHT/DARK。
 */
export class ThemeService {
  private static context: common.UIAbilityContext | null = null;
  private static store: preferences.Preferences | null = null;
  private static mode: AppThemeMode = AppThemeMode.SYSTEM;

  static async init(context: common.UIAbilityContext): Promise<AppThemeMode> {
    ThemeService.context = context;
    ThemeService.store = await preferences.getPreferences(context, { name: PREF_NAME });
    const saved = await ThemeService.store.get(KEY_THEME_MODE, AppThemeMode.SYSTEM) as string;
    ThemeService.mode = ThemeService.parseMode(saved);
    ThemeService.applyColorMode(ThemeService.mode);
    AppStorage.setOrCreate('theme_mode', ThemeService.mode);
    AppStorage.setOrCreate('theme_revision', 0);
    return ThemeService.mode;
  }

  static currentMode(): AppThemeMode {
    return ThemeService.mode;
  }

  static isDark(): boolean {
    if (ThemeService.mode === AppThemeMode.DARK) {
      return true;
    }
    if (ThemeService.mode === AppThemeMode.LIGHT) {
      return false;
    }
    return ThemeService.context?.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  /** 主页太阳按钮在明确的 LIGHT 与 DARK 之间切换。 */
  static async toggle(): Promise<AppThemeMode> {
    const next = ThemeService.isDark() ? AppThemeMode.LIGHT : AppThemeMode.DARK;
    await ThemeService.setMode(next);
    return next;
  }

  static async setMode(mode: AppThemeMode): Promise<void> {
    ThemeService.mode = mode;
    ThemeService.applyColorMode(mode);
    AppStorage.setOrCreate('theme_mode', mode);
    const revision = (AppStorage.get<number>('theme_revision') ?? 0) + 1;
    AppStorage.setOrCreate('theme_revision', revision);
    if (ThemeService.store !== null) {
      await ThemeService.store.put(KEY_THEME_MODE, mode);
      await ThemeService.store.flush();
    }
  }

  static async syncSystemBars(win: window.Window): Promise<void> {
    const dark = ThemeService.isDark();
    win.setWindowBackgroundColor(dark ? '#0A1020' : '#F5F7FC');
    await win.setWindowSystemBarProperties({
      statusBarColor: '#00000000',
      statusBarContentColor: dark ? '#F5F7FF' : '#171B2A',
      navigationBarColor: '#00000000',
      navigationBarContentColor: dark ? '#F5F7FF' : '#171B2A'
    });
  }

  private static applyColorMode(mode: AppThemeMode): void {
    if (ThemeService.context === null) {
      return;
    }
    let colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    if (mode === AppThemeMode.LIGHT) {
      colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    } else if (mode === AppThemeMode.DARK) {
      colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    ThemeService.context.getApplicationContext().setColorMode(colorMode);
  }

  private static parseMode(value: string): AppThemeMode {
    if (value === AppThemeMode.LIGHT) {
      return AppThemeMode.LIGHT;
    }
    if (value === AppThemeMode.DARK) {
      return AppThemeMode.DARK;
    }
    return AppThemeMode.SYSTEM;
  }
}
