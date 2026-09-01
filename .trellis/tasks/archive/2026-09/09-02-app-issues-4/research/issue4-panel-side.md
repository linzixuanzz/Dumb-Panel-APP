# agent-1

## summary

面板侧「分组」其实是两套完全不同的东西，issue #4 说的是第二套。第一套「任务分组」= 任务标签里的 `分组:<名>` 前缀，存在服务端 `tasks.labels` 字段里，APP 早就在读它（task.dart:4/108），所以这一套本来就是同步的。第二套「任务视图 TaskView」= 网页任务页顶部那排可点的 tab（ViewManager.vue:278-296），每个 tab 带一组 filters/sort_rules 规则，存在服务端 `task_views` 表里，有完整的 CRUD + 排序接口 `/api/v1/tasks/views`，而 APP 完全没有接这套 API（全仓只在备份勾选项里出现过 task_views 字样）。用户说的「按命令、订阅含关键字等规则」逐字对应 TaskView 的 filter 字段 command / subscription + 运算符 contains（ViewManager.vue:63-84 ↔ task_query.go:411-489）。因此 Q6 的前提不成立：分组不是浏览器 localStorage，服务端**不需要新增任何表/接口/迁移**，APP 直接消费现成的 `GET /tasks/views` 再把 filters/sort_rules 透传给 `GET /tasks` 即可。localStorage 只承载三个纯 UI 偏好（页大小、标签显示开关、「全部」tab 是否隐藏）。

## currentState

**A. 任务分组（label 型，已同步）**
- 载体：任务标签数组里带前缀 `分组:` 的那一条。前端常量 `TASK_GROUP_LABEL_PREFIX = '分组:'`（web/src/views/tasks/taskLabels.ts:3），后端常量 `taskGroupLabelPrefix = "分组:"`（server/handler/task_query.go:268）。
- 存储：`Task.Labels string \`gorm:"size:256;default:''" json:"-"\``（server/model/task.go:38），逗号拼接的单列字符串，`SetLabelsFromSlice` / `GetLabels` 就是 `strings.Join` / `strings.Split(",")`（server/model/task.go:209-218）。**不是独立表，没有 group_id 外键**。
- 写入口：网页任务表单「任务分组」文本框（web/src/views/tasks/components/TaskForm.vue:309-310），提交前由 `mergeTaskLabels()` 把 `分组:<名>` 拼回 labels 数组（TaskForm.vue:223 → taskLabels.ts:176-181），走 `POST /tasks` / `PUT /tasks/:id` 的 `labels` 字段（server/handler/task_mutate.go:59,153,200-205）。
- 渲染：网页**只把分组名当成一枚彩色 chip** 挂在任务名后面，没有分组头、没有折叠、没有树（web/src/views/tasks/index.vue:1238-1248）。后端把分组名 unshift 到 `display_labels[0]`（server/handler/task_query.go:330-332）。
- APP 侧已经在解析同一个前缀（android-app/lib/shared/models/task.dart:4 `groupLabelPrefix = '分组:'`、:108 `get groupName`），并据此分桶渲染分组头 + 「未分组」桶（task_list_rows.dart:34-55）。**所以这一套跨端本来就是通的。**

**B. 任务视图 TaskView（规则型，APP 完全没接）**
- 存储：独立表 `task_views`（server/model/task_view.go:5-21），字段 `id / name(uniqueIndex) / filters(text,默认'[]') / sort_rules(text,默认'[]') / hidden(bool,index) / sort_order(int,index) / created_at / updated_at`。表上**没有 user_id，是全局共享的**（model/task_view.go:7 注释明说）。
- `filters` 与 `sort_rules` 都是 JSON 字符串，内容分别是 `[{field,operator,value}]` 和 `[{field,direction}]`。
- 网页 UI：任务页顶部一排 tab（web/src/views/tasks/components/ViewManager.vue:278-296），第一个是「全部」，其余每个 tab 是一个视图；点 tab → `selectView()` 解析 JSON → emit `view-change`（ViewManager.vue:136-152）→ 页面把它们塞进 `GET /tasks` 的 `filters` / `sort_rules` 查询串（index.vue:154, 235-241）。
- 服务端筛选/排序全在 `GET /tasks` 里做（server/handler/task_query.go:42-43, 103-131）。
- **APP 侧零消费**：全仓 grep `tasks/views` / `TaskView` 在 android-app/lib 下只命中备份页的勾选项文案（backup_page.dart:257「任务视图 / 分组视图与自定义筛选排序」），没有任何 API 调用。

**C. 环境变量分组（另一套，与任务无关）**
`EnvVar.Group string \`gorm:"size:512;default:'';index" json:"group"\``（server/model/env_var.go:21），逗号分隔多组，有 `GET /envs/groups`、`PUT /envs/batch/group` 等接口（server/handler/env.go:1196,1201）。「未分组」这个字样在整个面板里**只出现在环境变量页**（web/src/views/envs/index.vue:1019,1174）。

**D. 脚本分组：不存在。** server/handler/script_routes.go 里 grep `group` 零命中。

## keyFiles

- `D:\GitHub\呆呆面板开发\server\model\task_view.go` :5-21 — TaskView 表结构：name 唯一索引 / filters / sort_rules / hidden / sort_order；无 user_id（全局共享）
- `D:\GitHub\呆呆面板开发\server\handler\task_view.go` :14-167 — 视图 CRUD + reorder 的全部实现（ListViews/CreateView/UpdateView/DeleteView/ReorderViews）
- `D:\GitHub\呆呆面板开发\server\handler\task_routes.go` :56-60 — 视图 5 条路由注册；同时看到 tasks 组统一挂 JWTAuth + OpenAPIAccess("tasks")（:18）
- `D:\GitHub\呆呆面板开发\server\handler\task_query.go` :19-28, 337-385, 401-489, 517-563 — 规则的定义与匹配实现：filter/sort 结构体、解析、字段取值、四种运算符、排序比较
- `D:\GitHub\呆呆面板开发\server\handler\task_query.go` :268-335 — 分组标签前缀常量 + display_labels/subscription_labels 构造（分组名 unshift 到第 0 位）
- `D:\GitHub\呆呆面板开发\server\model\task.go` :38, 209-218 — 任务分组的真实存储：tasks.labels 单列 size:256 逗号拼接字符串
- `D:\GitHub\呆呆面板开发\web\src\views\tasks\components\ViewManager.vue` :32-95, 136-152, 278-296 — 视图 tab 条 UI、规则字段/运算符下拉选项、唯一一处与视图相关的 localStorage（'dd:tasks:view_all_hidden'）
- `D:\GitHub\呆呆面板开发\web\src\api\taskView.ts` :1-59 — 视图接口的前端契约：TS 类型 + 5 个方法的路径与请求体形状，APP 可直接照抄
- `D:\GitHub\呆呆面板开发\web\src\views\tasks\index.vue` :39, 71, 154, 235-241, 1238-1248 — 两个 UI 偏好 localStorage key；视图规则如何进入 GET /tasks；分组只渲染成 chip
- `D:\GitHub\呆呆面板开发\web\src\views\tasks\taskLabels.ts` :3, 32-46, 111-153, 176-181 — 分组前缀解析/拼装、display_labels 三分类（分组/订阅/自定义）
- `D:\GitHub\呆呆面板开发\web\src\views\tasks\components\TaskForm.vue` :53, 96, 126, 223, 309-310 — 网页上唯一创建/修改任务分组的入口（「任务分组」文本框）
- `D:\GitHub\呆呆面板开发\server\handler\task_labels.go` :58-76, 103-110 — 批量加标签接口会主动丢弃 分组:/subscription: 前缀，所以它不能用来批量改分组
- `D:\GitHub\呆呆面板开发\server\model\system_config.go` :14-20, 34-105 — 键值配置的既有范式（如果日后真要为跨端偏好新增服务端存储，照抄这套）
- `D:\GitHub\呆呆面板开发\server\handler\config.go` :188-206, 214-215 — 配置批量写接口范式：PUT /configs {configs: {k: v}}，RequireAdmin
- `D:\GitHub\Dumb Panel\android-app\lib\shared\models\task.dart` :4, 108, 125 — APP 已经在解析 '分组:' 前缀 —— 证明 label 型分组本就跨端同步
- `D:\GitHub\Dumb Panel\android-app\lib\features\tasks\utils\task_list_rows.dart` :34-55, 57-60 — APP 的分组分桶与「未分组」桶；分组顺序来自本地 groupOrder
- `D:\GitHub\Dumb Panel\android-app\lib\features\tasks\views\task_list_page.dart` :60, 63, 467-496 — APP 的分组折叠态/顺序存在设备本地 SharedPreferences（'tasks.collapsed_groups' / 'tasks.group_order'），这两项才是真正没有服务端载体的

## detailedFindings

## 1. 面板 web 的「分组」到底是什么

grep `分组` 命中 18 个前端文件，去掉环境变量与备份页后，任务域只剩两个概念：

**(a) 任务分组 = 标签前缀**
```
web/src/views/tasks/taskLabels.ts:3
const TASK_GROUP_LABEL_PREFIX = '分组:'
```
UI 入口只有一处，是任务表单里的普通文本框：
```
web/src/views/tasks/components/TaskForm.vue:309-310
<el-form-item label="任务分组">
  <el-input v-model="form.group_name" placeholder="例如 京东 / 日常 / 中国联通" />
```
提交时拼回 labels：`TaskForm.vue:223 → data.labels = mergeTaskLabels(form.labels, internalLabels, form.group_name)`，`mergeTaskLabels` 在 taskLabels.ts:176-181 把 `分组:<名>` push 进数组。

**(b) 任务视图 = tab + 规则**
```
web/src/views/tasks/components/ViewManager.vue:278-296
<div class="view-tabs"><div class="view-seg">
  <button :class="['view-tab', {active: activeViewId===null}]">…全部…</button>
  <button v-for="view in visibleViews" :key="view.id" @click="selectView(view.id)">{{ view.name }}</button>
```
**注意它不是任务分组**，但视觉上就是一排「分组页签」，用户口中「网页建的分组」几乎必然指这个 —— 因为 (a) 那一套 APP 早就在读了（见第 6 节）。

不是脚本分组：`server/handler/script_routes.go` grep `group` 零命中。
环境变量另有一套独立分组（`env_vars.group`，server/model/env_var.go:21），与任务分组无任何代码共享。

## 2. 数据存在哪 —— 结论：**全部在服务端数据库，localStorage 只有 UI 偏好**

**任务分组** → `tasks.labels` 列：
```go
// server/model/task.go:38
Labels string `gorm:"size:256;default:''" json:"-"`
// :209-218
func (t *Task) SetLabelsFromSlice(labels []string) { t.Labels = strings.Join(labels, ",") }
func (t *Task) GetLabels() []string { return strings.Split(t.Labels, ",") }
```
即：`labels = "京东,分组:日常,subscription:3"` 这种逗号拼接串。没有独立分组表。

**任务视图** → 独立表 `task_views`：
```go
// server/model/task_view.go:5-21
type TaskView struct {
    ID        uint   `gorm:"primarykey" json:"id"`
    Name      string `gorm:"size:128;uniqueIndex;not null" json:"name"`
    Filters   string `gorm:"type:text;default:'[]'" json:"filters"`
    SortRules string `gorm:"type:text;default:'[]'" json:"sort_rules"`
    Hidden    bool   `gorm:"default:false;index" json:"hidden"`
    SortOrder int    `gorm:"default:0;index" json:"sort_order"`
    CreatedAt time.Time; UpdatedAt time.Time
}
func (TaskView) TableName() string { return "task_views" }
```
AutoMigrate 已登记：server/appboot/appboot.go:108。备份/还原也已覆盖：server/service/backup_runtime.go:188-189, 838-843。

**localStorage 只有 3 个 key，全是纯展示偏好，不含任何分组数据：**
- `dd:tasks:page_size`（index.vue:39）— 分页大小
- `dd:tasks:name_labels`（index.vue:71）— 「显示设置」里 订阅/分组/自定义/类型 四个标签开关
- `dd:tasks:view_all_hidden`（ViewManager.vue:32）— 「全部」这个 tab 是否隐藏

## 3. 服务端分组相关 API —— **有，而且是完整的**

路由（server/handler/task_routes.go:56-60，挂在 `tasks := r.Group("/tasks", middleware.JWTAuth(), middleware.OpenAPIAccess("tasks"))` 下，同时注册到 `/api/v1` 与 `/api` 两套前缀，router.go:38-39）：

| 方法 | 路径 | 角色 | handler |
|---|---|---|---|
| GET | `/tasks/views` | viewer | ListViews（task_view.go:14-18） |
| POST | `/tasks/views` | operator | CreateView（:20-52） |
| PUT | `/tasks/views/reorder` | operator | ReorderViews（:128-167） |
| PUT | `/tasks/views/:viewId` | operator | UpdateView（:62-102） |
| DELETE | `/tasks/views/:viewId` | operator | DeleteView（:104-113） |

字段：
- **ListViews 响应**：`TaskView[]`，按 `sort_order ASC, id ASC`（task_view.go:16）。
- **CreateView 请求**：直接 `ShouldBindJSON(&model.TaskView)`，实际用到 `name`（必填，空串 400「视图名称不能为空」）、`filters`、`sort_rules`、`sort_order`（传 0 或不传 → 自动取 `MAX(sort_order)+1`，:39-43）。name 撞唯一索引 → 400「同名任务视图已存在」（:47-50）。
- **UpdateView 请求**：全指针可选 `{name?, filters?, sort_rules?, hidden?, sort_order?}`（:54-60）。⚠️ `name/filters/sort_rules` 传空串等同不改（:77-85），所以**没法把 filters 清成 `""`**，要清得传 `"[]"`。
- **ReorderViews 请求**：`{views: [{id(必填), sort_order, hidden?}]}`，事务批量更新，payload 里没出现的 id 原样不动；响应 `{updated: N, views: TaskView[]}`（:115-167）。

另外，规则的**实际生效点**在任务列表接口：
```go
// server/handler/task_query.go:42-43
filters   := parseTaskListFilters(c.Query("filters"))
sortRules := parseTaskListSortRules(c.Query("sort_rules"))
```
即 `GET /tasks?filters=<JSON字符串>&sort_rules=<JSON字符串>&all=1&page=&page_size=`。前端 TS 签名同款：web/src/api/task.ts:5。

分组标签相关接口：
- 写分组：`POST /tasks` / `PUT /tasks/:id` 的 `labels` 数组（task_mutate.go:59, 153, 200-205）—— 这两条**不做内部前缀过滤**，可以直接写 `分组:xxx`。
- `PUT /tasks/batch/add-labels`（task_routes.go:52）**不能**用来批量改分组：`sanitizeIncomingLabels` 会把带 `分组:` / `subscription:` 前缀的输入全丢掉（task_labels.go:66, 107-110），且语义是纯追加（:78-101）。
- 按分组过滤可以用 `GET /tasks?label=分组:日常` —— 后端是 `labels LIKE '%<label>%'`（task_query.go:68-70），粗糙但可用。

## 4. 「规则」的定义与匹配实现

结构体（server/handler/task_query.go:19-28）：
```go
type taskListFilter struct { Field, Operator, Value string }   // json: field / operator / value
type taskListSortRule struct { Field, Direction string }        // json: field / direction
```

**可选字段**（后端 task_query.go:411-441 ↔ 前端下拉 ViewManager.vue:63-70）：

| field | 中文 | 取值来源 |
|---|---|---|
| `command` | 命令 | `task.Command`（单值） |
| `name` | 名称 | `task.Name` |
| `cron_expression` | 定时规则 | 整串 + 按换行切分出的每一条（:417-427，多行 cron 逐行都参与匹配） |
| `status` | 状态 | 三个候选串：数字（如 `1`）、`taskStatusFilterText`（禁用中/排队中/运行中/空闲中，:491-502）、`taskStatusFilterAlias`（已禁用/排队中/运行中/已启用，:504-515） |
| `labels` | 标签 | `display_labels`（**已把 `分组:` 前缀剥掉，只剩分组名**，:435） |
| `subscription` | 订阅 | `subscription_labels`（订阅名；订阅源已删则是字面量「订阅任务」，:436-437 / :315-319） |

**可选运算符**（task_query.go:457-488 ↔ ViewManager.vue:79-84）：`contains` / `not_contains` / `equals` / `not_equals`。未知运算符 → 直接 `return true`（:486-488，静默放行）。

**匹配语义**：
- **不区分大小写**：target 与每个候选值都 `strings.ToLower(strings.TrimSpace(...))`（:444, :451-452）。
- **不是正则**，`contains` 就是 `strings.Contains`（:459-461）。
- 多值字段（labels / subscription / 多行 cron）语义是 **any 命中即真**；`not_contains` / `not_equals` 则是 **all 都不命中才真**（:465-471, :479-485）。
- **空 value 视为恒真**（:446-447），且 `parseTaskListFilters` 会先把 `value == ""` 的整条规则丢掉（:353-355）。field / operator 为空同样整条丢弃。
- **多条 filter 之间是 AND**，任一不过就淘汰（:401-409）。**没有 OR、没有分组括号**。
- JSON 解析失败 → 整个 filters 当空（:344-346），**静默降级为不筛选**。

**排序**（sort_rules）：字段 `name / command / cron_expression / status / labels / subscription / created_at`（:537-563），`direction` 只认 `desc`，其它一律归一成 `asc`（:379-381）。多条按先后做 tie-break，全平手回落默认排序（置顶 > 状态分组 > sort_order > created_at DESC > id DESC，:517-535 / :207-224）。

**优先级 / 执行路径**：`filters` 与 `sort_rules` 都为空 → 走 SQL 分页快路径（:72-101）；任一非空 → `query.Find(&tasks)` **全表捞进内存**再 `filterPreparedTaskListItems` + `sortPreparedTaskListItems` + 内存切片分页（:103-131）。前端还有一层：工具栏快捷排序优先于视图自带排序（index.vue:237-241）。

## 5. 分组如何参与网页任务列表渲染

**视图（tab 型）**：
- `ViewManager` 组件挂在任务页顶部（index.vue:888 `<ViewManager @view-change="handleViewChange" />`）。
- 形态是分段控件式的一排按钮，不是树也不是折叠面板（ViewManager.vue:278-296）。
- 「全部」tab 语义 = `activeViewId === null` = 不带任何 filters/sort_rules（`selectView(null)` → `emit('view-change', [], [])`，:136-141）。
- 「全部」可以在视图管理弹窗里隐藏，该偏好写 localStorage（:32-56）；但有兜底：**一个可见视图都没有时强制把「全部」放回来**（:59-61 `showAllTab`），并有 `applyViewFallback()` 处理「当前高亮项被删/被隐藏」的三种回退（:106-123）。
- 每次点 tab → 解析该视图的 JSON → index.vue:154 `handleViewChange` 存进 `viewFilters/viewSortRules` → :235-241 序列化进 `GET /tasks` 查询串。

**分组（label 型）**：
- 网页**不做任何分组聚合**。列表是一张扁平 `el-table`，分组名只是任务名后面的一枚 chip：
  ```
  index.vue:1238-1248
  <el-tag v-for="entry in visibleTaskLabels(row)" :key="entry.key"
          :class="`task-label--${entry.kind}`" :title="taskLabelKindTitles[entry.kind]">
  ```
- 后端把分组名 unshift 到 `display_labels` 第 0 位（task_query.go:330-332），前端 `classifyDisplayTaskLabels` 用「名额消费」法把每一项标成 group/subscription/custom 并各给一套配色（taskLabels.ts:111-153，index.vue:1738-1741 的 `&--group` 配色）。
- 「显示设置」下拉可以分项隐藏 分组/订阅/自定义/类型 四类标签（index.vue:442-447, 472-477），偏好存 localStorage `dd:tasks:name_labels`。

**「未分组」在网页端不存在**：没有 `分组:` 标签的任务就是少一枚 chip，没有任何「未分组」桶或占位。全仓 grep `未分组` 只命中环境变量页两处（envs/index.vue:1019, 1174）。反倒是 APP 有「未分组」桶（task_list_rows.dart:45）。

## 6. Q6 前提不成立 —— 分组不是 localStorage，服务端不用新增东西

**关键事实：`分组:` 这套 APP 已经在读了。**
```dart
// android-app/lib/shared/models/task.dart:4
static const String groupLabelPrefix = '分组:';
// :108  String? get groupName { ... }
// task_list_rows.dart:34-55  groupTasksByGroupName() 按它分桶，空桶叫「未分组」
```
所以「网页建的分组手机不显示」不可能指 label 型分组 —— 那是同一份服务端数据。用户指的是**视图 tab**，而 issue 原文「手机也没办法通过命令、订阅含关键字等规则进行分组」逐字对上 TaskView 的 `command` / `subscription` + `contains`。

**结论：服务端零改动。** 需要做的全在 APP 侧：
1. 新增 `TaskViewApi`，照抄 web/src/api/taskView.ts:36-59 的 5 个方法与 TS 类型（Dart 端建 `TaskView` model：id/name/filters/sort_rules/hidden/sort_order）。
2. `GET /tasks/views` 拿列表 → 渲染成 tab 或 Chip 行；`filters` / `sort_rules` 是**字符串化的 JSON**，要 `jsonDecode` 两次（外层字段本身就是 String）。
3. 选中视图后，把这两段字符串**原样**作为 query 参数塞进已有的任务列表请求（`filters=` / `sort_rules=`）。后端已经会做筛选和排序，APP 不需要自己实现匹配算法。
4. 只读消费的话 `viewer` 角色就够（task_routes.go:56）；要在手机上建/改/删/拖排序则需要 `operator`。

**若日后确实要为跨端偏好新增服务端存储**（例如把 APP 的分组折叠态/拖拽顺序、或「全部」tab 是否隐藏也上云），面板里最贴近的既有范式是 `system_configs` 键值表：
```go
// server/model/system_config.go:14-20
type SystemConfig struct {
    ID uint; Key string `gorm:"size:64;uniqueIndex;not null"`;
    Value string `gorm:"type:text;default:''"`; Description string; UpdatedAt time.Time
}
// :34-49 GetConfig(key, default) string   —— 找不到/空值都回落 default
// :80-105 SetConfig(key, value) error     —— NormalizeSystemConfigValue 校验后 upsert
// :107-159 InitDefaultConfigs()           —— 启动时按注册表补默认值
```
配套接口范式：`PUT /configs {"configs": {"<key>": "<value>"}}`，逐条 `model.SetConfig` 再 `reloadRuntimeConfigKeys`（server/handler/config.go:188-206），路由 `r.Group("/configs", middleware.JWTAuth(), middleware.RequireAdmin())`（:214-215）。JSON 配置就是把整块 JSON 塞进 `Value`（`type:text`，无长度限制）。
不过更省事的做法是直接给 `task_views` 加列（它已经有 `hidden` / `sort_order` 这类纯 UI 字段的先例），或者干脆保持本地 —— 折叠态本来就该按设备走。

## proposedFix

**面板侧（server + web）：本 issue 不需要任何改动。** 所有数据与接口都已就位。

**APP 侧要新增的（供 APP agent 照抄）：**

1. `lib/shared/models/task_view.dart` — 新建 model，字段与 `server/model/task_view.go:5-21` 一一对应：
   `int id / String name / String filters / String sortRules / bool hidden / int sortOrder`。
   注意 `filters` 和 `sort_rules` 在 JSON 里是**字符串**不是数组，Dart 侧 `fromJson` 里保持 String，用到时再 `jsonDecode`（web 的 ViewManager.vue:144-151 就是 try/catch 包 `JSON.parse`，解析失败降级成空数组 —— APP 要照做，因为后端 CreateView 不校验 JSON 合法性）。

2. `lib/features/tasks/services/task_view_api.dart` — 5 个方法照抄 `web/src/api/taskView.ts:36-59`：
   - `list()` → `GET /tasks/views`
   - `create({name, filters, sortRules})` → `POST /tasks/views`
   - `update(id, {...})` → `PUT /tasks/views/{id}`（可选字段用 null 省略；**清空 filters 必须传 `"[]"` 而不是 `""`**，见 task_view.go:80-85）
   - `delete(id)` → `DELETE /tasks/views/{id}`
   - `reorder([{id, sort_order, hidden}])` → `PUT /tasks/views/reorder`

3. 任务列表请求透传：在现有 `GET /tasks` 的 query 里加 `filters` / `sort_rules` 两个可选字符串参数（后端读取点 `server/handler/task_query.go:42-43`；web 的用法 `index.vue:235-241`）。选中「全部」时两个都不传。

4. UI：在任务列表页顶部加一排视图 tab（或 Chip 行），语义对齐 web —— 第一个「全部」= 不传参数；`hidden == true` 的视图不渲染；按 `sort_order` 排（后端已排好，直接用返回顺序即可）。

5. **与 APP 现有 `分组:` 分组的关系要想清楚**：两者是正交的两个维度（视图 = 服务端规则筛选，分组 = 标签分桶）。建议做成「视图先筛，筛完的结果再按 `分组:` 分桶」，这样 `groupTasksByGroupName`（task_list_rows.dart:38）不用动。

6. （可选，补 issue 的后半句「手机也没办法建规则」）若要让手机也能**创建**视图，规则编辑器的字段/运算符选项直接抄 `ViewManager.vue:63-84`：
   - 字段：command 命令 / name 名称 / cron_expression 定时规则 / status 状态 / labels 标签 / subscription 订阅
   - 运算符：contains 包含 / not_contains 不包含 / equals 等于 / not_equals 不等于
   - status 的 value 要用固定四选一：`'1' 已启用/空闲中`、`'0' 已禁用`、`'2' 运行中`、`'0.5' 排队中`（ViewManager.vue:72-77）
   创建需要 `operator` 角色，APP 要先判当前账号权限再决定按钮显隐。

**面板侧唯一值得顺手补的（不属于本 issue 必需）**：`/tasks/views` 这 5 条路由**没有写进面板内置 API 文档**（`web/src/views/api-docs/apiData.ts` grep `/tasks/views` 零命中），APP 开发者从文档页里看不到它。要补的话就在 apiData.ts 的 tasks 分组里加 5 条。

## risks

1. **本调查的最大不确定性**：issue 原文只说「网页建的分组，手机不会显示」，没指名是「视图」还是「任务分组标签」。我判定为**视图**的依据是：(a) label 型分组 APP 已经在读（task.dart:4/108），不可能不显示；(b) issue 后半句「通过命令、订阅含关键字等规则」逐字对应 TaskView 的 filter 字段与运算符。但仍存在另一种可能：用户遇到的是 APP 缓存/刷新问题导致 label 分组没更新 —— 若如此，方向就完全错了。建议在 issue 下回一句确认。

2. **`tasks.labels` 是 `size:256` 的单列逗号串**（model/task.go:38）。分组名 + 订阅标签 + 全部自定义标签共挤这 256 字节；分组名里**不能含逗号**（GetLabels 按逗号裸切，:213-218），也不能含前导空格以外的怪字符。若 APP 要提供分组重命名，得考虑超长截断。

3. **视图筛选走内存全表路径**：带 `filters`/`sort_rules` 时后端会 `query.Find(&tasks)` 把全部任务读进内存再过滤分页（task_query.go:103-131），与不带参数的 SQL 分页快路径（:72-101）性能不是一个量级。任务量大的实例，手机端频繁切 tab 会明显加重服务端负担。

4. **CreateView / UpdateView 不校验 filters/sort_rules 的 JSON 合法性**（task_view.go:20-52, 62-102），只在读的时候静默降级（task_query.go:344-346 解析失败 → 当空 → **不筛选，返回全部任务**）。APP 若写坏 JSON，用户会看到「点了这个视图却出来全部任务」而不是报错。APP 端务必自己保证序列化正确。

5. **UpdateView 的空串陷阱**：`name/filters/sort_rules` 传 `""` 等于「不修改」（:77-85），想清空规则必须传 `"[]"`。

6. **`task_views` 表没有 user_id，是全局共享的**（model/task_view.go:7 注释）。多用户实例下，手机上改一个视图会影响所有人。若 APP 提供编辑能力，UI 上应有提示。

7. **状态字段筛选的 value 有三种等价写法**（数字 / `禁用中` 类 / `已禁用` 类，task_query.go:428-433, 491-515）。APP 若自建规则编辑器，必须用 web 那套固定值 `1/0/2/0.5`（ViewManager.vue:72-77），别自己发明中文串。

8. **`PUT /tasks/batch/add-labels` 用不了**：它主动丢弃 `分组:` 前缀（task_labels.go:66, 107-110），APP 若想批量改分组只能逐个 `PUT /tasks/:id`。

9. **「全部」tab 的隐藏偏好只在 web localStorage**（`dd:tasks:view_all_hidden`，ViewManager.vue:32），APP 无法读到也不该猜。若用户期望这个也同步，那才需要服务端新增存储 —— 但这不在 issue 诉求里。

## openQuestions

- issue #4 的「网页建的分组」到底指任务视图（TaskView tab）还是任务分组标签（`分组:` label）？证据强烈倾向视图（label 那套 APP 已在读，见 task.dart:4/108），但用户没明说。建议在 issue 下回一句确认，避免做错方向。
- APP 只需要**只读消费**视图（拿来筛选任务），还是也要能在手机上**创建/编辑/删除/拖拽排序**视图？后者需要 operator 角色，且要在 APP 里做一整套规则编辑器 UI。工作量差一个数量级。
- 视图筛选与 APP 现有的 `分组:` 分桶是并存（先按视图筛、再按分组分桶）还是二选一（视图 tab 取代分组头）？这决定 task_list_rows.dart 要不要改。
- APP 本地的分组折叠态与拖拽顺序（SharedPreferences `tasks.collapsed_groups` / `tasks.group_order`，task_list_page.dart:60/63）是否也要求跨端同步？面板 web 侧根本没有「分组顺序」这个概念（分组只是 chip），所以这项**没有任何服务端载体**，真要做才需要新增表/字段。
- 是否要顺手把 `/tasks/views` 这 5 条路由补进面板内置 API 文档 apiData.ts？目前文档页完全查不到它（grep 零命中），第三方/APP 开发者只能靠读源码。
- 面板 web 侧要不要反过来也支持「按分组折叠渲染任务列表」，与 APP 的呈现对齐？目前 web 只把分组渲染成一枚 chip（index.vue:1238-1248），两端的分组体验其实是不对称的 —— 这可能才是用户「感觉不同步」的另一半来源。