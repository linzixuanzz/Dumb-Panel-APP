import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/features/envs/views/env_list_page.dart';
import 'package:daidai_app/shared/widgets/app_circle_add_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_http_adapter.dart';

Future<void> _openPage(
  WidgetTester tester, {
  required Size size,
  double textScale = 1.0,
}) async {
  // 改窗口尺寸必须同时把像素比设成 1.0，否则逻辑尺寸只有三分之一。
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final adapter = FakeHttpAdapter((options) {
    if (options.path == ApiEndpoints.envsGroups) {
      return jsonResponse({'data': <String>[]});
    }
    if (options.method == 'GET' && options.path == ApiEndpoints.envs) {
      return jsonResponse({
        'data': [
          {
            'id': 1,
            'name': 'JD_COOKIE',
            'value': 'v',
            'remarks': '',
            'group': '',
            'enabled': true,
            'sort_order': 0,
            'position': 1000.0,
          },
        ],
        'total': 1,
      });
    }
    return jsonResponse({'message': '操作成功'});
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        envListProvider.overrideWith(
          (ref) => EnvListNotifier(dio: dioWithAdapter(adapter)),
        ),
      ],
      child: MaterialApp(theme: AppTheme.light(), home: const EnvListPage()),
    ),
  );
  await tester.pumpAndSettle();
}

/// APP #21：360dp 屏上环境变量页右上角的「＋」被挤到屏幕外、点了没反应。
///
/// 钉住：360 宽（含字号 1.3）页头不溢出、＋完整落在屏幕内且点得开新建弹层；
/// 放不下时胶囊只留图标、文字进 tooltip 且照样能点；宽屏照旧带字。
void main() {
  for (final textScale in [1.0, 1.3]) {
    testWidgets('360×800、字号 $textScale：页头不溢出，＋在屏幕内且点得开新建弹层', (
      tester,
    ) async {
      await _openPage(tester, size: const Size(360, 800), textScale: textScale);

      expect(tester.takeException(), isNull);
      final add = find.byType(AppCircleAddButton);
      expect(add, findsOneWidget);
      final rect = tester.getRect(add);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(360));
      expect(rect.width, 44);

      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
    });
  }

  testWidgets('360 宽：「批量」「排序」只留图标，tooltip 带原文案，点「批量」照样进多选', (tester) async {
    await _openPage(tester, size: const Size(360, 800));

    expect(find.text('批量'), findsNothing);
    expect(find.text('排序'), findsNothing);
    expect(find.byTooltip('批量'), findsOneWidget);
    expect(find.byTooltip('排序'), findsOneWidget);
    expect(tester.getSize(find.byTooltip('批量')).width, 44);

    await tester.tap(find.byTooltip('批量'));
    await tester.pumpAndSettle();

    // 多选态只剩「取消」和 ⋯，放得下，照常带字。
    expect(tester.takeException(), isNull);
    expect(find.text('取消'), findsWidgets);
    expect(find.byType(AppCircleAddButton), findsNothing);
  });

  testWidgets('800 宽：胶囊照旧带字（不是一律只留图标）', (tester) async {
    await _openPage(tester, size: const Size(800, 1600));

    expect(tester.takeException(), isNull);
    expect(find.text('批量'), findsOneWidget);
    expect(find.text('排序'), findsOneWidget);
    expect(find.byTooltip('批量'), findsNothing);
  });
}
