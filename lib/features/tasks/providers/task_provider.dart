import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/task.dart';
import '../../../shared/models/task_log.dart';
import '../../../shared/utils/api_utils.dart';

const _unset = Object();

class TaskListState {
  final List<Task> tasks;
  final int total;
  final bool loading;
  final String? error;
  final String keyword;
  final String? statusFilter;
  final String? labelFilter;

  const TaskListState({
    this.tasks = const [],
    this.total = 0,
    this.loading = false,
    this.error,
    this.keyword = '',
    this.statusFilter,
    this.labelFilter,
  });

  TaskListState copyWith({
    List<Task>? tasks,
    int? total,
    bool? loading,
    String? error,
    String? keyword,
    Object? statusFilter = _unset,
    Object? labelFilter = _unset,
  }) {
    return TaskListState(
      tasks: tasks ?? this.tasks,
      total: total ?? this.total,
      loading: loading ?? this.loading,
      error: error,
      keyword: keyword ?? this.keyword,
      statusFilter: identical(statusFilter, _unset)
          ? this.statusFilter
          : statusFilter as String?,
      labelFilter: identical(labelFilter, _unset)
          ? this.labelFilter
          : labelFilter as String?,
    );
  }
}

class TaskNotifier extends StateNotifier<TaskListState> {
  /// [dio] **仅供测试注入**，生产路径不传，仍然走 `DioClient` 单例。
  /// 单例的 baseUrl 会随切换面板被改写，所以这里不在构造时把它存下来。
  TaskNotifier({Dio? dio}) : _injectedDio = dio, super(const TaskListState());

  final Dio? _injectedDio;

  Dio get _dio => _injectedDio ?? DioClient.instance.dio;

  /// 任务列表**一次性全量拉取**（`all=1`），刻意没有 `loadMore`。
  ///
  /// 分组下拉项、全选、拖拽排序都建立在「全部任务都在内存里」这个前提上：
  /// 改成增量分页会让分组项残缺、全选变成「只全选已加载的」，
  /// 排序保存更会按当前列表顺序把未加载任务的 sort_order 写坏 —— 属于数据损坏。
  /// 列表卡顿由页面侧的 `ListView.builder` 虚拟化解决，不靠减少取回来的数据量。
  Future<void> load({bool refresh = false}) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final dio = _dio;
      final queryParams = <String, dynamic>{'all': 1};
      if (state.keyword.isNotEmpty) {
        queryParams['keyword'] = state.keyword;
      }
      if (state.statusFilter != null) {
        queryParams['status'] = state.statusFilter;
      }
      if (state.labelFilter != null) {
        queryParams['label'] = state.labelFilter;
      }

      final response = await dio.get(
        ApiEndpoints.tasks,
        queryParameters: queryParams,
      );
      final paginated = extractPaginated(response.data);
      final items = paginated.items.map((e) => Task.fromJson(e)).toList();
      final total = paginated.total;

      state = state.copyWith(tasks: items, total: total, loading: false);
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: extractListErrorMessage(e, '加载任务失败'),
      );
    }
  }

  void setKeyword(String keyword) {
    state = state.copyWith(keyword: keyword);
    load(refresh: true);
  }

  void setStatusFilter(String? status) {
    state = state.copyWith(statusFilter: status);
    load(refresh: true);
  }

  void setLabelFilter(String? label) {
    state = state.copyWith(labelFilter: label);
    load(refresh: true);
  }

  Future<void> runTask(int id) async {
    await _dio.put(ApiEndpoints.taskRun(id));
    await load(refresh: true);
  }

  Future<void> stopTask(int id) async {
    await _dio.put(ApiEndpoints.taskStop(id));
    await load(refresh: true);
  }

  Future<void> enableTask(int id) async {
    await _dio.put(ApiEndpoints.taskEnable(id));
    await load(refresh: true);
  }

  Future<void> disableTask(int id) async {
    await _dio.put(ApiEndpoints.taskDisable(id));
    await load(refresh: true);
  }

  Future<void> deleteTask(int id) async {
    await _dio.delete(ApiEndpoints.taskById(id));
    await load(refresh: true);
  }

  Future<void> batchRun(List<int> ids) async {
    await _dio.post(
      ApiEndpoints.tasksBatchRun,
      // 面板批量任务接口使用 task_ids 字段，不能复用环境变量的 ids 字段。
      data: {'task_ids': ids},
    );
    await load(refresh: true);
  }

  Future<void> batchEnable(List<int> ids) async {
    await _dio.put(
      ApiEndpoints.tasksBatchEnable,
      // 面板批量任务接口使用 task_ids 字段，保证与 Web 端请求保持一致。
      data: {'task_ids': ids},
    );
    await load(refresh: true);
  }

  Future<void> batchDisable(List<int> ids) async {
    await _dio.put(
      ApiEndpoints.tasksBatchDisable,
      // 面板批量任务接口使用 task_ids 字段，避免后端提示“请求参数错误”。
      data: {'task_ids': ids},
    );
    await load(refresh: true);
  }

  Future<void> batchDelete(List<int> ids) async {
    await _dio.delete(
      ApiEndpoints.tasksBatchDelete,
      // DELETE 请求的 body 也需要传 task_ids，和 Web 端保持一致。
      data: {'task_ids': ids},
    );
    await load(refresh: true);
  }

  Future<void> saveTaskOrder(List<Task> tasks) async {
    // 后端当前没有独立的任务排序接口，但任务更新接口允许写入 sort_order。
    // 这里按当前拖拽后的列表顺序写入 10、20、30...，后续插入任务时仍有间隔。
    for (var index = 0; index < tasks.length; index++) {
      await _dio.put(
        ApiEndpoints.taskById(tasks[index].id),
        data: {'sort_order': (index + 1) * 10},
      );
    }
    await load(refresh: true);
  }

  void reorderLocalTasks(int oldIndex, int newIndex) {
    final items = List<Task>.from(state.tasks);
    if (newIndex > oldIndex) {
      newIndex--;
    }
    final item = items.removeAt(oldIndex);
    items.insert(newIndex, item);
    state = state.copyWith(tasks: items);
  }

  Future<TaskLog?> fetchLatestLog(int id) async {
    try {
      final response = await _dio.get(
        ApiEndpoints.taskLatestLog(id),
      );
      final data = extractData(response.data);
      if (data is Map) {
        return TaskLog.fromJson(Map<String, dynamic>.from(data));
      }
      return null;
    } on DioException catch (e) {
      // 这个分支在 validateStatus 收紧前是死代码：404 不抛异常，永远进不来，
      // 「任务没有日志」是靠 extractData 解析失败碰巧返回 null 蒙对的。
      // 收紧后 404 才真正走到这里，语义变成显式的。
      if (e.response?.statusCode == 404) {
        return null;
      }
      rethrow;
    }
  }

  Future<void> pinTask(int id) async {
    await _dio.put(ApiEndpoints.taskPin(id));
    await load(refresh: true);
  }

  Future<void> unpinTask(int id) async {
    await _dio.put(ApiEndpoints.taskUnpin(id));
    await load(refresh: true);
  }

  Future<void> copyTask(int id) async {
    await _dio.post(ApiEndpoints.taskCopy(id));
    await load(refresh: true);
  }

  Future<void> updateTaskLabels(int id, List<String> labels) async {
    await _dio.put(
      ApiEndpoints.taskById(id),
      data: {'labels': labels},
    );
  }

  Future<void> batchUpdateGroupLabel({
    required List<Task> tasks,
    required String? oldGroupName,
    required String? newGroupName,
  }) async {
    for (final task in tasks) {
      final currentLabels = task.labelList.toList();
      currentLabels.removeWhere((l) => Task.isGroupLabel(l));
      if (newGroupName != null && newGroupName.trim().isNotEmpty) {
        currentLabels.add(Task.toGroupLabel(newGroupName));
      }
      await updateTaskLabels(task.id, currentLabels);
    }
    await load(refresh: true);
  }
}

final taskProvider = StateNotifierProvider<TaskNotifier, TaskListState>((ref) {
  return TaskNotifier();
});
