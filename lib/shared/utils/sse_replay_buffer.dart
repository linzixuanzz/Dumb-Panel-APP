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

  /// 下一条要比对的行在 [_pending] 里的位置。
  ///
  /// 用游标而不是 `removeAt(0)`：超长日志重连时要抵扣上万行，
  /// 每次删表头都要整体搬移，抵扣一遍就成了平方级。
  int _cursor = 0;

  /// 重放开头还要原样跳过的行数，见 [reset] 的 `skipLeading`。
  int _skip = 0;

  bool get isEmpty => _skip == 0 && _cursor >= _pending.length;

  /// 重连前调用：把当前已经显示给用户的行记下来，等着被重放抵扣。
  ///
  /// [skipLeading] 是日志页因为太长**已经丢掉**的前若干行（只在内存里保留最近一部分，
  /// 见 LogLineBuffer）。服务端重放是从第一行开始的，这些行本地已经没有原文可比，
  /// 只能按行数跳过；它们本来就算在「未显示、可下载完整日志」的那部分里，
  /// 跳过不等于吞掉。不传就是原来的行为。
  void reset(Iterable<String> alreadyShown, {int skipLeading = 0}) {
    _pending
      ..clear()
      ..addAll(alreadyShown);
    _cursor = 0;
    _skip = skipLeading < 0 ? 0 : skipLeading;
  }

  void clear() {
    _pending.clear();
    _cursor = 0;
    _skip = 0;
  }

  /// 返回真正需要追加到界面上的行。
  List<String> consume(List<String> incoming) {
    if (isEmpty) {
      return incoming;
    }

    final result = <String>[];
    for (final line in incoming) {
      if (_skip > 0) {
        _skip--;
        continue;
      }
      if (_cursor < _pending.length && line == _pending[_cursor]) {
        _cursor++;
        continue;
      }

      clear();
      result.add(line);
    }

    if (isEmpty) {
      // 抵扣完了就把原文放掉，别让上万行一直挂在内存里。
      clear();
    }
    return result;
  }
}
