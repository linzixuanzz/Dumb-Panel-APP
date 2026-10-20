import 'package:daidai_app/core/services/app_update_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 下载地址留空：弹窗里就没有「立即更新」，只测提醒相关的按钮。
AppUpdateInfo _info(String version) => AppUpdateInfo(
  latestVersion: version,
  currentVersion: '1.0.0',
  releaseNotes: '',
  downloadUrl: '',
  assetName: '',
  hasUpdate: true,
);

/// 挂一个空页面，返回能拿来弹窗的 context。外面包 Scaffold 是给「不再自动提醒」的提示条用的。
Future<BuildContext> _pumpHost(WidgetTester tester) async {
  late BuildContext hostContext;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) {
            hostContext = context;
            return const SizedBox();
          },
        ),
      ),
    ),
  );
  return hostContext;
}

/// 跑一次自动检查，返回检查函数被调了几次（0 = 本次启动已经检查过 / 自动提醒已关）。
Future<int> _autoCheck(
  WidgetTester tester,
  BuildContext context,
  String version,
) async {
  var calls = 0;
  // 弹窗要等关掉才返回，这里不 await，靠 pump 推进
  AppUpdateService.autoCheckAndPrompt(
    context,
    check: () async {
      calls++;
      return _info(version);
    },
  );
  await tester.pumpAndSettle();
  return calls;
}

/// issue #19：自动更新提醒每次启动最多一次，且能「忽略此版本」「不再自动提醒」。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AppUpdateService.resetAutoCheckForTest();
  });

  testWidgets('稍后：同一次启动再回首页不再检查、也不再弹', (tester) async {
    final context = await _pumpHost(tester);

    expect(await _autoCheck(tester, context, '9.9.9'), 1);
    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.text('忽略此版本'), findsOneWidget);
    expect(find.text('不再自动提醒'), findsOneWidget);

    await tester.tap(find.text('稍后'));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本'), findsNothing);

    // 首页重建 / 切回首页：进程级标记挡住，连 GitHub 都不再请求
    expect(await _autoCheck(tester, context, '9.9.9'), 0);
    expect(find.text('发现新版本'), findsNothing);
  });

  testWidgets('忽略此版本：同一版本下次启动不弹，出了更新的版本照常弹', (tester) async {
    final context = await _pumpHost(tester);

    await _autoCheck(tester, context, '9.9.9');
    await tester.tap(find.text('忽略此版本'));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本'), findsNothing);

    // 模拟下次启动：还是 9.9.9，检查了但不弹
    AppUpdateService.resetAutoCheckForTest();
    expect(await _autoCheck(tester, context, '9.9.9'), 1);
    expect(find.text('发现新版本'), findsNothing);

    // 再下次启动：出了 9.9.10，照常弹
    AppUpdateService.resetAutoCheckForTest();
    expect(await _autoCheck(tester, context, '9.9.10'), 1);
    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.text('v9.9.10'), findsOneWidget);
  });

  testWidgets('不再自动提醒：之后启动都不检查；在设置里重新打开后恢复', (tester) async {
    final context = await _pumpHost(tester);

    await _autoCheck(tester, context, '9.9.9');
    await tester.tap(find.text('不再自动提醒'));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本'), findsNothing);
    expect(await AppUpdateService.getAutoRemindEnabled(), isFalse);

    AppUpdateService.resetAutoCheckForTest();
    expect(await _autoCheck(tester, context, '9.9.10'), 0);
    expect(find.text('发现新版本'), findsNothing);

    // 更多页的「自动提醒更新」开关重新打开
    await AppUpdateService.setAutoRemindEnabled(true);
    AppUpdateService.resetAutoCheckForTest();
    expect(await _autoCheck(tester, context, '9.9.10'), 1);
    expect(find.text('发现新版本'), findsOneWidget);

    // 收掉提示条的定时器
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('手动检查：忽略了版本、关了自动提醒也照常弹，且不显示两个新选项', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'app_update_auto_remind': false,
      'app_update_ignored_version': '9.9.9',
    });
    final context = await _pumpHost(tester);

    // 更多页「检查更新」走的就是不带 fromAutoCheck 的 showUpdateDialog
    AppUpdateService.showUpdateDialog(context, _info('9.9.9'));
    await tester.pumpAndSettle();

    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.text('稍后'), findsOneWidget);
    expect(find.text('忽略此版本'), findsNothing);
    expect(find.text('不再自动提醒'), findsNothing);
  });
}
