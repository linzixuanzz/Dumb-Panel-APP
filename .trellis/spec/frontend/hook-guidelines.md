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
   - 环境变量：`env_list_page.dart` 的 `EnvListNotifier.moveEnv`（v1.4.0 起，取代旧的 `reorderLocal` +
     点「完成」才提交）。骨架同 `moveTask`（乐观挪位 → 只发一次 `PUT /envs/sort` → `finally` 里 `await load()`），
     多三条：上一次排序在飞时拒绝下一次、失败时只回滚自己写的那份乐观顺序、松手时核对拖起的那条 id。
     它的 catch 只为回滚，照样 `rethrow`。契约见下方「环境变量拖拽排序」。

3. **写操作方法本身不 try/catch，异常向上抛给 UI**。
   UI 侧用 `try { await ... } catch (error) { _showActionError(error, '...'); }`
   （`task_list_page.dart:232/253/291/308/322/331/345/1539`）。
   只有 `load()` 这类读操作在 Notifier 内部吞掉异常。

### 环境变量拖拽排序：`moveEnv` 与带代次的 `load()`（APP #16，v1.4.0）

**1. 范围与触发**：`lib/features/envs/views/env_list_page.dart` 里 `EnvListNotifier` 的 `load()` / `moveEnv`、
`EnvListState.envsUnfiltered`，以及页面的 `onReorderStart` / `onReorder` / `_moveEnv`。请求体、面板语义与新老面板的差异见
[panel-contract.md](./panel-contract.md)「`PUT /api/envs/sort`」，本节只管状态与并发。

**2. 签名**

```dart
class EnvListState {
  final bool envsUnfiltered;   // 默认 true；copyWith 不传就保留，只有 load() 成功时改写
}

class EnvListNotifier extends StateNotifier<EnvListState> {
  int _loadSeq = 0;            // load() 的代次：只认最后发出去的那一次
  bool _sorting = false;       // 有一次排序的 PUT + 重拉还没结束
  Future<void> load();         // GET /api/envs?all=1[&groups][&keyword]，自己吞异常
  Future<void> moveEnv(int oldIndex, int newIndex, {int? draggedId});
  Future<void> setPinned(int id, bool pinned);        // move-top / cancel-top，然后 await load()
  Future<void> setImportant(int id, bool important);  // PUT /envs/:id {important}，然后 await load()
}

// 页面 _EnvListPageState
int? _draggingEnvId;           // onReorderStart 记下拖起那条的 id，_moveEnv 取走并清空
```

**3. 契约**

`load()`：

1. 开头 `final seq = ++_loadSeq;`，同一刻取 `keyword` / `selectedGroups`：请求参数与「这份列表有没有筛选」同源。
2. 一次 `{'all': 1}`（加上 `groups` / `keyword`），不带 `page` / `page_size`、不再循环翻页（逐页拉取不是快照，见下方「分页」）。
3. 两个 `await`（列表、分组）之后、写 state 之前判 `seq != _loadSeq` → 整份丢掉；`catch` 分支同样先判——旧请求的结果和错误都不许盖掉新的。
4. `envs` 与 `envsUnfiltered` 只在成功分支的**同一次** `copyWith` 里写：`envsUnfiltered = 没筛选 && items.length >= paginated.total`
   （截断时 `total` 更大；响应里没有 `total` 时 `extractPaginated` 按条数算，不会误判）。失败分支只写 `error`，两者都保留旧值。

> **为什么要写进规约**：这是列表 provider 里第一个带代次的 `load()`，看着像多余防御（删掉它只有专门那 1 条用例会红）。
> 但搜索框、分组筛选、下拉刷新、每个写操作后的重拉都会各自调 `load()`，本来就会并发；排序拿这份列表算锚点，
> 先发后到的旧顺序一盖回来，下一次拖动就算错。先例：`task_view_provider.dart` 的 `_groupProbeSeq`、
> `task_form_page.dart` 的 `_cronParseGeneration`。

`moveEnv`（判断的**先后顺序**也是契约）：

1. 越界（`oldIndex` 不在 `[0, len)`、`newIndex` 不在 `[0, len]`）或 `draggedId != null && envs[oldIndex].id != draggedId`
   → 抛 `EnvWriteException('列表刚刷新过，请重新拖动')`。`draggedId` 为空 = TalkBack 的「上移 / 下移」（只调 `onReorder`、
   不调 `onReorderStart`），不核对。
2. `newIndex > oldIndex` 时先减一（`ReorderableListView` 给的是移除前的下标）；减完等于 `oldIndex` = 原地松手 → 直接返回。
3. `_sorting` 为真 → 抛 `EnvWriteException('上一次排序还在保存，请稍候再拖')`。**必须排在原地判断之后**：从下方拖回原位时
   Flutter 照样回调 `onReorder(i, i + 1)`，排在前面会在保存途中对一次原地松手也弹「请稍候」。
   不排队：排队的锚点算在前一次的乐观顺序上，前一次失败后，后面的全算错。
4. 算锚点；两侧邻居都不同桶 → 抛 `EnvWriteException('置顶变量和普通变量请分别排序；…')`，不挪位。
5. 读 `state.envsUnfiltered` → `_sorting = true` → `state = copyWith(envs: items)`（乐观挪位，否则松手瞬间列表先弹回原位）→ PUT。
6. PUT 抛错：`if (identical(state.envs, items)) state = copyWith(envs: before);` 然后 `rethrow`。只回滚自己写的那份：
   期间别的 `load()` 已经换掉列表就不动，保证 `envs` 与 `envsUnfiltered` 仍来自同一次 `load()`。
7. `finally { await load(); _sorting = false; }`：成功拿面板整桶重编号后的顺序，失败按服务端顺序弹回。`load()` 吞异常，
   不会盖掉 PUT 的异常，`_sorting` 一定复位。

页面：`onReorderStart` 只记 `_draggingEnvId`（不 `setState`）；`_moveEnv` 先取走并清空它再调 `moveEnv`；
`EnvWriteException` → `AppSnack.warn(error.message)`，其它 → `AppSnack.error(extractErrorMessage(error, '保存排序失败'))`；
成功不提示。「完成」按钮只切 `_sortMode`，退出时清 `_draggingEnvId`。

**4. 校验与错误矩阵**

| 场景 | 结果 |
|---|---|
| 搜索框连打两个字，两个 `load()` 并发、先发的后到 | 只认后发的那次，旧结果、旧错误都丢掉 |
| 清空搜索词后重拉失败 | `envs` 仍是筛过的那份、`envsUnfiltered` 仍为 false，拖到最后发 `{前一条, after}` |
| `all=1` 被截断（`total` 5001） | `envsUnfiltered` 为 false，排序按「有筛选」处理 |
| PUT 在飞时再拖 | 拒绝（「请稍候」），PUT 仍是 1 个；原地松手不算拖 |
| PUT 失败、紧接着的重拉也失败（断网） | 列表回到拖动前，异常是 PUT 的原话 |
| PUT 在飞时用户改了搜索词，那次重拉先写入新列表，PUT 随后失败 | 不回滚；`envsUnfiltered` 与新列表同源 |
| 拖拽途中列表被重拉成同条数、另一种顺序 | 松手时 id 对不上 → 拒绝，0 个 PUT |
| 慢网下连拖第二下 | 被「请稍候」拦回去（刻意取舍，不排队） |

**5. 用例**

- 正常：`A B C D E` 把 B 下移 1 格 → 请求发出那一刻本地已是 `A C B D E`，1 个 PUT + 1 次 GET 后列表不变。
- 基础：PUT 卡住时再拖一次 → 「请稍候」；放行后再拖 → 第 2 个 PUT 才发出，两个请求体按先后。
- 错误：PUT 500 且紧接着的重拉断网 → 列表回到 `A B C D E`；不回滚的话，没保存上的顺序会一直留在屏幕上。

**6. 必须有的测试**（`test/features/envs/env_sort_test.dart`；写法见 [quality-guidelines.md](./quality-guidelines.md)「widget 测试的写法约束」）

- G1：清空搜索后重拉失败，仍发 `{前一条, after}`；`total: 5001` 截断时同样；`total` 等于条数或缺省时 `envsUnfiltered == true`；
- G2：`putGate` 挂住 PUT、`onPut` 里完成 `arrived` 之后再拖 → 「请稍候」，原地松手不弹；
  「先发后到的旧 load」：keyword `a` 的 GET 卡在 `Completer` 上、`ab` 立刻回，放行后 `envs` 仍是 `ab` 的结果、`loading == false`；
- G3：150 条只发 1 次 GET，query 含 `all=1`、不含 `page` / `page_size`、带上 `keyword` / `groups`（在 responder 里记
  `options.queryParameters`，`FakeHttpAdapter` 不记 query）；GET 失败时 `error` 有原因、`envs` 与 `envsUnfiltered` 不变；
- G4：双失败回到拖动前；404 原话可取 + 重拉 1 次；「PUT 卡住期间列表已被别的 load 换掉」→ 不回滚、`envsUnfiltered` 同源；
- G5 / G7：`draggedId: 99` 拒绝、`null`（TalkBack）照常；越界 `(9, 0)` `(0, 9)` `(-1, 2)` 同一句拒绝、0 个 PUT；
- 页面：松手即 1 个 PUT、点「完成」不再发；拖拽途中重拉成另一种顺序（`onReorderStart!(1)` → 服务端换顺序 →
  `await tester.runAsync(() => …load())`）→ 松手提示「列表刚刷新过，请重新拖动」、0 个 PUT。
- 突变（实现时跑过，改回后全绿）：去掉 `_sorting`、把它挪到原地判断之前、去掉代次、去掉回滚、回滚去掉 `identical`、
  去掉 id 核对、`onReorderStart` 不记 id、去掉越界保护、`envsUnfiltered` 读此刻的搜索词 / 不看 `total`、`load()` 换回分页
  ——各有对应用例变红。

**7. 错误 vs 正确**

```dart
// ❌ 不带代次：先发后到的旧响应盖掉新列表，下一次拖动在旧顺序上算锚点
final response = await dio.get(ApiEndpoints.envs, queryParameters: params);
state = state.copyWith(envs: parse(response));

// ❌ 失败时无条件回滚：PUT 在飞时别的 load() 已写入新列表，旧快照把它盖回去，
//    envs 与 envsUnfiltered 从此不是同一次 load() 写的
} catch (_) { state = state.copyWith(envs: before); rethrow; }
```

```dart
// ✅ load()
final seq = ++_loadSeq;
final response = await listFuture;
final groups = await groupsFuture;
if (seq != _loadSeq) return;              // catch 分支同样先判

// ✅ moveEnv() 的收尾
} catch (_) {
  if (identical(state.envs, items)) state = state.copyWith(envs: before);
  rethrow;
} finally {
  await load();
  _sorting = false;
}
```

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
| 一次性 `all=1` 全量拉 | 任务 `task_provider.dart:109-113`（**刻意没有 `loadMore`**，见下）；环境变量 `env_list_page.dart:184-245` 的 `load()`（v1.4.0 起，面板上限 5000，见上方「环境变量拖拽排序」） |
| 循环翻页拉完（后端 `page_size` 上限 100） | `log_list_page.dart:165-188`（`deleteAllMatching` 取全部日志 id） |
| 真·滚动加载更多 | `log_list_page.dart:128-132` `loadMore()` |

> 后端 `page_size` 超过 100 会**静默退回 20**（不报错）：环境变量列表曾因此只显示 40 行、订阅列表第 21 条起看不见
> （`subscription_list_page.dart:78-81` 的注释；面板侧见 [panel-contract.md](./panel-contract.md)「分页」）。改分页逻辑前先读这条。

> ⚠️ **逐页拉取不是快照**：翻页之间列表一变（排序、增删），拼出来的结果会重复一行、丢一行，条数还可能正好等于 `total`，
> 循环照常结束（APP #16 实测）。环境变量页 v1.4.0 起改 `all=1` 就是因为这个——排序拿这份列表算锚点
> （`env_list_page.dart:193-197` 的注释）。要「整张表」语义（算锚点、全选、计数）的地方不要用循环翻页。

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
自己加 `Authorization` 头，支持 `autoReconnect`（收到 `event: done` + `data: reconnect` 时 1 秒后重连一次；
这次连不上不再重试，直接 `onError`，恢复与否由页面决定）。面板 v3.3.5 起正常关停时三条流（实时日志、依赖、订阅）
都发 `reconnect`，各页表现与约束见 [panel-contract.md](./panel-contract.md)「面板关停时的结束事件」。

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
> 日志太长、前面的行已从内存丢掉时，用 `reset(_log.lines, skipLeading: _log.droppedCount)`
> 让它先按行数跳过那一段（两个日志页的 `_resetReplayBuffer` 都是这么写的）。
> **灌进去的必须是面板重放的前缀**（之前 SSE 送来的内容）：`SseReplayBuffer` 第一处对不上就
> 整个放行（宁可重复不能吞行），别的来源交给它只会叠成两份，或者恰好对上时把历史吞掉——
> `live-logs` 的快照就是这种，见下一节。

### 实时日志页：live-logs 快照与 SSE 的衔接、结果结算与停止（`TaskLiveLogPage`，APP #15 R3′；v3.0 审查补结算）

**1. 范围与触发**：`_TaskLiveLogPageState`（`lib/features/tasks/views/task_list_page.dart`）里任何改动
「正文 `_log` 从哪来、何时整段替换、何时去重、轮询何时放弃 / 回落」「流结束后状态胶囊写什么、结果从哪来」
「停止之后怎么收尾」的地方。这个页面同时消费面板三个接口（形状见 [panel-contract.md](./panel-contract.md)「实时日志」一节）。
`LogStreamPage` 的**正文**不在此列（运行中先清空、只用 SSE），但它的**结果结算与停止**与本页同一套口径，见本节末
「`LogStreamPage` 的结算与停止」。

**2. 签名**

| 接口 | 页面怎么用 |
|---|---|
| `GET ApiEndpoints.taskLiveLogs(id)` → `{logs, done, status}` | 首屏快照与状态；没在运行、或 SSE 出错后，每秒轮询一次 |
| SSE `ApiEndpoints.logStream(id)`（`autoReconnect: true`，`onReconnect: _resetReplayBuffer`） | 运行中的正文：先整段历史，再实时行 |
| `GET ApiEndpoints.taskLatestLog(id)` → `{content, status, …}` / 404 | 运行结束后**结算这次运行的结果**（`status`：0 成功 / 1 失败 / 2 运行中 / 3 已终止）；手里只有快照或什么都没有时顺带换正文 |
| `PUT ApiEndpoints.taskStop(id)`（经 `taskProvider.stopTask`，之后还要等任务列表重拉） | 「停止运行」 |

页面状态：`_logFromSse`（正文是不是 SSE 来的）、`_liveStatus`（最近一次 live-logs 的 `status`）、
`_pollTimer` / `_pollAttempts`、`_runResult`（latest-log 结算出的 `task_logs.status`，null = 还不知道）、
`_stopRequested`（本页点过停止、请求已发出）、`_sseDropped`（SSE 出错断开、或没等到 done 就收口过，页面在降级轮询）、
`_settling` / `_settleRetryTimer`（结算在途）、`_runGeneration`（每次「重新运行」+1，上一次在途的结算作废）。
方法 `_applyLiveSnapshot`、`_startPolling`、`_fallbackToLatestLog`（`:3491`，回落正文 + 结算结果）、`_waitBeforeSettle`、
`_resetReplayBuffer`、`_connectSSE`（`:3574`）、`_stoppable`（`:3688`）、`_stopLiveTask`（`:3691`）、`_resolveLiveTone`（`:3817`）。

结算节奏是两个顶层常量，定义在 `lib/features/logs/views/log_stream_page.dart:29-35`，两个日志页共用
（任务页 `import … show kLogSettleAttempts, kLogSettleRetryDelay`，`task_list_page.dart:41-42`；两页都
`import 'package:dio/dio.dart' show DioException` 用来认 4xx）：

```dart
const int kLogSettleAttempts = 5;                                  // 最多查几次
const Duration kLogSettleRetryDelay = Duration(milliseconds: 500); // 每次查之前等多久（第一次也等）
```

**3. 契约**

1. 正文任一时刻只有一个来源：快照（`_logFromSse == false`）或 SSE（`true`），**两者不拼接**。
2. 快照只负责先给用户看点东西：`_resetReplayBuffer()` 在 `!_logFromSse` 时只 `_replayBuffer.clear()`；
   只有 SSE 来的内容才 `reset(_log.lines, skipLeading: _log.droppedCount)`。
3. 第一条 SSE data（`SseClient` 每条 `data:` 行回调一次，所以就是历史第一行）：
   `_logFromSse = true` + `_log.replaceAll(newLines)`，**不过** `consume`；之后照常 `consume` → `append`。
4. `_applyLiveSnapshot` 只在 `!_logFromSse` 时 `replaceAll(logs)`：SSE 出错降级轮询、再连上时，
   正文仍是 SSE 的内容，重放去重对得上。快照说「还有内容、任务已不在跑、也不在排队」（别处点了停止，宽限期里 TinyLog 还在）时
   停掉轮询、调 `_fallbackToLatestLog()` 结算。
5. **`done: finished` / `finished-late` 只表示流结束，不带成败**（`finished-late` 面板 v3.2.0 起才有，对 APP 同义）：
   → `_done = true`，状态写中性的「已结束」（停止过写「已停止」，已结算过直接写结果），**然后一律调 `_fallbackToLatestLog()` 结算**。
   `!_logFromSse`（这条流一行数据都没送来：live-logs 时还在跑，连上 SSE 时已经结束）时**保留快照**，结算拿到 latest-log 正文再换；
   `_logFromSse` 时只取结果、不换正文。`reconnect` → `_done = false`、「运行中」；其它值不算结束（`timeout` 显示「等待日志...」，
   不认识的值原样显示，见 `_statusFromStreamDone`）。**停止之后只认 `finished` / `finished-late`**，`reconnect` 等一律忽略
   （按钮不能变回「停止运行」）。
6. 轮询每一跳在 `await` live-logs 之后、动任何状态之前先判 `identical(timer, _pollTimer)`，
   不是当前这一轮就整跳作废；放弃分支同样只许当前这一轮执行。
7. 放弃（`_pollAttempts >= 15` 且状态仍是「等待日志...」）：停轮询 → `_liveStatus != kTaskStatusQueued` 时
   `await _fallbackToLatestLog()`（**不再要求 `!_logFromSse`**：结果总是要结算，正文换不换由第 8 条决定）→
   `_done = true`（不再跟着「有没有日志」走）、状态 `已结算 ? 结果 : (_log.isEmpty ? '暂无日志' : '已结束')`。
8. `_fallbackToLatestLog()`：已在结算（`_settling`）或已有 `_runResult` 就直接返回——done、轮询收口、停止、快照都可能触发，只查一轮。
   最多 `kLogSettleAttempts` 次，**每次请求之前先等 `kLogSettleRetryDelay`（第一次也等）**：面板先关 TinyLog（SSE 随即发 done），
   再读文件、压缩，最后才把结果写进 `task_logs`（见 panel-contract.md「停止与结算的时序」），刚收到 done 就查几乎总是「运行中」。每次回来：
   - `status` 不是运行中（2）才算结算出来：写 `_runResult`；已收口（`_done`）就把状态写成结果（`_runResultLabel`）——成功「已完成」（绿）、
     失败「失败」（红）、已终止「已终止」（中性）；
   - 正文**最多换一次**：`!_logFromSse` 且 `content` 非空时归一 `\r\n`、去掉结尾空行后 `replaceAll`；等结果期间 SSE 送来了内容就以 SSE 为准，
     重试拿到的正文不换第二遍（免得正在看的位置被重排两次）；
   - 还是运行中 → 等一拍再查；面板没给 `status` → 停；**4xx（`DioException`，如 404 从没跑过 / 被保留策略清理）不重试**，其它错误下一轮再查；
   - 查满次数仍是运行中：保持中性「已结束」，不报错、不猜成败。每次 `await` 之后 `!mounted` 或 `_runGeneration` 变了都整次作废。
9. **状态胶囊的绿 / 红只认 `_runResult`**（`_resolveLiveTone`）：流结束、轮询收口、停止本身都说不出成败，一律中性；
   「连接错误」「登录已失效」是红。
10. **只有 live-logs 报告运行中或排队中才给「停止运行」**：`_stoppable` = `_liveStatus == kTaskStatusRunning || _liveStatus == kTaskStatusQueued`，
    `onStop: !_done && _stoppable && canOperate`（`:3890`）。不能只看 `!_done`：几秒就跑完的任务进来时 live-logs 已经是空的，页面会在
    「等待日志...」里轮询最多 15 秒（`_done` 一直是 false），这时任务早就结束了。
11. **停止之后不关 SSE**（`_stopLiveTask`）：
    - 请求发出**之前**先置 `_stopRequested = true`：停止接口还要等任务列表重拉，这期间 done 先到也只能显示「已停止」，不能先闪别的结果；
    - `_stopRequested` 期间 SSE 送来的行（TERM 收尾、后置脚本、终止提示）只追加正文，**不改状态**；
    - 成功：停掉轮询、`_done = true`、胶囊「已停止」（已结算过写结果），等随后的 `done: finished` 触发结算（面板已把这次记成已终止）；
    - 成功时 SSE 已经出错断开、页面在降级轮询（`_sseDropped`）：**重连 SSE**，不当场结算——面板 Stop 返回前就把日志行记成 Aborted，
      当场结算第一次就收口，宽限期里的收尾输出再也拿不到；重连从头重放（去重后只补新行），最后照常 `done` 触发结算；
    - 停止之后 SSE 出错（`onError`）、或没收到 done 流就断了（`onDone`）：不报「连接错误」，直接结算；
    - 排队中停止（一直在轮询、没连过 SSE）：停掉轮询，不连 SSE、不结算（那时 latest-log 是上一次运行的）；
    - 失败：`_stopRequested = false`；在途期间 done 先到、写成了「已停止」的改回「已结束」，结果仍由那次结算给。
12. `SseAuthFailure` 不降级轮询（同上一节）：`_done = true`、「登录已失效」。
13. **没收到 done 流就收口（`onDone` 且 `!_done`，反代掐了长连接这类）与 `onError` 的非鉴权分支同等处理**：
    `_sseDropped = true`、胶囊「连接结束」、停掉旧轮询再 `_startPolling()`。轮询发现还在跑会重连 SSE，跑完了就结算；
    之后（或在途时）点停止，第 11 条按 `_sseDropped` 重连 SSE 接回收尾输出，`done` 后结算。改前这里只写「连接结束」：
    不轮询、不置 `_sseDropped`，「停止运行」还在，点了既不重连也不结算，胶囊永远是「已停止」、收尾输出一行也拿不到。

**4. 校验与错误矩阵**

| 场景 | 正文 | 状态 / 请求 |
|---|---|---|
| 运行中：几十行快照（首行半截）+ SSE 300 行历史 | 300 行，首行是历史第 1 行 | 「复制全部」= 这 300 行 |
| 快照恰好从历史第 2 行开始、每行完整 | 历史一行不少 | — |
| SSE 只回 `done: finished` / `finished-late` | 先留着快照，再换成 latest-log 全量 | latest-log 恰 1 次，不出现「无日志内容」；结算为成功时「已完成」 |
| 同上，latest-log 404 | 保留快照（日志不到 4KB 时它就是全量） | 不空白；4xx 不重试，停在「已结束」 |
| SSE 推完历史 + `done: finished`，latest-log 回失败（`status: 1`） | SSE 的内容，不换 | 先中性「已结束」、latest-log 0 次；约 0.5 秒后红色「失败」、latest-log 1 次，没有绿色对勾 |
| latest-log 一直回运行中（面板还没写完结果） | 不变 | latest-log 恰 `kLogSettleAttempts` 次，停在中性「已结束」，没有对勾也没有叉 |
| SSE 断线 → 轮询 → 再连（面板重放 305 行） | 305 行、无重复（latest-log 的正文不拿来换） | 共 2 条 SSE；结算为成功时「已完成」 |
| 刚跑完（live-logs `logs: []`、`status: 1`） | 第 15 跳放弃时换成 latest-log | latest-log 恰 1 次；结算为成功时「已完成」 |
| 刚跑完 + live-logs 每次 1.5 秒 | 同上 | 放弃后 live-logs 调用数不再增加 |
| 刚跑完、latest-log 404 | 「无日志内容」 | 胶囊「暂无日志」、不再转圈、正文不挂「等待日志输出...」 |
| 一直排队（`status: 0.5`） | 「无日志内容」 | **不回落**（拿到的会是上一次运行的日志），「暂无日志」 |
| 刚跑完、还在「等待日志...」里轮询 | — | **不给**「停止运行」；排队中的照样给 |
| 运行中点停止，SSE 不断 | 收尾输出照常追加 | 「已停止」不改回「运行中」；随后的 `done` → latest-log 结算成「已终止」 |
| 停止之后 SSE 没等到 done 就断了 | 不变 | 不报「连接错误」，直接结算成「已终止」 |
| SSE 出错降级轮询时点停止 | 重连 SSE，接回宽限期的收尾输出 | `done` 之后再结算 |
| SSE 没等到 done 就收口（`onDone`）后点停止 | 重连 SSE，接回宽限期的收尾输出 | 共 2 条 SSE；`done` 之后结算成「已终止」、latest-log 恰 1 次 |
| SSE 没等到 done 就收口、任务其实已经跑完 | SSE 的内容，不换 | 降级轮询；live-logs 空了第 15 跳放弃时去 latest-log 结算，不再连 SSE |
| 排队中点停止 | — | 停掉轮询，不连 SSE、latest-log 0 次 |
| 降级轮询拿到「快照还在、任务已不在跑」 | — | 停掉轮询，去 latest-log 结算 |
| 停止请求在途时 `done` 先到、停止却失败 | — | 结算拿不到结果就是「已结束」，不停在「已停止」 |

**5. 正常 / 基础 / 错误用例**

- 正常：打开运行中任务 → 先看到快照 → 历史第一行到达时整段换成 SSE 内容 → 实时追加 → `done: finished` → 中性「已结束」→
  约 0.5 秒后按 latest-log 显示「已完成 / 失败 / 已终止」。
- 基础：从任务列表点「运行」一个几秒就结束的任务 → live-logs 已经是空的 → 约 15 秒后回落 latest-log；这段时间里没有「停止运行」。
- 错误：live-logs 说还在跑、SSE 连上时已经结束（短任务常见）→ 只回 done → 不得空白。
  调研原案 R3「运行中不展示快照」就会在这里显示「无日志内容」，已否决。
- 错误：脚本失败退出 → 面板照样只发 `done: finished` → **不得出绿色对勾**（v3.0 改版初版把 finished 硬写成「已完成」，失败的任务也显示成功）。

**6. 必须有的测试**（`test/features/tasks/task_live_log_page_test.dart`，22 条；造数与注入写法见
[quality-guidelines.md](./quality-guidelines.md)「日志视图与实时日志页的测试约定」）

- 快照 + 300 行历史：`totalCount == 300`、`lines.first == history.first`、剪贴板 == `history.join('\n')`；
- 快照恰好从第 2 行开始：先自检 `snapshot == [...history.skip(1), '']`，再断言 `lines == history`。
  它钉的是契约第 2 条——快照首行是半截时第一处就对不上，就算把快照交给去重也不会吞行，钉不住；
- `finished`、`finished-late` 各一条：没有「无日志内容」、latest-log（回成功）结算后有「已完成」、`countOf(latestLog) == 1`、`lines == history`；
- 脚本失败退出：结算前胶囊里是「已结束」、latest-log 0 次，结算后红色「失败」、没有对勾；latest-log 一直运行中：
  `countOf(latestLog) == kLogSettleAttempts`、停在「已结束」、既没有对勾也没有叉。**推进结算要按节奏 pump**：
  `for (var i = 0; i < kLogSettleAttempts + 2; i++) await tester.pump(kLogSettleRetryDelay);`；
- 停止相关：刚跑完不给停止 / 排队中能停、停止后 SSE 不断（收尾行照常追加、不回「运行中」、结算「已终止」）、停止后 SSE 断、
  降级轮询时停止要重连 SSE、`onDone` 收口后停止同样要重连 SSE（`connections == 2`、收尾两行在、「已终止」）、
  排队中停止不连 SSE 不结算、在途时 done 先到停止却失败；状态文字用 `_inPill(find.text(...))` 只在胶囊里找；
- 矩阵其余各行各一条；慢网那条要在放弃后再推 20 秒，断言 live-logs 调用数不变、latest-log 仍是 1 次。

**7. 错误 vs 正确**

```dart
// ❌ 改前：把 live-logs 快照当成重放前缀
void _resetReplayBuffer() {
  _replayBuffer.reset(_log.lines, skipLeading: _log.droppedCount);   // _log 还是 4KB 快照
}
// 首行半截 → 第一处就对不上 → 去重放行 → 快照 + 整段历史叠成两份（300 行显示成 354 行）。
// 若再配上「第一条 data 整段替换」：快照恰好从第 2 行开始时，第 2 行起逐行对上，整段历史被吞，只剩 1 行。
```

```dart
// ✅
void _resetReplayBuffer() {
  if (!_logFromSse) {
    _replayBuffer.clear();   // 快照不是前缀：等第一条 data 来了整段换掉
    return;
  }
  _replayBuffer.reset(_log.lines, skipLeading: _log.droppedCount);
}
```

```dart
// ❌ 轮询回调 await 之后不判这一跳是否过期
final resp = await DioClient.instance.dio.get(ApiEndpoints.taskLiveLogs(widget.taskId));
_applyLiveSnapshot(extractData(resp.data));
// 慢过 1 秒的上一跳在「放弃 + 回落」之后才回来：空快照盖掉回落的正文 → 重新拉起轮询
// → 15 秒后再回落……无限循环，每轮都重拉一遍最近一次日志。
// ✅ await 之后、动任何状态之前：
if (!identical(timer, _pollTimer)) return;
```

```dart
// ❌ v3.0 改版初版：把流结束当成功，「已完成」配绿色对勾（两个日志页都是；v2.0 只是文案写「已完成」、胶囊中性）
if (event.data == 'finished') {
  setState(() { _done = true; _statusText = '已完成'; });   // 脚本失败退出也是绿色对勾
}
// ❌ 刚收到 done 就查结果：面板还没写库，几乎总是「运行中」；不等就连查几遍，运行中的详情每次都是整份日志
// ✅ 先说「已结束」，结果去 latest-log 结算（每次查之前等 kLogSettleRetryDelay，status 不是运行中才算数，4xx 不重试）
setState(() { _done = true; _statusText = _stopRequested ? '已停止' : '已结束'; });
_fallbackToLatestLog();
```

```dart
// ❌ 停止成功就关 SSE、停轮询，当场写终态（v3.0 改版新加「停止运行」时的写法）：宽限期里的收尾输出和真实结果都丢了
_sseClient.close(); _pollTimer?.cancel(); setState(() { _done = true; _statusText = '已停止'; });
// ✅ SSE 不关，收尾行只追加、不改状态，等 done 再结算；SSE 已经断了（降级轮询中）就重连，不当场结算
// 「断了」包括 onError 和没等到 done 的 onDone：两处都要置 _sseDropped、降级轮询，只置一处另一条路就卡在「已停止」
final reconnect = _sseDropped;
setState(() { _done = true; _statusText = _runResult != null ? _runResultLabel(_runResult!) : '已停止'; });
if (reconnect) _connectSSE(widget.taskId);
```

**已知、未处理**：`_applyLiveSnapshot` 的「快照还在、任务已不在跑」分支用 `_statusFromLiveTask(1, done: true)` 生成文案，
结算回来之前胶囊会短暂显示「已启用」（任务状态的叫法），结算拿不到结果时一直停在这里。v3.0 之前就是这样；要改就在这个分支里写「已结束」。

#### `LogStreamPage` 的结算与停止（同一套口径，`lib/features/logs/views/log_stream_page.dart`）

日志详情页的正文只从 SSE 来，结果从**日志详情**（`GET ApiEndpoints.logById(id)`）结算：

- 状态：`_logStatus`（`task_logs.status`，只从日志详情取，`_resultKnown` = 不是 null 也不是运行中，`:195`）、`_stopRequested`、
  `_statusIfStopFails`（停止请求在途时流先收口了，原本该显示的状态记在这里）、`_settling` / `_settleRetryTimer`、`_loadGeneration`。
- `done: reconnect` → 「运行中」（停止之后忽略）。其它 `done` → `_done = true`；`finished` / `finished-late` 先写中性「已结束」，
  不认识的值原样显示；停止过就显示「已停止」并把上面那个值记进 `_statusIfStopFails`；已结算过不改。随后 `_settleFromDetail()`（`:206`）：
  每次查之前等 `kLogSettleRetryDelay`，还在运行就再等再查，最多 `kLogSettleAttempts` 次，4xx 不重试；结算后写详情的 `statusText`
  （成功 / 失败 / 已终止）和耗时。**正文不换**：SSE 送来的就是这次运行的输出，换成详情正文会把正在看的位置整个重排。
- `onDone` 时还没收到过 done（状态仍是「运行中 / 连接中...」，反代掐了长连接等）：任务多半还在跑 → 「连接结束」，只查**一次**详情，
  不按收口的节奏连查（运行中的详情每次都是整份日志）。
- `onError`：「连接错误」/「登录已失效」终态（红）；停止过则显示「已停止」并结算，停止请求还在途时把出错记进 `_statusIfStopFails`。
- 停止（`_stopTask`，`:442`）：同样请求前先置 `_stopRequested`、成功后**不关 SSE**、收尾行只追加；在途期间流已经收口的，成功后补一次结算；
  失败时把 `_statusIfStopFails` 补回（「已结束」「连接错误」等），已结算出结果的不改。
- 胶囊绿 / 红只认 `_logStatus`（`_resolveTone`，`:561`）；「已结束」「已停止」「连接结束」一律中性。
- 测试：`test/features/logs/log_stream_result_test.dart`（13 条：失败退出显示红色「失败」、正常跑完绿色「成功」、结果晚一拍写库要隔一会儿再查、
  一直运行中停在「已结束」、停止后收尾输出与 done、停止在途 done 先到、先等一拍再查、没收到 done 就断只查一次、停止后 SSE 断、
  停止在途 SSE 断且停止失败、停止在途 done 先到且停止失败、下载原始日志时 `⋮` 转圈、截断后复制提示现算）。

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
