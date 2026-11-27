import 'dart:async';
import 'dart:convert';

import 'package:daidai_app/core/auth/auth_provider.dart';
import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/network/dio_client.dart';
import 'package:daidai_app/features/logs/views/log_stream_page.dart'
    show kLogSettleAttempts, kLogSettleRetryDelay;
import 'package:daidai_app/features/tasks/views/task_list_page.dart';
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

const _taskId = 12;

/// 真实任务输出的样子：一行里有中文，按字节截断时首行常常是半截。
List<String> _history(int count) => List<String>.generate(
  count,
  (i) => '第$i轮 【京东签到】签到 获得京豆 ${10000 + i} 任务完成 line $i',
);

/// 照面板 live-logs 的做法：TinyLog.ReadLastLines 只读文件最后 4096 字节再按换行切。
List<String> _liveLogsSnapshot(List<String> lines) {
  final bytes = utf8.encode('${lines.join('\n')}\n');
  final start = bytes.length > 4096 ? bytes.length - 4096 : 0;
  return utf8.decode(bytes.sublist(start), allowMalformed: true).split('\n');
}

/// 4KB 边界恰好落在第 2 行行首的历史：共 65 行，后 64 行每行连换行正好 64 字节、合计 4096 字节，
/// 所以 live-logs 快照里每一行都完整，正好是「历史去掉第 1 行」。
List<String> _historyAlignedAtSecondLine() => List<String>.generate(65, (i) {
  final text = '第$i轮 【京东签到】签到成功 line $i ';
  // 补到 63 字节，加上换行正好 64（中文在 UTF-8 里每个字 3 字节）。
  return '$text${'.' * (63 - utf8.encode(text).length)}';
});

/// 照面板 SSE 推整段历史的做法：一个帧、每行一条 data（writeSSEData）。
String _historyFrame(List<String> lines) {
  final frame = StringBuffer();
  for (final line in '${lines.join('\n')}\n'.split('\n')) {
    frame.write('data: $line\n');
  }
  frame.write('\n');
  return frame.toString();
}

/// 先把 [body] 推完，再报一次网络错误（模拟 SSE 中途断线）。
http.StreamedResponse _sseThenError(String body) {
  final controller = StreamController<List<int>>();
  controller
    ..add(utf8.encode(body))
    ..addError(Exception('连接被重置'))
    ..close();
  return http.StreamedResponse(
    controller.stream,
    200,
    headers: const {'content-type': 'text/event-stream'},
  );
}

/// live-logs 的响应；面板按「任务状态不是运行中」给 done。
ResponseBody _liveLogs(List<String> logs, {required double status}) =>
    jsonResponse({
      'data': {'logs': logs, 'done': status != 2, 'status': status},
    });

/// latest-log 的响应：这条任务最近一次运行的完整日志。
/// [status] 是 task_logs.status：0 成功 / 1 失败 / 2 运行中 / 3 已终止。
ResponseBody _latestLog(List<String> lines, {int status = kLogStatusSuccess}) =>
    jsonResponse({
      'data': {
        'id': 7,
        'task_id': _taskId,
        'status': status,
        'content': '${lines.join('\n')}\n',
      },
    });

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

/// 照面板 SSE 的实时行：每行一帧，行尾换行切出一条空 data 行。
String _liveLines(Iterable<String> lines) =>
    lines.map((line) => 'data: $line\ndata: \n\n').join();

Finder _inPill(Finder matching) => find.descendant(
  of: find.byKey(const Key('fullscreen-log-status-pill')),
  matching: matching,
);

/// 打开页面并推到假 HTTP / 假 SSE 都跑完。AppBar 里有常驻的转圈，不能 pumpAndSettle。
/// [operator] 为 true 时以 operator 登录（底栏才有停止 / 重新运行）。
Future<void> _openPage(WidgetTester tester, {bool operator = false}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (operator)
          authProvider.overrideWith(
            (ref) => _OperatorNotifier(ref.read(authServiceProvider)),
          ),
      ],
      child: const MaterialApp(
        home: TaskLiveLogPage(taskId: _taskId, taskName: '京东签到'),
      ),
    ),
  );
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// 收掉页面并把提示条、重连这类定时器都放完，免得测试结束时还挂着。
Future<void> _closePage(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 3));
}

LogLineBuffer _buffer(WidgetTester tester) =>
    tester.widget<LogView>(find.byType(LogView)).buffer;

/// APP #15 的 B4 与 R3′：TaskLiveLogPage 打开时先显示 live-logs 的快照（实时日志文件的
/// 最后 4KB），但不再把它当成 SSE 重放的前缀去去重；第一条 SSE 数据来了整段换掉。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues({});
    DioClient.instance.setBaseUrl('https://panel.test');
  });

  testWidgets('运行中：4KB 快照不再和 SSE 历史叠成两份，「复制全部」正好是那 300 行', (tester) async {
    final history = _history(300);
    DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.taskLiveLogs(_taskId)) {
        return _liveLogs(_liveLogsSnapshot(history), status: 2);
      }
      return jsonResponse(<String, dynamic>{});
    });
    final sse = FakeSseHttpClient((_) => sseResponse(_historyFrame(history)));
    String? copied;
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

    await http.runWithClient(() async {
      await _openPage(tester);

      expect(sse.requests, hasLength(1));
      // 改之前是快照约 60 行 + 整段历史 300 行，首行还是半截。
      expect(_buffer(tester).totalCount, 300);
      expect(_buffer(tester).lines.first, history.first);

      await tester.tap(find.byKey(const Key('fullscreen-log-copy')));
      await tester.pump();
      expect(copied, history.join('\n'));

      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('4KB 边界恰好落在第 2 行行首：快照不拿去去重，SSE 重放的历史一行都不被吞', (tester) async {
    // 钉住 _resetReplayBuffer 里「正文还是快照就不交给 SseReplayBuffer」那道保护。
    // 这里的快照每一行都完整、正好是历史第 2 行起的全部内容。SseClient 每条 data 行单独回调一次：
    // 要是快照被当成去重前缀，第 1 行换掉正文之后，第 2 行起逐行都和快照对得上，
    // 会被当成重放整段吞掉，正文只剩第 1 行。上面那条用例的快照首行是半截，第一处就对不上，钉不住它。
    final history = _historyAlignedAtSecondLine();
    final snapshot = _liveLogsSnapshot(history);
    // 前提自检：快照确实从第 2 行开始、每行完整（最后的空串是结尾换行切出来的）。
    expect(snapshot, [...history.skip(1), '']);

    DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.taskLiveLogs(_taskId)) {
        return _liveLogs(snapshot, status: 2);
      }
      return jsonResponse(<String, dynamic>{});
    });
    final sse = FakeSseHttpClient((_) => sseResponse(_historyFrame(history)));

    await http.runWithClient(() async {
      await _openPage(tester);

      expect(sse.requests, hasLength(1));
      expect(_buffer(tester).totalCount, history.length);
      expect(_buffer(tester).lines, history);

      await _closePage(tester);
    }, () => sse);
  });

  for (final payload in ['finished', 'finished-late']) {
    testWidgets('live-logs 说还在跑、SSE 连上时已结束（只回 done:$payload）：不空白，回落到最近一次日志拿全量', (
      tester,
    ) async {
      final history = _history(300);
      final api = FakeHttpAdapter((options) {
        if (options.path == ApiEndpoints.taskLiveLogs(_taskId)) {
          return _liveLogs(_liveLogsSnapshot(history), status: 2);
        }
        if (options.path == ApiEndpoints.taskLatestLog(_taskId)) {
          return _latestLog(history);
        }
        return jsonResponse(<String, dynamic>{});
      });
      DioClient.instance.dio.httpClientAdapter = api;
      final sse = FakeSseHttpClient(
        (_) => sseResponse('event: done\ndata: $payload\n\n'),
      );

      await http.runWithClient(() async {
        await _openPage(tester);
        // 结算先等一拍再查 latest-log（面板这时还在写结果）。
        await tester.pump(kLogSettleRetryDelay);

        expect(find.text('无日志内容'), findsNothing);
        expect(find.text('已完成'), findsOneWidget);
        expect(api.countOf(ApiEndpoints.taskLatestLog(_taskId)), 1);
        expect(_buffer(tester).lines, history);

        await _closePage(tester);
      }, () => sse);
    });
  }

  testWidgets('SSE 只回 done、最近一次日志也拿不到：至少留着快照，不出现空白', (tester) async {
    // 短任务的日志不到 4KB 时，快照本身就是全量。
    final history = _history(40);
    final snapshot = _liveLogsSnapshot(history);
    DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.taskLiveLogs(_taskId)) {
        return _liveLogs(snapshot, status: 2);
      }
      if (options.path == ApiEndpoints.taskLatestLog(_taskId)) {
        return jsonResponse({'error': '该任务还没有日志记录'}, status: 404);
      }
      return jsonResponse(<String, dynamic>{});
    });
    final sse = FakeSseHttpClient(
      (_) => sseResponse('event: done\ndata: finished\n\n'),
    );

    await http.runWithClient(() async {
      await _openPage(tester);

      expect(find.text('无日志内容'), findsNothing);
      expect(_buffer(tester).lines, history);

      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('SSE 断线后降级轮询、再连上：已有的 SSE 内容不被快照覆盖，重放的行照样去重', (tester) async {
    final first = _history(300);
    final all = _history(305);
    final api = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.taskLiveLogs(_taskId)) {
        return _liveLogs(_liveLogsSnapshot(all), status: 2);
      }
      if (options.path == ApiEndpoints.taskLatestLog(_taskId)) {
        // 结算只取结果：正文是 SSE 来的，latest-log 的正文不拿来换。
        return _latestLog(_history(310));
      }
      return jsonResponse(<String, dynamic>{});
    });
    DioClient.instance.dio.httpClientAdapter = api;
    var connections = 0;
    final sse = FakeSseHttpClient((_) {
      connections++;
      // 第一次推完 300 行就断线；轮询发现还在跑，再连时面板从第一行重放、多了 5 行。
      return connections == 1
          ? _sseThenError(_historyFrame(first))
          : sseResponse(
              '${_historyFrame(all)}event: done\ndata: finished\n\n',
            );
    });

    await http.runWithClient(() async {
      await _openPage(tester);
      expect(_buffer(tester).totalCount, 300);

      // 轮询一秒一次。
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(connections, 2);
      // 改之前：轮询先用快照（约 60 行）把正文整个换掉，再连时去重第一行就对不上，
      // 变成快照 + 305 行。
      expect(_buffer(tester).lines, all);
      expect(find.text('已完成'), findsOneWidget);
      expect(api.countOf(ApiEndpoints.taskLatestLog(_taskId)), 1);

      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('刚跑完的任务（live-logs 已空）：等不到实时日志就回落到最近一次日志', (tester) async {
    final history = _history(30);
    final api = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.taskLiveLogs(_taskId)) {
        return _liveLogs(const <String>[], status: 1);
      }
      if (options.path == ApiEndpoints.taskLatestLog(_taskId)) {
        return _latestLog(history);
      }
      return jsonResponse(<String, dynamic>{});
    });
    DioClient.instance.dio.httpClientAdapter = api;
    final sse = FakeSseHttpClient((_) => sseResponse(''));

    await http.runWithClient(() async {
      await _openPage(tester);
      // 轮询 15 次（每秒一次）后放弃，放弃时回落一次。
      for (var s = 0; s < 17; s++) {
        await tester.pump(const Duration(seconds: 1));
      }

      expect(api.countOf(ApiEndpoints.taskLatestLog(_taskId)), 1);
      expect(_buffer(tester).lines, history);
      expect(find.text('已完成'), findsOneWidget);
      expect(find.text('等待日志输出...'), findsNothing);

      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('刚跑完 + 网慢（live-logs 每次 1.5 秒）：只回落一次，晚到的轮询结果不再盖掉正文、也不重开轮询', (
    tester,
  ) async {
    final history = _history(30);
    var liveCalls = 0;
    final api = FakeHttpAdapter((options) async {
      if (options.path == ApiEndpoints.taskLiveLogs(_taskId)) {
        liveCalls++;
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        return _liveLogs(const <String>[], status: 1);
      }
      if (options.path == ApiEndpoints.taskLatestLog(_taskId)) {
        return _latestLog(history);
      }
      return jsonResponse(<String, dynamic>{});
    });
    DioClient.instance.dio.httpClientAdapter = api;
    final sse = FakeSseHttpClient((_) => sseResponse(''));

    await http.runWithClient(() async {
      await _openPage(tester);
      // 请求比轮询间隔慢，放弃时上一跳还在路上。
      for (var s = 0; s < 20; s++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(api.countOf(ApiEndpoints.taskLatestLog(_taskId)), 1);
      expect(_buffer(tester).lines, history);
      final callsAfterGiveUp = liveCalls;

      // 改之前：晚到的那一跳拿空快照把正文清掉、又开一轮轮询，十几秒后再回落一次，一直循环。
      for (var s = 0; s < 20; s++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(liveCalls, callsAfterGiveUp);
      expect(api.countOf(ApiEndpoints.taskLatestLog(_taskId)), 1);
      expect(_buffer(tester).lines, history);
      expect(find.text('已完成'), findsOneWidget);

      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('刚跑完、最近一次日志也拿不到：AppBar 说「暂无日志」，正文不再挂着「等待日志输出...」', (
    tester,
  ) async {
    DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.taskLiveLogs(_taskId)) {
        return _liveLogs(const <String>[], status: 1);
      }
      if (options.path == ApiEndpoints.taskLatestLog(_taskId)) {
        return jsonResponse({'error': '该任务还没有日志记录'}, status: 404);
      }
      return jsonResponse(<String, dynamic>{});
    });
    final sse = FakeSseHttpClient((_) => sseResponse(''));

    await http.runWithClient(() async {
      await _openPage(tester);
      for (var s = 0; s < 17; s++) {
        await tester.pump(const Duration(seconds: 1));
      }

      expect(find.text('暂无日志'), findsOneWidget);
      expect(find.text('无日志内容'), findsOneWidget);
      expect(find.text('等待日志输出...'), findsNothing);
      // 不再等了，AppBar 也别再转圈。
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('一直在排队的任务等不到日志时不回落：那时拿到的会是上一次运行的日志', (tester) async {
    final api = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.taskLiveLogs(_taskId)) {
        return _liveLogs(const <String>[], status: 0.5);
      }
      if (options.path == ApiEndpoints.taskLatestLog(_taskId)) {
        return _latestLog(_history(30));
      }
      return jsonResponse(<String, dynamic>{});
    });
    DioClient.instance.dio.httpClientAdapter = api;
    final sse = FakeSseHttpClient((_) => sseResponse(''));

    await http.runWithClient(() async {
      await _openPage(tester);
      for (var s = 0; s < 17; s++) {
        await tester.pump(const Duration(seconds: 1));
      }

      expect(api.countOf(ApiEndpoints.taskLatestLog(_taskId)), 0);
      expect(find.text('暂无日志'), findsOneWidget);
      expect(find.text('无日志内容'), findsOneWidget);

      await _closePage(tester);
    }, () => sse);
  });

  // ── 终态的语义：done:finished 只表示流结束、不带成败（panel-contract.md「实时日志」）──

  testWidgets('脚本失败退出：流结束后按 latest-log 显示红色「失败」，不打绿色对勾', (tester) async {
    final history = _history(30);
    final api = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.taskLiveLogs(_taskId)) {
        return _liveLogs(_liveLogsSnapshot(history), status: 2);
      }
      if (options.path == ApiEndpoints.taskLatestLog(_taskId)) {
        return _latestLog(history, status: kLogStatusFailed);
      }
      return jsonResponse(<String, dynamic>{});
    });
    DioClient.instance.dio.httpClientAdapter = api;
    final sse = FakeSseHttpClient(
      (_) => sseResponse(
        '${_historyFrame(history)}event: done\ndata: finished\n\n',
      ),
    );

    await http.runWithClient(() async {
      await _openPage(tester);
      // 流一结束先是中性的「已结束」；结算先等一拍再查 latest-log。
      expect(_inPill(find.text('已结束')), findsOneWidget);
      expect(api.countOf(ApiEndpoints.taskLatestLog(_taskId)), 0);
      await tester.pump(kLogSettleRetryDelay);

      expect(_inPill(find.text('失败')), findsOneWidget);
      expect(_inPill(find.byIcon(Icons.close_rounded)), findsOneWidget);
      // 改前：「已完成」一律映射成绿色 ✓。
      expect(_inPill(find.byIcon(Icons.check_rounded)), findsNothing);
      // 正文是 SSE 来的，结算只取结果，不拿 latest-log 换正文。
      expect(_buffer(tester).lines, history);
      expect(api.countOf(ApiEndpoints.taskLatestLog(_taskId)), 1);

      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('latest-log 一直是运行中（面板还没写完结果）：查满次数后停在中性「已结束」', (
    tester,
  ) async {
    final history = _history(30);
    final api = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.taskLiveLogs(_taskId)) {
        return _liveLogs(_liveLogsSnapshot(history), status: 2);
      }
      if (options.path == ApiEndpoints.taskLatestLog(_taskId)) {
        return _latestLog(history, status: kLogStatusRunning);
      }
      return jsonResponse(<String, dynamic>{});
    });
    DioClient.instance.dio.httpClientAdapter = api;
    final sse = FakeSseHttpClient(
      (_) => sseResponse(
        '${_historyFrame(history)}event: done\ndata: finished\n\n',
      ),
    );

    await http.runWithClient(() async {
      await _openPage(tester);
      for (var i = 0; i < kLogSettleAttempts + 2; i++) {
        await tester.pump(kLogSettleRetryDelay);
      }

      expect(_inPill(find.text('已结束')), findsOneWidget);
      expect(_inPill(find.byIcon(Icons.check_rounded)), findsNothing);
      expect(_inPill(find.byIcon(Icons.close_rounded)), findsNothing);
      expect(
        api.countOf(ApiEndpoints.taskLatestLog(_taskId)),
        kLogSettleAttempts,
      );

      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('刚跑完的任务在「等待日志...」里轮询时不给「停止运行」：任务早就结束了', (
    tester,
  ) async {
    DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.taskLiveLogs(_taskId)) {
        return _liveLogs(const <String>[], status: 1);
      }
      return jsonResponse(<String, dynamic>{});
    });
    final sse = FakeSseHttpClient((_) => sseResponse(''));

    await http.runWithClient(() async {
      await _openPage(tester, operator: true);
      for (var s = 0; s < 3; s++) {
        await tester.pump(const Duration(seconds: 1));
      }

      expect(find.text('等待日志...'), findsOneWidget);
      // 改前：_done 还是 false，就挂着红色「停止运行」，点了会去停一个已经结束的任务。
      expect(find.byKey(const Key('fullscreen-log-stop')), findsNothing);

      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('排队中的任务照样能停', (tester) async {
    DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.taskLiveLogs(_taskId)) {
        return _liveLogs(const <String>[], status: 0.5);
      }
      return jsonResponse(<String, dynamic>{});
    });
    final sse = FakeSseHttpClient((_) => sseResponse(''));

    await http.runWithClient(() async {
      await _openPage(tester, operator: true);

      expect(find.byKey(const Key('fullscreen-log-stop')), findsOneWidget);

      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('停止运行后 SSE 不断：收尾输出照常追加、不改回「运行中」，结果按 latest-log 结算', (
    tester,
  ) async {
    final history = _history(20);
    var stopped = false;
    final api = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.taskLiveLogs(_taskId)) {
        return _liveLogs(_liveLogsSnapshot(history), status: 2);
      }
      if (options.path == ApiEndpoints.taskStop(_taskId)) {
        stopped = true;
        return jsonResponse({'message': '任务已停止'});
      }
      if (options.path == ApiEndpoints.tasks) {
        return jsonResponse({'data': <Object>[], 'total': 0});
      }
      if (options.path == ApiEndpoints.taskLatestLog(_taskId)) {
        // 面板的停止接口返回前就把这次运行的日志记成了「已终止」。
        return _latestLog(
          history,
          status: stopped ? kLogStatusAborted : kLogStatusRunning,
        );
      }
      return jsonResponse(<String, dynamic>{});
    });
    DioClient.instance.dio.httpClientAdapter = api;
    final sse = _LiveSse();

    await http.runWithClient(() async {
      await _openPage(tester, operator: true);
      sse.push(_historyFrame(history));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(_inPill(find.text('运行中')), findsOneWidget);

      await tester.tap(find.byKey(const Key('fullscreen-log-stop')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(_inPill(find.text('已停止')), findsOneWidget);
      expect(find.byKey(const Key('fullscreen-log-rerun')), findsOneWidget);
      // 改前：停止一返回就关掉 SSE，收尾输出全丢。
      expect(sse.client.closeCount, 0);

      // 面板先发 TERM、留 5 秒宽限：收尾输出还会送来。
      sse.push(_liveLines(['收到 SIGTERM，正在收尾', '[任务已被手动停止]']));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(_buffer(tester).lines.last, '[任务已被手动停止]');
      expect(_inPill(find.text('运行中')), findsNothing);
      expect(_inPill(find.text('已停止')), findsOneWidget);

      sse.push('event: done\ndata: finished\n\n');
      await sse.end();
      await tester.pump(kLogSettleRetryDelay);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(_inPill(find.byIcon(Icons.check_rounded)), findsNothing);
      expect(_inPill(find.text('已终止')), findsOneWidget);
      // 正文是 SSE 来的：收尾那两行还在，没被 latest-log 换掉。
      expect(_buffer(tester).lines.last, '[任务已被手动停止]');

      await _closePage(tester);
    }, () => sse.client);
  });

  testWidgets('停止之后 SSE 没等到 done 就断了：不报连接错误，直接去 latest-log 结算', (
    tester,
  ) async {
    final history = _history(20);
    var stopped = false;
    final api = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.taskLiveLogs(_taskId)) {
        return _liveLogs(_liveLogsSnapshot(history), status: 2);
      }
      if (options.path == ApiEndpoints.taskStop(_taskId)) {
        stopped = true;
        return jsonResponse({'message': '任务已停止'});
      }
      if (options.path == ApiEndpoints.tasks) {
        return jsonResponse({'data': <Object>[], 'total': 0});
      }
      if (options.path == ApiEndpoints.taskLatestLog(_taskId)) {
        return _latestLog(
          history,
          status: stopped ? kLogStatusAborted : kLogStatusRunning,
        );
      }
      return jsonResponse(<String, dynamic>{});
    });
    DioClient.instance.dio.httpClientAdapter = api;
    final sse = _LiveSse();

    await http.runWithClient(() async {
      await _openPage(tester, operator: true);
      sse.push(_historyFrame(history));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      await tester.tap(find.byKey(const Key('fullscreen-log-stop')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(_inPill(find.text('已停止')), findsOneWidget);

      sse.fail();
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(_inPill(find.text('连接错误')), findsNothing);
      expect(_inPill(find.text('已停止')), findsOneWidget);

      // 改前：_done 已经是 true，出错什么都不做，一直停在「已停止」、从不结算。
      await tester.pump(kLogSettleRetryDelay);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(_inPill(find.text('已终止')), findsOneWidget);
      expect(api.countOf(ApiEndpoints.taskLatestLog(_taskId)), 1);

      await _closePage(tester);
    }, () => sse.client);
  });

  testWidgets('SSE 出错降级轮询时点停止：重连 SSE 接回宽限期的收尾输出，done 后再结算', (
    tester,
  ) async {
    final history = _history(20);
    const tail = ['收到 SIGTERM，正在收尾', '[任务已被手动停止]'];
    var stopped = false;
    var liveCalls = 0;
    final api = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.taskLiveLogs(_taskId)) {
        liveCalls++;
        // 只有打开页面那次拿得到；之后网络一直抖，轮询失败、连不回 SSE。
        if (liveCalls > 1) throw Exception('网络不可达');
        return _liveLogs(_liveLogsSnapshot(history), status: 2);
      }
      if (options.path == ApiEndpoints.taskStop(_taskId)) {
        stopped = true;
        return jsonResponse({'message': '任务已停止'});
      }
      if (options.path == ApiEndpoints.tasks) {
        return jsonResponse({'data': <Object>[], 'total': 0});
      }
      if (options.path == ApiEndpoints.taskLatestLog(_taskId)) {
        // 面板的停止接口返回前就把这次运行记成了「已终止」：当场结算第一次就收口。
        return _latestLog(
          history,
          status: stopped ? kLogStatusAborted : kLogStatusRunning,
        );
      }
      return jsonResponse(<String, dynamic>{});
    });
    DioClient.instance.dio.httpClientAdapter = api;
    var connections = 0;
    final sse = FakeSseHttpClient((_) {
      connections++;
      // 第一次推完历史就断线。停止之后重连：面板从第一行重放 TinyLog
      // （宽限期里的收尾输出也在里面），随后关流发 done。
      return connections == 1
          ? _sseThenError(_historyFrame(history))
          : sseResponse(
              '${_historyFrame([...history, ...tail])}'
              'event: done\ndata: finished\n\n',
            );
    });

    await http.runWithClient(() async {
      await _openPage(tester, operator: true);
      expect(_inPill(find.text('连接错误')), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));

      await tester.tap(find.byKey(const Key('fullscreen-log-stop')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      final liveCallsAfterStop = liveCalls;
      await tester.pump(kLogSettleRetryDelay);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      // 改前：停止时停掉轮询、当场结算，不再连 SSE，收尾那两行再也拿不到。
      expect(connections, 2);
      expect(_buffer(tester).lines, [...history, ...tail]);
      expect(_inPill(find.text('已终止')), findsOneWidget);
      expect(api.countOf(ApiEndpoints.taskLatestLog(_taskId)), 1);
      // 轮询停了。
      for (var s = 0; s < 3; s++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(liveCalls, liveCallsAfterStop);

      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('SSE 没等到 done 就收口后点停止：重连 SSE 接回收尾输出，done 后结算成「已终止」', (
    tester,
  ) async {
    final history = _history(20);
    const tail = ['收到 SIGTERM，正在收尾', '[任务已被手动停止]'];
    var stopped = false;
    final api = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.taskLiveLogs(_taskId)) {
        return _liveLogs(_liveLogsSnapshot(history), status: 2);
      }
      if (options.path == ApiEndpoints.taskStop(_taskId)) {
        stopped = true;
        return jsonResponse({'message': '任务已停止'});
      }
      if (options.path == ApiEndpoints.tasks) {
        return jsonResponse({'data': <Object>[], 'total': 0});
      }
      if (options.path == ApiEndpoints.taskLatestLog(_taskId)) {
        return _latestLog(
          history,
          status: stopped ? kLogStatusAborted : kLogStatusRunning,
        );
      }
      return jsonResponse(<String, dynamic>{});
    });
    DioClient.instance.dio.httpClientAdapter = api;
    var connections = 0;
    final sse = FakeSseHttpClient((_) {
      connections++;
      // 第一次推完历史就正常收口、没有 done（反代掐了长连接）；
      // 停止之后重连：面板从第一行重放 TinyLog（含收尾输出），再发 done。
      return connections == 1
          ? sseResponse(_historyFrame(history))
          : sseResponse(
              '${_historyFrame([...history, ...tail])}'
              'event: done\ndata: finished\n\n',
            );
    });

    await http.runWithClient(() async {
      await _openPage(tester, operator: true);
      expect(_inPill(find.text('连接结束')), findsOneWidget);
      expect(find.byKey(const Key('fullscreen-log-stop')), findsOneWidget);

      // 赶在第一跳轮询（1 秒）之前点停止。
      await tester.tap(find.byKey(const Key('fullscreen-log-stop')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pump(kLogSettleRetryDelay);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      // 改前：onDone 没置 _sseDropped，停止成功后既不重连也不结算，
      // 胶囊一直是「已停止」，收尾那两行也拿不到。
      expect(connections, 2);
      expect(_buffer(tester).lines, [...history, ...tail]);
      expect(_inPill(find.text('已终止')), findsOneWidget);
      expect(api.countOf(ApiEndpoints.taskLatestLog(_taskId)), 1);

      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('SSE 没等到 done 就收口、任务其实已经跑完：轮询兜底，去 latest-log 结算', (
    tester,
  ) async {
    final history = _history(20);
    var liveCalls = 0;
    final api = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.taskLiveLogs(_taskId)) {
        liveCalls++;
        // 打开时还在跑；之后任务结束、面板删了实时日志，只回空的。
        return liveCalls == 1
            ? _liveLogs(_liveLogsSnapshot(history), status: 2)
            : _liveLogs(const <String>[], status: 1);
      }
      if (options.path == ApiEndpoints.taskLatestLog(_taskId)) {
        return _latestLog(history, status: kLogStatusFailed);
      }
      return jsonResponse(<String, dynamic>{});
    });
    DioClient.instance.dio.httpClientAdapter = api;
    final sse = FakeSseHttpClient((_) => sseResponse(_historyFrame(history)));

    await http.runWithClient(() async {
      await _openPage(tester);
      // 轮询 15 次等不到日志就放弃，放弃时回落一次。
      for (var s = 0; s < 17; s++) {
        await tester.pump(const Duration(seconds: 1));
      }

      // 改前：只写「连接结束」，不轮询，结果永远结算不出来。
      expect(liveCalls, greaterThan(1));
      expect(_inPill(find.text('失败')), findsOneWidget);
      expect(api.countOf(ApiEndpoints.taskLatestLog(_taskId)), 1);
      // 正文是 SSE 来的，不被 latest-log 换掉；任务不在跑，不回去连 SSE。
      expect(_buffer(tester).lines, history);
      expect(sse.requests, hasLength(1));

      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('排队中点停止：停掉轮询，不连 SSE、不去 latest-log（那是上一次运行的）', (
    tester,
  ) async {
    var liveCalls = 0;
    final api = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.taskLiveLogs(_taskId)) {
        liveCalls++;
        return _liveLogs(const <String>[], status: 0.5);
      }
      if (options.path == ApiEndpoints.taskStop(_taskId)) {
        return jsonResponse({'message': '任务已停止'});
      }
      if (options.path == ApiEndpoints.tasks) {
        return jsonResponse({'data': <Object>[], 'total': 0});
      }
      if (options.path == ApiEndpoints.taskLatestLog(_taskId)) {
        return _latestLog(_history(30), status: kLogStatusFailed);
      }
      return jsonResponse(<String, dynamic>{});
    });
    DioClient.instance.dio.httpClientAdapter = api;
    final sse = FakeSseHttpClient((_) => sseResponse(''));

    await http.runWithClient(() async {
      await _openPage(tester, operator: true);
      for (var s = 0; s < 2; s++) {
        await tester.pump(const Duration(seconds: 1));
      }

      await tester.tap(find.byKey(const Key('fullscreen-log-stop')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      final liveCallsAfterStop = liveCalls;
      for (var s = 0; s < 3; s++) {
        await tester.pump(const Duration(seconds: 1));
      }

      expect(_inPill(find.text('已停止')), findsOneWidget);
      expect(liveCalls, liveCallsAfterStop);
      expect(sse.requests, isEmpty);
      expect(api.countOf(ApiEndpoints.taskLatestLog(_taskId)), 0);

      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('降级轮询拿到「快照还在、任务已不在跑」：停掉轮询，去 latest-log 结算', (
    tester,
  ) async {
    final history = _history(20);
    var liveCalls = 0;
    final api = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.taskLiveLogs(_taskId)) {
        liveCalls++;
        // 打开时还在跑；SSE 断线后再轮询，任务已经不在跑了（比如别处点了停止，
        // 宽限期里 TinyLog 还在，快照还有内容）。
        return _liveLogs(
          _liveLogsSnapshot(history),
          status: liveCalls == 1 ? 2 : 1,
        );
      }
      if (options.path == ApiEndpoints.taskLatestLog(_taskId)) {
        return _latestLog(history, status: kLogStatusFailed);
      }
      return jsonResponse(<String, dynamic>{});
    });
    DioClient.instance.dio.httpClientAdapter = api;
    final sse = FakeSseHttpClient(
      (_) => _sseThenError(_historyFrame(history)),
    );

    await http.runWithClient(() async {
      await _openPage(tester);
      for (var s = 0; s < 3; s++) {
        await tester.pump(const Duration(seconds: 1));
      }

      expect(_inPill(find.text('失败')), findsOneWidget);
      expect(api.countOf(ApiEndpoints.taskLatestLog(_taskId)), 1);
      // 不回去连 SSE，也不再轮询；正文是 SSE 来的，不被 latest-log 换掉。
      expect(sse.requests, hasLength(1));
      expect(_buffer(tester).lines, history);
      final liveCallsAfterSettle = liveCalls;
      for (var s = 0; s < 3; s++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(liveCalls, liveCallsAfterSettle);

      await _closePage(tester);
    }, () => sse);
  });

  testWidgets('停止请求在途时 done 先到、停止却失败：拿不到结果就是「已结束」，不停在「已停止」', (
    tester,
  ) async {
    final history = _history(20);
    final api = FakeHttpAdapter((options) async {
      if (options.path == ApiEndpoints.taskLiveLogs(_taskId)) {
        return _liveLogs(_liveLogsSnapshot(history), status: 2);
      }
      if (options.path == ApiEndpoints.taskStop(_taskId)) {
        await Future<void>.delayed(const Duration(seconds: 1));
        throw Exception('网络不可达');
      }
      if (options.path == ApiEndpoints.taskLatestLog(_taskId)) {
        throw Exception('网络不可达');
      }
      return jsonResponse(<String, dynamic>{});
    });
    DioClient.instance.dio.httpClientAdapter = api;
    final sse = _LiveSse();

    await http.runWithClient(() async {
      await _openPage(tester, operator: true);
      sse.push(_historyFrame(history));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      await tester.tap(find.byKey(const Key('fullscreen-log-stop')));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      sse.push('event: done\ndata: finished\n\n');
      await sse.end();
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      // 停止请求还在途：先让位给「已停止」。
      expect(_inPill(find.text('已停止')), findsOneWidget);

      for (var i = 0; i < kLogSettleAttempts + 2; i++) {
        await tester.pump(kLogSettleRetryDelay);
      }
      // 改前：停止失败只把标志放下，胶囊一直写着「已停止」。
      expect(_inPill(find.text('已结束')), findsOneWidget);
      expect(_inPill(find.text('已停止')), findsNothing);

      await _closePage(tester);
    }, () => sse.client);
  });

  testWidgets('运行中越过 1 万行上限后复制：提示在点击那一刻按缓冲区现算', (tester) async {
    final history = _history(10);
    DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.taskLiveLogs(_taskId)) {
        return _liveLogs(_liveLogsSnapshot(history), status: 2);
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
      sse.push(_historyFrame(history));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      // 之后一直「运行中」，页面不再重建（正文由 LogView 自己刷新）。
      sse.push(
        _liveLines(
          List<String>.generate(kLogBufferMaxLines + 40, (i) => 'tail $i'),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(_buffer(tester).droppedCount, greaterThan(0));

      await tester.tap(find.byKey(const Key('fullscreen-log-copy')));
      await tester.pump();
      expect(find.text('已复制最近 $kLogBufferMaxLines 行'), findsOneWidget);
      expect(find.text('日志已复制到剪贴板'), findsNothing);

      await _closePage(tester);
    }, () => sse.client);
  });
}
