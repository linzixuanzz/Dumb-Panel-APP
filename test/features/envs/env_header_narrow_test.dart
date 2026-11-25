import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/features/envs/views/env_list_page.dart';
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
/// v2.0 换装后页头只剩「⋯」「＋」两个圆形玻璃按钮（批量 / 排序 / 导入导出收进「⋯」菜单）。
/// 钉住：360 宽（含字号 1.3）页头不溢出、＋完整落在屏幕内且点得开新建弹层；
/// 「⋯」菜单进得了批量和排序；多选态、排序态的页头也不溢出。
void main() {
  for (final textScale in [1.0, 1.3]) {
    testWidgets('360×800、字号 $textScale：页头不溢出，＋在屏幕内且点得开新建弹层', (
      tester,
    ) async {
      await _openPage(tester, size: const Size(360, 800), textScale: textScale);

      expect(tester.takeException(), isNull);
      final add = find.byTooltip('新建变量');
      expect(add, findsOneWidget);
      final rect = tester.getRect(add);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(360));
      expect(rect.width, greaterThanOrEqualTo(44), reason: '命中区不小于 44');

      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
    });
  }

  testWidgets('360 宽：「⋯」菜单进多选，多选态页头只剩「⋯」「取消」且不溢出', (tester) async {
    await _openPage(tester, size: const Size(360, 800), textScale: 1.3);

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('批量'), findsOneWidget);
    expect(find.text('排序'), findsOneWidget);
    await tester.tap(find.text('批量'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('已选择 0 项'), findsOneWidget);
    expect(find.byTooltip('新建变量'), findsNothing);

    // 多选态的「⋯」只剩导出 / 导入。
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('排序'), findsNothing);
    expect(find.text('导出变量'), findsOneWidget);
    await tester.tapAt(const Offset(10, 790));
    await tester.pumpAndSettle();

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('新建变量'), findsOneWidget);
  });

  testWidgets('360 宽：「⋯」菜单进排序，排序态只剩「完成」，点了退出', (tester) async {
    await _openPage(tester, size: const Size(360, 800), textScale: 1.3);

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('排序'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(ReorderableListView), findsOneWidget);
    expect(find.byTooltip('更多'), findsNothing);
    expect(find.byTooltip('新建变量'), findsNothing);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.byType(ReorderableListView), findsNothing);
    expect(find.byTooltip('新建变量'), findsOneWidget);
  });
}
