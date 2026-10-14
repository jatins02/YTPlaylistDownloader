import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:yt_playlist_downloader/data/job_repository.dart';
import 'package:yt_playlist_downloader/data/local_database.dart';
import 'package:yt_playlist_downloader/data/pipeline_repository.dart';
import 'package:yt_playlist_downloader/data/private_workspace.dart';
import 'package:yt_playlist_downloader/domain/failure.dart';
import 'package:yt_playlist_downloader/domain/media_models.dart';
import 'package:yt_playlist_downloader/domain/models.dart';
import 'package:yt_playlist_downloader/domain/playlist_url.dart';
import 'package:yt_playlist_downloader/platform/desktop_media_port.dart';
import 'package:yt_playlist_downloader/platform/desktop_tools.dart';
import 'package:yt_playlist_downloader/platform/guarded_process.dart';
import 'package:yt_playlist_downloader/platform/playlist_source.dart';

/// Opt-in actual adapter acceptance, independent of .env/providers. A live run
/// must explicitly pass its public playlist. Runtime bytes stay in ignored runs.
Future<void> main(List<String> args) async {
  final manifestPath = Platform.environment['YTPD_MEDIA_RUNTIME'];
  if (manifestPath == null || (args.isNotEmpty && args.length != 2)) {
    stderr.writeln(
      'Set YTPD_MEDIA_RUNTIME; run with no args for synthetic media or --live <public-playlist>.',
    );
    exitCode = 2;
    return;
  }
  var live = args.length == 2 && args.first == '--live';
  final resume = args.length == 2 && args.first == '--resume';
  if (args.isNotEmpty && !live && !resume) {
    exitCode = 2;
    return;
  }
  final started = DateTime.now().toUtc();
  final root = Directory(p.join(Directory.current.path, '../../stage3-runs'));
  await root.create(recursive: true);
  final run = resume
      ? Directory(args[1]).absolute
      : await root.createTemp('linux-');
  if (resume && !p.isWithin(p.normalize(root.absolute.path), run.path)) {
    stderr.writeln('Resume requires a run under this checkout’s stage3-runs.');
    exitCode = 2;
    return;
  }
  Map<String, dynamic>? previous;
  if (resume) {
    previous = jsonDecode(
      await File(p.join(run.path, 'report.json')).readAsString(),
    ) as Map<String, dynamic>;
    live = previous['mode'] == 'live-public-playlist';
    await File(p.join(run.path, 'report-before-retry.json'))
        .writeAsString(const JsonEncoder.withIndent('  ').convert(previous));
  }
  PrivateWorkspace? workspace;
  Database? db;
  DesktopMediaPort? media;
  try {
    final tools = await DesktopTools.load(
      File(manifestPath),
      File('assets/process_guard.py').absolute.path,
    );
    workspace = await PrivateWorkspace.acquire(
      Directory(p.join(run.path, 'private')),
    );
    sqfliteFfiInit();
    db = await LocalDatabase.open(databaseFactoryFfi, workspace.databasePath);
    final jobs = JobRepository(db);
    media = DesktopMediaPort(
      jobs: jobs,
      workspace: workspace,
      tools: tools,
      source: live ? null : SyntheticPlaylistSource(tools),
    );
    await media.initialize();
    final job = resume
        ? await jobs.getJob(previous!['job_id'] as String)
        : await jobs.createDraft(
            PlaylistUrl.parse(
              live
                  ? args[1]
                  : 'https://youtube.com/playlist?list=PLsyntheticNative01',
            ),
          );
    if (resume && job.phase == JobPhase.reviewReady) {
      await PipelineRepository(jobs).retryFailedTracks(job.id);
    }
    final playlist = PlaylistUrl.parse(job.sourceUrl);
    await media.acquire(playlist: playlist, jobId: job.id);
    final snapshot = await jobs.processingSnapshot(job.id);
    final assets = await PipelineRepository(jobs).assets(job.id);
    final ready = snapshot.$2
        .where((t) => t.phase == TrackPhase.ready)
        .toList();
    final success =
        snapshot.$1.phase == JobPhase.reviewReady &&
        ready.length == 3 &&
        (live
            ? snapshot.$2.every((t) => t.phase == TrackPhase.ready)
            : snapshot.$3.length == 6 && snapshot.$2.length == 4);
    final report = {
      'mode': live ? 'live-public-playlist' : 'synthetic-real-codecs',
      'resumed': resume,
      'platform': 'linux',
      'started_utc': started.toIso8601String(),
      'elapsed_seconds':
          DateTime.now().toUtc().difference(started).inMilliseconds / 1000,
      'success': success,
      'job_id': job.id,
      'phase': snapshot.$1.phase.name,
      'entries': snapshot.$3.length,
      'unique_tracks': snapshot.$2.length,
      'ready': ready.length,
      'tracks': [
        for (final track in snapshot.$2)
          {
            'id': track.id,
            'phase': track.phase.name,
            'duration_seconds': track.durationSeconds,
            'failure': track.failure?.name,
          },
      ],
      'assets': [
        for (final asset in assets)
          {
            'id': asset.id,
            'track_id': asset.trackId,
            'kind': asset.kind.name,
            'bytes': asset.bytes,
            'sha256': asset.sha256,
          },
      ],
      'tools': {
        'python': MediaToolPins.python,
        'yt_dlp': MediaToolPins.ytDlp,
        'ejs': MediaToolPins.ejs,
        'ffmpeg': MediaToolPins.ffmpeg,
        'deno': MediaToolPins.deno,
      },
      'limitations': [
        'No AI or artwork called',
        'No player UI or device export',
        'No Windows/phone execution evidence',
      ],
    };
    await File(
      p.join(run.path, 'report.json'),
    ).writeAsString('${const JsonEncoder.withIndent('  ').convert(report)}\n');
    stdout.writeln(
      'Stage 3 ${live ? 'live' : 'synthetic'}: ${success ? 'PASS' : 'FAIL'}; ${ready.length} ready; report ${run.path}/report.json',
    );
    if (!success) exitCode = 1;
  } on AppFailure catch (error) {
    stderr.writeln('Stage 3 failed: ${error.code.name}. ${error.message}');
    exitCode = 1;
  } finally {
    if (media != null) await media.close();
    if (db != null) await db.close();
    if (workspace != null) await workspace.close();
  }
}

final class SyntheticPlaylistSource implements PlaylistSource {
  const SyntheticPlaylistSource(this.tools);
  final DesktopTools tools;
  @override
  Future<List<SourceEntry>> enumerate(
    PlaylistUrl playlist,
    ProcessScope scope,
    Directory work,
    PipelineLimits limits,
    Future<void> Function() monitor,
  ) async => const [
    SourceEntry(
      position: 1,
      title: 'Equal fictional title',
      videoId: 'abcdefghijk',
      durationSeconds: 2.4,
    ),
    SourceEntry(
      position: 2,
      title: 'Equal fictional title',
      videoId: '12345678901',
      durationSeconds: 2.4,
    ),
    SourceEntry(
      position: 3,
      title: 'Repeated occurrence',
      videoId: 'abcdefghijk',
      durationSeconds: 2.4,
    ),
    SourceEntry(
      position: 4,
      title: 'Unavailable fictional track',
      videoId: 'unused00001',
    ),
    SourceEntry(
      position: 5,
      title: 'Missing source identity',
      failure: FailureCode.sourceUnavailable,
    ),
    SourceEntry(
      position: 6,
      title: '夜の電車 — Étoiles (Live)',
      videoId: 'unicode0001',
      durationSeconds: 2.4,
    ),
  ];
  @override
  Future<File> download(
    String videoId,
    ProcessScope scope,
    Directory work,
    PipelineLimits limits,
    Future<void> Function() monitor,
  ) async {
    if (videoId == 'unused00001') {
      throw const AppFailure(
        FailureCode.sourceUnavailable,
        'Synthetic unavailable source.',
        retryable: true,
      );
    }
    final frequency = videoId == 'abcdefghijk'
        ? 440
        : videoId == '12345678901'
        ? 880
        : 1320;
    final file = File(p.join(work.path, 'generated.wav'));
    await scope.run(
      tools.ffmpeg,
      [
        '-nostdin',
        '-hide_banner',
        '-loglevel',
        'error',
        '-n',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=$frequency:duration=2.4',
        '-c:a',
        'pcm_s16le',
        file.path,
      ],
      directory: work,
      monitor: monitor,
    );
    return file;
  }
}
