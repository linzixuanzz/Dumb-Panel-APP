// 脚本编辑器的搜索匹配层。纯字符串运算，不依赖 Flutter，可直接单测。
//
// ── 为什么要从 script_list_page.dart 里搬出来 ──────────────────────────────
// 改造前「下一个」把搜索游标寄存在 `TextEditingController.selection` 上，
// 而 build() 里每帧一句 `controller.text = state.content` 会把 selection 打回
// `TextSelection.collapsed(offset: -1)`（Flutter 的 set text 强制重置光标）。
// 于是游标每帧被抹掉，下次点「下一个」时 `selection.isValid` 为 false，
// 查找起点回落成 0，`indexOf` 永远返回第一个命中 —— 这就是 issue #6 (c)
// 「点下一个不进行检索跳转」。
//
// 修法是让搜索拥有**自己的**命中列表与序号，不再依赖任何会被 UI、输入法、
// 焦点切换改写的状态。而那份计算是纯粹的字符串运算，抽出来才测得到。

/// 单次搜索最多记录多少个命中。
///
/// 设上限不是怕算不动（`indexOf` 扫几 MB 也就几毫秒），而是**高亮**的代价：
/// 每个命中都要在 `buildTextSpan` 里切出一个 TextSpan，几千个命中会让每次
/// setState 重建上千个 span，滚动当场掉帧。超出上限时 UI 上标 `500+`。
const int kScriptSearchMatchLimit = 500;

/// 全文查找 [query] 的**所有命中起点**，大小写不敏感。
///
/// 语义与改造前的 `indexOf` 循环保持一致：
/// - 空内容或空 [query] 返回空列表（不是「全选」）；
/// - **命中不重叠**：找到一个就从它的末尾继续，所以 `"aaaa"` 里找 `"aa"` 得到
///   `[0, 2]` 而不是 `[0, 1, 2]`。重叠命中会让高亮切片互相套住，必须排除；
/// - 最多返回 [limit] 个，超出部分直接丢弃。
List<int> findMatchOffsets(
  String content,
  String query, {
  int limit = kScriptSearchMatchLimit,
}) {
  if (content.isEmpty || query.isEmpty || limit <= 0) {
    return const [];
  }

  var haystack = content.toLowerCase();
  var needle = query.toLowerCase();
  // ⚠️ 极少数字符小写化之后长度会变（土耳其语 İ 之类）。一旦长度不等，小写串上的
  // 下标就不能拿回原文去切片：轻则高亮错位，重则 substring 抛 RangeError 把编辑器
  // 整块打崩。这种文件本来就罕见，退回大小写敏感也比切崩强。
  if (haystack.length != content.length || needle.length != query.length) {
    haystack = content;
    needle = query;
  }

  final offsets = <int>[];
  var start = 0;
  while (start <= haystack.length - needle.length) {
    final index = haystack.indexOf(needle, start);
    if (index < 0) {
      break;
    }
    offsets.add(index);
    if (offsets.length >= limit) {
      break;
    }
    start = index + needle.length;
  }
  return offsets;
}

/// 「下一个 / 上一个」的序号推进，到头回绕。
///
/// [current] 为负表示还没定位过：向下从第一个开始，向上从最后一个开始
/// （与改造前 `lastIndexOf` 从文末往回找的手感一致）。
/// [total] <= 0 时返回 -1 —— 没有命中就没有「当前项」。
int nextMatchIndex(int current, int total, {required bool forward}) {
  if (total <= 0) {
    return -1;
  }
  if (current < 0) {
    return forward ? 0 : total - 1;
  }
  // current 可能是上一轮搜索留下的、比现在的命中数还大的序号，先归一化。
  final normalized = current % total;
  return forward ? (normalized + 1) % total : (normalized - 1 + total) % total;
}

/// 在 [offsets] 里找离 [target] 最近的那个命中的序号。
///
/// 用途只有一个：用户正在编辑器里打字时会重扫全文，那时不该把「当前是第几个命中」
/// 打回第 1 个（计数会一直从 `7/20` 跳回 `1/20`，正文里的强高亮也跟着跳回开头）。
/// 按距离就近落位，手感上等于「还停在原地」。
///
/// [offsets] 必须是升序的（[findMatchOffsets] 的输出天然如此）。空列表返回 -1。
/// 距离相同时取靠前的那个。
int nearestMatchIndex(List<int> offsets, int target) {
  if (offsets.isEmpty) {
    return -1;
  }
  var best = 0;
  var bestDistance = (offsets[0] - target).abs();
  for (var i = 1; i < offsets.length; i++) {
    final distance = (offsets[i] - target).abs();
    // 升序 + 距离一旦开始变大就不会再变小，可以提前收工。
    if (distance >= bestDistance) {
      break;
    }
    best = i;
    bestDistance = distance;
  }
  return best;
}

/// [offset] 落在第几行，行号从 1 开始。
///
/// 数的是**逻辑行**（`\n`），与行号栏显示的是同一套编号 —— 软换行的续行不另起行号。
/// 空文件、负数、越界一律归到第 1 行。
int lineNumberForOffset(String content, int offset) {
  if (content.isEmpty || offset <= 0) {
    return 1;
  }
  final end = offset > content.length ? content.length : offset;
  var line = 1;
  for (var i = 0; i < end; i++) {
    if (content.codeUnitAt(i) == 0x0A) {
      line++;
    }
  }
  return line;
}
