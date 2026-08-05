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
| `use_build_context_synchronously` | 4 | `await` 之后使用 `BuildContext` 且未先判 `mounted` |
| `library_private_types_in_public_api` | 2 | 公开类 `UserListState` 暴露私有类型 `_User`：`user_list_page.dart:68`（`final List<_User> items`）与 `:73`（`copyWith({List<_User>? items})`） |
| 同类 info | 1 | |

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
└── widget_test.dart      (7 行)
```

```dart
// test/widget_test.dart 全文
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    // TODO: Add widget tests
  });
}
```

**这个用例体是空的。`flutter test` 全绿不代表任何代码被验证过。**

`dev_dependencies` 只有 `flutter_test` + `flutter_lints` + `flutter_launcher_icons`
（`pubspec.yaml:43-47`），没有 `mocktail` / `mockito` / `http_mock_adapter` / `integration_test`。

### 新增功能至少要覆盖什么

按第 0 期 R5 的定位（不追覆盖率，只保护「改错了用户会丢数据」的地方）：

| 类别 | 最低要求 |
|---|---|
| 触碰认证/token 链路 | 必须有测试覆盖 401 → 续期 → 重发 的路径 |
| 触碰「读取-修改-回写」的表单 | 必须有测试证明**未知字段不丢失**（见下方通知渠道案例） |
| 触碰列表 provider | 必须有测试证明请求失败时 `error` 被设置且能被 UI 消费 |
| 纯 UI 调整 | 不强制 |
| 新增 `shared/utils/` 函数 | 建议补纯函数单测（这类最容易测，目前一个都没有） |

**测试的现实障碍**：除 `auth` 外的 Notifier 都直接使用 `DioClient.instance.dio` 单例
（`task_provider.dart:61`、`env_list_page.dart:66` …），无法注入假 dio。
若要给某个 provider 补测试，需要先给它的 Notifier 加可选的 `Dio` 构造参数。

---

## 禁止的写法

| 禁止 | 原因 | 反例 |
|---|---|---|
| 请求 URL 直接拼字符串 | 绕过 `ApiEndpoints`，改路径时漏改 | `system_settings_page.dart:265/349/419` |
| 在页面里自己 `response.data['data']` | 后端有 3 种包裹形态 | 应用 `extractData` / `extractPaginated`（`api_utils.dart`） |
| 编辑表单时用空 map 重建再整串覆盖 | **用户在 Web 配的字段会被静默清空** | `notification_list_page.dart:735-757` |
| 后端已暴露的默认值写死在客户端 | 面板改配置后 APP 不跟随 | 参考已修正的 `task_form_page.dart:223-266` |
| 裸 `Color(0xFF...)` | 绕过 `AppColors` / `ColorScheme`，主色切换时漏改 | |
| 新增第 12 种 `BorderRadius.circular` 取值 | 现已 11 种，正在收敛 | |
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
- `pubspec.yaml` 的 `version:` 同时是 APP 版本号与 build number（当前 `1.2.6+19`），
  发版时 `docs/release-notes/` 下要有对应文件。
