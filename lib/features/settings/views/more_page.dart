import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/services/app_update_service.dart';
import '../../../core/storage/secure_storage.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/app_section_title.dart';

class MorePage extends ConsumerStatefulWidget {
  const MorePage({super.key});

  @override
  ConsumerState<MorePage> createState() => _MorePageState();
}

class _MorePageState extends ConsumerState<MorePage> {
  AppUpdateInfo? _updateInfo;
  bool _checking = false;
  String? _serverUrl;

  @override
  void initState() {
    super.initState();
    _loadServerUrl();
  }

  Future<void> _loadServerUrl() async {
    final url = await SecureStorage.getServerUrl();
    if (mounted) setState(() => _serverUrl = url);
  }

  String? _buildAvatarUrl(String? avatarPath) {
    if (avatarPath == null || avatarPath.isEmpty || _serverUrl == null) {
      return null;
    }
    if (avatarPath.startsWith('http')) return avatarPath;
    return '$_serverUrl$avatarPath';
  }

  Future<void> _checkUpdate({bool silent = false}) async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final info = await AppUpdateService.checkUpdate();
      if (mounted) {
        setState(() {
          _updateInfo = info;
          _checking = false;
        });
        if (info != null && info.hasUpdate && !silent) {
          AppUpdateService.showUpdateDialog(context, info);
        } else if (!silent) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('当前已是最新版本')));
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() => _checking = false);
        if (!silent) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('检查更新失败，请稍后重试')));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final user = auth.user;
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;

    return Scaffold(
      body: ListView(
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top + 16,
          left: 20,
          right: 20,
          bottom: 100,
        ),
        children: [
          const Text(
            '设置',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 20),

          // User Card
          if (user != null)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isLight ? Colors.white : AppColors.slate900,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isLight ? AppColors.slate200 : AppColors.slate800,
                ),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      _buildUserAvatar(user, 48),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              user.username,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              user.role.toUpperCase(),
                              style: TextStyle(
                                fontSize: 12,
                                color: isLight
                                    ? AppColors.slate500
                                    : AppColors.slate400,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (_serverUrl != null) ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Icon(
                          Icons.link,
                          size: 14,
                          color: isLight
                              ? AppColors.slate400
                              : AppColors.slate500,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _serverUrl!
                                .replaceAll('http://', '')
                                .replaceAll('https://', ''),
                            style: TextStyle(
                              fontSize: 12,
                              color: isLight
                                  ? AppColors.slate500
                                  : AppColors.slate400,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          const SizedBox(height: 24),

          // App Settings Section
          const AppSectionTitle(
            '应用设置',
            padding: EdgeInsets.only(left: 2),
          ),
          const SizedBox(height: 8),
          _SettingsItem(
            icon: Icons.dns_outlined,
            title: '服务器管理',
            isLight: isLight,
            onTap: () => context.push('/server-config?manage=1'),
          ),
          _SettingsItem(
            icon: Icons.key_outlined,
            title: '环境变量',
            isLight: isLight,
            onTap: () => context.go('/envs'),
          ),
          _SettingsItem(
            icon: Icons.notifications_none,
            title: '消息通知',
            isLight: isLight,
            onTap: () => context.push('/notifications'),
          ),
          _SettingsItem(
            icon: Icons.lock_outline,
            title: '应用锁',
            isLight: isLight,
            onTap: () => context.push('/app-lock'),
          ),

          if (user != null && user.isAdmin) ...[
            const SizedBox(height: 24),
            const AppSectionTitle(
              '系统管理',
              padding: EdgeInsets.only(left: 2),
            ),
            const SizedBox(height: 8),
            _SettingsItem(
              icon: Icons.code,
              title: '脚本管理',
              isLight: isLight,
              onTap: () => context.push('/scripts'),
            ),
            _SettingsItem(
              icon: Icons.sync,
              title: '订阅管理',
              isLight: isLight,
              onTap: () => context.push('/subscriptions'),
            ),
            _SettingsItem(
              icon: Icons.inventory_2_outlined,
              title: '依赖管理',
              isLight: isLight,
              onTap: () => context.push('/deps'),
            ),
            _SettingsItem(
              icon: Icons.people_outline,
              title: '用户管理',
              isLight: isLight,
              onTap: () => context.push('/users'),
            ),
            _SettingsItem(
              icon: Icons.security,
              title: '安全设置',
              isLight: isLight,
              onTap: () => context.push('/security'),
            ),
            _SettingsItem(
              icon: Icons.settings,
              title: '系统设置',
              isLight: isLight,
              onTap: () => context.push('/system-settings'),
            ),
            _SettingsItem(
              icon: Icons.article_outlined,
              title: '面板日志',
              isLight: isLight,
              onTap: () => context.push('/panel-log'),
            ),
            _SettingsItem(
              icon: Icons.api,
              title: 'Open API',
              isLight: isLight,
              onTap: () => context.push('/open-api'),
            ),
          ],

          const SizedBox(height: 24),
          const AppSectionTitle('其他', padding: EdgeInsets.only(left: 2)),
          const SizedBox(height: 8),
          _SettingsItem(
            icon: Icons.volunteer_activism_outlined,
            title: '赞助名单',
            isLight: isLight,
            onTap: () => context.push('/sponsors'),
          ),
          _SettingsItem(
            icon: Icons.system_update_outlined,
            title: '检查更新',
            isLight: isLight,
            trailing: _checking
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.primary,
                    ),
                  )
                : (_updateInfo?.hasUpdate == true
                      ? Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: AppColors.red500,
                            shape: BoxShape.circle,
                          ),
                        )
                      : null),
            onTap: () => _checkUpdate(),
          ),
          _SettingsItem(
            icon: Icons.info_outline,
            title: '关于',
            isLight: isLight,
            onTap: () => _showAboutDialog(context),
          ),

          // Logout
          const SizedBox(height: 24),
          GestureDetector(
            onTap: () => _logout(context, ref),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                color: isLight
                    ? AppColors.red50
                    : AppColors.red500.withAlpha(12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isLight
                      ? AppColors.red500.withAlpha(50)
                      : AppColors.red500.withAlpha(40),
                ),
              ),
              child: const Center(
                child: Text(
                  '退出登录',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.red500,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUserAvatar(dynamic user, double size) {
    final avatarFullUrl = _buildAvatarUrl(user.avatarUrl);
    if (avatarFullUrl != null) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.primary.withAlpha(40), width: 2),
        ),
        child: ClipOval(
          child: Image.network(
            avatarFullUrl,
            width: size,
            height: size,
            fit: BoxFit.cover,
            headers: {
              'Authorization':
                  'Bearer ${DioClient.instance.dio.options.headers['Authorization']?.toString().replaceFirst('Bearer ', '') ?? ''}',
            },
            errorBuilder: (_, error, stackTrace) =>
                _buildFallbackAvatar(user, size),
          ),
        ),
      );
    }
    return _buildFallbackAvatar(user, size);
  }

  Widget _buildFallbackAvatar(dynamic user, double size) {
    final initial = user.username.isNotEmpty
        ? user.username.substring(0, 1).toUpperCase()
        : '?';
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.primary.withAlpha(25),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(
          initial,
          style: TextStyle(
            fontSize: size * 0.38,
            fontWeight: FontWeight.w700,
            color: AppColors.primary,
          ),
        ),
      ),
    );
  }

  Future<void> _logout(BuildContext context, WidgetRef ref) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定要退出登录吗？'),
        actions: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(dialogCtx, false),
                    child: const Text('取消'),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(dialogCtx, true),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.red500,
                    ),
                    child: const Text('退出'),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (confirm == true) {
      await ref.read(authProvider.notifier).logout();
      if (context.mounted) {
        context.go('/server-config?manual=1');
      }
    }
  }

  Future<void> _showAboutDialog(BuildContext context) async {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final packageInfoFuture = PackageInfo.fromPlatform();
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('关于'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(20),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.dashboard_customize_outlined,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '呆呆面板',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      FutureBuilder<PackageInfo>(
                        future: packageInfoFuture,
                        builder: (context, snapshot) {
                          final info = snapshot.data;
                          final versionLabel = info == null
                              ? '版本 -'
                              : '版本 ${info.version}${info.buildNumber.trim().isEmpty ? '' : '+${info.buildNumber}'}';
                          return Text(
                            versionLabel,
                            style: const TextStyle(fontSize: 12),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              '轻量级定时任务管理平台',
              style: TextStyle(
                fontSize: 13,
                color: isLight ? AppColors.slate600 : AppColors.slate300,
              ),
            ),
          ],
        ),
        actions: [
          SizedBox(
            width: double.infinity,
            height: 44,
            child: FilledButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('知道了'),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool isLight;
  final VoidCallback onTap;
  final Widget? trailing;

  const _SettingsItem({
    required this.icon,
    required this.title,
    required this.isLight,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: isLight ? Colors.white : AppColors.slate900,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isLight ? AppColors.slate200 : AppColors.slate800,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: isLight ? AppColors.slate500 : AppColors.slate400,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (trailing != null) ...[trailing!, const SizedBox(width: 8)],
            Icon(
              Icons.chevron_right,
              size: 18,
              color: isLight ? AppColors.slate400 : AppColors.slate600,
            ),
          ],
        ),
      ),
    );
  }
}
