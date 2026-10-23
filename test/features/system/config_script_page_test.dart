import 'dart:async';

import 'package:daidai_app/core/auth/auth_provider.dart';
import 'package:daidai_app/core/auth/auth_service.dart';
import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/network/dio_client.dart';
import 'package:daidai_app/features/settings/views/more_page.dart';
import 'package:daidai_app/features/system/views/config_script_page.dart';
import 'package:daidai_app/shared/models/user.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_http_adapter.dart';

const _original = 'export JD_COOKIE=""\n';

/// 只为「更多」页提供一个已登录用户，不碰网络。
class _FakeAuth extends AuthNotifier {
  _FakeAuth(User user) : super(AuthService()) {
    state = AuthState(status: AuthStatus.authenticated, user: user);
  }
}

/// 假面板：GET 回 [content]；PUT 记下请求体，按 [failSave] 决定成败；加载可以先失败几次。
class _FakePanel {
  _FakePanel({this.content = _original});

  final String content;
  final putBodies = <Object?>[];
  int getCount = 0;
  int loadFailures = 0;
  bool failSave = false;

  FutureOr<ResponseBody> handle(RequestOptions options) {
    if (options.path == ApiEndpoints.configScript) {
      if (options.method == 'GET') {
        getCount++;
        if (loadFailures > 0) {
          loadFailures--;
          return jsonResponse({'error': '读取配置文件失败'}, status: 500);
        }
        return jsonResponse({
          'data': {'content': content, 'path': 'config.sh'},
        });
      }
      if (options.method == 'PUT') {
        putBodies.add(options.data);
        if (failSave) {
          return jsonResponse({'error': '保存配置文件失败'}, status: 500);
        }
        return jsonResponse({
          'data': {'message': '配置文件已保存'},
        });
      }
    }
    // 编辑器底色之类的面板配置按老面板 404 处理，用默认值。
    return jsonResponse(<String, dynamic>{}, status: 404);
  }
}

/// 从一个首页压栈打开配置文件页，返回时才有地方可回。
Future<void> _openPage(
  WidgetTester tester,
  _FakePanel panel, {
  Size size = const Size(360, 800),
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter(panel.handle);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const ConfigScriptPage(),
                ),
              ),
              child: const Text('打开配置文件'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开配置文件'));
  await tester.pumpAndSettle();
}

Future<void> _closePage(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

IconButton _saveButton(WidgetTester tester) => tester.widget<IconButton>(
  find.widgetWithIcon(IconButton, Icons.save_outlined),
);

/// APP #22：APP 里新增「配置文件」（config.sh）编辑页。
///
/// 钉住：读到的正文进编辑器；没改动时「保存」不可点；保存的请求体恰好是 `{content: 编辑器里的全文}`；
/// 保存成功 / 失败各有提示，失败后修改还在；加载失败给重试；有未保存修改时返回要确认。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues({});
    DioClient.instance.setBaseUrl('https://panel.test');
  });

  for (final textScale in [1.0, 1.3]) {
    testWidgets('360×800、字号 $textScale：正文进编辑器、不溢出，没改动时「保存」不可点', (
      tester,
    ) async {
      final panel = _FakePanel();
      await _openPage(tester, panel, textScale: textScale);

      expect(tester.takeException(), isNull);
      expect(find.text('配置文件'), findsOneWidget);
      expect(find.text('config.sh'), findsOneWidget);
      final editor = tester.widget<TextField>(find.byType(TextField));
      expect(editor.controller!.text, _original);
      expect(_saveButton(tester).onPressed, isNull);

      await _closePage(tester);
    });
  }

  testWidgets('改动后保存：PUT 请求体恰好是编辑器全文，成功提示，「保存」回到不可点', (tester) async {
    final panel = _FakePanel();
    await _openPage(tester, panel);

    await tester.enterText(find.byType(TextField), 'export A=1\n');
    await tester.pump();
    expect(find.text('config.sh · 有未保存的修改'), findsOneWidget);
    expect(_saveButton(tester).onPressed, isNotNull);

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.tap(find.byTooltip('保存'));
    await tester.pumpAndSettle();

    expect(panel.putBodies, [
      {'content': 'export A=1\n'},
    ]);
    expect(find.text('配置文件已保存'), findsOneWidget);
    expect(find.text('config.sh'), findsOneWidget);
    expect(_saveButton(tester).onPressed, isNull);

    await _closePage(tester);
  });

  testWidgets('保存失败：红条写面板原话，修改还在、还能再存', (tester) async {
    final panel = _FakePanel()..failSave = true;
    await _openPage(tester, panel);

    await tester.enterText(find.byType(TextField), 'export A=1\n');
    await tester.pump();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.tap(find.byTooltip('保存'));
    await tester.pumpAndSettle();

    expect(panel.putBodies, hasLength(1));
    expect(find.text('保存配置文件失败'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'export A=1\n',
    );
    expect(_saveButton(tester).onPressed, isNotNull);

    await _closePage(tester);
  });

  testWidgets('加载失败：显示原因和重试，重试成功后正文进编辑器', (tester) async {
    final panel = _FakePanel()..loadFailures = 1;
    await _openPage(tester, panel);

    expect(find.text('配置文件加载失败'), findsOneWidget);
    expect(find.text('读取配置文件失败'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(panel.getCount, 2);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      _original,
    );

    await _closePage(tester);
  });

  testWidgets('有未保存的修改时返回：先确认；「继续编辑」留在页上，「放弃修改」才回去', (tester) async {
    final panel = _FakePanel();
    await _openPage(tester, panel);

    await tester.enterText(find.byType(TextField), 'export A=1\n');
    await tester.pump();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('放弃修改？'), findsOneWidget);

    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.byType(ConfigScriptPage), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃修改'));
    await tester.pumpAndSettle();
    expect(find.byType(ConfigScriptPage), findsNothing);
    expect(find.text('打开配置文件'), findsOneWidget);
    expect(panel.putBodies, isEmpty);

    await _closePage(tester);
  });

  testWidgets('查找：复用脚本编辑器的查找条，命中计数随输入更新、可下一个回绕', (tester) async {
    final panel = _FakePanel(content: 'export A=1\nexport B=2\n');
    await _openPage(tester, panel);

    await tester.tap(find.byTooltip('查找'));
    await tester.pump();
    final findField = find.widgetWithText(TextField, '查找代码');
    expect(findField, findsOneWidget);

    await tester.enterText(findField, 'export');
    await tester.pump();
    expect(find.text('1/2'), findsOneWidget);

    await tester.tap(find.byTooltip('下一个'));
    await tester.pump();
    expect(find.text('2/2'), findsOneWidget);
    await tester.tap(find.byTooltip('下一个'));
    await tester.pump();
    expect(find.text('1/2'), findsOneWidget);

    await _closePage(tester);
  });

  group('「更多」页入口', () {
    Future<void> openMore(WidgetTester tester, String role) async {
      tester.view.physicalSize = const Size(400, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter(
        (_) => jsonResponse(<String, dynamic>{}, status: 404),
      );
      final user = User(
        id: 1,
        username: 'tester',
        role: role,
        enabled: true,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, state) => const MorePage()),
          GoRoute(
            path: '/config-script',
            builder: (_, state) => const Text('配置文件页'),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [authProvider.overrideWith((ref) => _FakeAuth(user))],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('管理员：系统管理分区里有「配置文件」，点它进 /config-script', (tester) async {
      await openMore(tester, 'admin');

      expect(find.text('系统设置'), findsOneWidget);
      await tester.ensureVisible(find.text('配置文件'));
      await tester.tap(find.text('配置文件'));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('配置文件页'), findsOneWidget);

      await _closePage(tester);
    });

    testWidgets('非管理员：看不到「配置文件」（接口仅 admin）', (tester) async {
      await openMore(tester, 'operator');

      expect(find.text('系统设置'), findsNothing);
      expect(find.text('配置文件'), findsNothing);

      await _closePage(tester);
    });
  });

  testWidgets('没有修改时返回：不弹确认，直接回去', (tester) async {
    final panel = _FakePanel();
    await _openPage(tester, panel);

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.text('放弃修改？'), findsNothing);
    expect(find.byType(ConfigScriptPage), findsNothing);

    await _closePage(tester);
  });
}
