import 'package:daidai_app/features/logs/views/log_list_page.dart';
import 'package:daidai_app/features/tasks/providers/task_provider.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_http_adapter.dart';

/// 列表错误态的回归保护（PRD R3 / F3b）。
///
/// 两件事必须同时成立，缺一个用户就会看到「暂无数据」而不是「拿不到数据」：
/// 1. 请求失败时 `error` 被赋值，UI 才能把「空」和「失败」分开；
/// 2. **下一次 load() 开头 error 被清空**，否则失败一次之后错误提示永远消不掉。
///
/// 第 2 点依赖 `copyWith` 里刻意写的 `error: error`（不是 `error ?? this.error`）。
/// 这套语义反直觉、极易被「顺手修正」，所以单独立了用例锁住。
void main() {
  group('copyWith 的 error 语义（不传 error 即清空）', () {
    test('TaskListState', () {
      const state = TaskListState(error: '加载任务失败');
      expect(
        state.copyWith(loading: true).error,
        isNull,
        reason: '改成 error ?? this.error 会让这条变红——那正是它存在的意义',
      );
      expect(state.copyWith(error: '新错误').error, '新错误');
    });

    test('LogListState', () {
      const state = LogListState(error: '加载日志失败');
      expect(state.copyWith(loading: true).error, isNull);
      expect(state.copyWith(error: '新错误').error, '新错误');
    });
  });

  group('TaskNotifier', () {
    test('请求失败：error 被赋值，列表保持空 —— UI 据此区分「空」和「失败」', () async {
      final adapter = FakeHttpAdapter(
        (_) => jsonResponse({'error': '面板数据库连接失败'}, status: 500),
      );
      final notifier = TaskNotifier(dio: dioWithAdapter(adapter));

      await notifier.load();

      expect(notifier.state.loading, isFalse);
      expect(notifier.state.tasks, isEmpty);
      expect(notifier.state.error, '面板数据库连接失败');
    });

    test('断网时给的是中文说明，不是 dio 的英文 message', () async {
      final adapter = FakeHttpAdapter(
        (options) => throw DioException.connectionError(
          requestOptions: options,
          reason: 'Failed host lookup',
        ),
      );
      final notifier = TaskNotifier(dio: dioWithAdapter(adapter));

      await notifier.load();

      expect(notifier.state.error, '无法连接到面板，请检查网络或面板是否在线');
    });

    test('下一次 load() 开头把 error 清空', () async {
      var shouldFail = true;
      final adapter = FakeHttpAdapter((_) {
        if (shouldFail) {
          return jsonResponse({'error': '面板数据库连接失败'}, status: 500);
        }
        return jsonResponse({
          'data': [
            {'id': 1, 'name': '任务一'},
          ],
          'total': 1,
        });
      });
      final notifier = TaskNotifier(dio: dioWithAdapter(adapter));

      await notifier.load();
      expect(notifier.state.error, isNotNull);

      shouldFail = false;
      await notifier.load();

      expect(
        notifier.state.error,
        isNull,
        reason: '成功之后还挂着上次的错误提示，页面会一直显示「加载失败」',
      );
      expect(notifier.state.tasks, hasLength(1));
    });
  });

  group('LogListNotifier', () {
    test('请求失败：error 被赋值，列表保持空', () async {
      final adapter = FakeHttpAdapter(
        (_) => jsonResponse({'error': '日志目录不可读'}, status: 500),
      );
      final notifier = LogListNotifier(dio: dioWithAdapter(adapter));

      await notifier.load(refresh: true);

      expect(notifier.state.loading, isFalse);
      expect(notifier.state.logs, isEmpty);
      expect(notifier.state.error, '日志目录不可读');
    });

    test('下一次 load() 开头把 error 清空', () async {
      var shouldFail = true;
      final adapter = FakeHttpAdapter((_) {
        if (shouldFail) {
          return jsonResponse({'error': '日志目录不可读'}, status: 500);
        }
        return jsonResponse({
          'data': [
            {'id': 7, 'task_id': 1, 'content': 'hello'},
          ],
          'total': 1,
        });
      });
      final notifier = LogListNotifier(dio: dioWithAdapter(adapter));

      await notifier.load(refresh: true);
      expect(notifier.state.error, isNotNull);

      shouldFail = false;
      await notifier.load(refresh: true);

      expect(notifier.state.error, isNull);
      expect(notifier.state.logs, hasLength(1));
    });
  });
}
