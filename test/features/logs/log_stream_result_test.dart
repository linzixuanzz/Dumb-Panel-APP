import 'dart:async';
import 'dart:convert';

import 'package:daidai_app/core/auth/auth_provider.dart';
import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/network/dio_client.dart';
import 'package:daidai_app/features/logs/views/log_stream_page.dart';
import 'package:daidai_app/shared/models/user.dart';
import 'package:daidai_app/shared/utils/log_line_buffer.dart';
import 'package:daidai_app/shared/utils/panel_enums.dart';
import 'package:daidai_app/shared/widgets/log_view.dart';
import 'package:dio/dio.dart' show ResponseBody;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_http_adapter.dart';
import '../../support/fake_sse_http_client.dart';

const _logId = 7;
const _taskId = 12;

/// 直接处于已登录的 operator 状态：停止 / 重新运行要 operator。
class _OperatorNotifier extends AuthNotifier {
  _OperatorNotifier(super.authService) {
    state = AuthState(
      status: AuthStatus.authenticated,
      user: User(
        id: 1,
        username: 'tester',
        role: 'operator',
        enabled: true,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
    );
  }
}

/// 面板日志详情（`GET /api/logs/:id`）。status 是 task_logs.status：
/// 0 成功 / 1 失败 / 2 运行中 / 3 已终止。
ResponseBody _detail(int status, {String logPath = 'task_12/run.log'}) =>
    jsonResponse({
      'data': {
        'id': _logId,
        'task_id': _taskId,
        'task_name': '京东签到',
        'content': '',
        'status': status,
        'duration': status == kLogStatusRunning ? null : 3.2,
        'log_path': logPath,
        'started_at': '2026-11-20T10:00:00Z',
        'created_at': '2026-11-20T10:00:00Z',
      },
    });

/// 照面板 SSE 的线格式：每行一条 data，后面跟一条空 data 行。
String _lines(Iterable<String> lines) =>
    lines.map((line) => 'data: $line\ndata: \n\n').join();

const _doneFinished = 'event: done\ndata: finished\n\n';

/// 一条一直开着、由测试决定何时推什么的 SSE。
class _LiveSse {
  final _controller = StreamController<List<int>>();
  late final FakeSseHttpClient client = FakeSseHttpClient(
    (_) => http.StreamedResponse(
      _controller.stream,
      200,
      headers: const {'content-type': 'text/event-stream'},
    ),
  );

  void push(String frame) => _controller.add(utf8.encode(frame));

  Future<void> end() => _controller.close();

  /// 网络断了：SseClient 收到流错误（cancelOnError），回调页面的 onError。
  void fail() => _controller.addError(Exception('连接被重置'));
}

Future<void> _pump(WidgetTester tester, Duration total) async {
  final steps = total.inMilliseconds ~/ 20;
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// 打开页面并推到假 HTTP / 假 SSE 都跑完。运行中有常驻的呼吸动画，不能 pumpAndSettle。
Future<void> _openPage(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(
          (ref) => _OperatorNotifier(ref.read(authServiceProvider)),
        ),
      ],
      child: const MaterialApp(home: LogStreamPage(logId: _logId)),
    ),
  );
  await _pump(tester, const Duration(milliseconds: 400));
}

/// 收掉页面并把提示条、重连这类定时器都放完。
Future<void> _closePage(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

Finder _inPill(Finder matching) => find.descendant(
  of: find.byKey(const Key('fullscreen-log-status-pill')),
  matching: matching,
);

LogLineBuffer _buffer(WidgetTester tester) =>
    tester.widget<LogView>(find.byType(LogView)).buffer;

/// 面板的 done:finished 只表示 TinyLog 关了、流结束了，不带成败
/// （panel-contract.md「实时日志」）。日志详情页流结束后要重新取日志详情，
/// 按面板记录的状态决定绿 / 红；拿不到就停在中性的「已结束」。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues({});
    DioClient.instance.setBaseUrl('https://panel.test');
  });

  testWidgets('脚本失败退出：done:finished 之后按详情显示红色「失败」，不打绿色对勾', (tester) async {
    var detailCalls = 0;
    final api = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.logById(_logId)) {
        detailCalls++;
        // 第 1 次是打开页面（还在跑），之后是流结束后的结算。
        return _detail(detailCalls == 1 ? kLogStatusRunning : kLogStatusFailed);
      }
      return jsonResponse(<String, dynamic>{});
    });
    DioClient.instance.dio.httpClientAdapter = api;
    final sse = FakeSseHttpClient(
      (_) => sseResponse(
        '${_lines(['开始签到', 'TypeError: x is undefined', '退出码: 1'])}'
        '$_doneFinished',
      ),
    );

    await http.runWithClient(() async {
      await _openPage(tester);
      await _pump(tester, kLogSettleRetryDelay);

      expect(_inPill(find.text('失败')), findsOneWidget);
      expect(_inPill(find.byIcon(Icons.close_rounded)), findsOneWidget);
      // 改前：done:finished 被直接写成 kLogStatusSuccess，胶囊是绿色「✓ 已完成」。
      expect(_inPill(find.byIcon(Icons.check_rounded)), findsNothing);
      expect(find.text('已完成'), findsNothing);
      expect(api.countOf(ApiEndpoints.logById(_logId)), 2);
      expect(find.textContaining('耗时'), findsOneWidget);

      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('正常跑完：按详情显示绿色「成功」', (tester) async {
    var detailCalls = 0;
    DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.logById(_logId)) {
        detailCalls++;
        return _detail(
          detailCalls == 1 ? kLogStatusRunning : kLogStatusSuccess,
        );
      }
      return jsonResponse(<String, dynamic>{});
    });
    final sse = FakeSseHttpClient(
      (_) => sseResponse('${_lines(['签到成功'])}$_doneFinished'),
    );

    await http.runWithClient(() async {
      await _openPage(tester);
      await _pump(tester, kLogSettleRetryDelay);

      expect(_inPill(find.text('成功')), findsOneWidget);
      expect(_inPill(find.byIcon(Icons.check_rounded)), findsOneWidget);

      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('结果晚一拍才写进库：结算时还是运行中就隔一会儿再查', (tester) async {
    // 面板先关 TinyLog（SSE 随即发 done）、再写 task_logs.status。
    var detailCalls = 0;
    final api = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.logById(_logId)) {
        detailCalls++;
        return _detail(detailCalls <= 2 ? kLogStatusRunning : kLogStatusFailed);
      }
      return jsonResponse(<String, dynamic>{});
    });
    DioClient.instance.dio.httpClientAdapter = api;
    final sse = FakeSseHttpClient(
      (_) => sseResponse('${_lines(['line'])}$_doneFinished'),
    );

    await http.runWithClient(() async {
      await _openPage(tester);
      // 流一结束先是中性的「已结束」。
      expect(_inPill(find.text('已结束')), findsOneWidget);
      expect(_inPill(find.byIcon(Icons.check_rounded)), findsNothing);

      // 第一次结算还是运行中：仍是「已结束」。
      await _pump(tester, kLogSettleRetryDelay);
      expect(api.countOf(ApiEndpoints.logById(_logId)), 2);
      expect(_inPill(find.text('已结束')), findsOneWidget);

      await _pump(tester, kLogSettleRetryDelay);
      expect(_inPill(find.text('失败')), findsOneWidget);
      expect(api.countOf(ApiEndpoints.logById(_logId)), 3);

      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('详情一直是运行中：查满次数后停在中性「已结束」，不猜成败', (tester) async {
    final api = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.logById(_logId)) {
        return _detail(kLogStatusRunning);
      }
      return jsonResponse(<String, dynamic>{});
    });
    DioClient.instance.dio.httpClientAdapter = api;
    final sse = FakeSseHttpClient(
      (_) => sseResponse('${_lines(['line'])}$_doneFinished'),
    );

    await http.runWithClient(() async {
      await _openPage(tester);
      await _pump(tester, kLogSettleRetryDelay * (kLogSettleAttempts + 2));

      expect(_inPill(find.text('已结束')), findsOneWidget);
      expect(_inPill(find.byIcon(Icons.check_rounded)), findsNothing);
      expect(_inPill(find.byIcon(Icons.close_rounded)), findsNothing);
      // 打开 1 次 + 结算 kLogSettleAttempts 次，之后不再查。
      expect(
        api.countOf(ApiEndpoints.logById(_logId)),
        1 + kLogSettleAttempts,
      );

      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('停止运行后：收尾输出照常追加、不改回「运行中」，随后的 done 不显示成功', (
    tester,
  ) async {
    var stopped = false;
    final api = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.logById(_logId)) {
        // 面板的停止接口返回前就把这条运行中的日志记成了「已终止」。
        return _detail(stopped ? kLogStatusAborted : kLogStatusRunning);
      }
      if (options.path == ApiEndpoints.taskStop(_taskId)) {
        stopped = true;
        return jsonResponse({'message': '任务已停止'});
      }
      if (options.path == ApiEndpoints.tasks) {
        return jsonResponse({'data': <Object>[], 'total': 0});
      }
      return jsonResponse(<String, dynamic>{});
    });
    DioClient.instance.dio.httpClientAdapter = api;
    final sse = _LiveSse();

    await http.runWithClient(() async {
      await _openPage(tester);
      sse.push(_lines(['line 0', 'line 1']));
      await _pump(tester, const Duration(milliseconds: 100));
      expect(_inPill(find.text('运行中')), findsOneWidget);

      await tester.tap(find.byKey(const Key('fullscreen-log-stop')));
      await _pump(tester, const Duration(milliseconds: 200));
      expect(_inPill(find.text('已停止')), findsOneWidget);
      expect(find.byKey(const Key('fullscreen-log-rerun')), findsOneWidget);

      // 面板先发 TERM、留宽限：收尾输出还会送来。
      sse.push(_lines(['收到 SIGTERM，正在收尾', '[任务已被手动停止]']));
      await _pump(tester, const Duration(milliseconds: 100));
      expect(_buffer(tester).lines.last, '[任务已被手动停止]');
      // 改前：数据行把状态改回「运行中」，旁边却挂着「重新运行」。
      expect(_inPill(find.text('运行中')), findsNothing);
      expect(_inPill(find.text('已停止')), findsOneWidget);

      sse.push(_doneFinished);
      await sse.end();
      await _pump(
        tester,
        kLogSettleRetryDelay + const Duration(milliseconds: 200),
      );
      // 改前：done:finished 把用户主动停止的运行改成绿色「✓ 已完成」。
      expect(_inPill(find.byIcon(Icons.check_rounded)), findsNothing);
      expect(_inPill(find.text('已终止')), findsOneWidget);

      await _closePage(tester);
    }, () => sse.client);
  });

  testWidgets('停止接口在途时 done 先到：不闪成功，结果仍按详情结算', (tester) async {
    var stopped = false;
    final api = FakeHttpAdapter((options) async {
      if (options.path == ApiEndpoints.logById(_logId)) {
        return _detail(stopped ? kLogStatusAborted : kLogStatusRunning);
      }
      if (options.path == ApiEndpoints.taskStop(_taskId)) {
        stopped = true;
        return jsonResponse({'message': '任务已停止'});
      }
      if (options.path == ApiEndpoints.tasks) {
        // stopTask 还要等任务列表刷新完：这一段里 done 先到。
        await Future<void>.delayed(const Duration(seconds: 1));
        return jsonResponse({'data': <Object>[], 'total': 0});
      }
      return jsonResponse(<String, dynamic>{});
    });
    DioClient.instance.dio.httpClientAdapter = api;
    final sse = _LiveSse();

    await http.runWithClient(() async {
      await _openPage(tester);
      sse.push(_lines(['line 0']));
      await _pump(tester, const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('fullscreen-log-stop')));
      await _pump(tester, const Duration(milliseconds: 100));
      sse.push(_doneFinished);
      await sse.end();
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        expect(_inPill(find.byIcon(Icons.check_rounded)), findsNothing);
      }

      expect(_inPill(find.text('已终止')), findsOneWidget);

      await _closePage(tester);
    }, () => sse.client);
  });

  testWidgets('流结束后先等一拍再查详情：刚收到 done 就查，大日志会白下一遍全文', (
    tester,
  ) async {
    var detailCalls = 0;
    final api = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.logById(_logId)) {
        detailCalls++;
        return _detail(detailCalls == 1 ? kLogStatusRunning : kLogStatusFailed);
      }
      return jsonResponse(<String, dynamic>{});
    });
    DioClient.instance.dio.httpClientAdapter = api;
    final sse = _LiveSse();

    await http.runWithClient(() async {
      await _openPage(tester);
      sse.push(_lines(['line 0']));
      sse.push(_doneFinished);
      await sse.end();
      await _pump(tester, const Duration(milliseconds: 100));

      // 面板这时还在读文件、压缩，详情多半还是「运行中」、带着从 log_path 读的
      // 整份日志。改前：done 一到就查，这一跳几乎总是白下。
      expect(api.countOf(ApiEndpoints.logById(_logId)), 1);
      expect(_inPill(find.text('已结束')), findsOneWidget);

      await _pump(tester, kLogSettleRetryDelay);
      expect(api.countOf(ApiEndpoints.logById(_logId)), 2);
      expect(_inPill(find.text('失败')), findsOneWidget);

      await _closePage(tester);
    }, () => sse.client);
  });

  testWidgets('没收到 done 流就断了：只看一眼详情，还在跑就停在「连接结束」', (tester) async {
    final api = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.logById(_logId)) {
        return _detail(kLogStatusRunning);
      }
      return jsonResponse(<String, dynamic>{});
    });
    DioClient.instance.dio.httpClientAdapter = api;
    final sse = _LiveSse();

    await http.runWithClient(() async {
      await _openPage(tester);
      sse.push(_lines(['line 0']));
      await _pump(tester, const Duration(milliseconds: 100));
      // 反代掐了长连接：干净断开、没有 done，任务多半还在跑。
      await sse.end();
      await _pump(tester, kLogSettleRetryDelay * (kLogSettleAttempts + 2));

      expect(_inPill(find.text('连接结束')), findsOneWidget);
      // 打开 1 次 + 看一眼 1 次。改前：按收口的节奏查满 kLogSettleAttempts 次，
      // 运行中的详情每次都是整份日志。
      expect(api.countOf(ApiEndpoints.logById(_logId)), 2);

      await _closePage(tester);
    }, () => sse.client);
  });

  testWidgets('停止之后 SSE 断了：保留「已停止」、不报连接错误，再按详情结算成「已终止」', (
    tester,
  ) async {
    var stopped = false;
    final api = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.logById(_logId)) {
        return _detail(stopped ? kLogStatusAborted : kLogStatusRunning);
      }
      if (options.path == ApiEndpoints.taskStop(_taskId)) {
        stopped = true;
        return jsonResponse({'message': '任务已停止'});
      }
      if (options.path == ApiEndpoints.tasks) {
        return jsonResponse({'data': <Object>[], 'total': 0});
      }
      return jsonResponse(<String, dynamic>{});
    });
    DioClient.instance.dio.httpClientAdapter = api;
    final sse = _LiveSse();

    await http.runWithClient(() async {
      await _openPage(tester);
      sse.push(_lines(['line 0']));
      await _pump(tester, const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('fullscreen-log-stop')));
      await _pump(tester, const Duration(milliseconds: 200));
      expect(_inPill(find.text('已停止')), findsOneWidget);

      sse.fail();
      await _pump(tester, const Duration(milliseconds: 100));
      expect(_inPill(find.text('连接错误')), findsNothing);
      expect(_inPill(find.text('已停止')), findsOneWidget);

      // 不会再有 done 了：直接按详情结算。
      await _pump(tester, kLogSettleRetryDelay);
      expect(_inPill(find.text('已终止')), findsOneWidget);
      expect(api.countOf(ApiEndpoints.logById(_logId)), 2);

      await _closePage(tester);
    }, () => sse.client);
  });

  testWidgets('停止请求在途时 SSE 断了、停止也失败（同一次断网）：显示「连接错误」', (
    tester,
  ) async {
    var detailCalls = 0;
    final api = FakeHttpAdapter((options) async {
      if (options.path == ApiEndpoints.logById(_logId)) {
        detailCalls++;
        if (detailCalls == 1) return _detail(kLogStatusRunning);
        throw Exception('网络不可达');
      }
      if (options.path == ApiEndpoints.taskStop(_taskId)) {
        await Future<void>.delayed(const Duration(seconds: 1));
        throw Exception('网络不可达');
      }
      return jsonResponse(<String, dynamic>{});
    });
    DioClient.instance.dio.httpClientAdapter = api;
    final sse = _LiveSse();

    await http.runWithClient(() async {
      await _openPage(tester);
      sse.push(_lines(['line 0']));
      await _pump(tester, const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('fullscreen-log-stop')));
      await _pump(tester, const Duration(milliseconds: 100));
      sse.fail();
      await _pump(tester, const Duration(milliseconds: 100));
      // 停止请求还在途：先让位给「已停止」。
      expect(_inPill(find.text('已停止')), findsOneWidget);

      await _pump(tester, const Duration(milliseconds: 1200));
      // 改前：出错被「停止了」压下去，停止失败后胶囊停在中性的「运行中」，
      // 旁边却挂着「重新运行」。
      expect(_inPill(find.text('连接错误')), findsOneWidget);
      expect(_inPill(find.byIcon(Icons.close_rounded)), findsOneWidget);
      expect(_inPill(find.text('运行中')), findsNothing);

      await _closePage(tester);
    }, () => sse.client);
  });

  testWidgets('停止请求在途时 done 先到、停止却失败：拿不到结果就是「已结束」，不停在「已停止」', (
    tester,
  ) async {
    var detailCalls = 0;
    final api = FakeHttpAdapter((options) async {
      if (options.path == ApiEndpoints.logById(_logId)) {
        detailCalls++;
        if (detailCalls == 1) return _detail(kLogStatusRunning);
        throw Exception('网络不可达');
      }
      if (options.path == ApiEndpoints.taskStop(_taskId)) {
        await Future<void>.delayed(const Duration(seconds: 1));
        throw Exception('网络不可达');
      }
      return jsonResponse(<String, dynamic>{});
    });
    DioClient.instance.dio.httpClientAdapter = api;
    final sse = _LiveSse();

    await http.runWithClient(() async {
      await _openPage(tester);
      sse.push(_lines(['line 0']));
      await _pump(tester, const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('fullscreen-log-stop')));
      await _pump(tester, const Duration(milliseconds: 100));
      sse.push(_doneFinished);
      await sse.end();
      await _pump(tester, const Duration(milliseconds: 100));
      expect(_inPill(find.text('已停止')), findsOneWidget);

      await _pump(tester, kLogSettleRetryDelay * (kLogSettleAttempts + 2));
      // 改前：停止失败只把标志放下，胶囊一直写着「已停止」。
      expect(_inPill(find.text('已结束')), findsOneWidget);
      expect(_inPill(find.text('已停止')), findsNothing);

      await _closePage(tester);
    }, () => sse.client);
  });

  testWidgets('下载原始日志期间 ⋮ 换成小转圈（菜单关了也看得到进度）', (tester) async {
    DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter((
      options,
    ) async {
      if (options.path == ApiEndpoints.logById(_logId)) {
        return _detail(kLogStatusSuccess);
      }
      if (options.path == ApiEndpoints.logRawTicket(_logId)) {
        // 签票据很慢（几十 MB 的原始日志要先整个拉完才弹保存框，这里用慢票据代替）。
        await Future<void>.delayed(const Duration(seconds: 2));
        return jsonResponse({'error': '日志文件已被清理'}, status: 404);
      }
      return jsonResponse(<String, dynamic>{});
    });
    final menuSpinner = find.descendant(
      of: find.byKey(const Key('fullscreen-log-menu')),
      matching: find.byType(CircularProgressIndicator),
    );

    await _openPage(tester);
    expect(menuSpinner, findsNothing);

    await tester.tap(find.byKey(const Key('fullscreen-log-menu')));
    await _pump(tester, const Duration(milliseconds: 400));
    await tester.tap(find.text('下载原始日志'));
    await _pump(tester, const Duration(milliseconds: 400));

    // 改前：菜单一关，页面上没有任何进度反馈。
    expect(menuSpinner, findsOneWidget);

    await _pump(tester, const Duration(seconds: 2));
    expect(menuSpinner, findsNothing);

    await _closePage(tester);
  });

  testWidgets('运行中越过 1 万行上限后复制：提示在点击那一刻按缓冲区现算，带下载引导', (
    tester,
  ) async {
    DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.logById(_logId)) {
        return _detail(kLogStatusRunning);
      }
      return jsonResponse(<String, dynamic>{});
    });
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final sse = _LiveSse();

    await http.runWithClient(() async {
      await _openPage(tester);
      // 页面最后一次重建发生在第一批行到来时，那时还没截断。
      sse.push(_lines(List<String>.generate(10, (i) => 'line $i')));
      await _pump(tester, const Duration(milliseconds: 100));

      // 之后一直「运行中」，页面不再重建。
      final total = kLogBufferMaxLines + 50;
      sse.push(
        _lines(List<String>.generate(total - 10, (i) => 'line ${i + 10}')),
      );
      await _pump(tester, const Duration(milliseconds: 200));
      expect(_buffer(tester).droppedCount, greaterThan(0));

      await tester.tap(find.byKey(const Key('fullscreen-log-copy')));
      await tester.pump();
      // 改前：build 时定死的「日志已复制到剪贴板」。
      expect(
        find.text('已复制最近 $kLogBufferMaxLines 行，完整日志请下载原始日志'),
        findsOneWidget,
      );

      await _closePage(tester);
    }, () => sse.client);
  });
}
