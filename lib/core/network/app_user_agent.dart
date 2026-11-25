import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

class AppUserAgent {
  AppUserAgent._();

  static String _userAgent = _fallbackUserAgent;
  static String _platform = _detectPlatform();
  static String _version = 'unknown';
  static String _buildNumber = '';
  static String _deviceModel = '';
  static String _deviceName = '';
  static String _osVersion = '';

  static String get value => _userAgent;

  static Map<String, String> get defaultHeaders => {
    // 网页版不带 User-Agent：浏览器禁止脚本改这个头，每个请求都会报一条
    // 「Refused to set unsafe header "User-Agent"」，而且实际发出去的仍是浏览器自己的 UA。
    // 少了它服务端看到的内容不变，客户端身份照样靠下面的 X-Client-* 识别。
    if (!kIsWeb) 'User-Agent': _userAgent,
    'X-Client-App': 'daidai-panel-app',
    'X-Client-Type': 'app',
    'X-Client-Platform': _platform,
    'X-Client-Version': versionLabel,
    if (_deviceModel.isNotEmpty) 'X-Device-Model': _deviceModel,
    if (_deviceName.isNotEmpty) 'X-Device-Name': _deviceName,
    if (_osVersion.isNotEmpty) 'X-OS-Version': _osVersion,
  };

  static String get versionLabel =>
      _buildNumber.isEmpty ? _version : '$_version+$_buildNumber';

  static Future<void> initialize() async {
    _platform = _detectPlatform();

    try {
      final info = await PackageInfo.fromPlatform();
      _version = info.version.trim().isEmpty ? 'unknown' : info.version.trim();
      _buildNumber = info.buildNumber.trim();
    } catch (_) {
      _version = 'unknown';
      _buildNumber = '';
    }

    await _loadDeviceInfo();
    _userAgent = _buildUserAgent();
  }

  static String _buildUserAgent() {
    final detail = _buildDetailSegments();
    switch (_platform) {
      case 'android':
        return 'DaidaiPanelApp/$versionLabel ($detail; Flutter)';
      case 'ios':
        return 'DaidaiPanelApp/$versionLabel ($detail; Flutter)';
      case 'macos':
        return 'DaidaiPanelApp/$versionLabel ($detail; Flutter)';
      case 'windows':
        return 'DaidaiPanelApp/$versionLabel ($detail; Flutter)';
      case 'linux':
        return 'DaidaiPanelApp/$versionLabel ($detail; Flutter)';
      case 'web':
        return 'DaidaiPanelApp/$versionLabel ($detail; Flutter)';
      default:
        return _fallbackUserAgent;
    }
  }

  static Future<void> _loadDeviceInfo() async {
    _deviceModel = '';
    _deviceName = '';
    _osVersion = '';

    if (kIsWeb) {
      return;
    }

    final plugin = DeviceInfoPlugin();
    try {
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          final info = await plugin.androidInfo;
          _deviceModel = _mergeAndroidBrandAndModel(
            info.manufacturer,
            info.model,
          );
          _deviceName = info.device.trim();
          _osVersion = info.version.release.trim();
          return;
        case TargetPlatform.iOS:
          final info = await plugin.iosInfo;
          final machine = info.utsname.machine.trim();
          _deviceModel = machine.isNotEmpty ? machine : info.model.trim();
          _deviceName = info.name.trim();
          _osVersion = info.systemVersion.trim();
          return;
        case TargetPlatform.macOS:
          final info = await plugin.macOsInfo;
          _deviceModel = info.model.trim();
          _deviceName = info.computerName.trim();
          _osVersion = info.osRelease.trim();
          return;
        case TargetPlatform.windows:
          final info = await plugin.windowsInfo;
          _deviceModel = info.productName.trim();
          _deviceName = info.computerName.trim();
          _osVersion = info.displayVersion.trim();
          return;
        case TargetPlatform.linux:
          final info = await plugin.linuxInfo;
          _deviceModel = info.prettyName.trim();
          _deviceName = info.name.trim();
          _osVersion = info.version?.trim() ?? '';
          return;
        case TargetPlatform.fuchsia:
          return;
      }
    } catch (_) {
      _deviceModel = '';
      _deviceName = '';
      _osVersion = '';
    }
  }

  static String _buildDetailSegments() {
    final parts = <String>[];
    final platformLabel = _platformLabel();
    if (platformLabel.isNotEmpty) {
      parts.add(platformLabel);
    }
    if (_deviceModel.isNotEmpty) {
      parts.add(_deviceModel);
    } else if (_deviceName.isNotEmpty) {
      parts.add(_deviceName);
    }
    return parts.join('; ');
  }

  static String _platformLabel() {
    switch (_platform) {
      case 'android':
        return _osVersion.isEmpty ? 'Android' : 'Android $_osVersion';
      case 'ios':
        return _osVersion.isEmpty ? 'iOS' : 'iOS $_osVersion';
      case 'macos':
        return _osVersion.isEmpty ? 'macOS' : 'macOS $_osVersion';
      case 'windows':
        return _osVersion.isEmpty ? 'Windows' : 'Windows $_osVersion';
      case 'linux':
        return _osVersion.isEmpty ? 'Linux' : 'Linux $_osVersion';
      case 'web':
        return 'Web';
      default:
        return '';
    }
  }

  static String _mergeAndroidBrandAndModel(String manufacturer, String model) {
    final maker = manufacturer.trim();
    final deviceModel = model.trim();
    if (maker.isEmpty) {
      return deviceModel;
    }
    if (deviceModel.isEmpty) {
      return maker;
    }
    final makerLower = maker.toLowerCase();
    final modelLower = deviceModel.toLowerCase();
    if (modelLower.startsWith(makerLower)) {
      return deviceModel;
    }
    return '$maker $deviceModel';
  }

  static String _detectPlatform() {
    if (kIsWeb) {
      return 'web';
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.linux:
        return 'linux';
      case TargetPlatform.fuchsia:
        return 'fuchsia';
    }
  }

  static const String _fallbackUserAgent = 'DaidaiPanelApp/unknown (Flutter)';
}
