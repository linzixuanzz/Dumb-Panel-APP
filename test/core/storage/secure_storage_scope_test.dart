import 'package:daidai_app/core/network/dio_client.dart';
import 'package:daidai_app/core/storage/secure_storage.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 登录凭据按面板分片（issue #13，v1.3.7）的两条回归保护。
///
/// 这块改动的两个后果都很难在别处被发现：
/// 1. 升级迁移放错位置 / 写失败就删老 key，存量用户升级后**集体掉线**或凭据永久丢失；
/// 2. scope 拼错，A 的 token 会被当成 B 的发出去 —— 这是真正的串台，
///    比「要重登一次」严重得多。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const panelA = 'https://a.panel.test';
  const panelB = 'https://b.panel.test';

  test('升级迁移：老的裸 key 归给 server_url 那台面板，写成功后老 key 被删干净', () async {
    // v1.3.6 及以前的现场：token / user / 可信期都是全局一份裸 key。
    final until = DateTime.now()
        .toUtc()
        .add(const Duration(days: 3))
        .toIso8601String();
    SharedPreferences.setMockInitialValues({'server_url': panelA});
    FlutterSecureStorage.setMockInitialValues({
      'access_token': 'legacy-access',
      'refresh_token': 'legacy-refresh',
      'auth_user': '{"id":1,"username":"admin"}',
      'trusted_login_until': until,
      'trusted_login_server_url': panelA,
    });

    await SecureStorage.migrateLegacyAuthScope();

    // 迁到了 A 名下：切到 A 就能照常读出来，用户不用重新登录。
    DioClient.instance.setBaseUrl(panelA);
    expect(await SecureStorage.getAccessToken(), 'legacy-access');
    expect(await SecureStorage.getRefreshToken(), 'legacy-refresh');
    expect(await SecureStorage.hasValidTrustedLogin(), isTrue);

    // key 形状本身也是契约的一部分：`<名字>::<sha256(url) 前 16 位>`。
    expect(
      await SecureStorage.readValue(
        'access_token::${SecureStorage.scopeOf(panelA)}',
      ),
      'legacy-access',
    );

    // 老 key 必须删干净，否则下次启动还会再迁一遍（而且会把用户改过的凭据盖回去）。
    expect(await SecureStorage.readValue('access_token'), isNull);
    expect(await SecureStorage.readValue('refresh_token'), isNull);
    expect(await SecureStorage.readValue('auth_user'), isNull);
    expect(await SecureStorage.readValue('trusted_login_until'), isNull);
    expect(await SecureStorage.readValue('trusted_login_server_url'), isNull);

    // 幂等：老 key 已经不在，第二次跑什么都不做，不会把 A 的凭据碰坏。
    await SecureStorage.migrateLegacyAuthScope();
    expect(await SecureStorage.getAccessToken(), 'legacy-access');
  });

  test('串台保护：A 的 token 不会被 B 读到，切回 A 又还在', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    DioClient.instance.setBaseUrl(panelA);
    await SecureStorage.saveTokens(
      accessToken: 'a-access',
      refreshToken: 'a-refresh',
    );

    // 切到 B：读不到任何东西 —— 这一条钉的就是「A 的 token 不会发给 B」。
    DioClient.instance.setBaseUrl(panelB);
    expect(await SecureStorage.getAccessToken(), isNull);
    expect(await SecureStorage.getRefreshToken(), isNull);

    // B 自己登一份，两边互不覆盖。
    await SecureStorage.saveTokens(
      accessToken: 'b-access',
      refreshToken: 'b-refresh',
    );
    expect(await SecureStorage.getAccessToken(), 'b-access');

    // 切回 A：原样还在，这正是 issue #13 要的「切回去不用重新登录」。
    DioClient.instance.setBaseUrl(panelA);
    expect(await SecureStorage.getAccessToken(), 'a-access');

    // 结尾斜杠不能分叉出第二个 scope（setBaseUrl 会去一次，scopeOf 自己也会去一次）。
    DioClient.instance.setBaseUrl('$panelA/');
    expect(await SecureStorage.getAccessToken(), 'a-access');

    // 删掉 A 这台面板时，它那份凭据一起清掉，不留长期 refresh token 在设备上。
    await SecureStorage.removePanel(panelA);
    expect(await SecureStorage.getAccessToken(), isNull);
    DioClient.instance.setBaseUrl(panelB);
    expect(await SecureStorage.getAccessToken(), 'b-access', reason: 'B 不受影响');
  });
}
