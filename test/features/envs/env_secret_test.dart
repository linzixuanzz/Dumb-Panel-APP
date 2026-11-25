import 'package:daidai_app/features/envs/utils/env_secret.dart';
import 'package:flutter_test/flutter_test.dart';

/// A6 敏感值识别与遮罩。规则照抄面板 `web/src/utils/envSecret.ts`（issue #127），
/// 下面两组名字向量与面板那份文件头里的「必须命中 16 条 / 必须不命中 7 条」逐字相同：
/// 面板、MCP、APP 三处只要有一处改了规则，这里就会红。
void main() {
  group('isSensitiveEnvName', () {
    const hits = [
      'JD_COOKIE',
      'S3_SECRET_ACCESS_KEY',
      'SMTP_PASSWORD',
      'API_TOKEN',
      'APP_SECRET',
      'DB_PASSWORD',
      'OPENAI_API_KEY',
      'APIKEY',
      'BARK_KEY',
      'PUSH_KEY',
      'JD_CK',
      'WSKEY',
      'TG_BOT_TOKEN',
      'X_AUTH',
      'DB_PWD',
      'MAIL_PASS',
    ];
    const misses = [
      'SEARCH_KEYWORD',
      'AUTHOR_NAME',
      'BYPASS_PROXY',
      'MONKEY_X',
      'QUICK_MODE',
      'KEYWORDS',
      'PASSPORT_URL',
    ];

    test('必须命中的 16 条', () {
      for (final name in hits) {
        expect(isSensitiveEnvName(name), isTrue, reason: name);
      }
    });

    test('必须不命中的 7 条', () {
      for (final name in misses) {
        expect(isSensitiveEnvName(name), isFalse, reason: name);
      }
    });

    test('不区分大小写；空名字不算', () {
      expect(isSensitiveEnvName('jd_cookie'), isTrue);
      expect(isSensitiveEnvName('push_key'), isTrue);
      expect(isSensitiveEnvName(''), isFalse);
    });

    test('已知漏判照面板口径：驼峰 barkKey 不是一整段 KEY', () {
      expect(isSensitiveEnvName('barkKey'), isFalse);
    });
  });

  group('maskEnvValue', () {
    test('长度 > 8：前 3 + 6 个星号 + 后 3', () {
      expect(maskEnvValue('abcdefghijk'), 'abc******ijk');
      expect(maskEnvValue('123456789'), '123******789');
    });

    test('长度 ≤ 8：一律 8 个星号（看不出原值多长）', () {
      expect(maskEnvValue('12345678'), '********');
      expect(maskEnvValue('a'), '********');
      expect(maskEnvValue(''), '********');
    });

    test('按码点切，不把 emoji 劈成半个代理对', () {
      // 10 个码点：前 3 个 emoji + ****** + 后 3 个 emoji
      const value = '😀😁😂🤣😃😄😅😆😉😊';
      expect(maskEnvValue(value), '😀😁😂******😆😉😊');
    });
  });

  group('shouldMaskEnvValue', () {
    test('名字像凭据且值不空才遮', () {
      expect(shouldMaskEnvValue('JD_COOKIE', 'pt_key=1'), isTrue);
      expect(shouldMaskEnvValue('JD_COOKIE', ''), isFalse);
      expect(shouldMaskEnvValue('BACKUP_DIR', '/data/backup'), isFalse);
    });
  });
}
