import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/network/sse_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/models/task_log.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/utils/ansi_text.dart';
import '../../../shared/utils/log_background.dart';
import '../../../shared/utils/sse_replay_buffer.dart';
import '../../../shared/widgets/app_snack.dart';
import '../utils/raw_log_download.dart';

class LogStreamPage extends StatefulWidget {
  final int logId;

  const LogStreamPage({super.key, required this.logId});

  @override
  State<LogStreamPage> createState() => _LogStreamPageState();
}

class _LogStreamPageState extends State<LogStreamPage> {
  final _sseClient = SseClient();
  final _scrollController = ScrollController();
  final _lines = <String>[];

  /// 服务端重连一律从头重放整段历史（没有 Last-Event-ID），
  /// 靠它把重放的行抵扣掉，用户才不会看到日志翻倍。
  final _replayBuffer = SseReplayBuffer();

  bool _loading = true;
  bool _done = false;
  bool _autoScroll = true;
  int? _taskId;
  String _status = '加载中...';
  Color? _logBackgroundColor;

  /// 这条日志在磁盘上有没有独立的原始日志文件。
  ///
  /// null 表示「还没拿到日志详情」（加载中或加载失败），此时不给下载入口 ——
  /// 那种状态下既不知道文件存不存在，也说不出为什么不能下。
  bool? _hasRawFile;
  bool _downloadingRaw = false;

  @override
  void initState() {
    super.initState();
    _loadAppearance();
    _loadLog();
  }

  Future<void> _loadAppearance() async {
    final color = await loadPanelLogBackgroundColor();
    if (!mounted) {
      return;
    }
    setState(() => _logBackgroundColor = color);
  }

  Future<void> _loadLog() async {
    setState(() {
      _loading = true;
      _status = '加载日志...';
    });

    try {
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

      if (!mounted) {
        return;
      }

      setState(() {
        _taskId = log.taskId;
        _lines
          ..clear()
          ..addAll(historyLines);
        _done = !log.isRunning;
        _loading = false;
        _status = log.isRunning ? '连接中...' : log.statusText;
        // 与面板签发票据前的前置判断同源：resolveTaskLogRecordRawFile 要求
        // task_logs.log_path 非空，否则直接回「该日志没有独立的原始日志文件」。
        // 这里读的是同一个字段，不是客户端另立的一套规则。
        _hasRawFile = (log.logPath ?? '').trim().isNotEmpty;
      });
      if (_autoScroll && historyLines.isNotEmpty) {
        _scrollToBottom();
      }

      if (log.isRunning) {
        _connect();
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _done = true;
        _status = '加载失败';
      });
    }
  }

  void _connect() {
    final taskId = _taskId;
    if (taskId == null) {
      return;
    }

    _replayBuffer.reset(_lines);
    _sseClient.connect(
      path: ApiEndpoints.logStream(taskId),
      autoReconnect: true,
      // 重放去重统一挂在这里：不管重连是服务端 done:reconnect 触发的，
      // 还是 token 续期后客户端自己发起的，行为都一样。
      onReconnect: () => _replayBuffer.reset(_lines),
      onEvent: (event) {
        if (!mounted) {
          return;
        }

        if (event.event == 'done') {
          if (event.data == 'reconnect') {
            // reconnect 是「任务还在跑，换条连接继续」，不是结束。
            // 以前这里一律置 _done=true，重连回来日志继续刷，
            // 页面却挂着一个「已结束」的状态。
            setState(() {
              _done = false;
              _status = '运行中';
            });
            return;
          }
          setState(() {
            _done = true;
            _status = event.data == 'finished' ? '已完成' : event.data;
          });
          return;
        }

        final newLines = _replayBuffer.consume(_splitLines(event.data));
        if (newLines.isEmpty) {
          return;
        }

        setState(() {
          _lines.addAll(newLines);
          _status = '运行中';
        });
        if (_autoScroll) {
          _scrollToBottom();
        }
      },
      onDone: () {
        if (!mounted) {
          return;
        }
        setState(() {
          _done = true;
          _status = '连接结束';
        });
      },
      onError: (error) {
        if (!mounted) {
          return;
        }
        setState(() {
          _done = true;
          // 这个 _status 挂在 AppBar 的 Chip 里，塞整句会把 actions 撑到溢出；
          // 完整的「登录已失效，请重新登录」由登录页顶部负责说，这里只给短标签。
          _status = error is SseAuthFailure ? '登录已失效' : '连接错误';
        });
      },
    );
  }

  /// 下载服务端磁盘上的原始日志文件。
  ///
  /// 与页面上这份文本的区别：页面里的内容已经按终端语义折叠过裸 `\r`，
  /// 「复制全部」拿到的也是折叠后的；原始文件是逐字节的，控制序列一个不少。
  /// 日志很大时它还能整个绕开渲染 —— 不用先把几 MB 文本铺成 TextSpan 才拿到手。
  ///
  /// 顺序是「先把字节拉完，再弹系统保存框」，**不能反过来**：
  /// 票据只活 120 秒（见 utils/raw_log_download.dart），
  /// 先让用户去保存框里挑目录的话，挑久一点票就过期了。
  Future<void> _downloadRawLog() async {
    if (_downloadingRaw) {
      return;
    }
    if (_hasRawFile != true) {
      // 短日志会被压缩后直接存进 task_logs.content，磁盘上没有独立文件。
      // 面板 Web 端的做法是把按钮置灰 + 挂 title 说明原因，但触屏上 tooltip
      // 要长按才出得来，所以这里改成「点了就直接告诉他为什么」。
      AppSnack.warn(context, '这条日志的内容存在数据库里，没有独立的原始日志文件');
      return;
    }

    setState(() => _downloadingRaw = true);
    try {
      final file = await const RawLogDownloader().downloadTaskLog(widget.logId);
      if (!mounted) {
        return;
      }
      // 系统保存框（SAF）由用户自己挑位置，不需要存储权限，也不受分区存储影响。
      // 与备份 / 脚本下载走的是同一套（backup_page、script_list_page）。
      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: '保存原始日志',
        fileName: file.filename,
        type: FileType.any,
        bytes: file.bytes,
      );
      if (!mounted) {
        return;
      }
      if (savedPath == null) {
        // 用户自己在系统保存框里按了取消，不是失败，保持中性。
        AppSnack.show(context, '已取消保存');
        return;
      }
      AppSnack.success(context, '原始日志已保存');
    } on RawLogDownloadException catch (error) {
      if (!mounted) {
        return;
      }
      // 这一支的文案已经是翻译好的中文原因（含票据过期 / 无权限 / 文件已清理）。
      AppSnack.error(context, error.message);
    } on UnsupportedError {
      // 平台能力缺失而不是这次操作出错，用警告。
      if (!mounted) {
        return;
      }
      AppSnack.warn(context, '当前平台暂不支持直接保存文件');
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppSnack.error(context, extractListErrorMessage(error, '下载原始日志失败'));
    } finally {
      if (mounted) {
        setState(() => _downloadingRaw = false);
      }
    }
  }

  List<String> _splitLines(String content) {
    final normalized = content.replaceAll('\r\n', '\n');
    final lines = normalized.split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    return lines;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
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
    final chipBackground = logTheme.brightness == Brightness.dark
        ? AppColors.slate800
        : AppColors.slate100;

    return Scaffold(
      backgroundColor: logTheme.background,
      appBar: AppBar(
        // actions 现在有 4 项（状态 chip + 复制 + 下载 + 自动滚动），窄屏上
        // 留给标题的宽度会被压得很少。加 ellipsis 让它老老实实截断。
        title: Text(
          '日志 #${widget.logId}',
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: logTheme.background,
        foregroundColor: logTheme.foreground,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Chip(
              backgroundColor: chipBackground,
              label: Text(
                _status,
                style: TextStyle(fontSize: 12, color: logTheme.foreground),
              ),
              avatar: _done
                  ? Icon(Icons.check, size: 16, color: logTheme.foreground)
                  : SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: logTheme.foreground,
                      ),
                    ),
              visualDensity: VisualDensity.compact,
            ),
          ),
          if (_lines.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.copy),
              tooltip: '复制全部',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _lines.join('\n')));
                // 这里保留原有的 2 秒，不用默认的 4 秒：复制是瞬时完成的动作，
                // 用户下一步多半立刻切到别的 App 去粘贴，提示条浮在日志正文上
                // 压满 4 秒只会挡住他刚复制的那几行。
                // 快捷方法 success() 故意不转发 duration，按 app_snack.dart 的
                // 说明，需要改停留时长时走 show(..., tone: ...)。
                AppSnack.show(
                  context,
                  '日志已复制到剪贴板',
                  tone: AppSnackTone.success,
                  duration: const Duration(seconds: 2),
                );
              },
            ),
          // 只在拿到日志详情之后才出现：在那之前既不知道有没有原始文件，
          // 也说不清楚点了会发生什么。
          if (_hasRawFile != null)
            IconButton(
              icon: _downloadingRaw
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: logTheme.foreground,
                      ),
                    )
                  : const Icon(Icons.download_outlined),
              tooltip: '下载原始日志',
              onPressed: _downloadingRaw ? null : _downloadRawLog,
            ),
          IconButton(
            icon: Icon(_autoScroll ? Icons.vertical_align_bottom : Icons.pause),
            tooltip: _autoScroll ? '自动滚动: 开' : '自动滚动: 关',
            onPressed: () {
              setState(() => _autoScroll = !_autoScroll);
              if (_autoScroll) {
                _scrollToBottom();
              }
            },
          ),
        ],
      ),
      body: Container(
        color: logTheme.background,
        child: _loading && _lines.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : _lines.isEmpty
            ? Center(
                child: Text(
                  _done ? '无日志内容' : '等待日志...',
                  style: TextStyle(color: logTheme.mutedForeground),
                ),
              )
            : Theme(
                data: Theme.of(context).copyWith(
                  textSelectionTheme: TextSelectionThemeData(
                    selectionColor: AppColors.primary.withAlpha(80),
                    selectionHandleColor: AppColors.primary,
                  ),
                ),
                child: Scrollbar(
                  controller: _scrollController,
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(12),
                    child: SelectableText.rich(
                      AnsiTextParser.buildTextSpan(
                        _lines.join('\n'),
                        baseStyle: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                          color: logTheme.foreground,
                          height: 1.5,
                        ),
                        brightness: logTheme.brightness,
                      ),
                      contextMenuBuilder: (context, editableTextState) {
                        return AdaptiveTextSelectionToolbar.editableText(
                          editableTextState: editableTextState,
                        );
                      },
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}
