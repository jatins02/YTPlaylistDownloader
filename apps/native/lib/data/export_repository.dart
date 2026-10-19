import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqlite_api.dart';

import '../domain/device_export.dart';
import '../domain/failure.dart';
import '../domain/models.dart';
import 'job_repository.dart';
import 'pipeline_repository.dart';
import 'private_workspace.dart';

final class ExportRepository {
  ExportRepository(this.jobs);
  final JobRepository jobs;
  int get _now => DateTime.now().toUtc().millisecondsSinceEpoch;
  Future<T> _write<T>(Future<T> Function(Transaction) action) async {
    try {
      return await jobs.db.transaction(action);
    } on AppFailure {
      rethrow;
    } catch (_) {
      throw const AppFailure(
        FailureCode.storageUnavailable,
        'Export state could not be saved. Your review and completed private files are retained.',
      );
    }
  }

  ExportSnapshot _snapshot(Map<String, Object?> row) {
    final result = ExportSnapshot(
      id: row['id'] as String,
      jobId: row['job_id'] as String,
      jobRevision: row['job_revision'] as int,
      hash: row['snapshot_hash'] as String,
      json: row['snapshot'] as String,
    );
    if (sha256.convert(utf8.encode(result.json)).toString() != result.hash) {
      throw const AppFailure(
        FailureCode.corruptData,
        'The frozen export failed its integrity check.',
      );
    }
    return result;
  }

  Never _conflict() => throw const AppFailure(
    FailureCode.conflict,
    'This export changed or was stopped. Return to the current review.',
  );

  Future<ExportPublication?> current(String jobId) => _write((tx) async {
    final rows = await tx.rawQuery(
      '''SELECT e.*,p.record,p.record_hash FROM exports e
      JOIN jobs j ON j.id=e.job_id JOIN export_publications p ON p.export_id=e.id
      WHERE e.job_id=? AND e.status='complete' AND j.phase='exportReady' AND j.revision=e.job_revision+2''',
      [jobId],
    );
    if (rows.isEmpty) return null;
    if (rows.length != 1) _conflict();
    final row = rows.single;
    final record = row['record'] as String;
    if (sha256.convert(utf8.encode(record)).toString() != row['record_hash']) {
      throw const AppFailure(
        FailureCode.corruptData,
        'The prepared export record failed its integrity check.',
      );
    }
    return ExportPublication.fromJson(_snapshot(row), record);
  });

  Future<void> requireSnapshot(ExportSnapshot snapshot) => _write((tx) async {
    final rows = await tx.rawQuery(
      '''SELECT e.* FROM exports e JOIN jobs j ON j.id=e.job_id
      WHERE e.id=? AND e.job_id=? AND e.status='planned' AND j.phase='exporting' AND j.revision=e.job_revision+1''',
      [snapshot.id, snapshot.jobId],
    );
    if (rows.length != 1 ||
        _snapshot(rows.single).json != snapshot.json ||
        rows.single['snapshot_hash'] != snapshot.hash) {
      _conflict();
    }
  });

  Future<void> publish(AttemptToken token, ExportPublication publication) =>
      PipelineRepository(jobs).writeWithToken(token, (tx) async {
        publication.validate();
        final snapshot = publication.snapshot;
        if (token.stage != TaskStage.export ||
            token.trackId != null ||
            token.jobId != snapshot.jobId) {
          _conflict();
        }
        final rows = await tx.rawQuery(
          '''SELECT e.* FROM exports e JOIN jobs j ON j.id=e.job_id
        WHERE e.id=? AND e.status='planned' AND j.phase='exporting' AND j.revision=e.job_revision+1''',
          [snapshot.id],
        );
        if (rows.length != 1 ||
            _snapshot(rows.single).json != snapshot.json ||
            rows.single['snapshot_hash'] != snapshot.hash) {
          _conflict();
        }
        final record = publication.json;
        await tx.insert('export_publications', {
          'export_id': snapshot.id,
          'record': record,
          'record_hash': sha256.convert(utf8.encode(record)).toString(),
          'created_at': _now,
        });
        await tx.update(
          'exports',
          {'status': 'complete'},
          where: 'id=?',
          whereArgs: [snapshot.id],
        );
        await tx.update(
          'attempts',
          {
            'status': 'complete',
            'updated_at': _now,
            'checkpoint': jsonEncode({
              'step': 'published',
              'export_id': snapshot.id,
            }),
          },
          where: 'id=?',
          whereArgs: [token.id],
        );
        await tx.update(
          'jobs',
          {
            'phase': 'exportReady',
            'revision': snapshot.jobRevision + 2,
            'updated_at': _now,
            'error_code': null,
          },
          where: 'id=?',
          whereArgs: [snapshot.jobId],
        );
      });

  /// Fence before terminating native work. A late completion cannot publish.
  Future<void> stop(String jobId, {FailureCode? failure}) => _write((tx) async {
    final rows = await tx.query(
      'jobs',
      where: "id=? AND phase='exporting'",
      whereArgs: [jobId],
    );
    if (rows.isEmpty) return;
    await tx.rawUpdate(
      "UPDATE attempts SET status='cancelled',generation=generation+1,error_code=?,updated_at=? WHERE job_id=? AND stage='export' AND status IN ('running','retryable')",
      [failure?.name ?? 'operationCancelled', _now, jobId],
    );
    await tx.update(
      'exports',
      {'status': 'failed'},
      where: "job_id=? AND status='planned'",
      whereArgs: [jobId],
    );
    await tx.rawUpdate(
      "UPDATE jobs SET phase='reviewReady',revision=revision+1,error_code=?,updated_at=? WHERE id=?",
      [failure?.name, _now, jobId],
    );
  });

  Future<void> beginDelivery(
    ExportPublication publication,
    ExportFile file, {
    required String id,
    required String destination,
    required String temporary,
    required int device,
    required int inode,
  }) => _write((tx) async {
    publication.validate();
    PrivatePaths.validateId(id);
    final members = publication.files.where((f) => f.id == file.id).toList();
    if (members.length != 1 ||
        jsonEncode(members.single.toJson()) != jsonEncode(file.toJson()) ||
        device < 0 ||
        inode < 0 ||
        (inode == 0 && device != 0) ||
        !p.isAbsolute(destination) ||
        !p.isAbsolute(temporary) ||
        p.dirname(destination) != p.dirname(temporary) ||
        p.basename(temporary) != '.ytpd-$id.part') {
      _conflict();
    }
    final rows = await tx.rawQuery(
      '''SELECT e.id FROM exports e JOIN jobs j ON j.id=e.job_id
        JOIN export_publications p ON p.export_id=e.id WHERE e.id=? AND e.status='complete'
        AND j.phase='exportReady' AND j.revision=e.job_revision+2 AND p.record=?''',
      [publication.snapshot.id, publication.json],
    );
    if (rows.length != 1 ||
        !publication.files.any(
          (f) => f.id == file.id && f.kind != ExportFileKind.manifest,
        )) {
      _conflict();
    }
    final writing = await tx.rawQuery(
      "SELECT id FROM export_deliveries WHERE status='writing' LIMIT 1",
    );
    if (writing.isNotEmpty) _conflict();
    final stale = await tx.rawQuery(
      // Keep one completed receipt per published file as durable download
      // coverage; only failed/interrupted or superseded receipts are disposable.
      """SELECT d.id FROM export_deliveries d JOIN exports e ON e.id=d.export_id
      WHERE e.job_id=? AND d.cleanup_pending=0 AND d.status!='writing'
      AND (d.status!='complete' OR EXISTS (
        SELECT 1 FROM export_deliveries n WHERE n.export_id=d.export_id
        AND n.file_id=d.file_id AND n.status='complete'
        AND (n.created_at>d.created_at OR (n.created_at=d.created_at AND n.id>d.id))
      )) ORDER BY d.created_at DESC,d.id DESC LIMIT -1 OFFSET 99""",
      [publication.snapshot.jobId],
    );
    for (final row in stale) {
      await tx.delete(
        'export_deliveries',
        where: 'id=?',
        whereArgs: [row['id']],
      );
    }
    await tx.insert('export_deliveries', {
      'id': id,
      'export_id': publication.snapshot.id,
      'file_id': file.id,
      'filename': p.basename(destination),
      'destination': destination,
      'temporary': temporary,
      'device': device,
      'inode': inode,
      'status': 'writing',
      'created_at': _now,
      'updated_at': _now,
    });
  });

  Future<void> bindStaging(
    String id, {
    required int device,
    required int inode,
  }) => _write((tx) async {
    if (device < 0 || inode <= 0) _conflict();
    final changed = await tx.update(
      'export_deliveries',
      {'device': device, 'inode': inode, 'updated_at': _now},
      where: "id=? AND status='writing' AND device=0 AND inode=0",
      whereArgs: [id],
    );
    if (changed != 1) _conflict();
  });
  Future<void> finishDelivery(String id, {FailureCode? failure}) => _write((
    tx,
  ) async {
    final changed = await tx.update(
      'export_deliveries',
      {
        'status': failure == null ? 'complete' : 'failed',
        'error_code': failure?.name,
        'updated_at': _now,
      },
      where:
          "id=? AND status='writing'${failure == null ? ' AND inode>0' : ''}",
      whereArgs: [id],
    );
    if (changed != 1 && failure == null) _conflict();
  });
  Future<List<Map<String, Object?>>> interruptedDeliveries() =>
      _write((tx) async {
        await tx.rawUpdate(
          "UPDATE export_deliveries SET status='interrupted',error_code='operationCancelled',updated_at=? WHERE status='writing'",
          [_now],
        );
        return tx.query(
          'export_deliveries',
          where: "cleanup_pending=1 AND status!='writing'",
          orderBy: 'updated_at,id',
          limit: 100,
        );
      });
  Future<void> stagingCleaned(String id, {bool cleaned = true}) =>
      _write((tx) async {
        await tx.update(
          'export_deliveries',
          {'cleanup_pending': cleaned ? 0 : 1, 'updated_at': _now},
          where: 'id=?',
          whereArgs: [id],
        );
      });
  Future<void> expireCompleted(String jobId) => _write((tx) async {
    final writing = await tx.rawQuery(
      "SELECT d.id FROM export_deliveries d JOIN exports e ON e.id=d.export_id WHERE e.job_id=? AND d.status='writing' LIMIT 1",
      [jobId],
    );
    if (writing.isNotEmpty) _conflict();
    await tx.rawUpdate(
      "UPDATE jobs SET phase='cancelled',revision=revision+1,error_code='expiredMedia',updated_at=? WHERE id=? AND phase='exportReady'",
      [_now, jobId],
    );
  });
  Future<DeliveryReceipt?> latestReceipt(String exportId) => _write((tx) async {
    final rows = await tx.query(
      'export_deliveries',
      where: "export_id=? AND status='complete'",
      whereArgs: [exportId],
      orderBy: 'updated_at DESC,id DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return DeliveryReceipt(
      row['id'] as String,
      exportId,
      row['file_id'] as String,
      row['filename'] as String,
    );
  });

  /// Only confirmed destination receipts count, including older snapshots.
  /// Private preparation, cancellation and interrupted transfers never count.
  Future<Set<String>> savedTrackIds(String jobId) =>
      _write((tx) => _savedTrackIds(tx, jobId));

  Future<Set<String>> _savedTrackIds(Transaction tx, String jobId) async {
    final rows = await tx.rawQuery(
      '''SELECT DISTINCT e.*,p.record,p.record_hash,d.file_id
      FROM exports e JOIN export_publications p ON p.export_id=e.id
      JOIN export_deliveries d ON d.export_id=e.id
      WHERE e.job_id=? AND e.status='complete' AND d.status='complete' ''',
      [jobId],
    );
    final saved = <String>{};
    for (final row in rows) {
      final record = row['record'] as String;
      if (sha256.convert(utf8.encode(record)).toString() !=
          row['record_hash']) {
        throw const AppFailure(
          FailureCode.corruptData,
          'Saved-song history failed verification. Your external files are unchanged.',
        );
      }
      final publication = ExportPublication.fromJson(_snapshot(row), record);
      final file = publication.files
          .where((f) => f.id == row['file_id'])
          .toList();
      if (file.length != 1 || file.single.kind == ExportFileKind.manifest) {
        throw const AppFailure(
          FailureCode.corruptData,
          'Saved-song history could not be read safely.',
        );
      }
      if (file.single.kind == ExportFileKind.zip) {
        saved.addAll(publication.tracks.map((f) => f.trackId!));
      } else {
        saved.add(file.single.trackId!);
      }
    }
    return Set.unmodifiable(saved);
  }

  /// Atomically unlock the review and select ready songs without saved receipts.
  /// Selection never changes underneath an active destination transfer.
  Future<void> reviewRemaining(String jobId, int revision) => _write((
    tx,
  ) async {
    final jobs = await tx.query(
      'jobs',
      where: "id=? AND revision=? AND phase='exportReady'",
      whereArgs: [jobId, revision],
    );
    final writing = await tx.rawQuery(
      '''SELECT d.id FROM export_deliveries d
      JOIN exports e ON e.id=d.export_id WHERE e.job_id=? AND d.status='writing' LIMIT 1''',
      [jobId],
    );
    if (jobs.length != 1 || writing.isNotEmpty) _conflict();
    final saved = await _savedTrackIds(tx, jobId);
    if (saved.isNotEmpty) {
      final tracks = await tx.query(
        'tracks',
        where: 'job_id=?',
        whereArgs: [jobId],
      );
      for (final track in tracks) {
        final selected =
            track['phase'] == 'ready' && !saved.contains(track['id']);
        if (track['selected'] != (selected ? 1 : 0)) {
          await tx.rawUpdate(
            'UPDATE tracks SET selected=?,revision=revision+1 WHERE id=?',
            [selected ? 1 : 0, track['id']],
          );
        }
      }
    }
    await tx.update(
      'jobs',
      {'phase': 'reviewReady', 'revision': revision + 1, 'updated_at': _now},
      where: 'id=?',
      whereArgs: [jobId],
    );
  });
  Future<void> fenceDeliveries(String jobId) => _write((tx) async {
    await tx.rawUpdate(
      "UPDATE export_deliveries SET status='interrupted',error_code='operationCancelled',updated_at=? WHERE status='writing' AND export_id IN (SELECT id FROM exports WHERE job_id=?)",
      [_now, jobId],
    );
  });
}
