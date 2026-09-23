import 'package:daidai_app/features/tasks/providers/task_provider.dart';
import 'package:daidai_app/shared/models/task.dart';
import 'package:daidai_app/shared/models/task_view.dart';
import 'package:daidai_app/shared/utils/api_utils.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_http_adapter.dart';

/// 拖拽排序改走 `PUT /tasks/sort`（面板 v3.2.1 起，只写 list_order）。
///
/// 以前「完成」时逐条 `PUT /tasks/:id {sort_order}`：N 条任务发 N 个请求，
/// 写的还是开机任务的串行执行顺序。这里钉住四件事：
/// 1. 松手一次只发一次 `PUT /tasks/sort`，锚与 position 按落点推算；
/// 2. 面板拒绝（跨区 400 / 老面板）时，本地顺序恢复成服务端顺序，原因能被页面展示出来；
/// 3. 老面板那种「被 PUT /tasks/:id 接走」的 404 翻译成「请升级」，新面板自己的 404 不误判；
/// 4. 视图带排序规则、或有任务在运行时不许拖（同网页端 dragSortDisabledReason）。
void main() {
  Map<String, dynamic> taskJson(
    int id, {
    bool pinned = false,
    num status = 1,
  }) => {
    'id': id,
    'name': '任务$id',
    'status': status,
    'is_pinned': pinned,
  };

  /// GET /tasks 始终回 [serverTasks]（服务端顺序）；PUT /tasks/sort 回 [sortResponse]。
  /// [sortBodies] 记下每次排序请求的 body，[orderDuringRequest] 记下请求发出那一刻本地的顺序。
  FakeHttpAdapter buildAdapter({
    required List<Map<String, dynamic>> serverTasks,
    required ResponseBody Function() sortResponse,
    required List<Object?> sortBodies,
    List<List<int>>? orderDuringRequest,
    TaskNotifier Function()? notifierRef,
  }) {
    return FakeHttpAdapter((options) {
      if (options.method == 'PUT' && options.path == '/api/tasks/sort') {
        sortBodies.add(options.data);
        if (notifierRef != null) {
          orderDuringRequest?.add(
            notifierRef().state.tasks.map((task) => task.id).toList(),
          );
        }
        return sortResponse();
      }
      return jsonResponse({'data': serverTasks, 'total': serverTasks.length});
    });
  }

  List<int> idsOf(TaskNotifier notifier) =>
      notifier.state.tasks.map((task) => task.id).toList();

  Future<Object> captureError(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      return error;
    }
    fail('应当抛出异常');
  }

  group('请求', () {
    test('拖到最底：只发一次 PUT /tasks/sort，锚是前一条、position=after', () async {
      final bodies = <Object?>[];
      final adapter = buildAdapter(
        serverTasks: [taskJson(1), taskJson(2), taskJson(3)],
        sortResponse: () => jsonResponse({'message': '排序更新成功'}),
        sortBodies: bodies,
      );
      final notifier = TaskNotifier(dio: dioWithAdapter(adapter));
      await notifier.load();

      // ReorderableListView 往下拖到末尾给的是 (0, 3)：newIndex 是「移除前」的下标。
      await notifier.moveTask(0, 3);

      expect(
        adapter.requests.where((request) => request.method == 'PUT'),
        hasLength(1),
        reason: '一次拖拽只能有一个写请求，不能再逐条 PUT /tasks/:id 写 sort_order',
      );
      expect(bodies.single, {
        'source_id': 1,
        'target_id': 3,
        'position': 'after',
      });
      // 成功后刷新一次，拿面板重编号后的顺序。
      expect(adapter.countOf('/api/tasks'), 2);
    });

    test('往上拖：锚是落点后一条、position=before', () async {
      final bodies = <Object?>[];
      final adapter = buildAdapter(
        serverTasks: [taskJson(1), taskJson(2), taskJson(3)],
        sortResponse: () => jsonResponse({'message': '排序更新成功'}),
        sortBodies: bodies,
      );
      final notifier = TaskNotifier(dio: dioWithAdapter(adapter));
      await notifier.load();

      await notifier.moveTask(2, 0);

      expect(bodies.single, {
        'source_id': 3,
        'target_id': 1,
        'position': 'before',
      });
    });

    test('拖到置顶区最后一条：后一条是普通任务，改用前一条置顶任务做锚，不能发成跨区', () async {
      final bodies = <Object?>[];
      final adapter = buildAdapter(
        serverTasks: [
          taskJson(1, pinned: true),
          taskJson(2, pinned: true),
          taskJson(3),
        ],
        sortResponse: () => jsonResponse({'message': '排序更新成功'}),
        sortBodies: bodies,
      );
      final notifier = TaskNotifier(dio: dioWithAdapter(adapter));
      await notifier.load();

      // 把置顶的 1 拖到置顶的 2 下面：落点后一条是普通任务 3。
      await notifier.moveTask(0, 2);

      expect(bodies.single, {
        'source_id': 1,
        'target_id': 2,
        'position': 'after',
      });
    });

    test('任意拖法：按面板 task_sort.go 的插入语义回放，桶内拖动的结果与本地乐观顺序一致', () async {
      // 置顶 1、2 一个桶，普通 3~6 一个桶。逐个枚举 ReorderableListView 可能给出的 (old, new)，
      // 覆盖上移、下移、移到桶首、移到桶尾，以及拖出本桶。
      const pinnedIds = {1, 2};
      final serverTasks = [
        for (var id = 1; id <= 6; id++)
          taskJson(id, pinned: pinnedIds.contains(id)),
      ];
      final serverIds = [for (final task in serverTasks) task['id'] as int];
      final bodies = <Object?>[];
      final orders = <List<int>>[];
      late TaskNotifier notifier;
      final adapter = buildAdapter(
        serverTasks: serverTasks,
        sortResponse: () => jsonResponse({'message': '排序更新成功'}),
        sortBodies: bodies,
        orderDuringRequest: orders,
        notifierRef: () => notifier,
      );
      notifier = TaskNotifier(dio: dioWithAdapter(adapter));
      await notifier.load();

      // 照抄面板 task_sort.go：同桶兄弟去掉 source，插到 target 的下标处，position=after 再往后一格；
      // 别的桶原样不动。
      List<int> replay(Map body) {
        final source = body['source_id'] as int;
        final sourcePinned = pinnedIds.contains(source);
        final bucket = [
          for (final id in serverIds)
            if (id != source && pinnedIds.contains(id) == sourcePinned) id,
        ];
        var index = bucket.indexOf(body['target_id'] as int);
        if (body['position'] == 'after') index++;
        bucket.insert(index, source);
        final others = [
          for (final id in serverIds)
            if (pinnedIds.contains(id) != sourcePinned) id,
        ];
        return sourcePinned ? [...bucket, ...others] : [...others, ...bucket];
      }

      for (var oldIndex = 0; oldIndex < serverIds.length; oldIndex++) {
        for (var newIndex = 0; newIndex <= serverIds.length; newIndex++) {
          final to = newIndex > oldIndex ? newIndex - 1 : newIndex;
          if (to == oldIndex) continue;
          bodies.clear();
          orders.clear();
          await notifier.moveTask(oldIndex, newIndex);

          final body = bodies.single as Map;
          final sourcePinned = oldIndex < pinnedIds.length;
          final staysInBucket = sourcePinned
              ? to < pinnedIds.length
              : to >= pinnedIds.length;
          if (staysInBucket) {
            expect(
              replay(body),
              orders.single,
              reason: '($oldIndex → $newIndex) 面板落库后的顺序要与松手时看到的一致',
            );
          } else {
            // 真拖出本桶：锚必须是别的桶的任务，面板才会回 400 而不是悄悄落进本桶某处。
            expect(
              pinnedIds.contains(body['target_id']),
              isNot(sourcePinned),
              reason: '($oldIndex → $newIndex) 跨区拖动要让面板拒绝',
            );
          }
        }
      }
    });

    test('原地松手不发请求', () async {
      final bodies = <Object?>[];
      final adapter = buildAdapter(
        serverTasks: [taskJson(1), taskJson(2)],
        sortResponse: () => jsonResponse({'message': '排序更新成功'}),
        sortBodies: bodies,
      );
      final notifier = TaskNotifier(dio: dioWithAdapter(adapter));
      await notifier.load();

      // 往下挪一格再放回原处，ReorderableListView 给的是 (0, 1)。
      await notifier.moveTask(0, 1);

      expect(bodies, isEmpty);
    });
  });

  group('面板拒绝时恢复服务端顺序', () {
    test('跨区拖动回 400：本地先乐观挪位，失败后弹回服务端顺序，面板文案原样可展示', () async {
      const crossBucketMessage =
          '置顶任务与普通任务、启用与禁用任务请分别排序，跨区移动请用置顶 / 启用按钮';
      final bodies = <Object?>[];
      final orderDuringRequest = <List<int>>[];
      late TaskNotifier notifier;
      final adapter = buildAdapter(
        serverTasks: [taskJson(1, pinned: true), taskJson(2), taskJson(3)],
        sortResponse: () =>
            jsonResponse({'error': crossBucketMessage}, status: 400),
        sortBodies: bodies,
        orderDuringRequest: orderDuringRequest,
        notifierRef: () => notifier,
      );
      notifier = TaskNotifier(dio: dioWithAdapter(adapter));
      await notifier.load();

      // 把普通任务 3 拖到最顶上（置顶任务 1 的上面）。
      final error = await captureError(() => notifier.moveTask(2, 0));

      expect(bodies, hasLength(1));
      expect(orderDuringRequest.single, [3, 1, 2], reason: '请求发出时本地已经挪过位');
      expect(idsOf(notifier), [1, 2, 3], reason: '失败后要按服务端顺序弹回去');
      // 页面走 extractErrorMessage 出提示，面板给的原因要原样到用户眼前。
      expect(extractErrorMessage(error, '保存任务排序失败'), crossBucketMessage);
    });

    test('老面板（≤ v3.2.0）：请求被 PUT /tasks/:id 接走回「任务不存在」→ 提示升级并恢复顺序', () async {
      final adapter = buildAdapter(
        serverTasks: [taskJson(1), taskJson(2), taskJson(3)],
        sortResponse: () => jsonResponse({'error': '任务不存在'}, status: 404),
        sortBodies: <Object?>[],
      );
      final notifier = TaskNotifier(dio: dioWithAdapter(adapter));
      await notifier.load();

      final error = await captureError(() => notifier.moveTask(0, 3));

      expect(error, isA<PanelUpgradeRequiredException>());
      expect(
        extractErrorMessage(error, '保存任务排序失败'),
        '当前面板版本不支持，请升级到 v3.2.1 或更高',
      );
      expect(idsOf(notifier), [1, 2, 3]);
    });

    test('没有路由的纯文本 404 同样提示升级', () async {
      final adapter = buildAdapter(
        serverTasks: [taskJson(1), taskJson(2)],
        sortResponse: () => ResponseBody.fromString(
          '404 page not found',
          404,
          headers: {
            Headers.contentTypeHeader: ['text/plain; charset=utf-8'],
          },
        ),
        sortBodies: <Object?>[],
      );
      final notifier = TaskNotifier(dio: dioWithAdapter(adapter));
      await notifier.load();

      final error = await captureError(() => notifier.moveTask(1, 0));

      expect(error, isA<PanelUpgradeRequiredException>());
    });

    test('新面板自己的 404（任务刚被别人删了）原样透出，不误判成老面板', () async {
      final adapter = buildAdapter(
        serverTasks: [taskJson(1), taskJson(2)],
        sortResponse: () => jsonResponse({'error': '目标任务不存在'}, status: 404),
        sortBodies: <Object?>[],
      );
      final notifier = TaskNotifier(dio: dioWithAdapter(adapter));
      await notifier.load();

      final error = await captureError(() => notifier.moveTask(1, 0));

      expect(error, isA<DioException>());
      expect(extractErrorMessage(error, '保存任务排序失败'), '目标任务不存在');
      expect(idsOf(notifier), [1, 2]);
    });
  });

  group('什么时候不许拖（同网页端 dragSortDisabledReason）', () {
    List<Task> tasksOf(List<num> statuses) => [
      for (var i = 0; i < statuses.length; i++)
        Task.fromJson(taskJson(i + 1, status: statuses[i])),
    ];

    test('启用 / 排队中 / 禁用都可以拖：只有运行中会被面板临时提前', () {
      final state = TaskListState(tasks: tasksOf([1, 0.5, 0]));

      expect(state.dragSortDisabledReason, isNull);
    });

    test('有任务在运行：不许拖，并给出与网页端一致的原因', () {
      final state = TaskListState(tasks: tasksOf([1, 2, 1]));

      expect(
        state.dragSortDisabledReason,
        '运行中的任务被临时排到了最前，此时拖拽的落点会算错；等它跑完再拖，或先切到「已启用」/「已禁用」筛选再排',
      );
    });

    test('视图带排序规则：没有任务在跑也不许拖', () {
      final state = TaskListState(
        tasks: tasksOf([1, 1]),
        sortRules: const [TaskViewSortRule(field: 'name')],
      );

      expect(state.dragSortDisabledReason, '当前视图自带排序规则，切到不带排序的视图再拖拽');
    });
  });
}
