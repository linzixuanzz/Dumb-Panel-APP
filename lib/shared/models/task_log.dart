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

  String get durationText {
    if (duration == null) return '-';
    if (duration! < 1) return '${(duration! * 1000).toStringAsFixed(0)}ms';
    if (duration! < 60) return '${duration!.toStringAsFixed(1)}s';
    final minutes = (duration! / 60).floor();
    final seconds = (duration! % 60).toStringAsFixed(0);
    return '${minutes}m${seconds}s';
  }

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
