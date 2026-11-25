import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/features/app_lock/providers/app_lock_provider.dart';
import 'package:daidai_app/features/envs/utils/env_secret.dart';
import 'package:daidai_app/features/envs/views/env_list_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_http_adapter.dart';

const _secret = 'pt_key=abcdefgh;';
const _masked = 'pt_******gh;';

/// 假的系统验证：记调用次数，按 [next] 应答。
class _FakeDeviceAuth {
  int calls = 0;
  EnvAuthResult next = const EnvAuthResult(EnvAuthOutcome.passed);

  Future<EnvAuthResult> call() async {
    calls++;
    return next;
  }
}

/// 应用锁已开启、只开了生物识别（没设密码 / 图案）。
///
/// 用户决定：查看 / 复制敏感值只在「开了应用锁」时验证，所以下面「要验证」的用例
/// 默认都装上这把已开启的锁；「没开应用锁直接放行」另有用例覆盖。
class _LockBiometricOnly extends AppLockController {
  _LockBiometricOnly() {
    state = const AppLockState(
      config: AppLockConfig(enabled: true, biometricEnabled: true),
    );
  }
}

/// 应用锁设了密码（正确密码 1234）。只替换验证这一步，不跑真正的哈希。
class _LockWithPassword extends AppLockController {
  _LockWithPassword() {
    state = const AppLockState(
      config: AppLockConfig(enabled: true, passwordHash: 'fake'),
    );
  }

  final tried = <String>[];

  @override
  Future<bool> unlockWithPassword(String value) async {
    tried.add(value);
    return value == '1234';
  }
}

Future<List<String>> _openPage(
  WidgetTester tester,
  _FakeDeviceAuth auth, {
  AppLockController Function()? lock,
  bool lockOff = false,
}) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  // 剪贴板走平台通道，测试里接住它看复制了什么。
  final clipboard = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard.add((call.arguments as Map)['text'] as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  final rows = [
    {
      'id': 1,
      'name': 'JD_COOKIE',
      'value': _secret,
      'remarks': '',
      'group': '',
      'enabled': true,
      'sort_order': 0,
      'position': 1000.0,
    },
    {
      'id': 2,
      'name': 'BACKUP_DIR',
      'value': '/data/backup',
      'remarks': '',
      'group': '',
      'enabled': true,
      'sort_order': 0,
      'position': 2000.0,
    },
  ];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        envListProvider.overrideWith(
          (ref) => EnvListNotifier(
            dio: dioWithAdapter(
              FakeHttpAdapter((options) {
                if (options.path == ApiEndpoints.envsGroups) {
                  return jsonResponse({'data': <String>[]});
                }
                if (options.method == 'GET' &&
                    options.path == ApiEndpoints.envs) {
                  return jsonResponse({'data': rows, 'total': rows.length});
                }
                return jsonResponse({'message': '操作成功'});
              }),
            ),
          ),
        ),
        envDeviceAuthProvider.overrideWithValue(auth.call),
        // lockOff：不替换，用默认的 AppLockController（没开应用锁）。
        if (!lockOff)
          appLockProvider.overrideWith(
            (ref) => lock != null ? lock() : _LockBiometricOnly(),
          ),
      ],
      child: MaterialApp(theme: AppTheme.light(), home: const EnvListPage()),
    ),
  );
  await tester.pumpAndSettle();
  return clipboard;
}

/// 「复制」按钮：只在列表行里找（详情弹层里也有个写着「复制」的按钮）。
Finder _rowCopy() => find.byTooltip('复制');

void main() {
  testWidgets('敏感值默认遮住、普通值明文；遮住的行给「查看」，明文的行给「复制」', (tester) async {
    final auth = _FakeDeviceAuth();
    await _openPage(tester, auth);

    expect(find.text(_masked), findsOneWidget);
    expect(find.text(_secret), findsNothing);
    expect(find.text('/data/backup'), findsOneWidget);
    expect(find.byTooltip('查看'), findsOneWidget);
    expect(_rowCopy(), findsOneWidget);
    expect(auth.calls, 0, reason: '只是打开页面，不该弹验证');
  });

  testWidgets('点「查看」验证通过后显示明文；60 秒内再复制不再验证', (tester) async {
    final auth = _FakeDeviceAuth();
    final clipboard = await _openPage(tester, auth);

    await tester.tap(find.byTooltip('查看'));
    await tester.pumpAndSettle();

    expect(auth.calls, 1);
    expect(find.text(_secret), findsOneWidget);
    expect(find.text(_masked), findsNothing);
    expect(_rowCopy(), findsNWidgets(2));

    await tester.tap(_rowCopy().first);
    await tester.pumpAndSettle();
    expect(auth.calls, 1, reason: '刚验证过，60 秒内不再问');
    expect(clipboard, [_secret]);
  });

  testWidgets('验证没通过：仍然遮住，系统给的原因提示出来；用户自己取消则不提示', (tester) async {
    final auth = _FakeDeviceAuth()
      ..next = const EnvAuthResult(EnvAuthOutcome.failed, '尝试次数过多');
    await _openPage(tester, auth);

    await tester.tap(find.byTooltip('查看'));
    await tester.pumpAndSettle();
    expect(find.text(_masked), findsOneWidget);
    expect(find.text('尝试次数过多'), findsOneWidget);

    auth.next = const EnvAuthResult(EnvAuthOutcome.failed);
    await tester.tap(find.byTooltip('查看'));
    await tester.pumpAndSettle();
    expect(auth.calls, 2, reason: '没通过就不记 60 秒窗口，下次照样要验证');
    expect(find.text(_masked), findsOneWidget);
  });

  testWidgets('普通变量复制不验证', (tester) async {
    final auth = _FakeDeviceAuth();
    final clipboard = await _openPage(tester, auth);

    await tester.tap(_rowCopy());
    await tester.pumpAndSettle();
    expect(auth.calls, 0);
    expect(clipboard, ['/data/backup']);
  });

  testWidgets('没开应用锁：值照样默认遮住，点「查看」直接显示、复制直接复制，都不验证', (
    tester,
  ) async {
    final auth = _FakeDeviceAuth()
      ..next = const EnvAuthResult(EnvAuthOutcome.failed, '不该走到验证');
    final clipboard = await _openPage(tester, auth, lockOff: true);

    expect(find.text(_masked), findsOneWidget, reason: '没开应用锁也照样默认遮住');

    await tester.tap(find.byTooltip('查看'));
    await tester.pumpAndSettle();
    expect(find.text(_secret), findsOneWidget);
    expect(find.text('不该走到验证'), findsNothing);

    await tester.tap(_rowCopy().first);
    await tester.pumpAndSettle();
    expect(clipboard, [_secret]);
    expect(auth.calls, 0);
  });

  testWidgets('没开应用锁：值还遮着时，详情弹层里的复制也直接复制原值', (tester) async {
    final auth = _FakeDeviceAuth()
      ..next = const EnvAuthResult(EnvAuthOutcome.failed);
    final clipboard = await _openPage(tester, auth, lockOff: true);

    await tester.tap(find.text('JD_COOKIE'));
    await tester.pumpAndSettle();
    final sheet = find.byType(BottomSheet);
    expect(
      find.descendant(of: sheet, matching: find.text(_masked)),
      findsOneWidget,
    );
    await tester.tap(find.descendant(of: sheet, matching: find.text('复制')));
    await tester.pumpAndSettle();
    expect(clipboard, [_secret]);
    expect(auth.calls, 0);
  });

  testWidgets('应用锁只开了生物识别、设备做不了系统验证：没有密码 / 图案可兜底，放行', (
    tester,
  ) async {
    final auth = _FakeDeviceAuth()
      ..next = const EnvAuthResult(EnvAuthOutcome.unavailable);
    await _openPage(tester, auth);

    await tester.tap(find.byTooltip('查看'));
    await tester.pumpAndSettle();
    expect(auth.calls, 1, reason: '开了应用锁，先走系统验证');
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text(_secret), findsOneWidget);
  });

  testWidgets('设备做不了系统验证、应用锁设了密码：改用应用锁密码验证', (tester) async {
    final auth = _FakeDeviceAuth()
      ..next = const EnvAuthResult(EnvAuthOutcome.unavailable);
    late _LockWithPassword lock;
    await _openPage(
      tester,
      auth,
      lock: () => lock = _LockWithPassword(),
    );

    await tester.tap(find.byTooltip('查看'));
    await tester.pumpAndSettle();
    expect(find.text('验证身份'), findsOneWidget);

    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '0000',
    );
    await tester.tap(find.text('验证'));
    await tester.pumpAndSettle();
    expect(find.text('密码不正确'), findsOneWidget);
    expect(find.text(_masked), findsOneWidget);

    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '1234',
    );
    await tester.tap(find.text('验证'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text(_secret), findsOneWidget);
    expect(lock.tried, ['0000', '1234']);
  });

  testWidgets('详情弹层：值先遮住，点「查看」验证后换成可编辑的输入框；弹层里的复制同样先验证', (
    tester,
  ) async {
    final auth = _FakeDeviceAuth()
      ..next = const EnvAuthResult(EnvAuthOutcome.failed);
    final clipboard = await _openPage(tester, auth);

    await tester.tap(find.text('JD_COOKIE'));
    await tester.pumpAndSettle();
    final sheet = find.byType(BottomSheet);
    expect(
      find.descendant(of: sheet, matching: find.text(_masked)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sheet, matching: find.byType(TextField)),
      findsNWidgets(3),
      reason: '只有变量名、备注、分组三个输入框，值不是输入框',
    );

    // 没通过：复制不发生。
    await tester.tap(find.descendant(of: sheet, matching: find.text('复制')));
    await tester.pumpAndSettle();
    expect(auth.calls, 1);
    expect(clipboard, isEmpty);

    auth.next = const EnvAuthResult(EnvAuthOutcome.passed);
    await tester.tap(find.descendant(of: sheet, matching: find.byTooltip('查看')));
    await tester.pumpAndSettle();
    expect(auth.calls, 2);
    expect(
      find.descendant(of: sheet, matching: find.text(_masked)),
      findsNothing,
    );
    expect(
      find.descendant(of: sheet, matching: find.text(_secret)),
      findsOneWidget,
      reason: '揭开后是可编辑的输入框，里面是原值',
    );

    await tester.tap(find.descendant(of: sheet, matching: find.text('复制')));
    await tester.pumpAndSettle();
    expect(auth.calls, 2, reason: '刚验证过，不再问');
    expect(clipboard, [_secret]);
  });
}
