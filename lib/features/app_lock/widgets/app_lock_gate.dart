import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/app_card.dart';
import '../providers/app_lock_provider.dart';
import 'pattern_pad.dart';

class AppLockGate extends ConsumerStatefulWidget {
  const AppLockGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends ConsumerState<AppLockGate> {
  late final ProviderSubscription<AuthStatus> _authSubscription;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      final controller = ref.read(appLockProvider.notifier);
      await controller.initialize();
      if (ref.read(authProvider).status == AuthStatus.authenticated) {
        controller.lockIfEnabled();
      }
    });

    _authSubscription = ref.listenManual<AuthStatus>(
      authProvider.select((state) => state.status),
      (previous, next) async {
        final controller = ref.read(appLockProvider.notifier);
        if (next == AuthStatus.authenticated) {
          await controller.initialize();
          controller.lockIfEnabled();
          return;
        }
        controller.resetSession();
      },
    );
  }

  @override
  void dispose() {
    _authSubscription.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final lockState = ref.watch(appLockProvider);
    final showOverlay =
        auth.status == AuthStatus.authenticated &&
        lockState.isEnabled &&
        lockState.locked;

    return Stack(
      children: [
        widget.child,
        if (showOverlay)
          Positioned.fill(
            child: _AppLockOverlay(
              state: lockState,
              controller: ref.read(appLockProvider.notifier),
            ),
          ),
      ],
    );
  }
}

enum _UnlockMethod { biometric, password, pattern }

class _AppLockOverlay extends StatefulWidget {
  const _AppLockOverlay({required this.state, required this.controller});

  final AppLockState state;
  final AppLockController controller;

  @override
  State<_AppLockOverlay> createState() => _AppLockOverlayState();
}

class _AppLockOverlayState extends State<_AppLockOverlay> {
  final TextEditingController _passwordController = TextEditingController();
  List<int> _patternPoints = const [];
  _UnlockMethod? _activeMethod;
  String? _error;
  bool _submitting = false;
  bool _autoBiometricTried = false;

  @override
  void initState() {
    super.initState();
    _activeMethod = _resolveInitialMethod(widget.state);
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryAutoBiometric());
  }

  @override
  void didUpdateWidget(covariant _AppLockOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state.locked != widget.state.locked && widget.state.locked) {
      _passwordController.clear();
      _patternPoints = const [];
      _error = null;
      _submitting = false;
      _autoBiometricTried = false;
      _activeMethod = _resolveInitialMethod(widget.state);
      WidgetsBinding.instance.addPostFrameCallback((_) => _tryAutoBiometric());
    }
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  _UnlockMethod? _resolveInitialMethod(AppLockState state) {
    if (state.hasBiometric) return _UnlockMethod.biometric;
    if (state.hasPassword) return _UnlockMethod.password;
    if (state.hasPattern) return _UnlockMethod.pattern;
    return null;
  }

  Future<void> _tryAutoBiometric() async {
    if (_autoBiometricTried ||
        _submitting ||
        _activeMethod != _UnlockMethod.biometric) {
      return;
    }
    _autoBiometricTried = true;
    await _unlockWithBiometric(showFailureMessage: false);
  }

  Future<void> _unlockWithPassword() async {
    if (_passwordController.text.trim().isEmpty) {
      setState(() => _error = '请输入应用锁密码');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    final ok = await widget.controller.unlockWithPassword(
      _passwordController.text.trim(),
    );
    final notice = widget.controller.getUnlockNotice();
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _error = ok ? null : (notice ?? '密码不正确');
      if (ok) {
        _passwordController.clear();
      }
    });
  }

  Future<void> _unlockWithPattern() async {
    if (_patternPoints.length < 4) {
      setState(() => _error = '请至少选择 4 个点');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    final ok = await widget.controller.unlockWithPattern(_patternPoints);
    final notice = widget.controller.getUnlockNotice();
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _error = ok ? null : (notice ?? '图案不正确');
      if (!ok) {
        _patternPoints = const [];
      }
    });
  }

  Future<void> _unlockWithBiometric({required bool showFailureMessage}) async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    final ok = await widget.controller.unlockWithBiometric();
    final notice = widget.controller.getUnlockNotice();
    if (!mounted) return;
    setState(() {
      _submitting = false;
      if (!ok && showFailureMessage) {
        _error = notice ?? '${widget.state.biometricLabel}验证未通过';
      }
    });
  }

  void _togglePatternPoint(int point) {
    if (_patternPoints.contains(point)) {
      return;
    }
    setState(() {
      _patternPoints = [..._patternPoints, point];
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;
    final methods = <_UnlockMethod>[
      if (widget.state.hasBiometric) _UnlockMethod.biometric,
      if (widget.state.hasPassword) _UnlockMethod.password,
      if (widget.state.hasPattern) _UnlockMethod.pattern,
    ];

    return Material(
      color: Colors.black.withAlpha(140),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AppCard(
                margin: const EdgeInsets.all(20),
                padding: const EdgeInsets.all(20),
                // 深色模式的卡面是 slate950（比常规卡片的 slate900 更深，
                // 用来压住背后的模糊遮罩），必须显式传入。
                color: isLight ? Colors.white : AppColors.slate950,
                // 删掉全库最强的那道投影（blur 24 / offset 0,14）之后，这张卡片
                // 在深色模式下唯一的分隔物就只剩这条 1px 边：卡面 slate950 与它下方
                // 「黑色 alpha140 遮罩 + 14px 模糊」的背景几乎同色（约 1.0:1），
                // 原来的 slate800 边对该背景只有约 1.4:1，等于看不见。
                // 因此边框同步提到 slate700（约 2.0:1）——补边框，不恢复投影。
                // 这里不能落到 AppCard 默认的 cardBorder（slate800），否则前一个
                // 提交的补偿会被静默打回原状。
                borderColor: isLight ? AppColors.slate200 : AppColors.slate700,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withAlpha(22),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.lock_outline,
                        size: 30,
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      '应用已锁定',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '请完成二次验证后继续使用当前服务器与任务。',
                      style: TextStyle(
                        fontSize: 13,
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                    if (methods.length > 1) ...[
                      const SizedBox(height: 18),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: methods.map((method) {
                          final selected = _activeMethod == method;
                          return ChoiceChip(
                            label: Text(_methodLabel(method, widget.state)),
                            selected: selected,
                            onSelected: (_) {
                              setState(() {
                                _activeMethod = method;
                                _error = null;
                                _patternPoints = const [];
                              });
                              if (method == _UnlockMethod.biometric) {
                                _tryAutoBiometric();
                              }
                            },
                          );
                        }).toList(),
                      ),
                    ],
                    const SizedBox(height: 20),
                    if (_activeMethod == _UnlockMethod.password)
                      _buildPasswordView(context)
                    else if (_activeMethod == _UnlockMethod.pattern)
                      _buildPatternView(context)
                    else
                      _buildBiometricView(context),
                    if (_error != null) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.red500.withAlpha(14),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: AppColors.red500.withAlpha(36),
                          ),
                        ),
                        child: Text(
                          _error!,
                          style: const TextStyle(
                            color: AppColors.red500,
                            fontSize: 13,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPasswordView(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _passwordController,
          obscureText: true,
          enabled: !_submitting,
          onSubmitted: (_) => _unlockWithPassword(),
          decoration: const InputDecoration(
            labelText: '应用锁密码',
            hintText: '请输入密码',
            prefixIcon: Icon(Icons.password_outlined),
          ),
        ),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: _submitting ? null : _unlockWithPassword,
          icon: const Icon(Icons.lock_open_outlined, size: 18),
          label: Text(_submitting ? '验证中...' : '解锁'),
        ),
      ],
    );
  }

  Widget _buildPatternView(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PatternPad(
          selectedPoints: _patternPoints,
          onPointTap: _togglePatternPoint,
          onClear: () => setState(() => _patternPoints = const []),
          onBackspace: () => setState(() {
            if (_patternPoints.isEmpty) return;
            _patternPoints = _patternPoints.sublist(
              0,
              _patternPoints.length - 1,
            );
          }),
          title: '图案验证',
          subtitle: '按顺序点击已设置的图案点位',
        ),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: _submitting ? null : _unlockWithPattern,
          icon: const Icon(Icons.gesture_outlined, size: 18),
          label: Text(_submitting ? '验证中...' : '验证图案'),
        ),
      ],
    );
  }

  Widget _buildBiometricView(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.primary.withAlpha(12),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.primary.withAlpha(28)),
          ),
          child: Column(
            children: [
              const Icon(Icons.fingerprint, size: 42, color: AppColors.primary),
              const SizedBox(height: 12),
              Text(
                '使用${widget.state.biometricLabel}解锁',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                '系统会调用设备已启用的生物识别能力完成验证。',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: _submitting
              ? null
              : () => _unlockWithBiometric(showFailureMessage: true),
          icon: const Icon(Icons.verified_user_outlined, size: 18),
          label: Text(_submitting ? '验证中...' : '重新验证'),
        ),
      ],
    );
  }

  String _methodLabel(_UnlockMethod method, AppLockState state) {
    switch (method) {
      case _UnlockMethod.password:
        return '密码';
      case _UnlockMethod.pattern:
        return '图案';
      case _UnlockMethod.biometric:
        return state.biometricLabel;
    }
  }
}
