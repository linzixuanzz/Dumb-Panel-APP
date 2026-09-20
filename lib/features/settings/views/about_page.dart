import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/widgets/app_back_button.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/app_section_title.dart';
import '../../../shared/widgets/app_snack.dart';

// 关于页用到的外链。APP 与面板是**两个仓库**，别混（issue #12 / v1.3.7）。
// 只有这一个页面用，按 spec/frontend/directory-structure.md:39-40
// 「是否有 2 个以上 feature 会用？否则放进对应 feature」写成文件级私有 const，
// 不新开 lib/core/constants/。也不要和 app_update_service.dart:12 的 _kGitHubRepo 合并——
// 那个是喂给 api.github.com 的 owner/repo 片段，不是网页地址。
const _kAuthorHome = 'https://github.com/linzixuanzz';
const _kAppRepo = 'https://github.com/linzixuanzz/Dumb-Panel-APP';
const _kPanelRepo = 'https://github.com/linzixuanzz/daidai-panel';
const _kAppIssues = '$_kAppRepo/issues';
const _kPanelIssues = '$_kPanelRepo/issues';

// GitHub 官方头像短链，免调 API。size=128 是为了在 2x/3x 屏上不糊。
const _kAuthorAvatar = '$_kAuthorHome.png?size=128';

// 打开外链复用「内置安装」那条 MethodChannel 的 openUrl 分支（原生侧 MainActivity.kt）。
// 仓库目前零 url_launcher 依赖，不为三个静态链接引插件——引入会改
// GeneratedPluginRegistrant，得重跑 flutter build apk 才敢发版（issue #12 / v1.3.7）。
const _platform = MethodChannel('com.daidai.panel/app_install');

/// 关于页。
///
/// 原先是 `more_page.dart` 里的 `_showAboutDialog` 弹窗，issue #12 要求补作者主页、
/// 项目地址与反馈入口，弹窗（`AlertDialog` 的 content 是不可滚动的 `Column`）装不下，
/// 故改成独立页。头部用 `AppBackButton` + 24px 粗标题的自绘头，
/// 与「安全设置」等设置系二级页一致（`sponsor_page` 的 AppBar 是唯一特例）。
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  // late final 字段而不是在 build 里现取：放 build 里每次重建（比如切主题）
  // 都会重新打一次平台通道，FutureBuilder 也会跟着闪一下「版本 -」。
  late final Future<PackageInfo> _packageInfoFuture = PackageInfo.fromPlatform();

  /// 打开外部链接。拉不起浏览器就退回复制链接，保证用户至少拿得到地址。
  Future<void> _openUrl(BuildContext context, String url) async {
    try {
      await _platform.invokeMethod('openUrl', {'url': url});
    } catch (e) {
      // 原生侧只放行 https，且找不到浏览器时会回 NO_BROWSER；
      // 非 Android 平台则是 MissingPluginException，两者都落到这条兜底上
      debugPrint('openUrl failed: $url, $e');
      await Clipboard.setData(ClipboardData(text: url));
      // await 之后必须重新判 mounted：analysis_options 引了 flutter_lints 全量规则，
      // use_build_context_synchronously 是开着的
      if (!context.mounted) return;
      AppSnack.warn(context, '没有可用的浏览器，链接已复制');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;

    return Scaffold(
      body: Padding(
        padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 12),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: const [
                  AppBackButton(),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '关于',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
                children: [
                  // ── 应用信息卡（整块从原关于弹窗搬过来）──
                  AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 42,
                              height: 42,
                              decoration: BoxDecoration(
                                color: AppColors.primary.withAlpha(20),
                                // 图标底板一律走 sm，不跟外层卡片（lg）同档。
                                borderRadius: BorderRadius.circular(
                                  AppRadius.sm,
                                ),
                              ),
                              child: const Icon(
                                Icons.dashboard_customize_outlined,
                                color: AppColors.primary,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    '呆呆面板',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  FutureBuilder<PackageInfo>(
                                    future: _packageInfoFuture,
                                    builder: (context, snapshot) {
                                      final info = snapshot.data;
                                      final versionLabel = info == null
                                          ? '版本 -'
                                          : '版本 ${info.version}${info.buildNumber.trim().isEmpty ? '' : '+${info.buildNumber}'}';
                                      return Text(
                                        versionLabel,
                                        style: const TextStyle(fontSize: 12),
                                      );
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Text(
                          '轻量级定时任务管理平台',
                          style: TextStyle(
                            fontSize: 13,
                            color: isLight
                                ? AppColors.slate600
                                : AppColors.slate300,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ── 作者卡：整卡可点，跳作者主页 ──
                  AppCard(
                    onTap: () => _openUrl(context, _kAuthorHome),
                    child: Row(
                      children: [
                        ClipOval(
                          // 裸 Image.network 打第三方域名在本 APP 已经线上跑着
                          // （赞助页头像打的就是 dumblist.linzixuan.top），照它写。
                          child: Image.network(
                            _kAuthorAvatar,
                            width: 46,
                            height: 46,
                            fit: BoxFit.cover,
                            // 没网 / 被墙时不要留白洞，退回首字母圆底。
                            errorBuilder: (_, error, stackTrace) =>
                                const _AuthorFallbackAvatar(),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'linzixuanzz',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '作者主页',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: isLight
                                      ? AppColors.slate500
                                      : AppColors.slate400,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.open_in_new,
                          size: 16,
                          color: isLight
                              ? AppColors.slate400
                              : AppColors.slate600,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  const AppSectionTitle(
                    '项目',
                    padding: EdgeInsets.only(left: 2),
                  ),
                  const SizedBox(height: 8),
                  _LinkItem(
                    icon: Icons.code,
                    title: 'GitHub 项目',
                    url: _kAppRepo,
                    isLight: isLight,
                    onTap: () => _openUrl(context, _kAppRepo),
                  ),
                  _LinkItem(
                    icon: Icons.dashboard_outlined,
                    title: '面板项目',
                    url: _kPanelRepo,
                    isLight: isLight,
                    onTap: () => _openUrl(context, _kPanelRepo),
                  ),
                  const SizedBox(height: 24),

                  const AppSectionTitle(
                    '反馈',
                    padding: EdgeInsets.only(left: 2),
                  ),
                  const SizedBox(height: 8),
                  _LinkItem(
                    icon: Icons.bug_report_outlined,
                    title: '反馈 APP 问题',
                    url: _kAppIssues,
                    isLight: isLight,
                    onTap: () => _openUrl(context, _kAppIssues),
                  ),
                  _LinkItem(
                    icon: Icons.feedback_outlined,
                    title: '反馈面板问题',
                    url: _kPanelIssues,
                    isLight: isLight,
                    onTap: () => _openUrl(context, _kPanelIssues),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 外链列表项。
///
/// 刻意**复刻**而不是复用 `more_page.dart` 的 `_SettingsItem`：那是个 Dart 私有类，
/// 跨文件根本 import 不到；提到 `shared/widgets/` 又会动到设置页现有 12 个条目的
/// 渲染路径，为 20 行代码换一片回归面不划算。
/// 唯二的差别：多一行目标地址，且 trailing 用 `open_in_new` 而不是 `chevron_right`——
/// 把「跳出 App」和「站内跳转」在视觉上分开。
class _LinkItem extends StatelessWidget {
  final IconData icon;
  final String title;

  /// 完整链接。副标题显示去掉 scheme 后的地址，让用户点之前知道要跳去哪。
  final String url;
  final bool isLight;
  final VoidCallback onTap;

  const _LinkItem({
    required this.icon,
    required this.title,
    required this.url,
    required this.isLight,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Icon(
            icon,
            size: 20,
            color: isLight ? AppColors.slate500 : AppColors.slate400,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  url.replaceFirst('https://', ''),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: isLight ? AppColors.slate500 : AppColors.slate400,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            Icons.open_in_new,
            size: 16,
            color: isLight ? AppColors.slate400 : AppColors.slate600,
          ),
        ],
      ),
    );
  }
}

/// 作者头像的兜底。
///
/// 尺寸必须和 `Image.network` 的 46 逐像素一致：写 48 的话，图加载失败的那一刻
/// 整行会当场跳 2dp。取值与字号照 `sponsor_page.dart` 的 `_FallbackAvatar`。
class _AuthorFallbackAvatar extends StatelessWidget {
  const _AuthorFallbackAvatar();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: AppColors.primary.withAlpha(22),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        'L',
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          // 圆底就是 primary 的 alpha=22 淡底，首字母用满强度同色只有 2.6:1。
          color: context.surfaces.tintFg(AppColors.primary),
        ),
      ),
    );
  }
}
