import 'package:daidai_app/core/network/dio_client.dart';
import 'package:daidai_app/features/deps/views/dep_list_page.dart';
import 'package:daidai_app/features/logs/views/log_list_page.dart';
import 'package:daidai_app/features/notifications/views/notification_list_page.dart';
import 'package:daidai_app/features/openapi/views/open_api_page.dart';
import 'package:daidai_app/features/scripts/views/script_list_page.dart';
import 'package:daidai_app/features/subscriptions/views/subscription_list_page.dart';
import 'package:daidai_app/features/users/views/user_list_page.dart';
import 'package:daidai_app/shared/widgets/app_circle_add_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_http_adapter.dart';

/// APP #21 同类排查：带「标题 + 按钮 + 圆形＋」页头的其它页面在 360dp、字号 1.3 下不溢出，
/// ＋整个落在屏幕内。环境变量 / 任务页各有专门用例（env_header_narrow_test、task_narrow_layout_test）。
///
/// 这里只看页头：所有请求一律 404，页面停在错误态或空态，与页头布局无关。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues({});
    DioClient.instance.setBaseUrl('https://panel.test');
  });

  final pages = <String, Widget>{
    '订阅管理': const SubscriptionListPage(),
    '依赖管理': const DepListPage(),
    '用户管理': const UserListPage(),
    '通知渠道': const NotificationListPage(),
    'Open API': const OpenApiPage(),
    '脚本管理': const ScriptListPage(),
    '运行日志': const LogListPage(),
  };

  for (final entry in pages.entries) {
    testWidgets('${entry.key}：360×800、字号 1.3 页头不溢出，＋在屏幕内', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter(
        (_) => jsonResponse(<String, dynamic>{}, status: 404),
      );

      await tester.pumpWidget(
        ProviderScope(child: MaterialApp(home: entry.value)),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(tester.takeException(), isNull);
      expect(find.text(entry.key), findsWidgets);
      final add = find.byType(AppCircleAddButton);
      if (add.evaluate().isNotEmpty) {
        expect(tester.getRect(add).right, lessThanOrEqualTo(360));
      }

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });
  }
}
