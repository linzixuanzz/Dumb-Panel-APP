# agent-0

## summary

issue #4 的两句抱怨其实是两件事，结论相反。**第一句「网页建的分组，手机不会显示」在当前代码上不成立**：APP 和 Web 用的是**完全同一套**分组约定 —— 任务 `labels` 数组里带 `分组:` 前缀的那一项（APP `task.dart:4`，Web `taskLabels.ts:3`），分组数据存在服务端 task 记录里，天然同步；APP 任务页已有完整的分组头、折叠、筛选、重命名/删除/新建分组。**第二句「没办法通过命令、订阅含关键字等规则进行分组」才是真缺口**：面板另有一套 APP 完全没实现的「任务视图」功能 —— 服务端 `task_views` 表 + `/api/tasks/views` 五个端点 + `GET /api/tasks?filters=&sort_rules=` 规则筛选（字段 command/name/cron_expression/status/labels/subscription × 操作符 contains/not_contains/equals/not_equals）。`api_endpoints.dart` 里一条 views 端点都没有，`task_provider.load()` 也从不发 `filters`/`sort_rules`。APP 本地只持久化折叠态/选中分组/分组顺序/滚动位置四个 SharedPreferences key，分组顺序是**纯本地**的、不会同步。另外顺带发现一个与 labels 往返有关的**数据丢失 bug**：APP 任务编辑页保存时会把 `subscription:<id>` 内部标签替换成订阅显示名，把订阅托管任务踢出订阅管理。

## currentState

## 1. APP 的分组是「标签前缀」实现，且与 Web 同源

`Task.groupLabelPrefix = '分组:'`（`task.dart:4`），`groupName` getter 遍历 `labelList` 找第一条 `分组:` 开头的标签并去前缀（`task.dart:108-119`）。Web 侧 `TASK_GROUP_LABEL_PREFIX = '分组:'` + `getTaskGroupName()`（`taskLabels.ts:3,32-41`）是逐字相同的逻辑。

分组值随 task 的 `labels` 字段走服务端 `GET /api/tasks`，**不存在本地分组表**。所以「网页建分组 → 手机看不到」这条，除非用户装的是老版本 APP，否则在 v1.3.3 代码上应该是能同步的（见 openQuestions 第 1 条）。

APP 任务页的分组能力已经相当完整：
- 分桶 + 排序 + 摊平成 ListView 行：`task_list_rows.dart:38-127`
- 可折叠分组头（含 N 条 / 运行中徽章 / 溢出菜单）：`task_list_page.dart:1442-1519`
- 分组选择底部面板（全部分组 / 已有分组 / 新建分组）：`task_list_page.dart:612-673`
- 重命名 / 删除 / 添加任务 / 新建分组：`task_list_page.dart:1029-1285`
- 分组顺序拖拽：`task_list_page.dart:1287-1345`
- 表单里的「任务分组」自动补全输入框：`task_form_page.dart:1169-1178`

写回服务端走 `batchUpdateGroupLabel`（`task_provider.dart:243-257`）：逐个任务剔掉旧的 `分组:` 标签、加上新的，再 `PUT /api/tasks/:id` 只发 `{labels: [...]}`（`task_provider.dart:236-241`）。

## 2. 真正缺失的是「任务视图（TaskView）」

面板独有，APP 零实现：

- 模型：`server/model/task_view.go:5-17` —— `task_views` 表，字段 `name`（全局唯一）/`filters`(JSON)/`sort_rules`(JSON)/`hidden`/`sort_order`。
- 路由：`server/handler/task_routes.go:56-60` —— `GET/POST /api/tasks/views`、`PUT /api/tasks/views/reorder`、`PUT/DELETE /api/tasks/views/:viewId`。
- 消费方式：Web 选中视图后把该视图的 `filters` / `sort_rules` 作为 **query 参数**塞进任务列表请求（`web/src/views/tasks/index.vue:234-241`），服务端 `task_query.go:42-43,112-113` 解析并做内存过滤 + 排序。

这正对应用户原话「通过命令、订阅含关键字等规则进行分组」。

## 3. APP 的本地持久化（全部 SharedPreferences，前缀 `ui_state_`）

`SecureStorage.saveUiState/getUiState` 写的是 `'ui_state_' + key`（`secure_storage.dart:81,303-326`）。任务页四个 key（`task_list_page.dart:60-63`）：

| key（实际存储名） | 值结构 | 写入点 |
|---|---|---|
| `ui_state_tasks.collapsed_groups` | 分组 key 用 `\n` 拼接的字符串，未分组是空串 | `task_list_page.dart:486-491` |
| `ui_state_tasks.selected_group` | 单个分组名字符串，空串=全部 | `task_list_page.dart:672,881` |
| `ui_state_tasks.group_order` | 分组 key 用 `\n` 拼接 | `task_list_page.dart:493-498` |
| `ui_state_tasks.scroll_offset` | `offset.toStringAsFixed(2)` | `task_list_page.dart:140-159` |

脚本页另有 `ui_state_scripts.favorite_paths`（StringList，`script_list_page.dart:461,469,509`）。

**注意：`group_order`（分组顺序）是纯本地的，面板上没有对应概念，天然不会同步。**

## keyFiles

- `D:\GitHub\Dumb Panel\android-app\lib\shared\models\task.dart` :4, 95-130 — 分组约定的唯一来源：groupLabelPrefix='分组:'、labelList、groupName、userLabelsForDisplay。没有 group_id/category/labels 之外的分组字段
- `D:\GitHub\Dumb Panel\android-app\lib\features\tasks\views\task_list_page.dart` :60-63, 446-498, 593-673, 851-887, 1029-1345, 1442-1519, 3118-3162 — 任务页分组 UI 全部：4 个 SharedPreferences key、分组选择面板、筛选行、分组增删改、分组头、溢出菜单
- `D:\GitHub\Dumb Panel\android-app\lib\features\tasks\utils\task_list_rows.dart` :38-127 — 纯函数数据层：groupTasksByGroupName / sortTaskGroupsByOrder / buildTaskListRows。已有单测 test/features/tasks/task_list_rows_test.dart
- `D:\GitHub\Dumb Panel\android-app\lib\features\tasks\providers\task_provider.dart` :11-53, 70-115, 236-257 — TaskListState 只有 keyword/statusFilter/labelFilter 三个筛选维度；load() 只发 all/keyword/status/label，不发 filters/sort_rules。batchUpdateGroupLabel 是分组写回入口
- `D:\GitHub\Dumb Panel\android-app\lib\core\network\api_endpoints.dart` :39-64, 124 — 任务端点清单，共 23 条，无任何 group/view 端点。对比：环境变量有 envsGroups(:124) 和 envsBatchGroup(:122)
- `D:\GitHub\Dumb Panel\android-app\lib\core\storage\secure_storage.dart` :81, 303-326 — UI 状态持久化 API，命名空间前缀 ui_state_，底层 SharedPreferences（非 secure storage）
- `D:\GitHub\Dumb Panel\android-app\lib\features\tasks\views\task_form_page.dart` :152, 160-162, 238-248, 515-543, 1169-1178 — 任务分组输入框 + labels 提交。第 160-162 行用 userLabelsForDisplay 播种 _labels，是 subscription 标签丢失的根因
- `D:\GitHub\呆呆面板开发\web\src\views\tasks\taskLabels.ts` :3, 32-46, 176-181 — 证明 Web 用同一套 '分组:' 前缀；mergeTaskLabels 显式保留 internalLabels —— APP 没做这一步
- `D:\GitHub\呆呆面板开发\server\model\task_view.go` :5-21 — TaskView 模型（name/filters/sort_rules/hidden/sort_order），APP 完全没有对应物
- `D:\GitHub\呆呆面板开发\server\handler\task_routes.go` :56-60 — 任务视图五条路由的权威定义：GET/POST /tasks/views、PUT /tasks/views/reorder、PUT/DELETE /tasks/views/:viewId
- `D:\GitHub\呆呆面板开发\server\handler\task_query.go` :38-132, 337-359, 411-489, 517-535 — filters/sort_rules 的完整契约：可筛字段、四个操作符、与 all=1 的交互、空 sort_rules 回落默认排序
- `D:\GitHub\呆呆面板开发\web\src\views\tasks\components\ViewManager.vue` :64-88, 93 — 字段/状态/操作符/方向四张下拉枚举表，APP 建视图 UI 可逐条照抄
- `D:\GitHub\Dumb Panel\android-app\lib\features\envs\views\env_list_page.dart` :1087-1110 — APP 内已有的「服务端分组 + 多选筛选」先例（PopupMenuButton + CheckedPopupMenuItem），任务视图筛选可复用这个形态

## detailedFindings

## 问题 1：任务页有没有分组？数据来自哪里？

**有，而且是服务端来源。**

分组不是独立字段，而是 `labels` 数组里的一项约定：

```dart
// lib/shared/models/task.dart:4
static const String groupLabelPrefix = '分组:';

// :102-119
static bool isGroupLabel(String label) => label.trim().startsWith(groupLabelPrefix);
static String toGroupLabel(String group) => '$groupLabelPrefix${group.trim()}';
String? get groupName { /* 遍历 labelList，返回第一条去掉前缀的 */ }
```

`labels` 来自 `Task.fromJson`（`task.dart:147-149`），即 `GET /api/tasks` 响应。**没有任何本地分组表**。

Web 侧完全一致：

```ts
// web/src/views/tasks/taskLabels.ts:3
const TASK_GROUP_LABEL_PREFIX = '分组:'
```

→ **结论：Web 建的分组，APP v1.3.3 应该能显示**。issue 里「网页建的分组，手机不会显示」大概率是老版本 APP，或是用户把 Web 的「视图」当成了「分组」（见问题 3）。

### 一个真实但轻微的 bug：分组筛选用 LIKE，会串味

`_showGroupPicker` 选中分组后调 `setLabelFilter(selected)`，传的是**显示名**而非 `分组:<name>`（`task_list_page.dart:669-671`）：

```dart
ref.read(taskProvider.notifier).setLabelFilter(selected.isEmpty ? null : selected);
```

`task_provider.dart:81-83` 把它作为 `label` query 参数发出，服务端做的是模糊匹配（`server/handler/task_query.go:68-69`）：

```go
if label != "" {
    query = query.Where("labels LIKE ?", "%"+label+"%")
}
```

后果：筛选分组「生产」时，一个只挂了**普通标签**「生产」、根本没分组的任务也会被捞回来，然后在客户端落进「未分组」桶。表现为「我筛了生产分组，列表里却出现一条未分组分组头」。同理 `分组:生产环境` 也会被「生产」捞到。

## 问题 2：本地持久化

见 currentState 第 3 节的表格。补充要点：

- `saveUiState` 走的是 **SharedPreferences 明文**，不是 `flutter_secure_storage`（`secure_storage.dart:303-306`），命名空间前缀 `ui_state_`（`:81`）。
- 恢复流程 `_restoreTaskUiState`（`task_list_page.dart:446-484`）有个刻意设计：`collapsed_groups` 从没写过时默认塞一个空串，即**默认折叠「未分组」组**（`:461-463`）。
- 已选分组会在启动时被恢复成 `labelFilter`（`:479-483`），所以上面那条 LIKE 串味问题在冷启动后也会重现。
- **`group_order` 是纯本地的**：面板没有任何「分组顺序」概念，`sortTaskGroupsByOrder`（`task_list_rows.dart:61-79`）只读本地值。换手机 / 清数据即丢，也不会跟 Web 对齐。

## 问题 3：端点清单 —— 与任务/分组相关的全部 23 条

`api_endpoints.dart:39-64`：

```
tasks                /api/tasks                       列表(GET)/新建(POST)
taskById(id)         /api/tasks/:id                   详情/更新/删除
taskRun/Stop         /api/tasks/:id/run|stop
taskEnable/Disable   /api/tasks/:id/enable|disable
taskPin/Unpin        /api/tasks/:id/pin|unpin
taskCopy             /api/tasks/:id/copy
taskLatestLog        /api/tasks/:id/latest-log
taskLiveLogs         /api/tasks/:id/live-logs
taskLogFiles         /api/tasks/:id/log-files
taskStats            /api/tasks/:id/stats
tasksBatch*          /api/tasks/batch[/enable|disable|delete|run]
tasksCleanLogs       /api/tasks/clean-logs
tasksExport/Import   /api/tasks/export|import
cronParse/Templates  /api/tasks/cron/parse|templates
notificationChannels /api/tasks/notification-channels
```

**没有一条 group / view 相关端点。** 对比同文件 `:122-124` 环境变量是有的：`envsBatchGroup = /api/envs/batch/group`、`envsGroups = /api/envs/groups`。

面板实际存在但 APP 没接的五条（`server/handler/task_routes.go:56-60`）：

```go
tasks.GET   ("/views",          RequireRole("viewer"),   h.ListViews)
tasks.POST  ("/views",          RequireRole("operator"), h.CreateView)
tasks.PUT   ("/views/reorder",  RequireRole("operator"), h.ReorderViews)
tasks.PUT   ("/views/:viewId",  RequireRole("operator"), h.UpdateView)
tasks.DELETE("/views/:viewId",  RequireRole("operator"), h.DeleteView)
```

全部挂在 `tasks := r.Group("/tasks", middleware.JWTAuth(), middleware.OpenAPIAccess("tasks"))` 下（`task_routes.go:18`），也就是 APP 现有的鉴权链原样可用，不需要新的 OpenAPI scope。

### filters / sort_rules 契约（照抄可用）

字段（`task_query.go:411-441` + `ViewManager.vue:64-69`）：

| field | 匹配的值 | Web 文案 |
|---|---|---|
| `command` | task.Command | 命令 |
| `name` | task.Name | 名称 |
| `cron_expression` | 原始串 **+ 每一行拆开后的表达式** | 定时规则 |
| `status` | 数值串 / 「禁用中·排队中·运行中·空闲中」/ 「已禁用·排队中·运行中·已启用」三种写法都匹配 | 状态 |
| `labels` | **display_labels**（分组名已 unshift 到首位，`subscription:<id>` 已换成订阅名） | 标签 |
| `subscription` | subscription_labels | 订阅 |

操作符（`task_query.go:457-488`）：`contains` / `not_contains` / `equals` / `not_equals`，**全部先 `strings.ToLower` + `TrimSpace`**，空 target 恒真。多条 filter 之间是 **AND**（`task_query.go:401-409`）。

排序：`{field, direction}`，direction 非 `desc` 一律归一成 `asc`（`task_query.go:379-381`）；`sort_rules` 为空时回落 `defaultTaskListLess`（`task_query.go:533`），即置顶优先的默认序。

**与 `all=1` 兼容**：`task_query.go:116-119` 在 filters/sort_rules 分支里也认 `wantAll`，直接整份返回。APP 现有的 `all=1` 全量取数模型不用改。

## 问题 4：任务模型的分组/标签字段

`task.dart` 只有两个 labels 相关字段（`:14-15`）：

```dart
final String labels;              // 原始，逗号拼接（fromJson 兼容 List 与 String，:147-149）
final List<String> displayLabels; // 服务端 display_labels，:150-155
```

**没有 `group_id` / `category` / `folder`。** 派生 getter 三个：`labelList`(:95-97) → 原始拆分；`labelsForDisplay`(:99-100) → displayLabels 优先回落 labelList；`userLabelsForDisplay`(:121-130) → 去掉分组项。

`task_provider.dart` 的组织方式：`load()` 一次性 `all=1` 全量拉（`:70-100`，注释在 `:64-69` 明确说明「分组下拉项/全选/拖拽排序都建立在全部任务在内存里」），列表**不做客户端分组**，分组是页面层 `build()` 里现算的（`task_list_page.dart:681-696`）。

## 问题 5：脚本页 / 订阅页

**脚本页**（`script_list_page.dart`）：没有分组概念。有的是
- 目录树本身（`_filterTree` :532、`_sortScriptTree` :602）—— 天然层级即「分组」；
- 本地收藏 `ui_state_scripts.favorite_paths`（:461,469,509）；
- 关键字搜索。

**订阅页**（`subscription_list_page.dart`）：只有关键字搜索（`:83,101-103,274`）。`:612`/`:934`/`:1270` 的 ChoiceChip 全是**表单里的类型选择**（git-repo / single-file，见 `:600-624`），不是列表筛选。

**能复用的不是这两个页，而是环境变量页**（`env_list_page.dart:1087-1110`）：它已经实现了「服务端分组列表（`/api/envs/groups`）+ PopupMenuButton 多选筛选 + `__all__` 全部项」，是 APP 内最接近「任务视图选择器」的现成形态。

## 问题 6：筛选/搜索 UI 现状与接入点

`task_list_page.dart` 的 `build()` 从上到下：

| 行号 | 组件 | 内容 |
|---|---|---|
| 708-751 | 标题行 Row | 「定时任务」+ 批量 / 排序 / 新建 三个 AppChipButton |
| 753-807 | TextField | 搜索任务名称或命令 |
| **809-849** | **横向 ListView.separated + ChoiceChip** | **状态筛选：全部 / 运行中 / 排队中 / 已启用 / 已禁用**（`_taskStatusFilters` 定义在 `:49-55`） |
| **851-887** | **Row** | 左「共 N 个任务」+ 右 **`TextButton.icon` 分组选择器（:863-871）** + 条件出现的「清除筛选」(:872-884) |
| 888-944 | 批量操作条 | 仅 `_selectionMode` |
| 945-955 | 排序提示 | 仅 `_taskSortMode` |
| 956-1022 | Expanded + RefreshIndicator | 五分支：loading / error / empty / 任务拖拽 / 分组拖拽 / `ListView.builder`(:1001-1020) |

### 新增「视图」最自然的接入点：`851-887` 这一行

理由：这一行已经是「筛选态汇总条」—— 分组选择器（`:863-871`）和「清除筛选」（`:872-884`）都在这儿，且它是唯一一处**横跨全部筛选维度**的位置。具体两种改法：

**方案 A（改动最小，推荐）**：在 `:862` 的 `Spacer()` 之后、分组 TextButton 之前，插入一个同形态的 `TextButton.icon`（图标建议 `Icons.filter_alt_outlined`），点开一个 `showModalBottomSheet` 视图列表 —— 结构可以直接照抄 `_showGroupPicker`（`:612-673`），把「全部分组 / 已有分组 / 新建分组」换成「全部任务 / 已有视图 / 新建视图」。

**方案 B（更贴近 Web）**：Web 是把视图做成任务页顶部的**标签页**（ViewManager.vue）。APP 对应位置是 `:809-849` 那条横向 ChoiceChip 带 —— 可以在状态筛选带**上方**再加一条同规格（`height: 38` + `ChoiceChip`）的视图带。代价是纵向再吃掉约 48dp，而 `task_list_rows.dart:1-18` 和 `:1438-1441` 的注释显示这个团队对任务页的纵向密度非常敏感（专门为省 60.9dp 做过重构），所以方案 A 更符合既有取向。

配套改动点：
- `TaskListState` 加 `List<TaskViewFilter> filters` / `List<TaskViewSortRule> sortRules`（`task_provider.dart:11-53`），`copyWith` 沿用现有 `_unset` 哨兵模式；
- `load()` 的 `queryParams` 里补 `filters` / `sort_rules`（`task_provider.dart:74-83`），值是 `jsonEncode`；
- 「清除筛选」的条件（`:872`）和动作（`:874-882`）要一并把视图清掉。

## 附带发现：APP 编辑任务会丢 `subscription:<id>` 标签（数据丢失）

这不是 issue #4 的内容，但和「labels 往返」是同一套机制，改分组功能时必然会碰到，所以一并报出。

`task_form_page.dart:160-162` 用 **显示用**标签播种编辑框：

```dart
_labels
  ..clear()
  ..addAll(task?.userLabelsForDisplay ?? const []);
```

`userLabelsForDisplay`（`task.dart:121-130`）基于 `labelsForDisplay`，而后者优先用服务端的 `display_labels` —— 那里面 `subscription:<id>` **已经被服务端换成了订阅的显示名**（`server/handler/task_query.go:304-327`）。

保存时（`task_form_page.dart:517-522,538`）：

```dart
final normalizedLabels = <String>[
  ..._labels.where((label) => !Task.isGroupLabel(label)),
];
if (groupName.isNotEmpty) normalizedLabels.add(Task.toGroupLabel(groupName));
// ...
'labels': normalizedLabels,
```

服务端 `Update` 是**整体覆写**（`server/handler/task_mutate.go:200-206`，`labels` 在 allowedFields 里 `:275`）。

具体走一遍：原始 labels `["分组:娱乐", "subscription:3"]`，订阅名「华星电信」
→ display_labels `["娱乐", "华星电信"]`
→ `userLabelsForDisplay` = `["华星电信"]`（「娱乐」被 `:125-128` 移除）
→ 提交 `["华星电信", "分组:娱乐"]`
→ **`subscription:3` 消失，任务脱离订阅托管**。

而面板代码里明确假设了前端不会这么干（`task_mutate.go:316-317` 原注释）：

> 判定刻意用改动前的 labels：订阅归属不会因为这一次编辑改变——**前端编辑标签时内部标签原样保留**

Web 确实做到了（`taskLabels.ts:176-181` 的 `mergeTaskLabels` 显式带上 `internalLabels`），APP 没有。

后果：订阅锁失效、详情页「恢复为订阅默认」入口消失、下次订阅拉取可能重建一个同名重复任务。

**触发条件**：仅当面板返回 `display_labels` 时（v3.x）。老面板不下发该字段，`labelsForDisplay` 回落 `labelList`（原始），`subscription:3` 反而能存活 —— 所以这是个「面板升级后才出现」的回归。

另注：`task_provider.dart:243-257` 的 `batchUpdateGroupLabel`（分组增删改走的路径）用的是 `task.labelList`（**原始** labels），只剔 `分组:` 前缀，**没有这个问题**。只有任务编辑表单有。

## proposedFix

## 前置：先确认 issue #4 的第一句是不是误报

在动手之前建议先跟报告者确认 APP 版本 + 让其描述「网页上建分组的具体操作路径」。因为代码证据显示标签式分组是同步的，而「用命令/订阅关键字建规则」只存在于面板的**任务视图**里。若确认是视图，则整个 issue 收敛成「APP 补齐任务视图」这一件事，第一句无需改动。

## 主体改动：APP 补齐「任务视图」

### 1) `lib/core/network/api_endpoints.dart`

在 `:62` 的 `cronTemplates` 后、`notificationChannels` 前补一组（与面板 `server/handler/task_routes.go:56-60` 对齐，建议照该文件既有风格加一行注释指向路由出处）：

```dart
// Task Views（任务视图）。路由见面板 server/handler/task_routes.go:56-60。
// 注意 reorder 是静态段，必须排在 :viewId 之前，与面板路由顺序一致。
static const String taskViews = '$baseApi/tasks/views';
static String taskViewById(int id) => '$baseApi/tasks/views/$id';
static const String taskViewsReorder = '$baseApi/tasks/views/reorder';
```

### 2) 新建 `lib/shared/models/task_view.dart`

对齐 `server/model/task_view.go:5-17`。注意 `filters` / `sort_rules` 在传输层是 **JSON 字符串**（不是对象），模型里要负责 encode/decode 两层：

```dart
class TaskViewFilter { final String field, operator, value; }   // 三字段全 String
class TaskViewSortRule { final String field; final String direction; } // asc|desc
class TaskView {
  final int id; final String name;
  final List<TaskViewFilter> filters;      // 由 filters:String 解出
  final List<TaskViewSortRule> sortRules;  // 由 sort_rules:String 解出
  final bool hidden; final int sortOrder;
}
```

解析要**容错**：`filters` 可能是 `''`、`'[]'` 或非法 JSON，一律降级成空列表（面板 `task_query.go:337-346` 自己也是这么兜的）。参考 `task.dart:185-192` 那几个 `_int/_date` 私有辅助的写法。

### 3) 新建 `lib/features/tasks/providers/task_view_provider.dart`

`StateNotifier<TaskViewListState>`，构造参数照抄 `TaskNotifier({Dio? dio})` 的可注入模式（`task_provider.dart:56-62`，为了可单测）。方法：`load()` / `create()` / `update()` / `delete()` / `reorder()`。

**降级要求**：`GET /api/tasks/views` 失败（老面板 404、viewer 以下角色 403）时**不要抛**，降级成空视图列表 + 隐藏入口，参考 `env_list_page.dart:113-115,153` 对分组列表的同款处理注释。

### 4) `lib/features/tasks/providers/task_provider.dart`

- `TaskListState` 加两个字段（`:11-28`），`copyWith` 沿用 `:36-37` 的 `_unset` 哨兵；
- `load()` 的 `queryParams`（`:74-83`）补：

```dart
if (state.filters.isNotEmpty) {
  queryParams['filters'] = jsonEncode(state.filters.map((f) => f.toJson()).toList());
}
if (state.sortRules.isNotEmpty) {
  queryParams['sort_rules'] = jsonEncode(state.sortRules.map((r) => r.toJson()).toList());
}
```

- 加 `void applyView(TaskView? view)`：设置两个字段后 `load(refresh: true)`；传 null 表示清空。

`all=1` 不用动，面板在 filters 分支里同样认（`task_query.go:116-119`）。

### 5) `lib/features/tasks/views/task_list_page.dart`

- 在 `:862` 的 `Spacer()` 之后插入视图选择 `TextButton.icon`，样式与相邻的分组选择器（`:863-871`）一致；
- 新增 `_showViewPicker()`，结构照抄 `_showGroupPicker`（`:612-673`）：ListTile「全部任务」+ 已有视图列表（`hidden==true` 的不显示，按 `sortOrder` 排）+ 分隔线 + 「新建视图」；沿用 `_createGroupSentinel`（`:610`）同款哨兵模式；
- 新增视图编辑对话框：字段/操作符下拉的选项逐条照抄 `ViewManager.vue:64-88`（含 `status` 字段要换成 `:73-76` 那四个预设值下拉，而不是自由文本框）；
- 持久化选中视图 id：加第五个 key `tasks.selected_view`，写入点比照 `:672`，恢复点比照 `_restoreTaskUiState`（`:446-484`）；
- 「清除筛选」的显示条件（`:872`）与动作（`:874-882`）要把视图一起算进去 / 清掉。

### 6) 顺手修的两个 bug

**(a) 分组筛选 LIKE 串味**（`task_list_page.dart:669-671`）

把传给 `setLabelFilter` 的值从显示名换成带前缀的完整标签：

```dart
.setLabelFilter(selected.isEmpty ? null : Task.toGroupLabel(selected));
```

这样服务端 `LIKE '%分组:生产%'` 就不会再捞到普通标签「生产」。但 `分组:生产环境` 仍会被「分组:生产」命中 —— 要彻底精确，改用视图 filter：`{field:'labels', operator:'equals', value:'生产'}`（`labels` 匹配的是 display_labels，分组名在里面是独立一项，`task_query.go:434-435`）。**注意**：`_selectedGroupStorageKey` 里存的是旧格式裸名，改了要么同步改写入格式、要么在 `:479-483` 恢复时做一次兼容归一。

**(b) 编辑任务丢 `subscription:` 标签**（`task_form_page.dart:160-162`）

`_labels` 改用**原始**标签播种，并新增一个 `_internalLabels` 原样透传，对齐 Web 的 `splitTaskLabels` / `mergeTaskLabels`（`taskLabels.ts:155-181`）：

```dart
// initState 附近，:160-162
final raw = task?.labelList ?? const <String>[];
_internalLabels
  ..clear()
  ..addAll(raw.where((l) => l.trim().startsWith('subscription:')));
_labels
  ..clear()
  ..addAll(raw.where((l) => !Task.isGroupLabel(l)
      && !l.trim().startsWith('subscription:')));

// _save，:517-523
final normalizedLabels = <String>[
  ..._labels.where((label) => !Task.isGroupLabel(label)),
  ..._internalLabels,
];
```

`subscription:` 前缀建议提成 `Task.subscriptionLabelPrefix` 常量放 `task.dart`，与 `groupLabelPrefix` 并列，别散在页面里。判前缀要**先 trim**（历史脏数据有 `" subscription:1"`，面板 `hasSubscriptionLabel` 是 trim 后判的，Web 在 `taskLabels.ts:20-24` 有一大段注释专门讲这个坑）。

### 7) 测试

`test/features/tasks/task_list_rows_test.dart` 已存在，说明这套纯函数是可单测的。建议同目录补：
- `task_view_model_test.dart`：filters 为 `''` / `'[]'` / 非法 JSON 的降级；
- `task_form_labels_test.dart`：给定 `["分组:娱乐","subscription:3"]` + display_labels `["娱乐","华星电信"]`，断言提交体里 `subscription:3` 仍在（这是 (b) 的回归锁）。

## risks

**1. 可能修错了问题。** 若 issue #4 的第一句真的是「标签式分组不同步」（而非我推断的「视图」），那么补视图不解决用户的痛点。代码证据强烈支持我的推断，但没有用户的实际版本号和操作录屏，这一步是推理不是实证。建议先问清楚再动工。

**2. 面板版本兼容。** `/api/tasks/views` 的引入版本我没查（见 openQuestions）。APP 要连老面板，`load()` 拿到 404 必须静默降级成「无视图」，不能弹错误、更不能让整个任务页红掉。同理 `display_labels` / `subscription_labels` 也是后加字段，`task.dart:150-155` 已经做了容错，新代码要保持同样标准。

**3. 角色权限。** `ListViews` 要 `viewer`，增删改要 `operator`（`task_routes.go:56-60`）。APP 若不看当前用户角色就渲染「新建视图」按钮，viewer 用户点了会吃 403。`env_list_page.dart:113-115` 的注释显示这个坑在环境变量分组上已经踩过一次。

**4. 服务端 filters 分支没有 5000 条保护。** 无 filters 时走 `ordered.Limit(5000)`（`task_query.go:82-83`），有 filters 时是裸 `query.Find(&tasks)`（`:104`）—— 全表进内存再过滤。任务量极大的实例上，APP 每次切视图都会打这条无上限路径。这是面板侧的既有行为（Web 也这么用），但 APP 加进来会**增加触发频率**。

**5. 视图名全局唯一且无 user_id**（`task_view.go:7-10` 注释明说）。多用户面板上 A 建的视图 B 也能看见和删。APP 的 UI 文案不要暗示「我的视图」。同名创建会被拒（`duplicate_name_regression_test.go:66-78`，报「同名任务视图已存在」），要正确显示这个后端错误而不是笼统的「保存失败」。

**6. 分组筛选改成带前缀会破坏已存的本地状态。** `ui_state_tasks.selected_group` 里存量是裸分组名。改格式必须在 `_restoreTaskUiState`（`task_list_page.dart:446-484`）加一次归一，否则老用户升级后冷启动会拿一个裸名去做 `LIKE '%分组:xxx%'` 之外的错误匹配 —— 具体表现取决于改法，最坏是筛出空列表且看不出为什么。

**7. `subscription:` 标签修复会改变编辑页可见标签集。** 修完之后，订阅托管的任务在编辑页**不再显示**订阅名那枚 chip（因为它现在被归进 `_internalLabels` 不渲染了）。这与 Web 行为一致（`splitTaskLabels` 就是这么分的），但对老用户是可见变化，可能被当成新 bug 报回来。

**8. 纵向密度。** `task_list_rows.dart:1-18` 与 `task_list_page.dart:1438-1441` 的长注释显示，任务页的每一 dp 都是有人专门优化过的。任何新增常驻筛选行都会被视为回退 —— 这是我推荐方案 A（复用现有 `:851-887` 那一行）而非 Web 式标签页的主要原因。

## openQuestions

- issue #4 报告者用的 APP 版本是多少？如果 < 某个引入 `分组:` 支持的版本，第一句抱怨就是「升级即可」，整个 issue 收敛成只补任务视图。我没查 APP 的 git 历史来定位 `groupLabelPrefix` 的引入版本。
- 报告者说的「网页建的分组」，具体是在 Web 的哪个 UI 建的？是任务编辑页的「任务分组」输入框（= 标签式，会同步），还是任务页顶部的视图管理器 ViewManager（= TaskView，不会同步）？这决定了要不要动第一半。
- `/api/tasks/views` 这组端点是面板哪个版本引入的？APP 需要按最低支持面板版本决定是硬依赖还是特性探测降级。查 docs/release-notes/ 应能定位（我只看到 v2.2.14.md 在 task_view grep 结果里出现，但没读内容确认是不是引入版本）。
- 面板的任务视图是全局的（`task_view.go:7` 明确说这张表没有 user_id）。APP 侧要不要限制只有 operator 及以上才显示「新建/编辑视图」入口？需要确认 APP 当前是否已经在别处读取并使用了用户角色 —— 我没查 `user.dart` 的 role 字段用法。
- APP 的分组顺序（`ui_state_tasks.group_order`）是纯本地的，面板没有对应概念。这次要不要顺便把它也做成服务端同步（比如复用 TaskView 的 sort_order 语义），还是保持本地？这属于产品决策，不是代码能回答的。
- 我没有实际运行 APP 或面板做端到端验证 —— 本次是纯静态代码调查（按要求只读）。特别是「Web 建的标签式分组在 APP 上确实能看到」这一条，是从两侧代码逐字比对推出的，没有实机跑通。