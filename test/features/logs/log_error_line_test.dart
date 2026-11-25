import 'dart:convert';
import 'dart:io';

import 'package:daidai_app/features/logs/utils/log_error_line.dart';
import 'package:flutter_test/flutter_test.dart';

/// 按面板的存法造 content：整段日志 zlib 压缩后再 base64（server/service/tiny_log.go）。
String compressLikePanel(String text) =>
    base64.encode(ZLibCodec().encode(utf8.encode(text)));

void main() {
  group('pickLogErrorLine：失败行下面显示的错误行', () {
    test('从尾部找第一条带错误特征的行，跳过面板的 === 框线，去掉颜色码', () {
      final content = compressLikePanel(
        [
          '=== 开始执行 [2026-11-24 20:00:00] ===',
          '正在请求接口',
          '\x1b[31mError: ETIMEDOUT 104.21.3.7:443\x1b[0m',
          '重试结束',
          '=== 执行结束 [2026-11-24 20:00:31] 耗时 31.00 秒 退出码 1 ===',
          '',
        ].join('\n'),
      );
      expect(pickLogErrorLine(content), 'Error: ETIMEDOUT 104.21.3.7:443');
    });

    test('没有错误特征时退回最后一条非空行（与面板「需要关注」同一规则）', () {
      expect(pickLogErrorLine(compressLikePanel('第一行\n最后一行\n')), '最后一行');
    });

    test('空正文（运行中 / 大日志落在磁盘文件里）不显示', () {
      expect(pickLogErrorLine(''), isNull);
      expect(pickLogErrorLine(compressLikePanel('  \n \n')), isNull);
    });

    test('不是 base64 + zlib 时按明文处理', () {
      expect(pickLogErrorLine('hello\nTraceback: boom'), 'Traceback: boom');
    });

    test('超过 120 字截断并加省略号', () {
      final line = pickLogErrorLine(
        compressLikePanel('error: ${'长' * 200}'),
      );
      expect(line!.runes.length, 120);
      expect(line.endsWith('…'), isTrue);
    });

    test('只看尾部 8 KB：前面再长也能取到最后的错误行', () {
      final head = List.filled(5000, 'ok line').join('\n');
      final content = compressLikePanel('$head\nFatal: 磁盘已满\n');
      expect(pickLogErrorLine(content), 'Fatal: 磁盘已满');
    });
  });
}
