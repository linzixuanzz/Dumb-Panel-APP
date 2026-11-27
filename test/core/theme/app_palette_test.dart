import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/core/theme/design_tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// WCAG 对比度。
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// v2.0 色板：PRD 验收第 2 条「正文与次要文字 ≥ 4.5:1」、状态色当文字用墨色。
void main() {
  for (final (name, p) in [
    ('浅色', AppPalette.light),
    ('深色', AppPalette.dark),
  ]) {
    group(name, () {
      test('正文与次要文字对卡片和页面底色都 ≥ 4.5:1', () {
        for (final surface in [p.card, p.bg]) {
          expect(_contrast(p.text, surface), greaterThanOrEqualTo(4.5));
          expect(_contrast(p.text2, surface), greaterThanOrEqualTo(4.5));
        }
      });

      test('五个墨色对卡片和页面底色都 ≥ 4.5:1', () {
        final inks = {
          'accentInk': p.accentInk,
          'okInk': p.okInk,
          'errInk': p.errInk,
          'warnInk': p.warnInk,
          'purpleInk': p.purpleInk,
        };
        inks.forEach((key, ink) {
          for (final surface in [p.card, p.bg]) {
            expect(
              _contrast(ink, surface),
              greaterThanOrEqualTo(4.5),
              reason: '$key on $surface',
            );
          }
        });
      });

      test('主按钮前景对背景 ≥ 4.5:1', () {
        expect(
          _contrast(p.primaryBtnFg, p.primaryBtnBg),
          greaterThanOrEqualTo(4.5),
        );
      });
    });
  }

  test('强调色走 Nordic Cobalt 钴蓝体系；主按钮统一钴蓝底配纯白字', () {
    expect(AppPalette.light.accent, const Color(0xFF2B5BEE));
    expect(AppPalette.dark.accent, const Color(0xFF6C93FF));
    expect(AppPalette.light.primaryBtnBg, const Color(0xFF2B5BEE));
    expect(AppPalette.light.primaryBtnFg, const Color(0xFFFFFFFF));
    expect(AppPalette.dark.primaryBtnBg, const Color(0xFF2B5BEE));
    expect(AppPalette.dark.primaryBtnFg, const Color(0xFFFFFFFF));
  });

  test('ThemeData 挂了色板扩展，Material 组件映射到令牌', () {
    final light = AppTheme.light();
    final dark = AppTheme.dark();
    expect(light.extension<AppPalette>(), AppPalette.light);
    expect(dark.extension<AppPalette>(), AppPalette.dark);
    expect(light.scaffoldBackgroundColor, AppPalette.light.bg);
    expect(dark.scaffoldBackgroundColor, AppPalette.dark.bg);
    expect(light.colorScheme.primary, AppPalette.light.accent);
    // 主按钮：FilledButton 的底色是黑（深色白）
    final filled = light.filledButtonTheme.style!.backgroundColor!.resolve({});
    expect(filled, AppPalette.light.primaryBtnBg);
    final filledDark = dark.filledButtonTheme.style!.backgroundColor!.resolve(
      {},
    );
    expect(filledDark, AppPalette.dark.primaryBtnBg);
  });

  test('lerp 两端分别等于浅色 / 深色', () {
    expect(AppPalette.light.lerp(AppPalette.dark, 0).bg, AppPalette.light.bg);
    expect(AppPalette.light.lerp(AppPalette.dark, 1).bg, AppPalette.dark.bg);
    expect(AppPalette.light.copyWith(accent: Colors.red).accent, Colors.red);
  });

  testWidgets('context.palette 跟随主题明暗；没挂扩展时按明暗回落', (tester) async {
    late AppPalette lightP, darkP, bareP;
    await tester.pumpWidget(
      Column(
        children: [
          Theme(
            data: AppTheme.light(),
            child: Builder(
              builder: (c) {
                lightP = c.palette;
                return const SizedBox();
              },
            ),
          ),
          Theme(
            data: AppTheme.dark(),
            child: Builder(
              builder: (c) {
                darkP = c.palette;
                return const SizedBox();
              },
            ),
          ),
          Theme(
            data: ThemeData(brightness: Brightness.dark),
            child: Builder(
              builder: (c) {
                bareP = c.palette;
                return const SizedBox();
              },
            ),
          ),
        ],
      ),
    );
    expect(lightP, AppPalette.light);
    expect(darkP, AppPalette.dark);
    expect(bareP, AppPalette.dark);
  });

  testWidgets('AppMotion.reduce 跟随系统「移除动画」', (tester) async {
    late bool reduceOff, reduceOn;
    await tester.pumpWidget(
      Column(
        children: [
          Builder(
            builder: (c) {
              reduceOff = AppMotion.reduce(c);
              return const SizedBox();
            },
          ),
          MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Builder(
              builder: (c) {
                reduceOn = AppMotion.reduce(c);
                expect(AppMotion.of(c, AppMotion.slide), Duration.zero);
                return const SizedBox();
              },
            ),
          ),
        ],
      ),
    );
    expect(reduceOff, isFalse);
    expect(reduceOn, isTrue);
  });

  test('AppText.tabular 打开等宽数字且遵循 v3.0 四阶克制字号', () {
    final style = AppText.tabular(AppText.body);
    expect(style.fontFeatures, contains(const FontFeature.tabularFigures()));
    expect(style.fontSize, 15);
    expect(AppText.largeTitle.fontSize, 23);
    expect(AppText.largeTitle.fontWeight, FontWeight.w600);
  });
}
