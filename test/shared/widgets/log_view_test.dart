import 'package:daidai_app/shared/utils/log_line_buffer.dart';
import 'package:daidai_app/shared/widgets/log_view.dart';
import 'package:flutter/material.dart';
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
}
