import 'package:flutter/material.dart';

import '../../core/network/api_endpoints.dart';
import '../../core/network/dio_client.dart';
import '../../core/theme/app_theme.dart';
import 'api_utils.dart';

class LogSurfaceTheme {
  final Color background;
  final Color foreground;
  final Color mutedForeground;
  final Brightness brightness;

  const LogSurfaceTheme({
    required this.background,
    required this.foreground,
    required this.mutedForeground,
    required this.brightness,
  });
}

Future<Color?> loadPanelLogBackgroundColor() =>
    loadPanelColorSetting('log_background_color');

/// 从面板公开设置里取一个颜色配置项。
///
/// 日志底色（log_background_color）与脚本编辑器底色（editor_background_color）
/// 取数与解析完全同一套，只有键名不同 —— 别再各自复制一份解析器。
///
/// 拿不到时返回 null，由调用方按主题回落（见 [resolveLogSurfaceTheme]）。
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

/// 把「面板配的日志底色」解析成一整套日志表面配色。
///
/// [themeBrightness] 必须传当前主题亮度（`Theme.of(context).brightness`）。
/// 之所以做成必填而不是可选带默认值：面板留空时的兜底色必须跟随明暗，
/// 给默认值会让漏改的调用点静默退回「深色模式白底」那个 bug（issue #2）。
LogSurfaceTheme resolveLogSurfaceTheme(
  Color? configuredColor, {
  required Brightness themeBrightness,
}) {
  // 面板契约：log_background_color 留空 = 跟随当前主题。
  // 用户显式配了颜色就一律听用户的，哪怕它和当前主题“撞色”。
  final background =
      configuredColor ??
      (themeBrightness == Brightness.dark
          ? AppColors.termBgDark
          : AppColors.termBgLight);
  // 前景色一律从「最终底色」的亮度推，不要改成主题文字色 —— 面板 v3.0.10 修 issue #104
  // 时踩过这个坑：深灰字压在深色底上，全糊。
  final brightness = ThemeData.estimateBrightnessForColor(background);
  final isDark = brightness == Brightness.dark;

  return LogSurfaceTheme(
    background: background,
    foreground: isDark ? AppColors.slate50 : AppColors.slate900,
    mutedForeground: isDark ? AppColors.slate300 : AppColors.slate500,
    brightness: brightness,
  );
}
