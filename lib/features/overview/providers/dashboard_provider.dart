import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/api/panel_insights.dart';
import '../../../shared/models/insights.dart';
import '../../../shared/models/task.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/utils/panel_enums.dart';

// v2.0 起这份 provider 服务「概览」Tab（原 v1.x 的「主页」）。
// 类名 / provider 名沿用 Dashboard*：登录页、开屏页、切换面板时的 invalidate
// 都按这个名字引用它，改名会牵动一串与概览无关的文件。

/// 概览请求的趋势天数。面板 v2.1.4 起支持 `?range=`（1~90），更老的面板忽略参数、照旧给 7 天，
/// 页面按实际拿到的天数显示，不假设一定是 30。
const int kOverviewTrendDays = 30;

/// 「最慢的任务」最多看多少个任务：面板任务列表一页上限 100，`recent-runs` 一次也最多 100 个 id。
const int _slowestTaskScan = 100;

/// 「最慢的任务」按最近几次已结束执行取平均。
const int _slowestRecentRuns = 10;

const _unset = Object();

String _formatBytes(dynamic bytes) {
  if (bytes == null) {
    return '-';
  }
  final b = (bytes as num).toDouble();
  if (b < 1024) return '${b.toStringAsFixed(0)}B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)}KB';
  if (b < 1024 * 1024 * 1024) {
    return '${(b / 1024 / 1024).toStringAsFixed(1)}MB';
  }
  return '${(b / 1024 / 1024 / 1024).toStringAsFixed(1)}GB';
}

bool _resourceUnavailable(dynamic total) {
  if (total == null) return true;
  if (total is num) return total <= 0;
  return false;
}

/// 「最慢的任务」卡的数据。
class SlowestTask {
  final int id;
  final String name;

  /// 耗时（秒）。
  final double seconds;

  /// true：最近 [_slowestRecentRuns] 次已结束执行的平均（v4.0 面板）；
  /// false：任务上记的「最近一次耗时」`last_running_time`（老面板兜底）。
  final bool isAverage;

  /// 算的时候拉到的那条任务本身：点卡片直接拿它弹详情，不用再按 id 找。
  final Task? task;

  const SlowestTask({
    required this.id,
    required this.name,
    required this.seconds,
    required this.isAverage,
    this.task,
  });
}

class DashboardData {
  final Map<String, dynamic> system;
  final Map<String, dynamic> dashboard;

  /// v4.0「需要关注」清单。null：老面板没有这条接口，或这次没拿到 —— 「最常失败」卡隐藏。
  final List<AttentionItem>? attention;

  /// 最慢的任务。null：算不出来（没有任务 / 都没有耗时记录 / 任务列表没拿到）—— 卡片隐藏。
  final SlowestTask? slowest;

  /// 算「最慢的任务」时顺带拉到的任务（任务列表第一页）。
  /// 「最常失败」卡只有任务 id，点它时先在这里找，找不到才去面板上取。
  final List<Task> scannedTasks;

  final bool loading;
  final String? error;

  const DashboardData({
    this.system = const {},
    this.dashboard = const {},
    this.attention,
    this.slowest,
    this.scannedTasks = const [],
    this.loading = false,
    this.error,
  });

  // 系统资源
  double get cpuUsage => (system['cpu_usage'] as num?)?.toDouble() ?? 0;
  double get memoryUsage => (system['memory_usage'] as num?)?.toDouble() ?? 0;
  double get diskUsage => (system['disk_usage'] as num?)?.toDouble() ?? 0;
  bool get memoryUnavailable => _resourceUnavailable(system['memory_total']);
  String get memoryTotal => _formatBytes(system['memory_total']);
  String get memoryUsed => _formatBytes(system['memory_used']);
  String get diskTotal => _formatBytes(system['disk_total']);
  String get diskUsed => _formatBytes(system['disk_used']);
  String get uptime => system['uptime']?.toString() ?? '-';
  String get hostname => system['hostname']?.toString() ?? '-';
  String get os => system['os']?.toString() ?? '-';
  String get panelTitle => system['panel_title']?.toString() ?? '';
  String get panelVersion => system['panel_version']?.toString() ?? '';

  // 仪表盘数据 — 字段名匹配后端实际返回
  int get totalTasks => (dashboard['task_count'] as num?)?.toInt() ?? 0;
  int get enabledTasks => (dashboard['enabled_tasks'] as num?)?.toInt() ?? 0;
  int get runningTasks => (dashboard['running_tasks'] as num?)?.toInt() ?? 0;
  int get disabledTasks => totalTasks - enabledTasks;
  int get todaySuccess => (dashboard['success_logs'] as num?)?.toInt() ?? 0;
  int get todayFailed => (dashboard['failed_logs'] as num?)?.toInt() ?? 0;

  /// 今日主动终止的执行数（面板 `server/handler/system.go`）。
  /// 老面板不返回这个键 → 0。
  int get todayAborted => (dashboard['aborted_logs'] as num?)?.toInt() ?? 0;
  List<dynamic> get recentLogs => dashboard['recent_logs'] as List? ?? [];

  /// 按天的执行统计，旧 → 新，**最后一项是今天**（面板从 range-1 天前循环到今天）。
  /// 每项 `{date: 'MM-DD', success, failed, aborted}`；老面板没有 aborted。
  List<Map<String, dynamic>> get executionTrend =>
      (dashboard['daily_stats'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();

  // ── 总览卡口径：趋势区间（默认近 30 天，含今天）内按天加总 ──────────────
  // 与面板 `Stats` 的成功率同口径：成功 / (成功 + 失败)，「已终止」不进分母，
  // 免得手动停掉的执行把成功率拉低。

  int _sumOf(String key) {
    var total = 0;
    for (final day in executionTrend) {
      total += (day[key] as num?)?.toInt() ?? 0;
    }
    return total;
  }

  int get rangeSuccess => _sumOf('success');
  int get rangeFailed => _sumOf('failed');
  int get rangeAborted => _sumOf('aborted');

  /// 区间内共执行（成功 + 失败 + 已终止）。
  int get rangeRuns => rangeSuccess + rangeFailed + rangeAborted;

  /// 区间成功率（0~100）；区间内没有自然结束的执行时为 null，页面显示「--」而不是编一个 100%。
  double? get rangeSuccessRate {
    final finished = rangeSuccess + rangeFailed;
    if (finished == 0) return null;
    return rangeSuccess / finished * 100;
  }

  /// 「最常失败」：attention 里第一条 `task_failing`（面板已按级别、时间排好）。
  AttentionItem? get topFailing {
    final items = attention;
    if (items == null) return null;
    for (final item in items) {
      if (item.type == 'task_failing') return item;
    }
    return null;
  }

  DashboardData copyWith({
    Map<String, dynamic>? system,
    Map<String, dynamic>? dashboard,
    Object? attention = _unset,
    Object? slowest = _unset,
    List<Task>? scannedTasks,
    bool? loading,
    String? error,
  }) {
    return DashboardData(
      system: system ?? this.system,
      dashboard: dashboard ?? this.dashboard,
      attention: identical(attention, _unset)
          ? this.attention
          : attention as List<AttentionItem>?,
      slowest: identical(slowest, _unset)
          ? this.slowest
          : slowest as SlowestTask?,
      scannedTasks: scannedTasks ?? this.scannedTasks,
      loading: loading ?? this.loading,
      // 故意不用 ??：不传即清空上次的错误（state-management.md）
      error: error,
    );
  }
}

class DashboardNotifier extends StateNotifier<DashboardData> {
  /// [dio] **仅供测试注入**，生产路径不传，仍然走 `DioClient` 单例。
  /// 单例的 baseUrl 会随切换面板被改写，所以这里不在构造时把它存下来。
  DashboardNotifier({Dio? dio})
    : _injectedDio = dio,
      super(const DashboardData());

  final Dio? _injectedDio;

  Dio get _dio => _injectedDio ?? DioClient.instance.dio;

  /// 把「可选接口」的失败吃掉，返回 null。用于只做锦上添花的请求，
  /// 避免它们的 4xx 把主数据一起拖垮。
  Future<dynamic> _optional(Future<dynamic> request) async {
    try {
      final response = await request;
      return extractData(response.data);
    } catch (_) {
      return null;
    }
  }

  /// 正在进行的完整加载个数。轻量预加载看到它 > 0 就不再发请求，
  /// 也不会抢先把 loading 置回 false（概览页这时还在等完整数据）。
  int _fullLoads = 0;

  /// [full] 为 false 时是开屏 / 登录的轻量预加载：只拉 `/system/dashboard`
  /// （桌面小组件的今日成功 / 失败次数靠它）。系统信息、需要关注、最慢任务这些
  /// 额外请求等概览页挂载、调用完整 load 时再拉 —— 默认落点是任务页，开屏没必要一次发 6 组请求。
  Future<void> load({bool full = true}) async {
    if (!full) {
      if (_fullLoads > 0) return;
      state = state.copyWith(loading: true, error: null);
      try {
        final response = await _dio.get(
          ApiEndpoints.dashboard,
          queryParameters: {'range': kOverviewTrendDays},
        );
        final dashData = extractData(response.data);
        state = state.copyWith(
          dashboard: dashData is Map<String, dynamic> ? dashData : {},
          loading: _fullLoads > 0,
        );
      } catch (_) {
        // 预加载失败不报错：概览页挂载时的完整 load 会重拉，失败了由它提示
        state = state.copyWith(loading: _fullLoads > 0);
      }
      return;
    }

    _fullLoads++;
    state = state.copyWith(
      loading: true,
      error: null,
      // 拉取中保留上一轮的数据，下拉刷新时页面不闪空
    );
    try {
      // 所有并发请求共用同一个实例，避免 getter 中途读到被切面板改写的单例。
      final dio = _dio;
      // 主数据：系统信息 + 仪表盘统计，失败就是整页失败。
      final systemFuture = dio.get(ApiEndpoints.systemInfo);
      final dashboardFuture = dio.get(
        ApiEndpoints.dashboard,
        queryParameters: {'range': kOverviewTrendDays},
      );
      // 辅助数据：失败都吃掉、各自降级，不拖垮主数据。
      final panelFuture = _optional(dio.get(ApiEndpoints.panelSettings));
      final versionFuture = _optional(dio.get(ApiEndpoints.systemVersion));
      final attentionFuture = _loadAttention(dio);
      final slowestFuture = _loadSlowest(dio);

      // 两个主请求必须**一起** await：以前是先 await 第一个，它一抛，
      // 第二个 Future 就没人接了，它的失败会冒成未捕获的 DioException。
      // Future.wait 会给每个 Future 都挂上错误处理，等全部结束后再抛第一个错误。
      final main = await Future.wait([systemFuture, dashboardFuture]);
      final sysData = extractData(main[0].data);
      final dashData = extractData(main[1].data);
      final panelData = await panelFuture;
      final versionData = await versionFuture;
      final attention = await attentionFuture;
      final scan = await slowestFuture;

      final sysMap = sysData is Map<String, dynamic>
          ? Map<String, dynamic>.from(sysData)
          : <String, dynamic>{};
      if (panelData is Map) {
        final title = panelData['panel_title']?.toString() ?? '';
        if (title.isNotEmpty) {
          sysMap['panel_title'] = title;
        }
      }
      if (versionData is Map) {
        final version = versionData['version']?.toString() ?? '';
        if (version.isNotEmpty) {
          sysMap['panel_version'] = version;
        }
      }
      state = state.copyWith(
        system: sysMap,
        dashboard: dashData is Map<String, dynamic> ? dashData : {},
        attention: attention,
        slowest: scan.slowest,
        scannedTasks: scan.tasks,
        loading: false,
      );
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: extractErrorMessage(e, '概览加载失败'),
      );
    } finally {
      _fullLoads--;
    }
  }

  /// v4.0「需要关注」。老面板返回 null（探测逻辑在 panel_insights）；
  /// 网络 / 5xx 这类错误也按 null 处理 —— 它只是概览上的一张小卡，不值得让整页失败。
  Future<List<AttentionItem>?> _loadAttention(Dio dio) async {
    try {
      return await fetchAttention(dio: dio);
    } catch (_) {
      return null;
    }
  }

  /// 算「最慢的任务」。任何一步失败都返回 null（卡片隐藏），不影响整页。
  ///
  /// 口径：
  /// 1. 取任务列表第一页（最多 [_slowestTaskScan] 个，面板默认排序）；
  /// 2. v4.0 面板：用 `recent-runs` 取每个任务最近 [_slowestRecentRuns] 次**成功或失败**的执行，
  ///    求平均耗时，取最大者（已终止的执行被中途打断，耗时不代表任务本身，排除）；
  /// 3. 老面板 / recent-runs 没拿到 / 都没有耗时记录：退回任务上的 `last_running_time`
  ///    （最近一次耗时；任务开始运行时面板会把它清 0，所以只看 > 0 的）。
  ///
  /// 顺带把拉到的任务一起返回（[DashboardData.scannedTasks]），给「最常失败」卡按 id 找任务用；
  /// 卡片上的 [SlowestTask.task] 也直接带上那条任务，点卡片时不用再找。
  Future<({SlowestTask? slowest, List<Task> tasks})> _loadSlowest(
    Dio dio,
  ) async {
    var tasks = const <Task>[];
    try {
      final response = await dio.get(
        ApiEndpoints.tasks,
        queryParameters: {'page': 1, 'page_size': _slowestTaskScan},
      );
      tasks = extractPaginated(
        response.data,
      ).items.map(Task.fromJson).toList();
      if (tasks.isEmpty) return (slowest: null, tasks: tasks);

      Map<int, List<RecentRun>>? runs;
      try {
        runs = await fetchRecentRuns(
          tasks.map((t) => t.id).toList(),
          limit: _slowestRecentRuns,
          dio: dio,
        );
      } catch (_) {
        // recent-runs 的网络错误 / 5xx：照样能用 last_running_time 兜底
        runs = null;
      }

      SlowestTask? best;
      if (runs != null) {
        for (final task in tasks) {
          final durations = (runs[task.id] ?? const <RecentRun>[])
              .where(
                (r) =>
                    r.status == kLogStatusSuccess ||
                    r.status == kLogStatusFailed,
              )
              .map((r) => r.duration)
              .whereType<double>()
              .toList();
          if (durations.isEmpty) continue;
          final avg = durations.reduce((a, b) => a + b) / durations.length;
          if (avg > 0 && (best == null || avg > best.seconds)) {
            best = SlowestTask(
              id: task.id,
              name: task.name,
              seconds: avg,
              isAverage: true,
              task: task,
            );
          }
        }
        if (best != null) return (slowest: best, tasks: tasks);
      }

      for (final task in tasks) {
        final last = task.lastRunningTime;
        if (last == null || last <= 0) continue;
        if (best == null || last > best.seconds) {
          best = SlowestTask(
            id: task.id,
            name: task.name,
            seconds: last,
            isAverage: false,
            task: task,
          );
        }
      }
      return (slowest: best, tasks: tasks);
    } catch (_) {
      // 卡片隐藏；已经拉到的任务照样留给「最常失败」卡用
      return (slowest: null, tasks: tasks);
    }
  }
}

final dashboardProvider =
    StateNotifierProvider<DashboardNotifier, DashboardData>((ref) {
      return DashboardNotifier();
    });
