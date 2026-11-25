import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_provider.dart';
import '../../../core/integration/integration_settings.dart';
import '../../../core/providers/server_scoped_providers.dart';
import '../../../core/router/default_landing_page.dart';
import '../../../core/services/app_update_service.dart';
import '../../../core/storage/secure_storage.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../core/theme/theme_mode_provider.dart';
import '../../../shared/widgets/app_grouped_list.dart';
import '../../../shared/widgets/app_icon_tile.dart';
import '../../../shared/widgets/app_large_title_header.dart';
import '../../../shared/widgets/app_pill_button.dart';
import '../../../shared/widgets/app_sheet.dart';
import '../../../shared/widgets/app_snack.dart';
import '../../app_lock/providers/app_lock_provider.dart';

/// 「设置」Tab（v2.0，方案书 §3「设置」行）。
///
/// 从上到下：星空个人卡 → 面板 → 外观 → 小组件与快捷方式 → 管理 → 系统 → 关于 → 退出登录。
/// v1.x「更多」页（`more_page.dart`）的入口、权限判断、检查更新、自动提醒更新、
/// 默认打开页面、退出登录全部迁到这里，`MorePage` 只剩一个转发。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  AppUpdateInfo? _updateInfo;
  bool _checking = false;

  // 「自动提醒更新」开关，读到本地偏好前先按默认值（开）显示
  bool _autoRemind = true;

  /// 当前面板（个人卡上的名称与地址）和已保存的面板数（「服务器管理」右侧）。
  PanelConfig? _panel;
  String? _serverUrl;
  int _panelCount = 0;

  /// 常驻通知开关正在等系统权限弹窗时禁用开关，免得连点发起两次申请。
  bool _notifyBusy = false;

  @override
  void initState() {
    super.initState();
    _loadPanelInfo();
    AppUpdateService.getAutoRemindEnabled().then((v) {
      if (mounted) setState(() => _autoRemind = v);
    });
  }

  Future<void> _loadPanelInfo() async {
    final url = await SecureStorage.getServerUrl();
    final panels = await SecureStorage.getPanels();
    if (!mounted) return;
    setState(() {
      _serverUrl = url;
      _panelCount = panels.length;
      _panel = panels.where((p) => p.url == url).firstOrNull;
    });
  }

  Future<void> _toggleAutoRemind(bool value) async {
    setState(() => _autoRemind = value);
    await AppUpdateService.setAutoRemindEnabled(value);
  }

  Future<void> _checkUpdate() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final info = await AppUpdateService.checkUpdate();
      if (!mounted) return;
      setState(() {
        _updateInfo = info;
        _checking = false;
      });
      if (info != null && info.hasUpdate) {
        AppUpdateService.showUpdateDialog(context, info);
      } else {
        AppSnack.show(context, '当前已是最新版本');
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _checking = false);
      // 文案不走 extractErrorMessage：AppUpdateService.checkUpdate() 内部
      // 已经 `catch (_) { return null; }`，网络/接口异常根本传不到这里；
      // 这里能接住的只有本地异常，其 message 是英文，报给用户反而更差。
      AppSnack.error(context, '检查更新失败，请稍后重试');
    }
  }

  /// 「运行中常驻通知」开关（B8 提供设置项）。
  ///
  /// 开启时安卓 13+ 会弹系统权限框；用户拒绝时 [setEnabled] 返回 false，
  /// 开关跟着 provider 的实际状态回到「关」，这里再补一句原因。
  Future<void> _toggleRunningNotification(bool on) async {
    setState(() => _notifyBusy = true);
    final notifier = ref.read(runningNotificationEnabledProvider.notifier);
    var actual = false;
    try {
      actual = await notifier.setEnabled(on);
    } catch (_) {
      actual = ref.read(runningNotificationEnabledProvider);
    }
    if (!mounted) return;
    setState(() => _notifyBusy = false);
    if (on && !actual) {
      AppSnack.warn(context, '没有通知权限，常驻通知未开启。可在系统设置里允许通知后再打开。');
    }
  }

  /// 明暗设置。点预览卡 = 固定成那一种（同时关掉「跟随系统」）。
  ///
  /// 切换过渡交给 `MaterialApp` 的主题插值；没有做方案书里「从点击处圆形扩散」的效果 ——
  /// 那需要在应用根部截一帧旧画面，不在本组文件范围内。
  void _setThemeMode(ThemeMode mode) {
    ref.read(themeModeProvider.notifier).set(mode);
  }

  /// 「默认打开页面」的选择弹层：四个选项，当前那项打勾，点一下就保存并关掉。
  Future<void> _pickDefaultLandingPage() async {
    final selected = await showAppSheet<String>(
      context: context,
      fullHeight: false,
      builder: (sheetContext) {
        final palette = sheetContext.palette;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                child: Text(
                  '默认打开页面',
                  style: AppText.cardTitle.copyWith(color: palette.text),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                child: Text(
                  '打开 APP、登录或切换面板后先进入这一页，所有面板共用。',
                  style: AppText.caption.copyWith(color: palette.text2),
                ),
              ),
              AppGroupedList(
                children: [
                  for (final entry in DefaultLandingPage.options.entries)
                    AppGroupedRow(
                      key: Key('default-landing-${entry.key}'),
                      title: entry.value,
                      trailing: entry.key == DefaultLandingPage.value
                          ? Icon(Icons.check_rounded, color: palette.accent)
                          : null,
                      onTap: () => Navigator.of(sheetContext).pop(entry.key),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
    if (selected == null) return;
    await DefaultLandingPage.save(selected);
    if (mounted) setState(() {});
  }

  Future<void> _logout() async {
    final palette = context.palette;
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
                      backgroundColor: palette.err,
                      foregroundColor: palette.onStatus,
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
    if (confirm != true) return;
    // 退出的只是**当前面板**（凭据按面板分片，issue #13 / v1.3.7），其它面板的登录状态还在。
    await ref.read(authProvider.notifier).logout();
    // 和切换面板走同一个失效函数：不清的话「A 退出 → 切到 B」会把 A 的任务/日志
    // 原样带到 B 的界面上。这些 provider 都不是 autoDispose。
    invalidateServerScopedProviders(ref);
    if (mounted) {
      context.go('/server-config?manual=1');
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final user = ref.watch(authProvider).user;
    final isAdmin = user != null && user.isAdmin;
    final themeMode = ref.watch(themeModeProvider);
    final lockState = ref.watch(appLockProvider);
    final notifyOn = ref.watch(runningNotificationEnabledProvider);
    final notifySupported = ref
        .read(runningNotificationEnabledProvider.notifier)
        .supported;
    // 底栏实际高度 + 16：要在滚动视图外面读，里面读到的是 0
    final bottom = AppSpacing.listBottomOf(context);

    // 分组之间的间距
    const gap = SizedBox(height: 28);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        // 整页是固定的十几行，直接 SingleChildScrollView 一次建完：
        // ListView 懒构建会让屏幕外的入口在测试里找不到，也没有性能上的必要。
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(16, 0, 16, bottom),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const AppLargeTitleHeader(
                title: '设置',
                padding: EdgeInsets.fromLTRB(4, 24, 4, 16),
              ),

              // ── 星空个人卡 ──
              _StarProfileCard(
                username: user?.username,
                roleLabel: user == null ? null : _roleLabel(user.role),
                panelName: _panel?.name,
                serverUrl: _serverUrl,
                onTap: () => context.push('/server-config?manage=1'),
              ),
              gap,

              // ── 面板 ──
              AppGroupedList(
                header: '面板',
                children: [
                  AppGroupedRow(
                    leading: AppIconTile(
                      icon: Icons.dns_rounded,
                      color: palette.accent,
                      solid: true,
                    ),
                    title: '服务器管理',
                    trailing: _panelCount > 0 ? Text('$_panelCount 个面板') : null,
                    showChevron: true,
                    onTap: () async {
                      await context.push('/server-config?manage=1');
                      // 回来时面板可能增删过，重新读一次
                      _loadPanelInfo();
                    },
                  ),
                  AppGroupedRow(
                    leading: AppIconTile(
                      icon: Icons.lock_rounded,
                      color: palette.ok,
                      solid: true,
                    ),
                    title: '应用锁',
                    trailing: Text(lockState.isEnabled ? '已开启' : '未开启'),
                    showChevron: true,
                    onTap: () => context.push('/app-lock'),
                  ),
                  // 进入主界面时落到哪一页（APP #24），存本机、所有面板共用
                  AppGroupedRow(
                    key: const Key('settings-default-landing-page'),
                    leading: AppIconTile(
                      icon: Icons.home_rounded,
                      color: palette.warn,
                      solid: true,
                    ),
                    title: '默认打开页面',
                    trailing: Text(DefaultLandingPage.label),
                    showChevron: true,
                    onTap: _pickDefaultLandingPage,
                  ),
                ],
              ),
              gap,

              // ── 外观 ──
              _AppearanceSection(mode: themeMode, onChanged: _setThemeMode),
              gap,

              // ── 小组件与快捷方式 ──
              AppGroupedList(
                header: '小组件与快捷方式',
                footer: '长按 APP 图标可以新建任务、搜索任务或运行常用任务；'
                    '安卓还可以在桌面添加「呆呆面板」小组件，查看今日成功率、下一个任务和最近失败的任务。',
                children: [
                  AppGroupedRow(
                    key: const Key('settings-running-notification'),
                    leading: AppIconTile(
                      icon: Icons.notifications_active_rounded,
                      color: notifySupported ? palette.purple : palette.text3,
                    ),
                    title: '运行中常驻通知',
                    // 不支持的平台整行置灰，并写明原因
                    titleColor: notifySupported ? null : palette.text3,
                    subtitle: notifySupported
                        ? '有任务在跑时通知栏显示「N 个任务运行中」，全部结束后自动消失'
                        : '仅安卓',
                    trailing: Switch.adaptive(
                      value: notifySupported && notifyOn,
                      onChanged: notifySupported && !_notifyBusy
                          ? _toggleRunningNotification
                          : null,
                      // 收紧点击区，免得这一行比其它行高一截
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
              gap,

              // ── 管理 ──
              // 权限沿用 v1.x「更多」页：通知渠道所有人可见，其余入口仅管理员。
              AppGroupedList(
                header: '管理',
                children: [
                  if (isAdmin) ...[
                    _entry(Icons.code_rounded, palette.purple, '脚本', '/scripts'),
                    _entry(Icons.sync_rounded, palette.accent, '订阅', '/subscriptions'),
                    _entry(Icons.inventory_2_rounded, palette.warn, '依赖', '/deps'),
                  ],
                  _entry(
                    Icons.notifications_rounded,
                    palette.err,
                    '通知渠道',
                    '/notifications',
                  ),
                ],
              ),
              if (isAdmin) ...[
                gap,
                AppGroupedList(
                  header: '系统',
                  children: [
                    _entry(Icons.people_rounded, palette.accent, '用户', '/users'),
                    _entry(Icons.shield_rounded, palette.ok, '安全', '/security'),
                    _entry(Icons.api_rounded, palette.purple, 'Open API', '/open-api'),
                    _entry(
                      Icons.settings_rounded,
                      palette.text2,
                      '系统设置',
                      '/system-settings',
                    ),
                    // APP #22：原来 APP 里找不到 config.sh 在哪编辑；接口仅 admin，所以放在这个分区。
                    _entry(
                      Icons.description_rounded,
                      palette.text2,
                      '配置文件',
                      '/config-script',
                    ),
                    _entry(
                      Icons.article_rounded,
                      palette.text2,
                      '面板日志',
                      '/panel-log',
                    ),
                    // v1.x 只能从「系统设置」里进，v2.0 在这里也给一个直达入口
                    _entry(Icons.backup_rounded, palette.ok, '备份', '/backup'),
                  ],
                ),
              ],
              gap,

              // ── 其他（赞助、更新、关于）──
              AppGroupedList(
                header: '其他',
                children: [
                  _entry(
                    Icons.volunteer_activism_rounded,
                    palette.err,
                    '赞助名单',
                    '/sponsors',
                  ),
                  AppGroupedRow(
                    leading: AppIconTile(
                      icon: Icons.system_update_rounded,
                      color: palette.accent,
                    ),
                    title: '检查更新',
                    trailing: _checking
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: palette.accent,
                            ),
                          )
                        : (_updateInfo?.hasUpdate == true
                              ? Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: palette.err,
                                    shape: BoxShape.circle,
                                  ),
                                )
                              : null),
                    showChevron: true,
                    onTap: _checkUpdate,
                  ),
                  // 首页自动弹更新的总开关；在弹窗里点过「不再自动提醒」后从这里重新打开（issue #19）
                  AppGroupedRow(
                    leading: AppIconTile(
                      icon: Icons.notifications_active_rounded,
                      color: palette.warn,
                    ),
                    title: '自动提醒更新',
                    trailing: Switch.adaptive(
                      value: _autoRemind,
                      onChanged: _toggleAutoRemind,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onTap: () => _toggleAutoRemind(!_autoRemind),
                  ),
                  // 原先是「更多」页的 _showAboutDialog 弹窗，issue #12 要补作者/项目/反馈三组
                  // 外链，弹窗装不下，已改成独立页（issue #12 / v1.3.7）
                  _entry(Icons.info_rounded, palette.text2, '关于', '/about'),
                ],
              ),
              gap,

              AppPillButton(
                label: '退出登录',
                variant: AppPillVariant.danger,
                expand: true,
                height: 52,
                onPressed: _logout,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 普通的「图标 + 标题 + 箭头，点了 push 二级页」一行。
  Widget _entry(IconData icon, Color color, String title, String route) {
    return AppGroupedRow(
      leading: AppIconTile(icon: icon, color: color),
      title: title,
      showChevron: true,
      onTap: () => context.push(route),
    );
  }

  /// 角色显示名，与「用户管理」页一致。
  static String _roleLabel(String role) => switch (role) {
    'admin' => '管理员',
    'operator' => '操作员',
    'viewer' => '观察者',
    _ => role,
  };
}

/// 星空个人卡：黑色渐变到蓝紫，撒星点，放呆呆头像、用户名、角色、当前面板名称和地址。
///
/// ⚠️ 这张卡是**插画**，不是界面色：两种明暗模式下都是同一片夜空，
/// 所以颜色写死在下面的常量里，不走 palette（方案书 §2.4「星空个人卡」，
/// 取值来自 `APP效果演示.html` 的 `.prof`）。
class _StarProfileCard extends StatelessWidget {
  const _StarProfileCard({
    required this.username,
    required this.roleLabel,
    required this.panelName,
    required this.serverUrl,
    required this.onTap,
  });

  final String? username;
  final String? roleLabel;
  final String? panelName;
  final String? serverUrl;
  final VoidCallback onTap;

  // ── 插画常量（夜空配色，明暗模式共用）──
  static const Color _skyBlack = Color(0xFF000000);
  static const Color _skyNavy = Color(0xFF0B1640);
  static const Color _skyBlue = Color(0xFF1A2E9E);
  static const Color _glowBlue = Color(0xFF2F6DFF);
  static const Color _glowPurple = Color(0xFF7B5CFF);
  static const Color _starWhite = Color(0xFFFFFFFF);

  @override
  Widget build(BuildContext context) {
    final host = serverUrl
        ?.replaceAll('http://', '')
        .replaceAll('https://', '');
    // 面板名称没起过时存的就是地址本身，这时不重复显示
    final name = (panelName == null || panelName!.isEmpty || panelName == serverUrl)
        ? null
        : panelName;
    // 角色 · 面板名称，缺哪个就不显示哪个
    final line2 = [?roleLabel, ?name].join(' · ');

    return Semantics(
      button: true,
      label: '个人信息与当前面板，点按管理服务器',
      child: GestureDetector(
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: Stack(
            children: [
              // 底：从左到右 黑 → 深蓝 → 蓝
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment(-1, -0.3),
                      end: Alignment(1, 0.3),
                      colors: [_skyBlack, _skyBlack, _skyNavy, _skyBlue],
                      stops: [0, 0.25, 0.6, 1],
                    ),
                  ),
                ),
              ),
              // 右上的蓝色光晕
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(0.4, -1),
                      radius: 0.9,
                      colors: [_glowBlue.withValues(alpha: 0.85), _glowBlue.withValues(alpha: 0)],
                    ),
                  ),
                ),
              ),
              // 右下的紫色光晕
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment.bottomRight,
                      radius: 1.1,
                      colors: [_glowPurple, _glowPurple.withValues(alpha: 0)],
                      stops: const [0, 0.55],
                    ),
                  ),
                ),
              ),
              // 星点：静态的，不做闪烁 —— 常驻动画会让页面永远 settle 不下来，
              // 也省得在「减少动画」时再分支。
              const Positioned.fill(
                child: CustomPaint(painter: _StarsPainter(color: _starWhite)),
              ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    Container(
                      width: 68,
                      height: 68,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _starWhite.withValues(alpha: 0.15),
                          width: 3,
                        ),
                      ),
                      child: ClipOval(
                        child: Image.asset(
                          'assets/icon.png',
                          width: 62,
                          height: 62,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            username ?? '未获取到用户信息',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              color: _starWhite,
                            ),
                          ),
                          if (line2.isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Text(
                              line2,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w600,
                                color: _starWhite.withValues(alpha: 0.85),
                              ),
                            ),
                          ],
                          if (host != null && host.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              host,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: _starWhite.withValues(alpha: 0.7),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: _starWhite.withValues(alpha: 0.6),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 固定位置的星点（相对坐标 + 半径），对应演示稿 `.prof .stars` 的那几颗。
class _StarsPainter extends CustomPainter {
  const _StarsPainter({required this.color});

  final Color color;

  static const List<(double, double, double)> _stars = [
    (0.20, 0.30, 1.0),
    (0.40, 0.70, 1.0),
    (0.65, 0.20, 1.2),
    (0.80, 0.60, 1.0),
    (0.55, 0.85, 1.0),
    (0.90, 0.35, 1.3),
    (0.12, 0.80, 1.0),
    (0.33, 0.12, 1.0),
    (0.72, 0.42, 0.8),
    (0.48, 0.30, 0.8),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color.withValues(alpha: 0.7);
    for (final (x, y, r) in _stars) {
      canvas.drawCircle(Offset(x * size.width, y * size.height), r, paint);
    }
  }

  @override
  bool shouldRepaint(_StarsPainter oldDelegate) => oldDelegate.color != color;
}

/// 外观：浅色 / 深色两张预览卡 + 「跟随系统」开关，读写 `themeModeProvider`。
///
/// 跟随系统时，高亮的是**当前实际生效**的那一张（和 iOS 设置一致）。
class _AppearanceSection extends StatelessWidget {
  const _AppearanceSection({required this.mode, required this.onChanged});

  final ThemeMode mode;
  final ValueChanged<ThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final followSystem = mode == ThemeMode.system;
    final effectiveDark = Theme.of(context).brightness == Brightness.dark;

    return AppGroupedList(
      header: '外观',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 6),
          child: Row(
            children: [
              Expanded(
                child: _ModePreviewCard(
                  key: const Key('appearance-light'),
                  dark: false,
                  selected: !effectiveDark,
                  onTap: () => onChanged(ThemeMode.light),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: _ModePreviewCard(
                  key: const Key('appearance-dark'),
                  dark: true,
                  selected: effectiveDark,
                  onTap: () => onChanged(ThemeMode.dark),
                ),
              ),
            ],
          ),
        ),
        AppGroupedRow(
          key: const Key('appearance-follow-system'),
          title: '跟随系统',
          // 第一行是预览卡，这里不画分隔线（和演示稿一致）
          showSeparator: false,
          trailing: Switch.adaptive(
            value: followSystem,
            // 关掉「跟随系统」时固定成当前看到的那一种，界面不会跳
            onChanged: (on) => onChanged(
              on
                  ? ThemeMode.system
                  : (effectiveDark ? ThemeMode.dark : ThemeMode.light),
            ),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onTap: () => onChanged(
            followSystem
                ? (effectiveDark ? ThemeMode.dark : ThemeMode.light)
                : ThemeMode.system,
          ),
        ),
      ],
    );
  }
}

/// 一张浅色 / 深色预览卡：缩小的「页面」—— 一根标题条、三个色块、底部大字。
///
/// 卡面颜色直接取 [AppPalette.light] / [AppPalette.dark] 的卡片色与文字色：
/// 它画的是「另一种模式长什么样」，所以不能跟着当前主题走。
/// 三个色块是插画色（演示稿 `.apc .blk`），写死在常量里。
class _ModePreviewCard extends StatelessWidget {
  const _ModePreviewCard({
    super.key,
    required this.dark,
    required this.selected,
    required this.onTap,
  });

  final bool dark;
  final bool selected;
  final VoidCallback onTap;

  // ── 插画常量：预览卡里的三个色块 ──
  static const List<Color> _lightBlocks = [
    Color(0xFF8B74E6),
    Color(0xFF4B94FF),
    Color(0xFF2B2B2F),
  ];
  static const List<Color> _darkBlocks = [
    Color(0xFF4A39A8),
    Color(0xFF1F6FE0),
    Color(0xFF48484C),
  ];

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final face = dark ? AppPalette.dark : AppPalette.light;
    final blocks = dark ? _darkBlocks : _lightBlocks;
    final label = dark ? '深色' : '浅色';

    return Semantics(
      button: true,
      selected: selected,
      label: '$label外观',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: AppMotion.of(context, AppMotion.normal),
          height: 128,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: face.card,
            borderRadius: BorderRadius.circular(22),
            // 选中：3dp 强调色描边；未选中：浅色卡在白底上加一圈发丝线免得糊在一起
            border: Border.all(
              color: selected
                  ? palette.accent
                  : (dark ? face.card : palette.separator),
              width: 3,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 7,
                    decoration: BoxDecoration(
                      color: face.text.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    dark ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
                    size: 18,
                    color: face.text,
                  ),
                ],
              ),
              Row(
                children: [
                  for (var i = 0; i < blocks.length; i++) ...[
                    if (i > 0) const SizedBox(width: 6),
                    Expanded(
                      child: Container(
                        height: 26,
                        decoration: BoxDecoration(
                          color: blocks[i],
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              Text(
                label,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: face.text,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
