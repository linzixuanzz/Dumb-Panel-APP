import 'package:dio/dio.dart';

import '../../core/network/api_endpoints.dart';
import '../../core/network/dio_client.dart';
import '../models/task.dart';
import '../utils/api_utils.dart';

/// 按 id 取一个任务。
///
/// 面板没有 `GET /tasks/:id`（`server/handler/task_routes.go` 里 `/:id` 只有 PUT / DELETE），
/// 只能拉一次不带筛选的全量列表（和任务页同一个口径 `all=1`）再按 id 找。
/// 调用方应先在手上已有的任务里找，找不到才调这里，免得多拉一次全量。
///
/// 返回 null：任务不存在（被删了）。网络错误照常抛出，由调用方决定怎么提示。
/// 现在的调用方：系统集成（小组件 / 快捷方式打开任务）、概览的「最慢 / 最常失败」卡。
Future<Task?> fetchTaskById(int id, {Dio? dio}) async {
  final response = await (dio ?? DioClient.instance.dio).get(
    ApiEndpoints.tasks,
    queryParameters: {'all': 1},
  );
  for (final item in extractPaginated(response.data).items) {
    final task = Task.fromJson(item);
    if (task.id == id) return task;
  }
  return null;
}
