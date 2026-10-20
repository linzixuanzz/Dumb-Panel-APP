import 'dart:async';

import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/features/envs/views/env_list_page.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_http_adapter.dart';

/// APP issue #18-2：「切分组 + 搜索后点清除，偶发卡住，只能杀后台」。
///
/// 真因：清空按钮没掐掉 300ms 的搜索防抖。打完字马上点清空，那次防抖会在清空**之后**
/// 把旧关键词写回筛选状态：输入框是空的、清空按钮也没了，列表却停在旧结果上，
/// 下拉刷新沿用旧词；provider 是全局的，切页回来照旧 —— 用户只剩杀后台一条路。
///
/// 下面钉三件事：防抖期内点清空不再写回旧词；分组 + 关键词清空后只按分组筛；
/// 在筛选结果里删除变量后列表照常更新。
Map<String, dynamic> _env(int id, String name, String group) => {
  'id': id,
  'name': name,
  'value': 'v$id',
  'remarks': '',
  'group': group,
  'enabled': true,
  'sort_order': 0,
  'position': 1000.0 * id,
};

/// 假面板：按请求里的 groups / keyword 真筛一遍；DELETE 真删。
class _FakePanel {
  _FakePanel(this.rows);

  final List<Map<String, dynamic>> rows;

  /// 每次列表 GET 的 query，按到达顺序。
  final listQueries = <Map<String, dynamic>>[];

  FutureOr<ResponseBody> handle(RequestOptions options) {
    if (options.path == ApiEndpoints.envsGroups) {
      return jsonResponse({
        'data': ['g1', 'g2'],
      });
    }
    if (options.method == 'GET' && options.path == ApiEndpoints.envs) {
      final query = Map<String, dynamic>.of(options.queryParameters);
      listQueries.add(query);
      final groups = (query['groups'] as String?)?.split(',') ?? const [];
      final keyword = (query['keyword'] as String?) ?? '';
      final shown = rows
          .where((row) => groups.isEmpty || groups.contains(row['group']))
          .where((row) => (row['name'] as String).contains(keyword))
          .toList();
      return jsonResponse({'data': shown, 'total': shown.length});
    }
    if (options.method == 'DELETE') {
      final id = int.parse(options.path.split('/').last);
      rows.removeWhere((row) => row['id'] == id);
    }
    return jsonResponse({'message': '操作成功'});
  }
}

Future<ProviderContainer> _openPage(
  WidgetTester tester,
  _FakePanel panel,
) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        envListProvider.overrideWith(
          (ref) => EnvListNotifier(
            dio: dioWithAdapter(FakeHttpAdapter(panel.handle)),
          ),
        ),
      ],
      child: MaterialApp(theme: AppTheme.light(), home: const EnvListPage()),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(EnvListPage)));
}

Future<void> _pickGroup(WidgetTester tester, String group) async {
  await tester.tap(find.byTooltip('筛选分组'));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(CheckedPopupMenuItem<String>, group));
  await tester.pumpAndSettle();
}

void main() {
  List<Map<String, dynamic>> rows() => [
    _env(1, 'JD_COOKIE', 'g1'),
    _env(2, 'JD_TOKEN', 'g1'),
    _env(3, 'OTHER', 'g1'),
    _env(4, 'JD_G2', 'g2'),
  ];

  testWidgets('防抖期内点清空：300ms 之后关键词仍为空，列表回到全量', (tester) async {
    final panel = _FakePanel(rows());
    final container = await _openPage(tester, panel);

    await tester.enterText(find.byType(TextField), 'JD_C');
    // 还在 300ms 防抖期内就点清空。
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byIcon(Icons.clear));
    await tester.pump();
    // 让原来那次防抖（如果还活着）有机会触发。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(container.read(envListProvider).keyword, '');
    expect(panel.listQueries.last.containsKey('keyword'), isFalse);
    expect(
      panel.listQueries.where((q) => q['keyword'] == 'JD_C'),
      isEmpty,
      reason: '旧关键词不许在清空之后再发出去',
    );
    for (final name in ['JD_COOKIE', 'JD_TOKEN', 'OTHER', 'JD_G2']) {
      expect(find.text(name), findsOneWidget);
    }
  });

  testWidgets('分组 + 关键词 → 清空：请求只带分组，列表是该分组全量且能继续操作', (tester) async {
    final panel = _FakePanel(rows());
    final container = await _openPage(tester, panel);

    await _pickGroup(tester, 'g1');
    await tester.enterText(find.byType(TextField), 'JD');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(panel.listQueries.last, {'all': 1, 'groups': 'g1', 'keyword': 'JD'});
    expect(find.text('OTHER'), findsNothing);

    await tester.tap(find.byIcon(Icons.clear));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(container.read(envListProvider).keyword, '');
    expect(container.read(envListProvider).selectedGroups, ['g1']);
    expect(panel.listQueries.last, {'all': 1, 'groups': 'g1'});
    expect(find.text('JD_COOKIE'), findsOneWidget);
    expect(find.text('OTHER'), findsOneWidget);
    expect(find.text('JD_G2'), findsNothing);

    // 还能继续搜：界面没有卡在旧状态上。
    await tester.enterText(find.byType(TextField), 'OTH');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(panel.listQueries.last, {
      'all': 1,
      'groups': 'g1',
      'keyword': 'OTH',
    });
    expect(find.text('OTHER'), findsOneWidget);
    expect(find.text('JD_COOKIE'), findsNothing);
  });

  testWidgets('分组 + 关键词筛选下左滑删除：列表照常更新，筛选条件不丢', (tester) async {
    final panel = _FakePanel(rows());
    await _openPage(tester, panel);

    await _pickGroup(tester, 'g1');
    await tester.enterText(find.byType(TextField), 'JD');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('JD_COOKIE'), findsOneWidget);
    expect(find.text('JD_TOKEN'), findsOneWidget);

    await tester.drag(find.text('JD_COOKIE'), const Offset(-300, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').first);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('删除')),
    );
    await tester.pumpAndSettle();

    expect(find.text('已删除 JD_COOKIE'), findsOneWidget);
    expect(find.text('JD_COOKIE'), findsNothing);
    expect(find.text('JD_TOKEN'), findsOneWidget);
    expect(panel.listQueries.last, {'all': 1, 'groups': 'g1', 'keyword': 'JD'});

    // 删完还能接着删下一条：卡片的左滑状态没有残留成「点不动」。
    await tester.drag(find.text('JD_TOKEN'), const Offset(-300, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').first);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('删除')),
    );
    await tester.pumpAndSettle();
    expect(find.text('JD_TOKEN'), findsNothing);
    expect(find.text('暂无环境变量'), findsOneWidget);

    // 清空关键词后回到 g1 全量。
    await tester.tap(find.byIcon(Icons.clear));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('OTHER'), findsOneWidget);
  });
}
