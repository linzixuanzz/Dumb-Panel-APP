import 'package:flutter/material.dart';

/// v3.0 语义色板 —— 方案 1 · Nordic Calm（智能家居级松弛留白风）。
///
/// 设计哲学（Distill & Quieter，60 / 30 / 10 法则）：
/// 1. **60% 温润暖纸留白**：浅色采用暖石纸底 `#F6F6F3`，深色采用柔和黑曜灰 `#121316`，告别刺眼纯白与死黑；
/// 2. **30% 洁净卡片与暖灰层次**：卡片纯白 `#FFFFFF` / 石墨 `#1B1D21`，次级块 `#EFECE6` / `#25282E`；
/// 3. **10% 克制钴蓝与异常语义色**：主操作与焦点采用克制钴蓝 `#2B5BEE`，状态色仅在运行/成功/异常时点缀；
/// 4. **无障碍对比度**：正文、次要文字及五个 `*Ink` 墨色在卡片和页面底色上全部实测 ≥ 5.3:1（高于 WCAG AA 4.5:1）。
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

  /// 页面底色（温润暖纸 / 柔和深灰）。
  final Color bg;

  /// 内容卡片底色。
  final Color card;

  /// 卡片内嵌的次级浅底块（不透明，如代码预览、参数微调底）。
  final Color card2;

  /// 次级半透明填充：分段控件底槽、搜索框、次要按钮、底栏选中态。
  final Color fill;

  /// 分段控件滑块底色。
  final Color thumb;

  /// 一级正文文字（暖深石黑 / 暖柔白）。
  final Color text;

  /// 二级说明文字（对 [card] 与 [bg] 均 ≥ 5.5:1）。
  final Color text2;

  /// 三级弱化文字（占位符、辅助时间戳、右箭头）。
  final Color text3;

  /// 缩进分隔发丝线。
  final Color separator;

  /// 品牌强调色：Nordic Cobalt 钴蓝。
  final Color accent;

  /// 状态实色：成功（森林绿）。
  final Color ok;

  /// 状态实色：异常 / 危险（珊瑚红）。
  final Color err;

  /// 状态实色：警告 / 已终止（暖琥珀）。
  final Color warn;

  /// 状态实色：扩展进行态 / 辅助系列（柔和鸢尾紫）。
  final Color purple;

  /// 状态文字专用「墨色」（保证浅深两套对 [card] 和 [bg] 均 ≥ 4.5:1）。
  final Color accentInk;
  final Color okInk;
  final Color errInk;
  final Color warnInk;
  final Color purpleInk;

  /// 状态实色徽章上的反白文字。
  final Color onStatus;

  /// 主操作按钮底色与前景色（Nordic Cobalt 钴蓝配纯白文字，对比度 5.48:1）。
  final Color primaryBtnBg;
  final Color primaryBtnFg;

  /// 悬浮导航栏与顶栏毛玻璃底色。
  final Color glass;

  /// 毛玻璃细描边。
  final Color glassBorder;

  /// 浅色：Nordic Calm 温润暖纸体系。
  static const AppPalette light = AppPalette(
    bg: Color(0xFFF6F6F3),
    card: Color(0xFFFFFFFF),
    card2: Color(0xFFEFECE6),
    fill: Color(0x141C1917), // rgba(28, 25, 23, 0.08)
    thumb: Color(0xFFFFFFFF),
    text: Color(0xFF1C1917),
    text2: Color(0xFF68625D),
    text3: Color(0xFFA8A29E),
    separator: Color(0x121C1917), // rgba(28, 25, 23, 0.07)
    accent: Color(0xFF2B5BEE),
    ok: Color(0xFF15803D),
    err: Color(0xFFDC2626),
    warn: Color(0xFFD97706),
    purple: Color(0xFF6D5BD0),
    accentInk: Color(0xFF224BC9),
    okInk: Color(0xFF147538),
    errInk: Color(0xFFC81E1E),
    warnInk: Color(0xFF9A5200),
    purpleInk: Color(0xFF5845BC),
    onStatus: Color(0xFFFFFFFF),
    primaryBtnBg: Color(0xFF2B5BEE),
    primaryBtnFg: Color(0xFFFFFFFF),
    glass: Color(0xE0FFFFFF), // rgba(255, 255, 255, 0.88)
    glassBorder: Color(0x121C1917),
  );

  /// 深色：Nordic Calm 静谧暗夜体系。
  static const AppPalette dark = AppPalette(
    bg: Color(0xFF121316),
    card: Color(0xFF1B1D21),
    card2: Color(0xFF25282E),
    fill: Color(0x24FFFFFF), // rgba(255, 255, 255, 0.14)
    thumb: Color(0xFF32363F),
    text: Color(0xFFF5F5F4),
    text2: Color(0xFFA8A29E),
    text3: Color(0xFF78716C),
    separator: Color(0x14FFFFFF), // rgba(255, 255, 255, 0.08)
    accent: Color(0xFF6C93FF),
    ok: Color(0xFF22C55E),
    err: Color(0xFFF87171),
    warn: Color(0xFFFBBF24),
    purple: Color(0xFFA78BFA),
    accentInk: Color(0xFF6C93FF),
    okInk: Color(0xFF22C55E),
    errInk: Color(0xFFF87171),
    warnInk: Color(0xFFFBBF24),
    purpleInk: Color(0xFFA78BFA),
    onStatus: Color(0xFFFFFFFF),
    primaryBtnBg: Color(0xFF2B5BEE),
    primaryBtnFg: Color(0xFFFFFFFF),
    glass: Color(0xE01B1D21), // rgba(27, 29, 33, 0.88)
    glassBorder: Color(0x14FFFFFF),
  );

  bool get isLight => bg.computeLuminance() > 0.5;

  /// 状态色的柔和淡底（浅色 9%、深色 16%）。
  Color tint(Color color) => color.withValues(alpha: isLight ? 0.09 : 0.16);

  /// 玻璃降级时的实色底：系统开启「移除动画」时不做模糊，改为 94% 不透明。
  Color get glassSolid => card.withValues(alpha: 0.94);

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
  /// 快捷读取 `context.palette`；测试未挂载主题扩展时按明暗安全回落。
  AppPalette get palette {
    final theme = Theme.of(this);
    return theme.extension<AppPalette>() ??
        (theme.brightness == Brightness.dark
            ? AppPalette.dark
            : AppPalette.light);
  }
}
