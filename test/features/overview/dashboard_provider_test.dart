import 'package:daidai_app/features/overview/providers/dashboard_provider.dart';
import 'package:daidai_app/shared/api/panel_insights.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_http_adapter.dart';

/// 概览数据（DashboardNotifier）：
/// - 主请求并发失败时不冒未捕获的 DioException（第一波遗留 bug）；
/// - 总览卡口径：区间内 成功 / (成功 + 失败)，已终止不进分母；
/// - 最常失败：v4 attention 的 task_failing，老面板 null；
/// - 最慢的任务：v4 用 recent-runs 平均，老面板退回 last_running_time。
void main() {
  setUp(resetPanelInsightsForTest);

  Map<String, dynamic> dashboardBody() => {
    'data': {
      'task_count': 3,
      'running_tasks': 1,
      'success_logs': 4,
      'failed_logs': 1,
      'aborted_logs': 0,
      'range_days': 3,
      'daily_stats': [
        {'date': '11-23', 'success': 10, 'failed': 0, 'aborted': 2},
        {'date': '11-24', 'success': 5, 'failed': 3, 'aborted': 0},
        {'date': '11-25', 'success': 4, 'failed': 1, 'aborted': 0},
      ],
    },
  };

  Map<String, dynamic> tasksBody() => {
    'data': [
      {'id': 1, 'name': '快任务', 'last_running_time': 2.0},
      {'id': 2, 'name': '慢任务', 'last_running_time': 1.0},
      {'id': 3, 'name': '最近一次最慢', 'last_running_time': 90.0},
    ],
    'total': 3,
  };

  /// [v4] 为 false 时模拟老面板：attention / recent-runs 都是 404 route not found。
  FakeHttpAdapter panel({required bool v4}) {
    return FakeHttpAdapter((options) {
      switch (options.path) {
        case '/api/system/info':
          return jsonResponse({
            'data': {'hostname': 'nas', 'cpu_usage': 12},
          });
        case '/api/system/dashboard':
          return jsonResponse(dashboardBody());
        case '/api/tasks':
          return jsonResponse(tasksBody());
        case '/api/system/attention':
          if (!v4) return jsonResponse({'error': 'route not found'}, status: 404);
          return jsonResponse({
            'items': [
              {
                'key': 'disk_high',
                'type': 'disk_high',
                'level': 'warn',
                'title': '磁盘快满了',
                'target': {'kind': 'system', 'id': 0},
              },
              {
                'key': 'task_failing:7',
                'type': 'task_failing',
                'level': 'err',
                'title': '签到 · 连续失败 4 次',
                'target': {'kind': 'task', 'id': 7},
              },
            ],
          });
        case '/api/tasks/recent-runs':
          if (!v4) return jsonResponse({'error': 'route not found'}, status: 404);
          return jsonResponse({
            'runs': {
              '1': [
                {'status': 0, 'duration': 2.0},
                {'status': 0, 'duration': 4.0},
              ],
              // 平均 30s；已终止的那次 500s 不算
              '2': [
                {'status': 0, 'duration': 20.0},
                {'status': 1, 'duration': 40.0},
                {'status': 3, 'duration': 500.0},
              ],
              '3': [],
            },
          });
        default:
          return jsonResponse({}, status: 404);
      }
    });
  }

  test('v4 面板：区间成功率、最常失败、最慢（平均耗时）', () async {
    final adapter = panel(v4: true);
    final notifier = DashboardNotifier(dio: dioWithAdapter(adapter));
    await notifier.load();
    final data = notifier.state;

    expect(data.error, isNull);
    expect(data.loading, isFalse);
    // 最慢的任务要多发两条：任务列表 + recent-runs
    expect(adapter.countOf('/api/tasks'), 1);
    expect(adapter.countOf('/api/tasks/recent-runs'), 1);

    // 成功 19、失败 4、终止 2：19 / 23，终止不进分母
    expect(data.rangeSuccess, 19);
    expect(data.rangeFailed, 4);
    expect(data.rangeAborted, 2);
    expect(data.rangeRuns, 25);
    expect(data.rangeSuccessRate, closeTo(82.6, 0.1));

    // attention 第一条是磁盘，最常失败要跳过它取 task_failing
    expect(data.attention, isNotNull);
    expect(data.topFailing!.target.id, 7);

    expect(data.slowest, isNotNull);
    expect(data.slowest!.id, 2);
    expect(data.slowest!.seconds, 30.0);
    expect(data.slowest!.isAverage, isTrue);
  });

  test('老面板：attention 为 null（卡片隐藏），最慢退回 last_running_time', () async {
    final notifier = DashboardNotifier(dio: dioWithAdapter(panel(v4: false)));
    await notifier.load();
    final data = notifier.state;

    expect(data.error, isNull);
    expect(data.attention, isNull);
    expect(data.topFailing, isNull);
    expect(data.slowest!.id, 3);
    expect(data.slowest!.seconds, 90.0);
    expect(data.slowest!.isAverage, isFalse);
  });

  test('没有任何执行记录：成功率为 null，不编 100%', () {
    const data = DashboardData(
      dashboard: {
        'daily_stats': [
          {'date': '11-25', 'success': 0, 'failed': 0, 'aborted': 3},
        ],
      },
    );
    expect(data.rangeSuccessRate, isNull);
    expect(data.rangeRuns, 3);
  });

  test('请求带 range=30', () async {
    Uri? uri;
    final adapter = FakeHttpAdapter((options) {
      if (options.path == '/api/system/dashboard') uri = options.uri;
      return jsonResponse({'data': <String, dynamic>{}});
    });
    await DashboardNotifier(dio: dioWithAdapter(adapter)).load();
    expect(uri!.queryParameters['range'], '30');
  });

  test('轻量预加载（开屏 / 登录）：只拉 /system/dashboard，不请求 recent-runs / attention', () async {
    final adapter = panel(v4: true);
    final notifier = DashboardNotifier(dio: dioWithAdapter(adapter));
    await notifier.load(full: false);

    expect(adapter.requests.map((r) => r.path).toList(), [
      '/api/system/dashboard',
    ]);
    expect(adapter.countOf('/api/tasks/recent-runs'), 0);
    expect(adapter.countOf('/api/system/attention'), 0);
    // 小组件要的今日次数已经有了
    expect(notifier.state.loading, isFalse);
    expect(notifier.state.error, isNull);
    expect(notifier.state.todaySuccess, 4);
    expect(notifier.state.todayFailed, 1);

    // 概览页挂载时的完整 load 照常把其余数据补齐
    await notifier.load();
    expect(adapter.countOf('/api/system/attention'), 1);
    expect(adapter.countOf('/api/tasks/recent-runs'), 1);
    expect(notifier.state.slowest, isNotNull);
    expect(notifier.state.system['hostname'], 'nas');
  });

  test('轻量预加载失败：不报错（概览页的完整 load 会再拉）', () async {
    final adapter = FakeHttpAdapter(
      (options) => jsonResponse({'error': 'boom'}, status: 500),
    );
    final notifier = DashboardNotifier(dio: dioWithAdapter(adapter));
    await notifier.load(full: false);
    expect(notifier.state.loading, isFalse);
    expect(notifier.state.error, isNull);
  });

  test('完整加载进行中：轻量预加载不再发请求，也不抢先结束 loading', () async {
    final adapter = panel(v4: true);
    final notifier = DashboardNotifier(dio: dioWithAdapter(adapter));
    final full = notifier.load();
    await notifier.load(full: false);
    expect(notifier.state.loading, isTrue);
    await full;
    expect(adapter.countOf('/api/system/dashboard'), 1);
    expect(notifier.state.loading, isFalse);
  });

  test('两个主请求都失败：load 正常结束、记错误，不冒未捕获的 DioException', () async {
    // 两个主请求都 500；以前第一个抛出后第二个没人 await，
    // 它的失败会冒成未捕获异常，测试框架会把这条用例判红。
    final adapter = FakeHttpAdapter((options) {
      if (options.path == '/api/system/info' ||
          options.path == '/api/system/dashboard') {
        return jsonResponse({'error': 'boom'}, status: 500);
      }
      return jsonResponse({}, status: 404);
    });
    final notifier = DashboardNotifier(dio: dioWithAdapter(adapter));
    await notifier.load();
    // 给可能漏接的 Future 一点时间冒出来
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(notifier.state.loading, isFalse);
    expect(notifier.state.error, isNotNull);
  });

  test('第二个主请求失败、第一个成功：同样按整页失败处理', () async {
    final adapter = FakeHttpAdapter((options) {
      if (options.path == '/api/system/dashboard') {
        throw DioException.connectionError(
          requestOptions: options,
          reason: 'offline',
        );
      }
      return jsonResponse({'data': <String, dynamic>{}});
    });
    final notifier = DashboardNotifier(dio: dioWithAdapter(adapter));
    await notifier.load();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(notifier.state.error, isNotNull);
  });
}
