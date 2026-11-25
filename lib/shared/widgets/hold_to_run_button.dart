import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/design_tokens.dart';

/// 「按住运行」（方案书 §2.2 第 5 条、PRD A2）：危险操作要按住，不是点一下。
///
/// - 按下后胶囊里的进度条从左到右走 [holdDuration]（默认 0.7 秒），走满才触发
///   [onConfirmed]，同时 `HapticFeedback.mediumImpact` 轻振一下；
/// - 中途松手（或手指滑走、被横向滑动的卡片抢走手势）进度条回弹，**不触发**；
/// - 系统开了「移除动画」时进度条照常走（这是功能，不是装饰），只是不做按下缩小；
/// - 读屏用户：长按动作（双击并按住）直接确认。
///
/// 外观是主按钮的黑色胶囊（深色白色），左边一个反色圆里放图标。
class HoldToRunButton extends StatefulWidget {
  final String label;
  final VoidCallback onConfirmed;
  final Duration holdDuration;
  final bool enabled;
  final IconData icon;

  /// 默认与效果演示一致：196 × 70，正好嵌进 `NotchedCard` 的默认缺口。
  final double width;
  final double height;

  const HoldToRunButton({
    super.key,
    required this.label,
    required this.onConfirmed,
    this.holdDuration = const Duration(milliseconds: 700),
    this.enabled = true,
    this.icon = Icons.play_arrow_rounded,
    this.width = 196,
    this.height = 70,
  });

  @override
  State<HoldToRunButton> createState() => _HoldToRunButtonState();
}

class _HoldToRunButtonState extends State<HoldToRunButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progress = AnimationController(
    vsync: this,
    duration: widget.holdDuration,
    // 松手回弹比走满快得多
    reverseDuration: AppMotion.normal,
  )..addStatusListener(_onStatus);

  bool _holding = false;

  @override
  void didUpdateWidget(HoldToRunButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _progress.duration = widget.holdDuration;
    if (!widget.enabled && _holding) _cancel();
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    // 走满：轻振 + 触发，然后复位（手指可能还按着，松手时不会再触发一次）
    HapticFeedback.mediumImpact();
    setState(() => _holding = false);
    _progress.value = 0;
    widget.onConfirmed();
  }

  void _start() {
    if (!widget.enabled) return;
    setState(() => _holding = true);
    _progress.forward(from: _progress.value);
  }

  void _cancel() {
    if (!_holding) return;
    setState(() => _holding = false);
    // 还没走满：回弹到 0，不触发
    _progress.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final reduce = AppMotion.reduce(context);
    final bg = palette.primaryBtnBg;
    final fg = palette.primaryBtnFg;
    final iconSize = widget.height - 16;

    final pill = Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // 进度条：前景色 22% 的一层，从左往右铺
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _progress,
              builder: (context, _) => FractionallySizedBox(
                key: const Key('hold-to-run-progress'),
                alignment: Alignment.centerLeft,
                widthFactor: _progress.value,
                child: ColoredBox(color: fg.withValues(alpha: 0.22)),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Container(
                  width: iconSize,
                  height: iconSize,
                  decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
                  child: Icon(widget.icon, size: iconSize * 0.55, color: bg),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 17.5,
                      fontWeight: FontWeight.w800,
                      color: fg,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.label,
      hint: '按住 ${(widget.holdDuration.inMilliseconds / 1000).toStringAsFixed(1)} 秒确认',
      onLongPress: widget.enabled ? widget.onConfirmed : null,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: widget.enabled ? (_) => _start() : null,
        onTapUp: widget.enabled ? (_) => _cancel() : null,
        onTapCancel: widget.enabled ? _cancel : null,
        child: AnimatedScale(
          scale: _holding && !reduce ? 0.97 : 1,
          duration: AppMotion.of(context, AppMotion.fast),
          child: Opacity(opacity: widget.enabled ? 1 : 0.4, child: pill),
        ),
      ),
    );
  }
}
