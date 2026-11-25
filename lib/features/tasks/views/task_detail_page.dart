import 'package:flutter/material.dart';

import '../../../core/theme/design_tokens.dart';
import '../../../shared/models/task.dart';
import '../widgets/task_detail_sheet.dart';

/// 任务详情页（`/tasks/:id/detail`）。
///
/// v2.0 起任务详情改成弹层（[showTaskDetailSheet]），列表点任务直接弹层；
/// 这个路由保留下来给深链和旧调用用，内容与弹层是**同一份** [TaskDetailContent]，
/// 只是左上角换成「返回」、多一个下拉刷新。
///
/// 面板没有「按 id 取单个任务」的接口，数据以任务列表 provider 里同 id 的那条为准；
/// 列表里找不到时（比如刚被删）才用路由 extra 传进来的 [initialTask] 兜底。
class TaskDetailPage extends StatelessWidget {
  final int taskId;
  final Task? initialTask;

  const TaskDetailPage({super.key, required this.taskId, this.initialTask});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.palette.bg,
      body: SafeArea(
        child: TaskDetailContent(
          taskId: taskId,
          initialTask: initialTask,
          inSheet: false,
        ),
      ),
    );
  }
}
