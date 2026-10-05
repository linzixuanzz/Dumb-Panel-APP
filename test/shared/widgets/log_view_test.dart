import 'package:daidai_app/shared/utils/log_line_buffer.dart';
import 'package:daidai_app/shared/widgets/log_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

List<String> _lines(int from, int count) =>
    List<String>.generate(count, (i) => 'line ${from + i}');

/// 13 号字、1.5 倍行高：每行 19.5 像素，测试视口 800x600 一屏约 30 行。
const _style = TextStyle(fontSize: 13, height: 1.5, color: Colors.black);

Future<LogLineBuffer> _pumpLogView(
  WidgetTester tester, {
  required List<String> initial,
  int maxLines = kLogBufferMaxLines,
  bool follow = true,
}) async {
  final buffer = LogLineBuffer(maxLines: maxLines)..replaceAll(initial);
  addTearDown(buffer.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: LogView(
          buffer: buffer,
          follow: follow,
          textStyle: _style,
          brightness: Brightness.light,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return buffer;
}

ScrollPosition _position(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable)).position;

void _expectAtBottom(WidgetTester tester) {
  final position = _position(tester);
  expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
}

/// 手指往下拖 = 内容往上翻。
Future<void> _scrollUp(WidgetTester tester, double distance) async {
  await tester.drag(find.byType(CustomScrollView), Offset(0, distance));
  await tester.pumpAndSettle();
}

final _backToBottom = find.byTooltip('回到底部');

/// 下方列表（锚点及之后的行）外面那层 SliverPadding，key 是 `log-below-<重建代号>`。
final _belowSliver = find.byWidgetPredicate(
  (widget) =>
      widget is SliverPadding &&
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith('log-below-'),
  skipOffstage: false,
);

/// 下方列表现在放了多少行。
int _belowChildCount(WidgetTester tester) {
  final list = tester.widget<SliverList>(
    find.descendant(
      of: _belowSliver,
      matching: find.byType(SliverList, skipOffstage: false),
      skipOffstage: false,
    ),
  );
  return (list.delegate as SliverChildBuilderDelegate).childCount!;
}

/// 下方列表的 key。变了说明走的是「回到底部」重建，没变说明是原地滑锚点。
String _belowKey(WidgetTester tester) =>
    (tester.widget<SliverPadding>(_belowSliver).key! as ValueKey<String>).value;

/// 「回到底部」重建一帧的排版上限：新列表要从尾段窗口（200 行）的第一行排到底，
/// 这是 #10 就定下的代价（只排这 200 行，而不是跳过的几千行）。
const _rebuildLayoutLimit = 210;

/// 推一帧，顺便数这一帧里段落（RenderParagraph）真正排版的次数。
///
/// debugPrintLayouts 只在真的执行布局时打印，次数与机器快慢、编译模式都无关，
/// 拿它当「一帧里排了多少行」的尺子，比计时断言稳定。
Future<int> _pumpCountingLayouts(WidgetTester tester) async {
  var count = 0;
  final savedDebugPrint = debugPrint;
  debugPrintLayouts = true;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null &&
        message.startsWith('Laying out') &&
        message.contains('RenderParagraph')) {
      count++;
    }
  };
  try {
    await tester.pump(const Duration(milliseconds: 16));
  } finally {
    debugPrint = savedDebugPrint;
    debugPrintLayouts = false;
  }
  return count;
}

/// 连推几帧（含贴底跳转后补的那一帧），返回每一帧的排版次数。
Future<List<int>> _pumpFramesCountingLayouts(
  WidgetTester tester, {
  int frames = 3,
}) async {
  final counts = <int>[];
  for (var i = 0; i < frames; i++) {
    counts.add(await _pumpCountingLayouts(tester));
  }
  return counts;
}

/// 当前选中的文字，按段落收集（点一下落下的光标那种空选区不算）。
List<String> _selectedTexts(WidgetTester tester) {
  final texts = <String>[];
  void visit(RenderObject object) {
    if (object is RenderParagraph) {
      final plain = object.text.toPlainText(includeSemanticsLabels: false);
      for (final selection in object.selections) {
        if (!selection.isCollapsed) {
          texts.add(selection.textInside(plain));
        }
      }
    }
    object.visitChildren(visit);
  }

  for (final view in tester.binding.renderViews) {
    visit(view);
  }
  return texts;
}

/// issue #10：运行中的日志只有停在底部时才跟着往下走；上翻看的时候不被拉回；
/// 回到底部恢复跟随；几万行不卡。
void main() {
  testWidgets('打开时定位到最新一行', (tester) async {
    await _pumpLogView(tester, initial: _lines(0, 300));

    _expectAtBottom(tester);
    expect(find.text('line 299'), findsOneWidget);
    expect(_backToBottom, findsNothing);
  });

  testWidgets('停在底部时，新日志到来自动跟随到底', (tester) async {
    final buffer = await _pumpLogView(tester, initial: _lines(0, 300));

    buffer.append(_lines(300, 50));
    await tester.pumpAndSettle();

    _expectAtBottom(tester);
    expect(find.text('line 349'), findsOneWidget);
  });

  testWidgets('离底部只差一点点（容差以内）仍算在底部，继续跟随', (tester) async {
    final buffer = await _pumpLogView(tester, initial: _lines(0, 300));

    // 拖动的前 20 像素被触摸判定吃掉，实际只滚动约 20 像素，在容差以内。
    await _scrollUp(tester, 40);
    expect(_backToBottom, findsNothing);

    buffer.append(_lines(300, 20));
    await tester.pumpAndSettle();

    _expectAtBottom(tester);
    expect(find.text('line 319'), findsOneWidget);
  });

  testWidgets('上翻之后新日志不会把视图拉走，眼前的行纹丝不动', (tester) async {
    final buffer = await _pumpLogView(tester, initial: _lines(0, 300));

    await _scrollUp(tester, 300);
    expect(_backToBottom, findsOneWidget, reason: '上翻时要给出回到底部的入口');
    final pixelsBefore = _position(tester).pixels;
    final anchorLine = find.text('line 270');
    expect(anchorLine, findsOneWidget);
    final anchorTopBefore = tester.getTopLeft(anchorLine).dy;

    buffer.append(_lines(300, 100));
    await tester.pumpAndSettle();

    expect(_position(tester).pixels, pixelsBefore);
    expect(tester.getTopLeft(anchorLine).dy, anchorTopBefore);
    expect(find.text('line 399'), findsNothing, reason: '没有被拉到底部');
    expect(_backToBottom, findsOneWidget);
  });

  testWidgets('点「回到底部」回到最新一行，之后恢复跟随', (tester) async {
    final buffer = await _pumpLogView(tester, initial: _lines(0, 300));
    await _scrollUp(tester, 300);
    buffer.append(_lines(300, 100));
    await tester.pumpAndSettle();

    await tester.tap(_backToBottom);
    await tester.pumpAndSettle();

    _expectAtBottom(tester);
    expect(find.text('line 399'), findsOneWidget);
    expect(_backToBottom, findsNothing);

    buffer.append(_lines(400, 20));
    await tester.pumpAndSettle();

    _expectAtBottom(tester);
    expect(find.text('line 419'), findsOneWidget);
  });

  testWidgets('手动滚回底部同样恢复跟随', (tester) async {
    final buffer = await _pumpLogView(tester, initial: _lines(0, 300));
    await _scrollUp(tester, 300);
    buffer.append(_lines(300, 10));
    await tester.pumpAndSettle();

    await _scrollUp(tester, -2000);
    expect(_backToBottom, findsNothing);

    buffer.append(_lines(310, 20));
    await tester.pumpAndSettle();

    _expectAtBottom(tester);
    expect(find.text('line 329'), findsOneWidget);
  });

  testWidgets('上翻期间超过上限也先不裁剪，眼前的内容不会被往上推', (tester) async {
    final buffer = await _pumpLogView(
      tester,
      initial: _lines(0, 300),
      maxLines: 400,
    );
    await _scrollUp(tester, 300);
    final anchorLine = find.text('line 270');
    final anchorTopBefore = tester.getTopLeft(anchorLine).dy;

    buffer.append(_lines(300, 200));
    await tester.pumpAndSettle();

    expect(buffer.droppedCount, 0, reason: '翻看期间暂缓裁剪');
    expect(tester.getTopLeft(anchorLine).dy, anchorTopBefore);
  });

  testWidgets('跟随时超长只保留最近部分，并提示更早的行未显示', (tester) async {
    final buffer = await _pumpLogView(
      tester,
      initial: _lines(0, 300),
      maxLines: 400,
    );

    buffer.append(_lines(300, 200));
    await tester.pumpAndSettle();

    expect(buffer.length, 400);
    expect(buffer.droppedCount, 100);
    _expectAtBottom(tester);
    expect(find.text('line 499'), findsOneWidget);
    // 提示条在内容最上方，这时不在屏幕内，但已经挂在树上。
    expect(
      find.textContaining('更早的 100 行未显示', skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('几万行的日志只构建屏幕附近的行，不会一次性铺开', (tester) async {
    final buffer = await _pumpLogView(tester, initial: _lines(0, 50000));

    expect(buffer.length, kLogBufferMaxLines);
    expect(buffer.droppedCount, 50000 - kLogBufferMaxLines);
    _expectAtBottom(tester);
    expect(find.text('line 49999'), findsOneWidget);

    // 改造前是整段拼成一个 SelectableText；现在树上只有视口附近的几十行。
    final built = tester
        .widgetList(find.textContaining('line ', skipOffstage: false))
        .length;
    expect(built, lessThan(100));

    // 继续往里追加也只动末尾，照样跟随。
    buffer.append(_lines(50000, 500));
    await tester.pumpAndSettle();
    _expectAtBottom(tester);
    expect(find.text('line 50499'), findsOneWidget);
  });

  testWidgets('静态日志（面板日志）从顶部开始，没有跟随与回到底部按钮', (tester) async {
    await _pumpLogView(tester, initial: _lines(0, 300), follow: false);

    expect(_position(tester).pixels, 0);
    expect(find.text('line 0'), findsOneWidget);

    await _scrollUp(tester, -300);
    expect(_backToBottom, findsNothing);
  });

  // APP #15：运行中的日志是 SSE 一行一行追加的，打开时整段历史会一下子涌进来。
  // 以前跟随时锚点不动、新行全接在下方列表末尾，贴底一跳要把跳过的每一行都排一遍版；
  // 现在锚点随尾部滑动，下方列表始终只放最后 200 行，一帧只重排屏幕附近那几十行。
  group('跟随时锚点随尾部滑动（APP #15）', () {
    testWidgets('一次整批涌入 5000 行：下方列表只留最后 200 行，不在一帧里排几千行', (tester) async {
      final buffer = await _pumpLogView(tester, initial: _lines(0, 300));

      buffer.append(_lines(300, 5000));
      final layouts = await _pumpFramesCountingLayouts(tester);

      expect(_belowChildCount(tester), lessThanOrEqualTo(200));
      _expectAtBottom(tester);
      expect(find.text('line 5299'), findsOneWidget);
      // 一屏约 30 行，加上下缓存区也就几十行；改造前贴底那一帧要排五千行。
      expect(layouts, everyElement(lessThanOrEqualTo(100)));
    });

    testWidgets('逐行涌入 5000 行再出一帧：同样只留最后 200 行', (tester) async {
      final buffer = await _pumpLogView(tester, initial: _lines(0, 300));

      for (var i = 0; i < 5000; i++) {
        buffer.append(_lines(300 + i, 1));
      }
      final layouts = await _pumpFramesCountingLayouts(tester);

      expect(_belowChildCount(tester), lessThanOrEqualTo(200));
      _expectAtBottom(tester);
      expect(find.text('line 5299'), findsOneWidget);
      expect(layouts, everyElement(lessThanOrEqualTo(100)));
    });

    testWidgets('逐行涌入、每 50 行出一帧：每一帧都只留最后 200 行、停在底部', (tester) async {
      final buffer = await _pumpLogView(tester, initial: _lines(0, 300));

      var next = 300;
      for (var frame = 0; frame < 100; frame++) {
        for (var i = 0; i < 50; i++) {
          buffer.append(_lines(next++, 1));
        }
        final layouts = await _pumpCountingLayouts(tester);
        expect(layouts, lessThanOrEqualTo(100), reason: '第 $frame 帧');
        expect(_belowChildCount(tester), lessThanOrEqualTo(200));
        _expectAtBottom(tester);
      }
      expect(find.text('line ${next - 1}'), findsOneWidget);
    });

    testWidgets('逐行追加越过一万行上限：不出现整列表重排的一帧，缓冲区严格一万行', (tester) async {
      // 核实时实测过：只把裁剪改成攒着做、锚点不跟着动的话，越过上限那一帧
      // 下方列表一下子缩短，会把一万行从头排一遍（4 秒级的卡顿）。
      final buffer = await _pumpLogView(tester, initial: _lines(0, 9800));

      var next = 9800;
      for (var frame = 0; frame < 60; frame++) {
        for (var i = 0; i < 20; i++) {
          buffer.append(_lines(next++, 1));
        }
        final layouts = await _pumpCountingLayouts(tester);
        expect(layouts, lessThanOrEqualTo(100), reason: '第 $frame 帧');
        expect(_belowChildCount(tester), lessThanOrEqualTo(200));
      }
      await tester.pumpAndSettle();

      expect(buffer.length, kLogBufferMaxLines);
      expect(buffer.droppedCount, 1000);
      _expectAtBottom(tester);
      expect(find.text('line 10999'), findsOneWidget);
      expect(
        find.textContaining('更早的 1000 行未显示', skipOffstage: false),
        findsOneWidget,
      );
    });

    testWidgets('跟随中选了一行字，新日志进来选中的仍是那行字；选区清掉后接着跟随', (tester) async {
      final buffer = await _pumpLogView(tester, initial: _lines(0, 300));

      // 用鼠标拖选：鼠标拖动不滚动列表，能稳稳地选中「line 290」这一整行。
      final rect = tester.getRect(find.text('line 290'));
      final gesture = await tester.startGesture(
        rect.centerLeft + const Offset(1, 0),
        kind: PointerDeviceKind.mouse,
      );
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(rect.centerRight - const Offset(1, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(_selectedTexts(tester), ['line 290']);
      final pixelsBefore = _position(tester).pixels;

      // 选区还在时每帧来 30 行：锚点不滑、不贴底。滑了的话屏幕上每一行都会换内容，
      // 选区停在原位，选中的就成了「line 291」「line 292」……复制拿到的是错的。
      for (var frame = 0; frame < 60; frame++) {
        for (var i = 0; i < 30; i++) {
          buffer.append(_lines(300 + frame * 30 + i, 1));
        }
        await tester.pump(const Duration(milliseconds: 16));
        expect(_selectedTexts(tester), ['line 290'], reason: '第 $frame 帧');
      }
      expect(_position(tester).pixels, pixelsBefore);
      expect(buffer.holdTrim, isTrue, reason: '选区保持期间暂缓裁剪，免得裁到锚点之前');
      expect(_backToBottom, findsNothing, reason: '选字只是暂停跟随，不算翻走');
      final keyBefore = _belowKey(tester);

      // 选区清掉（点别处、复制后都会清）：接着跟随、落到最新一行。
      // 这段时间下面攒了 1800 行，要走「回到底部」重建，不能直接贴底把 1800 行逐个排版。
      tester
          .state<SelectableRegionState>(find.byType(SelectableRegion))
          .clearSelection();
      final layouts = await _pumpFramesCountingLayouts(tester);
      await tester.pumpAndSettle();

      expect(_selectedTexts(tester), isEmpty);
      expect(buffer.holdTrim, isFalse);
      _expectAtBottom(tester);
      expect(find.text('line 2099'), findsOneWidget);
      expect(_belowKey(tester), isNot(keyBefore));
      expect(_belowChildCount(tester), lessThanOrEqualTo(200));
      expect(layouts, everyElement(lessThanOrEqualTo(_rebuildLayoutLimit)));

      // 之后照常原地滑。
      buffer.append(_lines(2100, 20));
      final slideLayouts = await _pumpFramesCountingLayouts(tester);
      _expectAtBottom(tester);
      expect(find.text('line 2119'), findsOneWidget);
      expect(_belowChildCount(tester), lessThanOrEqualTo(200));
      expect(slideLayouts, everyElement(lessThanOrEqualTo(100)));
    });

    testWidgets('选着字往上翻、再点「回到底部」：选区一并清掉，之后照常跟随', (tester) async {
      final buffer = await _pumpLogView(tester, initial: _lines(0, 300));
      final rect = tester.getRect(find.text('line 290'));
      final mouse = await tester.startGesture(
        rect.centerLeft + const Offset(1, 0),
        kind: PointerDeviceKind.mouse,
      );
      addTearDown(mouse.removePointer);
      await tester.pump();
      await mouse.moveTo(rect.centerRight - const Offset(1, 0));
      await tester.pump();
      await mouse.up();
      await tester.pump();
      expect(_selectedTexts(tester), ['line 290']);

      await _scrollUp(tester, 300);
      expect(_backToBottom, findsOneWidget);

      // 重建会把选中的那几行回收掉，但不会触发选区回调；不顺手清掉的话
      // 「有选区」的标记会一直挂着，回到底部之后新日志既不滑也不贴底。
      await tester.tap(_backToBottom);
      await tester.pumpAndSettle();
      expect(_selectedTexts(tester), isEmpty);
      expect(buffer.holdTrim, isFalse);

      buffer.append(_lines(300, 50));
      await tester.pumpAndSettle();
      _expectAtBottom(tester);
      expect(find.text('line 349'), findsOneWidget);
      expect(_belowChildCount(tester), lessThanOrEqualTo(200));
    });

    testWidgets('手指按住期间接进来的行，松手后不原地滑锚点，改走重建', (tester) async {
      final buffer = await _pumpLogView(tester, initial: _lines(0, 300));

      // 已经在底部，手指再往上推（朝底部方向）推不动，但手势算开始了。
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(CustomScrollView)),
      );
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();
      // 手指还在屏幕上时来了 60 行：不滑、不贴底，全接在下方列表末尾。
      for (var i = 0; i < 60; i++) {
        buffer.append(_lines(300 + i, 1));
      }
      await tester.pump();
      expect(_belowChildCount(tester), 260);

      // 跟着手指推到新的底部再松手：仍在底部，继续跟随。
      await gesture.moveBy(const Offset(0, -2000));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(_backToBottom, findsNothing);
      _expectAtBottom(tester);
      final keyBefore = _belowKey(tester);

      buffer.append(_lines(360, 1));
      final layouts = await _pumpFramesCountingLayouts(tester);
      await tester.pumpAndSettle();

      // 原地滑会让下方列表从 261 行一下缩到 200 行：排好的行全被回收、从第 0 行重排，
      // 滚动位置还落在新列表的底之外，要回弹一段。所以这里要看到的是重建（key 换了）。
      expect(_belowKey(tester), isNot(keyBefore));
      expect(_belowChildCount(tester), lessThanOrEqualTo(200));
      _expectAtBottom(tester);
      expect(find.text('line 360'), findsOneWidget);
      expect(layouts, everyElement(lessThanOrEqualTo(_rebuildLayoutLimit)));
    });
  });
}
