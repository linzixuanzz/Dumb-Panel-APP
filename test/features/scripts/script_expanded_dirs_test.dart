import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/network/dio_client.dart';
import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/features/scripts/views/script_list_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_http_adapter.dart';

/// 脚本树展开状态的行为锁（issue #9）。
///
/// 用户原话：「app 的脚本管理界面上传一个脚本就自动刷新到主目录，多个脚本上传太痛苦了」。
/// 真因不是文件传错了地方，而是展开状态原本是**每个树节点自己的局部 State**：
/// 新建文件 / 新建文件夹 / 上传 / 重命名 / 移动 / 复制 / 删除这 7 处写操作之后都会
/// `loadTree()` 整体换掉 `state.tree`，整棵树的 widget 被重建，局部状态随之归零，
/// 界面折叠回顶层。连传三个脚本就得重新展开三次。
///
/// 所以下面钉四件事：
/// 1. 刷新之后展开状态还在 —— 把状态改回节点局部 State 就会红；
/// 2. 目录消失之后脏记录被清掉，同名目录重建时不会诈尸展开；
/// 3. 折叠父目录时子目录的记录一起丢掉 —— 展开状态提到页面级之后，这条
///    「折叠再展开只回到一级」的既有语义很容易被顺手改掉；
/// 4. 上传弹窗默认目录的口径：最近一次展开、且仍然存在的那个目录。
///
/// 第 4 条只能测到纯函数这一层：上传弹窗要先过 FilePicker 才打得开，
/// 测试环境里没有文件选择器，**页面上那处接线没有被用例覆盖**。
void main() {
  group('remapExpandedDirs：重命名 / 移动之后展开记录跟着走', () {
    test('目录本身被改名', () {
      expect(remapExpandedDirs({'jd'}, 'jd', 'jd_new'), {'jd_new'});
    });

    test('它下面已展开的子目录跟着换前缀', () {
      expect(
        remapExpandedDirs({'jd', 'jd/sign', 'jd/sign/daily'}, 'jd', 'task/jd'),
        {'task/jd', 'task/jd/sign', 'task/jd/sign/daily'},
      );
    });

    test('无关路径一个字都不动', () {
      expect(remapExpandedDirs({'other', 'jd'}, 'jd', 'jd2'), {'other', 'jd2'});
    });

    test('只换开头那一段：同名子目录不会被换第二次', () {
      // 用 replaceAll 的话这里会变成 `x/x`，子目录的展开记录整条对不上。
      expect(remapExpandedDirs({'a/b/a/b'}, 'a/b', 'x'), {'x/a/b'});
    });

    test('前缀像但不是同一级的目录不受影响', () {
      // `jd2` 不是 `jd` 的子目录，别被 startsWith 顺手带走。
      expect(remapExpandedDirs({'jd2'}, 'jd', 'task/jd'), {'jd2'});
    });

    test('空路径 / 原地改名：原样返回', () {
      expect(remapExpandedDirs({'jd'}, '', 'jd2'), {'jd'});
      expect(remapExpandedDirs({'jd'}, 'jd', ''), {'jd'});
      expect(remapExpandedDirs({'jd'}, 'jd', 'jd'), {'jd'});
    });

    test('顺序保持不变：末尾仍然是最近一次展开的目录', () {
      // 顺序是有语义的，上传弹窗的默认目录取的就是末尾那个。
      expect(remapExpandedDirs(['a', 'b', 'c'], 'b', 'z').toList(), [
        'a',
        'z',
        'c',
      ]);
    });
  });

  group('latestExpandedDirectory：上传弹窗的默认目录', () {
    test('取最近一次展开的那个，不是最深的那个', () {
      // 用户十分钟前展开了很深的 backup/2026/old，刚刚才展开 jd —— 他现在在 jd。
      expect(
        latestExpandedDirectory(const [
          'backup/2026/old',
          'jd',
        ], const {'backup/2026/old', 'jd'}),
        'jd',
      );
    });

    test('最近那个已经不在树里就继续往前找', () {
      expect(latestExpandedDirectory(const ['jd', 'tmp'], const {'jd'}), 'jd');
    });

    test('一个都不在树里：返回 null，由调用方回落', () {
      // 目录刚被删掉 / 改名的那一帧就是这个形态，不能把下拉里选不到的值塞回去。
      expect(latestExpandedDirectory(const ['tmp'], const {'jd'}), isNull);
    });

    test('没展开过任何目录：返回 null（默认落回根目录）', () {
      expect(latestExpandedDirectory(const [], const {'jd'}), isNull);
      expect(latestExpandedDirectory(const [], const <String>{}), isNull);
    });
  });

  group('脚本管理页：loadTree 之后展开状态必须还在', () {
    // 每条用例可以中途换掉它，模拟写操作之后重新拉到的新树。
    late List<Map<String, dynamic>> tree;

    setUp(() {
      // 页面 initState 会先读一次收藏夹（走 SharedPreferences），
      // 不给假实现会抛 MissingPluginException，后面的 loadTree 根本轮不到。
      SharedPreferences.setMockInitialValues(<String, Object>{});
      DioClient.instance.setBaseUrl('https://panel.test');
      DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter((options) {
        if (options.path == ApiEndpoints.scriptsTree) {
          return jsonResponse({'data': tree});
        }
        return jsonResponse({
          'error': '这些用例不该打 ${options.path}',
        }, status: 404);
      });
    });

    /// 面板 `/scripts/tree` 的最小节点形状：title / key / type，目录再带 children。
    Map<String, dynamic> dirNode(
      String name,
      String path,
      List<Map<String, dynamic>> children,
    ) {
      return {
        'title': name,
        'key': path,
        'type': 'directory',
        'children': children,
      };
    }

    Map<String, dynamic> fileNode(String name, String path) {
      return {'title': name, 'key': path, 'type': 'file'};
    }

    /// 这里刻意不用 `pumpAndSettle`：加载态是一个永远转下去的
    /// `CircularProgressIndicator`，settle 不下来。只给 initState 的微任务
    /// （读收藏夹 + loadTree）和假 HTTP 留几帧。
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    /// 与 `main.dart` 一样自己建 container：用例要拿到 notifier 去模拟
    /// 「写操作之后的那次刷新」，而写操作本身（上传 / 新建）在测试环境里跑不起来。
    Future<ProviderContainer> pumpPage(WidgetTester tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const ScriptListPage(),
          ),
        ),
      );
      await settle(tester);
      return container;
    }

    List<Map<String, dynamic>> twoLevelTree() {
      return [
        dirNode('jd', 'jd', [
          dirNode('sign', 'jd/sign', [fileNode('sign.py', 'jd/sign/sign.py')]),
        ]),
        fileNode('readme.md', 'readme.md'),
      ];
    }

    testWidgets('展开两级之后连刷三次（连传三个文件的形态），树还停在原处', (tester) async {
      tree = twoLevelTree();
      final container = await pumpPage(tester);

      // 初始只画顶层。
      expect(find.text('jd'), findsOneWidget);
      expect(find.text('sign'), findsNothing);

      await tester.tap(find.text('jd'));
      await tester.pump();
      await tester.tap(find.text('sign'));
      await tester.pump();
      expect(find.text('sign.py'), findsOneWidget);

      for (var i = 1; i <= 3; i++) {
        // 上传 / 新建 / 重命名 / 移动 / 复制 / 删除之后发生的事：整棵树被换掉。
        // 必须走 runAsync：testWidgets 默认跑在 FakeAsync 里，直接 await 一个由 dio
      // 驱动的 Future 时没有人推帧，它永远完不成（实测三条用例各挂满 10 分钟超时）。
      // 页面首次加载不受影响，因为那次是 initState 里 fire-and-forget、由 settle 的 pump 推进的。
      await tester.runAsync(
        () => container.read(scriptProvider.notifier).loadTree(),
      );
        await settle(tester);

        expect(
          find.text('sign'),
          findsOneWidget,
          reason: '第 $i 次刷新之后第一级就折叠了',
        );
        expect(
          find.text('sign.py'),
          findsOneWidget,
          reason: 'issue #9：第 $i 次刷新之后折叠回了顶层',
        );
      }
    });

    testWidgets('折叠父目录时，子目录的展开记录一起丢掉', (tester) async {
      tree = twoLevelTree();
      final container = await pumpPage(tester);

      await tester.tap(find.text('jd'));
      await tester.pump();
      await tester.tap(find.text('sign'));
      await tester.pump();
      expect(find.text('sign.py'), findsOneWidget);

      // 折叠 jd：整棵子树收起来。
      await tester.tap(find.text('jd'));
      await tester.pump();
      expect(find.text('sign'), findsNothing);

      // 再展开 jd：只该看到 sign 这一级。
      // 改造前子节点的展开状态寄存在子 widget 的局部 State 上，父目录一折叠子 widget
      // 就被销毁，再展开必然是收拢的 —— 把展开状态提到页面级不该顺手改掉这条语义。
      await tester.tap(find.text('jd'));
      await tester.pump();
      expect(find.text('sign'), findsOneWidget);
      expect(
        find.text('sign.py'),
        findsNothing,
        reason: '折叠时没丢掉子目录的记录：再展开把整棵子树炸开了',
      );

      // 刷新一次：折叠时丢掉的记录不会被 loadTree 复活。
      // 必须走 runAsync：testWidgets 默认跑在 FakeAsync 里，直接 await 一个由 dio
      // 驱动的 Future 时没有人推帧，它永远完不成（实测三条用例各挂满 10 分钟超时）。
      // 页面首次加载不受影响，因为那次是 initState 里 fire-and-forget、由 settle 的 pump 推进的。
      await tester.runAsync(
        () => container.read(scriptProvider.notifier).loadTree(),
      );
      await settle(tester);
      expect(find.text('sign'), findsOneWidget);
      expect(find.text('sign.py'), findsNothing);
    });

    testWidgets('目录消失之后脏记录被清掉，同名目录重建时不会诈尸展开', (tester) async {
      tree = twoLevelTree();
      final container = await pumpPage(tester);

      await tester.tap(find.text('jd'));
      await tester.pump();
      await tester.tap(find.text('sign'));
      await tester.pump();
      expect(find.text('sign.py'), findsOneWidget);

      // jd/sign 被删掉（改名、移走是同一个形态）：新树里不再有它。
      tree = [
        dirNode('jd', 'jd', [fileNode('note.md', 'jd/note.md')]),
      ];
      // 必须走 runAsync：testWidgets 默认跑在 FakeAsync 里，直接 await 一个由 dio
      // 驱动的 Future 时没有人推帧，它永远完不成（实测三条用例各挂满 10 分钟超时）。
      // 页面首次加载不受影响，因为那次是 initState 里 fire-and-forget、由 settle 的 pump 推进的。
      await tester.runAsync(
        () => container.read(scriptProvider.notifier).loadTree(),
      );
      await settle(tester);

      expect(find.text('sign'), findsNothing);
      expect(
        find.text('note.md'),
        findsOneWidget,
        reason: 'jd 自己还在，应该仍是展开的',
      );

      // 同名目录又被建回来：它必须是折叠的 —— 那条记录已经在上一步被清掉了。
      tree = twoLevelTree();
      // 必须走 runAsync：testWidgets 默认跑在 FakeAsync 里，直接 await 一个由 dio
      // 驱动的 Future 时没有人推帧，它永远完不成（实测三条用例各挂满 10 分钟超时）。
      // 页面首次加载不受影响，因为那次是 initState 里 fire-and-forget、由 settle 的 pump 推进的。
      await tester.runAsync(
        () => container.read(scriptProvider.notifier).loadTree(),
      );
      await settle(tester);

      expect(find.text('sign'), findsOneWidget);
      expect(
        find.text('sign.py'),
        findsNothing,
        reason: '脏记录复活了：新建的同名目录不该是展开的',
      );
    });

    testWidgets('搜索只是暂时看不见，不能把没命中的目录的展开记录清掉', (tester) async {
      tree = twoLevelTree();
      await pumpPage(tester);

      await tester.tap(find.text('jd'));
      await tester.pump();
      await tester.tap(find.text('sign'));
      await tester.pump();
      expect(find.text('sign.py'), findsOneWidget);

      // 关键词只命中根目录下那个文件，整棵 jd 子树被过滤掉。
      await tester.enterText(find.byType(TextField), 'readme');
      await settle(tester);
      expect(find.text('jd'), findsNothing);

      await tester.enterText(find.byType(TextField), '');
      await settle(tester);

      expect(
        find.text('sign.py'),
        findsOneWidget,
        reason: '展开记录按整棵树过滤，不按搜索结果过滤',
      );
    });
  });
}
