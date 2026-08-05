import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';

/// 统一的卡片容器。
///
/// 替代散在 20 个文件里的 43 处内联「卡片形」`BoxDecoration`：
/// ```dart
/// Container(
///   padding: const EdgeInsets.all(16),
///   decoration: BoxDecoration(
///     color: isLight ? Colors.white : AppColors.slate900,
///     borderRadius: BorderRadius.circular(14),
///     border: Border.all(color: isLight ? AppColors.slate200 : AppColors.slate800),
///   ),
///   child: ...,
/// )
/// ```
///
/// 明暗色由 [AppSurfaces] 解析，圆角走 [AppRadius]。
/// 第 1 期扁平化时改 [AppRadius] 即可，不必回到每个页面。
class AppCard extends StatelessWidget {
  final Widget child;

  /// 内边距。默认 16，与既有卡片一致。
  final EdgeInsetsGeometry padding;

  /// 外边距。默认无。
  final EdgeInsetsGeometry? margin;

  /// 圆角。默认 [AppRadius.lg]（14），与既有列表项/区块卡片一致。
  final double radius;

  /// 覆盖底色。默认走 [AppSurfaces.card]。
  final Color? color;

  /// 覆盖描边色。默认走 [AppSurfaces.cardBorder]。
  final Color? borderColor;

  /// 是否画描边。
  final bool bordered;

  final double? width;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.margin,
    this.radius = AppRadius.lg,
    this.color,
    this.borderColor,
    this.bordered = true,
    this.width,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final surfaces = AppSurfaces.of(context);
    final borderRadius = BorderRadius.circular(radius);
    final decoration = BoxDecoration(
      color: color ?? surfaces.card,
      borderRadius: borderRadius,
      border: bordered
          ? Border.all(
              color: borderColor ?? surfaces.cardBorder,
              width: AppBorderWidth.hairline,
            )
          : null,
    );

    Widget result;
    if (onTap == null && onLongPress == null) {
      result = Container(
        width: width,
        padding: padding,
        decoration: decoration,
        child: child,
      );
    } else {
      // 有交互时用 InkWell 取水波纹；底色画在 DecoratedBox 上，
      // Material 保持透明，避免把 decoration 的圆角/描边盖掉。
      result = SizedBox(
        width: width,
        child: DecoratedBox(
          decoration: decoration,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onTap,
              onLongPress: onLongPress,
              borderRadius: borderRadius,
              child: Padding(padding: padding, child: child),
            ),
          ),
        ),
      );
    }

    if (margin != null) {
      result = Padding(padding: margin!, child: result);
    }
    return result;
  }
}
