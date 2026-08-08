import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// 手写的假 `HttpClientAdapter`，替换 `dio.httpClientAdapter` 后整条 dio 链路
/// （拦截器 / transformer / validateStatus / DioException）都是真的，只有网络是假的。
///
/// 之所以不引 `http_mock_adapter` 之类：仓库 51 个包被约束锁在旧版本，
/// dev_dependencies 目前只有 flutter_test / flutter_lints / flutter_launcher_icons，
/// 而 dio 本身就把适配器设计成可替换的，接口只有 fetch + close 两个方法。
class FakeHttpAdapter implements HttpClientAdapter {
  FakeHttpAdapter(this.responder);

  /// 按请求返回假响应。抛异常等价于网络层出错。
  final FutureOr<ResponseBody> Function(RequestOptions options) responder;

  /// 每次 fetch 的**快照**。不能直接存 RequestOptions：
  /// 重发用的是同一个实例，事后再读 headers 只会看到最后一次的值。
  final List<RecordedRequest> requests = <RecordedRequest>[];

  int countOf(String path) =>
      requests.where((item) => item.path == path).length;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(
      RecordedRequest(
        method: options.method,
        path: options.path,
        authorization: options.headers['Authorization']?.toString(),
      ),
    );
    return responder(options);
  }

  @override
  void close({bool force = false}) {}
}

/// 一次请求在 **发出那一刻** 的关键信息。
class RecordedRequest {
  const RecordedRequest({
    required this.method,
    required this.path,
    required this.authorization,
  });

  final String method;
  final String path;
  final String? authorization;
}

/// 构造 JSON 响应体。
///
/// content-type 必须带上：dio 的 transformer 只在 mime 是 json 时才解码，
/// 少了这个头，`response.data` 会是一整串未解析的字符串。
ResponseBody jsonResponse(Map<String, dynamic> body, {int status = 200}) {
  return ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

/// 构造**按字节**返回的响应体，用于 `ResponseType.bytes` 的下载接口。
///
/// 与 [jsonResponse] 的区别只在 content-type：走 `ResponseType.bytes` 时
/// dio 根本不看它，但真实响应确实是 `text/plain`，保持一致才好排查。
ResponseBody bytesResponse(
  List<int> body, {
  int status = 200,
  String contentType = 'text/plain; charset=utf-8',
}) {
  return ResponseBody.fromBytes(
    body,
    status,
    headers: {
      Headers.contentTypeHeader: [contentType],
    },
  );
}

/// 与 `lib/core/network/dio_client.dart` 同款配置的 dio：
/// `validateStatus < 400`（4xx 必须抛 DioException 才能进 onError）
/// 加上 json 的 Content-Type（少了它 dio 会把请求体按 form 编码，行为和线上不一致）。
Dio dioWithAdapter(FakeHttpAdapter adapter) {
  final dio = Dio(
    BaseOptions(
      baseUrl: 'https://panel.test',
      validateStatus: (status) => status != null && status < 400,
      headers: const {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
    ),
  );
  dio.httpClientAdapter = adapter;
  return dio;
}
