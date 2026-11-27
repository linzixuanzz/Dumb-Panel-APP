import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';

/// 页面顶部轻盈标题头（v3.0 Nordic Calm：23pt w600 克制标题 + 44dp 精致玻璃圆钮）。
class AppLargeTitleHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> actions;
  final EdgeInsetsGeometry padding;

  const AppLargeTitleHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.actions = const [],
    this.padding = const EdgeInsets.fromLTRB(
      AppSpacing.pageHorizontal,
      AppSpacing.md,
      AppSpacing.lg,
      AppSpacing.md,
    ),
  });

  static Widget sliver({
    Key? key,
    required String title,
    String? subtitle,
    Widget? leading,
    List<Widget> actions = const [],
    EdgeInsetsGeometry padding = const EdgeInsets.fromLTRB(
      AppSpacing.pageHorizontal,
      AppSpacing.md,
      AppSpacing.lg,
      AppSpacing.md,
    ),
  }) {
    return SliverToBoxAdapter(
      child: AppLargeTitleHeader(
        key: key,
        title: title,
        subtitle: subtitle,
        leading: leading,
        actions: actions,
        padding: padding,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: AppSpacing.sm),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title,
                    maxLines: 1,
                    style: AppText.largeTitle.copyWith(color: palette.text),
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(color: palette.text2),
                    ),
                  ),
              ],
            ),
          ),
          for (var i = 0; i < actions.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            actions[i],
          ],
        ],
      ),
    );
  }
}
