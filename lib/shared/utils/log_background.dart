import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/network/api_endpoints.dart';
import '../../core/network/dio_client.dart';
import '../../core/theme/app_palette.dart';
import '../../core/theme/app_theme.dart';
import 'api_utils.dart';

/// 日志页文字的最低对比度：WCAG AA 正文 4.5:1。
///
/// 日志页的次要文字（行数、空态、搜索计数、状态胶囊）都是 11.5~13.5 号，
/// 够不到「大字号」那一档，按正文算。
const double kLogMinTextContrast = 4.5;

/// 两个颜色的 WCAG 2.x 对比度（1~21）。只看 RGB，不看透明度。
double logContrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// 把 [color] 朝 [toward] 一步步挪，直到压在 [on] 里每一个底色上都够
/// [minRatio]；挪到头还不够就直接给 [toward]。
///
/// 日志底色是面板用户自己配的（`log_background_color`），设计稿只在默认底色上
/// 量过对比度。写死一个灰，换到 One Dark `#282C34`、Nord `#2E3440` 这类偏灰的
/// 深底上就只剩 2~3:1。朝主前景色挪而不是一律换成主前景色：默认底色上一步都
/// 不用挪，设计稿的颜色原样保留；只有不够读的自定义底色才会被提亮 / 压暗。
Color ensureLogContrast(
  Color color, {
  required Iterable<Color> on,
  required Color toward,
  double minRatio = kLogMinTextContrast,
}) {
  const steps = 20;
  for (var step = 0; step <= steps; step++) {
    final candidate = step == 0
        ? color
        : Color.lerp(color, toward, step / steps)!;
    final readable = on.every(
      (surface) => logContrastRatio(candidate, surface) >= minRatio,
    );
    if (readable) {
      return candidate;
    }
  }
  return toward;
}

class LogSurfaceTheme {
  final Color background;
  final Color foreground;

  /// 次要文字色。已保证压在 [background] 与 [barBackground] 上都 ≥ 4.5:1；
  /// 压在别的底（搜索框、胶囊的半透明填充）上时用 [readable] 再校一次。
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

  /// [color] 压在 [on] 上不到 4.5:1 时，朝 [foreground] 挪到刚好够读为止。
  ///
  /// 给叠了半透明填充的底用（搜索框、状态胶囊、底栏芯片）：[on] 要传
  /// 合成之后的实色，例如 `Color.alphaBlend(fill, barBackground)`。
  Color readable(Color color, {required Color on}) =>
      ensureLogContrast(color, on: [on], toward: foreground);
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
/// - 用户在全屏日志页开了 [forceNightTerminal]：一律 `#14161A` 护眼暗底；
/// - 否则面板配了 `log_background_color` 就听面板的；
/// - 留空时按主题回落：浅色 `#FAF9F6` 暖纸底、深色 `#14161A` 护眼暗底。
///
/// [themeBrightness] 必须传当前主题亮度（`Theme.of(context).brightness`）。
/// 之所以做成必填而不是可选带默认值：面板留空时的兜底色必须跟随明暗，
/// 给默认值会让漏改的调用点静默退回「深色模式白底」那个 bug（issue #2）。
LogSurfaceTheme resolveLogSurfaceTheme(
  Color? configuredColor, {
  required Brightness themeBrightness,
  bool forceNightTerminal = false,
}) {
  // 面板契约：log_background_color 留空 = 跟随当前主题。
  // 用户显式配了颜色就一律听用户的，哪怕它和当前主题“撞色”。
  final background = forceNightTerminal
      ? AppColors.termBgDark
      : (configuredColor ??
            (themeBrightness == Brightness.dark
                ? AppColors.termBgDark
                : AppColors.termBgLight));
  // 前景色一律从「最终底色」的亮度推，不要改成主题文字色 —— 面板 v3.0.10 修 issue #104
  // 时踩过这个坑：深灰字压在深色底上，全糊。
  final brightness = ThemeData.estimateBrightnessForColor(background);
  final isDark = brightness == Brightness.dark;

  // 日志正文色：深底取设计稿的温润浅字（比 AppPalette.dark.text 略暗，
  // 大段等宽字不刺眼），属日志内容色例外。
  final foreground = isDark ? const Color(0xFFE7E5E4) : AppPalette.light.text;
  final barBackground = isDark
      ? Color.alphaBlend(const Color(0x0AFFFFFF), background)
      : Color.alphaBlend(const Color(0x061C1917), background);
  // 次要文字取设计稿日志专项的 text2（与 AppPalette 两套 text2 同值）。
  // 它既压在日志底上（空态），也压在顶栏 / 底栏的 barBackground 上（行数），
  // 两处都要够 4.5:1：默认底色上原样就够，面板配了偏灰的底才会被往前景色挪。
  final mutedForeground = ensureLogContrast(
    isDark ? AppPalette.dark.text2 : AppPalette.light.text2,
    on: [background, barBackground],
    toward: foreground,
  );

  return LogSurfaceTheme(
    background: background,
    foreground: foreground,
    mutedForeground: mutedForeground,
    divider: isDark ? const Color(0x14FFFFFF) : const Color(0x121C1917),
    barBackground: barBackground,
    brightness: brightness,
  );
}
