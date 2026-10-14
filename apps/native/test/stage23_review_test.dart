import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:yt_playlist_downloader/application/processing_controller.dart';
import 'package:yt_playlist_downloader/data/private_workspace.dart';
import 'package:yt_playlist_downloader/domain/failure.dart';
import 'package:yt_playlist_downloader/domain/models.dart';
import 'package:yt_playlist_downloader/domain/playlist_url.dart';
import 'package:yt_playlist_downloader/platform/media_port.dart';
import 'package:yt_playlist_downloader/ui/processing_screen.dart';

import 'test_support.dart';

void main() {
  late Fixture fixture;
  setUp(() async => fixture = await Fixture.open());
  tearDown(() async => fixture.close());
  final invalidTransition = isA<AppFailure>().having(
    (error) => error.code,
    'code',
    FailureCode.invalidTransition,
  );

  test(
    'legacy state writes cannot declare ready with audio but no snippet',
    () async {
      final job = await fixture.draft();
      var track = await fixture.track(job);
      final token = await fixture.jobs.beginAttempt(
        jobId: job.id,
        trackId: track.id,
        stage: TaskStage.conversion,
      );
      final id = const Uuid().v4();
      await fixture.jobs.registerAsset(
        AssetRecord(
          id: id,
          jobId: job.id,
          trackId: track.id,
          kind: AssetKind.audio,
          relativePath: PrivatePaths.asset(job.id, id, AssetKind.audio),
          sha256: List.filled(64, 'a').join(),
          bytes: 100,
        ),
        attempt: token,
      );
      for (final phase in [TrackPhase.downloading, TrackPhase.converting]) {
        await fixture.jobs.setTrackState(track.id, track.revision, phase);
        track = await fixture.jobs.getTrack(track.id);
      }
      await expectLater(
        fixture.jobs.setTrackState(track.id, track.revision, TrackPhase.ready),
        throwsA(invalidTransition),
      );
      expect(
        (await fixture.jobs.getTrack(track.id)).phase,
        TrackPhase.converting,
      );
    },
  );

  test(
    'enrichment recovery cannot fabricate readiness when a snippet is missing',
    () async {
      final job = await fixture.draft();
      final ready = await fixture.ready(await fixture.track(job));
      await fixture.jobs.beginAttempt(
        jobId: job.id,
        trackId: ready.id,
        stage: TaskStage.enrichment,
      );
      await fixture.db.delete(
        'assets',
        where: 'kind = ?',
        whereArgs: ['preview'],
      );
      await fixture.jobs.recoverInterruptedAttempts();
      expect((await fixture.jobs.getTrack(ready.id)).phase, TrackPhase.queued);
    },
  );

  test(
    'legacy import retains each duplicate occurrence source title',
    () async {
      final job = await fixture.draft();
      final track = await fixture.track(job);
      await fixture.jobs.addSourceTrack(
        jobId: job.id,
        position: 2,
        videoId: track.videoId,
        sourceTitle: 'Second occurrence title',
      );
      final snapshot = await fixture.jobs.processingSnapshot(job.id);
      expect(snapshot.$3.map((entry) => entry.title), [
        'Original source title',
        'Second occurrence title',
      ]);
      expect(snapshot.$3.map((entry) => entry.trackId).toSet(), {track.id});
    },
  );

  test('pre-v4 entries recover their linked original title without altering metadata', () async {
    final job = await fixture.draft();
    final track = await fixture.track(job);
    await fixture.db.update(
      'playlist_entries',
      {'source_title': null},
      where: 'job_id = ?',
      whereArgs: [job.id],
    );
    await fixture.jobs.editMetadata(
      trackId: track.id,
      revision: track.revision,
      candidate: SongMetadata(title: 'New human title', artists: ['Mira Vale']),
      fields: {MetadataField.title},
    );
    expect(
      (await fixture.jobs.processingSnapshot(job.id)).$3.single.title,
      'Original source title',
    );
    expect(
      (await fixture.jobs.listEntries(job.id)).single.title,
      'Original source title',
    );
  });

  test('exportReady jobs reject fresh media attempts', () async {
    final job = await fixture.draft();
    final ready = await fixture.ready(await fixture.track(job));
    await fixture.db.update(
      'jobs',
      {'phase': 'exportReady'},
      where: 'id = ?',
      whereArgs: [job.id],
    );
    await expectLater(
      fixture.jobs.beginAttempt(
        jobId: job.id,
        trackId: ready.id,
        stage: TaskStage.enrichment,
      ),
      throwsA(invalidTransition),
    );
  });

  test(
    'restart releases an export frozen before its worker was created',
    () async {
      final job = await fixture.draft();
      final ready = await fixture.ready(await fixture.track(job));
      final review = await fixture.review(job);
      final frozen = await fixture.jobs.freezeExport(job.id, review.revision);
      expect(await fixture.jobs.recoverInterruptedAttempts(), 1);
      final recovered = await fixture.jobs.getJob(job.id);
      expect(recovered.phase, JobPhase.reviewReady);
      expect((await fixture.jobs.getTrack(ready.id)).phase, TrackPhase.ready);
      final exports = await fixture.db.query(
        'exports',
        where: 'id = ?',
        whereArgs: [frozen.id],
      );
      expect(exports.single['status'], 'failed');
      expect(
        (await fixture.jobs.freezeExport(job.id, recovered.revision)).id,
        isNot(frozen.id),
      );
    },
  );

  test(
    'restart queues a processing job that has no surviving running attempt',
    () async {
      final job = await fixture.draft();
      final track = await fixture.track(job);
      await fixture.db.update(
        'jobs',
        {'phase': 'processing'},
        where: 'id = ?',
        whereArgs: [job.id],
      );
      await fixture.db.update(
        'tracks',
        {'phase': 'converting'},
        where: 'id = ?',
        whereArgs: [track.id],
      );
      expect(await fixture.jobs.recoverInterruptedAttempts(), 1);
      expect((await fixture.jobs.getJob(job.id)).phase, JobPhase.queued);
      expect((await fixture.jobs.getTrack(track.id)).phase, TrackPhase.queued);
      expect(await fixture.jobs.recoverInterruptedAttempts(), 0);
    },
  );

  test('old nonexport tokens cannot checkpoint a frozen job', () async {
    final job = await fixture.draft();
    final track = await fixture.track(job);
    final token = await fixture.jobs.beginAttempt(
      jobId: job.id,
      trackId: track.id,
      stage: TaskStage.conversion,
    );
    // Simulate stale historical state; enforce fencing even if an old writer
    // survives a phase change made by a different repository API.
    await fixture.db.update(
      'jobs',
      {'phase': 'exporting'},
      where: 'id = ?',
      whereArgs: [job.id],
    );
    await expectLater(
      fixture.jobs.saveCheckpoint(
        token,
        Checkpoint(step: CheckpointStep.converted),
      ),
      throwsA(
        isA<AppFailure>().having((e) => e.code, 'code', FailureCode.conflict),
      ),
    );
  });

  test('paused queued jobs are not shown as actively processing', () async {
    final job = await fixture.draft();
    await fixture.jobs.transition(job.id, job.revision, JobPhase.queued);
    final state = ProcessingController(
      jobId: job.id,
      jobs: fixture.jobs,
      media: const UnavailableMediaPort(DevicePlatform.linux),
    );
    try {
      await state.initialize();
      expect(state.processing, isFalse);
      await Future.wait(List.generate(5, (_) => state.refresh(force: true)));
      expect(state.job!.phase, JobPhase.queued);
    } finally {
      state.dispose();
    }
  });

  test(
    'unexpected stop failures remain visible and release command state',
    () async {
      final job = await fixture.draft();
      final state = ProcessingController(
        jobId: job.id,
        jobs: fixture.jobs,
        media: StopFailurePort(),
      );
      try {
        await state.initialize();
        await state.cancel();
        expect(state.failure!.code, FailureCode.storageUnavailable);
        expect(state.failure!.message, isNot(contains('private diagnostic')));
        expect(state.cancelling, isFalse);
        await state.pause();
        expect(state.failure!.code, FailureCode.storageUnavailable);
        expect(state.cancelling, isFalse);
      } finally {
        state.dispose();
      }
    },
  );

  test(
    'pause during a queued retry prevents a worker from starting afterward',
    () async {
      final job = await fixture.draft();
      await fixture.track(job);
      await fixture.review(job);
      final port = StopFailurePort();
      final state = ProcessingController(
        jobId: job.id,
        jobs: fixture.jobs,
        media: port,
      );
      final entered = Completer<void>(), release = Completer<void>();
      try {
        await state.initialize();
        final lock = fixture.db.transaction((tx) async {
          entered.complete();
          await release.future;
        });
        await entered.future;
        final starting = state.start(retryFailed: true);
        final pausing = state.pause();
        release.complete();
        await lock;
        await Future.wait([starting, pausing]);
        expect(port.acquisitions, 0);
        expect(state.commanding, isFalse);
        expect(state.cancelling, isFalse);
      } finally {
        if (!release.isCompleted) release.complete();
        state.dispose();
      }
    },
  );

  testWidgets(
    'missing jobs show a recoverable error instead of an endless spinner',
    (tester) async {
      final state = ProcessingController(
        jobId: const Uuid().v4(),
        jobs: fixture.jobs,
        media: const UnavailableMediaPort(DevicePlatform.linux),
      );
      await tester.runAsync(state.initialize);
      await tester.pumpWidget(
        MaterialApp(home: ProcessingScreen(controller: state)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Playlist draft not found.'), findsOneWidget);
      expect(find.text('Retry loading playlist'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a duplicate occurrence error stays visible beside a ready shared track',
    (tester) async {
      final job = (await tester.runAsync(fixture.draft))!;
      final track = (await tester.runAsync(() => fixture.track(job)))!;
      await tester.runAsync(() async {
        await fixture.jobs.addSourceTrack(
          jobId: job.id,
          position: 2,
          videoId: track.videoId,
          sourceTitle: 'Unsupported occurrence',
        );
        await fixture.ready(track);
        await fixture.db.update(
          'playlist_entries',
          {'error_code': 'liveUnsupported'},
          where: 'job_id = ? AND position = 2',
          whereArgs: [job.id],
        );
      });
      final state = ProcessingController(
        jobId: job.id,
        jobs: fixture.jobs,
        media: const UnavailableMediaPort(DevicePlatform.linux),
      );
      await tester.runAsync(state.initialize);
      await tester.pumpWidget(
        MaterialApp(home: ProcessingScreen(controller: state)),
      );
      await tester.pumpAndSettle();
      final message = find.text(
        'Live, upcoming or overlong sources are not supported by this build.',
      );
      await tester.scrollUntilVisible(
        message,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(message, findsOneWidget);
      expect(state.readyCount, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

final class StopFailurePort implements ManagedMediaPort {
  int acquisitions = 0;
  @override
  Future<MediaCapabilities> capabilities() async =>
      const MediaCapabilities(platform: DevicePlatform.linux, canAcquire: true);
  @override
  Future<void> cancel(String jobId) async =>
      throw StateError('private diagnostic');
  @override
  Future<void> pause(String jobId) async =>
      throw StateError('private diagnostic');
  @override
  Future<void> acquire({
    required PlaylistUrl playlist,
    required String jobId,
  }) async {
    acquisitions++;
  }

  @override
  Future<void> discardPrivateMedia(String jobId) async {}
  @override
  Future<void> export(ExportSnapshot snapshot) async {}
  @override
  Future<void> close() async {}
}
