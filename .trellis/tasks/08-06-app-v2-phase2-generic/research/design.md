# 呆呆面板 / APP 通用化适配 —— 第 2 期方案

> 所有 file:line 均在本次会话内实读核对。与五路调查报告冲突处以本文为准，冲突点在文末「前提纠正」列出。

---

## 0. 结论先行

这一期不是「把面板功能抄到 APP」，而是**把面板对自己的描述从代码里搬到接口上**。

面板对自身的知识目前存在三种形态，处理成本差一个数量级：

| 形态 | 代表 | 面板端成本 | 实例 |
|---|---|---|---|
| **A 已结构化、已下发、没人用** | 系统配置注册表 | 极低（补 4 个字段） | 47 项配置 |
| **B 已结构化、但长在 Web 仓库的 TypeScript 里** | 通知渠道字段表 | 中（翻译 + 补 3 类缺失知识） | 22 渠道 / 91 字段槽 |
| **C 未结构化，只活在 Go 函数体和常量里** | 任务状态、日志状态、依赖类型、恢复阶段 | 中（新建字典） | ~8 张枚举表 |

**「面板已有定义，APP 复用即可」这个判断只对 A 成立。** 按 A 的成本估 B 和 C 会严重低估。

---

## 1. 问题定性

### 1.1 具体是什么问题

不是「APP 功能少」，是 **APP 复制了面板的定义，两份定义没有任何机制保持同步**。

已核实的三条因果链：

**链条 1：面板给通知渠道加一个 config 键 → APP 用户永远看不到输入框**

- 面板 `server/service/notifier.go` 里 23 个 `sendXxx` 函数共读取 **55 个唯一 config 键**（正则 `cfg\["..."\]` 统计）。
- 面板 Web `web/src/views/notifications/index.vue:95-319` 的 `configFields` 有 22 个 case、**91 个字段槽、56 个唯一键**（= 55 个 + `smtp_ssl`，`smtp_ssl` 在 `notifier.go:357-370` 是循环读别名所以不在正则命中里）。**Web 表与服务端读取集完全吻合，是精确镜像。**
- APP `notification_list_page.dart:385-613` 的 `_channelFieldMap`（**正好 229 行**）有 21 个渠道、**44 个字段槽、24 个唯一键**。
- **差值：31 个面板已支持的唯一 config 键在 APP 里没有任何输入入口**，47 个字段槽缺失，`custom` 渠道整个没有字段表。
- 服务端 `/notifications/types`（`server/handler/notification.go:220-246`）只回 `{type, name}` 22 条，**不下发任何字段定义**。APP 无处可读，只能抄。

**链条 2：面板注册一个新配置项 → APP 用户改不了**

- `server/model/system_config_registry.go:49-171` 注册 **47 项**（逐条数过）。
- `server/handler/config.go:47-77` 的 `buildConfigResponseItem` **已经下发** `registered / default_value / value_type / group / description / options`。
- APP `system_settings_page.dart:507-516` 硬编码写回 **10 个键**：`max_concurrent_tasks / log_retention_days / max_log_content_size / random_delay / random_delay_extensions / auto_install_deps / editor_background_color / proxy_url / update_image_mirror / binary_update_proxy`。
- **37 项配置在 APP 里完全不存在**：整组 `backup_schedule_*`（8 项）、`captcha_*`（4 项）、`cpu/memory/disk_warn`、`max_web_sessions / max_app_sessions`、`timezone`、`panel_title / panel_icon`、`auto_add_cron / auto_del_cron` 等。
- 这是本期**面板端零改动就能通用化**的唯一一块。

**链条 3：面板给一个 struct 加字段 → APP 静默丢数据**

- `server/service/backup_types.go:9-18` `BackupSelection` 有 **8 个**字段，含 `TaskViews bool \`json:"task_views"\``。
- APP `backup_page.dart:127-135` `toJson()` 只发 **7 个键**；`task_views` 在整个 `android-app/lib` 下 **grep 零命中**。
- `NormalizeDefaults()` 只在 `!Any()` 时生效，APP 发的 7 个 true 让 `Any()==true`，于是 `TaskViews` 保持 Go 零值 `false`。
- **从 APP 发起的每一次备份都在静默丢弃任务视图**，Web `BackupManagementCard.vue:101` 是发的。

### 1.2 反向链条：APP 已经在给面板投毒（与「面板改不改」无关，现在就是坏的）

- APP `channel_config.dart:45-46`：`configMap['smtp_ssl'] = smtpSsl;` —— `smtpSsl` 是 Dart `bool?`，`jsonEncode` 后落地成 `"smtp_ssl": false`。
- 面板 `server/service/notifier.go:166-168`：`var cfg map[string]string; if err := json.Unmarshal(...); err != nil { return fmt.Errorf("invalid config: %w", err) }`。
- Go `encoding/json` 在类型不匹配时记录 `UnmarshalTypeError` 并在 `Unmarshal` 末尾返回非 nil error → **该渠道所有通知（含测试按钮）从此全挂**。
- 服务端对 config 内容零校验（`handler/notification.go` Create/Update 只做空串→`{}`），写进去就发不出去；Web 端 `JSON.parse` 原样读回、原样写回，Web 也修不好。
- 旁证：所有服务端 config 生产者都写字符串 —— `backup_qinglong.go:483 cfg["smtp_ssl"] = "true"`、`index.vue:106-110` 的 select 值是 `'auto'/'true'/'false'`。

> ⚠️ 这条**未在真机验证**（本机无 Go 工具链）。10 秒可证伪：APP 编辑任一 email 渠道 → 保存 → 点「测试」，若报 `invalid config: json: cannot unmarshal bool into Go value of type string` 即坐实。**动手前先跑这一步。**

### 1.3 病灶不在 APP 一侧

同一份渠道知识在两个仓库里有 **4 份副本**：`notifier.go`（权威但非声明式）、`index.vue:95-319`（声明式但在前端）、`backup_qinglong.go:226-396`（青龙导入时各自重写键名）、`web/src/api-docs/apiData.ts:846`（文档字符串，**已漂移**：wecom_app 消息类型漏了 `mpnews`，而 `notifier.go` 和 `index.vue:175` 都有）。

面板自己也在漂移：`system_config_registry.go:129` 的 `backup_schedule_selection` 默认值是 7 项（无 `task_views`），同文件 `:534` 的 `normalizeBackupScheduleSelectionValue` 默认值是 8 项（有 `task_views`）。**如果 APP 改成信任 `default_value`，这一项会立刻表现为「APP 和 Web 不一致」并被误判成 APP 回归。**

结论：**只改 APP 解决不了问题**。必须让面板持有唯一真源，Web 和 APP 同时收敛过去。

---

## 2. 面板端改造（最小集）

### 2.1 【expose 类】扩展 SystemConfigDefinition —— 半天

**现状**：`server/model/system_config_registry.go:30-37` 只有 6 个字段，缺 4 类通用渲染必需的元信息。

```go
type SystemConfigDefinition struct {
    Key          string                `json:"key"`
    DefaultValue string                `json:"default_value"`
    Description  string                `json:"description"`
    ValueType    SystemConfigValueType `json:"value_type"`
    Group        string                `json:"group"`
    Options      []SystemConfigOption  `json:"options,omitempty"`
}
```

**缺什么**：

1. **`Label`** —— `Description` 现在是长句说明（`:137` 的 `panel_runtime_mode` 是三行说明），不能当输入框标题。
2. **`Min`/`Max`** —— **值已经存在但被困在闭包里**：`newIntConfig(...)` 的 `minValue/maxValue` 在 `:259-273` 只被 normalize 闭包捕获，从不写进 `def`。10 处调用都传了。这是 **4 行改动**。
3. **`Secret`** —— `captcha_key`(:160)、`backup_schedule_password`(:126) 与普通 string 无区别，`handler/config.go:54` 无条件明文下发。
4. **`Order` + 分组显示名** —— `Group` 现在只有 `tasks/network/security/branding/backup/alerts/subscription` 英文 slug；`/api/configs` 返回的是 **map 不是 list**（`config.go:88-106` `data := make(map[string]interface{})`），**没有顺序**。通用渲染必须自带 order。

**改法**：

```go
type SystemConfigDefinition struct {
    Key          string                `json:"key"`
    Label        string                `json:"label"`          // 新增：短标题
    DefaultValue string                `json:"default_value"`
    Description  string                `json:"description"`    // 保持：作为 hint
    ValueType    SystemConfigValueType `json:"value_type"`
    Group        string                `json:"group"`
    GroupLabel   string                `json:"group_label"`    // 新增：中文分组名
    Order        int                   `json:"order"`          // 新增：注册顺序
    Secret       bool                  `json:"secret,omitempty"`   // 新增
    Min          *int                  `json:"min,omitempty"`      // 新增：从闭包提出来
    Max          *int                  `json:"max,omitempty"`      // 新增
    Options      []SystemConfigOption  `json:"options,omitempty"`
}
```

`Order` 直接用 `registeredSystemConfigSpecs` 的下标（`SystemConfigDefinitions()` 在 `:586`）。`Label` 对 47 项各写一个短词。

**同时修 2 个 bug**：
- `:129` 的 `backup_schedule_selection` 默认值补上 `task_views`，与 `:534` 对齐。
- 加一个回归测试：`for each def: normalize("") == def.DefaultValue`。这条测试能永久防住这类漂移。

**接口不变**，仍是 `GET /api/configs`，只是 item 多几个键 —— 纯可加性，老 APP 无感。

### 2.2 【结构化类】通知渠道 schema registry —— 2~3 天，本期最大工作量

**明说：服务端目前没有任何声明式的渠道字段定义。** 只有 `notifier.go` 里 23 个函数中散落的 `cfg["key"]` 字面量。

**但也不是从零发明** —— `web/src/views/notifications/index.vue:95-319` 那 225 行 TS 与服务端读取集**逐条吻合**（56 唯一键 = 55 + smtp_ssl）。移植 ≈ 翻译。

新建 `server/model/notify_channel_registry.go`：

```go
type NotifyFieldWidget string
const (
    NotifyWidgetInput    NotifyFieldWidget = "input"
    NotifyWidgetPassword NotifyFieldWidget = "password"
    NotifyWidgetTextarea NotifyFieldWidget = "textarea"
    NotifyWidgetSelect   NotifyFieldWidget = "select"
)

// ShowWhen 只支持「单键等值命中」：field 的值 ∈ Values 时显示。
// 这个表达力刚好覆盖现有全部条件字段（wecom / wecom_app），不要再多。
type NotifyFieldCondition struct {
    Key    string   `json:"key"`
    Values []string `json:"values"`
}

type NotifyFieldDefinition struct {
    Key         string                 `json:"key"`
    Label       string                 `json:"label"`
    Widget      NotifyFieldWidget      `json:"widget"`
    Placeholder string                 `json:"placeholder,omitempty"`
    Required    bool                   `json:"required,omitempty"`
    Default     string                 `json:"default,omitempty"`
    Options     []SystemConfigOption   `json:"options,omitempty"`
    ShowWhen    *NotifyFieldCondition  `json:"show_when,omitempty"`
}

type NotifyChannelDefinition struct {
    Type   string                  `json:"type"`
    Name   string                  `json:"name"`
    Icon   string                  `json:"icon,omitempty"`   // 语义名，如 "mail"/"telegram"
    Fields []NotifyFieldDefinition `json:"fields"`
}
```

**工作量拆解（这是「先结构化」的真实成本）**：

| 子任务 | 量 | 说明 |
|---|---|---|
| 翻译 Web 表 → Go | 22 渠道 / 91 字段槽 / 14 组 options | 机械翻译，可脚本辅助 |
| 条件字段建模 | 2 渠道 / 10 个条件分支 | wecom 5 分支（`index.vue:141-158`）、wecom_app 5 分支（`:178-192`） |
| **条件 options**（难点） | 1 处 | `index.vue:196`：`safe` 的选项集合随 `msg_type` 变（mpnews 时多「仅企业内分享(2)」）。**建议 v1 不支持条件 options，直接把第 3 项常驻**，服务端 `notifier.go` 本来也只是透传 |
| **Required 逐条决策**（新知识） | 8 个渠道 | `serverchan / pushdeer / chanify / igot / pushover / discord / slack / custom` 在 `notifier.go` 里**零校验**。要么补校验要么显式标非必填 —— 这块服务端没有可 expose 的一致事实，必须现场做决策 |
| **Default 归位**（新知识） | ~10 处 | 默认值现在活在函数体：bark server、pushdeer、pushme、chanify、ntfy、wxpusher server、gotify priority=5、wecom_app duplicate_check_interval=1800、wxpusher content_type=1、custom method=POST/content_type/body 模板 |

**接口改法 —— 扩展现有端点，不新增路径**：

`GET /api/notifications/types`（`handler/notification.go:220-246`）从

```json
{ "data": [ {"type":"telegram","name":"Telegram"} ] }
```

改成

```json
{
  "data": [
    {
      "type": "telegram",
      "name": "Telegram",
      "icon": "telegram",
      "fields": [
        {"key":"token","label":"Bot Token","widget":"password","placeholder":"从 @BotFather 获取","required":true},
        {"key":"chat_id","label":"Chat ID","widget":"input","placeholder":"聊天/群组 ID","required":true},
        {"key":"message_thread_id","label":"Topic ID (可选)","widget":"input","placeholder":"群组话题 ID"},
        {"key":"api_host","label":"API 地址 (可选)","widget":"input","placeholder":"留空使用官方"},
        {"key":"proxy","label":"代理地址 (可选)","widget":"input","placeholder":"http/socks5 代理地址"}
      ]
    },
    {
      "type": "wecom",
      "name": "企业微信机器人",
      "fields": [
        {"key":"webhook","label":"Webhook URL","widget":"input","required":true},
        {"key":"msg_type","label":"消息类型","widget":"select","default":"text",
         "options":[{"value":"text","label":"文本"},{"value":"markdown","label":"Markdown"},
                    {"value":"markdown_v2","label":"Markdown V2"},{"value":"image","label":"图片"},
                    {"value":"news","label":"图文"},{"value":"template_card","label":"模版卡片"}]},
        {"key":"content_template","label":"文本模板","widget":"textarea",
         "show_when":{"key":"msg_type","values":["text","markdown","markdown_v2"]}},
        {"key":"mentioned_list","label":"提醒成员 (可选)","widget":"textarea",
         "show_when":{"key":"msg_type","values":["text"]}},
        {"key":"image_base64","label":"图片 Base64","widget":"textarea","required":true,
         "show_when":{"key":"msg_type","values":["image"]}},
        {"key":"news_articles","label":"图文 Articles(JSON)","widget":"textarea","required":true,
         "show_when":{"key":"msg_type","values":["news"]}}
      ]
    }
  ]
}
```

**为什么这个改法零版本兼容成本**：APP `notification_list_page.dart:120-139` 的 `_fetchTypes()` 是 try/catch-不抛 + `_fallbackTypes` 兜底（`:109`/`:114`）。老面板返回没有 `fields` 的项，APP 判断 `fields == null` 就回落本地表。**不需要第二处 `validateStatus` 特判，也不需要 capabilities 端点。**

### 2.3 【补校验】服务端强制 config 值为字符串 —— 2 小时

`handler/notification.go` 的 Create/Update 里，把 `req.Config` 反序列化成 `map[string]any`，逐值 `fmt.Sprintf` 归一成 string 再序列化回去；非法 JSON 直接 400。

**这一条独立于整个方案，应该第一批就发。** 它同时堵死 §1.2 的投毒，并保证未来任何客户端（含 APP、含 schema 驱动出来的表单）都写不出服务端读不了的 config。

### 2.4 【结构化类】枚举字典端点 —— 1 天

新增 `GET /api/system/enums`（挂在 `system.go:683` 的免鉴权区旁边，或至少 JWTAuth 不加 RequireAdmin —— 因为 viewer 也要显示任务状态）：

```json
{
  "data": {
    "task_status":  [{"value":"0","label":"已禁用","tone":"muted"},
                     {"value":"0.5","label":"排队中","tone":"info"},
                     {"value":"1","label":"已启用","tone":"success"},
                     {"value":"2","label":"运行中","tone":"running"}],
    "task_type":    [{"value":"cron","label":"定时任务"},{"value":"manual","label":"手动"},
                     {"value":"startup","label":"启动时"}],
    "log_status":   [{"value":"0","label":"成功","tone":"success"},{"value":"1","label":"失败","tone":"danger"},
                     {"value":"2","label":"运行中","tone":"running"},{"value":"3","label":"已终止","tone":"warning"}],
    "dep_type":     [{"value":"nodejs","label":"NodeJS"},{"value":"python","label":"Python"},
                     {"value":"linux","label":"Linux"}],
    "dep_status":   [...],
    "user_role":    [{"value":"viewer","label":"只读","level":1},
                     {"value":"operator","label":"操作员","level":2},
                     {"value":"admin","label":"管理员","level":3}],
    "restore_stage":[{"value":"preparing","label":"准备中"}, ...],
    "backup_selection": [{"value":"configs","label":"系统配置"}, ..., {"value":"task_views","label":"任务视图"}],
    "openapi_scope":[{"value":"tasks","label":"任务"}, ..., {"value":"notifications","label":"通知"},
                     {"value":"backup","label":"备份"}]
  }
}
```

真源锚点：`model/task.go:11-26`、`model/task_log.go:8-11`、`model/dependency.go:38-48`、`middleware/auth.go:191-196`。
**注意 `TaskStatusQueued = 0.5` 是浮点数**，字典里必须原样带出来。

`backup_selection` 这一项一并解决 §1.1 链条 3：APP 改成按字典渲染勾选项后，面板加第 9 个备份类别 APP 自动跟上。

### 2.5 【不做】capabilities / features 端点

调查报告建议加一个统一的能力探测端点。**我认为本期不该做**，理由见 §6.b。

---

## 3. APP 端改造

### 3.1 可以直接删掉的硬编码表

| 文件:行 | 内容 | 换成 | 前置依赖 |
|---|---|---|---|
| `notification_list_page.dart:385-613` | `_channelFieldMap`（229 行 / 21 渠道 / 44 槽） | `/notifications/types` 的 `fields` | §2.2 |
| `notification_list_page.dart:736-747` | email 专属 `SwitchListTile`（smtp_ssl） | schema 里的 3 选项 select | §2.2 + §2.3 |
| `system_settings_page.dart:92-123, 507-516` | 10 个键的读/写 + 客户端兜底默认值 | `/api/configs` 的 schema 驱动渲染 | §2.1 |
| `backup_page.dart:127-135, 231-237` | 7 项 selection | `/system/enums` 的 `backup_selection` | §2.4 |
| `task_log.dart:26-41`, `log_list_page.dart:606-642` | 日志状态 0/1/2 | `log_status` 字典 | §2.4 |
| `task_form_page.dart:480-484`, `task_list_page.dart:1674-1683` | 任务类型（APP 内部就重复了两份） | `task_type` 字典 | §2.4 |
| `dependency.dart:34-49`, `dep_list_page.dart:393-402,492-494` | 依赖类型/状态（APP 内部两份） | `dep_type` / `dep_status` | §2.4 |
| `user.dart:27`, `user_list_page.dart:57-61,272,372` | 角色层级 + 三份角色数组 | `user_role` 字典（带 level） | §2.4 |
| `open_api_page.dart:21-28` | 6 个 scope（面板实际 8 个） | `openapi_scope` 字典 | §2.4 |
| `backup_page.dart:778-816` | 恢复阶段 13 条文案 | `restore_stage` 字典 | §2.4 |
| `task_form_page.dart:533-537` | 3 条 cron 模板 | `GET /api/tasks/cron/templates`（面板已有 21 条，`api_endpoints.dart:57` 常量已声明、全库零调用） | **无，现在就能做** |

### 3.2 必须保留（不要下发）

- **`_fallbackTypes`（`:37-60`）和 `_channelFieldMap` 的一份冻结快照** —— 但语义要变：从「需要维护的表」变成「**v3.0.0 基线快照，此后永不更新**」。加文件头注释写死这一点，并加 lint/CI 规则禁止再往里加键。
- **导航结构、页面存在与否** —— 服务端驱动 UI 是陷阱，见 §6.c。
- **`app_lock` / `secure_storage` / 主题 / 本地缓存** —— 纯客户端。
- **`app_update_service.dart`** —— 这是 APP 自己查 GitHub 更新（`_kGitHubRepo = 'linzixuanzz/Dumb-Panel-APP'`），与面板版本无关，别动。
- **图标 IconData 映射** —— schema 可以下发语义名（`"telegram"`），但名字→`IconData` 的映射必须在 APP 里，因为 Flutter 图标是编译期常量。下发未知名字时回落 `Icons.webhook`（现状 `:882-898` 已经是这个行为）。

### 3.3 动态表单渲染器需要支持的能力（从实际数据推，不是设计）

面板 Web 的渲染器 `index.vue:795-819` **本来就是通用 `v-for`**，已实战验证。APP 要补到同等能力：

| 能力 | 依据 | 实际用量 |
|---|---|---|
| `input` | `index.vue` widget 统计 | 大多数 |
| `password` | 同上 | smtp_pass、wecom_app secret |
| `textarea` | 同上 | 全部 JSON 类字段（news_articles、template_card_payload、mpnews_articles、image_base64、mentioned_list…） |
| `select` + `options` | 同上，**14 组 options** | smtp_ssl、msg_type ×2、safe、level、template、mode、priority、content_type、method… |
| `show_when`（单键等值） | `index.vue:141-158, 178-192` | 2 渠道 / 10 分支 |
| `required` 前端拦截 | 新增 | 见 §2.2 决策项 |
| `min`/`max` 数字校验 | §2.1 | 10 个 int 配置 |
| `secret` → obscure | §2.1 | captcha_key、backup_schedule_password |
| `bool` → Switch | `/api/configs` 的 `value_type` | 10 个 bool 配置。**注意：值仍是字符串 `"true"/"false"`**（`newBoolConfig` 走 `strconv.FormatBool`），不要写成 JSON bool —— 这正是 §1.2 的教训 |

**四种 widget + show_when + 5 个约束标记，就是全部。** 不要设计表达式引擎、不要设计跨字段联动 DSL。

### 3.4 顺手修掉的既有 bug（与 schema 无关，但同源）

- `system_settings_page.dart:833` 标签写「日志背景色」，绑定的 `_editorBackgroundColorC` 实际读写 `editor_background_color`（`:106-108`、`:513`）—— **改的是脚本编辑器背景**。面板 `registry:93-95` 是三个独立配置。schema 驱动后 label 来自服务端，这类配对错误结构上消失。
- `page_size: 200` 三处（`subscription_list_page.dart:63`、`task_form_page.dart:207`、`dep_list_page.dart:138`）超过面板上限 100，被静默回落到 20 → **订阅列表超过 20 条就看不见**。
- 订阅表单缺 `auth_type / auth_username / auth_token`（APP `lib` 下 grep 零命中，只有 `subscription.dart` 的 `sshKeyId` 且是死代码）→ 私有仓库订阅在 APP 建不了。
- 5 个 model 的 `toJson()` 是死代码（真实请求体是页面内联字面量），每个实体两份字段清单且 subscription 的两份已不一致。**通用化前先删掉或统一走 model**，否则「改了没效果」的坑会一直复发。

---

## 4. 版本协商与降级

### 4.1 核心策略：形状探测优先，能力清单只在必要时用

**不要**建立「先查能力清单，再决定调不调接口」的机制。理由：

1. `handler.Version` 由 `release.yml` 用 ldflags 注入（源码默认值 `"3.0.0"`），**任何本地 `go build` / fork 构建都自称 3.0.0**，版本号不可信。
2. `/api` 与 `/api/v1` 是全等双挂载（`router.go:14-15, 35-84`），自初始提交就并存，**不是版本轴**。
3. `api_version` 硬编码 `"v1"`，从初始提交至今未变。
4. 能力清单本身就是一份手写常量数组 —— **它诞生那一刻就变成了服务端版的 `_channelFieldMap`**。

**实际策略是三层，按成本从低到高**：

**层 1：可加性字段探测（覆盖本期 90% 的场景）**

所有新增的 schema 都以「已有端点多返回几个键」的形式下发。APP 判断：

```dart
// 渠道 schema
final fields = typeItem['fields'];
final effective = (fields is List && fields.isNotEmpty)
    ? fields.map(NotifyFieldSchema.fromJson).toList()
    : _frozenFallbackFieldMap[type] ?? const [];   // v3.0.0 冻结快照
```

```dart
// 配置 schema
final label = item['label'] as String?
    ?? item['description'] as String?     // 老面板：退化用 description 当标题
    ?? key;
final secret = item['secret'] == true;    // 老面板：null → false → 明文框（可接受）
final ordered = items.where((e) => e['registered'] == true).toList()
  ..sort((a, b) => (a['order'] ?? 1 << 30).compareTo(b['order'] ?? 1 << 30));
// 老面板无 order → 全部落到末尾，按 key 字典序（现状本来就是 map 无序）
```

**关键判断：`GET /api/configs` 在老面板上就已经返回了 `registered/value_type/group/options/default_value`**（`config.go:47-77`，v3.0.0 已在线），所以**系统设置页的 schema 驱动改造对老面板天然可用**，只是 label 退化成 description、无 min/max 前端校验（服务端 `:269-271` 仍会 400）。这是本期性价比最高的一块。

**层 2：新端点 → 单次探测 + 缓存（只有 `/system/enums` 属于这类）**

APP 启动后首次进入需要枚举的页面时调一次，成功则缓存到内存 + `SharedPreferences`；404/任何异常 → 用冻结快照，且**在本次进程内不再重试**。

统一收敛成一个函数，而不是每个调用点手写 catch：

```dart
// lib/core/schema/panel_schema.dart
class PanelSchema {
  static Future<Map<String, List<EnumOption>>> enums() async { /* 单飞 + 缓存 + 404→快照 */ }
}
```

同时把现有 4 处「事实上在吸收老面板 404 但没标注」的 catch 收编进来：`dashboard_provider.dart:83-90` 的 `_optional`、`notification_list_page.dart:120-139` 的 `_fetchTypes`、`dep_list_page.dart:216`、`env_list_page.dart:141`。**否则会出现「网关说不支持、页面又自己 try 了一次」的双重逻辑。**

**层 3：不适用**

`/auth/captcha-config` 那处 `validateStatus < 500`（`auth_service.dart:99`）保留原样，不推广。

### 4.2 已知覆盖不到的地方（必须写进文档）

**SSE 完全不经过 dio**（`sse_client.dart` 用 `package:http`，`:62-66` 有注释说明 `AuthInterceptor` 覆盖不到）。4 条流式链路 —— `logStream`、`taskLiveLogs`、`depLogStream`、`subscriptionPullStream` —— **任何 dio 拦截器方案都覆盖不到**。所以 `PanelSchema` 必须是纯 Dart 的查询函数，不能做成拦截器。

另外 `sse_client.dart:58-69` 只特判 401，**404 时服务端返回的 `{"error":"route not found"}` 不以 `data: ` 开头，被逐行丢弃、stream 自然结束、不触发 onError** → 表现为「页面永远转圈」。本期不改 SSE，但要记录：**未来任何新增的流式端点必须先在非流式端点上探测存在性**。

### 4.3 老 APP + 新面板（不可控方向）

面板改动必须保持**响应可加性**：只加键、不改键名、不改类型。特别注意面板现在响应形态本身就不统一（`pkg/response/response.go` 的 `Success` 是裸 `c.JSON`，`/api/version` 扁平、`/api/system/version` 带 `data` 信封、`/api/system/public-version` 两者兼有）。**新增的 schema 一律用 `{"data": ...}` 信封**，与 `/configs`、`/notifications/types` 一致。

---

## 5. 分批实施顺序

依赖方向：**面板批次先合并 + 先发版，APP 对应批次才能上线**。但 §4.1 层 1 的设计保证 APP 批次**即使先发也不会崩**（回落快照），所以两个仓库可以并行开发、串行验收。

---

### 批次 0 · APP 独立修复（无任何面板依赖）

**仓库**：APP
**改动**：
1. `channel_config.dart:45-46` —— `configMap['smtp_ssl'] = smtpSsl ? 'true' : 'false';`（改成字符串）；同步改 `channel_config_test.dart:71` 的断言。
2. `backup_page.dart:127-135, 231-237` —— 补 `task_views`（先硬编码，批次 4 再换字典）。
3. `page_size: 200` 三处改 100，订阅列表补分页/无限滚动。
4. `task_log.dart:26-41` 补 status 3 = 已终止；`log_list_page.dart` 补筛选项；`dashboard_provider.dart:58-59`、`trend_chart.dart:19-27` 补 aborted。
5. `system_settings_page.dart:833` label 改「脚本编辑器背景色」（或改绑到 `log_background_color`，二选一，写清楚选了哪个）。
6. 删掉 5 个 model 的死 `toJson()`（或让页面统一走 model —— **建议直接删**，页面内联字面量才是真实契约）。

**风险**：低。第 1 项是修数据损坏，第 2 项改变备份包内容（**变大**，要在 release note 写明）。
**验证**：
- ⚠️ **先跑 §1.2 的 10 秒证伪实验**，确认 smtp_ssl 确实是 blocker 再改。
- 改后：APP 编辑 email 渠道 → 保存 → 点「测试」→ 应收到邮件；`SELECT config FROM notify_channels` 确认 `"smtp_ssl":"false"` 是字符串。
- 从 APP 发起备份 → 解包确认含 `task_views`。

**可独立回滚**：是。

---

### 批次 1 · 面板：配置 schema 补全 + config 值强制字符串化

**仓库**：面板
**改动**：§2.1（`SystemConfigDefinition` 加 5 字段 + 47 项补 Label + `backup_schedule_selection` 默认值修正）+ §2.3（`handler/notification.go` Create/Update 值归一化）。
**测试**（必须写，这是防漂移的地基）：
- `TestEveryConfigNormalizeEmptyEqualsDefault`：`for each def: normalize("") == def.DefaultValue`。
- `TestConfigListIncludesLabelOrderSecretMinMax`：扩展现有 `config_regression_test.go:18-76`。
- `TestNotifyChannelConfigCoercedToString`：POST 一个 `{"smtp_ssl": false}`，读回应为 `"false"`。

**风险**：低（纯可加性）。唯一行为变更是 `backup_schedule_selection` 默认值多了 `task_views` —— 定时备份包会变大。
**验证**：`curl /api/configs` 检查 47 项都有 `label/order`，`captcha_key` 有 `secret:true`，10 个 int 有 `min/max`。
**可独立回滚**：是。

---

### 批次 2 · 面板：通知渠道 registry + Web 切换 + `/notifications/types` 扩展

**仓库**：面板（server + web 同一次提交）
**改动**：§2.2。
**关键验收动作 —— 不做这一步整个方案作废**：
把 `web/src/views/notifications/index.vue:95-319` 的 `configFields` 从 `computed(硬编码)` 改成 **fetch 结果**，并**删掉那 225 行 TS**。渲染器 `:795-819` 一行不用改（它本来就是通用的），只需把 `show_when` 的过滤逻辑从 `...(cond ? [...] : [])` 改成对 schema 的 filter。

**风险**：**本批次风险最高**。22 个渠道的表单在 Web 上全部换血。
**验证**：
- 逐个渠道打开编辑框，与改动前截图对比字段数与顺序（91 个槽）。
- wecom / wecom_app 切换 msg_type，确认条件字段显隐一致。
- **写一个 Go 测试把 schema 与 notifier 绑起来**（详见 §6.a）。
- `curl /api/notifications/types` 检查 22 项都有 `fields`，总槽数 = 91（若决定把 wecom_app `safe` 的第 3 选项常驻，则 options 数会变，需重新计基线）。

**可独立回滚**：是（server 保留旧 `Types()` 输出结构的可加性，web 回滚即可）。

---

### 批次 3 · APP：schema 驱动的通知渠道表单

**依赖**：批次 2 已发版（或 dev 面板可用）。
**仓库**：APP
**改动**：
- 新增 `lib/core/schema/notify_field_schema.dart`（模型 + `show_when` 求值）。
- 新增 `lib/shared/widgets/schema_form.dart`（4 种 widget + required + secret）。
- `notification_list_page.dart`：`_channelFieldMap` 从「字段表」降级为 `_frozenFieldMapV300`（加禁改注释），渲染改读 schema。
- 删掉 email 的 `SwitchListTile`。

**风险**：中。核心是「未知 widget 类型」的兜底 —— 遇到不认识的 `widget` 一律降级成 `input`，**绝不隐藏字段**。
**验证**：
- 新面板：22 个渠道逐个与 Web 表单对齐截图。
- **老面板（v3.0.0）**：确认回落到冻结快照，行为与本期前完全一致。这是必测项。
- wecom 全 6 种 msg_type 各配一次并真实发送成功。

**可独立回滚**：是。

---

### 批次 4 · 面板：`/api/system/enums` 字典端点

**仓库**：面板
**改动**：§2.4。挂在 `system.go` 的 JWTAuth 组内但**不加 RequireAdmin**（viewer 也要显示任务状态）。
**风险**：低。
**验证**：`curl` 检查 `task_status` 含 `0.5`、`log_status` 含 `3`、`openapi_scope` 含 `notifications` 和 `backup`、`backup_selection` 含 `task_views`。
**可独立回滚**：是。

---

### 批次 5 · APP：枚举字典消费 + cron 模板接入

**依赖**：批次 4（cron 模板部分无依赖，面板 `/api/tasks/cron/templates` 已有 21 条）。
**仓库**：APP
**改动**：§3.1 表格中 §2.4 依赖项全部替换 + `task_form_page.dart:533-537` 改调 `ApiEndpoints.cronTemplates`（常量已存在于 `api_endpoints.dart:57`，零调用）。
**风险**：中。风险点是「服务端字典缺某个值时 UI 崩」—— 渲染必须是 `字典查表 ?? 显示原始值`，**绝不 `default: 已安装` 这种错误显示**（现状 `dependency.dart:34-49` 就是这个坏模式，比空白更危险）。
**验证**：老面板下所有列表页显示与本期前一致。
**可独立回滚**：是。

---

### 批次 6 · APP：schema 驱动的系统设置页

**依赖**：批次 1 发版（**但老面板也能跑**，见 §4.1 层 1）。
**仓库**：APP
**改动**：`system_settings_page.dart` 从 10 个硬编码控件改成按 `group` 分组、按 `order` 排序的通用渲染，**47 项全部可见可改**。
**风险**：**中高**。这是 APP 侧改动面最大的一处，且直接暴露 `captcha_key`、`backup_schedule_password` 等敏感项 —— `secret:true` 的渲染必须正确（老面板无 `secret` 字段 → 需要 APP 侧一张最小硬编码 secret key 名单作为兜底，这是**允许保留的硬编码**，只有 2 个键）。
**验证**：
- 47 项逐个改一次并回读确认落库。
- int 项越界时确认服务端 400 被正确展示（老面板无 min/max，只能靠服务端）。
- 老面板：确认 label 退化成 description 后仍可用。

**可独立回滚**：是。

---

### 批次 7 · APP：订阅鉴权字段（对齐缺口，非通用化）

订阅表单补 `auth_type / auth_username / auth_token` + SSH 密钥选择器（面板 `/ssh-keys` 5 条路由，Web 是订阅页内的子功能，**不是独立页面**）。
**风险**：低。**这批可以随时砍掉**，不影响通用化目标。

---

## 6. 三个必答问题

### a. 最可能失败的一环

**不是 APP 的动态表单，是「渠道 schema 与 `notifier.go` 再次漂移」。**

理由：schema 一旦建好，它与服务端实际读取的键之间**没有任何强制约束**。下次谁改 `notifier.go` 加一个 `cfg["retry_count"]`，schema 不会自动跟上 —— 于是「面板改了客户端跟不上」原封不动地复发，只是病灶从 APP 挪到了 `notify_channel_registry.go`。

证据是这件事**已经发生过一次**：`web/src/views/api-docs/apiData.ts:846` 的 wecom_app 消息类型漏了 `mpnews`，而 `notifier.go` 和 `index.vue:175` 都有。靠人手同步多份副本这条路已经失效过。

**唯一有效的对策是把两者用测试绑死**：

```go
// server/service/notifier_schema_binding_test.go
// 读 notifier.go 源码，提取所有 cfg["..."] 字面量，与 registry 声明的键集合断言相等。
// 差集两个方向都要报错：
//   schema 多出来的键 → 用户填了但服务端不读（假字段）
//   notifier 多出来的键 → 服务端读但用户填不了（本期要消灭的问题）
func TestNotifySchemaCoversAllConfigKeysReadByNotifier(t *testing.T) { ... }
```

用 `go/ast` 解析或直接正则读源文件都行（正则已经在本次调查里验证可行：命中 55 个唯一键）。**这个测试比整个 schema 本身更重要 —— 如果只能做一件事，做它。** 同样地，`smtp_ssl` 的 4 个兼容别名（`smtp_use_ssl/use_ssl/enable_ssl/ssl`，`notifier.go:357-370`）是青龙导入向后兼容，要在测试里显式加白名单排除。

次高风险是批次 2 的 Web 切换 —— 22 个渠道表单全换血，但它至少是**一次性的、可回滚的、有截图基线的**风险。

### b. 更简单的方案能不能拿 80%？——**能，而且应该选它的一部分**

**最简方案（我推荐先做的）= 批次 0 + 1 + 2 + 3 + 6，砍掉批次 4、5，砍掉 capabilities 端点。**

收益对照：

| 方案 | 消灭的硬编码 | 面板端成本 |
|---|---|---|
| 全量（批次 0-7） | ~22 处 | ~6 天 |
| **推荐（0/1/2/3/6）** | 渠道字段表 229 行 + 系统设置 37 项 + 备份类别 = **最痛的 3 处** | **~4 天** |
| 极简（只做 0 + 6） | 系统设置 37 项 | **0 天（面板不用改！）** |

**「极简」值得单独说**：`GET /api/configs` **在 v3.0.0 上就已经下发了完整 schema**。APP 光是把系统设置页改成 schema 驱动，就能立刻拿到 37 个新配置项、面板端一行不改、连老面板都兼容。**这是全方案里投入产出比最高的单点，应该无条件做，且不必等任何面板发版。**

**为什么不止步于极简**：通知渠道是用户实际抱怨的点（31 个键无入口、custom 渠道没表单），而它恰恰是面板端唯一必须新建结构的地方。躲不掉。

**为什么砍掉批次 4/5（枚举字典）**：8 张枚举表加起来只有 ~40 个值，且**变更频率极低** —— 任务类型自 v1.0.0 至今是 3 种，角色是 3 种，日志状态从 3 个变成 4 个用了整整 3 个大版本。为一年变一次的东西建一个端点 + 一套缓存 + 一套降级，ROI 是负的。**更好的做法：APP 保留硬编码，但把 `default:` 分支从「显示成某个已知值」改成「显示原始值」**（`dependency.dart:34-49` 现在把未知状态显示成「已安装」，`task_list_page.dart:1674-1683` 把未知类型显示成「常规定时」—— 这两个是错误显示，比空白危险）。改 `default` 分支是 20 行改动，能拿到枚举字典 80% 的安全收益。

真要做批次 4，也应该等到**面板下一次真的要加枚举值时**再做，而不是现在预防性地做。

**为什么砍掉 capabilities 端点**：见 §4.1 的三条理由。核心是**它本身就是一份手写常量数组，会成为新的漂移源**。层 1 的形状探测（`fields == null ? 快照 : schema`）已经覆盖本期所有新增能力，且零维护成本。仓库里已有的先例支持这个判断：`magisk_assets_test.go:347` 的 `TestMagiskCustomizeScriptUsesCapabilityProbeInsteadOfVersionGate` —— 团队已经确立过「能力探测优于版本闸门」的原则，而**形状探测是最轻量的能力探测**。

### c. 哪些不该通用化 —— 强行下发反而更糟

**1. 导航结构 / 页面存在与否 —— 绝对不要。**
服务端驱动 UI（下发菜单树、下发页面清单）会让 APP 变成一个渲染器，出问题时既不能在客户端修也不能在服务端修，还会让 App Store / Play 审核变复杂。面板加一个功能模块，APP 就该发一次版 —— **这是正常的，用户抱怨的不是这个**。

**2. TaskView 的 filter DSL —— 现在接就是自找麻烦。**
`web/src/api/taskView.ts:3-23` 的 `filters` / `sort_rules` 是**字符串化 JSON**，`TaskViewFilter = {field, operator, value}`，而面板**没有任何接口暴露合法的 field / operator 枚举**。现在接 = 在 APP 里再造一张硬编码表 = 把刚拆掉的 `_channelFieldMap` 复制到任务模块。要接必须先让面板出 `GET /tasks/views/schema`，那是另一期的事。

**3. 错误文案 —— 不该下发 schema，该下发错误码。**
`api_utils.dart:132-161` 现在用 `raw.contains('当前路径是目录')` 等 7 组中文子串匹配服务端原文。**正确解法不是「让面板下发错误文案表」，而是让面板在错误响应里加一个稳定的 `code` 字段。** 下发文案表只会把耦合从「文案内容」换成「文案 key」，一样脆。而且现状的降级是安全的（匹配不上就展示服务端原文，不丢数据），优先级可以很低。

**4. 镜像源预设列表 —— 面板端也没有真源，不要为了下发而先在面板里造一份硬编码。**
`system_settings_page.dart:41-55` 的 10 条 + `dep_list_page.dart:652-680` 的 11 条，面板 `service/dependency_mirrors.go` 只有 2 个默认值常量、`handler/deps.go:598-619` 的 `GetMirrors` 不回预设列表。**在面板里新写一张预设表 = 把 APP 的硬编码搬到面板，硬编码总数不变，还多了一个接口。** 正确做法是让用户能自己存预设（改成一个配置项），或者干脆接受它。

**5. Cron 表达式的合法性规则 —— 下发规则不如直接调接口。**
面板有 `POST /api/tasks/cron/parse`（`task_cron.go:12-47`，返回校验结果 + 未来 5 次执行时间）。**调它**，不要下发一套 cron 语法规则让 APP 本地校验。同理，任何「服务端能算的东西」都不要下发算法。

**6. `platform-tokens` —— 别接。**
面板注册了 9 条路由（`platform_token.go:171-184`），但**面板自己的 Web 前端没有页面**（`web/src/api/system.ts:120` 定义了 API，全仓无 view 引用）。给一个未定型的半成品做客户端，面板后续改动会直接打脸。

**7. 渠道图标 —— 可以下发语义名，但别期待收益。**
下发 `"icon": "telegram"` 之后，APP 仍然需要一张 `{"telegram": Icons.telegram_outlined}` 的本地映射（Flutter 图标是编译期常量）。面板加新渠道时图标仍然回落默认值。**成本近似为零所以顺手带上，但不要把它算进收益。**

---

## 7. 前提纠正

调查报告与背景事实中的错误，已实读核对：

1. **路径**：不是 `lib/core/constants/api_endpoints.dart`，实际是 `lib/core/network/api_endpoints.dart`（`core/constants/` 目录不存在，已确认）。
2. **`_channelFieldMap` 是 229 行**（`notification_list_page.dart:385-613`，首尾含入），背景事实**准确**。第五路调查报告的「223 行 / 385-607」**错误**，:607-613 仍在表内（wxpusher 的 topic_ids）。
3. **配置项是 47 个**（`system_config_registry.go:49-171` 逐条数）。报告中的「46 个」「38 个唯一键」均**错误**。
4. **APP 写回 10 个配置键**（`system_settings_page.dart:507-516`），不是 9 个。
5. **渠道字段缺口的准确口径**：APP `_channelFieldMap` = 21 渠道 / **44 字段槽** / **24 唯一键**；Web `configFields` = 22 渠道 / **91 字段槽** / **56 唯一键**；`notifier.go` = **55 唯一 `cfg["..."]` 键**（+ `smtp_ssl` 走别名循环）。**APP 缺 31 个唯一键、47 个字段槽。** 报告中的「39 / 44 / 31」是不同口径，本文统一用上述三个数。
6. **APP 的 24 个键 100% 是服务端认识的键**，「APP 有、面板没有」为空集 —— 问题是单向的，这让 schema 下发方案更简单（不存在需要向后兼容的 APP 私有字段）。
7. **`Web configFields` 的 56 个唯一键 = notifier 的 55 + smtp_ssl，是精确镜像**（本次实测比对）。这是「移植 ≈ 翻译，不是重新分析」这个成本判断的直接依据。
8. **背景事实说「Web 端做对了」是错的** —— Web 有完全相同的病（`index.vue:95-319`）。根因在服务端从未持有这份知识。所以不是 APP 追赶 Web，是两个客户端向一个**尚不存在**的服务端 schema 收敛。
9. **`task_form_page` 读 `default_version` 不是可推广的样板**。它来自 `handler/deps.go` 的 `PythonRuntimes` 这个 ad-hoc 端点，不走 SystemConfig registry。把它当样板会推导出「每个功能各写一个 meta 端点」的碎片化方案。
10. **`/auth/captcha-config` 那处降级防的是一个不存在的版本**：该端点自 Go 服务端第一个提交 `61cea9b`（v1.0.0）就存在。「唯一显式标注的兼容处理」这个说法成立，但它是空转的。真正存在过的端点缺口（`/deps/python-runtimes` v2.2.2 无、v2.2.20 起有）反而只有一个裸 `catch(_)`（`dep_list_page.dart:216`）。
11. **`/api/configs` 返回的是 map 不是 list**（`config.go:88-106`），**没有顺序** —— 这是 §2.1 必须加 `Order` 的原因，报告里没提。
12. **`SystemConfigDefinition` 的 min/max 已经存在，只是被闭包吃掉了**（`:250-275` 的 `newIntConfig`，10 处调用都传了）。暴露它是 4 行改动，不是新增知识。
13. **`/api/system/panel-settings`（`system.go:684`，免鉴权）已经是一个「手工挑 8 个配置项 expose 出去」的端点**（`:387-408`）—— 它是本文要消灭的模式的活标本，同时也证明「下发配置」这件事面板已经在做，只是做成了硬编码子集。