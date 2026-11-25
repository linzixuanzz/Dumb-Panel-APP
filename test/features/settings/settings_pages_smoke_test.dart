import 'package:daidai_app/core/auth/auth_provider.dart';
import 'package:daidai_app/core/auth/auth_service.dart';
import 'package:daidai_app/core/integration/integration_settings.dart';
import 'package:daidai_app/core/network/dio_client.dart';
import 'package:daidai_app/core/storage/secure_storage.dart';
import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/features/app_lock/views/app_lock_settings_page.dart';
import 'package:daidai_app/features/server_config/views/server_config_page.dart';
import 'package:daidai_app/features/settings/views/about_page.dart';
import 'package:daidai_app/features/settings/views/settings_page.dart';
import 'package:daidai_app/features/settings/views/sponsor_page.dart';
import 'package:daidai_app/shared/models/user.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_http_adapter.dart';

class _FakeAuth extends AuthNotifier {
  _FakeAuth() : super(AuthService()) {
    state = AuthState(
      status: AuthStatus.authenticated,
      user: User(
        id: 1,
        username: 'a-very-long-user-name-for-narrow-screens',
        role: 'admin',
        enabled: true,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
    );
  }
}

/// 不碰平台通道的常驻通知设置项替身。
class _FakeRunningNotification extends RunningNotificationSetting {
  @override
  bool get supported => true;

  @override
  Future<bool> setEnabled(bool on) async => state = on;
}

/// 有常驻转圈的页面不能 pumpAndSettle，按帧推进。
Future<void> _pumpFrames(WidgetTester tester, [int count = 10]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// v2.0 换装后的页面：360 宽、1.3 倍字号、浅 / 深两套主题下都不溢出、不抛异常。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: '呆呆面板',
      packageName: 'com.daidai.panel',
      version: '2.0.0',
      buildNumber: '37',
      buildSignature: '',
    );
    DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter(
      (_) => jsonResponse(<String, dynamic>{}, status: 404),
    );
    await SecureStorage.savePanel(
      const PanelConfig(
        url: 'https://a-really-long-panel-host.example.com:5700',
        name: '一个名字特别长特别长的家里的面板',
      ),
    );
    await SecureStorage.saveServerUrl(
      'https://a-really-long-panel-host.example.com:5700',
    );
  });

  final pages = <String, Widget Function()>{
    '设置': () => const SettingsPage(),
    '服务器管理': () => const ServerConfigPage(manageMode: true),
    '连接面板': () => const ServerConfigPage(),
    '应用锁': () => const AppLockSettingsPage(),
    '关于': () => const AboutPage(),
    '赞助名单': () => const SponsorPage(),
  };

  for (final dark in [false, true]) {
    for (final entry in pages.entries) {
      testWidgets('${entry.key}（${dark ? '深色' : '浅色'}）：窄屏大字号不溢出', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(360, 780);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        tester.platformDispatcher.textScaleFactorTestValue = 1.3;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

        final router = GoRouter(
          routes: [GoRoute(path: '/', builder: (_, state) => entry.value())],
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authProvider.overrideWith((ref) => _FakeAuth()),
              runningNotificationEnabledProvider.overrideWith(
                (ref) => _FakeRunningNotification(),
              ),
            ],
            child: MaterialApp.router(
              theme: dark ? AppTheme.dark() : AppTheme.light(),
              routerConfig: router,
            ),
          ),
        );
        await _pumpFrames(tester);
        expect(tester.takeException(), isNull);

        // 滚到底再看一次（下半部分的分组也要排得下）
        final scrollable = find.byType(Scrollable);
        if (scrollable.evaluate().isNotEmpty) {
          await tester.drag(scrollable.first, const Offset(0, -3000));
          await _pumpFrames(tester);
          expect(tester.takeException(), isNull);
        }

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
      });
    }
  }
}
