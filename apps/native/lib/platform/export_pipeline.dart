import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../data/export_repository.dart';
import '../data/export_workspace.dart';
import '../data/job_repository.dart';
import '../data/media_workspace.dart';
import '../domain/device_export.dart';
import '../domain/failure.dart';
import '../domain/models.dart';
import '../metadata/native_tag_adapter.dart';
import 'export_destination.dart';
import 'guarded_process.dart';
import 'native_export_tools.dart';

/// Single owner of export preparation/delivery. Published bundles are immutable;
/// only the database's fenced publication makes a private directory reusable.
final class ExportPipeline {
  ExportPipeline({
    required this.jobs,
    required this.media,
    required this.tools,
    required this.tags,
    required this.destination,
    required this.stopPlayback,
    required this.budget,
  });
  final JobRepository jobs;
  final MediaWorkspace media;
  final NativeExportTools tools;
  final NativeTagAdapter tags;
  final ExportDestination destination;
  final Future<void> Function() stopPlayback;
  final Future<void> Function(String, ProcessScope, Directory) budget;
  late final repository = ExportRepository(jobs);
  late final files = ExportWorkspace(media);
  String? jobId;
  int? _requestedRevision;
  Future<ExportPublication>? _build;
  Future<DeliveryReceipt?>? _delivery;
  ProcessScope? _scope, _archiveScope;
  Completer<void>? _stopped;
  Future<void>? _stopping;
  bool get busy => _build != null || _delivery != null || _stopping != null;

  Future<void> initialize() async {
    await tools.verify(media.workspace.root);
    for (final row in await repository.interruptedDeliveries()) {
      final work = await media.work(
        (await _deliveryJob(row['export_id'] as String)),
        const Uuid().v4(),
      );
      try {
        final cleaned = await _cleanupDestination(_journalRequest(row), work);
        try {
          await repository.stagingCleaned(
            row['id'] as String,
            cleaned: cleaned,
          );
        } on AppFailure {
          /* Retry the exact journal at startup. */
        }
      } finally {
        await work.delete(recursive: true);
      }
    }
    for (final job in await jobs.listJobs()) {
      await cleanup(job.id);
    }
  }

  Future<String> _deliveryJob(String id) async =>
      (await jobs.db.query(
            'exports',
            columns: ['job_id'],
            where: 'id=?',
            whereArgs: [id],
          )).single['job_id']
          as String;
  Map<String, Object?> _journalRequest(Map<String, Object?> row) => {
    'delivery_id': row['id'],
    'destination': row['destination'],
    'temporary': row['temporary'],
    'device': row['device'],
    'inode': row['inode'],
    'private_root': media.workspace.root.path,
  };
  Future<bool> _cleanupDestination(
    Map<String, Object?> request,
    Directory work,
  ) async {
    final scope = tools.tools.scope(maxFileBytes: media.maxArchiveBytes);
    try {
      await tools.run('cleanup-destination', request, scope, work);
      return true;
    } on AppFailure {
      /* Keep the exact inode journal for a later cleanup retry. */
      return false;
    } finally {
      scope.cancel();
    }
  }

  Future<void> cleanup(String id) async {
    final rows = await jobs.db.rawQuery(
      "SELECT e.id FROM exports e JOIN export_publications p ON p.export_id=e.id WHERE e.job_id=? AND e.status='complete'",
      [id],
    );
    await files.cleanup(id, rows.map((r) => r['id'] as String).toSet());
  }

  Future<ExportPublication> prepare(
    String id,
    int revision, {
    ExportSnapshot? frozen,
  }) {
    if (_build != null && jobId == id && _requestedRevision == revision) {
      return _build!;
    }
    if (busy) {
      return Future.error(
        const AppFailure(
          FailureCode.conflict,
          'Another export or save is active.',
        ),
      );
    }
    jobId = id;
    _requestedRevision = revision;
    _stopped = Completer<void>();
    return _build = _prepare(id, revision, frozen).whenComplete(() {
      _scope?.cancel();
      _archiveScope?.cancel();
      _scope = _archiveScope = null;
      _build = null;
      jobId = null;
      _stopped = null;
    });
  }

  Future<ExportPublication> _prepare(
    String id,
    int revision,
    ExportSnapshot? frozen,
  ) async {
    final scope = _scope = tools.tools.scope(
      maxFileBytes: media.limits.maxFileBytes,
    );
    final archiveScope = _archiveScope = tools.tools.scope(
      maxFileBytes: media.maxArchiveBytes,
    );
    final deadline = Timer(media.limits.jobTimeout, () {
      const error = AppFailure(
        FailureCode.processTimeout,
        'Export preparation reached its time limit. Your review is kept.',
      );
      scope.cancel(cause: error);
      archiveScope.cancel(cause: error);
    });
    Directory? work;
    var started = false;
    try {
      await stopPlayback();
      scope.check();
      final existing = await repository.current(id);
      if (existing != null) {
        if (frozen != null &&
            (frozen.id != existing.snapshot.id ||
                frozen.hash != existing.snapshot.hash ||
                frozen.json != existing.snapshot.json)) {
          throw const AppFailure(
            FailureCode.conflict,
            'This request does not match the current frozen export.',
          );
        }
        final current = await jobs.getJob(id);
        if (revision != current.revision &&
            revision != existing.snapshot.jobRevision) {
          throw const AppFailure(
            FailureCode.conflict,
            'Review the current selection before saving.',
          );
        }
        work = await media.work(id, const Uuid().v4());
        await _verify(
          existing,
          archiveScope,
          work,
          () => budget(id, scope, work!),
        );
        scope.check();
        return existing;
      }
      final snapshot = frozen ?? await jobs.freezeExport(id, revision);
      started = true;
      await repository.requireSnapshot(snapshot);
      scope.check();
      final token = await jobs.beginAttempt(jobId: id, stage: TaskStage.export);
      work = await media.work(id, token.id);
      await cleanup(id);
      Future<void> monitor() => budget(id, scope, work!);
      await monitor();
      final data = jsonDecode(snapshot.json) as Map<String, dynamic>;
      final rows = (data['tracks'] as List).cast<Map<String, dynamic>>();
      if (rows.length > media.limits.maxTracks) {
        throw const AppFailure(
          FailureCode.limitExceeded,
          'This export exceeds the verified track limit.',
        );
      }
      final naming = await tools.run(
        'names',
        {
          'tracks': rows
              .map(
                (r) => {
                  'track_id': r['track_id'],
                  'name': SongMetadata.fromJson(
                    r['metadata'] as Map<String, dynamic>,
                  ).displayName,
                },
              )
              .toList(),
        },
        scope,
        work,
      );
      final names = (naming['names'] as Map).cast<String, String>();
      if (names.length != rows.length ||
          !rows.every((r) => names.containsKey(r['track_id']))) {
        throw const AppFailure(
          FailureCode.exportInvalid,
          'Export names could not be matched to their tracks.',
        );
      }
      final bundle = await Directory(p.join(work.path, 'bundle')).create();
      final exported = <ExportFile>[];
      for (final row in rows) {
        scope.check();
        final trackId = row['track_id'] as String;
        final tagged = await tags.prepare(
          snapshot,
          trackId,
          scope,
          work,
          monitor,
        );
        final file = ExportFile(
          id: const Uuid().v4(),
          kind: ExportFileKind.mp3,
          trackId: trackId,
          filename: names[trackId]!,
          sha256: tagged.sha256,
          bytes: await tagged.file.length(),
        );
        await tagged.file.rename(
          p.join(bundle.path, ExportWorkspace.basename(file)),
        );
        exported.add(file);
        await monitor();
      }
      final content = jsonEncode({
        'version': 1,
        'export_id': snapshot.id,
        'job_id': id,
        'snapshot_hash': snapshot.hash,
        'files': exported.map((f) => f.toJson()).toList(),
      });
      final contentBytes = utf8.encode(content);
      final manifest = ExportFile(
        id: const Uuid().v4(),
        kind: ExportFileKind.manifest,
        filename: 'manifest.json',
        sha256: sha256.convert(contentBytes).toString(),
        bytes: contentBytes.length,
      );
      final manifestFile = File(
        p.join(bundle.path, ExportWorkspace.basename(manifest)),
      );
      await manifestFile.create(exclusive: true);
      await manifestFile.writeAsBytes(contentBytes, flush: true);
      final zipId = const Uuid().v4();
      final zip = File(p.join(bundle.path, '$zipId.zip'));
      final request = _archiveRequest(
        exported,
        manifest,
        (file) => p.join(bundle.path, ExportWorkspace.basename(file)),
        zip.path,
      );
      final result = await tools.run(
        'archive',
        request,
        archiveScope,
        work,
        monitor: monitor,
      );
      final archive = ExportFile(
        id: zipId,
        kind: ExportFileKind.zip,
        filename: 'Playlist-${snapshot.id.substring(0, 8)}.zip',
        sha256: result['sha256'] as String,
        bytes: result['bytes'] as int,
      );
      final publication = ExportPublication(
        snapshot: snapshot,
        files: [...exported, manifest, archive],
        contentManifest: content,
      );
      if (await media.digest(zip.path) != archive.sha256 ||
          await zip.length() != archive.bytes) {
        throw const AppFailure(
          FailureCode.exportInvalid,
          'The verified archive changed before publication.',
        );
      }
      await monitor();
      scope.check();
      archiveScope.check();
      final target = await files.directory(id, snapshot.id);
      if (await FileSystemEntity.type(target.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const AppFailure(
          FailureCode.conflict,
          'This export identity is already reserved.',
        );
      }
      await bundle.rename(target.path);
      scope.check();
      await tools.run(
        'sync-publication',
        {'directory': target.path, 'private_root': media.workspace.root.path},
        scope,
        work,
        monitor: monitor,
      );
      scope.check();
      await repository.publish(token, publication);
      return publication;
    } on AppFailure catch (error) {
      if (started) {
        await repository.stop(
          id,
          failure: error.code == FailureCode.operationCancelled
              ? null
              : error.code,
        );
      }
      rethrow;
    } catch (_) {
      if (started) {
        await repository.stop(id, failure: FailureCode.exportInvalid);
      }
      throw const AppFailure(
        FailureCode.exportInvalid,
        'Export preparation could not finish safely. Your review is kept.',
      );
    } finally {
      deadline.cancel();
      if (work != null) {
        try {
          await work.delete(recursive: true);
        } on FileSystemException {
          /* Private cleanup retries. */
        }
      }
    }
  }

  Map<String, Object?> _archiveRequest(
    List<ExportFile> tracks,
    ExportFile manifest,
    String Function(ExportFile) path,
    String archive,
  ) => {
    'files': tracks.map((f) => {...f.toJson(), 'path': path(f)}).toList(),
    'manifest': {...manifest.toJson(), 'path': path(manifest)},
    'archive': archive,
    'max_file_bytes': media.limits.maxFileBytes,
    'max_archive_bytes': media.maxArchiveBytes,
  };
  Future<void> _verify(
    ExportPublication publication,
    ProcessScope scope,
    Directory work,
    Future<void> Function() monitor,
  ) async {
    publication.validate();
    final paths = <String, String>{};
    for (final file in publication.files) {
      paths[file.id] = (await files.file(publication, file)).path;
    }
    final result = await tools.run(
      'verify',
      _archiveRequest(
        publication.tracks,
        publication.manifest,
        (f) => paths[f.id]!,
        paths[publication.archive.id]!,
      ),
      scope,
      work,
      monitor: monitor,
    );
    if (result['bytes'] != publication.archive.bytes ||
        result['sha256'] != publication.archive.sha256) {
      throw const AppFailure(
        FailureCode.exportInvalid,
        'The prepared archive failed its checksum check. Return to review and prepare again.',
      );
    }
  }

  Future<DeliveryReceipt?> deliver(
    ExportPublication publication,
    String fileId,
  ) {
    if (busy) {
      return Future.error(
        const AppFailure(
          FailureCode.conflict,
          'Another export or save is active.',
        ),
      );
    }
    jobId = publication.snapshot.jobId;
    _stopped = Completer<void>();
    return _delivery = _deliver(publication, fileId).whenComplete(() {
      _scope?.cancel();
      _archiveScope?.cancel();
      _scope = _archiveScope = null;
      _delivery = null;
      jobId = null;
      _stopped = null;
    });
  }

  Future<DeliveryReceipt?> _deliver(
    ExportPublication publication,
    String fileId,
  ) async {
    final id = publication.snapshot.jobId;
    final scope = _scope = tools.tools.scope(
      maxFileBytes: media.maxArchiveBytes,
    );
    final archiveScope = _archiveScope = tools.tools.scope(
      maxFileBytes: media.maxArchiveBytes,
    );
    Directory? work;
    Map<String, Object?>? request;
    var journaled = false;
    final deliveryId = const Uuid().v4();
    try {
      await stopPlayback();
      scope.check();
      final current = await repository.current(id);
      if (current?.json != publication.json ||
          current?.snapshot.id != publication.snapshot.id) {
        throw const AppFailure(
          FailureCode.conflict,
          'Return to the current prepared export before saving.',
        );
      }
      final candidates = publication.files
          .where((f) => f.id == fileId && f.kind != ExportFileKind.manifest)
          .toList();
      if (candidates.length != 1) {
        throw const AppFailure(
          FailureCode.invalidMetadata,
          'Choose a prepared MP3 or ZIP.',
        );
      }
      final file = candidates.single;
      work = await media.work(id, deliveryId);
      await _verify(
        publication,
        archiveScope,
        work,
        () => budget(id, scope, work!),
      );
      scope.check();
      final chosen = await Future.any<String?>([
        destination.choose(file),
        _stopped!.future.then((_) => null),
      ]);
      if (chosen == null) return null;
      scope.check();
      final extension = file.kind == ExportFileKind.zip ? '.zip' : '.mp3';
      if (!p.isAbsolute(chosen) ||
          p.extension(chosen).toLowerCase() != extension ||
          chosen.contains('\x00')) {
        throw const AppFailure(
          FailureCode.destinationUnavailable,
          'Choose a local filename with the requested extension. Your prepared files are kept.',
        );
      }
      request = {
        'delivery_id': deliveryId,
        'destination': chosen,
        'private_root': media.workspace.root.path,
        'source': (await files.file(publication, file)).path,
        'bytes': file.bytes,
        'sha256': file.sha256,
        'max_bytes': media.maxArchiveBytes,
        'free_reserve_bytes': media.limits.freeReserveBytes,
      };
      request.addAll({
        'temporary': p.join(p.dirname(chosen), '.ytpd-$deliveryId.part'),
        'device': 0,
        'inode': 0,
      });
      await repository.beginDelivery(
        publication,
        file,
        id: deliveryId,
        destination: chosen,
        temporary: request['temporary'] as String,
        device: 0,
        inode: 0,
      );
      journaled = true;
      scope.check();
      final prepared = await tools.run(
        'prepare-destination',
        request,
        scope,
        work,
      );
      if (prepared['temporary'] != request['temporary']) {
        throw const AppFailure(
          FailureCode.destinationUnavailable,
          'The destination staging identity changed. Your prepared files are kept.',
        );
      }
      request.addAll({
        'device': prepared['device'],
        'inode': prepared['inode'],
      });
      scope.check();
      await repository.bindStaging(
        deliveryId,
        device: prepared['device'] as int,
        inode: prepared['inode'] as int,
      );
      scope.check();
      final result = await tools.run(
        'transfer',
        request,
        scope,
        work,
        monitor: () => budget(id, scope, work!),
      );
      scope.check();
      if (result['sha256'] != file.sha256 || result['bytes'] != file.bytes) {
        throw const AppFailure(
          FailureCode.exportInvalid,
          'The destination did not confirm the complete verified file.',
        );
      }
      await repository.finishDelivery(deliveryId);
      return DeliveryReceipt(
        deliveryId,
        publication.snapshot.id,
        file.id,
        p.basename(chosen),
      );
    } on AppFailure catch (error) {
      if (journaled) {
        await repository.finishDelivery(deliveryId, failure: error.code);
      }
      rethrow;
    } catch (_) {
      if (journaled) {
        await repository.finishDelivery(
          deliveryId,
          failure: FailureCode.destinationUnavailable,
        );
      }
      throw const AppFailure(
        FailureCode.destinationUnavailable,
        'Saving could not finish. Your prepared files are kept; retry choosing a destination.',
      );
    } finally {
      if (work != null) {
        if (request?['inode'] != null) {
          final cleaned = await _cleanupDestination(request!, work);
          if (journaled) {
            try {
              await repository.stagingCleaned(deliveryId, cleaned: cleaned);
            } on AppFailure {
              /* Cleanup never changes a committed receipt. */
            }
          }
        }
        try {
          await work.delete(recursive: true);
        } on FileSystemException {
          /* Private startup cleanup retries. */
        }
      }
    }
  }

  Future<void> stop(String id) {
    if (jobId != id) return Future.value();
    return _stopping ??= _stop(id).whenComplete(() {
      _stopping = null;
    });
  }

  Future<void> _stop(String id) async {
    final scope = _scope, archiveScope = _archiveScope, stopped = _stopped;
    final pending = [_build, _delivery];
    try {
      await repository.stop(id);
      await repository.fenceDeliveries(id);
    } finally {
      scope?.cancel();
      archiveScope?.cancel();
      if (stopped?.isCompleted == false) stopped!.complete();
      for (final task in pending) {
        try {
          await task;
        } on AppFailure {
          /* Fenced before process termination. */
        }
      }
    }
  }
}
