import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/network/api_endpoints.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/utils/log_background.dart';
import '../../../shared/utils/log_line_buffer.dart';
import '../../../shared/widgets/fullscreen_log_scaffold.dart';

/// 面板日志的一组筛选条件：级别、服务端关键字、拉取的尾部行数。
typedef _PanelLogFilter = ({String level, String keyword, int lines});

/// 面板端单次最多返回的行数。
///
/// 超过它面板不报错，而是悄悄退回默认的 100 行（system.go `PanelLog`），
/// 所以自定义行数要在这边先夹进 1 ~ 10000。
const int _kPanelLogMaxLines = 10000;

const List<(String, String)> _kLevels = [
  ('', '全部级别'),
  ('info', '仅 INFO'),
  ('warn', '仅 WARN'),
  ('error', '仅 ERROR'),
  ('debug', '仅 DEBUG'),
];

const List<int> _kLineOptions = [300, 1000, 3000];

/// 面板系统日志页（v3.0 全屏沉浸式阅读器 + 级别 / 关键字 / 行数筛选弹层）。
class PanelLogPage extends StatefulWidget {
  const PanelLogPage({super.key});

  @override
  State<PanelLogPage> createState() => _PanelLogPageState();
}

class _PanelLogPageState extends State<PanelLogPage> {
  bool _loading = true;
  bool _loadFailed = false;
  String _selectedLevel = '';

  /// 交给面板在整份日志里筛的关键字（区分大小写）。
  ///
  /// 和阅读器自带的页内搜索不是一回事：页内搜索只在已经拉下来的尾部几千行里
  /// 高亮跳转；这里是面板扫完整个 panel.log、只回最近 N 条命中行，
  /// 更早的 scheduler / update 记录只有这样才取得回来。
  String _keyword = '';
  int _selectedLines = 300;
  final _log = LogLineBuffer();
  Color? _logBackgroundColor;

  /// 每次 [_load] 加一。改了筛选条件马上重拉时，上一次的请求可能还在路上，
  /// 只认最后一次发出的，免得旧条件的结果晚到、盖掉新结果。
  int _loadSeq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _log.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final seq = ++_loadSeq;
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      final logResponse = await DioClient.instance.dio.get(
        ApiEndpoints.panelLog,
        queryParameters: {
          if (_selectedLevel.isNotEmpty) 'level': _selectedLevel,
          if (_keyword.isNotEmpty) 'keyword': _keyword,
          'lines': _selectedLines,
        },
      );
      final backgroundColor = await loadPanelLogBackgroundColor();
      final data = extractData(logResponse.data);
      if (!mounted || seq != _loadSeq) return;

      String content = '';
      if (data is Map<String, dynamic>) {
        final rawLogs = data['logs'];
        if (rawLogs is List) {
          content = rawLogs
              .map((item) => item.toString())
              .where((line) => line.isNotEmpty)
              .join('\n');
        } else {
          content = data['content']?.toString() ?? '';
        }
      } else {
        content = data?.toString() ?? '';
      }

      final lines = content.replaceAll('\r\n', '\n').split('\n');
      if (lines.isNotEmpty && lines.last.isEmpty) {
        lines.removeLast();
      }
      setState(() {
        _log.replaceAll(lines);
        _logBackgroundColor = backgroundColor;
        _loading = false;
        _loadFailed = false;
      });
    } catch (error) {
      if (!mounted || seq != _loadSeq) return;
      final message = extractErrorMessage(error, '加载面板日志失败');
      setState(() {
        _log.replaceAll([message]);
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  Future<void> _showFilterSheet() async {
    // isScrollControlled：默认弹层最高只占屏幕 9/16，360dp 小屏或大字号下
    // 「应用并刷新」会被挤出弹层、看不见也点不到；内容自己负责滚动。
    final result = await showModalBottomSheet<_PanelLogFilter>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => _PanelLogFilterSheet(
        initial: (
          level: _selectedLevel,
          keyword: _keyword,
          lines: _selectedLines,
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _selectedLevel = result.level;
      _keyword = result.keyword;
      _selectedLines = result.lines;
    });
    await _load();
  }

  /// 副标题 / 菜单里展示用的关键字，过长时截断，避免挤掉级别与行数。
  String get _keywordLabel {
    final runes = _keyword.runes.toList();
    if (runes.length <= 12) return _keyword;
    return '${String.fromCharCodes(runes.take(12))}…';
  }

  @override
  Widget build(BuildContext context) {
    final levelText = _selectedLevel.isEmpty
        ? '全部级别'
        : _selectedLevel.toUpperCase();
    final keywordText = _keyword.isEmpty ? '' : ' · 含「$_keywordLabel」';

    return FullscreenLogScaffold(
      title: '面板日志',
      subtitle: '$levelText$keywordText · 最近 $_selectedLines 行',
      statusLabel: _loading
          ? '加载中'
          : _loadFailed
          ? '读取失败'
          : '系统日志',
      statusTone: _loading
          ? FullscreenLogTone.running
          : _loadFailed
          ? FullscreenLogTone.failed
          : FullscreenLogTone.neutral,
      buffer: _log,
      loading: _loading,
      follow: false,
      emptyMessage: _keyword.isEmpty
          ? '暂无面板日志内容'
          : '没有包含「$_keywordLabel」的日志',
      configuredBackgroundColor: _logBackgroundColor,
      onRerun: _load,
      rerunBusy: _loading,
      rerunLabel: '刷新日志',
      extraMenuEntries: [
        FullscreenLogMenuEntry(
          id: 'filter_panel_log',
          label: '筛选日志 ($levelText$keywordText / $_selectedLines 行)',
          icon: Icons.tune_rounded,
          onTap: _showFilterSheet,
        ),
      ],
      copySuccessToast: '已复制面板日志内容',
    );
  }
}

/// 筛选弹层。输入框控制器由弹层自己持有、在 [State.dispose] 里释放：
/// 弹层关闭后还要走退场动画，提前释放会在失焦重建时撞上「used after disposed」。
class _PanelLogFilterSheet extends StatefulWidget {
  const _PanelLogFilterSheet({required this.initial});

  final _PanelLogFilter initial;

  @override
  State<_PanelLogFilterSheet> createState() => _PanelLogFilterSheetState();
}

class _PanelLogFilterSheetState extends State<_PanelLogFilterSheet> {
  late String _level = widget.initial.level;

  /// 最近一次点选的快捷档；自定义行数为空或无效时用它。
  late int _presetLines = _kLineOptions.contains(widget.initial.lines)
      ? widget.initial.lines
      : _kLineOptions.first;

  late final _keywordController = TextEditingController(
    text: widget.initial.keyword,
  );

  /// 上次用的是快捷档以外的行数，就回填到自定义框里。
  late final _linesController = TextEditingController(
    text: _kLineOptions.contains(widget.initial.lines)
        ? ''
        : '${widget.initial.lines}',
  );

  @override
  void dispose() {
    _keywordController.dispose();
    _linesController.dispose();
    super.dispose();
  }

  /// 实际要拉的行数：自定义框里有合法数字就用它（夹到面板上限），否则用快捷档。
  int get _effectiveLines {
    final custom = int.tryParse(_linesController.text.trim());
    if (custom == null || custom <= 0) return _presetLines;
    return math.min(custom, _kPanelLogMaxLines);
  }

  void _apply() {
    // 连点两下时第一下已经关掉弹层，第二下若再 pop 会把日志页一起弹掉。
    if (ModalRoute.isCurrentOf(context) != true) return;
    Navigator.of(context).pop<_PanelLogFilter>((
      level: _level,
      keyword: _keywordController.text.trim(),
      lines: _effectiveLines,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final lines = _effectiveLines;
    final labelStyle = AppText.caption.copyWith(color: p.text2);
    final hintStyle = AppText.meta.copyWith(color: p.text2);

    return Padding(
      // 键盘弹起时把内容整体顶上去，输入框和按钮不被挡住。
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '筛选面板日志',
                style: AppText.cardTitle.copyWith(color: p.text),
              ),
              const SizedBox(height: 14),
              Text('日志级别', style: labelStyle),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (value, label) in _kLevels)
                    ChoiceChip(
                      label: Text(label),
                      selected: _level == value,
                      onSelected: (_) => setState(() => _level = value),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text('关键字', style: labelStyle),
              const SizedBox(height: 8),
              TextField(
                key: const Key('panel-log-keyword'),
                controller: _keywordController,
                textInputAction: TextInputAction.search,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _apply(),
                decoration: InputDecoration(
                  hintText: '比如 update / scheduler / ERROR',
                  prefixIcon: const Icon(Icons.search_rounded, size: 18),
                  suffixIcon: _keywordController.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清空关键字',
                          icon: const Icon(Icons.close_rounded, size: 18),
                          onPressed: () =>
                              setState(_keywordController.clear),
                        ),
                ),
              ),
              const SizedBox(height: 6),
              Text('由面板在整份日志里筛选，区分大小写', style: hintStyle),
              const SizedBox(height: 16),
              Text('拉取尾部行数', style: labelStyle),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final count in _kLineOptions)
                    ChoiceChip(
                      label: Text('最近 $count 行'),
                      selected: lines == count,
                      onSelected: (_) => setState(() {
                        _presetLines = count;
                        _linesController.clear();
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('panel-log-lines'),
                controller: _linesController,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(5),
                ],
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _apply(),
                decoration: const InputDecoration(
                  hintText: '自定义行数',
                  suffixText: '行',
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '面板单次最多返回 $_kPanelLogMaxLines 行，本次拉取 $lines 行',
                style: AppText.tabular(hintStyle),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: FilledButton(
                  onPressed: _apply,
                  child: const Text('应用并刷新'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
