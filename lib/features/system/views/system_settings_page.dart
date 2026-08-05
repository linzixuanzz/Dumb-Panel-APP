import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/app_section_title.dart';

class SystemSettingsPage extends ConsumerStatefulWidget {
  const SystemSettingsPage({super.key});

  @override
  ConsumerState<SystemSettingsPage> createState() => _SystemSettingsPageState();
}

class _SystemSettingsPageState extends ConsumerState<SystemSettingsPage> {
  Map<String, dynamic>? _versionInfo;
  Map<String, dynamic>? _updateInfo;
  Map<String, dynamic>? _updateStatus;
  bool _loading = true;
  bool _checking = false;
  bool _savingConfigs = false;
  bool _updatingPanel = false;

  final _concurrencyC = TextEditingController();
  final _logRetentionC = TextEditingController();
  final _logMaxSizeC = TextEditingController();
  final _randomDelayC = TextEditingController();
  final _fileSuffixC = TextEditingController();
  final _editorBackgroundColorC = TextEditingController();
  final _proxyUrlC = TextEditingController();
  final _updateImageMirrorC = TextEditingController();
  final _binaryUpdateProxyC = TextEditingController();
  bool _autoInstallDeps = false;

  static const _dockerMirrorOptions = [
    'https://docker.1ms.run',
    'https://docker.1panel.live',
    'https://docker.sparkcr.cn',
    'https://hub.rat.dev',
    'https://dockerproxy.net',
    'https://mirror.ccs.tencentyun.com',
  ];

  static const _binaryProxyOptions = [
    'https://gh-proxy.org/',
    'https://v4.gh-proxy.org/',
    'http://gh.301.ee/',
    'https://ghproxy.homeboyc.cn/',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _concurrencyC.dispose();
    _logRetentionC.dispose();
    _logMaxSizeC.dispose();
    _randomDelayC.dispose();
    _fileSuffixC.dispose();
    _editorBackgroundColorC.dispose();
    _proxyUrlC.dispose();
    _updateImageMirrorC.dispose();
    _binaryUpdateProxyC.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        DioClient.instance.dio.get(ApiEndpoints.systemVersion),
        DioClient.instance.dio.get(ApiEndpoints.configs),
      ]);
      final versionData = extractData(results[0].data);
      final configData = extractData(results[1].data);

      final configs = configData is Map<String, dynamic>
          ? configData
          : <String, dynamic>{};

      // Parse task execution configs
      _concurrencyC.text = _getConfigValueAny(configs, [
        'max_concurrent_tasks',
        'max_concurrency',
      ], '5');
      _logRetentionC.text = _getConfigValue(configs, 'log_retention_days', '7');
      _logMaxSizeC.text = _getConfigValueAny(configs, [
        'max_log_content_size',
        'log_max_size',
      ], '102400');
      _randomDelayC.text = _getConfigValue(configs, 'random_delay', '0');
      _fileSuffixC.text = _getConfigValueAny(configs, [
        'random_delay_extensions',
        'file_suffix',
      ], 'js py');
      _editorBackgroundColorC.text = _getConfigValue(
        configs,
        'editor_background_color',
        '',
      );
      _autoInstallDeps =
          _getConfigValue(configs, 'auto_install_deps', 'false') == 'true';
      _proxyUrlC.text = _getConfigValue(configs, 'proxy_url', '');
      _updateImageMirrorC.text = _getConfigValue(
        configs,
        'update_image_mirror',
        '',
      );
      _binaryUpdateProxyC.text = _getConfigValue(
        configs,
        'binary_update_proxy',
        '',
      );

      setState(() {
        _versionInfo = versionData is Map<String, dynamic> ? versionData : null;
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  String _getConfigValue(
    Map<String, dynamic> configs,
    String key,
    String fallback,
  ) {
    final config = configs[key];
    if (config is Map<String, dynamic>) {
      return config['value']?.toString() ?? fallback;
    }
    return fallback;
  }

  String _getConfigValueAny(
    Map<String, dynamic> configs,
    List<String> keys,
    String fallback,
  ) {
    for (final key in keys) {
      final value = _getConfigValue(configs, key, '');
      if (value.trim().isNotEmpty) {
        return value;
      }
    }
    return fallback;
  }

  Future<void> _checkUpdate() async {
    setState(() => _checking = true);
    try {
      final resp = await DioClient.instance.dio.get(ApiEndpoints.checkUpdate);
      final data = extractData(resp.data);
      setState(() {
        _updateInfo = data is Map<String, dynamic> ? data : null;
        _checking = false;
      });
      if (_updateInfo != null && _updateInfo!['has_update'] == true) {
        if (mounted) _showUpdateDialog();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('已是最新版本')));
        }
      }
    } catch (e) {
      setState(() => _checking = false);
      if (mounted) {
        String msg = '检查更新失败';
        if (e is DioException && e.response?.data is Map) {
          msg = (e.response!.data as Map)['error']?.toString() ?? msg;
        }
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(msg)));
      }
    }
  }

  bool get _isWatchtowerManaged {
    final target = _updateInfo?['update_target'];
    if (target is! Map) {
      return false;
    }
    return target['update_manager']?.toString() == 'watchtower' ||
        target['watchtower_managed'] == true;
  }

  bool get _isBinaryUpdate {
    final target = _updateInfo?['update_target'];
    if (target is! Map) {
      return false;
    }
    return target['deployment_type']?.toString() == 'binary';
  }

  String _updateActionLabel() {
    if (_isWatchtowerManaged) {
      return '触发 Watchtower 检查';
    }
    return '立即更新';
  }

  String _updateSuccessHint() {
    if (_isWatchtowerManaged) {
      return '已触发 Watchtower 检查更新，请稍后查看 Watchtower 日志或等待容器重建结果';
    }
    if (_isBinaryUpdate) {
      return '后台更新任务已启动，面板完成替换后会自动重启';
    }
    return '更新任务已启动，面板将拉取镜像并重建容器';
  }

  String _buildUpdateSummary() {
    final target = _updateInfo?['update_target'];
    if (target is! Map) {
      return '';
    }
    final lines = <String>[];
    if (target['deployment_type']?.toString() == 'binary') {
      lines.add('更新方式：二进制后台更新');
    } else if (_isWatchtowerManaged) {
      lines.add('更新方式：Watchtower 托管更新');
    } else {
      lines.add('更新方式：Docker 镜像更新');
    }
    final assetName = target['asset_name']?.toString() ?? '';
    if (assetName.trim().isNotEmpty) {
      lines.add('更新包：$assetName');
    }
    final installDir = target['install_dir']?.toString() ?? '';
    if (installDir.trim().isNotEmpty) {
      lines.add('安装目录：$installDir');
    }
    final mirrorHost = target['mirror_host']?.toString() ?? '';
    if (mirrorHost.trim().isNotEmpty) {
      lines.add('镜像源：$mirrorHost');
    }
    final channel = target['channel']?.toString() ?? '';
    if (channel.trim().isNotEmpty) {
      lines.add('渠道：${channel == 'debian' ? 'Debian' : 'Latest (Alpine)'}');
    }
    final schedule = target['watchtower_schedule']?.toString() ?? '';
    if (schedule.trim().isNotEmpty) {
      lines.add('Watchtower 调度：$schedule');
    }
    final reason = _updateInfo?['update_disabled_reason']?.toString() ?? '';
    if (reason.trim().isNotEmpty) {
      lines.add(reason.trim());
    }
    return lines.join('\n');
  }

  Future<void> _loadUpdateStatus() async {
    try {
      final response = await DioClient.instance.dio.get(
        '${ApiEndpoints.baseApi}/system/update-status',
      );
      final data = extractData(response.data);
      if (!mounted) {
        return;
      }
      setState(() {
        _updateStatus = data is Map<String, dynamic>
            ? data
            : data is Map
            ? Map<String, dynamic>.from(data)
            : null;
      });
    } catch (_) {}
  }

  void _showUpdateDialog() {
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('发现新版本'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('当前: ${_updateInfo?['current'] ?? ''}'),
            Text('最新: ${_updateInfo?['latest'] ?? ''}'),
            if ((_updateInfo?['release_notes'] ?? '')
                .toString()
                .isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                _updateInfo!['release_notes'].toString(),
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ],
        ),
        actions: [
          if (_updateInfo?['auto_update_supported'] == true)
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(dialogCtx),
                      child: const Text('稍后'),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: FilledButton(
                      onPressed: () {
                        Navigator.pop(dialogCtx);
                        _doUpdate();
                      },
                      child: Text(_updateActionLabel()),
                    ),
                  ),
                ),
              ],
            )
          else
            SizedBox(
              width: double.infinity,
              height: 44,
              child: OutlinedButton(
                onPressed: () => Navigator.pop(dialogCtx),
                child: const Text('稍后'),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _doUpdate() async {
    setState(() => _updatingPanel = true);
    try {
      final response = await DioClient.instance.dio.post(
        '${ApiEndpoints.baseApi}/system/update',
      );
      final data = extractData(response.data);
      if (mounted) {
        setState(() {
          _updateStatus = data is Map<String, dynamic>
              ? data
              : data is Map
              ? Map<String, dynamic>.from(data)
              : _updateStatus;
        });
      }
      await _loadUpdateStatus();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_updateSuccessHint())));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(extractErrorMessage(error, '更新失败'))),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _updatingPanel = false);
      }
    }
  }

  Future<void> _restart() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('重启面板'),
        content: const Text('确定要重启面板吗？所有运行中的任务将被中断。'),
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
                    child: const Text('重启'),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (confirm == true) {
      try {
        await DioClient.instance.dio.post(
          '${ApiEndpoints.baseApi}/system/restart',
        );
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('面板将在 2 秒后重启')));
        }
      } catch (_) {}
    }
  }

  Future<void> _showMirrorOptions({
    required String title,
    required List<String> urls,
    required TextEditingController controller,
    String? intro,
  }) async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                style: Theme.of(
                  ctx,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (intro != null && intro.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  intro,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              ...urls.map(
                (url) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx, url),
                    style: OutlinedButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                    child: Text(
                      url,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected != null) {
      setState(() => controller.text = selected);
    }
  }

  Future<void> _saveTaskConfigs() async {
    setState(() => _savingConfigs = true);
    try {
      await DioClient.instance.dio.put(
        ApiEndpoints.configsBatch,
        data: {
          'configs': {
            'max_concurrent_tasks': _concurrencyC.text.trim(),
            'log_retention_days': _logRetentionC.text.trim(),
            'max_log_content_size': _logMaxSizeC.text.trim(),
            'random_delay': _randomDelayC.text.trim(),
            'random_delay_extensions': _fileSuffixC.text.trim(),
            'auto_install_deps': _autoInstallDeps ? 'true' : 'false',
            'editor_background_color': _editorBackgroundColorC.text.trim(),
            'proxy_url': _proxyUrlC.text.trim(),
            'update_image_mirror': _updateImageMirrorC.text.trim(),
            'binary_update_proxy': _binaryUpdateProxyC.text.trim(),
          },
        },
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('配置已保存')));
      }
    } catch (error) {
      // 收紧 validateStatus 之前，面板返回 400 也会走 try 分支弹「配置已保存」，
      // 用户根本看不出保存失败。现在 4xx 会进到这里，直接把后端原文透出来。
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(extractErrorMessage(error, '保存失败'))),
        );
      }
    }
    setState(() => _savingConfigs = false);
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;

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
                      '系统设置',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: AppColors.primary,
                      ),
                    )
                  : RefreshIndicator(
                      color: AppColors.primary,
                      onRefresh: _load,
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
                        children: [
                          // ── Version Info ──
                          if (_versionInfo != null) ...[
                            const AppSectionTitle('版本信息'),
                            AppCard(
                              child: Column(
                                children: [
                                  _KVRow(
                                    '版本',
                                    _versionInfo?['version']?.toString() ?? '',
                                    isLight,
                                  ),
                                  const Divider(height: 16),
                                  _KVRow(
                                    'API',
                                    _versionInfo?['api_version']?.toString() ??
                                        '',
                                    isLight,
                                  ),
                                  const Divider(height: 16),
                                  _KVRow(
                                    'Go',
                                    _versionInfo?['go_version']?.toString() ??
                                        '',
                                    isLight,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 8),
                            SizedBox(
                              height: 40,
                              child: OutlinedButton.icon(
                                onPressed: _checking ? null : _checkUpdate,
                                icon: _checking
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.system_update, size: 16),
                                label: Text(
                                  _checking ? '检查中...' : '检查更新',
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                            ),
                            if (_updateInfo != null) ...[
                              const SizedBox(height: 10),
                              AppCard(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _updateInfo?['has_update'] == true
                                          ? '发现新版本：${_updateInfo?['latest'] ?? '-'}'
                                          : '当前已是最新版本',
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    if (_buildUpdateSummary().trim().isNotEmpty) ...[
                                      const SizedBox(height: 8),
                                      Text(
                                        _buildUpdateSummary(),
                                        style: TextStyle(
                                          fontSize: 12,
                                          height: 1.6,
                                          color: isLight
                                              ? AppColors.slate600
                                              : AppColors.slate300,
                                        ),
                                      ),
                                    ],
                                    if (_updateInfo?['has_update'] == true &&
                                        _updateInfo?['auto_update_supported'] ==
                                            true) ...[
                                      const SizedBox(height: 12),
                                      SizedBox(
                                        width: double.infinity,
                                        height: 42,
                                        child: FilledButton(
                                          onPressed: _updatingPanel
                                              ? null
                                              : _doUpdate,
                                          child: Text(
                                            _updatingPanel
                                                ? '处理中...'
                                                : _updateActionLabel(),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ],

                          const SizedBox(height: 20),

                          if (_updateStatus != null &&
                              (_updateStatus?['status']?.toString().trim().isNotEmpty ??
                                  false) &&
                              _updateStatus?['status'] != 'idle') ...[
                            const AppSectionTitle('更新状态'),
                            const SizedBox(height: 8),
                            AppCard(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '状态：${_updateStatus?['status'] ?? '-'}',
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    _updateStatus?['message']?.toString() ?? '暂无状态说明',
                                    style: TextStyle(
                                      fontSize: 12,
                                      height: 1.6,
                                      color: isLight
                                          ? AppColors.slate600
                                          : AppColors.slate300,
                                    ),
                                  ),
                                  if ((_updateStatus?['phase']?.toString() ?? '')
                                      .trim()
                                      .isNotEmpty) ...[
                                    const SizedBox(height: 6),
                                    Text(
                                      '阶段：${_updateStatus?['phase']}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: isLight
                                            ? AppColors.slate500
                                            : AppColors.slate400,
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 12),
                                  SizedBox(
                                    width: double.infinity,
                                    height: 40,
                                    child: OutlinedButton.icon(
                                      onPressed: _loadUpdateStatus,
                                      icon: const Icon(
                                        Icons.refresh_rounded,
                                        size: 18,
                                      ),
                                      label: const Text('刷新更新状态'),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 20),
                          ],

                          // ── 任务运行 ──
                          const AppSectionTitle('任务运行'),
                          const SizedBox(height: 8),
                          AppCard(
                            child: Column(
                              children: [
                                _ConfigField(
                                  label: '并发数',
                                  hint: '5',
                                  controller: _concurrencyC,
                                  isLight: isLight,
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    Expanded(
                                      child: _ConfigField(
                                        label: '日志保留(天)',
                                        hint: '7',
                                        controller: _logRetentionC,
                                        isLight: isLight,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: _ConfigField(
                                        label: '日志上限(字节)',
                                        hint: '102400',
                                        controller: _logMaxSizeC,
                                        isLight: isLight,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    Expanded(
                                      child: _ConfigField(
                                        label: '随机延迟(秒)',
                                        hint: '0 不延迟',
                                        controller: _randomDelayC,
                                        isLight: isLight,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: _ConfigField(
                                        label: '延迟文件后缀',
                                        hint: 'js py',
                                        controller: _fileSuffixC,
                                        isLight: isLight,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                SwitchListTile.adaptive(
                                  value: _autoInstallDeps,
                                  contentPadding: EdgeInsets.zero,
                                  dense: true,
                                  title: const Text(
                                    '自动安装缺失依赖',
                                    style: TextStyle(fontSize: 13),
                                  ),
                                  subtitle: Text(
                                    '运行失败时自动安装',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: isLight
                                          ? AppColors.slate500
                                          : AppColors.slate400,
                                    ),
                                  ),
                                  onChanged: (v) =>
                                      setState(() => _autoInstallDeps = v),
                                ),
                              ],
                            ),
                          ),

                          const SizedBox(height: 20),

                          // ── 面板外观 ──
                          const AppSectionTitle('面板外观'),
                          const SizedBox(height: 8),
                          AppCard(
                            child: _ConfigField(
                              label: '日志背景色',
                              hint: '#111827 或 rgba(...)，留空默认',
                              controller: _editorBackgroundColorC,
                              isLight: isLight,
                            ),
                          ),

                          const SizedBox(height: 20),

                          // ── 代理设置 ──
                          const AppSectionTitle('代理设置'),
                          const SizedBox(height: 8),
                          AppCard(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _ConfigField(
                                  label: '代理地址',
                                  hint: 'http://127.0.0.1:7890，留空不使用代理',
                                  controller: _proxyUrlC,
                                  isLight: isLight,
                                ),
                                const SizedBox(height: 10),
                                _InlineHint(
                                  isLight: isLight,
                                  text:
                                      '仅当服务器访问 GitHub、npm、pip、Docker 镜像等外部网络需要代理时填写；留空表示面板直连，不影响局域网访问面板。',
                                ),
                                const SizedBox(height: 14),
                                _MirrorField(
                                  label: '系统更新镜像源',
                                  hint: 'https://docker.example.com，留空直连',
                                  controller: _updateImageMirrorC,
                                  isLight: isLight,
                                  onPick: () => _showMirrorOptions(
                                    title: '系统更新镜像源',
                                    urls: _dockerMirrorOptions,
                                    controller: _updateImageMirrorC,
                                    intro:
                                        'Docker 部署更新使用。也可以到 https://status.anye.xyz/ 查看更多镜像源状态后手动填写。',
                                  ),
                                  onClear: () => setState(
                                    () => _updateImageMirrorC.clear(),
                                  ),
                                ),
                                const SizedBox(height: 14),
                                _MirrorField(
                                  label: '二进制更新加速源',
                                  hint:
                                      'https://gh-proxy.example.com/，留空直连 GitHub',
                                  controller: _binaryUpdateProxyC,
                                  isLight: isLight,
                                  onPick: () => _showMirrorOptions(
                                    title: '二进制更新加速源',
                                    urls: _binaryProxyOptions,
                                    controller: _binaryUpdateProxyC,
                                    intro:
                                        '二进制部署更新使用，用于加速 GitHub Release 更新包下载。',
                                  ),
                                  onClear: () => setState(
                                    () => _binaryUpdateProxyC.clear(),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            height: 44,
                            child: FilledButton(
                              onPressed: _savingConfigs
                                  ? null
                                  : _saveTaskConfigs,
                              child: Text(_savingConfigs ? '保存中...' : '保存配置'),
                            ),
                          ),

                          const SizedBox(height: 24),

                          // ── 系统操作 ──
                          const AppSectionTitle('系统操作'),
                          const SizedBox(height: 8),
                          _ActionBtn(
                            icon: Icons.backup,
                            title: '备份恢复',
                            subtitle: '创建备份、恢复、管理备份文件',
                            isLight: isLight,
                            onTap: () => context.push('/backup'),
                          ),
                          const SizedBox(height: 8),
                          _ActionBtn(
                            icon: Icons.article_outlined,
                            title: '面板日志',
                            subtitle: '查看面板运行日志，支持级别与关键字筛选',
                            isLight: isLight,
                            onTap: () => context.push('/panel-log'),
                          ),
                          const SizedBox(height: 8),
                          _ActionBtn(
                            icon: Icons.restart_alt,
                            title: '重启面板',
                            subtitle: '重启面板服务，运行中任务将中断',
                            isLight: isLight,
                            onTap: _restart,
                            danger: true,
                          ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineHint extends StatelessWidget {
  final bool isLight;
  final String text;

  const _InlineHint({required this.isLight, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.blue500.withAlpha(12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.blue500.withAlpha(30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 16, color: AppColors.blue500),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: isLight ? AppColors.slate600 : AppColors.slate300,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _KVRow extends StatelessWidget {
  final String label;
  final String value;
  final bool isLight;
  const _KVRow(this.label, this.value, this.isLight);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: isLight ? AppColors.slate500 : AppColors.slate400,
          ),
        ),
        const Spacer(),
        Text(
          value,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }
}

class _ConfigField extends StatelessWidget {
  final String label;
  final String hint;
  final TextEditingController controller;
  final bool isLight;

  const _ConfigField({
    required this.label,
    required this.hint,
    required this.controller,
    required this.isLight,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(
              fontSize: 11,
              color: isLight ? AppColors.slate400 : AppColors.slate500,
            ),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          style: const TextStyle(fontSize: 13),
          keyboardType: TextInputType.text,
        ),
        const SizedBox(height: 2),
        Text(
          hint,
          style: TextStyle(
            fontSize: 10,
            color: isLight ? AppColors.slate400 : AppColors.slate500,
          ),
        ),
      ],
    );
  }
}

class _MirrorField extends StatelessWidget {
  final String label;
  final String hint;
  final TextEditingController controller;
  final bool isLight;
  final VoidCallback onPick;
  final VoidCallback onClear;

  const _MirrorField({
    required this.label,
    required this.hint,
    required this.controller,
    required this.isLight,
    required this.onPick,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            TextButton(onPressed: onPick, child: const Text('配置')),
            if (controller.text.trim().isNotEmpty)
              TextButton(onPressed: onClear, child: const Text('清空')),
          ],
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(
              fontSize: 11,
              color: isLight ? AppColors.slate400 : AppColors.slate500,
            ),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          style: const TextStyle(fontSize: 13),
          keyboardType: TextInputType.url,
        ),
      ],
    );
  }
}

class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool isLight;
  final VoidCallback onTap;
  final bool danger;

  const _ActionBtn({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.isLight,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
              color: danger ? AppColors.red500 : AppColors.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: danger ? AppColors.red500 : null,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11,
                      color: isLight ? AppColors.slate500 : AppColors.slate400,
                    ),
                  ),
                ],
              ),
            ),
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
