import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';
import 'app_card.dart';

/// 淡底提示条 —— 用强调色的淡底 + 淡边包住一段说明 / 警告 / 错误文案。
///
/// 替代散在 8 个文件里的这套内联写法：
/// ```dart
/// Container(
///   width: double.infinity,
///   padding: const EdgeInsets.all(12),
///   decoration: BoxDecoration(
///     color: AppColors.blue500.withAlpha(12),
///     borderRadius: BorderRadius.circular(10),
///     border: Border.all(color: AppColors.blue500.withAlpha(30)),
///   ),
///   child: Text('...', style: TextStyle(fontSize: 12, height: 1.5, ...)),
/// )
/// ```
///
/// **为什么是新组件而不是给 [AppCard] 加参数**：这 11 处用
/// `AppCard(color: surfaces.tintBg(x), borderColor: surfaces.tintBorder(x))`
/// 就能表达，[AppCard] 一个 prop 都不用加。但手写 11 遍这三行，等于把 [AppCard]
/// 想消灭的重复原样搬到另一个地方。真正重复的不是「卡片」，是「淡底 + 淡边 +
/// 前景怎么配」这条规则，所以把规则本身封成组件，底下仍然复用 [AppCard]。
///
/// **本组件刻意不提供的东西**（读完 12 个候选站点后确认没有一处需要）：
/// 关闭按钮、操作按钮、标题/正文两级文字、自定义 padding、自定义圆角。
/// 少一个参数就少一处日后各写各的机会；真出现需求时再加，不预先摆空壳。
///
/// **唯一被排除的候选**：`app_lock_gate` 的生物识别面板是 42px 大图标 + 居中
/// 标题 + 居中描述的竖排「主视觉块」，不是提示条。硬塞进来要为它一个站点加
/// 三个维度，所以它直接用 [AppCard] + `tintBg/tintBorder`。
class AppNotice extends StatelessWidget {
  /// 语义强调色，淡底 / 淡边 / 图标 全部由它推导。
  ///
  /// 传满强度色即可（`AppColors.danger` / `warning` / `info` / `blue500`），
  /// 变淡与加深由 [AppSurfaces] 负责，调用方不要自己 `withAlpha`。
  final Color color;

  /// 正文。全部 11 个站点都只有一段纯文本，所以这里收 `String` 不收 `Widget`。
  final String text;

  /// 可选的前导图标。11 处里只有 4 处有，因此**不给默认图标** ——
  /// 按语义色自动配一个图标，会给另外 7 处凭空加上原本没有的元素。
  final IconData? icon;

  /// 正文是否用强调色。
  ///
  /// 这一条是真的双峰分布（5 处强调 / 6 处中性），不是为了迁就某个特例：
  /// - `true` —— **提示条本身就是消息**：登录 / 解锁失败的错误文案、
  ///   「正在排序模式」这类模式横幅。它们短、要抢眼，用强调色。
  /// - `false` —— **提示条在解释别的东西**：一整段帮助说明。它们长，
  ///   要的是读得下去，用中性正文色（淡底 + 小字号已经足够表达「次级」，
  ///   不必再靠降低对比度）。
  final bool accentText;

  /// 正文对齐。只有登录页与应用锁那两条居中的错误提示要传 [TextAlign.center]。
  final TextAlign? textAlign;

  const AppNotice({
    super.key,
    required this.color,
    required this.text,
    this.icon,
    this.accentText = false,
    this.textAlign,
  });

  /// 迁移前 11 处的字号是 11(bodySmall) / 12 / 12.5 / 13 四种，行高是「1.5 或不设」。
  /// 12 是众数，1.5 是多行说明文字读得下去的下限，统一到这一档。
  static const double _fontSize = 12;
  static const double _lineHeight = 1.5;

  /// 迁移前是 16(×3) / 18(×1)，取众数。
  static const double _iconSize = 16;

  @override
  Widget build(BuildContext context) {
    final surfaces = AppSurfaces.of(context);

    // ⚠️ 图标与强调文字一律走 tintFg，不能退回满强度同色。
    // 底色是同一个 color 的 alpha=18 淡底，前景再用满强度同色就是「同色相只差
    // 透明度」，浅色模式下数学上封顶约 2.6:1（primary）/ 3.4:1（danger）。
    // 深色模式 tintFg 原样返回，不受影响。
    final accent = surfaces.tintFg(color);

    final body = Text(
      text,
      textAlign: textAlign,
      style: TextStyle(
        fontSize: _fontSize,
        height: _lineHeight,
        // 中性档用 strongText 而不是 mutedText：提示条存在的意义就是被读到，
        // 用 mutedText(slate500) 会把浅色模式的正文从 7.5:1 压到 4.8:1，
        // 与本期「修低对比」的方向相反。「次级」由淡底和小字号表达就够了。
        color: accentText ? accent : surfaces.strongText,
      ),
    );

    return AppCard(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      // 提示条是嵌在页面/弹窗里的「内嵌块」，不是区块级大卡片，走 md。
      radius: AppRadius.md,
      color: surfaces.tintBg(color),
      borderColor: surfaces.tintBorder(color),
      child: icon == null
          ? body
          : Row(
              // 多行说明时图标要跟第一行对齐，不能垂直居中飘到中间去。
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: _iconSize, color: accent),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: body),
              ],
            ),
    );
  }
}
