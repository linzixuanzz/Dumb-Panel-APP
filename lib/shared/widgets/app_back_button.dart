import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/design_tokens.dart';

/// 页面头部的返回按钮。
///
/// 收敛全库 11 处逐字相同的写法：
/// ```dart
/// GestureDetector(
///   onTap: () => context.pop(),
///   child: const Icon(Icons.arrow_back_ios, size: 20),
/// )
/// ```
/// 那个写法有两个毛病，且是全库最糟的命中区：
/// 1. 没有 padding 也没有尺寸约束，可点范围就是图标本身的 **20dp**；
/// 2. 没有 `HitTestBehavior.opaque`，图标笔画之间的透明像素**不响应点击** ——
///    也就是说实际可点面积比 20dp 见方还小。
///
/// 这里用 [AppTapTarget.min] 撑出命中区，图标视觉尺寸保持 20 不变。
class AppBackButton extends StatelessWidget {
  const AppBackButton({super.key, this.onTap, this.color});

  /// 默认 `context.pop()`。少数页面需要先做确认或清理，可以自己接管。
  final VoidCallback? onTap;

  /// 默认跟随 `IconTheme`，与替换前的裸 `Icon` 行为一致。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap ?? () => context.pop(),
      child: SizedBox(
        width: AppTapTarget.min,
        height: AppTapTarget.min,
        child: Center(
          child: Icon(Icons.arrow_back_ios, size: 20, color: color),
        ),
      ),
    );
  }
}
