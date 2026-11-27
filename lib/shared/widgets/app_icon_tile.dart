import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';

/// 柔和语义图标方块（v3.0 Nordic Calm：默认 34dp 轻盈比例、细腻图标尺寸）。
class AppIconTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  final bool solid;

  const AppIconTile({
    super.key,
    required this.icon,
    required this.color,
    this.size = 34,
    this.solid = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final radius = solid ? AppRadius.tile : AppRadius.tile * size / 46;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: solid ? color : palette.tint(color),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(
        icon,
        size: size * 0.52,
        color: solid ? palette.onStatus : color,
      ),
    );
  }
}
