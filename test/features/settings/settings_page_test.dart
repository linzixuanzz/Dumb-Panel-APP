import 'package:daidai_app/core/auth/auth_provider.dart';
import 'package:daidai_app/core/auth/auth_service.dart';
import 'package:daidai_app/core/integration/integration_settings.dart';
import 'package:daidai_app/core/network/dio_client.dart';
import 'package:daidai_app/core/services/app_update_service.dart';
import 'package:daidai_app/core/storage/secure_storage.dart';
import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/core/theme/theme_mode_provider.dart';
import 'package:daidai_app/features/settings/views/settings_page.dart';
import 'package:daidai_app/shared/models/user.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_http_adapter.dart';

User _user(String role) => User(
  id: 1,
  username: 'tester',
  role: role,
  enabled: true,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

class _FakeAuth extends AuthNotifier {
  _FakeAuth(User user) : super(AuthService()) {
    state = AuthState(status: AuthStatus.authenticated, user: user);
  }
}

/// 常驻通知设置项（B8 提供）的替身：可控「是否支持」「是否授权」，并记下调用。
class _FakeRunningNotification extends RunningNotificationSetting {
  _FakeRunningNotification({required this.isSupported, required this.grant});

  final bool isSupported;
  final bool grant;
  final List<bool> calls = [];

  @override
  bool get supported => isSupported;

  @override
  Future<bool> setEnabled(bool on) async {
    calls.add(on);
    // 用户在系统权限框里点了「拒绝」时，实际状态仍是关
    state = on && grant;
    return state;
  }
}

Future<void> _closePage(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

/// 设置页：页面在 '/'，管理入口落到占位页。返回 ProviderContainer 以便断言 provider。
Future<ProviderContainer> _open(
  WidgetTester tester, {
  String role = 'admin',
  _FakeRunningNotification? notification,
}) async {
  tester.view.physicalSize = const Size(400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [
      authProvider.overrideWith((ref) => _FakeAuth(_user(role))),
      runningNotificationEnabledProvider.overrideWith(
        (ref) =>
            notification ??
            _FakeRunningNotification(isSupported: true, grant: true),
      ),
    ],
  );
  addTearDown(container.dispose);

  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, state) => const SettingsPage()),
      GoRoute(
        path: '/backup',
        builder: (_, state) => const Scaffold(body: Text('备份页占位')),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: Consumer(
        builder: (context, ref, _) => MaterialApp.router(
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: ref.watch(themeModeProvider),
          routerConfig: router,
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
  return container;
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues({});
    ThemeModeNotifier.resetForTest();
    DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter(
      (_) => jsonResponse(<String, dynamic>{}, status: 404),
    );
    AppUpdateService.checkOverrideForTest = () async => null;
    await SecureStorage.savePanel(
      const PanelConfig(url: 'https://nas.example.com:5700', name: '家里的 NAS'),
    );
    await SecureStorage.saveServerUrl('https://nas.example.com:5700');
  });

  tearDown(() {
    AppUpdateService.checkOverrideForTest = null;
    ThemeModeNotifier.resetForTest();
  });

  testWidgets('星空个人卡：用户名、角色、当前面板名称和地址', (tester) async {
    await _open(tester);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('tester'), findsOneWidget);
    expect(find.text('管理员 · 家里的 NAS'), findsOneWidget);
    expect(find.text('nas.example.com:5700'), findsOneWidget);
    expect(find.text('1 个面板'), findsOneWidget, reason: '服务器管理右侧显示面板数');
    expect(tester.takeException(), isNull);

    await _closePage(tester);
  });

  testWidgets('管理员：管理 / 系统分区的入口都在，备份可直达', (tester) async {
    await _open(tester);

    for (final title in [
      '脚本',
      '订阅',
      '依赖',
      '通知渠道',
      '用户',
      '安全',
      'Open API',
      '系统设置',
      '配置文件',
      '面板日志',
      '备份',
      '赞助名单',
      '关于',
    ]) {
      expect(find.text(title), findsOneWidget, reason: title);
    }

    await tester.ensureVisible(find.text('备份'));
    await tester.tap(find.text('备份'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('备份页占位'), findsOneWidget);

    await _closePage(tester);
  });

  testWidgets('非管理员：只有通知渠道，没有管理员入口', (tester) async {
    await _open(tester, role: 'operator');

    expect(find.text('通知渠道'), findsOneWidget);
    for (final title in ['脚本', '订阅', '依赖', '用户', '系统设置', '备份', '配置文件']) {
      expect(find.text(title), findsNothing, reason: title);
    }
    expect(find.text('操作员 · 家里的 NAS'), findsOneWidget);

    await _closePage(tester);
  });

  testWidgets('外观：点深色预览卡 → 深色并落盘；打开跟随系统 → 回到跟随系统', (tester) async {
    final container = await _open(tester);
    expect(container.read(themeModeProvider), ThemeMode.system);

    await tester.tap(find.byKey(const Key('appearance-dark')));
    await tester.pumpAndSettle();
    expect(container.read(themeModeProvider), ThemeMode.dark);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ThemeModeNotifier.prefsKey), 'dark');
    // 已经切成深色主题
    expect(
      Theme.of(tester.element(find.byType(SettingsPage))).brightness,
      Brightness.dark,
    );

    // 「跟随系统」开关此时是关的，打开它
    final follow = find.descendant(
      of: find.byKey(const Key('appearance-follow-system')),
      matching: find.byType(Switch),
    );
    expect(tester.widget<Switch>(follow).value, isFalse);
    await tester.tap(follow);
    await tester.pumpAndSettle();
    expect(container.read(themeModeProvider), ThemeMode.system);
    expect(prefs.getString(ThemeModeNotifier.prefsKey), 'system');

    // 关掉跟随系统：固定成当前看到的那一种（测试环境系统是浅色）
    await tester.tap(follow);
    await tester.pumpAndSettle();
    expect(container.read(themeModeProvider), ThemeMode.light);

    await _closePage(tester);
  });

  group('运行中常驻通知', () {
    Finder switchOf() => find.descendant(
      of: find.byKey(const Key('settings-running-notification')),
      matching: find.byType(Switch),
    );

    testWidgets('授权：打开后开关为开', (tester) async {
      final fake = _FakeRunningNotification(isSupported: true, grant: true);
      await _open(tester, notification: fake);

      expect(tester.widget<Switch>(switchOf()).value, isFalse);
      await tester.tap(switchOf());
      await tester.pumpAndSettle();

      expect(fake.calls, [true]);
      expect(tester.widget<Switch>(switchOf()).value, isTrue);

      await _closePage(tester);
    });

    testWidgets('被拒：开关回到关，并提示原因', (tester) async {
      final fake = _FakeRunningNotification(isSupported: true, grant: false);
      await _open(tester, notification: fake);

      await tester.tap(switchOf());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(fake.calls, [true]);
      expect(tester.widget<Switch>(switchOf()).value, isFalse);
      expect(find.textContaining('没有通知权限'), findsOneWidget);

      await _closePage(tester);
    });

    testWidgets('不支持的平台：置灰、写明仅安卓、开关不可点', (tester) async {
      final fake = _FakeRunningNotification(isSupported: false, grant: true);
      await _open(tester, notification: fake);

      expect(find.text('仅安卓'), findsOneWidget);
      final sw = tester.widget<Switch>(switchOf());
      expect(sw.onChanged, isNull);
      expect(sw.value, isFalse);

      await _closePage(tester);
    });
  });
}
