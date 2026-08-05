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
/// 当前取值 = 迁移前的既有取值，**本期不改变任何视觉**。
/// 第 1 期扁平化时把这里的常量调小（或归 0）即可全局生效。
class AppRadius {
  const AppRadius._();

  /// 极小色块：进度条、代码块、内联标记。原取值 4。
  static const double xs = 4;

  /// 小图标底、次级标签。原取值 8 / 9。
  static const double sm = 8;

  /// 内嵌块、输入框、普通按钮。原取值 10 / 12。
  static const double md = 12;

  /// 列表项卡片。原取值 12 / 14。
  static const double lg = 14;

  /// 区块级大卡片。原取值 16 / 18。
  static const double xl = 16;

  /// 弹窗 / 底部面板。原取值 20 / 24。
  static const double xxl = 20;

  /// 胶囊：筛选 chip、头部 chip 按钮。原取值 999。
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
}

extension AppSurfacesContext on BuildContext {
  /// `context.surfaces.card` 比 `AppSurfaces.of(context).card` 顺手。
  AppSurfaces get surfaces => AppSurfaces.of(this);
}
