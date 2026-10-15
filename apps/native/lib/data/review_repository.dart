import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';

import '../domain/failure.dart';
import '../domain/enrichment.dart';
import '../domain/models.dart';
import '../domain/review.dart';
import 'artwork_state.dart';
import 'job_repository.dart';
import 'pipeline_repository.dart';
import 'private_workspace.dart';

/// A running review token fences image work and blocks export freezing. Unsaved
/// editor text is UI state; interrupted review tokens are cancelled on restart.
final class ReviewRepository {
  ReviewRepository(this.jobs);
  final JobRepository jobs;
  late final pipeline = PipelineRepository(jobs);
  int get _now => DateTime.now().toUtc().millisecondsSinceEpoch;

  Future<T> _write<T>(Future<T> Function(Transaction) action) async {
    try {
      return await jobs.db.transaction(action);
    } on AppFailure {
      rethrow;
    } catch (_) {
      throw const AppFailure(
        FailureCode.storageUnavailable,
        'The review could not be saved. Your edits are kept; retry after checking storage.',
        retryable: true,
      );
    }
  }

  Never _conflict() => throw const AppFailure(
    FailureCode.conflict,
    'This review changed. Keep your text and explicitly apply your edits to the latest revision.',
  );

  Future<void> _ready(DatabaseExecutor tx, String jobId) async {
    final rows = await tx.query(
      'jobs',
      where: 'id=? AND phase=?',
      whereArgs: [jobId, 'reviewReady'],
    );
    if (rows.length != 1) _conflict();
  }

  Future<void> _touch(DatabaseExecutor tx, String jobId) async {
    await tx.rawUpdate(
      'UPDATE jobs SET revision=revision+1,updated_at=? WHERE id=?',
      [_now, jobId],
    );
  }

  Future<ReviewSession> begin(TrackRecord initial) => _write((tx) async {
    await _ready(tx, initial.jobId);
    final tracks = await tx.query(
      'tracks',
      where: 'id=? AND job_id=? AND phase=? AND revision=?',
      whereArgs: [initial.id, initial.jobId, 'ready', initial.revision],
    );
    if (tracks.length != 1) _conflict();
    final running = await tx.query(
      'attempts',
      where: "job_id=? AND status='running'",
      whereArgs: [initial.jobId],
    );
    if (running.isNotEmpty) {
      throw const AppFailure(
        FailureCode.conflict,
        'Finish preparation or the open edit before editing another track.',
      );
    }
    final previous = await tx.query(
      'attempts',
      where: "track_id=? AND stage='review'",
      whereArgs: [initial.id],
      orderBy: 'generation DESC',
      limit: 1,
    );
    final token = AttemptToken(
      id: const Uuid().v4(),
      jobId: initial.jobId,
      trackId: initial.id,
      stage: TaskStage.review,
      generation: previous.isEmpty
          ? 1
          : (previous.single['generation'] as int) + 1,
    );
    await tx.insert('attempts', {
      'id': token.id,
      'job_id': token.jobId,
      'track_id': token.trackId,
      'stage': 'review',
      'generation': token.generation,
      'status': 'running',
      'checkpoint': jsonEncode({'revision': initial.revision}),
      'updated_at': _now,
    });
    await _touch(tx, initial.jobId);
    return ReviewSession(token, initial, initial.revision);
  });

  Future<void> cancel(ReviewSession session) => _write((tx) async {
    final changed = await tx.update(
      'attempts',
      {'status': 'cancelled', 'updated_at': _now},
      where: "id=? AND job_id=? AND track_id=? AND stage='review' AND generation=? AND status='running'",
      whereArgs: [
        session.token.id,
        session.token.jobId,
        session.token.trackId,
        session.token.generation,
      ],
    );
    if (changed != 0) await _touch(tx, session.token.jobId);
  });

  Future<ReviewSession> rebase(ReviewSession session) =>
      pipeline.writeWithToken(session.token, (tx) async {
        if (session.token.stage != TaskStage.review ||
            session.token.trackId != session.initial.id) {
          _conflict();
        }
        await _ready(tx, session.token.jobId);
        final row = (await tx.query(
          'tracks',
          where: "id=? AND phase='ready'",
          whereArgs: [session.initial.id],
        ));
        if (row.length != 1) _conflict();
        final revision = row.single['revision'] as int;
        await tx.update(
          'attempts',
          {
            'checkpoint': jsonEncode({'revision': revision}),
            'updated_at': _now,
          },
          where: 'id=?',
          whereArgs: [session.token.id],
        );
        return ReviewSession(session.token, session.initial, revision);
      });

  Future<void> commit(
    ReviewSession session,
    SongMetadata candidate,
    CoverEdit cover, {
    AssetRecord? imported,
  }) => pipeline.writeWithToken(session.token, (tx) async {
    if (session.token.stage != TaskStage.review ||
        session.token.trackId != session.initial.id) {
      _conflict();
    }
    await _ready(tx, session.token.jobId);
    final row = (await tx.query(
      'tracks',
      where: 'id=?',
      whereArgs: [session.initial.id],
    )).single;
    final attempt = (await tx.query(
      'attempts',
      where: 'id=?',
      whereArgs: [session.token.id],
    )).single;
    if (row['revision'] != session.revision ||
        (jsonDecode(attempt['checkpoint'] as String) as Map)['revision'] !=
            session.revision) {
      _conflict();
    }
    final original = SongMetadata.fromJson(
      jsonDecode(row['metadata'] as String) as Map<String, dynamic>,
    );
    final fields = editedFields(session.initial.metadata, candidate);
    final metadata = original.merge(candidate, fields);
    final overrides = {
      ...(jsonDecode(row['overrides'] as String) as List).cast<String>(),
      ...fields.map((f) => f.name),
    }.toList()..sort();
    if (cover.action == CoverAction.import) {
      if (imported == null ||
          imported.kind != AssetKind.artwork ||
          imported.jobId != session.token.jobId ||
          imported.trackId != session.initial.id ||
          imported.bytes <= 0 ||
          imported.bytes > 1024 * 1024 ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(imported.sha256) ||
          imported.relativePath !=
              PrivatePaths.asset(
                imported.jobId,
                imported.id,
                AssetKind.artwork,
              )) {
        throw const AppFailure(
          FailureCode.artworkInvalid,
          'Choose a verified image belonging to this track.',
        );
      }
      await tx.insert('assets', {
        'id': imported.id,
        'job_id': imported.jobId,
        'track_id': imported.trackId,
        'kind': 'artwork',
        'relative_path': imported.relativePath,
        'sha256': imported.sha256,
        'bytes': imported.bytes,
        'active': 0,
      });
    } else if (imported != null) {
      throw const AppFailure(
        FailureCode.artworkInvalid,
        'Unexpected imported cover.',
      );
    }
    if (cover.action == CoverAction.keep) {
      if (artworkKey(original) != artworkKey(metadata) ||
          original.needsReview != metadata.needsReview) {
        await invalidateAutomaticArtwork(tx, session.initial.id);
      }
    } else {
      final id = cover.action == CoverAction.import
          ? imported!.id
          : cover.assetId;
      if (cover.action != CoverAction.remove && id == null) {
        throw const AppFailure(
          FailureCode.artworkInvalid,
          'Choose a cover before saving.',
        );
      }
      if (id != null &&
          (await tx.query(
                'assets',
                where: "id=? AND job_id=? AND track_id=? AND kind='artwork'",
                whereArgs: [id, session.token.jobId, session.initial.id],
              )).length !=
              1) {
        throw const AppFailure(
          FailureCode.artworkInvalid,
          'That cover is no longer available.',
        );
      }
      await tx.update(
        'assets',
        {'active': 0},
        where: "track_id=? AND kind='artwork'",
        whereArgs: [session.initial.id],
      );
      if (id != null) {
        await tx.update(
          'assets',
          {'active': 1},
          where: 'id=?',
          whereArgs: [id],
        );
      }
      await tx.insert('enrichment', {
        'track_id': session.initial.id,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      await tx.update(
        'enrichment',
        {
          'artwork': 'overridden',
          'artwork_override': 1,
          'artwork_asset_id': id,
          'artwork_failure': null,
          'provenance': null,
        },
        where: 'track_id=?',
        whereArgs: [session.initial.id],
      );
    }
    await tx.update(
      'tracks',
      {
        'metadata': jsonEncode(metadata.toJson()),
        'overrides': jsonEncode(overrides),
        'revision': session.revision + 1,
      },
      where: 'id=?',
      whereArgs: [session.initial.id],
    );
    await tx.update(
      'attempts',
      {'status': 'complete', 'updated_at': _now},
      where: 'id=?',
      whereArgs: [session.token.id],
    );
    await _touch(tx, session.token.jobId);
  });

  Future<void> selectTrack(TrackRecord track, bool selected) =>
      _write((tx) async {
        await _ready(tx, track.jobId);
        if ((await tx.query(
          'attempts',
          where: "job_id=? AND status='running'",
          whereArgs: [track.jobId],
        )).isNotEmpty) {
          _conflict();
        }
        final changed = await tx.rawUpdate(
          'UPDATE tracks SET selected=?,revision=revision+1 WHERE id=? AND job_id=? AND revision=?',
          [selected ? 1 : 0, track.id, track.jobId, track.revision],
        );
        if (changed != 1) _conflict();
        await _touch(tx, track.jobId);
      });

  Future<void> selectEntry(JobRecord job, int position, bool selected) =>
      _write((tx) async {
        await _ready(tx, job.id);
        if ((await tx.query(
              'jobs',
              where: 'id=? AND revision=?',
              whereArgs: [job.id, job.revision],
            )).isEmpty ||
            (await tx.query(
              'attempts',
              where: "job_id=? AND status='running'",
              whereArgs: [job.id],
            )).isNotEmpty) {
          _conflict();
        }
        if (await tx.update(
              'playlist_entries',
              {'selected': selected ? 1 : 0},
              where: 'job_id=? AND position=? AND track_id IS NULL',
              whereArgs: [job.id, position],
            ) !=
            1) {
          _conflict();
        }
        await _touch(tx, job.id);
      });
}
