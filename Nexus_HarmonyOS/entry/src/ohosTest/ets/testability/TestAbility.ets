/**
 * ohosTest 宿主 Ability。
 *
 * 修复说明：原模板在 loadContent 回调里调用 `delegator.sendState('')`，该方法在
 * API 26 的 AbilityDelegator 上并不存在（编译期报 sendState 不存在），且整个文件
 * 从未调用 `Hypium.hypiumTest(...)`，即用例集实际不会被执行。这里按当前 hypium
 * 契约补齐真正的启动链路：onCreate 取 delegator + 运行期参数，注入 List.test
 * 导出的 testsuite（logicTest + vpnArchTest）。
 */
import UIAbility from '@ohos.app.ability.UIAbility';
import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import type Want from '@ohos.app.ability.Want';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { Hypium } from '@ohos/hypium';
import testsuite from '../test/List.test';

const TAG: string = 'TestAbility';

export default class TestAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, TAG, `onCreate (launchParam=${launchParam === undefined ? 'none' : 'present'})`);
    const abilityDelegator = AbilityDelegatorRegistry.getAbilityDelegator();
    const abilityDelegatorArguments = AbilityDelegatorRegistry.getArguments();
    hilog.info(0x0000, TAG, 'bootstrapping hypium suites');
    Hypium.hypiumTest(abilityDelegator, abilityDelegatorArguments, testsuite);
  }

  onDestroy(): void {
    hilog.info(0x0000, TAG, 'onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(0x0000, TAG, 'onWindowStageCreate');
    // 仅为 UI 相关用例提供窗口宿主；测试执行本身在 onCreate 已启动。
    windowStage.loadContent('testability/pages/Index', (err: Error): void => {
      if (err) {
        hilog.error(0x0000, TAG, `loadContent failed: ${err instanceof Error ? err.message : String(err)}`);
        return;
      }
      hilog.info(0x0000, TAG, 'loadContent ok');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(0x0000, TAG, 'onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(0x0000, TAG, 'onForeground');
  }

  onBackground(): void {
    hilog.info(0x0000, TAG, 'onBackground');
  }
}
