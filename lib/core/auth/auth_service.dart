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

    // 登录接口的 4xx 现在由 DioClient 的全局 validateStatus(< 400) 直接抛成
    // DioException（带 response），语义与这里原先手工重建 DioException 完全一致，
    // 所以那段绕行代码已删除。AuthInterceptor 把 /auth/login 放进了 _noRefreshPaths，
    // 密码错误返回的 401 不会被误当成「token 过期」去续期。
    final response = await _dio.post(ApiEndpoints.login, data: data);

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
