import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/api_endpoints.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/storage/secure_storage.dart';
import '../../../core/network/sse_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/models/task.dart';
import '../../../shared/utils/ansi_text.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/utils/time_utils.dart';
import '../../../shared/utils/log_background.dart';
import '../../../shared/widgets/app_buttons.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/app_notice.dart';
import '../../../shared/widgets/app_snack.dart';
import '../../../shared/widgets/app_state_views.dart';
import '../../../shared/widgets/task_cron_list.dart';
import '../providers/task_provider.dart';

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

class _TaskListPageState extends ConsumerState<TaskListPage> {
  static const _collapsedGroupsStorageKey = 'tasks.collapsed_groups';
  static const _scrollOffsetStorageKey = 'tasks.scroll_offset';
  static const _selectedGroupStorageKey = 'tasks.selected_group';
  static const _groupOrderStorageKey = 'tasks.group_order';
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  final Set<String> _collapsedGroups = <String>{};
  final Set<int> _selectedTaskIds = <int>{};
  final List<String> _knownGroups = <String>[];
  List<String> _groupOrder = <String>[];
  bool _groupReorderMode = false;
  bool _selectionMode = false;
  bool _taskSortMode = false;
  bool _taskOrderDirty = false;
  Timer? _debounce;
  bool _restoredScrollOffset = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      await _restoreTaskUiState();
      if (!mounted) {
        return;
      }
      await ref.read(taskProvider.notifier).load(refresh: true);
    });
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      ref.read(taskProvider.notifier).loadMore();
    }

    if (_scrollController.hasClients) {
      SecureStorage.saveUiState(
        _scrollOffsetStorageKey,
        _scrollController.offset.toStringAsFixed(2),
      );
    }
  }

  void _showMessage(String message) => AppSnack.show(context, message);

  void _showSuccess(String message) => AppSnack.success(context, message);

  void _showError(String message) => AppSnack.error(context, message);

  void _showWarning(String message) => AppSnack.warn(context, message);

  /// 全部任务操作失败的漏斗：批量操作 / 排序保存 / 停止 / 启停 / 复制 / 置顶 / 删除
  /// 七条路径都从这里出提示，所以着色只需要改这一处。
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
                      backgroundColor: AppColors.red500,
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

  Future<void> _finishTaskSortMode(List<Task> tasks) async {
    if (!_taskOrderDirty) {
      setState(() => _taskSortMode = false);
      return;
    }

    try {
      await ref.read(taskProvider.notifier).saveTaskOrder(tasks);
      if (!mounted) {
        return;
      }
      setState(() {
        _taskSortMode = false;
        _taskOrderDirty = false;
      });
      _showSuccess('任务排序已保存');
    } catch (error) {
      await _showActionError(error, '保存任务排序失败');
    }
  }

  Future<void> _openLatestLog(Task task) async {
    if (task.isRunning) {
      _openLiveLog(task);
      return;
    }
    try {
      final latestLog = await ref
          .read(taskProvider.notifier)
          .fetchLatestLog(task.id);
      if (!mounted) {
        return;
      }
      if (latestLog == null) {
        _showMessage('当前任务暂无日志');
        return;
      }
      context.push('/logs/${latestLog.id}/stream');
    } catch (_) {
      _showError('打开日志失败');
    }
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
      if (task.isDisabled) {
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
      ref
          .read(taskProvider.notifier)
          .setLabelFilter(selectedGroup.trim().isEmpty ? null : selectedGroup);
    }
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

  List<_TaskGroup> _sortGroupsByOrder(List<_TaskGroup> groups) {
    if (_groupOrder.isEmpty) return groups;
    final orderMap = <String, int>{};
    for (var i = 0; i < _groupOrder.length; i++) {
      orderMap[_groupOrder[i]] = i;
    }
    groups.sort((a, b) {
      final ai = orderMap[a.key] ?? 9999;
      final bi = orderMap[b.key] ?? 9999;
      if (ai != bi) return ai.compareTo(bi);
      return 0;
    });
    return groups;
  }

  Future<void> _restoreScrollOffsetIfNeeded() async {
    if (_restoredScrollOffset || !_scrollController.hasClients) {
      return;
    }
    final raw = await SecureStorage.getUiState(_scrollOffsetStorageKey);
    if (raw == null || raw.trim().isEmpty) {
      _restoredScrollOffset = true;
      return;
    }
    final offset = double.tryParse(raw);
    if (offset == null) {
      _restoredScrollOffset = true;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) {
        return;
      }
      final maxOffset = _scrollController.position.maxScrollExtent;
      _scrollController.jumpTo(offset.clamp(0, maxOffset));
      _restoredScrollOffset = true;
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
                trailing: ref.watch(taskProvider).labelFilter == group
                    ? const Icon(Icons.check, color: AppColors.primary)
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
    ref
        .read(taskProvider.notifier)
        .setLabelFilter(selected.isEmpty ? null : selected);
    await SecureStorage.saveUiState(_selectedGroupStorageKey, selected);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(taskProvider);
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;
    _collectKnownGroups(state.tasks);
    final groupedTasks = _sortGroupsByOrder(_groupTasks(state.tasks));
    // 一个分组都没建过（或筛选后只剩「未分组」）时，那条分组头没有任何信息量：
    // 标题恒为「未分组」、条数与头部的「共 N 个任务」重复、折叠它等于清空整页。
    // 这种情况直接不渲染，省下 60.9dp——这是任务列表最大的一笔密度收益。
    final onlyUngrouped =
        groupedTasks.length == 1 && groupedTasks.first.key.isEmpty;
    final selectedCount = _selectedTaskIds.length;
    final allSelected = _isAllTasksSelected(state.tasks);
    _restoreScrollOffsetIfNeeded();

    return Scaffold(
      body: Padding(
        padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 12),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '定时任务',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                  ),
                  Row(
                    children: [
                      if (!_taskSortMode)
                        AppChipButton(
                          label: _selectionMode ? '取消' : '批量',
                          icon: _selectionMode ? Icons.close : Icons.done_all,
                          onTap: () => _setSelectionMode(!_selectionMode),
                        ),
                      if (!_selectionMode) ...[
                        const SizedBox(width: 8),
                        AppChipButton(
                          label: _taskSortMode ? '完成' : '排序',
                          icon: _taskSortMode ? Icons.check : Icons.swap_vert,
                          onTap: () async {
                            if (_taskSortMode) {
                              await _finishTaskSortMode(state.tasks);
                            } else {
                              setState(() {
                                _taskSortMode = true;
                                _groupReorderMode = false;
                                _taskOrderDirty = false;
                              });
                            }
                          },
                        ),
                      ],
                      if (!_selectionMode && !_taskSortMode) ...[
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () => context.push('/tasks/new'),
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: const BoxDecoration(
                              color: AppColors.primary,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.add,
                              size: 20,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: '搜索任务名称或命令...',
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
                            ref.read(taskProvider.notifier).setKeyword('');
                          },
                        )
                      : null,
                ),
                style: const TextStyle(fontSize: 14),
                onChanged: _onSearchChanged,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 38,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                scrollDirection: Axis.horizontal,
                itemCount: _taskStatusFilters.length,
                separatorBuilder: (_, index) => const SizedBox(width: 8),
                itemBuilder: (_, index) {
                  final filter = _taskStatusFilters[index];
                  final selected = state.statusFilter == filter.value;
                  return ChoiceChip(
                    label: Text(filter.label),
                    selected: selected,
                    onSelected: (_) {
                      if (_scrollController.hasClients &&
                          _scrollController.offset > 0) {
                        _scrollController.jumpTo(0);
                      }
                      ref
                          .read(taskProvider.notifier)
                          .setStatusFilter(filter.value);
                    },
                    selectedColor: AppColors.primary.withAlpha(18),
                    side: BorderSide(
                      color: selected
                          ? AppColors.primary.withAlpha(90)
                          : AppColors.slate200,
                    ),
                    labelStyle: TextStyle(
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      // selectedColor 就是同一个 primary 的 alpha=18 淡底，
                      // 标签再用满强度 primary 会和底色贴在一起。
                      color: selected
                          ? context.surfaces.tintFg(AppColors.primary)
                          : null,
                    ),
                    visualDensity: VisualDensity.compact,
                  );
                },
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Text(
                    '共 ${state.total} 个任务',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _showGroupPicker,
                    icon: const Icon(Icons.label_outline, size: 16),
                    label: Text(
                      state.labelFilter?.isNotEmpty == true
                          ? state.labelFilter!
                          : '全部分组',
                    ),
                  ),
                  if (state.statusFilter != null || state.labelFilter != null)
                    TextButton(
                      onPressed: () {
                        if (_scrollController.hasClients &&
                            _scrollController.offset > 0) {
                          _scrollController.jumpTo(0);
                        }
                        ref.read(taskProvider.notifier).setStatusFilter(null);
                        ref.read(taskProvider.notifier).setLabelFilter(null);
                        SecureStorage.saveUiState(_selectedGroupStorageKey, '');
                      },
                      child: const Text('清除筛选'),
                    ),
                ],
              ),
            ),
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
                        color: AppColors.slate500,
                        enabled: state.tasks.isNotEmpty,
                        onTap: () => _toggleSelectAllTasks(state.tasks),
                      ),
                      const SizedBox(width: 8),
                      AppTintedActionButton(
                        label: '批量运行',
                        icon: Icons.play_circle_outline,
                        color: AppColors.primary,
                        enabled: selectedCount > 0,
                        onTap: () =>
                            _performBatchTaskAction(_TaskBatchAction.run),
                      ),
                      const SizedBox(width: 8),
                      AppTintedActionButton(
                        label: '批量启用',
                        icon: Icons.toggle_on_outlined,
                        // 「启用」是 success 绿。原先它和左边的「批量运行」同为
                        // primary，两个语义完全不同的动作长得一模一样。
                        color: AppColors.success,
                        enabled: selectedCount > 0,
                        onTap: () =>
                            _performBatchTaskAction(_TaskBatchAction.enable),
                      ),
                      const SizedBox(width: 8),
                      AppTintedActionButton(
                        label: '批量禁用',
                        icon: Icons.toggle_off_outlined,
                        color: AppColors.slate500,
                        enabled: selectedCount > 0,
                        onTap: () =>
                            _performBatchTaskAction(_TaskBatchAction.disable),
                      ),
                      const SizedBox(width: 8),
                      AppTintedActionButton(
                        label: '批量删除',
                        icon: Icons.delete_outline,
                        color: AppColors.red500,
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
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: AppNotice(
                  color: AppColors.primary,
                  icon: Icons.swap_vert,
                  text: '长按拖拽调整当前任务列表顺序，点击「完成」保存',
                  accentText: true,
                ),
              ),
            ],
            Expanded(
              child: RefreshIndicator(
                color: AppColors.primary,
                onRefresh: () =>
                    ref.read(taskProvider.notifier).load(refresh: true),
                child: state.loading && state.tasks.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: const [AppLoadingView()],
                      )
                    // TaskListState 一直有 error 字段，但从来没有被渲染过：
                    // 拿不到数据和真的没有任务是两回事，必须先判 error。
                    : state.error != null && state.tasks.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
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
                        children: const [
                          AppEmptyView(
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
                    : ListView(
                        controller: _scrollController,
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
                        children: groupedTasks
                            .map(
                              (group) => _buildTaskGroup(
                                group,
                                isLight,
                                showHeader: !onlyUngrouped,
                              ),
                            )
                            .toList(),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<_TaskGroup> _groupTasks(List<Task> tasks) {
    final groups = <_TaskGroup>[];
    final map = <String, _TaskGroup>{};

    for (final task in tasks) {
      final groupName = task.groupName?.trim();
      final key = (groupName == null || groupName.isEmpty) ? '' : groupName;
      final title = key.isEmpty ? '未分组' : key;
      final entry = map.putIfAbsent(key, () {
        final created = _TaskGroup(key: key, title: title);
        groups.add(created);
        return created;
      });
      entry.tasks.add(task);
    }

    return groups;
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已将分组 "$oldName" 重命名为 "$newName"')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('重命名分组失败')));
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
            child: const Text('确定', style: TextStyle(color: Colors.red)),
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已删除分组 "$groupName"')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('删除分组失败')));
      }
    }
  }

  Future<void> _addTasksToGroup(
    String targetGroup,
    List<Task> ungroupedTasks,
  ) async {
    if (ungroupedTasks.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('没有未分组的任务可添加')));
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
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          '已将 ${tasksToMove.length} 个任务添加到 "$targetGroup"',
                        ),
                      ),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('添加任务到分组失败')));
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
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          '已创建分组 "$groupName" 并添加 ${tasksToMove.length} 个任务',
                        ),
                      ),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('创建分组失败')));
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

  Widget _buildGroupReorderView(List<_TaskGroup> groups) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.swap_vert, size: 18),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '长按拖拽调整分组顺序',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
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
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
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
                    const Icon(
                      Icons.drag_handle,
                      size: 20,
                      color: AppColors.slate400,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        group.title,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      '${group.tasks.length} 条',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.slate400,
                      ),
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
    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
      itemCount: tasks.length,
      onReorder: (oldIndex, newIndex) {
        // 只先调整本地顺序，等用户点击“完成”后再统一保存到后端，避免拖一下就请求多次。
        ref.read(taskProvider.notifier).reorderLocalTasks(oldIndex, newIndex);
        setState(() => _taskOrderDirty = true);
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
              const Icon(
                Icons.drag_handle,
                size: 20,
                color: AppColors.slate400,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.name,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      task.groupName?.isNotEmpty == true
                          ? '分组：${task.groupName}'
                          : '未分组',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.slate400,
                      ),
                    ),
                  ],
                ),
              ),
              _MetaChip(label: task.statusText, active: !task.isDisabled),
            ],
          ),
        );
      },
    );
  }

  /// [showHeader] 为 false 时不渲染可折叠分组头。
  ///
  /// `_groupTasks` 永远至少产出一个桶（没设分组的任务全部落进 key 为空的
  /// 「未分组」桶），所以分组头以前是**无条件**渲染的：一个从来没用过分组功能的
  /// 用户，屏幕顶部固定被一条 60.9dp 的「未分组 · N 条」占掉，而这条信息与头部
  /// 已有的「共 N 个任务」完全重复，且折叠它等于把整页任务藏起来，毫无用处。
  /// 这是任务列表每屏只能完整显示 1 张卡的首要原因，比卡片内边距重要得多。
  Widget _buildTaskGroup(
    _TaskGroup group,
    bool isLight, {
    bool showHeader = true,
  }) {
    // 分组头被隐藏时必须忽略折叠状态：此时没有任何入口可以再展开，
    // 上一次会话遗留在 _collapsedGroups 里的空 key 会让整页任务凭空消失。
    final collapsed = showHeader && _collapsedGroups.contains(group.key);
    final enabledCount = group.tasks.where((task) => task.isEnabled).length;
    final runningCount = group.tasks.where((task) => task.isRunning).length;
    final isUngrouped = group.key.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showHeader)
          AppCard(
            margin: const EdgeInsets.only(bottom: 6),
            // 纵向内边距只降到 10：整条分组头就是它自己的点击区，
            // 再往下压（12→8）会让这个点击目标掉到 44.9dp，低于 48dp 下限。
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
            child: Row(
              children: [
                Icon(
                  collapsed ? Icons.chevron_right : Icons.expand_more,
                  size: 20,
                  color: AppColors.slate400,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    group.title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '${group.tasks.length} 条',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 10),
                if (runningCount > 0)
                  _MetaChip(label: '$runningCount 运行中', active: true)
                else
                  _MetaChip(
                    label: '$enabledCount 已启用',
                    active: enabledCount > 0,
                  ),
                const SizedBox(width: 4),
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
        if (!collapsed)
          ...group.tasks.map(
            (task) => _TaskCard(
              key: ValueKey('task-card-${task.id}'),
              task: task,
              isLight: isLight,
              selectionMode: _selectionMode,
              selected: _selectedTaskIds.contains(task.id),
              onTap: () => _selectionMode
                  ? _toggleTaskSelection(task.id)
                  : _openLatestLog(task),
              onLongPress: () {
                HapticFeedback.mediumImpact();
                _toggleTaskSelection(task.id);
              },
              onSelectedChanged: () => _toggleTaskSelection(task.id),
              onRun: () => _runTask(task),
              onStop: () => _stopTask(task),
              onToggleEnabled: () => _toggleTaskEnabled(task),
              onCopy: () => _copyTask(task),
              onTogglePinned: () => _togglePinned(task),
              onEdit: () => context.push('/tasks/edit', extra: task),
              onDelete: () => _confirmDelete(task),
            ),
          ),
      ],
    );
  }

  Future<void> _confirmDelete(Task task) async {
    final scriptPath = _extractScriptPathFromCommand(task.command);
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
                        backgroundColor: AppColors.red500,
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
    if (confirm != true) {
      return;
    }
    try {
      await ref.read(taskProvider.notifier).deleteTask(task.id);
      if (deleteScript && scriptPath != null) {
        try {
          await DioClient.instance.dio.delete(
            ApiEndpoints.scripts,
            queryParameters: {'path': scriptPath, 'type': 'file'},
          );
          _showSuccess('任务和关联脚本已删除');
        } catch (error) {
          // 部分成功：任务删掉了、脚本没删掉。既不能报绿也不能报红。
          _showWarning(
            '任务已删除，但脚本删除失败：${extractErrorMessage(error, '请稍后手动删除脚本')}',
          );
        }
        return;
      }
      _showSuccess('任务已删除');
    } catch (error) {
      await _showActionError(error, '删除任务失败');
    }
  }
}

class _TaskCard extends StatefulWidget {
  final Task task;
  final bool isLight;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onSelectedChanged;
  final VoidCallback onRun;
  final VoidCallback onStop;
  final VoidCallback onToggleEnabled;
  final VoidCallback onCopy;
  final VoidCallback onTogglePinned;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _TaskCard({
    super.key,
    required this.task,
    required this.isLight,
    required this.selectionMode,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onSelectedChanged,
    required this.onRun,
    required this.onStop,
    required this.onToggleEnabled,
    required this.onCopy,
    required this.onTogglePinned,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  State<_TaskCard> createState() => _TaskCardState();
}

class _TaskCardState extends State<_TaskCard> {
  static const double _actionWidth = 52;
  static const double _actionGap = 6;
  static const double _actionsWidth = _actionWidth * 5 + _actionGap * 4 + 8;

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

  // 四态配色：运行中=蓝(info/主色)、排队中=琥珀(warning)、失败=红(danger)、
  // 已启用=绿(success)、已禁用=灰。改造前「运行中」与「已启用」都取 primary，
  // 主色换蓝后两者彻底同色，这里把「已启用」还给绿色语义。
  Color _dotColor() {
    if (task.isRunning) {
      return AppColors.info;
    }
    if (task.isQueued) {
      return AppColors.warning;
    }
    if (task.lastRunStatus == 1) {
      return AppColors.danger;
    }
    if (task.isEnabled) {
      return AppColors.success;
    }
    return AppColors.slate300;
  }

  String _statusLabel() {
    if (task.isRunning) {
      return '运行中';
    }
    if (task.isQueued) {
      return '排队中';
    }
    if (task.isEnabled) {
      return '已启用';
    }
    return '已禁用';
  }

  Color _statusBg() {
    if (task.isRunning) {
      return widget.isLight
          ? AppColors.infoLight
          : AppColors.info.withAlpha(25);
    }
    if (task.isQueued) {
      return AppColors.warning.withAlpha(widget.isLight ? 18 : 25);
    }
    if (task.isEnabled) {
      return widget.isLight
          ? AppColors.successLight
          : AppColors.success.withAlpha(25);
    }
    return widget.isLight ? AppColors.slate100 : AppColors.slate800;
  }

  Color _statusFg() {
    if (task.isRunning) {
      return widget.isLight ? AppColors.infoDark : AppColors.info;
    }
    if (task.isQueued) {
      // 「排队中」是全部徽章里最淡的一个：琥珀色压在自己的 alpha=18 淡底上
      // 只有 2.04:1。另外三个分支浅色下已经各自用了 *Dark，这里补齐。
      return (widget.isLight ? AppSurfaces.light : AppSurfaces.dark)
          .tintFg(AppColors.warning);
    }
    if (task.isEnabled) {
      return widget.isLight ? AppColors.successDark : AppColors.success;
    }
    return AppColors.neutral;
  }

  String _taskTypeLabel() {
    switch (task.taskType) {
      case 'manual':
        return '手动运行';
      case 'startup':
        return '开机运行';
      default:
        return '常规定时';
    }
  }

  List<String> _scheduleExpressions() {
    if (task.cronExpressions.isNotEmpty) {
      return task.cronExpressions;
    }
    if (task.cronExpression.trim().isNotEmpty) {
      return [task.cronExpression.trim()];
    }
    return const [];
  }

  String _bottomText() {
    if (task.isRunning) {
      return '点击查看实时日志';
    }
    if (task.lastRunStatus == 1 && task.lastRunAt != null) {
      return '上次失败：${formatTimeCn(task.lastRunAt, short: true)}';
    }
    if (task.nextRunAt != null) {
      return '下次运行：${formatTimeCn(task.nextRunAt, short: true)}';
    }
    if (task.taskType == 'manual') {
      return '手动触发';
    }
    if (task.taskType == 'startup') {
      return '面板启动时自动执行';
    }
    return '暂无计划';
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

  @override
  Widget build(BuildContext context) {
    final dotColor = _dotColor();
    final borderColor = widget.isLight
        ? AppColors.slate200
        : AppColors.slate800;
    final labels = task.userLabelsForDisplay;
    final hasFailure = task.lastRunStatus == 1;
    final primaryColor = task.isRunning ? AppColors.red500 : AppColors.primary;

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
        margin: const EdgeInsets.only(bottom: 8),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _TaskSwipeActionButton(
                      label: task.isDisabled ? '启用' : '禁用',
                      icon: task.isDisabled
                          ? Icons.play_circle_outline
                          : Icons.pause_circle_outline,
                      // 「启用」是把任务切到已启用态，语义是 success 绿，
                      // 和同卡状态圆点 / 徽章的「已启用」保持同色；
                      // 原先取 primary，与「运行」类动作撞成同一个蓝。
                      // 淡底与前景都由 _TaskSwipeActionButton 内部按这个 color
                      // 推导（含 tintFg），这里改一处即可。
                      color: task.isDisabled
                          ? AppColors.success
                          : AppColors.slate500,
                      onTap: () => _runSwipeAction(widget.onToggleEnabled),
                    ),
                    const SizedBox(width: _actionGap),
                    _TaskSwipeActionButton(
                      label: task.isPinned ? '取消' : '置顶',
                      icon: task.isPinned
                          ? Icons.push_pin_outlined
                          : Icons.push_pin,
                      color: AppColors.amber500,
                      onTap: () => _runSwipeAction(widget.onTogglePinned),
                    ),
                    const SizedBox(width: _actionGap),
                    _TaskSwipeActionButton(
                      label: '复制',
                      icon: Icons.copy_outlined,
                      color: AppColors.blue500,
                      onTap: () => _runSwipeAction(widget.onCopy),
                    ),
                    const SizedBox(width: _actionGap),
                    _TaskSwipeActionButton(
                      label: '编辑',
                      icon: Icons.edit_outlined,
                      color: AppColors.slate500,
                      onTap: () => _runSwipeAction(widget.onEdit),
                    ),
                    const SizedBox(width: _actionGap),
                    _TaskSwipeActionButton(
                      label: '删除',
                      icon: Icons.delete_outline,
                      color: AppColors.red500,
                      onTap: () => _runSwipeAction(widget.onDelete),
                    ),
                  ],
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
                      // 左滑露出右侧次要操作；关闭时也限制在卡片内处理，避免和系统返回手势抢动作。
                      final nextOffset = (_dragOffset + details.delta.dx)
                          .clamp(-_actionsWidth, 0.0)
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
                          _dragOffset.abs() > _actionsWidth * 0.42
                          ? -_actionsWidth
                          : 0.0;
                      setState(() {
                        _dragging = false;
                        _dragOffset = nextOffset;
                      });
                      if (nextOffset == -_actionsWidth) {
                        HapticFeedback.selectionClick();
                      }
                    },
              child: AnimatedContainer(
                duration: _dragging
                    ? Duration.zero
                    : const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                transform: Matrix4.translationValues(_dragOffset, 0, 0),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: widget.isLight ? Colors.white : AppColors.slate900,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: widget.selected
                        ? AppColors.primary
                        : (hasFailure
                              ? AppColors.red500.withAlpha(60)
                              : borderColor),
                    width: widget.selected ? 1.4 : 1,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (widget.selectionMode) ...[
                          SizedBox(
                            width: 24,
                            height: 24,
                            child: Checkbox(
                              value: widget.selected,
                              onChanged: (_) => widget.onSelectedChanged(),
                              activeColor: AppColors.primary,
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: dotColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            task.name,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (task.isPinned)
                          const Padding(
                            padding: EdgeInsets.only(right: 6),
                            child: Icon(
                              Icons.push_pin,
                              size: 14,
                              color: AppColors.amber500,
                            ),
                          ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: _statusBg(),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            _statusLabel(),
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: _statusFg(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _TaskScheduleSummary(
                      taskType: task.taskType,
                      taskTypeLabel: _taskTypeLabel(),
                      expressions: _scheduleExpressions(),
                      isLight: widget.isLight,
                    ),
                    if (labels.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      _TaskSubscriptionSummary(
                        labels: labels,
                        isLight: widget.isLight,
                      ),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _bottomText(),
                            style: TextStyle(
                              fontSize: 11,
                              color: hasFailure
                                  ? AppColors.red500
                                  : (widget.isLight
                                        ? AppColors.slate400
                                        : AppColors.slate500),
                            ),
                          ),
                        ),
                        if (!widget.selectionMode) ...[
                          _TaskPrimaryActionButton(
                            label: task.isRunning ? '停止' : '运行',
                            icon: task.isRunning
                                ? Icons.stop_rounded
                                : Icons.play_arrow_rounded,
                            color: primaryColor,
                            onTap: task.isRunning
                                ? widget.onStop
                                : widget.onRun,
                          ),
                          const SizedBox(width: 8),
                          const Icon(
                            Icons.swipe_left_alt_rounded,
                            size: 18,
                            color: AppColors.slate400,
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
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
    final surfaces = AppSurfaces.of(context);
    final isLight = surfaces.isLight;
    // 底色就是同一个 color 的淡底，前景必须加深，否则「运行 / 停止」两个
    // 主操作按钮在浅色下最高只有 2.6:1。
    final fg = surfaces.tintFg(color);
    return Material(
      color: color.withAlpha(isLight ? 22 : 34),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: fg),
              const SizedBox(width: 4),
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

class _TaskSwipeActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _TaskSwipeActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final surfaces = AppSurfaces.of(context);
    final isLight = surfaces.isLight;
    // 侧滑按钮的 10px 文字压在同色淡底上，是全库最小的那一档文字。
    final fg = surfaces.tintFg(color);
    return SizedBox(
      width: _TaskCardState._actionWidth,
      child: Material(
        color: color.withAlpha(isLight ? 22 : 34),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
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

class _TaskScheduleSummary extends StatelessWidget {
  final String taskType;
  final String taskTypeLabel;
  final List<String> expressions;
  final bool isLight;

  const _TaskScheduleSummary({
    required this.taskType,
    required this.taskTypeLabel,
    required this.expressions,
    required this.isLight,
  });

  @override
  Widget build(BuildContext context) {
    final isCron = taskType == 'cron';
    final cleanExpressions = expressions
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
    final title = isCron
        ? (cleanExpressions.length > 1
              ? 'Cron 定时 · ${cleanExpressions.length} 条'
              : 'Cron 定时')
        : taskTypeLabel;
    final value = isCron
        ? (cleanExpressions.isEmpty ? '暂无定时规则' : cleanExpressions.first)
        : (taskType == 'manual' ? '手动触发运行' : '面板启动时自动执行');
    final icon = isCron
        ? Icons.schedule_rounded
        : taskType == 'manual'
        ? Icons.touch_app_outlined
        : Icons.power_settings_new_rounded;
    final color = isCron
        ? AppColors.primary
        : taskType == 'manual'
        ? AppColors.blue500
        : AppColors.amber500;

    // 这里原本是「带边框的盒子套在带边框的卡片里」：任务卡自己已经有 1px 边框，
    // 里面再套一层 slate50 底 + slate200 边 + 12 圆角，只为了圈住两行排期文字。
    // 去掉这层框之后，左侧 28dp 的着色图标块仍然是足够强的分区锚点，
    // 「标题 + 值」的两级排版也没变，信息一条没少；卡片纵向省下 20dp
    //（上下各 9dp 内边距 + 2dp 边框），并且图标块从此与上下两行左对齐。
    return SizedBox(
      width: double.infinity,
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: color.withAlpha(isLight ? 22 : 36),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: isLight ? AppColors.slate600 : AppColors.slate300,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    fontFamily: isCron ? 'monospace' : null,
                    color: isLight ? AppColors.slate800 : AppColors.slate100,
                  ),
                ),
              ],
            ),
          ),
          if (cleanExpressions.length > 1) ...[
            const SizedBox(width: 8),
            _TaskMiniCountChip(
              label: '+${cleanExpressions.length - 1}',
              isLight: isLight,
            ),
          ],
        ],
      ),
    );
  }
}

class _TaskSubscriptionSummary extends StatelessWidget {
  final List<String> labels;
  final bool isLight;

  const _TaskSubscriptionSummary({required this.labels, required this.isLight});

  @override
  Widget build(BuildContext context) {
    final visibleLabels = labels.take(3).toList();

    // 与上方排期块同一处理：任务卡自身已有 1px 边框，这里原本再套一层
    // 「白底 + slate200 边」，等于把边框画在同色底上 —— 浅色是白压白、
    // 深色是 slate900 压 slate900，全靠一条发丝线撑出一个盒子。
    // 也不能改走 subtle 淡底：里面的订阅标签本身就是 slate50 / slate800 底，
    // 外层一旦用同一档淡底，标签就会和外层糊成一片，等于把「同色套同色」
    // 往下挪一层。直接去框，让标签自己完成分组，纵向再省 18dp
    //（上下各 8dp 内边距 + 2dp 边框），并与排期块左对齐。
    return SizedBox(
      width: double.infinity,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: AppColors.blue500.withAlpha(isLight ? 18 : 30),
              borderRadius: BorderRadius.circular(999),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.sync_rounded, size: 13, color: AppColors.blue500),
                SizedBox(width: 4),
                Text(
                  '订阅',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: AppColors.blue500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ...visibleLabels.map(
                  (label) =>
                      _TaskSubscriptionChip(label: label, isLight: isLight),
                ),
                if (labels.length > visibleLabels.length)
                  _TaskMiniCountChip(
                    label: '+${labels.length - visibleLabels.length}',
                    isLight: isLight,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TaskSubscriptionChip extends StatelessWidget {
  final String label;
  final bool isLight;

  const _TaskSubscriptionChip({required this.label, required this.isLight});

  @override
  Widget build(BuildContext context) {
    // 订阅标签只做轻量展示，不再做成大胶囊，避免任务卡片显得拥挤。
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: isLight ? AppColors.slate50 : AppColors.slate800,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: isLight ? AppColors.slate200 : AppColors.slate700,
        ),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: isLight ? AppColors.slate600 : AppColors.slate300,
        ),
      ),
    );
  }
}

class _TaskMiniCountChip extends StatelessWidget {
  final String label;
  final bool isLight;

  const _TaskMiniCountChip({required this.label, required this.isLight});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: isLight ? AppColors.slate100 : AppColors.slate800,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          color: isLight ? AppColors.slate500 : AppColors.slate400,
        ),
      ),
    );
  }
}

class _TaskGroup {
  final String key;
  final String title;
  final List<Task> tasks = <Task>[];

  _TaskGroup({required this.key, required this.title});
}

String? _extractScriptPathFromCommand(String command) {
  final trimmed = command.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  final tokens = _splitCommandTokens(trimmed);
  if (tokens.isEmpty) {
    return null;
  }

  bool hasSupportedExtension(String value) {
    final lower = value.toLowerCase();
    return lower.endsWith('.py') ||
        lower.endsWith('.js') ||
        lower.endsWith('.ts') ||
        lower.endsWith('.sh') ||
        lower.endsWith('.go');
  }

  String? joinCandidate(List<String> items) {
    for (var count = items.length; count >= 1; count--) {
      final candidate = items.take(count).join(' ').trim();
      if (hasSupportedExtension(candidate)) {
        return candidate;
      }
    }
    return null;
  }

  switch (tokens.first) {
    case 'task':
    case 'desi':
      final rest = tokens.sublist(1);
      var idx = 0;
      while (idx < rest.length) {
        if (rest[idx] == '-m' && idx + 1 < rest.length) {
          idx += 2;
          continue;
        }
        if (rest[idx] == '-l') {
          idx += 1;
          continue;
        }
        break;
      }
      return joinCandidate(rest.sublist(idx));
    case 'python':
    case 'python3':
    case 'node':
    case 'ts-node':
    case 'bash':
    case 'go':
      if (tokens.length <= 1) {
        return null;
      }
      return joinCandidate(tokens.sublist(1));
    default:
      return null;
  }
}

List<String> _splitCommandTokens(String command) {
  final tokens = <String>[];
  final buffer = StringBuffer();
  String? quote;

  for (final rune in command.runes) {
    final char = String.fromCharCode(rune);
    if (quote != null) {
      if (char == quote) {
        quote = null;
      } else {
        buffer.write(char);
      }
      continue;
    }

    if (char == '"' || char == "'") {
      quote = char;
      continue;
    }

    if (char.trim().isEmpty) {
      if (buffer.isNotEmpty) {
        tokens.add(buffer.toString());
        buffer.clear();
      }
      continue;
    }

    buffer.write(char);
  }

  if (buffer.isNotEmpty) {
    tokens.add(buffer.toString());
  }

  return tokens;
}

class _MetaChip extends StatelessWidget {
  final String label;
  final bool active;

  const _MetaChip({required this.label, this.active = true});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;
    final background = active
        ? (isLight ? AppColors.slate50 : AppColors.slate800)
        : (isLight ? AppColors.slate100 : AppColors.slate900);
    final foreground = active
        ? (isLight ? AppColors.slate700 : AppColors.slate300)
        : AppColors.slate400;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: isLight ? AppColors.slate200 : AppColors.slate800,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: foreground,
            ),
          ),
        ],
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

class TaskDetailSheet extends StatelessWidget {
  final Task task;

  const TaskDetailSheet({super.key, required this.task});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;
    final labels = task.labelsForDisplay;
    final scheduleExpressions = task.cronExpressions.isNotEmpty
        ? task.cronExpressions
        : (task.cronExpression.trim().isNotEmpty
              ? [task.cronExpression.trim()]
              : const <String>[]);

    Widget infoTile(String label, Widget child, {bool expand = false}) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: isLight ? AppColors.slate100 : AppColors.slate800,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            if (expand) child else DefaultTextStyle.merge(child: child),
          ],
        ),
      );
    }

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.78,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '任务详情',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                task.name,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      infoTile(
                        '状态',
                        _MetaChip(
                          label: task.statusText,
                          active: !task.isDisabled,
                        ),
                      ),
                      infoTile(
                        '任务类型',
                        Text(
                          task.taskType == 'manual'
                              ? '手动运行'
                              : task.taskType == 'startup'
                              ? '开机运行'
                              : '常规定时',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      infoTile(
                        '定时规则',
                        task.taskType == 'cron'
                            ? TaskCronList(expressions: scheduleExpressions)
                            : Text(
                                '不使用 Cron',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                        expand: true,
                      ),
                      infoTile(
                        '执行命令',
                        SelectableText(
                          task.command,
                          style: const TextStyle(
                            fontSize: 12,
                            height: 1.5,
                            fontFamily: 'monospace',
                          ),
                        ),
                        expand: true,
                      ),
                      infoTile(
                        '标签',
                        labels.isEmpty
                            ? Text(
                                '无',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              )
                            : Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: labels
                                    .map((label) => _MetaChip(label: label))
                                    .toList(),
                              ),
                        expand: true,
                      ),
                      infoTile(
                        '上次运行',
                        Text(
                          task.lastRunAt == null
                              ? '-'
                              : formatTimeCn(task.lastRunAt),
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      infoTile(
                        '下次运行',
                        Text(
                          task.nextRunAt == null
                              ? '-'
                              : formatTimeCn(task.nextRunAt),
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      infoTile(
                        '上次结果',
                        Text(
                          task.lastRunStatus == null
                              ? '未运行'
                              : task.lastRunStatus == 0
                              ? '成功'
                              : '失败',
                          style: TextStyle(
                            fontSize: 13,
                            color: task.lastRunStatus == 1
                                ? AppColors.red500
                                : null,
                          ),
                        ),
                      ),
                      infoTile(
                        '最近耗时',
                        Text(
                          task.lastRunningTime == null
                              ? '-'
                              : '${task.lastRunningTime!.toStringAsFixed(2)}s',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
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

class _TaskLiveLogPageState extends ConsumerState<TaskLiveLogPage> {
  final ScrollController _scrollController = ScrollController();
  final _sseClient = SseClient();
  final _lines = <String>[];
  final _historyReplayBuffer = <String>[];
  bool _loading = true;
  bool _done = false;
  bool _autoScroll = true;
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
    _scrollController.dispose();
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

    setState(() {
      _loading = false;
      _lines
        ..clear()
        ..addAll(logs);
      _done = done && !shouldKeepPolling;
      _statusText = shouldKeepPolling
          ? '等待日志...'
          : _statusFromLiveTask(status, done: done);
    });

    if (_autoScroll && logs.isNotEmpty) {
      _scrollToBottom();
    }

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
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
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
        final data = extractData(resp.data);
        if (data is Map<String, dynamic>) {
          _applyLiveSnapshot(data);
        }
      } catch (_) {}

      if (_pollAttempts >= 15 && mounted && _statusText == '等待日志...') {
        _pollTimer?.cancel();
        _pollTimer = null;
        setState(() {
          _done = _lines.isNotEmpty;
          _statusText = _lines.isEmpty ? '暂无日志' : '已完成';
        });
      }
    });
  }

  void _connectSSE(int taskId) {
    _sseClient.close();
    _pollTimer?.cancel();
    _pollTimer = null;
    _historyReplayBuffer
      ..clear()
      ..addAll(_lines);
    _sseClient.connect(
      path: ApiEndpoints.logStream(taskId),
      autoReconnect: true,
      onEvent: (event) {
        if (!mounted) return;
        if (event.event == 'done') {
          if (event.data == 'reconnect') {
            setState(() {
              _done = false;
              _statusText = '运行中';
            });
            _historyReplayBuffer
              ..clear()
              ..addAll(_lines);
            return;
          }
          setState(() {
            _done = event.data == 'finished';
            _statusText = _statusFromStreamDone(event.data);
          });
          return;
        }
        final newLines = event.data.replaceAll('\r\n', '\n').split('\n');
        newLines.removeWhere((l) => l.isEmpty);
        if (newLines.isEmpty) return;
        final dedupedLines = _consumeReplayLines(newLines);
        if (dedupedLines.isEmpty) return;
        setState(() {
          _lines.addAll(dedupedLines);
          _done = false;
          _statusText = '运行中';
        });
        if (_autoScroll) _scrollToBottom();
      },
      onDone: () {
        if (!mounted) return;
        if (_done) return;
        setState(() => _statusText = '连接结束');
      },
      onError: (_) {
        if (!mounted) return;
        if (!_done) {
          setState(() => _statusText = '连接错误');
          _pollTimer?.cancel();
          _pollTimer = null;
          _startPolling();
        }
      },
    );
  }

  List<String> _consumeReplayLines(List<String> incomingLines) {
    if (_historyReplayBuffer.isEmpty) {
      return incomingLines;
    }

    final result = <String>[];
    for (final line in incomingLines) {
      if (_historyReplayBuffer.isNotEmpty &&
          line == _historyReplayBuffer.first) {
        _historyReplayBuffer.removeAt(0);
        continue;
      }

      _historyReplayBuffer.clear();
      result.add(line);
    }

    return result;
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
        return _lines.isEmpty ? '等待日志...' : '已完成';
    }
  }

  String _statusFromStreamDone(String value) {
    switch (value) {
      case 'finished':
        return '已完成';
      case 'timeout':
        return '等待日志...';
      case 'reconnect':
        return '运行中';
      default:
        return value;
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final title = (widget.taskName?.trim().isNotEmpty ?? false)
        ? '${widget.taskName} 运行日志'
        : '运行日志';
    final logTheme = resolveLogSurfaceTheme(_logBackgroundColor);
    final chipBackground = logTheme.brightness == Brightness.dark
        ? AppColors.slate800
        : AppColors.slate100;

    return Scaffold(
      backgroundColor: logTheme.background,
      appBar: AppBar(
        title: Text(title),
        backgroundColor: logTheme.background,
        foregroundColor: logTheme.foreground,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Chip(
              backgroundColor: chipBackground,
              label: Text(
                _statusText,
                style: TextStyle(fontSize: 11, color: logTheme.foreground),
              ),
              avatar: _done
                  ? Icon(Icons.check, size: 14, color: logTheme.foreground)
                  : SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: logTheme.foreground,
                      ),
                    ),
              visualDensity: VisualDensity.compact,
            ),
          ),
          if (_lines.isNotEmpty)
            IconButton(
              icon: Icon(Icons.copy, color: logTheme.foreground),
              tooltip: '复制全部',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _lines.join('\n')));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('日志已复制到剪贴板'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
            ),
          IconButton(
            icon: Icon(
              _autoScroll ? Icons.vertical_align_bottom : Icons.pause,
              color: _autoScroll ? AppColors.primary : logTheme.mutedForeground,
            ),
            tooltip: _autoScroll ? '自动滚动: 开' : '自动滚动: 关',
            onPressed: () {
              setState(() => _autoScroll = !_autoScroll);
              if (_autoScroll) _scrollToBottom();
            },
          ),
        ],
      ),
      body: Container(
        color: logTheme.background,
        child: _loading && _lines.isEmpty
            ? const Center(
                child: CircularProgressIndicator(color: AppColors.primary),
              )
            : _lines.isEmpty
            ? Center(
                child: Text(
                  _done ? '无日志内容' : '等待日志输出...',
                  style: TextStyle(color: logTheme.mutedForeground),
                ),
              )
            : Theme(
                data: Theme.of(context).copyWith(
                  textSelectionTheme: TextSelectionThemeData(
                    selectionColor: AppColors.primary.withAlpha(80),
                    selectionHandleColor: AppColors.primary,
                  ),
                ),
                child: Scrollbar(
                  controller: _scrollController,
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(12),
                    child: SelectableText.rich(
                      AnsiTextParser.buildTextSpan(
                        _lines.join('\n'),
                        baseStyle: TextStyle(
                          color: logTheme.foreground,
                          fontFamily: 'monospace',
                          fontSize: 12,
                          height: 1.6,
                        ),
                        brightness: logTheme.brightness,
                      ),
                      contextMenuBuilder: (context, editableTextState) {
                        return AdaptiveTextSelectionToolbar.editableText(
                          editableTextState: editableTextState,
                        );
                      },
                    ),
                  ),
                ),
              ),
      ),
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
      icon: Icon(Icons.more_vert, size: 18, color: AppColors.slate400),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
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
