import 'package:flutter/material.dart';

import '../../../core/theme/design_tokens.dart';
import '../../../shared/models/insights.dart';

/// 任务详情里的月历（方案书 §3「任务详情」、PRD 验收第 5 条）：当月每天一个圆点。
///
/// 数据口径（全部来自 health 的 `days`，不另发请求）：
/// - 当天 `failed > 0` → **红**（实色底 + 白字）：当天至少失败过一次（超时也算失败）；
/// - 当天 `total > 0` 且没有失败 → **绿**（淡绿底 + 绿字）：已结束的执行全部没失败。
///   注意「已终止」计入 total、不计入 failed，所以只被手动停过的一天也是绿；
/// - 当天在数据窗口里但 `total == 0` → **灰**：这天没运行；
/// - 今天以后、或早于数据窗口的日子 → 只有浅色数字，不画底。
///
/// 「今天」取 `days` 的最后一行（面板时区的今天），不用手机时间：手机和面板不在一个时区时，
/// 用手机的今天会差出一格。`days` 为空时才回落到手机日期。
///
/// 可以往前翻到数据窗口最早那天所在的月（默认 91 天，至少能翻到上个月），往后翻到今天所在的月。
class TaskHealthCalendar extends StatefulWidget {
  final List<HealthDay> days;

  const TaskHealthCalendar({super.key, required this.days});

  @override
  State<TaskHealthCalendar> createState() => _TaskHealthCalendarState();
}

class _TaskHealthCalendarState extends State<TaskHealthCalendar> {
  /// 往前翻了几个月，0 = 今天所在的月。
  int _monthsBack = 0;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    // 日期 → 当天数据；解析不出日期的行直接忽略
    final byDate = <String, HealthDay>{};
    DateTime? first;
    DateTime? last;
    for (final day in widget.days) {
      final date = day.day;
      if (date == null) continue;
      final key = _dateKey(date);
      byDate[key] = day;
      if (first == null || date.isBefore(first)) first = date;
      if (last == null || date.isAfter(last)) last = date;
    }
    final now = DateTime.now();
    final today = last ?? DateTime(now.year, now.month, now.day);
    final earliest = first ?? today;
    // 最多能往前翻几个月：数据窗口最早那天所在的月
    final maxBack =
        (today.year - earliest.year) * 12 + today.month - earliest.month;
    final monthsBack = _monthsBack.clamp(0, maxBack);
    final month = DateTime(today.year, today.month - monthsBack);
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    // 周日排第一列（与效果演示一致）：DateTime.weekday 周一 = 1 … 周日 = 7
    final leadingBlanks = DateTime(month.year, month.month, 1).weekday % 7;
    final title = month.year == today.year
        ? '${month.month}月 · 每天一格'
        : '${month.year}年${month.month}月 · 每天一格';

    Widget arrow(IconData icon, String tooltip, VoidCallback? onTap) {
      return Semantics(
        button: true,
        enabled: onTap != null,
        label: tooltip,
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox(
            width: AppTapTarget.min,
            height: AppTapTarget.min,
            child: Icon(
              icon,
              size: 22,
              color: onTap == null ? palette.text3 : palette.text,
            ),
          ),
        ),
      );
    }

    final cells = <Widget>[
      for (final weekday in const ['日', '一', '二', '三', '四', '五', '六'])
        Center(
          child: Text(
            weekday,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: palette.text2,
            ),
          ),
        ),
      for (var i = 0; i < leadingBlanks; i++) const SizedBox.shrink(),
    ];
    for (var d = 1; d <= daysInMonth; d++) {
      final date = DateTime(month.year, month.month, d);
      final key = _dateKey(date);
      final data = byDate[key];
      final isToday = _dateKey(today) == key;

      // 四种格子：失败 / 全成功 / 没运行 / 窗口外（含未来）
      final String kind;
      final Color? fill;
      final Color textColor;
      if (data == null || date.isAfter(today)) {
        kind = 'none';
        fill = null;
        textColor = palette.text3;
      } else if (data.failed > 0) {
        kind = 'fail';
        fill = palette.err;
        textColor = palette.onStatus;
      } else if (data.total > 0) {
        kind = 'ok';
        fill = palette.tint(palette.ok);
        textColor = palette.okInk;
      } else {
        kind = 'idle';
        fill = palette.fill;
        textColor = palette.text2;
      }
      final label = switch (kind) {
        'fail' => '$d日，运行 ${data!.total} 次，失败 ${data.failed} 次',
        'ok' => '$d日，运行 ${data!.total} 次，全部成功',
        'idle' => '$d日，没运行',
        _ => '$d日',
      };

      cells.add(
        Semantics(
          label: isToday ? '今天，$label' : label,
          excludeSemantics: true,
          child: Container(
            key: ValueKey('health-day-$key-$kind'),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: fill,
              shape: BoxShape.circle,
              // 今天：外面一圈强调色描边
              border: isToday
                  ? Border.all(color: palette.accent, width: 2)
                  : null,
            ),
            child: Text(
              '$d',
              style: AppText.tabular(
                TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: textColor,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 10, 10, 18),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        key: const Key('health-calendar-title'),
                        style: AppText.cardTitle.copyWith(
                          fontSize: 19,
                          color: palette.text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '绿色全部成功，红色当天有失败，灰色没运行',
                        style: AppText.caption.copyWith(color: palette.text2),
                      ),
                    ],
                  ),
                ),
              ),
              arrow(
                Icons.chevron_left_rounded,
                '上个月',
                monthsBack < maxBack
                    ? () => setState(() => _monthsBack = monthsBack + 1)
                    : null,
              ),
              arrow(
                Icons.chevron_right_rounded,
                '下个月',
                monthsBack > 0
                    ? () => setState(() => _monthsBack = monthsBack - 1)
                    : null,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GridView.count(
              crossAxisCount: 7,
              mainAxisSpacing: 7,
              crossAxisSpacing: 7,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              children: cells,
            ),
          ),
        ],
      ),
    );
  }
}

String _dateKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';
