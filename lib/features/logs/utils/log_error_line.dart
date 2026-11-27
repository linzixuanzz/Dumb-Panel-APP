import 'dart:convert';
import 'dart:io';

import '../../../shared/utils/log_error_keywords.dart';

/// 日志列表「失败行直接显示错误行」用的取错误行逻辑。
///
/// 数据来源：`GET /api/logs` 列表里每条日志自带的 `content` 字段 —— 面板把整段执行日志
/// zlib 压缩后再 base64 存进 task_logs.content，列表接口原样下发（server/model/task_log.go 的
/// ToDict）。所以这里**不为每行额外发请求**，就地解压、只看尾部。
///
/// 挑行规则与面板「需要关注」的 `PickAttentionDetail`（server/service/system_attention.go）一致，
/// 两边对同一条失败日志给出同一句话：
/// - 去掉 ANSI 颜色码；
/// - 从尾部往前找，跳过空行、面板自己写的 `=== 开始执行 / 执行结束 ===` 框线，
///   以及 conc / desi 开头那行账号说明（`[按账号并发]` / `[指定账号]`，面板 #187）；
/// - 第一条带错误关键词（[kLogErrorKeywords]）的行；一条都没有就退回最后
///   一条非空行；
/// - 超过 120 字截断。
///
/// 返回 null 的情况：content 为空（运行中、或日志太大落在磁盘文件里，列表接口不带正文）、
/// 解压后没有任何可显示的行。调用方拿到 null 就不显示错误行。
String? pickLogErrorLine(String content) {
  if (content.trim().isEmpty) {
    return null;
  }

  // 只看最后 8 KB：找最后一条错误行足够了，与面板 attentionLogTailBytes 同值。
  const tailBytes = 8 * 1024;
  String text;
  try {
    final bytes = ZLibCodec().decode(base64.decode(content.trim()));
    final tail = bytes.length > tailBytes
        ? bytes.sublist(bytes.length - tailBytes)
        : bytes;
    text = utf8.decode(tail, allowMalformed: true);
  } catch (_) {
    // 不是 base64 + zlib：极老的面板或测试数据直接存明文，按明文处理。
    text = content.length > tailBytes
        ? content.substring(content.length - tailBytes)
        : content;
  }

  final lines = text.replaceAll(_ansiEscape, '').split('\n');
  String? lastNonEmpty;
  for (var i = lines.length - 1; i >= 0; i--) {
    final line = lines[i].trim();
    if (line.isEmpty || line.startsWith('=== ')) {
      continue;
    }
    // 账号说明是面板自己打的，不是失败原因：脚本在它后面什么都没打就挂了，
    // 退回最后一条非空行时也不能拿它顶上。
    if (line.startsWith('[按账号并发]') || line.startsWith('[指定账号]')) {
      continue;
    }
    lastNonEmpty ??= line;
    final lower = line.toLowerCase();
    if (kLogErrorKeywords.any(lower.contains)) {
      return _truncate(line);
    }
  }
  return lastNonEmpty == null ? null : _truncate(lastNonEmpty);
}

/// 终端颜色等 ANSI 转义序列，与面板 ansiEscapePattern 同一条正则。
final _ansiEscape = RegExp(r'\x1b\[[0-9;?]*[A-Za-z]');

String _truncate(String line) {
  const maxRunes = 120;
  final runes = line.runes.toList();
  if (runes.length <= maxRunes) {
    return line;
  }
  return '${String.fromCharCodes(runes.take(maxRunes - 1))}…';
}
