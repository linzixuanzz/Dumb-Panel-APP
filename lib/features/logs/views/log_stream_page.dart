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
        title: Text('日志 #${widget.logId}'),
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
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('日志已复制到剪贴板'), duration: Duration(seconds: 2)),
                );
              },
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
