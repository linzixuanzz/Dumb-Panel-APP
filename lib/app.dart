import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_mode_provider.dart';
import 'features/app_lock/widgets/app_lock_gate.dart';

// 本地化配置单独导出，测试直接复用同一份。
const appLocalizationsDelegates = <LocalizationsDelegate<dynamic>>[
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];
const appSupportedLocales = [Locale('zh', 'CN'), Locale('en')];

class DaidaiApp extends ConsumerStatefulWidget {
  const DaidaiApp({super.key});

  @override
  ConsumerState<DaidaiApp> createState() => _DaidaiAppState();
}

class _DaidaiAppState extends ConsumerState<DaidaiApp>
    with WidgetsBindingObserver {
  /// 系统「移除动画 / 减弱动态效果」开关。
  ///
  /// 为什么不用 `MediaQuery.disableAnimations`：MaterialApp 自己才创建 MediaQuery，
  /// 它上面这一层拿不到；而切明暗的渐变（`themeAnimationDuration`）恰恰是在
  /// MaterialApp 里、builder 之外做的，builder 里也关不掉。所以直接读平台的
  /// 无障碍开关（MediaQuery 的这一项也是从这里来的），并在系统设置变化时刷新。
  bool _reduceMotion = _platformReduceMotion();

  static bool _platformReduceMotion() => WidgetsBinding
      .instance
      .platformDispatcher
      .accessibilityFeatures
      .disableAnimations;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAccessibilityFeatures() {
    final next = _platformReduceMotion();
    if (next != _reduceMotion) setState(() => _reduceMotion = next);
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);
    // 明暗设置（浅色 / 深色 / 跟随系统），存本机、所有面板共用。
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp.router(
      title: '呆呆面板',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      // 减少动画时切明暗直接切，不做主题渐变；否则用 MaterialApp 的默认时长。
      themeAnimationDuration: _reduceMotion
          ? Duration.zero
          : kThemeAnimationDuration,
      routerConfig: router,
      locale: const Locale('zh', 'CN'),
      // 不挂这三个 delegate，长按输入框的复制/粘贴/全选菜单会是英文（APP #17）。
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: appSupportedLocales,
      builder: (context, child) =>
          AppLockGate(child: child ?? const SizedBox.shrink()),
    );
  }
}
