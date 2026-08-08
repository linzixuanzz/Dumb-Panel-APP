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

> **为什么这条值得写下来**：`parseSystemConfigGroups` 会跳过 `registered != true` 的项，
> 一条都收不到就显示「面板没有返回任何可编辑的系统配置」。而改造前那 10 个硬编码键
> **根本不看 `registered`**。如果这个前提不成立，用户会从「能改 10 项」变成
> 「一项都改不了 + 一句看不懂的错」—— **比改造前更糟**。
>
> 引入新的「依赖某个键存在」的降级判据时，照这个格式查一次并记在这里。

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

## 已知仍然存在的漂移源

| 位置 | 状态 |
|---|---|
| `web/src/views/api-docs/apiData.ts` | 文档字符串，已经漂了（wecom_app 漏 `mpnews`）。绑死测试覆盖不到 TS |
| `Task / Dependency / EnvVar / NotifyChannel` 的 `toJson()` | **死代码**，真实请求体是页面内联字面量。每个实体两份字段清单。`Subscription` 那份已删 |
| 111 处裸 `showSnackBar(`（14 文件） | 绕过 `AppSnack`，单列 backlog。8 个文件零使用 `AppSnack`，`env_list_page` 是迁了一半 |
| 4 个 State 无 `error` 字段 | `Notification / User / Dep / Script`，断网时静默变空 |
| `SubscriptionListState` / `DashboardData` 有 `error` 但 UI 不读 | 「改了一半」：字段有、set 了，build 里没人消费，仍显示「暂无订阅」 |
