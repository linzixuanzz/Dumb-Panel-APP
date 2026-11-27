import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';

/// 按钮的三种克制语义（v3.0 Nordic Calm）。
enum AppPillVariant {
  /// 主操作：Nordic Cobalt 钴蓝配纯白文字。
  primary,

  /// 次要操作：暖石浅填充配正文色。
  secondary,

  /// 危险操作：珊瑚红柔底配红墨色字。
  danger,
}

/// 胶囊/圆角操作按钮（44dp 标准高度，14.5pt w600 克制字重）。
class AppPillButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final AppPillVariant variant;
  final bool expand;
  final double height;

  const AppPillButton({
    super.key,
    required this.label,
    this.icon,
    required this.onPressed,
    this.variant = AppPillVariant.primary,
    this.expand = false,
    this.height = 44,
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
      AppPillVariant.secondary => (palette.card2, palette.text),
      AppPillVariant.danger => (palette.tint(palette.err), palette.errInk),
    };

    final content = Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.icon != null) ...[
          Icon(widget.icon, size: 17, color: fg),
          const SizedBox(width: 6),
        ],
        Flexible(
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
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
          scale: _pressed && !reduce ? 0.96 : 1,
          duration: AppMotion.of(context, AppMotion.fast),
          curve: AppMotion.spring,
          child: Opacity(
            opacity: enabled ? 1 : 0.42,
            child: Container(
              height: widget.height,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}
