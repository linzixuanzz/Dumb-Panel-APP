import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/network/dio_client.dart';
import 'package:daidai_app/features/tasks/providers/task_provider.dart';
import 'package:daidai_app/features/tasks/views/task_list_page.dart';
import 'package:daidai_app/shared/models/task_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_http_adapter.dart';

/// APP issue #28：任务列表引入网页端的快捷排序（11 项，同 web/src/views/tasks/index.vue 的 quickSortOptions）。
///
/// 钉住：
/// 1. 选中后 `GET /tasks` 的 sort_rules 是那一条规则；默认排序不传（没视图时）；
/// 2. 优先级「快捷排序 > 视图自带排序」，默认排序时用视图的；
/// 3. 用户切视图时快捷排序复位，冷启动恢复视图（setViewSelection）不复位；
/// 4. 快捷排序下不许拖拽排序；
/// 5. 页面：本机记住上次选择（`tasks.quick_sort`），切视图后记忆清掉。
const _viewRules = '[{"field":"created_at","direction":"desc"}]';

Map<String, dynamic> _taskJson(int id) => {
  'id': id,
  'name': '任务$id',
  'command': 'task t$id.py',
  'cron_expression': '0 8 * * *',
  'task_type': 'cron',
  'status': 1,
};

void main() {
  group('provider', () {
    late List<Map<String, dynamic>> queries;
    late TaskNotifier notifier;

    setUp(() {
      queries = [];
      notifier = TaskNotifier(
        dio: dioWithAdapter(
          FakeHttpAdapter((options) {
            queries.add(Map<String, dynamic>.of(options.queryParameters));
            return jsonResponse({
              'data': [_taskJson(1), _taskJson(2)],
              'total': 2,
            });
          }),
        ),
      );
    });

    const view = TaskView(
      id: 5,
      name: '最新创建',
      sortRules: [TaskViewSortRule(field: 'created_at', direction: 'desc')],
    );

    test('选中快捷排序：sort_rules 就是这一条规则', () async {
      notifier.applyQuickSort(
        const TaskViewSortRule(field: 'name', direction: 'desc'),
      );
      await pumpEventQueue();

      expect(queries.last['sort_rules'], '[{"field":"name","direction":"desc"}]');
    });

    test('默认排序且没选视图：不传 sort_rules', () async {
      await notifier.load();
      expect(queries.last.containsKey('sort_rules'), isFalse);
    });

    test('快捷排序优先于视图排序；切回默认排序后用视图的', () async {
      notifier.setViewSelection(view);
      notifier.applyQuickSort(const TaskViewSortRule(field: 'next_run_at'));
      await pumpEventQueue();
      expect(
        queries.last['sort_rules'],
        '[{"field":"next_run_at","direction":"asc"}]',
      );

      notifier.applyQuickSort(null);
      await pumpEventQueue();
      expect(queries.last['sort_rules'], _viewRules);
    });

    test('用户切视图时快捷排序复位；冷启动恢复视图不复位', () async {
      notifier.setQuickSortSelection(
        const TaskViewSortRule(field: 'cron_expression'),
      );
      // 冷启动恢复走 setViewSelection：刚恢复的快捷排序不能被抹掉。
      notifier.setViewSelection(view);
      expect(notifier.state.quickSort?.field, 'cron_expression');

      notifier.applyView(view);
      await pumpEventQueue();
      expect(notifier.state.quickSort, isNull);
      expect(queries.last['sort_rules'], _viewRules);
    });

    test('快捷排序下不许拖拽排序，切回默认后恢复', () async {
      await notifier.load();
      expect(notifier.state.dragSortDisabledReason, isNull);

      notifier.setQuickSortSelection(const TaskViewSortRule(field: 'name'));
      expect(notifier.state.dragSortDisabledReason, contains('默认排序'));

      notifier.setQuickSortSelection(null);
      expect(notifier.state.dragSortDisabledReason, isNull);
    });
  });

  group('页面', () {
    late List<Map<String, dynamic>> taskQueries;

    setUp(() {
      taskQueries = [];
      FlutterSecureStorage.setMockInitialValues({});
      DioClient.instance.setBaseUrl('https://panel.test');
      DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter((options) {
        if (options.path == ApiEndpoints.tasks) {
          taskQueries.add(Map<String, dynamic>.of(options.queryParameters));
          return jsonResponse({
            'data': [_taskJson(1), _taskJson(2)],
            'total': 2,
          });
        }
        if (options.path == ApiEndpoints.taskViews) {
          return jsonResponse({
            'data': [
              {
                'id': 5,
                'name': '最新创建',
                'filters': '[]',
                'sort_rules': _viewRules,
              },
            ],
          });
        }
        return jsonResponse(<String, dynamic>{}, status: 404);
      });
    });

    /// 有常驻转圈（列表加载态）的页面不能 pumpAndSettle，按帧推进。
    Future<void> pumpFrames(WidgetTester tester, [int count = 20]) async {
      for (var i = 0; i < count; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    Future<void> openPage(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp.router(
            routerConfig: GoRouter(
              routes: [
                GoRoute(path: '/', builder: (_, state) => const TaskListPage()),
              ],
            ),
          ),
        ),
      );
      await pumpFrames(tester);
    }

    Future<void> closePage(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }

    Future<String?> savedQuickSort() async {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('ui_state_tasks.quick_sort');
    }

    testWidgets('选「名称 Z→A」：请求带这条规则、按钮显示当前排序、本机记住、再打开时打勾', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await openPage(tester);
      expect(taskQueries.last.containsKey('sort_rules'), isFalse);

      await tester.tap(find.text('默认排序'));
      await pumpFrames(tester);
      // 11 项都在弹层里
      for (final label in [
        '名称 A→Z',
        '创建时间（最新优先）',
        '最后运行（最早优先）',
        '下次运行（最快到来）',
        '定时规则（每天时刻 晚→早）',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      await tester.tap(find.text('名称 Z→A'));
      await pumpFrames(tester);

      expect(
        taskQueries.last['sort_rules'],
        '[{"field":"name","direction":"desc"}]',
      );
      expect(find.text('名称 ↓'), findsOneWidget);
      expect(await tester.runAsync(savedQuickSort), 'name:desc');

      await tester.tap(find.text('名称 ↓'));
      await pumpFrames(tester);
      expect(
        find.descendant(
          of: find.widgetWithText(ListTile, '名称 Z→A'),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );

      await closePage(tester);
    });

    testWidgets('冷启动恢复上次的快捷排序：第一次请求就带上它', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'ui_state_tasks.quick_sort': 'last_run_at:desc',
      });
      await openPage(tester);

      expect(
        taskQueries.first['sort_rules'],
        '[{"field":"last_run_at","direction":"desc"}]',
      );
      expect(find.text('最后运行 ↓'), findsOneWidget);

      await closePage(tester);
    });

    testWidgets('切视图：快捷排序复位成默认、改用视图的排序、本机记忆清掉', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'ui_state_tasks.quick_sort': 'name:asc',
      });
      await openPage(tester);
      expect(find.text('名称 ↑'), findsOneWidget);

      await tester.tap(find.text('全部任务'));
      await pumpFrames(tester);
      await tester.tap(find.text('最新创建'));
      await pumpFrames(tester);

      expect(taskQueries.last['sort_rules'], _viewRules);
      expect(find.text('默认排序'), findsOneWidget);
      expect(await tester.runAsync(savedQuickSort), '');

      await closePage(tester);
    });
  });
}
