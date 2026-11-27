import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';

/// 分组卡片列表（v3.0 Nordic Calm：20dp 克制圆角、极轻暖纸边界与弥散阴影）。
class AppGroupedList extends StatelessWidget {
  final List<Widget> children;
  final String? header;
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
    final surfaces = AppSurfaces.of(context);
    final caption = AppText.meta.copyWith(color: palette.text2);

    Widget result = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: surfaces.cardBorder, width: 1),
        boxShadow: surfaces.softShadow,
      ),
      child: ClipRRect(
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
      ),
    );

    if (header != null || footer != null) {
      result = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (header != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
              child: Text(header!, style: caption),
            ),
          result,
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
              child: Text(
                footer!,
                style: AppText.caption.copyWith(
                  fontSize: 12,
                  color: palette.text2,
                ),
              ),
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

class _GroupedIndex extends InheritedWidget {
  final int index;

  const _GroupedIndex({required this.index, required super.child});

  static int? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_GroupedIndex>()?.index;

  @override
  bool updateShouldNotify(_GroupedIndex oldWidget) => oldWidget.index != index;
}

class AppGroupedRow extends StatelessWidget {
  final Widget? leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final bool showChevron;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Color? titleColor;
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

  static const double _hPad = 16;
  static const double _gap = 12;
  static const double _leadingWidth = 34;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final separator = showSeparator ?? (_GroupedIndex.of(context) ?? 0) > 0;
    final textStart = leading == null ? _hPad : _hPad + _leadingWidth + _gap;

    final content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 52),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: _hPad, vertical: 11),
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
                      fontWeight: FontWeight.w500,
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
                        style: AppText.caption.copyWith(
                          fontSize: 12.5,
                          color: palette.text2,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: AppSpacing.sm),
              DefaultTextStyle.merge(
                style: AppText.caption.copyWith(
                  fontSize: 13,
                  color: palette.text2,
                ),
                child: trailing!,
              ),
            ],
            if (showChevron) ...[
              const SizedBox(width: 4),
              Icon(Icons.chevron_right_rounded, size: 19, color: palette.text3),
            ],
          ],
        ),
      ),
    );

    return CustomPaint(
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
      ..strokeWidth = 0.6;
    canvas.drawLine(Offset(start, 0.3), Offset(size.width - 16, 0.3), paint);
  }

  @override
  bool shouldRepaint(_TopSeparatorPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.start != start;
}
