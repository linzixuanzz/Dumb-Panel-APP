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
| 规模 | `lib/` **89** 个 dart 文件 / 约 **35,978** 行；`test/` **26** 个 `*_test.dart` / **416** 个用例 | 全量统计（2026-09-02 实跑） |

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
| [panel-contract.md](./panel-contract.md) | **APP 与面板的契约**：什么该下发什么不该、形状探测、config 必须字符串、未知值要诚实、冻结快照 | 第 2 期新增 |

> **关于 `hook-guidelines.md` 的命名**：文件名来自 `trellis init` 的 React 模板。
> Flutter 没有 hooks（本仓库也未使用 `flutter_hooks`），因此该文件的**内容**已整体改写为
> riverpod provider 约定。文件名保留是为了不破坏 Trellis 的 spec 注入路径。

---

## 读这些文档前必须知道的三件事

### 1. 样式已经收敛完了，新代码必须走令牌与共享组件

第 0 期建令牌层、第 1 期把它接线到全库。**改造前后的对照**：

| | 改造前 | 现在 |
|---|---|---|
| 圆角取值 | 11 种散装字面量 | **5 档令牌**（`control/sm/md/lg/pill`），活代码零字面量 |
| `BoxDecoration(` | 134 | **76**（剩下的是圆钮、徽章、图标底、单边分隔线等真不该用卡片的） |
| `AppCard` 调用点 | 6 | **46** |
| `boxShadow` | 12 | **0** |
| `LinearGradient` | 2 | **0** |

**新代码必须**：圆角走 `AppRadius`（只有那五个名字，禁止第六档）、卡片用 `AppCard`、
提示条用 `AppNotice`、明暗走 `AppSurfaces`、提示走 `AppSnack`（**失败必须用 `error`**）。

详见 [component-guidelines.md](./component-guidelines.md)。

### 2. `validateStatus` 已收紧到 `< 400`，4xx 会抛 `DioException`

改造前是 `< 500`，导致 401 被当成功响应、token 续期整段是死代码、
后端返回 400 也弹「配置已保存」。第 0 期已修。

**新增调用点必须自行确认 catch 兜得住 4xx**。唯一的例外是
`/auth/captcha-config` 保留请求级 `< 500`（老面板没这个接口，404 = 没配验证码）。

### 3. 测试有 416 个用例，但覆盖面是**有选择的**

不追覆盖率，只保护「改错了用户会丢数据 / 丢会话 / 看到错误信息」的地方：

401 续期链路、通知渠道配置合并（未知字段不丢）、列表 error 语义、
系统配置 schema 的读写往返、通知渠道 schema 解析与降级、
枚举换算的诚实性、cron 模板解析、订阅鉴权请求体、
任务标签往返（订阅标签不丢）、任务视图规则的解析与回写（排序规则不丢）、
日志底色的主题回落、命令→脚本路径解析、编辑器搜索的命中与回绕。

**绝大部分 UI 代码仍然零覆盖** —— 圆角、间距、配色、布局对 `flutter test` 全部不可见。
不要把「测试通过」当成界面没问题。

没有引入任何测试依赖，假 HTTP 是手写的 `HttpClientAdapter`。详见
[quality-guidelines.md](./quality-guidelines.md#测试现状)。

### ★ 第 4 件：不要把面板的知识抄进 APP

第 2 期的主题。判断标准：**面板加一个值时 APP 需不需要发新版？**
需要就说明这份知识不该在 APP 里。

已经改成面板下发的：系统配置（47 项，schema 驱动）、通知渠道字段（22 渠道 90 槽）、
cron 模板（21 条）。仍然硬编码但**有意保留**的东西，以及哪些**不该**下发，
见 [panel-contract.md](./panel-contract.md)。

---

## 语言

本目录全部使用**中文**，与仓库 `docs/` 及代码注释一致。
