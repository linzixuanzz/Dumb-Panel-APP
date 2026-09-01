import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/models/task_view.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/app_notice.dart';
import '../../../shared/widgets/app_snack.dart';
import '../../../shared/widgets/app_state_views.dart';
import '../providers/task_view_provider.dart';

/// 任务视图的选择面板与规则编辑器。
///
/// 单独成文件而不是继续堆进 `task_list_page.dart`：那个文件已经 3000 行，
/// 而这两块 UI 与任务列表本身没有耦合，只通过 [TaskViewPickerResult] 交互。

/// 选择面板的返回动作。
enum TaskViewPickerAction {
  /// 回到「全部任务」（清空规则）。
  selectAll,

  /// 选中某个视图。
  select,

  /// 去新建视图。
  create,

  /// 去编辑某个视图。
  edit,
}

class TaskViewPickerResult {
  final TaskViewPickerAction action;
  final TaskView? view;

  const TaskViewPickerResult(this.action, {this.view});
}

/// 打开视图选择面板。返回 null 表示用户直接关掉了面板。
Future<TaskViewPickerResult?> showTaskViewPicker(
  BuildContext context, {
  required int? selectedViewId,
}) {
  return showModalBottomSheet<TaskViewPickerResult>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) =>
        _TaskViewPickerSheet(selectedViewId: selectedViewId),
  );
}

/// 视图编辑器的结果。
class TaskViewEditorResult {
  /// 视图列表是否真的被改动过（新建 / 保存 / 删除）。
  final bool changed;

  /// 保存之后的视图。删除时为 null。
  final TaskView? view;

  const TaskViewEditorResult({required this.changed, this.view});
}

/// 打开视图编辑器。[view] 为 null 表示新建。
/// 返回 null 表示用户直接关掉了面板，什么都没改。
Future<TaskViewEditorResult?> showTaskViewEditor(
  BuildContext context, {
  TaskView? view,
}) {
  return showModalBottomSheet<TaskViewEditorResult>(
    context: context,
    // 规则行多起来会顶到键盘，必须让面板能占满高度并自己处理 viewInsets。
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => _TaskViewEditorSheet(view: view),
  );
}

class _TaskViewPickerSheet extends ConsumerWidget {
  const _TaskViewPickerSheet({required this.selectedViewId});

  final int? selectedViewId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(taskViewProvider);
    // 增删改要 operator，viewer 点了只会吃一个 403，所以入口直接不给。
    final canManage = ref.watch(authProvider).user?.isOperator ?? false;
    final views = state.visibleViews;

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(
            title: Text('选择任务视图'),
            subtitle: Text('视图规则保存在面板上，与网页端共用同一份'),
          ),
          if (state.loading && views.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
              child: AppLoadingView(topPadding: 0),
            )
          else if (state.error != null && views.isEmpty)
            AppErrorView(
              title: '视图加载失败',
              message: state.error!,
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.xxl,
                AppSpacing.lg,
                AppSpacing.xxl,
                AppSpacing.lg,
              ),
              onRetry: () => ref.read(taskViewProvider.notifier).load(),
            )
          else ...[
            ListTile(
              leading: const Icon(Icons.all_inbox_outlined),
              title: const Text('全部任务'),
              trailing: selectedViewId == null
                  ? const Icon(Icons.check, color: AppColors.primary)
                  : null,
              onTap: () => Navigator.pop(
                context,
                const TaskViewPickerResult(TaskViewPickerAction.selectAll),
              ),
            ),
            if (views.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.sm,
                ),
                child: AppNotice(
                  color: AppColors.info,
                  icon: Icons.filter_alt_outlined,
                  text: '面板上还没有任务视图。视图可以按命令、名称、定时规则、状态、标签、订阅等条件筛选任务。',
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: views.length,
                  itemBuilder: (context, index) {
                    final view = views[index];
                    final selected = view.id == selectedViewId;
                    return ListTile(
                      leading: const Icon(Icons.filter_alt_outlined),
                      title: Text(view.name),
                      subtitle: Text(
                        taskViewRuleSummary(view),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (selected)
                            const Icon(Icons.check, color: AppColors.primary),
                          if (canManage)
                            IconButton(
                              icon: const Icon(Icons.edit_outlined, size: 18),
                              tooltip: '编辑视图',
                              // 命中区靠约束撑到 44，不加 padding（会把行撑高）。
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: AppTapTarget.min,
                                minHeight: AppTapTarget.min,
                              ),
                              onPressed: () => Navigator.pop(
                                context,
                                TaskViewPickerResult(
                                  TaskViewPickerAction.edit,
                                  view: view,
                                ),
                              ),
                            ),
                        ],
                      ),
                      onTap: () => Navigator.pop(
                        context,
                        TaskViewPickerResult(
                          TaskViewPickerAction.select,
                          view: view,
                        ),
                      ),
                    );
                  },
                ),
              ),
            if (canManage) ...[
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.create_new_folder_outlined),
                title: const Text('新建视图'),
                subtitle: const Text('按命令、订阅等关键字自动筛选任务'),
                onTap: () => Navigator.pop(
                  context,
                  const TaskViewPickerResult(TaskViewPickerAction.create),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// 编辑器里一条规则的草稿。
///
/// [id] 只用来做 widget 的 key：删掉中间一行时，若不按稳定 id 匹配元素，
/// 下面那一行会复用上一行的下拉状态，出现「删了第一条，第二条显示成第一条的值」。
class _FilterDraft {
  _FilterDraft({
    required this.id,
    required this.field,
    required this.op,
    required String value,
  }) : valueController = TextEditingController(text: value);

  final int id;
  String field;
  String op;

  /// 值的唯一真源。status 的下拉也写回这里，避免两处状态各说各话。
  final TextEditingController valueController;
}

class _TaskViewEditorSheet extends ConsumerStatefulWidget {
  const _TaskViewEditorSheet({this.view});

  final TaskView? view;

  @override
  ConsumerState<_TaskViewEditorSheet> createState() =>
      _TaskViewEditorSheetState();
}

class _TaskViewEditorSheetState extends ConsumerState<_TaskViewEditorSheet> {
  late final TextEditingController _nameC;
  final List<_FilterDraft> _filters = [];

  /// 已经被删掉的规则行。
  ///
  /// 不能在删除那一刻就 `dispose()` 它的 controller：`setState` 只是排一次重建，
  /// 旧的 `TextField` 元素要到重建时才卸载，那时再去摘监听就会撞上
  /// 「A TextEditingController was used after being disposed」。统一留到 [dispose]。
  final List<_FilterDraft> _retiredFilters = [];

  /// 读进来了、但没进 UI 的排序规则（第二条起）。
  ///
  /// 保存时必须原样拼回去：面板的 UpdateView 收到非空 sort_rules 是整体覆盖，
  /// 而这张表全站共享 —— 丢掉它们等于替网页端所有人删了排序规则。
  /// 详见 [composeTaskViewSortRules]。
  final List<TaskViewSortRule> _extraSortRules = [];
  int _draftSeq = 0;
  String? _sortField;
  String _sortDirection = 'asc';
  bool _saving = false;

  bool get _isEditing => widget.view != null;

  @override
  void initState() {
    super.initState();
    final view = widget.view;
    _nameC = TextEditingController(text: view?.name ?? '');
    for (final filter in view?.filters ?? const <TaskViewFilter>[]) {
      // ⚠️ 必须过一遍归一：库里存得下 field / operator 为空串的脏规则，
      // 直接播种会让下拉的 value 在 items 里找不到匹配项，当场踩断言崩掉。
      final draft = normalizeTaskViewFilterDraft(filter);
      _filters.add(
        _FilterDraft(
          id: _draftSeq++,
          field: draft.field,
          op: draft.op,
          value: draft.value,
        ),
      );
    }
    if (_filters.isEmpty) {
      _filters.add(_newDraft());
    }
    // 面板允许多条排序规则做 tie-break，手机上只暴露第一条（小屏摆一串排序行
    // 吃掉的高度远大于收益）。**没进 UI 的那些必须原样留着**，保存时拼回去。
    final sort = splitTaskViewSortRules(
      view?.sortRules ?? const <TaskViewSortRule>[],
    );
    final edited = sort.edited;
    if (edited != null) {
      _sortField = edited.field;
      _sortDirection = edited.direction;
    }
    _extraSortRules.addAll(sort.extras);
  }

  @override
  void dispose() {
    _nameC.dispose();
    for (final draft in [..._filters, ..._retiredFilters]) {
      draft.valueController.dispose();
    }
    super.dispose();
  }

  _FilterDraft _newDraft() => _FilterDraft(
    id: _draftSeq++,
    field: kTaskViewFilterFields.first.value,
    op: kTaskViewOperators.first.value,
    value: '',
  );

  List<TaskViewFilter> get _usableFilters => _filters
      .map(
        (draft) => TaskViewFilter(
          field: draft.field,
          op: draft.op,
          value: draft.valueController.text.trim(),
        ),
      )
      .where((filter) => filter.isUsable)
      .toList();

  List<TaskViewSortRule> get _usableSortRules => composeTaskViewSortRules(
    editedField: _sortField,
    editedDirection: _sortDirection,
    extraRules: _extraSortRules,
  );

  Future<void> _save() async {
    final name = _nameC.text.trim();
    if (name.isEmpty) {
      // 校验没过不是请求出错，用 warn。
      AppSnack.warn(context, '请输入视图名称');
      return;
    }
    setState(() => _saving = true);
    try {
      final notifier = ref.read(taskViewProvider.notifier);
      final view = widget.view;
      TaskView? saved;
      if (view == null) {
        await notifier.create(
          name: name,
          filters: _usableFilters,
          sortRules: _usableSortRules,
        );
        // create 不回传新建的记录，只能在重拉后的列表里按名字找回来。
        // 视图名在面板上是全局唯一索引，所以这个匹配是精确的。
        saved = _findViewByName(name);
      } else {
        await notifier.update(
          id: view.id,
          name: name,
          filters: _usableFilters,
          sortRules: _usableSortRules,
        );
        saved = ref.read(taskViewProvider).viewById(view.id);
      }
      if (!mounted) {
        return;
      }
      Navigator.pop(
        context,
        TaskViewEditorResult(changed: true, view: saved),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _saving = false);
      // 同名会被服务端拒（「同名任务视图已存在」），把原文透出来，
      // 不要笼统地说「保存失败」——用户改个名字就能过。
      AppSnack.error(context, extractErrorMessage(error, '保存视图失败'));
    }
  }

  TaskView? _findViewByName(String name) {
    for (final item in ref.read(taskViewProvider).views) {
      if (item.name == name) {
        return item;
      }
    }
    return null;
  }

  Future<void> _delete() async {
    final view = widget.view;
    if (view == null) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除视图'),
        content: Text('确定删除视图「${view.name}」吗？视图对所有用户可见，删除后其他人也会看不到。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!mounted) {
      return;
    }
    if (confirmed != true) {
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(taskViewProvider.notifier).delete(view.id);
      if (!mounted) {
        return;
      }
      Navigator.pop(context, const TaskViewEditorResult(changed: true));
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _saving = false);
      AppSnack.error(context, extractErrorMessage(error, '删除视图失败'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      // 键盘弹起时把面板整体顶上去，否则值输入框会被挡住。
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.85,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(_isEditing ? '编辑视图' : '新建视图'),
                subtitle: const Text('规则之间是「且」的关系，筛选与排序都由面板完成'),
              ),
              Flexible(child: SingleChildScrollView(child: _buildForm())),
              const Divider(height: 1),
              _buildActions(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildForm() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.sm,
        AppSpacing.xl,
        AppSpacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AppNotice(
            color: AppColors.warning,
            icon: Icons.groups_outlined,
            text: '任务视图对所有用户可见，也会同步到网页端。在这里的改动会影响面板上的其他人。',
          ),
          const SizedBox(height: AppSpacing.lg),
          TextField(
            controller: _nameC,
            decoration: const InputDecoration(
              labelText: '视图名称',
              hintText: '例如 京东 / 每日签到 / 待排查',
            ),
            style: const TextStyle(fontSize: 14),
          ),
          const SizedBox(height: AppSpacing.lg),
          const Text(
            '筛选规则',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: AppSpacing.sm),
          for (final draft in _filters)
            Padding(
              key: ValueKey('task-view-filter-${draft.id}'),
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: _buildFilterRow(draft),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _saving
                  ? null
                  : () => setState(() => _filters.add(_newDraft())),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('添加规则'),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          const Text(
            '排序',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: AppSpacing.sm),
          _buildSortRow(),
        ],
      ),
    );
  }

  bool _isKnownStatusValue(_FilterDraft draft) => kTaskViewStatusValues.any(
    (option) => option.value == draft.valueController.text,
  );

  Widget _buildFilterRow(_FilterDraft draft) {
    final surfaces = context.surfaces;
    final isStatus = draft.field == 'status';
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      radius: AppRadius.md,
      color: surfaces.subtle,
      borderColor: surfaces.subtleBorder,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _buildDropdown(
                  label: '字段',
                  value: draft.field,
                  options: kTaskViewFilterFields,
                  onChanged: (value) => setState(() {
                    draft.field = value;
                    // 换到「状态」时，之前输入的自由文本几乎肯定不是那四个数值串之一。
                    // 留着会变成一条「下拉看着没选、提交时却带着值」的规则，直接清掉。
                    if (value == 'status' && !_isKnownStatusValue(draft)) {
                      draft.valueController.clear();
                    }
                  }),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: _buildDropdown(
                  label: '条件',
                  value: draft.op,
                  options: kTaskViewOperators,
                  onChanged: (value) => setState(() => draft.op = value),
                ),
              ),
              const SizedBox(width: AppSpacing.xxs),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                tooltip: '删除这条规则',
                color: surfaces.mutedText,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                  minWidth: AppTapTarget.min,
                  minHeight: AppTapTarget.min,
                ),
                onPressed: _saving
                    ? null
                    : () => setState(() {
                        _filters.remove(draft);
                        _retiredFilters.add(draft);
                      }),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          if (isStatus)
            _buildDropdown(
              label: '状态',
              // 认不出来时先空着，强迫用户显式选一个，而不是偷偷替他挑一个。
              value: _isKnownStatusValue(draft)
                  ? draft.valueController.text
                  : null,
              hint: '选择状态',
              options: kTaskViewStatusValues,
              onChanged: (value) =>
                  setState(() => draft.valueController.text = value),
            )
          else
            TextField(
              controller: draft.valueController,
              decoration: const InputDecoration(
                labelText: '值',
                hintText: '例如 jd_bean',
                isDense: true,
              ),
              style: const TextStyle(fontSize: 14),
            ),
        ],
      ),
    );
  }

  Widget _buildSortRow() {
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: _buildDropdown(
            label: '排序字段',
            value: _sortField ?? '',
            options: kTaskViewSortFields,
            // 「默认顺序」必须是一个能选回来的选项，否则用户一旦设了排序
            // 就再也去不掉了。空串在提交时会被 [_usableSortRules] 过滤成不排序。
            emptyOption: const TaskViewOption('', '默认顺序'),
            onChanged: (value) =>
                setState(() => _sortField = value.isEmpty ? null : value),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          flex: 2,
          child: _buildDropdown(
            label: '方向',
            value: _sortDirection,
            options: const [
              TaskViewOption('asc', '正序'),
              TaskViewOption('desc', '倒序'),
            ],
            onChanged: (value) => setState(() => _sortDirection = value),
          ),
        ),
      ],
    );
  }

  /// 受控下拉。
  ///
  /// 刻意不用 `DropdownButtonFormField`：那个是 `FormField`，值由它自己的
  /// State 持有，而这里的值全都存在草稿对象里，两套状态很容易对不上。
  Widget _buildDropdown({
    required String label,
    required String? value,
    required List<TaskViewOption> options,
    required ValueChanged<String> onChanged,
    String? hint,
    TaskViewOption? emptyOption,
  }) {
    final items = <TaskViewOption>[?emptyOption, ...options];
    // `DropdownButton` 断言 items 里必须**恰好一项**等于 value，否则运行时直接崩。
    // 面板日后加一个新字段 / 新运算符，老 APP 打开那条视图就会撞上这一条 ——
    // 所以把认不出来的值原样补进选项里，诚实显示，而不是偷偷替换成第一项。
    // 空串同样要补：脏数据里 field / operator 缺项是真实存在的，
    // 这里少一道兜底就是「一按编辑就红屏」。播种侧已经归一过，这条是第二层保险。
    if (value != null && !items.any((option) => option.value == value)) {
      items.add(TaskViewOption(value, value.isEmpty ? '（未设置）' : value));
    }
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.md,
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          isDense: true,
          hint: hint == null
              ? null
              : Text(hint, style: const TextStyle(fontSize: 14)),
          style: TextStyle(fontSize: 14, color: context.surfaces.strongText),
          items: items
              .map(
                (option) => DropdownMenuItem(
                  value: option.value,
                  child: Text(option.label, overflow: TextOverflow.ellipsis),
                ),
              )
              .toList(),
          onChanged: _saving
              ? null
              : (selected) {
                  if (selected != null) {
                    onChanged(selected);
                  }
                },
        ),
      ),
    );
  }

  Widget _buildActions() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      child: Row(
        children: [
          if (_isEditing)
            TextButton.icon(
              onPressed: _saving ? null : _delete,
              icon: const Icon(Icons.delete_outline, size: 16),
              style: TextButton.styleFrom(foregroundColor: AppColors.danger),
              label: const Text('删除'),
            ),
          const Spacer(),
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          const SizedBox(width: AppSpacing.sm),
          FilledButton(
            onPressed: _saving ? null : _save,
            style: FilledButton.styleFrom(minimumSize: const Size(80, 38)),
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('保存'),
          ),
        ],
      ),
    );
  }
}
