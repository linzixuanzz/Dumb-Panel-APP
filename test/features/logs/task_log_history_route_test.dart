import 'package:daidai_app/core/auth/auth_provider.dart';
import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/network/dio_client.dart';
import 'package:daidai_app/core/router/app_router.dart';
import 'package:daidai_app/features/logs/views/log_list_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_http_adapter.dart';

/// 直接处于已登录状态，免得真实路由的 redirect 把页面踢回 /boot、/login。
class _AuthedNotifier extends AuthNotifier {
  _AuthedNotifier(super.authService) {
    state = const AuthState(status: AuthStatus.authenticated);
  }
}

/// issue #20：任务详情页「日志历史」走真实路由 `/tasks/:id/logs`。
/// 这条路由用嵌套 ProviderScope 给日志列表一份独立的 provider，
/// 这里钉住：只看这个任务、标题对、底部「日志」标签页那份筛选不被改。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues({});
    DioClient.instance.setBaseUrl('https://panel.test');
  });

  testWidgets('经真实路由打开单任务日志：标题、筛选参数、根作用域不受影响', (tester) async {
    final logQueries = <Map<String, dynamic>>[];
    DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.logs) {
        logQueries.add(Map<String, dynamic>.from(options.queryParameters));
        return jsonResponse({'data': <Object>[], 'total': 0});
      }
      return jsonResponse(<String, dynamic>{}, status: 404);
    });

    final container = ProviderContainer(
      overrides: [
        authProvider.overrideWith(
          (ref) => _AuthedNotifier(ref.read(authServiceProvider)),
        ),
      ],
    );
    addTearDown(container.dispose);
    final router = container.read(routerProvider);
    router.go('/tasks/12/logs', extra: '京东签到');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(tester.takeException(), isNull);
    expect(find.byType(LogListPage), findsOneWidget);
    expect(find.text('京东签到 的日志'), findsOneWidget);

    // 发出去的日志请求都带着这个任务的筛选，没有一条是不带筛选的全量请求
    expect(logQueries, isNotEmpty);
    expect(logQueries.every((query) => query['task_id'] == '12'), isTrue);

    // 底部「日志」标签页用的是根作用域那份，筛选条件仍是空的
    expect(container.read(logListProvider).taskIdFilter, isEmpty);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
