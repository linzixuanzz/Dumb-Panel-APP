// 面板 v4.0 洞察类接口的模型（GET /tasks/:id/health、/system/attention、
// /tasks/running、/tasks/recent-runs）。
//
// 字段名与面板逐字对齐：
//   server/service/task_insights.go   HealthDay / HealthStats / HealthRun / RecentRun / RunningTaskItem
//   server/handler/system_attention.go attentionItem / attentionTarget
//
// 解析全部防御式（type-safety.md）：缺字段给默认值，不裸 `as`。
// 「这个面板支不支持」不在这里判断，见 `shared/api/panel_insights.dart` 的形状探测。

import '../utils/panel_enums.dart';

/// 单个任务最近 N 天的健康画像（`GET /tasks/:id/health?days=`）。
class TaskHealth {
  /// 每天一行，旧 → 新，含今天；没跑过的天也有一行（全 0）。
  final List<HealthDay> days;
  final HealthStats stats;

  /// 最近若干次已结束的执行，旧 → 新（面板最多给 20 条）。
  final List<HealthRun> recent;

  const TaskHealth({
    this.days = const [],
    this.stats = const HealthStats(),
    this.recent = const [],
  });

  factory TaskHealth.fromJson(Map<String, dynamic> json) {
    return TaskHealth(
      days: _list(json['days'], HealthDay.fromJson),
      stats: json['stats'] is Map<String, dynamic>
          ? HealthStats.fromJson(json['stats'] as Map<String, dynamic>)
          : const HealthStats(),
      recent: _list(json['recent'], HealthRun.fromJson),
    );
  }
}

class HealthDay {
  /// 面板时区的日期，`YYYY-MM-DD`。
  final String date;

  /// 当天已结束的执行次数（成功 + 失败 + 已终止）。
  final int total;

  /// 当天失败次数（超时也记为失败）。月历上「红点」就看它 > 0。
  final int failed;

  /// 当天平均耗时（秒），没有耗时记录时是 0。
  final double avgDuration;

  const HealthDay({
    required this.date,
    this.total = 0,
    this.failed = 0,
    this.avgDuration = 0,
  });

  /// [date] 解析成本地日期；格式不对时为 null。
  DateTime? get day => DateTime.tryParse(date);

  factory HealthDay.fromJson(Map<String, dynamic> json) {
    return HealthDay(
      date: json['date']?.toString() ?? '',
      total: _int(json['total']),
      failed: _int(json['failed']),
      avgDuration: _double(json['avg_duration']),
    );
  }
}

class HealthStats {
  /// 窗口内已结束的执行次数。
  final int runs;

  /// 成功率，**0~100**（面板已乘 100、保留 1 位小数）；已终止不计入分母。
  final double successRate;

  /// 平均耗时 / P90 耗时（秒）。
  final double avgDuration;
  final double p90Duration;

  const HealthStats({
    this.runs = 0,
    this.successRate = 0,
    this.avgDuration = 0,
    this.p90Duration = 0,
  });

  factory HealthStats.fromJson(Map<String, dynamic> json) {
    return HealthStats(
      runs: _int(json['runs']),
      successRate: _double(json['success_rate']),
      avgDuration: _double(json['avg_duration']),
      p90Duration: _double(json['p90_duration']),
    );
  }
}

class HealthRun {
  /// 日志状态：0 成功 / 1 失败 / 3 已终止（见 `panel_enums.dart` 的 kLogStatus*）。
  final int status;

  /// 耗时（秒），面板没记录时为 null。
  final double? duration;
  final DateTime? startedAt;

  const HealthRun({required this.status, this.duration, this.startedAt});

  bool get isFailed => status == kLogStatusFailed;

  factory HealthRun.fromJson(Map<String, dynamic> json) {
    return HealthRun(
      status: _int(json['status']),
      duration: _doubleOrNull(json['duration']),
      startedAt: _date(json['started_at']),
    );
  }
}

/// 「需要关注」的一条（`GET /system/attention` 的 `items[]`）。
class AttentionItem {
  /// 稳定键，如 `task_failing:12`，前端靠它去重 / 做动画。
  final String key;

  /// `task_failing` / `subscription_failed` / `dependency_failed` / `disk_high`；
  /// 面板以后加了新类型时原样保留，调用方按不认识处理。
  final String type;

  /// `err` / `warn` / `info`。
  final String level;
  final String title;
  final String detail;
  final AttentionTarget target;
  final DateTime? at;

  const AttentionItem({
    required this.key,
    required this.type,
    required this.level,
    required this.title,
    this.detail = '',
    this.target = const AttentionTarget(),
    this.at,
  });

  factory AttentionItem.fromJson(Map<String, dynamic> json) {
    return AttentionItem(
      key: json['key']?.toString() ?? '',
      type: json['type']?.toString() ?? '',
      level: json['level']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      detail: json['detail']?.toString() ?? '',
      target: json['target'] is Map<String, dynamic>
          ? AttentionTarget.fromJson(json['target'] as Map<String, dynamic>)
          : const AttentionTarget(),
      at: _date(json['at']),
    );
  }
}

class AttentionTarget {
  /// `task` / `subscription` / `dependency` / `system`（system 时 [id] 为 0）。
  final String kind;
  final int id;

  const AttentionTarget({this.kind = '', this.id = 0});

  factory AttentionTarget.fromJson(Map<String, dynamic> json) {
    return AttentionTarget(
      kind: json['kind']?.toString() ?? '',
      id: _int(json['id']),
    );
  }
}

/// 当前运行中的一个任务（`GET /tasks/running` 的 `items[]`）。
class RunningTask {
  final int taskId;
  final String name;

  /// 正在写的那条日志；任务刚标记运行、日志行还没建好的极短窗口里为 null。
  final int? logId;
  final DateTime? startedAt;

  const RunningTask({
    required this.taskId,
    required this.name,
    this.logId,
    this.startedAt,
  });

  factory RunningTask.fromJson(Map<String, dynamic> json) {
    return RunningTask(
      taskId: _int(json['task_id']),
      name: json['name']?.toString() ?? '',
      logId: _intOrNull(json['log_id']),
      startedAt: _date(json['started_at']),
    );
  }
}

/// 某任务最近一次已结束的执行（`GET /tasks/recent-runs` 的 `runs.{id}[]`）。
/// 面板这里只给状态和耗时，不给时间。
class RecentRun {
  /// 日志状态：0 成功 / 1 失败 / 3 已终止。
  final int status;

  /// 耗时（秒），没记录时为 null。
  final double? duration;

  const RecentRun({required this.status, this.duration});

  bool get isFailed => status == kLogStatusFailed;

  factory RecentRun.fromJson(Map<String, dynamic> json) {
    return RecentRun(
      status: _int(json['status']),
      duration: _doubleOrNull(json['duration']),
    );
  }
}

// ── 文件私有的解析 helper（与 task.dart 同款，按现状复制）──────────────

List<T> _list<T>(dynamic v, T Function(Map<String, dynamic>) parse) {
  if (v is! List) return const [];
  return v.whereType<Map<String, dynamic>>().map(parse).toList();
}

int _int(dynamic v) => (v is num) ? v.toInt() : 0;
int? _intOrNull(dynamic v) => (v is num) ? v.toInt() : null;
double _double(dynamic v) => (v is num) ? v.toDouble() : 0.0;
double? _doubleOrNull(dynamic v) => (v is num) ? v.toDouble() : null;
DateTime? _date(dynamic v) {
  if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
  return null;
}
