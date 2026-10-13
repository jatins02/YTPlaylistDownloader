import 'package:flutter_test/flutter_test.dart';
import 'package:yt_playlist_downloader/application/fixture_journey.dart';
import 'package:yt_playlist_downloader/domain/models.dart';

import 'fixture_test_support.dart';

void main() {
  test('confirmed metadata clears uncertainty without hiding failed-source warnings', () {
    final journey = reviewed();
    addTearDown(journey.dispose);
    final confirmed = SongMetadata(
      title: 'Paper Lanterns',
      artists: ['Mira Vale'],
      version: 'Slowed / reverbed',
    );
    for (final id in ['uncertain', 'unavailable']) {
      final initial = journey.beginEdit(id)!;
      expect(journey.commitEdit(id, initial.revision, confirmed), isNull);
    }
    expect(journey.track('uncertain').warning, isNull);
    expect(
      journey.track('unavailable').warning,
      contains('Source unavailable'),
    );
    expect(journey.saveBlockedReason, contains('exclude'));
  });
  test('invalid imports retain the import screen without creating tracks', () {
    final journey = FixtureJourney();
    addTearDown(journey.dispose);
    expect(
      journey.start('https://evil.example/playlist?list=PLfictionalDemo01'),
      isFalse,
    );
    expect(journey.error, isNotNull);
    expect(journey.phase, FixturePhase.import);
    expect(journey.tracks, isEmpty);
    expect(journey.start(demoLink), isTrue);
    expect(journey.error, isNull);
    expect(journey.phase, FixturePhase.loading);
  });

  test(
    'explicit preparation counts ordered unique fixtures and retains failures',
    () {
      final journey = reviewed();
      addTearDown(journey.dispose);
      expect(journey.phase, FixturePhase.review);
      expect(journey.tracks, hasLength(5));
      expect(journey.occurrenceCount, 6);
      expect(journey.completedCount, 5);
      expect(journey.failedCount, 1);
      expect(journey.selectedCount, 5);
      expect(journey.saveBlockedReason, contains('exclude'));
      expect(journey.beginSave(FixtureExportFormat.zip), isFalse);
      journey.select('unavailable', false);
      expect(journey.excludedCount, 1);
      expect(journey.saveBlockedReason, isNull);
      expect(() => journey.tracks.clear(), throwsUnsupportedError);
    },
  );

  test(
    'retry restores only the unavailable fixture; peers and IDs survive',
    () {
      final journey = reviewed();
      addTearDown(journey.dispose);
      final peer = journey.track('unicode');
      journey.retryTrack('unavailable');
      expect(journey.failedCount, 0);
      expect(journey.track('unicode'), same(peer));
      expect(journey.track('unavailable').warning, isNull);
      expect(journey.saveBlockedReason, isNull);
    },
  );

  test('no selection and pending edits block finalization', () {
    final journey = reviewed(FixtureScenario.complete);
    addTearDown(journey.dispose);
    for (final track in journey.tracks) {
      journey.select(track.id, false);
    }
    expect(journey.saveBlockedReason, contains('at least one'));
    journey.select('moonlit-a', true);
    final original = journey.beginEdit('moonlit-a')!;
    expect(journey.saveBlockedReason, contains('pending edits'));
    expect(journey.beginSave(FixtureExportFormat.zip), isFalse);
    journey.select('moonlit-a', false);
    expect(journey.track('moonlit-a'), same(original));
    journey.cancelEdit('moonlit-a');
    expect(journey.track('moonlit-a').metadata.title, 'Moonlit Train');
    expect(journey.saveBlockedReason, isNull);
  });

  test(
    'edits preserve original titles, identity, versions and explicit revisions',
    () {
      final journey = reviewed(FixtureScenario.complete);
      addTearDown(journey.dispose);
      final initial = journey.beginEdit('unicode')!;
      final edited = SongMetadata(
        title: 'Étoiles 夜',
        artists: ['Éloïse'],
        version: initial.metadata.version,
      );
      expect(
        journey.commitEdit(initial.id, initial.revision - 1, edited),
        contains('changed'),
      );
      expect(journey.track(initial.id), same(initial));
      expect(journey.commitEdit(initial.id, initial.revision, edited), isNull);
      final result = journey.track(initial.id);
      expect(result.id, initial.id);
      expect(result.originalTitle, initial.originalTitle);
      expect(result.metadata.displayName, 'Étoiles 夜 (Live) - Éloïse');
      expect(result.revision, initial.revision + 1);
      expect(journey.editingId, isNull);
    },
  );

  test('failed edit retains the active revision and can retry', () {
    final journey = reviewed(FixtureScenario.complete);
    addTearDown(journey.dispose);
    journey.configureFailures(edits: true, saves: false);
    final initial = journey.beginEdit('moonlit-a')!;
    final edited = SongMetadata(title: 'Renamed', artists: ['Mira Vale']);
    expect(
      journey.commitEdit(initial.id, initial.revision, edited),
      contains('preserved'),
    );
    expect(journey.editingId, initial.id);
    expect(journey.track(initial.id), same(initial));
    journey.configureFailures(edits: false, saves: false);
    expect(journey.commitEdit(initial.id, initial.revision, edited), isNull);
    expect(journey.track(initial.id).metadata.title, 'Renamed');
  });

  test('one silent preview at a time, bounded seek and edit/save stop it', () {
    final journey = reviewed(FixtureScenario.complete);
    addTearDown(journey.dispose);
    journey.togglePreview('moonlit-a');
    journey.seekPreview(17);
    journey.togglePreview('moonlit-b');
    expect(journey.activeTrackId, 'moonlit-b');
    expect(journey.previewSeconds, 0);
    journey.seekPreview(-4);
    expect(journey.previewSeconds, 0);
    journey.seekPreview(40);
    expect(journey.activeTrackId, isNull);
    expect(journey.previewSeconds, 30);
    journey.togglePreview('moonlit-a');
    journey.beginEdit('moonlit-a');
    expect(journey.activeTrackId, isNull);
    journey.cancelEdit('moonlit-a');
    journey.togglePreview('moonlit-a');
    journey.beginSave(FixtureExportFormat.zip);
    expect(journey.activeTrackId, isNull);
  });

  test('frozen save preview keeps equal-title recordings separate and rejects late changes', () {
    final journey = reviewed(FixtureScenario.complete);
    addTearDown(journey.dispose);
    expect(journey.beginSave(FixtureExportFormat.mp3), isTrue);
    final snapshot = journey.savePreview!;
    expect(snapshot.format, FixtureExportFormat.mp3);
    expect(snapshot.items, hasLength(5));
    expect(
      snapshot.items[0].filename,
      'Moonlit Train - Mira Vale - Jun Park.mp3',
    );
    expect(
      snapshot.items[1].filename,
      'Moonlit Train - Mira Vale - Jun Park (2).mp3',
    );
    expect(snapshot.items.map((i) => i.trackId).toSet(), hasLength(5));
    expect(snapshot.items[2].filename, contains('(Live)'));
    journey.select('moonlit-a', false);
    expect(journey.selectedCount, 5);
    expect(journey.beginEdit('moonlit-a'), isNull);
    expect(journey.beginSave(FixtureExportFormat.zip), isFalse);
    expect(journey.savePreview, same(snapshot));
    expect(() => snapshot.items.clear(), throwsUnsupportedError);
  });

  test(
    'denied demo save and cancellation preserve review, then retry succeeds',
    () {
      final journey = reviewed(FixtureScenario.complete);
      addTearDown(journey.dispose);
      journey.select('moonlit-b', false);
      journey.configureFailures(edits: false, saves: true);
      journey.beginSave(FixtureExportFormat.zip);
      journey.finishSave();
      expect(journey.phase, FixturePhase.saving);
      expect(journey.error, contains('denied'));
      journey.cancelSave();
      expect(journey.phase, FixturePhase.review);
      expect(journey.track('moonlit-b').selected, isFalse);
      expect(journey.savePreview, isNull);
      journey.configureFailures(edits: false, saves: false);
      journey.beginSave(FixtureExportFormat.zip);
      journey.finishSave();
      expect(journey.phase, FixturePhase.saved);
      expect(journey.error, isNull);
    },
  );

  test('empty, expiry and connection states have deterministic recovery', () {
    for (final entry in {
      FixtureScenario.empty: FixturePhase.review,
      FixtureScenario.expired: FixturePhase.expired,
      FixtureScenario.offline: FixturePhase.offline,
    }.entries) {
      final journey = reviewed(entry.key);
      expect(journey.phase, entry.value);
      if (entry.key == FixtureScenario.empty) expect(journey.tracks, isEmpty);
      if (entry.key == FixtureScenario.offline) {
        journey.retryConnection();
        expect(journey.phase, FixturePhase.processing);
        while (journey.phase == FixturePhase.processing) {
          journey.advance();
        }
        expect(journey.failedCount, 0);
      }
      journey.reset();
      expect(journey.phase, FixturePhase.import);
      expect(journey.tracks, isEmpty);
      expect(journey.error, isNull);
      journey.dispose();
    }
  });

  test('cancelled processing cannot advance or publish a save', () {
    final journey = FixtureJourney()..start(demoLink);
    addTearDown(journey.dispose);
    journey.advance();
    journey.advance();
    journey.cancelProcessing();
    journey.advance();
    expect(journey.phase, FixturePhase.cancelled);
    expect(journey.completedCount, 1);
    expect(journey.beginSave(FixtureExportFormat.zip), isFalse);
    journey.reset();
    expect(journey.start(demoLink), isTrue);
    expect(journey.completedCount, 0);
  });
}
