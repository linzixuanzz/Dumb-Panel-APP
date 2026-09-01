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

  /// 这条日志对应任务的执行命令，用来反推它跑的是哪个脚本。
  ///
  /// ⚠️ **必须按可空用**。面板 `server/model/task_log.go` 的 `ToDict()` 是在
  /// Preload 到 Task 之后才补这个键的，而且是 v3.2.0 之后才加的 —— 用户连的是
  /// 老面板时它压根不存在。日志详情页因此还留了一条「点击时才去查任务列表」的
  /// 兜底路径，不能假定这里一定有值。
  ///
  /// 空串归一成 null：面板对「没有命令」和「命令是空字符串」不做区分，
  /// 调用方只要判一次 null 就够了。
  final String? command;

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
    this.command,
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
      command: _nonEmpty(json['command']),
    );
  }
}

int _int(dynamic v) => (v is num) ? v.toInt() : 0;
int? _intOrNull(dynamic v) => (v is num) ? v.toInt() : null;
String? _nonEmpty(dynamic v) {
  final text = v?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}

DateTime? _date(dynamic v) {
  if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
  return null;
}
