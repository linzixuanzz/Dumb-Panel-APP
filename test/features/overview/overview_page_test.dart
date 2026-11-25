import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/network/dio_client.dart';
import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/features/overview/providers/dashboard_provider.dart';
import 'package:daidai_app/features/overview/views/overview_page.dart';
import 'package:daidai_app/features/tasks/widgets/task_detail_sheet.dart';
import 'package:daidai_app/shared/api/panel_insights.dart';
import 'package:daidai_app/shared/models/insights.dart';
import 'package:daidai_app/shared/models/task.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_http_adapter.dart';

/// 不发请求、直接给定数据的概览 provider。
class _StaticDashboardNotifier extends DashboardNotifier {
  _StaticDashboardNotifier(DashboardData data) {
    state = data;
  }

  @override
  Future<void> load({bool full = true}) async {}
}

DashboardData _data({
  List<AttentionItem>? attention,
  SlowestTask? slowest,
  String? error,
}) {
  return DashboardData(
    system: const {
      'hostname': 'nas',
      'cpu_usage': 12,
      'memory_usage': 45,
      'memory_total': 4294967296,
      'memory_used': 1932735283,
      'disk_usage': 92,
      'disk_total': 68719476736,
      'disk_used': 63221918842,
      'uptime': '3 天',
    },
    dashboard: {
      'task_count': 8,
      'running_tasks': 1,
      'success_logs': 5,
      'failed_logs': 1,
      'daily_stats': [
        for (var i = 1; i <= 30; i++)
          {
            'date': '11-${i.toString().padLeft(2, '0')}',
            'success': 9,
            'failed': i == 30 ? 1 : 0,
            'aborted': 0,
          },
      ],
    },
    attention: attention,
    slowest: slowest,
    error: error,
  );
}

Future<void> _pump(WidgetTester tester, DashboardData data) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        dashboardProvider.overrideWith((ref) => _StaticDashboardNotifier(data)),
      ],
      child: MaterialApp(theme: AppTheme.light(), home: const OverviewPage()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('总览卡：近 30 天成功率按 成功 / (成功 + 失败) 截断到 1 位小数', (tester) async {
    await _pump(tester, _data());
    // 270 / 271 = 99.63…% → 截断显示 99.6
    final rate = tester.widget<Text>(find.byKey(const Key('overview-rate')));
    expect(rate.textSpan!.toPlainText(), '99.6%');
    expect(find.text('近 30 天成功率'), findsOneWidget);
    expect(find.text('1 次'), findsOneWidget);
    expect(find.text('概览'), findsOneWidget);
  });

  testWidgets('老面板（attention 为 null、算不出最慢）：两张小卡都不出，不报错', (tester) async {
    await _pump(tester, _data());
    expect(find.byKey(const Key('overview-failing')), findsNothing);
    expect(find.byKey(const Key('overview-slowest')), findsNothing);
    expect(find.text('最常失败'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('v4 面板：最常失败拆出任务名，最慢显示平均耗时', (tester) async {
    await _pump(
      tester,
      _data(
        attention: const [
          AttentionItem(
            key: 'task_failing:7',
            type: 'task_failing',
            level: 'err',
            title: '签到 · 连续失败 4 次',
            target: AttentionTarget(kind: 'task', id: 7),
          ),
        ],
        slowest: const SlowestTask(
          id: 2,
          name: '每日备份',
          seconds: 42.7,
          isAverage: true,
        ),
      ),
    );
    expect(find.text('签到'), findsOneWidget);
    expect(find.text('连续失败 4 次'), findsOneWidget);
    expect(find.text('每日备份'), findsOneWidget);
    expect(find.text('平均 42.7s'), findsOneWidget);
  });

  testWidgets('attention 拿到了但没有连续失败的任务：显示「暂无」', (tester) async {
    await _pump(tester, _data(attention: const []));
    expect(find.byKey(const Key('overview-failing')), findsOneWidget);
    expect(find.text('暂无'), findsOneWidget);
  });

  testWidgets('柱状图 7 天 / 30 天可切换', (tester) async {
    await _pump(tester, _data());
    final chartTitle = find.text('近 30 天');
    await tester.scrollUntilVisible(chartTitle, 200);
    expect(chartTitle, findsOneWidget);
    await tester.tap(find.text('7 天'));
    await tester.pumpAndSettle();
    expect(find.text('近 7 天'), findsOneWidget);
  });

  testWidgets('服务器资源：内存采集不可用时写「不可用」', (tester) async {
    final data = _data();
    final system = Map<String, dynamic>.from(data.system)
      ..remove('memory_total');
    await _pump(tester, data.copyWith(system: system));
    final resources = find.byKey(const Key('overview-resources'));
    await tester.scrollUntilVisible(resources, 200);
    expect(find.text('不可用'), findsOneWidget);
    expect(find.text('92%'), findsOneWidget);
  });

  testWidgets('首次加载失败：整页错误态 + 重试', (tester) async {
    await _pump(tester, const DashboardData(error: '网络连接失败'));
    expect(find.text('概览加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  // 两张小卡点开的是任务详情**弹层**（组间契约 showTaskDetailSheet），不再 push 详情页路由。
  group('点小卡弹任务详情', () {
    late FakeHttpAdapter adapter;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      FlutterSecureStorage.setMockInitialValues({});
      DioClient.instance.setBaseUrl('https://panel.test');
      resetPanelInsightsForTest();
      // 按 id 找任务只能拉全量列表；详情弹层顺手拉的健康画像 / 最近日志按老面板 404 处理
      adapter = FakeHttpAdapter((options) {
        if (options.path == ApiEndpoints.tasks &&
            '${options.queryParameters['all']}' == '1') {
          return jsonResponse({
            'data': [_taskJson(7, '签到')],
            'total': 1,
          });
        }
        return jsonResponse(<String, dynamic>{}, status: 404);
      });
      DioClient.instance.dio.httpClientAdapter = adapter;
    });

    Future<void> frames(WidgetTester tester) async {
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    Future<void> tearDownPage(WidgetTester tester) async {
      // 收掉弹层与提示条的定时器
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }

    testWidgets('最慢的任务：直接用卡片带的任务弹详情，不额外请求', (tester) async {
      await _pump(
        tester,
        _data(
          slowest: SlowestTask(
            id: 2,
            name: '每日备份',
            seconds: 42.7,
            isAverage: true,
            task: Task.fromJson(_taskJson(2, '每日备份')),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('overview-slowest')));
      await frames(tester);

      expect(find.byType(TaskDetailContent), findsOneWidget);
      expect(find.text('任务详情'), findsOneWidget);
      expect(adapter.countOf(ApiEndpoints.tasks), 0);
      await tearDownPage(tester);
    });

    testWidgets('最常失败：手上没有这条任务时去面板取，取到就弹详情', (tester) async {
      await _pump(tester, _data(attention: const [_failing7]));
      await tester.tap(find.byKey(const Key('overview-failing')));
      await frames(tester);

      expect(adapter.countOf(ApiEndpoints.tasks), 1);
      expect(find.byType(TaskDetailContent), findsOneWidget);
      expect(find.text('任务不存在或已被删除'), findsNothing);
      await tearDownPage(tester);
    });

    testWidgets('最常失败：面板上也没有这条任务时只提示，不弹详情', (tester) async {
      await _pump(
        tester,
        _data(
          attention: const [
            AttentionItem(
              key: 'task_failing:99',
              type: 'task_failing',
              level: 'err',
              title: '已删除的任务 · 连续失败 2 次',
              target: AttentionTarget(kind: 'task', id: 99),
            ),
          ],
        ),
      );
      await tester.tap(find.byKey(const Key('overview-failing')));
      await frames(tester);

      expect(find.byType(TaskDetailContent), findsNothing);
      expect(find.text('任务不存在或已被删除'), findsOneWidget);
      await tearDownPage(tester);
    });
  });
}

const _failing7 = AttentionItem(
  key: 'task_failing:7',
  type: 'task_failing',
  level: 'err',
  title: '签到 · 连续失败 4 次',
  target: AttentionTarget(kind: 'task', id: 7),
);

Map<String, dynamic> _taskJson(int id, String name) => {
  'id': id,
  'name': name,
  'command': 'task demo.py',
  'cron_expression': '0 8 * * *',
  'task_type': 'cron',
  'status': 1,
  'created_at': '2026-08-01T08:00:00Z',
  'updated_at': '2026-08-02T08:00:00Z',
};
