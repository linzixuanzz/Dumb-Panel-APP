// 通知渠道表单的 schema —— 面板下发什么字段，APP 就画什么字段。
//
// 这个文件顶掉的是 notification_list_page.dart 里那张 223 行的 `_channelFieldMap`：
// 21 个渠道、44 个字段槽、**24 个唯一键**，而面板 server/service/notifier.go 实际读
// **55 个唯一 config 键** —— 也就是 31 个键在 APP 上没有任何输入入口，
// custom 渠道更是压根没有表单。那张表是从面板 Web 抄来的，抄完就再没有任何机制
// 能发现它和面板漂移了，用户只会体验成「面板支持的东西 APP 上填不了」。
//
// ── 契约来源（本次实读核对）──────────────────────────────────────────────
// 面板 `GET /api/notifications/types` 的每一项多出一个 `fields`：
//
//   {"type":"telegram","name":"Telegram","fields":[
//     {"key":"token","label":"Bot Token","widget":"input",
//      "placeholder":"从 @BotFather 获取","required":true},
//     {"key":"proxy","label":"代理","widget":"input"},
//     {"key":"msg_type","label":"消息类型","widget":"select","default":"text",
//      "options":[{"value":"text","label":"文本"}]},
//     {"key":"news_articles","label":"图文","widget":"textarea",
//      "show_when":{"key":"msg_type","values":["news"]}}]}
//
// widget 只有四种：input / password / textarea / select。
// show_when 只支持**单键等值命中**。
//
// 这套表达力不是设计出来的，是面板 Web 端 web/src/views/notifications/index.vue:95-319
// 那 225 行字段表的实测归纳：四种控件、14 组 options、2 个渠道 10 个条件分支，
// 而它的渲染器（:795-819）本来就是一段通用 `v-for`，已经实战验证过一轮。
// ⚠️ 不要往里加表达式引擎，不要加跨字段联动 DSL —— 真实数据里一条都用不上。
//
// ── 老面板怎么办 ────────────────────────────────────────────────────────
// 形状探测：`fields` 在不在，不看版本号（handler.Version 由 ldflags 注入，
// 任何本地 go build / fork 都自称 3.0.0，不可信）。降级见
// frozen_channel_fields_v300.dart。
//
// ── 一条不能破的硬规则：config 的值必须全是字符串 ─────────────────────────
// 面板 sendToChannel 把整份 config 反序列化成 `map[string]string`
// （server/service/notifier.go:166-168）。里面出现**一个** bool，整份 Unmarshal 就报
// `json: cannot unmarshal bool into Go value of type string` 并直接返回错误 ——
// 该渠道的所有通知（含「测试」按钮）从此全挂，而且 Web 端是整份 JSON.parse 读入、
// 整份写回，会原样保留那个 bool，**Web 也修不回来**。
// 所以这个文件里所有产出表单值的函数返回的都是 `Map<String, String>`，
// 没有一个 dynamic：select 的选项值是 String，default 是 String，
// 存量里读到的 bool/数字/对象也在读的那一刻就转成 String。

import 'dart:convert';

import 'channel_config.dart';

/// 面板 NotifyFieldWidget 的四个取值。
///
/// [unknown] 不是面板的取值，是「面板加了第五种控件、而这一版 APP 不认识」的兜底。
/// 它一律降级成普通输入框（见 [NotifyFieldSchema.effectiveWidget]），
/// **绝不隐藏字段** —— 隐藏等于用户在 APP 上永远填不了它，
/// 而本次改造存在的全部意义就是「面板声明了什么，APP 上就能填什么」。
enum NotifyFieldWidget { input, password, textarea, select, unknown }

NotifyFieldWidget parseNotifyFieldWidget(dynamic raw) {
  switch (raw?.toString().trim().toLowerCase() ?? '') {
    case 'input':
      return NotifyFieldWidget.input;
    case 'password':
      return NotifyFieldWidget.password;
    case 'textarea':
      return NotifyFieldWidget.textarea;
    case 'select':
      return NotifyFieldWidget.select;
    default:
      return NotifyFieldWidget.unknown;
  }
}

/// 下拉选项，对齐面板的 `SystemConfigOption{value,label}`。
/// `value` 一定是字符串 —— 面板的 select 值本来就写成 `'0'`/`'1'`/`'true'` 这种字符串。
class NotifyFieldOption {
  const NotifyFieldOption({required this.value, required this.label});

  final String value;
  final String label;

  @override
  bool operator ==(Object other) =>
      other is NotifyFieldOption &&
      other.value == value &&
      other.label == label;

  @override
  int get hashCode => Object.hash(value, label);
}

/// `show_when`：**单键等值命中** —— 某个键的当前值落在 [values] 里时才显示。
///
/// 面板只支持这一种条件，它刚好覆盖现有全部条件字段
/// （wecom 5 分支、wecom_app 5 分支）。别扩。
class NotifyFieldCondition {
  const NotifyFieldCondition({required this.key, required this.values});

  final String key;
  final List<String> values;

  /// 解析失败一律返回 null = 无条件显示。读不懂的条件绝不能变成「隐藏」。
  static NotifyFieldCondition? tryParse(dynamic raw) {
    if (raw is! Map) {
      return null;
    }
    final key = raw['key']?.toString().trim() ?? '';
    if (key.isEmpty) {
      return null;
    }
    final rawValues = raw['values'];
    if (rawValues is! List || rawValues.isEmpty) {
      return null;
    }
    return NotifyFieldCondition(
      key: key,
      values: <String>[for (final item in rawValues) item?.toString() ?? ''],
    );
  }
}

/// 一个字段的定义。
///
/// 字段名 `isRequired` 而不是 `required`：后者在 Dart 里是构造参数位置的关键字，
/// `required this.required` 会读得很别扭。JSON 里仍然是 `required`。
class NotifyFieldSchema {
  const NotifyFieldSchema({
    required this.key,
    required this.label,
    this.widget = NotifyFieldWidget.input,
    this.placeholder = '',
    this.isRequired = false,
    this.defaultValue = '',
    this.options = const <NotifyFieldOption>[],
    this.showWhen,
  });

  factory NotifyFieldSchema.fromJson(Map<dynamic, dynamic> json) {
    final key = json['key']?.toString().trim() ?? '';
    final label = json['label']?.toString().trim() ?? '';
    final options = <NotifyFieldOption>[];
    final rawOptions = json['options'];
    if (rawOptions is List) {
      for (final item in rawOptions) {
        if (item is! Map) {
          continue;
        }
        final value = item['value']?.toString();
        if (value == null) {
          continue;
        }
        final optionLabel = item['label']?.toString().trim() ?? '';
        options.add(
          NotifyFieldOption(
            value: value,
            label: optionLabel.isEmpty ? value : optionLabel,
          ),
        );
      }
    }

    return NotifyFieldSchema(
      key: key,
      // 面板没给 label 就用 key —— 难看但能填。空标题的输入框才是真没法用。
      label: label.isEmpty ? key : label,
      widget: parseNotifyFieldWidget(json['widget']),
      placeholder: json['placeholder']?.toString() ?? '',
      isRequired: json['required'] == true,
      defaultValue: json['default']?.toString() ?? '',
      options: options,
      showWhen: NotifyFieldCondition.tryParse(json['show_when']),
    );
  }

  final String key;
  final String label;
  final NotifyFieldWidget widget;
  final String placeholder;
  final bool isRequired;

  /// 面板声明的默认值。只用作**表单初值**，不会凭空写进 config ——
  /// 见 [buildNotifyFieldValues] 里「用户没动过就不写」那一条。
  final String defaultValue;

  final List<NotifyFieldOption> options;
  final NotifyFieldCondition? showWhen;

  /// 实际该画哪种控件。
  ///
  /// 两处降级，方向都是「退成输入框」而不是「不画」：
  /// - 不认识的 widget（面板加了第五种控件）；
  /// - 声明成 select 却没给 options（理论上不会发生，发生了不能给个空下拉）。
  NotifyFieldWidget get effectiveWidget {
    if (widget == NotifyFieldWidget.unknown) {
      return NotifyFieldWidget.input;
    }
    if (widget == NotifyFieldWidget.select && options.isEmpty) {
      return NotifyFieldWidget.input;
    }
    return widget;
  }

  /// 下拉真正要渲染的选项。
  ///
  /// 当前值不在面板给的 options 里时（面板改了选项集合、DB 里有历史脏值、
  /// 青龙导入写进来的值…）**必须**把它补进去，否则：
  /// 用户点开下拉看不到自己当前的值，随手选一个就再也回不去了；
  /// 顺带也挡住了 Material 下拉那一类「value 找不到对应 item 直接 assert」的崩溃。
  List<NotifyFieldOption> renderOptions(String current) {
    if (options.any((option) => option.value == current)) {
      return options;
    }
    return <NotifyFieldOption>[
      NotifyFieldOption(
        value: current,
        label: current.isEmpty ? '未设置' : '$current（面板未声明）',
      ),
      ...options,
    ];
  }
}

/// 一个渠道类型。[fields] 为空 = 这台面板没下发字段定义（老面板），
/// 由 frozen_channel_fields_v300.dart 决定回落到什么。
class NotifyChannelSchema {
  const NotifyChannelSchema({
    required this.type,
    required this.name,
    this.fields = const <NotifyFieldSchema>[],
  });

  factory NotifyChannelSchema.fromJson(Map<dynamic, dynamic> json) {
    final type = json['type']?.toString().trim() ?? '';
    final name = json['name']?.toString().trim() ?? '';
    final fields = <NotifyFieldSchema>[];
    final rawFields = json['fields'];
    if (rawFields is List) {
      for (final item in rawFields) {
        if (item is! Map) {
          continue;
        }
        final field = NotifyFieldSchema.fromJson(item);
        if (field.key.isEmpty) {
          continue;
        }
        fields.add(field);
      }
    }

    return NotifyChannelSchema(
      type: type,
      name: name.isEmpty ? type : name,
      fields: fields,
    );
  }

  final String type;
  final String name;
  final List<NotifyFieldSchema> fields;
}

/// 解析 `GET /api/notifications/types` 的 data（已过 extractData）。
///
/// 老面板返回的是 `[{"type":"telegram","name":"Telegram"}]`，没有 `fields` ——
/// 解析出来就是一个 `fields` 为空的 [NotifyChannelSchema]，这本身就是形状探测的结果，
/// 不需要第二处版本判断。
List<NotifyChannelSchema> parseNotifyChannelSchemas(dynamic data) {
  if (data is! List) {
    return const <NotifyChannelSchema>[];
  }
  final result = <NotifyChannelSchema>[];
  for (final item in data) {
    if (item is! Map) {
      continue;
    }
    final schema = NotifyChannelSchema.fromJson(item);
    if (schema.type.isEmpty) {
      continue;
    }
    result.add(schema);
  }
  return result;
}

/// 按 `show_when` 过滤出当前该显示的字段，顺序不变。
///
/// [values] 是全部字段的当前值（含此刻不显示的那些）。
List<NotifyFieldSchema> visibleNotifyFields({
  required List<NotifyFieldSchema> fields,
  required Map<String, String> values,
}) {
  final declared = <String>{for (final field in fields) field.key};
  final result = <NotifyFieldSchema>[];
  for (final field in fields) {
    final condition = field.showWhen;
    if (condition == null) {
      result.add(field);
      continue;
    }
    // 条件依赖的键根本不在这个渠道的字段表里（面板写错，或它引用了一个
    // 这一版 APP 拿不到的键）→ 当作无条件显示。
    // 宁可多显示一个字段，也不能因为一条读不懂的条件把输入入口整个吞掉。
    if (!declared.contains(condition.key)) {
      result.add(field);
      continue;
    }
    if (condition.values.contains(values[condition.key] ?? '')) {
      result.add(field);
    }
  }
  return result;
}

const Map<String, dynamic> _emptyConfig = <String, dynamic>{};

/// 某个字段在服务端 config 里的**已有值**；null 表示这份配置里从没设置过它。
///
/// 返回值一定是 String —— 这是「config 值必须全是字符串」在读取侧的那一半：
/// 存量里可能有旧客户端写坏的 bool、青龙导入写的数字、以及早年 custom 渠道
/// 直接存成对象的 headers，读的时候就得转干净，否则一保存又原样写回去。
String? existingNotifyFieldValue(String key, Map<String, dynamic> config) {
  if (key == kSmtpSslConfigKey) {
    // 唯一一处按键名分叉。理由见 channel_config.dart 的 resolveExistingSmtpSslValue：
    // 面板读 SSL 时看 5 个键，schema 只声明得出 1 个，这个不对称 schema 表达不了。
    return resolveExistingSmtpSslValue(config);
  }

  final raw = config[key];
  if (raw == null) {
    return null;
  }
  if (raw is String) {
    return raw;
  }
  if (raw is Map || raw is List) {
    // 必须按 JSON 回显。Dart 的 `Map.toString()` 出来的 `{X-Token: abc}` 不是 JSON，
    // 用户点一下保存，一份合法的 headers 就变成了一段废字符串。
    return jsonEncode(raw);
  }
  // bool / 数字：面板读不了的投毒数据，转成字符串正好在这次保存时修掉。
  return raw.toString();
}

/// 表单初值：已有配置优先，其次面板声明的 default。
Map<String, String> buildNotifyFieldSeeds({
  required List<NotifyFieldSchema> fields,
  required Map<String, dynamic> existingConfig,
  required bool keepExistingConfig,
}) {
  final config = keepExistingConfig ? existingConfig : _emptyConfig;
  return <String, String>{
    for (final field in fields)
      field.key: existingNotifyFieldValue(field.key, config) ??
          field.defaultValue,
  };
}

/// 表单当前值 → 交给 `buildChannelConfigFromFields` 的 fieldValues。
///
/// [visibleFields] 只传**此刻显示着**的字段：show_when 不满足而没渲染的字段
/// 压根不进这个 map，于是它在 config 里的存量值被原样保留。
/// （用户把 msg_type 从 news 切到 text，不该把之前配好的 news_articles 删掉；
/// 面板 Web 端也是整份 configData 写回，行为一致。）
///
/// 「用户没动过就不写」那一条：某个键服务端本来没有、表单里显示的又正是
/// schema 给的 default，就不要凭空写进 config。否则「打开 → 一个字不改 → 保存」
/// 会往配置里塞一堆键，面板哪天改了默认值，用户配置里已经冻着一份旧的了。
/// 面板本来就会在读不到该键时用自己的默认值，不写和写一样。
///
/// 返回值全是 String，没有 dynamic。
Map<String, String> buildNotifyFieldValues({
  required List<NotifyFieldSchema> visibleFields,
  required Map<String, dynamic> existingConfig,
  required bool keepExistingConfig,
  required Map<String, String> draft,
}) {
  final config = keepExistingConfig ? existingConfig : _emptyConfig;
  final values = <String, String>{};
  for (final field in visibleFields) {
    final existing = existingNotifyFieldValue(field.key, config);
    final seed = existing ?? field.defaultValue;
    final text = (draft[field.key] ?? seed).trim();
    if (existing == null && text == seed.trim()) {
      continue;
    }
    values[field.key] = text;
  }
  return values;
}

/// `required` 的前端拦截。返回 null 表示通过，否则是给用户看的中文原因。
///
/// 只校验**此刻显示着**的字段：隐藏字段填不了，拦它等于让用户没法保存。
String? validateNotifyFields({
  required List<NotifyFieldSchema> visibleFields,
  required Map<String, String> values,
}) {
  for (final field in visibleFields) {
    if (!field.isRequired) {
      continue;
    }
    if ((values[field.key] ?? '').trim().isNotEmpty) {
      continue;
    }
    return '「${field.label}」不能为空';
  }
  return null;
}
