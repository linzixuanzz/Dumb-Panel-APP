import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/network/sse_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/models/task.dart';
import '../../../shared/models/task_log.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/utils/ansi_text.dart';
import '../../../shared/utils/log_background.dart';
import '../../../shared/utils/sse_replay_buffer.dart';
import '../../../shared/utils/task_command.dart';
import '../../../shared/widgets/app_snack.dart';
import '../../tasks/providers/task_provider.dart';
import '../utils/raw_log_download.dart';
import '../utils/task_command_lookup.dart';

/// AppBar 溢出菜单里的动作。
enum _LogStreamAction { copyAll, downloadRaw, openScript }

class LogStreamPage extends ConsumerStatefulWidget {
  final int logId;

  const LogStreamPage({super.key, required this.logId});

  @override
  ConsumerState<LogStreamPage> createState() => _LogStreamPageState();
}

class _LogStreamPageState extends ConsumerState<LogStreamPage> {
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

  /// 这条日志对应任务的名字与命令，只服务「编辑对应脚本」。
  ///
  /// [_command] 允许一直是 null —— 老面板的日志详情不返回它，那时靠
  /// [_resolveCommand] 在**点击那一刻**去任务列表兜底，拿到后回填这里，
  /// 免得同一个页面点两次就请求两次。
  String? _taskName;
  String? _command;
  bool _resolvingScript = false;

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
        _taskName = log.taskName;
        // 面板 v3.2.0 起才在日志详情里带 command；拿不到就保持 null，
        // 由「编辑对应脚本」点击时的兜底查询补。这里**不预取任务列表**：
        // 日志详情是高频入口，为一个可能没人点的菜单项多打一发全量请求
        // 会直接拖慢首屏。
        _command = log.command;
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

  void _copyAll() {
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
  }

  /// 跳到这条日志对应任务所执行的脚本编辑页。
  ///
  /// 复用现成的 `/scripts/view` 深链（`state.extra` 就是脚本路径，ScriptViewPage
  /// 自己会 loadContent），不新增路由。
  ///
  /// 降级是逐级的，每一级都要说清楚原因 —— 本页 `_downloadRawLog` 已经确立了
  /// 「点了就直接告诉他为什么」的基调，不静默失败。
  Future<void> _openScriptEditor() async {
    if (_resolvingScript) {
      return;
    }
    final taskId = _taskId;
    if (taskId == null) {
      return;
    }

    final command = await _resolveCommand(taskId);
    if (!mounted) {
      return;
    }
    if (command == null) {
      AppSnack.warn(context, '未能获取任务命令，无法定位脚本');
      return;
    }

    final scriptPath = extractScriptPathFromCommand(command);
    if (scriptPath == null) {
      // curl / 内联 shell / 不认识的入口命令都会走到这里。解析器故意判得窄
      // （它同时是「删除任务时顺带删脚本」的依据），宁可让用户自己去脚本页找。
      AppSnack.warn(context, '该任务不是脚本任务，命令里没有可打开的脚本文件');
      return;
    }

    context.push('/scripts/view', extra: scriptPath);
  }

  /// 拿到任务命令：日志详情自带 > 任务列表内存缓存 > 现查任务列表。
  ///
  /// 三级都拿不到时返回 null。中间那级是白捡的：taskProvider 不是
  /// autoDispose，用户只要进过任务页，全量列表就还在内存里。
  Future<String?> _resolveCommand(int taskId) async {
    final cached = _command;
    if (cached != null) {
      return cached;
    }

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
      // 兜底查询本身失败（断网 / 面板 5xx）与「面板里查不到这条任务」
      // 对用户是同一件事：定位不了脚本。文案由调用方统一给。
      return null;
    } finally {
      if (mounted) {
        setState(() => _resolvingScript = false);
      }
    }
  }

  /// 老面板兜底：日志详情不给 command 时，去任务列表把它捞回来。
  ///
  /// `all=1` 是一次性全量（面板侧上限 5000 条），所以必须带 `keyword` 收窄；
  /// 任务名为空时才退回真正的全量。角色门槛与日志详情同为 viewer，
  /// 不会因为这一发请求多出权限问题。
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
    final logTheme = resolveLogSurfaceTheme(
      _logBackgroundColor,
      themeBrightness: Theme.of(context).brightness,
    );
    final chipBackground = logTheme.brightness == Brightness.dark
        ? AppColors.slate800
        : AppColors.slate100;

    // 「编辑对应脚本」的两道门禁：
    // 1. `_taskId == null` 说明日志详情还没到手，这时连要跳哪个任务都不知道
    //    （与下面 `_hasRawFile != null` 同一个思路）；
    // 2. `/api/scripts/*` 在面板侧要 operator，而日志只要 viewer。viewer 点进去
    //    只会在编辑器里吃一个 403，不如直接不给这个入口。
    final user = ref.watch(authProvider).user;
    final canOpenScript = _taskId != null && (user?.isOperator ?? false);
    final hasMenuActions =
        _lines.isNotEmpty || _hasRawFile != null || canOpenScript;
    final menuBusy = _downloadingRaw || _resolvingScript;

    return Scaffold(
      backgroundColor: logTheme.background,
      appBar: AppBar(
        // actions 现在是 3 项（状态 chip + 自动滚动 + 溢出菜单）。复制 / 下载 /
        // 编辑脚本全折进溢出菜单，就是为了不让它继续往上涨：曾经的 4 个图标在
        // 窄屏上已经把标题压到要截断，再直接加第 5 个就会撑溢出。
        // ellipsis 保留 —— 状态 chip 的文案本身也会变长。
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
          // 三项全被门禁挡掉时（日志详情没加载出来、又不是 operator）整个按钮
          // 都不出现 —— 留一个点开是空的菜单比没有按钮更让人困惑。
          if (hasMenuActions)
            PopupMenuButton<_LogStreamAction>(
              // 有请求在飞时原地转圈：下载 / 兜底查询都可能要几秒，折进菜单之后
              // 没了那个 IconButton 的位置，进度反馈只能挂在这里。
              //
              // ⚠️ 这个 spinner **只是反馈，不兼任锁**。菜单整体绝不能 disable：
              // 原始日志有几十 MB 时，下载要先把字节整个拉完才弹保存框（见
              // _downloadRawLog 的注释），这期间用户多半正想复制屏幕上的报错行
              // 去搜索。把整个菜单锁死会让「复制全部」跟着一起点不开，
              // 而它在折进菜单之前是个从不受 busy 影响的独立按钮。
              // 门禁按项挂在下面各自的 enabled 上。
              icon: menuBusy
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: logTheme.foreground,
                      ),
                    )
                  : const Icon(Icons.more_vert),
              tooltip: '更多操作',
              itemBuilder: (_) => [
                // 复制是纯本地、瞬时完成的，不受任何在飞的请求影响，
                // 所以这一项**永远可点**（下载几十 MB 原始日志时尤其需要它）。
                if (_lines.isNotEmpty)
                  const PopupMenuItem(
                    value: _LogStreamAction.copyAll,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.copy, size: 20),
                      title: Text('复制全部'),
                    ),
                  ),
                // 只在拿到日志详情之后才出现：在那之前既不知道有没有原始文件，
                // 也说不清楚点了会发生什么。
                if (_hasRawFile != null)
                  PopupMenuItem(
                    value: _LogStreamAction.downloadRaw,
                    // 只锁自己：重复点会重复发票据请求。
                    enabled: !_downloadingRaw,
                    child: const ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.download_outlined, size: 20),
                      title: Text('下载原始日志'),
                    ),
                  ),
                if (canOpenScript)
                  PopupMenuItem(
                    value: _LogStreamAction.openScript,
                    // 同上，只锁自己：兜底查任务列表期间别再打一发。
                    enabled: !_resolvingScript,
                    child: const ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.code, size: 20),
                      title: Text('编辑对应脚本'),
                    ),
                  ),
              ],
              onSelected: (action) async {
                switch (action) {
                  case _LogStreamAction.copyAll:
                    _copyAll();
                    break;
                  case _LogStreamAction.downloadRaw:
                    await _downloadRawLog();
                    break;
                  case _LogStreamAction.openScript:
                    await _openScriptEditor();
                    break;
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
