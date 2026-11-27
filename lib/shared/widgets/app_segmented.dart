import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';

/// 分段切换控件（v3.0 Nordic Calm：38dp 轻盈圆角槽、13pt w500/w600 克制滑块）。
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

  static const double _height = 38;
  static const double _inset = 3;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final selected = segments.indexWhere((s) => s.$1 == value);

    return Container(
      height: _height,
      padding: const EdgeInsets.all(_inset),
      decoration: BoxDecoration(
        color: palette.card2,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth / segments.length;
          return Stack(
            children: [
              if (selected >= 0)
                AnimatedPositioned(
                  duration: AppMotion.of(context, AppMotion.slide),
                  curve: AppMotion.spring,
                  left: width * selected,
                  top: 0,
                  bottom: 0,
                  width: width,
                  child: DecoratedBox(
                    key: const Key('app-segmented-thumb'),
                    decoration: BoxDecoration(
                      color: palette.thumb,
                      borderRadius: BorderRadius.circular(9),
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
                children: [
                  for (var i = 0; i < segments.length; i++)
                    Expanded(
                      child: Semantics(
                        button: true,
                        selected: i == selected,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            if (i != selected) onChanged(segments[i].$1);
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
    );
  }
}
