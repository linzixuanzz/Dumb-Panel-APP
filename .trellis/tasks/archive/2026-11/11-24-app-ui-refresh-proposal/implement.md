# APP v2.0 实施计划

## 执行方式

- 两波。每组一个有 shell 的代理，在 scratchpad 的手动 worktree 里工作（基线 = HEAD + 前一波改动，整体 `git add -A` 暂存；收活时 `git add -N` 新文件 + `git diff` 导增量）。**组间文件零重叠**。
- Flutter 只在 **PowerShell** 里跑：`$env:PATH = "D:\flutter-sdk\bin;" + $env:PATH`。worktree 首次先 `flutter pub get`。
- 代理只跑 `flutter analyze` 与**本组相关**的测试（多组并发会抢 Flutter 启动锁）；全量 `flutter test`、`flutter build apk`、浏览器 / 模拟器验收由主会话合入后统一做。
- 不改版本号、不写发布说明、不 `git add` / commit。

## 第一波：地基（1 组）

### A · 主题与外壳（FE-Core）

只能改：
- `lib/core/theme/**`
- `lib/shared/widgets/**`（新增 §2 组件；既有组件换令牌、签名不变）
- `lib/app.dart`
- `lib/core/router/**`（含 `default_landing_page.dart`）
- 新建 `lib/shared/api/panel_insights.dart`、`lib/shared/models/insights.dart`；`lib/core/network/api_endpoints.dart` 只加新接口常量
- 新建占位页 `lib/features/overview/views/overview_page.dart`、`lib/features/settings/views/settings_page.dart`（第二波 B4 / B6 接手重写）
- 对应测试：`test/core/**`、`test/shared/**`，以及因路由 / 底栏改名而必须同步的既有测试（只改断言里的文案和路由，不改测试意图，逐条在交接说明里列出）

产出：design §1 ~ §4 全部；明暗设置 provider；5 个 Tab 外壳与兼容重定向；默认打开页面映射；v4 接口客户端与形状探测；共享组件的 widget test。

**第一波验收（主会话）**：`flutter analyze`、`flutter test` 全过；Flutter web 构建 + 本地面板实例截图，浅 / 深各看 5 个 Tab 的外壳与组件。

## 第二波（并行 8 组）

| 组 | 只能改 | 内容 |
|---|---|---|
| B1 任务列表 | `features/tasks/views/task_list_page.dart`、`features/tasks/providers/**`（不含新建的 `task_health_provider.dart`）、`features/tasks/widgets/task_view_sheets.dart`、新建 `features/tasks/widgets/favorite_*.dart` | 问候 + 常用任务卡片（`NotchedCard` + `HoldToRunButton`）+ `favoriteTasksProvider`；所有任务分组列表换装（下次运行倒计时）；保留筛选 / 视图 / 分组 / 快捷排序 / 拖拽 / 批量；点任务调 `showTaskDetailSheet` |
| B2 任务详情与表单 | `features/tasks/views/task_detail_page.dart`、`features/tasks/views/task_form_page.dart`、新建 `features/tasks/widgets/task_detail_sheet.dart`、`features/tasks/widgets/task_health_*.dart`、`features/tasks/providers/task_health_provider.dart` | A3 详情弹层（统计、月历、最近日志、按住运行；老面板降级）；`showTaskDetailSheet` 契约；详情页路由复用同一内容；表单换装 |
| B3 日志 | `features/logs/**`、`shared/widgets/log_view.dart`（只换色） | A5：一句话总结、四色筛选方块、趋势细线图（今天按已过时长折算）、失败行显示错误行、左滑删除；日志流页换装 |
| B4 概览 | `features/dashboard/**` → 迁到 `features/overview/**`（含占位页重写） | A4：渐变总览卡、最慢任务、最常失败（attention，老面板隐藏）、每月执行柱状图、服务器资源 |
| B5 变量 | `features/envs/**` | 换装（大标题、搜索、按分组的分组列表）；A6 敏感值遮蔽 + 指纹 / 设备密码验证后查看或复制；保留拖拽排序、置顶、重要、导入导出、#27 更新时间 |
| B6 设置与入口 | `features/settings/**`（含占位页重写，`more_page.dart` 内容迁入后删除或改为转发）、`features/app_lock/**`、`features/server_config/**`、`features/login/**` | 星空个人卡、外观（浅 / 深预览卡 + 跟随系统，读写 `themeModeProvider`）、默认打开页面新选项、小组件与快捷方式说明 + 常驻通知开关（调 B8 的设置项）、管理入口；登录、服务器管理、应用锁换装 |
| B7 次级页面换装 | `features/scripts/**`、`features/subscriptions/**`、`features/deps/**`、`features/notifications/**`、`features/users/**`、`features/security/**`、`features/openapi/**`、`features/system/**` | 写死颜色改令牌、大标题头、分组列表、胶囊按钮；不改业务逻辑 |
| B8 系统集成 | `pubspec.yaml`、`android/**`、`ios/Runner/Info.plist`、`lib/main.dart`、新建 `lib/core/integration/**` | design §6：快捷方式、桌面小组件（Kotlin + XML）、常驻通知；`IntegrationService` 契约；设置项 provider 给 B6 用 |

> 组间依赖都按 design §5 契约 import：B1 ↔ B2（`showTaskDetailSheet`、`favoriteTasksProvider`），B6 → B8（常驻通知开关），B8 → B1（常用任务）。本组工作区里还不存在的文件按契约写，自查时只因它们缺失的报错属预期。

**第二波验收（主会话）**：
1. `flutter analyze`（≤ 7 条 info）、`flutter test` 全过、`flutter build apk` 成功。
2. Flutter web + 本地面板（v4.0 与 v3.4.x 各一套）：浅 / 深 × 5 个 Tab + 详情弹层 + 设置子页截图巡检；按住运行、切 Tab、明暗切换、减少动画。
3. 安卓原生部分：APK 安装到模拟器或真机（若可用）验证快捷方式、小组件、常驻通知；不可用时在交接说明中标「未真机验证」。
4. 一轮限定范围复核（只找跨组交界问题）→ 修 → 主会话复跑。

## 收尾

- 版本 2.0.0：`pubspec.yaml`（`2.0.0+37`）、README、`docs/release-notes/v2.0.0.md`（含 #27 #28）、`NEXT.md` 归档。
- 回复 APP #27、#28（#28 的「复制粘贴英文」请用户补截图）。
- spec 沉淀：`component-guidelines.md` 加「v2.0 令牌与共享组件」一节。
- 推送与关 issue 由用户执行。
