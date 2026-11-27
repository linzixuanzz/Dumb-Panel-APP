import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/network/dio_client.dart';
import 'package:daidai_app/features/subscriptions/views/subscription_list_page.dart';
import 'package:daidai_app/shared/widgets/log_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_http_adapter.dart';
import '../../support/fake_sse_http_client.dart';

const _subId = 3;

Future<void> _pumpFrames(WidgetTester tester, [int count = 20]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _pumpApp(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(411, 860);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(child: MaterialApp(home: home)));
  await _pumpFrames(tester);
}

/// 收掉页面并把重连这类定时器都放完。
Future<void> _closePage(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 3));
}

List<String> _lines(WidgetTester tester) =>
    tester.widget<LogView>(find.byType(LogView)).buffer.lines;

Finder _inPill(String text) => find.descendant(
  of: find.byKey(const Key('fullscreen-log-status-pill')),
  matching: find.text(text),
);

Finder _inBanner(String text) => find.descendant(
  of: find.byKey(const Key('fullscreen-log-error-banner')),
  matching: find.text(text),
);

/// 照面板 PullStream 的做法：每行一条 data 帧。
String _frames(List<String> lines) =>
    lines.map((line) => 'data: $line\n\n').join();

/// 拉取流收尾的一组用例：面板推的日志、结束值，胶囊该写什么、不该写什么。
typedef _OutcomeCase = ({
  String name,
  List<String> log,
  String done,
  String pill,
  List<String> absent,
});

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues({});
    DioClient.instance.setBaseUrl('https://panel.test');
    DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter(
      (_) => jsonResponse(<String, dynamic>{}),
    );
  });

  group('拉取日志流', () {
    Future<void> openStream(WidgetTester tester) => _pumpApp(
      tester,
      const SubscriptionPullStreamPage(subscriptionId: _subId),
    );

    testWidgets('正文已有内容时收到 done: not_running：显示「已结束」，不是协议原文', (tester) async {
      // 面板很快重启回来：重连后历史又重放一遍，新进程里没有这次拉取。
      final sse = FakeSseHttpClient(
        (_) => sseResponse(
          'data: 正在克隆仓库...\n\nevent: done\ndata: not_running\n\n',
        ),
      );

      await http.runWithClient(() async {
        await openStream(tester);

        expect(find.text('not_running'), findsNothing);
        expect(find.text('已结束'), findsOneWidget);
        expect(_lines(tester), ['正在克隆仓库...']);

        await _closePage(tester);
      }, () => sse);
    });

    testWidgets('正文为空时收到 done: not_running：仍说明「当前没有正在运行的拉取任务」', (tester) async {
      final sse = FakeSseHttpClient(
        (_) => sseResponse('event: done\ndata: not_running\n\n'),
      );

      await http.runWithClient(() async {
        await openStream(tester);

        expect(find.text('未在运行'), findsOneWidget);
        expect(find.text('当前没有正在运行的拉取任务'), findsOneWidget);

        await _closePage(tester);
      }, () => sse);
    });

    testWidgets('有日志后断线：完整原因显示在正文顶上，不只藏在空态文案里', (tester) async {
      var connects = 0;
      final sse = FakeSseHttpClient((_) {
        connects++;
        return connects == 1
            ? sseResponse('data: 正在克隆仓库...\n\nevent: done\ndata: reconnect\n\n')
            : emptyResponse(502);
      });

      await http.runWithClient(() async {
        await openStream(tester);
        // SseClient 收到 reconnect 后 1 秒重连一次，这次回 502。
        await tester.pump(const Duration(seconds: 1));
        await _pumpFrames(tester);

        expect(find.text('连接已断开'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('fullscreen-log-error-banner')),
            matching: find.text('拉取日志连接已断开'),
          ),
          findsOneWidget,
        );
        expect(_lines(tester), ['正在克隆仓库...']);

        await _closePage(tester);
      }, () => sse);
    });

    // 面板不管拉取成没成都照常发结束信号（handler/subscription.go Pull），
    // 结果只看 ExecuteSubscriptionPull 最后写的收尾行。
    for (final c in <_OutcomeCase>[
      (
        name: '仓库地址错了：收尾行「状态: 失败」+ finished → 红色「拉取失败」',
        log: [
          '[开始拉取] 示例仓库 (git-repo)',
          '[错误] git clone 失败: exit status 128',
          '[完成] 耗时 1.00 秒, 状态: 失败',
        ],
        done: 'finished',
        pill: '拉取失败',
        absent: ['拉取完成'],
      ),
      (
        name: '在列表里点了停止：收尾行前是「拉取已停止」→ 中性「已停止」',
        log: [
          '[开始拉取] 示例仓库 (git-repo)',
          '[停止请求] 正在终止当前拉取任务...',
          '[错误] 拉取已停止',
          '[完成] 耗时 3.20 秒, 状态: 失败',
        ],
        done: 'finished',
        pill: '已停止',
        absent: ['拉取完成', '拉取失败'],
      ),
      (
        // curl 被杀后面板拿已取消的 ctx 再跑 wget（service/git.go
        // DownloadFileWithContext），错误行是 exec 原文，不是「拉取已停止」。
        name: '单文件订阅下载中点了停止：错误行是 exec 原文 → 仍是「已停止」',
        log: [
          '[开始拉取] 示例脚本 (single-file)',
          '[下载] https://example.com/demo.js -> scripts/demo.js',
          '[停止请求] 正在终止当前拉取任务...',
          '[错误] context canceled',
          '[完成] 耗时 2.10 秒, 状态: 失败',
        ],
        done: 'finished',
        pill: '已停止',
        absent: ['拉取完成', '拉取失败'],
      ),
      (
        // 正文被裁过、停止请求那行不在了；错误行被包了一层，仍带「拉取已停止」。
        name: '停止请求那行不在正文里：错误行带「拉取已停止」→「已停止」',
        log: [
          'Receiving objects: 100% (1000/1000)',
          '[错误] sparse-checkout init 失败: 拉取已停止',
          '[完成] 耗时 4.00 秒, 状态: 失败',
        ],
        done: 'finished',
        pill: '已停止',
        absent: ['拉取完成', '拉取失败'],
      ),
      (
        // 拉取已经自己失败、写完收尾行，停止请求才到：停止什么也没做。
        name: '停止请求在收尾行之后才到：失败是拉取自己的 →「拉取失败」',
        log: [
          '[开始拉取] 示例仓库 (git-repo)',
          '[错误] git clone 失败: exit status 128',
          '[完成] 耗时 1.00 秒, 状态: 失败',
          '[停止请求] 正在终止当前拉取任务...',
        ],
        done: 'finished',
        pill: '拉取失败',
        absent: ['已停止', '拉取完成'],
      ),
      (
        // 点了停止后面板正好关停，done: reconnect 重连上的是重启后新的
        // 一次拉取，上一次的停止请求留在前面。
        name: '停止请求属于上一次拉取：不算到这一次头上 →「拉取失败」',
        log: [
          '[开始拉取] 示例仓库 (git-repo)',
          '[停止请求] 正在终止当前拉取任务...',
          '[开始拉取] 示例仓库 (git-repo)',
          '[错误] git clone 失败: exit status 128',
          '[完成] 耗时 1.00 秒, 状态: 失败',
        ],
        done: 'finished',
        pill: '拉取失败',
        absent: ['已停止', '拉取完成'],
      ),
      (
        name: '结束信号被丢、只收到 closed：按收尾行「状态: 成功」→「拉取完成」',
        log: ['[开始拉取] 示例仓库 (git-repo)', '[完成] 耗时 2.00 秒, 状态: 成功'],
        done: 'closed',
        pill: '拉取完成',
        absent: ['已停止'],
      ),
      (
        name: 'closed 时最后几行也被丢了：读不到结果 → 中性「已结束」',
        log: ['[开始拉取] 示例仓库 (git-repo)', '正在克隆仓库...'],
        done: 'closed',
        pill: '已结束',
        absent: ['已停止', '拉取完成'],
      ),
      (
        name: 'finished 却没有收尾行：不猜成成功 → 中性「已结束」',
        log: ['[开始拉取] 示例仓库 (git-repo)'],
        done: 'finished',
        pill: '已结束',
        absent: ['拉取完成'],
      ),
      (
        // 真正的收尾行随结束信号一起被丢，前面只剩拉取前指令打印的一行。
        name: '长得像收尾行的脚本输出不在末尾：不当成结果 → 中性「已结束」',
        log: [
          '[开始拉取] 示例仓库 (git-repo)',
          '[完成] 耗时 0.10 秒, 状态: 成功',
          '正在克隆仓库...',
          'Receiving objects:  50% (500/1000)',
          'Receiving objects: 100% (1000/1000)',
        ],
        done: 'closed',
        pill: '已结束',
        absent: ['拉取完成'],
      ),
    ]) {
      testWidgets(c.name, (tester) async {
        final body = '${_frames(c.log)}event: done\ndata: ${c.done}\n\n';
        final sse = FakeSseHttpClient((_) => sseResponse(body));

        await http.runWithClient(() async {
          await openStream(tester);

          expect(_inPill(c.pill), findsOneWidget);
          for (final text in c.absent) {
            expect(_inPill(text), findsNothing);
          }
          expect(
            find.byKey(const Key('fullscreen-log-error-banner')),
            findsNothing,
          );
          expect(_lines(tester), c.log);

          await _closePage(tester);
        }, () => sse);
      });
    }

    testWidgets('done: timeout：是断流不是结果，红色「连接已断开」+ 横幅说拉取可能仍在进行', (
      tester,
    ) async {
      final sse = FakeSseHttpClient(
        (_) => sseResponse(
          'data: 正在克隆仓库...\n\nevent: done\ndata: timeout\n\n',
        ),
      );

      await http.runWithClient(() async {
        await openStream(tester);

        // 改前：红色「拉取超时」、没有横幅，像是拉取本身的结果。
        expect(_inPill('连接已断开'), findsOneWidget);
        expect(find.text('拉取超时'), findsNothing);
        expect(_inBanner('日志流已断开，拉取可能仍在进行'), findsOneWidget);

        await _closePage(tester);
      }, () => sse);
    });

    testWidgets('没收到结束帧连接就收口了：不说「拉取完成」，按断流处理', (tester) async {
      final sse = FakeSseHttpClient(
        (_) => sseResponse('data: 正在克隆仓库...\n\n'),
      );

      await http.runWithClient(() async {
        await openStream(tester);

        // 改前：绿色「拉取完成」。
        expect(find.text('拉取完成'), findsNothing);
        expect(_inPill('连接已断开'), findsOneWidget);
        expect(_inBanner('日志流已断开，拉取可能仍在进行'), findsOneWidget);
        expect(_lines(tester), ['正在克隆仓库...']);

        await _closePage(tester);
      }, () => sse);
    });
  });

  group('拉取日志详情', () {
    Future<void> openDetail(
      WidgetTester tester,
      Map<String, dynamic> log,
    ) async {
      DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter((options) {
        if (options.path == ApiEndpoints.subscriptionLogs(_subId)) {
          return jsonResponse({
            'data': [log],
            'total': 1,
          });
        }
        return jsonResponse(<String, dynamic>{});
      });
      await _pumpApp(
        tester,
        const SubscriptionLogsPage(subscriptionId: _subId),
      );
      await tester.tap(find.text('拉取完成，新增 2 个脚本'));
      await _pumpFrames(tester);
    }

    Map<String, dynamic> logWith(Object? duration) => {
      'id': 1,
      'subscription_id': _subId,
      'status': 0,
      'content': '拉取完成，新增 2 个脚本\n',
      'created_at': '2026-11-27T10:00:00+08:00',
      'duration': ?duration,
    };

    for (final (label, duration) in <(String, Object?)>[
      ('没有 duration 字段', null),
      ('duration 是负数', -3),
    ]) {
      testWidgets('$label：副标题不写「耗时 -」', (tester) async {
        await openDetail(tester, logWith(duration));

        expect(find.text('订阅拉取日志详情'), findsOneWidget);
        expect(find.textContaining('耗时'), findsNothing);
        expect(find.textContaining('1 行'), findsOneWidget);

        await _closePage(tester);
      });
    }

    testWidgets('有耗时：副标题照常带上', (tester) async {
      await openDetail(tester, logWith(12.34));

      expect(find.textContaining('耗时 12.3s'), findsOneWidget);

      await _closePage(tester);
    });
  });
}
