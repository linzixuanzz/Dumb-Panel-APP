import 'dart:convert';

import 'package:daidai_app/features/envs/utils/env_transfer.dart';
import 'package:flutter_test/flutter_test.dart';

/// 环境变量「导出 → 离线编辑 → 导入」的回归保护。
///
/// 这是一条彻头彻尾的「读取 → 修改 → 回写」链路，spec 对它有硬性要求：
/// **必须有测试证明未知字段不丢失**。这里把要求具体化成三条不许破的线：
///
/// 1. 往返一圈，**同名多条不能被压成一条** —— 这个仓库的多账号就是靠同名多条实现的
///    （运行时由 `joinTaskEnvValues` 用 `&` / `&&` 合并后暴露给脚本）。
/// 2. 往返一圈，**remarks / 分组 / 启用状态**一个都不能少 —— 少了在手机上看不出来。
/// 3. 往返一圈，**面板将来新增、这一版 APP 不认识的键**要原样带回去。
///
/// 另外还钉了两处「APP 与面板的字段约定」：`groups` 空数组也得发（否则清分组会失效）、
/// `enabled` 必须是 JSON 布尔（与通知渠道 config「全是字符串」正好相反）。
void main() {
  EnvTransferItem itemOf(String json) =>
      EnvTransferItem.fromJson(jsonDecode(json) as Map<String, dynamic>);

  group('往返无损', () {
    test('同名 3 条（不同备注）往返后仍是 3 条，逐字段不变', () {
      const items = <EnvTransferItem>[
        EnvTransferItem(
          name: 'JD_COOKIE',
          value: 'pt_key=one; pt_pin=a;',
          remarks: '账号1',
          groups: ['京东'],
        ),
        EnvTransferItem(
          name: 'JD_COOKIE',
          value: 'pt_key=two; pt_pin=b;',
          remarks: '账号2',
          groups: ['京东', '主力'],
        ),
        EnvTransferItem(
          name: 'JD_COOKIE',
          value: 'pt_key=three; pt_pin=c;',
          remarks: '账号3',
          enabled: false,
        ),
      ];

      final restored = parseEnvTransferJson(encodeEnvTransferJson(items));

      expect(restored.ok, isTrue);
      expect(restored.items.length, 3, reason: '同名多条被压平 = 多账号没了');
      expect(
        restored.items.map((item) => item.remarks).toList(),
        ['账号1', '账号2', '账号3'],
      );
      expect(restored.items[1].groups, ['京东', '主力']);
      expect(restored.items[2].enabled, isFalse, reason: '禁用状态必须保留');
      expect(restored.items[0].value, 'pt_key=one; pt_pin=a;');
    });

    test('连备注都一样的同名 3 条，编解码这一层也不压平', () {
      // 面板的 merge 会把它们压成一条 —— 那是 analyzeEnvImport 要拦的事，
      // 但序列化本身绝不能先替它压一次，否则连「换成替换模式」这条出路都没了。
      const items = <EnvTransferItem>[
        EnvTransferItem(name: 'CK', value: 'a'),
        EnvTransferItem(name: 'CK', value: 'b'),
        EnvTransferItem(name: 'CK', value: 'c'),
      ];

      final restored = parseEnvTransferJson(encodeEnvTransferJson(items));

      expect(restored.items.length, 3);
      expect(restored.items.map((item) => item.value).toList(), [
        'a',
        'b',
        'c',
      ]);
    });

    test('面板新增、这一版 APP 不认识的键不会被吃掉', () {
      // 面板 handler 是逐字段手写拼装的，将来给 export-all 加键很正常
      // （sort_order / position 现在就没在 APP 的字段表里）。
      final item = itemOf('''
{
  "name": "TOKEN",
  "value": "abc",
  "remarks": "",
  "group": "",
  "groups": [],
  "enabled": true,
  "sort_order": 1,
  "position": 2000.5,
  "brand_new_panel_field": {"nested": [1, 2]}
}
''');

      final payload = item.toJson();

      expect(payload['sort_order'], 1);
      expect(payload['position'], 2000.5);
      expect(payload['brand_new_panel_field'], {
        'nested': [1, 2],
      });
    });

    test('「读取 → 改一个值 → 回写」不丢未知字段，也不丢没改的那条', () {
      // 模拟真实链路：面板 export-all 的响应 → 用户在文本里改一个 value → 导入请求体。
      const exported = '''
[
  {"name":"JD_COOKIE","value":"old-one","remarks":"账号1","group":"京东","groups":["京东"],"enabled":true,"sort_order":1},
  {"name":"JD_COOKIE","value":"old-two","remarks":"账号2","group":"京东","groups":["京东"],"enabled":false,"position":3000.0}
]
''';

      final edited = exported.replaceAll('old-one', 'new-one');
      final parsed = parseEnvTransferJson(edited);
      expect(parsed.ok, isTrue);

      final request = buildEnvImportRequest(
        items: parsed.items,
        mode: EnvImportMode.merge,
      );
      final envs = request['envs'] as List<dynamic>;

      expect(envs.length, 2);
      final first = envs[0] as Map<String, dynamic>;
      final second = envs[1] as Map<String, dynamic>;

      expect(first['value'], 'new-one', reason: '改动要生效');
      expect(first['sort_order'], 1, reason: 'APP 不认识的键必须原样回写');
      expect(second['value'], 'old-two', reason: '没改的那条不能被顺手清掉');
      expect(second['remarks'], '账号2');
      expect(second['enabled'], isFalse);
      expect(second['position'], 3000.0);
    });

    test('再编码一次逐字节相同（往返幂等，含未知字段）', () {
      const exported = '''
[{"name":"A","value":"1","remarks":"r","group":"g1,g2","groups":["g1","g2"],"enabled":false,"sort_order":1}]
''';

      final once = encodeEnvTransferJson(parseEnvTransferJson(exported).items);
      final twice = encodeEnvTransferJson(parseEnvTransferJson(once).items);

      expect(twice, once);
    });
  });

  group('与面板 import 的字段约定', () {
    test('groups 即使为空也发出去 —— 不发的话 merge 会保留旧分组', () {
      // 面板 envGroupValueFromImportItem 是按「键在不在」决定要不要写 group 的。
      // 两个键都不发时 merge 保留旧值，于是「在面板上清掉分组 → 导出 → 导回」
      // 会把分组又装回来。
      const item = EnvTransferItem(name: 'A', value: 'v');
      final encoded = jsonEncode(item.toJson());

      expect(encoded, contains('"groups":[]'));
      expect(encoded, contains('"group":""'));
    });

    test('enabled 是 JSON 布尔，不是字符串', () {
      // ⚠️ 与通知渠道 config「值必须全是字符串」正好相反。面板这里读的是
      // item["enabled"].(bool)，给字符串会类型断言失败并静默退回 true，
      // 于是禁用状态无声丢失。
      const item = EnvTransferItem(name: 'A', enabled: false);
      final encoded = jsonEncode(item.toJson());

      expect(encoded, contains('"enabled":false'));
      expect(encoded, isNot(contains('"enabled":"false"')));
    });

    test('青龙的 status 优先于 enabled，且不会在 extras 里留一份', () {
      // 面板 Import 的取值顺序就是 status > enabled > 默认 true。
      // status 留在 extras 里的话，用户手改 enabled 会静默不生效。
      final disabled = itemOf('{"name":"A","status":1,"enabled":true}');
      final enabled = itemOf('{"name":"A","status":0,"enabled":false}');

      expect(disabled.enabled, isFalse);
      expect(enabled.enabled, isTrue);
      expect(disabled.toJson().containsKey('status'), isFalse);
      expect(jsonEncode(enabled.toJson()), contains('"enabled":true'));
    });

    test('两个字段都没有时默认启用', () {
      expect(itemOf('{"name":"A"}').enabled, isTrue);
    });

    test('请求体形状是 {"envs": [...], "mode": "..."}', () {
      final request = buildEnvImportRequest(
        items: const [EnvTransferItem(name: 'A')],
        mode: EnvImportMode.replace,
      );

      expect(request.keys.toSet(), {'envs', 'mode'});
      expect(request['mode'], 'replace');
      expect((request['envs'] as List<dynamic>).length, 1);
      expect(EnvImportMode.merge.wireValue, 'merge');
    });
  });

  group('分组解析', () {
    test('groups 数组优先于 group 字符串', () {
      final item = itemOf('{"name":"A","group":"旧的","groups":["新的","另一个"]}');
      expect(item.groups, ['新的', '另一个']);
      expect(item.group, '新的,另一个');
    });

    test('没有 groups 时退回 group 字符串', () {
      expect(itemOf('{"name":"A","group":"a,b"}').groups, ['a', 'b']);
    });

    test('认中文逗号和分号，并去重去空白', () {
      // 用户手改 JSON 时中文标点很常见，切不开就会出现一个叫「生产；通知」的分组。
      expect(splitEnvGroups('生产，通知；生产, 备用 '), ['生产', '通知', '备用']);
      expect(joinEnvGroups(['a,b', 'b', ' c ']), 'a,b,c');
    });

    test('groups 是字符串时也认（面板同样收这种形态）', () {
      expect(itemOf('{"name":"A","groups":"x;y"}').groups, ['x', 'y']);
    });
  });

  group('parseEnvTransferJson', () {
    test('接受顶层数组，也接受 {"envs": [...]}', () {
      expect(parseEnvTransferJson('[{"name":"A"}]').items.length, 1);
      expect(
        parseEnvTransferJson('{"envs":[{"name":"A"}],"mode":"merge"}')
            .items
            .length,
        1,
      );
    });

    test('非法 JSON 返回 error，绝不静默变成 0 条', () {
      final result = parseEnvTransferJson('[{"name": ');
      expect(result.ok, isFalse);
      expect(result.error, isNotNull);
      expect(result.items, isEmpty);
    });

    test('顶层既不是数组也没有 envs → error', () {
      expect(parseEnvTransferJson('{"name":"A"}').ok, isFalse);
      expect(parseEnvTransferJson('"just a string"').ok, isFalse);
    });

    test('空内容 → error', () {
      expect(parseEnvTransferJson('   ').ok, isFalse);
    });

    test('数组里的非对象元素被跳过并计数', () {
      final result = parseEnvTransferJson('[{"name":"A"}, 1, "x", null]');
      expect(result.ok, isTrue);
      expect(result.items.length, 1);
      expect(result.skipped, 3);
    });
  });

  group('analyzeEnvImport', () {
    EnvImportPreflight analyze(
      List<EnvTransferItem> items, {
      List<EnvTransferItem> existing = const [],
      EnvImportMode mode = EnvImportMode.merge,
    }) => analyzeEnvImport(items: items, existing: existing, mode: mode);

    test('合并模式下「同名 + 同备注」重复会被拦住', () {
      // 面板 merge 是「按 (name, remarks) 找到第一条就更新」：3 条会写进同一行，
      // 最终只剩一条，值是最后一条的。无声的数据损坏，必须拦。
      final result = analyze(const [
        EnvTransferItem(name: 'CK', value: 'a'),
        EnvTransferItem(name: 'CK', value: 'b'),
        EnvTransferItem(name: 'CK', value: 'c'),
      ]);

      expect(result.collapsedIdentities, ['CK']);
      expect(result.blocked, isTrue);
    });

    test('同名但备注不同 —— 多账号的正常形态，不拦', () {
      final result = analyze(const [
        EnvTransferItem(name: 'CK', value: 'a', remarks: '账号1'),
        EnvTransferItem(name: 'CK', value: 'b', remarks: '账号2'),
      ]);

      expect(result.collapsedIdentities, isEmpty);
      expect(result.blocked, isFalse);
    });

    test('替换模式是「清空 + 纯 insert」，同名重复无损，不拦', () {
      final result = analyze(
        const [
          EnvTransferItem(name: 'CK', value: 'a'),
          EnvTransferItem(name: 'CK', value: 'b'),
        ],
        mode: EnvImportMode.replace,
      );

      expect(result.collapsedIdentities, isEmpty);
      expect(result.ambiguousIdentities, isEmpty);
      expect(result.blocked, isFalse);
    });

    test('面板上已有多条同名同备注 → 只警告不拦', () {
      // 这是面板 PUT /envs/by-name 会直接 409 拒绝的同一类情况；
      // import 没有那道守卫，所以 APP 自己先看一眼。但它不丢数据（用户本来就要写这个值），
      // 只是「更新了哪一条」不确定，所以是警告不是拦。
      final result = analyze(
        const [EnvTransferItem(name: 'CK', value: 'new')],
        existing: const [
          EnvTransferItem(name: 'CK', value: 'old-1'),
          EnvTransferItem(name: 'CK', value: 'old-2'),
        ],
      );

      expect(result.ambiguousIdentities, ['CK']);
      expect(result.blocked, isFalse);
    });

    test('面板上只有一条同名记录时不报歧义', () {
      final result = analyze(
        const [EnvTransferItem(name: 'CK', value: 'new')],
        existing: const [EnvTransferItem(name: 'CK', value: 'old')],
      );

      expect(result.ambiguousIdentities, isEmpty);
    });

    test('提醒文案带上备注 —— 光有变量名定位不到是哪一条', () {
      final result = analyze(const [
        EnvTransferItem(name: 'CK', value: 'a', remarks: '账号1'),
        EnvTransferItem(name: 'CK', value: 'b', remarks: '账号1'),
      ]);

      expect(result.collapsedIdentities, ['CK（备注：账号1）']);
    });

    test('非法变量名只警告不拦（面板会逐条跳过，其余照常导入）', () {
      final result = analyze(const [
        EnvTransferItem(name: '2FA_TOKEN'),
        EnvTransferItem(name: 'has-dash'),
        EnvTransferItem(name: ''),
        EnvTransferItem(name: 'OK_NAME'),
      ]);

      expect(result.invalidNames, ['2FA_TOKEN', 'has-dash', '(空名称)']);
      expect(result.blocked, isFalse);
      expect(isValidEnvName('_ok1'), isTrue);
      expect(isValidEnvName('1bad'), isFalse);
    });

    test('超过面板 1MB 请求体上限时拦住', () {
      final huge = List<EnvTransferItem>.generate(
        300,
        (index) => EnvTransferItem(name: 'K$index', value: 'x' * 4096),
      );
      final result = analyze(huge);

      expect(result.payloadBytes, greaterThan(kEnvImportMaxBodyBytes));
      expect(result.oversized, isTrue);
      expect(result.blocked, isTrue);
    });

    test('空列表拦住 —— 不能把「什么都没解析出来」当成一次成功导入', () {
      expect(analyze(const []).blocked, isTrue);
    });

    test('长度前缀的身份键不会让不相干的两条撞在一起', () {
      // 非法名字也会走到这里，直接拿分隔符拼会把 A + B:C 和 A:B + C 认成同一条。
      final result = analyze(const [
        EnvTransferItem(name: 'A', remarks: 'B:C'),
        EnvTransferItem(name: 'A:B', remarks: 'C'),
      ]);

      expect(result.collapsedIdentities, isEmpty);
    });
  });

  group('EnvImportOutcome', () {
    test('原样转发面板的 message 与 errors', () {
      final outcome = EnvImportOutcome.fromResponse(const {
        'message': '成功导入 3 个环境变量',
        'errors': ['第 4 项: 名称 "2X" 格式无效', '  '],
      });

      expect(outcome.message, '成功导入 3 个环境变量');
      expect(outcome.errors, ['第 4 项: 名称 "2X" 格式无效']);
    });

    test('拿不到 message 时兜底，不编一句「成功导入 N 条」', () {
      // 接口没有导入条数的数字字段，APP 自己算一个会和面板对不上。
      final outcome = EnvImportOutcome.fromResponse(null);
      expect(outcome.message, '导入完成');
      expect(outcome.errors, isEmpty);
    });
  });
}
