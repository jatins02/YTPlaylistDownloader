import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';
import 'package:yt_playlist_downloader/data/export_repository.dart';
import 'package:yt_playlist_downloader/data/export_workspace.dart';
import 'package:yt_playlist_downloader/data/media_workspace.dart';
import 'package:yt_playlist_downloader/data/local_database.dart';
import 'package:yt_playlist_downloader/data/schema.dart';
import 'package:yt_playlist_downloader/domain/device_export.dart';
import 'package:yt_playlist_downloader/domain/failure.dart';
import 'package:yt_playlist_downloader/domain/models.dart';
import 'package:yt_playlist_downloader/domain/media_models.dart';

import 'test_support.dart';

Matcher code(FailureCode code) =>
    isA<AppFailure>().having((e) => e.code, 'code', code);
void main() {
  late Fixture fixture;
  late ExportRepository exports;
  setUp(() async {
    fixture = await Fixture.open();
    exports = ExportRepository(fixture.jobs);
  });
  tearDown(() => fixture.close());
  String chosen(String filename) =>
      p.join(fixture.root.path, 'fictional', filename);

  Future<ExportSnapshot> frozen() async {
    final job = await fixture.draft();
    await fixture.ready(await fixture.track(job));
    final review = await fixture.review(job);
    return fixture.jobs.freezeExport(job.id, review.revision);
  }

  test(
    'export orphan cleanup does not recreate a discarded private job',
    () async {
      final job = await fixture.draft();
      final directory = await fixture.workspace.ensureJob(job.id);
      await directory.delete(recursive: true);
      await ExportWorkspace(
        MediaWorkspace(fixture.workspace, const PipelineLimits()),
      ).cleanup(job.id, const {});
      expect(await Directory(directory.path).exists(), isFalse);
    },
  );

  test('schema v5 upgrade retains frozen source and adds publication and delivery journals', () async {
    final path = '${fixture.root.path}/legacy.sqlite';
    var db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 5,
        onCreate: (db, version) => Schema.migrate(db, 0, version),
      ),
    );
    final job = const Uuid().v4(), id = const Uuid().v4();
    await db.insert('jobs', {
      'id': job,
      'playlist_id': 'PLfictional',
      'source_url': 'https://youtube.com/playlist?list=PLfictional',
      'title': 'Kept',
      'phase': 'exporting',
      'revision': 1,
      'created_at': 1,
      'updated_at': 1,
    });
    await db.insert('exports', {
      'id': id,
      'job_id': job,
      'job_revision': 0,
      'snapshot_hash': 'legacy-hash',
      'snapshot': 'legacy-snapshot',
      'created_at': 1,
    });
    await db.close();
    db = await LocalDatabase.open(databaseFactoryFfi, path);
    expect(await db.getVersion(), 6);
    expect((await db.query('exports')).single['snapshot'], 'legacy-snapshot');
    expect(await db.query('export_publications'), isEmpty);
    expect(await db.query('export_deliveries'), isEmpty);
    await db.close();
  });
  test('completion is atomic and duplicate save reuses the same frozen publication', () async {
    final snapshot = await frozen();
    final publication = await publishFixture(fixture, snapshot);
    expect(
      (await fixture.jobs.getJob(snapshot.jobId)).phase,
      JobPhase.exportReady,
    );
    expect(
      (await fixture.jobs.freezeExport(
        snapshot.jobId,
        snapshot.jobRevision,
      )).id,
      snapshot.id,
    );
    expect((await exports.current(snapshot.jobId))!.json, publication.json);
    expect(await fixture.db.query('export_publications'), hasLength(1));
  });
  test(
    'a status or phase update cannot stand in for verified publication',
    () async {
      final snapshot = await frozen();
      await fixture.db.update(
        'exports',
        {'status': 'complete'},
        where: 'id=?',
        whereArgs: [snapshot.id],
      );
      final job = await fixture.jobs.getJob(snapshot.jobId);
      await expectLater(
        fixture.jobs.transition(job.id, job.revision, JobPhase.exportReady),
        throwsA(code(FailureCode.invalidTransition)),
      );
      expect(await exports.current(job.id), isNull);
    },
  );
  test('stopped export fences late publication and leaves ready audio and edits intact', () async {
    final snapshot = await frozen();
    final token = await fixture.jobs.beginAttempt(
      jobId: snapshot.jobId,
      stage: TaskStage.export,
    );
    await exports.stop(snapshot.jobId);
    await expectLater(
      exports.publish(token, publicationFixture(snapshot)),
      throwsA(code(FailureCode.conflict)),
    );
    expect(
      (await fixture.jobs.getJob(snapshot.jobId)).phase,
      JobPhase.reviewReady,
    );
    expect(
      (await fixture.jobs.listTracks(snapshot.jobId)).single.phase,
      TrackPhase.ready,
    );
    expect(await fixture.db.query('export_publications'), isEmpty);
  });
  test('storage failure rolls back publication attempt and job together, then retry succeeds', () async {
    final snapshot = await frozen();
    final publication = publicationFixture(snapshot);
    final token = await fixture.jobs.beginAttempt(
      jobId: snapshot.jobId,
      stage: TaskStage.export,
    );
    await fixture.db.execute(
      "CREATE TRIGGER fail_export BEFORE UPDATE ON exports WHEN NEW.status='complete' BEGIN SELECT RAISE(ABORT,'fixture storage failure'); END",
    );
    await expectLater(
      exports.publish(token, publication),
      throwsA(code(FailureCode.storageUnavailable)),
    );
    expect(await fixture.db.query('export_publications'), isEmpty);
    expect(
      (await fixture.jobs.getJob(snapshot.jobId)).phase,
      JobPhase.exporting,
    );
    expect(
      (await fixture.db.query(
        'attempts',
        where: 'id=?',
        whereArgs: [token.id],
      )).single['status'],
      'running',
    );
    await fixture.db.execute('DROP TRIGGER fail_export');
    await exports.publish(token, publication);
    expect((await exports.current(snapshot.jobId))!.snapshot.id, snapshot.id);
  });
  test('interrupted preparation requires a fresh recovered snapshot and rejects its old worker', () async {
    final snapshot = await frozen();
    final token = await fixture.jobs.beginAttempt(
      jobId: snapshot.jobId,
      stage: TaskStage.export,
    );
    await fixture.jobs.recoverInterruptedAttempts();
    await expectLater(
      exports.publish(token, publicationFixture(snapshot)),
      throwsA(code(FailureCode.conflict)),
    );
    final current = await fixture.jobs.getJob(snapshot.jobId);
    final next = await fixture.jobs.freezeExport(current.id, current.revision);
    expect(next.id, isNot(snapshot.id));
  });
  test(
    'an active destination write blocks edits and review changes until fenced',
    () async {
      final snapshot = await frozen();
      final publication = await publishFixture(fixture, snapshot);
      final file = publication.tracks.single, id = const Uuid().v4();
      await exports.beginDelivery(
        publication,
        file,
        id: id,
        destination: chosen('chosen.mp3'),
        temporary: chosen('.ytpd-$id.part'),
        device: 1,
        inode: 2,
      );
      final job = await fixture.jobs.getJob(snapshot.jobId),
          track = (await fixture.jobs.listTracks(job.id)).single;
      await expectLater(
        fixture.jobs.transition(job.id, job.revision, JobPhase.reviewReady),
        throwsA(code(FailureCode.conflict)),
      );
      await expectLater(
        fixture.jobs.editMetadata(
          trackId: track.id,
          revision: track.revision,
          candidate: SongMetadata(title: 'Too early', artists: ['Mira Vale']),
          fields: {MetadataField.title},
        ),
        throwsA(code(FailureCode.conflict)),
      );
      await exports.fenceDeliveries(job.id);
      await expectLater(
        exports.finishDelivery(id),
        throwsA(code(FailureCode.conflict)),
      );
      await fixture.jobs.transition(job.id, job.revision, JobPhase.reviewReady);
      expect(await exports.current(job.id), isNull);
    },
  );
  test('only a completed destination operation creates a durable saved-copy receipt', () async {
    final snapshot = await frozen();
    final publication = await publishFixture(fixture, snapshot);
    final id = const Uuid().v4();
    await exports.beginDelivery(
      publication,
      publication.archive,
      id: id,
      destination: chosen('Chosen name.zip'),
      temporary: chosen('.ytpd-$id.part'),
      device: 1,
      inode: 2,
    );
    expect(await exports.latestReceipt(snapshot.id), isNull);
    await exports.finishDelivery(id);
    expect(
      (await exports.latestReceipt(snapshot.id))!.filename,
      'Chosen name.zip',
    );
    await fixture.jobs.recoverInterruptedAttempts();
    expect((await exports.current(snapshot.jobId))!.snapshot.id, snapshot.id);
    expect((await exports.latestReceipt(snapshot.id))!.id, id);
  });
  test(
    'restart marks an unfinished delivery interrupted without claiming success',
    () async {
      final snapshot = await frozen();
      final publication = await publishFixture(fixture, snapshot),
          id = const Uuid().v4();
      await exports.beginDelivery(
        publication,
        publication.archive,
        id: id,
        destination: chosen('Chosen.zip'),
        temporary: chosen('.ytpd-$id.part'),
        device: 1,
        inode: 2,
      );
      final interrupted = await exports.interruptedDeliveries();
      expect(interrupted.single['status'], 'interrupted');
      expect(await exports.latestReceipt(snapshot.id), isNull);
      expect((await exports.current(snapshot.jobId))!.snapshot.id, snapshot.id);
      await exports.stagingCleaned(id);
      expect(await exports.interruptedDeliveries(), isEmpty);
    },
  );
  test('destination intent survives a crash before inode binding and cannot bind after Stop', () async {
    final snapshot = await frozen(), id = const Uuid().v4();
    final publication = await publishFixture(fixture, snapshot);
    await exports.beginDelivery(
      publication,
      publication.archive,
      id: id,
      destination: chosen('Chosen.zip'),
      temporary: chosen('.ytpd-$id.part'),
      device: 0,
      inode: 0,
    );
    await expectLater(
      exports.finishDelivery(id),
      throwsA(code(FailureCode.conflict)),
    );
    final pending = (await exports.interruptedDeliveries()).single;
    expect(pending['inode'], 0);
    expect(pending['status'], 'interrupted');
    await expectLater(
      exports.bindStaging(id, device: 1, inode: 2),
      throwsA(code(FailureCode.conflict)),
    );
    expect(await exports.latestReceipt(snapshot.id), isNull);
  });
  test('forged artifact metadata and unrelated staging paths never enter the delivery journal', () async {
    final snapshot = await frozen(), id = const Uuid().v4();
    final publication = await publishFixture(fixture, snapshot),
        file = publication.archive;
    final forged = ExportFile(
      id: file.id,
      kind: file.kind,
      filename: file.filename,
      sha256: file.sha256,
      bytes: file.bytes + 1,
    );
    await expectLater(
      exports.beginDelivery(
        publication,
        forged,
        id: id,
        destination: chosen('Chosen.zip'),
        temporary: chosen('.ytpd-$id.part'),
        device: 1,
        inode: 2,
      ),
      throwsA(code(FailureCode.conflict)),
    );
    await expectLater(
      exports.beginDelivery(
        publication,
        file,
        id: id,
        destination: chosen('Chosen.zip'),
        temporary: p.join(fixture.root.path, 'other', 'foreign.part'),
        device: 1,
        inode: 2,
      ),
      throwsA(code(FailureCode.conflict)),
    );
    expect(await fixture.db.query('export_deliveries'), isEmpty);
  });
  test('corrupt manifests and wrong artifact membership cannot become a publication', () async {
    final snapshot = await frozen(),
        publication = publicationFixture(await frozen());
    expect(
      () => ExportPublication(
        snapshot: snapshot,
        files: publication.files,
        contentManifest: publication.contentManifest,
      ),
      throwsA(code(FailureCode.corruptData)),
    );
    final valid = await publishFixture(fixture, snapshot);
    final row = (await fixture.db.query(
      'export_publications',
      where: 'export_id=?',
      whereArgs: [snapshot.id],
    )).single;
    final changed = jsonDecode(row['record'] as String) as Map<String, dynamic>;
    changed['files'][0]['filename'] = '../unsafe.mp3';
    await fixture.db.update(
      'export_publications',
      {'record': jsonEncode(changed)},
      where: 'export_id=?',
      whereArgs: [snapshot.id],
    );
    await expectLater(
      exports.current(valid.snapshot.jobId),
      throwsA(code(FailureCode.corruptData)),
    );
  });
}
