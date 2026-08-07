import 'package:daidai_app/shared/models/dependency.dart';
import 'package:daidai_app/shared/models/task.dart';
import 'package:daidai_app/shared/models/task_log.dart';
import 'package:daidai_app/shared/utils/panel_enums.dart';
import 'package:flutter_test/flutter_test.dart';

/// 面板枚举换算的回归保护。
///
/// 这一组用例守的是一条规则，而不是一堆文案：
/// **面板出现本版 APP 不认识的枚举值时，UI 必须诚实地说「不认识」，
/// 绝不能把它显示成某个已知值。**
///
/// 为什么值得单独测：改动前四处兜底分支分别把未知值说成
/// 「已安装」/「NodeJS」/「常规定时」/「失败」。这类 bug 不会崩、不会报错、
/// 也不会在任何截图里显得异常 —— 它只是安静地骗人。除了断言，没有别的办法防住。
void main() {
  group('任务状态', () {
    test('四个已知值各自有标签', () {
      expect(taskStatusLabel(0), '已禁用');
      expect(taskStatusLabel(0.5), '排队中');
      expect(taskStatusLabel(1), '已启用');
      expect(taskStatusLabel(2), '运行中');
    });

    test('排队中是浮点数 0.5，不能被当成 0 或 1', () {
      // 面板 TaskStatusQueued = 0.5（server/model/task.go:13）。
      // 任何把 status 当 int 读的写法都会把它截成 0 = 已禁用。
      expect(taskStatusLabel(0.5), isNot(taskStatusLabel(0)));
      expect(isKnownTaskStatus(0.5), isTrue);
    });

    test('未知状态不显示成「已禁用」', () {
      expect(taskStatusLabel(3), '未知状态(3)');
      expect(taskStatusLabel(3), isNot(contains('已禁用')));
      expect(isKnownTaskStatus(3), isFalse);
    });

    test('Task.statusText 跟着一起改，未知状态不再谎报已禁用', () {
      expect(_task(status: 3).statusText, '未知状态(3)');
      expect(_task(status: 3).hasKnownStatus, isFalse);
      expect(_task(status: 0).statusText, '已禁用');
    });
  });

  group('任务类型', () {
    test('三个已知值各自有标签', () {
      expect(taskTypeLabel('cron'), '常规定时');
      expect(taskTypeLabel('manual'), '手动运行');
      expect(taskTypeLabel('startup'), '开机运行');
    });

    test('空串按常规定时 —— 这一条兜底是对的，面板 NormalizeTaskType("") 就是 cron', () {
      expect(taskTypeLabel(''), '常规定时');
      expect(taskTypeLabel('   '), '常规定时');
    });

    test('未知类型显示原始值，不谎报常规定时', () {
      expect(taskTypeLabel('interval'), 'interval');
      expect(taskTypeLabel('interval'), isNot('常规定时'));
    });

    test('大小写不敏感，面板归一化时也做了 ToLower', () {
      expect(taskTypeLabel('Manual'), '手动运行');
    });
  });

  group('上次运行结果（Run* 枚举）', () {
    test('2 是「已终止」不是「失败」', () {
      // 面板 RunAborted = 2（server/model/task.go:23），
      // Web 端 TaskDetail.vue:111 也显示「已终止」。
      // 改动前 APP 写的是 `== 0 ? 成功 : 失败`，这是**当前版本就存在**的错误显示。
      expect(taskRunResultLabel(2), '已终止');
      expect(taskRunResultLabel(2), isNot('失败'));
      expect(taskRunResultTone(2), PanelStatusTone.warning);
    });

    test('null 是未运行，0 成功，1 失败', () {
      expect(taskRunResultLabel(null), '未运行');
      expect(taskRunResultLabel(0), '成功');
      expect(taskRunResultLabel(1), '失败');
      expect(taskRunResultTone(1), PanelStatusTone.danger);
    });

    test('未知结果不落到失败上', () {
      expect(taskRunResultLabel(9), '未知结果(9)');
      expect(taskRunResultTone(9), PanelStatusTone.neutral);
    });

    test('Task.lastRunFailed 只认 1；已终止不算失败', () {
      expect(_task(lastRunStatus: 1).lastRunFailed, isTrue);
      expect(_task(lastRunStatus: 2).lastRunFailed, isFalse);
      expect(_task(lastRunStatus: 2).lastRunResultText, '已终止');
    });
  });

  group('日志状态（LogStatus* 枚举）', () {
    test('面板 v3 有四个值，3 是已终止', () {
      expect(logStatusLabel(0), '成功');
      expect(logStatusLabel(1), '失败');
      expect(logStatusLabel(2), '运行中');
      expect(logStatusLabel(3), '已终止');
    });

    test('已终止的色调不能和运行中撞在一起', () {
      // 改动前 log_list_page 的圆点是 `if 成功 绿; if 失败 红; 蓝`，
      // status=3 会亮成「运行中」的蓝，用户会一直等一个已经结束的任务。
      expect(logStatusTone(3), PanelStatusTone.warning);
      expect(logStatusTone(3), isNot(logStatusTone(2)));
    });

    test('null 和未知值都是中性，不再沿用运行中的蓝', () {
      expect(logStatusLabel(null), '未知');
      expect(logStatusTone(null), PanelStatusTone.neutral);
      expect(logStatusLabel(4), '未知状态(4)');
      expect(logStatusTone(4), PanelStatusTone.neutral);
    });

    test('TaskLog 认得 status=3，且不会被当成运行中', () {
      final aborted = TaskLog.fromJson(<String, dynamic>{
        'id': 1,
        'task_id': 2,
        'status': 3,
      });
      expect(aborted.isAborted, isTrue);
      // 这一条是关键：列表页靠 isRunning 决定要不要开轮询 / 画蓝点。
      expect(aborted.isRunning, isFalse);
      expect(aborted.isSuccess, isFalse);
      expect(aborted.isFailed, isFalse);
      expect(aborted.statusText, '已终止');
      expect(aborted.statusTone, PanelStatusTone.warning);
    });

    test('日志状态 2 和任务的 last_run_status 2 含义相反，两套换算不能串', () {
      expect(logStatusLabel(2), '运行中');
      expect(taskRunResultLabel(2), '已终止');
    });
  });

  group('依赖类型 / 状态', () {
    test('三种依赖类型各自有标签', () {
      expect(dependencyTypeLabel('nodejs'), 'NodeJS');
      expect(dependencyTypeLabel('python'), 'Python');
      expect(dependencyTypeLabel('linux'), 'Linux');
    });

    test('未知依赖类型不谎报 NodeJS', () {
      expect(dependencyTypeLabel('golang'), 'golang');
      expect(dependencyTypeLabel('golang'), isNot('NodeJS'));
      // 空串也不猜成 NodeJS：面板对 Dependency.Type 没有「空即 nodejs」的归一化。
      expect(dependencyTypeLabel(''), '未知');
    });

    test('六种依赖状态各自有标签，installed 不再靠兜底', () {
      expect(dependencyStatusLabel('queued'), '排队中');
      expect(dependencyStatusLabel('installing'), '安装中');
      expect(dependencyStatusLabel('removing'), '卸载中');
      expect(dependencyStatusLabel('installed'), '已安装');
      expect(dependencyStatusLabel('failed'), '失败');
      expect(dependencyStatusLabel('cancelled'), '已取消');
    });

    test('未知依赖状态既不显示成「已安装」也不着成功色', () {
      expect(dependencyStatusLabel('paused'), 'paused');
      expect(dependencyStatusLabel('paused'), isNot('已安装'));
      expect(dependencyStatusTone('paused'), PanelStatusTone.neutral);
      expect(dependencyStatusTone('paused'), isNot(PanelStatusTone.success));
    });

    test('Dependency model 跟着一起改', () {
      final dep = _dependency(status: 'paused', type: 'golang');
      expect(dep.statusText, 'paused');
      expect(dep.statusTone, PanelStatusTone.neutral);
      expect(_dependency(status: 'installed').statusText, '已安装');
      expect(
        _dependency(status: 'installed').statusTone,
        PanelStatusTone.success,
      );
    });
  });

  group('formatEnumNumber', () {
    test('整数值不带 .0，小数保留', () {
      expect(formatEnumNumber(3), '3');
      expect(formatEnumNumber(3.0), '3');
      expect(formatEnumNumber(0.5), '0.5');
    });
  });
}

Task _task({double status = 1, int? lastRunStatus}) {
  return Task.fromJson(<String, dynamic>{
    'id': 1,
    'name': 't',
    'command': 'echo',
    'cron_expression': '',
    'status': status,
    'last_run_status': lastRunStatus,
  });
}

Dependency _dependency({required String status, String type = 'nodejs'}) {
  return Dependency.fromJson(<String, dynamic>{
    'id': 1,
    'name': 'axios',
    'type': type,
    'status': status,
  });
}
