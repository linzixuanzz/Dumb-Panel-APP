# agent-5

## summary

issue #2 是两个独立缺陷叠加，缺一不可。缺陷 A（仍未修）：`resolveLogSurfaceTheme()` 的兜底底色写死成 `AppColors.termBg = Colors.white`，函数拿不到任何主题信息，所以面板 `log_background_color` 留空（面板 v2.2.4 起的出厂默认就是留空）时，APP 无论明暗一律给白底——这正是「深色模式下日志背景是白的」。`AppColors.termBgDark = #000000` 定义了却全仓零引用，说明作者本来打算按主题分叉但没接上。缺陷 B（已在 v1.3.0 修掉）：APP v1.2.6 的系统设置页里那个标着「日志背景色」的输入框，绑的键是 `editor_background_color` 而不是 `log_background_color`——用户填的 #000000 写进了脚本编辑器背景，日志侧当然纹丝不动，这正是「就算设 #000000 也是白的」。APP 共 7 个日志展示面，全部正确读取 `log_background_color`，没有一个漏接、也没有 Card/Material 盖掉配置色；问题只在兜底值这一处。结论：v1.3.3 里 B 已随「系统设置改为 schema 驱动」（64ddf75，v1.3.0）自然修好，A 依然原样存在，log_background.dart 自 v1.2.6 到 v1.3.3 一个字节没变。

## currentState

**数据链路**：面板 `GET /api/system/panel-settings`（`server/handler/system.go:414-440`，注册在 JWTAuth 之外的公开组 `server/handler/system.go:764-765`，路由树 `server/router/router.go:15` 的 `/api` 组无任何中间件）下发 `log_background_color`。该键自面板 v1.8.0 起就在这个接口里（`git log -S logBackgroundColor -- server/handler/system.go` 只有一条 `2b31003 release: v1.8.0`），v2.3.8 实测存在（`git show v2.3.8:server/handler/system.go`）。注册表默认值在 v2.2.4 起是**空串**（`server/model/system_config_registry.go:179`，v2.3.8 同）。`GetRegisteredConfig → GetConfig` 直读 DB、无缓存（`server/model/system_config.go:34-49`），`SetConfig` 只做 trim 归一（`server/model/system_config.go:80-105`）。所以「用户设了值 → 接口返回不了」这条路不成立，APP 侧接口取得到、字段名一致、不需要鉴权。

**缺陷 A 的根因（未修）**：`lib/shared/utils/log_background.dart:84-95`

```dart
LogSurfaceTheme resolveLogSurfaceTheme(Color? configuredColor) {
  final background = configuredColor ?? AppColors.termBg;   // ← 这一行
  final brightness = ThemeData.estimateBrightnessForColor(background);
  ...
}
```

`AppColors.termBg = Colors.white`（`lib/core/theme/app_theme.dart:74`）。函数签名里没有 `BuildContext`/`Brightness`，**物理上不可能知道当前是不是深色模式**。于是 `configuredColor == null`（= 面板留空）时恒定白底，前景色再由 `estimateBrightnessForColor(white)` 推成 `slate900` 深字——白底深字，在深色模式下就是用户截图里那块刺眼的白。

对照面板 Web：`web/src/utils/panelAppearance.ts:204` 是 `effective?.log_background_color?.trim() || getDefaultLogBackgroundColor(isDark)`，`isDark` 来自 `document.documentElement.classList.contains('dark')`，深色回落 `#0f172a`、浅色回落 `#f8fafc`（`panelAppearance.ts:33-34, 120-122`；v2.3.8 逐字相同）。**即「留空跟随当前主题」这个契约只有 Web 实现了，APP 是唯一没实现的客户端**，而面板设置页的 hint 明写「留空时浅色模式为浅底深字，深色模式为深底浅字」（`web/src/views/settings/components/SystemConfigCard.vue` 日志背景颜色那一段）。

**缺陷 B 的根因（v1.3.0 已修）**：APP v1.2.6 的 `lib/features/system/views/system_settings_page.dart` 里，「面板外观」区只有一个颜色输入框：

- `:832` `label: '日志背景色'`，`controller: _editorBackgroundColorC`
- `:104` 读的是 `editor_background_color`
- `:509` 回写的是 `'editor_background_color': _editorBackgroundColorC.text.trim()`

整个文件 grep 不到 `log_background_color`。用户在 APP 里按这个标签填 `#000000`，落库的是 `editor_background_color`；日志侧读的 `log_background_color` 仍是空串 → 继续走 `?? termBg` → 继续白。这个错绑在仓库自己的设计文档里被记录过：`.trellis/tasks/archive/2026-08/08-06-app-v2-phase2-generic/research/design.md:410`「`system_settings_page.dart:833` label 改「脚本编辑器背景色」（或改绑到 `log_background_color`，二选一）」。

**旁证**：如果用户面板是 v1.8.0~v2.2.3 血统的老库，`log_background_color` 会残留旧默认 `#0f172a`（见 `docs/release-notes/v3.0.10.md:57-63`），APP 反而会显示深色。用户看到的是白 ⇒ 他库里这一行是**空串** ⇒ 他那次 `#000000` 确实没写进 `log_background_color`，与缺陷 B 完全自洽。

## keyFiles

- `D:\GitHub\Dumb Panel\android-app\lib\shared\utils\log_background.dart` :84-95 — 根因所在。resolveLogSurfaceTheme 的兜底 `configuredColor ?? AppColors.termBg` 写死白色，函数无 context/brightness 入参。文件自 v1.2.6 到 v1.3.3 逐字节未变（git show v1.2.6:… 对比确认）
- `D:\GitHub\Dumb Panel\android-app\lib\core\theme\app_theme.dart` :74-75 — termBg = Colors.white；termBgDark = Color(0xFF000000) 全仓零引用（grep termBgDark 只命中定义本身），是「本想按主题分叉但没接上」的死证据
- `D:\GitHub\Dumb Panel\android-app\lib\app.dart` :14-21 — themeMode: ThemeMode.system，无 App 内主题开关，所以 Theme.of(context).brightness 就是「深色模式」的唯一判据
- `D:\GitHub\Dumb Panel\android-app\lib\features\logs\views\log_stream_page.dart` :55-61, 292, 298, 306, 378-379, 402-409 — 日志展示面 1/7：日志详情+实时流。Scaffold.backgroundColor / AppBar / body Container 全用 logTheme.background，无分层错位
- `D:\GitHub\Dumb Panel\android-app\lib\features\tasks\views\task_list_page.dart` :2799-2805, 3002, 3008, 3011, 3065-3066, 3091-3100 — 日志展示面 2/7：_TaskLiveLogPage「运行日志」。同样全用 logTheme，无错位
- `D:\GitHub\Dumb Panel\android-app\lib\features\scripts\views\script_list_page.dart` :2589-2600, 2713, 2781-2786, 2806-2815 — 日志展示面 3/7：_ScriptDebugRunSheet 脚本调试输出。外层 showModalBottomSheet 用主题 surface、内层 AppCard 用 logTheme.background —— 深色模式下就是「白卡浮在深色 sheet 上」，但成因仍是兜底值而非层级写错
- `D:\GitHub\Dumb Panel\android-app\lib\features\scripts\views\script_list_page.dart` :1899-1962 — 编辑器外观走的是另一个键 editor_background_color，并私有复制了一份与 parseColorSetting 逐字相同的 _parseColorSetting（重复实现，与本 bug 无关但值得合并）
- `D:\GitHub\Dumb Panel\android-app\lib\features\system\views\panel_log_page.dart` :54, 73, 97, 176-184, 202 — 日志展示面 4/7：面板日志。页面 Scaffold 走主题 surface，只有 AppCard 走 logTheme.background —— 代码注释（:181-182）写明这是刻意的
- `D:\GitHub\Dumb Panel\android-app\lib\features\subscriptions\views\subscription_list_page.dart` :1604-1613, 1641-1690 — 日志展示面 5/7：订阅日志详情弹窗（AppCard 传 color: logTheme.background）。注意 :1610 给 _logBackgroundColor 赋值时没有 setState，靠随后 _load() 的 setState 兜住
- `D:\GitHub\Dumb Panel\android-app\lib\features\subscriptions\views\subscription_list_page.dart` :1918-1928, 1985, 1991, 1994, 1997-1998, 2015-2023 — 日志展示面 6/7：订阅「拉取日志」SSE 流页，全用 logTheme
- `D:\GitHub\Dumb Panel\android-app\lib\features\deps\views\dep_list_page.dart` :1586-1596, 1640, 1646, 1649, 1652-1653, 1663-1671 — 日志展示面 7/7：依赖「安装日志」SSE 流页，全用 logTheme
- `D:\GitHub\Dumb Panel\android-app\lib\shared\widgets\app_card.dart` :76-88 — AppCard 的 decoration 是 `color: color ?? surfaces.card`，显式传入的 logTheme.background 会生效，不存在「Card/Material 盖掉配置色」
- `D:\GitHub\Dumb Panel\android-app\lib\shared\utils\ansi_text.dart` :69-102 — ANSI 调色板明暗两支的 defaultBackground 都是 Colors.transparent，不会在 span 上刷底色盖掉配置色
- `D:\GitHub\Dumb Panel\android-app\lib\features\system\views\system_settings_page.dart` :19, 130-165 — v1.3.3 现状：设置页完全由 GET /api/configs 的 schema 驱动，log_background_color 作为 branding 组的注册项会被正常渲染与回写；缺陷 B 已消失
- `D:\GitHub\Dumb Panel\android-app\lib\features\system\utils\system_config_schema.dart` :113-121, 138-142, 185-221 — 老面板（如 2.3.8，注册表尚无 Label 字段）时，label 由 description 截断推导 → 「日志视图背景颜色」，不会退化成英文 key
- `D:\GitHub\呆呆面板开发\server\handler\system.go` :414-440, 763-765 — PanelSettings 下发 log_background_color；路由挂在 JWTAuth 之外的公开组。APP 取得到、字段名一致、不需要鉴权
- `D:\GitHub\呆呆面板开发\server\model\system_config_registry.go` :179 — log_background_color 注册默认值 = 空串（「留空跟随当前主题」）。v2.3.8 逐字相同
- `D:\GitHub\呆呆面板开发\server\model\system_config.go` :34-49, 80-105, 142-147 — GetConfig 直读 DB 无缓存；SetConfig 只 trim；:142-147 是 v3.0.10 补的老库 #0f172a→空串一次性迁移
- `D:\GitHub\呆呆面板开发\web\src\utils\panelAppearance.ts` :33-34, 120-122, 204, 208 — 面板 Web 的正确参考实现：留空时按 isDark 回落 #0f172a / #f8fafc，文字色 #e2e8f0 / #111827。APP 应对齐这四个常量
- `D:\GitHub\呆呆面板开发\docs\release-notes\v3.0.10.md` :51-83 — 面板侧同族 bug（issue #104）的完整取证：老库残留 #0f172a、颜色选择器只预览不落库需点「保存配置」。判断用户 DB 当前是空串的旁证来源

## detailedFindings

## 1. `log_background.dart` 三个函数的全部调用点

`Grep loadPanelLogBackgroundColor|parseColorSetting|resolveLogSurfaceTheme` 全仓结果（lib 内）：

| 函数 | 调用点 | 怎么用返回值 |
|---|---|---|
| `loadPanelLogBackgroundColor()` | `log_stream_page.dart:56` | `_loadAppearance()` 里 `setState(() => _logBackgroundColor = color)` |
| | `task_list_page.dart:2800` | 同上，`_TaskLiveLogPageState._loadAppearance()` |
| | `script_list_page.dart:2593` | `_ScriptDebugRunSheetState.initState` 的 `Future.microtask` 内 setState |
| | `panel_log_page.dart:54` | 在 `_load()` 里与日志正文**同一个 try** 内 await，赋值走 `:73` 的 setState |
| | `subscription_list_page.dart:1610` | `initState` microtask 内**裸赋值、无 setState**，靠紧随其后的 `_load()` setState 触发重建 |
| | `subscription_list_page.dart:1924` | microtask + setState |
| | `dep_list_page.dart:1592` | microtask + setState |
| `parseColorSetting()` | 只有 `log_background.dart:31` 自己调 | 解析 `data['log_background_color']` |
| `resolveLogSurfaceTheme()` | `log_stream_page.dart:292`、`task_list_page.dart:3002`、`script_list_page.dart:2713`、`panel_log_page.dart:97`、`subscription_list_page.dart:1642`、`subscription_list_page.dart:1985`、`dep_list_page.dart:1640` | 一律在 `build()`（或 `_showLogDetail()`）开头调一次，产出的 `logTheme.background/foreground/mutedForeground/brightness` 铺满该屏 |

**七个调用点全部传 `_logBackgroundColor`，没有任何一处传死值或漏传。** 另外 `script_list_page.dart:1917-1962` 有一份与 `parseColorSetting` **逐字相同**的私有副本 `_parseColorSetting`，服务于另一个键 `editor_background_color`（`:1901-1911`），与本 bug 无关。

`loadPanelLogBackgroundColor()` 每个页面各自发一次 HTTP，无任何缓存——7 个面就是 7 次独立请求，属可优化项。

## 2. 一共 7 个日志展示面，逐个确认背景色来源

以 `AnsiTextParser.buildTextSpan` 的调用点为准（这是 APP 里渲染日志正文的唯一入口），共 7 处，与 `.trellis/tasks/archive/2026-08/08-06-app-v2-phase1-flatten/research/premise-corrections.md:49` 当初核过的「七个消费者」一致：

| # | 面 | 文件:行 | 背景色来源 | 结论 |
|---|---|---|---|---|
| 1 | 日志详情 / 实时日志流 | `log_stream_page.dart:298/306/379` | `logTheme.background`（Scaffold + AppBar + body Container 三层同色） | ✅ 接了配置 |
| 2 | 任务运行日志（`_TaskLiveLogPage`） | `task_list_page.dart:3008/3011/3066` | 同上三层 | ✅ |
| 3 | 脚本调试输出 | `script_list_page.dart:2786` | 内层 `AppCard(color: logTheme.background)`，外层 bottom sheet 用主题 surface | ✅（分层见下） |
| 4 | 面板系统日志 | `panel_log_page.dart:183` | `AppCard(color: logTheme.background)`，页面 Scaffold 用主题 surface | ✅（刻意，见 `:181-182` 注释） |
| 5 | 订阅日志详情弹窗 | `subscription_list_page.dart:1669` | `AppCard(color: logTheme.background)`，外层 bottom sheet 主题 surface | ✅ |
| 6 | 订阅拉取日志（SSE） | `subscription_list_page.dart:1991/1994/1998` | Scaffold + AppBar + Container 三层 | ✅ |
| 7 | 依赖安装日志（SSE） | `dep_list_page.dart:1646/1649/1653` | Scaffold + AppBar + Container 三层 | ✅ |

**没有任何一个面漏接 `log_background_color`。** `log_list_page.dart`（执行日志列表）不渲染日志正文，只做列表与筛选，点进去走 #1，因此不需要接。

## 3. 分层错位与覆盖：查了，都不是病根

- **Card/Material/DecoratedBox 覆盖**：`AppCard` 的 decoration 是 `color: color ?? surfaces.card`（`app_card.dart:80`），显式传入的 `logTheme.background` 一定生效；交互分支的 `Material` 是 `MaterialType.transparency`（`:119-120`），不会盖底。**排除。**
- **ANSI span 刷底色**：明暗两支 `defaultBackground` 都是 `Colors.transparent`（`ansi_text.dart:76` / `:102`），`toTextStyle` 里 transparent 直接映射成 `null`（`:219`）。**排除。**
- **真实存在的分层现象**：#3、#4、#5 三处是「外层容器主题色 + 内层 AppCard 用 termBg」。深色模式下配置留空时，外层是 slate950 深色、内层 AppCard 是纯白 —— 视觉上就是一块白色卡片浮在深色页面上，观感最刺眼。但这不是层级写错，**内层拿到白色本身才是错**；把兜底改对，三处同时自愈。

## 4. 面板侧 `log_background_color` 的取值与默认值：APP 端能取到，不需要鉴权

- 注册：`server/model/system_config_registry.go:179` → `newTrimmedStringConfig("log_background_color", …, "", "日志视图背景颜色（留空跟随当前主题）", "branding")`，**默认空串**，v2.3.8 逐字相同。
- 取值范围：无枚举校验，`SetConfig` 只做 trim（`system_config.go:80-105` → `NormalizeSystemConfigValue`）。Web 端用 `<el-color-picker show-alpha>` + `<el-input>` 双控件（`SystemConfigCard.vue:91-92`），因此库里既可能是 `#rrggbb` 也可能是 `rgba(r, g, b, a)` —— APP 的 `parseColorSetting` 两种都能解（`log_background.dart:43-79`，`#000000` → `Color(0xFF000000)`，`rgba(0, 0, 0, 1)` 命中 `:59-62` 的正则）。
- 下发：`server/handler/system.go:432`，路由 `:765` 注册在 `JWTAuth` 之外（`:767` 才开始 `sys := r.Group("/system", middleware.JWTAuth())`），`/api` 组本身只挂 CORS + SecurityHeaders（`server/router/router.go:11-15`）。`response.Success` 就是 `c.JSON(200, data)`（`server/pkg/response/response.go:9-11`），body 形如 `{"data":{…}}`，APP 的 `extractData`（`api_utils.dart:5-11`）正好剥一层。
- **所以「APP 端接口取不到 / 需要鉴权 / 字段名不同 / 在另一个 settings 接口里」四种猜测全部不成立。** 也不存在服务端缓存（`GetConfig` 每次直查 DB）。
- 唯一的**取值口径差异**在客户端：Web 留空回落 `#0f172a` / `#f8fafc`（`panelAppearance.ts:120-122`），APP 留空回落 `Colors.white`。

## 5. v1.3.3 修好了吗：**修了一半**

**缺陷 B —— 已修，v1.3.0。**
- v1.2.6 `system_settings_page.dart:832` 的输入框 `label: '日志背景色'`，controller 是 `_editorBackgroundColorC`；读 `:104` `'editor_background_color'`，写 `:509` `'editor_background_color': _editorBackgroundColorC.text.trim()`。该文件在 v1.2.6 里 grep 不到 `log_background_color`。**用户在 APP 里填的 #000000 进的是脚本编辑器背景。**
- 修它的提交：`64ddf75 feat(app): 系统设置改为 schema 驱动，可配置项从 10 项变 47 项`（2026-08-07）。`git tag --contains 64ddf75` → `v1.3.0 v1.3.1 v1.3.2 v1.3.3`。`git show v1.3.0:…/system_settings_page.dart | Select-String "editor_background_color|日志背景"` 无输出，硬编码字段已整体删除。
- 现在的行为：设置页从 `GET /api/configs` 拉 schema，`log_background_color` 作为 branding 组注册项被渲染；面板 2.3.8 不下发 `label` 字段时，标题由 description 截断推出「日志视图背景颜色」（`system_config_schema.dart:185-221`），不会显示成英文 key，也不会再和编辑器背景撞名。

**缺陷 A —— 未修，v1.3.3 依旧。**
- `git diff v1.2.6..HEAD -- lib/shared/utils/log_background.dart` → **无输出**（该路径不在 diff --stat 结果里）；`git show v1.2.6:lib/shared/utils/log_background.dart` 与当前文件逐字相同，`?? AppColors.termBg` 原样在 `:85`。
- `git log --oneline -S termBgDark --all` 只有两条：`6e76fa7`（初始导入，定义它）与 `f2aab6c`（一次布局提交，只在 research/*.md 里提到它）。**termBgDark 从被定义那天起就没被任何代码用过。**
- `git log --oneline -- lib/shared/utils/log_background.dart` 只有 `68b7e2c Fix log theme contrast handling across app logs`（2026-05-17）与 `61b8675`（v1.0.9）；`git tag --contains 68b7e2c` 显示它早在 v1.0.9 就进去了，即那次「修对比度」改的是**前景色**，没碰兜底底色。
- `test/` 下 grep `resolveLogSurfaceTheme|parseColorSetting|log_background` → 无匹配，**没有任何测试守住这个行为**。

**为什么用户「设了也白」不能只用缺陷 A 解释**：缺陷 A 只在 `configuredColor == null` 时发作。若用户真把 `log_background_color` 写成了 `#000000`，7 个面全都会立刻变黑。所以必然存在一条「值没写到那个键上」的通路，而 v1.2.6 的 `:832` 错绑正是它。反过来还有一条旁证：若用户面板是 v1.8.0~v2.2.3 血统的老库，`log_background_color` 会残留 `#0f172a`（`docs/release-notes/v3.0.10.md:57-63`），APP 反而会是深色；他看到白色 ⇒ 库里那行是空串 ⇒ 他那次设置确实没落到这个键上。

## proposedFix

## 主修：让兜底底色跟随 App 主题（改 1 个函数 + 7 个调用点）

**`lib/shared/utils/log_background.dart`** —— 给 `resolveLogSurfaceTheme` 加一个必填的主题亮度入参，兜底按亮度分叉：

```dart
LogSurfaceTheme resolveLogSurfaceTheme(
  Color? configuredColor, {
  required Brightness themeBrightness,   // 新增，必填
}) {
  // 面板契约：log_background_color 留空 = 跟随当前主题
  // （server/model/system_config_registry.go:179 的说明原文）。
  // 回落值对齐面板 Web 的 panelAppearance.ts:33-34，不要用 Colors.white/black。
  final background = configuredColor ??
      (themeBrightness == Brightness.dark
          ? AppColors.termBgDark
          : AppColors.termBgLight);
  final brightness = ThemeData.estimateBrightnessForColor(background);
  ...   // 以下不变
}
```

参数做成**必填**而不是可选带默认值：可选默认值会让漏改的调用点静默退回今天的错误行为，编译期报错才能保证 7 处一个不漏。

**`lib/core/theme/app_theme.dart:74-75`** —— 两个常量都要动，并与面板 Web 对齐：

```dart
static const termBgLight = Color(0xFFF8FAFC);  // = slate50，对齐 web DEFAULT_LOG_BACKGROUND_COLOR_LIGHT
static const termBgDark  = Color(0xFF0F172A);  // = slate900，对齐 web DEFAULT_LOG_BACKGROUND_COLOR_DARK
```

现有 `termBg = Colors.white` 建议直接删掉（改完后零引用），别留着当陷阱；`termBgDark` 从 `#000000` 改成 `#0F172A` 才能和 Web 看起来是同一个产品——纯黑底在手机上比 Web 的 slate900 更刺眼，而且面板从来没把纯黑当默认。

**7 个调用点**，全部在 `build()` 或有 context 的方法里，一律加 `themeBrightness: Theme.of(context).brightness`（App 是 `ThemeMode.system`，见 `app.dart:19`，所以 `Theme.of(context).brightness` 就是系统明暗）：

- `lib/features/logs/views/log_stream_page.dart:292`
- `lib/features/tasks/views/task_list_page.dart:3002`
- `lib/features/scripts/views/script_list_page.dart:2713`
- `lib/features/system/views/panel_log_page.dart:97`
- `lib/features/subscriptions/views/subscription_list_page.dart:1642`（在 `_showLogDetail` 里，用的是页面 context，与弹窗同主题，可直接用）
- `lib/features/subscriptions/views/subscription_list_page.dart:1985`
- `lib/features/deps/views/dep_list_page.dart:1640`

前景色那两行（`:91-92` 的 `slate50` / `slate900`）不用动：它们是从**最终底色**的亮度推的，底色对了前景自然对；也别改成读主题文字色——面板 v3.0.10 修的 issue #104 链路 B 就是这个错（`docs/release-notes/v3.0.10.md:65-69`）。

## 补测（当前零覆盖）

`test/` 下新建 `log_background_test.dart`，锁三条契约（都是纯函数，不需要起 UI）：

1. `resolveLogSurfaceTheme(null, themeBrightness: Brightness.dark).background == AppColors.termBgDark` 且 `.foreground` 是浅色 —— 直接锁死 issue #2。
2. `resolveLogSurfaceTheme(null, themeBrightness: Brightness.light).background == AppColors.termBgLight`。
3. 显式配置压过主题：`resolveLogSurfaceTheme(Color(0xFFFFFFFF), themeBrightness: Brightness.dark).background` 仍是白 —— 防止将来有人「顺手」让深色模式无视用户配置。
4. 顺带锁 `parseColorSetting`：`#000000` / `#rrggbbaa` / `rgba(0, 0, 0, 1)` / `rgb(15,23,42)` / 空串 / 脏值，覆盖 Web 那两个控件（`el-color-picker show-alpha` 会写 `rgba(...)`）可能产出的全部形态。

## 建议顺带做（都不改行为，但能防复发）

1. **合并重复实现**：`script_list_page.dart:1917-1962` 的 `_parseColorSetting` 与 `log_background.dart:37-82` 逐字相同，删掉私有副本改调公共函数；`:1899-1915` 的 `_loadEditorAppearance` 也是 `loadPanelLogBackgroundColor` 的复制粘贴变体，可抽成 `loadPanelColorSetting(String key)` 一个函数带两个键。
2. **给用户一条自查路径**：设置页 `log_background_color` 那一项的说明里补一句「留空时深色模式自动用深底」，与面板 Web 的 hint 对齐。
3. **回 issue**：明确告诉用户「1.2.6 里那个『日志背景色』输入框绑错了键（写进了脚本编辑器背景），1.3.0 起设置页改成 schema 驱动已不存在该问题；剩下的『深色模式留空却给白底』是本次要修的」，并提示他升级 APP 后可以先把 `editor_background_color` 里被误写的 `#000000` 清掉。

## 不需要改的

面板侧一行都不用动：接口、字段、默认值、鉴权全部正确，`log_background_color` 是公开接口下发的，`GetConfig` 无缓存。**这是纯 APP 端缺陷。**

## risks

**行为变更（必须写进 release note）**：浅色模式下日志底色会从纯白 `#FFFFFF` 变成 `#F8FAFC`（与面板 Web 一致）。差别很小但确实是可见变更；如果想零变更，浅色分支保留 `Colors.white` 即可，代价是 APP 与 Web 浅色下差一档。同理，若把 `termBgDark` 从 `#000000` 改成 `#0F172A`，任何**显式**把颜色设成 `#000000` 的用户不受影响（显式值优先），只影响留空用户。

**必填参数是把双刃剑**：`themeBrightness` 设为必填会让 7 个调用点全部编译报错，这是刻意的（防漏改），但如果将来有人在 `build()` 之外、拿不到 context 的地方调用它，会被迫把 brightness 一路传下来。目前 7 处都在 build/有 context 的方法内，没有这个问题。

**别顺手把前景色改成主题文字色**：面板 v3.0.10 的 issue #104 链路 B 正是这个错（脚本调试弹窗写了面板主题文字色而不是与底色配对的前景色，导致深灰字压深色底，`docs/release-notes/v3.0.10.md:65-69`）。APP 现在 7 处全部用的是 `logTheme.foreground`（从底色亮度推导），是对的，改动时不要动 `log_background.dart:90-92`。

**老库用户观感会变**：v1.8.0~v2.2.3 血统、`log_background_color` 仍是 `#0f172a` 的面板（未升级到 v3.0.10、没跑那条一次性迁移），APP 端本来就是深色，此次改动对他们零影响——但也意味着**这类用户复现不了本 bug**，测试时必须先确认被测面板的库里那行是空串。

**测试盲区**：`test/` 目前对 log 主题零覆盖，且 7 个日志面全是 UI 层，flutter test 只能守住纯函数那一层；「深色模式下 7 个面实际渲染成什么色」只能真机/模拟器逐个看。按 memory 记录，Trellis 子代理跑不了构建与测试，这一步得主会话自己做。

**未验证项**：本次是纯静态取证，没有起 APP 实测，也没有起面板实例抓 `/api/system/panel-settings` 的真实响应。「面板 2.3.8 会把 `log_background_color` 原样下发」是从 v2.3.8 的源码读出来的，不是抓包实证的。

## openQuestions

- 用户那句「设置 #000000」到底是在 APP v1.2.6 的设置页里设的，还是在面板 2.3.8 的 Web 系统设置里设的？本次结论（缺陷 B = APP 的『日志背景色』错绑 editor_background_color）只在前者成立。若是在 Web 里设的，那半边就得换成另一套解释——最可能是『颜色选择器只做即时预览、没点保存配置』（面板 docs/release-notes/v3.0.10.md:83 记过同款误解）。判据很简单：让用户看一眼面板系统设置里『脚本编辑器背景颜色』那一栏是不是被写成了 #000000，或者直接查库 `SELECT key,value FROM system_configs WHERE key LIKE '%background_color%'`。这是本次唯一需要用户回话才能闭环的点。
- termBgDark 到底取 #000000（现值）还是 #0F172A（对齐面板 Web 的 DEFAULT_LOG_BACKGROUND_COLOR_DARK）？我的建议是后者——同一个产品两端观感应该一致，且面板从来没把纯黑当默认——但这会让『深色模式日志底色』与用户对『终端就该是纯黑』的预期有出入，属于口味裁决，要你拍。浅色侧同理：Colors.white 还是 #F8FAFC。
- APP 完全不支持 log_background_image（面板 Web 有，panelAppearance.ts:210 的 --dd-log-bg-image；PanelSettings 也照常下发了这个字段）。设了背景图的用户在 APP 上只会看到纯色。这算不算本 issue 的一部分、要不要一并做，需要你定范围。
- loadPanelLogBackgroundColor() 每开一个日志面就发一次 HTTP，7 个面互不共享（还有 script_list_page:1901 那次拿 editor_background_color 的，共 8 个请求点）。要不要顺手加一个进程内缓存（比如 Riverpod provider + 手动失效）？属于性能/整洁项，不影响本 bug 的修复，但一起做能少改一次这些文件。
- 是否要在 APP 侧对『用户在设置页把 log_background_color 设成与当前主题严重冲突的值』做提示（例如深色模式下设了 #ffffff）？面板 Web 也没有这个提示，倾向不做，但既然用户是因为颜色才提的 issue，值得确认一次口径。