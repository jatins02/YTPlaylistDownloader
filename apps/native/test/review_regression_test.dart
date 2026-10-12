import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:yt_playlist_downloader/application/drafts_controller.dart';
import 'package:yt_playlist_downloader/data/private_workspace.dart';
import 'package:yt_playlist_downloader/data/local_database.dart';
import 'package:yt_playlist_downloader/data/job_repository.dart';
import 'package:yt_playlist_downloader/data/schema.dart';
import 'package:yt_playlist_downloader/domain/playlist_url.dart';
import 'package:yt_playlist_downloader/domain/draft_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:yt_playlist_downloader/domain/failure.dart';
import 'package:yt_playlist_downloader/domain/models.dart';
import 'package:yt_playlist_downloader/platform/credential_vault.dart';

import 'test_support.dart';

final class DelayedPresenceVault implements CredentialVault {
  final started = Completer<void>();
  final presence = Completer<bool>();
  @override
  Future<bool> hasGroqKey() {
    started.complete();
    return presence.future;
  }

  @override
  Future<void> saveGroqKey(ApiKey key) async {}
  @override
  Future<void> removeGroqKey() async {}
  @override
  Future<ApiKey?> readGroqKey() async => null;
}

final class DelayedDraftStore implements DraftStore {
  DelayedDraftStore(this.delegate);
  final DraftStore delegate;
  final started = Completer<void>();
  final result = Completer<List<JobRecord>>();
  @override
  Future<List<JobRecord>> listJobs() {
    started.complete();
    return result.future;
  }

  @override
  Future<JobRecord> createDraft(PlaylistUrl playlist, {String? identity}) =>
      delegate.createDraft(playlist, identity: identity);
}

Matcher conflict = isA<AppFailure>().having(
  (error) => error.code,
  'code',
  FailureCode.conflict,
);

void main() {
  late Fixture fixture;
  setUp(() async {
    fixture = await Fixture.open();
  });
  tearDown(() async {
    await fixture.close();
  });

  test('new tracks retain original metadata after human edits', () async {
    final track = await fixture.track(await fixture.draft());
    final edited = await fixture.jobs.editMetadata(
      trackId: track.id,
      revision: track.revision,
      candidate: SongMetadata(
        title: 'Human edit',
        artists: ['Different artist'],
      ),
      fields: {MetadataField.title, MetadataField.artists},
    );
    expect(edited.originalMetadata!.title, 'Moonlit Train');
    expect(edited.originalMetadata!.artists, ['Mira Vale']);
    expect(edited.metadata.title, 'Human edit');
    expect(edited.sourceTitle, 'Original source title');
  });

  test('a modified stored export snapshot is rejected before reuse', () async {
    final job = await fixture.draft();
    await fixture.ready(await fixture.track(job));
    final review = await fixture.review(job);
    final snapshot = await fixture.jobs.freezeExport(job.id, review.revision);
    await fixture.db.update(
      'exports',
      {'snapshot': '{}'},
      where: 'id = ?',
      whereArgs: [snapshot.id],
    );
    await expectLater(
      fixture.jobs.freezeExport(job.id, review.revision),
      throwsA(
        isA<AppFailure>().having(
          (error) => error.code,
          'code',
          FailureCode.corruptData,
        ),
      ),
    );
  });

  test('completed snapshot reuse stops after the review is edited', () async {
    final job = await fixture.draft();
    final track = await fixture.ready(await fixture.track(job));
    final review = await fixture.review(job);
    final snapshot = await fixture.jobs.freezeExport(job.id, review.revision);
    // State fixture only: actual tagged ZIP publication remains Stage 6 work.
    await fixture.db.update(
      'exports',
      {'status': 'complete'},
      where: 'id = ?',
      whereArgs: [snapshot.id],
    );
    final exporting = await fixture.jobs.getJob(job.id);
    await fixture.jobs.transition(
      job.id,
      exporting.revision,
      JobPhase.exportReady,
    );
    expect(
      (await fixture.jobs.freezeExport(job.id, review.revision)).id,
      snapshot.id,
    );
    await fixture.jobs.editMetadata(
      trackId: track.id,
      revision: track.revision,
      candidate: SongMetadata(title: 'New title', artists: ['Mira Vale']),
      fields: {MetadataField.title},
    );
    await expectLater(
      fixture.jobs.freezeExport(job.id, review.revision),
      throwsA(conflict),
    );
  });

  test('a delayed initial draft list merges a newly committed draft', () async {
    final older = await fixture.draft();
    final store = DelayedDraftStore(fixture.jobs);
    final controller = DraftsController(
      jobs: store,
      workspace: fixture.workspace,
      vault: MemoryVault(),
    );
    addTearDown(controller.dispose);
    final loading = controller.load();
    await store.started.future;
    expect(
      await controller.saveDraft(
        'https://youtube.com/playlist?list=PLabcdefghij',
      ),
      isTrue,
    );
    final newer = controller.drafts.single;
    store.result.complete([older]);
    await loading;
    expect(
      controller.drafts.map((job) => job.id),
      containsAll([older.id, newer.id]),
    );
    expect(controller.drafts, hasLength(2));
    expect(await fixture.jobs.listJobs(), hasLength(2));
  });

  test(
    'invalid input during initial loading does not discard existing drafts',
    () async {
      final older = await fixture.draft();
      final store = DelayedDraftStore(fixture.jobs);
      final controller = DraftsController(
        jobs: store,
        workspace: fixture.workspace,
        vault: MemoryVault(),
      );
      addTearDown(controller.dispose);
      final loading = controller.load();
      await store.started.future;
      expect(await controller.saveDraft('invalid'), isFalse);
      store.result.complete([older]);
      await loading;
      expect(controller.drafts.single.id, older.id);
      expect(controller.failure!.code, FailureCode.invalidPlaylist);
    },
  );

  test(
    'v2 migration preserves edits and does not invent lost original fields',
    () async {
      final path = '${fixture.root.path}/version2.sqlite';
      final older = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 2,
          singleInstance: false,
          onCreate: (db, version) => Schema.migrate(db, 0, version),
        ),
      );
      final job = await JobRepository(older).createDraft(
        PlaylistUrl.parse('https://youtube.com/playlist?list=PL1234567890'),
      );
      final id = const Uuid().v4();
      final metadata = SongMetadata(
        title: 'Already edited',
        artists: ['Mira Vale'],
      );
      await older.insert('tracks', {
        'id': id,
        'job_id': job.id,
        'video_id': 'abcdefghijk',
        'source_title': 'Original source title',
        'metadata': jsonEncode(metadata.toJson()),
        'phase': 'queued',
      });
      await older.close();
      final upgraded = await LocalDatabase.open(databaseFactoryFfi, path);
      try {
        final track = await JobRepository(upgraded).getTrack(id);
        expect(track.metadata.title, 'Already edited');
        expect(track.originalMetadata, isNull);
        expect(track.sourceTitle, 'Original source title');
        expect(await upgraded.getVersion(), Schema.version);
      } finally {
        await upgraded.close();
      }
    },
  );

  test('a checkpoint cannot reference another job audio asset', () async {
    final owner = await fixture.draft();
    await fixture.ready(await fixture.track(owner));
    final other = await fixture.draft();
    final track = await fixture.track(other);
    final token = await fixture.jobs.beginAttempt(
      jobId: other.id,
      trackId: track.id,
      stage: TaskStage.conversion,
    );
    final asset = (await fixture.db.query('assets')).single;
    await expectLater(
      fixture.jobs.saveCheckpoint(
        token,
        Checkpoint(
          step: CheckpointStep.converted,
          assetId: asset['id']! as String,
        ),
      ),
      throwsA(isA<AppFailure>()),
    );
  });

  test(
    'finishing a recovered attempt retires its historical retryable row',
    () async {
      final job = await fixture.draft();
      final track = await fixture.ready(await fixture.track(job));
      await fixture.jobs.beginAttempt(
        jobId: job.id,
        trackId: track.id,
        stage: TaskStage.enrichment,
      );
      final review = await fixture.review(job);
      await fixture.jobs.recoverInterruptedAttempts();
      expect((await fixture.jobs.getJob(job.id)).phase, JobPhase.reviewReady);
      final current = await fixture.jobs.beginAttempt(
        jobId: job.id,
        trackId: track.id,
        stage: TaskStage.enrichment,
      );
      await fixture.jobs.saveCheckpoint(
        current,
        Checkpoint(step: CheckpointStep.enriched),
        complete: true,
      );
      final recovered = await fixture.jobs.getJob(job.id);
      expect(recovered.revision, review.revision + 1);
      await fixture.jobs.freezeExport(job.id, recovered.revision);
    },
  );

  test(
    'cancelling a track fences its worker without cancelling its peers',
    () async {
      final job = await fixture.draft();
      final track = await fixture.track(job);
      final peer = await fixture.track(
        job,
        position: 2,
        videoId: 'lmnopqrstuv',
      );
      final token = await fixture.jobs.beginAttempt(
        jobId: job.id,
        trackId: track.id,
        stage: TaskStage.acquisition,
      );
      final peerToken = await fixture.jobs.beginAttempt(
        jobId: job.id,
        trackId: peer.id,
        stage: TaskStage.acquisition,
      );
      await fixture.jobs.setTrackState(
        track.id,
        track.revision,
        TrackPhase.cancelled,
      );
      await expectLater(
        fixture.jobs.saveCheckpoint(
          token,
          Checkpoint(step: CheckpointStep.acquired),
        ),
        throwsA(conflict),
      );
      await fixture.jobs.saveCheckpoint(
        peerToken,
        Checkpoint(step: CheckpointStep.acquired),
      );
      await fixture.jobs.recoverInterruptedAttempts();
      expect(
        (await fixture.jobs.getTrack(track.id)).phase,
        TrackPhase.cancelled,
      );
    },
  );

  test(
    'recovery preserves playable enrichment and touches each job once',
    () async {
      final job = await fixture.draft();
      final ready = await fixture.ready(await fixture.track(job));
      final pending = await fixture.track(
        job,
        position: 2,
        videoId: 'lmnopqrstuv',
      );
      final review = await fixture.review(job);
      await fixture.jobs.beginAttempt(
        jobId: job.id,
        trackId: ready.id,
        stage: TaskStage.enrichment,
      );
      await fixture.jobs.beginAttempt(
        jobId: job.id,
        trackId: pending.id,
        stage: TaskStage.acquisition,
      );
      expect(await fixture.jobs.recoverInterruptedAttempts(), 2);
      expect((await fixture.jobs.getTrack(ready.id)).phase, TrackPhase.ready);
      expect((await fixture.jobs.getJob(job.id)).revision, review.revision + 1);
    },
  );

  test('returning to review retires an active export worker', () async {
    final job = await fixture.draft();
    await fixture.ready(await fixture.track(job));
    final review = await fixture.review(job);
    await fixture.jobs.freezeExport(job.id, review.revision);
    final worker = await fixture.jobs.beginAttempt(
      jobId: job.id,
      stage: TaskStage.export,
    );
    final exporting = await fixture.jobs.getJob(job.id);
    await fixture.jobs.transition(
      job.id,
      exporting.revision,
      JobPhase.reviewReady,
    );
    await expectLater(
      fixture.jobs.saveCheckpoint(
        worker,
        Checkpoint(step: CheckpointStep.published),
      ),
      throwsA(conflict),
    );
    final current = await fixture.jobs.getJob(job.id);
    await fixture.jobs.freezeExport(job.id, current.revision);
    await fixture.jobs.beginAttempt(jobId: job.id, stage: TaskStage.export);
  });

  test(
    'a new export cannot inherit the preceding snapshot checkpoint',
    () async {
      final job = await fixture.draft();
      await fixture.ready(await fixture.track(job));
      final review = await fixture.review(job);
      await fixture.jobs.freezeExport(job.id, review.revision);
      final worker = await fixture.jobs.beginAttempt(
        jobId: job.id,
        stage: TaskStage.export,
      );
      await fixture.jobs.saveCheckpoint(
        worker,
        Checkpoint(step: CheckpointStep.published, completedBytes: 99),
      );
      await fixture.jobs.recoverInterruptedAttempts();
      final recovered = await fixture.jobs.getJob(job.id);
      await fixture.jobs.freezeExport(job.id, recovered.revision);
      final newWorker = await fixture.jobs.beginAttempt(
        jobId: job.id,
        stage: TaskStage.export,
      );
      final row = (await fixture.db.query(
        'attempts',
        where: 'id = ?',
        whereArgs: [newWorker.id],
      )).single;
      expect(
        (jsonDecode(row['checkpoint']! as String)
            as Map<String, Object?>)['step'],
        'pending',
      );
    },
  );

  test(
    'finalization rejects multiple audio assets for one selected track',
    () async {
      final job = await fixture.draft();
      final track = await fixture.ready(await fixture.track(job));
      final token = await fixture.jobs.beginAttempt(
        jobId: job.id,
        trackId: track.id,
        stage: TaskStage.conversion,
      );
      final assetId = const Uuid().v4();
      await fixture.jobs.registerAsset(
        AssetRecord(
          id: assetId,
          jobId: job.id,
          trackId: track.id,
          kind: AssetKind.audio,
          relativePath: PrivatePaths.asset(job.id, assetId, AssetKind.audio),
          sha256: List.filled(64, 'b').join(),
          bytes: 101,
        ),
        attempt: token,
      );
      await fixture.jobs.saveCheckpoint(
        token,
        Checkpoint(step: CheckpointStep.converted),
        complete: true,
      );
      final review = await fixture.review(job);
      await expectLater(
        fixture.jobs.freezeExport(job.id, review.revision),
        throwsA(isA<AppFailure>()),
      );
      expect(await fixture.db.query('exports'), isEmpty);
    },
  );

  test('a delayed key-presence read cannot undo a newer save', () async {
    final vault = DelayedPresenceVault();
    final controller = DraftsController(
      jobs: fixture.jobs,
      workspace: fixture.workspace,
      vault: vault,
    );
    addTearDown(controller.dispose);
    final loading = controller.load();
    await vault.started.future;
    expect(
      await controller.saveKey('gsk_${List.filled(40, 'x').join()}'),
      isTrue,
    );
    vault.presence.complete(false);
    await loading;
    expect(controller.hasKey, isTrue);
  });
}
