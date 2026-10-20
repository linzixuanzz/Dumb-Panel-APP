import 'package:daidai_app/features/scripts/widgets/script_line_number_gutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// APP issue #18-1：3000+ 行脚本打开编辑器明显卡顿。
///
/// 改造前行号栏每次文本变化都用第二个 TextPainter 对全文 layout + computeLineMetrics，
/// 与 TextField 自己的排版重复；光标 / 选区一动整块重建并 O(n) 数一遍总行数。
/// 现在行号直接问 TextField 自己的 RenderEditable，只问视口附近几行。
///
/// 下面钉两件事：
/// 1. 行号仍与文字对齐（软换行、中文行、空行都对）—— 拿独立排一遍版的
///    [ScriptEditorTextMetrics] 当对照基准；
/// 2. 3000+ 行文本里移动光标不重扫、不问几何；敲一个字只重扫一次行首，
///    问几何的次数与全文长度无关。

// 与编辑器页 `_editorTextStyle` 同一套钉死的字段：TextField 会把 style 合并到主题上，
// 不钉死的话对照基准和 TextField 量的就不是同一件事。
const _style = TextStyle(
  fontSize: 13,
  fontFamily: 'monospace',
  height: 1.5,
  fontWeight: FontWeight.w400,
  fontStyle: FontStyle.normal,
  letterSpacing: 0,
  wordSpacing: 0,
  textBaseline: TextBaseline.alphabetic,
  leadingDistribution: TextLeadingDistribution.even,
  color: Colors.black,
);
final _strut = StrutStyle.fromTextStyle(_style, forceStrutHeight: true);

/// RenderEditable 的 `_caretMargin`（光标间隙 1 + 默认光标宽 2）：多行输入框的断行宽度。
const _caretMargin = 3.0;

class _Harness {
  _Harness(String text) : controller = TextEditingController(text: text);

  final TextEditingController controller;
  final ScrollController scroll = ScrollController();
  final GlobalKey editorKey = GlobalKey();

  Widget build() {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 360,
            height: 600,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ScriptLineNumberGutter(
                  controller: controller,
                  editorKey: editorKey,
                  editorWidth: 360,
                  scrollController: scroll,
                  textStyle: _style,
                  strutStyle: _strut,
                  textScaler: TextScaler.noScaling,
                  color: Colors.grey,
                  verticalPadding: 14,
                ),
                Expanded(
                  child: TextField(
                    key: editorKey,
                    controller: controller,
                    scrollController: scroll,
                    expands: true,
                    maxLines: null,
                    style: _style,
                    strutStyle: _strut,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.all(14),
                      filled: false,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  RenderEditable get editable =>
      findScriptRenderEditable(editorKey.currentContext)!;

  List<(int, double)> visibleLines() => scriptVisibleGutterLines(
    editable: editable,
    lineStarts: scriptLineStarts(controller.text),
    viewportHeight: editable.size.height,
  );

  /// 独立排一遍版的对照基准（就是改造前的做法）。
  ScriptEditorTextMetrics reference() => ScriptEditorTextMetrics.compute(
    text: controller.text,
    style: _style,
    strutStyle: _strut,
    textScaler: TextScaler.noScaling,
    maxWidth: editable.size.width - _caretMargin,
  );
}

/// 断言视口里的行号与对照基准逐行一致（行号相同、y 相差不到 1 个逻辑像素）。
void _expectAligned(_Harness h) {
  final ref = h.reference();
  final scroll = h.scroll.offset;
  final lines = h.visibleLines();
  expect(lines, isNotEmpty);
  final first = ref.lineNumbers.indexOf(lines.first.$1);
  expect(first, greaterThanOrEqualTo(0));
  for (var i = 0; i < lines.length; i++) {
    final (number, dy) = lines[i];
    expect(number, ref.lineNumbers[first + i]);
    expect(
      dy,
      closeTo(ref.lineTops[first + i] - scroll, 1.0),
      reason: '第 $number 行',
    );
  }
  ref.dispose();
}

void main() {
  testWidgets('软换行、中文行、空行、结尾换行：行号与 TextField 的文字逐行对齐', (tester) async {
    final text = [
      'short',
      '',
      '// 中文注释一行，中文注释一行',
      List.filled(60, 'word').join(' '),
      'after_wrap',
      '',
      'end',
      '',
    ].join('\n');
    final h = _Harness(text);
    await tester.pumpWidget(h.build());

    final ref = h.reference();
    // 确实发生了软换行，否则这条用例没在测软换行。
    expect(ref.visualLineCount, greaterThan(ref.lineNumbers.length));
    ref.dispose();

    // 8 条逻辑行，最后一条是结尾换行后的空行。
    expect(h.visibleLines().map((l) => l.$1), [1, 2, 3, 4, 5, 6, 7, 8]);
    _expectAligned(h);

    // 搜索滚动用的 y：落在长行第三条视觉行上的下标，拿到的是那条续行的 y。
    final mid = text.indexOf('word') + 4 * 50;
    final ref2 = h.reference();
    expect(
      scriptContentTopForOffset(h.editable, mid),
      closeTo(ref2.topForOffset(mid)!, 1.0),
    );
    ref2.dispose();
  });

  testWidgets('3000+ 行：移动光标不重扫不问几何，敲一个字只问视口附近几行，滚动后仍对齐', (tester) async {
    final text = List.generate(
      3200,
      (i) => i % 7 == 0 ? '// 第 $i 行中文注释' : 'const value$i = $i;',
    ).join('\n');
    final h = _Harness(text);
    await tester.pumpWidget(h.build());
    _expectAligned(h);

    // 移动光标 / 改选区：行首不重扫、行号栏不重画（一次几何都不问）。
    ScriptLineNumberGutter.debugLineIndexBuilds = 0;
    ScriptLineNumberGutter.debugGeometryQueries = 0;
    for (final offset in [10, 500, 4000]) {
      h.controller.selection = TextSelection.collapsed(offset: offset);
      await tester.pump();
    }
    h.controller.selection = const TextSelection(
      baseOffset: 20,
      extentOffset: 900,
    );
    await tester.pump();
    expect(ScriptLineNumberGutter.debugLineIndexBuilds, 0);
    expect(ScriptLineNumberGutter.debugGeometryQueries, 0);

    // 敲一个字符：只重扫一次行首；问几何的次数是「二分 + 一屏」级别，与 3200 行无关。
    ScriptLineNumberGutter.debugGeometryQueries = 0;
    final value = h.controller.value;
    h.controller.value = TextEditingValue(
      text: '${value.text.substring(0, 5)}x${value.text.substring(5)}',
      selection: const TextSelection.collapsed(offset: 6),
    );
    await tester.pump();
    expect(ScriptLineNumberGutter.debugLineIndexBuilds, 1);
    expect(ScriptLineNumberGutter.debugGeometryQueries, greaterThan(0));
    expect(ScriptLineNumberGutter.debugGeometryQueries, lessThan(120));
    _expectAligned(h);

    // 敲一个换行：行数变了，后面的行号跟着挪。
    h.controller.value = TextEditingValue(
      text: '\n${h.controller.text}',
      selection: const TextSelection.collapsed(offset: 1),
    );
    await tester.pump();
    expect(ScriptLineNumberGutter.debugLineIndexBuilds, 2);
    _expectAligned(h);

    // 滚到中间：只画视口里那几行，且仍然对齐。
    ScriptLineNumberGutter.debugGeometryQueries = 0;
    h.scroll.jumpTo(h.scroll.position.maxScrollExtent / 2);
    await tester.pump();
    expect(ScriptLineNumberGutter.debugGeometryQueries, lessThan(120));
    final lines = h.visibleLines();
    expect(lines.first.$1, greaterThan(1000));
    _expectAligned(h);
  });
}
