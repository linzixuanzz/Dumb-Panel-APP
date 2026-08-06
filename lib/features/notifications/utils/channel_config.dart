// 通知渠道「读取 → 修改 → 回写」的纯数据变换。
//
// 这几个函数原来是 notification_list_page.dart 里弹窗闭包中的内联代码。
// 抽出来**只为可测**，逻辑逐行照搬，没有改行为：
// 编辑渠道时丢配置是用户实际踩过的坑（PRD F2），必须有回归保护，
// 而闭包里的代码没法在不起 UI 的情况下断言。
//
// 踩过的坑，改动前先看对应函数的注释：
// 1. 表单字段表（_channelFieldMap）是 APP 本地写死的，面板支持而表里没有的键
//    （telegram proxy、wecom 图文卡片参数…）必须原样保留；
// 2. 没有字段表的渠道（custom）走 JSON 编辑框，编辑框初值必须回填已有配置，
//    否则「打开 → 直接保存」等于用 {} 覆盖；
// 3. 用户在下拉里换了渠道类型，旧类型的配置键就没有意义，不能再带回服务端；
// 4. config 的值**必须全是字符串**，且 smtp_ssl 是三态不是开关——见下面 smtpSslMode* 的注释。

import 'dart:convert';

/// SMTP SSL 的三种取值，逐字对齐面板 Web 端的 select
/// （web/src/views/notifications/index.vue:106-110），**必须是字符串**。
///
/// 为什么不是 bool：面板 `sendToChannel` 把整份 config 反序列化成
/// `map[string]string`（server/service/notifier.go:166-168），
/// 只要里面有一个 bool，整份 Unmarshal 就报
/// `json: cannot unmarshal bool into Go value of type string` 并直接返回错误——
/// 该渠道的**所有**通知（含「测试」按钮）从此全挂。
/// 而且 Web 端是整份 JSON.parse 读入、整份写回，会原样保留那个 bool，**Web 也修不回来**。
const String smtpSslModeAuto = 'auto';
const String smtpSslModeOn = 'true';
const String smtpSslModeOff = 'false';

/// 面板判定 SSL 时依次尝试的 5 个键（server/service/notifier.go:358）。
/// 顺序即优先级：**第一个存在的键**决定结果（哪怕值是空串），后面的不再看。
/// 后 4 个是青龙导入等外部来源用的兼容别名，面板自己不写。
const List<String> smtpSslConfigKeys = <String>[
  'smtp_ssl',
  'smtp_use_ssl',
  'use_ssl',
  'enable_ssl',
  'ssl',
];

/// 从服务端返回的 config 里解析出 SSL 三态，用作表单初值。
///
/// 必须与面板 `smtpImplicitSSLEnabled` 的取键顺序一致，否则会出现
/// 「APP 显示关闭、面板实际启用」这种表单与真相不符的状态；
/// 而用户随手一存就会把显示的错值固化成真值。
///
/// 存量数据有三种形态，都要认：
/// - 字符串（Web / 青龙导入写的，`'auto' | 'true' | 'false'` 及各类同义词）
/// - bool（旧版 APP 写坏的投毒数据）
/// - 键不存在（面板按端口是否为 465 自动判断，即 auto）
String resolveSmtpSslMode(Map<String, dynamic> config) {
  for (final key in smtpSslConfigKeys) {
    if (!config.containsKey(key)) {
      continue;
    }
    return normalizeSmtpSslMode(config[key]);
  }
  return smtpSslModeAuto;
}

/// 把任意存量取值收敛到三态之一，语义对齐面板
/// `smtpImplicitSSLEnabled` + `notificationConfigBool`（notifier.go:357-370、1273-1283）。
String normalizeSmtpSslMode(dynamic value) {
  // 旧版 APP 写进去的 bool。面板读不了，但 APP 自己得能读回来，
  // 否则用户打开编辑框会看到与已保存内容不符的状态。
  if (value is bool) {
    return value ? smtpSslModeOn : smtpSslModeOff;
  }

  final text = value?.toString().trim().toLowerCase() ?? '';
  if (text.isEmpty || text == smtpSslModeAuto) {
    return smtpSslModeAuto;
  }
  switch (text) {
    case '1':
    case 'true':
    case 'yes':
    case 'on':
    case 'enable':
    case 'enabled':
      return smtpSslModeOn;
    case '0':
    case 'false':
    case 'no':
    case 'off':
    case 'disable':
    case 'disabled':
      return smtpSslModeOff;
    default:
      // 面板对无法识别的值取 defaultValue=false，这里跟着取「关闭」，
      // 保证 APP 显示的就是面板实际会做的事。
      return smtpSslModeOff;
  }
}

/// 表单型渠道保存时的最终 config。
///
/// [existingConfig] 是服务端返回的原始 config（整份，含 APP 不认识的键）。
/// [keepExistingConfig] 为 false 表示用户改过渠道类型，旧配置整份作废。
/// [fieldValues] 是**已经 trim 过**的表单值，key 用字段表里的 key，顺序即渲染顺序。
/// [smtpSslMode] 只有 email 渠道传，其余传 null；取值见 [smtpSslModeAuto] 等常量。
///
/// 语义：以 [existingConfig] 为基底，只覆盖 [fieldValues] 里出现的键；
/// 表单里被清空的字段视为「明确要求删除」，不退回旧值。
/// 做法与 open_api_page.dart 保留未知 scope 的思路一致。
Map<String, dynamic> buildChannelConfigFromFields({
  required Map<String, dynamic> existingConfig,
  required bool keepExistingConfig,
  required Map<String, String> fieldValues,
  String? smtpSslMode,
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

  if (smtpSslMode != null) {
    // 一律写回主键 smtp_ssl，不写别名：主键在面板的取键顺序里排第一，
    // 而这里写的值本来就是从「当时生效的那个键」解析出来的，
    // 所以即便配置里还留着 use_ssl 之类的别名，解析结果也不会变。
    // 顺带让 Web 端（只认 smtp_ssl）能正常显示。
    // 经 normalize 兜底，保证落地的永远是 'auto'/'true'/'false' 三个字符串之一。
    configMap['smtp_ssl'] = normalizeSmtpSslMode(smtpSslMode);
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
