import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/task.dart';
import '../../../shared/models/task_log.dart';
import '../../../shared/models/task_view.dart';
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

  /// 当前生效的任务视图规则。空列表 = 没选视图。
  ///
  /// 这两组规则**不在客户端求值**：它们被序列化成 JSON 字符串塞进
  /// `GET /api/tasks` 的 query，由服务端筛选与排序。
  final List<TaskViewFilter> filters;
  final List<TaskViewSortRule> sortRules;

  /// 当前选中的视图 id，只用于 UI 高亮与本地持久化。
  final int? selectedViewId;

  const TaskListState({
    this.tasks = const [],
    this.total = 0,
    this.loading = false,
    this.error,
    this.keyword = '',
    this.statusFilter,
    this.labelFilter,
    this.filters = const [],
    this.sortRules = const [],
    this.selectedViewId,
  });

  /// 此刻不能拖拽排序的原因，能拖返回 null。条件与文案对齐网页端 tasks/index.vue 的
  /// dragSortDisabledReason（只取 APP 也有的两条）：
  /// - 视图带排序规则：展示顺序由规则决定，拖出来的位置刷新后又会被规则排回去；
  /// - 有任务在运行：面板默认排序把运行中的任务临时提到本区最前，展示顺序和 list_order 对不上，
  ///   而 [TaskNotifier.moveTask] 拿「看得见的邻居」当锚，拖了会白拖，甚至落到别的位置。
  ///   「已启用 / 已禁用」筛选是服务端按 status 精确匹配，运行中的会被筛掉，所以文案给的是这条出路。
  String? get dragSortDisabledReason {
    if (sortRules.isNotEmpty) {
      return '当前视图自带排序规则，切到不带排序的视图再拖拽';
    }
    if (tasks.any((task) => task.isRunning)) {
      return '运行中的任务被临时排到了最前，此时拖拽的落点会算错；等它跑完再拖，或先切到「已启用」/「已禁用」筛选再排';
    }
    return null;
  }

  TaskListState copyWith({
    List<Task>? tasks,
    int? total,
    bool? loading,
    String? error,
    String? keyword,
    Object? statusFilter = _unset,
    Object? labelFilter = _unset,
    List<TaskViewFilter>? filters,
    List<TaskViewSortRule>? sortRules,
    Object? selectedViewId = _unset,
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
      filters: filters ?? this.filters,
      sortRules: sortRules ?? this.sortRules,
      selectedViewId: identical(selectedViewId, _unset)
          ? this.selectedViewId
          : selectedViewId as int?,
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
  /// 分组下拉项、全选都建立在「全部任务都在内存里」这个前提上：
  /// 改成增量分页会让分组项残缺、全选变成「只全选已加载的」。
  /// （拖拽排序已改走 `PUT /tasks/sort`，兄弟序列由面板按整桶去取，不再依赖这里是否全量；
  /// 以前逐条写 sort_order 时，分页会把没加载到的任务写坏。）
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
      // 视图规则原样交给服务端（`server/handler/task_query.go:42-43`）。
      // 只在非空时才带上：面板对空 filters 走的是 SQL 分页快路径，
      // 带一个 `[]` 会把它推进「全表进内存再过滤」的慢路径。
      if (state.filters.isNotEmpty) {
        queryParams['filters'] = encodeTaskViewFilters(state.filters);
      }
      if (state.sortRules.isNotEmpty) {
        queryParams['sort_rules'] = encodeTaskViewSortRules(state.sortRules);
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

  /// 只写分组筛选，**不发请求**。冷启动恢复时用，理由同 [setViewSelection]。
  ///
  /// 刻意与 [setLabelFilter] 分成两个方法：用户点选分组时仍然要立刻刷新，
  /// 那个行为不能动。
  void setLabelSelection(String? label) {
    // error 是「不传即清空」，这里只动分组，与列表本身无关，必须原样回传。
    state = state.copyWith(labelFilter: label, error: state.error);
  }

  /// 只写视图选择，**不发请求**。冷启动恢复时用：紧接着还有一次统一的
  /// `load()`，这里再各自拉一遍就是白跑一次全量取数。
  void setViewSelection(TaskView? view) {
    state = state.copyWith(
      filters: view?.filters ?? const [],
      sortRules: view?.sortRules ?? const [],
      selectedViewId: view?.id,
      // 同上：只动视图选择时不能顺手把列表的错误信息抹掉 ——
      // 视图列表回来得比任务列表晚，那时抹掉就成了「空列表 + 没有任何提示」。
      error: state.error,
    );
  }

  /// 切换任务视图。传 null 表示回到「全部任务」（清空规则）。
  void applyView(TaskView? view) {
    setViewSelection(view);
    load(refresh: true);
  }

  /// 一次性清掉全部筛选维度（状态 / 分组 / 视图），**只发一次请求**。
  /// 逐个调 setStatusFilter / setLabelFilter / applyView 会连打三次全量取数。
  void clearFilters() {
    state = state.copyWith(
      statusFilter: null,
      labelFilter: null,
      filters: const [],
      sortRules: const [],
      selectedViewId: null,
    );
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

  /// 批量改通知开关（面板 v3.3.3 / issue #149 的 `PUT /tasks/batch/notify`）。
  ///
  /// 只带要改的开关，`null` = 不修改：面板那边是指针字段，没传的列原样保留，传 false 也会写入。
  /// 不带面板的 `all` 字段 —— APP 列表是 all=1 全量拉取，「全选」本来就是当前筛选下的全部任务。
  Future<void> batchSetNotify(
    List<int> ids, {
    bool? onFailure,
    bool? onSuccess,
  }) async {
    try {
      await _dio.put(
        ApiEndpoints.tasksBatchNotify,
        data: {
          'task_ids': ids,
          // `?` 是空感知元素：值为 null（不修改）时整个键都不放进 body。
          'notify_on_failure': ?onFailure,
          'notify_on_success': ?onSuccess,
        },
      );
    } on DioException catch (e) {
      if (_isMissingPanelRoute(e)) {
        throw const PanelUpgradeRequiredException(
          '当前面板版本不支持，请升级到 v3.3.3 或更高',
        );
      }
      rethrow;
    }
    await load(refresh: true);
  }

  /// 拖拽排序：松手一次只发一次 `PUT /tasks/sort`（面板 v3.2.1 起），面板只写 list_order。
  ///
  /// 以前是逐条 `PUT /tasks/:id {sort_order}` 把整张列表重写一遍，但 sort_order 在面板里是
  /// 「开机任务串行执行顺序」的契约（面板 server/model/task.go 的 ListOrder 注释）：
  /// APP 上拖一次就悄悄改写了开机编排；而默认排序里 list_order 排在 sort_order 前面，
  /// 网页端拖过的桶里 APP 的拖拽又等于白拖。
  Future<void> moveTask(int oldIndex, int newIndex) async {
    final items = List<Task>.from(state.tasks);
    // ReorderableListView 给的 newIndex 是「移除前」的下标，往下拖要先减一。
    if (newIndex > oldIndex) {
      newIndex--;
    }
    if (newIndex == oldIndex) {
      return;
    }
    final source = items.removeAt(oldIndex);
    items.insert(newIndex, source);
    // 先在本地挪到位（乐观更新），否则松手瞬间列表会先弹回原位、等请求回来再跳一次。
    state = state.copyWith(tasks: items);

    // 桶 = 置顶与否 + 状态分区，口径同面板 taskSortGroup（server/handler/task_query.go）：
    // 启用 / 排队中 / 运行中一区，禁用一区，其余一区。面板只许桶内互拖，跨桶回 400。
    int statusGroup(Task task) {
      if (task.isDisabled) return 1;
      if (task.isEnabled || task.isQueued || task.isRunning) return 0;
      return 2;
    }

    bool sameBucket(Task other) =>
        other.isPinned == source.isPinned &&
        statusGroup(other) == statusGroup(source);

    // 落点锚取「看得见的邻居」，口径同网页端 tasks/index.vue 的 onEnd：
    // 后一条同桶 → 插到它前面；否则前一条同桶 → 插到它后面。
    // 贴着桶边界松手（比如拖到置顶区最后一条）时后一条已是别的桶，只认后一条会把没跨区的拖动也发成跨区。
    // 两侧都不同桶就是真跨区了，照样发出去，由面板回 400 说明该用哪个按钮。
    final next = newIndex + 1 < items.length ? items[newIndex + 1] : null;
    final prev = newIndex > 0 ? items[newIndex - 1] : null;
    final useNext =
        next != null &&
        (sameBucket(next) || prev == null || !sameBucket(prev));
    try {
      await _dio.put(
        ApiEndpoints.tasksSort,
        data: {
          'source_id': source.id,
          // useNext 为假时 prev 一定存在：能走到这里说明列表至少两条、确实挪了位，
          // 后一条为空（拖到最底）时前一条必有；后一条在时，只有前一条同桶才会选它。
          'target_id': useNext ? next.id : prev!.id,
          'position': useNext ? 'before' : 'after',
        },
      );
    } on DioException catch (e) {
      // ≤ v3.2.0 没有 /tasks/sort，但有 PUT /tasks/:id：「sort」被当成任务 id 解析成 0，
      // 回的是 404 {"error":"任务不存在"}，不是 NoRoute 的那两种形态。新面板的 Sort 自己只会说
      // 「源任务不存在 / 目标任务不存在」，所以这句原话可以当成老面板的特征。
      final data = e.response?.data;
      final oldPanelUpdateRoute =
          e.response?.statusCode == 404 &&
          data is Map &&
          data['error'] == '任务不存在';
      if (oldPanelUpdateRoute || _isMissingPanelRoute(e)) {
        throw const PanelUpgradeRequiredException(
          '当前面板版本不支持，请升级到 v3.2.1 或更高',
        );
      }
      rethrow;
    } finally {
      // 成功要拿面板整桶重编号后的顺序；失败（跨桶 400、任务已被删、老面板）更要拉一次，
      // 把上面乐观挪过的位置按服务端顺序弹回去。
      await load(refresh: true);
    }
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

/// 面板版本太老、没有某条接口时抛出。[message] 已经是给用户看的中文，
/// 页面照常走 `extractErrorMessage`（它会读到这里的 message），不用另开分支。
class PanelUpgradeRequiredException implements Exception {
  const PanelUpgradeRequiredException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 「这台面板没有这条路由」的 404。靠形状判断、不看版本号（spec/frontend/panel-contract.md）：
/// - Docker 部署（nginx 反代）：gin 默认的纯文本 `404 page not found`，没有面板格式的错误 JSON；
/// - 二进制部署（面板自己托管前端）：NoRoute 回 `{"error":"route not found"}`
///   （面板 server/static_frontend.go 的 handleNoRoute）。
/// 面板业务上的 404 都带自己的中文 error（如「没有找到要修改的任务」），不会被当成缺路由。
bool _isMissingPanelRoute(DioException e) {
  if (e.response?.statusCode != 404) {
    return false;
  }
  final data = e.response?.data;
  final error = data is Map ? data['error'] : null;
  return error == null || error == 'route not found';
}
