import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/network/dio_client.dart';
import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/features/tasks/views/task_detail_page.dart';
import 'package:daidai_app/features/tasks/views/task_form_page.dart';
import 'package:daidai_app/shared/models/task.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_http_adapter.dart';

/// 面板 #168 的 APP 同步：任务级「可用环境变量」（全部 / 指定）。
///
/// 面板 v3.4.0 起任务数据带 `env_scope` / `env_groups` / `env_names`，老面板没有这三个键、
/// 也会静默忽略请求体里的这三项。所以 APP 一律按**形状探测**：
/// 有键才出表单分区、才在请求体里带、详情页才出那一行；没键时一个字段都不发，
/// 免得用户以为设上了其实没存。
Map<String, dynamic> _taskJson({
  int id = 12,
  String? envScope,
  Object? envGroups,
  Object? envNames,
}) => {
  'id': id,
  'name': '京东签到',
  'command': 'task jd/sign.py',
  'cron_expression': '0 8 * * *',
  'task_type': 'cron',
  'status': 1,
  'created_at': '2026-08-01T08:00:00Z',
  'updated_at': '2026-08-02T08:00:00Z',
  // 空感知元素：值为 null 时整个键都不放，造出「老面板没有这个键」
  'env_scope': ?envScope,
  'env_groups': ?envGroups,
  'env_names': ?envNames,
};

/// 有常驻转圈的页面不能 pumpAndSettle，按帧推进。
Future<void> _pumpFrames(WidgetTester tester, [int count = 20]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// 假面板：记下每个写请求的请求体（FakeHttpAdapter 自己不记 options.data）。
class _FakePanel {
  _FakePanel({this.listTasks = const []});

  /// GET /tasks 回的任务列表（新建任务时形状探测看的就是它）。
  final List<Map<String, dynamic>> listTasks;
  final List<({String method, String path, Map<String, dynamic> body})>
  writes = [];

  late final FakeHttpAdapter adapter = FakeHttpAdapter((options) {
    if (options.method == 'PUT' || options.method == 'POST') {
      if (options.path != ApiEndpoints.cronParse) {
        writes.add((
          method: options.method,
          path: options.path,
          body: Map<String, dynamic>.from(options.data as Map),
        ));
        return jsonResponse({'message': '操作成功'});
      }
    }
    if (options.method == 'GET' && options.path == ApiEndpoints.tasks) {
      return jsonResponse({'data': listTasks, 'total': listTasks.length});
    }
    if (options.path == ApiEndpoints.envsGroups) {
      return jsonResponse({
        'data': ['京东', '美团'],
      });
    }
    if (options.path == ApiEndpoints.envsNames) {
      return jsonResponse({
        'data': [
          {'name': 'JD_COOKIE', 'count': 3},
          {'name': 'MT_TOKEN', 'count': 1},
        ],
      });
    }
    // 渠道、Python 运行时、cron 模板与解析这些可选能力按老面板 404 处理
    return jsonResponse(<String, dynamic>{}, status: 404);
  });
}

Future<GoRouter> _openForm(
  WidgetTester tester,
  _FakePanel panel, {
  Task? task,
}) async {
  DioClient.instance.dio.httpClientAdapter = panel.adapter;
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, state) => const Scaffold(body: Text('列表页')),
      ),
      GoRoute(path: '/form', builder: (_, state) => TaskFormPage(task: task)),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp.router(
        theme: AppTheme.light(),
        routerConfig: router,
      ),
    ),
  );
  router.push('/form');
  await _pumpFrames(tester);
  return router;
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await _pumpFrames(tester);
}

Future<void> _save(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  await tester.tap(find.text('保存'));
  await _pumpFrames(tester);
}

Future<void> _closePage(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues({});
    DioClient.instance.setBaseUrl('https://panel.test');
  });

  group('模型解析', () {
    test('有键：指定 + 两个数组原样拿到', () {
      final task = Task.fromJson(
        _taskJson(
          envScope: 'selected',
          envGroups: ['京东', '美团'],
          envNames: ['JD_COOKIE'],
        ),
      );
      expect(task.hasEnvScope, isTrue);
      expect(task.isEnvScopeSelected, isTrue);
      expect(task.envGroups, ['京东', '美团']);
      expect(task.envNames, ['JD_COOKIE']);
    });

    test('有键：全部，空数组', () {
      final task = Task.fromJson(
        _taskJson(envScope: 'all', envGroups: <String>[], envNames: <String>[]),
      );
      expect(task.hasEnvScope, isTrue);
      expect(task.isEnvScopeSelected, isFalse);
      expect(task.envScope, 'all');
      expect(task.envGroups, isEmpty);
      expect(task.envNames, isEmpty);
    });

    test('无键（老面板）：不支持，按全部、两个列表为空', () {
      final task = Task.fromJson(_taskJson());
      expect(task.hasEnvScope, isFalse);
      expect(task.isEnvScopeSelected, isFalse);
      expect(task.envGroups, isEmpty);
      expect(task.envNames, isEmpty);
    });

    test('env_scope 为 null 与缺失同等对待', () {
      final json = _taskJson()..['env_scope'] = null;
      expect(Task.fromJson(json).hasEnvScope, isFalse);
    });

    test('不认识的 scope 按全部；逗号字符串也能解析，去空去重', () {
      final task = Task.fromJson(
        _taskJson(
          envScope: 'weird',
          envGroups: '京东, ,京东,美团',
          envNames: [' JD_COOKIE ', '', 'JD_COOKIE'],
        ),
      );
      expect(task.hasEnvScope, isTrue);
      expect(task.envScope, 'all');
      expect(task.envGroups, ['京东', '美团']);
      expect(task.envNames, ['JD_COOKIE']);
    });
  });

  group('任务表单', () {
    testWidgets('编辑、面板支持：显示分区，改成指定并选变量名，PUT 带三项', (tester) async {
      final panel = _FakePanel();
      final task = Task.fromJson(
        _taskJson(
          envScope: 'all',
          envGroups: <String>[],
          envNames: <String>[],
        ),
      );
      await _openForm(tester, panel, task: task);

      expect(find.text('环境变量'), findsOneWidget);
      // 「全部」时不出两个多选
      expect(find.byKey(const Key('task-form-env-names')), findsNothing);

      await _tapVisible(
        tester,
        find.byKey(const Key('task-form-env-scope-selected')),
      );
      expect(find.byKey(const Key('task-form-env-groups')), findsOneWidget);
      expect(find.byKey(const Key('task-form-env-names')), findsOneWidget);
      expect(find.textContaining('这不是沙箱'), findsOneWidget);

      // 变量名弹层：标签照变量页写成 `JD_COOKIE (3)`，可搜索
      await _tapVisible(tester, find.byKey(const Key('task-form-env-names')));
      expect(find.text('选择变量名'), findsOneWidget);
      expect(find.text('JD_COOKIE (3)'), findsOneWidget);
      expect(find.text('MT_TOKEN (1)'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('task-form-env-sheet-search')),
        'jd',
      );
      await tester.pump();
      expect(find.text('MT_TOKEN (1)'), findsNothing);
      await tester.tap(find.text('JD_COOKIE (3)'));
      await tester.pump();
      await tester.tap(find.text('确定（1）'));
      await _pumpFrames(tester);
      expect(find.text('JD_COOKIE'), findsOneWidget);

      await _save(tester);

      expect(panel.writes, hasLength(1));
      final write = panel.writes.single;
      expect(write.method, 'PUT');
      expect(write.path, ApiEndpoints.taskById(12));
      expect(write.body['env_scope'], 'selected');
      expect(write.body['env_groups'], isEmpty);
      expect(write.body['env_names'], ['JD_COOKIE']);
      expect(find.text('列表页'), findsOneWidget);

      await _closePage(tester);
    });

    testWidgets('编辑、指定回显；改回全部时两个列表发空数组', (tester) async {
      final panel = _FakePanel();
      final task = Task.fromJson(
        _taskJson(
          envScope: 'selected',
          envGroups: ['京东'],
          envNames: ['JD_COOKIE'],
        ),
      );
      await _openForm(tester, panel, task: task);

      // 回显：两个多选里是已选的值
      expect(
        find.descendant(
          of: find.byKey(const Key('task-form-env-groups')),
          matching: find.text('京东'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('task-form-env-names')),
          matching: find.text('JD_COOKIE'),
        ),
        findsOneWidget,
      );

      await _tapVisible(tester, find.byKey(const Key('task-form-env-scope-all')));
      await _save(tester);

      final body = panel.writes.single.body;
      expect(body['env_scope'], 'all');
      expect(body['env_groups'], isEmpty);
      expect(body['env_names'], isEmpty);

      await _closePage(tester);
    });

    testWidgets('编辑、面板不支持（任务没有 env_scope 键）：不显示分区，PUT 一个字段都不带', (
      tester,
    ) async {
      final panel = _FakePanel();
      await _openForm(tester, panel, task: Task.fromJson(_taskJson()));

      expect(find.text('环境变量'), findsNothing);
      expect(
        find.byKey(const Key('task-form-env-scope-selected')),
        findsNothing,
      );

      await _save(tester);

      final body = panel.writes.single.body;
      expect(body.containsKey('env_scope'), isFalse);
      expect(body.containsKey('env_groups'), isFalse);
      expect(body.containsKey('env_names'), isFalse);
      // 老面板不支持时也不去拉候选
      expect(panel.adapter.countOf(ApiEndpoints.envsNames), 0);

      await _closePage(tester);
    });

    testWidgets('新建、已加载的任务里有带键的：显示分区，POST 带三项（默认全部）', (tester) async {
      final panel = _FakePanel(
        listTasks: [
          _taskJson(
            envScope: 'all',
            envGroups: <String>[],
            envNames: <String>[],
          ),
        ],
      );
      await _openForm(tester, panel);

      expect(find.text('环境变量'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextFormField, '任务名称'), '新任务');
      await tester.enterText(
        find.widgetWithText(TextFormField, '执行命令'),
        'task demo.py',
      );
      await _save(tester);

      final write = panel.writes.single;
      expect(write.method, 'POST');
      expect(write.body['env_scope'], 'all');
      expect(write.body['env_groups'], isEmpty);
      expect(write.body['env_names'], isEmpty);

      await _closePage(tester);
    });

    testWidgets('新建、已加载的任务都没有键（老面板）：不显示分区，POST 不带', (tester) async {
      final panel = _FakePanel(listTasks: [_taskJson()]);
      await _openForm(tester, panel);

      expect(find.text('环境变量'), findsNothing);

      await tester.enterText(find.widgetWithText(TextFormField, '任务名称'), '新任务');
      await tester.enterText(
        find.widgetWithText(TextFormField, '执行命令'),
        'task demo.py',
      );
      await _save(tester);

      final body = panel.writes.single.body;
      expect(body.containsKey('env_scope'), isFalse);
      expect(body.containsKey('env_groups'), isFalse);
      expect(body.containsKey('env_names'), isFalse);

      await _closePage(tester);
    });

    testWidgets('新建、一个任务都没有：不显示分区（新任务由面板默认全部）', (tester) async {
      final panel = _FakePanel();
      await _openForm(tester, panel);

      expect(find.text('环境变量'), findsNothing);

      await _closePage(tester);
    });

    for (final textScale in [1.0, 1.3]) {
      testWidgets('360×800、字号 $textScale：分区与多选弹层不溢出，确定按钮完整可点', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        tester.platformDispatcher.textScaleFactorTestValue = textScale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

        final panel = _FakePanel();
        final task = Task.fromJson(
          _taskJson(
            envScope: 'selected',
            envGroups: ['京东', '美团'],
            envNames: ['JD_COOKIE', 'MT_TOKEN'],
          ),
        );
        await _openForm(tester, panel, task: task);
        await tester.ensureVisible(
          find.byKey(const Key('task-form-env-names')),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);

        await _tapVisible(tester, find.byKey(const Key('task-form-env-groups')));
        expect(find.text('选择分组'), findsOneWidget);
        expect(tester.takeException(), isNull);

        // 键盘弹起时也放得下
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        addTearDown(tester.view.resetViewInsets);
        await _pumpFrames(tester);
        expect(tester.takeException(), isNull);

        // 「确定」完整落在屏幕内，点得到
        final confirm = find.text('确定（2）');
        expect(confirm, findsOneWidget);
        final rect = tester.getRect(
          find.ancestor(of: confirm, matching: find.byType(FilledButton)),
        );
        expect(rect.right, lessThanOrEqualTo(360));
        expect(rect.bottom, lessThanOrEqualTo(800 - 300));
        await tester.tap(confirm);
        await _pumpFrames(tester);
        expect(find.text('选择分组'), findsNothing);

        await _closePage(tester);
      });
    }
  });

  group('任务详情', () {
    GoRouter router(Task task) => GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, state) => TaskDetailPage(taskId: 12, initialTask: task),
        ),
      ],
    );

    Future<void> openDetail(WidgetTester tester, Task task) async {
      DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter(
        (_) => jsonResponse(<String, dynamic>{}, status: 404),
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp.router(routerConfig: router(task)),
        ),
      );
      await tester.pumpAndSettle();
    }

    String rowText(WidgetTester tester) {
      final row = find.byKey(const Key('task-detail-env-scope'));
      final texts = tester
          .widgetList<Text>(find.descendant(of: row, matching: find.byType(Text)))
          .map((text) => text.data)
          .toList();
      return texts.last ?? '';
    }

    testWidgets('指定：写出分组与变量名', (tester) async {
      await openDetail(
        tester,
        Task.fromJson(
          _taskJson(
            envScope: 'selected',
            envGroups: ['京东', '美团'],
            envNames: ['JD_COOKIE'],
          ),
        ),
      );
      expect(find.text('环境变量'), findsOneWidget);
      expect(rowText(tester), '指定（分组：京东、美团；变量：JD_COOKIE）');
    });

    testWidgets('指定但只选了变量名：空的那一半不写', (tester) async {
      await openDetail(
        tester,
        Task.fromJson(
          _taskJson(
            envScope: 'selected',
            envGroups: <String>[],
            envNames: ['JD_COOKIE', 'MT_TOKEN'],
          ),
        ),
      );
      expect(rowText(tester), '指定（变量：JD_COOKIE、MT_TOKEN）');
    });

    testWidgets('全部', (tester) async {
      await openDetail(
        tester,
        Task.fromJson(
          _taskJson(envScope: 'all', envGroups: <String>[], envNames: <String>[]),
        ),
      );
      expect(rowText(tester), '全部');
    });

    testWidgets('老面板（没有 env_scope 键）：不出这一行', (tester) async {
      await openDetail(tester, Task.fromJson(_taskJson()));
      expect(find.byKey(const Key('task-detail-env-scope')), findsNothing);
      expect(find.text('环境变量'), findsNothing);
    });
  });
}
