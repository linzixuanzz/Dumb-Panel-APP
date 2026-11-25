import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/dio_client.dart';
import '../../../shared/api/panel_insights.dart';
import '../../../shared/models/insights.dart';
import '../../../shared/utils/api_utils.dart';

/// 单个任务的健康画像（面板 v4.0 `GET /tasks/:id/health`），给任务详情弹层 / 详情页用。
///
/// 按任务 id 分开（family）：每个任务一份状态，**A 任务的结果永远不会落到 B 任务上**；
/// 同一个任务连发两次时，只认最后一次（[TaskHealthNotifier._seq]），先发的那次回来直接丢掉。
///
/// 不是 autoDispose：关掉弹层再打开同一个任务，先把上次的结果画出来、后台再刷新，
/// 不会每次都从空白开始。结果里记着是哪台面板的（[TaskHealthState.panel]），
/// 切换面板后第一次 load 会先清掉上一台面板的旧结果。
final taskHealthProvider =
    StateNotifierProvider.family<TaskHealthNotifier, TaskHealthState, int>(
      (ref, taskId) => TaskHealthNotifier(taskId),
    );

class TaskHealthState {
  /// 健康画像。[loaded] 为 true 而它是 null，表示**面板不支持**（老面板）或任务在面板上已经没了，
  /// 调用方据此隐藏统计和月历。
  final TaskHealth? health;

  /// 至少有一次请求正常返回过（含返回 null）。还没返回过时调用方不画统计，免得老面板上先闪一下再消失。
  final bool loaded;

  final bool loading;

  /// 网络 / 401 / 5xx 这类真正的失败（不是「不支持」）。
  final String? error;

  /// 结果属于哪台面板：面板代号 + 地址。
  final String panel;

  const TaskHealthState({
    this.health,
    this.loaded = false,
    this.loading = false,
    this.error,
    this.panel = '',
  });
}

class TaskHealthNotifier extends StateNotifier<TaskHealthState> {
  final int taskId;

  /// 第几次请求。回来时对不上号就说明后面又发了一次，这次的结果作废。
  int _seq = 0;

  TaskHealthNotifier(this.taskId) : super(const TaskHealthState());

  /// 拉取（或刷新）健康画像。默认 91 天，月历够覆盖到上个月月初。
  Future<void> load() async {
    final panel =
        '${DioClient.panelGeneration}|${DioClient.instance.dio.options.baseUrl}';
    // 同一台面板：保留旧结果边刷新边显示；换了面板：旧结果整个作废
    final keep = state.panel == panel;
    final seq = ++_seq;
    state = TaskHealthState(
      health: keep ? state.health : null,
      loaded: keep && state.loaded,
      loading: true,
      panel: panel,
    );
    try {
      final health = await fetchTaskHealth(taskId);
      // 弹层关了不影响（family 不销毁），但被更新的一次请求顶掉了就丢弃
      if (!mounted || seq != _seq) return;
      state = TaskHealthState(health: health, loaded: true, panel: panel);
    } catch (error) {
      if (!mounted || seq != _seq) return;
      state = TaskHealthState(
        health: state.health,
        loaded: state.loaded,
        error: extractErrorMessage(error, '运行统计加载失败'),
        panel: panel,
      );
    }
  }
}
