import 'dart:async';

import 'package:daidai_app/core/auth/auth_provider.dart';
import 'package:daidai_app/core/auth/auth_service.dart';
import 'package:daidai_app/core/integration/integration_data.dart';
import 'package:daidai_app/core/integration/integration_platform.dart';
import 'package:daidai_app/core/integration/integration_service.dart';
import 'package:daidai_app/core/integration/integration_settings.dart';
import 'package:daidai_app/features/overview/providers/dashboard_provider.dart';
import 'package:daidai_app/features/tasks/providers/favorite_tasks_provider.dart';
import 'package:daidai_app/features/tasks/providers/task_provider.dart';
import 'package:daidai_app/shared/models/insights.dart';
import 'package:daidai_app/shared/models/task.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quick_actions/quick_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_http_adapter.dart';

/// 记录所有平台调用的假实现：测试里不碰三条插件 channel。
class _FakePlatform implements IntegrationPlatform {
  final shortcutSets = <List<ShortcutItem>>[];
  void Function(String type)? shortcutHandler;
  final widgetWrites = <Map<String, String?>>[];
  int widgetUpdates = 0;
  final shown = <(String, String)>[];
  int cancels = 0;
  Uri? initialUri;
  final clicks = StreamController<Uri?>.broadcast();

  /// 通知栏里还有没有「运行中」通知：false 模拟用户划掉了，null 模拟查不了。
  bool? runningActive = true;

  @override
  Future<void> initShortcuts(void Function(String type) onAction) async {
    shortcutHandler = onAction;
  }

  @override
  Future<void> setShortcuts(List<ShortcutItem> items) async {
    shortcutSets.add(items);
  }

  @override
  Future<Uri?> initialWidgetUri() async => initialUri;

  @override
  Stream<Uri?> get widgetClicks => clicks.stream;

  @override
  Future<void> saveWidgetData(Map<String, String?> data) async {
    widgetWrites.add(data);
  }

  @override
  Future<void> updateWidget() async {
    widgetUpdates++;
  }

  @override
  Future<void> initNotifications(void Function() onTap) async {}

  @override
  Future<void> showRunning(String title, String body) async {
    shown.add((title, body));
  }

  @override
  Future<void> cancelRunning() async {
    cancels++;
  }

  @override
  Future<bool?> isRunningShown() async => runningActive;
}

class _Auth extends AuthNotifier {
  _Auth(super.authService) {
    state = const AuthState(status: AuthStatus.authenticated);
  }

  void set(AuthStatus status) => state = AuthState(status: status);
}

/// 只用来推状态：模拟「开始加载 → 加载完成」。
class _Tasks extends TaskNotifier {
  void emit(TaskListState next) => state = next;

  Future<void> finishLoad(List<Task> tasks, {String keyword = ''}) async {
    state = state.copyWith(loading: true, keyword: keyword);
    state = state.copyWith(tasks: tasks, total: tasks.length, loading: false);
  }
}

class _Dashboard extends DashboardNotifier {
  _Dashboard({super.dio});

  void finishLoad(Map<String, dynamic> dashboard) {
    state = state.copyWith(loading: true);
    state = state.copyWith(dashboard: dashboard, loading: false);
  }
}

Task _task(int id, String name, {double status = 1, DateTime? next}) {
  return Task.fromJson({
    'id': id,
    'name': name,
    'status': status,
    'next_run_at': next?.toIso8601String(),
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakePlatform platform;
  late ProviderContainer container;
  late IntegrationService service;
  final start = DateTime(2026, 11, 25, 12);
  // 可变：常驻通知「划掉」判断要看距上次发出过了多久
  var now = start;

  /// 跑完挂起的微任务（unawaited 的平台调用、补读 prefs）。
  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> setUpService({
    bool android = true,
    bool shortcuts = true,
    Future<List<RunningTask>?> Function()? fetchRunning,
    Future<List<Task>> Function()? fetchRunningTaskList,
    Dio? dashboardDio,
  }) async {
    platform = _FakePlatform();
    container = ProviderContainer(
      overrides: [
        authProvider.overrideWith((ref) => _Auth(AuthService())),
        taskProvider.overrideWith((ref) => _Tasks()),
        dashboardProvider.overrideWith((ref) => _Dashboard(dio: dashboardDio)),
      ],
    );
    service = IntegrationService(
      container: container,
      platform: platform,
      shortcutsSupported: shortcuts,
      androidOnlySupported: android,
      fetchRunningTasks: fetchRunning ?? () async => const [],
      fetchRunningTaskList: fetchRunningTaskList ?? () async => const [],
      now: () => now,
    );
    await service.start();
    await settle();
  }

  setUp(() {
    now = start;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    RunningNotificationSetting.resetForTest();
  });

  tearDown(() {
    service.dispose();
    container.dispose();
    RunningNotificationSetting.resetForTest();
  });

  _Tasks tasks() => container.read(taskProvider.notifier) as _Tasks;

  group('快捷方式', () {
    test('任务列表还没成功拉过：不动系统里的快捷方式', () async {
      await setUpService();
      expect(platform.shortcutSets, isEmpty);
    });

    test('列表拉到后写入；常用任务第一个带上「运行 {名称}」；内容不变不重复写', () async {
      await setUpService();
      // 先等常用任务的补读回来，再操作，避免补读把 toggle 的结果盖掉
      container.read(favoriteTasksProvider);
      await settle();
      container.read(favoriteTasksProvider.notifier).toggle(2);
      await settle();
      await tasks().finishLoad([_task(1, '签到'), _task(2, '备份')]);
      await settle();
      expect(platform.shortcutSets, hasLength(1));
      final items = platform.shortcutSets.last;
      expect(items.map((e) => e.type), [
        kShortcutNewTask,
        kShortcutSearchTask,
        'run_task:2',
      ]);
      expect(items.last.localizedTitle, '运行 备份');

      // 同样的数据再拉一次：签名一样，不再调平台
      await tasks().finishLoad([_task(1, '签到'), _task(2, '备份')]);
      await settle();
      expect(platform.shortcutSets, hasLength(1));
    });

    test('点快捷方式：没进主界面前先挂起（冷启动）', () async {
      await setUpService();
      platform.shortcutHandler!('run_task:7');
      final pending = service.pendingAction!;
      expect(pending.taskId, 7);
      expect(pending.focusRun, isTrue);
    });

    test('平台不支持快捷方式：不初始化', () async {
      await setUpService(shortcuts: false);
      expect(platform.shortcutHandler, isNull);
      await tasks().finishLoad([_task(1, '签到')]);
      await settle();
      expect(platform.shortcutSets, isEmpty);
    });
  });

  group('桌面小组件', () {
    test('不带筛选的任务列表加载完：写下一个 / 最近失败并通知重绘', () async {
      await setUpService();
      await tasks().finishLoad([
        _task(1, '签到', next: now.add(const Duration(minutes: 30))),
      ]);
      await settle();
      expect(platform.widgetWrites, hasLength(1));
      final data = platform.widgetWrites.single;
      expect(data[WidgetKeys.nextName], '签到');
      expect(data[WidgetKeys.updatedAt], now.millisecondsSinceEpoch.toString());
      expect(platform.widgetUpdates, 1);
    });

    test('带关键字筛选的列表只是一部分：不写小组件', () async {
      await setUpService();
      await tasks().finishLoad([_task(1, '签到')], keyword: '签');
      await settle();
      expect(platform.widgetWrites, isEmpty);
    });

    test('概览加载完：写今日成功 / 失败次数和日期', () async {
      await setUpService();
      (container.read(dashboardProvider.notifier) as _Dashboard).finishLoad({
        'success_logs': 24,
        'failed_logs': 1,
      });
      await settle();
      final data = platform.widgetWrites.single;
      expect(data[WidgetKeys.todaySuccess], '24');
      expect(data[WidgetKeys.todayFailed], '1');
      expect(data[WidgetKeys.todayDate], '2026-11-25');
    });

    test('开屏 / 登录的轻量预加载（只拉 /system/dashboard）：今日快照照常写入', () async {
      final adapter = FakeHttpAdapter((options) {
        if (options.path == '/api/system/dashboard') {
          return jsonResponse({
            'data': {'success_logs': 7, 'failed_logs': 2},
          });
        }
        return jsonResponse({}, status: 404);
      });
      await setUpService(dashboardDio: dioWithAdapter(adapter));
      await container.read(dashboardProvider.notifier).load(full: false);
      await settle();
      expect(adapter.requests.map((r) => r.path), ['/api/system/dashboard']);
      final data = platform.widgetWrites.single;
      expect(data[WidgetKeys.todaySuccess], '7');
      expect(data[WidgetKeys.todayFailed], '2');
      expect(data[WidgetKeys.todayDate], '2026-11-25');
    });

    test('点小组件：入口挂起等主界面', () async {
      await setUpService();
      platform.clicks.add(Uri.parse('daidai://task/3'));
      await settle();
      expect(service.pendingAction!.taskId, 3);
      expect(service.pendingAction!.focusRun, isFalse);
    });

    test('冷启动由小组件拉起：读初始 URI', () async {
      platform = _FakePlatform();
      // setUpService 会新建 platform，这里单独组装
      container = ProviderContainer(
        overrides: [
          authProvider.overrideWith((ref) => _Auth(AuthService())),
          taskProvider.overrideWith((ref) => _Tasks()),
          dashboardProvider.overrideWith((ref) => _Dashboard()),
        ],
      );
      platform.initialUri = Uri.parse('daidai://overview');
      service = IntegrationService(
        container: container,
        platform: platform,
        shortcutsSupported: true,
        androidOnlySupported: true,
        fetchRunningTasks: () async => const [],
        now: () => now,
      );
      await service.start();
      expect(service.pendingAction!.route, '/overview');
    });

    test('退出登录：删掉快照里的全部键并重绘（桌面显示占位），连着两个信号只清一次', () async {
      await setUpService();
      await tasks().finishLoad([
        _task(1, '签到', next: now.add(const Duration(hours: 1))),
      ]);
      await settle();
      final writesBefore = platform.widgetWrites.length;
      final updatesBefore = platform.widgetUpdates;

      (container.read(authProvider.notifier) as _Auth).set(
        AuthStatus.unauthenticated,
      );
      // 退出登录流程随后还会作废任务列表 provider
      container.invalidate(taskProvider);
      await settle();

      expect(platform.widgetWrites.length, writesBefore + 1, reason: '只清一次');
      final cleared = platform.widgetWrites.last;
      expect(cleared.keys.toSet(), WidgetKeys.all.toSet());
      expect(cleared.values.every((v) => v == null), isTrue);
      expect(platform.widgetUpdates, updatesBefore + 1);
    });

    test('切换面板（任务列表 provider 被作废重建、登录态不变）：也清快照；新面板加载完照常写入', () async {
      await setUpService();
      final next = now.add(const Duration(hours: 1));
      await tasks().finishLoad([_task(1, '签到', next: next)]);
      await settle();
      final writesBefore = platform.widgetWrites.length;

      container.invalidate(taskProvider);
      await settle();
      expect(platform.widgetWrites.length, writesBefore + 1);
      expect(platform.widgetWrites.last[WidgetKeys.nextName], isNull);
      expect(
        platform.widgetWrites.last.containsKey(WidgetKeys.nextName),
        isTrue,
      );

      // 新面板恰好也有一个同名同时间的任务：清过之后不能因为「内容没变」跳过写入
      await tasks().finishLoad([_task(1, '签到', next: next)]);
      await settle();
      expect(platform.widgetWrites.last[WidgetKeys.nextName], '签到');
    });

    test('非安卓：退出登录不碰小组件', () async {
      await setUpService(android: false);
      (container.read(authProvider.notifier) as _Auth).set(
        AuthStatus.unauthenticated,
      );
      await settle();
      expect(platform.widgetWrites, isEmpty);
      expect(platform.widgetUpdates, 0);
    });

    test('非安卓：不写小组件', () async {
      await setUpService(android: false);
      await tasks().finishLoad([
        _task(1, '签到', next: now.add(const Duration(minutes: 30))),
      ]);
      await settle();
      expect(platform.widgetWrites, isEmpty);
    });
  });

  group('常驻通知', () {
    Future<void> enable() async {
      RunningNotificationSetting.supportedOverride = true;
      RunningNotificationSetting.requestPermissionOverride = () async => true;
      await container
          .read(runningNotificationEnabledProvider.notifier)
          .setEnabled(true);
      await settle();
    }

    test('默认关：不轮询', () async {
      await setUpService();
      expect(service.isPolling, isFalse);
    });

    test('打开后立刻拉一次：有任务在跑就显示「N 个任务运行中」', () async {
      await setUpService(
        fetchRunning: () async => const [
          RunningTask(taskId: 1, name: '签到'),
          RunningTask(taskId: 2, name: '备份'),
        ],
      );
      await enable();
      expect(service.isPolling, isTrue);
      expect(platform.shown.single, ('2 个任务运行中', '签到、备份'));
    });

    test('全部结束：取消通知', () async {
      var running = <RunningTask>[const RunningTask(taskId: 1, name: '签到')];
      await setUpService(fetchRunning: () async => running);
      await enable();
      expect(platform.shown, hasLength(1));
      running = [];
      await service.pollRunning();
      expect(platform.cancels, 1);
      // 已经取消过，再空一次不重复取消
      await service.pollRunning();
      expect(platform.cancels, 1);
    });

    test('老面板（running 接口返回 null）：改用任务列表里运行中的任务', () async {
      await setUpService(
        fetchRunning: () async => null,
        fetchRunningTaskList: () async => [_task(5, '老面板任务', status: 2)],
      );
      await enable();
      expect(platform.shown.single, ('1 个任务运行中', '老面板任务'));
    });

    test('网络错误：保留上一条，不取消', () async {
      var fail = false;
      await setUpService(
        fetchRunning: () async {
          if (fail) throw Exception('offline');
          return const [RunningTask(taskId: 1, name: '签到')];
        },
      );
      await enable();
      fail = true;
      await service.pollRunning();
      expect(platform.cancels, 0);
      expect(platform.shown, hasLength(1));
    });

    test('关掉开关 / 退出登录：停止轮询并取消通知', () async {
      await setUpService(
        fetchRunning: () async => const [RunningTask(taskId: 1, name: '签到')],
      );
      await enable();
      expect(service.isPolling, isTrue);
      (container.read(authProvider.notifier) as _Auth).set(
        AuthStatus.unauthenticated,
      );
      await settle();
      expect(service.isPolling, isFalse);
      expect(platform.cancels, 1);
    });

    test('用户划掉后，运行中的任务集合不变：不再重发', () async {
      await setUpService(
        fetchRunning: () async => const [
          RunningTask(taskId: 1, name: '签到'),
          RunningTask(taskId: 2, name: '备份'),
        ],
      );
      await enable();
      expect(platform.shown, hasLength(1));

      platform.runningActive = false; // 用户划掉了
      now = now.add(IntegrationService.pollInterval);
      await service.pollRunning();
      now = now.add(IntegrationService.pollInterval);
      await service.pollRunning();
      expect(platform.shown, hasLength(1), reason: '集合没变，尊重用户的划掉');
      expect(platform.cancels, 0);
    });

    test('用户划掉后，有新任务开始（集合变了）：重新显示', () async {
      var running = <RunningTask>[const RunningTask(taskId: 1, name: '签到')];
      await setUpService(fetchRunning: () async => running);
      await enable();
      expect(platform.shown, hasLength(1));

      platform.runningActive = false;
      now = now.add(IntegrationService.pollInterval);
      await service.pollRunning();
      expect(platform.shown, hasLength(1));

      running = [
        const RunningTask(taskId: 1, name: '签到'),
        const RunningTask(taskId: 3, name: '新任务'),
      ];
      now = now.add(IntegrationService.pollInterval);
      await service.pollRunning();
      expect(platform.shown, hasLength(2));
      expect(platform.shown.last, ('2 个任务运行中', '签到、新任务'));

      // 重新显示后照常每轮重发（通知栏里又有了）
      platform.runningActive = true;
      now = now.add(IntegrationService.pollInterval);
      await service.pollRunning();
      expect(platform.shown, hasLength(3));
    });

    test('用户划掉后全部结束：清掉标记，同一批任务再跑时照常显示', () async {
      var running = <RunningTask>[const RunningTask(taskId: 1, name: '签到')];
      await setUpService(fetchRunning: () async => running);
      await enable();

      platform.runningActive = false;
      now = now.add(IntegrationService.pollInterval);
      await service.pollRunning();
      expect(platform.shown, hasLength(1));

      running = [];
      now = now.add(IntegrationService.pollInterval);
      await service.pollRunning();
      expect(platform.cancels, 0, reason: '通知已经被划掉了，不用再取消');

      running = [const RunningTask(taskId: 1, name: '签到')];
      platform.runningActive = true;
      now = now.add(IntegrationService.pollInterval);
      await service.pollRunning();
      expect(platform.shown, hasLength(2));
    });

    test('距上次发出已超过自动消失时间（进程被冻结过）：不算划掉，照常重发', () async {
      await setUpService(
        fetchRunning: () async => const [RunningTask(taskId: 1, name: '签到')],
      );
      await enable();

      platform.runningActive = false; // 超时自己消失了
      now = now.add(const Duration(minutes: 3));
      await service.pollRunning();
      expect(platform.shown, hasLength(2));
    });

    test('查不了通知栏（返回 null）：按没划掉处理，照常重发', () async {
      await setUpService(
        fetchRunning: () async => const [RunningTask(taskId: 1, name: '签到')],
      );
      await enable();

      platform.runningActive = null;
      now = now.add(IntegrationService.pollInterval);
      await service.pollRunning();
      expect(platform.shown, hasLength(2));
    });

    test('非安卓：开关打不开，也不轮询', () async {
      RunningNotificationSetting.supportedOverride = false;
      await setUpService(android: false);
      await container
          .read(runningNotificationEnabledProvider.notifier)
          .setEnabled(true);
      await settle();
      expect(service.isPolling, isFalse);
      expect(platform.shown, isEmpty);
    });
  });
}
