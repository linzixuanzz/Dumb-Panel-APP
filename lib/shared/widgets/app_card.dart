import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';

/// 统一的卡片容器。
///
/// 替代散在业务页面里的内联「卡片形」`BoxDecoration`：
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
/// 实测总规模 **60 处**，分成两类，不要混着看：
/// - **48 个内容卡** —— 归本组件。已迁 46 处（提交 8 的 26 处无交互 +
///   提交 9 的 19 处交互态 / `ReorderableListView` key / 零内边距 +
///   提交 11 的仪表盘服务器信息卡 —— 它排到最后，是因为要先定渐变与装饰圆的去留）。
///   其余保持内联：`task_list` 任务卡与 `env_list` 环境卡那两处
///   `AnimatedContainer` + `Matrix4` transform（左滑露操作），
///   本组件既不接 `duration/curve` 也不接 `transform`，计划已裁决本期不动。
/// - **12 处淡底提示条** —— 提交 10 实际拆成了 11 + 1：
///   其中 **11 处**是真提示条，归 `AppNotice`（内部仍基于本组件）。它们用
///   `color:` / `borderColor:` 虽然也能表达，但手写 11 遍等于把本组件想消灭的
///   重复原样搬家。剩下 **1 处**（`app_lock_gate` 的生物识别面板）是 42px 大图标
///   + 居中标题 + 居中描述的竖排主视觉块，不是提示条，直接用本组件配
///   `AppSurfaces.tintBg/tintBorder`。
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
      // ⚠️ 这 1dp 不是手滑，删掉会让两个分支对同一个 padding 给出不同结果。
      //
      // 无交互分支用的是 Container：Container 在带 decoration 时会把
      // `decoration.padding`（即 `border.dimensions`，描边 1dp 就是 EdgeInsets.all(1)）
      // **并进**内边距（见 Container._paddingIncludingDecoration），所以内容实际
      // 内缩 padding + 1。有交互分支用的是 DecoratedBox，它不做这件事。
      //
      // 不补的话：同样写 padding: 16，无交互卡内容离边 17、有交互卡离边 16，
      // 且有交互卡整体小 2dp —— 而这些站点迁移前全都是 Container，等于凭空
      // 改了 10 处卡片的尺寸。`bordered: false` 时没有描边，Container 也不会加，
      // 因此这里同样不加。
      final effectivePadding = bordered
          ? padding.add(const EdgeInsets.all(AppBorderWidth.hairline))
          : padding;
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
              child: Padding(padding: effectivePadding, child: child),
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
