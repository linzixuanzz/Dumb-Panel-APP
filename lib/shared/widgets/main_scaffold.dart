import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/auth/auth_provider.dart';
import '../../core/services/app_update_service.dart';
import '../../core/theme/design_tokens.dart';
import 'app_snack.dart';

class MainScaffold extends ConsumerStatefulWidget {
  final Widget child;

  const MainScaffold({super.key, required this.child});

  @override
  ConsumerState<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends ConsumerState<MainScaffold> {
  DateTime? _lastExitAttemptAt;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      if (!mounted) return;
      if (ref.read(authProvider).user == null) {
        await ref.read(authProvider.notifier).refreshUser();
      }
      if (!mounted) return;
      await AppUpdateService.autoCheckAndPrompt(context);
    });
  }

  int _currentIndex(BuildContext context) {
    final location = GoRouterState.of(context).matchedLocation;
    for (var i = 0; i < mainTabs.length; i++) {
      if (location.startsWith(mainTabs[i].route)) return i;
    }
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
      AppSnack.show(
        context,
        '5秒内再按一次返回键退出应用',
        replaceCurrent: true,
        duration: const Duration(seconds: 5),
      );
      return;
    }

    await SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AuthState>(authProvider, (previous, next) {
      if (next.status == AuthStatus.authenticated &&
          next.user == null &&
          previous?.user != null) {
        ref.read(authProvider.notifier).refreshUser();
      }
    });
    final idx = _currentIndex(context);

    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) => _handleBackPress(didPop),
      child: Scaffold(
        body: widget.child,
        extendBody: true,
        bottomNavigationBar: _GlassTabBar(
          currentIndex: idx,
          onSelect: (i) {
            if (i != idx) context.go(mainTabs[i].route);
          },
        ),
      ),
    );
  }
}

/// 底栏单个 Tab 定义。
class MainTab {
  final String route;
  final String label;
  final IconData icon;
  final IconData activeIcon;

  const MainTab(this.route, this.label, this.icon, [IconData? activeIcon])
    : activeIcon = activeIcon ?? icon;
}

/// v3.0 Nordic Calm 五栏轻盈导航：线性图标 + 克制钴蓝激活态。
const List<MainTab> mainTabs = [
  MainTab(
    '/tasks',
    '任务',
    Icons.schedule_outlined,
    Icons.schedule_rounded,
  ),
  MainTab(
    '/logs',
    '日志',
    Icons.article_outlined,
    Icons.article_rounded,
  ),
  MainTab(
    '/overview',
    '概览',
    Icons.space_dashboard_outlined,
    Icons.space_dashboard_rounded,
  ),
  MainTab(
    '/envs',
    '变量',
    Icons.vpn_key_outlined,
    Icons.vpn_key_rounded,
  ),
  MainTab(
    '/settings',
    '设置',
    Icons.tune_rounded,
    Icons.tune_rounded,
  ),
];

class _GlassTabBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onSelect;

  const _GlassTabBar({required this.currentIndex, required this.onSelect});

  static const double _inset = 4;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final reduce = AppMotion.reduce(context);
    const radius = BorderRadius.all(Radius.circular(AppRadius.pill));

    Widget bar = DecoratedBox(
      decoration: BoxDecoration(
        color: reduce ? palette.glassSolid : palette.glass,
        borderRadius: radius,
        border: Border.all(color: palette.glassBorder, width: 0.8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(_inset),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final itemWidth = constraints.maxWidth / mainTabs.length;
            return Stack(
              children: [
                AnimatedPositioned(
                  duration: AppMotion.of(context, AppMotion.slide),
                  curve: AppMotion.spring,
                  left: itemWidth * currentIndex,
                  top: 0,
                  bottom: 0,
                  width: itemWidth,
                  child: DecoratedBox(
                    key: const Key('main-tab-pill'),
                    decoration: BoxDecoration(
                      color: palette.tint(palette.accent),
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                  ),
                ),
                Row(
                  children: [
                    for (var i = 0; i < mainTabs.length; i++)
                      Expanded(
                        child: _TabItem(
                          tab: mainTabs[i],
                          selected: i == currentIndex,
                          onTap: () => onSelect(i),
                        ),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
    if (!reduce) {
      bar = BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: bar,
      );
    }

    return SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: AppTabBarMetrics.bottomGap),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTabBarMetrics.sideGap,
        ),
        child: Container(
          height: AppTabBarMetrics.height,
          decoration: BoxDecoration(
            borderRadius: radius,
            boxShadow: [
              BoxShadow(
                color: palette.isLight
                    ? const Color(0x140F172A)
                    : const Color(0x47000000),
                blurRadius: 28,
                spreadRadius: -6,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: ClipRRect(borderRadius: radius, child: bar),
        ),
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  final MainTab tab;
  final bool selected;
  final VoidCallback onTap;

  const _TabItem({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final color = selected ? palette.accentInk : palette.text2;

    return Semantics(
      button: true,
      selected: selected,
      label: tab.label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              selected ? tab.activeIcon : tab.icon,
              size: 20,
              color: color,
            ),
            const SizedBox(height: 2),
            SizedBox(
              height: 14,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  tab.label,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: color,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
