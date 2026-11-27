// 设计令牌 —— 圆角 / 间距 / 字阶 / 动效 / 明暗表面色的唯一真源（v3.0 Nordic Calm）。

import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'app_theme.dart';

export 'app_palette.dart';

/// 圆角令牌（Nordic Calm 克制现代圆角体系，彻底告别 30dp 夸张气泡感）。
class AppRadius {
  const AppRadius._();

  /// 控件固定方框圆角（如 Checkbox 18dp 方框）。
  static const double control = 4;

  /// 微徽章 / 代码块 / 小方按钮。
  static const double sm = 8;

  /// 输入框 / 标准按钮 / 内嵌块 / 提示条 / 弹出菜单。
  static const double md = 12;

  /// 次级列表项卡片 / 弹窗内嵌容器。
  static const double lg = 16;

  /// 胶囊：状态胶囊、进度条、圆形触控波纹。
  static const double pill = 999;

  /// 区块级大卡片 / 分组列表容器 / 底部抽屉顶角（方案 1 `--r-card: 20px`）。
  static const double card = 20;

  /// 双列小卡片 / 行级独立卡片（方案 1 `--r-row: 16px`）。
  static const double cardSm = 16;

  /// 柔和图标容器基准圆角（按 46dp 基准缩放，36dp 时约 8.6dp）。
  static const double tile = 11;
}

/// 8pt 呼吸感网格间距令牌。
class AppSpacing {
  const AppSpacing._();

  static const double xxs = 4;
  static const double xs = 6;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;

  /// 页面统一左右呼吸留白（20dp）。
  static const double pageHorizontal = 20;

  /// 列表底部留白兜底常量（避开悬浮毛玻璃底栏）。
  static const double listBottom = 108;

  /// Tab 页列表底部动态留白：底栏与安全区实际高度 + 16dp 呼吸间距。
  static double listBottomOf(BuildContext context) =>
      MediaQuery.paddingOf(context).bottom + lg;
}

/// 悬浮毛玻璃底栏尺寸令牌。
class AppTabBarMetrics {
  const AppTabBarMetrics._();

  /// 底栏胶囊本体高度（轻盈紧凑，不挤压主内容视口）。
  static const double height = 58;

  /// 离屏幕底边的最小安全间距。
  static const double bottomGap = 10;

  /// 左右留白，与页面 20dp 网格对齐。
  static const double sideGap = 20;
}

/// 严格四阶字号与克制字重体系（方案 1 Nordic Calm：最高字重 w600，彻底消除老人机粗大字感）。
class AppText {
  const AppText._();

  /// 一级页面主标题（23pt w600，取代旧版夸张的 34pt w800）。
  static const TextStyle largeTitle = TextStyle(
    fontSize: 23,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.4,
    height: 1.25,
  );

  /// 区块小标题（「快捷场景」「全部任务」等，15pt w600）。
  static const TextStyle section = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    height: 1.35,
  );

  /// 卡片主标题（16pt w600）。
  static const TextStyle cardTitle = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.15,
    height: 1.35,
  );

  /// 标准正文与列表行标题（15pt w400/w500）。
  static const TextStyle body = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w400,
    height: 1.45,
  );

  /// 二级说明与列表副标题（13pt）。
  static const TextStyle caption = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    height: 1.4,
  );

  /// 三级辅助元数据与胶囊标签（11.5pt w500）。
  static const TextStyle meta = TextStyle(
    fontSize: 11.5,
    fontWeight: FontWeight.w500,
    height: 1.35,
  );

  /// 等宽数字：倒计时、耗时、百分比跳动时宽度恒定不抖动。
  static TextStyle tabular(TextStyle style) => style.copyWith(
    fontFeatures: const [FontFeature.tabularFigures()],
  );
}

/// 动效令牌。
class AppMotion {
  const AppMotion._();

  /// 系统无障碍「移除动画 / 减弱动态效果」。
  static bool reduce(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  static const Duration fast = Duration(milliseconds: 120);
  static const Duration normal = Duration(milliseconds: 220);
  static const Duration sheet = Duration(milliseconds: 340);
  static const Duration slide = Duration(milliseconds: 360);

  /// 柔和阻尼曲线（克制自然，不过度弹跳）。
  static const Curve spring = Cubic(0.22, 1.0, 0.36, 1.0);

  static Duration of(BuildContext context, Duration duration) =>
      reduce(context) ? Duration.zero : duration;
}

/// 最小可点命中区（44×44dp，符合 iOS HIG 与 WCAG 2.2 AA）。
class AppTapTarget {
  const AppTapTarget._();

  static const double min = 44;
}

/// 描边宽度令牌。
class AppBorderWidth {
  const AppBorderWidth._();

  static const double hairline = 1;
  static const double focus = 1.5;
}

/// 明暗表面色集中解析器（兼容次级页面并通过 `AppPalette` 统一驱动）。
@immutable
class AppSurfaces {
  final bool isLight;

  const AppSurfaces._(this.isLight);

  static const AppSurfaces light = AppSurfaces._(true);
  static const AppSurfaces dark = AppSurfaces._(false);

  static AppSurfaces of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.light ? light : dark;

  AppPalette get _p => isLight ? AppPalette.light : AppPalette.dark;

  Color get card => _p.card;

  /// 极淡微描边（浅色 5% 暖石色，深色 8% 柔白），赋予卡片干净的纸张边界。
  Color get cardBorder =>
      isLight ? const Color(0x0D1C1917) : const Color(0x14FFFFFF);

  /// 悬浮底栏的投影：比 [softShadow] 更深、更收（spread -6），让玻璃底栏浮在列表上方。
  List<BoxShadow> get tabBarShadow => [
    BoxShadow(
      color: isLight ? const Color(0x140F172A) : const Color(0x47000000),
      blurRadius: 28,
      spreadRadius: -6,
      offset: const Offset(0, 10),
    ),
  ];

  /// 极轻弥散阴影（仅用于白色浮层卡）。
  List<BoxShadow> get softShadow => isLight
      ? const [
          BoxShadow(
            color: Color(0x090F172A),
            blurRadius: 20,
            offset: Offset(0, 4),
          ),
        ]
      : const [
          BoxShadow(
            color: Color(0x3D000000),
            blurRadius: 24,
            offset: Offset(0, 6),
          ),
        ];

  Color get subtle => _p.card2;
  Color get subtleBorder => _p.separator;
  Color get page => _p.bg;

  Color get mutedText => _p.text2;
  Color get strongText => _p.text;

  Color get disabledFg => _p.text3;
  Color get disabledBg => _p.card2;
  Color get disabledBorder => _p.separator;

  Color tintBg(Color color) => color.withAlpha(isLight ? 20 : 32);
  Color tintBorder(Color color) => color.withAlpha(isLight ? 52 : 84);
  Color tintBgStrong(Color color) => color.withAlpha(isLight ? 28 : 42);

  Color tintFg(Color color) {
    if (!isLight) {
      return color;
    }
    return Color.lerp(color, Colors.black, 0.22)!;
  }

  Color solidBg(Color color) =>
      isLight ? Color.lerp(color, Colors.black, 0.35)! : color;

  Color get solidFg => isLight ? Colors.white : AppColors.slate950;
}

extension AppSurfacesContext on BuildContext {
  AppSurfaces get surfaces => AppSurfaces.of(this);
}
