import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/core/theme/design_tokens.dart';
import 'package:daidai_app/shared/widgets/app_sheet.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 卡片式弹层（design §2）：默认走 CupertinoSheetRoute（3.41.9 实测可用），
/// 减少动画时只淡入，fullHeight: false 回落 showModalBottomSheet。
void main() {
  Future<BuildContext> pumpHost(
    WidgetTester tester, {
    bool reduceMotion = false,
    bool dark = false,
  }) async {
    late BuildContext hostContext;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              hostContext = context;
              return const Center(child: Text('底下的页面'));
            },
          ),
        ),
      ),
    );
    return hostContext;
  }

  ModalRoute<dynamic>? routeOf(WidgetTester tester, String text) =>
      ModalRoute.of(tester.element(find.text(text)));

  testWidgets('默认：CupertinoSheetRoute，内容在 Material 里、底色 palette.bg、带把手；pop 返回值', (
    tester,
  ) async {
    final context = await pumpHost(tester);
    final result = showAppSheet<String>(
      context: context,
      builder: (sheetContext) => Center(
        child: TextButton(
          onPressed: () => Navigator.of(sheetContext).pop('done'),
          child: const Text('详情内容'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('详情内容'), findsOneWidget);
    expect(routeOf(tester, '详情内容'), isA<CupertinoSheetRoute<String>>());
    // 弹层外壳是一层底色为 palette.bg 的 Material（TextButton 自己也有一层透明的）
    expect(
      find.ancestor(
        of: find.text('详情内容'),
        matching: find.byWidgetPredicate(
          (w) => w is Material && w.color == AppPalette.light.bg,
        ),
      ),
      findsOneWidget,
    );
    // 背后的页面仍在（被缩小，不是被替换）
    expect(find.text('底下的页面', skipOffstage: false), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('详情内容'));
    await tester.pumpAndSettle();
    expect(await result, 'done');
    expect(find.text('详情内容'), findsNothing);
  });

  testWidgets('背后的页面缩小（iOS 卡片式模态）', (tester) async {
    final context = await pumpHost(tester);
    final before = tester.getRect(find.text('底下的页面'));
    showAppSheet<void>(context: context, builder: (_) => const Text('弹层'));
    await tester.pumpAndSettle();
    // 底下那页外面包了缩放变换：同一段文字在屏幕上的实际宽度变小了
    final after = tester.getRect(find.text('底下的页面'));
    expect(after.width, lessThan(before.width));
  });

  testWidgets('减少动画：不是 CupertinoSheetRoute，只做淡入', (tester) async {
    final context = await pumpHost(tester, reduceMotion: true);
    showAppSheet<void>(context: context, builder: (_) => const Text('弹层内容'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final route = routeOf(tester, '弹层内容');
    expect(route, isNot(isA<CupertinoSheetRoute<void>>()));
    final fade = tester.widget<FadeTransition>(
      find.ancestor(of: find.text('弹层内容'), matching: find.byType(FadeTransition)).first,
    );
    expect(fade.opacity.value, lessThan(1));
    await tester.pumpAndSettle();
    expect(find.text('弹层内容'), findsOneWidget);

    // 点遮罩关闭
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('弹层内容'), findsNothing);
  });

  testWidgets('fullHeight: false：回落 showModalBottomSheet，内容多高就多高', (tester) async {
    final context = await pumpHost(tester, dark: true);
    showAppSheet<void>(
      context: context,
      fullHeight: false,
      builder: (_) => const SizedBox(height: 120, child: Text('短弹层')),
    );
    await tester.pumpAndSettle();
    expect(routeOf(tester, '短弹层'), isA<ModalBottomSheetRoute<void>>());
    final material = tester.widget<Material>(
      find.ancestor(of: find.text('短弹层'), matching: find.byType(Material)).first,
    );
    expect(material.color, AppPalette.dark.bg);
    final sheetHeight = tester.getSize(find.byType(Material).last).height;
    expect(sheetHeight, lessThan(300));
  });
}
