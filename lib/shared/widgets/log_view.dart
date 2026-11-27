import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/design_tokens.dart';
import '../utils/ansi_text.dart';
import '../utils/log_line_buffer.dart';

/// 距底部多少像素以内算「停在底部」。
const double kLogFollowTolerance = 32;

/// 回到底部时，锚点下方只放最后这么多行；跟随期间锚点也随尾部滑动。
const int _kTailWindow = 200;

/// 供全屏日志容器按绝对行号跳转（如页内搜索上下跳转、「↑ 首处报错」一键定位）。
class LogViewController {
  _LogViewState? _state;

  void _attach(_LogViewState state) => _state = state;

  void _detach(_LogViewState state) {
    if (identical(_state, state)) {
      _state = null;
    }
  }

  /// 立即跳转到指定的绝对行号（`buffer.droppedCount .. buffer.totalCount - 1`），
  /// 并将该行置于视口靠上位置，同时暂停自动贴底跟随以便用户阅读上下文。
  void jumpToAbsoluteLine(int absoluteLine) {
    _state?._jumpToAbsoluteLine(absoluteLine);
  }

  /// 恢复到底部跟随。
  void jumpToLatest() {
    _state?._jumpToLatest();
  }
}

/// 日志正文视图：双 Sliver 尾窗懒渲染、贴底自动跟随、上翻暂停并统计新增行数、
/// 支持页内关键字高亮定位、可选行号与自动换行。
class LogView extends StatefulWidget {
  const LogView({
    super.key,
    required this.buffer,
    required this.textStyle,
    required this.brightness,
    this.controller,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    this.follow = true,
    this.showLineNumbers = false,
    this.softWrap = true,
    this.searchQuery = '',
    this.activeMatchAbsoluteLine,
    this.mutedColor,
    this.truncatedHint,
    this.truncatedActionLabel,
    this.onTruncatedAction,
  });

  final LogLineBuffer buffer;
  final TextStyle textStyle;
  final Brightness brightness;
  final LogViewController? controller;
  final EdgeInsets padding;
  final bool follow;

  /// 是否显示左侧等宽行号栏（不参与长按选词复制）。
  final bool showLineNumbers;

  /// 是否自动软换行。
  final bool softWrap;

  /// 页内关键字高亮词（大小写不敏感）。
  final String searchQuery;

  /// 当前选中的搜索命中所在绝对行号（以强高亮色标识）。
  final int? activeMatchAbsoluteLine;

  final Color? mutedColor;
  final String? truncatedHint;
  final String? truncatedActionLabel;
  final VoidCallback? onTruncatedAction;

  @override
  State<LogView> createState() => _LogViewState();
}

class _LogViewState extends State<LogView> {
  final _controller = ScrollController();

  int _anchor = 0;
  bool _centered = false;
  int _sliverGeneration = 0;
  int _bufferGeneration = 0;
  bool _glued = false;

  bool _following = true;
  bool _userScrolling = false;
  bool _stickScheduled = false;
  bool _hasSelection = false;

  /// 暂停跟随时记录的 `buffer.totalCount`，用于悬浮胶囊实时提示「新增 N 行」。
  int _pausedAtTotalCount = 0;

  final _selectionAreaKey = GlobalKey<SelectionAreaState>();

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
    _following = widget.follow;
    _pausedAtTotalCount = widget.buffer.totalCount;
    _bufferGeneration = widget.buffer.generation;
    widget.buffer.addListener(_handleBufferChanged);
    _resetAnchor();
    if (_following) {
      _stickAfterFrame();
    }
  }

  @override
  void didUpdateWidget(LogView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
    if (!identical(oldWidget.buffer, widget.buffer)) {
      oldWidget.buffer.removeListener(_handleBufferChanged);
      oldWidget.buffer.holdTrim = false;
      widget.buffer.addListener(_handleBufferChanged);
      _bufferGeneration = widget.buffer.generation;
      _following = widget.follow;
      _pausedAtTotalCount = widget.buffer.totalCount;
      _resetAnchor();
      _sliverGeneration++;
      if (_following) {
        _stickAfterFrame();
      }
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    widget.buffer.removeListener(_handleBufferChanged);
    widget.buffer.holdTrim = false;
    _controller.dispose();
    super.dispose();
  }

  void _resetAnchor() {
    final buffer = widget.buffer;
    if (!widget.follow) {
      _anchor = buffer.droppedCount;
      _centered = false;
      return;
    }
    _anchor = math.max(buffer.droppedCount, buffer.totalCount - _kTailWindow);
    _centered = _anchor > buffer.droppedCount;
    _glued = true;
  }

  void _handleBufferChanged() {
    final buffer = widget.buffer;
    if (buffer.generation != _bufferGeneration) {
      _bufferGeneration = buffer.generation;
      _pausedAtTotalCount = buffer.totalCount;
      if (_following) {
        _jumpToLatest();
        return;
      }
      _anchor = _anchor.clamp(buffer.droppedCount, buffer.totalCount);
    }
    if (_following && !_userScrolling && !_hasSelection) {
      final next = math.max(
        buffer.droppedCount,
        buffer.totalCount - _kTailWindow,
      );
      if (!_glued || (next > buffer.droppedCount) != _centered) {
        _jumpToLatest();
        return;
      }
      _anchor = next;
    }
    setState(() {});
    if (_following) {
      _stickAfterFrame();
    }
  }

  /// 按绝对行号 O(1) 重建锚点并滚至目标行（不遍历中间数千行）。
  void _jumpToAbsoluteLine(int targetAbsolute) {
    final buffer = widget.buffer;
    if (buffer.isEmpty) return;
    final clamped = targetAbsolute.clamp(
      buffer.droppedCount,
      buffer.totalCount - 1,
    );
    if (_hasSelection) {
      _hasSelection = false;
      _selectionAreaKey.currentState?.selectableRegion.clearSelection();
    }
    final nextAnchor = math.max(buffer.droppedCount, clamped - 2);
    setState(() {
      _anchor = nextAnchor;
      _centered = _anchor > buffer.droppedCount;
      _glued = false;
      _sliverGeneration++;
      if (widget.follow) {
        if (_following) {
          _pausedAtTotalCount = buffer.totalCount;
        }
        _following = false;
        buffer.holdTrim = true;
      }
    });
    if (_controller.hasClients) {
      _controller.position.jumpTo(0);
    }
  }

  void _jumpToLatest() {
    if (_hasSelection) {
      _hasSelection = false;
      widget.buffer.holdTrim = !_following;
      _selectionAreaKey.currentState?.selectableRegion.clearSelection();
    }
    setState(() {
      _resetAnchor();
      _pausedAtTotalCount = widget.buffer.totalCount;
      _sliverGeneration++;
    });
    _setFollowing(true);
    if (_controller.hasClients) {
      final position = _controller.position;
      final tailLines = widget.buffer.totalCount - _anchor;
      final lineExtent =
          MediaQuery.textScalerOf(
            context,
          ).scale(widget.textStyle.fontSize ?? 14) *
          (widget.textStyle.height ?? 1.0);
      final leading = _centered ? 0.0 : widget.padding.top;
      final estimate =
          leading +
          tailLines * lineExtent +
          widget.padding.bottom -
          position.viewportDimension;
      position.jumpTo(math.max(0.0, estimate));
    }
    _stickAfterFrame();
  }

  void _setFollowing(bool value) {
    if (_following == value) {
      return;
    }
    _following = value;
    if (!value) {
      _glued = false;
      _pausedAtTotalCount = widget.buffer.totalCount;
    }
    widget.buffer.holdTrim = !value || _hasSelection;
    _rebuildSoon();
  }

  void _handleSelectionChanged(SelectedContent? content) {
    final hasSelection = content != null && content.plainText.isNotEmpty;
    if (!mounted || hasSelection == _hasSelection) {
      return;
    }
    _hasSelection = hasSelection;
    widget.buffer.holdTrim = !_following || hasSelection;
    if (!hasSelection) {
      if (_following && !_userScrolling) {
        final buffer = widget.buffer;
        final anchor = _anchor.clamp(buffer.droppedCount, buffer.totalCount);
        if (buffer.totalCount - anchor > _kTailWindow) {
          if (SchedulerBinding.instance.schedulerPhase ==
              SchedulerPhase.persistentCallbacks) {
            SchedulerBinding.instance.addPostFrameCallback((_) {
              if (mounted && _following && !_userScrolling && !_hasSelection) {
                _jumpToLatest();
              }
            });
          } else {
            _jumpToLatest();
          }
          return;
        }
      }
      _resumeAfterPause();
    }
  }

  void _resumeAfterPause() {
    if (!_following || _userScrolling || _hasSelection) {
      return;
    }
    final buffer = widget.buffer;
    final anchor = _anchor.clamp(buffer.droppedCount, buffer.totalCount);
    if (buffer.totalCount - anchor > _kTailWindow) {
      _glued = false;
    }
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_following || _userScrolling || _hasSelection) {
        return;
      }
      _stickToBottom();
    });
  }

  void _rebuildSoon() {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
      return;
    }
    if (mounted) setState(() {});
  }

  void _stickAfterFrame() {
    if (_stickScheduled) {
      return;
    }
    _stickScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _stickScheduled = false;
      _stickToBottom();
    });
  }

  void _stickToBottom() {
    if (!mounted ||
        !_following ||
        _userScrolling ||
        _hasSelection ||
        !_controller.hasClients) {
      return;
    }
    final position = _controller.position;
    if (position.maxScrollExtent - position.pixels > 0.5) {
      position.jumpTo(position.maxScrollExtent);
    }
  }

  bool _isAtBottom(ScrollMetrics metrics) =>
      metrics.maxScrollExtent - metrics.pixels <= kLogFollowTolerance;

  bool _handleScrollNotification(ScrollNotification notification) {
    if (!widget.follow || notification.depth != 0) {
      return false;
    }
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _userScrolling = true;
    } else if (notification is UserScrollNotification &&
        notification.direction != ScrollDirection.idle) {
      _userScrolling = true;
    } else if (notification is ScrollUpdateNotification && _userScrolling) {
      _setFollowing(_isAtBottom(notification.metrics));
    } else if (notification is ScrollEndNotification && _userScrolling) {
      _userScrolling = false;
      _setFollowing(_isAtBottom(notification.metrics));
      _resumeAfterPause();
    }
    return false;
  }

  bool _handleMetricsNotification(ScrollMetricsNotification notification) {
    if (widget.follow && notification.depth == 0) {
      _stickToBottom();
    }
    return false;
  }

  /// 在保持 ANSI 着色的前提下叠加关键字搜索高亮。
  TextSpan _highlightSpan(TextSpan source, String query, Color bgColor) {
    final lowerQuery = query.toLowerCase();
    if (lowerQuery.isEmpty) return source;

    List<InlineSpan> processSpan(TextSpan span, TextStyle? inherited) {
      final effectiveStyle = inherited?.merge(span.style) ?? span.style;
      final out = <InlineSpan>[];
      final text = span.text;
      if (text != null && text.isNotEmpty) {
        final lower = text.toLowerCase();
        var cursor = 0;
        while (true) {
          final hit = lower.indexOf(lowerQuery, cursor);
          if (hit < 0) {
            if (cursor < text.length) {
              out.add(
                TextSpan(text: text.substring(cursor), style: effectiveStyle),
              );
            }
            break;
          }
          if (hit > cursor) {
            out.add(
              TextSpan(
                text: text.substring(cursor, hit),
                style: effectiveStyle,
              ),
            );
          }
          out.add(
            TextSpan(
              text: text.substring(hit, hit + lowerQuery.length),
              style: (effectiveStyle ?? const TextStyle()).copyWith(
                backgroundColor: bgColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          );
          cursor = hit + lowerQuery.length;
        }
      }
      final children = span.children;
      if (children != null) {
        for (final child in children) {
          if (child is TextSpan) {
            out.addAll(processSpan(child, effectiveStyle));
          } else {
            out.add(child);
          }
        }
      }
      return out;
    }

    return TextSpan(children: processSpan(source, null));
  }

  Widget _buildLine(int absolute) {
    final buffer = widget.buffer;
    final index = absolute - buffer.droppedCount;
    if (index < 0 || index >= buffer.length) {
      return const SizedBox.shrink();
    }
    final rawLine = buffer.lineAt(index);
    var span = AnsiTextParser.buildTextSpan(
      rawLine,
      baseStyle: widget.textStyle,
      brightness: widget.brightness,
      start: buffer.ansiStateAt(index),
    );

    final query = widget.searchQuery.trim();
    final isActiveMatch = widget.activeMatchAbsoluteLine == absolute;
    if (query.isNotEmpty) {
      span = _highlightSpan(
        span,
        query,
        isActiveMatch ? AppColors.searchMatchCurrent : AppColors.searchMatch,
      );
    }

    Widget lineText = Text.rich(
      span,
      softWrap: widget.softWrap,
      overflow: widget.softWrap ? TextOverflow.clip : TextOverflow.visible,
    );
    if (!widget.softWrap) {
      lineText = SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const ClampingScrollPhysics(),
        child: lineText,
      );
    }

    if (!widget.showLineNumbers) {
      if (!isActiveMatch) return lineText;
      return ColoredBox(
        color: AppColors.searchMatch.withAlpha(28),
        child: lineText,
      );
    }

    final digits = math.max(3, buffer.totalCount.toString().length);
    final gutterWidth = digits * 8.5 + 10;
    final gutterColor =
        widget.mutedColor?.withAlpha(150) ??
        widget.textStyle.color?.withAlpha(110) ??
        context.palette.text3;

    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectionContainer.disabled(
          child: SizedBox(
            width: gutterWidth,
            child: Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Text(
                '${absolute + 1}',
                textAlign: TextAlign.right,
                style: AppText.tabular(
                  widget.textStyle.copyWith(
                    color: gutterColor,
                    fontSize: (widget.textStyle.fontSize ?? 12.5) - 1,
                  ),
                ),
              ),
            ),
          ),
        ),
        Expanded(child: lineText),
      ],
    );

    if (!isActiveMatch) return row;
    return ColoredBox(
      color: AppColors.searchMatch.withAlpha(28),
      child: row,
    );
  }

  SliverChildBuilderDelegate _lineDelegate(
    int count,
    int Function(int index) absoluteOf,
  ) {
    return SliverChildBuilderDelegate(
      (context, index) => _buildLine(absoluteOf(index)),
      childCount: count,
      addAutomaticKeepAlives: false,
    );
  }

  Widget _buildTruncatedNotice(int dropped) {
    final muted =
        widget.mutedColor ??
        widget.textStyle.color?.withAlpha(170) ??
        context.palette.text2;
    final label = widget.truncatedActionLabel;
    final action = widget.onTruncatedAction;
    final hint = widget.truncatedHint;
    return SelectionContainer.disabled(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          children: [
            Text(
              '日志过长，仅显示最近 ${widget.buffer.length} 行，'
              '更早的 $dropped 行未显示${hint == null ? '' : '。$hint'}',
              style: TextStyle(fontSize: 12, height: 1.5, color: muted),
            ),
            if (label != null && action != null)
              TextButton(
                onPressed: action,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: Text(label),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFollowPill(BuildContext context) {
    final palette = context.palette;
    final unread = math.max(0, widget.buffer.totalCount - _pausedAtTotalCount);
    final text = unread > 0 ? '恢复跟随 · 新增 $unread 行' : '恢复跟随';
    return Tooltip(
      message: '回到底部',
      child: Material(
        color: palette.primaryBtnBg,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        elevation: 3,
        shadowColor: const Color(0x33000000),
        child: InkWell(
          onTap: _jumpToLatest,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.arrow_downward_rounded,
                  size: 15,
                  color: palette.primaryBtnFg,
                ),
                const SizedBox(width: 6),
                Text(
                  text,
                  style: AppText.tabular(
                    TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: palette.primaryBtnFg,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final buffer = widget.buffer;
    final dropped = buffer.droppedCount;
    final total = buffer.totalCount;
    final anchor = widget.follow ? _anchor.clamp(dropped, total) : dropped;
    final centered = widget.follow && _centered;
    final horizontal = EdgeInsets.only(
      left: widget.padding.left,
      right: widget.padding.right,
    );
    final belowKey = ValueKey<String>('log-below-$_sliverGeneration');

    final slivers = <Widget>[
      SliverToBoxAdapter(child: SizedBox(height: widget.padding.top)),
      if (dropped > 0)
        SliverPadding(
          padding: horizontal,
          sliver: SliverToBoxAdapter(child: _buildTruncatedNotice(dropped)),
        ),
      if (centered)
        SliverPadding(
          key: ValueKey<String>('log-above-$_sliverGeneration'),
          padding: horizontal,
          sliver: SliverList(
            delegate: _lineDelegate(anchor - dropped, (i) => anchor - 1 - i),
          ),
        ),
      SliverPadding(
        key: belowKey,
        padding: horizontal,
        sliver: SliverList(
          delegate: _lineDelegate(total - anchor, (i) => anchor + i),
        ),
      ),
      SliverToBoxAdapter(child: SizedBox(height: widget.padding.bottom)),
    ];

    return Theme(
      data: Theme.of(context).copyWith(
        textSelectionTheme: TextSelectionThemeData(
          selectionColor: context.palette.accent.withAlpha(80),
          selectionHandleColor: context.palette.accent,
        ),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: SelectionArea(
              key: _selectionAreaKey,
              onSelectionChanged: widget.follow
                  ? _handleSelectionChanged
                  : null,
              child: Scrollbar(
                controller: _controller,
                child: NotificationListener<ScrollMetricsNotification>(
                  onNotification: _handleMetricsNotification,
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _handleScrollNotification,
                    child: CustomScrollView(
                      controller: _controller,
                      center: centered ? belowKey : null,
                      slivers: slivers,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (widget.follow && !_following)
            Positioned(
              right: 16,
              bottom: 14,
              child: _buildFollowPill(context),
            ),
        ],
      ),
    );
  }
}
