import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/overview/providers/dashboard_provider.dart';
import '../../features/tasks/providers/favorite_tasks_provider.dart';
import '../../features/tasks/providers/task_provider.dart';
import '../../features/tasks/widgets/task_detail_sheet.dart';
import '../../shared/api/panel_insights.dart';
import '../../shared/api/task_lookup.dart';
import '../../shared/models/insights.dart';
import '../../shared/models/task.dart';
import '../../shared/utils/api_utils.dart';
import '../auth/auth_provider.dart';
import '../network/api_endpoints.dart';
import '../network/dio_client.dart';
import '../router/app_router.dart';
import 'integration_data.dart';
import 'integration_platform.dart';
import 'integration_settings.dart';

/// 系统集成（design §6）：快捷方式、安卓桌面小组件、安卓「任务运行中」常驻通知。
///
/// `main.dart` 在 `runApp` 之后调一次 [IntegrationService.init]，之后它自己监听
/// 任务列表 / 概览 / 常用任务 / 登录态 / 常驻通知开关，其他页面**不需要**主动调用。
///
/// 三件事都只在 APP 进程活着时工作：小组件只读 APP 写下的快照、不在后台联网；
/// 常驻通知不是前台服务，进程没了它会因 `timeoutAfter` 自己消失。
class IntegrationService {
  IntegrationService({
    required ProviderContainer container,
    IntegrationPlatform platform = const IntegrationPlatform(),
    bool? shortcutsSupported,
    bool? androidOnlySupported,
    Future<List<RunningTask>?> Function()? fetchRunningTasks,
    Future<List<Task>> Function()? fetchRunningTaskList,
    DateTime Function()? now,
  }) : _container = container,
       _platform = platform,
       _shortcutsSupported = shortcutsSupported ?? isQuickActionsPlatform,
       _android = androidOnlySupported ?? isRunningNotificationPlatform,
       _fetchRunning = fetchRunningTasks ?? fetchRunning,
       _fetchRunningTaskList = fetchRunningTaskList ?? _defaultRunningTaskList,
       _now = now ?? DateTime.now;

  static IntegrationService? _instance;

  /// 当前实例（`init` 之前、web 上为 null）。
  static IntegrationService? get instance => _instance;

  /// 启动系统集成。只调一次；web 上什么都不做。
  ///
  /// `main.dart` 不要 await 它的平台调用卡住首帧：监听在同步阶段就挂好了，
  /// 插件初始化各自 try/catch，任何一个失败都不影响 APP 本身。
  static Future<void> init(ProviderContainer container) async {
    if (kIsWeb || _instance != null) return;
    final service = IntegrationService(container: container);
    _instance = service;
    await service.start();
  }

  /// 常驻通知轮询间隔。
  static const Duration pollInterval = Duration(seconds: 30);

  /// 数据没变时，小组件的「更新于」最多隔这么久刷新一次。
  static const Duration _widgetHeartbeat = Duration(minutes: 5);

  final ProviderContainer _container;
  final IntegrationPlatform _platform;
  final bool _shortcutsSupported;
  final bool _android;
  final Future<List<RunningTask>?> Function() _fetchRunning;
  final Future<List<Task>> Function() _fetchRunningTaskList;
  final DateTime Function() _now;

  final List<ProviderSubscription<Object?>> _subscriptions = [];
  StreamSubscription<Uri?>? _widgetClickSub;
  AppLifecycleListener? _lifecycle;
  GoRouter? _router;

  /// [IntegrationHost] 挂上来的 ref：`showTaskDetailSheet` 需要一个 WidgetRef。
  WidgetRef? _hostRef;

  /// 冷启动时还没进主界面，入口先记在这里，落到主界面后再执行。只保留最新一个。
  LaunchAction? _pending;

  /// 任务 id → 名称。快捷方式「运行 {常用任务 1}」靠它拿名字；
  /// 列表带筛选时只追加不清空，免得常用任务被筛掉后快捷方式跟着消失。
  final Map<int, String> _taskNames = {};
  bool _taskNamesReady = false;
  String? _shortcutSig;

  final Map<String, String?> _widgetData = {};
  DateTime? _widgetWrittenAt;

  /// 小组件快照已经清成占位：退出登录会先后来两个信号（登录态变了 + 任务列表作废），只清一次。
  bool _widgetCleared = false;

  /// 当前的任务列表 notifier。换了实例说明 provider 被 `invalidateServerScopedProviders`
  /// 作废重建了（切换面板 / 退出登录）。
  TaskNotifier? _taskNotifier;

  Timer? _pollTimer;
  bool _polling = false;
  bool _notificationShown = false;

  /// 上一次发出常驻通知时的运行中任务 id 集合、发出时间：用来判断通知是不是被用户划掉了。
  Set<int> _shownIds = const {};
  DateTime? _shownAt;

  /// 用户划掉通知那一刻的任务 id 集合（安卓 14 起 ongoing 通知能划掉）。
  /// 运行中的集合不变就不再重发；集合变了、或全部结束时清掉。
  Set<int>? _dismissedIds;

  /// 发出后多久之内「不在通知栏里」才算用户划掉：比自动消失时间（75 秒）短一截。
  /// 超过它的（进程被系统冻结过、没按时重发）是超时自己没的，不算划掉，照常重发。
  static const Duration _dismissCheckWindow = Duration(
    milliseconds: IntegrationPlatform.runningTimeoutMs - 5000,
  );

  /// 测试用：当前待执行的入口。
  @visibleForTesting
  LaunchAction? get pendingAction => _pending;

  /// 测试用：常驻通知轮询是否在跑。
  @visibleForTesting
  bool get isPolling => _pollTimer != null;

  /// 挂监听 + 初始化插件。
  Future<void> start() async {
    // 监听都在第一个 await 之前挂好：init 不被 await 时也不会漏掉首批数据。
    _subscriptions.add(
      _container.listen<TaskListState>(taskProvider, _onTasks),
    );
    _subscriptions.add(
      _container.listen<List<int>>(
        favoriteTasksProvider,
        (_, _) => _refreshShortcuts(),
      ),
    );
    _subscriptions.add(
      _container.listen<DashboardData>(dashboardProvider, _onDashboard),
    );
    _subscriptions.add(
      _container.listen<AuthStatus>(authProvider.select((s) => s.status), (
        _,
        status,
      ) {
        // 退出登录 / 登录失效：小组件不能还挂着这台面板的任务名
        if (status == AuthStatus.unauthenticated) {
          unawaited(clearWidgetData());
        }
        _syncPolling();
        _tryFlush();
      }),
    );
    _subscriptions.add(
      _container.listen<bool>(
        runningNotificationEnabledProvider,
        (_, _) => _syncPolling(),
      ),
    );
    try {
      _router = _container.read(routerProvider);
      _router!.routerDelegate.addListener(_tryFlush);
    } catch (_) {
      // 测试里可能没有路由，入口就一直挂着，不影响其他功能
    }
    _taskNotifier = _container.read(taskProvider.notifier);
    _lifecycle = AppLifecycleListener(onResume: _onResume);

    if (_shortcutsSupported) {
      try {
        await _platform.initShortcuts(_onShortcut);
      } catch (e) {
        debugPrint('quick_actions init failed: $e');
      }
    }
    if (_android) {
      try {
        final uri = await _platform.initialWidgetUri();
        if (uri != null) _onWidgetUri(uri);
        _widgetClickSub = _platform.widgetClicks.listen((uri) {
          if (uri != null) _onWidgetUri(uri);
        });
      } catch (e) {
        debugPrint('home_widget init failed: $e');
      }
      try {
        await _platform.initNotifications(
          () => _enqueue(const LaunchAction(route: '/tasks')),
        );
      } catch (e) {
        debugPrint('notifications init failed: $e');
      }
    }
    _syncPolling();
  }

  /// 测试用：拆掉监听与定时器。
  @visibleForTesting
  void dispose() {
    for (final sub in _subscriptions) {
      sub.close();
    }
    _subscriptions.clear();
    _widgetClickSub?.cancel();
    _lifecycle?.dispose();
    _router?.routerDelegate.removeListener(_tryFlush);
    _pollTimer?.cancel();
    _pollTimer = null;
    if (identical(_instance, this)) _instance = null;
  }

  // ── 启动入口（快捷方式 / 小组件 / 通知点按） ───────────────────────────

  void _onShortcut(String type) {
    final action = launchActionFromShortcut(
      type,
      nonce: _now().millisecondsSinceEpoch,
    );
    if (action != null) _enqueue(action);
  }

  void _onWidgetUri(Uri uri) {
    final action = launchActionFromWidgetUri(uri);
    if (action != null) _enqueue(action);
  }

  void _enqueue(LaunchAction action) {
    _pending = action;
    _tryFlush();
  }

  /// 登录态已确认、路由已经离开开屏 / 登录页时执行待处理的入口。
  void _tryFlush() {
    final action = _pending;
    final router = _router;
    if (action == null || router == null) return;
    if (_container.read(authProvider).status != AuthStatus.authenticated) {
      return;
    }
    final config = router.routerDelegate.currentConfiguration;
    if (config.isEmpty || !isLaunchReadyLocation(config.uri.path)) return;
    _pending = null;
    // 放到帧后执行：_tryFlush 可能正处在路由的通知回调里，当场再导航会重入
    WidgetsBinding.instance.addPostFrameCallback((_) => _run(router, action));
    WidgetsBinding.instance.scheduleFrame();
  }

  Future<void> _run(GoRouter router, LaunchAction action) async {
    final taskId = action.taskId;
    if (taskId == null) {
      if (action.push) {
        router.push(action.route);
      } else {
        router.go(action.route);
      }
      return;
    }
    router.go(action.route);
    final task = await _findTask(taskId);
    // 任务被删了 / 取不到：就停在任务页，不弹错
    if (task == null) return;
    await WidgetsBinding.instance.endOfFrame;
    final context = router.routerDelegate.navigatorKey.currentContext;
    final ref = _hostRef;
    if (context == null || ref == null || !context.mounted) return;
    await showTaskDetailSheet(context, ref, task, focusRun: action.focusRun);
  }

  Future<Task?> _findTask(int id) async {
    for (final task in _container.read(taskProvider).tasks) {
      if (task.id == id) return task;
    }
    // 冷启动从小组件 / 快捷方式进来时任务列表还没拉回来：去面板上按 id 找
    //（面板没有 GET /tasks/:id，原来请求它永远 404，详情弹层一次都弹不出来）。
    try {
      return await fetchTaskById(id);
    } catch (_) {
      // 网络错误按取不到处理
      return null;
    }
  }

  // ── 任务列表 → 快捷方式 + 小组件 ─────────────────────────────────────

  void _onTasks(TaskListState? prev, TaskListState next) {
    // 任务列表 provider 换了实例 = 切换面板 / 退出登录：先把小组件清成占位，
    // 等新面板的列表 / 概览加载完再照常写入。
    final notifier = _container.read(taskProvider.notifier);
    if (!identical(notifier, _taskNotifier)) {
      _taskNotifier = notifier;
      unawaited(clearWidgetData());
    }
    final finished =
        prev != null && prev.loading && !next.loading && next.error == null;
    if (!finished) {
      // 不是一次加载结束、列表却空了：provider 被作废重建（切面板 / 退出登录），
      // 上一台面板的名字不能再用。
      if (!next.loading && next.tasks.isEmpty) {
        _taskNames.clear();
        _taskNamesReady = false;
      }
      return;
    }
    final unfiltered =
        next.keyword.isEmpty &&
        next.statusFilter == null &&
        next.labelFilter == null &&
        next.filters.isEmpty;
    if (unfiltered) _taskNames.clear();
    for (final task in next.tasks) {
      _taskNames[task.id] = task.name;
    }
    _taskNamesReady = true;
    _refreshShortcuts();
    // 带筛选的列表只是一部分任务，算出来的「下一个 / 最近失败」不可信，不写小组件
    if (unfiltered && _android) {
      unawaited(syncWidgetData(widgetDataFromTasks(next.tasks, _now())));
    }
  }

  void _refreshShortcuts() {
    // 任务列表还没成功拉过：常用任务的名字未知，先不动系统里上次留下的快捷方式
    if (!_shortcutsSupported || !_taskNamesReady) return;
    final favorites = _container.read(favoriteTasksProvider);
    final firstId = favorites.isEmpty ? null : favorites.first;
    final name = firstId == null ? null : _taskNames[firstId];
    final items = buildShortcutItems(
      android: _android,
      favoriteId: name == null ? null : firstId,
      favoriteName: name,
    );
    final sig = shortcutSignature(items);
    if (sig == _shortcutSig) return;
    _shortcutSig = sig;
    _platform.setShortcuts(items).catchError((Object e) {
      // 写失败就清掉签名，下次数据变化时重试
      _shortcutSig = null;
      debugPrint('setShortcutItems failed: $e');
    });
  }

  void _onDashboard(DashboardData? prev, DashboardData next) {
    final finished =
        prev != null && prev.loading && !next.loading && next.error == null;
    if (!finished || !_android || next.dashboard.isEmpty) return;
    final today = _now();
    unawaited(
      syncWidgetData({
        ...widgetDataFromToday(
          success: next.todaySuccess,
          failed: next.todayFailed,
        ),
        // 跨天后小组件靠它判断「今日」数据已过期
        WidgetKeys.todayDate: _dateKey(today),
      }),
    );
  }

  /// 写小组件快照并通知重绘。内容没变且距上次写入不到 5 分钟时跳过。
  Future<void> syncWidgetData(Map<String, String?> data) async {
    if (!_android) return;
    final now = _now();
    final changed = data.entries.any((e) => _widgetData[e.key] != e.value);
    final stale =
        _widgetWrittenAt == null ||
        now.difference(_widgetWrittenAt!) >= _widgetHeartbeat;
    if (!changed && !stale) return;
    _widgetCleared = false;
    _widgetData.addAll(data);
    _widgetWrittenAt = now;
    try {
      await _platform.saveWidgetData({
        ...data,
        WidgetKeys.updatedAt: now.millisecondsSinceEpoch.toString(),
      });
      await _platform.updateWidget();
    } catch (e) {
      // 写失败：下次一定重写
      _widgetData.clear();
      _widgetWrittenAt = null;
      debugPrint('home_widget save failed: $e');
    }
  }

  /// 退出登录 / 切换面板：删掉小组件快照里的全部数据并重绘，桌面显示占位
  /// （成功率「--」、两行「暂无」、「打开 APP 获取数据」），不再显示上一台面板的任务名。
  @visibleForTesting
  Future<void> clearWidgetData() async {
    if (!_android || _widgetCleared) return;
    _widgetCleared = true;
    // 记下的「上次写了什么」一起清掉：新面板的数据哪怕和旧的一样也要重新写
    _widgetData.clear();
    _widgetWrittenAt = null;
    try {
      await _platform.saveWidgetData({
        for (final key in WidgetKeys.all) key: null,
      });
      await _platform.updateWidget();
    } catch (e) {
      // 没清成：下一个信号再试
      _widgetCleared = false;
      debugPrint('home_widget clear failed: $e');
    }
  }

  static String _dateKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // ── 常驻通知 ───────────────────────────────────────────────────────

  void _syncPolling() {
    final on =
        _android &&
        _container.read(runningNotificationEnabledProvider) &&
        _container.read(authProvider).status == AuthStatus.authenticated;
    if (on && _pollTimer == null) {
      _pollTimer = Timer.periodic(pollInterval, (_) => pollRunning());
      unawaited(pollRunning());
    } else if (!on && _pollTimer != null) {
      _pollTimer!.cancel();
      _pollTimer = null;
      unawaited(updateRunningNotification(const []));
    }
  }

  void _onResume() {
    // 从后台回来立刻刷一次，不用等下一个 30 秒
    if (_pollTimer != null) unawaited(pollRunning());
  }

  /// 拉一次「运行中」并更新通知。v4.0 面板走 `GET /tasks/running`；
  /// 老面板（返回 null）改用任务列表里状态为运行中的任务。
  @visibleForTesting
  Future<void> pollRunning() async {
    if (_polling) return;
    _polling = true;
    try {
      var running = await _fetchRunning();
      running ??= runningFromTasks(await _fetchRunningTaskList());
      // 拉取途中开关被关掉 / 退出登录：不要再把通知发出来
      if (_pollTimer == null) return;
      await updateRunningNotification(running);
    } catch (_) {
      // 网络 / 5xx：保留上一条通知，下一轮再试（超时兜底保证不会永远挂着）
    } finally {
      _polling = false;
    }
  }

  /// 有任务在跑：显示（每次都重发，刷新超时）；没有：取消。
  ///
  /// 用户划掉了通知（安卓 14+）：运行中的任务集合不变就不再重发；
  /// 有新任务开始 / 集合变了才重新显示；全部结束后清掉「已划掉」标记。
  Future<void> updateRunningNotification(List<RunningTask> running) async {
    if (!_android) return;
    try {
      if (running.isEmpty) {
        // 全部结束：下次有任务开始照常显示
        _dismissedIds = null;
        if (!_notificationShown) return;
        _notificationShown = false;
        await _platform.cancelRunning();
        return;
      }
      final ids = running.map((t) => t.taskId).toSet();
      // 上一轮发过、还没到自动消失的时候，现在却不在通知栏里了：是用户划掉的。
      // 查不了（返回 null）按没划掉处理。
      final shownAt = _shownAt;
      if (_notificationShown &&
          shownAt != null &&
          _now().difference(shownAt) < _dismissCheckWindow &&
          await _platform.isRunningShown() == false) {
        _notificationShown = false;
        _dismissedIds = _shownIds;
      }
      final dismissed = _dismissedIds;
      if (dismissed != null) {
        // 运行中的还是划掉时那几个任务：尊重用户，不再发
        if (setEquals(dismissed, ids)) return;
        _dismissedIds = null;
      }
      final text = runningNotificationText(running);
      _notificationShown = true;
      _shownIds = ids;
      _shownAt = _now();
      await _platform.showRunning(text.title, text.body);
    } catch (e) {
      debugPrint('running notification failed: $e');
    }
  }

  /// 老面板兜底：只取运行中的任务（`status=2`），一页足够，不全量拉任务列表。
  static Future<List<Task>> _defaultRunningTaskList() async {
    final response = await DioClient.instance.dio.get(
      ApiEndpoints.tasks,
      queryParameters: {'status': '2', 'page': 1, 'page_size': 100},
    );
    return extractPaginated(response.data).items.map(Task.fromJson).toList();
  }
}

/// 包在 `DaidaiApp` 外面，把一个 WidgetRef 交给 [IntegrationService]，
/// 用于快捷方式 / 小组件打开任务详情弹层（`showTaskDetailSheet` 的签名要 WidgetRef）。
class IntegrationHost extends ConsumerStatefulWidget {
  const IntegrationHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<IntegrationHost> createState() => _IntegrationHostState();
}

class _IntegrationHostState extends ConsumerState<IntegrationHost> {
  @override
  void initState() {
    super.initState();
    IntegrationService.instance?._hostRef = ref;
  }

  @override
  void dispose() {
    final service = IntegrationService.instance;
    if (service != null && identical(service._hostRef, ref)) {
      service._hostRef = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // init 在 runApp 之后才跑：首帧时 instance 可能还是 null，这里每次 build 补挂一次
    IntegrationService.instance?._hostRef ??= ref;
    return widget.child;
  }
}
