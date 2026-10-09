import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/features/dashboard/widgets/trend_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pumpChart(WidgetTester tester, List<String> dates) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: ListView(
          children: [
            TrendChart(
              data: [
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

/// 首页「近7天执行统计」横轴日期（#158 调研顺带发现）。
///
/// 面板 `daily_stats[].date` 一直是 5 位的 `MM-DD`（server/handler/system.go 的 Format("01-02")），
/// 以前 APP 对它 `substring(5)`，4 个横轴标签全是空串，对真实面板从来没画出过字。
/// 7 天时 interval = 2，只画下标 0 / 2 / 4 / 6 这四个标签。
void main() {
  testWidgets('面板下发 5 位 MM-DD：横轴原样显示 10-01 这样的日期，没有空标签', (tester) async {
    await _pumpChart(tester, [
      '10-01',
      '10-02',
      '10-03',
      '10-04',
      '10-05',
      '10-06',
      '10-07',
    ]);

    for (final label in ['10-01', '10-03', '10-05', '10-07']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text(''), findsNothing, reason: '改前正好是 4 个空串标签');
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

    for (final label in ['10-01', '10-03', '10-05', '10-07']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text(''), findsNothing);
  });
}
