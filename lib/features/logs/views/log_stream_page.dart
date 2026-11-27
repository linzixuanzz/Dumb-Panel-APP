import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_provider.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/network/sse_client.dart';
import '../../../shared/models/task.dart';
import '../../../shared/models/task_log.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/utils/duration_utils.dart';
import '../../../shared/utils/log_background.dart';
import '../../../shared/utils/log_line_buffer.dart';
import '../../../shared/utils/panel_enums.dart';
import '../../../shared/utils/sse_replay_buffer.dart';
import '../../../shared/utils/task_command.dart';
import '../../../shared/widgets/app_snack.dart';
import '../../../shared/widgets/fullscreen_log_scaffold.dart';
import '../../tasks/providers/task_provider.dart';
import '../utils/log_open_preference.dart';
import '../utils/raw_log_download.dart';
import '../utils/task_command_lookup.dart';

class LogStreamPage extends ConsumerStatefulWidget {
  final int logId;

  const LogStreamPage({super.key, required this.logId});

  @override
  ConsumerState<LogStreamPage> createState() => _LogStreamPageState();
}

class _LogStreamPageState extends ConsumerState<LogStreamPage> {
  final _sseClient = SseClient();
  final _log = LogLineBuffer();
  final _replayBuffer = SseReplayBuffer();

  bool _loading = true;
  bool _done = false;
  int? _taskId;
  int? _logStatus;
  num? _durationSeconds;
  String _status = '加载中...';
  Color? _logBackgroundColor;

  bool? _hasRawFile;
  bool _downloadingRaw = false;

  String? _taskName;
  String? _command;
  bool _resolvingScript = false;
  bool _actionBusy = false;

  bool _follow = true;
  bool? _openAtBottom;

  @override
  void initState() {
    super.initState();
    _loadAppearance();
    _loadLog();
  }

  Future<void> _loadAppearance() async {
    final color = await loadPanelLogBackgroundColor();
    if (!mounted) return;
    setState(() => _logBackgroundColor = color);
  }

  Future<void> _loadLog() async {
    setState(() {
      _loading = true;
      _status = '加载日志...';
    });

    try {
      final openAtBottomFuture = loadOpenFinishedLogAtBottom();
      final response = await DioClient.instance.dio.get(
        ApiEndpoints.logById(widget.logId),
      );
      final data = extractData(response.data);
      if (data is! Map) {
        throw StateError('Invalid log payload');
      }

      final payload = Map<String, dynamic>.from(data);
      final log = TaskLog.fromJson(payload);
      final content = payload['content']?.toString() ?? '';
      final historyLines = log.isRunning
          ? const <String>[]
          : _splitLines(content);
      final openAtBottom = await openAtBottomFuture;

      if (!mounted) return;

      setState(() {
        _openAtBottom = openAtBottom;
        _follow =
            log.isRunning || (openAtBottom ?? kOpenFinishedLogAtBottomDefault);
        _taskId = log.taskId;
        _taskName = log.taskName;
        _logStatus = log.status;
        _durationSeconds = log.duration;
        _command = log.command;
        _log.replaceAll(historyLines);
        _done = !log.isRunning;
        _loading = false;
        _status = log.isRunning ? '连接中...' : log.statusText;
        _hasRawFile = (log.logPath ?? '').trim().isNotEmpty;
      });

      if (log.isRunning) {
        _connect();
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _done = true;
        _logStatus = kLogStatusFailed;
        _status = '加载失败';
      });
    }
  }

  void _resetReplayBuffer() {
    _replayBuffer.reset(_log.lines, skipLeading: _log.droppedCount);
  }

  void _connect() {
    final taskId = _taskId;
    if (taskId == null) return;

    _resetReplayBuffer();
    _sseClient.connect(
      path: ApiEndpoints.logStream(taskId),
      autoReconnect: true,
      onReconnect: _resetReplayBuffer,
      onEvent: (event) {
        if (!mounted) return;

        if (event.event == 'done') {
          if (event.data == 'reconnect') {
            setState(() {
              _done = false;
              _status = '运行中';
            });
            return;
          }
          setState(() {
            _done = true;
            if (event.data == 'finished' || event.data == 'finished-late') {
              _logStatus = kLogStatusSuccess;
              _status = '已完成';
            } else {
              _status = event.data;
            }
          });
          return;
        }

        final newLines = _replayBuffer.consume(_splitLines(event.data));
        if (newLines.isEmpty) return;

        final wasEmpty = _log.isEmpty;
        _log.append(newLines);
        if (wasEmpty || _status != '运行中') {
          setState(() => _status = '运行中');
        }
      },
      onDone: () {
        if (!mounted) return;
        setState(() {
          _done = true;
          if (_status == '运行中' || _status == '连接中...') {
            _status = '连接结束';
          }
        });
      },
      onError: (error) {
        if (!mounted) return;
        setState(() {
          _done = true;
          _logStatus = kLogStatusFailed;
          _status = error is SseAuthFailure ? '登录已失效' : '连接错误';
        });
      },
    );
  }

  Future<void> _downloadRawLog() async {
    if (_downloadingRaw) return;
    if (_hasRawFile != true) {
      AppSnack.warn(context, '这条日志的内容存在数据库里，没有独立的原始日志文件');
      return;
    }

    setState(() => _downloadingRaw = true);
    try {
      final file = await const RawLogDownloader().downloadTaskLog(widget.logId);
      if (!mounted) return;
      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: '保存原始日志',
        fileName: file.filename,
        type: FileType.any,
        bytes: file.bytes,
      );
      if (!mounted) return;
      if (savedPath == null) {
        AppSnack.show(context, '已取消保存');
        return;
      }
      AppSnack.success(context, '原始日志已保存');
    } on RawLogDownloadException catch (error) {
      if (!mounted) return;
      AppSnack.error(context, error.message);
    } on UnsupportedError {
      if (!mounted) return;
      AppSnack.warn(context, '当前平台暂不支持直接保存文件');
    } catch (error) {
      if (!mounted) return;
      AppSnack.error(context, extractListErrorMessage(error, '下载原始日志失败'));
    } finally {
      if (mounted) {
        setState(() => _downloadingRaw = false);
      }
    }
  }

  Future<void> _toggleOpenAtBottom() async {
    final next = !_openAtBottom!;
    setState(() => _openAtBottom = next);
    try {
      final saved = await saveOpenFinishedLogAtBottom(next);
      if (!mounted) return;
      if (!saved) {
        setState(() => _openAtBottom = !next);
        AppSnack.warn(context, '当前面板版本不支持，请升级到 v3.3.3 或更高');
        return;
      }
      AppSnack.success(
        context,
        next ? '已开启：下次打开已结束的日志会定位到底部' : '已关闭：下次打开已结束的日志从顶部开始',
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _openAtBottom = !next);
      AppSnack.error(context, extractListErrorMessage(error, '保存设置失败'));
    }
  }

  Future<void> _openScriptEditor() async {
    if (_resolvingScript) return;
    final taskId = _taskId;
    if (taskId == null) return;

    final command = await _resolveCommand(taskId);
    if (!mounted) return;
    if (command == null) {
      AppSnack.warn(context, '未能获取任务命令，无法定位脚本');
      return;
    }

    final scriptPath = extractScriptPathFromCommand(command);
    if (scriptPath == null) {
      AppSnack.warn(context, '该任务不是脚本任务，命令里没有可打开的脚本文件');
      return;
    }

    context.push('/scripts/view', extra: scriptPath);
  }

  Future<void> _stopTask() async {
    final taskId = _taskId;
    if (taskId == null || _actionBusy) return;
    setState(() => _actionBusy = true);
    try {
      await ref.read(taskProvider.notifier).stopTask(taskId);
      if (!mounted) return;
      setState(() {
        _done = true;
        _logStatus = kLogStatusAborted;
        _status = '已停止';
      });
      AppSnack.success(context, '任务已停止');
    } catch (error) {
      if (mounted) {
        AppSnack.error(context, extractErrorMessage(error, '停止任务失败'));
      }
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Future<void> _rerunTask() async {
    final taskId = _taskId;
    if (taskId == null || _actionBusy) return;
    setState(() => _actionBusy = true);
    try {
      await ref.read(taskProvider.notifier).runTask(taskId);
      if (!mounted) return;
      if (GoRouter.maybeOf(context) != null) {
        context.pushReplacement('/tasks/$taskId/live-logs', extra: _taskName);
      } else {
        await _loadLog();
      }
    } catch (error) {
      if (!mounted) return;
      final message = extractErrorMessage(error, '启动任务失败');
      if (message.contains('运行中') && GoRouter.maybeOf(context) != null) {
        context.pushReplacement('/tasks/$taskId/live-logs', extra: _taskName);
      } else {
        AppSnack.error(context, message);
      }
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Future<String?> _resolveCommand(int taskId) async {
    final cached = _command;
    if (cached != null) return cached;

    final fromMemory = pickCommandFromTasks(
      ref.read(taskProvider).tasks,
      taskId,
    );
    if (fromMemory != null) {
      _command = fromMemory;
      return fromMemory;
    }

    setState(() => _resolvingScript = true);
    try {
      final fetched = await _fetchCommandFromTaskList(taskId);
      _command = fetched;
      return fetched;
    } catch (_) {
      return null;
    } finally {
      if (mounted) {
        setState(() => _resolvingScript = false);
      }
    }
  }

  Future<String?> _fetchCommandFromTaskList(int taskId) async {
    final query = <String, dynamic>{'all': 1};
    final keyword = (_taskName ?? '').trim();
    if (keyword.isNotEmpty) {
      query['keyword'] = keyword;
    }

    final response = await DioClient.instance.dio.get(
      ApiEndpoints.tasks,
      queryParameters: query,
    );
    final paginated = extractPaginated(response.data);
    final tasks = paginated.items.map(Task.fromJson).toList();
    return pickCommandFromTasks(tasks, taskId);
  }

  List<String> _splitLines(String content) {
    final normalized = content.replaceAll('\r\n', '\n');
    final lines = normalized.split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    return lines;
  }

  FullscreenLogTone _resolveTone() {
    if (!_done) return FullscreenLogTone.running;
    if (_status == '加载失败' ||
        _status == '连接错误' ||
        _status == '登录已失效' ||
        _logStatus == kLogStatusFailed ||
        _status.contains('失败')) {
      return FullscreenLogTone.failed;
    }
    if (_status == '已完成' ||
        _status == '成功' ||
        _logStatus == kLogStatusSuccess) {
      return FullscreenLogTone.success;
    }
    return FullscreenLogTone.neutral;
  }

  @override
  void dispose() {
    _sseClient.close();
    _log.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider).user;
    final canOperate = _taskId != null && (user?.isOperator ?? false);
    final canOpenScript = canOperate;

    final subtitleParts = <String>[
      if (_taskName != null) '日志 #${widget.logId}',
      if (_durationSeconds != null)
        '耗时 ${formatDurationSeconds(_durationSeconds)}',
    ];

    final extraMenus = <FullscreenLogMenuEntry>[
      if (_hasRawFile != null)
        FullscreenLogMenuEntry(
          id: 'download_raw',
          label: '下载原始日志',
          icon: Icons.download_outlined,
          enabled: !_downloadingRaw,
          onTap: _downloadRawLog,
        ),
      if (canOpenScript)
        FullscreenLogMenuEntry(
          id: 'open_script',
          label: '编辑对应脚本',
          icon: Icons.code_rounded,
          enabled: !_resolvingScript,
          onTap: _openScriptEditor,
        ),
      if (_openAtBottom != null)
        FullscreenLogMenuEntry(
          id: 'open_at_bottom',
          label: '打开已结束的日志时定位到底部',
          checked: _openAtBottom!,
          onTap: _toggleOpenAtBottom,
        ),
    ];

    return FullscreenLogScaffold(
      title: _taskName ?? '日志 #${widget.logId}',
      subtitle: subtitleParts.join(' · '),
      statusLabel: _status,
      statusTone: _resolveTone(),
      buffer: _log,
      loading: _loading,
      emptyMessage: _done ? '无日志内容' : '等待日志...',
      follow: _follow,
      configuredBackgroundColor: _logBackgroundColor,
      truncatedActionLabel: _hasRawFile == true ? '下载完整日志' : null,
      onTruncatedAction: _downloadRawLog,
      onStop: (!_done && canOperate) ? _stopTask : null,
      stopBusy: _actionBusy,
      onRerun: (_done && canOperate) ? _rerunTask : null,
      rerunBusy: _actionBusy,
      onOpenScript: canOpenScript ? _openScriptEditor : null,
      openScriptBusy: _resolvingScript,
      extraMenuEntries: extraMenus,
      copySuccessToast: _log.droppedCount > 0
          ? '已复制最近 ${_log.length} 行，完整日志请下载原始日志'
          : '日志已复制到剪贴板',
    );
  }
}
