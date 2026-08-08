import 'dart:convert';

import 'package:daidai_app/core/auth/auth_interceptor.dart';
import 'package:daidai_app/core/auth/token_refresher.dart';
import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/storage/secure_storage.dart';
import 'package:daidai_app/features/logs/utils/raw_log_download.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_http_adapter.dart';

/// 「下载原始日志」的回归保护。
///
/// 两块内容：
/// 1. 换票响应里的下载地址是**从响应体里读出来、马上要带着票据去请求**的，
///    校验放松一点就等于把票据发给别人；
/// 2. `/raw` 那条路由在面板侧没有挂 JWT 中间件，它的 401 表示「票据失效」。
///    如果这条请求走了挂着 AuthInterceptor 的 dio 单例，**用户会被踢下线** ——
///    最后一组用例把这个后果直接演一遍。
void main() {
  const logId = 7;
  final ticketPath = ApiEndpoints.logRawTicket(logId);
  final rawPath = ApiEndpoints.logRaw(logId);

  Map<String, dynamic> ticketPayload({String? url, String? filename}) {
    return {
      'url': url ?? '$rawPath?ticket=v1.YWRtaW4.1785000120.3Qk8',
      'filename': filename ?? '签到任务-7-raw.log',
      // 面板确实会下发这三个，APP 不解析 —— 多出来的键不能让解析失败。
      'size': 2048,
      'expires_at': '2026-08-08T10:02:00Z',
      'expires_in': 120,
    };
  }

  group('parseRawLogTicket', () {
    test('正常响应：路径、票据、文件名都取到，面板多下发的键被忽略', () {
      final ticket = parseRawLogTicket(
        ticketPayload(),
        expectedPath: rawPath,
        fallbackFilename: 'fallback.log',
      );

      expect(ticket.path, rawPath);
      expect(ticket.query['ticket'], 'v1.YWRtaW4.1785000120.3Qk8');
      expect(ticket.filename, '签到任务-7-raw.log');
    });

    test('响应被 {data: ...} 包一层时同样能解析', () {
      final ticket = parseRawLogTicket(
        {'data': ticketPayload()},
        expectedPath: rawPath,
        fallbackFilename: 'fallback.log',
      );

      expect(ticket.path, rawPath);
    });

    test('绝对地址一律拒绝：票据不能被发到别的主机', () {
      expect(
        () => parseRawLogTicket(
          ticketPayload(url: 'https://evil.example.com$rawPath?ticket=abc'),
          expectedPath: rawPath,
          fallbackFilename: 'fallback.log',
        ),
        throwsA(isA<RawLogDownloadException>()),
      );
    });

    test('协议相对地址（//host/...）同样拒绝', () {
      // 突变验证锚点：把 parseRawLogTicket 里的 `uri.hasAuthority` 判断删掉，
      // 这条会变绿 —— 而实际效果是票据被发给 evil.example.com。
      expect(
        () => parseRawLogTicket(
          ticketPayload(url: '//evil.example.com$rawPath?ticket=abc'),
          expectedPath: rawPath,
          fallbackFilename: 'fallback.log',
        ),
        throwsA(isA<RawLogDownloadException>()),
      );
    });

    test('路径指向别的日志时拒绝', () {
      expect(
        () => parseRawLogTicket(
          ticketPayload(url: '${ApiEndpoints.logRaw(8)}?ticket=abc'),
          expectedPath: rawPath,
          fallbackFilename: 'fallback.log',
        ),
        throwsA(isA<RawLogDownloadException>()),
      );
    });

    test('地址里没有票据时拒绝：不做一次注定 401 的请求', () {
      expect(
        () => parseRawLogTicket(
          ticketPayload(url: rawPath),
          expectedPath: rawPath,
          fallbackFilename: 'fallback.log',
        ),
        throwsA(isA<RawLogDownloadException>()),
      );
    });

    test('面板没给文件名时用兜底名，而不是存成一个没有名字的文件', () {
      final ticket = parseRawLogTicket(
        ticketPayload(filename: '   '),
        expectedPath: rawPath,
        fallbackFilename: 'task-log-7-raw.log',
      );

      expect(ticket.filename, 'task-log-7-raw.log');
    });

    test('ticket 之外的查询参数原样保留（日志文件那套要靠 path= 才验得过签）', () {
      final ticket = parseRawLogTicket(
        ticketPayload(url: '$rawPath?path=task_1%2Frun.log&ticket=abc'),
        expectedPath: rawPath,
        fallbackFilename: 'fallback.log',
      );

      expect(ticket.query['path'], 'task_1/run.log');
      expect(ticket.query['ticket'], 'abc');
    });

    test('响应体不是对象时报错，而不是让后面拿着 null 去请求', () {
      expect(
        () => parseRawLogTicket(
          '不是一个对象',
          expectedPath: rawPath,
          fallbackFilename: 'fallback.log',
        ),
        throwsA(isA<RawLogDownloadException>()),
      );
    });
  });

  group('RawLogDownloader', () {
    late int authFailedCalls;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({
        'access_token': 'access-old',
        'refresh_token': 'refresh-1',
      });
      // TokenRefresher 是单例，不重置的话上一条用例注入的假 dio 会被下一条复用。
      TokenRefresher.instance.resetForTest();
      authFailedCalls = 0;
    });

    // 换票那条**要**走挂着 AuthInterceptor 的链路：它的 401 才是真的 token 过期。
    Dio buildAuthedDio(FakeHttpAdapter apiAdapter, FakeHttpAdapter refresh) {
      final api = dioWithAdapter(apiAdapter);
      api.interceptors.add(
        AuthInterceptor(
          dio: api,
          rawDioFactory: () => dioWithAdapter(refresh),
          onAuthFailed: () => authFailedCalls++,
        ),
      );
      return api;
    }

    test('两步走通：换票带 Bearer，下载那条不带，拿到的是磁盘原始字节', () async {
      final ticketAdapter = FakeHttpAdapter(
        (_) => jsonResponse(ticketPayload()),
      );
      final refreshAdapter = FakeHttpAdapter(
        (_) => jsonResponse({'access_token': 'access-new'}),
      );
      final downloadAdapter = FakeHttpAdapter(
        // 裸 \r 正是「原始日志」存在的理由：页面上那份已经被终端语义折叠过了。
        (_) => bytesResponse(utf8.encode('第 1 行\r进度 100%\n')),
      );

      final file = await RawLogDownloader(
        ticketDio: buildAuthedDio(ticketAdapter, refreshAdapter),
        downloadDio: dioWithAdapter(downloadAdapter),
      ).downloadTaskLog(logId);

      expect(file.filename, '签到任务-7-raw.log');
      expect(utf8.decode(file.bytes), '第 1 行\r进度 100%\n');
      expect(ticketAdapter.requests.single.path, ticketPath);
      expect(ticketAdapter.requests.single.authorization, 'Bearer access-old');
      expect(downloadAdapter.requests.single.path, rawPath);
      expect(
        downloadAdapter.requests.single.authorization,
        isNull,
        reason: '/raw 只认 ?ticket=，没必要把 Bearer token 发给它',
      );
      expect(refreshAdapter.requests, isEmpty);
    });

    test('票据过期（下载 401）：给中文提示，不续期、不清会话', () async {
      // 突变验证锚点：把 RawLogDownloader 的 _downloadDio 改成走 DioClient 单例
      // （或给这里的 downloadDio 挂上 AuthInterceptor），authFailedCalls 就不再是 0，
      // 用户会被踢回登录页 —— 后果见下一条用例。
      final ticketAdapter = FakeHttpAdapter(
        (_) => jsonResponse(ticketPayload()),
      );
      final refreshAdapter = FakeHttpAdapter(
        (_) => jsonResponse({'access_token': 'access-new'}),
      );
      final downloadAdapter = FakeHttpAdapter(
        (_) => jsonResponse({'error': '下载票据已过期，请重新发起下载'}, status: 401),
      );

      await expectLater(
        RawLogDownloader(
          ticketDio: buildAuthedDio(ticketAdapter, refreshAdapter),
          downloadDio: dioWithAdapter(downloadAdapter),
        ).downloadTaskLog(logId),
        throwsA(
          isA<RawLogDownloadException>().having(
            (e) => e.message,
            'message',
            // 下载走 ResponseType.bytes，面板写在 body 里的中文必须自己从字节里解出来，
            // 否则用户看到的是 "The request returned an invalid status code of 401."
            '下载票据已过期，请重新发起下载',
          ),
        ),
      );

      expect(refreshAdapter.requests, isEmpty, reason: '票据失效不是 token 过期');
      expect(authFailedCalls, 0);
      expect(await SecureStorage.getAccessToken(), 'access-old');
      expect(await SecureStorage.getRefreshToken(), 'refresh-1');
    });

    test('反例存档：下载改走带 AuthInterceptor 的 dio，票据 401 会把用户踢下线', () async {
      // 这条不是在保护现状，而是把「为什么必须用 DioClient.ticketDio」的后果钉下来。
      // 一张过期 120 秒的下载票据不该有清空登录态的能力。
      final apiAdapter = FakeHttpAdapter((options) {
        if (options.path == ticketPath) {
          return jsonResponse(ticketPayload());
        }
        return jsonResponse({'error': '下载票据已过期，请重新发起下载'}, status: 401);
      });
      final refreshAdapter = FakeHttpAdapter(
        (_) => jsonResponse({'access_token': 'access-new'}),
      );
      final authed = buildAuthedDio(apiAdapter, refreshAdapter);

      await expectLater(
        RawLogDownloader(
          ticketDio: authed,
          downloadDio: authed,
        ).downloadTaskLog(logId),
        throwsA(isA<RawLogDownloadException>()),
      );

      expect(refreshAdapter.requests, isNotEmpty, reason: '被当成 token 过期去续期了');
      expect(
        authFailedCalls,
        greaterThanOrEqualTo(1),
        reason: '续期后仍 401 → 判定会话失效',
      );
      expect(await SecureStorage.getAccessToken(), isNull, reason: '登录态被清空');
    });

    test('日志内容只存在数据库时：把面板给的原因原样告诉用户', () async {
      final ticketAdapter = FakeHttpAdapter(
        (_) => jsonResponse({
          'error': '该日志没有独立的原始日志文件（内容仅存于数据库）',
        }, status: 404),
      );
      final refreshAdapter = FakeHttpAdapter(
        (_) => jsonResponse({'access_token': 'access-new'}),
      );
      final downloadAdapter = FakeHttpAdapter((_) => bytesResponse(const []));

      await expectLater(
        RawLogDownloader(
          ticketDio: buildAuthedDio(ticketAdapter, refreshAdapter),
          downloadDio: dioWithAdapter(downloadAdapter),
        ).downloadTaskLog(logId),
        throwsA(
          isA<RawLogDownloadException>().having(
            (e) => e.message,
            'message',
            '该日志没有独立的原始日志文件（内容仅存于数据库）',
          ),
        ),
      );

      expect(downloadAdapter.requests, isEmpty, reason: '换票就失败了，不该再去拉文件');
    });

    test('403：把面板 RequireRole 给的原话透出来，不是英文状态码', () async {
      final ticketAdapter = FakeHttpAdapter(
        (_) => jsonResponse({'error': '拒绝访问'}, status: 403),
      );
      final refreshAdapter = FakeHttpAdapter(
        (_) => jsonResponse({'access_token': 'access-new'}),
      );
      final downloadAdapter = FakeHttpAdapter((_) => bytesResponse(const []));

      await expectLater(
        RawLogDownloader(
          ticketDio: buildAuthedDio(ticketAdapter, refreshAdapter),
          downloadDio: dioWithAdapter(downloadAdapter),
        ).downloadTaskLog(logId),
        throwsA(
          isA<RawLogDownloadException>().having(
            (e) => e.message,
            'message',
            '拒绝访问',
          ),
        ),
      );
    });

    test('老面板没有 raw-ticket 这条路由：提示升级，而不是「面板返回错误（HTTP 404）」', () async {
      // 形状探测而不是版本号：面板自己的 404 一定带 {"error": ...}，
      // gin 找不到路由时回的是纯文本 "404 page not found"。
      final ticketAdapter = FakeHttpAdapter(
        (_) => ResponseBody.fromString(
          '404 page not found',
          404,
          headers: {
            Headers.contentTypeHeader: ['text/plain; charset=utf-8'],
          },
        ),
      );
      final refreshAdapter = FakeHttpAdapter(
        (_) => jsonResponse({'access_token': 'access-new'}),
      );
      final downloadAdapter = FakeHttpAdapter((_) => bytesResponse(const []));

      await expectLater(
        RawLogDownloader(
          ticketDio: buildAuthedDio(ticketAdapter, refreshAdapter),
          downloadDio: dioWithAdapter(downloadAdapter),
        ).downloadTaskLog(logId),
        throwsA(
          isA<RawLogDownloadException>().having(
            (e) => e.message,
            'message',
            '当前面板不支持下载原始日志，请升级面板后再试',
          ),
        ),
      );
    });
  });
}
