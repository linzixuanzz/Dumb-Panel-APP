import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';

/// 缺口卡片（方案书 §2.4，任务页「常用任务」）：卡片右下角挖掉一块，
/// 缺口的左上角是圆角，缺口与卡片边缘相接的两处是「反向圆角」，
/// [notch]（一般是 `HoldToRunButton`）嵌在缺口里。
///
/// ```text
///  ╭──────────────────────╮
///  │ child                │
///  │                   ╭──╯   ← 右边：反向圆角
///  │              ╭────╯
///  ╰──────────────╯ [notch]    ← 缺口左上角是圆角；底边左侧也是反向圆角
/// ```
///
/// - [child] 铺满整张卡片（含缺口所在的右下角区域），**内容自己避开右下角**；
/// - 卡片高度由 [child] 决定，至少要比 `notchSize.height + fillet + radius` 高；
/// - 缺口的底色是透明的，透出的是卡片下面的页面底色。
class NotchedCard extends StatelessWidget {
  final Widget child;

  /// 嵌在缺口里的组件。它占的大小是 `notchSize - notchGap`，贴着卡片的右边和底边。
  final Widget notch;

  /// 缺口（挖掉的那块）的宽高。默认与效果演示一致：208 × 82。
  final Size notchSize;

  /// 卡片四角的圆角。
  final double radius;

  /// 缺口与嵌入组件之间的间隙（只在左边和上边）。
  final double notchGap;

  /// 卡片底色，默认 `palette.card`。
  final Color? color;

  static const double _defaultNotchWidth = 208;
  static const double _defaultNotchHeight = 82;

  /// 默认缺口尺寸（效果演示同款）。
  static const Size defaultNotchSize = Size(
    _defaultNotchWidth,
    _defaultNotchHeight,
  );

  /// 默认缺口间隙。
  static const double defaultNotchGap = 12;

  /// 默认缺口里 [notch] 实际拿到的大小（196 × 70，紧约束）。
  /// 嵌入组件要按它给尺寸，别靠自己的默认值去碰运气。
  static const Size defaultSlotSize = Size(
    _defaultNotchWidth - defaultNotchGap,
    _defaultNotchHeight - defaultNotchGap,
  );

  const NotchedCard({
    super.key,
    required this.child,
    required this.notch,
    this.notchSize = defaultNotchSize,
    this.radius = AppRadius.card,
    this.notchGap = defaultNotchGap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ClipPath(
          clipper: NotchedCardClipper(notchSize: notchSize, radius: radius),
          child: ColoredBox(
            color: color ?? context.palette.card,
            child: child,
          ),
        ),
        Positioned(
          right: 0,
          bottom: 0,
          width: notchSize.width - notchGap,
          height: notchSize.height - notchGap,
          child: notch,
        ),
      ],
    );
  }
}

/// 缺口卡片的轮廓。公开出来是为了单测能直接验证路径（哪些点在里面、哪些被挖掉）。
class NotchedCardClipper extends CustomClipper<Path> {
  final Size notchSize;

  /// 卡片四角圆角。
  final double radius;

  /// 缺口左上角的圆角（效果演示 32）。
  final double notchRadius;

  /// 两处反向圆角的半径（效果演示 30）。
  final double fillet;

  const NotchedCardClipper({
    required this.notchSize,
    this.radius = AppRadius.card,
    this.notchRadius = 32,
    this.fillet = 30,
  });

  @override
  Path getClip(Size size) => buildPath(size);

  /// 坐标约定：卡片宽 W、高 H，缺口占右下角 [W-w, W] × [H-h, H]。
  /// 从左上角起顺时针走一圈。
  Path buildPath(Size size) {
    final w = size.width;
    final h = size.height;
    final nw = notchSize.width;
    final nh = notchSize.height;
    // 卡片太小装不下缺口时，几何参数按比例收，保证路径不自交（不会出现在正常布局里）
    double fit(double v, double max) => v.clamp(0.0, math.max(0.0, max));
    final r = fit(fit(radius, (h - nh) / 2), (w - nw) / 2);
    final f = fit(fit(fillet, h - nh - r), w - nw - r);
    final nr = fit(fit(notchRadius, nh), nw);

    final notchTop = h - nh;
    final notchLeft = w - nw;

    return Path()
      ..moveTo(0, r)
      // 左上角
      ..arcToPoint(Offset(r, 0), radius: Radius.circular(r))
      ..lineTo(w - r, 0)
      // 右上角
      ..arcToPoint(Offset(w, r), radius: Radius.circular(r))
      ..lineTo(w, notchTop - f)
      // 右边的反向圆角：绕圆心 (w-f, notchTop-f) 顺时针转到缺口上沿
      ..arcToPoint(Offset(w - f, notchTop), radius: Radius.circular(f))
      ..lineTo(notchLeft + nr, notchTop)
      // 缺口左上角：逆时针拐下去
      ..arcToPoint(
        Offset(notchLeft, notchTop + nr),
        radius: Radius.circular(nr),
        clockwise: false,
      )
      ..lineTo(notchLeft, h - f)
      // 底边的反向圆角：绕圆心 (notchLeft-f, h-f) 顺时针转到底边
      ..arcToPoint(Offset(notchLeft - f, h), radius: Radius.circular(f))
      ..lineTo(r, h)
      // 左下角
      ..arcToPoint(Offset(0, h - r), radius: Radius.circular(r))
      ..close();
  }

  @override
  bool shouldReclip(NotchedCardClipper oldClipper) =>
      oldClipper.notchSize != notchSize ||
      oldClipper.radius != radius ||
      oldClipper.notchRadius != notchRadius ||
      oldClipper.fillet != fillet;
}
