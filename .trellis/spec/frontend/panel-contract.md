# APP 与面板的契约

> 第 2 期「通用化适配」形成的约定。核心目标是用户的一句话：
> **「不要每次更新面板，APP 端也要改来改去」**。

---

## 一条总原则

**面板持有唯一真源，APP 消费它下发的 schema。**

APP 里任何「复制了面板定义」的东西 —— 枚举表、字段表、默认值、校验规则、
文案映射 —— 都是一个漂移源。判断标准很简单：

> 面板加一个值 / 加一个字段 / 改一个默认值时，APP 需不需要发新版？
> 需要，就说明这份知识不该在 APP 里。

### 但不是所有东西都该下发

| 不要下发 | 原因 |
|---|---|
| 导航结构、页面存在与否 | 服务端驱动 UI 会让 APP 变成渲染器，出问题时两边都改不了，还让应用商店审核复杂化。**面板加一个功能模块，APP 就该发一次版 —— 这是正常的** |
| 错误文案表 | 正解是让面板在错误响应里加稳定的 `code`。下发文案表只是把耦合从「文案内容」换成「文案 key」，一样脆 |
| Cron 语法规则 | 面板有 `POST /tasks/cron/parse`，**调它**。任何「服务端能算的东西」都不要下发算法让 APP 本地算 —— 尤其是下次执行时间，必须按**面板时区**算 |
| 镜像源预设列表 | 面板端自己也没有这份真源。在面板里新写一张预设表 = 把 APP 的硬编码搬到面板，总数不变还多一个接口 |
| 图标 | 可以下发语义名（`"telegram"`），但 `名字 → IconData` 的映射必须编译进 APP（Flutter 图标是编译期常量）。所以收益≈0，顺手带上即可，别算进收益 |
| 纯客户端的东西 | `app_lock` / `secure_storage` / 主题 / 本地缓存 |

---

## 版本协商：形状探测，永远不要看版本号

### ⚠️ 面板的版本号不可信

`handler.Version` 由 `release.yml` 用 ldflags 注入，源码默认值是 `"3.0.0"` ——
**任何本地 `go build` / fork 构建都自称 3.0.0**。

而且 `/api` 与 `/api/v1` 是**双注册全等**的（`router.go` 里 17 组 handler 各注册两遍），
路径前缀既不是新旧标志，也不能用于协商。

### 正确做法：判断字段在不在

```dart
// 新面板下发了 fields → 用 schema
if (schema.fields.isNotEmpty) return schema.fields;
// 老面板只回 {type, name} → 回落冻结快照
return kFrozenChannelFieldsV300[type] ?? const [];
```

老面板的响应反序列化出来就是一个空 `fields` 的对象 —— **形状本身就是探测结果**，
不需要任何额外请求，也不需要能力清单端点。

> 仓库里已有先例支持这个判断：面板的
> `TestMagiskCustomizeScriptUsesCapabilityProbeInsteadOfVersionGate`
> 已经确立过「能力探测优于版本闸门」，而形状探测是最轻量的能力探测。

### ⚠️ `[]` 与「缺失」要同等对待

Go 的 `json:"fields"` 不带 `omitempty` 时，空切片发出来是 `[]` 不是不发。
只判 `!= null` 会漏。

### 不要建 capabilities 端点

它本身就是一份手写常量数组，会成为**新的漂移源**。形状探测零维护成本。

---

## config / 配置值：**必须全是字符串**

面板的通知渠道 config 是 `map[string]string`（`notifier.go` 的
`json.Unmarshal([]byte(ch.Config), &cfg)`）。

写进去一个 JSON 布尔或数字，**整份 config 解析失败，该渠道所有通知（含测试按钮）
全部停止工作**，错误是 `json: cannot unmarshal bool into Go value of type string`。

系统配置同理：`newBoolConfig` 走 `strconv.FormatBool`，值是 `"true"` / `"false"` 字符串。

### 结构上保证，不靠自觉

```dart
// 类型链全程 String，没有 dynamic
Map<String, String> buildNotifyFieldValues(...)
final String? default_ = json['default']?.toString();   // 面板误发 bool 也变 "true"
```

### 测试必须在 `jsonEncode` 层断言

Dart 侧是 `String` 不代表编码后是字符串。断言要写成：

```dart
expect(jsonEncode(config), contains('"smtp_ssl":"false"'));
expect(jsonEncode(config), isNot(contains(':true')));   // 裸 JSON 布尔
```

> 服务端现在会把布尔/数字/null **转成字符串**（可逆），对象/数组返回 400（不可逆）。
> 所以历史坏数据「一编辑就自愈」。但 APP 侧仍然不许产生非字符串 ——
> 依赖服务端兜底等于把自愈当常态。

---

## 「未知值」必须诚实

**兜底分支不许返回某个具体的已知值。** 这不是防御性编程，是防止显示错误信息。

| 反例（本期修掉的） | 后果 |
|---|---|
| `default → '已安装'` | 面板加一种状态，用户看到「已安装」却怎么都用不了 |
| `default → 'NodeJS'` | 面板加 Go/Rust 依赖，用户按 npm 思路排查 |
| `default → '常规定时'` | 用户去改一个根本不生效的 cron |
| 状态色的最后一个分支是绿色 | 只改文案不改色，未知状态仍是个绿色成功徽章 |

正确写法：显式列出所有已知值，兜底**回吐原始值**或显示「未知」。

### 例外：fail-safe 降级不算

`hierarchy[role] ?? 0`（不认识的角色按**最低**权限）是安全降级，改了反而放权。
判断标准是「兜底方向是更安全还是更危险」。

### ⚠️ 两套 status 枚举，`2` 的含义正好相反

```
task_logs.status      0 成功 / 1 失败 / 2 运行中 / 3 已终止
tasks.last_run_status 0 成功 / 1 失败 / 2 已终止
```

**不要共用一套换算。** 有测试专门锁这一条。

---

## ⚠️ 契约测试要钉 **JSON 键名**，不是 Go 结构体字段

这是交叉审查抓到的一整类缺口：面板的测试断言的是 Go struct 的字段值，
**改一个 json tag，面板全部测试仍然绿**，而 APP 静默退化成
「标题变成 key、hint 消失、下拉变文本框」—— 没有任何地方报错。

写契约测试时：**序列化一次，断言 JSON 里的键名**。
断言的值用 Go 侧的变量而不是写死的中文，这样改文案不误报、只有改键名才红。

## ⚠️ 同一个 key 声明两次时，客户端的表单状态是**按 key 存**的

面板允许同一个 key 在不同 `show_when` 分支下声明多次
（wecom 的 `content_template` 在 text 与 markdown 分支文案不同）。
服务端的守卫只保证两条 `show_when` **互斥**。

但客户端是这样建种子值的：

```dart
return <String, String>{
  for (final field in fields)
    field.key: existingNotifyFieldValue(field.key, config) ?? field.defaultValue,
};
```

Dart map 推导式里**重复 key 后写覆盖先写** —— 种子值恒等于**最后一条**声明的
`default`，与此刻显示的是哪个分支无关。Web 的 `configData[key]` 同理。

现在那两条的 `default` 都是空串所以看不出来。面板侧已加断言
（重复 key 的 `Default` / `Required` / `Widget` 必须一致），加了就红。

---

## 冻结快照：不是「保留的硬编码」

老面板兼容确实需要在 APP 里留一份基线数据，但它的语义必须是：

> **v3.0.0 基线快照，此后永不更新。** 新渠道 / 新字段一律靠面板下发。

**光写注释不够** —— 要加可执行的守卫：

```dart
group('v3.0.0 冻结快照不许再长', () {
  test('渠道数与字段槽数被钉死', () {
    expect(kFrozenChannelFieldsV300.length, 21);
    expect(totalSlots, 45);
  });
});
```

往里加任何东西，测试立刻红。注释可以被无视，测试不行。

---

## 已验证的兼容底线（不要再重新担心一遍）

schema 驱动依赖服务端下发某些键。这些键**是哪个版本引入的**，用
`git log -S '"键名"' -- <file>` 查过：

| 键 | 引入版本 | 结论 |
|---|---|---|
| `/api/configs` 的 `registered` | **v1.8.0**（2026-03-21） | 安全。APP 关心的最老面板是 **v2.2.2**（`dep_list_page` 那处降级挡的是 `/deps/python-runtimes` 在 v2.2.2 无、v2.2.20 才有），`registered` 比它早一个大版本 |
| `/api/auth/preferences` 路由 | **v3.2.4**（`09d32c1`） | 更老的面板 404（纯文本或 `{"error":"route not found"}`），读偏好当「面板不支持」 |
| 上面那条响应里的 `list` 组 | **v3.3.1**（`05b5c4e`） | 形状探测的依据：GET 响应里 `list` 不是对象 → 不给开关、**绝不 PUT**（见下方坑 1） |
| `list.log_open_at_bottom`（#147） | **v3.3.3** | 稀疏 JSON bool，没设过时整键省略。v3.3.1 / v3.3.2 在 GET 上和「没设过」分不出，只能看 PUT 回显（见下方坑 2）。实现在 `features/logs/utils/log_open_preference.dart` |

> **为什么这条值得写下来**：`parseSystemConfigGroups` 会跳过 `registered != true` 的项，
> 一条都收不到就显示「面板没有返回任何可编辑的系统配置」。而改造前那 10 个硬编码键
> **根本不看 `registered`**。如果这个前提不成立，用户会从「能改 10 项」变成
> 「一项都改不了 + 一句看不懂的错」—— **比改造前更糟**。
>
> 引入新的「依赖某个键存在」的降级判据时，照这个格式查一次并记在这里。

### `/auth/preferences` 的两个坑（写账户偏好前必读）

1. **v3.2.4 ~ v3.3.0 的 PUT 不认组**：请求体是 `struct { Editor editorPreferencesPatch }`（值类型），
   收到任何 PUT（哪怕只有 `{"list":{…}}`）都会把整套 editor 默认值写进库、把 `stored` 翻成 true，
   网页端用户存在浏览器本地的编辑器偏好会在下次打开编辑器时被静默冲掉。
   所以 GET 里没看到 `list` 对象，**一个 PUT 都不能发**。
2. **v3.3.1 / v3.3.2 对 list 里白名单外的键回 200 但不存**（整组当空补丁，原样回当前值）。
   写新键时要比对 PUT 回显里这个键是否等于刚写的值，不等就是面板太老，
   界面要弹回原状态并提示升级，不能当成功。

PUT 永远只带要改的那一个键：面板按组、按键合并，不带 editor，也不带 list 里的其它键。

---

## 服务端 handler 是**逐字段手写拼装**，不是 marshal struct

`buildConfigResponseItem` 逐个 `item["x"] = ...`。所以给 Go struct 加字段
**不会**让接口多出这些键 —— 客户端会永远走降级路径**且没有任何报错**。

改服务端定义时必须同时改 handler。

同理 `Order int` 这类字段**绝不能加 `omitempty`** —— 第一项的 order 是 0，
会被吞成「没有 order」。

---

## 分页：`page_size` 上限是 100

面板统一是 `if pageSize < 1 || pageSize > 100 { pageSize = 20 }` ——
**超了不是截断到 100，是静默回落到 20**。

APP 曾经三处写 200，其中订阅列表导致**第 21 条起看不见**。

例外：`/api/deps` 的 `List` 压根不读 `page_size`，全量返回。

---

## 权限：接口挂了什么中间件，UI 要能区分

- `/api/configs` 挂 `RequireAdmin` —— 非管理员打开设置页会 403
- `/api/ssh-keys` 全部 5 条路由挂 `RequireAdmin` —— operator/viewer **永远**看不到密钥列表

**403 与「空列表」必须区分提示。** 不做特判的话，非管理员会看到一个空下拉，
以为面板里没配过东西。

---

## 「读取-修改-回写」的表单

面板的 `BatchSet` 是逐键 `SetConfig`、**中途失败直接 400 而前面的键已经落库**。

所以：**只回写改动过的键，不要全量提交**。全量回写会把「一项填错」
变成「一半保存了一半没保存」。

配合 spec 的硬性要求「必须有测试证明未知字段不丢失」，本期形成的测试形状是：

- 打开页面 → 一个字不改 → 保存 → payload 为空
- 运行时状态（`registered: false`）永远不进 payload
- 面板将来新增、这一版 APP 不认识的键不会被清空
- 只读键即使被改也不回写
- **被条件隐藏的字段不算「被清空」** —— 切换 `msg_type` 不该删掉已存的 `news_articles`

---

## 实时日志：SSE 与 live-logs 的现状形状

> 面板 v3.3.4（`580f6d8`）读码 + 真实实例抓包（APP #15 调研，2026-10-04）；末尾「面板关停时的结束事件」
> 按面板 v3.3.5 开发中代码读码（2026-10-05，未发版；依赖 / 订阅流的关停结束值已按回归复核改为 `reconnect`）。
> APP 侧怎么扛见 [hook-guidelines.md](./hook-guidelines.md)「实时日志页」与
> [component-guidelines.md](./component-guidelines.md)「日志正文」。

### `GET /api/v1/logs/:id/stream`（`server/handler/log.go` 的 `LogHandler.Stream`，路径里的 id 是**任务** id）

| 阶段 | 线格式 |
|---|---|
| 连上 | 先一条注释 `: open`（为了立刻推出响应头） |
| 历史 | TinyLog 还在：`ReadAll()` 的**整段历史作为一个帧**推下来（`writeSSEData`：帧内每个 `\n` 一条 `data:` 行，只有「后面还有内容的裸 `\r`」才另起一帧）。5 万行 = 一个帧、约 5 万条 data 行、3.77MB；SSE 不压缩 |
| 实时 | 历史写完才 `Subscribe()`；之后每块输出一帧（面板按 `\n` / 裸 `\r` 切块，基本就是一行）：`data: <行>\ndata: \n\n`，行尾换行切出一条**空 data 行**；进度条每次 `\r` 刷新也是单独一帧 |
| 心跳 | 每 30 秒一条注释 `: keepalive`（有没有输出都发） |
| 结束 | 订阅关闭 → `event: done` / `data: finished`；登录会话被撤销 → `data: reconnect`；面板正常关停（v3.3.5 起）也是 `data: reconnect`，下一行「TinyLog 不在」的两个轮询分支同样会发，见下文「面板关停时的结束事件」 |
| TinyLog 不在 | 任务不在运行：只有排队中才每 150ms 探一次、最多 1.5 秒（其它状态不等），等到了就推历史；最后的 `done` 是 `reconnect`（期间开始跑了）/ `finished`（没等）/ `finished-late`（等过，v3.2.0 起）。任务在运行：每 0.5 秒探一次，等到了就推历史再发 `done: reconnect`（重连后历史会再重放一遍）；60 秒都等不到 → `finished` |

- 没有 `id:` 帧、不读 `Last-Event-ID`：任何重连都从第一行重放整段历史（见 hook-guidelines.md「SSE」一节）。
- 实时行会丢：每个订阅通道缓冲 100，满了直接丢（`service/tiny_log.go` 的 `broadcast`）；写历史期间的
  新输出既不在已发的历史里，也还没进订阅。网页在流结束后回拉 latest-log 补齐，**APP 目前不补**。

### `GET /api/tasks/:id/live-logs`（`server/handler/task_logs.go` 的 `LiveLogs`）

`{logs: [String], done: status != 运行中, status: num}`。`logs` 来自 `TinyLog.ReadLastLines(200)`，
但它**只读文件最后 4096 字节**再按 `\n` 切（参数 200 只在这 4KB 里超过 200 行时才起作用）：

- 首行常常是半截，切在多字节字符中间时 JSON 里就是 `�`；日志以换行结尾时最后一项是空串；
- 任务一结束 TinyLog 就被移除（`service/task_executor.go`），之后 `logs` 永远是 `[]`。

### `GET /api/tasks/:id/latest-log`

最近一次运行的完整日志在 `content` 里；从没跑过、或被保留策略清理掉时回 404。

### APP 据此必须遵守

1. live-logs 快照**不是** SSE 重放的前缀：只能展示，不能交给 `SseReplayBuffer` 去重。
2. `SseClient` 每条 `data:` 行回调一次（不按 SSE 规范把同一帧拼起来），历史那一帧会变成上万次
   「一次一行」的追加：缓冲区与视图必须扛得住逐行追加。依赖、订阅两页也依赖「一事件一行」，
   要改成按帧派发得四个页面一起改。
3. 空 data 行一律丢弃（两个日志页都这么做）——脚本真实输出的空行也跟着丢了，已知未修。
4. `finished-late` 对 APP 与 `finished` 同义。目前只有 `TaskLiveLogPage` 认它；`LogStreamPage` 的 done
   分支只认 `finished`，遇到它会把原值显示在状态 Chip 里（罕见，已知未修）。

### 面板关停时的结束事件（面板 v3.3.5 起）

**结论**：面板**正常关停**时，三条流（实时日志、依赖安装、订阅拉取）都以 `event: done` / `data: reconnect` 收尾；
没先发 TERM 的强杀仍是连接异常断开、没有结束帧。APP 四个 SSE 页面都不把 `reconnect` 当结束，`SseClient` 1 秒后
重连一次：面板没起来就走 `onError`，依赖 / 订阅页显示红色「安装日志连接已断开 / 拉取日志连接已断开」，与配面板
v3.3.4 被强杀时同一终态（只是正文末尾多一行字面量 `reconnect`）；两个任务日志页里只有 `TaskLiveLogPage` 能在
面板回来后自己恢复。
依赖 / 订阅页把 `reconnect` 以外的 `done` 一律显示成绿色「…完成」，**是 APP 既有问题，与关停无关、待 APP 修**：
面板在非关停场景发 `timeout`（依赖流的硬上限、订阅流 5 分钟无输出）时，这两页照样显示「安装完成 / 拉取完成」。

> 面板 v3.3.5 开发中（第二波）曾让依赖 / 订阅流关停时发 `timeout`，会把这两页的关停表现从红色「连接已断开」
> 变成绿色「…完成」（假成功）；本节复核发现后，面板改为三条流都发 `reconnect`（`deps.go` / `subscription.go`
> 的 ctx 分支，`panel_shutdown_test.go` 同步改成断言 `reconnect`）。

**1. 范围与触发**：改下列任一处都要对照本节——面板 `log.go` / `deps.go` / `subscription.go` 里 SSE 的
`ctx.Done()` 分支，`server/main.go` 的 `BaseContext` / `RegisterOnShutdown` / `shutdownPanel`；APP 的
`SseClient` 对 `done` 的处理与重连，四个 SSE 页面（`TaskLiveLogPage`、`LogStreamPage`、`DepLogStreamPage`、
`SubscriptionPullStreamPage`）的 `done` / `onError` 分支，`TaskLiveLogPage` 轮询的放弃条件。

**2. 签名**

| 流 | 面板代码 | 关停时最后一帧 |
|---|---|---|
| `GET /api/v1/logs/:id/stream` | `log.go` 的 `LogHandler.Stream`：TinyLog 实时分支、排队短轮询分支、运行中却没有 TinyLog 的 `c.Stream` 轮询分支（step 开头判 `c.Request.Context().Err()`），三处都发 | `event: done` / `data: reconnect` |
| `GET /api/v1/deps/:id/log-stream` | `deps.go` 的 `DepsHandler.LogStream`，订阅循环里的 `case <-ctx.Done()` | `event: done` / `data: reconnect` |
| `GET /api/v1/subscriptions/:id/pull-stream` | `subscription.go` 的 `SubscriptionHandler.PullStream`，同上 | `event: done` / `data: reconnect` |

- 面板触发链：`main` 建 `http.Server` 时设 `BaseContext`（请求 ctx 都派生自 `requestsCtx`）并
  `RegisterOnShutdown(cancelRequests)`；`shutdownPanel` 先起协程跑 `server.Shutdown(5s)`（关监听 → 取消
  `requestsCtx` → 各 SSE 走 ctx 分支写完结束帧再 return），同时 `service.HaltSchedulerV2()` 按进程组杀任务。
  进 `shutdownPanel` 的入口：SIGTERM / SIGINT，以及 `handler.SetPanelExitRequester` 接上的面板自发退出
  （`Restart` 退出码 1、`StopPanel` 0、二进制 / Magisk 在线升级的 `panelProcessExit(0)`）。
- APP：`SseClient` 在 `autoReconnect: true` 下收到 `done` + `reconnect`，先回调 `onEvent`，再
  `_scheduleReconnect(generation, 1 秒)`——**只重连这一次**，连不上（抛异常、或回 401 以外的 4xx / 5xx）就
  `onError`，不再重试。`timeout` 等其它值不触发重连。四个 SSE 页面都开了 `autoReconnect: true`
  （依赖 / 订阅页从仓库最早的 tag v1.0.2 起就是），所以关停发 `reconnect` 对所有版本的 APP 都成立。

**3. 契约**

面板侧：

1. 三条流都复用旧值 `reconnect`，不是新协议：与会话撤销、`streamDoneEvent` 的「任务已经在跑」同值。
   依赖 / 订阅流**不能**发 `timeout`：APP 依赖 / 订阅页（v1.0.2 起）对 `reconnect` 以外的 `done` 一律置
   `_done = true`、显示绿色「…完成」，关停会变成假成功；`reconnect` 则让所有版本的 APP 重连一次、失败后显示红色
   「…连接已断开」，与 v3.3.4 被强杀时一致。网页依赖页对 `timeout` / `reconnect` 显示同一句「日志流已断开，
   任务可能仍在进行」，网页订阅页把 `finished` / `not_running` / `closed` 以外的值都当「连接中断」，换值对网页无影响。
   `timeout` 只留给非关停场景：依赖流的硬上限（依赖操作超时 + 5 分钟）、订阅流的 5 分钟无输出。
2. 关停时的 `reconnect` **不代表任务还在跑**（任务正在被杀）；在依赖 / 订阅流上也**不代表操作结束**（依赖安装不随
   关停取消，记录停在 `installing`，下次启动由对账改成已安装 / 续装 /「操作因服务重启而中断」）。
3. 流先断、任务后结算：停机调研对原型实测，关停开始后 1~3 ms 收流，结算约 20 ms。被打断那次运行追加的
   `[面板正在关闭，任务已中断]`、`[面板正在关闭，跳过后置脚本]` **不在流里**，只在结算后的 latest-log / 日志详情里。
4. 写结束帧时监听已经关了，面板通常要停好几秒：Docker「重启面板」入口脚本等 2 秒再拉起（这期间容器里的 nginx
   还在，回 502）；systemd 下按 `RestartSec=3` 拉起；Magisk 存活守护约 60 秒一轮；停容器、「停止面板服务」要等
   用户手动拉起。
5. 正常关停 = `docker stop` / compose down / restart / NAS「停止」/ watchtower 换镜像、旧 docker.sock 一键更新
   （`docker rm -f` 前先 `docker stop -t 10`）、systemd stop / restart、二进制 Ctrl+C / 关 Windows 控制台窗口、
   `ddp restart`、面板里的重启 / 停止 / 在线升级。关停一开始流就带着结束帧收了，之后宽限到点的 SIGKILL、8 秒总兜底
   都不影响。**没有结束帧**的只有：没先发 TERM 的强杀（`docker kill`、`docker rm -f`、`kill -9`、OOM）与进程崩溃
   ——连接异常断开；断电 / 断网——可能连断开信号都没有。面板 ≤ v3.3.4 任何停法都是异常断开。

APP 侧（必须保持）：

1. `reconnect` 永远不当结束：不置 `_done = true`、不回落、不显示「…完成」（两个日志页还会把状态改回「运行中」）。
   依赖 / 订阅页现在会把它当一行日志追加进正文（末尾多一行字面量 `reconnect`），修第 3 条时一起改掉。
2. 恢复是页面的事：按面板侧第 4 条，`SseClient` 那一次 1 秒重连多半失败。`TaskLiveLogPage` 靠「`onError` →
   每秒轮询 live-logs」恢复，**失败的轮询不能计入放弃**（现在的放弃条件只认 live-logs 成功回来后才会设的
   「等待日志...」）。
3. `timeout`（面板非关停场景发：依赖流硬上限、订阅流 5 分钟无输出）不是成功，载荷也不是日志行：不能出绿色
   「…完成」，不能把 `timeout` 追加进正文（即本文「『未知值』必须诚实」：兜底不许落到绿色成功）。
   依赖 / 订阅页目前违反这一条，是 APP 既有问题（见第 4 节），待 APP 修。
4. 被打断那次运行的结果以 latest-log / 日志详情为准。要补就在面板回来、确认运行已结束之后拉；不要在收到
   `reconnect` 时拉——那时还没结算，面板也正在退出。
5. 新旧面板要落到同一个终态：旧面板关停时只有 `onError`，新面板多一个结束帧。

**4. 校验与错误矩阵**（APP v1.3.9 开发中工作区，2026-10-05）

| 页面 | 收到结束帧 | 1 秒后重连失败、面板没回来 | 面板回来后 |
|---|---|---|---|
| `TaskLiveLogPage`（`task_list_page.dart`） | `reconnect` →「运行中」 | `onError` →「连接错误」+ 转圈，每秒轮询一次、不放弃 | live-logs 回「没在跑」→「等待日志...」→ 轮询满 15 跳（停机期间失败的也算）收口为「已完成」（正文空则「暂无日志」）：正文是 SSE 来的就停在断流那一刻，**缺契约第 3 条那两行**；否则回落 latest-log 拿全量 |
| `LogStreamPage`（`log_stream_page.dart`） | `reconnect` →「运行中」 | `onError` →「连接错误」**终态**（`_done = true`，Chip 是对勾） | 不恢复，要退出重进（重进时这条日志已结束，正文是全量） |
| `DepLogStreamPage`（`dep_list_page.dart`） | `reconnect` → 正文末尾多一行字面量 `reconnect`，不置 `_done`，仍是进行中 | `onError`（含 nginx 回 502）→ `_done = true` + 红色「安装日志连接已断开」**终态**，与配 v3.3.4 被强杀时相同 | 不恢复，要退出重进 |
| `SubscriptionPullStreamPage`（`subscription_list_page.dart`） | 同上 | 同上 → 红色「拉取日志连接已断开」 | 不恢复，要退出重进 |

- **APP 既有问题（与关停无关，待 APP 修）**：依赖 / 订阅页的 `onEvent` 先 `_logs.add(event.data)`，再对 `reconnect`
  以外的一切 `done` 置 `_done = true`，于是面板在**非关停**场景发的 `timeout`（依赖流硬上限 = 依赖操作超时 + 5 分钟、
  订阅流 5 分钟无输出）、依赖的 `failed` / `cancelled`、订阅的 `closed` 都显示绿色「…完成」，正文末尾还多一行载荷原文。
  面板 v3.3.5 开发中曾让关停也发 `timeout`，会让这两页的关停表现从红变绿；已改成 `reconnect` 规避，关停不再触发它。
  修 APP 时不能指望面板以后不发 `timeout`，见下文第 7 节的修复方向。
- 两个日志页新旧面板殊途同归（旧面板直接 `onError`）。`LogStreamPage` 不恢复是既有局限，与 v3.3.4 被强杀时同一
  终态；要修就照 `TaskLiveLogPage`：`onError` 后定时重拉日志详情，结束了就换成详情正文。APP v1.3.8 及更早的
  `TaskLiveLogPage` 恢复时会被空快照清掉正文、停在「暂无日志」+ 转圈，v1.3.9 的 `_logFromSse` 守卫已修。
- 面板 1 秒内就回来了（少见，例如 `systemctl restart`）：重连到的是新进程，这次运行已结算、TinyLog 不在 →
  `done: finished`，两个日志页直接「已完成」，同样缺那两行。依赖 / 订阅页这时会把历史再显示一遍（这两页不做
  重放去重），随后按新进程给的内容收口：依赖按启动对账后的状态（已结束的直接回终态，`failed` 也显示「安装完成」，
  即上面的既有问题），订阅在新进程里没有这次拉取 → `not_running`，正文非空时同样显示「拉取完成」。
- 面板回来后任务又跑起来（开机任务、定时到点）：`TaskLiveLogPage` 轮询看到「在跑」就再连，`SseReplayBuffer`
  第一行就对不上、整段放行，新一次运行接在旧内容后面、没有分隔（旧内容被裁过时，新运行开头还会按
  `droppedCount` 被跳过几行）。既有行为，与结束帧无关。
- 断电 / 断网：APP 的 SSE 没有读超时，也不拿面板的心跳注释当看门狗，页面可能一直停在「运行中」。

**5. 正常 / 基础 / 错误用例**

- 正常：看着运行中任务的实时日志，在面板点「重启面板」（Docker）→「运行中」→ 约 1 秒后「连接错误」→ 面板约
  2 秒后回来 →「等待日志...」→ 十几秒后「已完成」，正文保留断流前的内容。
- 基础：停容器后一直不拉起 → `TaskLiveLogPage` 一直「连接错误」+ 转圈、每秒一次请求，直到离开页面；
  `LogStreamPage` 停在「连接错误」。
- 基础：依赖安装中停容器 → 依赖页末尾多一行 `reconnect`，约 1 秒后红色「安装日志连接已断开」（与配 v3.3.4 被强杀时
  同一终态）；装没装好要等下次启动对账，退出重进依赖页看结果。
- 错误（APP 既有问题，与关停无关）：依赖装了很久撞上面板的硬上限 → 面板发 `timeout` → 依赖页末尾一行 `timeout` +
  绿色「安装完成」，其实装没装好不知道。

**6. 必须有的测试**

- 面板（已有）：`server/handler/panel_shutdown_test.go` 的 `TestShutdownEndsSSEStreamsWithDoneEvent`——实时日志
  三个分支与依赖、订阅两条流共五行，都以 `event: done` + `data: reconnect` 结尾，`Shutdown` 后 1 秒内收流；
  删掉任一处结束帧、或依赖 / 订阅改回 `timeout`，对应那行变红。`server/service/shutdown_wiring_test.go` 钉 main 里的
  `BaseContext` 与 `RegisterOnShutdown`。
- APP（目前没有，改到相关代码时补）：
  1. `test/core/network/sse_client_test.dart`：第 1 次回
     `sseResponse('data: a\n\nevent: done\ndata: reconnect\n\n')`，第 2 次抛 `http.ClientException`（另一条用
     `emptyResponse(502)`）→ `onError` 恰 1 次、`requests.length == 2`、`onDone` 0 次。钉住「只重连一次，恢复归页面」。
  2. `test/features/tasks/task_live_log_page_test.dart`：首屏 live-logs 回「在跑」，SSE 推历史 + `done: reconnect`、
     之后的连接一律抛错；live-logs 接着失败 20 跳，再回 `{logs: [], done: true, status: 1}` → 停机期间有
     「连接错误」、没有「已完成」；恢复后「已完成」、`lines == history`，放弃后 live-logs 调用数不再增加。
     突变：给轮询加「失败 N 次就放弃」，这条应红。
  3. 修依赖 / 订阅页时：`done: timeout` → 找不到「安装完成」/「拉取完成」、正文没有 `timeout` 这一行；
     `done: reconnect` 后重连失败 → 红色「…连接已断开」、正文没有 `reconnect` 这一行；
     `done: installed` / `finished` 仍显示「…完成」。

**7. 错误 vs 正确**

```dart
// ❌ 依赖页现状（_DepLogStreamPageState 的 onEvent）：载荷当一行日志，reconnect 以外一律算完成
setState(() {
  _logs.add(event.data);                          // 末尾多一行载荷原文："timeout" / "reconnect" / "failed"
  if (event.event == 'done' && event.data != 'reconnect') {
    _done = true;                                 // → 非关停的 timeout、failed 也是绿色「安装完成」
  }
});
```

```go
// ❌ 面板关停时给依赖 / 订阅流发 timeout（面板 v3.3.5 开发中第二波）：所有版本的 APP 依赖 / 订阅页都显示绿色「…完成」
case <-ctx.Done():
    fmt.Fprintf(c.Writer, "event: done\ndata: timeout\n\n")

// ✅ 三条流关停时都发 reconnect：APP 重连一次，面板没起来就红色「…连接已断开」，与 v3.3.4 被强杀时一致
case <-ctx.Done():
    fmt.Fprintf(c.Writer, "event: done\ndata: reconnect\n\n")
```

```dart
// ✅ 修复方向（未实施）：done 先分辨载荷、不进正文；timeout 与 onError 同走红色 banner
if (event.event == 'done') {
  if (event.data == 'reconnect') return;          // 交给 SseClient 重连，也不进正文
  setState(() {
    _done = true;
    if (event.data == 'timeout') {
      _errorMessage = '日志流已断开，安装可能仍在进行';   // 与网页依赖页同口径
    }
  });
  return;
}
setState(() => _logs.add(event.data));
```

```dart
// ❌ 给 TaskLiveLogPage 的轮询加「连续失败 N 次就放弃」
} catch (_) {
  if (++_pollFailures >= 15) { _pollTimer?.cancel(); setState(() => _done = true); }
}
// 面板停的时间常常超过 15 秒（Magisk 守护 60 秒一轮、watchtower 换镜像）：面板回来之前页面就收口，再也不会恢复。

// ✅ 现状：失败的一跳不动状态，放弃只发生在 live-logs 成功回来、状态是「等待日志...」时
if (_pollAttempts >= 15 && mounted && _statusText == '等待日志...' && identical(timer, _pollTimer)) { … }
```

---

## 已知仍然存在的漂移源

| 位置 | 状态 |
|---|---|
| `web/src/views/api-docs/apiData.ts` | 文档字符串，已经漂了（wecom_app 漏 `mpnews`）。绑死测试覆盖不到 TS |
| `Task / Dependency / EnvVar / NotifyChannel` 的 `toJson()` | **死代码**，真实请求体是页面内联字面量。每个实体两份字段清单。`Subscription` 那份已删 |
| 111 处裸 `showSnackBar(`（14 文件） | 绕过 `AppSnack`，单列 backlog。8 个文件零使用 `AppSnack`，`env_list_page` 是迁了一半 |
| 4 个 State 无 `error` 字段 | `Notification / User / Dep / Script`，断网时静默变空 |
| `SubscriptionListState` / `DashboardData` 有 `error` 但 UI 不读 | 「改了一半」：字段有、set 了，build 里没人消费，仍显示「暂无订阅」 |
