import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/network/dio_client.dart';
import 'package:daidai_app/features/tasks/views/task_list_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_http_adapter.dart';

/// 「搜索任务」快捷方式（B8）跳 `/tasks?search=<毫秒时间戳>`。
///
/// 钉住：带新的 search 值进来就展开并聚焦搜索框；已经停在任务页再来一个新值也要再聚焦；
/// 同一个值不重复触发，页面重建（切 Tab 回来）时地址里还留着旧值也不触发。
/// 去重记录是 static 的，各用例用互不相同的值。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues({});
    DioClient.instance.setBaseUrl('https://panel.test');
    DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.tasks) {
        return jsonResponse({
          'data': [
            {
              'id': 12,
              'name': '京东签到',
              'command': 'task jd/sign.py',
              'cron_expression': '0 8 * * *',
              'task_type': 'cron',
              'status': 1,
            },
          ],
          'total': 1,
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

  Future<GoRouter> openPage(WidgetTester tester, String location) async {
    tester.view.physicalSize = const Size(400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: location,
      routes: [GoRoute(path: '/', builder: (_, state) => const TaskListPage())],
    );
    await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: router)),
    );
    await pumpFrames(tester);
    return router;
  }

  Future<void> closePage(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }

  bool searchFocused(WidgetTester tester) {
    final field = find.byType(EditableText);
    if (field.evaluate().isEmpty) {
      return false;
    }
    return tester.widget<EditableText>(field).focusNode.hasFocus;
  }

  testWidgets('不带 search：搜索框收着', (tester) async {
    await openPage(tester, '/');
    expect(find.byType(EditableText), findsNothing);
    await closePage(tester);
  });

  testWidgets('带新 search 值进来就聚焦；停在本页再来新值再聚焦；同值不重复', (tester) async {
    final router = await openPage(tester, '/?search=1001');
    expect(searchFocused(tester), isTrue);

    FocusManager.instance.primaryFocus?.unfocus();
    await pumpFrames(tester, 3);
    expect(searchFocused(tester), isFalse);

    router.go('/?search=1002');
    await pumpFrames(tester);
    expect(searchFocused(tester), isTrue);

    FocusManager.instance.primaryFocus?.unfocus();
    await pumpFrames(tester, 3);
    router.go('/?search=1002');
    await pumpFrames(tester);
    expect(searchFocused(tester), isFalse);

    await closePage(tester);
  });

  testWidgets('页面重建、地址里还是处理过的值：不再触发', (tester) async {
    await openPage(tester, '/?search=2001');
    expect(searchFocused(tester), isTrue);
    await closePage(tester);

    await openPage(tester, '/?search=2001');
    expect(find.byType(EditableText), findsNothing);
    await closePage(tester);
  });
}
