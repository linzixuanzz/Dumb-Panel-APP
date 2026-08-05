# Widget 构建约定

> Flutter widget 的真实写法与样式现状。**「样式现状」一节记录的是反模式**，
> 但它是当前 96% 界面的实际形态，改动前必须知道。

---

## Widget 类型选择（全库一致）

| 场景 | 用什么 | 例 |
|---|---|---|
| 页面，需要读 provider + 本地状态 | `ConsumerStatefulWidget` / `ConsumerState` | `task_list_page.dart:25`、`env_list_page.dart:240` |
| 页面，只读 provider 无本地状态 | `ConsumerWidget` | `app.dart:7`（全库仅此一处） |
| 页面，完全不碰 provider | `StatefulWidget` | `panel_log_page.dart:15`、`sponsor_page.dart:14`、`log_stream_page.dart:18` |
| 纯展示子组件 | `StatelessWidget` | `_NavItem`（`main_scaffold.dart:135`）、`TaskCronList`（`task_cron_list.dart:5`） |

全库 99 个 widget class。**未使用** `flutter_hooks`、`HookWidget`、`ConsumerStatefulWidget` 之外的任何变体。

### 构造函数写法

```dart
// lib/shared/widgets/task_cron_list.dart:5-15
class TaskCronList extends StatelessWidget {
  final List<String> expressions;      // 全部 final 字段前置
  final bool compact;
  final bool numbered;

  const TaskCronList({
    super.key,                          // 统一用 super.key，不写 Key? key
    required this.expressions,          // 必填用 required
    this.compact = false,               // 可选给默认值，不用可空
    this.numbered = true,
  });
```

私有子组件不传 `key`：

```dart
// lib/shared/widgets/main_scaffold.dart:142-148
const _NavItem({
  required this.icon,
  required this.activeIcon,
  required this.label,
  required this.isActive,
  required this.onTap,
});
```

---

## 私有子组件：写在同一个文件里

仓库现状是**同文件私有 class**，不是拆成独立文件：

- `_TaskCard` / `_MetaChip` → `task_list_page.dart:1580 / 2702`
- `_EnvCard` / `_HeaderChipButton` → `env_list_page.dart:1907 / 749`
- `_LoginLogsTab` / `_SessionsTab` / `_IpWhitelistTab` / `_TwoFaTab` / `_VerifyCodeInput`
  → 全部在 `security_page.dart`（1249 行）
- `_FileTreeItem` / `_ScriptVersionSheet` / `_ScriptDebugRunSheet` → 全部在 `script_list_page.dart`（2868 行）

只有 `dashboard` / `app_lock` / `login` 三个 feature 有 `widgets/` 目录。

> **指引**：新增子组件时，若该组件**只服务当前页面**且不超过 ~150 行，按现状写同文件私有 class；
> 若可能被第二个页面用到，直接放 `lib/shared/widgets/`（那里目前只有 2 个文件，非常缺）。

---

## 样式现状（反模式）

**这一节记录的是问题，不是要照抄的规范。**

### 主题定义了，但界面不用

`lib/core/theme/app_theme.dart` 提供了 `cardTheme`（`:103-111`，圆角 16 + 1px 边框）、
`inputDecorationTheme`、`filledButtonTheme`、`dialogTheme` 等。实际使用情况：

| 形态 | 次数 | 说明 |
|---|---|---|
| Flutter `Card(` | **6** | `resource_card.dart:20`、`server_config_page.dart:359`、`backup_page.dart:927/1029/1210/1403` |
| 手写 `BoxDecoration(` | **134 / 27 文件** | 每个「卡片」自己拼 color + borderRadius + border |
| 手写 `isLight` 明暗分支 | **507 行 / 27 文件** | `final isLight = Theme.of(context).brightness == Brightness.light;` 后逐处三元 |
| `BorderRadius.circular(` | **149 / 27 文件，11 种取值** | 4 / 8 / 9 / 10 / 12 / 14 / 16 / 18 / 20 / 24 / 999 |
| `BoxShadow` | 12 / 11 文件 | |

**同层级对象取值不统一**：列表项卡片在日志页是 18、任务页是 14、变量页是 12、设置页是 12。

**直接后果**：把 `app_theme.dart` 里的圆角全改成 0，界面上绝大多数卡片不会有任何变化。

### 典型的手写卡片长这样

```dart
// lib/shared/widgets/task_cron_list.dart:24-41（连"共享组件"自己也是这个写法）
final theme = Theme.of(context);
final isLight = theme.brightness == Brightness.light;
...
decoration: BoxDecoration(
  color: isLight ? AppColors.slate50 : AppColors.slate800,
  borderRadius: BorderRadius.circular(compact ? 8 : 10),
  border: Border.all(color: isLight ? AppColors.slate200 : AppColors.slate700),
),
```

### 颜色来源：`AppColors` 静态常量，不是 `ColorScheme`

`lib/core/theme/app_theme.dart:4-43` 定义了 Emerald + Slate 色板
（`AppColors.primary = #10B981`、`slate50`…`slate950`、`red500`、`blue500`…）。

页面**直接引用 `AppColors.xxx`**，而不是 `Theme.of(context).colorScheme.xxx`。
两种写法在同一个文件里混用，例如 `main_scaffold.dart:71` 用 `AppColors.slate900`，
`:154` 用 `Theme.of(context).colorScheme.onSurfaceVariant`。

> 第 0 期 R4 会把主色切到面板的 `#409eff` 并把设计令牌集中化。
> **在共享组件层落地之前**，新代码请：
> 1. 优先用 `Theme.of(context).colorScheme.*`；
> 2. 必须用固定色时统一走 `AppColors`，**不要写裸 `Color(0xFF...)`**；
> 3. 不要新增第 12 种圆角取值。

---

## 对话框与浮层

全库 `showDialog` / `showModalBottomSheet` / `AlertDialog` 合计 **127 处 / 17 文件**，
没有统一封装，每处自己写 `AlertDialog` 或 `showModalBottomSheet`。
`app_theme.dart:211-227` 给了 `bottomSheetTheme`（顶部 20 圆角）和 `dialogTheme`（20 圆角），
这部分因为走的是 Material 组件，**是少数真正生效的主题配置**。

---

## 用户提示：SnackBar，`_showMessage` 各写各的

`ScaffoldMessenger.of(context).showSnackBar` 全库 35 处 / 10 文件。
其中 7 个文件各自定义了**逐字相同**的私有 helper：

```dart
// lib/features/tasks/views/task_list_page.dart:90-97
// 同样的代码另见：log_list_page.dart:238、backup_page.dart:308、
// script_list_page.dart:476、server_config_page.dart:98、dep_list_page.dart、app_lock_settings_page.dart
void _showMessage(String message) {
  if (!mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
```

**没有** 成功/失败/警告的视觉区分，全部是默认样式的 SnackBar。

错误文案统一经 `extractErrorMessage(error, fallback)`（`shared/utils/api_utils.dart:44`）提取后端 `error`/`message` 字段：

```dart
// lib/features/tasks/views/task_list_page.dart:99-101, 3137
Future<void> _showActionError(dynamic error, String fallback) async {
  _showMessage(_extractTaskError(error, fallback));
}
String _extractTaskError(dynamic error, String fallback) => extractErrorMessage(error, fallback);
```

---

## 空状态：硬编码文案，**没有错误态**

27 处 `暂无XXX` 文案分散在各页面（`task_list_page.dart:880`、`log_list_page.dart:643`、
`env_list_page.dart:1132`、`notification_list_page.dart:260` …）。

**没有任何页面在请求失败时显示错误 + 重试**。断网时列表走的是同一条「暂无数据」分支，
因为 provider 的 `catch` 只把 `loading` 置回 false（详见 state-management.md）。

> 第 0 期 R3 要修这个。新增列表页时，请把「真的没有数据」与「拿不到数据」区分开。

---

## `BuildContext` 跨异步使用

约定是 **`await` 之后先判 `mounted`**：

```dart
// lib/features/envs/views/env_list_page.dart:1454-1472
final rootMessenger = ScaffoldMessenger.of(context);   // 先取出，避免 await 后用 context
final navigator = Navigator.of(ctx);
await ref.read(envListProvider.notifier).update(...);
if (!mounted) return;
navigator.pop();
rootMessenger.showSnackBar(const SnackBar(content: Text('已保存')));
```

这个约定**执行得不彻底**：`flutter analyze` 仍有 4 处 `use_build_context_synchronously`
（见 quality-guidelines.md）。新代码必须遵守，不得让这个计数上升。

---

## 常见错误（本仓库真实发生过）

| 错误 | 后果 | 依据 |
|---|---|---|
| 编辑表单时用空 map 重建 config 再整串覆盖 | 面板支持但 APP 字段表里没有的键**保存即丢失** | `notification_list_page.dart:735-757`（对照正确做法 `open_api_page.dart:671` 保留未知 scope） |
| 后端默认值写死在表单里 | 面板改了默认 Python 版本，APP 不跟随 | 已修：`task_form_page.dart:223-266` 现在读 `default_version` |
| 请求 URL 直接拼字符串 | 绕过 `ApiEndpoints`，改路径时漏改 | `system_settings_page.dart:265/349/419` 三处 `'${ApiEndpoints.baseApi}/system/...'` |
