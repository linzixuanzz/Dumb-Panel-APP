import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/app_card.dart';

class TrendChart extends StatelessWidget {
  final List<dynamic> data;

  const TrendChart({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;

    final successSpots = <FlSpot>[];
    final failSpots = <FlSpot>[];

    for (int i = 0; i < data.length; i++) {
      final item = data[i] as Map<String, dynamic>;
      successSpots.add(
        FlSpot(i.toDouble(), (item['success'] as num? ?? 0).toDouble()),
      );
      failSpots.add(
        FlSpot(i.toDouble(), (item['failed'] as num? ?? 0).toDouble()),
      );
    }

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '近7天执行统计',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: isLight ? AppColors.slate700 : AppColors.slate300,
                ),
              ),
              const Spacer(),
              // 与同屏 TaskStatsCard 的「今日成功 / 今日失败」保持同一套语义色。
              _LegendDot(color: AppColors.success, label: '成功', isLight: isLight),
              const SizedBox(width: 12),
              _LegendDot(color: AppColors.danger, label: '失败', isLight: isLight),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 180,
            child: LineChart(
              LineChartData(
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: 5,
                  getDrawingHorizontalLine: (value) => FlLine(
                    color: (isLight ? AppColors.slate200 : AppColors.slate800)
                        .withAlpha(120),
                    strokeWidth: 1,
                  ),
                ),
                titlesData: FlTitlesData(
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 32,
                      getTitlesWidget: (value, meta) => Text(
                        value.toInt().toString(),
                        style: TextStyle(
                          fontSize: 10,
                          color: isLight
                              ? AppColors.slate400
                              : AppColors.slate500,
                        ),
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval: (data.length / 5).ceilToDouble().clamp(
                        1,
                        double.infinity,
                      ),
                      getTitlesWidget: (value, meta) {
                        final idx = value.toInt();
                        if (idx < 0 || idx >= data.length) {
                          return const SizedBox();
                        }
                        final item = data[idx] as Map<String, dynamic>;
                        final date = item['date']?.toString() ?? '';
                        return Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            date.length >= 5 ? date.substring(5) : date,
                            style: TextStyle(
                              fontSize: 10,
                              color: isLight
                                  ? AppColors.slate400
                                  : AppColors.slate500,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                ),
                borderData: FlBorderData(show: false),
                lineBarsData: [
                  _line(successSpots, AppColors.success),
                  _line(failSpots, AppColors.danger),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  LineChartBarData _line(List<FlSpot> spots, Color color) {
    return LineChartBarData(
      spots: spots,
      isCurved: true,
      color: color,
      barWidth: 2,
      dotData: const FlDotData(show: false),
      belowBarData: BarAreaData(show: true, color: color.withAlpha(20)),
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  final bool isLight;

  const _LegendDot({
    required this.color,
    required this.label,
    required this.isLight,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: isLight ? AppColors.slate500 : AppColors.slate400,
          ),
        ),
      ],
    );
  }
}
