import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// 带搜索高亮的编辑器 controller：全部命中弱高亮 + 当前命中强高亮。
///
/// ── 为什么是改 controller，而不是换编辑器控件 ────────────────────────────
/// 原生 `TextField` 底下的 `RenderEditable` 只挂了一个选区 painter，一次只能画
/// 一段 range，而且 collapsed 的 range 会被直接 return。所以「同时画出所有命中」
/// 走 selection 那条路根本不成立 —— 改造前那个「把选区染成琥珀色 2 秒」的 hack
/// 就是这么来的，而且因为 selection 每帧被 `controller.text =` 抹掉，它连那 2 秒
/// 都留不住。
///
/// 但 `TextEditingController.buildTextSpan` 是 Flutter **官方开放**的 override
/// 钩子（`EditableTextState.build` 每次都会调它）。按命中区间切片返回带
/// `backgroundColor` 的 TextSpan 树，就能在**完全不动 TextField** 的前提下画出
/// 双档高亮：原生长按选择、系统文本菜单、选择手柄一个都不会丢。
/// 面板 Web 从 Monaco 换 CodeMirror 时刻意保住的正是这三条，APP 端更不能丢。
class ScriptHighlightController extends TextEditingController {
  List<int> _matchOffsets = const [];
  int _currentMatch = -1;
  int _matchLength = 0;

  /// 更新命中区间。
  ///
  /// **必须在页面自己的 `setState` 里调用**：这里刻意不 `notifyListeners()` ——
  /// 监听者是 `EditableText`，它收到通知会立刻 setState，等于在页面 setState 的
  /// 过程里又去戳子树重建。页面 setState 本身就会让 TextField 重建、重新问一次
  /// [buildTextSpan]，够了。
  void updateMatches({
    required List<int> offsets,
    required int current,
    required int length,
  }) {
    _matchOffsets = offsets;
    _currentMatch = current;
    _matchLength = length;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final source = text;
    if (_matchOffsets.isEmpty || _matchLength <= 0) {
      // 没有命中就原样交回父类：输入法组合下划线等默认行为一并保留。
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    final children = <TextSpan>[];
    var cursor = 0;
    for (var i = 0; i < _matchOffsets.length; i++) {
      final start = _matchOffsets[i];
      final end = start + _matchLength;
      // 命中区间是上一次搜索时算的。编辑模式下用户敲下一个字符，controller 先变、
      // 重算晚一步，这里就会拿到越界的下标 —— 必须当场停住，
      // 否则 substring 抛 RangeError 会把整个编辑器打崩。
      if (start < cursor || end > source.length) {
        break;
      }
      if (start > cursor) {
        children.add(TextSpan(text: source.substring(cursor, start)));
      }
      children.add(
        TextSpan(
          text: source.substring(start, end),
          style: TextStyle(
            backgroundColor: i == _currentMatch
                ? AppColors.searchMatchCurrent
                : AppColors.searchMatch,
          ),
        ),
      );
      cursor = end;
    }

    if (children.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    if (cursor < source.length) {
      children.add(TextSpan(text: source.substring(cursor)));
    }
    // 有高亮时不画输入法组合下划线：中文输入正好落在命中词上时会短暂看不到候选
    // 下划线，比起「高亮画不出来」这是可以接受的取舍。
    return TextSpan(style: style, children: children);
  }
}
