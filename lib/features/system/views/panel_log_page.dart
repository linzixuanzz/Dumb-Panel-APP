import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/network/api_endpoints.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/utils/log_background.dart';
import '../../../shared/utils/log_line_buffer.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/app_snack.dart';
import '../../../shared/widgets/log_view.dart';

class PanelLogPage extends StatefulWidget {
  const PanelLogPage({super.key});

  @override
  State<PanelLogPage> createState() => _PanelLogPageState();
}

class _PanelLogPageState extends State<PanelLogPage> {
  final _keywordController = TextEditingController();
  final _linesController = TextEditingController(text: '300');

  bool _loading = true;
  String _selectedLevel = '';

  /// 完整原文，只给「复制」用；显示走 [_log] 按行懒渲染。
  /// 「行数」是用户自己填的，填个几万行时整段铺成一棵 TextSpan 会直接卡住。
  String _content = '';
  final _log = LogLineBuffer();
  Color? _logBackgroundColor;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _keywordController.dispose();
    _linesController.dispose();
    _log.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final logResponse = await DioClient.instance.dio.get(
        ApiEndpoints.panelLog,
        queryParameters: {
          if (_selectedLevel.trim().isNotEmpty) 'level': _selectedLevel.trim(),
          if (_keywordController.text.trim().isNotEmpty)
            'keyword': _keywordController.text.trim(),
          'lines': int.tryParse(_linesController.text.trim()) ?? 300,
        },
      );
      final backgroundColor = await loadPanelLogBackgroundColor();
      final data = extractData(logResponse.data);
      if (!mounted) {
        return;
      }
      setState(() {
        if (data is Map<String, dynamic>) {
          final rawLogs = data['logs'];
          if (rawLogs is List) {
            _content = rawLogs
                .map((item) => item.toString())
                .where((line) => line.isNotEmpty)
                .join('\n');
          } else {
            _content = data['content']?.toString() ?? '';
          }
        } else {
          _content = data?.toString() ?? '';
        }
        _log.replaceAll(_content.split('\n'));
        _logBackgroundColor = backgroundColor;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _content = extractErrorMessage(error, '加载面板日志失败');
        _log.replaceAll(_content.split('\n'));
        _loading = false;
      });
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _content));
    if (!mounted) {
      return;
    }
    AppSnack.success(context, '已复制日志内容');
  }

  @override
  Widget build(BuildContext context) {
    final logTheme = resolveLogSurfaceTheme(
      _logBackgroundColor,
      themeBrightness: Theme.of(context).brightness,
    );
    final borderColor = logTheme.brightness == Brightness.dark
        ? AppColors.slate700
        : AppColors.slate200;

    return Scaffold(
      appBar: AppBar(
        title: const Text('面板日志'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            onPressed: _content.trim().isEmpty ? null : _copy,
            icon: const Icon(Icons.copy_all_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _selectedLevel,
                        decoration: const InputDecoration(labelText: '日志级别'),
                        items: const [
                          DropdownMenuItem(value: '', child: Text('全部')),
                          DropdownMenuItem(
                            value: 'debug',
                            child: Text('DEBUG'),
                          ),
                          DropdownMenuItem(value: 'info', child: Text('INFO')),
                          DropdownMenuItem(value: 'warn', child: Text('WARN')),
                          DropdownMenuItem(
                            value: 'error',
                            child: Text('ERROR'),
                          ),
                        ],
                        onChanged: (value) {
                          setState(() => _selectedLevel = value ?? '');
                          _load();
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 92,
                      child: TextField(
                        controller: _linesController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: '行数'),
                        onSubmitted: (_) => _load(),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _keywordController,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    labelText: '关键字筛选',
                    hintText: '比如 update / scheduler / ERROR',
                    suffixIcon: IconButton(
                      onPressed: _load,
                      icon: const Icon(Icons.search),
                    ),
                  ),
                  onSubmitted: (_) => _load(),
                ),
              ],
            ),
          ),
          Expanded(
            child: AppCard(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              // 内容自带 14 的滚动内边距，卡片本身不能再补一层。
              padding: EdgeInsets.zero,
              // 日志底色跟随用户设置的日志主题，与页面明暗无关，
              // 必须显式传入，不能落到 AppCard 的默认卡片底色。
              color: logTheme.background,
              borderColor: borderColor,
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: AppColors.primary,
                      ),
                    )
                  : _content.trim().isEmpty
                  ? Center(
                      child: Text(
                        '暂无日志内容',
                        style: TextStyle(color: logTheme.mutedForeground),
                      ),
                    )
                  // 一次性加载的静态日志：从顶部开始看，不跟随。
                  // 顺带修掉了原来 RichText 不接 SelectionArea、长按选不中的问题
                  // （LogView 每行用的是 Text.rich，会自动挂到选择区域上）。
                  : LogView(
                      buffer: _log,
                      follow: false,
                      padding: const EdgeInsets.all(14),
                      textStyle: TextStyle(
                        color: logTheme.foreground,
                        fontFamily: 'monospace',
                        fontSize: 12,
                        height: 1.55,
                      ),
                      brightness: logTheme.brightness,
                      mutedColor: logTheme.mutedForeground,
                      truncatedHint: '可以用右上角的复制拿到全部内容',
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
