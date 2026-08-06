# 第 1 期 UI 扁平化 —— 合并实施计划

> 本文是六份分维度调查的**唯一裁决版本**。凡与分报告冲突处，以本文为准。
> 行号均以本次调查时的 HEAD 为准；同一文件内的多处修改**从文件末尾往前改**，跨提交须重新定位。

---

## 0. 我实测复核过的前提修正（影响排期，先读）

| 事实 | 证据 | 对计划的影响 |
|---|---|---|
| Phase 0 令牌层在业务页面**零采用** | `AppSpacing.\|AppRadius.\|AppSurfaces.of\|context.surfaces` 全库仅 21 处、4 个文件：`design_tokens.dart`、`app_state_views.dart`、`app_card.dart`、`app_buttons.dart`。`features/` 下 0 处 | "改一处全局生效"目前是**假的**。必须先有提交 7/8/11 把调用点接上，提交 12 的令牌翻转才有意义 |
| `AppRadius.xs / xl / xxl` 全库 **0 引用** | grep 无命中 | 删除它们零成本；但也意味着**迁移期间不许写 xl/xxl**，否则提交 12 会编译失败 |
| `AppCard(` 真实调用 **6 处**，全在 `system_settings_page.dart:582/629/688/746/829/843` | grep 确认，另 3 处是 `_buildAppCard` 与构造函数声明 | AppCard 迁移是从 6 → 60，不是从 9 → 60 |
| `ResourceCard` 确认死代码 | 全库仅 `resource_card.dart:3`、`:9` 两处（类声明+构造函数） | 可直接删文件 |
| `AppColors` 已有 `red50`、`dangerDark`；**没有** `warningLight/warningDark` | `app_theme.dart:35/62`，`:66` 只有 `warning = amber500` | AppSnack 与 tintFg 需要新增这两个令牌 |
| `primaryDark / successDark / infoDark / dangerDark` **只用作前景文字** | 全库 11 个引用点，全部在 `_statusFg` 类函数与 `dep_list_page.dart:908` | 加深这两个值的 blast radius 可控，可以做 |
| `listBottom = 100` 的问题比密度报告说的**大 4 倍** | `app_router.dart` 里 ShellRoute 只装了 `/dashboard /tasks /logs /envs /more`；19 处 `fromLTRB(20,*,20,100)` 中 **13 处**在根导航器页面上 | 提交 3 从 3 处扩到 13 处 |

---

## 1. 冲突裁决表（谁拥有哪一行）

**规则一：一行只能有一个主人。** 下表左侧为被多个维度同时认领的代码，右侧为裁决结果。

| 代码位置 | 认领方 | **归属** | 被作废的提案 |
|---|---|---|---|
| `dashboard_page.dart:407-436` 渐变 + 装饰圆 + Stack | 装饰 / AppCard / 圆角(:417) | **提交 10（装饰专项）** 整块重做 | AppCard 迁移清单删掉此站；圆角清单删掉 `:417` |
| `dashboard_page.dart:442-455` 圆点 + 辉光 | 阴影(448-453) / 颜色(:446) / 装饰 | **阴影删 448-453 → 颜色改 :446** | 颜色维度的 `:450` 条目自动作废（行已不存在） |
| `dashboard_page.dart:540/635`、`task_stats_card:29`、`trend_chart:28` | AppCard / 圆角 / 装饰 | **AppCard 迁移** | 圆角的 `:544 / :642` 与装饰的 tokenize 建议 |
| `log_list_page.dart:736-762` | 阴影(:753) / AppCard(整块) / 圆角(:747) / 密度(:739,:740) | **阴影删 :753 → 密度改 :739/:740 → AppCard 接管整块** | 圆角 `:747`（随 AppCard 迁移消失） |
| `app_lock_gate.dart:230-246` | 阴影(:239) / AppCard(整块) / 圆角(:235) | **阴影删 :239 → AppCard 接管 :230** | 圆角 `:235` |
| `task_list_page.dart:1328-1338` | AppCard / 圆角(:1332,:1338) | **AppCard 迁移** | 圆角两条（同框同步对自动消失） |
| `task_list_page.dart:2104-2113` `_TaskScheduleSummary` | 密度(去框) / AppCard(迁移) | **密度（去框）** | AppCard 迁移条目整条作废 |
| `login_page.dart:266-282` 图标双层底 | 装饰(整块收掉) / 圆角(:271,:274) | **装饰** | 圆角两条 |
| `login_page.dart:522-530` 按钮本地 style | 阴影(删整块) / 装饰(elevation:0) / 圆角(:526) / 颜色(theme) | **阴影删整块 → 颜色只改 theme** | 装饰条目、圆角 `:526` |
| `subscription:1105/1108/1109`、`log_list:736/739/740`、`dep_list:1409/1414/1415`、`script_list:1682/1688` | 密度(数值) / AppCard(结构) | **密度先改数值 → AppCard 把数值原样搬进参数** | 无（顺序约束，不是取舍） |
| `app_theme.dart:252-256` popupMenuTheme | 阴影(elevation/shadowColor/side) / 圆角(:255) | **两者都做，但分在两个提交**（改的是同一 block 的不同属性行，git 不冲突） | 无 |
| `task_list:1816`、`env_list:1971` AnimatedContainer | AppCard 已自行排除 | **保持内联，本期不动** | — |

**规则二（顺序不变式）：**
1. 迁移到 AppCard 的站点，**不许**再单独改它的 `borderRadius / boxShadow / margin / padding` —— 这些一律变成 AppCard 参数。
2. 任何新写的圆角一律走 `AppRadius`，且**只许用 `sm / md / lg / pill` 四个名字**。
3. 提交 8 的 AppCard 迁移必须把提交 6 调好的 margin/padding 数值**原样搬进** AppCard 参数，禁止"顺手恢复"成原值。
4. 提交 11（圆角逐站点）的范围里**已剔除全部 60 个 AppCard 站点**，不需要再判断。

---

## 2. 提交序列

### 提交 1 — `chore(ui): 删除从未被引用的 ResourceCard 与死配置 navigationBarTheme`
- **文件**：`lib/features/dashboard/widgets/resource_card.dart`（删文件）、`lib/core/theme/app_theme.dart:214-237`（删 block）
- **修改数**：2
- **风险**：无
- **验证**：`flutter analyze` 通过且无新增 unused import；`grep -r "ResourceCard\|NavigationBar(\|BottomNavigationBar(" lib/` 返回空。**反证**：若 analyze 报某处 import 了 `resource_card.dart`，说明"死代码"判断错误，回滚。

---

### 提交 2 — `refactor(ui): 移除全部装饰性投影与 Material elevation`
- **文件**（13 个）：`user_list_page.dart:185-191`、`open_api_page.dart:115-121`、`env_list_page.dart:836-842`、`dep_list_page.dart:1135-1141`、`notification_list_page.dart:225-231`、`task_list_page.dart:575-581` 与 `:1861-1868`、`script_list_page.dart:654-660`、`subscription_list_page.dart:192-198`、`dashboard_page.dart:448-453`、`log_list_page.dart:753-761`、`app_lock_gate.dart:239-245`、`login_page.dart:522-530`（删整个本地 `FilledButton.styleFrom` 块）、`env_list_page.dart:327`、`task_form_page.dart:912`、`app_theme.dart:252-256`
- **修改数**：16（12 处 boxShadow 删除 + 3 处 elevation + 1 处 theme）
- **风险**：**中**。其中 2 处阴影是唯一分隔物，必须原子替换
- **必须成套改的两处**：
  ```dart
  // env_list_page.dart:327 与 task_form_page.dart:912 —— Autocomplete 浮层
  child: Material(
    elevation: 0,
    color: context.surfaces.card,
    shape: RoundedRectangleBorder(          // ← 注意：shape 与 borderRadius 互斥，
      borderRadius: BorderRadius.circular(12),  //    必须同时删掉原来的 borderRadius: 行，
      side: BorderSide(color: context.surfaces.cardBorder),  // 否则 Material 运行时 assert
    ),
  ```
  `app_theme.dart:252` popupMenuTheme 必须同时加 `elevation: 0` + `shadowColor: Colors.transparent` + `side: BorderSide(color: borderColor)` —— 这一处一次干掉 7 个 PopupMenuButton 的 M3 默认投影。
- **验证**：`grep -rn "boxShadow" lib/` 返回 0；`grep -rn "elevation:" lib/` 只剩 app_theme 里的 0 值。**必须真机反证**：① 打开环境分组输入框与任务表单分组输入框的 Autocomplete 下拉，浮层若与下方表单糊在一起 → shape/color 补错了；② 深色模式进应用锁界面，卡片若"消失"成一块看不见的深色矩形 → 把 `app_lock_gate.dart:236-238` 的边框从 slate800 提到 slate700，**不要**恢复阴影。
- **明确不做**：13 个 `DropdownButtonFormField` 的硬编码 `elevation: 8`（legacy dropdown 菜单路由不画边框、不暴露 shape，去 elevation 会变成真正无边界的浮板）；`SnackBarThemeData`（提交 4 会在 SnackBar 上直接设 behavior，加 theme 会打架）。

---

### 提交 3 — `fix(layout): 无底部导航栏的页面不再为其留 100dp 死留白`
- **文件**（13 个，均为 `app_router.dart` 里 `parentNavigatorKey: _rootNavigatorKey` 的路由）：`user_list_page.dart:240`、`open_api_page.dart:170` 与 `:1162`、`dep_list_page.dart:1307`、`script_list_page.dart:716`、`notification_list_page.dart:281`、`security_page.dart:218/529/779`、`system_settings_page.dart:577`、`backup_page.dart:1362`、`subscription_list_page.dart:320`、`app_lock_settings_page.dart:248`
- **修改数**：13（`100` → `24`）
- **风险**：低（只影响滚动余量，不影响每屏行数）
- **验证**：逐页滚到底，最后一张卡片下方约一指留白且未被系统手势条压住。**反证**：若某页滚到底被悬浮底栏遮住 → 该页其实在 ShellRoute 里，我对 `app_router.dart` 的判读错了，单独回滚该行。
- **明确不做**：`task_list:859/1194/1257`、`env_list:1167/1267`、`log_list:671` 这 6 处 ShellRoute 页面保持 100 不动（见第 4 节"本期剔除"）。

---

### 提交 4 — `feat(ui): AppSnack 增加语义 tone，成功与失败不再是同一条灰色提示`
- **文件**（9 个）：`app_snack.dart`（重写）、`app_theme.dart`（新增 `warningLight = Color(0xFFFDF6EC)` / `warningDark = Color(0xFFB88230)`）、`task_list_page.dart`、`log_list_page.dart`、`script_list_page.dart`、`dep_list_page.dart`、`backup_page.dart`、`app_lock_settings_page.dart`、`server_config_page.dart`
- **修改数**：约 62（API 1 + 令牌 2 + 调用点重标 ~59）
- **API**：新增 `AppSnackTone{neutral,success,error,warning,info}` + `AppSnack.success/error/warn/info` 四个快捷方法；`neutral` 保持 `inverseSurface` 原样，未重标的 56 处调用点像素不变。用 `SnackBarBehavior.floating` + 显式 `margin`。
- **最高杠杆的一行**：`task_list_page.dart:96` —— `_showActionError` 是全部任务操作失败的漏斗（批量操作/启动/停止/删除/复制/排序保存），改成 `AppSnack.error(...)` 一行让六种失败同时变红。
- **风险**：中
- **验证**：断网后点"运行任务"应弹红条；保存脚本成功应弹绿条。**必须真机反证**：如果一次操作弹出**两条** SnackBar（一条在底栏上方、一条被底栏盖住），说明"根 ScaffoldMessenger + 页面自带 Scaffold"双投递属实，需要给 `MaterialApp.router` 挂 `scaffoldMessengerKey` —— 这条在改红之前是灰的所以没人注意，改红之后会非常刺眼。
- **明确本期只做一半**：全库还有 118 处裸 `showSnackBar(` 绕过 AppSnack，其中 `env_list_page`(18) 与 `subscription_list_page`(12) **一次都没用过** AppSnack。这批迁移单列 backlog，不进第 1 期。

---

### 提交 5 — `fix(theme): 淡底徽章前景色令牌化，修 11 处低于 3:1 的对比`
- **文件**（4 个）：`design_tokens.dart`（新增 `Color tintFg(Color)`）、`app_theme.dart:10` `primaryDark → 0xFF2A5F99`、`:50` `successDark → 0xFF3E7A22`、新增 `warningDark`、`app_buttons.dart:96`（`color` → `surfaces.tintFg(color)`）、`task_list_page.dart:1640`、`dep_list_page.dart:1693-1700`
- **修改数**：约 7
- **根因说明**：`tintBg()` 浅色模式 alpha=18，调用方却拿**同一个满强度色**当前景，数学上封顶 ~2.6:1。这一处令牌一次修好 12 个站点，**必须先于提交 6b 落地**，否则那 22 处语义换色会让部分徽章更难读（success 在淡底上只有 2.11:1，比现在的 primary 2.60:1 还差）。
- **风险**：中（blast radius 覆盖全部运行中/已启用/已安装徽章，但只改前景文字，实测这两个令牌全库 11 个引用点均为前景）
- **验证**：浅色模式看任务列表的"运行中/成功/排队中"三个徽章文字是否明显变深变清晰；深色模式应**完全无变化**（`tintFg` 在深色分支直接返回原色）。**反证**：若深色模式有任何变化 → `tintFg` 的 `if (!isLight) return color;` 短路写漏了。

---

### 提交 6 — `fix(theme): primary 不再表示「成功 / 已启用 / 在线」`
- **文件**（10 个）：`dashboard_page.dart:446`、`task_list_page.dart:753/1736/2101`、`env_list_page.dart:1066/1256/1356/1367/1417/1905/2018`、`subscription_list_page.dart:1126/1732`、`dep_list_page.dart:1049/1662`、`security_page.dart:300`、`open_api_page.dart:399/409/954/965/1199/1210`、`notification_list_page.dart:924/931/984`、`login_page.dart:680`、`script_list_page.dart:2142/2144`
- **修改数**：约 27
- **风险**：中高（视觉可见，但零布局影响）
- **最显眼的一处**：`dashboard_page.dart:446` 是开屏第一眼的"在线"圆点，蓝变绿。**这一处要单独给用户看截图**，不要夹带过去。
- **同卡自相矛盾的两处（改完才自洽）**：`subscription_list_page.dart:1126` 圆点是蓝的、但同一张卡的徽章 `:1098` 早在 Phase 0 就改成绿了；`env_list_page.dart:1256`（详情页圆点）与 `:2018`（列表卡圆点）必须同时改，否则两个界面对"已启用"的表述不一致。
- **验证**：全库 `grep -n "enabled\s*?\s*AppColors.primary\|available\s*?\s*AppColors.primary\|success\s*?\s*AppColors.primary"` 返回 0。**反证**：若某处圆点改绿后与其旁边的徽章颜色不一致 → 漏改了配对的 bg/fg（这类配对共 5 组）。
- **明确不做**：`dep_list_page.dart:1208` 的"全部" chip（它是**无筛选**选项不是状态，代码注释 `:1220-1221` 明确写了 Phase 0 是为了让它保留品牌色才把"已安装"改走的）；`AppColors.termGreen`（终端 ANSI 调色板，与品牌无关）。

---

### 提交 7 — `perf(ui): 列表行密度收紧（纯 padding / margin / 间隙）`
- **文件**（6 个）：`task_list_page.dart:1720/1822/1912/1926/1329/1354/1953-1954/2104-2113`、`log_list_page.dart:739/740/793/809`、`env_list_page.dart:1892/1977/2059`、`script_list_page.dart:1688`、`dep_list_page.dart:1414/1415`、`subscription_list_page.dart:1108/1109/1192/1195`
- **修改数**：约 22
- **风险**：中（唯一有结构变化的是 `task_list_page.dart:2104` 去框）
- **唯一的判断题**：`_TaskScheduleSummary` 从 `Container(带底色+边框+12 圆角)` 变成 `SizedBox(width: double.infinity, child: Row(...))`，省 20dp。这是任务卡的最大单项收益，也是"带边框的盒子套在带边框的卡片里"这一典型花里胡哨的最清晰实例。若用户否决，退化方案是只把 `vertical: 9 → 6`（省 6dp），此时**必须把这一站点还给提交 8 的 AppCard 迁移**。
- **预期效果**（按 640dp 屏、Roboto 度量估算）：任务 1→2 行、日志 4→5、环境 4→5、脚本 7→8、依赖 5→6、订阅 3→4。
- **验证**：真机截图对比每屏完整可见行数。**反证**：若任务列表仍只显示 1 张卡 → 说明 `_buildTaskGroup` 那个**无条件渲染的 60.9dp 分组头**（含"未分组"桶）才是主因，`:1329/:1354` 的 10dp 削减不够，需要考虑对单一"未分组"桶不渲染分组头。
- **本提交不含**（信息删除，需用户签字）：`env_list_page.dart:2069` 环境值 `maxLines 2→1`（省 12.9dp）；`subscription_list_page.dart:1164-1191` 删仓库 URL 行（省 24.1dp）。
- **发现但不修（另立 a11y backlog）**：`main_scaffold:156` 导航项 36dp、`app_buttons:30` 32dp、`subscription:1259` `_SmallIconBtn` 30dp、`task_list:3041` 18dp、`log_list:826` / `script_list:1729` 40dp —— 全部低于 48dp 且**在本次修改之前就是**。修它们要付出密度（订阅卡从 −21dp 退化到 −3dp），不属于扁平化。

---

### 提交 8 — `refactor(ui): 内联卡片形 BoxDecoration 迁移到 AppCard（第一批：无交互）`
- **文件**（约 18 个）：`task_form_page.dart:409`（**最高杠杆：一个闭包画出任务表单的每个分区**）、`security_page.dart:277/553/800/1001/1065`、`user_list_page.dart:605`、`open_api_page.dart:363/927/1173`、`notification_list_page.dart:894`、`subscription_list_page.dart:1377`、`script_list_page.dart:2435`、`task_list_page.dart:2179`、`dep_list_page.dart:940/1409`、`env_list_page.dart:1023`、`app_lock_settings_page.dart:249/454`、`more_page.dart:97`、`sponsor_page.dart:114/160/260`、`trend_chart.dart:28`、`dashboard_page.dart:540`、`task_cron_list.dart:29/61`
- **修改数**：约 26 站点（每站点删 6-14 行 BoxDecoration）
- **风险**：中
- **圆角一律写 `AppRadius.lg`**（外层卡片）或 `AppRadius.md`（内嵌块），**禁止写 `xl/xxl`**。这意味着现值 16/18 的站点在本提交后会短暂变成 14，提交 13 再落到 12 —— 这是**一次代码修改、两次视觉变化**，不违反"后续提交不重写前面提交"。
- **必须显式传参、否则静默变色的 4 处**：`script_list:1682`（浅色边是 slate100 不是 slate200）、`app_lock_gate:230`（深色底是 slate950 不是 slate900）、`task_list:2104`(已由提交 7 去框，不在此列)、`task_cron_list:29` 与 `task_list:2179` 走 `surfaces.subtle/subtleBorder`
- **验证**：`flutter analyze` 通过；逐页截图对比卡片底色/边框未变。**反证**：任何卡片突然多出或少掉 16px 内边距 → 漏传 `padding: EdgeInsets.zero`。

---

### 提交 9 — `refactor(ui): AppCard 迁移第二批（交互态 / ReorderableListView key / 零内边距）`
- **文件**（约 13 个）
  - **带 onTap（GestureDetector 折进 AppCard.onTap）**：`more_page.dart:534`、`subscription_list_page.dart:1105` 与 `:1466`、`dashboard_page.dart:635`、`dep_list_page.dart:885`、`system_settings_page.dart:1149`、`task_list_page.dart:1328`、`task_stats_card.dart:29`、`log_list_page.dart:736`
  - **带 key（必须 `AppCard(key: ...)`）**：`task_list_page.dart:1207` 与 `:1266`、`env_list_page.dart:1200`
  - **必须 `padding: EdgeInsets.zero`**：`panel_log_page.dart:177`、`task_form_page.dart:786`、`script_list_page.dart:2255`
  - **其他特例**：`script_list_page.dart:1552`（外包 `ConstrainedBox`）、`:2805`（`bordered: false`）、`:1682`、`app_lock_gate.dart:230`
- **修改数**：约 19 站点
- **风险**：**高**（本计划风险最高的提交）
- **两类会在运行时炸的坑**：
  1. `key` 掉了 → `ReorderableListView` 抛 *Every item must have a key*。`flutter analyze` **看不出来**，必须真进排序模式拖一下。
  2. `shape` 与 `borderRadius` 同时传给 Material → assert（这条在提交 2 已提示，此处复查）。
- **一类看不出来的行为变化**：9 处 `GestureDetector → AppCard.onTap` 会**新增 Material 水波纹**。这是"统一"的应有之义，但要**一次性拍板**，不要一处一处讨论。
- **验证**：进任务排序模式、环境排序模式各拖一次；点每一张改过的卡片看水波纹是否在圆角内被正确裁切；`panel_log` / 脚本编辑器 / 任务表单折叠区检查内边距。**反证**：日志页 `log_list:736` 迁移后，其内部 `:775` 的 `InkWell(onTap: onView)` 若失效（点击不再进详情）→ AppCard 的外层 InkWell 抢走了手势，需要保留内层布局层次。

---

### 提交 10 — `refactor(ui): 12 处淡底提示条抽成 AppNotice`
- **文件**：新增 `lib/shared/widgets/app_notice.dart`（基于 AppCard），改 8 个文件 12 处：`app_lock_gate.dart:314` 与 `:403`、`login_page.dart:491`、`dep_list_page.dart:831` 与 `:1753`、`subscription_list_page.dart:1275`、`system_settings_page.dart:957`、`task_list_page.dart:784`、`env_list_page.dart:1098`、`backup_page.dart:654/989/1121`
- **修改数**：1 新文件 + 12 站点
- **风险**：中（会统一 alpha：现存 red 有 14/36、15/40、24/48 三套，blue 有一套 12/30，primary 有 12/28、16/26 两套 —— 统一到 `tintBg/tintBorder` 的 18/24 与 60/90）
- **为什么不是"给 AppCard 加参数"**：我复核了 AppCard 的 API，**找不到任何需要新增 prop 的站点**。这 12 处用 `AppCard(color:, borderColor:)` 就能表达，但手写 12 遍等于把 AppCard 想消灭的重复原样搬家。正确解是加一个新组件，不是加参数。
- **验证**：截图对比 12 处提示条的底色/边框深浅一致；`grep -c "withAlpha(1[2-5])" lib/` 显著下降。

---

### 提交 11 — `refactor(dashboard,login): 去掉渐变、装饰圆、图标双层底与图表面积填充`
- **文件**（4 个）：`dashboard_page.dart`、`trend_chart.dart`、`task_stats_card.dart`、`login_page.dart`
- **修改数**：约 12
- **逐项**：
  1. `dashboard_page.dart:407-436` —— 删 LinearGradient（浅色是 #FFF→#F8FAFC，手机上根本看不见）、删 `Positioned` 装饰圆、把只剩一个孩子的 `Stack` 收掉、整块换 `AppCard`。**注意 Stack 收掉后 Column 从 loose 约束变成紧约束**；我读了代码判定视觉等价（两个内层 Row 都是 mainAxisSize.max），但这是布局图变更不是绘制变更，要眼睛确认。
  2. `dashboard_page.dart:555-567` —— **只删 32x32 的着色底板，保留图标本身的颜色**。（分报告主张连图标颜色也改灰；我不采纳 —— 那会让 CPU/内存/磁盘三张卡完全同质。）
  3. `dashboard_page.dart:605` —— `value: (value ?? 0) / 100`。内存不可用时现在传 `null`，进度条变成**无限循环扫动**表达"没有数据"，而正上方文字已经写了"不可用"。（分报告主张用 `if (value != null)` 整块隐藏；我不采纳 —— 那会让内存卡比同一 Row 里的 CPU 卡矮一截。）
  4. `dashboard_page.dart:169` → `AppLoadingView()`；`:244/:315/:339/:354` 四个内联小标题 → `AppSectionTitle`（后随的 `SizedBox(height:12)` 相应降到 8，因为 AppSectionTitle 自带 `bottom:4`）。
  5. `trend_chart.dart:144` `belowBarData → show:false`（成功绿与失败红两块面积叠在一起是混出来的第三种颜色，不对应任何序列）；`:140` `isCurved → false`（数据是每日整数计数，样条会凭空造出中间值，且 `dotData` 是隐藏的，读者根本看不到真实测点在哪）。
  6. `login_page.dart:243-252` 渐变 → `context.surfaces.page`；`:266-282` 双层圆角底 → 单个 `ClipRRect` 包 56×56 图标。
  7. **可选**：`task_stats_card.dart:69-74` 删"已禁用"（`dashboard_provider.dart:57` 定义 `disabledTasks => totalTasks - enabledTasks`，是算出来的，却和真数据同样字号字重）。
- **风险**：**高**（判断题最密集的一个提交）
- **验证**：截图。`trend_chart` 的两项要**单独拿给用户看**，这是全计划里最可能被读成"你把我的图表弄丑了"的一处。

---

### 提交 12 — `refactor(theme): 圆角逐站点归档到三档（AppCard 站点已排除）`
- **文件**：约 20 个
- **修改数**：约 70
- **构成**：
  - `app_theme.dart` 11 处：cardTheme `16→lg`、input `border/enabled/focused` 三处 `12→md`（**必须三处同改**，否则聚焦动画中途角不一致）、filled/outlined button `12→md`、chipTheme `20→pill`（32px 高的 Chip 上 20 本来就被 clamp 成 16，零像素变化）、bottomSheet `vertical(top: Radius.circular(20))→lg`、popupMenu `12→md`、dialog `20→lg`；**新增 `checkboxTheme(shape:)`** 并删除 `login_page.dart:678` / `log_list_page.dart:775` 两处本地 Checkbox 圆角覆盖。
  - **四种正则扫不到的写法**（务必手工核对）：多行 `circular(\n 999,\n)`（`script_list:2466`、`subscription:1496`）、`BorderRadius.vertical(top: Radius.circular(N))`（`app_theme:249`、`task_form:798`）、`circular(compact ? a : b)`（`task_cron_list:37/69/80`）、`circular(radius)`（`app_card:64`，无需改）。
  - **必须按角色而非数值分档的 6 处嵌套陷阱**：`app_lock_settings:271`、`backup:937`、`backup:1039`（14 的图标底板嵌在 16/18 的卡里 → 走 `sm` 不是 `lg`）、`backup:996`、`backup:1222`、`app_lock_gate:407`。数值键的一刀切会让内层等于外层。
  - **本来就是胶囊却没这么写的 4 处**（零像素变化，只为诚实）：`dep_list:1707`（h≈31 用 r=20）、`dep_list:1732`（h≈15 用 r=10）、`dashboard:603`（6px 高进度条用 r=4）、chipTheme。
- **我推翻分报告的一处**：15 处逐字复制 `app_theme` 的 `OutlineInputBorder(12)` 覆盖（`task_list:611/617/623`、`log_list:535/541/547`、`env_list:879/887/895`、`subscription:229/237/245`），分报告主张**删除**。我改为**令牌化不删除** —— "只差 borderSide 颜色而 theme 已经供了"这个判断没有实证，删了若颜色变化，排查成本远高于收益。删除单列 backlog。
- **风险**：中
- **验证**：`grep -rn "BorderRadius.circular([0-9]" lib/` 剩余数应 < 10（且全部有注释说明）；`grep -rn "Radius.circular(\|circular($" lib/` 手工复查四种特殊写法。

---

### 提交 13 — `refactor(tokens): 圆角令牌收敛为 sm/md/lg/pill 四档`
- **文件**：`lib/core/theme/design_tokens.dart:20-46`（唯一一个文件）
- **修改数**：1 个 block
- **内容**：`sm=6 / md=10 / lg=12 / pill=999`，**删除 `xs / xl / xxl`**（全库 0 引用，删除零成本，且强制以后不许再分叉）。
- **风险**：**视觉高、机械低**。全部 150 处圆角一次到位。
- **保守版**：`sm=8 / md=12 / lg=14`（＝今天的值）。这版把 11 档收成 3 档、拿到全部一致性收益，**且几乎零像素变化**。
- **强烈建议**：先发保守版，跑一个版本，再单独决定要不要压。提交 12 与 13 之间存在中间态（此时 lg 还是 14，`4→8` 的微徽章会变**更圆**），两者应同一次发版，中间态不要单独发布。
- **验证**：全应用截图走查。**回滚成本 = 改三个数字**，这是整个计划里最便宜的回滚点，也是我把它放最后的唯一原因。

---

## 3. 本期明确剔除（连同理由）

| 被剔除项 | 来源 | 理由 |
|---|---|---|
| `filledButtonTheme.backgroundColor: primary → primaryDark` | 颜色 | 见第 4 节问题 3 |
| `main_scaffold.dart:156` 导航项提到 48dp | 密度 | 会让底栏从 48.5 长到 60.5，与密度目标**方向相反**，且级联到 listBottom |
| `AppSpacing.listBottom` 改成 MediaQuery 运行时函数 | 密度 | 底部留白**不影响每屏行数**，零密度收益；却把 6 处 const 变非 const 并把布局耦合到底栏高度 |
| `env_list:2069` maxLines 2→1、`subscription:1164-1191` 删仓库 URL | 密度 | 这是删信息不是删装饰，必须用户签字 |
| 13 处 DropdownButton `elevation: 8` | 阴影 | legacy 菜单路由不画边框、不暴露 shape，去 elevation 会得到真正无边界的浮板。正解是迁到 `DropdownMenu`，那是重构不是第 1 期 |
| 118 处裸 `showSnackBar(` 迁移 | 密度/AppSnack | 单独 backlog |
| 15 处冗余 `OutlineInputBorder` 覆盖的**删除**（令牌化仍做） | 圆角 | 无实证支撑"theme 已供同色" |
| 8 个重复的头部"+"圆钮抽公共组件 | 阴影 | 删完投影后是 8 份一模一样的 Container，抽出来是对的，但属于组件化不属于扁平化 |
| 6 处 48dp 以下点击区修复 | 密度 | 全部是**本次修改之前就存在**的问题；修它们要还回密度。另立 a11y backlog |
| `dashboard_page` 从不读 `data.error`（失败时把 CPU 0% / 主机名 `-` 当测量值渲染） | 装饰(附带发现) | 这是真 bug 不是 UI，另开 issue |

---

## 4. 三个问题

### 问题 1：这个计划里，什么会让 App **变难看**？收益递减点在哪？

**a. `sm = 6` 是全计划里唯一"扁平化把东西变更圆"的地方。**
9 处 `r=4` 里有 6 处是 fontSize 10、纵向内边距 1-3px 的微型文字徽章（`user_list:658`、`open_api:401/956/1201`、`subscription:1150`、`dep_list:1476`）。把它们从 4 提到 6，在 13-19px 高的胶囊上会明显变圆润。我保留 6 是为了让图标底板和 mono 代码块不至于像纸片，但如果你要的是"更方"，`sm = 4` 更诚实。

**b. 应用锁模态是全计划最不放心的单点。**
它同时挨了两刀：提交 2 删掉全库最强的投影（blur 24 / offset 0,14），提交 13 把圆角从 24 砍到 12。深色模式下它是 slate950 卡片浮在 alpha-140 黑色遮罩 + 14px 背景模糊之上，删完投影后**唯一的分隔物是一条 slate800 的 1px 边**。这两件事叠加，很可能读成"对话框消失了"。若如此，加深边框到 slate700，**不要**恢复投影。

**c. 仪表盘三张资源卡会变成三张几乎一样的灰卡。**
即便我保留了图标颜色（不采纳分报告的全灰方案），去掉 32×32 着色底板之后，CPU / 内存 / 磁盘的视觉区分度只剩下进度条颜色。信息没丢，一眼扫过去的层级会明显变弱。

**d. 折线图会从"漂亮的双色渐层"变成两条硬折线。**
`isCurved: false` + `belowBarData.show: false`。数据上是对的（每日整数计数不该被样条插值），观感上是明确更朴素。这是最可能被用户说"你把我的图表弄丑了"的一处，必须当作**主动选择**呈现，不能当清理夹带。

**e. 删完全部投影 + 全部渐变之后，浅色模式只剩三个灰度层级**（白卡 / slate200 边 / slate50 页底）。整个 App 会非常平，接近"网页表单"的观感。这正是用户要的，但值得先给一张截图确认这不是"变简陋"。

**f. 收益递减点：我认为在提交 13（圆角令牌翻转）。**
删投影、删渐变、删装饰圆、去掉卡内套卡、把 60 处内联卡片统一成 AppCard、把 22 处混淆的语义色纠正 —— 这些全是纯收益，做完 App 会明确变干净。把 11 档圆角收成 3 档也是纯收益（一致性）。但把这 3 档的**绝对值再压小**（14→12、8→6），已经不产生"更干净"的感受，只产生"不一样"的感受。所以提交 13 我给了两版，并建议先发保守版。

---

### 问题 2：哪些东西不跑真机就无法验证，因此是**赌**出去的？

1. **全部对比度数字**（2.03:1 / 2.78:1 / 3.20:1 …）都是算出来的，不是在屏幕上量的。淡底徽章是 alpha 合成，实际渲染受设备色彩管理与厂商屏幕调校影响。
2. **中文字形行高。** 密度报告的每屏行数用 `1.17 × fontSize`（Roboto 度量）。Android 上中文回退字体可能到 1.4×，所有"每屏 X 行"的绝对数字可能乐观 20%。**padding 省下的 dp 是精确的，行数不是。**
3. **嵌套 Scaffold 是否真的双发 SnackBar。** 这条直接决定 AppSnack 改造要不要连带改 `MaterialApp`。改红之前是灰的所以没人注意，改红之后会非常刺眼。必须真机弹一条看有没有两个。
4. **两个 Autocomplete 浮层去掉 `elevation: 4` 之后有没有边界**（`env_list:327` / `task_form:912`）—— 这是全库仅有的两处"阴影是唯一分隔物"，静态检查完全看不出来。
5. **深色模式下应用锁模态删投影 + 砍圆角后还立不立得住。**
6. **9 处 `GestureDetector → AppCard` 新增的水波纹观感**，以及 `log_list:736` 迁移后内层 `InkWell(onTap: onView)` 会不会被外层抢走手势。
7. **仪表盘 Stack 折叠后的布局等价性。** 我读了代码判定等价（Stack 的 loose 约束 vs Container 的紧约束，在两个 mainAxisSize.max 的 Row 下同解），但这是推断不是观察。
8. **`ReorderableListView` 的 key 有没有掉。** `flutter analyze` 看不出来，**运行时**才抛 assert。必须真的进一次任务排序、一次环境排序，各拖一下。
9. **系统字号 1.3× 下的表现。** `app.dart` 没有 textScaler clamp，密度收紧后吸收放大的余量更少。我全程不改字号，所以放大场景的退化方式和今天一致，但没有实测。

---

### 问题 3：风险收益比最差、应该**砍掉**的单个提案

**`app_theme.dart:178` —— `filledButtonTheme.backgroundColor: AppColors.primary → primaryDark`。砍掉。**

理由，按重要性排序：

1. **它与 Phase 0 刚做完的事情方向相反。** Phase 0 的全部意义（见 `app_theme.dart:6-7` 的注释）是让 App 主色对齐呆呆面板 web 端的 Element Plus `#409EFF`，"APP 不再自成一套 Emerald 绿"。而 Element Plus 自己的 primary 按钮就是 `#409EFF` + 白字（同样 2.78:1），web 端天天在用、无人抱怨。为了一个 web 端本来就不满足的指标，让 App 单方面偏离刚刚统一好的品牌色 —— 净损失。
2. **它是全计划视觉最显眼的一处。** 所有主按钮（登录、保存、确认、批量操作）从"面板蓝"变成深海军蓝。改动幅度远超任何一处圆角或投影。
3. **它不是本期目标。** 用户的原话是"减少花里胡哨的东西，一切以简洁干净为主"。这是 WCAG AA 合规，不是简洁。
4. **它连"修复回归"都算不上。** 颜色维度自己承认：旧的 emerald `#10B981` 是 2.54:1，比现在**更差**。主色切换把它从 2.54 提到了 2.78，是改善不是破坏。这是一个前置存在的、被继承下来的缺陷。
5. **真要修也不该这么修。** 正确做法是给 FilledButton 的文字加字重/字号（≥18px bold 只需 3:1 即可达标），或者只把 `primaryDark` 用作**按下态**底色。这属于单独的无障碍专项。

**保留**同一维度的 `successDark → #3E7A22` 与 `primaryDark → #2A5F99` 取值加深 —— 我实测这两个常量全库 11 个引用点**全部是前景文字**（`app_theme:57/62` 的语义别名 + 6 个 `_statusFg` 函数 + `dep_list:908`），blast radius 完全可控，且修的是 10px 加粗徽章文字这种真正读不清的地方。

**并列需要一起砍的（第 3 节已列）**：`main_scaffold` 导航项提到 48dp（让底栏变高，与密度目标相反且级联到 listBottom）、`listBottom` 改成 MediaQuery 运行时函数（底部留白根本不影响每屏行数，零密度收益，却把 6 处 const 变非 const 并把布局耦合到底栏高度）。