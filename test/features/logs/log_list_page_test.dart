import 'dart:convert';
import 'dart:io';

import 'package:daidai_app/core/auth/auth_provider.dart';
import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/features/logs/views/log_list_page.dart';
import 'package:daidai_app/shared/models/user.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_http_adapter.dart';

/// 直接处于已登录状态，角色可指定（删除类入口要 operator）。
class _AuthedNotifier extends AuthNotifier {
  _AuthedNotifier(super.authService, String role) {
    state = AuthState(
      status: AuthStatus.authenticated,
      user: User(
        id: 1,
        username: 'tester',
        role: role,
        enabled: true,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
    );
  }
}

typedef _Queries = List<Map<String, dynamic>>;

/// 按面板的存法造 content：zlib 压缩后再 base64。
String _compressed(String text) =>
    base64.encode(ZLibCodec().encode(utf8.encode(text)));

Map<String, dynamic> _log(int id, int status, {String content = ''}) => {
  'id': id,
  'task_id': 3,
  'task_name': '更新 IP 数据库',
  'status': status,
  'duration': 30.0,
  'content': content,
  'started_at': DateTime.now().toIso8601String(),
  'created_at': DateTime.now().toIso8601String(),
};

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues({});
  });

  /// 起一个日志页。返回每次日志列表请求的 query，以及假适配器（看 DELETE）。
  Future<(_Queries, _Queries, FakeHttpAdapter)> pumpPage(
    WidgetTester tester, {
    String role = 'viewer',
    LogListPage page = const LogListPage(),
  }) async {
    tester.view.physicalSize = const Size(400, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final logQueries = <Map<String, dynamic>>[];
    final dashboardQueries = <Map<String, dynamic>>[];
    final adapter = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.logs && options.method == 'GET') {
        logQueries.add(Map<String, dynamic>.from(options.queryParameters));
        return jsonResponse({
          'data': [
            _log(
              7,
              1,
              content: _compressed(
                '=== 开始执行 ===\n请求中\nError: ETIMEDOUT 104.21.3.7:443\n'
                '=== 执行结束 [x] 耗时 30.00 秒 退出码 1 ===\n',
              ),
            ),
            _log(8, 0, content: _compressed('ok\n')),
          ],
          'total': 2,
        });
      }
      if (options.path == ApiEndpoints.dashboard) {
        dashboardQueries.add(
          Map<String, dynamic>.from(options.queryParameters),
        );
        return jsonResponse({
          'data': {
            'today_logs': 29,
            'success_logs': 26,
            'failed_logs': 1,
            'aborted_logs': 2,
            'running_tasks': 0,
            'daily_stats': [
              {'date': '11-23', 'success': 140, 'failed': 3, 'aborted': 0},
              {'date': '11-24', 'success': 150, 'failed': 2, 'aborted': 1},
              {'date': '11-25', 'success': 26, 'failed': 1, 'aborted': 2},
            ],
          },
        });
      }
      return jsonResponse(<String, dynamic>{}, status: 200);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith(
            (ref) => _AuthedNotifier(ref.read(authServiceProvider), role),
          ),
          logListProvider.overrideWith(
            (ref) => LogListNotifier(dio: dioWithAdapter(adapter)),
          ),
        ],
        child: MaterialApp(home: page),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    return (logQueries, dashboardQueries, adapter);
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  testWidgets('日志标签页：月份标题、一句话总结、四色方块计数、趋势图、失败行的错误行', (tester) async {
    final (_, dashboardQueries, _) = await pumpPage(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('${DateTime.now().month} 月'), findsOneWidget);
    expect(find.text('今天执行 29 次，1 次失败'), findsOneWidget);
    for (final label in ['成功', '失败', '运行中', '已终止']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('26 次'), findsOneWidget);
    expect(find.text('2 次'), findsOneWidget);
    expect(find.text('执行趋势'), findsOneWidget);
    // 每日平均只算过完的两天：(143 + 153) / 2 = 148
    expect(find.text('148 次'), findsOneWidget);
    // 摘要请求带上了 range（本月天数，至少 7）
    expect(dashboardQueries.single['range'], greaterThanOrEqualTo(7));

    // 失败那条直接显示日志尾部的错误行，成功那条不显示
    expect(find.text('Error: ETIMEDOUT 104.21.3.7:443'), findsOneWidget);
    expect(find.text('今天'), findsWidgets);

    // viewer 没有删除权限：不能左滑，也没有「清理日志」
    expect(find.byType(Dismissible), findsNothing);
    expect(find.byTooltip('清理日志'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('点方块按状态筛选，再点同一个取消筛选', (tester) async {
    final (logQueries, _, _) = await pumpPage(tester);

    await tester.tap(find.text('失败'));
    await settle(tester);
    expect(logQueries.last['status'], 1);

    await tester.tap(find.text('失败'));
    await settle(tester);
    expect(logQueries.last.containsKey('status'), isFalse);

    await tester.tap(find.text('已终止'));
    await settle(tester);
    expect(logQueries.last['status'], 3);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('operator 左滑删除：先确认，确认后才发 DELETE', (tester) async {
    final (_, _, adapter) = await pumpPage(tester, role: 'operator');

    expect(find.byTooltip('清理日志'), findsOneWidget);
    expect(find.byType(Dismissible), findsNWidgets(2));

    // 左滑后先弹确认框，取消就不删
    await tester.drag(find.byType(Dismissible).first, const Offset(-600, 0));
    await settle(tester);
    expect(find.text('删除日志'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await settle(tester);
    expect(adapter.requests.where((r) => r.method == 'DELETE'), isEmpty);

    await tester.drag(find.byType(Dismissible).first, const Offset(-600, 0));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await settle(tester);
    final deletes = adapter.requests.where((r) => r.method == 'DELETE');
    expect(deletes.single.path, ApiEndpoints.logById(7));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('单任务日志页：不拉全局摘要、不画趋势，方块不带数字', (tester) async {
    final (logQueries, dashboardQueries, _) = await pumpPage(
      tester,
      page: const LogListPage(taskId: 12, taskName: '京东签到'),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('京东签到 的日志'), findsOneWidget);
    expect(find.byTooltip('返回'), findsOneWidget);
    expect(dashboardQueries, isEmpty);
    expect(find.text('执行趋势'), findsNothing);
    expect(find.text('失败'), findsOneWidget);
    expect(find.textContaining(' 次'), findsNothing);
    expect(logQueries.every((query) => query['task_id'] == '12'), isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
