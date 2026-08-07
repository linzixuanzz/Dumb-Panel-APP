// 通知渠道字段的 **v3.0.0 冻结快照** —— 只为兼容还没升级的面板而存在。
//
// ╔══════════════════════════════════════════════════════════════════════╗
// ║  这个文件永远不要再加东西。                                            ║
// ║                                                                      ║
// ║  面板新增渠道、新增字段、改 label、改 placeholder、加 select 选项 ——    ║
// ║  一律不要动这里。那些东西由面板 `GET /api/notifications/types` 的      ║
// ║  `fields` 下发，APP 收到就画（见 notify_field_schema.dart）。          ║
// ║  往这张表里加一行，就等于把刚拆掉的 223 行硬编码表重新长出来一截，       ║
// ║  而且它和面板之间照样没有任何机制保持同步 —— 那正是本次改造要消灭的病。 ║
// ╚══════════════════════════════════════════════════════════════════════╝
//
// 它存在的唯一理由：v3.0.0 及更早的面板 `/notifications/types` 只回
// `{type, name}`，没有 `fields`（server/handler/notification.go:220-246）。
// 用户的面板不会因为 APP 升级就跟着升级，所以这一版 APP 装在老面板上时
// 必须还能配渠道 —— 于是保留一份「APP 在 v3.0.0 时代自己那张表」的原样拷贝，
// 让老面板上的行为与改造前**逐字一致**。
//
// 内容 = notification_list_page.dart 当时的 `_channelFieldMap`
// （21 渠道 / 44 字段槽 / 24 唯一键，label 与 hint 一字未改）
// ＋ email 那个单独写死的三态 SSL 下拉（当时是页面里一个 DropdownButtonFormField，
// 不在 `_channelFieldMap` 里，这里按 select 字段表达，选项与文案原样搬过来）。
// 合计 21 渠道 / 45 字段槽 —— 有回归用例把这两个数钉住了，
// 加字段会直接把测试打红，这是本文件「禁止再长」的执行手段。
//
// 面板一旦下发 `fields`，这个文件里的任何一条都不会再被读到。
//
// 顺带说明两个「快照里没有」的事实，它们都是**故意**的：
// - `custom` 渠道在 v3.0.0 的 APP 上没有字段表，走「配置 JSON」编辑框。
//   这里也不给它字段，老面板上就保持那个编辑框。新面板会给它下发 5 个字段
//   （url / method / content_type / headers / body，与 notifier.go 的
//   sendCustomWebhook 读的键逐条对应），到那时它和别的渠道走同一套通用表单。
// - 快照里没有任何 `required` / `show_when` —— v3.0.0 的 APP 两者都不支持。
//   补上去会让老面板上的行为与改造前不一致，那就失去快照的意义了。

import 'channel_config.dart';
import 'notify_field_schema.dart';

/// v3.0.0 的渠道类型兜底（22 条），对应老面板 `/notifications/types` 的 `{type,name}`。
///
/// 只在服务端那一路取失败或返回空时才用得上（类型表是辅助数据，
/// 它的失败不该让整个渠道列表变成「暂无通知渠道」）。
/// ⚠️ 同样冻结：面板加了新渠道，靠下发，不靠这里。
const List<NotifyChannelSchema> kFrozenChannelTypesV300 = <NotifyChannelSchema>[
  NotifyChannelSchema(type: 'webhook', name: 'Webhook'),
  NotifyChannelSchema(type: 'email', name: '邮件'),
  NotifyChannelSchema(type: 'telegram', name: 'Telegram'),
  NotifyChannelSchema(type: 'dingtalk', name: '钉钉'),
  NotifyChannelSchema(type: 'wecom', name: '企业微信机器人'),
  NotifyChannelSchema(type: 'wecom_app', name: '企业微信应用'),
  NotifyChannelSchema(type: 'bark', name: 'Bark'),
  NotifyChannelSchema(type: 'pushplus', name: 'PushPlus'),
  NotifyChannelSchema(type: 'serverchan', name: 'Server酱'),
  NotifyChannelSchema(type: 'feishu', name: '飞书'),
  NotifyChannelSchema(type: 'gotify', name: 'Gotify'),
  NotifyChannelSchema(type: 'pushdeer', name: 'PushDeer'),
  NotifyChannelSchema(type: 'pushme', name: 'PushMe'),
  NotifyChannelSchema(type: 'chanify', name: 'Chanify'),
  NotifyChannelSchema(type: 'igot', name: 'iGot'),
  NotifyChannelSchema(type: 'qmsg', name: 'Qmsg'),
  NotifyChannelSchema(type: 'pushover', name: 'Pushover'),
  NotifyChannelSchema(type: 'discord', name: 'Discord'),
  NotifyChannelSchema(type: 'slack', name: 'Slack'),
  NotifyChannelSchema(type: 'ntfy', name: 'ntfy'),
  NotifyChannelSchema(type: 'wxpusher', name: 'WxPusher'),
  NotifyChannelSchema(type: 'custom', name: '自定义'),
];

/// v3.0.0 的字段快照。**只读，永不新增。**
const Map<String, List<NotifyFieldSchema>> kFrozenChannelFieldsV300 =
    <String, List<NotifyFieldSchema>>{
      'webhook': <NotifyFieldSchema>[
        NotifyFieldSchema(
          key: 'url',
          label: 'Webhook URL',
          placeholder: 'https://example.com/webhook',
        ),
      ],
      'email': <NotifyFieldSchema>[
        NotifyFieldSchema(
          key: 'smtp_host',
          label: 'SMTP 主机',
          placeholder: 'smtp.qq.com',
        ),
        NotifyFieldSchema(
          key: 'smtp_port',
          label: 'SMTP 端口',
          placeholder: '465',
        ),
        NotifyFieldSchema(
          key: 'smtp_user',
          label: '邮箱账号',
          placeholder: 'user@example.com',
        ),
        NotifyFieldSchema(
          key: 'smtp_pass',
          label: '邮箱密码/授权码',
          widget: NotifyFieldWidget.password,
          placeholder: 'SMTP 授权码',
        ),
        NotifyFieldSchema(
          key: 'to',
          label: '收件人',
          placeholder: '多个收件人用逗号分隔',
        ),
        // v3.0.0 时这一项不在 `_channelFieldMap` 里，是 email 专属的一个
        // DropdownButtonFormField。选项、文案、三个取值都原样搬过来 ——
        // 它必须是 select 而不是开关：面板在「auto 或键不存在」时按端口是否 465
        // 自行判断，用 bool 表达会把 auto 压成 false，等于替用户关掉 465 的 SSL。
        NotifyFieldSchema(
          key: kSmtpSslConfigKey,
          label: 'SSL 连接',
          widget: NotifyFieldWidget.select,
          placeholder: '自动：465 端口启用',
          defaultValue: smtpSslModeAuto,
          options: <NotifyFieldOption>[
            NotifyFieldOption(value: smtpSslModeAuto, label: '自动 (465 启用)'),
            NotifyFieldOption(value: smtpSslModeOn, label: '启用 SSL'),
            NotifyFieldOption(value: smtpSslModeOff, label: '关闭 SSL'),
          ],
        ),
      ],
      'telegram': <NotifyFieldSchema>[
        NotifyFieldSchema(
          key: 'token',
          label: 'Bot Token',
          placeholder: '从 @BotFather 获取',
        ),
        NotifyFieldSchema(
          key: 'chat_id',
          label: 'Chat ID',
          placeholder: '聊天/群组 ID',
        ),
        NotifyFieldSchema(
          key: 'api_host',
          label: 'API 地址 (可选)',
          placeholder: '留空使用官方',
        ),
      ],
      'dingtalk': <NotifyFieldSchema>[
        NotifyFieldSchema(
          key: 'webhook',
          label: 'Webhook URL',
          placeholder: 'https://oapi.dingtalk.com/robot/send?access_token=xxx',
        ),
        NotifyFieldSchema(
          key: 'secret',
          label: '加签秘钥 (可选)',
          placeholder: 'SEC 开头的秘钥',
        ),
      ],
      'wecom': <NotifyFieldSchema>[
        NotifyFieldSchema(
          key: 'webhook',
          label: 'Webhook URL',
          placeholder: 'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxx',
        ),
      ],
      'wecom_app': <NotifyFieldSchema>[
        NotifyFieldSchema(
          key: 'corp_id',
          label: '企业 ID',
          placeholder: 'CorpID',
        ),
        NotifyFieldSchema(
          key: 'secret',
          label: '应用 Secret',
          widget: NotifyFieldWidget.password,
          placeholder: 'Secret',
        ),
        NotifyFieldSchema(
          key: 'agent_id',
          label: 'Agent ID',
          placeholder: 'AgentId',
        ),
        NotifyFieldSchema(
          key: 'to_user',
          label: '成员账号 (可选)',
          placeholder: '多个成员用 | 分隔，留空 @all',
        ),
      ],
      'bark': <NotifyFieldSchema>[
        NotifyFieldSchema(
          key: 'key',
          label: 'Device Key',
          placeholder: 'Bark App 中的 Key',
        ),
        NotifyFieldSchema(
          key: 'server',
          label: '服务器 (可选)',
          placeholder: '默认 https://api.day.app',
        ),
        NotifyFieldSchema(
          key: 'sound',
          label: '推送声音 (可选)',
          placeholder: '如 birdsong',
        ),
        NotifyFieldSchema(
          key: 'group',
          label: '推送分组 (可选)',
          placeholder: '消息分组名称',
        ),
      ],
      'pushplus': <NotifyFieldSchema>[
        NotifyFieldSchema(
          key: 'token',
          label: 'Token',
          placeholder: 'PushPlus 用户 Token',
        ),
        NotifyFieldSchema(
          key: 'topic',
          label: '群组编码 (可选)',
          placeholder: '一对多推送时的群组编码',
        ),
      ],
      'serverchan': <NotifyFieldSchema>[
        NotifyFieldSchema(
          key: 'key',
          label: 'SendKey',
          placeholder: 'SCT...',
        ),
      ],
      'feishu': <NotifyFieldSchema>[
        NotifyFieldSchema(
          key: 'webhook',
          label: 'Webhook URL',
          placeholder: 'https://open.feishu.cn/open-apis/bot/v2/hook/xxx',
        ),
        NotifyFieldSchema(
          key: 'secret',
          label: '加签秘钥 (可选)',
          placeholder: '签名校验秘钥',
        ),
      ],
      'gotify': <NotifyFieldSchema>[
        NotifyFieldSchema(
          key: 'server',
          label: '服务器地址',
          placeholder: 'https://gotify.example.com',
        ),
        NotifyFieldSchema(
          key: 'token',
          label: 'App Token',
          placeholder: 'Gotify 应用 Token',
        ),
      ],
      'pushdeer': <NotifyFieldSchema>[
        NotifyFieldSchema(
          key: 'key',
          label: 'PushKey',
          placeholder: 'PushDeer 的 PushKey',
        ),
        NotifyFieldSchema(
          key: 'server',
          label: '服务器 (可选)',
          placeholder: '默认 https://api2.pushdeer.com',
        ),
      ],
      'pushme': <NotifyFieldSchema>[
        NotifyFieldSchema(
          key: 'key',
          label: 'PushMe Key',
          placeholder: 'push_key',
        ),
      ],
      'chanify': <NotifyFieldSchema>[
        NotifyFieldSchema(
          key: 'token',
          label: 'Token',
          placeholder: 'Chanify 设备 Token',
        ),
      ],
      'igot': <NotifyFieldSchema>[
        NotifyFieldSchema(
          key: 'key',
          label: 'Key',
          placeholder: 'iGot 推送 Key',
        ),
      ],
      'qmsg': <NotifyFieldSchema>[
        NotifyFieldSchema(
          key: 'key',
          label: 'Qmsg Key',
          placeholder: 'Qmsg 酱的 Key',
        ),
        NotifyFieldSchema(
          key: 'qq',
          label: 'QQ 号/群号 (可选)',
          placeholder: '留空按默认配置发送',
        ),
      ],
      'pushover': <NotifyFieldSchema>[
        NotifyFieldSchema(
          key: 'token',
          label: 'API Token',
          placeholder: '应用 API Token',
        ),
        NotifyFieldSchema(
          key: 'user',
          label: 'User Key',
          placeholder: '用户 Key',
        ),
      ],
      'discord': <NotifyFieldSchema>[
        NotifyFieldSchema(
          key: 'webhook',
          label: 'Webhook URL',
          placeholder: 'https://discord.com/api/webhooks/...',
        ),
      ],
      'slack': <NotifyFieldSchema>[
        NotifyFieldSchema(
          key: 'webhook',
          label: 'Webhook URL',
          placeholder: 'https://hooks.slack.com/services/...',
        ),
      ],
      'ntfy': <NotifyFieldSchema>[
        NotifyFieldSchema(
          key: 'topic',
          label: 'Topic',
          placeholder: '订阅主题名称',
        ),
        NotifyFieldSchema(
          key: 'server',
          label: '服务器 (可选)',
          placeholder: '默认 https://ntfy.sh',
        ),
        NotifyFieldSchema(
          key: 'token',
          label: 'Token (可选)',
          placeholder: '访问令牌',
        ),
      ],
      'wxpusher': <NotifyFieldSchema>[
        NotifyFieldSchema(
          key: 'app_token',
          label: 'App Token',
          placeholder: 'WxPusher 的 appToken',
        ),
        NotifyFieldSchema(
          key: 'uids',
          label: 'UID 列表 (可选)',
          placeholder: '多个 UID 用逗号分隔',
        ),
        NotifyFieldSchema(
          key: 'topic_ids',
          label: 'Topic ID (可选)',
          placeholder: '多个 ID 用逗号分隔',
        ),
      ],
    };

/// 渠道类型下拉要显示的列表。服务端给不出就用冻结快照。
List<NotifyChannelSchema> resolveNotifyChannelTypes(
  List<NotifyChannelSchema> fromPanel,
) => fromPanel.isEmpty ? kFrozenChannelTypesV300 : fromPanel;

/// **形状探测**：这台面板给这个渠道下发字段定义了吗？
///
/// - `fields` 存在且非空 → 用面板下发的 schema；
/// - `fields` 缺失或为空（老面板）→ 回落 v3.0.0 冻结快照；
/// - 快照里也没有（老面板上的 custom、以及面板新加而快照当然没有的类型）
///   → 返回空列表，页面转去「配置 JSON」编辑框，用户至少填得进去。
///
/// 不看版本号：`handler.Version` 由 release 流水线用 ldflags 注入，源码默认值就是
/// `"3.0.0"`，任何本地 `go build` / fork 构建都自称 3.0.0，版本号不可信。
/// 这一条与仓库既有的
/// `TestMagiskCustomizeScriptUsesCapabilityProbeInsteadOfVersionGate` 同一个原则，
/// 而形状探测是最轻量的能力探测 —— 零维护成本，也不会像 capabilities 端点那样
/// 自己变成一份新的手写常量数组。
List<NotifyFieldSchema> resolveNotifyChannelFields({
  required String type,
  required List<NotifyChannelSchema> schemas,
}) {
  for (final schema in schemas) {
    if (schema.type != type) {
      continue;
    }
    if (schema.fields.isNotEmpty) {
      return schema.fields;
    }
    break;
  }
  return kFrozenChannelFieldsV300[type] ?? const <NotifyFieldSchema>[];
}
