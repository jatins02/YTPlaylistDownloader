import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:yt_playlist_downloader/data/review_repository.dart';
import 'package:yt_playlist_downloader/data/job_repository.dart';
import 'package:yt_playlist_downloader/domain/device_export.dart';
import 'package:yt_playlist_downloader/domain/media_models.dart';
import 'package:yt_playlist_downloader/domain/models.dart';
import 'package:yt_playlist_downloader/domain/playlist_url.dart';
import 'package:yt_playlist_downloader/domain/review.dart';
import 'package:yt_playlist_downloader/platform/desktop_media_port.dart';
import 'package:yt_playlist_downloader/platform/desktop_tools.dart';
import 'package:yt_playlist_downloader/platform/export_destination.dart';
import 'package:yt_playlist_downloader/platform/guarded_process.dart';
import 'package:yt_playlist_downloader/platform/playlist_source.dart';

import '../tool/media_smoke.dart' show SyntheticPlaylistSource;

/// 65-second distinct full tracks prove that exports are not 30-second previews.
final class ExportTestSource implements PlaylistSource {
  const ExportTestSource(this.tools);
  final DesktopTools tools;
  @override
  Future<List<SourceEntry>> enumerate(
    PlaylistUrl playlist,
    ProcessScope scope,
    Directory work,
    PipelineLimits limits,
    Future<void> Function() monitor,
  ) async {
    final entries = await SyntheticPlaylistSource(tools)
        .enumerate(playlist, scope, work, limits, monitor);
    return entries
        .map(
          (e) => SourceEntry(
            position: e.position,
            title: e.title,
            videoId: e.videoId,
            durationSeconds:
                e.videoId == 'abcdefghijk' || e.videoId == '12345678901'
                ? 65
                : e.durationSeconds,
            uploader: e.uploader,
            failure: e.failure,
          ),
        )
        .toList();
  }

  @override
  Future<File> download(
    String videoId,
    ProcessScope scope,
    Directory work,
    PipelineLimits limits,
    Future<void> Function() monitor,
  ) async {
    if (videoId != 'abcdefghijk' && videoId != '12345678901') {
      return SyntheticPlaylistSource(tools)
          .download(videoId, scope, work, limits, monitor);
    }
    final result = File('${work.path}/generated.wav');
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
        'sine=frequency=${videoId == 'abcdefghijk' ? 440 : 880}:duration=65',
        '-c:a',
        'pcm_s16le',
        result.path,
      ],
      directory: work,
      monitor: monitor,
    );
    return result;
  }
}

final class TestExportDestination implements ExportDestination {
  String? path;
  int calls = 0;
  Completer<String?>? pending;
  final entered = Completer<void>();
  @override
  Future<String?> choose(ExportFile file) async {
    calls++;
    if (!entered.isCompleted) entered.complete();
    return pending == null ? path : pending!.future;
  }
}

Future<JobRecord> prepareExportReview(
  JobRepository jobs,
  DesktopMediaPort media,
  Uint8List image,
) async {
  final job = await jobs.createDraft(
    PlaylistUrl.parse('https://youtube.com/playlist?list=PLsyntheticNative01'),
  );
  await media.acquire(
    playlist: PlaylistUrl.parse(job.sourceUrl),
    jobId: job.id,
  );
  final review = ReviewRepository(jobs);
  for (final track in await jobs.listTracks(job.id)) {
    if (track.phase != TrackPhase.ready) {
      await review.selectTrack(track, false);
    } else if (['abcdefghijk', '12345678901'].contains(track.videoId)) {
      final session = await review.begin(track);
      await media.saveReview(
        session,
        SongMetadata(
          title: 'Same full song',
          artists: ['Mira Vale'],
          featuredArtists: ['Jun Park'],
          version: 'Live',
          album: 'Fictional album',
        ),
        track.videoId == 'abcdefghijk'
            ? CoverEdit.import(image)
            : const CoverEdit.remove(),
      );
      await review.cancel(session);
    }
  }
  for (final entry in await jobs.listEntries(job.id)) {
    if (entry.trackId == null) {
      await review.selectEntry(
        await jobs.getJob(job.id),
        entry.position,
        false,
      );
    }
  }
  return jobs.getJob(job.id);
}
