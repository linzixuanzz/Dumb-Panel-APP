import 'package:daidai_app/features/subscriptions/utils/subscription_auth.dart';
import 'package:daidai_app/shared/models/subscription.dart';
import 'package:flutter_test/flutter_test.dart';

/// 订阅仓库鉴权的回归保护。
///
/// 这一块的风险不在 UI，在**请求体**：面板的 Update 接口是「有哪个键就改哪个键」
/// （server/handler/subscription.go:265-276 的 allowed 白名单），
/// 少发一个键 = 旧值留在库里。所以下面重点断言的是「切换鉴权方式时，
/// 上一种方式的字段有没有被显式清空」，而不是标签文案。
void main() {
  group('parseSubscriptionAuthType', () {
    test('认得面板的两个取值', () {
      expect(parseSubscriptionAuthType('ssh'), SubscriptionAuthType.ssh);
      expect(parseSubscriptionAuthType('token'), SubscriptionAuthType.token);
    });

    test('空 / null / 认不出来的值都按无鉴权 —— 和面板 NormalizeSubscriptionAuthType 一致', () {
      // 这里的兜底不是「猜一个」，是复刻面板真正会做的事：
      // 面板对认不出来的 auth_type 归一成空串，也就是按无鉴权跑。
      // APP 显示成无鉴权，用户看到的才是面板实际的行为。
      expect(parseSubscriptionAuthType(null), SubscriptionAuthType.none);
      expect(parseSubscriptionAuthType(''), SubscriptionAuthType.none);
      expect(parseSubscriptionAuthType('oauth'), SubscriptionAuthType.none);
    });

    test('大小写与空白不敏感', () {
      expect(parseSubscriptionAuthType(' SSH '), SubscriptionAuthType.ssh);
    });
  });

  group('buildSubscriptionAuthPayload', () {
    test('SSH：只留 ssh_key_id，token 与用户名显式清空', () {
      final payload = buildSubscriptionAuthPayload(
        subType: 'git-repo',
        authType: SubscriptionAuthType.ssh,
        sshKeyId: 7,
        authUsername: '残留用户名',
        authToken: '残留token',
      );
      expect(payload['auth_type'], 'ssh');
      expect(payload['ssh_key_id'], 7);
      expect(payload['auth_username'], '');
      expect(payload['auth_token'], '');
    });

    test('Token：只留用户名与 token，ssh_key_id 显式置 null', () {
      final payload = buildSubscriptionAuthPayload(
        subType: 'git-repo',
        authType: SubscriptionAuthType.token,
        sshKeyId: 7,
        authUsername: ' oauth2 ',
        authToken: ' ghp_xxx ',
      );
      expect(payload['auth_type'], 'token');
      // 不置 null 的话，用户从 SSH 切到 Token 之后旧密钥 id 还留在库里。
      expect(payload['ssh_key_id'], isNull);
      expect(payload['auth_username'], 'oauth2');
      expect(payload['auth_token'], 'ghp_xxx');
    });

    test('Token 且留空时仍然发 auth_token 键 —— 面板靠它判断「保持原值」', () {
      // server/handler/subscription.go:318：
      //   if trim(text) != "" || sub.EffectiveAuthType() != token { authToken = text }
      // 也就是「auth_type 还是 token + 传空串」= 保留已存 token。
      // Web 端也是原样发空串（index.vue:529-530），APP 不能省掉这个键。
      final payload = buildSubscriptionAuthPayload(
        subType: 'git-repo',
        authType: SubscriptionAuthType.token,
        authToken: '   ',
      );
      expect(payload.containsKey('auth_token'), isTrue);
      expect(payload['auth_token'], '');
    });

    test('无鉴权：四个键全部清空', () {
      final payload = buildSubscriptionAuthPayload(
        subType: 'git-repo',
        authType: SubscriptionAuthType.none,
        sshKeyId: 7,
        authUsername: 'u',
        authToken: 't',
      );
      expect(payload['auth_type'], '');
      expect(payload['ssh_key_id'], isNull);
      expect(payload['auth_username'], '');
      expect(payload['auth_token'], '');
    });

    test('单文件订阅无视选中的鉴权方式，一律清空 —— 与 Web 的归一化一致', () {
      final payload = buildSubscriptionAuthPayload(
        subType: 'single-file',
        authType: SubscriptionAuthType.token,
        authToken: 'ghp_xxx',
      );
      expect(payload['auth_type'], '');
      expect(payload['auth_token'], '');
    });

    test('四个键任何分支都在，不会漏发导致旧值残留', () {
      for (final type in SubscriptionAuthType.values) {
        final payload = buildSubscriptionAuthPayload(
          subType: 'git-repo',
          authType: type,
          sshKeyId: 1,
          authUsername: 'u',
          authToken: 't',
        );
        expect(
          payload.keys.toSet(),
          {'auth_type', 'ssh_key_id', 'auth_username', 'auth_token'},
          reason: '$type 分支漏了键',
        );
      }
    });
  });

  group('validateSubscriptionAuth', () {
    test('SSH 没选密钥时拦下，文案与面板 400 一致', () {
      expect(
        validateSubscriptionAuth(
          subType: 'git-repo',
          authType: SubscriptionAuthType.ssh,
        ),
        '已选择 SSH 鉴权，请指定 SSH 密钥',
      );
      expect(
        validateSubscriptionAuth(
          subType: 'git-repo',
          authType: SubscriptionAuthType.ssh,
          sshKeyId: 0,
        ),
        isNotNull,
      );
      expect(
        validateSubscriptionAuth(
          subType: 'git-repo',
          authType: SubscriptionAuthType.ssh,
          sshKeyId: 3,
        ),
        isNull,
      );
    });

    test('Token 为空时拦下', () {
      expect(
        validateSubscriptionAuth(
          subType: 'git-repo',
          authType: SubscriptionAuthType.token,
          authToken: '  ',
        ),
        '已选择 Token 鉴权，请填写访问令牌',
      );
    });

    test('编辑一个已存 token 的订阅时，留空表示「不改」，不能被判成没填', () {
      expect(
        validateSubscriptionAuth(
          subType: 'git-repo',
          authType: SubscriptionAuthType.token,
          authToken: '',
          isEdit: true,
          hasExistingToken: true,
        ),
        isNull,
      );
      // 新建时没有「已存 token」这回事，仍然要拦。
      expect(
        validateSubscriptionAuth(
          subType: 'git-repo',
          authType: SubscriptionAuthType.token,
          authToken: '',
          hasExistingToken: true,
        ),
        isNotNull,
      );
    });

    test('单文件订阅不做鉴权校验', () {
      expect(
        validateSubscriptionAuth(
          subType: 'single-file',
          authType: SubscriptionAuthType.ssh,
        ),
        isNull,
      );
    });
  });

  group('parseSshKeys', () {
    test('解析 {"data": [...]}', () {
      final keys = parseSshKeys(<String, dynamic>{
        'data': <dynamic>[
          <String, dynamic>{'id': 1, 'name': 'github-deploy'},
          <String, dynamic>{'id': 2, 'name': 'gitee'},
        ],
      });
      expect(keys.length, 2);
      expect(keys.first.name, 'github-deploy');
    });

    test('无名密钥退回 #id，下拉里不会出现空白项', () {
      final keys = parseSshKeys(<String, dynamic>{
        'data': <dynamic>[
          <String, dynamic>{'id': 5, 'name': '   '},
        ],
      });
      expect(keys.single.name, '密钥 #5');
    });

    test('403 / 老面板返回的任何非列表形状都给空列表', () {
      expect(parseSshKeys(null), isEmpty);
      expect(parseSshKeys(<String, dynamic>{'error': 'forbidden'}), isEmpty);
    });
  });

  group('Subscription model 新增的鉴权字段', () {
    test('从面板 ToDict 读出 auth_type / auth_username / has_auth_token', () {
      // 面板 model/subscription.go:67-69 下发的就是这三个键，
      // 且 auth_type 是 EffectiveAuthType()（会从已存的 token / 密钥反推）。
      final sub = Subscription.fromJson(<String, dynamic>{
        'id': 1,
        'name': 'repo',
        'type': 'git-repo',
        'auth_type': 'token',
        'auth_username': 'oauth2',
        'has_auth_token': true,
        'ssh_key_id': null,
      });
      expect(sub.authType, 'token');
      expect(sub.authUsername, 'oauth2');
      expect(sub.hasAuthToken, isTrue);
      expect(parseSubscriptionAuthType(sub.authType), SubscriptionAuthType.token);
    });

    test('老面板不下发这几个键时退化成无鉴权，不报错', () {
      final sub = Subscription.fromJson(<String, dynamic>{
        'id': 1,
        'name': 'repo',
        'type': 'git-repo',
      });
      expect(sub.authType, '');
      expect(sub.hasAuthToken, isFalse);
      expect(parseSubscriptionAuthType(sub.authType), SubscriptionAuthType.none);
    });
  });
}
