import 'package:dio/dio.dart';
import '../network/api_endpoints.dart';
import '../network/dio_client.dart';
import '../storage/secure_storage.dart';
import 'token_refresher.dart';

/// 打在 `RequestOptions.extra` 上的标记：表示这条请求是「续期成功后重发」的。
///
/// 必须有这个标记，否则重发请求再次收到 401 时会重新进入 onError，
/// 而此时 `_isRefreshing` 仍然是 true，重发请求会把自己排进 `_pendingRequests`
/// 并且永远等不到 resolve —— 这条 await 自己等自己，直接死锁。
const String _kRetriedAfterRefresh = '__daidai_retried_after_refresh__';

/// 打在 `RequestOptions.extra` 上的 `FormData` 副本，供 401 续期后重发时替换请求体。
///
/// 为什么需要它：`_retry` 复用的是同一个 `RequestOptions`，也就是**同一个已经被
/// finalize 过的 `FormData` 实例**。dio 的 `FormData.finalize()` 二次调用直接抛
/// `StateError`，所以脚本上传、备份上传这类 multipart 请求一旦撞上 401，
/// 续期是成功的、重发却必然失败，而用户只看到一句「上传失败」。
///
/// 快照必须在 `onRequest` 里拿：那时 `FormData` 还没 finalize，`clone()` 才合法。
const String _kFormDataSnapshot = '__daidai_formdata_snapshot__';

class AuthInterceptor extends Interceptor {
  /// 这些接口的 401 表示「凭据不对」，不是「access token 过期」，不能触发续期：
  /// - login / init / check-init / captcha-config：用户还没有有效会话
  /// - refresh：刷新接口自身，续期它会递归
  /// - logout：用户主动退出，弹「登录已失效」只会让人困惑
  static const Set<String> _noRefreshPaths = {
    ApiEndpoints.login,
    ApiEndpoints.init,
    ApiEndpoints.checkInit,
    ApiEndpoints.captchaConfig,
    ApiEndpoints.refresh,
    ApiEndpoints.logout,
  };

  bool _isRefreshing = false;
  final List<({RequestOptions options, ErrorInterceptorHandler handler})>
  _pendingRequests = [];

  final void Function()? onAuthFailed;

  /// **仅供测试注入**，生产路径一律不传。
  ///
  /// 不在构造时把 `DioClient.instance.dio` 存下来，是因为单例的 baseUrl 会随
  /// 切换面板被改写；两个 getter 都保持「用的时候再取」，注入前后行为一致。
  final Dio? _injectedDio;
  final Dio Function()? _injectedRawDioFactory;

  AuthInterceptor({
    this.onAuthFailed,
    Dio? dio,
    Dio Function()? rawDioFactory,
  }) : _injectedDio = dio,
       _injectedRawDioFactory = rawDioFactory;

  /// 重发用：必须是挂着本拦截器的那个 dio，重发结果才会再走一遍完整链路。
  Dio get _dio => _injectedDio ?? DioClient.instance.dio;

  /// 刷新用：不挂拦截器，避免「刷新失败 → 触发续期 → 再刷新」的递归。
  Dio get _rawDio =>
      _injectedRawDioFactory?.call() ?? DioClient.instance.rawDio;

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final token = await SecureStorage.getAccessToken();
    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    // 趁 FormData 还没被 finalize，留一份可重发的副本。见 _kFormDataSnapshot 的说明。
    // try 是防御性的：clone 失败（例如将来有拦截器排在本拦截器之前并提前 finalize）
    // 只应该退化成「重发仍然失败」这个旧行为，绝不能把正常请求打挂。
    final body = options.data;
    if (body is FormData) {
      try {
        options.extra[_kFormDataSnapshot] = body.clone();
      } catch (_) {}
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    if (err.response?.statusCode != 401) {
      handler.next(err);
      return;
    }

    if (_noRefreshPaths.contains(err.requestOptions.path)) {
      handler.next(err);
      return;
    }

    if (err.requestOptions.extra[_kRetriedAfterRefresh] == true) {
      // 刚换的 access token 又被拒绝，说明会话确实死了，不再重试。
      await _failSession(err, handler);
      return;
    }

    final refreshToken = await SecureStorage.getRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) {
      await _failSession(err, handler);
      return;
    }

    if (_isRefreshing) {
      _pendingRequests.add((options: err.requestOptions, handler: handler));
      return;
    }

    _isRefreshing = true;

    try {
      // 续期动作本身交给 TokenRefresher 单例：SSE 走 package:http、完全不经过
      // dio 拦截器，它 401 时调的是同一个入口。两条链路共用「正在飞的那次刷新」，
      // 才不会出现「两处同时刷新、后一个把前一个的新 token 覆盖成过期值」。
      // rawDio 不挂拦截器，刷新失败不会递归回到这里。
      final newAccessToken = await TokenRefresher.instance.refresh(
        rawDioFactory: () => _rawDio,
      );

      handler.resolve(await _retry(err.requestOptions, newAccessToken));
      await _flushPending(newAccessToken);
    } catch (_) {
      await SecureStorage.clearAuthSession();
      onAuthFailed?.call();
      handler.next(err);
      _rejectPending('Token refresh failed');
    } finally {
      _isRefreshing = false;
      // 兜底：重发期间又排进来、且没被 _flushPending 取走的请求必须显式拒绝，
      // 直接 clear() 会让它们的 handler 永远悬着，调用方的 await 再也不返回。
      _rejectPending('Token refresh finished before this request was queued');
    }
  }

  /// 会话确认失效：清本地凭据 + 通知上层跳登录页，并把原始错误抛回调用方。
  Future<void> _failSession(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    await SecureStorage.clearAuthSession();
    onAuthFailed?.call();
    handler.next(err);
  }

  Future<Response<dynamic>> _retry(
    RequestOptions options,
    String accessToken,
  ) {
    options.headers['Authorization'] = 'Bearer $accessToken';
    options.extra[_kRetriedAfterRefresh] = true;
    // multipart 请求必须换上 onRequest 留的那份未使用副本，
    // 否则这里发出去的是已经 finalize 过的旧实例，重发必然抛 StateError。
    // 取完就清掉：重发只会发生一次（_kRetriedAfterRefresh 保证第二次 401 直接失败退出），
    // 留着只是白白多持有一份文件字节。
    final snapshot = options.extra[_kFormDataSnapshot];
    if (snapshot is FormData) {
      options.data = snapshot;
      options.extra.remove(_kFormDataSnapshot);
    }
    return _dio.fetch(options);
  }

  /// 重发续期期间积压的请求。用 while 而不是 for-in：
  /// 重发本身是异步的，期间可能又有请求排进队列，必须一并处理干净。
  Future<void> _flushPending(String accessToken) async {
    while (_pendingRequests.isNotEmpty) {
      final pending = _pendingRequests.removeAt(0);
      try {
        pending.handler.resolve(await _retry(pending.options, accessToken));
      } catch (e) {
        pending.handler.reject(
          e is DioException
              ? e
              : DioException(requestOptions: pending.options, error: e),
        );
      }
    }
  }

  void _rejectPending(String reason) {
    if (_pendingRequests.isEmpty) {
      return;
    }
    final pending = List.of(_pendingRequests);
    _pendingRequests.clear();
    for (final item in pending) {
      item.handler.reject(
        DioException(requestOptions: item.options, error: reason),
      );
    }
  }
}
