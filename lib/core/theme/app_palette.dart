import 'package:flutter/material.dart';

/// v2.0 语义色板（方案书 §2.3，iOS 26 干净留白方向）。
///
/// 组件一律 `context.palette.xxx` 取色，不再写 `Color(0x…)` / `Colors.*`
/// （插画、图表系列色这类「不是界面色」的例外，要在旁边写注释）。
///
/// 规则只有两条：
/// 1. **界面本身是黑白灰**：底色 / 卡片 / 文字 / 分隔线 / 主按钮。
/// 2. **颜色只给数据**：成功、失败、运行中、警告这些状态才上色。
///    状态色当**文字**时必须用对应的 `xxxInk`（保证 ≥ 4.5:1），
///    实色（[ok] / [err] …）只给图标、圆点、图表、进度条。
///
/// 浅深两套取值写死在 [light] / [dark] 里，由 `AppTheme` 挂进 `ThemeData.extensions`。
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.bg,
    required this.card,
    required this.card2,
    required this.fill,
    required this.thumb,
    required this.text,
    required this.text2,
    required this.text3,
    required this.separator,
    required this.accent,
    required this.ok,
    required this.err,
    required this.warn,
    required this.purple,
    required this.accentInk,
    required this.okInk,
    required this.errInk,
    required this.warnInk,
    required this.purpleInk,
    required this.onStatus,
    required this.primaryBtnBg,
    required this.primaryBtnFg,
    required this.glass,
    required this.glassBorder,
  });

  /// 页面底色（与 iOS 分组背景一致）。
  final Color bg;

  /// 内容卡片底色：无边框、无阴影，靠和 [bg] 的明度差分层。
  final Color card;

  /// 卡片里再嵌一层的不透明浅底（代码块、内嵌统计格子）。
  /// 与 [fill] 的区别：[fill] 是半透明的，叠在什么上面颜色就跟着变；这个是实色。
  final Color card2;

  /// 次级填充（半透明）：分段控件底槽、搜索框、次要按钮、底栏选中药丸。
  final Color fill;

  /// 分段控件的滑块（浅色是白，深色是 iOS 的 #636366，否则深色下看不出选中）。
  final Color thumb;

  /// 正文。
  final Color text;

  /// 次要文字。浅色模式对 [card] / [bg] 都 ≥ 4.5:1（见下方 [light] 的说明）。
  final Color text2;

  /// 弱化文字：只给非关键信息（占位、时间戳尾巴、箭头），对比度不到 4.5:1。
  final Color text3;

  /// 列表分隔线（发丝线）。
  final Color separator;

  /// 强调色：系统蓝。用于链接、选中态、可点的图标，不用于大面积底色。
  final Color accent;

  /// 状态实色：成功。
  final Color ok;

  /// 状态实色：失败 / 危险。
  final Color err;

  /// 状态实色：警告 / 已终止。
  final Color warn;

  /// 状态实色：紫（运行中以外的第二种「进行态」、图表第二系列）。
  final Color purple;

  /// 「墨色」：状态色当**文字**时用。
  ///
  /// 浅色模式里 iOS 的状态色当字太浅（白底上绿 2.2:1、橙 2.2:1），
  /// 这里按「向正文色（黑）混合」压深到对 [card] 和 [bg] 都 ≥ 4.5:1 为止；
  /// 深色模式的状态色本身就够亮，墨色等于实色。混合比例是离线算好写死的，
  /// 不在运行时反解 —— 每帧迭代既浪费，产出的颜色也无法预测。
  /// `test/core/theme/app_palette_test.dart` 逐个钉住了对比度。
  final Color accentInk;
  final Color okInk;
  final Color errInk;
  final Color warnInk;
  final Color purpleInk;

  /// 状态实色上的文字（徽标数字、实色小标签）。
  ///
  /// 两种模式都是白：与 iOS 徽标一致。白字压在绿 / 橙上对比度不到 3:1，
  /// 所以**只给粗体短标签用**，不要拿它在状态实色上排正文。
  final Color onStatus;

  /// 主按钮：浅色黑底白字，深色白底黑字（方案书「主操作永远是黑色胶囊」）。
  final Color primaryBtnBg;
  final Color primaryBtnFg;

  /// 玻璃底（半透明，配 `BackdropFilter` 用）：底栏、右上角圆形按钮。
  final Color glass;

  /// 玻璃的内描边。
  final Color glassBorder;

  /// 浅色。取值来自方案书 §2.3 / `APP效果演示.html` 的 `[data-mode="light"]`。
  ///
  /// ⚠️ 唯一偏离方案书的一处：[text2] 用 `#6E6E73` 而不是 iOS 的 `#8A8A8E`。
  /// `#8A8A8E` 在白卡片上只有 3.44:1、在 `#F2F2F7` 底上只有 3.08:1，
  /// 过不了 PRD 「正文与次要文字 ≥ 4.5:1」。`#6E6E73` 是 5.07:1 / 4.54:1，
  /// 观感仍是同一种中性灰。
  static const AppPalette light = AppPalette(
    bg: Color(0xFFF2F2F7),
    card: Color(0xFFFFFFFF),
    card2: Color(0xFFF2F2F7),
    fill: Color(0x1F767680), // rgba(118,118,128,.12)
    thumb: Color(0xFFFFFFFF),
    text: Color(0xFF000000),
    text2: Color(0xFF6E6E73),
    text3: Color(0xFFB0B0B5),
    separator: Color(0x213C3C43), // rgba(60,60,67,.13)
    accent: Color(0xFF007AFF),
    ok: Color(0xFF34C759),
    err: Color(0xFFFF3B30),
    warn: Color(0xFFFF9500),
    purple: Color(0xFFAF52DE),
    // 向黑混合的比例：accent 12% / ok 36% / err 18% / warn 37% / purple 11%
    accentInk: Color(0xFF006BE0),
    okInk: Color(0xFF217F39),
    errInk: Color(0xFFD13027),
    warnInk: Color(0xFFA15E00),
    purpleInk: Color(0xFF9C49C6),
    onStatus: Color(0xFFFFFFFF),
    primaryBtnBg: Color(0xFF000000),
    primaryBtnFg: Color(0xFFFFFFFF),
    glass: Color(0xB8FFFFFF), // rgba(255,255,255,.72)
    glassBorder: Color(0x0F000000), // rgba(0,0,0,.06)
  );

  /// 深色。取值来自 `APP效果演示.html` 的 `[data-mode="dark"]`。
  /// 深色下 iOS 状态色对 `#1C1C1E` 卡片最低也有 4.66:1（蓝），墨色直接等于实色。
  static const AppPalette dark = AppPalette(
    bg: Color(0xFF000000),
    card: Color(0xFF1C1C1E),
    card2: Color(0xFF2C2C2E),
    fill: Color(0x3D767680), // rgba(118,118,128,.24)
    thumb: Color(0xFF636366),
    text: Color(0xFFFFFFFF),
    text2: Color(0xFF8D8D93),
    text3: Color(0xFF5F5F65),
    separator: Color(0x8C545458), // rgba(84,84,88,.55)
    accent: Color(0xFF0A84FF),
    ok: Color(0xFF30D158),
    err: Color(0xFFFF453A),
    warn: Color(0xFFFF9F0A),
    purple: Color(0xFFBF5AF2),
    accentInk: Color(0xFF0A84FF),
    okInk: Color(0xFF30D158),
    errInk: Color(0xFFFF453A),
    warnInk: Color(0xFFFF9F0A),
    purpleInk: Color(0xFFBF5AF2),
    onStatus: Color(0xFFFFFFFF),
    primaryBtnBg: Color(0xFFFFFFFF),
    primaryBtnFg: Color(0xFF000000),
    glass: Color(0xB828282C), // rgba(40,40,44,.72)
    glassBorder: Color(0x1AFFFFFF), // rgba(255,255,255,.1)
  );

  bool get isLight => bg.computeLuminance() > 0.5;

  /// 状态色的淡底（彩色图标方块、筛选方块的底）。浅色 12%、深色 22%。
  /// 淡底上的图标用实色；淡底上要放**字**时用 `xxxInk`。
  Color tint(Color color) => color.withValues(alpha: isLight ? 0.12 : 0.22);

  /// 玻璃降级时的实色底：低端机 / 「移除动画」时不做模糊，改成 92% 不透明。
  Color get glassSolid => card.withValues(alpha: 0.92);

  @override
  AppPalette copyWith({
    Color? bg,
    Color? card,
    Color? card2,
    Color? fill,
    Color? thumb,
    Color? text,
    Color? text2,
    Color? text3,
    Color? separator,
    Color? accent,
    Color? ok,
    Color? err,
    Color? warn,
    Color? purple,
    Color? accentInk,
    Color? okInk,
    Color? errInk,
    Color? warnInk,
    Color? purpleInk,
    Color? onStatus,
    Color? primaryBtnBg,
    Color? primaryBtnFg,
    Color? glass,
    Color? glassBorder,
  }) {
    return AppPalette(
      bg: bg ?? this.bg,
      card: card ?? this.card,
      card2: card2 ?? this.card2,
      fill: fill ?? this.fill,
      thumb: thumb ?? this.thumb,
      text: text ?? this.text,
      text2: text2 ?? this.text2,
      text3: text3 ?? this.text3,
      separator: separator ?? this.separator,
      accent: accent ?? this.accent,
      ok: ok ?? this.ok,
      err: err ?? this.err,
      warn: warn ?? this.warn,
      purple: purple ?? this.purple,
      accentInk: accentInk ?? this.accentInk,
      okInk: okInk ?? this.okInk,
      errInk: errInk ?? this.errInk,
      warnInk: warnInk ?? this.warnInk,
      purpleInk: purpleInk ?? this.purpleInk,
      onStatus: onStatus ?? this.onStatus,
      primaryBtnBg: primaryBtnBg ?? this.primaryBtnBg,
      primaryBtnFg: primaryBtnFg ?? this.primaryBtnFg,
      glass: glass ?? this.glass,
      glassBorder: glassBorder ?? this.glassBorder,
    );
  }

  /// 明暗切换时主题插值要用。
  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppPalette(
      bg: l(bg, other.bg),
      card: l(card, other.card),
      card2: l(card2, other.card2),
      fill: l(fill, other.fill),
      thumb: l(thumb, other.thumb),
      text: l(text, other.text),
      text2: l(text2, other.text2),
      text3: l(text3, other.text3),
      separator: l(separator, other.separator),
      accent: l(accent, other.accent),
      ok: l(ok, other.ok),
      err: l(err, other.err),
      warn: l(warn, other.warn),
      purple: l(purple, other.purple),
      accentInk: l(accentInk, other.accentInk),
      okInk: l(okInk, other.okInk),
      errInk: l(errInk, other.errInk),
      warnInk: l(warnInk, other.warnInk),
      purpleInk: l(purpleInk, other.purpleInk),
      onStatus: l(onStatus, other.onStatus),
      primaryBtnBg: l(primaryBtnBg, other.primaryBtnBg),
      primaryBtnFg: l(primaryBtnFg, other.primaryBtnFg),
      glass: l(glass, other.glass),
      glassBorder: l(glassBorder, other.glassBorder),
    );
  }
}

extension AppPaletteContext on BuildContext {
  /// `context.palette.card`。
  ///
  /// 主题里没挂扩展（极少数测试直接 `MaterialApp()` 不带主题）时按明暗回落到内置两套，
  /// 不抛异常 —— 组件在任何测试脚手架里都能直接渲染。
  AppPalette get palette {
    final theme = Theme.of(this);
    return theme.extension<AppPalette>() ??
        (theme.brightness == Brightness.dark
            ? AppPalette.dark
            : AppPalette.light);
  }
}
