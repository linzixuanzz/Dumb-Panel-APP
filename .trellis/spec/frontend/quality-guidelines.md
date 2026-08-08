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
| `use_build_context_synchronously` | **5** | `await` 之后使用 `BuildContext` 且未先判 `mounted`。分布：`notification_list_page` / `open_api_page` / `script_list_page` / `security_page` / `user_list_page` 各 1 |
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

### `use_build_context_synchronously` 的正确写法

```dart
// lib/features/envs/views/env_list_page.dart:1454-1472
final rootMessenger = ScaffoldMessenger.of(context);   // await 之前先取出
final navigator = Navigator.of(ctx);
await ref.read(envListProvider.notifier).update(...);
if (!mounted) return;                                   // await 之后先判
navigator.pop();
rootMessenger.showSnackBar(const SnackBar(content: Text('已保存')));
```

---

## 测试现状

```
test/
├── support/
│   └── fake_http_adapter.dart          手写假 HttpClientAdapter + jsonResponse + dioWithAdapter
├── core/auth/auth_interceptor_test.dart 401 续期链路（续期成功/失败/防死锁/并发排队/noRefreshPaths）
├── features/
│   ├── list_error_state_test.dart      TaskListState / LogListState 的 error 语义与清空
│   └── notifications/channel_config_test.dart  通知渠道配置合并（未知字段不丢）
└── widget_test.dart                     空态 vs 错误态的渲染差异
```

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

### 可测性改造：Notifier 的可选 `Dio` 参数

`TaskNotifier` / `LogListNotifier` / `AuthInterceptor` 都加了**仅供测试**的可选注入参数：

```dart
TaskNotifier({Dio? dio}) : _injectedDio = dio, super(const TaskListState());
Dio get _dio => _injectedDio ?? DioClient.instance.dio;
```

**不要在构造时就把 `DioClient.instance.dio` 存进字段**：单例的 baseUrl 会随切换面板
被改写，存下来会拿到旧地址。要给别的 Notifier 补测试时照抄这个形状。

### 新增功能至少要覆盖什么

按第 0 期 R5 的定位（不追覆盖率，只保护「改错了用户会丢数据」的地方）：

| 类别 | 最低要求 |
|---|---|
| 触碰认证/token 链路 | 必须有测试覆盖 401 → 续期 → 重发 的路径 |
| 触碰「读取-修改-回写」的表单 | 必须有测试证明**未知字段不丢失**（见下方通知渠道案例） |
| 触碰列表 provider | 必须有测试证明请求失败时 `error` 被设置且能被 UI 消费 |
| 纯 UI 调整 | 不强制 |
| 新增 `shared/utils/` 函数 | 建议补纯函数单测（这类最容易测，目前一个都没有） |

**测试的现实障碍**：除 `TaskNotifier` / `LogListNotifier` 外，其余 Notifier 仍然直接使用
`DioClient.instance.dio` 单例（`env_list_page.dart`、`dep_list_page.dart` …），无法注入假 dio。
若要给它们补测试，先按上面的形状加可选 `Dio` 构造参数。

---

## 禁止的写法

| 禁止 | 原因 | 反例 |
|---|---|---|
| 请求 URL 直接拼字符串 | 绕过 `ApiEndpoints`，改路径时漏改 | `system_settings_page.dart:265/349/419` |
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

---

## 必须遵守的写法

1. **`await` 之后碰 `context` 先判 `mounted`**，或提前把 `ScaffoldMessenger` / `Navigator` 取出来。
2. **模型 `fromJson` 必须防御式解析**（不做裸 `as`），见 [type-safety.md](./type-safety.md)。
3. **错误文案统一走 `extractErrorMessage(error, fallback)`**，不要直接 `e.toString()`。
4. **端点常量加到 `ApiEndpoints`**，带参数的写成静态方法。
5. **写操作后 `await load()` 重拉**，与现有 provider 保持一致。
6. **中文文案**：全部 UI 文案、注释、提交信息用中文，与仓库现状一致。

---

## 注释风格

代码注释**记录「为什么」和踩过的坑**，不解释「是什么」。这是仓库里执行得相当好的一条，值得延续：

```dart
// lib/features/tasks/providers/task_provider.dart:134
// 面板批量任务接口使用 task_ids 字段，不能复用环境变量的 ids 字段。

// lib/features/envs/views/env_list_page.dart:67-68
// The panel backend caps page_size at 100. Requesting a larger value
// silently falls back to 20, which previously made the app stop after 40 rows.

// lib/core/auth/auth_provider.dart:204
// NAS / Nginx Proxy Manager 反代旧面板时，登录接口可能因为 CORS 来源端口不一致返回 403。

// lib/features/tasks/providers/task_provider.dart:168-169
// 后端当前没有独立的任务排序接口，但任务更新接口允许写入 sort_order。
```

> 少量注释是英文（`env_list_page.dart:67`），绝大多数是中文。新注释写中文。

---

## 代码审查清单

改动提交前逐条自检：

- [ ] `flutter analyze` ≤ 7 个 info，且没有新增类型
- [ ] `flutter test` 全绿
- [ ] 新增/修改的请求路径在 `ApiEndpoints` 里
- [ ] 响应解包走 `api_utils.dart` 而不是手写 `['data']`
- [ ] 「读取-修改-回写」的地方，未知字段被保留了
- [ ] `await` 之后没有裸用 `context`
- [ ] 请求失败时用户看得见原因，不是「暂无数据」也不是假的「保存成功」
- [ ] 没有引入新的圆角取值 / 裸颜色 / 影子模型
- [ ] 如果动了 `dio_client.dart` 的 `validateStatus`，**所有**受影响调用点都逐个确认过

---

## 构建与工具链注意

- Flutter SDK 装在 `D:\GitHub\Dumb Panel\flutter_windows_3.41.9-stable\`，
  **路径含空格会让 `flutter test` 在 native assets 构建阶段失败**
  （hook runner 未给 dart 可执行文件加引号）。
  当前用目录联接 `D:\flutter-nospace` 绕过。

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
- `pubspec.yaml` 的 `version:` 同时是 APP 版本号与 build number（当前 `1.3.0+20`），
  发版时 `docs/release-notes/` 下要有对应文件。
