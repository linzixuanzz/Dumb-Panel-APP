import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/shared/widgets/app_state_views.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 这里原来是一个用例体只有 `// TODO` 的空壳 smoke test。
/// 它必然通过，于是「flutter test 全绿」变成了一句没有信息量的话。
///
/// 换成真正验证得到东西的用例：列表三态里「空」和「失败」必须是两种界面。
/// 完整的应用启动 smoke test 需要 secure_storage / shared_preferences /
/// package_info 等一堆平台通道，起不来也没有回归价值，故不做。
///
/// 注意：断言用 `find.text` / `find.byIcon` 而不是 `find.byType(OutlinedButton)`——
/// `find.byType` 比的是 runtimeType，`OutlinedButton.icon` 返回的是私有子类，匹配不上，
/// 写成 `findsNothing` 会变成一条永远通过的假断言。
void main() {
  Widget wrap(Widget child) {
    return MaterialApp(theme: AppTheme.light(), home: Scaffold(body: child));
  }

  testWidgets('错误态给出原因和重试按钮，点击能触发重试', (WidgetTester tester) async {
    var retried = 0;

    await tester.pumpWidget(
      wrap(
        AppErrorView(
          title: '任务加载失败',
          message: '无法连接到面板，请检查网络或面板是否在线',
          onRetry: () => retried++,
        ),
      ),
    );

    expect(find.text('任务加载失败'), findsOneWidget);
    expect(find.text('无法连接到面板，请检查网络或面板是否在线'), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pump();

    expect(retried, 1);
  });

  testWidgets('空态不带重试按钮：真的没数据和拿不到数据是两回事', (WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(const AppEmptyView(icon: Icons.inbox_outlined, message: '暂无任务')),
    );

    expect(find.text('暂无任务'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    expect(find.byIcon(Icons.refresh), findsNothing);
  });

  testWidgets('错误态没有 onRetry 时不显示重试按钮', (WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(const AppErrorView(title: '加载失败', message: '面板返回错误（HTTP 500）')),
    );

    expect(find.text('面板返回错误（HTTP 500）'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    expect(find.byIcon(Icons.refresh), findsNothing);
  });
}
