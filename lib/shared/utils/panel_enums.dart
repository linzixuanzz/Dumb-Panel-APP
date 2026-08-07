// 面板枚举值 → 中文标签 / 语义色调。纯函数，不依赖 Flutter，可直接单测。
//
// ── 为什么要有这个文件 ────────────────────────────────────────────────────
// 这些换算原来散在 6 个页面和 3 个 model 里，同一份枚举最多有三份副本
// （任务类型在 task_list_page 里就有两份，依赖类型在 model 与列表页各一份）。
// 副本多不是最要命的，最要命的是**它们的兜底分支写法不一致，而且大多在说谎**：
//
//   dependency.dart:46       default → '已安装'    面板加一种依赖状态就谎报成「已安装」
//   dep_list_page.dart:404   default → 'NodeJS'    面板加一种依赖类型就谎报成 NodeJS
//   task_list_page.dart:1680 default → '常规定时'  面板加一种任务类型就谎报成定时
//   task_list_page.dart:2649 else    → '失败'      面板的 last_run_status=2 是「已终止」，
//                                                  这一条**现在就在说谎**，不是将来才会
//
// 方案（design.md §6.b）已经明确砍掉 `/api/system/enums` 字典端点：8 张枚举表
// 加起来才 ~40 个值、变更频率极低（日志状态从 3 个变成 4 个用了三个大版本），
// 为它建一个端点 + 一套缓存 + 一套降级，ROI 是负的。
// **但兜底分支必须改。** 面板加一个新枚举值时，用户应该看到一个诚实的未知标签，
// 而不是一个错误的已知标签 —— 空白只是没信息，错误标签会诱导错误操作
// （把「已终止」当成「失败」，去排查一个根本不存在的故障）。
//
// 所以本文件只有一条原则：
//   **认识的值给中文名；不认识的值原样吐回去，绝不落到某个已知值上。**
//
// ── 真源锚点（本次实读核对，面板仓库只读）────────────────────────────────
//   server/model/task.go:11-19       TaskStatus* / TaskType* / Run*
//   server/model/task_log.go:7-12    LogStatus*（**含 3 = Aborted**）
//   server/model/dependency.go:38-48 DepType* / DepStatus*
//
// ⚠️ 注意 `TaskStatusQueued = 0.5` 是浮点数，任务状态必须按 double 比较。
// ⚠️ 注意 `last_run_status` 走的是 Run*（0 成功 / 1 失败 / **2 已终止**），
//    与 `task_logs.status` 的 LogStatus*（2 是**运行中**、3 才是已终止）**不是同一套枚举**。
//    两者都叫 status、都是小整数、2 的含义正好相反，是这一块最容易写错的地方。

/// 状态的语义色调。页面只把它映射成具体颜色，不再各自判断状态字符串。
///
/// 没有单独的 `unknown`：未知状态在视觉上就该是中性的，和「已取消 / 已禁用」
/// 同一档。要区分「已知的中性态」和「不认识」，看标签文本即可（标签会带原始值）。
enum PanelStatusTone {
  /// 成功 / 已安装 / 已启用。
  success,

  /// 失败。
  danger,

  /// 运行中 / 安装中 / 排队中等进行态。
  running,

  /// 主动终止 / 需要注意但不是失败。
  warning,

  /// 已禁用 / 已取消 / 不认识的值。
  neutral,
}

// ── 任务状态（server/model/task.go:12-15）────────────────────────────────

const double kTaskStatusDisabled = 0;
const double kTaskStatusQueued = 0.5;
const double kTaskStatusEnabled = 1;
const double kTaskStatusRunning = 2;

/// 任务状态 → 标签。
///
/// 面板只有 0 / 0.5 / 1 / 2 四个值。第五个值出现时返回 `未知状态(x)` 而不是
/// 「已禁用」—— 原写法是 `if(...) ... return '已禁用';`，把任何没命中的值都
/// 说成已禁用，用户会以为任务被关了。
String taskStatusLabel(double status) {
  if (status == kTaskStatusRunning) return '运行中';
  if (status == kTaskStatusQueued) return '排队中';
  if (status == kTaskStatusEnabled) return '已启用';
  if (status == kTaskStatusDisabled) return '已禁用';
  return '未知状态(${formatEnumNumber(status)})';
}

/// 任务状态是否是本版 APP 认识的值。UI 需要「按状态上色 / 判断可否操作」时用它
/// 先挡一道：不认识的状态一律按中性处理，不要沿用某个已知分支的颜色和按钮。
bool isKnownTaskStatus(double status) =>
    status == kTaskStatusDisabled ||
    status == kTaskStatusQueued ||
    status == kTaskStatusEnabled ||
    status == kTaskStatusRunning;

// ── 任务类型（server/model/task.go:17-19）────────────────────────────────

/// 任务类型 → 标签。
///
/// 空串按「常规定时」处理是**正确**的兜底，不是猜：面板
/// `NormalizeTaskType("")` 明确返回 `TaskTypeCron`（server/model/task.go:176-187），
/// 且 APP 的 `Task.fromJson` 在字段缺失时也补 `'cron'`。
/// 但**非空且不认识**的值必须原样显示 —— 那是面板新增的类型，谎报成「常规定时」
/// 会让用户以为它按 cron 跑，从而去改一个根本不生效的 cron 表达式。
String taskTypeLabel(String raw) {
  switch (raw.trim().toLowerCase()) {
    case '':
    case 'cron':
      return '常规定时';
    case 'manual':
      return '手动运行';
    case 'startup':
      return '开机运行';
    default:
      return raw.trim();
  }
}

// ── 上次运行结果（server/model/task.go:21-23 的 Run*）────────────────────

/// `task.last_run_status` → 标签。
///
/// **这里 2 是「已终止」不是「运行中」。** 面板 `RunAborted = 2`
/// （server/model/task.go:23），Web 端 `TaskDetail.vue:111` 显示的也是「已终止」。
/// 改动前 APP 写的是 `status == 0 ? '成功' : '失败'`，把主动停止的任务显示成
/// 「失败」，是当前版本就存在的错误显示，不是将来才会踩的坑。
String taskRunResultLabel(int? status) {
  switch (status) {
    case null:
      return '未运行';
    case 0:
      return '成功';
    case 1:
      return '失败';
    case 2:
      return '已终止';
    default:
      return '未知结果($status)';
  }
}

PanelStatusTone taskRunResultTone(int? status) {
  switch (status) {
    case 0:
      return PanelStatusTone.success;
    case 1:
      return PanelStatusTone.danger;
    case 2:
      return PanelStatusTone.warning;
    default:
      return PanelStatusTone.neutral;
  }
}

// ── 日志状态（server/model/task_log.go:7-12）─────────────────────────────

const int kLogStatusSuccess = 0;
const int kLogStatusFailed = 1;
const int kLogStatusRunning = 2;

/// 主动终止。面板 v3 新增（`LogStatusAborted = 3`），APP 之前完全没有这个值：
/// 列表页少一个筛选项，状态点落到「运行中」的蓝色上，详情页显示「未知」。
const int kLogStatusAborted = 3;

/// 日志状态 → 标签。与面板 Web `views/logs/index.vue:244-250` 逐条对齐。
String logStatusLabel(int? status) {
  switch (status) {
    case null:
      return '未知';
    case kLogStatusSuccess:
      return '成功';
    case kLogStatusFailed:
      return '失败';
    case kLogStatusRunning:
      return '运行中';
    case kLogStatusAborted:
      return '已终止';
    default:
      return '未知状态($status)';
  }
}

PanelStatusTone logStatusTone(int? status) {
  switch (status) {
    case kLogStatusSuccess:
      return PanelStatusTone.success;
    case kLogStatusFailed:
      return PanelStatusTone.danger;
    case kLogStatusRunning:
      return PanelStatusTone.running;
    case kLogStatusAborted:
      return PanelStatusTone.warning;
    default:
      // null（面板没给 status）与未知值都走中性，而不是继续沿用「运行中」的蓝。
      // 原写法是 `if 成功 绿; if 失败 红; return 蓝`，已终止的日志会亮成蓝色，
      // 与真正还在跑的日志肉眼无法区分。
      return PanelStatusTone.neutral;
  }
}

// ── 依赖类型 / 状态（server/model/dependency.go:38-48）───────────────────

/// 依赖类型 → 标签。
///
/// 面板只有 nodejs / python / linux 三种，且 `Dependency.Type` 是 `not null`。
/// 空串在这里**不**按 NodeJS 处理：面板没有「空即 nodejs」的归一化逻辑
/// （与任务类型不同），猜一个出来只会掩盖数据异常。
String dependencyTypeLabel(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'nodejs':
      return 'NodeJS';
    case 'python':
      return 'Python';
    case 'linux':
      return 'Linux';
    case '':
      return '未知';
    default:
      return raw.trim();
  }
}

/// 依赖状态 → 标签。
///
/// `installed` 原来是靠 `default:` 兜出来的，于是「面板新增的状态」和
/// 「真的装好了」共用一个分支，用户看到「已安装」却怎么也用不了。
/// 现在 installed 显式列出，兜底改成原样回吐。
String dependencyStatusLabel(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'queued':
      return '排队中';
    case 'installing':
      return '安装中';
    case 'removing':
      return '卸载中';
    case 'installed':
      return '已安装';
    case 'failed':
      return '失败';
    case 'cancelled':
      return '已取消';
    case '':
      return '未知';
    default:
      return raw.trim();
  }
}

PanelStatusTone dependencyStatusTone(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'queued':
    case 'installing':
    case 'removing':
      return PanelStatusTone.running;
    case 'installed':
      return PanelStatusTone.success;
    case 'failed':
      return PanelStatusTone.danger;
    default:
      // cancelled、空串、以及面板将来新增的状态都走中性。
      // 原写法最后一个分支是绿色（= 已安装），未知状态会亮成绿的。
      return PanelStatusTone.neutral;
  }
}

// ── 工具 ─────────────────────────────────────────────────────────────────

/// 把枚举数值渲染进「未知」文案里：3.0 显示成 `3`，0.5 保持 `0.5`。
///
/// 直接 `toString()` 会把整数状态写成 `3.0`，看起来像是版本号或耗时，
/// 而这串东西是要给用户截图发给支持的，得能一眼对上面板里的数字。
String formatEnumNumber(num value) {
  if (value is int) {
    return value.toString();
  }
  final asDouble = value.toDouble();
  if (asDouble == asDouble.roundToDouble() && asDouble.abs() < 1e15) {
    return asDouble.toInt().toString();
  }
  return asDouble.toString();
}
