import '../utils/panel_enums.dart';

class Dependency {
  final int id;
  final String name;
  final String version;
  final String type;
  final String pythonVersion;
  final String status;
  final String? remark;
  final String? log;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Dependency({
    required this.id,
    required this.name,
    this.version = '',
    this.type = 'nodejs',
    this.pythonVersion = '',
    this.status = 'installed',
    this.remark,
    this.log,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isQueued => status == 'queued';
  bool get isInstalling => status == 'installing';
  bool get isRemoving => status == 'removing';
  bool get isInstalled => status == 'installed';
  bool get isFailed => status == 'failed';
  bool get isCancelled => status == 'cancelled';
  bool get isBusy => isInstalling || isRemoving || isQueued;

  /// 状态文案。兜底**不再**是「已安装」——
  /// 面板新增一种依赖状态时，那会把一个装不上的依赖显示成已装好。
  /// 换算表见 shared/utils/panel_enums.dart。
  String get statusText => dependencyStatusLabel(status);

  PanelStatusTone get statusTone => dependencyStatusTone(status);

  factory Dependency.fromJson(Map<String, dynamic> json) {
    return Dependency(
      id: _int(json['id']),
      name: json['name']?.toString() ?? '',
      version: json['version']?.toString() ?? '',
      type: json['type']?.toString() ?? 'nodejs',
      pythonVersion: json['python_version']?.toString() ?? '',
      status: json['status']?.toString() ?? 'installed',
      remark: json['remark']?.toString(),
      log: json['log']?.toString(),
      createdAt: _date(json['created_at']) ?? DateTime.now(),
      updatedAt: _date(json['updated_at']) ?? DateTime.now(),
    );
  }

  // 原有的 toJson() 全库无人调用（真实请求体是页面内联字面量），已删。理由见 task.dart。
}

int _int(dynamic value) => (value is num) ? value.toInt() : 0;

DateTime? _date(dynamic value) {
  if (value is String && value.isNotEmpty) {
    return DateTime.tryParse(value);
  }
  return null;
}
