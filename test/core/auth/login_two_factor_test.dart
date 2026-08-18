import 'package:daidai_app/core/auth/auth_service.dart';
import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/network/dio_client.dart';
import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/features/login/views/login_page.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_http_adapter.dart';

/// 「开了两步验证的账号在 APP 上永远登不进去」的回归保护。
///
/// 回归点是 v1.2.3：DioClient 的全局 `validateStatus` 收紧到 < 400 之后，
/// 服务端为两步验证返回的 **401 + two_factor_required** 在 `AuthService.login()` 里
/// 就地抛成了 DioException，下面解析响应体、return map 的代码一行都没执行；
/// login_page 里 `_needsTotp = true` 这条唯一的赋值随之变成死代码，
/// TOTP 输入框永远不渲染。用户看到的是红字「请输入两步验证码」+ 没地方输。
/// 验证码分支（captcha_required）死于同一根因。
///
/// 这里**不能**靠放宽全局 validateStatus 来修：那行是为了让 401 进 AuthInterceptor
/// 做 token 续期才特意收紧的，改回去等于把续期逻辑重新打回死代码。
/// 所以 login() 用的是请求级放宽 + 自己区分两类 4xx，本文件守的就是这个区分。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const loginPath = ApiEndpoints.login;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    // AuthService 拿的是 DioClient 单例，直接给单例换假适配器：
    // validateStatus / 拦截器 / transformer 全是线上那一套，只有网络是假的。
    DioClient.instance.setBaseUrl('https://panel.test');
  });

  test('401 + two_factor_required：返回 map 而不是抛异常（TOTP 输入框的前提）', () async {
    final adapter = FakeHttpAdapter(
      (_) => jsonResponse({
        'error': '请输入两步验证码',
        'two_factor_required': true,
      }, status: 401),
    );
    DioClient.instance.dio.httpClientAdapter = adapter;

    final result = await AuthService()
        .login(username: 'admin', password: 'right-password')
        .timeout(const Duration(seconds: 10));

    expect(
      result['two_factor_required'],
      isTrue,
      reason: '这个标记要原样交给 login_page，它据此渲染 TOTP 输入框',
    );
    expect(result['error'], '请输入两步验证码');
    expect(result.containsKey('access_token'), isFalse);
    expect(adapter.countOf(loginPath), 1);
  });

  test('401 + captcha_required：同样返回 map，滑块才能被重新拉起', () async {
    final adapter = FakeHttpAdapter(
      (_) => jsonResponse({
        'error': '验证码校验失败，请重新完成人机验证',
        'captcha_required': true,
        'captcha_invalid': true,
        'captcha_id': 'captcha-id',
      }, status: 401),
    );
    DioClient.instance.dio.httpClientAdapter = adapter;

    final result = await AuthService()
        .login(username: 'admin', password: 'right-password')
        .timeout(const Duration(seconds: 10));

    expect(result['captcha_required'], isTrue);
    expect(result['error'], '验证码校验失败，请重新完成人机验证');
    expect(result['captcha_id'], 'captcha-id');
  });

  test('401 + 纯 error（密码错误）仍然抛 DioException，且带得出后端文案', () async {
    // 突变验证锚点：把 login() 里 `statusCode >= 400 && !needsExtraStep` 的抛异常分支删掉，
    // 密码输错会被当成登录成功往下走，页面直接跳 dashboard 而不是提示错误，这条必须红。
    final adapter = FakeHttpAdapter(
      (_) => jsonResponse({
        'error': '用户名或密码错误',
        'failed_attempts': 3,
        // 未开启验证码时服务端带的是 false，不能被当成「还差一步」放行。
        'captcha_required': false,
      }, status: 401),
    );
    DioClient.instance.dio.httpClientAdapter = adapter;

    await expectLater(
      AuthService()
          .login(username: 'admin', password: 'wrong')
          .timeout(const Duration(seconds: 10)),
      throwsA(
        isA<DioException>()
            .having((e) => e.response?.statusCode, 'statusCode', 401)
            .having(
              // auth_provider._extractErrorMessage 就是从这里取文案的，
              // response 丢了的话页面只会显示「网络错误，请检查连接」。
              (e) => (e.response?.data as Map)['error'],
              'error',
              '用户名或密码错误',
            ),
      ),
    );
  });

  test('5xx 不受请求级放宽影响，照旧抛异常', () async {
    final adapter = FakeHttpAdapter(
      (_) => jsonResponse({
        'error': '验证码服务暂时不可用，请稍后重试',
        // 503 也会带 captcha_required，但它不该被当成「还差一步」返回。
        'captcha_required': true,
      }, status: 503),
    );
    DioClient.instance.dio.httpClientAdapter = adapter;

    await expectLater(
      AuthService()
          .login(username: 'admin', password: 'right-password')
          .timeout(const Duration(seconds: 10)),
      throwsA(
        isA<DioException>().having(
          (e) => e.response?.statusCode,
          'statusCode',
          503,
        ),
      ),
    );
  });

  testWidgets('登录页拿到 two_factor_required 后真的把 TOTP 输入框渲染出来', (tester) async {
    SharedPreferences.setMockInitialValues({'server_url': 'https://panel.test'});
    final adapter = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.checkInit) {
        return jsonResponse({'need_init': false});
      }
      if (options.path == ApiEndpoints.captchaConfig) {
        // 老面板没有这条路由，返回 404 走「没配验证码」分支。
        return jsonResponse({'error': 'not found'}, status: 404);
      }
      if (options.path == loginPath) {
        return jsonResponse({
          'error': '请输入两步验证码',
          'two_factor_required': true,
        }, status: 401);
      }
      return jsonResponse({'error': 'unexpected'}, status: 404);
    });
    DioClient.instance.dio.httpClientAdapter = adapter;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(theme: AppTheme.light(), home: const LoginPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('两步验证码'), findsNothing, reason: '没提交过登录时不该有这个框');

    await tester.enterText(find.byType(TextFormField).at(0), 'admin');
    await tester.enterText(find.byType(TextFormField).at(1), 'right-password');
    await tester.tap(find.text('连接并登录'));
    await tester.pumpAndSettle();

    expect(find.text('两步验证码'), findsOneWidget, reason: '这就是用户「看得见红字却没处输」的那个框');
    expect(find.text('6位数字验证码'), findsOneWidget);
    expect(find.text('请输入两步验证码'), findsOneWidget, reason: '后端文案要照常显示');
  });
}
