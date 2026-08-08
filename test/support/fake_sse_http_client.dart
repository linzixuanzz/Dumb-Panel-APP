import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// 手写的假 `http.Client`。
///
/// SSE 走 `package:http` 而不是 dio，复用不了 `FakeHttpAdapter`；
/// 但 `http.BaseClient` 只要求实现一个 `send`，同样不需要引新依赖。
class FakeSseHttpClient extends http.BaseClient {
  FakeSseHttpClient(this.responder);

  final FutureOr<http.StreamedResponse> Function(http.BaseRequest request)
  responder;

  /// 每次 send 在**发出那一刻**的快照。
  final List<RecordedSseRequest> requests = <RecordedSseRequest>[];

  int closeCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(
      RecordedSseRequest(
        url: request.url.toString(),
        authorization: request.headers['Authorization'],
      ),
    );
    return responder(request);
  }

  @override
  void close() {
    closeCount++;
  }
}

class RecordedSseRequest {
  const RecordedSseRequest({required this.url, required this.authorization});

  final String url;
  final String? authorization;
}

/// 构造一条 SSE 响应。[body] 直接写原始帧，例如：
/// `'data: 第一行\n\nevent: done\ndata: finished\n\n'`
http.StreamedResponse sseResponse(String body, {int status = 200}) {
  return http.StreamedResponse(
    Stream<List<int>>.value(utf8.encode(body)),
    status,
    headers: const {'content-type': 'text/event-stream'},
  );
}

/// 401 / 404 这类没有流体的响应。
http.StreamedResponse emptyResponse(int status) {
  return http.StreamedResponse(const Stream<List<int>>.empty(), status);
}
