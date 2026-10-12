import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';
import 'package:yt_playlist_downloader/data/job_repository.dart';
import 'package:yt_playlist_downloader/data/local_database.dart';
import 'package:yt_playlist_downloader/data/private_workspace.dart';
import 'package:yt_playlist_downloader/data/schema.dart';
import 'package:yt_playlist_downloader/domain/failure.dart';
import 'package:yt_playlist_downloader/domain/models.dart';
import 'package:yt_playlist_downloader/domain/playlist_url.dart';

import 'test_support.dart';

Matcher failure(FailureCode code) =>
    isA<AppFailure>().having((error) => error.code, 'code', code);

void main() {
  late Fixture fixture;
  setUp(() async {
    fixture = await Fixture.open();
  });
  tearDown(() async {
    await fixture.close();
  });

  test('fresh migrations create tables and enforce foreign keys', () async {
    expect(await fixture.db.getVersion(), Schema.version);
    expect(
      (await fixture.db.rawQuery('PRAGMA foreign_keys')).single.values.single,
      1,
    );
    expect(
      () => fixture.db.insert('playlist_entries', {
        'id': const Uuid().v4(),
        'job_id': 'missing',
        'position': 1,
      }),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('version one data survives an actual schema upgrade', () async {
    final path = '${fixture.root.path}/older.sqlite';
    final old = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        singleInstance: false,
        onCreate: (db, version) => Schema.migrate(db, 0, version),
      ),
    );
    final job = await JobRepository(old).createDraft(
      PlaylistUrl.parse('https://youtube.com/playlist?list=PLabcdefghij'),
    );
    await old.close();
    final upgraded = await LocalDatabase.open(databaseFactoryFfi, path);
    expect(await upgraded.getVersion(), Schema.version);
    expect(
      (await JobRepository(upgraded).getJob(job.id)).playlistId,
      'PLabcdefghij',
    );
    expect(await upgraded.query('attempts'), isEmpty);
    await upgraded.close();
  });

  test(
    'draft and human metadata edits survive closing and reopening SQLite',
    () async {
      final job = await fixture.draft();
      final track = await fixture.track(job);
      await fixture.jobs.editMetadata(
        trackId: track.id,
        revision: track.revision,
        candidate: SongMetadata(
          title: 'Corrected title',
          artists: ['Mira Vale'],
        ),
        fields: {MetadataField.title},
      );
      await fixture.db.close();
      final reopened = await LocalDatabase.open(
        databaseFactoryFfi,
        fixture.workspace.databasePath,
      );
      expect(
        (await JobRepository(reopened).getTrack(track.id)).metadata.title,
        'Corrected title',
      );
      expect(
        (await JobRepository(reopened).getJob(job.id)).sourceUrl,
        job.sourceUrl,
      );
      await reopened.close();
    },
  );

  test(
    'source identities deduplicate while playlist occurrence positions survive',
    () async {
      final job = await fixture.draft();
      final first = await fixture.track(job);
      final repeated = await fixture.track(job, position: 2);
      expect(repeated.id, first.id);
      expect(await fixture.jobs.listTracks(job.id), hasLength(1));
      expect(await fixture.db.query('playlist_entries'), hasLength(2));
    },
  );

  test('equal titles from distinct videos preserve distinct tracks', () async {
    final job = await fixture.draft();
    final first = await fixture.track(job);
    final second = await fixture.track(
      job,
      position: 2,
      videoId: 'lmnopqrstuv',
    );
    expect(first.id, isNot(second.id));
    expect(await fixture.jobs.listTracks(job.id), hasLength(2));
  });

  test(
    'stale human edits are rejected without overwriting the saved edit',
    () async {
      final track = await fixture.track(await fixture.draft());
      final edited = await fixture.jobs.editMetadata(
        trackId: track.id,
        revision: track.revision,
        candidate: SongMetadata(title: 'First edit', artists: ['Mira Vale']),
        fields: {MetadataField.title},
      );
      expect(
        () => fixture.jobs.editMetadata(
          trackId: track.id,
          revision: track.revision,
          candidate: SongMetadata(title: 'Stale edit', artists: ['Mira Vale']),
          fields: {MetadataField.title},
        ),
        throwsA(failure(FailureCode.conflict)),
      );
      expect(
        (await fixture.jobs.getTrack(track.id)).metadata.title,
        edited.metadata.title,
      );
    },
  );

  test('late AI is ignored and later AI updates only fields without human overrides', () async {
    final track = await fixture.track(await fixture.draft());
    final edited = await fixture.jobs.editMetadata(
      trackId: track.id,
      revision: track.revision,
      candidate: SongMetadata(title: 'My title', artists: ['Mira Vale']),
      fields: {MetadataField.title},
    );
    final suggestion = SongMetadata(
      title: 'Model title',
      artists: ['New artist'],
    );
    expect(
      await fixture.jobs.applySuggestion(
        trackId: track.id,
        revision: track.revision,
        suggestion: suggestion,
      ),
      isFalse,
    );
    expect(
      await fixture.jobs.applySuggestion(
        trackId: track.id,
        revision: edited.revision,
        suggestion: suggestion,
      ),
      isTrue,
    );
    final effective = await fixture.jobs.getTrack(track.id);
    expect(effective.metadata.title, 'My title');
    expect(effective.metadata.artists, ['New artist']);
    expect(effective.sourceTitle, 'Original source title');
  });

  test('cross-job asset ownership is rejected', () async {
    final owner = await fixture.draft();
    final other = await fixture.draft();
    final track = await fixture.track(owner);
    final attempt = await fixture.jobs.beginAttempt(
      jobId: owner.id,
      trackId: track.id,
      stage: TaskStage.conversion,
    );
    final id = const Uuid().v4();
    expect(
      () => fixture.jobs.registerAsset(
        AssetRecord(
          id: id,
          jobId: other.id,
          trackId: track.id,
          kind: AssetKind.audio,
          relativePath: PrivatePaths.asset(other.id, id, AssetKind.audio),
          sha256: List.filled(64, 'a').join(),
          bytes: 100,
        ),
        attempt: attempt,
      ),
      throwsA(failure(FailureCode.invalidMetadata)),
    );
    expect(await fixture.db.query('assets'), isEmpty);
  });

  test('a track cannot be marked ready without its audio manifest', () async {
    var track = await fixture.track(await fixture.draft());
    for (final phase in [TrackPhase.downloading, TrackPhase.converting]) {
      await fixture.jobs.setTrackState(track.id, track.revision, phase);
      track = await fixture.jobs.getTrack(track.id);
    }
    expect(
      () => fixture.jobs.setTrackState(
        track.id,
        track.revision,
        TrackPhase.ready,
      ),
      throwsA(failure(FailureCode.invalidTransition)),
    );
  });

  test(
    'interrupted attempts recover checkpoints and fence out the old worker',
    () async {
      final job = await fixture.draft();
      final track = await fixture.track(job);
      final old = await fixture.jobs.beginAttempt(
        jobId: job.id,
        trackId: track.id,
        stage: TaskStage.acquisition,
      );
      await fixture.jobs.saveCheckpoint(
        old,
        Checkpoint(step: CheckpointStep.acquired, completedBytes: 123),
      );
      expect(await fixture.jobs.recoverInterruptedAttempts(), 1);
      expect(await fixture.jobs.recoverInterruptedAttempts(), 0);
      expect(
        await fixture.jobs.applySuggestion(
          trackId: track.id,
          revision: track.revision,
          suggestion: SongMetadata(
            title: 'Stale worker',
            artists: ['Mira Vale'],
          ),
        ),
        isFalse,
      );
      final current = await fixture.jobs.beginAttempt(
        jobId: job.id,
        trackId: track.id,
        stage: TaskStage.acquisition,
      );
      expect(current.generation, greaterThan(old.generation));
      final row = (await fixture.db.query(
        'attempts',
        where: 'id = ?',
        whereArgs: [current.id],
      )).single;
      expect(
        (jsonDecode(row['checkpoint']! as String)
            as Map<String, Object?>)['completed_bytes'],
        123,
      );
      expect(
        () => fixture.jobs.saveCheckpoint(
          old,
          Checkpoint(step: CheckpointStep.published),
          complete: true,
        ),
        throwsA(failure(FailureCode.conflict)),
      );
      await fixture.jobs.saveCheckpoint(
        current,
        Checkpoint(step: CheckpointStep.acquired),
        complete: true,
      );
    },
  );

  test('a late worker cannot publish an asset after recovery', () async {
    final job = await fixture.draft();
    final track = await fixture.track(job);
    final attempt = await fixture.jobs.beginAttempt(
      jobId: job.id,
      trackId: track.id,
      stage: TaskStage.conversion,
    );
    await fixture.jobs.recoverInterruptedAttempts();
    final id = const Uuid().v4();
    await expectLater(
      fixture.jobs.registerAsset(
        AssetRecord(
          id: id,
          jobId: job.id,
          trackId: track.id,
          kind: AssetKind.audio,
          relativePath: PrivatePaths.asset(job.id, id, AssetKind.audio),
          sha256: List.filled(64, 'a').join(),
          bytes: 100,
        ),
        attempt: attempt,
      ),
      throwsA(failure(FailureCode.conflict)),
    );
    expect(await fixture.db.query('assets'), isEmpty);
  });

  test(
    'an export lock cannot be bypassed by a direct phase transition',
    () async {
      final job = await fixture.draft();
      final review = await fixture.review(job);
      await expectLater(
        fixture.jobs.transition(job.id, review.revision, JobPhase.exporting),
        throwsA(failure(FailureCode.invalidTransition)),
      );
      expect((await fixture.jobs.getJob(job.id)).phase, JobPhase.reviewReady);
    },
  );

  test(
    'an interrupted export must freeze the recovered revision again',
    () async {
      final job = await fixture.draft();
      await fixture.ready(await fixture.track(job));
      final review = await fixture.review(job);
      final original = await fixture.jobs.freezeExport(job.id, review.revision);
      await fixture.jobs.beginAttempt(jobId: job.id, stage: TaskStage.export);
      expect(await fixture.jobs.recoverInterruptedAttempts(), 1);
      final recovered = await fixture.jobs.getJob(job.id);
      expect(recovered.phase, JobPhase.reviewReady);
      expect(
        () => fixture.jobs.freezeExport(job.id, review.revision),
        throwsA(failure(FailureCode.conflict)),
      );
      final retried = await fixture.jobs.freezeExport(
        job.id,
        recovered.revision,
      );
      expect(retried.id, isNot(original.id));
      expect((await fixture.jobs.getJob(job.id)).phase, JobPhase.exporting);
    },
  );

  test('duplicate active attempts and late completion after cancellation are rejected', () async {
    final job = await fixture.draft();
    final token = await fixture.jobs.beginAttempt(
      jobId: job.id,
      stage: TaskStage.acquisition,
    );
    expect(
      () => fixture.jobs.beginAttempt(
        jobId: job.id,
        stage: TaskStage.acquisition,
      ),
      throwsA(failure(FailureCode.conflict)),
    );
    final current = await fixture.jobs.getJob(job.id);
    await fixture.jobs.transition(job.id, current.revision, JobPhase.cancelled);
    expect(
      () => fixture.jobs.saveCheckpoint(
        token,
        Checkpoint(step: CheckpointStep.published),
        complete: true,
      ),
      throwsA(failure(FailureCode.conflict)),
    );
  });

  test(
    'concurrent finalization reuses a frozen snapshot and locks metadata',
    () async {
      final job = await fixture.draft();
      final ready = await fixture.ready(await fixture.track(job));
      final review = await fixture.review(job);
      final results = await Future.wait([
        fixture.jobs.freezeExport(job.id, review.revision),
        fixture.jobs.freezeExport(job.id, review.revision),
      ]);
      expect(results.first.id, results.last.id);
      expect(await fixture.db.query('exports'), hasLength(1));
      final snapshot = jsonDecode(results.first.json) as Map<String, Object?>;
      expect(snapshot['assets'], hasLength(1));
      expect(
        () => fixture.jobs.editMetadata(
          trackId: ready.id,
          revision: ready.revision,
          candidate: SongMetadata(title: 'Too late', artists: ['Mira Vale']),
          fields: {MetadataField.title},
        ),
        throwsA(failure(FailureCode.conflict)),
      );
      expect(
        (await fixture.jobs.getTrack(ready.id)).metadata.title,
        'Moonlit Train',
      );
      final exportTask = await fixture.jobs.beginAttempt(
        jobId: job.id,
        stage: TaskStage.export,
      );
      expect(exportTask.stage, TaskStage.export);
    },
  );

  test(
    'unsafe asset paths and immutable-asset replacement are rejected',
    () async {
      final job = await fixture.draft();
      final track = await fixture.track(job);
      final id = const Uuid().v4();
      final hash = List.filled(64, 'a').join();
      final attempt = await fixture.jobs.beginAttempt(
        jobId: job.id,
        trackId: track.id,
        stage: TaskStage.conversion,
      );
      expect(
        () => fixture.jobs.registerAsset(
          AssetRecord(
            id: id,
            jobId: job.id,
            trackId: track.id,
            kind: AssetKind.audio,
            relativePath: '../../escape.mp3',
            sha256: hash,
            bytes: 100,
          ),
          attempt: attempt,
        ),
        throwsA(failure(FailureCode.invalidPath)),
      );
      final original = AssetRecord(
        id: id,
        jobId: job.id,
        trackId: track.id,
        kind: AssetKind.audio,
        relativePath: PrivatePaths.asset(job.id, id, AssetKind.audio),
        sha256: hash,
        bytes: 100,
      );
      await fixture.jobs.registerAsset(original, attempt: attempt);
      await fixture.jobs.registerAsset(original, attempt: attempt);
      expect(
        () => fixture.jobs.registerAsset(
          AssetRecord(
            id: id,
            jobId: job.id,
            trackId: track.id,
            kind: AssetKind.audio,
            relativePath: original.relativePath,
            sha256: hash,
            bytes: 101,
          ),
          attempt: attempt,
        ),
        throwsA(failure(FailureCode.conflict)),
      );
    },
  );
}
