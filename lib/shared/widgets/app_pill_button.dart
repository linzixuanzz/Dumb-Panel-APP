import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';

/// 胶囊按钮的三种语义。
enum AppPillVariant {
  /// 主操作：浅色黑底白字、深色白底黑字。一屏最多一个。
  primary,

  /// 次要操作：灰色填充 + 正文色。
  secondary,

  /// 危险操作：红色淡底 + 红色墨色字。
  danger,
}

/// 胶囊按钮（方案书「主操作永远是黑色胶囊」）。
///
/// [onPressed] 为 null 时是禁用态（整体 40% 透明度，不响应点击）。
class AppPillButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final AppPillVariant variant;

  /// 撑满父级宽度。
  final bool expand;

  final double height;

  const AppPillButton({
    super.key,
    required this.label,
    this.icon,
    required this.onPressed,
    this.variant = AppPillVariant.primary,
    this.expand = false,
    this.height = 46,
  });

  @override
  State<AppPillButton> createState() => _AppPillButtonState();
}

class _AppPillButtonState extends State<AppPillButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final reduce = AppMotion.reduce(context);
    final enabled = widget.onPressed != null;

    final (bg, fg) = switch (widget.variant) {
      AppPillVariant.primary => (palette.primaryBtnBg, palette.primaryBtnFg),
      AppPillVariant.secondary => (palette.fill, palette.text),
      AppPillVariant.danger => (palette.tint(palette.err), palette.errInk),
    };

    final content = Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.icon != null) ...[
          Icon(widget.icon, size: 19, color: fg),
          const SizedBox(width: AppSpacing.sm),
        ],
        Flexible(
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: fg,
            ),
          ),
        ),
      ],
    );

    return Semantics(
      button: true,
      enabled: enabled,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        onTapDown: enabled ? (_) => _setPressed(true) : null,
        onTapUp: enabled ? (_) => _setPressed(false) : null,
        onTapCancel: enabled ? () => _setPressed(false) : null,
        child: AnimatedScale(
          scale: _pressed && !reduce ? 0.94 : 1,
          duration: AppMotion.of(context, AppMotion.fast),
          curve: AppMotion.spring,
          child: Opacity(
            opacity: enabled ? 1 : 0.4,
            child: Container(
              height: widget.height,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}
