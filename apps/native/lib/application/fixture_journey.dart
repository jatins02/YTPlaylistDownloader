import 'package:flutter/foundation.dart';

import '../domain/failure.dart';
import '../domain/models.dart';
import '../domain/playlist_url.dart';

/// Stage 2 interaction fixtures. Never writes jobs, assets, credentials or files.
enum FixturePhase {
  import,
  loading,
  processing,
  review,
  saving,
  saved,
  expired,
  offline,
  cancelled,
}

enum FixtureScenario { partial, complete, empty, expired, offline }

enum FixtureTrackState { waiting, ready, failed }

enum FixtureExportFormat { zip, mp3 }

extension FixtureScenarioLabel on FixtureScenario {
  String get label => switch (this) {
    FixtureScenario.partial => 'Partial success',
    FixtureScenario.complete => 'All tracks ready',
    FixtureScenario.empty => 'Empty playlist',
    FixtureScenario.expired => 'Expired draft',
    FixtureScenario.offline => 'Connection lost',
  };
}

@immutable
final class FixtureTrack {
  const FixtureTrack({
    required this.id,
    required this.originalTitle,
    required this.metadata,
    required this.durationSeconds,
    this.state = FixtureTrackState.waiting,
    this.selected = true,
    this.revision = 0,
    this.hasCover = false,
    this.occurrences = 1,
    this.warning,
  });
  final String id;
  final String originalTitle;
  final SongMetadata metadata;
  final int durationSeconds;
  final FixtureTrackState state;
  final bool selected;
  final int revision;
  final bool hasCover;
  final int occurrences;
  final String? warning;

  FixtureTrack copyWith({
    SongMetadata? metadata,
    FixtureTrackState? state,
    bool? selected,
    bool clearWarning = false,
  }) => FixtureTrack(
    id: id,
    originalTitle: originalTitle,
    metadata: metadata ?? this.metadata,
    durationSeconds: durationSeconds,
    state: state ?? this.state,
    selected: selected ?? this.selected,
    revision: revision + 1,
    hasCover: hasCover,
    occurrences: occurrences,
    warning: clearWarning ? null : warning,
  );
}

@immutable
final class FixtureSaveItem {
  const FixtureSaveItem(this.trackId, this.metadata, this.filename);
  final String trackId;
  final SongMetadata metadata;
  final String filename;
}

/// Immutable UI-only preview, deliberately distinct from ExportSnapshot.
@immutable
final class FixtureSavePreview {
  FixtureSavePreview(Iterable<FixtureSaveItem> items, this.format)
    : items = List.unmodifiable(items);
  final List<FixtureSaveItem> items;
  final FixtureExportFormat format;
}

final class FixtureJourney extends ChangeNotifier {
  FixturePhase _phase = FixturePhase.import;
  FixturePhase get phase => _phase;
  FixtureScenario _scenario = FixtureScenario.partial;
  FixtureScenario get scenario => _scenario;
  List<FixtureTrack> _tracks = const [];
  List<FixtureTrack> get tracks => _tracks;
  String? _error;
  String? get error => _error;
  String? _editingId;
  String? get editingId => _editingId;
  String? _activeTrackId;
  String? get activeTrackId => _activeTrackId;
  int _previewSeconds = 0;
  int get previewSeconds => _previewSeconds;
  FixtureSavePreview? _savePreview;
  FixtureSavePreview? get savePreview => _savePreview;
  bool _simulateEditFailure = false;
  bool get simulateEditFailure => _simulateEditFailure;
  bool _simulateSaveFailure = false;
  bool get simulateSaveFailure => _simulateSaveFailure;

  int get completedCount =>
      _tracks.where((t) => t.state != FixtureTrackState.waiting).length;
  int get failedCount =>
      _tracks.where((t) => t.state == FixtureTrackState.failed).length;
  int get selectedCount => _tracks.where((t) => t.selected).length;
  int get excludedCount => _tracks.length - selectedCount;
  int get occurrenceCount =>
      _tracks.fold(0, (count, t) => count + t.occurrences);
  String? get saveBlockedReason {
    if (_phase != FixturePhase.review) return 'Return to review before saving.';
    if (_editingId != null) return 'Save or cancel your pending edits first.';
    if (selectedCount == 0) return 'Select at least one ready track.';
    if (_tracks.any((t) => t.selected && t.state != FixtureTrackState.ready)) {
      return 'Retry or exclude the unavailable tracks before saving.';
    }
    return null;
  }

  void configureFailures({required bool edits, required bool saves}) {
    _simulateEditFailure = edits;
    _simulateSaveFailure = saves;
    notifyListeners();
  }

  void chooseScenario(FixtureScenario scenario) {
    if (_phase != FixturePhase.import) return;
    _scenario = scenario;
    notifyListeners();
  }

  bool start(String input) {
    if (_phase != FixturePhase.import) return false;
    try {
      PlaylistUrl.parse(input);
    } on AppFailure catch (failure) {
      _error = failure.message;
      notifyListeners();
      return false;
    }
    _error = null;
    _tracks = _fixtures(_scenario);
    _phase = FixturePhase.loading;
    notifyListeners();
    return true;
  }

  /// Explicit deterministic steps: no invented network percentages or timers.
  void advance() {
    _error = null;
    if (_phase == FixturePhase.loading) {
      _phase = switch (_scenario) {
        FixtureScenario.expired => FixturePhase.expired,
        FixtureScenario.offline => FixturePhase.offline,
        FixtureScenario.empty => FixturePhase.review,
        _ => FixturePhase.processing,
      };
    } else if (_phase == FixturePhase.processing) {
      final index = _tracks.indexWhere(
        (t) => t.state == FixtureTrackState.waiting,
      );
      if (index >= 0) {
        final track = _tracks[index];
        _replace(
          track.copyWith(
            state:
                track.id == 'unavailable' &&
                    _scenario == FixtureScenario.partial
                ? FixtureTrackState.failed
                : FixtureTrackState.ready,
          ),
        );
      }
      if (completedCount == _tracks.length) _phase = FixturePhase.review;
    } else {
      return;
    }
    notifyListeners();
  }

  void cancelProcessing() {
    if (_phase != FixturePhase.loading && _phase != FixturePhase.processing) {
      return;
    }
    _phase = FixturePhase.cancelled;
    _stopPreview();
    notifyListeners();
  }

  void retryConnection() {
    if (_phase != FixturePhase.offline) return;
    _phase = FixturePhase.processing;
    notifyListeners();
  }

  void reset() {
    _phase = FixturePhase.import;
    _tracks = const [];
    _editingId = null;
    _savePreview = null;
    _stopPreview();
    _error = null;
    notifyListeners();
  }

  FixtureTrack track(String id) => _tracks.firstWhere((t) => t.id == id);

  void _replace(FixtureTrack updated) {
    _tracks = List.unmodifiable(
      _tracks.map((t) => t.id == updated.id ? updated : t),
    );
  }

  void select(String id, bool selected) {
    if (_phase != FixturePhase.review || _editingId != null) return;
    _replace(track(id).copyWith(selected: selected));
    _error = null;
    notifyListeners();
  }

  void retryTrack(String id) {
    if (_phase != FixturePhase.review || _editingId != null) return;
    final item = track(id);
    if (item.state != FixtureTrackState.failed) return;
    _replace(item.copyWith(state: FixtureTrackState.ready, clearWarning: true));
    _error = null;
    notifyListeners();
  }

  FixtureTrack? beginEdit(String id) {
    if (_phase != FixturePhase.review || _editingId != null) return null;
    _editingId = id;
    _stopPreview();
    notifyListeners();
    return track(id);
  }

  String? commitEdit(String id, int expectedRevision, SongMetadata metadata) {
    if (_phase != FixturePhase.review ||
        _editingId != id ||
        track(id).revision != expectedRevision) {
      return 'This review changed. Cancel and reopen the editor.';
    }
    if (_simulateEditFailure) {
      return 'Demo save failed. Your text is preserved; turn off edit failure in demo settings and retry.';
    }
    _replace(
      track(id).copyWith(
        metadata: metadata,
        clearWarning:
            !metadata.needsReview && track(id).state == FixtureTrackState.ready,
      ),
    );
    _editingId = null;
    notifyListeners();
    return null;
  }

  void cancelEdit(String id) {
    if (_editingId != id) return;
    _editingId = null;
    notifyListeners();
  }

  void togglePreview(String id) {
    if (_phase != FixturePhase.review ||
        _editingId != null ||
        track(id).state != FixtureTrackState.ready) {
      return;
    }
    if (_activeTrackId == id) {
      _stopPreview();
    } else {
      _activeTrackId = id;
      _previewSeconds = 0;
    }
    notifyListeners();
  }

  void seekPreview(int seconds) {
    if (_activeTrackId == null) return;
    _previewSeconds = seconds.clamp(0, 30);
    if (_previewSeconds == 30) _activeTrackId = null;
    notifyListeners();
  }

  void stopPreview() {
    _stopPreview();
    notifyListeners();
  }

  void _stopPreview() {
    _activeTrackId = null;
    _previewSeconds = 0;
  }

  bool beginSave(FixtureExportFormat format) {
    final reason = saveBlockedReason;
    if (reason != null) {
      _error = reason;
      notifyListeners();
      return false;
    }
    _stopPreview();
    // Illustrative collision handling only. Production byte-bounded names and
    // file publication must be implemented/verified in Stage 6.
    final used = <String>{};
    final items = <FixtureSaveItem>[];
    for (final item in _tracks.where((t) => t.selected)) {
      final base = item.metadata.displayName.replaceAll(
        RegExp(r'[<>:"/\\|?*]'),
        '_',
      );
      var name = '$base.mp3';
      var suffix = 2;
      while (!used.add(name.toLowerCase())) {
        name = '$base (${suffix++}).mp3';
      }
      items.add(FixtureSaveItem(item.id, item.metadata, name));
    }
    _savePreview = FixtureSavePreview(items, format);
    _phase = FixturePhase.saving;
    _error = null;
    notifyListeners();
    return true;
  }

  void cancelSave() {
    if (_phase != FixturePhase.saving && _phase != FixturePhase.saved) return;
    _phase = FixturePhase.review;
    _savePreview = null;
    _error = null;
    notifyListeners();
  }

  void finishSave() {
    if (_phase != FixturePhase.saving) return;
    if (_simulateSaveFailure) {
      _error = 'Demo destination permission denied. Your review is preserved. Turn off save failure in demo settings to retry, or return to review.';
    } else {
      _phase = FixturePhase.saved;
      _error = null;
    }
    notifyListeners();
  }
}

List<FixtureTrack> _fixtures(FixtureScenario scenario) {
  if (scenario == FixtureScenario.empty) return const [];
  return List.unmodifiable([
    FixtureTrack(
      id: 'moonlit-a',
      originalTitle: 'Mira Vale • Moonlit Train (official fictional fixture)',
      metadata: SongMetadata(
        title: 'Moonlit Train',
        artists: ['Mira Vale'],
        featuredArtists: ['Jun Park'],
      ),
      durationSeconds: 214,
      hasCover: true,
      occurrences: 2,
    ),
    FixtureTrack(
      id: 'moonlit-b',
      originalTitle: 'Another recording of Moonlit Train — fictional fixture',
      metadata: SongMetadata(
        title: 'Moonlit Train',
        artists: ['Mira Vale'],
        featuredArtists: ['Jun Park'],
      ),
      durationSeconds: 198,
      hasCover: true,
    ),
    FixtureTrack(
      id: 'unicode',
      originalTitle: '夜の電車 — Le voyage très lointain à travers les étoiles — fictional fixture',
      metadata: SongMetadata(
        title: '夜の電車 — Le voyage très lointain à travers les étoiles',
        artists: ['Éloïse'],
        version: 'Live',
      ),
      durationSeconds: 286,
    ),
    FixtureTrack(
      id: 'uncertain',
      originalTitle: 'Unknown tape • slowed / reverbed — fictional fixture',
      metadata: SongMetadata(
        title: 'Paper Lanterns',
        artists: [],
        version: 'Slowed / reverbed',
        needsReview: true,
      ),
      durationSeconds: 173,
      warning: 'AI unavailable · confirm the artist. No reliable cover found.',
    ),
    FixtureTrack(
      id: 'unavailable',
      originalTitle: 'The Last Platform — unavailable fictional source',
      metadata: SongMetadata(
        title: 'The Last Platform',
        artists: ['Noor Lane'],
      ),
      durationSeconds: 241,
      warning: scenario == FixtureScenario.partial
          ? 'Source unavailable. Retry or exclude this track.'
          : null,
    ),
  ]);
}
