// 任务列表的「分组 → 扁平行」数据层。纯函数 + 纯数据类，不依赖 Flutter，可直接单测。
//
// ── 为什么要摊平（issue #107「任务页太多就卡」）──────────────────────────
// 改动前任务页是 `ListView(children: groupedTasks.map(_buildTaskGroup))`：
// 每个分组被包成一个 `Column`，组内任务用 `...group.tasks.map(...)` 一次性展开。
// `Column` 没有惰性布局，有多少条任务就建多少个 Element/RenderObject，
// 而每张任务卡是 `PopScope` + `Stack` + 5 个侧滑按钮 + 一堆 chip，几十个 widget 起步。
// 最糟的是「从没建过分组」的用户只有一个桶，整个 ListView 只有 1 个孩子，
// sliver 的惰性机制被完全旁路 —— 滚不滚动都一样卡。
//
// 摊平成「分组头行 + 任务行」的一维列表之后，就能交给 `ListView.builder`
// 按 index 惰性构建，只有可见区域（加 cacheExtent）那几张卡会被真正建出来。
//
// ── 为什么不顺手做增量分页 ──────────────────────────────────────────────
// provider 依旧 `all=1` 一次性把任务全量拉进内存。分组下拉项、全选、
// 拖拽排序都建立在「全部任务都在手上」这个前提上，改成增量分页会把它们**算错**
// （排序甚至会把没加载到的任务 sort_order 写坏），属于数据损坏而不是显示问题。
// 所以这一轮只修渲染，不动取数。

import '../../../shared/models/task.dart';

/// 一个分组桶。
///
/// [key] 是分组名，**未分组固定为空串**（折叠态、分组排序都按这个 key 存），
/// [title] 是显示用标题（未分组显示成「未分组」）。
class TaskGroup {
  TaskGroup({required this.key, required this.title});

  final String key;
  final String title;
  final List<Task> tasks = <Task>[];
}

/// 按任务标签里的「分组:」前缀分桶。
///
/// 组内任务保持服务端给的原始顺序（置顶 / sort_order 已经在后端排好），
/// 桶本身按首次出现顺序排列，随后再交给 [sortTaskGroupsByOrder] 应用用户的分组序。
List<TaskGroup> groupTasksByGroupName(List<Task> tasks) {
  final groups = <TaskGroup>[];
  final map = <String, TaskGroup>{};

  for (final task in tasks) {
    final groupName = task.groupName?.trim();
    final key = (groupName == null || groupName.isEmpty) ? '' : groupName;
    final title = key.isEmpty ? '未分组' : key;
    final entry = map.putIfAbsent(key, () {
      final created = TaskGroup(key: key, title: title);
      groups.add(created);
      return created;
    });
    entry.tasks.add(task);
  }

  return groups;
}

/// 应用用户拖拽保存的分组顺序。[groupOrder] 为空表示从没排过，原样返回。
///
/// 与改造前一致：**原地排序并返回同一个 list**（分组拖拽视图会继续就地增删这个 list）。
/// 不在 [groupOrder] 里的分组（新建的）统一排到最后，相互之间保持原顺序。
List<TaskGroup> sortTaskGroupsByOrder(
  List<TaskGroup> groups,
  List<String> groupOrder,
) {
  if (groupOrder.isEmpty) {
    return groups;
  }
  final orderMap = <String, int>{};
  for (var i = 0; i < groupOrder.length; i++) {
    orderMap[groupOrder[i]] = i;
  }
  groups.sort((a, b) {
    final ai = orderMap[a.key] ?? 9999;
    final bi = orderMap[b.key] ?? 9999;
    if (ai != bi) return ai.compareTo(bi);
    return 0;
  });
  return groups;
}

/// 列表里的一行：要么是一条分组头，要么是一张任务卡。
///
/// 两种行共用同一个 `ListView.builder`，所以 [rowKey] 必须在整张列表里唯一。
class TaskListRow {
  TaskListRow.groupHeader(this.group) : task = null;

  TaskListRow.taskCard(this.group, Task this.task);

  /// 这一行所属的分组桶。分组头要用它渲染标题 / 条数 / 溢出菜单。
  final TaskGroup group;

  /// 任务行的任务；分组头行为 null。
  final Task? task;

  bool get isGroupHeader => task == null;

  /// 列表项 key。任务卡沿用改造前的 `task-card-<id>`（`_TaskCard` 靠它保住侧滑状态）。
  String get rowKey =>
      task == null ? 'group-header-${group.key}' : 'task-card-${task!.id}';
}

/// 把分组桶摊平成一维行列表。
///
/// - [collapsedGroups] 是折叠中的分组 key 集合，折叠的组**只产出分组头、不产出任务行**；
/// - [showGroupHeader] 为 false 时整张列表不渲染分组头（页面上只有一个「未分组」桶的场景）。
///   这种情况下必须**连折叠状态一起忽略**：没有分组头就没有任何入口能再展开，
///   上一次会话遗留在 collapsedGroups 里的空 key 会让整页任务凭空消失。
List<TaskListRow> buildTaskListRows({
  required List<TaskGroup> groups,
  required Set<String> collapsedGroups,
  required bool showGroupHeader,
}) {
  final rows = <TaskListRow>[];
  for (final group in groups) {
    if (showGroupHeader) {
      rows.add(TaskListRow.groupHeader(group));
    }
    final collapsed = showGroupHeader && collapsedGroups.contains(group.key);
    if (collapsed) {
      continue;
    }
    for (final task in group.tasks) {
      rows.add(TaskListRow.taskCard(group, task));
    }
  }
  return rows;
}
