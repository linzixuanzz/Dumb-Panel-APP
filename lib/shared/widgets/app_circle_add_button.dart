import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';

/// 页面头部右上角的圆形「新建」按钮（v3.0 Nordic Calm：44dp 命中区、34dp 钴蓝圆钮）。
class AppCircleAddButton extends StatelessWidget {
  const AppCircleAddButton({
    super.key,
    required this.onTap,
    this.icon = Icons.add_rounded,
    this.tooltip,
  });

  final VoidCallback onTap;
  final IconData icon;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: AppTapTarget.min,
        height: AppTapTarget.min,
        child: Center(
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: context.palette.primaryBtnBg,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 19, color: context.palette.primaryBtnFg),
          ),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}
