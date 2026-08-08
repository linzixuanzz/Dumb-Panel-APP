import 'dart:async';

import 'package:daidai_app/core/auth/auth_interceptor.dart';
import 'package:daidai_app/core/auth/token_refresher.dart';
import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/network/dio_client.dart';
import 'package:daidai_app/core/network/sse_client.dart';
import 'package:daidai_app/core/storage/secure_storage.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_http_adapter.dart';
import '../../support/fake_sse_http_client.dart';

/// TokenRefresher 存在的唯一理由是「同一时刻只有一次续期在飞」。
/// 这组用例就是钉这一条：dio 与 SSE 是两条独立链路，
/// 一旦各刷各的，后返回的那次会把先返回的新 token 覆盖成已经作废的值。
void main() {
  const refreshPath = ApiEndpoints.refresh;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({
      'access_token': 'access-old',
      'refresh_token': 'refresh-1',
    });
    // 单例状态会串场：不重置的话上一条用例的假 dio 会被下一条复用。
    TokenRefresher.instance.resetForTest();
    DioClient.instance.setBaseUrl('https://panel.test');
  });

  test('并发调用只打一次刷新接口，两个调用方拿到同一个新 token', () async {
    final releaseRefresh = Completer<void>();
    final refreshAdapter = FakeHttpAdapter((_) async {
      await releaseRefresh.future;
      return jsonResponse({'access_token': 'access-new'});
    });
    final refreshDio = dioWithAdapter(refreshAdapter);

    final first = TokenRefresher.instance.refresh(
      rawDioFactory: () => refreshDio,
    );
    final second = TokenRefresher.instance.refresh(
      rawDioFactory: () => refreshDio,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    releaseRefresh.complete();

    final tokens = await Future.wait([
      first,
      second,
    ]).timeout(const Duration(seconds: 5));

    expect(tokens, ['access-new', 'access-new']);
    expect(refreshAdapter.countOf(refreshPath), 1);
  });

  test('dio 与 SSE 同时 401：共用同一次续期，刷新接口只被打一次', () async {
    // 突变验证锚点：把 SseClient 或 AuthInterceptor 里的续期改回各写一份，
    // 刷新次数会变成 2，这条用例必须红。
    final releaseRefresh = Completer<void>();
    final refreshAdapter = FakeHttpAdapter((_) async {
      await releaseRefresh.future;
      return jsonResponse({'access_token': 'access-new'});
    });
    final refreshDio = dioWithAdapter(refreshAdapter);

    final apiAdapter = FakeHttpAdapter((options) {
      if (options.headers['Authorization'] == 'Bearer access-new') {
        return jsonResponse({'data': const [], 'total': 0});
      }
      return jsonResponse({'error': 'token 已过期'}, status: 401);
    });
    final api = dioWithAdapter(apiAdapter);
    api.interceptors.add(
      AuthInterceptor(dio: api, rawDioFactory: () => refreshDio),
    );

    final sseHttp = FakeSseHttpClient((request) {
      if (request.headers['Authorization'] == 'Bearer access-new') {
        return sseResponse('data: 日志一行\n\nevent: done\ndata: finished\n\n');
      }
      return emptyResponse(401);
    });
    final sse = SseClient(
      httpClientFactory: () => sseHttp,
      rawDioFactory: () => refreshDio,
    );

    final events = <SseEvent>[];
    final restCall = api.get(ApiEndpoints.tasks);
    final sseCall = sse.connect(
      path: ApiEndpoints.logStream(1),
      onEvent: events.add,
    );

    // 卡住刷新接口，确保两条链路都已经吃到 401 并进入续期。
    await Future<void>.delayed(const Duration(milliseconds: 100));
    releaseRefresh.complete();

    final restResponse = await restCall.timeout(const Duration(seconds: 5));
    await sseCall.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(
      refreshAdapter.countOf(refreshPath),
      1,
      reason: '两条链路各刷一次的话，后一个会把前一个的新 token 覆盖成过期值',
    );
    expect(restResponse.statusCode, 200);
    expect(sseHttp.requests.last.authorization, 'Bearer access-new');
    expect(events.map((e) => e.data), contains('日志一行'));
    expect(await SecureStorage.getAccessToken(), 'access-new');
  });

  test('刷新失败不会被钉死：下一次仍然会重新发起', () async {
    // 突变验证锚点：把 _joinOrStart 里的 whenComplete 换成 then，
    // 失败的 Future 会一直留在 _inFlight 里，第二次调用直接复用旧失败，
    // 刷新次数会停在 1，这条用例必须红。
    var attempt = 0;
    final refreshAdapter = FakeHttpAdapter((_) {
      attempt++;
      if (attempt == 1) {
        return jsonResponse({'error': 'refresh 也过期了'}, status: 401);
      }
      return jsonResponse({'access_token': 'access-new'});
    });
    final refreshDio = dioWithAdapter(refreshAdapter);

    await expectLater(
      TokenRefresher.instance.refresh(rawDioFactory: () => refreshDio),
      throwsA(anything),
    );

    final token = await TokenRefresher.instance
        .refresh(rawDioFactory: () => refreshDio)
        .timeout(const Duration(seconds: 5));

    expect(token, 'access-new');
    expect(refreshAdapter.countOf(refreshPath), 2);
  });

  test('本地 token 已被别的链路换掉：直接复用，不再打刷新接口', () async {
    await SecureStorage.saveAccessToken('access-new');

    final refreshAdapter = FakeHttpAdapter(
      (_) => jsonResponse({'access_token': 'access-newer'}),
    );

    final token = await TokenRefresher.instance.refresh(
      staleToken: 'access-old',
      rawDioFactory: () => dioWithAdapter(refreshAdapter),
    );

    expect(token, 'access-new');
    expect(refreshAdapter.requests, isEmpty, reason: '别人刚续过期，没必要再刷一次');
  });

  test('没有 refresh token 时直接失败，不发请求', () async {
    FlutterSecureStorage.setMockInitialValues({'access_token': 'access-old'});
    final refreshAdapter = FakeHttpAdapter(
      (_) => jsonResponse({'access_token': 'access-new'}),
    );

    await expectLater(
      TokenRefresher.instance.refresh(
        rawDioFactory: () => dioWithAdapter(refreshAdapter),
      ),
      throwsA(isA<StateError>()),
    );
    expect(refreshAdapter.requests, isEmpty);
  });

  test('notifySessionExpired：清本地会话并通知上层跳登录页', () async {
    var expiredCalls = 0;
    TokenRefresher.instance.onSessionExpired = () => expiredCalls++;

    await TokenRefresher.instance.notifySessionExpired();

    expect(expiredCalls, 1);
    expect(await SecureStorage.getAccessToken(), isNull);
    expect(await SecureStorage.getRefreshToken(), isNull);
  });
}
