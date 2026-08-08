# NEXT

## 目标版本

- **预计 APP 版本**：v1.3.1
- **当前基线版本**：v1.3.0+20
- **记录日期**：2026-08-08

## 更新内容

> 待发布版本草稿。后续每修复一个问题、优化一个体验或新增一个功能，都先记录到这里；最终发版时再整理为正式版本号文件，例如 `v1.3.1.md`。

### 新增

- 暂无。

### 优化

- 暂无。

### 修复

- 暂无。

### 说明

- 本文件用于收集下一轮 APP 端更新内容，正式发布前会根据实际改动整理成用户可读版本。

## v1.3.0 遗留的已知项

发版时明确记录、但没有做的事，避免下一轮重新调查一遍：

- **4 个 State 仍无 `error` 字段**：`NotificationListState` / `UserListState` / `DepListState` / `ScriptState`，断网时静默变空。
  另有两处是**改了一半**，比原样更危险：`SubscriptionListState` 的字段在（`subscription_list_page.dart:35`）、`load()` 的
  catch 也确实 set 了（`:82`），但整个 build 一次都没读过它，`:375` 仍然写死 `Text('暂无订阅')`；`DashboardData`
  同样是有字段、有 set、UI 不读（`dashboard_provider.dart:29` / `:139`）。**下次不要只 grep `final String? error` 就判定已修好**，
  要跟到 build 里确认它被消费。
- **补 `error` 之前得先让这些 Notifier 能注入 `Dio`**：11 个 StateNotifier 里只有 `TaskNotifier` / `LogListNotifier` 带
  `{Dio? dio}`，Dep / Script / Notification / User / Subscription / Dashboard / Env 七个都是直接取 `DioClient.instance.dio`
  单例，假 dio 注不进去。而 `quality-guidelines.md:156` 已经把「触碰列表 provider 必须有测试证明 `error` 被设置且能被 UI
  消费」写成硬性要求 —— 先动 `error` 会在写测试时卡住。改造形状照 `quality-guidelines.md:136-146`（可选 `Dio` 构造参数）抄。
- **111 处裸 `showSnackBar(`**（14 个文件）：绕过 `AppSnack`。其中 8 个文件**一次都没用过** `AppSnack` ——
  `security_page`(15) / `subscription_list_page`(14) / `open_api_page`(12) / `user_list_page`(10) /
  `notification_list_page`(9) / `more_page`(2) / `task_form_page`(2) / `panel_log_page`(1)，合计 65 处。
  `env_list_page` 裸调用最多（18）但已经用了 11 次 `AppSnack`，属于迁了一半，不是零使用。
- **4 个 model 的 `toJson()` 是死代码**：真实请求体是页面内联字面量，每个实体两份字段清单。`Subscription` 那份已删。
- **13 处点击区低于 48dp，其中 8 处 ≤36dp**：最糟的是 `task_list_page.dart:3064-3067` 的分组 `PopupMenuButton` ——
  `padding: EdgeInsets.zero` 配 `constraints: const BoxConstraints()`，**空约束等于把 IconButton 默认的 48×48 取消掉**，
  实际点击区就是那个 18dp 图标。其余 ≤36dp 的是：`subscription_list_page.dart:1542` 的 `_SmallIconBtn` 30dp（4 个调用点）、
  `app_buttons.dart` 的 `AppChipButton` ≈32dp **与 `AppTintedActionButton` ≈36dp（两个组件都不达标，不只是 chip 那个）**、
  `main_scaffold.dart:161` 导航项 36dp、以及 `dep_list_page.dart:1496` / `system_settings_page.dart:792` /
  `task_form_page.dart:806` 三个写死 36×36 的 IconButton。
  剩下 5 处在 40dp 档：`log_list_page.dart:865` 与 `script_list_page.dart:1721` 两个 `VisualDensity.compact` IconButton，
  加上 3 个被 `SizedBox(24, 24)` 夹住的选择框（`task_list_page.dart:1865` / `env_list_page.dart:2876` /
  `dep_list_page.dart:1408` —— 这三处整张卡的 `onTap` 覆盖同一动作，够不着的风险低，单列在这里只是别漏统计）。
  都是本轮之前就存在的。修它们要还回密度。
- **仪表盘「在线」圆点不绑定任何状态**：`dashboard_page.dart:408-415` 是写死的
  `const BoxDecoration(color: AppColors.success)`，面板不可达时照样常亮。
  **改动比想象中小**：`DashboardData.error` 已经在 set（`dashboard_provider.dart:139`），
  页面 `:118` 也已经 `watch` 了 `dashboardProvider`，缺的只是把 `const` 去掉、颜色改成读
  `data.error == null`。
  > 但别把它当成「在线状态」：`error` 反映的是**最后一次拉取失败**，不是心跳。
  > 面板刚挂、下一次轮询还没发生时它仍是绿的。要真实的在线语义得另做，
  > 这一条只负责去掉「明明加载失败了还亮绿灯」这个主动骗人的情形。
- **`FormData` 请求重发不可靠**：脚本上传、备份上传的流已被消费过，401 续期后重发大概率失败。改动前后都存在。
