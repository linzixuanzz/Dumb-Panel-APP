# 质量标准

> lint 配置、告警基线、测试现状、禁止/必须模式。全部按当前仓库实测。

---

## 静态分析配置

`analysis_options.yaml` 只做了一件事：

```yaml
include: package:flutter_lints/flutter.yaml
```

`linter.rules` 下**全是注释掉的示例**，没有启用或禁用任何自定义规则
（`analysis_options.yaml:23-25`）。`flutter_lints: ^6.0.0`（`pubspec.yaml:46`）。

**没有** `analyzer.errors` 段、没有 `exclude`、没有 strict 模式配置。
全库**没有任何** `// ignore:` 或 `// ignore_for_file:` 注释——lint 告警是靠「忍着」而不是屏蔽的。

---

## 告警基线：7 个 info（不得增加）

`flutter analyze` 当前输出 **7 个 info，0 warning，0 error**，全部是既有问题：

| 规则 | 数量 | 已定位的成因 |
|---|---|---|
| `use_build_context_synchronously` | **5** | `await` 之后使用 `BuildContext`，守卫不到位。file:line 清单见下 |
| `library_private_types_in_public_api` | 2 | 公开类 `UserListState` 暴露私有类型 `_User`（`user_list_page.dart` 的 `final List<_User> items` 与 `copyWith({List<_User>? items})`） |

> 之前这张表写的是「4 + 2 + 同类 info 1」，那个「同类 1」是含糊记法。
> 实测就是 **5 + 2**。**只比对总数会漏掉「修好一个又新增一个」**，
> 改动前后请比对 file:line 清单本身。

> **硬性要求（对应第 0 期 A8）**：任何改动后 `flutter analyze` **不得超过 7 个 info**。
> 修掉旧的可以，新增的不行。

### `library_private_types_in_public_api` 的根因

`user_list_page.dart` 里定义了一个私有 `_User` 模型，同时
`lib/shared/models/user.dart` 已有公开的 `User`。两者字段大量重合。
**新代码不要再制造这种影子模型**——需要页面私有模型时，要么复用 `shared/models/`，
要么让承载它的 State 类也保持私有。

### `use_build_context_synchronously` 的 5 处在哪、为什么

清单以 `flutter analyze --no-pub` 实跑输出为准（最近一次：2026-10-09，v1.4.0 开发中，7 issues）。
**这 5 处分两种成因，修法不同，别当成一类批量改。**

#### 甲类（4 处）：判错了对象

判的是 State 的 `mounted`，用的却是 builder 传下来的另一个 `BuildContext`。
`if (!mounted)` 保证的是 State 还在，保证不了那个对话框的 `ctx` 还挂在树上：

```dart
// lib/features/notifications/views/notification_list_page.dart:689-692
await ref.read(notificationListProvider.notifier).update(channel.id, payload);
if (!mounted) return;          // 判的是 State
Navigator.of(ctx).pop();       // 用的是 builder 的 ctx → 仍然告警
```

| 位置 | 那个「别人的 context」 |
|---|---|
| `notification_list_page.dart:692` | `showModalBottomSheet` 的 `ctx` |
| `open_api_page.dart:809` | `showDialog` 的 `dialogCtx` |
| `security_page.dart:872` | `showDialog` 的 `dialogCtx` |
| `user_list_page.dart:498` | `showDialog` 的 `dialogCtx` |

> 行号会随任何改动漂移（2026-10-09 核过）。**逐条比对时以「文件 + 规则名」为准，
> 行号只当线索**；直接跑 `flutter analyze` 拿当前清单最可靠。

修法：照下面「正确写法」改成 `if (ctx.mounted && ModalRoute.isCurrentOf(ctx) == true) { …pop(); }`，
页面的 `mounted` 只留给后面用页面 `context` 的提示。**只把 `if (!mounted)` 换成 `if (!ctx.mounted)` 不够**：
lint 不再报，但弹层 / 对话框退场动画期间 `ctx.mounted` 仍为 true，连点或刚关掉就回包时会再 pop 一次、把本页弹掉。

#### 乙类（1 处）：判对了，但分析器证明不了

`script_list_page.dart:3222`，在 `_ScriptDebugRunSheetState`（类定义 `:3042`）的
`build(BuildContext context)`（`:3175`）里：

```dart
await Clipboard.setData(ClipboardData(text: _logs.join('\n')));
if (!mounted) return;                     // State.mounted
AppSnack.success(context, '已复制调试日志'); // :3222 — build 的 context 参数
```

这里的 `context` **实际上就是** `State.context`，运行期没有问题。但 lint 无法证明
build 的形参与 `State.context` 同一，所以照样报 `unrelated 'mounted' check`。
修法只是把 `if (!mounted)` 改成 `if (!context.mounted)` 一行，不要按甲类去找什么
「别人的 context」——这个文件里没有。

> **这一处曾经找不到。** 用 `Navigator.of(` 搜整个文件会漏掉它，因为它是
> `ScaffoldMessenger.of(`。查这条 lint 时**永远以 analyze 输出为准，不要靠 grep 某个符号**。

### `use_build_context_synchronously` 的正确写法

```dart
// lib/features/envs/views/env_list_page.dart 的 _showDetailSheet「保存」（:2031-2067，v1.4.0）
final navigator = Navigator.of(ctx);                       // await 之前取出（ctx 是弹层 builder 的）
await ref.read(envListProvider.notifier).update(...);
if (ctx.mounted && ModalRoute.isCurrentOf(ctx) == true) {  // 弹层：还挂着，而且仍是最上面那层路由
  navigator.pop();
}
if (!mounted) return;                                      // 页面：只守后面用页面 context 的提示 / setState
AppSnack.success(context, '已保存');                        // 页面自己的 context，不是 ctx
```

这里原先的示例是「先存 `navigator` → `await` → 只判页面 `mounted` → `pop`」，正是 v1.4.0 修掉的写法：弹层已被用户关掉
（或前一次回包关过）时照样 pop，弹掉的是本页。只判 `ctx.mounted` 能让 lint 闭嘴，却挡不住退场动画期间的第二次 pop。
两半为什么都要、失败分支怎么写回弹层、要补哪两条用例，见 [component-guidelines.md](./component-guidelines.md)「`BuildContext` 跨异步使用」。

### ⚠️ 这条门禁**完全不覆盖** `android/` 下的 Kotlin

`flutter analyze` 只看 Dart。`MainActivity.kt` 写成什么样、`AndroidManifest.xml`
少声明了哪个组件，它一个字都不会说，**CI 同样没有 Kotlin 门禁**
（`.github/workflows/` 下既没有 `ktlint` 也没有 `compileKotlin`）。

所以：**改了 `android/` 下任何东西，「analyze 绿 + test 绿」不构成验证**，
必须另跑一次真实编译：

```powershell
flutter build apk --debug          # 或
cd android; ./gradlew :app:compileDebugKotlin
```

跑之前先看下面「构建与工具链注意」里的 `JAVA_HOME` 一条，
这台机器直接跑 gradlew 会撞上一个误导性极强的报错。

---

## 测试现状

```
test/
├── support/
│   ├── fake_http_adapter.dart          手写假 HttpClientAdapter + jsonResponse + dioWithAdapter
│   └── fake_sse_http_client.dart       手写假 http.BaseClient + sseResponse / emptyResponse
├── core/
│   ├── auth/auth_interceptor_test.dart  401 续期链路（续期成功/失败/防死锁/并发排队/noRefreshPaths）
│   ├── auth/token_refresher_test.dart   单次续期（并发共用/dio 与 SSE 共用/失败不钉死）
│   └── network/sse_client_test.dart     SSE 401 → 续期 → 重连（无感/不无限重试/额度归还）
├── shared/utils/sse_replay_buffer_test.dart  重连历史重放去重（宁可重复不能吞行）
├── features/
│   ├── list_error_state_test.dart      TaskListState / LogListState 的 error 语义与清空
│   └── notifications/channel_config_test.dart  通知渠道配置合并（未知字段不丢）
└── widget_test.dart                     空态 vs 错误态的渲染差异
```

> ⚠️ **上面这棵树不是全量**，它停在第 0/1 期的形态。`test/` 下实际有 **43 个 `*_test.dart`、619 个用例**
> （2026-10-09 glob + 实跑，v1.4.0 开发中），树里只画了 7 个。没画进来的包括：`features/system/system_config_schema_test.dart`、
> `features/notifications/notify_field_schema_test.dart`、`features/tasks/cron_schema_test.dart`、
> `features/subscriptions/subscription_auth_test.dart`、`features/envs/env_transfer_test.dart`、
> `features/logs/raw_log_download_test.dart`、`shared/panel_enums_test.dart`、
> `shared/duration_utils_test.dart`、`shared/utils/api_utils_test.dart`，日志视图那三份：
> `shared/utils/log_line_buffer_test.dart`、`shared/widgets/log_view_test.dart`、
> `features/tasks/task_live_log_page_test.dart`（写法见下方「日志视图与实时日志页的测试约定」），
> 以及 v1.4.0 新增的 `features/envs/env_sort_test.dart`、`features/envs/env_important_test.dart`、
> `features/dashboard/trend_chart_test.dart`（写法见下方「widget 测试的写法约束」）。
> **判断某条链路有没有测试请直接 glob `test/**/*_test.dart`，不要只看这棵树。**

> `TokenRefresher` 是单例，`setUp` 里必须调 `resetForTest()`：
> 不重置的话上一条用例注入的假 dio 会被下一条复用，出现查半天的假红/假绿。

> 历史：`widget_test.dart` 原来只有一个用例体是 `// TODO` 的空壳，
> 「`flutter test` 1 个用例通过」是**假绿**。第 0 期 R5 已经替换掉。

`dev_dependencies` 仍然只有 `flutter_test` + `flutter_lints` + `flutter_launcher_icons`
（`pubspec.yaml:43-47`），**没有** `mocktail` / `mockito` / `http_mock_adapter` / `integration_test`，
第 0 期补测试时也没有新增。

### 怎么在不加依赖的情况下假造 HTTP

dio 允许整体替换 `dio.httpClientAdapter`，接口只有 `fetch` + `close` 两个方法，
手写一个即可（`test/support/fake_http_adapter.dart`）。这样拦截器、transformer、
`validateStatus`、`DioException` 全是真的，只有网络是假的：

```dart
final dio = dioWithAdapter(FakeHttpAdapter(
  (options) => jsonResponse({'error': 'token 已过期'}, status: 401),
));
```

`ResponseBody` 必须带 `content-type: application/json`，否则 dio 的 transformer 不解码，
`response.data` 会是一整串未解析的字符串。

安全存储用 `FlutterSecureStorage.setMockInitialValues({...})`
（flutter_secure_storage 自带的内存实现，不需要 mock 平台通道）。

SSE 不经 dio。页面内部自己 `new SseClient()` 时，用 `http.runWithClient(body, () => FakeSseHttpClient(...))`
注入（`SseClient` 的默认工厂是 `http.Client()`，它认 zone），不用给页面加构造参数；
完整写法见下方「日志视图与实时日志页的测试约定」第 5 条。

### 可测性改造：Notifier 的可选 `Dio` 参数

碰 dio 的 10 个 Notifier（`Task` / `TaskView` / `LogList` / `EnvList` / `DepList` / `Script` /
`NotificationList` / `SubscriptionList` / `UserList` / `Dashboard`）与 `AuthInterceptor`
都有**仅供测试**的可选注入参数：

```dart
TaskNotifier({Dio? dio}) : _injectedDio = dio, super(const TaskListState());
Dio get _dio => _injectedDio ?? DioClient.instance.dio;
```

**不要在构造时就把 `DioClient.instance.dio` 存进字段**：单例的 baseUrl 会随切换面板
被改写，存下来会拿到旧地址。新增碰 dio 的 Notifier 时照抄这个形状。

### 新增功能至少要覆盖什么

按第 0 期 R5 的定位（不追覆盖率，只保护「改错了用户会丢数据」的地方）：

| 类别 | 最低要求 |
|---|---|
| 触碰认证/token 链路 | 必须有测试覆盖 401 → 续期 → 重发 的路径 |
| 触碰「读取-修改-回写」的表单 | 必须有测试证明**未知字段不丢失**（见下方通知渠道案例） |
| 触碰列表 provider | 必须有测试证明请求失败时 `error` 被设置且能被 UI 消费 |
| 纯 UI 调整 | 不强制 |
| 触碰日志视图（`LogView` / `LogLineBuffer` / 实时日志页） | 新分支配结构性断言与 `debugPrintLayouts` 计数，**不写计时断言**，见下方「日志视图与实时日志页的测试约定」 |
| 触碰弹层 / 对话框里 `await` 之后的 `pop` | 「请求在飞时先把弹层关掉」「连点两下」两条 widget 用例（回包后本页仍在），见下方「widget 测试的写法约束」第 3 条 |
| 新增 `shared/utils/` 函数 | 建议补纯函数单测（这类最容易测，已经有 `api_utils` / `duration_utils` / `sse_replay_buffer` 三份可以照抄） |

**注入点已经齐了**：全库 12 个 `StateNotifier`，碰 dio 的 10 个都带 `{Dio? dio}`（见上），
剩下 2 个（`AuthNotifier` 走 `AuthService`、`AppLockController` 走 `SecureStorage`）本来就不碰 dio。
给任何列表 provider 补测试都不用再先改构造函数，直接 `XxxNotifier(dio: dioWithAdapter(...))`。

> 上表「触碰列表 provider 必须有测试证明 `error` 被设置且能被 UI 消费」的现成写法：
> Task / Log 在 `test/features/list_error_state_test.dart`，
> Notification / User / Dep / Script / Subscription 在 `test/features/list_error_state_more_test.dart`，照抄即可。

### 日志视图与实时日志页的测试约定（#10 / APP #15）

目的：让「卡不卡」「选区跑没跑」这类以前只能上真机看的东西，在 `flutter test` 里有稳定的断言。
现成写法在 `test/shared/widgets/log_view_test.dart`、`test/shared/utils/log_line_buffer_test.dart`、
`test/features/tasks/task_live_log_page_test.dart`；契约本身见 component-guidelines.md「日志正文」
与 hook-guidelines.md「实时日志页」。

1. **只做结构性断言，不计时。** JIT debug 的耗时同一个用例跑两次能差 ±30%。该断言的是：
   - 下方列表行数：key 以 `log-below-` 开头的 `SliverPadding`（`skipOffstage: false`）下的 `SliverList`，
     `(delegate as SliverChildBuilderDelegate).childCount` 在跟随中 ≤ 200；
   - 走的是重建还是原地滑：比较前后 `log-below-<代号>` 这个 key，变了就是走了 `_jumpToLatest`；
   - 停在底部：`position.pixels` 与 `maxScrollExtent` 差 ≤ 0.5，最新一行 `findsOneWidget`。
2. **一帧排了多少行，用 `debugPrintLayouts` 数。** 置 `debugPrintLayouts = true`、临时替换 `debugPrint`，
   数以 `Laying out` 开头且含 `RenderParagraph` 的消息，推一帧 `pump(16ms)`，`finally` 里两样都还原
   （不还原会污染后面的用例）。这个数只在真正执行布局时才涨，和机器快慢、编译模式都无关。阈值：
   原地滑的帧 **≤ 100**（一屏约 30 行加缓存区）；`_jumpToLatest` 重建的那几帧 **≤ 210**
   （尾段 200 行 + 余量，#10 就定下的代价）。改前贴底的那一帧是几千。
   必须保留的一条：从 9800 行起逐行追加越过 1 万行上限、每 20 行出一帧，60 帧都 ≤ 100——
   它钉的是「浮动上限 + 锚点不动」的灾难帧，#10 的原测试全绿也测不出来。
3. **选区用鼠标拖。** 触摸拖动会滚动列表。`tester.startGesture(pos, kind: PointerDeviceKind.mouse)` →
   `moveTo` → `up`，并 `addTearDown(gesture.removePointer)`。读选中的字：遍历 `tester.binding.renderViews`
   下的 `RenderParagraph`，对 `selections` 里不折叠的取 `selection.textInside(plainText)`；
   清选区：`tester.state<SelectableRegionState>(find.byType(SelectableRegion)).clearSelection()`。
4. **改实现、对外语义不变时，把旧实现搬进测试当对照。** `_OriginalBuffer` 就是改造前逐行搬表的
   `LogLineBuffer`；随机操作序列逐步比对，`maxLines` 要同时覆盖 < 10 和 ≥ 10（两条代码路径）。
   几十万次逐行比较用 `if (...) fail(...)`，逐个 `expect` 太慢。
5. **页面级：真实页面 + 假 dio + 假 SSE，不改页面构造。**

   ```dart
   setUp(() {
     FlutterSecureStorage.setMockInitialValues({});
     DioClient.instance.setBaseUrl('https://panel.test');
   });
   // 页面直接用 DioClient 单例：换掉它的适配器（responder 可以是 async，用来模拟慢网）
   DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter((options) { /* 按 path 回 */ });
   // SseClient 的默认工厂是 http.Client()，认 zone：用 runWithClient 注入假客户端
   await http.runWithClient(() async {
     await _openPage(tester);
     // ……断言……
     await _closePage(tester);
   }, () => FakeSseHttpClient((_) => sseResponse(frame)));
   ```

   - 页面 AppBar 里有常驻的转圈，**不能 `pumpAndSettle`**：用固定次数的 `pump(Duration)` 推进
     （`_openPage` 是 `pumpWidget` 后推 20 次 20ms；轮询一秒一跳，等它放弃要推够 17 秒）；
   - 收尾（`_closePage`）先 `pumpWidget(const SizedBox())` 再 `pump(3s)`，把重连、提示条这些定时器放完；
   - 回落了几次用 `FakeHttpAdapter.countOf(path)` 数；「复制全部」的内容用
     `setMockMethodCallHandler(SystemChannels.platform, …)` 截 `Clipboard.setData`，`addTearDown` 里置回 null；
   - **造数照面板的真实形状**：快照照 `ReadLastLines` 取最后 4096 字节、`utf8.decode(allowMalformed: true)`
     后按 `\n` 切（首行半截、末尾一个空串）；历史照 `writeSSEData` 写成一个帧、每行一条 `data:`；
     「快照恰好从历史第 2 行开始」用 65 行、后 64 行每行连换行正好 64 字节（合计 4096）来造，
     并先断言这个前提成立。

### widget 测试的写法约束（APP #16 起）

现成写法在 `test/features/envs/env_sort_test.dart`（假服务端照抄面板语义、并发与回滚）与
`test/features/envs/env_important_test.dart`（形状探测、弹层、窄屏与键盘）。照写会挂或测错的几处：

1. **`testWidgets` 里不要直接 `await` notifier 的异步方法。** `testWidgets` 跑在 FakeAsync 里，dio 驱动的 Future 等不到，
   会一直挂到 10 分钟超时。要写成：

   ```dart
   final container = ProviderScope.containerOf(tester.element(find.byType(EnvListPage)));
   await tester.runAsync(() => container.read(envListProvider.notifier).load());
   await tester.pump();
   ```

   只经 `tap` / `onReorder` 触发、随后 `pumpAndSettle` 的用例不受影响；纯 notifier 用例（`test(...)`）照常直接 `await`。
2. **改窗口尺寸必须同时设 `tester.view.devicePixelRatio = 1.0`**，并 `addTearDown(tester.view.reset)`。默认像素比是 3.0，
   只设 `physicalSize = Size(384, 800)` 实际只有 128×267 逻辑像素，什么都会溢出。模拟键盘弹起：
   `tester.view.viewInsets = const FakeViewPadding(bottom: 300)` + `addTearDown(tester.view.resetViewInsets)`；
   不溢出的断言是 `expect(tester.takeException(), isNull)`。🔴 **窄屏一律用 360 宽，并加一条 textScale 1.3**（APP #21，v1.4.3）：
   360dp 是最常见的安卓宽度（#21 报告人的手机就是）。以前这里写「环境变量页页头在 360 宽本来就溢出 22px，所以改用 384」，
   等于把真 bug 绕过去了——用户的「+」被挤出屏幕点不中，测试却一直是绿的。页头已修，**不要再为了让断言变绿而放宽宽度**；
   360 下红了就是要修的布局问题。页头回归测试见 `test/features/page_header_narrow_test.dart`。
3. **测「请求在飞时」的用户操作，用 `Completer` 挂住应答。** `FakeHttpAdapter` 的 responder 可以返回 Future：
   `gate.future.then((_) => jsonResponse({...}))`（`ResponseBody` 的流只能读一次，每个请求现造一个）。
   - 页面用例：发起操作 → 先断言前提（请求已发出、还没重拉、弹层还开着）→ 做那个操作（`tester.tapAt(const Offset(400, 40))`
     点遮罩关弹层并 `pumpAndSettle` 等退场走完；或 `tap` → `pump()` → 再 `tap` 连点两下）→ `gate.complete()` →
     `pumpAndSettle` → 断言。**还要断言回包确实处理过**（重拉次数 +1、成功提示出现），否则用例可能在空转。
   - notifier 用例：假服务端在请求到达时完成一个 `arrived` Completer，`await arrived.future` 之后再发第二个操作
     （`env_sort_test.dart` 的 G2 / G4）。
4. `FakeHttpAdapter` 只记 method / path（和请求体字节数），**不记 query、也不记 `options.data`**：要断言请求体或 query，
   就在 responder 里自己记 `options.data` / `options.queryParameters`，请求体用相等断言（`{'important': true}`），
   「不该带某个键」用 `containsKey(...) isFalse`。造「老面板没有这个键」的列表项用空感知元素 `'important': ?important`
   （值为 null 时整个键都不放）。
5. 弹层里输入框还聚焦着就点「保存」且成功时，会撞上 component-guidelines.md「`BuildContext` 跨异步使用」末尾记的
   dispose 时机问题（debug 下报「… was used after being disposed」）。只测请求体的用例先
   `FocusManager.instance.primaryFocus?.unfocus(); await tester.pump();` 再点。

---

## 禁止的写法

| 禁止 | 原因 | 反例 |
|---|---|---|
| 请求 URL 直接拼字符串 | 绕过 `ApiEndpoints`，改路径时漏改 | **历史问题，已修，全库零命中**。原先是 `system_settings_page` 三处 `'${ApiEndpoints.baseApi}/system/...'`，现已收进 `ApiEndpoints.systemUpdateStatus` / `systemUpdate` / `systemRestart`（`api_endpoints.dart:23-27`）。别再照旧行号去找，那三行现在是别的代码 |
| 在页面里自己 `response.data['data']` | 后端有 3 种包裹形态 | 应用 `extractData` / `extractPaginated`（`api_utils.dart`） |
| 编辑表单时用空 map 重建再整串覆盖 | **用户在 Web 配的字段会被静默清空** | `notification_list_page.dart:735-757` |
| 后端已暴露的默认值写死在客户端 | 面板改配置后 APP 不跟随 | 参考已修正的 `task_form_page.dart:223-266` |
| 裸 `Color(0xFF...)` | 绕过 `AppColors` / `ColorScheme`，主色切换时漏改 | 已清零。历史反例：三处状态徽章写死 Emerald 深绿 `Color(0xFF047857)`，主色换蓝后成了深绿字配浅蓝底 |
| 用 `AppColors.primary` / `blue500` 表达「成功 / 已启用」 | 主色本身就是蓝，会与「运行中 / 进行中」撞色 | 用 `AppColors.success` / `successDark` / `successLight` |
| 写裸 `BorderRadius.circular(<字面量>)` | 已收敛成 `AppRadius` 五档且活代码零字面量 | 用 `control/sm/md/lg/pill`，禁止第六档 |
| 删 `boxShadow` 后不给 `BoxDecoration` 补 `const` | `flutter_lints` 的 `prefer_const_constructors` 会**当场多出一批新 info**，顶破「≤ 7 个」门禁 | 删完检查 `BoxDecoration` 是否已全是编译期常量 |
| `ReorderableListView` 的 key 挂到 itemBuilder 返回值的 **child** 上 | 运行时抛 `Every item of ReorderableListView must have a key`，**`flutter analyze` 完全看不出来** | key 必须在 `itemBuilder` 返回的**顶层 widget**上（迁 `AppCard` 时写 `AppCard(key: ...)`） |
| 给 `Material` 同时传 `shape` 和 `borderRadius` | 两者互斥，**运行时 assert**，analyze 看不出来 | 用 `shape: RoundedRectangleBorder(borderRadius:, side:)`，把并列那行 `borderRadius:` 删掉 |
| 迁移带自定义颜色的卡片时不显式传 `color`/`borderColor` | 会被 `AppCard` 默认值静默打回。真实案例：订阅拉取日志块的底色是**用户自选的日志主题**（`logTheme.background`），落到默认会把深色终端底换成白卡，ANSI 文字直接不可读 | 迁移前先记下原始颜色，迁完逐个比对 |
| 给 provider 加 `.autoDispose` | 底部导航 tab 常驻，会丢状态并重复请求 | |
| Notifier 的**写操作**里 try/catch 吞异常 | UI 的 `_showActionError` 拿不到错误，失败静默 | |
| 新增 `// ignore:` 注释 | 全库目前零使用，加了就破坏「基线 7 个 info」的可读性 | |
| 异步的原生操作在 `MethodChannel` handler 里立刻 `result.success` | 「提交后才知道成败」的链路（安装、下载、任何要等系统广播的动作）一旦提前收口，**分级错误码永远到不了 Dart 侧**，用户只会看到一个笼统的失败 | 把 `result` 挂起、等系统回调再由唯一出口回一次，写法见 `MainActivity.kt` 的 `InstallResultReceiver.begin/finish` |
| 挂起 `result` 却不配兜底超时 | 个别 ROM 一条广播都不回，Dart 侧的 `Future` 永挂，弹窗永远停在「正在安装」 | `begin()` 里 `postDelayed` 一个超时任务，`finish()` 里撤销；并保证同一个 `result` 只会被回一次 |

---

## 必须遵守的写法

1. **`await` 之后碰 `context` 先判 `mounted`**，或提前把 `ScaffoldMessenger` / `Navigator` 取出来；
   弹层 / 对话框关自己之前判 `ctx.mounted && ModalRoute.isCurrentOf(ctx) == true`（见 component-guidelines.md「`BuildContext` 跨异步使用」）。
2. **模型 `fromJson` 必须防御式解析**（不做裸 `as`），见 [type-safety.md](./type-safety.md)。
3. **错误文案统一走 `extractErrorMessage(error, fallback)`**，不要直接 `e.toString()`。
4. **端点常量加到 `ApiEndpoints`**，带参数的写成静态方法。
5. **写操作后 `await load()` 重拉**，与现有 provider 保持一致。
6. **中文文案**：全部 UI 文案、注释、提交信息用中文，与仓库现状一致。

---

## 注释风格

代码注释**记录「为什么」和踩过的坑**，不解释「是什么」。这是仓库里执行得相当好的一条，值得延续：

```dart
// lib/features/tasks/providers/task_provider.dart:234
// 面板批量任务接口使用 task_ids 字段，不能复用环境变量的 ids 字段。

// lib/features/envs/views/env_list_page.dart:193-195
// 一次 `all=1` 拉全（面板 v2.1.7 起认，上限 5000 条），不再按 page_size=100 逐页拉：
// 逐页拉取不是快照，翻页途中有人排序 / 增删，会重复一行、丢一行（APP #16 已实测），
// 而拖拽排序正是拿这份列表算锚点的。

// lib/core/auth/auth_provider.dart:207
// NAS / Nginx Proxy Manager 反代旧面板时，登录接口可能因为 CORS 来源端口不一致返回 403。

// lib/features/tasks/providers/task_provider.dart:124-125
// 只在非空时才带上：面板对空 filters 走的是 SQL 分页快路径，
// 带一个 `[]` 会把它推进「全表进内存再过滤」的慢路径。
```

> 这里原先的第四条范例是「后端当前没有独立的任务排序接口，但任务更新接口允许写入 sort_order」，
> v1.3.8 拖拽排序改走 `PUT /tasks/sort` 后那句注释连同逐条写 `sort_order` 的代码一起删了。
> 注释写的是「为什么」，前提一变它就成了反话——**改代码时同一处的注释要跟着改或删**。

> 少量注释是英文（`app_update_service.dart:106`、`:152`），绝大多数是中文。新注释写中文。
> 原先这里举的英文例子（`env_list_page.dart` 里「page_size 上限 100」那两行）v1.4.0 改 `all=1` 时换成了上面那段中文注释。

---

## 代码审查清单

改动提交前逐条自检：

- [ ] `flutter analyze` ≤ 7 个 info，且没有新增类型
- [ ] `flutter test` 全绿
- [ ] 新增/修改的请求路径在 `ApiEndpoints` 里
- [ ] 响应解包走 `api_utils.dart` 而不是手写 `['data']`
- [ ] 「读取-修改-回写」的地方，未知字段被保留了
- [ ] `await` 之后没有裸用 `context`；弹层回调里的 `pop` 判的是 `ctx.mounted && ModalRoute.isCurrentOf(ctx) == true`，弹层不关时失败原因写回了弹层
- [ ] 请求失败时用户看得见原因，不是「暂无数据」也不是假的「保存成功」
- [ ] 没有引入新的圆角取值 / 裸颜色 / 影子模型
- [ ] 如果动了 `dio_client.dart` 的 `validateStatus`，**所有**受影响调用点都逐个确认过
- [ ] 如果动了 `android/`（Kotlin / Manifest），另跑过 `flutter build apk --debug` 或 `gradlew :app:compileDebugKotlin`——analyze 与 test 都看不见那一侧
- [ ] 如果动了平台通道的错误码，Dart 侧 `_installErrorText` 与原生侧同步改过
- [ ] 如果动了 `LogView` / `LogLineBuffer` / 实时日志页：`log_view_test`、`log_line_buffer_test`、`task_live_log_page_test` 全过；新加的「跟随但锚点不滑」分支同时设了 `holdTrim`（见 component-guidelines.md「日志正文」）

---

## 构建与工具链注意

- Flutter SDK 装在 `D:\GitHub\Dumb Panel\flutter_windows_3.41.9-stable\`，
  **路径含空格会让 `flutter test` 在 native assets 构建阶段失败**
  （hook runner 未给 dart 可执行文件加引号）。
  当前用目录联接 `D:\flutter-nospace` 绕过。

### ★ `JAVA_HOME` 指着 Java 8，跑 Gradle 前必须先改（本机实测，v1.3.7）

本机 `JAVA_HOME` 是 `C:\Program Files\Eclipse Adoptium\jdk-8.0.502.7-hotspot\`，
而 AGP 8.11.1 + Gradle 8.14（`android/settings.gradle.kts`、`gradle-wrapper.properties`）
**要求 JDK 17**。

**坑在报错本身**：版本不对时 Gradle 不会说「需要 JDK 17」，而是先抛

```
Could not read workspace metadata from ...\metadata.bin
```

照着这句去查会一路查到缓存损坏上，方向完全是错的。**认准这条报错 = JDK 版本不对。**

正确做法，跑任何 `gradlew` 之前先切：

```powershell
$env:JAVA_HOME = "C:\Program Files\Java\jdk-17"
```

如果之前已经用 Java 8 起过 Gradle，残留的 daemon 会继续用旧 JDK，光改环境变量没用，
还要：

```powershell
cd android; ./gradlew --stop          # 停掉旧 daemon（必要时再手动杀掉残留进程）
Remove-Item "$env:USERPROFILE\.gradle\caches\8.14" -Recurse -Force   # 让缓存重建
```

> `flutter build apk` 会自己挑 JDK（走 Flutter 的 `--android-studio-dir` / `JAVA_HOME` 解析），
> 通常不用手动切；**直接调 `gradlew` 才要**。只想确认 Kotlin 编得过时，
> `flutter build apk --debug` 是省事的那条路。

### ★ 本地 `flutter build apk --release` 产出的是**未签名** APK，装不上

```
apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk
  DOES NOT VERIFY
  ERROR: Missing META-INF/MANIFEST.MF
```

APK 的 `META-INF/` 下只有构建元数据，**没有 `MANIFEST.MF` / `*.SF` / `*.RSA`**。

**根因**（`android/app/build.gradle.kts`）：

```kotlin
buildTypes {
    release {
        if (hasReleaseSigning) {                                  // 本地为 false
            signingConfig = signingConfigs.getByName("release")
        }
```

`hasReleaseSigning` 依赖 `android/key.properties` 或 `KEYSTORE_*` 环境变量，本地都没有，
于是 `signingConfig` 根本不被设置。**AGP 8+ 在 release buildType 没有 signingConfig 时
是直接不签名**，不像老版本会退回 debug key。

历史构建同样如此，只是本地从来没人拿它去装。

**正式发版不受影响**：`.github/workflows/release.yml` 与 `android-build.yml` 会用
`secrets.ANDROID_KEYSTORE_BASE64` 解码出 `.jks` 并生成 `key.properties`。

**本地要出可安装包**：`keytool -genkeypair` 生成 jks 放到**仓库外**，
再 `apksigner sign --ks <jks> --out <签好的> <未签的>`。
这样签出来的包与正式版**签名不同**，装之前必须卸载旧版，本地数据会丢。
`key.properties` 与 `.jks` **绝不能进 Git**。

### CI 没有 format / analyze / test 门禁

`.github/workflows/` 下 grep `dart format` / `analyze` / `flutter test` 均无命中。
也就是说**这三项全靠本地自觉**，CI 不会拦住你。改动后请自己跑。
- `pubspec.yaml` 的 `version:` 同时是 APP 版本号与 build number（当前 `1.3.3+23`），
  发版时 `docs/release-notes/` 下要有对应文件。
