import 'package:dio/dio.dart';

import '../../../core/network/api_endpoints.dart';
import '../../../core/network/dio_client.dart';

// 「打开已结束的日志时定位到底部」这条账户偏好（issue #147，面板 v3.3.3 起）。
//
// 存在面板 `/api/auth/preferences` 的 list 组里（键 `log_open_at_bottom`），跟账户走：
// 网页端和 APP 读写的是同一个值。list 组是稀疏存储：用户没设过时响应里没有这个键。

/// 用户从没设过时 APP 用的值。
///
/// 取 true 是为了「没设过就保持各端现状」：APP 打开已结束的日志一直在底部
/// （v1.3.6 之前靠自动滚动，v1.3.6 ~ v1.3.7 日志页没给 LogView 传 follow，用的是默认的跟随模式），
/// 而网页端从 v3.2.8 起停在顶部，所以网页端没设过时按 false。
/// 两端默认值不同是有意的，设过一次之后两端都按账户值走。
const bool kOpenFinishedLogAtBottomDefault = true;

/// 读这条偏好。
///
/// 返回 null = 这台面板没有 list 组（v3.3.0 及更早、没有 /auth/preferences 的更老面板、请求失败）：
/// 调用方按 [kOpenFinishedLogAtBottomDefault] 处理，**不给开关、也绝不 PUT** ——
/// v3.2.4 ~ v3.3.0 的 PUT 不认组，收到什么都会把整套编辑器默认值写进库，
/// 冲掉网页端用户存在浏览器本地的编辑器偏好。
/// v3.3.1 / v3.3.2 有 list 组但不认这个键，GET 上看和「v3.3.3 没设过」一模一样，
/// 只能在写的时候靠回显认出来（见 [saveOpenFinishedLogAtBottom]）。
///
/// [dio] 仅供测试注入假适配器，业务代码不传。
Future<bool?> loadOpenFinishedLogAtBottom({Dio? dio}) async {
  try {
    final response = await (dio ?? DioClient.instance.dio).get(
      ApiEndpoints.preferences,
    );
    final data = response.data;
    // 形状探测：有 list 对象才算有这套接口（见 spec/frontend/panel-contract.md）。
    final list = data is Map ? data['list'] : null;
    if (list is! Map) {
      return null;
    }
    // 面板只收、只发 JSON bool；类型不对就当没设过，回落 APP 默认值（开关照常显示）。
    final value = list['log_open_at_bottom'];
    return value is bool ? value : kOpenFinishedLogAtBottomDefault;
  } catch (_) {
    // 404（纯文本或 {"error":"route not found"}）、断网、超时都一样：当面板不支持，
    // 不能因为读偏好失败让日志页打不开。
    return null;
  }
}

/// 写这条偏好，返回面板是否真的存下了。
///
/// 只带这一个键：面板按组、按键合并，别的偏好一个字节都不动。
/// v3.3.1 / v3.3.2 把白名单外的键当空补丁，回 200 但不存；它回显的 list 里没有这个键，
/// 所以这里按回显判断，false 就是「面板太老」。
/// 调用前必须确认 [loadOpenFinishedLogAtBottom] 返回的不是 null。
///
/// [dio] 仅供测试注入假适配器，业务代码不传。
Future<bool> saveOpenFinishedLogAtBottom(bool value, {Dio? dio}) async {
  final response = await (dio ?? DioClient.instance.dio).put(
    ApiEndpoints.preferences,
    data: {
      'list': {'log_open_at_bottom': value},
    },
  );
  final data = response.data;
  final list = data is Map ? data['list'] : null;
  return list is Map && list['log_open_at_bottom'] == value;
}
