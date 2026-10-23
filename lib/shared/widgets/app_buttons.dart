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

  /// 只显示图标（文字挪进 tooltip），按钮缩成 44dp 的圆。
  /// 页头一行放不下完整形态时用（APP #21：360dp 屏上环境变量页的「＋」被挤出屏幕）。
  /// 没有 [icon] 的按钮忽略它，照常显示文字。
  final bool compact;

  const AppChipButton({
    super.key,
    required this.label,
    this.icon,
    required this.onTap,
    this.compact = false,
  });

  static const TextStyle _labelStyle = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
  );

  /// 完整形态（图标 + 文字）要占多宽，按当前字号缩放量出来。
  /// 页头据此判断一行放不放得下，放不下就切 [compact]（APP #21）。
  static double fullWidth(BuildContext context, String label) {
    return AppSpacing.md * 2 +
        16 +
        AppSpacing.xs +
        AppBorderWidth.hairline * 2 +
        measureTextWidth(context, label, _labelStyle);
  }

  @override
  Widget build(BuildContext context) {
    final surfaces = AppSurfaces.of(context);
    final iconOnly = compact && icon != null;
    final button = GestureDetector(
      // 图标形态下圆里大半是透明像素，不加 opaque 点空白处不响应。
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      // vertical: 7 加上 ~17 的内容高只有 31-32dp，够不到手指。
      // 用 minHeight 补差值而不是加大 padding：视觉密度完全不变，只是命中区变高。
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: AppTapTarget.min,
          minWidth: iconOnly ? AppTapTarget.min : 0,
        ),
        child: Container(
        alignment: Alignment.center,
        padding: iconOnly
            ? EdgeInsets.zero
            : const EdgeInsets.symmetric(
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
        child: iconOnly
            ? Icon(icon, size: 16, color: AppColors.slate400)
            : Row(
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 16, color: AppColors.slate400),
                    const SizedBox(width: AppSpacing.xs),
                  ],
                  Text(
                    label,
                    style: _labelStyle.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
        ),
      ),
    );
    // 文字没显示出来，就靠 tooltip 告诉用户这是什么（读屏也读它）。
    return iconOnly ? Tooltip(message: label, child: button) : button;
  }
}

/// 按当前主题字体和字号缩放量一段单行文字有多宽。
/// 与 [Text] 一样先叠上 [DefaultTextStyle]，量出来的才是屏幕上真实的宽度。
double measureTextWidth(BuildContext context, String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: DefaultTextStyle.of(context).style.merge(style),
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
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
