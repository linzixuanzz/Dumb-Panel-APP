import 'package:daidai_app/core/auth/auth_provider.dart';
import 'package:daidai_app/core/auth/auth_service.dart';
import 'package:daidai_app/core/network/dio_client.dart';
import 'package:daidai_app/core/router/app_router.dart';
import 'package:daidai_app/core/router/default_landing_page.dart';
import 'package:daidai_app/core/services/app_update_service.dart';
import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/core/theme/design_tokens.dart';
import 'package:daidai_app/shared/models/user.dart';
import 'package:daidai_app/shared/widgets/main_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_http_adapter.dart';

User _user() => User(
  id: 1,
  username: 'tester',
  role: 'admin',
  enabled: true,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

class _FakeAuthService extends AuthService {
  @override
  Future<User> getUser() async => _user();
}

class _AuthedWithUser extends AuthNotifier {
  _AuthedWithUser(super.authService) {
    state = AuthState(status: AuthStatus.authenticated, user: _user());
  }
}

/// 有常驻转圈的页面不能 pumpAndSettle，按帧推进。
Future<void> _pumpFrames(WidgetTester tester, [int count = 20]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _closePage(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

/// 真 MainScaffold + 5 个占位 Tab，Tab 页面走线上同一个 tabPage 过渡。
Future<GoRouter> _pumpShell(
  WidgetTester tester, {
  bool reduceMotion = false,
  String initial = '/tasks',
}) async {
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      ShellRoute(
        builder: (_, state, child) => MainScaffold(child: child),
        routes: [
          for (final tab in mainTabs)
            GoRoute(
              path: tab.route,
              pageBuilder: (_, state) => tabPage(
                state,
                Builder(
                  builder: (context) {
                    // 在页面层（ListView 外面）读：ListView 不传 padding 时会把
                    // MediaQuery 的 padding 吃掉，里面再读就是 0。
                    final bottom = AppSpacing.listBottomOf(context);
                    return ListView(
                      padding: EdgeInsets.only(bottom: bottom),
                      children: [
                        Text('${tab.label}占位'),
                        // 把「列表底部留白」显示出来，供断言读取
                        Text('bottom=$bottom', key: Key('bottom-${tab.route}')),
                      ],
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    ],
  );
  final service = _FakeAuthService();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authServiceProvider.overrideWithValue(service),
        authProvider.overrideWith((ref) => _AuthedWithUser(service)),
      ],
      child: MaterialApp.router(
        theme: AppTheme.light(),
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reduceMotion),
          child: child!,
        ),
      ),
    ),
  );
  await _pumpFrames(tester);
  return router;
}

double _pillLeft(WidgetTester tester) =>
    tester.getTopLeft(find.byKey(const Key('main-tab-pill'))).dx;

void main() {
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
    AppUpdateService.checkOverrideForTest = () async => null;
  });

  tearDown(() {
    AppUpdateService.checkOverrideForTest = null;
    DefaultLandingPage.resetForTest();
  });

  testWidgets('底栏 5 个 Tab：任务 / 日志 / 概览 / 变量 / 设置，从左到右', (tester) async {
    await _pumpShell(tester);
    final labels = ['任务', '日志', '概览', '变量', '设置'];
    double? lastX;
    for (final label in labels) {
      final x = tester.getCenter(find.text(label)).dx;
      if (lastX != null) expect(x, greaterThan(lastX));
      lastX = x;
    }
    expect(find.text('主页'), findsNothing);
    expect(find.text('更多'), findsNothing);
    await _closePage(tester);
  });

  testWidgets('点 Tab 切页面；选中药丸弹簧滑过去（中途在半路，最后停在新 Tab 下）', (tester) async {
    final router = await _pumpShell(tester);
    final start = _pillLeft(tester);

    await tester.tap(find.text('概览'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final mid = _pillLeft(tester);
    await _pumpFrames(tester, 30);
    final end = _pillLeft(tester);

    expect(router.routerDelegate.currentConfiguration.uri.path, '/overview');
    expect(find.text('概览占位'), findsOneWidget);
    expect(mid, greaterThan(start));
    expect(mid, lessThan(end), reason: '有动画：60ms 时还在半路');
    // 药丸的中心与「概览」标签对齐
    expect(
      tester.getCenter(find.byKey(const Key('main-tab-pill'))).dx,
      moreOrLessEquals(tester.getCenter(find.text('概览')).dx, epsilon: 1),
    );
    await _closePage(tester);
  });

  testWidgets('切 Tab：新页淡入（第一帧不是完全不透明）', (tester) async {
    await _pumpShell(tester);
    await tester.tap(find.text('日志'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final fades = tester.widgetList<FadeTransition>(
      find.ancestor(
        of: find.text('日志占位'),
        matching: find.byType(FadeTransition),
      ),
    );
    expect(fades.any((f) => f.opacity.value < 1), isTrue);
    await _pumpFrames(tester);
    await _closePage(tester);
  });

  testWidgets('系统「移除动画」：药丸直接跳到位、页面不做淡入', (tester) async {
    await _pumpShell(tester, reduceMotion: true);
    await tester.tap(find.text('变量'));
    await tester.pump();
    await tester.pump();
    expect(
      tester.getCenter(find.byKey(const Key('main-tab-pill'))).dx,
      moreOrLessEquals(tester.getCenter(find.text('变量')).dx, epsilon: 1),
    );
    final fades = tester.widgetList<FadeTransition>(
      find.ancestor(
        of: find.text('变量占位'),
        matching: find.byType(FadeTransition),
      ),
    );
    expect(fades.every((f) => f.opacity.value == 1), isTrue);
    await _closePage(tester);
  });

  testWidgets('底栏不盖住内容：Tab 页读到的列表底部留白 > 底栏高度', (tester) async {
    await _pumpShell(tester);
    final text = tester.widget<Text>(find.byKey(const Key('bottom-/tasks')));
    final bottom = double.parse(text.data!.split('=').last);
    expect(
      bottom,
      greaterThanOrEqualTo(
        AppTabBarMetrics.height + AppTabBarMetrics.bottomGap + AppSpacing.lg,
      ),
    );
    await _closePage(tester);
  });

  testWidgets('真实路由：旧的 /dashboard、/more 重定向到 /overview、/settings', (
    tester,
  ) async {
    // 这里给 200 空对象而不是 404：v1.x 主页的 DashboardNotifier.load 在第一个请求
    // 失败时，第二个并发请求的失败没人接（既有问题，第二波 B4 重写概览时一并处理），
    // 会在测试里冒成未捕获异常。本用例只验证路由，不关心页面数据。
    DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter(
      (_) => jsonResponse(<String, dynamic>{}),
    );
    final service = _FakeAuthService();
    final container = ProviderContainer(
      overrides: [
        authServiceProvider.overrideWithValue(service),
        authProvider.overrideWith((ref) => _AuthedWithUser(service)),
      ],
    );
    addTearDown(container.dispose);
    final router = container.read(routerProvider);
    router.go('/dashboard');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: router,
        ),
      ),
    );
    await _pumpFrames(tester);
    expect(router.routerDelegate.currentConfiguration.uri.path, '/overview');

    router.go('/more');
    await _pumpFrames(tester);
    expect(router.routerDelegate.currentConfiguration.uri.path, '/settings');

    // 新的 Tab 路由都能直接进
    for (final tab in mainTabs) {
      router.go(tab.route);
      await _pumpFrames(tester);
      expect(router.routerDelegate.currentConfiguration.uri.path, tab.route);
    }
    await _closePage(tester);
  });
}
