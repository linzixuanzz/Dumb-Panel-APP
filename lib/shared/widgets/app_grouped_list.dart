import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';
import 'app_icon_tile.dart';

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

  // ── 行尺寸：唯一真源 ──
  // 懒加载列表（变量页、任务页「所有任务」、日志列表）不用 AppGroupedList，
  // 行是照这里手写的；它们的内边距、文字起点、分隔线一律引用下面几个常量，
  // 不要再抄数字（v3.0 把 18/36/14 改成 16/34/12 时，抄数字的三处全错开了）。

  /// 行左右内边距；分隔线右端也缩进同样的距离。
  static const double hPad = 16;

  /// leading 与标题之间的间距。
  static const double gap = 12;

  /// leading 槽宽，等于 [AppIconTile.defaultSize]。
  static const double leadingWidth = AppIconTile.defaultSize;

  /// 有 leading 时标题（以及分隔线左端）的起点。
  static const double textStart = hPad + leadingWidth + gap;

  /// 行最小高度。
  static const double minHeight = 52;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final separator = showSeparator ?? (_GroupedIndex.of(context) ?? 0) > 0;
    final start = leading == null ? hPad : textStart;

    final content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: minHeight),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: hPad, vertical: 11),
        child: Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: gap)],
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
          ? _TopSeparatorPainter(color: palette.separator, start: start)
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
    canvas.drawLine(
      Offset(start, 0.3),
      Offset(size.width - AppGroupedRow.hPad, 0.3),
      paint,
    );
  }

  @override
  bool shouldRepaint(_TopSeparatorPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.start != start;
}
