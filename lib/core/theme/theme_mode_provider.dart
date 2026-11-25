import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 明暗设置：浅色 / 深色 / 跟随系统（PRD A7）。
///
/// - 存本机 SharedPreferences，**应用级、所有面板共用**（与「默认打开页面」同一类偏好）；
/// - 没设过 / 存了不认识的值 → 跟随系统，与 v1.x 写死 `ThemeMode.system` 的行为一致。
///
/// 启动时如果先 [ThemeModeNotifier.preload] 一次（`main.dart` 在 `runApp` 前调），
/// 第一帧就是用户选的明暗；没预读也能用，只是第一帧按跟随系统画、读到后再切一次。
final themeModeProvider = StateNotifierProvider<ThemeModeNotifier, ThemeMode>(
  (ref) => ThemeModeNotifier(),
);

class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  ThemeModeNotifier() : super(_preloaded ?? ThemeMode.system) {
    // 没预读过就自己补读一次。
    if (_preloaded == null) {
      _load();
    }
  }

  static const String prefsKey = 'app_theme_mode';

  /// 可选项：存的值 → 显示名，顺序即设置页里的顺序。
  static const Map<String, String> options = {
    'system': '跟随系统',
    'light': '浅色',
    'dark': '深色',
  };

  static ThemeMode? _preloaded;

  /// 启动时预读进内存，让第一帧就是对的明暗。读失败按跟随系统，不抛。
  static Future<void> preload() async {
    _preloaded = await _read();
  }

  static Future<ThemeMode> _read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return _parse(prefs.getString(prefsKey));
    } catch (_) {
      return ThemeMode.system;
    }
  }

  static ThemeMode _parse(String? value) => switch (value) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  static String _encode(ThemeMode mode) => switch (mode) {
    ThemeMode.light => 'light',
    ThemeMode.dark => 'dark',
    ThemeMode.system => 'system',
  };

  /// 补读还没回来时用户已经手动选过，就不能再被补读的旧值盖回去。
  bool _userChanged = false;

  Future<void> _load() async {
    final mode = await _read();
    if (mounted && !_userChanged) state = mode;
  }

  /// 先改内存（界面立刻切），再落盘。
  Future<void> set(ThemeMode mode) async {
    _userChanged = true;
    state = mode;
    _preloaded = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, _encode(mode));
  }

  /// 当前选择存的值（`system` / `light` / `dark`），设置页显示名用 `options[value]`。
  String get value => _encode(state);

  @visibleForTesting
  static void resetForTest() => _preloaded = null;
}
