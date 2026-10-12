import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/failure.dart';

final class ApiKey {
  ApiKey.parse(String value) : _value = value.trim() {
    if (!RegExp(r'^gsk_[A-Za-z0-9_-]{20,256}$').hasMatch(_value)) {
      throw const AppFailure(
        FailureCode.invalidCredential,
        'Enter a Groq API key beginning with gsk_.',
      );
    }
  }
  final String _value;
  String get value => _value;
  @override
  String toString() => 'ApiKey([redacted])';
}

abstract interface class CredentialVault {
  Future<bool> hasGroqKey();
  Future<void> saveGroqKey(ApiKey key);
  Future<ApiKey?> readGroqKey();
  Future<void> removeGroqKey();
}

final class SecureCredentialVault implements CredentialVault {
  SecureCredentialVault({
    FlutterSecureStorage? storage,
    String credentialKey = 'ytpd.groq.api_key.v1',
  }) : _storage =
           storage ??
           const FlutterSecureStorage(
             aOptions: AndroidOptions(),
             iOptions: IOSOptions(
               accessibility: KeychainAccessibility.unlocked,
             ),
           ),
       _groqKey = credentialKey;
  final FlutterSecureStorage _storage;
  final String _groqKey;

  Future<T> _guard<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } catch (_) {
      // No plaintext fallback, provider exception or key material reaches UI/logs.
      throw const AppFailure(
        FailureCode.storageUnavailable,
        'Secure credential storage is unavailable. Unlock your device keyring and try again.',
        retryable: true,
      );
    }
  }

  @override
  Future<bool> hasGroqKey() =>
      _guard(() => _storage.containsKey(key: _groqKey));
  @override
  Future<void> saveGroqKey(ApiKey key) =>
      _guard(() => _storage.write(key: _groqKey, value: key.value));
  @override
  Future<ApiKey?> readGroqKey() => _guard(() async {
    final value = await _storage.read(key: _groqKey);
    return value == null ? null : ApiKey.parse(value);
  });
  @override
  Future<void> removeGroqKey() => _guard(() => _storage.delete(key: _groqKey));
}
