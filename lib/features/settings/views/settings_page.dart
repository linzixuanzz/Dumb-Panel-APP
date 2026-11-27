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

              // ── Nordic 温润个人与节点卡 ──
              _NordicProfileCard(
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

/// Nordic Calm 温润节点与个人卡：洁净纸感底、柔和描边与在线绿点，彻底取代刺眼星空紫卡。
class _NordicProfileCard extends StatelessWidget {
  const _NordicProfileCard({
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

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final surfaces = AppSurfaces.of(context);
    final host = serverUrl
        ?.replaceAll('http://', '')
        .replaceAll('https://', '');
    final name =
        (panelName == null || panelName!.isEmpty || panelName == serverUrl)
        ? null
        : panelName;
    final line2 = [?roleLabel, ?name].join(' · ');

    return Semantics(
      button: true,
      label: '个人信息与当前面板，点按管理服务器',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: palette.card,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: surfaces.cardBorder),
          boxShadow: surfaces.softShadow,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppRadius.card),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: palette.separator),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(15),
                      child: Image.asset(
                        'assets/icon.png',
                        width: 56,
                        height: 56,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                username ?? '未获取到用户信息',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: -0.2,
                                  color: palette.text,
                                ),
                              ),
                            ),
                            if (host != null && host.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                  color: palette.ok,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ],
                          ],
                        ),
                        if (line2.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            line2,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.caption.copyWith(
                              fontWeight: FontWeight.w500,
                              color: palette.text2,
                            ),
                          ),
                        ],
                        if (host != null && host.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            host,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.meta.copyWith(color: palette.text3),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: palette.text3,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
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

  // ── 插画常量：Nordic Calm 预览卡色块（钴蓝 · 森林绿 · 暖石层次）──
  static const List<Color> _lightBlocks = [
    Color(0xFF2B5BEE),
    Color(0xFF15803D),
    Color(0xFFEFECE6),
  ];
  static const List<Color> _darkBlocks = [
    Color(0xFF6C93FF),
    Color(0xFF22C55E),
    Color(0xFF25282E),
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
          height: 118,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: face.bg,
            borderRadius: BorderRadius.circular(AppRadius.cardSm),
            border: Border.all(
              color: selected ? palette.accent : palette.separator,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 6,
                    decoration: BoxDecoration(
                      color: face.text.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    dark ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
                    size: 17,
                    color: selected ? palette.accent : face.text2,
                  ),
                ],
              ),
              Row(
                children: [
                  for (var i = 0; i < blocks.length; i++) ...[
                    if (i > 0) const SizedBox(width: 6),
                    Expanded(
                      child: Container(
                        height: 24,
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
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
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
