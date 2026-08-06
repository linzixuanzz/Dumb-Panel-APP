import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/utils/time_utils.dart';

class _ApiScopeOption {
  final String value;
  final String label;
  final String description;

  const _ApiScopeOption(this.value, this.label, this.description);
}

const _apiScopeOptions = [
  _ApiScopeOption('tasks', '任务管理', '读取与操作定时任务'),
  _ApiScopeOption('scripts', '脚本管理', '访问脚本目录和执行入口'),
  _ApiScopeOption('envs', '环境变量', '读取和维护环境变量'),
  _ApiScopeOption('subscriptions', '订阅管理', '管理订阅仓库和文件'),
  _ApiScopeOption('logs', '日志查看', '读取执行日志和流式输出'),
  _ApiScopeOption('system', '系统信息', '读取系统信息和状态数据'),
];

class OpenApiPage extends ConsumerStatefulWidget {
  const OpenApiPage({super.key});

  @override
  ConsumerState<OpenApiPage> createState() => _OpenApiPageState();
}

class _OpenApiPageState extends ConsumerState<OpenApiPage> {
  List<Map<String, dynamic>> _apps = [];
  bool _loading = true;

  String _scopeLabel(String value) {
    for (final option in _apiScopeOptions) {
      if (option.value == value) {
        return option.label;
      }
    }
    return value;
  }

  List<String> _parseScopes(String scopes) {
    return scopes
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }

  String _joinScopes(List<String> scopes) => scopes.join(',');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final resp = await DioClient.instance.dio.get(ApiEndpoints.openApiApps);
      final data = extractData(resp.data);
      setState(() {
        _apps = (data is List)
            ? data.whereType<Map<String, dynamic>>().toList()
            : [];
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
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
                      'Open API',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: _showCreateDialog,
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: const BoxDecoration(
                        color: AppColors.primary,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.add,
                        size: 20,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: RefreshIndicator(
                color: AppColors.primary,
                onRefresh: _load,
                child: _loading && _apps.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: const [
                          SizedBox(height: 120),
                          Center(
                            child: CircularProgressIndicator(
                              color: AppColors.primary,
                            ),
                          ),
                        ],
                      )
                    : _apps.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          const SizedBox(height: 100),
                          Icon(
                            Icons.api_outlined,
                            size: 56,
                            color: AppColors.slate400.withAlpha(120),
                          ),
                          const SizedBox(height: 12),
                          const Center(
                            child: Text(
                              '暂无 API 应用',
                              style: TextStyle(color: AppColors.slate400),
                            ),
                          ),
                        ],
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                        itemCount: _apps.length,
                        itemBuilder: (_, i) =>
                            _buildAppCard(app: _apps[i], isLight: isLight),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showCreateDialog() {
    final nameC = TextEditingController();
    final rateLimitC = TextEditingController(text: '100');
    final selectedScopes = <String>{};
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useRootNavigator: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final navigator = Navigator.of(ctx);
          final rootMessenger = ScaffoldMessenger.of(context);
          return Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              0,
              20,
              MediaQuery.of(ctx).viewInsets.bottom + 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '创建 API 应用',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: nameC,
                  decoration: const InputDecoration(labelText: '应用名称'),
                ),
                const SizedBox(height: 12),
                const Text(
                  '权限范围',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _apiScopeOptions.map((option) {
                    return FilterChip(
                      label: Text(option.label),
                      selected: selectedScopes.contains(option.value),
                      onSelected: (selected) {
                        setSheetState(() {
                          if (selected) {
                            selectedScopes.add(option.value);
                          } else {
                            selectedScopes.remove(option.value);
                          }
                        });
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 8),
                Text(
                  '留空表示该应用创建成功，但没有任何接口访问权限。',
                  style: TextStyle(fontSize: 11, color: AppColors.slate400),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: rateLimitC,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '速率限制（次/小时）',
                    hintText: '默认 100',
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  height: 44,
                  child: FilledButton(
                    onPressed: () async {
                      if (nameC.text.trim().isEmpty) {
                        return;
                      }
                      try {
                        final resp = await DioClient.instance.dio.post(
                          ApiEndpoints.openApiApps,
                          data: {
                            'name': nameC.text.trim(),
                            'scopes': _joinScopes(selectedScopes.toList()),
                            'rate_limit':
                                int.tryParse(rateLimitC.text.trim()) ?? 100,
                          },
                        );
                        if (!mounted) {
                          return;
                        }
                        navigator.pop();
                        await _load();
                        final data = extractData(resp.data);
                        if (data is Map && data['app_secret'] != null) {
                          _showSecretDialog(
                            data['app_key']?.toString() ?? '',
                            data['app_secret'].toString(),
                          );
                        }
                      } catch (error) {
                        if (!mounted) {
                          return;
                        }
                        rootMessenger.showSnackBar(
                          SnackBar(
                            content: Text(
                              extractErrorMessage(error, '创建 API 应用失败'),
                            ),
                          ),
                        );
                      }
                    },
                    child: const Text('创建'),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 44,
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('取消'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showSecretDialog(String appKey, String appSecret) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('应用密钥'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '请妥善保管以下密钥，关闭后无法再次查看：',
              style: TextStyle(fontSize: 12, color: AppColors.red500),
            ),
            const SizedBox(height: 12),
            _CopyableField(label: 'App Key', value: appKey),
            const SizedBox(height: 8),
            _CopyableField(label: 'App Secret', value: appSecret),
          ],
        ),
        actions: [
          SizedBox(
            width: double.infinity,
            height: 44,
            child: FilledButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('我已保存'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppCard({
    required Map<String, dynamic> app,
    required bool isLight,
  }) {
    final id = (app['id'] as num?)?.toInt() ?? 0;
    final name = app['name']?.toString() ?? '';
    final appKey = app['app_key']?.toString() ?? '';
    final enabled = app['enabled'] != false;
    final callCount = (app['call_count'] as num?)?.toInt() ?? 0;
    final scopes = app['scopes']?.toString() ?? '';
    final rateLimit = (app['rate_limit'] as num?)?.toInt() ?? 0;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: isLight ? Colors.white : AppColors.slate900,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isLight ? AppColors.slate200 : AppColors.slate800,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          name,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: enabled
                                ? AppColors.primary.withAlpha(25)
                                : AppColors.slate400.withAlpha(25),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            enabled ? '启用' : '禁用',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: enabled
                                  ? AppColors.primary
                                  : AppColors.slate400,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    GestureDetector(
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: appKey));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('App Key 已复制')),
                        );
                      },
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              appKey,
                              style: TextStyle(
                                fontSize: 11,
                                fontFamily: 'monospace',
                                color: isLight
                                    ? AppColors.slate500
                                    : AppColors.slate400,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(Icons.copy, size: 12, color: AppColors.slate400),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: scopes.isEmpty
                          ? [
                              const Chip(
                                label: Text('未授权任何范围'),
                                visualDensity: VisualDensity.compact,
                              ),
                            ]
                          : _parseScopes(scopes)
                                .map(
                                  (scope) => Chip(
                                    label: Text(_scopeLabel(scope)),
                                    visualDensity: VisualDensity.compact,
                                  ),
                                )
                                .toList(),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                icon: Icon(
                  Icons.more_vert,
                  size: 18,
                  color: isLight ? AppColors.slate400 : AppColors.slate500,
                ),
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'edit', child: Text('编辑')),
                  const PopupMenuItem(
                    value: 'view_secret',
                    child: Text('查看密钥'),
                  ),
                  PopupMenuItem(
                    value: 'toggle',
                    child: Text(enabled ? '禁用' : '启用'),
                  ),
                  const PopupMenuItem(value: 'reset', child: Text('重置密钥')),
                  const PopupMenuItem(value: 'logs', child: Text('调用日志')),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text(
                      '删除',
                      style: TextStyle(color: AppColors.red500),
                    ),
                  ),
                ],
                onSelected: (v) async {
                  switch (v) {
                    case 'edit':
                      _showEditDialog(id, name, scopes, rateLimit);
                      break;
                    case 'view_secret':
                      _showViewSecretDialog(id, appKey);
                      break;
                    case 'toggle':
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (d) => AlertDialog(
                          title: Text(enabled ? '禁用应用' : '启用应用'),
                          content: Text(
                            enabled
                                ? '确认禁用「$name」吗？禁用后该 App Key / App Secret 将立即失效。'
                                : '确认启用「$name」吗？',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(d, false),
                              child: const Text('取消'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(d, true),
                              child: Text(enabled ? '禁用' : '启用'),
                            ),
                          ],
                        ),
                      );
                      if (confirm == true) {
                        try {
                          await DioClient.instance.dio.put(
                            enabled
                                ? ApiEndpoints.openApiAppDisable(id)
                                : ApiEndpoints.openApiAppEnable(id),
                          );
                          if (!mounted) {
                            return;
                          }
                          await _load();
                          if (!mounted) {
                            return;
                          }
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(enabled ? '应用已禁用' : '应用已启用'),
                            ),
                          );
                        } catch (error) {
                          if (!mounted) {
                            return;
                          }
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                extractErrorMessage(
                                  error,
                                  enabled ? '禁用应用失败' : '启用应用失败',
                                ),
                              ),
                            ),
                          );
                        }
                      }
                      break;
                    case 'reset':
                      try {
                        final resp = await DioClient.instance.dio.put(
                          ApiEndpoints.openApiAppResetSecret(id),
                        );
                        final data = extractData(resp.data);
                        if (data is Map && data['app_secret'] != null) {
                          _showSecretDialog(
                            appKey,
                            data['app_secret'].toString(),
                          );
                        }
                      } catch (error) {
                        if (!mounted) {
                          return;
                        }
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(extractErrorMessage(error, '重置密钥失败')),
                          ),
                        );
                      }
                      break;
                    case 'logs':
                      _showLogsDialog(id, name);
                      break;
                    case 'delete':
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (d) => AlertDialog(
                          title: const Text('删除应用'),
                          content: Text('确定要删除「$name」吗？'),
                          actions: [
                            Row(
                              children: [
                                Expanded(
                                  child: SizedBox(
                                    height: 44,
                                    child: OutlinedButton(
                                      onPressed: () => Navigator.pop(d, false),
                                      child: const Text('取消'),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: SizedBox(
                                    height: 44,
                                    child: FilledButton(
                                      onPressed: () => Navigator.pop(d, true),
                                      style: FilledButton.styleFrom(
                                        backgroundColor: AppColors.red500,
                                      ),
                                      child: const Text('删除'),
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
                          await DioClient.instance.dio.delete(
                            ApiEndpoints.openApiAppById(id),
                          );
                          if (!mounted) {
                            return;
                          }
                          await _load();
                          if (!mounted) {
                            return;
                          }
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('应用已删除')),
                          );
                        } catch (error) {
                          if (!mounted) {
                            return;
                          }
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                extractErrorMessage(error, '删除应用失败'),
                              ),
                            ),
                          );
                        }
                      }
                      break;
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '调用次数: $callCount · 速率限制: $rateLimit/小时',
            style: TextStyle(
              fontSize: 11,
              color: isLight ? AppColors.slate500 : AppColors.slate400,
            ),
          ),
        ],
      ),
    );
  }

  void _showEditDialog(int id, String name, String scopes, int rateLimit) {
    final nameC = TextEditingController(text: name);
    final rateLimitC = TextEditingController(text: rateLimit.toString());
    final selectedScopes = _parseScopes(scopes).toSet();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useRootNavigator: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final navigator = Navigator.of(ctx);
          final rootMessenger = ScaffoldMessenger.of(context);
          return Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              0,
              20,
              MediaQuery.of(ctx).viewInsets.bottom + 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '编辑应用',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: nameC,
                  decoration: const InputDecoration(labelText: '应用名称'),
                ),
                const SizedBox(height: 12),
                const Text(
                  '权限范围',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _apiScopeOptions.map((option) {
                    return FilterChip(
                      label: Text(option.label),
                      selected: selectedScopes.contains(option.value),
                      onSelected: (selected) {
                        setSheetState(() {
                          if (selected) {
                            selectedScopes.add(option.value);
                          } else {
                            selectedScopes.remove(option.value);
                          }
                        });
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: rateLimitC,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '速率限制（次/小时）',
                    hintText: '0 表示不限制',
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  height: 44,
                  child: FilledButton(
                    onPressed: () async {
                      try {
                        await DioClient.instance.dio.put(
                          ApiEndpoints.openApiAppById(id),
                          data: {
                            'name': nameC.text.trim(),
                            'scopes': _joinScopes(selectedScopes.toList()),
                            'rate_limit':
                                int.tryParse(rateLimitC.text.trim()) ?? 0,
                          },
                        );
                        if (!mounted) {
                          return;
                        }
                        navigator.pop();
                        await _load();
                        rootMessenger.showSnackBar(
                          const SnackBar(content: Text('应用已保存')),
                        );
                      } catch (error) {
                        if (!mounted) {
                          return;
                        }
                        rootMessenger.showSnackBar(
                          SnackBar(
                            content: Text(extractErrorMessage(error, '保存应用失败')),
                          ),
                        );
                      }
                    },
                    child: const Text('保存'),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 44,
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('取消'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showViewSecretDialog(int id, String appKey) {
    final passwordC = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('查看密钥'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '需要输入当前登录用户的密码来查看 App Secret',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: passwordC,
              obscureText: true,
              decoration: const InputDecoration(labelText: '密码'),
            ),
          ],
        ),
        actions: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(dialogCtx),
                    child: const Text('取消'),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: FilledButton(
                    onPressed: () async {
                      if (passwordC.text.isEmpty) return;
                      try {
                        final resp = await DioClient.instance.dio.post(
                          ApiEndpoints.openApiAppViewSecret(id),
                          data: {'password': passwordC.text},
                        );
                        final data = extractData(resp.data);
                        if (!mounted) {
                          return;
                        }
                        Navigator.of(dialogCtx).pop();
                        if (data is Map && data['app_secret'] != null) {
                          _showSecretDialog(
                            appKey,
                            data['app_secret'].toString(),
                          );
                        }
                      } catch (error) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                extractErrorMessage(error, '查看密钥失败'),
                              ),
                            ),
                          );
                        }
                      }
                    },
                    child: const Text('确认'),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showLogsDialog(int appId, String appName) async {
    List<Map<String, dynamic>> logs = [];
    try {
      final resp = await DioClient.instance.dio.get(
        ApiEndpoints.openApiAppLogs(appId),
        queryParameters: {'page': 1, 'page_size': 50},
      );
      final paginated = extractPaginated(resp.data);
      logs = paginated.items;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(extractErrorMessage(error, '加载调用日志失败'))),
        );
      }
    }

    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useRootNavigator: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.6,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                '$appName 调用日志',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: logs.isEmpty
                  ? const Center(
                      child: Text(
                        '暂无日志',
                        style: TextStyle(color: AppColors.slate400),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      itemCount: logs.length,
                      itemBuilder: (_, i) {
                        final log = logs[i];
                        final status = (log['status'] as num?)?.toInt() ?? 0;
                        final ok = status >= 200 && status < 300;
                        final time = DateTime.tryParse(
                          log['created_at']?.toString() ?? '',
                        );
                        final duration =
                            (log['duration'] as num?)?.toDouble() ?? 0;
                        return Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(ctx).brightness == Brightness.light
                                ? Colors.white
                                : AppColors.slate900,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color:
                                  Theme.of(ctx).brightness == Brightness.light
                                  ? AppColors.slate200
                                  : AppColors.slate800,
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: ok
                                      ? AppColors.primary.withAlpha(25)
                                      : AppColors.red500.withAlpha(25),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  '$status',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    fontFamily: 'monospace',
                                    color: ok
                                        ? AppColors.primary
                                        : AppColors.red500,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${log['method'] ?? ''} ${log['endpoint'] ?? ''}',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontFamily: 'monospace',
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      '${log['ip'] ?? ''} · ${duration.toStringAsFixed(1)}ms',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: AppColors.slate400,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Text(
                                formatTimeCn(time),
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: AppColors.slate400,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CopyableField extends StatelessWidget {
  final String label;
  final String value;
  const _CopyableField({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: AppColors.slate400),
        ),
        const SizedBox(height: 4),
        GestureDetector(
          onTap: () {
            Clipboard.setData(ClipboardData(text: value));
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('已复制 $label')));
          },
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.slate100,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    value,
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const Icon(Icons.copy, size: 14, color: AppColors.slate400),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ── Standalone logs page (for route /open-api/:id/logs) ──

class OpenApiLogsPage extends ConsumerStatefulWidget {
  final int appId;
  const OpenApiLogsPage({super.key, required this.appId});

  @override
  ConsumerState<OpenApiLogsPage> createState() => _OpenApiLogsPageState();
}

class _OpenApiLogsPageState extends ConsumerState<OpenApiLogsPage> {
  List<Map<String, dynamic>> _logs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final resp = await DioClient.instance.dio.get(
        ApiEndpoints.openApiAppLogs(widget.appId),
        queryParameters: {'page': 1, 'page_size': 100},
      );
      final paginated = extractPaginated(resp.data);
      setState(() {
        _logs = paginated.items;
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
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
                      'API 调用日志',
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
              child: RefreshIndicator(
                color: AppColors.primary,
                onRefresh: _load,
                child: _loading
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: const [
                          SizedBox(height: 120),
                          Center(
                            child: CircularProgressIndicator(
                              color: AppColors.primary,
                            ),
                          ),
                        ],
                      )
                    : _logs.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: const [
                          SizedBox(height: 100),
                          Center(
                            child: Text(
                              '暂无日志',
                              style: TextStyle(color: AppColors.slate400),
                            ),
                          ),
                        ],
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                        itemCount: _logs.length,
                        itemBuilder: (_, i) {
                          final log = _logs[i];
                          final status = (log['status'] as num?)?.toInt() ?? 0;
                          final ok = status >= 200 && status < 300;
                          final time = DateTime.tryParse(
                            log['created_at']?.toString() ?? '',
                          );
                          final duration =
                              (log['duration'] as num?)?.toDouble() ?? 0;
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: isLight
                                  ? Colors.white
                                  : AppColors.slate900,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isLight
                                    ? AppColors.slate200
                                    : AppColors.slate800,
                              ),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: ok
                                        ? AppColors.primary.withAlpha(25)
                                        : AppColors.red500.withAlpha(25),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    '$status',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      fontFamily: 'monospace',
                                      color: ok
                                          ? AppColors.primary
                                          : AppColors.red500,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${log['method'] ?? ''} ${log['endpoint'] ?? ''}',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontFamily: 'monospace',
                                          fontWeight: FontWeight.w500,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      Text(
                                        '${log['ip'] ?? ''} · ${duration.toStringAsFixed(1)}ms',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: isLight
                                              ? AppColors.slate500
                                              : AppColors.slate400,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Text(
                                  time != null ? formatTimeCn(time) : '',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: isLight
                                        ? AppColors.slate400
                                        : AppColors.slate500,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
