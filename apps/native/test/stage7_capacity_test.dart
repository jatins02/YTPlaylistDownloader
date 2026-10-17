import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:yt_playlist_downloader/data/local_database.dart';
import 'package:yt_playlist_downloader/data/job_repository.dart';
import 'package:yt_playlist_downloader/data/export_repository.dart';
import 'package:yt_playlist_downloader/data/pipeline_repository.dart';
import 'package:yt_playlist_downloader/domain/failure.dart';
import 'package:yt_playlist_downloader/data/review_repository.dart';
import 'package:yt_playlist_downloader/domain/media_models.dart';
import 'package:yt_playlist_downloader/domain/models.dart';
import 'package:yt_playlist_downloader/domain/playlist_url.dart';
import 'package:yt_playlist_downloader/domain/review.dart';
import 'package:yt_playlist_downloader/metadata/native_metadata_tools.dart';
import 'package:yt_playlist_downloader/platform/desktop_media_port.dart';
import 'package:yt_playlist_downloader/platform/desktop_tools.dart';
import 'package:yt_playlist_downloader/platform/guarded_process.dart';
import 'package:yt_playlist_downloader/platform/native_export_tools.dart';
import 'package:yt_playlist_downloader/platform/playlist_source.dart';

import '../tool/linux_qa_metrics.dart';
import 'export_test_support.dart' show TestExportDestination;
import 'test_support.dart';

/// Additional, explicit opt-in: measured real codecs/SQLite/tags/ZIP/transfer.
/// Synthetic source + injected destination; not physical UI or phone evidence.
void main() {
  final manifest = Platform.environment['STAGE3_TEST_RUNTIME'];
  final output = Platform.environment['STAGE7_QA_OUTPUT'];
  if (!Platform.isLinux || manifest == null || output == null) return;
  test('network loss and low-space recovery preserve verified peers', () async {
    final f = await Fixture.open();
    final tools = await DesktopTools.load(
      File(manifest),
      File('assets/process_guard.py').absolute.path,
    );
    final source = LoadSource(tools, 3, 2)..unavailable = 'qa000000001';
    var media = DesktopMediaPort(
      jobs: f.jobs,
      workspace: f.workspace,
      tools: tools,
      source: source,
    );
    try {
      await media.initialize();
      final job = await f.draft();
      Future<void> acquire() => media.acquire(
        playlist: PlaylistUrl.parse(job.sourceUrl),
        jobId: job.id,
      );
      await acquire();
      final failed = (await f.jobs.listTracks(job.id))
          .singleWhere((t) => t.videoId == source.unavailable);
      expect(failed.failure, FailureCode.sourceUnavailable);
      final peers = (await PipelineRepository(f.jobs).assets(job.id))
          .where((a) => a.kind == AssetKind.audio)
          .toList();
      expect(peers, hasLength(2));
      source.unavailable = null;
      await PipelineRepository(f.jobs).retryFailedTracks(job.id);
      await acquire();
      expect(source.enumerations, 1);
      expect(source.downloads, 4);
      final after = await PipelineRepository(f.jobs).assets(job.id);
      for (final peer in peers) {
        expect(
          after.any((a) => a.id == peer.id && a.sha256 == peer.sha256),
          isTrue,
        );
      }
      await media.close();
      media = DesktopMediaPort(
        jobs: f.jobs,
        workspace: f.workspace,
        tools: tools,
        source: source,
        limits: const PipelineLimits(freeReserveBytes: 1 << 60),
      );
      await media.initialize();
      final lowSpace = await f.draft();
      await expectLater(
        media.acquire(
          playlist: PlaylistUrl.parse(lowSpace.sourceUrl),
          jobId: lowSpace.id,
        ),
        throwsA(
          isA<AppFailure>().having(
            (e) => e.code,
            'code',
            FailureCode.limitExceeded,
          ),
        ),
      );
      expect(
        (await f.jobs.getJob(lowSpace.id)).failure,
        FailureCode.limitExceeded,
      );
      expect(
        (await f.jobs.listTracks(job.id))
            .every((t) => t.phase == TrackPhase.ready),
        isTrue,
      );
      expect(source.downloads, 4);
      await media.close();
      media = DesktopMediaPort(
        jobs: f.jobs,
        workspace: f.workspace,
        tools: tools,
        source: source,
      );
      await media.initialize();
      await media.acquire(
        playlist: PlaylistUrl.parse(lowSpace.sourceUrl),
        jobId: lowSpace.id,
      );
      expect(
        (await f.jobs.listTracks(lowSpace.id))
            .every((t) => t.phase == TrackPhase.ready),
        isTrue,
      );
    } finally {
      await media.close();
      await f.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
  for (final load in [(3, 65), (10, 65), (1, 600)]) {
    test('measured Linux ${load.$1} tracks x ${load.$2} seconds', () async {
      final f = await Fixture.open();
      final destinationRoot = await Directory.systemTemp.createTemp(
        'ytpd-qa-copy-',
      );
      final destination = TestExportDestination();
      var db = f.db;
      var jobs = f.jobs;
      final tools = await DesktopTools.load(
        File(manifest),
        File('assets/process_guard.py').absolute.path,
      );
      final source = LoadSource(tools, load.$1, load.$2);
      DesktopMediaPort createPort() => DesktopMediaPort(
        jobs: jobs,
        workspace: f.workspace,
        tools: tools,
        source: source,
        vault: MemoryVault(),
        metadataTools: NativeMetadataTools(
          tools,
          File('assets/metadata_tools.py').absolute.path,
        ),
        exportTools: NativeExportTools(
          tools,
          File('assets/export_tools.py').absolute.path,
        ),
        exportDestination: destination,
      );
      var media = createPort();
      final metrics = LinuxQaMetrics(f.workspace.root, destinationRoot);
      try {
        await media.initialize();
        expect((await media.capabilities()).canExport, isTrue);
        final job = await f.draft();
        await metrics.start();
        await media.acquire(
          playlist: PlaylistUrl.parse(job.sourceUrl),
          jobId: job.id,
        );
        final tracks = await jobs.listTracks(job.id);
        expect(tracks, hasLength(load.$1));
        expect(tracks.every((t) => t.phase == TrackPhase.ready), isTrue);
        for (final track in tracks) {
          final session = await ReviewRepository(jobs).begin(track);
          await media.saveReview(
            session,
            SongMetadata(
              title: 'Equal fictional song',
              artists: ['Mira Vale'],
              version: 'Live',
            ),
            const CoverEdit.remove(),
          );
          await ReviewRepository(jobs).cancel(session);
        }
        final publication = await media.prepareExport(
          job.id,
          (await jobs.getJob(job.id)).revision,
        );
        expect(
          publication.tracks.map((f) => f.filename).toSet(),
          hasLength(load.$1),
        );
        expect(
          publication.tracks.map((f) => f.sha256).toSet(),
          hasLength(load.$1),
        );
        destination.path = '${destinationRoot.path}/full-playlist.zip';
        final receipt = await media.deliverExport(
          publication,
          publication.archive.id,
        );
        expect(receipt, isNotNull);
        expect(
          await media.files.digest(destination.path!),
          publication.archive.sha256,
        );
        destination.path = '${destinationRoot.path}/full-track.mp3';
        await media.deliverExport(publication, publication.tracks.first.id);
        expect(
          await media.files.digest(destination.path!),
          publication.tracks.first.sha256,
        );
        await media.close();
        // Reopen the real SQLite connection, not just a controller refresh.
        await f.db.close();
        db = await LocalDatabase.open(
          databaseFactoryFfi,
          f.workspace.databasePath,
        );
        jobs = JobRepository(db);
        await jobs.recoverInterruptedAttempts();
        media = createPort();
        await media.initialize();
        final restored = await media.currentExport(job.id);
        expect(restored!.json, publication.json);
        expect(
          (await ExportRepository(jobs).latestReceipt(restored.snapshot.id))!
              .fileId,
          publication.tracks.first.id,
        );
        expect(
          (await jobs.listTracks(job.id)).every(
            (t) => t.metadata.songTitle == 'Equal fictional song (Live)',
          ),
          isTrue,
        );
        expect(source.enumerations, 1);
        expect(source.downloads, load.$1);
        final report = await metrics.finish();
        await media.cancel(job.id);
        await media.discardPrivateMedia(job.id);
        expect(
          await Directory('${f.workspace.root.path}/jobs/${job.id}').exists(),
          isFalse,
        );
        expect(
          await media.files.digest(destination.path!),
          publication.tracks.first.sha256,
        );
        final target = File('$output/load-${load.$1}x${load.$2}.json');
        await target.parent.create(recursive: true);
        await target.writeAsString(
          '${const JsonEncoder.withIndent('  ').convert({'schema': 1, 'platform': 'linux-x64', 'mode': 'synthetic-real-codecs-injected-chooser', 'tracks': load.$1, 'seconds_per_track': load.$2, 'archive_bytes': publication.archive.bytes, 'verified_mp3_bytes': publication.tracks.fold<int>(0, (n, f) => n + f.bytes), 'metrics': report, 'restart_and_external_copy_cleanup': 'passed', 'battery_attribution': 'unavailable; shared host and external workloads'})}\n',
        );
      } finally {
        await metrics.dispose();
        await media.close();
        if (db != f.db) await db.close();
        await f.close();
        await destinationRoot.delete(recursive: true);
      }
    }, timeout: const Timeout(Duration(minutes: 10)));
  }
}

final class LoadSource implements PlaylistSource {
  LoadSource(this.tools, this.count, this.seconds);
  final DesktopTools tools;
  final int count, seconds;
  int enumerations = 0, downloads = 0;
  String? unavailable;
  @override
  Future<List<SourceEntry>> enumerate(
    PlaylistUrl playlist,
    ProcessScope scope,
    Directory work,
    PipelineLimits limits,
    Future<void> Function() monitor,
  ) async {
    enumerations++;
    return List.generate(
      count,
      (i) => SourceEntry(
        position: i + 1,
        title: 'Fictional load track',
        videoId: 'qa${i.toString().padLeft(9, '0')}',
        durationSeconds: seconds.toDouble(),
      ),
    );
  }

  @override
  Future<File> download(
    String videoId,
    ProcessScope scope,
    Directory work,
    PipelineLimits limits,
    Future<void> Function() monitor,
  ) async {
    downloads++;
    if (videoId == unavailable) {
      throw const AppFailure(
        FailureCode.sourceUnavailable,
        'Synthetic offline source.',
      );
    }
    final file = File('${work.path}/synthetic.flac');
    await scope.run(
      tools.ffmpeg,
      [
        '-nostdin',
        '-v',
        'error',
        '-n',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=${440 + int.parse(videoId.substring(2)) * 37}:duration=$seconds',
        '-c:a',
        'flac',
        file.path,
      ],
      directory: work,
      monitor: monitor,
      requireCleanStderr: true,
    );
    return file;
  }
}
