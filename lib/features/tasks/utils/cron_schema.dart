// Cron 模板与表达式解析的数据层。纯函数 + 纯数据类，不依赖 Flutter，可直接单测。
//
// ── 为什么接面板接口而不是继续内置 ──────────────────────────────────────
// 面板 `GET /api/tasks/cron/templates`（server/handler/task_cron.go:49-51 →
// pkg/cron/cron.go:312-336）已经有 **21 条**模板，分 7 个 category
// （高频/常用/每天/工作日/周末/每周/每月/秒级）。
// APP 这边硬编码了 **3 条**（每小时 / 每天0点 / 每天9点），而且
// `ApiEndpoints.cronTemplates` 这个常量**声明后全库零调用**。
// 换成调接口之后，面板加模板 APP 自动跟上，不需要发版。
//
// ── 响应形状（本次实读核对）────────────────────────────────────────────
// `pkg/response.Success` 是**裸 `c.JSON(200, data)`**（pkg/response/response.go:9-11），
// 没有 `{"data": ...}` 信封。所以：
//   GET  /api/tasks/cron/templates → `[{"name":..,"expression":..,"description":..,"category":..}, ...]`
//   POST /api/tasks/cron/parse     → `{"is_valid":true,"description":..,"next_run_times":[..],"format":..}`
//                                  或 `{"is_valid":false,"error":".."}`
// 下面两个 parse 函数同时认裸形态和 `{"data": ...}` 信封 —— 面板的响应形态
// 本来就不统一（design.md §4.3），多认一种是零成本的保险。
//
// ── 向后兼容 ────────────────────────────────────────────────────────────
// 拿不到模板（老面板 404 / 断网 / 任何异常）就回落到 [kFallbackCronTemplates]，
// 也就是改动前那 3 条。这是「形状探测」而不是版本号判断：
// 面板版本号由 ldflags 注入，本地构建一律自称 3.0.0，不可信（design.md §4.1）。

/// 一条 cron 模板。字段与面板 `pkg/cron.GetTemplates()` 的 map 键逐条对齐。
class CronTemplate {
  const CronTemplate({
    required this.name,
    required this.expression,
    this.description = '',
    this.category = '',
  });

  final String name;
  final String expression;
  final String description;

  /// 分组名（高频 / 常用 / 每天 / 工作日 / 周末 / 每周 / 每月 / 秒级）。
  /// APP 不认识这些分组名，也不需要认识 —— 直接按面板给的字符串分组显示。
  final String category;

  static CronTemplate? fromJson(Map<String, dynamic> json) {
    final expression = json['expression']?.toString().trim() ?? '';
    if (expression.isEmpty) {
      // 没有表达式的模板点了也没用，直接丢掉而不是渲染成一个空按钮。
      return null;
    }
    final name = json['name']?.toString().trim() ?? '';
    return CronTemplate(
      name: name.isEmpty ? expression : name,
      expression: expression,
      description: json['description']?.toString().trim() ?? '',
      category: json['category']?.toString().trim() ?? '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CronTemplate &&
      other.name == name &&
      other.expression == expression &&
      other.description == description &&
      other.category == category;

  @override
  int get hashCode => Object.hash(name, expression, description, category);
}

/// 面板不可用时的兜底模板 —— 就是改动前 `task_form_page.dart` 里硬编码的那三条。
///
/// 语义已经变了：它**不再是「APP 维护的模板表」**，而是「面板给不出模板时的
/// 最小可用集」。不要再往这里加条目，要加就加到面板 `pkg/cron.GetTemplates()`。
const List<CronTemplate> kFallbackCronTemplates = <CronTemplate>[
  CronTemplate(
    name: '每小时',
    expression: '0 0 * * * *',
    description: '每小时整点执行',
  ),
  CronTemplate(
    name: '每天0点',
    expression: '0 0 0 * * *',
    description: '每天凌晨0点执行',
  ),
  CronTemplate(
    name: '每天9点',
    expression: '0 0 9 * * *',
    description: '每天上午9点执行',
  ),
];

/// 解析 `/tasks/cron/templates` 的响应。任何拿不出模板的形状都返回空列表，
/// 由调用方决定是否回落到 [kFallbackCronTemplates]。
List<CronTemplate> parseCronTemplates(dynamic raw) {
  final list = raw is Map ? raw['data'] : raw;
  if (list is! List) {
    return const <CronTemplate>[];
  }
  final result = <CronTemplate>[];
  for (final item in list) {
    if (item is Map) {
      final template = CronTemplate.fromJson(Map<String, dynamic>.from(item));
      if (template != null) {
        result.add(template);
      }
    }
  }
  return result;
}

/// 一个分组及其模板，保持面板返回的原始顺序。
class CronTemplateGroup {
  const CronTemplateGroup({required this.category, required this.templates});

  final String category;
  final List<CronTemplate> templates;
}

/// 按 category 分组，**不排序**。
///
/// 面板 `GetTemplates()` 返回的是一个手写的有序数组（高频 → 秒级），顺序本身
/// 就是「常用程度」。按字典序重排会把「每10秒」排到「每天0点」前面。
/// 分组内部同理保持原序。category 为空的模板归到一个空名分组，排在最后。
List<CronTemplateGroup> groupCronTemplates(List<CronTemplate> templates) {
  final order = <String>[];
  final buckets = <String, List<CronTemplate>>{};
  for (final template in templates) {
    final category = template.category;
    if (!buckets.containsKey(category)) {
      buckets[category] = <CronTemplate>[];
      order.add(category);
    }
    buckets[category]!.add(template);
  }
  order.sort((a, b) {
    if (a.isEmpty == b.isEmpty) return 0;
    return a.isEmpty ? 1 : -1;
  });
  return [
    for (final category in order)
      CronTemplateGroup(category: category, templates: buckets[category]!),
  ];
}

/// 把多行 cron 输入拆成一条条表达式。
///
/// 逐字对齐面板 `pkg/cron.SplitExpressions`（cron.go:20-32）：按 `\n` / `\r`
/// 切分、去首尾空白、丢空行。**必须一致** —— 面板的 `Parse()` 只接受**单条**
/// 表达式，APP 把整个多行文本发过去必然 400，而任务表单的 cron 框是多行的
/// （`maxLines: null`，模板按钮也是追加新行）。
List<String> splitCronExpressions(String raw) {
  return raw
      .split(RegExp(r'[\r\n]+'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
}

/// `/tasks/cron/parse` 的结果。
class CronParseResult {
  const CronParseResult({
    required this.isValid,
    this.description = '',
    this.error = '',
    this.format = '',
    this.nextRunTimes = const <DateTime>[],
  });

  final bool isValid;

  /// 面板生成的人话描述，如「每天 09:00 执行」。
  final String description;

  /// 表达式非法时的原因，直接来自 robfig/cron 的报错。
  final String error;

  /// 「标准格式 (5位)」/「扩展格式 (6位含秒)」。
  final String format;

  /// 未来 5 次执行时间。面板发的是 RFC3339 字符串。
  final List<DateTime> nextRunTimes;

  DateTime? get nextRunTime =>
      nextRunTimes.isEmpty ? null : nextRunTimes.first;

  static CronParseResult? fromJson(dynamic raw) {
    final map = raw is Map && raw['data'] is Map ? raw['data'] : raw;
    if (map is! Map) {
      return null;
    }
    final json = Map<String, dynamic>.from(map);
    // 没有 is_valid 字段说明这压根不是 cron/parse 的响应（老面板 404 页面、
    // 反代插的错误页等）。宁可当作「没有结论」也不要显示一个假的「表达式无效」。
    if (json['is_valid'] is! bool) {
      return null;
    }
    final times = <DateTime>[];
    final rawTimes = json['next_run_times'];
    if (rawTimes is List) {
      for (final item in rawTimes) {
        final parsed = DateTime.tryParse(item?.toString() ?? '');
        if (parsed != null) {
          times.add(parsed);
        }
      }
    }
    return CronParseResult(
      isValid: json['is_valid'] as bool,
      description: json['description']?.toString().trim() ?? '',
      error: json['error']?.toString().trim() ?? '',
      format: json['format']?.toString().trim() ?? '',
      nextRunTimes: times,
    );
  }
}
