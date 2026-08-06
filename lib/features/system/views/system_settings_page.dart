import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/app_notice.dart';
import '../../../shared/widgets/app_section_title.dart';
import '../../../shared/widgets/app_snack.dart';
import '../utils/system_config_schema.dart';

/// 系统设置页。
///
/// 配置区**完全由 `GET /api/configs` 下发的 schema 驱动**，不再硬编码键名。
/// 改造前这里写死了 10 个键的读写，而面板注册表里有 47 项 —— 也就是说整组
/// 定时备份、验证码、资源告警阈值、会话上限、时区、面板标题在 APP 上根本改不了。
///
/// schema 的解析、降级与回写逻辑全部在 `../utils/system_config_schema.dart`，
/// 本文件只负责画。老面板兼容策略见那个文件的头注释。
class SystemSettingsPage extends ConsumerStatefulWidget {
  const SystemSettingsPage({super.key});

  @override
  ConsumerState<SystemSettingsPage> createState() => _SystemSettingsPageState();
}

/// 少数保留定制 UI 的配置项。
///
/// schema 说得出「这是个字符串」，说不出「常用镜像源有哪几个」。而面板端**也没有**
/// 这份预设的真源（server/service/dependency_mirrors.go 只有两个默认值常量，
/// handler/deps.go 的 GetMirrors 不回预设列表），所以在面板里新写一张表 =
/// 把 APP 的硬编码搬到面板，硬编码总数不变还多一个接口。
///
/// 这里的做法是「schema 驱动 + 增量定制」：输入框本身仍由 schema 生成，
/// 本表只多挂一个「配置 / 清空」按钮。面板哪天真的下发预设了，删掉本表即可，
/// 输入框不受影响。
class _MirrorPreset {
  const _MirrorPreset({
    required this.title,
    required this.intro,
    required this.urls,
  });

  final String title;
  final String intro;
  final List<String> urls;
}

/// int 输入框只放行数字和负号。留着负号是为了让「填了 -1」走到统一的范围报错，
/// 而不是变成一个打不出来的字符 —— 用户会以为键盘坏了。
final List<TextInputFormatter> _intInputFormatters = <TextInputFormatter>[
  FilteringTextInputFormatter.allow(RegExp(r'[0-9-]')),
];

const Map<String, _MirrorPreset> _mirrorPresets = <String, _MirrorPreset>{
  'update_image_mirror': _MirrorPreset(
    title: '系统更新镜像源',
    intro: 'Docker 部署更新使用。也可以到 https://status.anye.xyz/ 查看更多镜像源状态后手动填写。',
    urls: <String>[
      'https://docker.1ms.run',
      'https://docker.1panel.live',
      'https://docker.sparkcr.cn',
      'https://hub.rat.dev',
      'https://dockerproxy.net',
      'https://mirror.ccs.tencentyun.com',
    ],
  ),
  'binary_update_proxy': _MirrorPreset(
    title: '二进制更新加速源',
    intro: '二进制部署更新使用，用于加速 GitHub Release 更新包下载。',
    urls: <String>[
      'https://gh-proxy.org/',
      'https://v4.gh-proxy.org/',
      'http://gh.301.ee/',
      'https://ghproxy.homeboyc.cn/',
    ],
  ),
};

class _SystemSettingsPageState extends ConsumerState<SystemSettingsPage> {
  Map<String, dynamic>? _versionInfo;
  Map<String, dynamic>? _updateInfo;
  Map<String, dynamic>? _updateStatus;
  bool _loading = true;
  bool _checking = false;
  bool _savingConfigs = false;
  bool _updatingPanel = false;

  List<SystemConfigGroup> _groups = const <SystemConfigGroup>[];
  List<SystemConfigItem> _items = const <SystemConfigItem>[];
  String? _configError;

  /// string / int / 未知类型走输入框。
  final Map<String, TextEditingController> _controllers =
      <String, TextEditingController>{};

  /// bool / enum 走选择器，值仍然是字符串（面板存的就是字符串）。
  final Map<String, String> _choices = <String, String>{};

  final Set<String> _expandedGroups = <String>{};
  final Set<String> _revealedSecrets = <String>{};
  bool _expansionInitialized = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);

    Map<String, dynamic>? versionData;
    try {
      final response = await DioClient.instance.dio.get(
        ApiEndpoints.systemVersion,
      );
      final data = extractData(response.data);
      if (data is Map<String, dynamic>) {
        versionData = data;
      }
    } catch (_) {
      // 版本信息拿不到不影响改配置，保持原来的静默降级。
    }

    var groups = const <SystemConfigGroup>[];
    String? configError;
    try {
      final response = await DioClient.instance.dio.get(ApiEndpoints.configs);
      groups = parseSystemConfigGroups(extractData(response.data));
      if (groups.isEmpty) {
        configError = '面板没有返回任何可编辑的系统配置';
      }
    } catch (error) {
      // /configs 挂了 RequireAdmin，非管理员会拿到 403。原来这里整个被 catch(_)
      // 吞掉，用户看到的是一片空白而不是「没有权限」。
      configError = extractListErrorMessage(error, '加载系统配置失败');
    }

    if (!mounted) {
      return;
    }

    _rebuildEditors(groups);
    setState(() {
      _versionInfo = versionData;
      _groups = groups;
      _items = flattenSystemConfigItems(groups);
      _configError = configError;
      _loading = false;
    });
  }

  void _rebuildEditors(List<SystemConfigGroup> groups) {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _controllers.clear();
    _choices.clear();
    _revealedSecrets.clear();

    for (final item in flattenSystemConfigItems(groups)) {
      if (item.readOnly) {
        continue;
      }
      switch (item.effectiveType) {
        case ConfigValueType.boolean:
        case ConfigValueType.enumerated:
          _choices[item.key] = item.value;
        case ConfigValueType.string:
        case ConfigValueType.integer:
        case ConfigValueType.unknown:
          _controllers[item.key] = TextEditingController(text: item.value);
      }
    }

    // 47 项平铺没法用，默认只展开第一组。用「第一组」而不是写死某个 slug：
    // 分组名是服务端给的，写死 'tasks' 会在面板改名后变成一组都不展开。
    if (!_expansionInitialized && groups.isNotEmpty) {
      _expansionInitialized = true;
      _expandedGroups.add(groups.first.group);
    }
  }

  Map<String, String> _collectDraft() {
    final draft = <String, String>{};
    for (final entry in _controllers.entries) {
      draft[entry.key] = entry.value.text;
    }
    draft.addAll(_choices);
    return draft;
  }

  Future<void> _saveConfigs() async {
    final draft = _collectDraft();

    for (final item in _items) {
      final raw = draft[item.key];
      if (raw == null) {
        continue;
      }
      final message = validateSystemConfigValue(item, raw);
      if (message == null) {
        continue;
      }
      // 出错的那一项可能正好在折起来的分组里，先展开再报错。
      setState(() => _expandedGroups.add(item.group));
      AppSnack.error(context, message);
      return;
    }

    final payload = buildSystemConfigWritePayload(items: _items, draft: draft);
    if (payload.isEmpty) {
      AppSnack.show(context, '没有需要保存的改动');
      return;
    }

    setState(() => _savingConfigs = true);
    try {
      await DioClient.instance.dio.put(
        ApiEndpoints.configsBatch,
        data: <String, dynamic>{'configs': payload},
      );
      if (!mounted) {
        return;
      }
      AppSnack.success(context, '已保存 ${payload.length} 项配置');
      // 面板会对值做 normalize（空串回落默认值、枚举转小写、二进制加速源补斜杠），
      // 不重拉的话表单显示的就不是面板实际生效的值。
      await _load();
    } catch (error) {
      // 收紧 validateStatus 之前，面板返回 400 也会走 try 分支弹「配置已保存」，
      // 用户根本看不出保存失败。现在 4xx 会进到这里，直接把后端原文透出来。
      if (!mounted) {
        return;
      }
      AppSnack.error(context, extractErrorMessage(error, '保存失败'));
    } finally {
      if (mounted) {
        setState(() => _savingConfigs = false);
      }
    }
  }

  Future<void> _checkUpdate() async {
    setState(() => _checking = true);
    try {
      final resp = await DioClient.instance.dio.get(ApiEndpoints.checkUpdate);
      final data = extractData(resp.data);
      if (!mounted) {
        return;
      }
      setState(() {
        _updateInfo = data is Map<String, dynamic> ? data : null;
        _checking = false;
      });
      if (_updateInfo != null && _updateInfo!['has_update'] == true) {
        _showUpdateDialog();
      } else {
        AppSnack.show(context, '已是最新版本');
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _checking = false);
      AppSnack.error(context, extractErrorMessage(error, '检查更新失败'));
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
        ApiEndpoints.systemUpdateStatus,
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
              const SizedBox(height: AppSpacing.sm),
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
                const SizedBox(width: AppSpacing.md),
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
        ApiEndpoints.systemUpdate,
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
        AppSnack.success(context, _updateSuccessHint());
      }
    } catch (error) {
      if (mounted) {
        AppSnack.error(context, extractErrorMessage(error, '更新失败'));
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
              const SizedBox(width: AppSpacing.md),
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
    if (confirm != true) {
      return;
    }
    try {
      await DioClient.instance.dio.post(ApiEndpoints.systemRestart);
      if (!mounted) {
        return;
      }
      AppSnack.show(context, '面板将在 2 秒后重启');
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppSnack.error(context, extractErrorMessage(error, '重启失败'));
    }
  }

  Future<void> _showMirrorOptions(
    SystemConfigItem item,
    _MirrorPreset preset,
  ) async {
    final controller = _controllers[item.key];
    if (controller == null) {
      return;
    }
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.xl,
            0,
            AppSpacing.xl,
            AppSpacing.xl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                preset.title,
                style: Theme.of(
                  ctx,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                preset.intro,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              ...preset.urls.map(
                (url) => Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx, url),
                    style: OutlinedButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                        vertical: AppSpacing.md,
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
    if (selected == null || !mounted) {
      return;
    }
    setState(() => controller.text = selected);
  }

  Future<void> _pickOption(SystemConfigItem item) async {
    final options = item.renderOptions();
    final current = _choices[item.key] ?? item.value;
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.xl,
            0,
            AppSpacing.xl,
            AppSpacing.xl,
          ),
          children: [
            Text(
              item.label,
              style: Theme.of(
                ctx,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppSpacing.sm),
            ...options.map(
              (option) => ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  option.label,
                  style: const TextStyle(fontSize: 14),
                ),
                trailing: option.value == current
                    ? const Icon(
                        Icons.check_rounded,
                        size: 18,
                        color: AppColors.primary,
                      )
                    : null,
                onTap: () => Navigator.pop(ctx, option.value),
              ),
            ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) {
      return;
    }
    setState(() => _choices[item.key] = selected);
  }

  // ── 配置项渲染 ────────────────────────────────────────────────────────

  /// 输入框下方的说明。
  ///
  /// 老面板没有 label 时，label 是从 description 切出来的头段，两者相等就不重复显示
  /// （[SystemConfigItem.hasHint] 负责判断）。min/max 存在时附上取值范围 ——
  /// 老面板不下发这两个字段，此时这一句自然就没有，由面板 400 兜底。
  String? _hintFor(SystemConfigItem item) {
    final parts = <String>[];
    if (item.hasHint) {
      parts.add(item.description);
    }
    final extra = kSystemConfigExtraHints[item.key];
    if (extra != null) {
      parts.add(extra);
    }
    final min = item.min;
    final max = item.max;
    if (min != null && max != null) {
      parts.add('取值范围 $min - $max');
    } else if (min != null) {
      parts.add('最小 $min');
    } else if (max != null) {
      parts.add('最大 $max');
    }
    if (parts.isEmpty) {
      return null;
    }
    return parts.join('\n');
  }

  Widget _buildFieldFrame({
    required SystemConfigItem item,
    required Widget control,
    bool showLabel = true,
  }) {
    final surfaces = context.surfaces;
    final hint = _hintFor(item);
    final risk = item.riskNote;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showLabel) ...[
          Text(
            item.label,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: AppSpacing.xs),
        ],
        control,
        if (hint != null) ...[
          const SizedBox(height: AppSpacing.xxs),
          Text(
            hint,
            style: TextStyle(fontSize: 10, height: 1.4, color: surfaces.mutedText),
          ),
        ],
        if (risk != null) ...[
          const SizedBox(height: AppSpacing.xxs),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 12,
                color: surfaces.tintFg(AppColors.warning),
              ),
              const SizedBox(width: AppSpacing.xxs),
              Expanded(
                child: Text(
                  risk,
                  style: TextStyle(
                    fontSize: 10,
                    height: 1.4,
                    color: surfaces.tintFg(AppColors.warning),
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// 输入框里的灰字提示。
  ///
  /// 默认值可能很长（trusted_proxy_cidrs 的默认值是一串换行分隔的 CIDR），
  /// 直接塞进 hintText 会把输入框撑成好几行。
  String _placeholderFor(SystemConfigItem item) {
    final fallback = item.defaultValue.trim();
    if (fallback.isEmpty) {
      return '留空';
    }
    if (fallback.contains('\n') || fallback.length > 24) {
      return '留空恢复默认值';
    }
    return '默认 $fallback';
  }

  Widget _buildTextField(SystemConfigItem item) {
    final controller = _controllers[item.key];
    if (controller == null) {
      return const SizedBox.shrink();
    }

    final isSecret = item.secret;
    final revealed = _revealedSecrets.contains(item.key);
    final preset = _mirrorPresets[item.key];
    final isInt = item.effectiveType == ConfigValueType.integer;
    // 多行与否**从数据推**，不维护键名清单：面板里只有 trusted_proxy_cidrs
    // 这类换行分隔的值，它的 default_value 本身就是 strings.Join(..., "\n")。
    final multiline =
        !isSecret &&
        !isInt &&
        (item.value.contains('\n') || item.defaultValue.contains('\n'));

    final field = TextField(
      controller: controller,
      obscureText: isSecret && !revealed,
      // 打码字段关掉联想，别让输入法把密钥当词组记下来。
      enableSuggestions: !isSecret,
      autocorrect: !isSecret,
      keyboardType: isInt
          ? const TextInputType.numberWithOptions(signed: true)
          : (multiline ? TextInputType.multiline : TextInputType.text),
      inputFormatters: isInt ? _intInputFormatters : null,
      maxLines: multiline ? 4 : 1,
      minLines: multiline ? 2 : 1,
      decoration: InputDecoration(
        hintText: _placeholderFor(item),
        hintStyle: TextStyle(fontSize: 11, color: context.surfaces.mutedText),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 10,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        suffixIcon: isSecret
            ? IconButton(
                iconSize: 18,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                tooltip: revealed ? '隐藏' : '显示',
                icon: Icon(
                  revealed
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
                onPressed: () => setState(() {
                  if (revealed) {
                    _revealedSecrets.remove(item.key);
                  } else {
                    _revealedSecrets.add(item.key);
                  }
                }),
              )
            : null,
      ),
      style: const TextStyle(fontSize: 13),
    );

    if (preset == null) {
      return _buildFieldFrame(item: item, control: field);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                item.label,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            TextButton(
              onPressed: () => _showMirrorOptions(item, preset),
              child: const Text('配置'),
            ),
            // 「清空」按钮的显隐跟着输入框走。不能在 build 里直接读
            // controller.text —— 那只有 setState 时才会刷新，用户手动清空后
            // 按钮会一直挂着。
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              // 未用到的两个位置参数都写 `_`：这个 Dart 版本里 `_` 是非绑定通配符，
              // 可以重复；写成 `__` 反而会被 unnecessary_underscores 挑出来。
              builder: (_, value, _) => value.text.trim().isEmpty
                  ? const SizedBox.shrink()
                  : TextButton(
                      onPressed: () => setState(controller.clear),
                      child: const Text('清空'),
                    ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        _buildFieldFrame(item: item, control: field, showLabel: false),
      ],
    );
  }

  Widget _buildBoolField(SystemConfigItem item) {
    final value = parseConfigBool(_choices[item.key] ?? item.value);
    return _buildFieldFrame(
      item: item,
      showLabel: false,
      control: SwitchListTile.adaptive(
        value: value,
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(item.label, style: const TextStyle(fontSize: 13)),
        // ⚠️ 写回的值必须是字符串 'true'/'false'。面板的 BatchSet 绑定的是
        // map[string]string，混进 JSON bool 会让整份 ShouldBindJSON 失败。
        // 归一化统一由 SystemConfigItem.normalizeForWrite 负责。
        onChanged: (next) =>
            setState(() => _choices[item.key] = next ? 'true' : 'false'),
      ),
    );
  }

  Widget _buildEnumField(SystemConfigItem item) {
    final current = _choices[item.key] ?? item.value;
    final options = item.renderOptions();
    final label = options
        .firstWhere(
          (option) => option.value == current,
          orElse: () => SystemConfigOption(value: current, label: current),
        )
        .label;
    final surfaces = context.surfaces;

    return _buildFieldFrame(
      item: item,
      control: InkWell(
        onTap: () => _pickOption(item),
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: 10,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(
              color: surfaces.subtleBorder,
              width: AppBorderWidth.hairline,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label.isEmpty ? '未设置' : label,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              Icon(
                Icons.expand_more_rounded,
                size: 18,
                color: surfaces.mutedText,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReadOnlyField(SystemConfigItem item) {
    final surfaces = context.surfaces;
    return _buildFieldFrame(
      item: item,
      control: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 10,
        ),
        decoration: BoxDecoration(
          color: surfaces.subtle,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: surfaces.subtleBorder,
            width: AppBorderWidth.hairline,
          ),
        ),
        child: Text(
          item.value.trim().isEmpty ? '未设置' : item.value,
          style: TextStyle(fontSize: 13, color: surfaces.mutedText),
        ),
      ),
    );
  }

  /// 按 value_type 分派控件。
  ///
  /// [ConfigValueType.unknown]（面板加了这一版 APP 不认识的类型）降级成输入框，
  /// **绝不隐藏字段** —— 隐藏等于用户在 APP 上永远改不了它，而这一页存在的
  /// 全部意义就是「面板注册了什么，APP 上就能改什么」。
  Widget _buildConfigField(SystemConfigItem item) {
    if (item.readOnly) {
      return _buildReadOnlyField(item);
    }
    switch (item.effectiveType) {
      case ConfigValueType.boolean:
        return _buildBoolField(item);
      case ConfigValueType.enumerated:
        return _buildEnumField(item);
      case ConfigValueType.string:
      case ConfigValueType.integer:
      case ConfigValueType.unknown:
        return _buildTextField(item);
    }
  }

  Widget _buildGroup(SystemConfigGroup group) {
    final expanded = _expandedGroups.contains(group.group);
    final surfaces = context.surfaces;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppCard(
          padding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: AppSpacing.md,
          ),
          onTap: () => setState(() {
            if (expanded) {
              _expandedGroups.remove(group.group);
            } else {
              _expandedGroups.add(group.group);
            }
          }),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  group.label,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '${group.items.length} 项',
                style: TextStyle(fontSize: 11, color: surfaces.mutedText),
              ),
              const SizedBox(width: AppSpacing.sm),
              Icon(
                expanded
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
                size: 20,
                color: surfaces.mutedText,
              ),
            ],
          ),
        ),
        if (expanded) ...[
          const SizedBox(height: AppSpacing.sm),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < group.items.length; i++) ...[
                  if (i > 0) const SizedBox(height: 14),
                  _buildConfigField(group.items[i]),
                ],
              ],
            ),
          ),
        ],
      ],
    );
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
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.pageHorizontal,
              ),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => context.pop(),
                    child: const Icon(Icons.arrow_back_ios, size: 20),
                  ),
                  const SizedBox(width: AppSpacing.sm),
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
            const SizedBox(height: AppSpacing.lg),
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
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.pageHorizontal,
                          0,
                          AppSpacing.pageHorizontal,
                          AppSpacing.xxl,
                        ),
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
                            const SizedBox(height: AppSpacing.sm),
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
                                      const SizedBox(height: AppSpacing.sm),
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
                                      const SizedBox(height: AppSpacing.md),
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

                          const SizedBox(height: AppSpacing.xl),

                          if (_updateStatus != null &&
                              (_updateStatus?['status']?.toString().trim().isNotEmpty ??
                                  false) &&
                              _updateStatus?['status'] != 'idle') ...[
                            const AppSectionTitle('更新状态'),
                            const SizedBox(height: AppSpacing.sm),
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
                                  const SizedBox(height: AppSpacing.sm),
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
                                    const SizedBox(height: AppSpacing.xs),
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
                                  const SizedBox(height: AppSpacing.md),
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
                            const SizedBox(height: AppSpacing.xl),
                          ],

                          // ── 系统配置（schema 驱动）──
                          const AppSectionTitle('系统配置'),
                          const SizedBox(height: AppSpacing.sm),
                          if (_configError != null) ...[
                            AppNotice(
                              color: AppColors.danger,
                              icon: Icons.error_outline,
                              text: '$_configError\n下拉可重试。',
                            ),
                            const SizedBox(height: AppSpacing.sm),
                          ],
                          for (final group in _groups) ...[
                            _buildGroup(group),
                            const SizedBox(height: AppSpacing.sm),
                          ],
                          if (_groups.isNotEmpty) ...[
                            const SizedBox(height: AppSpacing.sm),
                            SizedBox(
                              width: double.infinity,
                              height: 44,
                              child: FilledButton(
                                onPressed: _savingConfigs ? null : _saveConfigs,
                                child: Text(
                                  _savingConfigs ? '保存中...' : '保存配置',
                                ),
                              ),
                            ),
                          ],

                          const SizedBox(height: AppSpacing.xxl),

                          // ── 系统操作 ──
                          const AppSectionTitle('系统操作'),
                          const SizedBox(height: AppSpacing.sm),
                          _ActionBtn(
                            icon: Icons.backup,
                            title: '备份恢复',
                            subtitle: '创建备份、恢复、管理备份文件',
                            isLight: isLight,
                            onTap: () => context.push('/backup'),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          _ActionBtn(
                            icon: Icons.article_outlined,
                            title: '面板日志',
                            subtitle: '查看面板运行日志，支持级别与关键字筛选',
                            isLight: isLight,
                            onTap: () => context.push('/panel-log'),
                          ),
                          const SizedBox(height: AppSpacing.sm),
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
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Icon(
            icon,
            size: 20,
            color: danger ? AppColors.red500 : AppColors.primary,
          ),
          const SizedBox(width: AppSpacing.md),
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
    );
  }
}
