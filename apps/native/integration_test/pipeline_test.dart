import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:yt_playlist_downloader/application/app_runtime.dart';
import 'package:yt_playlist_downloader/application/processing_controller.dart';
import 'package:yt_playlist_downloader/domain/models.dart';
import 'package:yt_playlist_downloader/domain/playlist_url.dart';
import 'package:yt_playlist_downloader/platform/credential_vault.dart';
import 'package:yt_playlist_downloader/platform/desktop_media_port.dart';
import 'package:yt_playlist_downloader/platform/desktop_tools.dart';
import 'package:yt_playlist_downloader/ui/processing_screen.dart';
import 'package:yt_playlist_downloader/ui/theme.dart';

import '../tool/media_smoke.dart' show SyntheticPlaylistSource;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native runtime, real codecs, processing UI and restart preserve verified media',
    (tester) async {
      if (!Platform.isLinux) {
        throw StateError(
          'Linux acceptance only; other devices require their own proof.',
        );
      }
      final manifest = Platform.environment['STAGE3_TEST_RUNTIME'];
      if (manifest == null) {
        throw StateError(
          'Set STAGE3_TEST_RUNTIME to the pinned local media manifest.',
        );
      }
      expect((await getApplicationSupportDirectory()).path, isNotEmpty);
      final root = await Directory.systemTemp.createTemp(
        'ytpd-pipeline-native-',
      );
      final vault = SecureCredentialVault(
        credentialKey: 'ytpd.pipeline.test.${const Uuid().v4()}',
      );
      AppRuntime? runtime;
      DesktopMediaPort? media;
      try {
        runtime = await AppRuntime.open(
          supportRoot: root,
          vault: vault,
          mediaManifest: File(manifest),
        );
        expect((await runtime.media.capabilities()).canAcquire, isTrue);
        final guard = File('${runtime.workspace.root.path}/process_guard.py');
        final tools = await DesktopTools.load(File(manifest), guard.path);
        media = DesktopMediaPort(
          jobs: runtime.jobs,
          workspace: runtime.workspace,
          tools: tools,
          source: SyntheticPlaylistSource(tools),
        );
        await media.initialize();
        final job = await runtime.jobs.createDraft(
          PlaylistUrl.parse(
            'https://youtube.com/playlist?list=PLsyntheticNative01',
          ),
        );
        final controller = ProcessingController(
          jobId: job.id,
          jobs: runtime.jobs,
          media: media,
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme,
            home: ProcessingScreen(controller: controller),
          ),
        );
        await tester.pumpAndSettle();
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (controller.job == null && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(controller.job, isNotNull);
        await tester.ensureVisible(find.byKey(const Key('start-processing')));
        await tester.tap(find.byKey(const Key('start-processing')));
        final completed = DateTime.now().add(const Duration(seconds: 30));
        while (controller.commanding && DateTime.now().isBefore(completed)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await controller.refresh(force: true);
        await tester.pumpAndSettle();
        expect(controller.job!.phase, JobPhase.reviewReady);
        expect(controller.readyCount, 3);
        expect(controller.failedCount, 1);
        expect(controller.unmappedCount, 1);
        expect(find.textContaining('3 ready'), findsOneWidget);
        final identities = controller.tracks.map((t) => t.id).toList();
        await tester.pumpWidget(const SizedBox.shrink());
        await media.close();
        media = null;
        await runtime.close();
        runtime = await AppRuntime.open(
          supportRoot: root,
          vault: vault,
          mediaManifest: File(manifest),
        );
        final reopened = await runtime.jobs.processingSnapshot(job.id);
        expect(reopened.$1.phase, JobPhase.reviewReady);
        expect(reopened.$2.map((t) => t.id), identities);
        expect(
          reopened.$2.where((t) => t.phase == TrackPhase.ready),
          hasLength(3),
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        if (media != null) await media.close();
        if (runtime != null) await runtime.close();
        await vault.removeGroqKey();
        await root.delete(recursive: true);
      }
    },
  );
}
