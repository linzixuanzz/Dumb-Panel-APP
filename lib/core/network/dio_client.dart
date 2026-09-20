import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import '../storage/secure_storage.dart';
import 'app_user_agent.dart';

final _logger = Logger(printer: PrettyPrinter(methodCount: 0));

class DioClient {
  static DioClient? _instance;
  late final Dio dio;
  String _baseUrl = '';

  DioClient._() {
    dio = Dio(
      BaseOptions(
        // 4xx 必须让 dio 判定为失败，才能进入 onError，AuthInterceptor 的 401 续期
        // 才会真正执行。历史上这里写的是 status < 500：401 被当成成功响应，
        // 70 行续期逻辑整段是死代码，用户看到的是「暂无数据」而不是「请重新登录」。
        // 收紧后所有 4xx 都会抛 DioException，新增调用点必须自己确认 catch 兜得住。
        validateStatus: (status) => status != null && status < 400,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        sendTimeout: const Duration(seconds: 15),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          ...AppUserAgent.defaultHeaders,
        },
      ),
    );

    if (kDebugMode) {
      dio.interceptors.add(
        LogInterceptor(
          request: false,
          requestHeader: false,
          requestBody: false,
          responseHeader: false,
          responseBody: false,
          logPrint: (obj) => _logger.d(obj),
        ),
      );
    }
  }

  static DioClient get instance {
    _instance ??= DioClient._();
    return _instance!;
  }

  String get baseUrl => _baseUrl;

  /// 当前面板的代号，[setBaseUrl] 在**地址真的变了**时自增（issue #13，v1.3.7）。
  ///
  /// 给 SSE 用：`SseClient._generation` 是实例级的，只管得住「同一个 SseClient 自己的新旧连接」；
  /// 换面板时在飞的是**别的页面**持有的实例，它们的 `_generation` 一点没变，
  /// 那次重连就会读到新面板的 baseUrl 和 token，把 B 的日志推进还没 dispose 的 A 页面里。
  ///
  /// 放在 DioClient 而不是 SseClient，是因为 sse_client 本来就 import 了 dio_client，
  /// 反过来会成环，而且方向也不对——底层的 network client 不该依赖上层的 SSE。
  /// 也不做成「切换时遍历关掉所有实例」：4 个 SseClient 全是页面私有字段
  /// （task_list / log_stream / dep_list / subscription_list），全仓没有注册表，
  /// 一个静态代号就够了，且不需要任何一方记得注册。
  static int panelGeneration = 0;

  void setBaseUrl(String url) {
    final normalized =
        url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    // 地址真的变了才算「换面板」。必须先比对再赋值：启动时 main.dart 会拿本来就存着的
    // 地址调一次，登录流程里也会用同一个地址重复调，无条件自增会把那几次也当成换面板，
    // 顺手作废掉正在正常工作的 SSE 流。
    if (_baseUrl.isNotEmpty && _baseUrl != normalized) {
      panelGeneration++;
    }
    _baseUrl = normalized;
    dio.options.baseUrl = _baseUrl;
    dio.options.headers.addAll(AppUserAgent.defaultHeaders);
    // 登录凭据按面板分片后（issue #13，v1.3.7），scope 切换全部收口在这一行。
    // 放这里是因为它同步、无 await：baseUrl 一改，后面任何一次读 token 拿到的就已经是
    // 新面板那份，中间不存在「请求打到 B、带的却是 A 的 token」的窗口。
    // 每个 setBaseUrl 调用点都自动获得正确的 scope，不需要各自再记得切一次。
    SecureStorage.setActiveServer(_baseUrl);
  }

  /// 专供 token 刷新使用：每次调用都新建实例，且**不挂任何拦截器**。
  /// 因此刷新请求自身返回 401 时不会再次进入 AuthInterceptor.onError，
  /// 不存在「刷新失败 → 触发续期 → 再刷新」的递归。
  ///
  /// validateStatus 同样收紧到 < 400：刷新被拒时直接抛 DioException，
  /// 由 AuthInterceptor 的 catch 统一走「清会话 + 跳登录页」，
  /// 而不是靠解析响应体失败（StateError）间接兜底。
  Dio get rawDio => Dio(
    BaseOptions(
      baseUrl: _baseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      validateStatus: (status) => status != null && status < 400,
      headers: {'Accept': 'application/json', ...AppUserAgent.defaultHeaders},
    ),
  );

  /// 专供**票据鉴权**的下载接口使用（目前只有 `/logs/:id/raw`）：
  /// 有 baseUrl，但**一个拦截器都不挂**。
  ///
  /// 为什么不能走 [dio] 单例 —— 不是「带上 Authorization 也无害」那么简单：
  /// 票据接口的 401 含义是「票据缺失 / 无效 / 已过期」，**不是** access token 过期。
  /// 走单例的话 AuthInterceptor 会把它当成 token 过期：先去续期，再带新 token 重发；
  /// 重发照样 401（票据并没有换新的），而这一次带着 `_kRetriedAfterRefresh` 标记，
  /// 直接判定会话失效 → `clearAuthSession()` + 跳登录页。
  /// 也就是说**一张过期 120 秒的下载票据会把用户踢下线**。
  ///
  /// 顺带也避免了把 Bearer token 发给一条压根不校验它的路由。
  ///
  /// 超时比 [rawDio] 长很多：这条拉的是日志文件本体（面板侧单文件可以到 MB 级），
  /// 不是一个 JSON。
  Dio get ticketDio => Dio(
    BaseOptions(
      baseUrl: _baseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(minutes: 2),
      validateStatus: (status) => status != null && status < 400,
      // 不写 Accept: application/json —— 正常响应是 text/plain 的文件流。
      headers: {...AppUserAgent.defaultHeaders},
    ),
  );
}
