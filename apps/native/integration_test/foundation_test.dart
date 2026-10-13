import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:yt_playlist_downloader/application/app_runtime.dart';
import 'package:yt_playlist_downloader/application/drafts_controller.dart';
import 'package:yt_playlist_downloader/domain/failure.dart';
import 'package:yt_playlist_downloader/domain/playlist_url.dart';
import 'package:yt_playlist_downloader/platform/credential_vault.dart';
import 'package:yt_playlist_downloader/ui/foundation_app.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native storage, credentials and draft restart round trip', (
    tester,
  ) async {
    // Exercise the registered native plugins; never replace or read the user's key.
    final support = await getApplicationSupportDirectory();
    expect(support.path, isNotEmpty);
    final temporary = await Directory.systemTemp.createTemp(
      'ytpd-native-test-',
    );
    final vault = SecureCredentialVault(
      credentialKey: 'ytpd.test.${const Uuid().v4()}',
    );
    AppRuntime? runtime;
    DraftsController? controller;
    try {
      runtime = await AppRuntime.open(supportRoot: temporary, vault: vault);
      controller = DraftsController(
        jobs: runtime.jobs,
        workspace: runtime.workspace,
        vault: vault,
      );
      await controller.load();
      await tester.pumpWidget(FoundationApp(controller: controller));
      await tester.pumpAndSettle();
      expect(find.text('Playlist drafts'), findsOneWidget);
      expect(
        await controller.saveDraft(
          'https://youtube.com/playlist?list=PL1234567890',
        ),
        isTrue,
      );
      await tester.pumpAndSettle();
      final id = controller.drafts.single.id;

      // The real native route can open/close the fixture journey without
      // creating simulated jobs or requesting credentials/media capability.
      await tester.scrollUntilVisible(
        find.byKey(const Key('open-fixture-journey')),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('open-fixture-journey')));
      await tester.pumpAndSettle();
      expect(find.text('Fictional demo · Stage 2'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect((await runtime.jobs.listJobs()).single.id, id);

      // Synthetic credential only. Its key name is unique, and cleanup is scoped.
      final key = ApiKey.parse('gsk_${const Uuid().v4().replaceAll('-', '')}');
      await vault.saveGroqKey(key);
      expect(await vault.hasGroqKey(), isTrue);
      // Avoid matchers that print actual credential values on failure.
      expect((await vault.readGroqKey())?.value == key.value, isTrue);
      await vault.removeGroqKey();
      expect(await vault.hasGroqKey(), isFalse);

      expect((await runtime.media.capabilities()).canAcquire, isFalse);
      await expectLater(
        runtime.media.acquire(
          playlist: PlaylistUrl.parse(
            'https://youtube.com/playlist?list=PL1234567890',
          ),
          jobId: id,
        ),
        throwsA(
          isA<AppFailure>().having(
            (error) => error.code,
            'code',
            FailureCode.mediaUnavailable,
          ),
        ),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      controller = null;
      await runtime.close();
      runtime = await AppRuntime.open(supportRoot: temporary, vault: vault);
      expect((await runtime.jobs.listJobs()).single.id, id);
      expect(
        (await runtime.jobs.getJob(id)).sourceUrl,
        'https://www.youtube.com/playlist?list=PL1234567890',
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller?.dispose();
      await runtime?.close();
      await vault.removeGroqKey();
      await temporary.delete(recursive: true);
    }
  });
}
