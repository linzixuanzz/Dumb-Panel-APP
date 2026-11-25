import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../auth/auth_provider.dart';
import '../theme/design_tokens.dart';
import 'default_landing_page.dart';
import '../../features/login/views/app_boot_page.dart';
import '../../features/login/views/login_page.dart';
import '../../features/server_config/views/server_config_page.dart';
import '../../features/overview/views/overview_page.dart';
import '../../features/tasks/views/task_list_page.dart';
import '../../features/tasks/views/task_form_page.dart';
import '../../features/tasks/views/task_detail_page.dart';
import '../../features/logs/views/log_list_page.dart';
import '../../features/logs/views/log_stream_page.dart';
import '../../features/envs/views/env_list_page.dart';
import '../../features/settings/views/about_page.dart';
import '../../features/settings/views/settings_page.dart';
import '../../features/settings/views/sponsor_page.dart';
import '../../features/subscriptions/views/subscription_list_page.dart';
import '../../features/scripts/views/script_list_page.dart';
import '../../features/notifications/views/notification_list_page.dart';
import '../../features/deps/views/dep_list_page.dart';
import '../../features/users/views/user_list_page.dart';
import '../../features/security/views/security_page.dart';
import '../../features/system/views/system_settings_page.dart';
import '../../features/system/views/panel_log_page.dart';
import '../../features/system/views/config_script_page.dart';
import '../../features/system/views/backup_page.dart';
import '../../features/openapi/views/open_api_page.dart';
import '../../features/app_lock/views/app_lock_settings_page.dart';
import '../../shared/widgets/main_scaffold.dart';
import '../../shared/models/task.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();
final _shellNavigatorKey = GlobalKey<NavigatorState>();

/// 底栏 5 个 Tab 的页面：切 Tab 时新页淡入并从 0.97 放大到 1（方案书 §2.5）。
/// 系统开了「移除动画」时直接切，不做过渡。
///
/// 公开出来是给测试里自建的路由表复用，保证测的就是线上这套过渡。
Page<void> tabPage(GoRouterState state, Widget child) {
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionDuration: AppMotion.normal,
    reverseTransitionDuration: Duration.zero,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      if (AppMotion.reduce(context)) return child;
      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOut);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.97, end: 1).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// 将 auth status 变化转为 Listenable，供 GoRouter.refreshListenable 使用
class _AuthNotifierBridge extends ChangeNotifier {
  _AuthNotifierBridge(Ref ref) {
    ref.listen<AuthStatus>(
      authProvider.select((s) => s.status),
      (previous, next) => notifyListeners(),
    );
  }
}

final _authNotifierProvider = Provider<_AuthNotifierBridge>((ref) {
  return _AuthNotifierBridge(ref);
});

final routerProvider = Provider<GoRouter>((ref) {
  final refreshNotifier = ref.watch(_authNotifierProvider);

  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/boot',
    refreshListenable: refreshNotifier,
    redirect: (context, state) {
      // 每次 redirect 时实时读取最新状态（不用 watch）
      final authState = ref.read(authProvider);
      final isAuth = authState.status == AuthStatus.authenticated;
      final isUnknown = authState.status == AuthStatus.unknown;
      final isBootRoute = state.matchedLocation == '/boot';
      final isLoginRoute = state.matchedLocation == '/login';
      final isServerConfig = state.matchedLocation == '/server-config';
      final manualServerConfig = state.uri.queryParameters['manual'] == '1';
      final manageServerConfig = state.uri.queryParameters['manage'] == '1';

      if (isBootRoute) {
        return null;
      }
      if (isUnknown) {
        return '/boot';
      }
      if (isServerConfig) {
        if (isAuth && !manualServerConfig && !manageServerConfig) {
          // 进入主界面的落点统一读「默认打开页面」（APP #24），没设过就是任务
          return DefaultLandingPage.route;
        }
        if (!isAuth &&
            !manualServerConfig &&
            !manageServerConfig &&
            authState.status == AuthStatus.unauthenticated) {
          return '/login';
        }
        return null;
      }
      if (!isAuth && !isLoginRoute) return '/login';
      if (isAuth && isLoginRoute) return DefaultLandingPage.route;
      return null;
    },
    routes: [
      GoRoute(path: '/boot', builder: (_, state) => const AppBootPage()),
      GoRoute(
        path: '/server-config',
        builder: (_, state) => ServerConfigPage(
          manageMode: state.uri.queryParameters['manage'] == '1',
        ),
      ),
      GoRoute(path: '/login', builder: (_, state) => const LoginPage()),
      // v2.0 底栏改成「任务 / 日志 / 概览 / 变量 / 设置」，旧的两个 Tab 路由保留成重定向：
      // 旧版本的深链、页面里还没改的 context.go('/dashboard' | '/more') 都不会落空。
      GoRoute(path: '/dashboard', redirect: (_, state) => '/overview'),
      GoRoute(path: '/more', redirect: (_, state) => '/settings'),
      ShellRoute(
        navigatorKey: _shellNavigatorKey,
        builder: (_, state, child) => MainScaffold(child: child),
        routes: [
          GoRoute(
            path: '/tasks',
            pageBuilder: (_, state) => tabPage(state, const TaskListPage()),
          ),
          GoRoute(
            path: '/logs',
            pageBuilder: (_, state) => tabPage(state, const LogListPage()),
          ),
          GoRoute(
            path: '/overview',
            pageBuilder: (_, state) => tabPage(state, const OverviewPage()),
          ),
          GoRoute(
            path: '/envs',
            pageBuilder: (_, state) => tabPage(state, const EnvListPage()),
          ),
          GoRoute(
            path: '/settings',
            pageBuilder: (_, state) => tabPage(state, const SettingsPage()),
          ),
        ],
      ),
      GoRoute(
        path: '/tasks/new',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, state) => TaskFormPage(
          prefill: state.extra is TaskFormPrefill
              ? state.extra as TaskFormPrefill
              : null,
        ),
      ),
      GoRoute(
        path: '/tasks/edit',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, state) {
          final task = state.extra as Task?;
          return TaskFormPage(task: task);
        },
      ),
      // 任务详情（issue #20）：extra 传列表里那条 Task，先渲染再跟着列表 provider 刷新。
      // v2.0 起列表点任务直接弹 showTaskDetailSheet，这条路由保留给深链与旧调用。
      GoRoute(
        path: '/tasks/:id/detail',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, state) => TaskDetailPage(
          taskId: int.parse(state.pathParameters['id']!),
          initialTask: state.extra is Task ? state.extra as Task : null,
        ),
      ),
      // 详情页「日志历史」：单任务日志列表。给它一份独立的 logListProvider，
      // 免得把底部「日志」标签页的筛选条件改成只看这一个任务
      GoRoute(
        path: '/tasks/:id/logs',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, state) => ProviderScope(
          overrides: [logListProvider.overrideWith((ref) => LogListNotifier())],
          child: LogListPage(
            taskId: int.parse(state.pathParameters['id']!),
            taskName: state.extra as String?,
          ),
        ),
      ),
      GoRoute(
        path: '/tasks/:id/live-logs',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, state) => TaskLiveLogPage(
          taskId: int.parse(state.pathParameters['id']!),
          taskName: state.extra as String?,
        ),
      ),
      GoRoute(
        path: '/logs/:id/stream',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, state) =>
            LogStreamPage(logId: int.parse(state.pathParameters['id']!)),
      ),
      // Phase 2 routes
      GoRoute(
        path: '/subscriptions',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, state) => const SubscriptionListPage(),
      ),
      GoRoute(
        path: '/subscriptions/:id/pull-stream',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, state) => SubscriptionPullStreamPage(
          subscriptionId: int.parse(state.pathParameters['id']!),
        ),
      ),
      GoRoute(
        path: '/subscriptions/:id/logs',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, state) => SubscriptionLogsPage(
          subscriptionId: int.parse(state.pathParameters['id']!),
          subscriptionName: state.extra as String?,
        ),
      ),
      GoRoute(
        path: '/scripts',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, state) => const ScriptListPage(),
      ),
      GoRoute(
        path: '/scripts/view',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, state) {
          final path = state.extra as String? ?? '';
          return ScriptViewPage(path: path);
        },
      ),
      GoRoute(
        path: '/notifications',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, state) => const NotificationListPage(),
      ),
      GoRoute(
        path: '/deps',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, state) => const DepListPage(),
      ),
      GoRoute(
        path: '/deps/:id/log-stream',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, state) =>
            DepLogStreamPage(depId: int.parse(state.pathParameters['id']!)),
      ),
      // Phase 3 routes
      GoRoute(
        path: '/users',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, state) => const UserListPage(),
      ),
      GoRoute(
        path: '/security',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, state) => const SecurityPage(),
      ),
      GoRoute(
        path: '/app-lock',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, state) => const AppLockSettingsPage(),
      ),
      GoRoute(
        path: '/system-settings',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, state) => const SystemSettingsPage(),
      ),
      GoRoute(
        path: '/panel-log',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, state) => const PanelLogPage(),
      ),
      // 配置文件 config.sh 编辑页（APP #22），入口在「更多」的管理员分区。
      GoRoute(
        path: '/config-script',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, state) => const ConfigScriptPage(),
      ),
      GoRoute(
        path: '/backup',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, state) => const BackupPage(),
      ),
      GoRoute(
        path: '/open-api',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, state) => const OpenApiPage(),
      ),
      GoRoute(
        path: '/sponsors',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, state) => const SponsorPage(),
      ),
      // 关于页（issue #12 / v1.3.7）。受上面 83 行的登录门禁约束，只有登录后能进；
      // 入口就在设置页，所以没影响——以后若想在登录页放「关于」，得先改那行判断。
      GoRoute(
        path: '/about',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, state) => const AboutPage(),
      ),
      GoRoute(
        path: '/open-api/:id/logs',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, state) =>
            OpenApiLogsPage(appId: int.parse(state.pathParameters['id']!)),
      ),
    ],
  );
});
