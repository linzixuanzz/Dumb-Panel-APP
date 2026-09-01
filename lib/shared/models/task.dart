import '../utils/panel_enums.dart';

class Task {
  static const String groupLabelPrefix = '分组:';

  /// 订阅托管标记。这是**服务端内部标签**，不是用户自己打的标签：
  /// 它把任务和订阅源绑在一起，决定订阅锁、「恢复为订阅默认」入口、
  /// 以及下次拉取时认不认得这条任务是自己建的。
  ///
  /// ⚠️ 编辑任务时必须**原样透传**，不能跟着用户标签一起被覆写掉，
  /// 否则任务会脱离订阅托管、下次拉取重建出一条同名重复任务。
  /// 面板 Web 端的 `mergeTaskLabels` 就是专门做这件事的。
  static const String subscriptionLabelPrefix = 'subscription:';

  final int id;
  final String name;
  final String command;
  final String cronExpression;
  final List<String> cronExpressions;
  final String taskType;
  final String pythonVersion;
  final double status;
  final String labels;
  final List<String> displayLabels;
  final DateTime? lastRunAt;
  final DateTime? nextRunAt;
  final int? lastRunStatus;
  final int timeout;
  final int? randomDelaySeconds;
  final int maxRetries;
  final int retryInterval;
  final bool notifyOnFailure;
  final bool notifyOnSuccess;
  final int? notificationChannelId;
  final int? dependsOn;
  final int sortOrder;
  final bool isPinned;
  final String? taskBefore;
  final String? taskAfter;
  final bool allowMultipleInstances;
  final String? notificationChannelName;
  final bool? notificationChannelEnabled;
  final double? lastRunningTime;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Task({
    required this.id,
    required this.name,
    required this.command,
    required this.cronExpression,
    this.cronExpressions = const [],
    this.taskType = 'cron',
    this.pythonVersion = '3.12',
    required this.status,
    this.labels = '',
    this.displayLabels = const [],
    this.lastRunAt,
    this.nextRunAt,
    this.lastRunStatus,
    this.timeout = 0,
    this.randomDelaySeconds,
    this.maxRetries = 0,
    this.retryInterval = 0,
    this.notifyOnFailure = false,
    this.notifyOnSuccess = false,
    this.notificationChannelId,
    this.dependsOn,
    this.sortOrder = 0,
    this.isPinned = false,
    this.taskBefore,
    this.taskAfter,
    this.allowMultipleInstances = false,
    this.notificationChannelName,
    this.notificationChannelEnabled,
    this.lastRunningTime,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isDisabled => status == kTaskStatusDisabled;
  bool get isQueued => status == kTaskStatusQueued;
  bool get isEnabled => status == kTaskStatusEnabled;
  bool get isRunning => status == kTaskStatusRunning;

  /// 本版 APP 是否认得这个状态值。不认得时 UI 走中性态，
  /// 而不是沿用「已禁用」那一支的灰色 + 「启用」按钮。
  bool get hasKnownStatus => isKnownTaskStatus(status);

  /// 状态文案。兜底**不再**是「已禁用」：面板加第五种状态时，
  /// 把它显示成已禁用会让用户去点「启用」，而那个按钮并不解决问题。
  String get statusText => taskStatusLabel(status);

  /// 任务类型文案（常规定时 / 手动运行 / 开机运行）。
  /// 空串按「常规定时」是面板的归一化语义，非空且不认识的值原样显示。
  String get taskTypeText => taskTypeLabel(taskType);

  /// 上次运行结果文案。注意 `last_run_status` 走的是 Run* 枚举，2 是**已终止**。
  String get lastRunResultText => taskRunResultLabel(lastRunStatus);

  /// 上次运行是否失败。**只有 1 是失败**，2 是用户主动终止，不该按失败告警。
  bool get lastRunFailed => lastRunStatus == 1;

  List<String> get labelList => labels.isEmpty
      ? []
      : labels.split(',').where((l) => l.isNotEmpty).toList();

  List<String> get labelsForDisplay =>
      displayLabels.isNotEmpty ? displayLabels : labelList;

  static bool isGroupLabel(String label) =>
      label.trim().startsWith(groupLabelPrefix);

  static String toGroupLabel(String group) =>
      '$groupLabelPrefix${group.trim()}';

  /// 判前缀一律**先 trim**：历史脏数据里存在 `" subscription:1"` 这种
  /// 带前导空格的标签（逗号拼接串被手工编辑过），面板侧同样是 trim 后判的。
  static bool isSubscriptionLabel(String label) =>
      label.trim().startsWith(subscriptionLabelPrefix);

  /// 把「裸分组名」或「分组:名」统一归一成完整的分组标签，空值返回空串。
  ///
  /// 存在的理由：本地持久化里存的是裸分组名，而发给服务端做筛选的必须是
  /// 带前缀的完整标签（服务端做的是 `labels LIKE '%<值>%'`，传裸名会把
  /// 只挂了同名**普通标签**的任务一起捞回来）。两种形态都要能吃下。
  static String normalizeGroupLabel(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    return isGroupLabel(trimmed) ? trimmed : toGroupLabel(trimmed);
  }

  /// 从「分组:名」取出分组名；传进来的若已经是裸名则原样返回。
  static String groupNameFromLabel(String value) {
    final trimmed = value.trim();
    if (!isGroupLabel(trimmed)) {
      return trimmed;
    }
    return trimmed.substring(groupLabelPrefix.length).trim();
  }

  /// 编辑表单里**可见可编辑**的用户标签：原始 labels 去掉分组与订阅两类。
  ///
  /// 注意入参必须是**原始** [labelList] 而不是 [userLabelsForDisplay]：
  /// 后者基于服务端的 `display_labels`，里面 `subscription:3` 已经被换成了
  /// 订阅显示名「华星电信」，拿它播种编辑框再整体覆写就等于把内部标签删了。
  static List<String> splitUserLabels(List<String> rawLabels) {
    return rawLabels
        .map((label) => label.trim())
        .where((label) => label.isNotEmpty)
        .where((label) => !isGroupLabel(label) && !isSubscriptionLabel(label))
        .toList();
  }

  /// 内部标签（目前只有 `subscription:<id>`）。编辑时不渲染、不可改，
  /// 保存时原样拼回去。
  static List<String> splitInternalLabels(List<String> rawLabels) {
    return rawLabels
        .map((label) => label.trim())
        .where((label) => label.isNotEmpty)
        .where(isSubscriptionLabel)
        .toList();
  }

  /// 拼回提交体的 labels：用户标签 + 内部标签 + 分组标签。
  ///
  /// 面板的任务更新是**整体覆写** labels，所以这里漏掉任何一类都是真的丢数据。
  static List<String> mergeTaskLabels({
    required List<String> userLabels,
    required List<String> internalLabels,
    required String groupName,
  }) {
    final merged = <String>[
      ...userLabels
          .map((label) => label.trim())
          .where(
            (label) =>
                label.isNotEmpty &&
                !isGroupLabel(label) &&
                !isSubscriptionLabel(label),
          ),
      ...internalLabels
          .map((label) => label.trim())
          .where((label) => label.isNotEmpty),
    ];
    final group = groupName.trim();
    if (group.isNotEmpty) {
      merged.add(toGroupLabel(group));
    }
    return merged;
  }

  String? get groupName {
    for (final label in labelList) {
      final trimmed = label.trim();
      if (isGroupLabel(trimmed)) {
        final group = trimmed.substring(groupLabelPrefix.length).trim();
        if (group.isNotEmpty) {
          return group;
        }
      }
    }
    return null;
  }

  List<String> get userLabelsForDisplay {
    final visible = labelsForDisplay
        .where((label) => !isGroupLabel(label))
        .toList();
    final group = groupName;
    if (group != null && group.isNotEmpty) {
      visible.remove(group);
    }
    return visible;
  }

  factory Task.fromJson(Map<String, dynamic> json) {
    return Task(
      id: _int(json['id']),
      name: json['name']?.toString() ?? '',
      command: json['command']?.toString() ?? '',
      cronExpression: json['cron_expression']?.toString() ?? '',
      cronExpressions: json['cron_expressions'] is List
          ? (json['cron_expressions'] as List)
                .map((e) => e.toString())
                .where((s) => s.trim().isNotEmpty)
                .toList()
          : const [],
      taskType: json['task_type']?.toString() ?? 'cron',
      pythonVersion: json['python_version']?.toString() ?? '3.12',
      status: _double(json['status']),
      labels: json['labels'] is List
          ? (json['labels'] as List).join(',')
          : json['labels']?.toString() ?? '',
      displayLabels: json['display_labels'] is List
          ? (json['display_labels'] as List)
                .map((e) => e.toString())
                .where((label) => label.trim().isNotEmpty)
                .toList()
          : const [],
      lastRunAt: _date(json['last_run_at']),
      nextRunAt: _date(json['next_run_at']),
      lastRunStatus: _intOrNull(json['last_run_status']),
      timeout: _int(json['timeout']),
      randomDelaySeconds: _intOrNull(json['random_delay_seconds']),
      maxRetries: _int(json['max_retries']),
      retryInterval: _int(json['retry_interval']),
      notifyOnFailure: json['notify_on_failure'] == true,
      notifyOnSuccess: json['notify_on_success'] == true,
      notificationChannelId: _intOrNull(json['notification_channel_id']),
      dependsOn: _intOrNull(json['depends_on']),
      sortOrder: _int(json['sort_order']),
      isPinned: json['is_pinned'] == true,
      taskBefore: json['task_before']?.toString(),
      taskAfter: json['task_after']?.toString(),
      allowMultipleInstances: json['allow_multiple_instances'] == true,
      notificationChannelName: json['notification_channel_name']?.toString(),
      notificationChannelEnabled: json['notification_channel_enabled'] as bool?,
      lastRunningTime: _doubleOrNull(json['last_running_time']),
      createdAt: _date(json['created_at']) ?? DateTime.now(),
      updatedAt: _date(json['updated_at']) ?? DateTime.now(),
    );
  }

  // 这里原本有一份 toJson()，全库无人调用（真实请求体是 task_form_page 里的内联字面量），
  // 于是同一个实体存在两份字段清单、改一处漏一处。已删，不要再加回来：
  // 要提交任务就用页面那份，它才是真正发出去的东西。
}

int _int(dynamic v) => (v is num) ? v.toInt() : 0;
int? _intOrNull(dynamic v) => (v is num) ? v.toInt() : null;
double _double(dynamic v) => (v is num) ? v.toDouble() : 0.0;
double? _doubleOrNull(dynamic v) => (v is num) ? v.toDouble() : null;
DateTime? _date(dynamic v) {
  if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
  return null;
}
