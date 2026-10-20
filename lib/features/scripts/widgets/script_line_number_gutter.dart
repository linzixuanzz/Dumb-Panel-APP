import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

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
///
/// ⚠️ 编辑器页**已不再用它**（APP issue #18）：它要对全文再排一次版，和 TextField
/// 自己的排版重复，3000+ 行脚本每敲一个字符都多一次整篇 layout，打字明显卡。
/// 现在行号直接问 TextField 自己的 `RenderEditable`（见 [ScriptLineNumberGutter]）。
/// 这里留作「独立排一遍版」的对照基准，测试拿它校验行号栏有没有对齐。
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

/// 逻辑行首下标：第 i 行从 `text[result[i]]` 开始，长度就是总行数
/// （与 `lineNumberForOffset(text, text.length)` 同口径）。
///
/// 只扫一遍码元、不排版，3000 行也就零点几毫秒；而且只在**文本真的变了**时才调。
List<int> scriptLineStarts(String text) {
  final starts = <int>[0];
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) {
      starts.add(i + 1);
    }
  }
  return starts;
}

/// 在编辑器 TextField 的子树里找到它自己用来排版的 [RenderEditable]。
///
/// [context] 传挂在 TextField 上那个 GlobalKey 的 `currentContext`；
/// 还没挂上或已经卸载时返回 null，调用方这次就别画 / 别滚。
RenderEditable? findScriptRenderEditable(BuildContext? context) {
  final root = context?.findRenderObject();
  if (root == null || !root.attached) {
    return null;
  }
  RenderEditable? found;
  void visit(RenderObject node) {
    if (found != null) {
      return;
    }
    if (node is RenderEditable) {
      found = node;
      return;
    }
    node.visitChildren(visit);
  }

  visit(root);
  return found;
}

/// 字符下标 [offset] 所在视觉行的顶边 y：内容坐标系，**不含** `contentPadding`、
/// 也不含滚动偏移。软换行也成立（落在长行第三条视觉行上就给那条续行的 y）。
///
/// 问的是 TextField **自己那份**排版，不另起 TextPainter。光标矩形在各平台上有一段
/// 固定的上下偏移（Android 扣 `_kCaretHeightOffset`、iOS 居中），而
/// `forceStrutHeight` 下每条视觉行一样高，这段偏移处处相同 —— 拿第 0 个字符的
/// 光标顶边当 0 点减掉，剩下的就是行顶；两者都带着同一个滚动偏移，相减也一并消掉。
double scriptContentTopForOffset(RenderEditable editable, int offset) {
  ScriptLineNumberGutter.debugGeometryQueries++;
  final length = editable.plainText.length;
  final clamped = offset < 0 ? 0 : (offset > length ? length : offset);
  final top = editable.getLocalRectForCaret(TextPosition(offset: clamped)).top;
  final origin = editable
      .getLocalRectForCaret(const TextPosition(offset: 0))
      .top;
  return top - origin;
}

/// 视口里要画的行号：`(行号, 顶边在视口里的 y)`。软换行的续行不画号。
///
/// 只问视口附近几行的几何：行顶随行号单调递增，先二分找到第一条露出来的逻辑行，
/// 再往下数到越过视口下沿为止。一次大约「十几次二分 + 一屏行数」次查询，
/// 与全文多长无关 —— 这是 APP issue #18 卡顿的关键：不再对全文另排一遍版。
List<(int, double)> scriptVisibleGutterLines({
  required RenderEditable editable,
  required List<int> lineStarts,
  required double viewportHeight,
}) {
  if (!editable.hasSize || lineStarts.isEmpty) {
    return const [];
  }
  final scroll = editable.offset.hasPixels ? editable.offset.pixels : 0.0;
  final lineHeight = editable.preferredLineHeight;
  // 找第一条「首条视觉行的下沿还在视口上沿之下」的逻辑行。
  var lo = 0;
  var hi = lineStarts.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (scriptContentTopForOffset(editable, lineStarts[mid]) + lineHeight >
        scroll) {
      hi = mid;
    } else {
      lo = mid + 1;
    }
  }
  final lines = <(int, double)>[];
  for (var i = lo; i < lineStarts.length; i++) {
    final dy = scriptContentTopForOffset(editable, lineStarts[i]) - scroll;
    if (dy > viewportHeight) {
      break;
    }
    lines.add((i + 1, dy));
  }
  return lines;
}

/// 编辑器左侧的行号栏。
///
/// 几何全部问编辑器 TextField 自己的 [RenderEditable]，不自己算任何常数，
/// 也**不再另排一遍全文**（APP issue #18：3000+ 行脚本每敲一个字符都多一次整篇
/// layout，打字明显卡）。**保留软换行**：续行留空，只在逻辑行的第一条视觉行画号。
///
/// 自己监听 [controller]，但只在**文本真的变了**时重扫行首、重建；光标移动、改选区、
/// 输入法组合都会通知过来，那些一律不理。滚动只触发重画（不重建）。
class ScriptLineNumberGutter extends StatefulWidget {
  const ScriptLineNumberGutter({
    super.key,
    required this.controller,
    required this.editorKey,
    required this.scrollController,
    required this.textStyle,
    required this.strutStyle,
    required this.textScaler,
    required this.color,
    required this.verticalPadding,
    required this.editorWidth,
  });

  final TextEditingController controller;

  /// 挂在编辑器 TextField 上的 key，用来找它的 [RenderEditable]。
  final GlobalKey editorKey;
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

  /// 编辑器卡片的宽度。宽度一变 TextField 会重新断行，行号要跟着重画。
  final double editorWidth;

  /// 测试用计数：重扫行首的次数 / 问几何的次数。用来钉住「移动光标不重扫、
  /// 打一个字只问视口附近几行」，别让整篇重算悄悄回来。
  @visibleForTesting
  static int debugLineIndexBuilds = 0;
  @visibleForTesting
  static int debugGeometryQueries = 0;

  @override
  State<ScriptLineNumberGutter> createState() => _ScriptLineNumberGutterState();
}

class _ScriptLineNumberGutterState extends State<ScriptLineNumberGutter> {
  late String _text;
  late List<int> _lineStarts;

  @override
  void initState() {
    super.initState();
    _text = widget.controller.text;
    _lineStarts = scriptLineStarts(_text);
    ScriptLineNumberGutter.debugLineIndexBuilds++;
    widget.controller.addListener(_handleControllerChanged);
  }

  @override
  void didUpdateWidget(covariant ScriptLineNumberGutter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerChanged);
      widget.controller.addListener(_handleControllerChanged);
      _handleControllerChanged();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    super.dispose();
  }

  void _handleControllerChanged() {
    final text = widget.controller.text;
    // 光标 / 选区 / 输入法组合变化时文本不变，什么都不做：不重扫、不重建。
    if (text == _text) {
      return;
    }
    _text = text;
    ScriptLineNumberGutter.debugLineIndexBuilds++;
    setState(() => _lineStarts = scriptLineStarts(text));
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: scriptGutterWidth(
        lineCount: _lineStarts.length,
        style: widget.textStyle,
        textScaler: widget.textScaler,
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: widget.verticalPadding),
        // RepaintBoundary 不能省：没有它，行号栏和 TextField 落在同一个重绘层里，
        // 光标闪烁、移动光标、改选区引起的编辑器重绘都会连带重画行号栏、重新问几何。
        child: RepaintBoundary(
          child: ClipRect(
            child: CustomPaint(
              painter: _ScriptLineNumberPainter(
                editorKey: widget.editorKey,
                lineStarts: _lineStarts,
                editorWidth: widget.editorWidth,
                style: widget.textStyle.copyWith(color: widget.color),
                strutStyle: widget.strutStyle,
                textScaler: widget.textScaler,
                rightPadding: AppSpacing.sm,
                // 滚动只重画：画的时候现问 RenderEditable 的滚动偏移。
                repaint: widget.scrollController,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ScriptLineNumberPainter extends CustomPainter {
  _ScriptLineNumberPainter({
    required this.editorKey,
    required this.lineStarts,
    required this.editorWidth,
    required this.style,
    required this.strutStyle,
    required this.textScaler,
    required this.rightPadding,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final GlobalKey editorKey;
  final List<int> lineStarts;
  final double editorWidth;
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
    // paint 发生在整棵树 layout 之后，这时 TextField 这一帧的排版已经就绪。
    final editable = findScriptRenderEditable(editorKey.currentContext);
    if (editable == null) {
      return;
    }
    final lines = scriptVisibleGutterLines(
      editable: editable,
      lineStarts: lineStarts,
      viewportHeight: size.height,
    );
    // 整个 paint 复用同一个 painter，只换 text 重排：滚动时每帧都会走到这里，
    // 一行一个 TextPainter 的话每帧要多几十次原生 Paragraph 分配。
    final painter = TextPainter(
      textScaler: textScaler,
      strutStyle: strutStyle,
      textDirection: TextDirection.ltr,
    );
    for (final (number, dy) in lines) {
      painter
        ..text = TextSpan(text: '$number', style: style)
        ..layout(maxWidth: maxTextWidth);
      painter.paint(canvas, Offset(maxTextWidth - painter.width, dy));
    }
    painter.dispose();
  }

  @override
  bool shouldRepaint(covariant _ScriptLineNumberPainter oldDelegate) {
    return !identical(oldDelegate.lineStarts, lineStarts) ||
        oldDelegate.editorWidth != editorWidth ||
        oldDelegate.style != style ||
        oldDelegate.strutStyle != strutStyle ||
        oldDelegate.textScaler != textScaler ||
        oldDelegate.rightPadding != rightPadding;
  }
}
