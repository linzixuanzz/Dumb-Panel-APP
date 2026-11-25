/// 日志页顶部「今天的摘要 + 执行趋势」的数据。
///
/// 数据来源与旧首页的趋势图（features/dashboard/widgets/trend_chart.dart）是同一个接口：
/// `GET /api/system/dashboard` 的 `success_logs / failed_logs / aborted_logs / today_logs /
/// running_tasks / daily_stats`。日志页额外带 `range`（面板 v3.3 起支持 1~90 天），
/// 老面板不认这个参数时照旧回 7 天，图照样能画。
class LogSummary {
  /// 今天执行的总次数（含运行中 / 状态未知的记录，与面板 today_logs 同口径）。
  final int todayTotal;
  final int success;
  final int failed;
  final int aborted;

  /// 正在运行的任务数（dashboard 的 running_tasks）。一个任务同一时间只有一条运行中的日志。
  final int running;

  /// 按天的执行次数，最后一项是今天（面板按它自己的时区切天）。
  final List<LogDayCount> days;

  const LogSummary({
    required this.todayTotal,
    required this.success,
    required this.failed,
    required this.aborted,
    required this.running,
    required this.days,
  });

  /// 解析 dashboard 返回的 data。形状不对返回 null，调用方当作「没有摘要」。
  static LogSummary? fromDashboard(dynamic data) {
    if (data is! Map) {
      return null;
    }
    int read(String key) => (data[key] as num?)?.toInt() ?? 0;
    final days = <LogDayCount>[];
    final raw = data['daily_stats'];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) {
          continue;
        }
        int count(String key) => (item[key] as num?)?.toInt() ?? 0;
        days.add(
          LogDayCount(
            date: item['date']?.toString() ?? '',
            // 老面板没有 aborted 键 → 0，与旧首页趋势图一致。
            total: count('success') + count('failed') + count('aborted'),
          ),
        );
      }
    }
    final success = read('success_logs');
    final failed = read('failed_logs');
    final aborted = read('aborted_logs');
    // today_logs 是面板 v3 才有的；老面板没有时按三档相加兜底。
    final total = data.containsKey('today_logs')
        ? read('today_logs')
        : success + failed + aborted;
    return LogSummary(
      todayTotal: total,
      success: success,
      failed: failed,
      aborted: aborted,
      running: read('running_tasks'),
      days: days,
    );
  }

  /// 大标题下面那一句话。
  String get sentence {
    if (todayTotal <= 0) {
      return '今天还没有执行记录';
    }
    if (failed > 0) {
      return '今天执行 $todayTotal 次，$failed 次失败';
    }
    return '今天执行 $todayTotal 次，没有失败';
  }
}

class LogDayCount {
  /// 面板 daily_stats 的 date，一直是 `MM-DD`。
  final String date;
  final int total;

  const LogDayCount({required this.date, required this.total});

  /// 横轴标签「25日」。认不出形状就原样返回，不猜。
  String get dayLabel {
    final parts = date.split('-');
    final day = int.tryParse(parts.last);
    return day == null ? date : '$day日';
  }
}

/// 今天还没过完，按「已过时长占全天的比例」把今天的次数折算成全天预估。
///
/// 例：现在 15:00（过了 62.5%），今天已跑 100 次 → 预估全天 160 次。
/// 不折算的话，趋势线每天最后一个点都会断崖式往下掉，看起来像出了故障。
///
/// 比例最少按 2 小时算：凌晨刚过几分钟时跑了 1 次，直接除会预估出上百次，
/// 让整张图的纵轴被一个虚高的点撑爆。
///
/// ⚠️ 用的是手机本地时间。面板按它自己的时区切天，两边时区不同时预估会偏，
/// 所以图上这一段画成虚线，只当「大概」看。
double projectTodayTotal(int todayCount, DateTime now) {
  final midnight = DateTime(now.year, now.month, now.day);
  final elapsed = now.difference(midnight).inSeconds / Duration.secondsPerDay;
  final fraction = elapsed.clamp(1 / 12, 1.0);
  return todayCount / fraction;
}

/// 「每日平均」：只算已经过完的那些天；只有今天一天时退回今天的预估值。
double averageDailyTotal(List<LogDayCount> days, double todayProjected) {
  if (days.length <= 1) {
    return todayProjected;
  }
  final full = days.sublist(0, days.length - 1);
  final sum = full.fold<int>(0, (acc, d) => acc + d.total);
  return sum / full.length;
}
