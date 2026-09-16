import 'dart:async';
import 'dart:convert';

import 'package:daidai_app/features/tasks/providers/task_view_provider.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_http_adapter.dart';

/// 视图编辑器给不给「分组」字段（`group`，契约 C3）的能力探测。
///
/// 老面板不认 `group`：取不到值，「分组 等于 X」匹配不到任何任务；而面板建视图时
/// 不校验字段，保存照样成功 —— 在老面板上给出这个选项，用户建出来的就是一条
/// 永远为空、还会同步到网页端的视图。所以先探测：`GET /api/tasks/groups`
/// （契约 C2，与 C3 同一版加的）回数组才算支持。
void main() {
  const viewsPath = '/api/tasks/views';
  const groupsPath = '/api/tasks/groups';

  test('探测到数组 → 支持 group，而且只多发这一次请求', () async {
    final adapter = FakeHttpAdapter((options) {
      if (options.path == groupsPath) {
        return _jsonList([
          {'name': '京东', 'count': 3},
        ]);
      }
      return _jsonList(const []);
    });
    final notifier = TaskViewNotifier(dio: dioWithAdapter(adapter));
    expect(
      notifier.state.supportsGroupFilter,
      isFalse,
      reason: '探测之前默认不给：宁可少一个选项，也不在老面板上建出空视图',
    );

    await notifier.load();
    await pumpEventQueue();

    expect(notifier.state.supportsGroupFilter, isTrue);
    expect(adapter.countOf(viewsPath), 1);
    expect(adapter.countOf(groupsPath), 1);
  });

  test('{data: [...]} 包裹的数组同样算支持', () async {
    final adapter = FakeHttpAdapter((options) {
      if (options.path == groupsPath) {
        return jsonResponse({
          'data': [
            {'name': '京东', 'count': 3},
          ],
        });
      }
      return _jsonList(const []);
    });
    final notifier = TaskViewNotifier(dio: dioWithAdapter(adapter));

    await notifier.load();
    await pumpEventQueue();

    expect(notifier.state.supportsGroupFilter, isTrue);
  });

  test('老面板 404 → 不支持，且不影响视图列表本身', () async {
    final adapter = FakeHttpAdapter((options) {
      if (options.path == groupsPath) {
        return jsonResponse({'error': '404 page not found'}, status: 404);
      }
      return _jsonList([
        {'id': 1, 'name': '京东', 'filters': '[]', 'sort_rules': '[]'},
      ]);
    });
    final notifier = TaskViewNotifier(dio: dioWithAdapter(adapter));

    await notifier.load();
    await pumpEventQueue();

    expect(notifier.state.supportsGroupFilter, isFalse);
    expect(notifier.state.supported, isTrue);
    expect(notifier.state.views.single.name, '京东');
    expect(notifier.state.error, isNull, reason: '可选能力探测不到不是「出错」');
  });

  test('200 但不是数组（反代把未知路径兜成首页）不算支持', () async {
    final adapter = FakeHttpAdapter((options) {
      if (options.path == groupsPath) {
        return ResponseBody.fromString(
          '<!doctype html><html><body></body></html>',
          200,
          headers: {
            Headers.contentTypeHeader: ['text/html; charset=utf-8'],
          },
        );
      }
      return _jsonList(const []);
    });
    final notifier = TaskViewNotifier(dio: dioWithAdapter(adapter));

    await notifier.load();
    await pumpEventQueue();

    expect(notifier.state.supportsGroupFilter, isFalse);
  });

  test('断网 / 5xx 说明不了面板认不认，保留上一次的结论', () async {
    var failGroups = false;
    final adapter = FakeHttpAdapter((options) {
      if (options.path == groupsPath) {
        if (failGroups) {
          return jsonResponse({'error': '面板数据库连接失败'}, status: 500);
        }
        return _jsonList(const []);
      }
      return _jsonList(const []);
    });
    final notifier = TaskViewNotifier(dio: dioWithAdapter(adapter));

    await notifier.load();
    await pumpEventQueue();
    expect(notifier.state.supportsGroupFilter, isTrue);

    failGroups = true;
    await notifier.load();
    await pumpEventQueue();

    expect(notifier.state.supportsGroupFilter, isTrue);
    expect(notifier.state.error, isNull, reason: '探测失败不许冒充成视图列表的错误');
  });

  test('视图接口 404 / 403（老面板或角色不够）时不探测，直接当作不支持', () async {
    for (final status in [404, 403]) {
      final adapter = FakeHttpAdapter(
        (_) => jsonResponse({'error': '不支持'}, status: status),
      );
      final notifier = TaskViewNotifier(dio: dioWithAdapter(adapter));

      await notifier.load();
      await pumpEventQueue();

      expect(notifier.state.supported, isFalse, reason: 'status=$status');
      expect(notifier.state.supportsGroupFilter, isFalse);
      expect(adapter.countOf(groupsPath), 0);
    }
  });

  test('视图列表加载失败（500）时不多发探测请求', () async {
    final adapter = FakeHttpAdapter(
      (_) => jsonResponse({'error': '面板数据库连接失败'}, status: 500),
    );
    final notifier = TaskViewNotifier(dio: dioWithAdapter(adapter));

    await notifier.load();
    await pumpEventQueue();

    expect(notifier.state.error, '面板数据库连接失败');
    expect(notifier.state.supportsGroupFilter, isFalse);
    expect(adapter.countOf(groupsPath), 0);
  });

  test('探测不阻塞 load()：冷启动恢复视图要等 load() 回来，不能再多等一个来回', () async {
    final groupsReply = Completer<ResponseBody>();
    final adapter = FakeHttpAdapter((options) {
      if (options.path == groupsPath) {
        return groupsReply.future;
      }
      return _jsonList([
        {'id': 1, 'name': '京东', 'filters': '[]'},
      ]);
    });
    final notifier = TaskViewNotifier(dio: dioWithAdapter(adapter));

    await notifier.load();

    expect(notifier.state.loading, isFalse);
    expect(notifier.state.views.single.name, '京东');
    expect(notifier.state.supportsGroupFilter, isFalse);

    groupsReply.complete(_jsonList(const []));
    await pumpEventQueue();

    expect(notifier.state.supportsGroupFilter, isTrue);
  });

  test('切换到老面板后，迟到的旧探测结果不许把结论改回「支持」', () async {
    final groupsReply = Completer<ResponseBody>();
    var viewCalls = 0;
    final adapter = FakeHttpAdapter((options) {
      if (options.path == groupsPath) {
        return groupsReply.future;
      }
      viewCalls++;
      if (viewCalls == 1) {
        return _jsonList(const []);
      }
      return jsonResponse({'error': '404 page not found'}, status: 404);
    });
    final notifier = TaskViewNotifier(dio: dioWithAdapter(adapter));

    // 新面板：视图成功，探测发出去了但还没回来。
    await notifier.load();
    await pumpEventQueue();
    // 切到老面板：视图 404。
    await notifier.load();
    // 新面板那次探测这时才回来。
    groupsReply.complete(_jsonList(const []));
    await pumpEventQueue();

    expect(notifier.state.supported, isFalse);
    expect(notifier.state.supportsGroupFilter, isFalse);
  });

  test('探测结果回来时不许抹掉视图列表的错误提示', () async {
    // copyWith 的 error 是「不传即清空」：探测与视图列表无关，必须原样回传 error。
    final groupsReply = Completer<ResponseBody>();
    var viewCalls = 0;
    final adapter = FakeHttpAdapter((options) {
      if (options.path == groupsPath) {
        return groupsReply.future;
      }
      viewCalls++;
      if (viewCalls == 1) {
        return _jsonList(const []);
      }
      return jsonResponse({'error': '面板数据库连接失败'}, status: 500);
    });
    final notifier = TaskViewNotifier(dio: dioWithAdapter(adapter));

    await notifier.load();
    await pumpEventQueue();
    await notifier.load();
    expect(notifier.state.error, '面板数据库连接失败');

    groupsReply.complete(_jsonList(const []));
    await pumpEventQueue();

    expect(notifier.state.supportsGroupFilter, isTrue);
    expect(notifier.state.error, '面板数据库连接失败');
  });
}

/// 构造**裸 JSON 数组**的响应体（`/tasks/views` 与 `/tasks/groups` 线上都是裸数组）。
ResponseBody _jsonList(List<dynamic> body) {
  return ResponseBody.fromString(
    jsonEncode(body),
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}
