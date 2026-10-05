import 'dart:async';
import 'dart:convert';

import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/network/dio_client.dart';
import 'package:daidai_app/features/tasks/views/task_list_page.dart';
import 'package:daidai_app/shared/utils/log_line_buffer.dart';
import 'package:daidai_app/shared/widgets/log_view.dart';
import 'package:dio/dio.dart' show ResponseBody;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

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
ResponseBody _latestLog(List<String> lines) => jsonResponse({
  'data': {
    'id': 7,
    'task_id': _taskId,
    'status': 0,
    'content': '${lines.join('\n')}\n',
  },
});

/// 打开页面并推到假 HTTP / 假 SSE 都跑完。AppBar 里有常驻的转圈，不能 pumpAndSettle。
Future<void> _openPage(WidgetTester tester) async {
  await tester.pumpWidget(
    const ProviderScope(
      child: MaterialApp(
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

      await tester.tap(find.byTooltip('复制全部'));
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
    DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.taskLiveLogs(_taskId)) {
        return _liveLogs(_liveLogsSnapshot(all), status: 2);
      }
      return jsonResponse(<String, dynamic>{});
    });
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
}
