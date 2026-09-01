import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/shared/utils/log_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 日志底色的回归保护（issue #2「日志背景颜色失效」）。
///
/// 用户报的现象是「深色模式下输出日志背景是白的」。根因是
/// `resolveLogSurfaceTheme` 的兜底底色写死成一个恒定的白，函数签名里
/// 压根没有主题亮度，物理上不可能知道当前是不是深色模式。
///
/// 面板那边 `log_background_color` 的出厂默认就是空串，注册说明写的是
/// 「留空跟随当前主题」，所以「留空 → 跟随明暗」是契约，不是可选优化。
void main() {
  group('resolveLogSurfaceTheme：面板留空时按主题回落', () {
    test('深色模式留空 → 深底浅字（issue #2 的直接锁）', () {
      final theme = resolveLogSurfaceTheme(
        null,
        themeBrightness: Brightness.dark,
      );

      expect(theme.background, AppColors.termBgDark);
      expect(theme.brightness, Brightness.dark);
      // 前景色是从最终底色的亮度推出来的，深底就必须给浅字。
      expect(theme.foreground, AppColors.slate50);
      expect(theme.mutedForeground, AppColors.slate300);
    });

    test('浅色模式留空 → 浅底深字', () {
      final theme = resolveLogSurfaceTheme(
        null,
        themeBrightness: Brightness.light,
      );

      expect(theme.background, AppColors.termBgLight);
      expect(theme.brightness, Brightness.light);
      expect(theme.foreground, AppColors.slate900);
      expect(theme.mutedForeground, AppColors.slate500);
    });

    test('兜底色与面板 Web 同值：两端观感必须是同一个产品', () {
      // 面板 web/src/utils/panelAppearance.ts 的
      // DEFAULT_LOG_BACKGROUND_COLOR_DARK / _LIGHT。改这两个值等于让 APP 和网页分叉。
      expect(AppColors.termBgDark, const Color(0xFF0F172A));
      expect(AppColors.termBgLight, const Color(0xFFF8FAFC));
    });
  });

  group('resolveLogSurfaceTheme：用户显式配的颜色永远压过主题', () {
    test('深色模式下配了白底，就得给白底 —— 不许「好心」改成深色', () {
      final theme = resolveLogSurfaceTheme(
        const Color(0xFFFFFFFF),
        themeBrightness: Brightness.dark,
      );

      expect(theme.background, const Color(0xFFFFFFFF));
      // 底色是白的，前景就得跟着翻成深字，否则白底白字全糊。
      expect(theme.brightness, Brightness.light);
      expect(theme.foreground, AppColors.slate900);
    });

    test('浅色模式下配了纯黑，就得给纯黑', () {
      final theme = resolveLogSurfaceTheme(
        const Color(0xFF000000),
        themeBrightness: Brightness.light,
      );

      expect(theme.background, const Color(0xFF000000));
      expect(theme.brightness, Brightness.dark);
      expect(theme.foreground, AppColors.slate50);
    });
  });

  group('parseColorSetting：面板那两个控件能产出的全部形态', () {
    test('#rrggbb', () {
      // 用户在 issue 里填的就是这个。
      expect(parseColorSetting('#000000'), const Color(0xFF000000));
      expect(parseColorSetting('#0F172A'), const Color(0xFF0F172A));
      // 十六进制大小写都要认。
      expect(parseColorSetting('#0f172a'), const Color(0xFF0F172A));
      // 面板 SetConfig 只做 trim，库里可能带前后空白。
      expect(parseColorSetting('  #000000  '), const Color(0xFF000000));
    });

    test('#rrggbbaa（带 alpha，8 位）', () {
      expect(parseColorSetting('#0F172A80'), const Color(0x0F172A80));
    });

    test('rgb() / rgba()：el-color-picker 开了 show-alpha 就会写这种', () {
      expect(parseColorSetting('rgb(15, 23, 42)'), const Color(0xFF0F172A));
      expect(parseColorSetting('rgba(0, 0, 0, 1)'), const Color(0xFF000000));
      expect(parseColorSetting('RGBA(15,23,42,1)'), const Color(0xFF0F172A));

      final half = parseColorSetting('rgba(0, 0, 0, 0.5)');
      expect(half, isNotNull);
      expect(half!.a, closeTo(0.5, 0.01));
    });

    test('空值与脏值一律返回 null，交给调用方按主题回落', () {
      expect(parseColorSetting(null), isNull);
      expect(parseColorSetting(''), isNull);
      expect(parseColorSetting('   '), isNull);
      expect(parseColorSetting('transparent'), isNull);
      expect(parseColorSetting('#12345'), isNull); // 位数不对
      expect(parseColorSetting('#gggggg'), isNull); // 非十六进制
      expect(parseColorSetting('rgb(1, 2)'), isNull); // 少一个分量
    });
  });
}
