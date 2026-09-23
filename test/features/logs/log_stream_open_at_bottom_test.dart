import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/network/dio_client.dart';
import 'package:daidai_app/features/logs/views/log_stream_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_http_adapter.dart';

/// issue #147：已结束的日志按账户偏好决定打开在顶部还是底部。
void main() {
  const logId = 7;
  const menuLabel = '打开已结束的日志时定位到底部';

  /// 面板存着的 list 组；null 表示面板没有 list 组（≤ v3.3.0）。
  late Map<String, dynamic>? list;

  /// 面板认不认 log_open_at_bottom（v3.3.1 / v3.3.2 不认：PUT 回 200 但不存）。
  late bool panelKnowsKey;
  late List<Object?> putBodies;

  setUp(() {
    list = null;
    panelKnowsKey = true;
    putBodies = <Object?>[];
    DioClient.instance.setBaseUrl('https://panel.test');
    DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter((options) {
      if (options.path == ApiEndpoints.logById(logId)) {
        return jsonResponse({
          'data': {
            'id': logId,
            'task_id': 12,
            'task_name': '京东签到',
            'content': List<String>.generate(300, (i) => 'line $i').join('\n'),
            'status': 0, // task_logs.status 0 = 成功，已结束
            'log_path': '',
            'started_at': '2026-09-23T10:00:00Z',
            'created_at': '2026-09-23T10:00:00Z',
          },
        });
      }
      if (options.path == ApiEndpoints.preferences) {
        if (options.method == 'PUT') {
          putBodies.add(options.data);
          final patch = (options.data as Map)['list'] as Map;
          if (panelKnowsKey) {
            list = {...?list, ...patch.cast<String, dynamic>()};
          }
        }
        return jsonResponse({
          'editor': <String, dynamic>{},
          'stored': false,
          'list': ?list,
        });
      }
      // 日志底色（/system/panel-settings）等：给空，走主题默认。
      return jsonResponse(<String, dynamic>{});
    });
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: LogStreamPage(logId: logId)),
      ),
    );
    // 加载中是常驻 spinner，先手推几帧让假 HTTP 回来，再 settle。
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();
  }

  ScrollPosition position(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable).last).position;

  Finder menuItem() => find.byWidgetPredicate((w) => w is CheckedPopupMenuItem);

  bool menuItemChecked(WidgetTester tester) =>
      tester.widget<CheckedPopupMenuItem<Object?>>(menuItem()).checked;

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
  }

  testWidgets('存过 true：打开就在底部', (tester) async {
    list = {'log_open_at_bottom': true};
    await pumpPage(tester);

    final p = position(tester);
    expect(p.pixels, closeTo(p.maxScrollExtent, 0.5));
    expect(find.text('line 299'), findsOneWidget);
  });

  testWidgets('存过 false：从顶部开始，没有回到底部按钮', (tester) async {
    list = {'log_open_at_bottom': false};
    await pumpPage(tester);

    expect(position(tester).pixels, 0);
    expect(find.text('line 0'), findsOneWidget);
    expect(find.byTooltip('回到底部'), findsNothing);
  });

  testWidgets('≤ v3.3.0（没有 list 组）：保持 APP 原来的打开即在底部', (tester) async {
    list = null;
    await pumpPage(tester);

    final p = position(tester);
    expect(
      p.pixels,
      closeTo(p.maxScrollExtent, 0.5),
      reason: '没设过时按 kOpenFinishedLogAtBottomDefault，老面板用户升级 APP 后不能变成顶部',
    );
  });

  testWidgets('≤ v3.3.0：菜单里没有这一项，也没有任何 PUT', (tester) async {
    list = null;
    await pumpPage(tester);

    await openMenu(tester);
    expect(find.text(menuLabel), findsNothing);
    expect(putBodies, isEmpty);
  });

  testWidgets('v3.3.3：菜单里切换，PUT 只带这一个键，眼前不重排', (tester) async {
    list = {'log_open_at_bottom': false};
    await pumpPage(tester);

    await openMenu(tester);
    // 点整个菜单项而不是里面的文字：文字在 CheckedPopupMenuItem 的 IgnorePointer 里。
    await tester.tap(menuItem());
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(putBodies.single, {
      'list': {'log_open_at_bottom': true},
    });
    expect(position(tester).pixels, 0, reason: '只影响下次打开');

    await tester.pumpAndSettle(const Duration(seconds: 5));
    await openMenu(tester);
    expect(menuItemChecked(tester), isTrue);
  });

  testWidgets('v3.3.1 / v3.3.2：点了提示升级，勾选状态弹回去', (tester) async {
    list = <String, dynamic>{};
    panelKnowsKey = false;
    await pumpPage(tester);

    await openMenu(tester);
    final before = menuItemChecked(tester);
    await tester.tap(menuItem());
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.text('当前面板版本不支持，请升级到 v3.3.3 或更高'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 5));
    await openMenu(tester);
    expect(menuItemChecked(tester), before);
  });
}
