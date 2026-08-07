// 通知渠道「读取 → 修改 → 回写」的纯数据变换。
//
// 这几个函数原来是 notification_list_page.dart 里弹窗闭包中的内联代码。
// 抽出来**只为可测**，逻辑逐行照搬，没有改行为：
// 编辑渠道时丢配置是用户实际踩过的坑（PRD F2），必须有回归保护，
// 而闭包里的代码没法在不起 UI 的情况下断言。
//
// 踩过的坑，改动前先看对应函数的注释：
// 1. 表单只画得出「当前这台面板声明了的字段」，其余的键（面板支持但 schema 没声明的、
//    条件不满足没渲染的、这一版 APP 不认识的）必须原样保留；
// 2. 一个字段定义都拿不到的渠道（老面板上的 custom）走 JSON 编辑框，编辑框初值必须
//    回填已有配置，否则「打开 → 直接保存」等于用 {} 覆盖；
// 3. 用户在下拉里换了渠道类型，旧类型的配置键就没有意义，不能再带回服务端；
// 4. config 的值**必须全是字符串**，且 smtp_ssl 是三态不是开关——见下面 smtpSslMode* 的注释。
//
// 字段表本身已经不在 APP 里了：面板 `/notifications/types` 下发 `fields`，
// 解析与渲染规则见 notify_field_schema.dart，老面板的降级见
// frozen_channel_fields_v300.dart。

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

/// SSL 的主键。面板的字段 schema 只声明得出这一个，4 个兼容别名不在 schema 里 ——
/// 这正是下面 [resolveExistingSmtpSslValue] 必须存在的原因。
const String kSmtpSslConfigKey = 'smtp_ssl';

/// 面板判定 SSL 时依次尝试的 5 个键（server/service/notifier.go:358）。
/// 顺序即优先级：**第一个存在的键**决定结果（哪怕值是空串），后面的不再看。
/// 后 4 个是青龙导入等外部来源用的兼容别名，面板自己不写。
const List<String> smtpSslConfigKeys = <String>[
  kSmtpSslConfigKey,
  'smtp_use_ssl',
  'use_ssl',
  'enable_ssl',
  'ssl',
];

/// 这份 config 里 `smtp_ssl` 的**已有值**；返回 null 表示从来没设置过。
///
/// 为什么不能让通用渲染器直接读 `config['smtp_ssl']`：面板判定 SSL 时依次看
/// [smtpSslConfigKeys] 这 5 个键，而 schema 只声明得出主键那一个。配置里只有别名
/// （青龙导入写的 `use_ssl`）时，直接读主键会拿到 null → 表单显示默认值「自动」，
/// 而面板实际是启用的 —— 用户随手一存，启用就被改成了自动。
/// 这是 schema **表达不出来**的一处面板内部不对称，只能留在 APP 侧补偿。
///
/// 主键存在时**原样返回，不做三态归一**：选项集合由面板 schema 说了算，
/// 面板哪天给 SSL 多加一个取值（比如 starttls），APP 不能替它压成 false。
/// 认不出来的值会被渲染成「(面板未声明)」的一项，用户看得见、也存得回去。
///
/// 唯一的例外是 bool —— 那是旧版 APP 写坏的投毒数据（面板整份 config 都读不了，
/// 该渠道所有通知全挂），必须在这里就修成字符串。
String? resolveExistingSmtpSslValue(Map<String, dynamic> config) {
  final primary = config[kSmtpSslConfigKey];
  if (primary != null) {
    return primary is bool ? normalizeSmtpSslMode(primary) : primary.toString();
  }

  for (final key in smtpSslConfigKeys) {
    if (key == kSmtpSslConfigKey || !config.containsKey(key)) {
      continue;
    }
    // 别名是外部来源写的，取值五花八门（1/yes/on…），必须归一到三态之一，
    // 否则回写主键时会把面板认不出来的值固化进 smtp_ssl。
    return normalizeSmtpSslMode(config[key]);
  }
  return null;
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
/// [fieldValues] 是**已经 trim 过**的表单值，key 用 schema 字段的 key，顺序即渲染顺序；
/// 怎么从表单算出它见 notify_field_schema.dart 的 `buildNotifyFieldValues`。
///
/// 语义：以 [existingConfig] 为基底，只覆盖 [fieldValues] 里出现的键；
/// 表单里被清空的字段视为「明确要求删除」，不退回旧值。
/// 反过来，[fieldValues] 里**没有**的键原样保留 —— 这就是「未知字段不丢失」的落点，
/// 覆盖三种情况：面板 schema 没声明的键、show_when 不满足所以没渲染的键、
/// 以及面板将来新增而这一版 APP 还不认识的键。
/// 做法与 open_api_page.dart 保留未知 scope 的思路一致。
Map<String, dynamic> buildChannelConfigFromFields({
  required Map<String, dynamic> existingConfig,
  required bool keepExistingConfig,
  required Map<String, String> fieldValues,
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

  return configMap;
}

/// 「配置 JSON」编辑框的初值。
///
/// 这个编辑框原来永远是空的（existingConfig 里不存在 `__raw_json__` 这个键），
/// 于是「打开 custom 渠道 → 直接保存」= 用 {} 覆盖，整份配置被清空。
/// 回填已有配置后，用户看到什么就保存什么。
///
/// 新面板会给 custom 下发 5 个字段（url / method / content_type / headers / body，
/// 与 notifier.go 的 `sendCustomWebhook` 逐条对应），那时走通用表单，不再进这里。
/// 这个编辑框留给「一个字段定义都拿不到」的情况：老面板上的 custom，
/// 以及面板将来新增、而冻结快照里当然也没有的渠道类型。
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
