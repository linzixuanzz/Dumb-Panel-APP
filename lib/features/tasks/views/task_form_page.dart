import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/api_endpoints.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/models/python_runtime_info.dart';
import '../../../shared/models/task.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/utils/time_utils.dart';
import '../../../shared/widgets/app_card.dart';
import '../utils/cron_schema.dart';
import '../providers/task_provider.dart';

class TaskFormPrefill {
  final String name;
  final String command;
  final String? taskType;
  final String? cronExpression;

  const TaskFormPrefill({
    required this.name,
    required this.command,
    this.taskType,
    this.cronExpression,
  });
}

class TaskFormPage extends ConsumerStatefulWidget {
  final Task? task;
  final TaskFormPrefill? prefill;

  const TaskFormPage({super.key, this.task, this.prefill});

  @override
  ConsumerState<TaskFormPage> createState() => _TaskFormPageState();
}

enum _RandomDelayMode { inherit, disabled, custom }

/// 直接铺在 Cron 输入框下方的快捷模板数量，其余收进「更多规则」面板。
///
/// 面板一共 21 条，全铺开会顶掉小半屏表单；6 条正好占两行。
/// 取的是**面板返回的前 6 条**，不按 APP 自己的偏好重排 —— `GetTemplates()`
/// 是一个手写有序数组（高频 → 常用 → 每天 → … → 秒级），顺序本身就是面板对
/// 「哪些最常用」的表态。APP 再挑一遍就等于把刚搬走的判断又搬回来。
/// 面板日后调整顺序，这里自动跟上。
const int _kInlineCronTemplateCount = 6;

class _TaskNotificationChannel {
  final int id;
  final String name;
  final String type;
  final bool enabled;

  const _TaskNotificationChannel({
    required this.id,
    required this.name,
    required this.type,
    required this.enabled,
  });

  factory _TaskNotificationChannel.fromJson(Map<String, dynamic> json) {
    return _TaskNotificationChannel(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name']?.toString() ?? '',
      type: json['type']?.toString() ?? '',
      enabled: json['enabled'] == true,
    );
  }
}

class _TaskFormPageState extends ConsumerState<TaskFormPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameC;
  late final TextEditingController _commandC;
  late final TextEditingController _cronC;
  late final TextEditingController _timeoutC;
  late final TextEditingController _randomDelayC;
  late final TextEditingController _retriesC;
  late final TextEditingController _retryIntervalC;
  late final TextEditingController _dependsOnC;
  late final TextEditingController _taskBeforeC;
  late final TextEditingController _taskAfterC;
  late final TextEditingController _labelC;
  late final TextEditingController _groupC;

  bool _saving = false;
  bool _loadingChannels = false;
  bool _loadingPythonRuntimes = false;
  String _taskType = 'cron';
  bool _notifyOnFailure = true;
  bool _notifyOnSuccess = false;
  bool _allowMultipleInstances = false;
  String _pythonVersion = '3.12';
  String _pythonDefaultVersion = '3.12';
  int? _notificationChannelId;
  _RandomDelayMode _randomDelayMode = _RandomDelayMode.inherit;
  final List<String> _labels = [];
  List<_TaskNotificationChannel> _notificationChannels = const [];
  List<PythonRuntimeInfo> _pythonRuntimes = const [];
  bool _showHooks = false;
  List<String> _knownGroups = const [];

  /// Cron 模板。默认就是老的 3 条硬编码，拉到面板的 21 条后整体替换。
  List<CronTemplate> _cronTemplates = kFallbackCronTemplates;

  /// 每一行 cron 表达式的解析结果（下标与 [splitCronExpressions] 对齐）。
  /// 拿不到结果的行不入表，UI 上就是不显示提示，不显示任何错误。
  Map<int, CronParseResult> _cronParseResults = const {};
  Timer? _cronParseDebounce;

  /// 丢弃过期响应用的世代号。用户连打几个字会发出多轮请求，
  /// 没有它就可能出现「先发的慢请求后到，把新表达式的结论覆盖掉」。
  int _cronParseGeneration = 0;

  bool get isEditing => widget.task != null;

  @override
  void initState() {
    super.initState();
    final task = widget.task;
    final prefill = widget.prefill;
    _nameC = TextEditingController(text: task?.name ?? prefill?.name ?? '');
    _commandC = TextEditingController(
      text: task?.command ?? prefill?.command ?? '',
    );
    _cronC = TextEditingController(
      text: task?.cronExpression.isNotEmpty == true
          ? task!.cronExpression
          : (prefill?.cronExpression ?? '0 0 * * *'),
    );
    _timeoutC = TextEditingController(text: '${task?.timeout ?? 0}');
    _randomDelayC = TextEditingController(
      text: '${task?.randomDelaySeconds ?? 60}',
    );
    _retriesC = TextEditingController(text: '${task?.maxRetries ?? 0}');
    _retryIntervalC = TextEditingController(
      text: '${task?.retryInterval ?? 60}',
    );
    _dependsOnC = TextEditingController(
      text: task?.dependsOn?.toString() ?? '',
    );
    _taskBeforeC = TextEditingController(text: task?.taskBefore ?? '');
    _taskAfterC = TextEditingController(text: task?.taskAfter ?? '');
    _labelC = TextEditingController();
    _groupC = TextEditingController(text: task?.groupName ?? '');

    _taskType = task?.taskType ?? prefill?.taskType ?? 'cron';
    _pythonVersion = task?.pythonVersion ?? '3.12';
    _notifyOnFailure = task?.notifyOnFailure ?? true;
    _notifyOnSuccess = task?.notifyOnSuccess ?? false;
    _allowMultipleInstances = task?.allowMultipleInstances ?? false;
    _notificationChannelId = task?.notificationChannelId;
    _labels
      ..clear()
      ..addAll(task?.userLabelsForDisplay ?? const []);
    _randomDelayMode = _resolveRandomDelayMode(task?.randomDelaySeconds);
    _showHooks = _taskBeforeC.text.isNotEmpty || _taskAfterC.text.isNotEmpty;

    Future.microtask(() async {
      await Future.wait([
        _loadNotificationChannels(),
        _loadKnownGroups(),
        _loadPythonRuntimes(),
        _loadCronTemplates(),
      ]);
    });
    // 进页面就解析一次：编辑已有任务时用户还没动键盘，也应该能看到下次执行时间。
    _scheduleCronParse(immediate: true);
  }

  @override
  void dispose() {
    _cronParseDebounce?.cancel();
    for (final c in [
      _nameC,
      _commandC,
      _cronC,
      _timeoutC,
      _randomDelayC,
      _retriesC,
      _retryIntervalC,
      _dependsOnC,
      _taskBeforeC,
      _taskAfterC,
      _labelC,
      _groupC,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  _RandomDelayMode _resolveRandomDelayMode(int? v) {
    if (v == null) return _RandomDelayMode.inherit;
    if (v <= 0) return _RandomDelayMode.disabled;
    return _RandomDelayMode.custom;
  }

  Future<void> _loadNotificationChannels() async {
    setState(() => _loadingChannels = true);
    try {
      final resp = await DioClient.instance.dio.get(
        ApiEndpoints.notificationChannels,
      );
      final data = extractData(resp.data);
      final channels = data is List
          ? data
                .whereType<Map>()
                .map(
                  (m) => _TaskNotificationChannel.fromJson(
                    Map<String, dynamic>.from(m),
                  ),
                )
                .toList()
          : <_TaskNotificationChannel>[];
      if (!mounted) return;
      setState(() {
        _notificationChannels = channels;
        _loadingChannels = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingChannels = false);
    }
  }

  Future<void> _loadKnownGroups() async {
    try {
      final response = await DioClient.instance.dio.get(
        ApiEndpoints.tasks,
        // 面板上限 100，超了静默回落到 20（server/handler/task_query.go:52-54）。
        // 这里只用来收集已有分组名做候选，原来写 200 等于只看了前 20 个任务的分组。
        queryParameters: {'page': 1, 'page_size': 100},
      );
      final paginated = extractPaginated(response.data);
      final groups =
          paginated.items
              .map((item) => Task.fromJson(item).groupName?.trim() ?? '')
              .where((group) => group.isNotEmpty)
              .toSet()
              .toList()
            ..sort();
      if (!mounted) {
        return;
      }
      setState(() => _knownGroups = groups);
    } catch (_) {}
  }

  Future<void> _loadPythonRuntimes() async {
    // 新建任务时，默认 Python 版本必须跟随后端默认版本，而不是继续写死 3.12。
    setState(() => _loadingPythonRuntimes = true);
    try {
      final response = await DioClient.instance.dio.get(
        ApiEndpoints.depsPythonRuntimes,
      );
      final raw = response.data;
      final map = raw is Map<String, dynamic>
          ? raw
          : raw is Map
          ? Map<String, dynamic>.from(raw)
          : <String, dynamic>{};
      final runtimeData = map['data'];
      final runtimes = runtimeData is List
          ? runtimeData
                .whereType<Map>()
                .map(
                  (item) => PythonRuntimeInfo.fromJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .where((item) => item.version.trim().isNotEmpty)
                .toList()
          : <PythonRuntimeInfo>[];
      final defaultVersion =
          map['default_version']?.toString().trim().isNotEmpty == true
          ? map['default_version'].toString().trim()
          : '3.12';
      final currentExists = runtimes.any(
        (runtime) => runtime.version == _pythonVersion,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _pythonRuntimes = runtimes;
        _pythonDefaultVersion = defaultVersion;
        // 编辑已有任务时保留原值；新建任务时直接跟随后端默认版本。
        if (isEditing) {
          if (!currentExists && runtimes.isNotEmpty) {
            _pythonVersion = widget.task?.pythonVersion ?? defaultVersion;
          }
        } else {
          _pythonVersion = defaultVersion;
        }
        _loadingPythonRuntimes = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _loadingPythonRuntimes = false);
      }
    }
  }

  /// 拉面板的 cron 模板（21 条 / 7 个分组）。
  ///
  /// 任何异常都静默保留 [kFallbackCronTemplates] —— 这个端点在老面板上可能
  /// 不存在，而「模板按钮少几个」不值得给用户弹一条错误。这就是 design.md §4.1
  /// 层 1 的形状探测：拿到列表就用，拿不到就用冻结的最小集。
  Future<void> _loadCronTemplates() async {
    try {
      final response = await DioClient.instance.dio.get(
        ApiEndpoints.cronTemplates,
      );
      final templates = parseCronTemplates(response.data);
      if (!mounted || templates.isEmpty) {
        return;
      }
      setState(() => _cronTemplates = templates);
    } catch (_) {}
  }

  void _scheduleCronParse({bool immediate = false}) {
    _cronParseDebounce?.cancel();
    if (immediate) {
      unawaited(_runCronParse());
      return;
    }
    // 600ms：比连续打字的间隔长，比「填完一条表达式停下来看结果」的等待短。
    _cronParseDebounce = Timer(
      const Duration(milliseconds: 600),
      () => unawaited(_runCronParse()),
    );
  }

  /// 逐条问面板「这条 cron 合不合法、下次什么时候跑」。
  ///
  /// 为什么调接口而不是在 APP 里自己解析（design.md §6.c 第 5 条）：
  /// cron 的合法性规则、5 位/6 位格式判定、以及「下次执行时间」都在面板的
  /// robfig/cron 里，且要按**面板的时区**算。APP 本地算出来的时间和面板真正
  /// 触发的时间对不上，比不显示更糟。
  ///
  /// 逐行发是因为面板 `pkg/cron.Parse` 只吃**单条**表达式（cron.go:53-73），
  /// 多行文本发过去必然报错。上限 5 条，够用且不会因为用户贴了 50 行而打爆面板。
  Future<void> _runCronParse() async {
    final generation = ++_cronParseGeneration;
    if (_taskType != 'cron') {
      if (mounted && _cronParseResults.isNotEmpty) {
        setState(() => _cronParseResults = const {});
      }
      return;
    }
    final expressions = splitCronExpressions(_cronC.text).take(5).toList();
    if (expressions.isEmpty) {
      if (mounted && _cronParseResults.isNotEmpty) {
        setState(() => _cronParseResults = const {});
      }
      return;
    }

    final results = await Future.wait(
      expressions.map(_parseSingleCron),
      eagerError: false,
    );
    if (!mounted || generation != _cronParseGeneration) {
      return;
    }
    final next = <int, CronParseResult>{};
    for (var i = 0; i < results.length; i++) {
      final result = results[i];
      if (result != null) {
        next[i] = result;
      }
    }
    setState(() => _cronParseResults = next);
  }

  Future<CronParseResult?> _parseSingleCron(String expression) async {
    try {
      final response = await DioClient.instance.dio.post(
        ApiEndpoints.cronParse,
        data: {'expression': expression},
      );
      return CronParseResult.fromJson(response.data);
    } catch (_) {
      // 端点不存在 / 断网 / 400 —— 一律当作「没有结论」，不显示提示也不报错。
      // 表达式真的非法时，保存那一步面板会给出「第 N 条定时规则无效: ...」。
      return null;
    }
  }

  void _applyCronTemplate(CronTemplate template) {
    final current = _cronC.text.trim();
    _cronC.text = current.isEmpty
        ? template.expression
        : '$current\n${template.expression}';
    _scheduleCronParse(immediate: true);
  }

  Future<void> _showCronTemplateSheet() async {
    final groups = groupCronTemplates(_cronTemplates);
    final selected = await showModalBottomSheet<CronTemplate>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useRootNavigator: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        return SizedBox(
          height: MediaQuery.of(sheetContext).size.height * 0.7,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  '选择定时规则',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                  children: [
                    for (final group in groups) ...[
                      if (group.category.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 6),
                          child: Text(
                            group.category,
                            style: theme.textTheme.labelLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      for (final template in group.templates)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            template.name,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            template.description.isEmpty
                                ? template.expression
                                : '${template.expression} · ${template.description}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          onTap: () =>
                              Navigator.of(sheetContext).pop(template),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
    // 面板挑完模板回来时页面可能已经被 pop 掉了，`_cronC` 那时已 dispose，
    // 再往里写字会抛。
    if (selected != null && mounted) {
      _applyCronTemplate(selected);
    }
  }

  void _addLabel() {
    final label = _labelC.text.trim();
    if (label.isEmpty || _labels.contains(label)) {
      _labelC.clear();
      return;
    }
    setState(() {
      _labels.add(label);
      _labelC.clear();
    });
  }

  int _parseInt(TextEditingController c, int fb) =>
      int.tryParse(c.text.trim()) ?? fb;

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    if (_labelC.text.trim().isNotEmpty) {
      _addLabel();
    }

    final randomDelay = switch (_randomDelayMode) {
      _RandomDelayMode.inherit => null,
      _RandomDelayMode.disabled => 0,
      _RandomDelayMode.custom => int.tryParse(_randomDelayC.text.trim()),
    };

    if (_randomDelayMode == _RandomDelayMode.custom &&
        (randomDelay == null || randomDelay <= 0)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请输入大于 0 的随机延迟秒数')));
      return;
    }

    final normalizedLabels = <String>[
      ..._labels.where((label) => !Task.isGroupLabel(label)),
    ];
    final groupName = _groupC.text.trim();
    if (groupName.isNotEmpty) {
      normalizedLabels.add(Task.toGroupLabel(groupName));
    }

    final data = <String, dynamic>{
      'name': _nameC.text.trim(),
      'command': _commandC.text.trim(),
      'cron_expression': _taskType == 'cron' ? _cronC.text.trim() : '',
      'task_type': _taskType,
      'python_version': _pythonVersion,
      'timeout': _parseInt(_timeoutC, 0),
      'random_delay_seconds': randomDelay,
      'max_retries': _parseInt(_retriesC, 0),
      'retry_interval': _parseInt(_retryIntervalC, 60),
      'notify_on_failure': _notifyOnFailure,
      'notify_on_success': _notifyOnSuccess,
      'notification_channel_id': _notificationChannelId,
      'labels': normalizedLabels,
      'depends_on': int.tryParse(_dependsOnC.text.trim()),
      'task_before': _taskBeforeC.text.trim(),
      'task_after': _taskAfterC.text.trim(),
      'allow_multiple_instances': _allowMultipleInstances,
    };

    setState(() => _saving = true);
    try {
      if (isEditing) {
        await DioClient.instance.dio.put(
          ApiEndpoints.taskById(widget.task!.id),
          data: data,
        );
      } else {
        await DioClient.instance.dio.post(ApiEndpoints.tasks, data: data);
      }
      await ref.read(taskProvider.notifier).load(refresh: true);
      if (mounted) context.pop();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(extractErrorMessage(error, '保存失败'))),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  List<_TaskNotificationChannel> get _channelOptions {
    final list = [..._notificationChannels];
    final sid = _notificationChannelId;
    if (sid != null && list.every((c) => c.id != sid)) {
      list.insert(
        0,
        _TaskNotificationChannel(
          id: sid,
          name: widget.task?.notificationChannelName ?? '渠道 #$sid',
          type: 'unknown',
          enabled: widget.task?.notificationChannelEnabled ?? false,
        ),
      );
    }
    return list;
  }

  List<DropdownMenuItem<String>> get _pythonRuntimeItems {
    if (_pythonRuntimes.isEmpty) {
      return const [
        DropdownMenuItem(value: '3.10', child: Text('Python 3.10')),
        DropdownMenuItem(value: '3.11', child: Text('Python 3.11')),
        DropdownMenuItem(value: '3.12', child: Text('Python 3.12')),
      ];
    }
    return _pythonRuntimes.map((runtime) {
      final suffix = runtime.version == _pythonDefaultVersion ? '（默认）' : '';
      final status = runtime.available ? '' : ' · 需安装';
      return DropdownMenuItem(
        value: runtime.version,
        child: Text('${runtime.label}$suffix$status'),
      );
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isNarrow = MediaQuery.of(context).size.width < 420;

    Widget section(String title, List<Widget> children) {
      return AppCard(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 14),
            ...children,
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? '编辑任务' : '新建任务'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _saving ? null : _save,
              style: FilledButton.styleFrom(minimumSize: const Size(80, 38)),
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('保存'),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              // 基本信息
              section('基本信息', [
                TextFormField(
                  controller: _nameC,
                  decoration: const InputDecoration(labelText: '任务名称'),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? '请输入任务名称' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _commandC,
                  decoration: const InputDecoration(
                    labelText: '执行命令',
                    hintText: 'task demo.py',
                  ),
                  minLines: 2,
                  maxLines: 4,
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? '请输入执行命令' : null,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _taskType,
                  decoration: const InputDecoration(labelText: '任务类型'),
                  items: const [
                    DropdownMenuItem(value: 'cron', child: Text('常规定时')),
                    DropdownMenuItem(value: 'manual', child: Text('手动运行')),
                    DropdownMenuItem(value: 'startup', child: Text('开机运行')),
                  ],
                  onChanged: (v) {
                    if (v != null) {
                      setState(() => _taskType = v);
                      _scheduleCronParse(immediate: true);
                    }
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _pythonVersion,
                  decoration: InputDecoration(
                    labelText: 'Python 版本',
                    helperText: '仅 Python 脚本使用；新建任务默认跟随面板默认 Python 版本。',
                    suffixIcon: _loadingPythonRuntimes
                        ? const Padding(
                            padding: EdgeInsets.all(14),
                            child: SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : null,
                  ),
                  items: _pythonRuntimeItems,
                  onChanged: (v) {
                    if (v != null) {
                      setState(() => _pythonVersion = v);
                    }
                  },
                ),
                if (_taskType == 'cron') ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _cronC,
                    maxLines: null,
                    minLines: 1,
                    decoration: const InputDecoration(
                      labelText: 'Cron 表达式',
                      hintText: '0 0 * * *',
                      helperText: '一行一条规则，可写多条',
                    ),
                    onChanged: (_) => _scheduleCronParse(),
                    validator: (v) =>
                        _taskType == 'cron' && (v == null || v.trim().isEmpty)
                        ? '请输入 Cron 表达式'
                        : null,
                  ),
                  _buildCronParsePreview(theme),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      // 常用几条直接放成快捷 chip，剩下的收进底部面板。
                      // 面板现在有 21 条，全平铺会把表单顶掉小半屏。
                      for (final template in _cronTemplates.take(
                        _kInlineCronTemplateCount,
                      ))
                        ActionChip(
                          label: Text(
                            template.name,
                            style: const TextStyle(fontSize: 12),
                          ),
                          tooltip: template.description.isEmpty
                              ? template.expression
                              : '${template.expression} · ${template.description}',
                          onPressed: () => _applyCronTemplate(template),
                          visualDensity: VisualDensity.compact,
                        ),
                      if (_cronTemplates.length > _kInlineCronTemplateCount)
                        ActionChip(
                          avatar: const Icon(Icons.more_horiz, size: 16),
                          label: Text(
                            '更多规则(${_cronTemplates.length})',
                            style: const TextStyle(fontSize: 12),
                          ),
                          onPressed: _showCronTemplateSheet,
                          visualDensity: VisualDensity.compact,
                        ),
                    ],
                  ),
                ],
                if (_labels.isNotEmpty || true) ...[
                  const SizedBox(height: 12),
                  _buildGroupAutocomplete(
                    controller: _groupC,
                    options: _knownGroups,
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      ..._labels.map(
                        (l) => InputChip(
                          label: Text(l, style: const TextStyle(fontSize: 12)),
                          onDeleted: () => setState(() => _labels.remove(l)),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: TextField(
                      controller: _labelC,
                      decoration: InputDecoration(
                        hintText: '添加标签',
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 10,
                        ),
                        suffixIcon: IconButton(
                          onPressed: _addLabel,
                          icon: const Icon(Icons.add, size: 16),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 36,
                            minHeight: 36,
                          ),
                        ),
                      ),
                      style: const TextStyle(fontSize: 13),
                      onSubmitted: (_) => _addLabel(),
                    ),
                  ),
                ],
              ]),

              // 执行策略
              section('执行策略', [
                if (isNarrow) ...[
                  TextFormField(
                    controller: _timeoutC,
                    decoration: const InputDecoration(
                      labelText: '超时(秒)',
                      helperText: '0 表示永不超时',
                    ),
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _retriesC,
                    decoration: const InputDecoration(labelText: '重试次数'),
                    keyboardType: TextInputType.number,
                  ),
                ] else
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _timeoutC,
                          decoration: const InputDecoration(
                            labelText: '超时(秒)',
                            helperText: '0 表示永不超时',
                          ),
                          keyboardType: TextInputType.number,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          controller: _retriesC,
                          decoration: const InputDecoration(labelText: '重试次数'),
                          keyboardType: TextInputType.number,
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 12),
                if (isNarrow) ...[
                  TextFormField(
                    controller: _retryIntervalC,
                    decoration: const InputDecoration(labelText: '重试间隔(秒)'),
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _dependsOnC,
                    decoration: const InputDecoration(labelText: '依赖任务ID'),
                    keyboardType: TextInputType.number,
                  ),
                ] else
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _retryIntervalC,
                          decoration: const InputDecoration(
                            labelText: '重试间隔(秒)',
                          ),
                          keyboardType: TextInputType.number,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          controller: _dependsOnC,
                          decoration: const InputDecoration(
                            labelText: '依赖任务ID',
                          ),
                          keyboardType: TextInputType.number,
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 14),
                Text(
                  '随机延迟',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('继承系统'),
                      selected: _randomDelayMode == _RandomDelayMode.inherit,
                      onSelected: (_) => setState(
                        () => _randomDelayMode = _RandomDelayMode.inherit,
                      ),
                    ),
                    ChoiceChip(
                      label: const Text('不延迟'),
                      selected: _randomDelayMode == _RandomDelayMode.disabled,
                      onSelected: (_) => setState(
                        () => _randomDelayMode = _RandomDelayMode.disabled,
                      ),
                    ),
                    ChoiceChip(
                      label: const Text('自定义'),
                      selected: _randomDelayMode == _RandomDelayMode.custom,
                      onSelected: (_) => setState(
                        () => _randomDelayMode = _RandomDelayMode.custom,
                      ),
                    ),
                  ],
                ),
                if (_randomDelayMode == _RandomDelayMode.custom) ...[
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _randomDelayC,
                    decoration: const InputDecoration(labelText: '延迟秒数'),
                    keyboardType: TextInputType.number,
                  ),
                ],
              ]),

              // 通知
              section('通知与并发', [
                SwitchListTile.adaptive(
                  value: _notifyOnFailure,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('失败时通知', style: TextStyle(fontSize: 14)),
                  onChanged: (v) => setState(() => _notifyOnFailure = v),
                ),
                SwitchListTile.adaptive(
                  value: _notifyOnSuccess,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('成功时通知', style: TextStyle(fontSize: 14)),
                  onChanged: (v) => setState(() => _notifyOnSuccess = v),
                ),
                SwitchListTile.adaptive(
                  value: _allowMultipleInstances,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('允许多实例', style: TextStyle(fontSize: 14)),
                  onChanged: (v) => setState(() => _allowMultipleInstances = v),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<int?>(
                  initialValue: _notificationChannelId,
                  decoration: InputDecoration(
                    labelText: '通知渠道',
                    suffixIcon: _loadingChannels
                        ? const Padding(
                            padding: EdgeInsets.all(14),
                            child: SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : null,
                  ),
                  items: [
                    const DropdownMenuItem<int?>(
                      value: null,
                      child: Text('全部启用渠道'),
                    ),
                    ..._channelOptions.map(
                      (c) => DropdownMenuItem<int?>(
                        value: c.id,
                        child: Text('${c.name} (${c.type})'),
                      ),
                    ),
                  ],
                  onChanged: (v) => setState(() => _notificationChannelId = v),
                ),
              ]),

              // 钩子脚本（折叠）
              AppCard(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 14),
                // 折叠头自带 16 内边距、展开区自带 fromLTRB(16,0,16,16)，
                // 卡片本身不能再补一层，否则折叠头的点击区会缩水。
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    InkWell(
                      // 只有折叠头可点，不能提到 AppCard.onTap ——
                      // 否则展开后点两个多行输入框也会把整块收起来。
                      onTap: () => setState(() => _showHooks = !_showHooks),
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(AppRadius.lg),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Text(
                              '钩子脚本',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (_taskBeforeC.text.isNotEmpty ||
                                _taskAfterC.text.isNotEmpty)
                              Container(
                                margin: const EdgeInsets.only(left: 8),
                                width: 6,
                                height: 6,
                                decoration: const BoxDecoration(
                                  color: AppColors.primary,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            const Spacer(),
                            Icon(
                              _showHooks
                                  ? Icons.expand_less
                                  : Icons.expand_more,
                              size: 20,
                              color: AppColors.slate400,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_showHooks)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: Column(
                          children: [
                            TextFormField(
                              controller: _taskBeforeC,
                              decoration: const InputDecoration(
                                labelText: '前置脚本',
                                hintText: '每次执行任务前运行，可写 Shell 命令或脚本路径。',
                                helperText: '任务命令和参数会作为参数传入，适合准备环境、检查变量。',
                                alignLabelWithHint: true,
                              ),
                              minLines: 3,
                              maxLines: 5,
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: _taskAfterC,
                              decoration: const InputDecoration(
                                labelText: '后置脚本',
                                hintText: '任务结束后运行，可用于清理现场或发送额外通知。',
                                helperText: '同样会收到任务命令和参数，任务失败时也会执行。',
                                alignLabelWithHint: true,
                              ),
                              minLines: 3,
                              maxLines: 5,
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Cron 表达式的解析提示：每条规则一行「描述 · 下次 时间」或错误原因。
  ///
  /// 数据全部来自面板 `POST /api/tasks/cron/parse`（含未来 5 次执行时间），
  /// APP 不做任何本地 cron 解析 —— 下次执行时间必须按面板时区算，本地算出来的
  /// 会和实际触发时刻对不上，那比不显示更误导。
  ///
  /// 拿不到结果（老面板没有这个端点 / 断网）时整块不渲染，不占位、不报错。
  Widget _buildCronParsePreview(ThemeData theme) {
    if (_cronParseResults.isEmpty) {
      return const SizedBox.shrink();
    }
    final expressions = splitCronExpressions(_cronC.text).take(5).toList();
    final showIndex = expressions.length > 1;
    final rows = <Widget>[];
    for (var i = 0; i < expressions.length; i++) {
      final result = _cronParseResults[i];
      if (result == null) {
        continue;
      }
      final prefix = showIndex ? '规则 ${i + 1}：' : '';
      final valid = result.isValid;
      final next = result.nextRunTime;
      final text = valid
          ? [
              if (result.description.isNotEmpty) result.description,
              if (next != null) '下次 ${formatTimeCn(next)}',
            ].join(' · ')
          : (result.error.isEmpty ? '表达式无效' : result.error);
      if (valid && text.isEmpty) {
        continue;
      }
      rows.add(
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                valid ? Icons.schedule_rounded : Icons.error_outline_rounded,
                size: 14,
                color: valid ? AppColors.success : AppColors.danger,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '$prefix$text',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: valid
                        ? theme.colorScheme.onSurfaceVariant
                        : AppColors.danger,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (rows.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
    );
  }

  Widget _buildGroupAutocomplete({
    required TextEditingController controller,
    required List<String> options,
  }) {
    return Autocomplete<String>(
      optionsBuilder: (textEditingValue) {
        final keyword = textEditingValue.text.trim().toLowerCase();
        if (keyword.isEmpty) {
          return options;
        }
        return options.where((group) => group.toLowerCase().contains(keyword));
      },
      onSelected: (value) => controller.text = value,
      fieldViewBuilder:
          (context, textEditingController, focusNode, onSubmitted) {
            textEditingController.value = controller.value;
            textEditingController.addListener(() {
              controller.value = textEditingController.value;
            });
            return TextField(
              controller: textEditingController,
              focusNode: focusNode,
              decoration: const InputDecoration(
                labelText: '任务分组',
                hintText: '可选已有分组或直接输入',
              ),
              onSubmitted: (_) => onSubmitted(),
            );
          },
      optionsViewBuilder: (context, onSelected, autocompleteOptions) {
        final items = autocompleteOptions.toList(growable: false);
        if (items.isEmpty) {
          return const SizedBox.shrink();
        }
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            // 全库仅有的两处「阴影是唯一分隔物」之一：这层浮层直接盖在表单上，
            // 去掉 elevation 必须同时补底色与边框，否则与下方表单糊在一起。
            // 注意 shape 与 borderRadius 互斥（同时传会在运行时 assert），
            // 所以原来那行 borderRadius 已删除，圆角改由 shape 承载。
            elevation: 0,
            color: context.surfaces.card,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
              side: BorderSide(color: context.surfaces.cardBorder),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220, maxWidth: 280),
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                shrinkWrap: true,
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final group = items[index];
                  return ListTile(
                    dense: true,
                    title: Text(group),
                    onTap: () => onSelected(group),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}
