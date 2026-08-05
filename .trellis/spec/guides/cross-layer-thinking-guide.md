# 跨层思考清单

> **用途**：动手前想清楚数据怎么在层与层之间流动。

---

## 问题

**多数 bug 发生在层的边界上，不在层的内部。**

本仓库的层：

```
面板 HTTP API
  ↓  ApiEndpoints（路径常量）
dio / SseClient（传输，含 validateStatus + AuthInterceptor）
  ↓  api_utils（extractData / extractPaginated / extractErrorMessage）
Model.fromJson（防御式解析）
  ↓
StateNotifier → XxxState（loading / error / 业务字段）
  ↓  ref.watch / ref.read
Widget（SnackBar / 空状态 / 列表）
```

回写方向：

```
Widget 表单 → Notifier 方法 → Model.toJson 或裸 Map → dio → 面板
```

---

## 动手之前

### 第一步：画出数据流

对每一个箭头问：

- 这里的数据是什么形状？
- 可能出什么错？
- 谁负责校验？

### 第二步：识别边界

| 边界 | 本仓库常见问题 |
|---|---|
| 面板 ↔ dio | **4xx 不抛异常**（`validateStatus: status < 500`），错误体被当成功响应解析 |
| dio ↔ api_utils | 响应有 3 种包裹形态：`{data:[...],total:N}` / `{data:{data:[...],total:N}}` / 裸 `[...]` |
| api_utils ↔ Model | 字段可能是 `List` 也可能是逗号串（`task.dart:134-136` 的 `labels`） |
| Model ↔ State | `toJson` **不是** `fromJson` 的镜像，是提交体，会省略只读字段 |
| State ↔ Widget | `error` 字段被赋值但 UI 不读（11 个 State 里 4 个有 error，只有 1 处被消费） |
| Widget → 回写 | **「读取-修改-回写」丢字段**（见下方专章） |

### 第三步：定义契约

对每个边界写清楚：输入格式、输出格式、可能的错误。

---

## 本仓库真实的跨层坑

### 坑 1：`validateStatus` —— 一行配置，全层失效

`lib/core/network/dio_client.dart:16`：

```dart
validateStatus: (status) => status != null && status < 500,
```

4xx 被判为成功，波及**每一层**：

| 层 | 失效表现 |
|---|---|
| 拦截器 | `AuthInterceptor.onError` 永不触发 → 70 行续期 + 排队重发是死代码（`:46-114`） |
| 解析层 | `extractPaginated` 从错误体里解出空列表 |
| provider | `catch` 兜不到 4xx，`error` 保持 null |
| UI | 显示「暂无数据」，用户以为面板是空的 |
| 设置页 | 400 也弹「配置已保存」（`system_settings_page.dart:496-529`） |

**局部绕过存在但不成体系**：`auth_service.dart:68-84` 登录接口自己判 `statusCode >= 400`
手动抛 `DioException`；`sse_client.dart:61` 单独处理 401（SSE 不经 dio）。

> **改这一行之前**：`rg "DioClient.instance.dio" lib` 找出所有调用点，逐个确认 catch 兜得住。
> 这不是抽查能过关的事。

### 坑 2：「读取 → 修改 → 回写」丢字段

**症状**：用户在 Web 端配的参数，经 APP 编辑保存后消失。

**成因**（`notification_list_page.dart:735-757`）：编辑时 `configMap` 从 `{}` 开始，
只填客户端写死的 `_channelFieldMap`（229 行常量表，`:361`）里有的键，然后整串
`jsonEncode(configMap)` 覆盖回服务端。面板支持而 APP 表里没有的键（telegram proxy、
wecom 图文卡片参数等）**保存即丢失**。

**正确对照**（同仓库内）：`open_api_page.dart:671` 用 `_parseScopes(scopes).toSet()`
完整保留未知 scope，保存时原样带回。

**清单**：

- [ ] 回写的基底是**服务端返回的原始对象**，不是新建的空对象
- [ ] 客户端字段表只用于**渲染表单**，不得用于**决定提交哪些键**
- [ ] 有测试证明：塞一个客户端不认识的键，保存后它还在

### 坑 3：一处路径改了，另一处没改

`ApiEndpoints` 是唯一路径来源，但有 3 处绕过它直接拼字符串：
`system_settings_page.dart:265 / 349 / 419`。面板改路径时这三处不会被 `rg ApiEndpoints` 找到。

### 坑 4：分页上限的隐式契约

后端 `page_size` 上限 100，**超限静默退回 20**（不是报错）。
`env_list_page.dart:67-69` 的注释记录了这次事故（列表只显示 40 行）。

三种分页策略在仓库里并存（一次性 `all=1` / 循环拉完 / 滚动加载更多），
改任何一处前先确认对应端点的实际上限。

### 坑 5：时间与时区

后端返回 ISO 字符串，`_date()` 用 `DateTime.tryParse` 解析（保留 UTC 标记），
显示时统一 `formatTimeCn()`（`shared/utils/time_utils.dart:6-17`），内部做 `.toLocal()`。
**不要在页面里自己 `DateFormat`** —— 该文件的注释就是为了终结「页面里混用 MM-dd」。

---

## 通用错误

### 错误 1：隐式格式假设

**坏**：假定 `labels` 一定是字符串。
**好**：`json['labels'] is List ? (...).join(',') : json['labels']?.toString() ?? ''`（`task.dart:134-136`）。

### 错误 2：校验散落在多层

**坏**：模型、provider、widget 各判一次 null。
**好**：解析层（`fromJson`）负责把类型变干净，上层拿到的就是非空的确定类型。

### 错误 3：抽象泄漏

**坏**：widget 里出现 `response.data['data']['total']`。
**好**：widget 只碰 State 的字段和 getter。`dynamic` 止步于 `api_utils`。

---

## 跨层改动清单

**实现前**：

- [ ] 画出完整数据流（API → 解析 → State → UI，以及回写方向）
- [ ] 列出所有边界
- [ ] 定义每个边界的格式
- [ ] 决定校验在哪一层做

**实现后**：

- [ ] 用边界情况测过（null、空列表、字段缺失、字段类型不符）
- [ ] 每个边界的错误处理都验证过
- [ ] **数据能完整往返**（读出来 → 改一个字段 → 存回去 → 再读，其他字段没变）
- [ ] 失败路径下用户看到的是原因，不是「暂无数据」也不是假的「保存成功」

---

## 什么时候该单独写流程文档

- 改动跨 3 层以上
- 数据形状复杂或有多种兼容形态
- 这块以前出过 bug

本仓库已有的这类文档：
`.trellis/tasks/08-05-app-v2-phase0-foundation/research/legacy-compatibility-map-v2218-2219.md`
（记录面板 v2.2.18 / v2.2.19 两次更新各自要求 APP 改哪些地方）。
面板每次升级都要改 APP —— 这正是第 2 期「通用化适配」要解决的模式。
