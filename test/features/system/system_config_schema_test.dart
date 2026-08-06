import 'dart:convert';

import 'package:daidai_app/features/system/utils/system_config_schema.dart';
import 'package:flutter_test/flutter_test.dart';

/// 系统设置页 schema 驱动的回归保护。
///
/// 这一页是全 App 覆盖面最大的「读取 → 修改 → 回写」表单（面板注册了 47 项配置），
/// 而且它同时要在**新老两种面板**上工作：
/// 面板正在给 SystemConfigDefinition 补 label / group_label / order / secret / min / max，
/// 但用户的面板不一定升级。所以下面的用例分成两组：
/// - `新面板（带 label/order/secret/min/max）`
/// - `老面板（v3.0.0，只有 registered/value/default_value/value_type/group/description/options）`
/// 两组必须都绿。

/// 逐字照抄面板 `buildConfigResponseItem`（server/handler/config.go）的输出形状。
Map<String, dynamic> _item({
  required String value,
  required String valueType,
  required String group,
  String defaultValue = '',
  String description = '',
  bool registered = true,
  List<Map<String, String>>? options,
  Map<String, dynamic> extra = const <String, dynamic>{},
}) {
  return <String, dynamic>{
    'registered': registered,
    'updated_at': null,
    'value': value,
    'default_value': defaultValue,
    'value_type': valueType,
    'group': group,
    'description': description,
    // `key: ?value` 是 null-aware 元素：options 为 null 时整条 entry 不出现，
    // 与面板 `if len(def.Options) > 0 { item["options"] = ... }` 的行为一致。
    'options': ?options,
    ...extra,
  };
}

/// 老面板（v3.0.0）的一份真实切片：键、value_type、group、description 均取自
/// server/model/system_config_registry.go，**不含** label/order/secret/min/max。
Map<String, dynamic> _legacyPanelConfigs() => <String, dynamic>{
  // 故意打乱插入顺序：/api/configs 返回的是 map 不是 list，
  // Go 的 encoding/json 序列化 map 时按键字典序输出，谁都不该依赖它表达注册顺序。
  'captcha_key': _item(
    value: 'SECRET-KEY',
    valueType: 'string',
    group: 'security',
    description: '验证码平台密钥（服务端 Key）',
  ),
  'panel_title': _item(
    value: '呆呆面板',
    valueType: 'string',
    group: 'branding',
    defaultValue: '呆呆面板',
    description: '面板标题',
  ),
  'max_concurrent_tasks': _item(
    value: '5',
    valueType: 'int',
    group: 'tasks',
    defaultValue: '5',
    description: '定时任务最大并发数',
  ),
  'auto_install_deps': _item(
    value: 'true',
    valueType: 'bool',
    group: 'tasks',
    defaultValue: 'true',
    description: '脚本缺依赖时自动尝试安装',
  ),
  'backup_schedule_frequency': _item(
    value: 'daily',
    valueType: 'enum',
    group: 'backup',
    defaultValue: 'daily',
    description: '定时备份频率',
    options: <Map<String, String>>[
      {'value': 'daily', 'label': '每天'},
      {'value': 'weekly', 'label': '每周'},
      {'value': 'monthly', 'label': '每月'},
    ],
  ),
  'timezone': _item(
    value: 'Asia/Shanghai',
    valueType: 'string',
    group: 'branding',
    defaultValue: 'Asia/Shanghai',
    description: '面板时区（影响日志、定时任务日期判断和脚本 TZ）',
  ),
  'auto_update_last_checked_at': _item(
    value: '2026-08-06T03:00:00+08:00',
    valueType: 'string',
    group: 'network',
    description: '上次自动检查更新时间',
  ),
  'panel_service_name': _item(
    value: 'daidai-panel',
    valueType: 'string',
    group: 'branding',
    defaultValue: 'daidai-panel',
    description: 'systemd 服务名称',
  ),
  // 面板运行时自己写的临时状态：不在注册表里，registered=false，没有 schema。
  'auto_update_pending_version': _item(
    value: '3.0.1',
    valueType: '',
    group: '',
    registered: false,
  ),
};

SystemConfigItem _pick(List<SystemConfigItem> items, String key) =>
    items.firstWhere((item) => item.key == key);

void main() {
  group('parseSystemConfigGroups —— 老面板（无 label/order/secret/min/max）', () {
    late List<SystemConfigGroup> groups;
    late List<SystemConfigItem> items;

    setUp(() {
      groups = parseSystemConfigGroups(_legacyPanelConfigs());
      items = flattenSystemConfigItems(groups);
    });

    test('只渲染 registered=true 的项', () {
      expect(
        items.map((item) => item.key),
        isNot(contains('auto_update_pending_version')),
        reason: 'registered=false 是面板运行时状态，没有 schema，渲染出来就有被覆盖的风险',
      );
      expect(items.length, 8);
    });

    test('label 缺失时从 description 切头段，而不是退回 key', () {
      // description 本身就是短说明 → 原样当标题。
      expect(_pick(items, 'max_concurrent_tasks').label, '定时任务最大并发数');
      // 「短说明 +（括号补充）」→ 只取括号前。
      expect(_pick(items, 'timezone').label, '面板时区');
      expect(_pick(items, 'captcha_key').label, '验证码平台密钥');
    });

    test('label 与 description 相同时不重复显示说明', () {
      expect(_pick(items, 'max_concurrent_tasks').hasHint, isFalse);
      expect(
        _pick(items, 'timezone').hasHint,
        isTrue,
        reason: '标题是切出来的头段，完整说明仍要显示在下面',
      );
    });

    test('group_label 缺失时把英文 slug 翻成中文分组名', () {
      expect(
        groups.map((group) => group.label),
        containsAll(<String>['任务运行', '定时备份', '安全', '面板外观']),
      );
      expect(
        groups.map((group) => group.label),
        isNot(contains('branding')),
        reason: '英文 slug 当中文分组标题很难看',
      );
    });

    test('order 缺失时排序仍然稳定：分组按兜底顺序，组内按 key 字典序', () {
      expect(groups.map((group) => group.group).toList(), <String>[
        'tasks',
        'network',
        'security',
        'backup',
        'branding',
      ]);
      final branding = groups.firstWhere((group) => group.group == 'branding');
      expect(branding.items.map((item) => item.key).toList(), <String>[
        'panel_service_name',
        'panel_title',
        'timezone',
      ]);
    });

    test('map 的插入顺序变了，输出顺序不变', () {
      final reversed = Map<String, dynamic>.fromEntries(
        _legacyPanelConfigs().entries.toList().reversed,
      );
      expect(
        flattenSystemConfigItems(
          parseSystemConfigGroups(reversed),
        ).map((item) => item.key).toList(),
        items.map((item) => item.key).toList(),
      );
    });

    test('secret 缺失时只兜底已知的两个密文键，不按键名瞎猜', () {
      expect(_pick(items, 'captcha_key').secret, isTrue);
      expect(
        _pick(items, 'panel_service_name').secret,
        isFalse,
        reason: '键名里没有 key/secret 就不该打码，反之也不该靠键名猜',
      );
      expect(_pick(items, 'timezone').secret, isFalse);
      expect(_pick(items, 'panel_title').secret, isFalse);
    });

    test('min/max 缺失时不做范围校验，也不能崩', () {
      final item = _pick(items, 'max_concurrent_tasks');
      expect(item.min, isNull);
      expect(item.max, isNull);
      // 面板真实上限是 128，但老面板没告诉我们，只能放行让服务端返回 400。
      expect(validateSystemConfigValue(item, '9999'), isNull);
      expect(validateSystemConfigValue(item, '-1'), isNull);
      // 类型错误仍然拦得住 —— 这不需要 min/max。
      expect(validateSystemConfigValue(item, 'abc'), isNotNull);
    });
  });

  group('parseSystemConfigGroups —— 新面板（带 label/group_label/order/secret/min/max）', () {
    late List<SystemConfigItem> items;
    late List<SystemConfigGroup> groups;

    setUp(() {
      groups = parseSystemConfigGroups(<String, dynamic>{
        'captcha_key': _item(
          value: 'SECRET-KEY',
          valueType: 'string',
          group: 'security',
          description: '验证码平台密钥（服务端 Key）',
          extra: const <String, dynamic>{
            'label': '平台密钥',
            'group_label': '安全设置',
            'order': 46,
            'secret': true,
          },
        ),
        'max_concurrent_tasks': _item(
          value: '5',
          valueType: 'int',
          group: 'tasks',
          defaultValue: '5',
          description: '定时任务最大并发数',
          extra: const <String, dynamic>{
            'label': '并发数',
            'group_label': '任务',
            'order': 0,
            'min': 1,
            'max': 128,
          },
        ),
        'log_retention_days': _item(
          value: '7',
          valueType: 'int',
          group: 'tasks',
          defaultValue: '7',
          description: '日志保留天数',
          extra: const <String, dynamic>{
            'label': '日志保留天数',
            'group_label': '任务',
            'order': 1,
            'min': 1,
            'max': 3650,
          },
        ),
      });
      items = flattenSystemConfigItems(groups);
    });

    test('服务端给了 label / group_label 就用服务端的', () {
      expect(_pick(items, 'captcha_key').label, '平台密钥');
      expect(_pick(items, 'max_concurrent_tasks').label, '并发数');
      expect(
        groups.map((group) => group.label).toList(),
        <String>['任务', '安全设置'],
      );
    });

    test('order 决定排序，兜底表不再参与', () {
      expect(items.map((item) => item.key).toList(), <String>[
        'max_concurrent_tasks',
        'log_retention_days',
        'captcha_key',
      ]);
    });

    test('secret 由服务端说了算：服务端说不打码，本地兜底名单不得反悔', () {
      final serverSaysPlain = flattenSystemConfigItems(
        parseSystemConfigGroups(<String, dynamic>{
          'captcha_key': _item(
            value: 'K',
            valueType: 'string',
            group: 'security',
            extra: const <String, dynamic>{'secret': false},
          ),
        }),
      );
      expect(serverSaysPlain.single.secret, isFalse);
    });

    test('min/max 参与前端校验，边界值放行', () {
      final item = _pick(items, 'max_concurrent_tasks');
      expect(validateSystemConfigValue(item, '1'), isNull);
      expect(validateSystemConfigValue(item, '128'), isNull);
      expect(validateSystemConfigValue(item, '0'), contains('1-128'));
      expect(validateSystemConfigValue(item, '129'), contains('1-128'));
      expect(
        validateSystemConfigValue(item, ''),
        isNull,
        reason: '空串在面板等于恢复默认值（int normalize 的 value == "" 分支）',
      );
    });
  });

  group('buildSystemConfigWritePayload —— 未知字段不丢失', () {
    late List<SystemConfigItem> items;

    setUp(() {
      items = flattenSystemConfigItems(
        parseSystemConfigGroups(_legacyPanelConfigs()),
      );
    });

    test('只回写改动过的键，没动的一个都不发', () {
      final draft = <String, String>{
        for (final item in items) item.key: item.value,
      };
      draft['panel_title'] = '我的面板';

      final payload = buildSystemConfigWritePayload(
        items: items,
        draft: draft,
      );

      expect(payload, <String, String>{'panel_title': '我的面板'});
    });

    test('registered=false 的运行时状态永远不进 payload', () {
      // 即便调用方把它塞进 draft（例如将来某个地方按 key 全量填表），
      // items 里没有它 → 不会被回写 → 面板那份状态不会被覆盖。
      final draft = <String, String>{
        for (final item in items) item.key: item.value,
        'auto_update_pending_version': '',
      };

      final payload = buildSystemConfigWritePayload(
        items: items,
        draft: draft,
      );

      expect(payload.containsKey('auto_update_pending_version'), isFalse);
      expect(payload, isEmpty);
    });

    test('面板将来新增、这一版 APP 还不认识的键不会被清空', () {
      // 场景：面板升级后多了一个键，用户在 Web 上配好了，然后用旧 APP 打开设置页。
      // 旧 APP 的 items 里没有这个键 → payload 里没有 → 服务端那份原样保留。
      final draft = <String, String>{
        for (final item in items) item.key: item.value,
      };
      draft['max_concurrent_tasks'] = '8';

      final payload = buildSystemConfigWritePayload(
        items: items,
        draft: draft,
      );

      expect(payload.keys.toList(), <String>['max_concurrent_tasks']);
      expect(payload.containsKey('ai_api_key'), isFalse);
    });

    test('只读键即使被改也不回写', () {
      final draft = <String, String>{
        for (final item in items) item.key: item.value,
        'auto_update_last_checked_at': '1970-01-01T00:00:00Z',
        'panel_service_name': 'wrong-service',
      };

      final payload = buildSystemConfigWritePayload(
        items: items,
        draft: draft,
      );

      expect(payload, isEmpty);
      expect(
        kReadOnlySystemConfigKeys,
        containsAll(<String>[
          'auto_update_last_checked_at',
          'panel_service_manager',
          'panel_service_name',
        ]),
      );
    });

    test('打开设置页 → 一个字不改 → 保存，payload 为空', () {
      final draft = <String, String>{
        for (final item in items) item.key: item.value,
      };
      expect(
        buildSystemConfigWritePayload(items: items, draft: draft),
        isEmpty,
        reason: '全量回写会把 47 项挨个重写，任何一项校验不过就变成「一半保存了一半没保存」',
      );
    });

    test('只有空白差异不算改动', () {
      final draft = <String, String>{
        for (final item in items) item.key: item.value,
      };
      draft['panel_title'] = '  呆呆面板  ';
      expect(
        buildSystemConfigWritePayload(items: items, draft: draft),
        isEmpty,
      );
    });
  });

  // ★ 面板的 BatchSet 绑定的是 `map[string]string`（server/handler/config.go 的
  //   `Configs map[string]string`），请求体里混进一个 JSON bool 会让整份
  //   ShouldBindJSON 失败 → 400「请求参数错误」，一项都存不进去。
  //   这与通知渠道 smtp_ssl 投毒是同一个病，上一个提交刚修完，不能在这里复发。
  group('bool 必须写成字符串，绝不能是 JSON bool', () {
    late List<SystemConfigItem> items;

    setUp(() {
      items = flattenSystemConfigItems(
        parseSystemConfigGroups(_legacyPanelConfigs()),
      );
    });

    test('开关关掉后写的是字符串 "false"', () {
      final draft = <String, String>{
        for (final item in items) item.key: item.value,
      };
      draft['auto_install_deps'] = 'false';

      final payload = buildSystemConfigWritePayload(
        items: items,
        draft: draft,
      );

      expect(payload['auto_install_deps'], isA<String>());
      expect(payload['auto_install_deps'], 'false');
      // 逐字校验落地 JSON，挡住「Dart 侧是 String、编码后仍是 bool」这种漏网写法。
      expect(
        jsonEncode(<String, dynamic>{'configs': payload}),
        contains('"auto_install_deps":"false"'),
      );
    });

    test('任何写法都收敛成 true/false 两个字符串', () {
      final item = _pick(items, 'auto_install_deps');
      expect(item.normalizeForWrite('1'), 'true');
      expect(item.normalizeForWrite('on'), 'true');
      expect(item.normalizeForWrite('YES'), 'true');
      expect(item.normalizeForWrite('0'), 'false');
      expect(item.normalizeForWrite('随便什么'), 'false');
    });

    test('存量脏值（旧客户端写进去的 JSON bool）能读回来显示', () {
      final legacy = flattenSystemConfigItems(
        parseSystemConfigGroups(<String, dynamic>{
          'auto_install_deps': <String, dynamic>{
            'registered': true,
            'value': true,
            'value_type': 'bool',
            'group': 'tasks',
            'default_value': 'true',
            'description': '脚本缺依赖时自动尝试安装',
          },
        }),
      ).single;

      expect(legacy.boolValue, isTrue, reason: '显示成关闭会让用户一存就替自己关掉');
    });
  });

  group('面板加了新东西也不能崩', () {
    test('不认识的 value_type 降级成输入框，不隐藏字段', () {
      final item = flattenSystemConfigItems(
        parseSystemConfigGroups(<String, dynamic>{
          'some_future_key': _item(
            value: '{"a":1}',
            valueType: 'json',
            group: 'tasks',
            description: '面板将来新增的类型',
          ),
        }),
      ).single;

      expect(item.valueType, ConfigValueType.unknown);
      expect(
        item.effectiveType,
        ConfigValueType.unknown,
        reason: '渲染时按输入框处理；隐藏字段等于用户永远改不了它',
      );
      expect(item.normalizeForWrite(' {"a":2} '), '{"a":2}');
    });

    test('enum 的当前值不在 options 里时补进去，不让下拉崩', () {
      final item = flattenSystemConfigItems(
        parseSystemConfigGroups(<String, dynamic>{
          'backup_schedule_frequency': _item(
            // DB 里的历史脏值 / 面板改过枚举。
            value: 'hourly',
            valueType: 'enum',
            group: 'backup',
            options: <Map<String, String>>[
              {'value': 'daily', 'label': '每天'},
            ],
          ),
        }),
      ).single;

      final options = item.renderOptions();
      expect(options.first.value, 'hourly');
      expect(options.map((option) => option.value), contains('daily'));
    });

    test('enum 但没给 options 时退成输入框', () {
      final item = flattenSystemConfigItems(
        parseSystemConfigGroups(<String, dynamic>{
          'weird': _item(value: 'x', valueType: 'enum', group: 'tasks'),
        }),
      ).single;

      expect(item.effectiveType, ConfigValueType.string);
    });

    test('未知 group 原样显示 slug 并排到末尾，不吞掉整组配置', () {
      final groups = parseSystemConfigGroups(<String, dynamic>{
        'brand_new': _item(
          value: 'v',
          valueType: 'string',
          group: 'experimental',
        ),
        'max_concurrent_tasks': _item(
          value: '5',
          valueType: 'int',
          group: 'tasks',
        ),
      });

      expect(groups.map((group) => group.group).toList(), <String>[
        'tasks',
        'experimental',
      ]);
      expect(groups.last.label, 'experimental');
    });

    test('响应形状不对时返回空列表而不是抛异常', () {
      expect(parseSystemConfigGroups(null), isEmpty);
      expect(parseSystemConfigGroups(<dynamic>['x']), isEmpty);
      expect(parseSystemConfigGroups(<String, dynamic>{'a': 'x'}), isEmpty);
    });
  });

  group('deriveConfigLabel', () {
    test('优先用服务端 label', () {
      expect(
        deriveConfigLabel('k', label: '并发数', description: '定时任务最大并发数'),
        '并发数',
      );
    });

    test('按括号 / 冒号 / 分号切头段', () {
      expect(
        deriveConfigLabel('k', description: '验证码上游异常策略：open=放行，strict=严格拦截'),
        '验证码上游异常策略',
      );
      expect(
        deriveConfigLabel('k', description: '面板二进制守护方式；启用后更新流程会尝试先停止守护再启动守护'),
        '面板二进制守护方式',
      );
      expect(
        deriveConfigLabel('k', description: 'CPU 告警阈值（%）'),
        'CPU 告警阈值',
      );
      expect(
        deriveConfigLabel('k', description: '定时备份执行时间（24 小时制 HH:MM）'),
        '定时备份执行时间',
      );
    });

    test('逗号不是断点，不把完整短语切碎', () {
      expect(
        deriveConfigLabel('k', description: '可信代理 CIDR/IP 列表'),
        '可信代理 CIDR/IP 列表',
      );
    });

    test('http:// 里的冒号不是断点', () {
      expect(
        deriveConfigLabel('k', description: '填 http://127.0.0.1:7890 这类地址'),
        '填 http://127.0.0.1',
      );
    });

    test('过长时截断，完整说明仍在下方显示', () {
      final label = deriveConfigLabel(
        'k',
        description: '旧 Docker Socket 更新链路使用的可选镜像源（Watchtower 部署请配置仓库）',
      );
      expect(label.endsWith('…'), isTrue);
      expect(label.length, 21);
    });

    test('description 也没有时才退回 key', () {
      expect(deriveConfigLabel('some_key'), 'some_key');
      expect(deriveConfigLabel('some_key', description: '   '), 'some_key');
    });
  });

  group('resolveConfigGroupLabel', () {
    test('服务端 group_label 优先', () {
      expect(resolveConfigGroupLabel('tasks', groupLabel: '任务'), '任务');
    });

    test('已知 slug 走本地翻译，未知 slug 原样显示', () {
      expect(resolveConfigGroupLabel('subscription'), '订阅');
      expect(resolveConfigGroupLabel('whatever'), 'whatever');
      expect(resolveConfigGroupLabel(''), '其它');
    });
  });
}
