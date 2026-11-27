import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/design_tokens.dart';
import '../utils/log_background.dart';
import '../utils/log_line_buffer.dart';
import 'app_back_button.dart';
import 'app_snack.dart';
import 'log_view.dart';

/// 全屏沉浸式实时日志的四态严格语义（彻底杜绝「✓ 失败」错位图标）。
enum FullscreenLogTone {
  /// 运行中 / 实时流输出（钴蓝呼吸圆点）。
  running,

  /// 正常完成（森林绿 `✓`）。
  success,

  /// 异常退出 / 报错 / 断线（珊瑚红 `✕`）。
  failed,

  /// 已停止 / 等待 / 暂无日志等中性态（石色圆点，绝不打对勾）。
  neutral,
}

/// 注入到右上角 `⋮` 溢出菜单里的附加菜单项。
class FullscreenLogMenuEntry {
  final String id;
  final String label;
  final IconData? icon;
  final bool? checked;
  final bool enabled;
  final Future<void> Function() onTap;

  const FullscreenLogMenuEntry({
    required this.id,
    required this.label,
    this.icon,
    this.checked,
    this.enabled = true,
    required this.onTap,
  });
}

/// 方案 1 · Nordic Calm 统一无底栏全屏沉浸式日志容器。
class FullscreenLogScaffold extends StatefulWidget {
  const FullscreenLogScaffold({
    super.key,
    required this.title,
    this.subtitle,
    required this.statusLabel,
    required this.statusTone,
    required this.buffer,
    required this.loading,
    this.emptyMessage = '无日志内容',
    this.follow = true,
    this.configuredBackgroundColor,
    this.truncatedHint,
    this.truncatedActionLabel,
    this.onTruncatedAction,
    this.onStop,
    this.stopBusy = false,
    this.stopLabel = '停止运行',
    this.onRerun,
    this.rerunBusy = false,
    this.rerunLabel = '重新运行',
    this.onOpenScript,
    this.openScriptBusy = false,
    this.extraMenuEntries = const [],
    this.copySuccessToast,
  });

  final String title;
  final String? subtitle;
  final String statusLabel;
  final FullscreenLogTone statusTone;
  final LogLineBuffer buffer;
  final bool loading;
  final String emptyMessage;
  final bool follow;
  final Color? configuredBackgroundColor;
  final String? truncatedHint;
  final String? truncatedActionLabel;
  final VoidCallback? onTruncatedAction;

  final VoidCallback? onStop;
  final bool stopBusy;
  final String stopLabel;

  final VoidCallback? onRerun;
  final bool rerunBusy;
  final String rerunLabel;

  final VoidCallback? onOpenScript;
  final bool openScriptBusy;

  final List<FullscreenLogMenuEntry> extraMenuEntries;
  final String? copySuccessToast;

  @override
  State<FullscreenLogScaffold> createState() => _FullscreenLogScaffoldState();
}

class _FullscreenLogScaffoldState extends State<FullscreenLogScaffold>
    with SingleTickerProviderStateMixin {
  static final RegExp _ansiEscape = RegExp(r'\x1b\[[0-9;?]*[A-Za-z]');
  static const List<String> _errTokens = [
    'error',
    'exception',
    'traceback',
    'fatal',
    'failed',
    'timed out',
    'permission denied',
    '错误',
    '异常',
    '失败',
    '退出码 1',
  ];

  final _logController = LogViewController();
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();

  late final AnimationController _pulseController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
    value: 1.0,
  );

  bool _nightTerminal = false;
  bool _showLineNumbers = false;
  bool _softWrap = true;

  bool _searchOpen = false;
  String _searchQuery = '';
  List<int> _matchLines = const [];
  int _matchCursor = 0;
  int? _firstErrorAbsoluteLine;

  @override
  void initState() {
    super.initState();
    widget.buffer.addListener(_onBufferChanged);
    _recomputeDerivedLines();
    _loadReaderPrefs();
    _syncPulse();
  }

  @override
  void didUpdateWidget(FullscreenLogScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.buffer, widget.buffer)) {
      oldWidget.buffer.removeListener(_onBufferChanged);
      widget.buffer.addListener(_onBufferChanged);
      _recomputeDerivedLines();
    }
    if (oldWidget.statusTone != widget.statusTone) {
      _syncPulse();
    }
  }

  void _syncPulse() {
    if (widget.statusTone == FullscreenLogTone.running) {
      if (!_pulseController.isAnimating) {
        _pulseController.repeat(reverse: true);
      }
    } else {
      if (_pulseController.isAnimating) {
        _pulseController.stop();
      }
      _pulseController.value = 1.0;
    }
  }

  @override
  void dispose() {
    widget.buffer.removeListener(_onBufferChanged);
    _pulseController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadReaderPrefs() async {
    final prefs = await loadLogReaderPreferences();
    if (!mounted) return;
    setState(() {
      _nightTerminal = prefs.nightTerminal;
      _showLineNumbers = prefs.showLineNumbers;
      _softWrap = prefs.softWrap;
    });
  }

  void _onBufferChanged() {
    if (!mounted) return;
    setState(_recomputeDerivedLines);
  }

  void _recomputeDerivedLines() {
    final buf = widget.buffer;
    final dropped = buf.droppedCount;
    int? firstErr;
    final matches = <int>[];
    final q = _searchQuery.trim().toLowerCase();

    for (var i = 0; i < buf.length; i++) {
      final raw = buf.lineAt(i);
      final clean = raw.replaceAll(_ansiEscape, '');
      final lower = clean.toLowerCase();
      if (firstErr == null && !clean.trimLeft().startsWith('=== ')) {
        for (final token in _errTokens) {
          if (lower.contains(token)) {
            firstErr = dropped + i;
            break;
          }
        }
      }
      if (q.isNotEmpty && lower.contains(q) && matches.length < 500) {
        matches.add(dropped + i);
      }
    }

    _firstErrorAbsoluteLine = firstErr;
    _matchLines = matches;
    if (_matchLines.isEmpty) {
      _matchCursor = 0;
    } else if (_matchCursor >= _matchLines.length) {
      _matchCursor = _matchLines.length - 1;
    }
  }

  void _toggleSearch() {
    final next = !_searchOpen;
    setState(() {
      _searchOpen = next;
      if (!next) {
        _searchController.clear();
        _searchQuery = '';
        _recomputeDerivedLines();
      }
    });
    if (next) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocusNode.requestFocus();
      });
    }
  }

  void _onSearchChanged(String value) {
    setState(() {
      _searchQuery = value;
      _matchCursor = 0;
      _recomputeDerivedLines();
    });
    if (_matchLines.isNotEmpty) {
      _logController.jumpToAbsoluteLine(_matchLines.first);
    }
  }

  void _stepMatch(int delta) {
    if (_matchLines.isEmpty) return;
    setState(() {
      _matchCursor =
          (_matchCursor + delta + _matchLines.length) % _matchLines.length;
    });
    _logController.jumpToAbsoluteLine(_matchLines[_matchCursor]);
  }

  Future<void> _toggleNightTerminal() async {
    final next = !_nightTerminal;
    setState(() => _nightTerminal = next);
    await saveLogNightTerminalPreference(next);
  }

  Future<void> _toggleLineNumbers() async {
    final next = !_showLineNumbers;
    setState(() => _showLineNumbers = next);
    await saveLogShowLineNumbersPreference(next);
  }

  Future<void> _toggleSoftWrap() async {
    final next = !_softWrap;
    setState(() => _softWrap = next);
    await saveLogSoftWrapPreference(next);
  }

  void _copyAll() {
    if (widget.buffer.isEmpty) return;
    Clipboard.setData(ClipboardData(text: widget.buffer.joinAll()));
    final msg =
        widget.copySuccessToast ??
        (widget.buffer.droppedCount > 0
            ? '已复制最近 ${widget.buffer.length} 行'
            : '日志已复制到剪贴板');
    AppSnack.show(
      context,
      msg,
      tone: AppSnackTone.success,
      duration: const Duration(seconds: 2),
      replaceCurrent: true,
    );
  }

  void _jumpFirstError() {
    final line = _firstErrorAbsoluteLine;
    if (line == null) return;
    _logController.jumpToAbsoluteLine(line);
    AppSnack.show(
      context,
      '已定位至第 ${line + 1} 行报错输出',
      duration: const Duration(seconds: 2),
      replaceCurrent: true,
    );
  }

  Widget _buildStatusPill(LogSurfaceTheme logTheme, AppPalette logPalette) {
    final reduce = AppMotion.reduce(context);
    final (Color bg, Color fg, Widget leading) = switch (widget.statusTone) {
      FullscreenLogTone.running => (
        logPalette.tint(logPalette.accent),
        logPalette.accentInk,
        reduce
            ? Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: logPalette.accent,
                  shape: BoxShape.circle,
                ),
              )
            : FadeTransition(
                opacity: Tween<double>(begin: 0.35, end: 1.0).animate(
                  CurvedAnimation(
                    parent: _pulseController,
                    curve: Curves.easeInOut,
                  ),
                ),
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: logPalette.accent,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
      ),
      FullscreenLogTone.success => (
        logPalette.tint(logPalette.ok),
        logPalette.okInk,
        Icon(Icons.check_rounded, size: 14, color: logPalette.okInk),
      ),
      FullscreenLogTone.failed => (
        logPalette.tint(logPalette.err),
        logPalette.errInk,
        Icon(Icons.close_rounded, size: 14, color: logPalette.errInk),
      ),
      FullscreenLogTone.neutral => (
        logPalette.fill,
        logTheme.mutedForeground,
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: logTheme.mutedForeground,
            shape: BoxShape.circle,
          ),
        ),
      ),
    };

    return Container(
      key: const Key('fullscreen-log-status-pill'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          leading,
          const SizedBox(width: 5),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 96),
            child: Text(
              widget.statusLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: fg,
              ),
            ),
          ),
        ],
      ),
    );
  }

  PopupMenuItem<String> _buildToggleMenuItem({
    required String value,
    required IconData icon,
    required String label,
    required bool active,
    required AppPalette palette,
  }) {
    return PopupMenuItem<String>(
      value: value,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        leading: Icon(icon, size: 19),
        title: Text(label),
        trailing: active
            ? Icon(Icons.check_rounded, size: 18, color: palette.accent)
            : null,
      ),
    );
  }

  Widget _buildHeader(LogSurfaceTheme logTheme, AppPalette logPalette) {
    final palette = context.palette;
    final lineCount = widget.buffer.totalCount;
    final subParts = <String>[
      if (widget.subtitle != null && widget.subtitle!.trim().isNotEmpty)
        widget.subtitle!.trim(),
      if (lineCount > 0) '$lineCount 行',
    ];
    final effectiveSub = subParts.join(' · ');

    return Container(
      constraints: const BoxConstraints(minHeight: 54),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: BoxDecoration(
        color: logTheme.barBackground,
        border: Border(bottom: BorderSide(color: logTheme.divider, width: 0.5)),
      ),
      child: Row(
        children: [
          AppBackButton(color: logTheme.foreground),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: logTheme.foreground,
                    letterSpacing: -0.15,
                  ),
                ),
                if (effectiveSub.isNotEmpty)
                  Text(
                    effectiveSub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.tabular(
                      TextStyle(fontSize: 11.5, color: logTheme.mutedForeground),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          _buildStatusPill(logTheme, logPalette),
          SizedBox(
            width: 36,
            height: AppTapTarget.min,
            child: IconButton(
              padding: EdgeInsets.zero,
              tooltip: '页内搜索',
              icon: Icon(
                _searchOpen ? Icons.search_off_rounded : Icons.search_rounded,
                size: 19,
                color: _searchOpen ? logPalette.accent : logTheme.foreground,
              ),
              onPressed: _toggleSearch,
            ),
          ),
          SizedBox(
            width: 36,
            height: AppTapTarget.min,
            child: IconButton(
              padding: EdgeInsets.zero,
              tooltip: _nightTerminal ? '恢复默认日志底色' : '切换护眼暗底终端',
              icon: Icon(
                logTheme.isDark
                    ? Icons.light_mode_outlined
                    : Icons.dark_mode_outlined,
                size: 18,
                color: _nightTerminal ? logPalette.accent : logTheme.foreground,
              ),
              onPressed: _toggleNightTerminal,
            ),
          ),
          PopupMenuButton<String>(
            tooltip: '更多选项',
            icon: Icon(
              Icons.more_vert,
              size: 19,
              color: logTheme.foreground,
            ),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(
              minWidth: 36,
              minHeight: AppTapTarget.min,
            ),
            itemBuilder: (_) => [
              _buildToggleMenuItem(
                value: '_wrap',
                icon: Icons.wrap_text_rounded,
                label: '自动换行',
                active: _softWrap,
                palette: palette,
              ),
              _buildToggleMenuItem(
                value: '_lines',
                icon: Icons.format_list_numbered_rounded,
                label: '显示行号',
                active: _showLineNumbers,
                palette: palette,
              ),
              _buildToggleMenuItem(
                value: '_night',
                icon: Icons.dark_mode_outlined,
                label: '独立护眼暗底 (#14161A)',
                active: _nightTerminal,
                palette: palette,
              ),
              if (widget.buffer.isNotEmpty)
                PopupMenuItem<String>(
                  value: '_copy',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: const Icon(Icons.copy_rounded, size: 19),
                    title: Text(
                      widget.buffer.droppedCount > 0
                          ? '复制最近 ${widget.buffer.length} 行'
                          : '复制全部',
                    ),
                  ),
                ),
              if (widget.extraMenuEntries.isNotEmpty) const PopupMenuDivider(),
              for (final item in widget.extraMenuEntries)
                if (item.checked != null)
                  CheckedPopupMenuItem<String>(
                    value: item.id,
                    enabled: item.enabled,
                    checked: item.checked!,
                    child: Text(item.label),
                  )
                else
                  PopupMenuItem<String>(
                    value: item.id,
                    enabled: item.enabled,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: item.icon == null
                          ? null
                          : Icon(item.icon, size: 19),
                      title: Text(item.label),
                    ),
                  ),
            ],
            onSelected: (value) async {
              switch (value) {
                case '_wrap':
                  await _toggleSoftWrap();
                case '_lines':
                  await _toggleLineNumbers();
                case '_night':
                  await _toggleNightTerminal();
                case '_copy':
                  _copyAll();
                default:
                  for (final item in widget.extraMenuEntries) {
                    if (item.id == value) {
                      await item.onTap();
                      break;
                    }
                  }
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(LogSurfaceTheme logTheme, AppPalette logPalette) {
    final hasQuery = _searchQuery.trim().isNotEmpty;
    final countLabel = !hasQuery
        ? ''
        : _matchLines.isEmpty
        ? '无匹配'
        : '${_matchCursor + 1}/${_matchLines.length}';

    return Container(
      constraints: const BoxConstraints(minHeight: 46),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: logTheme.barBackground,
        border: Border(bottom: BorderSide(color: logTheme.divider, width: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: logPalette.fill,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.search_rounded,
                    size: 16,
                    color: logTheme.mutedForeground,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      focusNode: _searchFocusNode,
                      onChanged: _onSearchChanged,
                      style: TextStyle(
                        fontSize: 13,
                        color: logTheme.foreground,
                      ),
                      decoration: InputDecoration(
                        hintText: '在全屏日志中搜索关键字...',
                        hintStyle: TextStyle(
                          fontSize: 13,
                          color: logTheme.mutedForeground,
                        ),
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                  if (countLabel.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Text(
                        countLabel,
                        style: AppText.tabular(
                          TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w500,
                            color: _matchLines.isEmpty
                                ? logPalette.errInk
                                : logTheme.mutedForeground,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '上一处匹配',
            icon: Icon(
              Icons.keyboard_arrow_up_rounded,
              size: 20,
              color: _matchLines.isEmpty
                  ? logTheme.mutedForeground.withAlpha(90)
                  : logTheme.foreground,
            ),
            onPressed: _matchLines.isEmpty ? null : () => _stepMatch(-1),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '下一处匹配',
            icon: Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 20,
              color: _matchLines.isEmpty
                  ? logTheme.mutedForeground.withAlpha(90)
                  : logTheme.foreground,
            ),
            onPressed: _matchLines.isEmpty ? null : () => _stepMatch(1),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '关闭搜索',
            icon: Icon(
              Icons.close_rounded,
              size: 18,
              color: logTheme.mutedForeground,
            ),
            onPressed: _toggleSearch,
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(LogSurfaceTheme logTheme, AppPalette logPalette) {
    final showStop = widget.onStop != null;
    final showRerun = !showStop && widget.onRerun != null;
    final showFirstError = _firstErrorAbsoluteLine != null;
    final hasAnyFooterAction =
        showStop ||
        showRerun ||
        showFirstError ||
        widget.buffer.isNotEmpty ||
        widget.onOpenScript != null;

    if (!hasAnyFooterAction) {
      return const SizedBox.shrink();
    }

    return Container(
      decoration: BoxDecoration(
        color: logTheme.barBackground,
        border: Border(top: BorderSide(color: logTheme.divider, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            children: [
              if (showStop)
                _PrimaryThumbButton(
                  key: const Key('fullscreen-log-stop'),
                  label: widget.stopLabel,
                  icon: Icons.stop_rounded,
                  bg: logPalette.tint(logPalette.err),
                  fg: logPalette.errInk,
                  busy: widget.stopBusy,
                  onTap: widget.onStop,
                )
              else if (showRerun)
                _PrimaryThumbButton(
                  key: const Key('fullscreen-log-rerun'),
                  label: widget.rerunLabel,
                  icon: Icons.play_arrow_rounded,
                  bg: logPalette.primaryBtnBg,
                  fg: logPalette.primaryBtnFg,
                  busy: widget.rerunBusy,
                  onTap: widget.onRerun,
                ),
              const Spacer(),
              Flexible(
                flex: 3,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (showFirstError) ...[
                        _UtilityThumbChip(
                          key: const Key('fullscreen-log-first-error'),
                          label: '首处报错',
                          icon: Icons.vertical_align_top_rounded,
                          fg: logPalette.errInk,
                          bg: logPalette.tint(logPalette.err),
                          onTap: _jumpFirstError,
                        ),
                        const SizedBox(width: 8),
                      ],
                      if (widget.buffer.isNotEmpty)
                        _UtilityThumbChip(
                          key: const Key('fullscreen-log-copy'),
                          label: '复制全部',
                          icon: Icons.copy_rounded,
                          fg: logTheme.foreground,
                          bg: logPalette.fill,
                          onTap: _copyAll,
                        ),
                      if (widget.onOpenScript != null) ...[
                        const SizedBox(width: 8),
                        _UtilityThumbChip(
                          key: const Key('fullscreen-log-open-script'),
                          label: '跳脚本',
                          icon: Icons.code_rounded,
                          fg: logTheme.foreground,
                          bg: logPalette.fill,
                          onTap: widget.openScriptBusy
                              ? null
                              : widget.onOpenScript,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final logTheme = resolveLogSurfaceTheme(
      widget.configuredBackgroundColor,
      themeBrightness: Theme.of(context).brightness,
      forceNightTerminal: _nightTerminal,
    );
    final logPalette = logTheme.isDark ? AppPalette.dark : AppPalette.light;
    final activeMatchLine =
        _matchLines.isNotEmpty && _matchCursor < _matchLines.length
        ? _matchLines[_matchCursor]
        : null;

    final overlayStyle = logTheme.isDark
        ? SystemUiOverlayStyle.light
        : SystemUiOverlayStyle.dark;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: Scaffold(
        backgroundColor: logTheme.background,
        body: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(logTheme, logPalette),
              if (_searchOpen) _buildSearchBar(logTheme, logPalette),
              Expanded(
                child: ColoredBox(
                  color: logTheme.background,
                  child: widget.loading && widget.buffer.isEmpty
                      ? Center(
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: logPalette.accent,
                          ),
                        )
                      : widget.buffer.isEmpty
                      ? Center(
                          child: Text(
                            widget.emptyMessage,
                            style: TextStyle(
                              fontSize: 13.5,
                              color: logTheme.mutedForeground,
                            ),
                          ),
                        )
                      : LogView(
                          controller: _logController,
                          buffer: widget.buffer,
                          follow: widget.follow,
                          showLineNumbers: _showLineNumbers,
                          softWrap: _softWrap,
                          searchQuery: _searchQuery,
                          activeMatchAbsoluteLine: activeMatchLine,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          textStyle: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12.5,
                            height: 1.58,
                            color: logTheme.foreground,
                          ),
                          brightness: logTheme.brightness,
                          mutedColor: logTheme.mutedForeground,
                          truncatedHint: widget.truncatedHint,
                          truncatedActionLabel: widget.truncatedActionLabel,
                          onTruncatedAction: widget.onTruncatedAction,
                        ),
                ),
              ),
              _buildFooter(logTheme, logPalette),
            ],
          ),
        ),
      ),
    );
  }
}

class _PrimaryThumbButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color bg;
  final Color fg;
  final bool busy;
  final VoidCallback? onTap;

  const _PrimaryThumbButton({
    super.key,
    required this.label,
    required this.icon,
    required this.bg,
    required this.fg,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        onTap: busy ? null : onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 38),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (busy)
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: fg,
                    ),
                  )
                else
                  Icon(icon, size: 16, color: fg),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UtilityThumbChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color fg;
  final Color bg;
  final VoidCallback? onTap;

  const _UtilityThumbChip({
    super.key,
    required this.label,
    required this.icon,
    required this.fg,
    required this.bg,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 38),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 15, color: fg),
                  const SizedBox(width: 5),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: fg,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
