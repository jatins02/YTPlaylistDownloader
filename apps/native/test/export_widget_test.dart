import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:path/path.dart' as p;
import 'package:yt_playlist_downloader/application/processing_controller.dart';
import 'package:yt_playlist_downloader/data/export_repository.dart';
import 'package:yt_playlist_downloader/domain/device_export.dart';
import 'package:yt_playlist_downloader/domain/failure.dart';
import 'package:yt_playlist_downloader/domain/models.dart';
import 'package:yt_playlist_downloader/domain/playlist_url.dart';
import 'package:yt_playlist_downloader/platform/export_port.dart';
import 'package:yt_playlist_downloader/platform/media_port.dart';
import 'package:yt_playlist_downloader/ui/processing_screen.dart';
import 'package:yt_playlist_downloader/ui/theme.dart';

import 'test_support.dart';

Future<void> until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 250; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    if (done()) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('Expected save action did not finish.');
}

void main() {
  setUpAll(() async {
    if (Platform.environment['STAGE6_SCREENSHOTS'] == null) return;
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
      'verified export fits ${size.width} with large text and keyboard insets',
      (tester) async {
        final fixture = (await tester.runAsync(Fixture.open))!;
        final job = (await tester.runAsync(fixture.draft))!;
        final media = ExportWidgetPort(fixture);
        await tester.runAsync(() async {
          await fixture.ready(await fixture.track(job));
          await fixture.review(job);
          await media.prepareExport(
            job.id,
            (await fixture.jobs.getJob(job.id)).revision,
          );
        });
        final state = ProcessingController(
          jobId: job.id,
          jobs: fixture.jobs,
          media: media,
        );
        await tester.runAsync(state.initialize);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.view.viewInsets = const FakeViewPadding(bottom: 160);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
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
        final button = find.byKey(const Key('save-export-zip'));
        await tester.scrollUntilVisible(
          button,
          220,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(button);
        await tester.pumpAndSettle();
        expect(button.hitTestable(), findsOneWidget);
        await tester.runAsync(() => tester.tap(button));
        await until(tester, () => !state.exportBusy);
        expect(state.saveMessage, contains('cancelled'));
        expect(state.savedCopy, isNull);
        final back = find.byKey(const Key('return-to-review'));
        await tester.scrollUntilVisible(
          back,
          220,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(back);
        await tester.pumpAndSettle();
        await tester.runAsync(() => tester.tap(back));
        await until(tester, () => state.job?.phase == JobPhase.reviewReady);
        expect(state.publication, isNull);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(fixture.close);
      },
    );
  }
  testWidgets(
    'no success appears while saving or after denial; retry uses the same publication',
    (tester) async {
      final fixture = (await tester.runAsync(Fixture.open))!;
      final job = (await tester.runAsync(fixture.draft))!;
      await tester.runAsync(() async {
        await fixture.ready(await fixture.track(job));
        await fixture.review(job);
      });
      final port = ExportWidgetPort(fixture);
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
      final prepare = find.byKey(const Key('prepare-device-export'));
      await tester.scrollUntilVisible(
        prepare,
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(prepare);
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(prepare));
      await until(tester, () => !state.exportBusy);
      final publication = state.publication!;
      final save = find.byKey(const Key('save-export-zip'));
      await tester.scrollUntilVisible(
        save,
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      port.gate = Completer<void>();
      port.deny = true;
      await tester.runAsync(() => tester.tap(save));
      await tester.pump();
      expect(state.exportBusy, isTrue);
      expect(state.savedCopy, isNull);
      expect(find.textContaining('Saved verified copy:'), findsNothing);
      await tester.runAsync(() async {
        port.gate!.complete();
      });
      await until(tester, () => !state.exportBusy);
      expect(state.failure!.code, FailureCode.destinationUnavailable);
      expect(state.publication!.snapshot.id, publication.snapshot.id);
      expect(find.textContaining('Saved verified copy:'), findsNothing);
      port.gate = null;
      port.deny = false;
      port.cancelPicker = false;
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(save));
      await until(tester, () => !state.exportBusy);
      expect(state.saveMessage, contains('Saved verified copy:'));
      expect(state.savedCopy, isNotNull);
      expect(
        await tester.runAsync(() => fixture.db.query('exports')),
        hasLength(1),
      );
      expect(port.prepareCalls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.close);
    },
  );
  testWidgets(
    'pending review edits disable final preparation even with export capability',
    (tester) async {
      final fixture = (await tester.runAsync(Fixture.open))!;
      final job = (await tester.runAsync(fixture.draft))!;
      final track = (await tester.runAsync(() async {
        final t = await fixture.ready(await fixture.track(job));
        await fixture.review(job);
        return t;
      }))!;
      final state = ProcessingController(
        jobId: job.id,
        jobs: fixture.jobs,
        media: ExportWidgetPort(fixture),
      );
      await tester.runAsync(state.initialize);
      final edit = (await tester.runAsync(() => state.beginEdit(track)))!;
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme,
          home: ProcessingScreen(controller: state),
        ),
      );
      await tester.pumpAndSettle();
      final prepare = find.byKey(const Key('prepare-device-export'));
      await tester.scrollUntilVisible(
        prepare,
        240,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.widget<FilledButton>(prepare).onPressed, isNull);
      expect(state.reviewBlockedReason, contains('open edit'));
      await tester.runAsync(() => state.endEdit(edit));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(prepare).onPressed, isNotNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.close);
    },
  );
  testWidgets('prepared files do not enable an unverified export runtime', (
    tester,
  ) async {
    final fixture = (await tester.runAsync(Fixture.open))!;
    final job = (await tester.runAsync(fixture.draft))!;
    final port = ExportWidgetPort(fixture, exportAvailable: false);
    await tester.runAsync(() async {
      await fixture.ready(await fixture.track(job));
      await fixture.review(job);
      await port.prepareExport(
        job.id,
        (await fixture.jobs.getJob(job.id)).revision,
      );
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
    final button = find.byKey(const Key('save-export-zip'));
    await tester.scrollUntilVisible(
      button,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    expect(state.savedCopy, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(fixture.close);
  });
  final screenshots = Platform.environment['STAGE6_SCREENSHOTS'];
  if (screenshots != null) {
    testWidgets('verified export screen renders', (tester) async {
      final fixture = (await tester.runAsync(Fixture.open))!;
      final job = (await tester.runAsync(fixture.draft))!;
      final media = ExportWidgetPort(
        fixture,
        filename: 'Étoiles (Live) - Mira Vale - Jun Park.mp3',
      );
      await tester.runAsync(() async {
        final track = await fixture.ready(await fixture.track(job));
        await fixture.jobs.editMetadata(
          trackId: track.id,
          revision: track.revision,
          candidate: SongMetadata(
            title: 'Étoiles',
            artists: ['Mira Vale'],
            featuredArtists: ['Jun Park'],
            version: 'Live',
          ),
          fields: {
            MetadataField.title,
            MetadataField.featuredArtists,
            MetadataField.version,
          },
        );
        await fixture.review(job);
        await media.prepareExport(
          job.id,
          (await fixture.jobs.getJob(job.id)).revision,
        );
      });
      final state = ProcessingController(
        jobId: job.id,
        jobs: fixture.jobs,
        media: media,
      );
      await tester.runAsync(state.initialize);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final boundary = GlobalKey();
      for (final entry in [
        ('export-desktop', const Size(1024, 1040)),
        ('export-phone', const Size(390, 844)),
      ]) {
        tester.view.physicalSize = entry.$2;
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: appTheme,
              home: ProcessingScreen(controller: state),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byKey(const Key('return-to-review')),
          240,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage(),
              bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(screenshots).create(recursive: true);
          await File('$screenshots/${entry.$1}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.close);
    });
  }
}

/// Widget-only state boundary. Codec, archive and destination bytes have separate native tests.
final class ExportWidgetPort implements ExportMediaPort {
  ExportWidgetPort(
    this.fixture, {
    this.filename = '夜の電車 — Étoiles (Live) - Mira Vale - Jun Park.mp3',
    this.exportAvailable = true,
  });
  final Fixture fixture;
  final String filename;
  final bool exportAvailable;
  bool cancelPicker = true, deny = false;
  int prepareCalls = 0;
  Completer<void>? gate;
  @override
  Future<MediaCapabilities> capabilities() async => MediaCapabilities(
    platform: DevicePlatform.linux,
    canAcquire: true,
    canConvert: true,
    canPrepareSnippets: true,
    canTag: true,
    canExport: exportAvailable,
  );
  @override
  Future<ExportPublication?> currentExport(String id) =>
      ExportRepository(fixture.jobs).current(id);
  @override
  Future<ExportPublication> prepareExport(String id, int revision) async {
    prepareCalls++;
    final snapshot = await fixture.jobs.freezeExport(id, revision);
    final publication = publicationFixture(snapshot, filenames: [filename]);
    final token = await fixture.jobs.beginAttempt(
      jobId: id,
      stage: TaskStage.export,
    );
    await ExportRepository(fixture.jobs).publish(token, publication);
    return publication;
  }

  @override
  Future<DeliveryReceipt?> deliverExport(
    ExportPublication publication,
    String fileId,
  ) async {
    await gate?.future;
    if (deny) {
      throw const AppFailure(
        FailureCode.destinationUnavailable,
        'Fictional permission denial. Your prepared files are kept.',
      );
    }
    if (cancelPicker) return null;
    final file = publication.files.singleWhere((f) => f.id == fileId),
        id = const Uuid().v4();
    final repo = ExportRepository(fixture.jobs);
    await repo.beginDelivery(
      publication,
      file,
      id: id,
      destination: p.join(fixture.root.path, 'fictional', file.filename),
      temporary: p.join(fixture.root.path, 'fictional', '.ytpd-$id.part'),
      device: 1,
      inode: 2,
    );
    await repo.finishDelivery(id);
    return DeliveryReceipt(id, publication.snapshot.id, file.id, file.filename);
  }

  @override
  Future<void> stopExport(String id) => ExportRepository(fixture.jobs).stop(id);
  @override
  Future<void> acquire({
    required PlaylistUrl playlist,
    required String jobId,
  }) async {}
  @override
  Future<void> cancel(String jobId) async {}
  @override
  Future<void> export(ExportSnapshot snapshot) async {}
}
