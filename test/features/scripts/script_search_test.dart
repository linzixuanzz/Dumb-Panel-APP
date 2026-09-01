import 'package:daidai_app/features/scripts/utils/script_search.dart';
import 'package:daidai_app/features/scripts/widgets/script_line_number_gutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 脚本编辑页搜索（issue #6）的行为锁。
///
/// 这几个函数是从 `script_list_page.dart` 里抽出来的：改造前搜索游标寄存在
/// `TextEditingController.selection` 上，被 build 里的每帧赋值抹掉，于是「下一个」
/// 永远停在第一个命中。把「命中列表 + 序号推进」做成纯函数之后，这条链路才测得到 ——
/// 下面每一条都是「点下一个必须真的往下走」的组成部分。
void main() {
  group('findMatchOffsets', () {
    test('大小写不敏感，返回的是原文下标', () {
      expect(findMatchOffsets('Hello hello HELLO', 'hello'), [0, 6, 12]);
      expect(findMatchOffsets('Hello hello HELLO', 'HeLLo'), [0, 6, 12]);
    });

    test('多命中按出现顺序排列', () {
      expect(findMatchOffsets('a-b-a-b-a', 'a'), [0, 4, 8]);
    });

    test('没命中给空列表，不是 null', () {
      expect(findMatchOffsets('abc', 'zzz'), isEmpty);
      // 关键词比全文还长。
      expect(findMatchOffsets('ab', 'abcdef'), isEmpty);
    });

    test('空 query / 空内容一律给空列表（不能变成「全选」）', () {
      expect(findMatchOffsets('abc', ''), isEmpty);
      expect(findMatchOffsets('', 'abc'), isEmpty);
      expect(findMatchOffsets('', ''), isEmpty);
    });

    test('命中不重叠：aaaa 里找 aa 只有 [0, 2]', () {
      // 重叠命中会让高亮切片互相套住（buildTextSpan 的 cursor 会往回走），
      // 所以找到一个就从它的末尾继续 —— 这也是改造前 indexOf 循环的语义。
      expect(findMatchOffsets('aaaa', 'aa'), [0, 2]);
      expect(findMatchOffsets('aaaaa', 'aa'), [0, 2]);
    });

    test('命中数触顶就截断，不会把上千个 span 甩给编辑器', () {
      final offsets = findMatchOffsets('a' * 1000, 'a');
      expect(offsets, hasLength(kScriptSearchMatchLimit));
      expect(offsets.first, 0);
      expect(offsets.last, kScriptSearchMatchLimit - 1);
    });

    test('limit 可以调小，limit <= 0 直接空', () {
      expect(findMatchOffsets('aaaaa', 'a', limit: 3), [0, 1, 2]);
      expect(findMatchOffsets('aaaaa', 'a', limit: 0), isEmpty);
    });

    test('换行、空格这类空白字符照样能搜（代码里缩进是有意义的）', () {
      expect(findMatchOffsets('a\n  b', '  '), [2]);
      expect(findMatchOffsets('a\nb', '\n'), [1]);
    });
  });

  group('nextMatchIndex', () {
    test('还没定位过时：向下从第一个开始，向上从最后一个开始', () {
      expect(nextMatchIndex(-1, 3, forward: true), 0);
      expect(nextMatchIndex(-1, 3, forward: false), 2);
    });

    test('向前逐个推进', () {
      expect(nextMatchIndex(0, 3, forward: true), 1);
      expect(nextMatchIndex(1, 3, forward: true), 2);
    });

    test('向后逐个回退', () {
      expect(nextMatchIndex(2, 3, forward: false), 1);
      expect(nextMatchIndex(1, 3, forward: false), 0);
    });

    test('到头回绕', () {
      expect(nextMatchIndex(2, 3, forward: true), 0);
      expect(nextMatchIndex(0, 3, forward: false), 2);
    });

    test('没有命中时不存在「当前项」', () {
      expect(nextMatchIndex(-1, 0, forward: true), -1);
      expect(nextMatchIndex(5, 0, forward: false), -1);
    });

    test('上一轮留下的越界序号先归一化，不会抛也不会卡住', () {
      // 换了更短的关键词之后 _currentMatchIndex 可能还停在旧的大序号上。
      expect(nextMatchIndex(7, 3, forward: true), 2);
      expect(nextMatchIndex(7, 3, forward: false), 0);
    });

    test('只有一个命中时反复点也只停在它身上', () {
      expect(nextMatchIndex(0, 1, forward: true), 0);
      expect(nextMatchIndex(0, 1, forward: false), 0);
    });
  });

  group('lineNumberForOffset', () {
    const source = 'a\nb\nc';

    test('首行 / 中间行 / 末行', () {
      expect(lineNumberForOffset(source, 0), 1);
      expect(lineNumberForOffset(source, 1), 1);
      expect(lineNumberForOffset(source, 2), 2);
      expect(lineNumberForOffset(source, 4), 3);
    });

    test('空文件是第 1 行，不是第 0 行', () {
      expect(lineNumberForOffset('', 0), 1);
      expect(lineNumberForOffset('', 99), 1);
    });

    test('越界和负数都不抛', () {
      expect(lineNumberForOffset(source, 999), 3);
      expect(lineNumberForOffset(source, -5), 1);
    });

    test('末尾换行会多出一行 —— 与编辑器显示一致', () {
      expect(lineNumberForOffset('a\n', 2), 2);
    });
  });

  group('ScriptEditorTextMetrics（行号几何）', () {
    // 与编辑器同一套度量：strut 强制行高，行号才可能逐行对齐。
    const style = TextStyle(fontSize: 13, height: 1.5);
    final strut = StrutStyle.fromTextStyle(style, forceStrutHeight: true);

    testWidgets('无软换行时每条逻辑行都有行号，y 依次递增', (tester) async {
      final metrics = ScriptEditorTextMetrics.compute(
        text: 'aaa\nbbb\nccc',
        style: style,
        strutStyle: strut,
        textScaler: TextScaler.noScaling,
        // 宽到不可能触发换行。
        maxWidth: 1000,
      );

      expect(metrics.lineNumbers, [1, 2, 3]);
      expect(metrics.visualLineCount, 3);
      expect(metrics.lineTops.first, 0);
      expect(metrics.lineTops[1], greaterThan(metrics.lineTops[0]));
      expect(metrics.lineTops[2], greaterThan(metrics.lineTops[1]));

      metrics.dispose();
    });

    testWidgets('有软换行时续行留空：视觉行更多，行号只有一个', (tester) async {
      final metrics = ScriptEditorTextMetrics.compute(
        text: 'aaa bbb ccc ddd eee',
        style: style,
        strutStyle: strut,
        textScaler: TextScaler.noScaling,
        // 19 个字符 × 13 远超这个宽度，必然被折成多条视觉行。
        maxWidth: 100,
      );

      // 只有一条**逻辑**行，所以只画一个行号（与 VS Code 一致）。
      expect(metrics.lineNumbers, [1]);
      // 但它确实被折断了 —— 否则这条用例根本没在测软换行。
      expect(metrics.visualLineCount, greaterThan(1));

      metrics.dispose();
    });

    testWidgets('空文件也要有第 1 行，不能一个行号都不画', (tester) async {
      final metrics = ScriptEditorTextMetrics.compute(
        text: '',
        style: style,
        strutStyle: strut,
        textScaler: TextScaler.noScaling,
        maxWidth: 200,
      );

      expect(metrics.lineNumbers, [1]);
      expect(metrics.lineTops, [0]);

      metrics.dispose();
    });

    testWidgets('topForOffset 随下标单调增，dispose 之后给 null 而不是脏值', (tester) async {
      final metrics = ScriptEditorTextMetrics.compute(
        text: 'aaa\nbbb\nccc',
        style: style,
        strutStyle: strut,
        textScaler: TextScaler.noScaling,
        maxWidth: 1000,
      );

      final first = metrics.topForOffset(0);
      final last = metrics.topForOffset(9);
      expect(first, isNotNull);
      expect(last, isNotNull);
      expect(last, greaterThan(first!));

      metrics.dispose();
      // 搜索的滚动回调是 post-frame 触发的，可能跑在几何被换掉之后，
      // 那时必须放弃这次滚动，而不是拿已释放的 painter 去算。
      expect(metrics.topForOffset(0), isNull);
    });

    testWidgets('行号栏宽度随位数增长，且个位数文件不比两位数窄', (tester) async {
      final oneDigit = scriptGutterWidth(
        lineCount: 9,
        style: style,
        textScaler: TextScaler.noScaling,
      );
      final twoDigits = scriptGutterWidth(
        lineCount: 42,
        style: style,
        textScaler: TextScaler.noScaling,
      );
      final fourDigits = scriptGutterWidth(
        lineCount: 1234,
        style: style,
        textScaler: TextScaler.noScaling,
      );

      // 最少按两位算：文件从 9 行涨到 10 行时整条栏不该横向跳一下。
      expect(oneDigit, twoDigits);
      expect(fourDigits, greaterThan(twoDigits));
    });
  });

  group('nearestMatchIndex：编辑期间重扫不要把「第几个命中」打回开头', () {
    test('落到离原位置最近的那个命中', () {
      // 用户停在 offset 100 那个命中上，敲了几个字之后命中整体挪了位置，
      // 序号应该跟着落到最近的那个，而不是回到第 1 个。
      expect(nearestMatchIndex(const [10, 98, 300], 100), 1);
      expect(nearestMatchIndex(const [10, 98, 300], 290), 2);
      expect(nearestMatchIndex(const [10, 98, 300], 0), 0);
    });

    test('距离一样时取靠前的那个', () {
      expect(nearestMatchIndex(const [90, 110], 100), 0);
    });

    test('刚好命中原位置', () {
      expect(nearestMatchIndex(const [10, 100, 300], 100), 1);
    });

    test('空列表给 -1：没有命中就没有「当前项」', () {
      expect(nearestMatchIndex(const [], 100), -1);
    });

    test('只有一个命中时永远是它', () {
      expect(nearestMatchIndex(const [42], 0), 0);
      expect(nearestMatchIndex(const [42], 99999), 0);
    });
  });
}
