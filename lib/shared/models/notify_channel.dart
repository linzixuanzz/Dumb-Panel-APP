import 'dart:convert';

class NotifyChannel {
  final int id;
  final String name;
  final String type;
  final Map<String, dynamic> config;
  final bool enabled;
  final DateTime createdAt;
  final DateTime updatedAt;

  const NotifyChannel({
    required this.id,
    required this.name,
    this.type = '',
    this.config = const {},
    this.enabled = true,
    required this.createdAt,
    required this.updatedAt,
  });

  factory NotifyChannel.fromJson(Map<String, dynamic> json) {
    return NotifyChannel(
      id: _int(json['id']),
      name: json['name']?.toString() ?? '',
      type: json['type']?.toString() ?? '',
      config: _config(json['config']),
      enabled: json['enabled'] != false,
      createdAt: _date(json['created_at']) ?? DateTime.now(),
      updatedAt: _date(json['updated_at']) ?? DateTime.now(),
    );
  }

  // 原有的 toJson() 全库无人调用（真实请求体是页面内联字面量），已删。理由见 task.dart。
}

int _int(dynamic v) => (v is num) ? v.toInt() : 0;
DateTime? _date(dynamic v) {
  if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
  return null;
}

Map<String, dynamic> _config(dynamic value) {
  if (value is Map<String, dynamic>) {
    return value;
  }

  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }

  if (value is String && value.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (_) {}
  }

  return {};
}
