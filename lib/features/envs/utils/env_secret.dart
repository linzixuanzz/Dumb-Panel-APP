import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/error_codes.dart' as auth_error;
import 'package:local_auth/local_auth.dart';

/// 环境变量敏感值的识别与遮蔽（APP v2.0 A6，对齐面板 issue #127）。
///
/// 规则**逐字照抄**面板 `web/src/utils/envSecret.ts`（网页默认档「自动」）：只看变量名，
/// 不看值。面板那份文件头写明「Go 侧 MCP 也按它实现，两边必须逐字一致」，APP 是第三份副本，
/// 改关键词清单、切段口径、遮罩格式时三处一起改，`test/features/envs/env_secret_test.dart`
/// 里的两组测试向量与面板那份相同。
///
/// 只管「页面上怎么显示」：接口返回、导出、编辑保存仍是明文。和网页不同的是，
/// APP 开了应用锁时，查看 / 复制被遮住的值前要先过一次本机验证（见 [envDeviceAuthProvider]）；
/// 没开应用锁就不验证，点「查看」直接显示。
///
/// ── 识别规则 [isSensitiveEnvName] ──
/// 先整体转大写，再按 `_` 切段：
///   · 长词按【子串】匹配：TOKEN SECRET PASSWORD PASSWD COOKIE CREDENTIAL WSKEY PRIVATE APIKEY ACCESSKEY
///   · 短词按【整段】匹配：KEY PWD PASS AUTH SK AK SID CK WSCK
/// 短词不做子串是刻意的：KEY 做子串会误伤 KEYWORD / MONKEY，PASS 会误伤 BYPASS / PASSPORT。
///
/// ── 遮罩格式 [maskEnvValue] ──
///   长度 > 8：前 3 个字符 + `******` + 后 3 个字符；长度 ≤ 8：一律 `********`。
///   长度按 Unicode 码点算（面板 Array.from / Go []rune 同口径），不会把 emoji 劈成半个。
const List<String> _substringKeywords = [
  'TOKEN',
  'SECRET',
  'PASSWORD',
  'PASSWD',
  'COOKIE',
  'CREDENTIAL',
  'WSKEY',
  'PRIVATE',
  'APIKEY',
  'ACCESSKEY',
];

const Set<String> _segmentKeywords = {
  'KEY',
  'PWD',
  'PASS',
  'AUTH',
  'SK',
  'AK',
  'SID',
  'CK',
  'WSCK',
};

/// 变量名是否像凭据。
bool isSensitiveEnvName(String name) {
  final upper = name.toUpperCase();
  if (upper.isEmpty) {
    return false;
  }
  if (_substringKeywords.any(upper.contains)) {
    return true;
  }
  return upper.split('_').any(_segmentKeywords.contains);
}

/// 这一条的值在列表 / 详情里默认要不要遮住：名字像凭据、并且值不是空的
/// （空值没什么可藏的，遮成 `********` 反而让人以为里面有东西）。
bool shouldMaskEnvValue(String name, String value) =>
    value.isNotEmpty && isSensitiveEnvName(name);

/// 把值换成定长遮罩。中间星号定长，看显示宽度猜不出原值有多长。
String maskEnvValue(String value) {
  final chars = value.runes.toList();
  if (chars.length <= 8) {
    return '********';
  }
  return '${String.fromCharCodes(chars.take(3))}******'
      '${String.fromCharCodes(chars.skip(chars.length - 3))}';
}

/// 系统验证的结果。
enum EnvAuthOutcome {
  /// 验证通过。
  passed,

  /// 用户取消、没认出来、被锁定，或者插件出了别的错：一律不放行。
  failed,

  /// 这台设备根本做不了系统验证（没锁屏密码、没硬件）：交给页面按应用锁的降级策略处理。
  unavailable,
}

class EnvAuthResult {
  const EnvAuthResult(this.outcome, [this.message]);

  final EnvAuthOutcome outcome;

  /// 失败时给用户看的一句话；用户自己取消时为 null（不提示）。
  final String? message;
}

typedef EnvDeviceAuthenticator = Future<EnvAuthResult> Function();

/// 查看 / 复制敏感值前的系统验证：指纹、面容或设备密码（锁屏 PIN / 图案）。
///
/// 做成 Provider 只为了测试能替换掉它（widget test 里没有 local_auth 的平台实现）。
final envDeviceAuthProvider = Provider<EnvDeviceAuthenticator>(
  (ref) => authenticateEnvRevealWithDevice,
);

/// 真正调 local_auth 的那一份。
///
/// 和应用锁（`AppLockController.unlockWithBiometric`）的区别只有 `biometricOnly: false`：
/// 应用锁自己有密码 / 图案兜底，所以只认生物识别；这里没有自带的兜底，
/// 直接让系统在指纹 / 面容之外也接受锁屏密码，没录指纹的设备照样能验证。
Future<EnvAuthResult> authenticateEnvRevealWithDevice() async {
  final localAuth = LocalAuthentication();
  try {
    if (!await localAuth.isDeviceSupported()) {
      return const EnvAuthResult(EnvAuthOutcome.unavailable);
    }
    final ok = await localAuth.authenticate(
      localizedReason: '验证身份以查看或复制变量值',
      options: const AuthenticationOptions(
        biometricOnly: false,
        stickyAuth: true,
        sensitiveTransaction: true,
      ),
    );
    // 返回 false 多半是用户自己点了取消，不弹提示。
    return EnvAuthResult(ok ? EnvAuthOutcome.passed : EnvAuthOutcome.failed);
  } on MissingPluginException {
    // 网页版没有 local_auth 实现：和「不是手机系统」（otherOperatingSystem）同一种情况，按设备不支持处理。
    return const EnvAuthResult(EnvAuthOutcome.unavailable);
  } on PlatformException catch (error) {
    switch (error.code) {
      // 设备做不了：没锁屏密码、没录入、没硬件、不是手机系统。
      case auth_error.notAvailable:
      case auth_error.notEnrolled:
      case auth_error.passcodeNotSet:
      case auth_error.otherOperatingSystem:
        return const EnvAuthResult(EnvAuthOutcome.unavailable);
      case auth_error.lockedOut:
      case auth_error.permanentlyLockedOut:
        return const EnvAuthResult(
          EnvAuthOutcome.failed,
          '尝试次数过多，验证已被系统暂时锁定，请稍后再试',
        );
      default:
        // 「上一次验证还没结束」之类的瞬时错误：不能当成「设备不支持」放行。
        return const EnvAuthResult(EnvAuthOutcome.failed, '验证暂时不可用，请稍后再试');
    }
  }
}
