import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/design_tokens.dart';

/// 概览「每日执行」柱状图：每天一根堆叠柱（成功 / 失败 / 已终止），细网格。
///
/// [days] 是面板 `daily_stats`，旧 → 新，**最后一项是今天**。
/// 今天还没过完，柱子天然偏矮；为了不被读成「今天断崖式下跌」，
/// 今天那根画成浅色（同色 45% 透明度），横轴写「今天」，图下再用一句话说明。
class ExecutionBarChart extends StatelessWidget {
  final List<Map<String, dynamic>> days;

  const ExecutionBarChart({super.key, required this.days});

  static int _count(Map<String, dynamic> day, String key) =>
      (day[key] as num?)?.toInt() ?? 0;

  /// 横轴标签：面板 `date` 一直是 5 位的 `MM-DD`（server/handler/system.go 的 Format("01-02")），
  /// 原样显示；10 位的 `YYYY-MM-DD` 只取月日；其它形状原样显示，不猜。
  static String dateLabel(Map<String, dynamic> day) {
    final date = day['date']?.toString() ?? '';
    return date.length == 10 ? date.substring(5) : date;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final n = days.length;

    var maxTotal = 0;
    var hasAborted = false;
    for (final day in days) {
      final aborted = _count(day, 'aborted');
      if (aborted > 0) hasAborted = true;
      maxTotal = math.max(
        maxTotal,
        _count(day, 'success') + _count(day, 'failed') + aborted,
      );
    }

    // 纵轴刻度：4 格，每格取 1 / 2 / 5 × 10^k 里刚好够用的那个，保证刻度都是整数
    final raw = maxTotal / 4;
    var interval = 1.0;
    if (raw > 1) {
      final magnitude = math.pow(10, (math.log(raw) / math.ln10).floor());
      for (final m in const [1, 2, 5, 10]) {
        if (m * magnitude >= raw) {
          interval = (m * magnitude).toDouble();
          break;
        }
      }
    }
    final maxY = interval * 4;

    // 横轴最多标 6~7 个日期，从今天往回数，保证「今天」一定有标签
    final labelStep = n <= 7 ? 1 : (n / 6).ceil();

    final labelStyle = TextStyle(fontSize: 11, color: palette.text2);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 150,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 柱宽跟着天数走：7 天粗一些，30 天细一些，柱间留出约 40% 空隙
              const leftReserved = 30.0;
              final slot = (constraints.maxWidth - leftReserved) / math.max(n, 1);
              final barWidth = (slot * 0.6).clamp(3.0, 18.0);

              return BarChart(
                BarChartData(
                  maxY: maxY,
                  minY: 0,
                  alignment: BarChartAlignment.spaceAround,
                  borderData: FlBorderData(show: false),
                  // 细网格：只画横线，发丝线粗细
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    horizontalInterval: interval,
                    getDrawingHorizontalLine: (_) =>
                        FlLine(color: palette.separator, strokeWidth: 0.5),
                  ),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: leftReserved,
                        interval: interval,
                        getTitlesWidget: (value, meta) => Text(
                          value.toInt().toString(),
                          style: AppText.tabular(
                            labelStyle.copyWith(fontSize: 10),
                          ),
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 24,
                        getTitlesWidget: (value, meta) {
                          final idx = value.toInt();
                          if (idx < 0 || idx >= n) return const SizedBox();
                          if ((n - 1 - idx) % labelStep != 0) {
                            return const SizedBox();
                          }
                          return Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              idx == n - 1 ? '今天' : dateLabel(days[idx]),
                              style: labelStyle,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  barTouchData: BarTouchData(
                    touchTooltipData: BarTouchTooltipData(
                      getTooltipColor: (_) => palette.primaryBtnBg,
                      tooltipRoundedRadius: AppRadius.md,
                      fitInsideHorizontally: true,
                      fitInsideVertically: true,
                      maxContentWidth: 160,
                      getTooltipItem: (group, groupIndex, rod, rodIndex) {
                        final day = days[group.x];
                        final aborted = _count(day, 'aborted');
                        final lines = [
                          group.x == n - 1 ? '今天（截至现在）' : dateLabel(day),
                          '成功 ${_count(day, 'success')} · 失败 ${_count(day, 'failed')}',
                          if (aborted > 0) '终止 $aborted',
                        ];
                        return BarTooltipItem(
                          lines.join('\n'),
                          TextStyle(
                            color: palette.primaryBtnFg,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        );
                      },
                    ),
                  ),
                  barGroups: [
                    for (var i = 0; i < n; i++)
                      _group(i, days[i], barWidth, palette, isToday: i == n - 1),
                  ],
                ),
                duration: AppMotion.of(context, AppMotion.normal),
              );
            },
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.lg,
          runSpacing: AppSpacing.xs,
          children: [
            _LegendDot(color: palette.ok, label: '成功'),
            _LegendDot(color: palette.err, label: '失败'),
            // 老面板没有 aborted，整段区间又全是 0 时不占图例位置
            if (hasAborted) _LegendDot(color: palette.warn, label: '终止'),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          '今天还没过完，浅色柱是截至现在的次数。轻点柱子看当天明细。',
          style: AppText.caption.copyWith(color: palette.text2),
        ),
      ],
    );
  }

  BarChartGroupData _group(
    int x,
    Map<String, dynamic> day,
    double width,
    AppPalette palette, {
    required bool isToday,
  }) {
    final s = _count(day, 'success').toDouble();
    final f = _count(day, 'failed').toDouble();
    final a = _count(day, 'aborted').toDouble();
    // 今天的柱子用同色浅版，表示「还在累计」
    Color c(Color color) => isToday ? color.withValues(alpha: 0.45) : color;
    return BarChartGroupData(
      x: x,
      barRods: [
        BarChartRodData(
          toY: s + f + a,
          width: width,
          color: c(palette.ok),
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(math.min(width / 2, 5)),
          ),
          rodStackItems: [
            BarChartRodStackItem(0, s, c(palette.ok)),
            BarChartRodStackItem(s, s + f, c(palette.err)),
            if (a > 0) BarChartRodStackItem(s + f, s + f + a, c(palette.warn)),
          ],
        ),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: AppText.caption.copyWith(color: context.palette.text2),
        ),
      ],
    );
  }
}
