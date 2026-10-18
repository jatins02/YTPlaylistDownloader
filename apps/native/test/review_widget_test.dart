import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yt_playlist_downloader/application/processing_controller.dart';
import 'package:yt_playlist_downloader/data/review_repository.dart';
import 'package:yt_playlist_downloader/domain/failure.dart';
import 'package:yt_playlist_downloader/domain/models.dart';
import 'package:yt_playlist_downloader/domain/playlist_url.dart';
import 'package:yt_playlist_downloader/domain/review.dart';
import 'package:yt_playlist_downloader/platform/media_port.dart';
import 'package:yt_playlist_downloader/platform/snippet_port.dart';
import 'package:yt_playlist_downloader/ui/processing_screen.dart';
import 'package:yt_playlist_downloader/ui/review_editor.dart';
import 'package:yt_playlist_downloader/ui/snippet_player_bar.dart';
import 'package:yt_playlist_downloader/ui/theme.dart';

import 'test_support.dart';

void main() {
  testWidgets(
    'review recovers when local audio starts and capability checks recover',
    (tester) async {
      final f = (await tester.runAsync(Fixture.open))!;
      final job = (await tester.runAsync(f.draft))!;
      await tester.runAsync(() async {
        await f.ready(await f.track(job));
        await f.review(job);
      });
      final port = ReviewWidgetPort(f)..outputAvailable = false;
      final state = ProcessingController(
        jobId: job.id,
        jobs: f.jobs,
        media: port,
      );
      try {
        await tester.runAsync(state.initialize);
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme,
            home: ProcessingScreen(controller: state),
          ),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byKey(const Key('review-play-1')),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        VoidCallback? playAction() => tester
            .widget<OutlinedButton>(find.byKey(const Key('review-play-1')))
            .onPressed;
        expect(playAction(), isNull);
        port.outputAvailable = true;
        await tester.runAsync(() => state.refresh(force: true));
        await tester.pumpAndSettle();
        expect(playAction(), isNotNull);
        port.capabilityError = StateError('private native diagnostic');
        await tester.runAsync(() => state.refresh(force: true));
        await tester.pumpAndSettle();
        expect(playAction(), isNull);
        expect(state.job!.id, job.id);
        expect(
          state.failure!.message,
          isNot(contains('private native diagnostic')),
        );
        port.capabilityError = null;
        await tester.runAsync(() => state.refresh(force: true));
        await tester.pumpAndSettle();
        expect(playAction(), isNotNull);
        expect(state.failure, isNull);
        port.outputAvailable = false;
        await tester.runAsync(() => state.refresh(force: true));
        await tester.pumpAndSettle();
        expect(playAction(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
        await tester.runAsync(f.close);
      }
    },
  );

  testWidgets('player controls wait for export, processing and cancellation', (
    tester,
  ) async {
    final f = (await tester.runAsync(Fixture.open))!;
    final job = (await tester.runAsync(f.draft))!;
    await tester.runAsync(() async {
      await f.ready(await f.track(job));
      await f.review(job);
    });
    final state = ProcessingController(
      jobId: job.id,
      jobs: f.jobs,
      media: ReviewWidgetPort(f),
    );
    await tester.runAsync(state.initialize);
    final track = state.tracks.single;
    await tester.runAsync(() => state.player.toggle(track.id));
    Future<void> render() => tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(body: SnippetPlayerBar(controller: state)),
      ),
    );
    await render();
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (w) =>
                  w is IconButton &&
                  w.tooltip == 'Pause ${track.metadata.songTitle}',
            ),
          )
          .onPressed,
      isNotNull,
    );
    for (final operation in ['export', 'processing', 'cancellation']) {
      state.exportBusy = operation == 'export';
      state.commanding = operation == 'processing';
      state.cancelling = operation == 'cancellation';
      await render();
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (w) =>
                    w is IconButton &&
                    w.tooltip == 'Pause ${track.metadata.songTitle}',
              ),
            )
            .onPressed,
        isNull,
        reason: operation,
      );
      expect(
        tester.widget<Slider>(find.byType(Slider)).onChanged,
        isNull,
        reason: operation,
      );
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == 'Stop snippet',
              ),
            )
            .onPressed,
        isNotNull,
      );
    }
    state.exportBusy = state.commanding = state.cancelling = false;
    await tester.runAsync(() => state.player.pause(clear: true));
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    await tester.runAsync(f.close);
  });
  setUpAll(() async {
    if (Platform.environment['STAGE5_SCREENSHOTS'] == null) return;
    final sdk = Platform.environment['FLUTTER_ROOT'];
    for (final font in [
      ('Roboto', 'Roboto-Regular.ttf'),
      ('MaterialIcons', 'MaterialIcons-Regular.otf'),
    ]) {
      final loader = FontLoader(font.$1)
        ..addFont(
          Future.value(
            ByteData.sublistView(
              await File('$sdk/bin/cache/artifacts/material_fonts/${font.$2}')
                  .readAsBytes(),
            ),
          ),
        );
      await loader.load();
    }
  });
  for (final size in [
    const Size(320, 720),
    const Size(390, 844),
    const Size(844, 390),
    const Size(768, 1024),
    const Size(1024, 768),
    const Size(1440, 900),
  ]) {
    testWidgets(
      'real review and editor fit ${size.width} at 200% text and keyboard insets',
      (tester) async {
        final fixture = (await tester.runAsync(Fixture.open))!;
        final job = (await tester.runAsync(fixture.draft))!;
        late TrackRecord track;
        await tester.runAsync(() async {
          track = await fixture.ready(await fixture.track(job));
          track = await fixture.jobs.editMetadata(
            trackId: track.id,
            revision: track.revision,
            candidate: SongMetadata(
              title: '夜の電車 — Étoiles ' * 20,
              artists: ['Mira Vale'],
            ),
            fields: {MetadataField.title},
          );
          await fixture.review(job);
        });
        final port = ReviewWidgetPort(fixture),
            state = ProcessingController(
              jobId: job.id,
              jobs: fixture.jobs,
              media: port,
            );
        await tester.runAsync(state.initialize);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
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
        await tester.scrollUntilVisible(
          find.byKey(const Key('review-edit-1')),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.byKey(const Key('review-edit-1')));
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => tester.tap(find.byKey(const Key('review-edit-1'))),
        );
        await waitForUi(
          tester,
          () => find.byType(ReviewEditor).evaluate().isNotEmpty,
        );
        expect(find.byType(ReviewEditor), findsOneWidget);
        expect(state.reviewBlockedReason, contains('open edit'));
        await tester.enterText(
          find.byKey(const Key('review-title')),
          '夜の電車 — Étoiles (Live)',
        );
        tester.view.viewInsets = const FakeViewPadding(bottom: 160);
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Étoiles (Live) - Mira Vale.mp3'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.runAsync(() => tester.tap(find.text('Cancel')));
        await waitForUi(
          tester,
          () =>
              !state.editing &&
              find.byType(ReviewEditor).evaluate().isEmpty &&
              Focus.of(tester.element(find.text('Edit track'))).hasFocus,
        );
        expect(
          (await tester.runAsync(() => fixture.jobs.getTrack(track.id)))!
              .metadata
              .title,
          track.metadata.title,
        );
        expect(
          Focus.of(tester.element(find.text('Edit track'))).hasFocus,
          isTrue,
        );
        tester.view.resetViewInsets();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(fixture.close);
      },
    );
  }

  testWidgets(
    'failed save retains text; explicit retry persists metadata and cover removal',
    (tester) async {
      final f = (await tester.runAsync(Fixture.open))!;
      // Each widget case uses its own durable, fictional job.
      final draft = (await tester.runAsync(f.draft))!;
      late TrackRecord track;
      await tester.runAsync(() async {
        track = await f.ready(await f.track(draft));
        await f.review(draft);
      });
      final port = ReviewWidgetPort(f)..failSave = true,
          state = ProcessingController(
            jobId: draft.id,
            jobs: f.jobs,
            media: port,
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
        find.byKey(const Key('review-edit-1')),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.byKey(const Key('review-edit-1')));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => tester.tap(find.byKey(const Key('review-edit-1'))),
      );
      await waitForUi(
        tester,
        () => find.byType(ReviewEditor).evaluate().isNotEmpty,
      );
      await tester.enterText(
        find.byKey(const Key('review-title')),
        'Saved user title',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('remove-review-cover')));
      await tester.tap(find.byKey(const Key('remove-review-cover')));
      await tester.tap(find.byKey(const Key('save-review-edit')));
      await tester.pumpAndSettle();
      expect(find.text('Review fixture failure'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('review-title')))
            .controller!
            .text,
        'Saved user title',
      );
      expect(state.editing, isTrue);
      port.failSave = false;
      await tester.runAsync(
        () => tester.tap(find.byKey(const Key('save-review-edit'))),
      );
      await waitForUi(
        tester,
        () => find.byType(ReviewEditor).evaluate().isEmpty,
      );
      expect(find.byType(ReviewEditor), findsNothing);
      final saved = (await tester.runAsync(() => f.jobs.getTrack(track.id)))!;
      expect(saved.metadata.title, 'Saved user title');
      expect(state.editing, isFalse);
      expect(port.lastCover, CoverAction.remove);
      final button = find.widgetWithText(FilledButton, 'Save to Device');
      await tester.scrollUntilVisible(
        button,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(f.close);
    },
  );

  final screenshots = Platform.environment['STAGE5_SCREENSHOTS'];
  testWidgets(
    'stale editor retains text and explicit rebase preserves untouched newer fields',
    (tester) async {
      final f = (await tester.runAsync(Fixture.open))!;
      final job = (await tester.runAsync(f.draft))!;
      late TrackRecord track;
      await tester.runAsync(() async {
        track = await f.ready(await f.track(job));
        await f.review(job);
      });
      final state = ProcessingController(
        jobId: job.id,
        jobs: f.jobs,
        media: ReviewWidgetPort(f),
      );
      await tester.runAsync(state.initialize);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme,
          home: ProcessingScreen(controller: state),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byKey(const Key('review-edit-1'));
      await tester.scrollUntilVisible(
        button,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(button));
      await waitForUi(
        tester,
        () => find.byType(ReviewEditor).evaluate().isNotEmpty,
      );
      await tester.enterText(
        find.byKey(const Key('review-title')),
        'My retained title',
      );
      await tester.runAsync(
        () => f.jobs.editMetadata(
          trackId: track.id,
          revision: track.revision,
          candidate: SongMetadata(
            title: track.metadata.title,
            artists: ['Newer Artist'],
          ),
          fields: {MetadataField.artists},
        ),
      );
      await tester.runAsync(
        () => tester.tap(find.byKey(const Key('save-review-edit'))),
      );
      await waitForUi(
        tester,
        () => find.byKey(const Key('review-save-error')).evaluate().isNotEmpty,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('review-title')))
            .controller!
            .text,
        'My retained title',
      );
      final rebase = find.text('Apply my edited fields to the latest revision');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.ensureVisible(rebase);
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(rebase));
      await waitForUi(tester, () => rebase.evaluate().isEmpty);
      await tester.runAsync(
        () => tester.tap(find.byKey(const Key('save-review-edit'))),
      );
      await waitForUi(
        tester,
        () => find.byType(ReviewEditor).evaluate().isEmpty,
      );
      expect(find.byType(ReviewEditor), findsNothing);
      final saved = (await tester.runAsync(() => f.jobs.getTrack(track.id)))!;
      expect(saved.metadata.title, 'My retained title');
      expect(saved.metadata.artists, ['Newer Artist']);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(f.close);
    },
  );
  if (screenshots != null) {
    testWidgets('review screen visual evidence', (tester) async {
      final directory = screenshots;
      final f = (await tester.runAsync(Fixture.open))!;
      final draft = (await tester.runAsync(f.draft))!;
      await tester.runAsync(() async {
        await f.ready(await f.track(draft));
        await f.review(draft);
      });
      final state = ProcessingController(
        jobId: draft.id,
        jobs: f.jobs,
        media: ReviewWidgetPort(f),
      );
      await tester.runAsync(state.initialize);
      tester.view.physicalSize = const Size(1024, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: appTheme,
            home: ProcessingScreen(controller: state),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('review-edit-1')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('review-edit-1')));
      await tester.pumpAndSettle();
      Future<void> screenshot(String filename) async => tester.runAsync(
        () async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(directory).create(recursive: true);
          await File('$directory/$filename.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        },
      );
      await screenshot('review-desktop');
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('review-edit-1')));
      await tester.pumpAndSettle();
      await screenshot('review-phone');
      await tester.runAsync(
        () => tester.tap(find.byKey(const Key('review-edit-1'))),
      );
      await waitForUi(
        tester,
        () => find.byType(ReviewEditor).evaluate().isNotEmpty,
      );
      await screenshot('editor-phone');
      await tester.runAsync(() => tester.tap(find.text('Cancel')));
      await waitForUi(tester, () => !state.editing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(f.close);
    });
  }

  testWidgets(
    'lifecycle suspension stops the current snippet without autoplay on resume',
    (tester) async {
      final f = (await tester.runAsync(Fixture.open))!;
      final job = (await tester.runAsync(f.draft))!;
      late TrackRecord track;
      await tester.runAsync(() async {
        track = await f.ready(await f.track(job));
        await f.review(job);
      });
      final port = ReviewWidgetPort(f),
          state = ProcessingController(
            jobId: job.id,
            jobs: f.jobs,
            media: port,
          );
      await tester.runAsync(state.initialize);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme,
          home: ProcessingScreen(controller: state),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() => state.player.toggle(track.id));
      expect(state.player.playing, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      expect(state.player.playing, isFalse);
      expect(port.playback, isNull);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(state.player.playing, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(f.close);
    },
  );

  testWidgets(
    'cover chooser cancellation preserves edits and the existing cover choice',
    (tester) async {
      final f = (await tester.runAsync(Fixture.open))!;
      final job = (await tester.runAsync(f.draft))!;
      late TrackRecord track;
      await tester.runAsync(() async {
        track = await f.ready(await f.track(job));
        await f.review(job);
      });
      final state = ProcessingController(
        jobId: job.id,
        jobs: f.jobs,
        media: ReviewWidgetPort(f),
      );
      await tester.runAsync(state.initialize);
      final session = (await tester.runAsync(() => state.beginEdit(track)))!;
      var chooserCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => ReviewEditor(
                    controller: state,
                    session: session,
                    pickImage: () async {
                      chooserCalls++;
                      return null;
                    },
                  ),
                ),
                child: const Text('Open editor'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open editor'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('review-title')),
        'Retained text',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('choose-review-cover')));
      await tester.pumpAndSettle();
      for (
        var attempt = 0;
        attempt < 8 &&
            find
                .byKey(const Key('choose-review-cover'))
                .hitTestable()
                .evaluate()
                .isEmpty;
        attempt++
      ) {
        final scroll = find
            .ancestor(
              of: find.byKey(const Key('choose-review-cover')),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.drag(scroll, const Offset(0, -200));
        await tester.pumpAndSettle();
      }
      expect(
        find.byKey(const Key('choose-review-cover')).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('choose-review-cover')));
      await tester.pumpAndSettle();
      expect(chooserCalls, 1);
      expect(
        find.textContaining('Keep the current cover choice'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('review-title')))
            .controller!
            .text,
        'Retained text',
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => state.endEdit(session));
      expect(
        (await tester.runAsync(() => f.jobs.getTrack(track.id)))!
            .metadata
            .title,
        track.metadata.title,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      await tester.runAsync(f.close);
    },
  );
}

final class ReviewWidgetPort implements MediaPort, ReviewMediaPort {
  ReviewWidgetPort(this.fixture);
  final Fixture fixture;
  bool failSave = false, outputAvailable = true;
  Object? capabilityError;
  CoverAction? lastCover;
  Completer<void>? playback;
  @override
  Future<MediaCapabilities> capabilities() async {
    if (capabilityError != null) throw capabilityError!;
    return MediaCapabilities(
      platform: DevicePlatform.linux,
      canPlaySnippets: outputAvailable,
      canAcquire: true,
      canImportArtwork: true,
    );
  }

  @override
  Future<void> acquire({
    required PlaylistUrl playlist,
    required String jobId,
  }) async {}
  @override
  Future<void> cancel(String jobId) async {}
  @override
  Future<void> export(ExportSnapshot snapshot) async => throw const AppFailure(
    FailureCode.mediaUnavailable,
    'Stage 6 is unavailable.',
  );
  @override
  Future<Map<String, Uint8List>> reviewCovers(
    String jobId,
    String trackId,
  ) async => {};
  @override
  Future<void> saveReview(
    ReviewSession session,
    SongMetadata candidate,
    CoverEdit cover,
  ) async {
    lastCover = cover.action;
    if (failSave) {
      throw const AppFailure(
        FailureCode.storageUnavailable,
        'Review fixture failure',
      );
    }
    await ReviewRepository(fixture.jobs).commit(session, candidate, cover);
  }

  @override
  Future<void> playSnippet(
    String jobId,
    String trackId,
    Duration position,
    void Function(SnippetProgress) progress,
  ) {
    playback = Completer<void>();
    progress(
      SnippetProgress(
        'preview-$trackId',
        position,
        const Duration(seconds: 30),
      ),
    );
    return playback!.future;
  }

  @override
  Future<void> stopSnippet() async {
    playback?.complete();
    playback = null;
  }
}

// Real SQLite/file futures run outside FakeAsync. Wait for their observable UI
// result rather than assuming a fixed disk latency under concurrent test load.
Future<void> waitForUi(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 250; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    if (ready()) return;
  }
  fail('The review action did not reach its expected UI state.');
}
