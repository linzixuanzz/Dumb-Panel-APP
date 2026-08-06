# 五路调查对 brief 的前提更正

## APP 里硬编码「面板知识」的穷尽式清单  (22 条发现)

- 路径写错了：不是 `lib/core/constants/api_endpoints.dart`，实际是 `lib/core/network/api_endpoints.dart`（193 行）。APP 的 lib 下没有 `core/constants/` 目录。
- `_channelFieldMap` 的 229 行完全属实，确认在 notification_list_page.dart:385-613，正好 229 行。「面板支持而这张表没有的键（telegram proxy、wecom 图文卡片等）」也属实，实测缺 39 个键。但补一句：它不在 `constants/`，而且同 feature 下还有个 `notifications/utils/channel_config.dart`（58 行），那里放的是第 0 期抽出来的合并逻辑，不含字段表。
- 「task_form_page 已改成读 default_version，是正确做法的既有样板」属实（task_form_page.dart:224-277，:249-252 读 map['default_version']）。但要补充：'3.12' 作为兜底仍硬编码在 4 处（task.dart:43、task.dart:132、task_form_page.dart:86-87、task_form_page.dart:252），且 :386-390 的运行时列表兜底仍写死 3.10/3.11/3.12。这个样板只解决了「新建任务的默认值」，没解决「可选版本列表」。
- 「captcha-config 是目前唯一的版本兼容处理」属实。全库 grep validateStatus 共 9 个文件命中，其中真正放宽的只有 auth_service.dart:99（<500）；dio_client.dart:20,71 是全局收紧到 <400，app_update_service.dart:65 是 APP 自更新查 GitHub 用的独立 Dio，不算面板兼容。
- 补充一条背景里没提、但对本期方案影响很大的事实：Task/Subscription/NotifyChannel/EnvVar/Dependency 五个 model 的 `toJson()` 全部是死代码，从未被调用（全库 `.toJson()` 只有 5 处调用，都是本地存储和备份 selection）。真实请求体是各页面里的内联 Map 字面量。也就是说每个实体在 APP 里有两份字段清单，且 subscription 的两份已经不一致（model 含 auto_add_task/ssh_key_id，实际请求体不含）。任何「让 APP 通用化跟随面板」的方案，都要先处理这个双份定义，否则改了没效果的坑会一直存在。

## 面板端已有的元数据下发能力（server/ + web/ 实证）  (13 条发现)

- 【重要纠正】背景事实把 229 行 `_channelFieldMap` 描述成 APP 端的问题，暗示 Web 端做对了。实际上 **Web 端有完全相同的病**：web/src/views/notifications/index.vue:95-319 是一张 225 行的硬编码 `configFields`，结构与 APP 那张表几乎一一对应。根因不在 APP，而在服务端从未持有这份知识（handler/notification.go:220-246 只给 type+name）。所以这不是 APP 要「补齐到 Web 的水平」，而是两个客户端都要向一个尚不存在的服务端 schema 收敛。
- 【重要纠正】提问设想的二选一「后端已有配置定义 → APP 直接复用是最短路径 / 后端没有 → 得先建」，两边都不完全对。真实情况是**分裂的**：系统配置侧后端**已有**结构化定义并已下发（system_config_registry.go:30-37 + handler/config.go:47-107，且有回归测试锁契约），通知渠道侧后端**完全没有**。同一期里两条路径的工作量差一个数量级，必须分开估算。
- 【重要纠正】背景把 task_form_page 读 `default_version` 称为「正确做法的既有样板」。查证后：该字段来自 server/handler/deps.go:558-563 `PythonRuntimes`，是为 Python 运行时单独写的**一次性 ad-hoc 端点**（返回 `data` + `default_version`），它并不走 SystemConfig registry（虽然底层键是 registry 里的 `python_default_version`，见 deps.go:582）。它是「某个功能顺手下发了自己的默认值」，不是可推广的通用机制——把它当样板会推导出「每个功能各写一个 meta 端点」的碎片化方案。
- 【补充纠正】背景称 `/auth/captcha-config` 的 404 降级是 APP **唯一**的版本兼容处理，且暗示这是纯客户端猜测。实际上服务端在该端点**主动下发了一个能力标志**：server/handler/auth.go:327 硬编码 `"implemented": true`，Web 侧还留有对应的历史门控常量（useSettingsConfig.ts:83-84 及其注释「此开关原为功能上线门控」）。也就是说面板已经有一次「下发能力位」的实践，只是做成了一次性的、且该端点免鉴权（auth.go:470 未挂 JWTAuth）——这反而是把它推广成统一 capabilities 机制的有利先例。
- 【补充】提问问「面板 Web 端的设置页是前端硬编码还是后端下发」，明确答案是：**后端下发了，前端不用**。server 侧 GET /configs 完整下发 default_value/value_type/group/options/description/registered（handler/config.go:47-77），但 web/src/views/settings/useSettingsConfig.ts:88-130 与 :158-200 硬编码了 41 个键的表单形状和取值，label/控件写死在 SystemConfigCard.vue。唯一真正消费服务端元数据的地方是 :134 的 `entry?.value ?? entry?.default_value` 兜底。可证伪的后果：47 个已注册配置中 panel_runtime_mode / panel_service_manager / panel_service_name 三项在 Web 端完全无 UI。

## 通知渠道链路两端逐字对照（APP _channelFieldMap ↔ 面板服务端 notifier.go ↔ 面板 Web configFields）  (9 条发现)

- 背景事实「229 行的 _channelFieldMap」**完全准确**——notification_list_page.dart:385-613，首尾含入正好 229 行。
- 背景事实「第 0 期已经修了『不丢未知字段』」**准确**——channel_config.dart:33-43 以 existingConfig 为基底合并，未知键保留；且 keepExistingConfig 的语义（换了类型就整份作废）与 Web 的 onChannelTypeChange（index.vue:366-369 清空 configData）一致。Web 侧也保留未知键（index.vue:329 JSON.parse 整份读入 → L324 整份写回）。
- **需要纠正的措辞**：「面板支持而这张表没有的键（telegram proxy、wecom 图文卡片等）」——这个「等」字掩盖了量级。实测缺 44 个字段槽，telegram proxy 只是其中 1 个，wecom_app 单渠道就缺 13 个（base_url / to_party / to_tag / msg_type / content_template / media_id / news_articles / mpnews_articles / template_card_payload / safe / enable_id_trans / enable_duplicate_check / duplicate_check_interval），custom 渠道在 APP 上压根没有表单。
- **需要纠正的判断优先级**：「保存即丢失」已经不是最严重的问题了（而且已修）。现在最严重的是反向的——APP 在 email 渠道上**主动写入了一个服务端读不了的值**（bool 型 smtp_ssl），不是丢数据而是投毒，后果是整个渠道停止工作，且 Web 端也修不回来。这条与「面板会不会改」无关，现在就是坏的，应该独立于本期通用化方案先修。
- **需要纠正的隐含预期**：调查前可能预期存在「APP 显示了一个面板不认的字段」这一类问题——实测**为空集**，APP 的 45 个键 100% 都被 notifier.go 读取。所以三张表里有一张是空的，问题是单向的（APP 落后于面板），这反而让 schema 下发方案更简单：不存在需要向后兼容的 APP 私有字段。
- **需要纠正/明确的关键前提**：不能说「服务端已经有结构，expose 即可」。服务端**没有**任何声明式的渠道字段结构——notifier.go 里是 23 个 send 函数中散落的 `cfg["key"]` 字符串字面量。唯一的声明式字段表在 web/src/views/notifications/index.vue:95-319（TypeScript）。但也不能说「要从零结构化」——那 225 行 TS 与 Go 的读取集逐条比对后完全一致，移植≈翻译，不是重新分析。准确表述是：**结构已经存在，只是长在了错误的仓库和错误的语言里**；把它搬到 server/model 下，并补齐 required、条件显隐、默认值这三块只活在 Go 函数体里的知识。
- **面板 Web 渲染器已经是通用的**这一点值得单独强调，因为它改变了方案的风险评估：index.vue:795-819 就是一段 `v-for field in configFields` 的通用渲染，四种控件分派。也就是说这套 schema 的表达能力已经被 Web 端实战验证过一遍了，不是新设计。APP 侧的工作是把渲染器补到同等能力（加 textarea + select），而不是发明新协议。

## 版本协商与向后兼容（新 APP × 老面板）  (10 条发现)

- 路径写错了：集中管理端点的文件在 `D:\GitHub\Dumb Panel\android-app\lib\core\network\api_endpoints.dart`，不是 `lib/core/constants/api_endpoints.dart`（该路径不存在）。
- `app_update_service.dart` 确认是 **APP 自身**的更新，与面板版本完全无关：:12 `const _kGitHubRepo = 'linzixuanzz/Dumb-Panel-APP'`，:73-74 请求 `https://api.github.com/repos/$_kGitHubRepo/releases/latest`，:100 拿 `AppUserAgent.versionLabel` 做本地版本，:117-131 `_isNewer` 比的是 APK 语义版本。你提醒要区分这两件事是对的 —— 它不含任何面板版本逻辑。面板自身的更新检查是另一条完全独立的链路：APP 调 `/api/system/check-update`（api_endpoints.dart:22 → system_settings_page.dart:163），由面板服务端去查 GitHub（server/handler/system.go:410-460）。
- 「只有 /auth/captcha-config 一处版本兼容处理」需要两点修正。(a) 作为「唯一**显式标注**为老面板兼容的降级」，说法成立。(b) 但该处防的版本不存在：`/auth/captcha-config` 自 Go 服务端第一个提交 61cea9b（Initial commit: 呆呆面板 v1.0.0, 2026-03-13）起就已注册（server/handler/auth.go:470），`git log -S 'captcha-config' --all -- server/handler/` 只有这一条提交记录。(c) 另有 4 处**事实上**在吸收老面板 404 但没标注：dashboard_provider.dart:83-90 `_optional`、notification_list_page.dart:119-136 `_fetchTypes` + :37-49 `_fallbackTypes`、dep_list_page.dart:216、env_list_page.dart:141。其中 dep_list_page 那处对应的是**真实存在过的**端点缺口（`/deps/python-runtimes` 在 v2.2.2 无、v2.2.20 起才有）。
- 「API 有没有版本前缀」不是二选一：`/api` 与 `/api/v1` **同时存在且全等**。router.go:14-15 建两个 group，:35-84 共 17 组 handler 逐个 `RegisterRoutes(v1)` + `RegisterRoutes(legacy)` 双注册；这个双挂载自 61cea9b（v1.0.0）就有（当时 15 组）。所以路径前缀既不是新旧标志，也不能用于协商。
- 补充一条你没问但影响结论的事实：`ApiEndpoints.version`（api_endpoints.dart:17 = `/api/v1/version`）**声明后从未被引用**（全仓 grep `ApiEndpoints.version` 零命中）。也就是说 APP 从未调用过任何会返回 `api_version` 字段的接口 —— APP 唯一接触到的面板版本来自 `/api/system/version`（api_endpoints.dart:21），且只取其中的 `version` 字符串用于显示。
- 另需修正一个可能的隐含假设：并非「面板一律没有能力描述能力」。`/api/configs` 已经是一个完整的自描述 schema 端点（server/handler/config.go:62-74 输出 value_type / options / default_value / group / description，来源 server/model/system_config_registry.go:30-37 的 `SystemConfigDefinition`）。缺的是 APP 侧的消费，以及把这个模式推广到「端点/渠道字段」维度。

## 面板有、APP 没有的功能（路由级对齐差距）  (11 条发现)

- `_channelFieldMap` 是 **223 行**不是 229 行，范围 lib/features/notifications/views/notification_list_page.dart:385-607，覆盖 21 个渠道。面板 /notifications/types 声明 22 个（notification.go:221-244），第 22 个是 `custom`，APP 走原始 JSON 编辑框（channel_config.dart:57-88）。所以**渠道数几乎不缺**，缺的是字段：面板 notifier.go 读 55 个 config key，APP 表只渲染 24 个，31 个键没有表单入口。用「229 行硬编码表」描述问题会低估真实缺口。
- `PUT /envs/by-name` 不该进优先级列表。它是 env.go:1185-1187 注释明写的青龙兼容/脚本 upsert 端点（「POST /envs 保持纯 insert，需要按名字 upsert 的脚本走这里」），面板自己的 Web 前端也完全不用（grep web/src 对 `by-name` 零命中）。APP 接它的用户价值 ≈ 0。
- SSH 密钥在面板**没有独立页面**，它是订阅页里的子功能（web/src/api/notification.ts:39-55 定义在 notification.ts 里，被 web/src/views/subscriptions/index.vue:4 引入，:1354 是订阅表单里的下拉）。所以 APP 该做的不是「SSH 密钥管理页」，而是「订阅表单补齐 auth_type / ssh_key_id / auth_username / auth_token 四个字段 + 一个密钥选择器」。按「SSH 密钥模块」立项会做出面板都没有的页面。
- api_endpoints.dart **不是** APP 的完整端点清单。system_settings_page.dart:269、353、423 三处用 `'${ApiEndpoints.baseApi}/system/update-status'` 这类插值直接拼路径，绕过了常量表。所以「集中管理路径」这个既有优势已经有裂口。
- 面板端**不需要为配置项通用化新增任何接口**。`GET /api/configs` 已经是自描述的：config.go:47-77 返回 value_type（string/int/bool/enum，registry:16-23）、group、options（含 value/label）、default_value、description、registered。「面板可以改」这个授权在配置维度上用不上——纯 APP 侧改造。这跟通知渠道恰好相反（那边面板必须扩接口）。
- 候选清单里「原始日志下载」实际是**四条路由两套机制**：/logs/:id/raw-ticket + /logs/:id/raw（DB 日志，log.go:269,272）和 /tasks/:id/log-files/:filename/raw-ticket + .../raw（文件日志，task_routes.go:13,24）。前者对应 APP 已有的日志详情页，后者对应 APP 完全没有的历史日志文件浏览。按一件事估工作量会低估一半。