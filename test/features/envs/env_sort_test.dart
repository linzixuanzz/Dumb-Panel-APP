import 'dart:async';

import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/theme/app_theme.dart';
import 'package:daidai_app/features/envs/views/env_list_page.dart';
import 'package:daidai_app/shared/utils/api_utils.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_http_adapter.dart';

/// 一张基准表。[full] 是面板里的整表顺序，[visible] 是筛选后看得见的那几条（null = 没筛选）。
class _Table {
  const _Table(this.name, this.full, {this.pinned = const {}, this.visible});

  final String name;
  final List<String> full;
  final Set<String> pinned;
  final List<String>? visible;

  List<String> get shown => visible ?? full;
  bool get filtered => visible != null;
}

const _jia = _Table('甲', ['A', 'B', 'C', 'D', 'E']);
const _yi = _Table('乙', ['P1', 'P2', 'A', 'B', 'C'], pinned: {'P1', 'P2'});
const _bing = _Table(
  '丙',
  ['A', 'B', 'C', 'D', 'E', 'F'],
  visible: ['B', 'D', 'F'],
);
const _ding = _Table(
  '丁',
  ['P1', 'P2', 'P3', 'A', 'B', 'C', 'D'],
  pinned: {'P1', 'P2', 'P3'},
  visible: ['P1', 'P3', 'B', 'D'],
);
const _tables = [_jia, _yi, _bing, _ding];

/// 照抄面板 `reorderEnvWithinSortBucket`（server/handler/env.go）的假服务端。
///
/// 维护整表顺序；PUT 时同桶兄弟去掉 source，target 为空插到桶尾（此时不看 position），
/// 否则插到 target 处（认 after 时再往后一格），跨桶 400。
/// GET 只回看得见的行：筛选条件由表本身决定，不看请求参数。
class _FakePanel {
  _FakePanel(this.table, {this.honorsAfter = true})
    : order = List.of(table.full);

  final _Table table;

  /// false = ≤ v3.2.7 的老面板：请求结构里没有 position，after 也按「插到前面」处理。
  final bool honorsAfter;

  /// 面板里的整表顺序。测试可以直接改它，模拟别处（网页端）刚改过顺序。
  List<String> order;

  /// 每个 PUT /envs/sort 的请求体，按到达顺序。
  final bodies = <Map<String, dynamic>>[];

  /// 每个列表 GET 的 query（FakeHttpAdapter 本身不记 query）。失败的那几次也算。
  final getQueries = <Map<String, dynamic>>[];

  /// PUT 到达那一刻回调（记下请求发出时本地的顺序）。
  void Function()? onPut;

  /// 设了就让 PUT 卡在这里，模拟慢网。
  Completer<void>? putGate;

  /// 设了就用它应答 PUT、不落库（面板拒绝）。
  ResponseBody Function()? putReply;

  /// 设了就用它应答列表 GET（HTTP 错误）。
  ResponseBody Function()? getReply;

  /// true = 列表 GET 在网络层出错（断网）。
  bool getThrows = false;

  /// 列表响应里的 total；null = 按可见条数报。用来模拟 all=1 被 5000 条上限截断。
  int? reportedTotal;

  /// true = 列表响应里干脆不带 total。
  bool omitTotal = false;

  int get getCount => getQueries.length;

  bool _pinned(String name) => table.pinned.contains(name);
  String _nameOf(int id) => table.full[id - 1];

  List<String> get visibleOrder {
    final shown = table.shown.toSet();
    return [
      for (final name in order)
        if (shown.contains(name)) name,
    ];
  }

  Map<String, dynamic> _row(String name) {
    final id = table.full.indexOf(name) + 1;
    return {
      'id': id,
      'name': name,
      'value': 'v$id',
      'remarks': '',
      'group': '',
      'enabled': true,
      'sort_order': _pinned(name) ? 1 : 0,
      'position': 1000.0 * id,
    };
  }

  Future<ResponseBody> handle(RequestOptions options) async {
    if (options.path == ApiEndpoints.envsGroups) {
      return jsonResponse({'data': <String>[]});
    }
    if (options.method == 'PUT' && options.path == ApiEndpoints.envsSort) {
      final body = Map<String, dynamic>.from(options.data as Map);
      bodies.add(body);
      onPut?.call();
      final gate = putGate;
      if (gate != null) {
        await gate.future;
      }
      final reply = putReply;
      if (reply != null) {
        return reply();
      }
      final source = _nameOf(body['source_id'] as int);
      final rawTarget = body['target_id'];
      final target = rawTarget is int ? _nameOf(rawTarget) : null;
      if (target != null && _pinned(target) != _pinned(source)) {
        return jsonResponse({'error': '置顶项和普通项请分别排序'}, status: 400);
      }
      final bucket = [
        for (final name in order)
          if (name != source && _pinned(name) == _pinned(source)) name,
      ];
      var index = bucket.length;
      if (target != null) {
        index = bucket.indexOf(target);
        if (honorsAfter && body['position'] == 'after') {
          index++;
        }
      }
      bucket.insert(index, source);
      final others = [
        for (final name in order)
          if (_pinned(name) != _pinned(source)) name,
      ];
      order = _pinned(source) ? [...bucket, ...others] : [...others, ...bucket];
      return jsonResponse({'message': '排序更新成功'});
    }
    if (options.method == 'GET' && options.path == ApiEndpoints.envs) {
      getQueries.add(Map<String, dynamic>.from(options.queryParameters));
      final reply = getReply;
      if (reply != null) {
        return reply();
      }
      if (getThrows) {
        // FakeHttpAdapter 的约定：responder 抛异常 = 网络层出错。
        throw StateError('网络断开');
      }
      final rows = [for (final name in visibleOrder) _row(name)];
      return jsonResponse({
        'data': rows,
        if (!omitTotal) 'total': reportedTotal ?? rows.length,
      });
    }
    return jsonResponse({
      'error': 'unexpected ${options.method} ${options.path}',
    }, status: 500);
  }
}

/// 面板列表项（给不走 [_FakePanel] 的用例用）。
Map<String, dynamic> _envRow(int id, String name) => {
  'id': id,
  'name': name,
  'value': 'v$id',
  'remarks': '',
  'group': '',
  'enabled': true,
  'sort_order': 0,
  'position': 1000.0 * id,
};

List<String> _names(EnvListNotifier notifier) =>
    notifier.state.envs.map((env) => env.name).toList();

/// 用户松手那一刻看到的顺序（纯列表操作，不依赖服务端）。
List<String> _localMove(List<String> items, int oldIndex, int newIndex) {
  final to = newIndex > oldIndex ? newIndex - 1 : newIndex;
  final copy = List.of(items);
  final source = copy.removeAt(oldIndex);
  copy.insert(to, source);
  return copy;
}

/// 独立判据（不看实现怎么算锚点）：挪完以后「置顶全在前、普通全在后」还成立，
/// 就是桶内拖动；否则是跨区。
bool _staysInBucket(_Table table, List<String> moved) {
  var seenNormal = false;
  for (final name in moved) {
    final isPinned = table.pinned.contains(name);
    if (!isPinned) {
      seenNormal = true;
    } else if (seenNormal) {
      return false;
    }
  }
  return true;
}

Future<EnvListNotifier> _loaded(_FakePanel panel) async {
  final notifier = EnvListNotifier(
    dio: dioWithAdapter(FakeHttpAdapter(panel.handle)),
  );
  if (panel.table.filtered) {
    // 筛选状态：搜索词非空。假服务端不看参数，只回 visible 那几条。
    notifier.setKeyword('x');
  }
  await notifier.load();
  return notifier;
}

Future<Object> _captureError(Future<void> Function() action) async {
  try {
    await action();
  } catch (error) {
    return error;
  }
  fail('应当抛出异常');
}

Matcher _envWriteException(String message) => throwsA(
  isA<EnvWriteException>().having((e) => e.message, 'message', message),
);

/// APP #16 ①「变量排序不生效」的回归保护。
///
/// 改前三个根因叠在一起：锚点取「落点上一行」却不带 position（面板按「插到前面」处理，
/// 下移 1 格原地不动）、拖到第一位发空 target（面板当成「移到本桶末尾」）、只在点「完成」时
/// 发最后一次拖动 —— 20 种拖法 0 种对。这里钉住：
/// 1. 每次松手恰好 1 个 `PUT /envs/sort` + 1 次重拉，请求体永远带 position；
/// 2. 照抄面板 `reorderEnvWithinSortBucket` 的假服务端穷举回放：桶内结果 = 松手时看到的顺序；
///    老面板（不认 after）只有「筛选状态 + 拖到可见末尾」差 1 格，没筛选时从不依赖 after；
/// 3. G1~G7：筛选条件取列表快照、请求串行、all=1 一次拉全、失败回滚、拖拽中重拉核对 id、
///    跨区本地拦下并给出路、越界保护。
void main() {
  group('请求形状', () {
    test('下移 1 格：恰好 1 个 PUT {后一条, before}，随后重拉 1 次；请求发出时本地已挪好', () async {
      final panel = _FakePanel(_jia);
      final notifier = await _loaded(panel);
      final orderDuringPut = <List<String>>[];
      panel.onPut = () => orderDuringPut.add(_names(notifier));
      final getsBefore = panel.getCount;

      await notifier.moveEnv(1, 3);

      expect(panel.bodies, [
        {'source_id': 2, 'target_id': 4, 'position': 'before'},
      ]);
      expect(panel.getCount, getsBefore + 1, reason: '松手后恰好重拉一次');
      expect(orderDuringPut.single, ['A', 'C', 'B', 'D', 'E']);
      expect(_names(notifier), ['A', 'C', 'B', 'D', 'E']);
    });

    test('拖到第一位：锚是原来的第一条 + before，不再发空 target', () async {
      final panel = _FakePanel(_jia);
      final notifier = await _loaded(panel);

      await notifier.moveEnv(3, 0);

      expect(panel.bodies.single, {
        'source_id': 4,
        'target_id': 1,
        'position': 'before',
      });
      expect(_names(notifier), ['D', 'A', 'B', 'C', 'E']);
    });

    test('没筛选拖到最后：空 target + after = 本桶末尾（置顶区同理）', () async {
      final jia = _FakePanel(_jia);
      final jiaNotifier = await _loaded(jia);
      await jiaNotifier.moveEnv(1, 5);
      expect(jia.bodies.single, {
        'source_id': 2,
        'target_id': null,
        'position': 'after',
      });
      expect(_names(jiaNotifier), ['A', 'C', 'D', 'E', 'B']);

      final yi = _FakePanel(_yi);
      final yiNotifier = await _loaded(yi);
      await yiNotifier.moveEnv(0, 2);
      expect(yi.bodies.single, {
        'source_id': 1,
        'target_id': null,
        'position': 'after',
      }, reason: '置顶区最后一条之后 = 置顶区末尾');
      expect(_names(yiNotifier), ['P2', 'P1', 'A', 'B', 'C']);
    });

    test('筛选状态拖到可见末尾：{前一条, after}，不能发空 target 越过看不见的行', () async {
      final panel = _FakePanel(_bing);
      final notifier = await _loaded(panel);
      expect(notifier.state.envsUnfiltered, isFalse);

      await notifier.moveEnv(0, 3);

      expect(panel.bodies.single, {
        'source_id': 2,
        'target_id': 6,
        'position': 'after',
      });
      expect(_names(notifier), ['D', 'F', 'B']);
      expect(panel.order, ['A', 'C', 'D', 'E', 'F', 'B']);
    });

    test('原地松手：一个请求都不发', () async {
      final panel = _FakePanel(_jia);
      final notifier = await _loaded(panel);
      final getsBefore = panel.getCount;

      // 往下挪一格再放回原处，ReorderableListView 给的是 (i, i + 1)。
      await notifier.moveEnv(0, 1);
      await notifier.moveEnv(2, 2);

      expect(panel.bodies, isEmpty);
      expect(panel.getCount, getsBefore);
    });
  });

  group('穷举回放', () {
    // (拖法总数, 其中跨区被拦下的数量)
    const expected = <String, (int, int)>{
      '甲': (20, 0),
      '乙': (20, 12),
      '丙': (6, 0),
      '丁': (12, 8),
    };

    for (final table in _tables) {
      test('新面板 · ${table.name}：桶内拖动回放后 == 松手时看到的顺序；跨区在本地拦下', () async {
        var drags = 0;
        var refused = 0;
        for (var oldIndex = 0; oldIndex < table.shown.length; oldIndex++) {
          for (var newIndex = 0; newIndex <= table.shown.length; newIndex++) {
            final to = newIndex > oldIndex ? newIndex - 1 : newIndex;
            if (to == oldIndex) continue;
            drags++;
            final panel = _FakePanel(table);
            final notifier = await _loaded(panel);
            final before = _names(notifier);
            final moved = _localMove(before, oldIndex, newIndex);
            final getsBefore = panel.getCount;

            Object? error;
            try {
              await notifier.moveEnv(oldIndex, newIndex);
            } catch (e) {
              error = e;
            }

            final label = '${table.name} ($oldIndex → $newIndex)';
            if (_staysInBucket(table, moved)) {
              expect(error, isNull, reason: '$label 桶内拖动不该报错');
              expect(panel.bodies, hasLength(1), reason: '$label 一次松手一个 PUT');
              expect(panel.getCount, getsBefore + 1, reason: '$label 随后重拉一次');
              expect(panel.visibleOrder, moved, reason: '$label 面板落库后的可见顺序');
              expect(_names(notifier), moved, reason: '$label 重拉后的列表');
            } else {
              refused++;
              expect(
                error,
                isA<EnvWriteException>(),
                reason: '$label 跨区要在本地拦下',
              );
              expect(panel.bodies, isEmpty, reason: '$label 跨区不发请求');
              expect(panel.getCount, getsBefore, reason: '$label 拦下时也不重拉');
              expect(_names(notifier), before, reason: '$label 列表原样');
            }
          }
        }
        expect((drags, refused), expected[table.name]);
      });
    }

    for (final table in _tables) {
      test('老面板（不认 after）· ${table.name}：落错位当且仅当请求是 {非空 target, after}', () async {
        var afterWithTarget = 0;
        for (var oldIndex = 0; oldIndex < table.shown.length; oldIndex++) {
          for (var newIndex = 0; newIndex <= table.shown.length; newIndex++) {
            final to = newIndex > oldIndex ? newIndex - 1 : newIndex;
            if (to == oldIndex) continue;
            final moved = _localMove(table.shown, oldIndex, newIndex);
            // 跨区上面已经测过（本地拦下，不发请求），这里只看桶内拖动。
            if (!_staysInBucket(table, moved)) continue;

            final panel = _FakePanel(table, honorsAfter: false);
            final notifier = await _loaded(panel);
            await notifier.moveEnv(oldIndex, newIndex);

            final body = panel.bodies.single;
            final usesAfter =
                body['position'] == 'after' && body['target_id'] != null;
            if (usesAfter) {
              afterWithTarget++;
            }
            final landed = panel.visibleOrder.join(',') == moved.join(',');
            expect(
              landed,
              !usesAfter,
              reason: '${table.name} ($oldIndex → $newIndex) 请求 $body',
            );
          }
        }
        // 没筛选时拖到最后发的是空 target（所有版本都认），从不依赖 after；
        // 筛选状态下「拖到可见末尾」才会用到 after，丙、丁各 2 种。
        expect(afterWithTarget, table.filtered ? 2 : 0);
      });
    }
  });

  group('连拖', () {
    final sequences = <(_Table, List<(int, int)>)>[
      (_jia, [(0, 3), (4, 1), (2, 5)]),
      (_yi, [(0, 2), (4, 2), (3, 5)]),
      (_bing, [(2, 1), (0, 3)]),
      (_ding, [(0, 2), (3, 2), (1, 0)]),
    ];
    for (final (table, drags) in sequences) {
      test('${table.name} 逐次 await 连拖 ${drags.length} 次：每次都保存，最终顺序 == 意图', () async {
        final panel = _FakePanel(table);
        final notifier = await _loaded(panel);
        var intended = _names(notifier);

        for (final (oldIndex, newIndex) in drags) {
          intended = _localMove(intended, oldIndex, newIndex);
          await notifier.moveEnv(oldIndex, newIndex);
          expect(_names(notifier), intended);
        }

        expect(panel.bodies, hasLength(drags.length));
        expect(panel.visibleOrder, intended);
      });
    }
  });

  group('G1：「有没有筛选」取这份列表加载时的条件', () {
    test('清空搜索词后重拉失败：屏幕上仍是筛过的列表，拖到最后仍发 {前一条, after}', () async {
      final panel = _FakePanel(_bing);
      final notifier = await _loaded(panel);
      expect(notifier.state.envsUnfiltered, isFalse);

      panel.getReply = () => jsonResponse({'error': '面板暂时不可用'}, status: 500);
      notifier.setKeyword('');
      // setKeyword 触发的那次与这一次都失败；代次保证只有最后发出的这次写 state。
      await notifier.load();
      panel.getReply = null;

      expect(notifier.state.keyword, isEmpty);
      expect(notifier.state.error, '面板暂时不可用');
      expect(notifier.state.envsUnfiltered, isFalse, reason: '列表还是筛选时加载的那份');
      expect(_names(notifier), ['B', 'D', 'F']);

      await notifier.moveEnv(0, 3);

      expect(panel.bodies.single, {
        'source_id': 2,
        'target_id': 6,
        'position': 'after',
      }, reason: '发空 target 会把 B 甩过看不见的 A、C、E');
    });

    test('被 all=1 的 5000 条上限截断（条数 < total）时也按「有筛选」处理', () async {
      final panel = _FakePanel(const _Table('截断', ['A', 'B', 'C']))
        ..reportedTotal = 5001;
      final notifier = await _loaded(panel);
      expect(notifier.state.envsUnfiltered, isFalse);

      await notifier.moveEnv(0, 3);

      expect(panel.bodies.single, {
        'source_id': 1,
        'target_id': 3,
        'position': 'after',
      }, reason: '后面还有看不见的行，不能发空 target');

      // total 等于条数、或响应里干脆没有 total（extractPaginated 按条数算）：是整表。
      panel.reportedTotal = 3;
      await notifier.load();
      expect(notifier.state.envsUnfiltered, isTrue);
      panel
        ..reportedTotal = null
        ..omitTotal = true;
      await notifier.load();
      expect(notifier.state.envsUnfiltered, isTrue);
    });
  });

  group('G2：请求串行', () {
    test('上一次 PUT + 重拉没结束前拒绝下一次拖动（原地松手不算），放行后再拖才发第 2 个', () async {
      final panel = _FakePanel(_jia);
      final notifier = await _loaded(panel);
      final arrived = Completer<void>();
      panel
        ..putGate = Completer<void>()
        ..onPut = () {
          if (!arrived.isCompleted) arrived.complete();
        };

      final first = notifier.moveEnv(1, 3); // 本地 A C B D E
      await arrived.future;

      await expectLater(
        notifier.moveEnv(0, 2),
        _envWriteException('上一次排序还在保存，请稍候再拖'),
      );
      // 从下方拖回原位时 Flutter 照样回调 onReorder(i, i + 1)：保存途中这种原地松手不该弹「请稍候」。
      await notifier.moveEnv(2, 3);
      expect(panel.bodies, hasLength(1));

      panel.putGate!.complete();
      await first;
      expect(_names(notifier), ['A', 'C', 'B', 'D', 'E']);

      panel.putGate = null;
      await notifier.moveEnv(0, 2); // A 拖到 C 后面 → C A B D E

      expect(panel.bodies, [
        {'source_id': 2, 'target_id': 4, 'position': 'before'},
        {'source_id': 1, 'target_id': 2, 'position': 'before'},
      ]);
      expect(_names(notifier), ['C', 'A', 'B', 'D', 'E']);
    });

    test('先发后到的旧 load 不许盖掉后发的那次（代次）', () async {
      final slowGate = Completer<void>();
      final adapter = FakeHttpAdapter((options) async {
        if (options.path == ApiEndpoints.envsGroups) {
          return jsonResponse({'data': <String>[]});
        }
        if (options.queryParameters['keyword'] == 'a') {
          await slowGate.future;
          return jsonResponse({
            'data': [_envRow(1, 'APPLE'), _envRow(2, 'AB_TOKEN')],
            'total': 2,
          });
        }
        return jsonResponse({
          'data': [_envRow(2, 'AB_TOKEN')],
          'total': 1,
        });
      });
      final notifier = EnvListNotifier(dio: dioWithAdapter(adapter));

      notifier.setKeyword('a'); // 第一次 GET 卡住
      notifier.setKeyword('ab'); // 第二次 GET 立刻回
      await pumpEventQueue();
      expect(_names(notifier), ['AB_TOKEN']);

      slowGate.complete();
      await pumpEventQueue();

      expect(_names(notifier), ['AB_TOKEN'], reason: '旧搜索词的结果晚到，不能盖掉新结果');
      expect(notifier.state.loading, isFalse);
    });
  });

  group('G3：一次拉全', () {
    test('150 条也只发一次 GET（all=1，不带 page / page_size），带上搜索词与分组', () async {
      final queries = <Map<String, dynamic>>[];
      final rows = [for (var id = 1; id <= 150; id++) _envRow(id, 'K$id')];
      final adapter = FakeHttpAdapter((options) {
        if (options.path == ApiEndpoints.envsGroups) {
          return jsonResponse({
            'data': ['g1', 'g2'],
          });
        }
        queries.add(Map<String, dynamic>.from(options.queryParameters));
        return jsonResponse({'data': rows, 'total': rows.length});
      });
      final notifier = EnvListNotifier(dio: dioWithAdapter(adapter));

      await notifier.load();

      expect(adapter.countOf(ApiEndpoints.envs), 1, reason: '不再按 100 条翻页');
      expect(notifier.state.envs, hasLength(150));
      expect(queries.single['all'], 1);
      expect(queries.single.containsKey('page'), isFalse);
      expect(queries.single.containsKey('page_size'), isFalse);
      expect(queries.single.containsKey('keyword'), isFalse);
      expect(notifier.state.envsUnfiltered, isTrue);
      expect(notifier.state.groups, ['g1', 'g2']);

      notifier.setGroups(['g1', 'g2']);
      notifier.setKeyword('K1');
      await notifier.load();

      expect(queries.last['all'], 1);
      expect(queries.last['groups'], 'g1,g2');
      expect(queries.last['keyword'], 'K1');
      expect(notifier.state.envsUnfiltered, isFalse);
    });

    test('列表 GET 失败：error 有原因、envs 保留旧值、envsUnfiltered 不变', () async {
      final panel = _FakePanel(_jia);
      final notifier = await _loaded(panel);
      panel.getReply = () => jsonResponse({'error': '数据库连接失败'}, status: 500);

      await notifier.load();

      expect(notifier.state.error, '数据库连接失败');
      expect(notifier.state.loading, isFalse);
      expect(_names(notifier), ['A', 'B', 'C', 'D', 'E']);
      expect(notifier.state.envsUnfiltered, isTrue);
    });
  });

  group('G4：失败时恢复', () {
    test('PUT 失败、紧接着的重拉也失败（断网）→ 列表回到拖动前，异常是 PUT 的原话', () async {
      final panel = _FakePanel(_jia);
      final notifier = await _loaded(panel);
      panel.putReply = () {
        panel.getThrows = true; // 紧接着的重拉也连不上
        return jsonResponse({'error': '数据库忙，请稍后再试'}, status: 500);
      };

      final error = await _captureError(() => notifier.moveEnv(1, 3));

      expect(extractErrorMessage(error, '保存排序失败'), '数据库忙，请稍后再试');
      expect(
        _names(notifier),
        ['A', 'B', 'C', 'D', 'E'],
        reason: '没保存上的顺序不能留在屏幕上',
      );
    });

    test('面板拒绝（变量刚被别人删了）→ 原话可取，列表按服务端顺序重拉', () async {
      final panel = _FakePanel(_jia);
      final notifier = await _loaded(panel);
      panel.putReply = () =>
          jsonResponse({'error': '目标环境变量不存在'}, status: 404);
      final getsBefore = panel.getCount;

      final error = await _captureError(() => notifier.moveEnv(3, 0));

      expect(extractErrorMessage(error, '保存排序失败'), '目标环境变量不存在');
      expect(_names(notifier), panel.visibleOrder);
      expect(_names(notifier), ['A', 'B', 'C', 'D', 'E']);
      expect(panel.getCount, getsBefore + 1, reason: '失败也要重拉');
    });

    test('PUT 卡住期间列表已被别的 load 换掉 → 失败时不拿拖动前的快照盖回去', () async {
      final panel = _FakePanel(_jia);
      final notifier = await _loaded(panel);
      final arrived = Completer<void>();
      panel
        ..putGate = Completer<void>()
        ..onPut = () {
          if (!arrived.isCompleted) arrived.complete();
        };
      final saving = _captureError(() => notifier.moveEnv(1, 3));
      await arrived.future;

      // 保存途中用户改了搜索词：这次重拉先回来，写入一份新列表（面板上的顺序也被别处改了）。
      panel.order = ['E', 'D', 'C', 'B', 'A'];
      notifier.setKeyword('x');
      await notifier.load();
      expect(_names(notifier), ['E', 'D', 'C', 'B', 'A']);
      expect(notifier.state.envsUnfiltered, isFalse);

      panel.putReply = () {
        panel.getThrows = true;
        return jsonResponse({'error': '数据库忙，请稍后再试'}, status: 500);
      };
      panel.putGate!.complete();
      final error = await saving;

      expect(extractErrorMessage(error, '保存排序失败'), '数据库忙，请稍后再试');
      expect(
        _names(notifier),
        ['E', 'D', 'C', 'B', 'A'],
        reason: '只回滚自己写的那份乐观顺序；列表已被换掉就不动',
      );
      expect(
        notifier.state.envsUnfiltered,
        isFalse,
        reason: 'envs 与 envsUnfiltered 必须来自同一次 load',
      );
    });
  });

  group('G5 / G7：松手时核对下标', () {
    test('G5：下标上已不是拖起的那条 → 拒绝、不发请求；对得上或为空（TalkBack）照常排', () async {
      final panel = _FakePanel(_jia);
      final notifier = await _loaded(panel);

      await expectLater(
        notifier.moveEnv(1, 3, draggedId: 99),
        _envWriteException('列表刚刷新过，请重新拖动'),
      );
      expect(panel.bodies, isEmpty);
      expect(_names(notifier), ['A', 'B', 'C', 'D', 'E']);

      await notifier.moveEnv(1, 3, draggedId: 2); // B，对得上
      // 为空：TalkBack 的「上移 / 下移」只调 onReorder、不调 onReorderStart，不核对。
      await notifier.moveEnv(0, 2);
      expect(panel.bodies, hasLength(2));
    });

    test('G7：下标越界（列表刚变短）→ 同一句拒绝，0 个 PUT，列表原样', () async {
      final panel = _FakePanel(_jia);
      final notifier = await _loaded(panel);

      for (final (oldIndex, newIndex) in [(9, 0), (0, 9), (-1, 2)]) {
        await expectLater(
          notifier.moveEnv(oldIndex, newIndex),
          _envWriteException('列表刚刷新过，请重新拖动'),
        );
      }

      expect(panel.bodies, isEmpty);
      expect(_names(notifier), ['A', 'B', 'C', 'D', 'E']);
    });
  });

  group('页面', () {
    Future<void> pumpPage(WidgetTester tester, _FakePanel panel) async {
      // 改窗口尺寸必须同时把像素比设成 1.0（默认 3.0），否则逻辑像素只有设定值的三分之一。
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            envListProvider.overrideWith(
              (ref) => EnvListNotifier(
                dio: dioWithAdapter(FakeHttpAdapter(panel.handle)),
              ),
            ),
          ],
          child: MaterialApp(theme: AppTheme.light(), home: const EnvListPage()),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> enterSortMode(WidgetTester tester) async {
      await tester.tap(find.text('排序'));
      await tester.pumpAndSettle();
    }

    ReorderableListView reorderList(WidgetTester tester) =>
        tester.widget<ReorderableListView>(find.byType(ReorderableListView));

    List<String> shownNames(WidgetTester tester) => [
      for (final widget in tester.widgetList<Text>(
        find.descendant(
          of: find.byType(ReorderableListView),
          matching: find.byType(Text),
        ),
      ))
        widget.data ?? '',
    ];

    testWidgets('首次加载失败：显示「环境变量加载失败」和面板原话，而不是「暂无环境变量」', (tester) async {
      final panel = _FakePanel(_jia)
        ..getReply = () => jsonResponse({'error': '数据库连接失败'}, status: 500);
      await pumpPage(tester, panel);

      expect(find.text('环境变量加载失败'), findsOneWidget);
      expect(find.text('数据库连接失败'), findsOneWidget);
      expect(find.text('暂无环境变量'), findsNothing);
    });

    testWidgets('松手立刻发一个 PUT，提示条写「松手即保存」，点「完成」不再发', (tester) async {
      final panel = _FakePanel(_jia);
      await pumpPage(tester, panel);
      await enterSortMode(tester);
      expect(find.text('长按拖拽调整顺序，松手即保存'), findsOneWidget);
      final getsBefore = panel.getCount;

      reorderList(tester).onReorder(1, 3);
      await tester.pumpAndSettle();

      expect(panel.bodies, [
        {'source_id': 2, 'target_id': 4, 'position': 'before'},
      ]);
      expect(panel.getCount, getsBefore + 1);
      expect(shownNames(tester), ['A', 'C', 'B', 'D', 'E']);

      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(panel.bodies, hasLength(1), reason: '「完成」只退出排序模式');
      expect(find.byType(ReorderableListView), findsNothing);
    });

    testWidgets('跨区：不发请求、提示能照着做的出路、列表原样', (tester) async {
      final panel = _FakePanel(_yi);
      await pumpPage(tester, panel);
      await enterSortMode(tester);

      reorderList(tester).onReorder(2, 0); // 普通变量 A 拖到置顶区最前
      await tester.pumpAndSettle();

      expect(panel.bodies, isEmpty);
      expect(find.textContaining('在变量详情里置顶或取消置顶'), findsOneWidget);
      expect(shownNames(tester), ['P1', 'P2', 'A', 'B', 'C']);
    });

    testWidgets('面板拒绝（变量刚被别人删了）：原话提示，列表按服务端顺序弹回', (tester) async {
      final panel = _FakePanel(_jia)
        ..putReply = () =>
            jsonResponse({'error': '目标环境变量不存在'}, status: 404);
      await pumpPage(tester, panel);
      await enterSortMode(tester);
      final getsBefore = panel.getCount;

      reorderList(tester).onReorder(3, 0);
      await tester.pumpAndSettle();

      expect(panel.bodies, hasLength(1));
      expect(find.text('目标环境变量不存在'), findsOneWidget);
      expect(panel.getCount, getsBefore + 1, reason: '失败也要重拉');
      expect(shownNames(tester), ['A', 'B', 'C', 'D', 'E']);
    });

    testWidgets('拖拽途中列表被重拉成同条数的另一种顺序：松手时核对 id 不符就拒绝，不发 PUT', (
      tester,
    ) async {
      final panel = _FakePanel(_jia);
      await pumpPage(tester, panel);
      await enterSortMode(tester);

      reorderList(tester).onReorderStart!(1); // 拖起 B
      // 别处（网页端）刚改过顺序，恰好在拖拽途中重拉回来。
      panel.order = ['E', 'D', 'C', 'B', 'A'];
      final container = ProviderScope.containerOf(
        tester.element(find.byType(EnvListPage)),
      );
      // testWidgets 跑在 FakeAsync 里，直接 await dio 驱动的 Future 会一直等到超时。
      await tester.runAsync(
        () => container.read(envListProvider.notifier).load(),
      );
      await tester.pump();
      expect(shownNames(tester), ['E', 'D', 'C', 'B', 'A']);

      reorderList(tester).onReorder(1, 3); // 下标 1 现在是 D，不是拖起的 B
      await tester.pumpAndSettle();

      expect(find.text('列表刚刷新过，请重新拖动'), findsOneWidget);
      expect(panel.bodies, isEmpty);
    });
  });
}
