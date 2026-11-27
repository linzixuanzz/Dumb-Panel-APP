import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';

/// 柔和语义图标方块（v3.0 Nordic Calm：默认 34dp 轻盈比例、细腻图标尺寸）。
class AppIconTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  final bool solid;

  /// 默认边长，也是 `AppGroupedRow.leadingWidth`：分组行按它算分隔线和文字起点，
  /// 两边必须是同一个数，否则分隔线与标题错开。
  static const double defaultSize = 34;

  const AppIconTile({
    super.key,
    required this.icon,
    required this.color,
    this.size = defaultSize,
    this.solid = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    // 圆角按 46dp 的比例缩，实色 / 浅底一视同仁：方块变小时不缩会接近圆形；
    // 同一组里实色与浅底混排、或选中态切成实色时，外形也不会跳。
    final radius = AppRadius.tile * size / 46;
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
        // 实色底上的前景走 onStatus（明暗各自保证压得住状态实色）
        color: solid ? palette.onStatus : color,
      ),
    );
  }
}
