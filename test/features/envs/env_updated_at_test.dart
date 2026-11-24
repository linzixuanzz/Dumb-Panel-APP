import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/features/envs/views/env_list_page.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_http_adapter.dart';

/// APP issue #27：环境变量列表要能一眼看到每个变量「最近一次改动」的时间。
///
/// 面板的 updated_at 在改值 / 启用 / 禁用时都会刷新。列表卡上给到分钟（不带年份，
/// 同其它列表页的 formatTimeCn(short: true)），详情弹层给完整时间。
/// 时间串故意不带时区：解析成本地时间，断言不受跑测试机器的时区影响。
Map<String, dynamic> _env(int id, String name, {String remarks = ''}) => {
  'id': id,
  'name': name,
  'value': 'v$id',
  'remarks': remarks,
  'group': '',
  'enabled': id.isOdd,
  'sort_order': 0,
  'position': 1000.0 * id,
  'created_at': '2026-01-0${id}T08:00:00',
  'updated_at': '2026-11-2${id}T21:3$id:00',
};

Future<void> _openPage(
  WidgetTester tester,
  List<Map<String, dynamic>> rows, {
  double width = 800,
}) async {
  tester.view.physicalSize = Size(width, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        envListProvider.overrideWith(
          (ref) => EnvListNotifier(
            dio: dioWithAdapter(
              FakeHttpAdapter((RequestOptions options) {
                if (options.path == ApiEndpoints.envsGroups) {
                  return jsonResponse({'data': <String>[]});
                }
                if (options.method == 'GET' &&
                    options.path == ApiEndpoints.envs) {
                  return jsonResponse({'data': rows, 'total': rows.length});
                }
                return jsonResponse({'message': '操作成功'});
              }),
            ),
          ),
        ),
      ],
      child: MaterialApp(theme: AppTheme.light(), home: const EnvListPage()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('列表卡显示每个变量自己的更新时间（有无备注都显示）', (tester) async {
    await _openPage(tester, [
      _env(1, 'JD_COOKIE', remarks: '账号1'),
      _env(2, 'JD_TOKEN'),
    ]);

    expect(find.text('更新于 11月21日 21:31'), findsOneWidget);
    expect(find.text('更新于 11月22日 21:32'), findsOneWidget);
    expect(find.text('账号1'), findsOneWidget);
  });

  testWidgets('窄屏 + 超长备注：备注省略、时间完整，不溢出', (tester) async {
    await _openPage(tester, [
      _env(1, 'JD_COOKIE', remarks: '很长的备注' * 30),
    ], width: 320);

    expect(tester.takeException(), isNull);
    expect(find.text('更新于 11月21日 21:31'), findsOneWidget);
    final remark = tester.widget<Text>(find.text('很长的备注' * 30));
    expect(remark.maxLines, 1);
    expect(remark.overflow, TextOverflow.ellipsis);
  });

  testWidgets('详情弹层显示完整的更新时间与创建时间', (tester) async {
    await _openPage(tester, [_env(1, 'JD_COOKIE')]);

    await tester.tap(find.text('JD_COOKIE'));
    await tester.pumpAndSettle();

    expect(
      find.text('更新于 2026年11月21日 21:31:00 · 创建于 2026年1月1日 08:00:00'),
      findsOneWidget,
    );
  });
}
