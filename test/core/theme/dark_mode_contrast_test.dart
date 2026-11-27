import 'dart:async';

import 'package:daidai_app/core/auth/auth_provider.dart';
import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/services/app_update_service.dart';
import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/core/theme/design_tokens.dart';
import 'package:daidai_app/features/envs/views/env_list_page.dart';
import 'package:daidai_app/features/logs/views/log_list_page.dart';
import 'package:daidai_app/features/tasks/widgets/task_view_sheets.dart';
import 'package:daidai_app/shared/models/user.dart';
import 'package:daidai_app/shared/widgets/app_card.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_http_adapter.dart';

/// WCAG 对比度。
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// 半透明色叠在不透明底上的实际颜色。
Color _over(Color top, Color base) => Color.alphaBlend(top, base);

/// 文字最终画出来的颜色（已合并 DefaultTextStyle、按钮前景等）。
Color _paintedColor(WidgetTester tester, Finder text) =>
    tester.renderObject<RenderParagraph>(text).text.style!.color!;

/// [label] 所在的实心按钮（含 `FilledButton.icon`）：文字实际画出来的颜色
/// 对按钮底色 ≥ 4.5:1。返回按钮底色，调用方再确认它确实是红底。
Color _expectReadableOnButton(WidgetTester tester, Finder label) {
  final button = find.ancestor(
    of: label,
    matching: find.byWidgetPredicate((widget) => widget is FilledButton),
  );
  final background = tester
      .widget<Material>(
        find.descendant(of: button, matching: find.byType(Material)).first,
      )
      .color!;
  expect(
    _contrast(_paintedColor(tester, label), background),
    greaterThanOrEqualTo(4.5),
  );
  return background;
}

Finder _inDialog(Finder finder) =>
    find.descendant(of: find.byType(AlertDialog), matching: finder);

/// 打开变量页（两条普通变量），列表加载完再返回。
Future<void> _openEnvPage(WidgetTester tester, ThemeData theme) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  Map<String, dynamic> env(int id, String name) => <String, dynamic>{
    'id': id,
    'name': name,
    'value': 'v',
    'remarks': '',
    'group': '',
    'enabled': true,
    'sort_order': 0,
    'position': 1000.0 * id,
  };
  final adapter = FakeHttpAdapter((options) {
    if (options.path == ApiEndpoints.envsGroups) {
      return jsonResponse({'data': <String>[]});
    }
    if (options.path == ApiEndpoints.envs && options.method == 'GET') {
      return jsonResponse({
        'data': [env(1, 'OLD_A'), env(2, 'OLD_B')],
        'total': 2,
      });
    }
    return jsonResponse({'message': '操作成功'});
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        envListProvider.overrideWith(
          (ref) => EnvListNotifier(dio: dioWithAdapter(adapter)),
        ),
      ],
      child: MaterialApp(theme: theme, home: const EnvListPage()),
    ),
  );
  await tester.pumpAndSettle();
}

final _themes = [
  ('浅色', AppTheme.light(), AppPalette.light),
  ('深色', AppTheme.dark(), AppPalette.dark),
];

/// 直接处于已登录的 operator 状态（左滑删除要 operator）。
class _OperatorNotifier extends AuthNotifier {
  _OperatorNotifier(super.authService) {
    state = AuthState(
      status: AuthStatus.authenticated,
      user: User(
        id: 1,
        username: 'tester',
        role: 'operator',
        enabled: true,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
    );
  }
}

/// v3.0 深色把状态色提亮、表面色收拢之后，几处「颜色各自取自令牌、
/// 但组合起来看不清」的回归：红底确认按钮、更新弹窗、视图编辑器规则卡。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('红底确认按钮', () {
    for (final (name, theme, p) in _themes) {
      testWidgets('$name：日志页左滑删除的「删除」按钮文字 ≥ 4.5:1', (tester) async {
        tester.view.physicalSize = const Size(400, 1800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final adapter = FakeHttpAdapter((options) {
          if (options.path == ApiEndpoints.logs && options.method == 'GET') {
            return jsonResponse({
              'data': [
                {
                  'id': 7,
                  'task_id': 3,
                  'task_name': '更新 IP 数据库',
                  'status': 0,
                  'duration': 30.0,
                  'content': '',
                  'started_at': DateTime.now().toIso8601String(),
                  'created_at': DateTime.now().toIso8601String(),
                },
              ],
              'total': 1,
            });
          }
          return jsonResponse(<String, dynamic>{});
        });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authProvider.overrideWith(
                (ref) => _OperatorNotifier(ref.read(authServiceProvider)),
              ),
              logListProvider.overrideWith(
                (ref) => LogListNotifier(dio: dioWithAdapter(adapter)),
              ),
            ],
            child: MaterialApp(theme: theme, home: const LogListPage()),
          ),
        );
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }

        await tester.drag(
          find.byType(Dismissible).first,
          const Offset(-600, 0),
        );
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(find.text('删除日志'), findsOneWidget);

        final background = _expectReadableOnButton(
          tester,
          _inDialog(find.text('删除')),
        );
        expect(background, p.err);

        await tester.tap(find.text('取消'));
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
      });

      // 变量页这几处红底按钮各自写了前景色，删掉任何一处都会退回主题的
      // primaryBtnFg（深色白字压 #F87171 只有 2.77:1）。
      testWidgets('$name：变量页左滑删除的「删除」按钮文字 ≥ 4.5:1', (tester) async {
        await _openEnvPage(tester, theme);

        await tester.drag(find.text('OLD_A'), const Offset(-300, 0));
        await tester.pumpAndSettle();
        await tester.tap(find.text('删除').first);
        await tester.pumpAndSettle();
        expect(find.text('删除环境变量'), findsOneWidget);

        final background = _expectReadableOnButton(
          tester,
          _inDialog(find.text('删除')),
        );
        expect(background, p.err);
      });

      testWidgets('$name：变量页批量删除的「删除」按钮文字 ≥ 4.5:1', (tester) async {
        await _openEnvPage(tester, theme);

        await tester.tap(find.byTooltip('更多'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('批量'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OLD_A'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('批量删除'));
        await tester.pumpAndSettle();
        expect(find.text('确定删除选中的 1 个环境变量吗？'), findsOneWidget);

        final background = _expectReadableOnButton(
          tester,
          _inDialog(find.text('删除')),
        );
        expect(background, p.err);
      });

      testWidgets('$name：替换导入的「导入」与「清空并导入」文字 ≥ 4.5:1', (tester) async {
        await _openEnvPage(tester, theme);

        await tester.tap(find.byTooltip('更多'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('导入变量'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.descendant(
            of: find.byType(BottomSheet),
            matching: find.byType(TextField),
          ),
          '[{"name":"NEW_A","value":"1"}]',
        );
        // 体检有 300ms 防抖，过了才能点「导入」。
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text('替换'));
        await tester.pumpAndSettle();

        // 替换模式下弹层里的「导入」本身就换成红底
        final importBackground = _expectReadableOnButton(
          tester,
          find.text('导入'),
        );
        expect(importBackground, p.err);

        await tester.tap(find.text('导入'));
        await tester.pumpAndSettle();
        expect(find.text('替换导入'), findsOneWidget);

        final confirmBackground = _expectReadableOnButton(
          tester,
          _inDialog(find.text('清空并导入')),
        );
        expect(confirmBackground, p.err);
      });
    }
  });

  group('更新弹窗', () {
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

    for (final (name, theme, p) in _themes) {
      testWidgets('$name：版本号、下载进度底轨、报错文字都看得清', (tester) async {
        // 「立即更新」只在 Android 上出现
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        // 挂住临时目录的请求，让弹窗停在「下载中」，好量进度条
        final gate = Completer<Object?>();
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(pathProvider, (_) => gate.future);
        try {
          late BuildContext host;
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: Scaffold(
                body: Builder(
                  builder: (context) {
                    host = context;
                    return const SizedBox();
                  },
                ),
              ),
            ),
          );
          AppUpdateService.showUpdateDialog(
            host,
            const AppUpdateInfo(
              latestVersion: '9.9.9',
              currentVersion: '1.0.0',
              releaseNotes: '修复若干问题',
              downloadUrl:
                  'https://github.com/linzixuanzz/Dumb-Panel-APP/releases/'
                  'download/v9.9.9/app.apk',
              assetName: 'app.apk',
              hasUpdate: true,
            ),
          );
          await tester.pumpAndSettle();

          // 弹窗底色是 dialogTheme 的 card
          final version = _paintedColor(tester, find.text('v9.9.9'));
          expect(version, p.accentInk);
          expect(_contrast(version, p.card), greaterThanOrEqualTo(4.5));

          await tester.tap(find.text('立即更新'));
          await tester.pump();
          final bar = tester.widget<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator),
          );
          // 0% 时只看得见底轨：它不能和弹窗同色（旧版深色是 1.00:1）
          final track = _over(bar.backgroundColor!, p.card);
          expect(_contrast(track, p.card), greaterThan(1.1));
          expect(_contrast(bar.color!, track), greaterThanOrEqualTo(3.0));

          // 拿不到临时目录 → 下载阶段失败，弹窗显示报错原文
          gate.complete(null);
          await tester.pumpAndSettle();
          final error = find.textContaining('下载失败');
          expect(error, findsOneWidget);
          final errorColor = _paintedColor(tester, error);
          expect(errorColor, p.errInk);
          expect(_contrast(errorColor, p.card), greaterThanOrEqualTo(4.5));

          await tester.tap(find.text('稍后'));
          await tester.pumpAndSettle();
        } finally {
          messenger.setMockMethodCallHandler(pathProvider, null);
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  });

  group('视图编辑器', () {
    for (final (name, theme, _) in _themes) {
      testWidgets('$name：规则卡片里的下拉和「值」输入框与卡片底分得开', (tester) async {
        late BuildContext host;
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: theme,
              home: Scaffold(
                body: Builder(
                  builder: (context) {
                    host = context;
                    return const SizedBox();
                  },
                ),
              ),
            ),
          ),
        );
        // 新建视图：自带一条空规则
        showTaskViewEditor(host);
        await tester.pumpAndSettle();

        final card = tester.widget<AppCard>(
          find.ancestor(of: find.text('字段'), matching: find.byType(AppCard)),
        );
        final cardColor = card.color!;
        final themeFill = theme.inputDecorationTheme.fillColor!;

        final dropdown = tester.widget<InputDecorator>(
          find.ancestor(
            of: find.text('字段'),
            matching: find.byType(InputDecorator),
          ),
        );
        final valueField = tester.widget<TextField>(
          find.ancestor(of: find.text('值'), matching: find.byType(TextField)),
        );
        final decorations = [dropdown.decoration, valueField.decoration!];
        for (final decoration in decorations) {
          expect(decoration.filled, isNot(isFalse));
          final fill = decoration.fillColor ?? themeFill;
          // 旧写法卡片是 subtle（= card2），与输入框的默认填充同值，1.00:1
          expect(_contrast(fill, cardColor), greaterThan(1.1));
        }

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
      });
    }
  });
}
