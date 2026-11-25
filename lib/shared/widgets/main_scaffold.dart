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
    // 每次进入主界面跑一次、与落在哪一页无关的两件事（APP #24）。
    // 它们原来挂在主页的 initState 里，「默认打开页面」设成任务 / 日志 / 变量时就不会跑：
    // 1. 用户信息为空时补拉 —— 「更多」页的管理员分区靠它；
    // 2. 静默检查更新 —— 每次启动最多弹一次，由服务里的进程级标记保证（issue #19）。
    // 主页自己的数据加载仍留在主页。
    Future.microtask(() async {
      if (!mounted) return;
      if (ref.read(authProvider).user == null) {
        await ref.read(authProvider.notifier).refreshUser();
      }
      if (!mounted) return;
      await AppUpdateService.autoCheckAndPrompt(context);
    });
  }

  /// 当前落在哪个 Tab。二级路由（如 `/tasks/new`）不在外壳里，这里只会看到 5 个 Tab 路径。
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
    // 切换面板时主界面不会重建（「更多」页是 push 出服务器配置页的），上面 initState 不再跑；
    // 新面板恢复出的登录态可能没带用户信息，这里同样补拉一次。只在「有 → 没有」时触发，
    // 补拉失败状态不变，不会反复请求。
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
        // 内容延伸到底栏下面（玻璃底栏透出内容）。Scaffold 会把底栏高度并进 body 的
        // MediaQuery.padding.bottom，列表用 AppSpacing.listBottomOf(context) 就能让开底栏。
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

/// 底栏的一个 Tab。
class MainTab {
  final String route;
  final String label;
  final IconData icon;

  const MainTab(this.route, this.label, this.icon);
}

/// v2.0 底栏：任务（首页）/ 日志 / 概览 / 变量 / 设置。实心图标 + 文字。
const List<MainTab> mainTabs = [
  MainTab('/tasks', '任务', Icons.watch_later_rounded),
  MainTab('/logs', '日志', Icons.receipt_long_rounded),
  MainTab('/overview', '概览', Icons.bar_chart_rounded),
  MainTab('/envs', '变量', Icons.key_rounded),
  MainTab('/settings', '设置', Icons.settings_rounded),
];

/// 悬浮玻璃胶囊底栏（方案书 §2.4）。
///
/// - 选中项后面一块灰色药丸，切换时弹簧滑过去；
/// - 系统开了「移除动画」时：药丸直接跳，玻璃不做模糊、换成 92% 不透明的实色
///   （模糊是全屏最贵的一层绘制，顺带照顾低端机）。
class _GlassTabBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onSelect;

  const _GlassTabBar({required this.currentIndex, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final reduce = AppMotion.reduce(context);
    const radius = BorderRadius.all(
      Radius.circular(AppTabBarMetrics.height / 2),
    );

    Widget bar = DecoratedBox(
      decoration: BoxDecoration(
        color: reduce ? palette.glassSolid : palette.glass,
        borderRadius: radius,
        border: Border.all(color: palette.glassBorder, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final itemWidth = constraints.maxWidth / mainTabs.length;
            return Stack(
              children: [
                // 选中药丸
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
                      color: palette.fill,
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
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
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
          decoration: const BoxDecoration(
            borderRadius: radius,
            // 悬浮感只靠一层很淡的下投影；这是全 App 唯一带投影的东西
            boxShadow: [
              BoxShadow(
                color: Color(0x29000000),
                blurRadius: 30,
                spreadRadius: -10,
                offset: Offset(0, 10),
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
    // 未选中的项稍微淡一点（效果演示是 .82），选中靠后面的药丸区分。
    final color = selected
        ? palette.text
        : palette.text.withValues(alpha: 0.78);

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
            Icon(tab.icon, size: 23, color: color),
            const SizedBox(height: 2),
            // 大字号下标签缩小而不是撑破胶囊
            SizedBox(
              height: 14,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  tab.label,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
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
