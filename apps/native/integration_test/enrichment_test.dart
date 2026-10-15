import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:uuid/uuid.dart';
import 'package:yt_playlist_downloader/application/app_runtime.dart';
import 'package:yt_playlist_downloader/application/processing_controller.dart';
import 'package:yt_playlist_downloader/data/enrichment_repository.dart';
import 'package:yt_playlist_downloader/data/pipeline_repository.dart';
import 'package:yt_playlist_downloader/domain/enrichment.dart';
import 'package:yt_playlist_downloader/domain/models.dart';
import 'package:yt_playlist_downloader/domain/playlist_url.dart';
import 'package:yt_playlist_downloader/metadata/provider_transport.dart';
import 'package:yt_playlist_downloader/platform/credential_vault.dart';
import 'package:yt_playlist_downloader/platform/desktop_media_port.dart';
import 'package:yt_playlist_downloader/platform/desktop_tools.dart';
import 'package:yt_playlist_downloader/ui/processing_screen.dart';
import 'package:yt_playlist_downloader/ui/theme.dart';

import '../tool/media_smoke.dart' show SyntheticPlaylistSource;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native secure key, enrichment UI, image/ID3 workers and durable restart',
    (tester) async {
      final manifest = Platform.environment['STAGE3_TEST_RUNTIME'];
      if (!Platform.isLinux || manifest == null) {
        throw StateError('Set the pinned Linux STAGE3_TEST_RUNTIME.');
      }
      final root = await Directory.systemTemp.createTemp('ytpd-stage4-native-');
      final vault = SecureCredentialVault(
        credentialKey: 'ytpd.stage4.test.${const Uuid().v4()}',
      );
      final tools = await DesktopTools.load(
        File(manifest),
        File('assets/process_guard.py').absolute.path,
      );
      final scope = tools.scope();
      try {
        await scope.run(tools.python, [
          '-I',
          '-c',
          'from PIL import Image;Image.new("RGB",(32,32),"#f5d6e0").save("fixture.png")',
        ], directory: root);
      } finally {
        scope.cancel();
      }
      final transport = NativeFixtureTransport(
        await File('${root.path}/fixture.png').readAsBytes(),
      );
      AppRuntime? runtime;
      try {
        // Only a unique synthetic credential in the real OS keyring; no owner key.
        await vault.saveGroqKey(
          ApiKey.parse('gsk_${const Uuid().v4().replaceAll('-', '')}'),
        );
        runtime = await AppRuntime.open(
          supportRoot: root,
          vault: vault,
          mediaManifest: File(manifest),
          source: SyntheticPlaylistSource(tools),
          metadataTransport: transport,
        );
        final media = runtime.media as DesktopMediaPort;
        expect((await media.capabilities()).canTag, isTrue);
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
        await controller.initialize();
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('start-processing')));
        await tester.tap(find.byKey(const Key('start-processing')));
        final deadline = DateTime.now().add(const Duration(seconds: 90));
        while (controller.commanding && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await controller.refresh(force: true);
        await tester.pumpAndSettle();
        expect(controller.job!.phase, JobPhase.reviewReady);
        expect(controller.readyCount, 3);
        expect(controller.failedCount, 1);
        expect(controller.enrichment, hasLength(3));
        expect(
          controller.enrichment.values.every(
            (r) =>
                r.naming == NamingState.complete &&
                r.artwork == ArtworkState.matched,
          ),
          isTrue,
        );
        expect(controller.covers, hasLength(3));
        expect(transport.authorized, isTrue);
        expect(transport.namingRequests, 1);
        await tester.ensureVisible(find.byKey(const Key('metadata-options')));
        await tester.tap(find.byKey(const Key('metadata-options')));
        await tester.pumpAndSettle();
        expect(find.text('Naming and artwork settings'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        final ready = controller.tracks
            .where((t) => t.phase == TrackPhase.ready)
            .toList();
        for (final track in controller.tracks.where(
          (t) => t.phase == TrackPhase.failed,
        )) {
          await runtime.jobs.setTrackState(
            track.id,
            track.revision,
            track.phase,
            selected: false,
          );
        }
        await runtime.jobs.db.update(
          'playlist_entries',
          {'selected': 0},
          where: 'job_id=? AND track_id IS NULL',
          whereArgs: [job.id],
        );
        final current = await runtime.jobs.getJob(job.id);
        final snapshot = await runtime.jobs.freezeExport(
          job.id,
          current.revision,
        );
        final tagScope = tools.scope(),
            work = await media.files.work(job.id, const Uuid().v4());
        try {
          final tagged = await media.tagAdapter!.prepare(
            snapshot,
            ready.first.id,
            tagScope,
            work,
            () => media.budget(job.id, tagScope, work),
          );
          expect(
            tagged.coverSha256,
            controller.enrichment[ready.first.id]!.provenance!['sha256'],
          );
        } finally {
          tagScope.cancel();
        }
        final identities = ready.map((t) => t.id).toList(),
            coverIds = controller.enrichment.values
                .map((r) => r.artworkAssetId)
                .toSet();
        await tester.pumpWidget(const SizedBox.shrink());
        await runtime.close();
        runtime = null;
        runtime = await AppRuntime.open(
          supportRoot: root,
          vault: vault,
          mediaManifest: File(manifest),
        );
        expect(
          (await runtime.jobs.listTracks(job.id))
              .where((t) => t.phase == TrackPhase.ready)
              .map((t) => t.id),
          identities,
        );
        expect(
          (await EnrichmentRepository(runtime.jobs).records(job.id)).values
              .map((r) => r.artworkAssetId)
              .toSet(),
          coverIds,
        );
        expect(
          (await PipelineRepository(runtime.jobs).assets(job.id))
              .where((a) => a.kind == AssetKind.artwork),
          hasLength(3),
        );
        expect(
          (await runtime.jobs.getJob(job.id)).phase,
          JobPhase.reviewReady,
        ); // interrupted planned export recovered
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await runtime?.close();
        await vault.removeGroqKey();
        await root.delete(recursive: true);
      }
    },
  );
}

final class NativeFixtureTransport implements ProviderTransport {
  NativeFixtureTransport(this.image);
  final Uint8List image;
  String title = '';
  bool authorized = false;
  int namingRequests = 0;
  static const recording = '11111111-1111-4111-8111-111111111111',
      release = '22222222-2222-4222-8222-222222222222';
  ProviderReply json(Object value) => ProviderReply(
    200,
    Uint8List.fromList(utf8.encode(jsonEncode(value))),
    contentType: 'application/json',
  );
  Map<String, Object?> get identity => {
    'id': recording,
    'title': title,
    'artist-credit': [
      {
        'artist': {'name': 'Mira Vale'},
      },
    ],
  };
  @override
  Future<ProviderReply> request(
    Uri uri,
    RequestScope scope, {
    Map<String, String> headers = const {},
    Map<String, Object?>? body,
    int maxBytes = 256 * 1024,
  }) async {
    scope.check();
    if (uri.host == 'api.groq.com') {
      namingRequests++;
      authorized = headers['Authorization']?.startsWith('Bearer gsk_') == true;
      final messages = body!['messages'] as List;
      final records =
          (jsonDecode(messages.last['content'] as String)
                  as Map)['source_records']
              as List;
      return json({
        'choices': [
          {
            'finish_reason': 'stop',
            'message': {
              'content': jsonEncode({
                'tracks': records.reversed
                    .map(
                      (r) => {
                        'track_id': r['track_id'],
                        'title': r['title'],
                        'artists': ['Mira Vale'],
                        'featured_artists': <String>[],
                        'album': null,
                        'version': null,
                        'needs_review': false,
                        'reason': null,
                      },
                    )
                    .toList(),
              }),
            },
          },
        ],
      });
    }
    if (uri.host == 'musicbrainz.org' && uri.path.endsWith('/recording/')) {
      title = RegExp(r'^recording:"(.*?)" AND')
          .firstMatch(uri.queryParameters['query']!)!
          .group(1)!
          .replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!);
      return json({
        'count': 1,
        'recordings': [identity],
      });
    }
    if (uri.host == 'musicbrainz.org') {
      return json({
        ...identity,
        'releases': [
          {'id': release, 'title': 'Fictional album'},
        ],
      });
    }
    if (uri.host == 'coverartarchive.org') {
      return json({
        'images': [
          {
            'front': true,
            'approved': true,
            'image': 'https://archive.org/fictional.png',
          },
        ],
      });
    }
    return ProviderReply(200, image, contentType: 'image/png');
  }
}
