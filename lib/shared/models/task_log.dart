import '../utils/duration_utils.dart';
import '../utils/panel_enums.dart';

class TaskLog {
  final int id;
  final int taskId;
  final String content;

  /// 0=成功 1=失败 2=运行中 **3=已终止**。
  ///
  /// 面板 `server/model/task_log.go:7-12` 的 LogStatus*。3 是面板 v3 新增的
  /// 「主动终止」（手动停止 / 定时停止），APP 之前完全没有这个值：
  /// 详情显示「未知」、列表状态点落到「运行中」的蓝、筛选栏也没有对应项。
  ///
  /// ⚠️ 不要和 `task.last_run_status` 混：那一套是 Run*（2 = 已终止），
  /// 两套枚举 2 的含义正好相反。
  final int? status;
  final double? duration;
  final String? logPath;
  final DateTime startedAt;
  final DateTime? endedAt;
  final DateTime createdAt;
  final String? taskName;

  const TaskLog({
    required this.id,
    required this.taskId,
    this.content = '',
    this.status,
    this.duration,
    this.logPath,
    required this.startedAt,
    this.endedAt,
    required this.createdAt,
    this.taskName,
  });

  bool get isSuccess => status == kLogStatusSuccess;
  bool get isFailed => status == kLogStatusFailed;
  bool get isRunning => status == kLogStatusRunning;
  bool get isAborted => status == kLogStatusAborted;

  String get statusText => logStatusLabel(status);

  PanelStatusTone get statusTone => logStatusTone(status);

  /// 耗时展示。分档实现在 `shared/utils/duration_utils.dart`：
  /// 这里原本自己写了一份 ms / s / m 三档的逻辑，缺小时档（4711.9s 会显示成
  /// `78m31s`），而且长在 getter 里没法单测。搬出去之后与面板
  /// `web/src/utils/duration.ts` 共用同一套分档。
  String get durationText => formatDurationSeconds(duration);

  factory TaskLog.fromJson(Map<String, dynamic> json) {
    return TaskLog(
      id: _int(json['id']),
      taskId: _int(json['task_id']),
      content: json['content']?.toString() ?? '',
      status: _intOrNull(json['status']),
      duration: (json['duration'] is num)
          ? (json['duration'] as num).toDouble()
          : null,
      logPath: json['log_path']?.toString(),
      startedAt: _date(json['started_at']) ?? DateTime.now(),
      endedAt: _date(json['ended_at']),
      createdAt: _date(json['created_at']) ?? DateTime.now(),
      taskName: json['task_name']?.toString(),
    );
  }
}

int _int(dynamic v) => (v is num) ? v.toInt() : 0;
int? _intOrNull(dynamic v) => (v is num) ? v.toInt() : null;
DateTime? _date(dynamic v) {
  if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
  return null;
}
