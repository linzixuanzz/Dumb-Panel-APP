import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/storage/secure_storage.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../dashboard/providers/dashboard_provider.dart';
import '../widgets/geetest_captcha_dialog.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _totpController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _loading = false;
  bool _obscurePassword = true;
  bool _needsInit = false;
  bool _needsTotp = false;
  bool _rememberPassword = false;
  bool _autoLogin = false;
  String? _error;
  String? _currentUrl;
  List<PanelConfig> _panels = [];
  PanelConfig? _selectedPanel;

  Future<Map<String, dynamic>?> _prepareCaptchaIfEnabled(
    String username,
  ) async {
    final config = await ref
        .read(authProvider.notifier)
        .captchaConfig(username: username);
    final enabled = config['enabled'] == true;
    if (!enabled) {
      return null;
    }

    final captchaId = config['captcha_id']?.toString().trim() ?? '';
    if (captchaId.isEmpty || config['configured'] == false) {
      throw _LoginFlowMessage(
        config['message']?.toString() ?? '验证码未配置完整，请先在 Web 端检查极验配置',
      );
    }

    if (!mounted) {
      throw const _LoginFlowMessage('登录页面已关闭');
    }
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => GeeTestCaptchaDialog(captchaId: captchaId),
    );
    if (result == null) {
      throw _LoginFlowMessage('请先完成滑块验证');
    }
    return result;
  }

  @override
  void initState() {
    super.initState();
    _initCheck();
  }

  Future<void> _initCheck() async {
    final serverUrl = await SecureStorage.getServerUrl();
    if (serverUrl == null || serverUrl.isEmpty) {
      if (mounted) context.go('/server-config');
      return;
    }
    _currentUrl = serverUrl;
    DioClient.instance.setBaseUrl(serverUrl);

    _panels = await SecureStorage.getPanels();
    _selectedPanel = _panels.where((p) => p.url == serverUrl).firstOrNull;

    if (_selectedPanel != null) {
      _rememberPassword = _selectedPanel!.rememberPassword;
      _autoLogin =
          _selectedPanel!.rememberPassword && _selectedPanel!.autoLogin;
      if (_selectedPanel!.rememberPassword &&
          _selectedPanel!.username != null) {
        _usernameController.text = _selectedPanel!.username!;
        if (_selectedPanel!.password != null) {
          _passwordController.text = _selectedPanel!.password!;
        }
      }
    }

    // 被 AuthInterceptor 踢回登录页时（token 续期失败），把原因显示出来。
    final sessionError = ref.read(authProvider).error;
    if (sessionError != null && sessionError.trim().isNotEmpty) {
      _error = sessionError;
    }

    if (mounted) setState(() {});

    if (ref.read(authProvider).status == AuthStatus.authenticated) {
      if (mounted) {
        context.go('/dashboard');
      }
      return;
    }

    try {
      final auth = ref.read(authProvider.notifier);
      await auth.checkInit();
      final authState = ref.read(authProvider);
      if (mounted) setState(() => _needsInit = authState.needsInit);
    } catch (_) {}
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    final auth = ref.read(authProvider.notifier);
    final initializing = _needsInit;

    try {
      if (initializing) {
        try {
          await auth.initAdmin(
            _usernameController.text.trim(),
            _passwordController.text,
          );
        } catch (_) {}
        setState(() => _needsInit = false);
      }

      final captcha = initializing
          ? null
          : await _prepareCaptchaIfEnabled(_usernameController.text.trim());
      if (!mounted) {
        return;
      }

      final result = await auth.login(
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        totpCode: _needsTotp ? _totpController.text.trim() : null,
        captcha: captcha,
      );

      if (result['two_factor_required'] == true) {
        setState(() {
          _needsTotp = true;
          _error = result['error']?.toString() ?? '请输入两步验证码';
          _loading = false;
        });
        return;
      }

      if (result['captcha_required'] == true) {
        setState(() {
          _error = result['error']?.toString() ?? '验证码已失效，请重新完成滑块验证';
          _loading = false;
        });
        return;
      }

      // 保存偏好
      if (_currentUrl != null) {
        await SecureStorage.savePanel(
          PanelConfig(
            url: _currentUrl!,
            name: _selectedPanel?.name.isNotEmpty == true
                ? _selectedPanel!.name
                : _currentUrl!,
            username: _rememberPassword
                ? _usernameController.text.trim()
                : null,
            password: _rememberPassword ? _passwordController.text : null,
            rememberPassword: _rememberPassword,
            autoLogin: _rememberPassword && _autoLogin,
          ),
        );
      }

      try {
        ref.invalidate(dashboardProvider);
        await ref.read(dashboardProvider.notifier).load();
      } catch (_) {}

      if (mounted) {
        context.go('/dashboard');
      }
    } catch (e) {
      setState(() {
        _error = e is _LoginFlowMessage
            ? e.message
            : ref.read(authProvider).error ?? '登录失败';
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _switchPanel(PanelConfig panel) {
    setState(() {
      _selectedPanel = panel;
      _currentUrl = panel.url;
      _rememberPassword = panel.rememberPassword;
      _autoLogin = panel.rememberPassword && panel.autoLogin;
      if (panel.rememberPassword && panel.username != null) {
        _usernameController.text = panel.username!;
        _passwordController.text = panel.password ?? '';
      } else {
        _usernameController.clear();
        _passwordController.clear();
      }
    });
    DioClient.instance.setBaseUrl(panel.url);
    SecureStorage.saveServerUrl(panel.url);
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _totpController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isLight
                ? [Colors.white, AppColors.slate50]
                : [AppColors.slate900, AppColors.slate950],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Logo
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: AppColors.primary.withAlpha(25),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.asset(
                            'assets/icon.png',
                            width: 40,
                            height: 40,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),

                      // Title
                      Text(
                        _needsInit ? '初始化面板' : '欢迎回来',
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _needsInit
                            ? '首次使用，请创建管理员账号。'
                            : '登录 Daidai Panel 管理您的服务器与任务。',
                        style: TextStyle(
                          fontSize: 13,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 32),

                      // Server selector
                      if (_panels.isNotEmpty && !_needsInit) ...[
                        _FieldLabel('服务器'),
                        const SizedBox(height: 6),
                        _IconInput(
                          icon: Icons.dns_outlined,
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: _currentUrl,
                              isExpanded: true,
                              isDense: false,
                              icon: Icon(
                                Icons.expand_more,
                                size: 20,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                              style: TextStyle(
                                fontSize: 14,
                                color: theme.colorScheme.onSurface,
                              ),
                              items: _panels.map((p) {
                                return DropdownMenuItem(
                                  value: p.url,
                                  child: Text(
                                    '${p.name.isNotEmpty ? p.name : "面板"} (${_shortUrl(p.url)})',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                );
                              }).toList(),
                              onChanged: (url) {
                                final panel = _panels
                                    .where((p) => p.url == url)
                                    .first;
                                _switchPanel(panel);
                              },
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],

                      // Username
                      _FieldLabel('用户名'),
                      const SizedBox(height: 6),
                      _IconInput(
                        icon: Icons.person_outline,
                        child: TextFormField(
                          controller: _usernameController,
                          decoration: const InputDecoration(
                            hintText: 'admin',
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                            isDense: true,
                          ),
                          textAlignVertical: TextAlignVertical.center,
                          textInputAction: TextInputAction.next,
                          validator: (v) =>
                              v == null || v.trim().isEmpty ? '请输入用户名' : null,
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Password
                      _FieldLabel('密码'),
                      const SizedBox(height: 6),
                      _IconInput(
                        icon: Icons.lock_outline,
                        suffix: GestureDetector(
                          onTap: () => setState(
                            () => _obscurePassword = !_obscurePassword,
                          ),
                          child: Icon(
                            _obscurePassword
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                            size: 20,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        child: TextFormField(
                          controller: _passwordController,
                          decoration: const InputDecoration(
                            hintText: '••••••••',
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                            isDense: true,
                          ),
                          textAlignVertical: TextAlignVertical.center,
                          obscureText: _obscurePassword,
                          textInputAction: _needsTotp
                              ? TextInputAction.next
                              : TextInputAction.go,
                          onFieldSubmitted: _needsTotp
                              ? null
                              : (_) => _submit(),
                          validator: (v) =>
                              v == null || v.isEmpty ? '请输入密码' : null,
                        ),
                      ),

                      // TOTP
                      if (_needsTotp) ...[
                        const SizedBox(height: 16),
                        _FieldLabel('两步验证码'),
                        const SizedBox(height: 6),
                        _IconInput(
                          icon: Icons.security,
                          suffix: SizedBox(
                            width: 40,
                            child: Text(
                              '${_totpController.text.trim().length}/6',
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                fontSize: 12,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          child: TextFormField(
                            controller: _totpController,
                            decoration: const InputDecoration(
                              hintText: '6位数字验证码',
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              contentPadding: EdgeInsets.zero,
                              isDense: true,
                            ),
                            textAlignVertical: TextAlignVertical.center,
                            keyboardType: TextInputType.number,
                            maxLength: 6,
                            buildCounter:
                                (
                                  BuildContext context, {
                                  required int currentLength,
                                  required bool isFocused,
                                  required int? maxLength,
                                }) => null,
                            textInputAction: TextInputAction.go,
                            onChanged: (_) => setState(() {}),
                            onFieldSubmitted: (_) => _submit(),
                            validator: (v) {
                              if (v == null || v.trim().isEmpty) {
                                return '请输入验证码';
                              }
                              if (v.trim().length != 6) return '验证码为6位数字';
                              return null;
                            },
                          ),
                        ),
                      ],

                      // Remember + AutoLogin
                      const SizedBox(height: 8),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 16,
                        runSpacing: 8,
                        children: [
                          _CompactCheck(
                            value: _rememberPassword,
                            label: '记住密码',
                            onChanged: (v) {
                              setState(() {
                                _rememberPassword = v;
                                if (!v) _autoLogin = false;
                              });
                            },
                          ),
                          const SizedBox(width: 16),
                          _CompactCheck(
                            value: _autoLogin,
                            label: '自动登录',
                            enabled: _rememberPassword,
                            onChanged: (v) => setState(() => _autoLogin = v),
                          ),
                        ],
                      ),

                      // Error
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.red500.withAlpha(15),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: AppColors.red500.withAlpha(40),
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

                      // Login Button
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        // 本地 style 整块删除：底色 / 前景色 / 圆角三项与
                        // filledButtonTheme 完全一致，只多出 elevation 4 +
                        // 主色辉光 shadowColor。删掉即走 theme（elevation 0）。
                        child: FilledButton(
                          onPressed: _loading ? null : _submit,
                          child: _loading
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : Text(
                                  _needsInit ? '创建并登录' : '连接并登录',
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                        ),
                      ),

                      // Switch panel
                      const SizedBox(height: 16),
                      Center(
                        child: TextButton.icon(
                          onPressed: () =>
                              context.go('/server-config?manual=1'),
                          icon: Icon(
                            Icons.swap_horiz,
                            size: 18,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          label: Text(
                            '管理面板',
                            style: TextStyle(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontSize: 13,
                            ),
                          ),
                        ),
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

  String _shortUrl(String url) {
    return url.replaceAll('http://', '').replaceAll('https://', '');
  }
}

class _LoginFlowMessage implements Exception {
  final String message;

  const _LoginFlowMessage(this.message);
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _IconInput extends StatelessWidget {
  final IconData icon;
  final Widget child;
  final Widget? suffix;

  const _IconInput({required this.icon, required this.child, this.suffix});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;
    final borderColor = isLight ? AppColors.slate200 : AppColors.slate800;

    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: isLight ? Colors.white : AppColors.slate900,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: AppColors.slate400),
          const SizedBox(width: 12),
          Expanded(child: child),
          if (suffix != null) ...[const SizedBox(width: 8), suffix!],
        ],
      ),
    );
  }
}

class _CompactCheck extends StatelessWidget {
  final bool value;
  final String label;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _CompactCheck({
    required this.value,
    required this.label,
    this.enabled = true,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final color = enabled
        ? Theme.of(context).colorScheme.onSurface
        : Theme.of(context).disabledColor;

    return GestureDetector(
      onTap: enabled ? () => onChanged(!value) : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: Checkbox(
              value: value,
              onChanged: enabled ? (v) => onChanged(v ?? false) : null,
              activeColor: AppColors.primary,
              checkColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
              side: BorderSide(color: AppColors.slate300, width: 1.5),
            ),
          ),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(fontSize: 13, color: color)),
        ],
      ),
    );
  }
}
