import 'package:daidai_app/shared/models/task.dart';
import 'package:flutter_test/flutter_test.dart';

/// 任务编辑页标签往返的回归锁（issue #4 顺带修的数据丢失 bug）。
///
/// 背景：面板的任务更新是**整体覆写** labels。编辑页原本用
/// `userLabelsForDisplay` 播种标签编辑框，而那份数据来自服务端的
/// `display_labels` —— 里面 `subscription:3` 已经被换成了订阅显示名
/// 「华星电信」。于是保存一次任务就会把 `subscription:3` 覆写掉：
/// 任务脱离订阅托管、订阅锁失效、下次拉取还会重建一条同名重复任务。
///
/// 这组用例守的就是「提交体里 `subscription:3` 必须还在」。
void main() {
  group('原始标签的拆分', () {
    test('分组与订阅两类内部标签都不出现在可编辑的用户标签里', () {
      final task = _task(
        labels: ['日常', '分组:娱乐', 'subscription:3'],
        displayLabels: ['娱乐', '日常', '华星电信'],
      );
      expect(Task.splitUserLabels(task.labelList), ['日常']);
      expect(Task.splitInternalLabels(task.labelList), ['subscription:3']);
    });

    test('判前缀先 trim：历史脏数据里存在带前导空格的内部标签', () {
      expect(Task.isSubscriptionLabel(' subscription:1'), isTrue);
      expect(Task.splitInternalLabels([' subscription:1']), ['subscription:1']);
      expect(Task.splitUserLabels([' subscription:1']), isEmpty);
    });

    test('空标签被丢掉，不会拼出一串多余的逗号', () {
      expect(Task.splitUserLabels(['', '  ', '签到']), ['签到']);
    });
  });

  group('提交体拼装', () {
    test('内部标签必须原样保留 —— 这条断言就是数据丢失的回归锁', () {
      final task = _task(
        labels: ['分组:娱乐', 'subscription:3'],
        displayLabels: ['娱乐', '华星电信'],
      );

      final submitted = Task.mergeTaskLabels(
        userLabels: Task.splitUserLabels(task.labelList),
        internalLabels: Task.splitInternalLabels(task.labelList),
        groupName: task.groupName ?? '',
      );

      expect(submitted, contains('subscription:3'));
      expect(submitted, contains('分组:娱乐'));
    });

    test('改坏之前的写法确实会丢掉 subscription —— 说明这个 bug 真的存在过', () {
      final task = _task(
        labels: ['分组:娱乐', 'subscription:3'],
        displayLabels: ['娱乐', '华星电信'],
      );

      // 旧代码：用 display 版标签播种，再整体覆写。
      final legacySubmitted = <String>[
        ...task.userLabelsForDisplay.where((label) => !Task.isGroupLabel(label)),
        Task.toGroupLabel('娱乐'),
      ];

      expect(task.userLabelsForDisplay, ['华星电信']);
      expect(legacySubmitted, isNot(contains('subscription:3')));
    });

    test('用户标签里混进来的分组 / 订阅前缀会被剔掉，避免拼出两个分组标签', () {
      final submitted = Task.mergeTaskLabels(
        userLabels: ['签到', '分组:手动加的', 'subscription:9'],
        internalLabels: ['subscription:3'],
        groupName: '娱乐',
      );
      expect(submitted, ['签到', 'subscription:3', '分组:娱乐']);
    });

    test('分组名为空时不追加分组标签', () {
      final submitted = Task.mergeTaskLabels(
        userLabels: ['签到'],
        internalLabels: const [],
        groupName: '   ',
      );
      expect(submitted, ['签到']);
    });

    test('新建任务（没有任何原始标签）时提交体就是用户输入的那几个', () {
      final submitted = Task.mergeTaskLabels(
        userLabels: ['测试'],
        internalLabels: const [],
        groupName: '日常',
      );
      expect(submitted, ['测试', '分组:日常']);
    });
  });

  group('分组标签归一', () {
    test('裸分组名补上前缀，已经带前缀的原样返回', () {
      expect(Task.normalizeGroupLabel('生产'), '分组:生产');
      expect(Task.normalizeGroupLabel('分组:生产'), '分组:生产');
      expect(Task.normalizeGroupLabel(' 生产 '), '分组:生产');
    });

    test('空值归一成空串，调用方据此判断「不筛选」', () {
      expect(Task.normalizeGroupLabel(''), '');
      expect(Task.normalizeGroupLabel('   '), '');
    });

    test('取回显示名：带前缀的去前缀，裸名原样返回', () {
      expect(Task.groupNameFromLabel('分组:生产'), '生产');
      expect(Task.groupNameFromLabel('生产'), '生产');
      expect(Task.groupNameFromLabel('分组: 生产 '), '生产');
    });

    test('归一后的值才是发给服务端做 LIKE 的那个 —— 传裸名会把同名普通标签一起捞回来', () {
      // 只挂了普通标签「生产」、根本没有分组的任务。
      final plain = _task(labels: ['生产']);
      expect(plain.groupName, isNull);
      // 服务端做的是 labels LIKE '%<值>%'：裸名会命中它，带前缀不会。
      expect(plain.labels.contains('生产'), isTrue);
      expect(plain.labels.contains(Task.normalizeGroupLabel('生产')), isFalse);
    });
  });
}

Task _task({
  required List<String> labels,
  List<String> displayLabels = const [],
}) {
  return Task.fromJson({
    'id': 1,
    'name': '示例任务',
    'command': 'task demo.js',
    'cron_expression': '0 0 * * *',
    'status': 1,
    'labels': labels,
    'display_labels': displayLabels,
  });
}
