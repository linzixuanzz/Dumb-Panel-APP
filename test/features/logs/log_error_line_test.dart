import 'dart:convert';
import 'dart:io';

import 'package:daidai_app/features/logs/utils/log_error_line.dart';
import 'package:daidai_app/shared/utils/log_error_keywords.dart';
import 'package:daidai_app/shared/widgets/fullscreen_log_scaffold.dart';
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

    // 面板 #187：conc / desi 在日志开头写明本次跑的是哪个账号。这行是面板
    // 自己打的说明，不是失败原因；脚本在它后面什么都没打就失败了，面板
    // 「需要关注」跳过它，列表也不能把它当错误行显示。
    test('跳过面板的账号说明行（[按账号并发] / [指定账号]）', () {
      const conc =
          '[按账号并发] JD_COOKIE 共 3 个账号（只算已启用的，按环境变量页'
          '顺序），本次运行第 2 个，每个账号单独一个进程';
      const desi =
          '[指定账号] 只把 JD_COOKIE 共 3 个账号（只算已启用的，按环境变量页'
          '顺序）中的第 2 个交给脚本，脚本自己的编号会从 1 开始';
      for (final notice in [conc, desi]) {
        final withEarlier = compressLikePanel(
          [
            '=== 开始执行 [2026-11-27 08:00:00] ===',
            '登录态已过期，请重新抓包',
            notice,
            '=== 执行结束 [2026-11-27 08:00:01] 耗时 0.50 秒 退出码 1 ===',
          ].join('\n'),
        );
        expect(pickLogErrorLine(withEarlier), '登录态已过期，请重新抓包');

        final onlyNotice = compressLikePanel(
          [
            '=== 开始执行 [2026-11-27 08:00:00] ===',
            '  $notice\r',
            '=== 执行结束 [2026-11-27 08:00:01] 耗时 0.50 秒 退出码 1 ===',
          ].join('\n'),
        );
        expect(pickLogErrorLine(onlyNotice), isNull);
      }
    });

    test('只看尾部 8 KB：前面再长也能取到最后的错误行', () {
      final head = List.filled(5000, 'ok line').join('\n');
      final content = compressLikePanel('$head\nFatal: 磁盘已满\n');
      expect(pickLogErrorLine(content), 'Fatal: 磁盘已满');
    });
  });

  group('与面板、全屏日志「首处报错」同一张关键词表', () {
    test('关键词与面板 attentionErrorKeywords 逐项一致', () {
      // server/service/system_attention.go 的 attentionErrorKeywords。
      expect(kLogErrorKeywords, const [
        'error', 'exception', 'traceback', 'fail', 'fatal', 'timeout', //
        'timed out', 'denied', 'refused', 'not found',
        '错误', '异常', '失败', '超时', '拒绝', '找不到', '不存在',
      ]);
    });

    // 列表失败行下面显示的这一行，点进全屏日志也要认成「首处报错」，
    // 不能一边说「这里出错」、一边说「没有报错」。
    test('列表按关键词挑中的错误行，全屏日志也认成报错', () {
      final lines = [
        for (final keyword in kLogErrorKeywords) '任务出了点状况：$keyword',
        '❌ 账号1: 请求超时',
        '连接被拒绝',
        '账号不存在',
        'Login failure',
        'connect ECONNREFUSED 127.0.0.1:443',
        '404 Not Found',
        'Error: 令牌已失效',
        // 整点启动、头一秒就挂：行首时间的 00 不能读成「0 个」。
        '2026-11-27 08:00:00 超时',
        '08:00:00 ERROR boom',
        '08:00 失败',
      ];
      for (final line in lines) {
        // 错误行在前、普通行在后：只有按关键词才会挑中它，不是退回最后一行。
        final picked = pickLogErrorLine(
          compressLikePanel('$line\n签到流程结束\n'),
        );
        expect(picked, line, reason: line);
        expect(looksLikeLogErrorLine(line), isTrue, reason: line);
      }
    });
  });
}
