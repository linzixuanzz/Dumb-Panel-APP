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

/// 行号与正文之间的间距。
const double _kGutterGap = 10;

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

  /// 是否按跳转设下的锚点排布。跟随模式本来就一直用锚点；静态日志平时从顶部
  /// 开始（锚点恒为 droppedCount），只有按行号跳转后才改用跳转锚点，否则
  /// 「下一处匹配」「首处报错」在面板日志这类静态页上只会回到第一行。
  /// [_resetAnchor] 清掉它（回到底部、换缓冲区、静态日志整段换内容）。
  bool _jumpAnchored = false;

  bool _following = true;
  bool _userScrolling = false;
  bool _stickScheduled = false;

  /// 用户有没有选中文字（长按 / 拖选）。有选区时按「不跟随」处理：不滑锚点、
  /// 不贴底，并暂缓裁剪，否则选中的字会变成下一行的字（APP #15）。
  bool _hasSelection = false;

  /// 暂停跟随时记录的 `buffer.totalCount`，用于悬浮胶囊实时提示「新增 N 行」。
  int _pausedAtTotalCount = 0;

  final _selectionAreaKey = GlobalKey<SelectionAreaState>();

  /// 跳转时要放到视口顶上的那一行（目标行前 2 行）。锚点被往前夹过时它不在
  /// 滚动原点，挂上 [_jumpTopKey]，帧后按实际排版把它滚到顶上（见
  /// [_revealJumpTop]）；没夹过时它就是锚点，用不着，key 为 null。
  int _jumpTopLine = 0;
  GlobalKey? _jumpTopKey;

  /// 上一次跳转时按多高的视口夹的锚点（见 [_showFromLine]）。窗口本身
  /// 变大、视口比它还高时重夹，见 [_handleMetricsNotification]。
  double _jumpClampExtent = 0;
  bool _reclampScheduled = false;

  /// 行号栏宽度按实际字形量一次缓存起来，位数、字号、缩放不变就不重量。
  int _gutterDigits = 0;
  TextStyle? _gutterStyle;
  TextScaler? _gutterScaler;
  double _gutterWidth = 0;

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
    _jumpAnchored = false;
    _jumpTopKey = null;
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
      if (_jumpAnchored && !widget.follow) {
        // 静态日志跳转过之后整段换了内容（如面板日志改筛选重拉）：绝对行号
        // 从 0 重数，旧的跳转锚点已经对不上任何一行，回到从顶部开始显示。
        _resetAnchor();
        _sliverGeneration++;
        if (_controller.hasClients) {
          _controller.position.jumpTo(0);
        }
      } else {
        // 没在跟随时尽量原地不动：轮询把同一份快照再推一遍是最常见的情况。
        _anchor = _anchor.clamp(buffer.droppedCount, buffer.totalCount);
      }
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

  /// 估算的单行高度：字号（随系统字体缩放）× 行高。软换行折成多行、没设
  /// 行高时字体自带的行距都会让实际行更高。
  double _estimatedLineExtent() {
    final fontSize = MediaQuery.textScalerOf(
      context,
    ).scale(widget.textStyle.fontSize ?? 14);
    return fontSize * (widget.textStyle.height ?? 1.0);
  }

  /// 视口高度；还没排过版时拿整屏高度兜底（只会偏大）。
  double _viewportExtent() {
    if (_controller.hasClients) {
      final position = _controller.position;
      if (position.hasViewportDimension) {
        return position.viewportDimension;
      }
    }
    return MediaQuery.sizeOf(context).height;
  }

  /// 按绝对行号 O(1) 重建锚点并滚至目标行（不遍历中间数千行）。
  ///
  /// 目标行前 2 行放在视口顶上，目标行就落在视口靠上处。锚点（滚动原点）
  /// 一般就设在这一行；跟随模式与静态日志都走这一条（静态日志靠
  /// [_jumpAnchored]）。
  void _jumpToAbsoluteLine(int targetAbsolute) {
    final buffer = widget.buffer;
    if (buffer.isEmpty) return;
    final dropped = buffer.droppedCount;
    final clamped = targetAbsolute.clamp(dropped, buffer.totalCount - 1);
    if (_hasSelection) {
      // 重建会把选中的行一起回收、却不触发选区回调：先改标记再清，
      // 清选区同步回调时看到的已是「无选区」。
      _hasSelection = false;
      _selectionAreaKey.currentState?.selectableRegion.clearSelection();
    }
    _showFromLine(math.max(dropped, clamped - 2));
  }

  /// 把 [line] 放到视口顶上：按它重建锚点（锚点下方不足一屏时往前夹），
  /// 跟随模式下同时暂停跟随。跳转和窗口变大后的重夹都走这里。
  void _showFromLine(int line) {
    final buffer = widget.buffer;
    if (buffer.isEmpty) return;
    final dropped = buffer.droppedCount;
    final total = buffer.totalCount;
    final topLine = line.clamp(dropped, total - 1);
    // 引擎把每行行高四舍五入到整数逻辑像素（13×1.5=19.5 排成 20，
    // 13×1.4=18.2 排成 18），空行还会再矮最多 1 像素（12.5×1.58 的空行
    // 只有 19）。所以按取整后的值估偏移，按再减 1 的值兜下限。
    final lineExtent = _estimatedLineExtent().roundToDouble();
    final minLineExtent = math.max(1.0, lineExtent - 1);
    final viewportExtent = _viewportExtent();
    // 锚点下方不足一屏时最大偏移是 0，从原点往前到「内容底边贴视口底边」
    // 那一整段都滑得到：末尾几行顶在视口上半截，下面一大片空白，往末尾
    // 一甩就停在那儿（跟随模式还会被当成「在底部」恢复跟随，一直空着）。
    // 所以锚点往前夹，让它下方的行按最矮的算也够一屏，滚动范围的末端就
    // 一定是内容底边贴视口底边。整段不足一屏时夹到最顶上、不设 center，
    // 等同从头显示、不能滚。
    // 「一屏」按视口之后最高能长到多高算，不按跳转这一刻：页内搜索是在
    // 键盘弹着时跳的，视口被压矮一大截，收起键盘、关掉搜索栏后又变高，
    // 按矮视口夹的锚点下方就又不够一屏了。窗口尺寸不随键盘变，视口高不过
    // 它的长边，转屏也一样；窗口本身变大见 [_handleMetricsNotification]。
    // 偏移仍按当前视口算。
    final clampExtent = math.max(
      viewportExtent,
      MediaQuery.sizeOf(context).longestSide,
    );
    final screenLines = (clampExtent / minLineExtent).ceil();
    final nextAnchor = math.max(
      dropped,
      math.min(topLine, total - screenLines),
    );
    final centered = nextAnchor > dropped;
    // 锚点被往前夹过时，按估算行高先滚到 topLine，但不超过估算的最大偏移
    // （内容底边贴视口底边）。不换行时这一帧就排对了，不会先按「锚点在顶、
    // 下面空着」画一帧再纠正；软换行把行撑高（偏移估小了）或末尾有空行
    // （估大了几像素）时，帧后 [_revealJumpTop] 按实际排版再补一次。
    var offset = 0.0;
    if (topLine > nextAnchor) {
      final leading = centered ? 0.0 : widget.padding.top;
      final toTop = leading + (topLine - nextAnchor) * lineExtent;
      final toEnd =
          leading +
          (total - nextAnchor) * lineExtent +
          widget.padding.bottom -
          viewportExtent;
      offset = math.max(0.0, math.min(toTop, toEnd));
    }
    setState(() {
      _anchor = nextAnchor;
      _centered = centered;
      _jumpAnchored = true;
      _jumpClampExtent = clampExtent;
      _jumpTopLine = topLine;
      _jumpTopKey = topLine > nextAnchor ? GlobalKey() : null;
      _glued = false;
      _sliverGeneration++;
      if (widget.follow) {
        if (_following) {
          _pausedAtTotalCount = total;
        }
        // 跳走即暂停跟随：锚点不再随尾部滑，新行接在下方列表末尾，
        // 所以要暂缓裁剪，免得缓冲区裁过锚点、眼前的行整体错位。
        _following = false;
        buffer.holdTrim = true;
      }
    });
    if (_controller.hasClients) {
      _controller.position.jumpTo(offset);
    }
    if (_jumpTopKey != null) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _revealJumpTop());
    }
  }

  /// 锚点被往前夹过时，帧后按实际排版把 topLine 滚到视口顶上，并夹进滚动
  /// 范围（夹到最大偏移即内容底边贴视口底边）。
  ///
  /// 估算偏移最多比 topLine 的实际位置靠后几像素（空行矮一点），落在缓存区
  /// 里照样排得出来；它没排出来就只可能在已排版范围的下方（软换行把中间
  /// 的行撑高了）：往下翻一屏再看，每次一帧，直到排出来或到底。
  void _revealJumpTop() {
    final key = _jumpTopKey;
    if (!mounted || key == null || !_controller.hasClients) {
      return;
    }
    final position = _controller.position;
    final box = key.currentContext?.findRenderObject();
    if (box == null || !box.attached) {
      final next = math.min(
        position.maxScrollExtent,
        position.pixels + position.viewportDimension,
      );
      if (next - position.pixels > 0.5) {
        position.jumpTo(next);
        SchedulerBinding.instance.addPostFrameCallback(
          (_) => _revealJumpTop(),
        );
        SchedulerBinding.instance.ensureVisualUpdate();
      }
      return;
    }
    _jumpTopKey = null;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) {
      return;
    }
    final target = viewport
        .getOffsetToReveal(box, 0.0)
        .offset
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((target - position.pixels).abs() > 0.5) {
      position.jumpTo(target);
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
      final lineExtent = _estimatedLineExtent();
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

  /// 选区变了（长按选词、拖选、点别处清掉、复制后清掉……）。
  void _handleSelectionChanged(SelectedContent? content) {
    // 点一下只会落一个光标（选中内容为空串），不算选区。
    final hasSelection = content != null && content.plainText.isNotEmpty;
    // 视图已经拆了就别再碰缓冲区：它归页面所有，dispose 时已复位暂缓裁剪。
    if (!mounted || hasSelection == _hasSelection) {
      return;
    }
    _hasSelection = hasSelection;
    // 选区保持期间也暂缓裁剪：裁到锚点之前的话下方列表整体错位，选中的字照样会跑。
    widget.buffer.holdTrim = !_following || hasSelection;
    if (!hasSelection) {
      // 不能在这里当场重建：工具栏「全选」是先清选区、再全选，这次回调
      // 只是中间一步。当场 _jumpToLatest() 会把随后全选到的旧行一起回收，
      // 「有选区」的标记就再也清不掉，跟随一直卡住。统一挪到帧后再判。
      _resumeAfterPause();
    }
  }

  /// 手势或选区让跟随暂停过，停下来后接着跟随。
  ///
  /// 暂停期间锚点没滑，新来的行都接在了下方列表末尾。只要接过行（下方列表
  /// 超过尾段窗口），之后就不能原地滑了，标成「不紧贴」交给「回到底部」重建；
  /// 人还停在底部时先补一次贴底，等下一批新行来了再重建。
  void _resumeAfterPause() {
    if (!_following || _userScrolling || _hasSelection) {
      return;
    }
    final buffer = widget.buffer;
    final anchor = _anchor.clamp(buffer.droppedCount, buffer.totalCount);
    if (buffer.totalCount - anchor > _kTailWindow) {
      _glued = false;
    }
    // 挪到这一帧之后再动：滚动结束的通知是在滚动位置内部派发的（惯性收尾时
    // 还可能正在布局），选区回调也可能只是「先清掉、再全选」中间的一步。
    // 到时候再看一眼，暂停没真结束就什么都不做。
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_following ||
          _userScrolling ||
          _hasSelection ||
          !_controller.hasClients) {
        return;
      }
      if (!_glued && !_isAtBottom(_controller.position)) {
        // 选区保持期间没贴底，下面攒了一截：直接贴底要把攒下的每一行都排
        // 一遍版，正是 APP #15 要消掉的那一顿，改走重建。
        _jumpToLatest();
        return;
      }
      _stickToBottom();
    });
    // 选区回调不一定伴随着一帧，帧后回调要有帧才会跑。
    SchedulerBinding.instance.ensureVisualUpdate();
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
    SchedulerBinding.instance.ensureVisualUpdate();
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
    if (notification.depth != 0) {
      return false;
    }
    if (widget.follow) {
      _stickToBottom();
    }
    // 跳转时锚点按窗口长边夹（[_showFromLine]），键盘、转屏都够；
    // 分屏拖动分隔条、桌面拉大窗口能让窗口本身变大，视口比当时的上界还高。
    // 最大偏移成了 0、锚点上面又还有行，说明锚点下方不足一屏：末尾几行
    // 顶在上半截、下面空着。帧后按新视口重夹一次。
    final metrics = notification.metrics;
    if (_jumpAnchored &&
        _centered &&
        metrics.viewportDimension > _jumpClampExtent + 0.5 &&
        metrics.maxScrollExtent <= 0) {
      _reclampJumpAfterFrame();
    }
    return false;
  }

  void _reclampJumpAfterFrame() {
    if (_reclampScheduled) {
      return;
    }
    _reclampScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _reclampScheduled = false;
      // 有选区时不动：重夹要重建列表，选中的字会被清掉。
      if (!mounted ||
          !_jumpAnchored ||
          _hasSelection ||
          !_controller.hasClients) {
        return;
      }
      final position = _controller.position;
      if (position.viewportDimension <= _jumpClampExtent + 0.5 ||
          position.maxScrollExtent > 0) {
        return;
      }
      if (_following) {
        // 跳转后已经甩回底部、恢复了跟随：按尾段重建，接着跟随。
        _jumpToLatest();
        return;
      }
      // 按眼下视口顶上那一行重夹，不按当初跳转的目标行：跳转之后人可能
      // 已经往前翻走了（静态页上跳转锚点一直留着），拉大窗口不该把人
      // 拽回去。
      final topLine = _lineAtViewportTop();
      if (topLine != null) {
        _showFromLine(topLine);
      }
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  /// 视口顶边压着的那一行的绝对行号；顶边落在上边距、截断提示上时取它
  /// 下面的第一行。按实际排版找，软换行撑高的行也不会数错。还没排过版时
  /// 返回 null。
  int? _lineAtViewportTop() {
    RenderViewportBase? viewport;
    void findViewport(RenderObject node) {
      if (viewport != null) {
        return;
      }
      if (node is RenderViewportBase) {
        viewport = node;
        return;
      }
      node.visitChildren(findViewport);
    }

    final root = context.findRenderObject();
    if (root == null) {
      return null;
    }
    findViewport(root);
    final found = viewport;
    if (found == null) {
      return null;
    }
    final buffer = widget.buffer;
    final anchor = _anchor.clamp(buffer.droppedCount, buffer.totalCount);
    int? best;
    var bestTop = double.infinity;
    found.visitChildren((sliver) {
      RenderObject? list = sliver;
      if (list is RenderSliverPadding) {
        list = list.child;
      }
      if (list is! RenderSliverMultiBoxAdaptor) {
        return;
      }
      // 锚点之前的行在反向排的那个列表里，第 0 个紧挨着锚点往上。
      final above =
          list.constraints.growthDirection == GrowthDirection.reverse;
      for (var box = list.firstChild; box != null; box = list.childAfter(box)) {
        if (!box.hasSize) {
          continue;
        }
        final top = box.localToGlobal(Offset.zero, ancestor: found).dy;
        if (top + box.size.height <= 0.5 || top >= bestTop) {
          continue;
        }
        bestTop = top;
        final index = list.indexOf(box);
        best = above ? anchor - 1 - index : anchor + index;
      }
    });
    return best;
  }

  /// 在保持 ANSI 着色的前提下叠加关键字搜索高亮；[active] 为当前选中的命中。
  TextSpan _highlightSpan(
    TextSpan source,
    String query, {
    required bool active,
  }) {
    final lowerQuery = query.toLowerCase();
    if (lowerQuery.isEmpty) return source;

    // 深色日志底上，浅色正文压在 60% 不透明的黄底上只有约 3.5:1，落在
    // ANSI 红 / 蓝字上更是不到 1.5:1，用户最该看清的那个词反而最难认。
    // 当前命中在深底上改成不透明黄底 + 深墨字（约 9:1），浅底维持原样。
    // 日志内容色属规范允许的例外，沿用 AppColors 现有的搜索高亮与终端墨色。
    final darkActive = active && widget.brightness == Brightness.dark;
    final matchBg = darkActive
        ? AppColors.searchMatchCurrent.withAlpha(0xFF)
        : active
        ? AppColors.searchMatchCurrent
        : AppColors.searchMatch;
    final matchFg = darkActive ? AppColors.termText : null;

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
                backgroundColor: matchBg,
                color: matchFg,
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
      span = _highlightSpan(span, query, active: isActiveMatch);
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

    // 栏宽与样式在 build 里按当前位数和字号缩放量好（_gutterWidth）。
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectionContainer.disabled(
          child: SizedBox(
            width: _gutterWidth,
            child: Padding(
              padding: const EdgeInsets.only(right: _kGutterGap),
              child: Text(
                '${absolute + 1}',
                textAlign: TextAlign.right,
                // 估宽万一偏小也只裁掉，不折成两行把整行日志撑高。
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.clip,
                style: _gutterStyle,
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
      (context, index) {
        final absolute = absoluteOf(index);
        final line = _buildLine(absolute);
        final topKey = _jumpTopKey;
        if (topKey != null && absolute == _jumpTopLine) {
          return KeyedSubtree(key: topKey, child: line);
        }
        return line;
      },
      childCount: count,
      addAutomaticKeepAlives: false,
    );
  }

  /// 截断提示、行号这类次要文字的颜色：优先用页面按日志底色给的
  /// [LogView.mutedColor]，缺省从正文颜色淡化。
  Color _mutedColor(BuildContext context) =>
      widget.mutedColor ??
      widget.textStyle.color?.withAlpha(170) ??
      context.palette.text2;

  /// 量出行号栏宽度（按最长行号的位数、当前字号与系统字体缩放），
  /// 结果缓存在 [_gutterWidth] / [_gutterStyle] 里给 [_buildLine] 用。
  ///
  /// 以前按每位固定 8.5dp 估算，不随缩放变：1.3 倍字号下 3 位行号放不下，
  /// 「123」折成「12 / 3」，每行日志都被撑高、行号也读错。
  void _updateGutter(BuildContext context) {
    final digits = math.max(3, widget.buffer.totalCount.toString().length);
    // 行号直接用次要文字色，不再叠半透明：叠了之后默认暗底上只剩约 2.7:1。
    // 先叠上外层 DefaultTextStyle（如 Material 正文的字间距）：Text 渲染时
    // 本来就会叠，量宽时漏了它，每位差零点几像素，末位照样被裁。
    final style = DefaultTextStyle.of(context).style.merge(
      AppText.tabular(
        widget.textStyle.copyWith(
          color: _mutedColor(context),
          fontSize: (widget.textStyle.fontSize ?? 12.5) - 1,
        ),
      ),
    );
    final scaler = MediaQuery.textScalerOf(context);
    if (digits == _gutterDigits &&
        style == _gutterStyle &&
        scaler == _gutterScaler) {
      return;
    }
    final painter = TextPainter(
      text: TextSpan(text: '8' * digits, style: style),
      textDirection: Directionality.of(context),
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    _gutterWidth = painter.width.ceilToDouble() + _kGutterGap;
    painter.dispose();
    _gutterDigits = digits;
    _gutterStyle = style;
    _gutterScaler = scaler;
  }

  Widget _buildTruncatedNotice(int dropped) {
    final muted = _mutedColor(context);
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
          // 有底色的胶囊按规范用约束补足 44dp 命中区，内容在其中居中。
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: AppTapTarget.min),
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
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final buffer = widget.buffer;
    final dropped = buffer.droppedCount;
    final total = buffer.totalCount;
    // 静态日志平时从顶部开始；按行号跳转过才改按跳转锚点排布。
    final useAnchor = widget.follow || _jumpAnchored;
    final anchor = useAnchor ? _anchor.clamp(dropped, total) : dropped;
    final centered = useAnchor && _centered;
    if (widget.showLineNumbers) {
      _updateGutter(context);
    }
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
