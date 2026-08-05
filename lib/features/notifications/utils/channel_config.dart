// 通知渠道「读取 → 修改 → 回写」的纯数据变换。
//
// 这几个函数原来是 notification_list_page.dart 里弹窗闭包中的内联代码。
// 抽出来**只为可测**，逻辑逐行照搬，没有改行为：
// 编辑渠道时丢配置是用户实际踩过的坑（PRD F2），必须有回归保护，
// 而闭包里的代码没法在不起 UI 的情况下断言。
//
// 三个坑各对应下面一个函数，改动前先看注释：
// 1. 表单字段表（_channelFieldMap）是 APP 本地写死的，面板支持而表里没有的键
//    （telegram proxy、wecom 图文卡片参数…）必须原样保留；
// 2. 没有字段表的渠道（custom）走 JSON 编辑框，编辑框初值必须回填已有配置，
//    否则「打开 → 直接保存」等于用 {} 覆盖；
// 3. 用户在下拉里换了渠道类型，旧类型的配置键就没有意义，不能再带回服务端。

import 'dart:convert';

/// 表单型渠道保存时的最终 config。
///
/// [existingConfig] 是服务端返回的原始 config（整份，含 APP 不认识的键）。
/// [keepExistingConfig] 为 false 表示用户改过渠道类型，旧配置整份作废。
/// [fieldValues] 是**已经 trim 过**的表单值，key 用字段表里的 key，顺序即渲染顺序。
/// [smtpSsl] 只有 email 渠道传，其余传 null。
///
/// 语义：以 [existingConfig] 为基底，只覆盖 [fieldValues] 里出现的键；
/// 表单里被清空的字段视为「明确要求删除」，不退回旧值。
/// 做法与 open_api_page.dart 保留未知 scope 的思路一致。
Map<String, dynamic> buildChannelConfigFromFields({
  required Map<String, dynamic> existingConfig,
  required bool keepExistingConfig,
  required Map<String, String> fieldValues,
  bool? smtpSsl,
}) {
  final configMap = keepExistingConfig
      ? Map<String, dynamic>.from(existingConfig)
      : <String, dynamic>{};

  for (final entry in fieldValues.entries) {
    if (entry.value.isEmpty) {
      configMap.remove(entry.key);
    } else {
      configMap[entry.key] = entry.value;
    }
  }

  if (smtpSsl != null) {
    configMap['smtp_ssl'] = smtpSsl;
  }

  return configMap;
}

/// 「配置 JSON」编辑框的初值。
///
/// 这个编辑框原来永远是空的（existingConfig 里不存在 `__raw_json__` 这个键），
/// 于是「打开 custom 渠道 → 直接保存」= 用 {} 覆盖，整份配置被清空。
/// 回填已有配置后，用户看到什么就保存什么。
String buildRawConfigEditorText({
  required Map<String, dynamic> existingConfig,
  required bool keepExistingConfig,
}) {
  if (!keepExistingConfig || existingConfig.isEmpty) {
    return '';
  }
  return const JsonEncoder.withIndent('  ').convert(existingConfig);
}

/// 解析「配置 JSON」编辑框。
///
/// 返回 null 表示**格式不合法**，调用方必须提示用户而不是退化成 `{}`——
/// 退化成 `{}` 等于把整份配置清空。空串是合法输入，返回空 map。
Map<String, dynamic>? parseChannelConfig(String raw) {
  final text = raw.trim();
  if (text.isEmpty) {
    return <String, dynamic>{};
  }

  try {
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
  } catch (_) {}

  return null;
}
