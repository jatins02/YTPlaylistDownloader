import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yt_playlist_downloader/application/app_runtime.dart';
import 'package:yt_playlist_downloader/application/processing_controller.dart';
import 'package:yt_playlist_downloader/domain/failure.dart';
import 'package:yt_playlist_downloader/main.dart';
import 'package:yt_playlist_downloader/ui/processing_screen.dart';
import 'package:yt_playlist_downloader/ui/review_editor.dart';
import 'package:yt_playlist_downloader/ui/theme.dart';
import 'package:yt_playlist_downloader/ui/workspace_components.dart';

import 'export_widget_test.dart' show ExportWidgetPort;
import 'review_widget_test.dart' show ReviewWidgetPort, waitForUi;
import 'test_support.dart';

Future<void> guidelines(WidgetTester tester) async {
  await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
  await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
  await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
  await expectLater(tester, meetsGuideline(textContrastGuideline));
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets('startup honors the actual reduced-motion platform preference', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final pending = Completer<AppRuntime>();
    await tester.pumpWidget(RuntimeHost(openRuntime: () => pending.future));
    await tester.pumpAndSettle();
    expect(find.byType(WorkspaceProgress), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.binding.hasScheduledFrame, isFalse);
    pending.completeError(
      const AppFailure(
        FailureCode.storageUnavailable,
        'Synthetic startup interruption',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('reduced motion keeps unknown progress static and labeled', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: const Scaffold(
              body: Column(
                children: [
                  WorkspaceProgress(label: 'Loading playlist'),
                  WorkspaceProgress(
                    label: 'Saving verified files',
                    linear: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.bySemanticsLabel('Loading playlist'), findsOneWidget);
      expect(find.bySemanticsLabel('Saving verified files'), findsOneWidget);
      expect(tester.binding.hasScheduledFrame, isFalse);
    } finally {
      semantics.dispose();
    }
  });

  for (final size in [const Size(390, 844), const Size(844, 390)]) {
    testWidgets('real review keyboard, semantics and rotation at $size', (
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
      final semantics = tester.ensureSemantics();
      try {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                disableAnimations: true,
                textScaler: const TextScaler.linear(2),
              ),
              child: child!,
            ),
            home: ProcessingScreen(controller: state),
          ),
        );
        await tester.pumpAndSettle();
        final edit = find.byKey(const Key('review-edit-1'));
        await tester.scrollUntilVisible(
          edit,
          180,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(edit);
        await tester.pumpAndSettle();
        await guidelines(tester);

        expect(
          find.bySemanticsLabel(
            RegExp(
              'Moonlit Train.*Edit track|Edit track.*Moonlit Train',
              dotAll: true,
            ),
          ),
          findsWidgets,
        );
        tester.widget<OutlinedButton>(edit).focusNode!.requestFocus();
        await tester.pump();
        await tester.runAsync(
          () => tester.sendKeyEvent(LogicalKeyboardKey.enter),
        );
        await waitForUi(
          tester,
          () => find.byType(ReviewEditor).evaluate().isNotEmpty,
        );
        final route =
            ModalRoute.of(tester.element(find.byType(ReviewEditor)))!
                as TransitionRoute<void>;
        expect(route.transitionDuration, Duration.zero);
        await tester.enterText(
          find.byKey(const Key('review-title')),
          'Unsaved orientation edit',
        );
        tester.view.physicalSize = Size(size.height, size.width);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('review-title')))
              .controller!
              .text,
          'Unsaved orientation edit',
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await waitForUi(
          tester,
          () => !state.editing && find.byType(ReviewEditor).evaluate().isEmpty,
        );
        expect(
          (await tester.runAsync(() => f.jobs.listTracks(job.id)))!
              .single
              .metadata
              .title,
          'Moonlit Train',
        );
        await tester.pumpAndSettle();
        expect(tester.widget<OutlinedButton>(edit).focusNode!.hasFocus, isTrue);
        const descent = [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
          AppLifecycleState.detached,
        ];
        for (var depth = 1; depth <= descent.length; depth++) {
          final path = descent.take(depth).toList();
          await tester.runAsync(
            () => state.player.toggle(state.tracks.single.id),
          );
          expect(state.player.playing, isTrue);
          await tester.pump();
          expect(
            find.bySemanticsLabel('Seek snippet for Moonlit Train'),
            findsWidgets,
          );
          for (final lifecycle in path) {
            tester.binding.handleAppLifecycleStateChanged(lifecycle);
          }
          // Hidden/paused views do not schedule frames. Flush the callbacks
          // once, then resume before waiting for the visible UI to settle.
          await tester.pump();
          expect(state.player.playing, isFalse);
          if (path.last != AppLifecycleState.detached) {
            for (final lifecycle in path.reversed.skip(1)) {
              tester.binding.handleAppLifecycleStateChanged(lifecycle);
            }
          }
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await waitForUi(
            tester,
            () => (state.media as ReviewWidgetPort).playback == null,
          );
          expect(
            state.player.playing,
            isFalse,
            reason: 'No autoplay after ${path.last}',
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(f.close);
      } finally {
        semantics.dispose();
      }
    });
  }

  testWidgets('verified save actions have labels, targets and contrast', (
    tester,
  ) async {
    final f = (await tester.runAsync(Fixture.open))!;
    final job = (await tester.runAsync(f.draft))!;
    final media = ExportWidgetPort(f);
    await tester.runAsync(() async {
      await f.ready(await f.track(job));
      await f.review(job);
      await media.prepareExport(job.id, (await f.jobs.getJob(job.id)).revision);
    });
    final state = ProcessingController(
      jobId: job.id,
      jobs: f.jobs,
      media: media,
    );
    await tester.runAsync(state.initialize);
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme,
          home: ProcessingScreen(controller: state),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('return-to-review')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await guidelines(tester);
      expect(
        find.bySemanticsLabel(RegExp('.*Save MP3.*|.*mp3.*')),
        findsWidgets,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(f.close);
    } finally {
      semantics.dispose();
    }
  });
}
