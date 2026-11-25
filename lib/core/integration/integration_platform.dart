import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:home_widget/home_widget.dart';
import 'package:quick_actions/quick_actions.dart';

/// 三个系统集成插件的薄封装。[IntegrationService] 只通过它碰平台，
/// 测试里换成假实现，不用逐个 mock 三条 platform channel。
class IntegrationPlatform {
  const IntegrationPlatform();

  /// 安卓小组件的 AppWidgetProvider 全名（`android/app/src/main/kotlin/.../TaskWidgetProvider.kt`）。
  static const String widgetProvider = 'com.daidai.panel.TaskWidgetProvider';

  /// 常驻通知：渠道与通知 id 都固定，更新时覆盖同一条。
  static const String runningChannelId = 'running_tasks';
  static const String runningChannelName = '任务运行中';
  static const int runningNotificationId = 4001;

  /// 常驻通知的自动消失时间（毫秒），见 [showRunning] 里的 `timeoutAfter`。
  static const int runningTimeoutMs = 75000;

  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  // ── 快捷方式 ──

  /// 注册点按回调。冷启动由快捷方式拉起时，插件会在这里补回调一次。
  Future<void> initShortcuts(void Function(String type) onAction) =>
      const QuickActions().initialize(onAction);

  Future<void> setShortcuts(List<ShortcutItem> items) =>
      const QuickActions().setShortcutItems(items);

  // ── 桌面小组件 ──

  /// 冷启动是不是由小组件拉起的；是的话返回那条启动 URI。
  Future<Uri?> initialWidgetUri() =>
      HomeWidget.initiallyLaunchedFromHomeWidget();

  /// APP 已在运行时点小组件。
  Stream<Uri?> get widgetClicks => HomeWidget.widgetClicked;

  /// 写快照：值为 null 的键会被删掉（例如没有失败任务了）。
  Future<void> saveWidgetData(Map<String, String?> data) async {
    for (final entry in data.entries) {
      await HomeWidget.saveWidgetData<String>(entry.key, entry.value);
    }
  }

  /// 让桌面上已添加的小组件按新快照重绘。没添加过小组件时是空操作。
  Future<void> updateWidget() =>
      HomeWidget.updateWidget(qualifiedAndroidName: widgetProvider);

  // ── 常驻通知 ──

  /// 初始化通知插件，并清掉上一次进程留下的「运行中」通知（进程被杀时来不及取消）。
  Future<void> initNotifications(void Function() onTap) async {
    await _notifications.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_running'),
      ),
      onDidReceiveNotificationResponse: (_) => onTap(),
    );
    await _notifications.cancel(id: runningNotificationId);
  }

  Future<void> showRunning(String title, String body) {
    return _notifications.show(
      id: runningNotificationId,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          runningChannelId,
          runningChannelName,
          channelDescription: '有任务正在运行时显示，全部结束后自动消失',
          icon: 'ic_stat_running',
          // 低重要性：只在通知栏里待着，不弹横幅、不响不振
          importance: Importance.low,
          priority: Priority.low,
          playSound: false,
          enableVibration: false,
          onlyAlertOnce: true,
          ongoing: true,
          autoCancel: false,
          showWhen: false,
          category: AndroidNotificationCategory.progress,
          // 不是前台服务：APP 进程被杀后没人来取消它。每 30 秒重发一次会刷新这个超时，
          // 进程没了就最多 75 秒后自己消失，不会一直挂着「运行中」。
          timeoutAfter: runningTimeoutMs,
        ),
      ),
    );
  }

  Future<void> cancelRunning() =>
      _notifications.cancel(id: runningNotificationId);

  /// 「运行中」通知现在还在不在通知栏里。安卓 14 起用户能划掉 ongoing 通知，靠它发现。
  /// 查不了（插件不支持 / 出错）时返回 null，调用方按「不知道」处理、照常更新。
  Future<bool?> isRunningShown() async {
    try {
      final active = await _notifications.getActiveNotifications();
      return active.any((n) => n.id == runningNotificationId);
    } catch (_) {
      return null;
    }
  }
}
