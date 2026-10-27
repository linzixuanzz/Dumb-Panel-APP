import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../shared/widgets/app_snack.dart';
import '../network/app_user_agent.dart';
import '../theme/app_theme.dart';

const _kGitHubRepo = 'linzixuanzz/Dumb-Panel-APP';
const _kGitHubDownloadHost = 'github.com';
const _kGitHubReleaseHost = 'objects.githubusercontent.com';
const _kGitHubAssetHost = 'githubusercontent.com';
const _kGitHubMirrorHost = 'gh.301.ee';
const _kGitHubMirrorPrefix = 'https://$_kGitHubMirrorHost/';

// 自动更新提醒的两个本地偏好（issue #19）：应用级、不分面板，所以直接放 SharedPreferences
const _kAutoRemindKey = 'app_update_auto_remind';
const _kIgnoredVersionKey = 'app_update_ignored_version';

bool _isTrustedDownloadUrl(String rawUrl) {
  final uri = Uri.tryParse(rawUrl);
  if (uri == null || uri.scheme != 'https') {
    return false;
  }
  final host = uri.host.toLowerCase();
  return host == _kGitHubDownloadHost ||
      host == _kGitHubReleaseHost ||
      host == _kGitHubMirrorHost ||
      host.endsWith('.$_kGitHubAssetHost');
}

String _applyGitHubMirror(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  final host = uri.host.toLowerCase();
  if (host == _kGitHubDownloadHost || host.endsWith('.$_kGitHubAssetHost')) {
    return '$_kGitHubMirrorPrefix$url';
  }
  return url;
}

/// 原生侧安装失败的 code → 中文文案。
///
/// 键必须与 `MainActivity.kt` 的 `InstallException.code` 一一对应，漏一个只会退化成
/// 显示英文原文（可接受的降级）。`NO_INSTALLER` 放第一位 —— 它是 issue #11 那位用户
/// 唯一会撞上的那条（v1.3.7）。
const _installErrorText = {
  'NO_INSTALLER': '系统没有找到可用的安装器。请到通知栏或文件管理器里手动打开刚下载的安装包，'
      '或先在系统设置里恢复「软件包安装程序」。',
  'NEED_UNKNOWN_SOURCE': '需要先允许「呆呆面板」安装未知应用。已为你打开设置页，授权后回到这里再点一次。',
  'VERIFY_FAILED': '安装包校验未通过，可能下载不完整，请点「重新下载」。',
  'FILE_MISSING': '安装包已被系统清理，请点「重新下载」。',
  'PATH_NOT_ALLOWED': '安装包位置异常，请点「重新下载」。',
  'UNTRUSTED_SOURCE': '更新来源不可信，已拒绝安装。',
  'SESSION_FAILED': '系统安装会话失败，可能是存储空间不足或被系统限制，请重试或手动安装。',
};

/// 内置安装失败，且原因已经翻译成能直接说给用户听的中文。
///
/// 单独立一个类型（写法照 `raw_log_download.dart` 的 `RawLogDownloadException`），
/// 是为了让弹窗能区分「下载阶段失败」和「安装阶段失败」—— 这两者原先挤在同一个
/// catch 里，安装异常被贴上「下载失败: 」前缀，把 issue #11 的排查方向整个带偏了。
class AppInstallException implements Exception {
  const AppInstallException(this.message, {this.code, this.detail});

  final String message;

  /// 原生侧的错误码，用来决定重试按钮给「重新下载」还是「重试安装」。
  final String? code;

  /// 未经翻译的原始异常文本，给「复制错误详情」按钮用。
  final String? detail;

  @override
  String toString() => message;
}

class AppUpdateInfo {
  final String latestVersion;
  final String currentVersion;
  final String releaseNotes;
  final String downloadUrl;
  final String assetName;
  final bool hasUpdate;

  const AppUpdateInfo({
    required this.latestVersion,
    required this.currentVersion,
    required this.releaseNotes,
    required this.downloadUrl,
    required this.assetName,
    required this.hasUpdate,
  });
}

class AppUpdateService {
  AppUpdateService._();

  static final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
    validateStatus: (status) => status != null && status < 400,
  ));

  static const _platform = MethodChannel('com.daidai.panel/app_install');

  /// 本次启动是否已经做过自动检查。进程级标记：首页重建、切回首页都不会再弹（issue #19）。
  static bool _autoCheckedThisLaunch = false;

  @visibleForTesting
  static void resetAutoCheckForTest() => _autoCheckedThisLaunch = false;

  /// 测试用：替换自动检查里的网络请求。[autoCheckAndPrompt] 的调用方（MainScaffold）
  /// 不方便传 `check` 参数，测试就从这里注入；正常运行时始终为 null。
  @visibleForTesting
  static Future<AppUpdateInfo?> Function()? checkOverrideForTest;

  /// 「自动提醒更新」开关，没设过时默认开着。
  static Future<bool> getAutoRemindEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kAutoRemindKey) ?? true;
  }

  static Future<void> setAutoRemindEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoRemindKey, enabled);
  }

  /// 进入主界面时的静默检查（v1.4.4 起由 MainScaffold 首次构建触发，与默认打开页面无关）：
  /// 每次启动最多弹一次，且尊重「忽略此版本」「不再自动提醒」。
  /// 手动「检查更新」不走这里，不受这两项影响。
  ///
  /// [check] 只给测试替换网络请求用，正常调用不传。
  static Future<void> autoCheckAndPrompt(
    BuildContext context, {
    Future<AppUpdateInfo?> Function()? check,
  }) async {
    // 一进来就打标记：哪怕这次没网检查失败，本次启动也不再反复请求 GitHub
    if (_autoCheckedThisLaunch) return;
    _autoCheckedThisLaunch = true;
    try {
      if (!await getAutoRemindEnabled()) return;
      final info = await (check ?? checkOverrideForTest ?? checkUpdate)();
      if (info == null || !info.hasUpdate) return;
      final prefs = await SharedPreferences.getInstance();
      // 只有和被忽略的版本号完全相同才跳过，出了更新的版本照常提示
      if (prefs.getString(_kIgnoredVersionKey) == info.latestVersion) return;
      if (!context.mounted) return;
      await showUpdateDialog(context, info, fromAutoCheck: true);
    } catch (_) {
      // 静默检查失败不打扰用户
    }
  }

  /// Check GitHub Releases for new version.
  static Future<AppUpdateInfo?> checkUpdate() async {
    try {
      final resp = await _dio.get(
        'https://api.github.com/repos/$_kGitHubRepo/releases/latest',
        options: Options(headers: {'Accept': 'application/vnd.github.v3+json'}),
      );
      final data = resp.data;
      if (data is! Map<String, dynamic>) return null;

      final tagName = (data['tag_name'] as String?)?.replaceFirst('v', '') ?? '';
      final body = data['body']?.toString() ?? '';
      final assets = data['assets'];

      String apkUrl = '';
      String assetName = '';
      if (assets is List) {
        for (final asset in assets) {
          final name = asset['name']?.toString() ?? '';
          if (name.endsWith('.apk')) {
            final rawUrl = asset['browser_download_url']?.toString() ?? '';
            if (_isTrustedDownloadUrl(rawUrl)) {
              apkUrl = rawUrl;
              assetName = name;
              break;
            }
          }
        }
      }

      final currentVersion = AppUserAgent.versionLabel.split('+').first;
      final hasUpdate = tagName.isNotEmpty && _isNewer(tagName, currentVersion);

      return AppUpdateInfo(
        latestVersion: tagName,
        currentVersion: currentVersion,
        releaseNotes: body,
        downloadUrl: apkUrl,
        assetName: assetName,
        hasUpdate: hasUpdate,
      );
    } catch (_) {
      return null;
    }
  }

  /// Compare semantic versions: returns true if remote > local.
  static bool _isNewer(String remote, String local) {
    final r = remote.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final l = local.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    while (r.length < 3) {
      r.add(0);
    }
    while (l.length < 3) {
      l.add(0);
    }
    for (int i = 0; i < 3; i++) {
      if (r[i] > l[i]) return true;
      if (r[i] < l[i]) return false;
    }
    return false;
  }

  /// Download APK and install it.
  /// Uses GitHub mirror for acceleration and reuses existing downloads.
  ///
  /// 下载与安装是两段，失败必须分开报：安装阶段的异常走 [onInstallError]，
  /// 不能再和下载异常挤在同一个 catch 里被贴上「下载失败」前缀 —— issue #11 就是被
  /// 这个前缀带偏的，用户和维护者都以为是下载坏了，实际下载完全成功（v1.3.7）。
  ///
  /// [forceRedownload] 为真时先把已下载的包和旁文件删掉再重来，对应弹窗上的「重新下载」。
  static Future<void> downloadAndInstall(
    String url,
    String assetName,
    ValueChanged<double> onProgress,
    VoidCallback onDone,
    ValueChanged<String> onError, {
    required ValueChanged<AppInstallException> onInstallError,
    bool forceRedownload = false,
  }) async {
    String filePath = '';

    try {
      if (!_isTrustedDownloadUrl(url)) {
        throw const FormatException('更新地址不可信，已拒绝下载');
      }

      final dir = await getTemporaryDirectory();
      final safeName = assetName.trim().isEmpty
          ? 'daidai_update.apk'
          : assetName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      filePath = '${dir.path}/$safeName';

      final existingFile = File(filePath);
      // 旁文件只记「下载成功那一刻的字节数」。原先复用的唯一依据是「文件 > 1MB」，
      // 下载途中进程被杀（用户划掉 APP / OOM）留下的半截包会被一直复用，装不上也不自愈。
      final stampFile = File('$filePath.ok');
      bool needsDownload = true;

      if (!forceRedownload &&
          await existingFile.exists() &&
          await stampFile.exists()) {
        final recorded = int.tryParse((await stampFile.readAsString()).trim());
        if (recorded != null &&
            recorded > 0 &&
            await existingFile.length() == recorded) {
          needsDownload = false;
          onProgress(1.0);
        }
      }

      if (needsDownload) {
        // 先把旧包和旧旁文件一起清掉，避免「新包下到一半失败、旧旁文件还在」的错配
        if (await stampFile.exists()) {
          await stampFile.delete();
        }
        if (await existingFile.exists()) {
          await existingFile.delete();
        }

        final downloadUrl = _applyGitHubMirror(url);

        final response = await _dio.download(
          downloadUrl,
          filePath,
          onReceiveProgress: (received, total) {
            if (total > 0) {
              onProgress(received / total);
            }
          },
          options: Options(receiveTimeout: const Duration(minutes: 10)),
        );
        final finalHost = response.realUri.host.toLowerCase();
        if (!(_isTrustedDownloadUrl(response.realUri.toString()) ||
            finalHost == _kGitHubReleaseHost ||
            finalHost == _kGitHubMirrorHost ||
            finalHost.endsWith('.$_kGitHubAssetHost'))) {
          throw const FormatException('更新资源跳转到了不受信任的来源');
        }

        // 只有走到这里才算下载完整，旁文件必须最后写
        await stampFile.writeAsString('${await existingFile.length()}');
      }
    } catch (e) {
      debugPrint('[update] download failed: $e');
      onError(e.toString());
      return;
    }

    if (!Platform.isAndroid) {
      onDone();
      return;
    }

    try {
      final originalHost = Uri.parse(url).host.toLowerCase();
      await _platform.invokeMethod('installApk', {
        'path': filePath,
        'sourceHost': originalHost,
      });
      // 原生侧的 result 要等系统回了会话状态才结，所以走到这里说明安装确认界面
      // 已经弹出来了，此时才算这次更新交接完成
      onDone();
    } on PlatformException catch (e) {
      debugPrint('[update] install failed: $e');
      onInstallError(AppInstallException(
        _installErrorText[e.code] ?? e.message ?? '安装失败',
        code: e.code,
        detail: e.toString(),
      ));
    } catch (e) {
      debugPrint('[update] install failed: $e');
      onInstallError(AppInstallException('安装失败：$e', detail: e.toString()));
    }
  }

  /// 打开系统的「安装未知应用」授权页，失败返回 false 由调用方给兜底提示。
  static Future<bool> openUnknownSourceSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      await _platform.invokeMethod('openUnknownSourceSettings');
      return true;
    } catch (e) {
      debugPrint('[update] open unknown source settings failed: $e');
      return false;
    }
  }

  /// Show update dialog.
  ///
  /// [fromAutoCheck] 为真时（首页自动弹出）才多给「忽略此版本」「不再自动提醒」两个选项。
  static Future<void> showUpdateDialog(
    BuildContext context,
    AppUpdateInfo info, {
    bool fromAutoCheck = false,
  }) async {
    if (!context.mounted) return;
    final isLight = Theme.of(context).brightness == Brightness.light;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => _UpdateDialog(
        info: info,
        isLight: isLight,
        fromAutoCheck: fromAutoCheck,
      ),
    );
  }
}

class _UpdateDialog extends StatefulWidget {
  final AppUpdateInfo info;
  final bool isLight;
  final bool fromAutoCheck;
  const _UpdateDialog({
    required this.info,
    required this.isLight,
    this.fromAutoCheck = false,
  });

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool _downloading = false;
  double _progress = 0;
  String? _error;
  // 原始异常文本与原生错误码分开存：前者给「复制错误详情」，后者决定重试按钮的形态
  String? _errorDetail;
  String? _installCode;
  bool _copied = false;

  void _startDownload({bool force = false}) {
    if (widget.info.downloadUrl.isEmpty) {
      setState(() => _error = '未找到 APK 下载链接');
      return;
    }
    setState(() {
      _downloading = true;
      _progress = 0;
      _error = null;
      _errorDetail = null;
      _installCode = null;
      _copied = false;
    });

    AppUpdateService.downloadAndInstall(
      widget.info.downloadUrl,
      widget.info.assetName,
      (p) {
        if (mounted) setState(() => _progress = p);
      },
      () {
        // 安装确认界面已经交给系统了，这里把更新弹窗收起来，免得用户重复点「立即更新」
        if (mounted) Navigator.of(context).pop();
      },
      (e) {
        if (mounted) {
          setState(() {
            _downloading = false;
            _error = '下载失败: $e';
            _errorDetail = e;
          });
        }
      },
      onInstallError: (e) {
        if (mounted) {
          setState(() {
            _downloading = false;
            _error = e.message;
            _errorDetail = e.detail;
            _installCode = e.code;
          });
        }
      },
      forceRedownload: force,
    );
  }

  /// 要不要重下整个包。
  ///
  /// 安装阶段失败时包本身通常是好的（权限没开、安装器拉不起、会话失败），
  /// 再拉一次几十 MB 纯属浪费；只有下载阶段失败或包真有问题才重下。
  bool get _needsRedownload =>
      _installCode == null ||
      _installCode == 'VERIFY_FAILED' ||
      _installCode == 'FILE_MISSING' ||
      _installCode == 'PATH_NOT_ALLOWED';

  Future<void> _openUnknownSourceSettings() async {
    final ok = await AppUpdateService.openUnknownSourceSettings();
    if (!mounted || ok) return;
    setState(() {
      _error = '打不开系统设置页，请手动到「设置 → 应用 → 特殊权限 → 安装未知应用」里允许呆呆面板。';
    });
  }

  Future<void> _ignoreThisVersion() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kIgnoredVersionKey, widget.info.latestVersion);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _disableAutoRemind() async {
    await AppUpdateService.setAutoRemindEnabled(false);
    if (!mounted) return;
    // 弹窗关掉前先拿到外层页面，告诉用户去哪儿重新打开
    final messengerContext = Navigator.of(context).context;
    Navigator.of(context).pop();
    if (messengerContext.mounted) {
      AppSnack.show(messengerContext, '已关闭自动提醒，可在「设置 → 自动提醒更新」重新打开');
    }
  }

  Future<void> _copyErrorDetail() async {
    // 有原始异常就复制原始异常：下次提 issue 能直接贴文本，不用再靠截图认字
    await Clipboard.setData(ClipboardData(text: _errorDetail ?? _error ?? ''));
    if (!mounted) return;
    setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final isAndroid = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

    return AlertDialog(
      title: const Text('发现新版本'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'v${widget.info.currentVersion}',
                style: TextStyle(
                  fontSize: 13,
                  color: widget.isLight
                      ? AppColors.slate500
                      : AppColors.slate400,
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Icon(Icons.arrow_forward, size: 14),
              ),
              Text(
                'v${widget.info.latestVersion}',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
          if (widget.info.releaseNotes.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text(
              '更新内容',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: SingleChildScrollView(
                child: Text(
                  widget.info.releaseNotes,
                  style: TextStyle(
                    fontSize: 12,
                    color: widget.isLight
                        ? AppColors.slate600
                        : AppColors.slate300,
                    height: 1.5,
                  ),
                ),
              ),
            ),
          ],
          if (_downloading) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(
              value: _progress,
              color: AppColors.primary,
              backgroundColor: widget.isLight
                  ? AppColors.slate200
                  : AppColors.slate800,
            ),
            const SizedBox(height: 6),
            Center(
              child: Text(
                // 进度条满格但弹窗还在，说明正卡在「把安装交给系统」这一步
                _progress >= 1
                    ? '正在安装…'
                    : '下载中 ${(_progress * 100).toStringAsFixed(0)}%',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: const TextStyle(fontSize: 12, color: AppColors.red500),
            ),
          ] else ...[
            const SizedBox(height: 12),
            Text(
              // 原文承诺「已下载的安装包会自动复用」，安装失败时格外误导（issue #11）
              '更新包通过 GitHub 加速镜像下载，校验包名与签名后交给系统安装。若安装失败，可按提示重试或去开启安装权限。',
              style: TextStyle(
                fontSize: 12,
                color: widget.isLight
                    ? AppColors.slate600
                    : AppColors.slate300,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
      actions: _downloading
          ? null
          : [
              // 失败态才出现的两个出路：一个去开权限，一个把报错原文捞出来
              if (_error != null)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton(
                      onPressed: _openUnknownSourceSettings,
                      child: const Text(
                        '去开启权限',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                    TextButton(
                      onPressed: _copied ? null : _copyErrorDetail,
                      child: Text(
                        _copied ? '已复制' : '复制错误详情',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('稍后'),
                      ),
                    ),
                  ),
                  if (isAndroid && widget.info.downloadUrl.isNotEmpty) ...[
                    const SizedBox(width: 12),
                    Expanded(
                      child: SizedBox(
                        height: 44,
                        child: FilledButton(
                          onPressed: () => _startDownload(
                            force: _error != null && _needsRedownload,
                          ),
                          child: Text(
                            _error == null
                                ? '立即更新'
                                : (_needsRedownload ? '重新下载' : '重试安装'),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              // 只有自动弹出时才有：两个都做成小号文字按钮放一行，小屏也放得下
              if (widget.fromAutoCheck)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton(
                      onPressed: _ignoreThisVersion,
                      child: const Text(
                        '忽略此版本',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                    TextButton(
                      onPressed: _disableAutoRemind,
                      child: const Text(
                        '不再自动提醒',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
            ],
    );
  }
}
