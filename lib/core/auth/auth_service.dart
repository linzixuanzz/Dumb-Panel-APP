import 'package:dio/dio.dart';
import '../network/app_user_agent.dart';
import '../network/api_endpoints.dart';
import '../network/dio_client.dart';
import '../storage/secure_storage.dart';
import '../../shared/models/user.dart';

/// 从响应中提取 data 字段，兼容 {code, data: {...}} 和直接 {...} 两种格式
dynamic _extractData(dynamic responseData) {
  if (responseData is Map<String, dynamic> &&
      responseData.containsKey('data')) {
    return responseData['data'];
  }
  return responseData;
}

class AuthService {
  final Dio _dio = DioClient.instance.dio;

  /// 返回 true 表示需要初始化，false 表示已初始化
  Future<bool> needsInitialization() async {
    try {
      final response = await _dio.get(ApiEndpoints.checkInit);
      final raw = response.data;
      if (raw is Map<String, dynamic>) {
        // 后端实际返回: {"need_init": false}
        if (raw.containsKey('need_init')) {
          return raw['need_init'] == true;
        }
        // 兼容: {data: {need_init: true}}
        if (raw['data'] is Map<String, dynamic>) {
          final data = raw['data'] as Map<String, dynamic>;
          if (data.containsKey('need_init')) {
            return data['need_init'] == true;
          }
          if (data.containsKey('initialized')) {
            return data['initialized'] == false;
          }
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> initAdmin(String username, String password) async {
    await _dio.post(
      ApiEndpoints.init,
      data: {'username': username, 'password': password},
    );
  }

  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
    String? totpCode,
    Map<String, dynamic>? captcha,
  }) async {
    final data = <String, dynamic>{'username': username, 'password': password};
    if (totpCode != null && totpCode.isNotEmpty) {
      data['totp_code'] = totpCode;
    }
    if (captcha != null && captcha.isNotEmpty) {
      data['captcha'] = captcha;
    }

    // 登录接口的 401 有两种**完全不同**的含义，必须在这里分开处理：
    //
    // 1. 「还差一步」：账号开了两步验证（server/handler/auth.go 返回
    //    401 + two_factor_required），或者验证码要求/失效（401 + captcha_required）。
    //    这属于正常登录流程，login_page 拿到这个 map 后才会把 TOTP 输入框渲染出来、
    //    或者重新拉起滑块。
    // 2. 「真失败」：用户名或密码错误，页面要显示错误文案。
    //
    // DioClient 的全局 validateStatus 收紧到 < 400（为的是让 401 进 AuthInterceptor
    // 做 token 续期，那行**不能动**），所有 401 都会就地抛 DioException，
    // 于是第 1 种情况的响应体压根走不到下面的解析代码 —— 用户看到红字
    // 「请输入两步验证码」，页面上却根本没有能输验证码的地方，等于永久登不进去。
    //
    // 所以这里跟下面的 captchaConfig() 一样做**请求级**放宽，再自己区分这两类 4xx。
    final response = await _dio.post(
      ApiEndpoints.login,
      data: data,
      options: Options(
        // 只放宽到 < 500：5xx（含验证码服务不可用的 503）仍旧抛异常，语义不变。
        validateStatus: (status) => status != null && status < 500,
      ),
    );

    final statusCode = response.statusCode ?? 0;
    final raw = response.data;
    // 只有带「还差一步」标记的 4xx 才按正常返回值往下走，交给 login_page 的既有分支。
    // 注意密码错误时服务端也会带 captcha_required，但值取的是「验证码功能是否开启」：
    // 没开就是 false，走下面的抛异常分支；开了则由 login_page 显示后端给的 error 文案。
    final needsExtraStep =
        raw is Map &&
        (raw['two_factor_required'] == true || raw['captcha_required'] == true);
    if (statusCode >= 400 && !needsExtraStep) {
      // 其余 4xx 保持收紧后的语义：抛带 response 的 DioException，
      // auth_provider._extractErrorMessage 会从 body 的 error 里取出
      // 「用户名或密码错误」这类后端文案，403 的反代提示也依赖它。
      throw DioException.badResponse(
        statusCode: statusCode,
        requestOptions: response.requestOptions,
        response: response,
      );
    }

    final result = _extractData(response.data);
    final Map<String, dynamic> map = result is Map<String, dynamic>
        ? result
        : {};

    if (map.containsKey('access_token')) {
      await SecureStorage.saveTokens(
        accessToken: map['access_token'] as String,
        refreshToken: map['refresh_token'] as String,
      );
    }

    return map;
  }

  Future<Map<String, dynamic>> captchaConfig({String? username}) async {
    // 这里**故意**保留放宽的 validateStatus：老面板没有 /auth/captcha-config，
    // 会返回 404。若跟着全局收紧成抛异常，登录流程会在取验证码配置这一步就中断，
    // 老面板将无法登录。4xx 时按「没有配验证码」处理，返回空 map 继续走登录。
    final response = await _dio.get(
      ApiEndpoints.captchaConfig,
      queryParameters: username != null && username.trim().isNotEmpty
          ? {'username': username.trim()}
          : null,
      options: Options(
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    final result = _extractData(response.data);
    if (result is Map<String, dynamic>) {
      return result;
    }
    if (result is Map) {
      return Map<String, dynamic>.from(result);
    }
    return <String, dynamic>{};
  }

  Future<void> logout() async {
    try {
      await _dio.post(ApiEndpoints.logout);
    } catch (_) {
      // 退出登录的语义是「清掉本地会话」，服务端调用失败不该阻断它。
      // 收紧 validateStatus 后，token 已过期时这里会抛 401；如果继续往上抛，
      // more_page 的退出流程会中断在 context.go 之前，用户点了退出却退不出去。
    } finally {
      await SecureStorage.clearAuthSession();
    }
  }

  Future<User> getUser() async {
    final response = await _dio.get(ApiEndpoints.user);
    final data = _extractData(response.data);
    final user = User.fromJson(data as Map<String, dynamic>);
    await SecureStorage.saveUser(user);
    return user;
  }

  Future<void> changePassword(String oldPassword, String newPassword) async {
    await _dio.put(
      ApiEndpoints.password,
      data: {'old_password': oldPassword, 'new_password': newPassword},
    );
  }

  Future<bool> checkHealth(String serverUrl) async {
    try {
      final dio = Dio(
        BaseOptions(
          baseUrl: serverUrl,
          connectTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
          headers: AppUserAgent.defaultHeaders,
        ),
      );
      final response = await dio.get(ApiEndpoints.health);
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
