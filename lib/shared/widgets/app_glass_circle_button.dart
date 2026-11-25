import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';

/// 大标题头右边的圆形玻璃按钮（搜索、新建、日历……）。
///
/// - 半透明玻璃底 + 背景模糊；系统开了「移除动画」时不做模糊，换成 92% 不透明的实色；
/// - 按下时轻微缩小（减少动画时不缩）；
/// - [badge] 不为空时右上角出一个红色小徽标（数字或短文字）。
class AppGlassCircleButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback? onTap;

  /// 必填：图标按钮没有文字，靠它告诉用户和读屏这是什么。
  final String tooltip;
  final String? badge;

  /// 圆的直径。默认 48（命中区 ≥ 44）。
  final double size;

  const AppGlassCircleButton({
    super.key,
    required this.icon,
    required this.onTap,
    required this.tooltip,
    this.badge,
    this.size = 48,
  });

  @override
  State<AppGlassCircleButton> createState() => _AppGlassCircleButtonState();
}

class _AppGlassCircleButtonState extends State<AppGlassCircleButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final reduce = AppMotion.reduce(context);
    final enabled = widget.onTap != null;

    Widget circle = DecoratedBox(
      decoration: BoxDecoration(
        color: reduce ? palette.glassSolid : palette.glass,
        shape: BoxShape.circle,
        border: Border.all(color: palette.glassBorder, width: 0.5),
      ),
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: Icon(
          widget.icon,
          size: widget.size * 0.46,
          color: enabled ? palette.accent : palette.text3,
        ),
      ),
    );
    if (!reduce) {
      circle = BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: circle,
      );
    }
    circle = ClipOval(child: circle);

    final badge = widget.badge;
    final button = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onTapDown: enabled ? (_) => _setPressed(true) : null,
      onTapUp: enabled ? (_) => _setPressed(false) : null,
      onTapCancel: enabled ? () => _setPressed(false) : null,
      child: AnimatedScale(
        scale: _pressed && !reduce ? 0.88 : 1,
        duration: AppMotion.of(context, AppMotion.fast),
        curve: AppMotion.spring,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            circle,
            if (badge != null && badge.isNotEmpty)
              Positioned(
                top: -2,
                right: -2,
                child: Container(
                  constraints: const BoxConstraints(minWidth: 18),
                  height: 18,
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: palette.err,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text(
                    badge,
                    style: AppText.tabular(
                      TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        color: palette.onStatus,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    return Tooltip(message: widget.tooltip, child: button);
  }
}
