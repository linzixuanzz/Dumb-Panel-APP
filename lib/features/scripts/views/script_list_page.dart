import 'dart:async';
import 'dart:ui';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/api_endpoints.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/storage/secure_storage.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/utils/ansi_text.dart';
import '../../../shared/utils/log_background.dart';
import '../../../shared/utils/time_utils.dart';
import '../../../shared/widgets/app_back_button.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/app_snack.dart';
import '../../../shared/widgets/app_state_views.dart';
import '../../tasks/views/task_form_page.dart';
import '../utils/script_search.dart';
import '../widgets/script_find_bar.dart';
import '../widgets/script_highlight_controller.dart';
import '../widgets/script_line_number_gutter.dart';

final scriptProvider = StateNotifierProvider<ScriptNotifier, ScriptState>((
  ref,
) {
  return ScriptNotifier();
});

enum _ScriptAction { upload, createFile, createDirectory }

enum _ScriptEntryAction {
  open,
  addToTask,
  favorite,
  download,
  move,
  copy,
  rename,
  delete,
  versions,
  uploadHere,
  createFileHere,
  createDirectoryHere,
}

enum _ScriptViewerAction { format, versions, addToTask, debug }

const _stateUnset = Object();

class ScriptFile {
  final String name;
  final String path;
  final bool isDirectory;
  final List<ScriptFile> children;

  const ScriptFile({
    required this.name,
    required this.path,
    this.isDirectory = false,
    this.children = const [],
  });

  factory ScriptFile.fromJson(Map<String, dynamic> json) {
    final children =
        (json['children'] as List?)
            ?.whereType<Map>()
            .map(
              (entry) => ScriptFile.fromJson(Map<String, dynamic>.from(entry)),
            )
            .toList() ??
        [];
    return ScriptFile(
      name: json['title']?.toString() ?? json['name']?.toString() ?? '',
      path: json['key']?.toString() ?? json['path']?.toString() ?? '',
      isDirectory:
          json['type'] == 'directory' ||
          json['is_directory'] == true ||
          json['isLeaf'] == false,
      children: children,
    );
  }
}

class ScriptVersionRecord {
  final int id;
  final int version;
  final String message;
  final int contentLength;
  final DateTime? createdAt;

  const ScriptVersionRecord({
    required this.id,
    required this.version,
    required this.message,
    required this.contentLength,
    required this.createdAt,
  });

  factory ScriptVersionRecord.fromJson(Map<String, dynamic> json) {
    return ScriptVersionRecord(
      id: (json['id'] as num?)?.toInt() ?? 0,
      version: (json['version'] as num?)?.toInt() ?? 0,
      message: json['message']?.toString() ?? '',
      contentLength: (json['content_length'] as num?)?.toInt() ?? 0,
      createdAt: json['created_at'] is String
          ? DateTime.tryParse(json['created_at'].toString())
          : null,
    );
  }
}

class ScriptState {
  final List<ScriptFile> tree;
  final bool loading;

  /// 脚本树加载失败的原因，成功或重新加载时清空。
  ///
  /// ⚠️ 它在 [copyWith] 里是**「不传即清空」**语义（与 `selectedPath` 的哨兵语义相反）。
  /// 这是有意的：`loadTree()` 开头一句 `copyWith(loading: true)` 就能顺手清掉上次的错误。
  /// 代价是**任何**不传 error 的 `copyWith` 都会把它抹掉 —— 所以与脚本树无关的状态更新
  /// （改搜索词、加载文件内容、保存文件）必须显式写 `error: state.error` 把它带回去，
  /// 否则用户会看到「加载失败」莫名其妙变成「暂无脚本」。
  final String? error;
  final String keyword;
  final String? selectedPath;
  final String content;
  final bool isBinary;
  final bool loadingContent;
  final bool saving;

  /// 脚本**内容**加载失败的原因。与 [error]（脚本树）是两件事。
  ///
  /// 为什么必须有它：改造前 `loadContent` 的 catch 分支把失败写成
  /// `content: '加载失败'` 且不留任何标志位。从脚本树点进来时路径必然存在，
  /// 所以从没踩到；但日志详情页新增「跳到对应脚本」的入口之后，脚本被删、被改名、
  /// 无权限都会走到这里 —— 用户看到的是一个内容为「加载失败」四个字的**可编辑**
  /// 缓冲区，一按保存就把这四个字写成真文件，属于静默数据破坏。
  ///
  /// ⚠️ 它走 [_stateUnset] 哨兵（「不传即保持」），**刻意不跟 [error] 一样裸赋值**：
  /// 内容加载失败之后用户随便点点（改搜索词、重命名别的文件）都会走 copyWith，
  /// 裸赋值会把标志位悄悄抹掉、编辑器又变回可编辑的脏缓冲区 —— 那正是这个字段
  /// 要防的事。要清空就显式写 `contentError: null`。
  final String? contentError;

  const ScriptState({
    this.tree = const [],
    this.loading = false,
    this.error,
    this.keyword = '',
    this.selectedPath,
    this.content = '',
    this.isBinary = false,
    this.loadingContent = false,
    this.saving = false,
    this.contentError,
  });

  ScriptState copyWith({
    List<ScriptFile>? tree,
    bool? loading,
    String? error,
    String? keyword,
    Object? selectedPath = _stateUnset,
    String? content,
    bool? isBinary,
    bool? loadingContent,
    bool? saving,
    Object? contentError = _stateUnset,
  }) {
    return ScriptState(
      tree: tree ?? this.tree,
      loading: loading ?? this.loading,
      // 刻意不写 `error ?? this.error`：不传就是清空，
      // 否则失败一次之后错误提示永远消不掉。
      // 这条语义被 test/features/list_error_state_test.dart 锁死。
      error: error,
      keyword: keyword ?? this.keyword,
      selectedPath: identical(selectedPath, _stateUnset)
          ? this.selectedPath
          : selectedPath as String?,
      content: content ?? this.content,
      isBinary: isBinary ?? this.isBinary,
      loadingContent: loadingContent ?? this.loadingContent,
      saving: saving ?? this.saving,
      contentError: identical(contentError, _stateUnset)
          ? this.contentError
          : contentError as String?,
    );
  }
}

class ScriptNotifier extends StateNotifier<ScriptState> {
  /// [dio] **仅供测试注入**，生产路径不传，仍然走 `DioClient` 单例。
  /// 单例的 baseUrl 会随切换面板被改写，所以这里不在构造时把它存下来。
  ScriptNotifier({Dio? dio}) : _injectedDio = dio, super(const ScriptState());

  final Dio? _injectedDio;

  Dio get _dio => _injectedDio ?? DioClient.instance.dio;

  void setKeyword(String keyword) {
    // 必须显式回传 error：copyWith 是「不传即清空」语义（见 ScriptState.copyWith 的注释）。
    // 不带上的话，树加载失败之后用户一敲搜索框，错误提示就被抹掉、页面退回「暂无脚本」——
    // 看起来像是搜不到结果，实际上是根本没加载成功。
    state = state.copyWith(keyword: keyword, error: state.error);
  }

  Future<void> loadTree() async {
    state = state.copyWith(loading: true, error: null);
    try {
      final resp = await _dio.get(ApiEndpoints.scriptsTree);
      final data = extractData(resp.data);
      final tree = data is List
          ? data
                .whereType<Map>()
                .map(
                  (entry) =>
                      ScriptFile.fromJson(Map<String, dynamic>.from(entry)),
                )
                .toList()
          : <ScriptFile>[];
      state = state.copyWith(tree: tree, loading: false);
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: extractListErrorMessage(e, '加载脚本失败'),
      );
    }
  }

  Future<void> loadContent(String path) async {
    // 这几处 copyWith 都显式回传 error：脚本树的错误提示与「打开某个文件」无关，
    // 不带上就会被「不传即清空」的语义顺手抹掉（见 ScriptState.copyWith 的注释）。
    state = state.copyWith(
      selectedPath: path,
      loadingContent: true,
      contentError: null,
      error: state.error,
    );
    try {
      final resp = await _dio.get(
        ApiEndpoints.scriptsContent,
        queryParameters: {'path': path},
      );
      final data = extractData(resp.data);
      if (data is Map) {
        final isBinary = data['binary'] == true || data['is_binary'] == true;
        state = state.copyWith(
          selectedPath: path,
          content: isBinary ? '' : (data['content']?.toString() ?? ''),
          isBinary: isBinary,
          loadingContent: false,
          error: state.error,
        );
        return;
      }
      state = state.copyWith(
        selectedPath: path,
        content: data?.toString() ?? '',
        isBinary: false,
        loadingContent: false,
        error: state.error,
      );
    } catch (e) {
      // ⚠️ 绝不能再把「加载失败」四个字当成文件内容塞进编辑器：那个缓冲区是可编辑的，
      // 用户一按保存就把这四个字写成真文件。这里清空内容并立起 contentError，
      // 由页面渲染错误态 + 禁用保存。
      state = state.copyWith(
        selectedPath: path,
        content: '',
        isBinary: false,
        loadingContent: false,
        contentError: extractListErrorMessage(e, '脚本内容加载失败'),
        error: state.error,
      );
    }
  }

  Future<void> saveContent(
    String path,
    String content, {
    String message = '',
  }) async {
    state = state.copyWith(saving: true);
    try {
      await _dio.put(
        ApiEndpoints.scriptsContent,
        data: {'path': path, 'content': content, 'message': message},
      );
      state = state.copyWith(content: content, isBinary: false, saving: false);
    } catch (_) {
      state = state.copyWith(saving: false);
      rethrow;
    }
  }

  Future<void> createFile(String path) async {
    await _dio.put(
      ApiEndpoints.scriptsContent,
      data: {'path': path, 'content': '', 'message': 'V1 初始版本'},
    );
    await loadTree();
  }

  Future<void> createDirectory(String path) async {
    await _dio.post(ApiEndpoints.scriptsDirectory, data: {'path': path});
    await loadTree();
  }

  Future<List<String>> uploadFiles(
    List<PlatformFile> files, {
    String dir = '',
  }) async {
    final formData = FormData();
    for (final file in files) {
      final multipart = await _toMultipartFile(file);
      if (multipart != null) {
        formData.files.add(MapEntry('file', multipart));
      }
    }
    if (formData.files.isEmpty) {
      throw StateError('未选择可上传的文件');
    }
    if (dir.trim().isNotEmpty) {
      formData.fields.add(MapEntry('dir', dir.trim()));
    }

    final resp = await _dio.post(
      ApiEndpoints.scriptsUpload,
      data: formData,
      options: Options(contentType: 'multipart/form-data'),
    );
    await loadTree();
    final raw = resp.data;
    if (raw is Map && raw['paths'] is List) {
      return (raw['paths'] as List).map((item) => item.toString()).toList();
    }
    if (raw is Map && raw['path'] != null) {
      return [raw['path'].toString()];
    }
    return files.map((file) => _joinScriptPath(dir, file.name)).toList();
  }

  Future<String> renamePath(String oldPath, String newName) async {
    final resp = await _dio.put(
      ApiEndpoints.scriptsRename,
      data: {'old_path': oldPath, 'new_name': newName},
    );
    await loadTree();
    final data = resp.data;
    final rawPath = data is Map && data['new_path'] != null
        ? data['new_path']
        : null;
    final newPath =
        rawPath?.toString() ??
        _joinScriptPath(_defaultScriptDirectory(oldPath), newName);

    final selected = state.selectedPath;
    if (selected == oldPath) {
      state = state.copyWith(selectedPath: newPath);
    } else if (selected != null && selected.startsWith('$oldPath/')) {
      state = state.copyWith(
        selectedPath: selected.replaceFirst(oldPath, newPath),
      );
    }
    return newPath;
  }

  Future<String> movePath(String sourcePath, {String targetDir = ''}) async {
    final response = await _dio.put(
      ApiEndpoints.scriptsMove,
      data: {'source_path': sourcePath, 'target_dir': targetDir},
    );
    await loadTree();
    final data = response.data;
    final newPath = data is Map && data['new_path'] != null
        ? data['new_path'].toString()
        : _joinScriptPath(targetDir, sourcePath.split('/').last);

    final selected = state.selectedPath;
    if (selected == sourcePath) {
      state = state.copyWith(selectedPath: newPath);
    } else if (selected != null && selected.startsWith('$sourcePath/')) {
      state = state.copyWith(
        selectedPath: selected.replaceFirst(sourcePath, newPath),
      );
    }
    return newPath;
  }

  Future<String> copyPath(
    String sourcePath, {
    String targetDir = '',
    String newName = '',
  }) async {
    final response = await _dio.post(
      ApiEndpoints.scriptsCopy,
      data: {
        'source_path': sourcePath,
        'target_dir': targetDir,
        'new_name': newName,
      },
    );
    await loadTree();
    final data = response.data;
    if (data is Map && data['new_path'] != null) {
      return data['new_path'].toString();
    }
    final finalName = newName.trim().isEmpty
        ? sourcePath.split('/').last
        : newName.trim();
    return _joinScriptPath(targetDir, finalName);
  }

  Future<void> deletePath(String path, {required bool isDirectory}) async {
    await _dio.delete(
      ApiEndpoints.scripts,
      queryParameters: {
        'path': path,
        'type': isDirectory ? 'directory' : 'file',
      },
    );
    await loadTree();
    final selected = state.selectedPath;
    if (selected == path ||
        (isDirectory && (selected?.startsWith('$path/') ?? false))) {
      state = state.copyWith(selectedPath: null, content: '', isBinary: false);
    }
  }

  Future<List<ScriptVersionRecord>> listVersions(String path) async {
    final resp = await _dio.get(
      ApiEndpoints.scriptsVersions,
      queryParameters: {'path': path},
    );
    final data = extractData(resp.data);
    if (data is! List) {
      return const [];
    }
    return data
        .whereType<Map>()
        .map(
          (item) =>
              ScriptVersionRecord.fromJson(Map<String, dynamic>.from(item)),
        )
        .toList();
  }

  Future<void> rollbackVersion(int versionId, String path) async {
    await _dio.put(ApiEndpoints.scriptVersionRollback(versionId));
    await loadTree();
    await loadContent(path);
  }

  Future<String> formatContent(String path, String content) async {
    final language = _detectFormatterLanguage(path);
    if (language == null) {
      throw StateError('该文件类型不支持格式化');
    }
    final resp = await _dio.post(
      ApiEndpoints.scriptsFormat,
      data: {'content': content, 'language': language},
    );
    final data = extractData(resp.data);
    final formatted = data is Map
        ? data['content']?.toString() ?? content
        : content;
    state = state.copyWith(content: formatted, isBinary: false);
    return formatted;
  }

  Future<MultipartFile?> _toMultipartFile(PlatformFile file) async {
    if (file.path != null && file.path!.isNotEmpty) {
      return MultipartFile.fromFile(file.path!, filename: file.name);
    }
    if (file.bytes != null) {
      return MultipartFile.fromBytes(file.bytes!, filename: file.name);
    }
    return null;
  }
}

class ScriptListPage extends ConsumerStatefulWidget {
  const ScriptListPage({super.key});

  @override
  ConsumerState<ScriptListPage> createState() => _ScriptListPageState();
}

class _ScriptListPageState extends ConsumerState<ScriptListPage> {
  static const _favoriteScriptsStorageKey = 'scripts.favorite_paths';
  final _searchController = TextEditingController();
  final Set<String> _favoriteScriptPaths = <String>{};

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      final favorites = await SecureStorage.getUiStateList(
        _favoriteScriptsStorageKey,
      );
      if (mounted) {
        setState(() {
          _favoriteScriptPaths
            ..clear()
            ..addAll(favorites);
        });
      }
      await ref.read(scriptProvider.notifier).loadTree();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _showMessage(String message) => AppSnack.show(context, message);

  void _showSuccess(String message) => AppSnack.success(context, message);

  void _showError(String message) => AppSnack.error(context, message);

  void _showWarning(String message) => AppSnack.warn(context, message);

  String _extractScriptError(dynamic error, String fallback) =>
      extractScriptSaveErrorMessage(error, fallback);

  Future<void> _openScript(String path) async {
    await ref.read(scriptProvider.notifier).loadContent(path);
    if (!mounted) {
      return;
    }
    context.push('/scripts/view', extra: path);
  }

  Future<void> _persistFavoriteScripts() {
    return SecureStorage.saveUiStateList(
      _favoriteScriptsStorageKey,
      _favoriteScriptPaths.toList(),
    );
  }

  Future<void> _toggleFavoriteScript(ScriptFile file) async {
    setState(() {
      if (_favoriteScriptPaths.contains(file.path)) {
        _favoriteScriptPaths.remove(file.path);
      } else {
        _favoriteScriptPaths.add(file.path);
      }
    });
    await _persistFavoriteScripts();
    if (!mounted) {
      return;
    }
    _showSuccess(
      _favoriteScriptPaths.contains(file.path) ? '已置顶脚本' : '已取消置顶脚本',
    );
  }

  List<ScriptFile> _filterTree(List<ScriptFile> nodes, String keyword) {
    final query = keyword.trim().toLowerCase();
    if (query.isEmpty) {
      return nodes;
    }

    List<ScriptFile> visit(List<ScriptFile> items) {
      final result = <ScriptFile>[];
      for (final item in items) {
        final children = visit(item.children);
        final matched =
            item.name.toLowerCase().contains(query) ||
            item.path.toLowerCase().contains(query);
        if (matched || children.isNotEmpty) {
          result.add(
            ScriptFile(
              name: item.name,
              path: item.path,
              isDirectory: item.isDirectory,
              children: children,
            ),
          );
        }
      }
      return result;
    }

    return visit(nodes);
  }

  TaskFormPrefill _taskPrefillFromScriptPath(String path) {
    final fileName = path.split('/').last;
    final taskName = fileName.replaceFirst(RegExp(r'\.[^/.]+$'), '');
    return TaskFormPrefill(name: taskName, command: 'task $path');
  }

  Future<void> _navigateToTaskWithScript(String path) async {
    if (!mounted) {
      return;
    }
    await context.push('/tasks/new', extra: _taskPrefillFromScriptPath(path));
  }

  Future<void> _maybePromptAddToTask(String path) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('加入任务'),
        content: Text('脚本「${path.split('/').last}」上传成功，是否直接添加到定时任务？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('稍后再说'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('立即添加'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await _navigateToTaskWithScript(path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(scriptProvider);
    final isLight = Theme.of(context).brightness == Brightness.light;
    final visibleTree = _sortScriptTree(_filterTree(state.tree, state.keyword));

    return Scaffold(
      body: Padding(
        padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 12),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  const AppBackButton(),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '脚本管理',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => ref.read(scriptProvider.notifier).loadTree(),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.refresh, size: 22),
                    ),
                  ),
                  const SizedBox(width: 8),
                  PopupMenuButton<_ScriptAction>(
                    onSelected: (action) => _handleAction(action, state),
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: _ScriptAction.upload,
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.upload_file_outlined, size: 20),
                          title: Text('上传脚本'),
                        ),
                      ),
                      PopupMenuItem(
                        value: _ScriptAction.createFile,
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.note_add_outlined, size: 20),
                          title: Text('新建脚本'),
                        ),
                      ),
                      PopupMenuItem(
                        value: _ScriptAction.createDirectory,
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            Icons.create_new_folder_outlined,
                            size: 20,
                          ),
                          title: Text('新建文件夹'),
                        ),
                      ),
                    ],
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
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: '搜索脚本名称或路径...',
                  prefixIcon: const Icon(
                    Icons.search,
                    size: 18,
                    color: AppColors.slate400,
                  ),
                  suffixIcon: _searchController.text.trim().isEmpty
                      ? null
                      : IconButton(
                          onPressed: () {
                            _searchController.clear();
                            ref.read(scriptProvider.notifier).setKeyword('');
                            setState(() {});
                          },
                          icon: const Icon(Icons.clear, size: 18),
                        ),
                ),
                onChanged: (value) {
                  ref.read(scriptProvider.notifier).setKeyword(value);
                  setState(() {});
                },
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: state.loading
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: AppColors.primary,
                      ),
                    )
                  // 拿不到数据和真的没有脚本是两回事，必须先判 error。
                  : state.error != null && state.tree.isEmpty
                  ? RefreshIndicator(
                      color: AppColors.primary,
                      onRefresh: () =>
                          ref.read(scriptProvider.notifier).loadTree(),
                      child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          AppErrorView(
                            title: '脚本加载失败',
                            message: state.error!,
                            onRetry: () =>
                                ref.read(scriptProvider.notifier).loadTree(),
                          ),
                        ],
                      ),
                    )
                  : visibleTree.isEmpty
                  ? _buildEmpty(state)
                  : RefreshIndicator(
                      color: AppColors.primary,
                      onRefresh: () =>
                          ref.read(scriptProvider.notifier).loadTree(),
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                        children: visibleTree
                            .map(
                              (file) => _FileTreeItem(
                                file: file,
                                isLight: isLight,
                                depth: 0,
                                onTap: (path) => _openScript(path),
                                onAction: (entry) =>
                                    _handleEntryAction(entry, state),
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

  Widget _buildEmpty(ScriptState state) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.folder_off,
            size: 56,
            color: AppColors.slate400.withAlpha(120),
          ),
          const SizedBox(height: 12),
          const Text('暂无脚本', style: TextStyle(color: AppColors.slate400)),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => _handleAction(_ScriptAction.upload, state),
                icon: const Icon(Icons.upload_file_outlined),
                label: const Text('上传脚本'),
              ),
              OutlinedButton.icon(
                onPressed: () => _handleAction(_ScriptAction.createFile, state),
                icon: const Icon(Icons.note_add_outlined),
                label: const Text('新建脚本'),
              ),
              OutlinedButton.icon(
                onPressed: () =>
                    _handleAction(_ScriptAction.createDirectory, state),
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('新建文件夹'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _handleAction(_ScriptAction action, ScriptState state) async {
    switch (action) {
      case _ScriptAction.upload:
        await _pickAndUploadFiles(state);
        return;
      case _ScriptAction.createFile:
        await _showCreateFileDialog(state);
        return;
      case _ScriptAction.createDirectory:
        await _showCreateDirectoryDialog(state);
        return;
    }
  }

  Future<void> _handleEntryAction(ScriptFile file, ScriptState state) async {
    final action = await showModalBottomSheet<_ScriptEntryAction>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        // 菜单项较多时限制底部菜单高度，并允许上下滚动，避免“删除”入口被小屏幕截掉。
        final maxSheetHeight = MediaQuery.sizeOf(sheetContext).height * 0.8;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxSheetHeight),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!file.isDirectory)
                    ListTile(
                      leading: const Icon(Icons.open_in_new),
                      title: const Text('打开脚本'),
                      onTap: () =>
                          Navigator.pop(sheetContext, _ScriptEntryAction.open),
                    ),
                  if (!file.isDirectory)
                    ListTile(
                      leading: const Icon(Icons.playlist_add_outlined),
                      title: const Text('加入任务'),
                      onTap: () => Navigator.pop(
                        sheetContext,
                        _ScriptEntryAction.addToTask,
                      ),
                    ),
                  if (!file.isDirectory)
                    ListTile(
                      leading: const Icon(Icons.download_outlined),
                      title: const Text('下载'),
                      onTap: () => Navigator.pop(
                        sheetContext,
                        _ScriptEntryAction.download,
                      ),
                    ),
                  if (!file.isDirectory)
                    ListTile(
                      leading: Icon(
                        _favoriteScriptPaths.contains(file.path)
                            ? Icons.push_pin_outlined
                            : Icons.push_pin,
                      ),
                      title: Text(
                        _favoriteScriptPaths.contains(file.path)
                            ? '取消置顶'
                            : '置顶到前面',
                      ),
                      onTap: () => Navigator.pop(
                        sheetContext,
                        _ScriptEntryAction.favorite,
                      ),
                    ),
                  if (!file.isDirectory)
                    ListTile(
                      leading: const Icon(Icons.history_outlined),
                      title: const Text('版本历史'),
                      onTap: () => Navigator.pop(
                        sheetContext,
                        _ScriptEntryAction.versions,
                      ),
                    ),
                  ListTile(
                    leading: const Icon(Icons.drive_file_move_outline),
                    title: Text(file.isDirectory ? '移动文件夹' : '移动文件'),
                    onTap: () =>
                        Navigator.pop(sheetContext, _ScriptEntryAction.move),
                  ),
                  ListTile(
                    leading: const Icon(Icons.copy_outlined),
                    title: Text(file.isDirectory ? '复制文件夹' : '复制文件'),
                    onTap: () =>
                        Navigator.pop(sheetContext, _ScriptEntryAction.copy),
                  ),
                  if (file.isDirectory)
                    ListTile(
                      leading: const Icon(Icons.upload_file_outlined),
                      title: const Text('上传到此处'),
                      onTap: () => Navigator.pop(
                        sheetContext,
                        _ScriptEntryAction.uploadHere,
                      ),
                    ),
                  if (file.isDirectory)
                    ListTile(
                      leading: const Icon(Icons.note_add_outlined),
                      title: const Text('在此新建脚本'),
                      onTap: () => Navigator.pop(
                        sheetContext,
                        _ScriptEntryAction.createFileHere,
                      ),
                    ),
                  if (file.isDirectory)
                    ListTile(
                      leading: const Icon(Icons.create_new_folder_outlined),
                      title: const Text('在此新建文件夹'),
                      onTap: () => Navigator.pop(
                        sheetContext,
                        _ScriptEntryAction.createDirectoryHere,
                      ),
                    ),
                  ListTile(
                    leading: const Icon(Icons.drive_file_rename_outline),
                    title: const Text('重命名'),
                    onTap: () =>
                        Navigator.pop(sheetContext, _ScriptEntryAction.rename),
                  ),
                  ListTile(
                    leading: const Icon(
                      Icons.delete_outline,
                      color: AppColors.red500,
                    ),
                    title: const Text(
                      '删除',
                      style: TextStyle(color: AppColors.red500),
                    ),
                    onTap: () =>
                        Navigator.pop(sheetContext, _ScriptEntryAction.delete),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    if (action == null) {
      return;
    }

    switch (action) {
      case _ScriptEntryAction.open:
        await _openScript(file.path);
        return;
      case _ScriptEntryAction.addToTask:
        await _navigateToTaskWithScript(file.path);
        return;
      case _ScriptEntryAction.favorite:
        await _toggleFavoriteScript(file);
        return;
      case _ScriptEntryAction.download:
        await _downloadScript(file);
        return;
      case _ScriptEntryAction.move:
        await _showMoveDialog(file, state);
        return;
      case _ScriptEntryAction.copy:
        await _showCopyDialog(file, state);
        return;
      case _ScriptEntryAction.rename:
        await _showRenameDialog(file);
        return;
      case _ScriptEntryAction.delete:
        await _confirmDelete(file);
        return;
      case _ScriptEntryAction.versions:
        await _showVersionSheet(file.path);
        return;
      case _ScriptEntryAction.uploadHere:
        await _pickAndUploadFiles(state, initialDir: file.path);
        return;
      case _ScriptEntryAction.createFileHere:
        await _showCreateFileDialog(state, initialParent: file.path);
        return;
      case _ScriptEntryAction.createDirectoryHere:
        await _showCreateDirectoryDialog(state, initialParent: file.path);
        return;
    }
  }

  List<ScriptFile> _sortScriptTree(List<ScriptFile> nodes) {
    final items = nodes
        .map(
          (node) => ScriptFile(
            name: node.name,
            path: node.path,
            isDirectory: node.isDirectory,
            children: _sortScriptTree(node.children),
          ),
        )
        .toList();

    items.sort((a, b) {
      if (a.isDirectory != b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      final aFavorite = _favoriteScriptPaths.contains(a.path);
      final bFavorite = _favoriteScriptPaths.contains(b.path);
      if (aFavorite != bFavorite) {
        return aFavorite ? -1 : 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return items;
  }

  Future<void> _showRenameDialog(ScriptFile file) async {
    final controller = TextEditingController(text: file.name);
    final parent = _defaultScriptDirectory(file.path);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final navigator = Navigator.of(dialogContext);
        return AlertDialog(
          title: Text(file.isDirectory ? '重命名文件夹' : '重命名脚本'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (parent.isNotEmpty) ...[
                Text(
                  '所在目录：$parent',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.slate500,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: controller,
                decoration: const InputDecoration(labelText: '新名称'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => navigator.pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                final newName = controller.text.trim();
                if (newName.isEmpty) {
                  _showWarning('名称不能为空');
                  return;
                }
                try {
                  final newPath = await ref
                      .read(scriptProvider.notifier)
                      .renamePath(file.path, newName);
                  if (!mounted) {
                    return;
                  }
                  navigator.pop();
                  _showSuccess('已重命名为 ${newPath.split('/').last}');
                } catch (error) {
                  if (!mounted) {
                    return;
                  }
                  _showError(_extractRequestError(error, '重命名失败'));
                }
              },
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _confirmDelete(ScriptFile file) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(file.isDirectory ? '删除文件夹' : '删除脚本'),
        content: Text(
          file.isDirectory
              ? '确定要删除文件夹「${file.name}」吗？其中的所有内容都会一起删除。'
              : '确定要删除脚本「${file.name}」吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.red500),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm != true) {
      return;
    }
    try {
      await ref
          .read(scriptProvider.notifier)
          .deletePath(file.path, isDirectory: file.isDirectory);
      _showSuccess(file.isDirectory ? '文件夹已删除' : '脚本已删除');
    } catch (error) {
      _showError(_extractRequestError(error, '删除失败'));
    }
  }

  Future<void> _downloadScript(ScriptFile file) async {
    try {
      final response = await DioClient.instance.dio.get(
        ApiEndpoints.scriptsDownload(file.path),
        options: Options(responseType: ResponseType.bytes),
      );
      final bytes = extractResponseBytes(response.data);
      if (bytes == null || bytes.isEmpty) {
        throw StateError('下载内容为空');
      }

      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: '保存脚本文件',
        fileName: file.name,
        type: FileType.any,
        bytes: bytes,
      );
      if (savedPath == null) {
        // 用户自己在系统保存框里按了取消，不是失败，保持中性。
        _showMessage('已取消保存');
        return;
      }

      _showSuccess('脚本已保存');
    } on UnsupportedError {
      // 平台能力缺失而不是这次操作出错，用警告。
      _showWarning('当前平台暂不支持直接保存文件');
    } catch (error) {
      _showError(_extractScriptError(error, '下载脚本失败'));
    }
  }

  Future<void> _showMoveDialog(ScriptFile file, ScriptState state) async {
    final folders = _scriptFolders(
      state.tree,
    ).where((folder) => folder != file.path).toList();
    String targetDir = _defaultScriptDirectory(file.path);

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final navigator = Navigator.of(dialogContext);
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(file.isDirectory ? '移动文件夹' : '移动文件'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '当前路径：${file.path}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.slate500,
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: targetDir,
                  decoration: const InputDecoration(labelText: '目标目录'),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('根目录')),
                    ...folders.map(
                      (folder) =>
                          DropdownMenuItem(value: folder, child: Text(folder)),
                    ),
                  ],
                  onChanged: (value) {
                    setDialogState(() => targetDir = value ?? '');
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => navigator.pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () async {
                  try {
                    final newPath = await ref
                        .read(scriptProvider.notifier)
                        .movePath(file.path, targetDir: targetDir);
                    if (!mounted) {
                      return;
                    }
                    navigator.pop();
                    _showSuccess('已移动到 ${newPath.split('/').last}');
                  } catch (error) {
                    if (!mounted) {
                      return;
                    }
                    _showError(_extractScriptError(error, '移动失败'));
                  }
                },
                child: const Text('移动'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showCopyDialog(ScriptFile file, ScriptState state) async {
    final folders = _scriptFolders(state.tree);
    final nameController = TextEditingController(text: file.name);
    String targetDir = _defaultScriptDirectory(file.path);

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final navigator = Navigator.of(dialogContext);
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(file.isDirectory ? '复制文件夹' : '复制文件'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '来源：${file.path}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.slate500,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: nameController,
                    decoration: InputDecoration(
                      labelText: file.isDirectory ? '新文件夹名' : '新文件名',
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: targetDir,
                    decoration: const InputDecoration(labelText: '目标目录'),
                    items: [
                      const DropdownMenuItem(value: '', child: Text('根目录')),
                      ...folders.map(
                        (folder) => DropdownMenuItem(
                          value: folder,
                          child: Text(folder),
                        ),
                      ),
                    ],
                    onChanged: (value) {
                      setDialogState(() => targetDir = value ?? '');
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => navigator.pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () async {
                  final newName = nameController.text.trim();
                  if (newName.isEmpty) {
                    _showWarning('名称不能为空');
                    return;
                  }
                  try {
                    final newPath = await ref
                        .read(scriptProvider.notifier)
                        .copyPath(
                          file.path,
                          targetDir: targetDir,
                          newName: newName,
                        );
                    if (!mounted) {
                      return;
                    }
                    navigator.pop();
                    _showSuccess('已复制到 ${newPath.split('/').last}');
                  } catch (error) {
                    if (!mounted) {
                      return;
                    }
                    _showError(_extractScriptError(error, '复制失败'));
                  }
                },
                child: const Text('复制'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showVersionSheet(String path) async {
    if (!mounted) {
      return;
    }
    // 面板返回 true 表示真的回滚了。列表页这边没有编辑器缓冲区要同步，
    // 用不上这个结果，但类型要跟 pop 出来的值对齐。
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _ScriptVersionSheet(path: path),
    );
  }

  Future<void> _showCreateFileDialog(
    ScriptState state, {
    String? initialParent,
  }) async {
    final nameController = TextEditingController();
    final folders = _scriptFolders(state.tree);
    String parent =
        initialParent ?? _defaultScriptDirectory(state.selectedPath);

    await showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) {
        final navigator = Navigator.of(dialogContext);
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('新建脚本'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      labelText: '文件名',
                      hintText: '例如 demo.py / test.js / run.sh',
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: parent,
                    decoration: const InputDecoration(labelText: '保存目录'),
                    items: [
                      const DropdownMenuItem(value: '', child: Text('根目录')),
                      ...folders.map(
                        (folder) => DropdownMenuItem(
                          value: folder,
                          child: Text(folder),
                        ),
                      ),
                    ],
                    onChanged: (value) {
                      setDialogState(() => parent = value ?? '');
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => navigator.pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () async {
                  final fileName = nameController.text.trim();
                  if (fileName.isEmpty) {
                    _showWarning('文件名不能为空');
                    return;
                  }
                  final fullPath = _joinScriptPath(parent, fileName);
                  try {
                    await ref
                        .read(scriptProvider.notifier)
                        .createFile(fullPath);
                    if (!mounted) {
                      return;
                    }
                    navigator.pop();
                    await _openScript(fullPath);
                  } catch (error) {
                    if (!mounted) {
                      return;
                    }
                    _showError(_extractRequestError(error, '创建脚本失败'));
                  }
                },
                child: const Text('创建'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showCreateDirectoryDialog(
    ScriptState state, {
    String? initialParent,
  }) async {
    final nameController = TextEditingController();
    final folders = _scriptFolders(state.tree);
    String parent =
        initialParent ?? _defaultScriptDirectory(state.selectedPath);

    await showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) {
        final navigator = Navigator.of(dialogContext);
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('新建文件夹'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(labelText: '文件夹名称'),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: parent,
                    decoration: const InputDecoration(labelText: '上级目录'),
                    items: [
                      const DropdownMenuItem(value: '', child: Text('根目录')),
                      ...folders.map(
                        (folder) => DropdownMenuItem(
                          value: folder,
                          child: Text(folder),
                        ),
                      ),
                    ],
                    onChanged: (value) {
                      setDialogState(() => parent = value ?? '');
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => navigator.pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () async {
                  final name = nameController.text.trim();
                  if (name.isEmpty) {
                    _showWarning('文件夹名称不能为空');
                    return;
                  }
                  try {
                    await ref
                        .read(scriptProvider.notifier)
                        .createDirectory(_joinScriptPath(parent, name));
                    if (!mounted) {
                      return;
                    }
                    navigator.pop();
                    _showSuccess('文件夹创建成功');
                  } catch (error) {
                    if (!mounted) {
                      return;
                    }
                    _showError(_extractRequestError(error, '创建文件夹失败'));
                  }
                },
                child: const Text('创建'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _pickAndUploadFiles(
    ScriptState state, {
    String initialDir = '',
  }) async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
    );
    if (result == null || result.files.isEmpty || !mounted) {
      return;
    }
    await _showUploadDialog(state, result.files, initialDir: initialDir);
  }

  Future<void> _showUploadDialog(
    ScriptState state,
    List<PlatformFile> files, {
    String initialDir = '',
  }) async {
    final folders = _scriptFolders(state.tree);
    String targetDir = initialDir.isNotEmpty
        ? initialDir
        : _defaultScriptDirectory(state.selectedPath);

    await showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) {
        final navigator = Navigator.of(dialogContext);
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('上传脚本'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '已选择 ${files.length} 个文件',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  // AppCard 没有 constraints 参数，限高交给外层 ConstrainedBox。
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 160),
                    child: AppCard(
                      // 列表自带滚动内边距，卡片不再补一层。
                      padding: EdgeInsets.zero,
                      radius: AppRadius.md,
                      // 弹窗里的次级块：浅色是 slate50、深色是 slate900，
                      // 两边都无描边，必须显式传入。
                      bordered: false,
                      color: Theme.of(context).brightness == Brightness.light
                          ? AppColors.slate50
                          : AppColors.slate900,
                      child: ListView.separated(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        itemCount: files.length,
                        separatorBuilder: (context, index) =>
                            const Divider(height: 12, thickness: 0.6),
                        itemBuilder: (_, index) => Text(
                          files[index].name,
                          style: const TextStyle(fontSize: 12),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: targetDir,
                    decoration: const InputDecoration(labelText: '上传目录'),
                    items: [
                      const DropdownMenuItem(value: '', child: Text('根目录')),
                      ...folders.map(
                        (folder) => DropdownMenuItem(
                          value: folder,
                          child: Text(folder),
                        ),
                      ),
                    ],
                    onChanged: (value) {
                      setDialogState(() => targetDir = value ?? '');
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => navigator.pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () async {
                  try {
                    final paths = await ref
                        .read(scriptProvider.notifier)
                        .uploadFiles(files, dir: targetDir);
                    if (!mounted) {
                      return;
                    }
                    navigator.pop();
                    _showSuccess(
                      paths.length > 1 ? '成功上传 ${paths.length} 个文件' : '上传成功',
                    );
                    if (paths.length == 1) {
                      await _openScript(paths.first);
                      if (!mounted) {
                        return;
                      }
                      await _maybePromptAddToTask(paths.first);
                    }
                  } catch (error) {
                    if (!mounted) {
                      return;
                    }
                    _showError(_extractScriptError(error, '上传失败'));
                  }
                },
                child: const Text('上传'),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _FileTreeItem extends StatefulWidget {
  final ScriptFile file;
  final bool isLight;
  final int depth;
  final ValueChanged<String> onTap;
  final ValueChanged<ScriptFile> onAction;

  const _FileTreeItem({
    required this.file,
    required this.isLight,
    required this.depth,
    required this.onTap,
    required this.onAction,
  });

  @override
  State<_FileTreeItem> createState() => _FileTreeItemState();
}

class _FileTreeItemState extends State<_FileTreeItem> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final file = widget.file;
    final indent = widget.depth * 16.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppCard(
          onLongPress: () => widget.onAction(file),
          onTap: () {
            if (file.isDirectory) {
              setState(() => _expanded = !_expanded);
            } else {
              widget.onTap(file.path);
            }
          },
          margin: const EdgeInsets.only(bottom: 2),
          // 这一行的高度由右侧那个 40dp 的溢出按钮决定，不是由文字决定：
          // 文字只有 15.2dp，纵向内边距压到 6 之后，图标周围观感上仍有 17dp 空白，
          // 整行 52dp（含 margin 56dp）也还在 Material 密集列表的正常区间。
          padding: EdgeInsets.only(
            left: 12 + indent,
            right: 8,
            top: 6,
            bottom: 6,
          ),
          radius: AppRadius.sm,
          // 文件树是嵌在卡片里的密集列表，浅色描边比常规卡片淡一档
          // （slate100 而不是 slate200），必须显式传入。
          borderColor: widget.isLight ? AppColors.slate100 : AppColors.slate800,
          child: Row(
            children: [
              Icon(
                file.isDirectory
                    ? (_expanded ? Icons.folder_open : Icons.folder)
                    : Icons.description_outlined,
                size: 18,
                color: file.isDirectory
                    ? AppColors.amber500
                    : AppColors.slate400,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  file.name,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: file.isDirectory
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (file.isDirectory)
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: AppColors.slate400,
                ),
              IconButton(
                onPressed: () => widget.onAction(file),
                icon: const Icon(Icons.more_vert, size: 18),
                // compact 是 -2 档，把 48 压到 40。取 -1 档的 44：过线，
                // 又不像直接删掉那样让每个文件行都长高 8dp。
                visualDensity: const VisualDensity(horizontal: -1, vertical: -1),
                color: AppColors.slate400,
                splashRadius: 18,
              ),
            ],
          ),
        ),
        if (_expanded && file.isDirectory)
          ...file.children.map(
            (child) => _FileTreeItem(
              file: child,
              isLight: widget.isLight,
              depth: widget.depth + 1,
              onTap: widget.onTap,
              onAction: widget.onAction,
            ),
          ),
      ],
    );
  }
}

class ScriptViewPage extends ConsumerStatefulWidget {
  final String path;

  const ScriptViewPage({super.key, required this.path});

  @override
  ConsumerState<ScriptViewPage> createState() => _ScriptViewPageState();
}

class _ScriptViewPageState extends ConsumerState<ScriptViewPage> {
  /// 编辑器内边距。行号栏要拿它当滚动视口的起点，所以必须是常量而不是字面量 ——
  /// 两边一旦写岔，行号会整体错位。
  static const _editorContentPadding = EdgeInsets.all(14);

  /// TextField 在排版**之前**额外扣掉的光标余量。
  ///
  /// = `RenderEditable._kCaretGap`(1.0) + `TextField.cursorWidth` 默认值 2.0，
  /// 即 SDK `rendering/editable.dart` 里的 `RenderEditable._caretMargin`；
  /// 多行输入框走 `_adjustConstraints`，实际断行宽度是 `maxWidth - _caretMargin`。
  ///
  /// ⚠️ 别把这一项「简化」掉：行号栏那份 TextPainter 拿不到这层扣减，某一行的宽度
  /// 恰好落在这 3px 带里时，TextField 把它折成 2 条视觉行、行号栏却认为只占 1 条，
  /// 从那一行往下所有行号整体错开一个行高；同一份几何还喂给 `_scrollToMatch`，
  /// 「下一个」也会跟着跳偏一整行。
  static const double _editorCaretMargin = 3.0;

  late final ScriptHighlightController _contentController;
  late final FocusNode _contentFocusNode;
  final ScrollController _contentScrollController = ScrollController();
  final TextEditingController _findController = TextEditingController();
  bool _editing = false;
  bool _debugRunning = false;
  Color? _editorBackgroundColor;

  /// 查找条是否常驻在编辑器上方。
  bool _findBarVisible = false;

  /// 当前查询词，以及它在全文里的全部命中起点、当前停在第几个。
  ///
  /// ⚠️ 搜索游标是**独立状态**，绝不能再寄存到 `controller.selection` 上：
  /// selection 会被输入法、焦点切换、内容刷新随时改写，一被改写「下一个」就退回
  /// 从头找 —— issue #6 (c)「点下一个不跳转」就是这么来的。
  String _matchQuery = '';
  List<int> _matchOffsets = const [];
  int _currentMatchIndex = -1;

  /// 命中数是否被 [kScriptSearchMatchLimit] 截断过（决定计数显示成 `500` 还是 `500+`）。
  bool _matchTruncated = false;

  /// 编辑器文本几何缓存。行号栏与搜索滚动共用**同一份** TextPainter 度量。
  ScriptEditorTextMetrics? _editorMetrics;

  /// `_contentController` 上一次的文本。
  ///
  /// controller 是 ValueNotifier，**移动光标、改选区、输入法组合**都会通知过来，
  /// 而这些跟命中偏移毫无关系。缓存上一次的 text 比对一下，才能只在内容真的变了时
  /// 重扫全文。
  String _lastContentText = '';

  @override
  void initState() {
    super.initState();
    _contentController = ScriptHighlightController();
    _contentController.addListener(_handleContentChanged);
    _contentFocusNode = FocusNode();
    Future.microtask(() async {
      await ref.read(scriptProvider.notifier).loadContent(widget.path);
      if (!mounted) {
        return;
      }
      // 兜底：build 里的 ref.listen 只对「注册之后」的变化生效。万一这次加载比首帧
      // 还早完成，就靠这一句把内容补进编辑器；内容一致时它是空操作。
      _applyContentFromState(ref.read(scriptProvider).content);
      await _loadEditorAppearance();
    });
  }

  @override
  void dispose() {
    _editorMetrics?.dispose();
    _contentScrollController.dispose();
    _contentController.removeListener(_handleContentChanged);
    _contentController.dispose();
    _findController.dispose();
    _contentFocusNode.dispose();
    super.dispose();
  }

  void _showSuccess(String message) => AppSnack.success(context, message);

  void _showError(String message) => AppSnack.error(context, message);

  String _extractScriptError(dynamic error, String fallback) =>
      extractScriptSaveErrorMessage(error, fallback);

  TaskFormPrefill _taskPrefill() {
    final fileName = widget.path.split('/').last;
    final taskName = fileName.replaceFirst(RegExp(r'\.[^/.]+$'), '');
    return TaskFormPrefill(name: taskName, command: 'task ${widget.path}');
  }

  /// 现在能不能把编辑器缓冲区写回服务端。
  ///
  /// 「缓冲区里装的确实是本文件的正文」这件事只有三个条件同时成立才为真。
  /// 单靠 UI 上的 `editable` 不够：`_debugRun` 会自作主张先存一次，将来还可能有别的入口，
  /// 所以在写入口本身也守一道。少存一次只是麻烦，存错一次是把用户的脚本冲掉。
  bool get _canPersist {
    final state = ref.read(scriptProvider);
    return !state.loadingContent &&
        state.selectedPath == widget.path &&
        state.contentError == null &&
        !state.isBinary;
  }

  Future<void> _save() async {
    if (!_canPersist) {
      _showError('脚本内容尚未加载完成，暂时不能保存');
      return;
    }
    try {
      await ref
          .read(scriptProvider.notifier)
          .saveContent(widget.path, _contentController.text);
      if (!mounted) {
        return;
      }
      setState(() => _editing = false);
      _showSuccess('保存成功');
    } catch (error) {
      _showError(_extractScriptError(error, '保存失败'));
    }
  }

  Future<void> _format() async {
    try {
      final formatted = await ref
          .read(scriptProvider.notifier)
          .formatContent(widget.path, _contentController.text);
      if (!mounted) {
        return;
      }
      // 编辑模式下 ref.listen 会跳过同步（不能覆盖用户正在敲的东西），
      // 所以格式化结果必须在这里显式落回编辑器。
      _applyContentFromState(formatted);
      if (!_editing) {
        setState(() => _editing = true);
      }
      _showSuccess('格式化完成');
    } catch (error) {
      final message = error is StateError
          ? error.message
          : _extractRequestError(error, '格式化失败');
      _showError(message);
    }
  }

  Future<void> _showVersions() async {
    if (!mounted) {
      return;
    }
    final rolledBack = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _ScriptVersionSheet(path: widget.path),
    );
    if (!mounted || rolledBack != true) {
      return;
    }
    // 回滚会改服务端内容，但 build 里的 ref.listen 在编辑模式下**不同步**
    // （那是为了不覆盖用户正在敲的东西）。不在这里显式落回的话，
    // 用户会看到「提示已回滚、编辑器里还是回滚前的正文」，再点一次保存
    // 就把刚回滚掉的内容原样 PUT 回去 —— 回滚被静默撤销。
    // 回滚本身就意味着「以服务端为准」，所以顺带退出编辑模式、丢弃本地未保存修改；
    // 只翻版本没回滚时 rolledBack 不为 true，走不到这里，未保存的修改不受影响。
    final next = ref.read(scriptProvider);
    if (next.selectedPath != widget.path ||
        next.contentError != null ||
        next.isBinary) {
      return;
    }
    if (_editing) {
      setState(() => _editing = false);
    }
    _applyContentFromState(next.content);
  }

  Future<void> _debugRun() async {
    if (_debugRunning) {
      return;
    }

    if (_editing) {
      await _save();
    }

    setState(() => _debugRunning = true);
    try {
      final resp = await DioClient.instance.dio.post(
        ApiEndpoints.scriptsRun,
        data: {'path': widget.path},
      );
      final raw = resp.data;
      String? runId;
      if (raw is Map && raw['run_id'] != null) {
        runId = raw['run_id'].toString();
      } else if (raw is Map &&
          raw['data'] is Map &&
          raw['data']['run_id'] != null) {
        runId = raw['data']['run_id'].toString();
      }
      if (runId == null || runId.isEmpty) {
        throw StateError('调试任务已启动，但未返回运行 ID');
      }

      if (!mounted) {
        return;
      }
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) =>
            _ScriptDebugRunSheet(path: widget.path, runId: runId!),
      );
    } catch (error) {
      _showError(_extractScriptError(error, '调试运行失败'));
    } finally {
      if (mounted) {
        setState(() => _debugRunning = false);
      }
    }
  }

  Future<void> _loadEditorAppearance() async {
    // 编辑器底色与日志底色是两个不同的面板配置项，但取数与解析完全同一套，
    // 统一走 shared/utils/log_background.dart，别再在页面里复制一份解析器。
    final color = await loadPanelColorSetting('editor_background_color');
    if (!mounted) {
      return;
    }
    setState(() => _editorBackgroundColor = color);
  }

  bool _useLightForeground(Color background) =>
      background.computeLuminance() < 0.45;

  /// 编辑器正文样式。
  ///
  /// 那些「看起来多余」的字段是**必须**写死的：TextField 会把 style 合并到主题的
  /// `bodyLarge` 上（M3 的 bodyLarge 自带 `letterSpacing: 0.5`），而行号栏另建的
  /// TextPainter 拿不到这层合并。字宽一旦对不上，软换行的断点就会分叉，
  /// 行号会越往下偏得越多。把影响度量的字段全部钉死，两边算的才是同一件事。
  ///
  /// ⚠️ 需要 context 是因为**系统「无障碍 → 粗体文字」**这一层：SDK 的
  /// `EditableText.didChangeDependencies` 里会做
  /// `_style = MediaQuery.boldTextOf(context) ? widget.style.merge(bold) : widget.style`，
  /// 行号栏那份 TextPainter 同样拿不到它。开着粗体文字时 TextField 按 bold 排版
  /// （字宽变大、断行提前）、行号栏还按 w400 算，长行脚本从第一处软换行起就整体错位，
  /// 越往下差得越多。这里提前把同一层 merge 做掉，strut 也由它派生，两边才对得齐。
  static TextStyle _editorTextStyle(BuildContext context, Color color) {
    const base = TextStyle(
      fontSize: 13,
      fontFamily: 'monospace',
      height: 1.5,
      fontWeight: FontWeight.w400,
      fontStyle: FontStyle.normal,
      letterSpacing: 0,
      wordSpacing: 0,
      textBaseline: TextBaseline.alphabetic,
      leadingDistribution: TextLeadingDistribution.even,
    );
    final style = base.copyWith(color: color);
    return MediaQuery.boldTextOf(context)
        ? style.merge(const TextStyle(fontWeight: FontWeight.bold))
        : style;
  }

  /// `forceStrutHeight` 让每条视觉行的高度只由 strut 决定，与这一行里有没有中文、
  /// emoji 无关 —— 否则一行中文注释就会把它后面所有行号整体推下去。
  static StrutStyle _editorStrutStyle(TextStyle style) =>
      StrutStyle.fromTextStyle(style, forceStrutHeight: true);

  /// 取（必要时重建）编辑器文本几何。
  ///
  /// 只在 (文本, 样式, strut, 字体缩放, 可用宽度) 之一变化时重排，别每帧 layout。
  ScriptEditorTextMetrics _ensureEditorMetrics({
    required String text,
    required TextStyle style,
    required StrutStyle strutStyle,
    required TextScaler textScaler,
    required double maxWidth,
  }) {
    final cached = _editorMetrics;
    if (cached != null &&
        cached.matchesInput(
          text: text,
          style: style,
          strutStyle: strutStyle,
          textScaler: textScaler,
          maxWidth: maxWidth,
        )) {
      return cached;
    }
    cached?.dispose();
    final created = ScriptEditorTextMetrics.compute(
      text: text,
      style: style,
      strutStyle: strutStyle,
      textScaler: textScaler,
      maxWidth: maxWidth,
    );
    _editorMetrics = created;
    return created;
  }

  /// 把命中滚进视口。
  ///
  /// 行高不再硬编码：改造前写死 `13 * 1.5` 又只数 `\n`，软换行、contentPadding、
  /// 系统字体缩放一个都没算，长行脚本上系统性跳偏。现在直接问行号栏那份**实测**
  /// 几何要真实 y —— 同一份 TextPainter 同时供行号和滚动定位使用。
  void _scrollToMatch(int offset) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_contentScrollController.hasClients) {
        return;
      }
      // 在回调里现取：这一帧重建可能已经换过一份几何，拿旧的会滚错位置。
      final top = _editorMetrics?.topForOffset(offset);
      if (top == null) {
        return;
      }
      final position = _contentScrollController.position;
      // 让命中落在视口上三分之一处，命中的前后都还留得下上下文。
      final target = (top - position.viewportDimension / 3).clamp(
        0.0,
        position.maxScrollExtent,
      );
      _contentScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  /// 把 provider 里的内容同步进编辑器。
  ///
  /// ⚠️ 绝不能写成 `_contentController.text = content`：Flutter 的 `set text`
  /// 会把 selection 强制打回 `TextSelection.collapsed(offset: -1)`，而这一句改造前
  /// 是放在 **build() 里每帧执行**的（SDK 文档明写「不应在 build / layout / paint
  /// 阶段设置」）。于是搜索刚设好的选区同帧就被抹掉，下次点「下一个」时
  /// `selection.isValid` 为 false、查找起点回落成 0 —— 这就是 issue #6 (c) 的根因，
  /// 同时也让 (b) 那个琥珀色高亮一帧都留不住。
  ///
  /// 现在只在内容**真的变了**时同步一次；命中偏移的重算交给
  /// [_handleContentChanged] —— 这一句赋值会同步触发它。
  void _applyContentFromState(String content) {
    if (_contentController.text == content) {
      return;
    }
    _contentController.value = TextEditingValue(
      text: content,
      selection: const TextSelection.collapsed(offset: -1),
      composing: TextRange.empty,
    );
  }

  /// 编辑器内容变了就重算命中偏移。
  ///
  /// 为什么必须挂这个 listener：命中偏移原本只在查找条的 `onChanged` 和
  /// [_applyContentFromState] 两处重算，**打字不算**。于是「搜 token 得到 3 处高亮 →
  /// 进编辑模式 → 在文件开头插入 5 个字符」之后，三处高亮整体左移 5 个字符染在毫不
  /// 相干的文本上，「下一个」按旧偏移滚到错误位置，计数还显示 3。
  ///
  /// 取舍：大文件下每敲一个字符都要全文重扫一遍。`indexOf` 扫几 MB 也就几毫秒，
  /// 而真正贵的高亮切片已经被 `kScriptSearchMatchLimit` 封顶了 ——
  /// 相比「高亮染错地方」这个正确性问题，这点开销必须付。
  void _handleContentChanged() {
    final text = _contentController.text;
    if (text == _lastContentText) {
      return;
    }
    _lastContentText = text;
    // 查找条关掉之后 _matchQuery 会被清空（输入框里的词还留着，方便重开），
    // 那时不该再把高亮算回来。
    if (_matchQuery.isEmpty) {
      return;
    }
    // 用户可能正在打字，别把视口拽走；也别把「第几个命中」打回第 1 个，
    // 否则连续编辑时计数会一直从 7/20 跳回 1/20。
    _runSearch(_matchQuery, scrollToMatch: false, keepPosition: true);
  }

  /// 重算命中列表并把高亮推给 controller。
  ///
  /// [scrollToMatch] 为 false 时只更新高亮，不动滚动位置。
  /// [keepPosition] 为 true 时尽量停在离原来那个命中最近的位置（用于编辑期间的重扫）。
  void _runSearch(
    String query, {
    bool scrollToMatch = true,
    bool keepPosition = false,
  }) {
    final previousOffset =
        keepPosition &&
            _currentMatchIndex >= 0 &&
            _currentMatchIndex < _matchOffsets.length
        ? _matchOffsets[_currentMatchIndex]
        : null;
    // 多要一个：拿到 limit+1 个才说明真的被截断了。只按 `== limit` 判断的话，
    // 恰好 500 个命中的文件会被误标成「500+」。
    final probed = query.isEmpty
        ? const <int>[]
        : findMatchOffsets(
            _contentController.text,
            query,
            limit: kScriptSearchMatchLimit + 1,
          );
    final truncated = probed.length > kScriptSearchMatchLimit;
    final offsets = truncated
        ? probed.sublist(0, kScriptSearchMatchLimit)
        : probed;
    final current = offsets.isEmpty
        ? -1
        : (previousOffset == null
              ? 0
              : nearestMatchIndex(offsets, previousOffset));
    setState(() {
      _matchQuery = query;
      _matchOffsets = offsets;
      _matchTruncated = truncated;
      _currentMatchIndex = current;
      _contentController.updateMatches(
        offsets: offsets,
        current: current,
        length: query.length,
      );
    });
    if (scrollToMatch && current >= 0) {
      _scrollToMatch(offsets[current]);
    }
  }

  /// 「上一个 / 下一个」：在命中列表里前后移动并回绕。
  ///
  /// 这里**只动序号**，不碰 selection —— 所以即便 selection 被输入法或内容刷新
  /// 改写，下一次点击照样往下走。
  void _stepMatch({required bool forward}) {
    final total = _matchOffsets.length;
    if (total == 0) {
      return;
    }
    final next = nextMatchIndex(_currentMatchIndex, total, forward: forward);
    setState(() {
      _currentMatchIndex = next;
      _contentController.updateMatches(
        offsets: _matchOffsets,
        current: next,
        length: _matchQuery.length,
      );
    });
    _scrollToMatch(_matchOffsets[next]);
  }

  void _toggleFindBar() {
    final visible = !_findBarVisible;
    setState(() => _findBarVisible = visible);
    if (visible) {
      // 关掉又打开时保留上次的查询词，省得用户重敲。
      if (_findController.text.isNotEmpty) {
        _runSearch(_findController.text);
      }
      return;
    }
    // ⚠️ 这里刻意**不** `_findController.clear()`：清掉之后上面那个 isNotEmpty 分支
    // 就永远不成立，注释里承诺的「保留查询词」是句空话 —— 用户要的正是「像编辑器那样」
    // 关了再开查询词还在。只把高亮状态撤干净：查找条都收起来了，正文里不该还留着一片
    // 琥珀色；[_handleContentChanged] 也靠 `_matchQuery` 为空来判断「现在没在搜」。
    setState(() {
      _matchQuery = '';
      _matchOffsets = const [];
      _matchTruncated = false;
      _currentMatchIndex = -1;
      _contentController.updateMatches(
        offsets: const [],
        current: -1,
        length: 0,
      );
    });
  }

  Future<void> _reloadContent() async {
    setState(() => _editing = false);
    await ref.read(scriptProvider.notifier).loadContent(widget.path);
  }

  Future<void> _handleAction(_ScriptViewerAction action) async {
    switch (action) {
      case _ScriptViewerAction.format:
        await _format();
        return;
      case _ScriptViewerAction.versions:
        await _showVersions();
        return;
      case _ScriptViewerAction.addToTask:
        if (!mounted) {
          return;
        }
        await context.push('/tasks/new', extra: _taskPrefill());
        return;
      case _ScriptViewerAction.debug:
        await _debugRun();
        return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(scriptProvider);
    // 内容同步从 build 主体里搬到这里：只在 provider 真的换了内容时走一次，
    // 不再每帧重置 selection（原因见 _applyContentFromState 的注释）。
    // 编辑模式下刻意不同步 —— 那会覆盖用户正在敲的东西；格式化结果由 _format 自己落回。
    ref.listen<ScriptState>(scriptProvider, (previous, next) {
      if (_editing || next.isBinary) {
        return;
      }
      _applyContentFromState(next.content);
    });

    // ⚠️ scriptProvider 是全局非 autoDispose 的，`contentError` 又走「不传即保持」
    // 哨兵，而 `loadContent` 只在 initState 的 microtask 里调 —— 微任务排在本帧 build
    // **之后**。于是「脚本 A 加载失败 → 返回列表 → 点开脚本 B」时，B 的第一帧读到的是
    // A 遗留的 contentError 且 loadingContent 还是 false，整页先闪一下红色错误页、
    // AppBar 上的编辑/保存/查找/调试全被藏起来，下一帧才切回 loading。
    // 所以：只要 state 讲的还是别的文件，就一律按 loading 处理。
    final stateMatchesPath = state.selectedPath == widget.path;
    final loadingContent = state.loadingContent || !stateMatchesPath;
    final contentError = stateMatchesPath ? state.contentError : null;
    // isBinary 同样要跟着 stateMatchesPath 走，否则「看完二进制文件再开文本文件」
    // 会在整个请求时长里把 AppBar 上的按钮全藏掉，回来时又凭空出现。
    final isBinary = stateMatchesPath && state.isBinary;
    // ⚠️ `loadingContent` 必须算进来。内容还在路上时，编辑器缓冲区里装的要么是空串、
    // 要么是**上一个脚本**的正文（loadContent 第一句 copyWith 就会触发上面的 ref.listen
    // 把旧内容灌进来）。此时若还给出「编辑 / 保存 / 调试运行」入口，用户在转圈期间
    // 点两下就能把目标脚本整个覆盖成另一个脚本的内容——从日志详情跳过来时尤其容易踩，
    // 因为那条路径不预加载，窗口就是一次 GET 的时长。
    final editable = !loadingContent && !isBinary && contentError == null;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final editorBackground =
        _editorBackgroundColor ??
        (isDark ? const Color(0xFF1E1E1E) : Colors.white);
    final onDarkEditor = _useLightForeground(editorBackground);
    final editorForeground = onDarkEditor
        ? const Color(0xFFD4D4D4)
        : AppColors.slate900;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.path.split('/').last),
        actions: [
          if (editable)
            IconButton(
              onPressed: _toggleFindBar,
              icon: Icon(_findBarVisible ? Icons.search_off : Icons.search),
              tooltip: _findBarVisible ? '关闭查找' : '查找代码',
            ),
          if (editable)
            PopupMenuButton<_ScriptViewerAction>(
              onSelected: _handleAction,
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: _ScriptViewerAction.addToTask,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.playlist_add_outlined),
                    title: Text('加入任务'),
                  ),
                ),
                PopupMenuItem(
                  value: _ScriptViewerAction.format,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.auto_fix_high_outlined),
                    title: Text('格式化'),
                  ),
                ),
                PopupMenuItem(
                  value: _ScriptViewerAction.versions,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.history_outlined),
                    title: Text('版本历史'),
                  ),
                ),
                PopupMenuItem(
                  value: _ScriptViewerAction.debug,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.play_circle_outline),
                    title: Text('调试运行'),
                  ),
                ),
              ],
            ),
          if (editable)
            IconButton(
              onPressed: _debugRunning ? null : _debugRun,
              icon: _debugRunning
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow_rounded),
              tooltip: '调试运行',
            ),
          if (editable)
            IconButton(
              onPressed: () {
                final next = !_editing;
                setState(() => _editing = next);
                if (!next) {
                  // 退回查看模式：与改造前一致，未保存的修改丢弃、回到服务端内容。
                  // 改造前这件事是靠 build 里那句每帧赋值顺带完成的，现在得显式做。
                  _applyContentFromState(ref.read(scriptProvider).content);
                }
              },
              icon: Icon(
                _editing ? Icons.visibility_outlined : Icons.edit_outlined,
              ),
            ),
          if (_editing && editable)
            IconButton(
              onPressed: state.saving ? null : _save,
              icon: state.saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
            ),
        ],
      ),
      body: loadingContent
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            )
          : contentError != null
          ? SingleChildScrollView(
              child: AppErrorView(
                title: '脚本内容加载失败',
                message: contentError,
                onRetry: _reloadContent,
              ),
            )
          : isBinary
          ? const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 28),
                child: Text(
                  '当前文件为二进制内容，App 暂不支持预览和编辑。',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Text(
                    widget.path,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (_findBarVisible)
                  ScriptFindBar(
                    controller: _findController,
                    matchCount: _matchOffsets.length,
                    currentIndex: _currentMatchIndex,
                    truncated: _matchTruncated,
                    onChanged: _runSearch,
                    onPrevious: () => _stepMatch(forward: false),
                    onNext: () => _stepMatch(forward: true),
                    onClose: _toggleFindBar,
                  ),
                Expanded(
                  child: AppCard(
                    margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    // 编辑器内边距由 InputDecoration.contentPadding 提供，
                    // 卡片再补一层会让光标与描边之间多出 16 的空白。
                    padding: EdgeInsets.zero,
                    radius: AppRadius.md,
                    // 编辑器底色跟随用户设置的日志/编辑器主题，与页面明暗无关。
                    color: editorBackground,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final textScaler = MediaQuery.textScalerOf(context);
                        final textStyle = _editorTextStyle(
                          context,
                          editorForeground,
                        );
                        final strutStyle = _editorStrutStyle(textStyle);
                        // 监听 controller 而不是整页 setState：编辑模式下每敲一个
                        // 字符都要重排行号，只让编辑器这一块重建，别牵动整页。
                        return ValueListenableBuilder<TextEditingValue>(
                          valueListenable: _contentController,
                          builder: (context, value, _) {
                            final text = value.text;
                            final gutterWidth = scriptGutterWidth(
                              lineCount: lineNumberForOffset(text, text.length),
                              style: textStyle,
                              textScaler: textScaler,
                            );
                            // 行号栏、contentPadding、光标余量一起从卡片宽里扣掉，
                            // 剩下的才是 TextField 真正用来断行的宽度。
                            final available =
                                (constraints.maxWidth -
                                        gutterWidth -
                                        _editorContentPadding.horizontal -
                                        _editorCaretMargin)
                                    .clamp(0.0, double.infinity);
                            final metrics = _ensureEditorMetrics(
                              text: text,
                              style: textStyle,
                              strutStyle: strutStyle,
                              textScaler: textScaler,
                              maxWidth: available,
                            );
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                ScriptLineNumberGutter(
                                  width: gutterWidth,
                                  metrics: metrics,
                                  scrollController: _contentScrollController,
                                  textStyle: textStyle,
                                  strutStyle: strutStyle,
                                  textScaler: textScaler,
                                  // 跟编辑器底色的明暗走，而不是跟 App 主题走 ——
                                  // 编辑器底色是用户在面板里自定义的。
                                  color: onDarkEditor
                                      ? AppColors.editorGutterOnDark
                                      : AppColors.editorGutterOnLight,
                                  verticalPadding: _editorContentPadding.top,
                                ),
                                Expanded(
                                  child: TextSelectionTheme(
                                    data: TextSelectionThemeData(
                                      selectionColor: AppColors.primary
                                          .withAlpha(60),
                                    ),
                                    child: TextField(
                                      controller: _contentController,
                                      focusNode: _contentFocusNode,
                                      scrollController:
                                          _contentScrollController,
                                      readOnly: !_editing,
                                      expands: true,
                                      maxLines: null,
                                      style: textStyle,
                                      // 与行号栏同一份 strut：行高只由它决定，
                                      // 中文注释才不会把后面的行号整体推下去。
                                      strutStyle: strutStyle,
                                      cursorColor: editorForeground,
                                      selectionHeightStyle: BoxHeightStyle.max,
                                      decoration: const InputDecoration(
                                        // ⚠️ 只写 border 挡不住：applyDefaults 会把主题的
                                        // enabledBorder / focusedBorder 填进来，而
                                        // _InputDecoratorState 取的是它们**优先**，
                                        // border 只在两者都为 null 时才回落。本仓主题恰好两个都给了
                                        // OutlineInputBorder，所以必须三个一起关掉 —— 否则行号栏
                                        // 拆到 TextField 外面之后，那圈描边只框住右半边代码区，
                                        // 聚焦时还会冒出一个只圈代码区的主色圆角框。
                                        border: InputBorder.none,
                                        enabledBorder: InputBorder.none,
                                        focusedBorder: InputBorder.none,
                                        contentPadding: _editorContentPadding,
                                        // 不写 filled 会继承主题 inputDecorationTheme
                                        // 的 filled:true + fillColor:cardColor，而
                                        // InputBorder.none 的 outer path 就是整个矩形，
                                        // 这层 fill 会把 AppCard 的 editorBackground 整块盖掉。
                                        // 改造前 TextField 铺满整张卡片所以看不出来（顺带说明：
                                        // 面板的 editor_background_color 设置项一直是无效的）；
                                        // 行号栏挪到 TextField 外面之后，露出来的就是
                                        // 「左边行号条 editorBackground + 右边代码区 cardColor」
                                        // 的一条竖直色缝。写死 false，那个设置项也第一次真正生效。
                                        filled: false,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _ScriptVersionSheet extends ConsumerStatefulWidget {
  final String path;

  const _ScriptVersionSheet({required this.path});

  @override
  ConsumerState<_ScriptVersionSheet> createState() =>
      _ScriptVersionSheetState();
}

class _ScriptVersionSheetState extends ConsumerState<_ScriptVersionSheet> {
  bool _loading = true;
  List<ScriptVersionRecord> _versions = const [];

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadVersions);
  }

  Future<void> _loadVersions() async {
    setState(() => _loading = true);
    try {
      final versions = await ref
          .read(scriptProvider.notifier)
          .listVersions(widget.path);
      if (!mounted) {
        return;
      }
      setState(() {
        _versions = versions;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _loading = false);
    }
  }

  Future<void> _rollback(ScriptVersionRecord version) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('回滚脚本'),
        content: Text('确定要回滚到 v${version.version} 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.amber500),
            child: const Text('回滚'),
          ),
        ],
      ),
    );
    if (confirm != true) {
      return;
    }
    try {
      await ref
          .read(scriptProvider.notifier)
          .rollbackVersion(version.id, widget.path);
      if (!mounted) {
        return;
      }
      // 回传 true 告诉打开它的页面「服务端内容真的换了」——编辑页要靠它决定
      // 把编辑器落回服务端内容。只是翻了翻版本就关掉时不能回传，
      // 否则会把用户未保存的修改一起丢掉。
      Navigator.pop(context, true);
      AppSnack.success(context, '已回滚到 v${version.version}');
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppSnack.error(context, _extractRequestError(error, '回滚失败'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.72,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '版本历史',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.path,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(
                          color: AppColors.primary,
                        ),
                      )
                    : _versions.isEmpty
                    ? const Center(
                        child: Text(
                          '暂无版本历史',
                          style: TextStyle(color: AppColors.slate400),
                        ),
                      )
                    : ListView.separated(
                        itemCount: _versions.length,
                        separatorBuilder: (_, index) =>
                            const SizedBox(height: 10),
                        itemBuilder: (_, index) {
                          final version = _versions[index];
                          final message = version.message.trim().isEmpty
                              ? 'v${version.version}'
                              : version.message;
                          return AppCard(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: AppColors.primary.withAlpha(18),
                                        borderRadius: BorderRadius.circular(
                                          AppRadius.pill,
                                        ),
                                      ),
                                      child: Text(
                                        'v${version.version}',
                                        style: TextStyle(
                                          // 底色是 primary 的 alpha=18 淡底。
                                          color: context.surfaces.tintFg(
                                            AppColors.primary,
                                          ),
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        message,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  version.createdAt != null
                                      ? formatTimeCn(version.createdAt)
                                      : '未知时间',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '内容长度：${version.contentLength} 字符',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: OutlinedButton.icon(
                                    onPressed: () => _rollback(version),
                                    icon: const Icon(Icons.restore, size: 18),
                                    label: const Text('回滚到此版本'),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

List<String> _scriptFolders(List<ScriptFile> tree) {
  final folders = <String>{};

  void visit(ScriptFile file) {
    if (file.isDirectory && file.path.isNotEmpty) {
      folders.add(file.path);
      for (final child in file.children) {
        visit(child);
      }
    }
  }

  for (final file in tree) {
    visit(file);
  }

  final values = folders.toList()..sort();
  return values;
}

String _defaultScriptDirectory(String? selectedPath) {
  final path = (selectedPath ?? '').trim();
  if (path.isEmpty) {
    return '';
  }
  final index = path.lastIndexOf('/');
  if (index <= 0) {
    return '';
  }
  return path.substring(0, index);
}

String _joinScriptPath(String dir, String name) {
  final folder = dir.trim();
  final leaf = name.trim();
  if (folder.isEmpty) {
    return leaf;
  }
  return '$folder/$leaf';
}

String? _detectFormatterLanguage(String path) {
  final ext = path.split('.').last.toLowerCase();
  switch (ext) {
    case 'py':
      return 'python';
    case 'sh':
    case 'bash':
      return 'shell';
    case 'go':
      return 'go';
    case 'json':
      return 'json';
    default:
      return null;
  }
}

String _extractRequestError(dynamic error, String fallback) =>
    extractScriptSaveErrorMessage(error, fallback);

class _ScriptDebugRunSheet extends StatefulWidget {
  final String path;
  final String runId;

  const _ScriptDebugRunSheet({required this.path, required this.runId});

  @override
  State<_ScriptDebugRunSheet> createState() => _ScriptDebugRunSheetState();
}

class _ScriptDebugRunSheetState extends State<_ScriptDebugRunSheet> {
  final ScrollController _scrollController = ScrollController();
  final List<String> _logs = [];
  bool _loading = true;
  bool _done = false;
  bool _autoScroll = true;
  String _statusText = '启动中...';
  Timer? _pollTimer;
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
    _loadLogs();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _loadLogs());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadLogs() async {
    try {
      final resp = await DioClient.instance.dio.get(
        ApiEndpoints.scriptsRunLogs(widget.runId),
      );
      final data = extractData(resp.data);
      if (data is! Map) {
        return;
      }

      final rawLogs = data['logs'];
      final nextLogs = rawLogs is List
          ? rawLogs
                .map((item) => item.toString())
                .where((item) => item.trim().isNotEmpty)
                .toList()
          : const <String>[];
      final done = data['done'] == true;
      final exitCode = data['exit_code'];
      final status = data['status']?.toString() ?? '';

      if (!mounted) {
        return;
      }

      setState(() {
        _logs
          ..clear()
          ..addAll(nextLogs);
        _done = done;
        _loading = false;
        _statusText = _buildStatusText(status, exitCode, done);
      });

      if (_autoScroll) {
        _scrollToBottom();
      }

      if (done) {
        _pollTimer?.cancel();
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _statusText = '日志读取失败';
      });
    }
  }

  String _buildStatusText(String status, dynamic exitCode, bool done) {
    if (!done) {
      return '运行中...';
    }
    if (status == 'success') {
      return '执行成功';
    }
    if (status == 'stopped') {
      return '已停止';
    }
    if (exitCode is num && exitCode == 0) {
      return '执行成功';
    }
    return '执行失败';
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _stopRun() async {
    try {
      await DioClient.instance.dio.put(
        ApiEndpoints.scriptsRunStop(widget.runId),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _done = true;
        _statusText = '已停止';
      });
      _pollTimer?.cancel();
      await _loadLogs();
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppSnack.error(context, extractScriptSaveErrorMessage(error, '停止调试失败'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final logTheme = resolveLogSurfaceTheme(
      _logBackgroundColor,
      themeBrightness: Theme.of(context).brightness,
    );

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.8,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '脚本调试',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                widget.path,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _statusText,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _logs.isEmpty
                        ? null
                        : () async {
                            await Clipboard.setData(
                              ClipboardData(text: _logs.join('\n')),
                            );
                            if (!mounted) return;
                            AppSnack.success(context, '已复制调试日志');
                          },
                    icon: const Icon(Icons.copy_all_outlined),
                  ),
                  IconButton(
                    onPressed: () {
                      setState(() => _autoScroll = !_autoScroll);
                      if (_autoScroll) {
                        _scrollToBottom();
                      }
                    },
                    icon: Icon(
                      _autoScroll
                          ? Icons.vertical_align_bottom
                          : Icons.pause_circle_outline,
                    ),
                  ),
                  if (!_done)
                    IconButton(
                      onPressed: _stopRun,
                      icon: const Icon(Icons.stop_circle_outlined),
                    ),
                ],
              ),
              Expanded(
                child: AppCard(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  // 调试输出面板原本就没有描边，靠日志主题底色与页面区分。
                  bordered: false,
                  color: logTheme.background,
                  child: _loading
                      ? const Center(
                          child: CircularProgressIndicator(
                            color: AppColors.primary,
                          ),
                        )
                      : _logs.isEmpty
                      ? Center(
                          child: Text(
                            '等待调试输出...',
                            style: TextStyle(color: logTheme.mutedForeground),
                          ),
                        )
                      : Scrollbar(
                          controller: _scrollController,
                          child: SingleChildScrollView(
                            controller: _scrollController,
                            child: SelectionArea(
                              child: RichText(
                                text: AnsiTextParser.buildTextSpan(
                                  _logs.join('\n'),
                                  baseStyle: TextStyle(
                                    color: logTheme.foreground,
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                    height: 1.55,
                                  ),
                                  brightness: logTheme.brightness,
                                ),
                              ),
                            ),
                          ),
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
