import 'package:quick_actions/quick_actions.dart';

import '../../shared/models/insights.dart';
import '../../shared/models/task.dart';

// 系统集成（快捷方式 / 桌面小组件 / 常驻通知）里「不碰平台」的那部分：
// 解析启动入口、拼快捷方式、算小组件快照、拼通知文案。都是纯函数，方便单测。

// ── 启动入口 ───────────────────────────────────────────────────────────

/// 快捷方式的 type（安卓 ShortcutInfo id / iOS UIApplicationShortcutItem type）。
const String kShortcutNewTask = 'new_task';
const String kShortcutSearchTask = 'search_task';

/// 「运行 {常用任务 1}」：type 带上任务 id，例如 `run_task:12`。
const String kShortcutRunTaskPrefix = 'run_task:';

/// 小组件点按用的启动 URI，scheme 固定 `daidai`：
/// - `daidai://tasks`    → 任务页
/// - `daidai://overview` → 概览页
/// - `daidai://task/12`  → 任务页并打开 12 号任务的详情弹层
const String kWidgetUriScheme = 'daidai';

/// 一次「从系统入口拉起 APP」要做的事。
class LaunchAction {
  /// 要去的路由；[taskId] 不为 null 时先回到 `/tasks` 再弹详情。
  final String route;

  /// true：在当前页面之上 push（新建任务页），false：go 到 Tab。
  final bool push;

  /// 要打开详情弹层的任务。
  final int? taskId;

  /// 打开详情弹层后高亮「按住运行」（快捷方式「运行常用任务」用）。不会直接运行。
  final bool focusRun;

  const LaunchAction({
    required this.route,
    this.push = false,
    this.taskId,
    this.focusRun = false,
  });

  @override
  String toString() =>
      'LaunchAction($route, push: $push, taskId: $taskId, focusRun: $focusRun)';
}

/// 「搜索任务」跳转的路由：`/tasks?search=<随机值>`。
///
/// 与 B1 的约定：任务页读到 query 里有 `search`（任意非空值）就聚焦搜索框；
/// 值每次都不一样（取当前毫秒数），所以已经停在 `/tasks?search=…` 时再点一次快捷方式也算一次新请求，
/// 任务页按「值变了才处理」去重即可。
String taskSearchRoute(int nonce) => '/tasks?search=$nonce';

/// 解析快捷方式 type；不认识的返回 null（例如旧版本留下的快捷方式）。
LaunchAction? launchActionFromShortcut(String type, {required int nonce}) {
  if (type == kShortcutNewTask) {
    return const LaunchAction(route: '/tasks/new', push: true);
  }
  if (type == kShortcutSearchTask) {
    return LaunchAction(route: taskSearchRoute(nonce));
  }
  if (type.startsWith(kShortcutRunTaskPrefix)) {
    final id = int.tryParse(type.substring(kShortcutRunTaskPrefix.length));
    if (id == null) return null;
    return LaunchAction(route: '/tasks', taskId: id, focusRun: true);
  }
  return null;
}

/// 解析小组件的启动 URI；不认识的返回 null（照常停在默认打开页面）。
LaunchAction? launchActionFromWidgetUri(Uri uri) {
  if (uri.scheme != kWidgetUriScheme) return null;
  switch (uri.host) {
    case 'tasks':
      return const LaunchAction(route: '/tasks');
    case 'overview':
      return const LaunchAction(route: '/overview');
    case 'task':
      final id = uri.pathSegments.isEmpty
          ? null
          : int.tryParse(uri.pathSegments.first);
      if (id == null) return const LaunchAction(route: '/tasks');
      return LaunchAction(route: '/tasks', taskId: id);
  }
  return null;
}

/// 这些路由上还不能处理启动入口：开屏还在恢复登录、或者停在登录 / 选服务器页。
/// 冷启动时先把入口记下，等落到主界面再执行。
bool isLaunchReadyLocation(String path) {
  return path != '/boot' && path != '/login' && path != '/server-config';
}

// ── 快捷方式 ───────────────────────────────────────────────────────────

/// 长按图标的菜单：新建任务、搜索任务，有常用任务时再加「运行 {常用任务 1}」。
///
/// 图标只给安卓（`res/drawable/ic_shortcut_*.xml`）；iOS 的图标要放进 asset catalog，
/// 本期不动 Xcode 工程，传 null 显示纯文字。
List<ShortcutItem> buildShortcutItems({
  required bool android,
  int? favoriteId,
  String? favoriteName,
}) {
  final items = <ShortcutItem>[
    ShortcutItem(
      type: kShortcutNewTask,
      localizedTitle: '新建任务',
      icon: android ? 'ic_shortcut_add' : null,
    ),
    ShortcutItem(
      type: kShortcutSearchTask,
      localizedTitle: '搜索任务',
      icon: android ? 'ic_shortcut_search' : null,
    ),
  ];
  final name = favoriteName?.trim() ?? '';
  if (favoriteId != null && name.isNotEmpty) {
    items.add(
      ShortcutItem(
        type: '$kShortcutRunTaskPrefix$favoriteId',
        // 安卓启动器短标题大约 10 个字就会被截断，太长的名字先截一刀，保证「运行」两个字看得见
        localizedTitle: '运行 ${_ellipsis(name, 12)}',
        icon: android ? 'ic_shortcut_run' : null,
      ),
    );
  }
  return items;
}

/// 快捷方式列表的比较签名：内容没变就不重复调平台接口。
String shortcutSignature(List<ShortcutItem> items) =>
    items.map((e) => '${e.type}|${e.localizedTitle}').join('\n');

String _ellipsis(String text, int max) {
  final chars = text.runes.toList();
  if (chars.length <= max) return text;
  return '${String.fromCharCodes(chars.take(max))}…';
}

// ── 桌面小组件快照 ─────────────────────────────────────────────────────

/// 小组件快照的键（安卓 `TaskWidgetProvider.kt` 按同名键读取，两边要一起改）。
/// 全部存字符串：home_widget 存 int 时安卓侧类型不稳定，时间统一存毫秒时间戳的字符串。
class WidgetKeys {
  WidgetKeys._();

  /// 今日成功 / 失败次数（来自概览数据，面板「今日」口径）。
  static const String todaySuccess = 'dd_today_success';
  static const String todayFailed = 'dd_today_failed';

  /// 上面两个次数属于哪一天（本地日期 `yyyy-MM-dd`）。跨天后小组件显示「--」，不把昨天的当今天。
  static const String todayDate = 'dd_today_date';

  /// 下一个要运行的任务。
  static const String nextId = 'dd_next_id';
  static const String nextName = 'dd_next_name';
  static const String nextAt = 'dd_next_at';

  /// 最近一次失败的任务。
  static const String failedId = 'dd_failed_id';
  static const String failedName = 'dd_failed_name';
  static const String failedAt = 'dd_failed_at';

  /// 快照写入时间（小组件上显示「更新于 HH:mm」，让人知道数据有多旧）。
  static const String updatedAt = 'dd_updated_at';

  /// 全部键：退出登录 / 切换面板时一次删光，小组件回到占位（「--」「暂无」「打开 APP 获取数据」）。
  static const List<String> all = [
    todaySuccess,
    todayFailed,
    todayDate,
    nextId,
    nextName,
    nextAt,
    failedId,
    failedName,
    failedAt,
    updatedAt,
  ];
}

/// 从任务列表算出「下一个任务」与「最近失败的任务」。值为 null 的键会被清掉。
///
/// - 下一个：没禁用、`next_run_at` 晚于 [now] 的任务里最早的那个；
/// - 最近失败：上次运行失败（`last_run_status == 1`）的任务里 `last_run_at` 最晚的那个。
Map<String, String?> widgetDataFromTasks(List<Task> tasks, DateTime now) {
  Task? next;
  Task? failed;
  for (final task in tasks) {
    final nextAt = task.nextRunAt;
    if (!task.isDisabled && nextAt != null && nextAt.isAfter(now)) {
      if (next == null || nextAt.isBefore(next.nextRunAt!)) next = task;
    }
    final lastAt = task.lastRunAt;
    if (task.lastRunFailed && lastAt != null) {
      if (failed == null || lastAt.isAfter(failed.lastRunAt!)) failed = task;
    }
  }
  return {
    WidgetKeys.nextId: next?.id.toString(),
    WidgetKeys.nextName: next?.name,
    WidgetKeys.nextAt: next?.nextRunAt?.millisecondsSinceEpoch.toString(),
    WidgetKeys.failedId: failed?.id.toString(),
    WidgetKeys.failedName: failed?.name,
    WidgetKeys.failedAt: failed?.lastRunAt?.millisecondsSinceEpoch.toString(),
  };
}

/// 今日成功率的原始次数（小组件里算百分比，成功 / (成功 + 失败)，与概览同口径，已终止不进分母）。
Map<String, String?> widgetDataFromToday({
  required int success,
  required int failed,
}) {
  return {
    WidgetKeys.todaySuccess: success.toString(),
    WidgetKeys.todayFailed: failed.toString(),
  };
}

// ── 常驻通知 ───────────────────────────────────────────────────────────

/// 「N 个任务运行中 · 名称…」：标题放数量，正文放最多 3 个名称。
({String title, String body}) runningNotificationText(List<RunningTask> tasks) {
  final names = tasks
      .map((t) => t.name.trim())
      .where((n) => n.isNotEmpty)
      .toList();
  final shown = names.take(3).join('、');
  final more = names.length > 3 ? ' 等' : '';
  return (
    title: '${tasks.length} 个任务运行中',
    body: shown.isEmpty ? '点按查看任务' : '$shown$more',
  );
}

/// 老面板没有 `GET /tasks/running`：用任务列表里状态为「运行中」的任务代替。
List<RunningTask> runningFromTasks(List<Task> tasks) {
  return tasks
      .where((t) => t.isRunning)
      .map((t) => RunningTask(taskId: t.id, name: t.name))
      .toList();
}
