import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yt_playlist_downloader/application/drafts_controller.dart';
import 'package:yt_playlist_downloader/ui/foundation_app.dart';

import 'test_support.dart';

void main() {
  late Fixture fixture;
  late DraftsController controller;
  setUp(() async {
    fixture = await Fixture.open();
    controller = DraftsController(
      jobs: fixture.jobs,
      workspace: fixture.workspace,
      vault: MemoryVault(),
    );
    await controller.load();
  });
  tearDown(() async {
    controller.dispose();
    await fixture.close();
  });

  testWidgets('the visible save-draft action persists a canonical playlist', (
    tester,
  ) async {
    await tester.pumpWidget(FoundationApp(controller: controller));
    await tester.enterText(
      find.byKey(const Key('playlist-input')),
      'https://music.youtube.com/playlist?list=PL1234567890&si=ignored',
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('save-draft')));
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (controller.savingDraft && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    expect(controller.drafts, hasLength(1));
    expect(
      controller.drafts.single.sourceUrl,
      'https://www.youtube.com/playlist?list=PL1234567890',
    );
    expect(find.text('Playlist draft saved on this device.'), findsOneWidget);
    expect(
      find.text(
        'Downloads and previews are not enabled in this foundation build.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('invalid input has a visible error and creates no draft', (
    tester,
  ) async {
    await tester.pumpWidget(FoundationApp(controller: controller));
    await tester.enterText(
      find.byKey(const Key('playlist-input')),
      'not a playlist',
    );
    await tester.tap(find.byKey(const Key('save-draft')));
    await tester.pumpAndSettle();
    expect(controller.drafts, isEmpty);
    expect(
      find.textContaining('Enter an HTTPS YouTube playlist link'),
      findsOneWidget,
    );
  });

  testWidgets(
    'demo route leaves durable drafts and personal key state untouched',
    (tester) async {
      await tester.pumpWidget(FoundationApp(controller: controller));
      await tester.scrollUntilVisible(
        find.byKey(const Key('open-fixture-journey')),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('open-fixture-journey')));
      await tester.pumpAndSettle();
      expect(find.text('Fictional demo · Stage 2'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const Key('start-demo')),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.byKey(const Key('start-demo')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('start-demo')));
      await tester.pump();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Playlist drafts'), findsOneWidget);
      expect(controller.drafts, isEmpty);
      expect(await tester.runAsync(fixture.jobs.listJobs), isEmpty);
      expect(controller.hasKey, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow layout and large text keep draft/settings controls usable',
    (tester) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 720),
              textScaler: TextScaler.linear(2),
            ),
            child: DraftsScreen(controller: controller, recoveredAttempts: 0),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.byKey(const Key('save-draft')), 150);
      expect(find.byKey(const Key('save-draft')), findsOneWidget);
      await tester.tap(find.byTooltip('AI key settings'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('groq-key-input')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
