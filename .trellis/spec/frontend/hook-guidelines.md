# Riverpod Provider 与数据获取约定

> **文件名说明**：`hook-guidelines.md` 来自 `trellis init` 的 React 模板。
> 本仓库是 Flutter，没有 React hooks，也**未使用** `flutter_hooks`。
> 文件名保留是为了不破坏 Trellis 的 spec 注入路径，**内容已整体改写**为
> 本仓库真实的 riverpod provider 与网络层约定。
>
> 状态形态（State 类、`copyWith`、错误态）见 [state-management.md](./state-management.md)。
> 本文只讲 **provider 的定义方式** 与 **数据怎么取回来**。

---

## 只用两种 provider

全库 riverpod provider 共 14 个，只有两种类型：

| 类型 | 数量 | 用途 |
|---|---|---|
| `StateNotifierProvider<XxxNotifier, XxxState>` | 11 | 所有列表页 / 仪表盘 / 认证 / 应用锁 |
| `Provider<T>` | 3 | 无状态服务与桥接：`authServiceProvider`、`routerProvider`、`_authNotifierProvider` |

**没有使用**：`FutureProvider`、`StreamProvider`、`StateProvider`、`ChangeNotifierProvider`、
`NotifierProvider` / `AsyncNotifierProvider`（riverpod 2.x 新 API）、`.family`、`.autoDispose`、
`@riverpod` 代码生成。

> 这意味着：**没有 `AsyncValue`**。加载/错误状态是手写字段，不是 `AsyncValue.when()`。
> 新代码请沿用现有形态，除非有明确理由并同步更新本文档。

### 完整清单

| provider | 位置 |
|---|---|
| `authServiceProvider` (`Provider`) | `core/auth/auth_provider.dart:227` |
| `authProvider` | `core/auth/auth_provider.dart:229` |
| `routerProvider` (`Provider`) | `core/router/app_router.dart:47` |
| `_authNotifierProvider` (`Provider`, 私有) | `core/router/app_router.dart:43` |
| `taskProvider` | `features/tasks/providers/task_provider.dart:246` |
| `dashboardProvider` | `features/dashboard/providers/dashboard_provider.dart:121` |
| `appLockProvider` | `features/app_lock/providers/app_lock_provider.dart:463` |
| `envListProvider` | `features/envs/views/env_list_page.dart:12` |
| `logListProvider` | `features/logs/views/log_list_page.dart:13` |
| `depListProvider` | `features/deps/views/dep_list_page.dart:17` |
| `scriptProvider` | `features/scripts/views/script_list_page.dart:21` |
| `userListProvider` | `features/users/views/user_list_page.dart:13` |
| `notificationListProvider` | `features/notifications/views/notification_list_page.dart:13` |
| `subscriptionListProvider` | `features/subscriptions/views/subscription_list_page.dart:18` |

---

## Notifier 的标准形态

```dart
// lib/features/tasks/providers/task_provider.dart:55-85, 246-248
class TaskNotifier extends StateNotifier<TaskListState> {
  TaskNotifier() : super(const TaskListState());   // 无参构造，不注入依赖

  Future<void> load({bool refresh = false}) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final dio = DioClient.instance.dio;           // 直接摸单例，不经 ref.read
      final response = await dio.get(ApiEndpoints.tasks, queryParameters: queryParams);
      final paginated = extractPaginated(response.data);
      final items = paginated.items.map((e) => Task.fromJson(e)).toList();
      state = state.copyWith(tasks: items, total: paginated.total, loading: false);
    } catch (e) {
      state = state.copyWith(loading: false, error: '加载失败');
    }
  }
}

final taskProvider = StateNotifierProvider<TaskNotifier, TaskListState>((ref) {
  return TaskNotifier();
});
```

### 三条关键约定

1. **Notifier 不接受依赖注入，直接用 `DioClient.instance.dio`**。
   唯一例外是 `AuthNotifier`，它通过 `ref.read(authServiceProvider)` 拿 service
   （`core/auth/auth_provider.dart:229-231`）。这也是**唯一有 service 层的 feature**——
   其余 feature 的 Notifier 直接发 HTTP，没有中间层。
   > 副作用：这些 Notifier 无法被单测替换掉网络，是第 0 期 R5 补测试时的主要障碍。

2. **写操作后统一 `await load()` 全量重拉**，不做本地乐观更新：
   ```dart
   // lib/features/tasks/providers/task_provider.dart:106-129
   Future<void> runTask(int id) async {
     await DioClient.instance.dio.put(ApiEndpoints.taskRun(id));
     await load(refresh: true);
   }
   ```
   例外只有拖拽排序会先改本地再提交（`task_provider.dart:179-187` `reorderLocalTasks`、
   `env_list_page.dart:227-233` `reorderLocal`）。

3. **写操作方法本身不 try/catch，异常向上抛给 UI**。
   UI 侧用 `try { await ... } catch (error) { _showActionError(error, '...'); }`
   （`task_list_page.dart:232/253/291/308/322/331/345/1539`）。
   只有 `load()` 这类读操作在 Notifier 内部吞掉异常。

---

## UI 侧读取 provider

```dart
// 读状态（build 内）
final state = ref.watch(taskProvider);

// 调方法（回调内）
await ref.read(taskProvider.notifier).runTask(task.id);

// 只订阅某个字段（仅路由桥接用过）
ref.listen<AuthStatus>(authProvider.select((s) => s.status), (prev, next) => notifyListeners());
```

`select` 全库只在 `core/router/app_router.dart:36-39` 用过一次。

### 首次加载在 `initState` 里发起

```dart
// 各列表页统一写法
@override
void initState() {
  super.initState();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    ref.read(xxxProvider.notifier).load();
  });
}
```

因为 provider 没有 `autoDispose`，**状态在页面销毁后依然保留**，
再次进入页面会先看到上次的数据再刷新。这是刻意的（底部导航 5 个 tab 用
`NoTransitionPage` 常驻，见 `app_router.dart:100-125`）。

---

## 网络层：现状与陷阱

### dio 单例

```dart
// lib/core/network/dio_client.dart:8-53
class DioClient {
  static DioClient? _instance;
  late final Dio dio;
  static DioClient get instance => _instance ??= DioClient._();

  void setBaseUrl(String url) { ... }   // 切换面板时调用，会去掉结尾斜杠
}
```

- 超时：connect 15s / receive 30s / send 15s（`:17-19`）
- 默认头：`Content-Type` + `Accept` + `AppUserAgent.defaultHeaders`（`:20-24`）
- debug 模式挂 `LogInterceptor`，但所有开关都是 false，只打请求行（`:28-39`）
- `rawDio`（`:55-63`）是**每次调用新建**的 Dio，专供 token 刷新用，避免递归触发拦截器

### 拦截器只有一个，且在 `main()` 里插入

```dart
// lib/main.dart:23-30
DioClient.instance.dio.interceptors.insert(0, AuthInterceptor(
  onAuthFailed: () => container.read(authProvider.notifier).setUnauthenticated(),
));
```

`AuthInterceptor`（`core/auth/auth_interceptor.dart`）：
- `onRequest`：从 `SecureStorage` 取 access token 注入 `Authorization`（`:35-44`）
- `onError`：401 时用 refresh token 换新 token，重发原请求，并排队重发期间积压的请求（`:47-114`）

### ⚠️ 陷阱一：`validateStatus: status < 500` 让上面的续期逻辑**从未执行过**

```dart
// lib/core/network/dio_client.dart:16 和 :60
validateStatus: (status) => status != null && status < 500,
```

401/403/400 全部被 dio 判定为**成功响应**，`onError` 永不触发。连锁后果：

| 位置 | 症状 |
|---|---|
| `auth_interceptor.dart:46-114` | 70 行续期 + 排队重发是死代码 |
| `auth_provider.dart:108` 的 `catch` | 够不着，因为 401 不抛异常 |
| 各 Notifier 的 `catch` | 兜不到 4xx，`extractPaginated` 从错误体里解出空列表 → 页面显示「暂无数据」 |
| `system_settings_page.dart:496-529` | 后端返回 400，仍走 try 分支弹「配置已保存」 |

**局部绕过**：`auth_service.dart:68-84` 登录接口自己判 `statusCode >= 400` 然后
手动 `throw DioException.badResponse(...)`；`sse_client.dart:61` 单独处理 401
（SSE 走 `package:http`，不经 dio）。

> **第 0 期 R1 会收紧 `validateStatus`。** 收紧后所有 4xx 变成 `DioException`，
> 现有走「成功路径」的代码会开始抛异常。**新增或修改任何调用点时，必须自己确认
> catch 兜得住**，不能假设「以前没炸所以现在也不会炸」。

### ⚠️ 陷阱二：路径必须走 `ApiEndpoints`

`lib/core/network/api_endpoints.dart` 是**唯一**路径来源，193 行、约 150 个常量，按业务分组
（Auth / System / Tasks / Logs / Scripts / Envs / Subscriptions / Notifications / Deps /
Users / Security / Configs / SSH Keys / Open API）。两种形式：

```dart
static const String tasks = '$baseApi/tasks';                    // 静态路径 → const
static String taskById(int id) => '$baseApi/tasks/$id';          // 带参数 → 静态方法
static String backupDownload(String filename) =>                 // 带 query → 必须 encode
    '$baseApi/system/backup/download?filename=${Uri.encodeQueryComponent(filename)}';
```

前缀只有两个：`baseApi = '/api'`、`baseApiV1 = '/api/v1'`。
`/api/v1` 只用于 SSE 流式接口和 health/version（`:16-17, 64, 122, 143`）。

**现存违规**（3 处，新代码不要模仿）：
`system_settings_page.dart:265 / 349 / 419` 直接拼 `'${ApiEndpoints.baseApi}/system/update-status'` 等。

### 响应解包：一律走 `shared/utils/api_utils.dart`

后端响应有多种包裹形态，**不要在页面里自己 `data['data']`**：

```dart
// 单对象
final data = extractData(response.data);            // api_utils.dart:3

// 分页列表：兼容 {data:[...], total:N} / {data:{data:[...],total:N}} / 裸 [...]
final paginated = extractPaginated(response.data);  // api_utils.dart:13
final items = paginated.items.map((e) => Task.fromJson(e)).toList();

// 错误文案：优先后端 error / message
final msg = extractErrorMessage(error, '加载失败');   // api_utils.dart:44
```

这三个函数被 22 个文件引用共 92 处。

### 分页：三种做法并存

| 做法 | 例 |
|---|---|
| 一次性 `all=1` 全量拉 | `task_provider.dart:62`（`loadMore()` 是空实现，`:87-89`） |
| 循环翻页拉完（后端 `page_size` 上限 100） | `env_list_page.dart:69-99`、`log_list_page.dart:135-158` |
| 真·滚动加载更多 | `log_list_page.dart:98-102` `loadMore()` |

> 注释里记录了踩坑原因：「后端 `page_size` 上限 100，请求更大值会静默退回 20，
> 导致列表只显示 40 行」（`env_list_page.dart:67-69`）。改分页逻辑前先读这条。

### SSE：独立客户端，不经 dio

`lib/core/network/sse_client.dart` 用 `package:http` 手动解析 `event:` / `data:` 行，
自己加 `Authorization` 头（`:54-56`），支持 `autoReconnect`（收到 `event: done` + `data: reconnect` 时 1 秒后重连，`:87-101`）。

用于：任务实时日志、日志流、依赖安装日志、订阅拉取流。
对应端点在 `ApiEndpoints` 里都是 `baseApiV1` 前缀。

> **注意**：SSE 不经过 `AuthInterceptor`，**token 过期时不会自动续期**，
> 只会回调 `onError('认证失败，请重新登录')`（`:61-64`）。

---

## 本地存储

`lib/core/storage/secure_storage.dart` 是唯一入口，静态方法，两套后端：

| 后端 | 存什么 |
|---|---|
| `FlutterSecureStorage` | access/refresh token、user、panels 配置、app lock 配置、可信登录有效期 |
| `SharedPreferences` | `server_url`、legacy server list、UI 状态（前缀 `ui_state_`） |

特殊约定：**7 天本地可信登录**。启动时若 `hasValidTrustedLogin(serverUrl)` 为真，
直接置 `authenticated` 而不打服务端（`main.dart:33` → `auth_provider.dart:44-70`），
目的是「避免每次打开 APP 都重新打登录日志」（`auth_provider.dart:45` 注释）。
