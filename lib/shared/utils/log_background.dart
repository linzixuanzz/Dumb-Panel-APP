import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/network/api_endpoints.dart';
import '../../core/network/dio_client.dart';
import '../../core/theme/app_theme.dart';
import 'api_utils.dart';

class LogSurfaceTheme {
  final Color background;
  final Color foreground;
  final Color mutedForeground;
  final Color divider;
  final Color barBackground;
  final Brightness brightness;

  const LogSurfaceTheme({
    required this.background,
    required this.foreground,
    required this.mutedForeground,
    required this.divider,
    required this.barBackground,
    required this.brightness,
  });

  bool get isDark => brightness == Brightness.dark;
}

/// 独立「护眼暗底终端（`#14161A`）」本机偏好键（方案 1 全屏日志专项能力）。
const String kLogNightTerminalPrefsKey = 'app_log_night_terminal';
const String kLogShowLineNumbersPrefsKey = 'app_log_show_line_numbers';
const String kLogSoftWrapPrefsKey = 'app_log_soft_wrap';

/// 读取本机保存的日志阅读器偏好（护眼暗底 / 行号 / 自动换行）。
Future<({bool nightTerminal, bool showLineNumbers, bool softWrap})>
loadLogReaderPreferences() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return (
      nightTerminal: prefs.getBool(kLogNightTerminalPrefsKey) ?? false,
      showLineNumbers: prefs.getBool(kLogShowLineNumbersPrefsKey) ?? false,
      softWrap: prefs.getBool(kLogSoftWrapPrefsKey) ?? true,
    );
  } catch (_) {
    return (nightTerminal: false, showLineNumbers: false, softWrap: true);
  }
}

Future<void> saveLogNightTerminalPreference(bool enabled) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kLogNightTerminalPrefsKey, enabled);
  } catch (_) {}
}

Future<void> saveLogShowLineNumbersPreference(bool enabled) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kLogShowLineNumbersPrefsKey, enabled);
  } catch (_) {}
}

Future<void> saveLogSoftWrapPreference(bool enabled) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kLogSoftWrapPrefsKey, enabled);
  } catch (_) {}
}

Future<Color?> loadPanelLogBackgroundColor() =>
    loadPanelColorSetting('log_background_color');

/// 从面板公开设置里取一个颜色配置项。
Future<Color?> loadPanelColorSetting(String key) async {
  try {
    final response = await DioClient.instance.dio.get(
      ApiEndpoints.panelSettings,
    );
    final data = extractData(response.data);
    if (data is! Map) {
      return null;
    }
    return parseColorSetting(data[key]?.toString());
  } catch (_) {
    return null;
  }
}

Color? parseColorSetting(String? raw) {
  final text = raw?.trim() ?? '';
  if (text.isEmpty) {
    return null;
  }

  if (text.startsWith('#')) {
    final hex = text.substring(1);
    if (hex.length == 6) {
      final value = int.tryParse(hex, radix: 16);
      if (value != null) {
        return Color(0xFF000000 | value);
      }
    }
    if (hex.length == 8) {
      final value = int.tryParse(hex, radix: 16);
      if (value != null) {
        return Color(value);
      }
    }
  }

  final rgb = RegExp(
    r'^rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})(?:\s*,\s*([0-9]*\.?[0-9]+))?\s*\)$',
    caseSensitive: false,
  ).firstMatch(text);
  if (rgb != null) {
    final r = int.tryParse(rgb.group(1) ?? '');
    final g = int.tryParse(rgb.group(2) ?? '');
    final b = int.tryParse(rgb.group(3) ?? '');
    final alphaText = rgb.group(4);
    if (r != null && g != null && b != null) {
      final opacity = alphaText == null
          ? 1.0
          : (double.tryParse(alphaText) ?? 1.0).clamp(0.0, 1.0);
      return Color.fromRGBO(
        r.clamp(0, 255),
        g.clamp(0, 255),
        b.clamp(0, 255),
        opacity,
      );
    }
  }

  return null;
}

/// 解析日志表面配色：
/// - 若用户在全屏日志页主动开启了 [forceNightTerminal]，优先使用 `#14161A` 护眼深邃终端底；
/// - 否则若面板配置了 `log_background_color`，遵循面板自定义底色；
/// - 留空时默认浅色为 `#FAF9F6` 暖纸底、深色为 `#14161A` 护眼暗底。
LogSurfaceTheme resolveLogSurfaceTheme(
  Color? configuredColor, {
  required Brightness themeBrightness,
  bool forceNightTerminal = false,
}) {
  final background = forceNightTerminal
      ? AppColors.termBgDark
      : (configuredColor ??
            (themeBrightness == Brightness.dark
                ? AppColors.termBgDark
                : AppColors.termBgLight));
  final brightness = ThemeData.estimateBrightnessForColor(background);
  final isDark = brightness == Brightness.dark;

  return LogSurfaceTheme(
    background: background,
    foreground: isDark ? const Color(0xFFE7E5E4) : const Color(0xFF1C1917),
    mutedForeground: isDark ? const Color(0xFF8A8F98) : const Color(0xFF78716C),
    divider: isDark ? const Color(0x14FFFFFF) : const Color(0x121C1917),
    barBackground: isDark
        ? Color.alphaBlend(const Color(0x0AFFFFFF), background)
        : Color.alphaBlend(const Color(0x061C1917), background),
    brightness: brightness,
  );
}
