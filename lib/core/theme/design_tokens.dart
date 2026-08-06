// 设计令牌 —— 圆角 / 间距 / 描边 / 明暗表面色的**唯一定义处**。
//
// 为什么需要它：
// 改造前全库有 149 处手写 `BorderRadius.circular()`（11 种取值：4/8/9/10/12/14/16/18/20/24/999）、
// 134 处手写 `BoxDecoration(`、507 行手写 `final isLight = ...` 后逐处三元。
// 真正走 Flutter `Card` 的只有 6 处，所以把 `app_theme.dart` 的 `cardTheme`
// 圆角改成 0，界面上 96% 的卡片**不会有任何变化**。
//
// 本文件把这些散落的数值收成常量，配合 `lib/shared/widgets/` 下的基元组件，
// 让第 1 期全面扁平化变成「改这里一处」而不是「逐页面改 140 处」。

import 'package:flutter/material.dart';

import 'app_theme.dart';

/// 圆角令牌。
///
/// 提交 12 之后全库已无散装圆角字面量，**每一处圆角都由本文件的常量供给**，
/// 所以「改这里一处全局生效」从这一刻起才是真的。
///
/// 分档依据是**角色**，不是数值 —— 按数值一刀切会踩两个坑：
/// 1. **嵌套**：图标底板原本写 12/14，与包着它的卡片（14）几乎相等甚至相同，
///    换算过去就成了「内层的角比外层还圆」。所以图标底板一律降到 [sm]，
///    与外层拉开一档。
/// 2. **clamp**：Flutter 画圆角时会把半径截到边长的一半。高 6 的进度条写 4、
///    高 31 的 chip 写 20，渲染出来本来就是胶囊，它们归 [pill] 是零像素变化。
///
/// 当前的角色归属（提交 12 落定）：
/// - [control] —— Checkbox。唯一的**控件**档，不跟表面一起收缩。
/// - [sm] —— 图标底板、微徽章、代码块、小方按钮。
/// - [md] —— 输入框、按钮、内嵌块、提示条、弹出菜单、左滑操作按钮。
/// - [lg] —— 列表项卡片、区块级大卡片、弹窗、底部面板、主视觉 logo。
/// - [pill] —— chip、胶囊徽章、进度条、圆形水波纹。
///
/// [xs] / [xl] / [xxl] 已无引用，提交 13 删除。
class AppRadius {
  const AppRadius._();

  /// **控件**圆角（目前只有 Checkbox）。取值 4，且**不参与** sm/md/lg 的整体收缩。
  ///
  /// 为什么单独一档而不是折进 [sm]：sm/md/lg/pill 描述的是「表面」——
  /// 卡片、内嵌块、徽章、chip，它们的共同点是尺寸由内容撑开，几十到几百 dp。
  /// Checkbox 是**控件**，方框恒定 18dp，`shape` 的半径直接就是它一半宽度的比例：
  /// r=4 占 22%，r=8（sm）占 44% —— 已经接近圆形。把它折进 sm 的结果是
  /// 「扁平化提交把勾选框改圆了」，与本期方向相反；提交 13 把 sm 压到 6
  /// 也仍有 33%，救不回来。
  ///
  /// 4 不是新造的第 12 种取值：它本来就在改造前的 11 种直方图里
  /// （`login_page` 的「记住我」与 `log_list` 的多选框），这里只是给它一个名字，
  /// 并顺手把另外 7 个走 Material 默认值（约 2dp）的 Checkbox 拉齐到同一档。
  ///
  /// ⚠️ [xs] 同样是 4 但全库零引用，提交 13 会删除它；本档是**有引用**的那一个，
  /// 两者不要合并 —— [xs] 的语义是「最小的表面」，本档的语义是「控件」。
  static const double control = 4;

  /// 零引用，提交 13 删除。语义与 [control] 重叠但角色不同，见 [control]。
  static const double xs = 4;

  /// **图标底板 / 微徽章 / 代码块 / 小方按钮**。原取值 4 / 8 / 9 / 10 / 12 / 14。
  ///
  /// 这一档吃掉的原值跨度最大，因为它收编的是两类东西：
  /// - 26–46dp 的**图标底板**（原来 8～14 各写各的）。它们必须比包着自己的
  ///   卡片小一档，否则内外两个角一样大 —— 这是提交 12 里最容易改错的一类。
  /// - fontSize 9–10 的**微徽章**（原来一律 4）。
  ///
  /// ⚠️ 微徽章高度只有 12–14，本档的 8 会被 clamp 到高的一半，
  /// 它们实际渲染成胶囊。这是已知且可接受的：写 [pill] 也是同一个结果，
  /// 但那会谎称「设计上它是 chip」。提交 13 把本档压到 6 也改变不了这件事。
  static const double sm = 8;

  /// **输入框 / 按钮 / 内嵌块 / 提示条 / 弹出菜单**。原取值 8 / 10 / 12 / 14。
  ///
  /// 输入框这一支尤其要整档统一：`inputDecorationTheme` 的
  /// border / enabledBorder / focusedBorder 是靠插值做聚焦动画的，
  /// 三者圆角不一致会在点进输入框的那一帧看到角在抖。
  static const double md = 12;

  /// **列表项卡片 / 区块级大卡片 / 弹窗 / 底部面板 / 主视觉 logo**。
  /// 原取值 12 / 14 / 16 / 20。
  ///
  /// 「浮在页面之上的容器」（Dialog、BottomSheet）与「铺在页面里的卡片」
  /// 合并到同一档：它们不会同时出现在一个视觉层级里，分两档只会多一个
  /// 需要维护的数字。
  static const double lg = 14;

  /// 零引用，提交 13 删除（原语义「区块级大卡片」已并入 [lg]）。
  static const double xl = 16;

  /// 零引用，提交 13 删除（原语义「弹窗 / 底部面板」已并入 [lg]）。
  static const double xxl = 20;

  /// **胶囊**：chip、状态徽章、进度条、圆形水波纹。原取值 4 / 10 / 20 / 999。
  ///
  /// 4 / 10 / 20 那几处不是写错了，是**写得不诚实**：半径超过边长一半时
  /// Flutter 会 clamp，它们渲染出来一直就是胶囊。改成本档是零像素变化。
  ///
  /// ⚠️ 第 1 期扁平化时这一项要**单独决定**：跟着归 0 会让所有 chip 变成方块，
  /// 未必是想要的效果。
  static const double pill = 999;
}

/// 间距令牌。取值来自现有页面里出现频率最高的那几档。
class AppSpacing {
  const AppSpacing._();

  static const double xxs = 4;
  static const double xs = 6;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;

  /// 列表页左右留白。全库列表页统一是 20。
  static const double pageHorizontal = 20;

  /// 列表底部留白，避开悬浮的底部导航栏。全库统一是 100。
  static const double listBottom = 100;
}

/// 描边宽度令牌。
class AppBorderWidth {
  const AppBorderWidth._();

  /// 卡片 / chip 的常规描边。
  static const double hairline = 1;

  /// 聚焦态描边（输入框等）。
  static const double focus = 1.5;
}

/// 明暗两套表面色的集中解析点。
///
/// 收敛掉页面里 `final isLight = Theme.of(context).brightness == Brightness.light;`
/// 之后逐处写三元的模式（改造前 507 行）。
///
/// 用法：
/// ```dart
/// final s = AppSurfaces.of(context);
/// Container(
///   decoration: BoxDecoration(color: s.card, border: Border.all(color: s.cardBorder)),
/// );
/// ```
@immutable
class AppSurfaces {
  /// 直接暴露出来，是为了让**尚未迁移**的页面能继续用它做局部三元，
  /// 而不必再写一遍 `Theme.of(context).brightness == ...`。
  final bool isLight;

  const AppSurfaces._(this.isLight);

  static const AppSurfaces light = AppSurfaces._(true);
  static const AppSurfaces dark = AppSurfaces._(false);

  static AppSurfaces of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.light ? light : dark;

  // ── 表面 ──────────────────────────────────────────────

  /// 卡片底色。原写法：`isLight ? Colors.white : AppColors.slate900`。
  Color get card => isLight ? Colors.white : AppColors.slate900;

  /// 卡片描边。原写法：`isLight ? AppColors.slate200 : AppColors.slate800`。
  Color get cardBorder => isLight ? AppColors.slate200 : AppColors.slate800;

  /// 卡片内嵌的次级浅底块。原写法：`isLight ? AppColors.slate50 : AppColors.slate800`。
  Color get subtle => isLight ? AppColors.slate50 : AppColors.slate800;

  /// 次级块的描边。原写法：`isLight ? AppColors.slate200 : AppColors.slate700`。
  Color get subtleBorder => isLight ? AppColors.slate200 : AppColors.slate700;

  /// 页面底色。
  Color get page => isLight ? AppColors.slate50 : AppColors.slate950;

  // ── 文字 ──────────────────────────────────────────────

  /// 次级说明文字。
  Color get mutedText => isLight ? AppColors.slate500 : AppColors.slate400;

  /// 正文强调文字。
  Color get strongText => isLight ? AppColors.slate800 : AppColors.slate100;

  // ── 禁用态 ────────────────────────────────────────────

  Color get disabledFg => AppColors.slate400;
  Color get disabledBg => isLight ? AppColors.slate50 : AppColors.slate800;
  Color get disabledBorder =>
      isLight ? AppColors.slate200 : AppColors.slate700;

  // ── 强调色的淡底 ──────────────────────────────────────

  /// 强调色淡底。原写法：`isLight ? color.withAlpha(18) : color.withAlpha(24)`。
  Color tintBg(Color color) => color.withAlpha(isLight ? 18 : 24);

  /// 强调色淡底描边。原写法：`color.withAlpha(isLight ? 60 : 90)`。
  Color tintBorder(Color color) => color.withAlpha(isLight ? 60 : 90);

  /// 更实一档的强调色淡底（滑动操作按钮等）。
  Color tintBgStrong(Color color) => color.withAlpha(isLight ? 24 : 34);

  /// 压在 [tintBg] / [tintBgStrong] 上的**前景**（徽章文字、状态图标）。
  ///
  /// 为什么需要它：淡底只有 alpha=18，调用方却拿**同一个满强度色**当前景，
  /// 于是前景和背景是同一个色相、只差透明度 —— 数学上封顶就那么高。
  /// 白底实测：primary 2.60:1、danger 3.43:1、success 2.13:1、warning 2.04:1。
  /// 错的不是淡底，是前景没跟着加深。
  ///
  /// 为什么选「向黑混 20%」而不是 HSL 压亮度、也不是按目标对比度反解：
  /// 1. 它**逐字节复现** [AppColors.primaryDark] 与 [AppColors.successDark]。
  ///    这两个常量取自 Element Plus 的 `dark-2`，而 `dark-2` 的定义就是
  ///    `mix(color, black, 20%)`：0.8×#409EFF=#337ECC、0.8×#67C23A=#529B2E。
  ///    于是已经手写 `*Dark` 的那批徽章（任务 / 依赖 / 订阅的 `_statusFg`）
  ///    与走本函数的徽章**不会分裂成两种蓝、两种绿**，也不必回头去改它们。
  /// 2. 加深规则与面板 Web 端同源，不是 APP 自造的第三套。
  /// 3. HSL 压亮度会保留 S=1.0，primary 会掉到 #005FC2 这种全饱和深蓝，
  ///    比面板深一大截；按对比度反解要在每帧迭代，产出的颜色还无法预测。
  ///
  /// 加深后（白底 + alpha=18，全库最坏情况）：
  ///   primary/info #409EFF → #337ECC   2.60:1 → 3.93:1
  ///   success      #67C23A → #529B2E   2.13:1 → 3.27:1
  ///   danger       #EF4444 → #BF3636   3.43:1 → 5.03:1
  ///   warning      #F59E0B → #C47E09   2.04:1 → 3.14:1
  /// 五个语义色全部越过 3:1，但只有 danger 越过 4.5:1。10px 加粗按 WCAG
  /// 不算大字，严格说该要 4.5:1 —— warning 是最短板，补齐要动全局常量，不在本次范围。
  ///
  /// 深色模式**原样返回**：那边淡底是 alpha=24 叠在 slate900/950 上，
  /// 满强度前景本来就有 5.6:1（primary）/ 6.9:1（success），再压只会更糊。
  Color tintFg(Color color) {
    if (!isLight) {
      return color;
    }
    return Color.lerp(color, Colors.black, 0.2)!;
  }

  // ── 强调色的实底 ──────────────────────────────────────

  /// 强调色**实底**（满铺，不是 [tintBg] 那种 alpha=18 的淡底）。目前用于提示条。
  ///
  /// 为什么明暗两套方向相反，而不是像 [tintFg] 那样深色模式直接返回原色：
  /// SnackBar 的默认底色是 `ColorScheme.inverseSurface`，语义就是「与页面相反」——
  /// 浅色模式给深底浅字、深色模式给浅底深字。语义色必须跟上这个方向，否则
  /// 深色模式下一条压深了的提示条会比页面还暗，边界糊掉：实测把浅色模式那支
  /// 深绿 #3E7423 摆到 slate950 页面上只有 2.42:1，连非文字元素的 3:1 都不到。
  ///
  /// 浅色模式用 `mix(color, black, 40%)`，与 [tintFg] 的 20% 是同一套配方，
  /// 只是压得更深 —— 因为这里白字压的是满强度实色，20% 不够：
  /// success 压到 #529B2E 配白字只有 3.45:1、info 压到 #337ECC 只有 4.20:1，
  /// 都过不了正文所需的 4.5:1。40% 之后 success 5.61 / danger 8.33 / warning 5.42。
  Color solidBg(Color color) =>
      isLight ? Color.lerp(color, Colors.black, 0.4)! : color;

  /// 压在 [solidBg] 上的前景文字色。
  ///
  /// 深色模式配满强度底：success 8.99:1、danger 5.36:1、warning 9.39:1。
  /// 这里用 slate950 而不是 slate900，是因为 danger #EF4444 是三支里**最暗**的底，
  /// 配 slate900 只剩 4.74:1，刚压着 4.5 的线；换 slate950 拉回 5.36:1 才有余量。
  Color get solidFg => isLight ? Colors.white : AppColors.slate950;
}

extension AppSurfacesContext on BuildContext {
  /// `context.surfaces.card` 比 `AppSurfaces.of(context).card` 顺手。
  AppSurfaces get surfaces => AppSurfaces.of(this);
}
