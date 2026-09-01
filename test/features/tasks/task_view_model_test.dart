import 'dart:convert';

import 'package:daidai_app/features/tasks/providers/task_provider.dart';
import 'package:daidai_app/features/tasks/providers/task_view_provider.dart';
import 'package:daidai_app/shared/models/task_view.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_http_adapter.dart';

/// 任务视图（issue #4）模型的回归保护。
///
/// 这个模型有两处非常容易写错、写错了又不报错的地方：
/// 1. `filters` / `sort_rules` 在传输层是**字符串化的 JSON**，要解两层。
///    面板建视图时不校验 JSON 合法性，脏数据必须静默降级成空列表 ——
///    一条脏视图不该让整个任务页红掉。
/// 2. `status` 的取值必须是面板 Web 那四个**数值串**。自己发明中文串，
///    面板改文案时会静默失效（未知运算符/取值在面板侧是「放行」不是「报错」）。
void main() {
  group('filters 解析与降级', () {
    test('字段缺失、空串、"[]" 一律降级成空列表，不抛异常', () {
      expect(parseTaskViewFilters(null), isEmpty);
      expect(parseTaskViewFilters(''), isEmpty);
      expect(parseTaskViewFilters('   '), isEmpty);
      expect(parseTaskViewFilters('[]'), isEmpty);
    });

    test('非法 JSON 降级成空列表而不是抛异常', () {
      expect(parseTaskViewFilters('[{"field":'), isEmpty);
      expect(parseTaskViewFilters('这不是 JSON'), isEmpty);
    });

    test('解出来不是数组（对象 / 数字 / 字符串）同样降级', () {
      expect(parseTaskViewFilters('{"field":"command"}'), isEmpty);
      expect(parseTaskViewFilters('123'), isEmpty);
      expect(parseTaskViewFilters('"command"'), isEmpty);
    });

    test('合法 JSON 字符串解成规则，operator 落到 op 字段', () {
      final filters = parseTaskViewFilters(
        '[{"field":"command","operator":"contains","value":"jd_bean"},'
        '{"field":"subscription","operator":"not_contains","value":"旧源"}]',
      );
      expect(filters.length, 2);
      expect(filters.first.field, 'command');
      expect(filters.first.op, 'contains');
      expect(filters.first.value, 'jd_bean');
      expect(filters[1].op, 'not_contains');
    });

    test('数组里混进非对象元素时只跳过那一项，不整条作废', () {
      final filters = parseTaskViewFilters(
        '[1,"x",{"field":"name","operator":"equals","value":"签到"}]',
      );
      expect(filters.length, 1);
      expect(filters.single.field, 'name');
    });

    test('已经是数组的形态也能吃下：面板日后改成直接下发数组时不用改客户端', () {
      final filters = parseTaskViewFilters([
        {'field': 'labels', 'operator': 'equals', 'value': '娱乐'},
      ]);
      expect(filters.single.value, '娱乐');
    });

    test('字段缺失的规则解成空串，并被 isUsable 判成不可用', () {
      final filters = parseTaskViewFilters('[{"field":"command"}]');
      expect(filters.single.op, '');
      expect(filters.single.value, '');
      expect(filters.single.isUsable, isFalse);
    });
  });

  group('脏规则播种成编辑器草稿', () {
    test('缺 operator 的规则也能播种成合法草稿：面板不校验写进去的 JSON', () {
      // 面板自己只是在查询时跳过这条规则（task_query.go:353），视图完全正常，
      // 所以库里真的存得下它。APP 这边直接播种的话，DropdownButton 的
      // value='' 在 items 里找不到匹配项，会踩它的构造断言 ——
      // debug 包一按「编辑」当场红屏，release 包渲染成一个选不动的空框。
      final filters = parseTaskViewFilters('[{"field":"labels","value":"娱乐"}]');
      expect(filters.single.op, '');
      expect(filters.single.isUsable, isFalse);

      final draft = normalizeTaskViewFilterDraft(filters.single);
      expect(draft.field, 'labels');
      expect(draft.op, kTaskViewOperators.first.value);
      expect(draft.value, '娱乐');
      expect(
        kTaskViewFilterFields.any((option) => option.value == draft.field),
        isTrue,
        reason: 'DropdownButton 断言 items 里必须恰好一项等于 value',
      );
      expect(
        kTaskViewOperators.any((option) => option.value == draft.op),
        isTrue,
      );
    });

    test('field 也缺时落回第一个可筛字段，不留空串', () {
      final draft = normalizeTaskViewFilterDraft(
        const TaskViewFilter(field: '  ', op: '', value: 'jd'),
      );
      expect(draft.field, kTaskViewFilterFields.first.value);
      expect(draft.op, kTaskViewOperators.first.value);
      expect(draft.value, 'jd');
      expect(draft.isUsable, isTrue);
    });

    test('面板日后新增的未知字段 / 运算符原样保留，不被替换成第一项', () {
      final draft = normalizeTaskViewFilterDraft(
        const TaskViewFilter(field: 'brand_new', op: 'starts_with', value: 'x'),
      );
      expect(draft.field, 'brand_new');
      expect(draft.op, 'starts_with');
    });

    test('值为空的规则不补默认值：那是用户自己要填的，替他编一个才是坑', () {
      final draft = normalizeTaskViewFilterDraft(
        const TaskViewFilter(field: 'command', op: 'contains', value: ''),
      );
      expect(draft.value, '');
      expect(draft.isUsable, isFalse);
    });
  });

  group('编辑器只暴露第一条排序规则，但不许吃掉其余条', () {
    // 面板的 UpdateView 收到**非空** sort_rules 是整体覆盖，而 task_views 表
    // 没有 user_id、全站共享 —— 只回传编辑到的那一条，等于「在手机上把视图名
    // 改一下保存」就把网页端所有人的第二条排序规则永久删掉了。
    const twoRules =
        '[{"field":"status","direction":"desc"},'
        '{"field":"name","direction":"asc"}]';

    test('只改名字保存，网页上配的第二条排序规则原样还在', () {
      final view = TaskView.fromJson({
        'id': 9,
        'name': '旧名字',
        'sort_rules': twoRules,
      });
      final seeded = splitTaskViewSortRules(view.sortRules);
      expect(seeded.edited?.field, 'status');
      expect(seeded.extras.map((rule) => rule.field).toList(), ['name']);

      // 用户只改了名字，两个排序控件一个都没动。
      final submitted = composeTaskViewSortRules(
        editedField: seeded.edited?.field,
        editedDirection: seeded.edited?.direction ?? 'asc',
        extraRules: seeded.extras,
      );
      expect(encodeTaskViewSortRules(submitted), twoRules);
    });

    test('改了第一条的方向，第二条仍然原样带回去', () {
      final seeded = splitTaskViewSortRules(parseTaskViewSortRules(twoRules));
      final submitted = composeTaskViewSortRules(
        editedField: 'status',
        editedDirection: 'asc',
        extraRules: seeded.extras,
      );
      expect(
        encodeTaskViewSortRules(submitted),
        '[{"field":"status","direction":"asc"},'
        '{"field":"name","direction":"asc"}]',
      );
    });

    test('把第一条改成与第二条同字段时不许拼出重复项', () {
      // 原本 [status desc, name asc]，用户把第一条改成 name。
      // 直接拼会得到 [name asc, name asc] —— 服务端第二条恒 0 无害，
      // 但网页端会多出一条自相矛盾的规则，而这是所有人都看得见的共享数据。
      final seeded = splitTaskViewSortRules(parseTaskViewSortRules(twoRules));
      final submitted = composeTaskViewSortRules(
        editedField: 'name',
        editedDirection: 'desc',
        extraRules: seeded.extras,
      );
      expect(
        encodeTaskViewSortRules(submitted),
        '[{"field":"name","direction":"desc"}]',
      );
    });

    test('第一条选回「默认顺序」只去掉第一条，看不见的那条不受牵连', () {
      final seeded = splitTaskViewSortRules(parseTaskViewSortRules(twoRules));
      final submitted = composeTaskViewSortRules(
        editedField: null,
        editedDirection: 'asc',
        extraRules: seeded.extras,
      );
      expect(
        encodeTaskViewSortRules(submitted),
        '[{"field":"name","direction":"asc"}]',
      );
    });

    test('本来就没有排序规则时提交空列表（编码成 "[]"，即清空）', () {
      final seeded = splitTaskViewSortRules(const []);
      expect(seeded.edited, isNull);
      expect(seeded.extras, isEmpty);
      expect(
        encodeTaskViewSortRules(
          composeTaskViewSortRules(
            editedField: '',
            editedDirection: 'asc',
            extraRules: seeded.extras,
          ),
        ),
        '[]',
      );
    });

    test('field 为空的脏排序规则不占用「第一条」，也不会被带回去', () {
      final seeded = splitTaskViewSortRules(
        parseTaskViewSortRules(
          '[{"field":"","direction":"desc"},{"field":"name"},'
          '{"field":"command","direction":"desc"}]',
        ),
      );
      expect(seeded.edited?.field, 'name');
      expect(seeded.extras.map((rule) => rule.field).toList(), ['command']);
    });

    test('未知的 direction 在拼装时也会被归一，不把脏值发回面板', () {
      final submitted = composeTaskViewSortRules(
        editedField: '  name  ',
        editedDirection: '倒序',
        extraRules: const [],
      );
      expect(
        encodeTaskViewSortRules(submitted),
        '[{"field":"name","direction":"asc"}]',
      );
    });
  });

  group('sort_rules 解析与方向归一', () {
    test('direction 非 desc 一律归一成 asc（含空、未知值）', () {
      expect(normalizeTaskViewSortDirection(null), 'asc');
      expect(normalizeTaskViewSortDirection(''), 'asc');
      expect(normalizeTaskViewSortDirection('ascending'), 'asc');
      expect(normalizeTaskViewSortDirection('倒序'), 'asc');
    });

    test('desc 不区分大小写与前后空格', () {
      expect(normalizeTaskViewSortDirection('desc'), 'desc');
      expect(normalizeTaskViewSortDirection('DESC'), 'desc');
      expect(normalizeTaskViewSortDirection('  Desc '), 'desc');
    });

    test('排序规则同样对空串 / 非法 JSON 降级', () {
      expect(parseTaskViewSortRules(''), isEmpty);
      expect(parseTaskViewSortRules('[]'), isEmpty);
      expect(parseTaskViewSortRules('{'), isEmpty);
    });

    test('合法排序规则解析后 direction 已归一', () {
      final rules = parseTaskViewSortRules(
        '[{"field":"created_at","direction":"DESC"}]',
      );
      expect(rules.single.field, 'created_at');
      expect(rules.single.direction, 'desc');
      expect(rules.single.isDescending, isTrue);
    });
  });

  group('序列化回字符串', () {
    test('空列表必须是 "[]" 而不是 ""：面板把空串当成「这个字段不改」', () {
      expect(encodeTaskViewFilters(const []), '[]');
      expect(encodeTaskViewSortRules(const []), '[]');
    });

    test('序列化用的键名是 operator，不是 Dart 侧的 op', () {
      final json = jsonDecode(
        encodeTaskViewFilters(const [
          TaskViewFilter(field: 'status', op: 'equals', value: '0.5'),
        ]),
      );
      expect(json, [
        {'field': 'status', 'operator': 'equals', 'value': '0.5'},
      ]);
    });

    test('解析 → 序列化 → 再解析，规则不变', () {
      const raw =
          '[{"field":"cron_expression","operator":"not_equals","value":"0 0 * * *"}]';
      final once = parseTaskViewFilters(raw);
      final twice = parseTaskViewFilters(encodeTaskViewFilters(once));
      expect(twice.single.field, 'cron_expression');
      expect(twice.single.op, 'not_equals');
      expect(twice.single.value, '0 0 * * *');
    });
  });

  group('TaskView.fromJson', () {
    test('整条视图解析：hidden / sort_order / 两组规则', () {
      final view = TaskView.fromJson({
        'id': 7,
        'name': '京东',
        'filters': '[{"field":"command","operator":"contains","value":"jd"}]',
        'sort_rules': '[{"field":"name","direction":"desc"}]',
        'hidden': true,
        'sort_order': 3,
      });
      expect(view.id, 7);
      expect(view.name, '京东');
      expect(view.filters.single.value, 'jd');
      expect(view.sortRules.single.direction, 'desc');
      expect(view.hidden, isTrue);
      expect(view.sortOrder, 3);
    });

    test('缺字段的视图不抛异常，退成安全默认值', () {
      final view = TaskView.fromJson({'id': 1});
      expect(view.name, '');
      expect(view.filters, isEmpty);
      expect(view.sortRules, isEmpty);
      expect(view.hidden, isFalse);
      expect(view.sortOrder, 0);
    });
  });

  group('下拉选项表', () {
    test('status 必须是面板那四个固定数值串', () {
      expect(kTaskViewStatusValues.map((item) => item.value).toList(), [
        '1',
        '0',
        '2',
        '0.5',
      ]);
    });

    test('运算符恰好四种，面板认不出来的会被静默放行，所以不能自造第五种', () {
      expect(kTaskViewOperators.map((item) => item.value).toList(), [
        'contains',
        'not_contains',
        'equals',
        'not_equals',
      ]);
    });

    test('可筛字段与面板 ViewManager 一致', () {
      expect(kTaskViewFilterFields.map((item) => item.value).toList(), [
        'command',
        'name',
        'cron_expression',
        'status',
        'labels',
        'subscription',
      ]);
    });

    test('可排序字段比可筛字段多一个 created_at', () {
      expect(kTaskViewSortFields.map((item) => item.value), contains('created_at'));
      expect(kTaskViewSortFields.length, kTaskViewFilterFields.length + 1);
    });

    test('认不出来的取值原样显示，不冒充成某个已知选项', () {
      expect(taskViewOptionLabel(kTaskViewFilterFields, 'command'), '命令');
      expect(taskViewOptionLabel(kTaskViewFilterFields, 'brand_new'), 'brand_new');
    });
  });

  group('规则摘要', () {
    test('status 的数值串在摘要里换成中文，别的字段原样显示', () {
      expect(
        taskViewFilterSummary(
          const TaskViewFilter(field: 'status', op: 'equals', value: '2'),
        ),
        '状态 等于 运行中',
      );
      expect(
        taskViewFilterSummary(
          const TaskViewFilter(field: 'command', op: 'contains', value: 'jd'),
        ),
        '命令 包含 jd',
      );
    });

    test('没有规则的视图要说清楚它等同于全部任务，而不是显示成空白', () {
      expect(
        taskViewRuleSummary(const TaskView(id: 1, name: '空视图')),
        '没有筛选规则，等同于全部任务',
      );
    });

    test('筛选与排序拼在一条摘要里', () {
      final view = TaskView.fromJson({
        'id': 2,
        'name': '订阅任务',
        'filters':
            '[{"field":"subscription","operator":"contains","value":"华星"}]',
        'sort_rules': '[{"field":"created_at","direction":"desc"}]',
      });
      expect(taskViewRuleSummary(view), '订阅 包含 华星 · 按创建时间倒序');
    });
  });

  group('TaskViewNotifier.load 的降级', () {
    test('404（老面板没有这条路由）静默降级：supported=false，不报错', () async {
      final adapter = FakeHttpAdapter(
        (_) => jsonResponse({'error': '404 page not found'}, status: 404),
      );
      final notifier = TaskViewNotifier(dio: dioWithAdapter(adapter));

      await notifier.load();

      expect(notifier.state.supported, isFalse);
      expect(notifier.state.views, isEmpty);
      expect(
        notifier.state.error,
        isNull,
        reason: '老面板没有这个能力不是「出错」，弹错误会让整个任务页看起来坏了',
      );
      expect(notifier.state.loading, isFalse);
    });

    test('403（角色不够）同样静默降级成隐藏入口', () async {
      final adapter = FakeHttpAdapter(
        (_) => jsonResponse({'error': '权限不足'}, status: 403),
      );
      final notifier = TaskViewNotifier(dio: dioWithAdapter(adapter));

      await notifier.load();

      expect(notifier.state.supported, isFalse);
      expect(notifier.state.error, isNull);
    });

    test('500 才算真出错：error 是后端原文，supported 保持 true', () async {
      final adapter = FakeHttpAdapter(
        (_) => jsonResponse({'error': '面板数据库连接失败'}, status: 500),
      );
      final notifier = TaskViewNotifier(dio: dioWithAdapter(adapter));

      await notifier.load();

      expect(notifier.state.error, '面板数据库连接失败');
      expect(notifier.state.supported, isTrue);
    });

    test('断网给中文说明，不是 dio 那句英文', () async {
      final adapter = FakeHttpAdapter(
        (options) => throw DioException.connectionError(
          requestOptions: options,
          reason: 'Failed host lookup',
        ),
      );
      final notifier = TaskViewNotifier(dio: dioWithAdapter(adapter));

      await notifier.load();

      expect(notifier.state.error, '无法连接到面板，请检查网络或面板是否在线');
    });

    test('成功后 error 被清空，hidden 的视图仍在 views 里但不进 visibleViews', () async {
      var failFirst = true;
      final adapter = FakeHttpAdapter((_) {
        if (failFirst) {
          failFirst = false;
          return jsonResponse({'error': '临时故障'}, status: 500);
        }
        return jsonResponse({
          'data': [
            {
              'id': 1,
              'name': '京东',
              'filters':
                  '[{"field":"command","operator":"contains","value":"jd"}]',
              'sort_rules': '[]',
              'hidden': false,
            },
            {'id': 2, 'name': '已隐藏', 'filters': '[]', 'hidden': true},
          ],
        });
      });
      final notifier = TaskViewNotifier(dio: dioWithAdapter(adapter));

      await notifier.load();
      expect(notifier.state.error, isNotNull);

      await notifier.load();
      expect(notifier.state.error, isNull);
      expect(notifier.state.views.length, 2);
      expect(notifier.state.visibleViews.map((v) => v.id).toList(), [1]);
      expect(notifier.state.viewById(2)?.name, '已隐藏');
      expect(notifier.state.viewById(99), isNull);
    });
  });

  group('ListViews 的响应形状', () {
    test('真实响应是**裸 JSON 数组**：面板走的是 response.Success(c, views)', () async {
      // 不是 {"data": [...]}。extractPaginated 的 `is List` 分支兜得住，
      // 但形状是契约的一部分，得有一条用例真的按线上的样子喂进来 ——
      // 否则哪天有人「顺手」把那个分支删了，测试全绿、线上视图全空。
      final adapter = FakeHttpAdapter(
        (_) => jsonListResponse([
          {
            'id': 1,
            'name': '京东',
            'filters':
                '[{"field":"command","operator":"contains","value":"jd"}]',
            'sort_rules': '[{"field":"name","direction":"desc"}]',
            'hidden': false,
          },
          {'id': 2, 'name': '已隐藏', 'filters': '[]', 'hidden': true},
        ]),
      );
      final notifier = TaskViewNotifier(dio: dioWithAdapter(adapter));

      await notifier.load();

      expect(notifier.state.views.length, 2);
      expect(notifier.state.visibleViews.map((v) => v.id).toList(), [1]);
      expect(notifier.state.views.first.filters.single.value, 'jd');
      expect(notifier.state.views.first.sortRules.single.isDescending, isTrue);
      expect(notifier.state.supported, isTrue);
      expect(notifier.state.error, isNull);
    });

    test('空视图的裸数组 `[]` 不是错误，只是「面板上还没建视图」', () async {
      final adapter = FakeHttpAdapter((_) => jsonListResponse(const []));
      final notifier = TaskViewNotifier(dio: dioWithAdapter(adapter));

      await notifier.load();

      expect(notifier.state.views, isEmpty);
      expect(notifier.state.supported, isTrue);
      expect(notifier.state.error, isNull);
    });
  });

  group('TaskViewNotifier 的写操作请求体', () {
    test('新建：filters / sort_rules 是字符串化 JSON，空列表是 "[]" 而不是 ""', () async {
      Map<String, dynamic>? posted;
      final adapter = FakeHttpAdapter((options) {
        if (options.method == 'POST' && options.data is Map) {
          posted = Map<String, dynamic>.from(options.data as Map);
        }
        return jsonResponse({'data': []});
      });
      final notifier = TaskViewNotifier(dio: dioWithAdapter(adapter));

      await notifier.create(
        name: '京东',
        filters: const [
          TaskViewFilter(field: 'command', op: 'contains', value: 'jd'),
        ],
        sortRules: const [],
      );

      expect(posted?['name'], '京东');
      expect(
        posted?['filters'],
        '[{"field":"command","operator":"contains","value":"jd"}]',
      );
      expect(
        posted?['sort_rules'],
        '[]',
        reason: '面板把空串当成「这个字段不改」，传 "" 会让清空规则静默失效',
      );
      expect(adapter.requests.first.path, '/api/tasks/views');
    });

    test('修改打到 /api/tasks/views/:id，清空规则传的是 "[]"', () async {
      Map<String, dynamic>? put;
      final adapter = FakeHttpAdapter((options) {
        if (options.method == 'PUT' && options.data is Map) {
          put = Map<String, dynamic>.from(options.data as Map);
        }
        return jsonResponse({'data': []});
      });
      final notifier = TaskViewNotifier(dio: dioWithAdapter(adapter));

      await notifier.update(
        id: 7,
        name: '京东',
        filters: const [],
        sortRules: const [],
      );

      expect(adapter.requests.first.method, 'PUT');
      expect(adapter.requests.first.path, '/api/tasks/views/7');
      expect(put?['filters'], '[]');
      expect(put?['sort_rules'], '[]');
    });
  });

  group('TaskNotifier 把视图规则透传给任务列表接口', () {
    test('选中视图后 filters / sort_rules 进 query，且是字符串化 JSON', () async {
      Map<String, dynamic>? query;
      final adapter = FakeHttpAdapter((options) {
        query = Map<String, dynamic>.from(options.queryParameters);
        return jsonResponse({'data': [], 'total': 0});
      });
      final notifier = TaskNotifier(dio: dioWithAdapter(adapter));

      notifier.applyView(
        TaskView.fromJson({
          'id': 3,
          'name': '订阅',
          'filters':
              '[{"field":"subscription","operator":"contains","value":"华星"}]',
          'sort_rules': '[{"field":"name","direction":"desc"}]',
        }),
      );
      // applyView 是 void（内部 load 不 await），这里把事件队列排空再断言。
      await pumpEventQueue();

      expect(
        query?['filters'],
        '[{"field":"subscription","operator":"contains","value":"华星"}]',
      );
      expect(query?['sort_rules'], '[{"field":"name","direction":"desc"}]');
      expect(notifier.state.selectedViewId, 3);
    });

    test('没选视图时**不带** filters —— 带一个空 "[]" 会把面板推进全表扫描的慢路径', () async {
      Map<String, dynamic>? query;
      final adapter = FakeHttpAdapter((options) {
        query = Map<String, dynamic>.from(options.queryParameters);
        return jsonResponse({'data': [], 'total': 0});
      });
      final notifier = TaskNotifier(dio: dioWithAdapter(adapter));

      await notifier.load();

      expect(query?.containsKey('filters'), isFalse);
      expect(query?.containsKey('sort_rules'), isFalse);
    });

    test('清除筛选把状态 / 分组 / 视图一次清干净，且只发一次请求', () async {
      final adapter = FakeHttpAdapter(
        (_) => jsonResponse({'data': [], 'total': 0}),
      );
      final notifier = TaskNotifier(dio: dioWithAdapter(adapter));

      notifier.applyView(
        TaskView.fromJson({
          'id': 3,
          'name': '订阅',
          'filters':
              '[{"field":"subscription","operator":"contains","value":"华星"}]',
        }),
      );
      // applyView 是 void（内部 load 不 await），这里把事件队列排空再断言。
      await pumpEventQueue();
      final before = adapter.requests.length;

      notifier.clearFilters();
      // applyView 是 void（内部 load 不 await），这里把事件队列排空再断言。
      await pumpEventQueue();

      expect(notifier.state.selectedViewId, isNull);
      expect(notifier.state.filters, isEmpty);
      expect(notifier.state.sortRules, isEmpty);
      expect(notifier.state.labelFilter, isNull);
      expect(notifier.state.statusFilter, isNull);
      expect(
        adapter.requests.length - before,
        1,
        reason: '逐个调 setStatusFilter / setLabelFilter / applyView 会连打三次全量取数',
      );
    });
  });

  group('冷启动恢复只能发一次任务列表请求', () {
    test('setLabelSelection 只写状态、不发请求', () async {
      // 恢复分组时若用 setLabelFilter，会当场打出一次**不带** filters /
      // sort_rules 的请求，和页面初始化末尾那次带规则的请求并发：
      // 两次都写 state.tasks，谁后到谁赢 —— 用户上次既选了分组又选了视图时，
      // 列表可能显示成没经视图筛过的结果，按钮却写着视图名。
      Map<String, dynamic>? query;
      final adapter = FakeHttpAdapter((options) {
        query = Map<String, dynamic>.from(options.queryParameters);
        return jsonResponse({'data': [], 'total': 0});
      });
      final notifier = TaskNotifier(dio: dioWithAdapter(adapter));

      notifier.setLabelSelection('分组:生产');
      await pumpEventQueue();

      expect(adapter.requests, isEmpty);
      expect(notifier.state.labelFilter, '分组:生产');

      // 随后统一的那次 load() 才发请求，并且带上了恢复出来的分组。
      await notifier.load();
      expect(adapter.requests.length, 1);
      expect(query?['label'], '分组:生产');
    });

    test('setLabelFilter 仍然立刻刷新：用户点选分组的行为不能跟着改', () async {
      final adapter = FakeHttpAdapter(
        (_) => jsonResponse({'data': [], 'total': 0}),
      );
      final notifier = TaskNotifier(dio: dioWithAdapter(adapter));

      notifier.setLabelFilter('分组:生产');
      await pumpEventQueue();

      expect(adapter.requests.length, 1);
    });

    test('setViewSelection / setLabelSelection 不许把列表的错误信息抹掉', () async {
      // copyWith 的 error 是「不传即清空」，与列表无关的更新必须显式回传。
      // 视图列表回来得比任务列表晚，那时抹掉就成了「空列表 + 没有任何提示」。
      final adapter = FakeHttpAdapter(
        (_) => jsonResponse({'error': '面板数据库连接失败'}, status: 500),
      );
      final notifier = TaskNotifier(dio: dioWithAdapter(adapter));

      await notifier.load();
      expect(notifier.state.error, isNotNull);
      final error = notifier.state.error;

      notifier.setViewSelection(null);
      expect(notifier.state.error, error);

      notifier.setLabelSelection('分组:生产');
      expect(notifier.state.error, error);
    });
  });
}

/// 构造**裸 JSON 数组**的响应体。
///
/// `test/support/fake_http_adapter.dart` 里的 `jsonResponse` 只收 Map，
/// 而 `/api/tasks/views` 走的是 `response.Success(c, views)`，线上返回的就是
/// 一个裸数组，不是 `{"data": [...]}`。
ResponseBody jsonListResponse(List<dynamic> body) {
  return ResponseBody.fromString(
    jsonEncode(body),
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}
