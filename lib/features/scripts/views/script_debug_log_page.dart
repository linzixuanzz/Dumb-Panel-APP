import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/network/api_endpoints.dart';
import '../../../core/network/dio_client.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/utils/log_background.dart';
import '../../../shared/utils/log_line_buffer.dart';
import '../../../shared/widgets/app_snack.dart';
import '../../../shared/widgets/fullscreen_log_scaffold.dart';

/// 脚本调试全屏实时日志路由参数。
class ScriptDebugLogArgs {
  final String path;
  final String initialRunId;

  const ScriptDebugLogArgs({
    required this.path,
    required this.initialRunId,
  });
}

/// 脚本编辑器「运行 / 调试」后的无底栏全屏沉浸式实时日志页（v3.0 彻底取代旧版半屏 ModalBottomSheet）。
class ScriptDebugLogPage extends StatefulWidget {
  final String path;
  final String initialRunId;

  const ScriptDebugLogPage({
    super.key,
    required this.path,
    required this.initialRunId,
  });

  @override
  State<ScriptDebugLogPage> createState() => _ScriptDebugLogPageState();
}

class _ScriptDebugLogPageState extends State<ScriptDebugLogPage> {
  final _log = LogLineBuffer();

  late String _runId = widget.initialRunId;
  bool _loading = true;
  bool _done = false;
  bool _actionBusy = false;
  String _statusLabel = '实时输出';
  FullscreenLogTone _statusTone = FullscreenLogTone.running;

  Timer? _pollTimer;
  Timer? _elapsedTimer;
  final Stopwatch _stopwatch = Stopwatch();
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
    _startRunTracking();
  }

  void _startRunTracking() {
    _pollTimer?.cancel();
    _elapsedTimer?.cancel();
    _stopwatch
      ..reset()
      ..start();

    _loadLogs();
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 700),
      (_) => _loadLogs(),
    );
    _elapsedTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted && !_done) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _elapsedTimer?.cancel();
    _stopwatch.stop();
    _log.dispose();
    super.dispose();
  }

  Future<void> _loadLogs() async {
    final activeRunId = _runId;
    try {
      final resp = await DioClient.instance.dio.get(
        ApiEndpoints.scriptsRunLogs(activeRunId),
      );
      if (!mounted || activeRunId != _runId) return;
      final data = extractData(resp.data);
      if (data is! Map) return;

      final rawLogs = data['logs'];
      final nextLogs = <String>[];
      if (rawLogs is List) {
        for (final item in rawLogs) {
          final text = item.toString().replaceAll('\r\n', '\n');
          for (final line in text.split('\n')) {
            if (line.trim().isNotEmpty) {
              nextLogs.add(line);
            }
          }
        }
      }
      final done = data['done'] == true;
      final exitCode = data['exit_code'];
      final status = data['status']?.toString() ?? '';

      final (label, tone) = _resolveStatus(status, exitCode, done);

      setState(() {
        _log.replaceAll(nextLogs);
        _done = done;
        _loading = false;
        _statusLabel = label;
        _statusTone = tone;
      });

      if (done) {
        _stopwatch.stop();
        _pollTimer?.cancel();
        _elapsedTimer?.cancel();
      }
    } catch (_) {
      if (!mounted || activeRunId != _runId) return;
      setState(() {
        _loading = false;
        if (_log.isEmpty) {
          _statusLabel = '日志读取失败';
          _statusTone = FullscreenLogTone.failed;
        }
      });
    }
  }

  (String, FullscreenLogTone) _resolveStatus(
    String status,
    dynamic exitCode,
    bool done,
  ) {
    if (!done) {
      return ('实时输出', FullscreenLogTone.running);
    }
    if (status == 'stopped') {
      return ('已停止', FullscreenLogTone.neutral);
    }
    if (status == 'success' || (exitCode is num && exitCode == 0)) {
      return ('执行成功', FullscreenLogTone.success);
    }
    if (exitCode is num) {
      return ('退出码 $exitCode', FullscreenLogTone.failed);
    }
    return ('执行失败', FullscreenLogTone.failed);
  }

  Future<void> _stopRun() async {
    if (_actionBusy || _done) return;
    setState(() => _actionBusy = true);
    try {
      await DioClient.instance.dio.put(ApiEndpoints.scriptsRunStop(_runId));
      if (!mounted) return;
      _stopwatch.stop();
      _pollTimer?.cancel();
      _elapsedTimer?.cancel();
      setState(() {
        _done = true;
        _statusLabel = '已停止';
        _statusTone = FullscreenLogTone.neutral;
      });
      await _loadLogs();
      if (mounted) {
        AppSnack.show(context, '已停止脚本运行');
      }
    } catch (error) {
      if (mounted) {
        AppSnack.error(
          context,
          extractScriptSaveErrorMessage(error, '停止脚本失败'),
        );
      }
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Future<void> _rerunScript() async {
    if (_actionBusy) return;
    setState(() => _actionBusy = true);
    try {
      final resp = await DioClient.instance.dio.post(
        ApiEndpoints.scriptsRun,
        data: {'path': widget.path},
      );
      final raw = resp.data;
      String? nextRunId;
      if (raw is Map && raw['run_id'] != null) {
        nextRunId = raw['run_id'].toString();
      } else if (raw is Map &&
          raw['data'] is Map &&
          raw['data']['run_id'] != null) {
        nextRunId = raw['data']['run_id'].toString();
      }
      if (nextRunId == null || nextRunId.isEmpty) {
        throw StateError('调试任务已启动，但未返回运行 ID');
      }
      if (!mounted) return;
      setState(() {
        _runId = nextRunId!;
        _done = false;
        _loading = true;
        _statusLabel = '实时输出';
        _statusTone = FullscreenLogTone.running;
        _log.clear();
      });
      _startRunTracking();
    } catch (error) {
      if (mounted) {
        AppSnack.error(
          context,
          extractScriptSaveErrorMessage(error, '重新运行失败'),
        );
      }
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  String _formatElapsed() {
    final secs = _stopwatch.elapsedMilliseconds / 1000.0;
    return '${secs.toStringAsFixed(1)}s';
  }

  @override
  Widget build(BuildContext context) {
    final fileName = widget.path.split('/').last;
    final prefix = _done ? '总耗时 ' : '实时耗时 ';

    return FullscreenLogScaffold(
      title: fileName.isEmpty ? '脚本调试' : fileName,
      subtitle: '${widget.path} · $prefix${_formatElapsed()}',
      statusLabel: _statusLabel,
      statusTone: _statusTone,
      buffer: _log,
      loading: _loading,
      emptyMessage: _done ? '脚本执行结束，无控制台输出' : '等待脚本实时输出...',
      configuredBackgroundColor: _logBackgroundColor,
      onStop: !_done ? _stopRun : null,
      stopBusy: _actionBusy,
      onRerun: _done ? _rerunScript : null,
      rerunBusy: _actionBusy,
      copySuccessToast: '已复制调试日志',
    );
  }
}
