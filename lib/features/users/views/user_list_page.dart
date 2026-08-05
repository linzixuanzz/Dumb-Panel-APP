import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/utils/time_utils.dart';

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

  const UserListState({this.items = const [], this.loading = false});

  UserListState copyWith({List<_User>? items, bool? loading}) {
    return UserListState(
      items: items ?? this.items,
      loading: loading ?? this.loading,
    );
  }
}

class UserListNotifier extends StateNotifier<UserListState> {
  UserListNotifier() : super(const UserListState());

  Future<void> load() async {
    state = state.copyWith(loading: true);
    try {
      final resp = await DioClient.instance.dio.get(ApiEndpoints.users);
      final data = extractData(resp.data);
      List<_User> items = [];
      if (data is List) {
        items = data
            .whereType<Map<String, dynamic>>()
            .map((e) => _User.fromJson(e))
            .toList();
      }
      state = state.copyWith(items: items, loading: false);
    } catch (_) {
      state = state.copyWith(loading: false);
    }
  }

  Future<void> create(String username, String password, String role) async {
    await DioClient.instance.dio.post(
      ApiEndpoints.users,
      data: {'username': username, 'password': password, 'role': role},
    );
    await load();
  }

  Future<void> update(int id, {String? role, bool? enabled}) async {
    final data = <String, dynamic>{};
    if (role != null) data['role'] = role;
    if (enabled != null) data['enabled'] = enabled;
    await DioClient.instance.dio.put(ApiEndpoints.userById(id), data: data);
    await load();
  }

  Future<void> delete(int id) async {
    await DioClient.instance.dio.delete(ApiEndpoints.userById(id));
    await load();
  }

  Future<void> resetPassword(int id, String password) async {
    await DioClient.instance.dio.put(
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
                  GestureDetector(
                    onTap: () => context.pop(),
                    child: const Icon(Icons.arrow_back_ios, size: 20),
                  ),
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
                  GestureDetector(
                    onTap: () => _showCreateDialog(),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary.withAlpha(80),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
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
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('角色更新成功')));
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(extractErrorMessage(error, '角色更新失败'))),
      );
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
        final rootMessenger = ScaffoldMessenger.of(context);
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
                        rootMessenger.showSnackBar(
                          const SnackBar(content: Text('用户已创建')),
                        );
                      } catch (error) {
                        if (!mounted) {
                          return;
                        }
                        rootMessenger.showSnackBar(
                          SnackBar(
                            content: Text(extractErrorMessage(error, '创建用户失败')),
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
        final rootMessenger = ScaffoldMessenger.of(context);
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
                          rootMessenger.showSnackBar(
                            const SnackBar(content: Text('密码已重置')),
                          );
                        } catch (error) {
                          if (!mounted) {
                            return;
                          }
                          rootMessenger.showSnackBar(
                            SnackBar(
                              content: Text(
                                extractErrorMessage(error, '重置密码失败'),
                              ),
                            ),
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('用户已删除')));
      } catch (error) {
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(extractErrorMessage(error, '删除用户失败'))),
        );
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

  @override
  Widget build(BuildContext _) {
    final roleColor = user.role == 'admin'
        ? AppColors.red500
        : user.role == 'operator'
        ? AppColors.amber500
        : AppColors.primary;
    final isSelf = currentUsername == user.username;

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
                  color: roleColor,
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
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        user.roleLabel,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: roleColor,
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
                    color: user.enabled
                        ? AppColors.primary
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
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(user.enabled ? '用户已禁用' : '用户已启用')),
                    );
                  } catch (error) {
                    if (!context.mounted) {
                      return;
                    }
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          extractErrorMessage(
                            error,
                            user.enabled ? '禁用用户失败' : '启用用户失败',
                          ),
                        ),
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
