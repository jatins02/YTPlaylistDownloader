import 'failure.dart';

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
