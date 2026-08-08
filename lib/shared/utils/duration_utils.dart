// 耗时（秒）→ 人读得懂的时分秒。纯函数，不依赖 Flutter，可直接单测。
//
// ── 为什么要有这个文件 ────────────────────────────────────────────────────
// 原写法长在 `TaskLog.durationText` 的 getter 里（task_log.dart:46-53），
// 分了 ms / s / m 三档但**没有小时档**：
//
//   4711.9s  ->  78m31s      跑满两小时的任务  ->  120m0s
//
// 「78 分 31 秒」用户还得自己心算除一遍才知道是一个多小时；到了 120m 就更离谱。
// 这条抱怨最早是用户对着面板的定时任务页提的（面板那边显示的是裸秒 `4711.9s`），
// APP 只是好一点，问题是同一个。
//
// 同一份「秒 → 文案」的活儿另外还有两处各写各的裸秒显示：
//   task_list_page.dart:2663          任务详情「最近耗时」   3600.00s
//   subscription_list_page.dart:1798  订阅拉取日志           3600.0s
// 一并收到这里，省得下次改分档又漏掉一处。
//
// ── 本文件是面板 `web/src/utils/duration.ts` 的逐字移植 ────────────────────
// **两端必须一致**：同一条日志在 Web 上写 `1h18m`、在 APP 上写 `78m31s`，
// 用户会以为是两条数据、或者以为哪一端算错了。
// 真源是面板那一份（`formatDuration`），本文件跟着它走；改任何一边都要同步另一边。
//
// 对照关系：
//   TS `Math.floor(x)`            -> Dart `x.floor()`
//   TS `Math.min(a, b)`           -> Dart `math.min(a, b)`
//   TS `Number(x.toFixed(6))`     -> Dart `double.parse(x.toStringAsFixed(6))`
// 面板那个 `fallback` 形参 APP 侧没有调用点需要（三处都用默认的 `-`），故未移植，
// 其余分支逐条对齐。
//
// ── 为什么是「截断」而不是「四舍五入」────────────────────────────────────
// 全档一律向下截断。这不是随手定的：
//   1. 用户要的 `4711.9s -> 1h18m` 本来就只能靠截断（1h18.53m 四舍五入是 1h19m）。
//      既然小时档必须截断，全档统一才自洽。
//   2. 语义上耗时是秒表读数，截断不虚报。
//   3. 截断从结构上锁死了上界（ms ≤ 999、秒位 ≤ 59.9、分位与秒位 ≤ 59），
//      不需要在任何一档写进位兜底。四舍五入则要在 4 个档各写一遍 carry，
//      而且很容易漏掉「进位跨两档」——3599.7s 进位成 60m 之后若回头拿原值算小时，
//      会算出 `0h`。
//
// ── 单位陷阱 ──────────────────────────────────────────────────────────────
// 本文件只处理**秒**。面板的耗时字段并不都是秒：
//   task_logs.duration         秒   server/service/task_executor.go:343
//   tasks.last_running_time    秒   server/service/task_lifecycle.go:98
//   subscription_logs.duration 秒   server/service/subscription.go:93
//   open_app_logs.duration     毫秒 server/middleware/openapi.go:111  ← 不要往这儿套
// `open_api_page.dart` 那两处显示的是毫秒，与本函数无关。

import 'dart:math' as math;

const int _secondsPerMinute = 60;
const int _secondsPerHour = 3600;

/// 把 `[1, 60)` 秒截断到 1 位小数，上限硬钳在 `59.9`。
///
/// 两层保护，缺一不可（照搬面板 `truncateToTenth` 的注释与实现）：
/// 1. 直接 `(v * 10).floor()` 会踩浮点精度 —— 某些值乘 10 后落在
///    `28.999999999999996` 这种比整数略小的位置，截断就凭空少了 0.1。
///    先 `toStringAsFixed(6)` 抹掉 1e-6 以下的噪声再截断。
/// 2. 但 `toStringAsFixed(6)` 本身是四舍五入，对无限逼近 60 的输入
///    （如 `59.9999999999`）又会把它顶成 `600` 从而输出 `60.0s`。
///    所以再用 `math.min(599, ...)` 封死上界。
String _truncateToTenth(double value) {
  final tenths = math.min(
    599,
    double.parse((value * 10).toStringAsFixed(6)).floor(),
  );
  return (tenths / 10).toStringAsFixed(1);
}

/// 秒数 → `1h18m` / `5m12s` / `12.3s` / `856ms` / `0s`。
///
/// 分档（每档只显示两个量级，再细就是噪声）：
///
/// | 区间 | 形态 | 例 |
/// |---|---|---|
/// | `0` | 整零 | `0s` |
/// | `(0, 1)` | 整毫秒 | `856ms` |
/// | `[1, 60)` | 一位小数的秒 | `12.3s` |
/// | `[60, 3600)` | 分 + 整秒，整分时省略秒位 | `5m12s` / `5m` |
/// | `>= 3600` | 时 + 整分，整点时省略分位 | `1h18m` / `6h` |
///
/// 边界行为：
/// - `null` / `NaN` / `±Infinity` / 负数 → `-`。这几种都不是「某个耗时」，
///   与其编一个 `0s` 出来骗人，不如照实说不知道。负数只可能来自时钟回拨等异常
///   （面板算耗时用的是 `now.Sub(startedAt)`），宁可显示 `-` 也不显示 `-500ms`。
/// - `0` 显示 `0s` 而不是 `0ms`：服务端在任务**开始运行**时会把
///   `last_running_time` 重置为 `0.0`（server/service/task_executor.go:207），
///   写 `0ms` 会让人以为真跑了 0 毫秒。
/// - 恰好 `60` → `1m`；恰好 `3600` → `1h`；恰好 `1` → `1.0s`。
/// - `59.95` → `59.9s`（**不会**变成 `60.0s`）；`0.9999` → `999ms`（不会变成
///   `1000ms`）；`3599.999` → `59m59s`（不会变成 `59m60s` 或 `60m`）。
/// - 小于 1 毫秒（如 `0.0004`）→ `0ms`，如实反映而不是伪造成 `1ms`。
String formatDurationSeconds(num? seconds) {
  if (seconds == null) return '-';
  final value = seconds.toDouble();
  // NaN 比不出大小：`nan < 0`、`nan < 60` 全是 false，不显式挡住就会一路掉到
  // 小时档；而 `double.infinity.floor()` 在 Dart 里是直接抛 UnsupportedError，
  // 不是返回一个大数。这两个必须在任何 floor() 之前拦住。
  // 对应面板的 `!Number.isFinite(seconds)`。
  if (value.isNaN || value.isInfinite) return '-';
  if (value < 0) return '-';

  if (value == 0) return '0s';
  // 毫秒位同样钳在 999，保证 (0,1) 区间永远不会输出 "1000ms"。
  if (value < 1) return '${math.min(999, (value * 1000).floor())}ms';
  if (value < _secondsPerMinute) return '${_truncateToTenth(value)}s';

  if (value < _secondsPerHour) {
    final minutes = (value / _secondsPerMinute).floor();
    final restSeconds = (value % _secondsPerMinute).floor();
    return restSeconds == 0 ? '${minutes}m' : '${minutes}m${restSeconds}s';
  }

  final hours = (value / _secondsPerHour).floor();
  final restMinutes = ((value % _secondsPerHour) / _secondsPerMinute).floor();
  return restMinutes == 0 ? '${hours}h' : '${hours}h${restMinutes}m';
}
