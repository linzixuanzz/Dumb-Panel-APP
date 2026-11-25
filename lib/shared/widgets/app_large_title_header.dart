import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';

/// Tab 页顶部的大标题头（方案书 §2.4）：左边 34pt 大标题，右边 1~2 个圆形玻璃按钮。
///
/// ```dart
/// AppLargeTitleHeader(
///   title: '设置',
///   actions: [AppGlassCircleButton(icon: Icons.search, tooltip: '搜索', onTap: ...)],
/// )
/// // 放进 CustomScrollView：
/// AppLargeTitleHeader.sliver(title: '日志')
/// ```
///
/// 本组件**不处理状态栏安全区**：Tab 页自己外面通常已经有 `SafeArea`，
/// 这里再套一层会让标题离顶部多一截。
class AppLargeTitleHeader extends StatelessWidget {
  final String title;

  /// 标题下方的一行说明（次要色）。
  final String? subtitle;

  /// 标题左边的头像之类（概览页的呆呆头像）。
  final Widget? leading;

  /// 右侧按钮，一般放 [AppGlassCircleButton]，按钮之间自动留 10。
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
      AppSpacing.sm,
      AppSpacing.lg,
      AppSpacing.lg,
    ),
  });

  /// 同一个头，包成 sliver 放进 `CustomScrollView`。
  static Widget sliver({
    Key? key,
    required String title,
    String? subtitle,
    Widget? leading,
    List<Widget> actions = const [],
    EdgeInsetsGeometry padding = const EdgeInsets.fromLTRB(
      AppSpacing.pageHorizontal,
      AppSpacing.sm,
      AppSpacing.lg,
      AppSpacing.lg,
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
            const SizedBox(width: AppSpacing.md),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 窄屏 + 大字号时缩小而不是换行 / 撑破：大标题只有一行
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
                    padding: const EdgeInsets.only(top: 2),
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
            if (i > 0) const SizedBox(width: 10),
            actions[i],
          ],
        ],
      ),
    );
  }
}
