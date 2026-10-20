import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/network/dio_client.dart';
import 'package:daidai_app/features/tasks/views/task_detail_page.dart';
import 'package:daidai_app/features/tasks/views/task_list_page.dart';
import 'package:daidai_app/shared/models/task.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_http_adapter.dart';

Map<String, dynamic> _taskJson({String command = 'task jd/sign.py'}) => {
  'id': 12,
  'name': '京东签到',
  'command': command,
  'cron_expression': '0 8 * * *',
  'task_type': 'cron',
  'status': 1,
  'created_at': '2026-08-01T08:00:00Z',
  'updated_at': '2026-08-02T08:00:00Z',
};

/// 详情页 + 两个目标路由的替身：只看跳到了哪、带了什么。
GoRouter _router(Widget home) => GoRouter(
  routes: [
    GoRoute(path: '/', builder: (_, state) => home),
    GoRoute(
      path: '/tasks/:id/detail',
      builder: (_, state) => TaskDetailPage(
        taskId: int.parse(state.pathParameters['id']!),
        initialTask: state.extra as Task?,
      ),
    ),
    GoRoute(
      path: '/scripts/view',
      builder: (_, state) => Text('脚本页:${state.extra}'),
    ),
  ],
);

/// 有常驻转圈（列表加载态）的页面不能 pumpAndSettle，按帧推进。
Future<void> _pumpFrames(WidgetTester tester, [int count = 20]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// issue #20：点任务进详情页；「脚本」行能解析出路径时可点、跳脚本页，解析不出显示「-」且不可点。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues({});
    DioClient.instance.setBaseUrl('https://panel.test');
  });

  testWidgets('非多选模式下点任务卡片进入详情页', (tester) async {
    DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.tasks) {
        return jsonResponse({
          'data': [_taskJson()],
          'total': 1,
        });
      }
      // 视图、分组这些可选能力按老面板 404 处理，列表照常出
      return jsonResponse(<String, dynamic>{}, status: 404);
    });

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(routerConfig: _router(const TaskListPage())),
      ),
    );
    await _pumpFrames(tester);

    expect(find.text('京东签到'), findsOneWidget);
    await tester.tap(find.text('京东签到'));
    await _pumpFrames(tester);

    expect(find.byType(TaskDetailPage), findsOneWidget);
    expect(find.text('任务详情'), findsOneWidget);
    expect(find.text('jd/sign.py'), findsOneWidget);

    // 收掉页面与提示条定时器
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('脚本行：解析出路径时点它跳到脚本页，extra 是脚本路径', (tester) async {
    final task = Task.fromJson(_taskJson());
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(
          routerConfig: _router(TaskDetailPage(taskId: 12, initialTask: task)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('京东签到'), findsOneWidget);
    expect(find.text('task jd/sign.py'), findsOneWidget);
    final scriptRow = find.byKey(const Key('task-detail-script'));
    expect(
      find.descendant(
        of: scriptRow,
        matching: find.byIcon(Icons.chevron_right),
      ),
      findsOneWidget,
    );

    await tester.tap(scriptRow);
    await tester.pumpAndSettle();

    expect(find.text('脚本页:jd/sign.py'), findsOneWidget);
  });

  testWidgets('脚本行：解析不出路径时显示「-」且不可点', (tester) async {
    final task = Task.fromJson(_taskJson(command: 'echo hello'));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(
          routerConfig: _router(TaskDetailPage(taskId: 12, initialTask: task)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final scriptRow = find.byKey(const Key('task-detail-script'));
    expect(
      find.descendant(of: scriptRow, matching: find.text('-')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: scriptRow,
        matching: find.byIcon(Icons.chevron_right),
      ),
      findsNothing,
    );
    expect(tester.widget<InkWell>(scriptRow).onTap, isNull);

    await tester.tap(scriptRow);
    await tester.pumpAndSettle();

    expect(find.textContaining('脚本页'), findsNothing);
    expect(find.byType(TaskDetailPage), findsOneWidget);
  });

  testWidgets('没下发的字段不显示那一行', (tester) async {
    // 从没运行过：没有下次 / 最后运行 / 时长
    final task = Task.fromJson(_taskJson());
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(
          routerConfig: _router(TaskDetailPage(taskId: 12, initialTask: task)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('最后运行'), findsNothing);
    expect(find.text('最后运行时长'), findsNothing);
    expect(find.text('下次运行'), findsNothing);
    expect(find.text('最新日志'), findsOneWidget);
    expect(find.text('日志历史'), findsOneWidget);
  });
}
