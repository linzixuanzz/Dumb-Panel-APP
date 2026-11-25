# APP v2.0 技术设计

## 1. 主题与令牌（`lib/core/theme/`）

- **`AppPalette`（`ThemeExtension`）**：语义色，浅 / 深两套，取值见方案书 §2.3。组件一律 `context.palette.xxx` 读取，不写 `Color(0x…)` / `Colors.*`（插画、图表系列色除外，需注释）。
  - 字段：`bg` `card` `fill`（次级填充）`text` `text2` `text3` `separator` `accent`（`#007AFF` / `#0A84FF`）`ok` `err` `warn` `purple` `onStatus`（状态实色上的文字）`primaryBtnBg` `primaryBtnFg`（浅：黑底白字；深：白底黑字）`glass`（玻璃底，含透明度）`glassBorder`。
  - 状态色当**文字**时用对应的「墨色」getter（`okInk` 等：与正文色混合加深 / 提亮，保证 ≥ 4.5:1），实色只给图标、圆点、图表、进度条。
- **`AppRadius`**：保留旧名（兼容既有代码），新增 `card = 30`、`cardSm = 28`、`tile = 15`、`pill = 999`。
- **`AppText`**：`largeTitle`（34 / w800 / 字距 -0.7）`section`（22 / w700）`cardTitle`（21 / w700）`body`（16.5）`caption`（13.5）；数字用 `AppText.tabular(style)`（`FontFeature.tabularFigures()`）。
- **`AppMotion`**：`reduce(context)` = `MediaQuery.of(context).disableAnimations`；时长 `fast 120ms` `normal 220ms` `sheet 380ms`；弹簧曲线 `spring`（`Cubic(.2,.9,.25,1.15)` 级别的轻回弹）。
- **明暗设置**：`themeModeProvider`（`StateNotifier<ThemeMode>`），本机键 `app_theme_mode`（`system` / `light` / `dark`，默认 system，应用级、所有面板共用）；`app.dart` 改读它。
- Material 组件（`TextField`、`Switch`、`Dialog` 等）通过 `ThemeData` 映射到令牌，次级页面自动换装。

## 2. 共享组件（`lib/shared/widgets/`，第一波提供，第二波只用不改）

| 组件 | 签名要点 |
|---|---|
| `AppLargeTitleHeader` | `title`、`subtitle?`、`actions: List<Widget>`（放 `AppGlassCircleButton`）；可放进 `CustomScrollView` 作 sliver（`AppLargeTitleHeader.sliver`） |
| `AppGlassCircleButton` | `icon`、`onTap`、`tooltip`、`badge?`；`BackdropFilter`，低端机 / 减少动画时退化为 92% 不透明纯色 |
| `AppGroupedList` / `AppGroupedRow` | 白色大圆角容器；行 `leading`（常配 `AppIconTile`）、`title`、`subtitle?`、`trailing?`、`onTap?`；分隔线缩进到 leading 之后 |
| `AppIconTile` | `icon`、`color`（取 palette 状态色）、`size`（默认 36，圆角 `AppRadius.tile`）；浅底配同色图标 |
| `AppSegmented<T>` | `segments: List<(T, String)>`、`value`、`onChanged`；灰色胶囊底槽、白色滑块弹簧滑动 |
| `AppPillButton` | `label`、`icon?`、`onPressed`、`variant: primary / secondary / danger`；primary 读 `primaryBtnBg/Fg` |
| `NotchedCard` | `child`、`notch`（嵌在右下角缺口里的组件）、`notchSize`、`radius`；`CustomClipper<Path>` 画「圆角矩形减右下缺口 + 两个反向圆角」 |
| `HoldToRunButton` | `label`、`onConfirmed`、`holdDuration = 700ms`、`enabled`；进度条走满触发 `HapticFeedback.mediumImpact`，中途松手回弹取消；减少动画时进度条照常（功能性） |
| `showAppSheet<T>` | 卡片式弹层：优先 `CupertinoSheetRoute`（背景缩放），不可用时回落 `showModalBottomSheet`（`isScrollControlled`、顶部圆角 30、拖拽把手） |
| `MainScaffold` | 悬浮玻璃胶囊底栏（5 项：任务 / 日志 / 概览 / 变量 / 设置，实心图标 + 文字，选中灰色药丸弹簧滑动）；内容区底部留出底栏高度（`AppSpacing.listBottom` 调整为底栏高 + 安全区） |
| 既有组件 | `AppCard`、`AppButtons`、`AppSectionTitle`、`AppStateViews`、`AppNotice`、`AppSnack` 换成新令牌，签名不变 |

## 3. 路由（`lib/core/router/`）

- Shell 内 5 个 Tab：`/tasks`（首页）、`/logs`、`/overview`、`/envs`、`/settings`；切 Tab 用淡入（从 0.97 放大到 1，减少动画时无）。
- 兼容重定向：`/dashboard` → `/overview`，`/more` → `/settings`。
- **默认打开页面（APP #24）**：选项 `tasks`（默认）/ `logs` / `overview` / `envs`；`load()` 读到旧值 `dashboard` 时按 `tasks` 处理并回写。
- 任务详情改为弹层：保留 `/tasks/:id/detail` 路由（深链与旧调用不坏），列表点任务时直接 `showAppSheet`。

## 4. 面板 v4.0 新接口（`lib/shared/api/panel_insights.dart` + `lib/shared/models/insights.dart`）

| 函数 | 接口 | 返回 |
|---|---|---|
| `fetchTaskHealth(id, {days = 91})` | `GET /tasks/:id/health` | `TaskHealth?` |
| `fetchAttention()` | `GET /system/attention` | `List<AttentionItem>?` |
| `fetchRunning()` | `GET /tasks/running` | `List<RunningTask>?` |
| `fetchRecentRuns(ids, {limit = 20})` | `GET /tasks/recent-runs` | `Map<int, List<RecentRun>>?` |

- 响应**没有 data 包装**（与旧接口不同，解析时注意）。
- **形状探测**（`panel-contract.md`）：404 / 405 / 形状不符 → 返回 `null`，并在本次会话记住「该面板不支持」（按服务器区分，切面板时清空），调用方据此隐藏卡片；网络错误照常抛出。
- 模型字段与面板契约逐字对齐：health 的 `days[{date,total,failed,avg_duration}]`、`stats{runs,success_rate,avg_duration,p90_duration}`、`recent[{status,duration,started_at}]`；attention 的 `items[{key,type,level,title,detail,target{kind,id},at}]`；running 的 `items[{task_id,name,log_id?,started_at?}]`。

## 5. 第二波组间契约

| 提供方 | 契约 |
|---|---|
| B1 任务列表 | `favoriteTasksProvider`（按服务器区分，本机键 `tasks.favorites`，值为任务 id 列表，最多 5 个）：`ids`、`isFavorite(id)`、`toggle(id)`、`reorder`；任务被删后自动剔除 |
| B2 任务详情 | `showTaskDetailSheet(context, ref, Task task)`：B1 的列表点击、B8 的快捷方式都调它 |
| B4 概览 | 无对外契约 |
| B8 系统集成 | `IntegrationService`：`init()`（`main.dart` 调用）、`syncWidgetSnapshot(WidgetSnapshot)`、`updateRunningNotification(List<RunningTask>)`；内部自行监听任务 / 运行中数据，其他组**不需要**主动调用 |

## 6. 系统集成（B8）

- **快捷方式**（`quick_actions`，安卓 + iOS）：「新建任务」→ `/tasks/new`；「搜索任务」→ `/tasks` 并聚焦搜索；「运行 {常用任务 1}」→ 打开该任务详情弹层并高亮按住运行（不直接运行，防误触）。常用任务变化时刷新快捷方式。
- **桌面小组件**（`home_widget`，仅安卓）：Kotlin `AppWidgetProvider` + XML 布局（浅 / 深两套跟随系统）；显示今日成功率、下一个任务与时间、最近失败任务；点按通过 `HomeWidget` 启动 URI 打开 APP 对应页面。数据在 APP 前台刷新任务 / 概览时写入快照，小组件不后台联网。
- **常驻通知**（`flutter_local_notifications`，仅安卓）：独立通知渠道「任务运行中」；有任务运行时显示「N 个任务运行中 · 名称…」，全部结束后取消；只在 APP 进程存活时更新；安卓 13+ 在用户首次打开开关时申请 `POST_NOTIFICATIONS`。设置页提供开关（默认关）。
- 原生改动只放 `android/`；iOS 仅 `Info.plist` 若有必要的快捷方式配置。

## 7. 兼容与风险

- 次级页面只换装，业务逻辑不动；大文件按行段修改，不整体重写。
- 版本协商一律形状探测；连 v3.4.x 面板时 v4.0 专属卡片隐藏。
- `flutter analyze` 基线 7 条 info 不增加；Flutter 只在 PowerShell 里跑（`D:\flutter-sdk\bin`），widget test 注意 `tester.runAsync` 与常驻 spinner 不能 `pumpAndSettle`。
