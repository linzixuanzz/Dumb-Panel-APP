import 'package:daidai_app/core/router/default_landing_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// v2.0 底栏改版后的「默认打开页面」（design §3）：
/// 选项变成 任务 / 日志 / 概览 / 变量；v1.x 存的旧值 `dashboard`（主页）按任务处理并回写。
void main() {
  setUp(DefaultLandingPage.resetForTest);
  tearDown(DefaultLandingPage.resetForTest);

  test('选项与顺序：任务 / 日志 / 概览 / 变量', () {
    expect(DefaultLandingPage.options.keys.toList(), [
      'tasks',
      'logs',
      'overview',
      'envs',
    ]);
    expect(DefaultLandingPage.options.values.toList(), ['任务', '日志', '概览', '变量']);
  });

  test('旧值 dashboard：落到任务，并把新值写回本机', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      DefaultLandingPage.prefsKey: 'dashboard',
    });
    await DefaultLandingPage.load();
    expect(DefaultLandingPage.value, 'tasks');
    expect(DefaultLandingPage.route, '/tasks');
    expect(DefaultLandingPage.label, '任务');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(DefaultLandingPage.prefsKey), 'tasks');
  });

  test('新选项「概览」可以保存并读回', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await DefaultLandingPage.save('overview');
    expect(DefaultLandingPage.route, '/overview');
    DefaultLandingPage.resetForTest();
    await DefaultLandingPage.load();
    expect(DefaultLandingPage.route, '/overview');
    expect(DefaultLandingPage.label, '概览');
  });

  test('旧值 dashboard 不能再被保存（不是可选项了）', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await DefaultLandingPage.save('dashboard');
    expect(DefaultLandingPage.route, '/tasks');
  });
}
