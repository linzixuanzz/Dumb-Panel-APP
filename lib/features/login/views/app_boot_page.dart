import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_provider.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/storage/secure_storage.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/widgets/app_state_views.dart';
import '../../dashboard/providers/dashboard_provider.dart';

/// 启动流程的步骤。
///
/// 失败态必须把「卡在哪一步」显示出来：issue #7 的现场是一张空白的开屏页，
/// 用户除了「打不开」之外给不出任何信息，无从判断是本地读取、面板探测还是自动登录。
enum _BootStep {
  readLocalConfig('读取本地配置'),
  checkPanel('检查面板状态'),
  autoLogin('自动登录');

  const _BootStep(this.label);

  /// 失败态里显示的步骤名。
  final String label;

  /// 进行中时开屏页的文案。
  ///
  /// [readLocalConfig] 必须是 null：v1.3.4 在这一步不改文案（显示的是
  /// 「正在启动呆呆面板...」），给它补一句就等于在正常路径上多一屏。
  String? get runningMessage => switch (this) {
    _BootStep.readLocalConfig => null,
    _BootStep.checkPanel => '正在检查面板状态...',
    _BootStep.autoLogin => '正在自动登录...',
  };
}

/// 某一步超过了自己的时间上限。
///
/// 与整体超时（[TimeoutException]）分成两类，是为了把「卡在哪一步」带进失败态。
class _BootStepTimeout implements Exception {
  const _BootStepTimeout(this.step, this.limit);

  final _BootStep step;
  final Duration limit;
}

/// 启动失败的快照，失败态 UI 完全由它渲染。
class _BootFailure {
  const _BootFailure({required this.step, required this.reason});

  final _BootStep step;
  final String reason;
}

class AppBootPage extends ConsumerStatefulWidget {
  /// 三个时限都可注入，**仅供测试**在假时钟里立刻走到超时；生产路径用默认值。
  const AppBootPage({
    super.key,
    this.localStepTimeout = const Duration(seconds: 10),
    this.networkStepTimeout = const Duration(seconds: 50),
    this.overallTimeout = const Duration(seconds: 75),
  });

  /// 读本地存储（SharedPreferences / 安全存储）这类步骤的上限。
  final Duration localStepTimeout;

  /// 要走网络的步骤（面板探测、自动登录）的上限。
  ///
  /// 取 50 秒是为了**不抢在 dio 前面**：`dio_client.dart` 配的是 connect 15s /
  /// receive 30s，而这两个是**可叠加**的 —— 连接慢 14s 再接收 20s 合计 34s，dio 自己
  /// 不超时。所以上限必须大于 45s 这个最坏值，否则一台冷启动/反代很慢但确实可用的面板，
  /// 会从「等到响应、继续走到登录页」退化成「启动没能完成」，那是正常路径的回归，比卡开屏更糟。
  /// 50s 仍远小于 75s 的整体上限，真卡住时的自救能力不受影响。
  /// 本页的时限真正要兜的是 dio 兜不住的那一类：平台通道不回调、future 永不完成。
  final Duration networkStepTimeout;

  /// 整个启动流程的兜底上限，防止「每一步都没超时、合起来却永远走不完」。
  final Duration overallTimeout;

  @override
  ConsumerState<AppBootPage> createState() => _AppBootPageState();
}

class _AppBootPageState extends ConsumerState<AppBootPage> {
  /// 启动流程是否正在执行。
  ///
  /// v1.3.4 里它叫 `_jumping`，置真之后**永不复位**：流程只要因为任何原因停在半路，
  /// 后续每一次触发都会被开头那行直接 return 掉，页面就永远停在转圈。
  /// 现在改成「进行中」标记，流程结束（跳转 / 失败 / 异常）一律在 finally 里复位，
  /// 「重试」才能真正重跑一遍。
  bool _running = false;

  String? _bootMessage;

  /// 当前走到哪一步。整体超时和未知异常都靠它说明卡在哪儿。
  _BootStep _currentStep = _BootStep.readLocalConfig;

  /// 非空即进入失败态。
  _BootFailure? _failure;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runBootFlow();
    });
  }

  Future<void> _runBootFlow() async {
    if (_running) {
      return;
    }

    _running = true;
    _currentStep = _BootStep.readLocalConfig;
    // 只在真的需要回到初始形态时才 setState：首次启动这两个字段本来就是 null，
    // 无条件调一次会在正常路径上凭空多一次重建 —— v1.3.4 没有这一下。
    if (mounted && (_failure != null || _bootMessage != null)) {
      setState(() {
        _failure = null;
        _bootMessage = null;
      });
    }

    try {
      await _bootSteps().timeout(widget.overallTimeout);
    } on _BootStepTimeout catch (e) {
      _enterFailure(e.step, '这一步超过 ${_formatLimit(e.limit)} 没有响应');
    } on TimeoutException {
      _enterFailure(
        _currentStep,
        '启动流程超过 ${_formatLimit(widget.overallTimeout)} 仍未完成',
      );
    } catch (e) {
      // 走 extractListErrorMessage 而不是 extractErrorMessage：后者在后端没给
      // error/message 时会退回 DioException 的英文 message，而这段文案是摊在
      // 整屏中央给用户看的。
      _enterFailure(_currentStep, extractListErrorMessage(e, '启动时发生未知错误'));
    } finally {
      // 失败、成功跳转、中途 return 都要复位，否则「重试」会被开头那行挡掉。
      _running = false;
    }
  }

  /// 启动流程本体。每一步的语义与 v1.3.4 逐条一致，只是各自加了时间上限。
  Future<void> _bootSteps() async {
    // 先确认有没有当前服务器，没有就直接去服务器配置页。
    final serverUrl = await _step(
      _BootStep.readLocalConfig,
      widget.localStepTimeout,
      SecureStorage.getServerUrl(),
    );
    if (serverUrl == null || serverUrl.isEmpty) {
      _go('/server-config');
      return;
    }

    DioClient.instance.setBaseUrl(serverUrl);

    if (!mounted) {
      return;
    }

    // 7 天可信会话内，直接进首页，不再重复请求登录接口。
    final authState = ref.read(authProvider);
    if (authState.status == AuthStatus.authenticated) {
      try {
        ref.invalidate(dashboardProvider);
      } catch (_) {}
      _go('/dashboard');
      return;
    }

    // 读取当前面板，决定是否允许静默自动登录。
    final currentPanel = await _step(
      _BootStep.readLocalConfig,
      widget.localStepTimeout,
      SecureStorage.getCurrentPanel(),
    );
    if (currentPanel == null) {
      _go('/login');
      return;
    }

    if (!mounted) {
      return;
    }

    try {
      await _step(
        _BootStep.checkPanel,
        widget.networkStepTimeout,
        ref.read(authProvider.notifier).checkInit(),
      );
      final latestAuthState = ref.read(authProvider);
      if (latestAuthState.needsInit) {
        _go('/login');
        return;
      }
    } on _BootStepTimeout {
      // 超时＝真的卡住了，必须让用户看到失败态。
      // 其余异常保持 v1.3.4 的「不阻塞」语义 —— checkInit 自身已经吞掉所有错误，
      // 这里改成硬失败会让「老面板没有 check-init 路由」之类的情况登不进去。
      rethrow;
    } catch (_) {
      // 初始化检测失败时不阻塞，交给登录页继续处理。
    }

    final canAutoLogin =
        currentPanel.rememberPassword &&
        currentPanel.autoLogin &&
        (currentPanel.username?.trim().isNotEmpty ?? false) &&
        (currentPanel.password?.isNotEmpty ?? false);

    if (!canAutoLogin) {
      _go('/login');
      return;
    }

    if (!mounted) {
      return;
    }

    try {
      final result = await _step(
        _BootStep.autoLogin,
        widget.networkStepTimeout,
        ref
            .read(authProvider.notifier)
            .login(
              username: currentPanel.username!.trim(),
              password: currentPanel.password!,
            ),
      );

      if (!mounted) {
        return;
      }

      if (result['access_token'] == null ||
          result['access_token'].toString().isEmpty) {
        _go('/login?manual=1');
        return;
      }

      await _step(
        _BootStep.autoLogin,
        widget.localStepTimeout,
        SecureStorage.savePanel(
          currentPanel.copyWith(
            username: currentPanel.username!.trim(),
            password: currentPanel.password,
            rememberPassword: true,
            autoLogin: true,
          ),
        ),
      );

      if (!mounted) {
        return;
      }

      // 仪表盘预加载**不再 await**：v1.3.4 在这里等它回来才跳转，于是
      // 「首页数据慢 / 不返回」直接等于「卡在开屏页」，而当时那一屏连按钮都没有。
      //
      // 取舍：DashboardPage 自己的 initState 里还会 load() 一次
      //（dashboard_page.dart:32-38），所以不等它并不会让首页空着 ——
      // 最坏情况只是数据晚一两帧到；换来的是跳转不再被任何网络请求拖住。
      // 请求仍然在跳转前就发出去，「进首页就有数据」的体验保持不变。
      ref.invalidate(dashboardProvider);
      unawaited(_preloadDashboard());

      _go('/dashboard');
      return;
    } on _BootStepTimeout {
      rethrow;
    } catch (_) {
      // 自动登录失败时回到手动登录，但保留记住密码，方便用户重新确认。
      _go('/login?manual=1');
      return;
    }
  }

  /// 跑一步，并给它一个时间上限；超时抛 [_BootStepTimeout]，带着「是哪一步」。
  Future<T> _step<T>(_BootStep step, Duration limit, Future<T> future) {
    _currentStep = step;
    final message = step.runningMessage;
    if (mounted && message != _bootMessage) {
      setState(() {
        _bootMessage = message;
      });
    }

    return future.timeout(
      limit,
      onTimeout: () => throw _BootStepTimeout(step, limit),
    );
  }

  /// 仪表盘预加载。失败与否都不影响启动 —— 首页自己还会再 load 一次。
  Future<void> _preloadDashboard() async {
    try {
      await ref.read(dashboardProvider.notifier).load();
    } catch (_) {}
  }

  void _enterFailure(_BootStep step, String reason) {
    if (!mounted) {
      return;
    }

    // GoRouter 的 redirect 会把 status == unknown 的**任何**路由打回 /boot
    //（`app_router.dart` 的 `if (isUnknown) return '/boot';`），那样下面四个出口
    // 会全部原地弹回本页，等于没有出口 —— 正是这次要消灭的那类「出不去」。
    // 正常启动路径上 main() 的 restoreTrustedLocalSession() 已经把状态置成
    // authenticated / unauthenticated，这里只兜住万一。
    if (ref.read(authProvider).status == AuthStatus.unknown) {
      ref.read(authProvider.notifier).setUnauthenticated();
    }

    setState(() {
      _failure = _BootFailure(step: step, reason: reason);
    });
  }

  void _backToLogin() {
    // 必须先落到 unauthenticated：卡住时登录态可能仍是 authenticated
    //（可信会话还在 7 天有效期内），那样 GoRouter 会把 /login 直接弹回 /dashboard，
    // 用户会以为按钮是坏的。与 server_config_page._switchToPanel 同一处理，
    // 只改登录态，不动本地凭据。
    ref.read(authProvider.notifier).setUnauthenticated();
    _go('/login?manual=1');
  }

  void _openServerConfig() {
    // manual=1 不能省：不带它时 redirect 会按登录态把 /server-config
    // 直接弹回 /dashboard 或 /login（`app_router.dart` 的 isServerConfig 分支）。
    _go('/server-config?manual=1');
  }

  Future<void> _clearLocalSession() async {
    // issue #7 的用户是「清空应用数据」才恢复的。这里给出同等效果里**最小**的一档：
    // 只清 token / 用户 / 可信会话，保留面板地址与账号配置，用户不必重新填地址。
    // 跳的是 /login 而不是 /boot：清完立刻重跑自动登录，很可能又卡在同一个地方。
    await SecureStorage.clearAuthSession();
    if (!mounted) {
      return;
    }
    ref.read(authProvider.notifier).setUnauthenticated();
    _go('/login?manual=1');
  }

  String _formatLimit(Duration limit) {
    if (limit.inSeconds >= 1) {
      return '${limit.inSeconds} 秒';
    }
    return '${limit.inMilliseconds} 毫秒';
  }

  void _go(String location) {
    if (!mounted) {
      return;
    }
    context.go(location);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failure = _failure;

    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: failure == null
              ? _buildLoading(theme)
              : _buildFailure(theme, failure),
        ),
      ),
    );
  }

  /// 正常路径的那一屏。**与 v1.3.4 逐像素一致**，改动它就是改正常启动体验。
  Widget _buildLoading(ThemeData theme) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Image.asset('assets/icon.png', width: 72, height: 72),
        const SizedBox(height: 20),
        const SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 3),
        ),
        const SizedBox(height: 20),
        Text(
          _bootMessage ?? '正在启动呆呆面板...',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// 可自救的失败态：说明卡在哪一步，并给四个出口。
  ///
  /// 复用 [AppErrorView]（列表页的错误态同款）拿到「图标 + 标题 + 原因 + 重试」，
  /// 另外三个出口摆在下面。用 Wrap 是因为三个中文按钮在 400dp 窄屏上排不下一行。
  Widget _buildFailure(ThemeData theme, _BootFailure failure) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppErrorView(
            title: '启动没能完成',
            message: '卡在「${failure.step.label}」：${failure.reason}',
            onRetry: _runBootFlow,
            icon: Icons.hourglass_empty,
            padding: EdgeInsets.zero,
          ),
          const SizedBox(height: AppSpacing.lg),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: AppSpacing.sm,
            children: [
              TextButton.icon(
                onPressed: _backToLogin,
                icon: const Icon(Icons.login, size: 18),
                label: const Text('返回登录'),
              ),
              TextButton.icon(
                onPressed: _openServerConfig,
                icon: const Icon(Icons.swap_horiz, size: 18),
                label: const Text('重新配置面板'),
              ),
              TextButton.icon(
                onPressed: _clearLocalSession,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('清除本地会话'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            '「清除本地会话」只清登录凭据，面板地址和账号配置会保留。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
