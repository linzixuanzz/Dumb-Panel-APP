import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
// ScrollDirection 只在 rendering 里导出，material/widgets 都没有转出来。
// 用它来区分「用户自己拖的」和「恢复流程 jumpTo 出来的」滚动。
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_provider.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/storage/secure_storage.dart';
import '../../../core/network/sse_client.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/models/task.dart';
import '../../../shared/models/task_view.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/utils/panel_enums.dart';
import '../../../shared/utils/sse_replay_buffer.dart';
import '../../../shared/utils/task_command.dart';
import '../../../shared/utils/log_background.dart';
import '../../../shared/utils/log_line_buffer.dart';
import '../../../shared/widgets/app_buttons.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/app_glass_circle_button.dart';
import '../../../shared/widgets/app_grouped_list.dart';
import '../../../shared/widgets/app_icon_tile.dart';
import '../../../shared/widgets/app_large_title_header.dart';
import '../../../shared/widgets/app_notice.dart';
import '../../../shared/widgets/app_pill_button.dart';
import '../../../shared/widgets/app_sheet.dart';
import '../../../shared/widgets/app_snack.dart';
import '../../../shared/widgets/app_state_views.dart';
import '../../../shared/widgets/fullscreen_log_scaffold.dart';
import '../../logs/utils/task_command_lookup.dart';
import '../providers/favorite_tasks_provider.dart';
import '../providers/task_provider.dart';
import '../providers/task_view_provider.dart';
import '../utils/task_list_rows.dart';
// B2 提供：点任务打开详情弹层（第二波组间契约）
import '../widgets/task_detail_sheet.dart';
import '../widgets/favorite_task_cards.dart';
import '../widgets/task_view_sheets.dart';

class TaskListPage extends ConsumerStatefulWidget {
  const TaskListPage({super.key});

  @override
  ConsumerState<TaskListPage> createState() => _TaskListPageState();
}

class _TaskStatusFilter {
  final String label;
  final String? value;

  const _TaskStatusFilter(this.label, this.value);
}

const _taskStatusFilters = [
  _TaskStatusFilter('全部', null),
  _TaskStatusFilter('运行中', '2'),
  _TaskStatusFilter('排队中', '0.5'),
  _TaskStatusFilter('已启用', '1'),
  _TaskStatusFilter('已禁用', '0'),
];

enum _TaskBatchAction { run, enable, disable, delete }

/// 快捷排序的一项（APP #28）。[rule] 为 null = 默认排序。
class _TaskQuickSortOption {
  final String label;
  final TaskViewSortRule? rule;

  const _TaskQuickSortOption(this.label, this.rule);

  /// 本机记忆里存的值：`字段:方向`，默认排序存空串。不存下标：以后增删选项时旧记忆不会错位。
  String get storageValue =>
      rule == null ? '' : '${rule!.field}:${rule!.direction}';
}

/// 与网页任务页 `quickSortOptions`（web/src/views/tasks/index.vue）逐项一致，顺序和文案都照抄，
/// 两端用户说「按 XX 排」时指的是同一个东西。面板新增排序字段要两端一起加。
const _taskQuickSortOptions = [
  _TaskQuickSortOption('默认排序', null),
  _TaskQuickSortOption('名称 A→Z', TaskViewSortRule(field: 'name')),
  _TaskQuickSortOption(
    '名称 Z→A',
    TaskViewSortRule(field: 'name', direction: 'desc'),
  ),
  _TaskQuickSortOption(
    '创建时间（最新优先）',
    TaskViewSortRule(field: 'created_at', direction: 'desc'),
  ),
  _TaskQuickSortOption('创建时间（最早优先）', TaskViewSortRule(field: 'created_at')),
  _TaskQuickSortOption(
    '最后运行（最近优先）',
    TaskViewSortRule(field: 'last_run_at', direction: 'desc'),
  ),
  _TaskQuickSortOption('最后运行（最早优先）', TaskViewSortRule(field: 'last_run_at')),
  _TaskQuickSortOption('下次运行（最快到来）', TaskViewSortRule(field: 'next_run_at')),
  _TaskQuickSortOption(
    '下次运行（最晚到来）',
    TaskViewSortRule(field: 'next_run_at', direction: 'desc'),
  ),
  // 按每天最早一次执行的时刻排，不是按表达式字符串（面板 v3.3.3 起的口径，见网页那两项的注释）。
  _TaskQuickSortOption(
    '定时规则（每天时刻 早→晚）',
    TaskViewSortRule(field: 'cron_expression'),
  ),
  _TaskQuickSortOption(
    '定时规则（每天时刻 晚→早）',
    TaskViewSortRule(field: 'cron_expression', direction: 'desc'),
  ),
];

/// 排序按钮上的短字段名（同网页 quickSortFieldLabels 里用得到的几项）。
const _quickSortFieldLabels = {
  'name': '名称',
  'created_at': '创建时间',
  'last_run_at': '最后运行',
  'next_run_at': '下次运行',
  'cron_expression': '定时规则',
};

class _TaskListPageState extends ConsumerState<TaskListPage> {
  static const _collapsedGroupsStorageKey = 'tasks.collapsed_groups';
  static const _scrollOffsetStorageKey = 'tasks.scroll_offset';
  static const _selectedGroupStorageKey = 'tasks.selected_group';
  static const _groupOrderStorageKey = 'tasks.group_order';

  /// 选中的任务视图 id。存空串表示「全部任务」。
  /// 视图是全局共享的，别人随时可能删掉它，所以恢复时必须能回落。
  static const _selectedViewStorageKey = 'tasks.selected_view';

  /// 上次选的快捷排序（APP #28），值见 [_TaskQuickSortOption.storageValue]。
  /// 同上面几项本机偏好一样不分服务器。
  static const _quickSortStorageKey = 'tasks.quick_sort';
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  final Set<String> _collapsedGroups = <String>{};
  final Set<int> _selectedTaskIds = <int>{};
  final List<String> _knownGroups = <String>[];
  List<String> _groupOrder = <String>[];
  bool _groupReorderMode = false;
  bool _selectionMode = false;
  bool _taskSortMode = false;
  Timer? _debounce;
  bool _scrollRestoreStarted = false;
  bool _restoredScrollOffset = false;
  // 已经排了一次「下一帧再试恢复」，避免 build 和重试链重复排帧。
  bool _scrollRestoreScheduled = false;
  // 等 ScrollController attach 的帧数。列表还停在加载/错误/空态时它没有 clients，
  // 只能一帧一帧地等；这个计数是防止一直等不到时无限排帧下去的兜底。
  int _scrollRestoreWaitFrames = 0;
  // 用户是不是已经自己滚过了。一旦为真，恢复流程必须立刻收手（见 _stepRestoreScrollOffset）。
  bool _userScrolled = false;
  // 滚动位置写盘的防抖定时器与「还没落地的最新值」。
  Timer? _scrollSaveDebounce;
  String? _pendingScrollOffset;

  /// 整页共用的「现在」，每秒跳一次，只驱动倒计时那几个字重建（不 setState 整页）。
  final ValueNotifier<DateTime> _now = ValueNotifier<DateTime>(DateTime.now());
  Timer? _clock;

  /// APP 进后台（hidden / paused）时停掉 1 秒时钟，回到前台立刻跳一次再接着走。
  AppLifecycleListener? _lifecycle;

  /// 搜索框默认收起，点页头的放大镜才展开；有搜索词时始终展开。
  bool _searchOpen = false;
  final _searchFocus = FocusNode();

  /// 「搜索任务」快捷方式（B8）跳 `/tasks?search=<毫秒时间戳>`：值每次都不同，变了才聚焦一次。
  ///
  /// 记在 static 上而不是 State 上：切 Tab 回来、从子页面返回时页面可能被重建，
  /// 而地址栏里还是那个旧值，记在 State 上会再聚焦一遍。query 不主动清，靠这个去重。
  static String? _lastHandledSearch;

  /// 监听路由变化用；拿不到（页面不在 GoRouter 下）时为 null。
  GoRouter? _router;

  // 等待 ScrollController attach 的帧数上限。
  // 正常情况下列表挂载当帧就能拿到 clients，这个上限只在「一直卡在加载态 / 错误态」
  // 时才会用到（加载动画会持续产帧），约合 10 秒后放弃恢复、但仍然放开保存闸。
  static const int _maxScrollRestoreWaitFrames = 600;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _now.value = DateTime.now(),
    );
    _lifecycle = AppLifecycleListener(
      onHide: () {
        _clock?.cancel();
        _clock = null;
      },
      onResume: () {
        // 只拉下通知栏这种 inactive → resumed 没停过时钟，不用处理
        if (_clock != null) return;
        _now.value = DateTime.now();
        _clock = Timer.periodic(
          const Duration(seconds: 1),
          (_) => _now.value = DateTime.now(),
        );
      },
    );
    // taskProvider 是全局的，切走切回时可能还带着上次的搜索词：搜索框要把它显示出来，
    // 否则列表被筛着、搜索框却是空的。
    _searchController.text = ref.read(taskProvider).keyword;
    Future.microtask(_bootstrapTaskPage);
    _scrollController.addListener(_onScroll);
    // 恢复滚动位置只能从「首帧之后」起跑：ScrollController 是在 build() 返回、
    // Scrollable 挂载时才 attach 的，在 build 体内同步调用永远是 hasClients == false。
    // 这里补一个首帧回调兜底，否则常见路径（provider 无轮询 / 无 SSE、_onScroll 不 setState）
    // 下压根不会有第二次 rebuild，_restoredScrollOffset 会永远是 false，
    // 把下面 _onScroll 里的保存闸永久锁死 —— 滚动位置一个字节都写不进去。
    _scheduleScrollRestore();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 已经停在任务页时再点一次快捷方式，页面不会重建，只能盯着路由变化
    final router = GoRouter.maybeOf(context);
    if (router != _router) {
      _router?.routerDelegate.removeListener(_onRouteChanged);
      _router = router;
      _router?.routerDelegate.addListener(_onRouteChanged);
      // 冷启动 / 从别的 Tab 跳过来：当前地址里可能已经带着 search
      _onRouteChanged();
    }
  }

  /// 地址里带着新的 `search` 值时，展开并聚焦搜索框（不改已有的搜索词）。
  void _onRouteChanged() {
    final router = _router;
    if (router == null || !mounted) {
      return;
    }
    final search =
        router.routerDelegate.currentConfiguration.uri.queryParameters['search'];
    if (search == null || search.isEmpty || search == _lastHandledSearch) {
      return;
    }
    _lastHandledSearch = search;
    // 路由通知可能来自 build 期间，放到帧后再 setState / 抢焦点
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _openSearchAndFocus();
    });
  }

  /// 展开搜索框并聚焦。输入框是这次 setState 之后才建出来的，
  /// 焦点要等它挂上树（下一帧）再要，否则 requestFocus 落空。
  void _openSearchAndFocus() {
    setState(() => _searchOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _searchFocus.requestFocus();
      }
    });
  }

  /// 进入任务页时的初始化。
  ///
  /// 顺序是刻意排的：**任务列表那次请求不能被可选能力挡住**。
  /// 视图列表（`/api/tasks/views`）在老面板上 404、viewer 角色 403，而 dio 的
  /// connectTimeout 是 15s、receiveTimeout 30s —— 面板慢或正在重启时，先 await
  /// 它等于任务列表 15~30s 一个请求都不发，而每次切回本页都会重来一遍。
  /// 只有「本地存了视图 id、provider 里却还没有选中视图」这一种真·冷启动恢复，
  /// 才必须先等视图列表（否则没法把 id 还原成规则）；其余情况让它在后台跑，
  /// 视图按钮靠 `ref.watch` 在它回来之后自然刷新。
  ///
  /// 另一条硬约束：整个流程**只发一次任务列表请求**。恢复分组、恢复视图都用
  /// 不发请求的 setXxxSelection 写进 provider，最后统一 load() 一次 ——
  /// 否则先发出去的那次不带规则、后发的带规则，两次都会写 `state.tasks`，
  /// 谁后到谁赢，用户会看到「按钮写着视图名、列表却是没筛过的全量」。
  Future<void> _bootstrapTaskPage() async {
    // 常用任务按面板存：刚切过面板时先换成当前面板那一份（不发请求）
    ref.read(favoriteTasksProvider.notifier).syncScope();
    await _restoreTaskUiState();
    if (!mounted) {
      return;
    }
    final savedViewId = await _readSavedViewId();
    if (!mounted) {
      return;
    }
    // 任务视图是**可选能力**：老面板没有这条路由、viewer 角色也拿不到，
    // 那两种情况 load() 内部会静默降级成「没有视图」，不会抛也不会红。
    final loadingViews = ref.read(taskViewProvider.notifier).load();
    // 「恢复上次的视图」是个迟到的动作：等视图列表回来可能要好几秒（最坏是 dio 的
    // 15~30s 超时）。这期间筛选按钮是可点的，用户完全可能自己切了视图。
    // 记下起点，回来时发现已经不是它了就整个让位 —— 否则会把用户刚选的那条弹回去，
    // 而且只改 provider 不改存储，留下「界面 = 旧视图、存储 = 新视图」的分叉。
    final selectionAtStart = ref.read(taskProvider).selectedViewId;
    bool userTookOver() =>
        ref.read(taskProvider).selectedViewId != selectionAtStart;
    final coldRestore = savedViewId != null && selectionAtStart == null;
    if (coldRestore) {
      await loadingViews;
      if (!mounted || userTookOver()) {
        return;
      }
      await _applySavedView(savedViewId);
      if (!mounted) {
        return;
      }
      await ref.read(taskProvider.notifier).load(refresh: true);
      return;
    }
    if (savedViewId == null) {
      // 上次就是「全部任务」。taskProvider 是全局、非 autoDispose 的，切走切回
      // 不会重建状态，可能还带着上一轮的规则回来 —— 先清掉，下面那次 load()
      // 才是对的参数。这一步不需要视图列表。
      await _applySavedView(null);
      if (!mounted) {
        return;
      }
    }
    await ref.read(taskProvider.notifier).load(refresh: true);
    if (savedViewId == null) {
      // 上面已经清成「全部任务」了，视图列表回来也改不了这次请求的参数。
      return;
    }
    if (!mounted) {
      return;
    }
    // 视图列表晚一点回来没关系，但回来之后必须再校一次：这条视图可能已经被
    // 别人删了 / 隐藏了 / 改过规则（表是全站共享的），那样上面那次请求带的参数
    // 就是错的。真变了才补一次请求，没变就一次都不多发。
    await loadingViews;
    if (!mounted || userTookOver()) {
      return;
    }
    if (await _applySavedView(savedViewId) && mounted) {
      await ref.read(taskProvider.notifier).load(refresh: true);
    }
  }

  void _onScroll() {
    // 任务是 `all=1` 一次性全量拉回来的，列表卡顿靠 ListView.builder 虚拟化解决，
    // 不需要「滚到底再加载下一页」，所以这里只剩记录滚动位置这一件事。
    if (!_scrollController.hasClients) {
      return;
    }
    // 区分「用户自己拖的」和「恢复流程 jumpTo 出来的」：
    // jumpTo 走的是 goIdle -> IdleScrollActivity，userScrollDirection 始终是 idle；
    // 只有 applyUserOffset（真的有手指在拖）才会把它改成 forward/reverse。
    if (_scrollController.position.userScrollDirection !=
        ScrollDirection.idle) {
      _userScrolled = true;
    }
    // 恢复上次位置的过程中会连跳好几帧（见 _restoreScrollOffsetIfNeeded），
    // 那些中间位置不能写回存储，否则会把用户真正停留的深位置覆盖成一个很浅的值。
    // 但用户一旦自己接管，恢复流程会立刻放弃、后面不会再有程序化 jumpTo，
    // 这时即使 _restoredScrollOffset 还没置位也可以放心记。
    if (!_restoredScrollOffset && !_userScrolled) {
      return;
    }
    _scheduleScrollOffsetSave(_scrollController.offset);
  }

  /// 滚动位置写盘的防抖。
  ///
  /// `SecureStorage.saveUiState` 每次都是一趟 SharedPreferences 平台通道往返，
  /// 而一次 fling 会打出几百条滚动通知 —— 原来是一条一写，几百次往返，
  /// 正好把虚拟化省下来的开销又还回去了。这里只攒住最新值，停下来 250ms 才落盘。
  void _scheduleScrollOffsetSave(double offset) {
    _pendingScrollOffset = offset.toStringAsFixed(2);
    _scrollSaveDebounce?.cancel();
    _scrollSaveDebounce = Timer(
      const Duration(milliseconds: 250),
      _flushScrollOffset,
    );
  }

  /// 把攒住的滚动位置真正写进存储。dispose 里也会调一次，
  /// 否则「滚到底 -> 立刻切走」这条路径上最后一段位置会随防抖定时器一起被丢掉。
  void _flushScrollOffset() {
    final pending = _pendingScrollOffset;
    if (pending == null) {
      return;
    }
    _pendingScrollOffset = null;
    // 不 await：dispose 里也会走到这儿，State 已经在销毁路径上，写失败也没有可补救的动作。
    SecureStorage.saveUiState(_scrollOffsetStorageKey, pending);
  }

  void _showMessage(String message) => AppSnack.show(context, message);

  void _showSuccess(String message) => AppSnack.success(context, message);

  void _showError(String message) => AppSnack.error(context, message);

  void _showWarning(String message) => AppSnack.warn(context, message);

  /// 全部任务操作失败的漏斗：批量操作 / 排序保存 / 停止 / 启停 / 复制 / 置顶 / 删除，
  /// 外加分组的重命名 / 删除 / 添加任务 / 新建，都从这里出提示，
  /// 所以着色和错误文案提取只需要改这一处。
  Future<void> _showActionError(dynamic error, String fallback) async {
    _showError(_extractTaskError(error, fallback));
  }

  bool _isAllTasksSelected(List<Task> tasks) =>
      tasks.isNotEmpty &&
      tasks.every((task) => _selectedTaskIds.contains(task.id));

  void _setSelectionMode(bool enabled) {
    setState(() {
      _selectionMode = enabled;
      if (!enabled) {
        _selectedTaskIds.clear();
      }
    });
  }

  void _toggleTaskSelection(int id) {
    setState(() {
      _selectionMode = true;
      if (_selectedTaskIds.contains(id)) {
        _selectedTaskIds.remove(id);
      } else {
        _selectedTaskIds.add(id);
      }
      if (_selectedTaskIds.isEmpty) {
        _selectionMode = false;
      }
    });
  }

  void _toggleSelectAllTasks(List<Task> tasks) {
    final visibleIds = tasks.map((task) => task.id).toSet();
    setState(() {
      if (visibleIds.isNotEmpty &&
          visibleIds.every((id) => _selectedTaskIds.contains(id))) {
        _selectedTaskIds.removeAll(visibleIds);
        if (_selectedTaskIds.isEmpty) {
          _selectionMode = false;
        }
      } else {
        _selectionMode = true;
        _selectedTaskIds.addAll(visibleIds);
      }
    });
  }

  Future<bool> _confirmBatchTaskDelete(int count) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('批量删除任务'),
        content: Text('确定要删除选中的 $count 个任务吗？此操作不可恢复。'),
        actions: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: const Text('取消'),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(dialogContext, true),
                    style: FilledButton.styleFrom(
                      backgroundColor: dialogContext.palette.err,
                      foregroundColor: dialogContext.palette.onStatus,
                    ),
                    child: const Text('删除'),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _performBatchTaskAction(_TaskBatchAction action) async {
    final ids = _selectedTaskIds.toList()..sort();
    if (ids.isEmpty) {
      return;
    }

    if (action == _TaskBatchAction.run && ids.length > 10) {
      _showWarning('批量运行最多选择 10 个任务');
      return;
    }

    if (action == _TaskBatchAction.delete) {
      final confirmed = await _confirmBatchTaskDelete(ids.length);
      if (!confirmed) {
        return;
      }
    }

    try {
      final notifier = ref.read(taskProvider.notifier);
      switch (action) {
        case _TaskBatchAction.run:
          await notifier.batchRun(ids);
          break;
        case _TaskBatchAction.enable:
          await notifier.batchEnable(ids);
          break;
        case _TaskBatchAction.disable:
          await notifier.batchDisable(ids);
          break;
        case _TaskBatchAction.delete:
          await notifier.batchDelete(ids);
          break;
      }

      if (!mounted) {
        return;
      }

      _setSelectionMode(false);
      final message = switch (action) {
        _TaskBatchAction.run => '已批量运行 ${ids.length} 个任务',
        _TaskBatchAction.enable => '已批量启用 ${ids.length} 个任务',
        _TaskBatchAction.disable => '已批量禁用 ${ids.length} 个任务',
        _TaskBatchAction.delete => '已批量删除 ${ids.length} 个任务',
      };
      _showSuccess(message);
    } catch (error) {
      await _showActionError(error, '批量操作失败');
    }
  }

  /// 批量设置通知开关（面板 v3.3.3 / issue #149）。只作用于选中的任务；
  /// APP 的列表是全量拉取，「全选」就是当前筛选下的全部任务，不需要面板的 `all`。
  Future<void> _performBatchNotify() async {
    final ids = _selectedTaskIds.toList()..sort();
    if (ids.isEmpty) {
      return;
    }
    final choice = await _showBatchNotifyDialog(ids.length);
    if (choice == null) {
      return;
    }

    try {
      await ref
          .read(taskProvider.notifier)
          .batchSetNotify(
            ids,
            onFailure: choice.onFailure,
            onSuccess: choice.onSuccess,
          );
      if (!mounted) {
        return;
      }
      _setSelectionMode(false);
      _showSuccess('已更新 ${ids.length} 个任务的通知设置');
    } catch (error) {
      // 老面板没有这条接口时，provider 已经翻译成「请升级」的中文，这里照常展示。
      await _showActionError(error, '批量设置通知失败');
    }
  }

  /// 失败 / 成功两行，各「开启 / 关闭 / 不修改」三档；APP 没有终止通知，所以不放那一行。
  /// 返回的开关为 null 表示「不修改」，整体返回 null 表示取消。
  Future<({bool? onFailure, bool? onSuccess})?> _showBatchNotifyDialog(
    int count,
  ) {
    // 失败默认「开启」—— #149 要的就是一键打开失败通知；成功默认不动，免得顺手把成功通知也改了。
    var failure = 'on';
    var success = 'keep';
    bool? toSwitch(String value) => value == 'keep' ? null : value == 'on';
    const segments = [
      ButtonSegment(value: 'on', label: Text('开启')),
      ButtonSegment(value: 'off', label: Text('关闭')),
      ButtonSegment(value: 'keep', label: Text('不修改')),
    ];

    return showDialog<({bool? onFailure, bool? onSuccess})>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          // 两项都「不修改」时面板会回 400，干脆不让提交。
          final nothingToChange = failure == 'keep' && success == 'keep';
          return AlertDialog(
            title: const Text('批量设置通知'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('将修改选中的 $count 个任务'),
                  const SizedBox(height: 16),
                  const Text('失败时通知'),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    segments: segments,
                    selected: {failure},
                    // 窄屏上三段带勾选图标会挤不下，靠底色区分选中即可。
                    showSelectedIcon: false,
                    onSelectionChanged: (selection) =>
                        setDialogState(() => failure = selection.first),
                  ),
                  const SizedBox(height: 16),
                  const Text('成功时通知'),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    segments: segments,
                    selected: {success},
                    showSelectedIcon: false,
                    onSelectionChanged: (selection) =>
                        setDialogState(() => success = selection.first),
                  ),
                  const SizedBox(height: 16),
                  // 面板这条接口只改开关、不碰渠道（与网页端弹窗同一句提示）。
                  AppNotice(
                    color: context.palette.accent,
                    text: '不修改任务绑定的通知渠道；没绑渠道的任务会发到默认推送渠道',
                  ),
                ],
              ),
            ),
            actions: [
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('取消'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: FilledButton(
                        onPressed: nothingToChange
                            ? null
                            : () => Navigator.pop(dialogContext, (
                                onFailure: toSwitch(failure),
                                onSuccess: toSwitch(success),
                              )),
                        child: const Text('确定'),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  void _openLiveLog(Task task) {
    context.push('/tasks/${task.id}/live-logs', extra: task.name);
  }

  Future<void> _runTask(Task task) async {
    try {
      await ref.read(taskProvider.notifier).runTask(task.id);
      if (!mounted) {
        return;
      }
      _openLiveLog(task);
    } catch (error) {
      final message = _extractTaskError(error, '启动任务失败');
      if (!mounted) {
        return;
      }
      if (message.contains('运行中')) {
        _openLiveLog(task);
        return;
      }
      _showError(message);
    }
  }

  Future<void> _stopTask(Task task) async {
    try {
      await ref.read(taskProvider.notifier).stopTask(task.id);
      _showSuccess('任务已停止');
    } catch (error) {
      await _showActionError(error, '停止任务失败');
    }
  }

  Future<void> _toggleTaskEnabled(Task task) async {
    try {
      // 按开关位分支，不按 status：禁用任务被手动运行时 status 是 0.5 / 2，
      // 按 isDisabled 判会走进「禁用」分支 —— 给一条本来就禁用的任务再打一次
      // 待禁用标记、提示「完成后禁用」，用户在它跑完之前根本启用不了它。
      if (!task.isSwitchOn) {
        await ref.read(taskProvider.notifier).enableTask(task.id);
        _showSuccess('任务已启用');
      } else {
        await ref.read(taskProvider.notifier).disableTask(task.id);
        _showSuccess(task.isRunning ? '任务已设置为完成后禁用' : '任务已禁用');
      }
    } catch (error) {
      await _showActionError(error, '更新任务状态失败');
    }
  }

  Future<void> _copyTask(Task task) async {
    try {
      await ref.read(taskProvider.notifier).copyTask(task.id);
      _showSuccess('任务已复制');
    } catch (error) {
      await _showActionError(error, '复制任务失败');
    }
  }

  Future<void> _togglePinned(Task task) async {
    try {
      if (task.isPinned) {
        await ref.read(taskProvider.notifier).unpinTask(task.id);
        _showSuccess('已取消置顶');
      } else {
        await ref.read(taskProvider.notifier).pinTask(task.id);
        _showSuccess('已置顶任务');
      }
    } catch (error) {
      await _showActionError(error, '更新置顶状态失败');
    }
  }

  void _onSearchChanged(String value) {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (_scrollController.hasClients && _scrollController.offset > 0) {
        _scrollController.jumpTo(0);
      }
      ref.read(taskProvider.notifier).setKeyword(value);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _clock?.cancel();
    _lifecycle?.dispose();
    _now.dispose();
    _searchFocus.dispose();
    _router?.routerDelegate.removeListener(_onRouteChanged);
    // 滚动位置是防抖写盘的，退出页面时很可能还有一次没落地的最新值。
    // 先 cancel 掉定时器（State 都要没了，回调再跑没有意义），再手动补写一次。
    _scrollSaveDebounce?.cancel();
    _flushScrollOffset();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _restoreTaskUiState() async {
    final collapsedRaw = await SecureStorage.getUiState(
      _collapsedGroupsStorageKey,
    );
    final selectedGroup = await SecureStorage.getUiState(
      _selectedGroupStorageKey,
    );
    final groups = <String>{};
    if (collapsedRaw != null && collapsedRaw.trim().isNotEmpty) {
      groups.addAll(
        collapsedRaw
            .split('\n')
            .map((item) => item.trim())
            .where((item) => item.isNotEmpty),
      );
    } else {
      groups.add('');
    }
    if (!mounted) {
      return;
    }
    final groupOrderRaw = await SecureStorage.getUiState(_groupOrderStorageKey);
    final savedGroupOrder = <String>[];
    if (groupOrderRaw != null && groupOrderRaw.trim().isNotEmpty) {
      savedGroupOrder.addAll(groupOrderRaw.split('\n').map((s) => s.trim()));
    }
    if (!mounted) return;
    setState(() {
      _collapsedGroups
        ..clear()
        ..addAll(groups);
      _groupOrder = savedGroupOrder;
    });
    if (selectedGroup != null) {
      // ⚠️ 兼容归一：这个 key 的**存量是裸分组名**（旧版本写进去的），
      // 而现在发给服务端的必须是带 `分组:` 前缀的完整标签。
      // 不归一的话，老用户升级后冷启动会拿裸名去做 LIKE，把只挂了同名普通标签
      // 的任务一起捞回来 —— 表现为「筛了分组却混进别的任务」。
      final normalized = Task.normalizeGroupLabel(selectedGroup);
      // 刻意用**不发请求**的版本：setLabelFilter 会当场打出一次不带 filters /
      // sort_rules 的请求，和 _bootstrapTaskPage 末尾那次带规则的请求撞车，
      // 两次都写 state.tasks，谁后到谁赢。唯一一次请求留给统一的 load()。
      ref
          .read(taskProvider.notifier)
          .setLabelSelection(normalized.isEmpty ? null : normalized);
    }
    // 恢复快捷排序，同样只写 provider 不发请求，唯一一次请求留给 _bootstrapTaskPage 末尾的 load()。
    // 存的值对不上任何一项（被手改过 / 以后删了某项）就当默认排序。
    final quickSortRaw = await SecureStorage.getUiState(_quickSortStorageKey);
    if (!mounted) {
      return;
    }
    TaskViewSortRule? quickSort;
    for (final option in _taskQuickSortOptions) {
      if (option.rule != null && option.storageValue == quickSortRaw?.trim()) {
        quickSort = option.rule;
      }
    }
    ref.read(taskProvider.notifier).setQuickSortSelection(quickSort);
  }

  /// 上次选中的视图 id。没存过 / 存的是空串 / 存了个非数字，都当成「全部任务」。
  Future<int?> _readSavedViewId() async {
    final raw = await SecureStorage.getUiState(_selectedViewStorageKey);
    return int.tryParse(raw?.trim() ?? '');
  }

  /// 把「上次选中的视图」落到 taskProvider 上，**不发请求**。
  /// 返回 true 表示生效的规则真的变了，调用方需要重新拉一次任务列表。
  ///
  /// 视图是**全局共享**的（表里没有 user_id），别人随时可能把它删掉或隐藏，
  /// 所以找不到时要静静地回落到「全部任务」，并把过期的记录清掉。
  ///
  /// ⚠️ 回落时必须连 taskProvider 里的规则一起清：它是全局、非 autoDispose 的，
  /// 页面切走切回只重跑 initState、不重建状态。只清本地存储的话，列表会继续被
  /// 一条已经不存在的视图筛着，按钮却显示「全部任务」——
  /// 用户看到的就是「明明写着全部任务，任务却少了一半」。
  Future<bool> _applySavedView(int? savedViewId) async {
    final before = ref.read(taskProvider);
    TaskView? view;
    if (savedViewId != null) {
      final viewState = ref.read(taskViewProvider);
      if (viewState.error != null) {
        // 这一次没拉到视图列表（断网 / 面板 500）。这不等于「视图被删了」——
        // 按删了处理，会在一次网络抖动之后把用户存了很久的选择连本地记录一起
        // 清掉。保持现状，等下次进页面再校。
        // （404 / 403 走的是 supported=false + views 清空，那是能力真的没了，
        //   下面会正常回落到「全部任务」。）
        return false;
      }
      view = viewState.viewById(savedViewId);
      if (view != null && view.hidden) {
        view = null;
      }
      if (view == null) {
        await SecureStorage.saveUiState(_selectedViewStorageKey, '');
        if (!mounted) {
          return false;
        }
      }
    }
    ref.read(taskProvider.notifier).setViewSelection(view);
    final after = ref.read(taskProvider);
    // 只比 id 不够：视图还在、但规则被别人在网页上改过时 id 是一样的，
    // 而已经发出去的那次请求带的仍然是旧规则，同样得重来一次。
    return before.selectedViewId != after.selectedViewId ||
        encodeTaskViewFilters(before.filters) !=
            encodeTaskViewFilters(after.filters) ||
        encodeTaskViewSortRules(before.sortRules) !=
            encodeTaskViewSortRules(after.sortRules);
  }

  Future<void> _persistSelectedView(int? id) {
    return SecureStorage.saveUiState(
      _selectedViewStorageKey,
      id?.toString() ?? '',
    );
  }

  Future<void> _persistCollapsedGroups() {
    return SecureStorage.saveUiState(
      _collapsedGroupsStorageKey,
      _collapsedGroups.join('\n'),
    );
  }

  Future<void> _persistGroupOrder() {
    return SecureStorage.saveUiState(
      _groupOrderStorageKey,
      _groupOrder.join('\n'),
    );
  }

  /// 把「尝试恢复滚动位置」排到下一帧结束之后。
  ///
  /// 不能在 build 体内直接调 [_restoreScrollOffsetIfNeeded]：
  /// Flutter 里 `ScrollController` 是在父 widget 的 build() **返回之后**、
  /// Scrollable 挂载时才 attach 上来的，所以列表首次出现的那一帧 `hasClients` 恒为 false。
  void _scheduleScrollRestore() {
    if (_scrollRestoreStarted || _scrollRestoreScheduled) {
      return;
    }
    _scrollRestoreScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollRestoreScheduled = false;
      _restoreScrollOffsetIfNeeded();
    });
  }

  Future<void> _restoreScrollOffsetIfNeeded() async {
    // 用 _scrollRestoreStarted 保证只真正跑一次
    //（_restoredScrollOffset 要等跳完才置位，挡不住重入）。
    if (_scrollRestoreStarted || !mounted) {
      return;
    }
    if (!_scrollController.hasClients) {
      // 列表还停在加载态 / 错误态 / 空态（那三条分支的 ListView 根本没挂 _scrollController），
      // 或者 Scrollable 还没 attach 完。这里必须安排下一帧继续等，**不能静默返回** ——
      // 一返回就再没有别的触发点，_restoredScrollOffset 会永远是 false，
      // _onScroll 里的保存闸被永久锁死，滚动位置一个字节都写不进去。
      _scrollRestoreWaitFrames++;
      if (_scrollRestoreWaitFrames > _maxScrollRestoreWaitFrames) {
        // 等太久（一直没拿到数据）就放弃恢复，但保存闸必须打开，
        // 否则这一次进入页面之后再也记不住位置。
        _scrollRestoreStarted = true;
        _restoredScrollOffset = true;
        return;
      }
      _scheduleScrollRestore();
      return;
    }
    _scrollRestoreStarted = true;
    final raw = await SecureStorage.getUiState(_scrollOffsetStorageKey);
    final offset = double.tryParse(raw?.trim() ?? '');
    // 读存储是异步的，这中间用户完全可能已经自己滚起来了 —— 那就别再把他拽走。
    if (!mounted || _userScrolled || offset == null || offset <= 0) {
      _restoredScrollOffset = true;
      return;
    }
    _stepRestoreScrollOffset(offset, -1.0, 0);
  }

  /// 惰性列表的滚动位置恢复。
  ///
  /// `ListView.builder` 只布局可见区域，首帧的 `maxScrollExtent` 只是
  /// 「已经布局出来的那一段 + 剩余项的粗略估算」，比真实值小得多。
  /// 改造前直接 `offset.clamp(0, maxScrollExtent)`，深位置会被夹到很靠前的地方，
  /// 表现为「退出任务页再进来，回不到原来的位置」。
  ///
  /// 所以这里逐帧往下跳：每跳一次就会带出下一屏内容、`maxScrollExtent` 随之变大，
  /// 直到够到目标位置，或者列表确实到底了（这一帧没再变长）为止。
  void _stepRestoreScrollOffset(
    double target,
    double lastMaxExtent,
    int attempt,
  ) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) {
        // 列表中途换成了空态 / 错误态（controller 脱离），恢复就此作罢，
        // 但要放开 _onScroll 的记录，否则这一次进入页面之后再也不记位置了。
        _restoredScrollOffset = true;
        return;
      }
      // 用户已经自己滚过了：再继续逐帧 jumpTo 就是把列表从他正在看的位置
      // 一路拽到上一次会话残留的旧位置，视觉上就是「列表自己乱跳」。
      // 这里立刻收手，同时放开保存闸，让他当前的位置能被正常记下来。
      if (_userScrolled) {
        _restoredScrollOffset = true;
        return;
      }
      final position = _scrollController.position;
      final maxExtent = position.maxScrollExtent;
      final next = target > maxExtent ? maxExtent : target;
      if ((position.pixels - next).abs() > 0.5) {
        _scrollController.jumpTo(next);
      }
      // 收工条件：够到目标 / 内容不再变长（任务被删了、换了筛选）/ 兜底次数用完。
      // 正常情况几帧就到位，60 次上限只是防死循环，不是期望值。
      if (next >= target - 0.5 || maxExtent <= lastMaxExtent || attempt >= 60) {
        _restoredScrollOffset = true;
        return;
      }
      _stepRestoreScrollOffset(target, maxExtent, attempt + 1);
    });
  }

  void _collectKnownGroups(List<Task> tasks) {
    final groups =
        tasks
            .map((task) => task.groupName?.trim() ?? '')
            .where((group) => group.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    _knownGroups
      ..clear()
      ..addAll(groups);
  }

  /// 「新建分组」在分组选择面板里的返回哨兵值。
  ///
  /// 分组名是用户输入的自由文本，理论上可能撞任何字面量，
  /// 所以用一个不可能出现在合法分组名里的前后缀标记。
  static const String _createGroupSentinel = '#dp:create-group#';

  Future<void> _showGroupPicker() async {
    final options = [..._knownGroups];
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('选择任务分组'), subtitle: Text('可筛选已有分组任务')),
            ListTile(
              leading: const Icon(Icons.layers_clear_outlined),
              title: const Text('全部分组'),
              onTap: () => Navigator.pop(sheetContext, ''),
            ),
            ...options.map(
              (group) => ListTile(
                leading: const Icon(Icons.label_outline),
                title: Text(group),
                trailing:
                    ref.watch(taskProvider).labelFilter ==
                        Task.toGroupLabel(group)
                    ? Icon(Icons.check, color: context.palette.accent)
                    : null,
                onTap: () => Navigator.pop(sheetContext, group),
              ),
            ),
            const Divider(height: 1),
            // 「新建分组」原先只挂在分组头右侧那个 18dp 的溢出菜单里。
            // 一个分组都没有时分组头已经不渲染，这个入口必须搬到常驻位置，
            // 否则用户就再也建不出第一个分组了。放这里同时也更好找。
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('新建分组'),
              subtitle: const Text('从未分组的任务中挑选'),
              onTap: () => Navigator.pop(sheetContext, _createGroupSentinel),
            ),
          ],
        ),
      ),
    );

    if (!mounted || selected == null) {
      return;
    }

    if (selected == _createGroupSentinel) {
      final ungrouped = ref
          .read(taskProvider)
          .tasks
          .where((task) => (task.groupName ?? '').isEmpty)
          .toList();
      await _showCreateGroupFromUngrouped(ungrouped);
      return;
    }

    if (_scrollController.hasClients && _scrollController.offset > 0) {
      _scrollController.jumpTo(0);
    }
    // ⚠️ 发出去的必须是 `分组:生产` 而不是显示名 `生产`：
    // 服务端做的是 `labels LIKE '%<值>%'`，传显示名会把只挂了普通标签「生产」、
    // 根本没分组的任务也捞回来，然后在客户端落进「未分组」桶 ——
    // 表现就是「筛了生产分组，列表里却冒出一个未分组的分组头」。
    // 存储里仍然存裸分组名（历史格式不动），恢复时由 normalizeGroupLabel 归一。
    ref
        .read(taskProvider.notifier)
        .setLabelFilter(
          selected.isEmpty ? null : Task.toGroupLabel(selected),
        );
    await SecureStorage.saveUiState(_selectedGroupStorageKey, selected);
  }

  Future<void> _showViewPicker() async {
    final result = await showTaskViewPicker(
      context,
      selectedViewId: ref.read(taskProvider).selectedViewId,
    );
    if (!mounted || result == null) {
      return;
    }
    if (result.action == TaskViewPickerAction.selectAll) {
      await _applyTaskView(null);
      return;
    }
    if (result.action == TaskViewPickerAction.select) {
      await _applyTaskView(result.view);
      return;
    }
    await _openTaskViewEditor(view: result.view);
  }

  Future<void> _applyTaskView(TaskView? view) async {
    if (_scrollController.hasClients && _scrollController.offset > 0) {
      _scrollController.jumpTo(0);
    }
    ref.read(taskProvider.notifier).applyView(view);
    await _persistSelectedView(view?.id);
    // applyView 把快捷排序复位成了默认，本机记忆跟着清掉，否则下次进来又恢复成旧的。
    await SecureStorage.saveUiState(_quickSortStorageKey, '');
  }

  /// 快捷排序选择（APP #28）。底部弹层列出与网页一致的 11 项，当前项打勾。
  Future<void> _showQuickSortPicker() async {
    final current = ref.read(taskProvider).quickSort;
    bool isCurrent(_TaskQuickSortOption option) =>
        option.rule?.field == current?.field &&
        option.rule?.direction == current?.direction;
    // 返回下标而不是规则：「默认排序」的规则是 null，会和「点遮罩关掉」的 null 混在一起。
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      // 11 项在矮屏上超过默认的半屏高度，放开高度、内容自己滚。
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('排序方式'),
              subtitle: Text('选了排序后，视图自带的排序暂不生效；切换视图时恢复默认排序'),
            ),
            for (var i = 0; i < _taskQuickSortOptions.length; i++)
              ListTile(
                title: Text(_taskQuickSortOptions[i].label),
                trailing: isCurrent(_taskQuickSortOptions[i])
                    ? Icon(Icons.check, color: context.palette.accent)
                    : null,
                onTap: () => Navigator.pop(sheetContext, i),
              ),
          ],
        ),
      ),
    );
    if (!mounted || picked == null) {
      return;
    }
    final option = _taskQuickSortOptions[picked];
    if (isCurrent(option)) {
      return;
    }
    if (_scrollController.hasClients && _scrollController.offset > 0) {
      _scrollController.jumpTo(0);
    }
    // 按快捷排序显示时拖拽不可用（dragSortDisabledReason），正在拖拽排序就顺手退出来。
    if (option.rule != null && _taskSortMode) {
      setState(() => _taskSortMode = false);
    }
    ref.read(taskProvider.notifier).applyQuickSort(option.rule);
    await SecureStorage.saveUiState(_quickSortStorageKey, option.storageValue);
  }

  Future<void> _openTaskViewEditor({TaskView? view}) async {
    final result = await showTaskViewEditor(context, view: view);
    if (!mounted || result == null || !result.changed) {
      return;
    }
    if (view == null) {
      // 刚建完就切过去：用户建规则本来就是为了立刻看到筛出来的结果。
      await _applyTaskView(result.view);
      return;
    }
    // 编辑 / 删除的若正好是当前选中的那条，必须按最新规则重跑一次，
    // 否则列表会继续拿着一份过期规则（甚至一条已经不存在的视图）在筛。
    final selectedId = ref.read(taskProvider).selectedViewId;
    if (selectedId != view.id) {
      return;
    }
    final latest = ref.read(taskViewProvider).viewById(selectedId);
    await _applyTaskView(latest != null && !latest.hidden ? latest : null);
  }

  /// 视图入口要不要出现。
  ///
  /// 面板不支持（老面板 404 / viewer 403）时整个入口藏起来 —— 摆一个点了
  /// 只会报错的按钮，比没有这个功能更糟。面板支持但一条视图都没有时也不摆，
  /// 除非当前账号能建（否则用户只能看到一个恒为「全部任务」的死按钮）。
  bool _showViewFilterEntry(TaskViewListState viewState, bool canManageViews) {
    if (!viewState.supported) {
      return false;
    }
    if (viewState.visibleViews.isNotEmpty) {
      return true;
    }
    return canManageViews;
  }

  String? _selectedViewName(TaskListState state, TaskViewListState viewState) {
    final view = viewState.viewById(state.selectedViewId);
    if (view == null || view.name.trim().isEmpty) {
      return null;
    }
    return view.name;
  }

  /// 筛选按钮的文字。视图名和分组名都是用户输入的自由文本，可以很长，
  /// 不封顶会把整行挤爆。
  Widget _buildFilterButtonLabel(String text) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 110),
      child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }

  void _clearTaskFilters() {
    if (_scrollController.hasClients && _scrollController.offset > 0) {
      _scrollController.jumpTo(0);
    }
    // 视图也是一种筛选，「清除筛选」不把它一起清掉的话，用户会以为按钮坏了。
    ref.read(taskProvider.notifier).clearFilters();
    SecureStorage.saveUiState(_selectedGroupStorageKey, '');
    _persistSelectedView(null);
  }

  /// 页头放大镜：展开 / 收起搜索框。收起时把搜索词一起清掉，
  /// 否则列表还被筛着、用户却看不到筛的是什么。
  void _toggleSearch() {
    final open =
        _searchOpen ||
        _searchController.text.isNotEmpty ||
        ref.read(taskProvider).keyword.isNotEmpty;
    if (!open) {
      _openSearchAndFocus();
      return;
    }
    _debounce?.cancel();
    _searchFocus.unfocus();
    final hadKeyword =
        _searchController.text.isNotEmpty ||
        ref.read(taskProvider).keyword.isNotEmpty;
    _searchController.clear();
    setState(() => _searchOpen = false);
    if (hadKeyword) {
      ref.read(taskProvider.notifier).setKeyword('');
    }
  }

  /// 进 / 出拖拽排序模式。此刻拖了也白拖（快捷排序 / 视图带排序规则 / 有任务在跑）就不进，只说原因；
  /// 退出不拦：「完成」任何时候都要能点。
  void _toggleTaskSortMode() {
    final reason = ref.read(taskProvider).dragSortDisabledReason;
    if (!_taskSortMode && reason != null) {
      _showWarning(reason);
      return;
    }
    setState(() {
      _taskSortMode = !_taskSortMode;
      if (_taskSortMode) {
        _groupReorderMode = false;
      }
    });
  }

  /// 页头「…」：批量操作、拖拽排序。原来这两个是页头上的两颗胶囊，
  /// 新页头只放圆形按钮（搜索 / 更多 / 新建），收进这里，功能不变。
  Future<void> _showMoreActions() async {
    final palette = context.palette;
    final reason = ref.read(taskProvider).dragSortDisabledReason;
    final action = await showAppSheet<String>(
      context: context,
      fullHeight: false,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: AppGroupedList(
            children: [
              AppGroupedRow(
                leading: AppIconTile(
                  icon: Icons.done_all_rounded,
                  color: palette.accent,
                ),
                title: '批量操作',
                subtitle: '多选后批量运行、启停、设置通知或删除',
                onTap: () => Navigator.pop(sheetContext, 'batch'),
              ),
              AppGroupedRow(
                leading: AppIconTile(
                  icon: Icons.swap_vert_rounded,
                  color: palette.purple,
                ),
                title: '拖拽排序',
                // 不能拖的原因提前说，省得点进去再被弹回来
                subtitle: reason ?? '长按拖动调整任务顺序，松手即保存',
                onTap: () => Navigator.pop(sheetContext, 'sort'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) {
      return;
    }
    if (action == 'batch') {
      _setSelectionMode(true);
    } else if (action == 'sort') {
      _toggleTaskSortMode();
    }
  }

  /// 任务行长按：加入 / 移出常用、多选。
  Future<void> _showTaskActions(Task task) async {
    HapticFeedback.mediumImpact();
    final palette = context.palette;
    final favorites = ref.read(favoriteTasksProvider.notifier);
    final isFavorite = favorites.isFavorite(task.id);
    final action = await showAppSheet<String>(
      context: context,
      fullHeight: false,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: AppGroupedList(
            header: task.name,
            children: [
              AppGroupedRow(
                leading: AppIconTile(
                  icon: isFavorite
                      ? Icons.star_outline_rounded
                      : Icons.star_rounded,
                  color: palette.warn,
                ),
                title: isFavorite ? '移出常用' : '加入常用',
                subtitle: isFavorite
                    ? null
                    : '显示在任务页顶部，最多 ${FavoriteTasksNotifier.maxCount} 个',
                onTap: () => Navigator.pop(sheetContext, 'favorite'),
              ),
              AppGroupedRow(
                leading: AppIconTile(
                  icon: Icons.done_all_rounded,
                  color: palette.accent,
                ),
                title: '多选',
                onTap: () => Navigator.pop(sheetContext, 'select'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) {
      return;
    }
    if (action == 'select') {
      _toggleTaskSelection(task.id);
      return;
    }
    if (!favorites.toggle(task.id)) {
      _showWarning('常用任务最多 ${FavoriteTasksNotifier.maxCount} 个，先移出一个再加');
      return;
    }
    _showSuccess(isFavorite ? '已移出常用' : '已加入常用');
  }

  /// 「所有任务」小标题 + 排序 / 视图 / 分组按钮 + 状态筛选。
  /// 正常浏览时排在列表里（「常用任务」下面，它只管下面这份列表）；
  /// 批量 / 拖拽排序时固定在页头下面，方便边操作边切筛选。
  Widget _buildFilterBar(
    TaskListState state,
    TaskViewListState viewState,
    bool canManageViews,
  ) {
    final palette = context.palette;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.pageHorizontal,
            0,
            8,
            4,
          ),
          child: Row(
            children: [
              Text(
                '所有任务',
                style: AppText.section.copyWith(color: palette.text),
              ),
              const SizedBox(width: 8),
              Text(
                '${state.total}',
                style: AppText.tabular(
                  AppText.caption.copyWith(color: palette.text2),
                ),
              ),
              // 数量和右边按钮区之间留出间距：按钮区放不下时会从左边裁掉半个字，
              // 紧贴着数字时看起来就像数量后面跟了个「字」（截图里的「10字」其实是被裁的「默认排序」）。
              const SizedBox(width: 12),
              // 这一行最多要摆四个按钮，360dp 的窄屏放不下 ——
              // 用横向滚动兜住，而不是让 Row 溢出。reverse 保证内容不足一屏时仍然靠右。
              Expanded(
                // 左缘 16dp 渐隐：被裁到的半截按钮淡出，而不是硬生生切出半个字。
                // 放得下时最左边是 TextButton 自带的约 12dp 内边距，渐隐几乎不碰到图标。
                child: ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (bounds) => LinearGradient(
                    colors: const [Colors.transparent, Colors.black],
                    stops: [
                      0,
                      bounds.width <= 0
                          ? 0
                          : (16 / bounds.width).clamp(0.0, 1.0),
                    ],
                  ).createShader(bounds),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    reverse: true,
                    child: Row(
                      children: [
                        // 快捷排序入口（APP #28）。不叫「排序」：「…」里的「拖拽排序」是另一回事。
                        TextButton.icon(
                          onPressed: _showQuickSortPicker,
                          icon: const Icon(Icons.sort, size: 16),
                          label: _buildFilterButtonLabel(
                            state.quickSort == null
                                ? '默认排序'
                                : '${_quickSortFieldLabels[state.quickSort!.field] ?? '自定义'} '
                                      '${state.quickSort!.isDescending ? '↓' : '↑'}',
                          ),
                        ),
                        if (_showViewFilterEntry(viewState, canManageViews))
                          TextButton.icon(
                            onPressed: _showViewPicker,
                            icon: const Icon(Icons.filter_alt_outlined, size: 16),
                            label: _buildFilterButtonLabel(
                              _selectedViewName(state, viewState) ?? '全部任务',
                            ),
                          ),
                        TextButton.icon(
                          onPressed: _showGroupPicker,
                          icon: const Icon(Icons.label_outline, size: 16),
                          label: _buildFilterButtonLabel(
                            state.labelFilter?.isNotEmpty == true
                                // 存的是完整标签 `分组:生产`，显示要去掉前缀。
                                ? Task.groupNameFromLabel(state.labelFilter!)
                                : '全部分组',
                          ),
                        ),
                        if (state.statusFilter != null ||
                            state.labelFilter != null ||
                            state.selectedViewId != null)
                          TextButton(
                            onPressed: _clearTaskFilters,
                            child: const Text('清除筛选'),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 38,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.pageHorizontal,
            ),
            scrollDirection: Axis.horizontal,
            itemCount: _taskStatusFilters.length,
            separatorBuilder: (_, index) => const SizedBox(width: 8),
            itemBuilder: (_, index) {
              final filter = _taskStatusFilters[index];
              final selected = state.statusFilter == filter.value;
              return ChoiceChip(
                label: Text(filter.label),
                selected: selected,
                showCheckmark: false,
                onSelected: (_) {
                  if (_scrollController.hasClients &&
                      _scrollController.offset > 0) {
                    _scrollController.jumpTo(0);
                  }
                  ref.read(taskProvider.notifier).setStatusFilter(filter.value);
                },
                // 白色胶囊，选中是强调色浅底；状态色当文字用 Ink 档
                backgroundColor: palette.card,
                selectedColor: palette.tint(palette.accent),
                side: BorderSide.none,
                shape: const StadiumBorder(),
                labelStyle: TextStyle(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? palette.accentInk : palette.text,
                ),
                visualDensity: VisualDensity.compact,
              );
            },
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(taskProvider);
    final viewState = ref.watch(taskViewProvider);
    final user = ref.watch(authProvider).user;
    // 任务视图的增删改要 operator，viewer 只能看。按住运行同样要 operator。
    final canManageViews = user?.isOperator ?? false;
    final canRun = user?.isOperator ?? false;
    final palette = context.palette;
    final favoriteNotifier = ref.read(favoriteTasksProvider.notifier);
    final watchedFavoriteIds = ref.watch(favoriteTasksProvider);
    // 刚切完面板、常用任务还没换成新面板那份时，先当作没有（同一个 id 在两台面板上是两条任务）
    final favoriteIds = favoriteNotifier.isCurrentScope
        ? watchedFavoriteIds
        : const <int>[];
    // 列表刷新成功、而且是没加筛选的全量时，顺手剔除已经被删掉的常用任务（组间契约：B1 负责 prune）。
    // 带筛选的结果不是全量，拿它剔除会把只是被筛掉的常用任务误删。
    ref.listen<TaskListState>(taskProvider, (previous, next) {
      if (previous == null || !previous.loading || next.loading) {
        return;
      }
      if (next.error != null || next.hasNarrowingFilters) {
        return;
      }
      favoriteNotifier.prune(next.tasks.map((task) => task.id).toSet());
    });
    _collectKnownGroups(state.tasks);
    final groupedTasks = sortTaskGroupsByOrder(
      groupTasksByGroupName(state.tasks),
      _groupOrder,
    );
    // 一个分组都没建过（或筛选后只剩「未分组」）时，那条分组头没有任何信息量：
    // 标题恒为「未分组」、条数与「所有任务」旁的总数重复、折叠它等于清空整页。
    // 这种情况直接不渲染。
    final onlyUngrouped =
        groupedTasks.length == 1 && groupedTasks.first.key.isEmpty;
    // 分组头 + 任务行摊平成一维行列表，交给下面的 ListView.builder 惰性构建。
    // 全量任务仍然留在 state.tasks 里，所以全选 / 分组下拉 / 拖拽排序语义不变。
    final taskRows = buildTaskListRows(
      groups: groupedTasks,
      collapsedGroups: _collapsedGroups,
      showGroupHeader: !onlyUngrouped,
    );
    final selectedCount = _selectedTaskIds.length;
    final allSelected = _isAllTasksSelected(state.tasks);
    // 排到帧末再试，不能在 build 体内直接调（那时 ScrollController 还没 attach）。
    // initState 里已经排过一次，这里是「列表分支从加载态换成真正的 ListView」之后的补触发。
    _scheduleScrollRestore();

    // 常用任务：优先用当前列表里的最新数据；列表带着筛选看不到时用最近一次见过的快照。
    favoriteNotifier.remember(state.tasks);
    final taskById = {for (final task in state.tasks) task.id: task};
    final favoriteTasks = <Task>[
      for (final id in favoriteIds)
        ?(taskById[id] ?? favoriteNotifier.snapshotOf(id)),
    ];
    final browsing = !_selectionMode && !_taskSortMode && !_groupReorderMode;
    // 搜索时用户关心的是搜索结果，常用卡片先让开
    final showFavorites = browsing && state.keyword.isEmpty;
    final showSearch =
        _searchOpen ||
        _searchController.text.isNotEmpty ||
        state.keyword.isNotEmpty;
    final listBottom = AppSpacing.listBottomOf(context);

    // 页头：问候 + 一句状态
    final userName = user?.username.trim() ?? '';
    final title = userName.isEmpty ? '任务' : 'Hi, $userName!';
    final String subtitle;
    if (_selectionMode) {
      subtitle = '已选 $selectedCount 个任务';
    } else if (_taskSortMode) {
      subtitle = '拖拽排序中';
    } else if (state.loading && state.tasks.isEmpty) {
      subtitle = '正在加载任务…';
    } else {
      final runningCount = state.tasks.where((task) => task.isRunning).length;
      final failedCount = state.tasks
          .where((task) => task.lastRunFailed)
          .length;
      subtitle = [
        '${state.total} 个任务',
        if (runningCount > 0) '$runningCount 个运行中',
        // 「失败」指上次运行失败（last_run_status == 1），页头放不下更长的说法
        if (failedCount > 0) '$failedCount 个失败',
      ].join(' · ');
    }
    final List<Widget> headerActions;
    if (_selectionMode) {
      headerActions = [
        AppPillButton(
          label: '取消',
          icon: Icons.close_rounded,
          variant: AppPillVariant.secondary,
          height: 44,
          onPressed: () => _setSelectionMode(false),
        ),
      ];
    } else if (_taskSortMode) {
      headerActions = [
        // 每次松手已经各自保存过了（见 _buildTaskReorderView），「完成」只是退出排序模式。
        AppPillButton(
          label: '完成',
          icon: Icons.check_rounded,
          height: 44,
          onPressed: _toggleTaskSortMode,
        ),
      ];
    } else {
      headerActions = [
        AppGlassCircleButton(
          icon: Icons.search_rounded,
          tooltip: '搜索任务',
          onTap: _toggleSearch,
        ),
        AppGlassCircleButton(
          icon: Icons.more_horiz_rounded,
          tooltip: '更多操作',
          onTap: _showMoreActions,
        ),
        AppGlassCircleButton(
          icon: Icons.add_rounded,
          tooltip: '新建任务',
          onTap: () => context.push('/tasks/new'),
        ),
      ];
    }

    final filterBar = _buildFilterBar(state, viewState, canManageViews);
    // 正常浏览时排在任务行前面、跟着一起滚的几块
    final leading = <Widget>[
      if (showFavorites)
        Padding(
          padding: const EdgeInsets.only(bottom: 26),
          child: FavoriteTaskSection(
            tasks: favoriteTasks,
            favoriteCount: favoriteIds.length,
            canRun: canRun,
            now: _now,
            onRun: _runTask,
            onOpen: (task) => showTaskDetailSheet(context, ref, task),
            onViewLog: (task) => openLatestTaskLog(context, ref, task),
          ),
        ),
      if (browsing) filterBar,
    ];

    return Scaffold(
      body: Padding(
        padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 12),
        child: Column(
          children: [
            AppLargeTitleHeader(
              title: title,
              subtitle: subtitle,
              actions: headerActions,
            ),
            if (showSearch)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.pageHorizontal,
                  0,
                  AppSpacing.pageHorizontal,
                  12,
                ),
                // 灰色填充、无描边的输入框样式由全局主题给（第一波），这里不再逐字抄边框
                child: TextField(
                  controller: _searchController,
                  focusNode: _searchFocus,
                  decoration: InputDecoration(
                    hintText: '搜索任务名称或命令...',
                    prefixIcon: Icon(
                      Icons.search,
                      size: 18,
                      color: palette.text3,
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    isDense: true,
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: Icon(
                              Icons.clear,
                              size: 16,
                              color: palette.text3,
                            ),
                            onPressed: () {
                              _searchController.clear();
                              setState(() {});
                              ref.read(taskProvider.notifier).setKeyword('');
                            },
                          )
                        : null,
                  ),
                  style: const TextStyle(fontSize: 14),
                  onChanged: _onSearchChanged,
                ),
              ),
            if (!browsing) filterBar,
            if (_selectionMode) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      AppTintedActionButton(
                        label: allSelected ? '取消全选' : '全选',
                        icon: allSelected ? Icons.deselect : Icons.select_all,
                        color: palette.text2,
                        enabled: state.tasks.isNotEmpty,
                        onTap: () => _toggleSelectAllTasks(state.tasks),
                      ),
                      const SizedBox(width: 8),
                      AppTintedActionButton(
                        label: '批量运行',
                        icon: Icons.play_circle_outline,
                        color: palette.accent,
                        enabled: selectedCount > 0,
                        onTap: () =>
                            _performBatchTaskAction(_TaskBatchAction.run),
                      ),
                      const SizedBox(width: 8),
                      AppTintedActionButton(
                        label: '批量启用',
                        icon: Icons.toggle_on_outlined,
                        // 「启用」是成功绿，和左边「批量运行」的蓝区分开。
                        color: palette.ok,
                        enabled: selectedCount > 0,
                        onTap: () =>
                            _performBatchTaskAction(_TaskBatchAction.enable),
                      ),
                      const SizedBox(width: 8),
                      AppTintedActionButton(
                        label: '批量禁用',
                        icon: Icons.toggle_off_outlined,
                        color: palette.text2,
                        enabled: selectedCount > 0,
                        onTap: () =>
                            _performBatchTaskAction(_TaskBatchAction.disable),
                      ),
                      const SizedBox(width: 8),
                      // 放在「批量删除」前面：删除是红色的破坏性动作，保持在最右。
                      AppTintedActionButton(
                        label: '通知设置',
                        icon: Icons.notifications_outlined,
                        color: palette.purple,
                        enabled: selectedCount > 0,
                        onTap: _performBatchNotify,
                      ),
                      const SizedBox(width: 8),
                      AppTintedActionButton(
                        label: '批量删除',
                        icon: Icons.delete_outline,
                        color: palette.err,
                        enabled: selectedCount > 0,
                        onTap: () =>
                            _performBatchTaskAction(_TaskBatchAction.delete),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (_taskSortMode) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: AppNotice(
                  color: palette.accent,
                  icon: Icons.swap_vert,
                  text: '长按拖拽调整任务顺序，松手即保存',
                  accentText: true,
                ),
              ),
            ],
            Expanded(
              child: RefreshIndicator(
                color: palette.accent,
                onRefresh: () =>
                    ref.read(taskProvider.notifier).load(refresh: true),
                // 加载 / 失败 / 空态也把筛选条带上：筛出空结果时用户得能切回去。
                child: state.loading && state.tasks.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          if (browsing) filterBar,
                          const AppLoadingView(),
                        ],
                      )
                    // 拿不到数据和真的没有任务是两回事，必须先判 error。
                    : state.error != null && state.tasks.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          if (browsing) filterBar,
                          AppErrorView(
                            title: '任务加载失败',
                            message: state.error!,
                            onRetry: () =>
                                ref.read(taskProvider.notifier).load(
                                  refresh: true,
                                ),
                          ),
                        ],
                      )
                    : state.tasks.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          if (browsing) filterBar,
                          const AppEmptyView(
                            icon: Icons.inbox_outlined,
                            message: '暂无任务',
                            topPadding: 0,
                          ),
                        ],
                      )
                    : _taskSortMode
                    ? _buildTaskReorderView(state.tasks)
                    : _groupReorderMode
                    ? _buildGroupReorderView(groupedTasks)
                    // 按摊平后的行 index 构建，只有可见区域会被真正建出来。
                    // 前面几项是常用任务与筛选条，后面才是任务行。
                    : ListView.builder(
                        controller: _scrollController,
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: EdgeInsets.only(bottom: listBottom),
                        itemCount: leading.length + taskRows.length,
                        itemBuilder: (context, index) {
                          if (index < leading.length) {
                            return leading[index];
                          }
                          final rowIndex = index - leading.length;
                          final row = taskRows[rowIndex];
                          if (row.isGroupHeader) {
                            return _buildGroupHeader(
                              row.group,
                              key: ValueKey(row.rowKey),
                            );
                          }
                          // 同一分组的任务行拼成一块白色圆角容器：首行圆上角、末行圆下角
                          final prev = rowIndex > 0
                              ? taskRows[rowIndex - 1]
                              : null;
                          final next = rowIndex + 1 < taskRows.length
                              ? taskRows[rowIndex + 1]
                              : null;
                          return _buildTaskCard(
                            row.task!,
                            isFirst:
                                prev == null ||
                                prev.isGroupHeader ||
                                prev.group.key != row.group.key,
                            isLast:
                                next == null ||
                                next.isGroupHeader ||
                                next.group.key != row.group.key,
                            isFavorite: favoriteIds.contains(row.task!.id),
                            key: ValueKey(row.rowKey),
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

  Future<void> _renameGroup(String oldName, List<Task> tasks) async {
    final controller = TextEditingController(text: oldName);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名分组'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '分组名称',
            hintText: '输入新的分组名称',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newName == null || newName.isEmpty || newName == oldName) return;
    try {
      await ref
          .read(taskProvider.notifier)
          .batchUpdateGroupLabel(
            tasks: tasks,
            oldGroupName: oldName,
            newGroupName: newName,
          );
      if (mounted) {
        _showSuccess('已将分组 "$oldName" 重命名为 "$newName"');
      }
    } catch (error) {
      if (mounted) {
        await _showActionError(error, '重命名分组失败');
      }
    }
  }

  Future<void> _deleteGroup(String groupName, List<Task> tasks) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除分组'),
        content: Text('确定将 "$groupName" 分组中的 ${tasks.length} 个任务移回未分组？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('确定', style: TextStyle(color: ctx.palette.errInk)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref
          .read(taskProvider.notifier)
          .batchUpdateGroupLabel(
            tasks: tasks,
            oldGroupName: groupName,
            newGroupName: null,
          );
      if (mounted) {
        _showSuccess('已删除分组 "$groupName"');
      }
    } catch (error) {
      if (mounted) {
        await _showActionError(error, '删除分组失败');
      }
    }
  }

  Future<void> _addTasksToGroup(
    String targetGroup,
    List<Task> ungroupedTasks,
  ) async {
    if (ungroupedTasks.isEmpty) {
      // 「没有可添加的」既不是成功也不是失败，只是没什么可干，保持中性。
      _showMessage('没有未分组的任务可添加');
      return;
    }
    final selected = <int>{};
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('添加任务到 "$targetGroup"'),
          content: SizedBox(
            width: double.maxFinite,
            height: 400,
            child: ListView.builder(
              itemCount: ungroupedTasks.length,
              itemBuilder: (ctx, i) {
                final task = ungroupedTasks[i];
                return CheckboxListTile(
                  value: selected.contains(task.id),
                  title: Text(task.name, style: const TextStyle(fontSize: 14)),
                  dense: true,
                  onChanged: (v) {
                    setDialogState(() {
                      if (v == true) {
                        selected.add(task.id);
                      } else {
                        selected.remove(task.id);
                      }
                    });
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                if (selected.isEmpty) return;
                final tasksToMove = ungroupedTasks
                    .where((t) => selected.contains(t.id))
                    .toList();
                try {
                  await ref
                      .read(taskProvider.notifier)
                      .batchUpdateGroupLabel(
                        tasks: tasksToMove,
                        oldGroupName: null,
                        newGroupName: targetGroup,
                      );
                  if (mounted) {
                    _showSuccess(
                      '已将 ${tasksToMove.length} 个任务添加到 "$targetGroup"',
                    );
                  }
                } catch (error) {
                  if (mounted) {
                    await _showActionError(error, '添加任务到分组失败');
                  }
                }
              },
              child: Text('添加 (${selected.length})'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showCreateGroupFromUngrouped(List<Task> ungroupedTasks) async {
    final nameController = TextEditingController();
    final selected = <int>{};
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('新建分组'),
          content: SizedBox(
            width: double.maxFinite,
            height: 450,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '分组名称',
                    hintText: '输入新分组的名称',
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  '选择要加入的任务:',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    itemCount: ungroupedTasks.length,
                    itemBuilder: (ctx, i) {
                      final task = ungroupedTasks[i];
                      return CheckboxListTile(
                        value: selected.contains(task.id),
                        title: Text(
                          task.name,
                          style: const TextStyle(fontSize: 14),
                        ),
                        dense: true,
                        onChanged: (v) {
                          setDialogState(() {
                            if (v == true) {
                              selected.add(task.id);
                            } else {
                              selected.remove(task.id);
                            }
                          });
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () async {
                final groupName = nameController.text.trim();
                Navigator.pop(ctx);
                if (groupName.isEmpty || selected.isEmpty) return;
                final tasksToMove = ungroupedTasks
                    .where((t) => selected.contains(t.id))
                    .toList();
                try {
                  await ref
                      .read(taskProvider.notifier)
                      .batchUpdateGroupLabel(
                        tasks: tasksToMove,
                        oldGroupName: null,
                        newGroupName: groupName,
                      );
                  if (mounted) {
                    _showSuccess(
                      '已创建分组 "$groupName" 并添加 ${tasksToMove.length} 个任务',
                    );
                  }
                } catch (error) {
                  if (mounted) {
                    await _showActionError(error, '创建分组失败');
                  }
                }
              },
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
    nameController.dispose();
  }

  Widget _buildGroupReorderView(List<TaskGroup> groups) {
    final palette = context.palette;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.swap_vert, size: 18, color: palette.text2),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '长按拖拽调整分组顺序',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: palette.text,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => setState(() => _groupReorderMode = false),
                child: const Text('完成'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ReorderableListView.builder(
            padding: EdgeInsets.fromLTRB(
              20,
              0,
              20,
              AppSpacing.listBottomOf(context),
            ),
            itemCount: groups.length,
            onReorder: (oldIndex, newIndex) {
              setState(() {
                if (newIndex > oldIndex) newIndex--;
                final item = groups.removeAt(oldIndex);
                groups.insert(newIndex, item);
                _groupOrder = groups.map((g) => g.key).toList();
              });
              _persistGroupOrder();
            },
            itemBuilder: (ctx, i) {
              final group = groups[i];
              // ⚠️ key 必须挂在 ReorderableListView 的直接子 widget 上（这里就是
              // AppCard 自己），挂到它的 child 上会在拖拽时抛
              // 「Every item of ReorderableListView must have a key」。
              return AppCard(
                key: ValueKey(group.key),
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    Icon(Icons.drag_handle, size: 20, color: palette.text3),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        group.title,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: palette.text,
                        ),
                      ),
                    ),
                    Text(
                      '${group.tasks.length} 条',
                      style: TextStyle(fontSize: 12, color: palette.text2),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildTaskReorderView(List<Task> tasks) {
    final palette = context.palette;
    return ReorderableListView.builder(
      padding: EdgeInsets.fromLTRB(20, 0, 20, AppSpacing.listBottomOf(context)),
      itemCount: tasks.length,
      onReorder: (oldIndex, newIndex) async {
        // 松手即保存，一次拖拽只发一次 PUT /tasks/sort（面板按落点把整桶重编号）。
        // 不再攒到「完成」时逐条提交：那样 N 条任务要发 N 个请求，而且写的是开机顺序 sort_order。
        // 失败时 provider 已按服务端顺序把列表弹回去，这里只负责把原因（跨区提示 / 请升级）说出来。
        // 进排序模式时拦过一次，但排序模式里列表还会刷新（每次松手后、下拉刷新、切状态筛选），
        // 刷出运行中的任务后就得在这里再拦；不调 moveTask，被拖的那条自然弹回原位。
        final reason = ref.read(taskProvider).dragSortDisabledReason;
        if (reason != null) {
          _showWarning(reason);
          return;
        }
        try {
          await ref.read(taskProvider.notifier).moveTask(oldIndex, newIndex);
        } catch (error) {
          await _showActionError(error, '保存任务排序失败');
        }
      },
      itemBuilder: (context, index) {
        final task = tasks[index];
        // ⚠️ key 必须挂在 ReorderableListView 的直接子 widget 上（这里就是
        // AppCard 自己），挂到它的 child 上会在拖拽时抛
        // 「Every item of ReorderableListView must have a key」。
        return AppCard(
          key: ValueKey('task-sort-${task.id}'),
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              Icon(Icons.drag_handle, size: 20, color: palette.text3),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.name,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: palette.text,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      task.groupName?.isNotEmpty == true
                          ? '分组：${task.groupName}'
                          : '未分组',
                      style: TextStyle(fontSize: 11, color: palette.text2),
                    ),
                  ],
                ),
              ),
              // 不认识的状态按「非活跃」渲染：只改文案不改高亮的话，面板新增的状态
              // 在排序视图里仍会亮成一个活跃态徽章，而我们并不知道它到底是不是活跃的。
              _MetaChip(
                label: task.statusText,
                active: task.hasKnownStatus && !task.isDisabled,
              ),
            ],
          ),
        );
      },
    );
  }

  /// 可折叠的分组头：分组列表上方的小标题行（不再是一张卡）。
  ///
  /// 只有 `buildTaskListRows` 产出分组头行时才会被调用：只剩「未分组」一个桶时
  /// 整张列表不画分组头（那条信息与「所有任务」旁的总数重复，折叠它等于清空整页）。
  /// 点一下折叠 / 展开，长按进分组排序。
  Widget _buildGroupHeader(TaskGroup group, {Key? key}) {
    final palette = context.palette;
    final collapsed = _collapsedGroups.contains(group.key);
    final enabledCount = group.tasks.where((task) => task.isEnabled).length;
    final runningCount = group.tasks.where((task) => task.isRunning).length;
    final isUngrouped = group.key.isEmpty;

    return Padding(
      key: key,
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: () {
            setState(() {
              if (collapsed) {
                _collapsedGroups.remove(group.key);
              } else {
                _collapsedGroups.add(group.key);
              }
            });
            _persistCollapsedGroups();
          },
          onLongPress: () {
            HapticFeedback.mediumImpact();
            setState(() => _groupReorderMode = true);
          },
          child: ConstrainedBox(
            // 整条分组头就是它自己的点击区，不低于 44dp
            constraints: const BoxConstraints(minHeight: AppTapTarget.min),
            child: Row(
              children: [
                const SizedBox(width: 4),
                Icon(
                  collapsed
                      ? Icons.chevron_right_rounded
                      : Icons.expand_more_rounded,
                  size: 20,
                  color: palette.text3,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    group.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.body.copyWith(
                      fontWeight: FontWeight.w700,
                      color: palette.text,
                    ),
                  ),
                ),
                Text(
                  '${group.tasks.length} 条',
                  style: AppText.tabular(
                    AppText.caption.copyWith(color: palette.text2),
                  ),
                ),
                const SizedBox(width: 8),
                if (runningCount > 0)
                  _MetaChip(label: '$runningCount 运行中', active: true)
                else
                  _MetaChip(
                    label: '$enabledCount 已启用',
                    active: enabledCount > 0,
                  ),
                _GroupPopupMenu(
                  isUngrouped: isUngrouped,
                  onRename: isUngrouped
                      ? null
                      : () => _renameGroup(group.key, group.tasks),
                  onDelete: isUngrouped
                      ? null
                      : () => _deleteGroup(group.key, group.tasks),
                  onAddTasks: () {
                    final allTasks = ref.read(taskProvider).tasks;
                    final ungrouped = allTasks
                        .where((t) => (t.groupName ?? '').isEmpty)
                        .toList();
                    final targetGroup = isUngrouped ? null : group.key;
                    if (targetGroup == null) {
                      _showCreateGroupFromUngrouped(ungrouped);
                    } else {
                      _addTasksToGroup(targetGroup, ungrouped);
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 单个任务行。[key] 由摊平行的 `rowKey` 提供（`task-card-<id>`），
  /// 虚拟化后 Element 会被回收复用，没有这个 key 侧滑展开状态会串到别的任务上。
  Widget _buildTaskCard(
    Task task, {
    required bool isFirst,
    required bool isLast,
    required bool isFavorite,
    Key? key,
  }) {
    return _TaskCard(
      key: key,
      task: task,
      isFirst: isFirst,
      isLast: isLast,
      isFavorite: isFavorite,
      now: _now,
      selectionMode: _selectionMode,
      selected: _selectedTaskIds.contains(task.id),
      // 非多选模式下点任务行打开详情弹层（v2.0；之前是进详情页，issue #20）
      onTap: () => _selectionMode
          ? _toggleTaskSelection(task.id)
          : showTaskDetailSheet(context, ref, task),
      // 多选模式下长按照旧是勾选；平时长按出菜单（加入 / 移出常用、多选）
      onLongPress: () {
        if (_selectionMode) {
          HapticFeedback.mediumImpact();
          _toggleTaskSelection(task.id);
          return;
        }
        _showTaskActions(task);
      },
      onSelectedChanged: () => _toggleTaskSelection(task.id),
      onStop: () => _stopTask(task),
      onToggleEnabled: () => _toggleTaskEnabled(task),
      onCopy: () => _copyTask(task),
      onTogglePinned: () => _togglePinned(task),
      onEdit: () => context.push('/tasks/edit', extra: task),
      onDelete: () => _confirmDelete(task),
      onViewLog: () => openLatestTaskLog(context, ref, task),
    );
  }

  Future<void> _confirmDelete(Task task) async {
    await confirmAndDeleteTask(context, ref, task);
  }
}

/// 删除任务：确认弹窗（可勾选同时删除关联脚本）→ 删除 → 提示。
/// 列表侧滑和任务详情页（issue #20）共用这一份；返回是否真的删掉了任务，详情页据此返回列表。
Future<bool> confirmAndDeleteTask(
  BuildContext context,
  WidgetRef ref,
  Task task,
) async {
  final scriptPath = extractScriptPathFromCommand(task.command);
  var deleteScript = false;
  final confirm = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('删除任务'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('确定要删除「${task.name}」吗？'),
            if (scriptPath != null) ...[
              const SizedBox(height: 14),
              CheckboxListTile(
                value: deleteScript,
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('同时删除关联脚本'),
                subtitle: Text(scriptPath),
                onChanged: (value) {
                  setDialogState(() => deleteScript = value ?? false);
                },
              ),
            ],
          ],
        ),
        actions: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: const Text('取消'),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(dialogContext, true),
                    style: FilledButton.styleFrom(
                      backgroundColor: dialogContext.palette.err,
                      foregroundColor: dialogContext.palette.onStatus,
                    ),
                    child: const Text('删除'),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
  if (confirm != true || !context.mounted) {
    return false;
  }
  try {
    await ref.read(taskProvider.notifier).deleteTask(task.id);
    if (deleteScript && scriptPath != null) {
      try {
        await DioClient.instance.dio.delete(
          ApiEndpoints.scripts,
          queryParameters: {'path': scriptPath, 'type': 'file'},
        );
        if (context.mounted) AppSnack.success(context, '任务和关联脚本已删除');
      } catch (error) {
        // 部分成功：任务删掉了、脚本没删掉。既不能报绿也不能报红。
        if (context.mounted) {
          AppSnack.warn(
            context,
            '任务已删除，但脚本删除失败：${extractErrorMessage(error, '请稍后手动删除脚本')}',
          );
        }
      }
      return true;
    }
    if (context.mounted) AppSnack.success(context, '任务已删除');
    return true;
  } catch (error) {
    if (context.mounted) {
      AppSnack.error(context, _extractTaskError(error, '删除任务失败'));
    }
    return false;
  }
}

/// 打开任务日志：运行中开实时日志，否则打开最近一次日志。
/// v1.4.2 起点卡片改进详情页（issue #20），看日志要多点一层；APP #22 评论要求在
/// 列表左滑里补一个「日志」，和详情页的「最新日志」行共用这一份，两处行为不会走样。
Future<void> openLatestTaskLog(
  BuildContext context,
  WidgetRef ref,
  Task task,
) async {
  if (task.isRunning) {
    context.push('/tasks/${task.id}/live-logs', extra: task.name);
    return;
  }
  try {
    final latestLog = await ref
        .read(taskProvider.notifier)
        .fetchLatestLog(task.id);
    if (!context.mounted) return;
    if (latestLog == null) {
      AppSnack.show(context, '当前任务暂无日志');
      return;
    }
    context.push('/logs/${latestLog.id}/stream');
  } catch (_) {
    if (context.mounted) AppSnack.error(context, '打开日志失败');
  }
}

class _TaskCard extends StatefulWidget {
  final Task task;

  /// 在所属分组里是不是第一行 / 最后一行：决定圆角画在哪、要不要顶部分隔线。
  final bool isFirst;
  final bool isLast;
  final bool isFavorite;
  final ValueListenable<DateTime> now;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onSelectedChanged;
  final VoidCallback onStop;
  final VoidCallback onToggleEnabled;
  final VoidCallback onCopy;
  final VoidCallback onTogglePinned;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onViewLog;

  const _TaskCard({
    super.key,
    required this.task,
    required this.isFirst,
    required this.isLast,
    required this.isFavorite,
    required this.now,
    required this.selectionMode,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onSelectedChanged,
    required this.onStop,
    required this.onToggleEnabled,
    required this.onCopy,
    required this.onTogglePinned,
    required this.onEdit,
    required this.onDelete,
    required this.onViewLog,
  });

  @override
  State<_TaskCard> createState() => _TaskCardState();
}

/// 「所有任务」里的一行（v2.0 分组列表样式）：状态色块 + 名称 / 定时与分组 + 右侧下次运行倒计时。
///
/// 同一分组的行首尾相接拼成一块白色圆角容器（首行圆上角、末行圆下角、行间缩进分隔线），
/// 左滑露出 6 个次要操作，这部分手势逻辑与改版前一致。
/// 改版前每行都有「运行」按钮，口袋里容易误触（方案书现状问题 4），现在运行走详情弹层或常用卡片的「按住运行」；
/// 运行中的任务仍保留一个「停止」。
class _TaskCardState extends State<_TaskCard> {
  // 左滑按钮的宽度上限（宽屏时的原尺寸）。
  static const double _actionMaxWidth = 52;
  static const double _actionGap = 6;
  static const int _actionCount = 6;

  /// 左滑全部展开后，卡片左侧至少还要露出来的宽度：一点都不露，用户看不出这是哪张卡、也没处点「收起」。
  static const double _cardPeekWidth = 16;

  /// 行内边距、前导色块与文字的间距：分隔线缩进按它们算（同 AppGroupedRow）。
  static const double _hPad = 18;
  static const double _gap = 14;
  static const double _tileSize = 36;

  double _dragOffset = 0;
  bool _dragging = false;

  Task get task => widget.task;

  @override
  void didUpdateWidget(covariant _TaskCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectionMode || oldWidget.task.id != widget.task.id) {
      _dragOffset = 0;
      _dragging = false;
    }
  }

  /// 副标题：定时规则（或任务类型）· 分组 / 标签。
  String _subtitle() {
    final String schedule;
    if (task.taskType == 'cron') {
      final expressions = task.cronExpressions.isNotEmpty
          ? task.cronExpressions
          : [
              if (task.cronExpression.trim().isNotEmpty)
                task.cronExpression.trim(),
            ];
      schedule = expressions.isEmpty
          ? '暂无定时规则'
          : expressions.length > 1
          ? '${expressions.first} 等 ${expressions.length} 条'
          : expressions.first;
    } else {
      schedule = task.taskType == 'manual' ? '手动触发' : '面板启动时执行';
    }
    final labels = task.userLabelsForDisplay;
    final where = task.groupName?.isNotEmpty == true
        ? task.groupName!
        : labels.take(2).join('、');
    return where.isEmpty ? schedule : '$schedule · $where';
  }

  void _closeActions() {
    if (_dragOffset == 0) {
      return;
    }
    setState(() => _dragOffset = 0);
  }

  void _runSwipeAction(VoidCallback action) {
    _closeActions();
    action();
  }

  /// 右侧：运行中 → 「运行中」+ 停止；有下次运行 → 倒计时 + 几点运行；其余 → 类型 / 状态。
  Widget _buildTrailing(AppPalette palette) {
    final valueStyle = AppText.tabular(
      TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: palette.text),
    );
    final captionStyle = TextStyle(fontSize: 12, color: palette.text2);
    if (task.isRunning) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '运行中',
            style: valueStyle.copyWith(color: palette.accentInk, fontSize: 14),
          ),
          if (!widget.selectionMode) ...[
            const SizedBox(height: 4),
            _TaskPrimaryActionButton(
              label: '停止',
              icon: Icons.stop_rounded,
              color: palette.err,
              onTap: widget.onStop,
            ),
          ],
        ],
      );
    }
    final next = task.nextRunAt;
    if (next != null && task.isSwitchOn) {
      final local = next.toLocal();
      final today = DateTime.now();
      String pad2(int v) => v.toString().padLeft(2, '0');
      final sameDay =
          local.year == today.year &&
          local.month == today.month &&
          local.day == today.day;
      final at = sameDay
          ? '${pad2(local.hour)}:${pad2(local.minute)} 运行'
          : '${local.month}月${local.day}日 ${pad2(local.hour)}:${pad2(local.minute)}';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          TaskCountdownText(next: next, now: widget.now, style: valueStyle),
          Text(at, style: AppText.tabular(captionStyle)),
        ],
      );
    }
    final String value;
    if (task.taskType == 'manual') {
      value = '手动';
    } else if (task.taskType == 'startup') {
      value = '启动时';
    } else {
      value = '—';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value, style: valueStyle),
        Text(
          task.statusText,
          style: captionStyle.copyWith(
            color: task.isQueued ? palette.warnInk : palette.text2,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final (statusIcon, statusColor) = taskStatusVisual(task, palette);
    const radius = Radius.circular(AppRadius.card);
    final borderRadius = BorderRadius.vertical(
      top: widget.isFirst ? radius : Radius.zero,
      bottom: widget.isLast ? radius : Radius.zero,
    );
    // 选中态：在卡片底色上叠一层强调色浅底（叠成不透明色，左滑按钮不会透出来）
    final rowColor = widget.selected
        ? Color.alphaBlend(palette.tint(palette.accent), palette.card)
        : palette.card;
    final textStart =
        _hPad + (widget.selectionMode ? 24 + 10 : 0) + _tileSize + _gap;

    return PopScope(
      canPop: _dragOffset == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _dragOffset == 0) {
          return;
        }
        // 侧滑按钮展开时，系统返回先收起按钮，避免用户回滑时误退出 APP。
        _closeActions();
      },
      child: Container(
        // 同一分组的行首尾相接；一组结束后与下一个分组头隔开
        margin: EdgeInsets.fromLTRB(
          AppSpacing.pageHorizontal,
          0,
          AppSpacing.pageHorizontal,
          widget.isLast ? 18 : 0,
        ),
        child: ClipRRect(
          borderRadius: borderRadius,
          child: ColoredBox(
            color: palette.card,
            child: LayoutBuilder(
              builder: (context, constraints) {
                // APP #22 评论：左滑 6 个按钮在 360dp 屏（行宽约 320dp）上要放得下。
                // 按行实际宽度均分：宽屏仍是 52，窄屏收窄但不低于 44dp 命中区；
                // 拖动上限、吸附阈值都用这同一个总宽，展开距离与按钮总宽始终一致。
                final actionWidth =
                    ((constraints.maxWidth -
                                8 -
                                _actionGap * (_actionCount - 1) -
                                _cardPeekWidth) /
                            _actionCount)
                        .clamp(AppTapTarget.min, _actionMaxWidth)
                        .toDouble();
                final actionsWidth =
                    actionWidth * _actionCount +
                    _actionGap * (_actionCount - 1) +
                    8;
                // 转屏 / 分屏后总宽可能变小，已展开的偏移不能超出新的总宽。
                final dragOffset = _dragOffset
                    .clamp(-actionsWidth, 0.0)
                    .toDouble();
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _TaskSwipeActionButton(
                                // APP #22 评论：看日志的直达入口。
                                label: '日志',
                                icon: Icons.receipt_long_outlined,
                                color: palette.purple,
                                width: actionWidth,
                                onTap: () =>
                                    _runSwipeAction(widget.onViewLog),
                              ),
                              const SizedBox(width: _actionGap),
                              _TaskSwipeActionButton(
                                // 开关位一律看 isSwitchOn，不看 status：禁用任务被手动运行时
                                // status 是 0.5 / 2，按 isDisabled 判会把它说成开着、按钮写
                                // 「禁用」（面板 #133 同款）。文案 / 图标 / 颜色三处同一个判断。
                                label: task.switchActionLabel,
                                icon: task.isSwitchOn
                                    ? Icons.pause_circle_outline
                                    : Icons.play_circle_outline,
                                // 「启用」是切到已启用态，用成功绿，与行首色块的「已启用」同色。
                                color: task.isSwitchOn
                                    ? palette.text2
                                    : palette.ok,
                                width: actionWidth,
                                onTap: () =>
                                    _runSwipeAction(widget.onToggleEnabled),
                              ),
                              const SizedBox(width: _actionGap),
                              _TaskSwipeActionButton(
                                label: task.isPinned ? '取消' : '置顶',
                                icon: task.isPinned
                                    ? Icons.push_pin_outlined
                                    : Icons.push_pin,
                                color: palette.warn,
                                width: actionWidth,
                                onTap: () =>
                                    _runSwipeAction(widget.onTogglePinned),
                              ),
                              const SizedBox(width: _actionGap),
                              _TaskSwipeActionButton(
                                label: '复制',
                                icon: Icons.copy_outlined,
                                color: palette.accent,
                                width: actionWidth,
                                onTap: () => _runSwipeAction(widget.onCopy),
                              ),
                              const SizedBox(width: _actionGap),
                              _TaskSwipeActionButton(
                                label: '编辑',
                                icon: Icons.edit_outlined,
                                color: palette.text2,
                                width: actionWidth,
                                onTap: () => _runSwipeAction(widget.onEdit),
                              ),
                              const SizedBox(width: _actionGap),
                              _TaskSwipeActionButton(
                                label: '删除',
                                icon: Icons.delete_outline,
                                color: palette.err,
                                width: actionWidth,
                                onTap: () => _runSwipeAction(widget.onDelete),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: () {
                        if (_dragOffset != 0) {
                          _closeActions();
                          return;
                        }
                        widget.onTap();
                      },
                      onLongPress: widget.onLongPress,
                      onHorizontalDragStart: widget.selectionMode
                          ? null
                          : (_) => setState(() => _dragging = true),
                      onHorizontalDragUpdate: widget.selectionMode
                          ? null
                          : (details) {
                              // 左滑露出右侧次要操作；关闭时也限制在行内处理，避免和系统返回手势抢动作。
                              final nextOffset =
                                  (_dragOffset + details.delta.dx)
                                      .clamp(-actionsWidth, 0.0)
                                      .toDouble();
                              if (nextOffset == _dragOffset) {
                                return;
                              }
                              setState(() => _dragOffset = nextOffset);
                            },
                      onHorizontalDragCancel: widget.selectionMode
                          ? null
                          : () => setState(() => _dragging = false),
                      onHorizontalDragEnd: widget.selectionMode
                          ? null
                          : (_) {
                              final nextOffset =
                                  _dragOffset.abs() > actionsWidth * 0.42
                                  ? -actionsWidth
                                  : 0.0;
                              setState(() {
                                _dragging = false;
                                _dragOffset = nextOffset;
                              });
                              if (nextOffset == -actionsWidth) {
                                HapticFeedback.selectionClick();
                              }
                            },
                      child: AnimatedContainer(
                        duration: _dragging
                            ? Duration.zero
                            : AppMotion.of(
                                context,
                                const Duration(milliseconds: 160),
                              ),
                        curve: Curves.easeOutCubic,
                        transform: Matrix4.translationValues(dragOffset, 0, 0),
                        decoration: BoxDecoration(
                          color: rowColor,
                          // 左滑出去的那一段露出右侧圆角，和按钮区分开
                          borderRadius: dragOffset < 0
                              ? BorderRadius.circular(AppRadius.md)
                              : null,
                        ),
                        child: CustomPaint(
                          // 顶部分隔线：分组首行不画；从文字起点画到最右边（iOS 的缩进分隔线）
                          foregroundPainter: widget.isFirst
                              ? null
                              : _RowSeparatorPainter(
                                  color: palette.separator,
                                  start: textStart,
                                ),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 64),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: _hPad,
                                vertical: 12,
                              ),
                              child: Row(
                                children: [
                                  if (widget.selectionMode) ...[
                                    SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: Checkbox(
                                        value: widget.selected,
                                        onChanged: (_) =>
                                            widget.onSelectedChanged(),
                                        activeColor: palette.accent,
                                        visualDensity: VisualDensity.compact,
                                        materialTapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                  ],
                                  AppIconTile(
                                    icon: statusIcon,
                                    color: statusColor,
                                    size: _tileSize,
                                  ),
                                  const SizedBox(width: _gap),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Row(
                                          children: [
                                            Flexible(
                                              child: Text(
                                                task.name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: AppText.body.copyWith(
                                                  fontWeight: FontWeight.w600,
                                                  color: palette.text,
                                                ),
                                              ),
                                            ),
                                            if (task.isPinned)
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                  left: 4,
                                                ),
                                                child: Icon(
                                                  Icons.push_pin,
                                                  size: 14,
                                                  color: palette.warn,
                                                ),
                                              ),
                                            if (widget.isFavorite)
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                  left: 4,
                                                ),
                                                child: Icon(
                                                  Icons.star_rounded,
                                                  size: 15,
                                                  color: palette.warn,
                                                ),
                                              ),
                                          ],
                                        ),
                                        const SizedBox(height: 2),
                                        Text.rich(
                                          TextSpan(
                                            text: _subtitle(),
                                            children: [
                                              // 只有 last_run_status == 1 才是失败；2 是用户主动终止，不标红
                                              if (task.lastRunFailed &&
                                                  !task.isRunning)
                                                TextSpan(
                                                  text: ' · 上次失败',
                                                  style: TextStyle(
                                                    color: palette.errInk,
                                                  ),
                                                ),
                                            ],
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: AppText.caption.copyWith(
                                            color: palette.text2,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  _buildTrailing(palette),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// 任务行顶部的缩进分隔线（同 AppGroupedRow 的画法；那个画笔是私有的）。
class _RowSeparatorPainter extends CustomPainter {
  final Color color;
  final double start;

  const _RowSeparatorPainter({required this.color, required this.start});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 0.5;
    canvas.drawLine(Offset(start, 0.25), Offset(size.width, 0.25), paint);
  }

  @override
  bool shouldRepaint(_RowSeparatorPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.start != start;
}

class _TaskPrimaryActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _TaskPrimaryActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    // 浅底配加深的前景：直接用实色当文字在浅底上对比度不够，取对应的 Ink 档
    final fg = color == palette.err ? palette.errInk : palette.accentInk;
    return Material(
      color: palette.tint(color),
      // 底板与水波纹必须同值，否则波纹会溢出胶囊的两个圆头。
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: fg),
              const SizedBox(width: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 状态色当文字时换成对应的 Ink 档（浅底上对比度够）；不是状态色的（如 text2）原样返回。
Color _inkOf(AppPalette palette, Color color) {
  if (color == palette.err) return palette.errInk;
  if (color == palette.ok) return palette.okInk;
  if (color == palette.warn) return palette.warnInk;
  if (color == palette.purple) return palette.purpleInk;
  if (color == palette.accent) return palette.accentInk;
  return color;
}

class _TaskSwipeActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  /// 由行宽算出来（APP #22 评论：6 个按钮要在 360dp 屏放得下）。
  final double width;

  const _TaskSwipeActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.width,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    // 侧滑按钮的 10px 文字压在同色浅底上，是全库最小的那一档文字，必须用 Ink 档。
    final fg = _inkOf(palette, color);
    return SizedBox(
      width: width,
      child: Material(
        color: palette.tint(color),
        // 左滑露出的操作按钮，走按钮档；底板与水波纹必须同值。
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 17, color: fg),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  final String label;
  final bool active;

  const _MetaChip({required this.label, this.active = true});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: active ? palette.card : palette.fill,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: active ? palette.text : palette.text3,
        ),
      ),
    );
  }
}

class TaskLiveLogPage extends ConsumerStatefulWidget {
  final int taskId;
  final String? taskName;

  const TaskLiveLogPage({super.key, required this.taskId, this.taskName});

  @override
  ConsumerState<TaskLiveLogPage> createState() => _TaskLiveLogPageState();
}

class _TaskLiveLogPageState extends ConsumerState<TaskLiveLogPage> {
  final _sseClient = SseClient();

  /// 日志正文。增量追加、超长只留最近一部分，渲染与滚动跟随都交给 LogView。
  final _log = LogLineBuffer();

  /// 服务端重连一律从头重放整段历史（没有 Last-Event-ID），
  /// 靠它把重放的行抵扣掉，用户才不会看到日志翻倍。
  final _replayBuffer = SseReplayBuffer();

  /// 正文里现在是不是 SSE 送来的内容，而不是 live-logs 的快照（APP #15）。
  ///
  /// live-logs 只回实时日志文件的最后 4KB（首行常常是半截），SSE 却从第一行重放整段历史，
  /// 快照根本不是重放的前缀。以前把快照交给去重，第一行就对不上，
  /// 快照和整段历史叠成两份（300 行显示成 354 行）。现在快照只负责先给用户看点东西：
  /// 第一条 SSE 数据来了就整段换掉；之后（含出错后轮询、再连）只拿 SSE 来的内容去重，
  /// 不再用快照覆盖它。
  bool _logFromSse = false;

  /// live-logs 最近一次回的任务状态。轮询放弃时用它判断能不能回落到最近一次日志。
  double? _liveStatus;

  bool _loading = true;
  bool _done = false;
  String _statusText = '连接中...';
  Timer? _pollTimer;
  int _pollAttempts = 0;
  Color? _logBackgroundColor;

  @override
  void initState() {
    super.initState();
    _loadAppearance();
    Future.microtask(_init);
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _sseClient.close();
    _log.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final resp = await DioClient.instance.dio.get(
        ApiEndpoints.taskLiveLogs(widget.taskId),
      );
      final data = extractData(resp.data);
      if (data is Map<String, dynamic>) {
        _applyLiveSnapshot(data, initial: true);
        return;
      }
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _loading = false;
      _done = false;
      _statusText = '等待日志...';
    });
    _startPolling();
  }

  Future<void> _loadAppearance() async {
    final color = await loadPanelLogBackgroundColor();
    if (!mounted) {
      return;
    }
    setState(() => _logBackgroundColor = color);
  }

  void _applyLiveSnapshot(Map<String, dynamic> data, {bool initial = false}) {
    final rawLogs = data['logs'];
    final logs = rawLogs is List
        ? rawLogs
              .map((item) => item.toString())
              .where((line) => line.trim().isNotEmpty)
              .toList()
        : const <String>[];
    final done = data['done'] == true;
    final status = (data['status'] as num?)?.toDouble();
    final isRunning = !done && status == 2;
    final shouldKeepPolling = !isRunning && (logs.isEmpty || initial);

    if (!mounted) {
      return;
    }

    _liveStatus = status;
    setState(() {
      _loading = false;
      // SSE 已经送来过内容（出错后降级轮询）时不能拿快照覆盖：快照只是最后 4KB，
      // SSE 来的才是面板重放的前缀，再连上时要靠它去重。
      if (!_logFromSse) {
        _log.replaceAll(logs);
      }
      _done = done && !shouldKeepPolling;
      _statusText = shouldKeepPolling
          ? '等待日志...'
          : _statusFromLiveTask(status, done: done);
    });

    if (isRunning) {
      _pollTimer?.cancel();
      _connectSSE(widget.taskId);
      return;
    }

    if (shouldKeepPolling) {
      _startPolling();
      return;
    }

    _pollTimer?.cancel();
  }

  void _startPolling() {
    if (_pollTimer != null) {
      return;
    }
    _pollAttempts = 0;
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      _pollAttempts++;
      if (!mounted) {
        _pollTimer?.cancel();
        _pollTimer = null;
        return;
      }
      try {
        final resp = await DioClient.instance.dio.get(
          ApiEndpoints.taskLiveLogs(widget.taskId),
        );
        // 这一轮轮询已经停了或换了新的一轮（连上了 SSE、已经放弃、出错后重开）：
        // 慢过一秒才回来的这一跳作废。否则它会拿空快照盖掉刚回落的正文、再把轮询重新拉起来，
        // 放弃 → 回落 → 又被盖掉一直循环，每轮都重拉一遍最近一次日志。
        if (!identical(timer, _pollTimer)) {
          return;
        }
        final data = extractData(resp.data);
        if (data is Map<String, dynamic>) {
          _applyLiveSnapshot(data);
        }
      } catch (_) {}

      // 只让当前这一轮轮询收口：请求慢过一秒时上一跳的回调可能还没走到这里，
      // 两跳都放弃的话会把最近一次日志（可能有好几 MB）重复拉两遍。
      if (_pollAttempts >= 15 &&
          mounted &&
          _statusText == '等待日志...' &&
          identical(timer, _pollTimer)) {
        _pollTimer?.cancel();
        _pollTimer = null;
        // 不再等了。手里只有快照或什么都没有、任务也不在排队时，回落一次最近一次日志：
        // 面板任务一结束就删掉实时日志，live-logs 之后只会回空的
        // （从任务列表点「运行」一个几秒就跑完的任务，进来就是这样）。
        // 还在排队就不回落：那时拿到的是上一次运行的日志，会被当成这一次的结果。
        if (!_logFromSse && _liveStatus != kTaskStatusQueued) {
          await _fallbackToLatestLog();
          if (!mounted) {
            return;
          }
        }
        setState(() {
          // 正文与 AppBar 要说同一件事：以前 _done 跟着「有没有日志」走，没日志时
          // AppBar 已经写着「暂无日志」，正文却还挂着「等待日志输出...」和转圈。
          _done = true;
          _statusText = _log.isEmpty ? '暂无日志' : '已完成';
        });
      }
    });
  }

  /// 回落到这个任务最近一次运行的日志（面板 latest-log，与日志详情页看到的是同一份）。
  ///
  /// 只在「运行已经结束、手里只有 live-logs 快照或什么都没有」时用：快照最多 4KB，
  /// 任务结束后 live-logs 也拿不到内容了。拿不到就保持原样，不报错。
  Future<void> _fallbackToLatestLog() async {
    try {
      final resp = await DioClient.instance.dio.get(
        ApiEndpoints.taskLatestLog(widget.taskId),
      );
      final data = extractData(resp.data);
      final content = data is Map ? (data['content']?.toString() ?? '') : '';
      // 等结果的这段时间里 SSE 送来了内容，就以 SSE 的为准。
      if (!mounted || _logFromSse || content.isEmpty) {
        return;
      }
      final lines = content.replaceAll('\r\n', '\n').split('\n');
      if (lines.last.isEmpty) {
        lines.removeLast();
      }
      setState(() => _log.replaceAll(lines));
    } catch (_) {}
  }

  /// 重连前把已显示的行交给去重缓冲。日志太长时前面的行已经从内存里丢掉，
  /// 但服务端仍从第一行开始重放，要让它先按行数跳过那一段（同 LogStreamPage）。
  void _resetReplayBuffer() {
    if (!_logFromSse) {
      // 正文还是 live-logs 的快照（或是空的）：它不是重放的前缀，不能拿去去重，
      // 否则整段历史会接在快照后面（见 _logFromSse）。等第一条数据来了整段换掉。
      _replayBuffer.clear();
      return;
    }
    _replayBuffer.reset(_log.lines, skipLeading: _log.droppedCount);
  }

  void _connectSSE(int taskId) {
    _sseClient.close();
    _pollTimer?.cancel();
    _pollTimer = null;
    _resetReplayBuffer();
    _sseClient.connect(
      path: ApiEndpoints.logStream(taskId),
      autoReconnect: true,
      // 重放去重统一挂在这里：不管重连是服务端 done:reconnect 触发的，
      // 还是 token 续期后客户端自己发起的，行为都一样。
      onReconnect: _resetReplayBuffer,
      onEvent: (event) {
        if (!mounted) return;
        if (event.event == 'done') {
          if (event.data == 'reconnect') {
            setState(() {
              _done = false;
              _statusText = '运行中';
            });
            return;
          }
          // finished-late 是面板「等了一会儿才收口」的结束（面板 v3.2.0 起），对这里同样是跑完了。
          final finished =
              event.data == 'finished' || event.data == 'finished-late';
          setState(() {
            _done = finished;
            _statusText = _statusFromStreamDone(event.data);
          });
          if (finished && !_logFromSse) {
            // 这条流一行数据都没送来：live-logs 那会儿任务还在跑，连上 SSE 时已经结束了
            // （短任务很容易碰上）。快照留着别清空（日志不到 4KB 时它就是全量），
            // 再回落一次最近一次日志拿完整的。
            _fallbackToLatestLog();
          }
          return;
        }
        final newLines = event.data.replaceAll('\r\n', '\n').split('\n');
        newLines.removeWhere((l) => l.isEmpty);
        if (newLines.isEmpty) return;
        final wasEmpty = _log.isEmpty;
        if (_logFromSse) {
          final dedupedLines = _replayBuffer.consume(newLines);
          if (dedupedLines.isEmpty) return;
          _log.append(dedupedLines);
        } else {
          // 第一条 SSE 数据：面板从第一行开始重放整段历史，快照整段换掉。
          _logFromSse = true;
          _log.replaceAll(newLines);
        }
        // 正文由 LogView 监听缓冲区自己刷新，整页只在「从无到有」或状态变了时重建。
        if (wasEmpty || _done || _statusText != '运行中') {
          setState(() {
            _done = false;
            _statusText = '运行中';
          });
        }
      },
      onDone: () {
        if (!mounted) return;
        if (_done) return;
        setState(() => _statusText = '连接结束');
      },
      onError: (error) {
        if (!mounted) return;
        if (error is SseAuthFailure) {
          // 会话已经死了，轮询接口同样会 401。这里不再降级轮询：
          // 只会刷一串失败请求，然后被路由踢回登录页，反而盖掉真正的原因。
          setState(() {
            _done = true;
            _statusText = '登录已失效';
          });
          return;
        }
        if (!_done) {
          setState(() => _statusText = '连接错误');
          _pollTimer?.cancel();
          _pollTimer = null;
          _startPolling();
        }
      },
    );
  }

  bool _actionBusy = false;
  bool _resolvingScript = false;
  String? _cachedCommand;

  Future<void> _stopLiveTask() async {
    if (_actionBusy || _done) return;
    setState(() => _actionBusy = true);
    try {
      await ref.read(taskProvider.notifier).stopTask(widget.taskId);
      if (!mounted) return;
      _sseClient.close();
      _pollTimer?.cancel();
      _pollTimer = null;
      setState(() {
        _done = true;
        _statusText = '已停止';
      });
      AppSnack.show(context, '已发送停止指令');
    } catch (error) {
      if (mounted) {
        AppSnack.error(context, extractErrorMessage(error, '停止任务失败'));
      }
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Future<void> _rerunLiveTask() async {
    if (_actionBusy) return;
    setState(() => _actionBusy = true);
    try {
      await ref.read(taskProvider.notifier).runTask(widget.taskId);
      if (!mounted) return;
      _sseClient.close();
      _pollTimer?.cancel();
      _pollTimer = null;
      setState(() {
        _log.clear();
        _replayBuffer.clear();
        _logFromSse = false;
        _liveStatus = kTaskStatusRunning;
        _loading = true;
        _done = false;
        _statusText = '连接中...';
      });
      await _init();
    } catch (error) {
      if (mounted) {
        AppSnack.error(context, extractErrorMessage(error, '重新运行失败'));
      }
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Future<void> _openScriptEditor() async {
    if (_resolvingScript) return;
    final cmd = await _resolveCommand();
    if (!mounted) return;
    if (cmd == null) {
      AppSnack.error(context, '无法获取任务命令');
      return;
    }
    final scriptPath = extractScriptPathFromCommand(cmd);
    if (scriptPath == null) {
      AppSnack.show(context, '该任务不是脚本文件命令：$cmd');
      return;
    }
    if (GoRouter.maybeOf(context) != null) {
      context.push('/scripts/view', extra: scriptPath);
    }
  }

  Future<String?> _resolveCommand() async {
    if ((_cachedCommand ?? '').trim().isNotEmpty) {
      return _cachedCommand;
    }
    final fromMemory = pickCommandFromTasks(
      ref.read(taskProvider).tasks,
      widget.taskId,
    );
    if (fromMemory != null) {
      _cachedCommand = fromMemory;
      return fromMemory;
    }
    setState(() => _resolvingScript = true);
    try {
      final response = await DioClient.instance.dio.get(
        ApiEndpoints.tasks,
        queryParameters: {'all': 1},
      );
      final paginated = extractPaginated(response.data);
      final tasks = paginated.items.map(Task.fromJson).toList();
      final fetched = pickCommandFromTasks(tasks, widget.taskId);
      _cachedCommand = fetched;
      return fetched;
    } catch (_) {
      return null;
    } finally {
      if (mounted) setState(() => _resolvingScript = false);
    }
  }

  FullscreenLogTone _resolveLiveTone() {
    if (_statusText == '登录已失效' ||
        _statusText == '连接错误' ||
        _statusText == 'failed' ||
        _statusText.contains('失败')) {
      return FullscreenLogTone.failed;
    }
    if (!_done) {
      return FullscreenLogTone.running;
    }
    if (_statusText == '已完成') {
      return FullscreenLogTone.success;
    }
    return FullscreenLogTone.neutral;
  }

  String _statusFromLiveTask(double? status, {required bool done}) {
    if (!done && status == 2) {
      return '运行中';
    }
    if (!done) {
      return '等待日志...';
    }
    switch (status) {
      case 0:
        return '已禁用';
      case 0.5:
        return '排队中';
      case 1:
        return '已启用';
      case 2:
        return '已完成';
      default:
        return _log.isEmpty ? '等待日志...' : '已完成';
    }
  }

  String _statusFromStreamDone(String value) {
    switch (value) {
      case 'finished':
      case 'finished-late':
        return '已完成';
      case 'timeout':
        return '等待日志...';
      case 'reconnect':
        return '运行中';
      default:
        return value;
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = (widget.taskName?.trim().isNotEmpty ?? false)
        ? '${widget.taskName} 运行日志'
        : '运行日志';
    final canOperate = ref.watch(authProvider).user?.isOperator ?? false;

    return FullscreenLogScaffold(
      title: title,
      subtitle: '任务 #${widget.taskId}',
      statusLabel: _statusText,
      statusTone: _resolveLiveTone(),
      buffer: _log,
      loading: _loading,
      emptyMessage: _done ? '无日志内容' : '等待日志输出...',
      configuredBackgroundColor: _logBackgroundColor,
      truncatedHint: '完整日志可在「运行日志」里打开这条记录下载',
      onStop: (!_done && canOperate) ? _stopLiveTask : null,
      stopBusy: _actionBusy,
      onRerun: (_done && canOperate) ? _rerunLiveTask : null,
      rerunBusy: _actionBusy,
      onOpenScript: canOperate ? _openScriptEditor : null,
      openScriptBusy: _resolvingScript,
      copySuccessToast: _log.droppedCount > 0
          ? '已复制最近 ${_log.length} 行'
          : '日志已复制到剪贴板',
    );
  }
}

String _extractTaskError(dynamic error, String fallback) =>
    extractErrorMessage(error, fallback);

class _GroupPopupMenu extends StatelessWidget {
  final bool isUngrouped;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;
  final VoidCallback onAddTasks;

  const _GroupPopupMenu({
    required this.isUngrouped,
    this.onRename,
    this.onDelete,
    required this.onAddTasks,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_vert, size: 18, color: context.palette.text3),
      padding: EdgeInsets.zero,
      // 这里原本是 `const BoxConstraints()` —— 空约束会把 IconButton 默认的
      // 48×48 直接取消掉，实际命中区退化成那个 18dp 图标，是全库最小的几处之一。
      // 不能简单删掉这行：删了会回到 48 并把分组头撑高。
      constraints: const BoxConstraints(
        minWidth: AppTapTarget.min,
        minHeight: AppTapTarget.min,
      ),
      itemBuilder: (ctx) => [
        if (!isUngrouped && onRename != null)
          const PopupMenuItem(value: 'rename', child: Text('重命名分组')),
        if (!isUngrouped && onDelete != null)
          const PopupMenuItem(value: 'delete', child: Text('删除分组')),
        PopupMenuItem(value: 'add', child: Text(isUngrouped ? '新建分组' : '添加任务')),
      ],
      onSelected: (value) {
        switch (value) {
          case 'rename':
            onRename?.call();
          case 'delete':
            onDelete?.call();
          case 'add':
            onAddTasks();
        }
      },
    );
  }
}