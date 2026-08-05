import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/auth/auth_service.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/storage/secure_storage.dart';
import '../../../shared/widgets/app_snack.dart';
import '../../dashboard/providers/dashboard_provider.dart';

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

  void _showMessage(String message) => AppSnack.show(context, message);

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
        content: Text(
          isNewPanel
              ? '服务器已保存。立即切换到“$panelLabel”并重新登录吗？'
              : '切换到“$panelLabel”需要退出当前账号后重新登录，是否继续？',
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
                    child: Text(isNewPanel ? '立即切换' : '切换登录'),
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
    await SecureStorage.clearAuthSession();
    DioClient.instance.setBaseUrl(finalUrl);
    await SecureStorage.saveServerUrl(finalUrl);
    ref.invalidate(dashboardProvider);

    if (!mounted) return;
    ref.read(authProvider.notifier).setUnauthenticated();
    context.go(skipAutoLogin ? '/login?manual=1' : '/boot');
  }

  Future<void> _connect({String? url, bool skipAutoLogin = true}) async {
    final selectedPanel = url == null
        ? null
        : _panels.where((p) => p.url == url).firstOrNull;

    if (_isManageMode && url != null && url == _activeServerUrl) {
      _showMessage('当前正在使用这个服务器');
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
          _showMessage('服务器已保存，当前账号保持不变');
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
      _showMessage('当前使用中的服务器暂时不能删除');
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
    final theme = Theme.of(context);
    final isAuthenticated =
        ref.watch(authProvider).status == AuthStatus.authenticated;

    return Scaffold(
      appBar: _isManageMode ? AppBar(title: const Text('服务器管理')) : null,
      body: SafeArea(
        top: !_isManageMode,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: _isManageMode ? 8 : 40),
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.asset('assets/icon.png', width: 64, height: 64),
              ),
              const SizedBox(height: 12),
              Text(
                _isManageMode ? '管理面板服务器' : '连接呆呆面板',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                _isManageMode ? '新增、删除或切换服务器，当前账号不会被直接中断。' : '选择已有面板或添加新面板',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                '建议使用 HTTPS；HTTP 连接需确认安全后方可使用。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              if (_panels.isNotEmpty) ...[
                const SizedBox(height: 28),
                Text('已保存的面板', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                ..._panels.map(
                  (panel) => Card(
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: theme.colorScheme.primaryContainer,
                        child: Icon(
                          Icons.dashboard,
                          size: 20,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      title: Text(
                        panel.name.isNotEmpty ? panel.name : panel.url,
                        style: theme.textTheme.titleSmall,
                      ),
                      subtitle: Text(
                        panel.url,
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (panel.url == _activeServerUrl)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primaryContainer,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                '当前',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          IconButton(
                            icon: Icon(
                              Icons.delete_outline,
                              size: 20,
                              color: theme.colorScheme.error,
                            ),
                            onPressed: () => _deletePanel(panel),
                          ),
                        ],
                      ),
                      onTap: () => _connect(
                        url: panel.url,
                        skipAutoLogin: !panel.autoLogin,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Divider(),
              ],
              const SizedBox(height: 20),
              Text('添加新面板', style: theme.textTheme.titleSmall),
              const SizedBox(height: 12),
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
                  style: TextStyle(color: theme.colorScheme.error),
                  textAlign: TextAlign.center,
                ),
              ] else if (_controller.text.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  _httpSecurityHint(_controller.text),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
              if (_isManageMode && isAuthenticated) ...[
                const SizedBox(height: 12),
                Text(
                  '新增服务器后会先保存配置，只有你确认切换时才会退出当前账号。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _checking ? null : _connect,
                child: _checking
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(_isManageMode ? '保存并检测' : '连接'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
