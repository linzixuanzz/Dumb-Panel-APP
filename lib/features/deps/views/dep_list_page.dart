import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/sse_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/models/dependency.dart';
import '../../../shared/models/python_runtime_info.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/utils/ansi_text.dart';
import '../../../shared/utils/log_background.dart';
import '../../../shared/utils/time_utils.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/app_snack.dart';

// ── Provider ──

final depListProvider = StateNotifierProvider<DepListNotifier, DepListState>((
  ref,
) {
  return DepListNotifier();
});

class DepListState {
  final List<Dependency> items;
  final bool loading;
  final String selectedType;
  final String selectedPythonVersion;
  final String pythonDefaultVersion;
  final List<PythonRuntimeInfo> pythonRuntimes;
  final bool runtimeLoading;

  const DepListState({
    this.items = const [],
    this.loading = false,
    this.selectedType = 'nodejs',
    this.selectedPythonVersion = '3.12',
    this.pythonDefaultVersion = '3.12',
    this.pythonRuntimes = const [],
    this.runtimeLoading = false,
  });

  DepListState copyWith({
    List<Dependency>? items,
    bool? loading,
    String? selectedType,
    String? selectedPythonVersion,
    String? pythonDefaultVersion,
    List<PythonRuntimeInfo>? pythonRuntimes,
    bool? runtimeLoading,
  }) {
    return DepListState(
      items: items ?? this.items,
      loading: loading ?? this.loading,
      selectedType: selectedType ?? this.selectedType,
      selectedPythonVersion:
          selectedPythonVersion ?? this.selectedPythonVersion,
      pythonDefaultVersion: pythonDefaultVersion ?? this.pythonDefaultVersion,
      pythonRuntimes: pythonRuntimes ?? this.pythonRuntimes,
      runtimeLoading: runtimeLoading ?? this.runtimeLoading,
    );
  }
}

class DepMirrorConfig {
  final String pipMirror;
  final String npmMirror;
  final String linuxMirror;
  final String linuxPackageManager;
  final String linuxDistribution;
  final bool linuxMirrorSupported;
  final String linuxMirrorLabel;
  final String linuxMirrorMessage;

  const DepMirrorConfig({
    this.pipMirror = '',
    this.npmMirror = '',
    this.linuxMirror = '',
    this.linuxPackageManager = '',
    this.linuxDistribution = '',
    this.linuxMirrorSupported = false,
    this.linuxMirrorLabel = 'Linux',
    this.linuxMirrorMessage = '',
  });

  factory DepMirrorConfig.fromJson(Map<String, dynamic> json) {
    return DepMirrorConfig(
      pipMirror: json['pip_mirror']?.toString() ?? '',
      npmMirror: json['npm_mirror']?.toString() ?? '',
      linuxMirror: json['linux_mirror']?.toString() ?? '',
      linuxPackageManager: json['linux_package_manager']?.toString() ?? '',
      linuxDistribution: json['linux_distribution']?.toString() ?? '',
      linuxMirrorSupported: json['linux_mirror_supported'] == true,
      linuxMirrorLabel: json['linux_mirror_label']?.toString() ?? 'Linux',
      linuxMirrorMessage: json['linux_mirror_message']?.toString() ?? '',
    );
  }

  DepMirrorConfig copyWith({
    String? pipMirror,
    String? npmMirror,
    String? linuxMirror,
    String? linuxPackageManager,
    bool? linuxMirrorSupported,
    String? linuxDistribution,
    String? linuxMirrorLabel,
    String? linuxMirrorMessage,
  }) {
    return DepMirrorConfig(
      pipMirror: pipMirror ?? this.pipMirror,
      npmMirror: npmMirror ?? this.npmMirror,
      linuxMirror: linuxMirror ?? this.linuxMirror,
      linuxPackageManager: linuxPackageManager ?? this.linuxPackageManager,
      linuxMirrorSupported: linuxMirrorSupported ?? this.linuxMirrorSupported,
      linuxDistribution: linuxDistribution ?? this.linuxDistribution,
      linuxMirrorLabel: linuxMirrorLabel ?? this.linuxMirrorLabel,
      linuxMirrorMessage: linuxMirrorMessage ?? this.linuxMirrorMessage,
    );
  }

  Map<String, dynamic> toRequestJson() => {
    'pip_mirror': pipMirror.trim(),
    'npm_mirror': npmMirror.trim(),
    'linux_mirror': linuxMirror.trim(),
  };
}

class DepListNotifier extends StateNotifier<DepListState> {
  DepListNotifier() : super(const DepListState());

  Future<List<Dependency>> fetchByType(
    String type, {
    String? pythonVersion,
  }) async {
    final params = <String, dynamic>{'page': 1, 'page_size': 200, 'type': type};
    if (type == 'python' && (pythonVersion ?? '').trim().isNotEmpty) {
      params['python_version'] = pythonVersion!.trim();
    }
    final resp = await DioClient.instance.dio.get(
      ApiEndpoints.deps,
      queryParameters: params,
    );
    final paginated = extractPaginated(resp.data);
    return paginated.items.map(Dependency.fromJson).toList();
  }

  Future<void> load({String? type, String? pythonVersion}) async {
    final nextType = type ?? state.selectedType;
    final nextPythonVersion = pythonVersion ?? state.selectedPythonVersion;
    state = state.copyWith(
      selectedType: nextType,
      selectedPythonVersion: nextPythonVersion,
      loading: true,
    );
    try {
      final items = await fetchByType(
        nextType,
        pythonVersion: nextType == 'python' ? nextPythonVersion : null,
      );
      state = state.copyWith(items: items, loading: false);
    } catch (_) {
      state = state.copyWith(loading: false);
    }
  }

  Future<void> setType(String type) async {
    await load(type: type);
  }

  Future<void> setPythonVersion(String version) async {
    await load(type: 'python', pythonVersion: version);
  }

  Future<void> loadPythonRuntimes() async {
    state = state.copyWith(runtimeLoading: true);
    try {
      final resp = await DioClient.instance.dio.get(
        ApiEndpoints.depsPythonRuntimes,
      );
      final raw = resp.data;
      final map = raw is Map<String, dynamic>
          ? raw
          : raw is Map
          ? Map<String, dynamic>.from(raw)
          : <String, dynamic>{};
      final runtimeData = map['data'];
      final runtimes = runtimeData is List
          ? runtimeData
                .whereType<Map>()
                .map(
                  (item) => PythonRuntimeInfo.fromJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .where((item) => item.version.isNotEmpty)
                .toList()
          : <PythonRuntimeInfo>[];
      final defaultVersion =
          map['default_version']?.toString().trim().isNotEmpty == true
          ? map['default_version'].toString().trim()
          : state.pythonDefaultVersion;
      final selectedStillExists = runtimes.any(
        (runtime) => runtime.version == state.selectedPythonVersion,
      );
      state = state.copyWith(
        pythonRuntimes: runtimes,
        pythonDefaultVersion: defaultVersion,
        selectedPythonVersion: selectedStillExists
            ? state.selectedPythonVersion
            : defaultVersion,
        runtimeLoading: false,
      );
    } catch (_) {
      state = state.copyWith(runtimeLoading: false);
    }
  }

  Future<void> setDefaultPythonRuntime(String version) async {
    await DioClient.instance.dio.put(
      ApiEndpoints.depsPythonRuntimeDefault,
      data: {'version': version},
    );
    await loadPythonRuntimes();
    await load(type: 'python', pythonVersion: version);
  }

  Future<void> delete(int id, {bool force = false}) async {
    await DioClient.instance.dio.delete(
      ApiEndpoints.depById(id),
      queryParameters: force ? {'force': true} : null,
    );
    await load();
  }

  Future<void> batchDelete(List<int> ids) async {
    await DioClient.instance.dio.post(
      ApiEndpoints.depsBatchDelete,
      data: {'ids': ids},
    );
    await load();
  }

  Future<void> reinstall(int id) async {
    await DioClient.instance.dio.put(ApiEndpoints.depReinstall(id));
    await load();
  }

  Future<void> cancel(int id) async {
    await DioClient.instance.dio.put(ApiEndpoints.depCancel(id));
    await load();
  }

  Future<void> create({
    required String type,
    required List<String> names,
  }) async {
    await DioClient.instance.dio.post(
      ApiEndpoints.deps,
      data: {
        'type': type,
        'names': names,
        if (type == 'python') 'python_version': state.selectedPythonVersion,
      },
    );
    await load();
  }

  Future<Map<String, dynamic>> getStatus(int id) async {
    final resp = await DioClient.instance.dio.get(ApiEndpoints.depStatus(id));
    final data = extractData(resp.data);
    if (data is Map<String, dynamic>) {
      return data;
    }
    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }
    return <String, dynamic>{};
  }

  Future<DepMirrorConfig> getMirrors() async {
    final resp = await DioClient.instance.dio.get(ApiEndpoints.depsMirrors);
    final data = extractData(resp.data);
    if (data is Map<String, dynamic>) {
      return DepMirrorConfig.fromJson(data);
    }
    if (data is Map) {
      return DepMirrorConfig.fromJson(Map<String, dynamic>.from(data));
    }
    return const DepMirrorConfig();
  }

  Future<void> setMirrors(DepMirrorConfig config) async {
    await DioClient.instance.dio.put(
      ApiEndpoints.depsMirrors,
      data: config.toRequestJson(),
    );
  }
}

// ── Page ──

class _CreateDepRequest {
  final String type;
  final List<String> names;

  const _CreateDepRequest({required this.type, required this.names});
}

class DepListPage extends ConsumerStatefulWidget {
  const DepListPage({super.key});

  @override
  ConsumerState<DepListPage> createState() => _DepListPageState();
}

class _DepListPageState extends ConsumerState<DepListPage> {
  final Set<int> _selectedIds = <int>{};
  Map<String, int> _counts = const {'nodejs': 0, 'python': 0, 'linux': 0};
  bool _countLoading = true;
  bool _mirrorLoading = false;
  bool _mirrorSaving = false;
  String? _statusFilter;

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadPageData);
  }

  Future<void> _loadPageData() async {
    await ref.read(depListProvider.notifier).loadPythonRuntimes();
    await Future.wait([
      ref.read(depListProvider.notifier).load(),
      _loadCounts(),
    ]);
    _trimSelection();
  }

  Future<void> _loadCounts() async {
    final notifier = ref.read(depListProvider.notifier);
    final state = ref.read(depListProvider);
    try {
      final results = await Future.wait([
        notifier.fetchByType('nodejs'),
        notifier.fetchByType(
          'python',
          pythonVersion: state.selectedPythonVersion,
        ),
        notifier.fetchByType('linux'),
      ]);
      if (!mounted) {
        return;
      }
      setState(() {
        _counts = {
          'nodejs': results[0].length,
          'python': results[1].length,
          'linux': results[2].length,
        };
        _countLoading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _countLoading = false);
    }
  }

  void _trimSelection() {
    final validIds = ref
        .read(depListProvider)
        .items
        .map((dep) => dep.id)
        .toSet();
    _selectedIds.removeWhere((id) => !validIds.contains(id));
  }

  // 这个页面的每条提示都有明确成败，没有中性提示，所以不再保留 _showMessage。
  void _showSuccess(String message) => AppSnack.success(context, message);

  void _showError(String message) => AppSnack.error(context, message);

  void _showWarning(String message) => AppSnack.warn(context, message);

  String _extractError(Object error, String fallback) {
    return extractErrorMessage(error, fallback);
  }

  String _typeLabel(String type) {
    switch (type) {
      case 'python':
        return 'Python';
      case 'linux':
        return 'Linux';
      default:
        return 'NodeJS';
    }
  }

  List<String> _parseNames(String raw, bool autoSplit) {
    if (!autoSplit) {
      final trimmed = raw.trim();
      return trimmed.isEmpty ? const [] : [trimmed];
    }
    final parts = raw
        .split(RegExp(r'[\n,\s]+'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
    return parts.toSet().toList();
  }

  Future<void> _changeType(String type) async {
    await ref.read(depListProvider.notifier).setType(type);
    if (!mounted) {
      return;
    }
    setState(() => _selectedIds.clear());
    await _loadCounts();
  }

  Future<void> _changePythonVersion(String version) async {
    await ref.read(depListProvider.notifier).setPythonVersion(version);
    if (!mounted) {
      return;
    }
    setState(() {
      _selectedIds.clear();
      _statusFilter = null;
    });
    await _loadCounts();
  }

  Future<void> _setPythonDefault() async {
    final state = ref.read(depListProvider);
    try {
      await ref
          .read(depListProvider.notifier)
          .setDefaultPythonRuntime(state.selectedPythonVersion);
      await _loadCounts();
      _showSuccess('已设置默认 Python 版本');
    } catch (error) {
      _showError(_extractError(error, '设置默认 Python 版本失败'));
    }
  }

  Future<void> _handleCreate() async {
    final request = await _showCreateDialog();
    if (request == null) {
      return;
    }
    try {
      await ref
          .read(depListProvider.notifier)
          .create(type: request.type, names: request.names);
      await _loadCounts();
      _showSuccess(
        request.type == 'python'
            ? '已提交 Python 依赖安装，会同步到可用的 Python 版本'
            : '已提交 ${request.names.length} 个依赖安装',
      );
    } catch (error) {
      _showError(_extractError(error, '提交安装失败'));
    }
  }

  Future<_CreateDepRequest?> _showCreateDialog() async {
    final messenger = ScaffoldMessenger.of(context);
    final namesController = TextEditingController();
    var createType = ref.read(depListProvider).selectedType;
    var autoSplit = true;

    return showDialog<_CreateDepRequest>(
      context: context,
      useRootNavigator: true,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('安装依赖'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'nodejs', label: Text('NodeJS')),
                      ButtonSegment(value: 'python', label: Text('Python')),
                      ButtonSegment(value: 'linux', label: Text('Linux')),
                    ],
                    selected: {createType},
                    onSelectionChanged: (selection) {
                      setDialogState(() => createType = selection.first);
                    },
                  ),
                  if (createType == 'python') ...[
                    const SizedBox(height: 12),
                    _PythonInstallHint(
                      isLight: Theme.of(context).brightness == Brightness.light,
                    ),
                  ],
                  const SizedBox(height: 16),
                  TextField(
                    controller: namesController,
                    minLines: 4,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      labelText: '依赖名称',
                      hintText: '每行一个依赖名称，支持换行、空格、逗号自动拆分',
                    ),
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('自动拆分'),
                    subtitle: const Text('开启后按换行、空格、逗号拆分为多个依赖'),
                    value: autoSplit,
                    onChanged: (value) {
                      setDialogState(() => autoSplit = value);
                    },
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final names = _parseNames(namesController.text, autoSplit);
                if (names.isEmpty) {
                  messenger.showSnackBar(
                    const SnackBar(content: Text('请输入依赖名称')),
                  );
                  return;
                }
                Navigator.of(
                  dialogCtx,
                ).pop(_CreateDepRequest(type: createType, names: names));
              },
              child: const Text('安装'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleBatchDelete() async {
    if (_selectedIds.isEmpty) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('批量卸载'),
        content: Text('确定要批量卸载选中的 ${_selectedIds.length} 个依赖吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.red500),
            child: const Text('批量卸载'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }

    try {
      await ref
          .read(depListProvider.notifier)
          .batchDelete(_selectedIds.toList());
      await _loadCounts();
      if (!mounted) {
        return;
      }
      setState(() => _selectedIds.clear());
      _showSuccess('批量卸载已提交');
    } catch (error) {
      _showError(_extractError(error, '批量卸载失败'));
    }
  }

  Future<void> _confirmDelete(Dependency dep, {bool force = false}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(force ? '强制卸载依赖' : '卸载依赖'),
        content: Text(
          force
              ? '确定要强制卸载「${dep.name}」吗？这会跳过依赖检查直接删除。'
              : '确定要卸载「${dep.name}」吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.red500),
            child: Text(force ? '强制卸载' : '卸载'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }

    try {
      await ref.read(depListProvider.notifier).delete(dep.id, force: force);
      await _loadCounts();
      _showSuccess(force ? '强制卸载中' : '卸载中');
    } catch (error) {
      _showError(_extractError(error, force ? '强制卸载失败' : '卸载失败'));
    }
  }

  Future<void> _handleReinstall(Dependency dep) async {
    try {
      await ref.read(depListProvider.notifier).reinstall(dep.id);
      await _loadCounts();
      _showSuccess('重新安装中');
    } catch (error) {
      _showError(_extractError(error, '重新安装失败'));
    }
  }

  Future<void> _handleCancel(Dependency dep) async {
    try {
      await ref.read(depListProvider.notifier).cancel(dep.id);
      await _loadCounts();
      _showSuccess('取消请求已提交');
    } catch (error) {
      _showError(_extractError(error, '取消失败'));
    }
  }

  List<MapEntry<String, String>> _linuxMirrorOptions(DepMirrorConfig config) {
    if (config.linuxPackageManager == 'apk') {
      return const [
        MapEntry('阿里云 (默认)', 'https://mirrors.aliyun.com/alpine'),
        MapEntry('清华大学', 'https://mirrors.tuna.tsinghua.edu.cn/alpine'),
        MapEntry('腾讯云', 'https://mirrors.cloud.tencent.com/alpine'),
        MapEntry('华为云', 'https://repo.huaweicloud.com/alpine'),
      ];
    }
    if (config.linuxPackageManager == 'apt') {
      if (config.linuxDistribution == 'debian') {
        return const [
          MapEntry('阿里云 Debian (默认)', 'https://mirrors.aliyun.com/debian'),
          MapEntry(
            '清华大学 Debian',
            'https://mirrors.tuna.tsinghua.edu.cn/debian',
          ),
          MapEntry('腾讯云 Debian', 'https://mirrors.cloud.tencent.com/debian'),
        ];
      }
      return const [
        MapEntry('阿里云 Ubuntu (默认)', 'https://mirrors.aliyun.com/ubuntu'),
        MapEntry('清华大学 Ubuntu', 'https://mirrors.tuna.tsinghua.edu.cn/ubuntu'),
        MapEntry('腾讯云 Ubuntu', 'https://mirrors.cloud.tencent.com/ubuntu'),
        MapEntry('华为云 Ubuntu', 'https://repo.huaweicloud.com/ubuntu'),
      ];
    }
    return const [];
  }

  Future<void> _openMirrorDialog() async {
    setState(() => _mirrorLoading = true);
    try {
      final config = await ref.read(depListProvider.notifier).getMirrors();
      if (!mounted) {
        return;
      }
      final nextConfig = await _showMirrorDialog(config);
      if (nextConfig == null) {
        return;
      }
      if (!nextConfig.linuxMirrorSupported &&
          nextConfig.linuxMirror.trim().isNotEmpty) {
        // 系统不支持而不是保存出错，用警告而不是失败。
        _showWarning(
          nextConfig.linuxMirrorMessage.isNotEmpty
              ? nextConfig.linuxMirrorMessage
              : '当前系统暂不支持 Linux 镜像设置',
        );
        return;
      }
      if (mounted) {
        setState(() => _mirrorSaving = true);
      }
      try {
        await ref.read(depListProvider.notifier).setMirrors(nextConfig);
        _showSuccess('镜像源设置成功');
      } catch (error) {
        _showError(_extractError(error, '镜像源设置失败'));
      } finally {
        if (mounted) {
          setState(() => _mirrorSaving = false);
        }
      }
    } catch (error) {
      _showError(_extractError(error, '获取镜像源配置失败'));
    } finally {
      if (mounted) {
        setState(() => _mirrorLoading = false);
      }
    }
  }

  Future<DepMirrorConfig?> _showMirrorDialog(DepMirrorConfig initial) async {
    final pipController = TextEditingController(text: initial.pipMirror);
    final npmController = TextEditingController(text: initial.npmMirror);
    final linuxController = TextEditingController(text: initial.linuxMirror);

    return showDialog<DepMirrorConfig>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('镜像源设置'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: pipController,
                    decoration: const InputDecoration(
                      labelText: 'Python (pip)',
                      hintText: '留空恢复默认加速源',
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children:
                        const [
                          MapEntry(
                            '阿里云 (默认)',
                            'https://mirrors.aliyun.com/pypi/simple',
                          ),
                          MapEntry(
                            '清华大学',
                            'https://pypi.tuna.tsinghua.edu.cn/simple',
                          ),
                          MapEntry(
                            '腾讯云',
                            'https://mirrors.cloud.tencent.com/pypi/simple',
                          ),
                        ].map((entry) {
                          return ActionChip(
                            label: Text(entry.key),
                            onPressed: () {
                              setDialogState(
                                () => pipController.text = entry.value,
                              );
                            },
                          );
                        }).toList(),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: npmController,
                    decoration: const InputDecoration(
                      labelText: 'Node.js (npm)',
                      hintText: '留空恢复默认加速源',
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children:
                        [
                          ('淘宝 (npmmirror)', 'https://registry.npmmirror.com'),
                          ('腾讯云', 'https://mirrors.cloud.tencent.com/npm/'),
                          (
                            '华为云',
                            'https://repo.huaweicloud.com/repository/npm/',
                          ),
                        ].map((entry) {
                          return ActionChip(
                            label: Text(entry.$1),
                            onPressed: () {
                              setDialogState(
                                () => npmController.text = entry.$2,
                              );
                            },
                          );
                        }).toList(),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: linuxController,
                    enabled: initial.linuxMirrorSupported,
                    decoration: InputDecoration(
                      labelText: initial.linuxMirrorLabel,
                      hintText: initial.linuxMirrorSupported
                          ? '留空恢复默认加速源'
                          : '当前包管理器暂不支持镜像设置',
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _linuxMirrorOptions(initial).map((entry) {
                      return ActionChip(
                        label: Text(entry.key),
                        onPressed: initial.linuxMirrorSupported
                            ? () {
                                setDialogState(
                                  () => linuxController.text = entry.value,
                                );
                              }
                            : null,
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.blue500.withAlpha(12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppColors.blue500.withAlpha(30),
                      ),
                    ),
                    child: Text(
                      '当前检测：${initial.linuxPackageManager.isEmpty ? '未识别' : initial.linuxPackageManager}'
                      '${initial.linuxDistribution.isEmpty ? '' : ' / ${initial.linuxDistribution}'}'
                      '${initial.linuxMirrorMessage.isEmpty ? '' : '。${initial.linuxMirrorMessage}'}',
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(height: 1.5),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(
                  dialogCtx,
                  initial.copyWith(
                    pipMirror: pipController.text.trim(),
                    npmMirror: npmController.text.trim(),
                    linuxMirror: linuxController.text.trim(),
                  ),
                );
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCountCard(
    String type,
    String label,
    bool selected,
    bool isLight,
  ) {
    final count = _counts[type] ?? 0;
    return AppCard(
      onTap: () => _changeType(type),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      // 选中态是淡底 + 实色边，必须显式传入，否则会落回 AppCard 的默认卡片配色。
      color: selected ? AppColors.primary.withAlpha(isLight ? 18 : 24) : null,
      borderColor: selected ? AppColors.primary : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: selected
                  ? AppColors.primaryDark
                  : (isLight ? AppColors.slate500 : AppColors.slate400),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _countLoading ? '--' : '$count',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: selected
                  ? AppColors.primary
                  : (isLight ? AppColors.slate900 : AppColors.slate50),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPythonRuntimePanel(DepListState state, bool isLight) {
    final runtimes = state.pythonRuntimes;
    final hasSelected = runtimes.any(
      (runtime) => runtime.version == state.selectedPythonVersion,
    );
    final selectedVersion = hasSelected
        ? state.selectedPythonVersion
        : (runtimes.isNotEmpty ? runtimes.first.version : null);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: AppCard(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.md),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isNarrow = constraints.maxWidth < 420;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isNarrow) ...[
                  DropdownButtonFormField<String>(
                    key: ValueKey(selectedVersion),
                    initialValue: selectedVersion,
                    decoration: const InputDecoration(
                      labelText: 'Python 版本',
                      isDense: true,
                    ),
                    items: runtimes.map((runtime) {
                      final suffix = runtime.isDefault ? '（默认）' : '';
                      return DropdownMenuItem(
                        value: runtime.version,
                        child: Text('${runtime.label}$suffix'),
                      );
                    }).toList(),
                    onChanged: state.runtimeLoading
                        ? null
                        : (value) {
                            if (value != null) _changePythonVersion(value);
                          },
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed:
                          state.selectedPythonVersion ==
                              state.pythonDefaultVersion
                          ? null
                          : _setPythonDefault,
                      child: const Text('设为默认'),
                    ),
                  ),
                ] else
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          key: ValueKey(selectedVersion),
                          initialValue: selectedVersion,
                          decoration: const InputDecoration(
                            labelText: 'Python 版本',
                            isDense: true,
                          ),
                          items: runtimes.map((runtime) {
                            final suffix = runtime.isDefault ? '（默认）' : '';
                            return DropdownMenuItem(
                              value: runtime.version,
                              child: Text('${runtime.label}$suffix'),
                            );
                          }).toList(),
                          onChanged: state.runtimeLoading
                              ? null
                              : (value) {
                                  if (value != null) {
                                    _changePythonVersion(value);
                                  }
                                },
                        ),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton(
                        onPressed:
                            state.selectedPythonVersion ==
                                state.pythonDefaultVersion
                            ? null
                            : _setPythonDefault,
                        child: const Text('设为默认'),
                      ),
                    ],
                  ),
                const SizedBox(height: 10),
                _PythonInstallHint(isLight: isLight),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: runtimes.isEmpty
                      ? [
                          Text(
                            state.runtimeLoading
                                ? '正在加载 Python 运行时...'
                                : '暂无运行时信息',
                            style: TextStyle(
                              fontSize: 12,
                              color: isLight
                                  ? AppColors.slate500
                                  : AppColors.slate400,
                            ),
                          ),
                        ]
                      : runtimes.map((runtime) {
                          // 「可用」是健康态，属 success 绿；primary 不表达可用。
                          // 这一个变量同时驱动淡底、描边和 tintFg 前景，改一处即可。
                          final color = runtime.available
                              ? AppColors.success
                              : AppColors.amber500;
                          return Tooltip(
                            message: runtime.message,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: color.withAlpha(18),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(color: color.withAlpha(60)),
                              ),
                              child: Text(
                                '${runtime.label}：${runtime.available ? '可用' : '需安装'}',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  // 「需安装」用的是 amber，压在自己的淡底上
                                  // 只有 2.04:1，是这一批里最看不清的。
                                  color: context.surfaces.tintFg(color),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(depListProvider);
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;
    final screenWidth = MediaQuery.of(context).size.width;
    final isNarrow = screenWidth < 420;

    return Scaffold(
      body: Padding(
        padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 12),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => context.pop(),
                    child: const Icon(Icons.arrow_back_ios, size: 20),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '依赖管理',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '镜像源设置',
                    onPressed: _mirrorLoading || _mirrorSaving
                        ? null
                        : _openMirrorDialog,
                    icon: _mirrorLoading || _mirrorSaving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.settings_suggest_outlined),
                  ),
                  GestureDetector(
                    onTap: _handleCreate,
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
              ),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = isNarrow
                      ? (constraints.maxWidth - 10) / 2
                      : (constraints.maxWidth - 20) / 3;
                  return Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      SizedBox(
                        width: width,
                        child: _buildCountCard(
                          'nodejs',
                          'NodeJS',
                          state.selectedType == 'nodejs',
                          isLight,
                        ),
                      ),
                      SizedBox(
                        width: width,
                        child: _buildCountCard(
                          'python',
                          'Python',
                          state.selectedType == 'python',
                          isLight,
                        ),
                      ),
                      SizedBox(
                        width: width,
                        child: _buildCountCard(
                          'linux',
                          'Linux',
                          state.selectedType == 'linux',
                          isLight,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 10),
            if (state.selectedType == 'python') ...[
              _buildPythonRuntimePanel(state, isLight),
              const SizedBox(height: 10),
            ],
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _StatusFilterChip(
                    label: '全部',
                    count: state.items.length,
                    selected: _statusFilter == null,
                    isLight: isLight,
                    onTap: () => setState(() => _statusFilter = null),
                  ),
                  _StatusFilterChip(
                    label: '已安装',
                    count: state.items.where((d) => d.isInstalled).length,
                    selected: _statusFilter == 'installed',
                    isLight: isLight,
                    // 与下方「已安装」状态徽章同色；原先是 primary，
                    // 和默认也是 primary 的「全部」chip 完全同色。
                    color: AppColors.success,
                    onTap: () => setState(
                      () => _statusFilter = _statusFilter == 'installed'
                          ? null
                          : 'installed',
                    ),
                  ),
                  _StatusFilterChip(
                    label: '失败',
                    count: state.items.where((d) => d.isFailed).length,
                    selected: _statusFilter == 'failed',
                    isLight: isLight,
                    color: AppColors.danger,
                    onTap: () => setState(
                      () => _statusFilter = _statusFilter == 'failed'
                          ? null
                          : 'failed',
                    ),
                  ),
                ],
              ),
            ),
            if (_selectedIds.isNotEmpty) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: FilledButton.tonalIcon(
                  onPressed: _handleBatchDelete,
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  label: Text('批量卸载 (${_selectedIds.length})'),
                  style: FilledButton.styleFrom(
                    foregroundColor: AppColors.red500,
                    minimumSize: const Size(double.infinity, 40),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 10),
            Expanded(
              child: RefreshIndicator(
                color: AppColors.primary,
                onRefresh: _loadPageData,
                child: state.loading && state.items.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: const [
                          SizedBox(height: 120),
                          Center(
                            child: CircularProgressIndicator(
                              color: AppColors.primary,
                            ),
                          ),
                        ],
                      )
                    : () {
                        final filtered = _statusFilter == null
                            ? state.items
                            : state.items
                                  .where((d) => d.status == _statusFilter)
                                  .toList();
                        if (filtered.isEmpty) {
                          return ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            children: [
                              const SizedBox(height: 100),
                              Icon(
                                Icons.inventory_2_outlined,
                                size: 56,
                                color: AppColors.slate400.withAlpha(120),
                              ),
                              const SizedBox(height: 12),
                              Center(
                                child: Text(
                                  _statusFilter != null
                                      ? '没有${_statusFilter == 'installed' ? '已安装' : '失败'}的依赖'
                                      : '暂无${_typeLabel(state.selectedType)}依赖',
                                  style: const TextStyle(
                                    color: AppColors.slate400,
                                  ),
                                ),
                              ),
                            ],
                          );
                        }
                        return ListView.builder(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                          itemCount: filtered.length,
                          itemBuilder: (_, i) {
                            final dep = filtered[i];
                            return _DepCard(
                              dep: dep,
                              isLight: isLight,
                              selected: _selectedIds.contains(dep.id),
                              subtitle:
                                  '${_typeLabel(dep.type)}'
                                  '${dep.type == 'python' && dep.pythonVersion.isNotEmpty ? ' ${dep.pythonVersion}' : ''}'
                                  ' · ${formatTimeCn(dep.createdAt, short: true)}',
                              onSelected: (value) {
                                setState(() {
                                  if (value) {
                                    _selectedIds.add(dep.id);
                                  } else {
                                    _selectedIds.remove(dep.id);
                                  }
                                });
                              },
                              onViewLog: () =>
                                  context.push('/deps/${dep.id}/log-stream'),
                              onCancel: dep.isBusy
                                  ? () => _handleCancel(dep)
                                  : null,
                              onReinstall: dep.isBusy
                                  ? null
                                  : () => _handleReinstall(dep),
                              onDelete: dep.isBusy
                                  ? null
                                  : () => _confirmDelete(dep),
                              onForceDelete: dep.isBusy
                                  ? null
                                  : () => _confirmDelete(dep, force: true),
                            );
                          },
                        );
                      }(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Card ──

class _DepCard extends StatelessWidget {
  final Dependency dep;
  final bool isLight;
  final bool selected;
  final String subtitle;
  final ValueChanged<bool> onSelected;
  final VoidCallback onViewLog;
  final VoidCallback? onCancel;
  final VoidCallback? onReinstall;
  final VoidCallback? onDelete;
  final VoidCallback? onForceDelete;

  const _DepCard({
    required this.dep,
    required this.isLight,
    required this.selected,
    required this.subtitle,
    required this.onSelected,
    required this.onViewLog,
    required this.onCancel,
    required this.onReinstall,
    required this.onDelete,
    required this.onForceDelete,
  });

  // 安装中/排队中=蓝(info)、失败=红(danger)、已取消=灰、已安装=绿(success)。
  // 「已安装」原先借用 primary 淡底 + 写死的 Emerald 深绿字，主色换蓝后就成了
  // 深绿字配浅蓝底，这里换成成套的 success 色。
  Color _statusBg() {
    if (dep.isBusy) {
      return isLight ? AppColors.infoLight : AppColors.info.withAlpha(25);
    }
    if (dep.isFailed) {
      return isLight ? AppColors.dangerLight : AppColors.danger.withAlpha(25);
    }
    if (dep.isCancelled) {
      return isLight ? AppColors.slate100 : AppColors.slate700;
    }
    return isLight ? AppColors.successLight : AppColors.success.withAlpha(25);
  }

  Color _statusFg() {
    if (dep.isBusy) {
      return isLight ? AppColors.infoDark : AppColors.info;
    }
    if (dep.isFailed) {
      return isLight ? AppColors.dangerDark : AppColors.danger;
    }
    if (dep.isCancelled) {
      return isLight ? AppColors.slate600 : AppColors.slate300;
    }
    return isLight ? AppColors.successDark : AppColors.success;
  }

  @override
  Widget build(BuildContext context) {
    // 这张卡已经贴着地板：78dp 里有 48dp 是右侧 PopupMenuButton 的点击区，
    // 那 48dp 一动不能动。可削的只有内边距与外边距，合计 −10dp 到头了。
    return AppCard(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: Checkbox(
              value: selected,
              onChanged: (value) => onSelected(value ?? false),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        dep.name,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (dep.version.isNotEmpty)
                      Text(
                        dep.version,
                        style: TextStyle(
                          fontSize: 10,
                          color: isLight
                              ? AppColors.slate500
                              : AppColors.slate400,
                          fontFamily: 'monospace',
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: _statusBg(),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        dep.statusText,
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: _statusFg(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 10,
                          color: isLight
                              ? AppColors.slate400
                              : AppColors.slate500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            onPressed: onViewLog,
            icon: const Icon(Icons.terminal, size: 18),
            tooltip: '日志',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
          PopupMenuButton<String>(
            onSelected: (action) {
              switch (action) {
                case 'cancel':
                  onCancel?.call();
                case 'reinstall':
                  onReinstall?.call();
                case 'delete':
                  onDelete?.call();
                case 'force_delete':
                  onForceDelete?.call();
              }
            },
            icon: const Icon(Icons.more_horiz, size: 18),
            itemBuilder: (_) => [
              if (dep.isBusy)
                const PopupMenuItem(value: 'cancel', child: Text('取消安装')),
              if (!dep.isBusy)
                const PopupMenuItem(value: 'reinstall', child: Text('重新安装')),
              if (!dep.isBusy)
                const PopupMenuItem(value: 'delete', child: Text('卸载')),
              if (!dep.isBusy)
                PopupMenuItem(
                  value: 'force_delete',
                  child: Text(
                    '强制卸载',
                    style: TextStyle(color: AppColors.red500),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Dep Log Stream Page ──

class DepLogStreamPage extends ConsumerStatefulWidget {
  final int depId;
  const DepLogStreamPage({super.key, required this.depId});

  @override
  ConsumerState<DepLogStreamPage> createState() => _DepLogStreamPageState();
}

class _DepLogStreamPageState extends ConsumerState<DepLogStreamPage> {
  final _sseClient = SseClient();
  final _logs = <String>[];
  final _scrollController = ScrollController();
  bool _done = false;
  Color? _logBackgroundColor;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      final color = await loadPanelLogBackgroundColor();
      if (mounted) {
        setState(() => _logBackgroundColor = color);
      }
    });
    _sseClient.connect(
      path: ApiEndpoints.depLogStream(widget.depId),
      autoReconnect: true,
      onEvent: (event) {
        if (!mounted) return;
        setState(() {
          _logs.add(event.data);
          if (event.event == 'done' && event.data != 'reconnect') {
            _done = true;
          }
        });
        Future.delayed(const Duration(milliseconds: 50), () {
          if (_scrollController.hasClients) {
            _scrollController.jumpTo(
              _scrollController.position.maxScrollExtent,
            );
          }
        });
      },
      onDone: () {
        if (mounted) setState(() => _done = true);
      },
      onError: (_) {
        if (mounted) setState(() => _done = true);
      },
    );
  }

  @override
  void dispose() {
    _sseClient.close();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final logTheme = resolveLogSurfaceTheme(_logBackgroundColor);
    final doneBannerBackground = logTheme.brightness == Brightness.dark
        ? AppColors.slate800
        : AppColors.slate100;

    return Scaffold(
      backgroundColor: logTheme.background,
      appBar: AppBar(
        title: const Text('安装日志'),
        backgroundColor: logTheme.background,
        foregroundColor: logTheme.foreground,
      ),
      body: Container(
        color: logTheme.background,
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(12),
                itemCount: _logs.length,
                itemBuilder: (_, i) => SelectionArea(
                  child: RichText(
                    text: AnsiTextParser.buildTextSpan(
                      _logs[i],
                      baseStyle: TextStyle(
                        color: logTheme.foreground,
                        fontFamily: 'monospace',
                        fontSize: 12,
                        height: 1.6,
                      ),
                      brightness: logTheme.brightness,
                    ),
                  ),
                ),
              ),
            ),
            if (_done)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                color: doneBannerBackground,
                child: Text(
                  '安装完成',
                  textAlign: TextAlign.center,
                  // 「完成」是结果成功，走 success；与列表卡「已安装」徽章同族。
                  // 浅色分支取 successDark：banner 底是 slate100，
                  // 满强度 success 只有 2.1:1。深色分支沿用日志前景色，不动。
                  style: TextStyle(
                    color: logTheme.brightness == Brightness.dark
                        ? logTheme.foreground
                        : AppColors.successDark,
                    fontSize: 13,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _StatusFilterChip extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final bool isLight;
  final Color? color;
  final VoidCallback onTap;

  const _StatusFilterChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.isLight,
    this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final activeColor = color ?? AppColors.primary;
    final bg = selected
        ? activeColor.withAlpha(20)
        : (isLight ? AppColors.slate50 : AppColors.slate900);
    // 选中态底色是 activeColor 的 alpha=20 淡底，标签再用满强度同色就贴在一起了。
    final fg = selected
        ? context.surfaces.tintFg(activeColor)
        : (isLight ? AppColors.slate600 : AppColors.slate400);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? activeColor.withAlpha(60)
                : (isLight ? AppColors.slate200 : AppColors.slate800),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: fg,
              ),
            ),
            const SizedBox(width: 5),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: selected
                    ? activeColor
                    : (isLight ? AppColors.slate200 : AppColors.slate800),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: selected ? Colors.white : fg,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PythonInstallHint extends StatelessWidget {
  final bool isLight;

  const _PythonInstallHint({required this.isLight});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.blue500.withAlpha(12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.blue500.withAlpha(30)),
      ),
      child: Text(
        'Python 多版本说明：二进制部署不会内置三个 Python，只需在服务器安装实际要用的版本；安装 Python 依赖时会同步提交到可用的 Python 3.10、3.11、3.12 环境。',
        style: TextStyle(
          fontSize: 12,
          height: 1.5,
          color: isLight ? AppColors.slate600 : AppColors.slate300,
        ),
      ),
    );
  }
}
