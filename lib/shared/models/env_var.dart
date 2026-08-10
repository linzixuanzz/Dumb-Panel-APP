class EnvVar {
  final int id;
  final String name;
  final String value;
  final String remarks;
  final bool enabled;
  final double position;
  final int sortOrder;
  final String group;
  final DateTime createdAt;
  final DateTime updatedAt;

  const EnvVar({
    required this.id,
    required this.name,
    this.value = '',
    this.remarks = '',
    this.enabled = true,
    this.position = 10000.0,
    this.sortOrder = 0,
    this.group = '',
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isPinned => sortOrder == 1;
  List<String> get groups => _splitEnvGroups(group);

  factory EnvVar.fromJson(Map<String, dynamic> json) {
    return EnvVar(
      id: _int(json['id']),
      name: json['name']?.toString() ?? '',
      value: json['value']?.toString() ?? '',
      remarks: json['remarks']?.toString() ?? '',
      enabled: json['enabled'] == true,
      position: (json['position'] is num)
          ? (json['position'] as num).toDouble()
          : 10000.0,
      sortOrder: _int(json['sort_order']),
      group: json['group']?.toString() ?? '',
      createdAt: _date(json['created_at']) ?? DateTime.now(),
      updatedAt: _date(json['updated_at']) ?? DateTime.now(),
    );
  }

  // 原有的 toJson() 全库无人调用（真实请求体是页面内联字面量；环境变量导入导出走的是
  // EnvTransferItem.toJson，不是这个），已删。理由见 task.dart。
}

int _int(dynamic v) => (v is num) ? v.toInt() : 0;
DateTime? _date(dynamic v) {
  if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
  return null;
}

List<String> _splitEnvGroups(String raw) {
  return raw
      .split(',')
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList();
}
