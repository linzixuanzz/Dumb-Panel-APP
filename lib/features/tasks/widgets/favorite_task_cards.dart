import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/design_tokens.dart';
import '../../../shared/models/task.dart';
import '../../../shared/utils/duration_utils.dart';
import '../../../shared/widgets/app_icon_tile.dart';
import '../../../shared/widgets/app_pill_button.dart';
import '../../../shared/widgets/hold_to_run_button.dart';
import '../../../shared/widgets/notched_card.dart';
import '../providers/favorite_tasks_provider.dart';

/// 下次运行倒计时的文字（效果演示同款）：
/// 1 小时内 `MM:SS`，1 天内 `H 时 MM 分`，再远 `N 天 H 时`；已经到点（面板还没刷新）显示「即将运行」。
String formatTaskCountdown(DateTime next, DateTime now) {
  final seconds = next.difference(now).inSeconds;
  if (seconds <= 0) {
    return '即将运行';
  }
  String pad2(int v) => v.toString().padLeft(2, '0');
  if (seconds < 3600) {
    return '${pad2(seconds ~/ 60)}:${pad2(seconds % 60)}';
  }
  if (seconds < 86400) {
    return '${seconds ~/ 3600} 时 ${pad2(seconds % 3600 ~/ 60)} 分';
  }
  return '${seconds ~/ 86400} 天 ${seconds % 86400 ~/ 3600} 时';
}

/// 任务状态 → 列表 / 卡片前导色块的图标与颜色。
///
/// 口径同旧任务卡的状态圆点：运行中 = 蓝、排队中 = 橙、上次失败 = 红（只认 last_run_status == 1，
/// 2 是用户主动终止，不亮红）、已启用 = 绿、已禁用 = 灰。
(IconData, Color) taskStatusVisual(Task task, AppPalette palette) {
  if (task.isRunning) {
    return (Icons.sync_rounded, palette.accent);
  }
  if (task.isQueued) {
    return (Icons.hourglass_top_rounded, palette.warn);
  }
  if (task.lastRunFailed) {
    return (Icons.close_rounded, palette.err);
  }
  if (task.isEnabled) {
    return (
      task.taskType == 'manual'
          ? Icons.touch_app_rounded
          : task.taskType == 'startup'
          ? Icons.power_settings_new_rounded
          : Icons.schedule_rounded,
      palette.ok,
    );
  }
  return (Icons.pause_rounded, palette.text3);
}

/// 一段会自己走的倒计时文字。整页共用一个每秒跳一次的 [now]，只有这几个字重建。
class TaskCountdownText extends StatelessWidget {
  final DateTime next;
  final ValueListenable<DateTime> now;
  final TextStyle? style;

  const TaskCountdownText({
    super.key,
    required this.next,
    required this.now,
    this.style,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DateTime>(
      valueListenable: now,
      builder: (context, value, _) => Text(
        formatTaskCountdown(next, value),
        maxLines: 1,
        // 数字等宽：每秒跳动时宽度不抖
        style: AppText.tabular(style ?? const TextStyle()),
      ),
    );
  }
}

/// 任务页「常用任务」区：小标题 + 横向可滑的缺口卡片（最多 5 张），或一张引导卡。
class FavoriteTaskSection extends StatefulWidget {
  /// 已经解析成任务的常用任务（顺序同 `favoriteTasksProvider`）。
  final List<Task> tasks;

  /// 收藏了几个 id（含当前看不到的）。用于右上角「N/5」和「都不在当前筛选里」的提示。
  final int favoriteCount;

  /// operator 及以上才能按住运行；否则缺口里放「查看」。
  final bool canRun;
  final ValueListenable<DateTime> now;
  final ValueChanged<Task> onRun;
  final ValueChanged<Task> onOpen;
  final ValueChanged<Task> onViewLog;

  const FavoriteTaskSection({
    super.key,
    required this.tasks,
    required this.favoriteCount,
    required this.canRun,
    required this.now,
    required this.onRun,
    required this.onOpen,
    required this.onViewLog,
  });

  @override
  State<FavoriteTaskSection> createState() => _FavoriteTaskSectionState();
}

class _FavoriteTaskSectionState extends State<FavoriteTaskSection> {
  final _pageController = PageController();
  int _page = 0;

  /// 卡片高度。缺口 82 高，上面要放下「图标 + 名称」和「下一次 / 上次」两行。
  static const double _cardHeight = 236;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final tasks = widget.tasks;
    // 删掉 / 移出常用后页数变少，当前页不能越界
    final page = tasks.isEmpty ? 0 : _page.clamp(0, tasks.length - 1);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.pageHorizontal,
            0,
            AppSpacing.pageHorizontal,
            10,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '常用任务',
                  style: AppText.section.copyWith(color: palette.text),
                ),
              ),
              if (widget.favoriteCount > 0)
                Text(
                  '卡片 ${widget.favoriteCount}/${FavoriteTasksNotifier.maxCount}',
                  style: AppText.tabular(
                    AppText.caption.copyWith(color: palette.text2),
                  ),
                ),
            ],
          ),
        ),
        if (tasks.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.pageHorizontal,
            ),
            child: _FavoriteGuideCard(
              // 收藏过、但一个都不在当前列表里（带着筛选冷启动）：说清楚，而不是假装没有收藏
              hiddenByFilter: widget.favoriteCount > 0,
            ),
          )
        else ...[
          SizedBox(
            height: _cardHeight,
            child: PageView.builder(
              controller: _pageController,
              itemCount: tasks.length,
              onPageChanged: (index) => setState(() => _page = index),
              itemBuilder: (context, index) => Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.pageHorizontal,
                ),
                child: _FavoriteTaskCard(
                  key: ValueKey('favorite-card-${tasks[index].id}'),
                  task: tasks[index],
                  canRun: widget.canRun,
                  now: widget.now,
                  pageCount: tasks.length,
                  page: page,
                  onRun: () => widget.onRun(tasks[index]),
                  onOpen: () => widget.onOpen(tasks[index]),
                  onViewLog: () => widget.onViewLog(tasks[index]),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 一张常用任务卡：左上图标 + 名称、中间「下一次 / 上次」、左下页码点，右下缺口里是按住运行。
class _FavoriteTaskCard extends StatelessWidget {
  final Task task;
  final bool canRun;
  final ValueListenable<DateTime> now;
  final int pageCount;
  final int page;
  final VoidCallback onRun;
  final VoidCallback onOpen;
  final VoidCallback onViewLog;

  const _FavoriteTaskCard({
    super.key,
    required this.task,
    required this.canRun,
    required this.now,
    required this.pageCount,
    required this.page,
    required this.onRun,
    required this.onOpen,
    required this.onViewLog,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final (icon, color) = taskStatusVisual(task, palette);
    final group = task.groupName;
    final labels = task.userLabelsForDisplay;
    // 副标题：上次结果 · 分组 / 第一个标签
    final resultText = task.isRunning
        ? '运行中'
        : task.isQueued
        ? '排队中'
        : task.lastRunStatus == null
        ? '还没运行过'
        : '上次${task.lastRunResultText}';
    final where = group?.isNotEmpty == true
        ? group!
        : labels.isNotEmpty
        ? labels.first
        : '未分组';
    final valueStyle = AppText.cardTitle.copyWith(
      fontSize: 18,
      color: palette.text,
    );
    final labelStyle = AppText.caption.copyWith(color: palette.text2);

    // 缺口里的三种按钮按缺口实际给的大小画（196 × 70），外形统一成 AppPillButton
    // 的圆角：任务开始 / 结束运行时按钮在「按住运行」和「实时日志」之间切换，
    // 尺寸和外形都不跳。
    const slot = NotchedCard.defaultSlotSize;
    final Widget notch;
    if (!canRun) {
      notch = AppPillButton(
        label: '查看',
        icon: Icons.open_in_new_rounded,
        onPressed: onOpen,
        expand: true,
        height: slot.height,
      );
    } else if (task.isRunning) {
      // 已经在跑：再按一次只会提示「运行中」，缺口里直接给看日志
      notch = AppPillButton(
        label: '实时日志',
        icon: Icons.receipt_long_rounded,
        onPressed: onViewLog,
        expand: true,
        height: slot.height,
      );
    } else {
      notch = HoldToRunButton(
        label: '按住运行',
        width: slot.width,
        height: slot.height,
        radius: AppRadius.md,
        onConfirmed: onRun,
      );
    }

    return NotchedCard(
      notch: notch,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    AppIconTile(icon: icon, color: color, size: 46),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            task.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.cardTitle.copyWith(
                              color: palette.text,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '$resultText · $where',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.caption.copyWith(
                              // 上次失败要一眼看到：状态色当文字用 Ink
                              color: task.lastRunFailed && !task.isRunning
                                  ? palette.errInk
                                  : palette.text2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('下一次', style: labelStyle),
                          if (task.nextRunAt != null && task.isSwitchOn)
                            TaskCountdownText(
                              next: task.nextRunAt!,
                              now: now,
                              style: valueStyle,
                            )
                          else
                            Text(
                              task.taskType == 'manual' ? '手动' : '—',
                              style: valueStyle,
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 22),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('上次耗时', style: labelStyle),
                          Text(
                            task.lastRunningTime == null
                                ? '—'
                                : formatDurationSeconds(task.lastRunningTime),
                            maxLines: 1,
                            style: AppText.tabular(valueStyle),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                // 页码点：只在左下角那一小块（右下是缺口），一张卡时不画
                if (pageCount > 1)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < pageCount; i++)
                        AnimatedContainer(
                          duration: AppMotion.of(context, AppMotion.normal),
                          curve: AppMotion.spring,
                          margin: const EdgeInsets.only(right: 5),
                          width: i == page ? 16 : 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: i == page ? palette.text : palette.text3,
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 一个常用任务都没有时的引导卡。
class _FavoriteGuideCard extends StatelessWidget {
  final bool hiddenByFilter;

  const _FavoriteGuideCard({required this.hiddenByFilter});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Row(
        children: [
          AppIconTile(icon: Icons.star_rounded, color: palette.warn, size: 46),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  hiddenByFilter ? '常用任务不在当前筛选里' : '长按任务加入常用',
                  style: AppText.body.copyWith(
                    fontWeight: FontWeight.w700,
                    color: palette.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  hiddenByFilter
                      ? '清除筛选或下拉刷新后就会出现'
                      : '最多 ${FavoriteTasksNotifier.maxCount} 个，按住卡片右下角的按钮即可运行',
                  style: AppText.caption.copyWith(color: palette.text2),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
