/// 从任务命令里反推它执行的是哪个脚本文件。
///
/// 这份逻辑原来是 `task_list_page.dart` 里的私有函数，只服务「删除任务时顺带删掉
/// 关联脚本」那个勾选框。日志详情页要跳到脚本编辑页也需要它，才提到 shared —— 搬移时
/// 行为一个字节都没改，`task_command_test.dart` 就是用来钉住这一点的。
///
/// ⚠️ 它仍然是「删除关联脚本」这个**破坏性操作**的判定依据。改这里之前先想清楚：
/// 判宽了会误删用户的脚本，判窄了只是少一个便利入口。**宁可返回 null。**
///
/// 面板侧另有两份同语义实现，三边并不完全一致（这是现状，不是本次要统一的东西）：
/// - Go：`server/service/task_executor.go` 的 `extractTaskScriptPath`
///   （把 `desi` 归进解释器组，额外认 python3.10/3.11/3.12）
/// - Web：`web/src/views/tasks/taskCommand.ts` 的 `extractTaskCommandScriptPath`
///   （认 `--` 终止符，多认 nodejs/sh，且入口命令不认识时会回退取第一个像脚本的 token）
library;

/// 支持的脚本扩展名。故意保持白名单而不是「有点就算」——
/// `curl https://x/y.io` 这种不该被当成脚本。
const _supportedScriptExtensions = <String>['.py', '.js', '.ts', '.sh', '.go'];

/// 解析不出来时返回 null（命令为空、不是脚本形态、入口命令不认识）。
String? extractScriptPathFromCommand(String command) {
  final trimmed = command.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  final tokens = splitCommandTokens(trimmed);
  if (tokens.isEmpty) {
    return null;
  }

  bool hasSupportedExtension(String value) {
    final lower = value.toLowerCase();
    return _supportedScriptExtensions.any(lower.endsWith);
  }

  // 路径里可能有空格（tokenizer 已经按引号切过一轮，但没引号的空格路径只能靠回拼）。
  // 从长到短拼，先命中的就是最完整的那条。
  String? joinCandidate(List<String> items) {
    for (var count = items.length; count >= 1; count--) {
      final candidate = items.take(count).join(' ').trim();
      if (hasSupportedExtension(candidate)) {
        return candidate;
      }
    }
    return null;
  }

  switch (tokens.first) {
    case 'task':
    case 'desi':
      final rest = tokens.sublist(1);
      var idx = 0;
      // 跳过 task 自己的参数：-m <并发数> 吃两个 token，-l 只吃一个。
      while (idx < rest.length) {
        if (rest[idx] == '-m' && idx + 1 < rest.length) {
          idx += 2;
          continue;
        }
        if (rest[idx] == '-l') {
          idx += 1;
          continue;
        }
        break;
      }
      return joinCandidate(rest.sublist(idx));
    case 'python':
    case 'python3':
    case 'node':
    case 'ts-node':
    case 'bash':
    case 'go':
      if (tokens.length <= 1) {
        return null;
      }
      return joinCandidate(tokens.sublist(1));
    default:
      return null;
  }
}

/// 按空白切 token，成对的单/双引号视为一个整体（引号本身不进结果）。
List<String> splitCommandTokens(String command) {
  final tokens = <String>[];
  final buffer = StringBuffer();
  String? quote;

  for (final rune in command.runes) {
    final char = String.fromCharCode(rune);
    if (quote != null) {
      if (char == quote) {
        quote = null;
      } else {
        buffer.write(char);
      }
      continue;
    }

    if (char == '"' || char == "'") {
      quote = char;
      continue;
    }

    if (char.trim().isEmpty) {
      if (buffer.isNotEmpty) {
        tokens.add(buffer.toString());
        buffer.clear();
      }
      continue;
    }

    buffer.write(char);
  }

  if (buffer.isNotEmpty) {
    tokens.add(buffer.toString());
  }

  return tokens;
}
