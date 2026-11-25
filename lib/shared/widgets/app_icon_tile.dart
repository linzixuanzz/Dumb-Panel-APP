import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';

/// 彩色图标方块（方案书 §2.4）：列表行、日志筛选、小卡片的前导图标。
///
/// - 默认「浅底配同色图标」：底是 `palette.tint(color)`，图标是 [color] 实色；
/// - [solid] 为 true 时是实色底 + 白色图标（设置页「服务器管理」「应用锁」那种）。
///
/// [color] 传色板里的状态色（`palette.ok` / `err` / `accent` / `purple` / `warn`），
/// 不要传写死的颜色。
class AppIconTile extends StatelessWidget {
  final IconData icon;
  final Color color;

  /// 方块边长。默认 36（列表行）；日志筛选方块之类用 46。
  final double size;
  final bool solid;

  const AppIconTile({
    super.key,
    required this.icon,
    required this.color,
    this.size = 36,
    this.solid = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    // AppRadius.tile 是按 46dp 方块定的；方块小了圆角跟着按比例缩，
    // 否则 36dp 的方块配 15 的圆角几乎成了圆。
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
        size: size * 0.56,
        color: solid ? palette.onStatus : color,
      ),
    );
  }
}
