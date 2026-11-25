import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「默认打开页面」（APP #24）：进入主界面时落到哪一页。
///
/// - 存本机 SharedPreferences，**所有面板共用**（应用级偏好，与「自动提醒更新」同一类）；
/// - 没设过 / 存了不认识的值 → 任务（v2.0 的首页）；
/// - 进入主界面的 7 处落点（开屏两处、登录页两处、切换面板一处、router 重定向两处）
///   都读 [route]。router 的 redirect 是同步的，所以启动时（`runApp` 之前）先 [load]
///   一次放进内存，之后 [save] 同步更新内存，redirect 直接读内存。
///
/// v2.0 底栏改成「任务 / 日志 / 概览 / 变量 / 设置」，旧选项「主页」（`dashboard`）没了：
/// [load] 读到它时按「任务」处理并回写，升级后不报错、也不会落到一个不存在的 Tab。
class DefaultLandingPage {
  DefaultLandingPage._();

  static const String prefsKey = 'app_default_landing_page';

  /// 没设过时的落点。
  static const String defaultValue = 'tasks';

  /// 可选项：存的值 → 显示名。顺序就是设置弹层里的顺序。
  static const Map<String, String> options = {
    'tasks': '任务',
    'logs': '日志',
    'overview': '概览',
    'envs': '变量',
  };

  /// v1.x 存下的旧值 → v2.0 的新值。
  static const Map<String, String> _legacy = {'dashboard': 'tasks'};

  static String _value = defaultValue;

  /// 当前选择（`tasks` / `logs` / `overview` / `envs`）。
  static String get value => _value;

  /// 当前选择对应的路由，例如 `/tasks`。
  static String get route => '/$_value';

  /// 当前选择的显示名，例如「任务」。
  static String get label => options[_value] ?? options[defaultValue]!;

  /// 启动时预读一次。读不到 / 读到不认识的值都回落任务，不抛。
  /// 读到旧值 `dashboard` 时换成新值并回写，下次启动就是干净的新值。
  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(prefsKey);
      final migrated = _legacy[stored];
      if (migrated != null) {
        _value = migrated;
        await prefs.setString(prefsKey, migrated);
        return;
      }
      _value = options.containsKey(stored) ? stored! : defaultValue;
    } catch (_) {
      _value = defaultValue;
    }
  }

  /// 先改内存（redirect 立刻生效），再落盘。不认识的值直接忽略。
  static Future<void> save(String value) async {
    if (!options.containsKey(value)) return;
    _value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, value);
  }

  @visibleForTesting
  static void resetForTest() => _value = defaultValue;
}
