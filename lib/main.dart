import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'core/auth/auth_interceptor.dart';
import 'core/auth/auth_provider.dart';
import 'core/auth/token_refresher.dart';
import 'core/network/app_user_agent.dart';
import 'core/network/dio_client.dart';
import 'core/storage/secure_storage.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppUserAgent.initialize();

  // 恢复服务器地址
  final serverUrl = await SecureStorage.getServerUrl();
  if (serverUrl != null && serverUrl.isNotEmpty) {
    DioClient.instance.setBaseUrl(serverUrl);
  }

  final container = ProviderContainer();

  // 续期失败 → 置为未登录，GoRouter 的 refreshListenable 会立刻跳登录页；
  // reason 会在登录页顶部显示，避免用户看到的是一个没有任何解释的登录页。
  //
  // 同一个闭包注册两处，是因为掉线可能从两条链路发现：
  // dio 请求由 AuthInterceptor 兜，SSE 长连接（package:http，不经过拦截器）
  // 由 TokenRefresher 兜。共用闭包保证两边最终落到同一套处理，
  // 而不是各弹各的提示。
  void handleAuthFailed() {
    container
        .read(authProvider.notifier)
        .setUnauthenticated(reason: '登录已失效，请重新登录');
  }

  TokenRefresher.instance.onSessionExpired = handleAuthFailed;

  // 注入认证拦截器
  DioClient.instance.dio.interceptors.insert(
    0,
    AuthInterceptor(onAuthFailed: handleAuthFailed),
  );

  // 启动时先恢复本地可信登录态，7 天内避免重复触发登录接口和登录日志。
  await container.read(authProvider.notifier).restoreTrustedLocalSession();

  runApp(
    UncontrolledProviderScope(container: container, child: const DaidaiApp()),
  );
}
