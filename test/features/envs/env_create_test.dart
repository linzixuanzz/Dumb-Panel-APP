import 'dart:async';

import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/features/envs/views/env_list_page.dart';
import 'package:daidai_app/shared/utils/api_utils.dart';
import 'package:daidai_app/shared/widgets/app_circle_add_button.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_http_adapter.dart';

/// 「不能单独添加环境变量」（APP issue #8）的回归保护。
///
/// 现场有两条独立的路径，用户看到的都是「加不进去」：
///
/// 1. **变量名为空**：创建按钮第一行是 `if (nameC.text.trim().isEmpty) return;`——
///    不提示、不关弹窗、也不发请求，点下去毫无反应。
/// 2. **变量名不合规**（`1abc`、含空格……）：面板 `POST /envs` **不回 4xx**，
///    它逐条跳过并把原因写进 `errors`，再用 **HTTP 200** 回
///    `{"message":"新增 0 条","data":[],"errors":["第 1 项: 变量名 'x' 格式无效"],"created":0}`。
///    dio 眼里这是一次成功的请求，于是 APP 照样弹「环境变量已创建」，列表里却什么都没多。
///    面板 Web 踩不到这条，因为 `EnvEditDialog.vue` 先做了客户端校验。
///
/// 所以第 2 组用例的锚点是：**HTTP 200 也可能是失败**。把 `create()` 里那段
/// `envCreateFailureMessage` 判断删掉，「假的创建成功」会立刻回来，这几条必须红。
void main() {
  const invalidNameReason = "第 1 项: 变量名 '1abc' 格式无效";

  /// 「一条都没建成」的信封，逐字对齐面板 server/handler/env.go 的 `Create`。
  Map<String, dynamic> rejectedEnvelope() => <String, dynamic>{
    'message': '新增 0 条',
    'data': <dynamic>[],
    'errors': <String>[invalidNameReason],
    'created': 0,
  };

  group('envCreateFailureMessage', () {
    test('200 + errors：把面板的原话交出去，不做任何包装', () {
      expect(envCreateFailureMessage(rejectedEnvelope()), invalidNameReason);
    });

    test('单条建成的信封（没有 errors / created）当成功', () {
      // 面板对「恰好建成 1 条且无错误」走的是 response.Created，形状与批量完全不同。
      expect(
        envCreateFailureMessage({
          'message': '创建成功',
          'data': {'id': 7, 'name': 'MY_TOKEN'},
        }),
        isNull,
      );
    });

    test('created > 0 且 errors 为空：成功', () {
      expect(
        envCreateFailureMessage({
          'message': '新增 1 条',
          'data': [
            {'id': 7},
          ],
          'errors': <String>[],
          'created': 1,
        }),
        isNull,
      );
    });

    test('created 是 0 但面板没给 errors：仍然算失败，用 message 兜底', () {
      expect(
        envCreateFailureMessage({
          'message': '新增 0 条',
          'errors': <String>[],
          'created': 0,
        }),
        '新增 0 条',
      );
    });

    test('认不出的形状一律当成功，不凭空造失败提示', () {
      // 老面板 / 反代改写过的响应体可能压根不是 Map。宁可漏报，也不能让正常创建
      // 变成「创建失败」——那比 issue #8 本身更糟。
      for (final raw in <dynamic>[null, '', 'OK', <dynamic>[], 42]) {
        expect(envCreateFailureMessage(raw), isNull, reason: 'raw=$raw');
      }
    });
  });

  group('EnvListNotifier.create', () {
    test('面板用 200 说「一条都没建成」时抛异常，而不是当成功', () async {
      final adapter = FakeHttpAdapter((_) => jsonResponse(rejectedEnvelope()));
      final notifier = EnvListNotifier(dio: dioWithAdapter(adapter));

      await expectLater(
        notifier.create('1abc', 'value'),
        throwsA(
          isA<EnvWriteException>().having(
            (e) => e.message,
            'message',
            invalidNameReason,
          ),
        ),
      );

      expect(
        adapter.requests,
        hasLength(1),
        reason: '一条都没建成就不必重拉列表，POST 之后不该再有请求',
      );
      expect(adapter.requests.single.method, 'POST');
    });

    test('这条失败经 UI 的 extractErrorMessage 出来的是面板原话，不是兜底文案', () async {
      // 页面 catch 里就是这么取文案的。取不出来的话用户只会看到「创建环境变量失败」，
      // 既不知道是名字的问题，也不知道该怎么改。
      final adapter = FakeHttpAdapter((_) => jsonResponse(rejectedEnvelope()));
      final notifier = EnvListNotifier(dio: dioWithAdapter(adapter));

      Object? captured;
      try {
        await notifier.create('1abc', 'value');
      } catch (error) {
        captured = error;
      }

      expect(captured, isNotNull, reason: '没抛出来的话页面根本没有提示的机会');
      expect(
        extractErrorMessage(captured, '创建环境变量失败'),
        invalidNameReason,
        reason: 'EnvWriteException 的字段叫 message 就是为了让这一步取得到',
      );
    });

    test('真正的 400 同样透出面板原话', () async {
      // 请求体过大 / 请求内容为空 / 请求参数错误走的是 {"error": ...} + 400，
      // 由 dio 抛异常，与上面那条是两条不同的链路，都要能说清楚原因。
      final adapter = FakeHttpAdapter(
        (_) => jsonResponse({'error': '请求体过大（最大 1MB）'}, status: 400),
      );
      final notifier = EnvListNotifier(dio: dioWithAdapter(adapter));

      Object? captured;
      try {
        await notifier.create('MY_TOKEN', 'x' * 16);
      } catch (error) {
        captured = error;
      }

      expect(captured, isA<DioException>());
      expect(
        extractErrorMessage(captured, '创建环境变量失败'),
        '请求体过大（最大 1MB）',
      );
    });

    test('真建成了就照常重拉列表，新行立刻出现', () async {
      final adapter = FakeHttpAdapter((options) {
        if (options.method == 'POST') {
          return jsonResponse({
            'message': '创建成功',
            'data': {'id': 7, 'name': 'MY_TOKEN'},
          }, status: 201);
        }
        if (options.path == ApiEndpoints.envsGroups) {
          return jsonResponse({'data': <String>[]});
        }
        return jsonResponse({
          'data': [
            {
              'id': 7,
              'name': 'MY_TOKEN',
              'value': 'value',
              'remarks': '',
              'group': '',
              'status': 0,
            },
          ],
          'total': 1,
        });
      });
      final notifier = EnvListNotifier(dio: dioWithAdapter(adapter));

      await notifier.create('MY_TOKEN', 'value');

      expect(notifier.state.envs, hasLength(1));
      expect(notifier.state.envs.single.name, 'MY_TOKEN');
      expect(
        adapter.requests.where(
          (item) => item.method == 'GET' && item.path == ApiEndpoints.envs,
        ),
        hasLength(1),
        reason: '创建成功后必须重拉一次，否则列表里看不到新行',
      );
    });
  });

  group('新建弹窗', () {
    testWidgets('变量名为空：给出就地提示、不关弹窗、一个请求都不发', (tester) async {
      final adapter = FakeHttpAdapter((options) {
        if (options.path == ApiEndpoints.envsGroups) {
          return jsonResponse({'data': <String>[]});
        }
        return jsonResponse({'data': <dynamic>[], 'total': 0});
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            envListProvider.overrideWith(
              (ref) => EnvListNotifier(dio: dioWithAdapter(adapter)),
            ),
          ],
          child: MaterialApp(theme: AppTheme.light(), home: const EnvListPage()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(AppCircleAddButton));
      await tester.pumpAndSettle();
      expect(find.text('新建环境变量'), findsOneWidget);

      final requestsBefore = adapter.requests.length;
      await tester.tap(find.widgetWithText(FilledButton, '创建'));
      await tester.pumpAndSettle();

      expect(
        find.text('变量名不能为空'),
        findsOneWidget,
        reason: '改动前这里是一句光秃秃的 return，用户点了什么都看不到',
      );
      expect(
        find.text('新建环境变量'),
        findsOneWidget,
        reason: '校验没过不能顺手把弹窗关掉，否则已填的值全没了',
      );
      expect(
        adapter.requests.length,
        requestsBefore,
        reason: '空名字不该发请求出去',
      );
      expect(adapter.requests.where((item) => item.method == 'POST'), isEmpty);
    });

    testWidgets('服务端拒绝：原因写回弹层内，而不是只塞进被弹层盖住的 SnackBar', (tester) async {
      // 失败时弹层刻意不关（免得用户重填），但 SnackBar 是挂在页面 Scaffold 上的，
      // 弹层作为根 Navigator 的路由整块压在它上面。实测这个视口下
      // snack = (0,528)-(800,600)，sheet = (0,244)-(800,600)，snack 完全被盖住 ——
      // 只发 SnackBar 的话，「看到面板给的具体原因」这条验收在真机上根本不成立。
      final adapter = FakeHttpAdapter((options) {
        if (options.method == 'POST') {
          return jsonResponse(rejectedEnvelope());
        }
        if (options.path == ApiEndpoints.envsGroups) {
          return jsonResponse({'data': <String>[]});
        }
        return jsonResponse({'data': <dynamic>[], 'total': 0});
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            envListProvider.overrideWith(
              (ref) => EnvListNotifier(dio: dioWithAdapter(adapter)),
            ),
          ],
          child: MaterialApp(theme: AppTheme.light(), home: const EnvListPage()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(AppCircleAddButton));
      await tester.pumpAndSettle();

      // 弹层里的第一个输入框就是「变量名」。取错了的话名字会是空的，
      // 走的就是上一条用例的空名分支、连请求都发不出去，这个用例会立刻红。
      await tester.enterText(
        find
            .descendant(
              of: find.byType(BottomSheet),
              matching: find.byType(TextField),
            )
            .first,
        '1abc',
      );
      await tester.tap(find.widgetWithText(FilledButton, '创建'));
      await tester.pumpAndSettle();

      expect(
        find.text('新建环境变量'),
        findsOneWidget,
        reason: '名字不合规时关掉弹层 = 让用户重填一遍',
      );
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text(invalidNameReason),
        ),
        findsOneWidget,
        reason: 'SnackBar 那一份在弹层底下，弹层内必须自己有一份',
      );
    });

    testWidgets('请求还没回来就把弹层划走：不许对已卸载的弹层 setState', (tester) async {
      // 上一条把失败原因写回了弹层，于是多出一条时序：回包到达时弹层可能已经没了。
      // StatefulBuilder 被 unmount 之后再 setSheetState 就是硬崩。
      final gate = Completer<void>();
      final adapter = FakeHttpAdapter((options) async {
        if (options.method == 'POST') {
          await gate.future;
          return jsonResponse(rejectedEnvelope());
        }
        if (options.path == ApiEndpoints.envsGroups) {
          return jsonResponse({'data': <String>[]});
        }
        return jsonResponse({'data': <dynamic>[], 'total': 0});
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            envListProvider.overrideWith(
              (ref) => EnvListNotifier(dio: dioWithAdapter(adapter)),
            ),
          ],
          child: MaterialApp(theme: AppTheme.light(), home: const EnvListPage()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(AppCircleAddButton));
      await tester.pumpAndSettle();
      await tester.enterText(
        find
            .descendant(
              of: find.byType(BottomSheet),
              matching: find.byType(TextField),
            )
            .first,
        '1abc',
      );
      await tester.tap(find.widgetWithText(FilledButton, '创建'));
      await tester.pump();

      // 点弹层上方的遮罩把它划走，此时 POST 还挂在 gate 上没回。
      await tester.tapAt(const Offset(400, 40));
      await tester.pumpAndSettle();
      expect(find.text('新建环境变量'), findsNothing);

      gate.complete();
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isNull,
        reason: '弹层已卸载，回包只能走 SnackBar，不能再 setState',
      );
    });
  });
}
