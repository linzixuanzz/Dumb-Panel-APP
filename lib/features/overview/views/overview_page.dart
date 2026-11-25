import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/auth/auth_provider.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/api/task_lookup.dart';
import '../../../shared/models/insights.dart';
import '../../../shared/models/task.dart';
import '../../../shared/utils/duration_utils.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/app_icon_tile.dart';
import '../../../shared/widgets/app_large_title_header.dart';
import '../../../shared/widgets/app_segmented.dart';
import '../../../shared/widgets/app_snack.dart';
import '../../../shared/widgets/app_state_views.dart';
import '../../tasks/providers/task_provider.dart';
import '../../tasks/widgets/task_detail_sheet.dart';
import '../providers/dashboard_provider.dart';
import '../widgets/execution_bar_chart.dart';

// ── 渐变总览卡的配色（方案书「淡紫渐变」，取自 APP效果演示.html 的 `.hero`）──────
// 这是一块插画式的装饰底，不属于界面语义色，所以不进 palette，写成文件内常量。
// 结构：一层 170° 线性底色 + 左上一团紫色径向光 + 右上一团蓝色径向光。

/// 浅色：线性底色（上 → 下）。
const List<Color> _heroBaseLight = [
  Color(0xFFD9D0F6),
  Color(0xFFF1ECFB),
  Color(0xFFFBFAFF),
];

/// 浅色：左上紫光（#8b74e6 → 55% → 透明）。
const List<Color> _heroGlowLight = [
  Color(0xFF8B74E6),
  Color(0x8C8B74E6),
  Color(0x008B74E6),
];

/// 浅色：右上蓝光（rgba(126,160,255,.5) → 透明）。
const List<Color> _heroGlow2Light = [Color(0x807EA0FF), Color(0x007EA0FF)];

/// 深色：线性底色。
const List<Color> _heroBaseDark = [
  Color(0xFF241C40),
  Color(0xFF18142A),
  Color(0xFF141220),
];

/// 深色：左上紫光（#5b45c9 → 50% → 透明）。
const List<Color> _heroGlowDark = [
  Color(0xFF5B45C9),
  Color(0x805B45C9),
  Color(0x005B45C9),
];

/// 深色：右上蓝光（rgba(60,90,220,.45) → 透明）。
const List<Color> _heroGlow2Dark = [Color(0x733C5ADC), Color(0x003C5ADC)];

final NumberFormat _thousands = NumberFormat.decimalPattern('en');

/// 「概览」Tab（v2.0，原 v1.x「主页」的统计部分）。
///
/// 自上而下：大标题 + 呆呆头像问候 → 渐变总览卡（近 30 天成功率）→
/// 最慢的任务 / 最常失败两张小卡 → 每日执行柱状图 → 服务器资源。
///
/// 老面板降级：
/// - 没有 `/system/attention`（v4.0 才有）→「最常失败」卡隐藏；
/// - 「最慢的任务」v4.0 用最近 10 次平均耗时，老面板退回任务的「最近一次耗时」，
///   都算不出来就隐藏；
/// - `/system/dashboard?range=30` 老于 v2.1.4 的面板忽略 range、只给 7 天，页面按实际天数显示。
class OverviewPage extends ConsumerStatefulWidget {
  const OverviewPage({super.key});

  @override
  ConsumerState<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends ConsumerState<OverviewPage> {
  /// 柱状图只看最近 7 天（true）还是整段区间（false，默认）。
  bool _chartWeekOnly = false;

  @override
  void initState() {
    super.initState();
    // 只管概览自己的数据。「user 为空时补拉用户信息」和「静默检查更新」在 MainScaffold 首次构建里。
    Future.microtask(() => ref.read(dashboardProvider.notifier).load());
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(dashboardProvider);
    final username = ref.watch(authProvider).user?.username;
    final palette = context.palette;
    // 安全区与底栏高度要在 ListView 外面读（AppSpacing.listBottomOf 的说明）
    final topInset = MediaQuery.paddingOf(context).top;
    final bottomInset = AppSpacing.listBottomOf(context);

    final hour = DateTime.now().hour;
    final greeting = hour < 5
        ? '夜深了'
        : hour < 11
        ? '早上好'
        : hour < 13
        ? '中午好'
        : hour < 18
        ? '下午好'
        : '晚上好';

    final header = AppLargeTitleHeader(
      title: '概览',
      subtitle: '$greeting，${(username ?? '').isEmpty ? '管理员' : username}',
      leading: const _MascotAvatar(size: 48),
      // 外层 ListView 已经有左右 16，这里只补到大标题该在的 20
      padding: const EdgeInsets.fromLTRB(4, AppSpacing.sm, 0, AppSpacing.lg),
    );

    final listPadding = EdgeInsets.fromLTRB(
      AppSpacing.lg,
      topInset,
      AppSpacing.lg,
      bottomInset,
    );

    final hasData = data.system.isNotEmpty || data.dashboard.isNotEmpty;

    Widget body;
    if (!hasData && (data.loading || data.error == null)) {
      // 首次加载（还没有任何数据）：与任务 / 日志页同一个加载态
      body = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: listPadding,
        children: [header, const AppLoadingView()],
      );
    } else if (!hasData) {
      // 首次加载就失败：整页错误态 + 重试
      body = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: listPadding,
        children: [
          header,
          AppErrorView(
            title: '概览加载失败',
            message: data.error ?? '',
            onRetry: () => ref.read(dashboardProvider.notifier).load(),
            padding: const EdgeInsets.fromLTRB(16, 60, 16, 0),
          ),
        ],
      );
    } else {
      final trend = data.executionTrend;
      final slowest = data.slowest;
      final failing = data.topFailing;
      // attention 为 null 才隐藏（老面板 / 没拿到）；拿到了但没有连续失败的任务时显示「暂无」
      final showFailing = data.attention != null;

      final chartDays = _chartWeekOnly && trend.length > 7
          ? trend.sublist(trend.length - 7)
          : trend;

      body = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: listPadding,
        children: [
          header,

          // 刷新失败但手上还有上一次的数据：照常显示旧数据，顶上说一句
          if (data.error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, AppSpacing.md),
              child: Text(
                '刷新失败：${data.error}。下面是上一次的数据。',
                style: AppText.caption.copyWith(color: palette.errInk),
              ),
            ),

          _HeroCard(data: data),

          // ── 最慢的任务 / 最常失败 ──────────────────────────────────
          // 只剩一张时独占一行；两张都没有就整行不出
          if (slowest != null || showFailing) ...[
            const SizedBox(height: AppSpacing.lg),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (slowest != null)
                    Expanded(
                      child: _MiniCard(
                        key: const Key('overview-slowest'),
                        label: '最慢的任务',
                        icon: Icons.schedule_rounded,
                        iconColor: palette.accent,
                        title: slowest.name,
                        caption:
                            '${slowest.isAverage ? '平均' : '最近一次'} '
                            '${formatDurationSeconds(slowest.seconds)}',
                        onTap: () =>
                            _openTask(slowest.id, known: slowest.task),
                      ),
                    ),
                  if (slowest != null && showFailing)
                    const SizedBox(width: AppSpacing.md),
                  if (showFailing)
                    Expanded(child: _buildFailingCard(context, failing)),
                ],
              ),
            ),
          ],

          // ── 每日执行 ─────────────────────────────────────────────
          if (trend.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.lg),
            AppCard(
              radius: AppRadius.card,
              bordered: false,
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('每日执行', style: AppText.cardTitle),
                            const SizedBox(height: 2),
                            Text(
                              '近 ${chartDays.length} 天',
                              style: AppText.caption.copyWith(
                                color: palette.text2,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // 老面板只给 7 天时没得切，不出分段
                      if (trend.length > 7)
                        SizedBox(
                          width: 150,
                          child: AppSegmented<bool>(
                            segments: [
                              (true, '7 天'),
                              (false, '${trend.length} 天'),
                            ],
                            value: _chartWeekOnly,
                            onChanged: (v) =>
                                setState(() => _chartWeekOnly = v),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  ExecutionBarChart(days: chartDays),
                ],
              ),
            ),
          ],

          // ── 服务器资源 ───────────────────────────────────────────
          const SizedBox(height: AppSpacing.lg),
          _ResourceCard(data: data),
        ],
      );
    }

    return Scaffold(
      body: RefreshIndicator(
        color: palette.accent,
        // 下拉刷新的转圈放到状态栏下面，不被刘海挡住
        edgeOffset: topInset,
        onRefresh: () => ref.read(dashboardProvider.notifier).load(),
        child: body,
      ),
    );
  }

  /// 「最常失败」卡：v4.0 attention 里的第一条 task_failing。
  /// 面板标题形如「任务名 · 连续失败 3 次」，拆成粗体任务名 + 下面一行说明；
  /// 拆不开（以后面板改了文案）就整句当标题。
  Widget _buildFailingCard(BuildContext context, AttentionItem? failing) {
    final palette = context.palette;
    if (failing == null) {
      return _MiniCard(
        key: const Key('overview-failing'),
        label: '最常失败',
        icon: Icons.check_circle_outline_rounded,
        iconColor: palette.ok,
        title: '暂无',
        caption: '没有连续失败的任务',
      );
    }
    final title = failing.title;
    final sep = title.lastIndexOf(' · ');
    final name = sep > 0 ? title.substring(0, sep) : title;
    final rest = sep > 0 ? title.substring(sep + 3) : '';
    final targetId = failing.target.id;
    final isTask = failing.target.kind == 'task' && targetId > 0;
    return _MiniCard(
      key: const Key('overview-failing'),
      label: '最常失败',
      icon: Icons.error_outline_rounded,
      iconColor: palette.warn,
      title: name,
      caption: rest,
      onTap: isTask ? () => _openTask(targetId) : null,
    );
  }

  /// 点「最慢 / 最常失败」卡：弹任务详情弹层（组间契约 showTaskDetailSheet）。
  ///
  /// 以前是 push `/tasks/:id/detail` 且不带任务数据，详情只在任务列表 provider 里按 id 找 ——
  /// 没进过任务页、或列表带着筛选时就显示「任务不存在」。现在按顺序找：
  /// 卡片自带的那条 → 任务列表 provider → 概览算「最慢」时拉到的第一页 → 去面板上按 id 取。
  Future<void> _openTask(int id, {Task? known}) async {
    var task = known;
    if (task == null) {
      final loaded = [
        ...ref.read(taskProvider).tasks,
        ...ref.read(dashboardProvider).scannedTasks,
      ];
      for (final item in loaded) {
        if (item.id == id) {
          task = item;
          break;
        }
      }
    }
    if (task == null) {
      try {
        task = await fetchTaskById(id);
      } catch (_) {
        if (mounted) AppSnack.error(context, '加载任务失败，请稍后再试');
        return;
      }
    }
    if (!mounted) return;
    if (task == null) {
      // 面板上也没有：多半是刚被删了，不跳转
      AppSnack.warn(context, '任务不存在或已被删除');
      return;
    }
    await showTaskDetailSheet(context, ref, task);
  }
}

/// 呆呆头像（`assets/icon.png`）；图片加载失败时退回文字头像。
class _MascotAvatar extends StatelessWidget {
  final double size;

  const _MascotAvatar({required this.size});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return ClipOval(
      child: Image.asset(
        'assets/icon.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => Container(
          width: size,
          height: size,
          color: palette.tint(palette.accent),
          alignment: Alignment.center,
          child: Text(
            '呆',
            style: TextStyle(
              fontSize: size * 0.42,
              fontWeight: FontWeight.w700,
              color: palette.accentInk,
            ),
          ),
        ),
      ),
    );
  }
}

/// 渐变总览卡：区间成功率大字 + 失败次数 + 今日 / 运行中 / 任务数。
///
/// 口径（与面板 `Stats` 一致）：成功 / (成功 + 失败)，已终止不进分母；
/// 区间 = `/system/dashboard?range=30` 返回的 daily_stats（含今天），老面板是 7 天。
/// 方案书里的「定时 / 手动占比」现有接口不区分触发方式，先不放。
class _HeroCard extends StatelessWidget {
  final DashboardData data;

  const _HeroCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final light = palette.isLight;
    final days = data.executionTrend.length;
    final rate = data.rangeSuccessRate;
    // 截断到 1 位小数，不往上凑：99.96% 不能显示成 100%
    final rateText = rate == null
        ? '--'
        : rate >= 100
        ? '100'
        : ((rate * 10).floor() / 10).toStringAsFixed(1);
    final todayRuns = data.todaySuccess + data.todayFailed + data.todayAborted;

    final radius = BorderRadius.circular(AppRadius.card);
    return ClipRRect(
      key: const Key('overview-hero'),
      borderRadius: radius,
      child: Stack(
        children: [
          // 三层渐变铺满整卡，内容在最上面
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: const Alignment(-0.17, -1),
                  end: const Alignment(0.17, 1),
                  stops: const [0, 0.6, 1],
                  colors: light ? _heroBaseLight : _heroBaseDark,
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment.topLeft,
                  radius: 1.2,
                  stops: const [0, 0.3, 0.65],
                  colors: light ? _heroGlowLight : _heroGlowDark,
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment.topRight,
                  radius: 0.9,
                  stops: const [0, 0.7],
                  colors: light ? _heroGlow2Light : _heroGlow2Dark,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  days > 0 ? '近 $days 天成功率' : '成功率',
                  style: AppText.cardTitle.copyWith(color: palette.text),
                ),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text.rich(
                          TextSpan(
                            text: rateText,
                            children: [
                              if (rate != null)
                                const TextSpan(
                                  text: '%',
                                  style: TextStyle(
                                    fontSize: 28,
                                    letterSpacing: -0.5,
                                  ),
                                ),
                            ],
                          ),
                          key: const Key('overview-rate'),
                          style: AppText.tabular(
                            TextStyle(
                              fontSize: 58,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -2,
                              height: 1.05,
                              color: palette.text,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            '失败',
                            style: AppText.caption.copyWith(
                              color: palette.text2,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            '${_thousands.format(data.rangeFailed)} 次',
                            style: AppText.tabular(
                              TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.w800,
                                // 0 次失败不必标红
                                color: data.rangeFailed > 0
                                    ? palette.errInk
                                    : palette.text,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  rate == null
                      ? '这段时间还没有执行记录'
                      : '共执行 ${_thousands.format(data.rangeRuns)} 次'
                            '${data.rangeAborted > 0 ? '，其中终止 ${_thousands.format(data.rangeAborted)} 次' : ''}',
                  style: AppText.caption.copyWith(color: palette.text2),
                ),
                const SizedBox(height: AppSpacing.xl),
                Row(
                  children: [
                    _heroStat(context, '今日执行', todayRuns),
                    _heroStat(context, '运行中', data.runningTasks),
                    _heroStat(context, '任务', data.totalTasks),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _heroStat(BuildContext context, String label, int value) {
    final palette = context.palette;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppText.caption.copyWith(color: palette.text2)),
          const SizedBox(height: 2),
          Text(
            _thousands.format(value),
            style: AppText.tabular(
              TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: palette.text,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 两列小卡：左上小标题、右上彩色图标方块、下面粗体名称 + 一行说明。
class _MiniCard extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color iconColor;
  final String title;
  final String caption;
  final VoidCallback? onTap;

  const _MiniCard({
    super.key,
    required this.label,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.caption,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return AppCard(
      radius: AppRadius.cardSm,
      bordered: false,
      padding: const EdgeInsets.fromLTRB(18, 16, 14, 18),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  label,
                  style: AppText.caption.copyWith(
                    color: palette.text2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              AppIconTile(icon: icon, color: iconColor, size: 32),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
              color: palette.text,
            ),
          ),
          if (caption.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              caption,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(color: palette.text2),
            ),
          ],
        ],
      ),
    );
  }
}

/// 服务器资源：CPU / 内存 / 磁盘三条细条，沿用 `/system/info` 的数据。
class _ResourceCard extends StatelessWidget {
  final DashboardData data;

  const _ResourceCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final title = data.panelTitle.isNotEmpty ? data.panelTitle : data.hostname;
    final meta = [
      '已运行 ${data.uptime}',
      if (data.panelVersion.isNotEmpty) 'v${data.panelVersion}',
    ].join(' · ');
    final arch = data.system['arch']?.toString() ?? '';

    return AppCard(
      key: const Key('overview-resources'),
      radius: AppRadius.card,
      bordered: false,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // 圆点语义是「最近一次拉取成功与否」，不是心跳：
              // 面板刚挂、下一次拉取还没发生时它仍然是绿的。
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: data.error == null ? palette.ok : palette.err,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.cardTitle,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            [
              meta,
              '${data.os} $arch'.trim(),
            ].where((s) => s.isNotEmpty && s != '-').join('\n'),
            style: AppText.caption.copyWith(color: palette.text2),
          ),
          const SizedBox(height: AppSpacing.lg),
          _ResourceRow(
            label: 'CPU',
            value: data.cpuUsage,
            color: palette.accent,
          ),
          _ResourceRow(
            label: '内存',
            // 内存采集不可用（容器里常见）时显示「不可用」，条是空的
            value: data.memoryUnavailable ? null : data.memoryUsage,
            color: palette.ok,
            detail: data.memoryUnavailable
                ? null
                : '${data.memoryUsed} / ${data.memoryTotal}',
          ),
          _ResourceRow(
            label: '磁盘',
            value: data.diskUsage,
            color: palette.warn,
            detail: '${data.diskUsed} / ${data.diskTotal}',
          ),
        ],
      ),
    );
  }
}

class _ResourceRow extends StatelessWidget {
  final String label;

  /// 0~100；null = 不可用。
  final double? value;
  final Color color;
  final String? detail;

  const _ResourceRow({
    required this.label,
    required this.value,
    required this.color,
    this.detail,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final v = value;
    // ≥ 90% 改成红色：资源快满了才需要被注意到
    final barColor = v != null && v >= 90 ? palette.err : color;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 44,
                child: Text(label, style: AppText.caption),
              ),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  child: SizedBox(
                    height: 8,
                    child: Stack(
                      children: [
                        Positioned.fill(child: ColoredBox(color: palette.fill)),
                        FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: ((v ?? 0) / 100).clamp(0.0, 1.0),
                          heightFactor: 1,
                          child: ColoredBox(color: barColor),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 56,
                child: Text(
                  v == null ? '不可用' : '${v.toStringAsFixed(0)}%',
                  textAlign: TextAlign.right,
                  style: AppText.tabular(
                    AppText.caption.copyWith(
                      fontWeight: FontWeight.w700,
                      color: v == null ? palette.text2 : palette.text,
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (detail != null)
            Padding(
              padding: const EdgeInsets.only(left: 44, top: 2),
              child: Text(
                detail!,
                style: AppText.tabular(
                  AppText.caption.copyWith(color: palette.text2, fontSize: 12),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
