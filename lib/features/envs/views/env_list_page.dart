import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/models/env_var.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/utils/time_utils.dart';
import '../../../shared/widgets/app_buttons.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/app_glass_circle_button.dart';
import '../../../shared/widgets/app_icon_tile.dart';
import '../../../shared/widgets/app_large_title_header.dart';
import '../../../shared/widgets/app_notice.dart';
import '../../../shared/widgets/app_pill_button.dart';
import '../../../shared/widgets/app_snack.dart';
import '../../../shared/widgets/app_state_views.dart';
// 应用锁只 import 不改（归 B6）：设备做不了系统验证时，按应用锁的密码 / 图案兜底。
import '../../app_lock/providers/app_lock_provider.dart';
import '../../app_lock/widgets/pattern_pad.dart';
import '../utils/env_secret.dart';
import '../utils/env_transfer.dart';

final envListProvider = StateNotifierProvider<EnvListNotifier, EnvListState>((
  ref,
) {
  return EnvListNotifier();
});

const _selectedGroupUnset = Object();

enum _EnvBatchAction { enable, disable, delete }

/// 写操作被面板拒绝了，或者在本地就被拦下、根本没发出去。
///
/// 存在的理由：面板 `POST /envs` **不是**用 4xx 表达「这条没建成」的（见
/// [envCreateFailureMessage]），dio 只看到 200/201，写操作必须自己把这种
/// 「HTTP 成功但业务失败」翻译成异常，UI 的 catch 才有东西可提示。
///
/// 拖拽排序（[EnvListNotifier.moveEnv]，APP #16 ①）在本地拦下时也抛它：
/// 跨区（置顶区 / 普通区互拖）、松手时列表刚刷新过、上一次排序还在保存。
/// 这几种都没发请求，页面按「提醒」（`AppSnack.warn`）提示，不报红。
/// 不为排序另开异常类：页面只需要区分「本地拦下」与「面板拒绝（DioException）」。
///
/// 字段名叫 message 不是随手起的：`extractErrorMessage`（api_utils.dart）
/// 取不到 `response.data['error']` 时会退回读 `error.message`，
/// 于是这条异常不用改任何调用点就能把面板原话透出去。
class EnvWriteException implements Exception {
  const EnvWriteException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 从 `POST /envs` 的响应里认出「一条都没建成」，返回面板给的原因；真建成了给 null。
///
/// 面板 handler（server/handler/env.go 的 `Create`）对**不合规的变量名不返回 400**：
/// 它逐条跳过、把原因写进 `errors`，`createdCount` 保持 0，最后走 `response.Success`
/// 回一个 **HTTP 200**：
///
/// ```json
/// {"message":"新增 0 条","data":[],"errors":["第 1 项: 变量名 '1abc' 格式无效"],"created":0}
/// ```
///
/// 不解析这个信封，APP 就会在一条都没建成时照样弹「环境变量已创建」、列表里却什么都没多
/// —— 那正是 issue #8「不能单独添加环境变量」的现场。面板 Web 踩不到，因为
/// `EnvEditDialog.vue` 先做了一次客户端校验，请求根本发不出去。
///
/// 真正的 400（请求体过大 / 请求内容为空 / 请求参数错误）走的是 `{"error": ...}`，
/// dio 那边直接抛 DioException，由 `extractErrorMessage` 取，不归这里管。
///
/// **只在能确证失败时才报错**：单条建成时面板回的是 `{"message":"创建成功","data":{...}}`，
/// 既没有 `errors` 也没有 `created`。这种形状一律当成功，否则会凭空多出失败提示。
String? envCreateFailureMessage(dynamic responseData) {
  if (responseData is! Map) {
    return null;
  }

  final errors = responseData['errors'];
  if (errors is List) {
    for (final item in errors) {
      final text = item?.toString().trim() ?? '';
      if (text.isNotEmpty) {
        // 单条新建最多只会有一条原因，把面板的原话原样交出去，不要再包装。
        return text;
      }
    }
  }

  // errors 空着但 created 明确是 0：面板没说为什么，也照样不能当成功。
  final created = responseData['created'];
  if (created is num && created == 0) {
    final message = responseData['message']?.toString().trim() ?? '';
    return message.isEmpty ? '面板没有创建任何变量' : message;
  }

  return null;
}

class EnvListState {
  final List<EnvVar> envs;
  final int total;
  final bool loading;
  final List<String> groups;
  final List<String> selectedGroups;
  final String keyword;

  /// 加载失败原因。为 null 表示这次请求成功了 —— UI 必须靠它区分
  /// 「面板里真的一个变量都没有」和「压根没拿到数据」。
  final String? error;

  /// 当前 [envs] 是不是整表（APP #16 ① 的 G1）：加载时没有搜索词、没有分组筛选，
  /// **并且**没被 `all=1` 的 5000 条上限截断（条数 ≥ 响应里的 total）。
  ///
  /// 只在 `load()` 成功写入 envs 时一起写，所以它描述的是「这份列表加载时」的条件，
  /// 不是此刻输入框里的搜索词：清空搜索后重拉还没回来（或失败）时，屏幕上仍是筛过的列表。
  /// 拖拽排序拖到可见末尾时靠它决定发空 target（= 本桶末尾）还是 `{前一条, after}`——
  /// 有看不见的行时发空 target，会把变量甩过那些行。
  final bool envsUnfiltered;

  const EnvListState({
    this.envs = const [],
    this.total = 0,
    this.loading = false,
    this.groups = const [],
    this.selectedGroups = const [],
    this.keyword = '',
    this.error,
    this.envsUnfiltered = true,
  });

  EnvListState copyWith({
    List<EnvVar>? envs,
    int? total,
    bool? loading,
    List<String>? groups,
    Object? selectedGroups = _selectedGroupUnset,
    String? keyword,
    String? error,
    bool? envsUnfiltered,
  }) {
    return EnvListState(
      envs: envs ?? this.envs,
      total: total ?? this.total,
      loading: loading ?? this.loading,
      groups: groups ?? this.groups,
      selectedGroups: identical(selectedGroups, _selectedGroupUnset)
          ? this.selectedGroups
          : selectedGroups as List<String>,
      keyword: keyword ?? this.keyword,
      // 与 envs 同进同出：不传就保留，只有 load() 成功时才改写。
      envsUnfiltered: envsUnfiltered ?? this.envsUnfiltered,
      // ⚠️ 这里**故意不写** `error ?? this.error`。
      // 语义选的是 TaskListState（task_provider.dart:43）那一套：
      // 任何不显式传 error 的 copyWith 都会清空错误，于是每次新请求
      // （load 开头的 copyWith(loading: true)）自动把上次的错误抹掉，
      // 不需要到处补 error: null。
      // 仓库里还有相反的一套（AuthState 用 _authFieldUnset 哨兵保留旧值），
      // 两种语义并存；这个 State 明确选前者，改成 `??` 会让错误提示永远不消失。
      error: error,
    );
  }
}

class EnvListNotifier extends StateNotifier<EnvListState> {
  /// [dio] **仅供测试注入**，生产路径不传，仍然走 `DioClient` 单例。
  /// 单例的 baseUrl 会随切换面板被改写，所以这里不在构造时把它存下来。
  EnvListNotifier({Dio? dio}) : _injectedDio = dio, super(const EnvListState());

  final Dio? _injectedDio;

  Dio get _dio => _injectedDio ?? DioClient.instance.dio;

  /// `load()` 的代次（APP #16 ① 的 G2 / G5）。搜索框、分组筛选、下拉刷新、每个写操作后的
  /// 重拉都会各自调 `load()`，它们本来就可能并发；只认最后发出去的那一次，
  /// 先发后到的旧响应不许盖掉新列表——排序拿这份列表算锚点，旧顺序回来就会算错。
  /// 先例：task_view_provider 的 group 能力探测序号、task_form_page 的 `_cronParseGeneration`。
  int _loadSeq = 0;

  /// 有一次拖拽排序的 PUT + 重拉还没结束（G2）。在飞时拒绝下一次拖动，见 [moveEnv]。
  bool _sorting = false;

  Future<void> load() async {
    final seq = ++_loadSeq;
    // G1：「这份列表有没有筛选」与请求参数同源，都取发请求这一刻的条件。
    final keyword = state.keyword;
    final selectedGroups = state.selectedGroups;
    final unfiltered = keyword.isEmpty && selectedGroups.isEmpty;
    state = state.copyWith(loading: true, error: null);
    try {
      final dio = _dio;
      // 一次 `all=1` 拉全（面板 v2.1.7 起认，上限 5000 条），不再按 page_size=100 逐页拉：
      // 逐页拉取不是快照，翻页途中有人排序 / 增删，会重复一行、丢一行（APP #16 已实测），
      // 而拖拽排序正是拿这份列表算锚点的。
      // （面板的 page_size 超过 100 会静默退回 20，所以以前才写死 100 循环翻页；
      // 现在不传 page_size，这个坑不再相关。）
      final params = <String, dynamic>{'all': 1};
      if (selectedGroups.isNotEmpty) {
        params['groups'] = selectedGroups.join(',');
      }
      if (keyword.isNotEmpty) {
        params['keyword'] = keyword;
      }

      final listFuture = dio.get(
        ApiEndpoints.envs,
        queryParameters: params,
      );
      // 分组列表是辅助数据。收紧 validateStatus 后它的 4xx（例如非管理员角色被 403）
      // 会让 Future.wait 整体失败，把已经取到的变量列表一起打成「加载失败」。
      // 两个请求仍然并发发出，但分组失败只降级成空分组。
      final groupsFuture = _fetchGroups();
      final response = await listFuture;
      final groups = await groupsFuture;
      // 期间又发起过新的 load()：这次的结果已经过期，整份丢掉。
      if (seq != _loadSeq) {
        return;
      }

      final paginated = extractPaginated(response.data);
      final items = paginated.items.map((e) => EnvVar.fromJson(e)).toList();
      state = state.copyWith(
        envs: items,
        total: paginated.total > items.length ? paginated.total : items.length,
        loading: false,
        groups: groups,
        // 超过 5000 条时 all=1 会被截断（total 在截断之前就数好了），
        // 这时列表并不是整表，排序要按「有筛选」处理。
        // 响应里取不到 total 时 extractPaginated 按条数算，不会误判成截断。
        envsUnfiltered: unfiltered && items.length >= paginated.total,
      );
    } catch (e) {
      // 过期的那次失败同样不算数：不能拿旧请求的错误盖掉新请求的结果。
      if (seq != _loadSeq) {
        return;
      }
      // 原来这里只写 copyWith(loading: false)，错误被完全吞掉，
      // 页面退化成「暂无环境变量」，用户分不清是没数据还是拿不到数据。
      state = state.copyWith(
        loading: false,
        error: extractListErrorMessage(e, '加载环境变量失败'),
      );
    }
  }

  /// 取分组列表。失败不抛：分组只用于筛选条，拿不到就当没有分组，
  /// 不能因此把整个环境变量列表判成加载失败。
  Future<List<String>> _fetchGroups() async {
    try {
      final response = await _dio.get(
        ApiEndpoints.envsGroups,
      );
      final raw = response.data;
      final List list;
      if (raw is List) {
        list = raw;
      } else if (raw is Map && raw['data'] is List) {
        list = raw['data'] as List;
      } else {
        list = const [];
      }
      return list.map((e) => e.toString()).toList();
    } catch (_) {
      return const [];
    }
  }

  void setGroups(List<String> groups) {
    state = state.copyWith(selectedGroups: groups);
    load();
  }

  void setKeyword(String keyword) {
    state = state.copyWith(keyword: keyword);
    load();
  }

  Future<void> toggle(int id, bool enabled) async {
    final dio = _dio;
    if (enabled) {
      await dio.put(ApiEndpoints.envEnable(id));
    } else {
      await dio.put(ApiEndpoints.envDisable(id));
    }
    await load();
  }

  /// 置顶 / 取消置顶（面板 v1.5.0 起的 `PUT /envs/:id/move-top`、`/cancel-top`）。
  ///
  /// 详情弹层的入口，也是排序跨区被拦下时给用户的出路（APP #16）。
  /// 调用方只按 [EnvVar.isPinned] 选其一：cancel-top 对没置顶的变量也会把它挪到普通区末尾，
  /// 不是「幂等的取消」。
  Future<void> setPinned(int id, bool pinned) async {
    final dio = _dio;
    if (pinned) {
      await dio.put(ApiEndpoints.envMoveTop(id));
    } else {
      await dio.put(ApiEndpoints.envCancelTop(id));
    }
    await load();
  }

  /// 标为重要 / 取消重要（面板 v3.3.6 起，APP #16 ②）。
  ///
  /// 请求体**只有** `important` 一个键：面板 `PUT /envs/:id` 的这个字段是指针，只带它时
  /// 只改这一列。带上 name / value 会拿弹层打开时的旧值冲掉别处刚改过的内容。
  /// 页面只在列表项带 `important` 键（形状探测）时才会调到这里，老面板绝不发。
  Future<void> setImportant(int id, bool important) async {
    await _dio.put(
      ApiEndpoints.envById(id),
      data: {'important': important},
    );
    await load();
  }

  Future<void> delete(int id) async {
    await _dio.delete(ApiEndpoints.envById(id));
    await load();
  }

  Future<void> batchDelete(List<int> ids) async {
    await _dio.delete(
      ApiEndpoints.envsBatchDelete,
      data: {'ids': ids},
    );
    await load();
  }

  Future<void> batchEnable(List<int> ids) async {
    await _dio.put(
      ApiEndpoints.envsBatchEnable,
      data: {'ids': ids},
    );
    await load();
  }

  Future<void> batchDisable(List<int> ids) async {
    await _dio.put(
      ApiEndpoints.envsBatchDisable,
      data: {'ids': ids},
    );
    await load();
  }

  Future<void> batchSetGroup(List<int> ids, List<String> groups) async {
    await _dio.put(
      ApiEndpoints.envsBatchGroup,
      data: {'ids': ids, 'groups': groups},
    );
    await load();
  }

  Future<void> create(
    String name,
    String value, {
    String remarks = '',
    List<String> groups = const [],
  }) async {
    final response = await _dio.post(
      ApiEndpoints.envs,
      data: {
        'name': name,
        'value': value,
        'remarks': remarks,
        'group': groups.join(','),
        'groups': groups,
      },
    );

    // 面板用「200 + errors」表达「这条没建成」，不是 4xx —— 见 envCreateFailureMessage。
    // 必须赶在 load() 之前判：一条都没建成时既不值得重拉列表，更不能让调用方弹「已创建」。
    final failure = envCreateFailureMessage(response.data);
    if (failure != null) {
      throw EnvWriteException(failure);
    }

    await load();
  }

  Future<void> update(
    int id,
    String name,
    String value, {
    String remarks = '',
    List<String> groups = const [],
  }) async {
    await _dio.put(
      ApiEndpoints.envById(id),
      // ⚠️ 故意不带 `important`：面板那边是指针字段，不传就不动。带上的话，
      // 会用弹层打开时的旧值冲掉别处（网页 / 弹层里的「标为重要」）刚改过的标记。
      data: {
        'name': name,
        'value': value,
        'remarks': remarks,
        'group': groups.join(','),
        'groups': groups,
      },
    );
    await load();
  }

  /// 拖拽排序：松手即保存，一次松手恰好一个 `PUT /envs/sort` + 一次重拉（APP #16 ①）。
  ///
  /// 面板语义（server/handler/env.go 的 `reorderEnvWithinSortBucket`）：把 source 插到
  /// target **前面**；`position:"after"` 插到后面（v3.2.8 起，更老的面板不认、按前面处理）；
  /// target 为空 = 移到 source 所在桶的末尾（v1.9.0 起），这时不看 position。
  /// 桶 = sort_order（1 置顶区 / 0 普通区），只许桶内互拖，跨桶回 400。
  ///
  /// 以前锚点取「落点上一行」却不带 position、拖到第一位发空 target、只在点「完成」时
  /// 发最后一次拖动，三处叠在一起，20 种拖法 0 种对。现在锚点照网页取看得见的邻居。
  ///
  /// [draggedId] 是 `onReorderStart` 时记下的那条（G5）；为空 = TalkBack 的「上移 / 下移」
  /// 语义动作（只调 onReorder、不调 onReorderStart），不核对。
  /// 本地拦下时抛 [EnvWriteException]（不发请求、不挪位）；面板拒绝时照原样抛 DioException。
  Future<void> moveEnv(int oldIndex, int newIndex, {int? draggedId}) async {
    final before = state.envs;
    // G7 越界 / G5 拖拽途中列表被重拉打断：拖起的那条已经不在这个下标上了。
    if (oldIndex < 0 ||
        oldIndex >= before.length ||
        newIndex < 0 ||
        newIndex > before.length ||
        (draggedId != null && before[oldIndex].id != draggedId)) {
      throw const EnvWriteException('列表刚刷新过，请重新拖动');
    }
    // ReorderableListView 给的 newIndex 是「移除前」的下标，往下拖要先减一。
    if (newIndex > oldIndex) {
      newIndex--;
    }
    // 原地松手：不发请求，也不提示。
    if (newIndex == oldIndex) {
      return;
    }
    // G2：上一次的 PUT + 重拉没结束前不接下一次，锚点一律在服务端确认过的顺序上算，
    // 请求天然串行。不排队：排队的锚点算在「前一次的乐观顺序」上，前一次失败后就全算错了。
    // 这句必须排在原地判断之后：从下方拖回原位时 Flutter 照样回调 onReorder(i, i+1)，
    // 排在前面会在保存途中对一次原地松手也弹「请稍候」。
    if (_sorting) {
      throw const EnvWriteException('上一次排序还在保存，请稍候再拖');
    }
    final items = List<EnvVar>.from(before);
    final source = items.removeAt(oldIndex);
    items.insert(newIndex, source);
    // 锚点取看得见的邻居（口径同网页 envs/index.vue 的 onEnd）。
    final next = newIndex + 1 < items.length ? items[newIndex + 1] : null;
    final prev = newIndex > 0 ? items[newIndex - 1] : null;
    final nextSameBucket = next != null && next.sortOrder == source.sortOrder;
    final prevSameBucket = prev != null && prev.sortOrder == source.sortOrder;
    if (!nextSameBucket && !prevSameBucket) {
      // G6：两侧都不同桶 = 真拖进了另一个区。本地拦下（不发请求、不挪位，列表原样弹回），
      // 并告诉用户能照着做的出路。
      throw const EnvWriteException(
        '置顶变量和普通变量请分别排序；要换区，请点「完成」后在变量详情里置顶或取消置顶',
      );
    }
    // G1：用这份列表加载时的条件，不读此刻的搜索词。
    final unfiltered = state.envsUnfiltered;
    _sorting = true;
    // 先在本地挪到位（乐观更新），否则松手瞬间列表会先弹回原位、等请求回来再跳一次。
    state = state.copyWith(envs: items);
    try {
      await _dio.put(
        ApiEndpoints.envsSort,
        data: {
          'source_id': source.id,
          // 后一条同桶 → 插到它前面。否则前一条必然同桶：
          // - 没筛选：插到本桶末尾（空 target）。v1.9.0 起所有面板都认，不依赖 after；
          // - 有筛选：后面可能还有看不见的行，只能发「插到前一条后面」。after 要 v3.2.8+，
          //   更老的面板会落到它前面一格，重拉后如实显示（已知差 1 格）。
          'target_id': nextSameBucket
              ? next.id
              : (unfiltered ? null : prev!.id),
          // 永远带上 position：target 为空时面板不看它，老面板请求结构里没有这个字段、直接忽略。
          'position': nextSameBucket ? 'before' : 'after',
        },
      );
    } catch (_) {
      // G4：先回滚到拖动前的顺序再重拉——PUT 与重拉都失败（断网）时，
      // 屏幕上不能留着一份没保存上的顺序。只回滚自己写的那份乐观顺序：
      // 期间别的 load() 已经换掉了列表，就不拿旧快照盖回去。
      if (identical(state.envs, items)) {
        state = state.copyWith(envs: before);
      }
      rethrow;
    } finally {
      // 成功要拿面板整桶重编号后的顺序；失败（跨区 400、变量刚被删 404）更要拉一次，
      // 按服务端顺序弹回去。load() 自己吞异常，不会盖掉上面 rethrow 的 PUT 异常。
      await load();
      _sorting = false;
    }
  }

  /// 导出。走面板 `GET /envs/export-all` —— 与 Web 端「导出 JSON」同一条接口。
  ///
  /// 为什么不直接序列化 [EnvListState.envs]：那份列表会被搜索词 / 分组筛过，
  /// 用户以为导了全部、实际只导了筛出来的那些，而且**看不出来**。
  /// export-all 返回的是未分页未筛选的全量数组，同名多条各占一行 —— 无损导出的前提。
  ///
  /// [ids] 非空时只导这些 id（对应列表页的多选）。失败**不静默降级**成本地列表：
  /// 宁可报错，也不能让用户拿到一份少了几条却毫无提示的备份。
  Future<List<EnvTransferItem>> exportAll({List<int>? ids}) async {
    final response = await _dio.get(
      ApiEndpoints.envsExportAll,
      queryParameters: (ids == null || ids.isEmpty)
          ? null
          : <String, dynamic>{'ids': ids.join(',')},
    );

    final data = extractData(response.data);
    if (data is! List) {
      return const <EnvTransferItem>[];
    }
    return data
        .whereType<Map<String, dynamic>>()
        .map(EnvTransferItem.fromJson)
        .toList();
  }

  /// 导入。不 try/catch：写操作吞掉异常会让 UI 拿不到失败原因（spec 明令禁止）。
  Future<EnvImportOutcome> importEnvs({
    required List<EnvTransferItem> items,
    required EnvImportMode mode,
  }) async {
    final response = await _dio.post(
      ApiEndpoints.envsImport,
      data: buildEnvImportRequest(items: items, mode: mode),
    );
    await load();
    return EnvImportOutcome.fromResponse(response.data);
  }
}

class EnvListPage extends ConsumerStatefulWidget {
  const EnvListPage({super.key});

  @override
  ConsumerState<EnvListPage> createState() => _EnvListPageState();
}

class _EnvListPageState extends ConsumerState<EnvListPage> {
  final _searchController = TextEditingController();
  final Set<int> _selectedIds = <int>{};
  Timer? _debounce;

  bool _selectionMode = false;
  bool _sortMode = false;

  /// 排序模式里拖起的那条变量的 id（`onReorderStart` 记下，松手时 [_moveEnv] 取走）。
  /// 拖拽途中列表被重拉成另一种顺序时，松手给的下标就对不上了，靠它核对（APP #16 ① 的 G5）。
  int? _draggingEnvId;

  /// 已经点「查看」揭开的敏感变量（A6）。只活在这一次页面停留里：
  /// 下拉刷新时收回（同网页「一刷新就全部收回遮蔽」），离开页面 State 销毁也就没了。
  final Set<int> _revealedIds = <int>{};

  /// 最近一次验证通过的时间。60 秒内再查看 / 复制不再问（A6）。
  DateTime? _revealAuthAt;

  /// 系统验证弹窗还开着：连点两下眼睛时不叠第二个验证。
  bool _revealAuthBusy = false;

  static const Duration _revealAuthWindow = Duration(seconds: 60);

  /// 查看 / 复制敏感值前的验证（A6）。通过返回 true。
  ///
  /// 0. 应用锁没开启 → 直接放行（用户决定：开了应用锁才验证；值照样默认遮住，点「查看」就显示）；
  /// 1. 60 秒内验证过 → 直接放行；
  /// 2. 先走系统验证：指纹 / 面容 / 设备密码（[envDeviceAuthProvider]）；
  /// 3. 设备做不了系统验证（没设锁屏密码、没硬件）时，照应用锁现有的降级策略：
  ///    应用锁设了密码或图案 → 用它验证（与锁屏共用输错冷却）；
  ///    应用锁也没有任何验证方式 → 放行。应用锁自己的规则就是「没有验证方式就不上锁」，
  ///    这台设备上本来就没有能拿来验证的东西，硬拦只会让用户永远看不到自己的变量。
  Future<bool> _ensureRevealAuth() async {
    // 应用锁没开（含开了但一个验证方式都没有，见 AppLockState.isEnabled）：不验证。
    // 应用锁状态由根部的 AppLockGate 在启动时读好，这里只读不改。
    if (!ref.read(appLockProvider).isEnabled) {
      return true;
    }
    final last = _revealAuthAt;
    if (last != null && DateTime.now().difference(last) < _revealAuthWindow) {
      return true;
    }
    if (_revealAuthBusy) {
      return false;
    }
    _revealAuthBusy = true;
    try {
      final result = await ref.read(envDeviceAuthProvider)();
      if (!mounted) {
        return false;
      }
      var passed = false;
      switch (result.outcome) {
        case EnvAuthOutcome.passed:
          passed = true;
          break;
        case EnvAuthOutcome.failed:
          if (result.message != null) {
            AppSnack.warn(context, result.message!);
          }
          break;
        case EnvAuthOutcome.unavailable:
          final lock = ref.read(appLockProvider);
          if (lock.hasPassword || lock.hasPattern) {
            passed = await _verifyWithAppLock(lock);
          } else {
            passed = true;
          }
          break;
      }
      if (passed) {
        _revealAuthAt = DateTime.now();
      }
      return passed;
    } finally {
      _revealAuthBusy = false;
    }
  }

  /// 设备做不了系统验证时的兜底：用应用锁的密码（优先）或图案验证一次，见 [_AppLockVerifyDialog]。
  Future<bool> _verifyWithAppLock(AppLockState lock) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _AppLockVerifyDialog(
        usePassword: lock.hasPassword,
        controller: ref.read(appLockProvider.notifier),
      ),
    );
    return ok == true;
  }

  /// 列表行 / 详情弹层的「查看」：验证通过后揭开这一条。
  Future<bool> _revealEnv(EnvVar env) async {
    if (!await _ensureRevealAuth() || !mounted) {
      return false;
    }
    setState(() => _revealedIds.add(env.id));
    return true;
  }

  /// 复制变量值：敏感值先验证（60 秒内验证过就不再问），普通值直接复制。
  /// [toastContext] 传弹层自己的 context 时提示落在弹层上方。
  Future<void> _copyEnvValue(
    EnvVar env,
    String value, {
    BuildContext? toastContext,
  }) async {
    if (shouldMaskEnvValue(env.name, env.value) && !await _ensureRevealAuth()) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: value));
    final target = toastContext ?? context;
    if (!target.mounted) {
      return;
    }
    AppSnack.success(target, '已复制值');
  }

  Widget _buildGroupAutocomplete({
    required TextEditingController controller,
    required List<String> options,
  }) {
    return Autocomplete<String>(
      optionsBuilder: (textEditingValue) {
        final keyword = textEditingValue.text.trim().toLowerCase();
        if (keyword.isEmpty) {
          return options;
        }
        return options.where((group) => group.toLowerCase().contains(keyword));
      },
      onSelected: (value) => controller.text = value,
      fieldViewBuilder:
          (context, textEditingController, focusNode, onSubmitted) {
            textEditingController.value = controller.value;
            textEditingController.addListener(() {
              controller.value = textEditingController.value;
            });
            return TextField(
              controller: textEditingController,
              focusNode: focusNode,
              decoration: const InputDecoration(
                labelText: '分组',
                hintText: '可选已有分组或直接输入',
              ),
              onSubmitted: (_) => onSubmitted(),
            );
          },
      optionsViewBuilder: (context, onSelected, autocompleteOptions) {
        final items = autocompleteOptions.toList(growable: false);
        if (items.isEmpty) {
          return const SizedBox.shrink();
        }
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            // 全库仅有的两处「阴影是唯一分隔物」之一：这层浮层直接盖在表单上，
            // 去掉 elevation 必须同时补底色与边框，否则与下方表单糊在一起。
            // 注意 shape 与 borderRadius 互斥（同时传会在运行时 assert），
            // 所以原来那行 borderRadius 已删除，圆角改由 shape 承载。
            elevation: 0,
            color: context.palette.card,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
              side: BorderSide(color: context.palette.separator),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220, maxWidth: 280),
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                shrinkWrap: true,
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final group = items[index];
                  return ListTile(
                    dense: true,
                    title: Text(group),
                    onTap: () => onSelected(group),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  List<String> _normalizeGroups(Iterable<String> values) {
    final seen = <String>{};
    final result = <String>[];
    for (final raw in values) {
      for (final group in raw.split(',')) {
        final trimmed = group.trim();
        if (trimmed.isEmpty || seen.contains(trimmed)) {
          continue;
        }
        seen.add(trimmed);
        result.add(trimmed);
      }
    }
    return result;
  }

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(envListProvider.notifier).load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  bool _isSelected(int id) => _selectedIds.contains(id);

  bool _isAllSelected(List<EnvVar> envs) =>
      envs.isNotEmpty && envs.every((env) => _selectedIds.contains(env.id));

  void _setSelectionMode(bool enabled) {
    setState(() {
      _selectionMode = enabled;
      if (!enabled) {
        _selectedIds.clear();
      }
    });
  }

  void _toggleSelection(int id) {
    setState(() {
      _selectionMode = true;
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
      if (_selectedIds.isEmpty) {
        _selectionMode = false;
      }
    });
  }

  void _toggleSelectAll(List<EnvVar> envs) {
    final visibleIds = envs.map((env) => env.id).toSet();
    setState(() {
      if (visibleIds.isNotEmpty &&
          visibleIds.every((id) => _selectedIds.contains(id))) {
        _selectedIds.removeAll(visibleIds);
        if (_selectedIds.isEmpty) {
          _selectionMode = false;
        }
      } else {
        _selectionMode = true;
        _selectedIds.addAll(visibleIds);
      }
    });
  }

  /// [count] 是真正要删的条数；[skipped] 是选中了、但因为是重要变量被剔掉的条数（APP #16 ②）。
  Future<bool> _confirmBatchDelete(int count, {int skipped = 0}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('批量删除'),
        // 有被跳过的重要变量时把账算清楚：选了几个、跳过几个、实际删几个。
        // 没有时文案与改动前逐字相同（老面板永远走这一支）。
        content: Text(
          skipped > 0
              ? '选中的 ${count + skipped} 个环境变量里有 $skipped 个是重要变量，'
                    '将跳过它们，只删除其余 $count 个。'
              : '确定删除选中的 $count 个环境变量吗？',
        ),
        actions: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(dialogCtx).pop(false),
                    child: const Text('取消'),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: FilledButton(
                    onPressed: () => Navigator.of(dialogCtx).pop(true),
                    style: FilledButton.styleFrom(
                      backgroundColor: dialogCtx.palette.err,
                    ),
                    // 按钮上写明实际删几个，免得用户以为选中的全删了。
                    child: Text(skipped > 0 ? '删除 $count 个' : '删除'),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );

    return confirmed == true;
  }

  Future<bool> _confirmDelete(EnvVar env) async {
    // 重要变量（APP #16 ②）单独一套措辞：点名它是重要变量、按钮写「仍要删除」。
    // 服务端不拦删除（只做客户端保护），这个确认框就是 APP 上唯一的一道防线。
    // 老面板没有 important 键，isImportant 恒为 false，文案与改动前逐字相同。
    final important = env.isImportant;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(important ? '删除重要变量' : '删除环境变量'),
        content: Text(
          important
              ? '「${env.name}」已标为重要变量，常用来存脚本依赖的配置。确定仍要删除吗？删除后无法恢复。'
              : '确定删除「${env.name}」吗？删除后无法恢复。',
        ),
        actions: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(dialogCtx).pop(false),
                    child: const Text('取消'),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: FilledButton(
                    onPressed: () => Navigator.of(dialogCtx).pop(true),
                    style: FilledButton.styleFrom(
                      backgroundColor: dialogCtx.palette.err,
                    ),
                    child: Text(important ? '仍要删除' : '删除'),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );

    return confirmed == true;
  }

  Future<void> _setEnvEnabled(EnvVar env, bool enabled) async {
    if (env.enabled == enabled) {
      return;
    }

    try {
      await ref.read(envListProvider.notifier).toggle(env.id, enabled);
      if (!mounted) {
        return;
      }
      AppSnack.success(
        context,
        enabled ? '已启用 ${env.name}' : '已禁用 ${env.name}',
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppSnack.error(context, extractErrorMessage(error, '修改环境变量状态失败'));
    }
  }

  Future<void> _deleteEnv(EnvVar env) async {
    final confirmed = await _confirmDelete(env);
    if (!confirmed || !mounted) {
      return;
    }

    try {
      await ref.read(envListProvider.notifier).delete(env.id);
      if (!mounted) {
        return;
      }
      AppSnack.success(context, '已删除 ${env.name}');
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppSnack.error(context, extractErrorMessage(error, '删除环境变量失败'));
    }
  }

  Future<void> _performBatchAction(_EnvBatchAction action) async {
    var ids = _selectedIds.toList()..sort();
    if (ids.isEmpty) {
      return;
    }

    // 选中了、但因为是重要变量而跳过的条数（只有批量删除会跳过）。
    var skipped = 0;
    if (action == _EnvBatchAction.delete) {
      // 批量删除默认跳过重要变量（APP #16 ②）：服务端不拦，只能在发请求前剔掉。
      // 按当前列表里的标记判断；老面板没有 important 键，什么都不剔，流程与改动前相同。
      final importantIds = ref
          .read(envListProvider)
          .envs
          .where((env) => env.isImportant)
          .map((env) => env.id)
          .toSet();
      final selectedCount = ids.length;
      ids = ids.where((id) => !importantIds.contains(id)).toList();
      skipped = selectedCount - ids.length;
      if (ids.isEmpty) {
        // 全是重要变量：不弹确认、不发请求，也不退出多选，让用户自己决定要不要逐个删。
        AppSnack.warn(
          context,
          '选中的 $selectedCount 个都是重要变量，没有可删除的；确需删除请逐个左滑删除',
        );
        return;
      }
      final confirmed = await _confirmBatchDelete(ids.length, skipped: skipped);
      if (!confirmed) {
        return;
      }
    }

    try {
      final notifier = ref.read(envListProvider.notifier);
      switch (action) {
        case _EnvBatchAction.enable:
          await notifier.batchEnable(ids);
          break;
        case _EnvBatchAction.disable:
          await notifier.batchDisable(ids);
          break;
        case _EnvBatchAction.delete:
          await notifier.batchDelete(ids);
          break;
      }

      if (!mounted) {
        return;
      }

      _setSelectionMode(false);
      final message = switch (action) {
        _EnvBatchAction.enable => '已批量启用 ${ids.length} 个环境变量',
        _EnvBatchAction.disable => '已批量禁用 ${ids.length} 个环境变量',
        _EnvBatchAction.delete =>
          skipped > 0
              ? '已删除 ${ids.length} 个环境变量，跳过 $skipped 个重要变量'
              : '已批量删除 ${ids.length} 个环境变量',
      };
      AppSnack.success(context, message);
    } catch (error) {
      if (!mounted) {
        return;
      }
      // 原来是 catch (_) 配一句固定文案，服务端说的「哪一条删不掉」被整个丢掉。
      // 与本文件其余写操作一致，先用服务端消息，拿不到再退回这句。
      AppSnack.error(context, extractErrorMessage(error, '批量操作失败，请稍后重试'));
    }
  }

  Future<void> _performBatchGroup(List<String> groups) async {
    final ids = _selectedIds.toList()..sort();
    if (ids.isEmpty) {
      return;
    }

    try {
      await ref.read(envListProvider.notifier).batchSetGroup(ids, groups);
      if (!mounted) {
        return;
      }

      _setSelectionMode(false);
      final message = groups.isEmpty
          ? '已清空 ${ids.length} 个环境变量的分组'
          : '已将 ${ids.length} 个环境变量分组到“${groups.join(' / ')}”';
      AppSnack.success(context, message);
    } catch (error) {
      if (!mounted) {
        return;
      }
      // 同上：分组失败时服务端的具体原因比一句「请稍后重试」有用。
      AppSnack.error(context, extractErrorMessage(error, '批量分组失败，请稍后重试'));
    }
  }

  Future<void> _showBatchGroupDialog(List<String> groups) async {
    if (_selectedIds.isEmpty) {
      return;
    }

    final controller = TextEditingController();
    final selectedGroups = <String>{};
    final result = await showDialog<List<String>>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('批量分组'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('将已选择的 ${_selectedIds.length} 个环境变量设置到同一分组。'),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  decoration: const InputDecoration(
                    labelText: '分组名称',
                    hintText: '输入多个分组，逗号分隔',
                  ),
                  onChanged: (_) => setDialogState(() {}),
                ),
                if (groups.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  const Text(
                    '已有分组',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: groups
                        .map(
                          (group) => ActionChip(
                            label: Text(group),
                            onPressed: () {
                              if (selectedGroups.contains(group)) {
                                selectedGroups.remove(group);
                              } else {
                                selectedGroups.add(group);
                              }
                              final merged = _normalizeGroups([
                                controller.text,
                                ...selectedGroups,
                              ]);
                              controller.text = merged.join(', ');
                              controller.selection = TextSelection.fromPosition(
                                TextPosition(offset: controller.text.length),
                              );
                              setDialogState(() {});
                            },
                          ),
                        )
                        .toList(),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(dialogCtx).pop(),
                      child: const Text('取消'),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(dialogCtx).pop(const []),
                      child: const Text('清空分组'),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: FilledButton(
                      onPressed: () => Navigator.of(dialogCtx).pop(
                        _normalizeGroups([controller.text, ...selectedGroups]),
                      ),
                      child: const Text('确认'),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    if (!mounted || result == null) {
      return;
    }

    await _performBatchGroup(result);
  }

  /// 松手即保存：一次松手只发一次 `PUT /envs/sort`（见 [EnvListNotifier.moveEnv]）。
  ///
  /// 写成 State 方法而不是 onReorder 里的闭包，是因为提示要用页面自己的 context：
  /// build 的 context 形参在分析器眼里和 State.mounted 不是一回事。
  ///
  /// 成功不弹提示：列表本身就是反馈（同任务页）。本地拦下（跨区 / 列表刚刷新 / 上一次还在保存）
  /// 是提醒不是失败，走 warn；面板拒绝才走 error。失败时 notifier 已按服务端顺序把列表弹回去，
  /// 这里只负责把原因说出来。
  Future<void> _moveEnv(int oldIndex, int newIndex) async {
    // 取走拖起时记下的 id：这次松手用完就清，下一次拖起会重新记。
    final draggedId = _draggingEnvId;
    _draggingEnvId = null;
    try {
      await ref
          .read(envListProvider.notifier)
          .moveEnv(oldIndex, newIndex, draggedId: draggedId);
    } on EnvWriteException catch (error) {
      if (!mounted) {
        return;
      }
      AppSnack.warn(context, error.message);
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppSnack.error(context, extractErrorMessage(error, '保存排序失败'));
    }
  }

  Future<void> _refresh() async {
    if (_selectionMode) {
      _setSelectionMode(false);
    }
    // 刷新就把揭开的敏感值全部收回（同网页 #127）；60 秒验证窗口不动，再点眼睛不用重新验证。
    if (_revealedIds.isNotEmpty) {
      setState(_revealedIds.clear);
    }
    await ref.read(envListProvider.notifier).load();
  }

  /// 大标题右边的「⋯」菜单：批量、排序、导出、导入（v2.0 换装前它们是页头的一排胶囊）。
  ///
  /// 页头只留「⋯」和「＋」两个圆形玻璃按钮：360dp 屏上四个胶囊放不下（APP #21），
  /// 收进菜单后窄屏、大字号都不会把「＋」挤出屏幕。多选态只给导出 / 导入（导出可以只导选中的）。
  /// [anchorContext] 是按钮自己的 context，菜单贴着按钮弹出。
  Future<void> _showMoreMenu(BuildContext anchorContext) async {
    final palette = context.palette;
    final button = anchorContext.findRenderObject() as RenderBox?;
    final overlay =
        Navigator.of(context).overlay?.context.findRenderObject() as RenderBox?;
    if (button == null || overlay == null) {
      return;
    }
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(
          button.size.bottomLeft(Offset.zero),
          ancestor: overlay,
        ),
        button.localToGlobal(
          button.size.bottomRight(Offset.zero),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );

    PopupMenuItem<String> item(String value, IconData icon, String label) {
      return PopupMenuItem<String>(
        value: value,
        child: Row(
          children: [
            Icon(icon, size: 18, color: palette.text2),
            const SizedBox(width: AppSpacing.sm),
            Text(label),
          ],
        ),
      );
    }

    final value = await showMenu<String>(
      context: context,
      position: position,
      items: [
        if (!_selectionMode) ...[
          item('batch', Icons.checklist_rounded, '批量'),
          item('sort', Icons.swap_vert_rounded, '排序'),
        ],
        item('export', Icons.ios_share, '导出变量'),
        item('import', Icons.file_download_outlined, '导入变量'),
      ],
    );
    if (!mounted || value == null) {
      return;
    }
    switch (value) {
      case 'batch':
        _setSelectionMode(true);
        break;
      case 'sort':
        setState(() => _sortMode = true);
        break;
      case 'export':
        _showExportSheet();
        break;
      case 'import':
        _showImportSheet();
        break;
    }
  }

  Future<void> _showExportSheet() async {
    final selectedIds = _selectedIds.toList()..sort();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useRootNavigator: true,
      builder: (_) => _EnvExportSheet(
        selectedIds: selectedIds,
        loadItems: (ids) =>
            ref.read(envListProvider.notifier).exportAll(ids: ids),
      ),
    );
  }

  Future<void> _showImportSheet() async {
    // 「面板上已经有多条同名同备注」这条提醒用的是**当前已加载的列表**，它可能被
    // 搜索词 / 分组筛过。最坏情况只是少给一条提醒，不影响面板的实际行为；
    // 真正会造成数据损坏的那一条（文件内同名同备注重复）只看导入文件本身，
    // 与这份列表无关 —— 见 analyzeEnvImport 的注释。
    final listState = ref.read(envListProvider);
    final existing = listState.envs
        .map(
          (env) => EnvTransferItem(
            name: env.name,
            value: env.value,
            remarks: env.remarks,
            groups: env.groups,
            enabled: env.enabled,
          ),
        )
        .toList();

    // 替换导入会连「重要」变量一起清空（APP #16 ②），确认框要点名。按顺序判断：
    // 1. 列表里没有任何一条带 important 键（老面板，或筛选结果为空）→ 不提示；
    // 2. 整表（没筛选、没被截断），数是全的 → 有几个报几个，一个都没有就不提示；
    // 3. 有筛选或被 5000 条截断，数不全 → 只给一句笼统的提醒，不报一个错的数字。
    String? importantNotice;
    if (listState.envs.any((env) => env.important != null)) {
      if (listState.envsUnfiltered) {
        final importantCount = listState.envs
            .where((env) => env.isImportant)
            .length;
        if (importantCount > 0) {
          importantNotice = '其中包括 $importantCount 个重要变量，它们也会被清空。';
        }
      } else {
        importantNotice = '面板上标为「重要」的变量（如果有）也会一并清空。';
      }
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useRootNavigator: true,
      builder: (_) => _EnvImportSheet(
        existing: existing,
        importantNotice: importantNotice,
        submit: (items, mode) => ref
            .read(envListProvider.notifier)
            .importEnvs(items: items, mode: mode),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(envListProvider);
    final palette = context.palette;
    final selectedCount = _selectedIds.length;
    final allSelected = _isAllSelected(state.envs);
    // 底部留白按底栏实际高度算（AppSpacing.listBottomOf），在 ListView 外面读好再传进去。
    final listBottom = AppSpacing.listBottomOf(context);
    // 搜索框与分组筛选是同一行、同为 44 高的一对灰色胶囊。
    final searchBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.pill),
      borderSide: BorderSide.none,
    );

    return Scaffold(
      backgroundColor: palette.bg,
      body: Padding(
        padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 8),
        child: Column(
          children: [
            // 大标题头（v2.0）：普通态「⋯」「＋」，多选态「⋯」「取消」，排序态只剩「完成」。
            // 批量 / 排序 / 导入导出收进「⋯」菜单（见 _showMoreMenu），窄屏不再挤掉「＋」（APP #21）。
            AppLargeTitleHeader(
              title: '变量',
              actions: [
                if (_sortMode)
                  AppPillButton(
                    label: '完成',
                    icon: Icons.check_rounded,
                    height: 40,
                    // 每次松手已经各自保存过了（见 _moveEnv），
                    // 「完成」只是退出排序模式，不再攒到这里统一提交。
                    onPressed: () => setState(() {
                      _sortMode = false;
                      _draggingEnvId = null;
                    }),
                  )
                else ...[
                  // 包一层 Builder 拿按钮自己的 context，菜单贴着按钮弹出。
                  Builder(
                    builder: (buttonCtx) => AppGlassCircleButton(
                      icon: Icons.more_horiz_rounded,
                      tooltip: '更多',
                      onTap: () => _showMoreMenu(buttonCtx),
                    ),
                  ),
                  if (_selectionMode)
                    AppPillButton(
                      label: '取消',
                      variant: AppPillVariant.secondary,
                      height: 40,
                      onPressed: () => _setSelectionMode(false),
                    )
                  else
                    AppGlassCircleButton(
                      icon: Icons.add_rounded,
                      tooltip: '新建变量',
                      onTap: _showCreateDialog,
                    ),
                ],
              ],
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.pageHorizontal,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: TextField(
                        controller: _searchController,
                        decoration: InputDecoration(
                          hintText: '搜索变量',
                          prefixIcon: Icon(
                            Icons.search_rounded,
                            size: 20,
                            color: palette.text2,
                          ),
                          filled: true,
                          fillColor: palette.fill,
                          // 灰色填充胶囊、无描边：三种状态同一个 border，聚焦时不跳线。
                          border: searchBorder,
                          enabledBorder: searchBorder,
                          focusedBorder: searchBorder,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 12,
                          ),
                          isDense: true,
                          suffixIcon: _searchController.text.isNotEmpty
                              ? IconButton(
                                  icon: Icon(
                                    Icons.clear,
                                    size: 16,
                                    color: palette.text2,
                                  ),
                                  onPressed: () {
                                    // APP issue #18：必须先掐掉还没触发的搜索防抖。
                                    // 打完字 300ms 内点清空的话，那次防抖会在清空之后
                                    // 把旧关键词写回筛选状态 —— 输入框是空的、清空按钮也没了，
                                    // 列表却停在旧结果上，下拉刷新也沿用旧词；
                                    // provider 是全局的，切页回来照旧，只能杀后台。
                                    _debounce?.cancel();
                                    _debounce = null;
                                    _searchController.clear();
                                    if (_selectionMode) {
                                      _setSelectionMode(false);
                                    }
                                    ref
                                        .read(envListProvider.notifier)
                                        .setKeyword('');
                                  },
                                )
                              : null,
                        ),
                        style: AppText.body.copyWith(color: palette.text),
                        onChanged: (v) {
                          setState(() {});
                          if (_selectionMode) {
                            _setSelectionMode(false);
                          }
                          _debounce?.cancel();
                          _debounce = Timer(
                            const Duration(milliseconds: 300),
                            () {
                              ref.read(envListProvider.notifier).setKeyword(v);
                            },
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  PopupMenuButton<String>(
                    tooltip: '筛选分组',
                    onSelected: (value) {
                      if (_selectionMode) {
                        _setSelectionMode(false);
                      }
                      if (value == '__all__') {
                        ref.read(envListProvider.notifier).setGroups(const []);
                        return;
                      }
                      final current = [...state.selectedGroups];
                      if (current.contains(value)) {
                        current.remove(value);
                      } else {
                        current.add(value);
                      }
                      ref
                          .read(envListProvider.notifier)
                          .setGroups(_normalizeGroups(current));
                    },
                    itemBuilder: (_) => [
                      CheckedPopupMenuItem<String>(
                        value: '__all__',
                        checked: state.selectedGroups.isEmpty,
                        child: const Text('全部'),
                      ),
                      ...state.groups.map(
                        (g) => CheckedPopupMenuItem<String>(
                          value: g,
                          checked: state.selectedGroups.contains(g),
                          child: Text(g),
                        ),
                      ),
                    ],
                    child: Container(
                      height: 44,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(
                        color: palette.fill,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.label_outline,
                            size: 18,
                            color: palette.text2,
                          ),
                          const SizedBox(width: 6),
                          // 选了好几个分组时名字会很长：限宽省略，不把搜索框挤没。
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 110),
                            child: Text(
                              state.selectedGroups.isEmpty
                                  ? '全部'
                                  : state.selectedGroups.join(' / '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                color: palette.text,
                              ),
                            ),
                          ),
                          const SizedBox(width: 2),
                          Icon(
                            Icons.expand_more,
                            size: 18,
                            color: palette.text2,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_selectionMode) ...[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.pageHorizontal,
                ),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: palette.card,
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            '已选择 $selectedCount 项',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: palette.text,
                            ),
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: () => _toggleSelectAll(state.envs),
                            child: Text(allSelected ? '取消全选' : '全选'),
                          ),
                        ],
                      ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          AppTintedActionButton(
                            label: '批量分组',
                            icon: Icons.label_outline,
                            color: palette.accent,
                            enabled: selectedCount > 0,
                            onTap: () => _showBatchGroupDialog(state.groups),
                          ),
                          AppTintedActionButton(
                            label: '批量启用',
                            icon: Icons.play_circle_outline,
                            // 「启用」是成功绿，与「批量分组」的蓝分得开。
                            color: palette.ok,
                            enabled: selectedCount > 0,
                            onTap: () =>
                                _performBatchAction(_EnvBatchAction.enable),
                          ),
                          AppTintedActionButton(
                            label: '批量禁用',
                            icon: Icons.pause_circle_outline,
                            color: palette.text2,
                            enabled: selectedCount > 0,
                            onTap: () =>
                                _performBatchAction(_EnvBatchAction.disable),
                          ),
                          AppTintedActionButton(
                            label: '批量删除',
                            icon: Icons.delete_outline,
                            color: palette.err,
                            enabled: selectedCount > 0,
                            onTap: () =>
                                _performBatchAction(_EnvBatchAction.delete),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (_sortMode) ...[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.pageHorizontal,
                ),
                child: AppNotice(
                  color: palette.accent,
                  icon: Icons.swap_vert,
                  text: '长按拖拽调整顺序，松手即保存',
                  accentText: true,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: RefreshIndicator(
                color: palette.accent,
                onRefresh: _refresh,
                child: state.loading && state.envs.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: const [AppLoadingView()],
                      )
                    // 拿不到数据和真的没有数据是两回事，必须先判 error。
                    : state.error != null && state.envs.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          AppErrorView(
                            title: '环境变量加载失败',
                            message: state.error!,
                            onRetry: _refresh,
                          ),
                        ],
                      )
                    : state.envs.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: const [
                          AppEmptyView(
                            icon: Icons.key_off,
                            message: '暂无环境变量',
                          ),
                        ],
                      )
                    : _sortMode
                    // 排序态保持「一条一张卡」的平铺列表：拖拽排序按服务端顺序算锚点，
                    // 不能按分组重排（见 EnvListNotifier.moveEnv）。
                    ? ReorderableListView.builder(
                        padding: EdgeInsets.fromLTRB(
                          AppSpacing.pageHorizontal,
                          0,
                          AppSpacing.pageHorizontal,
                          listBottom,
                        ),
                        itemCount: state.envs.length,
                        // 拖起时记下是哪一条：拖拽途中列表可能被重拉成同条数、另一种顺序，
                        // 松手时 _moveEnv 拿它核对下标（G5）。只是记一下，不影响界面，不用 setState。
                        onReorderStart: (index) {
                          final envs = ref.read(envListProvider).envs;
                          _draggingEnvId = index < envs.length
                              ? envs[index].id
                              : null;
                        },
                        onReorder: _moveEnv,
                        itemBuilder: (_, i) {
                          final env = state.envs[i];
                          // ⚠️ key 必须挂在 ReorderableListView 的直接子 widget
                          // 上（这里就是这个 Container），挂到它的 child 上会在
                          // 拖拽时抛「Every item of ReorderableListView must
                          // have a key」。
                          return Container(
                            key: ValueKey(env.id),
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: palette.card,
                              borderRadius: BorderRadius.circular(AppRadius.lg),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.drag_handle,
                                  size: 20,
                                  color: palette.text3,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      // 排序时更要看得出哪条是置顶：置顶区和普通区不能互拖，
                                      // 看不出来就只能撞上「请分别排序」的提示才知道（APP #16）。
                                      // 名字放 Flexible：名字长时名字先省略，标记不被挤掉。
                                      Row(
                                        children: [
                                          Flexible(
                                            child: Text(
                                              env.name,
                                              style: TextStyle(
                                                fontSize: 15,
                                                fontWeight: FontWeight.w600,
                                                color: palette.text,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          if (env.isPinned) ...[
                                            const SizedBox(width: 4),
                                            Icon(
                                              Icons.push_pin,
                                              size: 14,
                                              color: palette.warn,
                                              semanticLabel: '已置顶',
                                            ),
                                          ],
                                          if (env.isImportant) ...[
                                            const SizedBox(width: 4),
                                            const _EnvImportantBadge(),
                                          ],
                                        ],
                                      ),
                                      if (env.remarks.isNotEmpty)
                                        Text(
                                          env.remarks,
                                          style: TextStyle(
                                            fontSize: 12.5,
                                            color: palette.text2,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                    ],
                                  ),
                                ),
                                // 启用状态圆点：已启用 = 绿，已禁用 = 弱化灰。
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: env.enabled
                                        ? palette.ok
                                        : palette.text3,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      )
                    : Builder(
                        builder: (context) {
                          // 普通态按分组排成分组列表（v2.0）：置顶 → 各分组（按第一次出现的
                          // 顺序）→ 未分组 → 已禁用。每组内部保持服务端顺序。
                          // 属于多个分组的变量只放进它的第一个分组：同一条出现两次会让多选、
                          // 左滑都对不上号。置顶的变量不论分组、启用与否都留在置顶组。
                          final pinned = <EnvVar>[];
                          final byGroup = <String, List<EnvVar>>{};
                          final ungrouped = <EnvVar>[];
                          final disabled = <EnvVar>[];
                          for (final env in state.envs) {
                            if (env.isPinned) {
                              pinned.add(env);
                            } else if (!env.enabled) {
                              disabled.add(env);
                            } else if (env.groups.isEmpty) {
                              ungrouped.add(env);
                            } else {
                              byGroup
                                  .putIfAbsent(env.groups.first, () => [])
                                  .add(env);
                            }
                          }
                          final sections = <(String, List<EnvVar>)>[
                            ('置顶', pinned),
                            for (final entry in byGroup.entries)
                              (entry.key, entry.value),
                            // 只有这一组时叫「全部」，旁边有别的分组时才叫「未分组」。
                            (
                              byGroup.isEmpty && pinned.isEmpty
                                  ? '全部'
                                  : '未分组',
                              ungrouped,
                            ),
                            ('已禁用', disabled),
                          ];
                          // 摊平成「组头 + 行」一维列表，ListView.builder 懒加载
                          // （面板最多一次给 5000 条，不能整组一次建出来）。
                          // 每一项：(组头文字, 变量, 是不是组内第一行, 是不是组内最后一行)。
                          final entries = <(String?, EnvVar?, bool, bool)>[];
                          for (final (title, envs) in sections) {
                            if (envs.isEmpty) {
                              continue;
                            }
                            entries.add(('$title · ${envs.length}', null, false, false));
                            for (var j = 0; j < envs.length; j++) {
                              entries.add((
                                null,
                                envs[j],
                                j == 0,
                                j == envs.length - 1,
                              ));
                            }
                          }
                          return ListView.builder(
                            padding: EdgeInsets.fromLTRB(
                              AppSpacing.pageHorizontal,
                              0,
                              AppSpacing.pageHorizontal,
                              listBottom,
                            ),
                            itemCount: entries.length,
                            itemBuilder: (_, i) {
                              final (header, env, first, last) = entries[i];
                              if (env == null) {
                                // 组头：同 AppGroupedList 的 header（说明字号、次要色），
                                // 第一组上面不多留空。
                                return Padding(
                                  padding: EdgeInsets.fromLTRB(
                                    20,
                                    i == 0 ? 4 : 22,
                                    20,
                                    8,
                                  ),
                                  child: Text(
                                    header!,
                                    style: AppText.caption.copyWith(
                                      color: palette.text2,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                );
                              }
                              final masked =
                                  shouldMaskEnvValue(env.name, env.value) &&
                                  !_revealedIds.contains(env.id);
                              return _EnvCard(
                                key: ValueKey(env.id),
                                env: env,
                                first: first,
                                last: last,
                                masked: masked,
                                selectionMode: _selectionMode,
                                selected: _isSelected(env.id),
                                onTap: () {
                                  if (_selectionMode) {
                                    _toggleSelection(env.id);
                                  } else {
                                    _showDetailSheet(env);
                                  }
                                },
                                onLongPress: () {
                                  if (!_selectionMode) {
                                    HapticFeedback.mediumImpact();
                                    setState(() => _sortMode = true);
                                  }
                                },
                                onSelectedChanged: () =>
                                    _toggleSelection(env.id),
                                onReveal: () => _revealEnv(env),
                                onCopy: () => _copyEnvValue(env, env.value),
                                onEnable: () => _setEnvEnabled(env, true),
                                onDisable: () => _setEnvEnabled(env, false),
                                onDelete: () => _deleteEnv(env),
                              );
                            },
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showDetailSheet(EnvVar env) {
    final nameC = TextEditingController(text: env.name);
    final valueC = TextEditingController(text: env.value);
    final remarksC = TextEditingController(text: env.remarks);
    final groupC = TextEditingController(text: env.groups.join(', '));
    final groups = [...ref.read(envListProvider).groups];
    var valueEditorOpen = false;
    // 弹层内的失败原因（APP #16）。弹层是根 Navigator 上的路由，页面的 SnackBar 被它整块盖住
    // （v1.3.5 实测过几何），弹层不关时原因必须写回弹层里；SnackBar 照旧发，弹层关掉后才露出来。
    // 新建弹层的 nameError 是同一个道理。
    String? sheetError;
    // A6：敏感值在弹层里同样先遮住，点「查看」验证后才换成可编辑的输入框。
    // 列表上已经揭开过的，进来直接是明文。没揭开时不动 valueC，保存照旧带原值。
    final sensitive = shouldMaskEnvValue(env.name, env.value);
    var sheetRevealed = !sensitive || _revealedIds.contains(env.id);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useRootNavigator: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final theme = Theme.of(ctx);
          final palette = ctx.palette;
          final navigator = Navigator.of(ctx);
          if (valueEditorOpen) {
            return _EnvValueSheetEditor(
              title: '编辑变量值',
              controller: valueC,
              onDone: () => setSheetState(() => valueEditorOpen = false),
            );
          }
          // 置顶按钮走图钉的橙色；按钮文字和描边直接压在弹层白底上，用墨色才够看。
          final pinColor = palette.warnInk;
          // 「重要」按钮与列表上的「重要」标记同一套紫。
          final importantColor = palette.purpleInk;
          // 内容最后包一层 SingleChildScrollView（见本 builder 末尾）：新面板下头部三个按钮
          // 在手机宽度会折成两行，键盘弹起时（「保存」失败多半就在这时）内容会顶出弹层底部。
          final sheetContent = Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              0,
              20,
              MediaQuery.of(ctx).viewInsets.bottom + 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      // 「当前已启用」= 绿色淡底配绿色墨字；禁用 = 灰色填充配次要色字。
                      decoration: BoxDecoration(
                        color: env.enabled
                            ? palette.tint(palette.ok)
                            : palette.fill,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      child: Text(
                        env.enabled ? '当前已启用' : '当前已禁用',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: env.enabled ? palette.okInk : palette.text2,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 三个状态动作放进 Wrap：窄屏自动折成两行，不溢出，也不挤掉左边的状态徽章。
                    // 三个按钮同一种交互：点了立即生效、成功关弹层；失败时弹层不关、原因写回弹层。
                    Expanded(
                      child: Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          // 置顶 / 取消置顶（APP #16）：也是排序跨区被拦下时提示里说的那条出路。
                          OutlinedButton.icon(
                            onPressed: () async {
                              try {
                                await ref
                                    .read(envListProvider.notifier)
                                    .setPinned(env.id, !env.isPinned);
                                // 关弹层只看弹层自己，弹提示只看页面（mounted），同下面 catch 的写法。
                                // 请求在飞时用户可能已把弹层划走 / 点遮罩关掉，或者连点了两下、
                                // 前一次回包已经关过它；这时再 pop，弹掉的是根 Navigator 上的
                                // 下一层（通常就是本页）。退场动画期间（约 200ms）弹层仍挂在树上，
                                // 光判 ctx.mounted 不够，还要看它是不是最上面那层
                                // （Flutter 自己下拉关弹层时也是这么判的）。
                                if (ctx.mounted &&
                                    ModalRoute.isCurrentOf(ctx) == true) {
                                  navigator.pop();
                                }
                                if (!mounted) {
                                  return;
                                }
                                AppSnack.success(
                                  context,
                                  env.isPinned
                                      ? '已取消置顶 ${env.name}'
                                      : '已置顶 ${env.name}',
                                );
                              } catch (error) {
                                final message = extractErrorMessage(
                                  error,
                                  '修改置顶状态失败',
                                );
                                // 判的是 ctx 而不是 State.mounted：请求没回来之前用户可以
                                // 把弹层划走，再 setSheetState 就是对已卸载的弹层 setState。
                                if (ctx.mounted) {
                                  setSheetState(() => sheetError = message);
                                }
                                if (!mounted) {
                                  return;
                                }
                                AppSnack.error(context, message);
                              }
                            },
                            // 图标同任务页左滑：已置顶给空心图钉（取消），没置顶给实心图钉。
                            icon: Icon(
                              env.isPinned
                                  ? Icons.push_pin_outlined
                                  : Icons.push_pin,
                              size: 16,
                            ),
                            label: Text(env.isPinned ? '取消置顶' : '置顶'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: pinColor,
                              side: BorderSide(color: pinColor),
                            ),
                          ),
                          // 标为重要 / 取消重要（APP #16 ②）。形状探测：列表项带 important 键
                          // （面板 v3.3.6+）才出现，老面板上这个按钮不存在，也就绝不会发这个键。
                          // 做成按钮而不是开关：弹层里的 env 是打开时捕获的、不随列表刷新，
                          // 开关不关弹层就得另养一份本地状态；按钮与同排两个动作保持一种交互。
                          if (env.important != null)
                            OutlinedButton.icon(
                              onPressed: () async {
                                try {
                                  await ref
                                      .read(envListProvider.notifier)
                                      .setImportant(env.id, !env.isImportant);
                                  // 只在弹层还开着时关它，理由见上面「置顶」按钮。
                                  if (ctx.mounted &&
                                      ModalRoute.isCurrentOf(ctx) == true) {
                                    navigator.pop();
                                  }
                                  if (!mounted) {
                                    return;
                                  }
                                  AppSnack.success(
                                    context,
                                    env.isImportant
                                        ? '已取消 ${env.name} 的重要标记'
                                        : '已将 ${env.name} 标为重要',
                                  );
                                } catch (error) {
                                  final message = extractErrorMessage(
                                    error,
                                    '修改重要标记失败',
                                  );
                                  if (ctx.mounted) {
                                    setSheetState(() => sheetError = message);
                                  }
                                  if (!mounted) {
                                    return;
                                  }
                                  AppSnack.error(context, message);
                                }
                              },
                              icon: Icon(
                                env.isImportant
                                    ? Icons.lock_open
                                    : Icons.lock_outline,
                                size: 16,
                              ),
                              label: Text(
                                env.isImportant ? '取消重要' : '标为重要',
                              ),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: importantColor,
                                side: BorderSide(color: importantColor),
                              ),
                            ),
                          OutlinedButton.icon(
                            onPressed: () async {
                              // 收紧 validateStatus 后 4xx 会抛异常，这里必须自己兜，
                              // 否则失败时既不提示也不关闭弹层，只在控制台留一个未捕获异常。
                              try {
                                await ref
                                    .read(envListProvider.notifier)
                                    .toggle(env.id, !env.enabled);
                                // 只在弹层还开着时关它，理由见上面「置顶」按钮。
                                if (ctx.mounted &&
                                    ModalRoute.isCurrentOf(ctx) == true) {
                                  navigator.pop();
                                }
                                if (!mounted) {
                                  return;
                                }
                                // 传页面自己的 context 而不是弹层的 ctx：提示挂在根
                                // ScaffoldMessenger 上，弹层已经 pop 掉了，用 ctx 只会
                                // 因为它不再挂在树上而被静默丢弃。
                                AppSnack.success(
                                  context,
                                  env.enabled
                                      ? '已禁用 ${env.name}'
                                      : '已启用 ${env.name}',
                                );
                              } catch (error) {
                                final message = extractErrorMessage(
                                  error,
                                  '修改环境变量状态失败',
                                );
                                // 弹层不关，SnackBar 又被弹层盖住：原因写回弹层（v1.3.5 遗留项，
                                // 本次加新按钮时一并收口，免得同一个弹层里两种失败提示）。
                                if (ctx.mounted) {
                                  setSheetState(() => sheetError = message);
                                }
                                if (!mounted) {
                                  return;
                                }
                                AppSnack.error(context, message);
                              }
                            },
                            icon: Icon(
                              env.enabled
                                  ? Icons.pause_circle_outline
                                  : Icons.play_arrow,
                              size: 16,
                            ),
                            label: Text(env.enabled ? '禁用' : '启用'),
                            // 「启用」动作走绿色墨色：按钮文字和描边直接压在弹层白底上，
                            // 满强度绿只有约 2.2:1，墨色才过 4.5:1。「禁用」是中性次要色。
                            style: OutlinedButton.styleFrom(
                              foregroundColor: env.enabled
                                  ? palette.text2
                                  : palette.okInk,
                              side: BorderSide(
                                color: env.enabled
                                    ? palette.separator
                                    : palette.okInk,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (sheetError != null) ...[
                  const SizedBox(height: 12),
                  AppNotice(
                    color: palette.err,
                    icon: Icons.error_outline,
                    text: sheetError!,
                    accentText: true,
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  env.name,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                // 详情里给完整时间（带年份和秒），列表卡上只给到分钟（APP #27）。
                const SizedBox(height: 4),
                Text(
                  '更新于 ${formatTimeCn(env.updatedAt)} · 创建于 ${formatTimeCn(env.createdAt)}',
                  style: TextStyle(fontSize: 12, color: palette.text2),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: nameC,
                  decoration: const InputDecoration(labelText: '变量名'),
                ),
                const SizedBox(height: 12),
                if (sheetRevealed)
                  TextField(
                    controller: valueC,
                    decoration: InputDecoration(
                      labelText: '值',
                      suffixIcon: IconButton(
                        // 变量值较长时切到弹窗内的大输入区，不再新开页面，避免回填丢失。
                        icon: const Icon(Icons.open_in_full, size: 18),
                        tooltip: '放大编辑变量值',
                        onPressed: () =>
                            setSheetState(() => valueEditorOpen = true),
                      ),
                    ),
                    maxLines: 4,
                    minLines: 2,
                  )
                else
                  // A6：遮住的值只给一个只读的「输入框外观」，点眼睛验证后换成真正的输入框。
                  // 不用 obscureText：它只支持单行，长 Cookie 换成单行就没法编辑了。
                  InputDecorator(
                    decoration: InputDecoration(
                      labelText: '值',
                      helperText: '敏感值已遮住，验证后可查看和编辑',
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.visibility_outlined, size: 20),
                        tooltip: '查看',
                        onPressed: () async {
                          final ok = await _revealEnv(env);
                          if (ok && ctx.mounted) {
                            setSheetState(() => sheetRevealed = true);
                          }
                        },
                      ),
                    ),
                    child: Text(
                      maskEnvValue(env.value),
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 15,
                        letterSpacing: 1.5,
                        color: palette.text2,
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                TextField(
                  controller: remarksC,
                  decoration: const InputDecoration(labelText: '备注'),
                ),
                const SizedBox(height: 12),
                _buildGroupAutocomplete(controller: groupC, options: groups),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => Navigator.of(ctx).pop(),
                        icon: const Icon(Icons.close, size: 16),
                        label: const Text('关闭'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 44),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        // A6：敏感值先验证（与「查看」共用 60 秒窗口），复制的是输入框里的当前内容。
                        onPressed: () => _copyEnvValue(
                          env,
                          valueC.text,
                          toastContext: ctx,
                        ),
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('复制'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: palette.accentInk,
                          side: BorderSide(color: palette.accentInk),
                          minimumSize: const Size(0, 44),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () async {
                          final navigator = Navigator.of(ctx);
                          try {
                            await ref
                                .read(envListProvider.notifier)
                                .update(
                                  env.id,
                                  nameC.text.trim(),
                                  valueC.text,
                                  remarks: remarksC.text.trim(),
                                  groups: _normalizeGroups([groupC.text]),
                                );
                            // 只在弹层还开着时关它，理由见上面「置顶」按钮。
                            if (ctx.mounted &&
                                ModalRoute.isCurrentOf(ctx) == true) {
                              navigator.pop();
                            }
                            if (!mounted) {
                              return;
                            }
                            // 同上：弹层已 pop，只有页面自己的 context 还能弹提示。
                            AppSnack.success(context, '已保存');
                          } catch (error) {
                            final message = extractErrorMessage(
                              error,
                              '保存环境变量失败',
                            );
                            // 保存失败时弹层不关（免得重填），原因写回弹层，理由同上面的按钮。
                            if (ctx.mounted) {
                              setSheetState(() => sheetError = message);
                            }
                            if (!mounted) {
                              return;
                            }
                            AppSnack.error(context, message);
                          }
                        },
                        icon: const Icon(Icons.save, size: 16),
                        label: const Text('保存'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 44),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
          // 内容整体可滚动。实测（411×891 加 300px 键盘）不包这层时底部溢出 17px，
          // 再加一条失败提示溢出 69px。内容放得下时 Scrollable 不接拖动，下拉关弹层照旧；
          // 放不下（键盘弹起）时内容区改为滚动，拖柄仍可关弹层。
          return SingleChildScrollView(child: sheetContent);
        },
      ),
    ).then((_) {
      nameC.dispose();
      valueC.dispose();
      remarksC.dispose();
      groupC.dispose();
    });
  }

  void _showCreateDialog() {
    final nameC = TextEditingController();
    final valueC = TextEditingController();
    final remarksC = TextEditingController();
    final groupC = TextEditingController();
    // 校验没过时要把焦点送回变量名输入框，所以这里得有个自己的 FocusNode。
    final nameFocus = FocusNode();
    final groups = [...ref.read(envListProvider).groups];
    var valueEditorOpen = false;
    // 变量名的就地错误提示。挂在弹窗上而不是用 SnackBar：这条提示要一直留到用户
    // 改完为止，弹一下就消失的话，和改动前「点了没反应」的体感差别不大。
    String? nameError;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useRootNavigator: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final navigator = Navigator.of(ctx);
          if (valueEditorOpen) {
            return _EnvValueSheetEditor(
              title: '新建变量值',
              controller: valueC,
              onDone: () => setSheetState(() => valueEditorOpen = false),
            );
          }
          return Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              0,
              20,
              MediaQuery.of(ctx).viewInsets.bottom + 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '新建环境变量',
                  style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: nameC,
                  focusNode: nameFocus,
                  decoration: InputDecoration(
                    labelText: '变量名',
                    hintText: '如 MY_TOKEN',
                    errorText: nameError,
                  ),
                  textInputAction: TextInputAction.next,
                  onChanged: (_) {
                    // 用户一动手就把红字撤掉，别让它一路挂到下一次提交。
                    if (nameError != null) {
                      setSheetState(() => nameError = null);
                    }
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: valueC,
                  decoration: InputDecoration(
                    labelText: '值',
                    suffixIcon: IconButton(
                      // 新建变量时也用同一个控制器放大编辑，完成后原表单立即保留输入。
                      icon: const Icon(Icons.open_in_full, size: 18),
                      tooltip: '放大编辑变量值',
                      onPressed: () =>
                          setSheetState(() => valueEditorOpen = true),
                    ),
                  ),
                  maxLines: 3,
                  minLines: 1,
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: remarksC,
                        decoration: const InputDecoration(labelText: '备注'),
                        textInputAction: TextInputAction.next,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildGroupAutocomplete(
                        controller: groupC,
                        options: groups,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () async {
                    final name = nameC.text.trim();
                    if (name.isEmpty) {
                      // 改动前这里是一句光秃秃的 `return`：不提示、不关弹窗、也不发请求，
                      // 用户点「创建」毫无反应，体感就是「加不进去」（issue #8）。
                      // 文案与面板 Web 的 EnvEditDialog 逐字一致，两端对同一条规则要一个说法。
                      setSheetState(() => nameError = '变量名不能为空');
                      nameFocus.requestFocus();
                      return;
                    }
                    if (nameError != null) {
                      setSheetState(() => nameError = null);
                    }
                    try {
                      await ref
                          .read(envListProvider.notifier)
                          .create(
                            name,
                            valueC.text,
                            remarks: remarksC.text.trim(),
                            groups: _normalizeGroups([groupC.text]),
                          );
                      // 只在弹层还开着时关它，理由见 _showDetailSheet 里「置顶」按钮。
                      if (ctx.mounted && ModalRoute.isCurrentOf(ctx) == true) {
                        navigator.pop();
                      }
                      if (!mounted) {
                        return;
                      }
                      // 同上：弹层已 pop，只有页面自己的 context 还能弹提示。
                      AppSnack.success(context, '环境变量已创建');
                    } catch (error) {
                      // 两类失败都落到这里，且都拿得到面板的原话：
                      // 4xx 走 DioException 的 `response.data['error']`；
                      // 「HTTP 200 但一条都没建成」走 EnvWriteException.message
                      // （extractErrorMessage 取不到 error 字段时会退回读 .message）。
                      final message = extractErrorMessage(error, '创建环境变量失败');
                      // 弹窗刻意不关：原因多半是变量名不合规，关掉用户就得重填一遍。
                      // 但**只发 SnackBar 等于白说**：它挂在页面的 Scaffold 上，而弹层是
                      // 根 Navigator 上的一条路由，整块压在它上面 —— widget 测实测
                      // snack 落在 (0,528)-(800,600)，完全位于 sheet (0,244)-(800,600)
                      // 之内，一个字都露不出来。所以原因必须同时写回变量名下方。
                      // 这里判的是 ctx（StatefulBuilder 自己的 context）而不是 State.mounted：
                      // 请求没回来之前用户可以把弹层划走，那时弹层先被 unmount，
                      // 再调 setSheetState 就是「对已卸载 Element 调 setState」
                      // —— subscription_list_page.dart:541 记过同一个坑。
                      if (ctx.mounted) {
                        setSheetState(() => nameError = message);
                      }
                      if (!mounted) {
                        return;
                      }
                      // SnackBar 仍然留着：用户把弹层关掉之后它才露出来，
                      // 且与本页其它写操作（启用/禁用、保存、排序）的失败提示保持一致。
                      AppSnack.error(context, message);
                    }
                  },
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                  child: const Text('创建'),
                ),
              ],
            ),
          );
        },
      ),
    ).then((_) {
      nameC.dispose();
      valueC.dispose();
      remarksC.dispose();
      groupC.dispose();
      nameFocus.dispose();
    });
  }
}

/// 设备做不了系统验证（没设锁屏密码、没硬件）时，用应用锁的密码（优先）或图案验证一次（A6 降级）。
///
/// 直接调应用锁控制器的 unlockWithPassword / unlockWithPattern：输错次数与锁屏共用一套冷却，
/// 不能借这里绕过锁屏的「连续输错过多」限制。成功时它顺带执行一次 unlockSession，
/// 能走到这里说明应用本来就没锁着，没有副作用。
///
/// 做成 StatefulWidget 而不是 showDialog 里的 StatefulBuilder：输入框控制器得活到弹窗退场动画结束，
/// 在 showDialog 返回后立刻 dispose 会在退场的那几帧里报「控制器已销毁」。
class _AppLockVerifyDialog extends StatefulWidget {
  const _AppLockVerifyDialog({
    required this.usePassword,
    required this.controller,
  });

  final bool usePassword;
  final AppLockController controller;

  @override
  State<_AppLockVerifyDialog> createState() => _AppLockVerifyDialogState();
}

class _AppLockVerifyDialogState extends State<_AppLockVerifyDialog> {
  final _passwordC = TextEditingController();
  List<int> _pattern = const [];
  String? _error;
  bool _submitting = false;

  @override
  void dispose() {
    _passwordC.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) {
      return;
    }
    final usePassword = widget.usePassword;
    if (usePassword && _passwordC.text.trim().isEmpty) {
      setState(() => _error = '请输入应用锁密码');
      return;
    }
    if (!usePassword && _pattern.length < 4) {
      setState(() => _error = '请至少选择 4 个点');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    final passed = usePassword
        ? await widget.controller.unlockWithPassword(_passwordC.text.trim())
        : await widget.controller.unlockWithPattern(_pattern);
    if (!mounted) {
      return;
    }
    if (passed) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _submitting = false;
      _error =
          widget.controller.getUnlockNotice() ??
          (usePassword ? '密码不正确' : '图案不正确');
      _pattern = const [];
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final usePassword = widget.usePassword;
    return AlertDialog(
      title: const Text('验证身份'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '这台设备没有可用的指纹、面容或锁屏密码，'
              '请用应用锁的${usePassword ? '密码' : '图案'}验证后查看变量值。',
              style: AppText.caption.copyWith(color: palette.text2),
            ),
            const SizedBox(height: AppSpacing.md),
            if (usePassword)
              TextField(
                controller: _passwordC,
                obscureText: true,
                autofocus: true,
                enabled: !_submitting,
                onSubmitted: (_) => _submit(),
                decoration: const InputDecoration(
                  labelText: '应用锁密码',
                  prefixIcon: Icon(Icons.password_outlined),
                ),
              )
            else
              PatternPad(
                selectedPoints: _pattern,
                onPointTap: (point) {
                  if (_pattern.contains(point)) {
                    return;
                  }
                  setState(() {
                    _pattern = [..._pattern, point];
                    _error = null;
                  });
                },
                onClear: () => setState(() => _pattern = const []),
                onBackspace: () => setState(() {
                  if (_pattern.isNotEmpty) {
                    _pattern = _pattern.sublist(0, _pattern.length - 1);
                  }
                }),
                title: '图案验证',
                subtitle: '按顺序点击已设置的图案点位',
              ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.md),
              AppNotice(
                color: palette.err,
                icon: Icons.error_outline,
                text: _error!,
                accentText: true,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting
              ? null
              : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: Text(_submitting ? '验证中…' : '验证'),
        ),
      ],
    );
  }
}

class _EnvValueSheetEditor extends StatelessWidget {
  final String title;
  final TextEditingController controller;
  final VoidCallback onDone;

  const _EnvValueSheetEditor({
    required this.title,
    required this.controller,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final screenHeight = MediaQuery.of(context).size.height;
    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    final editorHeight = (screenHeight - keyboardHeight - 72)
        .clamp(420.0, screenHeight * 0.88)
        .toDouble();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          return;
        }
        // 系统返回键只退出大输入区，不直接关闭整个新建/编辑弹窗。
        onDone();
      },
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, keyboardHeight + 16),
          child: SizedBox(
            height: editorHeight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    AppIconTile(icon: Icons.open_in_full, color: palette.accent),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '回到表单',
                      onPressed: onDone,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '这里直接编辑原表单里的值，点完成后会回到新建/编辑窗口，不会丢输入。',
                  style: TextStyle(fontSize: 12, color: palette.text2),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: TextField(
                    controller: controller,
                    autofocus: true,
                    expands: true,
                    maxLines: null,
                    minLines: null,
                    keyboardType: TextInputType.multiline,
                    textAlignVertical: TextAlignVertical.top,
                    decoration: InputDecoration(
                      hintText: '在这里编辑完整变量值',
                      alignLabelWithHint: true,
                      filled: true,
                      fillColor: palette.fill,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          controller.clear();
                        },
                        icon: const Icon(Icons.cleaning_services, size: 16),
                        label: const Text('清空'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: palette.text2,
                          minimumSize: const Size(0, 44),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        // 不再新开路由，直接收起大输入区，因此原表单控制器会立即保留当前文本。
                        onPressed: onDone,
                        icon: const Icon(Icons.check, size: 18),
                        label: const Text('完成，回到表单'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 44),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _formatTransferSize(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  final kb = bytes / 1024;
  if (kb < 1024) {
    return '${kb.toStringAsFixed(1)} KB';
  }
  return '${(kb / 1024).toStringAsFixed(2)} MB';
}

/// 提示里只列前几条，剩下的折成「等 N 项」。全列出来会把弹层撑爆。
String _joinIdentityPreview(List<String> values, {int limit = 3}) {
  if (values.length <= limit) {
    return values.join('、');
  }
  return '${values.take(limit).join('、')} 等 ${values.length} 项';
}

/// 导出弹层。
///
/// 三个刻意的选择：
/// 1. **不做脱敏**。环境变量里全是 Cookie / Token，遮掉就导不回去了 ——
///    导出的全部意义就是「改完再导进来」。所以只警告，不改内容。
/// 2. **不提供 shell / js / python**（面板 `POST /envs/export-files` 那三种）。
///    它们把同名多条合并成一行、丢掉备注和分组，而且面板没有对应的导入口，
///    放在「导出改完再导入」的入口里只会诱导用户走进死路。
/// 3. 拿不到数据时**报错，不回落到本地列表** —— 见 EnvListNotifier.exportAll。
class _EnvExportSheet extends StatefulWidget {
  final List<int> selectedIds;
  final Future<List<EnvTransferItem>> Function(List<int>? ids) loadItems;

  const _EnvExportSheet({required this.selectedIds, required this.loadItems});

  @override
  State<_EnvExportSheet> createState() => _EnvExportSheetState();
}

class _EnvExportSheetState extends State<_EnvExportSheet> {
  bool _selectedOnly = false;
  bool _loading = true;
  String? _error;
  String _content = '';
  int _count = 0;
  int _bytes = 0;

  @override
  void initState() {
    super.initState();
    _selectedOnly = widget.selectedIds.isNotEmpty;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final items = await widget.loadItems(
        _selectedOnly ? widget.selectedIds : null,
      );
      if (!mounted) {
        return;
      }
      final content = encodeEnvTransferJson(items);
      setState(() {
        _content = content;
        _count = items.length;
        _bytes = utf8.encode(content).length;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = extractErrorMessage(error, '导出环境变量失败');
        _content = '';
        _count = 0;
        _bytes = 0;
        _loading = false;
      });
    }
  }

  void _setSelectedOnly(bool value) {
    if (_selectedOnly == value) {
      return;
    }
    setState(() => _selectedOnly = value);
    _load();
  }

  String _suggestedFileName() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return 'envs-${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}${two(now.second)}.json';
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: _content));
    AppSnack.success(context, '已复制 $_count 条环境变量到剪贴板');
  }

  Future<void> _save() async {
    try {
      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: '保存环境变量',
        fileName: _suggestedFileName(),
        type: FileType.any,
        // utf8.encode 在当前 SDK 返回的就是 Uint8List，不用再包一层 fromList
        // （包了就得 import dart:typed_data，而那会变成一条 unused_import 风险）。
        bytes: utf8.encode(_content),
      );
      if (!mounted) {
        return;
      }
      if (savedPath == null) {
        // 用户自己按了取消，不是失败，保持中性。
        AppSnack.show(context, '已取消保存');
        return;
      }
      AppSnack.success(context, '已保存 $_count 条环境变量');
    } on UnsupportedError {
      if (!mounted) {
        return;
      }
      AppSnack.warn(context, '当前平台暂不支持直接保存文件');
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppSnack.error(context, extractErrorMessage(error, '保存文件失败'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final canExport = !_loading && _error == null && _count > 0;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.xl,
        0,
        AppSpacing.xl,
        MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '导出环境变量',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: AppSpacing.md),
          AppNotice(
            color: palette.warn,
            icon: Icons.warning_amber_rounded,
            text:
                '导出内容是 Cookie / Token 的明文。复制到剪贴板后其他应用可能读到，'
                '存成文件也别放进网盘或聊天记录 —— 用完请及时清理。',
          ),
          if (widget.selectedIds.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.sm,
              children: [
                ChoiceChip(
                  label: Text('已选 ${widget.selectedIds.length} 项'),
                  selected: _selectedOnly,
                  onSelected: (value) {
                    if (value) {
                      _setSelectedOnly(true);
                    }
                  },
                ),
                ChoiceChip(
                  label: const Text('全部变量'),
                  selected: !_selectedOnly,
                  onSelected: (value) {
                    if (value) {
                      _setSelectedOnly(false);
                    }
                  },
                ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            AppNotice(
              color: palette.err,
              icon: Icons.error_outline,
              text: _error!,
              accentText: true,
            )
          else
            AppCard(
              radius: AppRadius.md,
              color: palette.card2,
              borderColor: palette.separator,
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '共 $_count 条 · ${_formatTransferSize(_bytes)}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xxs),
                  Text(
                    '格式与面板「导出 JSON」完全一致：同名多条各占一行（多账号不会被压平），'
                    '备注、分组、启用状态一并带上，可原样导回本 APP 或面板 Web。',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: palette.text2,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.lg),
          if (_error != null)
            OutlinedButton.icon(
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重试'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 44),
              ),
            )
          else
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: canExport ? _save : null,
                    icon: const Icon(Icons.save_alt, size: 16),
                    label: const Text('保存为文件'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 44),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: canExport ? _copy : null,
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('复制'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 44),
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// 导入弹层。
///
/// 只提供面板已有的两种模式（合并 / 替换），不自己拼第三种 —— 理由见 [EnvImportMode]。
///
/// 提交前做一次本地体检（[analyzeEnvImport]），其中**合并模式下会压平多账号**
/// 这一条是硬拦：面板 `POST /envs/import` 的 merge 没有 `PUT /envs/by-name` 那道
/// 「同名多条直接报 409」的守卫，放过去就是无声的数据损坏。
class _EnvImportSheet extends StatefulWidget {
  final List<EnvTransferItem> existing;
  final Future<EnvImportOutcome> Function(
    List<EnvTransferItem> items,
    EnvImportMode mode,
  )
  submit;

  /// 替换导入确认框末尾追加的一句「重要变量也会被清空」（APP #16 ②）；
  /// null = 不追加（老面板 / 面板上没有重要变量）。怎么算的见 `_showImportSheet`。
  final String? importantNotice;

  const _EnvImportSheet({
    required this.existing,
    required this.submit,
    this.importantNotice,
  });

  @override
  State<_EnvImportSheet> createState() => _EnvImportSheetState();
}

class _EnvImportSheetState extends State<_EnvImportSheet> {
  final _textController = TextEditingController();
  Timer? _debounce;

  EnvImportMode _mode = EnvImportMode.merge;
  EnvTransferParseResult _parsed = const EnvTransferParseResult();
  EnvImportPreflight? _preflight;
  bool _submitting = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _textController.dispose();
    super.dispose();
  }

  /// 边打字边整份 jsonDecode 会卡（粘一份 1MB 的进来更明显），沿用列表页搜索框的防抖。
  void _scheduleAnalyze() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _analyze);
  }

  void _analyze() {
    if (!mounted) {
      return;
    }
    final raw = _textController.text.trim();
    if (raw.isEmpty) {
      // 空白不算「格式错误」，别一进来就给用户一条红提示。
      setState(() {
        _parsed = const EnvTransferParseResult();
        _preflight = null;
      });
      return;
    }

    final parsed = parseEnvTransferJson(raw);
    setState(() {
      _parsed = parsed;
      _preflight = parsed.ok
          ? analyzeEnvImport(
              items: parsed.items,
              existing: widget.existing,
              mode: _mode,
            )
          : null;
    });
  }

  void _setMode(EnvImportMode mode) {
    if (_mode == mode) {
      return;
    }
    setState(() => _mode = mode);
    // 体检结果与模式强相关（压平 / 已存在多条只在 merge 下成立），必须重算。
    _analyze();
  }

  Future<void> _pickFile() async {
    try {
      // 不限制扩展名：Android 的文档选择器对 .json/.txt 的 MIME 映射各家实现不一，
      // 限了反而会出现「文件就在那儿但是灰的」。
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        withData: true,
      );
      if (!mounted) {
        return;
      }
      if (result == null || result.files.isEmpty) {
        // 用户自己取消了，不提示。
        return;
      }

      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) {
        AppSnack.error(context, '读取文件失败或文件为空');
        return;
      }

      _textController.text = utf8.decode(bytes, allowMalformed: true);
      _analyze();
      AppSnack.show(context, '已载入 ${file.name}');
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppSnack.error(context, extractErrorMessage(error, '选择文件失败'));
    }
  }

  Future<bool> _confirmReplace(int total) async {
    final importantNotice = widget.importantNotice;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('替换导入'),
        // 重要变量也在「全部」里，替换照样会清空它们（服务端不拦）——点名提醒一句。
        // 合并导入不加：面板对 important 只升不降，合并不会取消任何标记。
        content: Text(
          '替换会先删除面板上的全部环境变量，再写入这 $total 条。\n'
          '面板上有、而这份内容里没有的变量将无法找回。'
          '${importantNotice == null ? '' : '\n$importantNotice'}',
        ),
        actions: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(dialogCtx).pop(false),
                    child: const Text('取消'),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: FilledButton(
                    onPressed: () => Navigator.of(dialogCtx).pop(true),
                    style: FilledButton.styleFrom(
                      backgroundColor: dialogCtx.palette.err,
                    ),
                    child: const Text('清空并导入'),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );

    return confirmed == true;
  }

  Future<void> _submit() async {
    final preflight = _preflight;
    if (_submitting || preflight == null || preflight.blocked) {
      return;
    }

    if (_mode == EnvImportMode.replace) {
      final confirmed = await _confirmReplace(preflight.total);
      if (!mounted) {
        return;
      }
      if (!confirmed) {
        return;
      }
    }

    final navigator = Navigator.of(context);
    setState(() => _submitting = true);

    try {
      final outcome = await widget.submit(_parsed.items, _mode);
      if (!mounted) {
        return;
      }
      // 先弹提示再关弹层：提示挂在根 ScaffoldMessenger 上，弹层关掉它照样在；
      // 反过来先 pop 的话，这里的 context 已经失效，AppSnack 会静默什么都不做。
      if (outcome.errors.isEmpty) {
        AppSnack.success(context, outcome.message);
      } else {
        AppSnack.warn(
          context,
          '${outcome.message}；${outcome.errors.length} 条被跳过：'
          '${outcome.errors.first}',
        );
      }
      navigator.pop();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _submitting = false);
      AppSnack.error(context, extractErrorMessage(error, '导入环境变量失败'));
    }
  }

  List<Widget> _buildCheckWidgets(AppPalette palette) {
    final parseError = _parsed.error;
    if (parseError != null) {
      return [
        AppNotice(
          color: palette.err,
          icon: Icons.error_outline,
          text: parseError,
          accentText: true,
        ),
      ];
    }

    final preflight = _preflight;
    if (preflight == null) {
      return [
        AppNotice(
          color: palette.accent,
          icon: Icons.info_outline,
          text:
              '粘贴「导出变量」得到的 JSON，或从文件载入。格式与面板 Web 的「导出 JSON / 导入」一致，'
              '两边可以互导。',
        ),
      ];
    }

    final widgets = <Widget>[
      AppCard(
        radius: AppRadius.md,
        color: palette.card2,
        borderColor: palette.separator,
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Text(
          '解析出 ${preflight.total} 条 · ${_formatTransferSize(preflight.payloadBytes)}',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
      ),
    ];

    if (_parsed.skipped > 0) {
      widgets.add(
        AppNotice(
          color: palette.warn,
          icon: Icons.warning_amber_rounded,
          text: '有 ${_parsed.skipped} 项不是对象，已跳过。',
          accentText: true,
        ),
      );
    }

    if (preflight.oversized) {
      widgets.add(
        AppNotice(
          color: palette.err,
          icon: Icons.error_outline,
          text:
              '内容 ${_formatTransferSize(preflight.payloadBytes)} '
              '超过面板 1MB 的请求体上限，请分批导入。',
          accentText: true,
        ),
      );
    }

    if (preflight.collapsedIdentities.isNotEmpty) {
      widgets.add(
        AppNotice(
          color: palette.err,
          icon: Icons.error_outline,
          text:
              '合并模式按「变量名 + 备注」认领记录，'
              '${_joinIdentityPreview(preflight.collapsedIdentities)} '
              '在这份内容里出现了多次，导入后只会剩一条 —— 多账号会被压平。'
              '请改用「替换」，或给它们填上不同的备注。',
          accentText: true,
        ),
      );
    }

    if (preflight.ambiguousIdentities.isNotEmpty) {
      widgets.add(
        AppNotice(
          color: palette.warn,
          icon: Icons.warning_amber_rounded,
          text:
              '面板上已有多条同名同备注的记录（'
              '${_joinIdentityPreview(preflight.ambiguousIdentities)}），'
              '合并只会更新其中一条，其余保持原样。',
          accentText: true,
        ),
      );
    }

    if (preflight.invalidNames.isNotEmpty) {
      widgets.add(
        AppNotice(
          color: palette.warn,
          icon: Icons.warning_amber_rounded,
          text:
              '这些变量名不符合面板规则（只能字母或下划线开头，后接字母数字下划线），'
              '面板会跳过它们：${_joinIdentityPreview(preflight.invalidNames)}。',
          accentText: true,
        ),
      );
    }

    if (_mode == EnvImportMode.replace) {
      widgets.add(
        AppNotice(
          color: palette.err,
          icon: Icons.delete_forever,
          text: '替换会先清空面板上的全部环境变量，再写入上面这些。这一步不可撤销。',
          accentText: true,
        ),
      );
    }

    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final media = MediaQuery.of(context);
    final preflight = _preflight;
    final canSubmit =
        !_submitting && preflight != null && !preflight.blocked;

    final checkWidgets = _buildCheckWidgets(palette);

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: media.size.height * 0.86),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.xl,
          0,
          AppSpacing.xl,
          media.viewInsets.bottom + AppSpacing.xl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '导入环境变量',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: AppSpacing.md),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: AppSpacing.sm,
                      children: [
                        ChoiceChip(
                          label: const Text('合并'),
                          selected: _mode == EnvImportMode.merge,
                          onSelected: (value) {
                            if (value) {
                              _setMode(EnvImportMode.merge);
                            }
                          },
                        ),
                        ChoiceChip(
                          label: const Text('替换'),
                          selected: _mode == EnvImportMode.replace,
                          onSelected: (value) {
                            if (value) {
                              _setMode(EnvImportMode.replace);
                            }
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      _mode == EnvImportMode.merge
                          ? '合并：按「变量名 + 备注」认领面板上已有的记录，命中就更新值 / 分组 / 启用状态，'
                                '没命中就新增。不会删除这份内容里没有的变量。'
                          : '替换：先清空面板上的全部环境变量，再按顺序全量写入。同名多条会原样保留。',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: palette.text2,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextField(
                      controller: _textController,
                      maxLines: 8,
                      minLines: 4,
                      keyboardType: TextInputType.multiline,
                      textAlignVertical: TextAlignVertical.top,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'JSON 内容',
                        alignLabelWithHint: true,
                        hintText:
                            '[{"name": "JD_COOKIE", "value": "pt_key=...", '
                            '"remarks": "账号1", "groups": ["京东"], "enabled": true}]',
                        hintMaxLines: 3,
                      ),
                      onChanged: (_) => _scheduleAnalyze(),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    // 不要把循环变量取名 widget —— 那会遮住 State.widget。
                    for (final notice in checkWidgets) ...[
                      notice,
                      const SizedBox(height: AppSpacing.sm),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _submitting ? null : _pickFile,
                    icon: const Icon(Icons.folder_open, size: 16),
                    label: const Text('选择文件'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 44),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: canSubmit ? _submit : null,
                    icon: const Icon(Icons.file_download_done, size: 16),
                    label: Text(_submitting ? '导入中…' : '导入'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 44),
                      backgroundColor: _mode == EnvImportMode.replace
                          ? palette.err
                          : null,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 变量列表里的一行（v2.0 分组列表）。
///
/// 外观对齐 `AppGroupedRow`：左右内边距 18、36dp 的 [AppIconTile]、缩进到文字起点的发丝分隔线；
/// 一组的第一行带上圆角、最后一行带下圆角（[first] / [last]），连起来就是一张白色大圆角卡片。
/// 不直接用 `AppGroupedRow`：它的标题只能是一段字（这里要跟图钉和「重要」标记），
/// 也没有左滑露出启用 / 删除 / 禁用；而且页面要懒加载（最多 5000 条），不能整组包进 `AppGroupedList`。
class _EnvCard extends StatefulWidget {
  final EnvVar env;
  final bool first;
  final bool last;

  /// 值要不要遮住（敏感变量、还没揭开）。遮住时右侧是「查看」，否则是「复制」。
  final bool masked;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onSelectedChanged;
  final VoidCallback onReveal;
  final VoidCallback onCopy;
  final VoidCallback onEnable;
  final VoidCallback onDisable;
  final VoidCallback onDelete;

  const _EnvCard({
    super.key,
    required this.env,
    required this.first,
    required this.last,
    required this.masked,
    required this.selectionMode,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onSelectedChanged,
    required this.onReveal,
    required this.onCopy,
    required this.onEnable,
    required this.onDisable,
    required this.onDelete,
  });

  @override
  State<_EnvCard> createState() => _EnvCardState();
}

class _EnvCardState extends State<_EnvCard> {
  static const double _actionWidth = 64;
  static const double _actionGap = 6;

  /// 三个按钮 + 两道间隔 + 左右各 8 的留白。
  static const double _actionsWidth = _actionWidth * 3 + _actionGap * 2 + 16;

  /// 与 AppGroupedRow 同一套尺寸：分隔线从文字起点画起。
  static const double _hPad = 18;
  static const double _leadingSize = 36;
  static const double _leadingGap = 14;

  double _dragOffset = 0;
  bool _dragging = false;

  /// 按下时整行变灰（主题去掉了水波纹，同 AppGroupedRow 的按压反馈）。
  bool _pressed = false;

  @override
  void didUpdateWidget(covariant _EnvCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectionMode || oldWidget.env.id != widget.env.id) {
      _dragOffset = 0;
      _dragging = false;
    }
  }

  void _closeActions() {
    if (_dragOffset == 0) {
      return;
    }
    setState(() => _dragOffset = 0);
  }

  void _runSwipeAction(VoidCallback action) {
    _closeActions();
    action();
  }

  void _setPressed(bool value) {
    if (_pressed != value) {
      setState(() => _pressed = value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final env = widget.env;
    const radius = Radius.circular(AppRadius.card);
    // 多选时文字起点右移了一个复选框的宽度，分隔线跟着缩进。
    final textStart =
        _hPad +
        (widget.selectionMode ? 34 : 0) +
        _leadingSize +
        _leadingGap;
    // 选中 = 强调色淡底；按下 = 灰色填充；都叠在卡片白底上（淡底本身是半透明的）。
    final rowColor = widget.selected
        ? Color.alphaBlend(palette.tint(palette.accent), palette.card)
        : _pressed
        ? Color.alphaBlend(palette.fill, palette.card)
        : palette.card;

    return PopScope(
      canPop: _dragOffset == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _dragOffset == 0) {
          return;
        }
        // 侧滑按钮展开时，系统返回先收起按钮，避免用户回滑时误退出 APP。
        _closeActions();
      },
      child: ClipRRect(
        borderRadius: BorderRadius.vertical(
          top: widget.first ? radius : Radius.zero,
          bottom: widget.last ? radius : Radius.zero,
        ),
        child: ColoredBox(
          color: palette.card,
          child: Stack(
            children: [
              // 左滑露出的操作按钮，垫在这一行的下面。
              Positioned.fill(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _SwipeActionButton(
                          label: '启用',
                          icon: Icons.play_arrow_rounded,
                          color: palette.ok,
                          ink: palette.okInk,
                          enabled: !env.enabled,
                          onTap: () => _runSwipeAction(widget.onEnable),
                        ),
                        const SizedBox(width: _actionGap),
                        _SwipeActionButton(
                          label: '删除',
                          icon: Icons.delete_outline,
                          color: palette.err,
                          ink: palette.errInk,
                          enabled: true,
                          onTap: () => _runSwipeAction(widget.onDelete),
                        ),
                        const SizedBox(width: _actionGap),
                        _SwipeActionButton(
                          label: '禁用',
                          icon: Icons.pause_rounded,
                          color: palette.text2,
                          ink: palette.text2,
                          enabled: env.enabled,
                          onTap: () => _runSwipeAction(widget.onDisable),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              GestureDetector(
                onTap: () {
                  if (_dragOffset != 0) {
                    _closeActions();
                    return;
                  }
                  widget.onTap();
                },
                onTapDown: (_) => _setPressed(true),
                onTapUp: (_) => _setPressed(false),
                onTapCancel: () => _setPressed(false),
                onLongPress: widget.onLongPress,
                onHorizontalDragStart: widget.selectionMode
                    ? null
                    : (_) => setState(() => _dragging = true),
                onHorizontalDragUpdate: widget.selectionMode
                    ? null
                    : (details) {
                        // 左滑露出右侧操作按钮；关闭时也限制在行内处理，避免和系统返回手势抢动作。
                        final nextOffset = (_dragOffset + details.delta.dx)
                            .clamp(-_actionsWidth, 0.0)
                            .toDouble();
                        if (nextOffset == _dragOffset) {
                          return;
                        }
                        setState(() => _dragOffset = nextOffset);
                      },
                onHorizontalDragCancel: widget.selectionMode
                    ? null
                    : () => setState(() => _dragging = false),
                onHorizontalDragEnd: widget.selectionMode
                    ? null
                    : (_) {
                        final nextOffset =
                            _dragOffset.abs() > _actionsWidth * 0.42
                            ? -_actionsWidth
                            : 0.0;
                        setState(() {
                          _dragging = false;
                          _dragOffset = nextOffset;
                        });
                        if (nextOffset == -_actionsWidth) {
                          HapticFeedback.selectionClick();
                        }
                      },
                child: AnimatedContainer(
                  duration: _dragging
                      ? Duration.zero
                      : AppMotion.of(context, const Duration(milliseconds: 160)),
                  curve: Curves.easeOutCubic,
                  transform: Matrix4.translationValues(_dragOffset, 0, 0),
                  color: rowColor,
                  child: CustomPaint(
                    // 顶部发丝分隔线：组内第一行不画，从文字起点画到最右边。
                    foregroundPainter: widget.first
                        ? null
                        : _EnvRowSeparatorPainter(
                            color: palette.separator,
                            start: textStart,
                          ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(_hPad, 12, 10, 12),
                      // 已禁用的变量整行变淡（演示稿：已禁用单独一组、变淡）。
                      child: Opacity(
                        opacity: env.enabled ? 1 : 0.55,
                        child: Row(
                          children: [
                            if (widget.selectionMode) ...[
                              SizedBox(
                                width: 24,
                                height: 24,
                                child: Checkbox(
                                  value: widget.selected,
                                  onChanged: (_) => widget.onSelectedChanged(),
                                  activeColor: palette.accent,
                                  visualDensity: VisualDensity.compact,
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                              ),
                              const SizedBox(width: 10),
                            ],
                            // 置顶 = 橙（同图钉），已禁用 = 紫（演示稿），其余 = 蓝。
                            AppIconTile(
                              icon: Icons.key_rounded,
                              color: env.isPinned
                                  ? palette.warn
                                  : (env.enabled
                                        ? palette.accent
                                        : palette.purple),
                            ),
                            const SizedBox(width: _leadingGap),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // 置顶图钉与「重要」标记紧跟名字（APP #16）。名字放 Flexible：
                                  // 名字长时名字先省略，标记不会被挤掉。
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          env.name,
                                          style: TextStyle(
                                            fontFamily: 'monospace',
                                            fontSize: 15,
                                            fontWeight: FontWeight.w700,
                                            color: palette.text,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      if (env.isPinned) ...[
                                        const SizedBox(width: 4),
                                        Icon(
                                          Icons.push_pin,
                                          size: 14,
                                          color: palette.warn,
                                          semanticLabel: '已置顶',
                                        ),
                                      ],
                                      if (env.isImportant) ...[
                                        const SizedBox(width: 4),
                                        const _EnvImportantBadge(),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  // A6：敏感值默认遮住，只显示定长遮罩（猜不出原值长度）。
                                  Text(
                                    widget.masked
                                        ? maskEnvValue(env.value)
                                        : env.value.replaceAll('\n', ' '),
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontFamily: 'monospace',
                                      letterSpacing: widget.masked ? 1.2 : 0,
                                      color: palette.text2,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  // 备注与「更新于」同一行（APP #27）：备注占左边剩余宽度、长了照常省略，
                                  // 时间靠右不折行，行不因为多了时间而变高。没有备注时这一行只剩时间。
                                  // updated_at 在面板改值 / 启用 / 禁用时都会刷新，用户靠它看「什么时候动过」。
                                  // 分组列表的行比旧卡片多了前导图标，窄屏 + 大字号时一行放不下
                                  // 「时间 + 几个字的备注」：这时时间换到备注下面一行，整句照常显示。
                                  const SizedBox(height: 2),
                                  LayoutBuilder(
                                    builder: (context, constraints) {
                                      final timeText =
                                          '更新于 ${formatTimeCn(env.updatedAt, short: true)}';
                                      final timeStyle = AppText.tabular(
                                        TextStyle(
                                          fontSize: 12,
                                          color: palette.text2,
                                        ),
                                      );
                                      final remarks = env.remarks.isNotEmpty
                                          ? Text(
                                              env.remarks,
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: palette.text2,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            )
                                          : null;
                                      final time = Text(
                                        timeText,
                                        style: timeStyle,
                                        maxLines: 1,
                                      );
                                      // 有备注时至少给备注留 56（约 4 个字）。
                                      final oneLine =
                                          measureTextWidth(
                                                context,
                                                timeText,
                                                timeStyle,
                                              ) +
                                              8 +
                                              (remarks == null ? 0 : 56) <=
                                          constraints.maxWidth;
                                      if (oneLine) {
                                        return Row(
                                          children: [
                                            Expanded(
                                              child:
                                                  remarks ??
                                                  const SizedBox.shrink(),
                                            ),
                                            const SizedBox(width: 8),
                                            time,
                                          ],
                                        );
                                      }
                                      return Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          ?remarks,
                                          // 极窄时连单独一行都放不下：整体缩小，不截断、不溢出。
                                          FittedBox(
                                            fit: BoxFit.scaleDown,
                                            alignment: Alignment.centerLeft,
                                            child: time,
                                          ),
                                        ],
                                      );
                                    },
                                  ),
                                ],
                              ),
                            ),
                            if (!widget.selectionMode) ...[
                              const SizedBox(width: 4),
                              // 遮住时是「查看」（验证后揭开），否则是「复制」（敏感值同样先验证）。
                              IconButton(
                                tooltip: widget.masked ? '查看' : '复制',
                                onPressed: widget.masked
                                    ? widget.onReveal
                                    : widget.onCopy,
                                visualDensity: VisualDensity.compact,
                                icon: Icon(
                                  widget.masked
                                      ? Icons.visibility_outlined
                                      : Icons.copy_rounded,
                                  size: 20,
                                  color: palette.accent,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 行顶部的缩进分隔线（同 AppGroupedRow 的画法：0.5 宽、从文字起点画到最右边）。
class _EnvRowSeparatorPainter extends CustomPainter {
  final Color color;
  final double start;

  const _EnvRowSeparatorPainter({required this.color, required this.start});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 0.5;
    canvas.drawLine(Offset(start, 0.25), Offset(size.width, 0.25), paint);
  }

  @override
  bool shouldRepaint(_EnvRowSeparatorPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.start != start;
}

/// 「重要」标记（APP #16 ②），列表行与排序卡共用。
///
/// 紫色是变量页没给别的语义用过的颜色（红 = 删除，橙 = 置顶，蓝 = 可点的图标），
/// 颜色之外还有锁图标和「重要」二字，不只靠颜色区分。
class _EnvImportantBadge extends StatelessWidget {
  const _EnvImportantBadge();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    // 淡底上放字，用墨色。
    final foreground = palette.purpleInk;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: palette.tint(palette.purple),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_outline, size: 11, color: foreground),
          const SizedBox(width: 2),
          Text(
            '重要',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: foreground,
            ),
          ),
        ],
      ),
    );
  }
}

class _SwipeActionButton extends StatelessWidget {
  final String label;
  final IconData icon;

  /// 淡底用的实色。
  final Color color;

  /// 淡底上的图标和文字用墨色（浅色模式下实色当字不够看）。
  final Color ink;
  final bool enabled;
  final VoidCallback onTap;

  const _SwipeActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.ink,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final backgroundColor = enabled ? palette.tint(color) : palette.fill;
    final foregroundColor = enabled ? ink : palette.text3;

    return SizedBox(
      width: _EnvCardState._actionWidth,
      child: Material(
        color: backgroundColor,
        // 左滑露出的操作按钮，走按钮档；底板与按压反馈必须同值。
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: foregroundColor),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: foregroundColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
