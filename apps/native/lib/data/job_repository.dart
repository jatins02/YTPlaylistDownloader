import 'artwork_state.dart';
import '../domain/enrichment.dart';

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';

import '../domain/failure.dart';
import '../domain/draft_store.dart';
import '../domain/models.dart';
import '../domain/media_models.dart';
import '../domain/playlist_url.dart';
import 'private_workspace.dart';

typedef Clock = DateTime Function();
typedef IdGenerator = String Function();

final class JobRepository implements DraftStore {
  JobRepository(this.db, {Clock? clock, IdGenerator? idGenerator})
    : _clock = clock ?? DateTime.now,
      _id = idGenerator ?? (() => const Uuid().v4());
  final Database db;
  final Clock _clock;
  final IdGenerator _id;
  int get _now => _clock().toUtc().millisecondsSinceEpoch;

  Future<T> _guard<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on AppFailure {
      rethrow;
    } on DatabaseException {
      throw const AppFailure(
        FailureCode.storageUnavailable,
        'The local change could not be saved. Try again.',
        retryable: true,
      );
    } catch (_) {
      throw const AppFailure(
        FailureCode.corruptData,
        'Stored data could not be read safely.',
      );
    }
  }

  JobRecord _job(Map<String, Object?> row) => JobRecord(
    sourceTitles: row['source_titles'] == null
        ? const []
        : List.unmodifiable(
            List<String>.from(
              jsonDecode(row['source_titles'] as String) as List,
            ),
          ),
    enumerated: row['enumerated'] == 1,
    failure: row['error_code'] == null
        ? null
        : FailureCode.values.byName(row['error_code']! as String),
    id: row['id']! as String,
    playlistId: row['playlist_id']! as String,
    sourceUrl: row['source_url']! as String,
    title: row['title']! as String,
    phase: JobPhase.values.byName(row['phase']! as String),
    revision: row['revision']! as int,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      row['created_at']! as int,
      isUtc: true,
    ),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(
      row['updated_at']! as int,
      isUtc: true,
    ),
  );

  TrackRecord _track(Map<String, Object?> row) => TrackRecord(
    id: row['id']! as String,
    jobId: row['job_id']! as String,
    videoId: row['video_id']! as String,
    sourceTitle: row['source_title']! as String,
    metadata: SongMetadata.fromJson(
      jsonDecode(row['metadata']! as String) as Map<String, Object?>,
    ),
    originalMetadata: row['original_metadata'] == null
        ? null
        : SongMetadata.fromJson(
            jsonDecode(row['original_metadata']! as String)
                as Map<String, Object?>,
          ),
    overrides: (jsonDecode(row['overrides']! as String) as List<Object?>)
        .map((name) => MetadataField.values.byName(name as String))
        .toSet(),
    phase: TrackPhase.values.byName(row['phase']! as String),
    revision: row['revision']! as int,
    selected: row['selected'] == 1,
    sourceUploader: row['source_uploader'] as String?,
    durationSeconds: (row['duration_seconds'] as num?)?.toDouble(),
    failure: row['error_code'] == null
        ? null
        : FailureCode.values.byName(row['error_code']! as String),
  );

  Future<JobRecord> _requireJob(DatabaseExecutor tx, String id) async {
    final rows = await tx.query(
      'jobs',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw const AppFailure(FailureCode.notFound, 'Playlist draft not found.');
    }
    return _job(rows.single);
  }

  Future<TrackRecord> _requireTrack(DatabaseExecutor tx, String id) async {
    final rows = await tx.query(
      'tracks',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw const AppFailure(FailureCode.notFound, 'Track not found.');
    }
    return _track(rows.single);
  }

  void _expectRevision(int actual, int expected) {
    if (actual != expected) {
      throw const AppFailure(
        FailureCode.conflict,
        'This draft changed. Refresh it before saving.',
      );
    }
  }

  Future<void> _editable(DatabaseExecutor tx, String jobId) async {
    final job = await _requireJob(tx, jobId);
    final deliveries = await tx.rawQuery(
      "SELECT d.id FROM export_deliveries d JOIN exports e ON e.id=d.export_id WHERE e.job_id=? AND d.status='writing' LIMIT 1",
      [jobId],
    );
    if (deliveries.isNotEmpty ||
        job.phase == JobPhase.exporting ||
        job.phase == JobPhase.cancelled) {
      throw const AppFailure(
        FailureCode.conflict,
        'This draft is locked or cancelled.',
      );
    }
  }

  Future<void> _touch(DatabaseExecutor tx, String jobId) async {
    await tx.rawUpdate(
      '''UPDATE jobs SET revision = revision + 1, updated_at = ?,
      phase = CASE WHEN phase = 'exportReady' THEN 'reviewReady' ELSE phase END WHERE id = ?''',
      [_now, jobId],
    );
  }

  @override
  Future<JobRecord> createDraft(PlaylistUrl playlist, {String? identity}) =>
      _guard(
        () => db.transaction((tx) async {
          final id = identity ?? _id();
          PrivatePaths.validateId(id);
          await tx.insert('jobs', {
            'id': id,
            'playlist_id': playlist.id,
            'source_url': playlist.canonical,
            'title': 'YouTube playlist',
            'phase': JobPhase.draft.name,
            'revision': 0,
            'created_at': _now,
            'updated_at': _now,
          });
          return _requireJob(tx, id);
        }),
      );

  Future<void> _retireAttempts(
    DatabaseExecutor tx,
    String jobId, {
    String? trackId,
    TaskStage? stage,
    required String reason,
  }) async {
    await tx.rawUpdate(
      '''UPDATE attempts SET status = 'cancelled',
      generation = generation + 1, error_code = ?, updated_at = ?
      WHERE job_id = ? AND status IN ('running','retryable')
      ${trackId == null ? '' : 'AND track_id = ?'}
      ${stage == null ? '' : 'AND stage = ?'}''',
      [reason, _now, jobId, ?trackId, ?stage?.name],
    );
  }

  @override
  Future<List<JobRecord>> listJobs() => _guard(
    () async =>
        (await db.rawQuery("""SELECT j.*,
      (SELECT json_group_array(source_title) FROM (
        SELECT COALESCE(e.source_title,t.source_title,'Unavailable source') AS source_title
        FROM playlist_entries e LEFT JOIN tracks t ON t.id=e.track_id AND t.job_id=e.job_id
        WHERE e.job_id=j.id ORDER BY e.position LIMIT 3
      )) AS source_titles FROM jobs j ORDER BY j.updated_at DESC,j.id"""))
            .map(_job)
            .toList(growable: false),
  );
  Future<JobRecord> getJob(String id) => _guard(() => _requireJob(db, id));
  Future<TrackRecord> getTrack(String id) =>
      _guard(() => _requireTrack(db, id));
  Future<List<TrackRecord>> listTracks(String jobId) => _guard(() async {
    await _requireJob(db, jobId);
    return (await db.rawQuery(
      '''SELECT t.* FROM tracks t
      LEFT JOIN playlist_entries e ON e.track_id = t.id AND e.job_id = t.job_id
      WHERE t.job_id = ? GROUP BY t.id ORDER BY MIN(e.position), t.id''',
      [jobId],
    )).map(_track).toList(growable: false);
  });

  Future<List<StoredEntry>> listEntries(String jobId) =>
      _guard(() => _entries(db, jobId));

  Future<List<StoredEntry>> _entries(DatabaseExecutor tx, String jobId) async =>
      (await tx.rawQuery(
            """SELECT e.position, e.track_id, e.error_code, e.selected,
        COALESCE(e.source_title, t.source_title, 'Unavailable source') AS source_title
        FROM playlist_entries e LEFT JOIN tracks t
        ON t.id = e.track_id AND t.job_id = e.job_id
        WHERE e.job_id = ? ORDER BY e.position""",
            [jobId],
          ))
          .map(
            (row) => StoredEntry(
              position: row['position']! as int,
              title: row['source_title']! as String,
              trackId: row['track_id'] as String?,
              selected: row['selected'] == 1,
              failure: row['error_code'] == null
                  ? null
                  : FailureCode.values.byName(row['error_code']! as String),
            ),
          )
          .toList(growable: false);

  Future<(JobRecord, List<TrackRecord>, List<StoredEntry>)> processingSnapshot(
    String jobId,
  ) => _guard(
    () => db.transaction((tx) async {
      final job = await _requireJob(tx, jobId);
      final tracks = (await tx.rawQuery(
        'SELECT t.* FROM tracks t LEFT JOIN playlist_entries e ON e.track_id = t.id AND e.job_id = t.job_id WHERE t.job_id = ? GROUP BY t.id ORDER BY MIN(e.position), t.id',
        [jobId],
      )).map(_track).toList(growable: false);
      final entries = await _entries(tx, jobId);
      return (job, tracks, entries);
    }),
  );

  Future<JobRecord> transition(String id, int revision, JobPhase next) =>
      _guard(
        () => db.transaction((tx) async {
          final job = await _requireJob(tx, id);
          _expectRevision(job.revision, revision);
          if (!(jobTransitions[job.phase]?.contains(next) ?? false)) {
            throw const AppFailure(
              FailureCode.invalidTransition,
              'This processing transition is not allowed.',
            );
          }
          if (next == JobPhase.exporting) {
            throw const AppFailure(
              FailureCode.invalidTransition,
              'Create a frozen export snapshot before saving.',
            );
          }
          if (job.phase == JobPhase.exportReady) {
            final writing = await tx.rawQuery(
              "SELECT d.id FROM export_deliveries d JOIN exports e ON e.id=d.export_id WHERE e.job_id=? AND d.status='writing' LIMIT 1",
              [id],
            );
            if (writing.isNotEmpty) {
              throw const AppFailure(
                FailureCode.conflict,
                'Stop the active device save before changing this review.',
              );
            }
          }
          if (next == JobPhase.exportReady) {
            final completed = await tx.rawQuery(
              "SELECT e.id FROM exports e JOIN export_publications p ON p.export_id=e.id WHERE e.job_id=? AND e.status='complete' AND e.job_revision=?",
              [id, job.revision - 1],
            );
            if (completed.isEmpty) {
              throw const AppFailure(
                FailureCode.invalidTransition,
                'No verified export is ready.',
              );
            }
          }
          await tx.update(
            'jobs',
            {'phase': next.name, 'revision': revision + 1, 'updated_at': _now},
            where: 'id = ?',
            whereArgs: [id],
          );
          if (next == JobPhase.cancelled || next == JobPhase.failed) {
            await _retireAttempts(tx, id, reason: next.name);
          }
          if (job.phase == JobPhase.exporting && next != JobPhase.exportReady) {
            await _retireAttempts(
              tx,
              id,
              stage: TaskStage.export,
              reason: 'export_abandoned',
            );
            await tx.update(
              'exports',
              {'status': 'failed'},
              where: 'job_id = ? AND status = ?',
              whereArgs: [id, 'planned'],
            );
          }
          return _requireJob(tx, id);
        }),
      );

  Future<TrackRecord> addSourceTrack({
    required String jobId,
    required int position,
    required String videoId,
    required String sourceTitle,
    SongMetadata? metadata,
  }) => _guard(
    () => db.transaction((tx) async {
      await _editable(tx, jobId);
      if (position < 1 || !RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(videoId)) {
        throw const AppFailure(
          FailureCode.invalidMetadata,
          'Invalid source identity or playlist position.',
        );
      }
      if (sourceTitle.trim().isEmpty ||
          sourceTitle.length > 500 ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(sourceTitle)) {
        throw const AppFailure(
          FailureCode.invalidMetadata,
          'Source title is blank, overlong or invalid.',
        );
      }
      final existing = await tx.query(
        'tracks',
        where: 'job_id = ? AND video_id = ?',
        whereArgs: [jobId, videoId],
      );
      final id = existing.isEmpty ? _id() : existing.single['id']! as String;
      if (existing.isEmpty) {
        final effective =
            metadata ??
            SongMetadata(
              title: sourceTitle,
              artists: const [],
              needsReview: true,
            );
        await tx.insert('tracks', {
          'id': id,
          'job_id': jobId,
          'video_id': videoId,
          'source_title': sourceTitle,
          'metadata': jsonEncode(effective.toJson()),
          'original_metadata': jsonEncode(effective.toJson()),
          'overrides': '[]',
          'phase': TrackPhase.queued.name,
        });
      }
      await tx.insert('playlist_entries', {
        'id': _id(),
        'job_id': jobId,
        'position': position,
        'track_id': id,
        'source_title': sourceTitle,
      });
      await _touch(tx, jobId);
      return _requireTrack(tx, id);
    }),
  );

  Future<TrackRecord> editMetadata({
    required String trackId,
    required int revision,
    required SongMetadata candidate,
    required Set<MetadataField> fields,
  }) => _guard(
    () => db.transaction((tx) async {
      final track = await _requireTrack(tx, trackId);
      await _editable(tx, track.jobId);
      _expectRevision(track.revision, revision);
      if (fields.isEmpty) return track;
      final merged = track.metadata.merge(candidate, fields);
      if (artworkKey(track.metadata) != artworkKey(merged) ||
          track.metadata.needsReview != merged.needsReview) {
        await invalidateAutomaticArtwork(tx, trackId);
      }
      final overrides = {
        ...track.overrides,
        ...fields,
      }.map((value) => value.name).toList()..sort();
      await tx.update(
        'tracks',
        {
          'metadata': jsonEncode(merged.toJson()),
          'overrides': jsonEncode(overrides),
          'revision': revision + 1,
        },
        where: 'id = ?',
        whereArgs: [trackId],
      );
      await _touch(tx, track.jobId);
      return _requireTrack(tx, trackId);
    }),
  );

  /// False means a late suggestion was ignored; human edits are never overwritten.
  Future<bool> applySuggestion({
    required String trackId,
    required int revision,
    required SongMetadata suggestion,
  }) => _guard(
    () => db.transaction((tx) async {
      final track = await _requireTrack(tx, trackId);
      await _editable(tx, track.jobId);
      if (track.revision != revision) return false;
      final available = MetadataField.values.toSet().difference(
        track.overrides,
      );
      final merged = track.metadata.merge(suggestion, available);
      if (artworkKey(track.metadata) != artworkKey(merged) ||
          track.metadata.needsReview != merged.needsReview) {
        await invalidateAutomaticArtwork(tx, trackId);
      }
      await tx.update(
        'tracks',
        {
          'metadata': jsonEncode(merged.toJson()),
          'suggestion': jsonEncode(suggestion.toJson()),
          'revision': revision + 1,
        },
        where: 'id = ?',
        whereArgs: [trackId],
      );
      await _touch(tx, track.jobId);
      return true;
    }),
  );

  Future<void> overrideArtwork({
    required String trackId,
    required int revision,
    String? assetId,
  }) => _guard(
    () => db.transaction((tx) async {
      final track = await _requireTrack(tx, trackId);
      await _editable(tx, track.jobId);
      _expectRevision(track.revision, revision);
      if (assetId != null) {
        final rows = await tx.query(
          'assets',
          where: "id=? AND job_id=? AND track_id=? AND kind='artwork'",
          whereArgs: [assetId, track.jobId, trackId],
        );
        if (rows.length != 1) {
          throw const AppFailure(
            FailureCode.invalidPath,
            'Choose a verified cover belonging to this track.',
          );
        }
      }
      await tx.insert('enrichment', {
        'track_id': trackId,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      await tx.update(
        'assets',
        {'active': 0},
        where: "track_id=? AND kind='artwork'",
        whereArgs: [trackId],
      );
      if (assetId != null) {
        await tx.update(
          'assets',
          {'active': 1},
          where: 'id=?',
          whereArgs: [assetId],
        );
      }
      await tx.update(
        'enrichment',
        {
          'artwork': 'overridden',
          'artwork_override': 1,
          'artwork_asset_id': assetId,
          'artwork_failure': null,
          'provenance': null,
        },
        where: 'track_id=?',
        whereArgs: [trackId],
      );
      await tx.rawUpdate('UPDATE tracks SET revision=revision+1 WHERE id=?', [
        trackId,
      ]);
      await _touch(tx, track.jobId);
    }),
  );

  Future<void> setTrackState(
    String id,
    int revision,
    TrackPhase phase, {
    bool? selected,
  }) => _guard(
    () => db.transaction((tx) async {
      final track = await _requireTrack(tx, id);
      await _editable(tx, track.jobId);
      _expectRevision(track.revision, revision);
      if (phase != track.phase &&
          !(trackTransitions[track.phase]?.contains(phase) ?? false)) {
        throw const AppFailure(
          FailureCode.invalidTransition,
          'This track transition is not allowed.',
        );
      }
      if (phase == TrackPhase.ready) {
        for (final kind in [AssetKind.audio, AssetKind.preview]) {
          final assets = await tx.query(
            'assets',
            where: 'job_id = ? AND track_id = ? AND kind = ? AND active = 1',
            whereArgs: [track.jobId, id, kind.name],
          );
          if (assets.length != 1) {
            throw const AppFailure(
              FailureCode.invalidTransition,
              'Exactly one verified audio asset and snippet are required before marking a track ready.',
            );
          }
        }
      }
      await tx.update(
        'tracks',
        {
          'phase': phase.name,
          'revision': revision + 1,
          if (selected != null) 'selected': selected ? 1 : 0,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      await _touch(tx, track.jobId);
      if (phase == TrackPhase.cancelled || phase == TrackPhase.failed) {
        await _retireAttempts(tx, track.jobId, trackId: id, reason: phase.name);
      }
    }),
  );

  Future<AttemptToken> beginAttempt({
    required String jobId,
    String? trackId,
    required TaskStage stage,
  }) => _guard(
    () => db.transaction((tx) async {
      final job = await _requireJob(tx, jobId);
      if (stage == TaskStage.export) {
        if (job.phase != JobPhase.exporting || trackId != null) {
          throw const AppFailure(
            FailureCode.invalidTransition,
            'No export snapshot is active.',
          );
        }
      } else {
        await _editable(tx, jobId);
        if (job.phase == JobPhase.exportReady) {
          throw const AppFailure(
            FailureCode.invalidTransition,
            'Return to review before starting processing again.',
          );
        }
        if (job.phase == JobPhase.failed) {
          throw const AppFailure(
            FailureCode.invalidTransition,
            'Retry the failed job before starting another attempt.',
          );
        }
      }
      if (trackId != null &&
          (await _requireTrack(tx, trackId)).jobId != jobId) {
        throw const AppFailure(
          FailureCode.invalidMetadata,
          'Track belongs to another playlist.',
        );
      }
      if (trackId != null) {
        final track = await _requireTrack(tx, trackId);
        if (track.phase == TrackPhase.cancelled ||
            track.phase == TrackPhase.failed) {
          throw const AppFailure(
            FailureCode.invalidTransition,
            'Retry the failed track before starting another attempt.',
          );
        }
      }
      final rows = await tx.query(
        'attempts',
        where: trackId == null
            ? 'job_id = ? AND track_id IS NULL AND stage = ?'
            : 'job_id = ? AND track_id = ? AND stage = ?',
        whereArgs: [jobId, ?trackId, stage.name],
        orderBy: 'generation DESC',
      );
      if (rows.any((row) => row['status'] == 'running')) {
        throw const AppFailure(
          FailureCode.conflict,
          'This processing step is already running.',
        );
      }
      final generation = rows.isEmpty
          ? 1
          : (rows.first['generation']! as int) + 1;
      await tx.update(
        'attempts',
        {'status': 'cancelled', 'error_code': 'superseded', 'updated_at': _now},
        where: trackId == null
            ? 'job_id = ? AND track_id IS NULL AND stage = ? AND status = ?'
            : 'job_id = ? AND track_id = ? AND stage = ? AND status = ?',
        whereArgs: [jobId, ?trackId, stage.name, 'retryable'],
      );
      final token = AttemptToken(
        id: _id(),
        jobId: jobId,
        trackId: trackId,
        stage: stage,
        generation: generation,
      );
      await tx.insert('attempts', {
        'id': token.id,
        'job_id': jobId,
        'track_id': trackId,
        'stage': stage.name,
        'generation': generation,
        'status': 'running',
        'checkpoint': rows.isEmpty || stage == TaskStage.export
            ? jsonEncode(Checkpoint(step: CheckpointStep.pending).toJson())
            : rows.first['checkpoint'],
        'updated_at': _now,
      });
      return token;
    }),
  );

  Future<void> saveCheckpoint(
    AttemptToken token,
    Checkpoint checkpoint, {
    bool complete = false,
  }) => _guard(
    () => db.transaction((tx) async {
      await _requireAttempt(tx, token);
      if (checkpoint.assetId != null) {
        final assets = await tx.query(
          'assets',
          where: 'id = ?',
          whereArgs: [checkpoint.assetId],
          limit: 1,
        );
        if (assets.isEmpty ||
            assets.single['job_id'] != token.jobId ||
            assets.single['track_id'] != token.trackId) {
          throw const AppFailure(
            FailureCode.invalidMetadata,
            'Checkpoint asset belongs to another attempt or is missing.',
          );
        }
      }
      final changed = await tx.update(
        'attempts',
        {
          'checkpoint': jsonEncode(checkpoint.toJson()),
          'status': complete ? 'complete' : 'running',
          'updated_at': _now,
        },
        where: 'id = ? AND job_id = ? AND generation = ? AND status = ?',
        whereArgs: [token.id, token.jobId, token.generation, 'running'],
      );
      if (changed != 1) {
        throw const AppFailure(
          FailureCode.conflict,
          'A newer attempt replaced this processing step.',
        );
      }
    }),
  );

  Future<void> _requireAttempt(DatabaseExecutor tx, AttemptToken token) async {
    final job = await _requireJob(tx, token.jobId);
    if (job.phase == JobPhase.cancelled) {
      throw const AppFailure(FailureCode.conflict, 'This job was cancelled.');
    }
    if (job.phase == JobPhase.failed ||
        (token.stage != TaskStage.export &&
            [JobPhase.exporting, JobPhase.exportReady].contains(job.phase)) ||
        (token.stage == TaskStage.export && job.phase != JobPhase.exporting)) {
      throw const AppFailure(
        FailureCode.conflict,
        'This processing attempt is no longer active.',
      );
    }
    if (token.trackId != null) {
      final track = await _requireTrack(tx, token.trackId!);
      if (track.phase == TrackPhase.cancelled ||
          track.phase == TrackPhase.failed) {
        throw const AppFailure(
          FailureCode.conflict,
          'This track no longer accepts processing results.',
        );
      }
    }
    final rows = await tx.query(
      'attempts',
      where: 'id = ?',
      whereArgs: [token.id],
      limit: 1,
    );
    if (rows.isEmpty ||
        rows.single['job_id'] != token.jobId ||
        rows.single['track_id'] != token.trackId ||
        rows.single['stage'] != token.stage.name ||
        rows.single['generation'] != token.generation ||
        rows.single['status'] != 'running') {
      throw const AppFailure(
        FailureCode.conflict,
        'A newer attempt replaced this processing step.',
      );
    }
  }

  /// Call only after acquiring the process-wide private storage lock.
  Future<int> recoverInterruptedAttempts() => _guard(
    () => db.transaction((tx) async {
      final interrupted = await tx.query(
        'attempts',
        where: 'status = ?',
        whereArgs: ['running'],
      );
      final affectedJobs = <String, JobRecord>{};
      final affectedTracks = <String, TrackRecord>{};
      final interruptedStages = <String, Set<String>>{};
      for (final row in interrupted) {
        if (row['stage'] == TaskStage.review.name) {
          // Unsaved text was never committed. Release the editor/export fence
          // without inventing a retryable media task or changing ready audio.
          await tx.update(
            'attempts',
            {
              'status': 'cancelled',
              'generation': (row['generation']! as int) + 1,
              'error_code': 'interrupted',
              'updated_at': _now,
            },
            where: 'id=?',
            whereArgs: [row['id']],
          );
          continue;
        }
        final jobId = row['job_id']! as String;
        final job = affectedJobs[jobId] ?? await _requireJob(tx, jobId);
        affectedJobs[jobId] = job;
        final trackId = row['track_id'] as String?;
        final track = trackId == null ? null : await _requireTrack(tx, trackId);
        final terminal =
            job.phase == JobPhase.cancelled ||
            job.phase == JobPhase.failed ||
            track?.phase == TrackPhase.cancelled ||
            track?.phase == TrackPhase.failed;
        await tx.update(
          'attempts',
          {
            'status': terminal ? 'cancelled' : 'retryable',
            'generation': (row['generation']! as int) + 1,
            'error_code': 'interrupted',
            'updated_at': _now,
          },
          where: 'id = ?',
          whereArgs: [row['id']],
        );
        if (!terminal && track != null) {
          affectedTracks[track.id] = track;
          interruptedStages
              .putIfAbsent(track.id, () => {})
              .add(row['stage']! as String);
        }
      }
      // A crash can land between a phase/snapshot transaction and creation of
      // its attempt, or after enumeration completed but before the next phase.
      // Recover those jobs too; otherwise an exporting draft stays locked forever.
      var orphanJobs = 0;
      final activeJobs = await tx.query(
        'jobs',
        where: 'phase IN (?,?,?)',
        whereArgs: [
          JobPhase.enumerating.name,
          JobPhase.processing.name,
          JobPhase.exporting.name,
        ],
      );
      for (final row in activeJobs) {
        final job = _job(row);
        if (!affectedJobs.containsKey(job.id)) {
          affectedJobs[job.id] = job;
          orphanJobs++;
        }
      }
      for (final job in affectedJobs.values) {
        if ([JobPhase.cancelled, JobPhase.failed].contains(job.phase)) continue;
        final activeTracks = await tx.query(
          'tracks',
          where: 'job_id = ? AND phase IN (?,?,?)',
          whereArgs: [
            job.id,
            TrackPhase.downloading.name,
            TrackPhase.converting.name,
            TrackPhase.enriching.name,
          ],
        );
        for (final row in activeTracks) {
          final track = _track(row);
          if (!affectedTracks.containsKey(track.id)) {
            affectedTracks[track.id] = track;
            interruptedStages[track.id] = {
              track.phase == TrackPhase.enriching
                  ? TaskStage.enrichment.name
                  : TaskStage.conversion.name,
            };
          }
        }
      }
      for (final track in affectedTracks.values) {
        final audio = await tx.query(
          'assets',
          where: 'job_id = ? AND track_id = ? AND kind = ? AND active = 1',
          whereArgs: [track.jobId, track.id, AssetKind.audio.name],
        );
        final preview = await tx.query(
          'assets',
          where: 'job_id = ? AND track_id = ? AND kind = ? AND active = 1',
          whereArgs: [track.jobId, track.id, AssetKind.preview.name],
        );
        // A failed naming retry must not destroy already acquired playable
        // audio. Keep peers and original metadata; only unfinished work queues.
        final phase =
            (audio.length == 1 &&
                preview.length == 1 &&
                (track.phase == TrackPhase.ready ||
                    interruptedStages[track.id]!.every(
                      (stage) => stage == TaskStage.enrichment.name,
                    )))
            ? TrackPhase.ready
            : TrackPhase.queued;
        await tx.update(
          'tracks',
          {'phase': phase.name, 'revision': track.revision + 1},
          where: 'id = ?',
          whereArgs: [track.id],
        );
      }
      // Decide from the original job state once, never from a preceding attempt's
      // recovery update. Otherwise order changes phases and inflates revisions.
      for (final job in affectedJobs.values) {
        if (job.phase == JobPhase.cancelled || job.phase == JobPhase.failed) {
          continue;
        }
        final unfinished = await tx.query(
          'tracks',
          columns: ['id'],
          where: 'job_id = ? AND phase IN (?,?,?,?)',
          whereArgs: [
            job.id,
            TrackPhase.queued.name,
            TrackPhase.downloading.name,
            TrackPhase.converting.name,
            TrackPhase.enriching.name,
          ],
          limit: 1,
        );
        final phase =
            job.phase == JobPhase.exporting ||
                (unfinished.isEmpty &&
                    (job.phase == JobPhase.reviewReady ||
                        job.phase == JobPhase.exportReady))
            ? JobPhase.reviewReady
            : JobPhase.queued;
        await tx.update(
          'jobs',
          {
            'phase': phase.name,
            'revision': job.revision + 1,
            'updated_at': _now,
          },
          where: 'id = ?',
          whereArgs: [job.id],
        );
        if (job.phase == JobPhase.exporting) {
          await tx.update(
            'exports',
            {'status': 'failed'},
            where: 'job_id = ? AND status = ?',
            whereArgs: [job.id, 'planned'],
          );
        }
      }
      await tx.execute(
        "UPDATE enrichment SET naming='pending',naming_failure='aiUnavailable',reason='Details preparation was interrupted; retry from retained audio.' WHERE naming='running'",
      );
      await tx.execute(
        "UPDATE enrichment SET artwork='pending',artwork_failure='artworkUnavailable' WHERE artwork='running'",
      );
      return interrupted.length + orphanJobs;
    }),
  );

  Future<ExportSnapshot> freezeExport(
    String jobId,
    int revision, {
    bool fillMissingMetadata = false,
  }) => _guard(
    () => db.transaction((tx) async {
      final job = await _requireJob(tx, jobId);
      if (job.phase == JobPhase.cancelled) {
        throw const AppFailure(FailureCode.conflict, 'This job was cancelled.');
      }
      final previous = await tx.query(
        'exports',
        where: 'job_id = ? AND job_revision = ?',
        whereArgs: [jobId, revision],
      );
      if (previous.isNotEmpty) {
        final snapshot = _export(previous.single);
        // A completed export remains reusable. An interrupted or edited draft
        // must freeze its current revision rather than revive an obsolete lock.
        if ((previous.single['status'] == 'complete' &&
                ((job.phase == JobPhase.exporting &&
                        job.revision == revision + 1) ||
                    (job.phase == JobPhase.exportReady &&
                        job.revision == revision + 2))) ||
            (previous.single['status'] == 'planned' &&
                job.phase == JobPhase.exporting &&
                job.revision == revision + 1)) {
          return snapshot;
        }
        throw const AppFailure(
          FailureCode.conflict,
          'This draft changed. Review it before creating another export.',
        );
      }
      _expectRevision(job.revision, revision);
      if (job.phase != JobPhase.reviewReady) {
        throw const AppFailure(
          FailureCode.invalidTransition,
          'Finish reviewing the playlist before saving.',
        );
      }
      final unmapped = await tx.query(
        'playlist_entries',
        columns: ['id'],
        where: 'job_id = ? AND track_id IS NULL AND selected = 1',
        whereArgs: [jobId],
        limit: 1,
      );
      if (unmapped.isNotEmpty) {
        throw const AppFailure(
          FailureCode.invalidTransition,
          'Resolve or explicitly exclude unavailable playlist entries before saving.',
        );
      }
      final tracks = (await tx.rawQuery(
        '''SELECT t.* FROM tracks t JOIN playlist_entries e
      ON e.track_id = t.id AND e.job_id = t.job_id WHERE t.job_id = ? AND t.selected = 1
      GROUP BY t.id ORDER BY MIN(e.position), t.id''',
        [jobId],
      )).map(_track).toList();
      if (tracks.isEmpty ||
          tracks.any(
            (track) =>
                track.phase != TrackPhase.ready ||
                (!fillMissingMetadata && track.metadata.needsReview),
          )) {
        throw const AppFailure(
          FailureCode.invalidTransition,
          'Select ready tracks and resolve their review warnings before saving.',
        );
      }
      final assets = await tx.query(
        'assets',
        where: 'job_id = ? AND kind IN (?,?) AND active = 1',
        whereArgs: [jobId, AssetKind.audio.name, AssetKind.artwork.name],
        orderBy: 'id',
      );
      final selectedIds = tracks.map((track) => track.id).toSet();
      final audioByTrack = <String, List<Map<String, Object?>>>{};
      for (final asset in assets) {
        final trackId = asset['track_id'] as String?;
        if (trackId != null &&
            selectedIds.contains(trackId) &&
            asset['kind'] == AssetKind.audio.name) {
          audioByTrack.putIfAbsent(trackId, () => []).add(asset);
        }
      }
      if (tracks.any((track) => audioByTrack[track.id]?.length != 1)) {
        throw const AppFailure(
          FailureCode.invalidTransition,
          'Each selected track needs exactly one verified audio asset before saving.',
        );
      }
      final coversByTrack = <String, List<Map<String, Object?>>>{};
      for (final asset in assets.where(
        (a) => a['kind'] == AssetKind.artwork.name,
      )) {
        final id = asset['track_id'] as String?;
        if (id != null && selectedIds.contains(id)) {
          coversByTrack.putIfAbsent(id, () => []).add(asset);
        }
      }
      if (coversByTrack.values.any((covers) => covers.length != 1)) {
        throw const AppFailure(
          FailureCode.invalidTransition,
          'Each selected track can have only one verified cover.',
        );
      }
      final running = await tx.query(
        'attempts',
        columns: ['id'],
        where: 'job_id = ? AND stage != ? AND status IN (?,?)',
        whereArgs: [jobId, TaskStage.export.name, 'running', 'retryable'],
        limit: 1,
      );
      if (running.isNotEmpty) {
        throw const AppFailure(
          FailureCode.invalidTransition,
          'Finish or cancel pending processing before saving this review.',
        );
      }

      final snapshot = jsonEncode({
        'job_id': jobId,
        'job_revision': revision,
        'assets': assets
            .where((asset) => selectedIds.contains(asset['track_id']))
            .toList(),
        'tracks': tracks
            .map(
              (track) => {
                'track_id': track.id,
                'video_id': track.videoId,
                'track_revision': track.revision,
                'audio_asset_id': audioByTrack[track.id]!.single['id'],
                'artwork_asset_id': coversByTrack[track.id]?.single['id'],
                'metadata':
                    (fillMissingMetadata
                            ? track.metadata.withExportPlaceholders()
                            : track.metadata)
                        .toJson(),
              },
            )
            .toList(),
      });
      final row = <String, Object?>{
        'id': _id(),
        'job_id': jobId,
        'job_revision': revision,
        'snapshot_hash': sha256.convert(utf8.encode(snapshot)).toString(),
        'snapshot': snapshot,
        'status': 'planned',
        'created_at': _now,
      };
      await tx.insert('exports', row);
      await tx.update(
        'jobs',
        {
          'phase': JobPhase.exporting.name,
          'revision': revision + 1,
          'updated_at': _now,
        },
        where: 'id = ?',
        whereArgs: [jobId],
      );
      return _export(row);
    }),
  );

  ExportSnapshot _export(Map<String, Object?> row) {
    final json = row['snapshot']! as String;
    if (sha256.convert(utf8.encode(json)).toString() != row['snapshot_hash']) {
      throw const AppFailure(
        FailureCode.corruptData,
        'The stored export snapshot failed its integrity check.',
      );
    }
    return ExportSnapshot(
      id: row['id']! as String,
      jobId: row['job_id']! as String,
      jobRevision: row['job_revision']! as int,
      hash: row['snapshot_hash']! as String,
      json: json,
    );
  }

  /// Called only after the media adapter verifies complete bytes and checksum.
  Future<void> registerAsset(
    AssetRecord asset, {
    required AttemptToken attempt,
  }) => _guard(
    () => db.transaction((tx) async {
      await _requireAttempt(tx, attempt);
      if (attempt.jobId != asset.jobId || attempt.trackId != asset.trackId) {
        throw const AppFailure(
          FailureCode.invalidMetadata,
          'Asset belongs to another processing attempt.',
        );
      }
      await _editable(tx, asset.jobId);
      if (asset.trackId != null &&
          (await _requireTrack(tx, asset.trackId!)).jobId != asset.jobId) {
        throw const AppFailure(
          FailureCode.invalidMetadata,
          'Asset belongs to another playlist.',
        );
      }
      if (asset.bytes <= 0 ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(asset.sha256) ||
          asset.relativePath !=
              PrivatePaths.asset(asset.jobId, asset.id, asset.kind)) {
        throw const AppFailure(
          FailureCode.invalidPath,
          'Asset identity, path or checksum is invalid.',
        );
      }
      final row = <String, Object?>{
        'id': asset.id,
        'job_id': asset.jobId,
        'track_id': asset.trackId,
        'kind': asset.kind.name,
        'relative_path': asset.relativePath,
        'sha256': asset.sha256,
        'bytes': asset.bytes,
      };
      final existing = await tx.query(
        'assets',
        where: 'id = ?',
        whereArgs: [asset.id],
      );
      if (existing.isNotEmpty) {
        if (row.keys.every((key) => row[key] == existing.single[key])) return;
        throw const AppFailure(
          FailureCode.conflict,
          'An immutable asset cannot be replaced.',
        );
      }
      await tx.insert('assets', row);
      await _touch(tx, asset.jobId);
    }),
  );
}
