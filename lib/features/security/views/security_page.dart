import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/utils/time_utils.dart';
import '../../../shared/widgets/app_back_button.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/app_large_title_header.dart';
import '../../../shared/widgets/app_pill_button.dart';
import '../../../shared/widgets/app_snack.dart';

// ── Security Page (Tabbed) ──

class SecurityPage extends ConsumerStatefulWidget {
  const SecurityPage({super.key});

  @override
  ConsumerState<SecurityPage> createState() => _SecurityPageState();
}

class _SecurityPageState extends ConsumerState<SecurityPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return Scaffold(
      body: Padding(
        padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 12),
        child: Column(
          children: [
            // 返回头 + 大标题（v2.0 次级页面统一写法）
            const AppLargeTitleHeader(
              title: '安全设置',
              leading: AppBackButton(),
              padding: EdgeInsets.fromLTRB(8, 0, 16, 12),
            ),
            TabBar(
              controller: _tabController,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              labelColor: p.accentInk,
              unselectedLabelColor: p.text2,
              indicatorColor: p.accent,
              labelStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
              labelPadding: const EdgeInsets.symmetric(horizontal: 14),
              padding: const EdgeInsets.only(left: 20),
              tabs: const [
                Tab(text: '登录日志'),
                Tab(text: '活跃会话'),
                Tab(text: 'IP 白名单'),
                Tab(text: '两步验证'),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  const _LoginLogsTab(),
                  const _SessionsTab(),
                  const _IpWhitelistTab(),
                  const _TwoFaTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Login Logs Tab ──

class _LoginLogsTab extends ConsumerStatefulWidget {
  const _LoginLogsTab();

  @override
  ConsumerState<_LoginLogsTab> createState() => _LoginLogsTabState();
}

class _LoginLogsTabState extends ConsumerState<_LoginLogsTab>
    with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _logs = [];
  bool _loading = true;
  final TextEditingController _usernameController = TextEditingController();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final resp = await DioClient.instance.dio.get(
        ApiEndpoints.loginLogs,
        queryParameters: {
          'page': 1,
          'page_size': 100,
          if (_usernameController.text.trim().isNotEmpty)
            'username': _usernameController.text.trim(),
        },
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

  Future<void> _clearLogs() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('清理登录日志'),
        content: const Text('确定要清理全部登录日志吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          AppPillButton(
            label: '清理',
            variant: AppPillVariant.danger,
            height: 40,
            onPressed: () => Navigator.pop(dialogCtx, true),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    try {
      await DioClient.instance.dio.delete(ApiEndpoints.loginLogs);
      await _load();
      if (!mounted) {
        return;
      }
      AppSnack.success(context, '登录日志已清理');
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppSnack.error(context, extractErrorMessage(error, '清理登录日志失败'));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final p = context.palette;
    return RefreshIndicator(
      color: p.accent,
      onRefresh: _load,
      child: _loading
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const SizedBox(height: 120),
                Center(child: CircularProgressIndicator(color: p.accent)),
              ],
            )
          : ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _usernameController,
                        decoration: InputDecoration(
                          hintText: '按用户名筛选',
                          prefixIcon: const Icon(Icons.search, size: 18),
                          suffixIcon: _usernameController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, size: 16),
                                  onPressed: () {
                                    _usernameController.clear();
                                    setState(() {});
                                    _load();
                                  },
                                )
                              : null,
                        ),
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (_) => _load(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton.icon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('刷新'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                FilledButton.tonalIcon(
                  onPressed: _clearLogs,
                  icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                  label: const Text('清理登录日志'),
                  style: FilledButton.styleFrom(foregroundColor: p.errInk),
                ),
                const SizedBox(height: 12),
                if (_logs.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 80),
                    child: Center(
                      child: Text('暂无记录', style: TextStyle(color: p.text2)),
                    ),
                  )
                else
                  ..._logs.map((log) {
                    final success = (log['status'] as num?)?.toInt() == 0;
                    final time = DateTime.tryParse(
                      log['created_at']?.toString() ?? '',
                    );
                    return AppCard(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      child: Row(
                        children: [
                          // 登录成功/失败图标：成功走 success 绿，与失败的红成对。
                          // 原先成功是 primary —— 一个打勾图标用品牌蓝，
                          // 和「失败 = 红」不属于同一套语义。
                          Icon(
                            success ? Icons.check_circle : Icons.cancel,
                            size: 18,
                            color: success ? p.ok : p.err,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  log['username']?.toString() ?? '',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${log['ip'] ?? ''} · ${log['message'] ?? ''}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: p.text2,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  log['client_name']?.toString() ?? '客户端未知',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: p.text2,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          Text(
                            formatTimeCn(time),
                            style: TextStyle(
                              fontSize: 11,
                              color: p.text3,
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
              ],
            ),
    );
  }
}

// ── Sessions Tab ──

class _SessionsTab extends ConsumerStatefulWidget {
  const _SessionsTab();

  @override
  ConsumerState<_SessionsTab> createState() => _SessionsTabState();
}

class _SessionsTabState extends ConsumerState<_SessionsTab>
    with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _sessions = [];
  bool _loading = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final resp = await DioClient.instance.dio.get(ApiEndpoints.sessions);
      final data = extractData(resp.data);
      setState(() {
        _sessions = (data is List)
            ? data.whereType<Map<String, dynamic>>().toList()
            : [];
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  Future<void> _revokeOthers() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('撤销其他会话'),
        content: const Text('确定要撤销当前账号的所有其他活跃会话吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          AppPillButton(
            label: '撤销',
            variant: AppPillVariant.danger,
            height: 40,
            onPressed: () => Navigator.pop(dialogCtx, true),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    try {
      await DioClient.instance.dio.delete(ApiEndpoints.sessionsOthers);
      await _load();
      if (!mounted) {
        return;
      }
      AppSnack.success(context, '其他会话已撤销');
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppSnack.error(context, extractErrorMessage(error, '撤销其他会话失败'));
    }
  }

  Future<void> _revokeSession(int id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('撤销会话'),
        content: const Text('确定要撤销这个活跃会话吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          AppPillButton(
            label: '撤销',
            variant: AppPillVariant.danger,
            height: 40,
            onPressed: () => Navigator.pop(dialogCtx, true),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    try {
      await DioClient.instance.dio.delete(ApiEndpoints.sessionById(id));
      await _load();
      if (!mounted) {
        return;
      }
      AppSnack.success(context, '会话已撤销');
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppSnack.error(context, extractErrorMessage(error, '撤销会话失败'));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final p = context.palette;
    return RefreshIndicator(
      color: p.accent,
      onRefresh: _load,
      child: _loading
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const SizedBox(height: 120),
                Center(child: CircularProgressIndicator(color: p.accent)),
              ],
            )
          : _sessions.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                  child: SizedBox(
                    width: double.infinity,
                    height: 36,
                    child: OutlinedButton.icon(
                      onPressed: _revokeOthers,
                      icon: const Icon(Icons.logout, size: 16),
                      label: const Text(
                        '撤销其他会话',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 80),
                Center(
                  child: Text('暂无会话', style: TextStyle(color: p.text2)),
                ),
              ],
            )
          : ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              itemCount: _sessions.length + 1,
              itemBuilder: (_, i) {
                if (i == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: SizedBox(
                      width: double.infinity,
                      height: 36,
                      child: OutlinedButton.icon(
                        onPressed: _revokeOthers,
                        icon: const Icon(Icons.logout, size: 16),
                        label: const Text(
                          '撤销其他会话',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  );
                }
                final s = _sessions[i - 1];
                final expires = DateTime.tryParse(
                  s['expires_at']?.toString() ?? '',
                );
                return AppCard(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.devices, size: 18, color: p.accent),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${s['username'] ?? ''} · ${s['ip'] ?? ''}',
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              expires != null
                                  ? '过期: ${formatTimeCn(expires)}'
                                  : '',
                              style: TextStyle(
                                fontSize: 11,
                                color: p.text2,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '客户端: ${s['client_name'] ?? s['client_type_label'] ?? '未知'}',
                              style: TextStyle(
                                fontSize: 11,
                                color: p.text2,
                              ),
                            ),
                            if ((s['user_agent']?.toString() ?? '').isNotEmpty)
                              Text(
                                'UA: ${s['user_agent']}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: p.text2,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                      GestureDetector(
                        onTap: () {
                          final id = (s['id'] as num?)?.toInt();
                          if (id != null) {
                            _revokeSession(id);
                          }
                        },
                        child: Icon(Icons.close, size: 18, color: p.err),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

// ── IP Whitelist Tab ──

class _IpWhitelistTab extends ConsumerStatefulWidget {
  const _IpWhitelistTab();

  @override
  ConsumerState<_IpWhitelistTab> createState() => _IpWhitelistTabState();
}

class _IpWhitelistTabState extends ConsumerState<_IpWhitelistTab>
    with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final resp = await DioClient.instance.dio.get(ApiEndpoints.ipWhitelist);
      final data = extractData(resp.data);
      setState(() {
        _items = (data is List)
            ? data.whereType<Map<String, dynamic>>().toList()
            : [];
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  Future<void> _deleteItem(Map<String, dynamic> item) async {
    final id = (item['id'] as num?)?.toInt();
    if (id == null) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('删除白名单'),
        content: Text('确定删除 IP「${item['ip'] ?? ''}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          AppPillButton(
            label: '删除',
            variant: AppPillVariant.danger,
            height: 40,
            onPressed: () => Navigator.pop(dialogCtx, true),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }

    try {
      await DioClient.instance.dio.delete(ApiEndpoints.ipWhitelistById(id));
      await _load();
      if (!mounted) {
        return;
      }
      AppSnack.success(context, 'IP 白名单已删除');
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppSnack.error(context, extractErrorMessage(error, '删除 IP 白名单失败'));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final p = context.palette;
    return RefreshIndicator(
      color: p.accent,
      onRefresh: _load,
      child: _loading
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const SizedBox(height: 120),
                Center(child: CircularProgressIndicator(color: p.accent)),
              ],
            )
          : _items.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                  child: SizedBox(
                    width: double.infinity,
                    height: 36,
                    child: FilledButton.icon(
                      onPressed: _showAddDialog,
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text(
                        '添加 IP',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 80),
                Center(
                  child: Text('暂无白名单', style: TextStyle(color: p.text2)),
                ),
              ],
            )
          : ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              itemCount: _items.length + 1,
              itemBuilder: (_, i) {
                if (i == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: SizedBox(
                      width: double.infinity,
                      height: 36,
                      child: FilledButton.icon(
                        onPressed: _showAddDialog,
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text(
                          '添加 IP',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  );
                }
                final item = _items[i - 1];
                return AppCard(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.shield_outlined, size: 18, color: p.accent),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item['ip']?.toString() ?? '',
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                fontFamily: 'monospace',
                              ),
                            ),
                            if ((item['remarks']?.toString() ?? '').isNotEmpty)
                              Text(
                                item['remarks'].toString(),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: p.text2,
                                ),
                              ),
                          ],
                        ),
                      ),
                      GestureDetector(
                        onTap: () => _deleteItem(item),
                        child: Icon(
                          Icons.delete_outline,
                          size: 18,
                          color: p.err,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  void _showAddDialog() {
    final ipC = TextEditingController();
    final remarksC = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('添加 IP 白名单'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ipC,
              decoration: const InputDecoration(labelText: 'IP 地址'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: remarksC,
              decoration: const InputDecoration(labelText: '备注 (可选)'),
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
                      if (ipC.text.trim().isEmpty) return;
                      try {
                        await DioClient.instance.dio.post(
                          ApiEndpoints.ipWhitelist,
                          data: {
                            'ip': ipC.text.trim(),
                            'remarks': remarksC.text.trim(),
                          },
                        );
                        if (!mounted) {
                          return;
                        }
                        // 弹窗可能已被别的途径关掉，pop 前确认它的 context 还在。
                        if (!dialogCtx.mounted) return;
                        Navigator.of(dialogCtx).pop();
                        await _load();
                        if (!mounted) {
                          return;
                        }
                        AppSnack.success(context, 'IP 白名单已添加');
                      } catch (error) {
                        if (!mounted) {
                          return;
                        }
                        AppSnack.error(
                          context,
                          extractErrorMessage(error, '添加 IP 白名单失败'),
                        );
                      }
                    },
                    child: const Text('添加'),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── 2FA Tab ──

class _TwoFaTab extends ConsumerStatefulWidget {
  const _TwoFaTab();

  @override
  ConsumerState<_TwoFaTab> createState() => _TwoFaTabState();
}

class _TwoFaTabState extends ConsumerState<_TwoFaTab>
    with AutomaticKeepAliveClientMixin {
  bool _enabled = false;
  bool _loading = true;
  String? _secret;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    setState(() => _loading = true);
    try {
      final resp = await DioClient.instance.dio.get(ApiEndpoints.twoFaStatus);
      final data = extractData(resp.data);
      setState(() {
        _enabled = data is Map && data['enabled'] == true;
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final p = context.palette;
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: p.accent));
    }

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppCard(
            child: Row(
              children: [
                Icon(
                  Icons.security,
                  size: 24,
                  // 「已启用」统一走 success 绿。
                  color: _enabled ? p.ok : p.text3,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '两步验证 (TOTP)',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _enabled ? '已启用' : '未启用',
                        style: TextStyle(
                          fontSize: 12,
                          color: _enabled ? p.okInk : p.text2,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_enabled)
                  OutlinedButton(
                    onPressed: _disable2FA,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: p.errInk,
                      side: BorderSide(color: p.err),
                      minimumSize: const Size(0, 36),
                    ),
                    child: const Text('禁用', style: TextStyle(fontSize: 12)),
                  )
                else
                  FilledButton(
                    onPressed: _setup2FA,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 36),
                    ),
                    child: const Text('设置', style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
          ),
          if (_secret != null) ...[
            const SizedBox(height: 16),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('请使用验证器扫描或输入密钥:', style: TextStyle(fontSize: 13)),
                  const SizedBox(height: 8),
                  SelectableText(
                    _secret!,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _VerifyCodeInput(onVerify: (code) => _verify2FA(code)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _setup2FA() async {
    try {
      final resp = await DioClient.instance.dio.post(ApiEndpoints.twoFaSetup);
      final data = extractData(resp.data);
      if (data is Map) {
        setState(() {
          _secret = data['secret']?.toString();
        });
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppSnack.error(context, extractErrorMessage(error, '获取 2FA 密钥失败'));
    }
  }

  Future<void> _verify2FA(String code) async {
    try {
      await DioClient.instance.dio.post(
        ApiEndpoints.twoFaVerify,
        data: {'code': code},
      );
      setState(() {
        _enabled = true;
        _secret = null;
      });
      if (mounted) {
        // 「验证」按钮可以连点重试，覆盖掉上一条结果，
        // 否则改完验证码再点一次，看到的仍是上一次排队中的旧提示。
        AppSnack.success(context, '2FA 已启用', replaceCurrent: true);
      }
    } catch (_) {
      if (mounted) {
        // 验证码不对属于校验没过，不是请求出错，不报红。
        AppSnack.warn(context, '验证码错误', replaceCurrent: true);
      }
    }
  }

  Future<void> _disable2FA() async {
    final codeController = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('禁用两步验证'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('请输入当前验证器里的 6 位动态验证码后再禁用。'),
            const SizedBox(height: 12),
            TextField(
              controller: codeController,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: const InputDecoration(
                labelText: '动态验证码',
                hintText: '6位数字',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('取消'),
          ),
          AppPillButton(
            label: '禁用',
            variant: AppPillVariant.danger,
            height: 40,
            onPressed: () =>
                Navigator.pop(dialogCtx, codeController.text.trim()),
          ),
        ],
      ),
    );
    codeController.dispose();
    if (code == null || code.length != 6) {
      return;
    }
    try {
      await DioClient.instance.dio.delete(
        ApiEndpoints.twoFa,
        data: {'code': code},
      );
      if (!mounted) {
        return;
      }
      setState(() => _enabled = false);
      AppSnack.success(context, '2FA 已禁用');
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppSnack.error(context, extractErrorMessage(error, '禁用 2FA 失败'));
    }
  }
}

class _VerifyCodeInput extends StatefulWidget {
  final Future<void> Function(String) onVerify;
  const _VerifyCodeInput({required this.onVerify});

  @override
  State<_VerifyCodeInput> createState() => _VerifyCodeInputState();
}

class _VerifyCodeInputState extends State<_VerifyCodeInput> {
  final _codeC = TextEditingController();

  @override
  void dispose() {
    _codeC.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _codeC,
            decoration: const InputDecoration(
              labelText: '验证码',
              hintText: '6位数字',
            ),
            keyboardType: TextInputType.number,
            maxLength: 6,
          ),
        ),
        const SizedBox(width: 12),
        FilledButton(
          onPressed: () {
            if (_codeC.text.length == 6) widget.onVerify(_codeC.text);
          },
          child: const Text('验证'),
        ),
      ],
    );
  }
}