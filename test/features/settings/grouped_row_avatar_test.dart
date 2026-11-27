import 'package:daidai_app/core/network/dio_client.dart';
import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/features/settings/views/about_page.dart';
import 'package:daidai_app/features/settings/views/sponsor_page.dart';
import 'package:daidai_app/shared/widgets/app_grouped_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_http_adapter.dart';

/// 有转圈 / 网络图在加载的页面不能 pumpAndSettle，按帧推进。
Future<void> _pumpFrames(WidgetTester tester, [int count = 10]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 让测试环境的假 HttpClient 真正回 400，Image.network 才会走 errorBuilder。
/// testWidgets 默认跑在 FakeAsync 里，真实 I/O 不 runAsync 不会推进。
Future<void> _letImagesFail(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  }
}

Future<void> _pumpPage(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: page));
  await _pumpFrames(tester);
}

/// [title] 所在的分组行：标题左缘离行左缘正好 [AppGroupedRow.textStart]，
/// 也就是分隔线的起点；[separator] 为 true 时再确认分隔线确实从那里画起。
///
/// 头像写死 36dp 时标题在 16 + 36 + 12 = 64，分隔线在 62，错开 2dp。
void _expectTitleOnSeparator(
  WidgetTester tester,
  String title, {
  required bool separator,
}) {
  final text = find.text(title);
  final row = find.ancestor(of: text, matching: find.byType(AppGroupedRow));
  expect(row, findsOneWidget);
  final dx = tester.getTopLeft(text).dx - tester.getTopLeft(row).dx;
  expect(dx, AppGroupedRow.textStart, reason: '「$title」的标题起点');
  if (separator) {
    expect(
      tester.renderObject(row),
      paints..line(p1: const Offset(AppGroupedRow.textStart, 0.3)),
      reason: '「$title」的分隔线起点',
    );
  }
}

/// 关于页、赞助页分组行的头像（网络图与兜底首字母圆）都占
/// [AppGroupedRow.leadingWidth]，标题与分隔线左端对齐。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: '呆呆面板',
      packageName: 'com.daidai.panel',
      version: '3.0.0',
      buildNumber: '40',
      buildSignature: '',
    );
  });

  testWidgets('关于页：作者行的标题与分隔线对齐（图加载中 / 失败退兜底都一样）', (
    tester,
  ) async {
    await _pumpPage(tester, const AboutPage());

    // 图还在加载：Image.network 按给定宽高占位
    _expectTitleOnSeparator(tester, 'linzixuanzz', separator: true);

    // 图加载失败：换成首字母兜底圆，行不能跳
    await _letImagesFail(tester);
    expect(find.text('L'), findsOneWidget);
    _expectTitleOnSeparator(tester, 'linzixuanzz', separator: true);
    // 最近的那个 Container 就是兜底圆（再往外是分组卡片的 Container）
    final fallback = find
        .ancestor(of: find.text('L'), matching: find.byType(Container))
        .first;
    expect(
      tester.getSize(fallback),
      const Size.square(AppGroupedRow.leadingWidth),
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('赞助页：每一行的标题与分隔线对齐（有头像 / 无头像都一样）', (tester) async {
    DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter(
      (_) => jsonResponse(<String, dynamic>{
        'data': <String, dynamic>{
          'count': 3,
          'total_amount': 80,
          'sponsors': [
            // 按金额倒序排：A 是第一行（不画分隔线），B、C 画
            {
              'id': 1,
              'name': '赞助者A',
              'amount': 50,
              'avatar_url': 'https://example.com/a.png',
              'initial': 'A',
            },
            {
              'id': 2,
              'name': '赞助者B',
              'amount': 20,
              'avatar_url': 'https://example.com/b.png',
              'initial': 'B',
            },
            {
              'id': 3,
              'name': '赞助者C',
              'amount': 10,
              'avatar_url': '',
              'initial': 'C',
            },
          ],
        },
      }),
    );
    await _pumpPage(tester, const SponsorPage());

    _expectTitleOnSeparator(tester, '赞助者A', separator: false);
    _expectTitleOnSeparator(tester, '赞助者B', separator: true);
    _expectTitleOnSeparator(tester, '赞助者C', separator: true);

    await _letImagesFail(tester);
    for (final initial in ['A', 'B', 'C']) {
      expect(find.text(initial), findsOneWidget);
    }
    _expectTitleOnSeparator(tester, '赞助者A', separator: false);
    _expectTitleOnSeparator(tester, '赞助者B', separator: true);
    _expectTitleOnSeparator(tester, '赞助者C', separator: true);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
