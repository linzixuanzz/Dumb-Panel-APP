import 'package:flutter/material.dart';

import '../../../core/theme/design_tokens.dart';
import '../../../shared/widgets/app_card.dart';

/// 编辑器上方的常驻查找条。
///
/// ── 为什么不是弹窗 ────────────────────────────────────────────────────────
/// 改造前查找是 `showModalBottomSheet(isScrollControlled: true, showDragHandle: true)`
/// 配 `autofocus: true`，三件事叠在一起：modal 的遮罩压暗整个编辑区、键盘再把面板
/// 顶高一截、而「上一个 / 下一个」又不 pop —— 用户整个查找过程都看不到编辑器，
/// 跳没跳都不知道。这就是 issue #6 (d)「搜索弹窗占屏幕比例过大，遮挡内容」。
///
/// 常驻条贴在编辑器卡片**外面的上方**：既满足「编辑框外」，又一行代码都不遮
/// （浮在编辑区右上角反而会盖住正文）。形态与面板 Web 的 `search({ top: true })` 一致。
class ScriptFindBar extends StatelessWidget {
  const ScriptFindBar({
    super.key,
    required this.controller,
    required this.matchCount,
    required this.currentIndex,
    required this.truncated,
    required this.onChanged,
    required this.onPrevious,
    required this.onNext,
    required this.onClose,
  });

  final TextEditingController controller;

  /// 已记录的命中数。上限见 `kScriptSearchMatchLimit`。
  final int matchCount;

  /// 当前停在第几个，从 0 开始；-1 表示还没有命中。
  final int currentIndex;

  /// 命中数触顶被截断，计数显示成 `500+`。
  final bool truncated;

  final ValueChanged<String> onChanged;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final surfaces = context.surfaces;
    final hasMatch = matchCount > 0;
    final total = truncated ? '$matchCount+' : '$matchCount';
    final counter = controller.text.isEmpty
        ? ''
        : (hasMatch ? '${currentIndex + 1}/$total' : '无结果');

    return AppCard(
      margin: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      padding: EdgeInsets.zero,
      radius: AppRadius.md,
      // 不画描边：加上之后 Container 会把描边宽度并进内边距，整条高度变成 46，
      // 越过 AppTapTarget.min 这条「查找条不许比一个按钮更高」的线。
      bordered: false,
      // ⚠️ 底色**不能**跟编辑器走：editor_background_color 是用户在面板里自定义的，
      // 跟着走随时可能糊成一片。面板 Web 的搜索面板同样刻意不跟编辑器底色。
      color: surfaces.card,
      child: SizedBox(
        height: AppTapTarget.min,
        child: Row(
          children: [
            const SizedBox(width: AppSpacing.md),
            Icon(Icons.search, size: 16, color: surfaces.mutedText),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: TextField(
                controller: controller,
                autofocus: true,
                textInputAction: TextInputAction.search,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  hintText: '查找代码',
                  hintStyle: TextStyle(fontSize: 13, color: surfaces.mutedText),
                ),
                onChanged: onChanged,
                onSubmitted: (_) => onNext(),
              ),
            ),
            if (counter.isNotEmpty) ...[
              const SizedBox(width: AppSpacing.xs),
              Text(
                counter,
                style: TextStyle(fontSize: 12, color: surfaces.mutedText),
              ),
            ],
            _FindBarButton(
              icon: Icons.keyboard_arrow_up,
              tooltip: '上一个',
              onTap: hasMatch ? onPrevious : null,
            ),
            _FindBarButton(
              icon: Icons.keyboard_arrow_down,
              tooltip: '下一个',
              onTap: hasMatch ? onNext : null,
            ),
            _FindBarButton(
              icon: Icons.close,
              tooltip: '关闭查找',
              onTap: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

/// 查找条上的图标按钮。
///
/// 命中区靠 [AppTapTarget.min] 的**约束**撑到 44，图标视觉尺寸仍是 20 ——
/// 用 padding 撑会连带把整条查找条顶高。
class _FindBarButton extends StatelessWidget {
  const _FindBarButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final surfaces = context.surfaces;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: AppTapTarget.min,
          height: AppTapTarget.min,
          child: Icon(
            icon,
            size: 20,
            color: onTap == null ? surfaces.disabledFg : surfaces.strongText,
          ),
        ),
      ),
    );
  }
}
