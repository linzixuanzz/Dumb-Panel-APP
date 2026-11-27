import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/features/envs/views/env_list_page.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_http_adapter.dart';

/// APP #29：被自动禁用的变量（多是 cookie 失效）改完值保存就顺带启用。
///
/// 钉住：
/// 1. 已禁用 + 值改了 → `PUT /envs/:id` 带 `enabled: true`，提示「已保存并启用」；
/// 2. 已禁用 + 只改备注（值没动）→ 不带 `enabled`，不动启用状态；
/// 3. 已启用的变量改值 → 不带 `enabled`（面板是指针字段，不传不动）；
/// 4. 敏感值（如 JD_COOKIE）没揭开就保存 → 值没动，不带 `enabled`。
///
/// 前三条用非敏感变量名：敏感值在弹层里先遮住，值输入框要验证后才出现。
Map<String, dynamic> _env(int id, String name, {required bool enabled}) =>
    <String, dynamic>{
      'id': id,
      'name': name,
      'value': 'old-value',
      'remarks': '',
      'group': '',
      'enabled': enabled,
      'sort_order': 0,
      'position': 1000.0 * id,
    };

class _Call {
  const _Call(this.method, this.path, this.data);

  final String method;
  final String path;
  final Object? data;
}

class _FakePanel {
  _FakePanel(this.rows);

  final List<Map<String, dynamic>> rows;
  final calls = <_Call>[];

  List<_Call> callsOf(String method, String path) => [
    for (final call in calls)
      if (call.method == method && call.path == path) call,
  ];

  ResponseBody handle(RequestOptions options) {
    calls.add(_Call(options.method, options.path, options.data));
    if (options.path == ApiEndpoints.envsGroups) {
      return jsonResponse({'data': <String>[]});
    }
    if (options.method == 'GET' && options.path == ApiEndpoints.envs) {
      return jsonResponse({'data': rows, 'total': rows.length});
    }
    return jsonResponse({'message': '操作成功'});
  }
}

Future<void> _openPage(WidgetTester tester, _FakePanel panel) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        envListProvider.overrideWith(
          (ref) => EnvListNotifier(
            dio: dioWithAdapter(FakeHttpAdapter(panel.handle)),
          ),
        ),
      ],
      child: MaterialApp(theme: AppTheme.light(), home: const EnvListPage()),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _inSheet(Finder finder) =>
    find.descendant(of: find.byType(BottomSheet), matching: finder);

/// 打开 [name] 的详情弹层，按需改值 / 备注，再点「保存」。
/// 非敏感变量弹层里的输入框依次是：变量名、值、备注、分组。
Future<void> _editAndSave(
  WidgetTester tester,
  String name, {
  String? value,
  String? remarks,
}) async {
  await tester.tap(find.text(name));
  await tester.pumpAndSettle();
  if (value != null) {
    await tester.enterText(_inSheet(find.byType(TextField)).at(1), value);
  }
  if (remarks != null) {
    await tester.enterText(_inSheet(find.byType(TextField)).at(2), remarks);
  }
  // 先失焦再点保存，理由见 env_important_test「编辑保存的请求体不带 important」。
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  await tester.tap(_inSheet(find.text('保存')));
  await tester.pumpAndSettle();
}

void main() {
  group('APP #29 编辑已禁用变量保存后自动启用', () {
    testWidgets('已禁用 + 改了值：请求带 enabled:true，提示「已保存并启用」', (tester) async {
      final panel = _FakePanel([_env(1, 'PLAIN_A', enabled: false)]);
      await _openPage(tester, panel);

      await _editAndSave(tester, 'PLAIN_A', value: 'new-value');

      final body =
          panel.callsOf('PUT', ApiEndpoints.envById(1)).single.data as Map;
      expect(body['value'], 'new-value');
      expect(body['enabled'], isTrue);
      expect(find.text('已保存并启用'), findsOneWidget);
    });

    testWidgets('已禁用 + 只改备注：不带 enabled，不动启用状态', (tester) async {
      final panel = _FakePanel([_env(1, 'PLAIN_A', enabled: false)]);
      await _openPage(tester, panel);

      await _editAndSave(tester, 'PLAIN_A', remarks: '主账号');

      final body =
          panel.callsOf('PUT', ApiEndpoints.envById(1)).single.data as Map;
      expect(body['remarks'], '主账号');
      expect(body.containsKey('enabled'), isFalse);
      expect(find.text('已保存'), findsOneWidget);
    });

    testWidgets('已启用的变量改值：不带 enabled', (tester) async {
      final panel = _FakePanel([_env(1, 'PLAIN_A', enabled: true)]);
      await _openPage(tester, panel);

      await _editAndSave(tester, 'PLAIN_A', value: 'new-value');

      final body =
          panel.callsOf('PUT', ApiEndpoints.envById(1)).single.data as Map;
      expect(body.containsKey('enabled'), isFalse);
      expect(find.text('已保存'), findsOneWidget);
    });

    testWidgets('敏感值没揭开：值没动，只改备注也不带 enabled', (tester) async {
      final panel = _FakePanel([_env(1, 'JD_COOKIE', enabled: false)]);
      await _openPage(tester, panel);

      await tester.tap(find.text('JD_COOKIE'));
      await tester.pumpAndSettle();
      // 敏感值被遮住：输入框只剩变量名、备注、分组三个。
      expect(_inSheet(find.byType(TextField)), findsNWidgets(3));
      await tester.enterText(_inSheet(find.byType(TextField)).at(1), '主账号');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await tester.tap(_inSheet(find.text('保存')));
      await tester.pumpAndSettle();

      final body =
          panel.callsOf('PUT', ApiEndpoints.envById(1)).single.data as Map;
      expect(body['value'], 'old-value');
      expect(body['remarks'], '主账号');
      expect(body.containsKey('enabled'), isFalse);
    });
  });
}
