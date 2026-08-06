import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/design_tokens.dart';
import 'app_card.dart';

class TaskCronList extends StatelessWidget {
  final List<String> expressions;
  final bool compact;
  final bool numbered;

  const TaskCronList({
    super.key,
    required this.expressions,
    this.compact = false,
    this.numbered = true,
  });

  List<String> get _normalized => expressions
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;
    final surfaces = AppSurfaces.of(context);
    final items = _normalized;

    if (items.isEmpty) {
      return AppCard(
        width: double.infinity,
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 8 : 10,
          vertical: compact ? 6 : 9,
        ),
        radius: AppRadius.md,
        color: surfaces.subtle,
        borderColor: surfaces.subtleBorder,
        child: Text(
          '暂无定时规则',
          style: TextStyle(
            fontSize: compact ? 11 : 12,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    final isMulti = items.length > 1;
    final cardBg = surfaces.subtle;
    final cardBorder = surfaces.subtleBorder;
    // 序号 / 时钟图标压在 primary 淡底上，满强度 primary 只有 2.6:1。
    final badgeFg = surfaces.tintFg(AppColors.primary);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) SizedBox(height: compact ? 6 : 8),
          AppCard(
            width: double.infinity,
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 9 : 11,
              vertical: compact ? 7 : 10,
            ),
            radius: AppRadius.md,
            color: cardBg,
            borderColor: cardBorder,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: compact ? 26 : 30,
                  height: compact ? 26 : 30,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(isLight ? 22 : 36),
                    // 原来是 `compact ? 8 : 10` —— 正则扫不到的紧凑三元。
                    // 序号/时钟底板是图标底板，两种密度下都走 sm；外层卡片是
                    // md(12)，内层 8 仍小于外层。
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  alignment: Alignment.center,
                  child: numbered && isMulti
                      ? Text(
                          '${i + 1}',
                          style: TextStyle(
                            fontSize: compact ? 10 : 11,
                            fontWeight: FontWeight.w800,
                            color: badgeFg,
                          ),
                        )
                      : Icon(
                          Icons.schedule_rounded,
                          size: 16,
                          color: badgeFg,
                        ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (!compact) ...[
                        Text(
                          isMulti ? 'Cron 规则 ${i + 1}' : 'Cron 规则',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: isLight
                                ? AppColors.slate500
                                : AppColors.slate400,
                          ),
                        ),
                        const SizedBox(height: 4),
                      ],
                      // Cron 本身保留等宽字体，外层改成信息卡，不再像输入框。
                      SelectableText(
                        items[i],
                        maxLines: compact ? 1 : 2,
                        style: TextStyle(
                          fontSize: compact ? 11 : 12,
                          height: compact ? 1.25 : 1.45,
                          fontFamily: 'monospace',
                          color: isLight
                              ? AppColors.slate800
                              : AppColors.slate100,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
