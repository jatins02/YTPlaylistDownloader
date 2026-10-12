import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yt_playlist_downloader/domain/failure.dart';
import 'package:yt_playlist_downloader/platform/credential_vault.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'secure-storage failures are sanitized and never fall back to plaintext',
    () async {
      final secret = 'gsk_${List.filled(40, 'z').join()}';
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(
          code: 'locked',
          message: 'Sensitive provider details: $secret',
        );
      });
      final vault = SecureCredentialVault();
      try {
        await vault.saveGroqKey(ApiKey.parse(secret));
        fail('Secure-storage failure must not count as a successful save.');
      } on AppFailure catch (error) {
        expect(error.code, FailureCode.storageUnavailable);
        expect(error.toString(), isNot(contains(secret)));
      }
    },
  );
}
