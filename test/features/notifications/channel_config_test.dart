import 'dart:convert';

import 'package:daidai_app/features/notifications/utils/channel_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// 通知渠道「读取 → 修改 → 回写」的回归保护。
///
/// 背景：APP 的字段表（notification_list_page.dart 的 `_channelFieldMap`）是本地写死的，
/// 面板支持而表里没有的键（telegram proxy、wecom 图文卡片参数…）一旦被覆盖掉，
/// 用户在 Web 上配好的东西就没了，而且**在 APP 里完全看不出来**。
void main() {
  group('buildChannelConfigFromFields', () {
    test('APP 字段表里没有的键（telegram proxy）保存后仍在', () {
      final existing = <String, dynamic>{
        'token': '123:ABC',
        'chat_id': '-100123',
        // 面板支持、APP 字段表里没有的键。
        'proxy': 'socks5://127.0.0.1:1080',
        'parse_mode': 'MarkdownV2',
      };

      final result = buildChannelConfigFromFields(
        existingConfig: existing,
        keepExistingConfig: true,
        fieldValues: const {
          'token': '123:ABC',
          'chat_id': '-100999',
          'api_host': '',
        },
      );

      expect(result['proxy'], 'socks5://127.0.0.1:1080');
      expect(result['parse_mode'], 'MarkdownV2');
      expect(result['chat_id'], '-100999', reason: '表单改过的字段要生效');
    });

    test('表单里被清空的字段视为删除，不退回旧值', () {
      final result = buildChannelConfigFromFields(
        existingConfig: const {'webhook': 'https://old', 'secret': 'SEC123'},
        keepExistingConfig: true,
        fieldValues: const {'webhook': 'https://new', 'secret': ''},
      );

      expect(result['webhook'], 'https://new');
      expect(result.containsKey('secret'), isFalse);
    });

    test('切换渠道类型后不把旧类型的配置带回去', () {
      final result = buildChannelConfigFromFields(
        existingConfig: const {
          'token': '123:ABC',
          'proxy': 'socks5://127.0.0.1:1080',
        },
        // 用户在下拉里把 telegram 换成了 bark。
        keepExistingConfig: false,
        fieldValues: const {'key': 'device-key'},
      );

      expect(result, {'key': 'device-key'});
      expect(result.containsKey('proxy'), isFalse);
      expect(result.containsKey('token'), isFalse);
    });

    test('email 的 smtp_ssl 写进 config；非 email 不写', () {
      final withSsl = buildChannelConfigFromFields(
        existingConfig: const {'smtp_host': 'smtp.qq.com'},
        keepExistingConfig: true,
        fieldValues: const {'smtp_host': 'smtp.qq.com'},
        smtpSslMode: smtpSslModeOn,
      );
      expect(withSsl['smtp_ssl'], 'true');

      final withoutSsl = buildChannelConfigFromFields(
        existingConfig: const {'url': 'https://example.com'},
        keepExistingConfig: true,
        fieldValues: const {'url': 'https://example.com'},
      );
      expect(withoutSsl.containsKey('smtp_ssl'), isFalse);
    });

    // ★ 面板 sendToChannel 把 config 反序列化成 map[string]string
    //   （server/service/notifier.go:166-168），出现 bool 会让整份 Unmarshal 失败：
    //   `json: cannot unmarshal bool into Go value of type string`，
    //   该渠道所有通知（含「测试」按钮）从此全挂，且 Web 端原样读写也修不回来。
    test('写入的 smtp_ssl 必须是字符串，绝不能是 bool', () {
      for (final mode in const [
        smtpSslModeAuto,
        smtpSslModeOn,
        smtpSslModeOff,
      ]) {
        final config = buildChannelConfigFromFields(
          existingConfig: const {},
          keepExistingConfig: false,
          fieldValues: const {'smtp_host': 'smtp.qq.com'},
          smtpSslMode: mode,
        );
        expect(
          config['smtp_ssl'],
          isA<String>(),
          reason: 'bool 会让面板整份 config 解析失败',
        );
        expect(config['smtp_ssl'], mode);
        // 逐字校验落地 JSON，避免「Dart 侧是 String、编码后仍是 bool」这种漏网写法。
        expect(
          jsonEncode(config),
          contains('"smtp_ssl":"$mode"'),
          reason: '面板只认 auto/true/false 三个字符串',
        );
      }
    });

    test('写入值被收敛到 auto/true/false 三态，不透传乱值', () {
      final config = buildChannelConfigFromFields(
        existingConfig: const {},
        keepExistingConfig: false,
        fieldValues: const {'smtp_host': 'smtp.qq.com'},
        smtpSslMode: 'YES',
      );
      expect(config['smtp_ssl'], 'true');
    });

    test('打开 → 一个字不改 → 保存，smtp_ssl 不被改写', () {
      // 存量 auto（Web 端默认）最容易被压成 false：
      // 用 bool 开关表达三态时，auto 会显示成「关闭」，一存就替用户关掉 465 的 SSL。
      const existing = <String, dynamic>{
        'smtp_host': 'smtp.qq.com',
        'smtp_port': '465',
        'smtp_ssl': 'auto',
      };

      final saved = buildChannelConfigFromFields(
        existingConfig: existing,
        keepExistingConfig: true,
        fieldValues: const {
          'smtp_host': 'smtp.qq.com',
          'smtp_port': '465',
        },
        smtpSslMode: resolveSmtpSslMode(existing),
      );

      expect(saved['smtp_ssl'], 'auto');
    });

    test('不修改传入的 existingConfig', () {
      final existing = <String, dynamic>{'token': 'a', 'proxy': 'p'};
      buildChannelConfigFromFields(
        existingConfig: existing,
        keepExistingConfig: true,
        fieldValues: const {'token': 'b'},
      );
      expect(existing['token'], 'a');
    });
  });

  // 面板判定 SSL 的实现见 server/service/notifier.go:357-370（smtpImplicitSSLEnabled）
  // 与 :1273-1283（notificationConfigBool）。这里的用例逐条对齐它的语义。
  group('resolveSmtpSslMode', () {
    test('存量字符串按面板语义读回', () {
      expect(resolveSmtpSslMode(const {'smtp_ssl': 'true'}), smtpSslModeOn);
      expect(resolveSmtpSslMode(const {'smtp_ssl': 'false'}), smtpSslModeOff);
      expect(resolveSmtpSslMode(const {'smtp_ssl': 'auto'}), smtpSslModeAuto);
      expect(resolveSmtpSslMode(const {'smtp_ssl': 'AUTO'}), smtpSslModeAuto);
      expect(resolveSmtpSslMode(const {'smtp_ssl': ' true '}), smtpSslModeOn);
      // notificationConfigBool 认的同义词。
      expect(resolveSmtpSslMode(const {'smtp_ssl': '1'}), smtpSslModeOn);
      expect(resolveSmtpSslMode(const {'smtp_ssl': 'enabled'}), smtpSslModeOn);
      expect(resolveSmtpSslMode(const {'smtp_ssl': 'off'}), smtpSslModeOff);
      // 空串在面板等价于 auto（按端口是否 465 判断）。
      expect(resolveSmtpSslMode(const {'smtp_ssl': ''}), smtpSslModeAuto);
      // 面板对无法识别的值取 defaultValue=false。
      expect(resolveSmtpSslMode(const {'smtp_ssl': '???'}), smtpSslModeOff);
    });

    test('存量 bool（旧版 APP 写坏的数据）也能读回', () {
      expect(resolveSmtpSslMode(const {'smtp_ssl': true}), smtpSslModeOn);
      expect(resolveSmtpSslMode(const {'smtp_ssl': false}), smtpSslModeOff);
    });

    test('键不存在按 auto 处理，不能显示成关闭', () {
      expect(resolveSmtpSslMode(const {}), smtpSslModeAuto);
      expect(
        resolveSmtpSslMode(const {'smtp_host': 'smtp.qq.com'}),
        smtpSslModeAuto,
      );
    });

    test('识别面板的 4 个兼容别名，并保持同样的优先级', () {
      expect(resolveSmtpSslMode(const {'use_ssl': 'true'}), smtpSslModeOn);
      expect(resolveSmtpSslMode(const {'smtp_use_ssl': 'true'}), smtpSslModeOn);
      expect(resolveSmtpSslMode(const {'enable_ssl': 'true'}), smtpSslModeOn);
      expect(resolveSmtpSslMode(const {'ssl': 'true'}), smtpSslModeOn);

      // 面板取「第一个存在的键」，smtp_ssl 排在别名前面。
      expect(
        resolveSmtpSslMode(const {'smtp_ssl': 'false', 'use_ssl': 'true'}),
        smtpSslModeOff,
      );
    });

    test('别名配置存下来后不被改变含义，且别名本身不丢', () {
      const existing = <String, dynamic>{
        'smtp_host': 'smtp.qq.com',
        'smtp_port': '587',
        'use_ssl': 'true',
      };

      final saved = buildChannelConfigFromFields(
        existingConfig: existing,
        keepExistingConfig: true,
        fieldValues: const {
          'smtp_host': 'smtp.qq.com',
          'smtp_port': '587',
        },
        smtpSslMode: resolveSmtpSslMode(existing),
      );

      // 写回主键：面板取键顺序里 smtp_ssl 在最前，值又是从 use_ssl 解析来的，
      // 所以面板的判定结果不变；同时 Web 端（只认 smtp_ssl）也能正常显示。
      expect(saved['smtp_ssl'], 'true');
      expect(saved['use_ssl'], 'true', reason: '未知/别名字段不能丢');
    });
  });

  group('custom 渠道的 JSON 编辑框', () {
    test('打开已有渠道 → 直接保存 → 配置不被清空', () {
      final existing = <String, dynamic>{
        'url': 'https://example.com/hook',
        'method': 'POST',
        'headers': {'X-Token': 'abc'},
      };

      // 打开弹窗：编辑框回填服务端已有配置。
      final editorText = buildRawConfigEditorText(
        existingConfig: existing,
        keepExistingConfig: true,
      );
      expect(editorText, isNotEmpty, reason: '初值为空 = 保存时用 {} 覆盖，整份配置没了');

      // 用户一个字都没改就点保存。
      final saved = parseChannelConfig(
        editorText.isEmpty ? '{}' : editorText,
      );

      expect(saved, isNotNull);
      expect(saved, existing);
    });

    test('切换到 custom 时编辑框是空的，不带旧类型的配置', () {
      final editorText = buildRawConfigEditorText(
        existingConfig: const {'token': '123:ABC'},
        keepExistingConfig: false,
      );
      expect(editorText, isEmpty);
    });

    test('新建渠道时编辑框是空的', () {
      final editorText = buildRawConfigEditorText(
        existingConfig: const {},
        keepExistingConfig: true,
      );
      expect(editorText, isEmpty);
    });

    test('JSON 写错返回 null，调用方必须提示而不是退化成 {}', () {
      expect(parseChannelConfig('{"a": '), isNull);
      expect(parseChannelConfig('[1, 2]'), isNull, reason: '顶层不是对象也不合法');
      expect(parseChannelConfig(''), isEmpty);
      expect(parseChannelConfig('{"a": 1}'), {'a': 1});
    });

    test('回填的文本是合法 JSON，能被原样解析回去', () {
      final existing = <String, dynamic>{
        'nested': {
          'list': [1, 2, 3],
        },
        'flag': true,
      };
      final editorText = buildRawConfigEditorText(
        existingConfig: existing,
        keepExistingConfig: true,
      );
      expect(jsonDecode(editorText), existing);
    });
  });
}
