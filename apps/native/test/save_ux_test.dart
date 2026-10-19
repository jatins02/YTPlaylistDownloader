import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:yt_playlist_downloader/application/drafts_controller.dart';
import 'package:yt_playlist_downloader/application/processing_controller.dart';
import 'package:yt_playlist_downloader/data/export_repository.dart';
import 'package:yt_playlist_downloader/domain/device_export.dart';
import 'package:yt_playlist_downloader/domain/failure.dart';
import 'package:yt_playlist_downloader/domain/models.dart';
import 'package:yt_playlist_downloader/ui/foundation_app.dart';
import 'package:yt_playlist_downloader/ui/processing_screen.dart';
import 'package:yt_playlist_downloader/ui/theme.dart';

import 'export_widget_test.dart' show ExportWidgetPort, until;
import 'test_support.dart';

void main() {
  late Fixture f;
  setUp(() async => f = await Fixture.open());
  tearDown(() => f.close());

  Future<String> begin(ExportPublication publication, ExportFile file) async {
    final id = const Uuid().v4();
    await ExportRepository(f.jobs).beginDelivery(
      publication,
      file,
      id: id,
      destination: '${f.root.path}/chosen/${file.filename}',
      temporary: '${f.root.path}/chosen/.ytpd-$id.part',
      device: 1,
      inode: 2,
    );
    return id;
  }

  test('export-only placeholders retain source title, uncertainty, versions and human fields', () async {
    final job = await f.draft();
    final track = await f.jobs.addSourceTrack(
      jobId: job.id,
      position: 1,
      videoId: 'abcdefghijk',
      sourceTitle: 'Original Live recording',
      metadata: SongMetadata(
        title: 'Original Live recording',
        artists: [],
        featuredArtists: ['Jun Park'],
        version: 'Live',
        needsReview: true,
      ),
    );
    await f.ready(track);
    final review = await f.review(job);
    await expectLater(
      f.jobs.freezeExport(job.id, review.revision),
      throwsA(
        isA<AppFailure>().having(
          (e) => e.code,
          'code',
          FailureCode.invalidTransition,
        ),
      ),
    );
    final frozen = await f.jobs.freezeExport(
      job.id,
      review.revision,
      fillMissingMetadata: true,
    );
    final data = jsonDecode(frozen.json)['tracks'][0]['metadata'];
    expect(data['title'], 'Original Live recording');
    expect(data['artists'], ['-']);
    expect(data['featured_artists'], ['Jun Park']);
    expect(data['version'], 'Live');
    expect(data['needs_review'], isTrue);
    expect(data['album'], isNull);
    final retained = await f.jobs.getTrack(track.id);
    expect(retained.metadata.artists, isEmpty);
    expect(retained.metadata.needsReview, isTrue);
    expect(retained.overrides, isEmpty);
  });

  test('single MP3 receipt unlocks only remaining songs across snapshots and restart recovery', () async {
    final job = await f.draft();
    final a = await f.ready(await f.track(job));
    final b = await f.ready(
      await f.track(job, position: 2, videoId: '12345678901'),
    );
    final ready = await f.review(job);
    final publication = await publishFixture(
      f,
      await f.jobs.freezeExport(job.id, ready.revision),
    );
    final repository = ExportRepository(f.jobs);
    final id = await begin(
      publication,
      publication.tracks.singleWhere((t) => t.trackId == a.id),
    );
    expect(await repository.savedTrackIds(job.id), isEmpty);
    await expectLater(
      repository.reviewRemaining(
        job.id,
        (await f.jobs.getJob(job.id)).revision,
      ),
      throwsA(isA<AppFailure>()),
    );
    await repository.finishDelivery(id);
    await f.jobs.recoverInterruptedAttempts();
    expect(await ExportRepository(f.jobs).savedTrackIds(job.id), {a.id});
    await repository.reviewRemaining(
      job.id,
      (await f.jobs.getJob(job.id)).revision,
    );
    expect((await f.jobs.getTrack(a.id)).selected, isFalse);
    expect((await f.jobs.getTrack(b.id)).selected, isTrue);
    final next = await f.jobs.freezeExport(
      job.id,
      (await f.jobs.getJob(job.id)).revision,
    );
    expect(
      (jsonDecode(next.json)['tracks'] as List).map((t) => t['track_id']),
      [b.id],
    );
    final rest = await publishFixture(f, next);
    final zip = await begin(rest, rest.archive);
    await repository.finishDelivery(zip);
    expect(await repository.savedTrackIds(job.id), {a.id, b.id});
    await repository.reviewRemaining(
      job.id,
      (await f.jobs.getJob(job.id)).revision,
    );
    expect((await f.jobs.listTracks(job.id)).where((t) => t.selected), isEmpty);
  });

  test('failed/interrupted saves never disable songs and retry pruning retains completed history', () async {
    final job = await f.draft();
    final track = await f.ready(await f.track(job));
    final ready = await f.review(job);
    final publication = await publishFixture(
      f,
      await f.jobs.freezeExport(job.id, ready.revision),
    );
    final repository = ExportRepository(f.jobs);
    final interrupted = await begin(publication, publication.archive);
    await repository.fenceDeliveries(job.id);
    expect(await repository.savedTrackIds(job.id), isEmpty);
    await repository.stagingCleaned(interrupted);
    final completed = await begin(publication, publication.tracks.single);
    await repository.finishDelivery(completed);
    await repository.stagingCleaned(completed);
    await f.db.update(
      'export_deliveries',
      {'created_at': 1},
      where: 'id=?',
      whereArgs: [completed],
    );
    for (var i = 0; i < 105; i++) {
      final id = await begin(publication, publication.archive);
      await repository.finishDelivery(
        id,
        failure: FailureCode.destinationUnavailable,
      );
      await repository.stagingCleaned(id);
    }
    expect(await repository.savedTrackIds(job.id), {track.id});
    expect(
      (await f.db.query(
        'export_deliveries',
        where: 'id=?',
        whereArgs: [completed],
      )),
      hasLength(1),
    );
  });

  test('draft previews use original YouTube names in playlist order and remain bounded', () async {
    final job = await f.draft();
    for (var i = 0; i < 4; i++) {
      await f.jobs.addSourceTrack(
        jobId: job.id,
        position: i + 1,
        videoId: 'abcdefghij$i',
        sourceTitle: 'YouTube song $i',
        metadata: SongMetadata(title: 'Edited name $i', artists: ['Mira Vale']),
      );
    }
    final draft = (await f.jobs.listJobs()).single;
    expect(draft.sourceTitles, [
      'YouTube song 0',
      'YouTube song 1',
      'YouTube song 2',
    ]);
    expect(draft.createdAt, job.createdAt);
  });

  testWidgets(
    'save fallback is optional and downloaded songs remain disabled after reopening review',
    (tester) async {
      final job = (await tester.runAsync(f.draft))!;
      late TrackRecord first;
      late TrackRecord second;
      await tester.runAsync(() async {
        first = await f.ready(await f.track(job));
        second = await f.ready(
          await f.track(job, position: 2, videoId: '12345678901'),
        );
        await f.jobs.editMetadata(
          trackId: first.id,
          revision: first.revision,
          candidate: SongMetadata(
            title: first.sourceTitle,
            artists: [],
            needsReview: true,
          ),
          fields: {
            MetadataField.title,
            MetadataField.artists,
            MetadataField.needsReview,
          },
        );
        await f.review(job);
      });
      final port = ExportWidgetPort(f)..cancelPicker = false;
      final state = ProcessingController(
        jobId: job.id,
        jobs: f.jobs,
        media: port,
      );
      await tester.runAsync(state.initialize);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme,
          home: ProcessingScreen(controller: state),
        ),
      );
      await tester.pumpAndSettle();
      expect(state.canPrepareExport, isTrue);
      state.setFillMissingMetadata(false);
      expect(state.canPrepareExport, isFalse);
      state.setFillMissingMetadata(true);
      final prepare = find.byKey(const Key('prepare-device-export'));
      await tester.scrollUntilVisible(
        prepare,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(prepare);
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(prepare));
      await until(tester, () => !state.exportBusy);
      expect(state.failure, isNull);
      final save = find.byKey(Key('save-mp3-${first.id}'));
      await tester.scrollUntilVisible(
        save,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(save));
      await until(tester, () => !state.exportBusy);
      expect(state.savedTrackIds, {first.id});
      expect(tester.widget<OutlinedButton>(save).onPressed, isNull);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('save-export-zip')))
            .onPressed,
        isNull,
      );
      final back = find.byKey(const Key('return-to-review'));
      await tester.scrollUntilVisible(
        back,
        -220,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(back);
      await tester.pumpAndSettle();
      expect(find.text('Choose remaining songs (1)'), findsOneWidget);
      await tester.runAsync(() => tester.tap(back));
      await until(tester, () => state.job?.phase == JobPhase.reviewReady);
      expect(
        (await tester.runAsync(() => f.jobs.getTrack(second.id)))!.selected,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      // A fresh controller reconstructs download coverage from durable receipts.
      final reopened = ProcessingController(
        jobId: job.id,
        jobs: f.jobs,
        media: port,
      );
      await tester.runAsync(reopened.initialize);
      expect(reopened.savedTrackIds, {first.id});
      expect(reopened.selectedCount, 1);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme,
          home: ProcessingScreen(controller: reopened),
        ),
      );
      await tester.pumpAndSettle();
      final saved = find.widgetWithText(
        CheckboxListTile,
        'Downloaded · ${first.sourceTitle}',
      );
      await tester.scrollUntilVisible(
        saved,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.widget<CheckboxListTile>(saved).onChanged, isNull);
      expect(reopened.canPrepareExport, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'front page distinguishes drafts with local times and original song names',
    (tester) async {
      final job = (await tester.runAsync(f.draft))!;
      await tester.runAsync(() => f.track(job));
      final controller = DraftsController(
        jobs: f.jobs,
        workspace: f.workspace,
        vault: MemoryVault(),
      );
      await tester.runAsync(controller.load);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme,
          home: DraftsScreen(controller: controller, recoveredAttempts: 0),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Added '), findsOneWidget);
      expect(find.textContaining('Last activity '), findsOneWidget);
      expect(find.text('YouTube songs: Original source title'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );
}
