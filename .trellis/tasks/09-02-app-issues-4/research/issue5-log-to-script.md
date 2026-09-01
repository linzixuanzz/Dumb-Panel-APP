# agent-2

## summary

「日志详情页」= `log_stream_page.dart` 的 `LogStreamPage`（路由 `/logs/:id/stream`），不是 log_list_page 里的某个内联视图 —— 后者只有列表，点击即 `context.push('/logs/${log.id}/stream')`。脚本编辑页这一侧完全就绪：`/scripts/view` 路由已经接受一个「文件路径」字符串作为 `state.extra`，`ScriptViewPage` 自己会 `loadContent`，所以可以直接深链，不需要新增路由。真正的**阻塞点在数据**：`GET /api/logs/:id` 的返回体（`model.TaskLog.ToDict()`）里**没有 `command` 字段**，日志正文里也没有脚本路径（头部只有 `=== 开始执行 [时间] ===`），`log_path` 只是 `task_<id>_<任务名>/<时间戳>.log`。更糟的是**面板根本没有 `GET /api/tasks/:id` 这条路由**，所以拿不到单个任务的 command。命令解析器倒是现成的：APP 里已有 `_extractScriptPathFromCommand`（私有、无测试、只被删除任务对话框用），面板 Go 和 Web 各有一份同语义实现。面板 Web 的「从命令跳脚本」做在**任务页**（`/scripts?file=<path>`），日志页并没有这个功能，所以 issue #5 是要求 APP 超出 Web 现状，而不是对齐。

## currentState

**导航链路（已确认）**

日志列表 `LogListPage` → `_LogItem.onView` → `context.push('/logs/${log.id}/stream')`（log_list_page.dart:717-723）→ go_router 路由 `/logs/:id/stream`（app_router.dart:152-157，挂在 `_rootNavigatorKey` 上，全屏盖住底部导航壳）→ `LogStreamPage(logId: ...)`（log_stream_page.dart:16-19）。

第二个入口：任务列表点卡片 → `_openLatestLog`（task_list_page.dart:331-351）→ 拉 `/tasks/:id/latest-log` → 同样 `context.push('/logs/${latestLog.id}/stream')`（:347）。任务运行中时改走 `/tasks/:id/live-logs` → `TaskLiveLogPage`（task_list_page.dart:2537-2541），那是另一个页面。

log_list_page.dart 里没有任何详情视图；它的注释也把 LogStreamPage 称作「详情」（:787-789、:829），raw_log_download.dart:12 更直接写「APP 的日志详情页」。

**日志详情页当前展示的内容（log_stream_page.dart build，:291-423）**

- AppBar 标题：`日志 #<logId>`（:302-305），纯 ID，连任务名都没显示
- 状态 Chip：`_status`（:309-329）
- 复制全部（:330-348）／下载原始日志（:351-365）／自动滚动开关（:366-375）
- body：ANSI 解析后的日志正文（:401-417）

没有任务名、没有命令、没有开始/结束时间、没有耗时字段。`_loadLog`（:63-120）虽然解析出了完整 `TaskLog`，但只留下了 `_taskId`、`isRunning`、`statusText`、`logPath` 四个信息。

**根因：定位脚本所需的信息不存在**

`GET /api/logs/:id` → `LogHandler.Detail`（server/handler/log.go:316-337）→ `taskLog.ToDict()`（server/model/task_log.go:32-55）返回：`id / task_id / content / status / duration / log_path / started_at / ended_at / created_at / updated_at`，Preload 到 Task 时额外补 `task_name / task_type / labels / task{task_type,labels}`。**没有 command**。APP 侧 `TaskLog.fromJson`（shared/models/task_log.dart:53-68）也就没有这个字段。

想用 `task_id` 反查也走不通：`server/handler/task_routes.go:18-61` 全表里**没有 `tasks.GET("/:id")`**，只有 `/:id/latest-log`、`/:id/live-logs`、`/:id/log-files`、`/:id/stats`。APP 的 `ApiEndpoints.taskById`（api_endpoints.dart:41）只被 PUT/DELETE 用（task_form_page.dart:549、task_provider.dart:138/183/238）。

## keyFiles

- `D:\GitHub\Dumb Panel\android-app\lib\features\logs\views\log_stream_page.dart` :16-19, 63-120, 290-377 — 日志详情页本体（issue #5 的按钮要加在这里）。当前是纯 StatefulWidget，未 import go_router / riverpod；_loadLog 拿到 log 后只留 _taskId；AppBar actions 已有 4 项且带「会撑到溢出」注释
- `D:\GitHub\Dumb Panel\android-app\lib\features\logs\views\log_list_page.dart` :717-723 — 日志列表 → 详情的唯一导航点：context.push('/logs/${log.id}/stream')
- `D:\GitHub\Dumb Panel\android-app\lib\core\router\app_router.dart` :152-157, 184-191 — go_router 路由表。/logs/:id/stream 用 pathParameters；/scripts/view 用 state.extra as String? ?? '' —— 可复用的深链入口
- `D:\GitHub\Dumb Panel\android-app\lib\features\scripts\views\script_list_page.dart` :500-506, 239-246, 1749-1777, 2133-2226 — _openScript 是现成打开方式；ScriptViewPage 构造只要 path 且自己 loadContent（可直接深链）；⚠️ loadContent 失败时把 content 设成字面量「加载失败」，无错误态
- `D:\GitHub\Dumb Panel\android-app\lib\features\tasks\views\task_list_page.dart` :2393-2453, 2455-2490, 1549 — 已有的命令→脚本路径解析器 _extractScriptPathFromCommand + _splitCommandTokens。私有 top-level，唯一调用点是删除任务对话框，无单测
- `D:\GitHub\Dumb Panel\android-app\lib\shared\models\task_log.dart` :4-68 — TaskLog 模型：无 command 字段。要走面板扩字段方案需在这里加
- `D:\GitHub\呆呆面板开发\server\model\task_log.go` :32-55 — 日志详情返回体的唯一真源 ToDict()。缺 command —— 这是整个 issue 的卡点
- `D:\GitHub\呆呆面板开发\server\handler\task_routes.go` :18-61 — 证据：面板没有 GET /api/tasks/:id，无法按 id 取单个任务的 command
- `D:\GitHub\呆呆面板开发\server\service\task_executor.go` :1214-1258 — 面板 Go 版命令解析 extractTaskScriptPath（语义与 APP 版略有差异：desi 归到解释器组、支持 python3.10/3.11/3.12）
- `D:\GitHub\呆呆面板开发\web\src\views\tasks\taskCommand.ts` :52-108 — Web 版解析 extractTaskCommandScriptPath / splitTaskCommandDisplay（支持 -- 终止符、未知入口命令时回退取第一个像脚本的 token）
- `D:\GitHub\呆呆面板开发\web\src\views\tasks\index.vue` :410-412, 1101-1107, 1259-1265 — Web 唯一的「跳脚本」实现，在任务页不在日志页：router.push({path:'/scripts', query:{file: path}})
- `D:\GitHub\呆呆面板开发\web\src\views\scripts\useScriptWorkspace.ts` :39-55 — Web 侧 ?file= 深链消费端：openFile(param) 后 router.replace('/scripts') 清掉 query
- `D:\GitHub\呆呆面板开发\server\service\log_manager.go` :104-111, 255-279, 281-316 — log_path 生成逻辑，证明它不含脚本路径：目录名 = task_<id>_<sanitize(任务名 优先)>

## detailedFindings

## 1. 「日志详情页」到底是哪个

**是 `log_stream_page.dart` 的 `LogStreamPage`。** log_list_page.dart 里没有任何详情视图（`showDialog` 四处全是删除/清理确认框）。

链路：
- `log_list_page.dart:717-723` — `onView: () { if (_selectionMode) {...} else { context.push('/logs/${log.id}/stream'); } }`
- `app_router.dart:152-157` — `GoRoute(path: '/logs/:id/stream', parentNavigatorKey: _rootNavigatorKey, builder: (_, state) => LogStreamPage(logId: int.parse(state.pathParameters['id']!)))`
- `log_stream_page.dart:16-19` — `class LogStreamPage { final int logId; const LogStreamPage({super.key, required this.logId}); }`

注意参数只有 `logId`，**没有传 task 对象**，这是后面所有麻烦的起点。

第二入口（同一个页面）：`task_list_page.dart:331-351` `_openLatestLog` → `:347` `context.push('/logs/${latestLog.id}/stream')`。任务在跑时改走 `:353-355` `_openLiveLog` → `/tasks/:id/live-logs` → `TaskLiveLogPage`（`task_list_page.dart:2537-2541`，`{required taskId, taskName}`）。**如果 issue 也想覆盖「运行中日志」，那是第二个页面，但它反而更好办 —— 它手里已经有 taskId。**

## 2. 详情页现有字段 / 能否定位脚本 —— **不能，缺 command**

页面渲染的东西（`log_stream_page.dart:291-423`）：标题 `日志 #<logId>`（:302-305）、状态 Chip（:309-329）、复制全部（:330-348）、下载原始日志（:351-365）、自动滚动（:366-375）、ANSI 正文（:401-417）。任务名/命令/时间一个都没显示。

`_loadLog`（:63-120）请求 `ApiEndpoints.logById(widget.logId)` = `GET /api/logs/:id`（api_endpoints.dart:68）。服务端 `LogHandler.Detail`（server/handler/log.go:316-337）：

```go
database.DB.Preload("Task").First(&taskLog, logID)
result := taskLog.ToDict()
```

`ToDict()`（server/model/task_log.go:32-55）：
```go
result := map[string]interface{}{
    "id","task_id","content","status","duration","log_path",
    "started_at","ended_at","created_at","updated_at",
}
if l.Task != nil {
    result["task_name"] = l.Task.Name
    result["task_type"] = l.Task.GetTaskType()
    result["labels"]    = l.Task.GetLabels()
    result["task"]      = map[string]any{"task_type":..., "labels":...}
}
```
**`command` 不在里面。** APP 的 `TaskLog.fromJson`（shared/models/task_log.dart:53-68）也只解析上面这些 + `task_name`。

三条备选取数路径全部堵死：

**(a) `log_path` 里没有脚本路径。** `GetRelativeLogPathForTask`（server/service/log_manager.go:104-111）→ `getTaskLogDirName`（:255-257）→ `resolveTaskLogDirLabel`（:268-279）优先取 `task.Name`，**只有任务名为空时**才退到 `filepath.Base(extractTaskScriptPath(task.Command))` —— 而且只是 basename。真实样例（server/service/log_manager_test.go:22/43/63）：
- 常态 `task_7_签到任务/2026-08-04-10-00-00-000.log`
- 极端回退 `task_8_my_job.py/...` —— 只有文件名，重建不出 `dir/sub/my_job.py`

`sanitizeTaskLogDirLabel`（:281-307）还会把 `/ \ : * ? " < > |` 和空白全替成 `_`，路径分隔符本身就被抹掉了。

**(b) 日志正文里没有命令行。** 执行器写入的头是 `=== 开始执行 [2006-01-02 15:04:05] ===`（server/service/task_executor.go:447，scheduler.go:323 同）。全仓 grep「工作目录 / 脚本：/ 执行命令」在 server 侧无任何写进任务日志的命中（`web/src/demo/sse.ts:304` 那条 `## 工作目录：/opt/daidai/scripts` 是 demo 假数据，不是真日志）。

**(c) 拿 task_id 反查任务 —— 面板没有这条路由。** `server/handler/task_routes.go:18-61` 完整列出了 tasks 组的所有路由，GET 只有 `""`、`/notification-channels`、`/:id/latest-log`、`/:id/live-logs`、`/:id/log-files*`、`/:id/stats`、`/export`、`/cron/templates`、`/views`。**没有 `tasks.GET("/:id")`。** APP 的 `ApiEndpoints.taskById`（api_endpoints.dart:41）只用于 PUT/DELETE。

唯一可用的迂回是任务列表：`GET /api/tasks` 支持 `keyword`（`name LIKE ? OR command LIKE ?`，task_query.go:39/58-61）和 `all=1`（:46-47/81-88，服务端上限 5000）。`filters` 参数支持的字段是 `command/name/cron_expression/status/labels/subscription`（task_query.go:411-441），**不含 id**，所以只能「按任务名搜出来再按 id 过滤」。角色门槛是 `viewer`（task_routes.go:20），与日志详情同级，不会新增权限问题。

**command 的真实格式**（APP 自己生成的样例，script_list_page.dart:565 与 :1801）：
```dart
TaskFormPrefill(name: taskName, command: 'task $path');   // 例：task jd/sign.py
```
Task 模型有 `final String command`（shared/models/task.dart:8，fromJson :136）。

## 3. 脚本编辑页入口 —— **已经支持按路径深链，无需新增路由**

- `ScriptListPage._openScript`（script_list_page.dart:500-506）：
  ```dart
  await ref.read(scriptProvider.notifier).loadContent(path);
  context.push('/scripts/view', extra: path);
  ```
- 路由 `app_router.dart:184-191`：`path: '/scripts/view'`，`final path = state.extra as String? ?? ''`，`return ScriptViewPage(path: path);`
- `ScriptViewPage`（script_list_page.dart:1749-1752）：`const ScriptViewPage({super.key, required this.path})`；`initState`（:1768-1777）自己 `await ref.read(scriptProvider.notifier).loadContent(widget.path)`。

**结论：从日志详情页直接 `context.push('/scripts/view', extra: scriptPath)` 就能打开编辑器，不必经过 ScriptListPage。** `_openScript` 里的预加载只是让内容早一帧出现，不是必需前置。

编辑器功能齐全：标题取 basename（:2149）、查找（:2152-2156）、加入任务/格式化/版本历史/调试运行菜单（:2158-2194）、编辑↔预览切换（:2207-2213）、保存（:2214-2224）、body 顶部显示完整路径（:2246-2252）。

**⚠️ 一个真实的降级陷阱**：`ScriptNotifier.loadContent` 的 catch 分支（script_list_page.dart:239-246）把失败写成
```dart
state = state.copyWith(selectedPath: path, content: '加载失败', isBinary: false, loadingContent: false);
```
没有错误标志位。于是脚本被删/被移动/无权限时，编辑器会打开并把「加载失败」四个字当成脚本内容显示；此时用户点保存，就会 `PUT /api/scripts/content` 把这四个字写成文件（`saveContent` :249-265）。从日志页跳过来触发这个的概率远高于从脚本树点开（树里的路径必然存在）。

## 4. 路由表与传参约定

**go_router**（`app_router.dart:3` import、`:47-50` `routerProvider` 返回 `GoRouter`）。约定：

- **id 走 pathParameters**：`/logs/:id/stream`（:153-156）、`/tasks/:id/live-logs`（:145-150）、`/deps/:id/log-stream`（:203-206）
- **对象/字符串走 `state.extra`**：`/tasks/new` extra=`TaskFormPrefill`（:128-135）、`/tasks/edit` extra=`Task`（:136-143）、`/subscriptions/:id/logs` extra=`String?` 任务名（:171-178）、`/scripts/view` extra=`String` 路径（:184-191）
- **query 用得极少**：只有 `/server-config` 的 `?manual=1` / `?manage=1`（:62-63、:92）
- **壳内 vs 壳外**：5 个底部 tab（dashboard/tasks/logs/envs/more）在 `ShellRoute` 里用 `NoTransitionPage`（:96-126）；`/logs/:id/stream`、`/scripts`、`/scripts/view` 都显式 `parentNavigatorKey: _rootNavigatorKey`（:154、:181、:186），全屏推栈。所以「日志详情 → 脚本编辑」是同一个 root navigator 上的第二层 push，返回栈天然正确。
- **redirect**（:54-86）只管登录态，没有角色守卫，新增跳转不需要改守卫。

**注意事项**：`state.extra` 不可序列化，进程重启/系统深链恢复时会变成 `''`（:188 的 `?? ''` 兜底），`ScriptViewPage(path: '')` 会去请求 `?path=` 空串。本 issue 是应用内 push，不受影响；但如果将来想让这个跳转可分享/可恢复，就得改成 query 参数（对齐 Web 的 `?file=`）。

**新增 vs 复用**：**复用 `/scripts/view` 即可，不要新增路由。**

## 5. 已有的解析工具 & Web 对齐情况

**APP 已有一份**：`task_list_page.dart:2393-2453` `String? _extractScriptPathFromCommand(String command)` + `:2455-2490` `List<String> _splitCommandTokens(String)`。
- 支持入口：`task` / `desi`（跳过 `-m <arg>` 与 `-l`，:2423-2439）、`python` `python3` `node` `ts-node` `bash` `go`（:2440-2449）
- 扩展名白名单 `.py .js .ts .sh .go`（:2404-2411）
- `joinCandidate`（:2413-2421）从长到短拼接 token，支持带空格的路径
- tokenizer 处理单双引号（:2471-2474）
- **私有 top-level 函数**（Dart 里 library-private，跨文件不可见），**唯一调用点是 `_confirmDelete` 的「同时删除关联脚本」勾选框**（:1549、:1561-1573），**没有任何单测**（test/ 下无 task command 相关文件）

**面板 Go 版**：`server/service/task_executor.go:1214-1258` `extractTaskScriptPath`。差异：`desi` 被归进解释器组（:1244），额外支持 `python3.10/3.11/3.12`，用 `splitTaskShellAndScriptArgs` 切分（:1233）。

**面板 Web 版**：`web/src/views/tasks/taskCommand.ts:52-82` `extractTaskCommandScriptPath` + `:84-108` `splitTaskCommandDisplay`。差异：识别 `--` 终止符（:65）、多了 `nodejs`/`sh`（:77）、**未知入口命令时回退到「整条命令里第一个像脚本的 token」**（:81），比 APP 版宽松。

**Web 里的「跳脚本」实现在任务页，不在日志页**：
- `web/src/views/tasks/index.vue:410-412` `navigateToScript(path)` → `router.push({ path: '/scripts', query: { file: path } })`
- 渲染成命令文本中可点的一段：移动端卡片 `:1101-1107`、桌面表格 `:1259-1265`（`splitTaskCommandDisplay` 把命令切成 before/script/after 三段，只有 script 段可点）
- 消费端 `web/src/views/scripts/useScriptWorkspace.ts:39-55`：`watch(() => route.query.file, ...)` → `browser.openFile(fileParam)` → `router.replace({path:'/scripts'})` 清掉 query
- **`web/src/views/logs/index.vue` 全文 grep `script|脚本` 只命中 `<script setup>`（:1）、`</script>`（:708）和无关的 el-empty 文案 —— Web 日志页没有这个功能。**

顺带：**APP 的任务详情弹层也没有 Web 那个跳转** —— `task_list_page.dart:2663-2674` 的「执行命令」是纯 `SelectableText(task.command)`，不可点。这是一个比 issue #5 便宜得多的对齐项（那里手上就有完整 Task 对象，零额外请求）。

## proposedFix

## 最小可行方案（四步）

### 第 1 步：把解析器提到 shared（纯重构，零行为变化）

把 `task_list_page.dart:2393-2453` 的 `_extractScriptPathFromCommand` 和 `:2455-2490` 的 `_splitCommandTokens` 整体搬到新文件 `lib/shared/utils/task_command.dart`，改名为公开的 `String? extractScriptPathFromCommand(String command)`；`task_list_page.dart:1549` 改为 import 调用。同时补 `test/shared/utils/task_command_test.dart`（与 `duration_utils_test.dart`、`sse_replay_buffer_test.dart` 同规格），至少覆盖：`task jd/sign.py`、`task -m 5 -l a/b.js`、`python3 x/y.py --flag`、带引号带空格的路径、`curl https://x`（应返回 null）。

### 第 2 步：把 command 送进日志详情页（二选一，建议 A 主 B 备）

**方案 A（推荐，跨仓一行）**：在 `server/model/task_log.go:45-53` 的 `if l.Task != nil` 块里加 `result["command"] = l.Task.Command`；APP 侧 `shared/models/task_log.dart` 加 `final String? command;` 并在 `fromJson`（:53-68）解析 `json['command']?.toString()`。零额外请求，且日志**列表**接口（同样走 ToDict）也顺带拿到了。**必须按可空处理** —— 面板版本旧于此改动时该字段就是 null，APP 不能假定存在。

**方案 B（纯 APP，兼容现网面板）**：在用户**点击按钮时**（不是页面加载时）懒查 `GET /api/tasks`，`queryParameters: {'all': 1, 'keyword': log.taskName}`，从 `extractPaginated` 结果里挑 `id == _taskId` 的那条，取 `.command`。角色门槛与日志详情同为 viewer（task_routes.go:20），不引入新权限问题。可以先读 `ref.read(taskProvider).tasks` 的内存缓存（`task_provider.dart` 的 provider 非 autoDispose，用户来过任务页就已有数据），命中就跳过请求。

**建议**：A 落地后，APP 里写成 `log.command ?? await _lookupCommandFromTaskList()`，两条路都留着。

### 第 3 步：按钮位置 —— 不要再加第 5 个 AppBar icon

`log_stream_page.dart:300-301` 已有明确注释：actions 现在 4 项（状态 chip + 复制 + 下载 + 自动滚动），窄屏上标题已经被压到要 ellipsis；:186-188 也记录过一次 actions 撑溢出的教训。

建议把「复制全部 / 下载原始日志 / **编辑对应脚本**」折进一个 `PopupMenuButton`，AppBar 只留 状态 chip + 自动滚动 + 溢出菜单，总数反而从 4 降到 3。菜单项文案「编辑对应脚本」，icon `Icons.code`（与 more_page.dart:206 的脚本管理入口同图标）。

### 第 4 步：点击处理与降级阶梯

`LogStreamPage` 需要 `import 'package:go_router/go_router.dart';`；若采用方案 B 或要做角色门禁，还需改成 `ConsumerStatefulWidget`（目前是纯 `StatefulWidget`，`log_stream_page.dart:1-14` 既没有 go_router 也没有 riverpod）。

```
成功：context.push('/scripts/view', extra: scriptPath);
```

降级（从上到下逐级）：

1. **日志详情还没加载完**（`_taskId == null`）→ 菜单项直接不出现。照抄 `_hasRawFile != null` 的门禁写法（:349-351 及其注释：「在那之前既不知道有没有…也说不清楚点了会发生什么」）。
2. **拿不到 command**（面板旧版 + 列表兜底也失败）→ 菜单项保留，点击 `AppSnack.warn(context, '未能获取任务命令，无法定位脚本')`。
3. **解析返回 null**（`curl`、内联 shell、未知入口命令）→ `AppSnack.warn(context, '该任务不是脚本任务，无法跳转')`；可再给一个「打开脚本管理」的兜底跳到 `/scripts`。
4. **角色不足**：`/api/scripts/*` 要求 operator（server/handler/script_routes.go:10），而日志详情只要 viewer。用 `authProvider` 的 `user.isOperator`（shared/models/user.dart:23）门禁掉这个菜单项 —— 现成先例：more_page.dart:198 用 `user.isAdmin` 把整个「系统管理」（含脚本管理入口）藏起来。
5. **脚本已删/已移动**：这是必须一并修的 —— 见下面「风险」第 1 条。

不采用 AppSnack.warn 直接静默失败的写法：本页 `_downloadRawLog`（:203-213）已经确立了「点了就直接告诉他为什么」的交互基调，照它做即可。

## risks

**1. 「加载失败」被当成脚本内容保存（最需要先修的）**
`ScriptNotifier.loadContent` 的 catch（script_list_page.dart:239-246）把失败写成 `content: '加载失败'` 且不设错误位。从脚本树点开时路径必然存在，所以这条路径一直没被踩到；但从日志跳过来，脚本被删/被改名/权限不足都会走到这里 —— 用户看到一个内容是「加载失败」的可编辑缓冲区，一按保存就 `PUT /api/scripts/content` 把它写成真文件（`saveContent` :249-265），**属于静默数据破坏**。建议在这个 issue 里顺手给 `ScriptState` 加 `contentError`，让 `ScriptViewPage` 渲染 `AppErrorView` 而不是可编辑文本。

**2. 三份解析器已经不一致**
APP（task_list_page.dart:2423-2449）把 `desi` 和 `task` 归一组走 `-m/-l` 跳过；Go（task_executor.go:1244）把 `desi` 归进解释器组；Web（taskCommand.ts:77-81）支持 `--` 终止符、多了 `nodejs`/`sh`，并且未知入口命令时回退取第一个像脚本的 token。同一条边角命令三边可能给出三个答案。APP 按钮用 APP 版解析，理论上会和面板真正执行的脚本不一致。本次不建议统一（超出 issue 范围），但新加的单测应把这个差异写成注释锁住现状。

**3. 方案 A 的跨仓版本耦合**
往 `ToDict()` 加字段意味着 APP 的新功能只在新面板上生效。APP v1.3.3 目前没有「最低面板版本」的声明机制（`ApiEndpoints` 里没有 version gate 的先例），所以必须靠字段可空 + 方案 B 兜底来降级，不能出现「按钮点了什么都不发生」。

**4. 方案 B 的请求成本**
`GET /api/tasks?all=1` 是一次性全量（task_query.go:81-88，上限 5000 条），任务多的面板上这一发请求不小。务必带 `keyword=<task_name>` 收窄，且只在点击时触发，绝不在 `_loadLog` 里预取 —— 日志详情页是高频入口，页面加载多打一发全量列表会明显拖慢首屏。

**5. AppBar 溢出**
如果偷懒直接加第 5 个 IconButton 而不折叠成菜单，窄屏上标题会被挤没，重演 :186-188 记录过的那次问题。

**6. `_extractScriptPathFromCommand` 移动后的回归面**
它当前唯一消费者是「删除任务时同时删除关联脚本」的勾选框（task_list_page.dart:1549-1573）—— 那是个**破坏性操作**的判定依据。重构时如果不小心改了行为（哪怕只是扩展名列表顺序），会影响删除逻辑。必须是纯搬移，行为零改动，并让新单测先锁住现有行为。

## openQuestions

- issue 正文为空：「日志详情页」是否只指 LogStreamPage（/logs/:id/stream），还是也包括运行中日志页 TaskLiveLogPage（/tasks/:id/live-logs，task_list_page.dart:2537）？后者手上已经有 taskId + taskName，但同样没有 command，需要同一套取数逻辑。
- 是否允许为这个 APP issue 改面板（server/model/task_log.go 加 command 字段）？如果只能改 APP，就只能走「任务列表 keyword 搜索 + 按 id 过滤」的迂回方案。
- viewer 角色的用户能看日志（logs 要 viewer）但不能读脚本（scripts 要 operator，script_routes.go:10）。这个按钮对 viewer 应该整个隐藏，还是显示后点击给出「权限不足」提示？APP 现有做法（more_page.dart:198 用 isAdmin 隐藏整块）偏向隐藏，但那用的是 isAdmin 而非 isOperator，两边口径本来就不一致。
- 脚本已被删除/移动时，除了修 loadContent 的错误态，是否还需要更友好的兜底 —— 比如跳到 /scripts 并用文件名预填搜索框（ScriptNotifier.setKeyword 现成，script_list_page.dart:185-190）？
- 命令不是脚本形态时（curl、内联 shell、ddp 自定义命令），是仅弹一条提示，还是给一个「打开脚本管理」的次级入口？
- 要不要在同一个 PR 里补上 APP 任务详情弹层的「命令中脚本可点」（task_list_page.dart:2663-2674），以对齐 Web 的 tasks/index.vue:1259-1265？那里零额外请求，是本次改动的顺手收益，但会扩大 issue #5 的范围。