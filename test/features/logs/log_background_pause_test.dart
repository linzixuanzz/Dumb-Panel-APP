import 'package:daidai_app/core/auth/auth_provider.dart';
import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/features/logs/views/log_list_page.dart';
import 'package:daidai_app/shared/utils/panel_enums.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_http_adapter.dart';

class _AuthedNotifier extends AuthNotifier {
  _AuthedNotifier(super.authService) {
    state = const AuthState(status: AuthStatus.authenticated);
  }
}

Map<String, dynamic> _runningLogs() => {
  'data': [
    {
      'id': 1,
      'task_id': 12,
      'task_name': '京东签到',
      'status': kLogStatusRunning,
      'content': '',
      'started_at': DateTime.now().toIso8601String(),
      'created_at': DateTime.now().toIso8601String(),
    },
  ],
  'total': 1,
};

/// 日志页「有任务在跑时每 5 秒刷新」：APP 进后台（hidden / paused）停掉，
/// 回到前台立刻补拉一次，再接着每 5 秒刷新。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('进后台停掉 5 秒刷新；回到前台立刻补拉一次并恢复', (tester) async {
    var logGets = 0;
    final adapter = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.logs && options.method == 'GET') {
        logGets++;
        return jsonResponse(_runningLogs());
      }
      return jsonResponse(<String, dynamic>{});
    });

    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith(
            (ref) => _AuthedNotifier(ref.read(authServiceProvider)),
          ),
          logListProvider.overrideWith(
            (ref) => LogListNotifier(dio: dioWithAdapter(adapter)),
          ),
        ],
        child: const MaterialApp(
          home: LogListPage(taskId: 12, taskName: '京东签到'),
        ),
      ),
    );
    await settle();
    final afterOpen = logGets;
    expect(afterOpen, greaterThan(0));

    // 前台：5 秒后自动刷新一次
    await tester.pump(const Duration(seconds: 5));
    await settle();
    expect(logGets, afterOpen + 1);

    // 进后台：inactive → hidden → paused，之后 20 秒都不刷新
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final beforeBackground = logGets;
    await tester.pump(const Duration(seconds: 20));
    await settle();
    expect(logGets, beforeBackground, reason: '后台不轮询');

    // 回到前台：立刻补拉一次，之后照常每 5 秒刷新
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle();
    expect(logGets, beforeBackground + 1, reason: '回到前台立刻补拉');
    await tester.pump(const Duration(seconds: 5));
    await settle();
    expect(logGets, beforeBackground + 2);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('只是拉下通知栏（inactive → resumed）：不额外补拉', (tester) async {
    var logGets = 0;
    final adapter = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.logs && options.method == 'GET') {
        logGets++;
        return jsonResponse(_runningLogs());
      }
      return jsonResponse(<String, dynamic>{});
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith(
            (ref) => _AuthedNotifier(ref.read(authServiceProvider)),
          ),
          logListProvider.overrideWith(
            (ref) => LogListNotifier(dio: dioWithAdapter(adapter)),
          ),
        ],
        child: const MaterialApp(
          home: LogListPage(taskId: 12, taskName: '京东签到'),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    final before = logGets;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 200));
    expect(logGets, before);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
