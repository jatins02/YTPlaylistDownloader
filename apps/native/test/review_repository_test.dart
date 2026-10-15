import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:yt_playlist_downloader/data/job_repository.dart';
import 'package:yt_playlist_downloader/data/local_database.dart';
import 'package:yt_playlist_downloader/data/pipeline_repository.dart';
import 'package:yt_playlist_downloader/data/private_workspace.dart';
import 'package:yt_playlist_downloader/data/review_repository.dart';
import 'package:yt_playlist_downloader/domain/failure.dart';
import 'package:yt_playlist_downloader/domain/models.dart';
import 'package:yt_playlist_downloader/domain/review.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'test_support.dart';

void main() {
  late Fixture f;
  late ReviewRepository review;
  late TrackRecord track;
  setUp(() async {
    f = await Fixture.open();
    final job = await f.draft();
    track = await f.ready(await f.track(job));
    await f.review(job);
    review = ReviewRepository(f.jobs);
  });
  tearDown(() => f.close());

  SongMetadata name(
    String title, {
    List<String> artists = const ['Mira Vale'],
  }) => SongMetadata(title: title, artists: artists);
  Future<ExportSnapshot> freeze() async {
    final job = await f.jobs.getJob(track.jobId);
    return f.jobs.freezeExport(job.id, job.revision);
  }

  test('open edit blocks freezing; cancellation retains metadata and releases the fence', () async {
    final session = await review.begin(track);
    await expectLater(freeze(), throwsA(isA<AppFailure>()));
    await review.cancel(session);
    expect(
      (await f.jobs.getTrack(track.id)).metadata.title,
      track.metadata.title,
    );
    await freeze();
    await expectLater(review.begin(track), throwsA(isA<AppFailure>()));
  });

  test('committed edits retain stable assets, protect changed fields and reject late AI', () async {
    final assets = await PipelineRepository(f.jobs).assets(track.jobId);
    final session = await review.begin(track);
    await review.commit(session, name('月光列車 (Live)'), const CoverEdit.keep());
    final saved = await f.jobs.getTrack(track.id);
    expect(saved.metadata.title, '月光列車 (Live)');
    expect(saved.sourceTitle, track.sourceTitle);
    expect(saved.overrides, {MetadataField.title});
    expect(
      (await PipelineRepository(f.jobs).assets(track.jobId)).map((a) => a.id),
      assets.map((a) => a.id),
    );
    expect(
      await f.jobs.applySuggestion(
        trackId: track.id,
        revision: track.revision,
        suggestion: name('Late AI'),
      ),
      isFalse,
    );
    expect(
      await f.jobs.applySuggestion(
        trackId: track.id,
        revision: saved.revision,
        suggestion: name('Another AI', artists: ['Jun Park']),
      ),
      isTrue,
    );
    final merged = await f.jobs.getTrack(track.id);
    expect(merged.metadata.title, '月光列車 (Live)');
    expect(merged.metadata.artists, ['Jun Park']);
  });

  test('conflicts retain candidate; explicit rebase updates only user-edited fields', () async {
    final session = await review.begin(track);
    await f.jobs.editMetadata(
      trackId: track.id,
      revision: track.revision,
      candidate: name(track.metadata.title, artists: ['New Artist']),
      fields: {MetadataField.artists},
    );
    final candidate = name('My title');
    await expectLater(
      review.commit(session, candidate, const CoverEdit.remove()),
      throwsA(
        isA<AppFailure>().having((e) => e.code, 'code', FailureCode.conflict),
      ),
    );
    expect(
      (await f.jobs.getTrack(track.id)).metadata.title,
      track.metadata.title,
    );
    final rebased = await review.rebase(session);
    await review.commit(rebased, candidate, const CoverEdit.remove());
    final saved = await f.jobs.getTrack(track.id);
    expect(saved.metadata.title, 'My title');
    expect(saved.metadata.artists, ['New Artist']);
  });

  test('image and metadata publication rolls back together on storage failure and retries', () async {
    final session = await review.begin(track), id = const Uuid().v4();
    final image = AssetRecord(
      id: id,
      jobId: track.jobId,
      trackId: track.id,
      kind: AssetKind.artwork,
      relativePath: PrivatePaths.asset(track.jobId, id, AssetKind.artwork),
      sha256: 'a' * 64,
      bytes: 100,
    );
    final cover = CoverEdit.import(Uint8List.fromList([1]));
    await f.db.execute(
      "CREATE TRIGGER reject_review BEFORE UPDATE ON tracks BEGIN SELECT RAISE(ABORT, 'fictional disk failure'); END",
    );
    await expectLater(
      review.commit(session, name('New title'), cover, imported: image),
      throwsA(isA<AppFailure>()),
    );
    expect(await f.db.query('assets', where: 'id=?', whereArgs: [id]), isEmpty);
    expect(
      (await f.jobs.getTrack(track.id)).metadata.title,
      track.metadata.title,
    );
    await f.db.execute('DROP TRIGGER reject_review');
    await review.commit(session, name('New title'), cover, imported: image);
    expect((await f.jobs.getTrack(track.id)).metadata.title, 'New title');
    expect((await f.db.query('enrichment')).single['artwork_override'], 1);
  });

  test('cancelled/stale tokens cannot publish a user image', () async {
    final session = await review.begin(track);
    await review.cancel(session);
    await expectLater(
      review.commit(session, name('Discarded'), const CoverEdit.remove()),
      throwsA(isA<AppFailure>()),
    );
    expect(
      (await f.jobs.getTrack(track.id)).metadata.title,
      track.metadata.title,
    );
  });

  test('restart releases pending editor tokens without creating a retryable media task', () async {
    final session = await review.begin(track);
    await f.jobs.recoverInterruptedAttempts();
    final attempts = await f.db.query(
      'attempts',
      where: 'id=?',
      whereArgs: [session.token.id],
    );
    expect(attempts.single['status'], 'cancelled');
    final saved = await f.jobs.getTrack(track.id);
    expect(saved.phase, TrackPhase.ready);
    expect(saved.revision, track.revision);
    await freeze();
  });
  test('pause fences an edit without leaving a retryable review that blocks later saves', () async {
    final session = await review.begin(track);
    await PipelineRepository(f.jobs).stop(track.jobId);
    expect(
      (await f.db.query(
        'attempts',
        where: 'id=?',
        whereArgs: [session.token.id],
      )).single['status'],
      'cancelled',
    );
    await expectLater(
      review.commit(session, name('Late text'), const CoverEdit.keep()),
      throwsA(isA<AppFailure>()),
    );
    var job = await f.jobs.getJob(track.jobId);
    for (final phase in [
      JobPhase.enumerating,
      JobPhase.processing,
      JobPhase.reviewReady,
    ]) {
      job = await f.jobs.transition(job.id, job.revision, phase);
    }
    expect((await f.jobs.getTrack(track.id)).phase, TrackPhase.ready);
    await freeze();
  });

  test('track selections and unresolved entry exclusions persist across database reopen', () async {
    await f.db.insert('playlist_entries', {
      'id': const Uuid().v4(),
      'job_id': track.jobId,
      'position': 2,
      'source_title': 'Unavailable',
      'error_code': 'sourceUnavailable',
    });
    await expectLater(freeze(), throwsA(isA<AppFailure>()));
    await review.selectEntry(await f.jobs.getJob(track.jobId), 2, false);
    await review.selectTrack(track, false);
    final second = await LocalDatabase.open(
      databaseFactoryFfi,
      f.workspace.databasePath,
    );
    try {
      final jobs = JobRepository(second);
      expect((await jobs.getTrack(track.id)).selected, isFalse);
      expect((await jobs.listEntries(track.jobId)).last.selected, isFalse);
      expect((await jobs.listEntries(track.jobId)).last.title, 'Unavailable');
    } finally {
      await second.close();
    }
    track = await f.jobs.getTrack(track.id);
    await review.selectTrack(track, true);
    await freeze();
  });

  test(
    'selection rejects a stale revision and cannot change a frozen review',
    () async {
      await review.selectTrack(track, false);
      await expectLater(
        review.selectTrack(track, true),
        throwsA(isA<AppFailure>()),
      );
      track = await f.jobs.getTrack(track.id);
      await review.selectTrack(track, true);
      track = await f.jobs.getTrack(track.id);
      await freeze();
      await expectLater(
        review.selectTrack(track, false),
        throwsA(isA<AppFailure>()),
      );
    },
  );

  test(
    'filename preview bounds UTF-8 bytes without truncating semantic metadata',
    () {
      final value = name('界' * 160);
      expect(
        utf8.encode(filenamePreview(value)).length,
        lessThanOrEqualTo(184),
      );
      expect(value.title, '界' * 160);
      expect(filenamePreview(name('A/B: test')), 'A_B_ test - Mira Vale.mp3');
      expect(
        filenamePreview(
          SongMetadata(title: 'Verse only', artists: [], needsReview: true),
        ),
        'Verse only - Unknown Artist.mp3',
      );
    },
  );
}
