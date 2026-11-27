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

  /// 每发一次 GET 加一。并发的请求可能乱序回来（每个 GET 都带整份日志，
  /// 大包慢、小包快），只认比上次已应用的那份更新的回包，
  /// 晚到的旧快照不能把正文退回去、也不能把已结束的运行改回「实时输出」。
  int _requestSeq = 0;
  int _appliedSeq = 0;

  /// 本轮运行还没回来的 GET 个数。周期轮询碰到有在途请求就跳过这一跳：
  /// 慢网下 RTT 超过轮询间隔时，不再一跳叠一跳地拉整份日志。
  ///
  /// 按轮计数，[_startRunTracking] 时清零。停止前发出的慢轮询可能在
  /// 「重新运行」之后还挂着；若仍算在里面，新一轮每跳都被它挡住，
  /// 正文停在那儿直到它回来或超时（dio 接收超时 30s）。
  int _inFlight = 0;

  /// 第几轮运行跟踪，[_startRunTracking] 时加一。请求记下发出时的轮次，
  /// 回来时只有还在同一轮才扣减 [_inFlight]，上一轮的请求不会把它扣成负数
  /// （负数同样永远不等于 0，轮询会就此停掉）。
  int _trackingEpoch = 0;

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
    _trackingEpoch++;
    _inFlight = 0;

    _loadLogs();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 700), (_) {
      if (_inFlight == 0) {
        _loadLogs();
      }
    });
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
    final epoch = _trackingEpoch;
    final seq = ++_requestSeq;
    _inFlight++;
    try {
      final resp = await DioClient.instance.dio.get(
        ApiEndpoints.scriptsRunLogs(activeRunId),
      );
      if (!mounted || activeRunId != _runId || seq < _appliedSeq) return;
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
      // 已经结束（面板报了完成，或用户刚点了停止）就只进不退：
      // 停止前发出、晚到的 done=false 只是旧快照，计时器也已取消，
      // 应用了页面会永远卡在「实时输出」。
      if (_done && !done) return;
      _appliedSeq = seq;
      final exitCode = data['exit_code'];
      final status = data['status']?.toString() ?? '';

      final (label, tone) = _resolveStatus(status, exitCode, done);

      _applyLogs(nextLogs);
      setState(() {
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
      if (!mounted || activeRunId != _runId || seq < _appliedSeq) return;
      setState(() {
        _loading = false;
        // 已结束的运行保留结束时的状态，补拉失败不改成「读取失败」。
        if (_log.isEmpty && !_done) {
          _statusLabel = '日志读取失败';
          _statusTone = FullscreenLogTone.failed;
        }
      });
    } finally {
      if (epoch == _trackingEpoch) _inFlight--;
    }
  }

  /// 把这一跳拉到的整份日志并进缓冲区。
  ///
  /// 面板每跳都回整份日志。以前每跳都 `replaceAll`：generation 一变，LogView
  /// 就当成换了一份日志，跟随中重建尾段并 jumpTo，选区被清、拖动被打断，
  /// 上翻时「新增 N 行」也被清零。调试日志在面板端只往后追加，
  /// 所以内容没变就不动缓冲区，以现有内容开头就只追加多出来的行；
  /// 对不上（面板超过上限后成块丢掉了头部）才整段替换。
  void _applyLogs(List<String> next) {
    final total = _log.totalCount;
    if (next.length < total || !_startsWithBuffered(next)) {
      _log.replaceAll(next);
    } else if (next.length > total) {
      _log.append(next.sublist(total));
    }
  }

  /// [next] 是否以缓冲区现有内容开头（调用方保证 `next.length >= totalCount`）。
  ///
  /// 只比还留在内存里的行（更早的已被缓冲区裁掉），从最后一行往前比：
  /// 真有变化时几乎总是尾部先对不上，能尽早返回。
  bool _startsWithBuffered(List<String> next) {
    final dropped = _log.droppedCount;
    for (var i = _log.length - 1; i >= 0; i--) {
      if (next[dropped + i] != _log.lineAt(i)) return false;
    }
    return true;
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
