import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 常驻通知（「N 个任务运行中」）只在安卓上做：iOS 要 Live Activities 扩展，本期不做（PRD 决定表）。
/// 用 defaultTargetPlatform 而不是 dart:io 的 Platform：web 构建里 Platform 会抛，测试里也能覆盖平台。
bool get isRunningNotificationPlatform =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// 快捷方式（长按图标的菜单）安卓 + iOS 都做。
bool get isQuickActionsPlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// 设置页「任务运行时显示常驻通知」开关（第二波契约：B6 读写它）。
///
/// - 本机键 [RunningNotificationSetting.prefsKey]，默认关，**应用级**（所有面板共用）；
/// - iOS / web 上 [RunningNotificationSetting.supported] 为 false，开关应隐藏或置灰，
///   这时 state 恒为 false。
/// - 构造函数什么都不做（初始 false），本机设置由这里的工厂在构造后异步 [RunningNotificationSetting.load]；
///   测试里 `overrideWith` 换成子类时不会碰插件和 SharedPreferences。
final runningNotificationEnabledProvider =
    StateNotifierProvider<RunningNotificationSetting, bool>(
      (ref) => RunningNotificationSetting()..load(),
    );

class RunningNotificationSetting extends StateNotifier<bool> {
  RunningNotificationSetting() : super(false);

  static const String prefsKey = 'integration.running_notification';

  /// 测试用：覆盖「当前平台支不支持」。
  @visibleForTesting
  static bool? supportedOverride;

  /// 测试用：替换系统通知权限申请（真机走 flutter_local_notifications）。
  @visibleForTesting
  static Future<bool> Function()? requestPermissionOverride;

  bool get supported => supportedOverride ?? isRunningNotificationPlatform;

  /// 补读还没回来时用户已经手动拨过开关，就不能再被补读的旧值盖回去。
  bool _userChanged = false;

  /// 异步读回本机设置。补读回来前用户已经拨过开关，就以用户的为准。
  Future<void> load() async {
    if (!supported) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getBool(prefsKey) ?? false;
      if (mounted && !_userChanged) state = stored;
    } catch (_) {
      // 读不到就按默认关
    }
  }

  /// 打开 / 关闭常驻通知，返回**实际**状态。
  ///
  /// 打开时在安卓 13+ 申请 `POST_NOTIFICATIONS`：用户拒绝（或之前已永久拒绝，系统不再弹窗）
  /// 就返回 false、开关保持关闭，设置页据此提示「去系统设置里允许通知」。
  Future<bool> setEnabled(bool on) async {
    _userChanged = true;
    if (!supported) {
      state = false;
      return false;
    }
    var next = on;
    if (on) {
      final request = requestPermissionOverride ?? _requestPermission;
      next = await request();
    }
    if (!mounted) return next;
    state = next;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefsKey, next);
    } catch (_) {
      // 落盘失败只影响下次启动，本次照常生效
    }
    return next;
  }

  static Future<bool> _requestPermission() async {
    final android = FlutterLocalNotificationsPlugin()
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android == null) return false;
    try {
      // 安卓 13 以下没有运行时通知权限，插件直接回 true；
      // 13+ 弹系统授权框，回用户的选择。
      final granted = await android.requestNotificationsPermission();
      if (granted != null) return granted;
      return await android.areNotificationsEnabled() ?? false;
    } catch (_) {
      // 「上一次申请还没结束」等异常：按没拿到权限处理，用户再点一次即可
      return false;
    }
  }

  @visibleForTesting
  static void resetForTest() {
    supportedOverride = null;
    requestPermissionOverride = null;
  }
}
