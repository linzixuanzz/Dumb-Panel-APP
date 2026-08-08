import 'package:daidai_app/shared/models/task_log.dart';
import 'package:daidai_app/shared/utils/duration_utils.dart';
import 'package:flutter_test/flutter_test.dart';

/// 耗时分档的回归保护。
///
/// 这一组用例守三条规则：
///
/// 1. **大耗时必须让人一眼看懂。** 用户的原话是「4711 秒都不知道是多少分钟」，
///    改动前 APP 会写成 `78m31s`，跑满两小时的任务写成 `120m0s`。
/// 2. **全档一律向下截断，不四舍五入。** 截断从结构上锁死了每档的上界
///    （ms ≤ 999、秒位 ≤ 59.9、分位与秒位 ≤ 59），不需要写进位兜底；
///    四舍五入则会冒出 `60.0s` / `59m60s` / `1000ms` 这类不存在的档位。
/// 3. **与面板 `web/src/utils/duration.ts` 逐字一致。** 同一条日志在 Web 上写
///    `1h18m`、在 APP 上写 `78m31s`，用户会以为是两条数据。真源是面板那份，
///    这里的每个期望值都能在面板上跑出同样结果。
void main() {
  group('零与毫秒档（[0, 1)）', () {
    test('0 秒显示 0s，不是 0ms', () {
      // 服务端在任务**开始运行**时会把 last_running_time 重置为 0.0
      // （server/service/task_executor.go:207），写 0ms 会让人以为真跑了 0 毫秒。
      expect(formatDurationSeconds(0), '0s');
      expect(formatDurationSeconds(0.0), '0s');
    });

    test('不足 1 秒按整毫秒截断', () {
      expect(formatDurationSeconds(0.856), '856ms');
      expect(formatDurationSeconds(0.5), '500ms');
      expect(formatDurationSeconds(0.999), '999ms');
    });

    test('★ 逼近 1 秒时钳在 999ms，不会冒出 1000ms', () {
      // 截断本身就到不了 1000，math.min(999, ...) 是二次保险。
      expect(formatDurationSeconds(0.9994), '999ms');
      expect(formatDurationSeconds(0.9995), '999ms');
      expect(formatDurationSeconds(0.9996), '999ms');
      expect(formatDurationSeconds(0.9999), '999ms');
    });

    test('比 1 毫秒还小的值截断成 0ms，不伪造成 1ms', () {
      expect(formatDurationSeconds(0.0004), '0ms');
      // 但它与「0 秒」是两种输入，文案也不该一样。
      expect(formatDurationSeconds(0.0004), isNot(formatDurationSeconds(0)));
    });
  });

  group('秒档（[1, 60)）', () {
    test('保留一位小数，截断不进位', () {
      expect(formatDurationSeconds(1), '1.0s');
      expect(formatDurationSeconds(12.34), '12.3s');
      expect(formatDurationSeconds(12.39), '12.3s');
      expect(formatDurationSeconds(59.9), '59.9s');
    });

    test('★ 59.95s 是 59.9s，不能显示成 60.0s', () {
      // 本任务点名的一处。四舍五入的写法在这里会踩两次：
      // `59.95 < 60` 成立，但 toStringAsFixed(1) 会进位成「60.0s」——
      // 一个比 1m 还长的秒。截断从根上不产生这种输出。
      expect(formatDurationSeconds(59.95), '59.9s');
      expect(formatDurationSeconds(59.94), '59.9s');
      expect(formatDurationSeconds(59.99), '59.9s');
      expect(formatDurationSeconds(59.95), isNot(contains('60')));
    });

    test('★ 无限逼近 60 时被 min(599, ...) 封住', () {
      // truncateToTenth 里的 toStringAsFixed(6) 是四舍五入，
      // 59.9999999999 会被它顶成 600，没有那道 min 就会输出「60.0s」。
      expect(formatDurationSeconds(59.9999999999), '59.9s');
      expect(formatDurationSeconds(59.999999999999), '59.9s');
    });

    test('★ 浮点噪声不能吃掉 0.1 —— toStringAsFixed(6) 那道保护', () {
      // 直接 (v * 10).floor() 会在某些值上落到 `28.999999999999996`
      // 这种比整数略小的位置，截断就凭空少了 0.1（2.9s 显示成 2.8s）。
      // 这里把 [1, 60) 的每个 0.1 刻度都过一遍，逐个断言原样显示。
      final bad = <String>[];
      for (var i = 10; i < 600; i++) {
        final value = i / 10;
        final text = formatDurationSeconds(value);
        if (text != '${value.toStringAsFixed(1)}s') {
          bad.add('$value -> $text');
        }
      }
      expect(bad, isEmpty);
    });
  });

  group('分档（[60, 3600)）', () {
    test('分 + 整秒', () {
      expect(formatDurationSeconds(312), '5m12s');
      expect(formatDurationSeconds(90), '1m30s');
      expect(formatDurationSeconds(3599), '59m59s');
    });

    test('恰好 60s 是分档的第一格', () {
      expect(formatDurationSeconds(60), '1m');
      expect(formatDurationSeconds(60.4), '1m');
      expect(formatDurationSeconds(60.9), '1m');
    });

    test('整分时省略秒位，不写 5m0s', () {
      expect(formatDurationSeconds(300), '5m');
      expect(formatDurationSeconds(1800), '30m');
    });

    test('★ 秒位截断，不进位到下一分钟', () {
      // 四舍五入会把这几个说成 2m / 3m / 1h，各差不到 1 秒但档位全变了。
      expect(formatDurationSeconds(119.6), '1m59s');
      expect(formatDurationSeconds(179.5), '2m59s');
      expect(formatDurationSeconds(3599.7), '59m59s');
      expect(formatDurationSeconds(3599.999), '59m59s');
    });
  });

  group('小时档（>= 3600）', () {
    test('★ 用户举的 4711.9s 显示成 1h18m', () {
      // 改动前是 `78m31s`。注意 1111.9s = 18.53 分，
      // 四舍五入会说成 1h19m —— 这也是全档统一用截断的起点。
      expect(formatDurationSeconds(4711.9), '1h18m');
    });

    test('恰好 3600s 是小时档的第一格，整点时省略分位', () {
      expect(formatDurationSeconds(3599.4), '59m59s');
      expect(formatDurationSeconds(3600), '1h');
      expect(formatDurationSeconds(21600), '6h');
    });

    test('分位截断，不把 1h59m59s 说成 2h', () {
      expect(formatDurationSeconds(4733), '1h18m');
      expect(formatDurationSeconds(7199), '1h59m');
      expect(formatDurationSeconds(7200), '2h');
    });

    test('跑满两小时不再写成 120m0s', () {
      expect(formatDurationSeconds(7200), '2h');
      expect(formatDurationSeconds(7200), isNot(contains('m')));
    });

    test('超长任务也只用时分两级', () {
      expect(formatDurationSeconds(86400), '24h');
      expect(formatDurationSeconds(90061), '25h1m');
    });
  });

  group('非法输入一律 "-"，不编一个耗时出来', () {
    test('null', () {
      expect(formatDurationSeconds(null), '-');
    });

    test('负数（时钟回拨时面板真的会算出负的耗时）', () {
      // 宁可显示 "-" 也不显示 "-500ms"。
      expect(formatDurationSeconds(-1), '-');
      expect(formatDurationSeconds(-0.5), '-');
      expect(formatDurationSeconds(-4711.9), '-');
    });

    test('NaN —— 比大小全是 false，不显式挡住会一路掉进小时档', () {
      expect(formatDurationSeconds(double.nan), '-');
    });

    test('无穷 —— Infinity.floor() 在 Dart 里直接抛异常', () {
      expect(formatDurationSeconds(double.infinity), '-');
      expect(formatDurationSeconds(double.negativeInfinity), '-');
      // 真抛出来的话这条会是 UnsupportedError 而不是断言失败，特此留个记号。
      expect(() => formatDurationSeconds(double.infinity), returnsNormally);
    });
  });

  group('穷举扫描：截断语义下不存在越界输出', () {
    test('0 ~ 9000s 步长 0.1 共 90001 个值，没有 60.0s / m60s / h60m / 1000ms', () {
      // 与面板那边同一组穷举。截断从结构上锁死上界，这条应当恒绿；
      // 一旦有人把某档改回四舍五入，这里会立刻抓到。
      final bad = <String>[];
      for (var i = 0; i <= 90000; i++) {
        final value = i / 10;
        final text = formatDurationSeconds(value);
        if (text.contains('60.0s') ||
            text.contains('m60s') ||
            text.contains('h60m') ||
            text.contains('1000ms')) {
          bad.add('$value -> $text');
        }
      }
      expect(bad, isEmpty);
    });
  });

  group('TaskLog.durationText 委托给同一个函数', () {
    test('日志列表拿到的文案与纯函数一致', () {
      expect(_log(4711.9).durationText, '1h18m');
      expect(_log(59.95).durationText, '59.9s');
      expect(_log(0.856).durationText, '856ms');
      expect(_log(0).durationText, '0s');
    });

    test('duration 缺失时是 "-"', () {
      expect(_log(null).durationText, '-');
    });
  });
}

TaskLog _log(double? duration) {
  return TaskLog.fromJson(<String, dynamic>{
    'id': 1,
    'task_id': 2,
    'duration': duration,
  });
}
