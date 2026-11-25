import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/features/overview/widgets/execution_bar_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pumpChart(WidgetTester tester, List<String> dates) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: ListView(
          children: [
            ExecutionBarChart(
              days: [
                for (final date in dates)
                  <String, dynamic>{
                    'date': date,
                    'success': 1,
                    'failed': 0,
                    'aborted': 0,
                  },
              ],
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 概览「每日执行」横轴日期（从 v1.x 趋势图的用例迁来，#158 调研顺带发现）。
///
/// 面板 `daily_stats[].date` 一直是 5 位的 `MM-DD`，以前 APP 对它 `substring(5)`，
/// 横轴标签全是空串。7 天时每天都标，最后一天（今天）写「今天」。
void main() {
  testWidgets('面板下发 5 位 MM-DD：横轴原样显示，最后一天写「今天」', (tester) async {
    await _pumpChart(tester, [
      '10-01',
      '10-02',
      '10-03',
      '10-04',
      '10-05',
      '10-06',
      '10-07',
    ]);

    for (final label in ['10-01', '10-03', '10-06']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('今天'), findsOneWidget);
    expect(find.text('10-07'), findsNothing, reason: '今天写「今天」，不写日期');
    expect(find.text(''), findsNothing);
  });

  testWidgets('10 位 YYYY-MM-DD：只取月日', (tester) async {
    await _pumpChart(tester, [
      '2026-10-01',
      '2026-10-02',
      '2026-10-03',
      '2026-10-04',
      '2026-10-05',
      '2026-10-06',
      '2026-10-07',
    ]);

    for (final label in ['10-01', '10-03', '10-06']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text(''), findsNothing);
  });

  testWidgets('30 天：横轴只标从今天往回每隔几天一个，不挤在一起', (tester) async {
    await _pumpChart(tester, [
      for (var i = 1; i <= 30; i++) '11-${i.toString().padLeft(2, '0')}',
    ]);
    // 30 / 6 向上取整 = 5：今天(11-30)、11-25、11-20、11-15、11-10、11-05
    expect(find.text('今天'), findsOneWidget);
    for (final label in ['11-25', '11-20', '11-15', '11-10', '11-05']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('11-29'), findsNothing);
    expect(find.text('11-01'), findsNothing);
  });

  testWidgets('老面板没有 aborted：图例不出「终止」', (tester) async {
    await _pumpChart(tester, ['10-01', '10-02']);
    expect(find.text('成功'), findsOneWidget);
    expect(find.text('终止'), findsNothing);
  });
}
