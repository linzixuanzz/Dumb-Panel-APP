import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';

/// 分段控件（方案书 §2.4）：灰色胶囊底槽，选中块是白色滑块，切换时弹簧滑过去。
/// 用在概览（全部 / 定时 / 手动）、图表切换（每周 / 月度 / 年度）。
///
/// ```dart
/// AppSegmented<String>(
///   segments: const [('all', '全部'), ('cron', '定时'), ('manual', '手动')],
///   value: _mode,
///   onChanged: (v) => setState(() => _mode = v),
/// )
/// ```
///
/// 宽度撑满父级，各段等分。系统开了「移除动画」时滑块直接跳。
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

  static const double _height = 44;
  static const double _inset = 4;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final selected = segments.indexWhere((s) => s.$1 == value);

    return Container(
      height: _height,
      padding: const EdgeInsets.all(_inset),
      decoration: BoxDecoration(
        color: palette.fill,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth / segments.length;
          return Stack(
            children: [
              // 选中滑块。value 不在 segments 里时不画（不假装选中了某一段）。
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
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      // 浅色下白滑块压在浅灰底槽上，要一点投影才分得开
                      boxShadow: palette.isLight
                          ? const [
                              BoxShadow(
                                color: Color(0x1F000000),
                                blurRadius: 8,
                                offset: Offset(0, 2),
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
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: palette.text,
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
