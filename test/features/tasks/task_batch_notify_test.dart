import 'package:daidai_app/features/tasks/providers/task_provider.dart';
import 'package:daidai_app/shared/utils/api_utils.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_http_adapter.dart';

/// 批量设置通知（面板 v3.3.3 / issue #149 的 `PUT /tasks/batch/notify`）。
///
/// 两件事要钉住：
/// 1. 请求体只带传了的开关 —— 面板是指针字段，多带一个 false 就会把用户没想动的开关关掉；
/// 2. 老面板没有这条路由时的两种 404 形态都翻译成「请升级」，而面板业务上的 404 原样透出。
void main() {
  const upgradeMessage = '当前面板版本不支持，请升级到 v3.3.3 或更高';

  /// `PUT /tasks/batch/notify` 回 [notifyResponse]；其余请求（写完后刷新列表的 GET）回空列表。
  /// [bodies] 按顺序记下每次 PUT 的请求体。
  FakeHttpAdapter buildAdapter(
    ResponseBody Function() notifyResponse,
    List<Object?> bodies,
  ) {
    return FakeHttpAdapter((options) {
      if (options.method == 'PUT' && options.path == '/api/tasks/batch/notify') {
        bodies.add(options.data);
        return notifyResponse();
      }
      return jsonResponse({'data': <Object>[], 'total': 0});
    });
  }

  Future<Object> captureError(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      return error;
    }
    fail('应当抛出异常');
  }

  group('请求体', () {
    test('只带传了的开关：成功时通知没传就不出现在 body 里', () async {
      final bodies = <Object?>[];
      final adapter = buildAdapter(
        () => jsonResponse({'message': '已更新 2 个任务的通知设置', 'success_count': 2}),
        bodies,
      );
      final notifier = TaskNotifier(dio: dioWithAdapter(adapter));

      await notifier.batchSetNotify([3, 7], onFailure: true);

      expect(bodies, hasLength(1));
      expect(bodies.single, {
        'task_ids': [3, 7],
        'notify_on_failure': true,
      });
      expect(
        (bodies.single as Map).containsKey('all'),
        isFalse,
        reason: 'APP 的全选就是当前筛选下的全部任务，不能带 all 把筛选外的任务也改了',
      );
      // 写完要刷新列表，与其它批量操作一致。
      expect(adapter.countOf('/api/tasks'), 1);
    });

    test('false 也要写进 body：「关闭」是一次有效的修改', () async {
      final bodies = <Object?>[];
      final adapter = buildAdapter(
        () => jsonResponse({'message': '已更新 1 个任务的通知设置', 'success_count': 1}),
        bodies,
      );
      final notifier = TaskNotifier(dio: dioWithAdapter(adapter));

      await notifier.batchSetNotify([5], onFailure: false, onSuccess: true);

      expect(bodies.single, {
        'task_ids': [5],
        'notify_on_failure': false,
        'notify_on_success': true,
      });
    });
  });

  group('连老面板（没有这条路由）', () {
    test('Docker 部署：gin 默认的纯文本 404 → 提示升级', () async {
      final adapter = buildAdapter(
        () => ResponseBody.fromString(
          '404 page not found',
          404,
          headers: {
            Headers.contentTypeHeader: ['text/plain; charset=utf-8'],
          },
        ),
        <Object?>[],
      );
      final notifier = TaskNotifier(dio: dioWithAdapter(adapter));

      final error = await captureError(
        () => notifier.batchSetNotify([1], onFailure: true),
      );

      expect(error, isA<PanelUpgradeRequiredException>());
      // 页面走的是 extractErrorMessage，这里按同一条路径断言用户最终看到的文案。
      expect(extractErrorMessage(error, '批量设置通知失败'), upgradeMessage);
    });

    test('二进制部署：面板 NoRoute 的 {"error":"route not found"} → 提示升级，不露英文', () async {
      final adapter = buildAdapter(
        () => jsonResponse({'error': 'route not found'}, status: 404),
        <Object?>[],
      );
      final notifier = TaskNotifier(dio: dioWithAdapter(adapter));

      final error = await captureError(
        () => notifier.batchSetNotify([1], onFailure: true),
      );

      expect(error, isA<PanelUpgradeRequiredException>());
      expect(extractErrorMessage(error, '批量设置通知失败'), upgradeMessage);
    });

    test('新面板业务上的 404（选中的任务都不存在了）原样透出，不能误判成老面板', () async {
      final adapter = buildAdapter(
        () => jsonResponse({'error': '没有找到要修改的任务'}, status: 404),
        <Object?>[],
      );
      final notifier = TaskNotifier(dio: dioWithAdapter(adapter));

      final error = await captureError(
        () => notifier.batchSetNotify([999], onFailure: true),
      );

      expect(error, isA<DioException>());
      expect(extractErrorMessage(error, '批量设置通知失败'), '没有找到要修改的任务');
    });
  });
}
