import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/design_tokens.dart';
import '../utils/log_background.dart';
import '../utils/log_error_keywords.dart';
import '../utils/log_line_buffer.dart';
import 'app_back_button.dart';
import 'app_buttons.dart';
import 'app_snack.dart';
import 'log_view.dart';

/// 全屏沉浸式实时日志的四态严格语义（彻底杜绝「✓ 失败」错位图标）。
enum FullscreenLogTone {
  /// 运行中 / 实时流输出（钴蓝呼吸圆点）。
  running,

  /// 正常完成（森林绿 `✓`）。
  success,

  /// 异常退出 / 报错 / 断线（珊瑚红 `✕`）。
  failed,

  /// 已停止 / 等待 / 暂无日志等中性态（石色圆点，绝不打对勾）。
  neutral,
}

/// 注入到右上角 `⋮` 溢出菜单里的附加菜单项。
class FullscreenLogMenuEntry {
  final String id;
  final String label;
  final IconData? icon;
  final bool? checked;
  final bool enabled;
  final Future<void> Function() onTap;

  const FullscreenLogMenuEntry({
    required this.id,
    required this.label,
    this.icon,
    this.checked,
    this.enabled = true,
    required this.onTap,
  });
}

final RegExp _ansiEscape = RegExp(r'\x1b\[[0-9;?]*[A-Za-z]');

String _stripAnsi(String raw) =>
    raw.contains('\x1b') ? raw.replaceAll(_ansiEscape, '') : raw;

/// 非 0 的退出码。面板脚本运行器写的是「退出码: 1」，带冒号。
final RegExp _errorExitCode = RegExp(
  r'(?:退出码|exit (?:code|status))\s*[:：=]?\s*-?[1-9]',
);

/// 字段值是「空」：数值恰好是 0（`0x…` 这类十六进制错误码、`00:00:05`
/// 这类时间不算）、null / none / nil / false / undefined（整词，
/// `nonexistent` 不算）、空串、空数组、空对象。
const String _emptyFieldValue =
    r'''(?:["']?0+(?![\d.x:])["']?'''
    r'|(?:null|none|nil|false|undefined)(?![a-z0-9_])'
    r'''|""|''|\[\]|\{\})''';

/// 提到报错的数据字段键名：`error_code`、`errormsg`、`failed`、
/// `read_timeout`（已转小写）。两侧各限 24 个字母：行里有一长串字母时回溯
/// 不至于变成平方级。
const String _errorishKey =
    r'[a-z_]{0,24}(?:err|fail|exception|timeout)[a-z_]{0,24}';

/// 「提到了错误、但说的是没有错误」的写法，判报错前先从行里抹掉。
///
/// 签到类脚本几乎每次都打「成功 12 个，失败 0 个」，接口回包也常带
/// `"error_code":0`、`"error": null`，请求配置里还有 `timeout: 30`；
/// 按子串一碰就算报错，成功的日志也会冒出红色的「首处报错」。
///
/// 「键: 空值」只在键明显是数据字段时才算没出错。异常行也长成「键: 值」：
/// `KeyError: 0`、`TypeError: null is not an object`、
/// `NullPointerException: null`、`Error: None of the accounts…`，
/// 不能因为冒号后面跟了个 0 / null / None 就当成没出错。
///
/// 「0」两边紧挨着冒号、逗号、小数点的不算计数：定时任务多在整点启动，
/// 头一秒就挂的脚本打出来是「08:00:00 ERROR …」「08:00 失败」，时间末尾
/// 的 00 读成「0 个失败」，真报错就被抹掉了；`1,000 errors` 也一样。
final RegExp _benignErrorMention = RegExp(
  // 「失败 0 个」「失败：0」「超时 0 次」
  r'(?:失败|错误|异常|超时)\s*[:：=]?\s*0+(?![\d.x:])'
  // 「0 个失败」「0 次超时」
  r'|(?<![\d.:,])0+\s*(?:个|条|次|项|处)?\s*(?:失败|错误|异常|超时)'
  // 「0 errors」「no errors」「0 failed」「0 timeouts」
  r'|\b(?:(?<![.:,])0+|no|zero)\s+'
  r'(?:errors?|exceptions?|failures?|failed|fails?|fatal|timeouts?)\b'
  // 带引号的键（JSON、Python dict）：「"error_code":0」「'error': None」
  r'''|["']''' '$_errorishKey' r'''["']\s*[:=]\s*'''
  '$_emptyFieldValue'
  // 等号：「failed=0」「error=nil」
  r'|\b' '$_errorishKey' r'\s*=\s*'
  '$_emptyFieldValue'
  // 带下划线的键：「error_count: 0」
  r'|\b(?=[a-z_]*_)' '$_errorishKey' r'\s*:\s*'
  '$_emptyFieldValue'
  // 对象字面量里的一项（Node 的 console.log 打出来键不带引号）：
  // 「{ code: 0, error: null }」。前面是 { 或逗号，后面紧跟逗号或收尾。
  r'|[{,]\s*' '$_errorishKey' r'\s*:\s*'
  '$_emptyFieldValue'
  r'(?=\s*(?:[,}\]]|$))'
  // 汇总计数：「Errors: 0」「Passed: 10, Failed: 0」「failCount: 0」。
  // 只认单独的计数词，`KeyError: 0` 这类异常名前面紧挨着字母，过不了
  // 词边界。
  r'|\b(?:errors?|failures?|failed|fails?|exceptions?|timeouts?)'
  r'(?:_?(?:count|cnt|num|total))?\s*:\s*0+(?![\d.x:])'
  // 超时配置：「timeout: 30」「"timeout": 30000」「read_timeout=10」
  // 「connectTimeout: 5000」。数后面紧跟分隔符或行尾才算，
  // 「timeout: 30 seconds exceeded」照样是报错。
  r'''|\b[a-z_]{0,24}time_?outs?["']?\s*[:=]\s*["']?\d+(?:\.\d+)?'''
  r'''\s*(?:m?s|secs?|seconds?|m|mins?|minutes?|秒|毫秒|分钟)?["']?'''
  r'(?=\s*(?:[,;)}\]]|$))'
  // 「超时时间：30 秒」
  r'|超时(?:时间|设置)\s*(?:为|是)?\s*[:：=]?\s*\d+(?:\.\d+)?'
  r'\s*(?:ms|s|秒|毫秒|分钟)?(?=\s*(?:[,，;；)）}\]]|$))',
);

/// Node 的 console.log 把长对象拆成多行时，每个属性单占一行、缩进两格：
/// 「  error: null,」「  errorCode: 0,」。值后面紧跟逗号、括号或行尾。
final RegExp _indentedEmptyField = RegExp(
  r'^\s+' '$_errorishKey' r'\s*:\s*' '$_emptyFieldValue'
  r'(?=\s*(?:[,}\]]|$))',
);

/// 缩进之后是小写字母或下划线开头。数据字段的键是小写开头（`errorCode`），
/// 异常名是大写开头（`    KeyError: 0` 仍算报错）；转小写之后就分不出来，
/// 所以在原文上判。
final RegExp _indentedLowercaseKey = RegExp(r'^\s+[a-z_]');

/// 「首处报错」认哪些行。
///
/// 关键词与面板「需要关注」挑错误行（`PickAttentionDetail`）、日志列表失败行
/// 下面的错误行是同一张表（[kLogErrorKeywords]），按小写子串匹配，面板自己
/// 写的 `=== 开始执行 / 执行结束 … ===` 分隔行不算。
///
/// 比它们多一步：先抹掉「没出错」的写法（[_benignErrorMention]）。那两处只看
/// 已经失败的日志，这里每份日志都判，成功日志里的「失败 0 个」「timeout: 30」
/// 不能冒出红色的「首处报错」。
bool looksLikeLogErrorLine(String raw) {
  final plain = _stripAnsi(raw);
  if (plain.trimLeft().startsWith('=== ')) {
    return false;
  }
  final lower = plain.toLowerCase();
  final mentioned =
      kLogErrorKeywords.any(lower.contains) ||
      lower.contains('退出码') ||
      lower.contains('exit ');
  if (!mentioned) {
    return false;
  }
  var rest = lower;
  if (_indentedLowercaseKey.hasMatch(plain)) {
    rest = rest.replaceFirst(_indentedEmptyField, ' ');
  }
  rest = rest.replaceAll(_benignErrorMention, ' ');
  return _errorExitCode.hasMatch(rest) || kLogErrorKeywords.any(rest.contains);
}

/// 全屏日志的「首处报错」和页内搜索命中，按绝对行号增量维护。
///
/// 运行中的日志是 SSE 每条 `data:` 行 append 一次，打开页面时的历史重放就是
/// 几万次逐行追加（panel-contract「实时日志」）。每来一行都把整个缓冲区重扫一遍
/// （去 ANSI、转小写、逐个比关键词），重放 N 行就是 N²/2 次扫描，几千行的
/// 日志页能卡死几十秒。这里记住扫到了哪一行，追加时只看新来的行；
/// 缓冲区整段替换（`generation` 变了）或换了查询词才从头扫。
class FullscreenLogIndex {
  int _generation = -1;

  /// 绝对行号：首处报错还没找到时，`[droppedCount, _errorCheckedUpTo)` 已判过。
  int _errorCheckedUpTo = 0;
  int? _firstError;

  String _query = '';

  /// 命中的绝对行号，升序。表头裁掉时逐个 `removeFirst`（O(1)），
  /// 不能用 List 的 `removeAt(0)`：搜「INFO」这类每行都中的词时，
  /// 缓冲区每裁一行就要整表搬一次，又退回 O(n)/行。
  final ListQueue<int> _matches = ListQueue<int>();
  int _matchScannedUpTo = 0;

  int _scannedLines = 0;

  /// 还留在缓冲区里的第一处报错的绝对行号。
  int? get firstErrorLine => _firstError;

  /// 当前查询词（已去首尾空白、转小写）；空串表示不搜。
  String get query => _query;

  int get matchCount => _matches.length;

  /// 第 [index] 处命中的绝对行号（升序，不设上限）。
  int matchAt(int index) => _matches.elementAt(index);

  /// 累计判过多少行（报错 + 搜索各算一次）。只给测试钉住「逐行追加是 O(1)/行」。
  @visibleForTesting
  int get debugScannedLines => _scannedLines;

  /// 换了缓冲区：下次 [sync] 从头扫。新旧缓冲区的 generation 可能恰好相同，
  /// 不能只靠 generation 判。
  void reset() {
    _generation = -1;
  }

  /// 换查询词（传原始输入）。命中表清空，下次 [sync] 从头重扫。
  void setQuery(String query) {
    final next = query.trim().toLowerCase();
    if (next == _query) {
      return;
    }
    _query = next;
    _matches.clear();
    _matchScannedUpTo = 0;
  }

  /// 对齐到缓冲区当前内容，返回命中表表头被裁掉了几条（调用方据此平移游标）。
  int sync(LogLineBuffer buffer) {
    final dropped = buffer.droppedCount;
    final total = buffer.totalCount;
    if (buffer.generation != _generation) {
      _generation = buffer.generation;
      _firstError = null;
      _errorCheckedUpTo = 0;
      _matches.clear();
      _matchScannedUpTo = 0;
    }

    // 首处报错被裁出缓冲区了：从它的下一行接着找还留着的第一处，
    // 每行最多判一次。
    final lost = _firstError;
    if (lost != null && lost < dropped) {
      _firstError = null;
      _errorCheckedUpTo = lost + 1;
    }
    if (_firstError == null) {
      var line = math.max(_errorCheckedUpTo, dropped);
      while (line < total) {
        _scannedLines++;
        final hit = looksLikeLogErrorLine(buffer.lineAt(line - dropped));
        line++;
        if (hit) {
          _firstError = line - 1;
          break;
        }
      }
      _errorCheckedUpTo = line;
    }

    var trimmed = 0;
    while (_matches.isNotEmpty && _matches.first < dropped) {
      _matches.removeFirst();
      trimmed++;
    }
    if (_query.isNotEmpty) {
      for (var line = math.max(_matchScannedUpTo, dropped);
          line < total;
          line++) {
        _scannedLines++;
        final plain = _stripAnsi(buffer.lineAt(line - dropped));
        if (plain.toLowerCase().contains(_query)) {
          _matches.add(line);
        }
      }
    }
    _matchScannedUpTo = total;
    return trimmed;
  }
}

/// 方案 1 · Nordic Calm 统一无底栏全屏沉浸式日志容器。
class FullscreenLogScaffold extends StatefulWidget {
  const FullscreenLogScaffold({
    super.key,
    required this.title,
    this.subtitle,
    required this.statusLabel,
    required this.statusTone,
    required this.buffer,
    required this.loading,
    this.emptyMessage = '无日志内容',
    this.errorMessage,
    this.follow = true,
    this.configuredBackgroundColor,
    this.truncatedHint,
    this.truncatedActionLabel,
    this.onTruncatedAction,
    this.onStop,
    this.stopBusy = false,
    this.stopLabel = '停止运行',
    this.onRerun,
    this.rerunBusy = false,
    this.rerunLabel = '重新运行',
    this.onOpenScript,
    this.openScriptBusy = false,
    this.menuBusy = false,
    this.extraMenuEntries = const [],
    this.copySuccessToast,
    this.truncatedCopyHint,
  });

  final String title;
  final String? subtitle;
  final String statusLabel;
  final FullscreenLogTone statusTone;
  final LogLineBuffer buffer;
  final bool loading;
  final String emptyMessage;

  /// 非空时在正文顶上显示一条整宽的错误提示（珊瑚红墨色，不截断）。
  ///
  /// 断线、接口失败这类原因要让用户看全：状态胶囊只有 96dp 宽、单行省略，
  /// 放不下一句完整的原因；只写进 [emptyMessage] 又会在日志非空时看不见。
  /// 日志为空、不为空都显示。
  final String? errorMessage;
  final bool follow;
  final Color? configuredBackgroundColor;
  final String? truncatedHint;
  final String? truncatedActionLabel;
  final VoidCallback? onTruncatedAction;

  final VoidCallback? onStop;
  final bool stopBusy;
  final String stopLabel;

  final VoidCallback? onRerun;
  final bool rerunBusy;
  final String rerunLabel;

  final VoidCallback? onOpenScript;
  final bool openScriptBusy;

  /// 页面有菜单里发起的慢操作在跑（下载原始日志、兜底查询任务…）时置 true：
  /// `⋮` 换成小转圈，菜单照样能点开（复制等项一直可用）。
  ///
  /// 只是反馈、不兼任锁：防重入由页面自己的状态位负责。
  final bool menuBusy;

  final List<FullscreenLogMenuEntry> extraMenuEntries;

  /// 「复制全部」成功、且日志没被截断时的提示；不传为「日志已复制到剪贴板」。
  ///
  /// 截断时不用它：一律在点击那一刻按缓冲区现算「已复制最近 N 行」。
  /// 页面流式追加时不会重建，build 时算好的文案到点击时早就过期了。
  final String? copySuccessToast;

  /// 截断时接在「已复制最近 N 行」后面的引导（如「完整日志请下载原始日志」）。
  final String? truncatedCopyHint;

  @override
  State<FullscreenLogScaffold> createState() => _FullscreenLogScaffoldState();
}

/// 底栏一颗工具芯片的内容；放不放得下由 `_buildFooterRow` 统一量。
class _FooterChip {
  const _FooterChip({
    required this.key,
    required this.label,
    required this.icon,
    required this.fg,
    required this.bg,
    required this.onTap,
    this.busy = false,
  });

  final Key key;
  final String label;
  final IconData icon;
  final Color fg;
  final Color bg;
  final VoidCallback? onTap;
  final bool busy;

  Widget build({required bool compact}) => _UtilityThumbChip(
    key: key,
    label: label,
    icon: icon,
    fg: fg,
    bg: bg,
    busy: busy,
    compact: compact,
    onTap: onTap,
  );
}

class _FullscreenLogScaffoldState extends State<FullscreenLogScaffold>
    with SingleTickerProviderStateMixin {
  static const double _footerGap = 8;

  final _logController = LogViewController();
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  final _index = FullscreenLogIndex();

  late final AnimationController _pulseController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
    value: 1.0,
  );

  bool _nightTerminal = false;
  bool _showLineNumbers = false;
  bool _softWrap = true;

  bool _searchOpen = false;
  String _searchQuery = '';
  int _matchCursor = 0;

  /// 上一次整页构建时，由缓冲区推出来的那几项界面状态。
  Object? _builtSignature;

  @override
  void initState() {
    super.initState();
    widget.buffer.addListener(_onBufferChanged);
    _syncIndex();
    _loadReaderPrefs();
    _syncPulse();
  }

  @override
  void didUpdateWidget(FullscreenLogScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.buffer, widget.buffer)) {
      oldWidget.buffer.removeListener(_onBufferChanged);
      widget.buffer.addListener(_onBufferChanged);
      _index.reset();
      _syncIndex();
    }
    if (oldWidget.statusTone != widget.statusTone) {
      _syncPulse();
    }
  }

  void _syncPulse() {
    if (widget.statusTone == FullscreenLogTone.running) {
      if (!_pulseController.isAnimating) {
        _pulseController.repeat(reverse: true);
      }
    } else {
      if (_pulseController.isAnimating) {
        _pulseController.stop();
      }
      _pulseController.value = 1.0;
    }
  }

  @override
  void dispose() {
    widget.buffer.removeListener(_onBufferChanged);
    _pulseController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadReaderPrefs() async {
    final prefs = await loadLogReaderPreferences();
    if (!mounted) return;
    setState(() {
      _nightTerminal = prefs.nightTerminal;
      _showLineNumbers = prefs.showLineNumbers;
      _softWrap = prefs.softWrap;
    });
  }

  /// 整页里随缓冲区变的只有这几项；它们没变就不整页重建。
  ///
  /// 正文由 LogView 自己监听缓冲区刷新，顶栏行数由 ListenableBuilder 局部刷新。
  /// 跟随中缓冲区满了以后长度恒为上限，截断标签也不变，逐行追加不会触发整页构建。
  ///
  /// 当前命中的行号要单独算进来：同一次同步里表头裁掉一处、末尾又来一处，
  /// 游标被夹回 0、命中数也没变，只看这两项会漏掉重建，LogView 的高亮还停在
  /// 已经被裁掉的那一行上。
  Object _bufferSignature() {
    final buf = widget.buffer;
    return (
      buf.isEmpty,
      _index.firstErrorLine != null,
      _index.matchCount,
      _matchCursor,
      _index.matchCount == 0 ? null : _index.matchAt(_matchCursor),
      buf.droppedCount > 0 ? buf.length : 0,
    );
  }

  void _onBufferChanged() {
    if (!mounted) return;
    _syncIndex();
    if (_bufferSignature() != _builtSignature) {
      setState(() {});
    }
  }

  void _syncIndex() {
    // 表头裁掉了几处命中，游标跟着往前挪，指的还是原来那一行。
    final trimmed = _index.sync(widget.buffer);
    final count = _index.matchCount;
    _matchCursor = count == 0
        ? 0
        : (_matchCursor - trimmed).clamp(0, count - 1);
  }

  void _toggleSearch() {
    final next = !_searchOpen;
    setState(() {
      _searchOpen = next;
      if (!next) {
        _searchController.clear();
        _searchQuery = '';
        _index.setQuery('');
        _syncIndex();
      }
    });
    if (next) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocusNode.requestFocus();
      });
    }
  }

  void _onSearchChanged(String value) {
    setState(() {
      _searchQuery = value;
      _matchCursor = 0;
      _index.setQuery(value);
      _syncIndex();
    });
    if (_index.matchCount > 0) {
      _logController.jumpToAbsoluteLine(_index.matchAt(0));
    }
  }

  void _stepMatch(int delta) {
    final count = _index.matchCount;
    if (count == 0) return;
    setState(() {
      _matchCursor = (_matchCursor + delta + count) % count;
    });
    _logController.jumpToAbsoluteLine(_index.matchAt(_matchCursor));
  }

  Future<void> _toggleNightTerminal() async {
    final next = !_nightTerminal;
    setState(() => _nightTerminal = next);
    await saveLogNightTerminalPreference(next);
  }

  Future<void> _toggleLineNumbers() async {
    final next = !_showLineNumbers;
    setState(() => _showLineNumbers = next);
    await saveLogShowLineNumbersPreference(next);
  }

  Future<void> _toggleSoftWrap() async {
    final next = !_softWrap;
    setState(() => _softWrap = next);
    await saveLogSoftWrapPreference(next);
  }

  void _copyAll() {
    final buf = widget.buffer;
    if (buf.isEmpty) return;
    Clipboard.setData(ClipboardData(text: buf.joinAll()));
    // 截断后内存里只有最近一部分，得说清楚复制到的不是全部。
    // 在点击这一刻现算：页面流式追加时不重建，传进来的文案可能是开页时的。
    final String msg;
    if (buf.droppedCount > 0) {
      final hint = widget.truncatedCopyHint?.trim() ?? '';
      msg = hint.isEmpty
          ? '已复制最近 ${buf.length} 行'
          : '已复制最近 ${buf.length} 行，$hint';
    } else {
      msg = widget.copySuccessToast ?? '日志已复制到剪贴板';
    }
    AppSnack.show(
      context,
      msg,
      tone: AppSnackTone.success,
      duration: const Duration(seconds: 2),
      replaceCurrent: true,
    );
  }

  void _jumpFirstError() {
    final line = _index.firstErrorLine;
    if (line == null) return;
    _logController.jumpToAbsoluteLine(line);
    AppSnack.show(
      context,
      '已定位至第 ${line + 1} 行报错输出',
      duration: const Duration(seconds: 2),
      replaceCurrent: true,
    );
  }

  Widget _buildStatusPill(LogSurfaceTheme logTheme, AppPalette logPalette) {
    final reduce = AppMotion.reduce(context);
    final (Color bg, Color ink) = switch (widget.statusTone) {
      FullscreenLogTone.running => (
        logPalette.tint(logPalette.accent),
        logPalette.accentInk,
      ),
      FullscreenLogTone.success => (
        logPalette.tint(logPalette.ok),
        logPalette.okInk,
      ),
      FullscreenLogTone.failed => (
        logPalette.tint(logPalette.err),
        logPalette.errInk,
      ),
      // 中性态的字用主前景色：次要灰压在 fill 上只有 3.3~3.7:1。
      FullscreenLogTone.neutral => (logPalette.fill, logTheme.foreground),
    };
    // 胶囊是半透明淡底叠在栏底上，按合成后的实色校一次对比度：
    // 深色栏底上钴蓝墨色只有 4.4:1，面板配了偏灰的底更低。
    final fg = logTheme.readable(
      ink,
      on: Color.alphaBlend(bg, logTheme.barBackground),
    );
    final Widget leading = switch (widget.statusTone) {
      FullscreenLogTone.running =>
        reduce
            ? Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: logPalette.accent,
                  shape: BoxShape.circle,
                ),
              )
            : FadeTransition(
                opacity: Tween<double>(begin: 0.35, end: 1.0).animate(
                  CurvedAnimation(
                    parent: _pulseController,
                    curve: Curves.easeInOut,
                  ),
                ),
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: logPalette.accent,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
      FullscreenLogTone.success => Icon(
        Icons.check_rounded,
        size: 14,
        color: fg,
      ),
      FullscreenLogTone.failed => Icon(
        Icons.close_rounded,
        size: 14,
        color: fg,
      ),
      FullscreenLogTone.neutral => Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          color: logTheme.mutedForeground,
          shape: BoxShape.circle,
        ),
      ),
    };

    return Container(
      key: const Key('fullscreen-log-status-pill'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          leading,
          const SizedBox(width: 5),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 96),
            child: Text(
              widget.statusLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: fg,
              ),
            ),
          ),
        ],
      ),
    );
  }

  PopupMenuItem<String> _buildToggleMenuItem({
    required String value,
    required IconData icon,
    required String label,
    required bool active,
    required AppPalette palette,
  }) {
    return PopupMenuItem<String>(
      value: value,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        leading: Icon(icon, size: 19),
        title: Text(label),
        trailing: active
            ? Icon(Icons.check_rounded, size: 18, color: palette.accent)
            : null,
      ),
    );
  }

  /// 顶栏副标题（「… · N 行」）。行数每来一行都变，只重建这一行字，
  /// 不拖着整页一起重建。
  Widget _buildSubtitle(LogSurfaceTheme logTheme) {
    return ListenableBuilder(
      listenable: widget.buffer,
      builder: (context, _) {
        final lineCount = widget.buffer.totalCount;
        final subParts = <String>[
          if (widget.subtitle != null && widget.subtitle!.trim().isNotEmpty)
            widget.subtitle!.trim(),
          if (lineCount > 0) '$lineCount 行',
        ];
        if (subParts.isEmpty) {
          return const SizedBox.shrink();
        }
        return Text(
          subParts.join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.tabular(
            TextStyle(fontSize: 11.5, color: logTheme.mutedForeground),
          ),
        );
      },
    );
  }

  Widget _buildHeader(
    LogSurfaceTheme logTheme,
    AppPalette logPalette, {
    required bool canToggleNight,
  }) {
    final palette = context.palette;

    return Container(
      constraints: const BoxConstraints(minHeight: 54),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: BoxDecoration(
        color: logTheme.barBackground,
        border: Border(bottom: BorderSide(color: logTheme.divider, width: 0.5)),
      ),
      child: Row(
        children: [
          AppBackButton(color: logTheme.foreground),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: logTheme.foreground,
                    letterSpacing: -0.15,
                  ),
                ),
                _buildSubtitle(logTheme),
              ],
            ),
          ),
          const SizedBox(width: 4),
          _buildStatusPill(logTheme, logPalette),
          // 三颗图标按钮紧挨着，每颗的命中区都撑满 44dp，免得想点搜索却切了暗底。
          SizedBox(
            width: AppTapTarget.min,
            height: AppTapTarget.min,
            child: IconButton(
              padding: EdgeInsets.zero,
              tooltip: '页内搜索',
              icon: Icon(
                _searchOpen ? Icons.search_off_rounded : Icons.search_rounded,
                size: 19,
                color: _searchOpen ? logPalette.accent : logTheme.foreground,
              ),
              onPressed: _toggleSearch,
            ),
          ),
          if (canToggleNight)
            SizedBox(
              width: AppTapTarget.min,
              height: AppTapTarget.min,
              child: IconButton(
                padding: EdgeInsets.zero,
                tooltip: _nightTerminal ? '恢复默认日志底色' : '切换护眼暗底终端',
                // 图标表示「点了会怎样」：月亮 = 切到暗底；
                // 太阳（强调色）= 已开启，点了恢复默认底色。
                icon: Icon(
                  _nightTerminal
                      ? Icons.light_mode_outlined
                      : Icons.dark_mode_outlined,
                  size: 18,
                  color: _nightTerminal
                      ? logPalette.accent
                      : logTheme.foreground,
                ),
                onPressed: _toggleNightTerminal,
              ),
            ),
          SizedBox(
            width: AppTapTarget.min,
            height: AppTapTarget.min,
            child: PopupMenuButton<String>(
              key: const Key('fullscreen-log-menu'),
              tooltip: '更多选项',
              // 下载原始日志、兜底查询任务都可能要几秒，菜单一关就看不见了，
              // 进度只能挂在 ⋮ 上。菜单照样能点开，复制等项不受影响。
              icon: widget.menuBusy
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: logTheme.foreground,
                      ),
                    )
                  : Icon(
                      Icons.more_vert,
                      size: 19,
                      color: logTheme.foreground,
                    ),
              padding: EdgeInsets.zero,
              itemBuilder: (_) => [
                _buildToggleMenuItem(
                  value: '_wrap',
                  icon: Icons.wrap_text_rounded,
                  label: '自动换行',
                  active: _softWrap,
                  palette: palette,
                ),
                _buildToggleMenuItem(
                  value: '_lines',
                  icon: Icons.format_list_numbered_rounded,
                  label: '显示行号',
                  active: _showLineNumbers,
                  palette: palette,
                ),
                _buildToggleMenuItem(
                  value: '_night',
                  icon: Icons.dark_mode_outlined,
                  label: '独立护眼暗底 (#14161A)',
                  active: _nightTerminal,
                  palette: palette,
                ),
                if (widget.buffer.isNotEmpty)
                  PopupMenuItem<String>(
                    value: '_copy',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: const Icon(Icons.copy_rounded, size: 19),
                      title: Text(
                        widget.buffer.droppedCount > 0
                            ? '复制最近 ${widget.buffer.length} 行'
                            : '复制全部',
                      ),
                    ),
                  ),
                if (widget.extraMenuEntries.isNotEmpty)
                  const PopupMenuDivider(),
                for (final item in widget.extraMenuEntries)
                  if (item.checked != null)
                    CheckedPopupMenuItem<String>(
                      value: item.id,
                      enabled: item.enabled,
                      checked: item.checked!,
                      child: Text(item.label),
                    )
                  else
                    PopupMenuItem<String>(
                      value: item.id,
                      enabled: item.enabled,
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        leading: item.icon == null
                            ? null
                            : Icon(item.icon, size: 19),
                        title: Text(item.label),
                      ),
                    ),
              ],
              onSelected: (value) async {
                switch (value) {
                  case '_wrap':
                    await _toggleSoftWrap();
                  case '_lines':
                    await _toggleLineNumbers();
                  case '_night':
                    await _toggleNightTerminal();
                  case '_copy':
                    _copyAll();
                  default:
                    for (final item in widget.extraMenuEntries) {
                      if (item.id == value) {
                        await item.onTap();
                        break;
                      }
                    }
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(LogSurfaceTheme logTheme, AppPalette logPalette) {
    final hasQuery = _index.query.isNotEmpty;
    final count = _index.matchCount;
    final countLabel = !hasQuery
        ? ''
        : count == 0
        ? '无匹配'
        : '${_matchCursor + 1}/$count';
    // 输入框是半透明 fill 叠在栏底上，次要灰直接压上去只有 3.3~3.7:1。
    final fieldBg = Color.alphaBlend(logPalette.fill, logTheme.barBackground);
    final hintColor = logTheme.readable(logTheme.mutedForeground, on: fieldBg);
    final noMatchColor = logTheme.readable(logPalette.errInk, on: fieldBg);
    // VisualDensity.compact 是 48→40，不够 44；(-1, -1) 正好 44。
    const buttonDensity = VisualDensity(horizontal: -1, vertical: -1);

    return Container(
      constraints: const BoxConstraints(minHeight: 46),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: logTheme.barBackground,
        border: Border(bottom: BorderSide(color: logTheme.divider, width: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: logPalette.fill,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Row(
                children: [
                  Icon(Icons.search_rounded, size: 16, color: hintColor),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      focusNode: _searchFocusNode,
                      onChanged: _onSearchChanged,
                      style: TextStyle(
                        fontSize: 13,
                        color: logTheme.foreground,
                      ),
                      decoration: InputDecoration(
                        hintText: '在全屏日志中搜索关键字...',
                        hintStyle: TextStyle(fontSize: 13, color: hintColor),
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                  if (countLabel.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Text(
                        countLabel,
                        key: const Key('fullscreen-log-search-count'),
                        style: AppText.tabular(
                          TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w500,
                            color: count == 0 ? noMatchColor : hintColor,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            visualDensity: buttonDensity,
            tooltip: '上一处匹配',
            icon: Icon(
              Icons.keyboard_arrow_up_rounded,
              size: 20,
              color: count == 0
                  ? logTheme.mutedForeground.withAlpha(90)
                  : logTheme.foreground,
            ),
            onPressed: count == 0 ? null : () => _stepMatch(-1),
          ),
          IconButton(
            visualDensity: buttonDensity,
            tooltip: '下一处匹配',
            icon: Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 20,
              color: count == 0
                  ? logTheme.mutedForeground.withAlpha(90)
                  : logTheme.foreground,
            ),
            onPressed: count == 0 ? null : () => _stepMatch(1),
          ),
          IconButton(
            visualDensity: buttonDensity,
            tooltip: '关闭搜索',
            icon: Icon(
              Icons.close_rounded,
              size: 18,
              color: logTheme.mutedForeground,
            ),
            onPressed: _toggleSearch,
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner(
    LogSurfaceTheme logTheme,
    AppPalette logPalette,
    String message,
  ) {
    final bg = Color.alphaBlend(
      logPalette.tint(logPalette.err),
      logTheme.background,
    );
    final fg = logTheme.readable(logPalette.errInk, on: bg);
    return Semantics(
      liveRegion: true,
      child: Container(
        key: const Key('fullscreen-log-error-banner'),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          border: Border(
            bottom: BorderSide(color: logTheme.divider, width: 0.5),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(Icons.error_outline_rounded, size: 16, color: fg),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: TextStyle(fontSize: 13, height: 1.45, color: fg),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFooter(LogSurfaceTheme logTheme, AppPalette logPalette) {
    final buf = widget.buffer;
    final bar = logTheme.barBackground;
    final errBg = logPalette.tint(logPalette.err);
    final errFg = logTheme.readable(
      logPalette.errInk,
      on: Color.alphaBlend(errBg, bar),
    );
    final fillFg = logTheme.readable(
      logTheme.foreground,
      on: Color.alphaBlend(logPalette.fill, bar),
    );

    _PrimaryThumbButton? primary;
    if (widget.onStop != null) {
      primary = _PrimaryThumbButton(
        key: const Key('fullscreen-log-stop'),
        label: widget.stopLabel,
        icon: Icons.stop_rounded,
        bg: errBg,
        fg: errFg,
        busy: widget.stopBusy,
        onTap: widget.onStop,
      );
    } else if (widget.onRerun != null) {
      primary = _PrimaryThumbButton(
        key: const Key('fullscreen-log-rerun'),
        label: widget.rerunLabel,
        icon: Icons.play_arrow_rounded,
        bg: logPalette.primaryBtnBg,
        fg: logPalette.primaryBtnFg,
        busy: widget.rerunBusy,
        onTap: widget.onRerun,
      );
    }

    final firstError = _index.firstErrorLine == null
        ? null
        : _FooterChip(
            key: const Key('fullscreen-log-first-error'),
            label: '首处报错',
            icon: Icons.vertical_align_top_rounded,
            fg: errFg,
            bg: errBg,
            onTap: _jumpFirstError,
          );
    final copy = buf.isEmpty
        ? null
        : _FooterChip(
            key: const Key('fullscreen-log-copy'),
            label: buf.droppedCount > 0 ? '复制最近 ${buf.length} 行' : '复制全部',
            icon: Icons.copy_rounded,
            fg: fillFg,
            bg: logPalette.fill,
            onTap: _copyAll,
          );
    final openScript = widget.onOpenScript == null
        ? null
        : _FooterChip(
            key: const Key('fullscreen-log-open-script'),
            label: '跳脚本',
            icon: Icons.code_rounded,
            fg: fillFg,
            bg: logPalette.fill,
            busy: widget.openScriptBusy,
            onTap: widget.openScriptBusy ? null : widget.onOpenScript,
          );

    if (primary == null &&
        firstError == null &&
        copy == null &&
        openScript == null) {
      return const SizedBox.shrink();
    }

    return Container(
      decoration: BoxDecoration(
        color: logTheme.barBackground,
        border: Border(top: BorderSide(color: logTheme.divider, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          // 按钮命中区撑到 44 之后上下内边距收到 5，底栏总高与改前（38 + 8×2）一致。
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
          child: LayoutBuilder(
            builder: (context, constraints) => _buildFooterRow(
              context,
              constraints.maxWidth,
              primary: primary,
              firstError: firstError,
              copy: copy,
              openScript: openScript,
            ),
          ),
        ),
      ),
    );
  }

  /// 底栏一行：左边主按钮，右边一排工具芯片。
  ///
  /// 360dp 屏上「停止运行 + 首处报错 + 复制全部 + 跳脚本」带字要 ~400dp，
  /// 放不下的那一截看得见却点不中（以前还会把「首处报错」整颗挤出左边）。
  /// 按当前字号量出带字形态多宽，由宽到窄逐档退：
  /// 复制 / 跳脚本缩成只剩图标 → 底栏不放「复制」（⋮ 菜单里还有）→
  /// 「首处报错」也缩成图标。「首处报错」只有底栏这一个入口，始终留在屏幕上。
  Widget _buildFooterRow(
    BuildContext context,
    double maxWidth, {
    required _PrimaryThumbButton? primary,
    required _FooterChip? firstError,
    required _FooterChip? copy,
    required _FooterChip? openScript,
  }) {
    final primaryWidth = primary == null
        ? 0.0
        : _PrimaryThumbButton.fullWidth(context, primary.label) + _footerGap;
    double widthOf(_FooterChip chip, bool compact) => compact
        ? AppTapTarget.min
        : _UtilityThumbChip.fullWidth(context, chip.label);

    // 每一档：(首处报错缩图标, 复制缩图标, 底栏不放复制, 跳脚本缩图标)
    const plans = [
      (false, false, false, false),
      (false, true, false, true),
      (false, true, true, true),
      (true, true, true, true),
    ];
    var chosen = <(_FooterChip, bool)>[];
    var fits = false;
    for (final (errCompact, copyCompact, copyHidden, scriptCompact) in plans) {
      chosen = [
        if (firstError != null) (firstError, errCompact),
        if (copy != null && !copyHidden) (copy, copyCompact),
        if (openScript != null) (openScript, scriptCompact),
      ];
      var width = primaryWidth;
      for (final (chip, compact) in chosen) {
        width += widthOf(chip, compact);
      }
      width += _footerGap * math.max(0, chosen.length - 1);
      if (width <= maxWidth) {
        fits = true;
        break;
      }
    }

    final chipChildren = <Widget>[
      for (final (i, (chip, compact)) in chosen.indexed) ...[
        if (i > 0) const SizedBox(width: _footerGap),
        chip.build(compact: compact),
      ],
    ];
    final chipRow = Row(mainAxisSize: MainAxisSize.min, children: chipChildren);

    return Row(
      children: [
        ?primary,
        if (primary != null && chipChildren.isNotEmpty)
          const SizedBox(width: _footerGap),
        if (chipChildren.isNotEmpty)
          Expanded(
            child: fits
                ? Align(alignment: Alignment.centerRight, child: chipRow)
                // 字号放到极大时最窄一档也放不下，才退成横向滚动；
                // 从左往右排，「首处报错」在最左、初始就看得见。
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: chipRow,
                  ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    _builtSignature = _bufferSignature();
    final themeBrightness = Theme.of(context).brightness;
    final logTheme = resolveLogSurfaceTheme(
      widget.configuredBackgroundColor,
      themeBrightness: themeBrightness,
      forceNightTerminal: _nightTerminal,
    );
    // 底色本来就是深色时（深色主题且面板没配色，或面板配了深底），顶栏的
    // 「护眼暗底」一键切不出任何变化，只会悄悄存一个影响浅色主题的偏好，
    // 所以不显示。⋮ 菜单里的同名开关保留，作为全局偏好。
    final canToggleNight = !resolveLogSurfaceTheme(
      widget.configuredBackgroundColor,
      themeBrightness: themeBrightness,
    ).isDark;
    final logPalette = logTheme.isDark ? AppPalette.dark : AppPalette.light;
    final activeMatchLine = _index.matchCount == 0
        ? null
        : _index.matchAt(_matchCursor);
    final errorMessage = widget.errorMessage?.trim() ?? '';

    final overlayStyle = logTheme.isDark
        ? SystemUiOverlayStyle.light
        : SystemUiOverlayStyle.dark;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: Scaffold(
        backgroundColor: logTheme.background,
        body: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(
                logTheme,
                logPalette,
                canToggleNight: canToggleNight,
              ),
              if (_searchOpen) _buildSearchBar(logTheme, logPalette),
              if (errorMessage.isNotEmpty)
                _buildErrorBanner(logTheme, logPalette, errorMessage),
              Expanded(
                child: ColoredBox(
                  color: logTheme.background,
                  child: widget.loading && widget.buffer.isEmpty
                      ? Center(
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: logPalette.accent,
                          ),
                        )
                      : widget.buffer.isEmpty
                      ? Center(
                          child: Text(
                            widget.emptyMessage,
                            style: TextStyle(
                              fontSize: 13.5,
                              color: logTheme.mutedForeground,
                            ),
                          ),
                        )
                      : LogView(
                          controller: _logController,
                          buffer: widget.buffer,
                          follow: widget.follow,
                          showLineNumbers: _showLineNumbers,
                          softWrap: _softWrap,
                          searchQuery: _searchQuery,
                          activeMatchAbsoluteLine: activeMatchLine,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          textStyle: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12.5,
                            height: 1.58,
                            color: logTheme.foreground,
                          ),
                          brightness: logTheme.brightness,
                          mutedColor: logTheme.mutedForeground,
                          truncatedHint: widget.truncatedHint,
                          truncatedActionLabel: widget.truncatedActionLabel,
                          onTruncatedAction: widget.onTruncatedAction,
                        ),
                ),
              ),
              _buildFooter(logTheme, logPalette),
            ],
          ),
        ),
      ),
    );
  }
}

class _PrimaryThumbButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color bg;
  final Color fg;
  final bool busy;
  final VoidCallback? onTap;

  const _PrimaryThumbButton({
    super.key,
    required this.label,
    required this.icon,
    required this.bg,
    required this.fg,
    required this.busy,
    required this.onTap,
  });

  static const TextStyle _labelStyle = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
  );

  /// 按当前字号量出要占多宽（底栏据此决定芯片要不要缩成图标）。
  static double fullWidth(BuildContext context, String label) =>
      14 * 2 + 16 + 6 + measureTextWidth(context, label, _labelStyle) + 1;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        onTap: busy ? null : onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppTapTarget.min),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (busy)
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: fg,
                    ),
                  )
                else
                  Icon(icon, size: 16, color: fg),
                const SizedBox(width: 6),
                Text(label, style: _labelStyle.copyWith(color: fg)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UtilityThumbChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color fg;
  final Color bg;
  final VoidCallback? onTap;

  /// 慢操作在跑（如老面板上兜底查任务列表）：图标换成小转圈。
  final bool busy;

  /// 只显示图标（文字进 tooltip），缩成 44dp 见方。底栏放不下带字形态时用。
  final bool compact;

  const _UtilityThumbChip({
    super.key,
    required this.label,
    required this.icon,
    required this.fg,
    required this.bg,
    required this.onTap,
    this.busy = false,
    this.compact = false,
  });

  static const TextStyle _labelStyle = TextStyle(
    fontSize: 12.5,
    fontWeight: FontWeight.w500,
  );

  /// 带字形态按当前字号要占多宽。
  static double fullWidth(BuildContext context, String label) =>
      11 * 2 + 15 + 5 + measureTextWidth(context, label, _labelStyle) + 1;

  @override
  Widget build(BuildContext context) {
    final Widget leading = busy
        ? SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: fg),
          )
        : Icon(icon, size: 15, color: fg);
    final chip = Material(
      color: bg,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: compact
            ? SizedBox(
                width: AppTapTarget.min,
                height: AppTapTarget.min,
                child: Center(child: leading),
              )
            : ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: AppTapTarget.min,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      leading,
                      const SizedBox(width: 5),
                      Text(label, style: _labelStyle.copyWith(color: fg)),
                    ],
                  ),
                ),
              ),
      ),
    );
    // 同 AppChipButton：只有缩成图标时文字才进 Tooltip。带字形态再套一层，
    // TalkBack 会把同一句读两遍，长按还会弹出一模一样的提示。
    return compact ? Tooltip(message: label, child: chip) : chip;
  }
}
