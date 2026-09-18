import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../../core/theme/app_theme.dart';
import '../utils/ansi_text.dart';
import '../utils/log_line_buffer.dart';

/// 距底部多少像素以内算「停在底部」。
///
/// 下内边距 12 + 一行约 20，最后一行只要还露在屏幕上就算在底部；
/// 与面板 Web 端 useLogAutoFollow 的取值思路一致（它是 40，容器内边距更大）。
const double kLogFollowTolerance = 32;

/// 回到底部时，锚点下方只放最后这么多行。
///
/// 按行高不定的懒加载列表，跳到很远的偏移要把中间每一行都布局一遍
/// （几千行就是明显的一顿）。所以「回到底部」不直接跳，而是把锚点挪到末尾附近：
/// 锚点之上的行交给反向生长的列表，按需往上加载；锚点之下只剩这一小段，
/// 贴底时最多布局这么多行。取 200 是为了在大屏上也一定超过一屏高。
const int _kTailWindow = 200;

/// 日志正文视图：按行懒渲染、在底部时跟随新日志、上翻时不被拉回（issue #10）。
///
/// 跟随规则：
/// - 停在底部（误差 [kLogFollowTolerance] 以内）时，新日志到来自动贴底；
/// - 用户手动往上翻，就不再跟随，新日志只往下面接，眼前的内容一动不动；
/// - 手动滚回底部、或点「回到底部」按钮，恢复跟随。
///
/// 「是不是用户在滚」只认手势（拖动 / 惯性 / 滚轮），程序自己的贴底跳转不算：
/// 内容变高不会改变滚动位置，只有用户操作才会让它离开底部。
///
/// [follow] 为 false 时是静态日志（一次性加载完），从顶部开始显示，没有跟随与按钮。
class LogView extends StatefulWidget {
  const LogView({
    super.key,
    required this.buffer,
    required this.textStyle,
    required this.brightness,
    this.padding = const EdgeInsets.all(12),
    this.follow = true,
    this.mutedColor,
    this.truncatedHint,
    this.truncatedActionLabel,
    this.onTruncatedAction,
  });

  final LogLineBuffer buffer;
  final TextStyle textStyle;

  /// 日志底色的明暗（不是页面主题的），决定 ANSI 配色。
  final Brightness brightness;
  final EdgeInsets padding;
  final bool follow;

  /// 截断提示的文字颜色，缺省从正文颜色淡化。
  final Color? mutedColor;

  /// 日志被截断时接在提示后面的一句话，告诉用户完整日志去哪儿拿。
  final String? truncatedHint;

  /// 日志被截断时，提示条上的操作（比如「下载完整日志」）。两者都给才显示。
  final String? truncatedActionLabel;
  final VoidCallback? onTruncatedAction;

  @override
  State<LogView> createState() => _LogViewState();
}

class _LogViewState extends State<LogView> {
  final _controller = ScrollController();

  /// 锚点的绝对行号：它之前的行在「上方列表」里（从锚点往上反向生长），
  /// 它及之后的行在「下方列表」里（往下正向生长，新日志都接在这里）。
  int _anchor = 0;

  /// 是否以下方列表为滚动原点。只在锚点之上确实有行时才启用，
  /// 否则短日志会被原点顶在屏幕中间，上面空一截。
  bool _centered = false;

  /// 换锚点时递增，用作两个列表的 key：新列表从空白开始按需布局，
  /// 而不是拿着旧的已布局行一路往回补。
  int _sliverGeneration = 0;
  int _bufferGeneration = 0;

  bool _following = true;
  bool _userScrolling = false;
  bool _stickScheduled = false;

  @override
  void initState() {
    super.initState();
    _following = widget.follow;
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
    if (!identical(oldWidget.buffer, widget.buffer)) {
      oldWidget.buffer.removeListener(_handleBufferChanged);
      oldWidget.buffer.holdTrim = false;
      widget.buffer.addListener(_handleBufferChanged);
      _bufferGeneration = widget.buffer.generation;
      _following = widget.follow;
      _resetAnchor();
      _sliverGeneration++;
      if (_following) {
        _stickAfterFrame();
      }
    }
  }

  @override
  void dispose() {
    widget.buffer.removeListener(_handleBufferChanged);
    // 缓冲区归页面所有，比视图活得久；别把「暂缓裁剪」留在它身上。
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
  }

  void _handleBufferChanged() {
    final buffer = widget.buffer;
    if (buffer.generation != _bufferGeneration) {
      _bufferGeneration = buffer.generation;
      if (_following) {
        // 整段换了内容：跟随中就直接落到新内容的末尾。
        _jumpToLatest();
        return;
      }
      // 没在跟随时尽量原地不动。轮询把同一份快照再推一遍是最常见的情况，
      // 绝对行号一致，什么都不会变。
      _anchor = _anchor.clamp(buffer.droppedCount, buffer.totalCount);
    }
    setState(() {});
    if (_following) {
      _stickAfterFrame();
    }
  }

  /// 「回到底部」：换锚点、从末尾附近重新布局，并恢复跟随。
  void _jumpToLatest() {
    setState(() {
      _resetAnchor();
      _sliverGeneration++;
    });
    _setFollowing(true);
    if (_controller.hasClients) {
      // 必须在新列表布局之前把位置挪到尾段附近，否则新列表会在旧的
      // （可能很远的）偏移上布局，又回到「把中间每一行都排一遍」。
      // 估算按每行只有一行高，只会偏小不会越过底部，剩下的交给贴底校正。
      final position = _controller.position;
      final tailLines = widget.buffer.totalCount - _anchor;
      final lineExtent =
          MediaQuery.textScalerOf(context).scale(widget.textStyle.fontSize ?? 14) *
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
    widget.buffer.holdTrim = !value;
    _rebuildSoon();
  }

  /// 滚动通知有可能在布局阶段派发（例如惯性滚动途中内容变高），
  /// 那一刻不能 setState，挪到这一帧结束之后。
  void _rebuildSoon() {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {});
        }
      });
      return;
    }
    setState(() {});
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
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void _stickToBottom() {
    // 用户手指还在屏幕上（或惯性还没停）时绝不能跳：jumpTo 会打断当前手势，
    // 日志刷得快时用户就永远拖不动。
    if (!mounted || !_following || _userScrolling || !_controller.hasClients) {
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
      // 滚轮 / 触控板没有 dragDetails，靠用户滚动方向认出来。
      _userScrolling = true;
    } else if (notification is ScrollUpdateNotification && _userScrolling) {
      _setFollowing(_isAtBottom(notification.metrics));
    } else if (notification is ScrollEndNotification && _userScrolling) {
      _userScrolling = false;
      _setFollowing(_isAtBottom(notification.metrics));
      if (_following) {
        // 手势期间到的新日志没有贴底，停下来且仍在底部时补一次。
        _stickAfterFrame();
      }
    }
    return false;
  }

  /// 内容变高、视口尺寸变化、以及懒加载列表把估算高度修正成实际高度时都会触发。
  /// 贴底一次可能因为估算偏小而没到真正的底，靠它接着校正到位。
  bool _handleMetricsNotification(ScrollMetricsNotification notification) {
    if (widget.follow && notification.depth == 0) {
      _stickToBottom();
    }
    return false;
  }

  Widget _buildLine(int absolute) {
    final buffer = widget.buffer;
    final index = absolute - buffer.droppedCount;
    if (index < 0 || index >= buffer.length) {
      // 这一行已经被裁掉，下一次重建前的过渡帧里可能还会被问到。
      return const SizedBox.shrink();
    }
    return Text.rich(
      AnsiTextParser.buildTextSpan(
        buffer.lineAt(index),
        baseStyle: widget.textStyle,
        brightness: widget.brightness,
        start: buffer.ansiStateAt(index),
      ),
    );
  }

  SliverChildBuilderDelegate _lineDelegate(
    int count,
    int Function(int index) absoluteOf,
  ) {
    return SliverChildBuilderDelegate(
      (context, index) => _buildLine(absoluteOf(index)),
      childCount: count,
      // 日志行滚出去就该回收，保活只会让内存跟着翻看的范围涨。
      addAutomaticKeepAlives: false,
    );
  }

  Widget _buildTruncatedNotice(int dropped) {
    final muted =
        widget.mutedColor ??
        widget.textStyle.color?.withAlpha(170) ??
        AppColors.slate500;
    final label = widget.truncatedActionLabel;
    final action = widget.onTruncatedAction;
    final hint = widget.truncatedHint;
    // 提示不是日志正文，不参与选择复制。
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

    // 以下方列表为原点时，排在它前面的 sliver 从原点往上反向排布：
    // 上方列表紧贴原点，截断提示与顶部留白依次在更上面。
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
            // 上方列表的第 0 项是紧挨锚点的那一行，越往后越早。
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
          selectionColor: AppColors.primary.withAlpha(80),
          selectionHandleColor: AppColors.primary,
        ),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: SelectionArea(
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
              bottom: 16,
              child: FloatingActionButton.small(
                // 页面上可能还有别的 FAB，不参与路由切换的 Hero 动画。
                heroTag: null,
                tooltip: '回到底部',
                onPressed: _jumpToLatest,
                child: const Icon(Icons.vertical_align_bottom),
              ),
            ),
        ],
      ),
    );
  }
}
