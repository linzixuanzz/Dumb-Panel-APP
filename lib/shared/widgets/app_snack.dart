import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/design_tokens.dart';

/// 提示条的语义色调。
///
/// 为什么需要它：改造前全 App 的成功与失败提示是**同一条灰色 SnackBar**，
/// 「保存成功」和「保存失败」除了文案以外完全长得一样，用户必须逐字读完
/// 才知道操作成没成。
///
/// 故意**不做** `info`：蓝色在本 App 已经被 `AppColors.info`（= primary）
/// 占去表示「运行中 / 进行中」，提示条再来一支蓝的只会和状态徽章打架；
/// 而且现有调用点里没有一条需要它。等真出现再加，不预先留空壳。
enum AppSnackTone {
  /// 中性告知。底色与前景全部走主题默认值（`inverseSurface`），
  /// 未重标的调用点配色不变。
  neutral,

  /// 操作成功、已保存、已删除、请求已提交。
  success,

  /// 操作失败、请求出错。
  error,

  /// 校验没过、能力不支持、部分成功 —— 不是错，但也不能当成功。
  warning,
}

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
/// 相比最原始的写法：
/// 1. `mounted` 判断收进来了（用 `BuildContext.mounted`），调用方不必再写；
/// 2. 用 `ScaffoldMessenger.maybeOf`，页面已经从树上摘掉时静默返回而不是抛异常；
/// 3. 带 [AppSnackTone] 语义色（见上）。
///
/// 版式统一在这里定，不走 `SnackBarThemeData`：主题里只能设默认值，
/// 而这里每条都显式传 `behavior`，两边同时配会互相盖，留一处更好排查。
class AppSnack {
  const AppSnack._();

  /// 与 Flutter 的 `_snackBarDisplayDuration` 取值一致。
  ///
  /// 之所以自己写一份而不是「不传 duration 让框架填默认值」，是因为
  /// `SnackBar.duration` 是非空参数，想保留框架默认就得把整个 SnackBar
  /// 构造分叉成两份 —— 那才是真正会写歪的地方。
  static const Duration _defaultDuration = Duration(milliseconds: 4000);

  static void show(
    BuildContext context,
    String message, {
    AppSnackTone tone = AppSnackTone.neutral,

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

    final accent = _accentOf(tone);
    // neutral 一律传 null，让 SnackBar 落回主题默认的 inverseSurface /
    // onInverseSurface 组合 —— 未重标的调用点配色与改造前逐字节相同。
    final surfaces = AppSurfaces.of(context);
    final background = accent == null ? null : surfaces.solidBg(accent);
    final foreground = accent == null ? null : surfaces.solidFg;

    messenger.showSnackBar(
      SnackBar(
        content: Text(
          message,
          // TextStyle 默认 inherit: true，只覆盖颜色，字号字重仍来自主题。
          style: foreground == null ? null : TextStyle(color: foreground),
        ),
        backgroundColor: background,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(AppSpacing.md),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.md)),
        ),
        duration: duration ?? _defaultDuration,
      ),
    );
  }

  // 下面三个快捷方法故意不转发 duration：全库没有一处需要改停留时长，
  // 真需要的时候直接用 show(..., tone: ...) 就行，不预先摆一个没人调的参数。

  /// 操作成功。
  static void success(
    BuildContext context,
    String message, {
    bool replaceCurrent = false,
  }) => show(
    context,
    message,
    tone: AppSnackTone.success,
    replaceCurrent: replaceCurrent,
  );

  /// 操作失败。
  static void error(
    BuildContext context,
    String message, {
    bool replaceCurrent = false,
  }) => show(
    context,
    message,
    tone: AppSnackTone.error,
    replaceCurrent: replaceCurrent,
  );

  /// 校验没过 / 能力不支持 / 部分成功。
  static void warn(
    BuildContext context,
    String message, {
    bool replaceCurrent = false,
  }) => show(
    context,
    message,
    tone: AppSnackTone.warning,
    replaceCurrent: replaceCurrent,
  );

  /// 返回该色调的强调色；neutral 返回 null 表示「不着色，用主题默认」。
  static Color? _accentOf(AppSnackTone tone) => switch (tone) {
    AppSnackTone.neutral => null,
    AppSnackTone.success => AppColors.success,
    AppSnackTone.error => AppColors.danger,
    AppSnackTone.warning => AppColors.warning,
  };
}
