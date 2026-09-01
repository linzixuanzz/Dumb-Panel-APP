import 'dart:convert';

/// 任务视图（面板 `task_views` 表 / `server/model/task_view.go`）。
///
/// 它是**规则型分组**：一条视图 = 一组筛选条件 + 一组排序规则，
/// 选中之后把 `filters` / `sort_rules` 原样透传给 `GET /api/tasks`，
/// 由服务端做匹配与排序。**APP 不实现任何匹配算法** —— 面板加一种运算符
/// 就要 APP 跟着发版，那正是契约规范要防的事。
///
/// ⚠️ 这张表**没有 user_id，全局共享**（`task_view.go:7` 注释明说）：
/// 手机上改一条视图，面板上所有人都会看到。UI 文案不能写「我的视图」。
class TaskView {
  final int id;
  final String name;
  final List<TaskViewFilter> filters;
  final List<TaskViewSortRule> sortRules;
  final bool hidden;
  final int sortOrder;

  const TaskView({
    required this.id,
    required this.name,
    this.filters = const [],
    this.sortRules = const [],
    this.hidden = false,
    this.sortOrder = 0,
  });

  factory TaskView.fromJson(Map<String, dynamic> json) {
    return TaskView(
      id: _int(json['id']),
      name: json['name']?.toString() ?? '',
      filters: parseTaskViewFilters(json['filters']),
      sortRules: parseTaskViewSortRules(json['sort_rules']),
      hidden: json['hidden'] == true,
      sortOrder: _int(json['sort_order']),
    );
  }
}

/// 一条筛选规则：`{field, operator, value}`。
class TaskViewFilter {
  /// 可筛字段，取值见 [kTaskViewFilterFields]。
  final String field;

  /// 运算符，取值见 [kTaskViewOperators]。
  ///
  /// 字段名不叫 `operator`：那是 Dart 的内建标识符，写在类成员位置会被
  /// 当成运算符重载声明的开头，直接编译不过。传输层的键名仍然是 `operator`。
  final String op;

  final String value;

  const TaskViewFilter({
    required this.field,
    required this.op,
    required this.value,
  });

  factory TaskViewFilter.fromJson(Map<String, dynamic> json) {
    return TaskViewFilter(
      field: json['field']?.toString() ?? '',
      op: json['operator']?.toString() ?? '',
      value: json['value']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'field': field,
    'operator': op,
    'value': value,
  };

  /// 面板会把 field / operator / value 任一为空的整条规则丢掉
  /// （`task_query.go:353-355`），APP 提交前先滤一遍，免得用户存下一条
  /// 「看起来存住了、实际不生效」的规则。
  bool get isUsable =>
      field.trim().isNotEmpty && op.trim().isNotEmpty && value.trim().isNotEmpty;

  TaskViewFilter copyWith({String? field, String? op, String? value}) {
    return TaskViewFilter(
      field: field ?? this.field,
      op: op ?? this.op,
      value: value ?? this.value,
    );
  }
}

/// 一条排序规则：`{field, direction}`。
class TaskViewSortRule {
  /// 可排序字段，取值见 [kTaskViewSortFields]。
  final String field;

  /// 只有 `asc` / `desc` 两种。面板对非 `desc` 的值一律归一成 `asc`
  /// （`task_query.go:379-381`），这里在解析时就归一，避免两端各归一各的。
  final String direction;

  const TaskViewSortRule({required this.field, this.direction = 'asc'});

  factory TaskViewSortRule.fromJson(Map<String, dynamic> json) {
    return TaskViewSortRule(
      field: json['field']?.toString() ?? '',
      direction: normalizeTaskViewSortDirection(json['direction']),
    );
  }

  Map<String, dynamic> toJson() => {'field': field, 'direction': direction};

  bool get isUsable => field.trim().isNotEmpty;

  bool get isDescending => direction == 'desc';

  TaskViewSortRule copyWith({String? field, String? direction}) {
    return TaskViewSortRule(
      field: field ?? this.field,
      direction: direction ?? this.direction,
    );
  }
}

/// 排序方向归一。非 `desc`（含大小写变体、空串、null）一律 `asc`。
String normalizeTaskViewSortDirection(dynamic raw) {
  return raw?.toString().trim().toLowerCase() == 'desc' ? 'desc' : 'asc';
}

/// 解析 `filters`。
///
/// ⚠️ 传输层这个字段是**字符串化的 JSON**（`filters: "[{...}]"`），不是数组，
/// 所以要解两层。面板建视图时**不校验 JSON 合法性**，读的时候才静默降级
/// （`task_query.go:344-346`），APP 必须同样容错：`''` / `'[]'` / 非法 JSON /
/// 解出来不是数组，一律当空列表，**绝不抛异常** —— 一条脏视图不该让整页红掉。
///
/// 同时兼容「已经是数组」的形态：面板日后若改成直接下发数组，这里不用跟着改。
List<TaskViewFilter> parseTaskViewFilters(dynamic raw) {
  return _decodeRuleList(raw)
      .map((item) => TaskViewFilter.fromJson(item))
      .toList();
}

/// 解析 `sort_rules`。容错策略与 [parseTaskViewFilters] 完全一致。
List<TaskViewSortRule> parseTaskViewSortRules(dynamic raw) {
  return _decodeRuleList(raw)
      .map((item) => TaskViewSortRule.fromJson(item))
      .toList();
}

/// 序列化 `filters` 回字符串。
///
/// 空列表必须是 `'[]'` 而不是 `''`：面板的 UpdateView 把空串当成
/// 「这个字段不改」（`task_view.go:77-85`），传 `''` 会让「清空规则」这个动作
/// 变成静默无效。
String encodeTaskViewFilters(List<TaskViewFilter> filters) {
  return jsonEncode(filters.map((item) => item.toJson()).toList());
}

/// 序列化 `sort_rules` 回字符串。空列表同样是 `'[]'`，理由见 [encodeTaskViewFilters]。
String encodeTaskViewSortRules(List<TaskViewSortRule> rules) {
  return jsonEncode(rules.map((item) => item.toJson()).toList());
}

List<Map<String, dynamic>> _decodeRuleList(dynamic raw) {
  dynamic decoded = raw;
  if (raw is String) {
    final text = raw.trim();
    if (text.isEmpty) {
      return const [];
    }
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      // 面板不校验写入的 JSON，脏数据是可能存在的。
      return const [];
    }
  }
  if (decoded is! List) {
    return const [];
  }
  return decoded
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList();
}

/// 把一条读回来的筛选规则归一成「编辑器能安全播种」的草稿。
///
/// 面板**不校验**写进去的 JSON，库里真的可能存着 `{"field":"labels","value":"娱乐"}`
/// 这种缺 operator 的规则 —— 面板自己只是在查询时跳过它（`task_query.go:353`），
/// 视图看起来完全正常。但空串直接塞进 `DropdownButton.value` 时 items 里没有
/// 对应项，会当场踩它的构造断言（There should be exactly one item with
/// DropdownButton's value）：debug 包一按「编辑」就红屏，release 包渲染成一个
/// 选不动的空框。
///
/// 这里把空的 field / operator 落回各自选项表的第一项：让脏规则**看得见、改得动**，
/// 与模型层「脏数据静默降级、绝不抛」的取向一致。代价是这条规则保存后会真的生效，
/// 但它就摆在用户眼前，比静默丢掉或者直接崩掉都好。
TaskViewFilter normalizeTaskViewFilterDraft(TaskViewFilter filter) {
  final field = filter.field.trim();
  final op = filter.op.trim();
  return TaskViewFilter(
    field: field.isEmpty ? kTaskViewFilterFields.first.value : field,
    op: op.isEmpty ? kTaskViewOperators.first.value : op,
    value: filter.value,
  );
}

/// 编辑器播种排序时用：拆成「进 UI 的第一条」和「原样留着的其余条」。
///
/// 手机上只暴露第一条排序规则（小屏摆一串排序行的收益远低于它吃掉的高度），
/// 但**不能因此把用户在网页上配的第二条排序规则删掉**，理由见
/// [composeTaskViewSortRules]。
({TaskViewSortRule? edited, List<TaskViewSortRule> extras})
splitTaskViewSortRules(List<TaskViewSortRule> rules) {
  final usable = rules.where((rule) => rule.isUsable).toList();
  if (usable.isEmpty) {
    return (edited: null, extras: const <TaskViewSortRule>[]);
  }
  return (edited: usable.first, extras: usable.skip(1).toList());
}

/// 编辑器提交排序时用：把 UI 上编辑的那一条与没进 UI 的其余条拼回完整列表。
///
/// ⚠️ 面板的 UpdateView 收到**非空** sort_rules 是**整体覆盖**
/// （`server/handler/task_view.go:77-85`），而 `task_views` 表没有 user_id、
/// 全站共享 —— 只回传编辑到的那一条，就意味着「在手机上把视图名改一下保存」
/// 会把网页端配的第二条排序规则永久删掉，且所有人都受影响。
List<TaskViewSortRule> composeTaskViewSortRules({
  required String? editedField,
  required String editedDirection,
  required List<TaskViewSortRule> extraRules,
}) {
  final field = editedField?.trim() ?? '';
  return [
    // 空 field 表示「默认顺序」，那一条不提交；但其余条仍然要带回去。
    if (field.isNotEmpty)
      TaskViewSortRule(
        field: field,
        direction: normalizeTaskViewSortDirection(editedDirection),
      ),
    // 拼之前把「与编辑到的那条同字段」的剔掉：原本 [name asc, status desc]，
    // 用户把第一条改成 status，直接拼会拼出 [status asc, status desc] ——
    // 服务端那第二条是恒 0 的 tie-break、行为无害，但网页端会多出一条
    // 自相矛盾的规则，而这是所有人都看得见的共享数据。
    ...extraRules.where((rule) => rule.field.trim() != field),
  ];
}

/// 下拉选项。value 是发给面板的值，label 是 UI 上显示的中文。
class TaskViewOption {
  final String value;
  final String label;

  const TaskViewOption(this.value, this.label);
}

/// 可筛字段。逐条对齐面板 `web/.../ViewManager.vue:63-70`，顺序也照抄。
const List<TaskViewOption> kTaskViewFilterFields = [
  TaskViewOption('command', '命令'),
  TaskViewOption('name', '名称'),
  TaskViewOption('cron_expression', '定时规则'),
  TaskViewOption('status', '状态'),
  TaskViewOption('labels', '标签'),
  TaskViewOption('subscription', '订阅'),
];

/// 运算符。面板遇到不认识的运算符会**静默放行**（恒真），
/// 所以这里绝不能自己发明第五种。
const List<TaskViewOption> kTaskViewOperators = [
  TaskViewOption('contains', '包含'),
  TaskViewOption('not_contains', '不包含'),
  TaskViewOption('equals', '等于'),
  TaskViewOption('not_equals', '不等于'),
];

/// `status` 字段的取值。
///
/// ⚠️ 必须是面板 Web 用的这四个**数值串**（`ViewManager.vue:72-77`）。
/// 面板确实也认「已禁用 / 运行中」这类中文写法，但那是三套等价写法之一，
/// APP 自己造中文串会在面板改文案时静默失效。
const List<TaskViewOption> kTaskViewStatusValues = [
  TaskViewOption('1', '已启用'),
  TaskViewOption('0', '已禁用'),
  TaskViewOption('2', '运行中'),
  TaskViewOption('0.5', '排队中'),
];

/// 可排序字段（`task_query.go:537-563`）。比可筛字段多一个 `created_at`。
const List<TaskViewOption> kTaskViewSortFields = [
  TaskViewOption('name', '名称'),
  TaskViewOption('command', '命令'),
  TaskViewOption('cron_expression', '定时规则'),
  TaskViewOption('status', '状态'),
  TaskViewOption('labels', '标签'),
  TaskViewOption('subscription', '订阅'),
  TaskViewOption('created_at', '创建时间'),
];

/// 取选项的中文名，认不出来时原样返回 —— 面板加了新字段时诚实显示原值，
/// 不冒充成某个已知字段。
String taskViewOptionLabel(List<TaskViewOption> options, String value) {
  for (final option in options) {
    if (option.value == value) {
      return option.label;
    }
  }
  return value;
}

/// 一条筛选规则的人话描述，例如「命令 包含 jd_bean」。
String taskViewFilterSummary(TaskViewFilter filter) {
  final field = taskViewOptionLabel(kTaskViewFilterFields, filter.field);
  final op = taskViewOptionLabel(kTaskViewOperators, filter.op);
  // status 存的是 '1' / '0.5' 这种数值串，直接摊给用户看没人认得。
  final value = filter.field == 'status'
      ? taskViewOptionLabel(kTaskViewStatusValues, filter.value)
      : filter.value;
  return '$field $op $value';
}

/// 整条视图的规则摘要，用于选择面板里的副标题。
String taskViewRuleSummary(TaskView view) {
  final parts = view.filters
      .where((filter) => filter.isUsable)
      .map(taskViewFilterSummary)
      .toList();
  for (final rule in view.sortRules.where((rule) => rule.isUsable)) {
    final field = taskViewOptionLabel(kTaskViewSortFields, rule.field);
    parts.add('按$field${rule.isDescending ? '倒序' : '正序'}');
  }
  // 没有任何规则的视图在面板上是合法的（点了也是全部任务），
  // 这里必须说清楚，否则用户会以为是加载失败。
  return parts.isEmpty ? '没有筛选规则，等同于全部任务' : parts.join(' · ');
}

int _int(dynamic v) => (v is num) ? v.toInt() : 0;
