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

/// 上下留白各 12：跳到末尾时，最后一行的底边应落在视口底边往上 12 处。
const _padding = EdgeInsets.all(12);

Future<(LogLineBuffer, LogViewController)> _pumpLogView(
  WidgetTester tester, {
  required List<String> initial,
  bool follow = true,
}) async {
  // 视口固定 800x600（与 flutter_test 默认一致），一屏约 30 行。
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(800, 600);
  addTearDown(tester.view.reset);
  final buffer = LogLineBuffer()..replaceAll(initial);
  addTearDown(buffer.dispose);
  final controller = LogViewController();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: LogView(
          buffer: buffer,
          controller: controller,
          follow: follow,
          padding: _padding,
          textStyle: _style,
          brightness: Brightness.light,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (buffer, controller);
}

ScrollPosition _position(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable)).position;

Rect _viewport(WidgetTester tester) => tester.getRect(find.byType(Scrollable));

/// 这一行挂在树上，并且整行都落在视口里。
void _expectVisible(WidgetTester tester, String text) =>
    _expectFinderVisible(tester, find.text(text), text);

void _expectFinderVisible(WidgetTester tester, Finder finder, String what) {
  expect(finder, findsOneWidget, reason: '$what 应在视口里');
  final viewport = _viewport(tester);
  final rect = tester.getRect(finder);
  expect(rect.top, greaterThanOrEqualTo(viewport.top - 0.5), reason: what);
  expect(rect.bottom, lessThanOrEqualTo(viewport.bottom + 0.5), reason: what);
}

/// 往末尾方向（手指往上）甩一下并等滚动停下。
Future<void> _flingTowardEnd(WidgetTester tester) async {
  await tester.fling(
    find.byType(CustomScrollView),
    const Offset(0, -800),
    3000,
  );
  await tester.pumpAndSettle();
}

/// 往开头方向（手指往下）甩一下并等滚动停下。
Future<void> _flingTowardStart(WidgetTester tester) async {
  await tester.fling(
    find.byType(CustomScrollView),
    const Offset(0, 800),
    3000,
  );
  await tester.pumpAndSettle();
}

/// 停在滚动范围的末端，并且末端就是「最后一行的底边贴视口底边（留出下
/// 边距）」，下面没有空白。
void _expectEndAtBottom(WidgetTester tester, Finder lastLine) {
  final position = _position(tester);
  expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
  expect(
    tester.getRect(lastLine).bottom,
    closeTo(_viewport(tester).bottom - _padding.bottom, 0.5),
    reason: '最后一行下面不该有空白',
  );
}

final _backToBottom = find.byTooltip('回到底部');

/// 线上全屏日志正文的样式：12.5 号字、1.58 倍行高（排成 20，空行 19）。
const _pageStyle = TextStyle(fontSize: 12.5, height: 1.58, color: Colors.black);

/// 线上的留白：左右 16、上下 12（[_expectEndAtBottom] 按下边距 12 算）。
const _pagePadding = EdgeInsets.symmetric(horizontal: 16, vertical: 12);

/// 输入法的高度（视口 devicePixelRatio 为 1，物理像素即逻辑像素）。
const _keyboard = FakeViewPadding(bottom: 300);

/// 按全屏日志页的排布摆：Scaffold 默认随键盘压缩 body，正文在 Column 的
/// Expanded 里，上面一截是顶栏 / 搜索栏。键盘一弹，日志视口跟着变矮。
Future<(LogLineBuffer, LogViewController)> _pumpLogPage(
  WidgetTester tester, {
  required int lines,
  required bool follow,
  Size size = const Size(400, 800),
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final buffer = LogLineBuffer()..replaceAll(_lines(0, lines));
  addTearDown(buffer.dispose);
  final controller = LogViewController();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            const SizedBox(height: 60),
            Expanded(
              child: LogView(
                buffer: buffer,
                controller: controller,
                follow: follow,
                padding: _pagePadding,
                textStyle: _pageStyle,
                brightness: Brightness.light,
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (buffer, controller);
}

/// 下方列表（锚点及之后的行）外面那层 SliverPadding，key 是 `log-below-<重建代号>`。
final _belowSliver = find.byWidgetPredicate(
  (widget) =>
      widget is SliverPadding &&
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith('log-below-'),
  skipOffstage: false,
);

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

String _belowKey(WidgetTester tester) =>
    (tester.widget<SliverPadding>(_belowSliver).key! as ValueKey<String>).value;

/// 视口顶边压在哪一行上（在 `line from` .. `line to - 1` 里找）。
int _topLine(WidgetTester tester, int from, int to) {
  final top = _viewport(tester).top + 0.5;
  for (var i = from; i < to; i++) {
    final finder = find.text('line $i');
    if (finder.evaluate().isEmpty) {
      continue;
    }
    final rect = tester.getRect(finder);
    if (rect.top <= top && rect.bottom > top) {
      return i;
    }
  }
  fail('视口顶边上找不到第 $from ~ $to 行');
}

/// 重建一帧的排版上限，与 log_view_test 一致：只排目标附近一屏加缓存区，
/// 而不是从第一行一路排到目标行。
const _rebuildLayoutLimit = 210;

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

/// 连推几帧（跳转那一帧 + 帧后补满视口那一帧），返回每一帧的排版次数。
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

/// 页内搜索上下跳转、「↑ 首处报错」都靠 LogViewController.jumpToAbsoluteLine：
/// 按绝对行号把锚点挪到目标行附近重建，不从第一行一路排版过去。
void main() {
  group('静态日志（面板日志、订阅日志）', () {
    testWidgets('按行号跳转：目标行落在视口靠上处，不会回到第一行', (tester) async {
      final (_, controller) = await _pumpLogView(
        tester,
        initial: _lines(0, 5000),
        follow: false,
      );
      expect(_position(tester).pixels, 0);
      final keyBefore = _belowKey(tester);

      controller.jumpToAbsoluteLine(4000);
      final layouts = await _pumpFramesCountingLayouts(tester);

      _expectVisible(tester, 'line 4000');
      expect(find.text('line 0'), findsNothing, reason: '没有被拉回顶部');
      final viewport = _viewport(tester);
      expect(
        tester.getRect(find.text('line 4000')).top,
        lessThan(viewport.top + viewport.height / 3),
      );
      expect(_belowKey(tester), isNot(keyBefore), reason: '换锚点重建');
      expect(_belowChildCount(tester), 5000 - 3998, reason: '锚点在目标行前 2 行');
      expect(layouts, everyElement(lessThanOrEqualTo(_rebuildLayoutLimit)));
      expect(_backToBottom, findsNothing, reason: '静态日志没有跟随胶囊');

      // 锚点之上的行照样能往上翻出来。
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(find.text('line 3990'), findsOneWidget);
    });

    testWidgets('先手动翻到中部，再往前、往后连跳：每次都落在目标行', (tester) async {
      final (_, controller) = await _pumpLogView(
        tester,
        initial: _lines(0, 5000),
        follow: false,
      );
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
      await tester.pumpAndSettle();
      expect(_position(tester).pixels, greaterThan(0));

      for (final target in [1200, 4500, 30, 2600]) {
        controller.jumpToAbsoluteLine(target);
        final layouts = await _pumpFramesCountingLayouts(tester);
        _expectVisible(tester, 'line $target');
        expect(
          layouts,
          everyElement(lessThanOrEqualTo(_rebuildLayoutLimit)),
          reason: '跳到 $target',
        );
      }

      // 跳到最前面几行：锚点夹到第一行，等同从头显示。
      controller.jumpToAbsoluteLine(1);
      await tester.pumpAndSettle();
      expect(_position(tester).pixels, 0);
      expect(
        tester.getRect(find.text('line 0')).top,
        closeTo(_viewport(tester).top + _padding.top, 0.5),
      );
    });

    testWidgets('跳到末尾附近的行：内容底边贴住视口底边，下面不留空白', (tester) async {
      final (_, controller) = await _pumpLogView(
        tester,
        initial: _lines(0, 5000),
        follow: false,
      );

      controller.jumpToAbsoluteLine(4999);
      final layouts = await _pumpFramesCountingLayouts(tester);

      _expectVisible(tester, 'line 4999');
      expect(
        tester.getRect(find.text('line 4999')).bottom,
        closeTo(_viewport(tester).bottom - _padding.bottom, 0.5),
      );
      // 空出来的那截由目标行之前的行补满：一屏约 30 行。
      expect(find.text('line 4975'), findsOneWidget);
      expect(layouts, everyElement(lessThanOrEqualTo(_rebuildLayoutLimit)));
    });

    testWidgets('跳到末尾：跳转那一帧就排对，不先空一帧再纠正', (tester) async {
      final (_, controller) = await _pumpLogView(
        tester,
        initial: _lines(0, 5000),
        follow: false,
      );

      controller.jumpToAbsoluteLine(4999);
      await tester.pump();

      // 只推了跳转那一帧：最后一行已经贴在视口底边，上面是满的。
      final viewport = _viewport(tester);
      expect(
        tester.getRect(find.text('line 4999')).bottom,
        closeTo(viewport.bottom - _padding.bottom, 0.5),
      );
      expect(find.text('line 4975'), findsOneWidget);
      final pixels = _position(tester).pixels;

      await tester.pumpAndSettle();
      expect(_position(tester).pixels, pixels, reason: '帧后没有再挪');
    });

    testWidgets('跳到末尾附近再往末尾一甩：停在最后一行贴底处，滑不进空白', (
      tester,
    ) async {
      final (_, controller) = await _pumpLogView(
        tester,
        initial: _lines(0, 5000),
        follow: false,
      );

      controller.jumpToAbsoluteLine(4995);
      await tester.pumpAndSettle();
      _expectVisible(tester, 'line 4995');

      await _flingTowardEnd(tester);
      _expectEndAtBottom(tester, find.text('line 4999'));
      expect(find.text('line 4975'), findsOneWidget, reason: '视口上半截是满的');

      // 再甩一次也还停在这儿。
      await _flingTowardEnd(tester);
      _expectEndAtBottom(tester, find.text('line 4999'));
    });

    testWidgets('整段不满一屏的日志里跳转：仍从第一行完整显示', (tester) async {
      final (_, controller) = await _pumpLogView(
        tester,
        initial: _lines(0, 10),
        follow: false,
      );

      controller.jumpToAbsoluteLine(8);
      await tester.pumpAndSettle();

      for (var i = 0; i < 10; i++) {
        _expectVisible(tester, 'line $i');
      }
      expect(
        tester.getRect(find.text('line 0')).top,
        closeTo(_viewport(tester).top + _padding.top, 0.5),
        reason: '前几行没有被顶到视口外',
      );

      // 跳转后也不能变得能滚：往哪甩第一行都贴在顶上。
      final position = _position(tester);
      expect(position.minScrollExtent, 0);
      expect(position.maxScrollExtent, 0);
      for (final fling in [_flingTowardEnd, _flingTowardStart]) {
        await fling(tester);
        expect(
          tester.getRect(find.text('line 0')).top,
          closeTo(_viewport(tester).top + _padding.top, 0.5),
        );
      }
    });

    testWidgets('软换行把末尾几行撑高：帧后补到目标行，往末尾甩仍贴底', (tester) async {
      // 末尾 100 行每行都折成好几行显示，估算行高远小于实际行高。
      final lines = [
        ..._lines(0, 4900),
        for (var i = 4900; i < 5000; i++) 'line $i ${'w' * 300}',
      ];
      final (_, controller) = await _pumpLogView(
        tester,
        initial: lines,
        follow: false,
      );

      controller.jumpToAbsoluteLine(4990);
      await tester.pumpAndSettle();

      // 目标行前 2 行在视口顶上，目标行整行可见。
      expect(
        tester.getRect(find.textContaining('line 4988 ')).top,
        closeTo(_viewport(tester).top, 0.5),
      );
      _expectFinderVisible(
        tester,
        find.textContaining('line 4990 '),
        'line 4990',
      );

      await _flingTowardEnd(tester);
      _expectEndAtBottom(tester, find.textContaining('line 4999 '));
    });

    testWidgets('末尾一串空行（空行比估算矮）：跳到最后一行照样贴底', (tester) async {
      final lines = [..._lines(0, 4960), for (var i = 0; i < 39; i++) ''];
      lines.add('last line');
      final (_, controller) = await _pumpLogView(
        tester,
        initial: lines,
        follow: false,
      );

      controller.jumpToAbsoluteLine(lines.length - 1);
      await tester.pumpAndSettle();
      _expectEndAtBottom(tester, find.text('last line'));

      await _flingTowardEnd(tester);
      _expectEndAtBottom(tester, find.text('last line'));
    });

    testWidgets('跳转后整段换了内容（面板日志改筛选重拉）：回到从第一行显示', (tester) async {
      final (buffer, controller) = await _pumpLogView(
        tester,
        initial: _lines(0, 5000),
        follow: false,
      );
      controller.jumpToAbsoluteLine(4000);
      await tester.pumpAndSettle();
      _expectVisible(tester, 'line 4000');

      buffer.replaceAll(List<String>.generate(3000, (i) => 'new $i'));
      await tester.pumpAndSettle();

      expect(_position(tester).pixels, 0);
      expect(
        tester.getRect(find.text('new 0')).top,
        closeTo(_viewport(tester).top + _padding.top, 0.5),
      );
    });
  });

  group('运行中日志（跟随模式）', () {
    testWidgets('按行号跳转：暂停跟随、暂缓裁剪，新日志不把视图拉走；点胶囊回到底部', (
      tester,
    ) async {
      final (buffer, controller) = await _pumpLogView(
        tester,
        initial: _lines(0, 5000),
      );
      final keyBefore = _belowKey(tester);

      controller.jumpToAbsoluteLine(2500);
      final layouts = await _pumpFramesCountingLayouts(tester);

      _expectVisible(tester, 'line 2500');
      expect(_belowKey(tester), isNot(keyBefore));
      expect(layouts, everyElement(lessThanOrEqualTo(_rebuildLayoutLimit)));
      expect(_backToBottom, findsOneWidget, reason: '跳走即暂停跟随');
      expect(buffer.holdTrim, isTrue, reason: '锚点不滑，免得裁过锚点');

      final topBefore = tester.getRect(find.text('line 2500')).top;
      buffer.append(_lines(5000, 100));
      final appendLayouts = await _pumpFramesCountingLayouts(tester);
      expect(tester.getRect(find.text('line 2500')).top, topBefore);
      expect(find.text('line 5099'), findsNothing, reason: '没有被拉到底部');
      expect(find.text('恢复跟随 · 新增 100 行'), findsOneWidget);
      expect(appendLayouts, everyElement(lessThanOrEqualTo(100)));

      await tester.tap(_backToBottom);
      await tester.pumpAndSettle();
      final position = _position(tester);
      expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
      expect(find.text('line 5099'), findsOneWidget);
      expect(_backToBottom, findsNothing);
      expect(buffer.holdTrim, isFalse);
      expect(_belowChildCount(tester), lessThanOrEqualTo(200));
    });

    testWidgets('跳到最后一行（如末尾的报错）：内容底边贴住视口底边', (tester) async {
      final (_, controller) = await _pumpLogView(
        tester,
        initial: _lines(0, 300),
      );

      controller.jumpToAbsoluteLine(299);
      await tester.pumpAndSettle();

      _expectVisible(tester, 'line 299');
      expect(
        tester.getRect(find.text('line 299')).bottom,
        closeTo(_viewport(tester).bottom - _padding.bottom, 0.5),
      );
      expect(find.text('line 275'), findsOneWidget);
    });

    testWidgets('跳到末尾几行再往末尾一甩：恢复跟随，最后一行贴底、上面不空', (
      tester,
    ) async {
      final (buffer, controller) = await _pumpLogView(
        tester,
        initial: _lines(0, 300),
      );

      controller.jumpToAbsoluteLine(295);
      await tester.pumpAndSettle();
      _expectVisible(tester, 'line 295');
      expect(_backToBottom, findsOneWidget);

      // 已结束的日志不会再来新行：甩到末尾这一下停在哪，画面就一直是哪。
      await _flingTowardEnd(tester);
      expect(_backToBottom, findsNothing, reason: '到了底部，恢复跟随');
      _expectEndAtBottom(tester, find.text('line 299'));
      expect(find.text('line 275'), findsOneWidget, reason: '视口上半截是满的');
      expect(buffer.holdTrim, isFalse);

      // 恢复跟随后新行照常贴底。
      buffer.append(_lines(300, 20));
      await tester.pumpAndSettle();
      _expectEndAtBottom(tester, find.text('line 319'));
    });

    testWidgets('选着字时跳转：选区一并清掉，回到底部后照常跟随', (tester) async {
      final (buffer, controller) = await _pumpLogView(
        tester,
        initial: _lines(0, 300),
      );
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

      controller.jumpToAbsoluteLine(100);
      await tester.pumpAndSettle();
      expect(_selectedTexts(tester), isEmpty);
      _expectVisible(tester, 'line 100');

      await tester.tap(_backToBottom);
      await tester.pumpAndSettle();
      buffer.append(_lines(300, 20));
      await tester.pumpAndSettle();
      final position = _position(tester);
      expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
      expect(find.text('line 319'), findsOneWidget);
      expect(buffer.holdTrim, isFalse);
    });
  });

  // 页内搜索的「上一处 / 下一处」是在搜索框有焦点、键盘弹着时跳的：视口被
  // 压矮了一大截，收起键盘或关掉搜索栏后又变高。锚点要按变高后的视口也够
  // 一屏来夹，否则末尾几行顶在上半截、下面一大片空白，往末尾也甩不下去。
  group('键盘弹着跳到末尾附近，收起键盘后视口变高', () {
    for (final follow in [false, true]) {
      // 2999 是最后一行；2975 离末尾 25 行，键盘弹着时锚点根本不会往前夹，
      // 键盘收起后照样不足一屏。
      for (final target in [2999, 2975]) {
        final mode = follow ? '跟随' : '静态';
        testWidgets('$mode · 跳到第 ${target + 1} 行：往末尾甩，最后一行贴底不留白', (
          tester,
        ) async {
          final (_, controller) = await _pumpLogPage(
            tester,
            lines: 3000,
            follow: follow,
          );
          tester.view.viewInsets = _keyboard;
          await tester.pumpAndSettle();
          final lowViewport = _viewport(tester).height;

          controller.jumpToAbsoluteLine(target);
          await tester.pumpAndSettle();
          _expectVisible(tester, 'line $target');
          final keyBefore = _belowKey(tester);

          tester.view.viewInsets = FakeViewPadding.zero;
          await tester.pumpAndSettle();
          expect(_viewport(tester).height, greaterThan(lowViewport + 250));
          // 跳转时就按窗口长边夹够了，收键盘不用帧后重建（不会先空一帧）。
          expect(_belowKey(tester), keyBefore);

          await _flingTowardEnd(tester);
          _expectEndAtBottom(tester, find.text('line 2999'));
          // 视口上半截是满的：一屏约 37 行，倒数第 30 行也在视口里。
          _expectVisible(tester, 'line 2970');
          if (follow) {
            expect(_backToBottom, findsNothing, reason: '到了底部，恢复跟随');
          }
        });
      }
    }
  });

  // 键盘、转屏都不会让视口高过窗口的长边；分屏拖动分隔条、桌面拉大窗口能让
  // 窗口本身变大，视口比跳转时夹锚点用的上界还高：帧后按新视口重夹。
  group('跳转后窗口本身变大（分屏拖动）', () {
    for (final follow in [false, true]) {
      final mode = follow ? '跟随' : '静态';
      testWidgets('$mode · 跳到最后一行后窗口拉高：往末尾甩，最后一行贴底不留白', (
        tester,
      ) async {
        final (_, controller) = await _pumpLogPage(
          tester,
          lines: 3000,
          follow: follow,
          size: const Size(400, 400),
        );
        controller.jumpToAbsoluteLine(2999);
        await tester.pumpAndSettle();
        _expectEndAtBottom(tester, find.text('line 2999'));

        tester.view.physicalSize = const Size(400, 800);
        await tester.pumpAndSettle();
        _expectEndAtBottom(tester, find.text('line 2999'));
        _expectVisible(tester, 'line 2970');

        await _flingTowardEnd(tester);
        _expectEndAtBottom(tester, find.text('line 2999'));
        if (follow) {
          expect(_backToBottom, findsNothing, reason: '到了底部，恢复跟随');
        }
      });
    }

    testWidgets('跟随 · 跳转后已甩回底部恢复跟随，再拉高窗口：仍贴底、照常跟随', (
      tester,
    ) async {
      final (buffer, controller) = await _pumpLogPage(
        tester,
        lines: 3000,
        follow: true,
        size: const Size(400, 400),
      );
      controller.jumpToAbsoluteLine(2995);
      await tester.pumpAndSettle();
      await _flingTowardEnd(tester);
      expect(_backToBottom, findsNothing);

      tester.view.physicalSize = const Size(400, 800);
      await tester.pumpAndSettle();
      _expectEndAtBottom(tester, find.text('line 2999'));
      _expectVisible(tester, 'line 2970');
      expect(_backToBottom, findsNothing);

      buffer.append(_lines(3000, 20));
      await tester.pumpAndSettle();
      _expectEndAtBottom(tester, find.text('line 3019'));
    });

    // 跳转之后人往前翻走了：重夹要按眼下视口顶上那一行来，不能把人拽回
    // 跳转时的目标行（静态页上跳转锚点一直留着，旧目标会一直在）。
    for (final follow in [false, true]) {
      final mode = follow ? '跟随' : '静态';
      testWidgets('$mode · 跳到最后一行、往前翻走后拉高窗口：顶上还是那一行', (
        tester,
      ) async {
        final (_, controller) = await _pumpLogPage(
          tester,
          lines: 3000,
          follow: follow,
          size: const Size(400, 400),
        );
        controller.jumpToAbsoluteLine(2999);
        await tester.pumpAndSettle();
        for (var i = 0; i < 6; i++) {
          await tester.drag(
            find.byType(CustomScrollView),
            const Offset(0, 250),
          );
          await tester.pumpAndSettle();
        }
        final topBefore = _topLine(tester, 2800, 3000);
        expect(topBefore, lessThan(2950), reason: '确实翻走了');

        tester.view.physicalSize = const Size(400, 800);
        await tester.pumpAndSettle();
        expect(_topLine(tester, 2800, 3000), topBefore);
        if (follow) {
          expect(_backToBottom, findsOneWidget, reason: '仍暂停跟随');
        }

        // 锚点照样按新视口重夹过：往末尾甩，最后一行贴底不留白。
        await _flingTowardEnd(tester);
        _expectEndAtBottom(tester, find.text('line 2999'));
      });
    }

    testWidgets('跳到中部再拉高窗口：锚点下方本来就够，不重建、位置不动', (
      tester,
    ) async {
      final (_, controller) = await _pumpLogPage(
        tester,
        lines: 3000,
        follow: false,
        size: const Size(400, 400),
      );
      controller.jumpToAbsoluteLine(1500);
      await tester.pumpAndSettle();
      final keyBefore = _belowKey(tester);
      final topBefore = tester.getRect(find.text('line 1500')).top;

      tester.view.physicalSize = const Size(400, 800);
      await tester.pumpAndSettle();
      expect(_belowKey(tester), keyBefore);
      expect(tester.getRect(find.text('line 1500')).top, topBefore);
    });
  });
}
