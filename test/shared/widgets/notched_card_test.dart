import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/core/theme/design_tokens.dart';
import 'package:daidai_app/shared/widgets/notched_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 缺口卡片（方案书 §2.4）：圆角矩形减去右下缺口 + 两个反向圆角。
void main() {
  group('NotchedCardClipper 路径', () {
    const size = Size(360, 300);
    const notch = Size(208, 82);
    final path = const NotchedCardClipper(notchSize: notch).buildPath(size);
    // 缺口占 [152, 360] × [218, 300]
    const notchLeft = 360 - 208.0;
    const notchTop = 300 - 82.0;

    test('卡片主体在路径里', () {
      expect(path.contains(const Offset(180, 150)), isTrue);
      expect(path.contains(const Offset(20, 290)), isTrue, reason: '缺口左边的底部');
      expect(path.contains(const Offset(350, 100)), isTrue, reason: '缺口上方的右侧');
    });

    test('缺口被挖掉', () {
      expect(path.contains(const Offset(300, 280)), isFalse);
      expect(path.contains(const Offset(notchLeft + 40, notchTop + 10)), isFalse);
      expect(path.contains(const Offset(359, 299)), isFalse);
    });

    test('缺口左上角是圆角：角上那一小块属于卡片', () {
      // 缺口左上角 (152, 218) 往缺口里偏 4：圆角半径 32 外侧，仍是卡片
      expect(path.contains(const Offset(notchLeft + 4, notchTop + 4)), isTrue);
    });

    test('两处反向圆角：缺口上沿右端、底边缺口左端的尖角被削圆', () {
      // 右边：(359, 217) 在反向圆角之外（被削掉）
      expect(path.contains(const Offset(359, notchTop - 1)), isFalse);
      // 但离边稍远的点仍在卡片内
      expect(path.contains(const Offset(330, notchTop - 2)), isTrue);
      // 底边：(151, 299) 被削掉
      expect(path.contains(const Offset(notchLeft - 1, 299)), isFalse);
      expect(path.contains(const Offset(notchLeft - 2, 270)), isTrue);
    });

    test('四个外角是圆角', () {
      expect(path.contains(const Offset(1, 1)), isFalse);
      expect(path.contains(const Offset(359, 1)), isFalse);
      expect(path.contains(const Offset(1, 299)), isFalse);
    });

    test('卡片太矮装不下缺口时不抛异常', () {
      expect(
        () => const NotchedCardClipper(notchSize: notch).buildPath(const Size(100, 60)),
        returnsNormally,
      );
    });
  });

  testWidgets('缺口里的组件贴右下角、大小是缺口减去间隙；卡片底色走色板', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              child: NotchedCard(
                notch: const ColoredBox(key: Key('notch'), color: Colors.black),
                child: const SizedBox(height: 300, child: Text('内容')),
              ),
            ),
          ),
        ),
      ),
    );
    final card = tester.getRect(find.byType(NotchedCard));
    final notch = tester.getRect(find.byKey(const Key('notch')));
    expect(notch.right, card.right);
    expect(notch.bottom, card.bottom);
    expect(notch.size, const Size(208 - 12, 82 - 12));
    final box = tester.widget<ColoredBox>(
      find.ancestor(of: find.text('内容'), matching: find.byType(ColoredBox)).first,
    );
    expect(box.color, AppPalette.light.card);
  });
}
