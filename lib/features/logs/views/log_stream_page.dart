import 'dart:async';

import 'package:dio/dio.dart' show DioException;
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

/// 流结束后按日志详情结算结果：最多查几次、每次查之前等多久（第一次也等）。
///
/// 面板是先关 TinyLog（SSE 随即发 done:finished）、再读文件压缩、最后才把结果
/// 写进 task_logs（`service/task_executor.go` 结算 defer 里 `tinyLog.Close()`
/// 在 `Updates(status…)` 之前），刚收到 done 就查几乎总是「运行中」。
const int kLogSettleAttempts = 5;
const Duration kLogSettleRetryDelay = Duration(milliseconds: 500);

class LogStreamPage extends ConsumerStatefulWidget {
  final int logId;

  const LogStreamPage({super.key, required this.logId});

  @override
  ConsumerState<LogStreamPage> createState() => _LogStreamPageState();
}

class _LogStreamPageState extends ConsumerState<LogStreamPage> {
  final _sseClient = SseClient();

  /// 日志正文。增量追加、超长只留最近一部分，渲染与滚动跟随都交给 LogView。
  final _log = LogLineBuffer();

  /// 服务端重连一律从头重放整段历史（没有 Last-Event-ID），
  /// 靠它把重放的行抵扣掉，用户才不会看到日志翻倍。
  final _replayBuffer = SseReplayBuffer();

  bool _loading = true;
  bool _done = false;
  int? _taskId;

  /// 面板记录的这条日志的状态（task_logs.status），只从日志详情里取。
  ///
  /// SSE 的 done:finished 只表示 TinyLog 关了、流结束了，不带成败
  /// （panel-contract.md「实时日志」），不能拿它改这个值；流结束后由
  /// [_settleFromDetail] 重新取详情结算。状态胶囊的绿 / 红只认它。
  int? _logStatus;
  num? _durationSeconds;
  String _status = '加载中...';
  Color? _logBackgroundColor;

  /// 这条日志在磁盘上有没有独立的原始日志文件。
  ///
  /// null 表示「还没拿到日志详情」（加载中或加载失败），此时不给下载入口 ——
  /// 那种状态下既不知道文件存不存在，也说不出为什么不能下。
  bool? _hasRawFile;
  bool _downloadingRaw = false;

  /// 这条日志对应任务的名字与命令，只服务「编辑对应脚本」。
  ///
  /// [_command] 允许一直是 null —— 老面板的日志详情不返回它，那时靠
  /// [_resolveCommand] 在**点击那一刻**去任务列表兜底，拿到后回填这里。
  String? _taskName;
  String? _command;
  bool _resolvingScript = false;
  bool _actionBusy = false;

  /// 用户在本页点了「停止运行」（停止接口已经发出）。
  ///
  /// 面板停止是先发 TERM、留 5 秒宽限（`StopTask`），脚本收尾、后置脚本的输出
  /// 还会经 SSE 送来，最后照常发 done:finished。停止之后这些都只追加正文，
  /// 不能再把状态改回「运行中」；done 也不能把它改成别的，结果以结算为准。
  bool _stopRequested = false;

  /// 停止请求在途时流先收口了（done / 出错）：原本该显示的状态记在这里。
  ///
  /// 在途期间这些都让位给「已停止」；可停止请求要是失败了（多半是同一次断网，
  /// SSE 和停止请求一起断），得把它补回来，不能停在「已停止」或「运行中」。
  String? _statusIfStopFails;

  /// 结算在途：done 与随后的 onDone 都会触发结算，只查一轮。
  bool _settling = false;
  Timer? _settleRetryTimer;

  /// 每次 [_loadLog] 自增。上一轮的结算晚于重新加载才回来时，靠它作废。
  int _loadGeneration = 0;

  /// 交给 LogView 的 follow，只在加载时定一次（issue #147）：
  /// 运行中的日志跟随；已结束的日志按账户偏好，定位到底部就借用跟随模式，
  /// 否则从顶部开始。
  /// ⚠️ 不能跟着 _done 变：运行中的日志收到 done 时 _done 会翻成 true，
  /// LogView 中途切换 follow 会把正在看的位置整个重排。
  bool _follow = true;

  /// 账户偏好「打开已结束的日志时定位到底部」的当前值；null = 面板不支持，菜单里不给这一项。
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
    _loadGeneration++;
    _settling = false;
    _settleRetryTimer?.cancel();
    setState(() {
      _loading = true;
      _stopRequested = false;
      _statusIfStopFails = null;
      _status = '加载日志...';
    });

    try {
      // 偏好与日志详情一起发，不多等一个往返；它自己吞掉所有错误，不会让日志加载失败。
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
      // LogView 只在第一次建出来时按 follow 定位，所以得先等偏好回来再填正文。
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
        // 面板 v3.2.0 起才在日志详情里带 command；拿不到就保持 null，
        // 由「编辑对应脚本」点击时的兜底查询补，这里不预取任务列表。
        _command = log.command;
        _log.replaceAll(historyLines);
        _done = !log.isRunning;
        _loading = false;
        _status = log.isRunning ? '连接中...' : log.statusText;
        // 与面板签发票据前的前置判断同源：task_logs.log_path 非空才有原始文件。
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
        _status = '加载失败';
      });
    }
  }

  /// 面板已经给出这条日志的结果（不是运行中，也不是还没拿到）。
  bool get _resultKnown =>
      _logStatus != null && _logStatus != kLogStatusRunning;

  /// 流结束后重新取日志详情，按面板记录的状态结算（成功 / 失败 / 已终止）。
  ///
  /// 每次查之前都先等 [kLogSettleRetryDelay]，第一次也一样：面板关 TinyLog
  /// （done 随即发出）之后还要读文件、压缩才写结果，刚收到 done 就查几乎总是
  /// 「运行中」，而运行中的详情是从 log_path 读的整份日志，大日志会白下一遍。
  /// 还是「运行中」就再等再查，最多 [attempts] 次；一直拿不到就停在中性的
  /// 「已结束」，不猜成败。
  /// 正文不换：SSE 送来的就是这次运行的输出，换成详情正文会把正在看的位置整个重排。
  Future<void> _settleFromDetail({int attempts = kLogSettleAttempts}) async {
    if (_settling || _resultKnown) return;
    _settling = true;
    final generation = _loadGeneration;
    try {
      for (var attempt = 0; attempt < attempts; attempt++) {
        await _waitBeforeSettle();
        if (!mounted || generation != _loadGeneration) return;
        TaskLog? log;
        try {
          final response = await DioClient.instance.dio.get(
            ApiEndpoints.logById(widget.logId),
          );
          final data = extractData(response.data);
          if (data is Map) {
            log = TaskLog.fromJson(Map<String, dynamic>.from(data));
          }
        } on DioException catch (error) {
          // 404（日志被删 / 被保留策略清理）这类 4xx 再查也一样；网络抖一下下一轮再查。
          final code = error.response?.statusCode ?? 0;
          if (code >= 400 && code < 500) return;
        } catch (_) {}
        if (!mounted || generation != _loadGeneration) return;
        if (log == null || log.isRunning) continue;
        if (log.status == null) return;
        final settled = log;
        setState(() {
          _done = true;
          _logStatus = settled.status;
          _status = settled.statusText;
          _durationSeconds = settled.duration ?? _durationSeconds;
        });
        return;
      }
    } finally {
      if (generation == _loadGeneration) {
        _settling = false;
      }
    }
  }

  /// 结算每次查之前的等待。用可取消的 Timer：页面关了就不再留着一个挂起的定时器。
  Future<void> _waitBeforeSettle() {
    final completer = Completer<void>();
    _settleRetryTimer?.cancel();
    _settleRetryTimer = Timer(kLogSettleRetryDelay, completer.complete);
    return completer.future;
  }

  /// 重连前把已显示的行交给去重缓冲。
  ///
  /// 日志太长时前面的行已经从内存里丢掉了，但服务端仍从第一行开始重放，
  /// 所以要告诉它先按行数跳过那一段，否则第一行就对不上、整段历史被重复追加一遍。
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
      // 重放去重统一挂在这里：不管重连是服务端 done:reconnect 触发的，
      // 还是 token 续期后客户端自己发起的，行为都一样。
      onReconnect: _resetReplayBuffer,
      onEvent: (event) {
        if (!mounted) return;

        if (event.event == 'done') {
          if (event.data == 'reconnect') {
            // reconnect 是「任务还在跑，换条连接继续」，不是结束。
            // 停止之后不改：那次运行已经要停了，按钮不能再变回「停止运行」。
            if (_stopRequested) return;
            setState(() {
              _done = false;
              _status = '运行中';
            });
            return;
          }
          final finished =
              event.data == 'finished' || event.data == 'finished-late';
          // 流结束不等于成功：先写中性的「已结束」，结果由下面的结算给。
          final ended = finished ? '已结束' : event.data;
          setState(() {
            _done = true;
            if (_resultKnown) {
              // 已经结算过（停止接口在途时 done 先到又结算完了），不再改。
            } else if (_stopRequested) {
              _status = '已停止';
              _statusIfStopFails = ended;
            } else {
              _status = ended;
            }
          });
          _settleFromDetail();
          return;
        }

        final newLines = _replayBuffer.consume(_splitLines(event.data));
        if (newLines.isEmpty) return;

        final wasEmpty = _log.isEmpty;
        _log.append(newLines);
        // 正文由 LogView 监听缓冲区自己刷新。整页只在「从无到有」或状态变了时重建，
        // 不再每来一段日志就把整页重建一遍。
        // 停止之后送来的是收尾输出（TERM 收尾、后置脚本、终止提示），只追加，不改状态。
        if (!_stopRequested && (wasEmpty || _status != '运行中')) {
          setState(() => _status = '运行中');
        }
      },
      onDone: () {
        if (!mounted) return;
        // 没收到 done 就断了（反代掐了长连接等）：任务多半还在跑，只看一眼详情，
        // 还在跑就停在「连接结束」，不按收口的节奏连查几遍（运行中的详情每次都是
        // 整份日志）。正常收口时 done 已经先到、结算已在途，这里不会多查。
        final cutShort = _status == '运行中' || _status == '连接中...';
        setState(() {
          _done = true;
          if (cutShort) _status = '连接结束';
        });
        _settleFromDetail(attempts: cutShort ? 1 : kLogSettleAttempts);
      },
      onError: (error) {
        if (!mounted) return;
        // 状态胶囊塞不下整句，完整的「登录已失效，请重新登录」由登录页负责说。
        final failure = error is SseAuthFailure ? '登录已失效' : '连接错误';
        setState(() {
          _done = true;
          if (_resultKnown) return;
          if (_stopRequested) {
            // 停止之后流断了不算出错：显示「已停止」，结果交给结算。停止请求还在途
            // 的话先把出错记下，停止失败时再显示出来（见 _stopTask）。
            _status = '已停止';
            _statusIfStopFails = failure;
            return;
          }
          _status = failure;
        });
        if (_stopRequested) {
          _settleFromDetail();
        }
      },
    );
  }

  /// 下载服务端磁盘上的原始日志文件。
  ///
  /// 顺序是「先把字节拉完，再弹系统保存框」，**不能反过来**：
  /// 票据只活 120 秒（见 utils/raw_log_download.dart），
  /// 先让用户去保存框里挑目录的话，挑久一点票就过期了。
  /// 这几秒的进度反馈挂在 `⋮` 上（menuBusy）。
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
    if (taskId == null || _actionBusy || _done) return;
    setState(() {
      _actionBusy = true;
      // 先于请求置上：stopTask 还要等任务列表刷新完，这期间 done 先到的话，
      // 也只能显示「已停止」，不能先闪一下别的结果。
      _stopRequested = true;
      _statusIfStopFails = null;
    });
    try {
      await ref.read(taskProvider.notifier).stopTask(taskId);
      if (!mounted) return;
      // 在途期间流已经收口（done / 断开 / 出错）的话，之后不会再有事件触发结算，
      // 这里补一次（已在结算或已有结果时什么都不做）。
      final streamEnded = _done;
      // SSE 不关：收尾输出还会送来，done 到了再按详情结算（见 _settleFromDetail）。
      setState(() {
        _done = true;
        if (!_resultKnown) _status = '已停止';
      });
      if (streamEnded) _settleFromDetail();
      AppSnack.success(context, '任务已停止');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _stopRequested = false;
        // 在途期间流已经收口、状态让位给了「已停止」：停止没成，补回当时该显示的
        // 状态（「已结束」「连接错误」等）；结果仍以结算为准。
        final pending = _statusIfStopFails;
        _statusIfStopFails = null;
        if (pending != null && !_resultKnown) _status = pending;
      });
      AppSnack.error(context, extractErrorMessage(error, '停止任务失败'));
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

  /// 拿到任务命令：日志详情自带 > 任务列表内存缓存 > 现查任务列表。
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

  /// 状态胶囊的色调。绿 / 红只认面板给的日志状态 [_logStatus]，
  /// 「已结束」「已停止」「连接结束」这类说不出成败的一律中性。
  FullscreenLogTone _resolveTone() {
    if (!_done) return FullscreenLogTone.running;
    if (_status == '加载失败' || _status == '连接错误' || _status == '登录已失效') {
      return FullscreenLogTone.failed;
    }
    switch (_logStatus) {
      case kLogStatusSuccess:
        return FullscreenLogTone.success;
      case kLogStatusFailed:
        return FullscreenLogTone.failed;
      default:
        return FullscreenLogTone.neutral;
    }
  }

  @override
  void dispose() {
    _settleRetryTimer?.cancel();
    _sseClient.close();
    _log.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // `/api/scripts/*` 与停止 / 重新运行在面板侧要 operator，日志只要 viewer：
    // viewer 不给这些入口；日志详情没到手（_taskId == null）时也不给。
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
          // 只锁自己：重复点会重复发票据请求。
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
      // 超长被截断后，完整内容只在磁盘上的原始日志文件里。
      truncatedActionLabel: _hasRawFile == true ? '下载完整日志' : null,
      onTruncatedAction: _downloadRawLog,
      onStop: (!_done && canOperate) ? _stopTask : null,
      stopBusy: _actionBusy,
      onRerun: (_done && canOperate) ? _rerunTask : null,
      rerunBusy: _actionBusy,
      onOpenScript: canOpenScript ? _openScriptEditor : null,
      openScriptBusy: _resolvingScript,
      // 下载原始日志要先把字节拉完才弹保存框、老面板跳脚本要兜底查任务列表，
      // 都可能要几秒：菜单关了之后，进度只能挂在 `⋮` 上（只是反馈，不兼任锁）。
      menuBusy: _downloadingRaw || _resolvingScript,
      extraMenuEntries: extraMenus,
      // 复制提示由 scaffold 在点击那一刻按缓冲区现算（页面流式追加时不重建）；
      // 这里只补截断时的引导。
      truncatedCopyHint: _hasRawFile == true ? '完整日志请下载原始日志' : null,
    );
  }
}
