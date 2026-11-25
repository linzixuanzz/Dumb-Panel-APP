import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/network/api_endpoints.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/utils/time_utils.dart';
import '../../../shared/widgets/app_back_button.dart';
import '../../../shared/widgets/app_grouped_list.dart';
import '../../../shared/widgets/app_large_title_header.dart';

class SponsorPage extends StatefulWidget {
  const SponsorPage({super.key});

  @override
  State<SponsorPage> createState() => _SponsorPageState();
}

class _SponsorPageState extends State<SponsorPage> {
  final _currencyFormat = NumberFormat.currency(
    locale: 'zh_CN',
    symbol: '¥',
    decimalDigits: 2,
  );

  List<_SponsorRecord> _sponsors = const [];
  int _count = 0;
  double _totalAmount = 0;
  String? _updatedAt;
  bool _unavailable = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSponsors();
  }

  Future<void> _loadSponsors() async {
    if (mounted) {
      setState(() => _loading = true);
    }
    try {
      final resp = await DioClient.instance.dio.get(ApiEndpoints.sponsors);
      final data = extractData(resp.data);
      if (data is! Map) {
        throw StateError('invalid sponsor payload');
      }
      final payload = Map<String, dynamic>.from(data);
      final sponsors =
          (payload['sponsors'] as List? ?? const [])
              .whereType<Map>()
              .map(
                (item) =>
                    _SponsorRecord.fromJson(Map<String, dynamic>.from(item)),
              )
              .toList()
            ..sort((left, right) => right.amount.compareTo(left.amount));

      if (!mounted) {
        return;
      }
      setState(() {
        _sponsors = sponsors;
        _count = (payload['count'] as num?)?.toInt() ?? sponsors.length;
        _totalAmount = (payload['total_amount'] as num?)?.toDouble() ?? 0;
        _updatedAt = payload['updated_at']?.toString();
        _unavailable = payload['unavailable'] == true;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _sponsors = const [];
        _count = 0;
        _totalAmount = 0;
        _updatedAt = null;
        _unavailable = true;
        _loading = false;
      });
    }
  }

  String _summaryText() {
    final parts = <String>[
      '共 $_count 位赞助者',
      '累计 ${_currencyFormat.format(_totalAmount)}',
    ];
    final updatedAt = _updatedAt;
    final parsed = updatedAt == null ? null : DateTime.tryParse(updatedAt);
    if (parsed != null) {
      parts.add('更新于 ${formatTimeCn(parsed, short: true)}');
    }
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final caption = AppText.caption.copyWith(color: palette.text2);

    return Scaffold(
      body: SafeArea(
        child: _loading
            ? Center(child: CircularProgressIndicator(color: palette.accent))
            : RefreshIndicator(
                color: palette.accent,
                onRefresh: _loadSponsors,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  children: [
                    // 二级页：返回按钮在上，大标题在下（iOS 的导航大标题样式）
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: AppBackButton(),
                    ),
                    AppLargeTitleHeader(
                      title: '赞助名单',
                      subtitle: _summaryText(),
                      padding: const EdgeInsets.fromLTRB(4, 4, 4, 20),
                    ),
                    AppGroupedList(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(18),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '感谢支持',
                                style: AppText.cardTitle.copyWith(
                                  color: palette.text,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '本项目长期持续维护，感谢每一位赞助用户对开发迭代和服务开销的支持。',
                                style: caption,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 28),
                    if (_sponsors.isEmpty)
                      AppGroupedList(
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(AppSpacing.xl),
                            child: Column(
                              children: [
                                Icon(
                                  Icons.favorite_border,
                                  size: 44,
                                  color: palette.text3,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  _unavailable ? '赞助名单服务暂时不可用' : '暂时还没有赞助名单',
                                  style: AppText.body.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: palette.text,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  _unavailable
                                      ? '后端已经做了兜底，晚点下拉刷新再看即可。'
                                      : '后续录入赞助信息后，这里会自动展示最新名单。',
                                  textAlign: TextAlign.center,
                                  style: caption,
                                ),
                              ],
                            ),
                          ),
                        ],
                      )
                    else
                      AppGroupedList(
                        children: [
                          for (final sponsor in _sponsors)
                            _SponsorRow(
                              sponsor: sponsor,
                              currencyFormat: _currencyFormat,
                            ),
                        ],
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _SponsorRecord {
  final int id;
  final String name;
  final double amount;
  final String avatarUrl;
  final String initial;

  const _SponsorRecord({
    required this.id,
    required this.name,
    required this.amount,
    required this.avatarUrl,
    required this.initial,
  });

  factory _SponsorRecord.fromJson(Map<String, dynamic> json) {
    return _SponsorRecord(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name']?.toString().trim().isNotEmpty == true
          ? json['name'].toString().trim()
          : '匿名赞助者',
      amount: (json['amount'] as num?)?.toDouble() ?? 0,
      avatarUrl: json['avatar_url']?.toString() ?? '',
      initial: json['initial']?.toString().trim().isNotEmpty == true
          ? json['initial'].toString().trim()
          : '赞',
    );
  }
}

/// 赞助名单里的一行：头像 + 名字 + 金额（等宽数字）。
class _SponsorRow extends StatelessWidget {
  final _SponsorRecord sponsor;
  final NumberFormat currencyFormat;

  const _SponsorRow({required this.sponsor, required this.currencyFormat});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final avatarUrl = sponsor.avatarUrl.trim();
    return AppGroupedRow(
      leading: avatarUrl.isNotEmpty
          ? ClipOval(
              child: Image.network(
                avatarUrl,
                width: 36,
                height: 36,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) =>
                    _FallbackAvatar(initial: sponsor.initial),
              ),
            )
          : _FallbackAvatar(initial: sponsor.initial),
      title: sponsor.name,
      subtitle: '感谢你的支持',
      trailing: Text(
        currencyFormat.format(sponsor.amount),
        style: AppText.tabular(
          AppText.body.copyWith(
            fontWeight: FontWeight.w700,
            color: palette.text,
          ),
        ),
      ),
    );
  }
}

/// 头像兜底：首字母圆底。尺寸与 `Image.network` 的 36 一致，加载失败那一刻不跳。
class _FallbackAvatar extends StatelessWidget {
  final String initial;

  const _FallbackAvatar({required this.initial});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: palette.tint(palette.accent),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
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
