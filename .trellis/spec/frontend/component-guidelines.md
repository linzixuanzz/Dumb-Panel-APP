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

## 样式：组件层已建立并接线（第 1 期完成）

### 圆角：五档，取值已拍板固定

`lib/core/theme/design_tokens.dart` 的 `AppRadius`：

| 档 | 值 | 角色 |
|---|---|---|
| `control` | 4 | **控件**（Checkbox 方框等尺寸恒定的东西） |
| `sm` | 8 | 图标底板、微徽章 |
| `md` | 12 | 输入框、内嵌块、按钮 |
| `lg` | 14 | 卡片 |
| `pill` | 999 | chip、进度条 |

改造前是 **11 种散装取值**（4/8/9/10/12/14/16/18/20/24/999，其中 9 和 24 各只出现一次
——那是手滑不是设计）。现在 `lib/` 下活代码里 `Radius.circular(<字面量>)` **一处不剩**。

> **硬规则**：
> 1. 新代码只能用这五个名字，**禁止新增第六档**，也禁止写字面量。
> 2. `control` 与 `sm` 值不同源：`control` 描述**控件**（尺寸恒定，半径就是半宽的比例，
>    18dp 的 Checkbox 上 4 占 22%、8 占 44% 已接近圆）；`sm/md/lg/pill` 描述**表面**
>    （尺寸由内容撑开）。两者不同量纲，不要互相替代。
> 3. 取值经用户拍板**保持当前值不变**——11 种收敛成 5 种的一致性收益已经拿到，
>    再压绝对值只产生「不一样」不产生「更干净」。要改必须重新拍板。

### ⚠️ `AppSpacing` 有同名档位，是最容易误删的一处

`AppRadius` 与 `AppSpacing` 都有 `xs / xl / xxl` 这类名字。`AppRadius` 的三个已在
第 1 期删除（零引用），但 **`AppSpacing.xs` / `AppSpacing.xl` 有 4 处在用**
（`dashboard_page`、`sponsor_page`、`app_buttons` ×2、`app_state_views`）。

删档位前必须区分是哪个类，只按 `\b(xs|xl|xxl)\b` 搜会连坐。

### 卡片与提示条：走组件，不要内联 `BoxDecoration`

| 组件 | 调用点 | 用途 |
|---|---|---|
| `AppCard` | **46** | 一切「卡片形」表面（有底色 + 圆角，通常有边框） |
| `AppNotice` | **11** | 淡底提示条（帮助说明、错误提示、模式横幅） |
| `AppLoadingView` / `AppEmptyView` / `AppErrorView` | 各 3~4 | 列表三态 |

`BoxDecoration(` 从改造前的 **134 处降到 76 处**，剩下的是真正不该用 AppCard 的：
`BoxShape.circle` 的圆钮与状态点、微徽章 / chip、图标底板、单边描边的分隔线，
以及两处 `AnimatedContainer` + `Matrix4` 左滑操作（`AppCard` 不接
`duration/curve/transform`）。

`boxShadow` 与 `LinearGradient` 全库**均为 0**。扁平化不靠投影和渐变分层，
靠 1px 边框 + 底色差。

#### `AppCard` 有一处容易被当成手滑的实现细节

有交互分支（传了 `onTap`/`onLongPress`）走 `DecoratedBox > Material > InkWell > Padding`，
`Padding` 在 `bordered` 时会**额外加 1dp**：

```dart
final effectivePadding = bordered
    ? padding.add(const EdgeInsets.all(AppBorderWidth.hairline))
    : padding;
```

因为无交互分支走 `Container(padding:, decoration:)`，而 `Container` 在有 `decoration`
时会把 `border.dimensions` 并进内边距（`_paddingIncludingDecoration`），
`DecoratedBox` 不会。不补这 1dp，同一个 `padding:` 参数在两个分支给出不同结果。
**删掉它会凭空改变所有交互卡的尺寸。**

> 同一个机制也解释了：`Container(padding: all(20), decoration: 带 border)` 的内容
> 实际内缩是 **21dp** 不是 20dp。算裁切/对齐几何时要记得。

### 颜色来源：`AppColors` 静态常量，不是 `ColorScheme`

`lib/core/theme/app_theme.dart` 定义了主色 + Slate 色板
（`AppColors.primary = #409EFF`、`slate50`…`slate950`、`red500`、`blue500`…）。
主色已在第 0 期 R4 与面板 v3.0.0 的 `--el-color-primary` 对齐，
浅/深变体取 Element Plus 的 `primary-light-9` / `primary-dark-2`。

> ⚠️ **主色现在是蓝色**，与 `AppColors.blue500 (#3B82F6)` / `blue600 (#2563EB)` 很接近。
> 主色换蓝后，历史上那些用主色表达「成功 / 已启用」的地方与「运行中 / 进行中」撞了色，
> 现已在 `AppColors` 里补上真实语义色并逐处改用：

| 语义 | 常量 | 取值 | 用途 |
|---|---|---|---|
| 成功 / 已启用 / 已安装 | `success` / `successDark` / `successLight` | `#67C23A` / `#529B2E` / `#F0F9EB` | 状态圆点、深色前景 / 浅色前景 / 浅色淡底 |
| 运行中 / 进行中 / 信息 | `info` / `infoDark` / `infoLight` | 等同 `primary` / `primaryDark` / `primaryLight` | 同上 |
| 失败 / 危险 | `danger` / `dangerDark` / `dangerLight` | 等同 `red500` / `red600` / `red100` | 同上 |
| 排队中 / 警告 | `warning` | 等同 `amber500` | — |
| 已禁用 / 中性 | `neutral` | 等同 `slate500` | 徽章前景 |

> 绿色三兄弟取面板 Element Plus 的 `--el-color-success` / `success-dark-2` / `success-light-9`，
> 与主色同源；红 / 琥珀只建立语义别名，视觉不变。
>
> **状态判断处一律用上表的语义名**，不要再直接挑 `primary` / `blue500` 当状态色，
> 也不要写裸 `Color(0xFF...)`。`primary` 只用于「品牌 / 选中 / 焦点 / 下拉刷新」这类主色语义。

页面**直接引用 `AppColors.xxx`**，而不是 `Theme.of(context).colorScheme.xxx`。
两种写法在同一个文件里混用，例如 `main_scaffold.dart:71` 用 `AppColors.slate900`，
`:154` 用 `Theme.of(context).colorScheme.onSurfaceVariant`。

> 设计令牌已落在 `lib/core/theme/design_tokens.dart`。新代码请：
> 1. 圆角 / 间距 / 描边宽度走 `AppRadius` / `AppSpacing` / `AppBorderWidth`，**不写裸数值**；
> 2. 明暗分支走 `AppSurfaces.of(context)`，**不再手写 `isLight ? A : B`**；
> 3. 卡片用 `AppCard`、提示条用 `AppNotice`、列表三态用
>    `AppLoadingView` / `AppEmptyView` / `AppErrorView`；
> 4. 必须用固定色时统一走 `AppColors`，**不要写裸 `Color(0xFF...)`**；
> 5. 不要新增第六档圆角。

#### 第 2 条的例外：要和既有组件像素一致的**复刻件**

「复刻件」指的是：因为 Dart 私有类 import 不到，只能在另一个文件里照抄一份的同款组件。
这类组件**可以沿用 `isLight ? A : B`**，而且应该沿用。

已知这一对是 `more_page.dart` 的 `_SettingsItem` 与 `about_page.dart` 的 `_LinkItem`
（v1.3.7 / APP issue #12）——后者是前者的跨文件复刻，两者并排出现在设置系页面里，
配色必须逐字相同。

理由是**这里没有能完整替代三元的令牌**：
`isLight ? slate500 : slate400`（副标题）恰好等于 `surfaces.mutedText`，
但 trailing 图标的 `isLight ? slate400 : slate600` **没有对应令牌**。
一半用令牌一半写三元，反而比两条都写三元更难看出「这两个文件必须一致」。

> 🔴 **改任一侧都要同步改另一侧**。它们之间没有编译期约束，漂了只有肉眼能发现。

### 前景色：淡底走 `tintFg`，实底走 `solidFg`，两者明暗方向**相反**

```dart
// 淡底（withAlpha 的徽章 / chip / 提示条）
Color tintFg(Color c) => isLight ? Color.lerp(c, Colors.black, 0.2)! : c;

// 实底（SnackBar 这类整块着色的背景）
Color solidBg(Color c) => isLight ? Color.lerp(c, Colors.black, 0.4)! : c;
Color get solidFg      => isLight ? Colors.white : AppColors.slate950;
```

**为什么必须用它们**：`tintBg()` 浅色模式是 `withAlpha(18)`，若调用方拿**同一个满强度色**
当前景，数学上对比度封顶约 2.6:1。绿色更糟（`success` 亮度高，只有 2.13:1），
`warning` 是 2.04:1。套上 `tintFg` 后分别升到 3.93 / 3.27 / 3.14:1。

**为什么 20% 这个系数**：`Color.lerp(c, black, 0.2)` 逐字节复现了 `primaryDark` / `successDark`
——Element Plus 的 `dark-2` 定义就是 `mix($color, black, 20%)`，两个常量当初就是抄它的。
所以 `tintFg` 不会分裂出第二种深蓝 / 深绿。

**为什么 `solidBg` 明暗方向相反**：SnackBar 的默认底是 `inverseSurface`（与页面相反）。
若照 `tintFg` 那样深色返回原色，浅色那支深绿 `#3E7423` 摆到 `slate950` 页面上只有
2.42:1，连非文字的 3:1 都不到。且 20% 的 `dark-2` 配方在**实底**上不够用
（白字压 `successDark` 只有 3.45:1），必须压到 40%。

> ⚠️ **淡底前景不要二次加深**：有些 `_statusFg()` 函数浅色模式**已经返回 `*Dark`**
> （`backup_page`、`task/dep/subscription` 的状态色）。对它们再套 `tintFg` 会得到
> `#29659F` 这种过深的颜色。套之前先确认调用方传的是满强度色。

> **已知未达标（不是本期引入的）**：按 WCAG 对 10px 加粗文字的真实要求 4.5:1，
> `primary` 3.93 / `success` 3.27 / `warning` 3.14 仍不够，只有 `danger` 5.05 过线。
> 补齐需要加深 `AppColors` 的全局常量，用户已决定**保持与面板 Element Plus 一致、不加深**。

---

## 对话框与浮层

全库 `showDialog` / `showModalBottomSheet` / `AlertDialog` 合计 **133 处 / 18 文件**，
没有统一封装，每处自己写 `AlertDialog` 或 `showModalBottomSheet`。

> 这个数字**在涨**（改造期记的是 127 处 / 17 文件）。没有封装意味着每新增一个弹窗就多一份
> 圆角 / 按钮高度 / 取消文案的自由发挥，涨的是后面统一时要改的量。新增弹窗前先看看
> `script_list_page.dart`（23 处）那几个 `showDialog` 是不是已经有能抄的形状。

`app_theme.dart:211-227` 给了 `bottomSheetTheme`（顶部 20 圆角）和 `dialogTheme`（20 圆角），
这部分因为走的是 Material 组件，**是少数真正生效的主题配置**。

---

## 用户提示：统一走 `AppSnack`

改造前 7 个文件里各自定义了**逐字相同**的私有 `_showMessage`（8 份，含
`script_list_page.dart` 里的两份）。第 0 期 R4 把它们收敛成
`lib/shared/widgets/app_snack.dart`：

第 1 期提交 4 给它加了语义色调 `AppSnackTone{neutral, success, error, warning}`，
各页面按语义留 2~4 行委托：

```dart
// 中性告知（用户主动取消、空结果等），配色与第 0 期完全一致
void _showMessage(String message) => AppSnack.show(context, message);

// 成功 / 失败 / 警告
void _showSuccess(String message) => AppSnack.success(context, message);
void _showError(String message) => AppSnack.error(context, message);
void _showWarning(String message) => AppSnack.warn(context, message);

// 需要覆盖上一条提示时（应用锁设置页），三个快捷方法都支持：
AppSnack.error(context, message, replaceCurrent: true);
```

规则：

- **失败必须用 `error`**，不能再让「保存失败」和「保存成功」长得一样。
- 用户主动取消、"暂无可清理内容" 这类**不表态**的提示留 `neutral`。
- 校验没过 / 平台不支持 / 部分成功用 `warning`，不要一律报红。
- 没有 `info`：蓝色已被 `AppColors.info` 占去表示「运行中」，提示条不再占用。
- 底色前景一律走 `AppSurfaces.solidBg / solidFg`，禁止在调用点自己挑颜色。
- 版式（`floating` + margin + 圆角）只在 `AppSnack` 里定，**不要**再加
  `SnackBarThemeData`，两边同时配会互相盖。

> `main_scaffold.dart` 的「5 秒内再按一次返回键退出」在提交 4 里**一并迁到了
> `AppSnack.show(replaceCurrent: true, duration: 5s)`**。它本不在这一提交的范围内，
> 但提交 4 把 `AppSnack` 的版式改成了 `floating`，不迁它就会变成全 App 唯一一条
> 还是通栏方块的提示条 —— 而它恰恰是出现频率最高的之一。
> **一般规则：本提交造成的不一致，在本提交里修掉，不推给 backlog。**
>
> **v1.3.1 起全库零裸调用。** 曾经的 111 处（14 个文件）已全部迁完，
> 现在 `showSnackBar(` 只剩 `app_snack.dart` 自己那 2 处：一处在文档注释里、
> 一处是 `AppSnack` 的实现本体。**新代码一律走 `AppSnack`，不要开新的裸调用。**

### 迁移时最容易踩的一个坑

不少调用点原本会提前把 messenger 存下来规避 async gap：

```dart
final rootMessenger = ScaffoldMessenger.of(context);   // 弹窗 builder 里
...
rootMessenger.showSnackBar(...);
```

`AppSnack` 收的是 `BuildContext` 不是 messenger，所以这个变量迁完会变成未使用。
**删掉它，改传页面自身的 `context`**（不是弹窗的 `ctx`）——`ScaffoldMessenger.maybeOf`
解析到的是同一个根 messenger，弹窗 pop 之后照样能弹。前提是每个 `await` 之后
有 `if (!mounted) return;` 兜住。

两处特别容易多出 `use_build_context_synchronously` 告警：

- **`StatefulBuilder(builder: (context, setState))` 的 `context` 参数会遮蔽 `State.context`**，
  在那个闭包里直接用 `context`，分析器会认为外层的 `mounted` 检查「与它无关」。
- **`build(BuildContext context)` 的形参同理**，不被视为 `State.context`。

两种情况的解法都是：把提示调用挪进一个 State 方法（或走文件已有的
`_showSuccess` / `_showError` 私有转发器），让 `context` 解析到 `State.context`。

错误文案统一经 `extractErrorMessage(error, fallback)`（`shared/utils/api_utils.dart:44`）提取后端 `error`/`message` 字段：

```dart
// lib/features/tasks/views/task_list_page.dart —— 全部任务操作失败的漏斗，
// 批量操作 / 排序保存 / 停止 / 启停 / 复制 / 置顶 / 删除七条路径共用
Future<void> _showActionError(dynamic error, String fallback) async {
  _showError(_extractTaskError(error, fallback));
}
String _extractTaskError(dynamic error, String fallback) => extractErrorMessage(error, fallback);
```

---

## 空状态 vs 错误态：全部列表已区分（v1.3.1 补齐）

所有列表在「有错误且列表为空」时显示原因 + 重试按钮（`AppErrorView`），
不再一律显示「暂无数据」。

> ⚠️ **别用 `grep 'final String? error'` 判断某个列表修好了没有**——会有假阳性。
> `SubscriptionListState` 与 `DashboardData` 曾长期处于「字段在、`catch` 里也 set 了、
> 但整个 build 一次都没读过」的状态：症状和完全没做一样，却更容易被误判为已修。
> **判据是 build 里有没有把它接到 `AppErrorView`。**

> 新增列表 provider **必须**带 `error` 字段，并把「真的没有数据」与「拿不到数据」区分开。
> 错误文案走 `extractListErrorMessage`（不是 `extractErrorMessage`）——后者在后端没返回
> `error`/`message` 时会退回 `DioException.message`，那是英文
> （"The connection errored: Failed host lookup..."），而错误态是摊在屏幕中央给用户看的。

---

## 可点区域：最小 44dp，用约束补而不是加 padding

令牌是 `AppTapTarget.min = 44`（`core/theme/design_tokens.dart`）。

取 44 而不是 Material 规范的 48：全库多数图标按钮原本在 30–36dp 档，一律抬到 48 会把
列表行、导航栏、批量操作条整体撑高，密度损失明显；44 已经越过 iOS HIG 的 44×44 与
WCAG 2.2 AA 的 24×24 两条线。**不要再引入第二个尺寸档。**

**做法：加约束，不加 padding。** 这样命中区变大而视觉尺寸不变：

```dart
// ✅ IconButton / PopupMenuButton：改 constraints
constraints: const BoxConstraints(
  minWidth: AppTapTarget.min,
  minHeight: AppTapTarget.min,
),

// ✅ 自定义按钮：SizedBox 撑开 + Center 居中
GestureDetector(
  behavior: HitTestBehavior.opaque,   // 少了它，图标笔画之间的透明像素不响应点击
  onTap: onTap,
  child: SizedBox(
    width: AppTapTarget.min,
    height: AppTapTarget.min,
    child: Center(child: Icon(icon, size: 18)),
  ),
)

// ✅ 有背景/边框的胶囊按钮：ConstrainedBox 包住，Container 加 alignment
ConstrainedBox(
  constraints: const BoxConstraints(minHeight: AppTapTarget.min),
  child: Container(alignment: Alignment.center, padding: ..., child: ...),
)
```

**已有的共享组件，不要再手写一遍**：

| 组件 | 用途 | 替代的写法 |
|---|---|---|
| `AppBackButton` | 页面头部返回 | `GestureDetector(onTap: context.pop, child: Icon(arrow_back_ios, size: 20))` |
| `AppCircleAddButton` | 头部右上角圆形「新建」 | 32dp 的 `Container` + `BoxDecoration(circle)` + `Icon(add)` |

### 几个具体的坑

- **`constraints: const BoxConstraints()` 不是「用默认值」，是「取消默认值」。**
  `IconButton` 默认有 48×48，传空约束等于把它清零，命中区退化成图标本身
  （`task_list_page` 的分组菜单曾因此只有 18dp）。要改小就写明具体数值，别传空的。
- **`VisualDensity.compact` 是 −2 档（48→40）**，仍然不达标。改用
  `VisualDensity(horizontal: -1, vertical: -1)` 拿到 44——直接删掉 `compact` 会让每行长高 8dp。
- **卡片已经贴着高度下限时，别撑大里面的勾选框**，改成整卡 `onTap`
  （任务页、环境变量页本来就是这样）。依赖列表的 24dp 勾选框就是这么处理的。
- **`materialTapTargetSize: shrinkWrap` + `SizedBox` 紧约束会叠加**，
  36×36 会被压到 24dp，比看上去更糟。

---

## 日志正文：`LogView` + `LogLineBuffer`（#10 建立，APP #15 补逐行追加路径）

三个页面共用：`TaskLiveLogPage`（`task_list_page.dart`，任务运行日志）、`LogStreamPage`
（`log_stream_page.dart`，日志详情 / 运行中日志）、`PanelLogPage`（`panel_log_page.dart`，
`follow: false` 的静态日志）。**新的日志页接这一套**，不要再把整段 `join('\n')` 铺成一棵
`RichText` —— 那是 #10 之前几万行就卡死的写法（脚本「调试运行」弹窗 `_ScriptDebugRunSheet`
还是它；依赖安装、订阅拉取两页是各自的 `ListView`、没有上限，都未迁，在 backlog）。

> #10（`ef8368e`）当时没有写进 spec，下面的「基线」是按现有代码补的。
> 运行中日志的数据从哪来、怎么去重见 [hook-guidelines.md](./hook-guidelines.md)「实时日志页」一节；
> 面板推流的形状见 [panel-contract.md](./panel-contract.md)「实时日志」一节。

### 基线（#10）

| 部件 | 约定 | 位置 |
|---|---|---|
| 行缓冲 | 按行追加；追加时顺手算好每行「行首生效的 ANSI 样式」（`ansiStateAt`），按行渲染时靠它续上跨行颜色、不回扫；内存严格只留最近 `kLogBufferMaxLines = 10000` 行，丢掉的计入 `droppedCount`，截断提示与「复制最近 N 行」的 N 就是它 | `lib/shared/utils/log_line_buffer.dart` |
| 绝对行号 | 第 n 行的绝对位置 = `droppedCount + 下标`，裁剪不改变它；`replaceAll`（含 `clear`）让 `generation + 1`，绝对行号从 0 重数 | 同上 |
| 双列表 | `CustomScrollView` 以锚点 `_anchor`（绝对行号）为界：之前的行在上方 `SliverList`（反向生长），之后的行在下方 `SliverList`（新行都接这里）；锚点之上真有行才设 `center`，否则短日志会被顶在屏幕中间 | `lib/shared/widgets/log_view.dart` 的 `_LogViewState.build` |
| 回到底部 | 不跳很远的偏移（懒加载列表要把中间每一行都排一遍），而是锚点挪到 `total - 200`（`_kTailWindow`）、`_sliverGeneration++` 换掉两个列表的 key、按估算行高先 `jumpTo` 到尾段附近，帧后再贴底校正 | `_jumpToLatest` |
| 跟随 | 距底 ≤ `kLogFollowTolerance`（32px）才算在底部；「用户在滚」只认手势（拖动的 `ScrollStartNotification.dragDetails`、滚轮 / 触控板的 `UserScrollNotification`），程序贴底不算；手指还在屏幕上时绝不 `jumpTo`（会打断手势） | `_handleScrollNotification`、`_stickToBottom` |
| 暂缓裁剪 | 不跟随时 `holdTrim = true`：上限放宽到 2 倍、超了一次裁回 `maxLines`，否则每来一行眼前的内容就被往上推一行；`dispose` / 换缓冲区时复位成 false（缓冲区归页面所有，比视图活得久） | `LogLineBuffer.holdTrim`、`_setFollowing`、`dispose` |
| 静态日志 | `follow: false`：从顶部开始，无跟随、无「回到底部」、不挂选区回调 | `LogView.follow` |

### 契约：`LogLineBuffer` 用表头偏移裁剪（APP #15）

**1. 范围与触发**：改 `LogLineBuffer` 的裁剪或存储方式，或新增读它的地方。运行中日志是 SSE
每条 `data:` 行 `append` 一次、一次 1 行；改前缓冲区满后每来一行就把两张 1 万元素的表
`removeRange(0, 1)`，5 万行历史重放的数据通路要 1.6~2.4 秒（桌面 AOT，基本都花在搬表上）。

**2. 签名**（对外不变，只多一个测试用 getter）

```dart
int get length;  bool get isEmpty;  bool get isNotEmpty;
int get droppedCount;  int get totalCount;  int get generation;
List<String> get lines;                 // 只读；表头有待搬走的行时是拷贝
String lineAt(int index);
AnsiLineState ansiStateAt(int index);
bool holdTrim;
void append(Iterable<String> lines);  void replaceAll(Iterable<String> lines);  void clear();
String joinAll();
@visibleForTesting int get debugCompactions;   // 真正 removeRange 的累计次数
```

**3. 契约**

- **逻辑上当场裁好**：每次 `append` / `replaceAll` 后，长度一超 `holdTrim ? 2 × maxLines : maxLines`
  就裁回 `maxLines`。`length` / `droppedCount` / `totalCount` / `lines` / `joinAll` / `lineAt` /
  `ansiStateAt` 与「每次当场 `removeRange`」的原版**逐行一致**。
- **物理上攒着搬**：裁剪只做 `_head += excess`；`_head >= maxLines ~/ 10`（1 万行时是 1000）
  才把两张表一起 `removeRange(0, _head)` 并清零。跟随时物理上最多多留一成；
  `maxLines < 10` 时 `~/ 10` 为 0，每次都搬，与原版同一条路。
- 所有按下标取值都要加 `_head`，`length = _lines.length - _head`；`replaceAll` 必须把 `_head` 清零。
- `lines`：`_head == 0` 时是不复制的只读视图；否则是 `sublist(_head)` 的只读**拷贝**（O(n)）。
  **逐行 / 逐帧的路径禁止读 `lines`**，用 `length` + `lineAt`；现在只有重连去重
  （`_resetReplayBuffer`）和测试读它。
- 通知：`append` 空集合不通知、也不裁；`replaceAll` 一定通知。

**4. 边界矩阵**

| 情况 | 行为 |
|---|---|
| `maxLines` 为 1~9 | `_head` 恒为 0，每次都真搬，与原版完全一样 |
| 跟随中逐行越过上限 | 每行逻辑上裁 1 行（`droppedCount` 每行 +1，截断提示逐行准确），每 `maxLines ~/ 10` 行真搬一次 |
| `holdTrim` 期间超过 2 倍 | 一次裁回 `maxLines`；这时 `excess > maxLines ~/ 10`，当场搬表 |
| `holdTrim` 由 true 改 false | 不立即裁，下一次追加时按正常上限裁（别在滚动回调里改正在布局的列表） |
| `replaceAll` / `clear` | `_head`、`droppedCount` 清零，`generation + 1` |

**5. 用例**

- 正常：上限 1 万，逐行追加 5 万行 → 每一步 `length == min(total, 10000)`、`lineAt(0)` 是第 `total - kept` 行；搬表 ≤ 50 次（原版 4 万次）。
- 基础：上限 100，逐行追加 109 行 → `length 100`、`droppedCount 9`、`debugCompactions 0`；第 110 行 → 搬 1 次。
- 错误：上限浮动到 `maxLines + 10%`，见第 7 段。

**6. 必须有的测试**（`test/shared/utils/log_line_buffer_test.dart`，不计时）

- 改造前的实现原样搬进测试当对照（`_OriginalBuffer`），`maxLines ∈ {1, 2, 7, 10, 25, 100}` 各随机走 400 步
  （逐行追加 / 整批追加 / 切 `holdTrim` / `replaceAll` / `clear`），每步比上面七项，
  并逐行比 `lineAt` 与按 `ansiStateAt` 渲染出的 `TextSpan`；
- 上限 100：109 行不搬、110 行搬 1 次；`_head ≠ 0` 时 `lines.add` 抛 `UnsupportedError`（拷贝也必须只读）；
- 逐行 5 万行：逻辑上始终严格 1 万行，`0 < debugCompactions ≤ 50`（攒够了必须真搬，内存不能只涨不落）。

**7. 错误 vs 正确**

```dart
// ❌ 摊还裁剪（调研原案 R1）：上限浮动到 1.1 万，超了才一次裁回 1 万
final limit = holdTrim ? maxLines * 2 : maxLines + maxLines ~/ 10;
```

「最近 N 行」不再严格；更致命的是只要 LogView 有任何「跟随但锚点不滑」的状态，`droppedCount`
越过锚点后，每次成批裁剪都让下方列表从 11000 行一下缩到 10000 行，屏幕附近已建好的行
（下标都 ≥ 10000）被整体回收，`RenderSliverList` 只能从第 0 行重排到当前偏移：单帧 10,020 次
段落布局，JIT 4.4 秒、web profile 1.27 秒（核实实测）。#10 的原测试全绿，测不出来。

```dart
// ✅ 表头偏移（_trim）：逻辑上这一刻就裁好，物理上攒够一成再搬
final excess = length - maxLines;
_head += excess;
_droppedCount += excess;
if (_head >= maxLines ~/ 10) {
  _lines.removeRange(0, _head);
  _lineStarts.removeRange(0, _head);
  _head = 0;
}
```

配改前的 LogView 跑同一个越界场景，最差帧 11 ms / 56 次布局，所以它可以独立上线。

### 约定：跟随时锚点随尾部滑动（APP #15）

**是什么**：`_handleBufferChanged` 里，跟随中、手指不在屏幕上、也没有选区时，把锚点原地滑到
`max(droppedCount, totalCount - 200)`，下方列表始终只放最后 ≤ 200 行。各状态下来新行时：

| 状态 | 行为 |
|---|---|
| 跟随、无手势、无选区、`_glued`，且原点不变 | `_anchor = next` → `setState` → 帧后贴底 |
| 同上但 `!_glued`，或 `(next > dropped) != _centered`（短日志第一次超过 200 行，原点要换） | `_jumpToLatest()` 重建 |
| 手指在屏幕上（`_userScrolling`） | 锚点不动、不贴底，新行接在下方列表末尾 |
| 有选区（`_hasSelection`） | 同上，另外 `holdTrim = true`；`_following` 不变，不出「回到底部」按钮 |
| 不跟随（用户上翻） | 锚点不动，`_glued = false`，`holdTrim = true` |
| `generation` 变了（整段替换） | 跟随中 → `_jumpToLatest()`；否则把锚点夹进 `[dropped, total]`、原地不动 |

`_glued` 的意思是「下方列表恰好是最后 200 行」：跟随模式的 `_resetAnchor()` 置 true，
`_setFollowing(false)` 置 false，`_resumeAfterPause()` 发现下方超过 200 行时置 false。

**暂停结束**（手势的 `ScrollEndNotification`、选区清掉都走 `_resumeAfterPause`）：下方列表超过
200 行 → `_glued = false`；挪到帧后再判（滚动结束通知可能在布局中派发，选区回调也可能只是
「先清再全选」的中间一步）：不在底部 → `_jumpToLatest()`；还在底部 → 先 `_stickToBottom()`，
下一批新行来时因 `!_glued` 走重建。**禁止直接滑回 200 行**：下方列表一下缩短，已建好的行全被
回收、从第 0 行重排，滚动位置还落在新列表的底之外。

**选区保护**：`SelectionArea(onSelectionChanged: widget.follow ? _handleSelectionChanged : null)`，
`plainText` 非空才算有选区（点一下落个光标不算）；有选区时 `holdTrim = !_following || hasSelection`
——不暂缓的话缓冲区会裁过锚点，下方列表整体错位，选中的字照样会变。`_jumpToLatest()` 会把选中的行
一起回收、却不触发选区回调，所以它要**先**把 `_hasSelection` 置 false、复位 `holdTrim`，**再**
`_selectionAreaKey.currentState?.selectableRegion.clearSelection()`（清选区会同步回调，那时看到的
已是「无选区」）。

**为什么**：

- 锚点不动时新行全接在下方列表末尾，贴底一跳 `RenderSliverList` 要逐个排版跳过的每一行
  （一帧来 k 行就排 k 行），打开运行中任务时整段历史一下涌进来，单帧最长约 200 ms（JIT）。
  滑动之后来再多行也只重排屏幕附近那几十行（2 万行重放出帧合计 2037 → 186 ms，JIT）。
- 选区漂移已实测：锚点一滑，选区停在原来的屏幕行上，选中的字变成下一行的字，「复制」拿到的是错的。
- **不做滞回**（攒够一批才滑）：每次滑都是一次从零重排，约每 200 行一个 26~66 ms 的尖峰
  （web profile），比均匀的小代价更显眼。
- **代价如实记**：日志不到 1 万行时，每批新行都要重排一屏（测试视口约 56 行）而不是只排新来的
  几行，桌面 web profile 稳态帧耗时是改前的 1.45~2 倍（如 3.1 对 1.6 ms），超过 1 万行持平；
  用户自己滑回底部（没点按钮）后走重建路径，新行晚 2 帧出现（改前 1 帧）；有长行时偶尔要多等
  一帧校正。**手机没实测**，真机重点看：一直有输出的任务挂 5~10 分钟的发热掉帧（120Hz 一帧
  8.3 ms）、长按选择、拖滚动条。

**错误 vs 正确**

```dart
// ❌ 选区保护写成「仍跟随，只是有选区时不滑」，也不设 holdTrim
if (_following && !_userScrolling) {
  if (!_hasSelection) _anchor = next;
}
// 选区挂着时照样贴底，把选中的那几行带出屏幕；再来约 1 万行，缓冲区裁过锚点，
// 下方列表整体错位，选中的字跟着变。
```

```dart
// ✅ 有选区按「不跟随」处理：不滑、不贴底（_stickToBottom 同样判 _hasSelection）、暂缓裁剪
if (_following && !_userScrolling && !_hasSelection) { /* 滑锚点，或走 _jumpToLatest() */ }
widget.buffer.holdTrim = !_following || hasSelection;   // _handleSelectionChanged 里
```

测试写法见 [quality-guidelines.md](./quality-guidelines.md)「日志视图与实时日志页的测试约定」。

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

这个约定**执行得不彻底**：`flutter analyze` 仍有 **5 处** `use_build_context_synchronously`
（清单见 quality-guidelines.md「告警基线」）。新代码必须遵守，不得让这个计数上升。

> 这里原本写的是 4 处，与 quality-guidelines.md 的 5 对不上 —— 两份文档记同一个基线时必然会漂，
> **以 quality-guidelines.md 为准**，本文只引用不复制。

---

## 常见错误（本仓库真实发生过）

| 错误 | 后果 | 依据 |
|---|---|---|
| 编辑表单时用空 map 重建 config 再整串覆盖 | 面板支持但 APP 字段表里没有的键**保存即丢失** | `notification_list_page.dart:735-757`（对照正确做法 `open_api_page.dart:671` 保留未知 scope） |
| 后端默认值写死在表单里 | 面板改了默认 Python 版本，APP 不跟随 | 已修：`task_form_page.dart:223-266` 现在读 `default_version` |
| 请求 URL 直接拼字符串 | 绕过 `ApiEndpoints`，改路径时漏改 | **已修，全库零命中**。历史反例是 `system_settings_page` 里三处 `'${ApiEndpoints.baseApi}/system/...'`，现已收成 `ApiEndpoints.systemUpdateStatus` / `systemUpdate` / `systemRestart`（`api_endpoints.dart:23-27` 留了注释） |
