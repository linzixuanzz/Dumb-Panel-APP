import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/models/task_log.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/utils/panel_enums.dart';
import '../../../shared/widgets/app_glass_circle_button.dart';
import '../../../shared/widgets/app_grouped_list.dart';
import '../../../shared/widgets/app_icon_tile.dart';
import '../../../shared/widgets/app_large_title_header.dart';
import '../../../shared/widgets/app_snack.dart';
import '../../../shared/widgets/app_state_views.dart';
import '../utils/log_error_line.dart';
import '../utils/log_trend.dart';

final logListProvider = StateNotifierProvider<LogListNotifier, LogListState>((
  ref,
) {
  return LogListNotifier();
});

class LogListState {
  final List<TaskLog> logs;
  final int total;
  final bool loading;
  final String keyword;
  final String taskIdFilter;
  final int? statusFilter;

  /// 加载失败原因。为 null 表示这次请求成功了 —— UI 必须靠它区分
  /// 「面板里真的一条日志都没有」和「压根没拿到数据」。
  final String? error;

  /// 顶部「今天的摘要 + 执行趋势」。null = 还没拿到或面板不给，页面上直接不画那两块。
  /// 只有底部「日志」标签页会加载它；单任务日志页（taskId 模式）一直是 null。
  final LogSummary? summary;

  const LogListState({
    this.logs = const [],
    this.total = 0,
    this.loading = false,
    this.keyword = '',
    this.taskIdFilter = '',
    this.statusFilter,
    this.error,
    this.summary,
  });

  LogListState copyWith({
    List<TaskLog>? logs,
    int? total,
    bool? loading,
    String? keyword,
    String? taskIdFilter,
    int? statusFilter,
    bool resetStatusFilter = false,
    String? error,
    LogSummary? summary,
  }) {
    return LogListState(
      logs: logs ?? this.logs,
      total: total ?? this.total,
      loading: loading ?? this.loading,
      keyword: keyword ?? this.keyword,
      taskIdFilter: taskIdFilter ?? this.taskIdFilter,
      statusFilter: resetStatusFilter
          ? null
          : statusFilter ?? this.statusFilter,
      // ⚠️ 这里**故意不写** `error ?? this.error`，与 TaskListState
      // （task_provider.dart:43）保持同一套语义：不显式传 error 的 copyWith
      // 一律清空错误，于是每次新请求自动抹掉上一次的失败提示。
      // 仓库里 AuthState 用哨兵保留旧值，是相反的语义；本 State 明确选前者。
      // 改成 `??` 会让错误提示一旦出现就再也消不掉。
      error: error,
      // 摘要和列表是两个独立请求，列表刷新时不能把摘要抹掉。
      summary: summary ?? this.summary,
    );
  }
}

class LogListNotifier extends StateNotifier<LogListState> {
  /// [dio] **仅供测试注入**，生产路径不传，仍然走 `DioClient` 单例。
  /// 单例的 baseUrl 会随切换面板被改写，所以这里不在构造时把它存下来。
  LogListNotifier({Dio? dio}) : _injectedDio = dio, super(const LogListState());

  final Dio? _injectedDio;
  int _page = 1;

  Dio get _dio => _injectedDio ?? DioClient.instance.dio;

  Map<String, dynamic> _currentQueryParams({
    required int page,
    int pageSize = 20,
  }) {
    final params = <String, dynamic>{'page': page, 'page_size': pageSize};
    if (state.keyword.isNotEmpty) {
      params['keyword'] = state.keyword;
    }
    if (state.taskIdFilter.isNotEmpty) {
      params['task_id'] = state.taskIdFilter;
    }
    if (state.statusFilter != null) {
      params['status'] = state.statusFilter;
    }
    return params;
  }

  Future<void> load({bool refresh = false}) async {
    if (refresh) _page = 1;
    state = state.copyWith(loading: true, error: null);
    try {
      final response = await _dio.get(
        ApiEndpoints.logs,
        queryParameters: _currentQueryParams(page: _page),
      );
      final paginated = extractPaginated(response.data);
      final items = paginated.items.map((e) => TaskLog.fromJson(e)).toList();
      state = state.copyWith(
        logs: refresh ? items : [...state.logs, ...items],
        total: paginated.total,
        loading: false,
      );
    } catch (e) {
      // 原来这里只写 copyWith(loading: false)，错误被完全吞掉，
      // 页面退化成「暂无日志」，用户分不清是没数据还是拿不到数据。
      state = state.copyWith(
        loading: false,
        error: extractListErrorMessage(e, '加载日志失败'),
      );
    }
  }

  /// 加载顶部摘要与趋势（`GET /api/system/dashboard`，与旧首页趋势图同一个数据源）。
  ///
  /// 只在进页面和下拉刷新时调用，**不跟 5 秒自动刷新**：dashboard 要按天逐日计数，
  /// 区间越长越贵（面板 #153）。失败一律吞掉 —— 摘要只是锦上添花，
  /// 不能因为它把整个日志页打成「加载失败」。
  Future<void> loadSummary() async {
    // 标题写的是「本月」，趋势就从 1 号画到今天；月初不足 7 天时补满 7 天，免得只有一两个点。
    final range = DateTime.now().day.clamp(7, 31);
    try {
      final response = await _dio.get(
        ApiEndpoints.dashboard,
        queryParameters: {'range': range},
      );
      final summary = LogSummary.fromDashboard(extractData(response.data));
      if (summary != null) {
        // copyWith 不传 error 会清空错误，这里要原样带上列表那边的错误。
        state = state.copyWith(summary: summary, error: state.error);
      }
    } catch (_) {
      // 吞掉：保留上一次的摘要（或继续不显示）。
    }
  }

  Future<void> loadMore() async {
    if (state.loading || state.logs.length >= state.total) return;
    _page++;
    await load();
  }

  void setKeyword(String keyword) {
    state = state.copyWith(keyword: keyword);
    load(refresh: true);
  }

  void setTaskIdFilter(String taskId) {
    state = state.copyWith(taskIdFilter: taskId);
    load(refresh: true);
  }

  void setStatusFilter(int? status) {
    state = state.copyWith(
      statusFilter: status,
      resetStatusFilter: status == null,
    );
    load(refresh: true);
  }

  Future<void> deleteLog(int id) async {
    await _dio.delete(ApiEndpoints.logById(id));
    await load(refresh: true);
  }

  /// 左滑删除成功后，从当前列表里摘掉这一条。
  ///
  /// 正常情况下 [deleteLog] 之后的刷新已经把它拿掉了，这里什么都不会变；
  /// 但刷新本身失败时列表还留着旧数据，被滑走的那一行若还在树上，
  /// Dismissible 会直接断言报错，所以要在本地补一刀。
  void removeLocally(int id) {
    if (!state.logs.any((log) => log.id == id)) {
      return;
    }
    state = state.copyWith(
      logs: state.logs.where((log) => log.id != id).toList(),
      total: state.total > 0 ? state.total - 1 : 0,
      error: state.error,
    );
  }

  Future<void> batchDelete(List<int> ids) async {
    await _dio.post(
      ApiEndpoints.logsBatchDelete,
      data: {'ids': ids},
    );
    await load(refresh: true);
  }

  Future<int> deleteAllMatching() async {
    // 后端日志列表单页最多 100 条，这里按当前筛选条件分页取出所有日志 ID 后批量删除。
    const pageSize = 100;
    final ids = <int>[];
    var page = 1;
    var total = 0;

    do {
      final response = await _dio.get(
        ApiEndpoints.logs,
        queryParameters: _currentQueryParams(page: page, pageSize: pageSize),
      );
      final paginated = extractPaginated(response.data);
      total = paginated.total;
      final pageIds = paginated.items
          .map((entry) => TaskLog.fromJson(entry).id)
          .where((id) => id > 0)
          .toList();
      if (pageIds.isEmpty) {
        break;
      }
      ids.addAll(pageIds);
      page++;
    } while (ids.length < total);

    if (ids.isEmpty) {
      await load(refresh: true);
      return 0;
    }

    await _dio.post(
      ApiEndpoints.logsBatchDelete,
      data: {'ids': ids},
    );
    await load(refresh: true);
    return ids.length;
  }

  Future<void> clean({int? days}) async {
    await _dio.delete(
      ApiEndpoints.logsClean,
      queryParameters: days == null ? null : {'days': days},
    );
    await load(refresh: true);
  }
}

class LogListPage extends ConsumerStatefulWidget {
  /// 传了 [taskId] 就是任务详情页「日志历史」进来的单任务日志列表（issue #20）：
  /// 路由那边会给它一份独立的 [logListProvider]，不影响底部「日志」标签页的筛选。
  final int? taskId;
  final String? taskName;

  const LogListPage({super.key, this.taskId, this.taskName});

  @override
  ConsumerState<LogListPage> createState() => _LogListPageState();
}

class _LogListPageState extends ConsumerState<LogListPage> {
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  Timer? _refreshTimer;
  Timer? _debounce;
  bool _selectionMode = false;

  /// APP 在后台（hidden / paused）：5 秒刷新停掉，回到前台再恢复。
  bool _inBackground = false;
  AppLifecycleListener? _lifecycle;
  final Set<int> _selectedIds = <int>{};

  /// 失败行的错误行缓存（日志 id → 错误行，null 表示取不到）。
  /// 已结束日志的正文不会再变，解压一次就够；5 秒自动刷新时不用重复解压。
  final Map<int, String?> _errorLineCache = <int, String?>{};

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onHide: () {
        _inBackground = true;
        _refreshTimer?.cancel();
        _refreshTimer = null;
      },
      onResume: () {
        // 只拉下通知栏这种 inactive → resumed 没进过后台，不用处理
        if (!_inBackground) return;
        _inBackground = false;
        final state = ref.read(logListProvider);
        // 进后台前有任务在跑：后台这段时间没刷新，先立刻补拉一次，再接着每 5 秒刷新
        if (state.logs.any((log) => log.isRunning)) {
          ref.read(logListProvider.notifier).load(refresh: true);
        }
        _syncAutoRefresh(state);
      },
    );
    Future.microtask(() {
      final taskId = widget.taskId;
      if (taskId != null) {
        // setTaskIdFilter 自己会带着筛选条件加载第一页
        ref.read(logListProvider.notifier).setTaskIdFilter('$taskId');
      } else {
        ref.read(logListProvider.notifier).load(refresh: true);
        // 摘要和趋势是全部任务的统计，只在「日志」标签页加载；单任务日志页不画。
        ref.read(logListProvider.notifier).loadSummary();
      }
    });
    _scrollController.addListener(() {
      if (_scrollController.position.pixels >=
          _scrollController.position.maxScrollExtent - 200) {
        ref.read(logListProvider.notifier).loadMore();
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _refreshTimer?.cancel();
    _lifecycle?.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _syncAutoRefresh(LogListState state) {
    final hasRunning = state.logs.any((log) => log.isRunning);
    // 在后台时不开定时器（后台途中有请求回来也会走到这里），回到前台由 onResume 恢复
    if (hasRunning && !_inBackground) {
      _refreshTimer ??= Timer.periodic(const Duration(seconds: 5), (_) {
        ref.read(logListProvider.notifier).load(refresh: true);
      });
    } else {
      _refreshTimer?.cancel();
      _refreshTimer = null;
    }
  }

  void _resetScroll() {
    if (_scrollController.hasClients && _scrollController.offset > 0) {
      _scrollController.jumpTo(0);
    }
  }

  void _showMessage(String message) => AppSnack.show(context, message);

  void _showSuccess(String message) => AppSnack.success(context, message);

  void _showError(String message) => AppSnack.error(context, message);

  String _extractError(Object error, String fallback) {
    return extractErrorMessage(error, fallback);
  }

  void _enterSelectionModeWith(int id) {
    setState(() {
      _selectionMode = true;
      _selectedIds
        ..clear()
        ..add(id);
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelection(int id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
        if (_selectedIds.isEmpty) _selectionMode = false;
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _toggleSelectAll(List<TaskLog> logs) {
    setState(() {
      if (_selectedIds.length == logs.length) {
        _selectedIds.clear();
      } else {
        _selectedIds
          ..clear()
          ..addAll(logs.map((l) => l.id));
      }
    });
  }

  Future<void> _batchDeleteSelected() async {
    if (_selectedIds.isEmpty) return;
    final count = _selectedIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('批量删除'),
        content: Text('确定要删除选中的 $count 条日志吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: context.palette.err,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref
          .read(logListProvider.notifier)
          .batchDelete(_selectedIds.toList());
      _exitSelectionMode();
      _showSuccess('已删除 $count 条日志');
    } catch (e) {
      _showError(_extractError(e, '批量删除失败'));
    }
  }

  Future<void> _showCleanDialog() async {
    final days = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('清理旧日志'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 3),
            child: const Text('清理 3 天前的日志'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 7),
            child: const Text('清理 7 天前的日志'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 30),
            child: const Text('清理 30 天前的日志'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 0),
            child: Text(
              '清理全部日志',
              style: TextStyle(color: context.palette.errInk),
            ),
          ),
        ],
      ),
    );
    if (days == null) return;

    if (days == 0) {
      if (!mounted) {
        return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('清理全部日志'),
          content: const Text('确定要清理当前筛选条件下的全部日志吗？此操作不可恢复。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(
                backgroundColor: context.palette.err,
              ),
              child: const Text('清理'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    try {
      if (days == 0) {
        // 后端 clean 接口会自动套用默认保留天数，不能表达“全部清空”。
        // 所以这里改为读取当前筛选条件下全部日志 ID，再走批量删除接口。
        final count = await ref
            .read(logListProvider.notifier)
            .deleteAllMatching();
        _exitSelectionMode();
        // 一条都没清到不算成功，按中性提示，避免弹一条绿的却什么都没发生。
        if (count == 0) {
          _showMessage('暂无可清理日志');
        } else {
          _showSuccess('已清理 $count 条日志');
        }
        return;
      }

      await ref.read(logListProvider.notifier).clean(days: days);
      _exitSelectionMode();
      _showSuccess('已清理 $days 天前的日志');
    } catch (e) {
      _showError(_extractError(e, '清理失败'));
    }
  }

  /// 删除单条日志（左滑触发）。返回 true 表示真的删掉了，左滑的那一行据此决定是否弹回。
  Future<bool> _handleDelete(TaskLog log) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('删除日志'),
        content: Text('确定要删除日志 #${log.id} 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            style: FilledButton.styleFrom(
              backgroundColor: context.palette.err,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return false;
    }
    try {
      await ref.read(logListProvider.notifier).deleteLog(log.id);
      _showSuccess('日志已删除');
      return true;
    } catch (error) {
      _showError(_extractError(error, '删除失败'));
      return false;
    }
  }


  @override
  Widget build(BuildContext context) {
    ref.listen<LogListState>(logListProvider, (_, next) {
      _syncAutoRefresh(next);
    });
    final state = ref.watch(logListProvider);
    final palette = context.palette;
    final isTaskMode = widget.taskId != null;
    // 删除单条 / 批量删除 / 清理在面板侧都要 operator（server/handler/log.go 的 RegisterRoutes），
    // viewer 不给入口，免得左滑、确认之后才吃一个 403。与日志详情页「编辑对应脚本」同一个判断。
    final canDelete = ref.watch(authProvider).user?.isOperator ?? false;
    // 底部留白要在滚动视图外面读：它等于悬浮底栏实际盖住的高度 + 16。
    final bottomPadding = AppSpacing.listBottomOf(context);
    final summary = state.summary;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          color: palette.accent,
          onRefresh: () async {
            final notifier = ref.read(logListProvider.notifier);
            await Future.wait([
              notifier.load(refresh: true),
              if (!isTaskMode) notifier.loadSummary(),
            ]);
          },
          // 头部、筛选方块、趋势图和日志列表放进同一个滚动视图，一起滚走，
          // 小屏上不会被顶部固定区域吃掉半屏。
          child: CustomScrollView(
            controller: _scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(child: _buildHeader(state, canDelete)),
              SliverToBoxAdapter(child: _buildSearchField()),
              SliverToBoxAdapter(child: _buildFilterCard(state)),
              // 趋势是全部任务的统计，只在「日志」标签页画；单任务日志页不画。
              if (!isTaskMode && summary != null && summary.days.isNotEmpty)
                SliverToBoxAdapter(child: _buildTrendCard(summary)),
              ..._buildListSlivers(state, canDelete),
              SliverToBoxAdapter(child: SizedBox(height: bottomPadding)),
            ],
          ),
        ),
      ),
    );
  }

  /// 顶部大标题：标签页写月份 + 一句话总结；单任务日志页是返回键 + 任务名；多选时换成已选条数。
  Widget _buildHeader(LogListState state, bool canDelete) {
    if (_selectionMode) {
      final allSelected = _selectedIds.length == state.logs.length;
      return AppLargeTitleHeader(
        title: '已选 ${_selectedIds.length} 条',
        actions: [
          AppGlassCircleButton(
            icon: allSelected ? Icons.deselect : Icons.select_all,
            tooltip: allSelected ? '取消全选' : '全选',
            onTap: () => _toggleSelectAll(state.logs),
          ),
          AppGlassCircleButton(
            icon: Icons.delete_outline_rounded,
            tooltip: '批量删除',
            onTap: _batchDeleteSelected,
          ),
          AppGlassCircleButton(
            icon: Icons.close_rounded,
            tooltip: '取消',
            onTap: _exitSelectionMode,
          ),
        ],
      );
    }
    if (widget.taskId != null) {
      // 单任务日志页是压栈打开的，要有返回键；标签页没有
      return AppLargeTitleHeader(
        leading: AppGlassCircleButton(
          icon: Icons.arrow_back_ios_new_rounded,
          tooltip: '返回',
          onTap: () => Navigator.of(context).maybePop(),
        ),
        title: '${widget.taskName ?? '任务 #${widget.taskId}'} 的日志',
        subtitle: state.total > 0 ? '共 ${state.total} 条' : null,
      );
    }
    return AppLargeTitleHeader(
      title: '${DateTime.now().month} 月',
      // 摘要还没回来或面板不给时，退回页面名，标题下不留空。
      subtitle: state.summary?.sentence ?? '运行日志',
      actions: [
        // 「清理日志」按天数清的是全部任务的日志，单任务页里不给，免得误会
        if (canDelete)
          AppGlassCircleButton(
            icon: Icons.cleaning_services_outlined,
            tooltip: '清理日志',
            onTap: _showCleanDialog,
          ),
      ],
    );
  }

  Widget _buildSearchField() {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      // 灰色填充、无描边由全局 inputDecorationTheme 提供，这里只放图标和提示。
      child: TextField(
        controller: _searchController,
        decoration: InputDecoration(
          hintText: '搜索任务名称',
          prefixIcon: Icon(
            Icons.search_rounded,
            size: 20,
            color: palette.text2,
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
          isDense: true,
          suffixIcon: _searchController.text.isNotEmpty
              ? IconButton(
                  icon: Icon(
                    Icons.cancel_rounded,
                    size: 18,
                    color: palette.text3,
                  ),
                  tooltip: '清空',
                  onPressed: () {
                    _searchController.clear();
                    setState(() {});
                    ref.read(logListProvider.notifier).setKeyword('');
                  },
                )
              : null,
        ),
        style: const TextStyle(fontSize: 15),
        onChanged: (value) {
          setState(() {});
          _debounce?.cancel();
          _debounce = Timer(const Duration(milliseconds: 300), () {
            _resetScroll();
            ref.read(logListProvider.notifier).setKeyword(value);
          });
        },
      ),
    );
  }

  /// 四色筛选方块：成功 / 失败 / 运行中 / 已终止。
  ///
  /// 点一下按这个状态筛选，再点一下同一个取消（回到全部），接的还是原来的 status 参数。
  /// 面板 v3 起日志状态是四个（server/model/task_log.go:7-12），「已终止」是手动停止 /
  /// 定时停止留下的独立状态，不混进失败。
  /// 方块下的数字是**今天**的次数（来自摘要）；单任务页、老面板拿不到摘要时不显示数字。
  Widget _buildFilterCard(LogListState state) {
    final palette = context.palette;
    final summary = state.summary;
    final items = <(int, String, IconData, Color, int?)>[
      (
        kLogStatusSuccess,
        '成功',
        Icons.check_rounded,
        palette.ok,
        summary?.success,
      ),
      (
        kLogStatusFailed,
        '失败',
        Icons.close_rounded,
        palette.err,
        summary?.failed,
      ),
      (
        kLogStatusRunning,
        '运行中',
        Icons.autorenew_rounded,
        palette.accent,
        summary?.running,
      ),
      (
        kLogStatusAborted,
        '已终止',
        Icons.stop_rounded,
        palette.warn,
        summary?.aborted,
      ),
    ];
    return Container(
      margin: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 14),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (status, label, icon, color, count) in items)
            Expanded(
              child: _StatusFilterTile(
                label: label,
                icon: icon,
                color: color,
                count: count,
                selected: state.statusFilter == status,
                onTap: () {
                  _resetScroll();
                  ref
                      .read(logListProvider.notifier)
                      .setStatusFilter(
                        state.statusFilter == status ? null : status,
                      );
                },
              ),
            ),
        ],
      ),
    );
  }

  /// 执行趋势细线图。数据与旧首页趋势图同源（dashboard 的 daily_stats），画的是每天的总次数。
  ///
  /// 今天还没过完：今天这一点按「已过时长占全天的比例」折算成全天预估（[projectTodayTotal]），
  /// 并且昨天到今天这一段画成虚线、今天的点画成空心圆，表示「这是估的」。
  /// 不折算的话每天最后一个点都会断崖式下跌，像是出了故障。
  Widget _buildTrendCard(LogSummary summary) {
    final palette = context.palette;
    final days = summary.days;
    final last = days.length - 1;
    final todayActual = days[last].total;
    final projected = projectTodayTotal(todayActual, DateTime.now());
    final average = averageDailyTotal(days, projected);

    // 实线：已经过完的那些天；虚线：昨天 → 今天（预估）。
    final solidSpots = [
      for (var i = 0; i < last; i++)
        FlSpot(i.toDouble(), days[i].total.toDouble()),
    ];
    final dashedSpots = [
      if (last > 0)
        FlSpot((last - 1).toDouble(), days[last - 1].total.toDouble()),
      FlSpot(last.toDouble(), projected),
    ];
    final dashedBarIndex = solidSpots.isEmpty ? 0 : 1;

    // 纵轴固定 3 格，格距取整，网格线和刻度都落在整数上。
    var maxValue = projected;
    for (final day in days) {
      maxValue = math.max(maxValue, day.total.toDouble());
    }
    final interval = math.max(1, (maxValue / 3).ceil()).toDouble();
    final axisStyle = AppText.tabular(
      AppText.caption.copyWith(fontSize: 10.5, color: palette.text2),
    );

    LineChartBarData bar(List<FlSpot> spots, {bool dashed = false}) {
      return LineChartBarData(
        spots: spots,
        // 不做样条平滑：每个点是「某天执行了几次」的整数计数，两天之间没有中间值。
        isCurved: false,
        color: palette.warn,
        barWidth: 2.5,
        isStrokeCapRound: true,
        dashArray: dashed ? const [5, 4] : null,
        // 只在今天（预估）那一点画个空心圆，其余点不画。
        dotData: FlDotData(
          show: dashed,
          checkToShowDot: (spot, _) => spot.x == last,
          getDotPainter: (spot, percent, barData, index) => FlDotCirclePainter(
            radius: 4.5,
            color: palette.card,
            strokeWidth: 2.5,
            strokeColor: palette.warn,
          ),
        ),
        belowBarData: BarAreaData(show: false),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '执行趋势',
                      style: AppText.cardTitle.copyWith(
                        fontSize: 19,
                        color: palette.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '近 ${days.length} 天',
                      style: AppText.caption.copyWith(color: palette.text2),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '每日平均',
                    style: AppText.caption.copyWith(color: palette.text2),
                  ),
                  Text(
                    '${average.round()} 次',
                    style: AppText.tabular(
                      AppText.cardTitle.copyWith(color: palette.warnInk),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 150,
            child: LineChart(
              duration: AppMotion.of(context, AppMotion.normal),
              LineChartData(
                minX: 0,
                // 只有一天的数据时横轴宽度不能是 0
                maxX: math.max(last, 1).toDouble(),
                minY: 0,
                maxY: interval * 3,
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: interval,
                  // 网格线用发丝线，只做参照，不抢折线的视线
                  getDrawingHorizontalLine: (_) =>
                      FlLine(color: palette.separator, strokeWidth: 0.5),
                ),
                titlesData: FlTitlesData(
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 30,
                      interval: interval,
                      getTitlesWidget: (value, meta) =>
                          Text(value.toInt().toString(), style: axisStyle),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 24,
                      interval: (days.length / 5).ceilToDouble().clamp(
                        1,
                        double.infinity,
                      ),
                      getTitlesWidget: (value, meta) {
                        final index = value.toInt();
                        if (index < 0 || index > last) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            index == last ? '今天' : days[index].dayLabel,
                            style: axisStyle,
                          ),
                        );
                      },
                    ),
                  ),
                  topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                ),
                borderData: FlBorderData(show: false),
                lineTouchData: LineTouchData(
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipColor: (_) => palette.card2,
                    getTooltipItems: (touched) {
                      final style = AppText.tabular(
                        TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: palette.text,
                        ),
                      );
                      return touched.map((spot) {
                        final index = spot.x.toInt();
                        // 昨天那一点实线、虚线各有一个，只让实线那条出提示，免得重复
                        if (spot.barIndex == dashedBarIndex && index != last) {
                          return null;
                        }
                        if (index == last) {
                          return LineTooltipItem(
                            '今天已执行 $todayActual 次\n预估全天 ${projected.round()} 次',
                            style,
                          );
                        }
                        return LineTooltipItem(
                          '${days[index].date}  ${days[index].total} 次',
                          style,
                        );
                      }).toList();
                    },
                  ),
                ),
                lineBarsData: [
                  if (solidSpots.isNotEmpty) bar(solidSpots),
                  bar(dashedSpots, dashed: true),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '虚线是今天按已过时长折算的全天预估。按住图表查看每天的次数。',
            style: AppText.caption.copyWith(
              fontSize: 12.5,
              color: palette.text2,
            ),
          ),
        ],
      ),
    );
  }

  /// 日志列表：按天分组的圆角卡片（iOS 分组列表样式），组头是「今天 / 昨天 / 11月23日」。
  List<Widget> _buildListSlivers(LogListState state, bool canDelete) {
    if (state.loading && state.logs.isEmpty) {
      return const [SliverToBoxAdapter(child: AppLoadingView(topPadding: 48))];
    }
    // 拿不到数据和真的没有数据是两回事，必须先判 error。
    if (state.error != null && state.logs.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: AppErrorView(
            title: '日志加载失败',
            message: state.error!,
            padding: const EdgeInsets.fromLTRB(32, 48, 32, 0),
            onRetry: () =>
                ref.read(logListProvider.notifier).load(refresh: true),
          ),
        ),
      ];
    }
    if (state.logs.isEmpty) {
      return const [
        SliverToBoxAdapter(
          child: AppEmptyView(
            icon: Icons.article_outlined,
            message: '暂无日志',
            topPadding: 48,
          ),
        ),
      ];
    }

    // 摊平成「组头 + 行」的一维列表，懒加载时按下标取。
    // 每一行记下自己是不是本组第一行 / 最后一行，用来决定圆角和分隔线。
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    DateTime dayOf(TaskLog log) {
      final local = log.startedAt.toLocal();
      return DateTime(local.year, local.month, local.day);
    }

    final entries = <Object>[];
    final logs = state.logs;
    for (var i = 0; i < logs.length; i++) {
      final day = dayOf(logs[i]);
      final isFirst = i == 0 || dayOf(logs[i - 1]) != day;
      final isLast = i == logs.length - 1 || dayOf(logs[i + 1]) != day;
      if (isFirst) {
        final diff = today.difference(day).inDays;
        entries.add(
          diff == 0
              ? '今天'
              : diff == 1
              ? '昨天'
              : day.year == today.year
              ? '${day.month}月${day.day}日'
              : '${day.year}年${day.month}月${day.day}日',
        );
      }
      entries.add((log: logs[i], first: isFirst, last: isLast));
    }

    final palette = context.palette;
    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            final entry = entries[index];
            if (entry is String) {
              return Padding(
                padding: EdgeInsets.fromLTRB(20, index == 0 ? 4 : 18, 20, 8),
                child: Text(
                  entry,
                  style: AppText.caption.copyWith(
                    fontWeight: FontWeight.w600,
                    color: palette.text2,
                  ),
                ),
              );
            }
            final slot = entry as ({TaskLog log, bool first, bool last});
            return _buildLogRow(slot.log, slot.first, slot.last, canDelete);
          }, childCount: entries.length),
        ),
      ),
    ];
  }

  Widget _buildLogRow(TaskLog log, bool first, bool last, bool canDelete) {
    final palette = context.palette;
    final selected = _selectedIds.contains(log.id);

    // 状态色：成功=绿、失败=红、运行中=蓝、已终止=橙、未知=灰。
    // 「已终止」单独一档：面板 v3 的 status=3 以前会亮成运行中的蓝，用户会以为任务卡住了。
    final (IconData icon, Color color) = switch (log.statusTone) {
      PanelStatusTone.success => (Icons.check_rounded, palette.ok),
      PanelStatusTone.danger => (Icons.close_rounded, palette.err),
      PanelStatusTone.running => (Icons.autorenew_rounded, palette.accent),
      PanelStatusTone.warning => (Icons.stop_rounded, palette.warn),
      PanelStatusTone.neutral => (Icons.question_mark_rounded, palette.text3),
    };

    // 失败的行直接把错误行摆出来，不用点进去翻。正文来自列表接口自带的 content，不额外发请求。
    final errorLine = log.isFailed
        ? _errorLineCache.putIfAbsent(
            log.id,
            () => pickLogErrorLine(log.content),
          )
        : null;

    void open() {
      if (_selectionMode) {
        _toggleSelection(log.id);
      } else {
        context.push('/logs/${log.id}/stream');
      }
    }

    final time = DateFormat('HH:mm:ss').format(log.startedAt.toLocal());
    Widget row = ColoredBox(
      // 多选选中的行铺一层浅蓝；叠在卡片白上，不能直接用半透明色（会透出页面灰底）。
      color: selected
          ? Color.alphaBlend(palette.tint(palette.accent), palette.card)
          : palette.card,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppGroupedRow(
            leading: _selectionMode
                ? SizedBox(
                    width: 36,
                    height: 36,
                    child: Icon(
                      selected
                          ? Icons.check_circle_rounded
                          : Icons.circle_outlined,
                      size: 26,
                      color: selected ? palette.accent : palette.text3,
                    ),
                  )
                : AppIconTile(icon: icon, color: color),
            title: log.taskName ?? '任务 #${log.taskId}',
            subtitle: '$time · ${log.isRunning ? '运行中' : log.durationText}',
            showChevron: !_selectionMode,
            showSeparator: !first,
            onTap: open,
            // 长按进多选，多选只服务批量删除，没有删除权限就不给
            onLongPress: canDelete && !_selectionMode
                ? () => _enterSelectionModeWith(log.id)
                : null,
          ),
          if (errorLine != null)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: open,
              child: Container(
                // 左边与行标题对齐：行内边距 18 + 图标 36 + 间距 14
                margin: const EdgeInsets.fromLTRB(68, 0, 18, 12),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: palette.tint(palette.err),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Text(
                  errorLine,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12.5,
                    height: 1.35,
                    color: palette.errInk,
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    // 左滑删除：先弹确认，删成功才真的滑走，取消或失败就弹回原位。多选时不给滑。
    if (canDelete && !_selectionMode) {
      row = Dismissible(
        key: ValueKey('log-${log.id}'),
        direction: DismissDirection.endToStart,
        background: Container(
          color: palette.err,
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 24),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.delete_outline_rounded, color: palette.onStatus),
              const SizedBox(width: 6),
              Text(
                '删除',
                style: TextStyle(
                  color: palette.onStatus,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        confirmDismiss: (_) => _handleDelete(log),
        onDismissed: (_) =>
            ref.read(logListProvider.notifier).removeLocally(log.id),
        child: row,
      );
    }

    // 本组第一行圆上边、最后一行圆下边，连起来就是一张分组卡片。
    const radius = Radius.circular(AppRadius.card);
    return ClipRRect(
      borderRadius: BorderRadius.vertical(
        top: first ? radius : Radius.zero,
        bottom: last ? radius : Radius.zero,
      ),
      child: row,
    );
  }
}

/// 一个筛选方块：彩色图标方块 + 状态名 + 今天的次数。选中时方块变成实色。
class _StatusFilterTile extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final int? count;
  final bool selected;
  final VoidCallback onTap;

  const _StatusFilterTile({
    required this.label,
    required this.icon,
    required this.color,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.tile),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIconTile(icon: icon, color: color, size: 52, solid: selected),
              const SizedBox(height: 8),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(
                  fontWeight: FontWeight.w600,
                  color: palette.text,
                ),
              ),
              if (count != null)
                Text(
                  '$count 次',
                  maxLines: 1,
                  style: AppText.tabular(
                    AppText.caption.copyWith(
                      fontSize: 12,
                      color: palette.text2,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
