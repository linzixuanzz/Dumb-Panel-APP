import 'package:daidai_app/shared/utils/task_command.dart';
import 'package:flutter_test/flutter_test.dart';

/// `extractScriptPathFromCommand` 的行为锁。
///
/// 这份逻辑是从 `task_list_page.dart` 的私有函数原样搬到 shared 的，搬它是因为
/// 日志详情页要「跳到对应脚本」。搬移必须**零行为变化**——它同时还是「删除任务时
/// 顺带删除关联脚本」那个勾选框的判定依据，是个破坏性操作。
///
/// 所以这里连几条已知的怪行为也一并钉住（见「已知怪行为」一组）：不是说它们对，
/// 而是说「这次搬移没有偷偷改掉它们」。真要改，改的是另一次提交，得先想清楚误删风险。
void main() {
  group('task / desi 入口', () {
    test('最常见形态：APP 自己生成的就是这种', () {
      // script_list_page 里「加入任务」预填的命令就是 `task <path>`。
      expect(extractScriptPathFromCommand('task jd/sign.py'), 'jd/sign.py');
      expect(extractScriptPathFromCommand('desi jd/sign.py'), 'jd/sign.py');
    });

    test('跳过 task 自己的参数：-m 吃两个 token，-l 吃一个', () {
      expect(extractScriptPathFromCommand('task -m 5 a/b.js'), 'a/b.js');
      expect(extractScriptPathFromCommand('task -l a/b.sh'), 'a/b.sh');
      expect(extractScriptPathFromCommand('task -l -m 3 a/b.ts'), 'a/b.ts');
    });

    test('-m 后面没东西了不能越界', () {
      expect(extractScriptPathFromCommand('task -m'), isNull);
    });

    test('脚本后面的业务参数不参与匹配', () {
      expect(
        extractScriptPathFromCommand('task jd/sign.py --user 1 --debug'),
        'jd/sign.py',
      );
    });

    test('带空格的路径：加引号能整体保住', () {
      expect(
        extractScriptPathFromCommand('task "my scripts/a b.py"'),
        'my scripts/a b.py',
      );
      expect(
        extractScriptPathFromCommand("task 'my scripts/a b.py'"),
        'my scripts/a b.py',
      );
    });

    test('带空格的路径：没引号时从长到短回拼', () {
      expect(
        extractScriptPathFromCommand('task my dir/a b.py'),
        'my dir/a b.py',
      );
    });
  });

  group('解释器入口', () {
    test('python / python3 / node / ts-node / bash / go', () {
      expect(extractScriptPathFromCommand('python x/y.py'), 'x/y.py');
      expect(extractScriptPathFromCommand('python3 x/y.py --flag'), 'x/y.py');
      expect(extractScriptPathFromCommand('node x/y.js'), 'x/y.js');
      expect(extractScriptPathFromCommand('ts-node x/y.ts'), 'x/y.ts');
      expect(extractScriptPathFromCommand('bash x/y.sh'), 'x/y.sh');
    });

    test('解释器后面什么都没有', () {
      expect(extractScriptPathFromCommand('python3'), isNull);
      expect(extractScriptPathFromCommand('node'), isNull);
    });
  });

  group('必须返回 null 的情况（宁可少给入口，也不能误判）', () {
    test('空命令', () {
      expect(extractScriptPathFromCommand(''), isNull);
      expect(extractScriptPathFromCommand('   '), isNull);
    });

    test('不认识的入口命令', () {
      expect(extractScriptPathFromCommand('curl https://example.com'), isNull);
      expect(extractScriptPathFromCommand('echo hello'), isNull);
      // 入口命令大小写敏感，这是现状。
      expect(extractScriptPathFromCommand('TASK a.py'), isNull);
    });

    test('内联 shell：没有独立脚本文件可跳', () {
      expect(extractScriptPathFromCommand('bash -c "echo hi"'), isNull);
    });

    test('扩展名不在白名单里', () {
      // 白名单是故意的：`curl https://x/y.io` 这种不该被当成脚本。
      expect(extractScriptPathFromCommand('task a/b.txt'), isNull);
      expect(extractScriptPathFromCommand('task a/b'), isNull);
    });
  });

  group('已知怪行为（本次只钉住，不改）', () {
    test('go run main.go 会连 run 一起还回来', () {
      // 从长到短回拼时 "run main.go" 先命中 .go。表现是跳转/删除都会落空，
      // 但不会误伤别的文件，所以本次搬移不动它。
      expect(extractScriptPathFromCommand('go run main.go'), 'run main.go');
    });

    test('扩展名匹配不区分大小写，返回值保留原样', () {
      expect(extractScriptPathFromCommand('task A.PY'), 'A.PY');
    });
  });

  group('splitCommandTokens', () {
    test('按空白切，连续空白只切一次', () {
      expect(splitCommandTokens('a  b\tc'), ['a', 'b', 'c']);
    });

    test('成对引号整体保留，引号本身不进结果', () {
      expect(splitCommandTokens('"a b" c'), ['a b', 'c']);
      expect(splitCommandTokens("'a b'"), ['a b']);
      expect(splitCommandTokens('a"b"c'), ['abc']);
    });

    test('引号没闭合时把剩下的都吃进同一个 token', () {
      expect(splitCommandTokens('"abc'), ['abc']);
    });

    test('空串给空列表', () {
      expect(splitCommandTokens(''), isEmpty);
      expect(splitCommandTokens('   '), isEmpty);
    });
  });
}
