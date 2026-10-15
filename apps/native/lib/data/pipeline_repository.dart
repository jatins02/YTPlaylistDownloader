import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';

import '../domain/failure.dart';
import '../domain/media_models.dart';
import '../domain/models.dart';
import 'job_repository.dart';
import 'private_workspace.dart';

/// Pipeline writes require the same running token inside every transaction.
/// This complements JobRepository's review/export API; it never updates human
/// metadata or uses a title to find stored bytes.
final class PipelineRepository {
  PipelineRepository(this.jobs);
  final JobRepository jobs;
  Database get db => jobs.db;

  Future<T> _write<T>(Future<T> Function(Transaction) operation) async {
    try {
      return await db.transaction(operation);
    } on AppFailure {
      rethrow;
    } catch (_) {
      throw const AppFailure(
        FailureCode.storageUnavailable,
        'The processing checkpoint could not be saved. Check available storage.',
        retryable: true,
      );
    }
  }

  /// Shared transaction fence for later pipeline stages. Callback writes commit
  /// only while the exact owner/generation is still running and editable.
  Future<T> writeWithToken<T>(
    AttemptToken token,
    Future<T> Function(Transaction) operation,
  ) => _write((tx) async {
    await _token(tx, token);
    return operation(tx);
  });

  Future<void> _token(DatabaseExecutor tx, AttemptToken token) async {
    final rows = await tx.rawQuery(
      '''SELECT a.status, a.generation, a.job_id, a.track_id, a.stage,
      j.phase AS job_phase, t.phase AS track_phase FROM attempts a
      JOIN jobs j ON j.id = a.job_id LEFT JOIN tracks t ON t.id = a.track_id WHERE a.id = ?''',
      [token.id],
    );
    if (rows.length != 1) {
      throw const AppFailure(
        FailureCode.conflict,
        'This worker is no longer active.',
      );
    }
    final row = rows.single;
    if (row['status'] != 'running' ||
        row['generation'] != token.generation ||
        row['job_id'] != token.jobId ||
        row['track_id'] != token.trackId ||
        row['stage'] != token.stage.name ||
        [
          'cancelled',
          'failed',
          'exporting',
          'exportReady',
        ].contains(row['job_phase']) ||
        ['cancelled', 'failed'].contains(row['track_phase'])) {
      throw const AppFailure(
        FailureCode.conflict,
        'A newer action stopped this worker.',
      );
    }
  }

  Future<void> _touch(DatabaseExecutor tx, String jobId) async {
    await tx.rawUpdate(
      'UPDATE jobs SET revision = revision + 1, updated_at = ? WHERE id = ?',
      [DateTime.now().toUtc().millisecondsSinceEpoch, jobId],
    );
  }

  Future<void> commitEnumeration(
    AttemptToken token,
    List<SourceEntry> entries,
    PipelineLimits limits,
  ) => _write((tx) async {
    await _token(tx, token);
    limits.validate();
    if (token.trackId != null || token.stage != TaskStage.acquisition) {
      throw const AppFailure(
        FailureCode.invalidTransition,
        'This is not a playlist enumeration attempt.',
      );
    }
    final job = (await tx.query(
      'jobs',
      where: 'id = ?',
      whereArgs: [token.jobId],
    )).single;
    if (job['enumerated'] == 1 || job['phase'] != JobPhase.enumerating.name) {
      throw const AppFailure(
        FailureCode.conflict,
        'This playlist was already imported or stopped.',
      );
    }
    if (entries.length > limits.maxEntries ||
        entries.map((e) => e.videoId).whereType<String>().toSet().length >
            limits.maxTracks) {
      throw const AppFailure(
        FailureCode.limitExceeded,
        'This playlist exceeds the configured capacity. Nothing was silently truncated.',
      );
    }
    final identities = <String, String>{};
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (entry.position != i + 1 ||
          entry.title.trim().isEmpty ||
          entry.title.length > 500 ||
          (entry.uploader != null &&
              (entry.uploader!.length > 200 ||
                  RegExp(r'[\x00-\x1f\x7f]').hasMatch(entry.uploader!))) ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(entry.title) ||
          (entry.videoId != null &&
              !RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(entry.videoId!)) ||
          (entry.durationSeconds != null &&
              (!entry.durationSeconds!.isFinite ||
                  entry.durationSeconds! <= 0))) {
        throw const AppFailure(
          FailureCode.invalidMetadata,
          'The playlist contains malformed source metadata.',
        );
      }
      String? id;
      if (entry.videoId != null) {
        id = identities[entry.videoId];
        if (id == null) {
          id = const Uuid().v4();
          identities[entry.videoId!] = id;
          final metadata = SongMetadata(
            title: entry.title,
            artists: const [],
            needsReview: true,
          );
          await tx.insert('tracks', {
            'id': id,
            'job_id': token.jobId,
            'video_id': entry.videoId,
            'source_title': entry.title,
            'metadata': jsonEncode(metadata.toJson()),
            'original_metadata': jsonEncode(metadata.toJson()),
            'overrides': '[]',
            'duration_seconds': entry.durationSeconds,
            'source_uploader': entry.uploader,
            'phase': entry.failure == null
                ? TrackPhase.queued.name
                : TrackPhase.failed.name,
            'error_code': entry.failure?.name,
          });
        }
      }
      await tx.insert('playlist_entries', {
        'id': const Uuid().v4(),
        'job_id': token.jobId,
        'position': entry.position,
        'track_id': id,
        'source_title': entry.title,
        'error_code':
            entry.failure?.name ??
            (id == null ? FailureCode.sourceUnavailable.name : null),
      });
    }
    await tx.update(
      'jobs',
      {'enumerated': 1, 'error_code': null},
      where: 'id = ?',
      whereArgs: [token.jobId],
    );
    await tx.update(
      'attempts',
      {'status': 'complete'},
      where: 'id = ?',
      whereArgs: [token.id],
    );
    await _touch(tx, token.jobId);
  });

  Future<List<StoredEntry>> entries(String jobId) => jobs.listEntries(jobId);

  Future<void> trackPhase(
    AttemptToken token,
    TrackPhase phase, {
    double? duration,
    FailureCode? failure,
  }) => _write((tx) async {
    await _token(tx, token);
    if (token.trackId == null || token.stage != TaskStage.conversion) {
      throw const AppFailure(
        FailureCode.invalidTransition,
        'A track conversion attempt is required.',
      );
    }
    final rows = await tx.query(
      'tracks',
      where: 'id = ?',
      whereArgs: [token.trackId],
    );
    if (rows.length != 1) {
      throw const AppFailure(
        FailureCode.invalidTransition,
        'A track attempt is required.',
      );
    }
    final old = TrackPhase.values.byName(rows.single['phase']! as String);
    if (old != phase && !(trackTransitions[old]?.contains(phase) ?? false)) {
      throw const AppFailure(
        FailureCode.invalidTransition,
        'This track cannot change to that processing phase.',
      );
    }
    if (duration != null && (!duration.isFinite || duration <= 0)) {
      throw const AppFailure(
        FailureCode.audioInvalid,
        'The measured audio duration is invalid.',
      );
    }
    if (phase == TrackPhase.ready) {
      for (final kind in [AssetKind.audio, AssetKind.preview]) {
        final assets = await tx.query(
          'assets',
          where: 'track_id = ? AND kind = ? AND active = 1',
          whereArgs: [token.trackId, kind.name],
        );
        if (assets.length != 1) {
          throw const AppFailure(
            FailureCode.audioInvalid,
            'Verified audio and a preview are required.',
          );
        }
      }
      await tx.update(
        'attempts',
        {'status': 'complete'},
        where: 'id = ?',
        whereArgs: [token.id],
      );
    }
    await tx.rawUpdate(
      'UPDATE tracks SET phase = ?, revision = revision + 1, error_code = ?, duration_seconds = COALESCE(?,duration_seconds) WHERE id = ?',
      [phase.name, failure?.name, duration, token.trackId],
    );
    if (phase == TrackPhase.failed) {
      await tx.rawUpdate(
        "UPDATE attempts SET status = 'cancelled', generation = generation + 1, error_code = ? WHERE job_id = ? AND track_id = ? AND status IN ('running','retryable')",
        [failure?.name, token.jobId, token.trackId],
      );
    }
    await _touch(tx, token.jobId);
  });

  Future<List<AssetRecord>> assets(
    String jobId, {
    String? trackId,
    bool activeOnly = true,
  }) async =>
      (await db.query(
            'assets',
            where:
                'job_id = ? ${trackId == null ? '' : 'AND track_id = ?'} ${activeOnly ? 'AND active = 1' : ''}',
            whereArgs: [jobId, ?trackId],
          ))
          .map(
            (row) => AssetRecord(
              id: row['id']! as String,
              jobId: row['job_id']! as String,
              trackId: row['track_id'] as String?,
              kind: AssetKind.values.byName(row['kind']! as String),
              relativePath: row['relative_path']! as String,
              sha256: row['sha256']! as String,
              bytes: row['bytes']! as int,
            ),
          )
          .toList(growable: false);

  /// Make a newly verified derivative active atomically; retained manifests stay
  /// immutable and cannot confuse a later frozen export's audio selection.
  Future<void> publish(
    AttemptToken token,
    AssetRecord asset,
    CheckpointStep step,
  ) => _write((tx) async {
    await _token(tx, token);
    if (token.trackId == null || token.stage != TaskStage.conversion) {
      throw const AppFailure(
        FailureCode.invalidTransition,
        'Only a track conversion attempt can publish prepared media.',
      );
    }
    if (asset.jobId != token.jobId ||
        asset.trackId != token.trackId ||
        asset.bytes <= 0 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(asset.sha256) ||
        asset.relativePath !=
            PrivatePaths.asset(asset.jobId, asset.id, asset.kind) ||
        ![
          AssetKind.source,
          AssetKind.audio,
          AssetKind.preview,
        ].contains(asset.kind)) {
      throw const AppFailure(
        FailureCode.invalidPath,
        'The verified asset does not belong to this track.',
      );
    }
    final expectedStep = asset.kind == AssetKind.source
        ? CheckpointStep.acquired
        : CheckpointStep.converted;
    if (step != expectedStep) {
      throw const AppFailure(
        FailureCode.invalidTransition,
        'The checkpoint does not match the prepared media.',
      );
    }
    // A crash after publishing replacement audio must not retain a preview
    // from the previous conversion. Replacement sources invalidate derivatives.
    final obsolete = switch (asset.kind) {
      AssetKind.source => [AssetKind.audio, AssetKind.preview],
      AssetKind.audio => [AssetKind.preview],
      _ => <AssetKind>[],
    };
    for (final kind in obsolete) {
      await tx.update(
        'assets',
        {'active': 0},
        where: 'job_id = ? AND track_id = ? AND kind = ?',
        whereArgs: [asset.jobId, asset.trackId, kind.name],
      );
    }
    await tx.update(
      'assets',
      {'active': 0},
      where: 'job_id = ? AND track_id = ? AND kind = ?',
      whereArgs: [asset.jobId, asset.trackId, asset.kind.name],
    );
    await tx.insert('assets', {
      'id': asset.id,
      'job_id': asset.jobId,
      'track_id': asset.trackId,
      'kind': asset.kind.name,
      'relative_path': asset.relativePath,
      'sha256': asset.sha256,
      'bytes': asset.bytes,
      'active': 1,
    });
    if (asset.kind != AssetKind.preview) {
      await tx.update(
        'attempts',
        {
          'checkpoint': jsonEncode(
            Checkpoint(step: step, assetId: asset.id).toJson(),
          ),
        },
        where: 'id = ?',
        whereArgs: [token.id],
      );
    }
    await _touch(tx, asset.jobId);
  });

  Future<void> retire(AttemptToken token, AssetKind kind) => _write((tx) async {
    await _token(tx, token);
    if (token.trackId == null ||
        token.stage != TaskStage.conversion ||
        ![
          AssetKind.source,
          AssetKind.audio,
          AssetKind.preview,
        ].contains(kind)) {
      throw const AppFailure(
        FailureCode.invalidTransition,
        'Only a track conversion attempt can retire prepared media.',
      );
    }
    await tx.update(
      'assets',
      {'active': 0},
      where: 'job_id = ? AND track_id = ? AND kind = ?',
      whereArgs: [token.jobId, token.trackId, kind.name],
    );
    await _touch(tx, token.jobId);
  });

  /// Pause/fail the job, fencing all workers in the same transaction. Ready
  /// peers survive; failed/excluded rows remain for an explicit bounded retry.
  Future<void> stop(
    String jobId, {
    bool cancel = false,
    FailureCode? failure,
  }) => _write((tx) async {
    final rows = await tx.query('jobs', where: 'id = ?', whereArgs: [jobId]);
    if (rows.isEmpty) return;
    if ([
      'cancelled',
      'exporting',
      'exportReady',
    ].contains(rows.single['phase'])) {
      return;
    }
    // An enrichment pause retains verified playable audio. Conversion work
    // still resumes through its own queued checkpoint boundary.
    await tx.rawUpdate(
      "UPDATE tracks SET phase=CASE WHEN phase='enriching' AND EXISTS (SELECT 1 FROM attempts a WHERE a.track_id=tracks.id AND a.stage='enrichment' AND a.status='running') AND (SELECT COUNT(*) FROM assets WHERE track_id=tracks.id AND kind='audio' AND active=1)=1 AND (SELECT COUNT(*) FROM assets WHERE track_id=tracks.id AND kind='preview' AND active=1)=1 THEN 'ready' ELSE 'queued' END,revision=revision+1 WHERE job_id=? AND phase IN ('downloading','converting','enriching')",
      [jobId],
    );
    await tx.rawUpdate(
      "UPDATE enrichment SET naming='pending',naming_failure='operationCancelled' WHERE track_id IN (SELECT id FROM tracks WHERE job_id=?) AND naming='running'",
      [jobId],
    );
    await tx.rawUpdate(
      "UPDATE enrichment SET artwork='pending',artwork_failure='operationCancelled' WHERE track_id IN (SELECT id FROM tracks WHERE job_id=?) AND artwork='running'",
      [jobId],
    );
    await tx.rawUpdate(
      "UPDATE attempts SET status = 'retryable', generation = generation + 1, error_code = ? WHERE job_id = ? AND status = 'running'",
      [failure?.name ?? FailureCode.operationCancelled.name, jobId],
    );
    await tx.update(
      'jobs',
      {
        'phase': cancel
            ? JobPhase.cancelled.name
            : failure == null
            ? JobPhase.queued.name
            : JobPhase.failed.name,
        'error_code': failure?.name,
      },
      where: 'id = ?',
      whereArgs: [jobId],
    );
    if (cancel) {
      await tx.rawUpdate(
        "UPDATE attempts SET status = 'cancelled' WHERE job_id = ? AND status = 'retryable'",
        [jobId],
      );
    }
    await _touch(tx, jobId);
  });

  Future<void> retryFailedTracks(String jobId) => _write((tx) async {
    final job = (await tx.query(
      'jobs',
      where: 'id = ?',
      whereArgs: [jobId],
    )).single;
    if (job['phase'] != JobPhase.reviewReady.name) {
      throw const AppFailure(
        FailureCode.invalidTransition,
        'Return to review before retrying.',
      );
    }
    await tx.rawUpdate(
      "UPDATE tracks SET phase = 'queued', revision = revision + 1, error_code = NULL WHERE job_id = ? AND phase = 'failed'",
      [jobId],
    );
    await tx.update(
      'jobs',
      {'phase': JobPhase.queued.name, 'error_code': null},
      where: 'id = ?',
      whereArgs: [jobId],
    );
    await _touch(tx, jobId);
  });
  Future<void> dropCancelledAssets(String jobId) => _write((tx) async {
    final job = (await tx.query(
      'jobs',
      where: 'id = ?',
      whereArgs: [jobId],
    )).single;
    if (job['phase'] != 'cancelled') {
      throw const AppFailure(
        FailureCode.conflict,
        'Only cancelled-job media can be removed.',
      );
    }
    await tx.delete('assets', where: 'job_id = ?', whereArgs: [jobId]);
    await tx.rawUpdate(
      "UPDATE enrichment SET artwork='unavailable',artwork_failure='expiredMedia',artwork_asset_id=NULL WHERE track_id IN (SELECT id FROM tracks WHERE job_id=?) AND artwork_override=0",
      [jobId],
    );
    await tx.rawUpdate(
      "UPDATE tracks SET phase = 'cancelled', revision = revision + 1 WHERE job_id = ?",
      [jobId],
    );
    await _touch(tx, jobId);
  });
}
