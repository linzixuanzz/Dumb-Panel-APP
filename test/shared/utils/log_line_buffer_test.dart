import 'package:daidai_app/shared/utils/ansi_text.dart';
import 'package:daidai_app/shared/utils/log_line_buffer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<String> _lines(int from, int count) =>
    List<String>.generate(count, (i) => 'line ${from + i}');

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
}
