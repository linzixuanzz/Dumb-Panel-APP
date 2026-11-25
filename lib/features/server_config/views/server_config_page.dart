import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/auth/auth_service.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/providers/server_scoped_providers.dart';
import '../../../core/router/default_landing_page.dart';
import '../../../core/storage/secure_storage.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/widgets/app_back_button.dart';
import '../../../shared/widgets/app_grouped_list.dart';
import '../../../shared/widgets/app_icon_tile.dart';
import '../../../shared/widgets/app_large_title_header.dart';
import '../../../shared/widgets/app_pill_button.dart';
import '../../../shared/widgets/app_snack.dart';

class ServerConfigPage extends ConsumerStatefulWidget {
  const ServerConfigPage({super.key, this.manageMode = false});

  final bool manageMode;

  @override
  ConsumerState<ServerConfigPage> createState() => _ServerConfigPageState();
}

class _ServerConfigPageState extends ConsumerState<ServerConfigPage> {
  final _controller = TextEditingController();
  final _nameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  List<PanelConfig> _panels = [];
  String? _activeServerUrl;
  bool _checking = false;
  String? _error;

  bool get _isManageMode => widget.manageMode;

  @override
  void initState() {
    super.initState();
    _loadPanels();
  }

  Future<void> _loadPanels() async {
    _panels = await SecureStorage.getPanels();
    _activeServerUrl = await SecureStorage.getServerUrl();
    _controller.clear();
    _nameController.clear();

    if (mounted) {
      setState(() {});
    }
  }

  static final _ipPattern = RegExp(
    r'^(\d{1,3}\.){3}\d{1,3}(:\d+)?$|'
    r'^\[.*\](:\d+)?$|'
    r'^localhost(:\d+)?$',
  );

  bool _isLocalHttpHost(String hostPart) => _ipPattern.hasMatch(hostPart);

  String _normalizeUrl(String rawUrl) {
    var finalUrl = rawUrl.trim();
    if (!finalUrl.startsWith('http')) {
      final hostPart = finalUrl.split('/').first;
      finalUrl = _isLocalHttpHost(hostPart)
          ? 'http://$finalUrl'
          : 'https://$finalUrl';
    }
    if (finalUrl.endsWith('/')) {
      finalUrl = finalUrl.substring(0, finalUrl.length - 1);
    }
    return finalUrl;
  }

  bool _isExplicitHttpUrl(String url) => url.startsWith('http://');

  bool _isAllowedHttpUrl(String url) {
    if (!_isExplicitHttpUrl(url)) {
      return false;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return false;
    }
    return _isLocalHttpHost(uri.authority);
  }

  String _buildConnectError(String finalUrl) {
    if (_isExplicitHttpUrl(finalUrl)) {
      return '无法连接到服务器，请确认本地网络地址和端口可访问';
    }
    return '无法连接到服务器，请检查地址或确认面板已开启 HTTPS';
  }

  String _httpSecurityHint(String rawUrl) {
    final normalized = _normalizeUrl(rawUrl);
    if (_isExplicitHttpUrl(normalized)) {
      return '当前使用 HTTP 连接，数据传输未加密，请在可信网络中使用。';
    }
    return '公网域名建议使用 HTTPS 以保证数据安全。';
  }

  void _showSuccess(String message) => AppSnack.success(context, message);

  void _showWarning(String message) => AppSnack.warn(context, message);

  PanelConfig _panelForSave(String finalUrl, PanelConfig? existing) {
    final name = _nameController.text.trim();
    if (existing == null) {
      return PanelConfig(url: finalUrl, name: name.isEmpty ? finalUrl : name);
    }
    if (name.isNotEmpty && name != existing.name) {
      return existing.copyWith(name: name);
    }
    return existing;
  }

  Future<bool> _confirmSwitch(
    PanelConfig panel, {
    bool isNewPanel = false,
  }) async {
    final panelLabel = panel.name.isNotEmpty ? panel.name : panel.url;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('切换服务器'),
        // v1.3.7 起切面板不再退出当前账号，两台面板的登录状态各存各的（issue #13），
        // 所以这里的「需要退出当前账号」不再成立，文案一并改掉。
        content: Text(
          isNewPanel
              ? '服务器已保存。立即切换到“$panelLabel”吗？'
              : '切换到“$panelLabel”？当前账号不会退出，之前登录过的面板会直接进入。',
        ),
        actions: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(dialogCtx, false),
                    child: Text(isNewPanel ? '稍后切换' : '取消'),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(dialogCtx, true),
                    child: Text(isNewPanel ? '立即切换' : '切换'),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );

    return confirm == true;
  }

  Future<void> _switchToPanel(
    String finalUrl, {
    required bool skipAutoLogin,
  }) async {
    // v1.3.7 起**不再清凭据**（issue #13）：这里原来第一行就是 clearAuthSession()，
    // 那是纯客户端自加的限制 —— 后端从没要求切面板必须退出（access 20 天 / refresh 60 天，
    // /auth/refresh 不要密码不要 2FA，两台面板是两套独立后端零互踢）。
    // 凭据按面板分片存着，setBaseUrl 顺带把 scope 切过去，切回已登录过的面板
    // 直接进首页，不用重登、也不用再过一遍 2FA。
    DioClient.instance.setBaseUrl(finalUrl);
    await SecureStorage.saveServerUrl(finalUrl);

    // 上一台面板的数据必须当场作废，否则会原样显示在新面板上，详见函数内注释。
    invalidateServerScopedProviders(ref);

    // 新面板还有 token 且在可信期内 → 直接恢复成已登录；没命中时它自己会把状态
    // 置成 unauthenticated，所以下面不用再补一次 setUnauthenticated()。
    await ref.read(authProvider.notifier).restoreTrustedLocalSession();

    if (!mounted) return;
    if (ref.read(authProvider).status == AuthStatus.authenticated) {
      // 落到「默认打开页面」（APP #24），没设过就是主页
      context.go(DefaultLandingPage.route);
      return;
    }
    context.go(skipAutoLogin ? '/login?manual=1' : '/boot');
  }

  Future<void> _clearPanelSession(PanelConfig panel) async {
    final panelLabel = panel.name.isNotEmpty ? panel.name : panel.url;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('清除登录状态'),
        content: Text('清除“$panelLabel”保存在本机的登录凭据？下次切换到它需要重新登录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    await SecureStorage.clearAuthSessionForUrl(panel.url);
    if (!mounted) return;

    // 清的是当前正在用的这台，那当前会话也就没了，得当场踢回登录页，
    // 不能让用户拿着一个已经被删掉凭据的界面继续点。
    if (panel.url == _activeServerUrl) {
      invalidateServerScopedProviders(ref);
      ref.read(authProvider.notifier).setUnauthenticated();
      context.go('/login?manual=1');
      return;
    }

    _showSuccess('已清除“$panelLabel”的登录状态');
  }

  Future<void> _connect({String? url, bool skipAutoLogin = true}) async {
    final selectedPanel = url == null
        ? null
        : _panels.where((p) => p.url == url).firstOrNull;

    if (_isManageMode && url != null && url == _activeServerUrl) {
      // 拒绝执行而不是执行出错，用警告。
      _showWarning('当前正在使用这个服务器');
      return;
    }

    if (url != null) {
      _controller.text = url;
      _nameController.text =
          selectedPanel == null ||
              selectedPanel.name.isEmpty ||
              selectedPanel.name == selectedPanel.url
          ? ''
          : selectedPanel.name;
    } else {
      if (!_formKey.currentState!.validate()) return;
    }

    setState(() {
      _checking = true;
      _error = null;
    });

    var finalUrl = _normalizeUrl(_controller.text);
    if (_isExplicitHttpUrl(finalUrl) && !_isAllowedHttpUrl(finalUrl)) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          title: const Text('安全提示'),
          content: const Text('当前使用 HTTP 连接，数据传输未加密。\n建议仅在可信网络中使用，确认继续？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogCtx, true),
              child: const Text('继续连接'),
            ),
          ],
        ),
      );
      if (confirm != true) {
        setState(() => _checking = false);
        return;
      }
    }

    final authService = AuthService();
    var ok = await authService.checkHealth(finalUrl);

    if (!ok) {
      setState(() {
        _checking = false;
        _error = _buildConnectError(finalUrl);
      });
      return;
    }

    final existing = _panels.where((p) => p.url == finalUrl).firstOrNull;
    final panelToSave = _panelForSave(finalUrl, existing);
    if (existing == null || panelToSave.name != existing.name) {
      await SecureStorage.savePanel(panelToSave);
    }

    if (mounted) {
      setState(() => _checking = false);
    }

    final isAuthenticated =
        ref.read(authProvider).status == AuthStatus.authenticated;
    if (_isManageMode && isAuthenticated) {
      await _loadPanels();
      if (!mounted) return;

      final shouldSwitch = await _confirmSwitch(
        panelToSave,
        isNewPanel: url == null,
      );
      if (!shouldSwitch) {
        if (url == null) {
          _showSuccess('服务器已保存，当前账号保持不变');
        }
        return;
      }
    }

    _activeServerUrl = finalUrl;
    await _switchToPanel(finalUrl, skipAutoLogin: skipAutoLogin);
  }

  Future<void> _deletePanel(PanelConfig panel) async {
    final isAuthenticated =
        ref.read(authProvider).status == AuthStatus.authenticated;
    if (_isManageMode && isAuthenticated && panel.url == _activeServerUrl) {
      _showWarning('当前使用中的服务器暂时不能删除');
      return;
    }

    final panelLabel = panel.name.isNotEmpty ? panel.name : panel.url;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('删除服务器'),
        content: Text('确定删除“$panelLabel”吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    await SecureStorage.removePanel(panel.url);
    await _loadPanels();
  }

  @override
  void dispose() {
    _controller.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final isAuthenticated =
        ref.watch(authProvider).status == AuthStatus.authenticated;
    final caption = AppText.caption.copyWith(color: palette.text2);

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_isManageMode) ...[
                // 二级页：返回按钮在上，大标题在下（iOS 的导航大标题样式）
                const Align(
                  alignment: Alignment.centerLeft,
                  child: AppBackButton(),
                ),
                AppLargeTitleHeader(
                  title: '服务器管理',
                  subtitle: '新增、删除或切换服务器，每台面板的登录状态各自保存。',
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 20),
                ),
              ] else ...[
                const SizedBox(height: 32),
                Center(
                  child: ClipRRect(
                    // 与登录页、开屏页的图标同一种圆角（彩色图标方块 15/46 的比例）
                    borderRadius: BorderRadius.circular(
                      AppRadius.tile * 64 / 46,
                    ),
                    child: Image.asset(
                      'assets/icon.png',
                      width: 64,
                      height: 64,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '连接呆呆面板',
                  style: AppText.largeTitle.copyWith(color: palette.text),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                Text('选择已有面板或添加新面板', style: caption, textAlign: TextAlign.center),
                const SizedBox(height: 28),
              ],

              if (_panels.isNotEmpty) ...[
                AppGroupedList(
                  header: '已保存的面板',
                  children: [
                    for (final panel in _panels)
                      AppGroupedRow(
                        leading: AppIconTile(
                          icon: Icons.dns_rounded,
                          color: palette.accent,
                          // 当前在用的那台实色，其它浅底
                          solid: panel.url == _activeServerUrl,
                        ),
                        title: panel.name.isNotEmpty ? panel.name : panel.url,
                        subtitle: panel.url,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (panel.url == _activeServerUrl)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: palette.tint(palette.accent),
                                  borderRadius: BorderRadius.circular(
                                    AppRadius.pill,
                                  ),
                                ),
                                child: Text(
                                  '当前',
                                  style: AppText.caption.copyWith(
                                    fontSize: 12,
                                    color: palette.accentInk,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            // 凭据分片后每台面板各存一份登录状态，所以除了「删除服务器」，
                            // 还要给一个「只清这台的登录状态、保留地址」的出口（issue #13）。
                            // 两个动作收进同一个菜单，免得 trailing 挤成三个图标。
                            PopupMenuButton<String>(
                              icon: Icon(
                                Icons.more_horiz_rounded,
                                size: 22,
                                color: palette.text2,
                              ),
                              onSelected: (value) => value == 'clear'
                                  ? _clearPanelSession(panel)
                                  : _deletePanel(panel),
                              itemBuilder: (_) => [
                                const PopupMenuItem(
                                  value: 'clear',
                                  child: Text('清除该面板登录状态'),
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Text(
                                    '删除服务器',
                                    style: TextStyle(color: palette.errInk),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        onTap: () => _connect(
                          url: panel.url,
                          skipAutoLogin: !panel.autoLogin,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 28),
              ],

              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  '添加新面板',
                  style: caption.copyWith(fontWeight: FontWeight.w500),
                ),
              ),
              Form(
                key: _formKey,
                child: Column(
                  children: [
                    TextFormField(
                      controller: _nameController,
                      decoration: const InputDecoration(
                        labelText: '面板名称（可选）',
                        hintText: '如：家里的面板',
                        prefixIcon: Icon(Icons.label_outline),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _controller,
                      decoration: const InputDecoration(
                        labelText: '服务器地址',
                        hintText: '192.168.1.100:5700 或 panel.example.com',
                        prefixIcon: Icon(Icons.link),
                      ),
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.go,
                      onFieldSubmitted: (_) => _connect(),
                      validator: (v) =>
                          v == null || v.trim().isEmpty ? '请输入服务器地址' : null,
                    ),
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: AppText.caption.copyWith(color: palette.errInk),
                  textAlign: TextAlign.center,
                ),
              ] else if (_controller.text.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  _httpSecurityHint(_controller.text),
                  style: caption,
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 20),
              // v2.0 主操作：黑色胶囊。检测中只换文案、禁用，不在胶囊里转圈。
              AppPillButton(
                label: _checking
                    ? '正在检测…'
                    : (_isManageMode ? '保存并检测' : '连接'),
                expand: true,
                height: 52,
                onPressed: _checking ? null : _connect,
              ),
              const SizedBox(height: 16),
              Text(
                '建议使用 HTTPS；HTTP 连接需确认安全后方可使用。',
                style: caption,
                textAlign: TextAlign.center,
              ),
              if (_isManageMode && isAuthenticated) ...[
                const SizedBox(height: 8),
                Text(
                  '登录状态按面板分别保存在本机加密存储中，切换面板不会退出账号；'
                  '不想留着某台的凭据，可在它的菜单里「清除该面板登录状态」。',
                  style: caption,
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
