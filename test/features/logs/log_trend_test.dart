import 'package:daidai_app/features/logs/utils/log_trend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('projectTodayTotal：今天按已过时长折算成全天预估', () {
    test('15:00 过了 62.5%，已跑 100 次 → 预估 160 次', () {
      expect(projectTodayTotal(100, DateTime(2026, 11, 25, 15)), 160);
    });

    test('凌晨刚过几分钟时按至少 2 小时算，不会预估出虚高的点', () {
      // 00:10 跑了 1 次：直接除是 144 次，按 2 小时下限是 12 次
      expect(projectTodayTotal(1, DateTime(2026, 11, 25, 0, 10)), 12);
    });

    test('预估值永远不小于实际值', () {
      expect(
        projectTodayTotal(37, DateTime(2026, 11, 25, 23, 59, 59)),
        greaterThanOrEqualTo(37),
      );
    });
  });

  group('averageDailyTotal：每日平均', () {
    test('只算已经过完的天，不把还没过完的今天算进去', () {
      const days = [
        LogDayCount(date: '11-23', total: 140),
        LogDayCount(date: '11-24', total: 160),
        LogDayCount(date: '11-25', total: 20),
      ];
      expect(averageDailyTotal(days, 999), 150);
    });

    test('只有今天一天时退回今天的预估', () {
      const days = [LogDayCount(date: '11-25', total: 20)];
      expect(averageDailyTotal(days, 48), 48);
    });
  });

  group('LogSummary.fromDashboard', () {
    test('v3 面板：读今天的四档计数与按天总数（成功 + 失败 + 终止）', () {
      final summary = LogSummary.fromDashboard({
        'today_logs': 29,
        'success_logs': 26,
        'failed_logs': 1,
        'aborted_logs': 2,
        'running_tasks': 3,
        'daily_stats': [
          {'date': '11-24', 'success': 10, 'failed': 2, 'aborted': 1},
          {'date': '11-25', 'success': 26, 'failed': 1, 'aborted': 2},
        ],
      })!;
      expect(summary.todayTotal, 29);
      expect(summary.running, 3);
      expect(summary.days.map((d) => d.total), [13, 29]);
      expect(summary.days.first.dayLabel, '24日');
      expect(summary.sentence, '今天执行 29 次，1 次失败');
    });

    test('老面板没有 today_logs / aborted：按三档相加兜底，不报错', () {
      final summary = LogSummary.fromDashboard({
        'success_logs': 5,
        'failed_logs': 0,
        'daily_stats': [
          {'date': '11-25', 'success': 5, 'failed': 0},
        ],
      })!;
      expect(summary.todayTotal, 5);
      expect(summary.aborted, 0);
      expect(summary.days.single.total, 5);
      expect(summary.sentence, '今天执行 5 次，没有失败');
    });

    test('今天一次都没跑', () {
      final summary = LogSummary.fromDashboard(<String, dynamic>{})!;
      expect(summary.sentence, '今天还没有执行记录');
      expect(summary.days, isEmpty);
    });

    test('形状不对返回 null', () {
      expect(LogSummary.fromDashboard(null), isNull);
      expect(LogSummary.fromDashboard(const ['x']), isNull);
    });
  });
}
