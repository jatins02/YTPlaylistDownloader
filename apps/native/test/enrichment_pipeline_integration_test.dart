import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:yt_playlist_downloader/data/enrichment_repository.dart';
import 'package:yt_playlist_downloader/data/pipeline_repository.dart';
import 'package:yt_playlist_downloader/domain/enrichment.dart';
import 'package:yt_playlist_downloader/domain/failure.dart';
import 'package:yt_playlist_downloader/domain/models.dart';
import 'package:yt_playlist_downloader/domain/playlist_url.dart';
import 'package:yt_playlist_downloader/metadata/native_metadata_tools.dart';
import 'package:yt_playlist_downloader/metadata/providers.dart';
import 'package:yt_playlist_downloader/metadata/provider_transport.dart';
import 'package:yt_playlist_downloader/platform/desktop_media_port.dart';
import 'package:yt_playlist_downloader/platform/desktop_tools.dart';

import '../tool/media_smoke.dart' show SyntheticPlaylistSource;
import 'enrichment_test.dart' show artworkEvidence, failure;
import 'test_support.dart';

void main() {
  final manifest = Platform.environment['STAGE3_TEST_RUNTIME'];
  if (manifest == null || !Platform.isLinux) return;
  late Fixture fixture;
  late DesktopTools tools;
  late DesktopMediaPort media;
  late FixtureNaming naming;
  late FixtureArtwork artwork;
  setUp(() async {
    fixture = await Fixture.open();
    tools = await DesktopTools.load(
      File(manifest),
      File('assets/process_guard.py').absolute.path,
    );
    final scope = tools.scope();
    try {
      await scope.run(tools.python, [
        '-I',
        '-c',
        'from PIL import Image;Image.new("RGB",(32,32),"#f5d6e0").save("fixture.png")',
      ], directory: fixture.root);
    } finally {
      scope.cancel();
    }
    naming = FixtureNaming();
    artwork = FixtureArtwork(
      await File('${fixture.root.path}/fixture.png').readAsBytes(),
    );
    media = DesktopMediaPort(
      jobs: fixture.jobs,
      workspace: fixture.workspace,
      tools: tools,
      source: SyntheticPlaylistSource(tools),
      vault: MemoryVault(),
      metadataTools: NativeMetadataTools(
        tools,
        File('assets/metadata_tools.py').absolute.path,
      ),
      namingProvider: naming,
      artworkProvider: artwork,
    );
    await media.initialize();
  });
  tearDown(() async {
    await media.close();
    await fixture.close();
  });
  Future<JobRecord> draft() => fixture.jobs.createDraft(
    PlaylistUrl.parse('https://youtube.com/playlist?list=PLsyntheticNative01'),
  );
  Future<void> run(JobRecord job) =>
      media.acquire(playlist: PlaylistUrl.parse(job.sourceUrl), jobId: job.id);

  test('actual enrichment, cached covers and frozen MP3 readback preserve equal-title audio', () async {
    final job = await draft();
    await run(job);
    expect((await media.capabilities()).canEnrich, isTrue);
    expect((await media.capabilities()).canTag, isTrue);
    expect((await media.capabilities()).canExport, isFalse);
    final tracks = (await fixture.jobs.listTracks(job.id))
        .where((t) => t.phase == TrackPhase.ready)
        .toList();
    final records = await EnrichmentRepository(fixture.jobs).records(job.id);
    expect(tracks, hasLength(3));
    expect(records, hasLength(3));
    expect(naming.calls, 1);
    expect(tracks.every((t) => !t.metadata.needsReview), isTrue);
    expect(tracks.every((t) => t.metadata.album == 'Fictional album'), isTrue);
    expect(
      records.values.every((r) => r.artwork == ArtworkState.matched),
      isTrue,
    );
    final covers = (await PipelineRepository(fixture.jobs).assets(job.id))
        .where((a) => a.kind == AssetKind.artwork)
        .toList();
    expect(covers, hasLength(3));
    expect(covers.map((a) => a.id).toSet(), hasLength(3));
    expect(
      artwork.calls,
      lessThan(3),
    ); // equal metadata uses the bounded device cache
    for (final cover in covers) {
      expect(await media.coverBytes(job.id, cover.id), isNotNull);
    }
    final sourceAssets = (await PipelineRepository(fixture.jobs).assets(job.id))
        .where((a) => a.kind == AssetKind.audio)
        .toList();
    final hashes = sourceAssets.map((a) => a.sha256).toList();
    // Explicitly exclude the fictional failed peer and unmapped occurrence.
    for (final track in await fixture.jobs.listTracks(job.id)) {
      if (track.phase == TrackPhase.failed) {
        await fixture.jobs.setTrackState(
          track.id,
          track.revision,
          track.phase,
          selected: false,
        );
      }
    }
    for (final entry in await fixture.jobs.listEntries(job.id)) {
      if (entry.trackId == null) {
        await fixture.db.update(
          'playlist_entries',
          {'selected': 0},
          where: 'job_id=? AND position=? AND track_id IS NULL',
          whereArgs: [job.id, entry.position],
        );
      }
    }
    final current = await fixture.jobs.getJob(job.id);
    final snapshot = await fixture.jobs.freezeExport(job.id, current.revision);
    final data = jsonDecode(snapshot.json) as Map<String, dynamic>;
    expect(
      (data['tracks'] as List).every((t) => t['artwork_asset_id'] != null),
      isTrue,
    );
    final scope = tools.scope();
    final output = await media.files.work(job.id, const Uuid().v4());
    try {
      final results = <String>[];
      for (final track in tracks) {
        final work = await Directory('${output.path}/${track.id}').create();
        final tagged = await media.tagAdapter!.prepare(
          snapshot,
          track.id,
          scope,
          work,
          () => media.budget(job.id, scope, work),
        );
        expect(tagged.coverSha256, records[track.id]!.provenance!['sha256']);
        results.add(tagged.sha256);
      }
      expect(results.toSet(), hasLength(3));
      expect(
        (await PipelineRepository(fixture.jobs).assets(job.id))
            .where((a) => a.kind == AssetKind.audio)
            .map((a) => a.sha256),
        hashes,
      );
      await expectLater(
        fixture.jobs.editMetadata(
          trackId: tracks.first.id,
          revision: tracks.first.revision,
          candidate: tracks.first.metadata,
          fields: {MetadataField.title},
        ),
        failure(FailureCode.conflict),
      );
      final bad = ExportSnapshot(
        id: snapshot.id,
        jobId: snapshot.jobId,
        jobRevision: snapshot.jobRevision,
        hash: '0' * 64,
        json: snapshot.json,
      );
      await expectLater(
        media.tagAdapter!.prepare(
          bad,
          tracks.first.id,
          scope,
          output,
          () => media.budget(job.id, scope, output),
        ),
        failure(FailureCode.tagInvalid),
      );
    } finally {
      scope.cancel();
    }
  });
  test('failed naming preserves peers and only an explicit retry repeats provider work', () async {
    naming.fail = true;
    final job = await draft();
    await run(job);
    final before = (await PipelineRepository(fixture.jobs).assets(job.id))
        .where((a) => a.kind == AssetKind.audio)
        .map((a) => a.sha256)
        .toList();
    expect(
      (await fixture.jobs.listTracks(job.id))
          .where((t) => t.phase == TrackPhase.ready),
      hasLength(3),
    );
    expect(
      (await EnrichmentRepository(fixture.jobs).records(job.id)).values
          .every((r) => r.namingFailure == FailureCode.aiRateLimited),
      isTrue,
    );
    naming.fail = false;
    await media.enrich(job.id);
    expect(naming.calls, 2);
    await media.enrich(job.id);
    expect(naming.calls, 2); // completed peers are retained
    expect(
      (await PipelineRepository(fixture.jobs).assets(job.id))
          .where((a) => a.kind == AssetKind.audio)
          .map((a) => a.sha256),
      before,
    );
  });
  test('cancellation during provider wait fences names and covers without losing audio', () async {
    naming.block = true;
    final job = await draft(), task = run(job);
    await naming.entered.future.timeout(const Duration(seconds: 20));
    final stop = media.cancel(job.id);
    naming.release.complete();
    await stop;
    await task;
    expect((await fixture.jobs.getJob(job.id)).phase, JobPhase.cancelled);
    expect(
      (await fixture.jobs.listTracks(job.id))
          .where((t) => t.phase == TrackPhase.ready),
      hasLength(3),
    );
    expect(artwork.calls, 0);
    expect(
      (await PipelineRepository(fixture.jobs).assets(job.id))
          .where((a) => a.kind == AssetKind.audio),
      hasLength(3),
    );
  });
  test(
    'pause/resume retries only interrupted details and reuses verified audio',
    () async {
      naming.block = true;
      final job = await draft(), task = run(job);
      await naming.entered.future.timeout(const Duration(seconds: 20));
      final before = (await PipelineRepository(fixture.jobs).assets(job.id))
          .where((a) => a.kind == AssetKind.audio)
          .map((a) => a.id)
          .toList();
      final pause = media.pause(job.id);
      naming.release.complete();
      await pause;
      await task;
      expect((await fixture.jobs.getJob(job.id)).phase, JobPhase.queued);
      expect(
        (await EnrichmentRepository(fixture.jobs).records(job.id)).values
            .every((r) => r.naming == NamingState.pending),
        isTrue,
      );
      naming.block = false;
      await run(job);
      expect(naming.calls, 2);
      expect(
        (await PipelineRepository(fixture.jobs).assets(job.id))
            .where((a) => a.kind == AssetKind.audio)
            .map((a) => a.id),
        before,
      );
      expect(
        (await EnrichmentRepository(fixture.jobs).records(job.id)).values
            .every((r) => r.naming == NamingState.complete),
        isTrue,
      );
    },
  );
  test(
    'a late real normalized image cannot replace a human removal choice',
    () async {
      artwork.block = true;
      final job = await draft(), task = run(job);
      await artwork.entered.future.timeout(const Duration(seconds: 20));
      final track = (await fixture.jobs.listTracks(job.id)).first;
      await fixture.jobs.overrideArtwork(
        trackId: track.id,
        revision: track.revision,
      );
      artwork.release.complete();
      await task;
      final record = (await EnrichmentRepository(fixture.jobs)
          .records(job.id))[track.id]!;
      expect(record.artwork, ArtworkState.overridden);
      expect(record.artworkAssetId, isNull);
      expect(
        (await PipelineRepository(fixture.jobs).assets(
          job.id,
          trackId: track.id,
        )).where((a) => a.kind == AssetKind.artwork),
        isEmpty,
      );
    },
  );

  test('explicit cover retry repairs changed bytes without repeating accepted names', () async {
    final job = await draft();
    await run(job);
    final before = (await PipelineRepository(fixture.jobs).assets(job.id))
        .where((a) => a.kind == AssetKind.artwork)
        .toList();
    final damaged = before.first, source = await media.files.file(damaged);
    await source.writeAsBytes([1, 2, 3]);
    expect(await media.coverBytes(job.id, damaged.id), isNull);
    final calls = artwork.calls;
    await media.enrich(job.id);
    expect(naming.calls, 1);
    expect(artwork.calls, calls); // verified normalized cache reuse
    final after = (await PipelineRepository(fixture.jobs).assets(job.id))
        .where((a) => a.kind == AssetKind.artwork)
        .toList();
    expect(after, hasLength(3));
    expect(after.any((a) => a.id == damaged.id), isFalse);
    for (final peer in before.where((a) => a.id != damaged.id)) {
      expect(after.any((a) => a.id == peer.id), isTrue);
    }
  });

  test('invalid cache image is evicted and malformed artwork leaves playable peers', () async {
    artwork.invalid = true;
    final job = await draft();
    await run(job);
    expect(
      (await fixture.jobs.listTracks(job.id))
          .where((t) => t.phase == TrackPhase.ready),
      hasLength(3),
    );
    expect(
      (await PipelineRepository(fixture.jobs).assets(job.id))
          .where((a) => a.kind == AssetKind.artwork),
      isEmpty,
    );
    artwork.invalid = false;
    final store = EnrichmentRepository(fixture.jobs);
    final first = (await fixture.jobs.listTracks(job.id)).first;
    // A correctly hashed but invalid image in a corrupted cache cannot publish.
    final bytes = Uint8List.fromList([1, 2, 3]);
    final hash = await media.files.digest(
      (await File('${fixture.root.path}/bad-cache').writeAsBytes(bytes)).path,
    );
    await store.cache(
      first.metadata,
      bytes,
      artworkEvidence(first.metadata, hash),
    );
    await media.enrich(job.id);
    expect(naming.calls, 1);
    expect(
      (await store.records(job.id)).values
          .every((r) => r.artwork == ArtworkState.matched),
      isTrue,
    );
  });
}

final class FixtureNaming implements NamingProvider {
  int calls = 0;
  bool fail = false, block = false;
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<Map<String, NamingResult>> name(
    List<NamingInput> inputs,
    EnrichmentOptions options,
    RequestScope scope,
  ) async {
    calls++;
    if (block) {
      entered.complete();
      await release.future;
    }
    scope.check();
    if (fail) {
      throw const AppFailure(
        FailureCode.aiRateLimited,
        'Fictional quota failure',
      );
    }
    return {
      for (final input in inputs.reversed)
        input.trackId: NamingResult(
          SongMetadata(title: input.title, artists: ['Mira Vale']),
          null,
        ),
    };
  }
}

final class FixtureArtwork implements ArtworkProvider {
  FixtureArtwork(this.bytes);
  final Uint8List bytes;
  int calls = 0;
  bool invalid = false, block = false;
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<ArtworkDownload> find(
    SongMetadata metadata,
    EnrichmentOptions options,
    RequestScope scope,
  ) async {
    scope.check();
    calls++;
    if (block && calls == 1) {
      entered.complete();
      await release.future;
      scope.check();
    }
    final provenance = artworkEvidence(metadata, '0' * 64)..remove('sha256');
    return ArtworkDownload(
      invalid ? Uint8List.fromList([1, 2, 3]) : bytes,
      provenance,
    );
  }
}
