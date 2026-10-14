import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/job_repository.dart';
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
  MediaCapabilities? capability;
  AppFailure? failure;
  bool commanding = false, cancelling = false;
  bool _initialized = false;
  bool _disposed = false, _refreshing = false;
  Timer? _polling;
  Completer<void>? _readDone;
  int get unmappedCount => entries.where((e) => e.trackId == null).length;
  int get readyCount => tracks.where((t) => t.phase == TrackPhase.ready).length;
  int get failedCount =>
      tracks.where((t) => t.phase == TrackPhase.failed).length;
  bool get processing =>
      [
        JobPhase.enumerating,
        JobPhase.processing,
        JobPhase.queued,
      ].contains(job?.phase) ||
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
    if (_refreshing) {
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
      if (_disposed) return;
      // A new snapshot is read after each command too; no stale poll can publish
      // over a later completed database read.
      if (job != null && current.revision < job!.revision) return;
      job = current;
      tracks = List.unmodifiable(currentTracks);
      entries = List.unmodifiable(currentEntries);
    } on AppFailure catch (error) {
      if (!_disposed) failure = error;
    } finally {
      _refreshing = false;
      done.complete();
      _readDone = null;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> start({bool retryFailed = false}) async {
    if (_disposed || commanding || cancelling || job == null) return;
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
      await media.acquire(
        playlist: PlaylistUrl.parse(job!.sourceUrl),
        jobId: jobId,
      );
    } on AppFailure catch (error) {
      if (!_disposed) failure = error;
    } catch (_) {
      if (!_disposed) {
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

  Future<void> cancel() async {
    if (_disposed || cancelling) return;
    cancelling = true;
    notifyListeners();
    try {
      await media.cancel(jobId);
    } on AppFailure catch (error) {
      if (!_disposed) failure = error;
    } finally {
      await refresh(force: true);
      cancelling = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> pause() async {
    if (_disposed || cancelling || media is! ManagedMediaPort) return;
    cancelling = true;
    notifyListeners();
    try {
      await (media as ManagedMediaPort).pause(jobId);
    } on AppFailure catch (error) {
      if (!_disposed) failure = error;
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
