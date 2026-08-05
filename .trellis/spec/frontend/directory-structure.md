# 目录结构

> `lib/` 下的真实分层与文件组织。所有结论来自当前代码。

---

## 总览

```
lib/
├── main.dart              (38 行)  启动引导：UA 初始化 → 恢复 baseUrl → 注入拦截器 → 恢复登录态 → runApp
├── app.dart               (26 行)  MaterialApp.router：主题、locale、AppLockGate
├── core/      11 个文件            应用级基础设施（网络 / 认证 / 存储 / 路由 / 主题 / 服务）
├── features/  16 个模块 / 31 个文件 业务功能，按领域切分
└── shared/    15 个文件            跨 feature 复用：models 9 / utils 4 / widgets 2
```

合计 59 个 dart 文件、约 30,676 行。

---

## `lib/core/` — 基础设施（11 个文件）

| 子目录 | 文件 | 职责 |
|---|---|---|
| `network/` | `dio_client.dart` (64) | dio 单例 + `rawDio` 工厂 |
| | `api_endpoints.dart` (193) | **全部** REST 路径常量 |
| | `sse_client.dart` (134) | SSE 长连接，走 `package:http`，**不经过 dio** |
| | `app_user_agent.dart` (195) | UA 与 `X-Client-*` 头，`initialize()` 在 `main()` 首行调用 |
| `auth/` | `auth_provider.dart` (231) | `AuthNotifier` / `AuthState` / `authProvider` |
| | `auth_service.dart` (160) | 登录、初始化、改密、健康检查 |
| | `auth_interceptor.dart` (115) | Bearer 注入 + 401 续期排队重发 |
| `storage/` | `secure_storage.dart` (327) | `FlutterSecureStorage`（token/user/panels）+ `SharedPreferences`（serverUrl/UI 状态） |
| `router/` | `app_router.dart` (257) | `routerProvider`、全部 `GoRoute`、`redirect` 鉴权 |
| `theme/` | `app_theme.dart` (237) | `AppColors` 色板 + `AppTheme.light()/dark()` |
| `services/` | `app_update_service.dart` (393) | APP 自身版本检查与更新对话框 |

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
├── settings/       views/                       (2 文件)
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
| `models/` | **0 个** | feature 私有模型要么在 `shared/models/`，要么是 view 文件里的私有 class |

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

### `shared/utils/`（4 个）

| 文件 | 导出 | 被引用 |
|---|---|---|
| `api_utils.dart` (100) | `extractData` / `extractPaginated` / `extractErrorMessage` / `extractScriptSaveErrorMessage` | 22 个文件、92 处 |
| `time_utils.dart` (17) | `formatTimeCn(DateTime?, {short})` | 统一中文时间格式，注释明确「避免页面里混用 MM-dd」 |
| `ansi_text.dart` (298) | 日志 ANSI 转义 → `TextSpan` | 日志与依赖页 |
| `log_background.dart` (95) | 日志终端背景色 | 日志相关页 |

### `shared/widgets/`（**只有 2 个**）

| 文件 | 行数 | 内容 |
|---|---|---|
| `main_scaffold.dart` | 185 | 底部导航（自绘 `_NavItem`，未用 `NavigationBar`）+ **5 秒内双击返回退出**（`:29-50` `PopScope`） |
| `task_cron_list.dart` | 139 | Cron 规则展示卡片 |

**这就是「没有共享组件层」的直接证据**：卡片容器、空状态、错误态、chip、
统计块等基元全部在各 feature 里各写一遍。第 0 期 R4 正在补这一层。

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
