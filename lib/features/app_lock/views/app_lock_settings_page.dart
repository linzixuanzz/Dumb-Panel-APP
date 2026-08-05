import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/app_snack.dart';
import '../providers/app_lock_provider.dart';
import '../widgets/pattern_pad.dart';

class AppLockSettingsPage extends ConsumerStatefulWidget {
  const AppLockSettingsPage({super.key});

  @override
  ConsumerState<AppLockSettingsPage> createState() =>
      _AppLockSettingsPageState();
}

class _AppLockSettingsPageState extends ConsumerState<AppLockSettingsPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(appLockProvider.notifier).initialize());
  }

  // 这里保留 replaceCurrent：应用锁的提示连续弹出时要覆盖上一条，不排队。
  void _showMessage(String message) =>
      AppSnack.show(context, message, replaceCurrent: true);

  String _readError(Object error, String fallback) {
    if (error is StateError) {
      return error.message.toString();
    }
    final text = error.toString().trim();
    if (text.startsWith('Bad state: ')) {
      return text.replaceFirst('Bad state: ', '');
    }
    return text.isEmpty ? fallback : text;
  }

  Future<void> _toggleEnabled(bool value) async {
    try {
      await ref.read(appLockProvider.notifier).setEnabled(value);
      _showMessage(value ? '应用锁已开启' : '应用锁已关闭');
    } catch (error) {
      _showMessage(_readError(error, '应用锁状态更新失败'));
    }
  }

  Future<void> _configurePassword({required bool changing}) async {
    final passwordController = TextEditingController();
    final confirmController = TextEditingController();
    var obscurePassword = true;
    var obscureConfirm = true;

    final password = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(changing ? '修改应用锁密码' : '设置应用锁密码'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: passwordController,
                  obscureText: obscurePassword,
                  decoration: InputDecoration(
                    labelText: '新密码',
                    hintText: '至少 4 位',
                    prefixIcon: const Icon(Icons.password_outlined),
                    suffixIcon: IconButton(
                      onPressed: () => setDialogState(
                        () => obscurePassword = !obscurePassword,
                      ),
                      icon: Icon(
                        obscurePassword
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: confirmController,
                  obscureText: obscureConfirm,
                  decoration: InputDecoration(
                    labelText: '确认密码',
                    prefixIcon: const Icon(Icons.lock_person_outlined),
                    suffixIcon: IconButton(
                      onPressed: () => setDialogState(
                        () => obscureConfirm = !obscureConfirm,
                      ),
                      icon: Icon(
                        obscureConfirm
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final password = passwordController.text.trim();
                final confirm = confirmController.text.trim();
                if (password.length < 4) {
                  _showMessage('应用锁密码至少需要 4 位');
                  return;
                }
                if (password != confirm) {
                  _showMessage('两次输入的密码不一致');
                  return;
                }
                Navigator.pop(dialogCtx, password);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );

    passwordController.dispose();
    confirmController.dispose();

    if (password == null || password.isEmpty) {
      return;
    }

    try {
      await ref.read(appLockProvider.notifier).savePassword(password);
      _showMessage(changing ? '应用锁密码已更新' : '应用锁密码已设置');
    } catch (error) {
      _showMessage(_readError(error, '应用锁密码保存失败'));
    }
  }

  Future<void> _removePassword() async {
    final confirmed = await _confirmAction('移除密码', '移除后将不能再使用密码进行应用解锁，是否继续？');
    if (confirmed != true) return;
    await ref.read(appLockProvider.notifier).removePassword();
    _showMessage('应用锁密码已移除');
  }

  Future<void> _configurePattern({required bool changing}) async {
    final pattern = await showDialog<List<int>>(
      context: context,
      builder: (_) => const _PatternSetupDialog(),
    );
    if (pattern == null || pattern.length < 4) {
      return;
    }

    try {
      await ref.read(appLockProvider.notifier).savePattern(pattern);
      _showMessage(changing ? '应用锁图案已更新' : '应用锁图案已设置');
    } catch (error) {
      _showMessage(_readError(error, '应用锁图案保存失败'));
    }
  }

  Future<void> _removePattern() async {
    final confirmed = await _confirmAction('移除图案', '移除后将不能再使用图案进行应用解锁，是否继续？');
    if (confirmed != true) return;
    await ref.read(appLockProvider.notifier).removePattern();
    _showMessage('应用锁图案已移除');
  }

  Future<void> _toggleBiometric(bool value) async {
    try {
      await ref.read(appLockProvider.notifier).setBiometricEnabled(value);
      _showMessage(value ? '生物识别解锁已开启' : '生物识别解锁已关闭');
    } catch (error) {
      _showMessage(_readError(error, '生物识别设置失败'));
    }
  }

  Future<bool?> _confirmAction(String title, String content) {
    return showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('继续'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lockState = ref.watch(appLockProvider);
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;

    return Scaffold(
      body: Padding(
        padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 12),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => context.pop(),
                    child: const Icon(Icons.arrow_back_ios, size: 20),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '应用锁',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: lockState.loading
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: AppColors.primary,
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
                      children: [
                        Container(
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: isLight ? Colors.white : AppColors.slate900,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: isLight
                                  ? AppColors.slate200
                                  : AppColors.slate800,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    width: 46,
                                    height: 46,
                                    decoration: BoxDecoration(
                                      color: AppColors.primary.withAlpha(18),
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    child: const Icon(
                                      Icons.lock_person_outlined,
                                      color: AppColors.primary,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          '二次验证',
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          lockState.isEnabled
                                              ? '已开启，切回前台或重新进入时需要再次验证'
                                              : '未开启，登录后不会追加本地二次验证',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                            height: 1.4,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Switch.adaptive(
                                    value: lockState.isEnabled,
                                    onChanged: _toggleEnabled,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  _StatusChip(
                                    label: lockState.hasPassword
                                        ? '密码已配置'
                                        : '密码未配置',
                                  ),
                                  _StatusChip(
                                    label: lockState.hasPattern
                                        ? '图案已配置'
                                        : '图案未配置',
                                  ),
                                  _StatusChip(
                                    label: lockState.hasBiometric
                                        ? '${lockState.biometricLabel}已开启'
                                        : '${lockState.biometricLabel}未开启',
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                        _MethodCard(
                          icon: Icons.password_outlined,
                          title: '密码解锁',
                          subtitle: lockState.hasPassword
                              ? '已设置应用锁密码，可作为生物识别失败时的后备解锁方式。'
                              : '设置一个仅用于本地 App 的二次验证密码。',
                          isLight: isLight,
                          trailing: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              OutlinedButton(
                                onPressed: () => _configurePassword(
                                  changing: lockState.hasPassword,
                                ),
                                child: Text(
                                  lockState.hasPassword ? '修改' : '设置',
                                ),
                              ),
                              if (lockState.hasPassword)
                                OutlinedButton(
                                  onPressed: _removePassword,
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: AppColors.red500,
                                  ),
                                  child: const Text('移除'),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        _MethodCard(
                          icon: Icons.gesture_outlined,
                          title: '图案解锁',
                          subtitle: lockState.hasPattern
                              ? '已设置图案，解锁时按顺序点击已保存的点位即可通过验证。'
                              : '设置一个 3x3 图案点位序列，适合快速本地解锁。',
                          isLight: isLight,
                          trailing: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              OutlinedButton(
                                onPressed: () => _configurePattern(
                                  changing: lockState.hasPattern,
                                ),
                                child: Text(lockState.hasPattern ? '修改' : '设置'),
                              ),
                              if (lockState.hasPattern)
                                OutlinedButton(
                                  onPressed: _removePattern,
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: AppColors.red500,
                                  ),
                                  child: const Text('移除'),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        _MethodCard(
                          icon: Icons.fingerprint_outlined,
                          title: '${lockState.biometricLabel}解锁',
                          subtitle: lockState.biometricAvailable
                              ? '调用设备系统级${lockState.biometricLabel}能力进行验证。'
                              : '当前设备未检测到可用的指纹或人脸能力。',
                          isLight: isLight,
                          trailing: Switch.adaptive(
                            value:
                                lockState.config.biometricEnabled &&
                                lockState.biometricAvailable,
                            onChanged: lockState.biometricAvailable
                                ? _toggleBiometric
                                : null,
                          ),
                        ),
                        const SizedBox(height: 20),
                        FilledButton.icon(
                          onPressed: lockState.isEnabled
                              ? () {
                                  ref
                                      .read(appLockProvider.notifier)
                                      .lockIfEnabled();
                                  _showMessage('应用已立即锁定，可直接验证体验');
                                }
                              : null,
                          icon: const Icon(Icons.lock_clock_outlined, size: 18),
                          label: const Text('立即锁定并测试'),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MethodCard extends StatelessWidget {
  const _MethodCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
    required this.isLight,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget trailing;
  final bool isLight;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isLight ? Colors.white : AppColors.slate900,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isLight ? AppColors.slate200 : AppColors.slate800,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 22, color: AppColors.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          trailing,
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.primary.withAlpha(12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.primary.withAlpha(24)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: AppColors.primary,
        ),
      ),
    );
  }
}

class _PatternSetupDialog extends StatefulWidget {
  const _PatternSetupDialog();

  @override
  State<_PatternSetupDialog> createState() => _PatternSetupDialogState();
}

class _PatternSetupDialogState extends State<_PatternSetupDialog> {
  List<int> _draft = const [];
  List<int>? _firstPattern;
  String? _error;

  void _togglePoint(int point) {
    if (_draft.contains(point)) {
      return;
    }
    setState(() {
      _draft = [..._draft, point];
      _error = null;
    });
  }

  void _backspace() {
    if (_draft.isEmpty) return;
    setState(() {
      _draft = _draft.sublist(0, _draft.length - 1);
      _error = null;
    });
  }

  void _clear() {
    setState(() {
      _draft = const [];
      _error = null;
    });
  }

  void _submit() {
    if (_draft.length < 4) {
      setState(() => _error = '图案至少需要 4 个点');
      return;
    }

    if (_firstPattern == null) {
      setState(() {
        _firstPattern = [..._draft];
        _draft = const [];
        _error = null;
      });
      return;
    }

    final first = _firstPattern!;
    if (first.length != _draft.length) {
      setState(() => _error = '两次图案不一致，请重新确认');
      return;
    }

    for (var i = 0; i < first.length; i++) {
      if (first[i] != _draft[i]) {
        setState(() => _error = '两次图案不一致，请重新确认');
        return;
      }
    }

    Navigator.pop(context, _draft);
  }

  @override
  Widget build(BuildContext context) {
    final isConfirmStep = _firstPattern != null;

    return AlertDialog(
      title: Text(isConfirmStep ? '确认图案' : '设置图案'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PatternPad(
              selectedPoints: _draft,
              onPointTap: _togglePoint,
              onClear: _clear,
              onBackspace: _backspace,
              title: isConfirmStep ? '请再次输入相同图案' : '请按顺序点击图案点位',
              subtitle: '建议使用至少 4 个点位，避免过于简单。',
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: const TextStyle(color: AppColors.red500, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(isConfirmStep ? '完成' : '下一步'),
        ),
      ],
    );
  }
}
