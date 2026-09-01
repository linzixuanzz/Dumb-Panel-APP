# agent-4

## summary

APP 仓的工程约定几乎全部写在 `.trellis/spec/frontend/` 的 7 份中文规范里（另有 `guides/` 两份思考清单），每条都带 file:line 且明确区分「现状 / 反模式 / 硬规则」，可直接当实作宪法用。质量门禁只有两条硬线：`flutter analyze` ≤ 7 个 info（我实跑确认当前恰好 7 info / 0 warning / 0 error）和 `flutter test` 全绿（实跑 291 例全过），但 **CI 完全不管这两项** —— `.github/workflows/` 里只有 `release.yml` 会被 tag 触发，另两个是纯手动，全仓没有 PR/push 门禁。发版是「pubspec.yaml 单一真源 + 3 份文档跟随」：改 `pubspec.yaml` 的 `version:`、README 的两行版本指针与「本次适配重点」、新增 `docs/release-notes/vX.Y.Z.md`、滚动 `NEXT.md`；Android/iOS 版本号都从 pubspec 派生，无需手工同步。提交信息是中文 `type(scope): 一句话` + 极长的说明性 body（讲根因、否决过的方案、验证结果）。本次 4 条 issue 是 APP 仓的 #2/#4/#5/#6（日志背景色失效、分组与网页不同步、日志详情跳脚本编辑页、脚本编辑页搜索体验），其中只有 #4 有现成测试可参照（`task_list_rows_test.dart`），另外三条对应的代码路径**零测试覆盖**。另外我发现 spec 有 6 处已经与代码脱节（详见 detailedFindings §7），照着旧描述干活会踩坑。

## currentState

这是一个纯 Flutter 客户端仓（`daidai_app`，`pubspec.yaml:1-7`），无后端、无代码生成（全库 0 个 `.g.dart`）。状态管理是 `flutter_riverpod ^2.6.1`，但只用两种 provider：`StateNotifierProvider`（11 个）与 `Provider`（3 个），没有 `AsyncValue`、没有 `.family` / `.autoDispose` / `@riverpod`（`.trellis/spec/frontend/hook-guidelines.md:13-46`）。State 全是手写不可变类 + `copyWith`，可空字段置 null 靠顶层 `const Object()` 哨兵，`error` 字段刻意写成裸 `error: error`（不传即清空）。网络层是 dio 单例 + 唯一的 `AuthInterceptor`，`validateStatus` 已收紧到 `< 400`，SSE 单独走 `package:http` 但与 dio 共用唯一的 `TokenRefresher`。样式已在第 0/1 期收敛完毕：圆角只有 `AppRadius` 五档、卡片走 `AppCard`、提示走 `AppSnack`（实测全库裸 `showSnackBar(` 只剩 `app_snack.dart` 自己那 2 处）、明暗走 `AppSurfaces`、最小点击区 44dp（`AppTapTarget.min`）。质量门禁只有本地两条（analyze ≤ 7 info、test 全绿），CI 一条都不查。发版流程由 `release.yml` 的 `prepare` job 兜底：tag 去 v 后必须等于 pubspec 的 build name，且 `docs/release-notes/<tag>.md` 必须存在，缺一直接 exit 1。

## keyFiles

- `D:\GitHub\Dumb Panel\android-app\.trellis\spec\frontend\index.md` :1-99 — spec 总入口：仓库画像表（技术栈/规模）、7 份文档的索引、以及「读文档前必须知道的四件事」（样式已收敛、validateStatus 已收紧、测试覆盖是有选择的、不要把面板知识抄进 APP）
- `D:\GitHub\Dumb Panel\android-app\.trellis\spec\frontend\quality-guidelines.md` :1-317 — 质量门禁唯一源：lint 配置、7 个 info 基线及每一处的成因与修法、测试现状与「新增功能至少要覆盖什么」表、禁止/必须写法表、代码审查清单、构建工具链坑（含本地 APK 未签名的根因）
- `D:\GitHub\Dumb Panel\android-app\.trellis\spec\frontend\component-guidelines.md` :1-402 — UI 规范：widget 类型选择、AppRadius 五档硬规则、AppCard/AppNotice/三态视图、AppColors 语义色表、tintFg/solidBg 对比度推导、AppSnack 规则（失败必须 error）、44dp 可点区域做法与四个具体坑
- `D:\GitHub\Dumb Panel\android-app\.trellis\spec\frontend\state-management.md` :1-251 — 状态形态：手写 State + copyWith、_unset 哨兵、error 字段「不传即清空」语义及其代价、新增列表 provider 的 5 条硬要求（含「构造函数必须带 {Dio? dio}」）
- `D:\GitHub\Dumb Panel\android-app\.trellis\spec\frontend\hook-guidelines.md` :1-294 — （文件名是 React 模板遗留）Riverpod provider 清单与网络层：Notifier 标准形态、写操作不 try/catch 向上抛、ApiEndpoints 唯一路径来源、api_utils 解包、分页三种做法与「任务列表不做增量分页」的裁决、SSE 续期与重放去重
- `D:\GitHub\Dumb Panel\android-app\.trellis\spec\frontend\directory-structure.md` :1-193 — 目录分层与命名约定：core/features/shared 三层职责、feature 内部结构（只有 views/ 是全局约定）、命名表、import 用相对路径
- `D:\GitHub\Dumb Panel\android-app\.trellis\spec\frontend\type-safety.md` :1-221 — JSON 解析规范：防御式 fromJson 五条约定、toJson 只写可提交字段、dynamic 只许出现在传输边界、后端默认值不得写死在客户端
- `D:\GitHub\Dumb Panel\android-app\.trellis\spec\frontend\panel-contract.md` :1-260 — APP↔面板契约：形状探测代替版本号、config 值必须全是字符串、未知值必须诚实、契约测试要钉 JSON 键名、冻结快照要有可执行守卫、page_size 上限 100
- `D:\GitHub\Dumb Panel\android-app\.trellis\spec\guides\index.md` :1-86 — 思考清单入口 + 触发条件；「改任何值之前先搜」的铁律与三类危险值
- `D:\GitHub\Dumb Panel\android-app\analysis_options.yaml` :10-25 — 只 include flutter_lints，rules 全是注释掉的示例，无 analyzer.errors / exclude / strict 段
- `D:\GitHub\Dumb Panel\android-app\pubspec.yaml` :4,43-47 — 版本号唯一真源 `version: 1.3.3+23`；dev_dependencies 只有 flutter_test / flutter_lints / flutter_launcher_icons，无 mock 库
- `D:\GitHub\Dumb Panel\android-app\.github\workflows\release.yml` :94-144,375-391 — 唯一被自动触发的 workflow（tag `v*`）。prepare job 校验 tag 版本 == pubspec 版本、release-notes 文件必须存在；无 analyze/test/format 步骤
- `D:\GitHub\Dumb Panel\android-app\README.md` :5-16 — 发版必改：「当前版本」两行（APP / 适配面板）+「本次适配重点」一句话；「常见问题」按需追加
- `D:\GitHub\Dumb Panel\android-app\docs\release-notes\NEXT.md` :1-81 — 发版必改：目标版本 / 基线版本 / 记录日期滚动，遗留已知项清单顺延；日常开发也该往这里追加条目
- `D:\GitHub\Dumb Panel\android-app\docs\release-notes\v1.3.3.md` :1-52 — 最近一版正式更新日志的真实文体（版本概览 / 修复 / 优化 / 说明 / 上一版遗留项处理表），实际写法比 TEMPLATE.md 简短得多
- `D:\GitHub\Dumb Panel\android-app\docs\release-notes\TEMPLATE.md` :1-222 — 官方模板（12 节、含商店文案与发布检查清单）；近几版并未照抄，参考 v1.3.x 实际文体更稳
- `D:\GitHub\Dumb Panel\android-app\lib\core\theme\design_tokens.dart` :45-144 — AppRadius(control 4/sm 8/md 12/lg 14/pill 999) / AppSpacing(xxs4 xs6 sm8 md12 lg16 xl20 xxl24 + pageHorizontal 20 + listBottom 100) / AppTapTarget.min=44 / AppBorderWidth(hairline 1, focus 1.5) / AppSurfaces
- `D:\GitHub\Dumb Panel\android-app\test\support\fake_http_adapter.dart` :1-123 — 零依赖假 HTTP 的样板：FakeHttpAdapter + jsonResponse/bytesResponse + dioWithAdapter（validateStatus < 400 与线上同款）。写新测试直接照抄
- `D:\GitHub\Dumb Panel\android-app\test\features\tasks\task_list_rows_test.dart` :1-167 — issue #4（分组）最相关的既有测试：groupTasksByGroupName / sortTaskGroupsByOrder / buildTaskListRows 三个纯函数，11 例
- `D:\GitHub\Dumb Panel\android-app\lib\shared\utils\log_background.dart` :22-95 — issue #2 的核心代码：loadPanelLogBackgroundColor 拉 panelSettings 的 log_background_color、parseColorSetting 解析 #RGB/rgba()、resolveLogSurfaceTheme 回落 AppColors.termBg。当前零测试覆盖
- `D:\GitHub\Dumb Panel\android-app\lib\features\scripts\views\script_list_page.dart` :21,126,179,2564-2868 — issue #5/#6 的主战场，2868 行单文件，内含 scriptProvider / ScriptState / ScriptNotifier / _FileTreeItem / _ScriptVersionSheet / _ScriptDebugRunSheet。仅 list_error_state_more_test.dart 覆盖了它的 error 语义

## detailedFindings

# 1. Dart/Flutter 编码规范与状态管理约定

## 1.1 技术栈事实（`.trellis/spec/frontend/index.md:11-20`）

| 项 | 值 | 依据 |
|---|---|---|
| 状态管理 | `flutter_riverpod ^2.6.1`，**只用** `StateNotifierProvider` + `Provider` | `pubspec.yaml:16`、`hook-guidelines.md:13-27` |
| 网络 | `dio ^5.7.0`（REST）+ `http ^1.2.2`（**仅** SSE） | `pubspec.yaml:19-20` |
| 路由 | `go_router ^14.8.1` | `pubspec.yaml:23` |
| 代码生成 | **无**。全库 0 个 `.g.dart`，无 `build_runner`/`freezed`/`json_serializable` | `pubspec.yaml:43-47`、`type-safety.md:10-14` |
| hooks | **未使用** `flutter_hooks`（`hook-guidelines.md` 的文件名只是 trellis 模板遗留） | `hook-guidelines.md:3-6` |

**明确禁用的 riverpod 特性**（`hook-guidelines.md:22-24`）：`FutureProvider` / `StreamProvider` / `StateProvider` / `ChangeNotifierProvider` / `NotifierProvider` / `AsyncNotifierProvider` / `.family` / `.autoDispose` / `@riverpod`。**没有 `AsyncValue`**，loading/error 是手写字段。

## 1.2 State 类形态（`state-management.md:21-58`）

- 全 `final` 字段 + `const` 构造 + 手写 `copyWith`；集合默认值一律 `const []` 不用 null；不重写 `==`/`hashCode`/`toString`。
- 可空字段置回 null 用顶层 `const Object()` 哨兵（`_unset`）。仓库里有 4 个不同名字的哨兵（`task_provider.dart:9`、`auth_provider.dart:9`、`secure_storage.dart:6`、`env_list_page.dart:18`），新代码**命名靠向 `_unset`**。
- ⚠️ **反直觉且被测试钉死的语义**：`error` 字段故意写成裸 `error: error` 而不是 `error ?? this.error`（`task_provider.dart:43`、`dashboard_provider.dart:73`）。改成 `??` 会让 `list_error_state_test.dart` / `list_error_state_more_test.dart` 里 7 个 State 的用例直接变红（`state-management.md:101-105`）。
- 代价：**任何**不传 `error` 的 `copyWith` 都会把错误提示抹掉。已踩坑两次。与列表无关的更新必须显式回传 `error: state.error`（`state-management.md:106-132`）。`ScriptNotifier` 里还有约 10 处同形状调用没改 —— 这条直接命中 issue #5/#6 要动的文件。

## 1.3 Notifier 三条关键约定（`hook-guidelines.md:76-98`）

1. Notifier 不做依赖注入，`load()` 里直接 `DioClient.instance.dio`（唯一例外 `AuthNotifier` 走 `authServiceProvider`）。**但为了可测，构造函数要带仅供测试的可选 `{Dio? dio}`，且不得在构造时把单例存进字段**（切面板会改 baseUrl）—— 形状见 `quality-guidelines.md:162-172`。
2. 写操作后统一 `await load()` 全量重拉，不做乐观更新（例外只有拖拽排序）。
3. **写操作方法本身不 try/catch，异常向上抛给 UI**；UI 侧 `try { await ... } catch (e) { _showActionError(e, '...'); }`。在 Notifier 写操作里吞异常是明令禁止项（`quality-guidelines.md:216`）。

## 1.4 网络层硬规则

- 路径**唯一来源**是 `lib/core/network/api_endpoints.dart`（193 行）；静态路径写 `static const`，带参数写静态方法，带 query 必须 `Uri.encodeQueryComponent`（`hook-guidelines.md:193-207`）。直接拼字符串是禁止项，且**目前全库零命中**，别破功。
- 响应解包一律 `extractData` / `extractPaginated`，错误文案一律 `extractErrorMessage`；**列表错误态用 `extractListErrorMessage`**（后者不会把英文 `DioException.message` 摊到屏幕中央，`component-guidelines.md:311-315`）。
- `validateStatus` 已是 `< 400`，4xx 会抛 `DioException`。**新增调用点必须自行确认 catch 兜得住 4xx**（`index.md:64-70`）。唯一例外是 `/auth/captcha-config` 保留请求级 `< 500`。
- SSE 走 `sse_client.dart`（`package:http`），401 委托给**全仓唯一续期入口** `TokenRefresher`；服务端不支持 `Last-Event-ID`，重连会全量重放，页面必须用 `SseReplayBuffer` 去重（`hook-guidelines.md:249-278`）。

## 1.5 JSON 解析（`type-safety.md:17-76`）

绝不裸 `as`。五条约定：字符串 `json['x']?.toString() ?? ''`；数值 `_int()/_double()`；布尔 `json['x'] == true`；时间 `_date()`；列表先 `is List` 再 map。每个模型文件底部各自复制一份私有 helper（`_int`/`_date` 在 3 个文件里各写一遍）——**这是现状，新增模型照抄即可，不要为此单开重构**。唯一反例是 `user.dart:34-37` 的裸 `as`，明确写着「新模型不要模仿」。

# 2. UI 规范（间距 / 圆角 / 44dp / AppSnack / 错误态）

## 2.1 令牌（`lib/core/theme/design_tokens.dart`）

- **圆角只有 5 档，禁止第六档、禁止字面量**：`control=4`（控件，Checkbox 专用，不参与整体收缩）/ `sm=8`（图标底板、微徽章）/ `md=12`（输入框、按钮、内嵌块、提示条）/ `lg=14`（卡片、弹窗、底部面板）/ `pill=999`（chip、进度条）。取值**已用户拍板保持不变，要改必须重新拍板**（`design_tokens.dart:35-39`、`component-guidelines.md:86-91`）。
- 间距 `AppSpacing`：`xxs4 / xs6 / sm8 / md12 / lg16 / xl20 / xxl24`，另有 `pageHorizontal=20`（列表页左右留白，全库统一）与 `listBottom=100`（避开悬浮底部导航）（`design_tokens.dart:105-117`）。
- ⚠️ `AppRadius` 与 `AppSpacing` 有同名档位（`xs/xl/xxl`），删档位前必须区分类，只按 `\b(xs|xl|xxl)\b` 搜会连坐（`component-guidelines.md:93-99`）。
- 描边 `AppBorderWidth.hairline=1` / `focus=1.5`；明暗一律 `AppSurfaces.of(context)` 或 `context.surfaces`，**不再手写 `isLight ? A : B`**。

## 2.2 组件层（不要再内联 `BoxDecoration`）

`AppCard`(46 处) / `AppNotice`(11 处) / `AppLoadingView`+`AppEmptyView`+`AppErrorView` / `AppSnack` / `AppChipButton`+`AppTintedActionButton` / `AppSectionTitle` / `AppBackButton` / `AppCircleAddButton`。`boxShadow` 与 `LinearGradient` 全库为 0，扁平化靠 1px 边框 + 底色差。

三个实现细节坑（`component-guidelines.md:117-134, 212-214`）：
- `AppCard` 交互分支的 padding 会**额外加 1dp**（补 `Container` 的 `_paddingIncludingDecoration` 差异），删掉会凭空改变所有交互卡尺寸。
- `ReorderableListView` 的 key 必须在 `itemBuilder` 返回的**顶层 widget** 上，挂到 child 上是**运行时**抛异常，`flutter analyze` 看不出来。
- `Material` 不能同时传 `shape` 和 `borderRadius`，运行时 assert。

## 2.3 颜色

页面直接引用 `AppColors.xxx`（不是 `ColorScheme`）。主色已切成 `#409EFF`（与面板 Element Plus 对齐）。**状态一律用语义名**：`success/successDark/successLight`（#67C23A）、`info*`（等同 primary）、`danger*`、`warning`、`neutral`。禁止用 `primary`/`blue500` 表达「成功/已启用」（会和「运行中」撞色），禁止裸 `Color(0xFF...)`（已清零）。淡底前景走 `tintFg`、实底走 `solidBg/solidFg`，两者明暗方向相反且有完整对比度推导（`design_tokens.dart:215-271`）。

## 2.4 提示条（`component-guidelines.md:221-296`）

统一 `AppSnack.show/success/error/warn`，**失败必须用 `error`**；用户主动取消用 `neutral`；校验没过/部分成功用 `warning`；**没有 `info`**（蓝色被「运行中」占了）。版式只在 `AppSnack` 里定，不要再加 `SnackBarThemeData`。我实测确认：全库裸 `showSnackBar(` 只剩 `lib/shared/widgets/app_snack.dart:36`（文档注释）和 `:84`（实现本体）两处，**零裸调用是真的**。

迁移坑：`AppSnack` 收 `BuildContext` 不是 messenger，要传**页面自身的 `context`** 而不是弹窗的 `ctx`；`StatefulBuilder` 的 `context` 形参和 `build(context)` 形参都会遮蔽 `State.context`，在那里直接用会多出 `use_build_context_synchronously` 告警 —— 解法是把提示调用挪进 State 方法或走文件已有的 `_showSuccess/_showError` 私有转发器。

## 2.5 可点区域

`AppTapTarget.min = 44`（不是 Material 的 48，理由见 `design_tokens.dart:120-128`），**不要引入第二个尺寸档**。做法是**加约束不加 padding**。四个坑：`constraints: const BoxConstraints()` 是「取消默认 48×48」不是「用默认值」；`VisualDensity.compact` 只到 40，要用 `VisualDensity(horizontal:-1, vertical:-1)`；卡片已贴高度下限时改整卡 `onTap`；`materialTapTargetSize: shrinkWrap` + 紧约束会叠加。自定义按钮必须加 `behavior: HitTestBehavior.opaque`。

## 2.6 空态 vs 错误态（硬要求）

新增列表 provider **必须**：State 带 `error`（裸赋值）→ `load()` 开头清空、catch 里 `extractListErrorMessage` → **UI 的 build 里真的把它接到 `AppErrorView`**（带重试）→ 构造函数带 `{Dio? dio}` → 补测试。判据是「build 里有没有消费」，只 grep `final String? error` 会有假阳性（`state-management.md:155-170`）。我实测：10 个 State 有 `error` 字段，8 个 feature 页面 + `app_state_views.dart` 用了 `AppErrorView`。

# 3. 命名、目录与中文文案规范

## 3.1 命名（`directory-structure.md:169-192`）

文件 `snake_case.dart`；页面 `XxxPage`；Notifier `XxxNotifier`（例外 `AppLockController`）；State `XxxState`（例外 `DashboardData`）；provider 变量顶层 `final xxxProvider`；私有 widget `_XxxCard/_XxxItem/_XxxTab`；端点 `ApiEndpoints.xxx`。

## 3.2 目录

`lib/core`（基础设施，判据「2+ feature 依赖且无业务语义」）/ `lib/features/<domain>`（**只有 `views/` 是全部 16 个 feature 都有的约定**；`providers/` 仅 3 个、`widgets/` 仅 3 个、`utils/` 仅 1 个、`models/` 0 个）/ `lib/shared`。

**给新代码的指引**：新建 feature 优先用「独立 `providers/` 目录」的 A 式，但**改动既有 feature 时不要顺手迁移**（B 式是多数派，无谓搬迁让 diff 难审）。新增子组件若只服务当前页面且 <150 行，写同文件私有 class；可能被第二个页面用到就直接放 `lib/shared/widgets/`。纯数据变换被 UI 闭包裹住时，照 `features/notifications/utils/channel_config.dart` 的做法抽到 feature 的 `utils/`，**只搬不改**，行为变更单独一次改动。

## 3.3 import

`lib/` 内全部**相对路径**（`import '../../../core/network/dio_client.dart'`），`test/` 内用 `package:daidai_app/...`（`test/widget_test.dart:1-2`）。顺序习惯 `dart:` → `package:` → 相对路径，未强制（`directives_ordering` 没开）。

## 3.4 注释与中文文案（`quality-guidelines.md:228, 232-251`）

- **全部 UI 文案、代码注释、提交信息用中文**。
- 注释**只记「为什么」和踩过的坑**，不解释「是什么」。这是仓库执行得最好的一条，实例见 `task_provider.dart:134`、`env_list_page.dart:67-68`、`auth_provider.dart:204`。
- spec 文档本身也全中文（`index.md:97-99`）。

# 4. 测试约定

## 4.1 现状（我实跑确认，不是抄 spec）

`flutter test --no-pub` → **291 例全过**。目录下 **20 个 `*_test.dart` + 2 个 support 文件**：

```
test/
├── support/  fake_http_adapter.dart (101行)、fake_sse_http_client.dart (53行)
├── core/auth/       auth_interceptor_test.dart(8) · auth_interceptor_formdata_test.dart(3)
│                    token_refresher_test.dart(6) · login_two_factor_test.dart(4+1 widget)
├── core/network/    sse_client_test.dart(7)
├── shared/          panel_enums_test.dart(23) · duration_utils_test.dart(24)
│                    utils/api_utils_test.dart(5) · utils/sse_replay_buffer_test.dart(6)
├── features/        list_error_state_test.dart(7) · list_error_state_more_test.dart(20)
│                    envs/env_transfer_test.dart(31) · logs/raw_log_download_test.dart(15)
│                    notifications/channel_config_test.dart(15) · notify_field_schema_test.dart(34)
│                    subscriptions/subscription_auth_test.dart(18)
│                    system/system_config_schema_test.dart(34) · tasks/cron_schema_test.dart(15)
│                    tasks/task_list_rows_test.dart(11)
└── widget_test.dart (3 个 testWidgets)
```

风格：**绝大多数是纯函数/Notifier 单测**（286 个 `test()`），widget test 只有 4 个（`widget_test.dart` 3 个 + `login_two_factor_test.dart` 1 个）。用例名是完整中文句子且常写明「为什么这条重要」（例：`'空态不带重试按钮：真的没数据和拿不到数据是两回事'`，`widget_test.dart:44`）。

## 4.2 不加依赖造假的两个样板

- HTTP：手写 `FakeHttpAdapter` 替换 `dio.httpClientAdapter`，拦截器/transformer/`validateStatus`/`DioException` 全是真的（`test/support/fake_http_adapter.dart:13-54`）。`ResponseBody` **必须带 `content-type: application/json`**，否则 dio 不解码（`:74-86`）。
- SSE：手写假 `http.BaseClient`（`test/support/fake_sse_http_client.dart`）。
- 安全存储用 `FlutterSecureStorage.setMockInitialValues({...})`。
- ⚠️ `TokenRefresher` 是单例，`setUp` 里必须 `resetForTest()`，否则上条用例的假 dio 会串到下一条（`quality-guidelines.md:134-136`）。

## 4.3 新功能是否强制配测试（`quality-guidelines.md:174-184`）

**不追覆盖率，按类别分级**：

| 类别 | 要求 |
|---|---|
| 触碰认证/token 链路 | **必须**覆盖 401 → 续期 → 重发 |
| 触碰「读取-修改-回写」表单 | **必须**证明未知字段不丢失 |
| 触碰列表 provider | **必须**证明失败时 `error` 被设置**且能被 UI 消费** |
| 纯 UI 调整 | **不强制** |
| 新增 `shared/utils/` 纯函数 | 建议补单测（已有 3 份可照抄） |

契约类测试还有两条特殊要求（`panel-contract.md:86-97, 130-138, 163-180`）：涉及 config 值必须**在 `jsonEncode` 层断言**是字符串；契约测试要钉 **JSON 键名**不是 Dart 字段；冻结快照要加「不许再长」的可执行守卫。

## 4.4 与本次 4 条 issue 相关的既有测试

本次 4 条 = APP 仓当前全部 open issue：**#2 日志背景颜色失效**、**#4 希望手机的分组能同步网页的分组**、**#5 日志详情页添加按钮跳转至脚本编辑页**、**#6 脚本编辑页搜索优化显示**。

| issue | 相关既有测试 | 覆盖情况 |
|---|---|---|
| #4 分组同步 | `test/features/tasks/task_list_rows_test.dart`（11 例，覆盖 `groupTasksByGroupName` / `sortTaskGroupsByOrder` / `buildTaskListRows`）；`test/features/list_error_state_test.dart`（`TaskListState` 的 error 语义） | **有直接可扩展的测试**。注意 `:9-12` 那条注释：「不显示分组头时必须连折叠状态一起忽略」是个已知坑 |
| #2 日志背景色 | **无**。`lib/shared/utils/log_background.dart` 零测试；最近的只有 `test/features/logs/raw_log_download_test.dart`（日志下载，与背景色无关） | `parseColorSetting` 是不 import Flutter 之外无副作用的纯函数（只依赖 `dart:ui` 的 `Color`），完全可以按 `duration_utils_test.dart` 的形状补单测 |
| #5 日志详情 → 脚本编辑页跳转 | **无直接测试**。相关文件 `lib/features/logs/views/log_stream_page.dart` 与 `lib/features/scripts/views/script_list_page.dart` 均无页面级测试；只有 `test/features/list_error_state_more_test.dart:248-299` 覆盖了 `ScriptNotifier` 的 error/加载语义 | 属「纯 UI 调整」类，spec 不强制配测；若新增路由参数或路径解析纯函数，建议抽到 `features/scripts/utils/` 后单测 |
| #6 脚本编辑页搜索 | **无**。`script_list_page.dart` 2868 行零 widget 测试 | 同上。搜索匹配（高亮区间、下一个/上一个跳转索引）是天然的纯函数，抽出来测比测 UI 划算 |

**共同前提**：`ScriptNotifier` 已支持 `{Dio? dio}` 注入（`script_list_page.dart:179`），要给 #5/#6 补 Notifier 级测试没有障碍。

# 5. 质量门禁

## 5.1 lint 严格度

`analysis_options.yaml` 只有一行有效内容 `include: package:flutter_lints/flutter.yaml`（`:10`），`linter.rules` 下全是注释掉的示例（`:23-25`），**没有** `analyzer.errors` / `exclude` / strict 模式。`flutter_lints: ^6.0.0`。全库**没有任何** `// ignore:` / `// ignore_for_file:`，新增 ignore 是明令禁止项（`quality-guidelines.md:217`）。

## 5.2 info 基线：7 个，硬性不得超过（`quality-guidelines.md:36-38`）

我用 `flutter analyze --no-pub`（`D:\flutter-nospace\bin\flutter.bat`）实跑确认 **7 issues，0 warning，0 error**。**行号已与 spec 记录漂移**，当前实际清单是：

```
use_build_context_synchronously  lib\features\notifications\views\notification_list_page.dart:692:40
use_build_context_synchronously  lib\features\openapi\views\open_api_page.dart:809:38
use_build_context_synchronously  lib\features\scripts\views\script_list_page.dart:2756:46
use_build_context_synchronously  lib\features\security\views\security_page.dart:872:38
use_build_context_synchronously  lib\features\users\views\user_list_page.dart:498:40
library_private_types_in_public_api  lib\features\users\views\user_list_page.dart:74:14
library_private_types_in_public_api  lib\features\users\views\user_list_page.dart:86:32
```

spec 明确要求：**改动前后比对 file:line 清单本身，不要只比总数**（会漏掉「修好一个又新增一个」）。⚠️ 其中 `script_list_page.dart:2756` 正好在 issue #6 要动的文件里，改那一带时容易把它挪位置或复制出新的一条。

**容易顶破基线的三个动作**（`quality-guidelines.md:211`、`component-guidelines.md:278-285`）：删 `boxShadow` 后没给 `BoxDecoration` 补 `const`（`prefer_const_constructors` 会当场多出一批）；在 `StatefulBuilder` 的 `context` 闭包里直接用 `context`；在 `build(BuildContext context)` 形参上做 `if (!mounted)` 判断。

## 5.3 test 门禁

`flutter test` 必须全绿（当前 291 例）。`README.md:20-24` 把 `flutter pub get` / `flutter analyze` / `flutter test` 三条列为「开发」命令。

## 5.4 CI 什么都不查（重要）

我逐个 grep 确认：`.github/workflows/` 三个文件里**没有** `dart format` / `flutter analyze` / `flutter test` 任何一步。触发条件：

| workflow | 触发 | 有无质量检查 |
|---|---|---|
| `release.yml` | `push: tags: v*` + `workflow_dispatch` | 无。只校验版本一致性与 release-notes 存在 |
| `android-build.yml` | **仅** `workflow_dispatch` | 无 |
| `ios-build.yml` | **仅** `workflow_dispatch` | 无 |

即：**没有任何 PR / push 触发的 CI**，analyze/test/format 三项全靠本地自觉（`quality-guidelines.md:312-315`、`NEXT.md:59-60`）。

## 5.5 工具链坑

- Flutter SDK 在 `D:\GitHub\Dumb Panel\flutter_windows_3.41.9-stable\`，**路径含空格会让 `flutter test` 在 native assets 阶段失败**，用目录联接 `D:\flutter-nospace` 绕过（`quality-guidelines.md:271-276`）。我本次两条命令都走 `D:\flutter-nospace\bin\flutter.bat` + `--no-pub`，均成功。
- 本地 `flutter build apk --release` 产出的是**未签名 APK，装不上**（AGP 8+ 在没有 signingConfig 时直接不签名）。正式发版由 CI 用 `secrets.ANDROID_KEYSTORE_BASE64` 解出 jks（`quality-guidelines.md:278-310`）。
- CI 的 Flutter 版本是 **3.41.5**（`release.yml:32,153,215`），本地 SDK 是 3.41.9。

## 5.6 代码审查清单（提交前逐条自检，`quality-guidelines.md:255-267`）

analyze ≤ 7 info 且无新增类型 · test 全绿 · 新路径在 `ApiEndpoints` 里 · 解包走 `api_utils` · 「读取-修改-回写」保留未知字段 · `await` 后没裸用 `context` · 失败时用户看得见原因 · 没有新增圆角取值/裸颜色/影子模型 · 动了 `validateStatus` 就逐个确认调用点。

另有两份思考清单的自检项（`guides/code-reuse-thinking-guide.md:146-152`、`guides/cross-layer-thinking-guide.md:146+`）。

# 6. 发版流程

## 6.1 release 提交只改 4 个文件（`git show --stat` 实测）

`600f26c chore(release): 准备 v1.3.3` 与 `0d946a1 chore(release): 准备 v1.3.2` **改的文件完全一致**：

```
README.md                    | 6 +++---
docs/release-notes/NEXT.md   | ...
docs/release-notes/v1.3.X.md | (新增)
pubspec.yaml                 | 2 +-
```

## 6.2 版本号一共要同步几处：**只有 1 处代码 + 3 处文档**

| 位置 | 改什么 | 依据 |
|---|---|---|
| `pubspec.yaml:4` | `version: 1.3.3+23` → `1.3.4+24`（版本号与 build number 一起进） | 实测 diff |
| `README.md:7-8` | `- APP：\`v1.3.4\`` 与 `- 适配面板：\`v3.x.y\`` 两行 | 实测 diff |
| `README.md:12` | 「本次适配重点」整段换成本版的一句话（**只讲本版**，上一版的描述随版本翻篇，见 `a9d348c` 的提交意图） | 实测 diff |
| `docs/release-notes/vX.Y.Z.md` | **新建**。文件名必须等于 tag（去不去 v 都行，`release.yml:130-133` 两个候选都试） | `release.yml:126-143` |
| `docs/release-notes/NEXT.md:5-7,29` | 目标版本推到下一个、基线版本改成刚发的、记录日期更新、「vX.Y.Z 遗留的已知项」标题跟着改、遗留项顺延 | 实测 diff |

**不需要手工同步的**：`android/app/build.gradle.kts:55-56` 用 `flutter.versionCode` / `flutter.versionName`；`ios/Runner/Info.plist:22,26` 用 `$(FLUTTER_BUILD_NAME)` / `$(FLUTTER_BUILD_NUMBER)`。我 grep 全仓 `1\.3\.[0-9]`，代码侧只有 `pubspec.yaml` 一处（另有 `pubspec.lock` 的第三方包版本，与 APP 无关）。`600f26c` 的 commit body 也逐字写明了这一点。

## 6.3 CI 校验（`release.yml` 的 `prepare` job）

推 tag `vX.Y.Z` 后，两道硬门禁，缺一 `exit 1`：
1. `release.yml:118-121` —— tag 去掉 `v` 后**必须等于** pubspec 的 build name，否则 `::error::Tag 版本 X 与 pubspec.yaml 中的 Y 不一致`。
2. `release.yml:126-143` —— `docs/release-notes/<tag>.md` 或 `<build_name>.md` 必须存在，否则 `::error::缺少更新日志文件`。

该文件随后被原样喂给 `gh release create --notes-file`（`release.yml:375-390`），**所以 release notes 的正文就是 GitHub Release 页面的正文**。产物：`Dumb-Panel-APP-v<ver>-android.apk` + iOS IPA（有签名 secret 就签名，没有就 unsigned）。

## 6.4 提交信息风格（`git log -60` 统计）

格式：`type(scope): 中文一句话`，**标题不带句号**，描述用户可感知的变化而非实现细节。

scope 分布：`app`(24) 最常用，其次 `spec`(7，用于 `docs(spec)`)、`task`(5，用于 `chore(task): archive ...`)、`release`(4)、`ui`(7)、`theme`(3)、`layout`/`tokens`/`trellis`/`dashboard,login` 各 1。type 用 `feat/fix/docs/chore/refactor/perf/test`。

**body 是这个仓库的显著特色**：极长、分点、必写「根因 / 否决过的方案及理由 / 验证结果」。例（`f82b217`）：先驳斥 issue 标题里的「分页」不是根因、列出 4 条为什么卡、8 条改动、明确写「刻意不做增量分页」及数据损坏风险、最后一行 `验证：flutter analyze 7 个 info（基线未破）、flutter test 291 全过（原 280 + 新增 11）`。**建议本次实作照抄这个 body 结构，尤其是结尾那行 analyze/test 数字。**

⚠️ PowerShell 下带双引号的多行 body 必须用 `git commit -F <file>`，`-m` 会被拆坏参数（这是全局记忆里已记的坑）。

# 7. spec 与代码已脱节的 6 处（照旧文档干活会踩坑）

| # | spec 说 | 实际 | 证据 |
|---|---|---|---|
| 1 | 「全库 11 个 StateNotifier，**只有** `TaskNotifier`/`LogListNotifier` 带 `{Dio? dio}`，另外 7 个假 dio 注不进去」 | **9 个**都带了：User / Env / Subscription / Log / Dashboard / Notification / Script / Task / Dep | `quality-guidelines.md:186-196` vs `user_list_page.dart:98`、`env_list_page.dart:88`、`subscription_list_page.dart:66`、`log_list_page.dart:79`、`dashboard_provider.dart:92`、`notification_list_page.dart:68`、`script_list_page.dart:179`、`task_provider.dart:58`、`dep_list_page.dart:146` |
| 2 | 5 处 `use_build_context_synchronously` 的 file:line 清单（674 / 832 / 2759 / 890 / 485） | 行号全部漂了（692 / 809 / 2756 / 872 / 498），总数仍是 7 | `quality-guidelines.md:62-68, 76-83` vs 我的 `flutter analyze` 实跑 |
| 3 | 「`test/` 10 个文件 / 158 个用例」 | 20 个 `*_test.dart` / **291 例** | `index.md:20`、`quality-guidelines.md:110-132`（该处已自带「这棵树不是全量」的警告，但数字仍是 16 个文件） vs 实跑 |
| 4 | 「当前 `1.3.0+20`」 | `1.3.3+23` | `quality-guidelines.md:316` vs `pubspec.yaml:4` |
| 5 | 「`lib/` 59 个文件 / shared/widgets 只有 2 个 / shared/utils 4 个」（同一份 spec 内还有 72 个文件、widgets 7 个、utils 6 个三种说法） | `lib/` **80** 个 dart 文件；`shared/widgets/` **10** 个；`shared/utils/` **7** 个 | `directory-structure.md:15,18,106,128,148-156`、`index.md:20` vs 实际目录 |
| 6 | 「已知仍然存在的漂移源：111 处裸 `showSnackBar`（14 文件）；4 个 State 无 `error`；`SubscriptionListState`/`DashboardData` 有 error 但 UI 不读」 | 全部已修：裸 `showSnackBar(` 只剩 `app_snack.dart` 自己 2 处；10 个 State 都有 `error`；8 个页面接了 `AppErrorView` | `panel-contract.md:256-259` vs `component-guidelines.md:259-261`、`state-management.md:147-153` 与我的 grep |

**结论：以 `quality-guidelines.md` / `component-guidelines.md` / `state-management.md` 的「规则」部分为准，「统计数字」部分一律以实跑/实 grep 为准。** `panel-contract.md` 末尾那张漂移源表是第 2 期快照，已整体过期。

# 8. 顺带发现（与 issue #2 有关，未验证）

`AppColors.termBg = Colors.white`（`lib/core/theme/app_theme.dart:74`）是 `resolveLogSurfaceTheme` 在拿不到面板配置时的**唯一回落值**（`log_background.dart:85`），而同文件 `:75` 定义的 `termBgDark = Color(0xFF000000)` 我 grep 全仓**零引用**。也就是说面板配置拉取失败/字段为空时，深色模式下日志底也会是白的 —— 与 issue #2 的症状吻合。但用户还说「设置 #000000 纯黑也是白的」，那条 `parseColorSetting('#000000')` 静态看是能正确返回黑色的（`log_background.dart:43-50`），所以更可能是 `loadPanelLogBackgroundColor` 的取值链路（`ApiEndpoints.panelSettings` 的响应形状 / `extractData` 结果不是 Map / catch 静默吞异常，`:23-34`）在老面板上失败。**这是假设，未验证**，留给正式排查。另注意 `lib/features/logs/views/log_list_page.dart` 完全没引用 `resolveLogSurfaceTheme`，真正渲染日志的是 `log_stream_page.dart:292`。

## proposedFix

这是只读调查，没有需要修的 bug。以下是给接下来实作定的规矩（按「必须 / 应该 / 不要」三档），以及建议顺带修的 spec 漂移。

## A. 每次改动必须做的（硬门禁）

1. 改完跑这两条，命令用无空格 junction：
   - `D:\flutter-nospace\bin\flutter.bat analyze --no-pub` → 必须仍是 **7 issues**，且**逐条比对 file:line**（当前基线见 detailedFindings §5.2），不是只比总数。
   - `D:\flutter-nospace\bin\flutter.bat test --no-pub` → 必须 **≥291 例全过**。
2. commit 用 `git commit -F <file>`（PowerShell 下 `-m` 会被双引号拆坏），格式 `type(scope): 中文一句话`，body 分点写「根因 / 否决过的方案 / 改动清单 / 验证」，**结尾必须有一行 `验证：flutter analyze N 个 info（基线未破）、flutter test M 全过`**。scope 用 `app`（功能改动）/ `ui` / `theme` / `spec`（改 `.trellis/spec/`）。
3. 每修完一条 issue，往 `docs/release-notes/NEXT.md` 对应的「新增 / 优化 / 修复」小节追加一条**用户视角**的中文描述（不是实现细节）。

## B. 按 issue 分别要注意的

**issue #4（分组同步）** —— 唯一有现成测试的一条。
- 分组相关纯函数一律加进 `lib/features/tasks/utils/task_list_rows.dart`，测试加进 `test/features/tasks/task_list_rows_test.dart`（照 `:15-70` 的 `group()/test()` 形状）。
- **不要**为了「按命令/订阅关键字分组」在 APP 里新写一张规则表或本地匹配算法 —— `panel-contract.md:19-27` 明确禁止「服务端能算的东西下发算法让 APP 本地算」。先确认面板是否已有分组/规则接口，没有就走「面板下发」而不是「APP 复刻」。
- **不要**改成增量分页（`hook-guidelines.md:242-248` 是已裁决的红线，会把 `sort_order` 写坏）。

**issue #2（日志背景色）**
- 先在 `lib/shared/utils/log_background.dart` 落一条判据：`resolveLogSurfaceTheme(null)` 目前恒回落 `AppColors.termBg`（白），而 `AppColors.termBgDark`（`app_theme.dart:75`）零引用。若确认要按明暗回落，改 `resolveLogSurfaceTheme` 让它接 `BuildContext`/`Brightness` 参数，**不要**在 6 个调用点各写一遍三元（`log_stream_page.dart:292`、`task_list_page.dart:3002`、`script_list_page.dart:2713`、`panel_log_page.dart:97`、`dep_list_page.dart:1640`、`subscription_list_page.dart:1642/1985`）。
- `parseColorSetting` 是纯函数，**必须**按 `test/shared/duration_utils_test.dart` 的形状补 `test/shared/utils/log_background_test.dart`（`#RGB` 6/8 位、`rgb()/rgba()`、空串、非法值、大小写）。
- 若根因在 `loadPanelLogBackgroundColor` 的取数链路（`:23-34` 的 catch 静默吞掉），改法是让它区分「面板没配」与「拿不到」，而不是继续静默返回 null。

**issue #5（日志详情 → 脚本编辑页）**
- 新路由/参数一律进 `lib/core/router/app_router.dart`，路径常量进 `ApiEndpoints`（若涉及请求）。
- 跳转按钮是图标按钮的话，命中区必须 ≥ `AppTapTarget.min`（44），**加约束不加 padding**。
- 提示一律 `AppSnack`（失败用 `.error`），错误文案走 `extractErrorMessage`。

**issue #6（脚本编辑页搜索）**
- `script_list_page.dart` 已 2868 行，**新增 UI 拆到 `lib/features/scripts/widgets/`**，不要继续往这个文件追加（`directory-structure.md:101-106`）。
- 搜索匹配逻辑（命中区间计算、下一个/上一个索引推进、循环回绕）抽成 `lib/features/scripts/utils/` 下的纯函数并单测 —— 这是把「无法测的 UI」变成「可测」的标准做法，仓库已有 `features/notifications/utils/channel_config.dart` 先例。
- 搜索弹窗改成「编辑框外右上角浮层」时，圆角只能用 `AppRadius.md`（浮出菜单档）或 `AppRadius.lg`（弹窗档），**禁止新增第六档**；底色走 `AppSurfaces.of(context).card` / `subtle`。
- ⚠️ 该文件里 `:2756` 就是基线 7 个 info 之一（`_ScriptDebugRunSheet` 的 `ScaffoldMessenger.of(context)`），改这一带时别把它复制成第二条，也别顺手「修」出新的类型。
- ⚠️ `ScriptNotifier` 里约 10 处 `copyWith` 没有显式回传 `error`（`NEXT.md:33-42`）。本次若新增 `setSearchKeyword` 之类的方法，**必须写成 `state.copyWith(x: v, error: state.error)`**，否则搜索一敲错误提示就没了。

## C. 建议顺带修的 spec 漂移（单独一个 `docs(spec):` 提交，不要混进功能提交）

按 detailedFindings §7 修 6 处：`quality-guidelines.md:186-196`（Dio 注入现状）、`:62-83`（analyze file:line 清单）、`:316`（版本号）、`index.md:20` 与 `directory-structure.md:15,18,106,128`（文件数统计）、`panel-contract.md:256-259`（整张过期的漂移源表）。这符合 `.trellis/workflow.md:11` 的「Capture learnings」与 `:38` 的「When to update spec」。

## D. 明确不要做的

- 不要新增 `// ignore:` 注释（全库零使用）。
- 不要给 provider 加 `.autoDispose`。
- 不要在 Notifier 的写操作里 try/catch 吞异常。
- 不要写裸 `Color(0xFF...)`、裸 `BorderRadius.circular(<字面量>)`、裸 `showSnackBar(`、裸拼请求 URL、页面里手写 `response.data['data']`。
- 不要引入新的测试依赖（`mocktail`/`mockito`/`http_mock_adapter`/`integration_test` 都没有，也不需要）。
- 不要顺手把 B 式 provider（写在 view 文件顶部）迁成 A 式。
- 不要在功能提交里改版本号 —— 版本号只在 `chore(release): 准备 vX.Y.Z` 提交里动。

## risks

1. **CI 完全不设防**，analyze/test 全靠本地。一旦忘跑，破了「7 个 info」基线也不会有任何地方报错，直到下一次有人跑 analyze 才发现，而那时已经分不清是谁引入的。建议每个功能提交的 body 里都写明当次的 analyze/test 数字（仓库既有习惯）。
2. **`flutter analyze` 的 file:line 清单会随改动漂移**，只比总数会漏掉「修好一个又新增一个」。issue #6 要动的 `script_list_page.dart:2756` 恰好是基线之一，风险最高。
3. **`copyWith` 的「不传即清空」语义**是本仓最容易踩的陷阱，且 `ScriptNotifier`（issue #5/#6 的主文件）里还有约 10 处未修的同形状调用。新增任何 Notifier 方法时忘记回传 `error`，用户就会看到「错误提示莫名变空态」，而这不会被现有测试抓到。
4. **spec 的统计数字已过期 6 处**（详见 detailedFindings §7）。最危险的是 `quality-guidelines.md:186-196` 说「7 个 Notifier 注不进假 dio」—— 实际都能注，照旧文档会白白放弃可写的测试；以及 `panel-contract.md:256-259` 整张表已作废，照它去「修」已经修好的东西是纯浪费。
5. **本地 `flutter build apk --release` 出的是未签名 APK，装不上**。想本机验证必须自签，且签名与正式版不同，装前要卸载旧版、本地数据会丢。
6. **路径含空格**：Flutter SDK 必须走 `D:\flutter-nospace` junction，否则 `flutter test` 在 native assets 阶段炸。我本次两条命令都加了 `--no-pub`，若需要 `pub get` 请单独跑并确认不会污染 `.dart_tool`。
7. **issue #4 有把面板知识抄进 APP 的强诱惑**（在 APP 里写一套「按命令/关键字分组」的规则匹配）。这正是 `panel-contract.md` 整份文档要防的事：面板加一条规则 APP 就得发版。方案阶段必须先确认面板侧有没有现成接口。
8. **发版时最容易漏的是 `NEXT.md`**：它有 5 处要改（目标版本、基线版本、日期、「vX.Y.Z 遗留的已知项」标题、遗留项顺延），而 CI 只校验 `pubspec.yaml` 与 `docs/release-notes/<tag>.md`，漏改 NEXT.md 不会被拦住。
9. `release.yml` 里 release notes 文件**原样成为 GitHub Release 正文**，写错就要重新 `gh release edit`。

## openQuestions

- 本次 4 条 issue 我是按「APP 仓当前全部 open issue」推断的（#2 #4 #5 #6，`gh issue list` 实测），任务描述里没有点名。如果实际指的是面板仓（呆呆面板开发）的某 4 条 issue，或另有清单，§4.4 的测试映射需要重做。
- issue #4「同步网页的分组」到底指什么：是（a）面板 Web 建的分组标签 APP 读不到，还是（b）面板有一套「按命令/订阅关键字自动分组」的规则而 APP 没有实现？两者的解法完全不同 —— 前者是 APP 侧解析 `labels` 的兼容问题，后者按 `panel-contract.md` 应当由面板下发或由面板计算。我没有查面板仓的分组实现，无法判断。
- issue #2 的真实根因未验证。静态看 `parseColorSetting('#000000')` 能正确返回黑色（`log_background.dart:43-50`），所以「设 #000000 也是白的」更可能出在取数链路（`ApiEndpoints.panelSettings` 在面板 2.3.8 上的响应形状 / `extractData` 返回的不是 Map / catch 静默吞异常）。另外 `AppColors.termBgDark`（`app_theme.dart:75`）全仓零引用，回落色恒为白 —— 这两条是假设，需要真机或真实响应样本确认。
- `AppColors.termBg = Colors.white` 恒定回落是有意设计还是遗留缺陷？spec 里没有任何一处提到日志底色的明暗策略，改它属于「修 bug」还是「改设计」需要用户拍板（圆角/主色的取值都明确写了「用户已拍板」，日志底色没有对应记录）。
- `docs/release-notes/TEMPLATE.md` 有 12 节含商店文案与发布检查清单，但 v1.3.0~v1.3.3 实际写的是「版本概览 / 修复 / 优化 / 说明 / 上一版遗留项处理表」这套精简结构。下一版应该照模板还是照 v1.3.3？（我倾向照 v1.3.3，但这是观察不是明文规定。）
- README 的「适配面板」版本号怎么决定？v1.3.3 写的是 `v3.1.0`，但该版说明里明确写「服务端零改动，装在任何面板版本上都能生效」。它是「本次验证过的面板版本」还是「最低要求版本」，没有文档说明。
- spec 的 6 处统计漂移是否要在本次一并修掉？修 spec 会产生一个 `docs(spec):` 提交，需要确认这在本次范围内。
- `.trellis/tasks/` 下当前没有 active task（只有 archive/2026-08 的 5 个）。本次实作是否要按 `.trellis/workflow.md:40-59` 走 `task.py create/start` 的 Trellis 任务流程，还是直接改代码？