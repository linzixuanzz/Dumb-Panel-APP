import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/network/api_endpoints.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/utils/api_utils.dart';
import '../../../shared/utils/time_utils.dart';
import '../../../shared/widgets/app_card.dart';

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
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;

    return Scaffold(
      appBar: AppBar(title: const Text('赞助名单')),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            )
          : RefreshIndicator(
              color: AppColors.primary,
              onRefresh: _loadSponsors,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                children: [
                  AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '感谢支持',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '本项目长期持续维护，感谢每一位赞助用户对开发迭代和服务开销的支持。',
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.6,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          _summaryText(),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: isLight
                                ? AppColors.slate500
                                : AppColors.slate400,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_sponsors.isEmpty)
                    AppCard(
                      padding: const EdgeInsets.all(AppSpacing.xl),
                      child: Column(
                        children: [
                          Icon(
                            Icons.favorite_border,
                            size: 44,
                            color: AppColors.primary.withAlpha(180),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _unavailable ? '赞助名单服务暂时不可用' : '暂时还没有赞助名单',
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _unavailable
                                ? '后端已经做了兜底，晚点下拉刷新再看即可。'
                                : '后续录入赞助信息后，这里会自动展示最新名单。',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.6,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    ..._sponsors.map(
                      (sponsor) => _SponsorCard(
                        sponsor: sponsor,
                        currencyFormat: _currencyFormat,
                        isLight: isLight,
                      ),
                    ),
                ],
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

class _SponsorCard extends StatelessWidget {
  final _SponsorRecord sponsor;
  final NumberFormat currencyFormat;
  final bool isLight;

  const _SponsorCard({
    required this.sponsor,
    required this.currencyFormat,
    required this.isLight,
  });

  @override
  Widget build(BuildContext context) {
    final avatarUrl = sponsor.avatarUrl.trim();
    return AppCard(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          avatarUrl.isNotEmpty
              ? ClipOval(
                  child: Image.network(
                    avatarUrl,
                    width: 46,
                    height: 46,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) =>
                        _FallbackAvatar(initial: sponsor.initial),
                  ),
                )
              : _FallbackAvatar(initial: sponsor.initial),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  sponsor.name,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '感谢你的支持',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            currencyFormat.format(sponsor.amount),
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: AppColors.primary,
            ),
          ),
        ],
      ),
    );
  }
}

class _FallbackAvatar extends StatelessWidget {
  final String initial;

  const _FallbackAvatar({required this.initial});

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
        initial,
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
