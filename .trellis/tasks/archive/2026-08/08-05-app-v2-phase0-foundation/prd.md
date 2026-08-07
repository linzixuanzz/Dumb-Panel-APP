# APP v2 第 0 期：地基修复与共享组件层

## 背景

用户要对 APP 做大改，三条诉求：

1. **UI**：减少花里胡哨，一切以简洁干净为主
2. **功能**：把面板功能全部对齐；**不要每次更新面板 APP 就要改来改去，要通用化适配**
3. **体验**：考虑用户觉得哪些地方更便利

已完成一轮并行深度调研（4 个方向 + 对抗性复核，共 53 条问题）。结论是**不能直接从 UI 动手**——
现在改 UI 是在没有杠杆的地基上逐页面刷 140 处圆角，而且有两个真 bug 正在损害用户数据与体验。

本任务是第 0 期：**把地基补上**，为后续三期提供杠杆与安全网。

## 确认事实（★ 为我在代码中亲自核实，非调研转述）

### ★ F1：token 续期整段是死代码

`lib/core/network/dio_client.dart:16` 与 `:60`：

```dart
validateStatus: (status) => status != null && status < 500,
```

401 因此被 dio 判定为**成功响应**，`onError` 永不触发 —— `lib/core/auth/auth_interceptor.dart:46-114`
那 70 行续期 + 排队重发逻辑**一次都没有执行过**。

全仓库无兜底：`lib/core/network/sse_client.dart:61` 确实处理了 401，但 SSE 走独立 HTTP 客户端、
不经过 dio；`lib/core/auth/auth_provider.dart:108` 的 catch 也够不着，因为 401 根本不抛异常。

**用户实际遇到的**：access token 过期后，所有请求返回 401 却被当成功，body 解析出空数据，
页面显示「暂无数据」。用户看到的是**莫名其妙的空白，而不是「请重新登录」**，只能自己退出重登。

### ★ F2：编辑通知渠道会丢配置

`lib/features/notifications/views/notification_list_page.dart:735-757`：编辑时 `configMap`
从 `{}` 开始，只填入 `_channelFieldMap`（本地写死的 229 行常量表，`:361`）里有的字段，
然后 `jsonEncode(configMap)` **整串覆盖**回服务端。

面板支持而 APP 字段表里没有的键（telegram proxy、wecom 图文卡片参数等）**保存即丢失**。

> 对照：OpenAPI scope 那边用 `_parseScopes(scopes).toSet()`
> （`lib/features/openapi/views/open_api_page.dart:671`）完整保留了未知 scope，
> 保存时原样带回。**同一个仓库里两种做法，通知渠道这边是缺的那个。**

### ★ F3：错误态缺失（比初稿描述的更深，已核实修正）

三个主列表（任务 / 日志 / 环境变量）在断网或面板不可达时显示「暂无任务 / 暂无日志 / 暂无环境变量」
的空态，而不是错误提示，也没有重试按钮。

**初稿写「`error` 字段被赋值但 UI 从不读取」是错的**。实际核实（PowerShell 抽查）：

- `TaskListState` 有 `error` 字段（`lib/features/tasks/providers/task_provider.dart:43` / `:59` / `:83`）
- `EnvListState`（`lib/features/envs/views/env_list_page.dart`）与
  `LogListState`（`lib/features/logs/views/log_list_page.dart`）**连 error 字段都没有**，
  catch 里只写 `copyWith(loading: false)`

所以 R3 不是「把已有的 error 渲染出来」，而是**先给两个 State 加字段 → 改 Notifier → 再改 UI**。

### ★ F3b：`copyWith` 的 error 语义在仓库内不一致（改动时的陷阱）

`task_provider.dart:43` 是 `error: error,`，**刻意不写 `??`** —— 任何不显式传 error 的
`copyWith` 调用都会清空错误。而 `AuthState` 用 `_unset` 哨兵保留旧值（`auth_provider.dart:34`），
**两种相反语义并存**。

做 R3 时若有人「顺手修正」成 `error ?? this.error`，会静默破坏现有的错误清除逻辑
（例如 `:59` 的 `error: null` 将失效）。

### F4：设置页保存失败仍提示成功

面板返回 400 时 APP 照样弹「配置已保存」，用户看不到失败。

### F5：没有共享组件层，主题文件对界面几乎无效

- `lib/shared/widgets/` 只有 2 个文件：`main_scaffold.dart`（185 行，底部导航 **+ 5 秒内双击返回退出**
  的 PopScope 逻辑）和一个 cron 列表
- 真正走 Flutter `Card` 的只有 **6 处**；手写 `BoxDecoration` **132 处**、手写 `isLight` 分支 **514 处**
- **把 `app_theme.dart` 的圆角全改成 0，界面上 96% 的卡片不会有任何变化**
- `BorderRadius.circular(` 全库 **149 处 / 27 文件**（主题内 9 处，页面内 140 处），
  **11 种取值**（4/8/9/10/12/14/16/18/20/24/999），同层级对象都不统一：
  列表项卡片在日志页是 18、任务页是 14、变量页是 12、设置页是 12
- `BoxShadow` **12 处 / 11 文件**（复核纠正：调研原报 24 处是夸大）

**结论：第 1 期 UI 改造的前提是先有共享组件层，否则就是逐页面改 140 处。**

### F6：`.trellis/spec/` 是未填写的模板

`.trellis/spec/backend/` 写着「ORM patterns, queries, migrations」，
`.trellis/spec/frontend/state-management.md` 通篇 `(To be filled by the team)` ——
一个 Flutter APP 没有 Go 后端。

这要紧是因为 **sub-agent 的 hook 会把 spec 注入上下文**。原 `00-bootstrap-guidelines` 任务
（已归档，副本存于本任务 `research/legacy-bootstrap-spec-checklist.md`）自己就写着：

> Empty spec = sub-agents write generic code. Real spec = sub-agents match the team's actual patterns.

三个复选框一个都没勾。

### ★ F7：测试等于零，不是「1 个 smoke test」

`test/widget_test.dart` 只有一个 `testWidgets('App smoke test')`，而**用例体只有一句 `// TODO`**，
什么都没有验证。之前记录的「基线：1 个用例通过」是**假绿**——它必然通过，因为它什么都不做。

面板后端有回归测试 + 突变验证兜底，APP 这边**一张网都没有**。

### ★ F7b：补测试有前置障碍

除 `AuthNotifier` 外，**所有 Notifier 都直接使用 `DioClient.instance.dio` 单例**，不做依赖注入。
要给 R1 / R2 / R3 写回归测试，必须先给相关 Notifier 加可选 `Dio` 构造参数，否则无法注入假 dio。
这是 R5 的隐藏前置工作。

### ★ F9：R1 修不了 SSE 的 401

`lib/core/network/sse_client.dart` 走 `package:http`，**完全不经过 dio 与 `AuthInterceptor`**。
收紧 `validateStatus` 对它毫无作用——它的 401 处理是直接回调
`onError('认证失败，请重新登录')`（`:61-64`），**不会续期**。

受影响链路：任务实时日志、依赖安装日志、订阅拉取流。R1 需单独考虑这条路径。

### F8：历史适配记录证实了「面板一更新 APP 就要改」

已归档任务留下的 `research/legacy-compatibility-map-v2218-2219.md` 记录了 v2.2.18 / v2.2.19
两次面板更新各自要求 APP 改哪些地方。**这正是用户抱怨的模式**，也说明通用化适配的必要性。
其中若干条（任务表单默认 Python 版本、系统更新语义提示）**需要核实是否仍未完成**。

## 用户已定决策

- **主色统一为面板的 `#409eff`**（APP 现为 Emerald `#10B981`）
- **面板侧可以改动**（为第 2 期通用化铺路）

## 目标

1. 修掉正在损害用户数据与体验的缺陷
2. 建立共享组件层，让第 1 期 UI 改造有杠杆
3. 补上最小安全网，让后续三期不是在裸奔
4. 把 spec 填成真实的 Flutter 约定，让 sub-agent 拿到对的地图

## 需求

### R1：恢复 token 自动续期（**风险最高，单独成步**）

- 收紧 `validateStatus`，让 4xx 真正进入 `onError`，激活既有的续期链路
- **必须逐个排查所有调用点**：现在全 APP 的 4xx 都走「成功」路径，收紧后会变成异常，
  各处的 catch 是否兜得住必须逐一确认，不能想当然
- 续期失败时给出明确的「登录已失效」提示并跳转登录页，不能再显示空数据
- `rawDio`（`dio_client.dart:55-63`）用于刷新请求本身，其 `validateStatus` 需单独考量，
  避免刷新失败时产生递归

### R2：编辑通知渠道不得丢失未知字段

- 编辑时以服务端返回的原始 config 为基底，只覆盖表单里出现的键
- 参照 `open_api_page.dart:671` 已有的做法保持仓库内一致
- 用户在 Web 配的 telegram proxy / wecom 图文卡片等参数，经 APP 编辑保存后必须仍在

### R3：错误态可见且可操作

- 三个主列表在请求失败时显示错误原因 + 重试按钮，而不是「暂无数据」
- 区分「真的没有数据」与「拿不到数据」
- 设置页保存失败必须提示失败原因，不得再谎报成功

### R4：共享组件层

- 抽出被重复实现的基元：卡片容器、列表项、区块标题、空状态、错误态、统计块、chip、圆形操作按钮
- **设计令牌集中化**：圆角、间距、边框、颜色统一到一处，页面不再手写数值
- 主色切换到 `#409eff`
- **不要求本期把所有页面都迁过去**，但组件层必须能覆盖 F5 列出的重复形态，
  并至少在 1~2 个页面完成示范迁移，证明它真的可用
- `main_scaffold.dart` 改造时**不得丢掉双击返回退出**的行为

### R5：最小安全网

- 至少覆盖：401 续期链路、通知渠道配置保留、错误态渲染
- 目标不是高覆盖率，而是让 R1/R2 这类「改错了用户会丢数据」的地方有回归保护

### R6：填写 `.trellis/spec/`

- `frontend/` 按真实的 Flutter + riverpod + go_router + dio 约定填写
- `backend/` 那套 Go/ORM 模板与本仓库无关，应删除或改写为「本仓库无后端」
- 内容必须来自**代码里的真实模式**，不是通用最佳实践

## 验收标准

- **A1**：token 过期后 APP 能自动续期并继续工作；续期失败时明确提示并跳登录页，不再显示空数据
- **A2**：收紧 `validateStatus` 后，全 APP 无新增未捕获异常（逐调用点确认，不是抽查）
- **A3**：用 Web 给某渠道配一个 APP 字段表里没有的键，经 APP 编辑保存后该键仍在
- **A4**：断网状态下三个主列表显示错误 + 重试，而不是「暂无数据」
- **A5**：设置页保存返回 400 时提示失败
- **A6**：共享组件层存在，且至少 1~2 个页面已迁移并在 `flutter analyze` 下无新增告警
- **A7**：主色为 `#409eff`
- **A8**：`flutter analyze` 不超过基线的 7 个 info；`flutter test` 全绿且新增用例覆盖 R1/R2/R3
- **A9**：`.trellis/spec/` 内容与仓库真实模式一致，不再有 `(To be filled by the team)`

## 范围外（后续期）

- **第 1 期**：全面 UI 扁平化（140 处圆角、去阴影、去渐变、信息密度、去环形仪表盘）
- **第 2 期**：通用化适配（面板加 `Sensitive`/`Internal` 元数据 → 设置页由注册表驱动 →
  通知渠道字段服务端下发 → 版本协商与降级）
- **第 3 期**：功能补齐（原始日志下载、任务视图、SSH 密钥、环境变量导入导出等）
  与体验改进（自动刷新、失败直达、日志搜索与虚拟化）

## 基线（已实测）

| 检查 | 结果 |
| --- | --- |
| `flutter analyze` | 7 个 info（4 处 `use_build_context_synchronously`、2 处 `library_private_types_in_public_api`、1 处同类），全部既有 |
| `flutter test` | 1 个用例通过 |
| 工作树 | 干净 |

> **工具链注意**：Flutter SDK 装在 `D:\GitHub\Dumb Panel\flutter_windows_3.41.9-stable\`，
> 路径含空格会导致 `flutter test` 在 native assets 构建阶段失败
> （hook runner 未给 dart 可执行文件加引号）。已实测：经无空格路径调用即正常。
> 当前用目录联接 `D:\flutter-nospace` 绕过，建议后续把 SDK 移到无空格路径。

## 开放问题

无阻塞项。共享组件层的具体拆分粒度由 design.md 定。
