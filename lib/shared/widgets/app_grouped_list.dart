import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';

/// 分组列表（方案书 §2.4）：白色大圆角容器，行与行之间是缩进的发丝分隔线。
/// 用在「所有任务」、变量、设置。
///
/// ```dart
/// AppGroupedList(
///   header: '面板',
///   children: [
///     AppGroupedRow(
///       leading: AppIconTile(icon: Icons.dns_rounded, color: palette.accent, solid: true),
///       title: '服务器管理',
///       trailing: Text('2 个面板'),
///       showChevron: true,
///       onTap: ...,
///     ),
///     AppGroupedRow(title: '应用锁', onTap: ...),
///   ],
/// )
/// ```
///
/// 分隔线由 [AppGroupedRow] 自己画在**顶部**（第一行不画），缩进到 leading 之后，
/// 所以混进去的非 [AppGroupedRow] 子组件不会自动带分隔线。
class AppGroupedList extends StatelessWidget {
  final List<Widget> children;

  /// 容器上方的小标题（次要色说明字号），如「面板」「外观」。
  final String? header;

  /// 容器下方的说明文字。
  final String? footer;

  final EdgeInsetsGeometry? margin;

  const AppGroupedList({
    super.key,
    required this.children,
    this.header,
    this.footer,
    this.margin,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final caption = AppText.caption.copyWith(color: palette.text2);

    Widget result = ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: ColoredBox(
        color: palette.card,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < children.length; i++)
              _GroupedIndex(index: i, child: children[i]),
          ],
        ),
      ),
    );

    if (header != null || footer != null) {
      result = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (header != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                header!,
                style: caption.copyWith(fontWeight: FontWeight.w500),
              ),
            ),
          result,
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text(footer!, style: caption),
            ),
        ],
      );
    }
    if (margin != null) {
      result = Padding(padding: margin!, child: result);
    }
    return result;
  }
}

/// 告诉行「我是第几行」：第一行不画分隔线。
class _GroupedIndex extends InheritedWidget {
  final int index;

  const _GroupedIndex({required this.index, required super.child});

  static int? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_GroupedIndex>()?.index;

  @override
  bool updateShouldNotify(_GroupedIndex oldWidget) => oldWidget.index != index;
}

/// 分组列表里的一行。
class AppGroupedRow extends StatelessWidget {
  /// 前导，一般是 [AppIconTile]（默认 36dp，分隔线据此缩进）。
  final Widget? leading;
  final String title;
  final String? subtitle;

  /// 右侧：值文字、开关、等宽数字……
  final Widget? trailing;

  /// 最右边的 `>`。可点进下一级的行打开它。
  final bool showChevron;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 标题颜色覆盖（危险操作行用 `palette.errInk`）。
  final Color? titleColor;

  /// 是否画顶部分隔线。默认按在 [AppGroupedList] 里的位置决定（第一行不画）；
  /// 自己用 `ListView.builder` 懒加载拼分组时没有 [AppGroupedList]，就传 `index > 0`。
  final bool? showSeparator;

  const AppGroupedRow({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.showChevron = false,
    this.onTap,
    this.onLongPress,
    this.titleColor,
    this.showSeparator,
  });

  /// 行左右内边距与 leading 和文字的间距，分隔线缩进按它们算。
  static const double _hPad = 18;
  static const double _gap = 14;
  static const double _leadingWidth = 36;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final separator = showSeparator ?? (_GroupedIndex.of(context) ?? 0) > 0;
    final textStart = leading == null ? _hPad : _hPad + _leadingWidth + _gap;

    final content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: _hPad, vertical: 12),
        child: Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: _gap)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.body.copyWith(
                      fontWeight: FontWeight.w600,
                      color: titleColor ?? palette.text,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.caption.copyWith(color: palette.text2),
                      ),
                    ),
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: AppSpacing.sm),
              // 右侧值文字默认次要色
              DefaultTextStyle.merge(
                style: AppText.caption.copyWith(
                  fontSize: 15,
                  color: palette.text2,
                ),
                child: trailing!,
              ),
            ],
            if (showChevron) ...[
              const SizedBox(width: 4),
              Icon(Icons.chevron_right_rounded, size: 22, color: palette.text3),
            ],
          ],
        ),
      ),
    );

    return CustomPaint(
      // 顶部分隔线：第一行不画；从文字起点画到最右边（iOS 的缩进分隔线）。
      foregroundPainter: separator
          ? _TopSeparatorPainter(color: palette.separator, start: textStart)
          : null,
      child: onTap == null && onLongPress == null
          ? content
          : Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: onTap,
                onLongPress: onLongPress,
                child: content,
              ),
            ),
    );
  }
}

class _TopSeparatorPainter extends CustomPainter {
  final Color color;
  final double start;

  const _TopSeparatorPainter({required this.color, required this.start});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 0.5;
    canvas.drawLine(Offset(start, 0.25), Offset(size.width, 0.25), paint);
  }

  @override
  bool shouldRepaint(_TopSeparatorPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.start != start;
}
