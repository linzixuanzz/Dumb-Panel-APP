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

  /// 「重要」标记（APP #16 ②）。三种取值的含义不一样，**null 不等于 false**：
  ///
  /// - null：面板没下发这个键（≤ v3.3.5 的老面板）。这时一切「重要」入口都不出现、
  ///   删除流程与改动前逐字相同，也**绝不**往面板发 `important`。
  ///   「面板支持不支持」就看它是不是 null（形状探测，不看版本号），不另设字段。
  /// - true / false：面板 v3.3.6 起 `ToDict` 永远下发这个布尔。
  ///
  /// 下发的不是布尔（`1`、`"true"` 之类）一律当没下发：未知值诚实对待，不猜。
  final bool? important;

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
    this.important,
  });

  bool get isPinned => sortOrder == 1;
  bool get isImportant => important == true;
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
      // 没有这个键 / 不是布尔 → null（形状探测，见字段注释）
      important: json['important'] is bool ? json['important'] as bool : null,
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
