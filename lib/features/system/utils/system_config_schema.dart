// 系统设置页的 schema 解析、降级与回写 —— 纯数据变换，不依赖 Flutter。
//
// 为什么抽出来：这是一个「读取 → 修改 → 回写」的表单，而且是全 App 覆盖面最大的
// 一个（面板注册了 47 项配置）。回写写错一个键，用户在 Web 上配好的东西就没了，
// 且在 APP 里完全看不出来。闭包里的代码没法在不起 UI 的情况下断言，所以逻辑全部
// 放在这里，UI 只负责画。做法与 notifications/utils/channel_config.dart 一致。
//
// ── 契约来源（本次实读核对）─────────────────────────────────────────────
// 面板 `GET /api/configs` → server/handler/config.go 的 buildConfigResponseItem：
//
//   item := gin.H{"registered": false, "updated_at": nil}
//   if cfg != nil { item["value"], item["description"], item["updated_at"] = ... }
//   if def != nil {
//       item["registered"]    = true
//       item["default_value"] = def.DefaultValue
//       item["value_type"]    = def.ValueType     // string / int / bool / enum
//       item["group"]         = def.Group
//       item["description"]   = def.Description
//       if cfg == nil || cfg.Value == "" { item["value"] = def.DefaultValue }
//       if len(def.Options) > 0 { item["options"] = def.Options }   // [{value,label}]
//   }
//
// 也就是说 **v3.0.0 的面板就已经下发了完整 schema**，这一页改成 schema 驱动
// 不需要面板改任何东西。面板正在补 label / group_label / order / secret / min / max，
// 但用户的面板不一定升级，所以这里每一个新字段都必须能降级。
//
// ── 为什么用形状探测而不是版本号 ─────────────────────────────────────────
// handler.Version 由 release 流水线用 ldflags 注入，源码默认值就是 "3.0.0"，
// 任何本地 `go build` / fork 构建都自称 3.0.0。版本号不可信，只看字段在不在。
//
// ── 三个绝不能踩的坑 ────────────────────────────────────────────────────
// 1. bool 的值在面板里**是字符串** "true"/"false"（newBoolConfig 走
//    strconv.FormatBool），不是 JSON bool。`PUT /configs/batch` 的请求体是
//    `map[string]string`，写进一个 JSON bool 会让整份 ShouldBindJSON 失败。
//    这与通知渠道 smtp_ssl 投毒是同一个病，见 channel_config.dart 的注释。
// 2. 只回写**改动过**的键。BatchSet 是逐键 SetConfig 且中途失败就 400 返回
//    （前面的键已经落库），全量回写会把 47 项挨个重写一遍，任何一项校验不过
//    都会变成「一半保存了一半没保存」。
// 3. `registered == false` 的键（面板运行时自己写的临时状态，例如
//    auto_update_pending_version）没有 schema，一律不渲染、也一律不回写。

/// 面板 SystemConfigValueType 的四个取值
/// （server/model/system_config_registry.go 的 SystemConfigType* 常量）。
///
/// [unknown] 不是面板的类型，是「面板加了第五种类型而这一版 APP 不认识」的兜底：
/// 降级成普通输入框，**绝不隐藏字段** —— 隐藏等于用户在 APP 上永远改不了它。
enum ConfigValueType { string, integer, boolean, enumerated, unknown }

ConfigValueType parseConfigValueType(dynamic raw) {
  switch (raw?.toString().trim().toLowerCase() ?? '') {
    case 'string':
      return ConfigValueType.string;
    case 'int':
      return ConfigValueType.integer;
    case 'bool':
      return ConfigValueType.boolean;
    case 'enum':
      return ConfigValueType.enumerated;
    default:
      return ConfigValueType.unknown;
  }
}

/// 下拉选项，对齐面板的 `SystemConfigOption{value,label}`。
class SystemConfigOption {
  const SystemConfigOption({required this.value, required this.label});

  final String value;
  final String label;

  @override
  bool operator ==(Object other) =>
      other is SystemConfigOption &&
      other.value == value &&
      other.label == label;

  @override
  int get hashCode => Object.hash(value, label);
}

/// 面板注册了、但**不是用户设置**的键：值由面板自己写，APP 只读显示。
///
/// - `auto_update_last_checked_at`：静默更新巡检写入
///   （server/handler/system_update_auto.go 的 autoUpdateLastCheckedAtKey）。
///   面板 Web 端同样只读不给编辑框（views/settings/useSettingsOverview.ts 里
///   是 `configApi.get` 显示 + 自己 `configApi.set` 回写）。
/// - `panel_service_manager` / `panel_service_name`：由 `ddp service install`
///   命令写入（server/cmd/ddp/service_commands.go），是**安装事实**不是偏好。
///   面板更新流程按它去 `systemctl stop/start`
///   （server/service/panel_runtime.go 的 ResolvePanelServiceName）。
///   在手机上把服务名改错 → 二进制已经被替换、systemd 单元又拉不起来 →
///   **面板起不来，而且正因为面板起不来，没法再从 APP 改回去**。
///   面板自己的 Web 端也没有这两项的 UI，APP 不该比 Web 更危险。
///
/// 渲染成只读行而不是直接隐藏：隐藏会让「为什么我的更新失败」无从排查。
const Set<String> kReadOnlySystemConfigKeys = <String>{
  'auto_update_last_checked_at',
  'panel_service_manager',
  'panel_service_name',
};

/// 可改、但改错代价明显高于其它项的键，渲染时附一行警告。
///
/// 这张表只影响**提示文案**，不影响是否渲染、不影响取值、不影响回写。
/// 表里的键从面板注册表消失时，这里的条目自然不会再被查到，不会有残留影响。
const Map<String, String> kSystemConfigRiskNotes = <String, String>{
  'panel_runtime_mode': '改成「仅写文件」后 docker logs 将看不到面板日志，请改用面板日志页查看。',
  'trusted_proxy_cidrs': '填错会让面板取到错误的客户端 IP，可能被自己的 IP 白名单挡在门外。',
  'captcha_enabled': '开启前请先填好验证码平台 ID 与密钥，否则所有端都可能登录不了。',
  'captcha_fail_mode': '选「严格拦截」时，验证码上游一旦不可用就会拒绝全部登录。',
};

/// APP 侧补充的说明，追加显示在面板 `description` 之后。
///
/// 只在「面板的一句话说明会让用户做出危险决定」时才加，目前只有一条：
/// `proxy_url` 的 description 是「出站请求代理地址」，看不出它**只影响面板出站**、
/// 不影响局域网访问面板 —— 实际支持里反复被问。
/// 这一条是纯增量，键从注册表消失时自然不会被查到。
const Map<String, String> kSystemConfigExtraHints = <String, String>{
  'proxy_url': '仅当服务器访问 GitHub、npm、pip、Docker 镜像等外部网络需要代理时填写；留空表示面板直连，不影响局域网访问面板。',
};

/// 老面板不下发 `secret` 时的兜底打码名单。
///
/// 为什么不按键名猜（含 key / secret / token / password 就打码）：
/// 1. 值本来就是**明文下发**的（config.go 无条件写 `item["value"]`），
///    打码不是安全边界只是防肩窥，猜错的收益远小于猜错的代价；
/// 2. 键名启发式会在面板加新键时无声地改变行为 —— 正是本期要消灭的那种耦合。
/// 所以宁可漏打码也不猜，只列 v3.0.0 注册表里确定是密文的两项。
/// 面板补上 `secret` 之后这张表就不会再被查到（服务端说了算，本表只在字段缺失时生效）。
///
/// 另外：打码的输入框一律带「显示」开关，所以两个方向猜错都不会让人改不了值。
const Set<String> kFallbackSecretConfigKeys = <String>{
  'captcha_key',
  'backup_schedule_password',
};

/// group slug → 中文分组名的**降级**表。
///
/// 面板补上 `group_label` 后这张表不会被查到；表里没有的 slug 原样显示 slug
/// （英文 slug 当中文分组标题很难看，但比隐藏整组配置好得多）。
const Map<String, String> _fallbackGroupLabels = <String, String>{
  'tasks': '任务运行',
  'subscription': '订阅',
  'alerts': '资源告警',
  'network': '网络与更新',
  'security': '安全',
  'backup': '定时备份',
  'branding': '面板外观',
};

/// 老面板没有 `order` 时的分组显示顺序。
///
/// `GET /api/configs` 返回的是 **map 不是 list**（config.go 里
/// `data := make(map[string]interface{})`），而 Go 的 encoding/json 序列化 map 时
/// 会把键按字典序排 —— 也就是说线上顺序是「按 key 字母序」，**不是注册顺序**。
/// 靠 Dart 解码后的 Map 迭代顺序去还原注册顺序是空想，所以这里显式排序。
///
/// 表里没有的 slug 排到末尾，按 slug 字母序。
const List<String> _fallbackGroupOrder = <String>[
  'tasks',
  'subscription',
  'alerts',
  'network',
  'security',
  'backup',
  'branding',
];

/// 没有 `order` 时用的哨兵值。取一个足够大的正数，让有 order 的项永远排在前面。
const int _noOrder = 1 << 30;

/// 从 `description` 推标题时的长度上限。
///
/// 超出就截断加省略号 —— 完整 description 会原样显示在输入框下方作为说明，
/// 标题截断不丢信息。不截断的话最长一条（update_image_mirror）有 28 个字，
/// 会把一行标题撑成两行，和下面的说明文字糊在一起。
const int _maxDerivedLabelLength = 20;

/// 从 description 推标题时的断点。
///
/// 面板的 description 有两种形态：短说明（"定时任务最大并发数"）和
/// 「短说明 + 括号/冒号补充」（"面板时区（影响日志、定时任务日期判断和脚本 TZ）"、
/// "验证码上游异常策略：open=放行，strict=严格拦截"）。取第一段就是很好的标题。
///
/// 刻意**不含**逗号和句号：逗号在中文里更多是并列而不是「补充说明开始」，
/// 按逗号切会把 "可信代理 CIDR/IP 列表" 这类完整短语切碎。
const List<String> _labelStopChars = <String>['（', '(', '：', ':', '；', ';', '\n'];

/// 一项系统配置（已完成全部降级解析）。
class SystemConfigItem {
  const SystemConfigItem({
    required this.key,
    required this.value,
    required this.defaultValue,
    required this.valueType,
    required this.group,
    required this.groupLabel,
    required this.label,
    required this.description,
    required this.order,
    required this.secret,
    required this.min,
    required this.max,
    required this.options,
    required this.readOnly,
    required this.riskNote,
  });

  final String key;

  /// 服务端当前值。面板在 `cfg == nil || cfg.Value == ""` 时已经替换成
  /// default_value，所以这里拿到的就是「面板实际会用的值」。
  final String value;
  final String defaultValue;
  final ConfigValueType valueType;
  final String group;
  final String groupLabel;

  /// 输入框标题。老面板没有 `label` 时由 [deriveConfigLabel] 从 description 推。
  final String label;

  /// 完整说明，渲染在输入框下方。
  final String description;

  /// 注册顺序。老面板没有这个字段时为 null。
  final int? order;

  /// 是否打码显示。老面板没有这个字段时走 [kFallbackSecretConfigKeys]。
  final bool secret;

  /// 整数范围。老面板没有这两个字段时为 null —— 此时**不做前端范围校验**，
  /// 由面板 normalize 返回 400，错误原文透给用户。
  final int? min;
  final int? max;

  final List<SystemConfigOption> options;

  /// 见 [kReadOnlySystemConfigKeys]。
  final bool readOnly;

  /// 见 [kSystemConfigRiskNotes]。
  final String? riskNote;

  /// description 是否值得单独显示。
  ///
  /// 老面板下 label 就是从 description 切出来的头段，两者相等时再显示一遍
  /// 等于同一句话写两行。反过来，label 被截断（结尾是省略号）时**必须**显示 ——
  /// 那正是完整说明最有价值的时候。
  bool get hasHint => description.isNotEmpty && description != label;

  /// 该用哪种控件。
  ///
  /// enum 但服务端没给 options（理论上不会发生，但发生了不能白屏）→ 退成输入框。
  ConfigValueType get effectiveType {
    if (valueType == ConfigValueType.enumerated && options.isEmpty) {
      return ConfigValueType.string;
    }
    return valueType;
  }

  /// 选择器要渲染的选项。
  ///
  /// 如果当前值不在服务端给的 options 里（面板改了枚举、DB 里有历史脏值、
  /// 或者青龙导入写进来的值），**必须**把它补进去，否则：
  /// 用户点开选择器看不到自己当前的值，随手选一个就再也回不去了。
  /// 顺带也挡住了 Material 下拉那一类「value 找不到对应 item 直接 assert」的崩溃。
  List<SystemConfigOption> renderOptions() {
    if (options.any((option) => option.value == value)) {
      return options;
    }
    return <SystemConfigOption>[
      SystemConfigOption(value: value, label: '$value（面板未声明）'),
      ...options,
    ];
  }

  /// bool 的当前值。面板存的是字符串，这里按面板 parseBoolString 的语义读。
  bool get boolValue => parseConfigBool(value);

  /// 表单值 → 回写值。
  ///
  /// bool 一律收敛成 "true"/"false" 两个**字符串**；其余去掉首尾空白
  /// （面板的 normalize 本来也会 TrimSpace，这里先做只是为了让「有没有改动」
  /// 的比较不被空格干扰）。
  String normalizeForWrite(String draft) {
    if (valueType == ConfigValueType.boolean) {
      return parseConfigBool(draft) ? 'true' : 'false';
    }
    return draft.trim();
  }
}

/// 一个分组及其下的配置项，已排好序。
class SystemConfigGroup {
  const SystemConfigGroup({
    required this.group,
    required this.label,
    required this.items,
  });

  final String group;
  final String label;
  final List<SystemConfigItem> items;
}

/// 按面板 `parseBoolString`（server/model/system_config_registry.go）的语义
/// 读字符串布尔值：1/true/yes/on 为真，0/false/no/off 及任何无法识别的值为假
/// （面板对无法识别的值也是取 false，这里跟着取，保证 APP 显示的就是面板会做的事）。
///
/// 也认 JSON bool —— 那是历史上客户端写坏的数据，面板读不了，但 APP 自己得能
/// 读回来，否则用户打开设置页会看到与已保存内容不符的状态。
bool parseConfigBool(dynamic raw) {
  if (raw is bool) {
    return raw;
  }
  switch (raw?.toString().trim().toLowerCase() ?? '') {
    case '1':
    case 'true':
    case 'yes':
    case 'on':
      return true;
    default:
      return false;
  }
}

/// 老面板没有 `label` 时，从 `description` 推一个短标题。
///
/// 优先级：服务端 label > description 的第一段 > key。
///
/// 为什么不直接用 key：`max_log_content_size` 这种下划线英文当中文界面的
/// 输入框标题，可读性比 description 还差。
/// 为什么不直接用整句 description：它是**说明**不是标题，最长一条 40 多个字
/// （panel_runtime_mode 是三行），直接当标题会把表单撑爆。
/// 完整 description 仍然会显示在输入框下方，所以切头段不丢信息。
String deriveConfigLabel(String key, {String? label, String? description}) {
  final explicit = label?.trim() ?? '';
  if (explicit.isNotEmpty) {
    return explicit;
  }

  final desc = description?.trim() ?? '';
  if (desc.isEmpty) {
    return key;
  }

  var cut = desc.length;
  for (var i = 0; i < desc.length; i++) {
    if (!_labelStopChars.contains(desc[i])) {
      continue;
    }
    // "http://" 里的冒号不是断点，否则 "代理地址：http://..." 之外的写法
    // （"填 http://x 开头的地址"）会被切成 "填 http"。
    if (desc.startsWith('://', i)) {
      continue;
    }
    cut = i;
    break;
  }

  var head = desc.substring(0, cut).trim();
  if (head.isEmpty) {
    head = desc;
  }
  if (head.length > _maxDerivedLabelLength) {
    head = '${head.substring(0, _maxDerivedLabelLength)}…';
  }
  return head;
}

/// 老面板没有 `group_label` 时，把英文 slug 翻成中文分组名。
String resolveConfigGroupLabel(String group, {String? groupLabel}) {
  final explicit = groupLabel?.trim() ?? '';
  if (explicit.isNotEmpty) {
    return explicit;
  }
  final slug = group.trim();
  if (slug.isEmpty) {
    return '其它';
  }
  return _fallbackGroupLabels[slug] ?? slug;
}

/// 解析 `GET /api/configs` 的 data（已经过 extractData）成分好组、排好序的列表。
///
/// 只收 `registered == true` 的项：其余是面板运行时自己写的临时状态
/// （auto_update_pending_version 之类），没有 schema，渲染出来也没有意义，
/// 而且**渲染了就有被回写覆盖的风险**。
List<SystemConfigGroup> parseSystemConfigGroups(dynamic data) {
  if (data is! Map) {
    return const <SystemConfigGroup>[];
  }

  final items = <SystemConfigItem>[];
  for (final entry in data.entries) {
    final key = entry.key.toString();
    final raw = entry.value;
    if (raw is! Map) {
      continue;
    }
    if (raw['registered'] != true) {
      continue;
    }
    items.add(_parseItem(key, raw));
  }

  return _groupAndSort(items);
}

SystemConfigItem _parseItem(String key, Map<dynamic, dynamic> raw) {
  final group = raw['group']?.toString().trim() ?? '';
  final description = raw['description']?.toString().trim() ?? '';
  final order = _asInt(raw['order']);

  return SystemConfigItem(
    key: key,
    value: raw['value']?.toString() ?? '',
    defaultValue: raw['default_value']?.toString() ?? '',
    valueType: parseConfigValueType(raw['value_type']),
    group: group,
    groupLabel: resolveConfigGroupLabel(
      group,
      groupLabel: raw['group_label']?.toString(),
    ),
    label: deriveConfigLabel(
      key,
      label: raw['label']?.toString(),
      description: description,
    ),
    description: description,
    order: order,
    // 形状探测：字段在就听服务端的，字段不在（老面板）才查本地兜底名单。
    secret: raw.containsKey('secret')
        ? raw['secret'] == true
        : kFallbackSecretConfigKeys.contains(key),
    min: _asInt(raw['min']),
    max: _asInt(raw['max']),
    options: _parseOptions(raw['options']),
    readOnly: kReadOnlySystemConfigKeys.contains(key),
    riskNote: kSystemConfigRiskNotes[key],
  );
}

List<SystemConfigOption> _parseOptions(dynamic raw) {
  if (raw is! List) {
    return const <SystemConfigOption>[];
  }
  final result = <SystemConfigOption>[];
  for (final item in raw) {
    if (item is! Map) {
      continue;
    }
    final value = item['value']?.toString();
    if (value == null) {
      continue;
    }
    final label = item['label']?.toString().trim() ?? '';
    result.add(
      SystemConfigOption(value: value, label: label.isEmpty ? value : label),
    );
  }
  return result;
}

List<SystemConfigGroup> _groupAndSort(List<SystemConfigItem> items) {
  final buckets = <String, List<SystemConfigItem>>{};
  for (final item in items) {
    buckets.putIfAbsent(item.group, () => <SystemConfigItem>[]).add(item);
  }

  final groups = <SystemConfigGroup>[];
  for (final entry in buckets.entries) {
    final sorted = [...entry.value]..sort(_compareItems);
    groups.add(
      SystemConfigGroup(
        group: entry.key,
        label: sorted.first.groupLabel,
        items: sorted,
      ),
    );
  }

  groups.sort((a, b) {
    final rankDiff = _groupRank(a).compareTo(_groupRank(b));
    if (rankDiff != 0) {
      return rankDiff;
    }
    return a.group.compareTo(b.group);
  });
  return groups;
}

int _compareItems(SystemConfigItem a, SystemConfigItem b) {
  final orderDiff = (a.order ?? _noOrder).compareTo(b.order ?? _noOrder);
  if (orderDiff != 0) {
    return orderDiff;
  }
  // 老面板全员没有 order，落到这里 —— 按 key 字典序，与线上 JSON 的实际顺序
  // 一致（Go 的 encoding/json 序列化 map 时按键排序），至少是**稳定**的。
  return a.key.compareTo(b.key);
}

/// 分组的排序键：组内最小的 order；全组都没有 order 时用本地兜底顺序表。
int _groupRank(SystemConfigGroup group) {
  var best = _noOrder;
  for (final item in group.items) {
    final order = item.order;
    if (order != null && order < best) {
      best = order;
    }
  }
  if (best != _noOrder) {
    return best;
  }
  final index = _fallbackGroupOrder.indexOf(group.group);
  return _noOrder + (index < 0 ? _fallbackGroupOrder.length : index);
}

int? _asInt(dynamic raw) {
  if (raw is int) {
    return raw;
  }
  if (raw is num) {
    return raw.toInt();
  }
  if (raw is String) {
    return int.tryParse(raw.trim());
  }
  return null;
}

/// 单项前端校验。返回 null 表示通过，否则是给用户看的中文原因。
///
/// 只做面板一定会拒绝、且拒绝理由用户看不懂的两件事：类型和范围。
/// 其余（代理地址格式、cron 合法性、时区名…）交给面板 normalize，
/// 400 的原文比 APP 自己编一套规则准确，也不会随面板升级而过期。
String? validateSystemConfigValue(SystemConfigItem item, String draft) {
  if (item.valueType != ConfigValueType.integer) {
    return null;
  }

  final text = draft.trim();
  if (text.isEmpty) {
    // 面板的 int normalize 在空串时返回 default_value，是合法的「恢复默认」。
    return null;
  }

  final parsed = int.tryParse(text);
  if (parsed == null) {
    return '「${item.label}」需要填整数';
  }

  final min = item.min;
  final max = item.max;
  if (min != null && max != null) {
    if (parsed < min || parsed > max) {
      return '「${item.label}」需在 $min-$max 之间';
    }
    return null;
  }
  if (min != null && parsed < min) {
    return '「${item.label}」不能小于 $min';
  }
  if (max != null && parsed > max) {
    return '「${item.label}」不能大于 $max';
  }
  return null;
}

/// 构造 `PUT /configs/batch` 的请求体，**只含真正改动过的键**。
///
/// [items] 是本次渲染出来的全部项，[draft] 是表单当前值（key → 原始文本）。
///
/// 三条硬规则，每一条都对应一个踩过或差点踩到的坑：
/// 1. 只回写 `draft` 里出现过、且与服务端当前值**不同**的键。
///    面板 BatchSet 是逐键 SetConfig、中途失败直接 400 返回，前面的键已经落库；
///    全量回写会让「一项填错」变成「一半保存了一半没保存」。
/// 2. `readOnly` 的键永不回写（见 [kReadOnlySystemConfigKeys]）。
/// 3. `items` 里没有的键（`registered == false` 的运行时状态、以及面板将来
///    新增而这版 APP 还不认识的键）压根不进 payload，因此**不会被覆盖**。
///    这就是「未知字段不丢失」在本页的形态。
///
/// 返回值全部是 String —— 面板的 BatchSet 绑定的是 `map[string]string`，
/// 混进 JSON bool 会让整份 ShouldBindJSON 失败。
Map<String, String> buildSystemConfigWritePayload({
  required List<SystemConfigItem> items,
  required Map<String, String> draft,
}) {
  final payload = <String, String>{};
  for (final item in items) {
    if (item.readOnly) {
      continue;
    }
    final raw = draft[item.key];
    if (raw == null) {
      continue;
    }
    final next = item.normalizeForWrite(raw);
    if (next == item.value) {
      continue;
    }
    payload[item.key] = next;
  }
  return payload;
}

/// 把分好组的结构摊平成一维列表，顺序即渲染顺序。
List<SystemConfigItem> flattenSystemConfigItems(
  List<SystemConfigGroup> groups,
) => <SystemConfigItem>[for (final group in groups) ...group.items];
