import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 一处漏写前景色的按钮样式：位置与样式入口。
typedef _Violation = ({String where, String style});

/// 底色取自状态色（accent / ok / err / warn / purple，含墨色与 tint 淡底）。
final _statusColor = RegExp(r'\.(accent|ok|err|warn|purple)(Ink)?\b');

/// 按钮样式的入口：`XxxButton.styleFrom(` 与 `ButtonStyle(`。
final _styleCall = RegExp(r'\b(\w+\.styleFrom|ButtonStyle)\(');

/// 只留代码：注释和字符串内容都换成空格（换行保留、行号不变，引号保留），
/// 免得注释里、字符串里的 `styleFrom(` 和括号干扰扫描。
String _codeOnly(String src) {
  final out = StringBuffer();
  void blank(int from, int to) {
    for (var k = from; k < to; k++) {
      out.write(src[k] == '\n' ? '\n' : ' ');
    }
  }

  var i = 0;
  while (i < src.length) {
    final c = src[i];
    final next = i + 1 < src.length ? src[i + 1] : '';
    if (c == '/' && next == '/') {
      final end = src.indexOf('\n', i);
      final stop = end < 0 ? src.length : end;
      blank(i, stop);
      i = stop;
    } else if (c == '/' && next == '*') {
      final end = src.indexOf('*/', i + 2);
      final stop = end < 0 ? src.length : end + 2;
      blank(i, stop);
      i = stop;
    } else if (c == "'" || c == '"') {
      // r 前缀的字符串里反斜杠不是转义；三引号一直取到配对的三引号
      final raw = i > 0 && src[i - 1] == 'r';
      final quote = src.startsWith(c * 3, i) ? c * 3 : c;
      var j = i + quote.length;
      while (j < src.length && !src.startsWith(quote, j)) {
        j += !raw && src[j] == r'\' ? 2 : 1;
      }
      final closed = j < src.length;
      out.write(quote);
      blank(i + quote.length, closed ? j : src.length);
      if (closed) out.write(quote);
      i = closed ? j + quote.length : src.length;
    } else {
      out.write(c);
      i++;
    }
  }
  return out.toString();
}

/// 从 [open]（左括号下标）起，取到配对的右括号为止，按顶层逗号切开实参。
/// [code] 已经过 [_codeOnly]，不用再管字符串和注释。
List<String> _topLevelArgs(String code, int open) {
  final args = <String>[];
  var depth = 0;
  var start = open + 1;
  for (var i = open; i < code.length; i++) {
    final c = code[i];
    if (c == '(' || c == '[' || c == '{') {
      depth++;
    } else if (c == ')' || c == ']' || c == '}') {
      depth--;
      if (depth == 0) {
        args.add(code.substring(start, i));
        break;
      }
    } else if (c == ',' && depth == 1) {
      args.add(code.substring(start, i));
      start = i + 1;
    }
  }
  return [
    for (final arg in args)
      if (arg.trim().isNotEmpty) arg.trim(),
  ];
}

/// 扫一份源码，返回底色取自状态色、却没写前景色的按钮样式。
/// [checked] 收集扫到的「底色取自状态色」的样式位置，证明确实扫到了东西。
List<_Violation> _scan(String path, String src, List<String> checked) {
  final code = _codeOnly(src);
  final violations = <_Violation>[];
  for (final match in _styleCall.allMatches(code)) {
    final args = _topLevelArgs(code, match.end - 1);
    bool has(String name) =>
        args.any((arg) => RegExp('^$name\\s*:').hasMatch(arg));
    String? background;
    for (final arg in args) {
      if (RegExp(r'^backgroundColor\s*:').hasMatch(arg)) background = arg;
    }
    if (background == null || !_statusColor.hasMatch(background)) continue;

    final line = '\n'.allMatches(code.substring(0, match.start)).length + 1;
    checked.add('$path:$line');
    if (!has('foregroundColor')) {
      violations.add((where: '$path:$line', style: match.group(1)!));
    }
  }
  return violations;
}

/// 主题里 FilledButton / ElevatedButton 的前景是 primaryBtnFg，是给钴蓝底配的
/// 白字。深色下状态色提亮了，白字压在 err 上只有 2.77:1；淡底（tint）上更
/// 看不见。所以底色取自状态色的按钮必须自己写前景色：实色底用
/// `palette.onStatus`，淡底用对应的墨色。页面级测试只量得到几处，这里把全库
/// 的写法都钉住。
void main() {
  test('扫描器：漏写前景色会被抓到，三元式、夹在中间的注释、字符串不误报', () {
    const bad = '''
FilledButton(
  style: FilledButton.styleFrom(
    backgroundColor: context.palette.err,
  ),
  child: const Text('删除 (1)'),
);
''';
    const good = '''
FilledButton.icon(
  style: FilledButton.styleFrom(
    minimumSize: const Size(0, 44),
    backgroundColor: replace
        ? palette.err
        : null,
    // 替换模式是红底，前景随之换 onStatus
    foregroundColor: replace
        ? palette.onStatus
        : null,
  ),
);
TextButton.styleFrom(foregroundColor: p.errInk);
FilledButton.styleFrom(
  backgroundColor: p.tint(p.warn),
  foregroundColor: p.warnInk,
);
''';
    const plain = '''
FilledButton.styleFrom(backgroundColor: p.primaryBtnBg);
// FilledButton.styleFrom(backgroundColor: p.err)
const url = 'https://x.y/FilledButton.styleFrom(backgroundColor: p.err)';
final path = text.replaceAll(r'\\', '/');
ButtonStyle(backgroundColor: WidgetStatePropertyAll(p.ok));
''';

    final checked = <String>[];
    expect(_scan('bad', bad, checked).map((v) => v.where), ['bad:2']);
    expect(_scan('good', good, checked), isEmpty);
    expect(_scan('plain', plain, checked).map((v) => v.where), ['plain:5']);
    // bad 一处、good 两处（红底 + 淡底）；plain 里注释和字符串的不算
    expect(checked, ['bad:2', 'good:2', 'good:14', 'plain:5']);
  });

  test('lib/ 下底色取自状态色的按钮样式都写了前景色', () {
    final checked = <String>[];
    final violations = <_Violation>[];
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));
    for (final file in files) {
      final path = file.path.replaceAll(r'\', '/');
      violations.addAll(_scan(path, file.readAsStringSync(), checked));
    }

    // 扫描器没失效：至少扫到了那些红底确认按钮
    expect(checked, isNotEmpty);
    expect(
      violations,
      isEmpty,
      reason:
          '这些按钮的底色取自状态色，却没写 foregroundColor，会退回主题的 '
          'primaryBtnFg（钴蓝底上的白字）：\n'
          '${violations.map((v) => '${v.where}  ${v.style}').join('\n')}',
    );
  });
}
