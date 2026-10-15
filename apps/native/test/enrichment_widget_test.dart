import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yt_playlist_downloader/application/processing_controller.dart';
import 'package:yt_playlist_downloader/data/enrichment_repository.dart';
import 'package:yt_playlist_downloader/domain/enrichment.dart';
import 'package:yt_playlist_downloader/domain/failure.dart';
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
      'metadata failures and visible retry fit ${size.width} at 200% text',
      (tester) async {
        final fixture = (await tester.runAsync(Fixture.open))!;
        final job = (await tester.runAsync(fixture.draft))!;
        await tester.runAsync(() async {
          final track = await fixture.ready(await fixture.track(job));
          await fixture.review(job);
          final store = EnrichmentRepository(fixture.jobs),
              ticket = await store.begin(track.id);
          await store.naming(
            ticket,
            EnrichmentOptions(),
            failure: FailureCode.aiRateLimited,
          );
          await store.artwork(
            ticket,
            (await fixture.jobs.getTrack(track.id)).revision,
            failure: FailureCode.artworkUncertain,
          );
          await store.finish(ticket);
        });
        final port = WidgetMetadataPort();
        final state = ProcessingController(
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
          find.byKey(const Key('enrich-tracks')),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('enrich-tracks')))
              .onPressed,
          isNotNull,
        );
        await tester.scrollUntilVisible(
          find.textContaining('No unique recording'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.textContaining('provider quota'), findsOneWidget);
        expect(find.textContaining('Names need review'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(fixture.close);
      },
    );
  }
  testWidgets(
    'failed settings save retains model text and never enables final save',
    (tester) async {
      final fixture = (await tester.runAsync(Fixture.open))!,
          port = WidgetMetadataPort()..failSave = true;
      final job = (await tester.runAsync(fixture.draft))!;
      await tester.runAsync(() async {
        await fixture.ready(await fixture.track(job));
        await fixture.review(job);
      });
      final state = ProcessingController(
        jobId: job.id,
        jobs: fixture.jobs,
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
        find.byKey(const Key('metadata-options')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.byKey(const Key('metadata-options')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('metadata-options')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Groq model ID'),
        'openai/gpt-oss-20b',
      );
      await tester.tap(find.text('Save settings'));
      await tester.pumpAndSettle();
      expect(find.text('Settings fixture failure'), findsOneWidget);
      expect(find.text('openai/gpt-oss-20b'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(state.capability!.canExport, isFalse);
      expect(find.text('Save to Device'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.close);
    },
  );
  testWidgets(
    'unexpected settings read failure is visible without leaking diagnostics',
    (tester) async {
      final fixture = (await tester.runAsync(Fixture.open))!;
      final job = (await tester.runAsync(fixture.draft))!;
      await tester.runAsync(() async {
        await fixture.ready(await fixture.track(job));
        await fixture.review(job);
      });
      final state = ProcessingController(
        jobId: job.id,
        jobs: fixture.jobs,
        media: WidgetMetadataPort()..failRead = true,
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
        find.byKey(const Key('metadata-options')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.byKey(const Key('metadata-options')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('metadata-options')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Settings could not be loaded'),
        findsOneWidget,
      );
      expect(find.textContaining('private diagnostic'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.close);
    },
  );
}

final class WidgetMetadataPort implements EnrichingMediaPort {
  bool failSave = false, failRead = false;
  @override
  Future<MediaCapabilities> capabilities() async => const MediaCapabilities(
    platform: DevicePlatform.linux,
    canAcquire: true,
    canEnrich: true,
    canTag: true,
  );
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
    'Device save is unavailable.',
  );
  @override
  Future<Uint8List?> coverBytes(String jobId, String assetId) async => null;
  @override
  Future<void> enrich(String jobId, {bool retry = true}) async {}
  @override
  Future<EnrichmentOptions> metadataOptions() async {
    if (failRead) throw StateError('private diagnostic');
    return EnrichmentOptions();
  }

  @override
  Future<void> saveMetadataOptions(EnrichmentOptions options) async {
    if (failSave) {
      throw const AppFailure(
        FailureCode.storageUnavailable,
        'Settings fixture failure',
      );
    }
  }
}
