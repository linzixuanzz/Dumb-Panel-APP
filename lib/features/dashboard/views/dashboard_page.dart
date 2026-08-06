import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/services/app_update_service.dart';
import '../../../core/storage/secure_storage.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/widgets/app_card.dart';
import '../providers/dashboard_provider.dart';
import '../widgets/task_stats_card.dart';
import '../widgets/trend_chart.dart';

class DashboardPage extends ConsumerStatefulWidget {
  const DashboardPage({super.key});

  @override
  ConsumerState<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends ConsumerState<DashboardPage> {
  String? _serverUrl;

  @override
  void initState() {
    super.initState();
    SecureStorage.getServerUrl().then((url) {
      if (mounted) setState(() => _serverUrl = url);
    });
    Future.microtask(() async {
      await ref.read(dashboardProvider.notifier).load();
      if (ref.read(authProvider).user == null) {
        await ref.read(authProvider.notifier).refreshUser();
      }
      _silentUpdateCheck();
    });
  }

  String? _buildAvatarUrl(String? avatarPath) {
    if (avatarPath == null || avatarPath.isEmpty || _serverUrl == null) {
      return null;
    }
    if (avatarPath.startsWith('http')) return avatarPath;
    return '$_serverUrl$avatarPath';
  }

  Future<void> _silentUpdateCheck() async {
    try {
      final info = await AppUpdateService.checkUpdate();
      if (info != null && info.hasUpdate && mounted) {
        AppUpdateService.showUpdateDialog(context, info);
      }
    } catch (_) {
      // Silent — do not disturb user on failure
    }
  }

  Widget _buildDashboardAvatar(AuthState auth, bool isLight, double size) {
    final avatarFullUrl = _buildAvatarUrl(auth.user?.avatarUrl);
    if (avatarFullUrl != null) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: isLight ? AppColors.slate200 : AppColors.slate800,
          ),
        ),
        child: ClipOval(
          child: Image.network(
            avatarFullUrl,
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) =>
                _buildFallbackAvatar(auth, isLight, size),
          ),
        ),
      );
    }
    return _buildFallbackAvatar(auth, isLight, size);
  }

  Widget _buildFallbackAvatar(AuthState auth, bool isLight, double size) {
    final username = auth.user?.username ?? '';
    final initial = username.isNotEmpty
        ? username.substring(0, 1).toUpperCase()
        : '?';
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.primary.withAlpha(25),
        shape: BoxShape.circle,
        border: Border.all(
          color: isLight ? AppColors.slate200 : AppColors.slate800,
        ),
      ),
      child: Center(
        child: Text(
          initial,
          style: TextStyle(
            fontSize: size * 0.4,
            fontWeight: FontWeight.w700,
            // 圆底就是 primary 的 alpha=25 淡底，首字母用满强度同色只有 2.6:1。
            color: context.surfaces.tintFg(AppColors.primary),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(dashboardProvider);
    final auth = ref.watch(authProvider);
    final user = auth.user;
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;
    final quickActions = (user?.isAdmin ?? false)
        ? <_DashboardQuickActionData>[
            _DashboardQuickActionData(
              icon: Icons.add_task_outlined,
              label: '新建任务',
              onTap: () => context.push('/tasks/new'),
            ),
            _DashboardQuickActionData(
              icon: Icons.code_outlined,
              label: '脚本管理',
              onTap: () => context.push('/scripts'),
            ),
            _DashboardQuickActionData(
              icon: Icons.sync_outlined,
              label: '订阅管理',
              onTap: () => context.push('/subscriptions'),
            ),
            _DashboardQuickActionData(
              icon: Icons.inventory_2_outlined,
              label: '依赖管理',
              onTap: () => context.push('/deps'),
            ),
          ]
        : <_DashboardQuickActionData>[
            _DashboardQuickActionData(
              icon: Icons.schedule_outlined,
              label: '任务',
              onTap: () => context.go('/tasks'),
            ),
            _DashboardQuickActionData(
              icon: Icons.key_outlined,
              label: '环境变量',
              onTap: () => context.go('/envs'),
            ),
            _DashboardQuickActionData(
              icon: Icons.volunteer_activism_outlined,
              label: '赞助名单',
              onTap: () => context.push('/sponsors'),
            ),
            _DashboardQuickActionData(
              icon: Icons.settings_outlined,
              label: '设置',
              onTap: () => context.go('/more'),
            ),
          ];

    return Scaffold(
      body: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: () => ref.read(dashboardProvider.notifier).load(),
        child: data.loading && data.system.isEmpty
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [
                  SizedBox(height: 120),
                  Center(
                    child: CircularProgressIndicator(color: AppColors.primary),
                  ),
                ],
              )
            : ListView(
                padding: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top + 16,
                  left: 20,
                  right: 20,
                  bottom: 100,
                ),
                children: [
                  // Header
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (data.panelTitle.isNotEmpty) ...[
                              Text(
                                data.panelTitle,
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w800,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '欢迎，${auth.user?.username ?? '管理员'}',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ] else ...[
                              Text(
                                '欢迎，',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                auth.user?.username ?? '管理员',
                                style: const TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      _buildDashboardAvatar(auth, isLight, 40),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // Server Info Card
                  _ServerInfoCard(data: data, isLight: isLight),
                  const SizedBox(height: 24),

                  // System Stats
                  Text(
                    '系统状态',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurfaceVariant,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 12),

                  // CPU + RAM
                  Row(
                    children: [
                      Expanded(
                        child: _StatCard(
                          icon: Icons.memory,
                          iconBg: AppColors.blue100,
                          iconBgDark: AppColors.blue500.withAlpha(25),
                          iconColor: AppColors.blue600,
                          iconColorDark: AppColors.blue500,
                          label: 'CPU 使用率',
                          value: data.cpuUsage,
                          barColor: AppColors.blue500,
                          valueText: '${data.cpuUsage.toStringAsFixed(0)}%',
                          isLight: isLight,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _StatCard(
                          icon: Icons.storage,
                          iconBg: AppColors.primaryLight,
                          iconBgDark: AppColors.primary.withAlpha(25),
                          iconColor: AppColors.primary,
                          iconColorDark: AppColors.primary,
                          label: data.memoryUnavailable
                              ? '内存（资源采集不可用）'
                              : '内存 (${data.memoryUsed}/${data.memoryTotal})',
                          value: data.memoryUnavailable
                              ? null
                              : data.memoryUsage,
                          barColor: AppColors.primary,
                          valueText: data.memoryUnavailable
                              ? '不可用'
                              : '${data.memoryUsage.toStringAsFixed(0)}%',
                          isLight: isLight,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Disk (full width)
                  _StatCard(
                    icon: Icons.disc_full_outlined,
                    iconBg: AppColors.purple100,
                    iconBgDark: AppColors.purple500.withAlpha(25),
                    iconColor: AppColors.purple600,
                    iconColorDark: AppColors.purple500,
                    label: '磁盘空间',
                    value: data.diskUsage,
                    barColor: AppColors.purple500,
                    valueText: '${data.diskUsage.toStringAsFixed(0)}%',
                    subtitle: '${data.diskUsed} / ${data.diskTotal}',
                    isLight: isLight,
                  ),
                  const SizedBox(height: 24),

                  // Task Stats
                  if (data.totalTasks > 0) ...[
                    Text(
                      '任务概览',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurfaceVariant,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TaskStatsCard(
                      total: data.totalTasks,
                      enabled: data.enabledTasks,
                      running: data.runningTasks,
                      disabled: data.disabledTasks,
                      todaySuccess: data.todaySuccess,
                      todayFailed: data.todayFailed,
                      onTap: () => context.go('/tasks'),
                    ),
                    const SizedBox(height: 24),
                  ],

                  // Execution Trend
                  if (data.executionTrend.isNotEmpty) ...[
                    Text(
                      '执行趋势',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurfaceVariant,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TrendChart(data: data.executionTrend),
                    const SizedBox(height: 24),
                  ],

                  // Quick Actions
                  Text(
                    '快捷操作',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurfaceVariant,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: List.generate(quickActions.length * 2 - 1, (
                      index,
                    ) {
                      if (index.isOdd) {
                        return const SizedBox(width: 10);
                      }
                      final action = quickActions[index ~/ 2];
                      return _QuickAction(
                        icon: action.icon,
                        label: action.label,
                        isLight: isLight,
                        onTap: action.onTap,
                      );
                    }),
                  ),
                ],
              ),
      ),
    );
  }
}

class _DashboardQuickActionData {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _DashboardQuickActionData({
    required this.icon,
    required this.label,
    required this.onTap,
  });
}

class _ServerInfoCard extends StatelessWidget {
  final DashboardData data;
  final bool isLight;

  const _ServerInfoCard({required this.data, required this.isLight});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isLight
              ? [Colors.white, AppColors.slate50]
              : [AppColors.slate900, AppColors.slate800],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isLight ? AppColors.slate200 : AppColors.slate800,
        ),
      ),
      child: Stack(
        children: [
          // 装饰圆
          Positioned(
            top: -30,
            right: -30,
            child: Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(isLight ? 20 : 10),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // 主机名前的圆点语义是「在线」，属于 success 绿；primary 是品牌色
                  // 与「运行中」，不承担「在线 / 健康」。
                  //
                  // ⚠️ 已知缺口（本期不修）：这个圆点**不绑定任何连接或健康状态**，
                  // 面板不可达、接口报错时它同样常亮 —— 它现在只是个装饰。
                  // 要真正表示在线，得接 dashboardProvider 的 error / 心跳状态，
                  // 那是行为改动，不属于本期的配色语义修正。
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: AppColors.success,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    data.hostname,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isLight ? AppColors.slate600 : AppColors.slate400,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                '${data.os} ${data.system['arch'] ?? ''}',
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Text(
                    '已运行：${data.uptime}',
                    style: TextStyle(
                      fontSize: 12,
                      color: isLight ? AppColors.slate500 : AppColors.slate400,
                    ),
                  ),
                  if (data.panelVersion.isNotEmpty) ...[
                    Container(
                      width: 1,
                      height: 10,
                      margin: const EdgeInsets.symmetric(horizontal: 10),
                      color: isLight ? AppColors.slate300 : AppColors.slate700,
                    ),
                    Text(
                      'v${data.panelVersion}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primary,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final Color iconBg;
  final Color iconBgDark;
  final Color iconColor;
  final Color iconColorDark;
  final String label;
  final double? value;
  final Color barColor;
  final String valueText;
  final String? subtitle;
  final bool isLight;

  const _StatCard({
    required this.icon,
    required this.iconBg,
    required this.iconBgDark,
    required this.iconColor,
    required this.iconColorDark,
    required this.label,
    required this.value,
    required this.barColor,
    required this.valueText,
    this.subtitle,
    required this.isLight,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: isLight ? iconBg : iconBgDark,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  icon,
                  size: 16,
                  color: isLight ? iconColor : iconColorDark,
                ),
              ),
              Text(
                valueText,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: isLight ? iconColor : iconColorDark,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (subtitle != null)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: isLight ? AppColors.slate500 : AppColors.slate400,
                  ),
                ),
                Text(subtitle!, style: const TextStyle(fontSize: 12)),
              ],
            )
          else
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: isLight ? AppColors.slate500 : AppColors.slate400,
              ),
            ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: value == null ? null : (value! / 100).clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: isLight
                  ? AppColors.slate100
                  : AppColors.slate800,
              valueColor: AlwaysStoppedAnimation(barColor),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isLight;
  final VoidCallback onTap;

  const _QuickAction({
    required this.icon,
    required this.label,
    required this.isLight,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: AppCard(
        onTap: onTap,
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Column(
          children: [
            Icon(
              icon,
              size: 22,
              color: isLight ? AppColors.slate700 : AppColors.slate300,
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(fontSize: 10),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
