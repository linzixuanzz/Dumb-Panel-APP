import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/design_tokens.dart';
import 'app_snack.dart';

class MainScaffold extends StatefulWidget {
  final Widget child;

  const MainScaffold({super.key, required this.child});

  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<MainScaffold> {
  DateTime? _lastExitAttemptAt;

  int _currentIndex(BuildContext context) {
    final location = GoRouterState.of(context).matchedLocation;
    if (location.startsWith('/dashboard')) return 0;
    if (location.startsWith('/tasks')) return 1;
    if (location.startsWith('/logs')) return 2;
    if (location.startsWith('/envs')) return 3;
    if (location.startsWith('/more')) return 4;
    return 0;
  }

  Future<void> _handleBackPress(bool didPop) async {
    if (didPop) {
      return;
    }

    final now = DateTime.now();
    if (_lastExitAttemptAt == null ||
        now.difference(_lastExitAttemptAt!) > const Duration(seconds: 5)) {
      _lastExitAttemptAt = now;
      // 走 AppSnack 而不是裸 showSnackBar：它是全 App 出现频率最高的提示条之一，
      // 留在裸写法上会成为唯一一条还是通栏方块的提示，跟其余全部浮起圆角的对不上。
      // 中性色调 —— 这是操作指引，不是成功也不是失败。
      // replaceCurrent 等价于原来的 `..hideCurrentSnackBar()` 级联：AppSnack 内部
      // 就是先 hideCurrentSnackBar 再 showSnackBar，顺序与关闭原因(hide)都一致。
      AppSnack.show(
        context,
        '5秒内再按一次返回键退出应用',
        replaceCurrent: true,
        // 停留时长必须跟上面那个 5 秒判定窗口一致：提示消失即代表窗口关闭。
        duration: const Duration(seconds: 5),
      );
      return;
    }

    await SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;
    final idx = _currentIndex(context);

    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) => _handleBackPress(didPop),
      child: Scaffold(
        body: widget.child,
        extendBody: true,
        bottomNavigationBar: ClipRRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              decoration: BoxDecoration(
                color: isLight
                    ? Colors.white.withAlpha(230)
                    : AppColors.slate900.withAlpha(230),
                border: Border(
                  top: BorderSide(
                    color: isLight ? AppColors.slate200 : AppColors.slate800,
                    width: 0.5,
                  ),
                ),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      _NavItem(
                        icon: Icons.space_dashboard_outlined,
                        activeIcon: Icons.space_dashboard,
                        label: '主页',
                        isActive: idx == 0,
                        onTap: () => context.go('/dashboard'),
                      ),
                      _NavItem(
                        icon: Icons.schedule_outlined,
                        activeIcon: Icons.schedule,
                        label: '任务',
                        isActive: idx == 1,
                        onTap: () => context.go('/tasks'),
                      ),
                      _NavItem(
                        icon: Icons.terminal_outlined,
                        activeIcon: Icons.terminal,
                        label: '日志',
                        isActive: idx == 2,
                        onTap: () => context.go('/logs'),
                      ),
                      _NavItem(
                        icon: Icons.key_outlined,
                        activeIcon: Icons.key,
                        label: '变量',
                        isActive: idx == 3,
                        onTap: () => context.go('/envs'),
                      ),
                      _NavItem(
                        icon: Icons.menu_outlined,
                        activeIcon: Icons.menu,
                        label: '更多',
                        isActive: idx == 4,
                        onTap: () => context.go('/more'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = isActive
        ? AppColors.primary
        : Theme.of(context).colorScheme.onSurfaceVariant;

    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        // 内容高只有 22 + 2 + 12 = 36dp。外层那 6dp 的竖向 padding 在 GestureDetector
        // 之外，不计入命中区，所以底部导航实际是 36dp —— 全 App 点得最频繁的地方反而不达标。
        // 用 minHeight 抬到 44：导航栏总高只涨 8dp，图标与标签的排布不变。
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppTapTarget.min),
          child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(isActive ? activeIcon : icon, size: 22, color: color),
            const SizedBox(height: 2),
            SizedBox(
              height: 12,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 11,
                    color: color,
                    fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}
