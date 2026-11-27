import 'dart:async';

import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/network/dio_client.dart';
import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/features/system/views/panel_log_page.dart';
import 'package:daidai_app/shared/utils/log_line_buffer.dart';
import 'package:daidai_app/shared/widgets/fullscreen_log_scaffold.dart';
import 'package:dio/dio.dart' show RequestOptions, ResponseBody;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_http_adapter.dart';

/// 假面板：记下每次 GET panel-log 的 query（FakeHttpAdapter 本身不记 query），
/// 回包里写明是按哪组条件筛出来的，方便断言「显示的是哪一次的结果」。
class _FakePanel {
  _FakePanel() {
    adapter = FakeHttpAdapter(_respond);
  }

  late final FakeHttpAdapter adapter;
  final List<Map<String, dynamic>> queries = <Map<String, dynamic>>[];

  /// 置 true 后，下一个 panel-log 请求的回包挂到 [gates] 上，放行后才送回。
  bool holdNext = false;
  final List<Completer<void>> gates = <Completer<void>>[];

  Future<ResponseBody> _respond(RequestOptions options) async {
    if (options.path == ApiEndpoints.panelLog) {
      final query = Map<String, dynamic>.of(options.queryParameters);
      queries.add(query);
      final level = query['level'] ?? 'all';
      final keyword = query['keyword'] ?? '-';
      final body = <String, dynamic>{
        'data': {
          'logs': [
            for (var i = 0; i < 3; i++)
              '[$level] keyword=$keyword lines=${query['lines']} #$i',
          ],
          'total': 3,
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
    return jsonResponse(<String, dynamic>{});
  }
}

/// 推几帧，让假 HTTP 的回包、菜单与弹层的进出场动画都走完（30 × 20ms）。
/// 加载中状态胶囊一直在呼吸，不能 pumpAndSettle。
Future<void> _frames(WidgetTester tester, [int count = 30]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// 窄屏 + 大字号：360dp 是最常见的安卓宽度，1.3 倍是常见的系统大字号。
void _useNarrowLargeText(WidgetTester tester, {double height = 640}) {
  tester.view.physicalSize = Size(360, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = 1.3;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// 面板日志页压在一个首页上面打开，这样「误 pop 掉了本页」能被看出来。
Future<void> _openPage(WidgetTester tester) async {
  final navigatorKey = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigatorKey,
      theme: AppTheme.light(),
      home: const Scaffold(body: Center(child: Text('首页'))),
    ),
  );
  unawaited(
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const PanelLogPage()),
    ),
  );
  await _frames(tester);
}

Future<void> _openFilterSheet(WidgetTester tester) async {
  await tester.tap(find.byTooltip('更多选项'));
  await _frames(tester);
  await tester.tap(find.textContaining('筛选日志'));
  await _frames(tester);
  expect(find.text('筛选面板日志'), findsOneWidget);
}

Future<void> _tapApply(WidgetTester tester) async {
  final apply = find.text('应用并刷新');
  await tester.ensureVisible(apply);
  await tester.pump();
  await tester.tap(apply);
  await _frames(tester);
}

LogLineBuffer _buffer(WidgetTester tester) => tester
    .widget<FullscreenLogScaffold>(find.byType(FullscreenLogScaffold))
    .buffer;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues({});
    DioClient.instance.setBaseUrl('https://panel.test');
  });

  testWidgets('360dp + 1.3 倍字号：筛选弹层不溢出，级别 / 关键字 / 行数一起下发', (tester) async {
    _useNarrowLargeText(tester);
    final panel = _FakePanel();
    DioClient.instance.dio.httpClientAdapter = panel.adapter;

    await _openPage(tester);
    expect(panel.queries.single, {'lines': 300});

    await _openFilterSheet(tester);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('仅 ERROR'));
    await tester.pump();
    await tester.ensureVisible(find.text('最近 1000 行'));
    await tester.tap(find.text('最近 1000 行'));
    await tester.pump();
    // 输入框还聚焦着就直接点「应用并刷新」：控制器归弹层自己，
    // 退场动画里失焦重建不会撞上已释放的控制器。
    await tester.enterText(
      find.byKey(const Key('panel-log-keyword')),
      ' scheduler ',
    );
    await tester.pump();
    await _tapApply(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('筛选面板日志'), findsNothing);
    expect(panel.queries.last, {
      'level': 'error',
      'keyword': 'scheduler',
      'lines': 1000,
    });
    expect(_buffer(tester).lineAt(0), startsWith('[error] keyword=scheduler'));
    expect(find.textContaining('含「scheduler」'), findsOneWidget);
  });

  testWidgets('键盘弹起时「应用并刷新」仍能滚到并点中', (tester) async {
    _useNarrowLargeText(tester, height: 780);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    final panel = _FakePanel();
    DioClient.instance.dio.httpClientAdapter = panel.adapter;

    await _openPage(tester);
    await _openFilterSheet(tester);
    await tester.enterText(
      find.byKey(const Key('panel-log-keyword')),
      'update',
    );
    await tester.pump();
    // 测试里没有真的键盘挡着，所以要量位置：滚到之后按钮整个落在键盘上沿以上。
    final apply = find.text('应用并刷新');
    await tester.ensureVisible(apply);
    await tester.pump();
    expect(
      tester.getRect(find.byType(FilledButton)).bottom,
      lessThanOrEqualTo(780 - 300),
    );
    await _tapApply(tester);

    expect(tester.takeException(), isNull);
    expect(panel.queries.last, {'keyword': 'update', 'lines': 300});
  });

  testWidgets('自定义行数：任意填、超过面板上限按 10000 拉，点快捷档清掉自定义', (tester) async {
    final panel = _FakePanel();
    DioClient.instance.dio.httpClientAdapter = panel.adapter;

    await _openPage(tester);

    await _openFilterSheet(tester);
    await tester.enterText(find.byKey(const Key('panel-log-lines')), '5000');
    await tester.pump();
    expect(find.textContaining('本次拉取 5000 行'), findsOneWidget);
    await _tapApply(tester);
    expect(panel.queries.last, {'lines': 5000});
    expect(find.textContaining('最近 5000 行'), findsOneWidget);

    // 重新打开：上次的自定义行数回填在输入框里，快捷档都不选中。
    await _openFilterSheet(tester);
    final linesField = find.byKey(const Key('panel-log-lines'));
    expect(
      tester.widget<TextField>(linesField).controller!.text,
      '5000',
    );
    // 面板收到超过 10000 的值会悄悄退回 100 行，这边先夹到上限。
    await tester.enterText(linesField, '20000');
    await tester.pump();
    expect(find.textContaining('本次拉取 10000 行'), findsOneWidget);
    await _tapApply(tester);
    expect(panel.queries.last, {'lines': 10000});

    await _openFilterSheet(tester);
    await tester.tap(find.text('最近 300 行'));
    await tester.pump();
    expect(tester.widget<TextField>(linesField).controller!.text, isEmpty);
    await _tapApply(tester);
    expect(panel.queries.last, {'lines': 300});
  });

  testWidgets('同一帧里提交两次（输入法搜索键 + 点按钮）只关弹层，不把日志页一起弹掉', (
    tester,
  ) async {
    final panel = _FakePanel();
    DioClient.instance.dio.httpClientAdapter = panel.adapter;

    await _openPage(tester);
    await _openFilterSheet(tester);
    final keyword = find.byKey(const Key('panel-log-keyword'));
    await tester.showKeyboard(keyword);
    await tester.enterText(keyword, 'scheduler');
    await tester.pump();

    // 跨帧的连点不靠守卫：弹层一退场，路由就给整层套上 IgnorePointer，
    // 第二下落不到按钮上。守卫防的是两次提交挤在同一帧里，
    // 比如按输入法「搜索」键的同时点了按钮，两次都在重建之前到达。
    // 所以这里中间不推帧，搜索键提交后紧接着触发按钮。
    await tester.testTextInput.receiveAction(TextInputAction.search);
    tester.widget<FilledButton>(find.byType(FilledButton)).onPressed!();
    await _frames(tester);

    expect(tester.takeException(), isNull);
    expect(find.byType(PanelLogPage), findsOneWidget);
    expect(find.text('筛选面板日志'), findsNothing);
    expect(panel.queries.last, {'keyword': 'scheduler', 'lines': 300});
  });

  testWidgets('改了筛选马上重拉：上一次条件的回包晚到，不覆盖新结果', (tester) async {
    final panel = _FakePanel();
    DioClient.instance.dio.httpClientAdapter = panel.adapter;

    await _openPage(tester);

    // 「刷新日志」发出的请求挂住，趁它在路上改成只看 ERROR。
    panel.holdNext = true;
    await tester.tap(find.byKey(const Key('fullscreen-log-rerun')));
    await _frames(tester);
    expect(panel.gates, hasLength(1));

    await _openFilterSheet(tester);
    await tester.tap(find.text('仅 ERROR'));
    await tester.pump();
    await _tapApply(tester);
    expect(panel.queries.last, {'level': 'error', 'lines': 300});
    expect(_buffer(tester).lineAt(0), startsWith('[error]'));

    panel.gates.single.complete();
    await _frames(tester);
    expect(_buffer(tester).lineAt(0), startsWith('[error]'));
    expect(find.text('系统日志'), findsOneWidget);
  });
}
