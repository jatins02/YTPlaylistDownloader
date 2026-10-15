import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';

import '../domain/enrichment.dart';
import '../domain/failure.dart';
import '../domain/models.dart';
import 'job_repository.dart';
import 'artwork_state.dart';
import 'pipeline_repository.dart';
import 'private_workspace.dart';

final class EnrichmentTicket {
  const EnrichmentTicket(this.token, this.input, this.revision, this.audioId);
  final AttemptToken token;
  final NamingInput input;
  final int revision;
  final String audioId;
}

final class CachedArtwork {
  const CachedArtwork(this.bytes, this.provenance);
  final Uint8List bytes;
  final Map<String, Object?> provenance;
}

/// Metadata is a separate durable stage: provider failure never downgrades audio.
final class EnrichmentRepository {
  EnrichmentRepository(this.jobs);
  final JobRepository jobs;
  late final pipeline = PipelineRepository(jobs);
  Database get db => jobs.db;
  static int get _now => DateTime.now().toUtc().millisecondsSinceEpoch;
  static const cacheBytes = 1024 * 1024;

  Future<T> _write<T>(Future<T> Function(Transaction) operation) async {
    try {
      return await db.transaction(operation);
    } on AppFailure {
      rethrow;
    } catch (_) {
      throw const AppFailure(
        FailureCode.storageUnavailable,
        'Details could not be saved safely. Check private storage.',
        retryable: true,
      );
    }
  }

  Future<EnrichmentOptions> options() async {
    final rows = await db.query('metadata_settings', where: 'id = 1');
    return rows.isEmpty
        ? EnrichmentOptions()
        : EnrichmentOptions(
            model: rows.single['model'] as String,
            contact: rows.single['contact'] as String,
          );
  }

  Future<void> saveOptions(EnrichmentOptions options) => _write((tx) async {
    await tx.insert('metadata_settings', {
      'id': 1,
      'model': options.model,
      'contact': options.contact,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  });

  Future<Map<String, EnrichmentRecord>> records(String jobId) async {
    final rows = await db.rawQuery(
      'SELECT e.* FROM enrichment e JOIN tracks t ON t.id=e.track_id WHERE t.job_id=?',
      [jobId],
    );
    return {
      for (final row in rows)
        row['track_id'] as String: EnrichmentRecord(
          trackId: row['track_id'] as String,
          naming: NamingState.values.byName(row['naming'] as String),
          artwork: ArtworkState.values.byName(row['artwork'] as String),
          namingFailure: row['naming_failure'] == null
              ? null
              : FailureCode.values.byName(row['naming_failure'] as String),
          artworkFailure: row['artwork_failure'] == null
              ? null
              : FailureCode.values.byName(row['artwork_failure'] as String),
          reason: row['reason'] as String?,
          artworkAssetId: row['artwork_asset_id'] as String?,
          artworkOverride: row['artwork_override'] == 1,
          provenance: row['provenance'] == null
              ? null
              : (jsonDecode(
                  row['provenance'] as String,
                ) as Map<String, dynamic>).cast<String, Object?>(),
        ),
    };
  }

  Future<void> _touch(DatabaseExecutor tx, String jobId) => tx
      .rawUpdate(
        'UPDATE jobs SET revision=revision+1,updated_at=? WHERE id=?',
        [_now, jobId],
      )
      .then((_) {});

  Future<EnrichmentTicket> begin(String trackId, {bool nameNeeded = true}) =>
      _write((tx) async {
        final rows = await tx.rawQuery(
          'SELECT t.*,j.phase AS job_phase FROM tracks t JOIN jobs j ON j.id=t.job_id WHERE t.id=?',
          [trackId],
        );
        if (rows.length != 1 ||
            !['processing', 'reviewReady'].contains(rows.single['job_phase']) ||
            rows.single['phase'] != 'ready') {
          throw const AppFailure(
            FailureCode.invalidTransition,
            'Only verified ready audio can receive new details.',
          );
        }
        final row = rows.single, jobId = row['job_id'] as String;
        final active = await tx.query(
          'assets',
          where: 'track_id=? AND active=1 AND kind IN (?,?)',
          whereArgs: [trackId, 'audio', 'preview'],
        );
        if (active.where((a) => a['kind'] == 'audio').length != 1 ||
            active.where((a) => a['kind'] == 'preview').length != 1) {
          throw const AppFailure(
            FailureCode.audioInvalid,
            'Verified audio and preview are required before naming.',
          );
        }
        final attempts = await tx.query(
          'attempts',
          where: 'track_id=? AND stage=?',
          whereArgs: [trackId, 'enrichment'],
          orderBy: 'generation DESC',
        );
        if (attempts.any((a) => a['status'] == 'running')) {
          throw const AppFailure(
            FailureCode.conflict,
            'Details are already being prepared.',
          );
        }
        await tx.update(
          'attempts',
          {'status': 'cancelled'},
          where: "track_id=? AND stage='enrichment' AND status='retryable'",
          whereArgs: [trackId],
        );
        final token = AttemptToken(
          id: const Uuid().v4(),
          jobId: jobId,
          trackId: trackId,
          stage: TaskStage.enrichment,
          generation:
              (attempts.isEmpty ? 0 : attempts.first['generation'] as int) + 1,
        );
        await tx.insert('attempts', {
          'id': token.id,
          'job_id': jobId,
          'track_id': trackId,
          'stage': 'enrichment',
          'generation': token.generation,
          'status': 'running',
          'checkpoint': jsonEncode(
            Checkpoint(step: CheckpointStep.pending).toJson(),
          ),
          'updated_at': _now,
        });
        final revision = (row['revision'] as int) + 1;
        await tx.update(
          'tracks',
          {'phase': 'enriching', 'revision': revision},
          where: 'id=?',
          whereArgs: [trackId],
        );
        await tx.insert('enrichment', {
          'track_id': trackId,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        if (nameNeeded) {
          await tx.update(
            'enrichment',
            {'naming': 'running', 'naming_failure': null, 'reason': null},
            where: 'track_id=?',
            whereArgs: [trackId],
          );
        }
        await _touch(tx, jobId);
        return EnrichmentTicket(
          token,
          NamingInput(
            trackId: trackId,
            title: row['source_title'] as String,
            uploader: row['source_uploader'] as String?,
            duration: (row['duration_seconds'] as num?)?.toDouble(),
          ),
          revision,
          active.singleWhere((a) => a['kind'] == 'audio')['id'] as String,
        );
      });

  Future<Map<String, Object?>> _track(
    Transaction tx,
    EnrichmentTicket ticket,
  ) async {
    if (ticket.token.stage != TaskStage.enrichment ||
        ticket.token.trackId != ticket.input.trackId) {
      throw const AppFailure(
        FailureCode.invalidTransition,
        'An enrichment attempt is required.',
      );
    }
    final audio = await tx.query(
      'assets',
      where: "track_id=? AND kind='audio' AND active=1",
      whereArgs: [ticket.token.trackId],
    );
    if (audio.length != 1 || audio.single['id'] != ticket.audioId) {
      throw const AppFailure(
        FailureCode.conflict,
        'The verified audio changed while details were being prepared.',
      );
    }
    return (await tx.query(
      'tracks',
      where: 'id=?',
      whereArgs: [ticket.token.trackId],
    )).single;
  }

  /// A changed revision discards the candidate. Field overrides also protect
  /// human choices made before this attempt began.
  Future<bool> naming(
    EnrichmentTicket ticket,
    EnrichmentOptions options, {
    NamingResult? result,
    FailureCode? failure,
  }) => pipeline.writeWithToken(ticket.token, (tx) async {
    if ((result == null) == (failure == null)) {
      throw const AppFailure(
        FailureCode.invalidMetadata,
        'Naming must have either a validated result or a failure.',
      );
    }
    final row = await _track(tx, ticket);
    final current = row['revision'] == ticket.revision;
    final original = SongMetadata.fromJson(
      jsonDecode(row['metadata'] as String) as Map<String, dynamic>,
    );
    final overrides = (jsonDecode(row['overrides'] as String) as List)
        .cast<String>();
    var metadata = original;
    if (current && result != null) {
      metadata = original.merge(
        result.metadata,
        MetadataField.values.where((f) => !overrides.contains(f.name)).toSet(),
      );
    }
    if (current && failure != null && !overrides.contains('needsReview')) {
      metadata = SongMetadata(
        title: metadata.title,
        artists: metadata.artists,
        featuredArtists: metadata.featuredArtists,
        album: metadata.album,
        version: metadata.version,
        needsReview: true,
      );
    }
    await tx.update(
      'enrichment',
      {
        'naming': current ? (failure == null ? 'complete' : 'failed') : 'stale',
        'naming_failure': failure?.name,
        'reason': current ? result?.reason : 'A newer edit kept its metadata; retry details for the current revision.',
        'model': options.model,
        'prompt_version': namingPromptVersion,
        'schema_version': namingSchemaVersion,
      },
      where: 'track_id=?',
      whereArgs: [ticket.token.trackId],
    );
    if (current) {
      await tx.update(
        'tracks',
        {
          'metadata': jsonEncode(metadata.toJson()),
          if (result != null)
            'suggestion': jsonEncode(result.metadata.toJson()),
          'revision': ticket.revision + 1,
        },
        where: 'id=?',
        whereArgs: [ticket.token.trackId],
      );
      // Changed naming identity cannot keep artwork from an older recording.
      if (artworkKey(original) != artworkKey(metadata)) {
        await invalidateAutomaticArtwork(tx, ticket.token.trackId!);
      }
    }
    await _touch(tx, ticket.token.jobId);
    return current && result != null;
  });

  Future<void> artworkStarted(EnrichmentTicket ticket) =>
      pipeline.writeWithToken(ticket.token, (tx) async {
        await _track(tx, ticket);
        await tx.update(
          'enrichment',
          {'artwork': 'running', 'artwork_failure': null},
          where: 'track_id=? AND artwork_override=0',
          whereArgs: [ticket.token.trackId],
        );
        await _touch(tx, ticket.token.jobId);
      });

  Future<bool> artwork(
    EnrichmentTicket ticket,
    int revision, {
    AssetRecord? asset,
    Map<String, Object?>? provenance,
    FailureCode? failure,
  }) => pipeline.writeWithToken(ticket.token, (tx) async {
    if ((asset == null) == (failure == null) ||
        (asset == null && provenance != null)) {
      throw const AppFailure(
        FailureCode.artworkInvalid,
        'Artwork must have either a verified cover or a failure.',
      );
    }
    final row = await _track(tx, ticket);
    final record = (await tx.query(
      'enrichment',
      where: 'track_id=?',
      whereArgs: [ticket.token.trackId],
    )).single;
    if (row['revision'] != revision || record['artwork_override'] == 1) {
      if (record['artwork_override'] != 1) {
        await invalidateAutomaticArtwork(tx, ticket.token.trackId!);
      }
      return false;
    }
    if (asset != null &&
        (asset.kind != AssetKind.artwork ||
            asset.jobId != ticket.token.jobId ||
            asset.trackId != ticket.token.trackId ||
            asset.bytes <= 0 ||
            asset.bytes > cacheBytes ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(asset.sha256) ||
            asset.relativePath !=
                PrivatePaths.asset(asset.jobId, asset.id, asset.kind) ||
            provenance == null ||
            provenance['sha256'] != asset.sha256)) {
      throw const AppFailure(
        FailureCode.artworkInvalid,
        'The verified cover does not belong to this track.',
      );
    }
    if (asset != null) {
      validateArtworkEvidence(
        provenance!,
        SongMetadata.fromJson(
          jsonDecode(row['metadata'] as String) as Map<String, dynamic>,
        ),
        asset.sha256,
      );
    }
    await tx.update(
      'assets',
      {'active': 0},
      where: "track_id=? AND kind='artwork'",
      whereArgs: [ticket.token.trackId],
    );
    if (asset != null) {
      await tx.insert('assets', {
        'id': asset.id,
        'job_id': asset.jobId,
        'track_id': asset.trackId,
        'kind': 'artwork',
        'relative_path': asset.relativePath,
        'sha256': asset.sha256,
        'bytes': asset.bytes,
        'active': 1,
      });
    }
    if (asset != null) {
      final metadata = SongMetadata.fromJson(
        jsonDecode(row['metadata'] as String) as Map<String, dynamic>,
      );
      final overrides = jsonDecode(row['overrides'] as String) as List;
      if (metadata.album == null && !overrides.contains('album')) {
        final updated = SongMetadata(
          title: metadata.title,
          artists: metadata.artists,
          featuredArtists: metadata.featuredArtists,
          album: provenance!['album'] as String,
          version: metadata.version,
          needsReview: metadata.needsReview,
        );
        await tx.rawUpdate(
          'UPDATE tracks SET metadata=?,revision=revision+1 WHERE id=?',
          [jsonEncode(updated.toJson()), ticket.token.trackId],
        );
      }
    }
    await tx.update(
      'enrichment',
      {
        'artwork': asset != null
            ? 'matched'
            : failure == FailureCode.artworkUncertain
            ? 'unavailable'
            : 'failed',
        'artwork_failure': failure?.name,
        'artwork_asset_id': asset?.id,
        'provenance': provenance == null ? null : jsonEncode(provenance),
      },
      where: 'track_id=?',
      whereArgs: [ticket.token.trackId],
    );
    await _touch(tx, ticket.token.jobId);
    return true;
  });

  Future<void> finish(EnrichmentTicket ticket) =>
      pipeline.writeWithToken(ticket.token, (tx) async {
        await _track(tx, ticket);
        await tx.rawUpdate(
          "UPDATE tracks SET phase='ready',revision=revision+1 WHERE id=?",
          [ticket.token.trackId],
        );
        await tx.update(
          'attempts',
          {
            'status': 'complete',
            'checkpoint': jsonEncode(
              Checkpoint(step: CheckpointStep.enriched).toJson(),
            ),
            'updated_at': _now,
          },
          where: 'id=?',
          whereArgs: [ticket.token.id],
        );
        await _touch(tx, ticket.token.jobId);
      });

  /// Reserve the per-device request slot transactionally. A quota cooldown is
  /// persisted across restarts; long cooldowns fail promptly instead of waiting.
  Future<Duration> reserve(String provider, Duration spacing) =>
      _write((tx) async {
        final now = _now;
        final rows = await tx.query(
          'provider_state',
          where: 'provider=?',
          whereArgs: [provider],
        );
        final next = rows.isEmpty ? now : rows.single['not_before'] as int;
        if (next - now > 30000) {
          throw const AppFailure(
            FailureCode.aiRateLimited,
            'The provider is cooling down. Retry later.',
            retryable: true,
          );
        }
        final start = next > now ? next : now;
        await tx.insert('provider_state', {
          'provider': provider,
          'not_before': start + spacing.inMilliseconds,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        return Duration(milliseconds: start - now);
      });
  Future<void> cooldown(String provider, Duration wait) => _write((tx) async {
    final duration = wait.inSeconds.clamp(1, 86400);
    final rows = await tx.query(
      'provider_state',
      where: 'provider=?',
      whereArgs: [provider],
    );
    final next = _now + duration * 1000;
    await tx.insert('provider_state', {
      'provider': provider,
      'not_before': rows.isNotEmpty && (rows.single['not_before'] as int) > next
          ? rows.single['not_before']
          : next,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  });

  Future<void> pruneCache() => db
      .delete('artwork_cache', where: 'expires_at<=?', whereArgs: [_now])
      .then((_) {});

  String _key(SongMetadata metadata) =>
      sha256.convert(utf8.encode(artworkKey(metadata))).toString();
  Future<CachedArtwork?> cached(SongMetadata metadata) async {
    final rows = await db.query(
      'artwork_cache',
      where: 'cache_key=? AND expires_at>?',
      whereArgs: [_key(metadata), _now],
    );
    if (rows.isEmpty) return null;
    final row = rows.single,
        bytes = Uint8List.fromList((row['image'] as List).cast<int>());
    if (bytes.isEmpty ||
        bytes.length > cacheBytes ||
        sha256.convert(bytes).toString() != row['sha256']) {
      await db.delete(
        'artwork_cache',
        where: 'cache_key=?',
        whereArgs: [_key(metadata)],
      );
      return null;
    }
    try {
      final provenance = (jsonDecode(
        row['provenance'] as String,
      ) as Map<String, dynamic>).cast<String, Object?>();
      validateArtworkEvidence(provenance, metadata, row['sha256'] as String);
      return CachedArtwork(bytes, provenance);
    } catch (_) {
      await evict(metadata);
      return null;
    }
  }

  Future<void> evict(SongMetadata metadata) => db
      .delete(
        'artwork_cache',
        where: 'cache_key=?',
        whereArgs: [_key(metadata)],
      )
      .then((_) {});
  Future<void> cache(
    SongMetadata metadata,
    Uint8List bytes,
    Map<String, Object?> provenance,
  ) => _write((tx) async {
    if (bytes.isEmpty ||
        bytes.length > cacheBytes ||
        sha256.convert(bytes).toString() != provenance['sha256']) {
      throw const AppFailure(
        FailureCode.artworkInvalid,
        'The cover cache did not pass validation.',
      );
    }
    validateArtworkEvidence(
      provenance,
      metadata,
      sha256.convert(bytes).toString(),
    );
    await tx.delete('artwork_cache', where: 'expires_at<=?', whereArgs: [_now]);
    await tx.insert('artwork_cache', {
      'cache_key': _key(metadata),
      'image': bytes,
      'sha256': provenance['sha256'],
      'provenance': jsonEncode(provenance),
      'expires_at': _now + 86400000,
      'created_at': _now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await tx.execute(
      'DELETE FROM artwork_cache WHERE cache_key NOT IN (SELECT cache_key FROM artwork_cache ORDER BY created_at DESC,cache_key LIMIT 16)',
    );
  });
}
