import '../../../shared/models/task.dart';

/// 从任务列表里挑出 [taskId] 那条任务的命令。
///
/// 兜底路径专用：老面板的 `GET /api/logs/:id` 不返回 `command`，只能拿任务名当
/// keyword 去任务列表里捞。keyword 在面板侧是 `name LIKE ? OR command LIKE ?`
/// 的模糊匹配，同名或名字互为子串的任务会一起回来，所以**必须按 id 认人**，
/// 取第一条会打开别的任务的脚本。
///
/// 找不到、或那条任务的命令是空串时返回 null。
String? pickCommandFromTasks(List<Task> tasks, int taskId) {
  for (final task in tasks) {
    if (task.id != taskId) {
      continue;
    }
    final command = task.command.trim();
    return command.isEmpty ? null : command;
  }
  return null;
}
