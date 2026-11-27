import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_provider.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/widgets/app_notice.dart';
import '../../../shared/widgets/app_pill_button.dart';
import '../../../shared/widgets/app_segmented.dart';
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
    final palette = context.palette;
    final methods = <_UnlockMethod>[
      if (widget.state.hasBiometric) _UnlockMethod.biometric,
      if (widget.state.hasPassword) _UnlockMethod.password,
      if (widget.state.hasPattern) _UnlockMethod.pattern,
    ];

    return Material(
      // v2.0：遮罩用页面底色半透明 + 模糊（iOS 毛玻璃锁屏），明暗跟着主题走；
      // 背后的内容糊到看不清，卡片靠和遮罩的明度差浮出来，不再需要描边补偿。
      color: palette.bg.withValues(alpha: 0.6),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Container(
                margin: const EdgeInsets.all(20),
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: palette.card,
                  borderRadius: BorderRadius.circular(AppRadius.card),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: palette.tint(palette.accent),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.lock_rounded,
                          size: 30,
                          color: palette.accent,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '应用已锁定',
                      style: AppText.section.copyWith(
                        fontWeight: FontWeight.w600,
                        color: palette.text,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '请完成二次验证后继续使用当前服务器与任务。',
                      style: AppText.caption.copyWith(color: palette.text2),
                    ),
                    if (methods.length > 1) ...[
                      const SizedBox(height: 18),
                      // v1.x 是一排 ChoiceChip，v2.0 换成分段控件
                      AppSegmented<_UnlockMethod>(
                        segments: [
                          for (final method in methods)
                            (method, _methodLabel(method, widget.state)),
                        ],
                        value: _activeMethod ?? methods.first,
                        onChanged: (method) {
                          setState(() {
                            _activeMethod = method;
                            _error = null;
                            _patternPoints = const [];
                          });
                          if (method == _UnlockMethod.biometric) {
                            _tryAutoBiometric();
                          }
                        },
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
                      AppNotice(
                        color: palette.err,
                        text: _error!,
                        accentText: true,
                        textAlign: TextAlign.center,
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
        AppPillButton(
          label: _submitting ? '验证中...' : '解锁',
          icon: Icons.lock_open_rounded,
          expand: true,
          height: 50,
          onPressed: _submitting ? null : _unlockWithPassword,
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
        AppPillButton(
          label: _submitting ? '验证中...' : '验证图案',
          icon: Icons.gesture_rounded,
          expand: true,
          height: 50,
          onPressed: _submitting ? null : _unlockWithPattern,
        ),
      ],
    );
  }

  Widget _buildBiometricView(BuildContext context) {
    final palette = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 这一块是 42px 大图标 + 居中标题 + 居中描述的竖排主视觉，不是提示条，
        // 所以不走 AppNotice，直接画强调色浅底。
        Container(
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: BoxDecoration(
            color: palette.tint(palette.accent),
            borderRadius: BorderRadius.circular(AppRadius.tile),
          ),
          child: Column(
            children: [
              // 浅底上的图标用实色（palette 规则：只有「字」才要换墨色）
              Icon(Icons.fingerprint, size: 42, color: palette.accent),
              const SizedBox(height: 12),
              Text(
                '使用${widget.state.biometricLabel}解锁',
                style: AppText.body.copyWith(
                  fontWeight: FontWeight.w700,
                  color: palette.text,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                '系统会调用设备已启用的生物识别能力完成验证。',
                style: AppText.caption.copyWith(color: palette.text2),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        AppPillButton(
          label: _submitting ? '验证中...' : '重新验证',
          icon: Icons.verified_user_rounded,
          expand: true,
          height: 50,
          onPressed: _submitting
              ? null
              : () => _unlockWithBiometric(showFailureMessage: true),
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
