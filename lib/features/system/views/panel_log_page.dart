import 'package:flutter/material.dart';

import '../../../core/network/api_endpoints.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/utils/log_background.dart';
import '../../../shared/utils/log_line_buffer.dart';
import '../../../shared/widgets/fullscreen_log_scaffold.dart';

/// 面板系统日志页（v3.0 全屏沉浸式阅读器 + 级别/行数轻量化筛选菜单）。
class PanelLogPage extends StatefulWidget {
  const PanelLogPage({super.key});

  @override
  State<PanelLogPage> createState() => _PanelLogPageState();
}

class _PanelLogPageState extends State<PanelLogPage> {
  static const List<(String, String)> _levels = [
    ('', '全部级别'),
    ('info', '仅 INFO'),
    ('warn', '仅 WARN'),
    ('error', '仅 ERROR'),
    ('debug', '仅 DEBUG'),
  ];

  static const List<int> _lineOptions = [300, 1000, 3000];

  bool _loading = true;
  bool _loadFailed = false;
  String _selectedLevel = '';
  int _selectedLines = 300;
  final _log = LogLineBuffer();
  Color? _logBackgroundColor;

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
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      final logResponse = await DioClient.instance.dio.get(
        ApiEndpoints.panelLog,
        queryParameters: {
          if (_selectedLevel.isNotEmpty) 'level': _selectedLevel,
          'lines': _selectedLines,
        },
      );
      final backgroundColor = await loadPanelLogBackgroundColor();
      final data = extractData(logResponse.data);
      if (!mounted) return;

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
      if (!mounted) return;
      final message = extractErrorMessage(error, '加载面板日志失败');
      setState(() {
        _log.replaceAll([message]);
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  Future<void> _showFilterSheet() async {
    final result = await showModalBottomSheet<(String, int)>(
      context: context,
      useSafeArea: true,
      builder: (ctx) {
        var draftLevel = _selectedLevel;
        var draftLines = _selectedLines;
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final p = context.palette;
            return Padding(
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
                  Text(
                    '日志级别',
                    style: AppText.caption.copyWith(color: p.text2),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (value, label) in _levels)
                        ChoiceChip(
                          label: Text(label),
                          selected: draftLevel == value,
                          onSelected: (_) =>
                              setSheetState(() => draftLevel = value),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '拉取尾部行数',
                    style: AppText.caption.copyWith(color: p.text2),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final count in _lineOptions)
                        ChoiceChip(
                          label: Text('最近 $count 行'),
                          selected: draftLines == count,
                          onSelected: (_) =>
                              setSheetState(() => draftLines = count),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: FilledButton(
                      onPressed: () =>
                          Navigator.of(ctx).pop((draftLevel, draftLines)),
                      child: const Text('应用并刷新'),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
    if (result == null || !mounted) return;
    setState(() {
      _selectedLevel = result.$1;
      _selectedLines = result.$2;
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final levelText = _selectedLevel.isEmpty
        ? '全部级别'
        : _selectedLevel.toUpperCase();

    return FullscreenLogScaffold(
      title: '面板日志',
      subtitle: '$levelText · 最近 $_selectedLines 行',
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
      emptyMessage: '暂无面板日志内容',
      configuredBackgroundColor: _logBackgroundColor,
      onRerun: _load,
      rerunBusy: _loading,
      rerunLabel: '刷新日志',
      extraMenuEntries: [
        FullscreenLogMenuEntry(
          id: 'filter_panel_log',
          label: '筛选级别与行数 ($levelText / $_selectedLines 行)',
          icon: Icons.tune_rounded,
          onTap: _showFilterSheet,
        ),
      ],
      copySuccessToast: '已复制面板日志内容',
    );
  }
}
