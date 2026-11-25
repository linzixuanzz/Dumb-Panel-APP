import 'package:daidai_app/core/auth/auth_provider.dart';
import 'package:daidai_app/core/auth/auth_service.dart';
import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/network/dio_client.dart';
import 'package:daidai_app/core/storage/secure_storage.dart';
import 'package:daidai_app/features/tasks/providers/favorite_tasks_provider.dart';
import 'package:daidai_app/features/tasks/views/task_list_page.dart';
import 'package:daidai_app/features/tasks/widgets/favorite_task_cards.dart';
import 'package:daidai_app/shared/models/user.dart';
import 'package:daidai_app/shared/widgets/hold_to_run_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_http_adapter.dart';

/// APP v2.0 · A1 常用任务（B1）。
///
/// 钉住：
/// 1. `favoriteTasksProvider` 契约：最多 5 个、满了 toggle 返回 false 不加、remove、reorder 口径、
///    按面板分开存（键 `tasks.favorites::<scope>`）、读盘前的改动不被读盘结果覆盖、prune 剔除已删任务；
/// 2. 页面：没有常用任务时是引导卡；有常用任务时出缺口卡片，operator 才有「按住运行」、否则是「查看」；
///    长按任务行「加入常用」写进本机；列表全量刷新后剔除已删的常用任务，带筛选的结果不剔除；
/// 3. 倒计时文字的几档格式。
const _panelA = 'https://panel-a.test';
const _panelB = 'https://panel-b.test';

String _prefsKey(String url) =>
    'ui_state_tasks.favorites::${SecureStorage.scopeOf(url)}';

Map<String, dynamic> _taskJson(int id, {String? name}) => {
  'id': id,
  'name': name ?? '任务$id',
  'command': 'task t$id.py',
  'cron_expression': '0 8 * * *',
  'task_type': 'cron',
  'status': 1,
  'created_at': '2026-08-01T08:00:00Z',
  'updated_at': '2026-08-02T08:00:00Z',
};

/// 直接塞一个已登录用户，不走登录流程。
class _FakeAuthNotifier extends AuthNotifier {
  _FakeAuthNotifier(String role) : super(AuthService()) {
    state = AuthState(
      status: AuthStatus.authenticated,
      user: User(
        id: 1,
        username: 'admin',
        role: role,
        enabled: true,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
    );
  }
}

/// 读盘是异步的：等它落地。
Future<void> _settle() => pumpEventQueue();

void main() {
  group('favoriteTasksProvider', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      DioClient.instance.setBaseUrl(_panelA);
    });

    test('最多 5 个：满了 toggle 返回 false、不加；再点一次已收藏的是移出', () async {
      final notifier = FavoriteTasksNotifier();
      await _settle();
      for (var id = 1; id <= 5; id++) {
        expect(notifier.toggle(id), isTrue);
      }
      expect(notifier.toggle(6), isFalse);
      expect(notifier.state, [1, 2, 3, 4, 5]);
      expect(notifier.isFavorite(6), isFalse);

      expect(notifier.toggle(3), isTrue);
      expect(notifier.state, [1, 2, 4, 5]);
      notifier.remove(1);
      notifier.remove(99); // 不在里面：什么都不做
      expect(notifier.state, [2, 4, 5]);
    });

    test('reorder 口径同 ReorderableListView：往后拖时 newIndex 是移除前的位置', () async {
      final notifier = FavoriteTasksNotifier();
      await _settle();
      for (final id in [1, 2, 3]) {
        notifier.toggle(id);
      }
      notifier.reorder(0, 3); // 第一个拖到最后
      expect(notifier.state, [2, 3, 1]);
      notifier.reorder(2, 0); // 最后一个拖到最前
      expect(notifier.state, [1, 2, 3]);
      notifier.reorder(5, 0); // 越界忽略
      expect(notifier.state, [1, 2, 3]);
    });

    test('落盘：键按面板区分，换面板读到的是那台面板自己的一份', () async {
      final a = FavoriteTasksNotifier();
      await _settle();
      a.toggle(7);
      a.toggle(8);
      await _settle();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(_prefsKey(_panelA)), ['7', '8']);

      DioClient.instance.setBaseUrl(_panelB);
      expect(a.syncScope(), isTrue);
      await _settle();
      // B 台没有收藏；同一个 id 7 在 B 上是另一条任务，不能带过去
      expect(a.state, isEmpty);
      a.toggle(7);
      await _settle();
      expect(prefs.getStringList(_prefsKey(_panelB)), ['7']);

      DioClient.instance.setBaseUrl(_panelA);
      final again = FavoriteTasksNotifier();
      await _settle();
      expect(again.state, [7, 8]);
      // 面板没变时 syncScope 什么都不做
      expect(again.syncScope(), isFalse);
    });

    test('读盘前就点了「加入常用」：读回来时合并，盘上原有的不丢', () async {
      SharedPreferences.setMockInitialValues({
        _prefsKey(_panelA): ['1', '2'],
      });
      final notifier = FavoriteTasksNotifier();
      notifier.toggle(9); // 读盘还没回来
      await _settle();
      expect(notifier.state, [9, 1, 2]);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(_prefsKey(_panelA)), ['9', '1', '2']);
    });

    test('盘上的脏数据（非数字、重复、超过 5 个）读进来时洗掉', () async {
      SharedPreferences.setMockInitialValues({
        _prefsKey(_panelA): ['3', 'x', '3', '4', '5', '6', '7', '8'],
      });
      final notifier = FavoriteTasksNotifier();
      await _settle();
      expect(notifier.state, [3, 4, 5, 6, 7]);
    });

    test('prune 剔除已经不存在的任务；换了面板先换成新面板那份再剔', () async {
      SharedPreferences.setMockInitialValues({
        _prefsKey(_panelA): ['1', '2', '3'],
        _prefsKey(_panelB): ['1', '5'],
      });
      final notifier = FavoriteTasksNotifier();
      await _settle();
      await notifier.prune({1, 3, 10});
      expect(notifier.state, [1, 3]);

      DioClient.instance.setBaseUrl(_panelB);
      await notifier.prune({5});
      expect(notifier.state, [5]);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(_prefsKey(_panelB)), ['5']);
      // A 台的那份不受 B 台剔除影响
      expect(prefs.getStringList(_prefsKey(_panelA)), ['1', '3']);
    });
  });

  group('倒计时文字', () {
    final now = DateTime(2026, 11, 25, 10, 0, 0);
    test('1 小时内 MM:SS、1 天内 H 时 MM 分、更远 N 天 H 时、到点了显示即将运行', () {
      expect(
        formatTaskCountdown(now.add(const Duration(minutes: 4, seconds: 5)), now),
        '04:05',
      );
      expect(
        formatTaskCountdown(now.add(const Duration(hours: 2, minutes: 7)), now),
        '2 时 07 分',
      );
      expect(
        formatTaskCountdown(now.add(const Duration(days: 3, hours: 5)), now),
        '3 天 5 时',
      );
      expect(formatTaskCountdown(now, now), '即将运行');
      expect(
        formatTaskCountdown(now.subtract(const Duration(minutes: 1)), now),
        '即将运行',
      );
    });
  });

  group('任务页', () {
    late List<Map<String, dynamic>> taskQueries;
    late List<Map<String, dynamic>> tasks;

    setUp(() {
      taskQueries = [];
      tasks = [_taskJson(12, name: '京东签到'), _taskJson(13, name: '每日巡检')];
      FlutterSecureStorage.setMockInitialValues({});
      DioClient.instance.setBaseUrl(_panelA);
      DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter((options) {
        if (options.path == ApiEndpoints.tasks) {
          taskQueries.add(Map<String, dynamic>.of(options.queryParameters));
          return jsonResponse({'data': tasks, 'total': tasks.length});
        }
        // 视图、分组这些可选能力按老面板 404 处理，列表照常出
        return jsonResponse(<String, dynamic>{}, status: 404);
      });
    });

    /// 有常驻转圈（列表加载态）的页面不能 pumpAndSettle，按帧推进。
    Future<void> pumpFrames(WidgetTester tester, [int count = 20]) async {
      for (var i = 0; i < count; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    Future<void> openPage(WidgetTester tester, {String? role}) async {
      tester.view.physicalSize = const Size(400, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            if (role != null)
              authProvider.overrideWith((ref) => _FakeAuthNotifier(role)),
          ],
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

    testWidgets('没有常用任务：显示引导卡；长按任务行「加入常用」后出卡片并写进本机', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await openPage(tester, role: 'admin');

      expect(find.text('Hi, admin!'), findsOneWidget);
      expect(find.text('长按任务加入常用'), findsOneWidget);
      expect(find.byType(HoldToRunButton), findsNothing);

      await tester.longPress(find.text('京东签到'));
      await pumpFrames(tester);
      await tester.tap(find.text('加入常用'));
      await pumpFrames(tester, 40);

      expect(find.text('长按任务加入常用'), findsNothing);
      // 卡片上一份、列表里一份
      expect(find.text('京东签到'), findsNWidgets(2));
      expect(find.byType(HoldToRunButton), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(_prefsKey(_panelA)), ['12']);

      await closePage(tester);
    });

    testWidgets('viewer 看不到「按住运行」，缺口里是「查看」', (tester) async {
      SharedPreferences.setMockInitialValues({
        _prefsKey(_panelA): ['13'],
      });
      await openPage(tester, role: 'viewer');

      expect(find.byType(FavoriteTaskSection), findsOneWidget);
      expect(find.byType(HoldToRunButton), findsNothing);
      expect(find.text('查看'), findsOneWidget);
      expect(find.text('每日巡检'), findsNWidgets(2));

      await closePage(tester);
    });

    testWidgets('全量刷新后剔除已删的常用任务；带筛选的结果不剔除', (tester) async {
      SharedPreferences.setMockInitialValues({
        _prefsKey(_panelA): ['12', '99'],
      });
      await openPage(tester, role: 'admin');
      final prefs = await SharedPreferences.getInstance();
      // 99 不在全量列表里：已经被删了
      expect(prefs.getStringList(_prefsKey(_panelA)), ['12']);

      // 切到「已禁用」：面板只回 13，但这是筛选结果，12 不能被当成删了
      tasks = [_taskJson(13, name: '每日巡检')];
      await tester.tap(find.text('已禁用'));
      await pumpFrames(tester, 40);
      expect(taskQueries.last['status'], '0');
      expect(prefs.getStringList(_prefsKey(_panelA)), ['12']);
      // 列表里看不到 12 了，卡片靠快照照常显示
      expect(find.text('京东签到'), findsOneWidget);

      await closePage(tester);
    });
  });
}
