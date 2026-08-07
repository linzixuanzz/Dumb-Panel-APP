import 'dart:convert';

import 'package:daidai_app/features/notifications/utils/channel_config.dart';
import 'package:daidai_app/features/notifications/utils/frozen_channel_fields_v300.dart';
import 'package:daidai_app/features/notifications/utils/notify_field_schema.dart';
import 'package:flutter_test/flutter_test.dart';

// schema 驱动的通知渠道表单的回归保护。
//
// 这一套代码同时要在**新老两种面板**上工作：
// - 新面板：`/notifications/types` 的每一项带 `fields`，APP 收到就画；
// - 老面板（v3.0.0）：只回 `{type, name}`，回落 v3.0.0 冻结快照，
//   行为必须与本次改造前**逐字一致**。
//
// 判断依据是**形状**（`fields` 在不在），不是版本号 —— `handler.Version` 由
// release 流水线用 ldflags 注入，源码默认值就是 "3.0.0"，任何本地 go build
// 或 fork 构建都自称 3.0.0。

/// 逐字照抄面板补上 schema registry 之后 `/notifications/types` 的输出形状
/// （design.md §2.2）。custom 的 5 个键与 notifier.go 的 `sendCustomWebhook`
/// 实际读的 url / method / body / content_type / headers 一一对应。
List<Map<String, dynamic>> _newPanelTypes() => <Map<String, dynamic>>[
  <String, dynamic>{
    'type': 'telegram',
    'name': 'Telegram',
    'fields': <Map<String, dynamic>>[
      <String, dynamic>{
        'key': 'token',
        'label': 'Bot Token',
        'widget': 'password',
        'placeholder': '从 @BotFather 获取',
        'required': true,
      },
      <String, dynamic>{
        'key': 'chat_id',
        'label': 'Chat ID',
        'widget': 'input',
        'required': true,
      },
      // 冻结快照里没有这个键 —— 它正是「面板支持而 APP 填不了」的 31 个键之一。
      <String, dynamic>{
        'key': 'proxy',
        'label': '代理地址 (可选)',
        'widget': 'input',
      },
    ],
  },
  <String, dynamic>{
    'type': 'wecom',
    'name': '企业微信机器人',
    'fields': <Map<String, dynamic>>[
      <String, dynamic>{
        'key': 'webhook',
        'label': 'Webhook URL',
        'widget': 'input',
        'required': true,
      },
      <String, dynamic>{
        'key': 'msg_type',
        'label': '消息类型',
        'widget': 'select',
        'default': 'text',
        'options': <Map<String, String>>[
          <String, String>{'value': 'text', 'label': '文本'},
          <String, String>{'value': 'news', 'label': '图文'},
          <String, String>{'value': 'image', 'label': '图片'},
        ],
      },
      <String, dynamic>{
        'key': 'content_template',
        'label': '文本模板',
        'widget': 'textarea',
        'show_when': <String, dynamic>{
          'key': 'msg_type',
          'values': <String>['text'],
        },
      },
      <String, dynamic>{
        'key': 'news_articles',
        'label': '图文 Articles(JSON)',
        'widget': 'textarea',
        'required': true,
        'show_when': <String, dynamic>{
          'key': 'msg_type',
          'values': <String>['news'],
        },
      },
    ],
  },
  <String, dynamic>{
    'type': 'custom',
    'name': '自定义',
    'fields': <Map<String, dynamic>>[
      <String, dynamic>{
        'key': 'url',
        'label': 'URL',
        'widget': 'input',
        'required': true,
      },
      <String, dynamic>{
        'key': 'method',
        'label': 'Method',
        'widget': 'select',
        'default': 'POST',
        'options': <Map<String, String>>[
          <String, String>{'value': 'POST', 'label': 'POST'},
          <String, String>{'value': 'GET', 'label': 'GET'},
          <String, String>{'value': 'PUT', 'label': 'PUT'},
        ],
      },
      <String, dynamic>{
        'key': 'content_type',
        'label': 'Content-Type',
        'widget': 'input',
      },
      <String, dynamic>{
        'key': 'headers',
        'label': 'Headers (JSON)',
        'widget': 'textarea',
      },
      <String, dynamic>{
        'key': 'body',
        'label': 'Body 模板',
        'widget': 'textarea',
      },
    ],
  },
];

/// 老面板（v3.0.0）：server/handler/notification.go:220-246 只回 type + name。
List<Map<String, dynamic>> _legacyPanelTypes() => <Map<String, dynamic>>[
  <String, dynamic>{'type': 'telegram', 'name': 'Telegram'},
  <String, dynamic>{'type': 'email', 'name': '邮件'},
  <String, dynamic>{'type': 'custom', 'name': '自定义'},
];

List<NotifyFieldSchema> _fieldsOf(String type, List<Map<String, dynamic>> raw) =>
    resolveNotifyChannelFields(
      type: type,
      schemas: parseNotifyChannelSchemas(raw),
    );

List<String> _keysOf(List<NotifyFieldSchema> fields) =>
    fields.map((field) => field.key).toList();

void main() {
  group('形状探测：fields 在就用 schema，不在就回落冻结快照', () {
    test('新面板下发的字段真的会到达用户（含快照里没有的 proxy）', () {
      final fields = _fieldsOf('telegram', _newPanelTypes());

      expect(_keysOf(fields), <String>['token', 'chat_id', 'proxy']);
      expect(fields.first.widget, NotifyFieldWidget.password);
      expect(fields.first.placeholder, '从 @BotFather 获取');
      expect(
        _keysOf(kFrozenChannelFieldsV300['telegram']!).contains('proxy'),
        isFalse,
        reason: 'proxy 只可能来自面板下发，不可能来自快照',
      );
    });

    test('老面板没有 fields → 回落 v3.0.0 冻结快照', () {
      final schemas = parseNotifyChannelSchemas(_legacyPanelTypes());
      expect(schemas.length, 3);
      expect(schemas.first.fields, isEmpty, reason: '老面板压根不下发 fields');

      final fields = resolveNotifyChannelFields(
        type: 'telegram',
        schemas: schemas,
      );
      expect(
        _keysOf(fields),
        <String>['token', 'chat_id', 'api_host'],
        reason: '与本次改造前的 _channelFieldMap 逐字一致',
      );
    });

    test('fields 是空数组等同于没有', () {
      final fields = _fieldsOf('telegram', <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'telegram',
          'name': 'Telegram',
          'fields': <Map<String, dynamic>>[],
        },
      ]);
      expect(_keysOf(fields), <String>['token', 'chat_id', 'api_host']);
    });

    test('老面板的 custom 拿不到任何字段 → 页面转「配置 JSON」编辑框', () {
      expect(_fieldsOf('custom', _legacyPanelTypes()), isEmpty);
    });

    test('新面板给 custom 下发 5 个字段，与 sendCustomWebhook 读的键一一对应', () {
      final fields = _fieldsOf('custom', _newPanelTypes());
      expect(_keysOf(fields), <String>[
        'url',
        'method',
        'content_type',
        'headers',
        'body',
      ]);
    });

    test('面板新加的渠道类型、快照里没有 → 空字段表而不是崩', () {
      expect(_fieldsOf('some_new_channel', _legacyPanelTypes()), isEmpty);
    });

    test('类型表整个取不到时才用冻结类型表', () {
      expect(
        resolveNotifyChannelTypes(const <NotifyChannelSchema>[]).length,
        22,
      );
      final fromPanel = parseNotifyChannelSchemas(_newPanelTypes());
      expect(resolveNotifyChannelTypes(fromPanel), same(fromPanel));
    });
  });

  // 这一组就是「禁止再往冻结快照里加东西」的执行手段：
  // 加一个渠道或一个字段，下面的数字立刻对不上，测试直接红。
  // 新渠道 / 新字段一律靠面板下发，不靠改这个文件。
  group('v3.0.0 冻结快照不许再长', () {
    test('21 个渠道 / 45 个字段槽 / 22 条类型', () {
      expect(kFrozenChannelFieldsV300.length, 21);
      final slots = kFrozenChannelFieldsV300.values.fold<int>(
        0,
        (sum, fields) => sum + fields.length,
      );
      expect(
        slots,
        45,
        reason: '= 改造前 _channelFieldMap 的 44 槽 + email 那个单独写死的 SSL 下拉',
      );
      expect(kFrozenChannelTypesV300.length, 22);
    });

    test('快照里的渠道都在类型表里，且没有空 key', () {
      final declared = kFrozenChannelTypesV300
          .map((schema) => schema.type)
          .toSet();
      for (final entry in kFrozenChannelFieldsV300.entries) {
        expect(declared, contains(entry.key));
        for (final field in entry.value) {
          expect(field.key, isNotEmpty);
          expect(field.label, isNotEmpty);
        }
      }
    });

    test('快照里没有 required / show_when —— v3.0.0 的 APP 两者都不支持', () {
      for (final fields in kFrozenChannelFieldsV300.values) {
        for (final field in fields) {
          expect(field.isRequired, isFalse);
          expect(field.showWhen, isNull);
        }
      }
    });
  });

  group('widget 解析与降级', () {
    test('四种 widget 逐个认', () {
      expect(parseNotifyFieldWidget('input'), NotifyFieldWidget.input);
      expect(parseNotifyFieldWidget('password'), NotifyFieldWidget.password);
      expect(parseNotifyFieldWidget('textarea'), NotifyFieldWidget.textarea);
      expect(parseNotifyFieldWidget('select'), NotifyFieldWidget.select);
      expect(parseNotifyFieldWidget(null), NotifyFieldWidget.unknown);
      expect(parseNotifyFieldWidget('color-picker'), NotifyFieldWidget.unknown);
    });

    test('不认识的 widget 降级成输入框，绝不隐藏字段', () {
      final fields = _fieldsOf('x', <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'x',
          'name': 'X',
          'fields': <Map<String, dynamic>>[
            <String, dynamic>{
              'key': 'a',
              'label': 'A',
              'widget': 'color-picker',
            },
          ],
        },
      ]);
      expect(fields.single.widget, NotifyFieldWidget.unknown);
      expect(fields.single.effectiveWidget, NotifyFieldWidget.input);
      expect(
        visibleNotifyFields(fields: fields, values: const <String, String>{}),
        hasLength(1),
        reason: '不认识 ≠ 隐藏，隐藏等于用户永远填不了它',
      );
    });

    test('声明成 select 却没给 options → 退成输入框，不给空下拉', () {
      const field = NotifyFieldSchema(
        key: 'a',
        label: 'A',
        widget: NotifyFieldWidget.select,
      );
      expect(field.effectiveWidget, NotifyFieldWidget.input);
    });

    test('label 缺失时用 key 兜底，不给空标题输入框', () {
      final fields = _fieldsOf('x', <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'x',
          'name': 'X',
          'fields': <Map<String, dynamic>>[
            <String, dynamic>{'key': 'proxy', 'widget': 'input'},
          ],
        },
      ]);
      expect(fields.single.label, 'proxy');
    });

    test('当前值不在 options 里时必须补进去，否则用户再也选不回来', () {
      const field = NotifyFieldSchema(
        key: 'msg_type',
        label: '消息类型',
        widget: NotifyFieldWidget.select,
        options: <NotifyFieldOption>[
          NotifyFieldOption(value: 'text', label: '文本'),
        ],
      );
      expect(field.renderOptions('text'), hasLength(1));

      final injected = field.renderOptions('mpnews');
      expect(injected.first.value, 'mpnews');
      expect(injected.first.label, contains('面板未声明'));
      expect(field.renderOptions('').first.label, '未设置');
    });
  });

  group('show_when（单键等值命中）', () {
    test('切 msg_type 时条件字段跟着显隐', () {
      final fields = _fieldsOf('wecom', _newPanelTypes());

      expect(
        _keysOf(
          visibleNotifyFields(
            fields: fields,
            values: const <String, String>{'msg_type': 'text'},
          ),
        ),
        <String>['webhook', 'msg_type', 'content_template'],
      );
      expect(
        _keysOf(
          visibleNotifyFields(
            fields: fields,
            values: const <String, String>{'msg_type': 'news'},
          ),
        ),
        <String>['webhook', 'msg_type', 'news_articles'],
      );
      expect(
        _keysOf(
          visibleNotifyFields(
            fields: fields,
            values: const <String, String>{'msg_type': 'image'},
          ),
        ),
        <String>['webhook', 'msg_type'],
      );
    });

    test('条件引用了字段表里没有的键 → 无条件显示', () {
      final fields = _fieldsOf('x', <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'x',
          'name': 'X',
          'fields': <Map<String, dynamic>>[
            <String, dynamic>{
              'key': 'a',
              'label': 'A',
              'widget': 'input',
              'show_when': <String, dynamic>{
                'key': 'nope',
                'values': <String>['1'],
              },
            },
          ],
        },
      ]);
      expect(
        visibleNotifyFields(fields: fields, values: const <String, String>{}),
        hasLength(1),
        reason: '读不懂的条件不能把输入入口整个吞掉',
      );
    });

    test('show_when 写坏了也按无条件显示', () {
      expect(NotifyFieldCondition.tryParse(null), isNull);
      expect(NotifyFieldCondition.tryParse('news'), isNull);
      expect(
        NotifyFieldCondition.tryParse(<String, dynamic>{
          'key': '',
          'values': <String>['1'],
        }),
        isNull,
      );
      expect(
        NotifyFieldCondition.tryParse(<String, dynamic>{
          'key': 'msg_type',
          'values': <String>[],
        }),
        isNull,
      );
    });
  });

  group('required 前端拦截', () {
    test('必填空着时给出可读的中文原因', () {
      final fields = _fieldsOf('telegram', _newPanelTypes());
      expect(
        validateNotifyFields(
          visibleFields: fields,
          values: const <String, String>{
            'token': '  ',
            'chat_id': '-100123',
            'proxy': '',
          },
        ),
        '「Bot Token」不能为空',
      );
      expect(
        validateNotifyFields(
          visibleFields: fields,
          values: const <String, String>{
            'token': '123:ABC',
            'chat_id': '-100123',
            'proxy': '',
          },
        ),
        isNull,
      );
    });

    test('此刻隐藏着的必填字段不拦 —— 用户根本没地方填它', () {
      final fields = _fieldsOf('wecom', _newPanelTypes());
      const values = <String, String>{
        'webhook': 'https://qyapi.weixin.qq.com/x',
        'msg_type': 'text',
        'content_template': '',
        // news_articles 是必填，但 msg_type=text 时它不显示。
        'news_articles': '',
      };
      final visible = visibleNotifyFields(fields: fields, values: values);
      expect(_keysOf(visible), isNot(contains('news_articles')));
      expect(
        validateNotifyFields(visibleFields: visible, values: values),
        isNull,
      );
    });

    test('default 顶上了就算填了', () {
      final fields = _fieldsOf('custom', _newPanelTypes());
      final seeds = buildNotifyFieldSeeds(
        fields: fields,
        existingConfig: const <String, dynamic>{},
        keepExistingConfig: false,
      );
      expect(seeds['method'], 'POST');

      final draft = <String, String>{
        ...seeds,
        'url': 'https://example.com/api/notify',
      };
      expect(
        validateNotifyFields(visibleFields: fields, values: draft),
        isNull,
      );
    });
  });

  // ★★ 这一组是本次改造最容易再犯一次的错。
  //    面板 sendToChannel 把整份 config 反序列化成 map[string]string
  //    （server/service/notifier.go:166-168），里面出现**一个** bool，
  //    整份 Unmarshal 就报 `json: cannot unmarshal bool into Go value of type string`
  //    并直接返回错误 —— 该渠道的所有通知（含「测试」按钮）从此全挂，
  //    而且 Web 端是整份 JSON.parse 读入、整份写回，会原样保留那个 bool，Web 也修不回来。
  group('config 的值必须全是字符串', () {
    test('select / textarea / input 走完整条链路后逐字都是 JSON 字符串', () {
      final fields = _fieldsOf('wecom', _newPanelTypes());
      final seeds = buildNotifyFieldSeeds(
        fields: fields,
        existingConfig: const <String, dynamic>{},
        keepExistingConfig: false,
      );
      final draft = <String, String>{
        ...seeds,
        'webhook': 'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=x',
        'msg_type': 'news',
        'news_articles': '[{"title":"标题"}]',
      };
      final visible = visibleNotifyFields(fields: fields, values: draft);
      expect(
        validateNotifyFields(visibleFields: visible, values: draft),
        isNull,
      );

      final config = buildChannelConfigFromFields(
        existingConfig: const <String, dynamic>{},
        keepExistingConfig: false,
        fieldValues: buildNotifyFieldValues(
          visibleFields: visible,
          existingConfig: const <String, dynamic>{},
          keepExistingConfig: false,
          draft: draft,
        ),
      );

      for (final entry in config.entries) {
        expect(
          entry.value,
          isA<String>(),
          reason: '${entry.key} 不是字符串会让面板整份 config 解析失败',
        );
      }
      final encoded = jsonEncode(config);
      expect(encoded, contains('"msg_type":"news"'));
      expect(encoded, contains(r'"news_articles":"[{\"title\":\"标题\"}]"'));
      expect(encoded, isNot(contains(':true')));
      expect(encoded, isNot(contains(':false')));
    });

    test('存量 bool（旧客户端投毒）在保存时被修成字符串', () {
      const fields = <NotifyFieldSchema>[
        NotifyFieldSchema(
          key: 'enable_id_trans',
          label: 'ID 转译',
          widget: NotifyFieldWidget.select,
          defaultValue: '0',
          options: <NotifyFieldOption>[
            NotifyFieldOption(value: '0', label: '关闭 (0)'),
            NotifyFieldOption(value: '1', label: '开启 (1)'),
          ],
        ),
      ];
      const existing = <String, dynamic>{'enable_id_trans': true};

      final seeds = buildNotifyFieldSeeds(
        fields: fields,
        existingConfig: existing,
        keepExistingConfig: true,
      );
      expect(seeds['enable_id_trans'], 'true');

      final config = buildChannelConfigFromFields(
        existingConfig: existing,
        keepExistingConfig: true,
        fieldValues: buildNotifyFieldValues(
          visibleFields: fields,
          existingConfig: existing,
          keepExistingConfig: true,
          draft: seeds,
        ),
      );
      expect(config['enable_id_trans'], isA<String>());
      expect(jsonEncode(config), '{"enable_id_trans":"true"}');
    });

    test('存量对象按 JSON 回显，不是 Dart 的 Map.toString()', () {
      const fields = <NotifyFieldSchema>[
        NotifyFieldSchema(
          key: 'headers',
          label: 'Headers (JSON)',
          widget: NotifyFieldWidget.textarea,
        ),
      ];
      const existing = <String, dynamic>{
        'headers': <String, dynamic>{'X-Token': 'abc'},
      };

      final seeds = buildNotifyFieldSeeds(
        fields: fields,
        existingConfig: existing,
        keepExistingConfig: true,
      );
      // Dart 的 `{X-Token: abc}` 不是 JSON，用户点一下保存就把配置改成废字符串了。
      expect(seeds['headers'], '{"X-Token":"abc"}');
      expect(jsonDecode(seeds['headers']!), existing['headers']);

      final config = buildChannelConfigFromFields(
        existingConfig: existing,
        keepExistingConfig: true,
        fieldValues: buildNotifyFieldValues(
          visibleFields: fields,
          existingConfig: existing,
          keepExistingConfig: true,
          draft: seeds,
        ),
      );
      expect(config['headers'], isA<String>());
    });
  });

  group('未知字段不丢失', () {
    test('schema 没声明的键、以及条件隐藏着的键，保存后都还在', () {
      final fields = _fieldsOf('wecom', _newPanelTypes());
      const existing = <String, dynamic>{
        'webhook': 'https://old',
        'msg_type': 'text',
        // msg_type=text 时这个字段不显示，但值不能因此被删。
        'news_articles': '[{"title":"存量"}]',
        // 面板支持、当前 schema 没声明的键。
        'mentioned_list': '@all',
      };

      final seeds = buildNotifyFieldSeeds(
        fields: fields,
        existingConfig: existing,
        keepExistingConfig: true,
      );
      final visible = visibleNotifyFields(fields: fields, values: seeds);
      expect(_keysOf(visible), <String>[
        'webhook',
        'msg_type',
        'content_template',
      ]);

      final config = buildChannelConfigFromFields(
        existingConfig: existing,
        keepExistingConfig: true,
        fieldValues: buildNotifyFieldValues(
          visibleFields: visible,
          existingConfig: existing,
          keepExistingConfig: true,
          draft: seeds,
        ),
      );

      expect(config['mentioned_list'], '@all');
      expect(config['news_articles'], '[{"title":"存量"}]');
      expect(
        config,
        existing,
        reason: '打开 → 一个字不改 → 保存，必须是一次空操作',
      );
    });

    test('用户显式清空的字段才删，且只删它自己', () {
      final fields = _fieldsOf('telegram', _newPanelTypes());
      const existing = <String, dynamic>{
        'token': '123:ABC',
        'chat_id': '-100123',
        'proxy': 'socks5://127.0.0.1:1080',
        'parse_mode': 'MarkdownV2',
      };

      final draft = <String, String>{
        ...buildNotifyFieldSeeds(
          fields: fields,
          existingConfig: existing,
          keepExistingConfig: true,
        ),
        'proxy': '',
      };
      final config = buildChannelConfigFromFields(
        existingConfig: existing,
        keepExistingConfig: true,
        fieldValues: buildNotifyFieldValues(
          visibleFields: fields,
          existingConfig: existing,
          keepExistingConfig: true,
          draft: draft,
        ),
      );

      expect(config.containsKey('proxy'), isFalse);
      expect(config['parse_mode'], 'MarkdownV2', reason: '别的未知键不受影响');
      expect(config['token'], '123:ABC');
    });

    test('没动过的 default 不凭空写进 config', () {
      final fields = _fieldsOf('custom', _newPanelTypes());
      final seeds = buildNotifyFieldSeeds(
        fields: fields,
        existingConfig: const <String, dynamic>{},
        keepExistingConfig: false,
      );
      final values = buildNotifyFieldValues(
        visibleFields: fields,
        existingConfig: const <String, dynamic>{},
        keepExistingConfig: false,
        draft: <String, String>{...seeds, 'url': 'https://example.com/notify'},
      );

      expect(values, <String, String>{'url': 'https://example.com/notify'});
      expect(
        values.containsKey('method'),
        isFalse,
        reason: '面板读不到 method 时本来就用 POST，写进去只会把旧默认值冻住',
      );
    });

    test('换了渠道类型，旧类型的配置整份作废', () {
      final fields = _fieldsOf('telegram', _newPanelTypes());
      const existing = <String, dynamic>{
        'key': 'device-key',
        'sound': 'birdsong',
      };
      final config = buildChannelConfigFromFields(
        existingConfig: existing,
        keepExistingConfig: false,
        fieldValues: buildNotifyFieldValues(
          visibleFields: fields,
          existingConfig: existing,
          keepExistingConfig: false,
          draft: const <String, String>{
            'token': '123:ABC',
            'chat_id': '-100',
            'proxy': '',
          },
        ),
      );
      expect(config, <String, dynamic>{'token': '123:ABC', 'chat_id': '-100'});
    });
  });

  // smtp_ssl 的三态（auto / true / false）与面板把它声明成一个普通 select
  // **不冲突** —— 面板 Web 端 index.vue:106-110 声明的正是这三个字符串取值，
  // 通用渲染器直接就画得出来，APP 侧不需要任何 email 专属控件。
  //
  // schema 唯一表达不出来的是：面板判定 SSL 时依次看 5 个键
  // （notifier.go:358 的 smtp_ssl / smtp_use_ssl / use_ssl / enable_ssl / ssl），
  // 而 schema 只声明得出主键。这处不对称留在 APP 的**读取侧**补偿，
  // 写入侧一律原样透传，不替面板做归一。
  group('smtp_ssl：三态 select 与 schema 不冲突', () {
    test('冻结快照里它就是一个三态 select，不是开关', () {
      final fields = _fieldsOf('email', _legacyPanelTypes());
      final ssl = fields.last;

      expect(ssl.key, kSmtpSslConfigKey);
      expect(ssl.effectiveWidget, NotifyFieldWidget.select);
      expect(ssl.defaultValue, smtpSslModeAuto);
      expect(ssl.options.map((option) => option.value).toList(), <String>[
        smtpSslModeAuto,
        smtpSslModeOn,
        smtpSslModeOff,
      ]);
    });

    test('只有别名 use_ssl 时，表单显示的是面板实际会做的事', () {
      final fields = _fieldsOf('email', _legacyPanelTypes());
      const existing = <String, dynamic>{
        'smtp_host': 'smtp.qq.com',
        'smtp_port': '587',
        'use_ssl': 'true',
      };

      final seeds = buildNotifyFieldSeeds(
        fields: fields,
        existingConfig: existing,
        keepExistingConfig: true,
      );
      expect(
        seeds[kSmtpSslConfigKey],
        smtpSslModeOn,
        reason: '直接读主键会拿到「未设置」，而面板实际是启用的',
      );

      final config = buildChannelConfigFromFields(
        existingConfig: existing,
        keepExistingConfig: true,
        fieldValues: buildNotifyFieldValues(
          visibleFields: fields,
          existingConfig: existing,
          keepExistingConfig: true,
          draft: seeds,
        ),
      );
      // 写回主键（面板取键顺序里它排第一，Web 端也只认它），别名原样留着。
      expect(config[kSmtpSslConfigKey], smtpSslModeOn);
      expect(config['use_ssl'], 'true');
    });

    test('新建渠道保持「自动」→ 不凭空写 smtp_ssl', () {
      final fields = _fieldsOf('email', _legacyPanelTypes());
      final seeds = buildNotifyFieldSeeds(
        fields: fields,
        existingConfig: const <String, dynamic>{},
        keepExistingConfig: false,
      );
      expect(seeds[kSmtpSslConfigKey], smtpSslModeAuto);

      final values = buildNotifyFieldValues(
        visibleFields: fields,
        existingConfig: const <String, dynamic>{},
        keepExistingConfig: false,
        draft: <String, String>{
          ...seeds,
          'smtp_host': 'smtp.qq.com',
          'smtp_port': '465',
          'smtp_user': 'a@b.c',
          'smtp_pass': 'pass',
          'to': 'x@y.z',
        },
      );
      expect(
        values.containsKey(kSmtpSslConfigKey),
        isFalse,
        reason: '键不存在时面板按端口是否 465 自动判断，与「自动」等价',
      );
    });

    test('用户改成「关闭」会真的写进去，且是字符串', () {
      final fields = _fieldsOf('email', _legacyPanelTypes());
      final seeds = buildNotifyFieldSeeds(
        fields: fields,
        existingConfig: const <String, dynamic>{},
        keepExistingConfig: false,
      );
      final config = buildChannelConfigFromFields(
        existingConfig: const <String, dynamic>{},
        keepExistingConfig: false,
        fieldValues: buildNotifyFieldValues(
          visibleFields: fields,
          existingConfig: const <String, dynamic>{},
          keepExistingConfig: false,
          draft: <String, String>{
            ...seeds,
            'smtp_host': 'smtp.qq.com',
            kSmtpSslConfigKey: smtpSslModeOff,
          },
        ),
      );
      expect(jsonEncode(config), contains('"smtp_ssl":"false"'));
    });

    test('存量 auto 打开又保存，不被改写', () {
      final fields = _fieldsOf('email', _legacyPanelTypes());
      const existing = <String, dynamic>{
        'smtp_host': 'smtp.qq.com',
        'smtp_port': '465',
        'smtp_ssl': 'auto',
      };
      final seeds = buildNotifyFieldSeeds(
        fields: fields,
        existingConfig: existing,
        keepExistingConfig: true,
      );
      final config = buildChannelConfigFromFields(
        existingConfig: existing,
        keepExistingConfig: true,
        fieldValues: buildNotifyFieldValues(
          visibleFields: fields,
          existingConfig: existing,
          keepExistingConfig: true,
          draft: seeds,
        ),
      );
      expect(config, existing);
    });

    test('新面板把 smtp_ssl 声明成 select 时，走的是同一条通用链路', () {
      final fields = _fieldsOf('email', <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'email',
          'name': '邮件',
          'fields': <Map<String, dynamic>>[
            <String, dynamic>{
              'key': 'smtp_host',
              'label': 'SMTP 主机',
              'widget': 'input',
            },
            <String, dynamic>{
              'key': kSmtpSslConfigKey,
              'label': 'SSL 连接',
              'widget': 'select',
              'default': smtpSslModeAuto,
              'options': <Map<String, String>>[
                <String, String>{'value': smtpSslModeAuto, 'label': '自动 (465 启用)'},
                <String, String>{'value': smtpSslModeOn, 'label': '启用 SSL'},
                <String, String>{'value': smtpSslModeOff, 'label': '关闭 SSL'},
              ],
            },
          ],
        },
      ]);

      // 别名兜底在面板下发 schema 之后照样生效 —— 它补的是面板读取侧的不对称，
      // 与 schema 声明成什么无关。
      final seeds = buildNotifyFieldSeeds(
        fields: fields,
        existingConfig: const <String, dynamic>{'enable_ssl': '1'},
        keepExistingConfig: true,
      );
      expect(seeds[kSmtpSslConfigKey], smtpSslModeOn);
    });
  });
}
