import 'dart:async';

import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/features/tasks/providers/task_view_provider.dart';
import 'package:daidai_app/features/tasks/widgets/task_view_sheets.dart';
import 'package:daidai_app/shared/models/task_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// WCAG 对比度。
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// 新建视图的请求挂住不回，好在「保存中」那一刻截住按钮。
class _PendingTaskViewNotifier extends TaskViewNotifier {
  final pending = Completer<void>();

  @override
  Future<void> create({
    required String name,
    required List<TaskViewFilter> filters,
    required List<TaskViewSortRule> sortRules,
  }) => pending.future;
}

/// 视图编辑器点「保存」后按钮禁用（底色换成 fill），转圈要在禁用底上
/// 看得见：旧写法用 primaryBtnFg（白），浅色下压在约 #EDEDED 上只有 1.17:1。
void main() {
  final themes = [('浅色', AppTheme.light()), ('深色', AppTheme.dark())];

  for (final (name, theme) in themes) {
    testWidgets('$name：保存中的转圈对禁用按钮底 ≥ 3:1', (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final notifier = _PendingTaskViewNotifier();
      late BuildContext host;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [taskViewProvider.overrideWith((ref) => notifier)],
          child: MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  host = context;
                  return const SizedBox();
                },
              ),
            ),
          ),
        ),
      );
      final result = showTaskViewEditor(host);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, '视图名称'),
        '每日签到',
      );
      await tester.tap(find.text('保存'));
      // 转圈一直在转，不能 pumpAndSettle
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final spinnerFinder = find.byType(CircularProgressIndicator);
      expect(spinnerFinder, findsOneWidget);
      final button = find.ancestor(
        of: spinnerFinder,
        matching: find.byType(FilledButton),
      );
      // 前提：保存中按钮是禁用态，底色不是钴蓝
      expect(tester.widget<FilledButton>(button).onPressed, isNull);

      final buttonFill = tester
          .widget<Material>(
            find.descendant(of: button, matching: find.byType(Material)).first,
          )
          .color!;
      // fill 是半透明的，要叠到弹层的不透明底上才是看到的颜色
      final sheetColor = tester
          .widgetList<Material>(
            find.ancestor(of: button, matching: find.byType(Material)),
          )
          .map((material) => material.color)
          .firstWhere((color) => color != null && color.a == 1.0)!;
      final painted = Color.alphaBlend(buttonFill, sheetColor);

      final spinner = tester.widget<CircularProgressIndicator>(spinnerFinder);
      expect(spinner.color, isNotNull);
      // 转圈是图形不是文字，按 WCAG 非文字的 3:1
      expect(_contrast(spinner.color!, painted), greaterThanOrEqualTo(3.0));

      notifier.pending.complete();
      await tester.pumpAndSettle();
      expect((await result)?.changed, isTrue);
    });
  }
}
