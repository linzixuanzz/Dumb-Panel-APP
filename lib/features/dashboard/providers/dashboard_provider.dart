import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/utils/api_utils.dart';

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

class DashboardData {
  final Map<String, dynamic> system;
  final Map<String, dynamic> dashboard;
  final bool loading;
  final String? error;

  const DashboardData({
    this.system = const {},
    this.dashboard = const {},
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

  /// 今日主动终止的执行数（面板 `server/handler/system.go:101-102, 166`）。
  ///
  /// 面板已经把 aborted 从成功/失败里拆出来单独统计
  /// （`Stats` 里注释写明「成功率只统计自然完成的成功 / 失败」），
  /// APP 之前只读 success_logs / failed_logs，于是被手动停止的执行在首页
  /// **凭空消失**：今日成功 + 今日失败对不上今日执行总数，用户以为丢日志了。
  ///
  /// 老面板不返回这个键 → 0，与改动前的显示完全一致。
  int get todayAborted => (dashboard['aborted_logs'] as num?)?.toInt() ?? 0;
  List<dynamic> get recentLogs => dashboard['recent_logs'] as List? ?? [];
  List<dynamic> get executionTrend => dashboard['daily_stats'] as List? ?? [];

  DashboardData copyWith({
    Map<String, dynamic>? system,
    Map<String, dynamic>? dashboard,
    bool? loading,
    String? error,
  }) {
    return DashboardData(
      system: system ?? this.system,
      dashboard: dashboard ?? this.dashboard,
      loading: loading ?? this.loading,
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

  Future<void> load() async {
    state = state.copyWith(loading: true, error: null);
    try {
      // 四个并发请求共用同一个实例，避免 getter 中途读到被切面板改写的单例。
      final dio = _dio;
      // 主数据：系统信息 + 仪表盘统计，失败就是整页失败。
      final systemFuture = dio.get(ApiEndpoints.systemInfo);
      final dashboardFuture = dio.get(ApiEndpoints.dashboard);
      // 辅助数据：只用来补面板标题和版本号。收紧 validateStatus 后它们的 4xx
      // 会让 Future.wait 整体失败，导致「仅仅是拿不到面板标题」就把整个首页打空。
      final panelFuture = _optional(dio.get(ApiEndpoints.panelSettings));
      final versionFuture = _optional(dio.get(ApiEndpoints.systemVersion));

      final sysData = extractData((await systemFuture).data);
      final dashData = extractData((await dashboardFuture).data);
      final panelData = await panelFuture;
      final versionData = await versionFuture;
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
        loading: false,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: '加载失败');
    }
  }
}

final dashboardProvider =
    StateNotifierProvider<DashboardNotifier, DashboardData>((ref) {
      return DashboardNotifier();
    });
