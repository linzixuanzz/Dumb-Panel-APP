import 'dart:ui' show BoxHeightStyle;

import 'package:flutter/material.dart';

import '../../../core/network/api_endpoints.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/utils/log_background.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/app_snack.dart';
import '../../../shared/widgets/app_state_views.dart';
import '../../scripts/utils/script_search.dart';
import '../../scripts/widgets/script_find_bar.dart';
import '../../scripts/widgets/script_highlight_controller.dart';
import '../../scripts/widgets/script_line_number_gutter.dart';

/// 配置文件 config.sh 编辑页（APP #22：原来 APP 里找不到在哪编辑）。
///
/// 面板接口只有两条、都仅 admin：GET 拿 `{content, path}`（文件不存在时 content 为空），
/// PUT `{content}` 整篇覆盖。编辑器沿用脚本编辑页（`ScriptViewPage`）的行号栏 / 查找高亮 / 查找条，
/// 但这里打开即可编辑：config.sh 只有「改」这一件事，不需要先点「编辑」。
class ConfigScriptPage extends StatefulWidget {
  const ConfigScriptPage({super.key});

  @override
  State<ConfigScriptPage> createState() => _ConfigScriptPageState();
}

class _ConfigScriptPageState extends State<ConfigScriptPage> {
  /// 编辑器内边距。行号栏拿它当滚动视口的起点，两边必须是同一个值，否则行号整体错位。
  static const _editorContentPadding = EdgeInsets.all(14);

  final ScriptHighlightController _contentController =
      ScriptHighlightController();
  final ScrollController _contentScrollController = ScrollController();
  final TextEditingController _findController = TextEditingController();

  /// 挂在编辑器 TextField 上，行号栏与查找滚动靠它找到 TextField 自己的 RenderEditable。
  final GlobalKey _editorKey = GlobalKey();

  bool _loading = true;
  bool _saving = false;
  String? _loadError;
  String _path = 'config.sh';

  /// 最近一次从面板读到 / 成功保存的正文。编辑器内容和它不同就是有未保存的修改。
  String _savedContent = '';
  bool _dirty = false;
  Color? _editorBackgroundColor;

  bool _findBarVisible = false;

  /// 查找的命中列表与当前序号，和脚本编辑页一样独立于 selection（原因见 ScriptViewPage）。
  String _matchQuery = '';
  List<int> _matchOffsets = const [];
  int _currentMatchIndex = -1;
  bool _matchTruncated = false;

  /// 上一次的文本：controller 在移动光标、改选区时也会通知，只有文本真的变了才重算。
  String _lastContentText = '';

  @override
  void initState() {
    super.initState();
    _contentController.addListener(_handleContentChanged);
    _load();
    _loadEditorAppearance();
  }

  @override
  void dispose() {
    _contentController.removeListener(_handleContentChanged);
    _contentController.dispose();
    _contentScrollController.dispose();
    _findController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final response = await DioClient.instance.dio.get(
        ApiEndpoints.configScript,
      );
      final data = extractData(response.data);
      final map = data is Map ? data : const <String, dynamic>{};
      final content = map['content']?.toString() ?? '';
      final path = map['path']?.toString().trim() ?? '';
      if (!mounted) return;
      // 先记下「已保存的正文」再灌进编辑器：灌入会同步触发 _handleContentChanged，
      // 顺序反了那一下会被误判成「有未保存的修改」。
      _savedContent = content;
      _contentController.value = TextEditingValue(
        text: content,
        selection: const TextSelection.collapsed(offset: -1),
      );
      setState(() {
        _path = path.isEmpty ? 'config.sh' : path;
        _dirty = false;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = extractListErrorMessage(error, '加载配置文件失败');
        _loading = false;
      });
    }
  }

  Future<void> _loadEditorAppearance() async {
    // 与脚本编辑器同一个面板配置项（editor_background_color）。
    final color = await loadPanelColorSetting('editor_background_color');
    if (!mounted) return;
    setState(() => _editorBackgroundColor = color);
  }

  Future<void> _save() async {
    if (_saving || _loading || _loadError != null) return;
    final content = _contentController.text;
    setState(() => _saving = true);
    try {
      final response = await DioClient.instance.dio.put(
        ApiEndpoints.configScript,
        data: {'content': content},
      );
      if (!mounted) return;
      final data = extractData(response.data);
      final message = data is Map ? data['message']?.toString().trim() : null;
      setState(() {
        _savedContent = content;
        // 请求在飞时用户可能又敲了字，只把「发出去的那份」算作已保存。
        _dirty = _contentController.text != content;
      });
      AppSnack.success(
        context,
        message == null || message.isEmpty ? '配置文件已保存' : message,
      );
    } catch (error) {
      if (mounted) {
        AppSnack.error(context, extractListErrorMessage(error, '保存配置文件失败'));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 有未保存的修改时返回要确认，免得一个返回手势把改了半天的配置丢掉。
  Future<void> _confirmLeave() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('放弃修改？'),
        content: const Text('配置文件有未保存的修改，离开后这些修改会丢失。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('继续编辑'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.red500),
            child: const Text('放弃修改'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) {
      // Navigator.pop 不经过 PopScope，不会再弹一次确认。
      Navigator.of(context).pop();
    }
  }

  void _handleContentChanged() {
    final text = _contentController.text;
    if (text == _lastContentText) return;
    _lastContentText = text;
    final dirty = text != _savedContent;
    if (dirty != _dirty) {
      setState(() => _dirty = dirty);
    }
    // 查找条开着时边打字边重算命中，高亮才不会染到错位的文字上；不拽视口、不重置序号。
    if (_matchQuery.isNotEmpty) {
      _runSearch(_matchQuery, scrollToMatch: false, keepPosition: true);
    }
  }

  void _runSearch(
    String query, {
    bool scrollToMatch = true,
    bool keepPosition = false,
  }) {
    final previousOffset =
        keepPosition &&
            _currentMatchIndex >= 0 &&
            _currentMatchIndex < _matchOffsets.length
        ? _matchOffsets[_currentMatchIndex]
        : null;
    // 多要一个，才分得清「恰好 500 个」和「被截断」。
    final probed = query.isEmpty
        ? const <int>[]
        : findMatchOffsets(
            _contentController.text,
            query,
            limit: kScriptSearchMatchLimit + 1,
          );
    final truncated = probed.length > kScriptSearchMatchLimit;
    final offsets = truncated
        ? probed.sublist(0, kScriptSearchMatchLimit)
        : probed;
    final current = offsets.isEmpty
        ? -1
        : (previousOffset == null
              ? 0
              : nearestMatchIndex(offsets, previousOffset));
    setState(() {
      _matchQuery = query;
      _matchOffsets = offsets;
      _matchTruncated = truncated;
      _currentMatchIndex = current;
      _contentController.updateMatches(
        offsets: offsets,
        current: current,
        length: query.length,
      );
    });
    if (scrollToMatch && current >= 0) {
      _scrollToMatch(offsets[current]);
    }
  }

  void _stepMatch({required bool forward}) {
    final total = _matchOffsets.length;
    if (total == 0) return;
    final next = nextMatchIndex(_currentMatchIndex, total, forward: forward);
    setState(() {
      _currentMatchIndex = next;
      _contentController.updateMatches(
        offsets: _matchOffsets,
        current: next,
        length: _matchQuery.length,
      );
    });
    _scrollToMatch(_matchOffsets[next]);
  }

  void _toggleFindBar() {
    final visible = !_findBarVisible;
    setState(() => _findBarVisible = visible);
    if (visible) {
      // 关了再开保留上次的查询词。
      if (_findController.text.isNotEmpty) {
        _runSearch(_findController.text);
      }
      return;
    }
    setState(() {
      _matchQuery = '';
      _matchOffsets = const [];
      _matchTruncated = false;
      _currentMatchIndex = -1;
      _contentController.updateMatches(
        offsets: const [],
        current: -1,
        length: 0,
      );
    });
  }

  /// 把命中滚进视口：问 TextField 自己的 RenderEditable 要真实 y，与行号栏同一份排版。
  void _scrollToMatch(int offset) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_contentScrollController.hasClients) return;
      final editable = findScriptRenderEditable(_editorKey.currentContext);
      if (editable == null || !editable.hasSize) return;
      final top = scriptContentTopForOffset(editable, offset);
      final position = _contentScrollController.position;
      final target = (top - position.viewportDimension / 3).clamp(
        0.0,
        position.maxScrollExtent,
      );
      _contentScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final editable = !_loading && _loadError == null;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final editorBackground =
        _editorBackgroundColor ??
        (isDark ? const Color(0xFF1E1E1E) : Colors.white);
    final onDarkEditor = editorBackground.computeLuminance() < 0.45;
    final editorForeground = onDarkEditor
        ? const Color(0xFFD4D4D4)
        : AppColors.slate900;
    // 与 ScriptViewPage._editorTextStyle 同一组参数：影响度量的字段全部钉死、
    // 跟上系统「粗体文字」，行号栏和代码才是同一行高、同一基线（原因见那里的注释）。
    final baseStyle = TextStyle(
      fontSize: 13,
      fontFamily: 'monospace',
      height: 1.5,
      fontWeight: FontWeight.w400,
      fontStyle: FontStyle.normal,
      letterSpacing: 0,
      wordSpacing: 0,
      textBaseline: TextBaseline.alphabetic,
      leadingDistribution: TextLeadingDistribution.even,
      color: editorForeground,
    );
    final textStyle = MediaQuery.boldTextOf(context)
        ? baseStyle.merge(const TextStyle(fontWeight: FontWeight.bold))
        : baseStyle;
    final strutStyle = StrutStyle.fromTextStyle(
      textStyle,
      forceStrutHeight: true,
    );

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _confirmLeave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('配置文件'),
          actions: [
            if (editable)
              IconButton(
                onPressed: _toggleFindBar,
                icon: Icon(_findBarVisible ? Icons.search_off : Icons.search),
                tooltip: _findBarVisible ? '关闭查找' : '查找',
              ),
            if (editable)
              IconButton(
                onPressed: _dirty && !_saving ? _save : null,
                tooltip: '保存',
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
              ),
          ],
        ),
        body: _loading
            ? const Center(
                child: CircularProgressIndicator(color: AppColors.primary),
              )
            : _loadError != null
            ? SingleChildScrollView(
                child: AppErrorView(
                  title: '配置文件加载失败',
                  message: _loadError!,
                  onRetry: _load,
                ),
              )
            : Column(
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Text(
                      _dirty ? '$_path · 有未保存的修改' : _path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: _dirty
                            ? AppColors.amber500
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (_findBarVisible)
                    ScriptFindBar(
                      controller: _findController,
                      matchCount: _matchOffsets.length,
                      currentIndex: _currentMatchIndex,
                      truncated: _matchTruncated,
                      onChanged: _runSearch,
                      onPrevious: () => _stepMatch(forward: false),
                      onNext: () => _stepMatch(forward: true),
                      onClose: _toggleFindBar,
                    ),
                  Expanded(
                    child: AppCard(
                      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      // 内边距由 InputDecoration.contentPadding 提供，卡片不再补一层。
                      padding: EdgeInsets.zero,
                      radius: AppRadius.md,
                      color: editorBackground,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              ScriptLineNumberGutter(
                                controller: _contentController,
                                editorKey: _editorKey,
                                editorWidth: constraints.maxWidth,
                                scrollController: _contentScrollController,
                                textStyle: textStyle,
                                strutStyle: strutStyle,
                                textScaler: MediaQuery.textScalerOf(context),
                                color: onDarkEditor
                                    ? AppColors.editorGutterOnDark
                                    : AppColors.editorGutterOnLight,
                                verticalPadding: _editorContentPadding.top,
                              ),
                              Expanded(
                                child: TextSelectionTheme(
                                  data: TextSelectionThemeData(
                                    selectionColor: AppColors.primary
                                        .withAlpha(60),
                                  ),
                                  child: TextField(
                                    key: _editorKey,
                                    controller: _contentController,
                                    scrollController: _contentScrollController,
                                    expands: true,
                                    maxLines: null,
                                    style: textStyle,
                                    strutStyle: strutStyle,
                                    cursorColor: editorForeground,
                                    selectionHeightStyle: BoxHeightStyle.max,
                                    // 三个 border 要一起关、filled 写死 false，
                                    // 原因见 ScriptViewPage 编辑器 InputDecoration 的注释。
                                    decoration: const InputDecoration(
                                      border: InputBorder.none,
                                      enabledBorder: InputBorder.none,
                                      focusedBorder: InputBorder.none,
                                      contentPadding: _editorContentPadding,
                                      filled: false,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
