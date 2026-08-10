import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/design_tokens.dart';

/// 页面头部右上角的圆形「新建」按钮。
///
/// 收敛全库 7 处逐字相同的写法（任务 / 用户 / 通知渠道 / Open API / 订阅 /
/// 依赖 / 环境变量各一处）：
/// ```dart
/// GestureDetector(
///   onTap: ...,
///   child: Container(
///     width: 32, height: 32,
///     decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
///     child: const Icon(Icons.add, size: 20, color: Colors.white),
///   ),
/// )
/// ```
/// 那个写法的命中区就是 **32dp** 的圆本身，低于可用下限。
///
/// 这里用 [AppTapTarget.min] 撑出命中区，**圆点视觉尺寸仍然是 32dp**，
/// 排版完全不变，只是变得好按了。
class AppCircleAddButton extends StatelessWidget {
  const AppCircleAddButton({
    super.key,
    required this.onTap,
    this.icon = Icons.add,
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
            width: 32,
            height: 32,
            decoration: const BoxDecoration(
              color: AppColors.primary,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 20, color: Colors.white),
          ),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}
