# 第 1 期开工前基线（主会话实测，非推断）

测量时间：2026-08-06，commit `8d2c575`。

## 工具链基线

```
flutter analyze  -> 7 个 info，0 warning，0 error
flutter test     -> 28 个用例全过
```

7 个 info 的精确清单（用于判断「有没有新增」，只看总数会漏掉「修好一个又新增一个」）：

| 文件:行 | 规则 |
|---|---|
| notification_list_page.dart:829:40 | use_build_context_synchronously |
| open_api_page.dart:838:38 | use_build_context_synchronously |
| script_list_page.dart:2780:50 | use_build_context_synchronously |
| security_page.dart:915:38 | use_build_context_synchronously |
| user_list_page.dart:490:40 | use_build_context_synchronously |
| user_list_page.dart:68:14 | library_private_types_in_public_api |
| user_list_page.dart:73:32 | library_private_types_in_public_api |

> 注意 spec 的 quality-guidelines.md 表格把 7 个拆成「4 + 2 + 1 同类 info」，
> 实测是 **5 个 `use_build_context_synchronously` + 2 个 `library_private_types_in_public_api`**。
> 那个「同类 info 1」是含糊记法，本期顺手在 spec 里改准确。

## 圆角实测直方图（140 处，11 种取值）

| r | 处数 | | r | 处数 |
|---|---|---|---|---|
| 4 | 9 | | 14 | 24 |
| 8 | 7 | | 16 | 17 |
| 9 | 1 | | 18 | 2 |
| 10 | 13 | | 20 | 3 |
| 12 | **48** | | 24 | 1 |
| | | | 999 | 15 |

12 / 14 / 16 三档就占 89 处（64%）。r=9 与 r=24 各只有 1 处，是纯粹的手滑。

## 其它实测计数

| 项 | 数 |
|---|---|
| `boxShadow` 站点 | 12（`BoxShadow` 文本 24 次 = 12 属性 + 12 构造） |
| `LinearGradient` | 2（dashboard_page.dart:410、login_page.dart:245） |
| `BoxDecoration(` | 135 |
| `AppCard(` 已接入 | 9 |
| `isLight` 出现 | 560 |
| `Colors.` 出现 | 1039 |
| 裸 `Color(0x........)` | app_theme 33（定义处，正当）/ ansi_text 28（终端调色板，出范围）/ **script_list_page 2（违反 spec）** |

最大的几个文件：task_list 2912、script_list 2699、env_list 2090、dep_list 1690、
subscription_list 1688、backup 1371、open_api 1232 行。

---

## 对我自己第 1 期计划表述的两处更正

第 1 期原话是「去掉仪表盘的渐变 / 装饰圆 / **环形仪表盘**」。核对代码后两处要改：

### ★ 更正 1：`task_stats_card.dart` 里没有环形仪表盘

它已经是扁平的 4+2 数字网格，而且**语义色在第 0 期就已经改对了**——
文件 :46-48 的注释明确写了「改造前前三个分别是 primary / primary / blue500，
主色换蓝后全成了蓝色系」，现在是 总任务=中性 / 已启用=success / 运行中=info / 已禁用=slate400。
**这个文件本期不需要动配色。**

### ★ 更正 2：环形仪表盘在 `resource_card.dart`，而且不是 CustomPaint

全库 `CustomPaint` / `drawArc` / `SweepGradient` **零命中**——没有手绘仪表盘。
真正的「环」是 `resource_card.dart:34` 用 `CircularProgressIndicator` 拼的：
56×56 的环 + 环心里再写一遍同一个百分比数字。

这是本期最干净的一刀：**环和文字编码的是同一个数**，属于纯冗余；
而且 56 + 10 + 标题 + 副标题 ≈ 100dp 高度只为了显示一个百分比。
换成横向细条 + 数字，比例信息一点不丢，高度约减半。

---

## 测试能保护到第 1 期改动的哪一部分（如实说）

**几乎保护不到。** 28 个用例覆盖的是 401 续期、列表 error 语义、通知渠道配置合并，
以及 `AppErrorView` / `AppEmptyView` 的渲染差异。

- 会被抓到：改坏 `AppErrorView` / `AppEmptyView`（widget_test 3 条）
- 抓不到：圆角、阴影、渐变、间距、配色、密度——**全部视觉改动对测试不可见**

所以第 1 期的验收不能只靠 `flutter analyze` + `flutter test` 绿灯。
凡是本期改动，必须明确区分「机械等价改写」与「有意的视觉变更」，
后者只能靠人眼在真机上确认，不能声称已验证。
