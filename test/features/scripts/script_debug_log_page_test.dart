import 'dart:async';

import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/network/dio_client.dart';
import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/features/scripts/views/script_debug_log_page.dart';
import 'package:daidai_app/shared/utils/log_line_buffer.dart';
import 'package:daidai_app/shared/widgets/fullscreen_log_scaffold.dart';
import 'package:dio/dio.dart' show RequestOptions, ResponseBody;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_http_adapter.dart';

const _runId = 'debug-0123456789abcdef';
const _rerunId = 'debug-fedcba9876543210';

List<String> _lines(int from, int count) =>
    List<String>.generate(count, (i) => 'out ${from + i}');

/// 照面板 `DebugLogs` / `DebugStop` 的语义造的假调试运行。
///
/// GET 每次回整份日志；PUT stop 在回包之前就同步置好 done / stopped，
/// 并追加「[调试运行已停止]」（script_runtime.go `debugRun.stop`）。
class _FakeDebugRun {
  _FakeDebugRun(List<String> initial, {this.runId = _runId})
    : logs = List.of(initial) {
    adapter = FakeHttpAdapter(_respond);
  }

  final String runId;
  final List<String> logs;

  /// 点「重新运行」时 POST /scripts/run 交出的下一轮（照 script_debug.go
  /// 回 201 + 顶层 run_id），之后发给它的请求也转给它应答。
  /// 请求都记在本轮的 [adapter] 上。
  _FakeDebugRun? next;
  bool done = false;
  String status = 'running';
  int? exitCode;

  /// 置 true 后，下一个日志 GET 在到达那一刻取快照，回包挂到 [gates] 上，
  /// 放行后才送回：模拟「请求早发、回包晚到」的慢响应。
  bool holdNext = false;
  final List<Completer<void>> gates = <Completer<void>>[];

  late final FakeHttpAdapter adapter;

  int get logRequests => adapter.countOf(ApiEndpoints.scriptsRunLogs(runId));
  int get stopRequests => adapter.countOf(ApiEndpoints.scriptsRunStop(runId));

  Future<ResponseBody> _respond(RequestOptions options) async {
    final next = this.next;
    if (next != null) {
      if (options.path == ApiEndpoints.scriptsRun) {
        return jsonResponse({
          'message': '脚本已启动',
          'run_id': next.runId,
        }, status: 201);
      }
      if (options.path == ApiEndpoints.scriptsRunLogs(next.runId) ||
          options.path == ApiEndpoints.scriptsRunStop(next.runId)) {
        return next._respond(options);
      }
    }
    if (options.path == ApiEndpoints.scriptsRunLogs(runId)) {
      final body = <String, dynamic>{
        'data': {
          'logs': List.of(logs),
          'done': done,
          'exit_code': exitCode,
          'status': status,
        },
      };
      if (holdNext) {
        holdNext = false;
        final gate = Completer<void>();
        gates.add(gate);
        await gate.future;
      }
      return jsonResponse(body);
    }
    if (options.path == ApiEndpoints.scriptsRunStop(runId)) {
      done = true;
      status = 'stopped';
      exitCode = -1;
      logs.add('[调试运行已停止]');
      return jsonResponse({'message': '已停止'});
    }
    return jsonResponse(<String, dynamic>{});
  }
}

/// 推几帧，让假 HTTP 的回包和随后的重建都走完。
/// 运行中状态胶囊一直在呼吸、耗时每 200ms 刷新，不能 pumpAndSettle。
Future<void> _frames(WidgetTester tester, [int count = 10]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// 推过 [ticks] 个 700ms 的轮询周期，每跳之后把回包推完。
Future<void> _polls(WidgetTester tester, int ticks) async {
  for (var i = 0; i < ticks; i++) {
    await tester.pump(const Duration(milliseconds: 700));
    await _frames(tester, 5);
  }
}

/// 打开页面并把第一次拉取推完（20 × 20ms，赶在第一跳轮询之前）。
Future<void> _openPage(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: const ScriptDebugLogPage(
        path: 'demo/hello.py',
        initialRunId: _runId,
      ),
    ),
  );
  await _frames(tester, 20);
}

/// 收掉页面并把提示条这类定时器放完。
Future<void> _closePage(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

LogLineBuffer _buffer(WidgetTester tester) => tester
    .widget<FullscreenLogScaffold>(find.byType(FullscreenLogScaffold))
    .buffer;

String _lastLine(LogLineBuffer buffer) => buffer.lineAt(buffer.length - 1);

/// 当前选中的文字，按段落收集（点一下落下的光标那种空选区不算）。
List<String> _selectedTexts(WidgetTester tester) {
  final texts = <String>[];
  void visit(RenderObject object) {
    if (object is RenderParagraph) {
      final plain = object.text.toPlainText(includeSemanticsLabels: false);
      for (final selection in object.selections) {
        if (!selection.isCollapsed) {
          texts.add(selection.textInside(plain));
        }
      }
    }
    object.visitChildren(visit);
  }

  for (final view in tester.binding.renderViews) {
    visit(view);
  }
  return texts;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues({});
    DioClient.instance.setBaseUrl('https://panel.test');
  });

  testWidgets('轮询内容没变不动缓冲区、有新行只追加：跟随中选中的字一直保留', (tester) async {
    final run = _FakeDebugRun(_lines(0, 300));
    DioClient.instance.dio.httpClientAdapter = run.adapter;

    await _openPage(tester);
    final buffer = _buffer(tester);
    expect(buffer.totalCount, 300);
    final generation = buffer.generation;

    // 鼠标拖选不滚动列表，能稳稳地选中「out 290」这一整行。
    final rect = tester.getRect(find.text('out 290'));
    final gesture = await tester.startGesture(
      rect.centerLeft + const Offset(1, 0),
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(rect.centerRight - const Offset(1, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(_selectedTexts(tester), ['out 290']);

    // 没有新输出的三跳：缓冲区不动（generation 不变），选区还在。
    // 改前每跳都 replaceAll，generation 一变 LogView 就重建尾段、清掉选区。
    final requestsBefore = run.logRequests;
    await _polls(tester, 3);
    expect(
      run.logRequests,
      greaterThanOrEqualTo(requestsBefore + 3),
      reason: '轮询确实在跑',
    );
    expect(buffer.generation, generation);
    expect(buffer.totalCount, 300);
    expect(_selectedTexts(tester), ['out 290']);

    // 来了 5 行新输出：只追加这 5 行，generation 仍不变，选区仍在。
    run.logs.addAll(_lines(300, 5));
    await _polls(tester, 1);
    expect(buffer.generation, generation);
    expect(buffer.totalCount, 305);
    expect(_lastLine(buffer), 'out 304');
    expect(_selectedTexts(tester), ['out 290']);

    // 跑完：停止轮询，状态落到「执行成功」。
    run
      ..done = true
      ..status = 'success'
      ..exitCode = 0;
    await _polls(tester, 1);
    expect(find.text('执行成功'), findsOneWidget);
    final requestsAtDone = run.logRequests;
    await _polls(tester, 3);
    expect(run.logRequests, requestsAtDone, reason: '结束后不再轮询');

    await _closePage(tester);
  });

  testWidgets('上翻暂停跟随后，悬浮胶囊按轮询追加的行数累计「新增 N 行」', (tester) async {
    final run = _FakeDebugRun(_lines(0, 300));
    DioClient.instance.dio.httpClientAdapter = run.adapter;

    await _openPage(tester);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
    await _frames(tester, 30);
    expect(find.byTooltip('回到底部'), findsOneWidget);

    run.logs.addAll(_lines(300, 7));
    await _polls(tester, 1);
    expect(find.textContaining('新增 7 行'), findsOneWidget);

    // 内容没变的一跳不能把计数清零（改前每跳 replaceAll 都会重置成 0）。
    await _polls(tester, 2);
    expect(find.textContaining('新增 7 行'), findsOneWidget);

    run.logs.addAll(_lines(307, 3));
    await _polls(tester, 1);
    expect(find.textContaining('新增 10 行'), findsOneWidget);

    run.done = true;
    await _polls(tester, 1);
    await _closePage(tester);
  });

  testWidgets('面板截断了日志头部（内容对不上）才整段替换', (tester) async {
    final run = _FakeDebugRun(_lines(0, 300));
    DioClient.instance.dio.httpClientAdapter = run.adapter;

    await _openPage(tester);
    final buffer = _buffer(tester);
    final generation = buffer.generation;

    // 面板超过上限时成块丢掉头部、补一行省略提示，数组整体前移。
    run.logs
      ..removeRange(0, 100)
      ..insert(0, '[前 100 行输出已省略：单次运行最多保留 200000 行日志]')
      ..addAll(_lines(300, 50));
    await _polls(tester, 1);
    expect(buffer.generation, generation + 1);
    expect(buffer.lines, run.logs);

    run.done = true;
    await _polls(tester, 1);
    await _closePage(tester);
  });

  testWidgets('慢请求在途时不叠请求；停止后晚到的 done=false 旧回包不把页面改回运行中', (
    tester,
  ) async {
    final run = _FakeDebugRun(_lines(0, 10));
    DioClient.instance.dio.httpClientAdapter = run.adapter;

    await _openPage(tester);
    expect(run.logRequests, 1);
    final buffer = _buffer(tester);

    // 下一跳的回包挂住：它在停止之前就取好了 done=false 的快照。
    run
      ..holdNext = true
      ..logs.add('out 10');
    await _polls(tester, 1);
    expect(run.logRequests, 2);

    // 它没回来之前，后面几跳都跳过，不再叠新的 GET。
    await _polls(tester, 3);
    expect(run.logRequests, 2);

    // 点「停止运行」：面板同步置好 stopped，停止后补拉的那次拿到 done=true。
    await tester.tap(find.byKey(const Key('fullscreen-log-stop')));
    await _frames(tester);
    expect(run.stopRequests, 1);
    expect(run.logRequests, 3);
    expect(find.text('已停止'), findsOneWidget);
    expect(_lastLine(buffer), '[调试运行已停止]');

    // 停止前发出的那个慢请求现在才回来（done=false、日志少一行）：整份丢掉。
    run.gates.single.complete();
    await _frames(tester);
    expect(find.text('已停止'), findsOneWidget);
    expect(find.text('实时输出'), findsNothing);
    expect(find.byKey(const Key('fullscreen-log-stop')), findsNothing);
    expect(find.byKey(const Key('fullscreen-log-rerun')), findsOneWidget);
    expect(_lastLine(buffer), '[调试运行已停止]');

    // 计时器已经取消，之后不再轮询。
    await _polls(tester, 3);
    expect(run.logRequests, 3);

    await _closePage(tester);
  });

  testWidgets('停止后补拉也还挂着、停止前的旧回包先到：照样丢掉，不把页面改回运行中', (
    tester,
  ) async {
    final run = _FakeDebugRun(_lines(0, 10));
    DioClient.instance.dio.httpClientAdapter = run.adapter;

    await _openPage(tester);
    final buffer = _buffer(tester);

    // 周期轮询的回包挂住：它取的是停止前 done=false 的快照。
    run
      ..holdNext = true
      ..logs.add('out 10');
    await _polls(tester, 1);
    expect(run.logRequests, 2);

    // 停止后补拉的那次也挂住，两份回包都还在路上。
    run.holdNext = true;
    await tester.tap(find.byKey(const Key('fullscreen-log-stop')));
    await _frames(tester);
    expect(run.stopRequests, 1);
    expect(run.logRequests, 3);
    expect(run.gates, hasLength(2));
    expect(find.text('已停止'), findsOneWidget);

    // 旧回包先到。它的序号比已应用的那份（首次拉取）新，序号挡不住，
    // 只能靠「done 只进不退」整份丢掉；应用了页面会退回「实时输出」，
    // 停止按钮重新出现，而计时器已经取消。
    run.gates.first.complete();
    await _frames(tester);
    expect(find.text('已停止'), findsOneWidget);
    expect(find.text('实时输出'), findsNothing);
    expect(find.byKey(const Key('fullscreen-log-stop')), findsNothing);
    expect(_lastLine(buffer), 'out 9');

    // 补拉回来：带上面板追加的停止提示。
    run.gates.last.complete();
    await _frames(tester);
    expect(find.text('已停止'), findsOneWidget);
    expect(find.byKey(const Key('fullscreen-log-rerun')), findsOneWidget);
    expect(_lastLine(buffer), '[调试运行已停止]');

    await _polls(tester, 3);
    expect(run.logRequests, 3);

    await _closePage(tester);
  });

  testWidgets('停止前的慢轮询拖到重新运行之后：新一轮照常轮询，它回来后也不卡住', (
    tester,
  ) async {
    final run = _FakeDebugRun(_lines(0, 10));
    final rerun = _FakeDebugRun(_lines(100, 2), runId: _rerunId);
    run.next = rerun;
    DioClient.instance.dio.httpClientAdapter = run.adapter;
    int rerunLogRequests() =>
        run.adapter.countOf(ApiEndpoints.scriptsRunLogs(_rerunId));

    await _openPage(tester);
    final buffer = _buffer(tester);

    // 第一轮的周期轮询挂住，然后停止。停止后的补拉不挂，马上回来。
    run.holdNext = true;
    await _polls(tester, 1);
    expect(run.logRequests, 2);
    await tester.tap(find.byKey(const Key('fullscreen-log-stop')));
    await _frames(tester);
    expect(find.text('已停止'), findsOneWidget);
    // 等「已停止脚本运行」提示条收起，免得它盖住底栏按钮。提示条的 4s 计时
    // 从入场动画播完才开始，得一帧帧推。
    for (var i = 0; i < 55; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('已停止脚本运行'), findsNothing);

    await tester.tap(find.byKey(const Key('fullscreen-log-rerun')));
    await _frames(tester);
    expect(find.text('实时输出'), findsOneWidget);
    expect(rerunLogRequests(), 1);
    expect(_lastLine(buffer), 'out 101');

    // 上一轮的慢请求还挂着。改前它还算在途，新一轮每跳都跳过，
    // 正文停在 out 101，直到它回来或超时。
    expect(run.gates.single.isCompleted, isFalse);
    rerun.logs.addAll(_lines(102, 3));
    await _polls(tester, 3);
    expect(rerunLogRequests(), greaterThanOrEqualTo(4));
    expect(_lastLine(buffer), 'out 104');

    // 它终于回来：属于上一轮，整份丢掉，也不能把新一轮的在途计数扣成负数。
    run.gates.single.complete();
    await _frames(tester);
    expect(_lastLine(buffer), 'out 104');
    expect(find.text('实时输出'), findsOneWidget);
    final requestsAfterStale = rerunLogRequests();
    rerun.logs.addAll(_lines(105, 2));
    await _polls(tester, 3);
    expect(rerunLogRequests(), greaterThanOrEqualTo(requestsAfterStale + 3));
    expect(_lastLine(buffer), 'out 106');

    rerun.done = true;
    await _polls(tester, 1);
    await _closePage(tester);
  });
}
