import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/sse_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/models/subscription.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/utils/ansi_text.dart';
import '../../../shared/utils/duration_utils.dart';
import '../../../shared/utils/log_background.dart';
import '../../../shared/utils/time_utils.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/app_notice.dart';
import '../utils/subscription_auth.dart';

// ── Provider ──

final subscriptionListProvider =
    StateNotifierProvider<SubscriptionListNotifier, SubscriptionListState>((
      ref,
    ) {
      return SubscriptionListNotifier();
    });

class SubscriptionListState {
  final List<Subscription> items;
  final bool loading;
  final String keyword;
  final String? error;

  const SubscriptionListState({
    this.items = const [],
    this.loading = false,
    this.keyword = '',
    this.error,
  });

  SubscriptionListState copyWith({
    List<Subscription>? items,
    bool? loading,
    String? keyword,
    String? error,
  }) {
    return SubscriptionListState(
      items: items ?? this.items,
      loading: loading ?? this.loading,
      keyword: keyword ?? this.keyword,
      error: error,
    );
  }
}

class SubscriptionListNotifier extends StateNotifier<SubscriptionListState> {
  SubscriptionListNotifier() : super(const SubscriptionListState());

  Future<void> load() async {
    state = state.copyWith(loading: true);
    try {
      final dio = DioClient.instance.dio;
      // 面板把 page_size 卡在 100：`if pageSize < 1 || pageSize > 100 { pageSize = 20 }`
      // （server/handler/subscription.go:139-141）。原来这里写 200，超限后被**静默**
      // 回落到 20 —— 订阅超过 20 条，第 21 条起在 APP 上根本看不见，而且没有任何报错。
      // 100 是面板允许的上限；超过 100 条订阅还需要真正的分页，另计。
      final params = <String, dynamic>{'page': 1, 'page_size': 100};
      if (state.keyword.isNotEmpty) params['keyword'] = state.keyword;
      final resp = await dio.get(
        ApiEndpoints.subscriptions,
        queryParameters: params,
      );
      final paginated = extractPaginated(resp.data);
      final items = paginated.items
          .map((e) => Subscription.fromJson(e))
          .toList();
      state = state.copyWith(items: items, loading: false, error: null);
    } catch (_) {
      state = state.copyWith(loading: false, error: '加载订阅失败');
    }
  }

  void setKeyword(String keyword) {
    state = state.copyWith(keyword: keyword);
    load();
  }

  Future<void> toggle(int id, bool enabled) async {
    final dio = DioClient.instance.dio;
    if (enabled) {
      await dio.put(ApiEndpoints.subscriptionEnable(id));
    } else {
      await dio.put(ApiEndpoints.subscriptionDisable(id));
    }
    await load();
  }

  Future<void> pull(Subscription sub) async {
    final dio = DioClient.instance.dio;
    if (sub.type != sub.normalizedType) {
      await dio.put(
        ApiEndpoints.subscriptionById(sub.id),
        data: {'type': sub.normalizedType},
      );
    }
    await dio.put(ApiEndpoints.subscriptionPull(sub.id));
    await load();
  }

  Future<void> stopPull(int id) async {
    await DioClient.instance.dio.put(ApiEndpoints.subscriptionPullStop(id));
    await load();
  }

  Future<void> delete(int id) async {
    await DioClient.instance.dio.delete(ApiEndpoints.subscriptionById(id));
    await load();
  }

  Future<void> create(Map<String, dynamic> data) async {
    await DioClient.instance.dio.post(ApiEndpoints.subscriptions, data: data);
    await load();
  }

  Future<void> update(int id, Map<String, dynamic> data) async {
    await DioClient.instance.dio.put(
      ApiEndpoints.subscriptionById(id),
      data: data,
    );
    await load();
  }
}

// ── Page ──

class SubscriptionListPage extends ConsumerStatefulWidget {
  const SubscriptionListPage({super.key});

  @override
  ConsumerState<SubscriptionListPage> createState() =>
      _SubscriptionListPageState();
}

class _SubscriptionListPageState extends ConsumerState<SubscriptionListPage> {
  final _searchController = TextEditingController();
  Timer? _debounce;

  /// 面板已有的 SSH 密钥。订阅表单里的密钥下拉靠它。
  ///
  /// 面板**没有**独立的 SSH 密钥页面：`/ssh-keys` 的 5 条路由是订阅页的子功能
  /// （web/src/views/subscriptions/index.vue:1350-1365 就是订阅表单里的一个下拉）。
  /// 所以 APP 这边也只做「选一把已有的密钥」，不做密钥管理页 —— 那会做出一个
  /// 面板自己都没有的页面。
  List<SshKeyOption> _sshKeys = const [];

  /// 拉不到密钥列表时给用户的解释。`/ssh-keys` 挂了 RequireAdmin
  /// （server/handler/ssh_key.go:108），非管理员必然 403 —— 这种时候必须说清
  /// 「你没权限看密钥」，而不是甩一个空下拉让人以为面板里没配过密钥。
  String? _sshKeyLoadError;

  /// 正在进行的加载，避免连开两次表单打两次请求。
  Future<void>? _sshKeyLoading;
  bool _sshKeysLoaded = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(subscriptionListProvider.notifier).load());
    // 提前拉一次，用户点「新建」时下拉通常已经就绪。
    unawaited(_ensureSshKeys());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  /// 保证 SSH 密钥列表已加载。成功过就不再重复请求；失败过则允许下次重试。
  Future<void> _ensureSshKeys() {
    if (_sshKeysLoaded) {
      return Future<void>.value();
    }
    return _sshKeyLoading ??= _loadSshKeys();
  }

  Future<void> _loadSshKeys() async {
    try {
      final response = await DioClient.instance.dio.get(ApiEndpoints.sshKeys);
      final keys = parseSshKeys(response.data);
      if (!mounted) {
        return;
      }
      setState(() {
        _sshKeys = keys;
        _sshKeyLoadError = null;
        _sshKeysLoaded = true;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      final status = error is DioException
          ? error.response?.statusCode
          : null;
      setState(() {
        _sshKeys = const [];
        _sshKeyLoadError = status == 403
            ? '只有管理员能查看 SSH 密钥，请改用 Access Token 或让管理员代为配置。'
            : _extractRequestErrorMessage(error, '加载 SSH 密钥失败');
      });
    } finally {
      _sshKeyLoading = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(subscriptionListProvider);
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;

    return Scaffold(
      body: Padding(
        padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 12),
        child: Column(
          children: [
            // Header
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
                      '订阅管理',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => _showCreateDialog(),
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

            // Search
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: SizedBox(
                height: 44,
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: '搜索订阅...',
                    prefixIcon: const Icon(
                      Icons.search,
                      size: 18,
                      color: AppColors.slate400,
                    ),
                    filled: true,
                    fillColor: isLight ? Colors.white : AppColors.slate900,
                    // 逐字复制 app_theme 的三处 OutlineInputBorder：
                    // 计划裁决只令牌化不删除。三处圆角同值是聚焦动画的硬要求。
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      borderSide: BorderSide(
                        color: isLight
                            ? AppColors.slate200
                            : AppColors.slate800,
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      borderSide: BorderSide(
                        color: isLight
                            ? AppColors.slate200
                            : AppColors.slate800,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      borderSide: const BorderSide(
                        color: AppColors.primary,
                        width: 1.5,
                      ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    isDense: true,
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(
                              Icons.clear,
                              size: 16,
                              color: AppColors.slate400,
                            ),
                            onPressed: () {
                              _searchController.clear();
                              ref
                                  .read(subscriptionListProvider.notifier)
                                  .setKeyword('');
                            },
                          )
                        : null,
                  ),
                  style: const TextStyle(fontSize: 14),
                  onChanged: (v) {
                    setState(() {});
                    _debounce?.cancel();
                    _debounce = Timer(const Duration(milliseconds: 300), () {
                      ref.read(subscriptionListProvider.notifier).setKeyword(v);
                    });
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),

            // List
            Expanded(
              child: RefreshIndicator(
                color: AppColors.primary,
                onRefresh: () =>
                    ref.read(subscriptionListProvider.notifier).load(),
                child: state.loading && state.items.isEmpty
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
                    : state.items.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          const SizedBox(height: 100),
                          Icon(
                            Icons.sync_disabled,
                            size: 56,
                            color: AppColors.slate400.withAlpha(120),
                          ),
                          const SizedBox(height: 12),
                          const Center(
                            child: Text(
                              '暂无订阅',
                              style: TextStyle(color: AppColors.slate400),
                            ),
                          ),
                        ],
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                        itemCount: state.items.length,
                        itemBuilder: (_, i) {
                          final sub = state.items[i];
                          return _SubCard(
                            sub: sub,
                            isLight: isLight,
                            onPull: () => _doPull(sub),
                            onStopPull: () => _doStopPull(sub),
                            onLogs: () => _openLogs(sub),
                            onToggle: () => _doToggle(sub),
                            onDelete: () => _confirmDelete(sub),
                            onEdit: () => _showEditDialog(sub),
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

  /// 启用/禁用原来是直接内联调 notifier 的裸 await，没有任何 catch。
  /// 收紧 validateStatus 后 4xx 会抛异常，必须在这里兜住并提示。
  Future<void> _doToggle(Subscription sub) async {
    try {
      await ref
          .read(subscriptionListProvider.notifier)
          .toggle(sub.id, !sub.enabled);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_extractRequestErrorMessage(error, '修改订阅状态失败')),
        ),
      );
    }
  }

  Future<void> _doPull(Subscription sub) async {
    try {
      await ref.read(subscriptionListProvider.notifier).pull(sub);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已触发拉取')));
      context.push('/subscriptions/${sub.id}/pull-stream');
    } catch (error) {
      final message = _extractRequestErrorMessage(error, '拉取失败');
      if (!mounted) {
        return;
      }
      if (message.contains('拉取中')) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('该订阅已在拉取中')));
        context.push('/subscriptions/${sub.id}/pull-stream');
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _doStopPull(Subscription sub) async {
    try {
      await ref.read(subscriptionListProvider.notifier).stopPull(sub.id);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已停止拉取')));
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_extractRequestErrorMessage(error, '停止拉取失败'))),
      );
    }
  }

  void _openLogs(Subscription sub) {
    context.push('/subscriptions/${sub.id}/logs', extra: sub.name);
  }

  Future<void> _confirmDelete(Subscription sub) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除订阅'),
        content: Text('确定要删除「${sub.name}」吗？'),
        actions: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: const Text('取消'),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(dialogContext, true),
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
        await ref.read(subscriptionListProvider.notifier).delete(sub.id);
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('订阅已删除')));
      } catch (error) {
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_extractRequestErrorMessage(error, '删除订阅失败'))),
        );
      }
    }
  }

  Future<void> _showCreateDialog() async {
    final nameC = TextEditingController();
    final urlC = TextEditingController();
    final branchC = TextEditingController();
    final subPathC = TextEditingController();
    final scheduleC = TextEditingController();
    final saveDirC = TextEditingController();
    final aliasC = TextEditingController();
    final whitelistC = TextEditingController();
    final blacklistC = TextEditingController();
    final dependOnC = TextEditingController();
    final hookScriptC = TextEditingController();
    final auth = _AuthFormState.create();
    String selectedType = 'git-repo';
    bool forceOverwrite = true;

    // 先把密钥列表拿到手再开弹窗。弹窗内容是 StatefulBuilder 闭包，请求回来时
    // 用外层 setState 刷不到它，而在闭包里存 setSheetState 又会在弹窗关掉之后
    // 变成对已卸载 Element 调 setState。开之前 await 一次最省心：
    // initState 里已经预热过，绝大多数情况下这里是立即返回的。
    await _ensureSshKeys();
    if (!mounted) {
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useRootNavigator: true,
      builder: (ctx) {
        final navigator = Navigator.of(ctx);
        final rootMessenger = ScaffoldMessenger.of(context);
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final theme = Theme.of(ctx);
            final bottomInset = MediaQuery.of(ctx).viewInsets.bottom;
            return SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.75,
              child: Padding(
                padding: EdgeInsets.only(bottom: bottomInset),
                child: Column(
                  children: [
                    // 固定标题
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '新建订阅',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    // 可滚动表单
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            TextField(
                              controller: nameC,
                              decoration: const InputDecoration(
                                labelText: '名称',
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                const Text(
                                  '类型  ',
                                  style: TextStyle(fontSize: 13),
                                ),
                                ...['git-repo', 'single-file'].map((t) {
                                  final label = t == 'git-repo'
                                      ? 'Git 仓库'
                                      : '单文件';
                                  return Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: ChoiceChip(
                                      label: Text(
                                        label,
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                      selected: selectedType == t,
                                      onSelected: (_) =>
                                          setSheetState(() => selectedType = t),
                                      visualDensity: VisualDensity.compact,
                                    ),
                                  );
                                }),
                              ],
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: urlC,
                              decoration: InputDecoration(
                                labelText: selectedType == 'single-file'
                                    ? '文件 URL'
                                    : '仓库地址',
                              ),
                            ),
                            const SizedBox(height: 12),
                            if (selectedType != 'single-file') ...[
                              TextField(
                                controller: branchC,
                                decoration: const InputDecoration(
                                  labelText: '分支',
                                  hintText: '默认分支 (留空使用默认)',
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: subPathC,
                                decoration: const InputDecoration(
                                  labelText: '指定子目录',
                                  hintText: '逗号分隔多个，留空拉取全部',
                                ),
                              ),
                              const SizedBox(height: 12),
                            ],
                            TextField(
                              controller: scheduleC,
                              decoration: const InputDecoration(
                                labelText: '定时拉取',
                                hintText: 'cron 表达式 (留空不自动拉取)',
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: saveDirC,
                              decoration: const InputDecoration(
                                labelText: '保存目录',
                                hintText: '保存到 scripts 下的子目录',
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: aliasC,
                              decoration: const InputDecoration(
                                labelText: '别名',
                                hintText: '目录/文件别名',
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: whitelistC,
                              decoration: const InputDecoration(
                                labelText: '白名单',
                                hintText: '文件名/路径白名单 (逗号分隔)',
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: blacklistC,
                              decoration: const InputDecoration(
                                labelText: '黑名单',
                                hintText: '文件名/路径黑名单 (逗号分隔)',
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: dependOnC,
                              decoration: const InputDecoration(
                                labelText: '依赖说明',
                                hintText: '订阅依赖、过滤说明或迁移信息',
                              ),
                            ),
                            if (selectedType != 'single-file') ...[
                              const SizedBox(height: 16),
                              Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          '覆盖本地修改',
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          forceOverwrite
                                              ? '拉取时覆盖本地修改'
                                              : '拉取时保留本地修改的文件',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: Colors.grey,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Switch(
                                    value: forceOverwrite,
                                    onChanged: (v) =>
                                        setSheetState(() => forceOverwrite = v),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: hookScriptC,
                                maxLines: 3,
                                decoration: const InputDecoration(
                                  labelText: '拉取后钩子',
                                  hintText: '拉取成功后执行的 Shell 命令',
                                  alignLabelWithHint: true,
                                ),
                              ),
                              const SizedBox(height: 8),
                              const _HookScriptHint(),
                              _SubscriptionAuthFields(
                                state: auth,
                                sshKeys: _sshKeys,
                                sshKeyLoadError: _sshKeyLoadError,
                                onChanged: () => setSheetState(() {}),
                              ),
                            ],
                            const SizedBox(height: 16),
                          ],
                        ),
                      ),
                    ),
                    // 固定底部按钮
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                      child: Column(
                        children: [
                          SizedBox(
                            width: double.infinity,
                            height: 44,
                            child: FilledButton(
                              onPressed: () async {
                                if (nameC.text.trim().isEmpty) return;
                                // 面板对鉴权字段有两条硬校验，本地先拦一道，
                                // 省掉一个「点保存 → 等一个来回 → 看到同一句话」。
                                final authError = auth.validate(selectedType);
                                if (authError != null) {
                                  rootMessenger.showSnackBar(
                                    SnackBar(content: Text(authError)),
                                  );
                                  return;
                                }
                                try {
                                  await ref
                                      .read(subscriptionListProvider.notifier)
                                      .create({
                                        'name': nameC.text.trim(),
                                        'type': selectedType,
                                        'url': urlC.text.trim(),
                                        'branch': branchC.text.trim(),
                                        'sub_path': subPathC.text.trim(),
                                        'schedule': scheduleC.text.trim(),
                                        'save_dir': saveDirC.text.trim(),
                                        'alias': aliasC.text.trim(),
                                        'whitelist': whitelistC.text.trim(),
                                        'blacklist': blacklistC.text.trim(),
                                        'depend_on': dependOnC.text.trim(),
                                        'hook_script': hookScriptC.text.trim(),
                                        'force_overwrite': forceOverwrite,
                                        ...auth.payload(selectedType),
                                      });
                                  if (!mounted) {
                                    return;
                                  }
                                  navigator.pop();
                                  rootMessenger.showSnackBar(
                                    const SnackBar(content: Text('订阅已创建')),
                                  );
                                } catch (error) {
                                  if (!mounted) {
                                    return;
                                  }
                                  rootMessenger.showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        _extractRequestErrorMessage(
                                          error,
                                          '创建订阅失败',
                                        ),
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
                            width: double.infinity,
                            height: 44,
                            child: OutlinedButton(
                              onPressed: () => Navigator.of(ctx).pop(),
                              child: const Text('取消'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
      // 鉴权那两个输入框是本次新加的，关弹窗时释放掉。
      // 其余控制器是既有代码就没释放的，不在本次改动范围内一并动。
    ).whenComplete(auth.dispose);
  }

  Future<void> _showEditDialog(Subscription sub) async {
    final nameC = TextEditingController(text: sub.name);
    final urlC = TextEditingController(text: sub.url);
    final branchC = TextEditingController(text: sub.branch);
    final subPathC = TextEditingController(text: sub.subPath ?? '');
    final scheduleC = TextEditingController(text: sub.schedule);
    final saveDirC = TextEditingController(text: sub.saveDir);
    final aliasC = TextEditingController(text: sub.alias);
    final whitelistC = TextEditingController(text: sub.whitelist);
    final blacklistC = TextEditingController(text: sub.blacklist);
    final dependOnC = TextEditingController(text: sub.dependOn);
    final hookScriptC = TextEditingController(text: sub.hookScript);
    final auth = _AuthFormState.edit(sub);
    String selectedType = sub.normalizedType;
    bool forceOverwrite = sub.forceOverwrite ?? true;

    await _ensureSshKeys();
    if (!mounted) {
      auth.dispose();
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useRootNavigator: true,
      builder: (ctx) {
        final navigator = Navigator.of(ctx);
        final rootMessenger = ScaffoldMessenger.of(context);
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final theme = Theme.of(ctx);
            final bottomInset = MediaQuery.of(ctx).viewInsets.bottom;
            return SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.75,
              child: Padding(
                padding: EdgeInsets.only(bottom: bottomInset),
                child: Column(
                  children: [
                    // 固定标题
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '编辑订阅',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    // 可滚动表单
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            TextField(
                              controller: nameC,
                              decoration: const InputDecoration(
                                labelText: '名称',
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                const Text(
                                  '类型  ',
                                  style: TextStyle(fontSize: 13),
                                ),
                                ...['git-repo', 'single-file'].map((t) {
                                  final label = t == 'git-repo'
                                      ? 'Git 仓库'
                                      : '单文件';
                                  return Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: ChoiceChip(
                                      label: Text(
                                        label,
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                      selected: selectedType == t,
                                      onSelected: (_) =>
                                          setSheetState(() => selectedType = t),
                                      visualDensity: VisualDensity.compact,
                                    ),
                                  );
                                }),
                              ],
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: urlC,
                              decoration: InputDecoration(
                                labelText: selectedType == 'single-file'
                                    ? '文件 URL'
                                    : '仓库地址',
                              ),
                            ),
                            const SizedBox(height: 12),
                            if (selectedType != 'single-file') ...[
                              TextField(
                                controller: branchC,
                                decoration: const InputDecoration(
                                  labelText: '分支',
                                  hintText: '默认分支 (留空使用默认)',
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: subPathC,
                                decoration: const InputDecoration(
                                  labelText: '指定子目录',
                                  hintText: '逗号分隔多个，留空拉取全部',
                                ),
                              ),
                              const SizedBox(height: 12),
                            ],
                            TextField(
                              controller: scheduleC,
                              decoration: const InputDecoration(
                                labelText: '定时拉取',
                                hintText: 'cron 表达式 (留空不自动拉取)',
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: saveDirC,
                              decoration: const InputDecoration(
                                labelText: '保存目录',
                                hintText: '保存到 scripts 下的子目录',
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: aliasC,
                              decoration: const InputDecoration(
                                labelText: '别名',
                                hintText: '目录/文件别名',
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: whitelistC,
                              decoration: const InputDecoration(
                                labelText: '白名单',
                                hintText: '文件名/路径白名单 (逗号分隔)',
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: blacklistC,
                              decoration: const InputDecoration(
                                labelText: '黑名单',
                                hintText: '文件名/路径黑名单 (逗号分隔)',
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: dependOnC,
                              decoration: const InputDecoration(
                                labelText: '依赖说明',
                                hintText: '订阅依赖、过滤说明或迁移信息',
                              ),
                            ),
                            if (selectedType != 'single-file') ...[
                              const SizedBox(height: 16),
                              Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          '覆盖本地修改',
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          forceOverwrite
                                              ? '拉取时覆盖本地修改'
                                              : '拉取时保留本地修改的文件',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: Colors.grey,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Switch(
                                    value: forceOverwrite,
                                    onChanged: (v) =>
                                        setSheetState(() => forceOverwrite = v),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: hookScriptC,
                                maxLines: 3,
                                decoration: const InputDecoration(
                                  labelText: '拉取后钩子',
                                  hintText: '拉取成功后执行的 Shell 命令',
                                  alignLabelWithHint: true,
                                ),
                              ),
                              const SizedBox(height: 8),
                              const _HookScriptHint(),
                              _SubscriptionAuthFields(
                                state: auth,
                                sshKeys: _sshKeys,
                                sshKeyLoadError: _sshKeyLoadError,
                                onChanged: () => setSheetState(() {}),
                              ),
                            ],
                            const SizedBox(height: 16),
                          ],
                        ),
                      ),
                    ),
                    // 固定底部按钮
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                      child: Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => Navigator.of(ctx).pop(),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(0, 44),
                              ),
                              child: const Text('关闭'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton(
                              onPressed: () async {
                                final authError = auth.validate(selectedType);
                                if (authError != null) {
                                  rootMessenger.showSnackBar(
                                    SnackBar(content: Text(authError)),
                                  );
                                  return;
                                }
                                try {
                                  await ref
                                      .read(subscriptionListProvider.notifier)
                                      .update(sub.id, {
                                        'name': nameC.text.trim(),
                                        'type': selectedType,
                                        'url': urlC.text.trim(),
                                        'branch': branchC.text.trim(),
                                        'sub_path': subPathC.text.trim(),
                                        'schedule': scheduleC.text.trim(),
                                        'save_dir': saveDirC.text.trim(),
                                        'alias': aliasC.text.trim(),
                                        'whitelist': whitelistC.text.trim(),
                                        'blacklist': blacklistC.text.trim(),
                                        'depend_on': dependOnC.text.trim(),
                                        'hook_script': hookScriptC.text.trim(),
                                        'force_overwrite': forceOverwrite,
                                        ...auth.payload(selectedType),
                                      });
                                  if (!mounted) {
                                    return;
                                  }
                                  navigator.pop();
                                  rootMessenger.showSnackBar(
                                    const SnackBar(content: Text('订阅已保存')),
                                  );
                                } catch (error) {
                                  if (!mounted) {
                                    return;
                                  }
                                  rootMessenger.showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        _extractRequestErrorMessage(
                                          error,
                                          '保存订阅失败',
                                        ),
                                      ),
                                    ),
                                  );
                                }
                              },
                              style: FilledButton.styleFrom(
                                minimumSize: const Size(0, 44),
                              ),
                              child: const Text('保存'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(auth.dispose);
  }
}

// ── 鉴权表单 ──

/// 「仓库鉴权」那一段的可变状态。新建 / 编辑两个弹窗共用一份。
class _AuthFormState {
  _AuthFormState.create()
    : type = SubscriptionAuthType.none,
      sshKeyId = null,
      usernameC = TextEditingController(),
      tokenC = TextEditingController(),
      hasExistingToken = false,
      isEdit = false;

  _AuthFormState.edit(Subscription sub)
    : type = parseSubscriptionAuthType(sub.authType),
      sshKeyId = sub.sshKeyId,
      usernameC = TextEditingController(text: sub.authUsername),
      // token 框永远从空开始：面板不下发明文（AuthToken 的 json tag 是 `-`），
      // 预填一串假的星号只会让用户以为自己看到了真 token。
      tokenC = TextEditingController(),
      hasExistingToken = sub.hasAuthToken,
      isEdit = true;

  SubscriptionAuthType type;
  int? sshKeyId;
  final TextEditingController usernameC;
  final TextEditingController tokenC;
  final bool hasExistingToken;
  final bool isEdit;

  void dispose() {
    usernameC.dispose();
    tokenC.dispose();
  }

  String? validate(String subType) => validateSubscriptionAuth(
    subType: subType,
    authType: type,
    sshKeyId: sshKeyId,
    authToken: tokenC.text,
    isEdit: isEdit,
    hasExistingToken: hasExistingToken,
  );

  Map<String, dynamic> payload(String subType) => buildSubscriptionAuthPayload(
    subType: subType,
    authType: type,
    sshKeyId: sshKeyId,
    authUsername: usernameC.text,
    authToken: tokenC.text,
  );
}

/// 订阅表单里的「仓库鉴权」区块。
///
/// 与面板 Web（views/subscriptions/index.vue:1325-1417）字段一致：
/// 三选一的方式 + SSH 密钥下拉 + Token 用户名 + Token。
/// 只对 Git 仓库显示 —— 单文件订阅走的是直链下载，面板保存时也会把这几个字段清掉。
class _SubscriptionAuthFields extends StatelessWidget {
  const _SubscriptionAuthFields({
    required this.state,
    required this.sshKeys,
    required this.sshKeyLoadError,
    required this.onChanged,
  });

  final _AuthFormState state;
  final List<SshKeyOption> sshKeys;
  final String? sshKeyLoadError;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    // 面板给的 ssh_key_id 可能指向一把当前用户看不到（非管理员）或已被删除的
    // 密钥。这时候不能把下拉的值强行落到列表第一项上 —— 那等于替用户换了一把
    // 密钥。值置空、另给一行说明，让用户自己决定重选还是保持不动。
    final selectableId = sshKeys.any((key) => key.id == state.sshKeyId)
        ? state.sshKeyId
        : null;
    final hasDanglingKey = state.sshKeyId != null && selectableId == null;
    final keyError = sshKeyLoadError;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        const Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '仓库鉴权',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in SubscriptionAuthType.values)
                ChoiceChip(
                  label: Text(
                    subscriptionAuthTypeLabel(option),
                    style: const TextStyle(fontSize: 12),
                  ),
                  selected: state.type == option,
                  onSelected: (_) {
                    state.type = option;
                    onChanged();
                  },
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '私有仓库推荐使用权限更可控的 Token；公开仓库留空即可。',
            style: TextStyle(fontSize: 11, color: context.surfaces.mutedText),
          ),
        ),
        if (state.type == SubscriptionAuthType.ssh) ...[
          const SizedBox(height: 12),
          if (keyError != null)
            AppNotice(color: AppColors.warning, text: keyError)
          else if (sshKeys.isEmpty)
            const AppNotice(
              color: AppColors.warning,
              text: '面板里还没有 SSH 密钥。请先在面板 Web 端的订阅页添加，或改用 Access Token。',
            )
          else
            DropdownButtonFormField<int?>(
              initialValue: selectableId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'SSH 密钥'),
              items: [
                const DropdownMenuItem<int?>(value: null, child: Text('未选择')),
                ...sshKeys.map(
                  (key) => DropdownMenuItem<int?>(
                    value: key.id,
                    child: Text(key.name, overflow: TextOverflow.ellipsis),
                  ),
                ),
              ],
              onChanged: (value) {
                state.sshKeyId = value;
                onChanged();
              },
            ),
          if (hasDanglingKey) ...[
            const SizedBox(height: 6),
            Text(
              '当前订阅绑定的密钥 #${state.sshKeyId} 不在可选列表里（可能已被删除，或你没有查看权限）。',
              style: TextStyle(fontSize: 11, color: context.surfaces.mutedText),
            ),
          ],
        ],
        if (state.type == SubscriptionAuthType.token) ...[
          const SizedBox(height: 12),
          TextField(
            controller: state.usernameC,
            decoration: const InputDecoration(
              labelText: '鉴权用户名',
              hintText: '留空默认 x-access-token（GitHub 适用）',
              helperText: 'GitHub 留空；Gitee 填用户名；GitLab 可填 oauth2 或 private-token。',
              helperMaxLines: 2,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: state.tokenC,
            obscureText: true,
            decoration: InputDecoration(
              labelText: 'Access Token',
              hintText: state.hasExistingToken
                  ? '留空则保持当前已保存的 Token'
                  : '粘贴 Git 平台访问令牌',
              helperText: state.hasExistingToken
                  ? '面板不会回传已保存的 Token。不需要更换就保持留空。'
                  : '建议使用仅有仓库读取权限的 Token。',
              helperMaxLines: 2,
            ),
          ),
        ],
      ],
    );
  }
}

// ── Card ──

class _SubCard extends StatelessWidget {
  final Subscription sub;
  final bool isLight;
  final VoidCallback onPull;
  final VoidCallback onStopPull;
  final VoidCallback onLogs;
  final VoidCallback onToggle;
  final VoidCallback onDelete;
  final VoidCallback onEdit;

  const _SubCard({
    required this.sub,
    required this.isLight,
    required this.onPull,
    required this.onStopPull,
    required this.onLogs,
    required this.onToggle,
    required this.onDelete,
    required this.onEdit,
  });

  // 拉取中=蓝(info)、已启用=绿(success)、已禁用=灰。原先「已启用」是
  // primary 淡底 + 写死的 Emerald 深绿字，主色换蓝后互相打架。
  Color _statusBg() {
    if (sub.isPulling) {
      return isLight ? AppColors.infoLight : AppColors.info.withAlpha(25);
    }
    if (sub.enabled) {
      return isLight ? AppColors.successLight : AppColors.success.withAlpha(25);
    }
    return isLight ? AppColors.slate100 : AppColors.slate800;
  }

  Color _statusFg() {
    if (sub.isPulling) {
      return isLight ? AppColors.infoDark : AppColors.info;
    }
    if (sub.enabled) {
      return isLight ? AppColors.successDark : AppColors.success;
    }
    return AppColors.neutral;
  }

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onEdit,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        children: [
          // Top row: name + status
          Row(
            children: [
              // 卡片圆点：「已启用」= success 绿。第 0 期已经把同一张卡右侧的
              // 状态徽章（_statusBg/_statusFg）改成绿了，圆点却还留着蓝，
              // 同一张卡里两个元件对「已启用」各说各话，这里补齐。
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: sub.enabled ? AppColors.success : AppColors.slate300,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  sub.name,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _statusBg(),
                  // 10px 微徽章。原值 4，全库这一类统一走 sm。
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Text(
                  sub.statusText,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: _statusFg(),
                  ),
                ),
              ),
            ],
          ),
          // URL
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Text(
                  '仓库：',
                  style: TextStyle(
                    fontSize: 12,
                    color: isLight ? AppColors.slate500 : AppColors.slate400,
                  ),
                ),
                Expanded(
                  child: Text(
                    sub.url.isNotEmpty ? sub.url : sub.typeLabel,
                    style: TextStyle(
                      fontSize: 12,
                      color: isLight ? AppColors.slate500 : AppColors.slate400,
                      fontFamily: 'monospace',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),

          // Bottom: last pull + actions
          Container(
            padding: const EdgeInsets.only(top: 6),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: isLight
                      ? AppColors.slate100
                      : AppColors.slate800.withAlpha(120),
                ),
              ),
            ),
            child: Row(
              children: [
                Text(
                  sub.lastPullAt != null
                      ? '上次拉取：${formatTimeCn(sub.lastPullAt, short: true)}'
                      : '尚未拉取',
                  style: TextStyle(
                    fontSize: 12,
                    color: isLight ? AppColors.slate500 : AppColors.slate400,
                  ),
                ),
                const Spacer(),
                _SmallIconBtn(
                  icon: sub.isPulling ? Icons.stop : Icons.sync,
                  onTap: sub.isPulling ? onStopPull : onPull,
                  color: sub.isPulling ? AppColors.red500 : AppColors.primary,
                ),
                const SizedBox(width: 4),
                _SmallIconBtn(
                  icon: Icons.receipt_long_outlined,
                  onTap: onLogs,
                  color: AppColors.blue500,
                ),
                const SizedBox(width: 4),
                _SmallIconBtn(
                  icon: sub.enabled ? Icons.pause : Icons.play_arrow,
                  onTap: onToggle,
                ),
                const SizedBox(width: 4),
                _SmallIconBtn(
                  icon: Icons.delete_outline,
                  onTap: onDelete,
                  color: AppColors.red500,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SmallIconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color? color;

  const _SmallIconBtn({required this.icon, required this.onTap, this.color});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(icon, size: 18, color: color ?? AppColors.slate400),
      ),
    );
  }
}

class _HookScriptHint extends StatelessWidget {
  const _HookScriptHint();

  @override
  Widget build(BuildContext context) {
    return const AppNotice(
      color: AppColors.blue500,
      text: '钩子会在订阅拉取成功后执行，适合安装依赖、移动文件或触发通知；这里填写的是 Shell 命令，留空则不执行。',
    );
  }
}

class SubscriptionLogsPage extends ConsumerStatefulWidget {
  final int subscriptionId;
  final String? subscriptionName;

  const SubscriptionLogsPage({
    super.key,
    required this.subscriptionId,
    this.subscriptionName,
  });

  @override
  ConsumerState<SubscriptionLogsPage> createState() =>
      _SubscriptionLogsPageState();
}

class _SubscriptionLogsPageState extends ConsumerState<SubscriptionLogsPage> {
  static const int _pageSize = 20;

  List<Map<String, dynamic>> _logs = [];
  bool _loading = true;
  int _page = 1;
  int _total = 0;
  Color? _logBackgroundColor;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      _logBackgroundColor = await loadPanelLogBackgroundColor();
      await _load();
    });
  }

  Future<void> _load({int? page}) async {
    final targetPage = page ?? _page;
    setState(() => _loading = true);
    try {
      final response = await DioClient.instance.dio.get(
        ApiEndpoints.subscriptionLogs(widget.subscriptionId),
        queryParameters: {'page': targetPage, 'page_size': _pageSize},
      );
      final paginated = extractPaginated(response.data);
      if (!mounted) {
        return;
      }
      setState(() {
        _logs = paginated.items;
        _total = paginated.total;
        _page = targetPage;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _loading = false);
    }
  }

  void _showLogDetail(Map<String, dynamic> log) {
    final logTheme = resolveLogSurfaceTheme(_logBackgroundColor);
    final borderColor = logTheme.brightness == Brightness.dark
        ? AppColors.slate700
        : AppColors.slate200;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.75,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '日志详情',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: AppCard(
                    padding: const EdgeInsets.all(14),
                    radius: AppRadius.md,
                    // 日志底色跟随用户设置的日志主题，与页面明暗无关，
                    // 必须显式传入，不能落到 AppCard 的默认卡片底色。
                    color: logTheme.background,
                    borderColor: borderColor,
                    child: SingleChildScrollView(
                      child: SelectionArea(
                        child: RichText(
                          text: AnsiTextParser.buildTextSpan(
                            log['content']?.toString().trim().isNotEmpty == true
                                ? log['content'].toString()
                                : '(无日志内容)',
                            baseStyle: TextStyle(
                              color: logTheme.foreground,
                              fontFamily: 'monospace',
                              fontSize: 12,
                              height: 1.6,
                            ),
                            brightness: logTheme.brightness,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final totalPages = ((_total + _pageSize - 1) ~/ _pageSize).clamp(
      1,
      1 << 20,
    );
    final title = (widget.subscriptionName?.trim().isNotEmpty ?? false)
        ? '${widget.subscriptionName} 拉取日志'
        : '拉取日志';

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              color: AppColors.primary,
              onRefresh: () => _load(page: _page),
              child: _loading && _logs.isEmpty
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
                      children: const [
                        SizedBox(height: 100),
                        Center(
                          child: Text(
                            '暂无拉取日志',
                            style: TextStyle(color: AppColors.slate400),
                          ),
                        ),
                      ],
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                      itemCount: _logs.length,
                      itemBuilder: (_, index) {
                        final log = _logs[index];
                        // 面板 SubLog.Status 目前只有 0 成功 / 1 失败
                        // （server/service/subscription.go:95-101 就是这么算的）。
                        // 但 Web 端注释里已经在说「不给 SubLog.Status 加『已终止』，
                        // 前端自己打本地标记」（views/subscriptions/index.vue:740），
                        // 说明第三个值是有可能出现的。所以这里不写
                        // `status == 0 ? 成功 : 失败` —— 那会把任何新值一律说成失败。
                        final logStatus = (log['status'] as num?)?.toInt();
                        final success = logStatus == 0;
                        final failed = logStatus == 1;
                        final time = DateTime.tryParse(
                          log['created_at']?.toString() ?? '',
                        );
                        final preview = _subscriptionLogPreview(log);

                        return AppCard(
                          onTap: () => _showLogDetail(log),
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: success
                                          ? AppColors.success.withAlpha(20)
                                          : failed
                                          ? AppColors.danger.withAlpha(15)
                                          : AppColors.neutral.withAlpha(20),
                                      borderRadius: BorderRadius.circular(
                                        AppRadius.pill,
                                      ),
                                    ),
                                    child: Text(
                                      success
                                          ? '成功'
                                          : failed
                                          ? '失败'
                                          : '未知(${logStatus ?? '-'})',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        // 底色是同色淡底：success 2.13:1、
                                        // danger 3.43:1，绿的那个尤其糊。
                                        color: context.surfaces.tintFg(
                                          success
                                              ? AppColors.success
                                              : failed
                                              ? AppColors.danger
                                              : AppColors.neutral,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const Spacer(),
                                  Text(
                                    // 原写法是裸秒，且拿不到 duration 时假造一个
                                    // 「0.0s」。而 `0s` 现在是有确切含义的（任务刚
                                    // 开始跑，服务端把耗时重置为 0），拿它兜底等于
                                    // 把「不知道」说成「跑了 0 秒」。
                                    formatDurationSeconds(
                                      log['duration'] as num?,
                                    ),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: isLight
                                          ? AppColors.slate500
                                          : AppColors.slate400,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Text(
                                preview,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                time != null ? formatTimeCn(time) : '',
                                style: TextStyle(
                                  fontSize: 11,
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
          if (_total > _pageSize)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _page > 1
                            ? () => _load(page: _page - 1)
                            : null,
                        child: const Text('上一页'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '第 $_page / $totalPages 页',
                      style: TextStyle(
                        fontSize: 12,
                        color: isLight
                            ? AppColors.slate500
                            : AppColors.slate400,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: _page < totalPages
                            ? () => _load(page: _page + 1)
                            : null,
                        child: const Text('下一页'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Pull Stream Page ──

class SubscriptionPullStreamPage extends ConsumerStatefulWidget {
  final int subscriptionId;
  const SubscriptionPullStreamPage({super.key, required this.subscriptionId});

  @override
  ConsumerState<SubscriptionPullStreamPage> createState() =>
      _SubscriptionPullStreamPageState();
}

class _SubscriptionPullStreamPageState
    extends ConsumerState<SubscriptionPullStreamPage> {
  final _sseClient = SseClient();
  final _logs = <String>[];
  final _scrollController = ScrollController();
  bool _done = false;
  String? _statusMessage;
  Color? _logBackgroundColor;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      final color = await loadPanelLogBackgroundColor();
      if (mounted) {
        setState(() => _logBackgroundColor = color);
      }
    });
    _connectStream();
  }

  void _connectStream() {
    _sseClient.close();
    _sseClient.connect(
      path: ApiEndpoints.subscriptionPullStream(widget.subscriptionId),
      autoReconnect: true,
      onEvent: (event) {
        if (!mounted) return;
        setState(() {
          if (event.event == 'done' &&
              event.data == 'not_running' &&
              _logs.isEmpty) {
            _statusMessage = '当前没有正在运行的拉取任务';
          } else {
            _logs.add(event.data);
          }
          if (event.event == 'done' && event.data != 'reconnect') {
            _done = true;
          }
        });
        Future.delayed(const Duration(milliseconds: 50), () {
          if (_scrollController.hasClients) {
            _scrollController.jumpTo(
              _scrollController.position.maxScrollExtent,
            );
          }
        });
      },
      onDone: () {
        if (mounted) setState(() => _done = true);
      },
      onError: (_) {
        if (mounted) {
          setState(() {
            _done = true;
            _statusMessage ??= '拉取日志连接已断开';
          });
        }
      },
    );
  }

  @override
  void dispose() {
    _sseClient.close();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final logTheme = resolveLogSurfaceTheme(_logBackgroundColor);
    final doneBannerBackground = logTheme.brightness == Brightness.dark
        ? AppColors.slate800
        : AppColors.slate100;

    return Scaffold(
      backgroundColor: logTheme.background,
      appBar: AppBar(
        title: const Text('拉取日志'),
        backgroundColor: logTheme.background,
        foregroundColor: logTheme.foreground,
      ),
      body: Container(
        color: logTheme.background,
        child: Column(
          children: [
            Expanded(
              child: _logs.isEmpty && _statusMessage != null
                  ? Center(
                      child: Text(
                        _statusMessage!,
                        style: TextStyle(color: logTheme.mutedForeground),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(12),
                      itemCount: _logs.length,
                      itemBuilder: (_, i) => SelectionArea(
                        child: RichText(
                          text: AnsiTextParser.buildTextSpan(
                            _logs[i],
                            baseStyle: TextStyle(
                              color: logTheme.foreground,
                              fontFamily: 'monospace',
                              fontSize: 12,
                              height: 1.6,
                            ),
                            brightness: logTheme.brightness,
                          ),
                        ),
                      ),
                    ),
            ),
            if (_done)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                color: doneBannerBackground,
                child: Text(
                  '拉取完成',
                  textAlign: TextAlign.center,
                  // 「完成」是结果成功，不是「进行中」，所以走 success 而不是 primary。
                  // 浅色分支取 successDark：这条 banner 压在 slate100 上，
                  // 满强度 success 只有 2.1:1，加深一档才看得清。
                  // 深色分支沿用日志前景色，不动。
                  style: TextStyle(
                    color: logTheme.brightness == Brightness.dark
                        ? logTheme.foreground
                        : AppColors.successDark,
                    fontSize: 13,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _extractRequestErrorMessage(dynamic error, String fallback) =>
    extractErrorMessage(error, fallback);

String _subscriptionLogPreview(Map<String, dynamic> log) {
  final content = log['content']?.toString() ?? '';
  for (final line in content.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) {
      return trimmed;
    }
  }
  return '(无日志内容)';
}
