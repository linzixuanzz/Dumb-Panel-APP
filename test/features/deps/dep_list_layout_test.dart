import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/network/dio_client.dart';
import 'package:daidai_app/features/deps/views/dep_list_page.dart';
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

/// 假面板：python 30 条、nodejs 2 条、linux 0 条；镜像源是腾讯云 / npmmirror。
FakeHttpAdapter _fakePanel() => FakeHttpAdapter((options) {
  if (options.path == ApiEndpoints.depsPythonRuntimes) {
    return jsonResponse({
      'data': [
        {
          'version': '3.12',
          'label': 'Python 3.12',
          'default': true,
          'available': true,
        },
      ],
      'default_version': '3.12',
    });
  }
  if (options.path == ApiEndpoints.depsMirrors) {
    return jsonResponse({
      'data': {
        'pip_mirror': 'https://mirrors.cloud.tencent.com/pypi/simple',
        'npm_mirror': 'https://registry.npmmirror.com',
        'linux_mirror': '',
        'linux_mirror_supported': false,
      },
    });
  }
  if (options.path == ApiEndpoints.deps) {
    final type = options.queryParameters['type'];
    final count = type == 'python' ? 30 : (type == 'nodejs' ? 2 : 0);
    return jsonResponse({
      'data': [
        for (var i = 0; i < count; i++)
          {
            'id': i + 1,
            'name': '$type-pkg$i',
            'type': type,
            'python_version': type == 'python' ? '3.12' : '',
            'status': 'installed',
            'created_at': '2026-10-01T08:00:00Z',
          },
      ],
      'total': count,
    });
  }
  return jsonResponse(<String, dynamic>{}, status: 404);
});

Future<void> _openPage(
  WidgetTester tester, {
  Size size = const Size(360, 800),
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  DioClient.instance.dio.httpClientAdapter = _fakePanel();
  await tester.pumpWidget(
    const ProviderScope(child: MaterialApp(home: DepListPage())),
  );
  await _pumpFrames(tester);
}

Future<void> _closePage(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues({});
    DioClient.instance.setBaseUrl('https://panel.test');
  });

  /// APP #23 ①：看 Python 依赖时计数卡、运行时面板、状态筛选钉在上方，列表只剩小半屏。
  group('依赖页头部随列表滚走（APP #23 ①）', () {
    for (final textScale in [1.0, 1.3]) {
      testWidgets('360×800、字号 $textScale：计数卡一行三个、不溢出；上滑后只剩标题行固定，列表占满', (
        tester,
      ) async {
        await _openPage(tester, textScale: textScale);
        await tester.tap(find.text('Python'));
        await _pumpFrames(tester);

        expect(tester.takeException(), isNull);
        expect(find.text('python-pkg0'), findsOneWidget);
        expect(find.text('Python 版本'), findsOneWidget);
        // 窄屏也一行三个
        final nodeTop = tester.getRect(find.text('NodeJS')).top;
        expect(tester.getRect(find.text('Python')).top, nodeTop);
        expect(tester.getRect(find.text('Linux')).top, nodeTop);

        final titleRect = tester.getRect(find.text('依赖管理'));
        await tester.drag(find.text('python-pkg0'), const Offset(0, -600));
        await _pumpFrames(tester);

        // 标题行不动；计数卡、筛选条已经滚到标题行底下（被裁掉或已回收）。
        expect(tester.getRect(find.text('依赖管理')), titleRect);
        for (final text in ['NodeJS', '全部']) {
          final finder = find.text(text);
          if (finder.evaluate().isNotEmpty) {
            expect(
              tester.getRect(finder).bottom,
              lessThanOrEqualTo(titleRect.bottom + 12),
              reason: text,
            );
          }
        }
        // 依赖卡片顶到了标题行下面：列表占满了整屏。
        final visibleCardTops = [
          for (var i = 0; i < 30; i++)
            if (find.text('python-pkg$i').evaluate().isNotEmpty)
              tester.getRect(find.text('python-pkg$i')).top,
        ].where((top) => top > titleRect.bottom && top < 800).toList();
        expect(visibleCardTops, isNotEmpty);
        expect(
          visibleCardTops.reduce((a, b) => a < b ? a : b),
          lessThan(titleRect.bottom + 120),
        );

        await _closePage(tester);
      });
    }

    // 「批量卸载」不能跟着头部滚走：用户是往下滑着勾选的，按钮必须一直在屏幕内可点。
    testWidgets('滚到列表下方勾选后，「批量卸载」仍在屏幕内且可点', (tester) async {
      await _openPage(tester);
      await tester.tap(find.text('Python'));
      await _pumpFrames(tester);
      // 没选中时不占位
      expect(find.textContaining('批量卸载'), findsNothing);

      await tester.drag(find.text('python-pkg0'), const Offset(0, -600));
      await _pumpFrames(tester);
      // 头部已经滚出视口，再勾一张滚到下方才露出来的卡（第 10 张以后）
      final target = [
        for (var i = 10; i < 30; i++) 'python-pkg$i',
      ].firstWhere((name) {
        final finder = find.text(name);
        if (finder.evaluate().isEmpty) return false;
        final rect = tester.getRect(finder);
        return rect.top > 200 && rect.bottom < 750;
      });
      await tester.tap(find.text(target));
      await _pumpFrames(tester);

      final button = find.text('批量卸载 (1)');
      expect(button, findsOneWidget);
      final rect = tester.getRect(button);
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(800));
      // 按钮固定在标题行下方，不被列表盖住：点得中，弹出确认框。
      expect(
        rect.top,
        greaterThanOrEqualTo(tester.getRect(find.text('依赖管理')).bottom),
      );
      await tester.tap(button);
      await _pumpFrames(tester);
      expect(find.text('确定要批量卸载选中的 1 个依赖吗？'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await _pumpFrames(tester);
      await _closePage(tester);
    });

    testWidgets('下拉刷新照常可用：头部在最上面时往下拉，会重新请求依赖列表', (tester) async {
      await _openPage(tester);
      final adapter = DioClient.instance.dio.httpClientAdapter as FakeHttpAdapter;
      final before = adapter.countOf(ApiEndpoints.deps);

      await tester.fling(find.text('NodeJS'), const Offset(0, 400), 1000);
      await _pumpFrames(tester, 60);

      expect(adapter.countOf(ApiEndpoints.deps), greaterThan(before));
      await _closePage(tester);
    });
  });

  /// 面板 #165：官方源现在原样保存、原样生效，APP 镜像源弹窗给直达选项。
  testWidgets('镜像源弹窗：点「PyPI 官方」「npm 官方」填入官方源地址', (tester) async {
    await _openPage(tester, size: const Size(800, 1600));
    await tester.tap(find.byTooltip('镜像源设置'));
    await _pumpFrames(tester);

    TextField field(String label) =>
        tester.widget<TextField>(find.widgetWithText(TextField, label));

    await tester.ensureVisible(find.text('PyPI 官方'));
    await tester.tap(find.text('PyPI 官方'));
    await tester.pump();
    expect(field('Python (pip)').controller!.text, 'https://pypi.org/simple');

    await tester.ensureVisible(find.text('npm 官方'));
    await tester.tap(find.text('npm 官方'));
    await tester.pump();
    expect(
      field('Node.js (npm)').controller!.text,
      'https://registry.npmjs.org/',
    );

    await _closePage(tester);
  });

  /// 面板 #166：方括号里的逗号不切，`httpx[http2,socks]` 要整个交给 pip。
  group('splitDependencyNames（面板 #166）', () {
    test('换行、逗号、空白照常切开', () {
      expect(splitDependencyNames('requests, httpx\nlxml  numpy'), [
        'requests',
        'httpx',
        'lxml',
        'numpy',
      ]);
    });

    test('方括号里的逗号不切：httpx[http2,socks] 保持完整', () {
      expect(splitDependencyNames('httpx[http2,socks], requests'), [
        'httpx[http2,socks]',
        'requests',
      ]);
    });

    test('方括号里的空格去掉：httpx[http2, socks] → httpx[http2,socks]', () {
      expect(splitDependencyNames('httpx[http2, socks]'), [
        'httpx[http2,socks]',
      ]);
    });

    test('带版本约束的 extras 原样保留', () {
      expect(splitDependencyNames('httpx[http2]>=0.27 requests==2.31.0'), [
        'httpx[http2]>=0.27',
        'requests==2.31.0',
      ]);
    });

    test('少写了 ]：换行照样切，不把后面几行吞成一个名字', () {
      expect(splitDependencyNames('httpx[http2\nrequests\nlxml'), [
        'httpx[http2',
        'requests',
        'lxml',
      ]);
    });

    test('空串与纯分隔符：一个名字都没有', () {
      expect(splitDependencyNames(''), isEmpty);
      expect(splitDependencyNames(' ,\n, '), isEmpty);
    });
  });
}
