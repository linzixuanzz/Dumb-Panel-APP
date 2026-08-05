import 'package:flutter/material.dart';

/// 全局提示条。
///
/// 替代 7 个文件里逐字重复的私有 `_showMessage`：
/// ```dart
/// void _showMessage(String message) {
///   if (!mounted) return;
///   ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
/// }
/// ```
///
/// 与旧写法的差别只有两点，视觉与行为保持不变：
/// 1. `mounted` 判断收进来了（用 `BuildContext.mounted`），调用方不必再写；
/// 2. 用 `ScaffoldMessenger.maybeOf`，页面已经从树上摘掉时静默返回而不是抛异常。
class AppSnack {
  const AppSnack._();

  static void show(
    BuildContext context,
    String message, {
    /// 先关掉当前这条再弹新的。原来只有 `app_lock_settings_page` 这么做。
    bool replaceCurrent = false,
    Duration? duration,
  }) {
    if (!context.mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) {
      return;
    }
    if (replaceCurrent) {
      messenger.hideCurrentSnackBar();
    }
    messenger.showSnackBar(
      duration == null
          ? SnackBar(content: Text(message))
          : SnackBar(content: Text(message), duration: duration),
    );
  }
}
