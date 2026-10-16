import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:yt_playlist_downloader/domain/device_export.dart';
import 'package:yt_playlist_downloader/data/export_repository.dart';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';
import 'package:yt_playlist_downloader/data/job_repository.dart';
import 'package:yt_playlist_downloader/data/local_database.dart';
import 'package:yt_playlist_downloader/data/private_workspace.dart';
import 'package:yt_playlist_downloader/domain/models.dart';
import 'package:yt_playlist_downloader/domain/playlist_url.dart';
import 'package:yt_playlist_downloader/platform/credential_vault.dart';

final class Fixture {
  Fixture._(this.root, this.workspace, this.db, this.jobs);
  final Directory root;
  final PrivateWorkspace workspace;
  final Database db;
  final JobRepository jobs;

  static Future<Fixture> open() async {
    sqfliteFfiInit();
    final root = await Directory.systemTemp.createTemp('ytpd-foundation-test-');
    final workspace = await PrivateWorkspace.acquire(
      Directory('${root.path}/private'),
    );
    final db = await LocalDatabase.open(
      databaseFactoryFfi,
      workspace.databasePath,
    );
    return Fixture._(root, workspace, db, JobRepository(db));
  }

  Future<void> close() async {
    await db.close();
    await workspace.close();
    await root.delete(recursive: true);
  }

  Future<JobRecord> draft() => jobs.createDraft(
    PlaylistUrl.parse('https://www.youtube.com/playlist?list=PL1234567890'),
  );

  Future<TrackRecord> track(
    JobRecord job, {
    int position = 1,
    String videoId = 'abcdefghijk',
  }) => jobs.addSourceTrack(
    jobId: job.id,
    position: position,
    videoId: videoId,
    sourceTitle: 'Original source title',
    metadata: SongMetadata(title: 'Moonlit Train', artists: ['Mira Vale']),
  );

  Future<TrackRecord> ready(TrackRecord initial) async {
    final assetId = const Uuid().v4();
    final attempt = await jobs.beginAttempt(
      jobId: initial.jobId,
      trackId: initial.id,
      stage: TaskStage.conversion,
    );
    await jobs.registerAsset(
      AssetRecord(
        id: assetId,
        jobId: initial.jobId,
        trackId: initial.id,
        kind: AssetKind.audio,
        relativePath: PrivatePaths.asset(
          initial.jobId,
          assetId,
          AssetKind.audio,
        ),
        sha256: List.filled(64, 'a').join(),
        bytes: 100,
      ),
      attempt: attempt,
    );
    final previewId = const Uuid().v4();
    await jobs.registerAsset(
      AssetRecord(
        id: previewId,
        jobId: initial.jobId,
        trackId: initial.id,
        kind: AssetKind.preview,
        relativePath: PrivatePaths.asset(
          initial.jobId,
          previewId,
          AssetKind.preview,
        ),
        sha256: List.filled(64, 'b').join(),
        bytes: 20,
      ),
      attempt: attempt,
    );
    await jobs.saveCheckpoint(
      attempt,
      Checkpoint(step: CheckpointStep.converted, assetId: assetId),
      complete: true,
    );
    var track = initial;
    for (final phase in [
      TrackPhase.downloading,
      TrackPhase.converting,
      TrackPhase.ready,
    ]) {
      await jobs.setTrackState(track.id, track.revision, phase);
      track = await jobs.getTrack(track.id);
    }
    return track;
  }

  Future<JobRecord> review(JobRecord initial) async {
    var job = await jobs.getJob(initial.id);
    for (final phase in [
      JobPhase.queued,
      JobPhase.enumerating,
      JobPhase.processing,
      JobPhase.reviewReady,
    ]) {
      job = await jobs.transition(job.id, job.revision, phase);
    }
    return job;
  }
}

/// Test-only implementation; production always uses the platform keyring.
final class MemoryVault implements CredentialVault {
  ApiKey? _key;
  @override
  Future<bool> hasGroqKey() async => _key != null;
  @override
  Future<ApiKey?> readGroqKey() async => _key;
  @override
  Future<void> saveGroqKey(ApiKey key) async {
    _key = key;
  }

  @override
  Future<void> removeGroqKey() async {
    _key = null;
  }
}

/// State fixture only; never claims real byte or destination verification.
ExportPublication publicationFixture(
  ExportSnapshot snapshot, {
  List<String>? filenames,
}) {
  final rows =
      (jsonDecode(snapshot.json) as Map<String, dynamic>)['tracks'] as List;
  final tracks = <ExportFile>[
    for (var i = 0; i < rows.length; i++)
      ExportFile(
        id: const Uuid().v4(),
        kind: ExportFileKind.mp3,
        trackId: rows[i]['track_id'] as String,
        filename: filenames?[i] ?? 'Fictional track $i.mp3',
        sha256: sha256.convert([i + 1]).toString(),
        bytes: 1,
      ),
  ];
  final content = jsonEncode({
    'version': 1,
    'export_id': snapshot.id,
    'job_id': snapshot.jobId,
    'snapshot_hash': snapshot.hash,
    'files': tracks.map((f) => f.toJson()).toList(),
  });
  return ExportPublication(
    snapshot: snapshot,
    contentManifest: content,
    files: [
      ...tracks,
      ExportFile(
        id: const Uuid().v4(),
        kind: ExportFileKind.manifest,
        filename: 'manifest.json',
        sha256: sha256.convert(utf8.encode(content)).toString(),
        bytes: utf8.encode(content).length,
      ),
      ExportFile(
        id: const Uuid().v4(),
        kind: ExportFileKind.zip,
        filename: 'Fictional playlist.zip',
        sha256: sha256.convert([1, 2]).toString(),
        bytes: 2,
      ),
    ],
  );
}

Future<ExportPublication> publishFixture(
  Fixture fixture,
  ExportSnapshot snapshot,
) async {
  final publication = publicationFixture(snapshot);
  final token = await fixture.jobs.beginAttempt(
    jobId: snapshot.jobId,
    stage: TaskStage.export,
  );
  await ExportRepository(fixture.jobs).publish(token, publication);
  return publication;
}
