import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/network/dio_client.dart';
import 'package:daidai_app/features/tasks/views/task_list_page.dart';
import 'package:daidai_app/shared/widgets/app_circle_add_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_http_adapter.dart';

Map<String, dynamic> _taskJson({double status = 1}) => {
  'id': 12,
  'name': '京东签到',
  'command': 'task jd/sign.py',
  'cron_expression': '0 8 * * *',
  'task_type': 'cron',
  'status': status,
  'created_at': '2026-08-01T08:00:00Z',
  'updated_at': '2026-08-02T08:00:00Z',
};

/// 列表 + 两个日志目标路由的替身：只看跳到了哪。
GoRouter _router() => GoRouter(
  routes: [
    GoRoute(path: '/', builder: (_, state) => const TaskListPage()),
    GoRoute(
      path: '/logs/:id/stream',
      builder: (_, state) => Text('日志页:${state.pathParameters['id']}'),
    ),
    GoRoute(
      path: '/tasks/:id/live-logs',
      builder: (_, state) => Text('实时日志:${state.pathParameters['id']}'),
    ),
    GoRoute(path: '/tasks/new', builder: (_, state) => const Text('新建任务页')),
  ],
);

/// 有常驻转圈（列表加载态）的页面不能 pumpAndSettle，按帧推进。
Future<void> _pumpFrames(WidgetTester tester, [int count = 20]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _openPage(
  WidgetTester tester, {
  double status = 1,
  double textScale = 1.0,
  List<String>? requested,
}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter((options) {
    requested?.add(options.path);
    if (options.path == ApiEndpoints.tasks) {
      return jsonResponse({
        'data': [_taskJson(status: status)],
        'total': 1,
      });
    }
    if (options.path == ApiEndpoints.taskLatestLog(12)) {
      return jsonResponse({
        'data': {'id': 77, 'task_id': 12, 'content': ''},
      });
    }
    // 视图、分组这些可选能力按老面板 404 处理，列表照常出
    return jsonResponse(<String, dynamic>{}, status: 404);
  });
  await tester.pumpWidget(
    ProviderScope(child: MaterialApp.router(routerConfig: _router())),
  );
  await _pumpFrames(tester);
}

Future<void> _closePage(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

const _swipeLabels = ['日志', '禁用', '置顶', '复制', '编辑', '删除'];

/// APP #21 同类排查（任务页页头）+ APP #22 评论（任务卡左滑加「日志」）。
///
/// 钉住：360 宽、字号 1.3 时页头不溢出、＋点得到；左滑露出 6 个按钮，全部完整落在屏幕内、
/// 每个不窄于 44dp；「日志」与详情页「最新日志」同一逻辑：没在跑开最近一次日志，在跑开实时日志。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues({});
    DioClient.instance.setBaseUrl('https://panel.test');
  });

  testWidgets('360×800、字号 1.3：页头不溢出，＋在屏幕内且点得到', (tester) async {
    await _openPage(tester, textScale: 1.3);

    expect(tester.takeException(), isNull);
    final add = find.byType(AppCircleAddButton);
    expect(tester.getRect(add).right, lessThanOrEqualTo(360));
    await tester.tap(add);
    await _pumpFrames(tester);
    expect(find.text('新建任务页'), findsOneWidget);

    await _closePage(tester);
  });

  testWidgets('360 宽左滑：6 个按钮都在屏幕内、不窄于 44dp，卡片左边还露一截', (tester) async {
    await _openPage(tester);

    await tester.drag(find.text('京东签到'), const Offset(-400, 0));
    await _pumpFrames(tester);

    expect(tester.takeException(), isNull);
    for (final label in _swipeLabels) {
      final button = find.ancestor(
        of: find.text(label),
        matching: find.byType(InkWell),
      );
      expect(button, findsOneWidget, reason: label);
      final rect = tester.getRect(button);
      expect(rect.left, greaterThanOrEqualTo(0), reason: label);
      expect(rect.right, lessThanOrEqualTo(360), reason: label);
      expect(rect.width, greaterThanOrEqualTo(44), reason: label);
    }
    // 拖到底的距离与按钮总宽一致：卡片右边缘正好停在第一个按钮左边 8dp 处，
    // 左侧（列表左边距 20 之后）还露出一截卡片。
    final firstButton = tester.getRect(
      find.ancestor(of: find.text('日志'), matching: find.byType(InkWell)),
    );
    // 卡片底板（DecoratedBox）在 Transform 里面，量它拿到的才是平移后的位置。
    final card = tester.getRect(
      find
          .ancestor(
            of: find.text('京东签到'),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    expect(card.right, moreOrLessEquals(firstButton.left - 8, epsilon: 0.5));
    expect(card.right, greaterThan(20 + 8));

    await _closePage(tester);
  });

  testWidgets('左滑「日志」：任务没在跑，打开最近一次日志', (tester) async {
    final requested = <String>[];
    await _openPage(tester, requested: requested);

    await tester.drag(find.text('京东签到'), const Offset(-400, 0));
    await _pumpFrames(tester);
    await tester.tap(find.text('日志'));
    await _pumpFrames(tester);

    expect(requested, contains(ApiEndpoints.taskLatestLog(12)));
    expect(find.text('日志页:77'), findsOneWidget);

    await _closePage(tester);
  });

  testWidgets('左滑「日志」：任务在跑，直接开实时日志、不去要最近一次日志', (tester) async {
    final requested = <String>[];
    await _openPage(tester, status: 2, requested: requested);

    await tester.drag(find.text('京东签到'), const Offset(-400, 0));
    await _pumpFrames(tester);
    await tester.tap(find.text('日志'));
    await _pumpFrames(tester);

    expect(requested, isNot(contains(ApiEndpoints.taskLatestLog(12))));
    expect(find.text('实时日志:12'), findsOneWidget);

    await _closePage(tester);
  });
}
