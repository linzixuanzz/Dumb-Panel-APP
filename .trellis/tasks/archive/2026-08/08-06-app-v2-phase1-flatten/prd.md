# 第 1 期：UI 扁平化

## 目标

用户原话：**「UI 方面需要减少花里胡哨的东西，一切以简洁干净为主」**。

第 0 期建了令牌层与共享组件层但**几乎没接线**（`features/` 下 0 处引用），
第 1 期是把它真正用起来、并把界面压平的一期。

## 权威文档

| 文件 | 作用 |
|---|---|
| `baseline.md` | 开工前实测基线（analyze 7 info 的精确清单、圆角直方图、各项计数） |
| `research/merged-plan.md` | **13 个提交的裁决版实施计划**，含冲突归属表与顺序不变式 |
| `research/premise-corrections.md` | 六个探测对原始 brief 的前提更正（含多条「你说错了」） |

冲突以 `merged-plan.md` 为准。

---

## 硬约束（来自 spec/frontend/quality-guidelines.md）

1. `flutter analyze` **不得超过 7 个 info**，且不得出现新类型。
2. `flutter test` 全绿（28 个用例）。
3. **不得新增第 12 种圆角取值**；本期是往下收敛。
4. 禁止裸 `Color(0xFF...)`（`app_theme.dart` / `ansi_text.dart` 除外）。
5. 禁止用 `AppColors.primary` 表达「成功 / 已启用 / 在线」。
6. UI 文案、注释、提交信息一律中文。
7. `await` 之后碰 `context` 先判 `mounted`。

---

## 顺序不变式（违反会导致返工或编译失败）

1. 迁移到 `AppCard` 的站点，**不许**再单独改它的 `borderRadius / boxShadow / margin / padding`
   —— 这些一律变成 AppCard 参数。
2. 新写的圆角一律走 `AppRadius`，且**只许用 `sm / md / lg / pill` 四个名字**。
   `xs / xl / xxl` 全库 0 引用，提交 13 会删除它们；迁移期写了会编译失败。
3. 提交 8/9 的 AppCard 迁移必须把提交 7 调好的 margin/padding 数值**原样搬进** AppCard 参数，
   禁止「顺手恢复」成原值。
4. 提交 12（圆角逐站点）的范围**已剔除全部 60 个 AppCard 站点**。
5. 同一文件内多处修改**从文件末尾往前改**；跨提交须重新定位行号。

---

## 分波实施

### 第一波 —— 纯收益，无判断题（提交 1/2/3/5/6/4）

| # | 标题 | 风险 |
|---|---|---|
| 1 | 删除从未被引用的 `ResourceCard` 与死配置 `navigationBarTheme` | 无 |
| 2 | 移除全部装饰性投影与 Material elevation（12 boxShadow + 3 elevation + 1 theme） | 中 |
| 3 | 无底部导航栏的 13 个页面不再为其留 100dp 死留白 | 低 |
| 5 | 淡底徽章前景色令牌化 `tintFg()`，修 11 处低于 3:1 的对比 | 中 |
| 6 | primary 不再表示「成功 / 已启用 / 在线」（约 27 处） | 中高 |
| 4 | `AppSnack` 增加语义 tone，36 处失败提示不再是灰的 | 中 |

> 提交 5 **必须先于**提交 6 落地：否则 22 处语义换色会让部分徽章更难读
> （success 在淡底上只有 2.11:1，比现在的 primary 2.60:1 还差）。

### 第二波 —— 结构性重构（提交 7/8/9/10/12）

| # | 标题 | 风险 |
|---|---|---|
| 7 | 列表行密度收紧（纯 padding / margin / 间隙，约 22 处） | 中 |
| 8 | 内联卡片形 BoxDecoration 迁移到 AppCard（第一批：无交互，约 26 站点） | 中 |
| 9 | AppCard 迁移第二批（交互态 / ReorderableListView key / 零内边距，约 19 站点） | **高** |
| 10 | 12 处淡底提示条抽成 `AppNotice` | 中 |
| 12 | 圆角逐站点归档到三档（约 70 处） | 中 |

### 第三波 —— 需要用户拍板（提交 11/13）

判断题已全部拍板，下表是**实际落地的内容**（原始待决项与被否决项一并留档，
见下方「拍板记录」—— 记录被否决过什么本身有价值，不要删）。

| # | 实际做了什么 |
|---|---|
| 11 | 仪表盘服务器卡去渐变 + 删装饰圆（顺带修掉一处硬裁切渲染缺陷）+ 迁 `AppCard`；内存不可用时进度条不再无限扫动；折线图去曲线平滑 + 去面积填充；登录页去渐变背景（整层删除，交回 Scaffold）+ logo 双层圆角底收成单层；加载态与 4 个小标题收敛到共享组件 |
| 13 | 删除零引用的 `AppRadius.xs / xl / xxl`，档位定为 `control / sm / md / lg / pill` 五档；**取值一个不改**，纯编译期改动 |

#### 拍板记录

| 原始待决项 | 结论 |
|---|---|
| 折线图去曲线平滑 + 去面积填充 | ✅ 采纳，两项都做 |
| 圆角取值：保守版 `8/12/14` vs 激进版 `6/10/12` | ✅ 定保守版 = **当前值**，提交 13 不动任何取值 |
| 资源卡去掉 32×32 着色底板 | ❌ **用户否决**，底板保留。去掉会让 CPU / 内存 / 磁盘三张卡只剩进度条颜色可区分 |
| 「在线」圆点变绿 | ⚠️ **已在提交 6（primary 语义修正）完成**，不属于本提交范围。⚠️ 但它「不绑定任何连接或健康状态、永远亮着」这件事**仍未修**，见文末 |
| 加深语义色常量（含 `successDark`） | ❌ **用户否决**，`successDark` 保持 Element Plus 的 `#529B2E`，`app_theme.dart` 颜色值一个不动 |
| `task_stats_card` 删「已禁用」 | ❌ 本期不做。`disabledTasks` 虽是算出来的，但删它属于删信息，需单独确认 |

---

## 验收标准

### 能自动验证的

- `flutter analyze` ≤ 7 info，类型与 `baseline.md` 的清单一致
- `flutter test` 28 个全过
- `grep -rn "boxShadow" lib/` 返回 0（提交 2 后）
- `grep -rn "ResourceCard" lib/` 返回 0（提交 1 后）
- 全库无 `AppColors.primary` 表达「成功/已启用/在线」（提交 6 后）
- `grep -rn "LinearGradient" lib/` 返回 0（提交 11 后）
- `grep -rn "AppRadius\.\(xs\|xl\|xxl\)" lib/` 返回 0，且 `AppSpacing.xs/xl`
  的 4 处引用**仍在**（提交 13 后；两者同名不同类，是最容易误删的一处）

### **不能**自动验证的（必须真机，不得声称已验证）

1. 全部对比度数字是算出来的，不是在屏幕上量的
2. 中文字形行高（密度估算用的是 Roboto 度量，中文回退字体可能到 1.4×，
   **省下的 dp 是精确的，每屏行数不是**）
3. 嵌套 Scaffold 是否双发 SnackBar（改红之后才会刺眼）
4. 两个 Autocomplete 浮层去 elevation 后有没有边界
   （`env_list:327` / `task_form:912`，全库仅有的两处「阴影是唯一分隔物」）
5. 深色模式下应用锁模态删投影 + 砍圆角后还立不立得住
6. 9 处 `GestureDetector → AppCard` 新增水波纹的观感
7. 仪表盘 Stack 折叠后的布局等价性（**推断，非观察**）。推断依据：Column 原先在
   `StackFit.loose` 下就已被两个 `mainAxisSize.max` 的 Row 撑满整行宽，换成紧约束
   宽度不变。**该推断失效的唯一条件**是将来有人把其中一个 Row 改成 `mainAxisSize.min`
8. `ReorderableListView` 的 key 有没有掉 —— **analyze 看不出来，运行时才抛 assert**
9. 系统字号 1.3× 下的表现
10. 折线图去曲线 + 去面积填充后会不会显得太空 —— **本期最可能被说「弄丑了」的一处**。
    若要回退，**先恢复面积填充**（纯观感），曲线平滑留到最后（它在数据上撒谎：
    每日整数计数之间不存在中间值，且 `dotData` 关着，读者无从校验）
11. 登录页 logo 从「56 底板 + 40 图标」变成 56 满幅图标，**视觉上明显变大**，
    这是预期结果不是 bug
12. 4 个仪表盘小标题收敛到 `AppSectionTitle` 后 fontSize 13→12、并右移 2dp
    （组件自带 `left: 2`），是收敛到共享组件的必然代价

> 28 个测试覆盖的是 401 续期、列表 error 语义、通知渠道配置合并。
> **圆角/阴影/渐变/间距/配色/密度对 `flutter test` 全部不可见。**
> 绿灯只能证明没改坏逻辑，不能证明界面对。

---

## 本期明确剔除（附理由）

| 剔除项 | 理由 |
|---|---|
| 主按钮底色 `primary → primaryDark` | 与第 0 期对齐面板 Element Plus 的方向相反；旧 emerald 是 2.54:1 **更差**，主色切换是改善不是破坏，属继承缺陷 |
| `main_scaffold:156` 导航项提到 48dp | 底栏会从 48.5 长到 60.5，与密度目标方向相反 |
| `listBottom` 改成 MediaQuery 运行时函数 | 底部留白不影响每屏行数，零密度收益，却把 6 处 const 变非 const |
| `env_list:2069` maxLines 2→1、删订阅仓库 URL | 这是删信息不是删装饰，需用户签字 |
| 13 处 DropdownButton `elevation: 8` | legacy 菜单路由不画边框、不暴露 shape，去 elevation 会得到无边界浮板。正解是迁 `DropdownMenu`，属重构 |
| 118 处裸 `showSnackBar(` 迁移 | 单列 backlog |
| 删除 15 处冗余 `OutlineInputBorder`（令牌化仍做） | 「theme 已供同色」无实证支撑 |
| 8 个重复的头部「+」圆钮抽公共组件 | 属组件化不属扁平化 |
| 6 处 48dp 以下点击区 | 本次修改**之前就存在**；修它们要还回密度。另立 a11y backlog |

## 附带发现的真 bug（不在本期范围，另开条目）

- **`dashboard_page` 从不读 `data.error`**：`dashboard_provider.dart:129` 会设
  `error: '加载失败'`，页面只在头像的 `errorBuilder` 里出现过 error 字样。
  加载失败时把 CPU 0% / 内存 0% / 主机名 `-` **当作测量值渲染**。
  `AppErrorView` 已存在（`app_state_views.dart:73`）却没用上。
- **`_ServerInfoCard` 里主机名前的「在线」圆点不绑定任何状态**，永远亮着。
  提交 6 已经把它从 primary 改成 success（颜色语义对了），但「它根本不表示在线」
  这件事**仍未修** —— 面板不可达、接口报错时它照样常亮。要真修得接
  `dashboardProvider` 的 error / 心跳状态，属行为改动，不在本期。
  代码处已留 ⚠️ 注释，别当它已经修好了。
