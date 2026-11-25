# APP v2.0 进度快照

> 用户要求：周用量到 85% 时保存并停止。用量查看：`pwsh -NoProfile -File D:\avaer-wt\m2b-tools\usage.ps1`（接口有限流，别频繁查；主会话的守望日志在当次 scratchpad 的 `usage-log.txt`）。

## Snapshot 2026-11-25 01:10
- **已完成**：第一波 A 组（主题与外壳）。改动在 APP 仓库工作区，**已暂存、未提交**（39 个文件，+4262 / -321）。主会话复跑 `flutter analyze` 7 条 info（= 基线）、`flutter test` 805 个全过。契约见 `wave-a-handoff.md`。
- **第二波工作区已搭好**：scratchpad `appB/b1 … b8`（基线 = HEAD + 第一波补丁，已整体暂存；补丁在 scratchpad `patches/app-waveA.patch`）。分组与文件归属见 `implement.md` 第二波表格。
- **未做**：第一波的网页版截图验收（留到第二波合入后一起做）。
- **本地未发布提交**：`dca0f83`（#27 环境变量更新时间、#28 快捷排序、跳过 web_only）。

## 怎么续
1. 查用量，余量足够再开第二波 8 组（每组一个 general-purpose 代理，Flutter 只在 PowerShell 跑，只跑本组测试）。
2. 收活：每组 `git add -N` 新文件 + `git diff --binary` 导增量 → 打进 APP 仓库 → 在该组工作区 `git add -A`。
3. 合入后：全量 `flutter test`、`flutter analyze`、`flutter build apk`，网页版 + 本地面板截图巡检，一轮限定复核。
4. 若 scratchpad 被清理：从 APP 仓库工作区（已含第一波）重新 `git diff --cached` 导出补丁、重搭工作区即可，第一波不会丢。

## Snapshot 2026-11-25 01:25
- 用量 01:22 读数 **73%**（第一波整组约 2%），09:00 重置。8 组一起开会在中途撞 85%，所以只先开 3 个互不依赖的组：**B3 日志（appB/b3）、B4 概览（appB/b4）、B5 变量（appB/b5）**，代理名 `app-b3-logs` / `app-b4-overview` / `app-b5-envs`。
- 其余 B1 任务列表、B2 任务详情、B6 设置、B7 次级页面、B8 系统集成：工作区已搭好（appB/b1、b2、b6、b7、b8），**未开工**，等 09:00 额度重置后再开。
- 守望：scratchpad `usage-log-watch.ps1`（5 分钟一次，到 85% 退出叫醒主会话），读数在 `usage-log.txt`。
- 若中途触线被停：已开工的三组改动都留在各自 worktree（未暂存部分即本组增量），之后对同名代理 SendMessage「继续」即可续上。

## Snapshot 2026-11-25 01:36
- **B4 概览完成并合入** APP 仓库工作区（15 个文件，未暂存部分；dashboard → overview 迁移，修了 DashboardNotifier.load 未捕获异常；`test/features/overview` 17/17）。同一份增量已同步进未开工的 b1 / b2 / b6 / b7 / b8（因为改了 login 等文件的 import）。
- 收活脚本：scratchpad `appB/collect.sh <组> [未开工的组...]`。
- 用量 01:32 读数 74%。B3、B5 仍在跑。

## Snapshot 2026-11-25 01:45
- **B3 日志完成并合入**（8 个文件；左滑删除 / 多选 / 清理改为 operator+ 才显示；错误行就地解压列表里的 content 取，不额外请求）。已同步进未开工组。
- 用量 01:37 读数仍 **74%**（三组合计约 1%），所以把剩余 5 组也开了：**B1 任务列表（app-b1-tasks）、B2 任务详情（app-b2-detail）、B6 设置（app-b6-settings）、B7 次级页面（app-b7-sweep）、B8 系统集成（app-b8-integration）**，工作区 appB/b1、b2、b6、b7、b8（基线含第一波 + B3 + B4）。
- 组间契约已追加到 `wave-a-handoff.md` 末尾（favoriteTasksProvider / showTaskDetailSheet / runningNotificationEnabledProvider / IntegrationService）。
- 仍在跑：B5 变量（app-b5-envs）+ 上面 5 组。B8 会定一个「搜索任务」快捷方式的 query，收到后要转告 B1。

## Snapshot 2026-11-25 01:50
- **B5 变量完成并合入**（遮蔽规则照搬网页「自动」档；查看 / 复制被遮的值始终要验证，60 秒内不再问；降级走应用锁密码 / 图案，都没设则放行）。`test/features/envs` 126 个通过。
- **待用户确认**：演示稿写的是「开了应用锁才验证」，现在是「始终验证」；要改回只需在 `_ensureRevealAuth` 开头加一个判断。
- 已合入：第一波、B3、B4、B5。仍在跑：B1、B2、B6、B7、B8。

## Snapshot 2026-11-25 02:00
- **B2 任务详情完成并合入**（`showTaskDetailSheet` 与契约一致；月历按面板时区的「今天」；老面板只剩最近日志）。依赖 B1 的 `favorite_tasks_provider.dart`，**B1 合入前任务详情相关文件编译不过属预期**。B1 合入后要复跑：`flutter test test/features/tasks/task_detail_sheet_test.dart test/features/tasks/task_detail_page_test.dart test/features/tasks/task_env_scope_test.dart`。
- 复核时顺带：`core/providers/server_scoped_providers.dart` 的 `invalidateServerScopedProviders` 补一行 `ref.invalidate(taskHealthProvider)`（B2 报告的范围外建议；目前靠 state 里记的面板标识兜底）。
- 已合入：第一波、B2、B3、B4、B5。仍在跑：B1、B6、B7、B8。

## Snapshot 2026-11-25 02:10
- **B6 设置完成并合入**（设置页重写，more_page 改成转发；登录 / 服务器管理 / 应用锁 / 开屏换装）。依赖 B8 的 `integration_settings.dart`，**B8 合入前设置页编译不过属预期**；已告诉 B8：`RunningNotificationSetting` 要无参构造、`supported` / `setEnabled` 可覆写。
- 待主会话处理：B6 建议 `app.dart` 在减少动画时把 `themeAnimationDuration` 设为 0；圆形扩散切明暗没做（要改 app.dart）。应用锁遮罩改成 palette.bg 60% + 24 模糊，截图确认背后内容看不清。
- 已合入：第一波、B2、B3、B4、B5、B6。仍在跑：B1、B7、B8。

## Snapshot 2026-11-25 02:15
- **B7 次级页面完成并合入**（约 319 处颜色换令牌；analyze 基线 7 条 info 全部修掉 → 0；`_User` 改名 `PanelUser`；脚本查看 / 编辑、配置文件、面板日志、依赖安装日志、订阅实时日志 5 个全屏页刻意保留 AppBar）。
- 已合入：第一波、B2、B3、B4、B5、B6、B7。仍在跑：B1（任务列表）、B8（系统集成）。

## Snapshot 2026-11-25 02:25
- **B1 任务列表完成并合入**（常用任务卡片 + 按住运行；任务行去掉「运行」按钮；长按改为弹菜单；「…」收纳批量 / 排序；接上 `/tasks?search=<时间戳>` 快捷方式）。
- 复核时顺带：`invalidateServerScopedProviders` 补 `ref.invalidate(favoriteTasksProvider)`（与 taskHealthProvider 同一处）。
- 已合入：第一波、B1~B7。仍在跑：B8（系统集成，APK 编译中）。B8 合入后跑全量 `flutter test` / `analyze`（B2 的详情页测试、B6 的设置页测试要等 B1 / B8 都在才能编译）。

## Snapshot 2026-11-25 02:15
- **B8 系统集成完成并合入**（quick_actions ^1.1.1、home_widget ^0.10.0、flutter_local_notifications ^22.3.3；安卓小组件 Kotlin + XML；常驻通知；main.dart 加 ThemeModeNotifier.preload 与 IntegrationHost）。**第二波 8 组全部合入**，正在跑全量 analyze / test。用量 02:12 读数 76%。
- **APK 构建坑**（主会话 / 用户要知道）：
  - `flutter build apk` 会用 `D:\软件目录\Android Studio\jbr`（Java 25），Gradle 8.14 报 `What went wrong: 25.0.3`。根治：用户执行 `flutter config --jdk-dir "C:\Program Files\Java\jdk-17"`（改全局配置，代理没动）。
  - 绕法：在 `android\` 里 `.\gradlew.bat assembleDebug --no-daemon`，设 `JAVA_HOME=C:\Program Files\Java\jdk-17`、`ANDROID_HOME=D:\CDriveData\Android\Sdk`，并把 `HTTPS_PROXY` 拆成 `-Dhttps.proxyHost/Port/User/Password` 传给 Gradle（否则下载 storage.googleapis.com 的引擎 jar TLS 失败）。
  - B8 把 `~\.gradle\caches\8.14` 下一批半成品缓存改名为 `*.broken-20261125`（没删，确认无误后可删）；一个 Gradle daemon（PID 17344）没能停掉。
- 待用户决定：安卓 14 起用户能划掉 ongoing 通知，划掉后 30 秒内会再出现，是否接受。

## Snapshot 2026-11-25 02:20
- **第二波全部合入后的全量结果**：`flutter analyze` **No issues**（基线 7 条已被 B7 修掉）；`flutter test` **935 个全过**。
- 进行中：`app-core` 收尾两处核心小改（`invalidateServerScopedProviders` 补 favoriteTasksProvider / taskHealthProvider；减少动画时 `themeAnimationDuration = 0`）。
- 下一步：Flutter web 构建 + 本地面板（5792，v4.0）截图巡检浅 / 深 × 5 Tab + 详情弹层 + 设置子页；一轮限定复核；之后收尾（版本 2.0.0、发布说明、#27 #28 回复、spec）。
- 全部改动在 APP 仓库工作区（第一波已暂存，第二波未暂存），**未提交**。

## Snapshot 2026-11-25 02:30
- app-core 收尾完成（invalidate 补 favorite / health；减少动画时 themeAnimationDuration = 0）。全量 analyze 0、test 935 全过。
- **网页版截图验收完成**（scratchpad `appqa/`：proxy.py 代理到本地 v4.0 面板 5792；`tour3.py light|dark` 登录后截 5 个 Tab；截图在 `appqa/shots/tabs3-*.png`）：浅 / 深 5 个 Tab、详情弹层均与设计稿一致。注意网页版刷新会丢登录态，每轮要重新登录。
- 发现 3 个问题，已交给复核代理 `app-review`：①「所有任务」后数量与「条」字重叠；② 登录页输入框白卡里套灰色填充；③ 网页版登录后有未捕获 JS 错误（疑似 integration 插件在 web 无实现，需 kIsWeb 防护）。另有 web 专属的 User-Agent 警告。
- 下一步：复核修完 → 主会话复跑 analyze / test、重建 web 复看 → 用 gradlew 构建 APK → 收尾（版本 2.0.0、发布说明、#27 #28 回复）。**提交与发版等用户醒来确认**（改版面大，先让用户看效果）。

## Snapshot 2026-11-25 02:45
- **复核（app-review）修了**：①「所有任务」数量与横滑按钮区被裁的「序」字贴在一起 → 加间距 + 左缘渐隐；② 登录页 3 个输入框 `filled: false`（脚本「查找代码」条同类问题一并修）；③ 网页版 JS 错误真源是应用锁 `getAvailableBiometrics` 的 MissingPluginException（旧问题）→ 补 catch，env_secret 同类补上；web 不再设 User-Agent 头；④ **Manifest 关掉 Flutter 默认深链**（否则小组件 `daidai://` 被 GoRouter 当路由 → 页面不存在）；⑤ IntegrationService `_findTask` 原来请求不存在的 `GET /tasks/:id` → 改 `GET /tasks?all=1` 按 id 找。analyze 0、test 936 全过。
- 正在修：概览「最慢 / 最常失败」卡改走 `showTaskDetailSheet`（原来 push 详情路由，没进过任务页时会显示「任务不存在」）。
- **只报告未改（给用户看）**：开屏 / 登录会预加载 dashboard（v2.0 一次 6 组请求，默认落点已是任务页）；退出登录后小组件快照不清（桌面仍显示上一台面板的任务名）；任务页 1 秒时钟、日志页 5 秒轮询在 APP 进后台时不暂停（离开页面会停）。
- 待真机验证：小组件四个点按区、快捷方式冷启动弹详情、常驻通知。

## Snapshot 2026-11-25 03:00 —— 今晚收工（等用户醒来确认）
- **全部实现完成并验证**：第一波 + 第二波 8 组 + 复核修复都在 APP 仓库工作区（第一波已暂存，其余未暂存），**未提交、未改版本号**。
  - `flutter analyze` No issues；`flutter test` **939 个全过**（改版前 728）。
  - Flutter web + 本地 v4.0 面板截图：浅 / 深 5 个 Tab、详情弹层与设计稿一致；登录页双层背景、任务页标题重叠已修；清掉 Service Worker 缓存后登录并切完 5 个 Tab，控制台 0 错误。
  - 安卓 debug APK：`android\` 下 `gradlew assembleDebug` 成功（脚本 scratchpad `appqa/build_apk.ps1`：JDK 17 + ANDROID_HOME + 代理拆成 -D 参数），产物 `build\app\outputs\flutter-apk\app-debug.apk`（159 MB）。
- **已清理**：第二波 worktree 已从 git 注销（scratchpad 下 b1 / b8 目录有删不掉的残留，不影响）；本地面板 5792、代理 5780、无头 Chrome、用量守望都已停。
- **需要用户决定 / 确认**（醒来后）：
  1. 看效果：装 `app-debug.apk` 到手机，或看截图 scratchpad `appqa/shots/tabs3-light.png`、`tabs3-dark.png`。
  2. 变量查看：现在是「始终验证」，演示稿是「开了应用锁才验证」。
  3. 安卓 14 起常驻通知可被划掉、30 秒内会再出现，是否接受。
  4. 只报告未改的三条：开屏预加载概览数据（6 组请求）；退出登录后小组件仍显示旧面板任务名；任务页 1 秒时钟 / 日志页 5 秒轮询在后台不暂停。
  5. 真机验证：小组件四个点按区、快捷方式冷启动弹详情、常驻通知、指纹验证降级。
  6. `flutter build apk` 直接跑会用 Java 25 失败，建议用户执行一次 `flutter config --jdk-dir "C:\Program Files\Java\jdk-17"`；B8 挪开的 Gradle 缓存 `~\.gradle\caches\8.14\*.broken-20261125` 确认无误后可删。
- **收尾待做**（用户确认后）：版本 2.0.0（pubspec `2.0.0+37`、README、`docs/release-notes/v2.0.0.md` 含 #27 #28）、spec 沉淀、提交、APP #27 #28 回复（#28 的复制粘贴英文请用户补截图）。
- 用量：最后读数 02:12 为 76%（09:00 重置）。

## Snapshot 2026-11-25（用户醒来后）
- 用户决定：① 变量查看改回「开了应用锁才验证」；② 常驻通知由用户选择开不开（开关本就默认关），补「用户划掉后、运行中任务集合不变就不再重发」；③ 三个小问题由我决定 —— 都做：开屏 / 登录只轻量预加载、退出登录 / 切面板清小组件快照、任务页时钟与日志页轮询后台暂停。
- 正在做：代理 `app-tweaks` 一次改完以上 5 项。完成后：主会话复跑 analyze / test、重建 APK → 收尾（版本 2.0.0、发布说明、spec、提交、#27 #28 回复）。
