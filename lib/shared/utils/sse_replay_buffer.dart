/// SSE 重连后的「历史重放」去重缓冲。
///
/// 面板这四条流（任务实时日志 / 日志详情流 / 依赖安装日志 / 订阅拉取流）
/// **都不支持 `Last-Event-ID`**：服务端从来不发 `id:` 帧，也没有任何地方读它
/// （`server/handler/log.go`、`deps.go`、`subscription.go` 逐个查过）。
/// 所以任何重连都会把整段历史**从头重放一遍**，而不是从断点续。
///
/// 因此重连前把「已经显示过的行」灌进来，重放上来的行逐条抵扣，
/// 用户就看不到重复行 —— 这是在没有断点续传的前提下能做到的最接近无缝的行为。
///
/// 为什么第一处对不上就整个清空、之后原样放行：
/// 服务端重放的是「当前完整历史」，正常情况下它一定是已显示内容的前缀。
/// 一旦对不上（日志被截断、中途换了一次运行、任务重跑），继续逐条比对
/// 只会把真正的新行误吞掉。**宁可重复也不能吞行** —— 日志少一行比多一行危险得多。
class SseReplayBuffer {
  final List<String> _pending = <String>[];

  bool get isEmpty => _pending.isEmpty;

  /// 重连前调用：把当前已经显示给用户的行记下来，等着被重放抵扣。
  void reset(Iterable<String> alreadyShown) {
    _pending
      ..clear()
      ..addAll(alreadyShown);
  }

  void clear() => _pending.clear();

  /// 返回真正需要追加到界面上的行。
  List<String> consume(List<String> incoming) {
    if (_pending.isEmpty) {
      return incoming;
    }

    final result = <String>[];
    for (final line in incoming) {
      if (_pending.isNotEmpty && line == _pending.first) {
        _pending.removeAt(0);
        continue;
      }

      _pending.clear();
      result.add(line);
    }

    return result;
  }
}
