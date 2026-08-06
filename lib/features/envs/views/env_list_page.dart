import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/models/env_var.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/widgets/app_buttons.dart';
import '../../../shared/widgets/app_state_views.dart';

final envListProvider = StateNotifierProvider<EnvListNotifier, EnvListState>((
  ref,
) {
  return EnvListNotifier();
});

const _selectedGroupUnset = Object();

enum _EnvBatchAction { enable, disable, delete }

class EnvListState {
  final List<EnvVar> envs;
  final int total;
  final bool loading;
  final List<String> groups;
  final List<String> selectedGroups;
  final String keyword;

  /// 加载失败原因。为 null 表示这次请求成功了 —— UI 必须靠它区分
  /// 「面板里真的一个变量都没有」和「压根没拿到数据」。
  final String? error;

  const EnvListState({
    this.envs = const [],
    this.total = 0,
    this.loading = false,
    this.groups = const [],
    this.selectedGroups = const [],
    this.keyword = '',
    this.error,
  });

  EnvListState copyWith({
    List<EnvVar>? envs,
    int? total,
    bool? loading,
    List<String>? groups,
    Object? selectedGroups = _selectedGroupUnset,
    String? keyword,
    String? error,
  }) {
    return EnvListState(
      envs: envs ?? this.envs,
      total: total ?? this.total,
      loading: loading ?? this.loading,
      groups: groups ?? this.groups,
      selectedGroups: identical(selectedGroups, _selectedGroupUnset)
          ? this.selectedGroups
          : selectedGroups as List<String>,
      keyword: keyword ?? this.keyword,
      // ⚠️ 这里**故意不写** `error ?? this.error`。
      // 语义选的是 TaskListState（task_provider.dart:43）那一套：
      // 任何不显式传 error 的 copyWith 都会清空错误，于是每次新请求
      // （load 开头的 copyWith(loading: true)）自动把上次的错误抹掉，
      // 不需要到处补 error: null。
      // 仓库里还有相反的一套（AuthState 用 _authFieldUnset 哨兵保留旧值），
      // 两种语义并存；这个 State 明确选前者，改成 `??` 会让错误提示永远不消失。
      error: error,
    );
  }
}

class EnvListNotifier extends StateNotifier<EnvListState> {
  EnvListNotifier() : super(const EnvListState());

  Future<void> load() async {
    state = state.copyWith(loading: true, error: null);
    try {
      final dio = DioClient.instance.dio;
      // The panel backend caps page_size at 100. Requesting a larger value
      // silently falls back to 20, which previously made the app stop after 40 rows.
      const pageSize = 100;
      final params = <String, dynamic>{'page': 1, 'page_size': pageSize};
      if (state.selectedGroups.isNotEmpty) {
        params['groups'] = state.selectedGroups.join(',');
      }
      if (state.keyword.isNotEmpty) {
        params['keyword'] = state.keyword;
      }

      final firstPageFuture = dio.get(
        ApiEndpoints.envs,
        queryParameters: params,
      );
      // 分组列表是辅助数据。收紧 validateStatus 后它的 4xx（例如非管理员角色被 403）
      // 会让 Future.wait 整体失败，把已经取到的变量列表一起打成「加载失败」。
      // 两个请求仍然并发发出，但分组失败只降级成空分组。
      final groupsFuture = _fetchGroups();
      final firstPageResponse = await firstPageFuture;
      final groups = await groupsFuture;

      final paginated = extractPaginated(firstPageResponse.data);
      final allItems = <Map<String, dynamic>>[...paginated.items];
      var page = 2;
      while (allItems.length < paginated.total) {
        final nextResponse = await dio.get(
          ApiEndpoints.envs,
          queryParameters: {...params, 'page': page},
        );
        final nextPage = extractPaginated(nextResponse.data);
        if (nextPage.items.isEmpty) {
          break;
        }
        allItems.addAll(nextPage.items);
        page++;
      }

      final items = allItems.map((e) => EnvVar.fromJson(e)).toList();
      state = state.copyWith(
        envs: items,
        total: paginated.total > items.length ? paginated.total : items.length,
        loading: false,
        groups: groups,
      );
    } catch (e) {
      // 原来这里只写 copyWith(loading: false)，错误被完全吞掉，
      // 页面退化成「暂无环境变量」，用户分不清是没数据还是拿不到数据。
      state = state.copyWith(
        loading: false,
        error: extractListErrorMessage(e, '加载环境变量失败'),
      );
    }
  }

  /// 取分组列表。失败不抛：分组只用于筛选条，拿不到就当没有分组，
  /// 不能因此把整个环境变量列表判成加载失败。
  Future<List<String>> _fetchGroups() async {
    try {
      final response = await DioClient.instance.dio.get(
        ApiEndpoints.envsGroups,
      );
      final raw = response.data;
      final List list;
      if (raw is List) {
        list = raw;
      } else if (raw is Map && raw['data'] is List) {
        list = raw['data'] as List;
      } else {
        list = const [];
      }
      return list.map((e) => e.toString()).toList();
    } catch (_) {
      return const [];
    }
  }

  void setGroups(List<String> groups) {
    state = state.copyWith(selectedGroups: groups);
    load();
  }

  void setKeyword(String keyword) {
    state = state.copyWith(keyword: keyword);
    load();
  }

  Future<void> toggle(int id, bool enabled) async {
    final dio = DioClient.instance.dio;
    if (enabled) {
      await dio.put(ApiEndpoints.envEnable(id));
    } else {
      await dio.put(ApiEndpoints.envDisable(id));
    }
    await load();
  }

  Future<void> delete(int id) async {
    await DioClient.instance.dio.delete(ApiEndpoints.envById(id));
    await load();
  }

  Future<void> batchDelete(List<int> ids) async {
    await DioClient.instance.dio.delete(
      ApiEndpoints.envsBatchDelete,
      data: {'ids': ids},
    );
    await load();
  }

  Future<void> batchEnable(List<int> ids) async {
    await DioClient.instance.dio.put(
      ApiEndpoints.envsBatchEnable,
      data: {'ids': ids},
    );
    await load();
  }

  Future<void> batchDisable(List<int> ids) async {
    await DioClient.instance.dio.put(
      ApiEndpoints.envsBatchDisable,
      data: {'ids': ids},
    );
    await load();
  }

  Future<void> batchSetGroup(List<int> ids, List<String> groups) async {
    await DioClient.instance.dio.put(
      ApiEndpoints.envsBatchGroup,
      data: {'ids': ids, 'groups': groups},
    );
    await load();
  }

  Future<void> create(
    String name,
    String value, {
    String remarks = '',
    List<String> groups = const [],
  }) async {
    await DioClient.instance.dio.post(
      ApiEndpoints.envs,
      data: {
        'name': name,
        'value': value,
        'remarks': remarks,
        'group': groups.join(','),
        'groups': groups,
      },
    );
    await load();
  }

  Future<void> update(
    int id,
    String name,
    String value, {
    String remarks = '',
    List<String> groups = const [],
  }) async {
    await DioClient.instance.dio.put(
      ApiEndpoints.envById(id),
      data: {
        'name': name,
        'value': value,
        'remarks': remarks,
        'group': groups.join(','),
        'groups': groups,
      },
    );
    await load();
  }

  Future<void> sortEnvs(int sourceId, int? targetId) async {
    await DioClient.instance.dio.put(
      ApiEndpoints.envsSort,
      data: {'source_id': sourceId, 'target_id': targetId},
    );
    await load();
  }

  void reorderLocal(int oldIndex, int newIndex) {
    final items = List<EnvVar>.from(state.envs);
    if (newIndex > oldIndex) newIndex--;
    final item = items.removeAt(oldIndex);
    items.insert(newIndex, item);
    state = state.copyWith(envs: items);
  }
}

class EnvListPage extends ConsumerStatefulWidget {
  const EnvListPage({super.key});

  @override
  ConsumerState<EnvListPage> createState() => _EnvListPageState();
}

class _EnvListPageState extends ConsumerState<EnvListPage> {
  final _searchController = TextEditingController();
  final Set<int> _selectedIds = <int>{};
  Timer? _debounce;

  bool _selectionMode = false;
  bool _sortMode = false;
  int? _lastMovedSourceId;
  int? _lastMovedTargetId;

  Widget _buildGroupAutocomplete({
    required TextEditingController controller,
    required List<String> options,
  }) {
    return Autocomplete<String>(
      optionsBuilder: (textEditingValue) {
        final keyword = textEditingValue.text.trim().toLowerCase();
        if (keyword.isEmpty) {
          return options;
        }
        return options.where((group) => group.toLowerCase().contains(keyword));
      },
      onSelected: (value) => controller.text = value,
      fieldViewBuilder:
          (context, textEditingController, focusNode, onSubmitted) {
            textEditingController.value = controller.value;
            textEditingController.addListener(() {
              controller.value = textEditingController.value;
            });
            return TextField(
              controller: textEditingController,
              focusNode: focusNode,
              decoration: const InputDecoration(
                labelText: '分组',
                hintText: '可选已有分组或直接输入',
              ),
              onSubmitted: (_) => onSubmitted(),
            );
          },
      optionsViewBuilder: (context, onSelected, autocompleteOptions) {
        final items = autocompleteOptions.toList(growable: false);
        if (items.isEmpty) {
          return const SizedBox.shrink();
        }
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            // 全库仅有的两处「阴影是唯一分隔物」之一：这层浮层直接盖在表单上，
            // 去掉 elevation 必须同时补底色与边框，否则与下方表单糊在一起。
            // 注意 shape 与 borderRadius 互斥（同时传会在运行时 assert），
            // 所以原来那行 borderRadius 已删除，圆角改由 shape 承载。
            elevation: 0,
            color: context.surfaces.card,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
              side: BorderSide(color: context.surfaces.cardBorder),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220, maxWidth: 280),
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                shrinkWrap: true,
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final group = items[index];
                  return ListTile(
                    dense: true,
                    title: Text(group),
                    onTap: () => onSelected(group),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  List<String> _normalizeGroups(Iterable<String> values) {
    final seen = <String>{};
    final result = <String>[];
    for (final raw in values) {
      for (final group in raw.split(',')) {
        final trimmed = group.trim();
        if (trimmed.isEmpty || seen.contains(trimmed)) {
          continue;
        }
        seen.add(trimmed);
        result.add(trimmed);
      }
    }
    return result;
  }

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(envListProvider.notifier).load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  bool _isSelected(int id) => _selectedIds.contains(id);

  bool _isAllSelected(List<EnvVar> envs) =>
      envs.isNotEmpty && envs.every((env) => _selectedIds.contains(env.id));

  void _setSelectionMode(bool enabled) {
    setState(() {
      _selectionMode = enabled;
      if (!enabled) {
        _selectedIds.clear();
      }
    });
  }

  void _toggleSelection(int id) {
    setState(() {
      _selectionMode = true;
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
      if (_selectedIds.isEmpty) {
        _selectionMode = false;
      }
    });
  }

  void _toggleSelectAll(List<EnvVar> envs) {
    final visibleIds = envs.map((env) => env.id).toSet();
    setState(() {
      if (visibleIds.isNotEmpty &&
          visibleIds.every((id) => _selectedIds.contains(id))) {
        _selectedIds.removeAll(visibleIds);
        if (_selectedIds.isEmpty) {
          _selectionMode = false;
        }
      } else {
        _selectionMode = true;
        _selectedIds.addAll(visibleIds);
      }
    });
  }

  Future<bool> _confirmBatchDelete(int count) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('批量删除'),
        content: Text('确定删除选中的 $count 个环境变量吗？'),
        actions: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(dialogCtx).pop(false),
                    child: const Text('取消'),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: FilledButton(
                    onPressed: () => Navigator.of(dialogCtx).pop(true),
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

  Future<bool> _confirmDelete(EnvVar env) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('删除环境变量'),
        content: Text('确定删除「${env.name}」吗？删除后无法恢复。'),
        actions: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(dialogCtx).pop(false),
                    child: const Text('取消'),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: FilledButton(
                    onPressed: () => Navigator.of(dialogCtx).pop(true),
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

  Future<void> _setEnvEnabled(EnvVar env, bool enabled) async {
    if (env.enabled == enabled) {
      return;
    }

    try {
      await ref.read(envListProvider.notifier).toggle(env.id, enabled);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(enabled ? '已启用 ${env.name}' : '已禁用 ${env.name}'),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(extractErrorMessage(error, '修改环境变量状态失败'))),
      );
    }
  }

  Future<void> _deleteEnv(EnvVar env) async {
    final confirmed = await _confirmDelete(env);
    if (!confirmed || !mounted) {
      return;
    }

    try {
      await ref.read(envListProvider.notifier).delete(env.id);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已删除 ${env.name}')));
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(extractErrorMessage(error, '删除环境变量失败'))),
      );
    }
  }

  Future<void> _performBatchAction(_EnvBatchAction action) async {
    final ids = _selectedIds.toList()..sort();
    if (ids.isEmpty) {
      return;
    }

    if (action == _EnvBatchAction.delete) {
      final confirmed = await _confirmBatchDelete(ids.length);
      if (!confirmed) {
        return;
      }
    }

    try {
      final notifier = ref.read(envListProvider.notifier);
      switch (action) {
        case _EnvBatchAction.enable:
          await notifier.batchEnable(ids);
          break;
        case _EnvBatchAction.disable:
          await notifier.batchDisable(ids);
          break;
        case _EnvBatchAction.delete:
          await notifier.batchDelete(ids);
          break;
      }

      if (!mounted) {
        return;
      }

      _setSelectionMode(false);
      final message = switch (action) {
        _EnvBatchAction.enable => '已批量启用 ${ids.length} 个环境变量',
        _EnvBatchAction.disable => '已批量禁用 ${ids.length} 个环境变量',
        _EnvBatchAction.delete => '已批量删除 ${ids.length} 个环境变量',
      };
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('批量操作失败，请稍后重试')));
    }
  }

  Future<void> _performBatchGroup(List<String> groups) async {
    final ids = _selectedIds.toList()..sort();
    if (ids.isEmpty) {
      return;
    }

    try {
      await ref.read(envListProvider.notifier).batchSetGroup(ids, groups);
      if (!mounted) {
        return;
      }

      _setSelectionMode(false);
      final message = groups.isEmpty
          ? '已清空 ${ids.length} 个环境变量的分组'
          : '已将 ${ids.length} 个环境变量分组到“${groups.join(' / ')}”';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('批量分组失败，请稍后重试')));
    }
  }

  Future<void> _showBatchGroupDialog(List<String> groups) async {
    if (_selectedIds.isEmpty) {
      return;
    }

    final controller = TextEditingController();
    final selectedGroups = <String>{};
    final result = await showDialog<List<String>>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('批量分组'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('将已选择的 ${_selectedIds.length} 个环境变量设置到同一分组。'),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  decoration: const InputDecoration(
                    labelText: '分组名称',
                    hintText: '输入多个分组，逗号分隔',
                  ),
                  onChanged: (_) => setDialogState(() {}),
                ),
                if (groups.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  const Text(
                    '已有分组',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: groups
                        .map(
                          (group) => ActionChip(
                            label: Text(group),
                            onPressed: () {
                              if (selectedGroups.contains(group)) {
                                selectedGroups.remove(group);
                              } else {
                                selectedGroups.add(group);
                              }
                              final merged = _normalizeGroups([
                                controller.text,
                                ...selectedGroups,
                              ]);
                              controller.text = merged.join(', ');
                              controller.selection = TextSelection.fromPosition(
                                TextPosition(offset: controller.text.length),
                              );
                              setDialogState(() {});
                            },
                          ),
                        )
                        .toList(),
                  ),
                ],
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
                      onPressed: () => Navigator.of(dialogCtx).pop(),
                      child: const Text('取消'),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(dialogCtx).pop(const []),
                      child: const Text('清空分组'),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: FilledButton(
                      onPressed: () => Navigator.of(dialogCtx).pop(
                        _normalizeGroups([controller.text, ...selectedGroups]),
                      ),
                      child: const Text('确认'),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    if (!mounted || result == null) {
      return;
    }

    await _performBatchGroup(result);
  }

  Future<void> _refresh() async {
    if (_selectionMode) {
      _setSelectionMode(false);
    }
    await ref.read(envListProvider.notifier).load();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(envListProvider);
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;
    final messenger = ScaffoldMessenger.of(context);
    final selectedCount = _selectedIds.length;
    final allSelected = _isAllSelected(state.envs);

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
                    '环境变量',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                  ),
                  Row(
                    children: [
                      if (!_sortMode)
                        AppChipButton(
                          label: _selectionMode ? '取消' : '批量',
                          icon: _selectionMode ? Icons.close : Icons.done_all,
                          onTap: () => _setSelectionMode(!_selectionMode),
                        ),
                      if (!_selectionMode) ...[
                        const SizedBox(width: 8),
                        AppChipButton(
                          label: _sortMode ? '完成' : '排序',
                          icon: _sortMode ? Icons.check : Icons.swap_vert,
                          onTap: () async {
                            if (_sortMode) {
                              try {
                                if (_lastMovedSourceId != null) {
                                  await ref
                                      .read(envListProvider.notifier)
                                      .sortEnvs(
                                        _lastMovedSourceId!,
                                        _lastMovedTargetId,
                                      );
                                }
                                if (mounted) {
                                  messenger.showSnackBar(
                                    const SnackBar(content: Text('排序已保存')),
                                  );
                                }
                              } catch (error) {
                                if (mounted) {
                                  messenger.showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        extractErrorMessage(error, '保存排序失败'),
                                      ),
                                    ),
                                  );
                                }
                              }
                            }
                            setState(() {
                              _sortMode = !_sortMode;
                              if (!_sortMode) {
                                _lastMovedSourceId = null;
                                _lastMovedTargetId = null;
                              }
                            });
                          },
                        ),
                      ],
                      if (!_selectionMode && !_sortMode) ...[
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () => _showCreateDialog(),
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
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: TextField(
                        controller: _searchController,
                        decoration: InputDecoration(
                          hintText: '搜索变量...',
                          prefixIcon: const Icon(
                            Icons.search,
                            size: 18,
                            color: AppColors.slate400,
                          ),
                          filled: true,
                          fillColor: isLight
                              ? Colors.white
                              : AppColors.slate900,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: isLight
                                  ? AppColors.slate200
                                  : AppColors.slate800,
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: isLight
                                  ? AppColors.slate200
                                  : AppColors.slate800,
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                              color: AppColors.primary,
                              width: 1.5,
                            ),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 12,
                          ),
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
                                    if (_selectionMode) {
                                      _setSelectionMode(false);
                                    }
                                    ref
                                        .read(envListProvider.notifier)
                                        .setKeyword('');
                                  },
                                )
                              : null,
                        ),
                        style: const TextStyle(fontSize: 14),
                        onChanged: (v) {
                          setState(() {});
                          if (_selectionMode) {
                            _setSelectionMode(false);
                          }
                          _debounce?.cancel();
                          _debounce = Timer(
                            const Duration(milliseconds: 300),
                            () {
                              ref.read(envListProvider.notifier).setKeyword(v);
                            },
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  PopupMenuButton<String>(
                    tooltip: '筛选分组',
                    onSelected: (value) {
                      if (_selectionMode) {
                        _setSelectionMode(false);
                      }
                      if (value == '__all__') {
                        ref.read(envListProvider.notifier).setGroups(const []);
                        return;
                      }
                      final current = [...state.selectedGroups];
                      if (current.contains(value)) {
                        current.remove(value);
                      } else {
                        current.add(value);
                      }
                      ref
                          .read(envListProvider.notifier)
                          .setGroups(_normalizeGroups(current));
                    },
                    itemBuilder: (_) => [
                      CheckedPopupMenuItem<String>(
                        value: '__all__',
                        checked: state.selectedGroups.isEmpty,
                        child: const Text('全部'),
                      ),
                      ...state.groups.map(
                        (g) => CheckedPopupMenuItem<String>(
                          value: g,
                          checked: state.selectedGroups.contains(g),
                          child: Text(g),
                        ),
                      ),
                    ],
                    child: Container(
                      height: 44,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: isLight ? Colors.white : AppColors.slate900,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isLight
                              ? AppColors.slate200
                              : AppColors.slate800,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.label_outline,
                            size: 18,
                            color: AppColors.slate400,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            state.selectedGroups.isEmpty
                                ? '全部'
                                : state.selectedGroups.join(' / '),
                            style: TextStyle(
                              fontSize: 13,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Icon(
                            Icons.expand_more,
                            size: 18,
                            color: AppColors.slate400,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_selectionMode) ...[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isLight ? Colors.white : AppColors.slate900,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isLight ? AppColors.slate200 : AppColors.slate800,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            '已选择 $selectedCount 项',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: () => _toggleSelectAll(state.envs),
                            child: Text(allSelected ? '取消全选' : '全选'),
                          ),
                        ],
                      ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          AppTintedActionButton(
                            label: '批量分组',
                            icon: Icons.label_outline,
                            color: AppColors.blue500,
                            enabled: selectedCount > 0,
                            onTap: () => _showBatchGroupDialog(state.groups),
                          ),
                          AppTintedActionButton(
                            label: '批量启用',
                            icon: Icons.play_circle_outline,
                            color: AppColors.primary,
                            enabled: selectedCount > 0,
                            onTap: () =>
                                _performBatchAction(_EnvBatchAction.enable),
                          ),
                          AppTintedActionButton(
                            label: '批量禁用',
                            icon: Icons.pause_circle_outline,
                            color: AppColors.slate500,
                            enabled: selectedCount > 0,
                            onTap: () =>
                                _performBatchAction(_EnvBatchAction.disable),
                          ),
                          AppTintedActionButton(
                            label: '批量删除',
                            icon: Icons.delete_outline,
                            color: AppColors.red500,
                            enabled: selectedCount > 0,
                            onTap: () =>
                                _performBatchAction(_EnvBatchAction.delete),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (_sortMode) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: isLight
                        ? AppColors.primary.withAlpha(12)
                        : AppColors.primary.withAlpha(20),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.primary.withAlpha(40)),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.swap_vert,
                        size: 16,
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          '长按拖拽调整顺序，点击「完成」保存',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.primary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: RefreshIndicator(
                color: AppColors.primary,
                onRefresh: _refresh,
                child: state.loading && state.envs.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: const [AppLoadingView()],
                      )
                    // 拿不到数据和真的没有数据是两回事，必须先判 error。
                    : state.error != null && state.envs.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          AppErrorView(
                            title: '环境变量加载失败',
                            message: state.error!,
                            onRetry: _refresh,
                          ),
                        ],
                      )
                    : state.envs.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: const [
                          AppEmptyView(
                            icon: Icons.key_off,
                            message: '暂无环境变量',
                          ),
                        ],
                      )
                    : _sortMode
                    ? ReorderableListView.builder(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
                        itemCount: state.envs.length,
                        onReorder: (oldIndex, newIndex) {
                          final current = List<EnvVar>.from(state.envs);
                          if (current.isEmpty || oldIndex >= current.length) {
                            return;
                          }
                          final sourceEnv = current[oldIndex];
                          final adjustedNewIndex = newIndex > oldIndex
                              ? newIndex - 1
                              : newIndex;
                          int? targetId;
                          if (adjustedNewIndex > 0 &&
                              adjustedNewIndex - 1 < current.length) {
                            final targetSourceIndex =
                                adjustedNewIndex > oldIndex
                                ? adjustedNewIndex
                                : adjustedNewIndex - 1;
                            if (targetSourceIndex >= 0 &&
                                targetSourceIndex < current.length) {
                              targetId = current[targetSourceIndex].id;
                            }
                          }
                          ref
                              .read(envListProvider.notifier)
                              .reorderLocal(oldIndex, newIndex);
                          setState(() {
                            _lastMovedSourceId = sourceEnv.id;
                            _lastMovedTargetId = targetId;
                          });
                        },
                        itemBuilder: (_, i) {
                          final env = state.envs[i];
                          return Container(
                            key: ValueKey(env.id),
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 14,
                            ),
                            decoration: BoxDecoration(
                              color: isLight
                                  ? Colors.white
                                  : AppColors.slate900,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: isLight
                                    ? AppColors.slate200
                                    : AppColors.slate800,
                              ),
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
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        env.name,
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      if (env.remarks.isNotEmpty)
                                        Text(
                                          env.remarks,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: AppColors.slate400,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                    ],
                                  ),
                                ),
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: env.enabled
                                        ? AppColors.primary
                                        : AppColors.slate300,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
                        itemCount: state.envs.length,
                        itemBuilder: (_, i) {
                          final env = state.envs[i];
                          return _EnvCard(
                            env: env,
                            isLight: isLight,
                            selectionMode: _selectionMode,
                            selected: _isSelected(env.id),
                            onTap: () {
                              if (_selectionMode) {
                                _toggleSelection(env.id);
                              } else {
                                _showDetailSheet(env);
                              }
                            },
                            onLongPress: () {
                              if (!_selectionMode) {
                                HapticFeedback.mediumImpact();
                                setState(() => _sortMode = true);
                              }
                            },
                            onSelectedChanged: () => _toggleSelection(env.id),
                            onCopy: () {
                              Clipboard.setData(ClipboardData(text: env.value));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('已复制值')),
                              );
                            },
                            onEnable: () => _setEnvEnabled(env, true),
                            onDisable: () => _setEnvEnabled(env, false),
                            onDelete: () => _deleteEnv(env),
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

  void _showDetailSheet(EnvVar env) {
    final messenger = ScaffoldMessenger.of(context);
    final nameC = TextEditingController(text: env.name);
    final valueC = TextEditingController(text: env.value);
    final remarksC = TextEditingController(text: env.remarks);
    final groupC = TextEditingController(text: env.groups.join(', '));
    final groups = [...ref.read(envListProvider).groups];
    var valueEditorOpen = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useRootNavigator: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final theme = Theme.of(ctx);
          final navigator = Navigator.of(ctx);
          if (valueEditorOpen) {
            return _EnvValueSheetEditor(
              title: '编辑变量值',
              controller: valueC,
              onDone: () => setSheetState(() => valueEditorOpen = false),
            );
          }
          return Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              0,
              20,
              MediaQuery.of(ctx).viewInsets.bottom + 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color:
                            (env.enabled
                                    ? AppColors.primary
                                    : AppColors.slate400)
                                .withAlpha(18),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        env.enabled ? '当前已启用' : '当前已禁用',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          // 底色就是这个色的 alpha=18 淡底，前景必须加深。
                          // 禁用态本来就换了 slate500，不属于同色叠同色。
                          color: env.enabled
                              ? AppSurfaces.of(ctx).tintFg(AppColors.primary)
                              : AppColors.slate500,
                        ),
                      ),
                    ),
                    const Spacer(),
                    OutlinedButton.icon(
                      onPressed: () async {
                        // 收紧 validateStatus 后 4xx 会抛异常，这里必须自己兜，
                        // 否则失败时既不提示也不关闭弹层，只在控制台留一个未捕获异常。
                        try {
                          await ref
                              .read(envListProvider.notifier)
                              .toggle(env.id, !env.enabled);
                          if (!mounted) {
                            return;
                          }
                          navigator.pop();
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text(
                                env.enabled
                                    ? '已禁用 ${env.name}'
                                    : '已启用 ${env.name}',
                              ),
                            ),
                          );
                        } catch (error) {
                          if (!mounted) {
                            return;
                          }
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text(
                                extractErrorMessage(error, '修改环境变量状态失败'),
                              ),
                            ),
                          );
                        }
                      },
                      icon: Icon(
                        env.enabled
                            ? Icons.pause_circle_outline
                            : Icons.play_arrow,
                        size: 16,
                      ),
                      label: Text(env.enabled ? '禁用' : '启用'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: env.enabled
                            ? AppColors.slate600
                            : AppColors.primary,
                        side: BorderSide(
                          color: env.enabled
                              ? AppColors.slate300
                              : AppColors.primary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  env.name,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: nameC,
                  decoration: const InputDecoration(labelText: '变量名'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: valueC,
                  decoration: InputDecoration(
                    labelText: '值',
                    suffixIcon: IconButton(
                      // 变量值较长时切到弹窗内的大输入区，不再新开页面，避免回填丢失。
                      icon: const Icon(Icons.open_in_full, size: 18),
                      tooltip: '放大编辑变量值',
                      onPressed: () =>
                          setSheetState(() => valueEditorOpen = true),
                    ),
                  ),
                  maxLines: 4,
                  minLines: 2,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: remarksC,
                  decoration: const InputDecoration(labelText: '备注'),
                ),
                const SizedBox(height: 12),
                _buildGroupAutocomplete(controller: groupC, options: groups),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => Navigator.of(ctx).pop(),
                        icon: const Icon(Icons.close, size: 16),
                        label: const Text('关闭'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 44),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: valueC.text));
                          ScaffoldMessenger.of(
                            ctx,
                          ).showSnackBar(const SnackBar(content: Text('已复制值')));
                        },
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('复制'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.blue500,
                          side: const BorderSide(color: AppColors.blue500),
                          minimumSize: const Size(0, 44),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () async {
                          final rootMessenger = ScaffoldMessenger.of(context);
                          final navigator = Navigator.of(ctx);
                          try {
                            await ref
                                .read(envListProvider.notifier)
                                .update(
                                  env.id,
                                  nameC.text.trim(),
                                  valueC.text,
                                  remarks: remarksC.text.trim(),
                                  groups: _normalizeGroups([groupC.text]),
                                );
                            if (!mounted) {
                              return;
                            }
                            navigator.pop();
                            rootMessenger.showSnackBar(
                              const SnackBar(content: Text('已保存')),
                            );
                          } catch (error) {
                            if (!mounted) {
                              return;
                            }
                            rootMessenger.showSnackBar(
                              SnackBar(
                                content: Text(
                                  extractErrorMessage(error, '保存环境变量失败'),
                                ),
                              ),
                            );
                          }
                        },
                        icon: const Icon(Icons.save, size: 16),
                        label: const Text('保存'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 44),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    ).then((_) {
      nameC.dispose();
      valueC.dispose();
      remarksC.dispose();
      groupC.dispose();
    });
  }

  void _showCreateDialog() {
    final nameC = TextEditingController();
    final valueC = TextEditingController();
    final remarksC = TextEditingController();
    final groupC = TextEditingController();
    final groups = [...ref.read(envListProvider).groups];
    var valueEditorOpen = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useRootNavigator: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final navigator = Navigator.of(ctx);
          final rootMessenger = ScaffoldMessenger.of(context);
          if (valueEditorOpen) {
            return _EnvValueSheetEditor(
              title: '新建变量值',
              controller: valueC,
              onDone: () => setSheetState(() => valueEditorOpen = false),
            );
          }
          return Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              0,
              20,
              MediaQuery.of(ctx).viewInsets.bottom + 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '新建环境变量',
                  style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: nameC,
                  decoration: const InputDecoration(
                    labelText: '变量名',
                    hintText: '如 MY_TOKEN',
                  ),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: valueC,
                  decoration: InputDecoration(
                    labelText: '值',
                    suffixIcon: IconButton(
                      // 新建变量时也用同一个控制器放大编辑，完成后原表单立即保留输入。
                      icon: const Icon(Icons.open_in_full, size: 18),
                      tooltip: '放大编辑变量值',
                      onPressed: () =>
                          setSheetState(() => valueEditorOpen = true),
                    ),
                  ),
                  maxLines: 3,
                  minLines: 1,
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: remarksC,
                        decoration: const InputDecoration(labelText: '备注'),
                        textInputAction: TextInputAction.next,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildGroupAutocomplete(
                        controller: groupC,
                        options: groups,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () async {
                    if (nameC.text.trim().isEmpty) return;
                    try {
                      await ref
                          .read(envListProvider.notifier)
                          .create(
                            nameC.text.trim(),
                            valueC.text,
                            remarks: remarksC.text.trim(),
                            groups: _normalizeGroups([groupC.text]),
                          );
                      if (!mounted) {
                        return;
                      }
                      navigator.pop();
                      rootMessenger.showSnackBar(
                        const SnackBar(content: Text('环境变量已创建')),
                      );
                    } catch (error) {
                      if (!mounted) {
                        return;
                      }
                      rootMessenger.showSnackBar(
                        SnackBar(
                          content: Text(extractErrorMessage(error, '创建环境变量失败')),
                        ),
                      );
                    }
                  },
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                  child: const Text('创建'),
                ),
              ],
            ),
          );
        },
      ),
    ).then((_) {
      nameC.dispose();
      valueC.dispose();
      remarksC.dispose();
      groupC.dispose();
    });
  }
}

class _EnvValueSheetEditor extends StatelessWidget {
  final String title;
  final TextEditingController controller;
  final VoidCallback onDone;

  const _EnvValueSheetEditor({
    required this.title,
    required this.controller,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final screenHeight = MediaQuery.of(context).size.height;
    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    final editorHeight = (screenHeight - keyboardHeight - 72)
        .clamp(420.0, screenHeight * 0.88)
        .toDouble();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          return;
        }
        // 系统返回键只退出大输入区，不直接关闭整个新建/编辑弹窗。
        onDone();
      },
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, keyboardHeight + 16),
          child: SizedBox(
            height: editorHeight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withAlpha(isLight ? 20 : 34),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.open_in_full,
                        size: 18,
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '回到表单',
                      onPressed: onDone,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  '这里直接编辑原表单里的值，点完成后会回到新建/编辑窗口，不会丢输入。',
                  style: TextStyle(fontSize: 12, color: AppColors.slate500),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: TextField(
                    controller: controller,
                    autofocus: true,
                    expands: true,
                    maxLines: null,
                    minLines: null,
                    keyboardType: TextInputType.multiline,
                    textAlignVertical: TextAlignVertical.top,
                    decoration: InputDecoration(
                      hintText: '在这里编辑完整变量值',
                      alignLabelWithHint: true,
                      filled: true,
                      fillColor: isLight ? Colors.white : AppColors.slate900,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          controller.clear();
                        },
                        icon: const Icon(Icons.cleaning_services, size: 16),
                        label: const Text('清空'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.slate500,
                          minimumSize: const Size(0, 44),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        // 不再新开路由，直接收起大输入区，因此原表单控制器会立即保留当前文本。
                        onPressed: onDone,
                        icon: const Icon(Icons.check, size: 18),
                        label: const Text('完成，回到表单'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 44),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EnvCard extends StatefulWidget {
  final EnvVar env;
  final bool isLight;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onSelectedChanged;
  final VoidCallback onCopy;
  final VoidCallback onEnable;
  final VoidCallback onDisable;
  final VoidCallback onDelete;

  const _EnvCard({
    required this.env,
    required this.isLight,
    required this.selectionMode,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onSelectedChanged,
    required this.onCopy,
    required this.onEnable,
    required this.onDisable,
    required this.onDelete,
  });

  @override
  State<_EnvCard> createState() => _EnvCardState();
}

class _EnvCardState extends State<_EnvCard> {
  static const double _actionWidth = 64;
  static const double _actionGap = 6;
  static const double _actionsWidth = _actionWidth * 3 + _actionGap * 2 + 8;

  double _dragOffset = 0;
  bool _dragging = false;

  @override
  void didUpdateWidget(covariant _EnvCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectionMode || oldWidget.env.id != widget.env.id) {
      _dragOffset = 0;
      _dragging = false;
    }
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
                    _SwipeActionButton(
                      label: '启用',
                      icon: Icons.play_arrow_rounded,
                      color: AppColors.primary,
                      enabled: !widget.env.enabled,
                      onTap: () => _runSwipeAction(widget.onEnable),
                    ),
                    const SizedBox(width: _actionGap),
                    _SwipeActionButton(
                      label: '删除',
                      icon: Icons.delete_outline,
                      color: AppColors.red500,
                      enabled: true,
                      onTap: () => _runSwipeAction(widget.onDelete),
                    ),
                    const SizedBox(width: _actionGap),
                    _SwipeActionButton(
                      label: '禁用',
                      icon: Icons.pause_rounded,
                      color: AppColors.slate500,
                      enabled: widget.env.enabled,
                      onTap: () => _runSwipeAction(widget.onDisable),
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
                      // 左滑露出右侧操作按钮；关闭时也限制在卡片内处理，避免和系统返回手势抢动作。
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: widget.isLight ? Colors.white : AppColors.slate900,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: widget.selected
                        ? AppColors.primary
                        : (widget.isLight
                              ? AppColors.slate200
                              : AppColors.slate800),
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
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: widget.env.enabled
                                ? AppColors.primary
                                : AppColors.slate300,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            widget.env.name,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: widget.isLight
                                  ? AppColors.blue600
                                  : AppColors.blue500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (!widget.selectionMode) ...[
                          _MiniBtn(
                            icon: Icons.copy_outlined,
                            onTap: widget.onCopy,
                          ),
                          const SizedBox(width: 4),
                          const Icon(
                            Icons.swipe_left_alt_rounded,
                            size: 18,
                            color: AppColors.slate400,
                          ),
                        ],
                      ],
                    ),
                    Padding(
                      padding: EdgeInsets.only(
                        left: widget.selectionMode ? 32 : 14,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 4),
                          Text(
                            widget.env.value.replaceAll('\n', ' '),
                            style: TextStyle(
                              fontSize: 11,
                              fontFamily: 'monospace',
                              color: widget.isLight
                                  ? AppColors.slate500
                                  : AppColors.slate400,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (widget.env.remarks.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              widget.env.remarks,
                              style: TextStyle(
                                fontSize: 10,
                                color: widget.isLight
                                    ? AppColors.slate400
                                    : AppColors.slate500,
                                fontStyle: FontStyle.italic,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
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

class _SwipeActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool enabled;
  final VoidCallback onTap;

  const _SwipeActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final surfaces = AppSurfaces.of(context);
    final isLight = surfaces.isLight;
    final backgroundColor = enabled
        ? (isLight ? color.withAlpha(24) : color.withAlpha(34))
        : (isLight ? AppColors.slate50 : AppColors.slate800);
    // 底色是同色淡底，前景走 tintFg 才够看；禁用态另有中性灰，不受影响。
    final foregroundColor = enabled
        ? surfaces.tintFg(color)
        : AppColors.slate400;

    return SizedBox(
      width: _EnvCardState._actionWidth,
      child: Material(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: foregroundColor),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: foregroundColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _MiniBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: isLight ? AppColors.slate50 : AppColors.slate800,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, size: 14, color: AppColors.slate400),
      ),
    );
  }
}
