import 'package:daidai_app/shared/models/task.dart';
import 'package:flutter_test/flutter_test.dart';

/// 任务「启用开关位」的回归保护（面板 issue #133 的 APP 同款 bug）。
///
/// `status` 一个字段同时装着开关与运行态：禁用任务被手动运行时，排队 / 运行期间
/// status 是 0.5 / 2，与启用任务一模一样。改动前 APP 按 `status == 0` 判开关，
/// 运行中的禁用任务侧滑按钮写「禁用」，点下去是给一条禁用任务再打一次待禁用标记，
/// 用户在它跑完之前根本启用不了它。
///
/// 面板 v3.2.8 起下发 `enabled`（契约 C1）；老面板不下发时必须回退到原来的判断。
void main() {
  group('fromJson 解析 enabled', () {
    test('按 JSON 键名 enabled 解析，true / false 都原样保留', () {
      expect(_task(status: 2, enabled: false).enabled, isFalse);
      expect(_task(status: 2, enabled: true).enabled, isTrue);
    });

    test('老面板不下发这个键时是 null，不能被当成 false', () {
      // 当成 false 的话，老面板上所有任务都会被说成关着、按钮全变「启用」。
      expect(_task(status: 1).enabled, isNull);
      expect(_task(status: 1).isSwitchOn, isTrue);
    });

    test('非布尔值一律当作没下发，回退到 status 判断，不去猜 0 / 1 / 字符串', () {
      for (final raw in <Object?>[0, 1, 'true', 'false', null]) {
        final task = Task.fromJson({..._base, 'status': 0, 'enabled': raw});
        expect(task.enabled, isNull, reason: 'enabled=$raw');
        expect(task.isSwitchOn, isFalse, reason: 'status=0 回退为关');
      }
    });
  });

  group('面板下发了 enabled：以它为准', () {
    test('运行中的禁用任务：开关是关的，按钮给「启用」（#133 的现场）', () {
      final task = _task(status: 2, enabled: false);
      expect(task.isSwitchOn, isFalse);
      expect(task.switchActionLabel, '启用');
    });

    test('排队中的禁用任务同样是关的', () {
      final task = _task(status: 0.5, enabled: false);
      expect(task.isSwitchOn, isFalse);
      expect(task.switchActionLabel, '启用');
    });

    test('运行中 / 排队中的启用任务是开的', () {
      for (final status in [2.0, 0.5]) {
        final task = _task(status: status, enabled: true);
        expect(task.isSwitchOn, isTrue, reason: 'status=$status');
        expect(task.switchActionLabel, '禁用', reason: 'status=$status');
      }
    });

    test('空闲任务：enabled 与 status 一致', () {
      expect(_task(status: 0, enabled: false).switchActionLabel, '启用');
      expect(_task(status: 1, enabled: true).switchActionLabel, '禁用');
    });

    test('状态显示仍按 status：运行中的禁用任务照样是「运行中」', () {
      // 开关位只管「启用 / 禁用」这个动作。状态徽章、圆点颜色、分组头计数说的是
      // 运行态，不能跟着开关位变 —— 运行中的禁用任务确实在跑。
      final task = _task(status: 2, enabled: false);
      expect(task.isRunning, isTrue);
      expect(task.statusText, '运行中');
      expect(task.isDisabled, isFalse);
      expect(task.isEnabled, isFalse);
    });
  });

  group('老面板（不下发 enabled）：回退 status != 0，与改动前逐字相同', () {
    test('0 关，1 / 0.5 / 2 开', () {
      expect(_task(status: 0).isSwitchOn, isFalse);
      expect(_task(status: 1).isSwitchOn, isTrue);
      expect(_task(status: 0.5).isSwitchOn, isTrue);
      expect(_task(status: 2).isSwitchOn, isTrue);
    });

    test('不认识的状态值同样按 != 0 回退（改动前是 !isDisabled）', () {
      expect(_task(status: 3).isSwitchOn, isTrue);
      expect(_task(status: 3).switchActionLabel, '禁用');
    });

    test('老面板上运行中的任务仍给「禁用」：面板没给开关位，APP 猜不出来', () {
      expect(_task(status: 2).switchActionLabel, '禁用');
      expect(_task(status: 0).switchActionLabel, '启用');
    });
  });
}

const Map<String, dynamic> _base = {
  'id': 1,
  'name': '签到',
  'command': 'task jd_sign.js',
  'cron_expression': '0 0 * * *',
};

/// [enabled] 为 null 表示**不下发**这个键（老面板），不是下发一个 null。
Task _task({required double status, bool? enabled}) {
  return Task.fromJson({..._base, 'status': status, 'enabled': ?enabled});
}
