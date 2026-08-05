# 状态管理

> `flutter_riverpod ^2.6.1`，只用 `StateNotifierProvider` + `Provider`。
> provider 的定义方式与网络层见 [hook-guidelines.md](./hook-guidelines.md)，本文只讲 **state 的形态**。

---

## 状态分三类

| 类别 | 承载 | 例 |
|---|---|---|
| 全局状态 | `StateNotifierProvider` 的 State 类 | 登录态、任务列表、仪表盘数据、应用锁 |
| 页面本地状态 | `ConsumerState` 的字段 + `setState` | 搜索框文本、选中集合、展开/折叠、排序模式 |
| 持久化状态 | `SecureStorage` 静态方法 | token、面板列表、UI 偏好（`ui_state_` 前缀） |

**没有** server-state 缓存层（无 `AsyncValue`、无 stale-while-revalidate）。
每次进页面 `initState` 里主动 `load()`，写操作后 `await load()` 全量重拉。

---

## State 类：手写不可变类 + `copyWith`

**没有** `freezed`、`json_serializable` 或任何 codegen（全库 0 个 `.g.dart`）。
每个 State 都是手写的：全 `final` 字段 + `const` 构造 + `copyWith`。

```dart
// lib/features/tasks/providers/task_provider.dart:11-53
class TaskListState {
  final List<Task> tasks;
  final int total;
  final bool loading;
  final String? error;
  final String keyword;
  final String? statusFilter;
  final String? labelFilter;

  const TaskListState({
    this.tasks = const [],
    this.total = 0,
    this.loading = false,
    this.error,
    this.keyword = '',
    this.statusFilter,
    this.labelFilter,
  });

  TaskListState copyWith({ ... });
}
```

**约定**：

- 集合默认值一律 `const []`，不用 `null`
- 构造函数是 `const`，Notifier 初始化写 `super(const TaskListState())`
- **没有** `==` / `hashCode` 重写 → riverpod 靠引用比较，每次 `copyWith` 都会触发重建
- **没有** `toString()` 重写

---

## `_unset` 哨兵：让 `copyWith` 能把可空字段置回 null

这是本仓库一个**非通用但一致**的模式，出现在 4 个文件里。
`copyWith(x: null)` 在标准写法里无法与「不传 x」区分，仓库用一个顶层 `const Object()` 哨兵解决：

```dart
// lib/features/tasks/providers/task_provider.dart:9, 30-51
const _unset = Object();

TaskListState copyWith({
  List<Task>? tasks,
  Object? statusFilter = _unset,          // 注意类型是 Object?，不是 String?
  Object? labelFilter = _unset,
}) {
  return TaskListState(
    tasks: tasks ?? this.tasks,
    statusFilter: identical(statusFilter, _unset) ? this.statusFilter : statusFilter as String?,
    labelFilter: identical(labelFilter, _unset) ? this.labelFilter : labelFilter as String?,
  );
}
```

同样的哨兵在：

- `core/auth/auth_provider.dart:9` — `const Object _authFieldUnset`（用于 `user` 和 `error`）
- `core/storage/secure_storage.dart:6` — `const Object _panelFieldUnset`（用于 `username`/`password`）
- `features/envs/views/env_list_page.dart:18` — `const _selectedGroupUnset`（用于 `selectedGroups`）

**哨兵名字不统一**（`_unset` / `_authFieldUnset` / `_panelFieldUnset` / `_selectedGroupUnset`），
这是现状。新代码沿用这个模式即可，命名建议靠向 `_unset`。

### ⚠️ 反直觉细节：`error` 字段故意**不**用 `??`

```dart
// lib/features/tasks/providers/task_provider.dart:43
error: error,                    // 不是 error ?? this.error
```

`dashboard_provider.dart:73` 同样如此。效果是：**任何一次不显式传 `error` 的 `copyWith`
都会把 error 清空**。这是刻意的（每次新请求自动清掉上次的错误），但很容易被误改成 `error ?? this.error`。
`AuthState`（`auth_provider.dart:34`）则相反，用哨兵保留。**两种语义在仓库里并存。**

---

## 加载与错误：`loading: bool` + `error: String?`，**没有** `AsyncValue`

```dart
state = state.copyWith(loading: true, error: null);
try {
  ...
  state = state.copyWith(tasks: items, loading: false);
} catch (e) {
  state = state.copyWith(loading: false, error: '加载失败');
}
```

### ⚠️ 现状：错误态几乎不存在

**11 个 State 类里只有 4 个有 `error` 字段**：

| 有 `error` | 位置 |
|---|---|
| `AuthState` | `core/auth/auth_provider.dart:15` |
| `TaskListState` | `features/tasks/providers/task_provider.dart:15` |
| `DashboardData` | `features/dashboard/providers/dashboard_provider.dart:29` |
| `SubscriptionListState` | `features/subscriptions/views/subscription_list_page.dart:29` |

| **没有** `error` 字段 | 位置 |
|---|---|
| `EnvListState` | `env_list_page.dart:22-58`，`catch` 只写 `copyWith(loading: false)`（`:118-120`） |
| `LogListState` | `log_list_page.dart:19-55`，同上（`:93-95`） |
| `NotificationListState` | `notification_list_page.dart:59-81` |
| `UserListState` | `user_list_page.dart:67` |
| `DepListState` | `dep_list_page.dart:23-62` |
| `ScriptState` | `script_list_page.dart` |

**而且即使有 `error`，UI 也基本不读它**。全库唯一消费 provider error 的地方是登录页：

```dart
// lib/features/login/views/login_page.dart:198
: ref.read(authProvider).error ?? '登录失败';
```

`TaskListState.error`、`DashboardData.error`、`SubscriptionListState.error` 被赋值但**从未被渲染**。
断网时用户看到的是「暂无任务 / 暂无日志 / 暂无环境变量」，不是错误提示，也没有重试按钮。

> **第 0 期 R3 要修这个。** 新增列表 provider 时：
> 1. State 必须带 `error` 字段；
> 2. UI 必须区分「空列表」与「请求失败」，失败时显示原因 + 重试。

### 例外：`_RestoreProgressState` 的 error 是非空 String

`features/system/views/backup_page.dart:170` 用 `final String error`（默认 `''`），
并且**真的在 UI 里渲染**（`:1125-1138`）。这是全库唯一「错误态可见」的实现，可作参考。

---

## 派生状态：写成 State 的 getter

不用单独的 provider，直接在 State 类里做计算：

```dart
// lib/features/dashboard/providers/dashboard_provider.dart:39-61
double get cpuUsage => (system['cpu_usage'] as num?)?.toDouble() ?? 0;
int get disabledTasks => totalTasks - enabledTasks;
String get memoryTotal => _formatBytes(system['memory_total']);
```

模型上同理（`shared/models/task.dart:70-117`：`isRunning`、`statusText`、`labelList`、`groupName`…）。

`DashboardData` 特殊：它把两个接口的原始响应存成 `Map<String, dynamic>`
（`system` / `dashboard`），字段访问全部通过 getter 做类型转换，**没有中间模型类**。

---

## 认证状态机

```dart
// lib/core/auth/auth_provider.dart:7
enum AuthStatus { unknown, unauthenticated, authenticated }
```

`unknown` 是启动初态，路由据此把用户挡在 `/boot`（`app_router.dart:65-70`）。

路由订阅认证状态用了一个**桥接 provider**（把 riverpod 变化转成 `Listenable`）：

```dart
// lib/core/router/app_router.dart:34-45
class _AuthNotifierBridge extends ChangeNotifier {
  _AuthNotifierBridge(Ref ref) {
    ref.listen<AuthStatus>(authProvider.select((s) => s.status), (_, __) => notifyListeners());
  }
}
final _authNotifierProvider = Provider<_AuthNotifierBridge>((ref) => _AuthNotifierBridge(ref));
```

`GoRouter.redirect` 内部**用 `ref.read` 而不是 `ref.watch`**，注释写明了原因：
「每次 redirect 时实时读取最新状态（不用 watch）」（`app_router.dart:56`）。

---

## `ProviderContainer` 在 `main()` 中手动创建

不是简单的 `ProviderScope`：

```dart
// lib/main.dart:20-37
final container = ProviderContainer();
DioClient.instance.dio.interceptors.insert(0, AuthInterceptor(
  onAuthFailed: () => container.read(authProvider.notifier).setUnauthenticated(),
));
await container.read(authProvider.notifier).restoreTrustedLocalSession();
runApp(UncontrolledProviderScope(container: container, child: const DaidaiApp()));
```

原因：拦截器需要在 `runApp` 之前就能访问 provider。
**改动 `main.dart` 时不要把它换回 `ProviderScope`**，会切断 `onAuthFailed` 的回调链。

---

## 常见错误

| 错误 | 后果 |
|---|---|
| 把 `error: error` 改成 `error: error ?? this.error` | 错误提示不再自动清除，一次失败后永远显示 |
| 新 State 忘记加 `error` 字段 | 断网时又多一个「暂无数据」页面 |
| `copyWith` 里用 `String? x` 而不是 `Object? x = _unset` | 无法把该字段置回 null，筛选条件清不掉 |
| 给 provider 加 `.autoDispose` | 底部导航 5 个 tab 常驻（`NoTransitionPage`），切 tab 会丢状态并重复请求 |
| 在 Notifier 的写操作里加 try/catch 吞掉异常 | UI 侧 `_showActionError` 拿不到错误，操作失败静默 |
