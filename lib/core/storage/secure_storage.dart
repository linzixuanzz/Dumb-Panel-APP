import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../shared/models/user.dart';

const Object _panelFieldUnset = Object();

/// 面板配置信息
class PanelConfig {
  final String url;
  final String name;
  final String? username;
  final String? password;
  final bool rememberPassword;
  final bool autoLogin;

  const PanelConfig({
    required this.url,
    this.name = '',
    this.username,
    this.password,
    this.rememberPassword = false,
    this.autoLogin = false,
  });

  Map<String, dynamic> toJson() => {
    'url': url,
    'name': name.isEmpty ? url : name,
    'username': username,
    'password': password,
    'rememberPassword': rememberPassword,
    'autoLogin': autoLogin,
  };

  factory PanelConfig.fromJson(Map<String, dynamic> json) => PanelConfig(
    url: json['url'] as String,
    name: json['name'] as String? ?? '',
    username: json['username'] as String?,
    password: json['password'] as String?,
    rememberPassword: json['rememberPassword'] as bool? ?? false,
    autoLogin: json['autoLogin'] as bool? ?? false,
  );

  PanelConfig copyWith({
    String? url,
    String? name,
    Object? username = _panelFieldUnset,
    Object? password = _panelFieldUnset,
    bool? rememberPassword,
    bool? autoLogin,
  }) {
    return PanelConfig(
      url: url ?? this.url,
      name: name ?? this.name,
      username: identical(username, _panelFieldUnset)
          ? this.username
          : username as String?,
      password: identical(password, _panelFieldUnset)
          ? this.password
          : password as String?,
      rememberPassword: rememberPassword ?? this.rememberPassword,
      autoLogin: autoLogin ?? this.autoLogin,
    );
  }
}

class SecureStorage {
  static const _storage = FlutterSecureStorage();

  // 登录凭据按面板分片（issue #13，v1.3.7）。
  //
  // 分片前 token / user / 可信期都是全局一份裸 key，所以「切面板」必须先把上一台的凭据
  // 删掉，切回去就得重新登录、重新过 2FA。分片后每台面板各存一份，互不覆盖。
  // 这四个前缀拼上 scope 才是真正的 key：`access_token::<scope>`。
  static const _accessTokenPrefix = 'access_token';
  static const _refreshTokenPrefix = 'refresh_token';
  static const _trustedLoginUntilPrefix = 'trusted_login_until';
  static const _userPrefix = 'auth_user';

  // 下面这三个**保持全局不分片**：app lock 是设备级的（分片后换面板就要重设锁），
  // panels 是面板列表本身（分片等于自锁），ui_state 是 UI 偏好（分片不致命且成本不值）。
  static const _panelsKey = 'panels_config';
  static const _appLockConfigKey = 'app_lock_config';
  static const _prefsNamespaceKey = 'ui_state';

  static const _serverUrlKey = 'server_url';
  static const _serverListKey = 'server_list';

  /// 还没有选定面板时用的固定 scope。
  ///
  /// 必须是固定字符串：拼出 `access_token::null` 这种 key 之后，
  /// 一旦有人在这个 scope 下写过 token，后面谁都读不回来。
  static const _defaultScope = 'default';

  static String _activeScope = _defaultScope;

  /// 面板地址 → scope（`sha256(url)` 前 16 位 hex）。
  ///
  /// 不给 `PanelConfig` 加 id 字段是有硬理由的：`login_page.dart` 每次登录成功都是
  /// **裸 new 一个 PanelConfig** 覆盖保存（不是 copyWith），首次生成的 id 下次登录就被
  /// 换掉，存 token 时用的 id 会对不上号，症状正是「刚登完下次启动又要登」。
  /// url 才是全流程真正的主键（`savePanel` / `removePanel` / `getCurrentPanel` 都按它匹配）。
  ///
  /// 结尾斜杠在这里统一去掉：`DioClient.setBaseUrl` 会去一次，但迁移时从
  /// SharedPreferences 读到的 `server_url` 不一定去过，不统一就会分叉成两个 scope。
  /// `http://` 与 `https://`、带端口与不带端口是不同 scope，属预期
  /// —— 改了面板地址就等于换了一台，重新登录一次。
  static String scopeOf(String url) {
    final normalized = url.endsWith('/')
        ? url.substring(0, url.length - 1)
        : url;
    return sha256.convert(utf8.encode(normalized)).toString().substring(0, 16);
  }

  /// 切换当前面板。**唯一调用点是 `DioClient.setBaseUrl()`**。
  ///
  /// 同步方法、无 await：baseUrl 一改，后面任何一次读 token 就已经是新面板的那份，
  /// 中间不存在「请求打到 B、带的却是 A 的 token」的窗口。
  static void setActiveServer(String url) {
    final trimmed = url.trim();
    _activeScope = trimmed.isEmpty ? _defaultScope : scopeOf(trimmed);
  }

  static String get _accessTokenKey => '$_accessTokenPrefix::$_activeScope';
  static String get _refreshTokenKey => '$_refreshTokenPrefix::$_activeScope';
  static String get _trustedLoginUntilKey =>
      '$_trustedLoginUntilPrefix::$_activeScope';
  static String get _userKey => '$_userPrefix::$_activeScope';

  // Token
  static Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    await _storage.write(key: _accessTokenKey, value: accessToken);
    await _storage.write(key: _refreshTokenKey, value: refreshToken);
  }

  static Future<String?> getAccessToken() =>
      _storage.read(key: _accessTokenKey);

  static Future<String?> getRefreshToken() =>
      _storage.read(key: _refreshTokenKey);

  static Future<void> saveAccessToken(String token) =>
      _storage.write(key: _accessTokenKey, value: token);

  static Future<void> clearTokens() async {
    await _storage.delete(key: _accessTokenKey);
    await _storage.delete(key: _refreshTokenKey);
  }

  static Future<void> saveTrustedLoginSession({
    required DateTime expiresAt,
  }) async {
    // 保存当前面板的本地可信登录有效期，7 天内启动不再重复走登录接口。
    // 「是哪台面板的」已经由 key 里的 scope 表达，不再另存一个 url 做比对。
    await _storage.write(
      key: _trustedLoginUntilKey,
      value: expiresAt.toUtc().toIso8601String(),
    );
  }

  static Future<DateTime?> getTrustedLoginUntil() async {
    final raw = await _storage.read(key: _trustedLoginUntilKey);
    if (raw == null || raw.isEmpty) {
      return null;
    }

    try {
      return DateTime.parse(raw);
    } catch (_) {
      return null;
    }
  }

  /// 只判过期。
  ///
  /// 分片前这里还要比对另存的 `trusted_login_server_url`，因为全局只有一份可信期，
  /// 不比对就会让 A 的可信期把 B 也放进去。分片后每台面板各有一份可信期，
  /// scope 已经把「是哪台」钉死了，`serverUrl` 参数随之取消（issue #13，v1.3.7）。
  static Future<bool> hasValidTrustedLogin() async {
    final trustedUntil = await getTrustedLoginUntil();
    if (trustedUntil == null) {
      return false;
    }

    return DateTime.now().toUtc().isBefore(trustedUntil.toUtc());
  }

  static Future<void> clearTrustedLoginSession() async {
    await _storage.delete(key: _trustedLoginUntilKey);
  }

  static Future<void> saveUser(User user) =>
      _storage.write(key: _userKey, value: jsonEncode(user.toJson()));

  static Future<User?> getUser() async {
    final raw = await _storage.read(key: _userKey);
    if (raw == null || raw.isEmpty) {
      return null;
    }

    try {
      final data = jsonDecode(raw);
      if (data is Map<String, dynamic>) {
        return User.fromJson(data);
      }
      if (data is Map) {
        return User.fromJson(Map<String, dynamic>.from(data));
      }
    } catch (_) {}

    return null;
  }

  static Future<void> clearUser() => _storage.delete(key: _userKey);

  /// 只清**当前面板**的凭据（分片后这是它的天然语义）。
  static Future<void> clearAuthSession() async {
    await clearTokens();
    await clearUser();
    await clearTrustedLoginSession();
  }

  /// 清掉指定面板的凭据，不要求它是当前面板。
  /// 删除面板、以及「服务器管理」页的「清除该面板登录状态」走这条。
  static Future<void> clearAuthSessionForUrl(String url) async {
    final scope = scopeOf(url);
    await _storage.delete(key: '$_accessTokenPrefix::$scope');
    await _storage.delete(key: '$_refreshTokenPrefix::$scope');
    await _storage.delete(key: '$_trustedLoginUntilPrefix::$scope');
    await _storage.delete(key: '$_userPrefix::$scope');
  }

  /// v1.3.6 及以前的登录凭据是全局一份裸 key，升级后第一次启动把它归到
  /// `server_url` 指向的那台面板名下，否则存量用户会在升级后集体被踢下线。
  ///
  /// **必须在 `restoreTrustedLocalSession()` 之前调用**（见 `main.dart`），
  /// 放反了就是「升级后全被踢下线」这个 bug 本身。
  ///
  /// 顺序是「先写新 → 读回校验 → 再删老」：`getPanels()` 那种 `catch => []` 的吞异常写法
  /// 在这里绝对不能用 —— 一旦写新 key 失败（国产 ROM 上 Keystore 失效是真事）而老 key
  /// 又已经删了，用户凭据就永久丢失了。写不成功就原样留着，下次启动再试。
  ///
  /// 不加 `*_migrated` 标记：老 key 是否存在本身就是幂等判据。
  static Future<void> migrateLegacyAuthScope() async {
    const legacyAccessKey = 'access_token';
    const legacyRefreshKey = 'refresh_token';
    const legacyUserKey = 'auth_user';
    const legacyTrustedUntilKey = 'trusted_login_until';
    // 分片后不再需要的老字段，迁移时顺手清掉。
    const legacyTrustedServerUrlKey = 'trusted_login_server_url';

    final access = await _storage.read(key: legacyAccessKey);
    final refresh = await _storage.read(key: legacyRefreshKey);
    if ((access == null || access.isEmpty) &&
        (refresh == null || refresh.isEmpty)) {
      // 已经迁过 / 全新安装：绝大多数启动走这一条，两次读就返回。
      return;
    }

    final serverUrl = await getServerUrl();
    if (serverUrl == null || serverUrl.isEmpty) {
      // 没有归属面板（理论上不会发生：有 token 就一定登过）。
      // 宁可把无主数据原样留着，也不要删掉可能还有用的凭据。
      return;
    }

    final scope = scopeOf(serverUrl);
    final user = await _storage.read(key: legacyUserKey);
    final trustedUntil = await _storage.read(key: legacyTrustedUntilKey);

    final ok =
        await _writeAndVerify('$_accessTokenPrefix::$scope', access) &&
        await _writeAndVerify('$_refreshTokenPrefix::$scope', refresh) &&
        await _writeAndVerify('$_userPrefix::$scope', user) &&
        await _writeAndVerify(
          '$_trustedLoginUntilPrefix::$scope',
          trustedUntil,
        );
    if (!ok) {
      return;
    }

    await _storage.delete(key: legacyAccessKey);
    await _storage.delete(key: legacyRefreshKey);
    await _storage.delete(key: legacyUserKey);
    await _storage.delete(key: legacyTrustedUntilKey);
    await _storage.delete(key: legacyTrustedServerUrlKey);
  }

  /// 写一条并立刻读回核对。空值当作「没什么要迁的」直接算成功。
  static Future<bool> _writeAndVerify(String key, String? value) async {
    if (value == null || value.isEmpty) {
      return true;
    }
    await _storage.write(key: key, value: value);
    return await _storage.read(key: key) == value;
  }

  static Future<void> saveAppLockConfig(Map<String, dynamic> config) =>
      _storage.write(key: _appLockConfigKey, value: jsonEncode(config));

  static Future<Map<String, dynamic>?> getAppLockConfig() async {
    final raw = await _storage.read(key: _appLockConfigKey);
    if (raw == null || raw.isEmpty) {
      return null;
    }

    try {
      final data = jsonDecode(raw);
      if (data is Map<String, dynamic>) {
        return data;
      }
      if (data is Map) {
        return Map<String, dynamic>.from(data);
      }
    } catch (_) {}
    return null;
  }

  static Future<void> clearAppLockConfig() =>
      _storage.delete(key: _appLockConfigKey);

  // Server URL
  static Future<void> saveServerUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverUrlKey, url);
  }

  static Future<String?> getServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_serverUrlKey);
  }

  // Server List (legacy)
  static Future<void> saveServerList(List<String> servers) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_serverListKey, servers);
  }

  static Future<List<String>> getServerList() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_serverListKey) ?? [];
  }

  // Panels
  static Future<void> savePanels(List<PanelConfig> panels) async {
    final json = panels.map((p) => jsonEncode(p.toJson())).toList();
    await _storage.write(key: _panelsKey, value: jsonEncode(json));
  }

  static Future<List<PanelConfig>> getPanels() async {
    final raw = await _storage.read(key: _panelsKey);
    if (raw == null) {
      // 迁移旧数据
      final oldList = await getServerList();
      if (oldList.isNotEmpty) {
        final panels = oldList
            .map((url) => PanelConfig(url: url, name: url))
            .toList();
        await savePanels(panels);
        return panels;
      }
      return [];
    }
    try {
      final list = jsonDecode(raw) as List;
      final panels = list
          .map((e) => PanelConfig.fromJson(jsonDecode(e as String)))
          .toList();
      await savePanels(panels);
      return panels;
    } catch (_) {
      return [];
    }
  }

  static Future<void> savePanel(PanelConfig panel) async {
    final panels = await getPanels();
    final idx = panels.indexWhere((p) => p.url == panel.url);
    if (idx >= 0) {
      panels[idx] = panel;
    } else {
      panels.insert(0, panel);
    }
    await savePanels(panels);
  }

  static Future<void> removePanel(String url) async {
    final panels = await getPanels();
    panels.removeWhere((p) => p.url == url);
    await savePanels(panels);
    // 面板都删了，它那份登录凭据没有任何用处，留着只是多一份 60 天的长期凭据躺在设备上。
    await clearAuthSessionForUrl(url);
  }

  static Future<PanelConfig?> getCurrentPanel() async {
    // 当前活跃面板由 server_url 决定，再回 panels 列表里取完整配置。
    final currentUrl = await getServerUrl();
    if (currentUrl == null || currentUrl.isEmpty) {
      return null;
    }

    final panels = await getPanels();
    for (final panel in panels) {
      if (panel.url == currentUrl) {
        return panel;
      }
    }

    return null;
  }

  static Future<void> writeValue(String key, String value) =>
      _storage.write(key: key, value: value);

  static Future<String?> readValue(String key) => _storage.read(key: key);

  static Future<void> saveUiState(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('${_prefsNamespaceKey}_$key', value);
  }

  static Future<String?> getUiState(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('${_prefsNamespaceKey}_$key');
  }

  static Future<void> removeUiState(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('${_prefsNamespaceKey}_$key');
  }

  static Future<void> saveUiStateList(String key, List<String> values) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('${_prefsNamespaceKey}_$key', values);
  }

  static Future<List<String>> getUiStateList(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList('${_prefsNamespaceKey}_$key') ?? const [];
  }
}
