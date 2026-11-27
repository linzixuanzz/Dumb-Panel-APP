import 'dart:async';
import 'dart:convert';

import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/network/dio_client.dart';
import 'package:daidai_app/features/deps/views/dep_list_page.dart';
import 'package:daidai_app/shared/models/dependency.dart';
import 'package:daidai_app/shared/utils/log_line_buffer.dart';
import 'package:daidai_app/shared/widgets/log_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_http_adapter.dart';
import '../../support/fake_sse_http_client.dart';

const _depId = 7;

/// 假面板。依赖状态每次现读 [status]，测试里可以中途改；返回 null 表示
/// 记录已删（卸载成功），状态接口照面板回 404「依赖不存在」。
///
/// 取消 / 重装两个接口照面板只注册 PUT（deps.go RegisterRoutes）：
/// 方法不对就照 gin 的 NoRoute 回 404 `route not found`。
FakeHttpAdapter _fakePanel(String? Function() status) =>
    FakeHttpAdapter((options) {
      final path = options.path;
      if (path == ApiEndpoints.depStatus(_depId)) {
        if (status() == null) {
          return jsonResponse({'error': '依赖不存在'}, status: 404);
        }
        return jsonResponse({
          'data': {
            'id': _depId,
            'name': 'requests',
            'type': 'python',
            'status': status(),
            'log': '',
          },
        });
      }
      if (path == ApiEndpoints.depCancel(_depId) ||
          path == ApiEndpoints.depReinstall(_depId)) {
        if (options.method != 'PUT') {
          return jsonResponse({'error': 'route not found'}, status: 404);
        }
        return jsonResponse({'message': 'ok'});
      }
      if (path == ApiEndpoints.deps) {
        return jsonResponse({'data': <Object>[], 'total': 0});
      }
      return jsonResponse(<String, dynamic>{});
    });

/// 一条不会自己结束的 SSE 连接：测试往里推帧，最后再关。
class _LiveSse {
  final _controller = StreamController<List<int>>();

  http.StreamedResponse response() => http.StreamedResponse(
    _controller.stream,
    200,
    headers: const {'content-type': 'text/event-stream'},
  );

  void push(String frames) => _controller.add(utf8.encode(frames));

  Future<void> close() => _controller.close();
}

Future<void> _pumpFrames(WidgetTester tester, [int count = 20]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// 列表页带进来的快照：列表页不轮询，点完卸载后停在 removing。
class _ListedDeps extends DepListNotifier {
  _ListedDeps(List<Dependency> items) {
    state = DepListState(items: items);
  }
}

/// 列表里 id 为 [_depId] 的那条依赖。
Dependency _listedDep(String status) => Dependency(
  id: _depId,
  name: 'requests',
  type: 'python',
  status: status,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

/// 打开页面并推到假 HTTP / 假 SSE 都跑完。运行态的状态点会一直呼吸，
/// 不能 pumpAndSettle。必须在 `http.runWithClient` 里调用。
///
/// [listed] 是列表页的快照，不传就是空列表（页面只能靠查状态）。
Future<void> _openPage(
  WidgetTester tester, {
  List<Dependency> listed = const [],
}) async {
  tester.view.physicalSize = const Size(411, 860);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (listed.isNotEmpty)
          depListProvider.overrideWith((ref) => _ListedDeps(listed)),
      ],
      child: const MaterialApp(home: DepLogStreamPage(depId: _depId)),
    ),
  );
  await _pumpFrames(tester);
}

/// 收掉页面并把提示条、重连这类定时器都放完。
Future<void> _closePage(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

LogLineBuffer _buffer(WidgetTester tester) =>
    tester.widget<LogView>(find.byType(LogView)).buffer;

/// 底栏左侧的主按钮（「取消安装」或「重新安装 / 重新连接」）。
Finder _primaryButton(String label) => find.descendant(
  of: find.byWidgetPredicate(
    (widget) =>
        widget.key == const Key('fullscreen-log-stop') ||
        widget.key == const Key('fullscreen-log-rerun'),
  ),
  matching: find.text(label),
);

Finder _inPill(String text) => find.descendant(
  of: find.byKey(const Key('fullscreen-log-status-pill')),
  matching: find.text(text),
);

List<RecordedRequest> _writes(FakeHttpAdapter api, String path) =>
    api.requests.where((r) => r.path == path).toList();

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues({});
    DioClient.instance.setBaseUrl('https://panel.test');
  });

  testWidgets('取消安装走 PUT，提交后不收流、不自己定终态，等 done: cancelled', (tester) async {
    final api = _fakePanel(() => 'installing');
    DioClient.instance.dio.httpClientAdapter = api;
    final live = _LiveSse();
    final sse = FakeSseHttpClient((_) => live.response());

    await http.runWithClient(() async {
      await _openPage(tester);
      live.push('data: Collecting requests\n\n');
      await _pumpFrames(tester);

      expect(find.text('实时安装中'), findsOneWidget);
      await tester.tap(_primaryButton('取消安装'));
      await _pumpFrames(tester);

      // 改之前是 POST：面板没有这条路由，按钮在任何面板上都失败。
      final cancels = _writes(api, ApiEndpoints.depCancel(_depId));
      expect(cancels.map((r) => r.method), ['PUT']);
      // 走 provider：成功后顺带重拉了列表。
      expect(api.countOf(ApiEndpoints.deps), greaterThanOrEqualTo(1));
      expect(find.text('取消请求已提交'), findsOneWidget);
      expect(find.text('取消安装失败'), findsNothing);

      // 取消是异步生效的：页面不能自己宣布「已取消」，流也还连着。
      expect(find.text('已取消'), findsNothing);
      live.push('data: [依赖任务已取消]\n\n');
      await _pumpFrames(tester);
      expect(_buffer(tester).lines, ['Collecting requests', '[依赖任务已取消]']);

      live.push('event: done\ndata: cancelled\n\n');
      await _pumpFrames(tester);
      expect(find.text('已取消'), findsOneWidget);
      expect(find.byKey(const Key('fullscreen-log-stop')), findsNothing);
      expect(_primaryButton('重新安装'), findsOneWidget);
      expect(sse.requests, hasLength(1));

      await live.close();
      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('重新安装走 PUT，清空正文后重连日志流', (tester) async {
    final api = _fakePanel(() => 'installed');
    DioClient.instance.dio.httpClientAdapter = api;
    var connects = 0;
    final sse = FakeSseHttpClient((_) {
      connects++;
      return connects == 1
          ? sseResponse(
              'data: Successfully installed requests\n\n'
              'event: done\ndata: installed\n\n',
            )
          : sseResponse(
              'data: Collecting requests\n\n'
              'event: done\ndata: installed\n\n',
            );
    });

    await http.runWithClient(() async {
      await _openPage(tester);
      expect(find.text('安装完成'), findsOneWidget);

      await tester.tap(_primaryButton('重新安装'));
      await _pumpFrames(tester);

      final reinstalls = _writes(api, ApiEndpoints.depReinstall(_depId));
      expect(reinstalls.map((r) => r.method), ['PUT']);
      expect(find.text('重新安装失败'), findsNothing);
      expect(sse.requests, hasLength(2));
      expect(_buffer(tester).lines, ['Collecting requests']);
      expect(find.text('安装完成'), findsOneWidget);

      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('done: installed 显示「安装完成」（依赖流从来不发 finished）', (tester) async {
    DioClient.instance.dio.httpClientAdapter = _fakePanel(() => 'installed');
    final sse = FakeSseHttpClient(
      (_) => sseResponse(
        'data: Successfully installed requests-2.32.3\n\n'
        'event: done\ndata: installed\n\n',
      ),
    );

    await http.runWithClient(() async {
      await _openPage(tester);

      expect(find.text('安装完成'), findsOneWidget);
      expect(find.text('已结束'), findsNothing);
      expect(_buffer(tester).lines, ['Successfully installed requests-2.32.3']);
      expect(_primaryButton('重新安装'), findsOneWidget);

      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('done: failed 显示「安装失败」', (tester) async {
    DioClient.instance.dio.httpClientAdapter = _fakePanel(() => 'failed');
    final sse = FakeSseHttpClient(
      (_) => sseResponse(
        'data: ERROR: No matching distribution\n\n'
        'event: done\ndata: failed\n\n',
      ),
    );

    await http.runWithClient(() async {
      await _openPage(tester);

      expect(find.text('安装失败'), findsOneWidget);
      expect(find.text('安装完成'), findsNothing);
      expect(_primaryButton('重新安装'), findsOneWidget);

      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('done: queued：显示「排队中」，不给「重新安装」也不给「取消」', (tester) async {
    final api = _fakePanel(() => 'queued');
    DioClient.instance.dio.httpClientAdapter = api;
    final sse = FakeSseHttpClient(
      (_) => sseResponse('event: done\ndata: queued\n\n'),
    );

    await http.runWithClient(() async {
      await _openPage(tester);

      expect(find.text('排队中'), findsOneWidget);
      expect(find.text('安装完成'), findsNothing);
      expect(find.text('重新安装'), findsNothing);
      expect(find.byKey(const Key('fullscreen-log-stop')), findsNothing);
      // 排队中的依赖面板不让重装（回「依赖正在处理中」），只能重新连上流看。
      expect(_primaryButton('重新连接'), findsOneWidget);

      await tester.tap(_primaryButton('重新连接'));
      await _pumpFrames(tester);
      expect(sse.requests, hasLength(2));
      expect(_writes(api, ApiEndpoints.depReinstall(_depId)), isEmpty);

      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('done: timeout 不是成功：红色「连接已断开」+ 完整原因，正文不进载荷', (tester) async {
    final api = _fakePanel(() => 'installing');
    DioClient.instance.dio.httpClientAdapter = api;
    var connects = 0;
    final sse = FakeSseHttpClient((_) {
      connects++;
      return connects == 1
          ? sseResponse(
              'data: Building wheel for opencv-python\n\n'
              'event: done\ndata: timeout\n\n',
            )
          : sseResponse(
              'data: Building wheel for opencv-python\n\n'
              'data: Successfully installed opencv-python\n\n'
              'event: done\ndata: installed\n\n',
            );
    });

    await http.runWithClient(() async {
      await _openPage(tester);

      expect(find.text('安装完成'), findsNothing);
      expect(find.text('连接已断开'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('fullscreen-log-error-banner')),
          matching: find.text('日志流已断开，安装可能仍在进行'),
        ),
        findsOneWidget,
      );
      expect(_buffer(tester).lines, ['Building wheel for opencv-python']);

      // 面板说还在装：不能给「重新安装」（改之前断流就出这个按钮），
      // 只给「重新连接」，点了只重连流、不发任何写请求。
      expect(find.text('重新安装'), findsNothing);
      await tester.tap(_primaryButton('重新连接'));
      await _pumpFrames(tester);
      expect(sse.requests, hasLength(2));
      expect(_writes(api, ApiEndpoints.depReinstall(_depId)), isEmpty);
      expect(
        find.byKey(const Key('fullscreen-log-error-banner')),
        findsNothing,
      );
      expect(find.text('安装完成'), findsOneWidget);
      // 面板从头重放：先清空再接，正文不会叠成两份。
      expect(_buffer(tester).lines, [
        'Building wheel for opencv-python',
        'Successfully installed opencv-python',
      ]);

      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('done: reconnect 后重连失败：红色「连接已断开」，完整原因整句可见', (tester) async {
    DioClient.instance.dio.httpClientAdapter = _fakePanel(() => 'installing');
    var connects = 0;
    final sse = FakeSseHttpClient((_) {
      connects++;
      return connects == 1
          ? sseResponse('data: a\n\nevent: done\ndata: reconnect\n\n')
          : emptyResponse(502);
    });

    await http.runWithClient(() async {
      await _openPage(tester);
      // SseClient 收到 reconnect 后 1 秒重连一次。
      await tester.pump(const Duration(seconds: 1));
      await _pumpFrames(tester);

      expect(sse.requests, hasLength(2));
      expect(find.text('连接已断开'), findsOneWidget);
      expect(find.text('安装完成'), findsNothing);
      // 改之前原因只剩一个 96dp 宽、单行省略的胶囊；正文有日志时别处看不到。
      expect(
        find.descendant(
          of: find.byKey(const Key('fullscreen-log-error-banner')),
          matching: find.text('安装日志连接已断开'),
        ),
        findsOneWidget,
      );
      expect(_buffer(tester).lines, ['a']);
      expect(find.text('重新安装'), findsNothing);

      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('一行日志都没收到就断线：显示原因，不说成「无安装日志内容」', (tester) async {
    DioClient.instance.dio.httpClientAdapter = _fakePanel(() => 'installing');
    final sse = FakeSseHttpClient((_) => emptyResponse(502));

    await http.runWithClient(() async {
      await _openPage(tester);

      expect(find.text('无安装日志内容'), findsNothing);
      expect(find.text('没有收到安装日志'), findsOneWidget);
      expect(
        find.byKey(const Key('fullscreen-log-error-banner')),
        findsOneWidget,
      );
      expect(find.text('安装日志连接已断开'), findsOneWidget);

      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('没等到 done 帧连接就被掐断：不是「安装完成」', (tester) async {
    DioClient.instance.dio.httpClientAdapter = _fakePanel(() => 'installing');
    final sse = FakeSseHttpClient(
      (_) => sseResponse('data: Collecting requests\n\n'),
    );

    await http.runWithClient(() async {
      await _openPage(tester);

      expect(find.text('安装完成'), findsNothing);
      expect(find.text('连接已断开'), findsOneWidget);
      expect(find.text('日志流已断开，安装可能仍在进行'), findsOneWidget);
      expect(find.text('重新安装'), findsNothing);
      expect(_primaryButton('重新连接'), findsOneWidget);

      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('打开早已装好的依赖：done 帧到达之前也不给「取消安装」', (tester) async {
    DioClient.instance.dio.httpClientAdapter = _fakePanel(() => 'installed');
    final live = _LiveSse();
    final sse = FakeSseHttpClient((_) => live.response());

    await http.runWithClient(() async {
      await _openPage(tester);
      // 面板先重放历史，done 帧随后才到。
      live.push('data: Successfully installed requests\n\n');
      await _pumpFrames(tester);

      expect(find.byKey(const Key('fullscreen-log-stop')), findsNothing);
      expect(find.text('取消安装'), findsNothing);

      live.push('event: done\ndata: installed\n\n');
      await _pumpFrames(tester);
      expect(_primaryButton('重新安装'), findsOneWidget);

      await live.close();
      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('结束帧被丢、只收到 done: closed：胶囊按查到的终态显示', (tester) async {
    // 面板 broadcaster.done() 是非阻塞发送，订阅通道塞满时结束帧会被丢，
    // 随后通道关闭，流里只剩 closed；结果此前已经写进库。
    DioClient.instance.dio.httpClientAdapter = _fakePanel(() => 'failed');
    final sse = FakeSseHttpClient(
      (_) => sseResponse(
        'data: ERROR: No matching distribution\n\n'
        'event: done\ndata: closed\n\n',
      ),
    );

    await http.runWithClient(() async {
      await _openPage(tester);

      expect(find.text('安装失败'), findsOneWidget);
      expect(find.text('已结束'), findsNothing);
      expect(_primaryButton('重新安装'), findsOneWidget);

      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('不认识的结束值：查到终态后胶囊改成对应结果', (tester) async {
    DioClient.instance.dio.httpClientAdapter = _fakePanel(() => 'installed');
    final sse = FakeSseHttpClient(
      (_) => sseResponse(
        'data: Successfully installed requests\n\n'
        'event: done\ndata: archived\n\n',
      ),
    );

    await http.runWithClient(() async {
      await _openPage(tester);

      expect(find.text('安装完成'), findsOneWidget);
      expect(find.text('archived'), findsNothing);
      expect(_primaryButton('重新安装'), findsOneWidget);

      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('done: timeout 时依赖其实已装好：胶囊仍是「连接已断开」', (tester) async {
    // timeout 是断流：日志可能没收全，胶囊和横幅都保持断流口径，
    // 只给「重新连接」把完整日志拉回来。
    DioClient.instance.dio.httpClientAdapter = _fakePanel(() => 'installed');
    final sse = FakeSseHttpClient(
      (_) => sseResponse(
        'data: Building wheel for opencv-python\n\n'
        'event: done\ndata: timeout\n\n',
      ),
    );

    await http.runWithClient(() async {
      await _openPage(tester);

      expect(find.text('连接已断开'), findsOneWidget);
      expect(find.text('安装完成'), findsNothing);
      expect(_primaryButton('重新连接'), findsOneWidget);

      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('卸载成功后只收到 done: closed、记录已删：「卸载完成」，不给按钮', (
    tester,
  ) async {
    String? status = 'removing';
    DioClient.instance.dio.httpClientAdapter = _fakePanel(() => status);
    final live = _LiveSse();
    final sse = FakeSseHttpClient((_) => live.response());

    await http.runWithClient(() async {
      await _openPage(tester);
      live.push('data: Successfully uninstalled requests\n\n');
      await _pumpFrames(tester);
      expect(_primaryButton('取消卸载'), findsOneWidget);

      status = null;
      live.push('event: done\ndata: closed\n\n');
      await _pumpFrames(tester);

      // closed 本身说明不了结果；查到记录没了，这一轮卸载就是成功了。
      expect(_inPill('卸载完成'), findsOneWidget);
      expect(find.text('已结束'), findsNothing);
      // 改之前给「重新连接」，点了只会撞上 log-stream 的 404。
      expect(find.byKey(const Key('fullscreen-log-rerun')), findsNothing);
      expect(find.byKey(const Key('fullscreen-log-stop')), findsNothing);

      await live.close();
      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('卸载中：标题、胶囊都按卸载说；成功（记录已删、done 空串）→「卸载完成」', (
    tester,
  ) async {
    String? status = 'removing';
    DioClient.instance.dio.httpClientAdapter = _fakePanel(() => status);
    final live = _LiveSse();
    final sse = FakeSseHttpClient((_) => live.response());

    await http.runWithClient(() async {
      await _openPage(tester);
      live.push('data: Found existing installation: requests 2.32.3\n\n');
      await _pumpFrames(tester);

      // 改前：标题「安装日志」、胶囊「实时安装中」，旁边却是「取消卸载」。
      expect(find.text('卸载日志'), findsOneWidget);
      expect(find.text('安装日志'), findsNothing);
      expect(_inPill('实时卸载中'), findsOneWidget);
      expect(_primaryButton('取消卸载'), findsOneWidget);

      status = null;
      live.push(
        'data: Successfully uninstalled requests-2.32.3\n\n'
        'event: done\ndata: \n\n',
      );
      await _pumpFrames(tester);

      // 改前：中性的「已结束」。
      expect(_inPill('卸载完成'), findsOneWidget);
      expect(find.byKey(const Key('fullscreen-log-rerun')), findsNothing);

      await live.close();
      await _closePage(tester);
    }, () => sse);
  });

  for (final (done, pill) in [('failed', '卸载失败'), ('cancelled', '已取消')]) {
    testWidgets('卸载以 done: $done 收尾：「$pill」，不说安装、也不给「重新安装」', (
      tester,
    ) async {
      var status = 'removing';
      DioClient.instance.dio.httpClientAdapter = _fakePanel(() => status);
      final live = _LiveSse();
      final sse = FakeSseHttpClient((_) => live.response());

      await http.runWithClient(() async {
        await _openPage(tester);
        live.push('data: ERROR: Cannot uninstall requests\n\n');
        await _pumpFrames(tester);

        status = done;
        live.push('event: done\ndata: $done\n\n');
        await _pumpFrames(tester);

        expect(_inPill(pill), findsOneWidget);
        // 改前：红色「安装失败」+「重新安装」，去重装一个正想卸掉的包。
        expect(find.text('安装失败'), findsNothing);
        expect(find.text('重新安装'), findsNothing);
        expect(find.byKey(const Key('fullscreen-log-rerun')), findsNothing);
        expect(find.text('卸载日志'), findsOneWidget);

        await live.close();
        await _closePage(tester);
      }, () => sse);
    });
  }

  testWidgets('卸载早已完成才点日志：流和状态都回 404 → 绿色「卸载完成」，没有横幅', (
    tester,
  ) async {
    // pip 卸载一两秒就完、记录已删，列表快照却还停在 removing。
    DioClient.instance.dio.httpClientAdapter = _fakePanel(() => null);
    final sse = FakeSseHttpClient((_) => emptyResponse(404));

    await http.runWithClient(() async {
      await _openPage(tester, listed: [_listedDep('removing')]);

      // 改前：红色「连接已断开」+ 横幅「卸载日志连接已断开」。
      expect(_inPill('卸载完成'), findsOneWidget);
      expect(_inPill('连接已断开'), findsNothing);
      expect(
        find.byKey(const Key('fullscreen-log-error-banner')),
        findsNothing,
      );
      expect(find.text('requests 卸载日志'), findsOneWidget);
      expect(find.text('无卸载日志内容'), findsOneWidget);
      expect(find.byKey(const Key('fullscreen-log-rerun')), findsNothing);
      expect(find.byKey(const Key('fullscreen-log-stop')), findsNothing);

      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('列表快照是 removing：输出到达前就按卸载说', (tester) async {
    // 查状态失败（非 404）时保留快照的判断，只剩快照这一条来源。
    DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter(
      (_) => jsonResponse({'error': 'database is locked'}, status: 500),
    );
    final live = _LiveSse();
    final sse = FakeSseHttpClient((_) => live.response());

    await http.runWithClient(() async {
      await _openPage(tester, listed: [_listedDep('removing')]);

      // 还没有任何输出（正文仍是加载圈）。
      expect(find.byType(LogView), findsNothing);
      expect(find.text('requests 卸载日志'), findsOneWidget);
      expect(_inPill('实时卸载中'), findsOneWidget);
      expect(_primaryButton('取消卸载'), findsOneWidget);

      await live.close();
      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('列表没有快照、查状态才知道在卸载：还在跑的胶囊跟着改口', (
    tester,
  ) async {
    DioClient.instance.dio.httpClientAdapter = _fakePanel(() => 'removing');
    final live = _LiveSse();
    final sse = FakeSseHttpClient((_) => live.response());

    await http.runWithClient(() async {
      await _openPage(tester);

      // 流里一行都没有，胶囊只能靠查状态那一步改口。
      expect(find.byType(LogView), findsNothing);
      expect(_inPill('实时卸载中'), findsOneWidget);
      expect(_inPill('实时安装中'), findsNothing);
      expect(find.text('卸载日志'), findsOneWidget);

      await live.close();
      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('done: installing 且没有日志：说明还在等待执行', (tester) async {
    // node / linux 依赖在等包管理器的锁，面板还没建广播，直接回当前状态收流。
    final api = _fakePanel(() => 'installing');
    DioClient.instance.dio.httpClientAdapter = api;
    final sse = FakeSseHttpClient(
      (_) => sseResponse('event: done\ndata: installing\n\n'),
    );

    await http.runWithClient(() async {
      await _openPage(tester);

      expect(find.text('仍在安装'), findsOneWidget);
      expect(find.text('无安装日志内容'), findsNothing);
      expect(find.text('依赖还在等待执行，稍后点「重新连接」查看'), findsOneWidget);
      expect(find.text('重新安装'), findsNothing);
      expect(_primaryButton('重新连接'), findsOneWidget);

      await _closePage(tester);
    }, () => sse);
  });

  group('复制提示', () {
    String? copied;

    setUp(() => copied = null);

    void mockClipboard(WidgetTester tester) {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
    }

    testWidgets('没截断：「安装日志已复制到剪贴板」', (tester) async {
      mockClipboard(tester);
      DioClient.instance.dio.httpClientAdapter = _fakePanel(() => 'installed');
      final sse = FakeSseHttpClient(
        (_) => sseResponse(
          'data: a\n\ndata: b\n\nevent: done\ndata: installed\n\n',
        ),
      );

      await http.runWithClient(() async {
        await _openPage(tester);
        await tester.tap(find.byKey(const Key('fullscreen-log-copy')));
        await tester.pump();

        expect(copied, 'a\nb');
        expect(find.text('安装日志已复制到剪贴板'), findsOneWidget);

        await _closePage(tester);
      }, () => sse);
    });

    testWidgets('超过缓冲区上限：说清复制的是最近 N 行，不再写死「已复制」', (tester) async {
      mockClipboard(tester);
      DioClient.instance.dio.httpClientAdapter = _fakePanel(() => 'installed');
      const total = kLogBufferMaxLines + 5;
      final body = StringBuffer();
      for (var i = 0; i < total; i++) {
        body.write('data: line $i\n\n');
      }
      body.write('event: done\ndata: installed\n\n');
      final sse = FakeSseHttpClient((_) => sseResponse(body.toString()));

      await http.runWithClient(() async {
        await _openPage(tester);
        expect(_buffer(tester).droppedCount, 5);

        await tester.tap(find.byKey(const Key('fullscreen-log-copy')));
        await tester.pump();

        expect(copied!.split('\n'), hasLength(kLogBufferMaxLines));
        expect(find.text('已复制最近 $kLogBufferMaxLines 行'), findsOneWidget);
        expect(find.text('安装日志已复制到剪贴板'), findsNothing);

        await _closePage(tester);
      }, () => sse);
    });
  });
}
