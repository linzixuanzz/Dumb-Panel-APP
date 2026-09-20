# 目录结构

> `lib/` 下的真实分层与文件组织。所有结论来自当前代码。

---

## 总览

```
lib/
├── main.dart              (47 行)  启动引导：UA 初始化 → 恢复 baseUrl → **迁移凭据 scope** → 注入拦截器 → 恢复登录态 → runApp
├── app.dart               (26 行)  MaterialApp.router：主题、locale、AppLockGate
├── core/      14 个文件            应用级基础设施（网络 / 认证 / 存储 / 路由 / 主题 / 服务 / 跨 feature provider）
├── features/  16 个模块            业务功能，按领域切分
└── shared/                        跨 feature 复用：models / utils / widgets
```

> ⚠️ **不要拿本文里的文件数当清单用，也不要新增这类总数**。
> 这份总览此前写的「合计 59 个 dart 文件」就被当成清单用过一次，而实测是 93 个；
> 下面几节标题里的括号数字（`shared/` 的「15 个文件」等）同样早已漂移，别照着信。
> 要数文件请直接 `glob lib/**/*.dart`。本文真正的内容是**分类与约定**，
> 括号里的行数只是定位线索，会随任何改动漂移。

> `main.dart` 里 `migrateLegacyAuthScope()` 的位置是硬要求（必须夹在 `setBaseUrl` 与
> `restoreTrustedLocalSession()` 之间），理由见 [hook-guidelines.md](./hook-guidelines.md)
> 的「凭据按面板 scope 分片」。

---

## `lib/core/` — 基础设施（14 个文件）

| 子目录 | 文件 | 职责 |
|---|---|---|
| `network/` | `dio_client.dart` (64) | dio 单例 + `rawDio` 工厂 |
| | `api_endpoints.dart` (193) | **全部** REST 路径常量 |
| | `sse_client.dart` | SSE 长连接，走 `package:http`，**不经过 dio**；401 走 `TokenRefresher` 续期后重连一次 |
| | `app_user_agent.dart` (195) | UA 与 `X-Client-*` 头，`initialize()` 在 `main()` 首行调用 |
| `auth/` | `auth_provider.dart` (231) | `AuthNotifier` / `AuthState` / `authProvider` |
| | `auth_service.dart` (160) | 登录、初始化、改密、健康检查 |
| | `auth_interceptor.dart` | Bearer 注入 + 401 排队重发（续期动作委托给 `TokenRefresher`） |
| | `token_refresher.dart` | **全仓库唯一**的 access token 续期入口，单飞（dio 与 SSE 共用） |
| `storage/` | `secure_storage.dart` (384) | `FlutterSecureStorage`（token/user/panels）+ `SharedPreferences`（serverUrl/UI 状态）；token/user/可信期**按面板 scope 分片**，见 hook-guidelines |
| `router/` | `app_router.dart` (259) | `routerProvider`、全部 `GoRoute`、`redirect` 鉴权 |
| `theme/` | `app_theme.dart` (272) | `AppColors` 色板（含 `success`/`info`/`danger`/`warning`/`neutral` 语义状态色）+ `AppTheme.light()/dark()` |
| | `design_tokens.dart` | `AppRadius` / `AppSpacing` / `AppBorderWidth` / `AppSurfaces` / `AppTapTarget` |
| `services/` | `app_update_service.dart` | APP 自身版本检查、下载与内置安装（原生通道的 Dart 侧，见文末「android/ 原生侧与平台通道」） |
| `providers/` | `server_scoped_providers.dart` | `invalidateServerScopedProviders(ref)`：切面板 / 退出登录时一次失效 10 个服务器级 provider（v1.3.7 / issue #13）。**它天然要 import 全部 feature 的 provider**，同类先例是 `router/app_router.dart` |

**约定**：`core/` 里的东西被多个 feature 依赖，且**不含业务语义**。
新增基础能力先问：是否有 2 个以上 feature 会用？否则放进对应 feature。

---

## `lib/features/` — 业务模块（16 个）

```
features/
├── app_lock/       views/ providers/ widgets/   (3 文件)
├── dashboard/      views/ providers/ widgets/   (5 文件)
├── deps/           views/                       (1 文件, 1776 行)
├── envs/           views/                       (1 文件, 2235 行)
├── login/          views/ widgets/              (3 文件)
├── logs/           views/                       (2 文件)
├── notifications/  views/                       (1 文件, 993 行)
├── openapi/        views/                       (1 文件, 1264 行)
├── scripts/        views/                       (1 文件, 2868 行)
├── security/       views/                       (1 文件, 1249 行)
├── server_config/  views/                       (1 文件)
├── settings/       views/                       (3 文件：more / sponsor / about)
├── subscriptions/  views/                       (1 文件, 1737 行)
├── system/         views/                       (3 文件)
├── tasks/          views/ providers/            (3 文件, 其中 task_list_page.dart 3178 行)
└── users/          views/                       (1 文件)
```

### feature 内部结构：**没有统一约定**

这是仓库现状，如实记录：

| 子目录 | 出现在哪些 feature | 说明 |
|---|---|---|
| `views/` | **全部 16 个** | 唯一稳定的约定 |
| `providers/` | 仅 3 个：`tasks`、`dashboard`、`app_lock` | 其余 13 个把 provider 写在 view 文件顶部 |
| `widgets/` | 仅 3 个：`dashboard`、`app_lock`、`login` | 其余把私有子组件写在同一个 view 文件里 |
| `utils/` | 仅 1 个：`notifications` | `channel_config.dart`：从弹窗闭包里抽出来的纯数据变换，**为了可测** |
| `models/` | **0 个** | feature 私有模型要么在 `shared/models/`，要么是 view 文件里的私有 class |

> `features/notifications/utils/channel_config.dart` 是第 0 期 R5 抽的：
> 「读取-修改-回写」的合并规则原来写在 `showModalBottomSheet` 的闭包里，
> 不起 UI 就没法断言，而它恰恰是**改错了用户会丢配置**的地方。
> 以后遇到同类情况（纯数据变换被 UI 闭包裹住），照这个做法抽到 feature 的 `utils/`，
> **只搬不改**，行为变更要单独一次改动。

**两种并存写法**：

- A 式（独立 providers 目录）：`lib/features/tasks/providers/task_provider.dart:246`
  ```dart
  final taskProvider = StateNotifierProvider<TaskNotifier, TaskListState>((ref) => TaskNotifier());
  ```
- B 式（provider 写在 view 文件顶部，占多数）：`lib/features/envs/views/env_list_page.dart:12`
  ```dart
  final envListProvider = StateNotifierProvider<EnvListNotifier, EnvListState>((ref) => EnvListNotifier());
  ```
  同类还有 `log_list_page.dart:13`、`dep_list_page.dart:17`、`script_list_page.dart:21`、
  `user_list_page.dart:13`、`notification_list_page.dart:13`、`subscription_list_page.dart:18`。

> **给新代码的指引**：新建 feature 时优先用 A 式（`providers/` 独立目录），
> 它让 view 文件不至于继续膨胀。但**改动既有 feature 时不要顺手迁移**——
> B 式是当前多数派，无谓的搬迁会让 diff 难审。

### 单文件超长是常态

7 个 view 文件超过 1000 行，最长 `task_list_page.dart` 3178 行。
这些文件内部同时包含：provider 定义、State 类、Notifier、页面、私有卡片组件、
私有模型、私有工具函数。**这是现状，不是推荐做法。**
新增大块 UI 时，优先拆到 `widgets/` 而不是继续往 view 文件里追加。

---

## `lib/shared/` — 跨 feature 复用（15 个文件）

### `shared/models/`（9 个）

`api_response.dart`、`dependency.dart`、`env_var.dart`、`notify_channel.dart`、
`python_runtime_info.dart`、`subscription.dart`、`task.dart`、`task_log.dart`、`user.dart`

判定标准（观察得出）：**被 2 个以上 feature 或被 `core/` 引用**的响应模型放这里。
只有一个页面用的模型，仓库现状是写成该 view 文件里的私有 class：

- `_User`（`lib/features/users/views/user_list_page.dart:68`，注意**同时**存在 `shared/models/user.dart` 的公开 `User`）
- `_BackupFileRecord`、`_BackupSelection`、`_CreateBackupRequest`（`backup_page.dart:166/239/401`）
- `_TaskNotificationChannel`（`task_form_page.dart:89`）
- `_CreateDepRequest`（`dep_list_page.dart:469`）

> `_User` 与 `User` 并存是真实的重复，且触发了 lint（见 quality-guidelines）。
> 新代码不要再制造这种同名影子模型。

### `shared/utils/`（6 个）

| 文件 | 导出 | 被引用 |
|---|---|---|
| `api_utils.dart` | `extractData` / `extractPaginated` / `extractErrorMessage` / `extractScriptSaveErrorMessage` / `extractListErrorMessage` | 22 个文件、92 处 |
| `time_utils.dart` | `formatTimeCn(DateTime?, {short})` | 统一中文时间格式，注释明确「避免页面里混用 MM-dd」 |
| `ansi_text.dart` | 日志 ANSI 转义 → `TextSpan` | 日志与依赖页 |
| `log_background.dart` | 日志终端背景色 | 日志相关页 |
| `panel_enums.dart` | 面板枚举换算（任务状态 / 日志状态 / 依赖类型与状态 / 任务类型） | models 委托过来；**未知值一律回吐原始值**，见 panel-contract.md |
| `duration_utils.dart` | `formatDurationSeconds(num?)` | 耗时显示，与面板 `web/src/utils/duration.ts` **逐字对齐**（同为向下截断） |

> ⚠️ `duration_utils` 的函数名带 `Seconds` 是有意的：本仓库存在一个毫秒字段
> （`open_app_logs.duration`，服务端是 `.Milliseconds()`），名字带单位是防误用的有效防线。
>
> 这两个新文件都是**纯函数、不 import Flutter**，所以可以直接单测
> （`test/shared/panel_enums_test.dart`、`test/shared/duration_utils_test.dart`）。
> 新增这类换算逻辑时照这个形状放，不要长在 model 的 getter 里。

### `shared/widgets/`

| 文件 | 内容 | 状态 |
|---|---|---|
| `main_scaffold.dart` | 底部导航（自绘 `_NavItem`，未用 `NavigationBar`）+ **5 秒内双击返回退出**（`_handleBackPress` 里的 `PopScope`；提示条第 1 期已迁到 `AppSnack`） | 既有 |
| `task_cron_list.dart` | Cron 规则展示卡片 | 既有 |
| `app_card.dart` | `AppCard`：统一卡片容器（底色/描边/圆角走令牌） | 第 0 期 R4 新增 |
| `app_state_views.dart` | `AppLoadingView` / `AppEmptyView` / `AppErrorView`：列表三态 | 第 0 期 R4 新增 |
| `app_snack.dart` | `AppSnack.show/success/error/warn()` + `AppSnackTone`：替代 8 处逐字重复的 `_showMessage`，并区分成功 / 失败 / 警告 | 第 0 期 R4 新增，第 1 期加 tone |
| `app_buttons.dart` | `AppChipButton` / `AppTintedActionButton`：头部 chip 与批量操作按钮 | 第 0 期 R4 新增 |
| `app_section_title.dart` | `AppSectionTitle`：设置类页面的区块小标题 | 第 0 期 R4 新增 |

配套令牌在 `lib/core/theme/design_tokens.dart`：`AppRadius` / `AppSpacing` /
`AppBorderWidth` / `AppSurfaces`。**新代码写卡片、空态、错误态、提示条时先用这一层，
不要再手写 `BoxDecoration` + `isLight` 三元。**

第 0 期只做了示范迁移（任务 / 日志 / 环境变量 / 系统设置 / 更多 五个页面），
其余页面仍是各写一遍的旧形态，第 1 期继续收敛。

> ⚠️ 改造 `main_scaffold.dart` 时**不得丢掉双击返回退出**（`:29-50`）。

---

## 命名约定（全库一致，可直接照抄）

| 对象 | 规则 | 例 |
|---|---|---|
| 文件 | `snake_case.dart` | `task_list_page.dart` |
| 页面 widget | `XxxPage` | `TaskListPage`、`EnvListPage` |
| Notifier | `XxxNotifier`（`app_lock` 例外，叫 `AppLockController`） | `TaskNotifier` / `AppLockController` (`app_lock_provider.dart:463`) |
| State 类 | `XxxState`；dashboard 例外叫 `DashboardData` | `TaskListState` / `DashboardData` (`dashboard_provider.dart:25`) |
| provider 变量 | `xxxProvider`，顶层 `final` | `taskProvider`、`envListProvider` |
| 私有 widget | `_XxxCard` / `_XxxItem` / `_XxxTab` | `_TaskCard`、`_NavItem`、`_TwoFaTab` |
| 端点常量 | `ApiEndpoints.xxx`，带参数的写成静态方法 | `ApiEndpoints.taskById(int id)` |

## import 约定

全部使用**相对路径**，无 `package:daidai_app/...` 形式：

```dart
// lib/features/tasks/providers/task_provider.dart:3-7
import '../../../core/network/dio_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/task.dart';
```

顺序习惯：`dart:` → `package:` → 相对路径（未强制，`analysis_options.yaml` 未开 `directives_ordering`）。

---

## `android/` 原生侧与平台通道

本仓库的原生 Kotlin 代码**只有一个文件**：
`android/app/src/main/kotlin/com/daidai/panel/MainActivity.kt`，
里面是 `MainActivity`（平台通道 handler）与 `InstallResultReceiver`（安装结果广播接收器）。

### 全 APP 只有一条平台通道

```
com.daidai.panel/app_install
```

| 方法 | 入参 | 干什么 |
|---|---|---|
| `installApk` | `path`、`sourceHost` | 内置安装下载好的 APK |
| `openUnknownSourceSettings` | — | 把用户送到「允许安装未知应用」授权页 |
| `openUrl` | `url` | 用系统浏览器打开外链（关于页那几个写死的仓库/issue 链接） |

> **通道名是历史名字**。`openUrl` 与安装毫无关系，但它仍挂在这条通道上——
> 这里的约定是：**`com.daidai.panel/app_install` 就是「本 APP 唯一的原生平台通道」**，
> 新增任何原生能力一律挂它，**不要再开第二条**。多开一条只会让 Dart 侧多一份
> `MethodChannel` 常量、原生侧多一个 handler 注册点，而它们必须逐字对齐。
>
> Dart 侧目前有两处各自 `const MethodChannel('com.daidai.panel/app_install')`：
> `core/services/app_update_service.dart` 与 `features/settings/views/about_page.dart`。

### 内置安装走 `PackageInstaller` Session API，**不是** `Intent(ACTION_VIEW)`

这是硬约定，别「简化」回 Intent：`targetSdk 36 ≥ 30` 会按包可见性过滤 Intent 的候选列表，
系统安装器对本 APP 不可见，`ACTION_VIEW` 解析出空集并抛 `ActivityNotFoundException`
——这正是 issue #11 的报错。`PackageInstaller` 由本进程把 APK 字节写进会话，
全程不做 Intent 解析，对「包可见性 / ROM 纯净模式 / 第三方安装器缺失」三种成因都免疫。

Manifest 里那条 `<queries>` 的 `ACTION_VIEW` + `application/vnd.android.package-archive`
是留给可能的回退路径兜底的，**不要**用 `QUERY_ALL_PACKAGES` 去绕——那是大锤，
也改不了 ROM 侧禁用安装器的情况。

配套的三条硬要求：

- `InstallResultReceiver` 必须在 Manifest 里以 `android:exported="false"` 声明。
  它和 `MainActivity` 不是同一个实例，只能靠 `companion object` 的静态字段传递待回调的
  `MethodChannel.Result`，这是这套 API 的标准用法。
- 回调用的 `PendingIntent` 在 API 31+ **必须带 `FLAG_MUTABLE`**（系统要往里回填安装状态，
  不带会被直接拒绝），且它的 `Intent` 必须**显式指明组件**——显式 Intent 才不会踩
  Android 14「可变 PendingIntent 不能配隐式 Intent」那条限制。
- 解析整包验签 + 拷贝几十 MB 字节要跑在子线程，留在平台主线程必 ANR。

### 错误码是两侧共同的契约

`installApk` 的错误码与 `core/services/app_update_service.dart` 的 `_installErrorText`
**一一对应，改一侧必须同时改另一侧**。当前 7 个：

`NO_INSTALLER` / `NEED_UNKNOWN_SOURCE` / `VERIFY_FAILED` / `FILE_MISSING` /
`PATH_NOT_ALLOWED` / `UNTRUSTED_SOURCE` / `SESSION_FAILED`

漏配不会崩，只会退化成把英文原文摊给用户看（可接受的降级，但不要留着）。

`openUrl` 的错误码是 `INVALID_URL` / `NO_BROWSER`，**Dart 侧刻意不区分这两个码**，
一律退回「复制链接 + `AppSnack.warn`」——对用户来说两种情况的下一步动作是同一个。

### `openUrl` 的两条约定

- **只放行 `https://` 前缀**。放开 scheme 等于让 Dart 侧任意字符串都能拉起任意组件
  （`intent://`、`file://` 都塞得进来），是白送的注入面（issue #12 / v1.3.7）。
- **不需要给它加 `<queries>` 声明**。`startActivity` 不受 Android 11 包可见性过滤，
  受限的是 `queryIntentActivities` / `resolveActivity` 这类**查询** API。
  这是下一个人最容易误加 `<queries>` 的地方。

> 仓库**刻意不引 `url_launcher`**：引入会改 `GeneratedPluginRegistrant`，
> 意味着必须重跑 `flutter build apk` 才敢发版。为了几个写死的外链不值得。

> 🔴 改了 `android/` 下任何东西，`flutter analyze` 都**看不见**。
> 必须另跑构建验证，见 [quality-guidelines.md](./quality-guidelines.md)。
