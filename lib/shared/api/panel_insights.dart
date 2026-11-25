// 面板 v4.0 洞察类接口的客户端：任务健康画像、需要关注、运行中、最近 N 次。
//
// ── 和老面板怎么兼容：形状探测，不看版本号（panel-contract.md）─────────────
// 这几条路由只有 v4.0 面板有。连老面板时：
//   - 路由不存在 → 404 `{"error":"route not found"}`（更老的是纯文本）或 405；
//   - 响应形状不对（被别的路由接走、反向代理回了网页）也算不支持。
// 这两种都返回 **null**，调用方据此隐藏卡片 / 降级；同时在内存里记一笔
// 「这台面板不支持这条接口」，本次会话里不再重复请求。切换面板时清空。
// 网络错误、401、5xx 等**照常抛出**，由调用方按「加载失败」处理 —— 那不是「不支持」。
//
// ⚠️ 这几条接口的响应**没有 data 包装**（与 v3.x 的大多数接口不同），直接是
// `{days, stats, recent}` / `{items}` / `{runs}`，不要套 `extractData`。

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/network/api_endpoints.dart';
import '../../core/network/dio_client.dart';
import '../models/insights.dart';

/// 任务健康画像。`days` 面板会夹到 7~180。
///
/// 返回 null：面板不支持（老面板），或**这个任务在面板上已经不存在**（v4.0 面板对不存在的
/// 任务也回 404，但那不代表面板不支持，所以不会记成不支持）。
Future<TaskHealth?> fetchTaskHealth(int id, {int days = 91, Dio? dio}) async {
  final data = await _probe(
    'health',
    (d) => d.get(
      ApiEndpoints.taskHealth(id),
      queryParameters: {'days': days},
    ),
    dio,
  );
  if (identical(data, _skipped)) return null;
  if (data is! Map<String, dynamic>) return _unsupported('health', data);
  if (data['days'] is! List ||
      data['stats'] is! Map ||
      data['recent'] is! List) {
    return _unsupported('health', data);
  }
  return TaskHealth.fromJson(data);
}

/// 「需要关注」清单（已按 err → warn → info、时间倒序排好，最多 20 条）。
/// 面板按角色裁剪：viewer 只有任务类，admin 才有依赖与磁盘。
Future<List<AttentionItem>?> fetchAttention({Dio? dio}) async {
  final data = await _probe(
    'attention',
    (d) => d.get(ApiEndpoints.systemAttention),
    dio,
  );
  if (identical(data, _skipped)) return null;
  if (data is! Map<String, dynamic> || data['items'] is! List) {
    return _unsupported('attention', data);
  }
  return (data['items'] as List)
      .whereType<Map<String, dynamic>>()
      .map(AttentionItem.fromJson)
      .toList();
}

/// 当前运行中的任务。没有任务在跑时是空列表（不是 null）。
Future<List<RunningTask>?> fetchRunning({Dio? dio}) async {
  final data = await _probe(
    'running',
    (d) => d.get(ApiEndpoints.tasksRunning),
    dio,
  );
  if (identical(data, _skipped)) return null;
  if (data is! Map<String, dynamic> || data['items'] is! List) {
    return _unsupported('running', data);
  }
  return (data['items'] as List)
      .whereType<Map<String, dynamic>>()
      .map(RunningTask.fromJson)
      .toList();
}

/// 多个任务各自最近 [limit] 次已结束的执行，每个任务旧 → 新。
///
/// - 面板一次最多 100 个 id、limit 夹到 1~30；超过 100 个时面板回 400，这里会照常抛出，
///   调用方按当前页（任务列表每页最多 100）取即可；
/// - 请求里的每个 id 都会出现在结果里，没跑过的是空列表；
/// - [ids] 为空时不发请求，直接返回空 Map。
Future<Map<int, List<RecentRun>>?> fetchRecentRuns(
  List<int> ids, {
  int limit = 20,
  Dio? dio,
}) async {
  if (ids.isEmpty) {
    // 不发请求，但已知不支持时仍要如实返回 null，免得调用方以为面板支持
    return isInsightUnsupported('recent-runs', dio: dio) ? null : {};
  }
  final data = await _probe(
    'recent-runs',
    (d) => d.get(
      ApiEndpoints.tasksRecentRuns,
      queryParameters: {'ids': ids.join(','), 'limit': limit},
    ),
    dio,
  );
  if (identical(data, _skipped)) return null;
  if (data is! Map<String, dynamic> || data['runs'] is! Map) {
    return _unsupported('recent-runs', data);
  }
  final result = <int, List<RecentRun>>{};
  (data['runs'] as Map).forEach((key, value) {
    // JSON 对象的键只能是字符串，面板把任务 id 转成了 "12"
    final id = int.tryParse(key.toString());
    if (id == null || value is! List) return;
    result[id] = value
        .whereType<Map<String, dynamic>>()
        .map(RecentRun.fromJson)
        .toList();
  });
  return result;
}

// ── 「这台面板不支持」的记忆 ────────────────────────────────────────────

/// 记住的是哪台面板：地址 + DioClient 的面板代号。切换面板（地址变了）时代号会自增，
/// 两者任何一个变了就整体清空。只在内存里，重启 APP 重新探测一次。
String _memoPanel = '';
final Set<String> _unsupportedKeys = <String>{};

String _panelOf(Dio dio) =>
    '${DioClient.panelGeneration}|${dio.options.baseUrl}';

/// 切面板了就清空记忆。
void _syncPanel(Dio dio) {
  final panel = _panelOf(dio);
  if (panel != _memoPanel) {
    _memoPanel = panel;
    _unsupportedKeys.clear();
  }
}

/// 当前面板是否**已经探测到**不支持某条接口（`health` / `attention` / `running` / `recent-runs`）。
/// 还没请求过时是 false。调用方一般不需要它：直接调 fetch，拿到 null 就隐藏。
bool isInsightUnsupported(String key, {Dio? dio}) {
  _syncPanel(dio ?? DioClient.instance.dio);
  return _unsupportedKeys.contains(key);
}

@visibleForTesting
void resetPanelInsightsForTest() {
  _memoPanel = '';
  _unsupportedKeys.clear();
}

/// 记一笔不支持并返回 null。[data] 只用于调试时看看形状。
T? _unsupported<T>(String key, Object? data) {
  _unsupportedKeys.add(key);
  if (kDebugMode) {
    debugPrint('[panel_insights] $key 形状不符，按面板不支持处理：${data.runtimeType}');
  }
  return null;
}

/// 「没拿到响应体」的哨兵：已知不支持没发请求、路由不存在、或任务已不存在。
/// 与「请求成功但响应体是 null」区分开 —— 后者是形状不符，要记成不支持；
/// 前者该记的 [_probe] 已经记过了（任务不存在则故意不记），调用方直接返回 null。
const Object _skipped = Object();

/// 发请求并处理 404 / 405。返回响应体；没拿到响应体时返回 [_skipped]。
Future<Object?> _probe(
  String key,
  Future<Response<dynamic>> Function(Dio dio) request,
  Dio? injected,
) async {
  final dio = injected ?? DioClient.instance.dio;
  _syncPanel(dio);
  if (_unsupportedKeys.contains(key)) return _skipped;
  try {
    final response = await request(dio);
    return response.data;
  } on DioException catch (e) {
    final status = e.response?.statusCode;
    if (status == 405) {
      _unsupportedKeys.add(key);
      return _skipped;
    }
    if (status == 404) {
      // 老面板的 404 是「路由不存在」：JSON `{"error":"route not found"}` 或纯文本。
      // v4.0 面板的 health 对不存在的任务也回 404（`{"error":"任务不存在"}`），
      // 那只说明这个任务没了，不能把整台面板记成不支持。
      final body = e.response?.data;
      final routeMissing =
          body is! Map || body['error']?.toString() == 'route not found';
      if (routeMissing) _unsupportedKeys.add(key);
      return _skipped;
    }
    rethrow;
  }
}
