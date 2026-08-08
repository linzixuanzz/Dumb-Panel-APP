import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;

import '../auth/token_refresher.dart';
import '../storage/secure_storage.dart';
import 'app_user_agent.dart';
import 'dio_client.dart';

class SseEvent {
  final String? event;
  final String data;
  SseEvent({this.event, required this.data});
}

/// 续期失败（refresh token 也过期了）时通过 `onError` 交给页面的哨兵。
///
/// 页面靠它区分两件后果完全不同的事：
///   - 网络断了 → 重试 / 降级轮询是有意义的；
///   - 会话没了 → 再重试也只会一路 401，只是刷屏，应该停下等跳登录页。
class SseAuthFailure {
  const SseAuthFailure([this.message = '登录已失效，请重新登录']);

  final String message;

  @override
  String toString() => message;
}

class SseClient {
  SseClient({
    http.Client Function()? httpClientFactory,
    Dio Function()? rawDioFactory,
  }) : _httpClientFactory = httpClientFactory ?? _defaultHttpClientFactory,
       _rawDioFactory = rawDioFactory;

  static http.Client _defaultHttpClientFactory() => http.Client();

  /// **仅供测试注入**，生产路径一律不传。
  final http.Client Function() _httpClientFactory;

  /// **仅供测试注入**：刷新接口用的 dio。生产走 `DioClient.instance.rawDio`。
  final Dio Function()? _rawDioFactory;

  http.Client? _client;
  StreamSubscription<String>? _subscription;
  bool _closed = false;

  /// 每次 `connect` / `close` 都自增，所有异步回调（延迟重连、续期后重连）
  /// 都带着发起时的代号，对不上就直接放弃。
  ///
  /// 没有这个代号会怎样：页面调 `close()` 紧接着 `connect()` 时，
  /// 上一轮排在 `Future.delayed` 里的重连只看 `_closed`，
  /// 而 `_closed` 已经被新的 `connect()` 置回 false —— 于是两条流同时往同一个
  /// 页面推日志，`_client` 字段被后者覆盖，前者永远没人关。
  int _generation = 0;

  /// 本轮连接是否已经用掉那一次「续期后重连」的额度。
  ///
  /// 等价于 dio 侧打在 `RequestOptions.extra` 上的 `_kRetriedAfterRefresh`：
  /// 换了新 token 还是 401，说明会话真的死了，必须停。
  /// 少了这个开关就是 401 → 续期 → 401 → 续期的无限循环，
  /// 而 SSE 这边没有 `RequestOptions` 可以挂标记，只能自己记。
  bool _refreshRetryUsed = false;

  String _path = '';
  bool _autoReconnect = false;
  void Function(SseEvent event)? _onEvent;
  void Function()? _onDone;
  void Function(dynamic error)? _onError;
  void Function()? _onReconnect;

  /// [onReconnect] 在**每次重新建立连接之前**回调（续期后重连、服务端
  /// `done: reconnect` 重连都会触发）。服务端不支持断点续传，重连一定会把历史
  /// 从头重放一遍，页面要在这个回调里把已显示的行灌进 `SseReplayBuffer` 去重。
  Future<void> connect({
    required String path,
    required void Function(SseEvent event) onEvent,
    void Function()? onDone,
    void Function(dynamic error)? onError,
    void Function()? onReconnect,
    bool autoReconnect = false,
  }) async {
    _closed = false;
    _refreshRetryUsed = false;
    _path = path;
    _autoReconnect = autoReconnect;
    _onEvent = onEvent;
    _onDone = onDone;
    _onError = onError;
    _onReconnect = onReconnect;

    await _doConnect(++_generation);
  }

  bool _isStale(int generation) => _closed || generation != _generation;

  Future<void> _doConnect(int generation) async {
    if (_isStale(generation)) return;

    final baseUrl = DioClient.instance.baseUrl;
    final token = await SecureStorage.getAccessToken();
    if (_isStale(generation)) return;

    final url = Uri.parse('$baseUrl$_path');
    final client = _httpClientFactory();
    _client = client;

    final request = http.Request('GET', url);
    request.headers.addAll(AppUserAgent.defaultHeaders);
    request.headers['Accept'] = 'text/event-stream';
    request.headers['Cache-Control'] = 'no-cache';
    if (token != null && token.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $token';
    }

    try {
      final response = await client.send(request);

      if (_isStale(generation)) {
        client.close();
        return;
      }

      if (response.statusCode == 401) {
        // 长时间挂着实时日志正是 token 过期的高发场景：任务跑半小时，
        // 中途服务端 done:reconnect 触发重连，这一次重连才吃到 401。
        await _handleUnauthorized(generation, token);
        return;
      }

      if (response.statusCode >= 400) {
        // 以前这里只判 401：404 / 500 会被当成一条空的 SSE 流解析完，
        // 用户看到的是「连接结束」而不是失败原因。
        _disposeConnection();
        _onError?.call('连接失败（HTTP ${response.statusCode}）');
        return;
      }

      // 连上了就说明这个 token 是好的，把续期重连的额度还回去。
      // 不还的话，一次会话里只允许续期一次 —— 用户看两小时日志，
      // 第二次过期就直接掉线，正好又是这次要修的场景。
      _refreshRetryUsed = false;

      String buffer = '';
      String? currentEvent;

      _subscription = response.stream
          .transform(utf8.decoder)
          .listen(
            (chunk) {
              // cancel() 之后仍可能有一帧已经排在事件队列里，
              // 页面已经 dispose 或换了新连接时不能再往上推。
              if (_isStale(generation)) return;

              buffer += chunk;
              final lines = buffer.split('\n');
              buffer = lines.removeLast(); // 保留不完整的行

              for (final line in lines) {
                if (line.startsWith('event: ')) {
                  currentEvent = line.substring(7).trim();
                } else if (line.startsWith('data: ')) {
                  final data = line.substring(6);
                  _onEvent?.call(SseEvent(event: currentEvent, data: data));

                  // 处理 done 事件的 reconnect
                  if (currentEvent == 'done' &&
                      data == 'reconnect' &&
                      _autoReconnect &&
                      !_isStale(generation)) {
                    _scheduleReconnect(generation, const Duration(seconds: 1));
                    return;
                  }

                  currentEvent = null;
                } else if (line.isEmpty) {
                  currentEvent = null;
                }
              }
            },
            onDone: () {
              if (!_isStale(generation)) _onDone?.call();
            },
            onError: (error) {
              if (!_isStale(generation)) _onError?.call(error);
            },
            cancelOnError: true,
          );
    } catch (e) {
      if (!_isStale(generation)) _onError?.call(e);
    }
  }

  /// 401 的唯一出口：复用 dio 那边同一个续期入口，再重连一次。
  ///
  /// [usedToken] 是这次连接实际发出去、被服务端拒掉的那个 access token。
  /// 交给 `TokenRefresher` 是为了「本地存的已经不是它了」时直接复用别人续好的，
  /// 而不是再打一次刷新接口。
  Future<void> _handleUnauthorized(int generation, String? usedToken) async {
    _disposeConnection();

    if (_refreshRetryUsed) {
      // 刚换来的 token 又被拒 —— 会话确实死了，到此为止，不再重连。
      await _failSession(generation);
      return;
    }
    _refreshRetryUsed = true;

    try {
      await TokenRefresher.instance.refresh(
        staleToken: usedToken,
        rawDioFactory: _rawDioFactory,
      );
    } catch (_) {
      await _failSession(generation);
      return;
    }

    if (_isStale(generation)) return;

    // 续期成功 → 立刻重连，用户不该看到任何提示（无感）。
    _scheduleReconnect(generation, Duration.zero);
  }

  Future<void> _failSession(int generation) async {
    // 与 REST 那条链路走同一个出口：清本地凭据 + 通知上层跳登录页。
    await TokenRefresher.instance.notifySessionExpired();
    if (_isStale(generation)) return;
    _onError?.call(const SseAuthFailure());
  }

  void _scheduleReconnect(int generation, Duration delay) {
    _disposeConnection();
    Future.delayed(delay, () {
      if (_isStale(generation)) return;
      // 服务端这四条流都没有 Last-Event-ID / id: 帧，重连一律从头重放整段历史。
      // 先让页面把「已显示的行」灌进去重缓冲，重放上来的行才不会显示两遍。
      _onReconnect?.call();
      _doConnect(generation);
    });
  }

  void _disposeConnection() {
    _subscription?.cancel();
    _subscription = null;
    _client?.close();
    _client = null;
  }

  void close() {
    _closed = true;
    _generation++;
    _disposeConnection();
  }
}
