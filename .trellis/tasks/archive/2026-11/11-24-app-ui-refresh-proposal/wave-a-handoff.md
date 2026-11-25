# 第一波（主题与外壳）交付契约 —— 第二波各组按这里 import，不改这些文件

> 来源：A 组交接（2026-11-25）。与 design.md 不一致时以本文件为准。

## 令牌（只 import `core/theme/design_tokens.dart`，它会 export app_palette）
- `context.palette`（`AppPalette` ThemeExtension，`AppPalette.light` / `.dark`）
  - 字段：`bg card card2 fill thumb text text2 text3 separator accent ok err warn purple accentInk okInk errInk warnInk purpleInk onStatus primaryBtnBg primaryBtnFg glass glassBorder`
  - 方法：`tint(Color)`（浅底：浅色 12%、深色 22%）、`glassSolid`、`isLight`
  - **状态色当文字一律用 `xxxInk`**；实色只给图标、圆点、图表、进度条。浅色 `text2` = `#6E6E73`（方案书的 #8A8A8E 对比度不够）。
- `AppRadius`：新增 `card = 30`、`cardSm = 28`、`tile = 15`、`pill = 999`；旧档 `control / sm / md / lg`（4 / 8 / 12 / 14）不变，`AppCard` 默认圆角不变。
- `AppText`：`largeTitle / section / cardTitle / body / caption`（都不带颜色）；`AppText.tabular(style)` 等宽数字。
- `AppMotion`：`reduce(ctx)`；`fast 120ms / normal 220ms / sheet 380ms / slide 450ms`；`spring`；`AppMotion.of(ctx, d)`（减少动画时返回 0）。
- 底部留白：**`AppSpacing.listBottomOf(ctx)`** = 底栏实际高度 + 16，在 ListView 外面读、再传给 padding；兜底常量 `AppSpacing.listBottom = 112`；`AppTabBarMetrics.height / bottomGap / sideGap`。各页写死的底部 100 要改成它。
- `AppColors`（#409EFF 等旧常量）**没改**：仍直接用 `AppColors.*` 的页面在迁移前还是旧蓝，第二波各组把本组文件里的 `AppColors.*` 换成 palette。
- 主题全局：无水波纹（按下整行变灰）、输入框灰色填充无描边、OutlinedButton 灰色胶囊、Switch 开启为绿色、弹窗圆角 28、底部面板顶部圆角 30。

## Provider
- `themeModeProvider`（`core/theme/theme_mode_provider.dart`）：`StateNotifierProvider<ThemeModeNotifier, ThemeMode>`；`notifier.set(ThemeMode)`、`notifier.value`（`system / light / dark`）、`ThemeModeNotifier.options`（值 → 中文名）、`prefsKey = 'app_theme_mode'`、`static preload()`。**B8 在 `main.dart` 的 `runApp` 前加 `await ThemeModeNotifier.preload();`**。
- `DefaultLandingPage`：options = `tasks / logs / overview / envs`，`defaultValue = 'tasks'`；旧值 `dashboard` 读到时改 `tasks` 并回写。

## 路由
- Shell 内 `/tasks /logs /overview /envs /settings`，页面都走 `tabPage(state, child)`（`app_router.dart` 导出）；`/dashboard → /overview`、`/more → /settings`；`/tasks/:id/detail` 保留。
- `main_scaffold.dart` 导出 `mainTabs`（`List<MainTab(route, label, icon)>`）。
- 占位页：`features/overview/views/overview_page.dart`（返回 DashboardPage）、`features/settings/views/settings_page.dart`（返回 MorePage）—— B4 / B6 重写。

## 组件（`lib/shared/widgets/`）
- `AppLargeTitleHeader({title, subtitle?, leading?, actions = const [], padding})`，sliver 版 `AppLargeTitleHeader.sliver(...)`
- `AppGlassCircleButton({icon, onTap, required tooltip, badge?, size = 48})`
- `AppGroupedList({children, header?, footer?, margin?})`
- `AppGroupedRow({leading?, title, subtitle?, trailing?, showChevron = false, onTap?, onLongPress?, titleColor?, showSeparator?})`：懒加载列表里不包 AppGroupedList 时传 `showSeparator: index > 0`
- `AppIconTile({icon, color, size = 36, solid = false})`
- `AppSegmented<T>({segments: List<(T, String)>, value, onChanged})`
- `AppPillButton({label, icon?, onPressed, variant = AppPillVariant.primary / secondary / danger, expand = false, height = 46})`
- `NotchedCard({child, notch, notchSize = Size(208, 82), radius = 30, notchGap = 12, color?})`：child 铺满整卡、要自己避开右下角；默认 notch 正好放下 `HoldToRunButton` 默认尺寸
- `HoldToRunButton({label, onConfirmed, holdDuration = 700ms, enabled = true, icon = play, width = 196, height = 70})`
- `showAppSheet<T>({context, builder, fullHeight = true})` → `Future<T?>`：默认 `CupertinoSheetRoute`（3.41.9 实测可用，背后页面缩放；点遮罩不关、下拉可关），减少动画走淡入；`fullHeight: false` 回落 `showModalBottomSheet`
- `MainScaffold({child})` 签名不变

## v4 接口（`shared/api/panel_insights.dart`，模型 `shared/models/insights.dart`）
- `fetchTaskHealth(int id, {int days = 91, Dio? dio})` → `TaskHealth?`
- `fetchAttention({Dio? dio})` → `List<AttentionItem>?`
- `fetchRunning({Dio? dio})` → `List<RunningTask>?`（没有任务在跑是 `[]` 不是 null）
- `fetchRecentRuns(List<int> ids, {int limit = 20, Dio? dio})` → `Map<int, List<RecentRun>>?`（ids 为空不发请求、返回 `{}`）
- `isInsightUnsupported(key, {dio})`；测试用 `resetPanelInsightsForTest()`
- null 的含义：404 路由不存在 / 405 / 形状不符 → null 并按「面板 + baseUrl」逐接口记住不支持（切面板清空）；health 的 404「任务不存在」也返回 null 但**不记**不支持；网络 / 401 / 5xx 照常抛出。
- 模型：`TaskHealth{days, stats, recent}`、`HealthDay{date, total, failed, avgDuration, day}`、`HealthStats{runs, successRate(0~100), avgDuration, p90Duration}`、`HealthRun{status, duration?, startedAt?, isFailed}`、`AttentionItem{key, type, level, title, detail, target{kind, id}, at}`、`RunningTask{taskId, name, logId?, startedAt?}`、`RecentRun{status, duration?, isFailed}`。

## 已知遗留（给第二波）
- `DashboardNotifier.load` 第一个请求失败时，第二个并发请求的 Future 没人 await，会冒成未捕获的 DioException —— B4 重写概览时一并处理。
- 底栏没有未读徽标；没有低端机探测（玻璃只在「移除动画」时退化）。

## 第二波组间契约（文件路径与名字定死，各组按此 import）

| 提供方 | 文件 | 契约 |
|---|---|---|
| B1 | `lib/features/tasks/providers/favorite_tasks_provider.dart` | `favoriteTasksProvider`（按服务器区分，本机键 `tasks.favorites`，值为任务 id 列表，最多 5 个）：state 为 `List<int>`；notifier 方法 `isFavorite(int id)`、`toggle(int id)`（满 5 个时返回 false 并不加）、`remove(int id)`、`reorder(int oldIndex, int newIndex)`；任务被删后由 B1 在列表刷新时调用 `prune(Set<int> existingIds)` 剔除 |
| B2 | `lib/features/tasks/widgets/task_detail_sheet.dart` | `Future<void> showTaskDetailSheet(BuildContext context, WidgetRef ref, Task task, {bool focusRun = false})`：`focusRun` 为 true 时弹层打开后高亮「按住运行」（快捷方式用）；弹层里可调 `favoriteTasksProvider` 加入 / 移出常用 |
| B8 | `lib/core/integration/integration_settings.dart` | `runningNotificationEnabledProvider`（`StateNotifierProvider<RunningNotificationSetting, bool>`，本机键 `integration.running_notification`，默认 false）：`Future<bool> setEnabled(bool on)`（开启时安卓 13+ 申请通知权限，返回实际状态）；`bool get supported`（iOS / web 为 false） |
| B8 | `lib/core/integration/integration_service.dart` | `IntegrationService.init(ProviderContainer)`（`main.dart` 调）；内部监听任务与运行中数据，其他组不需要主动调用 |
