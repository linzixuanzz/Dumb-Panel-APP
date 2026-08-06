import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/models/task_log.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/utils/time_utils.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/app_snack.dart';
import '../../../shared/widgets/app_state_views.dart';

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

  const LogListState({
    this.logs = const [],
    this.total = 0,
    this.loading = false,
    this.keyword = '',
    this.taskIdFilter = '',
    this.statusFilter,
    this.error,
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
  const LogListPage({super.key});

  @override
  ConsumerState<LogListPage> createState() => _LogListPageState();
}

class _LogListPageState extends ConsumerState<LogListPage> {
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  Timer? _refreshTimer;
  Timer? _debounce;
  bool _selectionMode = false;
  final Set<int> _selectedIds = <int>{};

  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => ref.read(logListProvider.notifier).load(refresh: true),
    );
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
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _syncAutoRefresh(LogListState state) {
    final hasRunning = state.logs.any((log) => log.isRunning);
    if (hasRunning) {
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
            style: FilledButton.styleFrom(backgroundColor: AppColors.red500),
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
            child: const Text('清理全部日志', style: TextStyle(color: Colors.red)),
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
              style: FilledButton.styleFrom(backgroundColor: AppColors.red500),
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

  Future<void> _handleDelete(TaskLog log) async {
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
            style: FilledButton.styleFrom(backgroundColor: AppColors.red500),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    try {
      await ref.read(logListProvider.notifier).deleteLog(log.id);
      _showSuccess('日志已删除');
    } catch (error) {
      _showError(_extractError(error, '删除失败'));
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<LogListState>(logListProvider, (_, next) {
      _syncAutoRefresh(next);
    });
    final state = ref.watch(logListProvider);
    final isLight = Theme.of(context).brightness == Brightness.light;

    return Scaffold(
      body: Padding(
        padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 12),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Expanded(
                    child: _selectionMode
                        ? Text(
                            '已选 ${_selectedIds.length} 条',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          )
                        : const Text(
                            '运行日志',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                  if (_selectionMode) ...[
                    IconButton(
                      icon: Icon(
                        _selectedIds.length == state.logs.length
                            ? Icons.deselect
                            : Icons.select_all,
                        size: 20,
                      ),
                      onPressed: () => _toggleSelectAll(state.logs),
                      tooltip: _selectedIds.length == state.logs.length
                          ? '取消全选'
                          : '全选',
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.delete_outline,
                        size: 20,
                        color: AppColors.red500,
                      ),
                      onPressed: _batchDeleteSelected,
                      tooltip: '批量删除',
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: _exitSelectionMode,
                      tooltip: '取消',
                    ),
                  ] else ...[
                    IconButton(
                      icon: const Icon(
                        Icons.cleaning_services_outlined,
                        size: 20,
                      ),
                      onPressed: _showCleanDialog,
                      tooltip: '清理日志',
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: '搜索任务名称...',
                  prefixIcon: const Icon(
                    Icons.search,
                    size: 18,
                    color: AppColors.slate400,
                  ),
                  filled: true,
                  fillColor: isLight ? Colors.white : AppColors.slate900,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: isLight ? AppColors.slate200 : AppColors.slate800,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: isLight ? AppColors.slate200 : AppColors.slate800,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(
                      color: AppColors.primary,
                      width: 1.5,
                    ),
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  isDense: true,
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(
                            Icons.clear,
                            size: 16,
                            color: AppColors.slate400,
                          ),
                          onPressed: () {
                            _searchController.clear();
                            setState(() {});
                            ref.read(logListProvider.notifier).setKeyword('');
                          },
                        )
                      : null,
                ),
                style: const TextStyle(fontSize: 14),
                onChanged: (value) {
                  setState(() {});
                  _debounce?.cancel();
                  _debounce = Timer(const Duration(milliseconds: 300), () {
                    _resetScroll();
                    ref.read(logListProvider.notifier).setKeyword(value);
                  });
                },
              ),
            ),
            const SizedBox(height: 12),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _StatusFilterChip(
                      label: '全部',
                      selected: state.statusFilter == null,
                      onTap: () {
                        _resetScroll();
                        ref
                            .read(logListProvider.notifier)
                            .setStatusFilter(null);
                      },
                    ),
                    _StatusFilterChip(
                      label: '成功',
                      selected: state.statusFilter == 0,
                      onTap: () {
                        _resetScroll();
                        ref.read(logListProvider.notifier).setStatusFilter(0);
                      },
                      selectedColor: AppColors.success,
                    ),
                    _StatusFilterChip(
                      label: '失败',
                      selected: state.statusFilter == 1,
                      onTap: () {
                        _resetScroll();
                        ref.read(logListProvider.notifier).setStatusFilter(1);
                      },
                      selectedColor: AppColors.danger,
                    ),
                    _StatusFilterChip(
                      label: '运行中',
                      selected: state.statusFilter == 2,
                      onTap: () {
                        _resetScroll();
                        ref.read(logListProvider.notifier).setStatusFilter(2);
                      },
                      selectedColor: AppColors.info,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            Expanded(
              child: RefreshIndicator(
                color: AppColors.primary,
                onRefresh: () =>
                    ref.read(logListProvider.notifier).load(refresh: true),
                child: state.loading && state.logs.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: const [AppLoadingView()],
                      )
                    // 拿不到数据和真的没有数据是两回事，必须先判 error。
                    : state.error != null && state.logs.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          AppErrorView(
                            title: '日志加载失败',
                            message: state.error!,
                            onRetry: () => ref
                                .read(logListProvider.notifier)
                                .load(refresh: true),
                          ),
                        ],
                      )
                    : state.logs.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: const [
                          AppEmptyView(
                            icon: Icons.article_outlined,
                            message: '暂无日志',
                          ),
                        ],
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
                        itemCount: state.logs.length,
                        itemBuilder: (_, i) {
                          final log = state.logs[i];
                          return _LogItem(
                            log: log,
                            isLight: isLight,
                            selectionMode: _selectionMode,
                            selected: _selectedIds.contains(log.id),
                            onView: () {
                              if (_selectionMode) {
                                _toggleSelection(log.id);
                              } else {
                                context.push('/logs/${log.id}/stream');
                              }
                            },
                            onLongPress: () {
                              if (!_selectionMode) {
                                _enterSelectionModeWith(log.id);
                              }
                            },
                            onDelete: () => _handleDelete(log),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LogItem extends StatelessWidget {
  final TaskLog log;
  final bool isLight;
  final VoidCallback onView;
  final VoidCallback onDelete;
  final VoidCallback? onLongPress;
  final bool selectionMode;
  final bool selected;

  const _LogItem({
    required this.log,
    required this.isLight,
    required this.onView,
    required this.onDelete,
    this.onLongPress,
    this.selectionMode = false,
    this.selected = false,
  });

  // 日志列表最主要的状态区分就靠这个圆点：成功=绿、失败=红、运行中=蓝。
  // 改造前成功取 primary(#409EFF)、运行中取 blue500(#3B82F6)，主色换蓝后
  // 两者都是蓝、肉眼分不出。
  Color _statusColor() {
    if (log.isSuccess) return AppColors.success;
    if (log.isFailed) return AppColors.danger;
    return AppColors.info;
  }

  @override
  Widget build(BuildContext context) {
    final color = _statusColor();
    // 外层只接管长按（进入多选），点击进详情仍由内层 InkWell 负责 ——
    // 两者是不同动作，不能折叠成同一个 onTap：内层的点击区只覆盖标题那一段，
    // 提到外层会让「删除」按钮旁边的空白也变成进详情的热区。
    return AppCard(
      onLongPress: onLongPress,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      color: selected
          ? (isLight
                ? AppColors.primary.withAlpha(12)
                : AppColors.primary.withAlpha(20))
          : null,
      borderColor: selected ? AppColors.primary.withAlpha(80) : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (selectionMode) ...[
            SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(
                value: selected,
                onChanged: (_) => onView(),
                activeColor: AppColors.primary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(width: 10),
          ] else ...[
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          ],
          const SizedBox(width: 12),
          Expanded(
            child: InkWell(
              onTap: onView,
              borderRadius: BorderRadius.circular(AppRadius.md),
              // 卡片的纵向内边距搬到这里来：整行的高度本来就由这个 InkWell 决定，
              // 内边距放在外面时它白白撑高卡片，放进来则同时成为点击区。
              // 结果是卡片矮了 20dp，而「点进日志详情」的点击目标反而
              // 从 43.3dp 长到 55.3dp，越过了 48dp 下限。
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      log.taskName ?? '任务 #${log.taskId}',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.onSurface,
                        height: 1.2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '运行时间 ${formatTimeCn(log.startedAt)} · ${log.durationText}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: isLight
                            ? AppColors.slate500
                            : AppColors.slate400,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: '删除日志',
            onPressed: onDelete,
            visualDensity: VisualDensity.compact,
            splashRadius: 20,
            icon: const Icon(Icons.delete_outline, size: 20),
            color: AppColors.red500,
          ),
        ],
      ),
    );
  }
}

class _StatusFilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// 状态筛选 chip 的强调色。
  ///
  /// 传 null 表示「这不是某个状态，而是『全部』」，用中性强调色。
  /// 原先默认值是 `AppColors.primary`，主色换蓝之后「全部」和「运行中」
  /// 是同一族蓝，选中时分不清选的是哪个，所以默认改成中性色。
  final Color? selectedColor;

  const _StatusFilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.selectedColor,
  });

  @override
  Widget build(BuildContext context) {
    final surfaces = AppSurfaces.of(context);
    final isLight = surfaces.isLight;
    final accent =
        selectedColor ?? (isLight ? AppColors.slate800 : AppColors.slate100);
    // 选中态底色是 accent 的 alpha=16 淡底。三个筛选项传的是
    // success / danger / info，其中 success 在淡底上只有 2.13:1。
    final foreground = selected
        ? surfaces.tintFg(accent)
        : (isLight ? AppColors.slate600 : AppColors.slate300);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? accent.withAlpha(16)
                : (isLight ? AppColors.slate50 : AppColors.slate950),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected
                  ? accent.withAlpha(70)
                  : (isLight ? AppColors.slate200 : AppColors.slate800),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: foreground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
