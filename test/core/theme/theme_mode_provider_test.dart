import 'package:daidai_app/core/theme/theme_mode_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 明暗设置（PRD A7）：本机键 app_theme_mode，默认跟随系统，应用级。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ThemeModeNotifier.resetForTest();
  });

  tearDown(ThemeModeNotifier.resetForTest);

  /// 让构造函数里的补读跑完。
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('没设过：跟随系统', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await settle();
    expect(container.read(themeModeProvider), ThemeMode.system);
    expect(container.read(themeModeProvider.notifier).value, 'system');
  });

  for (final (stored, mode) in const [
    ('light', ThemeMode.light),
    ('dark', ThemeMode.dark),
    ('system', ThemeMode.system),
    ('purple', ThemeMode.system), // 不认识的值回落跟随系统
  ]) {
    test('存的是 $stored：读出 $mode', () async {
      SharedPreferences.setMockInitialValues({
        ThemeModeNotifier.prefsKey: stored,
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(themeModeProvider);
      await settle();
      expect(container.read(themeModeProvider), mode);
    });
  }

  test('设置：内存立刻生效并落盘，下次启动预读回来', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(themeModeProvider.notifier).set(ThemeMode.dark);
    expect(container.read(themeModeProvider), ThemeMode.dark);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ThemeModeNotifier.prefsKey), 'dark');

    // 模拟重启：预读后第一帧就是深色，不经过「跟随系统」
    ThemeModeNotifier.resetForTest();
    await ThemeModeNotifier.preload();
    final next = ProviderContainer();
    addTearDown(next.dispose);
    expect(next.read(themeModeProvider), ThemeMode.dark);
  });

  test('补读还没回来时用户先选了：不会被补读的旧值盖回去', () async {
    SharedPreferences.setMockInitialValues({
      ThemeModeNotifier.prefsKey: 'light',
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // 构造即开始补读；补读完成前用户选了深色
    final notifier = container.read(themeModeProvider.notifier);
    final saving = notifier.set(ThemeMode.dark);
    await settle();
    await saving;
    expect(container.read(themeModeProvider), ThemeMode.dark);
  });
}
