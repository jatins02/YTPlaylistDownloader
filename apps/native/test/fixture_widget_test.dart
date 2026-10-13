import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yt_playlist_downloader/application/fixture_journey.dart';
import 'package:yt_playlist_downloader/ui/fixture_screen.dart';
import 'package:yt_playlist_downloader/ui/theme.dart';

import 'fixture_test_support.dart';

const previewBoundary = Key('stage2-render');

Future<void> mount(
  WidgetTester tester,
  FixtureJourney journey, {
  Size size = const Size(1024, 900),
  double scale = 1,
  double keyboard = 0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      theme: const bool.fromEnvironment('STAGE2_PREVIEWS')
          ? appTheme.copyWith(
              textTheme: appTheme.textTheme.apply(
                fontFamilyFallback: ['Stage2CJK'],
              ),
            )
          : appTheme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: true,
          viewInsets: EdgeInsets.only(bottom: keyboard),
        ),
        child: RepaintBoundary(key: previewBoundary, child: child!),
      ),
      home: FixtureScreen(journey: journey),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> reveal(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty) {
    // A viewport resize can leave a desired row above the current lazy range.
    // Begin at the top so this helper can reveal rows in either direction.
    tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .jumpTo(0);
    await tester.pump();
    await tester.scrollUntilVisible(
      target,
      200,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 100,
    );
  }
  await tester.ensureVisible(target);
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> click(WidgetTester tester, String key) async {
  final target = find.byKey(Key(key));
  await reveal(tester, target);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(target);
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> renderPreview(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('STAGE2_PREVIEWS')) return;
  await tester.pump(const Duration(milliseconds: 400));
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(previewBoundary),
    );
    final image = await boundary.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final directory = Directory('build/stage2-previews')
        ..createSync(recursive: true);
      await File('${directory.path}/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(() async {
    // Opt-in evidence uses the SDK's bundled font, never a new dependency or
    // a network font. Default behavior tests retain deterministic test fonts.
    if (const bool.fromEnvironment('STAGE2_PREVIEWS')) {
      final sdk = Platform.environment['FLUTTER_ROOT'];
      final file = File(
        '$sdk/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
      );
      final loader = FontLoader('Roboto')
        ..addFont(Future.value(ByteData.sublistView(await file.readAsBytes())));
      await loader.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          Future.value(
            ByteData.sublistView(
              await File(
                '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
              ).readAsBytes(),
            ),
          ),
        );
      await icons.load();
      final cjkPath = Platform.environment['STAGE2_CJK_FONT'];
      if (cjkPath != null) {
        final cjk = FontLoader('Stage2CJK')
          ..addFont(
            Future.value(
              ByteData.sublistView(await File(cjkPath).readAsBytes()),
            ),
          );
        await cjk.load();
      }
    }
  });

  testWidgets('visible import to progress to review to final save journey', (
    tester,
  ) async {
    final journey = FixtureJourney();
    addTearDown(journey.dispose);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester, journey);
    expect(find.text('Fictional demo · Stage 2'), findsOneWidget);
    await click(tester, 'start-demo');
    expect(find.text('Reading the demo playlist'), findsOneWidget);
    await click(tester, 'next-demo-step');
    for (var i = 0; i < 5; i++) {
      await click(tester, 'next-demo-step');
    }
    expect(find.text('Make it yours'), findsOneWidget);
    await click(tester, 'select-unavailable');
    expect(journey.selectedCount, 4);
    await click(tester, 'demo-save-device');
    expect(find.text('Confirm your demo save'), findsOneWidget);
    expect(
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .pixels,
      0,
    );
    await click(tester, 'finish-demo-save');
    expect(find.text('Demo journey complete'), findsOneWidget);
    expect(
      find.text('Simulation completed; no device download'),
      findsOneWidget,
    );
    await click(tester, 'return-to-review');
    expect(journey.selectedCount, 4);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'edit validation and failure retain text, explicit save wins, cancel discards',
    (tester) async {
      final journey = reviewed(FixtureScenario.complete);
      addTearDown(journey.dispose);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester, journey);
      await click(tester, 'edit-moonlit-a');
      await tester.enterText(find.byKey(const Key('edit-title')), '');
      await click(tester, 'commit-edit');
      expect(journey.editingId, 'moonlit-a');
      await tester.enterText(find.byKey(const Key('edit-title')), 'A new name');
      await tester.pump();
      expect(find.textContaining('A new name - Mira Vale'), findsOneWidget);
      journey.configureFailures(edits: true, saves: false);
      await click(tester, 'commit-edit');
      expect(find.textContaining('Your text is preserved'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('edit-title')))
            .controller!
            .text,
        'A new name',
      );
      journey.configureFailures(edits: false, saves: false);
      await click(tester, 'commit-edit');
      expect(journey.track('moonlit-a').metadata.title, 'A new name');
      await click(tester, 'edit-moonlit-a');
      await tester.enterText(
        find.byKey(const Key('edit-title')),
        'Discard this',
      );
      await click(tester, 'cancel-edit');
      expect(journey.track('moonlit-a').metadata.title, 'A new name');
    },
  );

  testWidgets(
    'keyboard focus enters editor and Escape returns to initiating button',
    (tester) async {
      final journey = reviewed(FixtureScenario.complete);
      addTearDown(journey.dispose);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester, journey);
      final edit = find.byKey(const Key('edit-moonlit-a'));
      await reveal(tester, edit);
      // Reach a visible button through actual traversal rather than requesting
      // focus programmatically; activate it through the keyboard.
      for (var i = 0; i < 30; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final button = FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<OutlinedButton>();
        if (button?.key == const Key('edit-moonlit-a')) break;
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('edit-title')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('edit-title')),
        'Discard on escape',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(journey.editingId, isNull);
      expect(journey.track('moonlit-a').metadata.title, 'Moonlit Train');
      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<OutlinedButton>()
            ?.key,
        const Key('edit-moonlit-a'),
      );
    },
  );

  testWidgets('screen-reader labels and measured accessibility guidelines', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final journey = reviewed();
      addTearDown(journey.dispose);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester, journey, size: const Size(390, 844));
      await reveal(tester, find.byKey(const Key('selection-summary')));
      expect(
        tester
            .getSemantics(find.byKey(const Key('selection-summary')))
            .getSemanticsData()
            .flagsCollection
            .isLiveRegion,
        isTrue,
      );
      await reveal(tester, find.byKey(const Key('play-moonlit-a')));
      await tester.pump();
      expect(
        find.bySemanticsLabel(RegExp('Preview Moonlit Train')),
        findsWidgets,
      );
      expect(
        find.bySemanticsLabel(RegExp('Include Moonlit Train')),
        findsWidgets,
      );
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
    } finally {
      semantics.dispose();
    }
  });

  for (final size in [
    const Size(320, 720),
    const Size(390, 844),
    const Size(768, 1024),
    const Size(1024, 768),
    const Size(1440, 900),
    const Size(844, 390),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'all fixture states fit ${size.width.toInt()}x${size.height.toInt()} at ${scale}x text',
        (tester) async {
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final journey = FixtureJourney();
          addTearDown(journey.dispose);
          await mount(tester, journey, size: size, scale: scale);
          await reveal(tester, find.byKey(const Key('start-demo')));
          await tester.pump();
          expect(tester.takeException(), isNull);
          journey.start(demoLink);
          await tester.pump();
          expect(tester.takeException(), isNull);
          journey.advance();
          await tester.pump();
          expect(tester.takeException(), isNull);
          while (journey.phase == FixturePhase.processing) {
            journey.advance();
          }
          await tester.pump();
          await reveal(tester, find.byKey(const Key('edit-unicode')));
          await tester.pump();
          expect(tester.takeException(), isNull);
          await click(tester, 'edit-unicode');
          await reveal(tester, find.byKey(const Key('edit-album')));
          await tester.pump();
          expect(tester.takeException(), isNull);
          await click(tester, 'cancel-edit');
          journey.select('unavailable', false);
          await tester.pump();
          await click(tester, 'demo-save-device');
          await reveal(tester, find.byKey(const Key('finish-demo-save')));
          await tester.pump();
          expect(tester.takeException(), isNull);
          journey.finishSave();
          await tester.pump();
          expect(tester.takeException(), isNull);
          for (final scenario in [
            FixtureScenario.empty,
            FixtureScenario.expired,
            FixtureScenario.offline,
          ]) {
            journey.reset();
            journey.chooseScenario(scenario);
            journey.start(demoLink);
            journey.advance();
            await tester.pump();
            expect(tester.takeException(), isNull);
          }
        },
      );
    }
  }

  testWidgets('phone editor survives landscape keyboard insets and settings', (
    tester,
  ) async {
    final journey = reviewed();
    addTearDown(journey.dispose);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(
      tester,
      journey,
      size: const Size(844, 390),
      scale: 2,
      keyboard: 160,
    );
    await click(tester, 'edit-moonlit-a');
    await reveal(tester, find.byKey(const Key('edit-title')));
    await tester.enterText(
      find.byKey(const Key('edit-title')),
      'Keyboard-safe edit',
    );
    await click(tester, 'commit-edit');
    expect(journey.track('moonlit-a').metadata.title, 'Keyboard-safe edit');
    await tester.tap(find.byTooltip('Demo settings'));
    await tester.pumpAndSettle();
    final saveToggle = find.descendant(
      of: find.byKey(const Key('simulate-save-failure')),
      matching: find.byType(Checkbox),
    );
    await reveal(tester, saveToggle);
    await tester.tap(saveToggle);
    await tester.pump();
    expect(journey.simulateSaveFailure, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'preview gestures switch by stable ID and stop on app suspension',
    (tester) async {
      final journey = reviewed(FixtureScenario.complete);
      addTearDown(journey.dispose);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester, journey);
      await click(tester, 'play-moonlit-a');
      expect(journey.activeTrackId, 'moonlit-a');
      await click(tester, 'play-moonlit-b');
      expect(journey.activeTrackId, 'moonlit-b');
      await reveal(tester, find.byKey(const Key('demo-preview-seek')));
      await tester.pump();
      expect(find.text('Preview controls · silent simulation'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(journey.activeTrackId, isNull);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    },
  );

  if (const bool.fromEnvironment('STAGE2_PREVIEWS')) {
    testWidgets(
      'rendered evidence for phone, tablet, laptop, editor and error states',
      (tester) async {
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final journey = FixtureJourney();
        addTearDown(journey.dispose);
        await mount(tester, journey, size: const Size(390, 844));
        await renderPreview(tester, 'phone-import');
        journey.start(demoLink);
        journey.advance();
        journey.advance();
        await tester.pump();
        await renderPreview(tester, 'phone-progress');
        while (journey.phase == FixturePhase.processing) {
          journey.advance();
        }
        await tester.pump();
        await renderPreview(tester, 'phone-review');
        await reveal(tester, find.byKey(const Key('track-card-unicode')));
        await renderPreview(tester, 'phone-unicode-review');
        journey.togglePreview('unicode');
        await tester.pump();
        await reveal(tester, find.byKey(const Key('demo-player')));
        await renderPreview(tester, 'phone-player');
        journey.stopPreview();
        await mount(tester, journey, size: const Size(320, 720), scale: 2);
        await reveal(tester, find.byKey(const Key('track-card-moonlit-a')));
        await renderPreview(tester, 'phone-large-text');
        await mount(tester, journey, size: const Size(768, 1024));
        await renderPreview(tester, 'tablet-review');
        await mount(tester, journey, size: const Size(1440, 900));
        await renderPreview(tester, 'laptop-review');
        await mount(tester, journey, size: const Size(390, 844));
        await click(tester, 'edit-moonlit-a');
        await renderPreview(tester, 'phone-editor');
        expect(find.byKey(const Key('edit-title')), findsOneWidget);
        await click(tester, 'cancel-edit');
        await tester.pumpAndSettle();
        journey.select('unavailable', false);
        journey.beginSave(FixtureExportFormat.zip);
        await tester.pump();
        await renderPreview(tester, 'phone-save');
        journey.configureFailures(edits: false, saves: true);
        journey.finishSave();
        await tester.pump();
        await renderPreview(tester, 'phone-save-error');
        journey.configureFailures(edits: false, saves: false);
        journey.finishSave();
        await tester.pump();
        await renderPreview(tester, 'phone-complete');
        journey.reset();
        journey.chooseScenario(FixtureScenario.expired);
        journey.start(demoLink);
        journey.advance();
        await tester.pump();
        await renderPreview(tester, 'phone-expired');
        for (final scenario in [
          FixtureScenario.empty,
          FixtureScenario.offline,
        ]) {
          journey.reset();
          journey.chooseScenario(scenario);
          journey.start(demoLink);
          journey.advance();
          await tester.pump();
          await renderPreview(tester, 'phone-${scenario.name}');
        }
      },
    );
  }

  test(
    'palette text and control tokens exceed documented contrast targets',
    () {
      double ratio(Color a, Color b) {
        final first = a.computeLuminance(), second = b.computeLuminance();
        return first > second
            ? (first + .05) / (second + .05)
            : (second + .05) / (first + .05);
      }

      for (final text in [ink, mutedInk, errorInk]) {
        for (final surface in [
          Colors.white,
          blush,
          surfaceMuted,
          surfaceHover,
        ]) {
          expect(ratio(text, surface), greaterThanOrEqualTo(4.5));
        }
      }
      for (final control in [controlBorder, focus]) {
        expect(ratio(control, Colors.white), greaterThanOrEqualTo(3));
        expect(ratio(control, blush), greaterThanOrEqualTo(3));
      }
    },
  );
}
