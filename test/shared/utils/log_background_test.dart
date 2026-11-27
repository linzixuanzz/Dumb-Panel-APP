import 'package:daidai_app/core/theme/app_palette.dart';
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
      // 前景色是从最终底色的亮度推出来的，深底就必须给温润浅字。
      expect(theme.foreground, const Color(0xFFE7E5E4));
      // 次要文字是设计稿日志专项的 text2；默认底色上够读，原样不动。
      expect(theme.mutedForeground, AppPalette.dark.text2);
    });

    test('浅色模式留空 → 暖纸浅底深字', () {
      final theme = resolveLogSurfaceTheme(
        null,
        themeBrightness: Brightness.light,
      );

      expect(theme.background, AppColors.termBgLight);
      expect(theme.brightness, Brightness.light);
      expect(theme.foreground, const Color(0xFF1C1917));
      expect(theme.mutedForeground, AppPalette.light.text2);
    });

    test('兜底色有意与面板 Web 分叉：v3.0 Nordic Calm 的暖纸 / 护眼暗底', () {
      // 面板 web/src/utils/panelAppearance.ts 的
      // DEFAULT_LOG_BACKGROUND_COLOR_DARK / _LIGHT 是 #0F172A / #F8FAFC，
      // APP v2.x 曾与它逐字一致。v3.0 换成 Nordic Calm 的 #14161A / #FAF9F6
      // 是设计决定，两端默认观感从此不同；保留下来的契约只有
      // 「面板留空 = 跟随当前主题」（上面两条）。要改回或再改，先同步面板侧。
      expect(AppColors.termBgDark, const Color(0xFF14161A));
      expect(AppColors.termBgLight, const Color(0xFFFAF9F6));
      expect(AppColors.termBgDark, isNot(const Color(0xFF0F172A)));
      expect(AppColors.termBgLight, isNot(const Color(0xFFF8FAFC)));
    });

    test('forceNightTerminal 开启时在浅色主题下也强制使用 #14161A 护眼深底', () {
      final theme = resolveLogSurfaceTheme(
        null,
        themeBrightness: Brightness.light,
        forceNightTerminal: true,
      );

      expect(theme.background, const Color(0xFF14161A));
      expect(theme.brightness, Brightness.dark);
      expect(theme.foreground, const Color(0xFFE7E5E4));
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
      expect(theme.foreground, const Color(0xFF1C1917));
    });

    test('浅色模式下配了纯黑，就得给纯黑', () {
      final theme = resolveLogSurfaceTheme(
        const Color(0xFF000000),
        themeBrightness: Brightness.light,
      );

      expect(theme.background, const Color(0xFF000000));
      expect(theme.brightness, Brightness.dark);
      expect(theme.foreground, const Color(0xFFE7E5E4));
    });
  });

  group('次要文字对比度：默认底色和常见自定义底色上都 ≥ 4.5:1', () {
    // 次要文字（行数、空态、截断提示）是 11.5~13.5 号，按 WCAG AA 正文算。
    // 以前写死一个冷灰，只在默认底 #14161A 上量过；面板配成常见的编辑器深底
    // 就只剩 2~4:1。浅色默认那支压在栏底上也只有 4.35:1。
    const darkBackgrounds = <String, Color>{
      '默认护眼暗底': Color(0xFF14161A),
      '面板 Web 旧默认': Color(0xFF0F172A),
      '纯黑': Color(0xFF000000),
      'VS Code': Color(0xFF1E1E1E),
      'One Dark': Color(0xFF282C34),
      'Nord': Color(0xFF2E3440),
      '#333333': Color(0xFF333333),
      'Nord 浅一档': Color(0xFF3B4252),
      'Darcula': Color(0xFF3C3F41),
      'gray-600': Color(0xFF4B5563),
      '#505050': Color(0xFF505050),
    };
    const lightBackgrounds = <String, Color>{
      '默认暖纸': Color(0xFFFAF9F6),
      '面板 Web 旧默认': Color(0xFFF8FAFC),
      '纯白': Color(0xFFFFFFFF),
      'Solarized Light': Color(0xFFFDF6E3),
      'gray-200': Color(0xFFE5E7EB),
    };

    void expectReadable(String name, Color configured, Brightness expected) {
      for (final brightness in Brightness.values) {
        final theme = resolveLogSurfaceTheme(
          configured,
          themeBrightness: brightness,
        );
        expect(theme.brightness, expected, reason: name);
        // 空态压在日志底上，行数压在顶栏 / 底栏的栏底上。
        expect(
          logContrastRatio(theme.mutedForeground, theme.background),
          greaterThanOrEqualTo(kLogMinTextContrast),
          reason: '$name：次要文字 / 日志底',
        );
        expect(
          logContrastRatio(theme.mutedForeground, theme.barBackground),
          greaterThanOrEqualTo(kLogMinTextContrast),
          reason: '$name：次要文字 / 栏底',
        );
        // 搜索框是半透明 fill 叠在栏底上，页面经 readable 再校一次。
        // gray-600 这类中灰底上叠 14% 白之后，连主前景色都到不了 4.5:1，
        // 这时只要求「不比主前景色差」。
        final palette = theme.isDark ? AppPalette.dark : AppPalette.light;
        final field = Color.alphaBlend(palette.fill, theme.barBackground);
        final best = logContrastRatio(theme.foreground, field);
        expect(
          logContrastRatio(
            theme.readable(theme.mutedForeground, on: field),
            field,
          ),
          greaterThanOrEqualTo(
            best < kLogMinTextContrast ? best : kLogMinTextContrast,
          ),
          reason: '$name：次要文字 / 搜索框',
        );
      }
    }

    test('深色底', () {
      darkBackgrounds.forEach(
        (name, color) => expectReadable(name, color, Brightness.dark),
      );
    });

    test('浅色底', () {
      lightBackgrounds.forEach(
        (name, color) => expectReadable(name, color, Brightness.light),
      );
    });

    test('护眼暗底强制开启时同样够读', () {
      final theme = resolveLogSurfaceTheme(
        const Color(0xFFFFFFFF),
        themeBrightness: Brightness.light,
        forceNightTerminal: true,
      );
      expect(theme.mutedForeground, AppPalette.dark.text2);
      expect(
        logContrastRatio(theme.mutedForeground, theme.barBackground),
        greaterThanOrEqualTo(kLogMinTextContrast),
      );
    });

    test('默认底色上不做自适应：就是设计稿的 text2，不会被挪成别的灰', () {
      for (final brightness in Brightness.values) {
        final theme = resolveLogSurfaceTheme(
          null,
          themeBrightness: brightness,
        );
        final designed = brightness == Brightness.dark
            ? AppPalette.dark.text2
            : AppPalette.light.text2;
        expect(theme.mutedForeground, designed);
      }
    });

    test('偏灰的自定义深底：次要灰被往前景色提亮，但不直接等于前景色', () {
      final theme = resolveLogSurfaceTheme(
        const Color(0xFF3B4252),
        themeBrightness: Brightness.dark,
      );
      expect(theme.mutedForeground, isNot(AppPalette.dark.text2));
      expect(theme.mutedForeground, isNot(theme.foreground));
      expect(
        theme.mutedForeground.computeLuminance(),
        greaterThan(AppPalette.dark.text2.computeLuminance()),
      );
    });
  });

  group('ensureLogContrast', () {
    test('黑白对比度是 21:1', () {
      expect(
        logContrastRatio(const Color(0xFF000000), const Color(0xFFFFFFFF)),
        closeTo(21, 0.001),
      );
    });

    test('已经够读就原样返回', () {
      const ink = Color(0xFF68625D);
      expect(
        ensureLogContrast(
          ink,
          on: const [Color(0xFFFFFFFF)],
          toward: const Color(0xFF000000),
        ),
        ink,
      );
    });

    test('不够就朝目标色挪到刚好够', () {
      const gray = Color(0xFF8A8F98);
      const surface = Color(0xFF3B4252);
      final out = ensureLogContrast(
        gray,
        on: const [surface],
        toward: const Color(0xFFE7E5E4),
      );
      expect(out, isNot(gray));
      expect(logContrastRatio(out, surface), greaterThanOrEqualTo(4.5));
    });

    test('挪到头也不够就给目标色', () {
      // 中灰底上谁都到不了 4.5:1：给出能给的最好的那个，不死循环、不抛异常。
      final out = ensureLogContrast(
        const Color(0xFF777777),
        on: const [Color(0xFF808080)],
        toward: const Color(0xFF888888),
      );
      expect(out, const Color(0xFF888888));
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
