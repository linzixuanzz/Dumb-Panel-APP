import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/features/logs/utils/log_open_preference.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_http_adapter.dart';

/// 账户偏好「打开已结束的日志时定位到底部」（issue #147，面板 v3.3.3 list 组的 log_open_at_bottom）。
///
/// 钉三件事：
/// 1. 形状探测：响应里没有 list 对象（≤ v3.3.0）→ null（不给开关、绝不 PUT）；
/// 2. PUT 只带 list 组的这一个键，不能带 editor（老面板收到 editor 会写一整套默认值）；
/// 3. v3.3.1 / v3.3.2 回 200 却没存：靠回显认出来。
void main() {
  Future<bool?> loadWith(ResponseBody Function() respond) {
    final adapter = FakeHttpAdapter((_) => respond());
    return loadOpenFinishedLogAtBottom(dio: dioWithAdapter(adapter));
  }

  Map<String, dynamic> editor() => {
    'word_wrap': 'on',
    'minimap': false,
    'indent_guides': true,
    'whitespace': 'selection',
    'indent_width': 'auto',
  };

  group('读', () {
    test('v3.3.3：存过 true / false 原样拿到', () async {
      expect(
        await loadWith(
          () => jsonResponse({
            'editor': editor(),
            'stored': false,
            'list': {'log_open_at_bottom': true},
          }),
        ),
        isTrue,
      );
      expect(
        await loadWith(
          () => jsonResponse({
            'editor': editor(),
            'stored': false,
            'list': {'log_open_at_bottom': false, 'tasks_page_size': 50},
          }),
        ),
        isFalse,
      );
    });

    test('有 list 没这个键（v3.3.3 没设过 / v3.3.1、v3.3.2）→ APP 默认值，而不是 null', () async {
      expect(
        await loadWith(
          () => jsonResponse({
            'editor': editor(),
            'stored': false,
            'list': <String, dynamic>{},
          }),
        ),
        kOpenFinishedLogAtBottomDefault,
      );
    });

    test('v3.2.4 ~ v3.3.0：只有 editor → null', () async {
      expect(
        await loadWith(() => jsonResponse({'editor': editor(), 'stored': true})),
        isNull,
      );
    });

    test('更老的面板没有这条路由：两种 404 形态都 → null，不抛', () async {
      // Docker 部署：gin 默认的纯文本 404。
      expect(
        await loadWith(
          () => ResponseBody.fromString(
            '404 page not found',
            404,
            headers: {
              Headers.contentTypeHeader: ['text/plain; charset=utf-8'],
            },
          ),
        ),
        isNull,
      );
      // 二进制部署、面板托管前端：NoRoute 回 JSON。
      expect(
        await loadWith(
          () => jsonResponse({'error': 'route not found'}, status: 404),
        ),
        isNull,
      );
    });

    test('值类型不对（字符串 "true"）→ 当没设过', () async {
      expect(
        await loadWith(
          () => jsonResponse({
            'list': {'log_open_at_bottom': 'true'},
          }),
        ),
        kOpenFinishedLogAtBottomDefault,
      );
    });
  });

  group('写', () {
    test('PUT 只带 list 组的这一个键；v3.3.3 回显里有 → true', () async {
      final bodies = <Object?>[];
      final adapter = FakeHttpAdapter((options) {
        bodies.add(options.data);
        return jsonResponse({
          'editor': editor(),
          'stored': false,
          'list': {'log_open_at_bottom': false, 'tasks_page_size': 50},
        });
      });

      final saved = await saveOpenFinishedLogAtBottom(
        false,
        dio: dioWithAdapter(adapter),
      );

      expect(saved, isTrue);
      expect(adapter.requests.single.method, 'PUT');
      expect(adapter.requests.single.path, ApiEndpoints.preferences);
      // 恰好这一个键：不带 editor，也不带 list 里的其它键。
      expect(bodies.single, {
        'list': {'log_open_at_bottom': false},
      });
    });

    test('v3.3.1 / v3.3.2：白名单外的键被当空补丁，回 200 但回显里没有 → false', () async {
      final adapter = FakeHttpAdapter(
        (_) => jsonResponse({
          'editor': editor(),
          'stored': false,
          'list': {'tasks_page_size': 50},
        }),
      );

      expect(
        await saveOpenFinishedLogAtBottom(true, dio: dioWithAdapter(adapter)),
        isFalse,
      );
    });
  });
}
