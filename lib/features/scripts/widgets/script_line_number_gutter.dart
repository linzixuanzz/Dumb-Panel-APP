import 'package:flutter/material.dart';

import '../../../core/theme/design_tokens.dart';

/// 编辑器文本的**实测**几何：每条逻辑行画在哪、任意字符下标落在哪。
///
/// ── 为什么必须实测，不能自己乘 ────────────────────────────────────────────
/// 改造前 `_scrollToMatch` 写死 `13 * 1.5`，既没算软换行（一条长行占多条视觉行）、
/// 没算 `contentPadding`，也没跟系统字体缩放挂钩，长行脚本上系统性跳偏。
/// 行号栏一旦也这么算，误差会随文件长度累积成「越往下偏得越多」；
/// 而 `fontFamily: 'monospace'` 在不同 Android ROM 上解析到的实际字体还不一样，
/// 常数根本不可能算对。
///
/// 这里用与 TextField **完全相同**的 `style` / `strutStyle` / `textScaler` /
/// 可用宽度建一个 `TextPainter`，行号和滚动定位都问它要真值。
class ScriptEditorTextMetrics {
  ScriptEditorTextMetrics._({
    required this.text,
    required this.style,
    required this.strutStyle,
    required this.textScaler,
    required this.maxWidth,
    required TextPainter painter,
    required this.lineNumbers,
    required this.lineTops,
    required this.visualLineCount,
    required this.lineHeight,
  }) : _painter = painter;

  /// 用与 TextField 同一套度量排一遍版。调用方负责在替换或销毁时调 [dispose]。
  factory ScriptEditorTextMetrics.compute({
    required String text,
    required TextStyle style,
    required StrutStyle strutStyle,
    required TextScaler textScaler,
    required double maxWidth,
    TextDirection textDirection = TextDirection.ltr,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      strutStyle: strutStyle,
      textScaler: textScaler,
      textDirection: textDirection,
    )..layout(maxWidth: maxWidth > 0 ? maxWidth : 0);

    final metrics = painter.computeLineMetrics();
    final numbers = <int>[];
    final tops = <double>[];
    var y = 0.0;
    var logical = 1;
    var startsLogicalLine = true;

    for (final line in metrics) {
      if (startsLogicalLine) {
        numbers.add(logical);
        tops.add(y);
      }
      y += line.height;
      // hardBreak 表示这条视觉行是被 '\n'（或段落结尾）断开的，下一条才是新的逻辑行。
      // 软换行的续行 hardBreak 为 false，于是不进 numbers —— 续行留空，与 VS Code 一致。
      if (line.hardBreak) {
        logical++;
        startsLogicalLine = true;
      } else {
        startsLogicalLine = false;
      }
    }

    if (numbers.isEmpty) {
      // 空文件在部分平台上一条 line metric 都不产出，行号栏仍然要显示「1」。
      numbers.add(1);
      tops.add(0);
    }

    return ScriptEditorTextMetrics._(
      text: text,
      style: style,
      strutStyle: strutStyle,
      textScaler: textScaler,
      maxWidth: maxWidth,
      painter: painter,
      lineNumbers: numbers,
      lineTops: tops,
      visualLineCount: metrics.length,
      lineHeight: metrics.isEmpty
          ? painter.preferredLineHeight
          : metrics.first.height,
    );
  }

  final String text;
  final TextStyle style;
  final StrutStyle strutStyle;
  final TextScaler textScaler;
  final double maxWidth;

  /// 要画出来的行号，与 [lineTops] 一一对应。软换行的续行不在里面。
  final List<int> lineNumbers;

  /// 每个行号的顶边 y，**不含** `contentPadding`，也不含滚动偏移。
  final List<double> lineTops;

  /// 视觉行总数（含软换行的续行）。大于 [lineNumbers] 的长度就说明发生了软换行。
  final int visualLineCount;

  /// 首条视觉行的高度。只用于「这一行还在不在视口里」的粗判。
  final double lineHeight;

  final TextPainter _painter;
  bool _disposed = false;

  /// 缓存命中判定：只有这五个输入之一变了才需要重排。
  bool matchesInput({
    required String text,
    required TextStyle style,
    required StrutStyle strutStyle,
    required TextScaler textScaler,
    required double maxWidth,
  }) {
    return !_disposed &&
        this.text == text &&
        this.style == style &&
        this.strutStyle == strutStyle &&
        this.textScaler == textScaler &&
        this.maxWidth == maxWidth;
  }

  /// 字符下标 [offset] 所在视觉行的顶边 y（不含 `contentPadding` 与滚动偏移）。
  ///
  /// 软换行也成立：搜索命中落在长行的第三条视觉行上时，拿到的就是那条续行的 y。
  /// 已被 [dispose] 时返回 null，调用方应当放弃这次滚动而不是拿脏值去 animateTo。
  double? topForOffset(int offset) {
    if (_disposed) {
      return null;
    }
    final clamped = offset < 0
        ? 0
        : (offset > text.length ? text.length : offset);
    return _painter
        .getOffsetForCaret(TextPosition(offset: clamped), Rect.zero)
        .dy;
  }

  /// `TextPainter` 持有引擎侧的 Paragraph，不释放会漏原生内存。
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _painter.dispose();
  }
}

/// 行号栏宽度：按最大行号的位数实测一次字宽，两侧各留 [AppSpacing.sm]。
///
/// 最少按两位算，否则文件从 9 行涨到 10 行时整条栏会横向跳一下。
double scriptGutterWidth({
  required int lineCount,
  required TextStyle style,
  required TextScaler textScaler,
}) {
  final digits = lineCount < 10 ? 2 : '$lineCount'.length;
  final painter = TextPainter(
    text: TextSpan(text: '0' * digits, style: style),
    textScaler: textScaler,
    textDirection: TextDirection.ltr,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width + AppSpacing.sm * 2;
}

/// 编辑器左侧的行号栏。
///
/// 与编辑器共用一个 [ScrollController]，几何全部来自 [ScriptEditorTextMetrics]，
/// 不自己算任何常数。**保留软换行**：续行留空，只在逻辑行的第一条视觉行画号。
class ScriptLineNumberGutter extends StatelessWidget {
  const ScriptLineNumberGutter({
    super.key,
    required this.width,
    required this.metrics,
    required this.scrollController,
    required this.textStyle,
    required this.strutStyle,
    required this.textScaler,
    required this.color,
    required this.verticalPadding,
  });

  final double width;
  final ScriptEditorTextMetrics metrics;
  final ScrollController scrollController;
  final TextStyle textStyle;
  final StrutStyle strutStyle;
  final TextScaler textScaler;
  final Color color;

  /// 必须等于 TextField 的 `contentPadding` 上下值。
  ///
  /// TextField 的可滚动视口是从 `contentPadding` **之内**开始的（padding 由
  /// InputDecorator 画在滚动区之外），行号栏用同一个起点与同一个高度，
  /// 滚出去的行号才会和滚出去的代码在同一条边界上消失。
  final double verticalPadding;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: verticalPadding),
        child: ClipRect(
          child: AnimatedBuilder(
            animation: scrollController,
            builder: (context, _) {
              final offset = scrollController.hasClients
                  ? scrollController.offset
                  : 0.0;
              return CustomPaint(
                painter: _ScriptLineNumberPainter(
                  lineNumbers: metrics.lineNumbers,
                  lineTops: metrics.lineTops,
                  lineHeight: metrics.lineHeight,
                  scrollOffset: offset,
                  style: textStyle.copyWith(color: color),
                  strutStyle: strutStyle,
                  textScaler: textScaler,
                  rightPadding: AppSpacing.sm,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ScriptLineNumberPainter extends CustomPainter {
  const _ScriptLineNumberPainter({
    required this.lineNumbers,
    required this.lineTops,
    required this.lineHeight,
    required this.scrollOffset,
    required this.style,
    required this.strutStyle,
    required this.textScaler,
    required this.rightPadding,
  });

  final List<int> lineNumbers;
  final List<double> lineTops;
  final double lineHeight;
  final double scrollOffset;
  final TextStyle style;
  final StrutStyle strutStyle;
  final TextScaler textScaler;
  final double rightPadding;

  @override
  void paint(Canvas canvas, Size size) {
    final maxTextWidth = size.width - rightPadding;
    if (maxTextWidth <= 0) {
      return;
    }
    // 整个 paint 复用同一个 painter，只换 text 重排：滚动时每帧都会走到这里，
    // 一行一个 TextPainter 的话每帧要多几十次原生 Paragraph 分配。
    final painter = TextPainter(
      textScaler: textScaler,
      strutStyle: strutStyle,
      textDirection: TextDirection.ltr,
    );
    for (var i = 0; i < lineNumbers.length; i++) {
      final dy = lineTops[i] - scrollOffset;
      // 滚出视口上沿的跳过；lineTops 单调递增，越过下沿就可以整体收工。
      if (dy + lineHeight < 0) {
        continue;
      }
      if (dy > size.height) {
        break;
      }
      painter
        ..text = TextSpan(text: '${lineNumbers[i]}', style: style)
        ..layout(maxWidth: maxTextWidth);
      painter.paint(canvas, Offset(maxTextWidth - painter.width, dy));
    }
    painter.dispose();
  }

  @override
  bool shouldRepaint(covariant _ScriptLineNumberPainter oldDelegate) {
    return oldDelegate.scrollOffset != scrollOffset ||
        !identical(oldDelegate.lineTops, lineTops) ||
        oldDelegate.style != style ||
        oldDelegate.strutStyle != strutStyle ||
        oldDelegate.textScaler != textScaler ||
        oldDelegate.rightPadding != rightPadding;
  }
}
