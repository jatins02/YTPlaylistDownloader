import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:uuid/uuid.dart';
import 'package:yt_playlist_downloader/application/app_runtime.dart';
import 'package:yt_playlist_downloader/application/processing_controller.dart';
import 'package:yt_playlist_downloader/data/enrichment_repository.dart';
import 'package:yt_playlist_downloader/data/pipeline_repository.dart';
import 'package:yt_playlist_downloader/domain/failure.dart';
import 'package:yt_playlist_downloader/domain/models.dart';
import 'package:yt_playlist_downloader/domain/playlist_url.dart';
import 'package:yt_playlist_downloader/domain/review.dart';
import 'package:yt_playlist_downloader/platform/credential_vault.dart';
import 'package:yt_playlist_downloader/platform/desktop_media_port.dart';
import 'package:yt_playlist_downloader/platform/desktop_tools.dart';
import 'package:yt_playlist_downloader/ui/processing_screen.dart';
import 'package:yt_playlist_downloader/ui/theme.dart';

import '../tool/media_smoke.dart' show SyntheticPlaylistSource;
import 'enrichment_test.dart' show NativeFixtureTransport;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real snippet output, review edits, user covers and selections survive restart',
    (tester) async {
      final manifest = Platform.environment['STAGE3_TEST_RUNTIME'],
          socket = Platform.environment['YTPD_AUDIO_SOCKET'];
      if (!Platform.isLinux || manifest == null || socket == null) {
        throw StateError(
          'Run scripts/test_stage5_audio.py with the pinned media runtime.',
        );
      }
      final root = await Directory.systemTemp.createTemp('ytpd-stage5-native-');
      final vault = SecureCredentialVault(
        credentialKey: 'ytpd.stage5.test.${const Uuid().v4()}',
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
      try {
        await vault.saveGroqKey(
          ApiKey.parse('gsk_${const Uuid().v4().replaceAll('-', '')}'),
        );
        runtime = await AppRuntime.open(
          supportRoot: root,
          vault: vault,
          mediaManifest: File(manifest),
          source: SyntheticPlaylistSource(tools),
          metadataTransport: NativeFixtureTransport(image),
        );
        final media = runtime.media as DesktopMediaPort;
        expect((await media.capabilities()).canPlaySnippets, isTrue);
        final job = await runtime.jobs.createDraft(
          PlaylistUrl.parse(
            'https://youtube.com/playlist?list=PLsyntheticNative01',
          ),
        );
        await media.acquire(
          playlist: PlaylistUrl.parse(job.sourceUrl),
          jobId: job.id,
        );
        final controller = ProcessingController(
          jobId: job.id,
          jobs: runtime.jobs,
          media: media,
        );
        await controller.initialize();
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme,
            home: ProcessingScreen(controller: controller),
          ),
        );
        await tester.pumpAndSettle();
        final ready = controller.tracks
            .where((t) => t.phase == TrackPhase.ready)
            .toList();
        final first = ready.firstWhere((t) => t.videoId == 'abcdefghijk'),
            second = ready.firstWhere((t) => t.videoId == '12345678901');
        final before = await PipelineRepository(runtime.jobs).assets(job.id);

        Future<Uint8List> capture(
          TrackRecord track,
          int position, {
          bool rename = false,
        }) async {
          final scope = tools.scope(),
              output = File('${root.path}/capture-${track.id}.pcm');
          final recording = scope.run(
            tools.ffmpeg,
            [
              '-nostdin',
              '-hide_banner',
              '-loglevel',
              'error',
              '-n',
              '-f',
              'pulse',
              '-server',
              'unix:$socket',
              '-i',
              'ytpd_stage5.monitor',
              '-t',
              '4',
              '-ac',
              '1',
              '-ar',
              '44100',
              '-f',
              's16le',
              output.path,
            ],
            directory: root,
            timeout: const Duration(seconds: 12),
            localAudio: true,
          );
          try {
            await Future<void>.delayed(const Duration(milliseconds: 300));
            await tester.ensureVisible(
              find.byKey(Key('review-play-$position')),
            );
            await tester.tap(find.byKey(Key('review-play-$position')));
            final deadline = DateTime.now().add(const Duration(seconds: 10));
            while (controller.player.loading &&
                DateTime.now().isBefore(deadline)) {
              await tester.pump(const Duration(milliseconds: 100));
            }
            expect(controller.player.failure, isNull);
            expect(controller.player.trackId, track.id);
            if (rename) {
              final session = await controller.beginEdit(
                await runtime!.jobs.getTrack(track.id),
              );
              expect(session, isNotNull);
              expect(controller.reviewBlockedReason, contains('open edit'));
              final current = await runtime!.jobs.getJob(job.id);
              await expectLater(
                runtime!.jobs.freezeExport(job.id, current.revision),
                throwsA(isA<AppFailure>()),
              );
              expect(
                await controller.saveEdit(
                  session!,
                  SongMetadata(title: '月光列車 (Live)', artists: ['Mira Vale']),
                  const CoverEdit.keep(),
                ),
                isNull,
              );
              await controller.endEdit(session);
              expect(controller.player.trackId, track.id);
            }
            while ((controller.player.loading || controller.player.playing) &&
                DateTime.now().isBefore(deadline)) {
              await tester.pump(const Duration(milliseconds: 100));
            }
            expect(controller.player.playing, isFalse);
            expect(controller.player.failure, isNull);
            expect(
              controller.player.position,
              lessThanOrEqualTo(const Duration(seconds: 30)),
            );
            await recording;
            return await output.readAsBytes();
          } finally {
            scope.cancel();
            try {
              await recording;
            } on AppFailure {
              /* Retain an earlier assertion failure after capture cancellation. */
            }
          }
        }

        final firstPcm = await capture(first, 1, rename: true),
            secondPcm = await capture(second, 2);
        final firstEnergy = toneEnergy(firstPcm, 440),
            secondEnergy = toneEnergy(secondPcm, 880);
        expect(firstEnergy, greaterThan(500));
        expect(secondEnergy, greaterThan(500));
        expect(firstEnergy, greaterThan(toneEnergy(firstPcm, 880) * 10));
        expect(secondEnergy, greaterThan(toneEnergy(secondPcm, 440) * 10));
        // Replace an actually running native output, not only a mock player.
        await controller.player.toggle(first.id);
        final switchingDeadline = DateTime.now().add(
          const Duration(seconds: 10),
        );
        while (controller.player.loading &&
            DateTime.now().isBefore(switchingDeadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(controller.player.playing, isTrue);
        await controller.player.toggle(second.id);
        while (controller.player.loading &&
            DateTime.now().isBefore(switchingDeadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(controller.player.failure, isNull);
        expect(controller.player.trackId, second.id);
        expect(controller.player.playing, isTrue);
        await controller.player.pause(clear: true);
        final after = await PipelineRepository(runtime.jobs).assets(job.id);
        expect(
          after
              .where((a) => a.kind == AssetKind.preview)
              .map((a) => a.sha256)
              .toSet(),
          before
              .where((a) => a.kind == AssetKind.preview)
              .map((a) => a.sha256)
              .toSet(),
        );

        // Actual bounded image decoding and an atomic human-cover override.
        var current = await runtime.jobs.getTrack(first.id);
        final edit = await controller.beginEdit(current);
        expect(
          (await controller.saveEdit(
            edit!,
            SongMetadata(title: 'Must not commit', artists: ['Mira Vale']),
            CoverEdit.import(Uint8List.fromList([0, 1, 2])),
          ))?.code,
          FailureCode.artworkInvalid,
        );
        expect(
          (await runtime.jobs.getTrack(first.id)).metadata.title,
          current.metadata.title,
        );
        expect(
          await controller.saveEdit(
            edit,
            current.metadata,
            CoverEdit.import(image),
          ),
          isNull,
        );
        await controller.endEdit(edit);
        final cover = (await EnrichmentRepository(runtime.jobs)
            .records(job.id))[first.id]!;
        expect(cover.artworkOverride, isTrue);
        expect(
          await media.coverBytes(job.id, cover.artworkAssetId!),
          isNotNull,
        );
        final remove = await controller.beginEdit(
          await runtime.jobs.getTrack(second.id),
        );
        expect(
          await controller.saveEdit(
            remove!,
            second.metadata,
            const CoverEdit.remove(),
          ),
          isNull,
        );
        await controller.endEdit(remove);
        for (final track in controller.tracks.where(
          (t) => t.phase == TrackPhase.failed,
        )) {
          await controller.selectTrack(track, false);
        }
        for (final entry in controller.entries.where(
          (e) => e.trackId == null,
        )) {
          await controller.selectEntry(entry, false);
        }
        expect(controller.reviewBlockedReason, isNull);
        expect(controller.excludedCount, 2);

        // Corruption is rejected before any output; source-title/metadata remain.
        final preview = (await PipelineRepository(runtime.jobs).assets(
          job.id,
          trackId: second.id,
        )).singleWhere((a) => a.kind == AssetKind.preview);
        await (await media.files.file(preview)).writeAsBytes([0, 1, 2]);
        await expectLater(
          media.playSnippet(job.id, second.id, Duration.zero, (_) {}),
          throwsA(
            isA<AppFailure>().having(
              (e) => e.code,
              'code',
              FailureCode.audioInvalid,
            ),
          ),
        );
        // Stage 4's private adapter must read the human image back from APIC;
        // this does not publish an export or transfer anything to a destination.
        final frozen = await runtime.jobs.freezeExport(
          job.id,
          (await runtime.jobs.getJob(job.id)).revision,
        );
        final tagScope = tools.scope(),
            tagWork = await media.files.work(job.id, const Uuid().v4());
        try {
          final tagged = await media.tagAdapter!.prepare(
            frozen,
            first.id,
            tagScope,
            tagWork,
            () => media.budget(job.id, tagScope, tagWork),
          );
          final asset = (await PipelineRepository(runtime.jobs).assets(job.id))
              .singleWhere((a) => a.id == cover.artworkAssetId);
          expect(tagged.coverSha256, asset.sha256);
          expect(await tagged.file.length(), greaterThan(0));
        } finally {
          tagScope.cancel();
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await runtime.close();
        runtime = null;
        runtime = await AppRuntime.open(
          supportRoot: root,
          vault: vault,
          mediaManifest: File(manifest),
        );
        current = await runtime.jobs.getTrack(first.id);
        expect(current.metadata.title, '月光列車 (Live)');
        expect(current.id, first.id);
        expect(
          (await runtime.jobs.listTracks(job.id)).where((t) => !t.selected),
          hasLength(1),
        );
        expect(
          (await runtime.jobs.listEntries(job.id))
              .where((e) => e.trackId == null && !e.selected),
          hasLength(1),
        );
        expect(
          (await EnrichmentRepository(
            runtime.jobs,
          ).records(job.id))[first.id]!.artworkAssetId,
          cover.artworkAssetId,
        );
        expect(
          (await EnrichmentRepository(
            runtime.jobs,
          ).records(job.id))[second.id]!.artworkAssetId,
          isNull,
        );
        // Native output evidence is synthetic audio captured from the private sink,
        // not a claim about a physical speaker, Windows or a phone.
        debugPrint(
          'Stage 5 private output verified: 440 Hz and 880 Hz, bounded completion, stable IDs and durable review.',
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

double toneEnergy(Uint8List pcm, double frequency) {
  final data = ByteData.sublistView(pcm);
  var real = 0.0, imaginary = 0.0;
  for (var i = 0; i + 1 < pcm.length; i += 2) {
    final sample = data.getInt16(i, Endian.little),
        phase = 2 * math.pi * frequency * (i ~/ 2) / 44100;
    real += sample * math.cos(phase);
    imaginary += sample * math.sin(phase);
  }
  return math.sqrt(real * real + imaginary * imaginary) / (pcm.length / 2);
}
