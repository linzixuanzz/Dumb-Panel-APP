import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../shared/models/task.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/utils/duration_utils.dart';
import '../../../shared/utils/panel_enums.dart';
import '../../../shared/utils/task_command.dart';
import '../../../shared/utils/time_utils.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/app_snack.dart';
import '../providers/task_provider.dart';
import 'task_list_page.dart' show confirmAndDeleteTask, openLatestTaskLog;

/// 任务详情页（issue #20，照青龙客户端）：从上到下一行一个「标签 — 值」，
/// 可点的行右侧带「>」，右上角「…」菜单放运行 / 编辑 / 启停 / 置顶 / 复制 / 删除。
///
/// 面板没有「按 id 取单个任务」的接口，所以数据以任务列表 provider 里同 id 的那条为准：
/// 菜单里的操作都会让 provider 重拉列表，详情页跟着刷新；列表里找不到时（比如刚被删）
/// 才用路由 extra 传进来的那份兜底。
class TaskDetailPage extends ConsumerStatefulWidget {
  final int taskId;
  final Task? initialTask;

  const TaskDetailPage({super.key, required this.taskId, this.initialTask});

  @override
  ConsumerState<TaskDetailPage> createState() => _TaskDetailPageState();
}

class _TaskDetailPageState extends ConsumerState<TaskDetailPage> {
  Task? _findTask(List<Task> tasks) {
    for (final task in tasks) {
      if (task.id == widget.taskId) return task;
    }
    return widget.initialTask;
  }

  void _openLiveLog(Task task) {
    context.push('/tasks/${task.id}/live-logs', extra: task.name);
  }

  /// 菜单动作统一入口：成功出绿条、失败出红条，文案与列表侧滑一致。
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

  Future<void> _onMenuSelected(String value, Task task) async {
    final notifier = ref.read(taskProvider.notifier);
    switch (value) {
      case 'run':
        // 与列表一样：启动后直接进实时日志；面板说「已在运行中」也照样进
        try {
          await notifier.runTask(task.id);
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
      case 'stop':
        await _runAction(() => notifier.stopTask(task.id), '任务已停止', '停止任务失败');
      case 'edit':
        context.push('/tasks/edit', extra: task);
      case 'toggle':
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
      case 'pin':
        if (task.isPinned) {
          await _runAction(
            () => notifier.unpinTask(task.id),
            '已取消置顶',
            '更新置顶状态失败',
          );
        } else {
          await _runAction(
            () => notifier.pinTask(task.id),
            '已置顶任务',
            '更新置顶状态失败',
          );
        }
      case 'copy':
        await _runAction(() => notifier.copyTask(task.id), '任务已复制', '复制任务失败');
      case 'delete':
        final deleted = await confirmAndDeleteTask(context, ref, task);
        // 删掉了就回列表，留在这里只剩一份过期数据
        if (deleted && mounted) context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tasks = ref.watch(taskProvider.select((state) => state.tasks));
    final task = _findTask(tasks);
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;

    if (task == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('任务详情')),
        body: const Center(child: Text('任务不存在或已被删除')),
      );
    }

    final scriptPath = extractScriptPathFromCommand(task.command);
    final scheduleExpressions = task.cronExpressions.isNotEmpty
        ? task.cronExpressions
        : (task.cronExpression.trim().isNotEmpty
              ? [task.cronExpression.trim()]
              : const <String>[]);
    final dividerColor = isLight ? AppColors.slate100 : AppColors.slate800;
    final mutedColor = theme.colorScheme.onSurfaceVariant;

    // 一行「标签 — 值」。传了 onTap 才可点，右侧带「>」；值过长时在右侧换行
    Widget row(
      String label,
      String value, {
      VoidCallback? onTap,
      Color? valueColor,
      bool selectable = false,
      Key? key,
    }) {
      final valueStyle = TextStyle(
        fontSize: 13,
        height: 1.4,
        color: valueColor ?? (value == '-' ? mutedColor : null),
      );
      return InkWell(
        key: key,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: dividerColor)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 96,
                child: Text(
                  label,
                  style: TextStyle(fontSize: 13, color: mutedColor),
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
                    : Text(
                        value,
                        textAlign: TextAlign.right,
                        style: valueStyle,
                      ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: 4),
                Icon(Icons.chevron_right, size: 18, color: mutedColor),
              ],
            ],
          ),
        ),
      );
    }

    // 运行状态与启用状态拆开显示：status 一个字段同时装着开关和运行态
    final runStateText = task.isRunning
        ? '运行中'
        : task.isQueued
        ? '排队中'
        : (task.hasKnownStatus ? '空闲' : task.statusText);
    // 最新日志行的值给上次运行结果；失败红、已终止琥珀，与旧详情弹窗同一套着色
    final lastResultColor = switch (taskRunResultTone(task.lastRunStatus)) {
      PanelStatusTone.danger => AppColors.red500,
      PanelStatusTone.warning => AppColors.warning,
      _ => null,
    };

    return Scaffold(
      appBar: AppBar(
        title: const Text('任务详情'),
        actions: [
          PopupMenuButton<String>(
            key: const Key('task-detail-menu'),
            icon: const Icon(Icons.more_horiz),
            onSelected: (value) => _onMenuSelected(value, task),
            itemBuilder: (_) => [
              PopupMenuItem(
                value: task.isRunning ? 'stop' : 'run',
                child: Text(task.isRunning ? '停止' : '运行'),
              ),
              const PopupMenuItem(value: 'edit', child: Text('编辑')),
              PopupMenuItem(
                value: 'toggle',
                child: Text(task.switchActionLabel),
              ),
              PopupMenuItem(
                value: 'pin',
                child: Text(task.isPinned ? '取消置顶' : '置顶'),
              ),
              const PopupMenuItem(value: 'copy', child: Text('复制')),
              const PopupMenuItem(
                value: 'delete',
                child: Text('删除', style: TextStyle(color: AppColors.red500)),
              ),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: () => ref.read(taskProvider.notifier).load(refresh: true),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            AppCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  row('名称', task.name, selectable: true),
                  row('ID', '${task.id}'),
                  row('命令', task.command, selectable: true),
                  // 解析不出脚本路径时显示「-」且不可点
                  row(
                    '脚本',
                    scriptPath ?? '-',
                    key: const Key('task-detail-script'),
                    onTap: scriptPath == null
                        ? null
                        : () =>
                              context.push('/scripts/view', extra: scriptPath),
                  ),
                  row('创建时间', formatTimeCn(task.createdAt)),
                  row('更新时间', formatTimeCn(task.updatedAt)),
                  row(
                    '定时规则',
                    task.taskType == 'cron'
                        ? (scheduleExpressions.isEmpty
                              ? '-'
                              : scheduleExpressions.join('\n'))
                        : task.taskTypeText,
                  ),
                  // 下面三项面板没下发（从没运行过 / 非定时任务）就不显示那一行
                  if (task.nextRunAt != null)
                    row('下次运行', formatTimeCn(task.nextRunAt)),
                  if (task.lastRunAt != null)
                    row('最后运行', formatTimeCn(task.lastRunAt)),
                  if (task.lastRunningTime != null)
                    row('最后运行时长', formatDurationSeconds(task.lastRunningTime)),
                  row(
                    '最新日志',
                    task.isRunning
                        ? '运行中，查看实时日志'
                        : (task.lastRunStatus == null
                              ? ''
                              : task.lastRunResultText),
                    valueColor: task.isRunning ? null : lastResultColor,
                    key: const Key('task-detail-latest-log'),
                    // 与列表左滑的「日志」共用（APP #22 评论）：运行中开实时日志，否则打开最近一次日志
                    onTap: () => openLatestTaskLog(context, ref, task),
                  ),
                  row(
                    '日志历史',
                    '',
                    key: const Key('task-detail-log-history'),
                    onTap: () => context.push(
                      '/tasks/${task.id}/logs',
                      extra: task.name,
                    ),
                  ),
                  row('运行状态', runStateText),
                  row(
                    '启用状态',
                    task.isSwitchOn ? '已启用' : '已禁用',
                    valueColor: task.isSwitchOn ? null : mutedColor,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
