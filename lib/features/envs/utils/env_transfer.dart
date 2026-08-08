// 环境变量「导出 → 离线编辑 → 导入」的纯数据变换。
//
// 为什么抽成一个不 import Flutter 的文件：往返丢东西在手机上**完全看不出来** ——
// 少一个 remarks、把「同名 3 条」压成 1 条、面板新加的字段被吃掉，
// 界面上长得一模一样。这类回归只能靠单测钉死（test/features/envs/env_transfer_test.dart）。
//
// **格式不是 APP 发明的**：逐字对齐面板 `GET /api/envs/export-all` 的响应
// （server/handler/env.go 的 `ExportAll`）与 `POST /api/envs/import` 的请求体
// （同文件 `Import`），也就是面板 Web 端「导出 JSON / 导入」用的同一份格式
// （web/src/views/envs/index.vue 的 `handleExportAll` +
// web/src/views/envs/components/EnvImportDialog.vue）。
//
// 面板另有 `POST /envs/export-files`（shell / js / python）。那三种是**给脚本 source 用**的：
// 同名多条会被 `JoinTaskEnvValues` 合并成一行（`&` 分隔，值里含 `&` 时升级成 `&&` 并转义），
// remarks / 分组 / 启用状态全部丢掉，而且面板**没有对应的导入口**。
// 所以它们不能作为「导出改完再导入」的载体，本文件不碰。
//
// 踩过 / 绕开的坑，改动前先读：
//
// 1. **`groups` 即使为空也必须发出去。** 面板 `envGroupValueFromImportItem` 是按
//    「键在不在」决定要不要写 group 的：两个键都不发时 merge 会**保留旧分组**，
//    于是「在面板上清掉分组 → 导出 → 导回」这一圈把分组又装回来了。
//
// 2. **`enabled` 是 JSON 布尔。** 这一条与通知渠道 config「值必须全是字符串」
//    正好相反，别顺手抄过去：面板这里读的是 `item["enabled"].(bool)`，
//    给字符串会类型断言失败并静默退回 `true` —— 禁用状态无声丢失。
//
// 3. **面板认 `status`（青龙格式，0 = 启用）且优先级高于 `enabled`。**
//    所以解析时按同样的优先级折进 [EnvTransferItem.enabled]，
//    并且**不把 `status` 留进 extras** —— 留着会让用户手改的 `enabled` 不生效。
//
// 4. **这一版 APP 不认识的键统统进 [EnvTransferItem.extras] 原样带回去。**
//    面板将来给 export-all 加字段（`sort_order` / `position` / 新的什么），
//    APP 不发新版也不会在往返里把它吃掉。这是 spec 对「读取-修改-回写」的硬性要求。

import 'dart:convert';

/// 面板 `POST /api/envs/import` 的请求体上限。
///
/// 对应 server/handler/env.go 的 `maxEnvRequestBodySize = 1 << 20`：超了服务端直接
/// 回 400「请求体过大（最大 1MB）」。本地先算一次能给出「当前 X，请分批」这种可操作的提示，
/// 而不是把服务端那句话原样甩给用户。
const int kEnvImportMaxBodyBytes = 1 << 20;

/// 面板对变量名的校验规则（server/handler/env.go 的 `envNamePattern`）。
/// 不匹配的条目面板会逐条跳过并写进 `errors`，不会整批失败。
final RegExp _envNamePattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

bool isValidEnvName(String name) => _envNamePattern.hasMatch(name);

/// 分组分隔符，与面板 `model.SplitEnvGroups` 一致 —— 注意它认**中文逗号和分号**。
///
/// 这里没复用 `shared/models/env_var.dart` 里的 `_splitEnvGroups`：那个只切半角逗号，
/// 够用是因为它读的永远是面板已经规范化过的 `group` 字段。而这里读的是**用户手改过的
/// JSON**，中文标点很常见，切不开就会变成一个叫「生产；通知」的分组。
final RegExp _envGroupSeparator = RegExp(r'[,，;；\n\r\t]');

/// 切分分组串：trim、丢空、去重，顺序保持首次出现的顺序。
List<String> splitEnvGroups(String raw) {
  final seen = <String>{};
  final result = <String>[];
  for (final field in raw.split(_envGroupSeparator)) {
    final group = field.trim();
    if (group.isEmpty || !seen.add(group)) {
      continue;
    }
    result.add(group);
  }
  return result;
}

/// 合并成面板存库用的逗号串。每个元素自己也会再切一次 —— 与面板
/// `model.JoinEnvGroups` 内部对每个元素调 `SplitEnvGroups` 的行为一致。
String joinEnvGroups(Iterable<String> groups) {
  final seen = <String>{};
  final result = <String>[];
  for (final raw in groups) {
    for (final group in splitEnvGroups(raw)) {
      if (!seen.add(group)) {
        continue;
      }
      result.add(group);
    }
  }
  return result.join(',');
}

/// 给「同名多条」一个人看得懂的标识。
///
/// 变量名不足以定位一条记录（多账号场景就是靠同名多条实现的），
/// 面板 merge 认领时用的键是 `(name, remarks)`，提示文案也必须带上 remarks。
String describeEnvIdentity(String name, String remarks) {
  final safeName = name.isEmpty ? '(空名称)' : name;
  return remarks.isEmpty ? safeName : '$safeName（备注：$remarks）';
}

/// 已被本文件消费掉的键。剩下的一律进 [EnvTransferItem.extras] 原样保留。
const Set<String> _consumedEnvKeys = <String>{
  'name',
  'value',
  'remarks',
  'group',
  'groups',
  'enabled',
  // status 被折进 enabled 了，不能再留一份 —— 面板读 status 的优先级更高，
  // 留着会让用户手改的 enabled 静默失效。
  'status',
};

/// 导出 / 导入的一条记录。一条就是面板里的一行，**同名多条就是多条**。
class EnvTransferItem {
  final String name;
  final String value;
  final String remarks;
  final List<String> groups;
  final bool enabled;

  /// 面板下发了、但这一版 APP 不认识的键。原样带回请求体，保证往返不丢。
  final Map<String, dynamic> extras;

  const EnvTransferItem({
    required this.name,
    this.value = '',
    this.remarks = '',
    this.groups = const <String>[],
    this.enabled = true,
    this.extras = const <String, dynamic>{},
  });

  /// 面板存库用的逗号串形态。
  String get group => joinEnvGroups(groups);

  /// 面板 merge 认领记录用的业务键：`(name, remarks)`。
  ///
  /// 带**长度前缀**而不是直接拿分隔符拼：合法变量名不含冒号，但**非法名字也会走到
  /// 这里**（体检的职责恰恰是把它们找出来），直接拼会让 `A` + `B:C` 与 `A:B` + `C`
  /// 撞成同一个键，把两条不相干的记录误报成「同名多条」。
  String get identityKey => '${name.length}:$name:$remarks';

  String get identityLabel => describeEnvIdentity(name, remarks);

  /// 同时发 `group` 与 `groups`（面板 export-all 也是两个都发）。
  /// 面板 import 优先看 `groups`；两个都留着是为了让这份 JSON 直接粘进
  /// 面板 Web 的导入框也是同一个结果。
  Map<String, dynamic> toJson() => <String, dynamic>{
    // extras 先铺，已知键随后覆盖 —— 虽然 extras 里按定义不会有已知键，
    // 但顺序写死了就不怕以后有人往 extras 里塞东西。
    ...extras,
    'name': name,
    'value': value,
    'remarks': remarks,
    'group': group,
    'groups': groups,
    'enabled': enabled,
  };

  factory EnvTransferItem.fromJson(Map<String, dynamic> json) {
    final rawGroups = json['groups'];
    final List<String> groups;
    if (rawGroups is List) {
      groups = splitEnvGroups(
        rawGroups.map((item) => item?.toString() ?? '').join(','),
      );
    } else if (rawGroups is String) {
      groups = splitEnvGroups(rawGroups);
    } else {
      groups = splitEnvGroups(json['group']?.toString() ?? '');
    }

    // 优先级逐字对齐面板 Import：status（青龙，0 = 启用）> enabled > 默认 true。
    final rawStatus = json['status'];
    final rawEnabled = json['enabled'];
    final bool enabled;
    if (rawStatus is num) {
      enabled = rawStatus == 0;
    } else if (rawEnabled is bool) {
      enabled = rawEnabled;
    } else {
      enabled = true;
    }

    final extras = <String, dynamic>{};
    for (final entry in json.entries) {
      if (_consumedEnvKeys.contains(entry.key)) {
        continue;
      }
      extras[entry.key] = entry.value;
    }

    return EnvTransferItem(
      name: json['name']?.toString() ?? '',
      value: json['value']?.toString() ?? '',
      remarks: json['remarks']?.toString() ?? '',
      groups: groups,
      enabled: enabled,
      extras: extras,
    );
  }
}

/// 导出文本。两空格缩进，与面板 Web 的 `JSON.stringify(res.data, null, 2)` 一致。
String encodeEnvTransferJson(List<EnvTransferItem> items) =>
    const JsonEncoder.withIndent(
      '  ',
    ).convert(items.map((item) => item.toJson()).toList());

/// 解析结果。[error] 非空表示这段文本压根不能用，调用方**必须**提示而不是当成 0 条。
class EnvTransferParseResult {
  final List<EnvTransferItem> items;
  final String? error;

  /// 数组里不是对象的元素个数。它们被跳过了，但用户有权知道。
  final int skipped;

  const EnvTransferParseResult({
    this.items = const <EnvTransferItem>[],
    this.error,
    this.skipped = 0,
  });

  bool get ok => error == null;
}

EnvTransferParseResult parseEnvTransferJson(String raw) {
  final text = raw.trim();
  if (text.isEmpty) {
    return const EnvTransferParseResult(error: '内容为空');
  }

  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (error) {
    return EnvTransferParseResult(error: 'JSON 格式不正确：${error.message}');
  }

  // 面板 Web 的导入框只认顶层数组；这里额外认 `{"envs": [...]}`，因为那正是面板
  // `POST /envs/import` 的请求体形状，从接口文档抄一段过来很常见。
  // **只多认这一种** —— 每多认一种，就多一种「APP 认识而面板不认识」的格式。
  final List<dynamic> list;
  if (decoded is List) {
    list = decoded;
  } else if (decoded is Map && decoded['envs'] is List) {
    list = decoded['envs'] as List;
  } else {
    return const EnvTransferParseResult(
      error: '顶层需要是数组，或 {"envs": [...]}',
    );
  }

  final items = <EnvTransferItem>[];
  var skipped = 0;
  for (final entry in list) {
    if (entry is Map<String, dynamic>) {
      items.add(EnvTransferItem.fromJson(entry));
    } else if (entry is Map) {
      items.add(
        EnvTransferItem.fromJson(
          entry.map((key, value) => MapEntry(key.toString(), value)),
        ),
      );
    } else {
      skipped++;
    }
  }

  return EnvTransferParseResult(items: items, skipped: skipped);
}

/// 面板 `POST /envs/import` 支持的两种模式，**没有第三种**。
///
/// 刻意不自己拼一个「追加」模式（用 `POST /envs` 的数组纯 insert 也做得到）：
/// 那会变成一种只有 APP 有、Web 上找不到的行为，而且 `POST /envs` 不收 `enabled`，
/// 禁用的变量导进去会全部变成启用。
enum EnvImportMode {
  /// 按 `(name, remarks)` 认领面板已有记录：命中就更新 value / enabled / group，
  /// 没命中就新增。不会删除文件里没有的变量。
  merge('merge'),

  /// 先清空**全部**环境变量，再按文件顺序纯 insert。同名多条原样落库。
  replace('replace');

  const EnvImportMode(this.wireValue);

  final String wireValue;
}

Map<String, dynamic> buildEnvImportRequest({
  required List<EnvTransferItem> items,
  required EnvImportMode mode,
}) => <String, dynamic>{
  'envs': items.map((item) => item.toJson()).toList(),
  'mode': mode.wireValue,
};

/// 导入前的本地体检结果。
class EnvImportPreflight {
  final int total;

  /// 不符合面板变量名规则的名字（去重，保持出现顺序）。面板会逐条跳过并写进
  /// `errors`，所以这只是警告，不拦。
  final List<String> invalidNames;

  /// **合并模式下会被压平的多账号记录。**
  ///
  /// 面板 merge 是「按 `(name, remarks)` 找到第一条就更新」：文件里同一个
  /// `(name, remarks)` 出现 N 次，最终只会剩下**一条**，值是最后一条的。
  /// 这是无声的数据损坏，所以它是唯一会 [blocked] 的业务级问题。
  final List<String> collapsedIdentities;

  /// 面板上**已经**有多条同 `(name, remarks)` 的记录。
  ///
  /// 合并只会更新其中一条（`First()` 取到的那条），其余原样不动。
  /// 不算丢数据（用户本来就是要写这个值），但「更新了哪一条」不确定，值得告知。
  /// 这也是面板 `PUT /envs/by-name` 直接报 409 拒绝的同一类情况 ——
  /// import 没有那道守卫，所以 APP 自己先看一眼。
  final List<String> ambiguousIdentities;

  /// 按最终请求体算出来的字节数。
  final int payloadBytes;

  const EnvImportPreflight({
    required this.total,
    required this.payloadBytes,
    this.invalidNames = const <String>[],
    this.collapsedIdentities = const <String>[],
    this.ambiguousIdentities = const <String>[],
  });

  bool get oversized => payloadBytes > kEnvImportMaxBodyBytes;

  /// 不许提交。三种：没内容、超体积、合并模式会压平多账号。
  bool get blocked => total == 0 || oversized || collapsedIdentities.isNotEmpty;
}

/// 导入前体检。
///
/// [existing] 是「面板上现在有什么」，只用于 [EnvImportPreflight.ambiguousIdentities]
/// 这一条提醒。传一份被搜索/分组筛过的子集也不会出错，最坏情况是少给一条提醒；
/// 真正会造成数据损坏的 [EnvImportPreflight.collapsedIdentities] 只看导入文件本身。
EnvImportPreflight analyzeEnvImport({
  required List<EnvTransferItem> items,
  required List<EnvTransferItem> existing,
  required EnvImportMode mode,
}) {
  final invalidNames = <String>[];
  final seenInvalidName = <String>{};
  final counts = <String, int>{};
  final labels = <String, String>{};

  for (final item in items) {
    if (!isValidEnvName(item.name) && seenInvalidName.add(item.name)) {
      invalidNames.add(item.name.isEmpty ? '(空名称)' : item.name);
    }
    counts[item.identityKey] = (counts[item.identityKey] ?? 0) + 1;
    labels[item.identityKey] = item.identityLabel;
  }

  final collapsed = <String>[];
  final ambiguous = <String>[];

  // 只有 merge 会按 (name, remarks) 认领已有记录。replace 是「清空 + 纯 insert」，
  // 同名多条原样落库，不存在压平，也就没有这两类问题。
  if (mode == EnvImportMode.merge) {
    final existingCounts = <String, int>{};
    for (final item in existing) {
      existingCounts[item.identityKey] =
          (existingCounts[item.identityKey] ?? 0) + 1;
    }
    for (final entry in counts.entries) {
      if (entry.value > 1) {
        collapsed.add(labels[entry.key]!);
      } else if ((existingCounts[entry.key] ?? 0) > 1) {
        ambiguous.add(labels[entry.key]!);
      }
    }
  }

  final payloadBytes = utf8
      .encode(jsonEncode(buildEnvImportRequest(items: items, mode: mode)))
      .length;

  return EnvImportPreflight(
    total: items.length,
    payloadBytes: payloadBytes,
    invalidNames: invalidNames,
    collapsedIdentities: collapsed,
    ambiguousIdentities: ambiguous,
  );
}

/// `POST /envs/import` 的返回。
///
/// 注意它**不走** `response.Success` 那套包装，是 handler 直接 `c.JSON(201, ...)`，
/// 所以既没有 `data` 也没有导入条数的数字字段 —— [message] 只能原样转发面板文案，
/// 不要在 APP 侧另编一句「成功导入 N 条」，那会和面板对不上。
class EnvImportOutcome {
  final String message;
  final List<String> errors;

  const EnvImportOutcome({
    required this.message,
    this.errors = const <String>[],
  });

  factory EnvImportOutcome.fromResponse(dynamic data) {
    var message = '';
    final errors = <String>[];

    if (data is Map) {
      final rawMessage = data['message'];
      if (rawMessage != null) {
        message = rawMessage.toString().trim();
      }
      final rawErrors = data['errors'];
      if (rawErrors is List) {
        for (final item in rawErrors) {
          final text = item?.toString().trim() ?? '';
          if (text.isNotEmpty) {
            errors.add(text);
          }
        }
      }
    }

    return EnvImportOutcome(
      message: message.isEmpty ? '导入完成' : message,
      errors: errors,
    );
  }
}
