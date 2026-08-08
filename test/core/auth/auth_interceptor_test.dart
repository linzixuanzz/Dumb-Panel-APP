import 'dart:async';

import 'package:daidai_app/core/auth/auth_interceptor.dart';
import 'package:daidai_app/core/auth/token_refresher.dart';
import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/storage/secure_storage.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_http_adapter.dart';

/// 401 续期链路的回归保护。
///
/// 这段代码在收紧 `validateStatus` 之前**一次都没有执行过**（401 被 dio 当成成功响应），
/// 激活时才发现里面有真 bug。它同时是「改错了用户会直接掉登录态」的地方，
/// 所以这里是全仓库优先级最高的一组用例。
void main() {
  const tasksPath = ApiEndpoints.tasks;
  const logsPath = ApiEndpoints.logs;
  const refreshPath = ApiEndpoints.refresh;
  const loginPath = ApiEndpoints.login;

  late int authFailedCalls;

  setUp(() {
    // flutter_secure_storage 自带的内存实现，不需要额外依赖，也不需要 mock 平台通道。
    FlutterSecureStorage.setMockInitialValues({
      'access_token': 'access-old',
      'refresh_token': 'refresh-1',
    });
    // 续期动作已经收敛到 TokenRefresher 单例（SSE 也调它）。
    // 单例状态会跨用例串场，不重置的话上一条用例的假 dio 会被下一条复用。
    TokenRefresher.instance.resetForTest();
    authFailedCalls = 0;
  });

  Dio buildApiDio(FakeHttpAdapter apiAdapter, FakeHttpAdapter refreshAdapter) {
    final api = dioWithAdapter(apiAdapter);
    final refresh = dioWithAdapter(refreshAdapter);
    api.interceptors.add(
      AuthInterceptor(
        dio: api,
        rawDioFactory: () => refresh,
        onAuthFailed: () => authFailedCalls++,
      ),
    );
    return api;
  }

  test('续期成功：401 → 换新 access token → 重发原请求 → 拿到数据', () async {
    final apiAdapter = FakeHttpAdapter((options) {
      if (options.headers['Authorization'] == 'Bearer access-new') {
        return jsonResponse({
          'data': [
            {'id': 1, 'name': '任务一'},
          ],
          'total': 1,
        });
      }
      return jsonResponse({'error': 'token 已过期'}, status: 401);
    });
    final refreshAdapter = FakeHttpAdapter(
      (_) => jsonResponse({'access_token': 'access-new'}),
    );
    final api = buildApiDio(apiAdapter, refreshAdapter);

    final response = await api
        .get(tasksPath)
        .timeout(const Duration(seconds: 10));

    expect(response.statusCode, 200);
    expect((response.data as Map)['total'], 1);
    expect(
      await SecureStorage.getAccessToken(),
      'access-new',
      reason: '新 token 必须落盘，否则下一个请求又是 401',
    );
    expect(authFailedCalls, 0, reason: '续期成功不该把用户踢去登录页');
    expect(apiAdapter.countOf(tasksPath), 2, reason: '原请求 + 重发各一次');
    expect(refreshAdapter.countOf(refreshPath), 1);
    expect(apiAdapter.requests.first.authorization, 'Bearer access-old');
    expect(apiAdapter.requests.last.authorization, 'Bearer access-new');
    expect(
      refreshAdapter.requests.single.authorization,
      'Bearer refresh-1',
      reason: '刷新接口要带的是 refresh token，不是过期的 access token',
    );
  });

  test('续期失败：清本地会话 + 回调 onAuthFailed + 把原始异常抛回调用方', () async {
    final apiAdapter = FakeHttpAdapter(
      (_) => jsonResponse({'error': 'token 已过期'}, status: 401),
    );
    final refreshAdapter = FakeHttpAdapter(
      (_) => jsonResponse({'error': 'refresh token 也过期了'}, status: 401),
    );
    final api = buildApiDio(apiAdapter, refreshAdapter);

    await expectLater(
      api.get(tasksPath).timeout(const Duration(seconds: 10)),
      throwsA(
        isA<DioException>()
            .having((e) => e.response?.statusCode, 'statusCode', 401)
            .having(
              (e) => (e.response?.data as Map)['error'],
              'error',
              // 抛回调用方的必须是**原始**异常，不是刷新接口那条，
              // 否则页面上会出现「refresh token 也过期了」这种用户看不懂的文案。
              'token 已过期',
            ),
      ),
    );

    expect(authFailedCalls, 1);
    expect(await SecureStorage.getAccessToken(), isNull);
    expect(await SecureStorage.getRefreshToken(), isNull);
    expect(apiAdapter.countOf(tasksPath), 1, reason: '刷新都失败了就不该再重发');
  });

  test('重发后又 401：直接失败，不能再排队（防的是 await 自己等自己的死锁）', () async {
    // 突变验证锚点：删掉 auth_interceptor.dart 里 `_kRetriedAfterRefresh` 的判断，
    // 重发请求会带着 _isRefreshing == true 把自己排进 _pendingRequests，
    // 于是 `await _retry(...)` 永远等不到 resolve，整条请求永久挂起。
    // 那种情况下下面的 timeout 会先炸，这条用例必须红。
    final apiAdapter = FakeHttpAdapter(
      (_) => jsonResponse({'error': 'token 已过期'}, status: 401),
    );
    final refreshAdapter = FakeHttpAdapter(
      (_) => jsonResponse({'access_token': 'access-new'}),
    );
    final api = buildApiDio(apiAdapter, refreshAdapter);

    await expectLater(
      api.get(tasksPath).timeout(const Duration(seconds: 5)),
      throwsA(isA<DioException>()),
    );

    expect(apiAdapter.countOf(tasksPath), 2, reason: '原请求 + 一次重发，不能有第三次');
    expect(refreshAdapter.countOf(refreshPath), 1, reason: '不能反复续期');
    expect(authFailedCalls, greaterThanOrEqualTo(1), reason: '会话确实死了，要跳登录页');
  });

  test('并发排队：续期期间的其它请求排队，续期成功后被重发', () async {
    final releaseRefresh = Completer<void>();
    final apiAdapter = FakeHttpAdapter((options) {
      if (options.headers['Authorization'] == 'Bearer access-new') {
        return jsonResponse({'data': const [], 'total': 0});
      }
      return jsonResponse({'error': 'token 已过期'}, status: 401);
    });
    final refreshAdapter = FakeHttpAdapter((_) async {
      await releaseRefresh.future;
      return jsonResponse({'access_token': 'access-new'});
    });
    final api = buildApiDio(apiAdapter, refreshAdapter);

    final first = api.get(tasksPath);
    final second = api.get(logsPath);
    // 卡住刷新接口，确保两条请求都吃到 401：一条去续期，另一条只能排队。
    await Future<void>.delayed(const Duration(milliseconds: 100));
    releaseRefresh.complete();

    final responses = await Future.wait([
      first,
      second,
    ]).timeout(const Duration(seconds: 10));

    expect(responses.map((r) => r.statusCode), everyElement(200));
    expect(refreshAdapter.countOf(refreshPath), 1, reason: '并发 401 只能续期一次');
    expect(apiAdapter.countOf(tasksPath), 2);
    expect(apiAdapter.countOf(logsPath), 2, reason: '排队的请求必须被重发');
  });

  test('续期失败时排队的请求被显式拒绝，不会让调用方的 await 永久悬着', () async {
    // 突变验证锚点：把 auth_interceptor.dart 里的 `_rejectPending(...)` 换成
    // `_pendingRequests.clear()`，排队请求的 handler 就被直接丢弃，
    // 第二条请求的 Future 永远不完成，下面的 timeout 会炸。
    final releaseRefresh = Completer<void>();
    final apiAdapter = FakeHttpAdapter(
      (_) => jsonResponse({'error': 'token 已过期'}, status: 401),
    );
    final refreshAdapter = FakeHttpAdapter((_) async {
      await releaseRefresh.future;
      return jsonResponse({'error': 'refresh token 也过期了'}, status: 401);
    });
    final api = buildApiDio(apiAdapter, refreshAdapter);

    // 立刻挂上错误处理，避免先失败的那条变成未被监听的异步异常。
    final first = api.get(tasksPath).then<Object?>(
      (r) => r,
      onError: (Object error) => error,
    );
    final second = api.get(logsPath).then<Object?>(
      (r) => r,
      onError: (Object error) => error,
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    releaseRefresh.complete();

    final results = await Future.wait([
      first,
      second,
    ]).timeout(const Duration(seconds: 5));

    expect(results[0], isA<DioException>(), reason: '发起续期的那条要拿到原始 401');
    expect(results[1], isA<DioException>(), reason: '排队的那条必须被拒绝，不能悬着');
  });

  test('login 的 401 不触发续期：一次密码输错不能清掉已有会话', () async {
    final apiAdapter = FakeHttpAdapter(
      (_) => jsonResponse({'error': '用户名或密码错误'}, status: 401),
    );
    final refreshAdapter = FakeHttpAdapter(
      (_) => jsonResponse({'access_token': 'access-new'}),
    );
    final api = buildApiDio(apiAdapter, refreshAdapter);

    await expectLater(
      api
          .post(loginPath, data: {'username': 'admin', 'password': 'wrong'})
          .timeout(const Duration(seconds: 10)),
      throwsA(isA<DioException>()),
    );

    expect(refreshAdapter.requests, isEmpty, reason: 'login 不在续期范围内');
    expect(apiAdapter.countOf(loginPath), 1);
    expect(await SecureStorage.getAccessToken(), 'access-old');
    expect(await SecureStorage.getRefreshToken(), 'refresh-1');
    expect(authFailedCalls, 0);
  });

  test('没有 refresh token 时不发刷新请求，直接判定会话失效', () async {
    FlutterSecureStorage.setMockInitialValues({'access_token': 'access-old'});

    final apiAdapter = FakeHttpAdapter(
      (_) => jsonResponse({'error': 'token 已过期'}, status: 401),
    );
    final refreshAdapter = FakeHttpAdapter(
      (_) => jsonResponse({'access_token': 'access-new'}),
    );
    final api = buildApiDio(apiAdapter, refreshAdapter);

    await expectLater(
      api.get(tasksPath).timeout(const Duration(seconds: 10)),
      throwsA(isA<DioException>()),
    );

    expect(refreshAdapter.requests, isEmpty);
    expect(authFailedCalls, 1);
    expect(await SecureStorage.getAccessToken(), isNull);
  });

  test('非 401 的错误原样放行，不碰会话', () async {
    final apiAdapter = FakeHttpAdapter(
      (_) => jsonResponse({'error': '服务器内部错误'}, status: 500),
    );
    final refreshAdapter = FakeHttpAdapter(
      (_) => jsonResponse({'access_token': 'access-new'}),
    );
    final api = buildApiDio(apiAdapter, refreshAdapter);

    await expectLater(
      api.get(tasksPath).timeout(const Duration(seconds: 10)),
      throwsA(
        isA<DioException>().having(
          (e) => e.response?.statusCode,
          'statusCode',
          500,
        ),
      ),
    );

    expect(refreshAdapter.requests, isEmpty);
    expect(authFailedCalls, 0);
    expect(await SecureStorage.getAccessToken(), 'access-old');
  });
}
