import 'package:daidai_app/shared/api/panel_insights.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_http_adapter.dart';

/// 面板 v4.0 洞察接口客户端（design §4）：
/// - 响应没有 data 包装；
/// - 形状探测：404（路由不存在）/ 405 / 形状不符 → null，并按面板记住；切面板清空；
/// - 任务不存在的 404 不记成「面板不支持」；网络错误 / 5xx 照常抛。
void main() {
  setUp(resetPanelInsightsForTest);

  Map<String, dynamic> healthBody() => {
    'days': [
      {'date': '2026-11-24', 'total': 4, 'failed': 1, 'avg_duration': 1.5},
      {'date': '2026-11-25', 'total': 0, 'failed': 0, 'avg_duration': 0},
    ],
    'stats': {
      'runs': 4,
      'success_rate': 66.7,
      'avg_duration': 1.5,
      'p90_duration': 2.25,
    },
    'recent': [
      {'status': 0, 'duration': 1.2, 'started_at': '2026-11-24T08:00:00+08:00'},
      {'status': 1, 'duration': null, 'started_at': '2026-11-24T09:00:00+08:00'},
    ],
  };

  group('fetchTaskHealth', () {
    test('解析：没有 data 包装，字段逐字对齐；days 参数带上', () async {
      Uri? uri;
      final adapter = FakeHttpAdapter((options) {
        uri = options.uri;
        return jsonResponse(healthBody());
      });
      final health = await fetchTaskHealth(12, dio: dioWithAdapter(adapter));

      expect(uri!.path, '/api/tasks/12/health');
      expect(uri!.queryParameters['days'], '91');
      expect(health, isNotNull);
      expect(health!.days, hasLength(2));
      expect(health.days.first.date, '2026-11-24');
      expect(health.days.first.failed, 1);
      expect(health.days.first.avgDuration, 1.5);
      expect(health.days.first.day, DateTime(2026, 11, 24));
      expect(health.stats.runs, 4);
      expect(health.stats.successRate, 66.7);
      expect(health.stats.p90Duration, 2.25);
      expect(health.recent.last.isFailed, isTrue);
      expect(health.recent.last.duration, isNull);
      expect(health.recent.first.startedAt, isNotNull);
    });

    test('老面板 404 route not found：返回 null，记住不支持，不再请求', () async {
      final adapter = FakeHttpAdapter(
        (_) => jsonResponse({'error': 'route not found'}, status: 404),
      );
      final dio = dioWithAdapter(adapter);
      expect(await fetchTaskHealth(1, dio: dio), isNull);
      expect(await fetchTaskHealth(2, dio: dio), isNull);
      expect(adapter.requests, hasLength(1));
      expect(isInsightUnsupported('health', dio: dio), isTrue);
    });

    test('更老的面板 404 纯文本：同样按不支持', () async {
      final adapter = FakeHttpAdapter(
        (_) => bytesResponse('404 page not found'.codeUnits, status: 404),
      );
      final dio = dioWithAdapter(adapter);
      expect(await fetchTaskHealth(1, dio: dio), isNull);
      expect(isInsightUnsupported('health', dio: dio), isTrue);
    });

    test('v4.0 面板上任务不存在（404 任务不存在）：返回 null，但不记成面板不支持', () async {
      final adapter = FakeHttpAdapter(
        (_) => jsonResponse({'error': '任务不存在'}, status: 404),
      );
      final dio = dioWithAdapter(adapter);
      expect(await fetchTaskHealth(99, dio: dio), isNull);
      expect(isInsightUnsupported('health', dio: dio), isFalse);
      await fetchTaskHealth(98, dio: dio);
      expect(adapter.requests, hasLength(2));
    });

    test('405：按不支持', () async {
      final adapter = FakeHttpAdapter(
        (_) => jsonResponse({'error': 'method not allowed'}, status: 405),
      );
      final dio = dioWithAdapter(adapter);
      expect(await fetchTaskHealth(1, dio: dio), isNull);
      expect(isInsightUnsupported('health', dio: dio), isTrue);
    });

    test('形状不符（被别的路由接走、套了 data）：按不支持', () async {
      final adapter = FakeHttpAdapter(
        (_) => jsonResponse({'data': healthBody()}),
      );
      final dio = dioWithAdapter(adapter);
      expect(await fetchTaskHealth(1, dio: dio), isNull);
      expect(isInsightUnsupported('health', dio: dio), isTrue);
    });

    test('5xx / 401 照常抛出，不记成不支持', () async {
      final adapter = FakeHttpAdapter(
        (_) => jsonResponse({'error': 'boom'}, status: 500),
      );
      final dio = dioWithAdapter(adapter);
      await expectLater(
        fetchTaskHealth(1, dio: dio),
        throwsA(isA<DioException>()),
      );
      expect(isInsightUnsupported('health', dio: dio), isFalse);
    });

    test('切换面板（地址变了）：记忆清空，重新探测', () async {
      final adapter = FakeHttpAdapter(
        (_) => jsonResponse({'error': 'route not found'}, status: 404),
      );
      final dio = dioWithAdapter(adapter);
      await fetchTaskHealth(1, dio: dio);
      expect(isInsightUnsupported('health', dio: dio), isTrue);

      dio.options.baseUrl = 'https://other-panel.test';
      expect(isInsightUnsupported('health', dio: dio), isFalse);
      await fetchTaskHealth(1, dio: dio);
      expect(adapter.requests, hasLength(2));
    });

    test('不支持只按接口记：health 不支持不影响 running', () async {
      final adapter = FakeHttpAdapter((options) {
        if (options.path.endsWith('/health')) {
          return jsonResponse({'error': 'route not found'}, status: 404);
        }
        return jsonResponse({'items': <Object>[]});
      });
      final dio = dioWithAdapter(adapter);
      expect(await fetchTaskHealth(1, dio: dio), isNull);
      expect(await fetchRunning(dio: dio), isEmpty);
    });
  });

  group('fetchAttention', () {
    test('解析 items', () async {
      final adapter = FakeHttpAdapter(
        (_) => jsonResponse({
          'items': [
            {
              'key': 'task_failing:3',
              'type': 'task_failing',
              'level': 'err',
              'title': '签到 · 连续失败 3 次',
              'detail': '最近一次：Error: timeout',
              'target': {'kind': 'task', 'id': 3},
              'at': '2026-11-25T10:00:00+08:00',
            },
            {
              'key': 'disk_high',
              'type': 'disk_high',
              'level': 'warn',
              'title': '数据盘使用率 88.0%',
              'detail': '',
              'target': {'kind': 'system', 'id': 0},
              'at': '2026-11-25T10:01:00+08:00',
            },
          ],
        }),
      );
      final items = await fetchAttention(dio: dioWithAdapter(adapter));
      expect(adapter.requests.single.path, '/api/system/attention');
      expect(items, hasLength(2));
      expect(items!.first.key, 'task_failing:3');
      expect(items.first.level, 'err');
      expect(items.first.target.kind, 'task');
      expect(items.first.target.id, 3);
      expect(items.first.at, isNotNull);
      expect(items.last.target.kind, 'system');
    });

    test('items 缺失：按不支持', () async {
      final adapter = FakeHttpAdapter((_) => jsonResponse({'ok': true}));
      final dio = dioWithAdapter(adapter);
      expect(await fetchAttention(dio: dio), isNull);
      expect(isInsightUnsupported('attention', dio: dio), isTrue);
    });
  });

  group('fetchRunning', () {
    test('解析 items；log_id / started_at 可为 null', () async {
      final adapter = FakeHttpAdapter(
        (_) => jsonResponse({
          'items': [
            {
              'task_id': 5,
              'name': '备份',
              'log_id': 88,
              'started_at': '2026-11-25T10:00:00+08:00',
            },
            {'task_id': 6, 'name': '刚开始', 'log_id': null, 'started_at': null},
          ],
        }),
      );
      final items = await fetchRunning(dio: dioWithAdapter(adapter));
      expect(adapter.requests.single.path, '/api/tasks/running');
      expect(items, hasLength(2));
      expect(items!.first.taskId, 5);
      expect(items.first.logId, 88);
      expect(items.last.logId, isNull);
      expect(items.last.startedAt, isNull);
    });

    test('没有任务在跑：空列表，不是 null', () async {
      final adapter = FakeHttpAdapter(
        (_) => jsonResponse({'items': <Object>[]}),
      );
      expect(await fetchRunning(dio: dioWithAdapter(adapter)), isEmpty);
    });
  });

  group('fetchRecentRuns', () {
    test('ids 逗号拼接、limit 带上；字符串键转成 int', () async {
      Uri? uri;
      final adapter = FakeHttpAdapter((options) {
        uri = options.uri;
        return jsonResponse({
          'runs': {
            '1': [
              {'status': 0, 'duration': 1.0},
              {'status': 1, 'duration': 2.5},
            ],
            '2': <Object>[],
          },
        });
      });
      final runs = await fetchRecentRuns(
        [1, 2],
        limit: 10,
        dio: dioWithAdapter(adapter),
      );
      expect(uri!.path, '/api/tasks/recent-runs');
      expect(uri!.queryParameters['ids'], '1,2');
      expect(uri!.queryParameters['limit'], '10');
      expect(runs!.keys, containsAll([1, 2]));
      expect(runs[1], hasLength(2));
      expect(runs[1]!.last.isFailed, isTrue);
      expect(runs[2], isEmpty);
    });

    test('ids 为空：不发请求，返回空 Map', () async {
      final adapter = FakeHttpAdapter((_) => jsonResponse({'runs': {}}));
      final runs = await fetchRecentRuns([], dio: dioWithAdapter(adapter));
      expect(runs, isEmpty);
      expect(adapter.requests, isEmpty);
    });

    test('老面板：null；之后 ids 为空也如实返回 null', () async {
      final adapter = FakeHttpAdapter(
        (_) => jsonResponse({'error': 'route not found'}, status: 404),
      );
      final dio = dioWithAdapter(adapter);
      expect(await fetchRecentRuns([1], dio: dio), isNull);
      expect(await fetchRecentRuns([], dio: dio), isNull);
    });
  });
}
