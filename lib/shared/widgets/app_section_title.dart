import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';

/// 区块小标题（设置类页面里「版本信息」「系统操作」这种）。
///
/// 收敛 `system_settings_page.dart` 的 `_SectionTitle` 与
/// `more_page.dart` 的 `_SectionLabel` —— 两者只差一个 `bottom: 4`。
class AppSectionTitle extends StatelessWidget {
  final String text;
  final EdgeInsetsGeometry padding;

  const AppSectionTitle(
    this.text, {
    super.key,
    this.padding = const EdgeInsets.only(left: 2, bottom: 4),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Text(
        text,
        // v2.0：iOS 分组列表头的样式（说明字号、次要色、不加字距）。
        style: AppText.caption.copyWith(
          fontWeight: FontWeight.w500,
          color: context.palette.text2,
        ),
      ),
    );
  }
}
