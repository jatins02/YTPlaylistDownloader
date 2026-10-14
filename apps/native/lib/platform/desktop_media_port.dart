import 'dart:async';
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../data/job_repository.dart';
import '../data/media_workspace.dart';
import '../data/pipeline_repository.dart';
import '../data/private_workspace.dart';
import '../domain/failure.dart';
import '../domain/media_models.dart';
import '../domain/models.dart';
import '../domain/playlist_url.dart';
import 'desktop_tools.dart';
import 'guarded_process.dart';
import 'media_port.dart';
import 'native_codec.dart';
import 'playlist_source.dart';

/// Linux adapter. The portable repository/codec contracts are not evidence that
/// this process implementation can run on Android, iOS or Windows.
final class DesktopMediaPort implements ManagedMediaPort {
  DesktopMediaPort({
    required this.jobs,
    required this.workspace,
    required this.tools,
    this.limits = const PipelineLimits(),
    PlaylistSource? source,
  }) : source = source ?? YoutubePlaylistSource(tools);
  final JobRepository jobs;
  final PrivateWorkspace workspace;
  final DesktopTools tools;
  final PipelineLimits limits;
  final PlaylistSource source;
  late final store = PipelineRepository(jobs);
  late final files = MediaWorkspace(workspace, limits);
  late final codec = NativeCodec(tools, limits);
  String? _activeJob;
  ProcessScope? _scope;
  Future<void>? _task;
  Timer? _retentionTimer;
  Future<void>? _retentionWork;
  final Map<String, Future<void>> _discardTasks = {};
  bool _closed = false;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_closed) {
      throw const AppFailure(
        FailureCode.mediaUnavailable,
        'The media adapter is closed.',
      );
    }
    if (_initialized) return;
    if (!Platform.isLinux) {
      throw const AppFailure(
        FailureCode.mediaUnavailable,
        'This media adapter is proven only on Linux.',
      );
    }
    limits.validate();
    await tools.verify(workspace.root);
    for (final job in await jobs.listJobs()) {
      if ([JobPhase.enumerating, JobPhase.processing].contains(job.phase)) {
        await store.stop(job.id);
      }
      await files.cleanup(
        job.id,
        await store.assets(job.id, activeOnly: false),
      );
    }
    await expireOldMedia();
    _initialized = true;
    _retentionTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      if (_retentionWork != null || _closed) return;
      unawaited(
        expireOldMedia().catchError((Object _) {
          /* Safe to retry at next startup; never erase exports. */
        }),
      );
    });
  }

  Future<void> expireOldMedia() {
    if (_closed) return Future.value();
    return _retentionWork ??= _expireOldMedia().whenComplete(() {
      _retentionWork = null;
    });
  }

  Future<void> _expireOldMedia() async {
    final cutoff = DateTime.now().toUtc().subtract(const Duration(hours: 48));
    for (final job in await jobs.listJobs()) {
      if (job.id == _activeJob ||
          job.createdAt.isAfter(cutoff) ||
          job.phase == JobPhase.exporting) {
        continue;
      }
      // Expired metadata remains a durable draft. Do not recreate its private
      // directory or increment revisions on every retention sweep.
      if (job.phase == JobPhase.cancelled &&
          (await store.assets(job.id, activeOnly: false)).isEmpty &&
          await FileSystemEntity.type(
                '${workspace.root.path}/jobs/${job.id}',
                followLinks: false,
              ) ==
              FileSystemEntityType.notFound) {
        continue;
      }
      await store.stop(job.id, cancel: true, failure: FailureCode.expiredMedia);
      final current = await jobs.getJob(job.id);
      if (current.phase == JobPhase.cancelled) {
        await discardPrivateMedia(job.id);
      }
    }
  }

  @override
  Future<MediaCapabilities> capabilities() async => MediaCapabilities(
    platform: DevicePlatform.linux,
    canAcquire: _initialized && !_closed,
    canConvert: _initialized && !_closed,
    canPrepareSnippets: _initialized && !_closed,
  );

  @override
  Future<void> acquire({required PlaylistUrl playlist, required String jobId}) {
    if (!_initialized) {
      return Future.error(
        const AppFailure(
          FailureCode.toolUnavailable,
          'Verify the local media runtime before processing.',
        ),
      );
    }
    if (_closed || _activeJob != null || _retentionWork != null) {
      return Future.error(
        const AppFailure(
          FailureCode.conflict,
          'Another playlist or storage cleanup is active. Wait for it to finish before processing.',
        ),
      );
    }
    _activeJob = jobId;
    final scope = tools.scope(maxFileBytes: limits.maxFileBytes);
    _scope = scope;
    final deadline = Timer(
      limits.jobTimeout,
      () => scope.cancel(
        cause: const AppFailure(
          FailureCode.processTimeout,
          'This playlist reached its processing time limit. Verified work is preserved.',
          retryable: true,
        ),
      ),
    );
    final future = _process(playlist, jobId, scope).whenComplete(() {
      deadline.cancel();
      _activeJob = null;
      _scope = null;
      _task = null;
    });
    _task = future;
    return future;
  }

  Future<void> budget(
    String jobId,
    ProcessScope scope,
    Directory directory,
  ) async {
    scope.check();
    await files.checkBudget(jobId);
    final output = await scope.run(
      '/bin/df',
      ['-B1', '--output=avail', '--', workspace.root.path],
      directory: directory,
      timeout: const Duration(seconds: 10),
      maxOutputBytes: 8192,
    );
    final available = int.tryParse(output.trim().split('\n').last.trim());
    if (available == null) {
      throw const AppFailure(
        FailureCode.storageUnavailable,
        'Available disk space could not be checked.',
      );
    }
    if (available < limits.freeReserveBytes) {
      throw const AppFailure(
        FailureCode.limitExceeded,
        'The device is low on space. Free storage before retrying; verified tracks are preserved.',
      );
    }
    scope.check();
  }

  Future<JobRecord> _transition(String id, JobPhase next) async {
    final job = await jobs.getJob(id);
    return jobs.transition(id, job.revision, next);
  }

  Future<void> _process(
    PlaylistUrl playlist,
    String jobId,
    ProcessScope scope,
  ) async {
    var started = false;
    try {
      var job = await jobs.getJob(jobId);
      if (job.sourceUrl != playlist.canonical ||
          ![
            JobPhase.draft,
            JobPhase.queued,
            JobPhase.failed,
          ].contains(job.phase)) {
        throw const AppFailure(
          FailureCode.invalidTransition,
          'This playlist cannot start in its current phase.',
        );
      }
      started = true;
      if (job.phase != JobPhase.queued) {
        job = await _transition(jobId, JobPhase.queued);
      }
      await files.cleanup(jobId, await store.assets(jobId, activeOnly: false));
      scope.check();
      if (!job.enumerated) {
        await _transition(jobId, JobPhase.enumerating);
        final token = await jobs.beginAttempt(
          jobId: jobId,
          stage: TaskStage.acquisition,
        );
        final work = await files.work(jobId, token.id);
        Future<void> monitor() => budget(jobId, scope, work);
        await monitor();
        final entries = await source.enumerate(
          playlist,
          scope,
          work,
          limits,
          monitor,
        );
        scope.check();
        await store.commitEnumeration(token, entries, limits);
      } else {
        // Enumeration is a durable all-or-nothing boundary. Never refetch a
        // changed remote playlist when resuming this local job.
        await _transition(jobId, JobPhase.enumerating);
      }
      await _transition(jobId, JobPhase.processing);
      for (final initial in await jobs.listTracks(jobId)) {
        scope.check();
        if (initial.phase == TrackPhase.failed ||
            initial.phase == TrackPhase.cancelled) {
          continue;
        }
        if (initial.phase == TrackPhase.ready) {
          // Ready peers survive; integrity is checked before declaring reuse.
          final assets = await store.assets(jobId, trackId: initial.id);
          final audio = assets.where((a) => a.kind == AssetKind.audio).toList();
          final preview = assets
              .where((a) => a.kind == AssetKind.preview)
              .toList();
          if (audio.length == 1 &&
              preview.length == 1 &&
              await files.matches(audio.single) &&
              await files.matches(preview.single)) {
            continue;
          }
          // A retained ready asset was changed/lost outside the app. Rebuild
          // through an explicit attempt; never silently keep a corrupt result.
          await jobs.setTrackState(
            initial.id,
            initial.revision,
            TrackPhase.enriching,
          );
          final interrupted = await jobs.beginAttempt(
            jobId: jobId,
            trackId: initial.id,
            stage: TaskStage.conversion,
          );
          await store.trackPhase(
            interrupted,
            TrackPhase.failed,
            failure: FailureCode.audioInvalid,
          );
          continue;
        }
        await _track(initial, scope);
      }
      scope.check();
      await _transition(jobId, JobPhase.reviewReady);
    } on AppFailure catch (failure) {
      if (failure.code == FailureCode.operationCancelled) return;
      // An invalid start must not mutate a review/exporting/cancelled job.
      if (started && failure.code == FailureCode.conflict) {
        final current = await jobs.getJob(jobId);
        if ([
          JobPhase.queued,
          JobPhase.enumerating,
          JobPhase.processing,
        ].contains(current.phase)) {
          await store.stop(jobId, failure: failure.code);
        }
      } else if (failure.code != FailureCode.invalidTransition &&
          failure.code != FailureCode.conflict) {
        await store.stop(jobId, failure: failure.code);
      }
      rethrow;
    } on FileSystemException {
      await store.stop(jobId, failure: FailureCode.storageUnavailable);
      throw const AppFailure(
        FailureCode.storageUnavailable,
        'Media storage failed. Check free space and permissions.',
        retryable: true,
      );
    } on Object {
      await store.stop(jobId, failure: FailureCode.toolUnavailable);
      throw const AppFailure(
        FailureCode.toolUnavailable,
        'The media operation could not finish safely. Verified work is preserved; retry after checking the runtime.',
        retryable: true,
      );
    } finally {
      scope.cancel();
      // Registered assets (including inactive ones) are retained. Orphans and
      // incomplete scratch are removable only after every guarded command ends.
      try {
        await files.cleanup(
          jobId,
          await store.assets(jobId, activeOnly: false),
        );
      } on AppFailure {
        /* Keep the safe original result; next startup can retry cleanup. */
      } on FileSystemException {
        /* Storage is already reported; do not delete user files. */
      }
    }
  }

  Future<void> _track(TrackRecord initial, ProcessScope scope) async {
    final token = await jobs.beginAttempt(
      jobId: initial.jobId,
      trackId: initial.id,
      stage: TaskStage.conversion,
    );
    final work = await files.work(initial.jobId, token.id);
    Future<void> monitor() => budget(initial.jobId, scope, work);
    try {
      await monitor();
      await store.trackPhase(token, TrackPhase.downloading);
      var assets = await store.assets(initial.jobId, trackId: initial.id);
      AssetRecord? sourceAsset, audioAsset, previewAsset;
      for (final kind in [
        AssetKind.source,
        AssetKind.audio,
        AssetKind.preview,
      ]) {
        final candidates = assets.where((a) => a.kind == kind).toList();
        if (candidates.length == 1 && await files.matches(candidates.single)) {
          switch (kind) {
            case AssetKind.source:
              sourceAsset = candidates.single;
            case AssetKind.audio:
              audioAsset = candidates.single;
            case AssetKind.preview:
              previewAsset = candidates.single;
            default:
              break;
          }
        } else if (candidates.isNotEmpty) {
          await store.retire(token, kind);
        }
      }
      File? input;
      AudioProbe? original;
      if (audioAsset == null) {
        input = sourceAsset == null
            ? await source.download(
                initial.videoId,
                scope,
                work,
                limits,
                monitor,
              )
            : await files.file(sourceAsset);
        original = sourceAsset == null
            ? await codec.verify(
                input,
                scope,
                work,
                monitor,
                expected: initial.durationSeconds,
              )
            : await _verifyStored(
                token,
                sourceAsset,
                scope,
                work,
                monitor,
                expected: initial.durationSeconds,
              );
        scope.check();
        if (sourceAsset == null) {
          sourceAsset = await files.stage(
            input,
            initial.jobId,
            initial.id,
            const Uuid().v4(),
            AssetKind.source,
          );
          await store.publish(token, sourceAsset, CheckpointStep.acquired);
          input = await files.file(sourceAsset);
        }
      }
      await store.trackPhase(token, TrackPhase.converting);
      if (audioAsset == null) {
        final output = await codec.convert(input!, scope, work, monitor);
        await codec.verify(
          output,
          scope,
          work,
          monitor,
          mp3: true,
          expected: original!.durationSeconds,
        );
        scope.check();
        audioAsset = await files.stage(
          output,
          initial.jobId,
          initial.id,
          const Uuid().v4(),
          AssetKind.audio,
        );
        await store.publish(token, audioAsset, CheckpointStep.converted);
        // Publication already retired the older preview atomically.
        previewAsset = null;
      }
      final audioFile = await files.file(audioAsset);
      final verified = await _verifyStored(
        token,
        audioAsset,
        scope,
        work,
        monitor,
        mp3: true,
        expected: initial.durationSeconds,
      );
      if (previewAsset == null) {
        final preview = await codec.snippet(
          audioFile,
          verified.durationSeconds,
          scope,
          work,
          monitor,
        );
        await codec.verify(
          preview,
          scope,
          work,
          monitor,
          mp3: true,
          preview: true,
          expected: NativeCodec.snippetSeconds(verified.durationSeconds),
        );
        scope.check();
        previewAsset = await files.stage(
          preview,
          initial.jobId,
          initial.id,
          const Uuid().v4(),
          AssetKind.preview,
        );
        await store.publish(token, previewAsset, CheckpointStep.converted);
      } else {
        await _verifyStored(
          token,
          previewAsset,
          scope,
          work,
          monitor,
          mp3: true,
          preview: true,
          expected: NativeCodec.snippetSeconds(verified.durationSeconds),
        );
      }
      scope.check();
      await store.trackPhase(
        token,
        TrackPhase.ready,
        duration: verified.durationSeconds,
      );
    } on AppFailure catch (failure) {
      if ([
        FailureCode.operationCancelled,
        FailureCode.conflict,
        FailureCode.limitExceeded,
        FailureCode.storageUnavailable,
        FailureCode.toolUnavailable,
      ].contains(failure.code)) {
        rethrow;
      }
      await store.trackPhase(token, TrackPhase.failed, failure: failure.code);
    }
  }

  Future<AudioProbe> _verifyStored(
    AttemptToken token,
    AssetRecord asset,
    ProcessScope scope,
    Directory work,
    Future<void> Function() monitor, {
    bool mp3 = false,
    bool preview = false,
    double? expected,
  }) async {
    try {
      return await codec.verify(
        await files.file(asset),
        scope,
        work,
        monitor,
        mp3: mp3,
        preview: preview,
        expected: expected,
      );
    } on AppFailure catch (failure) {
      if (failure.code == FailureCode.audioInvalid) {
        await store.retire(token, asset.kind);
        if (asset.kind == AssetKind.audio) {
          await store.retire(token, AssetKind.preview);
        }
      }
      rethrow;
    }
  }

  Future<void> _stop(String jobId, {required bool cancel}) async {
    try {
      await store.stop(jobId, cancel: cancel);
    } finally {
      if (_activeJob == jobId) {
        _scope?.cancel();
        final task = _task;
        if (task != null) {
          try {
            await task;
          } on AppFailure {
            /* Publication was fenced or the scope stopped. */
          }
        }
      }
    }
  }

  @override
  Future<void> cancel(String jobId) => _stop(jobId, cancel: true);
  @override
  Future<void> pause(String jobId) => _stop(jobId, cancel: false);
  @override
  Future<void> discardPrivateMedia(String jobId) {
    if (_closed) {
      return Future.error(
        const AppFailure(
          FailureCode.storageUnavailable,
          'Private media storage is closing.',
        ),
      );
    }
    return _discardTasks[jobId] ??= _discardPrivateMedia(jobId)
        .whenComplete(() {
          _discardTasks.remove(jobId);
        });
  }

  Future<void> _discardPrivateMedia(String jobId) async {
    if (_activeJob == jobId) await cancel(jobId);
    final job = await jobs.getJob(jobId);
    if (job.phase != JobPhase.cancelled) {
      throw const AppFailure(
        FailureCode.conflict,
        'Cancel this job before removing its temporary files.',
      );
    }
    final retained = await store.assets(jobId, activeOnly: false);
    if (retained.isEmpty &&
        await FileSystemEntity.type(
              '${workspace.root.path}/jobs/$jobId',
              followLinks: false,
            ) ==
            FileSystemEntityType.notFound) {
      return;
    }
    for (final asset in retained) {
      final file = await files.file(asset);
      if (await file.exists()) await file.delete();
    }
    await files.cleanup(jobId, const []);
    await store.dropCancelledAssets(jobId);
    final directory = await workspace.ensureJob(jobId);
    await directory.delete(recursive: true);
  }

  @override
  Future<void> export(ExportSnapshot snapshot) async => throw const AppFailure(
    FailureCode.mediaUnavailable,
    'Verified final tagging and device saving are not implemented until Stage 6.',
  );

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _retentionTimer?.cancel();
    try {
      final retention = _retentionWork;
      if (retention != null) await retention;
    } finally {
      try {
        final id = _activeJob;
        if (id != null) await pause(id);
      } finally {
        await Future.wait(_discardTasks.values.toList());
      }
    }
  }
}
