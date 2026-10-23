import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/network/dio_client.dart';
import 'package:daidai_app/features/subscriptions/views/subscription_list_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_http_adapter.dart';

Future<void> _pumpFrames(WidgetTester tester, [int count = 20]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// APP #23 ②：订阅卡片底部「上次拉取：…」不可收缩，360dp 屏上把删除图标挤出卡片、点不到。
///
/// 钉住：360 宽（含字号 1.3）不溢出；4 个按钮完整落在卡片内，删除点得开确认框。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues({});
    DioClient.instance.setBaseUrl('https://panel.test');
  });

  for (final textScale in [1.0, 1.3]) {
    testWidgets('360×800、字号 $textScale：底部行不溢出，删除图标在卡片内且点得开确认框', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter((options) {
        if (options.path == ApiEndpoints.subscriptions) {
          return jsonResponse({
            'data': [
              {
                'id': 3,
                'name': 'faker 仓库',
                'type': 'public-repo',
                'url': 'https://github.com/shufflewzc/faker2.git',
                'enabled': true,
                'status': 1,
                'last_pull_at': '2026-10-23T08:30:00Z',
              },
            ],
            'total': 1,
          });
        }
        return jsonResponse(<String, dynamic>{}, status: 404);
      });

      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: SubscriptionListPage())),
      );
      await _pumpFrames(tester);

      expect(find.text('faker 仓库'), findsOneWidget);
      expect(tester.takeException(), isNull);

      final delete = find.byIcon(Icons.delete_outline);
      expect(delete, findsOneWidget);
      // 卡片在列表左右各 20 的边距里，按钮的 44dp 命中区必须整块落在卡片内。
      final hitArea = tester.getRect(
        find.ancestor(of: delete, matching: find.byType(SizedBox)).first,
      );
      expect(hitArea.width, 44);
      expect(hitArea.right, lessThanOrEqualTo(340));

      await tester.tap(delete);
      await _pumpFrames(tester);
      expect(find.text('删除订阅'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });
  }
}
