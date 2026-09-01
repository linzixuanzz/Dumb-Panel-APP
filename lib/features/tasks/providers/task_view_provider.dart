import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_endpoints.dart';
import '../../../core/network/dio_client.dart';
import '../../../shared/models/task_view.dart';
import '../../../shared/utils/api_utils.dart';

class TaskViewListState {
  final List<TaskView> views;
  final bool loading;
  final String? error;

  /// 当前面板**支不支持**任务视图。
  ///
  /// `/api/tasks/views` 是后加的路由：老面板会 404，viewer 以下的角色会 403。
  /// 这两种情况都不是「出错」，而是「这个面板/这个账号没有这个能力」——
  /// 必须静默降级成「没有视图 + 隐藏整个入口」，不能弹错误，
  /// 更不能让任务列表因为一个可选能力红掉。
  final bool supported;

  const TaskViewListState({
    this.views = const [],
    this.loading = false,
    this.error,
    this.supported = true,
  });

  /// 页面上真正会渲染的视图：`hidden` 的不显示。
  /// 顺序直接用服务端返回的顺序（已按 `sort_order ASC, id ASC` 排好），
  /// APP 不再排第二遍。
  List<TaskView> get visibleViews =>
      views.where((view) => !view.hidden).toList();

  TaskView? viewById(int? id) {
    if (id == null) {
      return null;
    }
    for (final view in views) {
      if (view.id == id) {
        return view;
      }
    }
    return null;
  }

  TaskViewListState copyWith({
    List<TaskView>? views,
    bool? loading,
    // ⚠️ 与全库其它 State 一致：error 是**裸赋值**，不传即清空。
    // 任何与列表无关的 copyWith 都必须显式回传 error: state.error。
    String? error,
    bool? supported,
  }) {
    return TaskViewListState(
      views: views ?? this.views,
      loading: loading ?? this.loading,
      error: error,
      supported: supported ?? this.supported,
    );
  }
}

class TaskViewNotifier extends StateNotifier<TaskViewListState> {
  /// [dio] **仅供测试注入**，生产路径不传，仍然走 `DioClient` 单例。
  /// 单例的 baseUrl 会随切换面板被改写，所以这里不在构造时把它存下来。
  TaskViewNotifier({Dio? dio})
    : _injectedDio = dio,
      super(const TaskViewListState());

  final Dio? _injectedDio;

  Dio get _dio => _injectedDio ?? DioClient.instance.dio;

  Future<void> load() async {
    state = state.copyWith(loading: true, error: null);
    try {
      final response = await _dio.get(ApiEndpoints.taskViews);
      final paginated = extractPaginated(response.data);
      final items = paginated.items.map((e) => TaskView.fromJson(e)).toList();
      state = state.copyWith(views: items, loading: false, supported: true);
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 404 || status == 403) {
        // 老面板没有这条路由（404）/ 当前角色不够（403）。
        // 这不是错误，是能力缺失：清空视图并把入口整体藏起来。
        state = state.copyWith(
          views: const [],
          loading: false,
          supported: false,
        );
        return;
      }
      state = state.copyWith(
        loading: false,
        error: extractListErrorMessage(e, '加载任务视图失败'),
      );
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: extractListErrorMessage(e, '加载任务视图失败'),
      );
    }
  }

  /// 新建视图。**不 try/catch**，异常抛给 UI 去出提示 ——
  /// 同名会被服务端拒（「同名任务视图已存在」），那句原文要能透到用户眼前。
  Future<void> create({
    required String name,
    required List<TaskViewFilter> filters,
    required List<TaskViewSortRule> sortRules,
  }) async {
    await _dio.post(
      ApiEndpoints.taskViews,
      data: {
        'name': name,
        'filters': encodeTaskViewFilters(filters),
        'sort_rules': encodeTaskViewSortRules(sortRules),
      },
    );
    await load();
  }

  /// 修改视图。
  ///
  /// ⚠️ 面板的 UpdateView 把 `name` / `filters` / `sort_rules` 的**空串**
  /// 当成「这个字段不改」（`server/handler/task_view.go:77-85`），
  /// 所以「把规则清空」必须传 `"[]"` 而不是 `""` —— [encodeTaskViewFilters]
  /// 对空列表返回的正是 `"[]"`，这里直接用它，不要顺手改成条件拼装。
  Future<void> update({
    required int id,
    required String name,
    required List<TaskViewFilter> filters,
    required List<TaskViewSortRule> sortRules,
  }) async {
    await _dio.put(
      ApiEndpoints.taskViewById(id),
      data: {
        'name': name,
        'filters': encodeTaskViewFilters(filters),
        'sort_rules': encodeTaskViewSortRules(sortRules),
      },
    );
    await load();
  }

  Future<void> delete(int id) async {
    await _dio.delete(ApiEndpoints.taskViewById(id));
    await load();
  }
}

final taskViewProvider =
    StateNotifierProvider<TaskViewNotifier, TaskViewListState>((ref) {
      return TaskViewNotifier();
    });
