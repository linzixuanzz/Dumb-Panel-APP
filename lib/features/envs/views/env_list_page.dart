import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/models/env_var.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/widgets/app_circle_add_button.dart';
import '../../../shared/widgets/app_buttons.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/app_notice.dart';
import '../../../shared/widgets/app_snack.dart';
import '../../../shared/widgets/app_state_views.dart';
import '../utils/env_transfer.dart';

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
  /// [dio] **仅供测试注入**，生产路径不传，仍然走 `DioClient` 单例。
  /// 单例的 baseUrl 会随切换面板被改写，所以这里不在构造时把它存下来。
  EnvListNotifier({Dio? dio}) : _injectedDio = dio, super(const EnvListState());

  final Dio? _injectedDio;

  Dio get _dio => _injectedDio ?? DioClient.instance.dio;

  Future<void> load() async {
    state = state.copyWith(loading: true, error: null);
    try {
      final dio = _dio;
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
      final response = await _dio.get(
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
    final dio = _dio;
    if (enabled) {
      await dio.put(ApiEndpoints.envEnable(id));
    } else {
      await dio.put(ApiEndpoints.envDisable(id));
    }
    await load();
  }

  Future<void> delete(int id) async {
    await _dio.delete(ApiEndpoints.envById(id));
    await load();
  }

  Future<void> batchDelete(List<int> ids) async {
    await _dio.delete(
      ApiEndpoints.envsBatchDelete,
      data: {'ids': ids},
    );
    await load();
  }

  Future<void> batchEnable(List<int> ids) async {
    await _dio.put(
      ApiEndpoints.envsBatchEnable,
      data: {'ids': ids},
    );
    await load();
  }

  Future<void> batchDisable(List<int> ids) async {
    await _dio.put(
      ApiEndpoints.envsBatchDisable,
      data: {'ids': ids},
    );
    await load();
  }

  Future<void> batchSetGroup(List<int> ids, List<String> groups) async {
    await _dio.put(
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
    await _dio.post(
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
    await _dio.put(
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
    await _dio.put(
      ApiEndpoints.envsSort,
      data: {'source_id': sourceId, 'target_id': targetId},
    );
    await load();
  }

  /// 导出。走面板 `GET /envs/export-all` —— 与 Web 端「导出 JSON」同一条接口。
  ///
  /// 为什么不直接序列化 [EnvListState.envs]：那份列表会被搜索词 / 分组筛过，
  /// 用户以为导了全部、实际只导了筛出来的那些，而且**看不出来**。
  /// export-all 返回的是未分页未筛选的全量数组，同名多条各占一行 —— 无损导出的前提。
  ///
  /// [ids] 非空时只导这些 id（对应列表页的多选）。失败**不静默降级**成本地列表：
  /// 宁可报错，也不能让用户拿到一份少了几条却毫无提示的备份。
  Future<List<EnvTransferItem>> exportAll({List<int>? ids}) async {
    final response = await _dio.get(
      ApiEndpoints.envsExportAll,
      queryParameters: (ids == null || ids.isEmpty)
          ? null
          : <String, dynamic>{'ids': ids.join(',')},
    );

    final data = extractData(response.data);
    if (data is! List) {
      return const <EnvTransferItem>[];
    }
    return data
        .whereType<Map<String, dynamic>>()
        .map(EnvTransferItem.fromJson)
        .toList();
  }

  /// 导入。不 try/catch：写操作吞掉异常会让 UI 拿不到失败原因（spec 明令禁止）。
  Future<EnvImportOutcome> importEnvs({
    required List<EnvTransferItem> items,
    required EnvImportMode mode,
  }) async {
    final response = await _dio.post(
      ApiEndpoints.envsImport,
      data: buildEnvImportRequest(items: items, mode: mode),
    );
    await load();
    return EnvImportOutcome.fromResponse(response.data);
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
      AppSnack.success(
        context,
        enabled ? '已启用 ${env.name}' : '已禁用 ${env.name}',
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppSnack.error(context, extractErrorMessage(error, '修改环境变量状态失败'));
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
      AppSnack.success(context, '已删除 ${env.name}');
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppSnack.error(context, extractErrorMessage(error, '删除环境变量失败'));
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
      AppSnack.success(context, message);
    } catch (error) {
      if (!mounted) {
        return;
      }
      // 原来是 catch (_) 配一句固定文案，服务端说的「哪一条删不掉」被整个丢掉。
      // 与本文件其余写操作一致，先用服务端消息，拿不到再退回这句。
      AppSnack.error(context, extractErrorMessage(error, '批量操作失败，请稍后重试'));
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
      AppSnack.success(context, message);
    } catch (error) {
      if (!mounted) {
        return;
      }
      // 同上：分组失败时服务端的具体原因比一句「请稍后重试」有用。
      AppSnack.error(context, extractErrorMessage(error, '批量分组失败，请稍后重试'));
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

  /// 保存排序结果。
  ///
  /// 从「完成」按钮的 onTap 里提出来，是因为提示要用页面自己的 context：
  /// build 的 context 形参在分析器眼里和 State.mounted 不是一回事，
  /// 写在 build 里就会多两条 use_build_context_synchronously 告警。
  ///
  /// 异常在这里就地消化，不往外抛：调用方在它之后还要 setState 退出排序模式，
  /// 让异常冒出去会把界面卡在排序态。
  Future<void> _saveSortOrder() async {
    try {
      if (_lastMovedSourceId != null) {
        await ref
            .read(envListProvider.notifier)
            .sortEnvs(_lastMovedSourceId!, _lastMovedTargetId);
      }
      if (!mounted) {
        return;
      }
      AppSnack.success(context, '排序已保存');
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppSnack.error(context, extractErrorMessage(error, '保存排序失败'));
    }
  }

  Future<void> _refresh() async {
    if (_selectionMode) {
      _setSelectionMode(false);
    }
    await ref.read(envListProvider.notifier).load();
  }

  /// 导入 / 导出入口。
  ///
  /// 做成弹出菜单而不是再加两个 chip：页头这一行在 360dp 宽的机器上已经排到边，
  /// 多两个 56dp 的 chip 会直接 RenderFlex overflow。
  Widget _buildTransferMenu() {
    final surfaces = context.surfaces;
    return PopupMenuButton<String>(
      tooltip: '导入导出',
      onSelected: (value) {
        if (value == 'export') {
          _showExportSheet();
          return;
        }
        _showImportSheet();
      },
      itemBuilder: (_) => const [
        PopupMenuItem<String>(
          value: 'export',
          child: Row(
            children: [
              Icon(Icons.ios_share, size: 18, color: AppColors.slate400),
              SizedBox(width: AppSpacing.sm),
              Text('导出变量'),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'import',
          child: Row(
            children: [
              Icon(
                Icons.file_download_outlined,
                size: 18,
                color: AppColors.slate400,
              ),
              SizedBox(width: AppSpacing.sm),
              Text('导入变量'),
            ],
          ),
        ),
      ],
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: surfaces.card,
          shape: BoxShape.circle,
          border: Border.all(
            color: surfaces.cardBorder,
            width: AppBorderWidth.hairline,
          ),
        ),
        child: const Icon(
          Icons.more_horiz,
          size: 18,
          color: AppColors.slate400,
        ),
      ),
    );
  }

  Future<void> _showExportSheet() async {
    final selectedIds = _selectedIds.toList()..sort();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useRootNavigator: true,
      builder: (_) => _EnvExportSheet(
        selectedIds: selectedIds,
        loadItems: (ids) =>
            ref.read(envListProvider.notifier).exportAll(ids: ids),
      ),
    );
  }

  Future<void> _showImportSheet() async {
    // 「面板上已经有多条同名同备注」这条提醒用的是**当前已加载的列表**，它可能被
    // 搜索词 / 分组筛过。最坏情况只是少给一条提醒，不影响面板的实际行为；
    // 真正会造成数据损坏的那一条（文件内同名同备注重复）只看导入文件本身，
    // 与这份列表无关 —— 见 analyzeEnvImport 的注释。
    final existing = ref
        .read(envListProvider)
        .envs
        .map(
          (env) => EnvTransferItem(
            name: env.name,
            value: env.value,
            remarks: env.remarks,
            groups: env.groups,
            enabled: env.enabled,
          ),
        )
        .toList();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useRootNavigator: true,
      builder: (_) => _EnvImportSheet(
        existing: existing,
        submit: (items, mode) => ref
            .read(envListProvider.notifier)
            .importEnvs(items: items, mode: mode),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(envListProvider);
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;
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
                              await _saveSortOrder();
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
                      if (!_sortMode) ...[
                        const SizedBox(width: 8),
                        _buildTransferMenu(),
                      ],
                      if (!_selectionMode && !_sortMode) ...[
                        const SizedBox(width: 8),
                        AppCircleAddButton(onTap: () => _showCreateDialog()),
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
                          // 逐字复制 app_theme 的三处 OutlineInputBorder：
                          // 计划裁决只令牌化不删除。三处圆角同值是聚焦动画的硬要求。
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(AppRadius.md),
                            borderSide: BorderSide(
                              color: isLight
                                  ? AppColors.slate200
                                  : AppColors.slate800,
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(AppRadius.md),
                            borderSide: BorderSide(
                              color: isLight
                                  ? AppColors.slate200
                                  : AppColors.slate800,
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(AppRadius.md),
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
                        // 与左边同一行、同为 44 高的搜索框成对，必须同档。
                        borderRadius: BorderRadius.circular(AppRadius.md),
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
                child: AppCard(
                  width: double.infinity,
                  padding: const EdgeInsets.all(AppSpacing.md),
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
                            // 「启用」是 success 绿，与状态圆点/徽章同语义；
                            // 原先是 primary，和「批量分组」的 blue500 同属蓝族，
                            // 一条操作栏里两个蓝按钮分不清。
                            color: AppColors.success,
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
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: AppNotice(
                  color: AppColors.primary,
                  icon: Icons.swap_vert,
                  text: '长按拖拽调整顺序，点击「完成」保存',
                  accentText: true,
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
                          // ⚠️ key 必须挂在 ReorderableListView 的直接子 widget
                          // 上（这里就是 AppCard 自己），挂到它的 child 上会在
                          // 拖拽时抛「Every item of ReorderableListView must
                          // have a key」。
                          return AppCard(
                            key: ValueKey(env.id),
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
                                // 详情页圆点：「已启用」= success 绿。必须与列表卡
                                // 圆点一起改，否则两个界面对同一个状态各说各话。
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: env.enabled
                                        ? AppColors.success
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
                              AppSnack.success(context, '已复制值');
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
                      // 「当前已启用」= success 绿。底色和前景是一对，必须同时改，
                      // 只改一个就会变成绿字配蓝底（或反过来）。
                      decoration: BoxDecoration(
                        color:
                            (env.enabled
                                    ? AppColors.success
                                    : AppColors.slate400)
                                .withAlpha(18),
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      child: Text(
                        env.enabled ? '当前已启用' : '当前已禁用',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          // 底色就是这个色的 alpha=18 淡底，前景必须加深。
                          // 禁用态本来就换了 slate500，不属于同色叠同色。
                          color: env.enabled
                              ? AppSurfaces.of(ctx).tintFg(AppColors.success)
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
                          // 传页面自己的 context 而不是弹层的 ctx：提示挂在根
                          // ScaffoldMessenger 上，弹层已经 pop 掉了，用 ctx 只会
                          // 因为它不再挂在树上而被静默丢弃。
                          AppSnack.success(
                            context,
                            env.enabled ? '已禁用 ${env.name}' : '已启用 ${env.name}',
                          );
                        } catch (error) {
                          if (!mounted) {
                            return;
                          }
                          AppSnack.error(
                            context,
                            extractErrorMessage(error, '修改环境变量状态失败'),
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
                      // 「启用」动作走 success 绿。这里用 tintFg 而不是满强度
                      // success：按钮文字和描边直接压在弹层白底上，满强度 success
                      // 只有 2.13:1，比换掉的 primary（2.78:1）还差 —— 换语义不能
                      // 顺带把可读性换没了。tintFg 浅色下正好等于 successDark，
                      // 与上方徽章同一族绿；深色下原样返回。
                      style: OutlinedButton.styleFrom(
                        foregroundColor: env.enabled
                            ? AppColors.slate600
                            : AppSurfaces.of(ctx).tintFg(AppColors.success),
                        side: BorderSide(
                          color: env.enabled
                              ? AppColors.slate300
                              : AppSurfaces.of(ctx).tintFg(AppColors.success),
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
                          AppSnack.success(ctx, '已复制值');
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
                            // 同上：弹层已 pop，只有页面自己的 context 还能弹提示。
                            AppSnack.success(context, '已保存');
                          } catch (error) {
                            if (!mounted) {
                              return;
                            }
                            AppSnack.error(
                              context,
                              extractErrorMessage(error, '保存环境变量失败'),
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
                      // 同上：弹层已 pop，只有页面自己的 context 还能弹提示。
                      AppSnack.success(context, '环境变量已创建');
                    } catch (error) {
                      if (!mounted) {
                        return;
                      }
                      AppSnack.error(
                        context,
                        extractErrorMessage(error, '创建环境变量失败'),
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
                        // 图标底板一律走 sm，不跟外层容器同档。
                        borderRadius: BorderRadius.circular(AppRadius.sm),
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
                        borderRadius: BorderRadius.circular(AppRadius.md),
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

String _formatTransferSize(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  final kb = bytes / 1024;
  if (kb < 1024) {
    return '${kb.toStringAsFixed(1)} KB';
  }
  return '${(kb / 1024).toStringAsFixed(2)} MB';
}

/// 提示里只列前几条，剩下的折成「等 N 项」。全列出来会把弹层撑爆。
String _joinIdentityPreview(List<String> values, {int limit = 3}) {
  if (values.length <= limit) {
    return values.join('、');
  }
  return '${values.take(limit).join('、')} 等 ${values.length} 项';
}

/// 导出弹层。
///
/// 三个刻意的选择：
/// 1. **不做脱敏**。环境变量里全是 Cookie / Token，遮掉就导不回去了 ——
///    导出的全部意义就是「改完再导进来」。所以只警告，不改内容。
/// 2. **不提供 shell / js / python**（面板 `POST /envs/export-files` 那三种）。
///    它们把同名多条合并成一行、丢掉备注和分组，而且面板没有对应的导入口，
///    放在「导出改完再导入」的入口里只会诱导用户走进死路。
/// 3. 拿不到数据时**报错，不回落到本地列表** —— 见 EnvListNotifier.exportAll。
class _EnvExportSheet extends StatefulWidget {
  final List<int> selectedIds;
  final Future<List<EnvTransferItem>> Function(List<int>? ids) loadItems;

  const _EnvExportSheet({required this.selectedIds, required this.loadItems});

  @override
  State<_EnvExportSheet> createState() => _EnvExportSheetState();
}

class _EnvExportSheetState extends State<_EnvExportSheet> {
  bool _selectedOnly = false;
  bool _loading = true;
  String? _error;
  String _content = '';
  int _count = 0;
  int _bytes = 0;

  @override
  void initState() {
    super.initState();
    _selectedOnly = widget.selectedIds.isNotEmpty;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final items = await widget.loadItems(
        _selectedOnly ? widget.selectedIds : null,
      );
      if (!mounted) {
        return;
      }
      final content = encodeEnvTransferJson(items);
      setState(() {
        _content = content;
        _count = items.length;
        _bytes = utf8.encode(content).length;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = extractErrorMessage(error, '导出环境变量失败');
        _content = '';
        _count = 0;
        _bytes = 0;
        _loading = false;
      });
    }
  }

  void _setSelectedOnly(bool value) {
    if (_selectedOnly == value) {
      return;
    }
    setState(() => _selectedOnly = value);
    _load();
  }

  String _suggestedFileName() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return 'envs-${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}${two(now.second)}.json';
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: _content));
    AppSnack.success(context, '已复制 $_count 条环境变量到剪贴板');
  }

  Future<void> _save() async {
    try {
      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: '保存环境变量',
        fileName: _suggestedFileName(),
        type: FileType.any,
        // utf8.encode 在当前 SDK 返回的就是 Uint8List，不用再包一层 fromList
        // （包了就得 import dart:typed_data，而那会变成一条 unused_import 风险）。
        bytes: utf8.encode(_content),
      );
      if (!mounted) {
        return;
      }
      if (savedPath == null) {
        // 用户自己按了取消，不是失败，保持中性。
        AppSnack.show(context, '已取消保存');
        return;
      }
      AppSnack.success(context, '已保存 $_count 条环境变量');
    } on UnsupportedError {
      if (!mounted) {
        return;
      }
      AppSnack.warn(context, '当前平台暂不支持直接保存文件');
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppSnack.error(context, extractErrorMessage(error, '保存文件失败'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final surfaces = context.surfaces;
    final canExport = !_loading && _error == null && _count > 0;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.xl,
        0,
        AppSpacing.xl,
        MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '导出环境变量',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: AppSpacing.md),
          const AppNotice(
            color: AppColors.warning,
            icon: Icons.warning_amber_rounded,
            text:
                '导出内容是 Cookie / Token 的明文。复制到剪贴板后其他应用可能读到，'
                '存成文件也别放进网盘或聊天记录 —— 用完请及时清理。',
          ),
          if (widget.selectedIds.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.sm,
              children: [
                ChoiceChip(
                  label: Text('已选 ${widget.selectedIds.length} 项'),
                  selected: _selectedOnly,
                  onSelected: (value) {
                    if (value) {
                      _setSelectedOnly(true);
                    }
                  },
                ),
                ChoiceChip(
                  label: const Text('全部变量'),
                  selected: !_selectedOnly,
                  onSelected: (value) {
                    if (value) {
                      _setSelectedOnly(false);
                    }
                  },
                ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            AppNotice(
              color: AppColors.danger,
              icon: Icons.error_outline,
              text: _error!,
              accentText: true,
            )
          else
            AppCard(
              radius: AppRadius.md,
              color: surfaces.subtle,
              borderColor: surfaces.subtleBorder,
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '共 $_count 条 · ${_formatTransferSize(_bytes)}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xxs),
                  Text(
                    '格式与面板「导出 JSON」完全一致：同名多条各占一行（多账号不会被压平），'
                    '备注、分组、启用状态一并带上，可原样导回本 APP 或面板 Web。',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: surfaces.mutedText,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.lg),
          if (_error != null)
            OutlinedButton.icon(
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重试'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 44),
              ),
            )
          else
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: canExport ? _save : null,
                    icon: const Icon(Icons.save_alt, size: 16),
                    label: const Text('保存为文件'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 44),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: canExport ? _copy : null,
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('复制'),
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
  }
}

/// 导入弹层。
///
/// 只提供面板已有的两种模式（合并 / 替换），不自己拼第三种 —— 理由见 [EnvImportMode]。
///
/// 提交前做一次本地体检（[analyzeEnvImport]），其中**合并模式下会压平多账号**
/// 这一条是硬拦：面板 `POST /envs/import` 的 merge 没有 `PUT /envs/by-name` 那道
/// 「同名多条直接报 409」的守卫，放过去就是无声的数据损坏。
class _EnvImportSheet extends StatefulWidget {
  final List<EnvTransferItem> existing;
  final Future<EnvImportOutcome> Function(
    List<EnvTransferItem> items,
    EnvImportMode mode,
  )
  submit;

  const _EnvImportSheet({required this.existing, required this.submit});

  @override
  State<_EnvImportSheet> createState() => _EnvImportSheetState();
}

class _EnvImportSheetState extends State<_EnvImportSheet> {
  final _textController = TextEditingController();
  Timer? _debounce;

  EnvImportMode _mode = EnvImportMode.merge;
  EnvTransferParseResult _parsed = const EnvTransferParseResult();
  EnvImportPreflight? _preflight;
  bool _submitting = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _textController.dispose();
    super.dispose();
  }

  /// 边打字边整份 jsonDecode 会卡（粘一份 1MB 的进来更明显），沿用列表页搜索框的防抖。
  void _scheduleAnalyze() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _analyze);
  }

  void _analyze() {
    if (!mounted) {
      return;
    }
    final raw = _textController.text.trim();
    if (raw.isEmpty) {
      // 空白不算「格式错误」，别一进来就给用户一条红提示。
      setState(() {
        _parsed = const EnvTransferParseResult();
        _preflight = null;
      });
      return;
    }

    final parsed = parseEnvTransferJson(raw);
    setState(() {
      _parsed = parsed;
      _preflight = parsed.ok
          ? analyzeEnvImport(
              items: parsed.items,
              existing: widget.existing,
              mode: _mode,
            )
          : null;
    });
  }

  void _setMode(EnvImportMode mode) {
    if (_mode == mode) {
      return;
    }
    setState(() => _mode = mode);
    // 体检结果与模式强相关（压平 / 已存在多条只在 merge 下成立），必须重算。
    _analyze();
  }

  Future<void> _pickFile() async {
    try {
      // 不限制扩展名：Android 的文档选择器对 .json/.txt 的 MIME 映射各家实现不一，
      // 限了反而会出现「文件就在那儿但是灰的」。
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        withData: true,
      );
      if (!mounted) {
        return;
      }
      if (result == null || result.files.isEmpty) {
        // 用户自己取消了，不提示。
        return;
      }

      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) {
        AppSnack.error(context, '读取文件失败或文件为空');
        return;
      }

      _textController.text = utf8.decode(bytes, allowMalformed: true);
      _analyze();
      AppSnack.show(context, '已载入 ${file.name}');
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppSnack.error(context, extractErrorMessage(error, '选择文件失败'));
    }
  }

  Future<bool> _confirmReplace(int total) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('替换导入'),
        content: Text(
          '替换会先删除面板上的全部环境变量，再写入这 $total 条。\n'
          '面板上有、而这份内容里没有的变量将无法找回。',
        ),
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
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: FilledButton(
                    onPressed: () => Navigator.of(dialogCtx).pop(true),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.danger,
                    ),
                    child: const Text('清空并导入'),
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

  Future<void> _submit() async {
    final preflight = _preflight;
    if (_submitting || preflight == null || preflight.blocked) {
      return;
    }

    if (_mode == EnvImportMode.replace) {
      final confirmed = await _confirmReplace(preflight.total);
      if (!mounted) {
        return;
      }
      if (!confirmed) {
        return;
      }
    }

    final navigator = Navigator.of(context);
    setState(() => _submitting = true);

    try {
      final outcome = await widget.submit(_parsed.items, _mode);
      if (!mounted) {
        return;
      }
      // 先弹提示再关弹层：提示挂在根 ScaffoldMessenger 上，弹层关掉它照样在；
      // 反过来先 pop 的话，这里的 context 已经失效，AppSnack 会静默什么都不做。
      if (outcome.errors.isEmpty) {
        AppSnack.success(context, outcome.message);
      } else {
        AppSnack.warn(
          context,
          '${outcome.message}；${outcome.errors.length} 条被跳过：'
          '${outcome.errors.first}',
        );
      }
      navigator.pop();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _submitting = false);
      AppSnack.error(context, extractErrorMessage(error, '导入环境变量失败'));
    }
  }

  List<Widget> _buildCheckWidgets(AppSurfaces surfaces) {
    final parseError = _parsed.error;
    if (parseError != null) {
      return [
        AppNotice(
          color: AppColors.danger,
          icon: Icons.error_outline,
          text: parseError,
          accentText: true,
        ),
      ];
    }

    final preflight = _preflight;
    if (preflight == null) {
      return [
        const AppNotice(
          color: AppColors.primary,
          icon: Icons.info_outline,
          text:
              '粘贴「导出变量」得到的 JSON，或从文件载入。格式与面板 Web 的「导出 JSON / 导入」一致，'
              '两边可以互导。',
        ),
      ];
    }

    final widgets = <Widget>[
      AppCard(
        radius: AppRadius.md,
        color: surfaces.subtle,
        borderColor: surfaces.subtleBorder,
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Text(
          '解析出 ${preflight.total} 条 · ${_formatTransferSize(preflight.payloadBytes)}',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
      ),
    ];

    if (_parsed.skipped > 0) {
      widgets.add(
        AppNotice(
          color: AppColors.warning,
          icon: Icons.warning_amber_rounded,
          text: '有 ${_parsed.skipped} 项不是对象，已跳过。',
          accentText: true,
        ),
      );
    }

    if (preflight.oversized) {
      widgets.add(
        AppNotice(
          color: AppColors.danger,
          icon: Icons.error_outline,
          text:
              '内容 ${_formatTransferSize(preflight.payloadBytes)} '
              '超过面板 1MB 的请求体上限，请分批导入。',
          accentText: true,
        ),
      );
    }

    if (preflight.collapsedIdentities.isNotEmpty) {
      widgets.add(
        AppNotice(
          color: AppColors.danger,
          icon: Icons.error_outline,
          text:
              '合并模式按「变量名 + 备注」认领记录，'
              '${_joinIdentityPreview(preflight.collapsedIdentities)} '
              '在这份内容里出现了多次，导入后只会剩一条 —— 多账号会被压平。'
              '请改用「替换」，或给它们填上不同的备注。',
          accentText: true,
        ),
      );
    }

    if (preflight.ambiguousIdentities.isNotEmpty) {
      widgets.add(
        AppNotice(
          color: AppColors.warning,
          icon: Icons.warning_amber_rounded,
          text:
              '面板上已有多条同名同备注的记录（'
              '${_joinIdentityPreview(preflight.ambiguousIdentities)}），'
              '合并只会更新其中一条，其余保持原样。',
          accentText: true,
        ),
      );
    }

    if (preflight.invalidNames.isNotEmpty) {
      widgets.add(
        AppNotice(
          color: AppColors.warning,
          icon: Icons.warning_amber_rounded,
          text:
              '这些变量名不符合面板规则（只能字母或下划线开头，后接字母数字下划线），'
              '面板会跳过它们：${_joinIdentityPreview(preflight.invalidNames)}。',
          accentText: true,
        ),
      );
    }

    if (_mode == EnvImportMode.replace) {
      widgets.add(
        const AppNotice(
          color: AppColors.danger,
          icon: Icons.delete_forever,
          text: '替换会先清空面板上的全部环境变量，再写入上面这些。这一步不可撤销。',
          accentText: true,
        ),
      );
    }

    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    final surfaces = context.surfaces;
    final media = MediaQuery.of(context);
    final preflight = _preflight;
    final canSubmit =
        !_submitting && preflight != null && !preflight.blocked;

    final checkWidgets = _buildCheckWidgets(surfaces);

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: media.size.height * 0.86),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.xl,
          0,
          AppSpacing.xl,
          media.viewInsets.bottom + AppSpacing.xl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '导入环境变量',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: AppSpacing.md),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: AppSpacing.sm,
                      children: [
                        ChoiceChip(
                          label: const Text('合并'),
                          selected: _mode == EnvImportMode.merge,
                          onSelected: (value) {
                            if (value) {
                              _setMode(EnvImportMode.merge);
                            }
                          },
                        ),
                        ChoiceChip(
                          label: const Text('替换'),
                          selected: _mode == EnvImportMode.replace,
                          onSelected: (value) {
                            if (value) {
                              _setMode(EnvImportMode.replace);
                            }
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      _mode == EnvImportMode.merge
                          ? '合并：按「变量名 + 备注」认领面板上已有的记录，命中就更新值 / 分组 / 启用状态，'
                                '没命中就新增。不会删除这份内容里没有的变量。'
                          : '替换：先清空面板上的全部环境变量，再按顺序全量写入。同名多条会原样保留。',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: surfaces.mutedText,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextField(
                      controller: _textController,
                      maxLines: 8,
                      minLines: 4,
                      keyboardType: TextInputType.multiline,
                      textAlignVertical: TextAlignVertical.top,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'JSON 内容',
                        alignLabelWithHint: true,
                        hintText:
                            '[{"name": "JD_COOKIE", "value": "pt_key=...", '
                            '"remarks": "账号1", "groups": ["京东"], "enabled": true}]',
                        hintMaxLines: 3,
                      ),
                      onChanged: (_) => _scheduleAnalyze(),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    // 不要把循环变量取名 widget —— 那会遮住 State.widget。
                    for (final notice in checkWidgets) ...[
                      notice,
                      const SizedBox(height: AppSpacing.sm),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _submitting ? null : _pickFile,
                    icon: const Icon(Icons.folder_open, size: 16),
                    label: const Text('选择文件'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 44),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: canSubmit ? _submit : null,
                    icon: const Icon(Icons.file_download_done, size: 16),
                    label: Text(_submitting ? '导入中…' : '导入'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 44),
                      backgroundColor: _mode == EnvImportMode.replace
                          ? AppColors.danger
                          : null,
                    ),
                  ),
                ),
              ],
            ),
          ],
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
        margin: const EdgeInsets.only(bottom: 6),
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
                      // 「启用」动作走 success 绿；淡底和前景（含 tintFg）都由
                      // _SwipeActionButton 内部按这个 color 推导，改一处即可。
                      color: AppColors.success,
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
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: widget.isLight ? Colors.white : AppColors.slate900,
                  // 列表项卡片。这一处没迁 AppCard（要 AnimatedContainer +
                  // Matrix4 做左滑），但圆角必须与 AppCard 同档。
                  borderRadius: BorderRadius.circular(AppRadius.lg),
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
                        // 列表卡圆点：「已启用」= success 绿。必须与详情页的
                        // 同义圆点一起改，否则同一个环境变量在两个界面是两种颜色。
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: widget.env.enabled
                                ? AppColors.success
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
                          const SizedBox(height: 2),
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
        // 左滑露出的操作按钮，走按钮档；底板与水波纹必须同值。
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(AppRadius.md),
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
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Icon(icon, size: 14, color: AppColors.slate400),
      ),
    );
  }
}