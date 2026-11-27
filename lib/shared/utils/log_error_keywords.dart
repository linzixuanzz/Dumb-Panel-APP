/// 一行日志「像不像报错」的关键词，全部按小写子串比较。
///
/// 与面板 `attentionErrorKeywords`（server/service/system_attention.go）
/// 逐项一致，改这张表要同步改面板那边。三处共用它，对同一行给出同一个
/// 判断：面板「需要关注」挑的错误行、日志列表失败行下面显示的错误行
/// （`pickLogErrorLine`）、全屏日志的「首处报错」（`looksLikeLogErrorLine`）。
///
/// 不按词边界匹配：Python 的 `TypeError`、Java 的 `NullPointerException`
/// 前面紧挨着字母，加了词边界反而认不出来。
const List<String> kLogErrorKeywords = <String>[
  'error', 'exception', 'traceback', 'fail', 'fatal', 'timeout', //
  'timed out', 'denied', 'refused', 'not found',
  '错误', '异常', '失败', '超时', '拒绝', '找不到', '不存在',
];
