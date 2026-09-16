import 'dart:async';

import 'package:daidai_app/core/auth/auth_provider.dart';
import 'package:daidai_app/core/auth/auth_service.dart';
import 'package:daidai_app/core/storage/secure_storage.dart';
import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/features/dashboard/providers/dashboard_provider.dart';
import 'package:daidai_app/features/login/views/app_boot_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 开屏页「卡住之后能自救」的回归保护（issue #7）。
///
/// v1.3.4 的开屏页只有一个转圈 + 一行文案，没有任何按钮，`_runBootFlow` 也没有
/// 任何时间上限：某一步不返回，用户除了杀进程或清空应用数据别无出路。
/// 这里守的不是「那个未复现的根因被修掉了」，而是：
/// 1. 任何一步卡住都会在有限时间内变成**可操作的失败态**，并说明卡在哪一步；
/// 2. 「重试」真的会重跑一遍（v1.3.4 的 `_jumping` 置真后不复位，重试是死的）；
/// 3. 仪表盘预加载不返回时，跳转不再被它拖住；
/// 4. 正常路径不会多出这一屏。
void main() {
  /// 用例里给的时限都是「秒」级但走的是假时钟：`tester.pump(Duration)` 直接把
  /// 时钟拨过去，不会真的等。取秒是为了让失败态文案与线上那句同形
  ///（`_formatLimit` 对不足 1 秒的时限会写成「N 毫秒」，并不会退化成「0 秒」）。
  const fastBoot = AppBootPage(
    localStepTimeout: Duration(seconds: 1),
    networkStepTimeout: Duration(seconds: 1),
    overallTimeout: Duration(seconds: 5),
  );

  /// 落一个当前面板，让启动流程能走到 checkInit / 自动登录。
  Future<void> seedPanel({required bool autoLogin}) async {
    SharedPreferences.setMockInitialValues({
      'server_url': 'https://panel.test',
    });
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStorage.savePanel(
      PanelConfig(
        url: 'https://panel.test',
        name: '测试面板',
        username: 'admin',
        password: 'pw',
        rememberPassword: autoLogin,
        autoLogin: autoLogin,
      ),
    );
  }

  /// 开屏页始终有 `CircularProgressIndicator` 在转，**不能用 `pumpAndSettle`**：
  /// 动画会一直调度新帧，pumpAndSettle 永远等不到「树静下来」，只会超时报错。
  /// 这里手动推几帧，把 SharedPreferences / 安全存储那几层异步读取推完。
  /// 总共只拨 200ms 假时钟，远小于用例给的 1 秒单步上限，
  /// 所以不会顺手把要测的超时也一起触发了。
  Future<void> pumpFrames(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> pumpBoot(
    WidgetTester tester,
    AuthService service, {
    void Function()? onDashboardLoad,
  }) async {
    final router = GoRouter(
      initialLocation: '/boot',
      routes: [
        GoRoute(path: '/boot', builder: (_, _) => fastBoot),
        GoRoute(
          path: '/login',
          builder: (_, _) =>
              const Scaffold(body: Center(child: Text('登录页占位'))),
        ),
        GoRoute(
          path: '/server-config',
          builder: (_, _) =>
              const Scaffold(body: Center(child: Text('服务器配置页占位'))),
        ),
        GoRoute(
          path: '/dashboard',
          builder: (_, _) =>
              const Scaffold(body: Center(child: Text('首页占位'))),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authServiceProvider.overrideWithValue(service),
          if (onDashboardLoad != null)
            dashboardProvider.overrideWith(
              (ref) => _HangingDashboardNotifier(onDashboardLoad),
            ),
        ],
        child: MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: router,
        ),
      ),
    );
  }

  testWidgets('某一步卡住：超时后进入失败态，说明卡在哪一步，四个出口都在', (tester) async {
    await seedPanel(autoLogin: false);
    final service = _FakeAuthService(hangCheckInitTimes: 99);

    await pumpBoot(tester, service);
    await pumpFrames(tester);

    // 先确认真的停在这一步，否则后面的断言可能是别的原因碰巧成立。
    expect(find.text('正在检查面板状态...'), findsOneWidget);
    expect(find.text('启动没能完成'), findsNothing);

    await tester.pump(const Duration(seconds: 2)); // 拨过 1 秒的单步上限
    await tester.pump();

    expect(find.text('启动没能完成'), findsOneWidget);
    expect(
      find.textContaining('检查面板状态'),
      findsOneWidget,
      reason: '用户回报 issue 时，「卡在哪一步」是唯一能带出来的线索',
    );
    // 四个出口。断言用 find.text 而不是 find.byType(OutlinedButton)：
    // OutlinedButton.icon 返回的是私有子类，byType 匹配不上，写了也是假断言。
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('返回登录'), findsOneWidget);
    expect(find.text('重新配置面板'), findsOneWidget);
    expect(find.text('清除本地会话'), findsOneWidget);
  });

  testWidgets('失败态点重试：启动流程真的重跑了一遍', (tester) async {
    await seedPanel(autoLogin: false);
    // 只卡第一次，重试那次立刻返回 —— 这样「重试有没有真的重跑」是可判定的。
    final service = _FakeAuthService(hangCheckInitTimes: 1);

    await pumpBoot(tester, service);
    await pumpFrames(tester);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(find.text('启动没能完成'), findsOneWidget);
    expect(service.checkInitCalls, 1);

    await tester.tap(find.text('重试'));
    await tester.pump();
    await pumpFrames(tester);

    expect(
      service.checkInitCalls,
      2,
      reason: '_jumping 那样置真不复位的话，这里会停在 1，重试按钮等于没接线',
    );
    expect(find.text('启动没能完成'), findsNothing);
    expect(find.text('登录页占位'), findsOneWidget);
  });

  testWidgets('仪表盘预加载不返回时，跳转不再被它拖住', (tester) async {
    await seedPanel(autoLogin: true);
    final service = _FakeAuthService(
      loginResult: {
        'access_token': 'token',
        'refresh_token': 'refresh',
        'user': {'id': 1, 'username': 'admin', 'role': 'admin'},
      },
    );
    var dashboardLoadCalls = 0;

    await pumpBoot(
      tester,
      service,
      onDashboardLoad: () => dashboardLoadCalls++,
    );
    await pumpFrames(tester);

    expect(
      find.text('首页占位'),
      findsOneWidget,
      reason: 'v1.3.4 在这里 await 预加载，预加载不返回就永远停在开屏页',
    );
    expect(
      dashboardLoadCalls,
      greaterThanOrEqualTo(1),
      reason: '预加载仍要在跳转前发出去，只是不再 await',
    );
    expect(service.loginCalls, 1, reason: '自动登录本身照走，不因为预加载改动而被跳过');
  });

  testWidgets('正常路径：不出现失败态，也不多一屏', (tester) async {
    await seedPanel(autoLogin: false);
    final service = _FakeAuthService();

    await pumpBoot(tester, service);
    await pumpFrames(tester);

    expect(find.text('登录页占位'), findsOneWidget);
    expect(find.text('启动没能完成'), findsNothing);
    expect(find.text('重试'), findsNothing);
    expect(find.text('清除本地会话'), findsNothing);
  });
}

/// 可控的 AuthService：checkInit 卡几次、登录返回什么，都由用例指定。
class _FakeAuthService extends AuthService {
  _FakeAuthService({this.hangCheckInitTimes = 0, this.loginResult});

  final int hangCheckInitTimes;
  final Map<String, dynamic>? loginResult;

  int checkInitCalls = 0;
  int loginCalls = 0;

  @override
  Future<bool> needsInitialization() {
    checkInitCalls++;
    if (checkInitCalls <= hangCheckInitTimes) {
      // 永不完成的 future 就是 issue #7 的形态：dio 的 connect/receive 超时
      // 只能兜住真正发出去的请求，兜不住「这一步压根没回调」。
      return Completer<bool>().future;
    }
    return Future.value(false);
  }

  @override
  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
    String? totpCode,
    Map<String, dynamic>? captcha,
  }) async {
    loginCalls++;
    return loginResult ?? <String, dynamic>{};
  }
}

/// `load()` 永不返回的仪表盘 provider。
///
/// 计数回调放在外面，是因为 `ref.invalidate(dashboardProvider)` 之后
/// override 会被重新调用，实例可能换掉，计数挂在实例上会丢。
class _HangingDashboardNotifier extends DashboardNotifier {
  _HangingDashboardNotifier(this.onLoad);

  final void Function() onLoad;

  @override
  Future<void> load() {
    onLoad();
    return Completer<void>().future;
  }
}
