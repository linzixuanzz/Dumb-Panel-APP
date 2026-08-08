import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../network/api_endpoints.dart';
import '../network/dio_client.dart';
import '../storage/secure_storage.dart';

String _extractAccessToken(dynamic responseData) {
  if (responseData is Map) {
    final directToken = responseData['access_token']?.toString();
    if (directToken != null && directToken.isNotEmpty) {
      return directToken;
    }

    final nestedData = responseData['data'];
    if (nestedData is Map) {
      final nestedToken = nestedData['access_token']?.toString();
      if (nestedToken != null && nestedToken.isNotEmpty) {
        return nestedToken;
      }
    }
  }

  throw StateError('Missing access_token in refresh response');
}

/// 全仓库**唯一**的 access token 续期入口。
///
/// 为什么必须收敛成单例：dio（`AuthInterceptor`）和 SSE（`SseClient` 走
/// `package:http`，根本不经过 dio 拦截器）是两条独立链路。如果各写一份续期，
/// token 过期时两边会同时打 `/auth/refresh`，**后返回的那次会把先返回的新 token
/// 覆盖掉**，而它自己带的可能已经是服务端换掉的旧值 —— 用户看到的是
/// 「刚续期完又掉线」，而且这种竞态只在两条链路同时活跃时出现，极难复现。
///
/// 共用同一个 `_inFlight` 之后，第二个调用方拿到的是**同一个 Future**，
/// 「同一时刻只有一次续期在飞」由类型系统而不是自觉来保证。
class TokenRefresher {
  TokenRefresher._();

  static final TokenRefresher instance = TokenRefresher._();

  Future<String>? _inFlight;

  /// 会话确认失效（refresh token 也过期了）时的统一出口，在 `main.dart` 注册。
  /// 与 `AuthInterceptor.onAuthFailed` 指向同一个闭包，
  /// 保证 REST 与 SSE 掉线后走的是同一套「清凭据 + 跳登录页」。
  void Function()? onSessionExpired;

  static Dio _defaultRawDioFactory() => DioClient.instance.rawDio;

  /// 换一个可用的 access token；失败时抛异常，由调用方决定怎么收场。
  ///
  /// [staleToken] 是调用方**实际用出去并被服务端拒绝**的那个 token。
  /// 如果本地存的已经不是它，说明另一条链路刚刚续过期了，直接复用即可 ——
  /// 少打一次刷新接口，也少一次「刚换的新 token 又被自己换掉」的机会。
  /// 不传则一律走刷新（dio 那条链路的既有行为，不动）。
  Future<String> refresh({
    String? staleToken,
    Dio Function()? rawDioFactory,
  }) async {
    if (staleToken != null && staleToken.isNotEmpty) {
      final current = await SecureStorage.getAccessToken();
      if (current != null && current.isNotEmpty && current != staleToken) {
        return current;
      }
    }
    return _joinOrStart(rawDioFactory);
  }

  Future<String> _joinOrStart(Dio Function()? rawDioFactory) {
    final inFlight = _inFlight;
    if (inFlight != null) {
      // 已经有一次在飞：直接搭车，绝不并发发起第二次。
      return inFlight;
    }

    // 用 whenComplete 而不是 then/catchError：成功失败都必须把「正在飞」清掉，
    // 否则一次失败会把之后所有续期永久钉死在这个已完成的失败 Future 上，
    // 用户重新登录后照样每次都拿到旧的失败结果。
    final tracked = _requestNewAccessToken(rawDioFactory).whenComplete(() {
      _inFlight = null;
    });
    _inFlight = tracked;
    return tracked;
  }

  Future<String> _requestNewAccessToken(Dio Function()? rawDioFactory) async {
    final refreshToken = await SecureStorage.getRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) {
      throw StateError('Missing refresh token');
    }

    // rawDio 不挂拦截器：刷新自身返回 401 时不会再触发一轮续期。
    final dio = (rawDioFactory ?? _defaultRawDioFactory)();
    final response = await dio.post(
      ApiEndpoints.refresh,
      options: Options(headers: {'Authorization': 'Bearer $refreshToken'}),
    );

    final newAccessToken = _extractAccessToken(response.data);
    await SecureStorage.saveAccessToken(newAccessToken);
    return newAccessToken;
  }

  /// 会话确认失效：清本地凭据 + 通知上层跳登录页。
  ///
  /// `AuthInterceptor` 有自己的 `_failSession`（它还要把原始 DioException
  /// 抛回调用方），这里是给没有 dio handler 的链路（SSE）用的同款出口。
  Future<void> notifySessionExpired() async {
    await SecureStorage.clearAuthSession();
    onSessionExpired?.call();
  }

  /// **仅供测试**：清掉跨用例残留的「正在飞的刷新」与回调。
  /// 单例的状态会在同一个测试文件里串场，不重置会出现「上一条用例的假 dio
  /// 被下一条用例复用」这种查半天的假红/假绿。
  @visibleForTesting
  void resetForTest() {
    _inFlight = null;
    onSessionExpired = null;
  }
}
