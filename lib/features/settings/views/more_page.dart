import 'package:flutter/material.dart';

import 'settings_page.dart';

/// v1.x 的「更多」页。
///
/// v2.0 起内容全部迁进「设置」Tab（[SettingsPage]），路由 `/more` 也重定向到 `/settings`。
/// 这里只留一个转发，免得仍按旧名引用它的地方（既有测试）跟着改。
class MorePage extends StatelessWidget {
  const MorePage({super.key});

  @override
  Widget build(BuildContext context) => const SettingsPage();
}
