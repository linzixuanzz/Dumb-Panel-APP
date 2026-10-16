import 'package:daidai_app/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // APP #17：长按输入框的系统菜单要是中文。
  testWidgets('APP 本地化配置下系统菜单文案为中文', (tester) async {
    late MaterialLocalizations l10n;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh', 'CN'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: appSupportedLocales,
        home: Builder(
          builder: (context) {
            l10n = MaterialLocalizations.of(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(l10n.copyButtonLabel, '复制');
    expect(l10n.pasteButtonLabel, '粘贴');
    expect(l10n.selectAllButtonLabel, '全选');
  });
}
