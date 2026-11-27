import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/design_tokens.dart';

/// 「按住运行」安全防误触按钮（v3.0 Nordic Calm：克制钴蓝胶囊 + 平滑进度填充）。
///
/// [width] / [height] 是名义尺寸；外面给紧约束时（嵌进 `NotchedCard` 的缺口）
/// 以实际拿到的尺寸为准，图标圆按实际高度算、上下居中，不会被拉歪。
class HoldToRunButton extends StatefulWidget {
  final String label;
  final VoidCallback onConfirmed;
  final Duration holdDuration;
  final bool enabled;
  final IconData icon;
  final double width;
  final double height;

  /// 外形圆角，默认胶囊。与 `AppPillButton`（[AppRadius.md]）同处一个位置、
  /// 状态一变就互相替换时传 [AppRadius.md]，免得外形来回跳（常用任务卡缺口）。
  final double radius;

  const HoldToRunButton({
    super.key,
    required this.label,
    required this.onConfirmed,
    this.holdDuration = const Duration(milliseconds: 700),
    this.enabled = true,
    this.icon = Icons.play_arrow_rounded,
    this.width = 164,
    this.height = 46,
    this.radius = AppRadius.pill,
  });

  @override
  State<HoldToRunButton> createState() => _HoldToRunButtonState();
}

class _HoldToRunButtonState extends State<HoldToRunButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progress = AnimationController(
    vsync: this,
    duration: widget.holdDuration,
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
    _progress.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final reduce = AppMotion.reduce(context);
    final bg = palette.primaryBtnBg;
    final fg = palette.primaryBtnFg;

    final pill = Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(widget.radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 按实际高度算：缺口给的 70dp 紧约束会把名义 46 撑高
          final height = constraints.maxHeight.isFinite
              ? constraints.maxHeight
              : widget.height;
          final iconSize = (height - 14).clamp(24.0, 38.0);
          // 图标圆离左边与离上下一样远：胶囊时与左端半圆同心
          final inset = ((height - iconSize) / 2).clamp(0.0, double.infinity);
          return Stack(
            alignment: AlignmentDirectional.centerStart,
            children: [
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: _progress,
                  builder: (context, _) => FractionallySizedBox(
                    key: const Key('hold-to-run-progress'),
                    alignment: Alignment.centerLeft,
                    widthFactor: _progress.value,
                    child: ColoredBox(color: fg.withValues(alpha: 0.24)),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: inset),
                child: Row(
                  children: [
                    Container(
                      key: const Key('hold-to-run-icon'),
                      width: iconSize,
                      height: iconSize,
                      decoration: BoxDecoration(
                        color: fg.withValues(alpha: 0.96),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        widget.icon,
                        size: iconSize * 0.56,
                        color: bg,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          color: fg,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );

    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.label,
      hint:
          '按住 ${(widget.holdDuration.inMilliseconds / 1000).toStringAsFixed(1)} 秒确认',
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
