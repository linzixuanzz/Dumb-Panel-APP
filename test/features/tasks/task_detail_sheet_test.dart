import 'package:daidai_app/core/auth/auth_provider.dart';
import 'package:daidai_app/core/auth/auth_service.dart';
import 'package:daidai_app/core/network/dio_client.dart';
import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/features/tasks/providers/favorite_tasks_provider.dart';
import 'package:daidai_app/features/tasks/providers/task_health_provider.dart';
import 'package:daidai_app/features/tasks/widgets/task_detail_sheet.dart';
import 'package:daidai_app/shared/api/panel_insights.dart';
import 'package:daidai_app/shared/models/task.dart';
import 'package:daidai_app/shared/models/user.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_http_adapter.dart';

/// PRD A3：任务详情弹层 —— 统计、月历、最近日志、按住运行、加入常用，以及老面板降级。

Map<String, dynamic> _taskJson() => {
  'id': 12,
  'name': '更新 IP 数据库',
  'command': 'task ipdb/update.py',
  'cron_expression': '0 */6 * * *',
  'task_type': 'cron',
  'status': 1,
  'labels': ['网络'],
  'created_at': '2026-08-01T08:00:00Z',
  'updated_at': '2026-08-02T08:00:00Z',
};

/// 面板 v4.0 的 health 响应（没有 data 包装）。最后一天 2026-11-24 就是月历的「今天」，
/// 与手机日期无关，所以断言是确定的。
Map<String, dynamic> _healthJson() {
  final days = <Map<String, dynamic>>[];
  final last = DateTime(2026, 11, 24);
  for (var i = 90; i >= 0; i--) {
    final d = last.subtract(Duration(days: i));
    final date =
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    var total = 1;
    var failed = 0;
    if (date == '2026-11-24') {
      total = 2;
      failed = 1;
    } else if (date == '2026-11-22') {
      total = 0;
    }
    days.add({
      'date': date,
      'total': total,
      'failed': failed,
      'avg_duration': 12.5,
    });
  }
  return {
    'days': days,
    'stats': {
      'runs': 92,
      'success_rate': 90,
      'avg_duration': 12.5,
      'p90_duration': 20,
    },
    'recent': <Map<String, dynamic>>[],
  };
}

Map<String, dynamic> _latestLogJson() => {
  'data': {
    'id': 5,
    'task_id': 12,
    'status': 1,
    'content':
        '=== 开始执行 ===\n[18:00:01] 开始下载 ipdb 数据源…\nError: ETIMEDOUT\n=== 执行结束 ===',
    'started_at': '2026-11-24T18:00:00Z',
    'created_at': '2026-11-24T18:00:00Z',
  },
};

User _operator() => User(
  id: 1,
  username: 'tester',
  role: 'operator',
  enabled: true,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

class _AuthedOperator extends AuthNotifier {
  _AuthedOperator() : super(AuthService()) {
    state = AuthState(status: AuthStatus.authenticated, user: _operator());
  }
}

Future<void> _pumpFrames(WidgetTester tester, [int count = 30]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// 首页一个按钮，点了调 [showTaskDetailSheet]，和列表 / 常用卡片 / 快捷方式同一个入口。
Future<void> _openSheet(
  WidgetTester tester, {
  required bool newPanel,
  bool operator = false,
  bool focusRun = false,
  ThemeMode themeMode = ThemeMode.light,
}) async {
  DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter((options) {
    if (options.path.endsWith('/tasks/12/health')) {
      return newPanel
          ? jsonResponse(_healthJson())
          // 老面板：路由不存在
          : jsonResponse({'error': 'route not found'}, status: 404);
    }
    if (options.path.endsWith('/tasks/12/latest-log')) {
      return jsonResponse(_latestLogJson());
    }
    return jsonResponse(<String, dynamic>{}, status: 404);
  });
  final task = Task.fromJson(_taskJson());
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, state) => Scaffold(
          body: Consumer(
            builder: (context, ref, _) => Center(
              child: TextButton(
                onPressed: () => showTaskDetailSheet(
                  context,
                  ref,
                  task,
                  focusRun: focusRun,
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/logs/:id/stream',
        builder: (_, state) => Text('日志页:${state.pathParameters['id']}'),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (operator) authProvider.overrideWith((ref) => _AuthedOperator()),
      ],
      child: MaterialApp.router(
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: themeMode,
        routerConfig: router,
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await _pumpFrames(tester);
}

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues({});
    DioClient.instance.setBaseUrl('https://panel.test');
    resetPanelInsightsForTest();
  });

  testWidgets('新面板：三个统计、月历按天着色、最近日志末尾几行', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _openSheet(tester, newPanel: true);

    expect(find.byType(TaskDetailContent), findsOneWidget);
    expect(find.text('更新 IP 数据库'), findsOneWidget);
    expect(find.text('网络'), findsOneWidget);

    // 统计：成功率整数不带 .0，耗时走 formatDurationSeconds
    expect(
      find.descendant(
        of: find.byKey(const Key('task-health-success-rate')),
        matching: find.text('90%'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('task-health-avg')),
        matching: find.text('12.5s'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('task-health-p90')),
        matching: find.text('20.0s'),
      ),
      findsOneWidget,
    );

    // 月历：今天（数据最后一天）有失败 → 红；全成功 → 绿；没运行 → 灰；今天以后 → 无底
    expect(find.text('11月 · 每天一格'), findsOneWidget);
    expect(find.byKey(const ValueKey('health-day-2026-11-24-fail')), findsOneWidget);
    expect(find.byKey(const ValueKey('health-day-2026-11-23-ok')), findsOneWidget);
    expect(find.byKey(const ValueKey('health-day-2026-11-22-idle')), findsOneWidget);
    expect(find.byKey(const ValueKey('health-day-2026-11-25-none')), findsOneWidget);

    // 能翻到上个月
    await tester.tap(find.bySemanticsLabel('上个月'));
    await tester.pump();
    expect(find.text('10月 · 每天一格'), findsOneWidget);
    expect(find.byKey(const ValueKey('health-day-2026-10-01-ok')), findsOneWidget);

    // 最近日志：只显示末尾的非空行，去掉面板的 === 框线
    final tail = find.byKey(const Key('task-detail-log-tail'));
    expect(tail, findsOneWidget);
    final text = tester.widget<Text>(
      find.descendant(of: tail, matching: find.byType(Text)),
    );
    expect(text.data, '[18:00:01] 开始下载 ipdb 数据源…\nError: ETIMEDOUT');

    // 点最近日志 → 打开那条日志
    await tester.tap(find.byKey(const Key('task-detail-latest-log')));
    await _pumpFrames(tester);
    expect(find.text('日志页:5'), findsOneWidget);

    await _close(tester);
  });

  testWidgets('老面板（health 404）：不显示统计和月历，只显示最近日志，不报错', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _openSheet(tester, newPanel: false);

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('task-health-success-rate')), findsNothing);
    expect(find.byKey(const Key('health-calendar-title')), findsNothing);
    expect(find.byKey(const Key('task-health-retry')), findsNothing);
    expect(find.byKey(const Key('task-detail-log-tail')), findsOneWidget);

    await _close(tester);
  });

  testWidgets('加入常用开关调 favoriteTasksProvider', (tester) async {
    await _openSheet(tester, newPanel: true);

    final row = find.byKey(const Key('task-detail-favorite'));
    final container = ProviderScope.containerOf(tester.element(row));
    expect(container.read(favoriteTasksProvider), isNot(contains(12)));

    await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
    await _pumpFrames(tester, 5);
    expect(container.read(favoriteTasksProvider), contains(12));

    await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
    await _pumpFrames(tester, 5);
    expect(container.read(favoriteTasksProvider), isNot(contains(12)));

    await _close(tester);
  });

  testWidgets('按住立即运行：viewer 不显示，operator 显示；focusRun 时有提示描边', (tester) async {
    await _openSheet(tester, newPanel: true);
    expect(find.byKey(const Key('task-detail-hold-run')), findsNothing);
    // viewer 也看不到写操作
    expect(find.byKey(const Key('task-detail-delete')), findsNothing);
    await _close(tester);

    await _openSheet(tester, newPanel: true, operator: true, focusRun: true);
    expect(find.byKey(const Key('task-detail-hold-run')), findsOneWidget);
    expect(find.byKey(const Key('task-detail-run-focus')), findsOneWidget);
    expect(find.text('按住立即运行'), findsOneWidget);
    // 让三下脉冲走完，不留动画
    await _pumpFrames(tester, 200);
    await _close(tester);
  });

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('360 窄屏不溢出（${mode.name}）', (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await _openSheet(tester, newPanel: true, operator: true, themeMode: mode);
      expect(tester.takeException(), isNull);
      // 整页滚到底，所有区块都排一遍版
      await tester.drag(find.byType(Scrollable).last, const Offset(0, -3000));
      await _pumpFrames(tester, 10);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('task-detail-hold-run')), findsOneWidget);
      await _close(tester);
    });
  }

  test('切换任务互不影响：同一任务连发两次只认最后一次', () async {
    resetPanelInsightsForTest();
    var call = 0;
    DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter((options) async {
      call++;
      final mine = call;
      // 第一次请求慢、第二次快：第一次的结果回来时已经过期
      await Future<void>.delayed(Duration(milliseconds: mine == 1 ? 60 : 5));
      final json = _healthJson();
      (json['stats'] as Map<String, dynamic>)['runs'] = mine;
      return jsonResponse(json);
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(taskHealthProvider(12).notifier);
    final first = notifier.load();
    final second = notifier.load();
    await Future.wait([first, second]);
    expect(container.read(taskHealthProvider(12)).health?.stats.runs, 2);
    // 另一个任务的状态没被动过
    expect(container.read(taskHealthProvider(13)).loaded, isFalse);
  });
}
