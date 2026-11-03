import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/design_tokens.dart';

/// 脚本编辑页（`ScriptViewPage`）与配置文件页（`ConfigScriptPage`）共用的代码编辑器。
///
/// ── 为什么换掉原生 TextField（APP #25） ──────────────────────────────────
/// 原来的编辑器是一个装着全文的 `TextField`：4000+ 行（约 150KB）的脚本，每敲一个字、
/// 每滚一下都要对整篇重新排版 / 重画（v1.4.2 只去掉了行号栏那一次重复排版）。
/// re_editor 按行建段落、只排版和绘制视口里的那几十行，文本多长都只付一屏的代价。
///
/// 这里只做「外观 + 行为开关」，内容、查找状态都由页面持有：
/// - 字体 13 号等宽、行高 1.5，跟随系统字号缩放（与原 TextField 一致）；
/// - 软换行，续行不编号（行号按逻辑行画）；
/// - 关掉代码折叠、括号 / 引号自动补全、语法高亮——原来的编辑器都没有，别凭空多出来；
/// - 只读时不显示光标、选择菜单里只有「复制 / 全选」，外接键盘也改不了内容；
/// - 跟随系统「粗体文字」；键盘弹起压矮编辑器时把光标行滚回视口；
/// - 点同一组 [CodeEditorTapRegion] 里的控件（查找条、路径行）不让编辑器失焦，
///   所以页面要把紧挨编辑器的区域一起包进 [CodeEditorTapRegion]。
class ScriptCodeEditor extends StatefulWidget {
  const ScriptCodeEditor({
    super.key,
    required this.controller,
    required this.findController,
    required this.readOnly,
    required this.background,
    this.focusNode,
  });

  final CodeLineEditingController controller;

  /// 查找命中的高亮层，见 [ScriptEditorFindController]。
  final ScriptEditorFindController findController;

  final bool readOnly;

  /// 编辑器底色（面板设置 editor_background_color，没设过按明暗主题回落）。
  /// 正文与行号的颜色按它的明暗来选，而不是按 App 主题。
  final Color background;

  final FocusNode? focusNode;

  /// 编辑器正文内边距。行号由 re_editor 按段落的实际 y 画，不用再和它手工对齐。
  static const contentPadding = EdgeInsets.all(14);

  @override
  State<ScriptCodeEditor> createState() => _ScriptCodeEditorState();
}

class _ScriptCodeEditorState extends State<ScriptCodeEditor>
    with WidgetsBindingObserver {
  /// 移动端长按 / 双击后弹出的选择菜单。re_editor 在移动端不自带菜单，要自己实现。
  late final SelectionToolbarController _toolbarController =
      MobileSelectionToolbarController(builder: _buildToolbar);

  /// 页面没传 focusNode 时自己建一个：下面切只读时要用它收起键盘。
  FocusNode? _ownFocusNode;

  FocusNode get _focusNode =>
      widget.focusNode ?? (_ownFocusNode ??= FocusNode());

  /// 交给 CodeEditor 的是这层包装，不是页面的 controller 本身，见 [_ScriptEditorController]。
  late _ScriptEditorController _editorController = _ScriptEditorController(
    widget.controller,
  );

  /// 上一次窗口尺寸变化时键盘（viewInsets）占的高度，用来判断「键盘刚弹起 / 变高」。
  double _lastBottomInset = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  /// 键盘弹起会把编辑器压矮，但 re_editor 不管 viewInsets：点屏幕下半部的一行，
  /// 键盘一出来光标行就被挡在视口下面了（原生 TextField 会自己滚回来）。
  ///
  /// 和原生 EditableText 一样在窗口尺寸变化时读 View 上的 viewInsets：不能用
  /// MediaQuery，Scaffold 会把正文那层 MediaQuery 的 viewInsets.bottom 抹成 0。
  /// 键盘变高、且编辑器有焦点时，等这一帧按压矮后的高度排完版，再把光标滚进视口。
  @override
  void didChangeMetrics() {
    final bottomInset = View.of(context).viewInsets.bottom;
    if (bottomInset > _lastBottomInset && _focusNode.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _focusNode.hasFocus) {
          _editorController.makeCursorVisible();
        }
      });
    }
    _lastBottomInset = bottomInset;
  }

  @override
  void didUpdateWidget(covariant ScriptCodeEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 两个页面的 controller 都是 late final、不会换；万一换了就跟着换一层包装。
    // 旧包装不 dispose：它的 dispose 会转发给页面的 controller，那是页面自己管的。
    if (oldWidget.controller != widget.controller) {
      _editorController = _ScriptEditorController(widget.controller);
    }
    // re_editor 切成只读时不会关掉已经打开的输入法连接，键盘还在、还能继续往里敲。
    // 原生 TextField(readOnly) 会关，这里补上：变成只读就让编辑器失焦。
    if (!oldWidget.readOnly && widget.readOnly && _focusNode.hasFocus) {
      _focusNode.unfocus();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ownFocusNode?.dispose();
    super.dispose();
  }

  /// 选择菜单：文案写死中文，不依赖系统语言。
  ///
  /// 只读时只给「复制 / 全选」；可编辑时再加「剪切 / 粘贴」。
  /// 「复制 / 剪切」只在有选区时出现：re_editor 在选区折叠时会复制 / 剪切**整行**，
  /// 这和原生输入框的习惯不一样，容易误删。
  Widget _buildToolbar({
    required BuildContext context,
    required TextSelectionToolbarAnchors anchors,
    required CodeLineEditingController controller,
    required VoidCallback onDismiss,
    required VoidCallback onRefresh,
  }) {
    final readOnly = widget.readOnly;
    final hasSelection = !controller.selection.isCollapsed;
    final items = <ContextMenuButtonItem>[
      if (hasSelection && !readOnly)
        ContextMenuButtonItem(
          type: ContextMenuButtonType.cut,
          label: '剪切',
          onPressed: () {
            controller.cut();
            onDismiss();
          },
        ),
      if (hasSelection)
        ContextMenuButtonItem(
          type: ContextMenuButtonType.copy,
          label: '复制',
          onPressed: () {
            controller.copy();
            onDismiss();
          },
        ),
      if (!readOnly)
        ContextMenuButtonItem(
          type: ContextMenuButtonType.paste,
          label: '粘贴',
          onPressed: () {
            controller.paste();
            onDismiss();
          },
        ),
      if (!controller.isAllSelected)
        ContextMenuButtonItem(
          type: ContextMenuButtonType.selectAll,
          label: '全选',
          onPressed: () {
            controller.selectAll();
            // 全选后菜单留着并按新选区重新定位，接着就能点「复制 / 剪切」。
            onRefresh();
          },
        ),
    ];
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: anchors,
      buttonItems: items,
    );
  }

  @override
  Widget build(BuildContext context) {
    final onDarkEditor = widget.background.computeLuminance() < 0.45;
    final foreground = onDarkEditor
        ? const Color(0xFFD4D4D4)
        : AppColors.slate900;
    // 跟随系统字号：原 TextField 会按 textScaler 放大，re_editor 不会，这里手动乘上。
    final fontSize = MediaQuery.textScalerOf(context).scale(13);
    // 系统「无障碍 → 粗体文字」：原 TextField 会自己合并 FontWeight.bold，re_editor 不会。
    // CodeEditorStyle 没有字重这一项，正文靠 [_ScriptEditorController.buildTextSpan] 加粗，
    // 行号在下面的 gutterStyle 里同条件加粗。
    final boldText = MediaQuery.boldTextOf(context);
    _editorController.readOnly = widget.readOnly;
    if (_editorController.boldText != boldText) {
      _editorController.boldText = boldText;
      // 已经排好的段落按 TextSpan 缓存，开关粗体时要整屏重排一次才看得到变化。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _editorController.forceRepaint();
        }
      });
    }
    // 行号与正文同字号、同行高，re_editor 按每个段落的顶边画号，天然与正文同一行。
    final gutterStyle = TextStyle(
      fontSize: fontSize,
      fontFamily: 'monospace',
      fontWeight: boldText ? FontWeight.bold : null,
      height: 1.5,
      // 跟编辑器底色的明暗走，而不是跟 App 主题走 —— 编辑器底色是用户在面板里自定义的。
      color: onDarkEditor
          ? AppColors.editorGutterOnDark
          : AppColors.editorGutterOnLight,
    );

    return CodeEditor(
      controller: _editorController,
      findController: widget.findController,
      focusNode: _focusNode,
      toolbarController: _toolbarController,
      readOnly: widget.readOnly,
      // 只读时不画光标，与原 TextField(readOnly) 一致。
      showCursorWhenReadOnly: false,
      // re_editor 默认 autofocus = true：一进页面就弹键盘，原来没有这个行为。
      autofocus: false,
      // 软换行：长行折到下一视觉行，续行不编号。
      wordWrap: true,
      // 原编辑器没有括号 / 引号自动补全，敲一个引号就该只出一个引号。
      autocompleteSymbols: false,
      // 关掉代码折叠：按括号分块对 shell / python 并不准，原来也没有这个功能。
      chunkAnalyzer: const NonCodeChunkAnalyzer(),
      padding: ScriptCodeEditor.contentPadding,
      style: CodeEditorStyle(
        fontSize: fontSize,
        fontFamily: 'monospace',
        fontHeight: 1.5,
        textColor: foreground,
        // 底色由外层卡片画，这里透明，免得圆角处露出直角。
        backgroundColor: Colors.transparent,
        selectionColor: AppColors.primary.withAlpha(60),
        // 全部命中的弱高亮；当前命中由 ScriptEditorFindController 叠画一层变成强高亮。
        highlightColor: AppColors.searchMatch,
        cursorColor: foreground,
      ),
      indicatorBuilder: (context, editingController, chunkController, notifier) {
        // IgnorePointer：re_editor 的行号区按下就会选中整行，手指从行号栏开始滑动
        // 滚屏时会误选一行。原来的行号栏也不响应点击。
        return IgnorePointer(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            child: DefaultCodeLineNumber(
              controller: editingController,
              notifier: notifier,
              textStyle: gutterStyle,
              // 当前行不另换颜色，与原来一致。
              focusedTextStyle: gutterStyle,
              // 最少按两位算宽度，文件从 9 行涨到 10 行时整条栏不会横跳。
              minNumberCount: 2,
            ),
          ),
        );
      },
    );
  }
}

/// 套在页面 controller 外面、交给 [CodeEditor] 的那一层。只有编辑器自己（按键、手势、
/// 输入法、选择菜单）走这一层；页面灌内容、查找跳转仍直接用自己的 controller，不受影响。
///
/// 管两件事：
/// 1. **只读时拦住改动**：re_editor 在 Android / iOS 上处理外接键盘（平板、DeX、模拟器）时，
///    按 Backspace / Enter 直接调 `deleteBackward` / `applyNewLine`，根本不看 readOnly；
///    而只读时点一下正文也会拿到焦点。不拦的话，查看模式下就能把正文删掉一截，
///    之后点「编辑」再保存就写回服务端了。所以只读期间凡是改内容的操作一律不执行。
///    选区、复制、全选不改内容，照常放行。
/// 2. **系统「粗体文字」**：re_editor 的样式里没有字重，每一行的 TextSpan 都从
///    [buildTextSpan] 出来再交给段落排版，在这里外面套一层 bold，正文就整体加粗了
///    （断行、命中定位按加粗后的排版走）。
///
/// 构造时 re_editor 会对页面 controller 发一次通知（它的 delegate setter 就这么写的），
/// 内容和选区都没变，页面的监听按 codeLines 引用判重，不会有动作。
class _ScriptEditorController extends CodeLineEditingControllerDelegate {
  _ScriptEditorController(CodeLineEditingController controller)
    : super(delegate: controller);

  bool readOnly = false;
  bool boldText = false;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    required int index,
    required TextSpan textSpan,
    required TextStyle style,
  }) {
    final span = super.buildTextSpan(
      context: context,
      index: index,
      textSpan: textSpan,
      style: style,
    );
    if (!boldText) {
      return span;
    }
    // 外层只带字重、不带文字，里面各段没写字重的都继承它；纯文本与下标都不变。
    return TextSpan(
      style: const TextStyle(fontWeight: FontWeight.bold),
      children: [span],
    );
  }

  // ── 以下都是会改内容的操作：只读时直接不做 ──────────────────────────────
  // 外接键盘实际走到的只有 deleteBackward / applyNewLine，其余一并拦住，
  // 免得 re_editor 以后在别的入口（快捷键、菜单）漏掉 readOnly 时又能改。

  @override
  void edit(TextEditingValue newValue) {
    if (!readOnly) super.edit(newValue);
  }

  @override
  void deleteBackward() {
    if (!readOnly) super.deleteBackward();
  }

  @override
  void deleteForward() {
    if (!readOnly) super.deleteForward();
  }

  @override
  void deleteWordBackward() {
    if (!readOnly) super.deleteWordBackward();
  }

  @override
  void deleteWordForward() {
    if (!readOnly) super.deleteWordForward();
  }

  @override
  void deleteLineBackward() {
    if (!readOnly) super.deleteLineBackward();
  }

  @override
  void deleteLineForward() {
    if (!readOnly) super.deleteLineForward();
  }

  @override
  void deleteSelection() {
    if (!readOnly) super.deleteSelection();
  }

  @override
  void deleteSelectionLines([bool keepExtentOffset = true]) {
    if (!readOnly) super.deleteSelectionLines(keepExtentOffset);
  }

  @override
  void applyNewLine() {
    if (!readOnly) super.applyNewLine();
  }

  @override
  void applyIndent() {
    if (!readOnly) super.applyIndent();
  }

  @override
  void applyOutdent() {
    if (!readOnly) super.applyOutdent();
  }

  @override
  void moveSelectionLinesUp() {
    if (!readOnly) super.moveSelectionLinesUp();
  }

  @override
  void moveSelectionLinesDown() {
    if (!readOnly) super.moveSelectionLinesDown();
  }

  @override
  void transposeCharacters() {
    if (!readOnly) super.transposeCharacters();
  }

  @override
  void replaceSelection(String replacement, [CodeLineSelection? selection]) {
    if (!readOnly) super.replaceSelection(replacement, selection);
  }

  @override
  void replaceAll(Pattern pattern, String replacement) {
    if (!readOnly) super.replaceAll(pattern, replacement);
  }

  @override
  void cut() {
    if (!readOnly) super.cut();
  }

  @override
  void paste() {
    if (!readOnly) super.paste();
  }

  @override
  void undo() {
    if (!readOnly) super.undo();
  }

  @override
  void redo() {
    if (!readOnly) super.redo();
  }
}

/// 查找命中的高亮层：交给 [CodeEditor] 的 `findController`，但**不用** re_editor 自带的查找。
///
/// ── 为什么不用 re_editor 自带的 CodeFindController ──────────────────────
/// 1. 它在后台 isolate 里跑正则，结果异步回来；查找条上的「第几个 / 共几个」、500 上限
///    （`kScriptSearchMatchLimit`）、编辑时就近保持序号（issue #6）这些既有交互都要重做一遍；
/// 2. 它在编辑器没焦点时会把**选区**改写成当前命中、关闭查找时还会抢焦点弹键盘。
///
/// 所以命中仍由页面用 `script_search.dart` 算（与改造前同一套），这里只负责把字符下标
/// 换成 re_editor 的「行 + 列」交给它画：全部命中画一层弱高亮，当前命中再叠画一层
/// （`searchMatch` 0.35 叠两次 ≈ 0.58，接近原来 `searchMatchCurrent` 的 0.6）。
///
/// [value] 始终是同一个非空值：re_editor 只在它变成 null 时抢焦点、变成别的值时改选区，
/// 两件事这里都不要。高亮靠页面 `setState` 时编辑器重建、重新读 [allMatchSelections] 生效。
class ScriptEditorFindController extends ValueNotifier<CodeFindValue?>
    implements CodeFindController {
  ScriptEditorFindController() : super(const CodeFindValue.empty());

  List<int> _lineStarts = const [0];
  List<CodeLineSelection> _matches = const [];
  int _current = -1;
  List<CodeLineSelection> _highlights = const [];

  // 下面四个是接口要求的成员。re_editor 只在自带查找面板（findBuilder）和桌面快捷键里用到，
  // 这里都没开，留着空实例而已。
  final TextEditingController _findInput = TextEditingController();
  final TextEditingController _replaceInput = TextEditingController();
  final FocusNode _findFocus = FocusNode();
  final FocusNode _replaceFocus = FocusNode();

  /// 更新命中区间。[text] 是算出 [offsets] 时编辑器里的全文（`\n` 换行）。
  ///
  /// **必须在页面自己的 `setState` 里调用**：这里刻意不通知监听者（原因见类注释），
  /// 页面 setState 会让编辑器重建、重新取高亮。
  void updateMatches({
    required String text,
    required List<int> offsets,
    required int current,
    required int length,
  }) {
    if (offsets.isEmpty || length <= 0) {
      _matches = const [];
      _current = -1;
      _highlights = const [];
      return;
    }
    // 行首下标只扫一遍 '\n'，不排版；命中再逐个二分落到行上。
    final starts = <int>[0];
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0x0A) {
        starts.add(i + 1);
      }
    }
    _lineStarts = starts;
    final matches = <CodeLineSelection>[];
    for (final offset in offsets) {
      // 命中是按同一份 text 算的，正常不会越界；万一越界就停，别把编辑器画崩。
      if (offset < 0 || offset + length > text.length) {
        break;
      }
      final start = positionForOffset(offset);
      final end = positionForOffset(offset + length);
      matches.add(
        CodeLineSelection(
          baseIndex: start.index,
          baseOffset: start.offset,
          extentIndex: end.index,
          extentOffset: end.offset,
        ),
      );
    }
    _matches = matches;
    updateCurrent(current);
  }

  /// 只换「当前命中」（上一个 / 下一个），命中列表不变。同样要在页面 setState 里调用。
  void updateCurrent(int current) {
    _current = current >= 0 && current < _matches.length ? current : -1;
    _highlights = [..._matches, if (_current >= 0) _matches[_current]];
  }

  /// 字符下标 → 行 + 列（按最近一次 [updateMatches] 的全文）。
  CodeLinePosition positionForOffset(int offset) {
    final starts = _lineStarts;
    var lo = 0;
    var hi = starts.length - 1;
    // 找最后一个「行首 <= offset」的行。
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (starts[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return CodeLinePosition(index: lo, offset: offset - starts[lo]);
  }

  /// 测试用：当前要画的高亮（当前命中会出现两次）。
  @visibleForTesting
  List<CodeLineSelection> get debugHighlights => _highlights;

  @override
  List<CodeLineSelection>? get allMatchSelections => _highlights;

  /// 故意返回 null：不让 re_editor 拿它去改写选区、滚动，跳转由页面自己做。
  @override
  CodeLineSelection? get currentMatchSelection => null;

  @override
  TextEditingController get findInputController => _findInput;

  @override
  TextEditingController get replaceInputController => _replaceInput;

  @override
  FocusNode get findInputFocusNode => _findFocus;

  @override
  FocusNode get replaceInputFocusNode => _replaceFocus;

  @override
  CodeLineSelection? convertMatchToSelection(CodeLineSelection match) => match;

  // 以下操作都由页面自己的查找条实现，这里不响应。
  @override
  void findMode() {}

  @override
  void replaceMode() {}

  @override
  void focusOnFindInput() {}

  @override
  void focusOnReplaceInput() {}

  @override
  void toggleMode() {}

  @override
  void close() {}

  @override
  void toggleRegex() {}

  @override
  void toggleCaseSensitive() {}

  @override
  void previousMatch() {}

  @override
  void nextMatch() {}

  @override
  void replaceMatch() {}

  @override
  void replaceAllMatches() {}

  @override
  void dispose() {
    _findInput.dispose();
    _replaceInput.dispose();
    _findFocus.dispose();
    _replaceFocus.dispose();
    super.dispose();
  }
}
