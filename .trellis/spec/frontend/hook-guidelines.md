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
// lib/features/tasks/providers/task_provider.dart（节选）
class TaskNotifier extends StateNotifier<TaskListState> {
  // dio 仅供测试注入；生产路径不传，provider 里是 TaskNotifier() 无参 new
  TaskNotifier({Dio? dio}) : _injectedDio = dio, super(const TaskListState());
  final Dio? _injectedDio;
  Dio get _dio => _injectedDio ?? DioClient.instance.dio;   // 直接摸单例，不经 ref.read

  Future<void> load({bool refresh = false}) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final dio = _dio;
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

1. **Notifier 不经 riverpod 注入依赖，直接用 `DioClient.instance.dio`**。
   碰 dio 的 10 个 Notifier 都带一个**仅供测试**的可选 `{Dio? dio}`，生产路径不传，
   经 `_dio` getter 回落到单例（形状和「别在构造时存单例」的理由见
   [quality-guidelines.md](./quality-guidelines.md)「可测性改造」）。
   唯一例外是 `AuthNotifier`，它通过 `ref.read(authServiceProvider)` 拿 service
   （`core/auth/auth_provider.dart:229-231`）。这也是**唯一有 service 层的 feature**——
   其余 feature 的 Notifier 直接发 HTTP，没有中间层。

2. **写操作后统一 `await load()` 全量重拉**，不做本地乐观更新：
   ```dart
   // lib/features/tasks/providers/task_provider.dart
   Future<void> runTask(int id) async {
     await _dio.put(ApiEndpoints.taskRun(id));
     await load(refresh: true);
   }
   ```
   例外只有拖拽排序会先改本地再提交：
   - 任务：`task_provider.dart` 的 `moveTask`（v1.3.8 起）。先在本地挪位（乐观更新，
     否则松手瞬间列表会先弹回原位），再**只发一次** `PUT /tasks/sort {source_id, target_id, position}`，
     最后在 `finally` 里 `await load()`——成功拿面板整桶重编号后的顺序，失败（跨桶 400 / 老面板 404）
     靠这次重拉把本地顺序弹回服务端顺序。它（以及 `batchSetNotify`）catch `DioException`
     只为把「面板没有这条路由」翻译成 `PanelUpgradeRequiredException`，其余照样 `rethrow`，不违反下一条。
   - 环境变量：`env_list_page.dart` 的 `reorderLocal`（`:389`）。

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

> 代价：**换了面板 / 退出登录之后这些状态是脏的**。所以切面板
> （`server_config_page._switchToPanel`）与退出登录（`more_page._logout`）
> **必须**调 `invalidateServerScopedProviders(ref)`
> （`lib/core/providers/server_scoped_providers.dart`，v1.3.7 / issue #13），
> 否则 A 面板的任务列表会原样显示在 B 上，用户可能对着 A 的任务点「运行」、
> 请求却打到了 B。
>
> **新增任何服务器级 provider，都要同时加进那个函数**——它是唯一一份、两个页面共用，
> 写成两份必然只被改其中一份。当前失效 10 个：`dashboard` / `task` / `taskView` /
> `envList` / `logList` / `script` / `depList` / `subscriptionList` /
> `notificationList` / `userList`。设备级的 `appLockProvider` 与核心的
> `authProvider` / `routerProvider` **刻意不在其中**，别顺手补上去。
>
> 这个函数放在 `core/` 而不是某个 feature 里，是因为它天然要 import 全部 feature 的
> provider；同类先例是 `core/router/app_router.dart`。

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
| 一次性 `all=1` 全量拉 | `task_provider.dart:74`（**刻意没有 `loadMore`**，见下） |
| 循环翻页拉完（后端 `page_size` 上限 100） | `env_list_page.dart:69-99`、`log_list_page.dart:135-158` |
| 真·滚动加载更多 | `log_list_page.dart:98-102` `loadMore()` |

> 注释里记录了踩坑原因：「后端 `page_size` 上限 100，请求更大值会静默退回 20，
> 导致列表只显示 40 行」（`env_list_page.dart:161-162`）。改分页逻辑前先读这条。

> **任务列表不要改成增量分页**（issue #107 已裁决）。分组下拉项、全选
> 都建立在「全部任务都在内存里」这个前提上：分页会让分组项残缺、全选退化成
> 「只全选已加载的」。（拖拽排序 v1.3.8 起改走 `PUT /tasks/sort`，兄弟序列由面板按整桶去取，
> 已不依赖这里是否全量；以前逐条写 `sort_order` 时，分页会把未加载任务的顺序写坏。）
> 列表卡顿由渲染侧解决 ——
> `task_list_page.dart` 把分组摊平成一维行列表（`utils/task_list_rows.dart`）
> 后交给 `ListView.builder`，只有可见区域的卡片会被建出来。
> 服务端 `all=1` 分支同理是**永久兼容红线**：线上 v1.1.1~v1.3.2 老客户端全都硬编码传它。

### SSE：独立客户端，不经 dio，但**与 dio 共用同一个续期入口**

`lib/core/network/sse_client.dart` 用 `package:http` 手动解析 `event:` / `data:` 行，
自己加 `Authorization` 头，支持 `autoReconnect`（收到 `event: done` + `data: reconnect` 时 1 秒后重连）。

用于：任务实时日志、日志流、依赖安装日志、订阅拉取流。
对应端点在 `ApiEndpoints` 里都是 `baseApiV1` 前缀。

401 的处理流程（**不要在这里重造第二套续期**）：

1. 调 `TokenRefresher.instance.refresh(staleToken: 用出去的那个 token)`；
2. 拿到新 token 后重连一次，**用户无感**，不弹任何提示；
3. 重连仍是 401 → `notifySessionExpired()`（清凭据 + 跳登录页，与 REST 同一个出口），
   并通过 `onError` 抛 `SseAuthFailure` 哨兵，页面据此区分「网络断了可以重试」
   和「会话没了，重试没意义」。

> **`TokenRefresher` 是全仓库唯一的续期入口**（`lib/core/auth/token_refresher.dart`），
> `AuthInterceptor` 也走它。理由是「同一时刻只能有一次续期在飞」：
> 两条链路各刷各的，后返回的那次会把先返回的新 token 覆盖成已作废的值。
>
> **重连额度**：`SseClient._refreshRetryUsed` 是 dio 侧 `RequestOptions.extra`
> 那个「已重发」标记的等价物，防的是 401 → 续期 → 401 的无限循环；
> 它在**每次连接成功（<400）时归还**，否则一次会话只能续期一次，
> 挂两小时的日志流第二次过期就直接掉线。

> **⚠️ 服务端不支持 `Last-Event-ID`**：`log.go` / `deps.go` / `subscription.go`
> 从不发 `id:` 帧也从不读它，任何重连都会**把整段历史从头重放**。
> 所以 `connect()` 有一个 `onReconnect` 回调，页面必须在里面把「已显示的行」
> 灌进 `SseReplayBuffer`（`lib/shared/utils/sse_replay_buffer.dart`）做去重，
> 否则重连一次日志翻一倍。

---

## 本地存储

`lib/core/storage/secure_storage.dart` 是唯一入口，静态方法，两套后端：

| 后端 | 存什么 |
|---|---|
| `FlutterSecureStorage` | access/refresh token、user、可信登录有效期 —— 这四项**按面板 scope 分片**（v1.3.7 / issue #13），真实 key 形如 `access_token::<sha256(url) 前 16 位>`，scope 由 `SecureStorage.scopeOf(url)` 现算；panels 配置、app lock 配置**保持全局**（前者是面板列表本身，分片等于自锁；后者是设备级的，分片后换面板就要重设锁） |
| `SharedPreferences` | `server_url`、legacy server list、UI 状态（前缀 `ui_state_`） |

### 凭据按面板 scope 分片

分片前 token / user / 可信期是全局一份裸 key，「切面板」只能先把上一台的凭据删掉，
切回去就得重新登录、重新过 2FA。分片后每台面板各存一份，互不覆盖。

- **scope 的主键是 url，不是面板 id**。`login_page.dart` 每次登录成功都是裸 new 一个
  `PanelConfig` 覆盖保存（不是 `copyWith`），首次生成的 id 下次登录就被换掉，
  用 id 当 scope 会对不上号，症状正是「刚登完下次启动又要登」。
- `scopeOf()` 统一去掉结尾斜杠；`http://` 与 `https://`、带端口与不带端口算不同 scope，
  这是预期——改了面板地址就等于换了一台，重新登录一次。
- 还没选定面板时落在固定 scope `default`。**不要让它变成 `null` 拼进 key**：
  一旦有人在 `access_token::null` 下写过 token，后面谁都读不回来。

**scope 切换只有一个入口**：`DioClient.setBaseUrl()` 末尾的
`SecureStorage.setActiveServer()`。它是同步方法、无 `await`，保证 baseUrl 与 scope
原子同步，中间不存在「请求打到 B、带的却是 A 的 token」的窗口。
新增 `setBaseUrl` 调用点不需要自己切 scope。

**升级迁移**：`SecureStorage.migrateLegacyAuthScope()` 在 `main.dart` 里的位置是硬要求——
必须排在 `setBaseUrl` **之后**、`restoreTrustedLocalSession()` **之前**；
顺序颠倒 = 存量用户升级后第一次启动读不到 token，等于把所有人踢下线一次。
迁移内部是「先写新 → 读回校验 → 再删老」，写失败就原样留着下次再试；
**绝不能用 `getPanels()` 那种 `catch => []` 的吞异常写法**——国产 ROM 上 Keystore 失效是真事，
吞掉之后老 key 已删、新 key 没写成，凭据就永久丢了。老 key 是否存在本身就是幂等判据，
不需要另外记 `*_migrated` 标记。

特殊约定：**7 天本地可信登录**。启动时若 `hasValidTrustedLogin()` 为真，
直接置 `authenticated` 而不打服务端（`main.dart:51` → `auth_provider.dart:44-70`），
目的是「避免每次打开 APP 都重新打登录日志」（`auth_provider.dart:45` 注释）。
签名**不带 `serverUrl`**：可信期本身就存在该面板的 scope 下，
「是哪台面板的」已由 key 表达，不需要另存一个 url 再比对一次。
