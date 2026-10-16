import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:uuid/uuid.dart';
import 'package:yt_playlist_downloader/application/app_runtime.dart';
import 'package:yt_playlist_downloader/application/processing_controller.dart';
import 'package:yt_playlist_downloader/data/export_repository.dart';
import 'package:yt_playlist_downloader/domain/models.dart';
import 'package:yt_playlist_downloader/platform/credential_vault.dart';
import 'package:yt_playlist_downloader/platform/desktop_media_port.dart';
import 'package:yt_playlist_downloader/platform/desktop_tools.dart';
import 'package:yt_playlist_downloader/ui/processing_screen.dart';
import 'package:yt_playlist_downloader/ui/theme.dart';

import '../test/export_test_support.dart';
import 'enrichment_test.dart' show NativeFixtureTransport;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native full MP3 and ZIP save, receipt restart and private cleanup preserve external copies',
    (tester) async {
      final manifest = Platform.environment['STAGE3_TEST_RUNTIME'];
      if (!Platform.isLinux || manifest == null) {
        throw StateError(
          'Set STAGE3_TEST_RUNTIME for the opt-in actual Linux export test.',
        );
      }
      final root = await Directory.systemTemp.createTemp('ytpd-stage6-native-');
      final destination = TestExportDestination();
      final vault = SecureCredentialVault(
        credentialKey: 'ytpd.stage6.test.${const Uuid().v4()}',
      );
      final tools = await DesktopTools.load(
        File(manifest),
        File('assets/process_guard.py').absolute.path,
      );
      final setup = tools.scope();
      await setup.run(tools.python, [
        '-I',
        '-c',
        'from PIL import Image;Image.new("RGB",(32,32),"#f5d6e0").save("fixture.png")',
      ], directory: root);
      setup.cancel();
      final image = await File('${root.path}/fixture.png').readAsBytes();
      AppRuntime? runtime;
      Future<void> waitFor(bool Function() done) async {
        final deadline = DateTime.now().add(const Duration(minutes: 3));
        while (!done() && DateTime.now().isBefore(deadline)) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        expect(done(), isTrue);
        await tester.pumpAndSettle();
      }

      try {
        await vault.saveGroqKey(
          ApiKey.parse('gsk_${const Uuid().v4().replaceAll('-', '')}'),
        );
        runtime = await AppRuntime.open(
          supportRoot: root,
          vault: vault,
          mediaManifest: File(manifest),
          source: ExportTestSource(tools),
          metadataTransport: NativeFixtureTransport(image),
          exportDestination: destination,
        );
        var media = runtime.media as DesktopMediaPort;
        expect((await media.capabilities()).canExport, isTrue);
        final job = await prepareExportReview(runtime.jobs, media, image);
        var state = ProcessingController(
          jobId: job.id,
          jobs: runtime.jobs,
          media: media,
        );
        await state.initialize();
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme,
            home: ProcessingScreen(controller: state),
          ),
        );
        await tester.pumpAndSettle();
        final prepare = find.byKey(const Key('prepare-device-export'));
        await tester.scrollUntilVisible(
          prepare,
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(prepare);
        await tester.pumpAndSettle();
        expect(tester.widget<FilledButton>(prepare).onPressed, isNotNull);
        await tester.runAsync(() => tester.tap(prepare));
        await waitFor(() => !state.exportBusy);
        expect(state.failure, isNull);
        expect(state.job!.phase, JobPhase.exportReady);
        final publication = state.publication!;
        expect(publication.tracks, hasLength(3));
        expect(state.savedCopy, isNull);
        final zipButton = find.byKey(const Key('save-export-zip'));
        await tester.scrollUntilVisible(
          zipButton,
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(zipButton);
        await tester.pumpAndSettle();
        // The OS chooser boundary is injected; all workers and file operations are real.
        await tester.runAsync(() => tester.tap(zipButton));
        await waitFor(() => !state.exportBusy);
        expect(state.saveMessage, contains('cancelled'));
        expect(await runtime.jobs.db.query('export_deliveries'), isEmpty);
        destination.path = '${root.path}/Saved playlist.zip';
        await tester.runAsync(() => tester.tap(zipButton));
        await waitFor(() => !state.exportBusy);
        expect(state.failure, isNull);
        expect(state.saveMessage, contains('Saved verified copy'));
        expect(
          await media.files.digest(destination.path!),
          publication.archive.sha256,
        );
        final zipPath = destination.path!;
        destination.path = '${root.path}/Saved full track.mp3';
        await state.saveExportFile(publication.tracks.first.id);
        expect(state.failure, isNull);
        final mp3Path = destination.path!;
        expect(
          await media.files.digest(mp3Path),
          publication.tracks.first.sha256,
        );
        final work = await media.files.work(job.id, const Uuid().v4()),
            scope = tools.scope();
        try {
          final verified = await media.codec.verify(
            File(mp3Path),
            scope,
            work,
            () => media.budget(job.id, scope, work),
            mp3: true,
            expected: 65,
          );
          expect(verified.durationSeconds, greaterThan(64));
          final result = await scope.run(tools.python, [
            '-I',
            '-c',
            'import json,sys,zipfile;z=zipfile.ZipFile(sys.argv[1]);m=json.loads(z.read("manifest.json"));assert len(m["files"])==3;assert len(z.namelist())==4;print("verified native ZIP")',
            zipPath,
          ], directory: work);
          expect(result, contains('verified native ZIP'));
        } finally {
          scope.cancel();
          await work.delete(recursive: true);
        }
        final interruptedId = const Uuid().v4();
        final interruptedPath = '${root.path}/Interrupted.zip';
        final recoveryWork = await media.files.work(job.id, const Uuid().v4());
        final recoveryScope = tools.scope();
        try {
          final request = <String, Object?>{
            'delivery_id': interruptedId,
            'destination': interruptedPath,
            'private_root': runtime.workspace.root.path,
            'bytes': publication.archive.bytes,
          };
          final pending = await media.exportTools!.run(
            'prepare-destination',
            request,
            recoveryScope,
            recoveryWork,
          );
          await ExportRepository(runtime.jobs).beginDelivery(
            publication,
            publication.archive,
            id: interruptedId,
            destination: interruptedPath,
            temporary: pending['temporary'] as String,
            device: pending['device'] as int,
            inode: pending['inode'] as int,
          );
          await File(pending['temporary'] as String)
              .writeAsBytes([1, 2, 3], flush: true);
        } finally {
          recoveryScope.cancel();
          await recoveryWork.delete(recursive: true);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await runtime.close();
        runtime = await AppRuntime.open(
          supportRoot: root,
          vault: vault,
          mediaManifest: File(manifest),
          exportDestination: destination,
        );
        media = runtime.media as DesktopMediaPort;
        final recoveredJournal = (await runtime.jobs.db.query(
          'export_deliveries',
          where: 'id=?',
          whereArgs: [interruptedId],
        )).single;
        expect(recoveredJournal['status'], 'interrupted');
        expect(recoveredJournal['cleanup_pending'], 0);
        expect(
          await File(recoveredJournal['temporary'] as String).exists(),
          isFalse,
        );
        expect(await File(interruptedPath).exists(), isFalse);
        final restored = await media.currentExport(job.id);
        expect(restored!.snapshot.id, publication.snapshot.id);
        expect(
          (await ExportRepository(runtime.jobs)
                  .latestReceipt(restored.snapshot.id))!
              .fileId,
          publication.tracks.first.id,
        );
        final again = await media.prepareExport(
          job.id,
          (await runtime.jobs.getJob(job.id)).revision,
        );
        expect(again.json, publication.json);
        state = ProcessingController(
          jobId: job.id,
          jobs: runtime.jobs,
          media: media,
        );
        await state.initialize();
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme,
            home: ProcessingScreen(controller: state),
          ),
        );
        await tester.pumpAndSettle();
        expect(state.savedCopy, isNotNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await media.cancel(job.id);
        expect((await runtime.jobs.getJob(job.id)).phase, JobPhase.cancelled);
        await media.discardPrivateMedia(job.id);
        expect(await File(zipPath).exists(), isTrue);
        expect(await File(mp3Path).exists(), isTrue);
        expect(await media.files.digest(zipPath), publication.archive.sha256);
        expect(
          await media.files.digest(mp3Path),
          publication.tracks.first.sha256,
        );
        expect(
          await Directory('${runtime.workspace.root.path}/jobs/${job.id}')
              .exists(),
          isFalse,
        );
        debugPrint(
          'Stage 6 native acceptance: full MP3/ZIP destination bytes, snapshot/receipt restart, cancellation and external-copy-safe cleanup verified.',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await runtime?.close();
        await vault.removeGroqKey();
        await root.delete(recursive: true);
      }
    },
  );
}
