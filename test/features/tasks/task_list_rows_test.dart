import 'package:daidai_app/features/tasks/utils/task_list_rows.dart';
import 'package:daidai_app/shared/models/task.dart';
import 'package:flutter_test/flutter_test.dart';

/// 任务列表「分组 → 扁平行」的回归保护（issue #107 虚拟化改造）。
///
/// 页面把这些行直接喂给 `ListView.builder`，所以行序错一格就是整页错位。
/// 三个必须守住的点：
/// 1. **折叠的组只留分组头**，不能再产出任务行；
/// 2. **不显示分组头时必须连折叠状态一起忽略** —— 没有分组头就没有展开入口，
///    上次会话遗留的空 key 折叠态会让整页任务凭空消失；
/// 3. **行 key 全局唯一**，且任务行沿用改造前的 `task-card-<id>`
///    （`_TaskCard` 靠它在 Element 复用时保住自己的侧滑状态）。
void main() {
  group('groupTasksByGroupName', () {
    test('没有分组标签的任务全部落进 key 为空的「未分组」桶', () {
      final groups = groupTasksByGroupName([_task(1), _task(2)]);
      expect(groups.length, 1);
      expect(groups.single.key, '');
      expect(groups.single.title, '未分组');
      expect(groups.single.tasks.map((t) => t.id).toList(), [1, 2]);
    });

    test('按分组标签分桶，桶序 = 首次出现顺序，组内保持原顺序', () {
      final groups = groupTasksByGroupName([
        _task(1, group: 'B'),
        _task(2),
        _task(3, group: 'A'),
        _task(4, group: 'B'),
      ]);
      expect(groups.map((g) => g.key).toList(), ['B', '', 'A']);
      expect(groups.first.tasks.map((t) => t.id).toList(), [1, 4]);
      expect(groups[1].tasks.map((t) => t.id).toList(), [2]);
    });

    test('空任务列表产出空桶列表', () {
      expect(groupTasksByGroupName(const []), isEmpty);
    });
  });

  group('sortTaskGroupsByOrder', () {
    test('按保存的分组顺序排，没排过（空顺序）时原样返回', () {
      final tasks = [_task(1, group: 'A'), _task(2, group: 'B')];

      final untouched = sortTaskGroupsByOrder(
        groupTasksByGroupName(tasks),
        const [],
      );
      expect(untouched.map((g) => g.key).toList(), ['A', 'B']);

      final reordered = sortTaskGroupsByOrder(
        groupTasksByGroupName(tasks),
        const ['B', 'A'],
      );
      expect(reordered.map((g) => g.key).toList(), ['B', 'A']);
    });

    test('不在顺序表里的分组（新建的）排到最后', () {
      final groups = groupTasksByGroupName([
        _task(1, group: 'A'),
        _task(2, group: '新建的'),
        _task(3, group: 'B'),
      ]);
      final sorted = sortTaskGroupsByOrder(groups, const ['B', 'A']);
      expect(sorted.map((g) => g.key).toList(), ['B', 'A', '新建的']);
    });
  });

  group('buildTaskListRows', () {
    test('多组：分组头 + 组内任务交替铺开', () {
      final rows = buildTaskListRows(
        groups: groupTasksByGroupName([
          _task(1, group: 'A'),
          _task(2, group: 'A'),
          _task(3, group: 'B'),
        ]),
        collapsedGroups: <String>{},
        showGroupHeader: true,
      );
      expect(rows.map((r) => r.rowKey).toList(), [
        'group-header-A',
        'task-card-1',
        'task-card-2',
        'group-header-B',
        'task-card-3',
      ]);
      expect(rows.first.isGroupHeader, isTrue);
      expect(rows.first.task, isNull);
      expect(rows[1].isGroupHeader, isFalse);
      expect(rows[1].task!.id, 1);
      // 任务行也要带着自己所属的桶，分组头之外的地方不需要再查一次归属。
      expect(rows[1].group.key, 'A');
    });

    test('折叠的组只留分组头，其它组不受影响', () {
      final rows = buildTaskListRows(
        groups: groupTasksByGroupName([
          _task(1, group: 'A'),
          _task(2, group: 'B'),
          _task(3, group: 'B'),
        ]),
        collapsedGroups: <String>{'A'},
        showGroupHeader: true,
      );
      expect(rows.map((r) => r.rowKey).toList(), [
        'group-header-A',
        'group-header-B',
        'task-card-2',
        'task-card-3',
      ]);
    });

    test('全部折叠时只剩分组头', () {
      final rows = buildTaskListRows(
        groups: groupTasksByGroupName([
          _task(1, group: 'A'),
          _task(2, group: 'B'),
        ]),
        collapsedGroups: <String>{'A', 'B'},
        showGroupHeader: true,
      );
      expect(rows.map((r) => r.rowKey).toList(), [
        'group-header-A',
        'group-header-B',
      ]);
    });

    test('未分组（不显示分组头）时只出任务行，且忽略遗留的折叠态', () {
      // 空 key 落在 collapsedGroups 里是常态：_restoreTaskUiState 读不到存储时
      // 会默认塞一个空串进去。此时若还认折叠，整页任务会直接消失且无法展开。
      final rows = buildTaskListRows(
        groups: groupTasksByGroupName([_task(1), _task(2)]),
        collapsedGroups: <String>{''},
        showGroupHeader: false,
      );
      expect(rows.map((r) => r.rowKey).toList(), [
        'task-card-1',
        'task-card-2',
      ]);
      expect(rows.every((r) => !r.isGroupHeader), isTrue);
    });

    test('空列表产出空行列表，itemCount 直接为 0', () {
      expect(
        buildTaskListRows(
          groups: const [],
          collapsedGroups: <String>{},
          showGroupHeader: true,
        ),
        isEmpty,
      );
    });

    test('行 key 在整张列表里唯一 —— 分组头和任务卡共用一个 ListView', () {
      final rows = buildTaskListRows(
        groups: groupTasksByGroupName([
          _task(1, group: 'A'),
          _task(2, group: 'B'),
          _task(3),
        ]),
        collapsedGroups: <String>{},
        showGroupHeader: true,
      );
      final keys = rows.map((r) => r.rowKey).toList();
      expect(keys.toSet().length, keys.length);
    });
  });
}

/// 造一条最小可用的任务。分组走真实的「分组:」标签，不绕过 `Task.groupName`。
Task _task(int id, {String? group}) => Task.fromJson(<String, dynamic>{
  'id': id,
  'name': '任务 $id',
  'labels': group == null ? '' : Task.toGroupLabel(group),
});
