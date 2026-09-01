import 'package:daidai_app/core/network/api_endpoints.dart';
// 只 import 这个纯函数所在的 utils，不 import 日志详情页：从 view 里拿它会把
// file_picker / go_router / riverpod / secure_storage 整条依赖链拖进本文件的
// 编译单元，纯函数的单测不该为此付编译代价。
import 'package:daidai_app/features/logs/utils/task_command_lookup.dart';
import 'package:daidai_app/shared/models/task.dart';
import 'package:daidai_app/shared/models/task_log.dart';
import 'package:daidai_app/shared/utils/api_utils.dart';
import 'package:daidai_app/shared/utils/task_command.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_http_adapter.dart';

/// 日志详情页「编辑对应脚本」的取数链路。
///
/// 这条链路最容易坏的地方不是跳转本身，而是**取命令**：
/// 1. `command` 是面板 v3.2.0 才加进 `GET /api/logs/:id` 的字段，用户连老面板时
///    它根本不存在。按不可空解析会直接抛，按空串处理又会让降级判断失效；
/// 2. 老面板只能靠任务列表兜底，而列表接口的 `keyword` 是模糊匹配
///    （`name LIKE ? OR command LIKE ?`），同名/名字互为子串的任务会一起回来。
///    取第一条就会打开**别的任务**的脚本 —— 用户在错误的文件上编辑并保存。
///
/// 所以下面钉的是这两件事：null 安全，和「按 id 认人」。
void main() {
  // 面板日志详情的最小响应体。省掉的键（duration / ended_at / updated_at 等）
  // 本来就是可空的，这里只关心 command 这一列。
  Map<String, dynamic> logPayload({Object? command = _unset}) {
    return {
      'id': 7,
      'task_id': 12,
      'task_name': '京东签到',
      'content': '=== 开始执行 [2026-08-04 10:00:00] ===\n',
      'status': 0,
      'log_path': 'task_12_京东签到/2026-08-04-10-00-00-000.log',
      'started_at': '2026-08-04T10:00:00Z',
      'created_at': '2026-08-04T10:00:00Z',
      if (!identical(command, _unset)) 'command': command,
    };
  }

  group('TaskLog.fromJson 的 command', () {
    test('新面板带 command：原样拿到', () {
      final log = TaskLog.fromJson(logPayload(command: 'task jd/sign.py'));

      expect(log.command, 'task jd/sign.py');
    });

    test('老面板整个键都没有：是 null，不是空串，也不能抛', () {
      // 这是升级 APP 但没升级面板的用户看到的响应，必须原样能解析。
      final log = TaskLog.fromJson(logPayload());

      expect(log.command, isNull);
      expect(log.taskId, 12);
      expect(log.taskName, '京东签到');
    });

    test('command 是空串 / 纯空白：归一成 null', () {
      // 面板对「没有命令」和「命令是空字符串」不做区分，调用方只判一次 null。
      expect(TaskLog.fromJson(logPayload(command: '')).command, isNull);
      expect(TaskLog.fromJson(logPayload(command: '   ')).command, isNull);
    });

    test('command 是 null：同样归一成 null', () {
      expect(TaskLog.fromJson(logPayload(command: null)).command, isNull);
    });

    test('两侧空白被裁掉，不影响后面的脚本路径解析', () {
      final log = TaskLog.fromJson(logPayload(command: '  task jd/sign.py  '));

      expect(log.command, 'task jd/sign.py');
    });
  });

  group('pickCommandFromTasks', () {
    Task task(int id, String name, String command) {
      return Task.fromJson({'id': id, 'name': name, 'command': command});
    }

    test('按 id 认人，不是取第一条', () {
      // keyword=「签到」会把这三条一起捞回来，只有中间那条才是这次要的。
      final tasks = [
        task(11, '京东签到（旧）', 'task jd/sign_old.py'),
        task(12, '京东签到', 'task jd/sign.py'),
        task(13, '京东签到备份', 'task jd/sign_backup.py'),
      ];

      expect(pickCommandFromTasks(tasks, 12), 'task jd/sign.py');
    });

    test('列表里没有这个 id：返回 null', () {
      // 任务被删了、或 keyword 恰好没搜到它，都会落到这里。
      final tasks = [task(11, '京东签到（旧）', 'task jd/sign_old.py')];

      expect(pickCommandFromTasks(tasks, 12), isNull);
    });

    test('空列表：返回 null', () {
      expect(pickCommandFromTasks(const [], 12), isNull);
    });

    test('命中了但命令是空串：按拿不到处理', () {
      final tasks = [task(12, '京东签到', '   ')];

      expect(pickCommandFromTasks(tasks, 12), isNull);
    });
  });

  group('端到端：从 /logs/:id 的真实响应推到脚本路径', () {
    const logId = 7;

    test('新面板：响应里的 command 一路推到 jd/sign.py', () async {
      final adapter = FakeHttpAdapter(
        (_) => jsonResponse({'data': logPayload(command: 'task jd/sign.py')}),
      );
      final dio = dioWithAdapter(adapter);

      final response = await dio.get(ApiEndpoints.logById(logId));
      final log = TaskLog.fromJson(
        Map<String, dynamic>.from(extractData(response.data) as Map),
      );

      expect(adapter.requests.single.path, ApiEndpoints.logById(logId));
      expect(log.command, 'task jd/sign.py');
      expect(extractScriptPathFromCommand(log.command!), 'jd/sign.py');
    });

    test('老面板：响应里没有 command，转由任务列表兜底补上', () async {
      final adapter = FakeHttpAdapter(
        (_) => jsonResponse({'data': logPayload()}),
      );
      final dio = dioWithAdapter(adapter);

      final response = await dio.get(ApiEndpoints.logById(logId));
      final log = TaskLog.fromJson(
        Map<String, dynamic>.from(extractData(response.data) as Map),
      );
      expect(log.command, isNull);

      // 页面此时才会去打 GET /api/tasks?all=1&keyword=<任务名>，
      // 拿回来的分页结果按 id 过滤出这一条。
      final tasksPayload = <String, dynamic>{
        'data': <Map<String, dynamic>>[
          {'id': 11, 'name': '京东签到（旧）', 'command': 'task jd/sign_old.py'},
          {'id': 12, 'name': '京东签到', 'command': 'task jd/sign.py'},
        ],
        'total': 2,
      };
      final paginated = extractPaginated(tasksPayload);
      final tasks = paginated.items.map(Task.fromJson).toList();

      final command = pickCommandFromTasks(tasks, log.taskId);
      expect(command, 'task jd/sign.py');
      expect(extractScriptPathFromCommand(command!), 'jd/sign.py');
    });

    test('命令不是脚本形态时，解析给 null —— 页面据此弹「不是脚本任务」', () async {
      final adapter = FakeHttpAdapter(
        (_) => jsonResponse({
          'data': logPayload(command: 'curl https://example.com/ping'),
        }),
      );
      final dio = dioWithAdapter(adapter);

      final response = await dio.get(ApiEndpoints.logById(logId));
      final log = TaskLog.fromJson(
        Map<String, dynamic>.from(extractData(response.data) as Map),
      );

      expect(log.command, 'curl https://example.com/ping');
      expect(extractScriptPathFromCommand(log.command!), isNull);
    });
  });
}

/// 「这个键根本不存在」的哨兵，用来把它和「键在、值是 null」区分开 ——
/// 老面板是前者，两者都得能解析。
const Object _unset = Object();
