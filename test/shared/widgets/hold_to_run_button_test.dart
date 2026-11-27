import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/core/theme/design_tokens.dart';
import 'package:daidai_app/shared/widgets/hold_to_run_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 按住运行（PRD A2）：0.7 秒走满才触发 + 轻振；中途松手回弹取消；
/// 减少动画时进度条照常走。
void main() {
  late List<String> haptics;

  setUp(() {
    haptics = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments as String);
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> pump(
    WidgetTester tester, {
    required VoidCallback onConfirmed,
    bool enabled = true,
    bool reduceMotion = false,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
          child: child!,
        ),
        home: Scaffold(
          body: Center(
            child: HoldToRunButton(
              label: '按住运行',
              onConfirmed: onConfirmed,
              enabled: enabled,
            ),
          ),
        ),
      ),
    );
  }

  double progress(WidgetTester tester) => tester
      .widget<FractionallySizedBox>(find.byKey(const Key('hold-to-run-progress')))
      .widthFactor!;

  testWidgets('按住 0.7 秒：触发一次并轻振（mediumImpact），松手不再触发', (tester) async {
    var confirmed = 0;
    await pump(tester, onConfirmed: () => confirmed++);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(HoldToRunButton)),
    );
    // 先推一帧让动画的计时器起步（Ticker 从按下后的第一帧开始计时）
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(confirmed, 0);
    expect(progress(tester), closeTo(0.5, 0.1));

    await tester.pump(const Duration(milliseconds: 400));
    expect(confirmed, 1);
    expect(haptics, ['HapticFeedbackType.mediumImpact']);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(confirmed, 1, reason: '走满之后松手不会再触发一次');
    expect(progress(tester), 0);
  });

  testWidgets('中途松手：不触发、不振动，进度条回弹到 0', (tester) async {
    var confirmed = 0;
    await pump(tester, onConfirmed: () => confirmed++);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(HoldToRunButton)),
    );
    // 先推一帧让动画的计时器起步（Ticker 从按下后的第一帧开始计时）
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final atRelease = progress(tester);
    expect(atRelease, greaterThan(0.5));
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(progress(tester), lessThan(atRelease), reason: '回弹中');
    await tester.pumpAndSettle();

    expect(confirmed, 0);
    expect(haptics, isEmpty);
    expect(progress(tester), 0);
  });

  testWidgets('手指滑走（被横向滑动抢走）：取消', (tester) async {
    var confirmed = 0;
    await pump(tester, onConfirmed: () => confirmed++);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(HoldToRunButton)),
    );
    // 先推一帧让动画的计时器起步（Ticker 从按下后的第一帧开始计时）
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.moveBy(const Offset(120, 0));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(confirmed, 0);
  });

  testWidgets('减少动画：进度条照常走，0.7 秒照样触发', (tester) async {
    var confirmed = 0;
    await pump(tester, onConfirmed: () => confirmed++, reduceMotion: true);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(HoldToRunButton)),
    );
    // 先推一帧让动画的计时器起步（Ticker 从按下后的第一帧开始计时）
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(progress(tester), closeTo(0.5, 0.1));
    await tester.pump(const Duration(milliseconds: 400));
    expect(confirmed, 1);
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('禁用：按住不走进度、不触发', (tester) async {
    var confirmed = 0;
    await pump(tester, onConfirmed: () => confirmed++, enabled: false);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(HoldToRunButton)),
    );
    // 先推一帧让动画的计时器起步（Ticker 从按下后的第一帧开始计时）
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(confirmed, 0);
    expect(progress(tester), 0);
  });

  testWidgets('被外面的紧约束撑大（缺口 196 × 70）：图标圆按实际高度算、上下居中、不被裁', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Center(
            // 名义尺寸是默认的 164 × 46，外面强制 196 × 70
            child: SizedBox(
              width: 196,
              height: 70,
              child: HoldToRunButton(
                label: '按住运行',
                radius: AppRadius.md,
                onConfirmed: () {},
              ),
            ),
          ),
        ),
      ),
    );
    final button = tester.getRect(find.byType(HoldToRunButton));
    expect(button.size, const Size(196, 70));
    final icon = tester.getRect(find.byKey(const Key('hold-to-run-icon')));
    expect(icon.height, 38, reason: '(70 - 14) 夹到上限 38，不是按名义高度 46 算的 32');
    expect(icon.center.dy, moreOrLessEquals(button.center.dy));
    // 离左边与离上下一样远
    expect(icon.left - button.left, moreOrLessEquals(icon.top - button.top));
    final deco =
        tester
                .widget<Container>(
                  find
                      .descendant(
                        of: find.byType(HoldToRunButton),
                        matching: find.byType(Container),
                      )
                      .first,
                )
                .decoration
            as BoxDecoration;
    expect(deco.borderRadius, BorderRadius.circular(AppRadius.md));
  });

  testWidgets('默认外形仍是胶囊，名义尺寸下图标圆与左端半圆同心', (tester) async {
    await pump(tester, onConfirmed: () {});
    final button = tester.getRect(find.byType(HoldToRunButton));
    expect(button.size, const Size(164, 46));
    final icon = tester.getRect(find.byKey(const Key('hold-to-run-icon')));
    expect(icon.center.dy, moreOrLessEquals(button.center.dy));
    expect(icon.center.dx - button.left, moreOrLessEquals(button.height / 2));
    final deco =
        tester
                .widget<Container>(
                  find
                      .descendant(
                        of: find.byType(HoldToRunButton),
                        matching: find.byType(Container),
                      )
                      .first,
                )
                .decoration
            as BoxDecoration;
    expect(deco.borderRadius, BorderRadius.circular(AppRadius.pill));
  });

  testWidgets('读屏：长按动作直接确认', (tester) async {
    final handle = tester.ensureSemantics();
    var confirmed = 0;
    await pump(tester, onConfirmed: () => confirmed++);
    final node = tester.getSemantics(find.byType(HoldToRunButton));
    expect(node.label, '按住运行');
    tester.semantics.longPress(find.semantics.byLabel('按住运行'));
    await tester.pump();
    expect(confirmed, 1);
    handle.dispose();
  });
}
