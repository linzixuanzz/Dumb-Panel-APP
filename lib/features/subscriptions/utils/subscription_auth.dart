// 订阅仓库鉴权的取值、校验与请求体拼装。纯函数，不依赖 Flutter，可直接单测。
//
// ── 补的是什么缺口 ──────────────────────────────────────────────────────
// 面板的订阅支持三种鉴权：无 / SSH 密钥 / Access Token
// （server/model/subscription.go:8-13 的 SubAuthType*），
// 而 APP 的订阅表单**一个字段都没有** —— 私有仓库订阅在手机上根本建不了。
// `Subscription` model 里那个 `sshKeyId` 是死代码：真实请求体是页面里的内联
// 字面量，从来没带过它。
//
// ── 面板的规则（server/handler/subscription.go:107-127 逐条核对）────────
// `normalizeSubscriptionAuthInput(authType, sshKeyID, authToken)`：
//   auth_type ""     → 三个字段全清空（ssh_key_id=nil, auth_token=""）
//   auth_type "ssh"  → **必须**有 ssh_key_id，否则 400「已选择 SSH 鉴权，请指定 SSH 密钥」
//                      且 auth_token 被清空
//   auth_type "token"→ **必须**有非空 auth_token，否则 400「已选择 Token 鉴权，请填写访问令牌」
//                      且 ssh_key_id 被清空
//   其它值           → 归一成 ""（NormalizeSubscriptionAuthType 的 default）
//
// 编辑时的特例（subscription.go:311-321）：auth_type 仍是 token 且传上来的
// auth_token 是空串时，面板**保留**已存的 token。所以「编辑一个已有 token 的
// 订阅、不想换 token」的正确做法是把 auth_token 留空发过去，而不是不发这个键
// —— 不发的话 `updates["auth_token"]` 不存在，面板会拿 sub.AuthToken 兜住，
// 结果一样，但形状不一致会让 Web 和 APP 的行为分叉。这里统一按 Web 的做法发空串
// （web/src/views/subscriptions/index.vue:519-536）。
//
// ── 为什么不做「SSH 密钥管理页」──────────────────────────────────────────
// 面板自己就**没有**这个页面：`/ssh-keys` 的 5 条路由被订阅页当子功能用
// （index.vue:1350-1365 是订阅表单里的一个下拉）。给 APP 单开一页会做出一个
// 面板都没有的东西，两边再也对不上。这里只做「订阅表单里选一把已有的密钥」。
//
// ⚠️ `/api/ssh-keys` 挂了 `RequireAdmin`（server/handler/ssh_key.go:108），
// 非管理员拿不到列表。UI 必须能在拿不到列表时给出解释，而不是显示一个空下拉。

/// 订阅仓库鉴权方式。取值与面板 `SubAuthType*` 一一对应。
enum SubscriptionAuthType {
  /// 公开仓库，不带任何凭据。对应面板的空串。
  none,

  /// SSH 密钥。必须同时指定 `ssh_key_id`。
  ssh,

  /// Access Token（GitHub / Gitee / GitLab 的个人令牌）。必须同时有 token。
  token,
}

/// 面板 → APP 的取值换算。
///
/// 面板 `NormalizeSubscriptionAuthType` 对认不出来的值返回空串，也就是
/// 「按无鉴权处理」。这里跟着返回 [SubscriptionAuthType.none]，
/// **不是**为了兜底好看，而是为了和面板真正会做的事保持一致：
/// 面板既然会把它当无鉴权，APP 显示成无鉴权才是诚实的。
SubscriptionAuthType parseSubscriptionAuthType(dynamic raw) {
  switch (raw?.toString().trim().toLowerCase() ?? '') {
    case 'ssh':
      return SubscriptionAuthType.ssh;
    case 'token':
      return SubscriptionAuthType.token;
    default:
      return SubscriptionAuthType.none;
  }
}

/// APP → 面板的线上取值。**wire 值只在这里出现一次**，
/// 请求体拼装走 [buildSubscriptionAuthPayload]，不要在页面里再写字面量。
String subscriptionAuthTypeValue(SubscriptionAuthType type) {
  switch (type) {
    case SubscriptionAuthType.ssh:
      return 'ssh';
    case SubscriptionAuthType.token:
      return 'token';
    case SubscriptionAuthType.none:
      return '';
  }
}

String subscriptionAuthTypeLabel(SubscriptionAuthType type) {
  switch (type) {
    case SubscriptionAuthType.ssh:
      return 'SSH 密钥';
    case SubscriptionAuthType.token:
      return 'Access Token';
    case SubscriptionAuthType.none:
      return '无鉴权';
  }
}

/// 保存前的本地校验，返回 null 表示可以提交。
///
/// 复刻面板 `normalizeSubscriptionAuthInput` 的两条 400，文案也照抄 ——
/// 与其让用户点了保存、等一个来回、再看一句同样的话，不如当场说。
/// 但**只是提前**：面板那边的校验一条没少，APP 拦不住的（比如 token 被删了）
/// 仍然由面板报错。
///
/// [isEdit] + [hasExistingToken]：编辑一个已经存过 token 的订阅时，token 框
/// 留空表示「不改」，不该被判成「没填」。
String? validateSubscriptionAuth({
  required String subType,
  required SubscriptionAuthType authType,
  int? sshKeyId,
  String authToken = '',
  bool isEdit = false,
  bool hasExistingToken = false,
}) {
  // 单文件订阅不走 git 鉴权，面板也会在保存时把这几个字段清掉。
  if (subType != 'git-repo') {
    return null;
  }
  switch (authType) {
    case SubscriptionAuthType.none:
      return null;
    case SubscriptionAuthType.ssh:
      if (sshKeyId == null || sshKeyId <= 0) {
        return '已选择 SSH 鉴权，请指定 SSH 密钥';
      }
      return null;
    case SubscriptionAuthType.token:
      if (authToken.trim().isEmpty && !(isEdit && hasExistingToken)) {
        return '已选择 Token 鉴权，请填写访问令牌';
      }
      return null;
  }
}

/// 拼出请求体里与鉴权相关的那几个键。
///
/// 归一规则与面板 Web（index.vue:519-536）逐条一致：
/// 选中哪一种，就只留那一种需要的字段，其余显式清空。
/// 显式清空很重要 —— 更新接口是「有哪个键就改哪个键」，
/// 不发 `ssh_key_id` 的话，用户从 SSH 切到 Token 之后旧的密钥 id 还留在库里。
Map<String, dynamic> buildSubscriptionAuthPayload({
  required String subType,
  required SubscriptionAuthType authType,
  int? sshKeyId,
  String authUsername = '',
  String authToken = '',
}) {
  final none = <String, dynamic>{
    'auth_type': subscriptionAuthTypeValue(SubscriptionAuthType.none),
    'ssh_key_id': null,
    'auth_username': '',
    'auth_token': '',
  };
  if (subType != 'git-repo') {
    return none;
  }
  switch (authType) {
    case SubscriptionAuthType.ssh:
      return <String, dynamic>{
        'auth_type': subscriptionAuthTypeValue(SubscriptionAuthType.ssh),
        'ssh_key_id': sshKeyId,
        'auth_username': '',
        'auth_token': '',
      };
    case SubscriptionAuthType.token:
      return <String, dynamic>{
        'auth_type': subscriptionAuthTypeValue(SubscriptionAuthType.token),
        'ssh_key_id': null,
        'auth_username': authUsername.trim(),
        // 编辑时留空 = 保持已存的 token（面板 subscription.go:318 的分支）。
        // 所以这里不能因为「空就别发了」而省掉这个键 —— Web 也是原样发空串。
        'auth_token': authToken.trim(),
      };
    case SubscriptionAuthType.none:
      return none;
  }
}

/// 面板 `GET /api/ssh-keys` 的一条记录。私钥不下发（model/ssh_key.go:19-26 的
/// `ToDict` 只给 id / name / 时间戳），APP 也不需要。
class SshKeyOption {
  const SshKeyOption({required this.id, required this.name});

  final int id;
  final String name;

  static SshKeyOption? fromJson(Map<String, dynamic> json) {
    final id = (json['id'] as num?)?.toInt() ?? 0;
    if (id <= 0) {
      return null;
    }
    final name = json['name']?.toString().trim() ?? '';
    return SshKeyOption(id: id, name: name.isEmpty ? '密钥 #$id' : name);
  }

  @override
  bool operator ==(Object other) =>
      other is SshKeyOption && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// 解析 `GET /api/ssh-keys` 的响应（`{"data": [...]}`，见 handler/ssh_key.go:29）。
List<SshKeyOption> parseSshKeys(dynamic raw) {
  final list = raw is Map ? raw['data'] : raw;
  if (list is! List) {
    return const <SshKeyOption>[];
  }
  final result = <SshKeyOption>[];
  for (final item in list) {
    if (item is Map) {
      final key = SshKeyOption.fromJson(Map<String, dynamic>.from(item));
      if (key != null) {
        result.add(key);
      }
    }
  }
  return result;
}
