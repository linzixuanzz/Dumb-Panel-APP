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

/// 色板：PRD 验收第 2 条「正文与次要文字 ≥ 4.5:1」、状态色当文字用墨色，
/// 以及实色底上的前景（onStatus / Checkbox 的勾 / Switch 打开时的滑块）、
/// 分段滑块的可见度。
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

      // 红底确认按钮的文字、实色徽章的数字、实色图标方块的图标都压在状态实色上。
      // v3.0 深色把状态色提亮后，白字压红只剩 2.77:1，所以深色改用深墨。
      test('onStatus 压在五个状态实色上都看得清', () {
        final solids = {
          'accent': p.accent,
          'ok': p.ok,
          'err': p.err,
          'warn': p.warn,
          'purple': p.purple,
        };
        solids.forEach((key, solid) {
          // 浅色琥珀上的白只有 3.19:1：浅色 warn 实底只放图标（非文本 3:1），
          // 当文字的地方用 warnInk。其余组合都按正文 4.5:1 钉住。
          final min = p.isLight && key == 'warn' ? 3.0 : 4.5;
          expect(
            _contrast(p.onStatus, solid),
            greaterThanOrEqualTo(min),
            reason: 'onStatus on $key',
          );
        });
      });

      test('分段控件选中滑块看得出来，滑块上的选中文字仍 ≥ 4.5:1', () {
        expect(_contrast(p.text, p.thumb), greaterThanOrEqualTo(4.5));
        // 深色滑块没有投影，只能靠底色和 card2 底槽拉开（旧值 #32363F 只有
        // 1.22:1，几乎看不见）。浅色是白块加投影，不靠这一条。
        if (!p.isLight) {
          expect(_contrast(p.thumb, p.card2), greaterThanOrEqualTo(2.3));
        }
      });
    });
  }

  test('Checkbox 的勾与 primary / error 上的前景跟 onStatus 走', () {
    for (final (theme, p) in [
      (AppTheme.light(), AppPalette.light),
      (AppTheme.dark(), AppPalette.dark),
    ]) {
      final cs = theme.colorScheme;
      expect(_contrast(cs.onPrimary, cs.primary), greaterThanOrEqualTo(4.5));
      expect(_contrast(cs.onError, cs.error), greaterThanOrEqualTo(4.5));
      final check = theme.checkboxTheme.checkColor!.resolve({
        WidgetState.selected,
      });
      final fill = theme.checkboxTheme.fillColor!.resolve({
        WidgetState.selected,
      });
      expect(check, p.onStatus);
      expect(fill, p.accent);
      expect(_contrast(check!, fill!), greaterThanOrEqualTo(4.5));
    }
  });

  // 写死白色时深色打开态只有 2.89:1（白压 #6C93FF）。
  test('Switch 打开时滑块跟 onStatus 走，压 accent 轨道 ≥ 3:1（非文字）', () {
    for (final (theme, p) in [
      (AppTheme.light(), AppPalette.light),
      (AppTheme.dark(), AppPalette.dark),
    ]) {
      final on = {WidgetState.selected};
      final thumb = theme.switchTheme.thumbColor!.resolve(on);
      final track = theme.switchTheme.trackColor!.resolve(on);
      expect(thumb, p.onStatus);
      expect(track, p.accent);
      expect(_contrast(thumb!, track!), greaterThanOrEqualTo(3.0));
    }
  });

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
