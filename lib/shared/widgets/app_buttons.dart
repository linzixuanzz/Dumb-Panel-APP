import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/design_tokens.dart';

/// 页面头部的胶囊型 chip 按钮（「批量」「排序」等）。
///
/// 收敛 `env_list_page.dart` 的 `_HeaderChipButton` 与
/// `task_list_page.dart` 的 `_TaskHeaderChipButton` —— 这两个类除了名字之外**逐字相同**。
///
/// 与旧实现的唯一差别：明暗由 [AppSurfaces] 从 context 解析，
/// 调用方不用再往下传 `isLight`。
class AppChipButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback onTap;

  const AppChipButton({
    super.key,
    required this.label,
    this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final surfaces = AppSurfaces.of(context);
    return GestureDetector(
      onTap: onTap,
      // vertical: 7 加上 ~17 的内容高只有 31-32dp，够不到手指。
      // 用 minHeight 补差值而不是加大 padding：视觉密度完全不变，只是命中区变高。
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppTapTarget.min),
        child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 7,
        ),
        decoration: BoxDecoration(
          color: surfaces.card,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(
            color: surfaces.cardBorder,
            width: AppBorderWidth.hairline,
          ),
        ),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: AppColors.slate400),
              const SizedBox(width: AppSpacing.xs),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

/// 淡底强调色操作按钮（批量操作条里的「批量启用 / 批量删除」等）。
///
/// 收敛 `env_list_page.dart` 的 `_BatchActionButton` 与
/// `task_list_page.dart` 的 `_TaskBatchActionButton` —— 同样是逐字相同的两份。
class AppTintedActionButton extends StatelessWidget {
  final String label;
  final IconData icon;

  /// 强调色。禁用时会退成中性灰。
  final Color color;

  final bool enabled;
  final VoidCallback onTap;

  const AppTintedActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.color,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final surfaces = AppSurfaces.of(context);
    final backgroundColor = enabled
        ? surfaces.tintBg(color)
        : surfaces.disabledBg;
    final borderColor = enabled
        ? surfaces.tintBorder(color)
        : surfaces.disabledBorder;
    // 前景走 tintFg：底色是同一个 color 的 alpha=18 淡底，前景再用满强度色
    // 就是同色相叠同色相，浅色模式下最高只有 2.6:1。
    final foregroundColor = enabled
        ? surfaces.tintFg(color)
        : surfaces.disabledFg;

    return GestureDetector(
      onTap: enabled ? onTap : null,
      // vertical: 10 加 16 的图标只有 36dp。同 AppChipButton，用约束补差值不改 padding。
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppTapTarget.min),
        child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 10,
        ),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: borderColor,
            width: AppBorderWidth.hairline,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: foregroundColor),
            const SizedBox(width: AppSpacing.xs),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: foregroundColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}
