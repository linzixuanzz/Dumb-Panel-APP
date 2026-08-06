import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/api_endpoints.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/models/notify_channel.dart';
import '../../../shared/utils/api_utils.dart';
import '../utils/channel_config.dart';

final notificationListProvider =
    StateNotifierProvider<NotificationListNotifier, NotificationListState>((
      ref,
    ) {
      return NotificationListNotifier();
    });

class NotificationTypeOption {
  final String type;
  final String name;

  const NotificationTypeOption({required this.type, required this.name});

  factory NotificationTypeOption.fromJson(Map<String, dynamic> json) {
    return NotificationTypeOption(
      type: json['type']?.toString() ?? '',
      name: json['name']?.toString() ?? json['type']?.toString() ?? '',
    );
  }
}

const List<NotificationTypeOption> _fallbackTypes = [
  NotificationTypeOption(type: 'webhook', name: 'Webhook'),
  NotificationTypeOption(type: 'email', name: '邮件'),
  NotificationTypeOption(type: 'telegram', name: 'Telegram'),
  NotificationTypeOption(type: 'dingtalk', name: '钉钉'),
  NotificationTypeOption(type: 'wecom', name: '企业微信机器人'),
  NotificationTypeOption(type: 'wecom_app', name: '企业微信应用'),
  NotificationTypeOption(type: 'bark', name: 'Bark'),
  NotificationTypeOption(type: 'pushplus', name: 'PushPlus'),
  NotificationTypeOption(type: 'serverchan', name: 'Server酱'),
  NotificationTypeOption(type: 'feishu', name: '飞书'),
  NotificationTypeOption(type: 'gotify', name: 'Gotify'),
  NotificationTypeOption(type: 'pushdeer', name: 'PushDeer'),
  NotificationTypeOption(type: 'pushme', name: 'PushMe'),
  NotificationTypeOption(type: 'chanify', name: 'Chanify'),
  NotificationTypeOption(type: 'igot', name: 'iGot'),
  NotificationTypeOption(type: 'qmsg', name: 'Qmsg'),
  NotificationTypeOption(type: 'pushover', name: 'Pushover'),
  NotificationTypeOption(type: 'discord', name: 'Discord'),
  NotificationTypeOption(type: 'slack', name: 'Slack'),
  NotificationTypeOption(type: 'ntfy', name: 'ntfy'),
  NotificationTypeOption(type: 'wxpusher', name: 'WxPusher'),
  NotificationTypeOption(type: 'custom', name: '自定义'),
];

class NotificationListState {
  final List<NotifyChannel> items;
  final bool loading;
  final List<NotificationTypeOption> types;

  const NotificationListState({
    this.items = const [],
    this.loading = false,
    this.types = const [],
  });

  NotificationListState copyWith({
    List<NotifyChannel>? items,
    bool? loading,
    List<NotificationTypeOption>? types,
  }) {
    return NotificationListState(
      items: items ?? this.items,
      loading: loading ?? this.loading,
      types: types ?? this.types,
    );
  }
}

class NotificationListNotifier extends StateNotifier<NotificationListState> {
  NotificationListNotifier() : super(const NotificationListState());

  Future<void> load() async {
    state = state.copyWith(loading: true);
    try {
      final dio = DioClient.instance.dio;
      final channelsFuture = dio.get(ApiEndpoints.notifications);
      // 渠道类型表是辅助数据，本来就有 _fallbackTypes 兜底。收紧 validateStatus 后
      // 它的 4xx 会让 Future.wait 整体失败，连已经取到的渠道列表都会被丢掉，
      // 页面反而变成「暂无通知渠道」。所以类型表单独降级，不参与主流程成败。
      final typesFuture = _fetchTypes();
      final channelsResponse = await channelsFuture;
      final types = await typesFuture;

      final paginated = extractPaginated(channelsResponse.data);
      final items = paginated.items
          .map((e) => NotifyChannel.fromJson(e))
          .toList();

      state = state.copyWith(
        items: items,
        loading: false,
        types: types.isNotEmpty ? types : _fallbackTypes,
      );
    } catch (_) {
      state = state.copyWith(
        loading: false,
        types: state.types.isNotEmpty ? state.types : _fallbackTypes,
      );
    }
  }

  /// 取渠道类型表。失败不抛，交给 [_fallbackTypes] 兜底。
  Future<List<NotificationTypeOption>> _fetchTypes() async {
    try {
      final response = await DioClient.instance.dio.get(
        ApiEndpoints.notificationTypes,
      );
      final typeData = extractData(response.data);
      if (typeData is! List) {
        return const [];
      }
      return typeData
          .whereType<Map>()
          .map(
            (e) =>
                NotificationTypeOption.fromJson(Map<String, dynamic>.from(e)),
          )
          .where((option) => option.type.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> toggle(int id, bool enabled) async {
    final dio = DioClient.instance.dio;
    if (enabled) {
      await dio.put(ApiEndpoints.notificationEnable(id));
    } else {
      await dio.put(ApiEndpoints.notificationDisable(id));
    }
    await load();
  }

  Future<void> test(int id) async {
    await DioClient.instance.dio.post(ApiEndpoints.notificationTest(id));
  }

  Future<void> delete(int id) async {
    await DioClient.instance.dio.delete(ApiEndpoints.notificationById(id));
    await load();
  }

  Future<void> create(Map<String, dynamic> data) async {
    await DioClient.instance.dio.post(ApiEndpoints.notifications, data: data);
    await load();
  }

  Future<void> update(int id, Map<String, dynamic> data) async {
    await DioClient.instance.dio.put(
      ApiEndpoints.notificationById(id),
      data: data,
    );
    await load();
  }
}

class NotificationListPage extends ConsumerStatefulWidget {
  const NotificationListPage({super.key});

  @override
  ConsumerState<NotificationListPage> createState() =>
      _NotificationListPageState();
}

class _NotificationListPageState extends ConsumerState<NotificationListPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(notificationListProvider.notifier).load());
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(notificationListProvider);
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;

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
                      '通知渠道',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => _showChannelDialog(),
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
                onRefresh: () =>
                    ref.read(notificationListProvider.notifier).load(),
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
                            Icons.notifications_off,
                            size: 56,
                            color: AppColors.slate400.withAlpha(120),
                          ),
                          const SizedBox(height: 12),
                          const Center(
                            child: Text(
                              '暂无通知渠道',
                              style: TextStyle(color: AppColors.slate400),
                            ),
                          ),
                        ],
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                        itemCount: state.items.length,
                        itemBuilder: (_, i) {
                          final channel = state.items[i];
                          return _ChannelCard(
                            channel: channel,
                            typeLabel: _typeName(state.types, channel.type),
                            isLight: isLight,
                            onEdit: () => _showChannelDialog(channel: channel),
                            onToggle: () => _doToggle(channel),
                            onTest: () => _doTest(channel),
                            onDelete: () => _confirmDelete(channel),
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
  Future<void> _doToggle(NotifyChannel channel) async {
    try {
      await ref
          .read(notificationListProvider.notifier)
          .toggle(channel.id, !channel.enabled);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_extractMessage(error, '修改渠道状态失败'))),
      );
    }
  }

  Future<void> _doTest(NotifyChannel channel) async {
    try {
      await ref.read(notificationListProvider.notifier).test(channel.id);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('测试通知已发送')));
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_extractMessage(error, '测试发送失败'))));
    }
  }

  Future<void> _confirmDelete(NotifyChannel channel) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除通知渠道'),
        content: Text('确定要删除「${channel.name}」吗？'),
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
        await ref.read(notificationListProvider.notifier).delete(channel.id);
      } catch (error) {
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_extractMessage(error, '删除失败'))));
      }
    }
  }

  static const _channelFieldMap =
      <String, List<({String key, String label, String hint, bool obscure})>>{
        'webhook': [
          (
            key: 'url',
            label: 'Webhook URL',
            hint: 'https://example.com/webhook',
            obscure: false,
          ),
        ],
        'email': [
          (
            key: 'smtp_host',
            label: 'SMTP 主机',
            hint: 'smtp.qq.com',
            obscure: false,
          ),
          (key: 'smtp_port', label: 'SMTP 端口', hint: '465', obscure: false),
          (
            key: 'smtp_user',
            label: '邮箱账号',
            hint: 'user@example.com',
            obscure: false,
          ),
          (
            key: 'smtp_pass',
            label: '邮箱密码/授权码',
            hint: 'SMTP 授权码',
            obscure: true,
          ),
          (key: 'to', label: '收件人', hint: '多个收件人用逗号分隔', obscure: false),
        ],
        'telegram': [
          (
            key: 'token',
            label: 'Bot Token',
            hint: '从 @BotFather 获取',
            obscure: false,
          ),
          (key: 'chat_id', label: 'Chat ID', hint: '聊天/群组 ID', obscure: false),
          (
            key: 'api_host',
            label: 'API 地址 (可选)',
            hint: '留空使用官方',
            obscure: false,
          ),
        ],
        'dingtalk': [
          (
            key: 'webhook',
            label: 'Webhook URL',
            hint: 'https://oapi.dingtalk.com/robot/send?access_token=xxx',
            obscure: false,
          ),
          (
            key: 'secret',
            label: '加签秘钥 (可选)',
            hint: 'SEC 开头的秘钥',
            obscure: false,
          ),
        ],
        'wecom': [
          (
            key: 'webhook',
            label: 'Webhook URL',
            hint: 'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxx',
            obscure: false,
          ),
        ],
        'wecom_app': [
          (key: 'corp_id', label: '企业 ID', hint: 'CorpID', obscure: false),
          (key: 'secret', label: '应用 Secret', hint: 'Secret', obscure: true),
          (key: 'agent_id', label: 'Agent ID', hint: 'AgentId', obscure: false),
          (
            key: 'to_user',
            label: '成员账号 (可选)',
            hint: '多个成员用 | 分隔，留空 @all',
            obscure: false,
          ),
        ],
        'bark': [
          (
            key: 'key',
            label: 'Device Key',
            hint: 'Bark App 中的 Key',
            obscure: false,
          ),
          (
            key: 'server',
            label: '服务器 (可选)',
            hint: '默认 https://api.day.app',
            obscure: false,
          ),
          (
            key: 'sound',
            label: '推送声音 (可选)',
            hint: '如 birdsong',
            obscure: false,
          ),
          (key: 'group', label: '推送分组 (可选)', hint: '消息分组名称', obscure: false),
        ],
        'pushplus': [
          (
            key: 'token',
            label: 'Token',
            hint: 'PushPlus 用户 Token',
            obscure: false,
          ),
          (
            key: 'topic',
            label: '群组编码 (可选)',
            hint: '一对多推送时的群组编码',
            obscure: false,
          ),
        ],
        'serverchan': [
          (key: 'key', label: 'SendKey', hint: 'SCT...', obscure: false),
        ],
        'feishu': [
          (
            key: 'webhook',
            label: 'Webhook URL',
            hint: 'https://open.feishu.cn/open-apis/bot/v2/hook/xxx',
            obscure: false,
          ),
          (key: 'secret', label: '加签秘钥 (可选)', hint: '签名校验秘钥', obscure: false),
        ],
        'gotify': [
          (
            key: 'server',
            label: '服务器地址',
            hint: 'https://gotify.example.com',
            obscure: false,
          ),
          (
            key: 'token',
            label: 'App Token',
            hint: 'Gotify 应用 Token',
            obscure: false,
          ),
        ],
        'pushdeer': [
          (
            key: 'key',
            label: 'PushKey',
            hint: 'PushDeer 的 PushKey',
            obscure: false,
          ),
          (
            key: 'server',
            label: '服务器 (可选)',
            hint: '默认 https://api2.pushdeer.com',
            obscure: false,
          ),
        ],
        'pushme': [
          (key: 'key', label: 'PushMe Key', hint: 'push_key', obscure: false),
        ],
        'chanify': [
          (
            key: 'token',
            label: 'Token',
            hint: 'Chanify 设备 Token',
            obscure: false,
          ),
        ],
        'igot': [
          (key: 'key', label: 'Key', hint: 'iGot 推送 Key', obscure: false),
        ],
        'qmsg': [
          (key: 'key', label: 'Qmsg Key', hint: 'Qmsg 酱的 Key', obscure: false),
          (key: 'qq', label: 'QQ 号/群号 (可选)', hint: '留空按默认配置发送', obscure: false),
        ],
        'pushover': [
          (
            key: 'token',
            label: 'API Token',
            hint: '应用 API Token',
            obscure: false,
          ),
          (key: 'user', label: 'User Key', hint: '用户 Key', obscure: false),
        ],
        'discord': [
          (
            key: 'webhook',
            label: 'Webhook URL',
            hint: 'https://discord.com/api/webhooks/...',
            obscure: false,
          ),
        ],
        'slack': [
          (
            key: 'webhook',
            label: 'Webhook URL',
            hint: 'https://hooks.slack.com/services/...',
            obscure: false,
          ),
        ],
        'ntfy': [
          (key: 'topic', label: 'Topic', hint: '订阅主题名称', obscure: false),
          (
            key: 'server',
            label: '服务器 (可选)',
            hint: '默认 https://ntfy.sh',
            obscure: false,
          ),
          (key: 'token', label: 'Token (可选)', hint: '访问令牌', obscure: false),
        ],
        'wxpusher': [
          (
            key: 'app_token',
            label: 'App Token',
            hint: 'WxPusher 的 appToken',
            obscure: false,
          ),
          (
            key: 'uids',
            label: 'UID 列表 (可选)',
            hint: '多个 UID 用逗号分隔',
            obscure: false,
          ),
          (
            key: 'topic_ids',
            label: 'Topic ID (可选)',
            hint: '多个 ID 用逗号分隔',
            obscure: false,
          ),
        ],
      };

  /// 没有字段表的渠道类型（如 custom）走「配置 JSON」编辑框，用这个 key 存控制器。
  static const String _rawConfigFieldKey = '__raw_json__';

  void _showChannelDialog({NotifyChannel? channel}) {
    final messenger = ScaffoldMessenger.of(context);
    final nameController = TextEditingController(text: channel?.name ?? '');
    final existingConfig = Map<String, dynamic>.from(channel?.config ?? {});
    final fieldControllers = <String, TextEditingController>{};
    bool smtpSsl = _configBool(existingConfig['smtp_ssl']);

    final availableTypes = ref.read(notificationListProvider).types.isNotEmpty
        ? ref.read(notificationListProvider).types
        : _fallbackTypes;
    String selectedType = channel?.type ?? availableTypes.first.type;
    if (!availableTypes.any((item) => item.type == selectedType)) {
      selectedType = availableTypes.first.type;
    }

    void disposeFieldControllers() {
      for (final c in fieldControllers.values) {
        c.dispose();
      }
      fieldControllers.clear();
    }

    /// 服务端已有的 config 只有在渠道类型没被改过时才对得上号。
    /// 用户在下拉里换了类型，旧配置的键就没有意义了，不能再带回服务端。
    bool keepsExistingConfig() =>
        channel != null && selectedType == channel.type;

    TextEditingController getFieldController(String key) {
      return fieldControllers.putIfAbsent(key, () {
        if (key == _rawConfigFieldKey) {
          // 回填逻辑与「打开 → 直接保存不清空配置」的回归用例都在
          // features/notifications/utils/channel_config.dart。
          return TextEditingController(
            text: buildRawConfigEditorText(
              existingConfig: existingConfig,
              keepExistingConfig: keepsExistingConfig(),
            ),
          );
        }
        return TextEditingController(
          text: existingConfig[key]?.toString() ?? '',
        );
      });
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useRootNavigator: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final fields = _channelFieldMap[selectedType] ?? [];
            return Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                0,
                20,
                MediaQuery.of(ctx).viewInsets.bottom + 20,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      channel == null ? '新建通知渠道' : '编辑通知渠道',
                      style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(
                        labelText: '渠道名称',
                        hintText: '如：我的Bark',
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: selectedType,
                      decoration: const InputDecoration(labelText: '渠道类型'),
                      items: availableTypes
                          .map(
                            (item) => DropdownMenuItem(
                              value: item.type,
                              child: Text(item.name),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setSheetState(() {
                            disposeFieldControllers();
                            selectedType = value;
                          });
                        }
                      },
                    ),
                    if (fields.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      const Divider(height: 1),
                      const SizedBox(height: 12),
                      ...fields.map(
                        (f) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: TextField(
                            controller: getFieldController(f.key),
                            obscureText: f.obscure,
                            decoration: InputDecoration(
                              labelText: f.label,
                              hintText: f.hint,
                            ),
                          ),
                        ),
                      ),
                      if (selectedType == 'email')
                        SwitchListTile.adaptive(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('启用 SMTP SSL'),
                          subtitle: const Text(
                            '465 端口通常需要开启，25/587 可按邮箱服务要求选择',
                          ),
                          value: smtpSsl,
                          onChanged: (value) {
                            setSheetState(() => smtpSsl = value);
                          },
                        ),
                    ],
                    if (fields.isEmpty) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: getFieldController(_rawConfigFieldKey),
                        minLines: 5,
                        maxLines: 10,
                        decoration: const InputDecoration(
                          labelText: '配置 JSON',
                          alignLabelWithHint: true,
                          hintText: '{"key": "value"}',
                        ),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: () async {
                        final name = nameController.text.trim();
                        if (name.isEmpty) {
                          messenger.showSnackBar(
                            const SnackBar(content: Text('名称不能为空')),
                          );
                          return;
                        }

                        Map<String, dynamic> configMap;
                        if (fields.isNotEmpty) {
                          // 合并规则（保留未知字段）与回归用例都在
                          // features/notifications/utils/channel_config.dart。
                          configMap = buildChannelConfigFromFields(
                            existingConfig: existingConfig,
                            keepExistingConfig: keepsExistingConfig(),
                            fieldValues: {
                              for (final f in fields)
                                f.key: getFieldController(f.key).text.trim(),
                            },
                            smtpSsl: selectedType == 'email' ? smtpSsl : null,
                          );
                        } else {
                          final raw = getFieldController(
                            _rawConfigFieldKey,
                          ).text.trim();
                          final parsed = parseChannelConfig(
                            raw.isEmpty ? '{}' : raw,
                          );
                          if (parsed == null) {
                            // JSON 写错时原来会静默退化成 {}，等于把整份配置清空。
                            messenger.showSnackBar(
                              const SnackBar(content: Text('配置 JSON 格式不正确')),
                            );
                            return;
                          }
                          configMap = parsed;
                        }

                        final payload = {
                          'name': name,
                          'type': selectedType,
                          'config': jsonEncode(configMap),
                        };

                        try {
                          if (channel == null) {
                            await ref
                                .read(notificationListProvider.notifier)
                                .create(payload);
                          } else {
                            await ref
                                .read(notificationListProvider.notifier)
                                .update(channel.id, payload);
                          }
                          if (!mounted) return;
                          Navigator.of(ctx).pop();
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text(channel == null ? '创建成功' : '保存成功'),
                            ),
                          );
                        } catch (error) {
                          if (!mounted) return;
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text(
                                _extractMessage(
                                  error,
                                  channel == null ? '创建失败' : '保存失败',
                                ),
                              ),
                            ),
                          );
                        }
                      },
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 48),
                      ),
                      child: Text(channel == null ? '创建' : '保存'),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).then((_) {
      nameController.dispose();
      disposeFieldControllers();
    });
  }
}

class _ChannelCard extends StatelessWidget {
  final NotifyChannel channel;
  final String typeLabel;
  final bool isLight;
  final VoidCallback onEdit;
  final VoidCallback onToggle;
  final VoidCallback onTest;
  final VoidCallback onDelete;

  const _ChannelCard({
    required this.channel,
    required this.typeLabel,
    required this.isLight,
    required this.onEdit,
    required this.onToggle,
    required this.onTest,
    required this.onDelete,
  });

  IconData _typeIcon() {
    switch (channel.type) {
      case 'email':
        return Icons.email_outlined;
      case 'telegram':
        return Icons.send;
      case 'dingtalk':
        return Icons.chat;
      case 'wecom':
      case 'wecom_app':
        return Icons.business;
      case 'bark':
        return Icons.phone_iphone;
      default:
        return Icons.webhook;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: isLight ? Colors.white : AppColors.slate900,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isLight ? AppColors.slate200 : AppColors.slate800,
        ),
      ),
      child: Row(
        children: [
          // 渠道图标底板：启用态 = success 绿。底板和图标是一对，必须同时改。
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: channel.enabled
                  ? AppColors.success.withAlpha(25)
                  : AppColors.slate200.withAlpha(60),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              _typeIcon(),
              size: 18,
              // 底板就是同色的 alpha=25 淡底，18px 图标按 UI 组件也要 3:1。
              color: context.surfaces.tintFg(
                channel.enabled ? AppColors.success : AppColors.slate400,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  channel.name,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  typeLabel,
                  style: TextStyle(
                    fontSize: 11,
                    color: isLight ? AppColors.slate500 : AppColors.slate400,
                  ),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: onTest,
            child: const Padding(
              padding: EdgeInsets.all(6),
              child: Icon(Icons.send, size: 16, color: AppColors.blue500),
            ),
          ),
          GestureDetector(
            onTap: onEdit,
            child: const Padding(
              padding: EdgeInsets.all(6),
              child: Icon(
                Icons.edit_outlined,
                size: 18,
                color: AppColors.blue500,
              ),
            ),
          ),
          GestureDetector(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.all(6),
              // 开关图标：开 = 已启用 = success 绿。必须与同一行左侧的图标底板
              // 一起改，否则同一张卡里「已启用」是一绿一蓝。
              child: Icon(
                channel.enabled ? Icons.toggle_on : Icons.toggle_off,
                size: 28,
                color: channel.enabled ? AppColors.success : AppColors.slate400,
              ),
            ),
          ),
          GestureDetector(
            onTap: onDelete,
            child: const Padding(
              padding: EdgeInsets.all(6),
              child: Icon(
                Icons.delete_outline,
                size: 18,
                color: AppColors.red500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _typeName(List<NotificationTypeOption> types, String type) {
  for (final item in types) {
    if (item.type == type) {
      return item.name;
    }
  }
  return type;
}

bool _configBool(dynamic value) {
  if (value is bool) {
    return value;
  }
  final text = value?.toString().trim().toLowerCase() ?? '';
  return text == 'true' || text == '1' || text == 'yes' || text == 'on';
}

String _extractMessage(dynamic error, String fallback) {
  try {
    final data = (error as dynamic).response?.data;
    if (data is Map && data['error'] != null) {
      return data['error'].toString();
    }
    if (data is Map && data['message'] != null) {
      return data['message'].toString();
    }
  } catch (_) {}
  return fallback;
}
