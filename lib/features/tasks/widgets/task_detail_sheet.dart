import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_provider.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/models/task.dart';
import '../../../shared/models/task_log.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/utils/duration_utils.dart';
import '../../../shared/utils/panel_enums.dart';
import '../../../shared/utils/task_command.dart';
import '../../../shared/utils/time_utils.dart';
import '../../../shared/widgets/app_glass_circle_button.dart';
import '../../../shared/widgets/app_grouped_list.dart';
import '../../../shared/widgets/app_icon_tile.dart';
import '../../../shared/widgets/app_pill_button.dart';
import '../../../shared/widgets/app_sheet.dart';
import '../../../shared/widgets/app_snack.dart';
import '../../../shared/widgets/hold_to_run_button.dart';
import '../providers/favorite_tasks_provider.dart';
import '../providers/task_health_provider.dart';
import '../providers/task_provider.dart';
import '../views/task_list_page.dart' show confirmAndDeleteTask, openLatestTaskLog;
import 'task_health_calendar.dart';

/// 打开任务详情弹层（PRD A3）。任务列表点任务、常用任务卡片、快捷方式「运行 xx」都调它。
///
/// [focusRun] 为 true 时，弹层打开后「按住立即运行」轻轻脉冲几下，提示可以运行
/// （快捷方式用：不直接运行，防误触）。
Future<void> showTaskDetailSheet(
  BuildContext context,
  WidgetRef ref,
  Task task, {
  bool focusRun = false,
}) {
  // 弹层动画还在走，健康画像的请求先发出去
  final health = ref.read(taskHealthProvider(task.id));
  if (!health.loading) {
    ref.read(taskHealthProvider(task.id).notifier).load();
  }
  return showAppSheet<void>(
    context: context,
    builder: (_) => TaskDetailContent(
      taskId: task.id,
      initialTask: task,
      focusRun: focusRun,
      inSheet: true,
    ),
  );
}

/// 任务详情的内容：弹层和 `/tasks/:id/detail` 详情页共用这一份。
///
/// 从上到下：顶栏 → 任务名与状态 → 启用 / 加入常用 → 三个统计 → 月历 → 最近一次日志
/// → 信息 → 操作；底部固定「按住立即运行」（operator 及以上）。
///
/// 面板没有「按 id 取单个任务」的接口，数据以任务列表 provider 里同 id 的那条为准：
/// 操作都会让 provider 重拉列表，这里跟着刷新；列表里找不到时（比如刚被删）才用 [initialTask] 兜底。
///
/// 老面板（health 接口 404）：统计和月历整块不显示，其余照常。
class TaskDetailContent extends ConsumerStatefulWidget {
  final int taskId;
  final Task? initialTask;
  final bool focusRun;

  /// 弹层里：左上角是「关闭」、不带下拉刷新（下拉是关弹层）；详情页里：左上角是「返回」、带下拉刷新。
  final bool inSheet;

  const TaskDetailContent({
    super.key,
    required this.taskId,
    this.initialTask,
    this.focusRun = false,
    this.inSheet = true,
  });

  @override
  ConsumerState<TaskDetailContent> createState() => _TaskDetailContentState();
}

class _TaskDetailContentState extends ConsumerState<TaskDetailContent>
    with SingleTickerProviderStateMixin {
  // 最近一次日志：本页自己拉（沿用 latest-log 接口，面板已解压好正文）
  TaskLog? _latestLog;
  bool _logLoading = true;
  bool _logFailed = false;

  /// 「按住运行」的提示脉冲（focusRun）。在 initState 里建好：懒建的话没用到它的弹层
  /// 会在 dispose 时才第一次创建，那时已经不能再找祖先（TickerMode）了。
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );
    // 不能在 build 阶段改 provider，挪到下一个微任务
    Future.microtask(() {
      if (!mounted) return;
      final health = ref.read(taskHealthProvider(widget.taskId));
      // 弹层入口已经发过请求的就不重复发
      if (!health.loading) {
        ref.read(taskHealthProvider(widget.taskId).notifier).load();
      }
    });
    _loadLatestLog();
    if (widget.focusRun) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // 减少动画时不脉冲，只留一圈静态描边
        if (mounted && !AppMotion.reduce(context)) _playPulse();
      });
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _playPulse() async {
    try {
      for (var i = 0; i < 3; i++) {
        await _pulse.forward(from: 0).orCancel;
        await _pulse.reverse().orCancel;
      }
    } on TickerCanceled {
      // 弹层关了，动画被取消，什么都不用做
    }
  }

  Future<void> _loadLatestLog() async {
    setState(() {
      _logLoading = true;
      _logFailed = false;
    });
    try {
      final log = await ref
          .read(taskProvider.notifier)
          .fetchLatestLog(widget.taskId);
      if (!mounted) return;
      setState(() {
        _latestLog = log;
        _logLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _logLoading = false;
        _logFailed = true;
      });
    }
  }

  Future<void> _refreshAll() async {
    await Future.wait([
      ref.read(taskProvider.notifier).load(refresh: true),
      ref.read(taskHealthProvider(widget.taskId).notifier).load(),
      _loadLatestLog(),
    ]);
  }

  void _openLiveLog(Task task) {
    context.push('/tasks/${task.id}/live-logs', extra: task.name);
  }

  /// 操作统一入口：成功出绿条、失败出红条，文案与列表侧滑一致。
  Future<void> _runAction(
    Future<void> Function() action,
    String successText,
    String errorFallback,
  ) async {
    try {
      await action();
      if (mounted && successText.isNotEmpty) {
        AppSnack.success(context, successText);
      }
    } catch (error) {
      if (mounted) {
        AppSnack.error(context, extractErrorMessage(error, errorFallback));
      }
    }
  }

  /// 按住走满：与列表一样，启动后直接进实时日志；面板说「已在运行中」也照样进。
  Future<void> _run(Task task) async {
    try {
      await ref.read(taskProvider.notifier).runTask(task.id);
      if (mounted) _openLiveLog(task);
    } catch (error) {
      if (!mounted) return;
      final message = extractErrorMessage(error, '启动任务失败');
      if (message.contains('运行中')) {
        _openLiveLog(task);
      } else {
        AppSnack.error(context, message);
      }
    }
  }

  Future<void> _toggleEnabled(Task task) async {
    final notifier = ref.read(taskProvider.notifier);
    // 按开关位分支，与列表 _toggleTaskEnabled 同一口径（运行中的禁用任务 status 也是 2）
    if (task.isSwitchOn) {
      await _runAction(
        () => notifier.disableTask(task.id),
        task.isRunning ? '任务已设置为完成后禁用' : '任务已禁用',
        '更新任务状态失败',
      );
    } else {
      await _runAction(
        () => notifier.enableTask(task.id),
        '任务已启用',
        '更新任务状态失败',
      );
    }
  }

  Future<void> _toggleFavorite(Task task, bool wasFavorite) async {
    // toggle 的返回值只在「加满了」时有意义，这里不依赖它：调完再看状态里有没有
    // 同步、异步两种实现都兼容：返回 Future 就等它写完
    final Object result = ref
        .read(favoriteTasksProvider.notifier)
        .toggle(task.id);
    if (result is Future) await result;
    if (!mounted) return;
    final isFavorite = ref.read(favoriteTasksProvider).contains(task.id);
    if (!wasFavorite && !isFavorite) {
      AppSnack.show(context, '常用任务最多 5 个，先移出一个再加');
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final tasks = ref.watch(taskProvider.select((state) => state.tasks));
    Task? task = widget.initialTask;
    for (final item in tasks) {
      if (item.id == widget.taskId) {
        task = item;
        break;
      }
    }

    // 任务跑完一轮（上次运行时间 / 状态变了）：最近日志和统计跟着刷新
    ref.listen<String?>(
      taskProvider.select((state) {
        for (final item in state.tasks) {
          if (item.id == widget.taskId) {
            return '${item.lastRunAt}|${item.status}|${item.lastRunStatus}';
          }
        }
        return null;
      }),
      (previous, next) {
        if (previous == null || next == null || previous == next) return;
        _loadLatestLog();
        ref.read(taskHealthProvider(widget.taskId).notifier).load();
      },
    );

    final topBar = Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        children: [
          AppGlassCircleButton(
            icon: widget.inSheet
                ? Icons.close_rounded
                : Icons.arrow_back_ios_new_rounded,
            tooltip: widget.inSheet ? '关闭' : '返回',
            size: 44,
            onTap: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: Text(
              '任务详情',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: palette.text,
              ),
            ),
          ),
          AppGlassCircleButton(
            key: const Key('task-detail-refresh'),
            icon: Icons.refresh_rounded,
            tooltip: '刷新',
            size: 44,
            onTap: task == null ? null : _refreshAll,
          ),
        ],
      ),
    );

    if (task == null) {
      return Column(
        children: [
          topBar,
          Expanded(
            child: Center(
              child: Text(
                '任务不存在或已被删除',
                style: AppText.body.copyWith(color: palette.text2),
              ),
            ),
          ),
        ],
      );
    }
    final current = task;

    final canOperate = ref.watch(authProvider).user?.isOperator ?? false;
    final isFavorite = ref.watch(favoriteTasksProvider).contains(current.id);
    final healthState = ref.watch(taskHealthProvider(current.id));
    final health = healthState.health;

    // ── 任务名下面那一行：状态点 + 文字 · 下次运行 / 任务类型 ──
    final (statusText, statusColor) = current.isRunning
        ? ('运行中', palette.accent)
        : !current.isSwitchOn
        ? ('已禁用', palette.text3)
        : current.lastRunStatus == null
        ? ('还没运行过', palette.text3)
        : switch (taskRunResultTone(current.lastRunStatus)) {
            PanelStatusTone.danger => ('上次失败', palette.err),
            PanelStatusTone.warning => ('上次${current.lastRunResultText}', palette.warn),
            PanelStatusTone.success => ('上次成功', palette.ok),
            _ => ('上次${current.lastRunResultText}', palette.text3),
          };
    final scheduleText = current.nextRunAt != null
        ? '下次 ${formatTimeCn(current.nextRunAt, short: true)}'
        : current.taskTypeText;

    final group = current.groupName;
    final labels = current.userLabelsForDisplay;
    Widget chip(String text, {IconData? icon}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: palette.fill,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: palette.text2),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: palette.text2,
            ),
          ),
        ],
      ),
    );

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            current.name,
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.6,
              height: 1.2,
              color: palette.text,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$statusText · $scheduleText',
                  key: const Key('task-detail-status'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.tabular(
                    TextStyle(fontSize: 15, color: palette.text2),
                  ),
                ),
              ),
            ],
          ),
          if (group != null || labels.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (group != null) chip(group, icon: Icons.folder_rounded),
                for (final label in labels) chip(label),
              ],
            ),
          ],
        ],
      ),
    );

    // ── 启用 / 加入常用 ──
    final switches = AppGroupedList(
      children: [
        AppGroupedRow(
          key: const Key('task-detail-enabled'),
          leading: AppIconTile(
            icon: Icons.power_settings_new_rounded,
            color: palette.ok,
          ),
          title: '启用',
          subtitle: current.isSwitchOn
              ? (current.isRunning ? '运行中' : '按定时规则运行')
              : '已禁用，不会按定时规则运行',
          trailing: Switch(
            value: current.isSwitchOn,
            onChanged: canOperate ? (_) => _toggleEnabled(current) : null,
          ),
        ),
        AppGroupedRow(
          key: const Key('task-detail-favorite'),
          leading: AppIconTile(icon: Icons.star_rounded, color: palette.warn),
          title: '加入常用',
          subtitle: '显示在任务页顶部，最多 5 个',
          trailing: Switch(
            value: isFavorite,
            onChanged: (_) => _toggleFavorite(current, isFavorite),
          ),
        ),
      ],
    );

    // ── 三个统计（面板 v4.0）──
    Widget? stats;
    if (healthState.loaded && health != null) {
      final s = health.stats;
      final hasRuns = s.runs > 0;
      // 成功率是 0~100、一位小数；整数时不带 .0
      final rate = s.successRate == s.successRate.roundToDouble()
          ? s.successRate.toStringAsFixed(0)
          : s.successRate.toStringAsFixed(1);
      Widget tile(String label, String value, Key key) => Expanded(
        child: Container(
          key: key,
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 14),
          decoration: BoxDecoration(
            color: palette.card,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: AppText.caption.copyWith(color: palette.text2),
              ),
              const SizedBox(height: 2),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  maxLines: 1,
                  style: AppText.tabular(
                    TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: palette.text,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      stats = Row(
        children: [
          tile(
            '成功率',
            hasRuns ? '$rate%' : '—',
            const Key('task-health-success-rate'),
          ),
          const SizedBox(width: 10),
          tile(
            '平均耗时',
            hasRuns ? formatDurationSeconds(s.avgDuration) : '—',
            const Key('task-health-avg'),
          ),
          const SizedBox(width: 10),
          tile(
            'P90',
            hasRuns ? formatDurationSeconds(s.p90Duration) : '—',
            const Key('task-health-p90'),
          ),
        ],
      );
    }

    // 统计真的加载失败（不是老面板）：一行小字，点了重试；有旧结果时照常显示旧结果
    Widget? healthError;
    if (healthState.error != null && health == null && !healthState.loading) {
      healthError = GestureDetector(
        key: const Key('task-health-retry'),
        behavior: HitTestBehavior.opaque,
        onTap: () => ref.read(taskHealthProvider(current.id).notifier).load(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Text(
            '${healthState.error}，点此重试',
            style: AppText.caption.copyWith(color: palette.text2),
          ),
        ),
      );
    }

    // ── 最近一次日志 ──
    final log = _latestLog;
    final String? logTail = log == null ? null : _tailLines(log.content, 6);
    final (logStatusText, logStatusColor) = log == null
        ? ('', palette.text2)
        : switch (logStatusTone(log.status)) {
            PanelStatusTone.success => ('成功', palette.okInk),
            PanelStatusTone.danger => ('失败', palette.errInk),
            PanelStatusTone.warning => (logStatusLabel(log.status), palette.warnInk),
            PanelStatusTone.running => (logStatusLabel(log.status), palette.accentInk),
            _ => (logStatusLabel(log.status), palette.text2),
          };
    final String? logHint = current.isRunning
        ? '任务正在运行，点开看实时日志'
        : _logLoading && log == null
        ? '加载中…'
        : _logFailed && log == null
        ? '最近日志加载失败，点开重试'
        : log == null
        ? '暂无日志'
        : (logTail == null ? '日志没有内容，点开查看详情' : null);

    final latestLogCard = Material(
      color: palette.card,
      borderRadius: BorderRadius.circular(AppRadius.card),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const Key('task-detail-latest-log'),
        // 与列表左滑的「日志」共用（APP #22 评论）：运行中开实时日志，否则打开最近一次日志
        onTap: () => openLatestTaskLog(context, ref, current),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 12, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    '最近一次',
                    style: AppText.cardTitle.copyWith(
                      fontSize: 19,
                      color: palette.text,
                    ),
                  ),
                  const Spacer(),
                  if (log != null && !current.isRunning) ...[
                    Text(
                      logStatusText,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: logStatusColor,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      formatTimeCn(log.startedAt, short: true),
                      style: AppText.tabular(
                        TextStyle(fontSize: 14, color: palette.text2),
                      ),
                    ),
                  ],
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 22,
                    color: palette.text3,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (logHint != null)
                Text(
                  logHint,
                  style: AppText.caption.copyWith(color: palette.text2),
                )
              else
                Container(
                  key: const Key('task-detail-log-tail'),
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(right: 6),
                  decoration: BoxDecoration(
                    color: palette.card2,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    logTail!,
                    maxLines: 8,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12.5,
                      height: 1.5,
                      // 失败日志的末尾一般就是报错，整段用红色墨色
                      color: log?.status == kLogStatusFailed
                          ? palette.errInk
                          : palette.text,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    // ── 信息（沿用旧详情页的「标签 — 值」）──
    final scriptPath = extractScriptPathFromCommand(current.command);
    final scheduleExpressions = current.cronExpressions.isNotEmpty
        ? current.cronExpressions
        : (current.cronExpression.trim().isNotEmpty
              ? [current.cronExpression.trim()]
              : const <String>[]);
    // 「环境变量」行：全部 / 指定（分组：a、b；变量：X、Y），空的那一半不写
    final envScopeParts = [
      if (current.envGroups.isNotEmpty) '分组：${current.envGroups.join('、')}',
      if (current.envNames.isNotEmpty) '变量：${current.envNames.join('、')}',
    ];
    final envScopeText = !current.isEnvScopeSelected
        ? '全部'
        : (envScopeParts.isEmpty
              ? '指定（未选任何分组或变量，不注入用户变量）'
              : '指定（${envScopeParts.join('；')}）');

    var infoIndex = 0;
    Widget info(
      String label,
      String value, {
      VoidCallback? onTap,
      bool selectable = false,
      Key? key,
    }) => _InfoRow(
      key: key,
      label: label,
      value: value,
      onTap: onTap,
      selectable: selectable,
      showSeparator: infoIndex++ > 0,
    );

    final infoList = AppGroupedList(
      header: '信息',
      children: [
        info('ID', '${current.id}'),
        info('命令', current.command, selectable: true),
        // 解析不出脚本路径时显示「-」且不可点
        info(
          '脚本',
          scriptPath ?? '-',
          key: const Key('task-detail-script'),
          onTap: scriptPath == null
              ? null
              : () => context.push('/scripts/view', extra: scriptPath),
        ),
        info(
          '定时规则',
          current.taskType == 'cron'
              ? (scheduleExpressions.isEmpty
                    ? '-'
                    : scheduleExpressions.join('\n'))
              : current.taskTypeText,
        ),
        // 下面三项面板没下发（从没运行过 / 非定时任务）就不显示那一行
        if (current.nextRunAt != null)
          info('下次运行', formatTimeCn(current.nextRunAt)),
        if (current.lastRunAt != null)
          info('最后运行', formatTimeCn(current.lastRunAt)),
        if (current.lastRunningTime != null)
          info('最后运行时长', formatDurationSeconds(current.lastRunningTime)),
        // 任务级「可用环境变量」（面板 #168，v3.4.0 起）。老面板没有 env_scope 键就不出这一行
        if (current.hasEnvScope)
          info('环境变量', envScopeText, key: const Key('task-detail-env-scope')),
        info('创建时间', formatTimeCn(current.createdAt)),
        info('更新时间', formatTimeCn(current.updatedAt)),
      ],
    );

    // ── 操作：写操作只给 operator 及以上 ──
    final actions = AppGroupedList(
      header: '操作',
      children: [
        AppGroupedRow(
          key: const Key('task-detail-log-history'),
          leading: AppIconTile(
            icon: Icons.history_rounded,
            color: palette.accent,
          ),
          title: '日志历史',
          showChevron: true,
          onTap: () =>
              context.push('/tasks/${current.id}/logs', extra: current.name),
        ),
        if (canOperate) ...[
          AppGroupedRow(
            key: const Key('task-detail-edit'),
            leading: AppIconTile(
              icon: Icons.edit_rounded,
              color: palette.accent,
            ),
            title: '编辑',
            showChevron: true,
            onTap: () => context.push('/tasks/edit', extra: current),
          ),
          AppGroupedRow(
            key: const Key('task-detail-pin'),
            leading: AppIconTile(
              icon: Icons.push_pin_rounded,
              color: palette.purple,
            ),
            title: current.isPinned ? '取消置顶' : '置顶',
            onTap: () => current.isPinned
                ? _runAction(
                    () => ref.read(taskProvider.notifier).unpinTask(current.id),
                    '已取消置顶',
                    '更新置顶状态失败',
                  )
                : _runAction(
                    () => ref.read(taskProvider.notifier).pinTask(current.id),
                    '已置顶任务',
                    '更新置顶状态失败',
                  ),
          ),
          AppGroupedRow(
            key: const Key('task-detail-copy'),
            leading: AppIconTile(
              icon: Icons.copy_rounded,
              color: palette.accent,
            ),
            title: '复制',
            onTap: () => _runAction(
              () => ref.read(taskProvider.notifier).copyTask(current.id),
              '任务已复制',
              '复制任务失败',
            ),
          ),
          AppGroupedRow(
            key: const Key('task-detail-delete'),
            leading: AppIconTile(
              icon: Icons.delete_rounded,
              color: palette.err,
            ),
            title: '删除',
            titleColor: palette.errInk,
            onTap: () async {
              final deleted = await confirmAndDeleteTask(context, ref, current);
              // 删掉了就关掉弹层 / 回列表，留在这里只剩一份过期数据
              if (deleted && context.mounted) {
                Navigator.of(context).maybePop();
              }
            },
          ),
        ],
      ],
    );

    final list = ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        header,
        const SizedBox(height: 18),
        switches,
        if (stats != null) ...[const SizedBox(height: 16), stats],
        if (stats != null && health!.days.isNotEmpty) ...[
          const SizedBox(height: 16),
          TaskHealthCalendar(days: health.days),
        ],
        if (healthError != null) ...[const SizedBox(height: 8), healthError],
        const SizedBox(height: 16),
        latestLogCard,
        const SizedBox(height: 24),
        infoList,
        const SizedBox(height: 24),
        actions,
      ],
    );

    // ── 底部固定：按住立即运行 / 运行中时「实时日志 + 停止」──
    Widget? bottomBar;
    if (canOperate) {
      final Widget runControl;
      if (current.isRunning) {
        runControl = Row(
          children: [
            Expanded(
              child: AppPillButton(
                key: const Key('task-detail-live-log'),
                label: '实时日志',
                icon: Icons.subject_rounded,
                variant: AppPillVariant.secondary,
                expand: true,
                height: 56,
                onPressed: () => _openLiveLog(current),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: AppPillButton(
                key: const Key('task-detail-stop'),
                label: '停止',
                icon: Icons.stop_rounded,
                variant: AppPillVariant.danger,
                expand: true,
                height: 56,
                onPressed: () => _runAction(
                  () => ref.read(taskProvider.notifier).stopTask(current.id),
                  '任务已停止',
                  '停止任务失败',
                ),
              ),
            ),
          ],
        );
      } else {
        runControl = LayoutBuilder(
          builder: (context, constraints) {
            final button = HoldToRunButton(
              key: const Key('task-detail-hold-run'),
              label: '按住立即运行',
              width: constraints.maxWidth,
              height: 64,
              onConfirmed: () => _run(current),
            );
            if (!widget.focusRun) return button;
            // focusRun：外面一圈强调色描边 + 轻微放大，脉冲三下；减少动画时描边常亮、不动
            final reduce = AppMotion.reduce(context);
            return AnimatedBuilder(
              animation: _pulse,
              builder: (context, child) {
                final t = reduce ? 1.0 : _pulse.value;
                return Transform.scale(
                  scale: 1 + 0.03 * (reduce ? 0 : t),
                  child: DecoratedBox(
                    key: const Key('task-detail-run-focus'),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      border: Border.all(
                        color: palette.accent.withValues(
                          alpha: reduce ? 0.8 : 0.25 + 0.75 * t,
                        ),
                        width: 3,
                      ),
                    ),
                    child: child,
                  ),
                );
              },
              child: button,
            );
          },
        );
      }
      bottomBar = Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: runControl,
      );
    }

    return Column(
      children: [
        topBar,
        Expanded(
          child: widget.inSheet
              ? list
              : RefreshIndicator(
                  color: palette.accent,
                  onRefresh: _refreshAll,
                  child: list,
                ),
        ),
        ?bottomBar,
      ],
    );
  }
}

/// 日志正文的最后 [count] 行非空行（去掉终端颜色码和面板自己写的 `===` 框线）。
/// 没有可显示的行时返回 null。
String? _tailLines(String content, int count) {
  final lines = content
      .replaceAll(RegExp(r'\x1b\[[0-9;?]*[A-Za-z]'), '')
      .split('\n')
      .map((line) => line.trimRight())
      .where((line) => line.trim().isNotEmpty && !line.startsWith('=== '))
      .toList();
  if (lines.isEmpty) return null;
  return lines.sublist(lines.length > count ? lines.length - count : 0).join('\n');
}

/// 信息区的一行「标签 — 值」：值靠右、过长时换行；传了 [onTap] 才可点，右侧带「>」。
/// 不用 `AppGroupedRow`：它的 trailing 不会换行，长命令会溢出。
class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback? onTap;
  final bool selectable;
  final bool showSeparator;

  const _InfoRow({
    super.key,
    required this.label,
    required this.value,
    this.onTap,
    this.selectable = false,
    this.showSeparator = true,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final valueStyle = TextStyle(
      fontSize: 14,
      height: 1.4,
      color: value == '-' ? palette.text3 : palette.text,
    );
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 13, 14, 13),
        decoration: BoxDecoration(
          border: showSeparator
              ? Border(
                  top: BorderSide(color: palette.separator, width: 0.5),
                )
              : null,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 92,
              child: Text(
                label,
                style: TextStyle(fontSize: 14, color: palette.text2),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: selectable
                  ? SelectableText(
                      value,
                      textAlign: TextAlign.right,
                      style: valueStyle,
                    )
                  : Text(value, textAlign: TextAlign.right, style: valueStyle),
            ),
            if (onTap != null) ...[
              const SizedBox(width: 4),
              Icon(Icons.chevron_right_rounded, size: 20, color: palette.text3),
            ],
          ],
        ),
      ),
    );
  }
}
