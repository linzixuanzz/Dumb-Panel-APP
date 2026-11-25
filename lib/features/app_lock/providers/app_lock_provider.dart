import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../../../core/storage/secure_storage.dart';

const Object _lockFieldUnset = Object();
const String _kAppLockHashVersion = 'sha256-iter-v1';
const int _kAppLockHashRounds = 40000;

class AppLockConfig {
  final bool enabled;
  final String passwordHash;
  final String patternHash;
  final bool biometricEnabled;

  const AppLockConfig({
    this.enabled = false,
    this.passwordHash = '',
    this.patternHash = '',
    this.biometricEnabled = false,
  });

  bool get hasPassword => passwordHash.isNotEmpty;
  bool get hasPattern => patternHash.isNotEmpty;
  bool get hasAnyMethod => hasPassword || hasPattern || biometricEnabled;

  AppLockConfig copyWith({
    bool? enabled,
    String? passwordHash,
    String? patternHash,
    bool? biometricEnabled,
  }) {
    return AppLockConfig(
      enabled: enabled ?? this.enabled,
      passwordHash: passwordHash ?? this.passwordHash,
      patternHash: patternHash ?? this.patternHash,
      biometricEnabled: biometricEnabled ?? this.biometricEnabled,
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'password_hash': passwordHash,
    'pattern_hash': patternHash,
    'biometric_enabled': biometricEnabled,
  };

  factory AppLockConfig.fromJson(Map<String, dynamic> json) {
    return AppLockConfig(
      enabled: json['enabled'] == true,
      passwordHash: json['password_hash']?.toString() ?? '',
      patternHash: json['pattern_hash']?.toString() ?? '',
      biometricEnabled: json['biometric_enabled'] == true,
    );
  }
}

class AppLockState {
  final bool loading;
  final bool locked;
  final AppLockConfig config;
  final List<BiometricType> availableBiometrics;
  final int failedAttempts;
  final DateTime? lockedUntil;
  final String? unlockNotice;

  const AppLockState({
    this.loading = false,
    this.locked = false,
    this.config = const AppLockConfig(),
    this.availableBiometrics = const [],
    this.failedAttempts = 0,
    this.lockedUntil,
    this.unlockNotice,
  });

  bool get biometricAvailable => availableBiometrics.isNotEmpty;
  bool get isEnabled => config.enabled && config.hasAnyMethod;
  bool get hasPassword => config.hasPassword;
  bool get hasPattern => config.hasPattern;
  bool get hasBiometric => config.biometricEnabled && biometricAvailable;
  String get biometricLabel {
    final hasFace = availableBiometrics.contains(BiometricType.face);
    final hasFingerprint = availableBiometrics.contains(
      BiometricType.fingerprint,
    );
    if (hasFace && hasFingerprint) return '指纹 / 人脸';
    if (hasFace) return '人脸';
    if (hasFingerprint) return '指纹';
    return '生物识别';
  }

  AppLockState copyWith({
    bool? loading,
    bool? locked,
    AppLockConfig? config,
    List<BiometricType>? availableBiometrics,
    int? failedAttempts,
    Object? lockedUntil = _lockFieldUnset,
    Object? unlockNotice = _lockFieldUnset,
  }) {
    return AppLockState(
      loading: loading ?? this.loading,
      locked: locked ?? this.locked,
      config: config ?? this.config,
      availableBiometrics: availableBiometrics ?? this.availableBiometrics,
      failedAttempts: failedAttempts ?? this.failedAttempts,
      lockedUntil: identical(lockedUntil, _lockFieldUnset)
          ? this.lockedUntil
          : lockedUntil as DateTime?,
      unlockNotice: identical(unlockNotice, _lockFieldUnset)
          ? this.unlockNotice
          : unlockNotice as String?,
    );
  }
}

class AppLockController extends StateNotifier<AppLockState> {
  AppLockController() : super(const AppLockState());

  final LocalAuthentication _localAuth = LocalAuthentication();

  Future<void> initialize() async {
    state = state.copyWith(loading: true);
    final rawConfig = await SecureStorage.getAppLockConfig();
    final biometrics = await _readAvailableBiometrics();
    final nextConfig = _sanitizeConfig(
      AppLockConfig.fromJson(rawConfig ?? const <String, dynamic>{}),
      biometrics,
    );
    state = state.copyWith(
      loading: false,
      config: nextConfig,
      availableBiometrics: biometrics,
      failedAttempts: 0,
      lockedUntil: null,
      unlockNotice: null,
    );
    await SecureStorage.saveAppLockConfig(nextConfig.toJson());
  }

  Future<void> setEnabled(bool enabled) async {
    final nextConfig = _sanitizeConfig(
      state.config.copyWith(enabled: enabled),
      state.availableBiometrics,
    );
    if (enabled && !nextConfig.hasAnyMethod) {
      throw StateError('请先至少配置一种验证方式');
    }
    await _saveConfig(nextConfig);
    if (!nextConfig.enabled) {
      state = state.copyWith(locked: false);
    }
  }

  Future<void> savePassword(String value) async {
    final nextConfig = _sanitizeConfig(
      state.config.copyWith(
        enabled: true,
        passwordHash: await _hashSecret(value),
      ),
      state.availableBiometrics,
    );
    await _saveConfig(nextConfig);
  }

  Future<void> removePassword() async {
    final nextConfig = _sanitizeConfig(
      state.config.copyWith(passwordHash: ''),
      state.availableBiometrics,
    );
    await _saveConfig(nextConfig);
  }

  Future<void> savePattern(List<int> pattern) async {
    final nextConfig = _sanitizeConfig(
      state.config.copyWith(
        enabled: true,
        patternHash: await _hashSecret(pattern.join('-')),
      ),
      state.availableBiometrics,
    );
    await _saveConfig(nextConfig);
  }

  Future<void> removePattern() async {
    final nextConfig = _sanitizeConfig(
      state.config.copyWith(patternHash: ''),
      state.availableBiometrics,
    );
    await _saveConfig(nextConfig);
  }

  Future<void> setBiometricEnabled(bool enabled) async {
    if (enabled && state.availableBiometrics.isEmpty) {
      throw StateError('当前设备未检测到可用的指纹或人脸');
    }
    final nextConfig = _sanitizeConfig(
      state.config.copyWith(enabled: true, biometricEnabled: enabled),
      state.availableBiometrics,
    );
    await _saveConfig(nextConfig);
  }

  void lockIfEnabled() {
    if (state.isEnabled) {
      state = state.copyWith(locked: true, unlockNotice: null);
    }
  }

  void unlockSession() {
    state = state.copyWith(
      locked: false,
      failedAttempts: 0,
      lockedUntil: null,
      unlockNotice: null,
    );
  }

  void resetSession() {
    state = state.copyWith(
      locked: false,
      failedAttempts: 0,
      lockedUntil: null,
      unlockNotice: null,
    );
  }

  String? getUnlockNotice() {
    // 给 UI 读取最近一次验证提示，避免在 Widget 里直接访问 StateNotifier.state。
    return state.unlockNotice;
  }

  Future<bool> unlockWithPassword(String value) async {
    if (!state.hasPassword) {
      return false;
    }
    final blockedMessage = _ensureUnlockReady();
    if (blockedMessage != null) {
      return false;
    }

    final ok = await _matchesSecret(value, state.config.passwordHash);
    if (ok) {
      await _upgradeLegacyPasswordIfNeeded(value);
      unlockSession();
    } else {
      _recordFailedAttempt('密码不正确');
    }
    return ok;
  }

  Future<bool> unlockWithPattern(List<int> pattern) async {
    if (!state.hasPattern) {
      return false;
    }
    final blockedMessage = _ensureUnlockReady();
    if (blockedMessage != null) {
      return false;
    }

    final rawPattern = pattern.join('-');
    final ok = await _matchesSecret(rawPattern, state.config.patternHash);
    if (ok) {
      await _upgradeLegacyPatternIfNeeded(rawPattern);
      unlockSession();
    } else {
      _recordFailedAttempt('图案不正确');
    }
    return ok;
  }

  Future<bool> unlockWithBiometric() async {
    if (!state.hasBiometric) {
      return false;
    }

    try {
      final ok = await _localAuth.authenticate(
        localizedReason: '验证身份以进入呆呆面板',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
          sensitiveTransaction: true,
        ),
      );
      if (ok) {
        unlockSession();
      } else {
        state = state.copyWith(unlockNotice: '${state.biometricLabel}验证未通过');
      }
      return ok;
    } on PlatformException {
      state = state.copyWith(unlockNotice: '生物识别暂时不可用，请改用其他方式');
      return false;
    }
  }

  Future<void> _saveConfig(AppLockConfig config) async {
    await SecureStorage.saveAppLockConfig(config.toJson());
    state = state.copyWith(
      config: config,
      failedAttempts: 0,
      lockedUntil: null,
      unlockNotice: null,
    );
  }

  Future<List<BiometricType>> _readAvailableBiometrics() async {
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      if (!canCheck) {
        return const [];
      }
      return await _localAuth.getAvailableBiometrics();
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      // 网页版没有 local_auth 的实现，会抛 MissingPluginException（它不是 PlatformException）。
      // 以前这里漏接，异常冒出 initialize()：网页版控制台报未捕获错误，应用锁状态也一直停在 loading。
      return const [];
    }
  }

  AppLockConfig _sanitizeConfig(
    AppLockConfig config,
    List<BiometricType> availableBiometrics,
  ) {
    final biometricEnabled =
        config.biometricEnabled && availableBiometrics.isNotEmpty;
    final hasAnyMethod =
        config.passwordHash.isNotEmpty ||
        config.patternHash.isNotEmpty ||
        biometricEnabled;
    return config.copyWith(
      enabled: config.enabled && hasAnyMethod,
      biometricEnabled: biometricEnabled,
    );
  }

  String? _ensureUnlockReady() {
    final lockedUntil = state.lockedUntil;
    if (lockedUntil == null) {
      return null;
    }
    if (lockedUntil.isAfter(DateTime.now())) {
      final seconds = lockedUntil.difference(DateTime.now()).inSeconds + 1;
      final message = '连续输错过多，请在 ${seconds}s 后重试';
      state = state.copyWith(unlockNotice: message);
      return message;
    }
    state = state.copyWith(
      failedAttempts: 0,
      lockedUntil: null,
      unlockNotice: null,
    );
    return null;
  }

  void _recordFailedAttempt(String fallbackMessage) {
    final nextAttempts = state.failedAttempts + 1;
    final cooldown = _cooldownForAttempts(nextAttempts);
    if (cooldown == null) {
      state = state.copyWith(
        failedAttempts: nextAttempts,
        unlockNotice: fallbackMessage,
      );
      return;
    }

    state = state.copyWith(
      failedAttempts: nextAttempts,
      lockedUntil: DateTime.now().add(cooldown),
      unlockNotice: '连续输错过多，请在 ${cooldown.inSeconds}s 后重试',
    );
  }

  Duration? _cooldownForAttempts(int attempts) {
    if (attempts >= 8) {
      return const Duration(minutes: 1);
    }
    if (attempts >= 5) {
      return const Duration(seconds: 30);
    }
    if (attempts >= 3) {
      return const Duration(seconds: 10);
    }
    return null;
  }

  Future<void> _upgradeLegacyPasswordIfNeeded(String value) async {
    if (!_isLegacyHash(state.config.passwordHash)) {
      return;
    }
    await _saveConfig(
      state.config.copyWith(passwordHash: await _hashSecret(value)),
    );
  }

  Future<void> _upgradeLegacyPatternIfNeeded(String value) async {
    if (!_isLegacyHash(state.config.patternHash)) {
      return;
    }
    await _saveConfig(
      state.config.copyWith(patternHash: await _hashSecret(value)),
    );
  }

  bool _isLegacyHash(String value) =>
      !value.startsWith('$_kAppLockHashVersion:');

  Future<bool> _matchesSecret(String value, String storedHash) async {
    if (_isLegacyHash(storedHash)) {
      return _legacyHashSecret(value) == storedHash;
    }

    final parts = storedHash.split(':');
    if (parts.length != 4 || parts[0] != _kAppLockHashVersion) {
      return false;
    }

    final rounds = int.tryParse(parts[1]);
    final salt = parts[2];
    final digest = parts[3];
    if (rounds == null || rounds <= 0 || salt.isEmpty || digest.isEmpty) {
      return false;
    }

    final actualDigest = await _deriveSecret(value, salt, rounds);
    return actualDigest == digest;
  }

  Future<String> _hashSecret(String value) async {
    final salt = _generateSalt();
    final digest = await _deriveSecret(value, salt, _kAppLockHashRounds);
    return '$_kAppLockHashVersion:$_kAppLockHashRounds:$salt:$digest';
  }

  String _legacyHashSecret(String value) {
    final bytes = utf8.encode('daidai_app_lock::$value');
    return sha256.convert(bytes).toString();
  }

  String _generateSalt() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64UrlEncode(bytes);
  }

  Future<String> _deriveSecret(String value, String salt, int rounds) async {
    List<int> current = utf8.encode('$salt::$value');
    for (var i = 0; i < rounds; i++) {
      current = sha256.convert(current).bytes;
      if ((i + 1) % 2000 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    return current.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
}

final appLockProvider = StateNotifierProvider<AppLockController, AppLockState>((
  ref,
) {
  return AppLockController();
});
