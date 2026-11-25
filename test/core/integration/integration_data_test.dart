import 'package:daidai_app/core/integration/integration_data.dart';
import 'package:daidai_app/shared/models/insights.dart';
import 'package:daidai_app/shared/models/task.dart';
import 'package:flutter_test/flutter_test.dart';

Task _task(
  int id,
  String name, {
  double status = 1,
  DateTime? next,
  DateTime? last,
  int? lastStatus,
}) {
  return Task.fromJson({
    'id': id,
    'name': name,
    'status': status,
    'next_run_at': next?.toIso8601String(),
    'last_run_at': last?.toIso8601String(),
    'last_run_status': lastStatus,
  });
}

/// 系统集成里不碰平台的部分：启动入口解析、快捷方式、小组件快照、通知文案。
void main() {
  group('快捷方式 type → 启动入口', () {
    test('新建任务：在当前页面之上 push /tasks/new', () {
      final a = launchActionFromShortcut(kShortcutNewTask, nonce: 1)!;
      expect(a.route, '/tasks/new');
      expect(a.push, isTrue);
      expect(a.taskId, isNull);
    });

    test('搜索任务：go /tasks?search=<nonce>，每次的值不同', () {
      final a = launchActionFromShortcut(kShortcutSearchTask, nonce: 111)!;
      final b = launchActionFromShortcut(kShortcutSearchTask, nonce: 222)!;
      expect(a.route, '/tasks?search=111');
      expect(a.push, isFalse);
      expect(Uri.parse(b.route).queryParameters['search'], '222');
    });

    test('运行常用任务：打开详情并高亮按住运行，不直接运行', () {
      final a = launchActionFromShortcut('run_task:12', nonce: 1)!;
      expect(a.route, '/tasks');
      expect(a.taskId, 12);
      expect(a.focusRun, isTrue);
    });

    test('不认识的 type / 坏 id：忽略', () {
      expect(launchActionFromShortcut('dashboard', nonce: 1), isNull);
      expect(launchActionFromShortcut('run_task:abc', nonce: 1), isNull);
    });
  });

  group('小组件 URI → 启动入口', () {
    test('daidai://overview、daidai://tasks', () {
      expect(
        launchActionFromWidgetUri(Uri.parse('daidai://overview'))!.route,
        '/overview',
      );
      expect(
        launchActionFromWidgetUri(Uri.parse('daidai://tasks'))!.route,
        '/tasks',
      );
    });

    test('daidai://task/7：打开 7 号任务详情，不高亮运行', () {
      final a = launchActionFromWidgetUri(Uri.parse('daidai://task/7'))!;
      expect(a.route, '/tasks');
      expect(a.taskId, 7);
      expect(a.focusRun, isFalse);
    });

    test('task 缺 id 时退回任务页；别的 scheme / host 忽略', () {
      final a = launchActionFromWidgetUri(Uri.parse('daidai://task'))!;
      expect(a.taskId, isNull);
      expect(a.route, '/tasks');
      expect(launchActionFromWidgetUri(Uri.parse('https://x/tasks')), isNull);
      expect(launchActionFromWidgetUri(Uri.parse('daidai://logs')), isNull);
    });
  });

  test('开屏 / 登录 / 选服务器页上不执行入口，主界面上执行', () {
    expect(isLaunchReadyLocation('/boot'), isFalse);
    expect(isLaunchReadyLocation('/login'), isFalse);
    expect(isLaunchReadyLocation('/server-config'), isFalse);
    expect(isLaunchReadyLocation('/tasks'), isTrue);
    expect(isLaunchReadyLocation('/logs'), isTrue);
  });

  group('快捷方式列表', () {
    test('没有常用任务：只有新建、搜索', () {
      final items = buildShortcutItems(android: true);
      expect(items.map((e) => e.type), [kShortcutNewTask, kShortcutSearchTask]);
      expect(items.map((e) => e.localizedTitle), ['新建任务', '搜索任务']);
      expect(items.first.icon, 'ic_shortcut_add');
    });

    test('有常用任务：加「运行 {名称}」，长名字截断', () {
      final items = buildShortcutItems(
        android: true,
        favoriteId: 5,
        favoriteName: '一个名字特别特别特别长的签到任务',
      );
      expect(items, hasLength(3));
      expect(items.last.type, 'run_task:5');
      expect(items.last.localizedTitle, '运行 一个名字特别特别特别长的…');
      expect(items.last.icon, 'ic_shortcut_run');
    });

    test('iOS 不带图标（没有 asset catalog 资源）', () {
      final items = buildShortcutItems(
        android: false,
        favoriteId: 5,
        favoriteName: '签到',
      );
      expect(items.every((e) => e.icon == null), isTrue);
    });

    test('签名：内容一样就一样', () {
      final a = buildShortcutItems(
        android: true,
        favoriteId: 1,
        favoriteName: 'A',
      );
      final b = buildShortcutItems(
        android: true,
        favoriteId: 1,
        favoriteName: 'A',
      );
      final c = buildShortcutItems(
        android: true,
        favoriteId: 1,
        favoriteName: 'B',
      );
      expect(shortcutSignature(a), shortcutSignature(b));
      expect(shortcutSignature(a), isNot(shortcutSignature(c)));
    });
  });

  group('小组件快照', () {
    final now = DateTime(2026, 11, 25, 12);

    test('下一个：未禁用、未来最早；最近失败：失败里最晚', () {
      final data = widgetDataFromTasks([
        _task(1, '已过', next: now.subtract(const Duration(minutes: 1))),
        _task(2, '晚的', next: now.add(const Duration(hours: 3))),
        _task(3, '早的', next: now.add(const Duration(minutes: 20))),
        _task(
          4,
          '禁用的更早',
          status: 0,
          next: now.add(const Duration(minutes: 5)),
        ),
        _task(
          5,
          '旧失败',
          last: now.subtract(const Duration(hours: 5)),
          lastStatus: 1,
        ),
        _task(
          6,
          '新失败',
          last: now.subtract(const Duration(hours: 1)),
          lastStatus: 1,
        ),
        _task(
          7,
          '新成功',
          last: now.subtract(const Duration(minutes: 1)),
          lastStatus: 0,
        ),
      ], now);
      expect(data[WidgetKeys.nextId], '3');
      expect(data[WidgetKeys.nextName], '早的');
      expect(
        data[WidgetKeys.nextAt],
        now.add(const Duration(minutes: 20)).millisecondsSinceEpoch.toString(),
      );
      expect(data[WidgetKeys.failedId], '6');
      expect(data[WidgetKeys.failedName], '新失败');
    });

    test('都没有时值为 null（小组件侧删键、显示「暂无」）', () {
      final data = widgetDataFromTasks([_task(1, 'a')], now);
      expect(data.keys, contains(WidgetKeys.nextName));
      expect(data[WidgetKeys.nextName], isNull);
      expect(data[WidgetKeys.failedName], isNull);
    });

    test('今日次数存字符串', () {
      expect(widgetDataFromToday(success: 24, failed: 1), {
        WidgetKeys.todaySuccess: '24',
        WidgetKeys.todayFailed: '1',
      });
    });
  });

  group('常驻通知文案', () {
    test('数量做标题，最多列 3 个名称', () {
      final text = runningNotificationText([
        for (var i = 1; i <= 4; i++) RunningTask(taskId: i, name: '任务$i'),
      ]);
      expect(text.title, '4 个任务运行中');
      expect(text.body, '任务1、任务2、任务3 等');
    });

    test('名称为空时给一句点按提示', () {
      final text = runningNotificationText([
        const RunningTask(taskId: 1, name: ''),
      ]);
      expect(text.title, '1 个任务运行中');
      expect(text.body, '点按查看任务');
    });

    test('老面板兜底：任务列表里状态为运行中的', () {
      final running = runningFromTasks([
        _task(1, 'a', status: 2),
        _task(2, 'b', status: 1),
      ]);
      expect(running.map((e) => e.taskId), [1]);
      expect(running.single.name, 'a');
    });
  });
}
