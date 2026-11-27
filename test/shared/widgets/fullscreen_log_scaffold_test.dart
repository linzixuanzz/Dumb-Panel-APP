import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/shared/utils/log_line_buffer.dart';
import 'package:daidai_app/shared/widgets/fullscreen_log_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('四态胶囊严格语义：失败态显示 ✕ 绝不显示 ✓，完成态显示 ✓', (tester) async {
    final buffer = LogLineBuffer()..replaceAll(['[08:00:01] 开始运行', 'Error: 令牌已失效']);
    addTearDown(buffer.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: FullscreenLogScaffold(
          title: '阿里云盘签到',
          subtitle: '日志 #1084 · 耗时 2.4s',
          statusLabel: '退出码 1',
          statusTone: FullscreenLogTone.failed,
          buffer: buffer,
          loading: false,
          onRerun: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final pill = find.byKey(const Key('fullscreen-log-status-pill'));
    expect(find.descendant(of: pill, matching: find.byIcon(Icons.close_rounded)), findsOneWidget);
    expect(find.descendant(of: pill, matching: find.byIcon(Icons.check_rounded)), findsNothing);
    expect(find.text('退出码 1'), findsOneWidget);
    // 发现报错行时底部自动露出「首处报错」定位芯片
    expect(find.byKey(const Key('fullscreen-log-first-error')), findsOneWidget);
    expect(find.byKey(const Key('fullscreen-log-rerun')), findsOneWidget);
  });

  testWidgets('页内搜索与独立护眼暗底切换、360 窄屏 1.3 倍字号无溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final buffer = LogLineBuffer()
      ..replaceAll([
        for (var i = 0; i < 40; i++)
          i == 10 || i == 25 ? 'line $i TOKEN_EXPIRED' : 'line $i normal output',
      ]);
    addTearDown(buffer.dispose);

    var stopCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: FullscreenLogScaffold(
          title: '一个名字非常非常长的自动化脚本任务名称',
          subtitle: '日志 #2048 · 实时耗时 12.8s',
          statusLabel: '实时输出',
          statusTone: FullscreenLogTone.running,
          buffer: buffer,
          loading: false,
          onStop: () => stopCount++,
          onOpenScript: () {},
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(tester.takeException(), isNull);

    // 默认是浅色暖纸底 #FAF9F6
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      AppColors.termBgLight,
    );

    // 点击顶栏切换独立护眼暗底 #14161A（不改变外层浅色 AppTheme）
    await tester.tap(find.byTooltip('切换护眼暗底终端'));
    await tester.pump();
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      AppColors.termBgDark,
    );
    expect(tester.takeException(), isNull);

    // 打开页内搜索并输入关键字
    await tester.tap(find.byTooltip('页内搜索'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'token_expired');
    await tester.pump();
    expect(find.text('1/2'), findsOneWidget);

    await tester.tap(find.byTooltip('下一处匹配'));
    await tester.pump();
    expect(find.text('2/2'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 底部停止运行按钮可点按
    await tester.tap(find.byKey(const Key('fullscreen-log-stop')));
    await tester.pump();
    expect(stopCount, 1);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
