import 'dart:math';

import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/core/theme/design_tokens.dart';
import 'package:daidai_app/shared/utils/log_background.dart';
import 'package:daidai_app/shared/utils/log_line_buffer.dart';
import 'package:daidai_app/shared/widgets/fullscreen_log_scaffold.dart';
import 'package:daidai_app/shared/widgets/log_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _firstErrorKey = Key('fullscreen-log-first-error');
const _copyKey = Key('fullscreen-log-copy');
const _openScriptKey = Key('fullscreen-log-open-script');
const _stopKey = Key('fullscreen-log-stop');
const _menuKey = Key('fullscreen-log-menu');
const _pillKey = Key('fullscreen-log-status-pill');
const _bannerKey = Key('fullscreen-log-error-banner');

final _ansi = RegExp(r'\x1b\[[0-9;?]*[A-Za-z]');

const _min = AppTapTarget.min;

/// 主题切换不做过渡动画：同一个用例里换明暗，下一帧就是新主题。
Widget _app(FullscreenLogScaffold scaffold, {ThemeData? theme}) => MaterialApp(
  theme: theme ?? AppTheme.light(),
  themeAnimationDuration: Duration.zero,
  home: scaffold,
);

FullscreenLogScaffold _scaffold(
  LogLineBuffer buffer, {
  FullscreenLogTone tone = FullscreenLogTone.running,
  String statusLabel = '运行中',
  String? subtitle = '任务 #7',
  VoidCallback? onStop,
  VoidCallback? onRerun,
  VoidCallback? onOpenScript,
  bool openScriptBusy = false,
  bool menuBusy = false,
  Color? configured,
  String? errorMessage,
  String emptyMessage = '无日志内容',
  String? copySuccessToast,
  String? truncatedCopyHint,
}) => FullscreenLogScaffold(
  title: '签到脚本',
  subtitle: subtitle,
  statusLabel: statusLabel,
  statusTone: tone,
  buffer: buffer,
  loading: false,
  emptyMessage: emptyMessage,
  errorMessage: errorMessage,
  configuredBackgroundColor: configured,
  onStop: onStop,
  onRerun: onRerun,
  onOpenScript: onOpenScript,
  openScriptBusy: openScriptBusy,
  menuBusy: menuBusy,
  copySuccessToast: copySuccessToast,
  truncatedCopyHint: truncatedCopyHint,
);

/// 运行态胶囊在呼吸、转圈是无限动画，不能 pumpAndSettle，固定推几帧。
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// 收尾：卸掉页面再把提示条、动画的定时器放完。
Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 3));
}

void _setView(WidgetTester tester, double width, {double textScale = 1.0}) {
  tester.view.physicalSize = Size(width, 780);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

List<String> _mockClipboard(WidgetTester tester) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
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
  return copied;
}

/// 不增量、每次从头扫一遍的对照实现。
({int? firstError, List<int> matches}) _bruteForce(
  LogLineBuffer buffer,
  String query,
) {
  final q = query.trim().toLowerCase();
  int? firstError;
  final matches = <int>[];
  for (var i = 0; i < buffer.length; i++) {
    final line = buffer.lineAt(i);
    final abs = buffer.droppedCount + i;
    if (firstError == null && looksLikeLogErrorLine(line)) {
      firstError = abs;
    }
    if (q.isNotEmpty &&
        line.replaceAll(_ansi, '').toLowerCase().contains(q)) {
      matches.add(abs);
    }
  }
  return (firstError: firstError, matches: matches);
}

List<int> _indexMatches(FullscreenLogIndex index) =>
    [for (var i = 0; i < index.matchCount; i++) index.matchAt(i)];

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('四态胶囊严格语义：失败态显示 ✕ 绝不显示 ✓，完成态显示 ✓', (tester) async {
    final buffer = LogLineBuffer()
      ..replaceAll(['[08:00:01] 开始运行', 'Error: 令牌已失效']);
    addTearDown(buffer.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: FullscreenLogScaffold(
          title: '阿里云盘签到',
          subtitle: '日志 #1084 · 耗时 2.4s',
          statusLabel: '退出码 1',
          statusTone: FullscreenLogTone.failed,
          buffer: buffer,
          loading: false,
          onRerun: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final pill = find.byKey(_pillKey);
    expect(
      find.descendant(of: pill, matching: find.byIcon(Icons.close_rounded)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: pill, matching: find.byIcon(Icons.check_rounded)),
      findsNothing,
    );
    expect(find.text('退出码 1'), findsOneWidget);
    // 发现报错行时底部自动露出「首处报错」定位芯片
    expect(find.byKey(_firstErrorKey), findsOneWidget);
    expect(find.byKey(const Key('fullscreen-log-rerun')), findsOneWidget);
  });

  testWidgets('页内搜索与独立护眼暗底切换、360 窄屏 1.3 倍字号无溢出', (tester) async {
    _setView(tester, 360, textScale: 1.3);

    final buffer = LogLineBuffer()
      ..replaceAll([
        for (var i = 0; i < 40; i++)
          i == 10 || i == 25 ? 'line $i TOKEN_EXPIRED' : 'line $i normal output',
      ]);
    addTearDown(buffer.dispose);

    var stopCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: FullscreenLogScaffold(
          title: '一个名字非常非常长的自动化脚本任务名称',
          subtitle: '日志 #2048 · 实时耗时 12.8s',
          statusLabel: '实时输出',
          statusTone: FullscreenLogTone.running,
          buffer: buffer,
          loading: false,
          onStop: () => stopCount++,
          onOpenScript: () {},
        ),
      ),
    );
    await _settle(tester);
    expect(tester.takeException(), isNull);

    // 默认是浅色暖纸底 #FAF9F6
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      AppColors.termBgLight,
    );

    // 点击顶栏切换独立护眼暗底 #14161A（不改变外层浅色 AppTheme）
    await tester.tap(find.byTooltip('切换护眼暗底终端'));
    await tester.pump();
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      AppColors.termBgDark,
    );
    expect(tester.takeException(), isNull);

    // 打开页内搜索并输入关键字
    await tester.tap(find.byTooltip('页内搜索'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'token_expired');
    await tester.pump();
    expect(find.text('1/2'), findsOneWidget);

    await tester.tap(find.byTooltip('下一处匹配'));
    await tester.pump();
    expect(find.text('2/2'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 底部停止运行按钮可点按
    await tester.tap(find.byKey(_stopKey));
    await tester.pump();
    expect(stopCount, 1);

    await _close(tester);
  });

  group('逐行追加：首处报错与搜索命中增量维护', () {
    test('5 万行逐行追加：每行最多判两次（报错一次、搜索一次），与从头扫的结果一致', () {
      final buffer = LogLineBuffer();
      addTearDown(buffer.dispose);
      final index = FullscreenLogIndex()..setQuery('needle');
      const total = 50000;
      for (var i = 0; i < total; i++) {
        final line = i == 5000 || i == 45000
            ? 'Error: boom $i'
            : i % 97 == 0
            ? 'x NEEDLE $i'
            : 'line $i ok';
        // SseClient 每条 data 行回调一次，页面每次 append 一行。
        buffer.append([line]);
        index.sync(buffer);
      }

      // 改前每来一行都把缓冲区（最多 1 万行）整个重扫：约 4.5 亿次。
      expect(index.debugScannedLines, lessThanOrEqualTo(2 * total));
      final expected = _bruteForce(buffer, 'needle');
      // 第 5000 行早被裁掉了，首处报错要前移到还留着的第 45000 行。
      expect(index.firstErrorLine, 45000);
      expect(index.firstErrorLine, expected.firstError);
      expect(_indexMatches(index), expected.matches);
    });

    test('随机追加 / 裁剪 / 整段替换 / 换查询词：逐步与从头扫一致', () {
      const vocabulary = [
        'plain output',
        'Error: 令牌已失效',
        '\x1b[31mNeedle\x1b[0m in red',
        '本次成功 3 个，失败 0 个',
        'needle here',
        '签到失败：Cookie 过期',
        '=== 执行结束 退出码 1 ===',
        'zz top',
      ];
      const queries = ['', 'needle', ' NEEDLE ', 'err', 'zz', '失败'];
      for (final maxLines in const [1, 7, 50]) {
        final rng = Random(maxLines);
        final buffer = LogLineBuffer(maxLines: maxLines);
        final index = FullscreenLogIndex();
        var query = '';
        var serial = 0;
        String next() => '${vocabulary[rng.nextInt(vocabulary.length)]} '
            '#${serial++}';
        for (var step = 0; step < 800; step++) {
          final roll = rng.nextInt(100);
          if (roll < 55) {
            buffer.append([next()]);
          } else if (roll < 75) {
            final count = rng.nextInt(30);
            buffer.append([for (var i = 0; i < count; i++) next()]);
          } else if (roll < 85) {
            buffer.holdTrim = rng.nextBool();
          } else if (roll < 92) {
            final count = rng.nextInt(40);
            buffer.replaceAll([for (var i = 0; i < count; i++) next()]);
          } else {
            query = queries[rng.nextInt(queries.length)];
            index.setQuery(query);
          }
          index.sync(buffer);
          final expected = _bruteForce(buffer, query);
          if (index.firstErrorLine != expected.firstError) {
            fail(
              'maxLines=$maxLines step=$step 首处报错 '
              '${index.firstErrorLine} != ${expected.firstError}',
            );
          }
          if (_indexMatches(index).join(',') != expected.matches.join(',')) {
            fail('maxLines=$maxLines step=$step 搜索命中不一致');
          }
        }
        buffer.dispose();
      }
    });

    testWidgets('5 万行逐行追加：整页只在派生状态变化时重建，行数照常刷新', (tester) async {
      final buffer = LogLineBuffer();
      addTearDown(buffer.dispose);
      await tester.pumpWidget(_app(_scaffold(buffer, onStop: () {})));
      await _settle(tester);

      // 整页重建一次就会造一个新的 LogView 配置对象；没重建时还是同一个。
      final logViews = <LogView>{};
      var frames = 0;
      for (var i = 0; i < 50000; i++) {
        buffer.append([
          i == 5000 || i == 45000 ? 'Error: boom $i' : 'line $i ok',
        ]);
        if (i % 500 == 499) {
          await tester.pump(const Duration(milliseconds: 16));
          frames++;
          logViews.add(tester.widget<LogView>(find.byType(LogView)));
        }
      }
      expect(frames, 100);
      // 只有这几次：有了第一行、出现首处报错、开始截断、首处报错被裁掉、
      // 第二处报错到来。改前是每帧都重建（100 次）。
      expect(logViews.length, lessThanOrEqualTo(6));
      // 顶栏行数是局部刷新的，照样跟上。
      expect(find.text('任务 #7 · 50000 行'), findsOneWidget);

      await tester.tap(find.byKey(_firstErrorKey));
      await tester.pump();
      expect(find.text('已定位至第 45001 行报错输出'), findsOneWidget);

      await _close(tester);
    });
  });

  group('首处报错的判定', () {
    test('计数写法、成功回包、面板分隔行不算报错', () {
      const benign = [
        '本次成功 12 个，失败 0 个',
        '共 3 个账号，0 个失败',
        '失败：0',
        'Tests: 10 passed, 0 failed',
        '0 errors, 2 warnings',
        'no errors found',
        '{"error_code":0,"msg":"ok"}',
        '{"code":200,"error":null}',
        '{"errors": [], "data": {}}',
        'failed_count=0',
        '=== 执行结束 [2026-11-27 08:00:00] 耗时 1.20 秒 退出码 1 ===',
        '[进程结束, 退出码: 0, 耗时: 1.00秒]',
        '签到完成，获得 10 积分',
        // Python dict、Node console.log 打出来的对象（键不带引号）。
        "{'error': None, 'data': []}",
        "{ code: 0, msg: 'ok', error: null }",
        '{ success: true, failed: false }',
        'error_count: 0',
        'error=nil',
        'Errors: 0',
        'Passed: 10, Failed: 0',
      ];
      for (final line in benign) {
        expect(looksLikeLogErrorLine(line), isFalse, reason: line);
      }
    });

    test('真正的报错行照样认得出来', () {
      const errors = [
        'Error: 令牌已失效',
        "TypeError: Cannot read properties of undefined (reading 'x')",
        'java.lang.NullPointerException',
        'Traceback (most recent call last):',
        '签到失败：Cookie 已过期',
        '本次成功 10 个，失败 2 个',
        '{"error_code":40001,"msg":"invalid token"}',
        'error: 0x80070005',
        '[进程异常退出, 退出码: 1, 耗时: 2.00秒]',
        '[进程结束, 退出码: 2, 耗时: 1.00秒]',
        '\x1b[31mERROR\x1b[0m something broke',
        'Request timed out',
        'open /data/x: permission denied',
        // 异常名或 Error 前缀后面跟着 0 / null / None / False，照样是报错。
        'Error: None of the accounts logged in',
        'Error: nonexistent key token',
        'AssertionError: False is not true',
        'java.lang.NullPointerException: null',
        "TypeError: null is not an object (evaluating 'a.b')",
        'Exception: None',
        'KeyError: 0',
        'ValueError: 0 is not a valid choice',
        'error: nil pointer dereference',
        'at main, TypeError: null is not a function',
      ];
      for (final line in errors) {
        expect(looksLikeLogErrorLine(line), isTrue, reason: line);
      }
    });

    // 关键词与面板「需要关注」、日志列表的错误行是同一张表：列表把这一行当
    // 错误行显示，点进全屏日志也要有「首处报错」。
    test('超时、拒绝、不存在、failure、not found 也认得出来', () {
      const errors = [
        '❌ 账号1: 请求超时',
        '连接被拒绝',
        '账号不存在',
        'Cookie 不存在',
        '找不到配置文件 sendNotify.js',
        'Login failure',
        'connect ECONNREFUSED 127.0.0.1:443',
        '404 Not Found',
        'Request timeout',
        'AxiosError: timeout of 5000ms exceeded',
        'timeout of 5000ms exceeded',
        'socket timeout: 30 seconds exceeded',
        'Read timed out. (read timeout=10)',
        '签到失败 timeout: 30000',
        'Access denied',
      ];
      for (final line in errors) {
        expect(looksLikeLogErrorLine(line), isTrue, reason: line);
      }
    });

    test('超时、失败的计数与配置写法不算报错', () {
      const benign = [
        'timeout: 30',
        'timeout=30s',
        'timeout=5m',
        '"timeout": 30000,',
        '{ timeout: 10000, retries: 3 }',
        'connectTimeout: 5000, readTimeout: 10000',
        'read_timeout=10',
        '超时时间：30 秒',
        '超时 0 次',
        '共 5 个请求，0 个超时',
        '0 timeouts',
        'Passed: 10, Fails: 0',
        'failCount: 0',
        'errorCount: 0',
        'timeouts: 0',
      ];
      for (final line in benign) {
        expect(looksLikeLogErrorLine(line), isFalse, reason: line);
      }
    });

    // 定时任务多在整点、整分启动，开头一秒就挂的脚本行首时间是 08:00:00：
    // 时间末尾的 00 不能读成「0 个失败」「0 errors」。
    test('紧挨着整点时间的报错照样认得出来', () {
      const errors = [
        '2026-11-27 08:00:00 ERROR something broke',
        '2026/11/27 08:00:00 error: token expired',
        '08:00:00 FATAL out of memory',
        '2026-11-27 08:00:00 超时',
        '08:00:00 fail',
        '08:00 失败',
        '08:00:00,000 ERROR boom',
        '08:00:00.000 ERROR boom',
        'Found 1,000 errors',
        // 时间在关键词后面：「: 00」后面跟的是冒号，不是「计数为 0」。
        'ERROR: 00:00:05 task crashed',
        '失败 00:00:05 重试',
      ];
      for (final line in errors) {
        expect(looksLikeLogErrorLine(line), isTrue, reason: line);
      }
      const benign = [
        '08:00:00 0 errors',
        '08:00:00 no errors',
        '2026-11-27 08:00:00 本次成功 3 个，失败 0 个',
        '08:00:00 共 3 个账号，0 个失败',
        '08:00:00 Errors: 0',
      ];
      for (final line in benign) {
        expect(looksLikeLogErrorLine(line), isFalse, reason: line);
      }
    });

    // Node 的 console.log 打长一点的对象会拆成多行，每个属性单占一行、
    // 缩进两格；面板按行转发时缩进原样保留。
    test('多行对象里缩进的「键: 空值」不算报错，缩进的报错行照样算', () {
      const benign = [
        '  error: null,',
        '  errorCode: 0,',
        '  failed: false',
        '  errors: [],',
        '  error: undefined,',
        '  lastError: null',
        '  timeout: 0,',
        '\terror: null',
      ];
      for (final line in benign) {
        expect(looksLikeLogErrorLine(line), isFalse, reason: line);
      }
      const errors = [
        'KeyError: 0',
        'E   KeyError: 0',
        // 异常名大写开头：缩进了也不当成数据字段。
        '    KeyError: 0',
        '  TypeError: null is not a function',
        '  error: 0x80070005,',
        "  error: 'token expired',",
        '  error: null, failed: true',
        'Error: undefined',
      ];
      for (final line in errors) {
        expect(looksLikeLogErrorLine(line), isTrue, reason: line);
      }
    });

    testWidgets('成功日志里 console.log 的多行回包不冒出「首处报错」', (tester) async {
      final buffer = LogLineBuffer()
        ..replaceAll([
          '=== 开始执行 [2026-11-27 08:00:00] ===',
          '{',
          '  code: 0,',
          "  message: 'success',",
          '  errorCode: 0,',
          '  error: null,',
          '  data: { points: 10 }',
          '}',
          '=== 执行结束 [2026-11-27 08:00:03] 耗时 3.00 秒 退出码 0 ===',
        ]);
      addTearDown(buffer.dispose);
      await tester.pumpWidget(
        _app(
          _scaffold(
            buffer,
            tone: FullscreenLogTone.success,
            statusLabel: '已完成',
            onRerun: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(_firstErrorKey), findsNothing);
    });

    testWidgets('完全成功的签到日志不冒出红色「首处报错」', (tester) async {
      final buffer = LogLineBuffer()
        ..replaceAll([
          '=== 开始执行 [2026-11-27 08:00:00] ===',
          '账号 1 签到成功',
          '{"code":0,"error":null,"data":{"points":10}}',
          '本次成功 12 个，失败 0 个',
          '=== 执行结束 [2026-11-27 08:00:03] 耗时 3.00 秒 退出码 0 ===',
        ]);
      addTearDown(buffer.dispose);
      await tester.pumpWidget(
        _app(
          _scaffold(
            buffer,
            tone: FullscreenLogTone.success,
            statusLabel: '已完成',
            onRerun: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(_firstErrorKey), findsNothing);
    });
  });

  testWidgets('页内搜索不设命中上限：600 处都数得到、跳得到，新来的命中也接得上', (
    tester,
  ) async {
    final buffer = LogLineBuffer()
      ..replaceAll([
        for (var i = 0; i < 1200; i++)
          i.isEven ? 'INFO step $i' : 'debug $i',
      ]);
    addTearDown(buffer.dispose);
    await tester.pumpWidget(_app(_scaffold(buffer)));
    await _settle(tester);

    await tester.tap(find.byTooltip('页内搜索'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'info');
    await tester.pump();
    expect(find.text('1/600'), findsOneWidget);

    // 从第一处往回跳，绕到最后一处（以前只收集前 500 处，最后的跳不到）。
    await tester.tap(find.byTooltip('上一处匹配'));
    await tester.pump();
    expect(find.text('600/600'), findsOneWidget);

    // 页面不重建，运行中又来了一处命中：计数跟上，也跳得过去。
    buffer.append(['INFO new tail']);
    await tester.pump();
    expect(find.text('600/601'), findsOneWidget);
    await tester.tap(find.byTooltip('下一处匹配'));
    await tester.pump();
    expect(find.text('601/601'), findsOneWidget);

    await _close(tester);
  });

  testWidgets('表头那处命中被裁掉、末尾又来一处：高亮挪到还留着的第一处', (
    tester,
  ) async {
    // 跟随中缓冲区已满、搜的是每行都有的词：每来一行就裁掉最老的一处命中，
    // 又补上一处，命中数不变、游标夹在 0。
    final buffer = LogLineBuffer(maxLines: 5)
      ..replaceAll([for (var i = 0; i < 5; i++) 'INFO step $i']);
    addTearDown(buffer.dispose);
    await tester.pumpWidget(_app(_scaffold(buffer)));
    await _settle(tester);

    await tester.tap(find.byTooltip('页内搜索'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'info');
    await tester.pump();
    int? active() => tester
        .widget<LogView>(find.byType(LogView))
        .activeMatchAbsoluteLine;
    expect(find.text('1/5'), findsOneWidget);
    expect(active(), 0);

    // 跳到命中会暂停跟随（暂缓裁剪）；点「恢复跟随」回到贴底跟随。
    await tester.tap(find.textContaining('恢复跟随'));
    await _settle(tester);
    expect(buffer.holdTrim, isFalse);

    for (var i = 5; i < 9; i++) {
      buffer.append(['INFO step $i']);
      await tester.pump();
      expect(find.text('1/5'), findsOneWidget);
      // 还留在缓冲区里的第一行就是第一处命中。
      expect(active(), buffer.droppedCount, reason: 'append #$i');
    }

    await _close(tester);
  });

  testWidgets('底栏芯片：带字的不再套 Tooltip，缩成图标的才有', (tester) async {
    // 360dp 下「复制」「跳脚本」缩成图标，「首处报错」仍带字。
    _setView(tester, 360);
    final handle = tester.ensureSemantics();
    final buffer = LogLineBuffer(maxLines: 30)
      ..replaceAll([
        for (var i = 0; i < 40; i++)
          i == 33 ? 'Error: 令牌已失效' : 'line $i ok',
      ]);
    addTearDown(buffer.dispose);
    await tester.pumpWidget(
      _app(_scaffold(buffer, onStop: () {}, onOpenScript: () {})),
    );
    await _settle(tester);

    final firstError = find.byKey(_firstErrorKey);
    expect(
      find.descendant(of: firstError, matching: find.text('首处报错')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: firstError, matching: find.byType(Tooltip)),
      findsNothing,
    );
    // TalkBack 只读一遍：节点上有文字标签，没有重复的 tooltip。
    final node = tester.getSemantics(find.bySemanticsLabel('首处报错'));
    expect(node.tooltip, isEmpty);

    expect(
      find.descendant(
        of: find.byKey(_openScriptKey),
        matching: find.byTooltip('跳脚本'),
      ),
      findsOneWidget,
    );

    handle.dispose();
    await _close(tester);
  });

  group('底栏在常见手机宽度下「首处报错」不被挤出屏幕', () {
    for (final (width, scale) in const [
      (360.0, 1.0),
      (360.0, 1.3),
      (360.0, 2.0),
      (411.0, 1.0),
      (411.0, 1.3),
    ]) {
      testWidgets('${width.toInt()}dp × $scale', (tester) async {
        _setView(tester, width, textScale: scale);
        // 截断后「复制」芯片的字更长，一起覆盖到。
        final buffer = LogLineBuffer(maxLines: 30)
          ..replaceAll([
            for (var i = 0; i < 40; i++)
              i == 33 ? 'Error: 令牌已失效' : 'line $i ok',
          ]);
        addTearDown(buffer.dispose);
        var stopCount = 0;
        await tester.pumpWidget(
          _app(
            _scaffold(
              buffer,
              onStop: () => stopCount++,
              onOpenScript: () {},
            ),
          ),
        );
        await _settle(tester);
        expect(tester.takeException(), isNull);

        for (final key in [_stopKey, _firstErrorKey, _openScriptKey]) {
          final rect = tester.getRect(find.byKey(key));
          expect(rect.left, greaterThanOrEqualTo(0), reason: '$key');
          expect(rect.right, lessThanOrEqualTo(width), reason: '$key');
          expect(
            rect.height,
            greaterThanOrEqualTo(_min),
            reason: '$key',
          );
        }

        // 真点得中：命中测试落在芯片上。
        await tester.tap(find.byKey(_firstErrorKey));
        await tester.pump();
        expect(find.text('已定位至第 34 行报错输出'), findsOneWidget);
        await tester.tap(find.byKey(_stopKey));
        await tester.pump();
        expect(stopCount, 1);

        await _close(tester);
      });
    }
  });

  testWidgets('可点区域都不小于 44dp（顶栏、搜索栏、底栏）', (tester) async {
    _setView(tester, 360);
    final buffer = LogLineBuffer()
      ..replaceAll(['line 1', 'Error: 令牌已失效', 'line 3']);
    addTearDown(buffer.dispose);
    await tester.pumpWidget(
      _app(_scaffold(buffer, onStop: () {}, onOpenScript: () {})),
    );
    await _settle(tester);
    await tester.tap(find.byTooltip('页内搜索'));
    await tester.pump();

    Size iconButton(String tooltip) => tester.getSize(
      find.ancestor(
        of: find.byTooltip(tooltip),
        matching: find.byType(IconButton),
      ),
    );
    for (final tooltip in const [
      '页内搜索',
      '切换护眼暗底终端',
      '上一处匹配',
      '下一处匹配',
      '关闭搜索',
    ]) {
      final size = iconButton(tooltip);
      expect(size.width, greaterThanOrEqualTo(_min), reason: tooltip);
      expect(size.height, greaterThanOrEqualTo(_min), reason: tooltip);
    }
    final menu = tester.getSize(find.byKey(_menuKey));
    expect(menu.width, greaterThanOrEqualTo(_min));
    expect(menu.height, greaterThanOrEqualTo(_min));
    for (final key in [_stopKey, _firstErrorKey, _copyKey, _openScriptKey]) {
      final size = tester.getSize(find.byKey(key));
      expect(size.height, greaterThanOrEqualTo(_min), reason: '$key');
      expect(size.width, greaterThanOrEqualTo(_min), reason: '$key');
    }

    await _close(tester);
  });

  testWidgets('状态胶囊四态的文字压在胶囊底上都 ≥ 4.5:1', (tester) async {
    final buffer = LogLineBuffer()..replaceAll(['line 1']);
    addTearDown(buffer.dispose);
    final cases = <(String, ThemeData, Color?)>[
      ('浅色默认', AppTheme.light(), null),
      ('深色默认', AppTheme.dark(), null),
      ('自定义 Nord 深底', AppTheme.light(), const Color(0xFF2E3440)),
      ('自定义 One Dark', AppTheme.dark(), const Color(0xFF282C34)),
      ('自定义纯白', AppTheme.dark(), const Color(0xFFFFFFFF)),
    ];
    for (final (name, theme, configured) in cases) {
      for (final tone in FullscreenLogTone.values) {
        await tester.pumpWidget(
          _app(
            _scaffold(
              buffer,
              tone: tone,
              statusLabel: '状态文字',
              configured: configured,
            ),
            theme: theme,
          ),
        );
        await tester.pump();
        final pill = find.byKey(_pillKey);
        final decoration =
            tester.widget<Container>(pill).decoration! as BoxDecoration;
        final text = tester.widget<Text>(
          find.descendant(of: pill, matching: find.text('状态文字')),
        );
        final logTheme = resolveLogSurfaceTheme(
          configured,
          themeBrightness: theme.brightness,
        );
        final under = Color.alphaBlend(
          decoration.color!,
          logTheme.barBackground,
        );
        expect(
          logContrastRatio(text.style!.color!, under),
          greaterThanOrEqualTo(kLogMinTextContrast),
          reason: '$name / $tone',
        );
      }
    }
    await _close(tester);
  });

  group('护眼暗底按钮', () {
    testWidgets('深色主题、面板没配色：底色本来就是暗底，顶栏不放这颗按钮，⋮ 里的偏好照旧', (
      tester,
    ) async {
      final buffer = LogLineBuffer()..replaceAll(['line 1']);
      addTearDown(buffer.dispose);
      await tester.pumpWidget(
        _app(_scaffold(buffer), theme: AppTheme.dark()),
      );
      await _settle(tester);

      expect(
        tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        AppColors.termBgDark,
      );
      expect(find.byTooltip('切换护眼暗底终端'), findsNothing);
      expect(find.byTooltip('恢复默认日志底色'), findsNothing);

      await tester.tap(find.byKey(_menuKey));
      await _settle(tester);
      expect(find.text('独立护眼暗底 (#14161A)'), findsOneWidget);

      await _close(tester);
    });

    testWidgets('面板配了深色日志底：同样不放', (tester) async {
      final buffer = LogLineBuffer()..replaceAll(['line 1']);
      addTearDown(buffer.dispose);
      await tester.pumpWidget(
        _app(_scaffold(buffer, configured: const Color(0xFF000000))),
      );
      await _settle(tester);
      expect(find.byTooltip('切换护眼暗底终端'), findsNothing);
      await _close(tester);
    });

    testWidgets('浅色底：月亮 = 切到暗底，开启后换太阳、再点恢复浅底', (tester) async {
      final buffer = LogLineBuffer()..replaceAll(['line 1']);
      addTearDown(buffer.dispose);
      await tester.pumpWidget(_app(_scaffold(buffer)));
      await _settle(tester);

      Color background() =>
          tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor!;

      final off = find.byTooltip('切换护眼暗底终端');
      expect(
        find.descendant(
          of: off,
          matching: find.byIcon(Icons.dark_mode_outlined),
        ),
        findsOneWidget,
      );
      expect(background(), AppColors.termBgLight);

      await tester.tap(off);
      await tester.pump();
      expect(background(), AppColors.termBgDark);
      final on = find.byTooltip('恢复默认日志底色');
      expect(
        find.descendant(
          of: on,
          matching: find.byIcon(Icons.light_mode_outlined),
        ),
        findsOneWidget,
      );

      await tester.tap(on);
      await tester.pump();
      expect(background(), AppColors.termBgLight);

      await _close(tester);
    });
  });

  group('页面代理用的参数', () {
    testWidgets('复制提示在点击时现算：页面没重建、缓冲区涨过上限也说「最近 N 行」', (
      tester,
    ) async {
      final copied = _mockClipboard(tester);
      final buffer = LogLineBuffer(maxLines: 5)..replaceAll(['a', 'b', 'c']);
      addTearDown(buffer.dispose);
      await tester.pumpWidget(
        _app(
          _scaffold(
            buffer,
            tone: FullscreenLogTone.success,
            statusLabel: '已完成',
            copySuccessToast: '已复制调试日志',
            truncatedCopyHint: '完整日志请下载原始日志',
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(_copyKey));
      await tester.pump();
      expect(find.text('已复制调试日志'), findsOneWidget);
      expect(copied.last, 'a\nb\nc');

      // 页面（父级）不重建，缓冲区继续涨过上限。
      buffer.append(['d', 'e', 'f', 'g']);
      await tester.pump();
      expect(find.text('复制最近 5 行'), findsOneWidget);

      await tester.tap(find.byKey(_copyKey));
      await tester.pump();
      expect(find.text('已复制最近 5 行，完整日志请下载原始日志'), findsOneWidget);
      expect(copied.last, 'c\nd\ne\nf\ng');

      await _close(tester);
    });

    testWidgets('截断时没给引导就只说「已复制最近 N 行」', (tester) async {
      _mockClipboard(tester);
      final buffer = LogLineBuffer(maxLines: 3)
        ..replaceAll(['a', 'b', 'c', 'd']);
      addTearDown(buffer.dispose);
      await tester.pumpWidget(
        _app(
          _scaffold(
            buffer,
            tone: FullscreenLogTone.success,
            copySuccessToast: '日志已复制',
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(_copyKey));
      await tester.pump();
      expect(find.text('已复制最近 3 行'), findsOneWidget);
      await _close(tester);
    });

    testWidgets('errorMessage：整宽、不截断、日志空不空都显示', (tester) async {
      _setView(tester, 360);
      const message =
          '安装日志连接已断开：面板可能正在重启或网络已中断，请稍后从依赖列表重新打开这条安装日志';
      final buffer = LogLineBuffer();
      addTearDown(buffer.dispose);
      Widget page(String? error) => _app(
        _scaffold(
          buffer,
          tone: FullscreenLogTone.failed,
          statusLabel: '连接已断开',
          emptyMessage: '无安装日志内容',
          errorMessage: error,
        ),
      );

      await tester.pumpWidget(page(message));
      await tester.pump();
      final banner = find.byKey(_bannerKey);
      expect(banner, findsOneWidget);
      expect(tester.getSize(banner).width, 360);
      expect(find.text(message), findsOneWidget);
      final paragraph = tester.renderObject<RenderParagraph>(
        find.text(message),
      );
      expect(paragraph.didExceedMaxLines, isFalse);
      // 空态照常显示在正文中央。
      expect(find.text('无安装日志内容'), findsOneWidget);

      final decoration =
          tester.widget<Container>(banner).decoration! as BoxDecoration;
      final text = tester.widget<Text>(find.text(message));
      expect(
        logContrastRatio(text.style!.color!, decoration.color!),
        greaterThanOrEqualTo(kLogMinTextContrast),
      );
      // 字用的是错误墨色（浅色默认底上原样够读）。
      expect(text.style!.color, AppPalette.light.errInk);

      // 已经有日志时也显示。
      buffer.append(['line 1', 'line 2']);
      await tester.pump();
      expect(find.byType(LogView), findsOneWidget);
      expect(find.byKey(_bannerKey), findsOneWidget);

      await tester.pumpWidget(page(null));
      await tester.pump();
      expect(find.byKey(_bannerKey), findsNothing);
      expect(tester.takeException(), isNull);

      await _close(tester);
    });

    testWidgets('menuBusy：⋮ 换成小转圈，菜单照样能点开', (tester) async {
      final buffer = LogLineBuffer()..replaceAll(['line 1']);
      addTearDown(buffer.dispose);
      await tester.pumpWidget(_app(_scaffold(buffer, menuBusy: true)));
      await _settle(tester);

      final menu = find.byKey(_menuKey);
      expect(
        find.descendant(
          of: menu,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: menu, matching: find.byIcon(Icons.more_vert)),
        findsNothing,
      );

      await tester.tap(menu);
      await _settle(tester);
      expect(find.text('自动换行'), findsOneWidget);

      await _close(tester);
    });

    testWidgets('menuBusy 默认 false：⋮ 是普通图标', (tester) async {
      final buffer = LogLineBuffer()..replaceAll(['line 1']);
      addTearDown(buffer.dispose);
      await tester.pumpWidget(_app(_scaffold(buffer)));
      await _settle(tester);
      final menu = find.byKey(_menuKey);
      expect(
        find.descendant(of: menu, matching: find.byIcon(Icons.more_vert)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: menu,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
      );
      await _close(tester);
    });

    testWidgets('openScriptBusy：跳脚本芯片转圈且不响应', (tester) async {
      final buffer = LogLineBuffer()..replaceAll(['line 1']);
      addTearDown(buffer.dispose);
      var opened = 0;
      await tester.pumpWidget(
        _app(
          _scaffold(buffer, onOpenScript: () => opened++, openScriptBusy: true),
        ),
      );
      await _settle(tester);
      final chip = find.byKey(_openScriptKey);
      expect(
        find.descendant(
          of: chip,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      await tester.tap(chip);
      await tester.pump();
      expect(opened, 0);
      await _close(tester);
    });
  });
}
