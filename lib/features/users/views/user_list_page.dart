import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/utils/time_utils.dart';
import '../../../shared/widgets/app_circle_add_button.dart';
import '../../../shared/widgets/app_back_button.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/app_snack.dart';
import '../../../shared/widgets/app_state_views.dart';

// ── Provider ──

final userListProvider = StateNotifierProvider<UserListNotifier, UserListState>(
  (ref) {
    return UserListNotifier();
  },
);

class _User {
  final int id;
  final String username;
  final String role;
  final bool enabled;
  final DateTime? lastLoginAt;
  final DateTime createdAt;

  const _User({
    required this.id,
    required this.username,
    required this.role,
    this.enabled = true,
    this.lastLoginAt,
    required this.createdAt,
  });

  factory _User.fromJson(Map<String, dynamic> json) {
    return _User(
      id: (json['id'] as num?)?.toInt() ?? 0,
      username: json['username']?.toString() ?? '',
      role: json['role']?.toString() ?? 'viewer',
      enabled: json['enabled'] != false,
      lastLoginAt: json['last_login_at'] is String
          ? DateTime.tryParse(json['last_login_at'])
          : null,
      createdAt: json['created_at'] is String
          ? DateTime.tryParse(json['created_at']!) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  bool get isAdmin => role == 'admin';

  String get roleLabel {
    switch (role) {
      case 'admin':
        return '管理员';
      case 'operator':
        return '操作员';
      case 'viewer':
        return '观察者';
      default:
        return role;
    }
  }
}

class UserListState {
  final List<_User> items;
  final bool loading;
  final String? error;

  const UserListState({
    this.items = const [],
    this.loading = false,
    this.error,
  });

  /// [error] 刻意不写 `error ?? this.error`：语义是「不传即清空」，
  /// 否则一次失败之后的所有 `copyWith` 都会把旧错误粘住，重试成功了还在报错。
  UserListState copyWith({List<_User>? items, bool? loading, String? error}) {
    return UserListState(
      items: items ?? this.items,
      loading: loading ?? this.loading,
      error: error,
    );
  }
}

class UserListNotifier extends StateNotifier<UserListState> {
  /// [dio] **仅供测试注入**，生产路径不传，仍然走 `DioClient` 单例。
  /// 单例的 baseUrl 会随切换面板被改写，所以这里不在构造时把它存下来。
  UserListNotifier({Dio? dio})
    : _injectedDio = dio,
      super(const UserListState());

  final Dio? _injectedDio;

  Dio get _dio => _injectedDio ?? DioClient.instance.dio;

  Future<void> load() async {
    state = state.copyWith(loading: true, error: null);
    try {
      final resp = await _dio.get(ApiEndpoints.users);
      final data = extractData(resp.data);
      List<_User> items = [];
      if (data is List) {
        items = data
            .whereType<Map<String, dynamic>>()
            .map((e) => _User.fromJson(e))
            .toList();
      }
      state = state.copyWith(items: items, loading: false);
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: extractListErrorMessage(e, '加载用户失败'),
      );
    }
  }

  Future<void> create(String username, String password, String role) async {
    await _dio.post(
      ApiEndpoints.users,
      data: {'username': username, 'password': password, 'role': role},
    );
    await load();
  }

  Future<void> update(int id, {String? role, bool? enabled}) async {
    final data = <String, dynamic>{};
    if (role != null) data['role'] = role;
    if (enabled != null) data['enabled'] = enabled;
    await _dio.put(ApiEndpoints.userById(id), data: data);
    await load();
  }

  Future<void> delete(int id) async {
    await _dio.delete(ApiEndpoints.userById(id));
    await load();
  }

  Future<void> resetPassword(int id, String password) async {
    await _dio.put(
      ApiEndpoints.userResetPassword(id),
      data: {'password': password},
    );
  }
}

// ── Page ──

class UserListPage extends ConsumerStatefulWidget {
  const UserListPage({super.key});

  @override
  ConsumerState<UserListPage> createState() => _UserListPageState();
}

class _UserListPageState extends ConsumerState<UserListPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(userListProvider.notifier).load());
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(userListProvider);
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;
    final currentUsername = ref.watch(authProvider).user?.username;

    return Scaffold(
      body: Padding(
        padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 12),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  const AppBackButton(),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '用户管理',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  AppCircleAddButton(onTap: () => _showCreateDialog()),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: RefreshIndicator(
                color: AppColors.primary,
                onRefresh: () => ref.read(userListProvider.notifier).load(),
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
                    // 拿不到数据和真的没有用户是两回事，必须先判 error，
                    // 否则面板离线时页面只会显示一句「暂无用户」。
                    : state.error != null && state.items.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          AppErrorView(
                            title: '用户加载失败',
                            message: state.error!,
                            onRetry: () =>
                                ref.read(userListProvider.notifier).load(),
                          ),
                        ],
                      )
                    : state.items.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          const SizedBox(height: 100),
                          Icon(
                            Icons.people_outline,
                            size: 56,
                            color: AppColors.slate400.withAlpha(120),
                          ),
                          const SizedBox(height: 12),
                          const Center(
                            child: Text(
                              '暂无用户',
                              style: TextStyle(color: AppColors.slate400),
                            ),
                          ),
                        ],
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                        itemCount: state.items.length,
                        itemBuilder: (_, i) => _UserCard(
                          user: state.items[i],
                          isLight: isLight,
                          currentUsername: currentUsername,
                          ref: ref,
                          context: context,
                          showResetPw: _showResetPasswordDialog,
                          showRolePicker: _showRolePicker,
                          showDelete: _confirmDelete,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showRolePicker(_User user) async {
    String role = user.role;
    final changed = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('修改 ${user.username} 的角色'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('请选择新的用户角色'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: ['admin', 'operator', 'viewer']
                    .map(
                      (item) => ChoiceChip(
                        label: Text(
                          item == 'admin'
                              ? '管理员'
                              : item == 'operator'
                              ? '操作员'
                              : '观察者',
                        ),
                        selected: role == item,
                        onSelected: (_) => setDialogState(() => role = item),
                      ),
                    )
                    .toList(),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogCtx, role),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );

    if (changed == null || changed == user.role) {
      return;
    }

    // 原来这里既没有 catch，也无条件弹「角色更新成功」：
    // 面板返回 4xx 时用户会看到一个假的成功提示。收紧 validateStatus 后必须自己兜。
    try {
      await ref.read(userListProvider.notifier).update(user.id, role: changed);
      if (!mounted) {
        return;
      }
      AppSnack.success(context, '角色更新成功');
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppSnack.error(context, extractErrorMessage(error, '角色更新失败'));
    }
  }

  void _showCreateDialog() {
    final usernameC = TextEditingController();
    final passwordC = TextEditingController();
    String role = 'operator';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useRootNavigator: true,
      builder: (ctx) {
        final navigator = Navigator.of(ctx);
        return StatefulBuilder(
          builder: (ctx, setSheetState) => Padding(
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
                  '新建用户',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: usernameC,
                  decoration: const InputDecoration(labelText: '用户名'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: passwordC,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '密码'),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text('角色  ', style: TextStyle(fontSize: 13)),
                    ...['admin', 'operator', 'viewer'].map(
                      (r) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(
                            r == 'admin'
                                ? '管理员'
                                : r == 'operator'
                                ? '操作员'
                                : '观察者',
                            style: const TextStyle(fontSize: 12),
                          ),
                          selected: role == r,
                          onSelected: (_) => setSheetState(() => role = r),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                SizedBox(
                  height: 44,
                  child: FilledButton(
                    onPressed: () async {
                      if (usernameC.text.trim().isEmpty ||
                          passwordC.text.isEmpty) {
                        return;
                      }
                      try {
                        await ref
                            .read(userListProvider.notifier)
                            .create(
                              usernameC.text.trim(),
                              passwordC.text,
                              role,
                            );
                        if (!mounted) {
                          return;
                        }
                        navigator.pop();
                        // 这里用页面级 context 而不是 sheet 的 ctx：sheet 刚被 pop，
                        // ctx 已失效。原先提前取 rootMessenger 就是为了绕开这点，
                        // 换成 AppSnack 后由上面的 mounted 判断承担同样的作用。
                        AppSnack.success(context, '用户已创建');
                      } catch (error) {
                        if (!mounted) {
                          return;
                        }
                        AppSnack.error(
                          context,
                          extractErrorMessage(error, '创建用户失败'),
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
          ),
        );
      },
    );
  }

  void _showResetPasswordDialog(_User user) {
    final passwordC = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogCtx) {
        return AlertDialog(
          title: Text('重置 ${user.username} 的密码'),
          content: TextField(
            controller: passwordC,
            obscureText: true,
            decoration: const InputDecoration(labelText: '新密码'),
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
                          await ref
                              .read(userListProvider.notifier)
                              .resetPassword(user.id, passwordC.text);
                          if (!mounted) {
                            return;
                          }
                          Navigator.of(dialogCtx).pop();
                          // 同上：弹窗已 pop，dialogCtx 失效，改用页面级 context，
                          // 由前面的 mounted 判断守住 async gap。
                          AppSnack.success(context, '密码已重置');
                        } catch (error) {
                          if (!mounted) {
                            return;
                          }
                          AppSnack.error(
                            context,
                            extractErrorMessage(error, '重置密码失败'),
                          );
                        }
                      },
                      child: const Text('确认'),
                    ),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Future<void> _confirmDelete(_User user) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('删除用户'),
        content: Text('确定要删除「${user.username}」吗？'),
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
        await ref.read(userListProvider.notifier).delete(user.id);
        if (!mounted) {
          return;
        }
        AppSnack.success(context, '用户已删除');
      } catch (error) {
        if (!mounted) {
          return;
        }
        AppSnack.error(context, extractErrorMessage(error, '删除用户失败'));
      }
    }
  }
}

class _UserCard extends StatelessWidget {
  final _User user;
  final bool isLight;
  final String? currentUsername;
  final WidgetRef ref;
  final BuildContext context;
  final void Function(_User) showResetPw;
  final Future<void> Function(_User) showRolePicker;
  final Future<void> Function(_User) showDelete;

  const _UserCard({
    required this.user,
    required this.isLight,
    required this.currentUsername,
    required this.ref,
    required this.context,
    required this.showResetPw,
    required this.showRolePicker,
    required this.showDelete,
  });

  // 形参不叫 context，是因为本类有一个同名字段（页面级 context）要留给
  // 下面的 mounted 判断和 SnackBar 用。
  @override
  Widget build(BuildContext ctx) {
    final roleColor = user.role == 'admin'
        ? AppColors.red500
        : user.role == 'operator'
        ? AppColors.amber500
        : AppColors.primary;
    // 首字母头像和角色徽章都压在 roleColor 的 alpha=25 淡底上，
    // 管理员红 3.43:1、操作员琥珀 2.04:1、普通用户蓝 2.60:1。
    final roleFg = AppSurfaces.of(ctx).tintFg(roleColor);
    final isSelf = currentUsername == user.username;

    return AppCard(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: roleColor.withAlpha(25),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                user.username.substring(0, 1).toUpperCase(),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: roleFg,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      user.username,
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
                        color: roleColor.withAlpha(25),
                        // 10px 微徽章。原值 4，全库这一类统一走 sm。
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                      child: Text(
                        user.roleLabel,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: roleFg,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  user.enabled ? '已启用' : '已禁用',
                  style: TextStyle(
                    fontSize: 12,
                    // 「已启用」全库统一走 success 绿，与任务/订阅/依赖列表一致。
                    color: user.enabled
                        ? AppColors.success
                        : AppColors.slate400,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '最后登录: ${formatTimeCn(user.lastLoginAt)}',
                  style: TextStyle(
                    fontSize: 11,
                    color: isLight ? AppColors.slate500 : AppColors.slate400,
                  ),
                ),
                Text(
                  '创建时间: ${formatTimeCn(user.createdAt)}',
                  style: TextStyle(
                    fontSize: 11,
                    color: isLight ? AppColors.slate500 : AppColors.slate400,
                  ),
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
              if (!isSelf)
                const PopupMenuItem(value: 'role', child: Text('修改角色')),
              if (!isSelf)
                PopupMenuItem(
                  value: 'toggle',
                  child: Text(user.enabled ? '禁用' : '启用'),
                ),
              const PopupMenuItem(value: 'reset_pw', child: Text('重置密码')),
              if (!isSelf)
                const PopupMenuItem(
                  value: 'delete',
                  child: Text('删除', style: TextStyle(color: AppColors.red500)),
                ),
            ],
            onSelected: (v) async {
              switch (v) {
                case 'role':
                  await showRolePicker(user);
                  break;
                case 'toggle':
                  try {
                    await ref
                        .read(userListProvider.notifier)
                        .update(user.id, enabled: !user.enabled);
                    if (!context.mounted) {
                      return;
                    }
                    AppSnack.success(
                      context,
                      user.enabled ? '用户已禁用' : '用户已启用',
                    );
                  } catch (error) {
                    if (!context.mounted) {
                      return;
                    }
                    AppSnack.error(
                      context,
                      extractErrorMessage(
                        error,
                        user.enabled ? '禁用用户失败' : '启用用户失败',
                      ),
                    );
                  }
                  break;
                case 'reset_pw':
                  showResetPw(user);
                  break;
                case 'delete':
                  await showDelete(user);
                  break;
              }
            },
          ),
        ],
      ),
    );
  }
}