import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';

/// 分段切换控件（v3.0 Nordic Calm：38dp 轻盈圆角槽、13pt w500/w600 克制滑块）。
///
/// 看得见的底槽是 38dp，但整个控件占 44dp（[AppTapTarget.min]）：
/// 每段的点按区铺满这 44dp 的整个高度，底槽和滑块只在绘制层内缩。
/// 命中区用约束补、视觉不变（component-guidelines「可点区域」）。
class AppSegmented<T> extends StatelessWidget {
  final List<(T, String)> segments;
  final T value;
  final ValueChanged<T> onChanged;

  const AppSegmented({
    super.key,
    required this.segments,
    required this.value,
    required this.onChanged,
  });

  /// 底槽的视觉高度。
  static const double trackHeight = 38;

  /// 滑块与底槽边缘的间距。
  static const double _inset = 3;

  /// 底槽在 44dp 命中区里上下各让出的距离。
  static const double _trackOffset = (AppTapTarget.min - trackHeight) / 2;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final selected = segments.indexWhere((s) => s.$1 == value);

    return SizedBox(
      height: AppTapTarget.min,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 底槽：只负责画，命中区不受它的高度限制
          Padding(
            padding: const EdgeInsets.symmetric(vertical: _trackOffset),
            child: DecoratedBox(
              key: const Key('app-segmented-track'),
              decoration: BoxDecoration(
                color: palette.card2,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: _inset),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth / segments.length;
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    if (selected >= 0)
                      AnimatedPositioned(
                        duration: AppMotion.of(context, AppMotion.slide),
                        curve: AppMotion.spring,
                        left: width * selected,
                        top: _trackOffset + _inset,
                        bottom: _trackOffset + _inset,
                        width: width,
                        child: DecoratedBox(
                          key: const Key('app-segmented-thumb'),
                          decoration: BoxDecoration(
                            color: palette.thumb,
                            // 与底槽同心：外圈圆角减去内缩
                            borderRadius: BorderRadius.circular(
                              AppRadius.md - _inset,
                            ),
                            boxShadow: palette.isLight
                                ? const [
                                    BoxShadow(
                                      color: Color(0x140F172A),
                                      blurRadius: 6,
                                      offset: Offset(0, 1.5),
                                    ),
                                  ]
                                : null,
                          ),
                        ),
                      ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < segments.length; i++)
                          Expanded(
                            child: Semantics(
                              button: true,
                              selected: i == selected,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () {
                                  if (i != selected) {
                                    onChanged(segments[i].$1);
                                  }
                                },
                                child: Center(
                                  child: Text(
                                    segments[i].$2,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: i == selected
                                          ? FontWeight.w600
                                          : FontWeight.w500,
                                      color: i == selected
                                          ? palette.text
                                          : palette.text2,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
