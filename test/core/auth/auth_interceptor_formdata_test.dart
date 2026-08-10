import 'package:daidai_app/core/auth/auth_interceptor.dart';
import 'package:daidai_app/core/auth/token_refresher.dart';
import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_http_adapter.dart';

/// multipart 上传撞上 401 时的重发回归。
///
/// 背景：`_retry` 复用同一个 `RequestOptions`，也就是同一个已经 finalize 过的
/// `FormData`。dio 的 `FormData.finalize()` 二次调用直接抛 `StateError`，
/// 所以脚本上传、备份上传遇到 401 时，**续期是成功的、重发却必然失败**，
/// 而用户只看到一句「上传失败」，完全无从判断是 token 问题。
///
/// 修法是在 `onRequest`（FormData 尚未 finalize 的唯一时机）留一份 `clone()`，
/// 重发时换上去。这组用例锁住这个行为。
void main() {
  const uploadPath = ApiEndpoints.scriptsUpload;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({
      'access_token': 'access-old',
      'refresh_token': 'refresh-1',
    });
    TokenRefresher.instance.resetForTest();
  });

  Dio buildApiDio(FakeHttpAdapter apiAdapter, FakeHttpAdapter refreshAdapter) {
    final api = dioWithAdapter(apiAdapter);
    final refresh = dioWithAdapter(refreshAdapter);
    api.interceptors.add(
      AuthInterceptor(dio: api, rawDioFactory: () => refresh),
    );
    return api;
  }

  FormData buildUpload() {
    return FormData()
      ..files.add(
        MapEntry(
          'file',
          MultipartFile.fromBytes(
            List<int>.filled(256, 65),
            filename: 'demo.js',
          ),
        ),
      );
  }

  test('multipart 上传遇到 401：续期后重发不抛 StateError，且请求体不是空的', () async {
    final apiAdapter = FakeHttpAdapter((options) {
      if (options.headers['Authorization'] == 'Bearer access-new') {
        return jsonResponse({'message': '上传成功'});
      }
      return jsonResponse({'error': 'token 已过期'}, status: 401);
    });
    final refreshAdapter = FakeHttpAdapter(
      (_) => jsonResponse({'access_token': 'access-new'}),
    );
    final api = buildApiDio(apiAdapter, refreshAdapter);

    final response = await api
        .post(uploadPath, data: buildUpload())
        .timeout(const Duration(seconds: 10));

    expect(response.statusCode, 200);
    expect(apiAdapter.countOf(uploadPath), 2, reason: '应该发了首发 + 重发两次');

    final retried = apiAdapter.requests
        .where((r) => r.path == uploadPath)
        .last;
    expect(
      retried.authorization,
      'Bearer access-new',
      reason: '重发必须带新 token',
    );
    // 这一条才是真正的回归点：没有 clone 快照时，重发要么抛 StateError，
    // 要么发出一个空 body —— 服务端拿不到文件，报错还与 token 无关。
    expect(
      retried.bodyByteCount,
      greaterThan(256),
      reason: '重发的请求体必须包含完整文件内容（256 字节正文 + multipart 边界）',
    );
  });

  test('首发就成功的 multipart 不受影响，请求体照常完整', () async {
    final apiAdapter = FakeHttpAdapter(
      (_) => jsonResponse({'message': '上传成功'}),
    );
    final refreshAdapter = FakeHttpAdapter(
      (_) => jsonResponse({'access_token': 'access-new'}),
    );
    final api = buildApiDio(apiAdapter, refreshAdapter);

    final response = await api
        .post(uploadPath, data: buildUpload())
        .timeout(const Duration(seconds: 10));

    expect(response.statusCode, 200);
    expect(apiAdapter.countOf(uploadPath), 1);
    expect(apiAdapter.requests.single.bodyByteCount, greaterThan(256));
  });

  test('非 multipart 的 JSON 请求走原路径，不因快照逻辑改变行为', () async {
    final apiAdapter = FakeHttpAdapter((options) {
      if (options.headers['Authorization'] == 'Bearer access-new') {
        return jsonResponse({'data': []});
      }
      return jsonResponse({'error': 'token 已过期'}, status: 401);
    });
    final refreshAdapter = FakeHttpAdapter(
      (_) => jsonResponse({'access_token': 'access-new'}),
    );
    final api = buildApiDio(apiAdapter, refreshAdapter);

    final response = await api
        .post(ApiEndpoints.tasks, data: {'name': '任务一'})
        .timeout(const Duration(seconds: 10));

    expect(response.statusCode, 200);
    expect(apiAdapter.countOf(ApiEndpoints.tasks), 2);
  });
}
