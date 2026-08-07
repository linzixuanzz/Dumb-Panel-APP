class Subscription {
  final int id;
  final String name;
  final String type;
  final String url;
  final String branch;
  final String? subPath;
  final String schedule;
  final String whitelist;
  final String blacklist;
  final bool autoAddTask;
  final bool autoDelTask;
  final bool enabled;
  final double status;
  final DateTime? lastPullAt;
  final String saveDir;
  final int? sshKeyId;

  /// 仓库鉴权方式：`''` / `'ssh'` / `'token'`。
  ///
  /// 面板下发的是 `EffectiveAuthType()`（model/subscription.go:97-111）——
  /// 它会在 auth_type 为空但实际存了 token / 密钥时**推断**出方式，
  /// 所以这个值可以直接拿来当表单初值，不用 APP 再猜一遍。
  final String authType;

  /// Token 鉴权的用户名（GitHub 留空 / Gitee 填用户名 / GitLab 填 oauth2）。
  final String authUsername;

  /// 是否已存过 Access Token。面板**不下发 token 明文**
  /// （`AuthToken` 的 json tag 是 `-`），只给这个布尔。
  /// 编辑表单靠它区分「没配过 token」和「配过但这次不改」。
  final bool hasAuthToken;
  final String alias;
  final String dependOn;
  final String hookScript;
  final bool? forceOverwrite;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Subscription({
    required this.id,
    required this.name,
    this.type = 'public-repo',
    this.url = '',
    this.branch = '',
    this.subPath,
    this.schedule = '',
    this.whitelist = '',
    this.blacklist = '',
    this.autoAddTask = false,
    this.autoDelTask = false,
    this.enabled = true,
    this.status = 0,
    this.lastPullAt,
    this.saveDir = '',
    this.sshKeyId,
    this.authType = '',
    this.authUsername = '',
    this.hasAuthToken = false,
    this.alias = '',
    this.dependOn = '',
    this.hookScript = '',
    this.forceOverwrite,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isRunning => status == 2;
  bool get isPulling => status == 2;
  String get normalizedType {
    switch (type) {
      case 'file':
        return 'single-file';
      case 'public-repo':
      case 'private-repo':
        return 'git-repo';
      case '':
        return 'git-repo';
      default:
        return type;
    }
  }

  bool get isSingleFile => normalizedType == 'single-file';
  bool get isGitRepo => normalizedType == 'git-repo';
  String get typeLabel {
    if (isSingleFile) return '单文件';
    if (isGitRepo) return 'Git 仓库';
    return normalizedType;
  }

  String get statusText {
    if (isRunning) return '拉取中';
    if (enabled) return '已启用';
    return '已禁用';
  }

  factory Subscription.fromJson(Map<String, dynamic> json) {
    return Subscription(
      id: _int(json['id']),
      name: json['name']?.toString() ?? '',
      type: json['type']?.toString() ?? 'public-repo',
      url: json['url']?.toString() ?? '',
      branch: json['branch']?.toString() ?? '',
      subPath: json['sub_path']?.toString(),
      schedule: json['schedule']?.toString() ?? '',
      whitelist: json['whitelist']?.toString() ?? '',
      blacklist: json['blacklist']?.toString() ?? '',
      autoAddTask: json['auto_add_task'] == true,
      autoDelTask: json['auto_del_task'] == true,
      enabled: json['enabled'] != false,
      status: _double(json['status']),
      lastPullAt: _date(json['last_pull_at']),
      saveDir: json['save_dir']?.toString() ?? '',
      sshKeyId: _intOrNull(json['ssh_key_id']),
      authType: json['auth_type']?.toString() ?? '',
      authUsername: json['auth_username']?.toString() ?? '',
      hasAuthToken: json['has_auth_token'] == true,
      alias: json['alias']?.toString() ?? '',
      dependOn: json['depend_on']?.toString() ?? '',
      hookScript: json['hook_script']?.toString() ?? '',
      forceOverwrite: json['force_overwrite'] as bool?,
      createdAt: _date(json['created_at']) ?? DateTime.now(),
      updatedAt: _date(json['updated_at']) ?? DateTime.now(),
    );
  }

  // 这里原来有一个 `toJson()`，**全库零调用**（真实请求体是订阅页里的内联
  // Map 字面量），且两份字段清单已经不一致：它带了 auto_add_task / ssh_key_id，
  // 而实际发出去的请求体没有。本次给 model 加 auth_type / auth_username 时
  // 顺手删掉 —— 留着只会让下一个人改错地方，改完还查不出为什么没生效。
  // 需要序列化订阅时请直接在页面里构造请求体，或先把两份清单合并再恢复它。
}

int _int(dynamic v) => (v is num) ? v.toInt() : 0;
int? _intOrNull(dynamic v) => (v is num) ? v.toInt() : null;
double _double(dynamic v) => (v is num) ? v.toDouble() : 0.0;
DateTime? _date(dynamic v) {
  if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
  return null;
}
