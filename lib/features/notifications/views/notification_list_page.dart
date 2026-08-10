import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_endpoints.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/models/notify_channel.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/widgets/app_circle_add_button.dart';
import '../../../shared/widgets/app_back_button.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/app_snack.dart';
import '../../../shared/widgets/app_state_views.dart';
import '../utils/channel_config.dart';
import '../utils/frozen_channel_fields_v300.dart';
import '../utils/notify_field_schema.dart';

final notificationListProvider =
    StateNotifierProvider<NotificationListNotifier, NotificationListState>((
      ref,
    ) {
      return NotificationListNotifier();
    });

class NotificationListState {
  final List<NotifyChannel> items;
  final bool loading;

  /// 拉取失败的原因，成功时为 null。
  final String? error;

  /// 渠道类型 + 每个类型的字段定义，全部来自面板 `/notifications/types`。
  /// 老面板只回 `{type,name}`，这时每一项的 `fields` 是空的，
  /// 由 [resolveNotifyChannelFields] 回落到 v3.0.0 冻结快照。
  final List<NotifyChannelSchema> types;

  const NotificationListState({
    this.items = const [],
    this.loading = false,
    this.error,
    this.types = const [],
  });

  NotificationListState copyWith({
    List<NotifyChannel>? items,
    bool? loading,
    String? error,
    List<NotifyChannelSchema>? types,
  }) {
    return NotificationListState(
      items: items ?? this.items,
      loading: loading ?? this.loading,
      // 故意不写 `error ?? this.error`：不传 error 就等于清空错误态，
      // 否则一次失败之后的每次成功刷新都还挂着旧错误。
      error: error,
      types: types ?? this.types,
    );
  }
}

class NotificationListNotifier extends StateNotifier<NotificationListState> {
  /// [dio] **仅供测试注入**，生产路径不传，仍然走 `DioClient` 单例。
  /// 单例的 baseUrl 会随切换面板被改写，所以这里不在构造时把它存下来。
  NotificationListNotifier({Dio? dio})
    : _injectedDio = dio,
      super(const NotificationListState());

  final Dio? _injectedDio;

  Dio get _dio => _injectedDio ?? DioClient.instance.dio;

  Future<void> load() async {
    state = state.copyWith(loading: true, error: null);
    try {
      final dio = _dio;
      final channelsFuture = dio.get(ApiEndpoints.notifications);
      // 渠道类型表是辅助数据，本来就有冻结快照兜底。收紧 validateStatus 后
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
        types: resolveNotifyChannelTypes(types),
      );
    } catch (e) {
      state = state.copyWith(
        loading: false,
        // 类型表要单独降级（见上面注释），失败时也得保住冻结快照兜底。
        types: resolveNotifyChannelTypes(state.types),
        error: extractListErrorMessage(e, '加载通知渠道失败'),
      );
    }
  }

  /// 取渠道类型 + 字段 schema。失败不抛，交给冻结快照兜底。
  ///
  /// 这里**不做**任何版本判断：老面板返回的项没有 `fields`，解析出来就是
  /// `fields` 为空的 schema，形状本身就是探测结果。
  Future<List<NotifyChannelSchema>> _fetchTypes() async {
    try {
      final response = await _dio.get(ApiEndpoints.notificationTypes);
      return parseNotifyChannelSchemas(extractData(response.data));
    } catch (_) {
      return const [];
    }
  }

  Future<void> toggle(int id, bool enabled) async {
    final dio = _dio;
    if (enabled) {
      await dio.put(ApiEndpoints.notificationEnable(id));
    } else {
      await dio.put(ApiEndpoints.notificationDisable(id));
    }
    await load();
  }

  Future<void> test(int id) async {
    await _dio.post(ApiEndpoints.notificationTest(id));
  }

  Future<void> delete(int id) async {
    await _dio.delete(ApiEndpoints.notificationById(id));
    await load();
  }

  Future<void> create(Map<String, dynamic> data) async {
    await _dio.post(ApiEndpoints.notifications, data: data);
    await load();
  }

  Future<void> update(int id, Map<String, dynamic> data) async {
    await _dio.put(ApiEndpoints.notificationById(id), data: data);
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
                  const AppBackButton(),
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
                  AppCircleAddButton(onTap: () => _showChannelDialog()),
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
                    // 拿不到数据和真的没有渠道是两回事，必须先判 error。
                    : state.error != null && state.items.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          AppErrorView(
                            title: '通知渠道加载失败',
                            message: state.error!,
                            onRetry: () => ref
                                .read(notificationListProvider.notifier)
                                .load(),
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
      AppSnack.error(context, extractErrorMessage(error, '修改渠道状态失败'));
    }
  }

  Future<void> _doTest(NotifyChannel channel) async {
    try {
      await ref.read(notificationListProvider.notifier).test(channel.id);
      if (!mounted) {
        return;
      }
      AppSnack.success(context, '测试通知已发送');
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppSnack.error(context, extractErrorMessage(error, '测试发送失败'));
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
        AppSnack.error(context, extractErrorMessage(error, '删除失败'));
      }
    }
  }

  /// 一个字段定义都拿不到的渠道类型走「配置 JSON」编辑框，用这个 key 存控制器。
  ///
  /// 新面板会给 custom 下发 5 个字段（url / method / content_type / headers / body，
  /// 与 notifier.go 的 `sendCustomWebhook` 读的键逐条对应），那时它走通用表单。
  /// 这个分支只剩老面板上的 custom、以及面板新加而 APP 还拿不到 schema 的类型。
  static const String _rawConfigFieldKey = '__raw_json__';

  void _showChannelDialog({NotifyChannel? channel}) {
    // 底部弹窗里的提示一律用**本页的 context**（不是 builder 的 ctx）：
    // 提交成功那条是在 `Navigator.of(ctx).pop()` 之后弹的，那时 ctx 已经失效，
    // 用它会被 AppSnack 内部的 context.mounted 判空静默丢掉。
    // 原来这里提前取 `ScaffoldMessenger.of(context)` 就是为了跨 await 不碰 context，
    // AppSnack 同样要 context，所以改成每个 await 之后先判本页的 mounted —— 行为一致，
    // 也不会新增 use_build_context_synchronously。
    final nameController = TextEditingController(text: channel?.name ?? '');
    final existingConfig = Map<String, dynamic>.from(channel?.config ?? {});
    final fieldControllers = <String, TextEditingController>{};
    // select 型字段没有 TextEditingController，当前值存这里。
    final selectValues = <String, String>{};

    final availableTypes = resolveNotifyChannelTypes(
      ref.read(notificationListProvider).types,
    );
    String selectedType = channel?.type ?? availableTypes.first.type;
    if (!availableTypes.any((item) => item.type == selectedType)) {
      selectedType = availableTypes.first.type;
    }

    void disposeFieldControllers() {
      for (final c in fieldControllers.values) {
        c.dispose();
      }
      fieldControllers.clear();
      // 换了渠道类型，上一个类型的下拉选值同样作废。
      selectValues.clear();
    }

    /// 服务端已有的 config 只有在渠道类型没被改过时才对得上号。
    /// 用户在下拉里换了类型，旧配置的键就没有意义了，不能再带回服务端。
    bool keepsExistingConfig() =>
        channel != null && selectedType == channel.type;

    TextEditingController textController(String key, String seed) {
      return fieldControllers.putIfAbsent(
        key,
        () => TextEditingController(text: seed),
      );
    }

    /// 字段此刻的值。select 读 [selectValues]，其余读输入框。
    String currentValue(NotifyFieldSchema field, Map<String, String> seeds) {
      final seed = seeds[field.key] ?? '';
      if (field.effectiveWidget == NotifyFieldWidget.select) {
        return selectValues[field.key] ?? seed;
      }
      return textController(field.key, seed).text;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useRootNavigator: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            // 面板下发了 fields 就用面板的，没有就回落 v3.0.0 冻结快照 ——
            // 形状探测与降级都收在 resolveNotifyChannelFields 里，这里不做版本判断。
            final fields = resolveNotifyChannelFields(
              type: selectedType,
              schemas: availableTypes,
            );
            final seeds = buildNotifyFieldSeeds(
              fields: fields,
              existingConfig: existingConfig,
              keepExistingConfig: keepsExistingConfig(),
            );
            Map<String, String> readDraft() => <String, String>{
              for (final field in fields) field.key: currentValue(field, seeds),
            };
            final visibleFields = visibleNotifyFields(
              fields: fields,
              values: readDraft(),
            );

            Widget buildFieldControl(NotifyFieldSchema field) {
              final seed = seeds[field.key] ?? '';
              final label = field.isRequired ? '${field.label} *' : field.label;
              final hint = field.placeholder.isEmpty
                  ? null
                  : field.placeholder;
              // 字段列表随渠道类型整体换血。不给 key 的话 Flutter 会按位置复用
              // 上一个类型同位置的 Element，下拉会显示成上一个类型的旧值。
              final fieldKey = ValueKey<String>('$selectedType/${field.key}');

              switch (field.effectiveWidget) {
                case NotifyFieldWidget.select:
                  final current = selectValues[field.key] ?? seed;
                  return DropdownButtonFormField<String>(
                    key: fieldKey,
                    initialValue: current,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: label,
                      helperText: hint,
                    ),
                    items: field
                        .renderOptions(current)
                        .map(
                          (option) => DropdownMenuItem<String>(
                            value: option.value,
                            child: Text(
                              option.label,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    // 选项值一律是 String（NotifyFieldOption.value 就是 String），
                    // 不会有 bool 混进 config —— 那会让面板整份 config 解析失败，
                    // 该渠道所有通知从此全挂。
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      setSheetState(() => selectValues[field.key] = value);
                    },
                  );
                case NotifyFieldWidget.textarea:
                  return TextField(
                    key: fieldKey,
                    controller: textController(field.key, seed),
                    minLines: 3,
                    maxLines: 6,
                    decoration: InputDecoration(
                      labelText: label,
                      hintText: hint,
                      alignLabelWithHint: true,
                    ),
                    // textarea 装的全是 JSON（news_articles、template_card_payload、
                    // image_base64…），等宽字体好对括号。
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                  );
                case NotifyFieldWidget.password:
                  return TextField(
                    key: fieldKey,
                    controller: textController(field.key, seed),
                    obscureText: true,
                    // 密钥别让输入法当词组记下来。
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: label,
                      hintText: hint,
                    ),
                  );
                // 不认识的 widget 一律降级成输入框，**绝不隐藏字段**：
                // 隐藏等于用户在 APP 上永远填不了它。
                case NotifyFieldWidget.input:
                case NotifyFieldWidget.unknown:
                  return TextField(
                    key: fieldKey,
                    controller: textController(field.key, seed),
                    decoration: InputDecoration(
                      labelText: label,
                      hintText: hint,
                    ),
                  );
              }
            }

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
                      isExpanded: true,
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
                    if (visibleFields.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      const Divider(height: 1),
                      const SizedBox(height: 12),
                      ...visibleFields.map(
                        (field) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: buildFieldControl(field),
                        ),
                      ),
                    ],
                    if (fields.isEmpty) ...[
                      const SizedBox(height: 12),
                      TextField(
                        // 回填逻辑与「打开 → 直接保存不清空配置」的回归用例都在
                        // features/notifications/utils/channel_config.dart。
                        controller: textController(
                          _rawConfigFieldKey,
                          buildRawConfigEditorText(
                            existingConfig: existingConfig,
                            keepExistingConfig: keepsExistingConfig(),
                          ),
                        ),
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
                          // 这颗按钮可以连点，下面几条提示统一 replaceCurrent：
                          // 不顶掉上一条的话，用户改完再点，先看到的还是上一次的过期结论。
                          AppSnack.warn(
                            context,
                            '名称不能为空',
                            replaceCurrent: true,
                          );
                          return;
                        }

                        Map<String, dynamic> configMap;
                        if (fields.isNotEmpty) {
                          // 显隐重新算一遍：用户可能改完下拉又改了输入框，
                          // 而 build 时算的那份 visibleFields 已经过期了。
                          final draft = readDraft();
                          final activeFields = visibleNotifyFields(
                            fields: fields,
                            values: draft,
                          );
                          final invalid = validateNotifyFields(
                            visibleFields: activeFields,
                            values: draft,
                          );
                          if (invalid != null) {
                            AppSnack.warn(
                              context,
                              invalid,
                              replaceCurrent: true,
                            );
                            return;
                          }
                          // 合并规则（保留未知字段）与回归用例都在
                          // features/notifications/utils/channel_config.dart。
                          configMap = buildChannelConfigFromFields(
                            existingConfig: existingConfig,
                            keepExistingConfig: keepsExistingConfig(),
                            fieldValues: buildNotifyFieldValues(
                              visibleFields: activeFields,
                              existingConfig: existingConfig,
                              keepExistingConfig: keepsExistingConfig(),
                              draft: draft,
                            ),
                          );
                        } else {
                          final raw = textController(
                            _rawConfigFieldKey,
                            '',
                          ).text.trim();
                          final parsed = parseChannelConfig(
                            raw.isEmpty ? '{}' : raw,
                          );
                          if (parsed == null) {
                            // JSON 写错时原来会静默退化成 {}，等于把整份配置清空。
                            AppSnack.warn(
                              context,
                              '配置 JSON 格式不正确',
                              replaceCurrent: true,
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
                          AppSnack.success(
                            context,
                            channel == null ? '创建成功' : '保存成功',
                            replaceCurrent: true,
                          );
                        } catch (error) {
                          if (!mounted) return;
                          AppSnack.error(
                            context,
                            extractErrorMessage(
                              error,
                              channel == null ? '创建失败' : '保存失败',
                            ),
                            replaceCurrent: true,
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
    return AppCard(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
              // 图标底板一律走 sm，不跟外层 AppCard（lg）同档。
              borderRadius: BorderRadius.circular(AppRadius.sm),
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

String _typeName(List<NotifyChannelSchema> types, String type) {
  for (final item in types) {
    if (item.type == type) {
      return item.name;
    }
  }
  return type;
}
