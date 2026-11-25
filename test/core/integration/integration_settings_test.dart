import 'package:daidai_app/core/integration/integration_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 常驻通知开关（第二波契约，B6 的设置页读写它）：本机键 integration.running_notification，默认关。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    RunningNotificationSetting.resetForTest();
  });

  tearDown(RunningNotificationSetting.resetForTest);

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('没设过：默认关（flutter test 里默认平台是安卓，supported 为 true）', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await settle();
    expect(container.read(runningNotificationEnabledProvider), isFalse);
    expect(
      container.read(runningNotificationEnabledProvider.notifier).supported,
      isTrue,
    );
  });

  test('构造函数不读本机设置（子类覆写时不碰 prefs / 插件），load() 才读', () async {
    RunningNotificationSetting.supportedOverride = true;
    SharedPreferences.setMockInitialValues({
      RunningNotificationSetting.prefsKey: true,
    });
    final setting = RunningNotificationSetting();
    addTearDown(setting.dispose);
    await settle();
    expect(setting.state, isFalse);
    await setting.load();
    expect(setting.state, isTrue);
  });

  test('iOS 上不支持', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(
      container.read(runningNotificationEnabledProvider.notifier).supported,
      isFalse,
    );
  });

  test('不支持的平台：打开也返回 false，不申请权限', () async {
    RunningNotificationSetting.supportedOverride = false;
    var asked = 0;
    RunningNotificationSetting.requestPermissionOverride = () async {
      asked++;
      return true;
    };
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final ok = await container
        .read(runningNotificationEnabledProvider.notifier)
        .setEnabled(true);
    expect(ok, isFalse);
    expect(asked, 0);
    expect(container.read(runningNotificationEnabledProvider), isFalse);
  });

  test('安卓：打开时申请权限，同意 → 开启并落盘', () async {
    RunningNotificationSetting.supportedOverride = true;
    var asked = 0;
    RunningNotificationSetting.requestPermissionOverride = () async {
      asked++;
      return true;
    };
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final ok = await container
        .read(runningNotificationEnabledProvider.notifier)
        .setEnabled(true);
    expect(ok, isTrue);
    expect(asked, 1);
    expect(container.read(runningNotificationEnabledProvider), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(RunningNotificationSetting.prefsKey), isTrue);
  });

  test('安卓：用户拒绝通知权限 → 保持关闭，返回 false', () async {
    RunningNotificationSetting.supportedOverride = true;
    RunningNotificationSetting.requestPermissionOverride = () async => false;
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final ok = await container
        .read(runningNotificationEnabledProvider.notifier)
        .setEnabled(true);
    expect(ok, isFalse);
    expect(container.read(runningNotificationEnabledProvider), isFalse);
  });

  test('关闭不申请权限；重启后读回存的值', () async {
    RunningNotificationSetting.supportedOverride = true;
    SharedPreferences.setMockInitialValues({
      RunningNotificationSetting.prefsKey: true,
    });
    var asked = 0;
    RunningNotificationSetting.requestPermissionOverride = () async {
      asked++;
      return true;
    };
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(runningNotificationEnabledProvider);
    await settle();
    expect(container.read(runningNotificationEnabledProvider), isTrue);

    await container
        .read(runningNotificationEnabledProvider.notifier)
        .setEnabled(false);
    expect(asked, 0);
    expect(container.read(runningNotificationEnabledProvider), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(RunningNotificationSetting.prefsKey), isFalse);
  });
}
