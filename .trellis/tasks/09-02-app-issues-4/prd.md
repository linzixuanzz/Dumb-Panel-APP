# APP 开放 issue 四条一次性收口

> 来源：`linzixuanzz/Dumb-Panel-APP` 全部 4 条 open issue（#2 #4 #5 #6）
> 基线：APP v1.3.3（`flutter analyze` 7 info、`flutter test` 291 全过，2026-09-01 实测）

## 1. 背景与目标

四条 issue 都由用户提出，均已完成只读取证（6 个调查 agent，跨 APP 与面板两仓）。
本任务把四条一次性做完，并在 issue 下逐条回复。

---

## 2. issue #2 —— 日志背景颜色失效

**用户原话**：app1.2.6+面板2.3.8，深色模式下输出日志背景是白的，就算设 `#000000` 纯黑也是白的。

### 根因（两个缺陷叠加）

- **缺陷 A（v1.3.3 仍在）**：`lib/shared/utils/log_background.dart:85`
  `final background = configuredColor ?? AppColors.termBg;`，而 `AppColors.termBg = Colors.white`
  （`app_theme.dart:74`）。函数签名里没有 `Brightness`，**物理上不知道当前是不是深色模式**。
  面板 `log_background_color` 的出厂默认自 v2.2.4 起就是空串
  （`server/model/system_config_registry.go:179`，注册说明写的是「留空跟随当前主题」），
  于是 APP 深色模式恒定白底。
  `AppColors.termBgDark = #000000` 定义了却**全仓零引用**——本来打算按主题分叉，没接上。
  面板 Web 侧实现是对的：留空回落 `#0f172a` / `#f8fafc`（`web/src/utils/panelAppearance.ts:33-34,120-122`）。
- **缺陷 B（v1.3.0 已自然修好）**：APP v1.2.6 系统设置页里标着「日志背景色」的输入框
  绑的是 `editor_background_color`（v1.2.6 `system_settings_page.dart:104/509/832`），
  用户填的 `#000000` 写进了脚本编辑器背景。v1.3.0 的 `64ddf75`（系统设置改 schema 驱动）已删掉该硬编码。

### 交付

1. `AppColors.termBg` 删除；新增 `termBgLight = #F8FAFC`、`termBgDark 改为 #0F172A`（对齐面板 Web）。
2. `resolveLogSurfaceTheme(Color?, {required Brightness themeBrightness})`——
   **必填**参数，让 7 个调用点全部编译报错，杜绝漏改。
3. 7 个调用点全部传 `Theme.of(context).brightness`（APP 是 `ThemeMode.system`）：
   `log_stream_page.dart:292`、`task_list_page.dart:3002`、`script_list_page.dart:2713`、
   `panel_log_page.dart:97`、`subscription_list_page.dart:1642/1985`、`dep_list_page.dart:1640`。
4. 前景色推导（`:90-92`）**不动**——面板 v3.0.10 修 issue #104 时踩过「改成主题文字色」的坑。
5. 合并 `script_list_page.dart:1917-1962` 那份与 `parseColorSetting` 逐字相同的私有副本。
6. 新增 `test/shared/utils/log_background_test.dart`（当前零覆盖）。

### 不做

面板侧零改动——接口、字段、默认值、鉴权全部正确，是纯 APP 端缺陷。

---

## 3. issue #4 —— 手机分组同步网页分组

**用户原话**：同步分组和规则……网页建的分组，手机不会显示，手机也没办法通过命令、订阅含关键字等规则进行分组。

### 取证结论：两句话是两件事，结论相反

- **第一句不成立**：标签式分组（`labels` 里的 `分组:` 前缀）APP 与 Web 用的是**同一套服务端数据**
  （APP `task.dart:4`，Web `taskLabels.ts:3`），v1.3.3 本来就同步，且 APP 的分组能力比 Web 更强
  （Web 只把分组渲染成一枚 chip，APP 有分组头 / 折叠 / 拖拽排序）。
  用户大概率把 Web 任务页顶部那排**视图 tab** 当成了「分组」。
- **第二句是真缺口**：面板另有一套 APP 零实现的「任务视图 TaskView」——
  服务端 `task_views` 表（`server/model/task_view.go:5-21`）+ 5 条路由
  （`server/handler/task_routes.go:56-60`）+ `GET /tasks?filters=&sort_rules=` 规则筛选。
  用户说的「命令、订阅含关键字」逐字对应 filter 字段 `command`/`subscription` + 操作符 `contains`。

### 交付（**面板侧零改动**，数据与接口都已就位）

1. `api_endpoints.dart` 补 3 条：`taskViews` / `taskViewById(id)` / `taskViewsReorder`。
2. 新建 `lib/shared/models/task_view.dart`：`TaskViewFilter` / `TaskViewSortRule` / `TaskView`。
   ⚠️ `filters` 与 `sort_rules` 在传输层是**字符串化 JSON**，要解两层；`''` / 非法 JSON 一律降级成空列表
   （面板 `task_query.go:337-346` 自己也这么兜）。
3. 新建 `lib/features/tasks/providers/task_view_provider.dart`（`StateNotifier` + `{Dio? dio}` 可注入）。
   **老面板 404 / 权限 403 必须静默降级成「无视图」并隐藏入口，不许让任务页红掉。**
4. `task_provider.dart`：`TaskListState` 加 `filters` / `sortRules`，`load()` 的 query 补
   `filters` / `sort_rules`（`jsonEncode`），新增 `applyView(TaskView?)`。
5. `task_list_page.dart`：在 `:851-887` 那条「筛选态汇总条」里插视图选择器
   （形态照抄相邻的分组选择器 `:863-871` + `_showGroupPicker` `:612-673`）。
   **不新增常驻筛选行**——任务页纵向密度被专门优化过（`task_list_rows.dart:1-18` 的注释）。
   选中视图 id 持久化到 `ui_state_tasks.selected_view`。
6. 视图**增删改**（用户第二句要的就是「能建规则」）：字段/操作符/状态四张枚举表逐条照抄
   `ViewManager.vue:64-88`。`operator` 以下角色隐藏入口。
   ⚠️ `UpdateView` 传 `""` 等于「不修改」，清空规则必须传 `"[]"`（`task_view.go:77-85`）。
   ⚠️ 视图表**没有 user_id、全局共享**，UI 文案不许暗示「我的视图」。

### 顺手修的两个既有 bug

- **(a) 分组筛选 LIKE 串味**（`task_list_page.dart:669-671`）：`setLabelFilter(selected)` 传的是显示名，
  服务端做 `labels LIKE '%生产%'`，会把只挂普通标签「生产」的任务也捞回来。改传 `Task.toGroupLabel(selected)`，
  并在 `_restoreTaskUiState`（`:446-484`）对旧格式裸名做一次兼容归一。
- **(b) 编辑任务丢 `subscription:` 标签（数据丢失）**（`task_form_page.dart:160-162`）：
  用 `userLabelsForDisplay`（订阅 id 已被服务端换成显示名）播种编辑框，保存时整体覆写 →
  `subscription:3` 消失、任务脱离订阅托管。Web 用 `mergeTaskLabels` 显式保留 internalLabels，APP 没做。
  修法：`_labels` 改用原始 `labelList` 播种 + 新增 `_internalLabels` 原样透传；
  `subscription:` 提成 `Task.subscriptionLabelPrefix` 常量，判前缀先 trim（历史脏数据有前导空格）。

---

## 4. issue #5 —— 日志详情页加按钮跳脚本编辑页

**issue 正文为空，只有标题。**

### 取证结论

- 「日志详情页」= `log_stream_page.dart` 的 `LogStreamPage`（路由 `/logs/:id/stream`）。
- 脚本侧**已就绪**：`/scripts/view` 路由接受路径字符串作 `state.extra`，`ScriptViewPage` 自己
  `loadContent`，可直接深链，**不需要新增路由**。
- **卡点在数据**：`GET /api/logs/:id` 的返回体（`server/model/task_log.go:32-55` 的 `ToDict()`）
  **没有 `command`**；日志正文头部只有 `=== 开始执行 [时间] ===`；`log_path` 是
  `task_<id>_<任务名>/<时间戳>.log` 不含脚本路径；**面板也没有 `GET /api/tasks/:id` 路由**。

### 交付

1. **面板侧一行**：`server/model/task_log.go` 的 `if l.Task != nil` 块里加 `result["command"] = l.Task.Command`。
   日志列表接口同走 `ToDict()`，顺带受益。
2. **APP 侧兼容旧面板**：`TaskLog` 加可空 `command`；拿不到时**点击那一刻**才懒查
   `GET /api/tasks?all=1&keyword=<task_name>` 按 `id == taskId` 挑，命中内存缓存则跳过请求。
   **绝不在 `_loadLog` 里预取**——日志详情是高频入口。
3. 解析器提到 `lib/shared/utils/task_command.dart`（纯搬移，零行为变化）+ 补单测。
   ⚠️ 它当前唯一消费者是「删除任务时同时删除关联脚本」的**破坏性操作**判据（`task_list_page.dart:1549`）。
4. **按钮不加成第 5 个 AppBar icon**（`log_stream_page.dart:300-301` 已有「会撑到溢出」的注释）：
   把「复制全部 / 下载原始日志 / 编辑对应脚本」折进 `PopupMenuButton`，AppBar 从 4 项降到 3 项。
5. 降级阶梯：详情未加载完 → 菜单项不出现；拿不到 command → `AppSnack.warn`；
   解析返回 null（curl / 内联 shell）→ 提示「该任务不是脚本任务」；
   非 operator 角色 → 隐藏（`/api/scripts/*` 要 operator，日志只要 viewer）。

### 必须一并修（否则这个跳转会造成静默数据破坏）

`ScriptNotifier.loadContent` 的 catch（`script_list_page.dart:239-246`）把失败写成
`content: '加载失败'` 且**不设错误位**。从脚本树点开时路径必然存在所以从没踩到；
但从日志跳过来，脚本被删/改名/无权限都会走到这里——用户看到内容是「加载失败」的可编辑缓冲区，
一按保存就 `PUT /api/scripts/content` 把这四个字写成真文件。
修法：`ScriptState` 加 `contentError`，`ScriptViewPage` 渲染 `AppErrorView` 而不是可编辑文本。

---

## 5. issue #6 —— 脚本编辑页搜索优化显示

**用户原话 4 条**：(a) 编辑页左侧显示行号；(b) 高亮显示被搜索中对象；
(c) 点击下一个不进行检索跳转；(d) 搜索弹窗占屏幕比例过大、遮挡内容，建议像编辑器那样在编辑框外右上角显示。

### 取证结论

编辑器是**原生 `TextField`**（`script_list_page.dart:2269-2288`），pubspec 零 code editor 依赖。

- **(c) 根因已闭环**：`build()` 的 `:2136-2138` 每帧执行 `_contentController.text = state.content`，
  而 Flutter 的 `set text` 会把 selection 重置成 `TextSelection.collapsed(offset: -1)`
  （`editable_text.dart:276-282`，文档明写「不应在 build/layout/paint 阶段设置」）。
  `_findInContent` 自己的 `setState`（`:2038`）就触发了这次重建，刚设好的 selection 同帧被抹掉。
  下次点「下一个」时 `selection.isValid == false` → `:2010` 的 `start` 回落成 0 → `indexOf` 永远返回第一个命中。
  **只在查看模式复现**（`_editing == true` 时 `!_editing` 守卫挡住了赋值）。
- **(b) 同一根因**：collapsed 的 range 在 `_TextHighlightPainter.paint` 里被直接 return（`editable.dart:2905-2911`），
  那个「2 秒琥珀选区」一帧都留不住。
- **(d) 根因**：`showModalBottomSheet(isScrollControlled: true)` + `autofocus: true` +
  按钮不 pop（`:2057-2110`）——遮罩压暗编辑区、键盘顶高、整个 await 期间 sheet 常驻看不到跳转结果。
- **次要缺陷**：`_scrollToMatch`（`:1967-1988`）硬编码 `lineHeight = 13*1.5`、只数 `\n`、
  忽略软换行 / `contentPadding` / `textScaler` —— 长行脚本上系统性跳偏。

### 交付

1. **搜索游标独立**：加 `_matchOffsets` / `_currentMatchIndex` / `_matchQuery`，
   不再把游标寄存在 `controller.selection` 上；匹配区间计算抽成
   `lib/features/scripts/utils/script_search.dart` 的纯函数并单测。
2. **build 里不再赋值 controller**：改成内容真变了才同步，且走 `value.copyWith` 不走 `.text` setter。
   ⚠️ 回归面是 4 条路径：首次加载 / 保存后 / 格式化（`:1827` 直接写 controller）/ 版本回滚。
3. **双档高亮**：自定义 `TextEditingController` 覆写 `buildTextSpan`
   （`editable_text.dart:295-303` 是官方 override 钩子，`:5956` 确实会调），
   全部命中弱高亮 + 当前命中强高亮。**完全不动 TextField**，原生长按选择 / 系统菜单 / 选择手柄全保留
   ——这正是面板 Web 从 Monaco 换 CodeMirror 时刻意保住的东西。
   性能护栏：命中数上限 500，超出只高亮前 N 个并在 bar 上标 `500+`。
4. **行号栏**：保留软换行（不改成横向滚动，那是产品级行为变更）。
   用与 TextField **完全相同**的 `TextStyle` + **显式传同一个 `strutStyle`** + `MediaQuery.textScalerOf`
   建 `TextPainter`，`getOffsetForCaret` 拿每条逻辑行首字符的真实 y，
   换行的续行留空（与 VS Code 一致）。gutter 跟 `_contentScrollController` 同步平移。
   **同一份 TextPainter 缓存顺带把 `_scrollToMatch` 的偏移量算准**（一举两得）。
   配色对齐 web：行号 dark `#6B7280` / light `#94A3B8`（= `AppColors.slate400`）。
5. **find bar 替掉 modal sheet**：删掉 `_showFindSheet`，改成**编辑框外**、编辑器卡片**上方**的一条
   ≤44dp 常驻 bar，输入框占宽、`当前/总数` + ↑ ↓ ✕ 靠右（满足「编辑框外右上角」且不遮内容）。
   bar 底色用 `Theme.of(context).colorScheme.surface`**不能**用 `editorBackground`
   ——编辑器底色是用户可配项，跟着走会不可读（面板 `codeEditor.ts:257-258` 有明确注释）。
   删掉 `已定位到第 N 行` 的 snackbar，位置反馈交给计数 + 行号栏。
6. **拆文件**：`script_list_page.dart` 已 2868 行，新增 UI 放 `lib/features/scripts/widgets/`，
   纯函数放 `lib/features/scripts/utils/`。

---

## 6. 全局硬约束（来自 `.trellis/spec/frontend/`）

| 约束 | 内容 |
|---|---|
| analyze 基线 | 必须仍是 **7 issues**，且逐条比对 file:line（当前清单见 `research/baseline.md`）。⚠️ `script_list_page.dart:2756` 就在基线里，改那一带别把它复制成第二条 |
| test 基线 | ≥ **291 例**全过 |
| CI | **不查 analyze/test**，全靠本地自觉 |
| `copyWith` 陷阱 | `error` 字段是裸赋值「不传即清空」。`ScriptNotifier` 里还有约 10 处未修的同形状调用；新增方法必须写 `error: state.error` |
| 圆角 | 只有 `AppRadius` 五档，**禁止第六档、禁止字面量** |
| 颜色 | 禁止裸 `Color(0xFF...)`；新增语义色进 `AppColors` |
| 提示条 | 只用 `AppSnack`，失败必须 `.error`，没有 `info` |
| 可点区域 | `AppTapTarget.min = 44`，**加约束不加 padding** |
| 端点 | 只能进 `api_endpoints.dart`，带 query 必须 `Uri.encodeQueryComponent` |
| 解包 | `extractData` / `extractPaginated`；列表错误态用 `extractListErrorMessage` |
| Notifier | 写操作**不 try/catch**，异常抛给 UI；构造函数带 `{Dio? dio}` |
| import | `lib/` 内一律相对路径 |
| 文案/注释 | 全中文；注释只写「为什么」和踩过的坑 |
| 禁止 | 新增 `// ignore:`、`.autoDispose`、新测试依赖、在功能提交里改版本号 |

## 7. 完成判据

1. 4 条 issue 的诉求逐条落地（#6 的 a/b/c/d 四小条都要有对应改动）。
2. `flutter analyze` 仍 7 info（file:line 逐条比对）、`flutter test` ≥291 全过。
3. `docs/release-notes/NEXT.md` 按用户视角逐条追加。
4. 在 4 条 issue 下逐条回复（含 #2 给用户的自查提示、#4 第一句的澄清）。
