import 'package:daidai_app/core/auth/auth_provider.dart';
import 'package:daidai_app/core/auth/auth_service.dart';
import 'package:daidai_app/core/network/dio_client.dart';
import 'package:daidai_app/core/router/app_router.dart';
import 'package:daidai_app/core/router/default_landing_page.dart';
import 'package:daidai_app/core/services/app_update_service.dart';
import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/features/login/views/app_boot_page.dart';
import 'package:daidai_app/features/settings/views/more_page.dart';
import 'package:daidai_app/shared/models/user.dart';
import 'package:daidai_app/shared/widgets/main_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_http_adapter.dart';

User _user() => User(
  id: 1,
  username: 'tester',
  role: 'admin',
  enabled: true,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

/// 只数 getUser 被调了几次，不碰网络。
class _CountingAuthService extends AuthService {
  int getUserCalls = 0;

  @override
  Future<User> getUser() async {
    getUserCalls++;
    return _user();
  }
}

/// 可信期内恢复出来的登录态：已登录，但本地没存用户信息（user 为空）。
class _AuthedNoUser extends AuthNotifier {
  _AuthedNoUser(super.authService) {
    state = const AuthState(status: AuthStatus.authenticated);
  }
}

/// 「更多」页要一个已登录用户。
class _AuthedWithUser extends AuthNotifier {
  _AuthedWithUser(super.authService) {
    state = AuthState(status: AuthStatus.authenticated, user: _user());
  }
}

/// 有常驻转圈（开屏页、列表加载态）的页面不能 pumpAndSettle，按帧推进。
Future<void> _pumpFrames(WidgetTester tester, [int count = 20]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _closePage(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

/// 开屏页 + 主界面外壳（真 MainScaffold）+ 四个占位页：启动后落到哪一页一目了然。
Future<void> _boot(WidgetTester tester, _CountingAuthService service) async {
  final router = GoRouter(
    initialLocation: '/boot',
    routes: [
      GoRoute(path: '/boot', builder: (_, state) => const AppBootPage()),
      GoRoute(
        path: '/login',
        builder: (_, state) => const Scaffold(body: Text('登录页占位')),
      ),
      ShellRoute(
        builder: (_, state, child) => MainScaffold(child: child),
        routes: [
          for (final entry in const {
            '/dashboard': '主页占位',
            '/tasks': '任务占位',
            '/logs': '日志占位',
            '/envs': '变量占位',
            '/more': '更多占位',
          }.entries)
            GoRoute(
              path: entry.key,
              builder: (_, state) => Center(child: Text(entry.value)),
            ),
        ],
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authServiceProvider.overrideWithValue(service),
        authProvider.overrideWith((ref) => _AuthedNoUser(service)),
      ],
      child: MaterialApp.router(theme: AppTheme.light(), routerConfig: router),
    ),
  );
  await _pumpFrames(tester);
}

/// APP #24：默认打开页面（主页 / 任务 / 日志 / 变量），存本机、所有面板共用，没设过是主页。
void main() {
  var updateChecks = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'server_url': 'https://panel.test',
    });
    FlutterSecureStorage.setMockInitialValues({});
    DioClient.instance.setBaseUrl('https://panel.test');
    DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter(
      (_) => jsonResponse(<String, dynamic>{}, status: 404),
    );
    DefaultLandingPage.resetForTest();
    AppUpdateService.resetAutoCheckForTest();
    updateChecks = 0;
    AppUpdateService.checkOverrideForTest = () async {
      updateChecks++;
      return null;
    };
  });

  tearDown(() {
    AppUpdateService.checkOverrideForTest = null;
    DefaultLandingPage.resetForTest();
  });

  group('偏好读写', () {
    test('没设过：主页', () async {
      await DefaultLandingPage.load();
      expect(DefaultLandingPage.value, 'dashboard');
      expect(DefaultLandingPage.route, '/dashboard');
      expect(DefaultLandingPage.label, '主页');
    });

    test('存了不认识的值：回落主页', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        DefaultLandingPage.prefsKey: 'subscriptions',
      });
      await DefaultLandingPage.load();
      expect(DefaultLandingPage.route, '/dashboard');
    });

    test('保存：内存立刻生效，也落了盘（下次启动读回来）', () async {
      await DefaultLandingPage.save('logs');
      expect(DefaultLandingPage.route, '/logs');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(DefaultLandingPage.prefsKey), 'logs');

      DefaultLandingPage.resetForTest();
      await DefaultLandingPage.load();
      expect(DefaultLandingPage.route, '/logs');

      // 不认识的值直接忽略
      await DefaultLandingPage.save('nope');
      expect(DefaultLandingPage.route, '/logs');
    });
  });

  group('启动落点', () {
    testWidgets('没设过：落主页', (tester) async {
      await DefaultLandingPage.load();
      await _boot(tester, _CountingAuthService());
      expect(find.text('主页占位'), findsOneWidget);
      await _closePage(tester);
    });

    for (final (value, placeholder) in const [
      ('dashboard', '主页占位'),
      ('tasks', '任务占位'),
      ('logs', '日志占位'),
      ('envs', '变量占位'),
    ]) {
      testWidgets('设为 $value：落到 $placeholder', (tester) async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'server_url': 'https://panel.test',
          DefaultLandingPage.prefsKey: value,
        });
        await DefaultLandingPage.load();
        await _boot(tester, _CountingAuthService());
        expect(find.text(placeholder), findsOneWidget);
        await _closePage(tester);
      });
    }

    testWidgets('设为任务：启动后仍会补拉用户信息、仍会检查更新（原来挂在主页 initState 里）', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'server_url': 'https://panel.test',
        DefaultLandingPage.prefsKey: 'tasks',
      });
      await DefaultLandingPage.load();
      final service = _CountingAuthService();
      await _boot(tester, service);

      expect(find.text('任务占位'), findsOneWidget);
      expect(find.text('主页占位'), findsNothing);
      expect(service.getUserCalls, 1, reason: '「更多」页的管理员分区靠这份用户信息');
      expect(updateChecks, 1);

      // 切到其它标签再切回来：主界面外壳不重建，也不会再检查一次
      await tester.tap(find.text('日志'));
      await _pumpFrames(tester);
      await tester.tap(find.text('任务'));
      await _pumpFrames(tester);
      expect(updateChecks, 1);
      expect(service.getUserCalls, 1);

      await _closePage(tester);
    });

    testWidgets('真实路由的两处重定向（已登录进登录页 / 服务器配置页）也落到默认页', (tester) async {
      await DefaultLandingPage.save('logs');
      final service = _CountingAuthService();
      final container = ProviderContainer(
        overrides: [
          authServiceProvider.overrideWithValue(service),
          authProvider.overrideWith((ref) => _AuthedWithUser(service)),
        ],
      );
      addTearDown(container.dispose);
      final router = container.read(routerProvider);
      router.go('/login');

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await _pumpFrames(tester);
      expect(router.routerDelegate.currentConfiguration.uri.path, '/logs');

      await DefaultLandingPage.save('envs');
      router.go('/server-config');
      await _pumpFrames(tester);
      expect(router.routerDelegate.currentConfiguration.uri.path, '/envs');

      await _closePage(tester);
    });
  });

  group('「更多」页设置项', () {
    for (final textScale in [1.0, 1.3]) {
      testWidgets('360×800、字号 $textScale：不溢出，选「任务」后保存并显示', (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        tester.platformDispatcher.textScaleFactorTestValue = textScale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

        final router = GoRouter(
          routes: [GoRoute(path: '/', builder: (_, state) => const MorePage())],
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authProvider.overrideWith(
                (ref) => _AuthedWithUser(_CountingAuthService()),
              ),
            ],
            child: MaterialApp.router(
              theme: AppTheme.light(),
              routerConfig: router,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));

        // ListView 懒构建：这一项在屏幕外时还没建出来，要先滚过去
        final item = find.byKey(const Key('more-default-landing-page'));
        await tester.scrollUntilVisible(
          item,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(
          find.descendant(of: item, matching: find.text('主页')),
          findsOneWidget,
          reason: '没设过时显示主页',
        );

        await tester.tap(item);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('default-landing-dashboard')), findsOneWidget);
        expect(find.byKey(const Key('default-landing-envs')), findsOneWidget);
        // 四个选项都完整落在屏幕内
        for (final key in DefaultLandingPage.options.keys) {
          final rect = tester.getRect(find.byKey(Key('default-landing-$key')));
          expect(rect.bottom, lessThanOrEqualTo(800));
          expect(rect.right, lessThanOrEqualTo(360));
        }

        await tester.tap(find.byKey(const Key('default-landing-tasks')));
        await tester.pumpAndSettle();

        expect(DefaultLandingPage.route, '/tasks');
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(DefaultLandingPage.prefsKey), 'tasks');
        expect(
          find.descendant(of: item, matching: find.text('任务')),
          findsOneWidget,
        );

        await _closePage(tester);
      });
    }
  });
}
