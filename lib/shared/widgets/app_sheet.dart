import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';

/// 卡片式弹层（方案书 §2.4，任务详情）。
///
/// 三条路径，调用方不用关心：
/// 1. **默认**：`CupertinoSheetRoute`（Flutter 3.41.9 自带，已实测可用）——从底部弹起，
///    背后的页面缩小、下沉并稍微变暗（iOS 卡片式模态），下拉关闭；
/// 2. 系统开了「移除动画」：同样的外观，但只淡入、背后的页面不缩放；
/// 3. [fullHeight] 为 false：内容多高弹层就多高（选择器、短确认），回落到
///    `showModalBottomSheet`（`isScrollControlled`、顶部圆角 30、拖拽把手）。
///
/// 三条路径都把内容包在 `Material` 里（底色 `palette.bg`、顶部圆角 30、拖拽把手），
/// [builder] 里直接放 `ListView` / `Column` 即可；返回值与 `Navigator.pop(result)` 一致。
///
/// ⚠️ 弹层压在根 Navigator 上（盖住底栏）。在弹层里 `context.push` 二级页面时，
/// 新页面同样在根 Navigator 上、盖在弹层之上，返回后弹层还在。
Future<T?> showAppSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool fullHeight = true,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);

  if (!fullHeight) {
    return showModalBottomSheet<T>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      elevation: 0,
      builder: (sheetContext) =>
          _AppSheetSurface(fullHeight: false, child: builder(sheetContext)),
    );
  }

  if (AppMotion.reduce(context)) {
    return navigator.push<T>(
      PageRouteBuilder<T>(
        opaque: false,
        barrierDismissible: true,
        // rgba(0,0,0,.28)，同效果演示的遮罩
        barrierColor: const Color(0x47000000),
        barrierLabel: MaterialLocalizations.of(
          context,
        ).modalBarrierDismissLabel,
        transitionDuration: AppMotion.normal,
        reverseTransitionDuration: AppMotion.normal,
        pageBuilder: (routeContext, _, _) => Padding(
          // 与 CupertinoSheetRoute 一样在顶部留出 8% 的缝
          padding: EdgeInsets.only(
            top: MediaQuery.sizeOf(routeContext).height * 0.08,
          ),
          child: _AppSheetSurface(
            fullHeight: true,
            child: builder(routeContext),
          ),
        ),
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  return navigator.push<T>(
    CupertinoSheetRoute<T>(
      builder: (routeContext) =>
          _AppSheetSurface(fullHeight: true, child: builder(routeContext)),
    ),
  );
}

/// 弹层的外壳：底色、顶部圆角、拖拽把手、底部安全区。
class _AppSheetSurface extends StatelessWidget {
  final bool fullHeight;
  final Widget child;

  const _AppSheetSurface({required this.fullHeight, required this.child});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final handle = Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 6),
      child: Center(
        child: Container(
          width: 40,
          height: 5,
          decoration: BoxDecoration(
            color: palette.text3,
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
        ),
      ),
    );

    return Material(
      color: palette.bg,
      // CupertinoSheetRoute 自己只裁了 12 的顶角，这里再裁一层 30 的盖过去
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.card),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: fullHeight ? MainAxisSize.max : MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            handle,
            if (fullHeight) Expanded(child: child) else Flexible(child: child),
          ],
        ),
      ),
    );
  }
}
