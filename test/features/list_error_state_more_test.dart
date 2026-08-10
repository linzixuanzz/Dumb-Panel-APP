import 'package:daidai_app/features/deps/views/dep_list_page.dart';
import 'package:daidai_app/features/notifications/views/notification_list_page.dart';
import 'package:daidai_app/features/scripts/views/script_list_page.dart';
import 'package:daidai_app/features/subscriptions/views/subscription_list_page.dart';
import 'package:daidai_app/features/users/views/user_list_page.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_http_adapter.dart';

/// 列表错误态的回归保护（PRD R3 / F3b）—— 第二批。
///
/// `list_error_state_test.dart` 已经锁住 TaskNotifier / LogListNotifier，
/// 这里补上剩下 5 个列表 provider。三条不变量对每个 provider 都成立：
/// 1. 后端报错时 `error` 是**后端原文**，列表保持空 —— UI 才能把「空」和「失败」分开；
/// 2. 断网时 `error` 是中文说明，不是 dio 那句 "The connection errored: ..."；
/// 3. **下一次 load 成功后 error 被清空**，否则失败一次之后错误提示永远消不掉。
///
/// 第 3 点依赖各 State 的 `copyWith` 把 error 写成裸的 `error: error`
/// （不是 `error ?? this.error`）。这个语义反直觉、极易被「顺手修正」，
/// 所以每个 State 另立一条纯 copyWith 用例钉死。
void main() {
  group('copyWith 的 error 语义（不传 error 即清空）', () {
    // 每条都同时断言「一个兄弟字段照常保留」：
    // 只有 error 是清空语义，别的字段仍然是 `x ?? this.x`。

    test('NotificationListState', () {
      const state = NotificationListState(loading: true, error: '加载通知渠道失败');
      expect(
        state.copyWith(items: const []).error,
        isNull,
        reason: '改成 error ?? this.error 会让这条变红——那正是它存在的意义',
      );
      expect(state.copyWith(items: const []).loading, isTrue);
      expect(state.copyWith(error: '新错误').error, '新错误');
    });

    test('UserListState', () {
      const state = UserListState(loading: true, error: '加载用户失败');
      expect(state.copyWith(items: const []).error, isNull);
      expect(state.copyWith(items: const []).loading, isTrue);
      expect(state.copyWith(error: '新错误').error, '新错误');
    });

    test('DepListState', () {
      const state = DepListState(selectedType: 'python', error: '加载依赖失败');
      expect(state.copyWith(loading: true).error, isNull);
      expect(state.copyWith(loading: true).selectedType, 'python');
      expect(state.copyWith(error: '新错误').error, '新错误');
    });

    test('SubscriptionListState', () {
      const state = SubscriptionListState(keyword: 'jd', error: '加载订阅失败');
      expect(state.copyWith(loading: true).error, isNull);
      expect(state.copyWith(loading: true).keyword, 'jd');
      expect(state.copyWith(error: '新错误').error, '新错误');
    });

    test('ScriptState：error 是裸的，selectedPath 才走 _stateUnset 哨兵', () {
      const state = ScriptState(selectedPath: 'a/b.js', error: '加载脚本失败');

      // error：不传即清空。
      expect(state.copyWith(loading: true).error, isNull);
      expect(state.copyWith(error: '新错误').error, '新错误');

      // selectedPath：不传是「保持原值」，显式传 null 才是清空。
      // 两者语义相反，别把 error 也顺手改成哨兵写法。
      expect(state.copyWith(loading: true).selectedPath, 'a/b.js');
      expect(state.copyWith(selectedPath: null).selectedPath, isNull);
    });
  });

  group('NotificationListNotifier', () {
    // 渠道类型表（/notifications/types）是辅助数据，load() 里单独降级、
    // 不参与主流程成败，所以每个假适配器都得把它和渠道列表分开应答。
    bool isTypesRequest(RequestOptions options) =>
        options.path.endsWith('/notifications/types');

    test('请求失败：error 被赋值，列表保持空 —— UI 据此区分「空」和「失败」', () async {
      final adapter = FakeHttpAdapter((options) {
        if (isTypesRequest(options)) return jsonResponse({'data': []});
        return jsonResponse({'error': '通知渠道表损坏'}, status: 500);
      });
      final notifier = NotificationListNotifier(dio: dioWithAdapter(adapter));

      await notifier.load();

      expect(notifier.state.loading, isFalse);
      expect(notifier.state.items, isEmpty);
      expect(notifier.state.error, '通知渠道表损坏');
    });

    test('断网时给的是中文说明，不是 dio 的英文 message', () async {
      final adapter = FakeHttpAdapter(
        (options) => throw DioException.connectionError(
          requestOptions: options,
          reason: 'Failed host lookup',
        ),
      );
      final notifier = NotificationListNotifier(dio: dioWithAdapter(adapter));

      await notifier.load();

      expect(notifier.state.error, '无法连接到面板，请检查网络或面板是否在线');
    });

    test('下一次 load() 成功后把 error 清空', () async {
      var shouldFail = true;
      final adapter = FakeHttpAdapter((options) {
        if (isTypesRequest(options)) return jsonResponse({'data': []});
        if (shouldFail) {
          return jsonResponse({'error': '通知渠道表损坏'}, status: 500);
        }
        return jsonResponse({
          'data': [
            {'id': 1, 'name': 'Bark', 'type': 'bark'},
          ],
          'total': 1,
        });
      });
      final notifier = NotificationListNotifier(dio: dioWithAdapter(adapter));

      await notifier.load();
      expect(notifier.state.error, isNotNull);

      shouldFail = false;
      await notifier.load();

      expect(
        notifier.state.error,
        isNull,
        reason: '成功之后还挂着上次的错误提示，页面会一直显示「加载失败」',
      );
      expect(notifier.state.items, hasLength(1));
    });
  });

  group('UserListNotifier', () {
    test('请求失败：error 被赋值，列表保持空', () async {
      final adapter = FakeHttpAdapter(
        (_) => jsonResponse({'error': '当前账号不是管理员'}, status: 500),
      );
      final notifier = UserListNotifier(dio: dioWithAdapter(adapter));

      await notifier.load();

      expect(notifier.state.loading, isFalse);
      expect(notifier.state.items, isEmpty);
      expect(notifier.state.error, '当前账号不是管理员');
    });

    test('断网时给的是中文说明，不是 dio 的英文 message', () async {
      final adapter = FakeHttpAdapter(
        (options) => throw DioException.connectionError(
          requestOptions: options,
          reason: 'Failed host lookup',
        ),
      );
      final notifier = UserListNotifier(dio: dioWithAdapter(adapter));

      await notifier.load();

      expect(notifier.state.error, '无法连接到面板，请检查网络或面板是否在线');
    });

    test('下一次 load() 成功后把 error 清空', () async {
      var shouldFail = true;
      final adapter = FakeHttpAdapter((_) {
        if (shouldFail) {
          return jsonResponse({'error': '当前账号不是管理员'}, status: 500);
        }
        return jsonResponse({
          'data': [
            {'id': 1, 'username': 'admin', 'role': 'admin'},
          ],
        });
      });
      final notifier = UserListNotifier(dio: dioWithAdapter(adapter));

      await notifier.load();
      expect(notifier.state.error, isNotNull);

      shouldFail = false;
      await notifier.load();

      expect(notifier.state.error, isNull);
      expect(notifier.state.items, hasLength(1));
    });
  });

  group('DepListNotifier', () {
    test('请求失败：error 被赋值，列表保持空', () async {
      final adapter = FakeHttpAdapter(
        (_) => jsonResponse({'error': 'pip 未安装'}, status: 500),
      );
      final notifier = DepListNotifier(dio: dioWithAdapter(adapter));

      await notifier.load(type: 'python', pythonVersion: '3.12');

      expect(notifier.state.loading, isFalse);
      expect(notifier.state.items, isEmpty);
      expect(notifier.state.error, 'pip 未安装');
      // 失败不该把用户选中的筛选条件也一起丢掉。
      expect(notifier.state.selectedType, 'python');
      expect(notifier.state.selectedPythonVersion, '3.12');
    });

    test('断网时给的是中文说明，不是 dio 的英文 message', () async {
      final adapter = FakeHttpAdapter(
        (options) => throw DioException.connectionError(
          requestOptions: options,
          reason: 'Failed host lookup',
        ),
      );
      final notifier = DepListNotifier(dio: dioWithAdapter(adapter));

      await notifier.load();

      expect(notifier.state.error, '无法连接到面板，请检查网络或面板是否在线');
    });

    test('下一次 load() 成功后把 error 清空', () async {
      var shouldFail = true;
      final adapter = FakeHttpAdapter((_) {
        if (shouldFail) {
          return jsonResponse({'error': 'pip 未安装'}, status: 500);
        }
        return jsonResponse({
          'data': [
            {'id': 1, 'name': 'axios', 'type': 'nodejs'},
          ],
          'total': 1,
        });
      });
      final notifier = DepListNotifier(dio: dioWithAdapter(adapter));

      await notifier.load(type: 'nodejs');
      expect(notifier.state.error, isNotNull);

      shouldFail = false;
      await notifier.load(type: 'nodejs');

      expect(notifier.state.error, isNull);
      expect(notifier.state.items, hasLength(1));
    });
  });

  group('ScriptNotifier', () {
    test('请求失败：error 被赋值，脚本树保持空', () async {
      final adapter = FakeHttpAdapter(
        (_) => jsonResponse({'error': '脚本目录不可读'}, status: 500),
      );
      final notifier = ScriptNotifier(dio: dioWithAdapter(adapter));

      await notifier.loadTree();

      expect(notifier.state.loading, isFalse);
      expect(notifier.state.tree, isEmpty);
      expect(notifier.state.error, '脚本目录不可读');
    });

    test('断网时给的是中文说明，不是 dio 的英文 message', () async {
      final adapter = FakeHttpAdapter(
        (options) => throw DioException.connectionError(
          requestOptions: options,
          reason: 'Failed host lookup',
        ),
      );
      final notifier = ScriptNotifier(dio: dioWithAdapter(adapter));

      await notifier.loadTree();

      expect(notifier.state.error, '无法连接到面板，请检查网络或面板是否在线');
    });

    test('下一次 loadTree() 成功后把 error 清空', () async {
      var shouldFail = true;
      final adapter = FakeHttpAdapter((_) {
        if (shouldFail) {
          return jsonResponse({'error': '脚本目录不可读'}, status: 500);
        }
        return jsonResponse({
          'data': [
            {'title': 'jd_sign.js', 'key': 'jd_sign.js'},
          ],
        });
      });
      final notifier = ScriptNotifier(dio: dioWithAdapter(adapter));

      await notifier.loadTree();
      expect(notifier.state.error, isNotNull);

      shouldFail = false;
      await notifier.loadTree();

      expect(notifier.state.error, isNull);
      expect(notifier.state.tree, hasLength(1));
    });
  });

  group('SubscriptionListNotifier', () {
    test('请求失败：error 被赋值，列表保持空', () async {
      final adapter = FakeHttpAdapter(
        (_) => jsonResponse({'error': 'git 未安装'}, status: 500),
      );
      final notifier = SubscriptionListNotifier(dio: dioWithAdapter(adapter));

      await notifier.load();

      expect(notifier.state.loading, isFalse);
      expect(notifier.state.items, isEmpty);
      expect(notifier.state.error, 'git 未安装');
    });

    test('断网时给的是中文说明，不是 dio 的英文 message', () async {
      final adapter = FakeHttpAdapter(
        (options) => throw DioException.connectionError(
          requestOptions: options,
          reason: 'Failed host lookup',
        ),
      );
      final notifier = SubscriptionListNotifier(dio: dioWithAdapter(adapter));

      await notifier.load();

      expect(notifier.state.error, '无法连接到面板，请检查网络或面板是否在线');
    });

    test('下一次 load() 成功后把 error 清空', () async {
      var shouldFail = true;
      final adapter = FakeHttpAdapter((_) {
        if (shouldFail) {
          return jsonResponse({'error': 'git 未安装'}, status: 500);
        }
        return jsonResponse({
          'data': [
            {'id': 1, 'name': 'my-repo'},
          ],
          'total': 1,
        });
      });
      final notifier = SubscriptionListNotifier(dio: dioWithAdapter(adapter));

      await notifier.load();
      expect(notifier.state.error, isNotNull);

      shouldFail = false;
      await notifier.load();

      expect(notifier.state.error, isNull);
      expect(notifier.state.items, hasLength(1));
    });
  });
}
