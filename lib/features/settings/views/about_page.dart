import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../core/theme/design_tokens.dart';
import '../../../shared/widgets/app_back_button.dart';
import '../../../shared/widgets/app_grouped_list.dart';
import '../../../shared/widgets/app_icon_tile.dart';
import '../../../shared/widgets/app_large_title_header.dart';
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
/// 故改成独立页。v2.0 换装：返回按钮 + 大标题头，内容收进分组列表。
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
    final palette = context.palette;

    // 外链行：副标题是去掉 scheme 的地址，右侧 open_in_new 把「跳出 App」和站内跳转区分开
    Widget link(IconData icon, Color color, String title, String url) {
      return AppGroupedRow(
        leading: AppIconTile(icon: icon, color: color),
        title: title,
        subtitle: url.replaceFirst('https://', ''),
        trailing: Icon(Icons.open_in_new, size: 16, color: palette.text3),
        onTap: () => _openUrl(context, url),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            // 二级页：返回按钮在上，大标题在下（iOS 的导航大标题样式）
            const Align(
              alignment: Alignment.centerLeft,
              child: AppBackButton(),
            ),
            const AppLargeTitleHeader(
              title: '关于',
              padding: EdgeInsets.fromLTRB(4, 4, 4, 20),
            ),

            // ── 应用信息 + 作者 ──
            AppGroupedList(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
                  child: Row(
                    children: [
                      ClipRRect(
                        // 应用图标，圆角按彩色图标方块的比例（15/46）缩放
                        borderRadius: BorderRadius.circular(
                          AppRadius.tile * 52 / 46,
                        ),
                        child: Image.asset(
                          'assets/icon.png',
                          width: 52,
                          height: 52,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '呆呆面板',
                              style: AppText.cardTitle.copyWith(
                                color: palette.text,
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
                                  '$versionLabel · 轻量级定时任务管理平台',
                                  style: AppText.caption.copyWith(
                                    color: palette.text2,
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // 作者：整行可点，跳作者主页
                AppGroupedRow(
                  leading: ClipOval(
                    // 裸 Image.network 打第三方域名在本 APP 已经线上跑着
                    // （赞助页头像打的就是 dumblist.linzixuan.top），照它写。
                    // 边长取 leadingWidth：分隔线起点按这个槽宽算，
                    // 头像大一号，标题就会比分隔线靠右。
                    child: Image.network(
                      _kAuthorAvatar,
                      width: AppGroupedRow.leadingWidth,
                      height: AppGroupedRow.leadingWidth,
                      fit: BoxFit.cover,
                      // 没网 / 被墙时不要留白洞，退回首字母圆底。
                      errorBuilder: (_, error, stackTrace) =>
                          const _AuthorFallbackAvatar(),
                    ),
                  ),
                  title: 'linzixuanzz',
                  subtitle: '作者主页',
                  trailing: Icon(
                    Icons.open_in_new,
                    size: 16,
                    color: palette.text3,
                  ),
                  onTap: () => _openUrl(context, _kAuthorHome),
                ),
              ],
            ),
            const SizedBox(height: 28),

            AppGroupedList(
              header: '项目',
              children: [
                link(Icons.code_rounded, palette.purple, 'GitHub 项目', _kAppRepo),
                link(
                  Icons.dashboard_rounded,
                  palette.accent,
                  '面板项目',
                  _kPanelRepo,
                ),
              ],
            ),
            const SizedBox(height: 28),

            AppGroupedList(
              header: '反馈',
              children: [
                link(
                  Icons.bug_report_rounded,
                  palette.err,
                  '反馈 APP 问题',
                  _kAppIssues,
                ),
                link(
                  Icons.feedback_rounded,
                  palette.warn,
                  '反馈面板问题',
                  _kPanelIssues,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 作者头像的兜底。
///
/// 尺寸必须和 `Image.network` 一样取 [AppGroupedRow.leadingWidth]：不一致的话，
/// 图加载失败的那一刻整行会当场跳一下，标题也会和分隔线错开。
class _AuthorFallbackAvatar extends StatelessWidget {
  const _AuthorFallbackAvatar();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      width: AppGroupedRow.leadingWidth,
      height: AppGroupedRow.leadingWidth,
      decoration: BoxDecoration(
        color: palette.tint(palette.accent),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        'L',
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          // 浅底上的字用墨色
          color: palette.accentInk,
        ),
      ),
    );
  }
}
