import 'dart:async';

import 'package:daidai_app/core/auth/token_refresher.dart';
import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/network/dio_client.dart';
import 'package:daidai_app/core/network/sse_client.dart';
import 'package:daidai_app/core/storage/secure_storage.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_http_adapter.dart';
import '../../support/fake_sse_http_client.dart';

/// SSE 走 `package:http`，**完全不经过 dio 与 AuthInterceptor**。
/// 改造前这里的 401 只会弹一句「认证失败」，不续期 ——
/// 而「开着实时日志看任务跑半小时」正是 access token 过期的高发场景。
///
/// 这组用例钉的是：401 → 续期 → 带新 token 重连 → 用户无感；
/// 以及「不能无限重试」和「额度要还」这两条边界。
void main() {
  const streamPath = '/api/v1/logs/1/stream';
  const refreshPath = ApiEndpoints.refresh;

  late int sessionExpiredCalls;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({
      'access_token': 'access-old',
      'refresh_token': 'refresh-1',
    });
    TokenRefresher.instance.resetForTest();
    DioClient.instance.setBaseUrl('https://panel.test');
    sessionExpiredCalls = 0;
    TokenRefresher.instance.onSessionExpired = () => sessionExpiredCalls++;
  });

  tearDown(() => TokenRefresher.instance.resetForTest());

  test('401 → 续期 → 带新 token 重连 → 事件照常送达，页面看不到任何错误', () async {
    final refreshAdapter = FakeHttpAdapter(
      (_) => jsonResponse({'access_token': 'access-new'}),
    );
    final httpClient = FakeSseHttpClient((request) {
      if (request.headers['Authorization'] == 'Bearer access-new') {
        return sseResponse('data: 第一行\n\nevent: done\ndata: finished\n\n');
      }
      return emptyResponse(401);
    });

    final client = SseClient(
      httpClientFactory: () => httpClient,
      rawDioFactory: () => dioWithAdapter(refreshAdapter),
    );

    final events = <SseEvent>[];
    final errors = <dynamic>[];
    var reconnects = 0;

    await client.connect(
      path: streamPath,
      onEvent: events.add,
      onError: errors.add,
      onReconnect: () => reconnects++,
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(httpClient.requests.length, 2, reason: '原连接 + 续期后重连各一次');
    expect(httpClient.requests.first.authorization, 'Bearer access-old');
    expect(httpClient.requests.last.authorization, 'Bearer access-new');
    expect(refreshAdapter.countOf(refreshPath), 1);
    expect(await SecureStorage.getAccessToken(), 'access-new');
    expect(events.map((e) => e.data), containsAll(<String>['第一行', 'finished']));
    expect(errors, isEmpty, reason: '续期成功就该是无感的，页面不该收到任何错误');
    expect(sessionExpiredCalls, 0, reason: '续期成功不能把用户踢去登录页');
    expect(
      reconnects,
      1,
      reason: '服务端会重放整段历史，页面必须收到 onReconnect 才能去重',
    );

    client.close();
  });

  test('重连后又 401：不再续期，抛 SseAuthFailure 并清会话', () async {
    // 突变验证锚点：删掉 sse_client.dart 里 `_refreshRetryUsed` 的判断，
    // 就会变成 401 → 续期 → 401 → 续期的无限循环，
    // 下面的「刷新只有一次、连接只有两次」会同时红。
    final refreshAdapter = FakeHttpAdapter(
      (_) => jsonResponse({'access_token': 'access-new'}),
    );
    final httpClient = FakeSseHttpClient((_) => emptyResponse(401));

    final client = SseClient(
      httpClientFactory: () => httpClient,
      rawDioFactory: () => dioWithAdapter(refreshAdapter),
    );

    final errors = <dynamic>[];
    await client.connect(
      path: streamPath,
      onEvent: (_) {},
      onError: errors.add,
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(refreshAdapter.countOf(refreshPath), 1, reason: '不能反复续期');
    expect(httpClient.requests.length, 2, reason: '原连接 + 一次重连，不能有第三次');
    expect(errors.single, isA<SseAuthFailure>());
    expect(sessionExpiredCalls, 1, reason: '会话确实死了，要走和 REST 一样的跳登录页');
    expect(await SecureStorage.getAccessToken(), isNull);
    expect(await SecureStorage.getRefreshToken(), isNull);

    client.close();
  });

  test('refresh token 也过期：不重连，直接判会话失效', () async {
    final refreshAdapter = FakeHttpAdapter(
      (_) => jsonResponse({'error': 'refresh token 也过期了'}, status: 401),
    );
    final httpClient = FakeSseHttpClient((_) => emptyResponse(401));

    final client = SseClient(
      httpClientFactory: () => httpClient,
      rawDioFactory: () => dioWithAdapter(refreshAdapter),
    );

    final errors = <dynamic>[];
    await client.connect(
      path: streamPath,
      onEvent: (_) {},
      onError: errors.add,
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(httpClient.requests.length, 1, reason: '续期都失败了就不该再连');
    expect(errors.single, isA<SseAuthFailure>());
    expect(sessionExpiredCalls, 1);
    expect(await SecureStorage.getAccessToken(), isNull);

    client.close();
  });

  test('一次成功连接之后续期额度归还：第二次过期还能再续一次', () async {
    // 这条钉的是「用户挂着日志看两小时」的场景：
    // 长连接会反复重连（服务端 done:reconnect / 超时），
    // 额度不还的话一次会话只允许续期一次，第二次过期就直接掉线。
    var refreshCount = 0;
    final refreshAdapter = FakeHttpAdapter((_) {
      refreshCount++;
      return jsonResponse({'access_token': 'access-$refreshCount'});
    });

    // ⚠️ 这个假 client 必须按**第几次连接**回，不能按 token 回。
    // 本场景里第 1、2 次连接带的是同一个 access-old（1s 后重连时本地 token
    // 还没换），但要求的响应不同：第 1 次 200 + done:reconnect，第 2 次才 401。
    // 按 token 分支的话第 2 次会拿到和第 1 次一样的 done:reconnect，
    // 于是每秒重连一次、永远等不到 401，一次续期都不会发生。
    const reconnectFrame = 'event: done\ndata: reconnect\n\n';
    var connectCount = 0;
    final httpClient = FakeSseHttpClient((_) {
      connectCount++;
      switch (connectCount) {
        case 1: // access-old 连上，服务端要求重连
        case 3: // 第一次续期后连上，服务端再次要求重连
          return sseResponse(reconnectFrame);
        case 2: // 重连时 access-old 已过期
        case 4: // 重连时 access-1 也过期了 —— 全靠额度归还才能再续一次
          return emptyResponse(401);
        default:
          return sseResponse('data: 第二次续期后的日志\n\n');
      }
    });

    final client = SseClient(
      httpClientFactory: () => httpClient,
      rawDioFactory: () => dioWithAdapter(refreshAdapter),
    );

    final events = <SseEvent>[];
    final errors = <dynamic>[];
    await client.connect(
      path: streamPath,
      autoReconnect: true,
      onEvent: events.add,
      onError: errors.add,
    );
    // done:reconnect 的重连固定延迟 1s，这里要跨过两轮。
    await Future<void>.delayed(const Duration(milliseconds: 3000));

    expect(refreshCount, 2, reason: '两次过期就该续两次，不能只允许一次');
    expect(refreshAdapter.countOf(refreshPath), 2);
    // 这条列表才是「额度确实归还了」的证据：删掉 sse_client.dart 里
    // 那句 `_refreshRetryUsed = false`，第 4 次连接的 401 会直接判会话失效，
    // 列表只剩 4 条、最后一条是 access-1，且 errors 里会多出一个 SseAuthFailure。
    expect(
      httpClient.requests.map((r) => r.authorization).toList(),
      <String>[
        'Bearer access-old',
        'Bearer access-old', // 1s 后重连，此时本地 token 还没换
        'Bearer access-1',
        'Bearer access-1', // 同上，重连时本地还是上一次续到的 token
        'Bearer access-2',
      ],
    );
    expect(events.map((e) => e.data), contains('第二次续期后的日志'));
    expect(errors, isEmpty);
    expect(sessionExpiredCalls, 0);

    client.close();
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('页面已经 close()：续期回来后不再重连', () async {
    // 没有代号（_generation）的话，close() 之后排在续期回调里的重连
    // 会照样连上去，页面已经销毁却还在收日志。
    final releaseRefresh = Completer<void>();
    final refreshAdapter = FakeHttpAdapter((_) async {
      await releaseRefresh.future;
      return jsonResponse({'access_token': 'access-new'});
    });
    final httpClient = FakeSseHttpClient((_) => emptyResponse(401));

    final client = SseClient(
      httpClientFactory: () => httpClient,
      rawDioFactory: () => dioWithAdapter(refreshAdapter),
    );

    final errors = <dynamic>[];
    final pending = client.connect(
      path: streamPath,
      onEvent: (_) {},
      onError: errors.add,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    client.close();
    releaseRefresh.complete();
    await pending.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(httpClient.requests.length, 1, reason: '关掉之后不该再建连接');
    expect(errors, isEmpty, reason: '页面已经没了，不该再往上抛提示');
  });

  test('非 401 的 HTTP 错误会告诉页面原因，而不是装成一条空流', () async {
    // 改造前 404 会被当成空的 SSE 流解析完，用户看到的是「连接结束」。
    final httpClient = FakeSseHttpClient((_) => emptyResponse(404));
    // 404 走不到续期，不需要注入刷新用的 dio。
    final client = SseClient(httpClientFactory: () => httpClient);

    final errors = <dynamic>[];
    await client.connect(
      path: streamPath,
      onEvent: (_) {},
      onError: errors.add,
    );

    expect(errors.single.toString(), contains('404'));
    expect(errors.single, isNot(isA<SseAuthFailure>()));

    client.close();
  });

  test('正常的流不碰续期逻辑', () async {
    final refreshAdapter = FakeHttpAdapter(
      (_) => jsonResponse({'access_token': 'access-new'}),
    );
    const body = 'data: 一\n\ndata: 二\n\nevent: done\ndata: finished\n\n';
    final httpClient = FakeSseHttpClient((_) => sseResponse(body));

    final client = SseClient(
      httpClientFactory: () => httpClient,
      rawDioFactory: () => dioWithAdapter(refreshAdapter),
    );

    final events = <SseEvent>[];
    await client.connect(path: streamPath, onEvent: events.add);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(events.map((e) => e.data).toList(), ['一', '二', 'finished']);
    expect(events.last.event, 'done');
    expect(refreshAdapter.requests, isEmpty);
    expect(await SecureStorage.getAccessToken(), 'access-old');

    client.close();
  });
}
