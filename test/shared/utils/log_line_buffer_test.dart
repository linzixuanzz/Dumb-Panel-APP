import 'dart:math' as math;

import 'package:daidai_app/shared/utils/ansi_text.dart';
import 'package:daidai_app/shared/utils/log_line_buffer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<String> _lines(int from, int count) =>
    List<String>.generate(count, (i) => 'line ${from + i}');

/// 改造前的 LogLineBuffer（每次裁剪都当场 removeRange）原样搬过来当对照（APP #15）。
///
/// 新实现只是把「搬表」攒着做，对外每一项都必须和它逐行一致。
class _OriginalBuffer {
  _OriginalBuffer(this.maxLines);

  final int maxLines;
  final lines = <String>[];
  final starts = <AnsiLineState>[];
  var tail = AnsiLineState.initial;
  var dropped = 0;
  var holdTrim = false;

  void append(List<String> input) {
    // 原版追加空集合时直接返回，连裁剪都不做。
    if (input.isEmpty) {
      return;
    }
    _add(input);
    _trim();
  }

  void replaceAll(List<String> input) {
    lines.clear();
    starts.clear();
    tail = AnsiLineState.initial;
    dropped = 0;
    _add(input);
    _trim();
  }

  void _add(List<String> input) {
    for (final line in input) {
      starts.add(tail);
      tail = tail.advance(line);
      lines.add(line);
    }
  }

  void _trim() {
    final limit = holdTrim ? maxLines * 2 : maxLines;
    if (lines.length <= limit) {
      return;
    }
    final excess = lines.length - maxLines;
    lines.removeRange(0, excess);
    starts.removeRange(0, excess);
    dropped += excess;
  }
}

/// 隔几行混进跨行生效的颜色序列，好让「行首 ANSI 样式」的比对有意义。
String _ansiLine(int n) {
  if (n % 7 == 0) {
    return '\x1B[3${n % 8}m变色 $n';
  }
  if (n % 11 == 0) {
    return '\x1B[0m复位 $n';
  }
  return 'line $n';
}

/// issue #10：日志太长时页面卡死。缓冲区负责「增量追加 + 超长只留最近一部分」，
/// 这里钉住截断的口径 —— 丢多少、留哪些、绝对行号怎么算，
/// 以及用户上翻时暂缓裁剪（否则眼前的内容会被往上推走）。
void main() {
  group('截断：只保留最近一部分', () {
    test('没超上限时原样保留，一行不丢', () {
      final buffer = LogLineBuffer(maxLines: 10)..append(_lines(0, 10));

      expect(buffer.length, 10);
      expect(buffer.droppedCount, 0);
      expect(buffer.lines.first, 'line 0');
    });

    test('超出上限后丢掉最早的行，留下的是最近的那部分', () {
      final buffer = LogLineBuffer(maxLines: 10)
        ..append(_lines(0, 8))
        ..append(_lines(8, 17));

      expect(buffer.length, 10);
      expect(buffer.droppedCount, 15);
      expect(buffer.totalCount, 25);
      expect(buffer.lines, _lines(15, 10));
    });

    test('replaceAll 也按上限截断，并且绝对行号从 0 重新数起', () {
      final buffer = LogLineBuffer(maxLines: 10)..append(_lines(0, 30));
      final generation = buffer.generation;

      buffer.replaceAll(_lines(0, 12));

      expect(buffer.generation, generation + 1);
      expect(buffer.droppedCount, 2);
      expect(buffer.lines, _lines(2, 10));
    });

    test('clear 清空内容与丢弃计数', () {
      final buffer = LogLineBuffer(maxLines: 10)
        ..append(_lines(0, 30))
        ..clear();

      expect(buffer.isEmpty, isTrue);
      expect(buffer.droppedCount, 0);
    });

    test('用户上翻期间放宽到两倍才裁，裁的时候一次裁回上限', () {
      final buffer = LogLineBuffer(maxLines: 10)..append(_lines(0, 10));
      buffer.holdTrim = true;

      buffer.append(_lines(10, 10));
      expect(buffer.length, 20, reason: '两倍以内不裁，屏幕上的行不会被往上推');
      expect(buffer.droppedCount, 0);

      buffer.append(_lines(20, 1));
      expect(buffer.length, 10, reason: '超过两倍就必须裁了，内存不能无限涨');
      expect(buffer.lines, _lines(11, 10));
    });

    test('回到底部（不再暂缓）后，下一次追加恢复正常上限', () {
      final buffer = LogLineBuffer(maxLines: 10)..holdTrim = true;
      buffer.append(_lines(0, 15));
      expect(buffer.length, 15);

      buffer.holdTrim = false;
      buffer.append(_lines(15, 1));

      expect(buffer.length, 10);
      expect(buffer.lines, _lines(6, 10));
    });

    test('追加空集合不通知、不改内容', () {
      final buffer = LogLineBuffer(maxLines: 10)..append(_lines(0, 3));
      var notified = 0;
      buffer.addListener(() => notified++);

      buffer.append(const <String>[]);

      expect(notified, 0);
      expect(buffer.length, 3);
    });
  });

  group('跨行的 ANSI 颜色', () {
    const baseStyle = TextStyle(color: Colors.black, fontSize: 13);
    // 浅色配色下 31 号（红）对应的颜色，见 ansi_text.dart 的 _paletteForBrightness。
    const red = Color(0xFFDC2626);

    Color? firstColor(TextSpan span) =>
        (span.children!.first as TextSpan).style?.color;

    test('颜色序列跨行生效：按行渲染时续上上一行结束时的状态', () {
      final buffer = LogLineBuffer()
        ..append(['\x1B[31m红色开始', '仍然是红色', '\x1B[0m恢复默认']);

      expect(buffer.ansiStateAt(0), same(AnsiLineState.initial));

      final middle = AnsiTextParser.buildTextSpan(
        buffer.lineAt(1),
        baseStyle: baseStyle,
        brightness: Brightness.light,
        start: buffer.ansiStateAt(1),
      );
      expect(firstColor(middle), red, reason: '没续上状态的话这一行会退回默认色');

      final last = AnsiTextParser.buildTextSpan(
        buffer.lineAt(2),
        baseStyle: baseStyle,
        brightness: Brightness.light,
        start: buffer.ansiStateAt(2),
      );
      expect(firstColor(last), Colors.black);
    });

    test('按行渲染的颜色与整段解析逐段一致', () {
      const lines = [
        '\x1B[1;32m粗绿',
        '接着粗绿\x1B[22m取消粗体',
        '\x1B[38;5;208m256 色\x1B[48;2;1;2;3m带背景',
        '背景延续\x1B[39;49m全部默认',
      ];
      final buffer = LogLineBuffer()..append(lines);

      final whole = AnsiTextParser.buildTextSpan(
        lines.join('\n'),
        baseStyle: baseStyle,
        brightness: Brightness.dark,
      );
      // 整段解析的样式按字符铺开，再与逐行解析的结果逐字比对。
      List<TextStyle?> stylesPerChar(TextSpan span) => [
        for (final child in span.children!.cast<TextSpan>())
          for (var i = 0; i < child.text!.length; i++)
            if (child.text![i] != '\n') child.style,
      ];
      final perLine = <TextStyle?>[
        for (var i = 0; i < buffer.length; i++)
          ...stylesPerChar(
            AnsiTextParser.buildTextSpan(
              buffer.lineAt(i),
              baseStyle: baseStyle,
              brightness: Brightness.dark,
              start: buffer.ansiStateAt(i),
            ),
          ),
      ];

      expect(perLine, stylesPerChar(whole));
    });

    test('裁掉前面的行后，留下的第一行仍带着它原本的起始状态', () {
      final buffer = LogLineBuffer(maxLines: 2)
        ..append(['\x1B[31m开始', '中间', '结尾']);

      expect(buffer.droppedCount, 1);
      final span = AnsiTextParser.buildTextSpan(
        buffer.lineAt(0),
        baseStyle: baseStyle,
        brightness: Brightness.light,
        start: buffer.ansiStateAt(0),
      );
      expect(firstColor(span), red);
    });
  });

  // APP #15：运行中的日志是 SSE 一行一行追加的。缓冲区满了以后原来每来一行
  // 就把两张一万个元素的表整体前移一格，几万行历史重放光搬表就一两秒。
  // 现在逻辑上照样严格只留 maxLines 行，物理上攒够上限的十分之一才搬一次。
  group('逐行追加时攒着搬表，对外与原版逐行一致', () {
    const baseStyle = TextStyle(color: Colors.black, fontSize: 13);

    TextSpan render(String line, AnsiLineState start) =>
        AnsiTextParser.buildTextSpan(
          line,
          baseStyle: baseStyle,
          brightness: Brightness.light,
          start: start,
        );

    /// 两边对外能看到的东西逐项比；行首 ANSI 样式按渲染出来的 TextSpan 比。
    void expectSameAsOriginal(
      LogLineBuffer buffer,
      _OriginalBuffer original,
      String step,
    ) {
      expect(buffer.length, original.lines.length, reason: step);
      expect(buffer.isEmpty, original.lines.isEmpty, reason: step);
      expect(buffer.isNotEmpty, original.lines.isNotEmpty, reason: step);
      expect(buffer.droppedCount, original.dropped, reason: step);
      expect(
        buffer.totalCount,
        original.dropped + original.lines.length,
        reason: step,
      );
      expect(buffer.lines, original.lines, reason: step);
      expect(buffer.joinAll(), original.lines.join('\n'), reason: step);
      // 逐行比用普通判断、出错才 fail：几十万次 expect 太慢。
      for (var i = 0; i < original.lines.length; i++) {
        if (buffer.lineAt(i) != original.lines[i] ||
            render(buffer.lineAt(i), buffer.ansiStateAt(i)) !=
                render(original.lines[i], original.starts[i])) {
          fail('$step：第 $i 行（或它的行首样式）与原版不一致');
        }
      }
    }

    test('随机穿插逐行追加、整批追加、暂缓裁剪、整体替换：每一步都与原版一致', () {
      // 上限小于 10 时每次都真搬（与原版同一条路），10 以上才攒着搬，两种都要覆盖。
      for (final maxLines in [1, 2, 7, 10, 25, 100]) {
        final random = math.Random(maxLines);
        final buffer = LogLineBuffer(maxLines: maxLines);
        final original = _OriginalBuffer(maxLines);
        var next = 0;
        List<String> take(int count) => [
          for (var i = 0; i < count; i++) _ansiLine(next++),
        ];

        for (var step = 0; step < 400; step++) {
          final roll = random.nextInt(100);
          final String what;
          if (roll < 50) {
            final batch = take(1);
            buffer.append(batch);
            original.append(batch);
            what = '逐行追加';
          } else if (roll < 70) {
            final batch = take(random.nextInt(maxLines * 3 + 1));
            buffer.append(batch);
            original.append(batch);
            what = '整批追加 ${batch.length} 行';
          } else if (roll < 85) {
            final hold = random.nextBool();
            buffer.holdTrim = hold;
            original.holdTrim = hold;
            what = 'holdTrim=$hold';
          } else if (roll < 95) {
            final batch = take(random.nextInt(maxLines * 3 + 1));
            buffer.replaceAll(batch);
            original.replaceAll(batch);
            what = '整体替换为 ${batch.length} 行';
          } else {
            buffer.clear();
            original.replaceAll(const <String>[]);
            what = '清空';
          }
          expectSameAsOriginal(
            buffer,
            original,
            'maxLines=$maxLines 第 $step 步（$what）',
          );
        }
      }
    });

    test('上限 100 时：每多一行逻辑上就裁一行，物理上攒够 10 行才搬一次', () {
      final buffer = LogLineBuffer(maxLines: 100);
      for (var i = 0; i < 109; i++) {
        buffer.append(['line $i']);
      }

      expect(buffer.length, 100);
      expect(buffer.droppedCount, 9);
      expect(buffer.lines, _lines(9, 100));
      expect(buffer.lineAt(0), 'line 9');
      expect(buffer.debugCompactions, 0, reason: '9 行还没攒够上限的十分之一');
      expect(
        () => buffer.lines.add('x'),
        throwsUnsupportedError,
        reason: '表头有待搬走的行时给的是拷贝，也必须只读',
      );

      buffer.append(['line 109']);
      expect(buffer.debugCompactions, 1);
      expect(buffer.droppedCount, 10);
      expect(buffer.lines, _lines(10, 100));
    });

    test('逐行追加 5 万行：逻辑上始终严格一万行，搬表次数有上限', () {
      final buffer = LogLineBuffer();
      var mismatches = 0;
      for (var i = 0; i < 50000; i++) {
        buffer.append(['line $i']);
        final total = i + 1;
        final kept = math.min(total, kLogBufferMaxLines);
        if (buffer.length != kept ||
            buffer.droppedCount != total - kept ||
            buffer.lineAt(0) != 'line ${total - kept}' ||
            buffer.lineAt(kept - 1) != 'line $i') {
          mismatches++;
        }
      }

      expect(mismatches, 0, reason: '截断提示与「复制最近 N 行」的 N 必须一直是 10000');
      expect(buffer.lines, _lines(40000, kLogBufferMaxLines));
      // 原版每来一行搬一次，这里会是 4 万次；现在每攒一千行才搬一次。
      expect(buffer.debugCompactions, lessThanOrEqualTo(50));
      expect(
        buffer.debugCompactions,
        greaterThan(0),
        reason: '攒够了就得真搬，内存不能只涨不落',
      );
    });
  });
}
