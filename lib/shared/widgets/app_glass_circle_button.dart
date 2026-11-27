import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';

/// 顶栏精致玻璃圆钮（v3.0 Nordic Calm：44dp 命中区、38dp 轻盈视觉圆、18dp 细线性图标）。
class AppGlassCircleButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final String tooltip;
  final String? badge;
  final double size;

  const AppGlassCircleButton({
    super.key,
    required this.icon,
    required this.onTap,
    required this.tooltip,
    this.badge,
    this.size = 44,
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
        border: Border.all(color: palette.glassBorder, width: 0.8),
      ),
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: Icon(
          widget.icon,
          size: widget.size * 0.43,
          color: enabled ? palette.text : palette.text3,
        ),
      ),
    );
    if (!reduce) {
      circle = BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
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
        scale: _pressed && !reduce ? 0.92 : 1,
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
                  constraints: const BoxConstraints(minWidth: 17),
                  height: 17,
                  padding: const EdgeInsets.symmetric(horizontal: 4.5),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: palette.err,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text(
                    badge,
                    style: AppText.tabular(
                      TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
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
