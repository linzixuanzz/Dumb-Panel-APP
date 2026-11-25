import 'package:daidai_app/features/app_lock/providers/app_lock_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// 网页版没有 local_auth 的平台实现，调用会抛 MissingPluginException（不是 PlatformException）。
/// 测试环境里同样没有注册 local_auth 的通道，正好模拟网页版的情况。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('没有 local_auth 实现时 initialize 正常结束：不抛错、不卡在 loading、视为没有生物识别', () async {
    final controller = AppLockController();
    addTearDown(controller.dispose);

    // 以前 MissingPluginException 会从这里冒出去：网页版控制台报未捕获错误，loading 一直为 true
    await controller.initialize();

    expect(controller.state.loading, isFalse);
    expect(controller.state.availableBiometrics, isEmpty);
    expect(controller.state.config.biometricEnabled, isFalse);
  });
}
