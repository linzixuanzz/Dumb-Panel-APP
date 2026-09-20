import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/dashboard/providers/dashboard_provider.dart';
import '../../features/deps/views/dep_list_page.dart';
import '../../features/envs/views/env_list_page.dart';
import '../../features/logs/views/log_list_page.dart';
import '../../features/notifications/views/notification_list_page.dart';
import '../../features/scripts/views/script_list_page.dart';
import '../../features/subscriptions/views/subscription_list_page.dart';
import '../../features/tasks/providers/task_provider.dart';
import '../../features/tasks/providers/task_view_provider.dart';
import '../../features/users/views/user_list_page.dart';

/// 把「装着上一台面板数据」的 provider 全部作废（issue #13，v1.3.7）。
///
/// 为什么必须有这一步：下面这些 provider **都不是 autoDispose**，也就是说页面退出后
/// 状态还留在容器里。v1.3.6 之前切面板会先清凭据、踢回登录页，脏数据被登录流程顺带冲掉了；
/// v1.3.7 起切面板直接进首页，不失效的话首页/任务/日志里躺的仍然是 A 的列表，
/// 用户可能对着 A 的任务点「运行」，请求却打到了 B。
///
/// 切换面板（`server_config_page._switchToPanel`）和退出登录（`more_page._logout`）
/// **共用这一个函数**：写成两份的话，以后新增一个服务器级 provider 只会被加进其中一份，
/// 另一份静默漂移。
///
/// 放在 `core/` 而不是某个 feature 里，是因为它天然要引用全部 feature 的 provider；
/// 同样理由的先例是 `core/router/app_router.dart`（它 import 了 22 个 feature 页面）。
/// 不含设备级的 `appLockProvider` 和核心的 `authProvider` / `routerProvider`。
void invalidateServerScopedProviders(WidgetRef ref) {
  ref.invalidate(dashboardProvider);
  ref.invalidate(taskProvider);
  ref.invalidate(taskViewProvider);
  ref.invalidate(envListProvider);
  ref.invalidate(logListProvider);
  ref.invalidate(scriptProvider);
  ref.invalidate(depListProvider);
  ref.invalidate(subscriptionListProvider);
  ref.invalidate(notificationListProvider);
  ref.invalidate(userListProvider);
}
