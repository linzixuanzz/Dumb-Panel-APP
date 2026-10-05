import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'ansi_text.dart';

/// 日志页在内存里最多保留的行数，超出后只留最近这么多行。
///
/// 与面板 Web 端「默认只渲染最后 5000 行」同一个量级，这里放宽到一万：
/// APP 没有 Web 那种「点击展开完整日志」，丢掉的行只能靠下载原始日志拿回来，
/// 所以多留一些；按行懒渲染之后行数本身不再拖慢界面，这个上限只管内存。
const int kLogBufferMaxLines = 10000;

/// 日志页的行缓冲：增量追加、超长只保留最近一部分。
///
/// 改造前三个日志页都是「来一段就 `_lines.join('\n')` 整段重建一棵 TextSpan」，
/// 每条 SSE 事件的开销随日志总长线性增长，几万行时页面直接卡死（issue #10）。
/// 现在追加只动新来的那几行，渲染交给 LogView 按行懒加载。
///
/// 每行还顺带记下「行首生效的 ANSI 样式」（[ansiStateAt]），在追加时一次性推好：
/// 颜色序列可以跨行生效，按行渲染时要靠它续上，而不能每画一行都从头重扫。
class LogLineBuffer extends ChangeNotifier {
  LogLineBuffer({this.maxLines = kLogBufferMaxLines})
    : assert(maxLines > 0, 'maxLines 必须大于 0');

  final int maxLines;

  final List<String> _lines = <String>[];
  final List<AnsiLineState> _lineStarts = <AnsiLineState>[];
  AnsiLineState _tailState = AnsiLineState.initial;
  int _droppedCount = 0;
  int _generation = 0;

  /// 表头偏移：[_lines] / [_lineStarts] 的前 [_head] 个元素在逻辑上已经裁掉，
  /// 只是还没从表里搬走（APP #15）。
  ///
  /// 运行中的日志是 SSE 一条一条追加的，缓冲区满了以后每来一行就要裁一行。
  /// 以前是当场 `removeRange(0, 1)`，两张一万个元素的表每次整体往前挪一格，
  /// 几万行的历史重放光搬表就要一两秒。现在裁剪只挪这个偏移，
  /// 攒够上限的十分之一再真正搬一次，逐行追加摊下来就不再随缓冲区大小变慢。
  /// 对外的行数、丢弃数、按下标取行都扣掉这个偏移，与逐行裁剪时一行不差。
  int _head = 0;

  /// 真正搬表（removeRange）的累计次数，只给测试钉住「逐行追加不再逐行搬表」用。
  int _compactions = 0;

  int get length => _lines.length - _head;
  bool get isEmpty => length == 0;
  bool get isNotEmpty => length != 0;

  /// 因为超长已经从内存里丢掉的行数（从第一行起算）。
  int get droppedCount => _droppedCount;

  /// 自上次 [replaceAll] 以来一共收到的行数，等于 [droppedCount] + [length]。
  ///
  /// 第 n 行（从 0 起）在整段日志里的位置是固定的，丢掉前面的行不会改变它；
  /// LogView 靠这个「绝对行号」定位，裁剪时屏幕上正在看的行才不会错位。
  int get totalCount => _droppedCount + length;

  /// 每次 [replaceAll]（含 [clear]）加一，表示绝对行号重新从 0 数起。
  int get generation => _generation;

  /// 当前保留的行（只读）。
  ///
  /// 表头没有待搬走的行时是不复制的视图；有的话返回一份拷贝。
  /// 只有重连去重（把已显示的行交给 SseReplayBuffer）和测试会读它，不在逐行追加的路径上。
  List<String> get lines =>
      UnmodifiableListView(_head == 0 ? _lines : _lines.sublist(_head));

  String lineAt(int index) => _lines[_head + index];

  /// 第 [index] 行行首生效的 ANSI 样式。
  AnsiLineState ansiStateAt(int index) => _lineStarts[_head + index];

  /// 真正搬表的累计次数（见 [_head]）。只给测试用，界面不读它。
  @visibleForTesting
  int get debugCompactions => _compactions;

  /// 用户正在往上翻看（或选中了文字）时由 LogView 置 true：暂缓裁剪。
  ///
  /// 从表头裁掉行会让下面所有行的位置一起往上挪，用户正在读的那几行就会被带走，
  /// 这正是 #10 要解决的「被拖走」。所以翻看期间先放宽到两倍上限，
  /// 回到底部（跟随时裁剪的挪动被贴底抵消，看不出来）再恢复正常上限。
  /// 只是个标记、改它不会立即裁剪：裁剪留到下一次追加时顺带做，
  /// 免得在滚动通知回调里改动正在布局的列表。
  bool holdTrim = false;

  /// 追加若干行。
  void append(Iterable<String> lines) {
    if (!_addAll(lines)) {
      return;
    }
    _trim();
    notifyListeners();
  }

  /// 整体替换内容，绝对行号从 0 重新数起。
  void replaceAll(Iterable<String> lines) {
    _lines.clear();
    _lineStarts.clear();
    _tailState = AnsiLineState.initial;
    _droppedCount = 0;
    _head = 0;
    _generation++;
    _addAll(lines);
    _trim();
    notifyListeners();
  }

  void clear() => replaceAll(const <String>[]);

  /// 把保留的行拼回一整段文本（「复制全部」用）。
  String joinAll() => _lines.skip(_head).join('\n');

  bool _addAll(Iterable<String> lines) {
    var added = false;
    for (final line in lines) {
      _lineStarts.add(_tailState);
      _tailState = _tailState.advance(line);
      _lines.add(line);
      added = true;
    }
    return added;
  }

  void _trim() {
    final limit = holdTrim ? maxLines * 2 : maxLines;
    if (length <= limit) {
      return;
    }
    // 翻看期间撑到两倍才裁，一次裁回 maxLines：宁可少裁几次，
    // 也不要每来一行就把用户眼前的内容往上推一行。
    final excess = length - maxLines;
    // 逻辑上这一刻就裁好了（对外严格只剩 maxLines 行），物理上先只挪表头偏移。
    _head += excess;
    _droppedCount += excess;
    // 攒够上限的十分之一再整体搬一次：一万行时每一千行才搬一回，
    // 跟随时物理上最多多留一成。上限小于 10 时每次都搬，与原来完全一样。
    if (_head >= maxLines ~/ 10) {
      _lines.removeRange(0, _head);
      _lineStarts.removeRange(0, _head);
      _head = 0;
      _compactions++;
    }
  }
}
