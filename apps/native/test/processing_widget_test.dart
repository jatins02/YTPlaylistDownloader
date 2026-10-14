import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yt_playlist_downloader/application/processing_controller.dart';
import 'package:yt_playlist_downloader/data/pipeline_repository.dart';
import 'package:yt_playlist_downloader/domain/failure.dart';
import 'package:yt_playlist_downloader/domain/media_models.dart';
import 'package:yt_playlist_downloader/domain/models.dart';
import 'package:yt_playlist_downloader/domain/playlist_url.dart';
import 'package:yt_playlist_downloader/platform/media_port.dart';
import 'package:yt_playlist_downloader/ui/processing_screen.dart';
import 'package:yt_playlist_downloader/ui/theme.dart';

import 'test_support.dart';

void main() {
  for (final size in [
    const Size(320, 720),
    const Size(844, 390),
    const Size(1440, 900),
  ]) {
    testWidgets(
      'real processing states fit ${size.width} at 200% text without fake export success',
      (tester) async {
        final fixture = (await tester.runAsync(Fixture.open))!;
        final job = (await tester.runAsync(fixture.draft))!;
        final state = ProcessingController(
          jobId: job.id,
          jobs: fixture.jobs,
          media: FailureFixturePort(fixture),
        );
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        await tester.runAsync(state.initialize);
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: ProcessingScreen(controller: state),
          ),
        );
        await tester.pumpAndSettle();
        final action = find.byKey(const Key('start-processing'));
        await tester.scrollUntilVisible(
          action,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(action);
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(action);
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (state.commanding && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        await tester.pumpAndSettle();
        expect(state.job!.phase, JobPhase.reviewReady);
        expect(state.failedCount, 1);
        expect(state.unmappedCount, 1);
        expect(state.entries, hasLength(3));
        await tester.scrollUntilVisible(
          find.textContaining('No files have been saved'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.textContaining('No files have been saved'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(fixture.close);
      },
    );
  }

  testWidgets(
    'unsupported phone media is visibly disabled and leaves the local draft intact',
    (tester) async {
      final fixture = (await tester.runAsync(Fixture.open))!;
      final job = (await tester.runAsync(fixture.draft))!;
      final state = ProcessingController(
        jobId: job.id,
        jobs: fixture.jobs,
        media: const UnavailableMediaPort(DevicePlatform.android),
      );
      await tester.runAsync(state.initialize);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme,
          home: ProcessingScreen(controller: state),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('start-processing')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('start-processing')))
            .onPressed,
        isNull,
      );
      expect(
        find.textContaining('not available on this platform'),
        findsOneWidget,
      );
      expect(
        (await tester.runAsync(() => fixture.jobs.getJob(job.id)))!.phase,
        JobPhase.draft,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.close);
    },
  );
}

/// UI/data behavior fixture only; deliberately creates failed rows, no audio.
final class FailureFixturePort implements MediaPort {
  FailureFixturePort(this.fixture);
  final Fixture fixture;
  @override
  Future<MediaCapabilities> capabilities() async =>
      const MediaCapabilities(platform: DevicePlatform.linux, canAcquire: true);
  @override
  Future<void> acquire({
    required PlaylistUrl playlist,
    required String jobId,
  }) async {
    var job = await fixture.jobs.getJob(jobId);
    job = await fixture.jobs.transition(jobId, job.revision, JobPhase.queued);
    job = await fixture.jobs.transition(
      jobId,
      job.revision,
      JobPhase.enumerating,
    );
    final token = await fixture.jobs.beginAttempt(
      jobId: jobId,
      stage: TaskStage.acquisition,
    );
    final store = PipelineRepository(fixture.jobs);
    await store.commitEnumeration(token, const [
      SourceEntry(
        position: 1,
        title: '夜 — a very long fictional source name',
        videoId: 'abcdefghijk',
      ),
      SourceEntry(
        position: 2,
        title: 'Repeated source',
        videoId: 'abcdefghijk',
      ),
      SourceEntry(
        position: 3,
        title: 'Unavailable identity',
        failure: FailureCode.sourceUnavailable,
      ),
    ], const PipelineLimits());
    job = await fixture.jobs.getJob(jobId);
    await fixture.jobs.transition(jobId, job.revision, JobPhase.processing);
    final track = (await fixture.jobs.listTracks(jobId)).single;
    final work = await fixture.jobs.beginAttempt(
      jobId: jobId,
      trackId: track.id,
      stage: TaskStage.conversion,
    );
    await store.trackPhase(
      work,
      TrackPhase.failed,
      failure: FailureCode.sourceUnavailable,
    );
    job = await fixture.jobs.getJob(jobId);
    await fixture.jobs.transition(jobId, job.revision, JobPhase.reviewReady);
  }

  @override
  Future<void> cancel(String jobId) =>
      PipelineRepository(fixture.jobs).stop(jobId, cancel: true);
  @override
  Future<void> export(ExportSnapshot snapshot) async => throw const AppFailure(
    FailureCode.mediaUnavailable,
    'No export in this fixture.',
  );
}
