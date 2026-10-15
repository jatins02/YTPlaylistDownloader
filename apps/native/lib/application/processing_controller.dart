import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/job_repository.dart';
import '../data/enrichment_repository.dart';
import '../domain/enrichment.dart';
import '../data/pipeline_repository.dart';
import '../domain/failure.dart';
import '../domain/media_models.dart';
import '../domain/models.dart';
import '../domain/playlist_url.dart';
import '../platform/media_port.dart';

final class ProcessingController extends ChangeNotifier {
  ProcessingController({
    required this.jobId,
    required this.jobs,
    required this.media,
  });
  final String jobId;
  final JobRepository jobs;
  final MediaPort media;
  late final store = PipelineRepository(jobs);
  JobRecord? job;
  List<TrackRecord> tracks = const [];
  List<StoredEntry> entries = const [];
  Map<String, EnrichmentRecord> enrichment = const {};
  Map<String, Uint8List> covers = const {};
  Map<String, String> _coverIds = const {};
  MediaCapabilities? capability;
  AppFailure? failure;
  bool commanding = false, cancelling = false;
  bool _initialized = false;
  bool _disposed = false, _refreshing = false;
  Timer? _polling;
  Completer<void>? _readDone;
  AppFailure? _readFailure;
  int _commandGeneration = 0;
  static const _stopFailure = AppFailure(
    FailureCode.storageUnavailable,
    'Processing could not be stopped safely. Check storage and retry.',
    retryable: true,
  );
  int get unmappedCount => entries.where((e) => e.trackId == null).length;
  int get readyCount => tracks.where((t) => t.phase == TrackPhase.ready).length;
  int get failedCount =>
      tracks.where((t) => t.phase == TrackPhase.failed).length;
  bool get processing =>
      [JobPhase.enumerating, JobPhase.processing].contains(job?.phase) ||
      commanding;

  Future<void> initialize() async {
    if (_initialized || _disposed) return;
    _initialized = true;
    try {
      capability = await media.capabilities();
    } on AppFailure catch (error) {
      failure = error;
    } on Object {
      failure = const AppFailure(
        FailureCode.mediaUnavailable,
        'Media capability could not be checked safely.',
      );
    }
    await refresh();
    if (_disposed) return;
    _polling = Timer.periodic(const Duration(milliseconds: 500), (_) {
      unawaited(refresh());
    });
  }

  Future<void> refresh({bool force = false}) async {
    if (_disposed) return;
    while (_refreshing) {
      if (!force) return;
      await _readDone?.future;
      if (_disposed) return;
    }
    _refreshing = true;
    final done = Completer<void>();
    _readDone = done;
    try {
      final snapshot = await jobs.processingSnapshot(jobId);
      final current = snapshot.$1,
          currentTracks = snapshot.$2,
          currentEntries = snapshot.$3;
      final currentEnrichment = await EnrichmentRepository(jobs).records(jobId);
      final loadedCovers = <String, Uint8List>{}, coverIds = <String, String>{};
      if (capability?.canEnrich == true && media is EnrichingMediaPort) {
        for (final record in currentEnrichment.values) {
          final id = record.artworkAssetId;
          if (id == null) continue;
          final bytes = _coverIds[record.trackId] == id
              ? covers[record.trackId]
              : await (media as EnrichingMediaPort).coverBytes(jobId, id);
          if (bytes != null) {
            loadedCovers[record.trackId] = bytes;
            coverIds[record.trackId] = id;
          }
        }
        if ((await jobs.getJob(jobId)).revision != current.revision) return;
      }
      if (_disposed) return;
      // A new snapshot is read after each command too; no stale poll can publish
      // over a later completed database read.
      if (job != null && current.revision < job!.revision) return;
      job = current;
      tracks = List.unmodifiable(currentTracks);
      entries = List.unmodifiable(currentEntries);
      enrichment = Map.unmodifiable(currentEnrichment);
      covers = Map.unmodifiable(loadedCovers);
      _coverIds = Map.unmodifiable(coverIds);
      if (identical(failure, _readFailure)) failure = null;
      _readFailure = null;
    } on AppFailure catch (error) {
      if (!_disposed) failure = _readFailure = error;
    } on Object {
      if (!_disposed) {
        failure = _readFailure = const AppFailure(
          FailureCode.storageUnavailable,
          'Processing state could not be read. Check storage and retry.',
          retryable: true,
        );
      }
    } finally {
      _refreshing = false;
      done.complete();
      _readDone = null;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> start({bool retryFailed = false}) async {
    if (_disposed || commanding || cancelling || job == null) return;
    final generation = ++_commandGeneration;
    commanding = true;
    failure = null;
    notifyListeners();
    try {
      if (capability?.canAcquire != true) {
        throw const AppFailure(
          FailureCode.mediaUnavailable,
          'This platform needs a verified local media runtime before processing. Your draft remains saved.',
        );
      }
      if (retryFailed) await store.retryFailedTracks(jobId);
      // A cancel/pause can finish while the retry transaction is awaiting I/O.
      // Never acquire a fresh worker after that newer user action.
      if (_disposed || cancelling || _commandGeneration != generation) return;
      await media.acquire(
        playlist: PlaylistUrl.parse(job!.sourceUrl),
        jobId: jobId,
      );
    } on AppFailure catch (error) {
      if (!_disposed && !cancelling && _commandGeneration == generation) {
        failure = error;
      }
    } catch (_) {
      if (!_disposed && !cancelling && _commandGeneration == generation) {
        failure = const AppFailure(
          FailureCode.storageUnavailable,
          'Processing could not finish safely. Reopen this draft to recover.',
        );
      }
    } finally {
      await refresh(force: true);
      commanding = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> enrich() async {
    if (_disposed ||
        commanding ||
        cancelling ||
        job == null ||
        media is! EnrichingMediaPort) {
      return;
    }
    final generation = ++_commandGeneration;
    commanding = true;
    failure = null;
    notifyListeners();
    try {
      if (capability?.canEnrich != true) {
        throw const AppFailure(
          FailureCode.mediaUnavailable,
          'Naming and covers require the verified metadata runtime.',
        );
      }
      await (media as EnrichingMediaPort).enrich(jobId);
    } on AppFailure catch (error) {
      if (!_disposed && !cancelling && _commandGeneration == generation) {
        failure = error;
      }
    } catch (_) {
      if (!_disposed && !cancelling && _commandGeneration == generation) {
        failure = const AppFailure(
          FailureCode.storageUnavailable,
          'Details preparation could not finish safely. Audio is kept.',
        );
      }
    } finally {
      await refresh(force: true);
      commanding = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> cancel() async {
    if (_disposed || cancelling) return;
    cancelling = true;
    _commandGeneration++;
    failure = null;
    notifyListeners();
    try {
      await media.cancel(jobId);
    } on AppFailure catch (error) {
      if (!_disposed) failure = error;
    } on Object {
      if (!_disposed) failure = _stopFailure;
    } finally {
      await refresh(force: true);
      cancelling = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> pause() async {
    if (_disposed || cancelling || media is! ManagedMediaPort) return;
    cancelling = true;
    _commandGeneration++;
    failure = null;
    notifyListeners();
    try {
      await (media as ManagedMediaPort).pause(jobId);
    } on AppFailure catch (error) {
      if (!_disposed) failure = error;
    } on Object {
      if (!_disposed) failure = _stopFailure;
    } finally {
      await refresh(force: true);
      cancelling = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> discardMedia() async {
    if (_disposed || cancelling || media is! ManagedMediaPort) return;
    cancelling = true;
    failure = null;
    notifyListeners();
    try {
      await (media as ManagedMediaPort).discardPrivateMedia(jobId);
    } on AppFailure catch (error) {
      if (!_disposed) failure = error;
    } on Object {
      if (!_disposed) {
        failure = const AppFailure(
          FailureCode.storageUnavailable,
          'Private media could not be fully removed. Retry after checking storage.',
        );
      }
    } finally {
      await refresh(force: true);
      cancelling = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _polling?.cancel();
    super.dispose();
  }
}
