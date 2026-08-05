# 客户端开发约定（Flutter）

> 本目录记录 **呆呆面板 Flutter 客户端（`daidai_app`）当前真实的**代码约定。
> 每一条都来自仓库现有代码并附 `文件:行号`，**不是通用最佳实践**。
> 与现状不符的地方会明确标注「现状 / 反模式 / 第 0 期正在收敛」。

---

## 这是什么仓库

| 项 | 值 | 依据 |
|---|---|---|
| 类型 | 纯 Flutter 客户端，**无后端** | `pubspec.yaml:1-7` |
| 包名 | `daidai_app` | `pubspec.yaml:1` |
| Dart SDK | `^3.11.3` | `pubspec.yaml:7` |
| 状态管理 | `flutter_riverpod ^2.6.1`（仅 `StateNotifierProvider` + `Provider`） | `pubspec.yaml:16` |
| 网络 | `dio ^5.7.0`（REST）+ `http ^1.2.2`（仅 SSE） | `pubspec.yaml:19-20`、`lib/core/network/sse_client.dart:3` |
| 路由 | `go_router ^14.8.1` | `pubspec.yaml:23` |
| 代码生成 | **无**。全库 0 个 `.g.dart`，`pubspec.yaml` 无 `build_runner` / `freezed` / `json_serializable` | `pubspec.yaml:43-47` |
| 规模 | `lib/` 59 个 dart 文件 / 约 30,676 行 | rg 全量统计 |

服务端（Go 面板）在**另一个仓库**，本仓库只消费它的 HTTP API。
本目录的 `../backend/` 是 `trellis init` 留下的 Go/ORM 模板，与本仓库无关，见 `../backend/index.md`。

---

## 文件索引

| 文档 | 覆盖内容 | 状态 |
|---|---|---|
| [directory-structure.md](./directory-structure.md) | `lib/core` / `lib/features` / `lib/shared` 三层职责、feature 内部结构、命名 | 已按代码填写 |
| [component-guidelines.md](./component-guidelines.md) | Widget 构建、私有子组件、主题与样式现状（含反模式统计） | 已按代码填写 |
| [hook-guidelines.md](./hook-guidelines.md) | **已改写为「Riverpod Provider 与数据获取约定」**（本仓库是 Flutter，无 React hooks） | 已按代码填写 |
| [state-management.md](./state-management.md) | `StateNotifier` + 手写不可变 State 类、`copyWith`、`_unset` 哨兵、错误态现状 | 已按代码填写 |
| [quality-guidelines.md](./quality-guidelines.md) | lint 基线、7 个既有 info、测试现状、禁止/必须模式、审查清单 | 已按代码填写 |
| [type-safety.md](./type-safety.md) | JSON 解析防御式写法、后端默认值不得写死、运行模式分支 | 已按代码填写 |

> **关于 `hook-guidelines.md` 的命名**：文件名来自 `trellis init` 的 React 模板。
> Flutter 没有 hooks（本仓库也未使用 `flutter_hooks`），因此该文件的**内容**已整体改写为
> riverpod provider 约定。文件名保留是为了不破坏 Trellis 的 spec 注入路径。

---

## 读这些文档前必须知道的三件事

### 1. 主题文件对界面几乎无效（反模式，第 0 期已建杠杆、第 1 期继续收敛）

`lib/core/theme/app_theme.dart` 定义了 `cardTheme` / `inputDecorationTheme` 等，但页面几乎不用：

- 真正使用 Flutter `Card` 的只有 **6 处**（`resource_card.dart:20`、`server_config_page.dart:359`、`backup_page.dart:927/1029/1210/1403`）
- 手写 `BoxDecoration(` **134 处 / 27 文件**
- 手写 `isLight` 明暗分支 **507 行 / 27 文件**
- `BorderRadius.circular(` **149 处 / 27 文件，11 种取值**（4/8/9/10/12/14/16/18/20/24/999）

**后果**：把 `app_theme.dart` 的圆角全改成 0，界面上绝大多数卡片不会有任何变化。

第 0 期 R4 已经补上 `lib/core/theme/design_tokens.dart`（令牌）
与 `lib/shared/widgets/app_*.dart`（基元组件），并做了 5 个页面的示范迁移。
**新代码必须走这一层**，否则第 1 期扁平化的杠杆会被继续稀释。
详见 [component-guidelines.md](./component-guidelines.md#样式现状反模式)。

### 2. `validateStatus: status < 500` 让 4xx 变成「成功」

`lib/core/network/dio_client.dart:16` 与 `:60`：

```dart
validateStatus: (status) => status != null && status < 500,
```

所有 4xx 都不抛异常，直接进入 `then` 分支。连锁后果贯穿整个客户端：

- `lib/core/auth/auth_interceptor.dart:46-114` 的 token 续期整段是**死代码**（`onError` 永不触发）
- `lib/features/system/views/system_settings_page.dart:496-529` 后端返回 400 也弹「配置已保存」
- 各 provider 的 `catch` 兜不到 4xx，列表拿到空数据后显示「暂无数据」

**第 0 期 R1 会收紧这个配置。** 改动后所有 4xx 会变成 `DioException`，
**任何新增/修改调用点都必须自行确认 catch 兜得住**。详见
[hook-guidelines.md](./hook-guidelines.md#网络层现状与陷阱)。

### 3. 测试只覆盖「改错了用户会丢数据」的地方

第 0 期 R5 之前 `test/` 下只有一个用例体是 `// TODO` 的空壳，全绿等于零信息。
现在有 4 个测试文件，只保护三条线：**401 续期链路**、**通知渠道配置不丢未知字段**、
**列表 error 语义**。其余绝大部分代码仍然没有任何覆盖，
改动时不要把「`flutter test` 通过」当成安全。

没有引入任何测试依赖，假 HTTP 是手写的 `HttpClientAdapter`。详见
[quality-guidelines.md](./quality-guidelines.md#测试现状)。

---

## 语言

本目录全部使用**中文**，与仓库 `docs/` 及代码注释一致。
