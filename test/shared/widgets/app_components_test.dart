import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/core/theme/design_tokens.dart';
import 'package:daidai_app/shared/widgets/app_buttons.dart';
import 'package:daidai_app/shared/widgets/app_card.dart';
import 'package:daidai_app/shared/widgets/app_circle_add_button.dart';
import 'package:daidai_app/shared/widgets/app_glass_circle_button.dart';
import 'package:daidai_app/shared/widgets/app_grouped_list.dart';
import 'package:daidai_app/shared/widgets/app_icon_tile.dart';
import 'package:daidai_app/shared/widgets/app_large_title_header.dart';
import 'package:daidai_app/shared/widgets/app_notice.dart';
import 'package:daidai_app/shared/widgets/app_pill_button.dart';
import 'package:daidai_app/shared/widgets/app_section_title.dart';
import 'package:daidai_app/shared/widgets/app_segmented.dart';
import 'package:daidai_app/shared/widgets/app_snack.dart';
import 'package:daidai_app/shared/widgets/app_state_views.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(
  Widget child, {
  bool dark = false,
  bool reduceMotion = false,
}) {
  return MaterialApp(
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    themeMode: dark ? ThemeMode.dark : ThemeMode.light,
    builder: (context, app) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: app!,
    ),
    home: Scaffold(body: Center(child: child)),
  );
}

/// 找某个组件里第一个 DecoratedBox / Container 的底色。
Color? _colorOf(WidgetTester tester, Finder finder) {
  final box = tester.widget<DecoratedBox>(
    find.descendant(of: finder, matching: find.byType(DecoratedBox)).first,
  );
  return (box.decoration as BoxDecoration).color;
}

void main() {
  group('AppLargeTitleHeader', () {
    testWidgets('大标题 23 / w600（v3.0 Nordic Calm），副标题次要色，右侧按钮从左到右排', (tester) async {
      await tester.pumpWidget(
        _wrap(
          AppLargeTitleHeader(
            title: '设置',
            subtitle: '家里的 NAS',
            actions: [
              AppGlassCircleButton(icon: Icons.search, onTap: () {}, tooltip: '搜索'),
              AppGlassCircleButton(icon: Icons.add, onTap: () {}, tooltip: '新建'),
            ],
          ),
        ),
      );
      final title = tester.widget<Text>(find.text('设置'));
      expect(title.style!.fontSize, 23);
      expect(title.style!.fontWeight, FontWeight.w600);
      final subtitle = tester.widget<Text>(find.text('家里的 NAS'));
      expect(subtitle.style!.color, AppPalette.light.text2);
      expect(
        tester.getCenter(find.byTooltip('搜索')).dx,
        lessThan(tester.getCenter(find.byTooltip('新建')).dx),
      );
    });

    testWidgets('sliver 版本能放进 CustomScrollView；窄屏长标题不溢出', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _wrap(
          CustomScrollView(
            slivers: [
              AppLargeTitleHeader.sliver(
                title: '一个非常非常非常长的大标题文字',
                actions: [
                  AppGlassCircleButton(icon: Icons.add, onTap: () {}, tooltip: '新建'),
                ],
              ),
            ],
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('新建'), findsOneWidget);
    });
  });

  group('AppGlassCircleButton', () {
    testWidgets('点按回调、徽标、命中区 ≥ 44；减少动画时不做模糊', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _wrap(
          AppGlassCircleButton(
            icon: Icons.notifications,
            onTap: () => taps++,
            tooltip: '通知',
            badge: '6',
          ),
        ),
      );
      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(find.text('6'), findsOneWidget);
      final size = tester.getSize(find.byType(AppGlassCircleButton));
      expect(size.width, greaterThanOrEqualTo(44));
      await tester.tap(find.byType(AppGlassCircleButton));
      await tester.pumpAndSettle();
      expect(taps, 1);

      await tester.pumpWidget(
        _wrap(
          AppGlassCircleButton(icon: Icons.add, onTap: () {}, tooltip: '新建'),
          reduceMotion: true,
        ),
      );
      expect(find.byType(BackdropFilter), findsNothing);
    });
  });

  group('AppGroupedList / AppGroupedRow', () {
    testWidgets('行：标题、副标题、右侧值、箭头、点按；容器大圆角卡片色', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _wrap(
          AppGroupedList(
            header: '面板',
            footer: '说明文字',
            children: [
              AppGroupedRow(
                leading: AppIconTile(
                  icon: Icons.dns_rounded,
                  color: AppPalette.light.accent,
                  solid: true,
                ),
                title: '服务器管理',
                subtitle: '2 个面板',
                trailing: const Text('家里'),
                showChevron: true,
                onTap: () => taps++,
              ),
              const AppGroupedRow(title: '应用锁'),
            ],
          ),
        ),
      );
      expect(find.text('面板'), findsOneWidget);
      expect(find.text('说明文字'), findsOneWidget);
      expect(find.text('2 个面板'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
      final clip = tester.widget<ClipRRect>(
        find.descendant(
          of: find.byType(AppGroupedList),
          matching: find.byType(ClipRRect),
        ).first,
      );
      expect(clip.borderRadius, BorderRadius.circular(AppRadius.card));

      await tester.tap(find.text('服务器管理'));
      await tester.pump();
      expect(taps, 1);
      // 右侧值文字默认是次要色
      final trailing = tester.widget<DefaultTextStyle>(
        find.ancestor(of: find.text('家里'), matching: find.byType(DefaultTextStyle)).first,
      );
      expect(trailing.style.color, AppPalette.light.text2);
    });

    testWidgets('分隔线：第一行不画，后面的行画在顶部并缩进到 leading 之后', (tester) async {
      await tester.pumpWidget(
        _wrap(
          AppGroupedList(
            children: [
              AppGroupedRow(
                leading: AppIconTile(icon: Icons.lock, color: AppPalette.light.ok),
                title: '第一行',
              ),
              AppGroupedRow(
                leading: AppIconTile(icon: Icons.lock, color: AppPalette.light.ok),
                title: '第二行',
              ),
              const AppGroupedRow(title: '第三行'),
            ],
          ),
        ),
      );
      CustomPaint paintOf(String title) => tester.widget<CustomPaint>(
        find.ancestor(of: find.text(title), matching: find.byType(CustomPaint)).first,
      );
      expect(paintOf('第一行').foregroundPainter, isNull);
      expect(paintOf('第二行').foregroundPainter, isNotNull);
      expect(paintOf('第三行').foregroundPainter, isNotNull);
    });

    testWidgets('懒加载拼分组时可以手动指定分隔线', (tester) async {
      await tester.pumpWidget(
        _wrap(const AppGroupedRow(title: '独立的行', showSeparator: true)),
      );
      final paint = tester.widget<CustomPaint>(
        find.ancestor(of: find.text('独立的行'), matching: find.byType(CustomPaint)).first,
      );
      expect(paint.foregroundPainter, isNotNull);
    });
  });

  group('AppIconTile', () {
    testWidgets('浅底配同色图标；solid 是实色底白图标；圆角按 46 的比例缩', (tester) async {
      final p = AppPalette.light;
      await tester.pumpWidget(
        _wrap(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIconTile(key: const Key('tint'), icon: Icons.check, color: p.ok),
              AppIconTile(
                key: const Key('solid'),
                icon: Icons.lock,
                color: p.ok,
                solid: true,
                size: 46,
              ),
            ],
          ),
        ),
      );
      final tint = tester.widget<Container>(
        find.descendant(of: find.byKey(const Key('tint')), matching: find.byType(Container)),
      );
      final tintDeco = tint.decoration! as BoxDecoration;
      expect(tintDeco.color, p.tint(p.ok));
      expect(tintDeco.borderRadius, BorderRadius.circular(AppRadius.tile * 34 / 46));
      expect(tester.widget<Icon>(find.byIcon(Icons.check)).color, p.ok);

      final solid = tester.widget<Container>(
        find.descendant(of: find.byKey(const Key('solid')), matching: find.byType(Container)),
      );
      final solidDeco = solid.decoration! as BoxDecoration;
      expect(solidDeco.color, p.ok);
      expect(solidDeco.borderRadius, BorderRadius.circular(AppRadius.tile));
      expect(tester.widget<Icon>(find.byIcon(Icons.lock)).color, p.onStatus);
      expect(tester.getSize(find.byKey(const Key('tint'))), const Size(34, 34));
    });
  });

  group('AppSegmented', () {
    Future<void> pumpSeg(
      WidgetTester tester,
      String value,
      ValueChanged<String> onChanged, {
      bool reduceMotion = false,
    }) {
      return tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 300,
            child: AppSegmented<String>(
              segments: const [('all', '全部'), ('cron', '定时'), ('manual', '手动')],
              value: value,
              onChanged: onChanged,
            ),
          ),
          reduceMotion: reduceMotion,
        ),
      );
    }

    double thumbLeft(WidgetTester tester) =>
        tester.getTopLeft(find.byKey(const Key('app-segmented-thumb'))).dx;

    testWidgets('点另一段回调新值；点当前段不回调；滑块弹簧滑过去', (tester) async {
      var value = 'all';
      final changes = <String>[];
      await pumpSeg(tester, value, (v) {
        changes.add(v);
        value = v;
      });
      final start = thumbLeft(tester);

      await tester.tap(find.text('全部'));
      expect(changes, isEmpty);

      await tester.tap(find.text('手动'));
      expect(changes, ['manual']);
      await pumpSeg(tester, value, (v) => changes.add(v));
      await tester.pump(const Duration(milliseconds: 60));
      final mid = thumbLeft(tester);
      await tester.pumpAndSettle();
      final end = thumbLeft(tester);
      expect(mid, greaterThan(start));
      expect(mid, lessThan(end));
      expect(
        tester.getCenter(find.byKey(const Key('app-segmented-thumb'))).dx,
        moreOrLessEquals(tester.getCenter(find.text('手动')).dx, epsilon: 1),
      );
    });

    testWidgets('减少动画：滑块直接跳', (tester) async {
      await pumpSeg(tester, 'all', (_) {}, reduceMotion: true);
      await pumpSeg(tester, 'cron', (_) {}, reduceMotion: true);
      await tester.pump();
      expect(
        tester.getCenter(find.byKey(const Key('app-segmented-thumb'))).dx,
        moreOrLessEquals(tester.getCenter(find.text('定时')).dx, epsilon: 1),
      );
    });

    testWidgets('value 不在选项里：不画滑块', (tester) async {
      await pumpSeg(tester, 'nope', (_) {});
      expect(find.byKey(const Key('app-segmented-thumb')), findsNothing);
    });
  });

  group('AppPillButton', () {
    testWidgets('primary 浅色黑底白字、深色白底黑字；禁用不响应', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _wrap(AppPillButton(label: '保存', onPressed: () => taps++)),
      );
      final finder = find.byType(AppPillButton);
      expect(
        tester
            .widget<Container>(find.descendant(of: finder, matching: find.byType(Container)))
            .decoration,
        isA<BoxDecoration>().having((d) => d.color, 'color', AppPalette.light.primaryBtnBg),
      );
      expect(tester.widget<Text>(find.text('保存')).style!.color, AppPalette.light.primaryBtnFg);
      await tester.tap(finder);
      await tester.pumpAndSettle();
      expect(taps, 1);

      await tester.pumpWidget(
        _wrap(AppPillButton(label: '保存', onPressed: () => taps++), dark: true),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.text('保存')).style!.color, AppPalette.dark.primaryBtnFg);

      await tester.pumpWidget(_wrap(const AppPillButton(label: '保存', onPressed: null)));
      await tester.tap(find.byType(AppPillButton));
      await tester.pumpAndSettle();
      expect(taps, 1);
    });

    testWidgets('secondary 灰色填充；danger 红色淡底 + 墨色字', (tester) async {
      final p = AppPalette.light;
      await tester.pumpWidget(
        _wrap(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppPillButton(
                label: '取消',
                onPressed: () {},
                variant: AppPillVariant.secondary,
              ),
              AppPillButton(
                label: '删除',
                icon: Icons.delete,
                onPressed: () {},
                variant: AppPillVariant.danger,
              ),
            ],
          ),
        ),
      );
      expect(tester.widget<Text>(find.text('取消')).style!.color, p.text);
      expect(tester.widget<Text>(find.text('删除')).style!.color, p.errInk);
      expect(tester.widget<Icon>(find.byIcon(Icons.delete)).color, p.errInk);
    });
  });

  group('既有组件换上新令牌（签名不变）', () {
    for (final dark in [false, true]) {
      testWidgets('${dark ? '深色' : '浅色'}：卡片 / 状态视图 / 小标题 / 提示条 / 新建按钮', (
        tester,
      ) async {
        final p = dark ? AppPalette.dark : AppPalette.light;
        await tester.pumpWidget(
          _wrap(
            SingleChildScrollView(
              child: Column(
                children: [
                  const AppCard(key: Key('card'), child: Text('卡片')),
                  const AppSectionTitle('小标题'),
                  const AppEmptyView(icon: Icons.inbox, message: '暂无数据', topPadding: 0),
                  const AppErrorView(
                    title: '加载失败',
                    message: '网络错误',
                    padding: EdgeInsets.zero,
                  ),
                  AppNotice(color: p.accent, text: '提示'),
                  AppCircleAddButton(onTap: () {}),
                  AppChipButton(label: '排序', icon: Icons.sort, onTap: () {}),
                ],
              ),
            ),
            dark: dark,
          ),
        );
        await tester.pumpAndSettle();
        expect(_colorOf(tester, find.byKey(const Key('card'))), p.card);
        expect(tester.widget<Text>(find.text('小标题')).style!.color, p.text2);
        expect(tester.widget<Text>(find.text('暂无数据')).style!.color, p.text2);
        expect(tester.widget<Text>(find.text('网络错误')).style!.color, p.text2);
        final add = tester.widget<Container>(
          find.descendant(
            of: find.byType(AppCircleAddButton),
            matching: find.byType(Container),
          ),
        );
        expect((add.decoration! as BoxDecoration).color, p.primaryBtnBg);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('AppSnack 成功 / 失败色调取自色板', (tester) async {
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => AppSnack.error(context, '失败了'),
              child: const Text('弹'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('弹'));
      await tester.pump();
      final bar = tester.widget<SnackBar>(find.byType(SnackBar));
      final surfaces = AppSurfaces.light;
      expect(bar.backgroundColor, surfaces.solidBg(AppPalette.light.err));
    });
  });
}
