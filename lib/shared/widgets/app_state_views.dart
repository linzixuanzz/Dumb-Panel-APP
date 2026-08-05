import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/design_tokens.dart';

/// 列表「加载中」占位。
///
/// 替代任务 / 日志 / 环境变量三页里逐字相同的：
/// ```dart
/// ListView(children: const [
///   SizedBox(height: 120),
///   Center(child: CircularProgressIndicator(color: AppColors.primary)),
/// ])
/// ```
class AppLoadingView extends StatelessWidget {
  /// 顶部留白。三个列表页原本都是 120。
  final double topPadding;

  const AppLoadingView({super.key, this.topPadding = 120});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: topPadding),
      child: const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      ),
    );
  }
}

/// 「真的没有数据」空态。
///
/// 注意与 [AppErrorView] 的区别：空态表示请求成功但结果为空，
/// **拿不到数据必须用 [AppErrorView]**，否则用户看到的是莫名其妙的「暂无 XXX」。
class AppEmptyView extends StatelessWidget {
  final IconData icon;
  final String message;

  /// 顶部留白。列表页里通常给 100，弹层里给 0。
  final double topPadding;

  const AppEmptyView({
    super.key,
    required this.icon,
    required this.message,
    this.topPadding = 100,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: topPadding),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: AppColors.slate400.withAlpha(120)),
          const SizedBox(height: AppSpacing.md),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.slate400, fontSize: 15),
          ),
        ],
      ),
    );
  }
}

/// 「拿不到数据」错误态：原因 + 重试。
///
/// 替代任务 / 日志 / 环境变量三页里各复制一份的 `_buildLoadError`（每份约 32 行，形态完全一致）。
class AppErrorView extends StatelessWidget {
  /// 例如「任务加载失败」。
  final String title;

  /// 具体原因，通常来自 `extractErrorMessage(error, fallback)`。
  final String message;

  /// 为 null 时不显示重试按钮。
  final VoidCallback? onRetry;

  final String retryLabel;
  final IconData icon;
  final EdgeInsetsGeometry padding;

  const AppErrorView({
    super.key,
    required this.title,
    required this.message,
    this.onRetry,
    this.retryLabel = '重试',
    this.icon = Icons.cloud_off_outlined,
    this.padding = const EdgeInsets.fromLTRB(32, 100, 32, 0),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: AppColors.red500.withAlpha(120)),
          const SizedBox(height: AppSpacing.md),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: AppColors.slate400),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: AppSpacing.lg),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 16),
              label: Text(retryLabel),
            ),
          ],
        ],
      ),
    );
  }
}
