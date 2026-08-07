import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/app_card.dart';

class TaskStatsCard extends StatelessWidget {
  final int total;
  final int enabled;
  final int running;
  final int disabled;
  final int todaySuccess;
  final int todayFailed;

  /// 今日主动终止数。面板把它从成功 / 失败里拆了出来（`aborted_logs`），
  /// 不显示的话「今日成功 + 今日失败」永远对不上今日执行总数。
  ///
  /// 默认 0：老面板不返回 `aborted_logs`，此时这一格不渲染，布局与改动前一致。
  final int todayAborted;
  final VoidCallback? onTap;

  const TaskStatsCard({
    super.key,
    required this.total,
    required this.enabled,
    required this.running,
    required this.disabled,
    required this.todaySuccess,
    required this.todayFailed,
    this.todayAborted = 0,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;

    return AppCard(
      // 主页任务概览现在可以直接点击跳转，方便用户从统计卡片进入任务列表。
      onTap: onTap,
      child: Column(
        children: [
          // 四个统计块必须互相区分：总任务是中性汇总数（不是状态，用强调文字色），
          // 已启用=绿、运行中=蓝、已禁用=灰。改造前前三个分别是
          // primary / primary / blue500，主色换蓝后全成了蓝色系。
          Row(
            children: [
              _StatItem(
                label: '总任务',
                value: '$total',
                color: isLight ? AppColors.slate800 : AppColors.slate100,
                isLight: isLight,
              ),
              _StatItem(
                label: '已启用',
                value: '$enabled',
                color: AppColors.success,
                isLight: isLight,
              ),
              _StatItem(
                label: '运行中',
                value: '$running',
                color: AppColors.info,
                isLight: isLight,
              ),
              _StatItem(
                label: '已禁用',
                value: '$disabled',
                color: AppColors.slate400,
                isLight: isLight,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Divider(
              height: 1,
              color: isLight ? AppColors.slate100 : AppColors.slate800,
            ),
          ),
          Row(
            children: [
              _StatItem(
                label: '今日成功',
                value: '$todaySuccess',
                color: AppColors.success,
                isLight: isLight,
              ),
              _StatItem(
                label: '今日失败',
                value: '$todayFailed',
                color: AppColors.danger,
                isLight: isLight,
              ),
              // 面板没返回 aborted_logs（老面板）且今天一次没终止过时不占位，
              // 避免给老面板用户凭空多出一个恒为 0 的格子。
              if (todayAborted > 0)
                _StatItem(
                  label: '今日终止',
                  value: '$todayAborted',
                  color: AppColors.warning,
                  isLight: isLight,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final bool isLight;

  const _StatItem({
    required this.label,
    required this.value,
    required this.color,
    required this.isLight,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: isLight ? AppColors.slate500 : AppColors.slate400,
            ),
          ),
        ],
      ),
    );
  }
}
