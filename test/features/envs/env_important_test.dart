import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/features/envs/views/env_list_page.dart';
import 'package:daidai_app/shared/models/env_var.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_http_adapter.dart';

/// 面板列表项。[important] 为 null = 老面板（≤ v3.3.5）：列表项里根本没有这个键。
Map<String, dynamic> _env(
  int id,
  String name, {
  bool? important,
  bool pinned = false,
  String value = 'v',
}) => <String, dynamic>{
  'id': id,
  'name': name,
  'value': value,
  'remarks': '',
  'group': '',
  'enabled': true,
  'sort_order': pinned ? 1 : 0,
  'position': 1000.0 * id,
  // `?` 是空感知元素：important 为 null 时整个键都不放进去（模拟老面板）。
  'important': ?important,
};

/// 一次请求的快照：FakeHttpAdapter 只记 method / path，这里另记请求体。
class _Call {
  const _Call(this.method, this.path, this.data);

  final String method;
  final String path;
  final Object? data;
}

/// 假面板：列表 GET 恒回 [rows]，写操作一律回 200（不落库）；可以按请求让它失败。
class _FakePanel {
  _FakePanel(this.rows);

  final List<Map<String, dynamic>> rows;
  final calls = <_Call>[];

  /// 设了就先问它：返回非 null 就用它应答（模拟面板拒绝）。
  ResponseBody? Function(RequestOptions options)? reject;

  List<_Call> callsOf(String method, String path) => [
    for (final call in calls)
      if (call.method == method && call.path == path) call,
  ];

  ResponseBody handle(RequestOptions options) {
    calls.add(_Call(options.method, options.path, options.data));
    final rejected = reject?.call(options);
    if (rejected != null) {
      return rejected;
    }
    if (options.path == ApiEndpoints.envsGroups) {
      return jsonResponse({'data': <String>[]});
    }
    if (options.method == 'GET' && options.path == ApiEndpoints.envs) {
      return jsonResponse({'data': rows, 'total': rows.length});
    }
    return jsonResponse({'message': '操作成功'});
  }
}

Future<void> _openPage(
  WidgetTester tester,
  _FakePanel panel, {
  Size size = const Size(800, 1600),
}) async {
  // 改窗口尺寸必须同时把像素比设成 1.0：默认 3.0 时 384×800 实际只有 128×267 逻辑像素。
  tester.view.physicalSize = size;
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

/// 只在详情 / 导入弹层里找：页面 SnackBar、列表卡的左滑按钮也可能有同样的字。
Finder _inSheet(Finder finder) =>
    find.descendant(of: find.byType(BottomSheet), matching: finder);

Finder _inDialog(Finder finder) =>
    find.descendant(of: find.byType(AlertDialog), matching: finder);

/// [name] 那张卡上名字所在的那一行（名字、置顶图钉、「重要」标记都在这一行）。
Finder _nameRow(String name) =>
    find.ancestor(of: find.text(name), matching: find.byType(Row)).first;

/// 打开导入弹层 → 贴一份 JSON → 选「替换」→ 点「导入」，停在替换确认框上。
Future<void> _openReplaceConfirm(WidgetTester tester) async {
  await tester.tap(find.byTooltip('导入导出'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('导入变量'));
  await tester.pumpAndSettle();
  await tester.enterText(
    _inSheet(find.byType(TextField)),
    '[{"name":"NEW_A","value":"1"}]',
  );
  // 体检有 300ms 防抖。
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(find.text('替换'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('导入'));
  await tester.pumpAndSettle();
}

/// APP #16 ②「重要变量醒目显示、防误删」的 APP 侧回归保护（服务端不拦删除，保护全在客户端）。
///
/// 钉住：
/// 1. 形状探测：列表项没有 `important` 键（老面板）时一切「重要」界面都不出现、删除流程与今天逐字相同、
///    绝不发 `important`；
/// 2. 列表卡与排序卡显示「重要」与置顶图钉；
/// 3. 详情弹层：「标为重要」的请求体恰好是 `{important: bool}`、编辑保存不带它、置顶走 move-top / cancel-top、
///    失败原因写回弹层（弹层会盖住页面的 SnackBar）；窄屏与键盘弹起时不溢出；
/// 4. 单删重要变量专门确认；批量删除剔除重要项并写明跳过数；替换导入点名重要变量。
void main() {
  group('形状探测（模型）', () {
    test('没有 important 键 → null，isImportant 为 false', () {
      final env = EnvVar.fromJson(_env(1, 'A'));

      expect(env.important, isNull);
      expect(env.isImportant, isFalse);
    });

    test('true / false 原样', () {
      final important = EnvVar.fromJson(_env(1, 'A', important: true));
      final normal = EnvVar.fromJson(_env(2, 'B', important: false));

      expect(important.important, isTrue);
      expect(important.isImportant, isTrue);
      expect(normal.important, isFalse);
      expect(normal.isImportant, isFalse);
    });

    test('不是布尔（1、"true"）一律当没下发', () {
      for (final raw in <Object>[1, 'true']) {
        final env = EnvVar.fromJson({..._env(1, 'A'), 'important': raw});

        expect(env.important, isNull, reason: 'raw=$raw');
        expect(env.isImportant, isFalse, reason: 'raw=$raw');
      }
    });
  });

  group('老面板（列表项没有 important 键）', () {
    testWidgets('列表、排序模式、详情弹层都没有任何「重要」界面，置顶照常', (tester) async {
      final panel = _FakePanel([_env(1, 'OLD_A'), _env(2, 'OLD_B')]);
      await _openPage(tester, panel);
      expect(find.text('重要'), findsNothing);

      await tester.tap(find.text('排序'));
      await tester.pumpAndSettle();
      expect(find.text('重要'), findsNothing);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('OLD_A'));
      await tester.pumpAndSettle();
      expect(_inSheet(find.text('置顶')), findsOneWidget);
      expect(find.text('标为重要'), findsNothing);
      expect(find.text('取消重要'), findsNothing);
    });

    testWidgets('删除流程与今天逐字相同：左滑单删、批量删除', (tester) async {
      final panel = _FakePanel([_env(1, 'OLD_A'), _env(2, 'OLD_B')]);
      await _openPage(tester, panel);

      await tester.drag(find.text('OLD_A'), const Offset(-300, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除').first);
      await tester.pumpAndSettle();
      expect(find.text('删除环境变量'), findsOneWidget);
      expect(find.text('确定删除「OLD_A」吗？删除后无法恢复。'), findsOneWidget);
      expect(_inDialog(find.text('删除')), findsOneWidget);
      expect(find.text('仍要删除'), findsNothing);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('批量'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OLD_A'));
      await tester.pump();
      await tester.tap(find.text('OLD_B'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('批量删除'));
      await tester.pumpAndSettle();
      expect(find.text('确定删除选中的 2 个环境变量吗？'), findsOneWidget);

      await tester.tap(_inDialog(find.text('删除')));
      await tester.pumpAndSettle();

      expect(panel.callsOf('DELETE', ApiEndpoints.envsBatchDelete).single.data, {
        'ids': [1, 2],
      });
      expect(find.text('已批量删除 2 个环境变量'), findsOneWidget);
    });

    testWidgets('替换导入确认框与今天逐字相同（不提重要变量）', (tester) async {
      final panel = _FakePanel([_env(1, 'OLD_A'), _env(2, 'OLD_B')]);
      await _openPage(tester, panel);

      await _openReplaceConfirm(tester);

      expect(find.text('替换导入'), findsOneWidget);
      expect(_inDialog(find.textContaining('重要')), findsNothing);
    });

    testWidgets('有筛选时替换导入确认框同样不提重要变量（老面板根本没有这个概念）', (tester) async {
      // 没筛选时「数一数有几个重要变量」本来就得 0、不提示，测不出形状探测；
      // 有筛选时新面板会给一句笼统提醒，老面板必须连这句也没有（不变量 6）。
      final panel = _FakePanel([_env(1, 'OLD_A'), _env(2, 'OLD_B')]);
      await _openPage(tester, panel);
      // 搜索框有 300ms 防抖。
      await tester.enterText(find.byType(TextField).first, 'OLD');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      await _openReplaceConfirm(tester);

      expect(find.text('替换导入'), findsOneWidget);
      expect(_inDialog(find.textContaining('重要')), findsNothing);
    });
  });

  group('标记显示', () {
    testWidgets('重要变量在列表与排序模式都有「重要」，置顶变量有图钉，普通变量两者都没有', (tester) async {
      final panel = _FakePanel([
        _env(1, 'PIN_B', pinned: true, important: false),
        _env(2, 'CFG_A', important: true),
        _env(3, 'PLAIN_C', important: false),
      ]);
      await _openPage(tester, panel);

      void expectMarks() {
        expect(find.text('重要'), findsOneWidget);
        expect(find.byIcon(Icons.push_pin), findsOneWidget);
        expect(
          find.descendant(of: _nameRow('CFG_A'), matching: find.text('重要')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: _nameRow('PIN_B'),
            matching: find.byIcon(Icons.push_pin),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: _nameRow('PLAIN_C'), matching: find.text('重要')),
          findsNothing,
        );
        expect(
          find.descendant(
            of: _nameRow('PLAIN_C'),
            matching: find.byIcon(Icons.push_pin),
          ),
          findsNothing,
        );
      }

      expectMarks();

      await tester.tap(find.text('排序'));
      await tester.pumpAndSettle();
      expectMarks();
    });
  });

  group('窄屏与键盘', () {
    testWidgets('384 宽：超长名字 + 两个标记的卡片、最宽的详情弹层头部都不溢出，头部折成两行', (
      tester,
    ) async {
      final longName = 'VERY_LONG_IMPORTANT_CONFIG_NAME_${'X' * 40}';
      final panel = _FakePanel([
        _env(1, longName, pinned: true, important: true),
        _env(2, 'PLAIN_B', important: false),
      ]);
      await _openPage(tester, panel, size: const Size(384, 800));
      expect(tester.takeException(), isNull);
      expect(find.text('重要'), findsOneWidget);

      await tester.tap(find.text('排序'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();

      await tester.tap(find.text(longName));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull, reason: '不许有 RenderFlex 溢出');
      expect(_inSheet(find.text('取消置顶')), findsOneWidget);
      expect(_inSheet(find.text('取消重要')), findsOneWidget);
      expect(_inSheet(find.text('禁用')), findsOneWidget);
      final header = find
          .descendant(of: find.byType(BottomSheet), matching: find.byType(Row))
          .first;
      expect(
        tester.getSize(header).height,
        greaterThan(60),
        reason: '三个按钮在手机宽度下要折成两行（Wrap），不能挤成一行溢出',
      );
    });

    testWidgets('411×891 键盘弹起时「标为重要」失败：弹层内出现原因，内容可滚动、不溢出', (tester) async {
      // 已置顶、值很长：头部是「取消置顶」「标为重要」「禁用」三个按钮（最宽的组合之一），
      // 值的输入框撑满 4 行。
      final panel = _FakePanel([
        _env(1, 'PIN_CFG', pinned: true, important: false, value: 'x' * 400),
      ]);
      await _openPage(tester, panel, size: const Size(411, 891));
      await tester.tap(find.text('PIN_CFG'));
      await tester.pumpAndSettle();

      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();

      panel.reject = (options) =>
          options.method == 'PUT' && options.path == ApiEndpoints.envById(1)
          ? jsonResponse({'error': '更新失败'}, status: 500)
          : null;
      await tester.tap(find.text('标为重要'));
      await tester.pumpAndSettle();

      expect(_inSheet(find.text('更新失败')), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '键盘弹起 + 失败提示时不许底部溢出');
    });
  });

  group('详情弹层', () {
    testWidgets('标为重要：PUT /envs/2 的请求体恰好是 {important: true}，成功后关弹层并重拉', (
      tester,
    ) async {
      final panel = _FakePanel([
        _env(1, 'CFG_A', important: true),
        _env(2, 'PLAIN_B', important: false),
      ]);
      await _openPage(tester, panel);
      await tester.tap(find.text('PLAIN_B'));
      await tester.pumpAndSettle();
      final getsBefore = panel.callsOf('GET', ApiEndpoints.envs).length;

      await tester.tap(find.text('标为重要'));
      await tester.pumpAndSettle();

      expect(panel.callsOf('PUT', ApiEndpoints.envById(2)).single.data, {
        'important': true,
      });
      expect(find.byType(BottomSheet), findsNothing);
      expect(panel.callsOf('GET', ApiEndpoints.envs), hasLength(getsBefore + 1));
      expect(find.text('已将 PLAIN_B 标为重要'), findsOneWidget);
    });

    testWidgets('取消重要：请求体是 {important: false}', (tester) async {
      final panel = _FakePanel([
        _env(1, 'CFG_A', important: true),
        _env(2, 'PLAIN_B', important: false),
      ]);
      await _openPage(tester, panel);
      await tester.tap(find.text('CFG_A'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('取消重要'));
      await tester.pumpAndSettle();

      expect(panel.callsOf('PUT', ApiEndpoints.envById(1)).single.data, {
        'important': false,
      });
    });

    testWidgets('置顶 / 取消置顶：按是否已置顶选 move-top 或 cancel-top', (tester) async {
      final panel = _FakePanel([
        _env(1, 'PIN_A', pinned: true, important: false),
        _env(2, 'PLAIN_B', important: false),
      ]);
      await _openPage(tester, panel);

      await tester.tap(find.text('PLAIN_B'));
      await tester.pumpAndSettle();
      await tester.tap(_inSheet(find.text('置顶')));
      await tester.pumpAndSettle();
      expect(panel.callsOf('PUT', ApiEndpoints.envMoveTop(2)), hasLength(1));
      expect(find.byType(BottomSheet), findsNothing);

      await tester.tap(find.text('PIN_A'));
      await tester.pumpAndSettle();
      await tester.tap(_inSheet(find.text('取消置顶')));
      await tester.pumpAndSettle();
      expect(panel.callsOf('PUT', ApiEndpoints.envCancelTop(1)), hasLength(1));
      expect(panel.callsOf('PUT', ApiEndpoints.envMoveTop(1)), isEmpty);
    });

    testWidgets('「标为重要」失败：弹层不关，面板原话写在弹层里', (tester) async {
      final panel = _FakePanel([_env(2, 'PLAIN_B', important: false)])
        ..reject = (options) =>
            options.method == 'PUT' && options.path == ApiEndpoints.envById(2)
            ? jsonResponse({'error': '更新失败'}, status: 500)
            : null;
      await _openPage(tester, panel);
      await tester.tap(find.text('PLAIN_B'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('标为重要'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(_inSheet(find.text('更新失败')), findsOneWidget);
    });

    testWidgets('「禁用」失败：同样写回弹层（页面 SnackBar 被弹层盖住）', (tester) async {
      final panel = _FakePanel([_env(2, 'PLAIN_B', important: false)])
        ..reject = (options) => options.path == ApiEndpoints.envDisable(2)
            ? jsonResponse({'error': '禁用失败：面板繁忙'}, status: 500)
            : null;
      await _openPage(tester, panel);
      await tester.tap(find.text('PLAIN_B'));
      await tester.pumpAndSettle();

      await tester.tap(_inSheet(find.text('禁用')));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(_inSheet(find.text('禁用失败：面板繁忙')), findsOneWidget);
    });

    testWidgets('「保存」失败：同样写回弹层', (tester) async {
      final panel = _FakePanel([_env(2, 'PLAIN_B', important: false)])
        ..reject = (options) =>
            options.method == 'PUT' && options.path == ApiEndpoints.envById(2)
            ? jsonResponse({'error': '保存失败：变量名重复'}, status: 500)
            : null;
      await _openPage(tester, panel);
      await tester.tap(find.text('PLAIN_B'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(_inSheet(find.text('保存失败：变量名重复')), findsOneWidget);
    });

    testWidgets('编辑保存的请求体不带 important（面板是指针字段，不传不动）', (tester) async {
      final panel = _FakePanel([_env(1, 'CFG_A', important: true)]);
      await _openPage(tester, panel);
      await tester.tap(find.text('CFG_A'));
      await tester.pumpAndSettle();

      // 弹层里的输入框依次是：变量名、值、备注、分组。
      await tester.enterText(_inSheet(find.byType(TextField)).at(1), 'new-value');
      // 先让输入框失焦再点「保存」。原因是 v1.3.9 就有的时序（与本用例要钉的请求体无关）：
      // 弹层 Future 在 pop() 一调用就完成，`.then` 立刻 dispose 了控制器，而弹层还在退场动画里；
      // 聚焦着的输入框这时因为失焦重建，会撞上「TextEditingController was used after being
      // disposed」断言（只在 debug 下报，release 里该断言被编译掉）。复核时把页面换回 HEAD 版本，
      // 同一流程照样报这个断言。
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      final body =
          panel.callsOf('PUT', ApiEndpoints.envById(1)).single.data as Map;
      expect(body['value'], 'new-value');
      expect(
        body.containsKey('important'),
        isFalse,
        reason: '带上弹层打开时的旧值，会冲掉别处刚改过的标记',
      );
    });
  });

  group('删除保护', () {
    testWidgets('左滑删除重要变量：弹「删除重要变量」专门确认，取消不发请求，「仍要删除」才删', (
      tester,
    ) async {
      final panel = _FakePanel([
        _env(1, 'CFG_A', important: true),
        _env(2, 'PLAIN_B', important: false),
      ]);
      await _openPage(tester, panel);

      await tester.drag(find.text('CFG_A'), const Offset(-300, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除').first);
      await tester.pumpAndSettle();
      expect(find.text('删除重要变量'), findsOneWidget);
      expect(_inDialog(find.textContaining('CFG_A')), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(panel.callsOf('DELETE', ApiEndpoints.envById(1)), isEmpty);

      await tester.drag(find.text('CFG_A'), const Offset(-300, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('仍要删除'));
      await tester.pumpAndSettle();

      expect(panel.callsOf('DELETE', ApiEndpoints.envById(1)), hasLength(1));
    });

    testWidgets('批量删除选中重要 + 普通：确认框写明跳过数，只把普通变量发给面板', (tester) async {
      final panel = _FakePanel([
        _env(1, 'CFG_A', important: true),
        _env(2, 'PLAIN_B', important: false),
      ]);
      await _openPage(tester, panel);

      await tester.tap(find.text('批量'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CFG_A'));
      await tester.pump();
      await tester.tap(find.text('PLAIN_B'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('批量删除'));
      await tester.pumpAndSettle();

      expect(find.textContaining('有 1 个是重要变量'), findsOneWidget);
      await tester.tap(find.text('删除 1 个'));
      await tester.pumpAndSettle();

      expect(panel.callsOf('DELETE', ApiEndpoints.envsBatchDelete).single.data, {
        'ids': [2],
      });
      expect(find.text('已删除 1 个环境变量，跳过 1 个重要变量'), findsOneWidget);
    });

    testWidgets('批量删除只选了重要变量：不弹确认、不发请求、保留多选', (tester) async {
      final panel = _FakePanel([
        _env(1, 'CFG_A', important: true),
        _env(2, 'PLAIN_B', important: false),
      ]);
      await _openPage(tester, panel);

      await tester.tap(find.text('批量'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CFG_A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('批量删除'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.textContaining('没有可删除的'), findsOneWidget);
      expect(panel.callsOf('DELETE', ApiEndpoints.envsBatchDelete), isEmpty);
      expect(find.text('已选择 1 项'), findsOneWidget);
    });

    testWidgets('替换导入（没筛选）：确认框点名面板上有几个重要变量', (tester) async {
      final panel = _FakePanel([
        _env(1, 'CFG_A', important: true),
        _env(2, 'CFG_B', important: true),
        _env(3, 'PLAIN_C', important: false),
      ]);
      await _openPage(tester, panel);

      await _openReplaceConfirm(tester);

      expect(find.textContaining('其中包括 2 个重要变量'), findsOneWidget);
      expect(find.textContaining('（如果有）'), findsNothing);
    });

    testWidgets('替换导入（有筛选）：数不全，只给一句笼统的提醒', (tester) async {
      final panel = _FakePanel([
        _env(1, 'CFG_A', important: true),
        _env(2, 'CFG_B', important: true),
        _env(3, 'PLAIN_C', important: false),
      ]);
      await _openPage(tester, panel);
      // 搜索框有 300ms 防抖。
      await tester.enterText(find.byType(TextField).first, 'CFG');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      await _openReplaceConfirm(tester);

      expect(
        find.textContaining('标为「重要」的变量（如果有）也会一并清空'),
        findsOneWidget,
      );
      expect(find.textContaining('其中包括'), findsNothing);
    });
  });
}
