import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/api_endpoints.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/utils/time_utils.dart';
import '../../../shared/widgets/app_notice.dart';
import '../../../shared/widgets/app_snack.dart';

class BackupPage extends ConsumerStatefulWidget {
  const BackupPage({super.key});

  @override
  ConsumerState<BackupPage> createState() => _BackupPageState();
}

class _BackupFileRecord {
  final String filename;
  final int size;
  final DateTime? createdAt;

  const _BackupFileRecord({
    required this.filename,
    required this.size,
    required this.createdAt,
  });

  factory _BackupFileRecord.fromJson(Map<String, dynamic> json) {
    final filename =
        json['filename']?.toString() ?? json['name']?.toString() ?? '';
    final size = (json['size'] as num?)?.toInt() ?? 0;
    final createdAt = json['created_at'] is String
        ? DateTime.tryParse(json['created_at'].toString())
        : (json['mtime'] is num
              ? DateTime.fromMillisecondsSinceEpoch(
                  (json['mtime'] as num).toInt() * 1000,
                )
              : null);
    return _BackupFileRecord(
      filename: filename,
      size: size,
      createdAt: createdAt,
    );
  }

  bool get encrypted => filename.toLowerCase().endsWith('.enc');
}

class _BackupSelection {
  final bool configs;
  final bool tasks;
  final bool subscriptions;
  final bool envVars;
  final bool logs;
  final bool scripts;
  final bool dependencies;

  const _BackupSelection({
    required this.configs,
    required this.tasks,
    required this.subscriptions,
    required this.envVars,
    required this.logs,
    required this.scripts,
    required this.dependencies,
  });

  const _BackupSelection.defaults()
    : configs = true,
      tasks = true,
      subscriptions = true,
      envVars = true,
      logs = true,
      scripts = true,
      dependencies = true;

  bool get any =>
      configs ||
      tasks ||
      subscriptions ||
      envVars ||
      logs ||
      scripts ||
      dependencies;

  _BackupSelection copyWith({
    bool? configs,
    bool? tasks,
    bool? subscriptions,
    bool? envVars,
    bool? logs,
    bool? scripts,
    bool? dependencies,
  }) {
    return _BackupSelection(
      configs: configs ?? this.configs,
      tasks: tasks ?? this.tasks,
      subscriptions: subscriptions ?? this.subscriptions,
      envVars: envVars ?? this.envVars,
      logs: logs ?? this.logs,
      scripts: scripts ?? this.scripts,
      dependencies: dependencies ?? this.dependencies,
    );
  }

  factory _BackupSelection.fromJson(Map<String, dynamic> json) {
    return _BackupSelection(
      configs: json['configs'] != false,
      tasks: json['tasks'] != false,
      subscriptions: json['subscriptions'] != false,
      envVars: json['env_vars'] != false,
      logs: json['logs'] != false,
      scripts: json['scripts'] != false,
      dependencies: json['dependencies'] != false,
    );
  }

  Map<String, dynamic> toJson() => {
    'configs': configs,
    'tasks': tasks,
    'subscriptions': subscriptions,
    'env_vars': envVars,
    'logs': logs,
    'scripts': scripts,
    'dependencies': dependencies,
  };

  List<String> labels() {
    final result = <String>[];
    if (configs) {
      result.add('配置项');
    }
    if (tasks) {
      result.add('定时任务');
    }
    if (subscriptions) {
      result.add('订阅管理');
    }
    if (envVars) {
      result.add('环境变量');
    }
    if (logs) {
      result.add('日志文件');
    }
    if (scripts) {
      result.add('脚本文件');
    }
    if (dependencies) {
      result.add('依赖记录');
    }
    return result;
  }
}

class _RestoreProgressState {
  final bool active;
  final String status;
  final String filename;
  final String source;
  final _BackupSelection? selection;
  final String stage;
  final String message;
  final int percent;
  final String error;
  final DateTime? startedAt;
  final DateTime? updatedAt;

  const _RestoreProgressState({
    this.active = false,
    this.status = 'idle',
    this.filename = '',
    this.source = '',
    this.selection,
    this.stage = '',
    this.message = '',
    this.percent = 0,
    this.error = '',
    this.startedAt,
    this.updatedAt,
  });

  bool get visible => active || status == 'completed' || status == 'failed';

  bool get completed => status == 'completed';

  bool get failed => status == 'failed';

  factory _RestoreProgressState.fromJson(Map<String, dynamic> json) {
    return _RestoreProgressState(
      active: json['active'] == true,
      status: json['status']?.toString() ?? 'idle',
      filename: json['filename']?.toString() ?? '',
      source: json['source']?.toString() ?? '',
      selection: json['selection'] is Map
          ? _BackupSelection.fromJson(
              Map<String, dynamic>.from(json['selection'] as Map),
            )
          : null,
      stage: json['stage']?.toString() ?? '',
      message: json['message']?.toString() ?? '',
      percent: (json['percent'] as num?)?.toInt() ?? 0,
      error: json['error']?.toString() ?? '',
      startedAt: json['started_at'] is String
          ? DateTime.tryParse(json['started_at'].toString())
          : null,
      updatedAt: json['updated_at'] is String
          ? DateTime.tryParse(json['updated_at'].toString())
          : null,
    );
  }
}

class _BackupSelectionOption {
  final String key;
  final String title;
  final String description;

  const _BackupSelectionOption(this.key, this.title, this.description);
}

const _backupSelectionOptions = [
  _BackupSelectionOption('configs', '配置项', '系统设置、Open API、通知渠道与安全配置'),
  _BackupSelectionOption('tasks', '定时任务', '任务定义、标签、执行参数与依赖关系'),
  _BackupSelectionOption('subscriptions', '订阅管理', '订阅配置与 SSH 密钥'),
  _BackupSelectionOption('env_vars', '环境变量', '面板环境变量与分组信息'),
  _BackupSelectionOption('logs', '日志文件', '任务日志记录、日志目录与面板运行日志'),
  _BackupSelectionOption('scripts', '脚本文件', '脚本目录内的源码、资源和可执行文件'),
  _BackupSelectionOption('dependencies', '依赖记录', '记录已安装依赖，恢复时按记录重新安装'),
];

class _CreateBackupRequest {
  final String password;
  final _BackupSelection selection;

  const _CreateBackupRequest({required this.password, required this.selection});
}

class _BackupPageState extends ConsumerState<BackupPage> {
  List<_BackupFileRecord> _backups = const [];
  bool _loading = true;
  bool _creating = false;
  bool _uploading = false;
  final Set<String> _downloading = <String>{};
  final Set<String> _deleting = <String>{};
  bool _restoreRequestRunning = false;
  bool _hideRestoreProgress = false;
  _RestoreProgressState _restoreProgress = const _RestoreProgressState();
  Timer? _progressTimer;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      await _loadBackups();
      await _loadRestoreProgress();
    });
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadBackups() async {
    if (mounted) {
      setState(() => _loading = true);
    }
    try {
      final resp = await DioClient.instance.dio.get(ApiEndpoints.backups);
      final data = extractData(resp.data);
      final backups = data is List
          ? data
                .whereType<Map>()
                .map(
                  (item) => _BackupFileRecord.fromJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .toList()
          : <_BackupFileRecord>[];
      backups.sort((a, b) {
        final aTime = a.createdAt?.millisecondsSinceEpoch ?? 0;
        final bTime = b.createdAt?.millisecondsSinceEpoch ?? 0;
        return bTime.compareTo(aTime);
      });
      if (!mounted) {
        return;
      }
      setState(() {
        _backups = backups;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _loading = false);
    }
  }

  void _showMessage(String message) => AppSnack.show(context, message);

  void _showSuccess(String message) => AppSnack.success(context, message);

  void _showError(String message) => AppSnack.error(context, message);

  void _showWarning(String message) => AppSnack.warn(context, message);

  void _ensureProgressPolling() {
    _progressTimer ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => _loadRestoreProgress(),
    );
  }

  void _stopProgressPolling() {
    _progressTimer?.cancel();
    _progressTimer = null;
  }

  Future<void> _loadRestoreProgress() async {
    try {
      final resp = await DioClient.instance.dio.get(
        ApiEndpoints.restoreProgress,
      );
      final data = extractData(resp.data);
      final progress = data is Map
          ? _RestoreProgressState.fromJson(Map<String, dynamic>.from(data))
          : const _RestoreProgressState();
      if (!mounted) {
        return;
      }
      setState(() {
        _restoreProgress = progress;
        if (progress.active) {
          _hideRestoreProgress = false;
        }
      });
      if (progress.active) {
        _ensureProgressPolling();
      } else {
        _stopProgressPolling();
      }
    } catch (_) {
      if (_restoreRequestRunning) {
        _ensureProgressPolling();
      } else {
        _stopProgressPolling();
      }
    }
  }

  String _formatSize(int size) {
    if (size < 1024) {
      return '$size B';
    }
    if (size < 1024 * 1024) {
      return '${(size / 1024).toStringAsFixed(1)} KB';
    }
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _createBackup() async {
    final request = await _showCreateBackupDialog();
    if (request == null) {
      return;
    }
    if (!request.selection.any) {
      _showWarning('请至少选择一个备份项');
      return;
    }

    setState(() => _creating = true);
    try {
      await DioClient.instance.dio.post(
        ApiEndpoints.backup,
        data: {
          'password': request.password,
          'selection': request.selection.toJson(),
        },
      );
      await _loadBackups();
      _showSuccess('备份创建成功');
    } catch (error) {
      _showError(_extractRequestError(error, '备份创建失败'));
    } finally {
      if (mounted) {
        setState(() => _creating = false);
      }
    }
  }

  Future<_CreateBackupRequest?> _showCreateBackupDialog() async {
    final messenger = ScaffoldMessenger.of(context);
    final passwordController = TextEditingController();
    var selection = const _BackupSelection.defaults();

    return showDialog<_CreateBackupRequest>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('创建备份'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('选择需要备份的内容，默认全选。', style: TextStyle(fontSize: 13)),
                  const SizedBox(height: 12),
                  ..._backupSelectionOptions.map(
                    (option) => CheckboxListTile(
                      value: _selectionValue(selection, option.key),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(option.title),
                      subtitle: Text(option.description),
                      onChanged: (value) {
                        setDialogState(() {
                          selection = _setSelectionValue(
                            selection,
                            option.key,
                            value ?? false,
                          );
                        });
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: passwordController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '备份密码（可选）',
                      hintText: '留空则导出为 .tgz，设置密码则导出为 .enc',
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (!selection.any) {
                  messenger.showSnackBar(
                    const SnackBar(content: Text('请至少选择一个备份项')),
                  );
                  return;
                }
                Navigator.pop(
                  dialogContext,
                  _CreateBackupRequest(
                    password: passwordController.text.trim(),
                    selection: selection,
                  ),
                );
              },
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _refresh() async {
    await _loadBackups();
    await _loadRestoreProgress();
  }

  bool get _busyRestoring => _restoreRequestRunning || _restoreProgress.active;

  Future<void> _uploadBackup() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      withData: false,
      withReadStream: true,
      type: FileType.custom,
      allowedExtensions: const ['json', 'enc', 'tgz', 'gz'],
      dialogTitle: '选择备份文件',
    );
    if (result == null || result.files.isEmpty) {
      return;
    }

    final file = result.files.first;
    final multipart = await _toMultipartFile(file);
    if (multipart == null) {
      _showError('无法读取所选备份文件');
      return;
    }

    setState(() => _uploading = true);
    try {
      final formData = FormData();
      formData.files.add(MapEntry('file', multipart));
      await DioClient.instance.dio.post(
        ApiEndpoints.backupUpload,
        data: formData,
        options: Options(contentType: 'multipart/form-data'),
      );
      await _loadBackups();
      _showSuccess('备份导入成功');
    } catch (error) {
      _showError(_extractRequestError(error, '导入备份失败'));
    } finally {
      if (mounted) {
        setState(() => _uploading = false);
      }
    }
  }

  Future<void> _downloadBackup(String filename) async {
    if (_downloading.contains(filename)) {
      return;
    }

    setState(() => _downloading.add(filename));
    try {
      final resp = await DioClient.instance.dio.get(
        ApiEndpoints.backupDownload(filename),
        options: Options(responseType: ResponseType.bytes),
      );
      final bytes = _extractBytes(resp.data);
      if (bytes == null || bytes.isEmpty) {
        throw StateError('下载内容为空');
      }

      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: '保存备份文件',
        fileName: filename,
        type: FileType.any,
        bytes: bytes,
      );
      if (savedPath == null) {
        // 用户自己在系统保存框里按了取消，不是失败，保持中性。
        _showMessage('已取消保存');
        return;
      }

      _showSuccess('备份已保存');
    } on UnsupportedError {
      // 平台能力缺失而不是这次操作出错，用警告。
      _showWarning('当前平台暂不支持直接保存文件');
    } catch (error) {
      _showError(_extractRequestError(error, '下载备份失败'));
    } finally {
      if (mounted) {
        setState(() => _downloading.remove(filename));
      }
    }
  }

  Future<void> _restoreBackup(String filename) async {
    final password = await _showRestoreDialog(filename);
    if (password == null) {
      return;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _restoreRequestRunning = true;
      _hideRestoreProgress = false;
      _restoreProgress = _RestoreProgressState(
        active: true,
        status: 'running',
        filename: filename,
        percent: 3,
        stage: 'preparing',
        message: '正在准备恢复环境...',
      );
    });
    _ensureProgressPolling();

    try {
      await DioClient.instance.dio.post(
        ApiEndpoints.restore,
        data: {'filename': filename, 'password': password},
        options: Options(
          sendTimeout: Duration.zero,
          receiveTimeout: Duration.zero,
        ),
      );
      await _loadRestoreProgress();
      await _loadBackups();
      _showSuccess(
        _restoreProgress.completed ? '恢复完成，请等待面板状态稳定' : '恢复请求已提交，请关注进度卡片',
      );
    } catch (error) {
      await _loadRestoreProgress();
      if (_restoreProgress.visible || _restoreProgress.active) {
        // 请求虽然抛了异常，但服务端确实已经在跑恢复了。既不能报红吓人，
        // 也不能报绿说成功 —— 保持中性，把结论交给进度卡片。
        _showMessage('恢复请求已提交，请查看恢复进度');
      } else {
        _showError(_extractRequestError(error, '恢复备份失败'));
      }
    } finally {
      if (mounted) {
        setState(() => _restoreRequestRunning = false);
      }
      await _loadRestoreProgress();
    }
  }

  Future<String?> _showRestoreDialog(String filename) async {
    final messenger = ScaffoldMessenger.of(context);
    final passwordController = TextEditingController();
    final needsPassword = filename.toLowerCase().endsWith('.enc');

    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('恢复备份'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                filename,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                needsPassword
                    ? '这是一个加密备份，请输入备份密码后继续恢复。'
                    : '恢复将覆盖当前数据，请确认已经完成必要备份。',
                style: const TextStyle(fontSize: 13),
              ),
              if (needsPassword) ...[
                const SizedBox(height: 16),
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '备份密码',
                    hintText: '请输入备份密码',
                  ),
                ),
              ],
              const SizedBox(height: 14),
              const AppNotice(
                color: AppColors.warning,
                icon: Icons.warning_amber_rounded,
                text: '恢复期间不要重复提交恢复请求，也不要立刻切换账号或清理缓存。',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (needsPassword && passwordController.text.trim().isEmpty) {
                messenger.showSnackBar(
                  const SnackBar(content: Text('请输入备份密码')),
                );
                return;
              }
              Navigator.pop(dialogContext, passwordController.text.trim());
            },
            style: FilledButton.styleFrom(backgroundColor: AppColors.red500),
            child: const Text('确认恢复'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteBackup(String filename) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除备份'),
        content: Text('确定要删除备份「$filename」吗？删除后将无法恢复。'),
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
    if (confirm != true || _deleting.contains(filename)) {
      return;
    }

    setState(() => _deleting.add(filename));
    try {
      await DioClient.instance.dio.delete(
        ApiEndpoints.backup,
        queryParameters: {'filename': filename},
      );
      await _loadBackups();
      _showSuccess('备份已删除');
    } catch (error) {
      _showError(_extractRequestError(error, '删除备份失败'));
    } finally {
      if (mounted) {
        setState(() => _deleting.remove(filename));
      }
    }
  }

  Future<MultipartFile?> _toMultipartFile(PlatformFile file) async {
    if (file.path != null && file.path!.isNotEmpty) {
      return MultipartFile.fromFile(file.path!, filename: file.name);
    }
    if (file.readStream != null) {
      return MultipartFile.fromStream(
        () => file.readStream!,
        file.size,
        filename: file.name,
      );
    }
    if (file.bytes != null) {
      return MultipartFile.fromBytes(file.bytes!, filename: file.name);
    }
    return null;
  }

  Uint8List? _extractBytes(dynamic data) {
    if (data is Uint8List) {
      return data;
    }
    if (data is List<int>) {
      return Uint8List.fromList(data);
    }
    if (data is List) {
      final values = data.whereType<num>().map((item) => item.toInt()).toList();
      return Uint8List.fromList(values);
    }
    return null;
  }

  String _extractRequestError(Object error, String fallback) =>
      extractErrorMessage(error, fallback);

  String _formatDateTime(DateTime? value) {
    if (value == null) {
      return '未知时间';
    }
    return formatTimeCn(value);
  }

  String _restoreSourceLabel(String source) {
    switch (source.trim()) {
      case 'qinglong':
        return '青龙备份';
      case 'daidai-panel':
        return '呆呆面板备份';
      default:
        return source.trim().isEmpty ? '面板备份' : '${source.trim()} 备份';
    }
  }

  String _restoreStageLabel(String stage) {
    switch (stage.trim()) {
      case 'preparing':
        return '准备恢复';
      case 'reading':
        return '读取备份';
      case 'decrypting':
        return '解密备份';
      case 'extracting':
        return '解包校验';
      case 'analyzing':
        return '分析结构';
      case 'restoring-data':
        return '写入数据';
      case 'restoring-files':
        return '恢复文件';
      case 'restoring-mirrors':
        return '恢复镜像';
      case 'finalizing':
        return '收尾整理';
      case 'completed':
        return '恢复完成';
      case 'failed':
        return '恢复失败';
      default:
        return '处理中';
    }
  }

  String _restoreStatusText(_RestoreProgressState progress) {
    if (progress.active) {
      return '恢复中';
    }
    if (progress.completed) {
      return '已完成';
    }
    if (progress.failed) {
      return '恢复失败';
    }
    return '空闲';
  }

  // 恢复失败=红、已完成=绿、恢复中=蓝。改造前「已完成」用 primaryDark、
  // 「恢复中」用 blue600，主色换蓝后两个状态是同一族蓝。
  Color _restoreStatusColor(bool isLight, _RestoreProgressState progress) {
    if (progress.failed) {
      return isLight ? AppColors.dangerDark : AppColors.danger;
    }
    if (progress.completed) {
      return isLight ? AppColors.successDark : AppColors.success;
    }
    return isLight ? AppColors.infoDark : AppColors.info;
  }

  IconData _restoreStatusIcon(_RestoreProgressState progress) {
    if (progress.failed) {
      return Icons.error_outline_rounded;
    }
    if (progress.completed) {
      return Icons.check_circle_outline_rounded;
    }
    return Icons.sync_rounded;
  }

  bool _selectionValue(_BackupSelection selection, String key) {
    switch (key) {
      case 'configs':
        return selection.configs;
      case 'tasks':
        return selection.tasks;
      case 'subscriptions':
        return selection.subscriptions;
      case 'env_vars':
        return selection.envVars;
      case 'logs':
        return selection.logs;
      case 'scripts':
        return selection.scripts;
      case 'dependencies':
        return selection.dependencies;
      default:
        return false;
    }
  }

  _BackupSelection _setSelectionValue(
    _BackupSelection selection,
    String key,
    bool value,
  ) {
    switch (key) {
      case 'configs':
        return selection.copyWith(configs: value);
      case 'tasks':
        return selection.copyWith(tasks: value);
      case 'subscriptions':
        return selection.copyWith(subscriptions: value);
      case 'env_vars':
        return selection.copyWith(envVars: value);
      case 'logs':
        return selection.copyWith(logs: value);
      case 'scripts':
        return selection.copyWith(scripts: value);
      case 'dependencies':
        return selection.copyWith(dependencies: value);
      default:
        return selection;
    }
  }

  bool get _showProgressCard =>
      !_hideRestoreProgress && _restoreProgress.visible;

  Widget _buildActionIcon(bool loading, IconData icon) {
    if (loading) {
      return const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return Icon(icon, size: 18);
  }

  Widget _buildActionCard(bool isLight) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.blue500.withAlpha(isLight ? 24 : 36),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.inventory_2_outlined,
                    color: AppColors.blue500,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '数据备份与恢复',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '支持导入呆呆面板备份（.tgz / .enc / 旧版 .json）以及青龙面板导出的 .tgz 包。',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                OutlinedButton.icon(
                  onPressed: _uploading || _busyRestoring
                      ? null
                      : _uploadBackup,
                  icon: _buildActionIcon(_uploading, Icons.upload_file_rounded),
                  label: Text(_uploading ? '导入中...' : '导入备份'),
                ),
                FilledButton.icon(
                  onPressed: _creating || _busyRestoring ? null : _createBackup,
                  icon: _buildActionIcon(
                    _creating,
                    Icons.add_circle_outline_rounded,
                  ),
                  label: Text(_creating ? '创建中...' : '创建备份'),
                ),
              ],
            ),
            const SizedBox(height: 14),
            const AppNotice(
              color: AppColors.primary,
              text: '恢复过程中会轮询显示实时进度；加密备份恢复时需要输入备份密码。',
            ),
            if (_loading && _backups.isNotEmpty) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(minHeight: 3),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRestoreProgressCard(bool isLight) {
    final progress = _restoreProgress;
    final theme = Theme.of(context);
    final color = _restoreStatusColor(isLight, progress);
    final selectionLabels = progress.selection?.labels() ?? const <String>[];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: color.withAlpha(isLight ? 24 : 36),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(_restoreStatusIcon(progress), color: color),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        progress.active ? '正在恢复备份' : '恢复进度',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _restoreStatusText(progress),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: color,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!progress.active)
                  IconButton(
                    tooltip: '收起',
                    onPressed: () =>
                        setState(() => _hideRestoreProgress = true),
                    icon: const Icon(Icons.close_rounded),
                  ),
              ],
            ),
            if (progress.filename.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                progress.filename,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
            const SizedBox(height: 14),
            LinearProgressIndicator(
              value: progress.failed
                  ? null
                  : progress.percent.clamp(0, 100).toDouble() / 100,
              minHeight: 8,
              borderRadius: BorderRadius.circular(999),
              color: color,
              backgroundColor: isLight
                  ? AppColors.slate100
                  : AppColors.slate800,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Text(
                  '${progress.percent.clamp(0, 100)}%',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
                const Spacer(),
                Text(
                  _restoreStageLabel(progress.stage),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            if (progress.message.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                progress.message.trim(),
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
              ),
            ],
            if (progress.error.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              AppNotice(
                color: AppColors.danger,
                text: progress.error.trim(),
                accentText: true,
              ),
            ],
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(
                  avatar: const Icon(
                    Icons.widgets_outlined,
                    size: 16,
                    color: AppColors.blue500,
                  ),
                  label: Text('来源：${_restoreSourceLabel(progress.source)}'),
                ),
                if (progress.startedAt != null)
                  Chip(
                    avatar: const Icon(
                      Icons.schedule_outlined,
                      size: 16,
                      color: AppColors.blue500,
                    ),
                    label: Text('开始：${_formatDateTime(progress.startedAt)}'),
                  ),
                if (progress.updatedAt != null)
                  Chip(
                    avatar: const Icon(
                      Icons.update_outlined,
                      size: 16,
                      color: AppColors.blue500,
                    ),
                    label: Text('更新：${_formatDateTime(progress.updatedAt)}'),
                  ),
              ],
            ),
            if (selectionLabels.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: selectionLabels
                    .map(
                      (label) => Chip(
                        label: Text(label),
                        side: BorderSide(color: color.withAlpha(56)),
                        backgroundColor: color.withAlpha(18),
                        labelStyle: TextStyle(
                          color: color,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    )
                    .toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBackupCard(_BackupFileRecord record, bool isLight) {
    final theme = Theme.of(context);
    final downloading = _downloading.contains(record.filename);
    final deleting = _deleting.contains(record.filename);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: record.encrypted
                        ? AppColors.amber500.withAlpha(isLight ? 18 : 28)
                        : AppColors.blue500.withAlpha(isLight ? 18 : 28),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    record.encrypted
                        ? Icons.lock_outline_rounded
                        : Icons.archive_outlined,
                    color: record.encrypted
                        ? AppColors.amber500
                        : AppColors.blue500,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        record.filename,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          Chip(
                            label: Text(_formatSize(record.size)),
                            avatar: const Icon(
                              Icons.data_object_rounded,
                              size: 16,
                            ),
                          ),
                          Chip(
                            label: Text(_formatDateTime(record.createdAt)),
                            avatar: const Icon(
                              Icons.schedule_outlined,
                              size: 16,
                            ),
                          ),
                          if (record.encrypted)
                            const Chip(
                              label: Text('已加密'),
                              avatar: Icon(
                                Icons.shield_outlined,
                                size: 16,
                                color: AppColors.amber500,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: downloading
                      ? null
                      : () => _downloadBackup(record.filename),
                  icon: _buildActionIcon(downloading, Icons.download_rounded),
                  label: Text(downloading ? '保存中...' : '下载'),
                ),
                FilledButton.icon(
                  onPressed: _busyRestoring
                      ? null
                      : () => _restoreBackup(record.filename),
                  icon: const Icon(Icons.restore_rounded, size: 18),
                  label: const Text('恢复'),
                ),
                OutlinedButton.icon(
                  onPressed: deleting || _busyRestoring
                      ? null
                      : () => _deleteBackup(record.filename),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.red500,
                  ),
                  icon: _buildActionIcon(
                    deleting,
                    Icons.delete_outline_rounded,
                  ),
                  label: Text(deleting ? '删除中...' : '删除'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;

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
                      '备份与恢复',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '刷新',
                    onPressed: _loading ? null : _refresh,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: RefreshIndicator(
                color: AppColors.primary,
                onRefresh: _refresh,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                  children: [
                    _buildActionCard(isLight),
                    if (_showProgressCard) ...[
                      const SizedBox(height: 12),
                      _buildRestoreProgressCard(isLight),
                    ],
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Text(
                          '备份文件',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '${_backups.length} 个',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (_loading && _backups.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 60),
                        child: Center(
                          child: CircularProgressIndicator(
                            color: AppColors.primary,
                          ),
                        ),
                      )
                    else if (_backups.isEmpty)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 32,
                          ),
                          child: Column(
                            children: [
                              Icon(
                                Icons.folder_open_rounded,
                                size: 56,
                                color: isLight
                                    ? AppColors.slate400.withAlpha(170)
                                    : AppColors.slate600,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                '暂无备份文件',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '可以先创建一个本地备份，或导入已有的面板备份包。',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  height: 1.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      ..._backups.map(
                        (record) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _buildBackupCard(record, isLight),
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
