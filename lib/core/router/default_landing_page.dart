import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「默认打开页面」（APP #24）：进入主界面时落到哪一页。
///
/// - 存本机 SharedPreferences，**所有面板共用**（应用级偏好，与「自动提醒更新」同一类）；
/// - 没设过 / 存了不认识的值 → 主页，与改动前一致；
/// - 进入主界面的 7 处落点（开屏两处、登录页两处、切换面板一处、router 重定向两处）
///   都读 [route]。router 的 redirect 是同步的，所以启动时（`runApp` 之前）先 [load]
///   一次放进内存，之后 [save] 同步更新内存，redirect 直接读内存。
///
/// 底部导航的「主页」按钮仍然去 `/dashboard`，与这个设置无关。
class DefaultLandingPage {
  DefaultLandingPage._();

  static const String prefsKey = 'app_default_landing_page';

  /// 可选项：存的值 → 显示名。顺序就是设置弹层里的顺序。
  static const Map<String, String> options = {
    'dashboard': '主页',
    'tasks': '任务',
    'logs': '日志',
    'envs': '变量',
  };

  static String _value = 'dashboard';

  /// 当前选择（`dashboard` / `tasks` / `logs` / `envs`）。
  static String get value => _value;

  /// 当前选择对应的路由，例如 `/tasks`。
  static String get route => '/$_value';

  /// 当前选择的显示名，例如「任务」。
  static String get label => options[_value] ?? '主页';

  /// 启动时预读一次。读不到 / 读到不认识的值都回落主页，不抛。
  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(prefsKey);
      _value = options.containsKey(stored) ? stored! : 'dashboard';
    } catch (_) {
      _value = 'dashboard';
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
  static void resetForTest() => _value = 'dashboard';
}
