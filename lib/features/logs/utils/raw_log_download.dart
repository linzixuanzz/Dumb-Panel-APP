import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../core/network/api_endpoints.dart';
import '../../../core/network/dio_client.dart';
import '../../../shared/utils/api_utils.dart';

// 「下载原始日志」的客户端侧。
//
// 为什么需要它：APP 的日志详情页把整段日志渲染成一棵 ANSI TextSpan 树，日志一大就卡；
// 而且页面里那份文本已经按终端语义折叠过裸 \r，想按字节比对磁盘文件、
// 排查脚本吐出的终端控制序列时是拿不到的。面板为此提供了「服务端直传磁盘文件」
// 的接口，这里把它接过来。
//
// 面板端是**两步票据**（server/pkg/dlticket + handler/log_raw_download.go）：
//  1. GET /logs/:id/raw-ticket —— 鉴权与 /logs/:id 完全一致（JWTAuth +
//     OpenAPIAccess("logs") + RequireRole("viewer")）。校验通过并在磁盘上定位到
//     文件之后，签发一张 HMAC 签名、绑定这一个文件、**120 秒**过期的票据，
//     并把拼好票据的下载地址一起下发；
//  2. GET /logs/:id/raw?ticket=... —— 这条**没有挂 JWT 中间件**，只认票据。
//
// 面板那么设计是因为浏览器的 `<a download>` 带不了 Authorization 头。
// APP 没有这个限制，但仍然照着走，原因有两个：
//  - 这是面板已有的、被服务端测试钉死的契约，另开一条路等于让面板多养一个接口；
//  - 票据只绑定单个文件、活 120 秒，比把长期 access token 塞进 URL 安全得多。
//
// ⚠️ 票据拿到就要立刻用：120 秒的窗口只够覆盖「换票 → 发起下载」。
// 所以调用方的顺序必须是「先把文件字节拉完，再弹系统保存框让用户挑位置」——
// 反过来的话，用户在保存框里磨蹭一会儿票就过期了。

/// 原始日志下载失败，且原因是能直接说给用户听的那一类。
///
/// 单独立一个类型，是为了让页面能区分「已经翻译好的中文原因」和
/// 「还需要过一遍 extractListErrorMessage 的原始异常」。
class RawLogDownloadException implements Exception {
  const RawLogDownloadException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// `GET /logs/:id/raw-ticket` 的响应里 APP 真正用得上的部分。
///
/// 面板还下发了 `size` / `expires_at` / `expires_in`，这里**不解析** ——
/// 页面既不展示大小也不倒计时（票据拿到就立刻用掉了），解析了却不用
/// 只会多出一份需要跟着面板改的字段清单。
class RawLogTicket {
  const RawLogTicket({
    required this.path,
    required this.query,
    required this.filename,
  });

  /// 下载路径（相对面板 baseUrl）。
  final String path;

  /// 下载地址上的全部查询参数。
  ///
  /// **原样带回**而不是只挑 `ticket`：票据签名的原文里含有「资源标识」，
  /// 日志文件那一套（`/tasks/:id/log-files/:filename/raw`）在 `ticket` 之外
  /// 还会带一个 `path=`，少一个参数服务端就算不出同一个资源标识、验签必失败。
  /// 现在 APP 只用到执行日志那一套，但这里不写成「只取 ticket」，
  /// 免得将来接日志文件浏览时留一个很难查的坑。
  final Map<String, String> query;

  /// 服务端决定的下载文件名（`<任务名>-<日志ID>-raw.log`）。
  final String filename;
}

/// 已经下载到内存、等待写盘的原始日志文件。
class RawLogFile {
  const RawLogFile({required this.filename, required this.bytes});

  final String filename;
  final Uint8List bytes;
}

/// 解析换票响应，并校验下发的下载地址确实指向 [expectedPath]。
///
/// 校验不是多此一举：这个地址是从响应体里读出来、马上要带着票据去请求的。
/// 两条硬性拒绝：
///  - **带 scheme 或以 `//` 开头** —— 那等于把票据发到另一台主机；
///  - **路径不是本条日志的 `/raw`** —— 说明地址被改写过或面板行为变了，
///    与其闷头请求一个未知路径，不如当场报错，出问题时也好查。
///
/// 面板那边的推导逻辑是「把请求路径的 `-ticket` 后缀去掉」
/// （handler/log_raw_download.go 的 issueRawLogTicket），而且服务端测试
/// 就断言了 `HasPrefix(url, "/api/v1/logs/<id>/raw?")`——这个形状面板自己也锁着。
RawLogTicket parseRawLogTicket(
  dynamic payload, {
  required String expectedPath,
  required String fallbackFilename,
}) {
  final data = extractData(payload);
  if (data is! Map) {
    throw const RawLogDownloadException('面板返回的下载票据格式无法识别');
  }

  final rawUrl = data['url']?.toString().trim() ?? '';
  if (rawUrl.isEmpty) {
    throw const RawLogDownloadException('面板没有返回下载地址');
  }

  final uri = Uri.tryParse(rawUrl);
  if (uri == null) {
    throw const RawLogDownloadException('面板返回的下载地址无法解析');
  }

  if (uri.hasScheme || uri.hasAuthority) {
    throw const RawLogDownloadException('面板返回的下载地址指向了其它主机，已拒绝下载');
  }
  if (uri.path != expectedPath) {
    throw const RawLogDownloadException('面板返回的下载地址与这条日志不符，已拒绝下载');
  }

  final query = Map<String, String>.from(uri.queryParameters);
  if ((query['ticket'] ?? '').trim().isEmpty) {
    throw const RawLogDownloadException('面板返回的下载地址里没有票据');
  }

  final filename = data['filename']?.toString().trim() ?? '';

  return RawLogTicket(
    path: uri.path,
    query: query,
    filename: filename.isEmpty ? fallbackFilename : filename,
  );
}

/// 换票失败的原因。
///
/// 面板自己的 4xx 一定带 JSON body：403 是 `{"error":"拒绝访问"}`（RequireRole），
/// 404 是 `{"error":"日志不存在"}` 或 `{"error":"该日志没有独立的原始日志文件…"}`，
/// 这些由 [extractListErrorMessage] 原样取出，用户看到的就是面板的原话。
///
/// **没有 body 的 404 是另一回事**：gin 找不到路由时回的是纯文本
/// `404 page not found` —— 也就是这台面板压根没有 raw-ticket 这条路由（老面板）。
/// 靠「形状」而不是版本号判断，理由见 spec/frontend/panel-contract.md。
String rawLogTicketErrorMessage(Object error) {
  if (_isMissingRoute(error)) {
    return '当前面板不支持下载原始日志，请升级面板后再试';
  }
  return extractListErrorMessage(error, '获取下载票据失败');
}

/// 把 `/raw` 的错误响应翻译成人话。
///
/// 这条请求用的是 `ResponseType.bytes`，dio 不会把 4xx 的 JSON body 解成 Map，
/// 直接丢给 [extractErrorMessage] 只会拿到一句英文
/// （"The request returned an invalid status code of 401."）。
/// 面板写在 body 里的中文原因（"下载票据已过期，请重新发起下载" /
/// "原始日志文件不存在或已被清理"）必须先自己从字节里解出来。
String rawLogDownloadErrorMessage(Object error) {
  final backendMessage = _backendErrorMessage(error);
  if (backendMessage != null) {
    return backendMessage;
  }
  if (_isMissingRoute(error)) {
    return '当前面板不支持下载原始日志，请升级面板后再试';
  }

  final status = error is DioException ? error.response?.statusCode : null;
  if (status == 401) {
    // 走到这里说明 401 连 body 都没有（多半是反代插手）。这条路由上的 401
    // 只可能是票据问题，重来一次就好，**绝不能**当成登录失效 ——
    // 见 DioClient.ticketDio 的注释。
    return '下载票据已失效，请重新点击下载';
  }
  // 其余状态码不猜原因：面板在这条路由上只回 401 / 404 且都带 body，
  // 到这里已经是未知情况，硬编一句「无权限」只会把排查带偏。
  return extractListErrorMessage(error, '下载原始日志失败');
}

/// 「这台面板没有这条路由」——404 且响应体不是面板格式的错误 JSON。
bool _isMissingRoute(Object error) {
  if (error is! DioException || error.response?.statusCode != 404) {
    return false;
  }
  return _backendErrorMessage(error) == null;
}

/// 执行「换票 → 拉文件」两步。
class RawLogDownloader {
  /// 两个 dio 都**仅供测试注入**，生产路径一律不传。
  /// 不在构造时把单例存进字段：单例的 baseUrl 会随切换面板被改写。
  const RawLogDownloader({Dio? ticketDio, Dio? downloadDio})
    : _injectedTicketDio = ticketDio,
      _injectedDownloadDio = downloadDio;

  final Dio? _injectedTicketDio;
  final Dio? _injectedDownloadDio;

  /// 换票走常规链路：这条**需要**带 Authorization，它的 401 也确实是
  /// access token 过期，交给 AuthInterceptor 续期后重发是对的。
  Dio get _ticketDio => _injectedTicketDio ?? DioClient.instance.dio;

  /// 下载走无拦截器的链路。为什么不能共用单例见 [DioClient.ticketDio] 的注释：
  /// 票据失效的 401 会被 AuthInterceptor 误判成会话失效，把用户踢下线。
  Dio get _downloadDio => _injectedDownloadDio ?? DioClient.instance.ticketDio;

  /// 下载一条执行日志记录对应的磁盘原始日志文件。
  Future<RawLogFile> downloadTaskLog(int logId) async {
    final ticket = await _issueTicket(logId);
    final bytes = await _fetchFile(ticket);
    return RawLogFile(filename: ticket.filename, bytes: bytes);
  }

  Future<RawLogTicket> _issueTicket(int logId) async {
    final response = await _guard(
      () => _ticketDio.get(ApiEndpoints.logRawTicket(logId)),
      rawLogTicketErrorMessage,
    );

    return parseRawLogTicket(
      response.data,
      expectedPath: ApiEndpoints.logRaw(logId),
      fallbackFilename: 'task-log-$logId-raw.log',
    );
  }

  Future<Uint8List> _fetchFile(RawLogTicket ticket) async {
    final response = await _guard(
      () => _downloadDio.get(
        ticket.path,
        queryParameters: ticket.query,
        options: Options(responseType: ResponseType.bytes),
      ),
      rawLogDownloadErrorMessage,
    );

    final bytes = extractResponseBytes(response.data);
    if (bytes == null || bytes.isEmpty) {
      throw const RawLogDownloadException('原始日志文件是空的，没有可保存的内容');
    }
    return bytes;
  }
}

/// 把请求异常统一换成 [RawLogDownloadException]。
///
/// 页面只需要 catch 一个类型就能拿到已经翻译好的中文原因，
/// 不必在 UI 层再判一次「这是 DioException 还是别的」。
Future<Response<dynamic>> _guard(
  Future<Response<dynamic>> Function() request,
  String Function(Object error) describe,
) async {
  try {
    return await request();
  } catch (error) {
    throw RawLogDownloadException(describe(error));
  }
}

/// 取出面板写在响应体里的 `error` / `message`。
///
/// 三种形态都要吃：
///  - Map —— 换票接口走默认 `ResponseType.json`，dio 已经解好了；
///  - List&lt;int&gt; —— 下载接口用 `ResponseType.bytes`，dio 原样给字节；
///  - String —— 反代或 gin 默认 404 回的纯文本，解 JSON 会失败，那就当没有。
String? _backendErrorMessage(Object error) {
  if (error is! DioException) {
    return null;
  }
  final data = error.response?.data;

  Object? decoded;
  if (data is List<int>) {
    try {
      decoded = jsonDecode(utf8.decode(data));
    } catch (_) {
      return null;
    }
  } else if (data is String) {
    try {
      decoded = jsonDecode(data);
    } catch (_) {
      return null;
    }
  } else {
    decoded = data;
  }

  if (decoded is Map) {
    final message = (decoded['error'] ?? decoded['message'])?.toString().trim();
    if (message != null && message.isNotEmpty) {
      return message;
    }
  }
  return null;
}
