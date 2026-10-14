import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:yt_playlist_downloader/data/pipeline_repository.dart';
import 'package:yt_playlist_downloader/data/private_workspace.dart';
import 'package:yt_playlist_downloader/domain/failure.dart';
import 'package:yt_playlist_downloader/domain/media_models.dart';
import 'package:yt_playlist_downloader/domain/models.dart';

import 'test_support.dart';

Matcher failed(FailureCode code) =>
    isA<AppFailure>().having((e) => e.code, 'code', code);

void main() {
  late Fixture fixture;
  late PipelineRepository store;
  late JobRecord job;
  late AttemptToken enumeration;
  setUp(() async {
    fixture = await Fixture.open();
    store = PipelineRepository(fixture.jobs);
    job = await fixture.draft();
    job = await fixture.jobs.transition(job.id, job.revision, JobPhase.queued);
    job = await fixture.jobs.transition(
      job.id,
      job.revision,
      JobPhase.enumerating,
    );
    enumeration = await fixture.jobs.beginAttempt(
      jobId: job.id,
      stage: TaskStage.acquisition,
    );
  });
  tearDown(() async {
    await fixture.close();
  });

  const entries = [
    SourceEntry(
      position: 1,
      title: 'Equal title',
      videoId: 'abcdefghijk',
      durationSeconds: 2,
      uploader: 'Fictional channel',
    ),
    SourceEntry(
      position: 2,
      title: 'Equal title',
      videoId: '12345678901',
      durationSeconds: 2,
    ),
    SourceEntry(position: 3, title: 'Duplicate source', videoId: 'abcdefghijk'),
    SourceEntry(
      position: 4,
      title: 'Unavailable entry',
      failure: FailureCode.sourceUnavailable,
    ),
  ];
  Future<AttemptToken> processing() async {
    await store.commitEnumeration(enumeration, entries, const PipelineLimits());
    final current = await fixture.jobs.getJob(job.id);
    await fixture.jobs.transition(
      job.id,
      current.revision,
      JobPhase.processing,
    );
    return fixture.jobs.beginAttempt(
      jobId: job.id,
      trackId: (await fixture.jobs.listTracks(job.id)).first.id,
      stage: TaskStage.conversion,
    );
  }

  AssetRecord asset(AttemptToken token, AssetKind kind) {
    final id = const Uuid().v4();
    return AssetRecord(
      id: id,
      jobId: job.id,
      trackId: token.trackId,
      kind: kind,
      relativePath: PrivatePaths.asset(job.id, id, kind),
      sha256: List.filled(64, 'a').join(),
      bytes: 100,
    );
  }

  test('atomic enumeration preserves order, duplicate sources, equal titles and missing identities', () async {
    await store.commitEnumeration(enumeration, entries, const PipelineLimits());
    final snapshot = await fixture.jobs.processingSnapshot(job.id);
    expect(snapshot.$1.enumerated, isTrue);
    expect(snapshot.$2, hasLength(2));
    expect(snapshot.$3, hasLength(4));
    expect(snapshot.$2[0].id, isNot(snapshot.$2[1].id));
    expect(snapshot.$3[0].trackId, snapshot.$3[2].trackId);
    expect(snapshot.$3.last.trackId, isNull);
    expect(snapshot.$3.last.failure, FailureCode.sourceUnavailable);
    expect(snapshot.$3.map((e) => e.position), [1, 2, 3, 4]);
    expect(snapshot.$2.first.metadata.artists, isEmpty);
    expect(snapshot.$2.first.originalMetadata!.title, 'Equal title');
    expect(snapshot.$2.first.sourceUploader, 'Fictional channel');
    expect(
      () =>
          store.commitEnumeration(enumeration, entries, const PipelineLimits()),
      throwsA(failed(FailureCode.conflict)),
    );
  });

  test(
    'malformed enumeration rolls back every prefix row and completion flag',
    () async {
      expect(
        () => store.commitEnumeration(enumeration, [
          entries.first,
          const SourceEntry(position: 2, title: 'Bad', videoId: '../escape'),
        ], const PipelineLimits()),
        throwsA(failed(FailureCode.invalidMetadata)),
      );
      await Future<void>.delayed(Duration.zero);
      expect(await fixture.jobs.listTracks(job.id), isEmpty);
      expect(await store.entries(job.id), isEmpty);
      expect((await fixture.jobs.getJob(job.id)).enumerated, isFalse);
    },
  );

  test(
    'capacity rejection never imports a silently truncated prefix',
    () async {
      await expectLater(
        store.commitEnumeration(
          enumeration,
          entries,
          const PipelineLimits(maxTracks: 1),
        ),
        throwsA(failed(FailureCode.limitExceeded)),
      );
      expect(await fixture.jobs.listTracks(job.id), isEmpty);
      expect((await fixture.jobs.getJob(job.id)).enumerated, isFalse);
    },
  );

  test(
    'cancel fences late enumeration before any rows can be published',
    () async {
      await store.stop(job.id, cancel: true);
      await expectLater(
        store.commitEnumeration(enumeration, entries, const PipelineLimits()),
        throwsA(failed(FailureCode.conflict)),
      );
      expect(await store.entries(job.id), isEmpty);
    },
  );

  test('active audio is explicit and replacing it cannot mutate retained manifests', () async {
    final token = await processing();
    final first = asset(token, AssetKind.audio),
        second = asset(token, AssetKind.audio);
    await store.publish(token, first, CheckpointStep.converted);
    await store.publish(token, second, CheckpointStep.converted);
    expect(
      (await store.assets(job.id, trackId: token.trackId)).single.id,
      second.id,
    );
    expect(
      await store.assets(job.id, trackId: token.trackId, activeOnly: false),
      hasLength(2),
    );
    final firstRow = (await fixture.db.query(
      'assets',
      where: 'id = ?',
      whereArgs: [first.id],
    )).single;
    expect(firstRow['sha256'], first.sha256);
    expect(firstRow['active'], 0);
  });

  test('ready requires both verified-manifest kinds, preview keeps the audio checkpoint', () async {
    final token = await processing();
    await store.trackPhase(token, TrackPhase.downloading);
    await store.trackPhase(token, TrackPhase.converting);
    final audio = asset(token, AssetKind.audio);
    await store.publish(token, audio, CheckpointStep.converted);
    await expectLater(
      store.trackPhase(token, TrackPhase.ready),
      throwsA(failed(FailureCode.audioInvalid)),
    );
    await store.publish(
      token,
      asset(token, AssetKind.preview),
      CheckpointStep.converted,
    );
    final checkpoint = jsonDecode(
      (await fixture.db.query(
            'attempts',
            where: 'id = ?',
            whereArgs: [token.id],
          )).single['checkpoint']!
          as String,
    ) as Map<String, dynamic>;
    expect(checkpoint['asset_id'], audio.id);
    await store.trackPhase(token, TrackPhase.ready, duration: 2.4);
    expect((await fixture.jobs.getTrack(token.trackId!)).durationSeconds, 2.4);
    await expectLater(
      store.publish(
        token,
        asset(token, AssetKind.source),
        CheckpointStep.acquired,
      ),
      throwsA(failed(FailureCode.conflict)),
    );
  });

  test('replacement audio atomically invalidates its previous snippet across restart', () async {
    final token = await processing();
    await store.trackPhase(token, TrackPhase.downloading);
    await store.trackPhase(token, TrackPhase.converting);
    await store.publish(
      token,
      asset(token, AssetKind.audio),
      CheckpointStep.converted,
    );
    final oldPreview = asset(token, AssetKind.preview);
    await store.publish(token, oldPreview, CheckpointStep.converted);
    final replacement = asset(token, AssetKind.audio);
    await store.publish(token, replacement, CheckpointStep.converted);
    await fixture.jobs.recoverInterruptedAttempts();
    final active = await store.assets(job.id, trackId: token.trackId);
    expect(active.map((a) => a.id), [replacement.id]);
    expect(
      await store.assets(job.id, trackId: token.trackId, activeOnly: false),
      hasLength(3),
    );
    expect(
      (await fixture.jobs.getTrack(token.trackId!)).phase,
      TrackPhase.queued,
    );
  });

  test(
    'wrong stage cannot mutate track phases or retire another attempts audio',
    () async {
      final token = await processing();
      final audio = asset(token, AssetKind.audio);
      await store.publish(token, audio, CheckpointStep.converted);
      final wrong = await fixture.jobs.beginAttempt(
        jobId: job.id,
        trackId: token.trackId,
        stage: TaskStage.enrichment,
      );
      await expectLater(
        store.trackPhase(wrong, TrackPhase.downloading),
        throwsA(failed(FailureCode.invalidTransition)),
      );
      await expectLater(
        store.retire(wrong, AssetKind.audio),
        throwsA(failed(FailureCode.invalidTransition)),
      );
      expect((await store.assets(job.id)).single.id, audio.id);
    },
  );

  test('publication rejects inconsistent checkpoints without changing active audio', () async {
    final token = await processing();
    await expectLater(
      store.publish(
        token,
        asset(token, AssetKind.audio),
        CheckpointStep.acquired,
      ),
      throwsA(failed(FailureCode.invalidTransition)),
    );
    expect(await store.assets(job.id), isEmpty);
  });

  test(
    'pause and retry fence stale workers while preserving verified assets',
    () async {
      final old = await processing();
      final audio = asset(old, AssetKind.audio);
      await store.publish(old, audio, CheckpointStep.converted);
      await store.trackPhase(old, TrackPhase.downloading);
      await store.stop(job.id);
      expect((await fixture.jobs.getJob(job.id)).phase, JobPhase.queued);
      expect(
        (await fixture.jobs.getTrack(old.trackId!)).phase,
        TrackPhase.queued,
      );
      await expectLater(
        store.trackPhase(old, TrackPhase.converting),
        throwsA(failed(FailureCode.conflict)),
      );
      final next = await fixture.jobs.beginAttempt(
        jobId: job.id,
        trackId: old.trackId,
        stage: TaskStage.conversion,
      );
      expect(next.generation, greaterThan(old.generation));
      expect((await store.assets(job.id)).single.id, audio.id);
    },
  );

  test(
    'failed peers can retry without reenumerating or resetting human metadata',
    () async {
      final token = await processing();
      await store.trackPhase(
        token,
        TrackPhase.failed,
        failure: FailureCode.sourceUnavailable,
      );
      final current = await fixture.jobs.getJob(job.id);
      await fixture.jobs.transition(
        job.id,
        current.revision,
        JobPhase.reviewReady,
      );
      await store.retryFailedTracks(job.id);
      final track = await fixture.jobs.getTrack(token.trackId!);
      expect(track.phase, TrackPhase.queued);
      expect(track.failure, isNull);
      expect((await fixture.jobs.getJob(job.id)).enumerated, isTrue);
      expect(await store.entries(job.id), hasLength(4));
    },
  );

  test('only cancelled private-media manifests can be discarded', () async {
    final token = await processing();
    await store.publish(
      token,
      asset(token, AssetKind.source),
      CheckpointStep.acquired,
    );
    await expectLater(
      store.dropCancelledAssets(job.id),
      throwsA(failed(FailureCode.conflict)),
    );
    await store.stop(job.id, cancel: true);
    await store.dropCancelledAssets(job.id);
    expect(await store.assets(job.id), isEmpty);
    expect(await store.entries(job.id), hasLength(4));
  });
}
